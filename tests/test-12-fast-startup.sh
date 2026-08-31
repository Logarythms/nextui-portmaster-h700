#!/bin/sh
. "$(dirname -- "$0")/helpers.sh"

# F33: trim avoidable per-launch latency. Two independent edits, both spliced by
# build/build-pak.sh's edit_portmaster_launch.
#
#   gt-h700-fast-splash — run_port's "Starting <port>..." splash is a FOREGROUND
#     minui-presenter with a 3s timeout (show_message's numeric-timeout branch is
#     not backgrounded), so every port launch blocks a full 3s on a screen that
#     does no work before exec-ing the game. Cut to 1s. The call is KEPT and stays
#     FOREGROUND: show_message first kills the "Starting, please wait..."
#     forever-presenter, so a live presenter never overlaps the port's fb grab
#     (the F14/F15 mali present-path desync). Only the timeout changes.
#
#   gt-h700-skip-redundant-patch — patch_pylibs unpacks pylibs.zip once (the zip
#     is deleted on success) but re-ran two seds and TWO python3
#     disable_python_function.py spawns (~0.5s of python cold-start doing nothing)
#     on EVERY launch. Guard the patch block so it runs only when pylibs was
#     (re)extracted this launch (gt_fresh) or the .gt-patched marker is missing.
#     Self-healing is preserved: the marker is written AFTER patching (a crash
#     mid-patch re-patches next launch), and a pak upgrade's unzip-over ships a
#     fresh pylibs.zip so gt_fresh forces a re-patch of the new, unpatched files.
#     F48 (Tasks 4/5) added two more guarded pylibs patches (the platform-layout
#     and optionscene-layout gt_patch helpers), so patch_pylibs now makes FOUR
#     python3 spawns total (2 disable_python_function + 2 F48 helpers), all still
#     inside the same guard — steady-state per-launch cost is still zero.
work="$SANDBOX/pmpak"; mkdir -p "$work"
cp "$TROOT/fixtures/portmaster-pak-skeleton/pak.json.fixture" "$work/pak.json"
cp "$TROOT/fixtures/portmaster-pak-skeleton/launch.sh.fixture" "$work/launch.sh"
GT_STAGE_EDIT_ONLY="$work" sh "$ROOT/build/build-pak.sh" portmaster

# ---------- gt-h700-fast-splash ----------
assert_contains "$work/launch.sh" 'gt-h700-fast-splash'
# the 3s splash is gone; the 1s splash is present (fixed-string, ${..%.*} is regex)
grep -qF 'show_message "Starting ${ROM_NAME%.*}..." 1' "$work/launch.sh" \
  || { echo "1s splash line not present"; cat "$work/launch.sh"; exit 1; }
grep -qF 'show_message "Starting ${ROM_NAME%.*}..." 3' "$work/launch.sh" \
  && { echo "3s splash line still present"; exit 1; } || true
sh -n "$work/launch.sh" || { echo "edited launch.sh does not parse"; exit 1; }

# ---------- gt-h700-skip-redundant-patch: static structure ----------
assert_contains "$work/launch.sh" 'gt-h700-skip-redundant-patch'
# shellcheck disable=SC2016
assert_contains "$work/launch.sh" 'if \[ "\$gt_fresh" = 1 \] || \[ ! -f "\$EMU_DIR/pylibs/.gt-patched" \]; then'
# shellcheck disable=SC2016
assert_contains "$work/launch.sh" 'touch "\$EMU_DIR/pylibs/.gt-patched"'

# placement: gt_fresh is captured BEFORE unzip_pylibs consumes the zip, and both
# python3 disable calls sit strictly BETWEEN the guard `then` and the marker
# `touch` (i.e. inside the `if ... fi`).
fresh_line=$(grep -n 'gt_fresh=0' "$work/launch.sh" | head -1 | cut -d: -f1)
unzip_line=$(grep -n 'unzip_pylibs "\$EMU_DIR/pylibs.zip"' "$work/launch.sh" | head -1 | cut -d: -f1)
then_line=$(grep -n 'if \[ "\$gt_fresh" = 1 \]' "$work/launch.sh" | head -1 | cut -d: -f1)
py1_line=$(grep -n 'platform.py" portmaster_install' "$work/launch.sh" | head -1 | cut -d: -f1)
py2_line=$(grep -n 'harbour.py" _install_portmaster' "$work/launch.sh" | head -1 | cut -d: -f1)
touch_line=$(grep -n 'touch "\$EMU_DIR/pylibs/.gt-patched"' "$work/launch.sh" | head -1 | cut -d: -f1)
[ "$fresh_line" -lt "$unzip_line" ] || { echo "gt_fresh not captured before unzip_pylibs"; exit 1; }
[ "$then_line" -lt "$py1_line" ]  || { echo "platform.py disable not inside the guard"; exit 1; }
[ "$then_line" -lt "$py2_line" ]  || { echo "harbour.py disable not inside the guard"; exit 1; }
[ "$py1_line" -lt "$touch_line" ] || { echo "platform.py disable is after the marker touch"; exit 1; }
[ "$py2_line" -lt "$touch_line" ] || { echo "harbour.py disable is after the marker touch"; exit 1; }

# ---------- gt-h700-skip-redundant-patch: behavioral ----------
# Extract the built patch_pylibs and run it with fakes, proving the guard skips
# the python3 disables on a steady-state launch and re-runs them when pylibs is
# fresh or the marker is missing. python3/sed/unzip_pylibs are stubbed; only the
# guard's control flow is under test.
pp="$SANDBOX/pp"; mkdir -p "$pp"
awk '/^patch_pylibs\(\) \{/{p=1} p{print} p&&/^}$/{exit}' "$work/launch.sh" > "$pp/patch_pylibs.fn"
assert_contains "$pp/patch_pylibs.fn" 'gt-h700-skip-redundant-patch'

cat > "$pp/runner.sh" <<'RUNEOF'
set -u
EMU_DIR="$1"; PAK_DIR="$2"; PYCOUNT="$3"; FN="$4"
ROM_DIR="/roms"
unzip_pylibs() { rm -f "$EMU_DIR/pylibs.zip"; }   # the real one consumes the zip
python3() { printf 'x\n' >> "$PYCOUNT"; }          # count disable spawns
sed() { :; }                                        # files here are fakes
. "$FN"
patch_pylibs
RUNEOF

pycount() { if [ -s "$1" ]; then wc -l < "$1" | tr -d ' '; else echo 0; fi; }

# scenario A — steady state: zip already consumed, marker present -> NO python
rm -rf "$pp/emu"; mkdir -p "$pp/emu/pylibs/harbourmaster"; : > "$pp/emu/pylibs/.gt-patched"
: > "$pp/cnt"
sh "$pp/runner.sh" "$pp/emu" "$pp/pak" "$pp/cnt" "$pp/patch_pylibs.fn"
assert_eq "$(pycount "$pp/cnt")" "0" "steady-state launch spawns no python3"

# scenario B — fresh pylibs (first install / upgrade unzip-over): re-patch both
rm -rf "$pp/emu"; mkdir -p "$pp/emu/pylibs/harbourmaster"; : > "$pp/emu/pylibs.zip"
: > "$pp/cnt"
sh "$pp/runner.sh" "$pp/emu" "$pp/pak" "$pp/cnt" "$pp/patch_pylibs.fn"
assert_eq "$(pycount "$pp/cnt")" "4" "fresh pylibs re-patches all four guarded pylibs patches"
[ -f "$pp/emu/pylibs/.gt-patched" ] || { echo "marker not created after a fresh patch"; exit 1; }

# scenario C — self-heal: no zip AND no marker (e.g. crash mid-patch) -> re-patch
rm -rf "$pp/emu"; mkdir -p "$pp/emu/pylibs/harbourmaster"
: > "$pp/cnt"
sh "$pp/runner.sh" "$pp/emu" "$pp/pak" "$pp/cnt" "$pp/patch_pylibs.fn"
assert_eq "$(pycount "$pp/cnt")" "4" "missing marker self-heals (re-patches all four)"

# ---------- idempotency: rerunning the build neither re-inserts nor duplicates ----------
GT_STAGE_EDIT_ONLY="$work" sh "$ROOT/build/build-pak.sh" portmaster
assert_eq "$(grep -c 'gt-h700-fast-splash' "$work/launch.sh")" "1" "fast-splash inserted once"
assert_eq "$(grep -cF 'show_message "Starting ${ROM_NAME%.*}..." 1' "$work/launch.sh")" "1" "one 1s splash after rerun"
assert_eq "$(grep -c 'gt_fresh=0' "$work/launch.sh")" "1" "skip-redundant-patch guard inserted once"
sh -n "$work/launch.sh" || { echo "edited launch.sh does not parse after rerun"; exit 1; }
