#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_contains() {
    local file=$1 text=$2
    grep -Fq -- "$text" "$file" || fail "expected '$text' in $file"
}
assert_not_contains() {
    local file=$1 text=$2
    ! grep -Fq -- "$text" "$file" || fail "did not expect '$text' in $file"
}

# Extract the exact update-all program emitted by section_base without running
# the root installer or writing to /usr/local/bin.
awk '
    /cat > \/usr\/local\/bin\/update-all <<'"'"'UPD'"'"'/ { capture = 1; next }
    capture && /^UPD$/ { exit }
    capture { sub(/^        /, ""); print }
' "$ROOT/fedora-postinstall.sh" > "$TMP/update-all"
[[ -s "$TMP/update-all" ]] || fail "could not extract generated update-all helper"
chmod +x "$TMP/update-all"

make_stubs() {
    local bin=$1 log=$2
    mkdir -p "$bin"
    cat > "$bin/sudo" <<'STUB'
#!/usr/bin/env bash
exec "$@"
STUB
    cat > "$bin/dnf" <<'STUB'
#!/usr/bin/env bash
echo "dnf $*" >> "$UPDATE_LOG"
exit "${DNF_STATUS:-0}"
STUB
    cat > "$bin/flatpak" <<'STUB'
#!/usr/bin/env bash
echo "flatpak $*" >> "$UPDATE_LOG"
exit "${FLATPAK_STATUS:-0}"
STUB
    cat > "$bin/fwupdmgr" <<'STUB'
#!/usr/bin/env bash
echo "fwupdmgr $*" >> "$UPDATE_LOG"
exit "${FWUPD_STATUS:-0}"
STUB
    cat > "$bin/rpm" <<'STUB'
#!/usr/bin/env bash
case "$*" in
    *"%{NAME}"*)
        [[ "${RPM_QUERY_STATUS:-0}" -eq 0 ]] || exit "$RPM_QUERY_STATUS"
        [[ "${NVIDIA_PACKAGE:-1}" == 1 ]] && printf 'akmod-nvidia\n' || true
        ;;
    *"%{VERSION}"*) printf '6.20.4-200.fc44.x86_64\n' ;;
    *) exit 1 ;;
esac
STUB
    cat > "$bin/akmods" <<'STUB'
#!/usr/bin/env bash
echo "akmods $*" >> "$UPDATE_LOG"
exit "${AKMODS_STATUS:-0}"
STUB
    cat > "$bin/modinfo" <<'STUB'
#!/usr/bin/env bash
echo "modinfo $*" >> "$UPDATE_LOG"
case " $* " in
    *" -F version "*) printf '%s\n' "${MODULE_VERSION-595.10.1}" ;;
    *" -F signer "*) printf '%s\n' "${MODULE_SIGNER-Fedora akmods}" ;;
    *) exit 1 ;;
esac
exit "${MODINFO_STATUS:-0}"
STUB
    cat > "$bin/mokutil" <<'STUB'
#!/usr/bin/env bash
echo "mokutil $*" >> "$UPDATE_LOG"
case "$*" in
    --sb-state) printf '%s\n' "${SECURE_BOOT_STATE:-SecureBoot disabled}" ;;
    --test-key*) exit "${MOKUTIL_STATUS:-0}" ;;
    --list-new) [[ "${PENDING_MOK:-0}" == 1 ]] && printf 'SHA1 Fingerprint: AA:BB:CC\n' ;;
    *) exit 1 ;;
esac
STUB
    cat > "$bin/openssl" <<'STUB'
#!/usr/bin/env bash
printf 'sha1 Fingerprint=AA:BB:CC\n'
STUB
    cat > "$bin/uname" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' '6.20.3-200.fc44.x86_64'
STUB
    chmod +x "$bin"/*
    : > "$log"
}

run_update() {
    local name=$1; shift
    local bin="$TMP/$name-bin" log="$TMP/$name.log"
    make_stubs "$bin" "$log"
    set +e
    UPDATE_LOG="$log" PATH="$bin:$PATH" "$@" "$TMP/update-all" \
        >"$TMP/$name.out" 2>&1
    local status=$?
    set -e
    printf '%s\n' "$status" > "$TMP/$name.status"
}

# A successful NVIDIA build must be checked against the newly installed kernel
# before Flatpak or firmware work begins.
run_update ready env
[[ $(cat "$TMP/ready.status") -eq 0 ]] || fail "ready update should succeed"
assert_contains "$TMP/ready.log" 'akmods --force --kernels 6.20.4-200.fc44.x86_64'
assert_contains "$TMP/ready.log" 'modinfo -k 6.20.4-200.fc44.x86_64 -F version nvidia'
assert_contains "$TMP/ready.log" 'flatpak update -y'
assert_contains "$TMP/ready.log" 'fwupdmgr update'

run_update without-nvidia env NVIDIA_PACKAGE=0
[[ $(cat "$TMP/without-nvidia.status") -eq 0 ]] || fail "non-NVIDIA updates should succeed"
assert_not_contains "$TMP/without-nvidia.log" 'akmods '
assert_contains "$TMP/without-nvidia.log" 'flatpak update -y'

run_update rpm-failed env DNF_STATUS=1
[[ $(cat "$TMP/rpm-failed.status") -ne 0 ]] || fail "RPM transaction failure must fail update-all"
assert_not_contains "$TMP/rpm-failed.log" 'flatpak update -y'

run_update rpm-query-failed env RPM_QUERY_STATUS=1
[[ $(cat "$TMP/rpm-query-failed.status") -ne 0 ]] || fail "RPM inventory failure must stop update-all"
assert_not_contains "$TMP/rpm-query-failed.log" 'flatpak update -y'

# A failed or unsigned NVIDIA module must stop before later phases and warn
# clearly against rebooting.
run_update failed-module env AKMODS_STATUS=1
[[ $(cat "$TMP/failed-module.status") -ne 0 ]] || fail "akmods failure must fail update-all"
assert_contains "$TMP/failed-module.out" 'Do not reboot'
assert_not_contains "$TMP/failed-module.log" 'flatpak update -y'

run_update unsigned env SECURE_BOOT_STATE='SecureBoot enabled' MODULE_SIGNER=''
[[ $(cat "$TMP/unsigned.status") -ne 0 ]] || fail "unsigned module must fail under Secure Boot"
assert_contains "$TMP/unsigned.out" 'Do not reboot'
assert_not_contains "$TMP/unsigned.log" 'flatpak update -y'

run_update missing-module env MODULE_VERSION=''
[[ $(cat "$TMP/missing-module.status") -ne 0 ]] || fail "missing target-kernel module must fail safely"
assert_contains "$TMP/missing-module.out" 'Do not reboot'
assert_not_contains "$TMP/missing-module.log" 'flatpak update -y'

# A matching key queued for MOK enrollment is a safe, expected first reboot
# path; a key that is neither enrolled nor pending is not.
run_update mok-pending env SECURE_BOOT_STATE='SecureBoot enabled' MOKUTIL_STATUS=1 PENDING_MOK=1
[[ $(cat "$TMP/mok-pending.status") -eq 0 ]] || fail "matching pending MOK key should permit the enrollment reboot"
assert_contains "$TMP/mok-pending.out" 'pending MOK enrollment'

run_update mok-missing env SECURE_BOOT_STATE='SecureBoot enabled' MOKUTIL_STATUS=1 PENDING_MOK=0
[[ $(cat "$TMP/mok-missing.status") -ne 0 ]] || fail "unenrolled and non-pending MOK key must fail safely"
assert_contains "$TMP/mok-missing.out" 'Do not reboot'

# Failures in independent post-RPM phases must not disappear behind a success.
run_update flatpak-failed env FLATPAK_STATUS=1
[[ $(cat "$TMP/flatpak-failed.status") -ne 0 ]] || fail "Flatpak failure must fail update-all"
assert_contains "$TMP/flatpak-failed.out" 'flatpak update FAILED'

run_update firmware-failed env FWUPD_STATUS=1
[[ $(cat "$TMP/firmware-failed.status") -ne 0 ]] || fail "firmware failure must fail update-all"
assert_contains "$TMP/firmware-failed.out" 'firmware update FAILED'

run_update firmware-refresh-failed env FWUPD_STATUS=1
[[ $(cat "$TMP/firmware-refresh-failed.status") -ne 0 ]] || fail "firmware metadata failure must fail update-all"
assert_contains "$TMP/firmware-refresh-failed.out" 'firmware metadata refresh FAILED'

echo 'PASS: update-all phase ordering, NVIDIA readiness, and failure propagation'
