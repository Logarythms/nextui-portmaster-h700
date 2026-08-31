#!/bin/sh
. "$(dirname -- "$0")/helpers.sh"

# F48: unit test of the standalone layout resolver (assets/gt-controller-layout.sh).
if ! command -v jq >/dev/null 2>&1; then
    echo "SKIP: no jq on this host; gt-controller-layout resolver test not run"
    exit 0
fi

res="$ROOT/assets/gt-controller-layout.sh"
export EMU_DIR="$SANDBOX/emu"
export USERDATA_PATH="$SANDBOX/userdata"
mkdir -p "$EMU_DIR/config" "$USERDATA_PATH/PORTS-portmaster"

# 4: no config, no marker -> nintendo
assert_eq "$(sh "$res" 'Sonic 1.sh')" "nintendo" "default should be nintendo"

# 2: global xbox
printf '{"gt-controller-layout":"xbox"}' > "$EMU_DIR/config/config.json"
assert_eq "$(sh "$res" 'Sonic 1.sh')" "xbox" "global xbox should win over default"

# 1: per-game nintendo overrides global xbox
printf '{"gt-controller-layout":"xbox","gt-port-layout":{"Sonic 1.sh":"nintendo"}}' > "$EMU_DIR/config/config.json"
assert_eq "$(sh "$res" 'Sonic 1.sh')" "nintendo" "per-game should win over global"
assert_eq "$(sh "$res" 'Other.sh')" "xbox" "unlisted port falls back to global"

# 3: malformed JSON -> next tier (marker) -> nintendo
printf 'not json{' > "$EMU_DIR/config/config.json"
: > "$USERDATA_PATH/PORTS-portmaster/nintendo"
assert_eq "$(sh "$res" 'Sonic 1.sh')" "nintendo" "malformed json + marker -> nintendo"

# invalid stored value -> default
printf '{"gt-controller-layout":"playstation"}' > "$EMU_DIR/config/config.json"
rm -f "$USERDATA_PATH/PORTS-portmaster/nintendo"
assert_eq "$(sh "$res" 'Sonic 1.sh')" "nintendo" "invalid value -> default nintendo"

echo "test-24-controller-layout-resolve OK"
