#!/bin/sh
. "$(dirname -- "$0")/helpers.sh"

# gt-input-remap.c carries a pure remap table (device SDL joystick index →
# the index the TrimUI-compiled stock PortMaster binaries expect). The table
# is the MEASURED RG SP mapping — read live off the device via the shim's own
# jbtn trace during a scripted press sequence (2026-08-19). NextUI's h700
# SDL2 enumerates evdev keycodes in plain ascending order (ESC=b0, VolDown=b1,
# VolUp=b2), so every gamepad button lands +3 from the vanilla-SDL derivation:
#   A=3→1  B=4→0  Y=5→2  X=6→3  L1=7→4  R1=8→5
#   Select=9→6  Start=10→7  Menu=11→8  L2=12→10  R2=13→11
#   parked→15: 0-2 (ESC/volume would otherwise act as B/A/Y) and 14 (Menu's
#   second emission, KEY_GOTO — would otherwise double-fire)
# The test compiles the shim NATIVELY with -DGT_REMAP_TEST, which strips the
# SDL/dlfcn interposer half and exposes a main() that asserts the table.
cc -DGT_REMAP_TEST -O2 -o "$SANDBOX/remap-test" "$ROOT/assets/gt-input-remap.c"
out=$("$SANDBOX/remap-test")
assert_eq "$out" "remap ok" "input-remap table"

# --- F25 gt-h700-port-remap: run_port preloads the shim per port ---
# The README documented the shim as a port-level fix since v0.1.0, but only
# run_portmaster_gui ever honored a flag — run_port had no preload path at
# all (found while fixing Tunics!, whose Solarus engine reads raw joystick
# events: it launched fine and ignored every button, hardware-diagnosed
# 2026-08-23). The hook preloads gt-input-remap.so when the launcher's
# filename appears in the pak-shipped files/gt-remap-ports.txt OR the
# user's use-remap-ports file; it is NOT blanket-enabled, because
# GameController-tier ports get correct input natively.
work="$SANDBOX/pmpak"; mkdir -p "$work"
cp "$TROOT/fixtures/portmaster-pak-skeleton/pak.json.fixture" "$work/pak.json"
cp "$TROOT/fixtures/portmaster-pak-skeleton/launch.sh.fixture" "$work/launch.sh"
GT_STAGE_EDIT_ONLY="$work" sh "$ROOT/build/build-pak.sh" portmaster

assert_contains "$work/launch.sh" 'gt-h700-port-remap'
# shellcheck disable=SC2016
assert_contains "$work/launch.sh" 'grep -Fxq "$ROM_NAME" "$PAK_DIR/files/gt-remap-ports.txt"'
# shellcheck disable=SC2016
assert_contains "$work/launch.sh" 'grep -Fxq "$ROM_NAME" "$USERDATA_PATH/PORTS-portmaster/use-remap-ports"'
# shellcheck disable=SC2016
assert_contains "$work/launch.sh" 'export LD_PRELOAD="$PAK_DIR/lib/gt-input-remap.so${LD_PRELOAD:+:$LD_PRELOAD}"'
# F26: the hook hands the shim the port's own gptk mapping for keyboard
# synthesis (gptokeyb's uinput keyboard never reaches SDL apps on NextUI)
# shellcheck disable=SC2016
assert_contains "$work/launch.sh" 'export GT_REMAP_GPTK="$gt_gptk"'
# placement: inside run_port, immediately guarding the port exec — after the
# controller-layout selection, before the bash invocation of the port script
layout_nintendo_line=$(grep -n 'set_controller_layout nintendo' "$work/launch.sh" | head -1 | cut -d: -f1)
hook_line=$(grep -n 'gt-h700-port-remap' "$work/launch.sh" | head -1 | cut -d: -f1)
# shellcheck disable=SC2016
bash_exec_line=$(grep -n '"\$PAK_DIR/bin/bash" "\$ROM_PATH"' "$work/launch.sh" | head -1 | cut -d: -f1)
[ "$layout_nintendo_line" -lt "$hook_line" ] || { echo "port-remap hook is not inside run_port (before layout selection)"; exit 1; }
[ "$hook_line" -lt "$bash_exec_line" ] || { echo "port-remap hook is not before the port bash exec"; exit 1; }
sh -n "$work/launch.sh" || { echo "edited launch.sh does not parse"; exit 1; }

# the pak-shipped default list must exist and carry Tunics! (the port this
# hook was built for); comment lines are inert (grep -Fx never matches them)
assert_contains "$ROOT/assets/gt-remap-ports.txt" 'Tunics!.sh'
# v0.2.2: three more keyboard-gptk ports that were input-dead until the user
# added them to use-remap-ports (device-verified by Camille) — promoted to the
# pak default so they work out of the box. Exact launcher filenames.
assert_contains "$ROOT/assets/gt-remap-ports.txt" 'BYTEPATH.sh'
assert_contains "$ROOT/assets/gt-remap-ports.txt" 'Lasagna Boy Classic.sh'
assert_contains "$ROOT/assets/gt-remap-ports.txt" 'Road Invaders.sh'
assert_contains "$ROOT/assets/gt-remap-ports.txt" 'The Starlit Escape.sh'

# --- idempotency ---
GT_STAGE_EDIT_ONLY="$work" sh "$ROOT/build/build-pak.sh" portmaster
assert_eq "$(grep -c 'gt-h700-port-remap' "$work/launch.sh")" "1" "port-remap marker idempotent"
sh -n "$work/launch.sh" || { echo "edited launch.sh does not parse after rerun"; exit 1; }
