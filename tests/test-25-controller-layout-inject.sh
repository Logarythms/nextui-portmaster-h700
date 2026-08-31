#!/bin/sh
. "$(dirname -- "$0")/helpers.sh"

# F48: assert build-pak.sh injects the controller-layout resolver into
# launch.sh — run_port's upstream nintendo_file if/else is replaced by a
# call into gt-controller-layout.sh (+ GT_CONTROLLER_LAYOUT export), and
# run_portmaster_gui's hardcoded `set_controller_layout xbox` is replaced by
# the same resolver applied globally (no ROM_NAME) so the GUI pad map
# matches config.json instead of always landing on xbox.
work="$SANDBOX/pmpak"; mkdir -p "$work"
cp "$TROOT/fixtures/portmaster-pak-skeleton/pak.json.fixture" "$work/pak.json"
cp "$TROOT/fixtures/portmaster-pak-skeleton/launch.sh.fixture" "$work/launch.sh"
GT_STAGE_EDIT_ONLY="$work" sh "$ROOT/build/build-pak.sh" portmaster

# 1. run_port resolver block present
assert_contains "$work/launch.sh" 'gt-h700-controller-layout (F48): resolve nintendo/xbox'
# 2. GT_CONTROLLER_LAYOUT export present
# shellcheck disable=SC2016
assert_contains "$work/launch.sh" 'export GT_CONTROLLER_LAYOUT="$gt_layout"'
# 3. GUI marker present
assert_contains "$work/launch.sh" 'gt-h700-controller-layout-gui (F48)'
# 4. upstream nintendo_file= anchor preserved (other injected blocks + tier-3
#    legacy input hang off it)
# shellcheck disable=SC2016
assert_contains "$work/launch.sh" 'nintendo_file=$(find'
# 5. upstream if/else that consumed nintendo_file is gone
# shellcheck disable=SC2016
if grep -q 'if \[ -n "\$nintendo_file" \]; then' "$work/launch.sh"; then
    echo "upstream if/else was not replaced"; exit 1
fi
# 6. R1 guard: no literal hardcoded `set_controller_layout xbox` survives
#    anywhere in the edited file (run_port's else-branch was removed by the
#    run_port awk; run_portmaster_gui's line was replaced by the GUI awk)
if grep -q 'set_controller_layout xbox' "$work/launch.sh"; then
    echo "leftover hardcoded xbox"; exit 1
fi
sh -n "$work/launch.sh" || { echo "edited launch.sh does not parse"; exit 1; }

# 7. idempotency: a second edit pass must not double-insert either block and
#    the file must still parse
GT_STAGE_EDIT_ONLY="$work" sh "$ROOT/build/build-pak.sh" portmaster
n=$(grep -c 'gt-h700-controller-layout (F48): resolve' "$work/launch.sh")
assert_eq "$n" "1" "resolver block inserted more than once"
n_gui=$(grep -c 'gt-h700-controller-layout-gui (F48)' "$work/launch.sh")
assert_eq "$n_gui" "1" "GUI block inserted more than once"
sh -n "$work/launch.sh" || { echo "edited launch.sh does not parse after rerun"; exit 1; }

echo "test-25-controller-layout-inject OK"
