#!/bin/sh
. "$(dirname -- "$0")/helpers.sh"

# gt-input-remap.c's pure half, compiled NATIVELY with -DGT_REMAP_TEST (which
# strips the SDL/dlfcn interposer half and exposes a main() of asserts). F65:
# NextUI rc11 numbers the built-in pad like TrimUI / Xbox 360 on every model
# (B0 A1 Y2 X3 L1 4 R1 5 Select 6 Start 7 Menu 8 L3 9 R3 10, Vol 13/14,
# L2/R2 = trigger axes 2/5, sticks a0/a1 + a3/a4), so the rc10 index-remap
# tables are gone; main() asserts the gptk slot numbering, the trigger and
# stick axis helpers, the b8 Menu swallow and the evdev code table against it.
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

# F34: LD_PRELOAD is unconditional for h700. F65: the rc10 index remap and its
# GT_INPUT_REMAP flag are gone (shim and launcher); the allowlist only arms the
# gptk synthesis fallback, so GT_REMAP_GPTK sits inside it, LD_PRELOAD outside.
assert_not_contains "$work/launch.sh" 'GT_INPUT_REMAP=1'
assert_not_contains "$ROOT/assets/gt-input-remap.c" '"GT_INPUT_REMAP"'
# shellcheck disable=SC2016
assert_contains "$work/launch.sh" 'echo "Enabling input synthesis for $ROM_NAME"'
lp=$(grep -n 'export LD_PRELOAD=' "$work/launch.sh" | head -1 | cut -d: -f1)
gate=$(grep -n 'gt-remap-ports.txt' "$work/launch.sh" | head -1 | cut -d: -f1)
gp=$(grep -n 'export GT_REMAP_GPTK=' "$work/launch.sh" | head -1 | cut -d: -f1)
[ "$lp" -lt "$gate" ] || { echo "LD_PRELOAD must precede (be outside) the remap allowlist gate"; exit 1; }
[ "$gate" -lt "$gp" ] || { echo "GT_REMAP_GPTK must be inside the allowlist gate"; exit 1; }
# F52: a flag file turns the shim trace on for every port (user reports)
assert_contains "$work/launch.sh" 'gt-h700-input-debug'
# brackets escaped for grep BRE (unescaped '[ -f ... ]' parses as a character
# class and can error out with "invalid character range" — see test-02-syslib.sh)
# shellcheck disable=SC2016
assert_contains "$work/launch.sh" '\[ -f "$USERDATA_PATH/PORTS-portmaster/use-input-debug" \] && export GT_INPUT_REMAP_DEBUG=1'
dbg=$(grep -n 'use-input-debug' "$work/launch.sh" | head -1 | cut -d: -f1)
[ "$lp" -lt "$dbg" ] || { echo "input-debug switch must follow the LD_PRELOAD export"; exit 1; }
[ "$dbg" -lt "$gate" ] || { echo "input-debug switch must precede the remap allowlist gate"; exit 1; }
# placement: inside run_port, immediately guarding the port exec — after the
# controller-layout selection, before the bash invocation of the port script
layout_line=$(grep -Fn 'set_controller_layout "$gt_layout"' "$work/launch.sh" | head -1 | cut -d: -f1)
hook_line=$(grep -n 'gt-h700-port-remap' "$work/launch.sh" | head -1 | cut -d: -f1)
# shellcheck disable=SC2016
bash_exec_line=$(grep -n '"\$PAK_DIR/bin/bash" "\$ROM_PATH"' "$work/launch.sh" | head -1 | cut -d: -f1)
[ "$layout_line" -lt "$hook_line" ] || { echo "port-remap hook is not inside run_port (before layout selection)"; exit 1; }
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
