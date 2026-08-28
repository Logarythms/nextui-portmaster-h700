#!/bin/sh
. "$(dirname -- "$0")/helpers.sh"

# F40: Sonic 1 & Sonic 2 (Rubberduckycooly RSDK decompilation) ship a
# sonic2013/sonicforever/sonic2absolute binary linked against libsndfile.so.1,
# which NextUI-h700 provides nowhere (not the port libs/, not .system, not the
# pak) — the loader aborts before main() and both ports exit instantly
# (on-device 2026-08-28). libsndfile's DT_NEEDED closure adds two more missing
# sonames, libvorbisenc.so.2 and libopus.so.0 (libFLAC/libvorbis/libogg are
# already shipped). Same "h700 lib gap" fix as F9/F10/F20: stage the three
# bullseye libs into the pak's own lib/.
#
# This staging lives in do_portmaster's network path (GT_STAGE_EDIT_ONLY exits
# before it), so — like the F9/F10/F20 lib rounds — the on-device gate is the
# behavioral proof. What IS checkable offline, and what this test guards, is
# that pins.sh and build-pak.sh stay wired together: a pin referenced but never
# defined is an unbound-var abort under `set -u`, and an extract/hash/cp
# filename that drifts ships nothing or ships unverified bytes.
PINS="$ROOT/pins.sh"
BUILD="$ROOT/build/build-pak.sh"

# both source files parse
sh -n "$BUILD" || { echo "build-pak.sh does not parse"; exit 1; }
sh -n "$PINS"  || { echo "pins.sh does not parse"; exit 1; }

# every F40 pin is DEFINED in pins.sh and REFERENCED in build-pak.sh. A pin in
# one file but not the other is the exact bug this guards (build-pak.sh runs
# under `set -eu`, so an undefined PM_* aborts the build).
for v in PM_SNDFILE_DEB_URL PM_SNDFILE_DEB_SHA256 PM_SNDFILE_SO_SHA256 \
         PM_VORBISENC_DEB_URL PM_VORBISENC_DEB_SHA256 PM_VORBISENC_SO_SHA256 \
         PM_OPUS_DEB_URL PM_OPUS_DEB_SHA256 PM_OPUS_SO_SHA256; do
  grep -q "^${v}=" "$PINS" || { echo "pins.sh missing definition: $v"; exit 1; }
  grep -q "\$${v}\b\|\${${v}}" "$BUILD" || { echo "build-pak.sh never references: $v"; exit 1; }
done

# each pin's SHA is a well-formed 64-hex digest (not a placeholder / truncated)
for v in PM_SNDFILE_DEB_SHA256 PM_SNDFILE_SO_SHA256 \
         PM_VORBISENC_DEB_SHA256 PM_VORBISENC_SO_SHA256 \
         PM_OPUS_DEB_SHA256 PM_OPUS_SO_SHA256; do
  val=$(grep "^${v}=" "$PINS" | head -1 | cut -d= -f2)
  printf '%s' "$val" | grep -Eq '^[0-9a-f]{64}$' \
    || { echo "$v is not a 64-hex sha256: '$val'"; exit 1; }
done

# the three libs must each be: extracted (versioned filename), extracted-hash
# checked, and copied into $assembled/lib/ under their SONAME. Pair the
# versioned real file with its SONAME so a drift in either half is caught.
#   versioned-filename : SONAME
for pair in \
  'libsndfile.so.1.0.31:libsndfile.so.1' \
  'libvorbisenc.so.2.0.12:libvorbisenc.so.2' \
  'libopus.so.0.8.0:libopus.so.0'; do
  vers=${pair%%:*}; soname=${pair#*:}
  grep -q "tar -xJ .*${vers}" "$BUILD" \
    || { echo "build-pak.sh does not extract $vers"; exit 1; }
  grep -q "gt_check_extracted_hash .*${vers}" "$BUILD" \
    || { echo "build-pak.sh does not hash-verify $vers"; exit 1; }
  grep -q "cp .*${vers}.*\$assembled/lib/${soname}\b\|cp .*${vers}.*\"\$assembled/lib/${soname}\"" "$BUILD" \
    || { echo "build-pak.sh does not cp $vers -> lib/$soname"; exit 1; }
done

# the F40 fix must be documented (fix-inventory entry + a per-symptom section)
assert_contains "$ROOT/docs/h700-fixes.md" 'F40'
assert_contains "$ROOT/docs/h700-fixes.md" 'libsndfile'

echo "test-16-libsndfile: OK"
