#!/bin/sh
. "$(dirname -- "$0")/helpers.sh"

# F29: harbourmaster recreates its default *.source.json files ONLY on
# first-run or a config-version migration. A config dir that kept
# config.json (first-run:false, version:2) but lost the source files is
# stuck forever: zero sources -> every port "unknown" -> all lists empty
# and Featured shows a bogus internet-required message (featured/porters/
# ports_info fetch independently of sources, masking the cause). Observed
# 2026-08-23 after a half-applied upstream self-update deleted the source
# files and a recovery restored config.json without them. run_portmaster_gui
# now restores the pinned defaults (files/gt-source-defaults/) whenever
# config.json exists but no *.source.json does.
work="$SANDBOX/pmpak"; mkdir -p "$work"
cp "$TROOT/fixtures/portmaster-pak-skeleton/pak.json.fixture" "$work/pak.json"
cp "$TROOT/fixtures/portmaster-pak-skeleton/launch.sh.fixture" "$work/launch.sh"
GT_STAGE_EDIT_ONLY="$work" sh "$ROOT/build/build-pak.sh" portmaster

assert_contains "$work/launch.sh" 'gt-h700-source-heal'
assert_contains "$work/launch.sh" 'gt-source-defaults'
sh -n "$work/launch.sh" || { echo "edited launch.sh does not parse"; exit 1; }
# placement: inside run_portmaster_gui, before pugwash starts
func_line=$(grep -n '^run_portmaster_gui() {' "$work/launch.sh" | head -1 | cut -d: -f1)
heal_line=$(grep -n 'gt-h700-source-heal' "$work/launch.sh" | head -1 | cut -d: -f1)
pugwash_line=$(grep -n '^        pugwash --debug' "$work/launch.sh" | head -1 | cut -d: -f1)
[ "$func_line" -lt "$heal_line" ] || { echo "source-heal hook is not inside run_portmaster_gui"; exit 1; }
[ "$heal_line" -lt "$pugwash_line" ] || { echo "source-heal hook is not before the pugwash start"; exit 1; }

# the shipped defaults must match harbourmaster's own HM_SOURCE_DEFAULTS
# (pinned pylibs 2025.03): both sources, fetch-on-next-load state.
src020="$ROOT/assets/gt-source-defaults/020_portmaster.source.json"
src021="$ROOT/assets/gt-source-defaults/021_portmaster.multiverse.source.json"
assert_contains "$src020" '"prefix": "pm"'
assert_contains "$src020" 'PortsMaster/PortMaster-New'
assert_contains "$src020" '"last_checked": null'
assert_contains "$src021" '"prefix": "pmmv"'
assert_contains "$src021" 'PortsMaster-MV/PortMaster-MV-New'
assert_contains "$src021" '"last_checked": null'

# behavioral: the extracted hook must (1) restore both defaults when
# config.json exists with no *.source.json, (2) leave ANY surviving source
# file alone (never fight user-modified sources), (3) skip a fresh install
# (no config.json -> harbourmaster's own first-run path writes them).
sed -n '/# gt-h700-source-heal/,/^    fi$/p' "$work/launch.sh" > "$SANDBOX/hook.sh"
[ -s "$SANDBOX/hook.sh" ] || { echo "could not extract source-heal hook"; exit 1; }
fakepak="$SANDBOX/fakepak"; mkdir -p "$fakepak/files/gt-source-defaults"
cp "$src020" "$src021" "$fakepak/files/gt-source-defaults/"

emu1="$SANDBOX/emu1"; mkdir -p "$emu1/config"
echo '{}' > "$emu1/config/config.json"
PAK_DIR="$fakepak" EMU_DIR="$emu1" sh "$SANDBOX/hook.sh" >/dev/null
[ -f "$emu1/config/020_portmaster.source.json" ] || { echo "case 1: 020 not restored"; exit 1; }
[ -f "$emu1/config/021_portmaster.multiverse.source.json" ] || { echo "case 1: 021 not restored"; exit 1; }

emu2="$SANDBOX/emu2"; mkdir -p "$emu2/config"
echo '{}' > "$emu2/config/config.json"
echo 'user-modified' > "$emu2/config/020_portmaster.source.json"
PAK_DIR="$fakepak" EMU_DIR="$emu2" sh "$SANDBOX/hook.sh" >/dev/null
assert_contains "$emu2/config/020_portmaster.source.json" 'user-modified'
[ ! -f "$emu2/config/021_portmaster.multiverse.source.json" ] || { echo "case 2: healed despite surviving source"; exit 1; }

emu3="$SANDBOX/emu3"; mkdir -p "$emu3/config"
PAK_DIR="$fakepak" EMU_DIR="$emu3" sh "$SANDBOX/hook.sh" >/dev/null
[ ! -f "$emu3/config/020_portmaster.source.json" ] || { echo "case 3: healed a fresh install"; exit 1; }

# --- idempotency of the edit itself ---
GT_STAGE_EDIT_ONLY="$work" sh "$ROOT/build/build-pak.sh" portmaster
assert_eq "$(grep -c 'gt-h700-source-heal' "$work/launch.sh")" "1" "source-heal marker idempotent"
sh -n "$work/launch.sh" || { echo "edited launch.sh does not parse after rerun"; exit 1; }
