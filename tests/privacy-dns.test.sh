#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$ROOT/fedora-postinstall.sh"
README="$ROOT/README.md"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_contains() {
    grep -Fq -- "$2" "$1" || fail "expected '$2' in $1"
}

# The section must be optional, never part of the default run.
assert_contains "$SCRIPT" 'OPTIONAL_SECTIONS=(privacy '
if grep -Eq '^DEFAULT_SECTIONS=.*privacy' "$SCRIPT"; then
    fail 'privacy must not be a default section'
fi

# bash -n early: a broken block here would take the whole script down.
bash -n "$SCRIPT" || fail 'script has a bash syntax error'

# Section, flag, provider table and the strict DoT settings must exist.
assert_contains "$SCRIPT" 'section_privacy() {'
assert_contains "$SCRIPT" --dns
assert_contains "$SCRIPT" 'quad9'
assert_contains "$SCRIPT" 'dns.quad9.net'
assert_contains "$SCRIPT" 'DNSOverTLS=yes'
assert_contains "$SCRIPT" '99-privacy.conf'

# The drop-in is global, but resolved also queries per-link DHCP servers in
# parallel, so the section has to clear those on every profile.
assert_contains "$SCRIPT" 'lock_per_connection_dns() {'
assert_contains "$SCRIPT" 'ipv4.ignore-auto-dns yes ipv6.ignore-auto-dns yes'
assert_contains "$SCRIPT" 'privacy-dns-revert.sh'
assert_contains "$SCRIPT" 'nmcli device reapply'

# --list must advertise it without needing root.
listed=$(bash "$SCRIPT" --list 2>/dev/null || true)
case "$listed" in
    *optional:*privacy*) ;;
    *) fail "--list does not list privacy: $listed" ;;
esac

# --help must document the selector.
help_text=$(bash "$SCRIPT" --help 2>/dev/null || true)
case "$help_text" in
    *"--dns PROVIDER"*) ;;
    *) fail '--help does not document --dns' ;;
esac

# README must document the section, the per-link caveat and the revert path.
assert_contains "$README" '`privacy`'
assert_contains "$README" 'DNS-over-TLS'
assert_contains "$README" '99-privacy.conf'
assert_contains "$README" 'ignore-auto-dns'
assert_contains "$README" 'privacy-dns-revert.sh'

# ---- Behavioural check of the per-connection lock -------------------------
# The fragile part is the round trip: the values a profile had before the run
# must land in the revert script, so reverting does not clobber a hand-written
# per-connection DNS setup. Run the extracted function against a stub nmcli.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"

cat >"$tmp/bin/nmcli" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >>"$STUB_LOG"
state="$STUB_STATE"
case "$*" in
    "-t -f NAME,TYPE connection show")
        if [[ -n "${STUB_NO_CONNS:-}" ]]; then exit 0; fi
        printf '%s\n' 'Home\:WiFi:802-11-wireless' 'Wired connection 1:802-3-ethernet' 'corp:vpn'
        ;;
    "-g ipv4.ignore-auto-dns connection show "*)
        sed -n 's/^ipv4 //p' "$state"
        ;;
    "-g ipv6.ignore-auto-dns connection show "*)
        sed -n 's/^ipv6 //p' "$state"
        ;;
    "-g ipv4.dns,ipv6.dns connection show "*)
        case "$*" in
            *'Wired connection 1'*) printf '%s\n%s\n' '1.1.1.1' '' ;;
            *) printf '%s\n%s\n' '' '' ;;
        esac
        ;;
    "-g GENERAL.DEVICES connection show "*)
        case "$*" in
            *'Home:WiFi'*) echo wlp3s0 ;;
            *) echo -- ;;
        esac
        ;;
    "connection modify "*)
        # Track the lock so a second run sees the post-change values, which is
        # exactly the situation that must not corrupt the revert script.
        case "$*" in
            *"ipv4.ignore-auto-dns yes"*) sed -i 's/^ipv4 .*/ipv4 yes/' "$state" ;;
        esac
        case "$*" in
            *"ipv6.ignore-auto-dns yes"*) sed -i 's/^ipv6 .*/ipv6 yes/' "$state" ;;
        esac
        ;;
esac
exit 0
STUB
chmod +x "$tmp/bin/nmcli"

# Pre-run profile state: ipv4 already explicit (yes), ipv6 left at the default.
printf '%s\n%s\n' 'ipv4 yes' 'ipv6 no' >"$tmp/values"

awk '/^lock_per_connection_dns\(\) \{/{f=1} f; f && /^\}$/{exit}' "$SCRIPT" >"$tmp/lock.sh"
[[ -s "$tmp/lock.sh" ]] || fail 'could not extract lock_per_connection_dns'

export STUB_LOG="$tmp/calls.log"
export STUB_STATE="$tmp/values"
export PRIVACY_STATE_DIR="$tmp/state"
export PATH="$tmp/bin:$PATH"
NOTES="$tmp/notes.log"
: >"$STUB_LOG"
: >"$NOTES"

# Same contract as the script's helpers, but recorded instead of printed.
ok() { printf 'OK %s\n' "$*" >>"$NOTES"; }
warn() { printf 'WARN %s\n' "$*" >>"$NOTES"; }
err() { printf 'ERR %s\n' "$*" >>"$NOTES"; }
step() { local d=$1; shift; "$@" >>"$NOTES" 2>&1 || warn "step failed: $d"; }
step_soft() { local d=$1; shift; "$@" >>"$NOTES" 2>&1 || true; }

# shellcheck disable=SC1090
. "$tmp/lock.sh"
lock_per_connection_dns || fail 'lock_per_connection_dns exited non-zero'

REVERT="$tmp/state/privacy-dns-revert.sh"
[[ -f "$REVERT" ]] || fail 'the revert script was not generated'

# Both Ethernet and Wi-Fi are locked down; the VPN profile is not touched.
grep -Fq -- 'connection modify Home:WiFi ipv4.ignore-auto-dns yes ipv6.ignore-auto-dns yes' "$STUB_LOG" ||
    fail 'Wi-Fi profile was not locked down'
grep -Fq -- 'connection modify Wired connection 1 ipv4.ignore-auto-dns yes ipv6.ignore-auto-dns yes' "$STUB_LOG" ||
    fail 'Ethernet profile was not locked down'
if grep -Fq 'corp' "$REVERT"; then fail 'the VPN profile must not be modified'; fi

# The escaped colon in `nmcli -t` output must be unescaped before it is used.
grep -Fq 'Home:WiFi' "$REVERT" || fail 'connection name kept the nmcli escaping'

# Prior values, not a hardcoded "no": this profile had ipv4 at yes.
grep -Fq 'ipv4.ignore-auto-dns yes ipv6.ignore-auto-dns no' "$REVERT" ||
    fail 'revert script does not restore the original ignore-auto-dns values'

# A static DNS on the profile defeats the drop-in; it must be reported.
grep -Fq "also sets static DNS" "$NOTES" || fail 'static per-connection DNS was not reported'

# Only the active profile is reapplied, and with the right device.
grep -Fq 'device reapply wlp3s0' "$STUB_LOG" || fail 'active profile was not reapplied'
if grep -Fq 'device reapply --' "$STUB_LOG"; then fail 'inactive profile was reapplied'; fi

# Re-running must not overwrite the pre-run values: the stub now reports the
# locked state (yes/yes), so a naive append/rewrite would record "yes" for ipv6
# and revert to the locked configuration. The original line must survive intact.
lock_per_connection_dns || fail 'second run exited non-zero'
mods=$(grep -c '^nmcli connection modify' "$REVERT")
[[ "$mods" -eq 2 ]] || fail "revert script has $mods modify lines after a re-run, expected 2"
grep -Fq 'ipv4.ignore-auto-dns yes ipv6.ignore-auto-dns no' "$REVERT" ||
    fail 'a re-run clobbered the pre-run values in the revert script'

# A run that finds no profiles must not delete a revert script from an earlier
# run: that file is the only record of the pre-run values.
mkdir -p "$tmp/state2"
printf '%s\n' '#!/bin/bash' '# earlier run' \
    'nmcli connection modify Old ipv4.ignore-auto-dns no ipv6.ignore-auto-dns no' \
    >"$tmp/state2/privacy-dns-revert.sh"
: >"$NOTES"
STUB_NO_CONNS=1 PRIVACY_STATE_DIR="$tmp/state2" lock_per_connection_dns ||
    fail 'run without profiles exited non-zero'
[[ -f "$tmp/state2/privacy-dns-revert.sh" ]] || fail 'an earlier revert script was deleted'
grep -Fq 'connection modify Old ' "$tmp/state2/privacy-dns-revert.sh" ||
    fail 'an earlier revert script was rewritten'

echo 'PASS: privacy section is optional, documented, and configures encrypted DNS'
