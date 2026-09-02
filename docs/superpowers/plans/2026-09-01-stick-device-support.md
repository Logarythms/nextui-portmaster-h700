# Stick-Equipped h700 Devices (F52/F53) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the pak correct on stick-equipped h700 NextUI devices (RG34XXSP class): right triggers/stick clicks/Menu handling in every port class, sticks in native SDL ports via the controller DB, stick-to-keys in gptk ports via the shim, and a truthful 2-stick profile — while the RG SP path stays behaviorally unchanged.

**Architecture:** launch.sh classifies the joystick node's key bitmap into an *input class* (`plain`|`sticks`) once per launch and exports it; the controller-DB copy, the shim's raw-index table + Menu-echo index, and the profile-bucket refinement all key on that one variable. The F45 evdev path becomes a class-free evdev-code→slot table. Analog synthesis in the shim mirrors gptokeyb (same keys, defaults, deadzone semantics). Two knobs stay separate: the input class (hardware truth, drives tables) and the stick profile (policy, `use-stickless` hatch, never touches tables).

**Tech Stack:** POSIX sh (busybox ash on device, macOS sh for tests), awk injections in `build/build-pak.sh`, C (LD_PRELOAD shim `assets/gt-input-remap.c`, host-tested with `-DGT_REMAP_TEST`), docker arm64/armv7 builds, the repo's `tests/test-*.sh` suites (`make test`).

**Spec:** `docs/superpowers/specs/2026-09-01-stick-device-support-design.md` — read it first; Appendix A has the fixture dumps, Appendix B the measured table, Appendix C the gptokeyb reference.

## Global Constraints

- **RG SP unchanged.** With `GT_INPUT_CLASS=plain` (or absent) every table, file choice and code path equals today's. `plain` is also the fail-safe for anything unrecognized.
- **Exact values (from the spec):** key word `dff000000000000` = plain, `1fff000000000000` = sticks (fifth word from the right of the `js0` record's `B: KEY=` line). Stick raw-index table: 12→L3 slot 9, 13→L2 slot 10, 14→R2 slot 11, 15→R3 slot 12, park 0–2 and 16 at **17**; plain parks at **15**. Menu-echo raw index 14 (plain) / **16** (sticks). Slots L3=**9**, R3=**12**. Deadzone default **15000**, accepted range 1..32767, deflected iff |v| ≥ deadzone. Axes: 0 left X, 1 left Y, 2 right X, 3 right Y; negative = up/left. gptokeyb analog defaults: left `w s a d`, right `end home left right` (up down left right).
- **Controller-DB stick line** (nintendo; xbox swaps a/b and x/y to `a:b4,b:b3,x:b5,y:b6`):
  `19000000010000000100000000010000,Anbernic h700 Gamepad (sticks),a:b3,b:b4,x:b6,y:b5,back:b9,start:b10,guide:b11,leftshoulder:b7,rightshoulder:b8,lefttrigger:b13,righttrigger:b14,leftstick:b12,rightstick:b15,leftx:a0,lefty:a1,rightx:a2,righty:a3,dpup:h0.1,dpdown:h0.4,dpleft:h0.8,dpright:h0.2,platform:Linux,`
- **File names:** staged DB copies `files/gamecontrollerdb_{nintendo,xbox}_sticks.txt`; assets `assets/gamecontrollerdb-h700-sticks-{nintendo,xbox}.txt`; fixtures `tests/fixtures/input-devices/{rgsp,rg34xxsp,unknown}.txt`; flag files `$USERDATA_PATH/PORTS-portmaster/use-stickless` and `use-input-debug`; env `GT_INPUT_CLASS`, `GT_ANALOG_STICKS`, `GT_INPUT_DEVICES_FILE` (test seam only).
- **Injection hygiene (repo convention):** every launch.sh/device_info edit is an awk pass guarded by a `grep -q '<marker>'` so restaging is idempotent; markers here: `gt-h700-input-class`, `gt-h700-controller-db-class`, `gt-h700-input-debug`, `gt-h700-stickless`. Before replacing any anchored line, `grep -rn '<old literal>' tests/` (F48/F49 lesson).
- **Build hygiene:** `make shim` needs network + docker (run with the sandbox off); `file` both shim outputs after every rebuild (arm64 `.so`, `ELF 32-bit … ARM` `.armhf.so`) — the bullseye tag cache drifts arch per pull. `make pak` needs network.
- **Git:** feature branch `feat/stick-devices` (already created off `ae35d8b`); one commit per task; squash-merge to local main at the end; **no push, no tag** (Camille's bundle rule).
- **Sh portability:** the injected launch.sh code runs under busybox ash on device and under macOS `sh` in tests — POSIX only (no `[[ ]]`, no `${var//…}`, no `set --` inside the pin block because launch.sh reads `$1` after it).

**User decisions (already made):**
- Scope "B": buttons + native-port sticks + analog-to-key synthesis + true 2-stick profile (with the `use-stickless` hatch).
- Gate "B": RG SP regression gate only; stick support ships labelled **experimental**; a volunteer round stays in reserve.
- Approach 1: input class from the key bitmap with two measured tables (not computed-from-bitmap, not SKU-keyed).
- Wave 1 = F52 (Tasks 1–4) must stand alone; Wave 2 = F53 (Tasks 5–6) — the profile flip never ships without analog synthesis.
- Slots L3=9 / R3=12; park 17 on the stick table; Menu echo 16.
- Release-notes/README wording: terse `### Fixes` style, "Experimental — not yet verified on hardware".

---

## Wave 1 — F52

### Task 1: Input-device fixtures + input-class detection in launch.sh

**Goal:** launch.sh exports `GT_INPUT_CLASS=plain|sticks` from the `js0` node's key bitmap (fail-safe `plain` + warning), logs a breadcrumb, and test-03 proves it against real fixtures.

**Files:**
- Create: `tests/fixtures/input-devices/rgsp.txt`, `tests/fixtures/input-devices/rg34xxsp.txt`, `tests/fixtures/input-devices/unknown.txt`
- Modify: `build/build-pak.sh:141-186` (the `gt-h700-device-pin` awk injection inside `edit_portmaster_launch`)
- Modify: `tests/test-03-device.sh:31-60` (`run_pin` + new `run_class` assertions)

**Acceptance Criteria:**
- [ ] RG SP fixture → `GT_INPUT_CLASS=plain`, breadcrumb `gt-h700: input class plain (js0 key word dff000000000000)`, no warning
- [ ] RG34XXSP fixture → `sticks`, breadcrumb with `1fff000000000000`
- [ ] unknown-word fixture → `plain` + warning line containing `unrecognized joystick key set [1ffe000000000000]`
- [ ] missing file → `plain` + warning containing `[none]`
- [ ] the block still lives after `mkdir -p "$XDG_DATA_HOME"` and before `ROM_PATH="$1"`; `$1` is untouched; `sh -n` passes; restage idempotent (one marker)
- [ ] all existing test-03 profile assertions still pass

**Verify:** `make test` → `=== test-03-device.sh ===` with no `assert_` failure, ends `ALL TESTS PASSED`

**Steps:**

- [ ] **Step 1: Create the three fixtures**

Copy the two dumps verbatim from the spec's Appendix A (they are the real `/proc/bus/input/devices` of both devices; the trailing space after each `Handlers=` value is genuine kernel output — keep it). Create `tests/fixtures/input-devices/rgsp.txt`:

```
I: Bus=0000 Vendor=0000 Product=0000 Version=0000
N: Name="axp2202-pek"
P: Phys=m1kbd/input2
S: Sysfs=/devices/platform/soc/twi5/i2c-5/5-0034/axp2101-pek.0/input/input0
U: Uniq=
H: Handlers=kbd event0 
B: PROP=0
B: EV=100003
B: KEY=12c00000000000 0

I: Bus=0019 Vendor=0001 Product=0001 Version=0100
N: Name="ANBERNIC-keys"
P: Phys=gpio-keys-polled/input0
S: Sysfs=/devices/platform/soc/soc@03000000:gpio_keys/input/input1
U: Uniq=
H: Handlers=kbd js0 event1 
B: PROP=0
B: EV=20000b
B: KEY=400000000 dff000000000000 0 0 c000000000000 2
B: ABS=30038
B: FF=107030000 0

I: Bus=0019 Vendor=0001 Product=0001 Version=0100
N: Name="dierct-keys-polled"
P: Phys=dierct-keys-polled/input0
S: Sysfs=/devices/platform/dierct-keys-polled/input/input2
U: Uniq=
H: Handlers=kbd event2 
B: PROP=0
B: EV=3
B: KEY=c378000000000 c042e2100000

```

`tests/fixtures/input-devices/rg34xxsp.txt` is identical except the two `ANBERNIC-keys` lines:

```
B: KEY=400000000 1fff000000000000 0 0 c000000000000 2
B: ABS=3003c
```

`tests/fixtures/input-devices/unknown.txt` is the rg34xxsp file with a fabricated word (a hypothetical device missing one code):

```
B: KEY=400000000 1ffe000000000000 0 0 c000000000000 2
```

Check the fixtures: `grep -c 'js0' tests/fixtures/input-devices/*.txt` → `1` each; `diff tests/fixtures/input-devices/rgsp.txt tests/fixtures/input-devices/rg34xxsp.txt` → exactly the two KEY/ABS lines differ.

- [ ] **Step 2: Write the failing tests (test-03)**

In `tests/test-03-device.sh`, replace the existing `run_pin` helper (the block starting `sed -n '/# gt-h700-device-pin/,/^fi$/p'` … through the `run_pin()` definition) with this version — it pins the detection to a fixture, discards the block's stdout, and gains two optional parameters used by Task 6:

```sh
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
```

Then append, right after the last existing `run_pin` assertion (`"unknown token = pre-F51 behavior"`):

```sh
# --- F52 input class: js0 key-bitmap word -> GT_INPUT_CLASS, breadcrumb, fail-safe ---
run_class() { # $1=input-devices fixture path (may be missing) ; prints "<class>|<block stdout, newlines -> ;>"
    fake="$SANDBOX/classhome-$$"; rm -rf "$fake"; mkdir -p "$fake"
    env -i PATH="$PATH" HOME="$fake" PLATFORM=h700 GT_INPUT_DEVICES_FILE="$1" sh -c \
      ". \"$SANDBOX/pinblock.sh\" >\"$fake/out.txt\"; printf '%s|' \"\$GT_INPUT_CLASS\"; tr '\n' ';' <\"$fake/out.txt\""
}
assert_contains "$work/launch.sh" 'gt-h700-input-class'
# shellcheck disable=SC2016
assert_contains "$work/launch.sh" 'export GT_INPUT_CLASS'
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
```

Also add to the idempotency section (after `"device pin idempotent"`):

```sh
assert_eq "$(grep -c 'gt-h700-input-class' "$work/launch.sh")" "1" "input-class marker idempotent"
```

- [ ] **Step 3: Run test-03 to verify it fails**

Run: `sh tests/test-03-device.sh`
Expected: `assert_contains: 'gt-h700-input-class' not in …/launch.sh` (the existing assertions above it still pass).

- [ ] **Step 4: Inject the detection into the device-pin block**

In `build/build-pak.sh`, inside `edit_portmaster_launch`, the `gt-h700-device-pin` awk currently prints the block starting with `if [ "$PLATFORM" = "h700" ]; then` / `mkdir -p "$HOME/.config"` and then the `case "${DEVICE:-}" in`. Insert the detection between `mkdir -p "$HOME/.config"` and the `case`. The block, as it must read in the edited launch.sh:

```sh
    # gt-h700-input-class (F52): which measured input table applies. The js0
    # node's EV_KEY bitmap word for codes 256-319 is dff... on the RG SP
    # (304-312,314,315) and 1fff... on stick-equipped devices (304-316: the
    # L3/R3 clicks 313/316 shift every later SDL button index). Same GUID on
    # both, so this - not the controller DB - has to pick the table. Anything
    # unrecognized = plain (the RG SP tables, today's behavior) + a log line.
    gt_dev_file="${GT_INPUT_DEVICES_FILE:-/proc/bus/input/devices}"
    gt_key_word=; gt_injs=0
    if [ -r "$gt_dev_file" ]; then
        while IFS= read -r gt_line; do
            case "$gt_line" in
                "I:"*) gt_injs=0 ;;
                "H: Handlers="*js0*) gt_injs=1 ;;
                "B: KEY="*)
                    if [ "$gt_injs" = 1 ]; then
                        gt_w=${gt_line#B: KEY=}
                        if [ $(($(echo "$gt_w" | wc -w))) -ge 5 ]; then
                            gt_w=${gt_w% *}; gt_w=${gt_w% *}; gt_w=${gt_w% *}; gt_w=${gt_w% *}
                            gt_key_word=${gt_w##* }
                        else
                            gt_key_word=short
                        fi
                        break
                    fi ;;
            esac
        done < "$gt_dev_file"
    fi
    case "$gt_key_word" in
        dff000000000000)  GT_INPUT_CLASS=plain ;;
        1fff000000000000) GT_INPUT_CLASS=sticks ;;
        *)  GT_INPUT_CLASS=plain
            echo "gt-h700: unrecognized joystick key set [${gt_key_word:-none}] - using RG SP input tables; please run GT Probe and open an issue" ;;
    esac
    export GT_INPUT_CLASS
    echo "gt-h700: input class $GT_INPUT_CLASS (js0 key word ${gt_key_word:-none})"
```

As awk `print` statements (double quotes escaped, no single quotes anywhere — the awk program sits inside a sh single-quoted string), insert after the existing `print "    mkdir -p \"$HOME/.config\""` line:

```awk
      print "    # gt-h700-input-class (F52): which measured input table applies. The js0"
      print "    # node'\''s EV_KEY bitmap word for codes 256-319 is dff... on the RG SP"
      print "    # (304-312,314,315) and 1fff... on stick-equipped devices (304-316: the"
      print "    # L3/R3 clicks 313/316 shift every later SDL button index). Same GUID on"
      print "    # both, so this - not the controller DB - has to pick the table. Anything"
      print "    # unrecognized = plain (the RG SP tables, today'\''s behavior) + a log line."
      print "    gt_dev_file=\"${GT_INPUT_DEVICES_FILE:-/proc/bus/input/devices}\""
      print "    gt_key_word=; gt_injs=0"
      print "    if [ -r \"$gt_dev_file\" ]; then"
      print "        while IFS= read -r gt_line; do"
      print "            case \"$gt_line\" in"
      print "                \"I:\"*) gt_injs=0 ;;"
      print "                \"H: Handlers=\"*js0*) gt_injs=1 ;;"
      print "                \"B: KEY=\"*)"
      print "                    if [ \"$gt_injs\" = 1 ]; then"
      print "                        gt_w=${gt_line#B: KEY=}"
      print "                        if [ $(($(echo \"$gt_w\" | wc -w))) -ge 5 ]; then"
      print "                            gt_w=${gt_w% *}; gt_w=${gt_w% *}; gt_w=${gt_w% *}; gt_w=${gt_w% *}"
      print "                            gt_key_word=${gt_w##* }"
      print "                        else"
      print "                            gt_key_word=short"
      print "                        fi"
      print "                        break"
      print "                    fi ;;"
      print "            esac"
      print "        done < \"$gt_dev_file\""
      print "    fi"
      print "    case \"$gt_key_word\" in"
      print "        dff000000000000)  GT_INPUT_CLASS=plain ;;"
      print "        1fff000000000000) GT_INPUT_CLASS=sticks ;;"
      print "        *)  GT_INPUT_CLASS=plain"
      print "            echo \"gt-h700: unrecognized joystick key set [${gt_key_word:-none}] - using RG SP input tables; please run GT Probe and open an issue\" ;;"
      print "    esac"
      print "    export GT_INPUT_CLASS"
      print "    echo \"gt-h700: input class $GT_INPUT_CLASS (js0 key word ${gt_key_word:-none})\""
```

(The two `'\''` sequences are the existing repo idiom for an apostrophe inside the single-quoted awk program — the F51 block already uses one.) Extend the F51 comment above the injection with one sentence: "F52: the same block first classifies the joystick node's key bitmap into GT_INPUT_CLASS (plain|sticks), consumed by set_controller_layout, the shim, and the F53 bucket refinement."

- [ ] **Step 5: Run test-03, then the whole suite**

Run: `sh tests/test-03-device.sh && make test`
Expected: no `assert_` output from test-03; `ALL TESTS PASSED`. If the `$1`-intact assertion fails, something in the block used `set --` — it must not.

- [ ] **Step 6: Commit**

```bash
git add tests/fixtures/input-devices build/build-pak.sh tests/test-03-device.sh
git commit -m "feat: F52 — input-class detection from the joystick key bitmap (plain|sticks)"
```

---

### Task 2: Per-class controller-DB assets, staging, and the `set_controller_layout` suffix

**Goal:** Four staged DB files; `set_controller_layout` installs the `_sticks` copy when `GT_INPUT_CLASS=sticks`; the plain files are byte-identical to before.

**Files:**
- Create: `assets/gamecontrollerdb-h700-sticks-nintendo.txt`, `assets/gamecontrollerdb-h700-sticks-xbox.txt`
- Modify: `build/build-pak.sh` — `append_controllerdb` area (~line 1183: add `stage_controllerdb_classes`), the `GT_STAGE_EDIT_ONLY` branch (~1208-1214), the assembly (~1397-1398), and a new awk edit in `edit_portmaster_launch` (after the F48 `gt-h700-controller-layout-gui` block)
- Modify: `tests/test-03-device.sh` (mapping fixtures, staging asserts, `set_controller_layout` behavioral test, idempotency)

**Acceptance Criteria:**
- [ ] both new assets carry the exact stick line from Global Constraints (nintendo `a:b3,b:b4,x:b6,y:b5`, xbox `a:b4,b:b3,x:b5,y:b6`), header comments in the plain files' style
- [ ] edit-only staging produces `gamecontrollerdb_{xbox,nintendo}_sticks.txt` containing the sticks mapping line and NOT the plain line; the plain files contain only the plain line
- [ ] restage: exactly one data line per GUID in each of the four files
- [ ] edited `set_controller_layout` copies `gamecontrollerdb_<layout>_sticks.txt` when `GT_INPUT_CLASS=sticks`, the plain file otherwise (absent variable = plain); `sh -n` passes
- [ ] `grep -c gt-h700-controller-db-class` = 1 after restage

**Verify:** `make test` → `ALL TESTS PASSED`

**Steps:**

- [ ] **Step 1: Create the two assets**

`assets/gamecontrollerdb-h700-sticks-nintendo.txt`:

```
# Stick-equipped h700 NextUI devices (RG34XXSP class) SDL controller mapping —
# nintendo layout (a/b and x/y swapped vs xbox). Same GUID as the RG SP line
# (gamecontrollerdb-h700-nintendo.txt) — launch.sh picks the file per input
# class (F52), never by GUID. MEASURED from the RG34XXSP volunteer probe trace
# (2026-09-01, gt-joyprobe on NextUI's own SDL 2.28.5): the L3/R3 clicks
# (evdev 313/316) shift L2/R2 to b13/b14 and Menu's KEY_GOTO echo to b16;
# sticks a0..a3 = leftx lefty rightx righty, up/left = negative. One SDL
# mapping line per row; staging appends data lines verbatim (GUID-deduped).
19000000010000000100000000010000,Anbernic h700 Gamepad (sticks),a:b3,b:b4,x:b6,y:b5,back:b9,start:b10,guide:b11,leftshoulder:b7,rightshoulder:b8,lefttrigger:b13,righttrigger:b14,leftstick:b12,rightstick:b15,leftx:a0,lefty:a1,rightx:a2,righty:a3,dpup:h0.1,dpdown:h0.4,dpleft:h0.8,dpright:h0.2,platform:Linux,
```

`assets/gamecontrollerdb-h700-sticks-xbox.txt`: same header with "xbox layout" in the first line, data line:

```
19000000010000000100000000010000,Anbernic h700 Gamepad (sticks),a:b4,b:b3,x:b5,y:b6,back:b9,start:b10,guide:b11,leftshoulder:b7,rightshoulder:b8,lefttrigger:b13,righttrigger:b14,leftstick:b12,rightstick:b15,leftx:a0,lefty:a1,rightx:a2,righty:a3,dpup:h0.1,dpdown:h0.4,dpleft:h0.8,dpright:h0.2,platform:Linux,
```

- [ ] **Step 2: Write the failing tests (test-03)**

In the mapping-source setup near the top of `tests/test-03-device.sh` (after the two `printf … > "$dbdir/gamecontrollerdb-h700-…"` lines) add stick mapping sources with a *distinct* fake GUID so plain/stick lines are distinguishable in assertions:

```sh
printf '%s\n' '# test stick mapping' '190000005354494b530000000000000a,Stick Pad,a:b1,b:b0,leftx:a0,platform:Linux,' \
  > "$dbdir/gamecontrollerdb-h700-sticks-xbox.txt"
printf '%s\n' '# test stick mapping' '190000005354494b530000000000000a,Stick Pad,a:b0,b:b1,leftx:a0,platform:Linux,' \
  > "$dbdir/gamecontrollerdb-h700-sticks-nintendo.txt"
```

After the existing `# --- controller DB appended, comments skipped ---` assertions add:

```sh
# --- F52: per-class DB copies — forked from the PRISTINE upstream DB, stick line appended ---
assert_contains "$work/gamecontrollerdb_xbox_sticks.txt" '190000005354494b530000000000000a,Stick Pad,a:b1,b:b0,leftx:a0'
assert_contains "$work/gamecontrollerdb_nintendo_sticks.txt" '190000005354494b530000000000000a,Stick Pad,a:b0,b:b1,leftx:a0'
assert_contains "$work/gamecontrollerdb_xbox_sticks.txt" 'Dummy Pad'   # the upstream DB content is carried over
assert_not_contains "$work/gamecontrollerdb_xbox_sticks.txt" '190000004b4800000111000000010000'   # no plain line in the stick copy
assert_not_contains "$work/gamecontrollerdb_xbox.txt" '190000005354494b530000000000000a'         # no stick line in the plain file
assert_not_contains "$work/gamecontrollerdb_xbox_sticks.txt" '# test stick mapping'
# the real assets carry the measured stick fields
assert_contains "$ROOT/assets/gamecontrollerdb-h700-sticks-nintendo.txt" 'a:b3,b:b4,x:b6,y:b5,back:b9,start:b10,guide:b11,leftshoulder:b7,rightshoulder:b8,lefttrigger:b13,righttrigger:b14,leftstick:b12,rightstick:b15,leftx:a0,lefty:a1,rightx:a2,righty:a3,dpup:h0.1,dpdown:h0.4,dpleft:h0.8,dpright:h0.2,platform:Linux,'
assert_contains "$ROOT/assets/gamecontrollerdb-h700-sticks-xbox.txt" 'a:b4,b:b3,x:b5,y:b6,back:b9,start:b10,guide:b11,leftshoulder:b7,rightshoulder:b8,lefttrigger:b13,righttrigger:b14,leftstick:b12,rightstick:b15,leftx:a0'

# --- F52: set_controller_layout picks the per-class copy ---
assert_contains "$work/launch.sh" 'gt-h700-controller-db-class'
sed -n '/^set_controller_layout() {$/,/^}$/p' "$work/launch.sh" > "$SANDBOX/layoutfn.sh"
[ -s "$SANDBOX/layoutfn.sh" ] || { echo "set_controller_layout not extracted"; exit 1; }
fakepak="$SANDBOX/fakepak"; fakeemu="$SANDBOX/fakeemu"; mkdir -p "$fakepak/files" "$fakeemu"
printf 'plain nintendo\n'  > "$fakepak/files/gamecontrollerdb_nintendo.txt"
printf 'sticks nintendo\n' > "$fakepak/files/gamecontrollerdb_nintendo_sticks.txt"
run_layout() { # $1=GT_INPUT_CLASS ('' = unset)
    env -i PATH="$PATH" PAK_DIR="$fakepak" EMU_DIR="$fakeemu" ${1:+GT_INPUT_CLASS="$1"} sh -c \
      ". \"$SANDBOX/layoutfn.sh\"; set_controller_layout nintendo >/dev/null; cat \"$fakeemu/gamecontrollerdb.txt\""
}
assert_eq "$(run_layout sticks)" "sticks nintendo" "sticks class installs the _sticks DB copy"
assert_eq "$(run_layout plain)"  "plain nintendo"  "plain class installs the plain DB"
assert_eq "$(run_layout '')"     "plain nintendo"  "absent class = plain DB (pre-F52 behavior)"
```

And in the idempotency section (after the existing `"db append dedupes by GUID"`):

```sh
assert_eq "$(grep -c '^190000005354494b530000000000000a,' "$work/gamecontrollerdb_xbox_sticks.txt")" "1" "stick db append dedupes by GUID"
assert_eq "$(grep -c '^190000004b4800000111000000010000,' "$work/gamecontrollerdb_xbox_sticks.txt")" "0" "stick copy never gains the plain line on restage"
assert_eq "$(grep -c 'gt-h700-controller-db-class' "$work/launch.sh")" "1" "controller-db-class edit idempotent"
```

- [ ] **Step 3: Run test-03 to verify it fails**

Run: `sh tests/test-03-device.sh`
Expected: `assert_contains: '190000005354494b530000000000000a,Stick Pad…' not in …/gamecontrollerdb_xbox_sticks.txt` (file missing → grep fails → cat error is fine).

- [ ] **Step 4: Add the class staging helper and wire both build paths**

In `build/build-pak.sh`, right after `append_controllerdb()`'s closing brace, add:

```sh
stage_controllerdb_classes() { # $1=dir holding gamecontrollerdb_<layout>.txt $2=repo mapping dir
  # F52: stick-equipped devices need their own controller-DB line but share the
  # RG SP's GUID, so each layout gets a per-class COPY: <layout>_sticks.txt =
  # the upstream DB + the stick line. ORDER MATTERS: the copy must fork from the
  # PRISTINE upstream file BEFORE the plain RG SP line is appended, because
  # append_controllerdb dedupes by GUID and would otherwise skip the stick line.
  # On a restage the copy already exists (not re-forked) and both appends dedupe.
  for gt_l in xbox nintendo; do
    base="$1/gamecontrollerdb_$gt_l.txt"; sticks="$1/gamecontrollerdb_${gt_l}_sticks.txt"
    [ -f "$base" ] || continue
    [ -f "$sticks" ] || cp -f "$base" "$sticks"
    append_controllerdb "$2/gamecontrollerdb-h700-$gt_l.txt" "$base"
    append_controllerdb "$2/gamecontrollerdb-h700-sticks-$gt_l.txt" "$sticks"
  done
}
```

Replace the two `GT_STAGE_EDIT_ONLY` append blocks (`if [ -f "$GT_STAGE_EDIT_ONLY/gamecontrollerdb_xbox.txt" ]; then … fi` and its nintendo twin) with:

```sh
      pm_db_dir=${GT_PM_DB_DIR:-$ASSETS}
      stage_controllerdb_classes "$GT_STAGE_EDIT_ONLY" "$pm_db_dir"
```

Replace the two assembly-path `append_controllerdb "$ASSETS/gamecontrollerdb-h700-…"` lines with:

```sh
  stage_controllerdb_classes "$assembled/files" "$ASSETS"
```

- [ ] **Step 5: Edit `set_controller_layout` to honor the class**

In `edit_portmaster_launch`, after the `gt-h700-controller-layout-gui` block, add:

```sh
  # gt-h700-controller-db-class: F52 — stick-equipped devices install the
  # per-class DB copy (files/gamecontrollerdb_<layout>_sticks.txt, staged by
  # stage_controllerdb_classes). GT_INPUT_CLASS comes from the device-pin
  # block on the common path, so the GUI and run_port both inherit it; absent
  # or plain = the unchanged upstream path.
  if ! grep -q 'gt-h700-controller-db-class' "$f"; then
    awk '$0 == "    src=\"$PAK_DIR/files/gamecontrollerdb_$layout.txt\"" {
      print "    # gt-h700-controller-db-class (F52): stick devices get the per-class DB copy"
      print "    gt_db_suffix=; [ \"${GT_INPUT_CLASS:-plain}\" = sticks ] && gt_db_suffix=_sticks"
      print "    src=\"$PAK_DIR/files/gamecontrollerdb_${layout}${gt_db_suffix}.txt\""
      next
    }
    { print }' "$f" > "$f.awk.tmp" && mv "$f.awk.tmp" "$f"
  fi
```

- [ ] **Step 6: Run test-03 and the suite**

Run: `sh tests/test-03-device.sh && make test`
Expected: `ALL TESTS PASSED`. (test-24/25/26 grep `set_controller_layout "$gt_layout"` as a landmark — that line is untouched.)

- [ ] **Step 7: Commit**

```bash
git add assets/gamecontrollerdb-h700-sticks-nintendo.txt assets/gamecontrollerdb-h700-sticks-xbox.txt build/build-pak.sh tests/test-03-device.sh
git commit -m "feat: F52 — per-class controller DB (stick line, _sticks copies, class-keyed set_controller_layout)"
```

---

### Task 3: Shim — class-aware raw-index table, Menu-echo swallow, direct evdev slots, `l3`/`r3`

**Goal:** `gt-input-remap.so` honors `GT_INPUT_CLASS`: the stick table remaps 12→9/13→10/14→11/15→12 and parks 0–2 & 16 at 17; the HUD swallows raw 16 (not 14) on stick devices; the F45 evdev path maps evdev code→slot directly; gptk `l3`/`r3` bind slots 9/12. Plain behavior identical.

**Files:**
- Modify: `assets/gt-input-remap.c` (~lines 66-90 remap; 136-190 slots/evdev; 586-596 swallow; 1042-1080 evdev thread; 1141-1148 `gt_init`; test main 645-660, 700-712, 887-892, 904-919)
- Modify: `tests/test-05-input-remap.sh:3-15` (header comment only)
- Rebuild: `assets/gt-input-remap.so`, `assets/gt-input-remap.armhf.so`

**Acceptance Criteria:**
- [ ] host test (`cc -DGT_REMAP_TEST … && ./remap-test`) prints `remap ok` with: plain table unchanged (existing cases), stick table over raw 0..18, `gt_menu_swallow` 11+14 (plain) vs 11+16 (sticks) and 14 NOT swallowed on sticks, `gt_class_load` from env, `gt_evdev_code_slot` values incl. 313→9 / 316→12, direct-slot ≡ two-step on both tables, `l3`→9 `r3`→12 via `gt_button_slot` and via a parsed gptk line
- [ ] evdev thread uses `gt_evdev_code_slot` (no remaining `gt_evdev_code_sdl_index` symbol in the file)
- [ ] `file assets/gt-input-remap.so` → `ELF 64-bit LSB shared object, ARM aarch64`; `file assets/gt-input-remap.armhf.so` → `ELF 32-bit LSB shared object, ARM, EABI5`
- [ ] `make test` green

**Verify:** `make test` → `ALL TESTS PASSED`; `file assets/gt-input-remap.so assets/gt-input-remap.armhf.so`

**Steps:**

- [ ] **Step 1: Write the failing host tests**

In `assets/gt-input-remap.c`'s `main()` (inside `#ifdef GT_REMAP_TEST`), after the existing plain-table `cases[]` loop, add:

```c
    /* F52: the stick-class table (RG34XXSP volunteer trace, 2026-09-01). The
     * L3/R3 clicks (evdev 313/316) sit at raw 12/15 and push L2/R2/Menu-echo
     * up by one; park moves to 17 (one past the device's 17 buttons). */
    setenv("GT_INPUT_CLASS", "sticks", 1); gt_class_load();
    if (!gt_sticks_class) return fail("GT_INPUT_CLASS=sticks not loaded");
    {
        static const struct { unsigned char in, out; } scases[] = {
            {3, 1}, {4, 0}, {5, 2}, {6, 3}, {7, 4}, {8, 5}, {9, 6}, {10, 7}, {11, 8},
            {12, 9}, {13, 10}, {14, 11}, {15, 12},
            {0, 17}, {1, 17}, {2, 17}, {16, 17},
            {17, 17}, {18, 18},
        };
        for (i = 0; i < sizeof(scases) / sizeof(scases[0]); i++) {
            if (gt_remap(scases[i].in) != scases[i].out) {
                fprintf(stderr, "sticks remap(%u) = %u, want %u\n",
                        scases[i].in, gt_remap(scases[i].in), scases[i].out);
                return 1;
            }
        }
        if (!gt_menu_swallow(11) || !gt_menu_swallow(16)) return fail("sticks: swallow raw 11 and 16");
        if (gt_menu_swallow(14)) return fail("sticks: raw 14 is R2 and must NOT be swallowed");
        if (!gt_is_menu_button(11) || gt_is_menu_button(16)) return fail("sticks: Menu identity is raw 11 only");
    }
    setenv("GT_INPUT_CLASS", "plain", 1); gt_class_load();
    if (gt_sticks_class) return fail("GT_INPUT_CLASS=plain must select the RG SP table");
    unsetenv("GT_INPUT_CLASS"); gt_class_load();
    if (gt_sticks_class) return fail("absent GT_INPUT_CLASS must select the RG SP table");
    if (gt_menu_swallow(16)) return fail("plain: raw 16 must not be swallowed");
    if (gt_remap(14) != 15) return fail("plain: raw 14 still parks at 15");
```

Replace the F45 block (`if (gt_remap((unsigned char)gt_evdev_code_sdl_index(304)) != 1) …` through the `evdev 1 (ESC)` line) with:

```c
    /* F52: evdev code -> slot is DIRECT and device-independent (the codes are
     * the hardware truth; only the SDL index order differs between classes). */
    if (gt_evdev_code_slot(304) != 1)  return fail("evdev 304 -> A slot 1");
    if (gt_evdev_code_slot(305) != 0)  return fail("evdev 305 -> B slot 0");
    if (gt_evdev_code_slot(306) != 2)  return fail("evdev 306 -> Y slot 2");
    if (gt_evdev_code_slot(307) != 3)  return fail("evdev 307 -> X slot 3");
    if (gt_evdev_code_slot(308) != 4)  return fail("evdev 308 -> L1 slot 4");
    if (gt_evdev_code_slot(309) != 5)  return fail("evdev 309 -> R1 slot 5");
    if (gt_evdev_code_slot(310) != 6)  return fail("evdev 310 -> Select slot 6");
    if (gt_evdev_code_slot(311) != 7)  return fail("evdev 311 -> Start slot 7");
    if (gt_evdev_code_slot(313) != 9)  return fail("evdev 313 -> L3 slot 9");
    if (gt_evdev_code_slot(314) != 10) return fail("evdev 314 -> L2 slot 10");
    if (gt_evdev_code_slot(315) != 11) return fail("evdev 315 -> R2 slot 11");
    if (gt_evdev_code_slot(316) != 12) return fail("evdev 316 -> R3 slot 12");
    if (gt_evdev_code_slot(312) != -1) return fail("evdev 312 (Menu) is not a gameplay button");
    if (gt_evdev_code_slot(354) != -1) return fail("evdev 354 (GOTO) is not a gameplay button");
    if (gt_evdev_code_slot(1)   != -1) return fail("evdev 1 (ESC) is not a gameplay button");
    if (gt_evdev_code_slot(114) != -1) return fail("evdev 114 (VolDown) is not a gameplay button");
    /* consistency: the direct table equals SDL-index -> gt_remap on BOTH measured
     * tables (NextUI's SDL orders codes ascending after ESC/Vol at 0..2). */
    {
        static const int rgsp_code[]  = {304,305,306,307,308,309,310,311,314,315};
        static const int rgsp_idx[]   = {  3,  4,  5,  6,  7,  8,  9, 10, 12, 13};
        static const int stick_code[] = {304,305,306,307,308,309,310,311,313,314,315,316};
        static const int stick_idx[]  = {  3,  4,  5,  6,  7,  8,  9, 10, 12, 13, 14, 15};
        unsetenv("GT_INPUT_CLASS"); gt_class_load();
        for (i = 0; i < 10; i++)
            if (gt_evdev_code_slot(rgsp_code[i]) != (int)gt_remap((unsigned char)rgsp_idx[i]))
                return fail("direct evdev slot != plain two-step");
        setenv("GT_INPUT_CLASS", "sticks", 1); gt_class_load();
        for (i = 0; i < 12; i++)
            if (gt_evdev_code_slot(stick_code[i]) != (int)gt_remap((unsigned char)stick_idx[i]))
                return fail("direct evdev slot != sticks two-step");
        unsetenv("GT_INPUT_CLASS"); gt_class_load();
    }
```

In the F48 layout-swap block, after `if (gt_button_slot("l1") != 4) return fail("nintendo l1 slot moved");` (first occurrence, `gt_ab_swap = 0`), add:

```c
    if (gt_button_slot("l3") != 9 || gt_button_slot("r3") != 12) return fail("l3/r3 slots 9/12");
```

In the gptk-parsing block (the `gt_keymap m;` scope), after `if (!gt_gptk_line(&m, "up = up")) return fail("parse up=up");` add:

```c
        if (!gt_gptk_line(&m, "l3 = q")) return fail("parse l3=q");
        if (m.button_key[9].sym != 'q') return fail("l3 slot != q");
```

- [ ] **Step 2: Run the host test to verify it fails**

Run: `cc -DGT_REMAP_TEST -O2 -o /tmp/remap-test assets/gt-input-remap.c`
Expected: compile errors — `gt_class_load`, `gt_sticks_class`, `gt_evdev_code_slot` undeclared.

- [ ] **Step 3: Implement the class state and the two tables**

Replace `gt_remap()` (the `static unsigned char gt_remap(unsigned char b) { switch … }` at ~line 72) with:

```c
/* F52: which measured raw-index table applies. Loaded once from
 * GT_INPUT_CLASS (exported by launch.sh's gt-h700-input-class block, derived
 * from the joystick node's EV_KEY bitmap): "sticks" = the RG34XXSP-class
 * table, anything else (incl. absent) = the RG SP table below — so a device
 * that fails detection gets exactly the pre-F52 behavior. */
static int gt_sticks_class = 0;
static void gt_class_load(void) {
    const char *c = getenv("GT_INPUT_CLASS");
    gt_sticks_class = (c && !strcmp(c, "sticks")) ? 1 : 0;
}

/* Park targets: one past each device's real button count, so no game can
 * hold a binding there (RG SP: 15 buttons 0..14; stick devices: 17, 0..16). */
#define GT_PARK_PLAIN  15
#define GT_PARK_STICKS 17

/* RG SP table — MEASURED 2026-08-19 (see the top-of-file comment). */
static unsigned char gt_remap_plain(unsigned char b) {
    switch (b) {
        case 0:  return GT_PARK_PLAIN;  /* ESC — park (would act as B) */
        case 1:  return GT_PARK_PLAIN;  /* VolDown — park (would act as A) */
        case 2:  return GT_PARK_PLAIN;  /* VolUp — park (would act as Y) */
        case 3:  return 1;   /* A */
        case 4:  return 0;   /* B */
        case 5:  return 2;   /* Y */
        case 6:  return 3;   /* X */
        case 7:  return 4;   /* L1 */
        case 8:  return 5;   /* R1 */
        case 9:  return 6;   /* Select */
        case 10: return 7;   /* Start */
        case 11: return 8;   /* Menu (TL2 half) */
        case 12: return 10;  /* L2 */
        case 13: return 11;  /* R2 */
        case 14: return GT_PARK_PLAIN;  /* Menu's KEY_GOTO half — park (double-fire) */
        default: return b;
    }
}

/* Stick-class table (RG34XXSP) — MEASURED from the volunteer probe trace
 * 2026-09-01. Identical to the RG SP through raw 11; the L3/R3 clicks
 * (evdev 313 BTN_TR2 / 316 BTN_MODE, absent on the RG SP) take raw 12/15
 * and shift L2/R2 to 13/14 and Menu's KEY_GOTO echo to 16. L3/R3 land on
 * slots 9/12 — the two gaps of the TrimUI-layout table, the standard
 * leftstick/rightstick positions of tg5040 mappings. */
static unsigned char gt_remap_sticks(unsigned char b) {
    switch (b) {
        case 0:  return GT_PARK_STICKS;  /* ESC */
        case 1:  return GT_PARK_STICKS;  /* VolDown */
        case 2:  return GT_PARK_STICKS;  /* VolUp */
        case 3:  return 1;   /* A */
        case 4:  return 0;   /* B */
        case 5:  return 2;   /* Y */
        case 6:  return 3;   /* X */
        case 7:  return 4;   /* L1 */
        case 8:  return 5;   /* R1 */
        case 9:  return 6;   /* Select */
        case 10: return 7;   /* Start */
        case 11: return 8;   /* Menu (TL2 half) */
        case 12: return 9;   /* L3 click */
        case 13: return 10;  /* L2 */
        case 14: return 11;  /* R2 */
        case 15: return 12;  /* R3 click */
        case 16: return GT_PARK_STICKS;  /* Menu's KEY_GOTO half — park */
        default: return b;
    }
}

static unsigned char gt_remap(unsigned char b) {
    return gt_sticks_class ? gt_remap_sticks(b) : gt_remap_plain(b);
}

/* The raw index of Menu's KEY_GOTO second emission for the active class. */
static unsigned char gt_menu_echo_index(void) {
    return gt_sticks_class ? 16 : 14;
}
```

- [ ] **Step 4: Class-aware swallow, slots, direct evdev table**

Replace `gt_menu_swallow`:

```c
/* Which raw indices gt_hud_intercept must SWALLOW (never deliver to the game):
 * the Menu toggle button (raw 11) plus KEY_GOTO's second emission — raw 14 on
 * the RG SP, raw 16 on stick devices (F52; on those, raw 14 is R2!). Only
 * raw 11 drives the toggle — the echo is swallowed without touching the tap
 * machine. Pure/host-testable so main() can assert the swallow decision. */
static int gt_menu_swallow(unsigned char raw) {
    return gt_is_menu_button(raw) || (raw == gt_menu_echo_index());
}
```

In `gt_button_slot`, after the `"r2"` line add:

```c
    if (!strcmp(name, "l3"))    return 9;   /* F52: stick clicks (stick-class devices) */
    if (!strcmp(name, "r3"))    return 12;
```

Replace `gt_evdev_code_sdl_index` (function + its comment) with:

```c
/* F45/F52: evdev key code -> TrimUI-layout SLOT, directly. The evdev codes
 * are the hardware truth and identical on every h700 Anbernic; only NextUI's
 * SDL index order differs between the RG SP and stick devices (it enumerates
 * the node's codes ascending after ESC/Vol, so the stick devices' extra
 * 313/316 shift everything after them). Mapping code -> slot here makes the
 * evdev gameplay path (OpenCrossing — its stock 32-bit SDL yields no
 * joystick events) class-independent by construction; main() asserts it
 * equals SDL-index -> gt_remap on both measured tables. Returns -1 for codes
 * that are not plain gameplay buttons (Menu/GOTO/Vol/ESC). */
static int gt_evdev_code_slot(int code) {
    switch (code) {
        case 304: return 1;   /* BTN_SOUTH  A  */
        case 305: return 0;   /* BTN_EAST   B  */
        case 306: return 2;   /* BTN_C      Y  */
        case 307: return 3;   /* BTN_NORTH  X  */
        case 308: return 4;   /* BTN_WEST   L1 */
        case 309: return 5;   /* BTN_Z      R1 */
        case 310: return 6;   /* BTN_TL     Select */
        case 311: return 7;   /* BTN_TR     Start  */
        case 313: return 9;   /* BTN_TR2    L3 click (stick devices) */
        case 314: return 10;  /* BTN_SELECT L2 */
        case 315: return 11;  /* BTN_START  R2 */
        case 316: return 12;  /* BTN_MODE   R3 click (stick devices) */
        default:  return -1;  /* 312 Menu / 354 GOTO / 1 ESC / 114-115 Vol */
    }
}
```

In the evdev thread (the `} else if (keys_on) {` branch, ~line 1062), replace the index→remap pair:

```c
                /* F45/F52: gameplay button -> synthesized keystate, straight
                 * from the evdev code (class-independent; see gt_evdev_code_slot). */
                int slot = gt_evdev_code_slot(ev.code);
                if (slot >= 0 && slot < 16) {
                    gt_key k = gt_map.button_key[slot];
                    if (k.sym) {
                        gt_synth_set(gt_synth_keys, k.scancode, down);
                        if (gt_debug())
                            fprintf(stderr, "gt-input-remap: evdev btn %d -> slot %d key 0x%x (%s)\n",
                                    (int)ev.code, slot, (unsigned)k.sym, down ? "down" : "up");
                    }
                }
```

(Delete the old `int idx = gt_evdev_code_sdl_index(ev.code); if (idx >= 0) { int slot = gt_remap(...); … }` nesting — one `if` level less.)

In `gt_init`, after `gt_layout_load();` add:

```c
    gt_class_load();  /* F52: plain (RG SP) unless launch.sh exported GT_INPUT_CLASS=sticks */
    if (gt_debug())
        fprintf(stderr, "gt-input-remap: input class %s\n", gt_sticks_class ? "sticks" : "plain");
```

- [ ] **Step 5: Host test green, suite green**

Run: `grep -c gt_evdev_code_sdl_index assets/gt-input-remap.c` → `0`; `cc -DGT_REMAP_TEST -O2 -Wall -o /tmp/remap-test assets/gt-input-remap.c && /tmp/remap-test` → `remap ok`; `make test` → `ALL TESTS PASSED`.

Update the comment block at the top of `tests/test-05-input-remap.sh` (lines 3–15): add one sentence — "F52: a second measured table (RG34XXSP class, GT_INPUT_CLASS=sticks) is asserted alongside; the evdev path maps code→slot directly."

- [ ] **Step 6: Rebuild both shim binaries**

Run (network + docker; sandbox off): `docker pull --platform linux/arm64 debian:bullseye && make shim`
Then: `file assets/gt-input-remap.so assets/gt-input-remap.armhf.so`
Expected: `gt-input-remap.so: ELF 64-bit LSB shared object, ARM aarch64 …` and `gt-input-remap.armhf.so: ELF 32-bit LSB shared object, ARM, EABI5 …`. If either arch is wrong, `docker pull --platform <linux/arm64|linux/arm/v7> debian:bullseye` and rerun that lane's `docker run` line from the Makefile by hand, then re-check with `file`. (`make shim` also rebuilds the other shims from unchanged sources — that is expected and harmless.)

- [ ] **Step 7: Commit**

```bash
git add assets/gt-input-remap.c assets/gt-input-remap.so assets/gt-input-remap.armhf.so tests/test-05-input-remap.sh
git commit -m "feat: F52 — class-aware shim tables (stick raw indices, Menu echo 16, direct evdev slots, l3/r3)"
```

---

### Task 4: `use-input-debug` flag → shim trace for every port

**Goal:** Touching `$USERDATA_PATH/PORTS-portmaster/use-input-debug` exports `GT_INPUT_REMAP_DEBUG=1` for every port launch, so a user report can carry the shim's full remap/synthesis trace.

**Files:**
- Modify: `build/build-pak.sh:660-664` (the `gt-h700-port-remap` awk block)
- Modify: `tests/test-05-input-remap.sh` (placement assertions)

**Acceptance Criteria:**
- [ ] edited launch.sh contains `use-input-debug` and `export GT_INPUT_REMAP_DEBUG=1` inside the h700 preload block, after the `LD_PRELOAD` export and before the remap allowlist gate
- [ ] `sh -n` passes; marker count 1 after restage

**Verify:** `sh tests/test-05-input-remap.sh` → no output; `make test` → `ALL TESTS PASSED`

**Steps:**

- [ ] **Step 1: Failing test** — in `tests/test-05-input-remap.sh`, after the `assert_contains "$work/launch.sh" 'export GT_INPUT_REMAP=1'` line add:

```sh
# F52: a flag file turns the shim trace on for every port (user reports)
assert_contains "$work/launch.sh" 'gt-h700-input-debug'
# shellcheck disable=SC2016
assert_contains "$work/launch.sh" '[ -f "$USERDATA_PATH/PORTS-portmaster/use-input-debug" ] && export GT_INPUT_REMAP_DEBUG=1'
dbg=$(grep -n 'use-input-debug' "$work/launch.sh" | head -1 | cut -d: -f1)
[ "$lp" -lt "$dbg" ] || { echo "input-debug switch must follow the LD_PRELOAD export"; exit 1; }
[ "$dbg" -lt "$gate" ] || { echo "input-debug switch must precede the remap allowlist gate"; exit 1; }
```

(`lp` and `gate` are already computed a few lines below in the file — move this block to just AFTER the existing `[ "$gate" -lt "$ir" ] || …` line so both variables exist.) Run `sh tests/test-05-input-remap.sh` → expected `assert_contains: 'gt-h700-input-debug' not in …`.

- [ ] **Step 2: Inject** — in the `gt-h700-port-remap` awk, right after the `print "        export LD_PRELOAD=…"` line add:

```awk
      print "        # gt-h700-input-debug (F52): touch use-input-debug to trace every remap/synth into PORTS.txt"
      print "        [ -f \"$USERDATA_PATH/PORTS-portmaster/use-input-debug\" ] && export GT_INPUT_REMAP_DEBUG=1"
```

- [ ] **Step 3: Verify** — `sh tests/test-05-input-remap.sh && make test` → `ALL TESTS PASSED`.

- [ ] **Step 4: Commit**

```bash
git add build/build-pak.sh tests/test-05-input-remap.sh
git commit -m "feat: F52 — use-input-debug flag file enables the shim trace for every port"
```

---

## Wave 2 — F53

### Task 5: Shim — analog-to-key synthesis (gptokeyb parity)

**Goal:** On stick-class devices with a gptk loaded, stick deflections synthesize the gptk's `left_analog_*` / `right_analog_*` keys (gptokeyb defaults when unnamed; `deadzone` honored; mouse sticks skipped), edge-tracked, first key replacing the axis event, the rest stashed, mirrored into the polled keystate.

**Files:**
- Modify: `assets/gt-input-remap.c` (`gt_keyname` ~133; `gt_keymap` struct + parser ~212-247; new helpers after `gt_dir_slot` ~200 and after `gt_evdev_hat_edges` ~285; `gt_init` ~1150; `gt_rewrite` ~1262 hat branch; interposer state ~1127; test main)
- Rebuild: `assets/gt-input-remap.so`, `assets/gt-input-remap.armhf.so`

**Acceptance Criteria:**
- [ ] host test `remap ok` with: `home`/`end` key names; defaults (left w/s/a/d, right end/home/left/right, deadzone 15000); a present analog line overrides; `\"` clears; `mouse_movement_*` marks the stick mouse-driven and clears that direction; `deadzone` 1..32767 honored, 0/99999/abc ignored; `gt_axis_dir` at 14999/15000/-15000/27935/-32768/0; `gt_axis_slots` for axes 0–3; edge sequence center→up→down through center via `gt_evdev_hat_edges` with analog slot ids
- [ ] `gt_rewrite` has an `SDL_JOYAXISMOTION` branch gated on `gt_map.loaded && gt_sticks_class && axis < 4`, mouse-stick pass-through, first-key-replaces/rest-stashed, `gt_axis_prev[4]` state, debug line
- [ ] both `.so` rebuilt, arch verified with `file`; `make test` green

**Verify:** `cc -DGT_REMAP_TEST -O2 -Wall -o /tmp/remap-test assets/gt-input-remap.c && /tmp/remap-test` → `remap ok`; `make test` → `ALL TESTS PASSED`

**Steps:**

- [ ] **Step 1: Write the failing host tests**

In `main()`, the existing gptk block asserts `if (gt_gptk_line(&m, "left_analog_up = up")) return fail("analog line parsed");` — analog lines now DO map. Replace that one line with:

```c
        if (!gt_gptk_line(&m, "left_analog_up = up")) return fail("F53: analog line must map");
        if (m.analog_key[0][0].sym != (GT_SCANCODE_MASK | 82)) return fail("left_analog_up != Up key");
```

Keep `if (gt_gptk_line(&m, "deadzone = 2000")) return fail("config line parsed");` (still returns 0) and add right after it:

```c
        if (m.deadzone != 2000) return fail("deadzone = 2000 not honored");
```

Then add a new block after the F48 layout-swap block:

```c
    /* F53: analog synthesis — gptokeyb parity (PortsMaster/gptokeyb structs.h
     * defaults, keyboard.cpp deadzone semantics). */
    if (gt_keyname("home").scancode != 74 || gt_keyname("home").sym != (GT_SCANCODE_MASK | 74)) return fail("keyname home");
    if (gt_keyname("end").scancode  != 77 || gt_keyname("end").sym  != (GT_SCANCODE_MASK | 77)) return fail("keyname end");
    {
        gt_keymap m; memset(&m, 0, sizeof m);
        gt_keymap_defaults(&m);
        if (m.analog_key[0][0].sym != 'w' || m.analog_key[0][1].sym != 's' ||
            m.analog_key[0][2].sym != 'a' || m.analog_key[0][3].sym != 'd') return fail("left analog defaults w/s/a/d");
        if (m.analog_key[1][0].sym != (GT_SCANCODE_MASK | 77) ||   /* up = End */
            m.analog_key[1][1].sym != (GT_SCANCODE_MASK | 74) ||   /* down = Home */
            m.analog_key[1][2].sym != (GT_SCANCODE_MASK | 80) ||   /* left */
            m.analog_key[1][3].sym != (GT_SCANCODE_MASK | 79))     /* right */
            return fail("right analog defaults end/home/left/right");
        if (m.deadzone != 15000) return fail("deadzone default 15000");
        if (m.loaded) return fail("defaults alone must not mark the map loaded");
        if (!gt_gptk_line(&m, "left_analog_up = i")) return fail("parse left_analog_up=i");
        if (m.analog_key[0][0].sym != 'i' || !m.loaded) return fail("left_analog_up override");
        if (!gt_gptk_line(&m, "left_analog_down = \\\"")) return fail("placeholder analog line must count as present");
        if (m.analog_key[0][1].sym != 0) return fail("placeholder must CLEAR the default");
        if (!gt_gptk_line(&m, "left_analog_left = nosuchkey")) return fail("unknown analog value counts as present");
        if (m.analog_key[0][2].sym != 0) return fail("unknown analog value must clear");
        if (!gt_gptk_line(&m, "right_analog_left = mouse_movement_left")) return fail("parse mouse_movement");
        if (!m.analog_mouse[1]) return fail("mouse_movement marks the right stick mouse-driven");
        if (m.analog_key[1][2].sym != 0) return fail("mouse direction cleared");
        if (m.analog_mouse[0]) return fail("left stick must not be marked mouse");
        if (gt_gptk_line(&m, "deadzone = 20000")) return fail("deadzone is config, returns 0");
        if (m.deadzone != 20000) return fail("deadzone 20000");
        gt_gptk_line(&m, "deadzone = 0");     if (m.deadzone != 20000) return fail("deadzone 0 rejected");
        gt_gptk_line(&m, "deadzone = 99999"); if (m.deadzone != 20000) return fail("deadzone 99999 rejected");
        gt_gptk_line(&m, "deadzone = abc");   if (m.deadzone != 20000) return fail("deadzone abc rejected");
        gt_gptk_line(&m, "deadzone = 32767"); if (m.deadzone != 32767) return fail("deadzone 32767 accepted");
        gt_gptk_line(&m, "deadzone = 1");     if (m.deadzone != 1) return fail("deadzone 1 accepted");
        if (gt_gptk_line(&m, "deadzone_x = 5000")) return fail("deadzone_x stays ignored");
        if (gt_gptk_line(&m, "left_analog_up_repeat = true")) return fail("repeat flags stay ignored");
    }
    /* axis value -> direction, per-axis (gptokeyb: zero iff |v| < deadzone) */
    if (gt_axis_dir(14999, 15000) != 0)   return fail("14999 inside deadzone");
    if (gt_axis_dir(15000, 15000) != 1)   return fail("15000 deflected +");
    if (gt_axis_dir(-15000, 15000) != -1) return fail("-15000 deflected -");
    if (gt_axis_dir(27935, 15000) != 1)   return fail("short-range max still deflects");
    if (gt_axis_dir(-32768, 15000) != -1) return fail("full negative");
    if (gt_axis_dir(0, 15000) != 0)       return fail("centered");
    if (gt_axis_dir(500, 1) != 1)         return fail("deadzone 1: any offset deflects");
    /* axis -> stick + slot ends: 0/2 = X (left 2 / right 3), 1/3 = Y (up 0 / down 1) */
    {
        int st, sn, sp;
        gt_axis_slots(0, &st, &sn, &sp); if (st != 0 || sn != 2 || sp != 3) return fail("axis 0 = left X");
        gt_axis_slots(1, &st, &sn, &sp); if (st != 0 || sn != 0 || sp != 1) return fail("axis 1 = left Y");
        gt_axis_slots(2, &st, &sn, &sp); if (st != 1 || sn != 2 || sp != 3) return fail("axis 2 = right X");
        gt_axis_slots(3, &st, &sn, &sp); if (st != 1 || sn != 0 || sp != 1) return fail("axis 3 = right Y");
    }
    /* edge sequence on a Y axis: center -> up (press up), up -> down through
     * center (release up BEFORE press down), down -> center (release down) */
    {
        int es[2], ep[2], en;
        en = gt_evdev_hat_edges(0, -1, 0, 1, es, ep);
        if (en != 1 || es[0] != 0 || ep[0] != 1) return fail("stick center->up");
        en = gt_evdev_hat_edges(-1, 1, 0, 1, es, ep);
        if (en != 2 || es[0] != 0 || ep[0] != 0 || es[1] != 1 || ep[1] != 1) return fail("stick up->down releases first");
        en = gt_evdev_hat_edges(1, 0, 0, 1, es, ep);
        if (en != 1 || es[0] != 1 || ep[0] != 0) return fail("stick down->center");
        en = gt_evdev_hat_edges(1, 1, 0, 1, es, ep);
        if (en != 0) return fail("held stick emits nothing");
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `cc -DGT_REMAP_TEST -O2 -o /tmp/remap-test assets/gt-input-remap.c`
Expected: compile errors — `analog_key`, `gt_keymap_defaults`, `gt_axis_dir`, `gt_axis_slots` undeclared.

- [ ] **Step 3: Key names, struct, defaults, parser**

In `gt_keyname`, after the `"right"` line add:

```c
    if (!strcmp(name, "home"))      { k.scancode = 74;  k.sym = GT_SCANCODE_MASK | 74;  return k; }
    if (!strcmp(name, "end"))       { k.scancode = 77;  k.sym = GT_SCANCODE_MASK | 77;  return k; }
```

Replace the `gt_keymap` typedef with:

```c
typedef struct {
    gt_key button_key[16];   /* indexed by post-v1-remap button index */
    gt_key dir_key[4];       /* up/down/left/right (hat) */
    gt_key analog_key[2][4]; /* F53: [stick 0=left 1=right][0=up 1=down 2=left 3=right] */
    int analog_mouse[2];     /* F53: stick is mouse-driven in the gptk -> synthesize nothing */
    int deadzone;            /* F53: |axis| >= deadzone = deflected */
    int loaded;              /* any mapping present */
} gt_keymap;

/* F53: gptokeyb's built-in analog defaults (PortsMaster/gptokeyb, structs.h):
 * left stick W/S/A/D, right stick End/Home/Left/Right, deadzone 15000. A gptk
 * that names no analog line still gets these under gptokeyb, so the shim
 * mirrors them. Does NOT mark the map loaded — only parsed lines do. */
#define GT_DEADZONE_DEFAULT 15000
static void gt_keymap_defaults(gt_keymap *m) {
    m->analog_key[0][0] = gt_keyname("w");    m->analog_key[0][1] = gt_keyname("s");
    m->analog_key[0][2] = gt_keyname("a");    m->analog_key[0][3] = gt_keyname("d");
    m->analog_key[1][0] = gt_keyname("end");  m->analog_key[1][1] = gt_keyname("home");
    m->analog_key[1][2] = gt_keyname("left"); m->analog_key[1][3] = gt_keyname("right");
    m->analog_mouse[0] = m->analog_mouse[1] = 0;
    m->deadzone = GT_DEADZONE_DEFAULT;
}
```

After `gt_dir_slot` add:

```c
/* F53: "left_analog_up" -> stick 0, dir 0 (dir uses gt_dir_slot's order). */
static int gt_analog_name(const char *name, int *stick, int *dir) {
    const char *rest;
    if (!strncmp(name, "left_analog_", 12))       { *stick = 0; rest = name + 12; }
    else if (!strncmp(name, "right_analog_", 13)) { *stick = 1; rest = name + 13; }
    else return 0;
    *dir = gt_dir_slot(rest);
    return *dir >= 0;   /* rejects left_analog_up_repeat and friends */
}
```

(`gt_dir_slot` must precede `gt_analog_name`; it does. `gt_keymap_defaults` calls `gt_keyname`, defined earlier — fine.)

In `gt_gptk_line`, replace the tail from `gt_key k = gt_keyname(value);` onward with:

```c
    /* F53: analog lines. A PRESENT line replaces the gptokeyb default: a known
     * key sets it, an unknown name / the \" placeholder clears it, and a
     * mouse_movement_* value marks the whole stick mouse-driven (gptokeyb
     * emits no keys for a mouse stick). */
    int stick, dir;
    if (gt_analog_name(name, &stick, &dir)) {
        if (!strncmp(value, "mouse_movement", 14)) {
            m->analog_mouse[stick] = 1;
            m->analog_key[stick][dir].sym = 0; m->analog_key[stick][dir].scancode = 0;
        } else {
            m->analog_key[stick][dir] = gt_keyname(value);   /* unknown -> sym 0 = cleared */
        }
        m->loaded = 1;
        return 1;
    }
    if (!strcmp(name, "deadzone")) {   /* gptokeyb's unified deadzone; 0 would read a centered stick as deflected */
        int dz = atoi(value);
        if (dz >= 1 && dz <= 32767) m->deadzone = dz;
        return 0;   /* config, not a mapping */
    }

    gt_key k = gt_keyname(value);
    if (!k.sym) return 0;

    int slot = gt_button_slot(name);
    if (slot >= 0) { m->button_key[slot] = k; m->loaded = 1; return 1; }
    slot = gt_dir_slot(name);
    if (slot >= 0) { m->dir_key[slot] = k; m->loaded = 1; return 1; }
    return 0; /* other config/unknown names: ignored by design */
```

Update the function's comment: "…ignores comments, blanks, non-`deadzone` config lines, and unknown key names; analog lines and `deadzone` are honored (F53)."

- [ ] **Step 4: Axis helpers (host-testable section, after `gt_evdev_hat_edges`)**

```c
/* F53: axis value -> direction. gptokeyb: zero iff |v| < deadzone, so a value
 * AT the deadzone counts as deflected. */
static int gt_axis_dir(int value, int deadzone) {
    if (value <= -deadzone) return -1;
    if (value >=  deadzone) return  1;
    return 0;
}

/* F53: which stick an SDL axis belongs to and which analog_key slots its
 * negative / positive ends drive. Measured on the RG34XXSP: a0 left X, a1 left
 * Y, a2 right X, a3 right Y; negative = up / left. Slot order = gt_dir_slot. */
static void gt_axis_slots(int axis, int *stick, int *slot_neg, int *slot_pos) {
    *stick = axis / 2;
    if (axis & 1) { *slot_neg = 0; *slot_pos = 1; }   /* Y: up / down */
    else          { *slot_neg = 2; *slot_pos = 3; }   /* X: left / right */
}
```

- [ ] **Step 5: Wire defaults into `gt_init` and add the axis branch to `gt_rewrite`**

In `gt_init`, right before the `char line[256];` / `fgets` loop, add `gt_keymap_defaults(&gt_map);` (so a parsed line can override). Next to `static int gt_hat_prev;` add `static int gt_axis_prev[4];  /* F53: per-axis last direction (-1/0/+1) */`.

In `gt_rewrite`, after the `SDL_JOYHATMOTION` block's `return;`, add:

```c
    /* F53: analog stick -> the gptk's analog keys. Stick-class devices only
     * (the RG SP's three phantom axes never move, and plain must stay
     * byte-for-byte pre-F53). Same shape as the hat path: release-before-press
     * edges from gt_evdev_hat_edges, the first key REPLACES the axis event,
     * the rest ride the stash; no mapped edge -> the axis passes through, so a
     * hybrid port that reads raw axes keeps them. A mouse-driven stick is left
     * alone entirely (gptokeyb emits no keys for it). Re-pass safe: a key event
     * is never rewritten, and prev == cur yields no edges. */
    if (ev->type == SDL_JOYAXISMOTION && gt_map.loaded && gt_sticks_class
        && ev->jaxis.axis < 4) {
        int axis = ev->jaxis.axis, stick, sneg, spos;
        gt_axis_slots(axis, &stick, &sneg, &spos);
        if (gt_map.analog_mouse[stick]) return;
        int cur = gt_axis_dir(ev->jaxis.value, gt_map.deadzone);
        int slots[2], pressed[2];
        int n = gt_evdev_hat_edges(gt_axis_prev[axis], cur, sneg, spos, slots, pressed);
        if (gt_debug() && cur != gt_axis_prev[axis])
            fprintf(stderr, "gt-input-remap: axis %d %d -> dir %d\n", axis, (int)ev->jaxis.value, cur);
        gt_axis_prev[axis] = cur;
        Uint32 ts = ev->jaxis.timestamp;
        int emitted = 0, i;
        for (i = 0; i < n; i++) {
            gt_key k = gt_map.analog_key[stick][slots[i]];
            if (!k.sym) continue;
            if (!emitted) {
                gt_make_key_event(ev, ts, k, pressed[i]);              /* replace in place */
            } else if (gt_stash_n < (int)(sizeof gt_stash / sizeof gt_stash[0])) {
                gt_make_key_event(&gt_stash[gt_stash_n++], ts, k, pressed[i]);
            }
            emitted++;
        }
        return;
    }
```

- [ ] **Step 6: Host test, suite, rebuild**

Run: `cc -DGT_REMAP_TEST -O2 -Wall -o /tmp/remap-test assets/gt-input-remap.c && /tmp/remap-test` → `remap ok`; `make test` → `ALL TESTS PASSED`.
Rebuild (network + docker, sandbox off): `docker pull --platform linux/arm64 debian:bullseye && make shim`, then `file assets/gt-input-remap.so assets/gt-input-remap.armhf.so` → aarch64 / `ELF 32-bit … ARM, EABI5` (re-pull the drifted platform and rerun that lane if not).

- [ ] **Step 7: Commit**

```bash
git add assets/gt-input-remap.c assets/gt-input-remap.so assets/gt-input-remap.armhf.so
git commit -m "feat: F53 — analog-to-key synthesis in the input shim (gptokeyb parity, stick-class devices)"
```

---

### Task 6: Profile pin refinement (`RGXX_MODEL` first, class refines buckets) + `use-stickless` hatch

**Goal:** The F51 pin tries the exact SKU from `RGXX_MODEL`, then the `DEVICE` bucket, then the default; `GT_INPUT_CLASS=sticks` upgrades the ambiguous buckets (`rg34xx`→`rg34xx-sp`, `rg35xx`→`rg35xx-h`, unknown→`rg34xx-sp`); a `use-stickless` flag exports `GT_ANALOG_STICKS=0`, which device_info applies as an `ANALOG_STICKS` override.

**Files:**
- Modify: `build/build-pak.sh` — the `gt-h700-device-pin` awk (the `case "${DEVICE:-}"` … `export GT_PANEL_W GT_PANEL_H` part) and `edit_portmaster_device_info`
- Modify: `tests/test-03-device.sh` (profile + hatch assertions)

**Acceptance Criteria:**
- [ ] `run_pin rg34xx RG34xxSP` → `rg34xx-sp 720 480`; `run_pin rg34xx RGSP` → `rg34xx-h 720 480`; `run_pin rg35xx RG35xx2024` → `rg35xx-plus 640 480` (model miss → bucket); `run_pin rg40xx RG40xxV` → `rg40xx-v 640 480`
- [ ] with the rg34xxsp fixture: `run_pin rg34xx` → `rg34xx-sp`; `run_pin rg35xx` → `rg35xx-h`; `run_pin ''` → `rg34xx-sp 720 480`; `run_pin rgsp` → `rg34xx-h` (exact SKU immune); `run_pin rg40xx` → `rg40xx-h`
- [ ] every pre-existing `run_pin` assertion unchanged
- [ ] `use-stickless` present → `GT_ANALOG_STICKS=0` exported + log line; absent → unset
- [ ] device_info: `gt-h700-stickless` line immediately before `export ANALOG_STICKS`; behavioral override 2→0 with the env, 2 stays without; marker count 1 after restage

**Verify:** `sh tests/test-03-device.sh && make test` → `ALL TESTS PASSED`

**Steps:**

- [ ] **Step 1: Failing tests** — append after the F52 `run_class` block in test-03:

```sh
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
```

And in the idempotency section add `assert_eq "$(grep -c 'gt-h700-stickless' "$work/device_info.txt")" "1" "stickless edit idempotent"`.

Run `sh tests/test-03-device.sh` → expected first failure `assert_eq: 'rg34xx-h 720 480' != 'rg34xx-sp 720 480' (model beats bucket)`.

- [ ] **Step 2: Rewrite the pin case in the injection**

In the `gt-h700-device-pin` awk, replace the `print` lines from `print "    case \"${DEVICE:-}\" in"` through `print "    esac"` (keep the F52 detection lines above them, and keep the `.DEVICE` echo / `export GT_PANEL_W GT_PANEL_H` lines after) with:

```awk
      print "    # F51+F53 profile token: the exact SKU from RGXX_MODEL (RG34xxSP, RGSP, ...)"
      print "    # first, then the family bucket NextUI puts in $DEVICE, then the RG SP default."
      print "    gt_pm_device=; gt_pm_bucket="
      print "    for gt_tok in \"$(printf %s \"${RGXX_MODEL:-}\" | tr A-Z a-z)\" \"${DEVICE:-}\"; do"
      print "        case \"$gt_tok\" in"
      print "            rgsp)                 gt_pm_device=rg34xx-h;    GT_PANEL_W=720; GT_PANEL_H=480 ;;"
      print "            rg34xxsp)             gt_pm_device=rg34xx-sp;   GT_PANEL_W=720; GT_PANEL_H=480 ;;"
      print "            rg35xxh)              gt_pm_device=rg35xx-h;    GT_PANEL_W=640; GT_PANEL_H=480 ;;"
      print "            rg35xxplus|rg35xxpro) gt_pm_device=rg35xx-plus; GT_PANEL_W=640; GT_PANEL_H=480 ;;"
      print "            rg35xxsp)             gt_pm_device=rg35xx-sp;   GT_PANEL_W=640; GT_PANEL_H=480 ;;"
      print "            rg40xxh)              gt_pm_device=rg40xx-h;    GT_PANEL_W=640; GT_PANEL_H=480 ;;"
      print "            rg40xxv)              gt_pm_device=rg40xx-v;    GT_PANEL_W=640; GT_PANEL_H=480 ;;"
      print "            rg28xx)               gt_pm_device=rg28xx;      GT_PANEL_W=640; GT_PANEL_H=480 ;;"
      print "            rgcubexx|cube)        gt_pm_device=rg34xx-h;    GT_PANEL_W=720; GT_PANEL_H=720 ;;"
      print "            # family buckets: ambiguous between the stickless and the stick SKU -> refined below"
      print "            rg34xx)               gt_pm_device=rg34xx-h;    GT_PANEL_W=720; GT_PANEL_H=480; gt_pm_bucket=rg34xx ;;"
      print "            rg35xx)               gt_pm_device=rg35xx-plus; GT_PANEL_W=640; GT_PANEL_H=480; gt_pm_bucket=rg35xx ;;"
      print "            rg40xx)               gt_pm_device=rg40xx-h;    GT_PANEL_W=640; GT_PANEL_H=480 ;;"
      print "            *) continue ;;"
      print "        esac"
      print "        break"
      print "    done"
      print "    if [ -z \"$gt_pm_device\" ]; then  # unknown/absent tokens = the RG SP profile (pre-F51 behavior)"
      print "        gt_pm_device=rg34xx-h; GT_PANEL_W=720; GT_PANEL_H=480; gt_pm_bucket=unknown"
      print "    fi"
      print "    # F53: the input class disambiguates the buckets (sticks present -> the stick SKU)"
      print "    if [ \"$GT_INPUT_CLASS\" = sticks ]; then"
      print "        case \"$gt_pm_bucket\" in"
      print "            rg34xx|unknown) gt_pm_device=rg34xx-sp ;;"
      print "            rg35xx)         gt_pm_device=rg35xx-h ;;"
      print "        esac"
      print "    fi"
      print "    # F53: use-stickless hatch -> ports see ANALOG_STICKS=0 (device_info honors GT_ANALOG_STICKS);"
      print "    # the input tables are untouched, and harbourmaster keeps the true profile."
      print "    if [ -f \"$USERDATA_PATH/PORTS-portmaster/use-stickless\" ]; then"
      print "        export GT_ANALOG_STICKS=0"
      print "        echo \"gt-h700: use-stickless present - ports will see ANALOG_STICKS=0\""
      print "    fi"
```

(`continue` inside `case` inside `for` continues the loop; matched arms fall to `break`. `tr A-Z a-z` needs no quotes, which keeps the awk program free of single quotes.) Update the F51 comment above the injection: token order is now model → bucket → default, and the class refines ambiguous buckets.

- [ ] **Step 3: device_info override**

In `edit_portmaster_device_info`, after the existing `if ! grep -q 'gt-h700-fallback' …; fi` block add:

```sh
  # gt-h700-stickless: F53 — the use-stickless hatch. launch.sh exports
  # GT_ANALOG_STICKS=0 when the flag file exists; apply it AFTER upstream's own
  # per-device case so every port launcher picks its stickless gptk again.
  if ! grep -q 'gt-h700-stickless' "$f"; then
    awk '$0 == "export ANALOG_STICKS" {
      print "ANALOG_STICKS=${GT_ANALOG_STICKS:-$ANALOG_STICKS}  # gt-h700-stickless (F53): use-stickless flag override"
    } { print }' "$f" > "$f.awk.tmp" && mv "$f.awk.tmp" "$f"
  fi
```

- [ ] **Step 4: Verify** — `sh tests/test-03-device.sh && make test` → `ALL TESTS PASSED`.

- [ ] **Step 5: Commit**

```bash
git add build/build-pak.sh tests/test-03-device.sh
git commit -m "feat: F53 — RGXX_MODEL-first profile pin, class-refined buckets, use-stickless hatch"
```

---

### Task 7: Docs — README, h700-fixes (F52/F53 + changelog), shim header, remap-list comment

**Goal:** Users and future maintainers can read what stick support does, that it is experimental, how to report, and how to opt out.

**Files:**
- Modify: `README.md` ("Other h700 NextUI devices" section, lines ~93-101)
- Modify: `docs/h700-fixes.md` (0.4.0 changelog bullets; F51 section tail ~1601-1606; two new sections appended at the end)
- Modify: `assets/gt-input-remap.c` (top-of-file comment, ~lines 1-45)
- Modify: `assets/gt-remap-ports.txt` (header comment)

**Acceptance Criteria:**
- [ ] README section rewritten (text below), mentions `use-input-debug`, `use-stickless`, "experimental", the breadcrumb line
- [ ] h700-fixes.md: two F52/F53 bullets under `### 0.4.0` → `**Fixes**`; F51 tail no longer says stick axes are out of scope; `## Stick-equipped devices: input class and per-class tables (F52)` and `## Stick-equipped devices: analog sticks as keys, and a truthful profile (F53)` sections exist
- [ ] shim header no longer says "the RG SP has no sticks"; describes both tables and analog synthesis
- [ ] `make test` still green (docs only; the grep in Task 3's test-05 header is a comment)

**Verify:** `grep -n 'use-input-debug\|use-stickless\|xperimental' README.md docs/h700-fixes.md | wc -l` ≥ 6; `make test` → `ALL TESTS PASSED`

**Steps:**

- [ ] **Step 1: README** — replace the whole "Other h700 NextUI devices" section body with:

```markdown
## Other h700 NextUI devices

Only the RG SP is verified in hand. The pak adapts its hardware profile,
screen geometry and sleep trigger to the device it runs on (RG34XXSP, the
RG35XX and RG40XX families, CubeXX), and since 0.4.0 it also adapts its
**controller tables**: at launch it reads which buttons the device's input
node actually has and picks the matching measured mapping, so triggers,
stick clicks and the Menu button behave on stick-equipped devices too.

**Analog sticks — experimental.** On devices with sticks the pak installs a
controller mapping that carries both sticks (native SDL ports and the
PortMaster GUI use them directly), and the built-in input translator turns
stick movement into the keys a port's `.gptk` expects — the same
`left_analog_*` / `right_analog_*` lines and defaults gptokeyb uses. The
device profile then reports two analog sticks, so ports pick their stick
control schemes. None of this has been run on stick hardware yet: the
tables come from a volunteer's RG34XXSP probe log. If a port's stick scheme
misbehaves, create an empty file `use-stickless` in
`.userdata/h700/PORTS-portmaster/` on the SD card — ports go back to their
d-pad schemes while buttons and native stick support stay correct.

**Reporting.** Create an empty file `use-input-debug` in the same folder,
launch the port, then open an issue with `.userdata/h700/logs/PORTS.txt`
attached. It carries the `gt-h700: input class …` line (which table was
chosen and why), the `DEVICE INFO` line, and every button/stick event the
translator saw. If the log says `unrecognized joystick key set`, your device
has a key layout we have not measured — please also run the GT Probe pak
from the wiki so we can add it.
```

- [ ] **Step 2: h700-fixes.md changelog** — under `### 0.4.0` → `**Fixes**`, after the F51 bullet add:

```markdown
- F52: stick-equipped h700 devices (RG34XXSP, RG35XX-H, RG40XX, CubeXX) get the right controller tables — the pak reads the input node's key set at launch and picks the measured mapping for it, fixing triggers, stick clicks and a Menu-button echo that swallowed R2 in every port; `use-input-debug` flag file traces the input shim for reports
- F53: analog sticks (experimental, not yet run on stick hardware) — sticks mapped in the controller DB for native ports and the GUI, stick-to-keys synthesis in the input translator with gptokeyb's own keys and defaults, a truthful 2-stick device profile, and a `use-stickless` flag file to fall back to d-pad control schemes
```

- [ ] **Step 3: h700-fixes.md F51 tail** — replace the sentence "Deliberately out of scope: the controller mapping and the shim's index table have only ever been measured on the RG SP (stick-equipped devices additionally get no stick axes — the measured mapping carries none), RG28XX's rotated panel is unaddressed, and the ALSA suspend-proxy chain is a copy of the RG SP's stock output chain." with: "The controller tables became device-keyed in F52/F53 (below). Still out of scope: RG28XX's rotated panel, and the ALSA suspend-proxy chain is a copy of the RG SP's stock output chain."

- [ ] **Step 4: h700-fixes.md new sections** — append at the end of the file:

```markdown
## Stick-equipped devices: input class and per-class tables (F52)

Every button table in the pak was measured on the RG SP: the two SDL
controller-DB lines, the shim's raw-index remap, the HUD's Menu-echo
swallow, and the F45 evdev-code table. The first non-RG-SP probe log — an
RG34XXSP, captured with the GT Probe pak on NextUI's own SDL — showed the
difference is small and exact. Its `ANBERNIC-keys` node carries **two extra
evdev codes**, 313 (`BTN_TR2`, the L3 click) and 316 (`BTN_MODE`, R3).
NextUI's SDL enumerates the node's codes in ascending order after the three
keyboard-type codes (ESC, Vol−, Vol+ at b0–b2), so those two codes push
L2/R2 from b12/b13 to **b13/b14**, Menu's `KEY_GOTO` echo from b14 to
**b16**, and put L3/R3 at b12/b15; faces, shoulders, Select, Start, Menu
and the hat d-pad are identical. The SDL GUID is identical too, so a
controller-DB line cannot tell the devices apart.

What a stick device got from the pak before F52: L3 acted as L2, L2 as R2,
and **R2 was dead in every port** — the HUD's Menu intercept, preloaded
everywhere, swallowed raw index 14 unconditionally because on the RG SP that
is the Menu echo.

- **Input class.** `launch.sh` reads `/proc/bus/input/devices`, takes the
  `js0` record's `B: KEY=` bitmap word for codes 256–319 (fifth word from
  the right) and classifies it: `dff000000000000` = `plain` (RG SP),
  `1fff000000000000` = `sticks`. It exports `GT_INPUT_CLASS` on the common
  path and logs `gt-h700: input class <class> (js0 key word <word>)`.
  Anything else — missing node, unrecognized word — is `plain` plus a
  warning asking for a probe run: exactly the pre-F52 behavior. (The
  RG40XX-V, listed by harbourmaster with one stick, may be such a third
  layout.)
- **Controller DB per class.** The build stages four files:
  `gamecontrollerdb_{nintendo,xbox}.txt` (unchanged) and
  `gamecontrollerdb_{nintendo,xbox}_sticks.txt` — the same upstream DB with
  the measured stick line (`lefttrigger:b13,righttrigger:b14,leftstick:b12,
  rightstick:b15,leftx:a0,lefty:a1,rightx:a2,righty:a3`). Upstream's
  `set_controller_layout` picks the `_sticks` copy when the class says so;
  the F48 layout choice composes with it.
- **Shim tables.** `gt-input-remap.so` loads the class once and switches its
  raw-index remap (stick table: 12→L3 slot 9, 13→L2, 14→R2, 15→R3 slot 12,
  park at 17) and the Menu-echo swallow index (14 → 16). The F45 evdev path
  now maps evdev code → slot directly, which is device-independent by
  construction. gptk `l3`/`r3` names bind the stick clicks.
- **Reporting switch.** A `use-input-debug` flag file exports the shim's
  debug variable for every port, so a report carries the full trace.

Wording for users and the volunteer-gate decision: stick support ships
**experimental**, gated only by the RG SP regression run; the design and
measured tables are in `docs/superpowers/specs/2026-09-01-stick-device-support-design.md`.

## Stick-equipped devices: analog sticks as keys, and a truthful profile (F53)

With the buttons right, two things kept stick devices second-class: the
shim ignored every analog line in a gptk (the RG SP has no sticks), and the
F51 profile pinned the `rg34xx` family bucket to the stickless `rg34xx-h`,
so device_info reported zero sticks and ports picked their d-pad control
schemes.

- **Analog synthesis** (shim, stick class only, gptk loaded). Mirrors
  gptokeyb (PortsMaster/gptokeyb source): the eight `left_analog_*` /
  `right_analog_*` lines, gptokeyb's built-in defaults when a line is absent
  (left W/S/A/D, right End/Home/Left/Right), a present line with an unknown
  name or the `\"` placeholder clears the default, a `mouse_movement_*`
  value marks that stick mouse-driven and it synthesizes nothing, and the
  unified `deadzone` (default 15000, deflected when |value| ≥ deadzone) is
  honored. Axes a0–a3 are left X/Y, right X/Y with negative = up/left. Each
  axis keeps its last direction; edges go through the same
  release-before-press helper the evdev d-pad uses, the first key replaces
  the axis event and the rest ride the existing stash, and every key is
  mirrored into the polled keystate (F31), so polling games see the stick
  too. Unmapped axes pass through untouched.
- **Profile.** The pin tries the exact SKU from `RGXX_MODEL` first (this
  NextUI build exports it: `RGSP`, `RG34xxSP`, …), then the `DEVICE`
  bucket, then the RG SP default; the input class upgrades the ambiguous
  buckets (`rg34xx` + sticks → `rg34xx-sp`, `rg35xx` + sticks → `rg35xx-h`,
  unknown + sticks → `rg34xx-sp`). Exact SKUs are never overridden.
- **Hatch.** `use-stickless` exports `GT_ANALOG_STICKS=0`, which
  device_info applies after upstream's own per-device case — ports see zero
  sticks and pick their d-pad schemes again, while harbourmaster keeps the
  true profile and the button tables are untouched.

Not done, deliberately: mouse emulation, deadzone modes/scaling, key
repeat and hold-state modifiers in the shim; a third key layout (RG40XX-V)
until a probe log exists.
```

- [ ] **Step 5: shim header + remap-list comment** — in `assets/gt-input-remap.c`'s top comment, change the v1 paragraph's last sentences ("Identity elsewhere. … revisit if one is attached.") to: "Identity elsewhere. F52 adds a second measured table for stick-equipped devices (RG34XXSP class: L3/R3 clicks at evdev 313/316 shift L2/R2/Menu-echo by one; park 17), selected once at load from GT_INPUT_CLASS; absent = this RG SP table." In the v2 paragraph replace "analog lines (the RG SP has no sticks), deadzone config," with "deadzone modes/scaling," and add a sentence: "F53: on stick-class devices the eight analog lines (with gptokeyb's defaults and unified `deadzone`) are honored — stick deflections synthesize their keys the same way hats do." In `assets/gt-remap-ports.txt`, extend the header comment with one line: "# On stick-equipped devices the shim also honors the gptk's left/right_analog lines (F53)."

- [ ] **Step 6: Verify and commit**

Run: `make test` → `ALL TESTS PASSED`; `grep -c 'no sticks' assets/gt-input-remap.c` → `0`.

```bash
git add README.md docs/h700-fixes.md assets/gt-input-remap.c assets/gt-remap-ports.txt
git commit -m "docs: F52/F53 — stick-device support (README, h700-fixes, shim header)"
```

---

### Task 8: Build the pak and run the RG SP regression gate

**Goal:** A full pak build from this branch, installed on the RG SP, shows `input class plain` and no behavior change across the affected port classes; on PASS the branch is squash-merged to local main (no push, no tag).

**USER-ORDERED GATE — NON-SKIPPABLE.** This task was requested by the user in the current conversation. It MUST NOT be closed by walking around it, by declaring it "verified inline", or by substituting a cheaper check. Close only after every item in `acceptanceCriteria` has been re-validated independently, with output captured.

**Files:**
- Build output: `dist/Emus/h700/PORTS.pak.zip` (gitignored)
- Device: RG SP at `ssh root@10.0.1.16`, pak at `/mnt/SDCARD/Emus/h700/PORTS.pak/`, log `/mnt/SDCARD/.userdata/h700/logs/PORTS.txt`

**Acceptance Criteria (each with captured evidence — a log excerpt or Camille's explicit confirmation):**
- [ ] `make test` → `ALL TESTS PASSED`; `make pak` succeeds; `unzip -l dist/Emus/h700/PORTS.pak.zip | grep -c 'gamecontrollerdb_.*_sticks.txt'` → `2`; the zip's `lib/gt-input-remap.so` md5 equals `assets/gt-input-remap.so`
- [ ] after install and one GUI launch, `PORTS.txt` contains `gt-h700: input class plain (js0 key word dff000000000000)` and no `unrecognized joystick key set`
- [ ] GUI: d-pad navigation, A confirms / B backs (nintendo default) — Camille confirms
- [ ] Celeste (clean SDL): jump/dash on the right faces, grab on the trigger — Camille confirms
- [ ] Tunics! and BYTEPATH (shim): controls as before — Camille confirms
- [ ] Sonic 1 (gptk overlay): A+B jump, Menu tap toggles the HUD, a later press of R2/L2 still reaches the game — Camille confirms
- [ ] Animal Crossing (evdev refactor — the ONE path whose code changes on the RG SP): A/B/X/Y, L/R, Start all act; log shows `evdev btn 304 -> slot 1` style lines with `use-input-debug` on
- [ ] power-button sleep in a port, resume with sound — Camille confirms
- [ ] `use-input-debug` on for one launch produces `gt-input-remap: input class plain` + `jbtn=` trace lines in `PORTS.txt`; flag removed afterwards; `use-stickless` NOT left on the device

**Verify:** `ssh root@10.0.1.16 'grep -n "gt-h700: input class\|unrecognized joystick" /mnt/SDCARD/.userdata/h700/logs/PORTS.txt'` → one `input class plain (js0 key word dff000000000000)` line, no `unrecognized` line

**Steps:**

- [ ] **Step 1: Build** (network; sandbox off): `make test && make pak`, then
  `unzip -l dist/Emus/h700/PORTS.pak.zip | grep 'gamecontrollerdb_'` (expect 4 files + `PortMaster/gamecontrollerdb.txt`), and
  `unzip -p dist/Emus/h700/PORTS.pak.zip PORTS.pak/lib/gt-input-remap.so | md5 ; md5 -q assets/gt-input-remap.so` → equal.

- [ ] **Step 2: Install on the RG SP** (PortMaster must be idle — no GUI or port running; check with `ssh root@10.0.1.16 'ps | grep -i "[p]ugwash\|[g]ptokeyb"'` → empty):

```bash
scp dist/Emus/h700/PORTS.pak.zip root@10.0.1.16:/mnt/SDCARD/PORTS.pak.zip
ssh root@10.0.1.16 'cd /mnt/SDCARD && md5sum PORTS.pak.zip && unzip -o -q PORTS.pak.zip -d Emus/h700/ && rm PORTS.pak.zip && md5sum Emus/h700/PORTS.pak/lib/gt-input-remap.so'
md5 -q dist/Emus/h700/PORTS.pak.zip   # must match the device's first md5sum
```

(Unzip-over is the documented self-healing install: `PortMaster/config/` and `PortMaster/libs/` are not in the zip.)

- [ ] **Step 3: Hand Camille the checklist** (Acceptance Criteria 3–8) and wait. Do not proceed on assumptions; record each answer.

- [ ] **Step 4: Collect log evidence**

```bash
ssh root@10.0.1.16 'grep -n "gt-h700: input class\|unrecognized joystick\|gt-input-remap: input class\|evdev btn" /mnt/SDCARD/.userdata/h700/logs/PORTS.txt | head -20; ls /mnt/SDCARD/.userdata/h700/PORTS-portmaster/ | grep -c "use-input-debug\|use-stickless"'
```

Expected: the plain breadcrumb, no `unrecognized`, trace lines from the debug run, and `0` leftover flag files.

- [ ] **Step 5: On PASS — finish the branch** via `superpowers-extended-cc:finishing-a-development-branch`: squash-merge `feat/stick-devices` into local `main` as one commit (`feat: F52/F53 — stick-equipped h700 devices: per-class input tables, analog-to-key synthesis, truthful profile`, docs folded in), delete the branch, **do not push or tag**. On any FAIL: stop, report the failing criterion with the log excerpt, and do not merge.

---

## Self-review (done at plan-writing time)

- **Spec coverage:** 4.1 → Task 1; 4.2 → Task 2; 4.3 → Task 3; 4.4 → Task 5; 4.5 → Task 6; 4.6 → Tasks 4 + 7; §7 tests → inside each task; §7 build + RG SP gate → Task 8; §8 delivery → Task 8 step 5 + Global Constraints.
- **Placeholders:** none; every code step carries the code.
- **Name consistency:** `GT_INPUT_CLASS`, `gt_sticks_class`, `gt_class_load`, `gt_remap_plain/sticks`, `GT_PARK_PLAIN/STICKS`, `gt_menu_echo_index`, `gt_evdev_code_slot`, `gt_keymap_defaults`, `gt_analog_name`, `gt_axis_dir`, `gt_axis_slots`, `gt_axis_prev`, `analog_key[2][4]`, `analog_mouse[2]`, `deadzone`, `stage_controllerdb_classes`, `run_pin DEVICE MODEL FIXTURE`, `run_class`, `run_layout`, `run_hatch`, markers `gt-h700-input-class` / `gt-h700-controller-db-class` / `gt-h700-input-debug` / `gt-h700-stickless` — used identically across tasks.
