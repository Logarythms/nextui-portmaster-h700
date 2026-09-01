#!/bin/sh
. "$(dirname -- "$0")/helpers.sh"

# E6/E7/E8 + F51: device profile ($DEVICE SKU token -> harbourmaster pin via
# $HOME/.config/.DEVICE + GT_PANEL_W/H panel exports; unknown/absent token =
# rg34xx-h 720x480, the RG SP profile = pre-F51 behavior), the opt-in GUI
# remap hook, the parametric resolution fallback, and controller-DB appends.
work="$SANDBOX/pmpak"; mkdir -p "$work"
cp "$TROOT/fixtures/portmaster-pak-skeleton/pak.json.fixture" "$work/pak.json"
cp "$TROOT/fixtures/portmaster-pak-skeleton/launch.sh.fixture" "$work/launch.sh"
cp "$TROOT/fixtures/portmaster-pak-skeleton/device_info.txt" "$work/device_info.txt"
cp "$TROOT/fixtures/portmaster-pak-skeleton/gamecontrollerdb_xbox.txt" "$work/gamecontrollerdb_xbox.txt"
cp "$TROOT/fixtures/portmaster-pak-skeleton/gamecontrollerdb_nintendo.txt" "$work/gamecontrollerdb_nintendo.txt"

# mapping source with one real-shaped line, to prove the append path
dbdir="$SANDBOX/pmdb"; mkdir -p "$dbdir"
printf '%s\n' '# test mapping' '190000004b4800000111000000010000,RG SP Gamepad,a:b1,b:b0,platform:Linux,' \
  > "$dbdir/gamecontrollerdb-h700-xbox.txt"
printf '%s\n' '# test mapping' '190000004b4800000111000000010000,RG SP Gamepad,a:b0,b:b1,platform:Linux,' \
  > "$dbdir/gamecontrollerdb-h700-nintendo.txt"

GT_PM_DB_DIR="$dbdir" GT_STAGE_EDIT_ONLY="$work" sh "$ROOT/build/build-pak.sh" portmaster

# --- device profile: after the XDG mkdir, h700-guarded, $DEVICE-keyed ---
assert_contains "$work/launch.sh" 'gt-h700-device-pin'
# shellcheck disable=SC2016
assert_contains "$work/launch.sh" 'echo "$gt_pm_device" >"$HOME/.config/.DEVICE"'
assert_contains "$work/launch.sh" 'gt_pm_device=rg34xx-sp'
assert_contains "$work/launch.sh" 'gt_pm_device=rg35xx-sp'
# shellcheck disable=SC2016
assert_contains "$work/launch.sh" 'export GT_PANEL_W GT_PANEL_H'
# shellcheck disable=SC2016  # literal $XDG_DATA_HOME in the grep pattern is the point
xdg_line=$(grep -n 'mkdir -p "\$XDG_DATA_HOME"' "$work/launch.sh" | head -1 | cut -d: -f1)
pin_line=$(grep -n 'gt-h700-device-pin' "$work/launch.sh" | head -1 | cut -d: -f1)
[ "$xdg_line" -lt "$pin_line" ] || { echo "device pin is not after XDG mkdir"; exit 1; }

# --- device profile behavioral: extract the injected block and run it with
# a fake HOME per token. Every consumer contract in one string:
# "<.DEVICE content> <GT_PANEL_W> <GT_PANEL_H>".
sed -n '/# gt-h700-device-pin/,/^fi$/p' "$work/launch.sh" > "$SANDBOX/pinblock.sh"
run_pin() { # $1=DEVICE value ('' = unset)
    fake="$SANDBOX/pinhome-$$-$1"; rm -rf "$fake"; mkdir -p "$fake"
    env -i PATH="$PATH" HOME="$fake" PLATFORM=h700 ${1:+DEVICE="$1"} sh -c \
      ". \"$SANDBOX/pinblock.sh\"; printf '%s %s %s' \"\$(cat \"\$HOME/.config/.DEVICE\")\" \"\$GT_PANEL_W\" \"\$GT_PANEL_H\""
}
assert_eq "$(run_pin rg34xxsp)"  "rg34xx-sp 720 480"  "rg34xxsp profile"
assert_eq "$(run_pin rg35xxsp)"  "rg35xx-sp 640 480"  "rg35xxsp profile"
assert_eq "$(run_pin rg35xxh)"   "rg35xx-h 640 480"   "rg35xxh profile"
assert_eq "$(run_pin rgcubexx)"  "rg34xx-h 720 720"   "rgcubexx panel truth, nearest profile"
assert_eq "$(run_pin rgsp)"      "rg34xx-h 720 480"   "rgsp = RG SP profile"
# family-bucket tokens: what the current NextUI-h700 build actually emits
# (its launch.sh maps RG34xx*->rg34xx, RG35xx*->rg35xx, RG40xx*->rg40xx,
# RGcubexx->cube; device-read 2026-09-01) — the exact-SKU arms above follow
# the wiki and cover newer builds.
assert_eq "$(run_pin rg34xx)"    "rg34xx-h 720 480"   "rg34xx family bucket"
assert_eq "$(run_pin rg35xx)"    "rg35xx-plus 640 480" "rg35xx family bucket"
assert_eq "$(run_pin rg40xx)"    "rg40xx-h 640 480"   "rg40xx family bucket"
assert_eq "$(run_pin cube)"      "rg34xx-h 720 720"   "cube family bucket"
assert_eq "$(run_pin '')"        "rg34xx-h 720 480"   "absent \$DEVICE = pre-F51 behavior"
assert_eq "$(run_pin someflyer)" "rg34xx-h 720 480"   "unknown token = pre-F51 behavior"

# --- remap hook: after the 4-space pugwash-reboot rm, before the GUI loop ---
assert_contains "$work/launch.sh" 'gt-h700-remap-hook'
# shellcheck disable=SC2016
assert_contains "$work/launch.sh" 'use-remap'
hook_line=$(grep -n 'gt-h700-remap-hook' "$work/launch.sh" | head -1 | cut -d: -f1)
loop_line=$(grep -n '^    while true; do$' "$work/launch.sh" | head -1 | cut -d: -f1)
[ "$hook_line" -lt "$loop_line" ] || { echo "remap hook is not before the pugwash loop"; exit 1; }

# --- device_info fallback 640x480 -> ${GT_PANEL_W/H:-RG SP panel} ---
assert_contains "$work/device_info.txt" 'gt-h700-fallback'
# shellcheck disable=SC2016
assert_contains "$work/device_info.txt" 'DISPLAY_WIDTH=${GT_PANEL_W:-720}'
# shellcheck disable=SC2016
assert_contains "$work/device_info.txt" 'DISPLAY_HEIGHT=${GT_PANEL_H:-480}'
assert_not_contains "$work/device_info.txt" '^    DISPLAY_WIDTH=640$'

# behavioral: the edited fallback lines honor the exports and default to the
# RG SP panel without them.
grep 'gt-h700-fallback' "$work/device_info.txt" | sed 's/^ *//' > "$SANDBOX/fallback.sh"
out=$(env -i PATH="$PATH" GT_PANEL_W=640 GT_PANEL_H=480 sh -c ". \"$SANDBOX/fallback.sh\"; printf '%sx%s' \"\$DISPLAY_WIDTH\" \"\$DISPLAY_HEIGHT\"")
assert_eq "$out" "640x480" "fallback honors GT_PANEL_W/H"
out=$(env -i PATH="$PATH" sh -c ". \"$SANDBOX/fallback.sh\"; printf '%sx%s' \"\$DISPLAY_WIDTH\" \"\$DISPLAY_HEIGHT\"")
assert_eq "$out" "720x480" "fallback defaults to the RG SP panel"

# --- controller DB appended, comments skipped ---
assert_contains "$work/gamecontrollerdb_xbox.txt" '190000004b4800000111000000010000,RG SP Gamepad,a:b1'
assert_contains "$work/gamecontrollerdb_nintendo.txt" '190000004b4800000111000000010000,RG SP Gamepad,a:b0'
assert_not_contains "$work/gamecontrollerdb_xbox.txt" '# test mapping'
sh -n "$work/launch.sh" || { echo "edited launch.sh does not parse"; exit 1; }

# --- idempotency (append must GUID-dedupe) ---
GT_PM_DB_DIR="$dbdir" GT_STAGE_EDIT_ONLY="$work" sh "$ROOT/build/build-pak.sh" portmaster
assert_eq "$(grep -c 'gt-h700-device-pin' "$work/launch.sh")" "1" "device pin idempotent"
assert_eq "$(grep -c 'gt-h700-remap-hook' "$work/launch.sh")" "1" "remap hook idempotent"
assert_eq "$(grep -c 'gt-h700-fallback' "$work/device_info.txt")" "2" "fallback edit idempotent (one marker per line, two lines)"
assert_eq "$(grep -c '^190000004b4800000111000000010000,' "$work/gamecontrollerdb_xbox.txt")" "1" "db append dedupes by GUID"
sh -n "$work/launch.sh" || { echo "edited launch.sh does not parse after rerun"; exit 1; }

# --- header-only mapping source (the pre-gate state) must be a clean no-op ---
# Isolated source dir, NOT the real repo mapping files: the on-device gate
# has since filled this repo's gamecontrollerdb-h700-*.txt files with real
# data lines, so this sub-test needs its own still-header-only source to
# exercise the no-op path deterministically, independent of that mutable
# repo state.
work2="$SANDBOX/pmpak2"; mkdir -p "$work2"
cp "$TROOT/fixtures/portmaster-pak-skeleton/pak.json.fixture" "$work2/pak.json"
cp "$TROOT/fixtures/portmaster-pak-skeleton/launch.sh.fixture" "$work2/launch.sh"
cp "$TROOT/fixtures/portmaster-pak-skeleton/gamecontrollerdb_xbox.txt" "$work2/gamecontrollerdb_xbox.txt"
headeronly_dbdir="$SANDBOX/pmdb-headeronly"; mkdir -p "$headeronly_dbdir"
printf '%s\n' '# header only, no data lines' > "$headeronly_dbdir/gamecontrollerdb-h700-xbox.txt"
before=$(wc -l < "$work2/gamecontrollerdb_xbox.txt")
GT_PM_DB_DIR="$headeronly_dbdir" GT_STAGE_EDIT_ONLY="$work2" sh "$ROOT/build/build-pak.sh" portmaster
after=$(wc -l < "$work2/gamecontrollerdb_xbox.txt")
assert_eq "$before" "$after" "header-only mapping file appends nothing"
