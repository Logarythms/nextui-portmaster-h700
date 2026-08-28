#!/bin/sh
. "$(dirname -- "$0")/helpers.sh"

# F46: drop the bundled tg5040 Weston runtime image. Upstream builds its
# release zips from a get-weston branch that ships a 44.6MB custom
# files/weston_pkg_0.2.squashfs and a launch.sh bootstrap block that moves it
# into PortMaster/libs on first boot. Weston/Crusty ports cannot display on
# the RG SP at all (no DRM/KMS scanout — see h700-fixes.md "Ports this
# platform can't run"), so the image is pure dead weight in our zip and on the
# SD card. The build removes it from the assembled pak; upstream's bootstrap
# block is left intact because it is guarded by `[ -f ... ]` and becomes a
# no-op. If a future fix ever needs the runtime, harbourmaster can still
# download the official weston_pkg_0.2 image on demand.
work="$SANDBOX/pmpak"; mkdir -p "$work/files"
cp "$TROOT/fixtures/portmaster-pak-skeleton/pak.json.fixture" "$work/pak.json"
cp "$TROOT/fixtures/portmaster-pak-skeleton/launch.sh.fixture" "$work/launch.sh"
printf 'not-a-real-squashfs\n' > "$work/files/weston_pkg_0.2.squashfs"
printf 'unrelated payload\n' > "$work/files/keep.txt"

GT_STAGE_EDIT_ONLY="$work" sh "$ROOT/build/build-pak.sh" portmaster

# --- the weston image is gone; a sibling file under files/ is untouched ---
[ ! -e "$work/files/weston_pkg_0.2.squashfs" ] \
  || { echo "files/weston_pkg_0.2.squashfs still present after staging"; exit 1; }
[ -f "$work/files/keep.txt" ] || { echo "strip removed an unrelated file"; exit 1; }

# --- upstream's guarded bootstrap block is left intact (no-op without the file) ---
grep -qF 'if [ -f "$PAK_DIR/files/weston_pkg_0.2.squashfs" ]; then' "$work/launch.sh" \
  || { echo "upstream weston bootstrap guard missing from launch.sh"; exit 1; }
sh -n "$work/launch.sh" || { echo "edited launch.sh does not parse"; exit 1; }

# --- idempotency: a second run with the file already gone is a clean no-op ---
GT_STAGE_EDIT_ONLY="$work" sh "$ROOT/build/build-pak.sh" portmaster \
  || { echo "second staging run failed with the weston image absent"; exit 1; }
[ ! -e "$work/files/weston_pkg_0.2.squashfs" ] || { echo "weston image reappeared"; exit 1; }
[ -f "$work/files/keep.txt" ] || { echo "second run removed an unrelated file"; exit 1; }
echo "test-21 ok"
