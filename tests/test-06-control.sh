#!/bin/sh
. "$(dirname -- "$0")/helpers.sh"

# F19: pm_platform_helper stub. 2026-era port scripts (deltarune, Tunics!,
# the RHH GameMaker ports) call pm_platform_helper unguarded; the 2025.03
# runtime pinned through v0.3.2 predated it, so every such launch logged "command not
# found" (and a `set -e` script would die outright). Upstream's current
# implementation — read from a 2026 funcs.txt that a partial GUI self-update
# left on-device — is an effective no-op (PM_PIPE dialog-exit + printf ""),
# so a faithful stub is behavior-correct. It is appended to files/control.txt
# because install_control_txt re-installs that file into the live control
# folder at EVERY launch, which also makes the stub self-healing after a
# partial self-update replaces the live copy (observed 2026-08-23).
# Fixture is the REAL upstream files/control.txt from the ben16w 2.14.0 zip
# (byte-identical to 2.13.0's). Since the 2.14.0 base upstream's funcs.txt
# defines pm_platform_helper itself; the stub stays as belt-and-braces (it is
# sourced after funcs.txt, same behavior).
work="$SANDBOX/pmpak"; mkdir -p "$work"
cp "$TROOT/fixtures/portmaster-pak-skeleton/pak.json.fixture" "$work/pak.json"
cp "$TROOT/fixtures/portmaster-pak-skeleton/launch.sh.fixture" "$work/launch.sh"
cp "$TROOT/fixtures/portmaster-pak-skeleton/control.txt.fixture" "$work/control.txt"
GT_STAGE_EDIT_ONLY="$work" sh "$ROOT/build/build-pak.sh" portmaster

# --- stub appended: marker, function, no-op body, upstream content intact ---
assert_contains "$work/control.txt" 'gt-h700-pm-platform-helper'
assert_contains "$work/control.txt" 'pm_platform_helper() {'
assert_contains "$work/control.txt" 'printf ""'
# the PM_PIPE dialog-exit mirrors upstream's real body, but must be guarded:
# PortMasterDialogExit lives in PortMasterDialog.txt, which is not always
# sourced — an unguarded call would turn the no-op into a crash.
# shellcheck disable=SC2016
assert_contains "$work/control.txt" 'command -v PortMasterDialogExit'
# upstream content is preserved (append-only edit): the funcs.txt source
# line the stub must come AFTER (definition order: a later definition would
# be overridden if funcs.txt ever ships its own pm_platform_helper — ours
# must win only while the pinned funcs.txt lacks it, which append-after does).
# shellcheck disable=SC2016
assert_contains "$work/control.txt" '. $controlfolder/funcs.txt'
funcs_line=$(grep -n 'controlfolder/funcs.txt' "$work/control.txt" | head -1 | cut -d: -f1)
stub_line=$(grep -n 'pm_platform_helper() {' "$work/control.txt" | head -1 | cut -d: -f1)
[ "$funcs_line" -lt "$stub_line" ] || { echo "stub is not after the funcs.txt source line"; exit 1; }
sh -n "$work/control.txt" || { echo "edited control.txt does not parse"; exit 1; }

# --- idempotency ---
GT_STAGE_EDIT_ONLY="$work" sh "$ROOT/build/build-pak.sh" portmaster
assert_eq "$(grep -c 'pm_platform_helper() {' "$work/control.txt")" "1" "stub appended exactly once"
sh -n "$work/control.txt" || { echo "edited control.txt does not parse after rerun"; exit 1; }
