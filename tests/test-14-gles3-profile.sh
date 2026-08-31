#!/bin/sh
. "$(dirname -- "$0")/helpers.sh"

# gt-gles3-profile.c is an LD_PRELOAD shim that forces SDL to create a NATIVE
# OpenGL ES 3.x context (interposing SDL_GL_SetAttribute/SDL_GL_CreateContext)
# instead of the GL4ES desktop-GL wrapper. Gothic-engine (Yacht Club) machismo
# ports — e.g. Mina the Hollower by bmdhacks — emit GLSL ES 3.10 shaders and
# take a GLES fallback when Vulkan is absent (always on h700). On GL4ES their
# shaders are down-converted to #version 100 and fail to compile, so the render
# thread SIGABRTs and the port never starts. The device's Mali r20p0 blob speaks
# native ES 3.2 and compiles them as-is. Fix hardware-verified on the RG SP
# (Mina the Hollower boots + plays on native ES3, 2026-08-27).
#
# The shim is built in the container by `make shim` (it needs SDL2 headers and
# has no host test harness), so this test does NOT compile it — it validates the
# run_port wiring the edit generates, which is the risk area, matching the other
# edit tests.

# --- F37 gt-h700-gles3-profile: run_port auto-applies the GL fix for gothic ports ---
# Auto-gated on the gothic signature libs/libgothic_patches.so (like the FMOD
# auto-gate): the failure is engine-level and h700-invariant, so the fix is
# gothic-generic by construction and needs no per-port list.
work="$SANDBOX/pmpak"; mkdir -p "$work"
cp "$TROOT/fixtures/portmaster-pak-skeleton/pak.json.fixture" "$work/pak.json"
cp "$TROOT/fixtures/portmaster-pak-skeleton/launch.sh.fixture" "$work/launch.sh"
GT_STAGE_EDIT_ONLY="$work" sh "$ROOT/build/build-pak.sh" portmaster

assert_contains "$work/launch.sh" 'gt-h700-gles3-profile'
# the auto-gate: gothic-engine signature in the port's own game dir
# shellcheck disable=SC2016
assert_contains "$work/launch.sh" '-f "$GAMEDIR/libs/libgothic_patches.so"'
# part 1: shadow the pak GL4ES libGL/libEGL with the device native Mali wrappers
assert_contains "$work/launch.sh" '/usr/lib/libGLESv2.so.2:libGL.so.1'
assert_contains "$work/launch.sh" '/usr/lib/libEGL.so.1:libEGL.so.1'
# cmp-guarded + cp -fp (a fresh mtime would retrigger rebuild-if-newer ports)
# shellcheck disable=SC2016
assert_contains "$work/launch.sh" 'cp -fp "$gt_gl_src" "$gt_gl_dst"'
# part 2: preload the ES3-profile shim
# shellcheck disable=SC2016
assert_contains "$work/launch.sh" 'export LD_PRELOAD="$PAK_DIR/lib/gt-gles3-profile.so${LD_PRELOAD:+:$LD_PRELOAD}"'

# placement: inside run_port, after the controller-layout selection, before the
# port bash exec — same window as the input-remap / fmod-audio hooks; order
# among the three is irrelevant (disjoint interposed symbols, all prepend
# LD_PRELOAD).
layout_line=$(grep -Fn 'set_controller_layout "$gt_layout"' "$work/launch.sh" | head -1 | cut -d: -f1)
hook_line=$(grep -n 'gt-h700-gles3-profile' "$work/launch.sh" | head -1 | cut -d: -f1)
# shellcheck disable=SC2016
bash_exec_line=$(grep -n '"\$PAK_DIR/bin/bash" "\$ROM_PATH"' "$work/launch.sh" | head -1 | cut -d: -f1)
[ "$layout_line" -lt "$hook_line" ] || { echo "gles3-profile hook is not inside run_port (before layout selection)"; exit 1; }
[ "$hook_line" -lt "$bash_exec_line" ] || { echo "gles3-profile hook is not before the port bash exec"; exit 1; }
sh -n "$work/launch.sh" || { echo "edited launch.sh does not parse"; exit 1; }

# --- idempotency ---
GT_STAGE_EDIT_ONLY="$work" sh "$ROOT/build/build-pak.sh" portmaster
assert_eq "$(grep -c 'gt-h700-gles3-profile' "$work/launch.sh")" "1" "gles3-profile marker idempotent"
sh -n "$work/launch.sh" || { echo "edited launch.sh does not parse after rerun"; exit 1; }

# --- HUD on native ES3: gothic ports render on a native-ES3 context where the
# F34 HUD once drew a solid black quad (the engine binds a sampler object to
# unit 0, overriding the HUD's texture params); fixed at the source in F38
# (gt-input-remap.c), device-verified on Mina 2026-08-27, so Mina is NOT
# blocklisted (nor is any gothic port).
assert_not_contains "$ROOT/assets/gt-hud-blocklist.txt" 'Mina the Hollower.sh'
