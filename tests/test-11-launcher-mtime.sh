#!/bin/sh
. "$(dirname -- "$0")/helpers.sh"

# F32: launcher mtime pin. run_port patches the LAUNCHED .sh in place — a shebang
# rewrite plus the "/roms/ports/PortMaster" -> $EMU_DIR path rewrite. That is
# unavoidable, but copy_game_scripts reverts the launcher in $ROM_DIR back to its
# pristine .ports source after EVERY PortMaster-GUI session (cp -fp), so the two
# edits re-fire on the next launch and bump $0's mtime to "now". LOVE-patch ports
# key their rebuild-if-source-newer check off $0 — Balatro's (and UFO 50's)
# needs_build() lists "$LAUNCHER" (=$0) as a build source — so a purely cosmetic
# re-patch forced a full, minutes-long rebuild after any GUI session (Balatro
# hardware-diagnosed 2026-08-24: launcher 23:10:52 > Balatro_pm 23:11:26-1 ...).
# The F12b gt-h700-shebang-guard only skipped the shebang rewrite when it was
# already correct — the reverted launcher is NOT correct, and the path rewrite
# had no guard at all, so it never stopped the loop.
#
# Fix: run_port snapshots the launcher's mtime before the in-place edits and
# restores it after, wrapping all three ROM_PATH patches. Content still changes;
# mtime does not. The pristine .ports source mtime therefore stays authoritative,
# so a GENUINE port update (which bumps the source mtime, propagated by cp -fp)
# still triggers a legitimate rebuild — only no-op re-patches stop rebuilding.
work="$SANDBOX/pmpak"; mkdir -p "$work"
cp "$TROOT/fixtures/portmaster-pak-skeleton/pak.json.fixture" "$work/pak.json"
cp "$TROOT/fixtures/portmaster-pak-skeleton/launch.sh.fixture" "$work/launch.sh"
GT_STAGE_EDIT_ONLY="$work" sh "$ROOT/build/build-pak.sh" portmaster

# --- snapshot + restore present ---
assert_contains "$work/launch.sh" 'gt-h700-launcher-mtime'
# shellcheck disable=SC2016
assert_contains "$work/launch.sh" 'gt_launcher_mtime_ref="$(mktemp)"'
# shellcheck disable=SC2016
assert_contains "$work/launch.sh" 'touch -r "$ROM_PATH" "$gt_launcher_mtime_ref"'
# shellcheck disable=SC2016
assert_contains "$work/launch.sh" 'touch -r "$gt_launcher_mtime_ref" "$ROM_PATH"'
# shellcheck disable=SC2016
assert_contains "$work/launch.sh" 'rm -f "$gt_launcher_mtime_ref"'

# --- placement: the snapshot precedes the first in-place edit (the shebang
# patch); the restore follows the last one (the lib-inject block) and precedes
# GAMEDIR resolution, so it wraps ALL three ROM_PATH edits AND always runs
# before run_port's "No GAMEDIR" early-exit. ---
snap_line=$(grep -n 'touch -r "$ROM_PATH" "$gt_launcher_mtime_ref"' "$work/launch.sh" | head -1 | cut -d: -f1)
shebang_patch_line=$(grep -n 'update_file_shebang "$ROM_PATH"' "$work/launch.sh" | head -1 | cut -d: -f1)
libinject_line=$(grep -n 'Ensuring system lib path for \$ROM_PATH' "$work/launch.sh" | head -1 | cut -d: -f1)
restore_line=$(grep -n 'touch -r "$gt_launcher_mtime_ref" "$ROM_PATH"' "$work/launch.sh" | head -1 | cut -d: -f1)
gamedir_line=$(grep -n 'directory="${TEMP_DATA_DIR#/}"' "$work/launch.sh" | head -1 | cut -d: -f1)
[ "$snap_line" -lt "$shebang_patch_line" ] || { echo "mtime snapshot is not before the shebang patch"; exit 1; }
[ "$libinject_line" -lt "$restore_line" ] || { echo "mtime restore is not after the lib-inject block"; exit 1; }
[ "$restore_line" -lt "$gamedir_line" ] || { echo "mtime restore is not before GAMEDIR resolution"; exit 1; }
sh -n "$work/launch.sh" || { echo "edited launch.sh does not parse"; exit 1; }

# --- behavioral: the snapshot/restore wrapper (as built) preserves the launcher
# mtime across a real in-place content rewrite — the essence of the fix. Extract
# run_port's own snapshot (2 lines) and restore (2 lines), wrap a real rewrite of
# the launcher (changes the shebang, bumps mtime to now), and prove the content
# changed while the mtime did NOT. Portable mtime compare via -nt/-ot (no stat
# format / no GNU-vs-BSD sed -i). ---
fake="$SANDBOX/fakeport"; mkdir -p "$fake"
ROM_PATH="$fake/Game.sh"
printf '#!/bin/bash\necho hi\n' > "$ROM_PATH"
touch -t 202601010101 "$ROM_PATH"
ref="$fake/ref"; touch -r "$ROM_PATH" "$ref"   # ref := the launcher's original mtime

snap=$(grep -A1 'gt_launcher_mtime_ref="$(mktemp)"' "$work/launch.sh" || true)
rest=$(grep -A1 'touch -r "$gt_launcher_mtime_ref" "$ROM_PATH"' "$work/launch.sh" || true)
{
  echo "ROM_PATH=\"$ROM_PATH\""
  printf '%s\n' "$snap"
  echo 'printf "#!/usr/bin/env bash\necho hi\n" > "$ROM_PATH"'   # a real in-place edit + mtime bump
  printf '%s\n' "$rest"
} > "$fake/wrap.sh"
sh "$fake/wrap.sh"

assert_eq "$(head -1 "$ROM_PATH")" "#!/usr/bin/env bash" "launcher content was really patched"
[ ! "$ROM_PATH" -nt "$ref" ] || { echo "launcher mtime advanced past pre-patch value — rebuild-if-newer ports (Balatro/UFO 50) would re-patch"; exit 1; }
[ ! "$ROM_PATH" -ot "$ref" ] || { echo "launcher mtime moved backwards"; exit 1; }

# --- idempotency: rerunning the build neither re-inserts nor duplicates ---
GT_STAGE_EDIT_ONLY="$work" sh "$ROOT/build/build-pak.sh" portmaster
assert_eq "$(grep -c 'gt-h700-launcher-mtime' "$work/launch.sh")" "2" "launcher-mtime marker count stable"
assert_eq "$(grep -c 'gt_launcher_mtime_ref="$(mktemp)"' "$work/launch.sh")" "1" "one snapshot after rerun"
assert_eq "$(grep -c 'touch -r "$gt_launcher_mtime_ref" "$ROM_PATH"' "$work/launch.sh")" "1" "one restore after rerun"
sh -n "$work/launch.sh" || { echo "edited launch.sh does not parse after rerun"; exit 1; }
