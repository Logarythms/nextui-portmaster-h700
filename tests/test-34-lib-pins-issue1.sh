#!/bin/sh
. "$(dirname -- "$0")/helpers.sh"

# F58: issue #1 lib gaps for the CURRENT port builds, traced with
# LD_TRACE_LOADED_OBJECTS on the RG SP 2026-09-04: Doom Engines' Crispy binaries
# need libgomp.so.1 (OpenMP) and libgthread-2.0.so.0 (bundled fluidsynth;
# libglib-2.0 itself IS on the system image), GZDoom 4.11/4.14 need
# libgomp.so.1, Luanti needs libgmp.so.10 (NOT libcurl — that error in the
# report came from a stale Minetest build). Same "h700 lib gap" fix as
# F9/F10/F20/F40: stage bullseye libs into the pak's own lib/.
#
# F63: same "h700 lib gap" story, found in the v0.5.0 device gate (RG SP,
# NextUI rc10): Doom Engines' front-end menu is a LÖVE app whose bundled
# libs/lovelibs/libcairo.so.2 is built with cairo's X backends, and the port
# does not ship their libraries (other CFWs have them in the system image) —
# so ./love failed at load and the launcher exited before any game was picked.
# Only four sonames were missing — libxcb-shm.so.0, libxcb-render.so.0,
# libXrender.so.1, libXext.so.6 — the rest of the chain (libxcb.so.1,
# libX11.so.6, libXau.so.6, libXdmcp.so.6) was already in the pak's lib/
# (upstream). Device pre-check with exactly these four on the path: 0 missing
# libraries, 0 undefined symbols (LD_WARN + LD_BIND_NOW).
#
# Like test-16, this guards that pins.sh and build-pak.sh stay wired together
# (an undefined PM_* aborts the build under set -u; a drifted filename ships
# nothing or ships unverified bytes). The on-device gate is the behavioral proof.
PINS="$ROOT/pins.sh"
BUILD="$ROOT/build/build-pak.sh"

sh -n "$BUILD" || { echo "build-pak.sh does not parse"; exit 1; }
sh -n "$PINS"  || { echo "pins.sh does not parse"; exit 1; }

for v in PM_GOMP_DEB_URL PM_GOMP_DEB_SHA256 PM_GOMP_SO_SHA256 \
         PM_GLIB_DEB_URL PM_GLIB_DEB_SHA256 PM_GTHREAD_SO_SHA256 \
         PM_GMP_DEB_URL PM_GMP_DEB_SHA256 PM_GMP_SO_SHA256 \
         PM_XCBSHM_DEB_URL PM_XCBSHM_DEB_SHA256 PM_XCBSHM_SO_SHA256 \
         PM_XCBRENDER_DEB_URL PM_XCBRENDER_DEB_SHA256 PM_XCBRENDER_SO_SHA256 \
         PM_XRENDER_DEB_URL PM_XRENDER_DEB_SHA256 PM_XRENDER_SO_SHA256 \
         PM_XEXT_DEB_URL PM_XEXT_DEB_SHA256 PM_XEXT_SO_SHA256; do
  grep -q "^${v}=" "$PINS" || { echo "pins.sh missing definition: $v"; exit 1; }
  grep -q "\$${v}\b\|\${${v}}" "$BUILD" || { echo "build-pak.sh never references: $v"; exit 1; }
done

for v in PM_GOMP_DEB_SHA256 PM_GOMP_SO_SHA256 PM_GLIB_DEB_SHA256 PM_GTHREAD_SO_SHA256 \
         PM_GMP_DEB_SHA256 PM_GMP_SO_SHA256 \
         PM_XCBSHM_DEB_SHA256 PM_XCBSHM_SO_SHA256 \
         PM_XCBRENDER_DEB_SHA256 PM_XCBRENDER_SO_SHA256 \
         PM_XRENDER_DEB_SHA256 PM_XRENDER_SO_SHA256 \
         PM_XEXT_DEB_SHA256 PM_XEXT_SO_SHA256; do
  val=$(grep "^${v}=" "$PINS" | head -1 | cut -d= -f2)
  printf '%s' "$val" | grep -Eq '^[0-9a-f]{64}$' \
    || { echo "$v is not a 64-hex sha256: '$val'"; exit 1; }
done

# the deb URLs point at bullseye arm64 pool files of the expected packages, via
# snapshot.debian.org (bullseye is archived; its live pool prunes superseded versions)
grep -q '^PM_GOMP_DEB_URL="http://snapshot.debian.org/archive/debian/[0-9]*T[0-9]*Z/pool/main/g/gcc-10/libgomp1_.*_arm64.deb"' "$PINS" \
  || { echo "PM_GOMP_DEB_URL is not a bullseye libgomp1 arm64 pool URL"; exit 1; }
grep -q '^PM_GLIB_DEB_URL="http://snapshot.debian.org/archive/debian/[0-9]*T[0-9]*Z/pool/main/g/glib2.0/libglib2.0-0_.*_arm64.deb"' "$PINS" \
  || { echo "PM_GLIB_DEB_URL is not a bullseye libglib2.0-0 arm64 pool URL"; exit 1; }
grep -q '^PM_GMP_DEB_URL="http://snapshot.debian.org/archive/debian/[0-9]*T[0-9]*Z/pool/main/g/gmp/libgmp10_.*_arm64.deb"' "$PINS" \
  || { echo "PM_GMP_DEB_URL is not a bullseye libgmp10 arm64 pool URL"; exit 1; }
grep -q '^PM_XCBSHM_DEB_URL="http://snapshot.debian.org/archive/debian/[0-9]*T[0-9]*Z/pool/main/libx/libxcb/libxcb-shm0_.*_arm64.deb"' "$PINS" \
  || { echo "PM_XCBSHM_DEB_URL is not a bullseye libxcb-shm0 arm64 pool URL"; exit 1; }
grep -q '^PM_XCBRENDER_DEB_URL="http://snapshot.debian.org/archive/debian/[0-9]*T[0-9]*Z/pool/main/libx/libxcb/libxcb-render0_.*_arm64.deb"' "$PINS" \
  || { echo "PM_XCBRENDER_DEB_URL is not a bullseye libxcb-render0 arm64 pool URL"; exit 1; }
grep -q '^PM_XRENDER_DEB_URL="http://snapshot.debian.org/archive/debian/[0-9]*T[0-9]*Z/pool/main/libx/libxrender/libxrender1_.*_arm64.deb"' "$PINS" \
  || { echo "PM_XRENDER_DEB_URL is not a bullseye libxrender1 arm64 pool URL"; exit 1; }
grep -q '^PM_XEXT_DEB_URL="http://snapshot.debian.org/archive/debian/[0-9]*T[0-9]*Z/pool/main/libx/libxext/libxext6_.*_arm64.deb"' "$PINS" \
  || { echo "PM_XEXT_DEB_URL is not a bullseye libxext6 arm64 pool URL"; exit 1; }

#   versioned-filename : SONAME — extracted, hash-checked, copied under the SONAME
for pair in \
  'libgomp.so.1.0.0:libgomp.so.1' \
  'libgthread-2.0.so.0.6600.8:libgthread-2.0.so.0' \
  'libgmp.so.10.4.1:libgmp.so.10' \
  'libxcb-shm.so.0.0.0:libxcb-shm.so.0' \
  'libxcb-render.so.0.0.0:libxcb-render.so.0' \
  'libXrender.so.1.3.0:libXrender.so.1' \
  'libXext.so.6.4.0:libXext.so.6'; do
  vers=${pair%%:*}; soname=${pair#*:}
  grep -q "tar -xJ .*${vers}" "$BUILD" \
    || { echo "build-pak.sh does not extract $vers"; exit 1; }
  grep -q "gt_check_extracted_hash .*${vers}" "$BUILD" \
    || { echo "build-pak.sh does not hash-verify $vers"; exit 1; }
  grep -q "cp .*${vers}.*\"\$assembled/lib/${soname}\"" "$BUILD" \
    || { echo "build-pak.sh does not cp $vers -> lib/$soname"; exit 1; }
done
# only the gthread sublibrary of glib ships — never the whole set (the system has libglib-2.0)
if grep -q 'libglib-2.0.so.0.6600.8\|libgio-2.0.so\|libgobject-2.0.so\|libgmodule-2.0.so' "$BUILD"; then
  echo "build-pak.sh must ship only libgthread from libglib2.0-0"; exit 1
fi

assert_contains "$ROOT/docs/h700-fixes.md" 'F58'
assert_contains "$ROOT/docs/h700-fixes.md" 'libgomp'
assert_contains "$ROOT/docs/h700-fixes.md" 'F63'
assert_contains "$ROOT/docs/h700-fixes.md" 'libxcb-shm'

echo "test-34-lib-pins-issue1: OK"
