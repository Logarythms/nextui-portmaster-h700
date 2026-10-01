#!/bin/sh
# F68: functional check that gt-input-remap.so forwards to the app's SDL2 (and
# EGL) when the app loaded them into a PRIVATE dlopen scope — the Half-Life
# (Xash3D FWGS) shape: xash3d.aarch64 does dlopen("libxash.so", RTLD_NOW)
# without RTLD_GLOBAL, and libxash.so NEEDs libSDL2-2.0.so.0. A preloaded
# shim's dlsym(RTLD_NEXT) can't see that scope; before F68 the shim's SDL_Init
# returned -1 without calling SDL and its SDL_PollEvent jumped to NULL.
#
# arm64 bullseye container with fake SDL2/EGL (tests/fixtures/sdl-scope/), so
# no display or audio is needed. Checks the shim built from source AND the
# committed assets/gt-input-remap.so, each with the engine dlopen'd "local"
# (the bug) and "global" (control), plus an "unresolvable" case (stand-ins
# under unknown sonames) where the shim must degrade and log, not crash.
# Run manually (or from CI); NOT part of tests/run.sh (needs docker+network).
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SNAP=$(sed -n 's/^BULLSEYE_SNAPSHOT = //p' "$ROOT/Makefile")
[ -n "$SNAP" ] || { echo "BULLSEYE_SNAPSHOT not found in Makefile"; exit 1; }
docker pull -q --platform linux/arm64 debian:bullseye >/dev/null
docker run --rm --platform linux/arm64 -e SNAP="$SNAP" \
  -v "$ROOT/assets:/w:ro" -v "$ROOT/tests/fixtures/sdl-scope:/fx:ro" debian:bullseye sh -ec '
  printf "deb [check-valid-until=no] http://snapshot.debian.org/archive/debian/%s bullseye main\ndeb [check-valid-until=no] http://snapshot.debian.org/archive/debian-security/%s bullseye-security main\n" "$SNAP" "$SNAP" > /etc/apt/sources.list
  apt-get -o Acquire::Check-Valid-Until=false -o Acquire::Retries=3 update -qq
  apt-get install -y -qq gcc libsdl2-dev libgles2-mesa-dev libegl1-mesa-dev >/dev/null
  mkdir -p /t && cd /t
  gcc -O2 -Wall -shared -fPIC -Wl,-soname,libSDL2-2.0.so.0 -o libSDL2-2.0.so.0 /fx/fake_sdl.c
  gcc -O2 -Wall -shared -fPIC -Wl,-soname,libEGL.so.1 -o libEGL.so.1 /fx/fake_egl.c
  gcc -O2 -Wall -shared -fPIC -o libengine.so /fx/engine.c ./libSDL2-2.0.so.0 ./libEGL.so.1
  gcc -O2 -Wall -o launcher /fx/launcher.c -ldl
  gcc -O2 -Wall -shared -fPIC -o gt-input-remap.src.so /w/gt-input-remap.c -ldl -pthread
  rc=0
  for shim in /t/gt-input-remap.src.so /w/gt-input-remap.so; do
    for mode in local global; do
      set +e
      out=$(LD_LIBRARY_PATH=/t LD_PRELOAD="$shim" GT_HUD=1 ./launcher "$mode" 2>&1)
      st=$?
      set -e
      bad=""
      [ "$st" = 0 ] || bad="exit=$st"
      for want in "fake: SDL_Init" "engine: SDL_Init=0" "fake: SDL_PollEvent" \
                  "fake: SDL_WaitEventTimeout" "fake: SDL_GetKeyboardState" "engine: numkeys=512" \
                  "fake: SDL_GL_SwapWindow" "fake: SDL_RenderPresent" "fake: eglSwapBuffers" \
                  "engine: eglSwapBuffers=1" "engine: done"; do
        printf "%s\n" "$out" | grep -Fqx "$want" || bad="$bad, missing [$want]"
      done
      if [ -z "$bad" ]; then
        echo "PASS: $(basename "$shim") $mode"
      else
        echo "FAIL: $(basename "$shim") $mode: ${bad#, }"
        printf "%s\n" "$out" | sed "s/^/    | /"
        rc=1
      fi
    done
  done
  # Unresolvable: the same engine linked against SDL2/EGL stand-ins under
  # sonames the fallback does not know, so neither lookup can succeed. The shim
  # must degrade (SDL_Init -1, no events, no present) and log, never call NULL.
  mkdir -p /t/odd && cd /t/odd
  gcc -O2 -Wall -shared -fPIC -Wl,-soname,libSDL2odd.so -o libSDL2odd.so /fx/fake_sdl.c
  gcc -O2 -Wall -shared -fPIC -Wl,-soname,libEGLodd.so -o libEGLodd.so /fx/fake_egl.c
  gcc -O2 -Wall -shared -fPIC -o libengine.so /fx/engine.c ./libSDL2odd.so ./libEGLodd.so
  for shim in /t/gt-input-remap.src.so /w/gt-input-remap.so; do
    set +e
    out=$(LD_LIBRARY_PATH=/t/odd LD_PRELOAD="$shim" GT_HUD=1 /t/launcher local 2>&1)
    st=$?
    set -e
    bad=""
    [ "$st" = 0 ] || bad="exit=$st"
    for want in "engine: SDL_Init=-1" "engine: SDL_PollEvent=0" "engine: SDL_WaitEventTimeout=0" \
                "engine: eglSwapBuffers=0" "engine: done" \
                "gt-input-remap: cannot resolve real SDL_Init" \
                "gt-input-remap: cannot resolve real SDL_PollEvent" \
                "gt-input-remap: cannot resolve real SDL_WaitEventTimeout" \
                "gt-input-remap: cannot resolve real SDL_GL_SwapWindow" \
                "gt-input-remap: cannot resolve real SDL_RenderPresent" \
                "gt-input-remap: cannot resolve real eglSwapBuffers"; do
      printf "%s\n" "$out" | grep -Fqx "$want" || bad="$bad, missing [$want]"
    done
    if [ -z "$bad" ]; then
      echo "PASS: $(basename "$shim") unresolvable (degrades, no crash)"
    else
      echo "FAIL: $(basename "$shim") unresolvable: ${bad#, }"
      printf "%s\n" "$out" | sed "s/^/    | /"
      rc=1
    fi
  done
  exit $rc
'
echo "container-sdl-scope-check: ALL PASS"
