#!/bin/sh
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
rc=0
for t in "$here"/test-*.sh; do
  echo "=== $(basename "$t") ==="
  sh "$t" || { echo "FAIL: $(basename "$t")"; rc=1; }
done
[ "$rc" = 0 ] && echo "ALL TESTS PASSED"
exit "$rc"
