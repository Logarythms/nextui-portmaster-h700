#!/bin/sh
. "$(dirname -- "$0")/helpers.sh"

# F65: Balatro-class ports (a first-run button wizard that saves an SDL
# mapping line to $BUTTON_MAP_FILE) record the pad GUID of the moment. NextUI
# rc11 gives the built-in pad a new, tagged GUID, so a map saved on older
# firmware silently stops matching. run_port calls files/gt-button-map-rc11.sh
# on rc11, which moves such a map aside; the port's own "no file -> ask" rule
# then runs the button check once. The launcher is never edited (its mtime is
# a Balatro rebuild source, F32).
work="$SANDBOX/pmpak"; mkdir -p "$work"
cp "$TROOT/fixtures/portmaster-pak-skeleton/pak.json.fixture" "$work/pak.json"
cp "$TROOT/fixtures/portmaster-pak-skeleton/launch.sh.fixture" "$work/launch.sh"
GT_STAGE_EDIT_ONLY="$work" sh "$ROOT/build/build-pak.sh" portmaster

assert_contains "$work/launch.sh" 'gt-h700-button-map-rc11 (F65)'
# shellcheck disable=SC2016
assert_contains "$work/launch.sh" '"$PAK_DIR/files/gt-button-map-rc11.sh" "$ROM_PATH" "$GAMEDIR"'
# placement: inside run_port — after GAMEDIR resolution, before the port exec
gamedir_line=$(grep -n 'echo "Game dir is: \$GAMEDIR"' "$work/launch.sh" | head -1 | cut -d: -f1)
hook_line=$(grep -n 'gt-h700-button-map-rc11 (F65)' "$work/launch.sh" | head -1 | cut -d: -f1)
# shellcheck disable=SC2016
bash_exec_line=$(grep -n '"\$PAK_DIR/bin/bash" "\$ROM_PATH"' "$work/launch.sh" | head -1 | cut -d: -f1)
[ "$gamedir_line" -lt "$hook_line" ] || { echo "hook is not after GAMEDIR resolution"; exit 1; }
[ "$hook_line" -lt "$bash_exec_line" ] || { echo "hook is not before the port exec"; exit 1; }
sh -n "$work/launch.sh" || { echo "edited launch.sh does not parse"; exit 1; }
GT_STAGE_EDIT_ONLY="$work" sh "$ROOT/build/build-pak.sh" portmaster
assert_eq "$(grep -c 'gt-h700-button-map-rc11 (F65)' "$work/launch.sh")" "1" "hook inserted exactly once"

# staged executable by do_portmaster (GT_STAGE_EDIT_ONLY skips staging, so assert the lines)
# shellcheck disable=SC2016
assert_contains "$ROOT/build/build-pak.sh" 'cp -f "$ASSETS/gt-button-map-rc11.sh" "$assembled/files/gt-button-map-rc11.sh"'
# shellcheck disable=SC2016
assert_contains "$ROOT/build/build-pak.sh" 'chmod +x "$assembled/files/gt-button-map-rc11.sh"'

# --- the helper, against a fake Balatro install ---
helper="$ROOT/assets/gt-button-map-rc11.sh"
[ -x "$helper" ] || { echo "helper missing/not executable"; exit 1; }
fake="$SANDBOX/fake"; mkdir -p "$fake/balatro/saves"
# shellcheck disable=SC2016  # the launcher text is literal on purpose
printf '%s\n' '#!/bin/bash' 'GAMEDIR="/$directory/ports/balatro"' 'FORCE_BUTTON_SETUP=0' \
    'BUTTON_MAP_FILE="$GAMEDIR/saves/controller-map.txt"' \
    'export BALATRO_PM_BUTTON_MAP_FILE="$BUTTON_MAP_FILE"' > "$fake/Balatro.sh"
cp "$fake/Balatro.sh" "$SANDBOX/Balatro.sh.orig"
touch -t 202601010000 "$fake/Balatro.sh" "$SANDBOX/ref"
map="$fake/balatro/saves/controller-map.txt"
launcher_untouched() {
    cmp -s "$fake/Balatro.sh" "$SANDBOX/Balatro.sh.orig" || { echo "launcher content changed"; exit 1; }
    if [ "$fake/Balatro.sh" -nt "$SANDBOX/ref" ] || [ "$fake/Balatro.sh" -ot "$SANDBOX/ref" ]; then
        echo "launcher mtime changed (would trigger a Balatro rebuild)"; exit 1
    fi
}

# 1. a map on the pre-rc11 built-in GUID is moved aside, with a log line
printf '%s\n' '# Balatro button setup.' '19000000010000000100000000010000,RG SP Gamepad,a:b3,b:b4,platform:Linux,' > "$map"
out=$("$helper" "$fake/Balatro.sh" "$fake/balatro")
[ ! -e "$map" ] || { echo "old-GUID map was not moved aside"; exit 1; }
assert_contains "$map.pre-rc11" '19000000010000000100000000010000,RG SP Gamepad'
case "$out" in *'gt-h700: Balatro button map predates rc11 - the port will ask for its button check once'*) ;;
    *) echo "missing log line: $out"; exit 1;; esac
launcher_untouched
# 2. a map the wizard saved on rc11 (tagged GUID) stays
printf '%s\n' '# Balatro button setup.' '19000000010000000100000000016e01,ANBERNIC-keys,a:b1,b:b0,platform:Linux,' > "$map"
"$helper" "$fake/Balatro.sh" "$fake/balatro" >/dev/null
assert_contains "$map" '19000000010000000100000000016e01,ANBERNIC-keys'
# 3. a skipped / timed-out check writes a comment-only file: nothing to move
printf '%s\n' '# Balatro button setup: skipped.' > "$map"
"$helper" "$fake/Balatro.sh" "$fake/balatro" >/dev/null
assert_contains "$map" 'skipped'
# 4. a map recorded on an external pad stays
printf '%s\n' '030000005e0400008e02000014010000,Xbox 360 Controller,a:b0,b:b1,platform:Linux,' > "$map"
"$helper" "$fake/Balatro.sh" "$fake/balatro" >/dev/null
assert_contains "$map" 'Xbox 360 Controller'
# 5. a launcher without BUTTON_MAP_FILE is never considered
printf '%s\n' '19000000010000000100000000010000,RG SP Gamepad,a:b3,platform:Linux,' > "$map"
printf '%s\n' '#!/bin/bash' 'GAMEDIR="/$directory/ports/balatro"' > "$SANDBOX/Other.sh"
"$helper" "$SANDBOX/Other.sh" "$fake/balatro" >/dev/null
assert_contains "$map" '19000000010000000100000000010000'
# 6. a missing map is a clean no-op
rm -f "$map"
"$helper" "$fake/Balatro.sh" "$fake/balatro" || { echo "missing map must exit 0"; exit 1; }
launcher_untouched

# --- the run_port hook waits for rc11 ---
sed -n '/gt-h700-button-map-rc11 (F65)/,/^    fi$/p' "$work/launch.sh" > "$SANDBOX/hook.sh"
mkdir -p "$SANDBOX/pak/files"; cp "$helper" "$SANDBOX/pak/files/"
printf '%s\n' '19000000010000000100000000010000,RG SP Gamepad,a:b3,platform:Linux,' > "$map"
PLATFORM=h700 GT_NEXTUI_RC11=0 PAK_DIR="$SANDBOX/pak" ROM_PATH="$fake/Balatro.sh" GAMEDIR="$fake/balatro" \
    sh "$SANDBOX/hook.sh" >/dev/null
[ -e "$map" ] || { echo "hook acted before rc11"; exit 1; }
PLATFORM=h700 GT_NEXTUI_RC11=1 PAK_DIR="$SANDBOX/pak" ROM_PATH="$fake/Balatro.sh" GAMEDIR="$fake/balatro" \
    sh "$SANDBOX/hook.sh" >/dev/null
[ ! -e "$map" ] || { echo "hook did not act on rc11"; exit 1; }

echo "test-36-rc11-button-map OK"
