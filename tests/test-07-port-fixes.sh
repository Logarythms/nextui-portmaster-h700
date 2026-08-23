#!/bin/sh
. "$(dirname -- "$0")/helpers.sh"

# F27: port-fixes overlay. Some ports ship a broken binary for this device —
# tunics_pm's bundled libmodplug.so.1 dies on an illegal instruction (udf #0)
# the moment a map transition changes the tracker music (gdb-attach caught
# the SIGSEGV inside the port's own copy; bullseye's build fixed it live on
# hardware, 2026-08-23). The pak carries replacement files under
# files/port-fixes/<port-dir-name>/ mirroring the port's layout, and
# run_port overlays them before the port executes: re-applied every launch
# (a port reinstall self-heals), cmp-guarded (a fresh mtime would retrigger
# rebuild-if-newer ports — the F12 lesson).
work="$SANDBOX/pmpak"; mkdir -p "$work"
cp "$TROOT/fixtures/portmaster-pak-skeleton/pak.json.fixture" "$work/pak.json"
cp "$TROOT/fixtures/portmaster-pak-skeleton/launch.sh.fixture" "$work/launch.sh"
GT_STAGE_EDIT_ONLY="$work" sh "$ROOT/build/build-pak.sh" portmaster

assert_contains "$work/launch.sh" 'gt-h700-port-fixes'
# shellcheck disable=SC2016
assert_contains "$work/launch.sh" 'gt_fix_dir="$PAK_DIR/files/port-fixes/'
# the cmp guard is load-bearing (mtime churn protection), as is the h700 gate
# shellcheck disable=SC2016
assert_contains "$work/launch.sh" 'if ! cmp -s "$gt_fix_src" "$GAMEDIR/$gt_rel" 2>/dev/null; then'
# shellcheck disable=SC2016
assert_contains "$work/launch.sh" 'cp -fp "$gt_fix_src" "$GAMEDIR/$gt_rel"'
# placement: inside run_port — after GAMEDIR resolution, before the
# controller-layout pick and the port exec
gamedir_line=$(grep -n 'echo "Game dir is: \$GAMEDIR"' "$work/launch.sh" | head -1 | cut -d: -f1)
overlay_line=$(grep -n 'gt-h700-port-fixes' "$work/launch.sh" | head -1 | cut -d: -f1)
nintendo_line=$(grep -n 'nintendo_file=' "$work/launch.sh" | head -1 | cut -d: -f1)
# shellcheck disable=SC2016
bash_exec_line=$(grep -n '"\$PAK_DIR/bin/bash" "\$ROM_PATH"' "$work/launch.sh" | head -1 | cut -d: -f1)
[ "$gamedir_line" -lt "$overlay_line" ] || { echo "overlay is not after GAMEDIR resolution"; exit 1; }
[ "$overlay_line" -lt "$nintendo_line" ] || { echo "overlay is not before the controller-layout pick"; exit 1; }
[ "$overlay_line" -lt "$bash_exec_line" ] || { echo "overlay is not before the port exec"; exit 1; }
sh -n "$work/launch.sh" || { echo "edited launch.sh does not parse"; exit 1; }

# behavioral check of the overlay's shell fragment: extract run_port's
# overlay block into a scratch script and run it against a fake port dir —
# the replacement must copy once (content differs), then no-op (cmp equal),
# preserving the copied mtime both times.
fake="$SANDBOX/fake"; mkdir -p "$fake/pak/files/port-fixes/game/libs" "$fake/game/libs"
echo "good" > "$fake/pak/files/port-fixes/game/libs/lib.so.1"
touch -t 202601010101 "$fake/pak/files/port-fixes/game/libs/lib.so.1"
echo "broken" > "$fake/game/libs/lib.so.1"
sed -n '/gt_fix_dir=/,/^    fi$/p' "$work/launch.sh" > "$fake/overlay.sh"
PAK_DIR="$fake/pak" GAMEDIR="$fake/game" PLATFORM=h700 sh "$fake/overlay.sh" >/dev/null 2>&1 || true
assert_eq "$(cat "$fake/game/libs/lib.so.1")" "good" "overlay replaced the broken file"
# no-op proof: stamp a sentinel mtime on the (now content-equal) target; a
# faulty re-copy would reset it to the source's preserved 2026-01-01 stamp.
touch -t 202502020202 "$fake/game/libs/lib.so.1"
mt1=$(ls -la "$fake/game/libs/lib.so.1")
PAK_DIR="$fake/pak" GAMEDIR="$fake/game" PLATFORM=h700 sh "$fake/overlay.sh" >/dev/null 2>&1 || true
mt2=$(ls -la "$fake/game/libs/lib.so.1")
assert_eq "$mt1" "$mt2" "second overlay run is a no-op (cmp guard held)"

# --- idempotency of the edit itself ---
GT_STAGE_EDIT_ONLY="$work" sh "$ROOT/build/build-pak.sh" portmaster
assert_eq "$(grep -c 'gt_fix_dir=' "$work/launch.sh")" "1" "overlay hook inserted exactly once"
sh -n "$work/launch.sh" || { echo "edited launch.sh does not parse after rerun"; exit 1; }
