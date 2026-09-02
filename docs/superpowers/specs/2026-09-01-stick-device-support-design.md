# Stick-equipped h700 devices: input class, per-class tables, analog synthesis (F52/F53)

Date: 2026-09-01. Repo: nextui-portmaster-h700, branch `feat/stick-devices` off main `ae35d8b` (F51).
Status: design approved in chat; this document is the spec for the implementation plan.

## 1. Context and problem

Every button table in the pak was measured on the RG SP and hardcoded: the two SDL
controller-DB lines, the shim's raw-index remap, the HUD's Menu-echo swallow, and the
F45 evdev-code table. F51 made the *geometry* device-keyed but left input alone.

The first non-RG-SP probe log (RG34XXSP, 1 GB revision, `NextUI-20260809-h700-0`,
on `feat/gt-probe` at `probe/logs/2026-09-01-rg34xxsp-1gb-nextui-20260809.txt`)
shows why input is different there, and that the difference is small and exact:

- The RG34XXSP's `ANBERNIC-keys` node carries **two extra evdev codes**, 313
  (`BTN_TR2`, the L3 click) and 316 (`BTN_MODE`, the R3 click). The RG SP's node
  (read live 2026-09-01) has neither. Nothing else in the key set differs.
- NextUI's SDL enumerates the node's keys in ascending code order with the three
  keyboard-type codes first (measured, both devices), so the two extra codes shift
  everything after them: **L2/R2 move from b12/b13 to b13/b14**, Menu's KEY_GOTO
  echo moves from **b14 to b16**, and L3/R3 appear at **b12/b15**. Faces,
  shoulders, Select, Start, Menu (b3–b11) and the hat d-pad are identical.
- Four real axes appear: **a0 left X, a1 left Y, a2 right X, a3 right Y**, up/left
  = negative, full range −32768..32767 (one axis topped out at 27935).
- The SDL **GUID is identical** to the RG SP's (`19000000010000000100000000010000`),
  so a controller-DB line cannot discriminate the devices; the pak has to choose per
  launch.
- `$DEVICE` is a family bucket on this build (`rg34xx` for both the stickless RG34XX
  and the RG34XXSP); the exact SKU is in **`RGXX_MODEL`** (`RG34xxSP`; the RG SP
  reports `RGSP`).

What a stick device gets from the pak today, as a consequence:

| Consumer | Effect on a stick device |
|---|---|
| Controller DB (native SDL ports, GUI) | L3 acts as L2, L2 acts as R2, R2 unmapped, sticks unmapped |
| HUD Menu intercept (preloaded into **every** port) | swallows raw 14 = **R2 dead in every port** |
| Shim remap (allowlisted ports) | same trigger shift, R2 parked, b16 Menu echo leaks as an unknown button |
| Profile pin | `rg34xx` → `rg34xx-h` → `ANALOG_STICKS=0`: ports pick stickless gptk variants, harbourmaster hides stick-requiring ports |

## 2. Goals and non-goals

Goals (Camille's choice "B"):

1. Correct buttons on stick-class devices: triggers, stick clicks, Menu echo, in every
   port class (native SDL, shim, evdev/F45) and in the GUI.
2. Sticks work in native SDL GameController ports via the controller DB.
3. Sticks work in gptk-driven shim ports via analog-to-key synthesis with **gptokeyb
   parity** (same config keys, same defaults, same deadzone semantics).
4. The harbourmaster/device_info profile tells the truth (2 sticks) on stick devices,
   with a user escape hatch back to the stickless profile.
5. The RG SP path is behaviorally unchanged. Anything unrecognized falls back to
   exactly today's behavior and says so in the log.
6. Feedback arrives as a log, not a description: a flag file turns on the shim trace.

Non-goals:

- No volunteer gate before release (Camille: RG SP regression gate only; stick
  support is labelled **experimental**; a volunteer round stays in reserve).
- No mouse emulation, deadzone modes/scaling, key repeat, or hold-state modifiers in
  the shim (unchanged policy).
- RG40XX-V (harbourmaster: 1 stick) may have a third key layout; it is detected as
  unrecognized and falls back to plain with a warning. A probe log adds a third
  table cheaply later.
- RG28XX rotation, CubeXX harbourmaster profile, raw `SDL_JoystickGetButton`
  polling — all unchanged from F51's out-of-scope list.

## 3. Decisions

- **Approach 1: input class from the key bitmap, two measured tables.** Chosen over
  computing the SDL index order from the bitmap (the ordering rule is inferred from
  two devices, not read from NextUI's SDL; a wrong inference would be silent) and
  over SKU-token keying (the bucket is ambiguous, the list goes stale).
- **Two knobs, deliberately separate.** The *input class* (`plain`|`sticks`) is
  hardware truth and drives every table. The *stick profile* (`ANALOG_STICKS`) is
  policy: derived from the class, user-overridable via the hatch, and it never
  touches the tables.
- **SKU where the SKU is the right key.** `RGXX_MODEL` picks the harbourmaster
  profile name (RG40XX-H vs -V differ in form factor, not input); the class refines
  only ambiguous buckets.
- **gptokeyb parity for analog**, verified against the PortsMaster/gptokeyb source
  (`structs.h` defaults, `keyboard.cpp` axis macros): unified `deadzone` default
  15000; deflected iff |value| ≥ deadzone; per-direction was-pressed state; a stick
  in mouse mode emits no keys; built-in default keys (left WASD, right
  End/Home/Left/Right) apply when a gptk names none.
- **Fail-safe = plain.** Absent variable, unrecognized bitmap, missing `/proc` node
  all mean the RG SP tables and today's code paths.

## 4. Components

### 4.1 Input-class detection (launch.sh, F52)

Location: inside the existing `gt-h700-device-pin` block (h700-guarded, common path
after `mkdir -p "$XDG_DATA_HOME"`), **before** the profile case so the class can
refine it. Runs once per launch; the GUI and every `run_port` inherit the exports.

Algorithm (line-oriented awk, busybox-safe):

1. Read `${GT_INPUT_DEVICES_FILE:-/proc/bus/input/devices}` (the env seam exists
   for tests only).
2. Find the record whose `H: Handlers=` line contains `js0`; take its `B: KEY=` line.
3. The key bitmap is printed as space-separated 64-bit hex words, highest word first.
   Take the **fifth word from the right** (bits 256–319, the `BTN_SOUTH..BTN_MODE`
   range). Require at least five words; otherwise unrecognized.
4. Classify: `dff000000000000` → `plain`; `1fff000000000000` → `sticks`; anything
   else → `plain` plus a warning.

Exports and log:

- `export GT_INPUT_CLASS=plain|sticks` (consumed by `set_controller_layout`, the
  shim, and the profile refinement).
- Breadcrumb, always: `gt-h700: input class <class> (js0 key word <word>)`.
- Warning, when unrecognized: `gt-h700: unrecognized joystick key set '<word|none>'
  — using RG SP input tables; please run GT Probe and open an issue`.

Fixtures: `tests/fixtures/input-devices/rgsp.txt` (live dump, Appendix A),
`rg34xxsp.txt` (from the probe log, Appendix A), `unknown.txt` (a fabricated word),
plus a missing-file case.

### 4.2 Controller DB per class (F52)

New repo assets `assets/gamecontrollerdb-h700-sticks-nintendo.txt` and
`assets/gamecontrollerdb-h700-sticks-xbox.txt`, same header convention as the plain
pair ("MEASURED ON-DEVICE", source = volunteer trace). Data lines:

```
# nintendo
19000000010000000100000000010000,Anbernic h700 Gamepad (sticks),a:b3,b:b4,x:b6,y:b5,back:b9,start:b10,guide:b11,leftshoulder:b7,rightshoulder:b8,lefttrigger:b13,righttrigger:b14,leftstick:b12,rightstick:b15,leftx:a0,lefty:a1,rightx:a2,righty:a3,dpup:h0.1,dpdown:h0.4,dpleft:h0.8,dpright:h0.2,platform:Linux,
# xbox
19000000010000000100000000010000,Anbernic h700 Gamepad (sticks),a:b4,b:b3,x:b5,y:b6,back:b9,start:b10,guide:b11,leftshoulder:b7,rightshoulder:b8,lefttrigger:b13,righttrigger:b14,leftstick:b12,rightstick:b15,leftx:a0,lefty:a1,rightx:a2,righty:a3,dpup:h0.1,dpdown:h0.4,dpleft:h0.8,dpright:h0.2,platform:Linux,
```

Build (`build-pak.sh`): stage **four** files under `files/`:
`gamecontrollerdb_nintendo.txt`, `gamecontrollerdb_xbox.txt` (unchanged, plain) and
`gamecontrollerdb_nintendo_sticks.txt`, `gamecontrollerdb_xbox_sticks.txt` (the same
upstream DB copy with the stick line appended via `append_controllerdb`, GUID-deduped,
so restaging is idempotent). The `GT_STAGE_EDIT_ONLY` path stages them too.

launch.sh: one marker-guarded awk edit of upstream `set_controller_layout`'s
`src="$PAK_DIR/files/gamecontrollerdb_$layout.txt"` line → suffix `_sticks` when
`GT_INPUT_CLASS=sticks`. The function already serves both the GUI and `run_port`
and copies to `$EMU_DIR/gamecontrollerdb.txt` = `SDL_GAMECONTROLLERCONFIG_FILE`.
The F48 layout resolution is untouched; the two dimensions compose to four files.

### 4.3 Shim: class-aware tables (assets/gt-input-remap.c, F52)

Load once: `GT_INPUT_CLASS` == `sticks` → stick tables; anything else → plain
(today's code). One static int read per event.

Raw SDL index → TrimUI-layout slot (slot convention unchanged: A=1 B=0 Y=2 X=3
L1=4 R1=5 Select=6 Start=7 Menu=8 L2=10 R2=11; **new: L3=9, R3=12**, the two gaps,
matching the standard tg5040 leftstick/rightstick positions):

| raw | plain (RG SP) | sticks (RG34XXSP) |
|---|---|---|
| 0–2 (ESC, Vol−, Vol+) | park 15 | park **17** |
| 3–11 (A B Y X L1 R1 Sel Start Menu) | 1 0 2 3 4 5 6 7 8 | same |
| 12 | L2 → 10 | **L3 → 9** |
| 13 | R2 → 11 | **L2 → 10** |
| 14 | Menu echo → park 15 | **R2 → 11** |
| 15 | identity | **R3 → 12** |
| 16 | identity | **Menu echo → park 17** |

Park index = one past the device's real button count (15 buttons on plain, 17 on
sticks) so no game can have a binding there. The v2 key-lookup guard (`button < 16`)
already rejects 17.

Menu echo swallow (HUD intercept, runs on RAW events in **every** port):
`gt_menu_swallow(raw) = gt_is_menu_button(raw) || raw == echo_index`, with
`echo_index` 14 (plain) / 16 (sticks). `gt_is_menu_button` goes through the remap
and follows automatically. This is the fix for "R2 dead everywhere".

Evdev gameplay path (F45, OpenCrossing): replace `gt_evdev_code_sdl_index` +
`gt_remap` with a direct, device-independent `gt_evdev_code_slot(code)`:

| code | 304 | 305 | 306 | 307 | 308 | 309 | 310 | 311 | 313 | 314 | 315 | 316 | else |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| slot | 1 A | 0 B | 2 Y | 3 X | 4 L1 | 5 R1 | 6 Sel | 7 Start | 9 L3 | 10 L2 | 11 R2 | 12 R3 | −1 |

Identical results to the old two-step path for every code the RG SP has (asserted).
The 313→L3 / 316→R3 pairing follows the ascending-order rule from the measured
b12/b15 positions (Appendix B).

gptk names: `l3` → 9, `r3` → 12 in `gt_button_slot`.

Unchanged: the Menu-toggle evdev thread (finds its device by BTN_TL2/KEY_GOTO
capability), hats, the F48 a↔b/x↔y swap (face indices are identical).

### 4.4 Shim: analog-to-key synthesis (F53)

Gate: `gt_map.loaded` (a gptk is active — same as button synthesis) **and** class
== `sticks`. On plain nothing changes, including a stick device that fell back to
plain.

Parser (gptokeyb parity):

- Keys: `left_analog_up|down|left|right`, `right_analog_up|down|left|right`,
  `deadzone`.
- Defaults applied before parsing (gptokeyb `structs.h`): left = `w s a d`
  (up down left right), right = `end home left right`; `deadzone = 15000`.
- A present analog line **replaces** the default: a known key name sets it; an
  unknown name or gptokeyb's `\"` placeholder **clears** it (no key).
- A `mouse_movement_*` value on any direction marks that **stick** mouse-driven; a
  mouse stick synthesizes nothing (gptokeyb skips keys for it entirely).
- `deadzone = N`: integer 1..32767, else keep the default (0 would read a centered stick as deflected).
- Still ignored: `deadzone_x/_y/_triggers/_mode/_scale/_delay`, `mouse_*`, repeat
  flags, modifiers, hold-state lines.
- New key names in `gt_keyname`: `home` (scancode 74), `end` (scancode 77), both
  `sym = 0x40000000 | scancode`.

Axis model: axis 0 = left X, 1 = left Y, 2 = right X, 3 = right Y (stick = axis/2,
Y = axis&1). Negative = up/left. Direction from value: `v <= -dz → −1`,
`v >= dz → +1`, else 0 (gptokeyb: zero iff |v| < deadzone). Per-axis
`prev_dir[4]`.

Event rewrite (new `SDL_JOYAXISMOTION` branch in `gt_rewrite`, axis < 4 only):

1. Mouse stick → pass the axis event through untouched.
2. `cur = dir(value)`; edges = `gt_evdev_hat_edges(prev, cur, slot_neg, slot_pos)`
   (the existing release-before-press helper; `slot_neg` = up/left key,
   `slot_pos` = down/right key of that stick). `prev = cur`.
3. Skip edges whose key is cleared. The **first** emitted key replaces the axis
   event in place; the rest go to the existing stash (same shape as the hat path).
   No emitted edge → the axis event passes through, so hybrid ports keep raw axes.
4. Every key goes through `gt_make_key_event`, which mirrors into the v3 polled
   keystate (LÖVE/BYTEPATH-class games see the stick too).

Idempotence under the WaitEventTimeout→PollEvent double pass holds as for hats: a
re-pass sees a key event (never rewritten) or `prev == cur` (no edges).

Debug (`GT_INPUT_REMAP_DEBUG=1`): `gt-input-remap: axis <n> <value> -> dir <d>` per
transition; the existing `synth key` lines cover the emitted keys.

### 4.5 Profile pin refinement and the stickless hatch (F51 extension, ships with F53)

Token order in the pin case: `tok=$(lowercase "$RGXX_MODEL")` first; if it hits no
arm, `tok=$DEVICE`; if neither, the `*` default. All values this build emits map onto
existing exact-SKU arms: `rgsp rg34xxsp rg35xxh rg35xxplus rg35xxsp rg40xxh
rg40xxv rg28xx rgcubexx`. Bucket arms (`rg34xx rg35xx rg40xx cube`) and `*` stay.

Class refinement, **ambiguous arms only** (exact SKUs are never overridden):

| resolved via | class = sticks → |
|---|---|
| bucket `rg34xx` | `rg34xx-sp` |
| bucket `rg35xx` | `rg35xx-h` |
| `*` unknown | `rg34xx-sp` (720×480 is already the unknown default) |

`GT_PANEL_W/H` unchanged. RAM stays live-detected on both paths (`rg34xx-sp`'s
profile RAM of 2048 is moot).

Hatch: flag file `$USERDATA_PATH/PORTS-portmaster/use-stickless` (the
`use-remap-ports` / `use-hud-blocklist` convention) → `export GT_ANALOG_STICKS=0`.
`edit_portmaster_device_info` inserts, anchored on upstream's `export ANALOG_STICKS`
line: `ANALOG_STICKS=${GT_ANALOG_STICKS:-$ANALOG_STICKS}  # gt-h700-stickless`.
Effect: harbourmaster keeps the true profile (port compatibility stays honest);
every port launcher sees 0 sticks and picks its stickless gptk again; tables are
untouched. No-op on the RG SP.

### 4.6 Reporting switch and docs (F52)

- `$USERDATA_PATH/PORTS-portmaster/use-input-debug` → `export
  GT_INPUT_REMAP_DEBUG=1` in the universal preload block (every port launch).
- README "Other h700 NextUI devices": experimental stick support — what is covered
  (buttons everywhere, sticks in native ports, stick-to-keys in gptk ports), what is
  unverified (no stick device in hand), the report recipe (touch `use-input-debug`,
  play, attach `.userdata/h700/logs/PORTS.txt` — it now carries the class
  breadcrumb), the `use-stickless` hatch.
- `docs/h700-fixes.md`: F52 and F53 sections + terse changelog bullets; F51 section
  drops "stick axes out of scope"; shim header comment stops saying "the RG SP has
  no sticks" and documents the two tables.
- `assets/gt-remap-ports.txt` comment: mention analog lines are honored on stick
  devices.

## 5. Data flow

```
launch.sh (common path, h700)
  /proc/bus/input/devices ──awk──▶ GT_INPUT_CLASS=plain|sticks  ──▶ log breadcrumb
  RGXX_MODEL / DEVICE + class ────▶ $HOME/.config/.DEVICE (harbourmaster + device_info)
  use-stickless? ─────────────────▶ GT_ANALOG_STICKS=0 ──▶ device_info ANALOG_STICKS
  use-input-debug? ───────────────▶ GT_INPUT_REMAP_DEBUG=1
  set_controller_layout <layout> ─▶ files/gamecontrollerdb_<layout>[_sticks].txt → $EMU_DIR/gamecontrollerdb.txt
run_port / GUI (LD_PRELOAD gt-input-remap.so, all ports)
  GT_INPUT_CLASS ─▶ remap table + park + Menu-echo index; evdev code→slot is class-free
  GT_REMAP_GPTK  ─▶ button/hat synthesis (as today) + analog synthesis (sticks only)
```

## 6. Error handling and fail-safe summary

| Condition | Behavior |
|---|---|
| `/proc` node/line missing, < 5 words, unknown word | class `plain`, warning line, RG SP tables, today's DB, no analog |
| `GT_INPUT_CLASS` absent in the shim's env | plain (same as before F52) |
| `RGXX_MODEL` absent or unmatched | bucket token, then `*` default (F51 behavior) |
| gptk analog value unknown / placeholder | that direction emits nothing |
| gptk `deadzone` malformed | default 15000 |
| `_sticks` DB file missing (should not happen) | upstream's existing "not found" error path |

## 7. Testing

Host-side, `make test`:

- **test-03** (device): detection block extracted and run with `GT_INPUT_DEVICES_FILE`
  pointing at each fixture → class + breadcrumb/warning; pin runner extended: model
  precedence, model miss → bucket, refinement under each ambiguous arm with
  `GT_INPUT_CLASS=sticks`, exact SKU immune, `use-stickless` export, device_info
  override line present after upstream's case; staging produces the two `_sticks`
  files with the measured line, plain files byte-identical, restage idempotent;
  extracted `set_controller_layout` copies the right file under each class.
- **test-05** (shim, `-DGT_REMAP_TEST` main): both remap tables over raw 0..16, park
  15/17, swallow index per class, direct evdev slot table vs. the old two-step result
  on RG SP codes and 313/316, `l3`/`r3` slots; analog parser (defaults, override,
  clear on placeholder, mouse stick, `deadzone`), direction at boundaries (14999,
  15000, −15000, 27935), edge sequences (center→up; up→down through center releases
  before pressing; two axes independent), plain class → no synthesis.
- Preload-block test: `use-input-debug` line present.
- **Sibling-test sweep before editing anchored lines** (lesson from F48/F49):
  `grep -rn` tests/ for `gamecontrollerdb_$layout.txt`, `gt_evdev_code_sdl_index`,
  `case 14: return 15`, and the `src=` literal. test-12's pylib spawn count is
  unaffected (no new pylib patch).

Build: `make shim` (docker `--platform` pull first; `file` both `.so`), then
`make pak` (network; sandbox off).

RG SP regression gate (Camille): PORTS.txt shows `input class plain`; GUI navigation
and confirm/back; Celeste (clean SDL); Tunics! and BYTEPATH (shim); Sonic 1 (gptk
overlay + HUD); **Animal Crossing** (the evdev refactor is the one path whose code
changes on the RG SP); one Menu tap toggles the HUD and R2 still works; one power-
button sleep/resume with sound; `use-input-debug` once to see the trace, then remove.

## 8. Delivery

- Branch `feat/stick-devices` off `ae35d8b`; squash-merge to local main; joins the
  unpushed bundle. **No push, no tag** until Camille says.
- Plan in two waves: **Wave 1 = F52** (4.1, 4.2, 4.3, 4.6) — stands alone;
  **Wave 2 = F53** (4.4, 4.5) — the profile flip must not ship without synthesis.
- Release-notes wording (terse style): under `### Fixes`, "Stick-equipped h700
  devices (RG34XXSP, RG35XX-H, RG40XX, CubeXX): correct triggers, stick clicks and
  Menu handling; analog sticks work in native ports and drive keyboard-style ports
  via the built-in translator. **Experimental — not yet verified on hardware; see the
  README for how to report.**"

## Appendix A — measured input records (full `/proc/bus/input/devices`, verbatim)

Both dumps are reproduced in full so the fixtures can be recreated from this file;
the plan commits them as `tests/fixtures/input-devices/{rgsp,rg34xxsp}.txt`.
Note the trailing space after each `Handlers=` value — it is in the kernel output.

RG SP (`ssh root@10.0.1.16`, 2026-09-01, NextUI-20260809-h700-0, `RGXX_MODEL=RGSP`,
`DEVICE=rgsp`):

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

RG34XXSP (volunteer probe log, 2026-09-01, NextUI-20260809-h700-0,
`RGXX_MODEL=RG34xxSP`, `DEVICE=rg34xx`):

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
B: KEY=400000000 1fff000000000000 0 0 c000000000000 2
B: ABS=3003c
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

Both devices: `event0` = `axp2202-pek` (KEY_POWER; F47 sleepmon unchanged); the
key-bitmap word for codes 256–319 is `dff000000000000` (RG SP) vs `1fff000000000000`
(RG34XXSP) — bits 9 and 12 of that word = codes 313 and 316; ABS `30038` vs `3003c`
— bit 2 = ABS_Z, the first real stick axis.

## Appendix B — measured SDL table, RG34XXSP (volunteer trace)

SDL 2.28.5 (NextUI), `axes=4 buttons=17 hats=1`, GUID `19000000010000000100000000010000`.

| button | raw index | evdev code (inferred, ascending rule) |
|---|---|---|
| A | b3 | 304 |
| B | b4 | 305 |
| Y | b5 | 306 |
| X | b6 | 307 |
| L1 | b7 | 308 |
| R1 | b8 | 309 |
| Select | b9 | 310 |
| Start | b10 | 311 |
| Menu (press) | b11 | 312 |
| L3 | b12 | 313 |
| L2 | b13 | 314 |
| R2 | b14 | 315 |
| R3 | b15 | 316 |
| Menu echo (release) | b16 | 354 |
| ESC / Vol− / Vol+ | b0 b1 b2 | 1 / 114 / 115 |

Axes: a0 left X, a1 left Y, a2 right X, a3 right Y; up/left = MIN; a3 MAX seen 27935.
D-pad = hat0 (UP 0x01, RIGHT 0x02, DOWN 0x04, LEFT 0x08).

The RG SP's measured table (v0.1.0 gate) is the same minus 313/316, i.e. L2 b12,
R2 b13, Menu echo b14, 15 buttons, 3 phantom axes.

## Appendix C — gptokeyb reference (PortsMaster/gptokeyb, main, read 2026-09-01)

`src/structs.h`: `deadzone = 15000; deadzone_y = 15000; deadzone_x = 15000;
deadzone_triggers = 3000; deadzone_scale = 512;` `left_analog_up = KEY_W, _down =
KEY_S, _left = KEY_A, _right = KEY_D; right_analog_up = KEY_END, _down = KEY_HOME,
_left = KEY_LEFT, _right = KEY_RIGHT`.
`src/keyboard.cpp`: `_ANALOG_AXIS_ZERO(v) = abs(v) < config.deadzone`; positive /
negative = not zero and sign; per-direction `was_` state via `handleAnalogTrigger`;
a stick in mouse mode (`left_analog_as_mouse`) skips key emission.
