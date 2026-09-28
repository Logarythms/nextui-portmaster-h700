#!/bin/sh
. "$(dirname -- "$0")/helpers.sh"

# F60: NextUI's SDL fork (mali-fbdev backend) calls egl_data->eglCreateSyncKHR
# and ->eglDestroySyncKHR UNGUARDED in its SwapWindow, resolving them via
# eglGetProcAddress on whatever SDL_VIDEO_EGL_DRIVER names. gl4es ports point
# SDL at gl4es's fake EGL stub; a stub older than gl4es's eglDestroySyncKHR
# (Quakespasm's, 26,568 B, eglGetProcAddress -> NULL for unknown names) makes
# the swap call address 0 -> SIGSEGV on the first frame (gdb on the RG SP,
# 2026-09-04). Newer stubs (Jedi Outcast) export it plus a catch-all eglStub and
# run; substituting JO's stub made Quakespasm play. The pak now ships its own
# stub built from a pinned ptitSeb/gl4es commit (make gl4es-egl) and run_port
# swaps it in for any 64-bit gl4es dir whose stub lacks the symbol.
work="$SANDBOX/pmpak"; mkdir -p "$work"
cp "$TROOT/fixtures/portmaster-pak-skeleton/pak.json.fixture" "$work/pak.json"
cp "$TROOT/fixtures/portmaster-pak-skeleton/launch.sh.fixture" "$work/launch.sh"
GT_STAGE_EDIT_ONLY="$work" sh "$ROOT/build/build-pak.sh" portmaster

# ---------- the committed asset: right arch, right exports, provenance pinned to the Makefile ----------
[ -f "$ROOT/assets/gl4es-libEGL.so.1" ] || { echo "assets/gl4es-libEGL.so.1 missing (run make gl4es-egl)"; exit 1; }
file "$ROOT/assets/gl4es-libEGL.so.1" | grep -q 'ELF 64-bit.*aarch64' \
  || { echo "gl4es-libEGL.so.1 is not an aarch64 shared object: $(file "$ROOT/assets/gl4es-libEGL.so.1")"; exit 1; }
[ "$(grep -a -c eglDestroySyncKHR "$ROOT/assets/gl4es-libEGL.so.1")" -ge 1 ] || { echo "stub lacks eglDestroySyncKHR"; exit 1; }
[ "$(grep -a -c eglStub "$ROOT/assets/gl4es-libEGL.so.1")" -ge 1 ] || { echo "stub lacks eglStub"; exit 1; }
mk_commit=$(grep '^GL4ES_COMMIT' "$ROOT/Makefile" | awk '{print $3}')
printf '%s' "$mk_commit" | grep -Eq '^[0-9a-f]{40}$' || { echo "Makefile GL4ES_COMMIT is not a 40-hex commit: '$mk_commit'"; exit 1; }
assert_contains "$ROOT/assets/gl4es-libEGL.txt" "^commit: $mk_commit\$"
assert_contains "$ROOT/assets/gl4es-libEGL.txt" '^sha256: '
so_sha=$(shasum -a 256 "$ROOT/assets/gl4es-libEGL.so.1" | cut -d' ' -f1)
assert_contains "$ROOT/assets/gl4es-libEGL.txt" "^sha256: $so_sha\$"
assert_contains "$ROOT/assets/gl4es-libEGL.txt" 'libGL.so.1'
# the container script is what the Makefile runs; both must exist and parse
sh -n "$ROOT/build/gl4es-egl.sh" || { echo "build/gl4es-egl.sh does not parse"; exit 1; }
assert_contains "$ROOT/Makefile" 'build/gl4es-egl.sh'
assert_contains "$ROOT/Makefile" '\-DEGL_WRAPPER=ON\|gl4es-egl.sh'

# ---------- staging: a SUBDIRECTORY of lib/, never lib/libEGL.so.1 (pak lib/ is on every port's LD_LIBRARY_PATH) ----------
# shellcheck disable=SC2016
assert_contains "$ROOT/build/build-pak.sh" 'mkdir -p "\$assembled/lib/gl4es-egl"'
# shellcheck disable=SC2016
assert_contains "$ROOT/build/build-pak.sh" 'cp "\$ASSETS/gl4es-libEGL.so.1" "\$assembled/lib/gl4es-egl/libEGL.so.1"'
assert_contains "$ROOT/build/build-pak.sh" 'gl4es-libEGL.so.1 is not an aarch64 shared object'
# shellcheck disable=SC2016
assert_not_contains "$ROOT/build/build-pak.sh" '"\$assembled/lib/libEGL.so.1"'

# ---------- run_port splices: present, after GAMEDIR resolves, before the exec ----------
assert_contains "$work/launch.sh" 'gt-h700-gl4es-egl (F60)'
assert_contains "$work/launch.sh" 'gt-h700-port-libs-path (F60)'
gamedir_line=$(grep -n 'echo "Game dir is: \$GAMEDIR"' "$work/launch.sh" | head -1 | cut -d: -f1)
exec_line=$(grep -n '"\$PAK_DIR/bin/bash" "\$ROM_PATH"' "$work/launch.sh" | head -1 | cut -d: -f1)
egl_line=$(grep -n 'gt-h700-gl4es-egl (F60)' "$work/launch.sh" | head -1 | cut -d: -f1)
libs_line=$(grep -n 'gt-h700-port-libs-path (F60)' "$work/launch.sh" | head -1 | cut -d: -f1)
[ "$gamedir_line" -lt "$egl_line" ] && [ "$egl_line" -lt "$exec_line" ] || { echo "gl4es-egl splice not between GAMEDIR resolution and exec"; exit 1; }
[ "$gamedir_line" -lt "$libs_line" ] && [ "$libs_line" -lt "$exec_line" ] || { echo "port-libs-path splice not between GAMEDIR resolution and exec"; exit 1; }
# 32-bit gl4es dirs must never be in the glob (F45 armhf ports)
assert_not_contains "$work/launch.sh" 'gl4es\.armhf'
assert_not_contains "$work/launch.sh" 'gl4es\*/libEGL'

# ---------- behavioral: the substitution ----------
sed -n '/# gt-h700-gl4es-egl (F60)/,/^    fi$/p' "$work/launch.sh" > "$SANDBOX/egl-block.sh"
pak="$SANDBOX/pak"; mkdir -p "$pak/lib/gl4es-egl"
printf 'NEW STUB eglDestroySyncKHR eglStub\n' > "$pak/lib/gl4es-egl/libEGL.so.1"
gd="$SANDBOX/ports/quakespasm"; mkdir -p "$gd/gl4es.aarch64" "$gd/gl4es.armhf"
printf 'OLD STUB eglCreateSyncKHR only\n' > "$gd/gl4es.aarch64/libEGL.so.1"
printf 'OLD 32-BIT STUB\n' > "$gd/gl4es.armhf/libEGL.so.1"
run_egl() { ( PLATFORM="${2:-h700}" PAK_DIR="$pak" GAMEDIR="$1" sh "$SANDBOX/egl-block.sh" ); }
out=$(run_egl "$gd")
case "$out" in *'substituting the pak stub (F60)'*) ;; *) echo "no substitution log line: $out"; exit 1;; esac
assert_eq "$(cat "$gd/gl4es.aarch64/libEGL.so.1")" "NEW STUB eglDestroySyncKHR eglStub" "old stub replaced"
assert_eq "$(cat "$gd/gl4es.aarch64/libEGL.so.1.gt-orig")" "OLD STUB eglCreateSyncKHR only" "original backed up"
assert_eq "$(cat "$gd/gl4es.armhf/libEGL.so.1")" "OLD 32-BIT STUB" "32-bit gl4es dir untouched"
out=$(run_egl "$gd")   # second launch: idempotent, backup not clobbered
case "$out" in *substituting*) echo "re-substituted an already-fixed stub: $out"; exit 1;; esac
assert_eq "$(cat "$gd/gl4es.aarch64/libEGL.so.1.gt-orig")" "OLD STUB eglCreateSyncKHR only" "backup preserved on re-run"
# a fresh install (or a reinstalled port) can put a different old-style stub back in place;
# the FIRST original must stay backed up, not whatever was reintroduced
printf 'OLD STUB v2, reintroduced, no symbol here\n' > "$gd/gl4es.aarch64/libEGL.so.1"
out=$(run_egl "$gd")
case "$out" in *'substituting the pak stub (F60)'*) ;; *) echo "no re-substitution log line for the reintroduced old stub: $out"; exit 1;; esac
assert_eq "$(cat "$gd/gl4es.aarch64/libEGL.so.1.gt-orig")" "OLD STUB eglCreateSyncKHR only" "backup stays the FIRST original, not the reintroduced stub"
assert_eq "$(cat "$gd/gl4es.aarch64/libEGL.so.1")" "NEW STUB eglDestroySyncKHR eglStub" "reintroduced old stub replaced again"
gd2="$SANDBOX/ports/jedi"; mkdir -p "$gd2/gl4es.aarch64"
printf 'FINE STUB eglDestroySyncKHR eglStub\n' > "$gd2/gl4es.aarch64/libEGL.so.1"
run_egl "$gd2" >/dev/null
[ ! -e "$gd2/gl4es.aarch64/libEGL.so.1.gt-orig" ] || { echo "backup created for a stub that already has the symbol"; exit 1; }
assert_eq "$(cat "$gd2/gl4es.aarch64/libEGL.so.1")" "FINE STUB eglDestroySyncKHR eglStub" "good stub untouched"
gd3="$SANDBOX/ports/plain-gl4es"; mkdir -p "$gd3/gl4es"
printf 'OLD STUB\n' > "$gd3/gl4es/libEGL.so.1"
run_egl "$gd3" tg5040 >/dev/null
assert_eq "$(cat "$gd3/gl4es/libEGL.so.1")" "OLD STUB" "non-h700 platform untouched"
run_egl "$gd3" >/dev/null
assert_eq "$(cat "$gd3/gl4es/libEGL.so.1")" "NEW STUB eglDestroySyncKHR eglStub" "plain gl4es/ dir handled on h700"

# ---------- behavioral: the port-libs path ----------
sed -n '/# gt-h700-port-libs-path (F60)/,/^    fi$/p' "$work/launch.sh" > "$SANDBOX/libs-block.sh"
gd4="$SANDBOX/ports/q2"; mkdir -p "$gd4/libs.aarch64"
printf '#!/bin/bash\nGAMEDIR=/x\n./quake\n' > "$SANDBOX/noldpath.sh"
printf '#!/bin/bash\nGAMEDIR=/x\nexport LD_LIBRARY_PATH="$GAMEDIR/libs.aarch64"\n./quake\n' > "$SANDBOX/ldpath.sh"
run_libs() { # $1=GAMEDIR $2=ROM_PATH ; prints the resulting LD_LIBRARY_PATH
    ( PLATFORM=h700 GAMEDIR="$1" ROM_PATH="$2" LD_LIBRARY_PATH=/pak/lib \
        sh -c ". \"$SANDBOX/libs-block.sh\" >/dev/null; printf '%s' \"\$LD_LIBRARY_PATH\"" )
}
assert_eq "$(run_libs "$gd4" "$SANDBOX/noldpath.sh")" "$gd4/libs.aarch64:/pak/lib" "port libs prepended when the launcher sets none"
assert_eq "$(run_libs "$gd4" "$SANDBOX/ldpath.sh")"   "/pak/lib" "launcher with its own LD_LIBRARY_PATH line untouched"
mkdir -p "$gd4/libs"
assert_eq "$(run_libs "$gd4" "$SANDBOX/noldpath.sh")" "$gd4/libs.aarch64:$gd4/libs:/pak/lib" "both port lib dirs, aarch64 first"
gd5="$SANDBOX/ports/nolibs"; mkdir -p "$gd5"
assert_eq "$(run_libs "$gd5" "$SANDBOX/noldpath.sh")" "/pak/lib" "no port lib dirs -> unchanged"

sh -n "$work/launch.sh" || { echo "edited launch.sh does not parse"; exit 1; }
GT_STAGE_EDIT_ONLY="$work" sh "$ROOT/build/build-pak.sh" portmaster
assert_eq "$(grep -c 'gt-h700-gl4es-egl (F60)' "$work/launch.sh")" 1 "gl4es-egl marker once after re-run"
assert_eq "$(grep -c 'gt-h700-port-libs-path (F60)' "$work/launch.sh")" 1 "port-libs-path marker once after re-run"

echo "test-32-gl4es-egl: OK"
