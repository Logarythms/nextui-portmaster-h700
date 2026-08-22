#!/bin/sh
. "$(dirname -- "$0")/helpers.sh"

# E3: SYSTEM_LIB_DIR generalization. On h700 the system SDL2 stack lives in
# NextUI's .system tree (BaseOS ships no SDL2); on TrimUI it is /usr/trimui/lib.
# NOTE: fixtures are stored as launch.sh.fixture / pak.json.fixture (not
# .sh/.json) because the real upstream launch.sh trips shellcheck style
# warnings that would fail a `find . -name '*.sh'` shellcheck sweep; the
# test copies them to proper names in $SANDBOX before running the build
# script (mirrors test-01-edits.sh's cp pattern).
work="$SANDBOX/pmpak"; mkdir -p "$work"
cp "$TROOT/fixtures/portmaster-pak-skeleton/pak.json.fixture" "$work/pak.json"
cp "$TROOT/fixtures/portmaster-pak-skeleton/launch.sh.fixture" "$work/launch.sh"
GT_STAGE_EDIT_ONLY="$work" sh "$ROOT/build/build-pak.sh" portmaster

# --- case block present, before the export that uses it; sets BOTH vars
# per branch (PM_PYSDL2_DIR added round 2 — F3: pysdl2's vendored dll.py
# cannot handle a multi-entry PYSDL2_DLL_PATH, so h700's dir must be the
# pak's own self-sufficient lib/) ---
assert_contains "$work/launch.sh" 'gt-h700-syslib'
# shellcheck disable=SC2016
assert_contains "$work/launch.sh" 'h700) SYSTEM_LIB_DIR="$SDCARD_PATH/.system/h700/lib"; PM_PYSDL2_DIR="$PAK_DIR/lib" ;;'
# shellcheck disable=SC2016
assert_contains "$work/launch.sh" '*) SYSTEM_LIB_DIR="/usr/trimui/lib"; PM_PYSDL2_DIR="/usr/trimui/lib" ;;'
case_line=$(grep -n 'gt-h700-syslib:' "$work/launch.sh" | head -1 | cut -d: -f1)
ld_line=$(grep -n 'export LD_LIBRARY_PATH=' "$work/launch.sh" | head -1 | cut -d: -f1)
[ "$case_line" -lt "$ld_line" ] || { echo "case block is not before LD_LIBRARY_PATH export"; exit 1; }

# --- exports rewritten ---
# shellcheck disable=SC2016
assert_contains "$work/launch.sh" 'export LD_LIBRARY_PATH="$PAK_DIR/lib:$SYSTEM_LIB_DIR:$LD_LIBRARY_PATH"'
# shellcheck disable=SC2016
assert_contains "$work/launch.sh" 'export PYSDL2_DLL_PATH="$PM_PYSDL2_DIR"'
assert_not_contains "$work/launch.sh" 'export PYSDL2_DLL_PATH="/usr/trimui/lib"'
# the round-1 shape (single-dir reuse of SYSTEM_LIB_DIR) must be gone too
# shellcheck disable=SC2016
assert_not_contains "$work/launch.sh" 'export PYSDL2_DLL_PATH="$SYSTEM_LIB_DIR"'
# shellcheck disable=SC2016
assert_not_contains "$work/launch.sh" 'export LD_LIBRARY_PATH="\$PAK_DIR/lib:/usr/trimui/lib'

# --- gt-h700-sdl-core: h700-only launch-time sync of core SDL2 (NOT
# SDL2_image — NextUI's build lacks JPEG support; that ships from bullseye
# at staging instead), placed right after the case block ---
assert_contains "$work/launch.sh" 'gt-h700-sdl-core'
# shellcheck disable=SC2016
assert_contains "$work/launch.sh" 'if \[ "$PLATFORM" = "h700" \] && \[ -f "$SYSTEM_LIB_DIR/libSDL2-2\.0\.so\.0" \]; then'
# shellcheck disable=SC2016
assert_contains "$work/launch.sh" 'cp -f "$SYSTEM_LIB_DIR/libSDL2-2.0.so.0" "$PAK_DIR/lib/"'
# SDL2_image must NOT be launch-time-synced from the system dir: NextUI's
# build lacks JPEG support (round-2 amendment) — a JPEG-capable SDL2_image
# ships from bullseye at staging instead (round 3).
assert_not_contains "$work/launch.sh" 'libSDL2_image'
esac_line=$(grep -n '^esac$' "$work/launch.sh" | head -1 | cut -d: -f1)
sdlcore_line=$(grep -n 'gt-h700-sdl-core' "$work/launch.sh" | head -1 | cut -d: -f1)
[ "$esac_line" -lt "$sdlcore_line" ] || { echo "gt-h700-sdl-core is not after the case block"; exit 1; }
[ "$sdlcore_line" -lt "$ld_line" ] || { echo "gt-h700-sdl-core is not before LD_LIBRARY_PATH export"; exit 1; }

# --- inject function replaced, name + callers preserved ---
assert_contains "$work/launch.sh" 'gt-h700-syslib-inject'
assert_eq "$(grep -c 'inject_trimui_lib_path() {' "$work/launch.sh")" "1" "one function definition"
assert_eq "$(grep -c '| inject_trimui_lib_path' "$work/launch.sh")" "2" "both upstream call sites intact"
# the old hardcoded per-line append body must be gone
assert_not_contains "$work/launch.sh" ':/usr/trimui/lib"|g'
sh -n "$work/launch.sh" || { echo "edited launch.sh does not parse"; exit 1; }

# --- idempotency ---
GT_STAGE_EDIT_ONLY="$work" sh "$ROOT/build/build-pak.sh" portmaster
assert_eq "$(grep -c 'gt-h700-syslib:' "$work/launch.sh")" "1" "syslib case idempotent"
assert_eq "$(grep -c 'gt-h700-sdl-core' "$work/launch.sh")" "1" "sdl-core sync idempotent"
assert_eq "$(grep -c 'gt-h700-syslib-inject' "$work/launch.sh")" "1" "inject splice idempotent"
assert_eq "$(grep -c 'inject_trimui_lib_path() {' "$work/launch.sh")" "1" "still one definition after rerun"
sh -n "$work/launch.sh" || { echo "edited launch.sh does not parse after rerun"; exit 1; }
