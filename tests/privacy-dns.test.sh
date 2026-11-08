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

# Section, flag, provider table and the strict DoT settings must exist.
assert_contains "$SCRIPT" 'section_privacy() {'
assert_contains "$SCRIPT" --dns
assert_contains "$SCRIPT" 'quad9'
assert_contains "$SCRIPT" 'dns.quad9.net'
assert_contains "$SCRIPT" 'DNSOverTLS=yes'
assert_contains "$SCRIPT" '99-privacy.conf'

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

# README must document the section and its revert path.
assert_contains "$README" '`privacy`'
assert_contains "$README" 'DNS-over-TLS'
assert_contains "$README" '99-privacy.conf'

echo 'PASS: privacy section is optional, documented, and configures encrypted DNS'
