#!/bin/sh
. "$(dirname -- "$0")/helpers.sh"

# --- F34 gt-h700-hud: run_port sets GT_HUD=1 for every h700 port unless the
# port is blocklisted ---
# LD_PRELOAD of the shim is unconditional for h700 (see test-05); the HUD env
# is opt-out via files/gt-hud-blocklist.txt (pak-shipped) or the user's
# use-hud-blocklist, mirroring the opt-in shape of the remap allowlist.
work="$SANDBOX/pmpak"; mkdir -p "$work"
cp "$TROOT/fixtures/portmaster-pak-skeleton/pak.json.fixture" "$work/pak.json"
cp "$TROOT/fixtures/portmaster-pak-skeleton/launch.sh.fixture" "$work/launch.sh"
GT_STAGE_EDIT_ONLY="$work" sh "$ROOT/build/build-pak.sh" portmaster

assert_contains "$work/launch.sh" 'export GT_HUD=1'
assert_contains "$work/launch.sh" 'gt-hud-blocklist.txt'
assert_contains "$work/launch.sh" 'use-hud-blocklist'
# shellcheck disable=SC2016
assert_contains "$work/launch.sh" 'export LD_PRELOAD="$PAK_DIR/lib/gt-input-remap.so'

[ -f "$ROOT/assets/gt-hud-blocklist.txt" ] || { echo "missing assets/gt-hud-blocklist.txt"; exit 1; }
sh -n "$work/launch.sh" || { echo "launch.sh does not parse"; exit 1; }

# --- F38: on a native-ES3 context the engine can bind a sampler object to
# texture unit 0, which OVERRIDES the HUD's glTexParameteri and makes the HUD
# texture sample opaque black (device-diagnosed on the gothic machismo ports,
# "sampler[unit0]=1", 2026-08-27). The HUD unbinds it around its own draw,
# resolving glBindSampler NON-fatally so GL4ES/ES2 ports (no sampler objects)
# are untouched. Guard both halves against accidental removal.
assert_contains "$ROOT/assets/gt-input-remap.c" 'p_glBindSampler(0, 0)'
assert_contains "$ROOT/assets/gt-input-remap.c" 'gt_resolve1("glBindSampler")'
strings "$ROOT/assets/gt-input-remap.so" | grep -q 'glBindSampler' \
    || { echo "F38 sampler fix missing from built gt-input-remap.so (rebuild: make shim)"; exit 1; }

# placement: GT_HUD=1 sits in the ELSE of the blocklist check (not gated by
# the remap allowlist), and LD_PRELOAD precedes both gates.
lp=$(grep -n 'export LD_PRELOAD=' "$work/launch.sh" | head -1 | cut -d: -f1)
hud_gate=$(grep -n 'gt-hud-blocklist.txt' "$work/launch.sh" | head -1 | cut -d: -f1)
hud=$(grep -n 'export GT_HUD=1' "$work/launch.sh" | head -1 | cut -d: -f1)
[ "$lp" -lt "$hud_gate" ] || { echo "LD_PRELOAD must precede the HUD blocklist gate"; exit 1; }
[ "$hud_gate" -lt "$hud" ] || { echo "GT_HUD=1 must be inside (after) the HUD blocklist gate"; exit 1; }

# --- idempotency ---
GT_STAGE_EDIT_ONLY="$work" sh "$ROOT/build/build-pak.sh" portmaster
assert_eq "$(grep -c 'gt-h700-port-remap' "$work/launch.sh")" "1" "combined block idempotent"
sh -n "$work/launch.sh" || { echo "launch.sh does not parse after rerun"; exit 1; }
