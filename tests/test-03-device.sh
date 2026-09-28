#!/bin/sh
. "$(dirname -- "$0")/helpers.sh"

# E6/E7/E8 + F51: device profile ($DEVICE SKU token -> harbourmaster pin via
# $HOME/.config/.DEVICE + GT_PANEL_W/H panel exports; unknown/absent token =
# rg34xx-h 720x480, the RG SP profile = pre-F51 behavior), the opt-in GUI
# remap hook, the parametric resolution fallback, and controller-DB appends.
work="$SANDBOX/pmpak"; mkdir -p "$work"
cp "$TROOT/fixtures/portmaster-pak-skeleton/pak.json.fixture" "$work/pak.json"
cp "$TROOT/fixtures/portmaster-pak-skeleton/launch.sh.fixture" "$work/launch.sh"
cp "$TROOT/fixtures/portmaster-pak-skeleton/device_info.txt" "$work/device_info.txt"
cp "$TROOT/fixtures/portmaster-pak-skeleton/gamecontrollerdb_xbox.txt" "$work/gamecontrollerdb_xbox.txt"
cp "$TROOT/fixtures/portmaster-pak-skeleton/gamecontrollerdb_nintendo.txt" "$work/gamecontrollerdb_nintendo.txt"

# mapping source with one real-shaped line per layout, to prove the append path
dbdir="$SANDBOX/pmdb"; mkdir -p "$dbdir"
printf '%s\n' '# test mapping' '19000000010000000100000000016e01,ANBERNIC-keys,a:b0,b:b1,platform:Linux,' \
  > "$dbdir/gamecontrollerdb-h700-xbox.txt"
printf '%s\n' '# test mapping' '19000000010000000100000000016e01,ANBERNIC-keys,a:b1,b:b0,platform:Linux,' \
  > "$dbdir/gamecontrollerdb-h700-nintendo.txt"

GT_PM_DB_DIR="$dbdir" GT_STAGE_EDIT_ONLY="$work" sh "$ROOT/build/build-pak.sh" portmaster

# --- device profile: after the XDG mkdir, h700-guarded, $DEVICE-keyed ---
assert_contains "$work/launch.sh" 'gt-h700-device-pin'
# shellcheck disable=SC2016
assert_contains "$work/launch.sh" 'echo "$gt_pm_device" >"$HOME/.config/.DEVICE"'
assert_contains "$work/launch.sh" 'gt_pm_device=rg34xx-sp'
assert_contains "$work/launch.sh" 'gt_pm_device=rg35xx-sp'
# shellcheck disable=SC2016
assert_contains "$work/launch.sh" 'export GT_PANEL_W GT_PANEL_H'
# shellcheck disable=SC2016  # literal $XDG_DATA_HOME in the grep pattern is the point
xdg_line=$(grep -n 'mkdir -p "\$XDG_DATA_HOME"' "$work/launch.sh" | head -1 | cut -d: -f1)
pin_line=$(grep -n 'gt-h700-device-pin' "$work/launch.sh" | head -1 | cut -d: -f1)
[ "$xdg_line" -lt "$pin_line" ] || { echo "device pin is not after XDG mkdir"; exit 1; }

# --- device profile behavioral: extract the injected block and run it with
# a fake HOME per token. Every consumer contract in one string:
# "<.DEVICE content> <GT_PANEL_W> <GT_PANEL_H>". The block also runs the F52
# input-class detection, so it reads a fixture instead of /proc (the RG SP
# dump by default) and its breadcrumb/warning output is discarded here.
sed -n '/# gt-h700-device-pin/,/^fi$/p' "$work/launch.sh" > "$SANDBOX/pinblock.sh"
FIX="$TROOT/fixtures/input-devices"
run_pin() { # $1=DEVICE ('' = unset) $2=RGXX_MODEL ('' = unset) $3=input-devices fixture (default rgsp)
    fake="$SANDBOX/pinhome-$$"; rm -rf "$fake"; mkdir -p "$fake"
    env -i PATH="$PATH" HOME="$fake" PLATFORM=h700 ${1:+DEVICE="$1"} ${2:+RGXX_MODEL="$2"} \
        GT_INPUT_DEVICES_FILE="${3:-$FIX/rgsp.txt}" sh -c \
      ". \"$SANDBOX/pinblock.sh\" >/dev/null; printf '%s %s %s' \"\$(cat \"\$HOME/.config/.DEVICE\")\" \"\$GT_PANEL_W\" \"\$GT_PANEL_H\""
}
assert_eq "$(run_pin rg34xxsp)"  "rg34xx-sp 720 480"  "rg34xxsp profile"
assert_eq "$(run_pin rg35xxsp)"  "rg35xx-sp 640 480"  "rg35xxsp profile"
assert_eq "$(run_pin rg35xxh)"   "rg35xx-h 640 480"   "rg35xxh profile"
assert_eq "$(run_pin rgcubexx)"  "rg34xx-h 720 720"   "rgcubexx panel truth, nearest profile"
assert_eq "$(run_pin rgsp)"      "rg34xx-h 720 480"   "rgsp = RG SP profile"
# family-bucket tokens: what the current NextUI-h700 build actually emits
# (its launch.sh maps RG34xx*->rg34xx, RG35xx*->rg35xx, RG40xx*->rg40xx,
# RGcubexx->cube; device-read 2026-09-01) — the exact-SKU arms above follow
# the wiki and cover newer builds.
assert_eq "$(run_pin rg34xx)"    "rg34xx-h 720 480"   "rg34xx family bucket"
assert_eq "$(run_pin rg35xx)"    "rg35xx-plus 640 480" "rg35xx family bucket"
assert_eq "$(run_pin rg40xx)"    "rg40xx-h 640 480"   "rg40xx family bucket"
assert_eq "$(run_pin cube)"      "rg34xx-h 720 720"   "cube family bucket"
assert_eq "$(run_pin '')"        "rg34xx-h 720 480"   "absent \$DEVICE = pre-F51 behavior"
assert_eq "$(run_pin someflyer)" "rg34xx-h 720 480"   "unknown token = pre-F51 behavior"

# a run leaves no /tmp copy behind (busybox read must never see the proc file
# directly — see the gt_dev_tmp regression asserts below)
assert_eq "$(ls /tmp/gt-input-devices.* 2>/dev/null | wc -l | tr -d ' ')" "0" "input-class temp copy removed"

# --- F52 input class: js0 key-bitmap word -> GT_INPUT_CLASS, breadcrumb, fail-safe ---
run_class() { # $1=input-devices fixture path (may be missing) ; prints "<class>|<block stdout, newlines -> ;>"
    fake="$SANDBOX/classhome-$$"; rm -rf "$fake"; mkdir -p "$fake"
    env -i PATH="$PATH" HOME="$fake" PLATFORM=h700 GT_INPUT_DEVICES_FILE="$1" sh -c \
      ". \"$SANDBOX/pinblock.sh\" >\"$fake/out.txt\"; printf '%s|' \"\$GT_INPUT_CLASS\"; tr '\n' ';' <\"$fake/out.txt\""
}
assert_contains "$work/launch.sh" 'gt-h700-input-class'
# shellcheck disable=SC2016
assert_contains "$work/launch.sh" 'export GT_INPUT_CLASS'
# regression: the loop must read a cat copy, never the proc file itself —
# busybox read polls fd 0 before every byte and /proc/bus/input/devices only
# polls readable on input hotplug, so a direct read loop hangs launch.sh
# forever (found at the F52 RG SP gate; see build-pak.sh's gt_dev_tmp comment)
# shellcheck disable=SC2016
assert_not_contains "$work/launch.sh" 'done < "$gt_dev_file"'
# shellcheck disable=SC2016
assert_contains "$work/launch.sh" 'cat "$gt_dev_file" >"$gt_dev_tmp"'
out=$(run_class "$FIX/rgsp.txt")
assert_eq "${out%%|*}" "plain" "RG SP key set = plain"
case "$out" in *'gt-h700: input class plain (js0 key word dff000000000000)'*) ;; *) echo "missing plain breadcrumb: $out"; exit 1;; esac
case "$out" in *unrecognized*) echo "RG SP must not warn: $out"; exit 1;; esac
out=$(run_class "$FIX/rg34xxsp.txt")
assert_eq "${out%%|*}" "sticks" "RG34XXSP key set = sticks"
case "$out" in *'input class sticks (js0 key word 1fff000000000000)'*) ;; *) echo "missing sticks breadcrumb: $out"; exit 1;; esac
out=$(run_class "$FIX/unknown.txt")
assert_eq "${out%%|*}" "plain" "unknown key set falls back to plain"
case "$out" in *'unrecognized joystick key set [1ffe000000000000]'*) ;; *) echo "missing unknown warning: $out"; exit 1;; esac
out=$(run_class "$SANDBOX/does-not-exist")
assert_eq "${out%%|*}" "plain" "missing /proc node falls back to plain"
case "$out" in *'unrecognized joystick key set [none]'*) ;; *) echo "missing none warning: $out"; exit 1;; esac
# the block must not consume the launcher's $1 (ROM_PATH is read right after it)
out=$(env -i PATH="$PATH" HOME="$SANDBOX/argshome" PLATFORM=h700 GT_INPUT_DEVICES_FILE="$FIX/rgsp.txt" sh -c "mkdir -p \"\$HOME\"; . \"$SANDBOX/pinblock.sh\" >/dev/null; printf '%s' \"\$1\"" sh "/roms/Ports/Game.sh")
assert_eq "$out" "/roms/Ports/Game.sh" "pin block leaves \$1 intact"

# --- F53: RGXX_MODEL (exact SKU) first, DEVICE bucket second; class refines buckets ---
assert_eq "$(run_pin rg34xx RG34xxSP)"   "rg34xx-sp 720 480"  "model beats bucket"
assert_eq "$(run_pin rg34xx RGSP)"       "rg34xx-h 720 480"   "RGSP model = RG SP profile"
assert_eq "$(run_pin rg35xx RG35xxH)"    "rg35xx-h 640 480"   "RG35xxH model"
assert_eq "$(run_pin rg35xx RG35xx2024)" "rg35xx-plus 640 480" "unknown model falls to the bucket"
assert_eq "$(run_pin rg40xx RG40xxV)"    "rg40xx-v 640 480"   "RG40xxV model"
assert_eq "$(run_pin rg34xx '' "$FIX/rg34xxsp.txt")" "rg34xx-sp 720 480"  "rg34xx bucket + sticks -> rg34xx-sp"
assert_eq "$(run_pin rg35xx '' "$FIX/rg34xxsp.txt")" "rg35xx-h 640 480"   "rg35xx bucket + sticks -> rg35xx-h"
assert_eq "$(run_pin ''     '' "$FIX/rg34xxsp.txt")" "rg34xx-sp 720 480"  "unknown + sticks -> rg34xx-sp"
assert_eq "$(run_pin rgsp   '' "$FIX/rg34xxsp.txt")" "rg34xx-h 720 480"   "exact SKU is never refined"
assert_eq "$(run_pin rg40xx '' "$FIX/rg34xxsp.txt")" "rg40xx-h 640 480"   "rg40xx bucket unchanged by class"
assert_eq "$(run_pin rg34xx '' "$FIX/rgsp.txt")"     "rg34xx-h 720 480"   "rg34xx bucket + plain stays rg34xx-h"

# --- F56: RG35XX Pro is a two-stick SKU (issue #1: it was pinned to the stickless rg35xx-plus) ---
assert_eq "$(run_pin rg35xxpro)"        "rg35xx-h 640 480"    "rg35xxpro token"
assert_eq "$(run_pin rg35xx RG35xxPro)" "rg35xx-h 640 480"    "RG35xxPro model"
assert_eq "$(run_pin rg35xxplus)"       "rg35xx-plus 640 480" "rg35xxplus stays stickless"
assert_contains "$work/launch.sh" 'rg35xxpro)            gt_pm_device=rg35xx-h'
# stickless exact-SKU profile + a pad reporting sticks -> profile unchanged (exact SKUs are never
# refined) but a breadcrumb is printed; the CubeXX (pinned rg34xx-h for its 720x720 panel, has
# sticks) is exempt; a two-stick profile or a plain pad never warns
run_pin_out() { # $1=DEVICE ('' = unset) $2=RGXX_MODEL ('' = unset) $3=input-devices fixture; prints block stdout, newlines -> ;
    fake="$SANDBOX/pinout-$$"; rm -rf "$fake"; mkdir -p "$fake"
    env -i PATH="$PATH" HOME="$fake" PLATFORM=h700 ${1:+DEVICE="$1"} ${2:+RGXX_MODEL="$2"} \
        GT_INPUT_DEVICES_FILE="$3" sh -c ". \"$SANDBOX/pinblock.sh\" | tr '\n' ';'"
}
out=$(run_pin_out rg35xxplus '' "$FIX/rg34xxsp.txt")
case "$out" in *'gt-h700: WARNING: profile rg35xx-plus has no analog sticks'*) ;; *) echo "missing stick-mismatch warning: $out"; exit 1;; esac
assert_eq "$(run_pin rg35xxplus '' "$FIX/rg34xxsp.txt")" "rg35xx-plus 640 480" "exact SKU still not refined by the class"
out=$(run_pin_out cube '' "$FIX/rg34xxsp.txt")
case "$out" in *'WARNING: profile'*) echo "CubeXX must not warn: $out"; exit 1;; esac
out=$(run_pin_out rg35xxpro '' "$FIX/rg34xxsp.txt")
case "$out" in *'WARNING: profile'*) echo "a two-stick profile must not warn: $out"; exit 1;; esac
out=$(run_pin_out rg35xxplus '' "$FIX/rgsp.txt")
case "$out" in *'WARNING: profile'*) echo "a plain pad must never warn: $out"; exit 1;; esac

# --- F53: use-stickless hatch -> GT_ANALOG_STICKS=0 (tables untouched; only device_info's ANALOG_STICKS) ---
run_hatch() { # $1=userdata dir
    fake="$SANDBOX/hatchhome-$$"; rm -rf "$fake"; mkdir -p "$fake"
    env -i PATH="$PATH" HOME="$fake" PLATFORM=h700 USERDATA_PATH="$1" GT_INPUT_DEVICES_FILE="$FIX/rg34xxsp.txt" sh -c \
      ". \"$SANDBOX/pinblock.sh\" >\"$fake/out.txt\"; printf '%s|' \"\${GT_ANALOG_STICKS:-unset}\"; tr '\n' ';' <\"$fake/out.txt\""
}
ud="$SANDBOX/ud"; mkdir -p "$ud/PORTS-portmaster"; touch "$ud/PORTS-portmaster/use-stickless"
out=$(run_hatch "$ud")
assert_eq "${out%%|*}" "0" "use-stickless exports GT_ANALOG_STICKS=0"
case "$out" in *'use-stickless present'*) ;; *) echo "missing hatch log line: $out"; exit 1;; esac
ud2="$SANDBOX/ud2"; mkdir -p "$ud2/PORTS-portmaster"
out=$(run_hatch "$ud2")
assert_eq "${out%%|*}" "unset" "no flag = GT_ANALOG_STICKS unset"
assert_contains "$work/device_info.txt" 'gt-h700-stickless'
ov=$(grep -n 'gt-h700-stickless' "$work/device_info.txt" | head -1 | cut -d: -f1)
ex=$(grep -n '^export ANALOG_STICKS$' "$work/device_info.txt" | head -1 | cut -d: -f1)
[ "$((ov + 1))" = "$ex" ] || { echo "stickless override must sit right before export ANALOG_STICKS"; exit 1; }
grep 'gt-h700-stickless' "$work/device_info.txt" > "$SANDBOX/stickless.sh"
out=$(env -i PATH="$PATH" GT_ANALOG_STICKS=0 sh -c "ANALOG_STICKS=2; . \"$SANDBOX/stickless.sh\"; printf '%s' \"\$ANALOG_STICKS\"")
assert_eq "$out" "0" "hatch env overrides ANALOG_STICKS"
out=$(env -i PATH="$PATH" sh -c "ANALOG_STICKS=2; . \"$SANDBOX/stickless.sh\"; printf '%s' \"\$ANALOG_STICKS\"")
assert_eq "$out" "2" "no hatch env keeps upstream ANALOG_STICKS"

# --- F54: ANALOGSTICKS alias — OpenTTD's launcher spells the stick count
# without the underscore ($ANALOGSTICKS); device_info.txt never set it, so
# export it too, right after upstream's own export (i.e. after the
# use-stickless override resolves the value).
assert_eq "$(grep -c 'gt-h700-analogsticks' "$work/device_info.txt")" "1" "analogsticks alias present exactly once"
alias_line=$(grep -n 'gt-h700-analogsticks' "$work/device_info.txt" | head -1 | cut -d: -f1)
export_line=$(grep -n '^export ANALOG_STICKS$' "$work/device_info.txt" | head -1 | cut -d: -f1)
[ "$((export_line + 1))" = "$alias_line" ] || { echo "analogsticks alias must sit exactly one line after export ANALOG_STICKS"; exit 1; }
sed -n '/gt-h700-stickless/,/gt-h700-analogsticks/p' "$work/device_info.txt" > "$SANDBOX/analogsticks.sh"
out=$(env -i PATH="$PATH" GT_ANALOG_STICKS=0 sh -c "ANALOG_STICKS=2; . \"$SANDBOX/analogsticks.sh\"; printf '%s' \"\$ANALOGSTICKS\"")
assert_eq "$out" "0" "analogsticks alias follows the hatch override"
out=$(env -i PATH="$PATH" sh -c "ANALOG_STICKS=2; . \"$SANDBOX/analogsticks.sh\"; printf '%s' \"\$ANALOGSTICKS\"")
assert_eq "$out" "2" "analogsticks alias follows upstream ANALOG_STICKS without the hatch"
# a second edit run (scratch copy, so $work's later assertions stay on the
# first-run state) must not duplicate the alias line
scratch="$SANDBOX/pmpak-analogsticks2"; mkdir -p "$scratch"
cp "$work/pak.json" "$work/launch.sh" "$work/device_info.txt" "$scratch/"
GT_STAGE_EDIT_ONLY="$scratch" sh "$ROOT/build/build-pak.sh" portmaster
assert_eq "$(grep -c 'gt-h700-analogsticks' "$scratch/device_info.txt")" "1" "analogsticks alias idempotent on rerun"
# --- F62: DEVICE_HAS_ARMHF needs a 32-bit libdl behind the loader (issue #1: armhf-only ports offered, then dead) ---
assert_contains "$work/device_info.txt" 'gt-h700-no-armhf'
na=$(grep -n 'gt-h700-no-armhf' "$work/device_info.txt" | head -1 | cut -d: -f1)
ex=$(grep -n '^export DEVICE_HAS_ARMHF$' "$work/device_info.txt" | head -1 | cut -d: -f1)
[ "$na" -lt "$ex" ] || { echo "no-armhf probe must run before export DEVICE_HAS_ARMHF"; exit 1; }
sed -n "${na},$((na + 4))p" "$work/device_info.txt" > "$SANDBOX/noarmhf.sh"
out=$(env -i PATH="$PATH" GT_ARMHF_LIBDL="$SANDBOX/does-not-exist" sh -c "DEVICE_HAS_ARMHF=Y; . \"$SANDBOX/noarmhf.sh\"; printf '%s' \"\$DEVICE_HAS_ARMHF\"")
assert_eq "$out" "N" "armhf loader without a 32-bit libdl -> N"
: > "$SANDBOX/fake-libdl.so.2"
out=$(env -i PATH="$PATH" GT_ARMHF_LIBDL="$SANDBOX/fake-libdl.so.2" sh -c "DEVICE_HAS_ARMHF=Y; . \"$SANDBOX/noarmhf.sh\"; printf '%s' \"\$DEVICE_HAS_ARMHF\"")
assert_eq "$out" "Y" "a real 32-bit libdl keeps Y"
out=$(env -i PATH="$PATH" GT_ARMHF_LIBDL="$SANDBOX/does-not-exist" sh -c "DEVICE_HAS_ARMHF=N; . \"$SANDBOX/noarmhf.sh\"; printf '%s' \"\$DEVICE_HAS_ARMHF\"")
assert_eq "$out" "N" "N stays N"
# --- F62: lscpu is absent on BaseOS; the probe is silenced, DEVICE_CPU stays informational ---
assert_contains "$work/device_info.txt" 'gt-h700-lscpu'
# shellcheck disable=SC2016
assert_contains "$work/device_info.txt" 'DEVICE_CPU=$(lscpu 2>/dev/null | grep'
sh -n "$work/device_info.txt" || { echo "edited device_info.txt does not parse"; exit 1; }
# idempotent: a second build run must not duplicate either edit
GT_PM_DB_DIR="$dbdir" GT_STAGE_EDIT_ONLY="$work" sh "$ROOT/build/build-pak.sh" portmaster
assert_eq "$(grep -c 'gt-h700-no-armhf' "$work/device_info.txt")" 1 "no-armhf marker once"
assert_eq "$(grep -c 'gt-h700-lscpu' "$work/device_info.txt")" 1 "lscpu marker once"

# --- remap hook: after the 4-space pugwash-reboot rm, before the GUI loop ---
assert_contains "$work/launch.sh" 'gt-h700-remap-hook'
# shellcheck disable=SC2016
assert_contains "$work/launch.sh" 'use-remap'
hook_line=$(grep -n 'gt-h700-remap-hook' "$work/launch.sh" | head -1 | cut -d: -f1)
loop_line=$(grep -n '^    while true; do$' "$work/launch.sh" | head -1 | cut -d: -f1)
[ "$hook_line" -lt "$loop_line" ] || { echo "remap hook is not before the pugwash loop"; exit 1; }

# --- device_info fallback 640x480 -> ${GT_PANEL_W/H:-RG SP panel} ---
assert_contains "$work/device_info.txt" 'gt-h700-fallback'
# shellcheck disable=SC2016
assert_contains "$work/device_info.txt" 'DISPLAY_WIDTH=${GT_PANEL_W:-720}'
# shellcheck disable=SC2016
assert_contains "$work/device_info.txt" 'DISPLAY_HEIGHT=${GT_PANEL_H:-480}'
assert_not_contains "$work/device_info.txt" '^    DISPLAY_WIDTH=640$'

# behavioral: the edited fallback lines honor the exports and default to the
# RG SP panel without them.
grep 'gt-h700-fallback' "$work/device_info.txt" | sed 's/^ *//' > "$SANDBOX/fallback.sh"
out=$(env -i PATH="$PATH" GT_PANEL_W=640 GT_PANEL_H=480 sh -c ". \"$SANDBOX/fallback.sh\"; printf '%sx%s' \"\$DISPLAY_WIDTH\" \"\$DISPLAY_HEIGHT\"")
assert_eq "$out" "640x480" "fallback honors GT_PANEL_W/H"
out=$(env -i PATH="$PATH" sh -c ". \"$SANDBOX/fallback.sh\"; printf '%sx%s' \"\$DISPLAY_WIDTH\" \"\$DISPLAY_HEIGHT\"")
assert_eq "$out" "720x480" "fallback defaults to the RG SP panel"

# --- F65 gt-h700-rc11: NextUI rc11 check = the tagged GUID in the system libSDL2 ---
assert_contains "$work/launch.sh" 'gt-h700-rc11 (F65)'
# shellcheck disable=SC2016
assert_contains "$work/launch.sh" 'export GT_NEXTUI_RC11'
# order: gt-h700-syslib sets SYSTEM_LIB_DIR above the check that reads it
sys_line=$(grep -n 'h700) SYSTEM_LIB_DIR=' "$work/launch.sh" | head -1 | cut -d: -f1)
rc11_line=$(grep -n 'gt-h700-rc11 (F65)' "$work/launch.sh" | head -1 | cut -d: -f1)
[ "$sys_line" -lt "$rc11_line" ] || { echo "rc11 check runs before SYSTEM_LIB_DIR is set"; exit 1; }
libs="$SANDBOX/rc11libs"; mkdir -p "$libs/rc11" "$libs/rc10" "$libs/none"
{ printf 'ELF\000'; printf '%s' '19000000010000000100000000016e01,ANBERNIC-keys,a:b0,b:b1'; printf '\000tail'; } \
  > "$libs/rc11/libSDL2-2.0.so.0"
{ printf 'ELF\000'; printf '%s' '19000000010000000100000000010000,ODROID Go 2,a:b0'; printf '\000tail'; } \
  > "$libs/rc10/libSDL2-2.0.so.0"
run_rc11() { # $1=SYSTEM_LIB_DIR ; prints "<GT_NEXTUI_RC11>|<block stdout+stderr, newlines -> ;>"
    fake="$SANDBOX/rc11home-$$"; rm -rf "$fake"; mkdir -p "$fake"
    env -i PATH="$PATH" HOME="$fake" PLATFORM=h700 SYSTEM_LIB_DIR="$1" GT_INPUT_DEVICES_FILE="$FIX/rgsp.txt" sh -c \
      ". \"$SANDBOX/pinblock.sh\" >\"$fake/out.txt\" 2>&1; printf '%s|' \"\$GT_NEXTUI_RC11\"; tr '\n' ';' <\"$fake/out.txt\""
}
out=$(run_rc11 "$libs/rc11")
assert_eq "${out%%|*}" "1" "rc11 libSDL2 -> GT_NEXTUI_RC11=1"
case "$out" in *'gt-h700: NextUI pad layout rc11'*) ;; *) echo "missing rc11 log line: $out"; exit 1;; esac
case "$out" in *'older than rc11'*) echo "rc11 must not warn: $out"; exit 1;; esac
out=$(run_rc11 "$libs/rc10")
assert_eq "${out%%|*}" "0" "pre-rc11 libSDL2 -> GT_NEXTUI_RC11=0"
case "$out" in *'gt-h700: WARNING: this NextUI is older than rc11'*) ;; *) echo "missing old-firmware warning: $out"; exit 1;; esac
out=$(run_rc11 "$libs/none")
assert_eq "${out%%|*}" "0" "missing libSDL2 -> GT_NEXTUI_RC11=0"
case "$out" in *'No such file'*|*'cannot open'*|*"can't open"*) echo "missing lib must not print a shell error: $out"; exit 1;; esac

# --- controller DB appended, comments skipped ---
assert_contains "$work/gamecontrollerdb_xbox.txt" '19000000010000000100000000016e01,ANBERNIC-keys,a:b0'
assert_contains "$work/gamecontrollerdb_nintendo.txt" '19000000010000000100000000016e01,ANBERNIC-keys,a:b1'
assert_not_contains "$work/gamecontrollerdb_xbox.txt" '# test mapping'
assert_contains "$work/gamecontrollerdb_xbox.txt" 'Dummy Pad'   # the upstream DB content is kept

# --- F65: one class-free rc11 line per layout; F52's per-class copies are gone ---
[ ! -e "$work/gamecontrollerdb_xbox_sticks.txt" ] || { echo "F65: no _sticks DB copy may be staged"; exit 1; }
[ ! -e "$work/gamecontrollerdb_nintendo_sticks.txt" ] || { echo "F65: no _sticks DB copy may be staged"; exit 1; }
[ ! -e "$ROOT/assets/gamecontrollerdb-h700-sticks-xbox.txt" ] || { echo "F65: the sticks DB assets must be deleted"; exit 1; }
[ ! -e "$ROOT/assets/gamecontrollerdb-h700-sticks-nintendo.txt" ] || { echo "F65: the sticks DB assets must be deleted"; exit 1; }
# the real assets carry exactly one rc11 line each: the patch's own built-in
# mapping for xbox, a/b and x/y swapped for nintendo
rc11_rest='back:b6,start:b7,guide:b8,leftshoulder:b4,rightshoulder:b5,leftstick:b9,rightstick:b10,lefttrigger:a2,righttrigger:a5,leftx:a0,lefty:a1,rightx:a3,righty:a4,dpup:h0.1,dpdown:h0.4,dpleft:h0.8,dpright:h0.2,platform:Linux,'
assert_eq "$(grep -v '^#' "$ROOT/assets/gamecontrollerdb-h700-xbox.txt" | grep -c .)" "1" "one xbox data line"
assert_eq "$(grep -v '^#' "$ROOT/assets/gamecontrollerdb-h700-nintendo.txt" | grep -c .)" "1" "one nintendo data line"
assert_eq "$(grep -v '^#' "$ROOT/assets/gamecontrollerdb-h700-xbox.txt" | grep .)" \
  "19000000010000000100000000016e01,ANBERNIC-keys,a:b0,b:b1,x:b2,y:b3,$rc11_rest" "xbox rc11 line"
assert_eq "$(grep -v '^#' "$ROOT/assets/gamecontrollerdb-h700-nintendo.txt" | grep .)" \
  "19000000010000000100000000016e01,ANBERNIC-keys,a:b1,b:b0,x:b3,y:b2,$rc11_rest" "nintendo rc11 line"

# --- F65: set_controller_layout is upstream's again (no per-class pick) ---
assert_not_contains "$work/launch.sh" 'gt-h700-controller-db-class'
sed -n '/^set_controller_layout() {$/,/^}$/p' "$work/launch.sh" > "$SANDBOX/layoutfn.sh"
[ -s "$SANDBOX/layoutfn.sh" ] || { echo "set_controller_layout not extracted"; exit 1; }
fakepak="$SANDBOX/fakepak"; fakeemu="$SANDBOX/fakeemu"; mkdir -p "$fakepak/files" "$fakeemu"
printf 'plain nintendo\n'  > "$fakepak/files/gamecontrollerdb_nintendo.txt"
printf 'sticks nintendo\n' > "$fakepak/files/gamecontrollerdb_nintendo_sticks.txt"   # stale copy an unzip-over leaves behind
run_layout() { # $1=GT_INPUT_CLASS ('' = unset)
    env -i PATH="$PATH" PAK_DIR="$fakepak" EMU_DIR="$fakeemu" ${1:+GT_INPUT_CLASS="$1"} sh -c \
      ". \"$SANDBOX/layoutfn.sh\"; set_controller_layout nintendo >/dev/null; cat \"$fakeemu/gamecontrollerdb.txt\""
}
assert_eq "$(run_layout sticks)" "plain nintendo" "F65: sticks class uses the one rc11 DB (stale _sticks copy ignored)"
assert_eq "$(run_layout plain)"  "plain nintendo" "plain class installs the plain DB"
assert_eq "$(run_layout '')"     "plain nintendo" "absent class = plain DB"

sh -n "$work/launch.sh" || { echo "edited launch.sh does not parse"; exit 1; }

# --- idempotency (append must GUID-dedupe) ---
GT_PM_DB_DIR="$dbdir" GT_STAGE_EDIT_ONLY="$work" sh "$ROOT/build/build-pak.sh" portmaster
assert_eq "$(grep -c 'gt-h700-device-pin' "$work/launch.sh")" "1" "device pin idempotent"
assert_eq "$(grep -c 'gt-h700-input-class' "$work/launch.sh")" "1" "input-class marker idempotent"
assert_eq "$(grep -c 'gt-h700-remap-hook' "$work/launch.sh")" "1" "remap hook idempotent"
assert_eq "$(grep -c 'gt-h700-fallback' "$work/device_info.txt")" "2" "fallback edit idempotent (one marker per line, two lines)"
assert_eq "$(grep -c 'gt-h700-stickless' "$work/device_info.txt")" "1" "stickless edit idempotent"
assert_eq "$(grep -c '^19000000010000000100000000016e01,' "$work/gamecontrollerdb_xbox.txt")" "1" "db append dedupes by GUID"
assert_eq "$(grep -c '^19000000010000000100000000016e01,' "$work/gamecontrollerdb_nintendo.txt")" "1" "nintendo db append dedupes by GUID"
assert_eq "$(grep -c 'gt-h700-rc11 (F65)' "$work/launch.sh")" "1" "rc11 check inserted once"
[ ! -e "$work/gamecontrollerdb_xbox_sticks.txt" ] || { echo "F65: restage must not create a _sticks copy"; exit 1; }
sh -n "$work/launch.sh" || { echo "edited launch.sh does not parse after rerun"; exit 1; }

# --- header-only mapping source (the pre-gate state) must be a clean no-op ---
# Isolated source dir, NOT the real repo mapping files: the on-device gate
# has since filled this repo's gamecontrollerdb-h700-*.txt files with real
# data lines, so this sub-test needs its own still-header-only source to
# exercise the no-op path deterministically, independent of that mutable
# repo state.
work2="$SANDBOX/pmpak2"; mkdir -p "$work2"
cp "$TROOT/fixtures/portmaster-pak-skeleton/pak.json.fixture" "$work2/pak.json"
cp "$TROOT/fixtures/portmaster-pak-skeleton/launch.sh.fixture" "$work2/launch.sh"
cp "$TROOT/fixtures/portmaster-pak-skeleton/gamecontrollerdb_xbox.txt" "$work2/gamecontrollerdb_xbox.txt"
headeronly_dbdir="$SANDBOX/pmdb-headeronly"; mkdir -p "$headeronly_dbdir"
printf '%s\n' '# header only, no data lines' > "$headeronly_dbdir/gamecontrollerdb-h700-xbox.txt"
before=$(wc -l < "$work2/gamecontrollerdb_xbox.txt")
GT_PM_DB_DIR="$headeronly_dbdir" GT_STAGE_EDIT_ONLY="$work2" sh "$ROOT/build/build-pak.sh" portmaster
after=$(wc -l < "$work2/gamecontrollerdb_xbox.txt")
assert_eq "$before" "$after" "header-only mapping file appends nothing"
