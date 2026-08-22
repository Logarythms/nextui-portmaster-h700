# helpers.sh — sourced by every tests/test-*.sh ($0 = the test file).
set -eu
TROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$TROOT/.." && pwd); export ROOT
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
assert_eq() { [ "$1" = "$2" ] || { echo "assert_eq: '$1' != '$2' ($3)"; exit 1; }; }
assert_contains() { grep -q -- "$2" "$1" || { echo "assert_contains: '$2' not in $1:"; cat "$1"; exit 1; }; }
assert_not_contains() { ! grep -q -- "$2" "$1" || { echo "assert_not_contains: '$2' IS in $1"; exit 1; }; }
