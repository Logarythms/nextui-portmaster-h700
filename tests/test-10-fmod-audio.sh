#!/bin/sh
. "$(dirname -- "$0")/helpers.sh"

# gt-fmod-audio.c is an LD_PRELOAD shim for gmloadernext FMOD ports on the h700.
# The h700 audio codec is single-client (no SysV IPC -> no ALSA dmix), so a
# GameMaker port that ships FMOD opens the codec twice — the runner's own audio
# device first, then FMOD_SDL — and the runner wins, leaving FMOD (and thus the
# whole game, which routes its sound through FMOD) SILENT. The shim suppresses
# the runner's non-FMOD_SDL open so FMOD_SDL gets the device. FMOD_SDL is
# identified by SDL_AUDIO_ALLOW_FORMAT_CHANGE (0x4); capture opens always pass.
# Diagnosed + fix hardware-verified on the RG SP (Pizza Tower, 2026-08-24).
#
# The test compiles the shim NATIVELY with -DGT_FMOD_TEST, which strips the
# SDL/dlfcn interposer half and exposes a main() that asserts the suppression
# decision in isolation (no SDL needed on the host).
cc -DGT_FMOD_TEST -O2 -o "$SANDBOX/fmod-test" "$ROOT/assets/gt-fmod-audio.c"
out=$("$SANDBOX/fmod-test")
assert_eq "$out" "fmod-audio ok" "fmod-audio suppression decision"

# --- F30 gt-h700-fmod-audio: run_port auto-preloads the shim for FMOD ports ---
# Auto-gated, pak-wide, no per-port list (Option B): the launcher preloads the
# shim for any port that carries libs/libfmod*.so* (only gmloadernext FMOD ports
# do), so non-FMOD ports are untouched and no user config is needed.
work="$SANDBOX/pmpak"; mkdir -p "$work"
cp "$TROOT/fixtures/portmaster-pak-skeleton/pak.json.fixture" "$work/pak.json"
cp "$TROOT/fixtures/portmaster-pak-skeleton/launch.sh.fixture" "$work/launch.sh"
GT_STAGE_EDIT_ONLY="$work" sh "$ROOT/build/build-pak.sh" portmaster

assert_contains "$work/launch.sh" 'gt-h700-fmod-audio'
# the auto-gate: FMOD-lib detection in the port's own game dir
# shellcheck disable=SC2016
assert_contains "$work/launch.sh" 'ls "$GAMEDIR"/libs/libfmod'
# shellcheck disable=SC2016
assert_contains "$work/launch.sh" 'export LD_PRELOAD="$PAK_DIR/lib/gt-fmod-audio.so${LD_PRELOAD:+:$LD_PRELOAD}"'
# placement: inside run_port, after the controller-layout selection, before the
# port bash exec — same window as the input-remap hook, order between the two
# is irrelevant (they interpose disjoint symbols and both prepend LD_PRELOAD)
layout_nintendo_line=$(grep -n 'set_controller_layout nintendo' "$work/launch.sh" | head -1 | cut -d: -f1)
hook_line=$(grep -n 'gt-h700-fmod-audio' "$work/launch.sh" | head -1 | cut -d: -f1)
# shellcheck disable=SC2016
bash_exec_line=$(grep -n '"\$PAK_DIR/bin/bash" "\$ROM_PATH"' "$work/launch.sh" | head -1 | cut -d: -f1)
[ "$layout_nintendo_line" -lt "$hook_line" ] || { echo "fmod-audio hook is not inside run_port (before layout selection)"; exit 1; }
[ "$hook_line" -lt "$bash_exec_line" ] || { echo "fmod-audio hook is not before the port bash exec"; exit 1; }
sh -n "$work/launch.sh" || { echo "edited launch.sh does not parse"; exit 1; }

# --- idempotency ---
GT_STAGE_EDIT_ONLY="$work" sh "$ROOT/build/build-pak.sh" portmaster
assert_eq "$(grep -c 'gt-h700-fmod-audio' "$work/launch.sh")" "1" "fmod-audio marker idempotent"
sh -n "$work/launch.sh" || { echo "edited launch.sh does not parse after rerun"; exit 1; }
