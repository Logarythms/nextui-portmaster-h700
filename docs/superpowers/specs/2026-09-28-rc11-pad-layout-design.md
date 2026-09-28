# NextUI-h700 rc11 fixed pad layout (F65) — design

Date: 2026-09-28. Branch: `feat/rc11-pad-layout` (worktree `~/dev/nextui-portmaster-h700-rc11`, off
main `c15216f`). Status: approved design, awaiting implementation plan. Ships in **0.5.0** as **F65**.

## Context

NextUI-h700 **rc11** (pre-release, 2026-09-27) changes how its SDL 2.28.5 fork numbers the built-in pad.
The change lives in LoveRetro/h700-toolchain `support/sdl2-h700.patch` (commits `46cc4d73`, `04faa348`),
not in pvaibhav/NextUI. It is shipped in `NextUI-v6.14.0-h700-rc11.zip` → `MinUI.zip` →
`.system/h700/lib/libSDL2-2.0.so.0`. Spike notes (2026-09-27, read-only) are in the session memory
"nextui-h700-rc11-fixed-sdl-layout". The facts this design builds on, read from the patch source:

- The built-in pad (`ANBERNIC-keys`, BUS_HOST, vendor 1, product 1) gets a **tagged GUID**:
  `19000000010000000100000000016e01` (GUID byte 14 = `'n'`, byte 15 = 1). rc10 and older reported
  `19000000010000000100000000010000`, so every mapping written for the old ID stops matching.
- Buttons use **one fixed layout on every model**, "matching TrimUI "Player1" and Xbox 360 raw indices"
  (the patch's own comment). There are 15 buttons, and 11 and 12 never fire:

  | evdev | SDL | control | | evdev | SDL | control |
  |---|---|---|---|---|---|---|
  | 305 | b0 | B (south) | | 311 | b7 | Start |
  | 304 | b1 | A (east) | | 312 | b8 | Menu |
  | 306 | b2 | Y (west) | | 313 | b9 | L3 |
  | 307 | b3 | X (north) | | 316 | b10 | R3 |
  | 308 | b4 | L1 | | 114 | b13 | Vol− |
  | 309 | b5 | R1 | | 115 | b14 | Vol+ |
  | 310 | b6 | Select | | | | |

  KEY_ESC and Menu's KEY_GOTO echo (354) are dropped, so Menu is one clean b8.
- **L2/R2 (evdev 314/315) are trigger axes 2/5**: +32767 when pressed, −32768 when released.
- **Sticks**: axes 0/1 = left X/Y, 3/4 = right X/Y. On stickless models they stay centred. The D-pad is
  hat 0, unchanged.
- SDL adds a built-in positional ("xbox") mapping for the tagged GUID at DEFAULT priority, so our
  `gamecontrollerdb` lines override it.
- `SDL_JOYSTICK_H700_FIXED_LAYOUT=0` restores the old GUID and the old numbering.

The pak's input stack (F25/F26/F31/F34/F45/F48–F53) was built for rc10's ascending numbering. On rc11 it
breaks in several places. The DB lines never match, so the GUI and the layout setting are ignored. The
shim's rc10 index table scrambles buttons. F53 reads L2 as right-stick X. The HUD swallows Vol+ and leaks
Menu. Cave Story's blob binds wrong buttons. Balatro's saved map silently stops matching. The rc11
numbering is exactly what the shim's v1 remap was built to fake on rc10, so most of the work is removal.

## Goals

1. On rc11, every input path of the pak works on the built-in pad: the GUI, SDL-GameController ports,
   gptokeyb (passthrough and the Select+Start quit), shim synthesis ports, the HUD Menu tap, Cave Story,
   Balatro, and Animal Crossing's evdev path.
2. The Nintendo/Xbox layout setting (global and per-game) keeps working.
3. Existing installs migrate without user action: Cave Story keeps in-game rebinds, and Balatro asks for
   its button check once.
4. rc10-only machinery is deleted, not kept alongside.

## Non-goals

- **Anything older than rc11**, and the `SDL_JOYSTICK_H700_FIXED_LAYOUT=0` hatch. Both are unsupported
  (see Decisions).
- External pads, beyond "rc11 treats them like the built-in pad" (see Known limits).
- Ports that bundle their own 64-bit SDL. They number buttons their own way, as before.
- Merging GT Probe (`feat/gt-probe` stays unmerged, per Camille). It is used only as a measurement tool.
- Pushing, tagging and releasing. Those are Camille's calls.

## Decisions (2026-09-28, Camille)

1. **rc11 is the floor.** No compatibility with rc10 or older, and none with the hatch. rc11 is expected
   to become the version merged into NextUI main. This supersedes the 2026-09-27 choice of native
   rc10+rc11 support ("option B").
2. **Release:** F65 goes into **0.5.0**. It extends the existing `### 0.5.0` changelog block in
   `docs/h700-fixes.md` and `docs/release-notes-v0.5.0.md`. 0.5.0 is published as a **GitHub
   pre-release** alongside the rc11 preview, so people can test before rc11 goes final.
3. **Balatro-class ports: force the port's own button check once** (option C). The pak moves a map
   recorded on the pre-rc11 pad ID aside, and Balatro's "no file → ask" rule does the rest. The F50
   ruling stands: the pak never rewrites a port's own mapping.
4. **No per-pad ID check in the shim.** rc11's numbering is the standard Xbox 360 layout, which most
   external pads share, so every pad is treated the same.
5. **Old-firmware check = the tagged GUID string in the system `libSDL2`.** This is sturdier than the hint
   name or `version.txt`, because the tag is how rc11 blocks old mappings. The check only logs a warning
   and holds back the two one-way migrations. Nothing else special-cases old firmware.
6. Worktree off main, one squash commit on main (pak convention). Camille merges, pushes and tags.

## Design

### 1. Shim (`assets/gt-input-remap.c`, both `.so` builds)

**Removed** (rc10-only):
- the v1 raw-index remap: `gt_remap_plain`, `gt_remap_sticks`, `gt_remap`, `GT_PARK_PLAIN`/`GT_PARK_STICKS`,
  the ESC/Vol/GOTO parking, and the jbutton rewrite block in `gt_rewrite`, including its
  `GT_REMAPPED_MARKER` once-only guard, which existed only for that rewrite
- `gt_menu_echo_index` and the echo half of `gt_menu_swallow`
- `gt_remap_on()` and the shim's use of `GT_INPUT_REMAP`. launch.sh stops exporting it (§2). The
  allowlist keeps arming synthesis through `GT_REMAP_GPTK`.
- the rc10 parts of the top-of-file comment. It is rewritten to describe the rc11 model.

**Synthesis slot numbering = rc11 SDL indices.** `gt_button_slot`: b 0, a 1, y 2, x 3 (the `gt_ab_swap`
Xbox swap is unchanged), l1 4, r1 5, back/select 6, start 7, guide 8, l3 9, **r3 10** (was 12).
**l2/r2** move out of the button space into a separate `trigger_key[2]` in `gt_keymap` (0 = l2, 1 = r2),
so no raw button index can ever reach them. Button events index `button_key` by their raw index
directly. `gt_is_menu_button(raw)` becomes `raw == 8`.

**Triggers (new).** A pure helper turns a trigger-axis value into pressed/released (pressed iff
value > 0) with edge tracking per trigger. In `gt_rewrite`, an `SDL_JOYAXISMOTION` on axis 2 or 5, when
`gt_map.loaded`, becomes the l2/r2 key event on an edge. It replaces the event in place, using the same
shape as the hat path. When there is no mapped key or no edge, the axis event passes through unchanged,
so the game sees a native trigger. This is re-pass safe: a key event is never rewritten, and prev == cur
gives no edge.

**Sticks (F53).** `gt_axis_slots`: axes 0/1 → left stick, 3/4 → right stick (was `axis/2` over 0..3).
Axes 2/5 never reach the analog path. It stays gated on `gt_sticks_class`, so the RG SP's phantom axes
stay inert. `gt_axis_prev` is sized for 6 axes.

**Evdev path (F45, Animal Crossing).** `gt_evdev_code_slot` follows the new slots: 304→1, 305→0,
306→2, 307→3, 308→4, 309→5, 310→6, 311→7, 313→9, **316→10**. The evdev thread handles 314/315 (L2/R2)
separately and drives `trigger_key[0/1]`.

**Menu.** `gt_hud_intercept` swallows **b8** on both press and release. The toggle authority stays the
evdev thread, which is unchanged (it reads evdev 312 directly).

**Unchanged:** F54 passthrough, F31 keystate merge, the HUD draw paths, gt-sleepmon, `gt_ensure_joystick_open`,
`GT_INPUT_CLASS` loading (it still gates F53), and the debug trace.

### 2. Controller DB and launch.sh (`assets/`, `build/build-pak.sh`)

**DB lines.** `gamecontrollerdb-h700-{nintendo,xbox}.txt`: the old-ID line is replaced by one rc11 line.
The same line works on every model; sticks and triggers are included, and they never move on stickless
devices:
- xbox (= SDL's built-in rc11 mapping):
  `19000000010000000100000000016e01,ANBERNIC-keys,a:b0,b:b1,x:b2,y:b3,back:b6,start:b7,guide:b8,leftshoulder:b4,rightshoulder:b5,leftstick:b9,rightstick:b10,lefttrigger:a2,righttrigger:a5,leftx:a0,lefty:a1,rightx:a3,righty:a4,dpup:h0.1,dpdown:h0.4,dpleft:h0.8,dpright:h0.2,platform:Linux,`
- nintendo: the same line with `a:b1,b:b0,x:b3,y:b2`. This matches the NextUI wiki example.
- Header comments name the source (the patch mapping, confirmed by the §4 measurement pass).

This covers the GUI (pugwash via `set_controller_layout`, plus the F48 PlatformTrimUI confirm/back patch),
gptokeyb, and every SDL-GameController port. All of them read the file through
`SDL_GAMECONTROLLERCONFIG_FILE`.

**Retired:** `assets/gamecontrollerdb-h700-sticks-{nintendo,xbox}.txt`, the `_sticks` fork in
`stage_controllerdb_classes` (it goes back to plain appends; the "ORDER MATTERS" constraint is gone), and
the `gt-h700-controller-db-class` launch.sh hook (upstream's `src=` line stays). After an unzip-over,
stale `files/gamecontrollerdb_*_sticks.txt` remain on the card. Nothing reads them.

**Remap allowlist hook** (`gt-h700-port-remap`): drop `export GT_INPUT_REMAP=1`. The allowlist still
exports `GT_REMAP_GPTK`. Its log line becomes "Enabling input synthesis for $ROM_NAME".

**Firmware check (new, inside the `gt-h700-device-pin` block).** `SYSTEM_LIB_DIR` is already set above
that block by `gt-h700-syslib`.
- `GT_NEXTUI_RC11=1` iff the tagged GUID string is in `"$SYSTEM_LIB_DIR/libSDL2-2.0.so.0"`, else `0`.
  The value is exported. The scan is `LC_ALL=C tr -cs 0-9a-f "\n" <lib | grep -q -x <guid>`. A plain
  busybox `grep -q` needs about 2.8 s on the 8 MB rc11 library (measured on the RG SP, 2026-09-28), while
  tr+grep takes 0.13 s, so no cache is needed. A cache keyed on mtime would also be wrong here, because
  unzipping a NextUI update keeps the archive's file times.
- One log line either way: `gt-h700: NextUI pad layout rc11`, or
  `gt-h700: WARNING: this NextUI is older than rc11 - controls will be wrong; please update NextUI`.
- Read only by the §3 migrations. The shim does not read it.

**Unchanged:** the input-class detection (device profile, F53 bucket refinement, F56 warning, stick gate)
and `set_controller_layout`.

### 3. Game-specific (Cave Story, Balatro)

**Cave Story (nxengine-evo; F39 blob, F49 conform).** `settings.dat` layout: magic `NXS7`, 964 bytes,
28 binding records of 24 bytes starting at offset 36. Field 1 (record+4) = `jbut` (int32 LE, −1 =
unbound).
- **Shipped blob** `assets/nxengine-evo-h700-settings.dat`: records 4–10 `jbut` change from
  `4,3,5,9,10,7,8` to **`0,1,2,6,7,4,5`**. Every other byte stays identical.
- **Fresh install** (F39 block): as today, and it also writes the stamp `conf/nxengine/.gt-h700-rc11`.
- **One-time migration** of an existing install. It runs when the F39 marker is present, the rc11 stamp
  is absent, and `GT_NEXTUI_RC11=1`. It translates `jbut` of all 28 records from rc10 to rc11 numbering,
  so rebinds survive. The rc10 source table depends on `GT_INPUT_CLASS`:
  - plain (RG SP): 1→13, 2→14, 3→1, 4→0, 5→2, 6→3, 7→4, 8→5, 9→6, 10→7, 11→8
  - sticks: the same, plus 12→9 (L3) and 15→10 (R3)
  - every other button (ESC 0, L2/R2, the GOTO echo) → −1, and −1 stays −1

  It reads the 28 fields with one `od` call and writes back only the changed ones with `dd conv=notrunc`.
  The magic and size guards stay as in F49. The stamp is written only if every write succeeded. After a
  migration the F49 layout stamp is cleared, so the conform step re-applies.
- **Layout conform** (F49, same helper, runs after the migration): JUMP/FIRE values are rc11's.
  Nintendo JUMP=1 (A, east), FIRE=0 (B, south). Xbox JUMP=0, FIRE=1. The stamp semantics are unchanged.
- It stays one helper (`assets/gt-nxengine-conform-layout.sh`) called from the existing F49 hook. The
  helper reads `GT_NEXTUI_RC11` and `GT_INPUT_CLASS` from the environment.

**Balatro (and any port using its button-wizard framework).** Balatro's launcher runs its wizard when
`$BUTTON_MAP_FILE` is missing. The saved line starts with the pad GUID captured at wizard time. A skipped
or timed-out check writes a comment-only file.
- **New run_port hook `gt-h700-button-map-rc11`.** Its logic lives in `assets/gt-button-map-rc11.sh`,
  which is staged to `files/` and called with the launcher path and `$GAMEDIR`, so it can be tested
  directly. It acts only when `GT_NEXTUI_RC11=1` and the launcher
  contains `BUTTON_MAP_FILE="$GAMEDIR/…"`. It resolves that path. If the file's first non-comment,
  non-blank line matches `190000000100000001000000????0000,*` (the pre-rc11 built-in ID; the `????` is
  its version field), it renames the file to `<file>.pre-rc11` (overwriting any older backup) and logs
  `gt-h700: <port> button map predates rc11 - the port will ask for its button check once`.
- A comment-only file, or a map recorded on any other ID (an external pad), is left alone.
- The launcher is never edited, so its mtime is untouched and Balatro does not rebuild (F32).
- The F50 GUI disclaimer for Balatro-class ports is unchanged.

### 4. Testing, device work, docs

**Host tests (`make test`)**
- test-05 / test-26 (shim host `main()` under `-DGT_REMAP_TEST`): the rc10 table cases are replaced by
  checks for the rc11 slot numbering (Nintendo and Xbox), the trigger edge helper (press, release,
  repeat), `gt_axis_slots` 0/1/3/4, `gt_evdev_code_slot` checked against the patch's button table, and
  swallow of b8 only. test-05's launch.sh asserts drop `GT_INPUT_REMAP=1` and keep the `GT_REMAP_GPTK`
  gating.
- test-03 (device/DB): one rc11 line per layout in the staged DBs, no `_sticks` files, no class-DB hook
  in the built launch.sh. The firmware check runs against fixture `libSDL2` files with and without the
  ID, checking `GT_NEXTUI_RC11` and the log line.
- test-15 (Cave Story): blob values; migration for plain and sticks (−1 handling, a custom rebind
  surviving, stamp written only on success); no-op when stamped or when `GT_NEXTUI_RC11=0`; rc11 conform
  values for both layouts.
- **test-36** (new, Balatro hook): old-ID map moved to `.pre-rc11`; comment-only and other-ID maps
  untouched; `GT_NEXTUI_RC11=0` = no-op; launcher mtime unchanged.
- Hygiene: `grep -rn` `tests/` for the old ID and the old table values (the lesson from
  "rgsp-controller-layout-config"). Rebuild both `.so` with `make shim` and check them with `file`
  (aarch64 and armhf).

**Device (RG SP, stickless)**
- **Measurement pass, before any shim code (Camille installs rc11 at this point).** Run `gt-joyprobe`
  (from `feat/gt-probe`, used as a tool, nothing installed into the pak) over ssh against the system SDL.
  Confirm: pad GUID, SDL's built-in mapping string, b0–b10/b13/b14 per the table above, Menu as a single
  b8 with no ESC, L2/R2 on a2/a5 at ±32767, a hat-0 D-pad, and no stray axis motion. Also confirm the
  firmware check (`grep` on the device lib). Any deviation from the patch source stops the work for a
  design revision.
- **Final gate** (full build, unzip-over install):
  1. the launch log shows the rc11 line
  2. GUI navigation, confirm/back for each layout, and the layout toggle
  3. Celeste on each layout
  4. BYTEPATH and Tunics! through passthrough, including the Select+Start quit
  5. Sonic 1 on the synthesis path
  6. a Menu tap toggles the HUD without leaking into the game, and the Menu+Vol brightness combo still
     works
  7. Cave Story: an existing install migrates (JUMP/FIRE correct, an in-game rebind survives), then a
     layout change conforms
  8. Balatro: the button check appears once, then not again, and the new map works
  9. Animal Crossing (evdev path) and sleep (power and lid) still work
- Stick devices are host-tested only, so the EXPERIMENTAL label stays.

**Docs (0.5.0 blocks)**
- `docs/h700-fixes.md`: a new F65 section and a line in the `### 0.5.0` changelog. Earlier F-sections
  get a one-line "superseded by F65 on rc11" note where they describe rc10 numbering (F25/F26, F52/F53
  tables, F49 values).
- `docs/release-notes-v0.5.0.md` (per the pak release-notes style: non-technical, one ⚠️ per behavior
  change): ⚠️ **needs NextUI rc11 or newer**, with an "update NextUI first" upgrade step; ⚠️ Balatro
  asks for its button check once; Cave Story keeps its controls. It notes that 0.5.0 is a pre-release
  for testing with the rc11 preview.
- README: the requirement line, plus "Other h700 NextUI devices" and "Changing the button layout" where
  they describe rc10 behavior.

## Known limits

- **rc10 and older, and the hatch, are unsupported.** On them the new pak's controls are wrong. There
  is a launch-log warning, and the one-way migrations wait for rc11.
- **External pads** get the same synthesis and Menu-swallow treatment as the built-in pad. That is right
  for Xbox-layout pads. An oddly numbered pad may see its b8 swallowed.
- A `settings.dat` that nxengine-evo regenerated itself (after the user deleted it) is still treated as
  rc10-numbered if the F39 marker exists. This is a pre-existing class of stale-stamp edge case.
- The Cave Story migration unbinds rc10 L2/R2 bindings (they are axes on rc11) instead of translating
  them to axis bindings.
- Stick-device paths (F53 axes 0/1/3/4, L3/R3) are host-tested only.

## Follow-ups (recorded, not built)

- If NextUI main later drops the tagged GUID string, update the firmware check.
- A d-pad-as-left-stick option for stick-only ports (from the issue-1 triage) is unchanged by this work.

## Task map

1. Device measurement pass on rc11 (gates everything below).
2. Shim rc11 numbering (§1), with its host tests and both `.so` rebuilt.
3. Controller DB, retiring the class-DB copies, and the firmware check (§2), with test-03/test-05.
4. Cave Story blob, migration and conform (§3), with test-15.
5. Balatro move-aside hook (§3), with test-36.
6. Docs (§4).
7. Full build, final device gate, squash commit.
