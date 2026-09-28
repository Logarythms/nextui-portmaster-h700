#!/bin/sh
# gt-button-map-rc11 (F65): Balatro-class ports (a first-run button wizard
# that saves an SDL mapping line to $BUTTON_MAP_FILE) record the pad GUID of
# the moment. NextUI rc11 gives the built-in pad a new, tagged GUID, so a map
# saved on older firmware silently stops matching. Move such a map aside; the
# port's own "no file -> run the button check" rule then asks the player once.
# Never edits the launcher (its mtime is a rebuild source, F32).
#   $1 = port launcher (.sh)   $2 = the port's GAMEDIR
# Only launchers that set BUTTON_MAP_FILE="$GAMEDIR/..." are considered.
launcher="$1"
gamedir="$2"
[ -f "$launcher" ] && [ -n "$gamedir" ] || exit 0
# shellcheck disable=SC2016  # literal $GAMEDIR in the launcher text is the point
rel=$(sed -n 's|^[[:space:]]*BUTTON_MAP_FILE="\$GAMEDIR/\([^"]*\)".*|\1|p' "$launcher" | head -n 1)
[ -n "$rel" ] || exit 0
map="$gamedir/$rel"
[ -f "$map" ] || exit 0
# The port's own reader: first non-comment, non-blank line.
line=$(grep -v '^[[:space:]]*#' "$map" | grep -m 1 '[^[:space:]]')
case "$line" in
    190000000100000001000000????0000,*)
        # pre-rc11 built-in pad ID (bus 0x19, vendor 1, product 1, untagged)
        if mv -f "$map" "$map.pre-rc11"; then
            echo "gt-h700: $(basename "$launcher" .sh) button map predates rc11 - the port will ask for its button check once"
        fi ;;
esac
exit 0
