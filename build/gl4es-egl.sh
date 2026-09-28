#!/bin/sh
# build/gl4es-egl.sh — F60: build gl4es's fake EGL (libEGL.so.1) from a pinned
# ptitSeb/gl4es commit. Runs INSIDE the linux/arm64 debian:bullseye container
# that `make gl4es-egl` starts (repo mounted at /repo, GL4ES_COMMIT in the env).
# Outputs: assets/gl4es-libEGL.so.1 (stripped) + assets/gl4es-libEGL.txt
# (provenance). Why: NextUI's SDL fork calls eglCreateSyncKHR/eglDestroySyncKHR
# unguarded in its mali-fbdev swap; a port whose bundled gl4es fake EGL predates
# eglDestroySyncKHR (Quakespasm) crashes on the first frame. run_port swaps this
# newer stub in (edit_portmaster_launch, gt-h700-gl4es-egl). The stub links the
# port's OWN gl4es libGL.so.1 at load (DT_NEEDED) — the undefined-symbol list
# below is what that libGL must export; device-proven with Jedi Outcast's stub
# on Quakespasm's libGL 2026-09-04.
set -eu
: "${GL4ES_COMMIT:?GL4ES_COMMIT must be set (see Makefile)}"
: "${BULLSEYE_SNAPSHOT:?BULLSEYE_SNAPSHOT must be set (see Makefile)}"
# Debian bullseye is EOL/archived (~2026-08); deb.debian.org no longer serves it
# (the debian-security pool 404s), so pin apt to a pre-EOL snapshot.debian.org
# date with Check-Valid-Until off — the same fix `make shim` uses. main carries
# the build toolchain (git/cmake/gcc/g++/binutils + the GLES/EGL -dev headers).
printf 'deb [check-valid-until=no] http://snapshot.debian.org/archive/debian/%s bullseye main\ndeb [check-valid-until=no] http://snapshot.debian.org/archive/debian-security/%s bullseye-security main\n' \
  "$BULLSEYE_SNAPSHOT" "$BULLSEYE_SNAPSHOT" > /etc/apt/sources.list
apt-get -o Acquire::Check-Valid-Until=false -o Acquire::Retries=3 update -qq
apt-get install -y -qq git make gcc g++ binutils libegl1-mesa-dev libgles2-mesa-dev python3 python3-pip >/dev/null
# bullseye ships CMake 3.18, but gl4es's pinned commit uses CheckCompilerFlag /
# check_compiler_flag() (CMake >= 3.19). Take a newer CMake from a prebuilt PyPI
# aarch64 wheel instead of a newer base image — the gcc/glibc stay bullseye's so
# the stub keeps the device's glibc floor (the reason this lane is bullseye, not
# bookworm). /usr/local/bin (pip's target) precedes /usr/bin on PATH.
pip3 install -q cmake >/dev/null
cmake --version | head -1
rm -rf /tmp/gl4es
git clone -q https://github.com/ptitSeb/gl4es.git /tmp/gl4es
cd /tmp/gl4es
git checkout -q "$GL4ES_COMMIT"
# EGL_WRAPPER builds the fake EGL (src/egl/egl.c + lookup.c -> libEGL.so.1,
# target_link_libraries(EGL GL dl)); NOX11 + GLX_STUBS match how PortMaster
# ports build gl4es for fbdev devices.
cmake -S . -B build -DNOX11=ON -DGLX_STUBS=ON -DEGL_WRAPPER=ON -DCMAKE_BUILD_TYPE=Release >/dev/null
make -C build -j"$(nproc)" >/dev/null
egl=$(find /tmp/gl4es -name libEGL.so.1 -type f | head -1)
[ -n "$egl" ] || { echo "gl4es build produced no libEGL.so.1" >&2; exit 1; }
# Fail closed on arch (F45 lesson + the shim's arch-cache hazard): `docker run
# --platform` silently reuses a wrong-arch cached debian:bullseye, which would
# yield a 32-bit armhf stub. The Makefile pulls arm64 first; this is the belt.
readelf -h "$egl" | grep -q 'AArch64' || { echo "built libEGL.so.1 is not aarch64 (stale wrong-arch debian:bullseye?)" >&2; exit 1; }
# The two things the fix depends on, checked on the UNSTRIPPED build:
#   eglDestroySyncKHR — the symbol NextUI's mali-fbdev swap calls (a real export)
#   eglStub — the catch-all eglGetProcAddress returns for names it does not know.
# At this commit eglStub is a LOCAL symbol (nm 't'), not an export, so match [tT].
nm -D --defined-only "$egl" | grep -q ' T eglDestroySyncKHR$' || { echo "stub lacks eglDestroySyncKHR (exported)" >&2; exit 1; }
nm --defined-only "$egl" | grep -Eq ' [tT] eglStub$' || { echo "stub lacks the eglStub catch-all" >&2; exit 1; }
# Strip, but KEEP the eglStub symbol: a plain strip drops the local eglStub name
# entirely (it is not in .dynsym), and the shipped asset's presence check is a
# byte-grep for that name. eglDestroySyncKHR lives in .dynsym and survives strip.
strip -K eglStub "$egl"
# Re-assert the contract on the stripped bytes that actually ship:
nm -D --defined-only "$egl" | grep -q ' T eglDestroySyncKHR$' || { echo "eglDestroySyncKHR lost after strip" >&2; exit 1; }
[ "$(grep -a -c eglStub "$egl")" -ge 1 ] || { echo "eglStub name lost after strip -K" >&2; exit 1; }
cp "$egl" /repo/assets/gl4es-libEGL.so.1
{
  echo "gl4es fake EGL (libEGL.so.1), shipped as lib/gl4es-egl/libEGL.so.1 - F60"
  echo "source: https://github.com/ptitSeb/gl4es (MIT)"
  echo "commit: $GL4ES_COMMIT"
  echo "built: $(date -u +%Y-%m-%dT%H:%MZ) in debian:bullseye linux/arm64 (build/gl4es-egl.sh), stripped (kept the eglStub symbol)"
  echo "cmake: -DNOX11=ON -DGLX_STUBS=ON -DEGL_WRAPPER=ON -DCMAKE_BUILD_TYPE=Release"
  echo "size: $(stat -c %s /repo/assets/gl4es-libEGL.so.1) bytes"
  echo "sha256: $(sha256sum /repo/assets/gl4es-libEGL.so.1 | cut -d' ' -f1)"
  echo
  echo "DT_NEEDED:"
  readelf -d /repo/assets/gl4es-libEGL.so.1 | awk '/NEEDED/ { gsub(/[][]/, "", $NF); print "  " $NF }'
  echo
  echo "undefined non-glibc symbols (resolved from the PORT's own gl4es libGL.so.1 at load):"
  nm -D --undefined-only /repo/assets/gl4es-libEGL.so.1 | awk '$NF !~ /@/ && $NF !~ /^_/ { print "  " $NF }'
} > /repo/assets/gl4es-libEGL.txt
cat /repo/assets/gl4es-libEGL.txt
