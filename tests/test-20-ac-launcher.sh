#!/bin/sh
. "$(dirname -- "$0")/helpers.sh"

# F45: Animal Crossing is a 32-bit armhf port; NextUI is aarch64-only. The pak
# ships a complete 32-bit runtime (files/ac-gc-h700/libs.armhf, incl. the Mali
# blob), the 32-bit build of the input shim (lib/gt-input-remap.armhf.so), and a
# launcher that wires them up. run_port re-installs that launcher over ROM_PATH
# every launch (copy_game_scripts reverts it to the pristine porter source);
# detected by the AnimalCrossing binary in GAMEDIR so no other port is touched.

# parse-check
sh -n "$ROOT/build/build-pak.sh"

# run only the edit functions against the fixture pair
work="$SANDBOX/pmpak"; mkdir -p "$work"
cp "$TROOT/fixtures/portmaster-pak-skeleton/pak.json.fixture" "$work/pak.json"
cp "$TROOT/fixtures/portmaster-pak-skeleton/launch.sh.fixture" "$work/launch.sh"
GT_STAGE_EDIT_ONLY="$work" sh "$ROOT/build/build-pak.sh" portmaster

# marker + load-bearing content (patterns are BRE — assert regex-safe
# substrings; avoid a leading '[' or '*').
assert_contains "$work/launch.sh" 'gt-h700-ac-launcher'
# shellcheck disable=SC2016
assert_contains "$work/launch.sh" 'gt_ac_src="$PAK_DIR/files/ac-gc-h700/Animal Crossing.sh"'
# shellcheck disable=SC2016
assert_contains "$work/launch.sh" '= "ac-gc" ]'
# shellcheck disable=SC2016
assert_contains "$work/launch.sh" '-f "$GAMEDIR/AnimalCrossing" ]'
# shellcheck disable=SC2016
assert_contains "$work/launch.sh" 'cp -f "$gt_ac_src" "$ROM_PATH"'

# placement: inside run_port — after GAMEDIR resolution, before the port exec
gamedir_line=$(grep -n 'echo "Game dir is: \$GAMEDIR"' "$work/launch.sh" | head -1 | cut -d: -f1)
ac_line=$(grep -n 'gt-h700-ac-launcher: F45 — re-install' "$work/launch.sh" | head -1 | cut -d: -f1)
# shellcheck disable=SC2016
bash_exec_line=$(grep -n '"\$PAK_DIR/bin/bash" "\$ROM_PATH"' "$work/launch.sh" | head -1 | cut -d: -f1)
[ "$gamedir_line" -lt "$ac_line" ] || { echo "overlay is not after GAMEDIR resolution"; exit 1; }
[ "$ac_line" -lt "$bash_exec_line" ] || { echo "overlay is not before the port exec"; exit 1; }
sh -n "$work/launch.sh" || { echo "edited launch.sh does not parse"; exit 1; }

# behavioral: slice the injected overlay fragment and run it against fake dirs.
fake="$SANDBOX/fake"
mkdir -p "$fake/pak/files/ac-gc-h700" "$fake/ac-gc" "$fake/other"
printf 'PAKLAUNCHER\n' > "$fake/pak/files/ac-gc-h700/Animal Crossing.sh"
: > "$fake/ac-gc/AnimalCrossing"      # AC signature binary present
: > "$fake/other/AnimalCrossing"      # binary present but wrong GAMEDIR basename
sed -n '/gt_ac_src=/,/^    fi$/p' "$work/launch.sh" > "$fake/overlay.sh"

# 1) ac-gc + binary + differing content -> overlays the pak launcher
printf 'PORTERLAUNCHER\n' > "$fake/rom.sh"
PAK_DIR="$fake/pak" GAMEDIR="$fake/ac-gc" ROM_PATH="$fake/rom.sh" PLATFORM=h700 \
  sh "$fake/overlay.sh" >/dev/null 2>&1 || true
assert_eq "$(cat "$fake/rom.sh")" "PAKLAUNCHER" "overlays the pak launcher onto ROM_PATH"

# 2) cmp-guard: identical content -> a rerun is a no-op (exercises the ! cmp false branch)
PAK_DIR="$fake/pak" GAMEDIR="$fake/ac-gc" ROM_PATH="$fake/rom.sh" PLATFORM=h700 \
  sh "$fake/overlay.sh" >/dev/null 2>&1 || true
assert_eq "$(cat "$fake/rom.sh")" "PAKLAUNCHER" "identical launcher left in place"

# 3) wrong GAMEDIR basename (even with an AnimalCrossing binary) -> untouched
printf 'PORTERLAUNCHER\n' > "$fake/rom2.sh"
PAK_DIR="$fake/pak" GAMEDIR="$fake/other" ROM_PATH="$fake/rom2.sh" PLATFORM=h700 \
  sh "$fake/overlay.sh" >/dev/null 2>&1 || true
assert_eq "$(cat "$fake/rom2.sh")" "PORTERLAUNCHER" "non-ac-gc port not touched"

# 4) ac-gc basename but no AnimalCrossing binary -> untouched
mkdir -p "$fake/ac-gc-empty"
printf 'PORTERLAUNCHER\n' > "$fake/rom3.sh"
PAK_DIR="$fake/pak" GAMEDIR="$fake/ac-gc-empty" ROM_PATH="$fake/rom3.sh" PLATFORM=h700 \
  sh "$fake/overlay.sh" >/dev/null 2>&1 || true
assert_eq "$(cat "$fake/rom3.sh")" "PORTERLAUNCHER" "no-binary ac-gc dir not touched"

# --- assembly staging present in do_portmaster (GT_STAGE_EDIT_ONLY skips it) ---
# shellcheck disable=SC2016
assert_contains "$ROOT/build/build-pak.sh" 'cp "$ASSETS/gt-input-remap.armhf.so" "$assembled/lib/gt-input-remap.armhf.so"'
# shellcheck disable=SC2016
assert_contains "$ROOT/build/build-pak.sh" 'mkdir -p "$assembled/files/ac-gc-h700/libs.armhf"'
# shellcheck disable=SC2016
assert_contains "$ROOT/build/build-pak.sh" 'cp "$ASSETS/ac-gc-h700/Animal Crossing.sh" "$assembled/files/ac-gc-h700/Animal Crossing.sh"'
# fail-closed ELF-class checks
assert_contains "$ROOT/build/build-pak.sh" 'is not a 32-bit ARM shared object'

# --- the pak-hosted launcher asset is correct + self-consistent ---
LAUNCHER="$ROOT/assets/ac-gc-h700/Animal Crossing.sh"
[ -f "$LAUNCHER" ] || { echo "missing $LAUNCHER"; exit 1; }
sh -n "$LAUNCHER" || { echo "shipped AC launcher does not parse"; exit 1; }
assert_contains "$LAUNCHER" 'GT_EVDEV_KEYS=1'
assert_contains "$LAUNCHER" 'SDL_VIDEODRIVER=mali'
# shellcheck disable=SC2016
assert_contains "$LAUNCHER" 'LD_PRELOAD="$PAK_DIR/lib/gt-input-remap.armhf.so"'
# shellcheck disable=SC2016
assert_contains "$LAUNCHER" 'GT_AC_RUNTIME="$PAK_DIR/files/ac-gc-h700"'
# the launcher must NOT still point the runtime at the game dir (F45 rebased to $PAK_DIR)
assert_not_contains "$LAUNCHER" 'LD_PRELOAD="$GAMEDIR/gt-input-remap.armhf.so"'

# --- the gptk maps straight to AC's keybindings + camera on L2/R2 ---
# F48 device gate: the earlier F45 static face cross-swap was removed — the
# shim now applies the Nintendo/Xbox swap dynamically, so this is the straight
# Nintendo baseline (gptk name = game button 1:1).
GPTK="$ROOT/assets/ac-gc-h700/animalcrossing.gptk"
[ -f "$GPTK" ] || { echo "missing $GPTK"; exit 1; }
assert_contains "$GPTK" 'a = space'        # gptk a -> game A (Space)
assert_contains "$GPTK" 'b = left_shift'   # gptk b -> game B (Left Shift)
assert_contains "$GPTK" 'x = x'            # gptk x -> game X
assert_contains "$GPTK" 'y = y'            # gptk y -> game Y
assert_contains "$GPTK" 'l2 = left'        # camera
assert_contains "$GPTK" 'r2 = right'

# --- the shipped runtime is genuinely 32-bit ARM (fail-closed at build too) ---
file "$ROOT/assets/gt-input-remap.armhf.so" | grep -q 'ELF 32-bit.*ARM' \
  || { echo "assets/gt-input-remap.armhf.so is not a 32-bit ARM shared object"; exit 1; }
[ -f "$ROOT/assets/ac-gc-h700/libs.armhf/libmali.so.0" ] || { echo "missing Mali blob"; exit 1; }
file "$ROOT/assets/ac-gc-h700/libs.armhf/libmali.so.0" | grep -q 'ELF 32-bit.*ARM' \
  || { echo "libs.armhf/libmali.so.0 is not a 32-bit ARM shared object"; exit 1; }

# --- the Makefile builds the armhf shim reproducibly ---
assert_contains "$ROOT/Makefile" 'linux/arm/v7'
assert_contains "$ROOT/Makefile" 'gt-input-remap.armhf.so'

# --- idempotency of the edit itself ---
GT_STAGE_EDIT_ONLY="$work" sh "$ROOT/build/build-pak.sh" portmaster
assert_eq "$(grep -c 'gt-h700-ac-launcher: F45 — re-install' "$work/launch.sh")" "1" "overlay hook inserted exactly once"
sh -n "$work/launch.sh" || { echo "edited launch.sh does not parse after rerun"; exit 1; }

# docs coverage
assert_contains "$ROOT/docs/h700-fixes.md" 'F45'
echo "test-20 ok"
