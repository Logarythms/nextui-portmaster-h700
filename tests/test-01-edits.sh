#!/bin/sh
. "$(dirname -- "$0")/helpers.sh"

# PortMaster h700 repackage — E1/E2/E4 edit coverage (see docs/h700-fixes.md
# for the fix-by-fix rationale). Fixtures are the REAL 2.13.0
# launch.sh/pak.json; if a real file stops matching an anchor on a version
# bump, fix anchor AND fixture together.
# NOTE: fixtures are stored as launch.sh.fixture / pak.json.fixture (not
# .sh/.json) because the real upstream launch.sh trips ShellCheck style
# warnings (SC2221/SC2222/SC2034) that would fail a `find . -name '*.sh'`
# sweep run through ShellCheck; the test copies them to proper names in
# $SANDBOX before running the build script.
work="$SANDBOX/pmpak"; mkdir -p "$work"
cp "$TROOT/fixtures/portmaster-pak-skeleton/pak.json.fixture" "$work/pak.json"
cp "$TROOT/fixtures/portmaster-pak-skeleton/launch.sh.fixture" "$work/launch.sh"
GT_STAGE_EDIT_ONLY="$work" sh "$ROOT/build/build-pak.sh" portmaster

# --- E1 pak.json: h700 present exactly once, first element, JSON valid ---
assert_contains "$work/pak.json" '"h700"'
assert_eq "$(grep -c '"h700"' "$work/pak.json")" "1" "h700 added once"
assert_eq "$(sed -n '/"platforms": \[/{n;p;}' "$work/pak.json")" '    "h700",' "h700 first platforms element"
assert_contains "$work/pak.json" '"tg5040"'
python3 -m json.tool "$work/pak.json" > /dev/null \
  || { echo "pak.json is not valid JSON after edit"; exit 1; }

# --- E2 allowed_platforms: appended, not replaced ---
assert_contains "$work/launch.sh" 'allowed_platforms="tg5040 h700"'
assert_eq "$(grep -c 'allowed_platforms=' "$work/launch.sh")" "1" "platform gate edited in place"

# --- E4 cpufreq: h700 branch + preserved tg5040 else-branch ---
assert_contains "$work/launch.sh" 'gt-h700-cpufreq'
assert_contains "$work/launch.sh" 'echo 1200000 >/sys/devices/system/cpu/cpu0/cpufreq/scaling_min_freq'
assert_contains "$work/launch.sh" 'echo 1512000 >/sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq'
assert_contains "$work/launch.sh" 'echo 1608000 >/sys/devices/system/cpu/cpu0/cpufreq/scaling_min_freq'
assert_contains "$work/launch.sh" 'echo 1800000 >/sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq'
assert_eq "$(grep -c 'gt-h700-cpufreq' "$work/launch.sh")" "1" "cpufreq edit applied once"
# original unconditional 4-space lines must be gone (now inside the if/else)
assert_not_contains "$work/launch.sh" '^    echo 1608000'
assert_not_contains "$work/launch.sh" '^    echo 1800000'
sh -n "$work/launch.sh" || { echo "edited launch.sh does not parse"; exit 1; }

# --- idempotency ---
GT_STAGE_EDIT_ONLY="$work" sh "$ROOT/build/build-pak.sh" portmaster
assert_eq "$(grep -c '"h700"' "$work/pak.json")" "1" "pak.json idempotent"
assert_eq "$(grep -c 'allowed_platforms="tg5040 h700"' "$work/launch.sh")" "1" "platforms idempotent"
assert_eq "$(grep -c 'gt-h700-cpufreq' "$work/launch.sh")" "1" "cpufreq idempotent"
python3 -m json.tool "$work/pak.json" > /dev/null \
  || { echo "pak.json is not valid JSON after rerun"; exit 1; }
sh -n "$work/launch.sh" || { echo "edited launch.sh does not parse after rerun"; exit 1; }
