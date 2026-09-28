#!/bin/sh
# gt-preload-append.sh — F54. Some PortMaster launchers OVERWRITE LD_PRELOAD
# (Doom Engines: export LD_PRELOAD="$GAMEDIR/libs/hacksdl.so"), which drops
# every pak shim — input remap / gptokeyb passthrough / HUD, FMOD audio, GLES3
# profile, SDL audio init — from the game process. run_port calls this on the
# ROM-dir launcher inside the F32 mtime window, right before executing it.
# Every overwrite-style line
#     export LD_PRELOAD=<value>
# becomes
#     export LD_PRELOAD="${GT_LD_PRELOAD}${GT_LD_PRELOAD:+:}"<value>
# where GT_LD_PRELOAD is run_port's snapshot of the complete pak chain
# (gt-h700-preload-snapshot, exported just before the launcher runs). Shell
# concatenation keeps the launcher's own library loading after ours, and a
# trailing comment stays a comment.
#   - Only lines matching ^[[:space:]]*export LD_PRELOAD= are candidates, so a
#     commented-out export never matches.
#   - A candidate whose value already mentions LD_PRELOAD is skipped: an
#     append-style launcher (...:$LD_PRELOAD) is already right, and a line this
#     script rewrote contains GT_LD_PRELOAD — so a rerun is a no-op.
#   - No candidate => the file is not opened for writing (inode + mtime kept).
#   - No `sed -i`: BSD sed (host tests) and busybox sed differ on it; write a
#     temp file and cat it back so the inode and mode survive.
# Usage: gt-preload-append.sh <launcher.sh>
set -u
f="$1"
[ -f "$f" ] || exit 0
grep -Eq '^[[:space:]]*export LD_PRELOAD=' "$f" || exit 0
grep -E '^[[:space:]]*export LD_PRELOAD=' "$f" | grep -Evq 'LD_PRELOAD=.*LD_PRELOAD' || exit 0
tmp="$f.gt-preload.tmp"
sed '/^[[:space:]]*export LD_PRELOAD=/{/LD_PRELOAD=.*LD_PRELOAD/!s|^\([[:space:]]*export LD_PRELOAD=\)|\1"${GT_LD_PRELOAD}${GT_LD_PRELOAD:+:}"|;}' "$f" > "$tmp" \
    && cat "$tmp" > "$f"
rm -f "$tmp"
