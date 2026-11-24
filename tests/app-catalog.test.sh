#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$ROOT/fedora-postinstall.sh"
README="$ROOT/README.md"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_contains() {
    grep -Fq -- "$2" "$1" || fail "expected '$2' in $1"
}

# Apps confirmed in scope must be installed and documented in their sections.
assert_contains "$SCRIPT" 'flatpak install -y --noninteractive flathub io.ente.photos'
assert_contains "$SCRIPT" 'Heronite'
assert_contains "$SCRIPT" 'Aura'
assert_contains "$SCRIPT" 'section_photos() {'
assert_contains "$SCRIPT" 'photos onlyoffice collabora mycomputer upscayl'
assert_contains "$README" 'Heronite'
assert_contains "$README" 'Aura'
assert_contains "$README" 'Ente Photos'

# Upscayl is its own opt-in section, installed from Flathub.
assert_contains "$SCRIPT" 'section_upscayl() {'
assert_contains "$SCRIPT" 'flatpak install -y --noninteractive flathub org.upscayl.Upscayl'
assert_contains "$README" 'Upscayl'

# Aurora is a pinned BETA opt-in: it must not appear in the default set, and
# its Fedora RPM is installed only after verifying the release asset digest.
assert_contains "$SCRIPT" 'mycomputer upscayl aurora'
assert_contains "$SCRIPT" 'section_aurora() {'
assert_contains "$SCRIPT" '[aurora]="Aurora game launcher — BETA (pinned 1.0.0-rc4), not for daily use"'
assert_contains "$SCRIPT" 'aurora-1.0.0-rc4-1.x86_64.rpm'
assert_contains "$SCRIPT" '1ea6d770947935ce1dcf74480144561bdcaba10fa036a8b89cfe5917e8a75890'
assert_contains "$README" '| `aurora`'
assert_contains "$README" 'BETA — release candidate, not for daily use'
if grep -Eq '^DEFAULT_SECTIONS=.*aurora' "$SCRIPT"; then
    fail 'aurora is a beta and must not be a default section'
fi

if grep -Eq 'Morrow|Safe Disk Cleaner' "$SCRIPT" "$README"; then
    fail 'Morrow and Safe Disk Cleaner were explicitly removed from scope'
fi

echo 'PASS: requested applications are represented in installer and catalog'
