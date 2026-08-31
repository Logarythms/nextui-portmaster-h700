#!/bin/sh
. "$(dirname -- "$0")/helpers.sh"

# F47: host-run unit test of gt-sleepmon's pure trigger logic
# (gt_should_trigger — see assets/gt-sleepmon.c). Until this suite, that logic
# was only ever exercised by hand on a real device; `make test` could not
# catch a regression in the debounce/edge rules (power-release-only,
# lid-close-press-only, swallow-window suppression). GT_SLEEPMON_TEST compiles
# out everything Linux-only (poll/epoll, linux/input.h, /proc walking) and
# swaps in a small main() that asserts the pure function directly — see the
# #else branch in assets/gt-sleepmon.c.
#
# No C compiler in this environment -> skip rather than fail (matches the
# project's existing posture: `make shim` requires docker and is not part of
# `make test`; this suite is host-only best-effort coverage on top of that).
if ! command -v cc >/dev/null 2>&1; then
    echo "SKIP: no C compiler (cc) available on this host; gt-sleepmon trigger-logic test not run"
    exit 0
fi

bin="$SANDBOX/gt-sleepmon-test"
cc -O2 -Wall -DGT_SLEEPMON_TEST -o "$bin" "$ROOT/assets/gt-sleepmon.c" \
    || { echo "gt-sleepmon.c failed to compile under -DGT_SLEEPMON_TEST"; exit 1; }

out=$("$bin" 2>&1) && rc=0 || rc=$?
assert_eq "$rc" 0 "gt-sleepmon host trigger-logic test exited nonzero ($rc): $out"
assert_eq "$out" "sleepmon-test-ok" "unexpected output from the host trigger-logic test"

echo "test-23-sleepmon-host OK"
