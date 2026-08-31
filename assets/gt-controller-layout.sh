#!/bin/sh
# gt-controller-layout (F48): resolve the effective controller layout for a
# launch. Echoes "nintendo" or "xbox". Single source of truth = PortMaster's
# config.json. Precedence high->low:
#   1. per-game   cfg.gt-port-layout["<ROM_NAME>"]   ($1)
#   2. global     cfg.gt-controller-layout
#   3. legacy     a "nintendo*" file in PORTS-portmaster   -> nintendo
#   4. factory    nintendo
# Every read fails safe to the next tier (missing file/key, malformed JSON,
# unrecognized value). Reads EMU_DIR + USERDATA_PATH from the launch env.
#   $1 = ROM_NAME (launcher filename, e.g. "Sonic 1.sh"); optional (GUI: omit).
rom_name=${1:-}
cfg="${EMU_DIR:-}/config/config.json"

valid() { [ "$1" = "nintendo" ] || [ "$1" = "xbox" ]; }

if [ -f "$cfg" ] && command -v jq >/dev/null 2>&1; then
    if [ -n "$rom_name" ]; then
        v=$(jq -r --arg n "$rom_name" '.["gt-port-layout"][$n] // empty' "$cfg" 2>/dev/null)
        if valid "$v"; then echo "$v"; exit 0; fi
    fi
    v=$(jq -r '.["gt-controller-layout"] // empty' "$cfg" 2>/dev/null)
    if valid "$v"; then echo "$v"; exit 0; fi
fi

if [ -n "${USERDATA_PATH:-}" ] && \
   [ -n "$(find "$USERDATA_PATH/PORTS-portmaster" -maxdepth 1 -iname 'nintendo*' -type f 2>/dev/null)" ]; then
    echo "nintendo"; exit 0
fi

echo "nintendo"
