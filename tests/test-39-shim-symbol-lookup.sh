#!/bin/sh
. "$(dirname -- "$0")/helpers.sh"

# F68: every real-symbol lookup in gt-input-remap.c must go through the
# shim's resolver (RTLD_NEXT, then the already-loaded SDL2/EGL by soname), never
# a bare dlsym(RTLD_NEXT, "..."). A bare lookup returns NULL when the app
# loaded SDL2 into a private dlopen scope — Half-Life (Xash3D) does exactly
# that — and before F68 that meant SDL_Init failing unseen by SDL and
# SDL_PollEvent calling address 0 (device-proven on the RG SP, rc11).
#
# This is the static guard that a NEW interposer can't regress it. The
# behavioral proof is tests/container-sdl-scope-check.sh (docker; not in
# run.sh), which dlopens a fake engine RTLD_LOCAL under the preloaded shim.
SRC="$ROOT/assets/gt-input-remap.c"

n=$(grep -c 'dlsym(RTLD_NEXT, "' "$SRC" || true)
assert_eq "$n" "0" "bare dlsym(RTLD_NEXT, \"...\") lookups left in gt-input-remap.c"

assert_contains "$SRC" 'static void \*gt_sym_in(const char \*const \*libs, const char \*name)'
assert_contains "$SRC" 'dlopen(\*libs, RTLD_NOW | RTLD_NOLOAD)'
assert_contains "$SRC" '"libSDL2-2.0.so.0"'

# The resolver is the only RTLD_NEXT caller left.
n=$(grep -c 'dlsym(RTLD_NEXT, name)' "$SRC" || true)
assert_eq "$n" "1" "exactly one RTLD_NEXT lookup (inside gt_sym_in)"

# Interposers that forward unconditionally must check for NULL first.
for f in SDL_PollEvent SDL_WaitEventTimeout SDL_GL_SwapWindow eglSwapBuffers; do
  assert_contains "$SRC" "GT_MISSING(\"$f\")"
done

echo "test-39: OK"
