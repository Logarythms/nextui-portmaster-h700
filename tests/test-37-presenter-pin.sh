#!/bin/sh
. "$(dirname -- "$0")/helpers.sh"

# F66: the pinned josegonzalez minui-presenter must be a build made against
# NextUI h700-rc11's libmsettings. rc10 turned GetMute/GetMutedBrightness/
# GetMutedColortemp/GetMutedVolume into header-only stubs, so the 0.13.0
# h700-nextui build (and anything before 0.13.4, the release pinned to rc11)
# dies on its first GetMute call with "symbol lookup error" — every pak
# message ("Starting, please wait...", "Unpacking files...", "Applying
# changes...") silently never appeared. Found from a 0.5.0 pre-release report;
# reproduced on the RG SP (rc11 PORTS.txt logged the error twice per launch).
#
# Like test-34, this guards the pins.sh <-> build-pak.sh wiring and adds a
# version floor so a later edit can't slide the pin back below 0.13.4. The
# on-device gate (LD_BIND_NOW=1 resolves every symbol; GUI and a port launch
# with the messages visible) is the behavioral proof.
PINS="$ROOT/pins.sh"
BUILD="$ROOT/build/build-pak.sh"

sh -n "$PINS" || { echo "pins.sh does not parse"; exit 1; }

for v in MP_URL MP_SHA256; do
  grep -q "^${v}=" "$PINS" || { echo "pins.sh missing definition: $v"; exit 1; }
  grep -q "\$${v}\b\|\${${v}}" "$BUILD" || { echo "build-pak.sh never references: $v"; exit 1; }
done

MP_URL=$(sed -n 's/^MP_URL="\(.*\)"$/\1/p' "$PINS")
MP_SHA256=$(sed -n 's/^MP_SHA256=\([0-9a-f]*\)$/\1/p' "$PINS")

case "$MP_URL" in
  https://github.com/josegonzalez/minui-presenter/releases/download/*/minui-presenter-h700-nextui) ;;
  *) echo "MP_URL is not the josegonzalez h700-nextui asset: $MP_URL"; exit 1 ;;
esac
assert_eq "${#MP_SHA256}" 64 "MP_SHA256 is a 64-hex-digit sha256"

ver=${MP_URL%/minui-presenter-h700-nextui}; ver=${ver##*/}
echo "$ver" | awk -F. '
  NF != 3 { exit 2 }
  { exit !(($1 > 0) || ($1 == 0 && $2 > 13) || ($1 == 0 && $2 == 13 && $3 >= 4)) }' \
  || { echo "minui-presenter pin $ver is older than 0.13.4 (pre-rc11 builds import GetMute*)"; exit 1; }

echo "PASS test-37-presenter-pin (pinned minui-presenter $ver)"
