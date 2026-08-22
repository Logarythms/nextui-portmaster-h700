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
