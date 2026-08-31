#!/bin/sh
. "$(dirname -- "$0")/helpers.sh"

# F48: host-run unit test of gt-input-remap's layout swap (gt_button_slot under
# GT_CONTROLLER_LAYOUT). Compiles the shim source with -DGT_REMAP_TEST (libc
# only). No compiler -> skip (matches test-23's posture).
if ! command -v cc >/dev/null 2>&1; then
    echo "SKIP: no C compiler (cc) available; gt-input-remap layout test not run"
    exit 0
fi
bin="$SANDBOX/gt-input-remap-test"
cc -O2 -Wall -DGT_REMAP_TEST -o "$bin" "$ROOT/assets/gt-input-remap.c" \
    || { echo "gt-input-remap.c failed to compile under -DGT_REMAP_TEST"; exit 1; }
out=$("$bin" 2>&1) && rc=0 || rc=$?
assert_eq "$rc" 0 "gt-input-remap host test exited nonzero ($rc): $out"

echo "test-26-controller-layout-shim OK"
