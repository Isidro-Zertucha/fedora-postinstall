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
assert_contains "$SCRIPT" 'photos onlyoffice collabora mycomputer'
assert_contains "$README" 'Heronite'
assert_contains "$README" 'Aura'
assert_contains "$README" 'Ente Photos'

if grep -Eq 'Morrow|Safe Disk Cleaner' "$SCRIPT" "$README"; then
    fail 'Morrow and Safe Disk Cleaner were explicitly removed from scope'
fi

echo 'PASS: requested applications are represented in installer and catalog'
