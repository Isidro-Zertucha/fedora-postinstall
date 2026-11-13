#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$ROOT/fedora-postinstall.sh"
README="$ROOT/README.md"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_contains() {
    grep -Fq -- "$2" "$1" || fail "expected '$2' in $1"
}
assert_not_contains() {
    if grep -Fq -- "$2" "$1"; then fail "unexpected '$2' in $1"; fi
}

# The whole point of the section is undoing a bad update, so it must be a
# default, not something the user has to remember to ask for.
if ! grep -Eq '^DEFAULT_SECTIONS=.*\bsnapper\b' "$SCRIPT"; then
    fail 'snapper must be a default section'
fi
assert_contains "$SCRIPT" 'section_snapper() {'

# bash -n first: a broken heredoc here silently nukes every later section.
bash -n "$SCRIPT" || fail 'script has a bash syntax error'

# dnf5 path only. python3-dnf-plugin-snapper installs cleanly on Fedora 43+ and
# dnf5 never loads it, so asking for it succeeds and snapshots nothing.
assert_contains "$SCRIPT" 'libdnf5-plugin-actions'
# Guard the install line, not the comments that explain why the dnf4 plugin is
# deliberately absent.
if grep -Eq '^[[:space:]]*[^#]*dnf[^#]*python3-dnf-plugin-snapper' "$SCRIPT"; then
    fail 'the dnf4 snapper plugin must not be installed: dnf5 never loads it'
fi

# The actions file must exist and use the 5-field layout
# callback:package_filter:direction:options:command.
assert_contains "$SCRIPT" '/etc/dnf/libdnf5-plugins/actions.d/snapper.actions'

actions_block=$(
    awk "/<<'SNACT'/{f=1;next} /^SNACT\$/{f=0} f" "$SCRIPT"
) || fail 'could not extract the SNACT heredoc'
[[ -n "$actions_block" ]] || fail 'snapper.actions heredoc is empty'

hooks=0
while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    [[ "$line" == \#* ]] && continue
    fields=$(awk -F: '{print NF}' <<<"$line")
    [[ "$fields" -eq 5 ]] ||
        fail "snapper.actions line has $fields fields, expected 5 (callback::::command): $line"
    case "${line%%:*}" in
        pre_transaction|post_transaction) hooks=$((hooks + 1)) ;;
        *) fail "unexpected snapper.actions callback: ${line%%:*}" ;;
    esac
done <<<"$actions_block"
[[ "$hooks" -eq 2 ]] || fail "expected 2 transaction hooks, found $hooks"

# Both hook scripts must be written, executable, and carry the pre number
# across processes through the marker file.
assert_contains "$SCRIPT" '/usr/local/bin/dnf-snapper-pre'
assert_contains "$SCRIPT" '/usr/local/bin/dnf-snapper-post'
assert_contains "$SCRIPT" '/run/snapper-dnf-pre'
assert_contains "$SCRIPT" '--pre-number'
assert_contains "$SCRIPT" 'chmod 0755 "$pre" "$post"'

# A snapshot you cannot boot from is not a recovery path.
assert_contains "$SCRIPT" 'kylegospo/grub-btrfs'
assert_contains "$SCRIPT" 'grub-btrfs-watch.path'
assert_contains "$SCRIPT" 'grub2-mkconfig -o /boot/grub2/grub.cfg'
assert_contains "$SCRIPT" 'menu_auto_hide'
# The packaged path unit carries BindsTo on \x2esnapshots.mount, which does not
# exist on Fedora, so it must be disabled rather than merely re-enabled.
assert_contains "$SCRIPT" 'systemctl disable --now grub-btrfs.path'

# The section must prove the hook works instead of assuming it.
assert_contains "$SCRIPT" 'fedora-postinstall hook test'

# Fedora's layout breaks snapper rollback; the README must not promise otherwise.
assert_contains "$README" 'snapper rollback'
assert_contains "$README" 'does nothing on Fedora'
assert_contains "$README" '/boot'

# ---- Behavioural check of the hook pair -----------------------------------
# The fragile part is the cross-process handoff: pre and post run as separate
# processes, so the pre snapshot number has to survive in the marker file. Run
# the extracted scripts against a stub snapper and require the number to arrive.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"

cat >"$tmp/bin/snapper" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >>"$STUB_LOG"
case " $* " in *" -p "*) echo 42 ;; esac
exit 0
STUB
chmod +x "$tmp/bin/snapper"

extract_hook() {
    local tag="$1"
    awk "/<<'${tag}'/{f=1;next} /^${tag}\$/{f=0} f" "$SCRIPT" |
        sed "s#/run/snapper-dnf-pre#$tmp/pre#g"
}

extract_hook SNPRE >"$tmp/pre.sh"
extract_hook SNPOST >"$tmp/post.sh"
[[ -s "$tmp/pre.sh" ]] || fail 'could not extract the pre hook'
[[ -s "$tmp/post.sh" ]] || fail 'could not extract the post hook'

export STUB_LOG="$tmp/calls.log"
export PATH="$tmp/bin:$PATH"
: >"$STUB_LOG"

bash "$tmp/pre.sh" || fail 'pre hook exited non-zero'
grep -qx '42' "$tmp/pre" || fail 'pre hook did not record the snapshot number'

bash "$tmp/post.sh" || fail 'post hook exited non-zero'
grep -q -- '--pre-number 42' "$STUB_LOG" ||
    fail 'post hook did not link to the pre snapshot number'
[[ ! -e "$tmp/pre" ]] || fail 'post hook left the marker file behind'

# Without a marker the post hook must do nothing at all (no orphan snapshots).
: >"$STUB_LOG"
bash "$tmp/post.sh" || fail 'post hook exited non-zero without a marker'
[[ ! -s "$STUB_LOG" ]] || fail 'post hook created a snapshot with no pre snapshot'

echo 'PASS: snapper section'
