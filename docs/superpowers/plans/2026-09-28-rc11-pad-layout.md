# NextUI-h700 rc11 pad layout (F65) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every input path of the PortMaster pak work on NextUI-h700 rc11's fixed pad layout, and remove the rc10-only machinery. rc11 is the minimum supported firmware.

**Architecture:** rc11's SDL numbers the built-in pad like TrimUI/Xbox 360 on every model. The input shim therefore stops remapping indices and only re-bases its synthesis (gptk slots, trigger axes, stick axes, Menu swallow) on that numbering. The controller DB gets one class-free rc11 line per layout. A cheap launch.sh check (`GT_NEXTUI_RC11`) gates two one-way migrations: Cave Story's `settings.dat` and Balatro's saved button map.

**Tech Stack:** C (LD_PRELOAD shim, host-tested with `-DGT_REMAP_TEST`, device-built via `make shim` in arm64/armhf bullseye containers), POSIX sh / busybox (launch.sh injected by awk from `build/build-pak.sh`), Python 3 (tests and one-off edit programs), the RG SP over ssh.

**Spec:** `docs/superpowers/specs/2026-09-28-rc11-pad-layout-design.md`

## Global Constraints

- **Workspace:** all work happens in the worktree `~/dev/nextui-portmaster-h700-rc11` on branch `feat/rc11-pad-layout`. Never switch branches, build or run tests in the main checkout `~/dev/nextui-portmaster-h700`. Never push, tag or merge; Camille does those.
- **rc11 is the floor.** No rc10 compatibility, and no support for `SDL_JOYSTICK_H700_FIXED_LAYOUT=0`.
- **rc11 numbering (exact):** B b0, A b1, Y b2, X b3, L1 b4, R1 b5, Select b6, Start b7, Menu b8, L3 b9, R3 b10, Vol− b13, Vol+ b14. b11/b12 never fire. L2/R2 = axes a2/a5 (+32767 pressed, −32768 released). Sticks = a0/a1 (left), a3/a4 (right). D-pad = hat 0.
- **IDs (exact strings):** rc11 built-in GUID `19000000010000000100000000016e01`. The pre-rc11 built-in ID pattern is `190000000100000001000000????0000` (the `????` is the version field).
- **Names (exact):** env `GT_NEXTUI_RC11` (`1`/`0`); helper `assets/gt-button-map-rc11.sh` → `files/gt-button-map-rc11.sh`; Cave Story stamp `conf/nxengine/.gt-h700-rc11`; Balatro backup `<map>.pre-rc11`; launch.sh markers `gt-h700-rc11 (F65)` and `gt-h700-button-map-rc11 (F65)`. `GT_INPUT_REMAP` is removed. `GT_INPUT_REMAP_DEBUG` stays.
- **Log lines (exact):**
  - `gt-h700: NextUI pad layout rc11`
  - `gt-h700: WARNING: this NextUI is older than rc11 - controls will be wrong; please update NextUI`
  - `gt-h700: <port> button map predates rc11 - the port will ask for its button check once`
  - `Enabling input synthesis for $ROM_NAME`
- **Tests:** the suite is `make test` (= `sh tests/run.sh`). Run one test with `sh tests/test-NN-*.sh`. Never run two suites at once.
- **Builds:** `make shim` and `make pak` need Docker and network (snapshot.debian.org, pinned downloads), so run them with the sandbox disabled. After `make shim`, `file`-check both remap shims (aarch64 and ARM EABI5). Commit only `assets/gt-input-remap.so` and `assets/gt-input-remap.armhf.so`; revert any other rebuilt binary with `git checkout -- <file>`.
- **Edit programs:** Tasks 1–5 apply exact, pre-validated edits through small Python programs embedded below. Save each block verbatim to a scratch directory outside the repo (`mktemp -d`) and run it from the worktree root. Every edit asserts that its anchor occurs exactly once, so a drifted tree fails loudly and never half-applies silently. If one fails, stop and report; don't hand-patch around it. After a program runs, review the resulting `git diff`: that diff is the code under review.
- **Device:** the RG SP is `ssh root@10.0.1.16` (use `scp -O`). It is Camille's device. Ask him before installing anything, stopping processes, or changing files on it. Read-only probes are fine. **Tasks 0 and 6 need Camille pressing buttons live, so the coordinating session runs them itself; they are not dispatched to a subagent.**
- **Commits:** one commit per task on the branch, message style `feat(F65): …`. End each message with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>` and no `Claude-Session` trailer. The branch lands on main later as ONE squash commit (pak convention), done by Camille.
- **Docs style:** release notes follow the pak style: terse bullets with bold lead-ins, one ⚠️ per behaviour change, non-technical.

**User decisions (already made):**
- 2026-09-28: "we do not need to keep compatibility with anything older than rc11". rc11 is the floor, and this supersedes the 2026-09-27 dual-numbering choice.
- 2026-09-28: F65 goes into 0.5.0 (option A) and extends the existing `### 0.5.0` changelog and `docs/release-notes-v0.5.0.md`.
- 2026-09-28: 0.5.0 is released as a GitHub pre-release alongside the rc11 preview.
- 2026-09-28: Balatro-class ports: force the port's own button check once (option C). The pak never rewrites the port's mapping (F50).
- 2026-09-28: approach approved: no per-pad GUID check in the shim; every pad is treated with rc11 numbering.
- 2026-09-28: use a dedicated git worktree.
- 2026-09-27: the hatch-only stopgap (`SDL_JOYSTICK_H700_FIXED_LAYOUT=0` as the fix) is rejected.

---

## File map

| File | Change | Task |
|---|---|---|
| `assets/gt-input-remap.c` | rc11 slot numbering, trigger/stick axes, b8 swallow; v1 remap removed; host tests in `main()` | 1 |
| `assets/gt-input-remap.so`, `assets/gt-input-remap.armhf.so` | rebuilt | 1 |
| `assets/gamecontrollerdb-h700-{nintendo,xbox}.txt` | one rc11 line each | 2 |
| `assets/gamecontrollerdb-h700-sticks-{nintendo,xbox}.txt` | deleted | 2 |
| `build/build-pak.sh` | firmware check, `stage_controllerdb`, class-DB hook removed, `GT_INPUT_REMAP` dropped (T2); F39 stamp (T3); Balatro hook + staging (T4) | 2, 3, 4 |
| `tests/test-03-device.sh`, `tests/test-05-input-remap.sh` | rc11 DB, firmware check, remap-hook asserts | 2 |
| `assets/nxengine-evo-h700-settings.dat` | renumbered to rc11 | 3 |
| `assets/gt-nxengine-conform-layout.sh` | one-time migration + rc11 conform values | 3 |
| `tests/test-15-nxengine-settings.sh` | blob, migration, conform asserts | 3 |
| `assets/gt-button-map-rc11.sh` (new), `tests/test-36-rc11-button-map.sh` (new) | Balatro move-aside helper + test | 4 |
| `docs/h700-fixes.md`, `docs/release-notes-v0.5.0.md`, `README.md` | F65 docs | 5 (gate paragraph: 6) |

Task order is strict (0 → 6). Tasks 2–4 all edit `build/build-pak.sh`, and Task 0 gates everything.

---

### Task 0: Device measurement pass on rc11

**Goal:** Confirm, on the RG SP running NextUI rc11, that the pad behaves exactly as the SDL patch source says, before any shim code is written.

> **USER-ORDERED GATE — NON-SKIPPABLE.** This task was requested by the user in the current conversation. It MUST NOT be closed by walking around it, by declaring it "verified inline", or by substituting a cheaper check. Close only after every item in `acceptanceCriteria` has been re-validated independently, with output captured.

**Files:** none in the repo. The probe binary is extracted to scratch from `feat/gt-probe` and deleted from the device afterwards.

**Acceptance Criteria:**
- [ ] `/mnt/SDCARD/.system/version.txt` reads `NextUI-v6.14.0-h700-rc11` (or newer rc11+).
- [ ] The probe reports the built-in pad as `guid=19000000010000000100000000016e01` with `axes=6 buttons=15 hats=1`, and its `builtin-mapping` line equals the patch mapping in the spec's Context section.
- [ ] Pressing B, A, Y, X, L1, R1, Select, Start, Menu, Vol−, Vol+ logs exactly b0, b1, b2, b3, b4, b5, b6, b7, b8, b13, b14. The Menu tap produces one b8 down/up and no other button.
- [ ] L2/R2 log as axis edges on a2/a5 (raw +32767 pressed, −32768 released), not as buttons. The d-pad logs hat 0 values 0x01/0x02/0x04/0x08.
- [ ] Nothing ever fires b11/b12, and no stick axis moves on the stickless RG SP.
- [ ] Firmware check on the device: `LC_ALL=C tr -cs 0-9a-f "\n" < …/libSDL2-2.0.so.0 | grep -q -x 19000000010000000100000000016e01` exits 0. `od -An -v -t d4 -j 36 -N 672` works on a copy of a `settings.dat`.
- [ ] Device left clean: `/tmp/gt-joyprobe*` removed and `nextui.elf` running (not stopped).

**Verify:** the probe log saved to scratch, plus the grep/od exit codes, quoted in the task's close note.

**Steps:**

- [ ] **Step 1: Static facts (read-only).**

```bash
ssh -o BatchMode=yes root@10.0.1.16 'cat /mnt/SDCARD/.system/version.txt | head -2
L=/mnt/SDCARD/.system/h700/lib/libSDL2-2.0.so.0
LC_ALL=C tr -cs 0-9a-f "\n" < $L | grep -q -x 19000000010000000100000000016e01; echo "rc11-id rc=$?"
f=$(find /mnt/SDCARD -path "*conf/nxengine/settings.dat" 2>/dev/null | head -1); echo "cave story: ${f:-none}"
[ -n "$f" ] && cp "$f" /tmp/gt-od.dat && od -An -v -t d4 -j 36 -N 672 /tmp/gt-od.dat | head -3; rm -f /tmp/gt-od.dat'
```
Expected: `NextUI-v6.14.0-h700-rc11`, `rc11-id rc=0`, and signed decimal rows from `od` (the planning pass saw `rc=0` in 0.13 s).

- [ ] **Step 2: Stage the probe (read-only for the pak).**

```bash
SCR=$(mktemp -d)
git -C ~/dev/nextui-portmaster-h700-rc11 show feat/gt-probe:probe/gt-joyprobe > "$SCR/gt-joyprobe"
file "$SCR/gt-joyprobe"          # must say: ELF 64-bit LSB pie executable, ARM aarch64
scp -O "$SCR/gt-joyprobe" root@10.0.1.16:/tmp/gt-joyprobe && ssh root@10.0.1.16 'chmod +x /tmp/gt-joyprobe'
```

- [ ] **Step 3: Ask Camille and run the probe.** Tell Camille in chat, as plain text rather than inside an AskUserQuestion: the NextUI menu will be frozen with `kill -STOP` for about 60 s so button presses don't navigate it, and resumed with `kill -CONT` afterwards. Don't press Power. Wait for his go. Then give him the press sequence: **B, A, Y, X, L1, R1, Select, Start, Menu (one tap), Vol−, Vol+, L2 (hold ~1 s), R2 (hold ~1 s), d-pad up, right, down, left**. Run:

```bash
ssh root@10.0.1.16 'P=$(pidof nextui.elf); kill -STOP $P
LD_LIBRARY_PATH=/mnt/SDCARD/.system/h700/lib /tmp/gt-joyprobe 60 > /tmp/gt-joyprobe.log 2>&1
kill -CONT $P; echo resumed'
ssh root@10.0.1.16 'cat /tmp/gt-joyprobe.log' | tee "$SCR/gt-joyprobe-rc11.log"
```

- [ ] **Step 4: Compare against the acceptance criteria.** Check the device line (`guid=`, `builtin-mapping`, `axes=6 buttons=15 hats=1`), the event lines (`joyN bK down/up`, `joyN aK -> … (raw …)`, `joyN h0 0x..`) and the summary block. **Any deviation from the table stops the plan:** report it to Camille and revise the spec and plan before Task 1.

- [ ] **Step 5: Clean up and record.**

```bash
ssh root@10.0.1.16 'rm -f /tmp/gt-joyprobe /tmp/gt-joyprobe.log; P=$(pidof nextui.elf); grep State /proc/$P/status'
```
Expected: `State: S (sleeping)` or `R`, never `T (stopped)`. Keep `$SCR/gt-joyprobe-rc11.log`; Task 5's gate paragraph cites it. No commit.

```json:metadata
{"files": [], "verifyCommand": "ssh root@10.0.1.16 'cat /mnt/SDCARD/.system/version.txt' && review the gt-joyprobe log against the rc11 table", "acceptanceCriteria": ["version.txt shows rc11", "probe: guid ...016e01, axes=6 buttons=15 hats=1, builtin-mapping = patch mapping", "presses log b0..b8, b13, b14; Menu = single b8", "L2/R2 = a2/a5 axis edges; d-pad = hat 0", "no b11/b12, no stick motion", "tr|grep rc 0; od -j -N works", "device clean: probe removed, nextui.elf not stopped"], "modelTier": "frontier", "userGate": true, "tags": ["user-gate"]}
```

---

### Task 1: Shim speaks rc11 numbering (`gt-input-remap.c`)

**Goal:** Remove the rc10 index remap from the shim and re-base synthesis, triggers, sticks and the Menu swallow on rc11's numbering, with host tests, and rebuild both `.so`.

**Files:**
- Modify: `assets/gt-input-remap.c` (the whole v1 remap block, `gt_button_slot`, `gt_evdev_code_slot`, `gt_keymap`, `gt_gptk_line`, `gt_axis_slots`, `gt_is_menu_button`, the interposer flags, the evdev thread, `gt_rewrite`, `gt_hud_intercept`, and `main()` under `GT_REMAP_TEST`)
- Rebuild: `assets/gt-input-remap.so`, `assets/gt-input-remap.armhf.so`
- Test: `tests/test-05-input-remap.sh` and `tests/test-26-controller-layout-shim.sh` both compile and run `main()`. No edits to those two files in this task.

**Acceptance Criteria:**
- [ ] `gt_remap*`, `GT_PARK_*`, `gt_menu_echo_index`, `gt_menu_swallow`, `GT_REMAPPED_MARKER`, `gt_remap_on` and the string `"GT_INPUT_REMAP"` no longer exist in the file.
- [ ] `gt_button_slot`: b0 a1 y2 x3 (the xbox layout swaps a/b and x/y), l1 4, r1 5, back/select 6, start 7, guide 8, l3 9, **r3 10**. `l2`/`r2` return −1 there, and `gt_trigger_slot` returns 0/1.
- [ ] `gt_keymap.trigger_key[2]` is driven by `SDL_JOYAXISMOTION` on axes 2/5 through `gt_trigger_edge` (pressed iff value > 0). An unmapped trigger, or a non-edge value, passes through.
- [ ] `gt_axis_slots` maps 0/1 → left stick and 3/4 → right stick, and returns 0 for 2/5/others. The F53 path stays gated on `gt_sticks_class`.
- [ ] The evdev path maps 304–311/313/316 to rc11 slots (316→10) and 314/315 to `trigger_key[0/1]`.
- [ ] `gt_hud_intercept` swallows only b8.
- [ ] `cc -O2 -Wall -Wextra -DGT_REMAP_TEST` compiles without warnings and prints `remap ok`.
- [ ] `make shim` builds. `file` shows `gt-input-remap.so` = ELF 64-bit ARM aarch64 and `gt-input-remap.armhf.so` = ELF 32-bit ARM EABI5.

**Verify:** `sh tests/test-05-input-remap.sh && sh tests/test-26-controller-layout-shim.sh` → both OK (test-05 prints no failure; test-26 prints `test-26-controller-layout-shim OK`).

**Steps:**

- [ ] **Step 1: Write the failing tests.** Save as `$SCR/t1_tests.py` and run `python3 "$SCR/t1_tests.py" assets/gt-input-remap.c`. It rewrites the rc10 table, Menu and evdev cases in `main()` into rc11 cases, and adds the trigger, stick-axis and r3/l2/r2 cases.

```python
import re, sys
p = sys.argv[1]
s = open(p).read()

def rep(old, new, count=1):
    global s
    n = s.count(old)
    if n != count:
        sys.exit(f"expected {count} of:\n{old[:200]}\n--- found {n}")
    s = s.replace(old, new)

def rep_between(start, end, new):
    """replace from start marker (inclusive) through end marker (inclusive)"""
    global s
    a = s.find(start)
    if a < 0: sys.exit("start not found: " + start[:80])
    b = s.find(end, a)
    if b < 0: sys.exit("end not found: " + end[:80])
    b += len(end)
    s = s[:a] + new + s[b:]

# ---------- 9. main(): class + table tests ----------

rep_between(
"""    (void)argc; (void)argv;
    static const struct { unsigned char in, out; } cases[] = {
""",
"""    if (gt_remap(14) != 15) return fail("plain: raw 14 still parks at 15");
""",
"""    (void)argc; (void)argv;
    unsigned i;
    /* F65: GT_INPUT_CLASS only gates F53 now (rc11 has one table for all). */
    setenv("GT_INPUT_CLASS", "sticks", 1); gt_class_load();
    if (!gt_sticks_class) return fail("GT_INPUT_CLASS=sticks not loaded");
    setenv("GT_INPUT_CLASS", "plain", 1); gt_class_load();
    if (gt_sticks_class) return fail("GT_INPUT_CLASS=plain must be stickless");
    unsetenv("GT_INPUT_CLASS"); gt_class_load();
    if (gt_sticks_class) return fail("absent GT_INPUT_CLASS must be stickless");
""")

rep("""        if (!m.loaded) return fail("map not marked loaded");
    }
""", """        if (!m.loaded) return fail("map not marked loaded");
        /* F65: r3 is rc11 b10; l2/r2 are trigger keys, never button slots */
        if (!gt_gptk_line(&m, "r3 = e")) return fail("parse r3=e");
        if (m.button_key[10].sym != 'e') return fail("F65: r3 slot != 10");
        if (!gt_gptk_line(&m, "l2 = left")) return fail("parse l2=left");
        if (!gt_gptk_line(&m, "r2 = right")) return fail("parse r2=right");
        if (m.trigger_key[0].sym != (GT_SCANCODE_MASK | 80)) return fail("F65: l2 -> trigger 0");
        if (m.trigger_key[1].sym != (GT_SCANCODE_MASK | 79)) return fail("F65: r2 -> trigger 1");
        for (i = 11; i < 16; i++)
            if (m.button_key[i].sym) return fail("F65: nothing may land in button slots 11-15");
    }
""")

rep("""    if (gt_button_slot("l3") != 9 || gt_button_slot("r3") != 12) return fail("l3/r3 slots 9/12");
""", """    if (gt_button_slot("l3") != 9 || gt_button_slot("r3") != 10) return fail("F65: l3/r3 slots 9/10");
    if (gt_button_slot("l2") != -1 || gt_button_slot("r2") != -1) return fail("F65: l2/r2 are not button slots");
    if (gt_trigger_slot("l2") != 0 || gt_trigger_slot("r2") != 1) return fail("F65: l2/r2 trigger slots 0/1");
    if (gt_trigger_slot("l1") != -1) return fail("F65: l1 is not a trigger");
""")
rep("""    if (gt_button_slot("l1") != 4) return fail("xbox l1 slot moved");
    gt_ab_swap = 0;
""", """    if (gt_button_slot("l1") != 4) return fail("xbox l1 slot moved");
    if (gt_trigger_slot("l2") != 0 || gt_trigger_slot("r2") != 1) return fail("F65: xbox leaves triggers alone");
    gt_ab_swap = 0;
""")

rep_between(
"""    /* axis -> stick + slot ends: 0/2 = X (left 2 / right 3), 1/3 = Y (up 0 / down 1) */
""",
"""        gt_axis_slots(3, &st, &sn, &sp); if (st != 1 || sn != 0 || sp != 1) return fail("axis 3 = right Y");
    }
""",
"""    /* F65 axis -> stick + slot ends: rc11 a0/a1 = left X/Y, a3/a4 = right X/Y;
     * X: left 2 / right 3, Y: up 0 / down 1; a2/a5 are triggers, not sticks */
    {
        int st, sn, sp;
        if (!gt_axis_slots(0, &st, &sn, &sp) || st != 0 || sn != 2 || sp != 3) return fail("axis 0 = left X");
        if (!gt_axis_slots(1, &st, &sn, &sp) || st != 0 || sn != 0 || sp != 1) return fail("axis 1 = left Y");
        if (!gt_axis_slots(3, &st, &sn, &sp) || st != 1 || sn != 2 || sp != 3) return fail("axis 3 = right X");
        if (!gt_axis_slots(4, &st, &sn, &sp) || st != 1 || sn != 0 || sp != 1) return fail("axis 4 = right Y");
        if (gt_axis_slots(2, &st, &sn, &sp) || gt_axis_slots(5, &st, &sn, &sp)) return fail("axes 2/5 are triggers, not sticks");
        if (gt_axis_slots(6, &st, &sn, &sp)) return fail("axis 6 is not a stick");
    }
    /* F65 triggers: a2 = L2 (0), a5 = R2 (1); pressed iff value > 0, edges only */
    if (gt_trigger_index(2) != 0 || gt_trigger_index(5) != 1) return fail("trigger axes 2/5");
    if (gt_trigger_index(0) != -1 || gt_trigger_index(3) != -1) return fail("stick axes are not triggers");
    {
        int held = 0;
        if (gt_trigger_edge(&held, -32768) != -1) return fail("released seed is no edge");
        if (gt_trigger_edge(&held, 32767) != 1 || !held) return fail("trigger press");
        if (gt_trigger_edge(&held, 32767) != -1) return fail("repeat / re-pass is no edge");
        if (gt_trigger_edge(&held, -32768) != 0 || held) return fail("trigger release");
        if (gt_trigger_edge(&held, 0) != -1) return fail("0 counts as released");
    }
""")

rep_between(
"""    /* HUD: Menu-identity + swallow helpers (fix round 2 — device gate). Menu's
""",
"""      if (vis != 0) return fail("Menu+Vol combo must not flip"); }
""",
"""    /* F65: rc11 Menu = one clean b8 (no ESC, no GOTO echo); the SDL path
     * swallows exactly b8 and nothing else in the pad's range. */
    { gt_tap_state s; memset(&s,0,sizeof s); int vis = 0;
      if (!gt_is_menu_button(8)) return fail("b8 is Menu");
      for (i = 0; i <= 14; i++)
          if (i != 8 && gt_is_menu_button((unsigned char)i)) return fail("only b8 is Menu");
      /* clean b8 tap (one down + one up) -> exactly one flip */
      gt_menu_toggle(&s,&vis,gt_is_menu_button(8),1);
      gt_menu_toggle(&s,&vis,gt_is_menu_button(8),0);
      if (vis != 1) return fail("clean b8 tap must flip once");
      /* Menu + Vol- (b13) during the hold -> no flip (disqualified) */
      memset(&s,0,sizeof s); vis = 0;
      gt_menu_toggle(&s,&vis,gt_is_menu_button(8),1);
      gt_menu_toggle(&s,&vis,gt_is_menu_button(13),1);
      gt_menu_toggle(&s,&vis,gt_is_menu_button(8),0);
      if (vis != 0) return fail("Menu+Vol combo must not flip"); }
""")

rep_between(
"""    /* F52: evdev code -> slot is DIRECT and device-independent (the codes are
""",
"""        unsetenv("GT_INPUT_CLASS"); gt_class_load();
    }
""",
"""    /* F65: evdev code -> slot equals rc11's own code -> SDL index table
     * (sdl2-h700.patch h700_buttons) for every gameplay button; Menu, GOTO,
     * ESC, Vol and L2/R2 get no button slot; L2/R2 are triggers 0/1. */
    {
        static const int code[] = {305, 304, 306, 307, 308, 309, 310, 311, 313, 316};
        static const int idx[]  = {  0,   1,   2,   3,   4,   5,   6,   7,   9,  10};
        for (i = 0; i < sizeof code / sizeof code[0]; i++)
            if (gt_evdev_code_slot(code[i]) != idx[i]) return fail("evdev slot != rc11 SDL index");
        static const int none[] = {312, 354, 1, 114, 115, 314, 315};
        for (i = 0; i < sizeof none / sizeof none[0]; i++)
            if (gt_evdev_code_slot(none[i]) != -1) return fail("non-gameplay evdev code got a button slot");
        if (gt_evdev_trigger_slot(314) != 0 || gt_evdev_trigger_slot(315) != 1) return fail("evdev 314/315 -> triggers 0/1");
        if (gt_evdev_trigger_slot(313) != -1 || gt_evdev_trigger_slot(316) != -1) return fail("stick clicks are not triggers");
    }
""")

open(p, "w").write(s)
print("shim tests edited")
```

- [ ] **Step 2: Run the tests and see them fail.**

Run: `cc -O2 -Wall -DGT_REMAP_TEST -o /tmp/gt-rt assets/gt-input-remap.c`
Expected: compile errors: `gt_trigger_slot`, `gt_trigger_index`, `gt_trigger_edge`, `gt_evdev_trigger_slot` undeclared; `trigger_key` not a member; `gt_axis_slots` returns void.

- [ ] **Step 3: Implement.** Save as `$SCR/t1_impl.py` and run `python3 "$SCR/t1_impl.py" assets/gt-input-remap.c`.

```python
import re, sys
p = sys.argv[1]
s = open(p).read()

def rep(old, new, count=1):
    global s
    n = s.count(old)
    if n != count:
        sys.exit(f"expected {count} of:\n{old[:200]}\n--- found {n}")
    s = s.replace(old, new)

def rep_between(start, end, new):
    """replace from start marker (inclusive) through end marker (inclusive)"""
    global s
    a = s.find(start)
    if a < 0: sys.exit("start not found: " + start[:80])
    b = s.find(end, a)
    if b < 0: sys.exit("end not found: " + end[:80])
    b += len(end)
    s = s[:a] + new + s[b:]

# ---------- 1. header comment (v1 paragraph) ----------

rep_between(
"/* gt-input-remap.so — an optional LD_PRELOAD shim for PortMaster processes\n",
" *   304-316 straight to slots, with no SDL-index hop at all.\n *\n",
"""/* gt-input-remap.so — an optional LD_PRELOAD shim for PortMaster processes
 * on NextUI-h700 handhelds (RG SP and siblings). F65: it assumes NextUI rc11
 * or newer. rc11's SDL (LoveRetro h700-toolchain sdl2-h700.patch) gives the
 * built-in pad ONE fixed layout on every model, "matching TrimUI Player1 and
 * Xbox 360 raw indices":
 *
 *   B 0, A 1, Y 2, X 3, L1 4, R1 5, Select 6, Start 7, Menu 8, L3 9, R3 10,
 *   Vol- 13, Vol+ 14 (11 and 12 never fire; ESC and Menu's KEY_GOTO echo are
 *   dropped). L2/R2 are trigger AXES 2/5 (+32767 pressed, -32768 released),
 *   the sticks are axes 0/1 (left) and 3/4 (right), the d-pad is hat 0.
 *
 * That is the numbering the TrimUI-built PortMaster binaries expect, so the
 * shim no longer rewrites button indices: the rc10-era v1 remap tables (and
 * GT_INPUT_REMAP) are gone. The gptk slot space below IS that SDL numbering,
 * and a class-free table (gt_evdev_code_slot) maps kernel evdev codes to the
 * same slots for the evdev path (F45).
 *
""")

rep(""" * (post-v1-remap) button carries a .gptk key mapping are REPLACED in the""",
    """ * button carries a .gptk key mapping are REPLACED in the""")
rep(""" * are honored — stick deflections synthesize their keys the same way hats
 * do.
""", """ * are honored — stick deflections synthesize their keys the same way hats
 * do. F65: the gptk's l2/r2 keys are synthesized from the trigger axes.
""")
rep(""" * SDL_PollEvent via the PLT — in that case one event would pass through the
 * shim twice, and the v1 0↔1 swap would undo itself. A marker in the
 * event's padding byte (always zero from SDL) makes the jbutton rewrite
 * once-only; v2 replacements are naturally idempotent (a key event is never
 * rewritten, and a hat re-pass sees prev==cur and yields no edges).
""", """ * SDL_PollEvent via the PLT — in that case one event passes through the
 * shim twice. Every rewrite is idempotent: a key event is never rewritten,
 * an unmapped button stays as it is, and a hat/axis/trigger re-pass sees
 * prev==cur and yields no edges.
""")

# ---------- 2. class loader + drop the rc10 tables ----------

rep_between(
"/* F52: which measured raw-index table applies. Loaded once from\n",
"""static unsigned char gt_menu_echo_index(void) {
    return gt_sticks_class ? 16 : 14;
}
""",
"""/* F52: the pad's input class, loaded once from GT_INPUT_CLASS (exported by
 * launch.sh's gt-h700-input-class block from the joystick node's EV_KEY
 * bitmap): "sticks" = a stick-equipped device (RG34XXSP class), anything else
 * (incl. absent) = stickless (RG SP). F65: rc11 numbers the buttons the same
 * on both, so the class no longer picks a table; it only gates the F53
 * analog synthesis, which keeps the RG SP's phantom axes inert. */
static int gt_sticks_class = 0;
static void gt_class_load(void) {
    const char *c = getenv("GT_INPUT_CLASS");
    gt_sticks_class = (c && !strcmp(c, "sticks")) ? 1 : 0;
}
""")

# ---------- 3. gt_button_slot + gt_trigger_slot ----------

rep_between(
"/* Post-v1-remap (TrimUI-layout) button index for each gptk button name. */\n",
"""    if (!strcmp(name, "r3"))    return 12;
    return -1;
}
""",
"""/* gptk button name -> slot. F65: the slot IS rc11's SDL button index; the
 * xbox layout swaps a<->b and x<->y. l2/r2 are not buttons on rc11 (see
 * gt_trigger_slot). */
static int gt_button_slot(const char *name) {
    if (!strcmp(name, "b"))     return gt_ab_swap ? 1 : 0;
    if (!strcmp(name, "a"))     return gt_ab_swap ? 0 : 1;
    if (!strcmp(name, "y"))     return gt_ab_swap ? 3 : 2;
    if (!strcmp(name, "x"))     return gt_ab_swap ? 2 : 3;
    if (!strcmp(name, "l1"))    return 4;
    if (!strcmp(name, "r1"))    return 5;
    if (!strcmp(name, "back") ||
        !strcmp(name, "select")) return 6;
    if (!strcmp(name, "start")) return 7;
    if (!strcmp(name, "guide")) return 8;
    if (!strcmp(name, "l3"))    return 9;   /* F52: stick clicks (stick-class devices) */
    if (!strcmp(name, "r3"))    return 10;
    return -1;
}

/* F65: gptk trigger name -> trigger index (0 = l2, 1 = r2). rc11 reports
 * L2/R2 as trigger axes 2/5, so their keys live in gt_keymap.trigger_key,
 * which no raw button index can reach. */
static int gt_trigger_slot(const char *name) {
    if (!strcmp(name, "l2")) return 0;
    if (!strcmp(name, "r2")) return 1;
    return -1;
}
""")

# ---------- 4. evdev code tables ----------

rep_between(
"/* F45/F52: evdev key code -> TrimUI-layout SLOT, directly. The evdev codes\n",
"""        default:  return -1;  /* 312 Menu / 354 GOTO / 1 ESC / 114-115 Vol */
    }
}
""",
"""/* F45/F52: evdev key code -> slot, directly, for the evdev gameplay path
 * (OpenCrossing: its stock 32-bit SDL yields no joystick events). The evdev
 * codes are the hardware truth on every h700 Anbernic. F65: the slot space is
 * rc11's SDL numbering, so this is the patch's own code -> index table for
 * the gameplay buttons (main() asserts it). L2/R2 go through
 * gt_evdev_trigger_slot. Returns -1 for codes that are not plain gameplay
 * buttons. */
static int gt_evdev_code_slot(int code) {
    switch (code) {
        case 304: return 1;   /* A  (east)  */
        case 305: return 0;   /* B  (south) */
        case 306: return 2;   /* Y  (west)  */
        case 307: return 3;   /* X  (north) */
        case 308: return 4;   /* L1 */
        case 309: return 5;   /* R1 */
        case 310: return 6;   /* Select */
        case 311: return 7;   /* Start  */
        case 313: return 9;   /* L3 click (stick devices) */
        case 316: return 10;  /* R3 click (stick devices) */
        default:  return -1;  /* 312 Menu / 354 GOTO / 1 ESC / 114-115 Vol / 314-315 L2-R2 */
    }
}

/* F65: evdev L2/R2 key codes -> trigger index (gt_trigger_slot's order). */
static int gt_evdev_trigger_slot(int code) {
    if (code == 314) return 0;   /* L2 */
    if (code == 315) return 1;   /* R2 */
    return -1;
}
""")

# ---------- 5. keymap struct ----------

rep("""    gt_key button_key[16];   /* indexed by post-v1-remap button index */
""", """    gt_key button_key[16];   /* indexed by rc11 SDL button index (F65) */
    gt_key trigger_key[2];   /* F65: [0 = l2, 1 = r2], driven by trigger axes 2/5 */
""")

# ---------- 6. gptk line: trigger names ----------

rep("""    int slot = gt_button_slot(name);
    if (slot >= 0) { m->button_key[slot] = k; m->loaded = 1; return 1; }
""", """    int slot = gt_button_slot(name);
    if (slot >= 0) { m->button_key[slot] = k; m->loaded = 1; return 1; }
    slot = gt_trigger_slot(name);
    if (slot >= 0) { m->trigger_key[slot] = k; m->loaded = 1; return 1; }
""")

# ---------- 7. axis slots + trigger helpers ----------

rep_between(
"/* F53: which stick an SDL axis belongs to and which analog_key slots its\n",
"""    else          { *slot_neg = 2; *slot_pos = 3; }   /* X: left / right */
}
""",
"""/* F53/F65: which stick an rc11 SDL axis belongs to and which analog_key
 * slots its negative / positive ends drive: a0 left X, a1 left Y, a3 right X,
 * a4 right Y; negative = up / left. Slot order = gt_dir_slot. Returns 0 for
 * every other axis (a2/a5 are the L2/R2 triggers, see gt_trigger_index). */
static int gt_axis_slots(int axis, int *stick, int *slot_neg, int *slot_pos) {
    switch (axis) {
        case 0: *stick = 0; *slot_neg = 2; *slot_pos = 3; return 1;   /* left X: left / right */
        case 1: *stick = 0; *slot_neg = 0; *slot_pos = 1; return 1;   /* left Y: up / down    */
        case 3: *stick = 1; *slot_neg = 2; *slot_pos = 3; return 1;   /* right X */
        case 4: *stick = 1; *slot_neg = 0; *slot_pos = 1; return 1;   /* right Y */
        default: return 0;
    }
}

/* F65: rc11 trigger axis -> trigger index (0 = L2 on a2, 1 = R2 on a5), else -1. */
static int gt_trigger_index(int axis) {
    return axis == 2 ? 0 : axis == 5 ? 1 : -1;
}

/* F65: trigger edge. rc11 reports a trigger as +32767 pressed and -32768
 * released (plus a seed value when the pad is opened); pressed iff value > 0.
 * Returns 1 on a press, 0 on a release, -1 when the state did not change (a
 * repeat, the released seed, or a re-pass of the same event). *held is the
 * per-trigger state. */
static int gt_trigger_edge(int *held, int value) {
    int now = value > 0 ? 1 : 0;
    if (now == *held) return -1;
    *held = now;
    return now;
}
""")

# ---------- 8. Menu identity/swallow ----------

rep_between(
"/* True ONLY for raw 11 (TL2 half -> guide/8), the edge that drives the toggle.\n",
"""static int gt_menu_swallow(unsigned char raw) {
    return gt_is_menu_button(raw) || (raw == gt_menu_echo_index());
}
""",
"""/* F65: the SDL Menu button. rc11 delivers Menu as ONE clean button, b8 (no
 * ESC, no KEY_GOTO echo), so identity and swallow are the same test:
 * gt_hud_intercept swallows both b8 edges so the game never sees Menu, and the
 * toggle itself runs in the evdev thread. Pure/host-testable. */
#define GT_MENU_BUTTON 8
static int gt_is_menu_button(unsigned char b) {
    return b == GT_MENU_BUTTON;
}
""")

# ---------- 10. interposer: marker + remap flag ----------

rep("""#define GT_REMAPPED_MARKER 0x5A

""", "")
rep("""/* F34: env-flag gating for the v1 index remap and the HUD half, decoupled
 * from each other and from v2/v3 gptk synthesis (which stays keyed on
 * gt_map.loaded, unconditionally, for backward compat — build-pak.sh only
 * ever sets GT_REMAP_GPTK together with GT_INPUT_REMAP=1, so on real
 * configs the two are on together, but nothing in this file requires it). */
""", """/* F34: env-flag gating for the HUD half, decoupled from v2/v3 gptk synthesis
 * (which stays keyed on gt_map.loaded). F65 removed the v1 index remap and
 * with it the GT_INPUT_REMAP flag. */
""")
rep("""static int gt_remap_on(void)  { static int v = -1; if (v < 0) v = gt_flag("GT_INPUT_REMAP"); return v; }
""", "")

# evdev thread gameplay branch
rep_between(
"""            } else if (keys_on) {
                /* F45/F52: gameplay button -> synthesized keystate, straight
""",
"""                                    (int)ev.code, slot, (unsigned)k.sym, down ? "down" : "up");
                    }
                }
            }
""",
"""            } else if (keys_on) {
                /* F45/F52/F65: gameplay button or L2/R2 -> synthesized
                 * keystate, straight from the evdev code (see gt_evdev_code_slot). */
                int slot = gt_evdev_code_slot(ev.code), t = -1;
                gt_key k = {0, 0};
                if (slot >= 0 && slot < 16) k = gt_map.button_key[slot];
                else if ((t = gt_evdev_trigger_slot(ev.code)) >= 0) k = gt_map.trigger_key[t];
                if (k.sym) {
                    gt_synth_set(gt_synth_keys, k.scancode, down);
                    if (gt_debug())
                        fprintf(stderr, "gt-input-remap: evdev btn %d -> %s %d key 0x%x (%s)\\n",
                                (int)ev.code, t >= 0 ? "trigger" : "slot", t >= 0 ? t : slot,
                                (unsigned)k.sym, down ? "down" : "up");
                }
            }
""")

rep("""static int gt_axis_prev[4];  /* F53: per-axis last direction (-1/0/+1) */
""", """static int gt_axis_prev[6];  /* F53: per-axis last direction (-1/0/+1), rc11 axes 0..5 */
static int gt_trigger_held[2]; /* F65: per-trigger pressed state (gt_trigger_edge) */
""")

rep(""" * log: first 60 events of any type, then joystick buttons only. Buttons
 * print their raw (pre-remap) index — this is how the real SDL index table
 * was read off the device (NextUI's custom SDL2 assigns its own order; the
 * vanilla ascending-keycode derivation from evtest was wrong). */""",
""" * log: first 60 events of any type, then joystick buttons only. Buttons
 * print their raw SDL index (how the rc10 table was read off the device;
 * F65: on rc11 it is the fixed TrimUI/Xbox 360 numbering). */""")

# ---------- 11. gt_rewrite ----------

rep_between(
"""    if (ev->type == SDL_JOYBUTTONDOWN || ev->type == SDL_JOYBUTTONUP) {
        /* v1 index remap: gated behind GT_INPUT_REMAP (F34). The v2 gptk
""",
"""        /* v2: replace the button event with its mapped key event */
""",
"""    if (ev->type == SDL_JOYBUTTONDOWN || ev->type == SDL_JOYBUTTONUP) {
        /* v2: replace the button event with its mapped key event. F65: the
         * raw rc11 index IS the slot, so there is no remap step; an unmapped
         * button passes through untouched. */
""")

rep_between(
"""    /* F53: analog stick -> the gptk's analog keys. Stick-class devices only
""",
"""    if (ev->type == SDL_JOYAXISMOTION && gt_map.loaded && gt_sticks_class
        && ev->jaxis.axis < 4) {
        int axis = ev->jaxis.axis, stick, sneg, spos;
        gt_axis_slots(axis, &stick, &sneg, &spos);
""",
"""    /* F65: L2/R2 -> the gptk's l2/r2 keys. rc11 reports them as trigger axes
     * 2/5; a press/release edge REPLACES the axis event with the key event.
     * An unmapped trigger, or a value that is no edge, passes through, so a
     * port that reads the trigger axis natively keeps it. */
    if (ev->type == SDL_JOYAXISMOTION && gt_map.loaded) {
        int t = gt_trigger_index(ev->jaxis.axis);
        if (t >= 0) {
            gt_key k = gt_map.trigger_key[t];
            if (!k.sym) return;
            int e = gt_trigger_edge(&gt_trigger_held[t], ev->jaxis.value);
            if (e >= 0) gt_make_key_event(ev, ev->jaxis.timestamp, k, e);
            return;
        }
    }

    /* F53: analog stick -> the gptk's analog keys. Stick-class devices only
     * (the RG SP's phantom axes never move, and plain must stay byte-for-byte
     * pre-F53). F65: rc11 sticks are a0/a1 + a3/a4 (gt_axis_slots). Same shape
     * as the hat path: release-before-press edges from gt_evdev_hat_edges, the
     * first key REPLACES the axis event, the rest ride the stash; no mapped
     * edge -> the axis passes through, so a hybrid port that reads raw axes
     * keeps them. A mouse-driven stick is left alone entirely (gptokeyb emits
     * no keys for it). */
    if (ev->type == SDL_JOYAXISMOTION && gt_map.loaded && gt_sticks_class) {
        int axis = ev->jaxis.axis, stick, sneg, spos;
        if (!gt_axis_slots(axis, &stick, &sneg, &spos)) return;
""")

# ---------- 12. HUD intercept ----------

rep_between(
"""/* F35 (Decision A): Menu-edge SWALLOWER for the SDL path. Runs on the RAW
""",
"""    return swallow;
}
""",
"""/* F35 (Decision A): Menu-edge SWALLOWER for the SDL path. Runs on the raw
 * event, in the poll interposers' real-poll branch, BEFORE gt_rewrite. It
 * never toggles the HUD — the toggle authority is gt_evdev_thread, the one
 * evdev source every engine shares (mono/gptokeyb ports never reach this SDL
 * hook at all). F65: rc11 sends Menu as one clean b8, so both b8 edges are
 * swallowed (gt_is_menu_button) and every other edge passes through. Returns
 * 1 if consumed (the caller must not deliver it to the app). */
static int gt_hud_intercept(SDL_Event *ev) {
    if (!gt_hud_on() || !ev) return 0;
    if (ev->type != SDL_JOYBUTTONDOWN && ev->type != SDL_JOYBUTTONUP) return 0;
    unsigned char b = ev->jbutton.button;
    int swallow = gt_is_menu_button(b);
    if (gt_hud_debug() && swallow)
        fprintf(stderr, "gt-hud: menu b%u %s swallowed, vis=%d\\n", (unsigned)b,
                ev->type == SDL_JOYBUTTONDOWN ? "down" : "up", gt_hud_visible);
    return swallow;
}
""")

open(p, "w").write(s)
print("shim implementation edited")
```

- [ ] **Step 4: Run the tests and see them pass.**

Run: `cc -O2 -Wall -Wextra -DGT_REMAP_TEST -o /tmp/gt-rt assets/gt-input-remap.c && /tmp/gt-rt && sh tests/test-05-input-remap.sh && sh tests/test-26-controller-layout-shim.sh`
Expected: no compiler warnings, `remap ok`, then `test-26-controller-layout-shim OK`. At this point test-05 still asserts `export GT_INPUT_REMAP=1` in launch.sh, which is still true until Task 2, so it passes.
Then: `grep -n 'gt_remap\|GT_PARK\|gt_menu_echo\|gt_menu_swallow\|GT_REMAPPED\|"GT_INPUT_REMAP"' assets/gt-input-remap.c` → no output.

- [ ] **Step 5: Rebuild the device shims** (sandbox disabled: Docker plus network).

Run: `make shim`
Expected: ends with a `file` listing in which `assets/gt-input-remap.so: ELF 64-bit LSB shared object, ARM aarch64` and `assets/gt-input-remap.armhf.so: ELF 32-bit LSB shared object, ARM, EABI5`. The planning pass compiled this source in the arm64 container with no new warnings; the two `-Wmisleading-indentation` warnings at the battery clamp were already there.
Then: `git status --short assets/` → for every changed binary other than the two remap shims, run `git checkout -- <file>`.

- [ ] **Step 6: Commit.**

```bash
git add assets/gt-input-remap.c assets/gt-input-remap.so assets/gt-input-remap.armhf.so
git commit -m "feat(F65): input shim speaks NextUI rc11's fixed pad numbering

Drop the rc10 index-remap tables, parking and Menu-echo handling (and the
GT_INPUT_REMAP flag). gptk slots are rc11 SDL indices (r3 = 10); l2/r2 keys
come from the rc11 trigger axes 2/5; F53 sticks read a0/a1 + a3/a4; the HUD
swallows b8 only; the evdev path maps to the same slots.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

```json:metadata
{"files": ["assets/gt-input-remap.c", "assets/gt-input-remap.so", "assets/gt-input-remap.armhf.so"], "verifyCommand": "cc -O2 -Wall -Wextra -DGT_REMAP_TEST -o /tmp/gt-rt assets/gt-input-remap.c && /tmp/gt-rt && sh tests/test-05-input-remap.sh && sh tests/test-26-controller-layout-shim.sh", "acceptanceCriteria": ["rc10 remap symbols and GT_INPUT_REMAP gone", "gt_button_slot rc11 incl r3=10; l2/r2 via gt_trigger_slot", "trigger axes 2/5 -> trigger_key via gt_trigger_edge; unmapped passes through", "gt_axis_slots 0/1 left, 3/4 right, else 0", "evdev 316->10, 314/315 -> triggers", "HUD swallows b8 only", "host test warning-free, remap ok", "make shim: aarch64 + armhf EABI5 file-checked"], "modelTier": "standard"}
```

---

### Task 2: rc11 controller DB, firmware check, remap-hook cleanup

**Goal:** Ship one class-free rc11 DB line per layout, retire F52's per-class DB copies, export `GT_NEXTUI_RC11` from a fast launch.sh check, and drop `GT_INPUT_REMAP` from the remap hook.

**Files:**
- Modify: `assets/gamecontrollerdb-h700-nintendo.txt`, `assets/gamecontrollerdb-h700-xbox.txt` (full replacement)
- Delete: `assets/gamecontrollerdb-h700-sticks-nintendo.txt`, `assets/gamecontrollerdb-h700-sticks-xbox.txt`
- Modify: `build/build-pak.sh` (device-pin block, `gt-h700-port-remap` hook and its comment, `gt-h700-controller-db-class` hook removed, `stage_controllerdb_classes` → `stage_controllerdb` plus its two callers, the `append_controllerdb` comment)
- Test: `tests/test-03-device.sh`, `tests/test-05-input-remap.sh`

**Acceptance Criteria:**
- [ ] Each DB asset has exactly one data line, the exact rc11 line from the spec: xbox `a:b0,b:b1,x:b2,y:b3,…`, nintendo `a:b1,b:b0,x:b3,y:b2,…`.
- [ ] The sticks DB assets are deleted, staging creates no `_sticks` copies, and launch.sh has no `gt-h700-controller-db-class`.
- [ ] launch.sh sets `GT_NEXTUI_RC11=1` when `$SYSTEM_LIB_DIR/libSDL2-2.0.so.0` contains the tagged GUID (via `LC_ALL=C tr -cs 0-9a-f "\n" | grep -q -x`), and `0` otherwise, including when the library is missing, with no shell error. It exports the value and logs the exact rc11 or WARNING line. The check sits after `gt-h700-syslib` sets `SYSTEM_LIB_DIR`.
- [ ] The remap hook no longer exports `GT_INPUT_REMAP=1` and logs `Enabling input synthesis for $ROM_NAME`. `GT_REMAP_GPTK` stays inside the allowlist gate.
- [ ] `make test` passes.

**Verify:** `sh tests/test-03-device.sh && sh tests/test-05-input-remap.sh && make test` → ends with `ALL TESTS PASSED`.

**Steps:**

- [ ] **Step 1: Write the failing tests.** Save as `$SCR/t2_tests.py` and run `python3 "$SCR/t2_tests.py" .` from the worktree root.

```python
import sys, os
root = sys.argv[1]

def edit(rel, pairs):
    p = os.path.join(root, rel)
    s = open(p).read()
    for old, new in pairs:
        n = s.count(old)
        if n != 1:
            sys.exit(f"{rel}: expected 1 of:\n{old[:300]}\n--- found {n}")
        s = s.replace(old, new)
    open(p, "w").write(s)

# ------------------------------ test-03 ------------------------------
edit("tests/test-03-device.sh", [
("""# mapping source with one real-shaped line, to prove the append path
dbdir="$SANDBOX/pmdb"; mkdir -p "$dbdir"
printf '%s\\n' '# test mapping' '190000004b4800000111000000010000,RG SP Gamepad,a:b1,b:b0,platform:Linux,' \\
  > "$dbdir/gamecontrollerdb-h700-xbox.txt"
printf '%s\\n' '# test mapping' '190000004b4800000111000000010000,RG SP Gamepad,a:b0,b:b1,platform:Linux,' \\
  > "$dbdir/gamecontrollerdb-h700-nintendo.txt"
printf '%s\\n' '# test stick mapping' '190000005354494b530000000000000a,Stick Pad,a:b1,b:b0,leftx:a0,platform:Linux,' \\
  > "$dbdir/gamecontrollerdb-h700-sticks-xbox.txt"
printf '%s\\n' '# test stick mapping' '190000005354494b530000000000000a,Stick Pad,a:b0,b:b1,leftx:a0,platform:Linux,' \\
  > "$dbdir/gamecontrollerdb-h700-sticks-nintendo.txt"
""", """# mapping source with one real-shaped line per layout, to prove the append path
dbdir="$SANDBOX/pmdb"; mkdir -p "$dbdir"
printf '%s\\n' '# test mapping' '19000000010000000100000000016e01,ANBERNIC-keys,a:b0,b:b1,platform:Linux,' \\
  > "$dbdir/gamecontrollerdb-h700-xbox.txt"
printf '%s\\n' '# test mapping' '19000000010000000100000000016e01,ANBERNIC-keys,a:b1,b:b0,platform:Linux,' \\
  > "$dbdir/gamecontrollerdb-h700-nintendo.txt"
"""),
("""# --- controller DB appended, comments skipped ---
assert_contains "$work/gamecontrollerdb_xbox.txt" '190000004b4800000111000000010000,RG SP Gamepad,a:b1'
assert_contains "$work/gamecontrollerdb_nintendo.txt" '190000004b4800000111000000010000,RG SP Gamepad,a:b0'
assert_not_contains "$work/gamecontrollerdb_xbox.txt" '# test mapping'
""", """# --- F65 gt-h700-rc11: NextUI rc11 check = the tagged GUID in the system libSDL2 ---
assert_contains "$work/launch.sh" 'gt-h700-rc11 (F65)'
# shellcheck disable=SC2016
assert_contains "$work/launch.sh" 'export GT_NEXTUI_RC11'
# order: gt-h700-syslib sets SYSTEM_LIB_DIR above the check that reads it
sys_line=$(grep -n 'h700) SYSTEM_LIB_DIR=' "$work/launch.sh" | head -1 | cut -d: -f1)
rc11_line=$(grep -n 'gt-h700-rc11 (F65)' "$work/launch.sh" | head -1 | cut -d: -f1)
[ "$sys_line" -lt "$rc11_line" ] || { echo "rc11 check runs before SYSTEM_LIB_DIR is set"; exit 1; }
libs="$SANDBOX/rc11libs"; mkdir -p "$libs/rc11" "$libs/rc10" "$libs/none"
{ printf 'ELF\\000'; printf '%s' '19000000010000000100000000016e01,ANBERNIC-keys,a:b0,b:b1'; printf '\\000tail'; } \\
  > "$libs/rc11/libSDL2-2.0.so.0"
{ printf 'ELF\\000'; printf '%s' '19000000010000000100000000010000,ODROID Go 2,a:b0'; printf '\\000tail'; } \\
  > "$libs/rc10/libSDL2-2.0.so.0"
run_rc11() { # $1=SYSTEM_LIB_DIR ; prints "<GT_NEXTUI_RC11>|<block stdout+stderr, newlines -> ;>"
    fake="$SANDBOX/rc11home-$$"; rm -rf "$fake"; mkdir -p "$fake"
    env -i PATH="$PATH" HOME="$fake" PLATFORM=h700 SYSTEM_LIB_DIR="$1" GT_INPUT_DEVICES_FILE="$FIX/rgsp.txt" sh -c \\
      ". \\"$SANDBOX/pinblock.sh\\" >\\"$fake/out.txt\\" 2>&1; printf '%s|' \\"\\$GT_NEXTUI_RC11\\"; tr '\\n' ';' <\\"$fake/out.txt\\""
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
"""),
("""# --- F52: per-class DB copies — forked from the PRISTINE upstream DB, stick line appended ---
assert_contains "$work/gamecontrollerdb_xbox_sticks.txt" '190000005354494b530000000000000a,Stick Pad,a:b1,b:b0,leftx:a0'
assert_contains "$work/gamecontrollerdb_nintendo_sticks.txt" '190000005354494b530000000000000a,Stick Pad,a:b0,b:b1,leftx:a0'
assert_contains "$work/gamecontrollerdb_xbox_sticks.txt" 'Dummy Pad'   # the upstream DB content is carried over
assert_contains "$work/gamecontrollerdb_nintendo_sticks.txt" 'Dummy Pad'   # the upstream DB content is carried over
assert_not_contains "$work/gamecontrollerdb_xbox_sticks.txt" '190000004b4800000111000000010000'   # no plain line in the stick copy
assert_not_contains "$work/gamecontrollerdb_nintendo_sticks.txt" '190000004b4800000111000000010000'   # no plain line in the stick copy
assert_not_contains "$work/gamecontrollerdb_xbox.txt" '190000005354494b530000000000000a'         # no stick line in the plain file
assert_not_contains "$work/gamecontrollerdb_nintendo.txt" '190000005354494b530000000000000a'     # no stick line in the plain file
assert_not_contains "$work/gamecontrollerdb_xbox_sticks.txt" '# test stick mapping'
# the real assets carry the measured stick fields
assert_contains "$ROOT/assets/gamecontrollerdb-h700-sticks-nintendo.txt" 'a:b3,b:b4,x:b6,y:b5,back:b9,start:b10,guide:b11,leftshoulder:b7,rightshoulder:b8,lefttrigger:b13,righttrigger:b14,leftstick:b12,rightstick:b15,leftx:a0,lefty:a1,rightx:a2,righty:a3,dpup:h0.1,dpdown:h0.4,dpleft:h0.8,dpright:h0.2,platform:Linux,'
assert_contains "$ROOT/assets/gamecontrollerdb-h700-sticks-xbox.txt" 'a:b4,b:b3,x:b5,y:b6,back:b9,start:b10,guide:b11,leftshoulder:b7,rightshoulder:b8,lefttrigger:b13,righttrigger:b14,leftstick:b12,rightstick:b15,leftx:a0'

# --- F52: set_controller_layout picks the per-class copy ---
assert_contains "$work/launch.sh" 'gt-h700-controller-db-class'
""", """# --- F65: one class-free rc11 line per layout; F52's per-class copies are gone ---
[ ! -e "$work/gamecontrollerdb_xbox_sticks.txt" ] || { echo "F65: no _sticks DB copy may be staged"; exit 1; }
[ ! -e "$work/gamecontrollerdb_nintendo_sticks.txt" ] || { echo "F65: no _sticks DB copy may be staged"; exit 1; }
[ ! -e "$ROOT/assets/gamecontrollerdb-h700-sticks-xbox.txt" ] || { echo "F65: the sticks DB assets must be deleted"; exit 1; }
[ ! -e "$ROOT/assets/gamecontrollerdb-h700-sticks-nintendo.txt" ] || { echo "F65: the sticks DB assets must be deleted"; exit 1; }
# the real assets carry exactly one rc11 line each: the patch's own built-in
# mapping for xbox, a/b and x/y swapped for nintendo
rc11_rest='back:b6,start:b7,guide:b8,leftshoulder:b4,rightshoulder:b5,leftstick:b9,rightstick:b10,lefttrigger:a2,righttrigger:a5,leftx:a0,lefty:a1,rightx:a3,righty:a4,dpup:h0.1,dpdown:h0.4,dpleft:h0.8,dpright:h0.2,platform:Linux,'
assert_eq "$(grep -v '^#' "$ROOT/assets/gamecontrollerdb-h700-xbox.txt" | grep -c .)" "1" "one xbox data line"
assert_eq "$(grep -v '^#' "$ROOT/assets/gamecontrollerdb-h700-nintendo.txt" | grep -c .)" "1" "one nintendo data line"
assert_eq "$(grep -v '^#' "$ROOT/assets/gamecontrollerdb-h700-xbox.txt" | grep .)" \\
  "19000000010000000100000000016e01,ANBERNIC-keys,a:b0,b:b1,x:b2,y:b3,$rc11_rest" "xbox rc11 line"
assert_eq "$(grep -v '^#' "$ROOT/assets/gamecontrollerdb-h700-nintendo.txt" | grep .)" \\
  "19000000010000000100000000016e01,ANBERNIC-keys,a:b1,b:b0,x:b3,y:b2,$rc11_rest" "nintendo rc11 line"

# --- F65: set_controller_layout is upstream's again (no per-class pick) ---
assert_not_contains "$work/launch.sh" 'gt-h700-controller-db-class'
"""),
("""printf 'sticks nintendo\\n' > "$fakepak/files/gamecontrollerdb_nintendo_sticks.txt"
""", """printf 'sticks nintendo\\n' > "$fakepak/files/gamecontrollerdb_nintendo_sticks.txt"   # stale copy an unzip-over leaves behind
"""),
("""assert_eq "$(run_layout sticks)" "sticks nintendo" "sticks class installs the _sticks DB copy"
assert_eq "$(run_layout plain)"  "plain nintendo"  "plain class installs the plain DB"
assert_eq "$(run_layout '')"     "plain nintendo"  "absent class = plain DB (pre-F52 behavior)"
""", """assert_eq "$(run_layout sticks)" "plain nintendo" "F65: sticks class uses the one rc11 DB (stale _sticks copy ignored)"
assert_eq "$(run_layout plain)"  "plain nintendo" "plain class installs the plain DB"
assert_eq "$(run_layout '')"     "plain nintendo" "absent class = plain DB"
"""),
("""assert_eq "$(grep -c '^190000004b4800000111000000010000,' "$work/gamecontrollerdb_xbox.txt")" "1" "db append dedupes by GUID"
assert_eq "$(grep -c '^190000005354494b530000000000000a,' "$work/gamecontrollerdb_xbox_sticks.txt")" "1" "stick db append dedupes by GUID"
assert_eq "$(grep -c '^190000005354494b530000000000000a,' "$work/gamecontrollerdb_nintendo_sticks.txt")" "1" "nintendo stick db append dedupes by GUID"
assert_eq "$(grep -c '^190000004b4800000111000000010000,' "$work/gamecontrollerdb_xbox_sticks.txt")" "0" "stick copy never gains the plain line on restage"
assert_eq "$(grep -c '^190000004b4800000111000000010000,' "$work/gamecontrollerdb_nintendo_sticks.txt")" "0" "nintendo stick copy never gains the plain line on restage"
assert_eq "$(grep -c 'gt-h700-controller-db-class' "$work/launch.sh")" "1" "controller-db-class edit idempotent"
""", """assert_eq "$(grep -c '^19000000010000000100000000016e01,' "$work/gamecontrollerdb_xbox.txt")" "1" "db append dedupes by GUID"
assert_eq "$(grep -c '^19000000010000000100000000016e01,' "$work/gamecontrollerdb_nintendo.txt")" "1" "nintendo db append dedupes by GUID"
assert_eq "$(grep -c 'gt-h700-rc11 (F65)' "$work/launch.sh")" "1" "rc11 check inserted once"
[ ! -e "$work/gamecontrollerdb_xbox_sticks.txt" ] || { echo "F65: restage must not create a _sticks copy"; exit 1; }
"""),
])

# ------------------------------ test-05 ------------------------------
edit("tests/test-05-input-remap.sh", [
("""# gt-input-remap.c carries a pure remap table (device SDL joystick index →
# the index the TrimUI-compiled stock PortMaster binaries expect). The table
# is the MEASURED RG SP mapping — read live off the device via the shim's own
# jbtn trace during a scripted press sequence (2026-08-19). NextUI's h700
# SDL2 enumerates evdev keycodes in plain ascending order (ESC=b0, VolDown=b1,
# VolUp=b2), so every gamepad button lands +3 from the vanilla-SDL derivation:
#   A=3→1  B=4→0  Y=5→2  X=6→3  L1=7→4  R1=8→5
#   Select=9→6  Start=10→7  Menu=11→8  L2=12→10  R2=13→11
#   parked→15: 0-2 (ESC/volume would otherwise act as B/A/Y) and 14 (Menu's
#   second emission, KEY_GOTO — would otherwise double-fire)
# The test compiles the shim NATIVELY with -DGT_REMAP_TEST, which strips the
# SDL/dlfcn interposer half and exposes a main() that asserts the table.
# F52: a second measured table (RG34XXSP class, GT_INPUT_CLASS=sticks) is
# asserted alongside; the evdev path maps code→slot directly.
""", """# gt-input-remap.c's pure half, compiled NATIVELY with -DGT_REMAP_TEST (which
# strips the SDL/dlfcn interposer half and exposes a main() of asserts). F65:
# NextUI rc11 numbers the built-in pad like TrimUI / Xbox 360 on every model
# (B0 A1 Y2 X3 L1 4 R1 5 Select 6 Start 7 Menu 8 L3 9 R3 10, Vol 13/14,
# L2/R2 = trigger axes 2/5, sticks a0/a1 + a3/a4), so the rc10 index-remap
# tables are gone; main() asserts the gptk slot numbering, the trigger and
# stick axis helpers, the b8 Menu swallow and the evdev code table against it.
"""),
("""# F34: LD_PRELOAD is now unconditional for h700; remap is gated by GT_INPUT_REMAP
assert_contains "$work/launch.sh" 'export GT_INPUT_REMAP=1'
# GT_INPUT_REMAP must sit inside the allowlist check, LD_PRELOAD outside it
lp=$(grep -n 'export LD_PRELOAD=' "$work/launch.sh" | head -1 | cut -d: -f1)
gate=$(grep -n 'gt-remap-ports.txt' "$work/launch.sh" | head -1 | cut -d: -f1)
ir=$(grep -n 'export GT_INPUT_REMAP=1' "$work/launch.sh" | head -1 | cut -d: -f1)
[ "$lp" -lt "$gate" ] || { echo "LD_PRELOAD must precede (be outside) the remap allowlist gate"; exit 1; }
[ "$gate" -lt "$ir" ] || { echo "GT_INPUT_REMAP must be inside the allowlist gate"; exit 1; }
""", """# F34: LD_PRELOAD is unconditional for h700. F65: the rc10 index remap and its
# GT_INPUT_REMAP flag are gone (shim and launcher); the allowlist only arms the
# gptk synthesis fallback, so GT_REMAP_GPTK sits inside it, LD_PRELOAD outside.
assert_not_contains "$work/launch.sh" 'GT_INPUT_REMAP=1'
assert_not_contains "$ROOT/assets/gt-input-remap.c" '"GT_INPUT_REMAP"'
# shellcheck disable=SC2016
assert_contains "$work/launch.sh" 'echo "Enabling input synthesis for $ROM_NAME"'
lp=$(grep -n 'export LD_PRELOAD=' "$work/launch.sh" | head -1 | cut -d: -f1)
gate=$(grep -n 'gt-remap-ports.txt' "$work/launch.sh" | head -1 | cut -d: -f1)
gp=$(grep -n 'export GT_REMAP_GPTK=' "$work/launch.sh" | head -1 | cut -d: -f1)
[ "$lp" -lt "$gate" ] || { echo "LD_PRELOAD must precede (be outside) the remap allowlist gate"; exit 1; }
[ "$gate" -lt "$gp" ] || { echo "GT_REMAP_GPTK must be inside the allowlist gate"; exit 1; }
"""),
])
# stick-mismatch checks: match the stick warning only (the rc11 check adds its own WARNING line)
edit("tests/test-03-device.sh", [
    ('case "$out" in *WARNING*) echo "CubeXX must not warn', 'case "$out" in *\'WARNING: profile\'*) echo "CubeXX must not warn'),
    ('case "$out" in *WARNING*) echo "a two-stick profile must not warn', 'case "$out" in *\'WARNING: profile\'*) echo "a two-stick profile must not warn'),
    ('case "$out" in *WARNING*) echo "a plain pad must never warn', 'case "$out" in *\'WARNING: profile\'*) echo "a plain pad must never warn'),
])
print("tests patched")
```

- [ ] **Step 2: Run the tests and see them fail.**

Run: `sh tests/test-03-device.sh; sh tests/test-05-input-remap.sh`
Expected: test-03 fails at `assert_contains … 'gt-h700-rc11 (F65)'`, and test-05 fails at `assert_not_contains … 'GT_INPUT_REMAP=1'`.

- [ ] **Step 3: Implement the build-script edits.** Save as `$SCR/t2_build.py` and run `python3 "$SCR/t2_build.py" build/build-pak.sh`.

```python
import sys
p = sys.argv[1]
s = open(p).read()

def rep(old, new, count=1):
    global s
    n = s.count(old)
    if n != count:
        sys.exit(f"expected {count} of:\n{old[:300]}\n--- found {n}")
    s = s.replace(old, new)

# ---- Task 2a: firmware check inside the device-pin block ----
rep('''      print "if [ \\"$PLATFORM\\" = \\"h700\\" ]; then"
      print "    mkdir -p \\"$HOME/.config\\""
      print "    # gt-h700-input-class (F52): which measured input table applies. The js0"
''', '''      print "if [ \\"$PLATFORM\\" = \\"h700\\" ]; then"
      print "    mkdir -p \\"$HOME/.config\\""
      print "    # gt-h700-rc11 (F65): NextUI rc11 gives the built-in pad a fixed TrimUI/Xbox 360"
      print "    # numbering under a tagged GUID, and the pak supports nothing older. rc11'\\''s"
      print "    # libSDL2 carries that GUID in its built-in mapping, so its presence is the"
      print "    # signal. tr first: busybox grep needs ~2.8 s on the 8 MB library, tr+grep 0.13 s."
      print "    if LC_ALL=C tr -cs 0-9a-f \\"\\\\n\\" 2>/dev/null <\\"$SYSTEM_LIB_DIR/libSDL2-2.0.so.0\\" \\\\"
      print "        | grep -q -x 19000000010000000100000000016e01; then"
      print "        GT_NEXTUI_RC11=1"
      print "        echo \\"gt-h700: NextUI pad layout rc11\\""
      print "    else"
      print "        GT_NEXTUI_RC11=0"
      print "        echo \\"gt-h700: WARNING: this NextUI is older than rc11 - controls will be wrong; please update NextUI\\""
      print "    fi"
      print "    export GT_NEXTUI_RC11"
      print "    # gt-h700-input-class (F52): which measured input table applies. The js0"
''')

# ---- Task 2b: remap hook drops GT_INPUT_REMAP ----
rep('''      print "        # input remap stays opt-in (allowlist): TrimUI index remap + gptk synthesis"
''', '''      print "        # input synthesis stays opt-in (allowlist): the gptk keyboard fallback"
''')
rep('''      print "            echo \\"Enabling input remap for $ROM_NAME\\""
      print "            export GT_INPUT_REMAP=1"
''', '''      print "            echo \\"Enabling input synthesis for $ROM_NAME\\""
''')
rep('''  # button, hardware-diagnosed 2026-08-23). What the shim actually DOES stays
  # gated: the v1 index remap + gptk keyboard synthesis (h700 button indices
  # sit +3 off the layout ports expect; measured table in
  # assets/gt-input-remap.c) are opt-in via GT_INPUT_REMAP=1, set only for
  # launcher filenames listed in files/gt-remap-ports.txt (pak-shipped
''', '''  # button, hardware-diagnosed 2026-08-23). What the shim actually DOES stays
  # gated: gptk keyboard synthesis is opt-in via GT_REMAP_GPTK, set only for
  # launcher filenames listed in files/gt-remap-ports.txt (pak-shipped
''')
rep('''  # (one name per line, no rebuild needed) — GameController-tier ports get
  # correct input natively and must stay untouched. The in-game HUD (F34) is
''', '''  # (one name per line, no rebuild needed) — GameController-tier ports get
  # correct input natively and must stay untouched. F65: NextUI rc11 numbers
  # the pad the way ports expect, so the rc10-era index remap and its
  # GT_INPUT_REMAP flag are gone. The in-game HUD (F34) is
''')

# ---- Task 2c: drop the per-class DB hook ----
a = s.find('  # gt-h700-controller-db-class: F52 — stick-equipped devices install the\n')
b = s.find('  # gt-h700-controller-layout-platform: F48 — patch PlatformTrimUI.loaded() so the\n')
assert a > 0 and b > a
s = s[:a] + s[b:]

# ---- Task 2d: stage_controllerdb ----
rep('''stage_controllerdb_classes() { # $1=dir holding gamecontrollerdb_<layout>.txt $2=repo mapping dir
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
''', '''stage_controllerdb() { # $1=dir holding gamecontrollerdb_<layout>.txt $2=repo mapping dir
  # F65: NextUI rc11 numbers the built-in pad the same on every h700 model, so
  # one line per layout serves every device (F52's per-class _sticks copies are
  # gone). GUID-deduped by append_controllerdb, so a restage is idempotent.
  for gt_l in xbox nintendo; do
    [ -f "$1/gamecontrollerdb_$gt_l.txt" ] || continue
    append_controllerdb "$2/gamecontrollerdb-h700-$gt_l.txt" "$1/gamecontrollerdb_$gt_l.txt"
  done
}
''')
rep('''      stage_controllerdb_classes "$GT_STAGE_EDIT_ONLY" "$pm_db_dir"
''', '''      stage_controllerdb "$GT_STAGE_EDIT_ONLY" "$pm_db_dir"
''')
rep('''  stage_controllerdb_classes "$assembled/files" "$ASSETS"
''', '''  stage_controllerdb "$assembled/files" "$ASSETS"
''')
rep('''  # Appends measured RG SP mapping lines (gate-filled; header-only = no-op).
''', '''  # Appends the pak's rc11 mapping lines (header-only = no-op).
''')

open(p, "w").write(s)
print("build-pak.sh edited (Task 2)")
```

- [ ] **Step 4: Replace the DB assets** (full content) and delete the per-class ones.

`assets/gamecontrollerdb-h700-nintendo.txt`:

```text
# NextUI-h700 rc11+ SDL controller mapping — nintendo layout (a/b and x/y
# swapped vs xbox, so the buttons act as printed). rc11's SDL gives the
# built-in pad ONE fixed layout on every h700 model under the tagged GUID
# ...016e01 (LoveRetro h700-toolchain sdl2-h700.patch; confirmed on the RG SP
# by the F65 measurement pass). Sticks and triggers are included — on
# stickless models those axes never move. One SDL mapping line per row;
# staging appends data lines verbatim (GUID-deduped):
#   <guid>,<name>,a:bN,b:bN,...,platform:Linux,
19000000010000000100000000016e01,ANBERNIC-keys,a:b1,b:b0,x:b3,y:b2,back:b6,start:b7,guide:b8,leftshoulder:b4,rightshoulder:b5,leftstick:b9,rightstick:b10,lefttrigger:a2,righttrigger:a5,leftx:a0,lefty:a1,rightx:a3,righty:a4,dpup:h0.1,dpdown:h0.4,dpleft:h0.8,dpright:h0.2,platform:Linux,
```

`assets/gamecontrollerdb-h700-xbox.txt`:

```text
# NextUI-h700 rc11+ SDL controller mapping — xbox layout: identical to the
# built-in mapping rc11's SDL adds for its tagged GUID ...016e01 (LoveRetro
# h700-toolchain sdl2-h700.patch; confirmed on the RG SP by the F65
# measurement pass). Kept as a file so set_controller_layout swaps between two
# real files. Sticks and triggers are included — on stickless models those
# axes never move. One SDL mapping line per row; staging appends data lines
# verbatim (GUID-deduped):
#   <guid>,<name>,a:bN,b:bN,...,platform:Linux,
19000000010000000100000000016e01,ANBERNIC-keys,a:b0,b:b1,x:b2,y:b3,back:b6,start:b7,guide:b8,leftshoulder:b4,rightshoulder:b5,leftstick:b9,rightstick:b10,lefttrigger:a2,righttrigger:a5,leftx:a0,lefty:a1,rightx:a3,righty:a4,dpup:h0.1,dpdown:h0.4,dpleft:h0.8,dpright:h0.2,platform:Linux,
```

```bash
git rm -q assets/gamecontrollerdb-h700-sticks-nintendo.txt assets/gamecontrollerdb-h700-sticks-xbox.txt
```

- [ ] **Step 5: Run the tests and see them pass.**

Run: `sh tests/test-03-device.sh && sh tests/test-05-input-remap.sh && make test`
Expected: `ALL TESTS PASSED`.
Then run the hygiene sweep: `grep -rn '19000000010000000100000000010000\|_sticks\|sticks-nintendo\|sticks-xbox\|GT_INPUT_REMAP=' tests/ build/ assets/*.txt`. The only hits should be:
  - test-03's rc10 fake-library fixture, its `[ ! -e … _sticks … ]` negative checks, and its stale-copy fixture plus `run_layout sticks` line
  - test-05's `assert_not_contains … 'GT_INPUT_REMAP=1'`
  - the `stage_controllerdb` comment in `build/build-pak.sh`

  Anything else is a stale old-ID or class-copy reference, which you should fix.

- [ ] **Step 6: Commit.**

```bash
git add -A assets/gamecontrollerdb-h700-*.txt build/build-pak.sh tests/test-03-device.sh tests/test-05-input-remap.sh
git commit -m "feat(F65): rc11 controller DB + NextUI rc11 firmware check

One class-free rc11 line per layout (xbox = the SDL built-in mapping); F52's
per-class _sticks DB copies and the controller-db-class hook are gone.
launch.sh exports GT_NEXTUI_RC11 from a tr|grep scan of the system libSDL2
(busybox grep alone takes ~2.8 s on it) and warns on older firmware. The
remap hook no longer exports GT_INPUT_REMAP.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

```json:metadata
{"files": ["assets/gamecontrollerdb-h700-nintendo.txt", "assets/gamecontrollerdb-h700-xbox.txt", "build/build-pak.sh", "tests/test-03-device.sh", "tests/test-05-input-remap.sh"], "verifyCommand": "sh tests/test-03-device.sh && sh tests/test-05-input-remap.sh && make test", "acceptanceCriteria": ["one exact rc11 line per DB asset", "sticks DB assets + _sticks staging + class-DB hook gone", "GT_NEXTUI_RC11 1/0 from tr|grep, exported, exact log lines, after SYSTEM_LIB_DIR, silent on missing lib", "no GT_INPUT_REMAP=1; 'Enabling input synthesis'; GT_REMAP_GPTK inside the gate", "make test ALL TESTS PASSED"], "modelTier": "standard"}
```

---

### Task 3: Cave Story on rc11: renumbered blob, one-time migration, rc11 conform

**Goal:** Fresh Cave Story installs get an rc11-numbered `settings.dat`. Installs made before rc11 are translated once (rebinds kept). The layout conform writes rc11 values.

**Files:**
- Modify: `assets/nxengine-evo-h700-settings.dat` (binary: records 4–10 `jbut` only)
- Modify: `assets/gt-nxengine-conform-layout.sh` (full replacement)
- Modify: `build/build-pak.sh` (F39 install block comment and touch line)
- Test: `tests/test-15-nxengine-settings.sh`

**Acceptance Criteria:**
- [ ] Shipped blob: records 4–10 `jbut` = `0,1,2,6,7,4,5`, records 11–27 = −1, and every other byte identical to before.
- [ ] A fresh install (F39 block) touches both `.gt-h700-settings` and `.gt-h700-rc11`.
- [ ] Migration runs only when `GT_NEXTUI_RC11=1`, the F39 marker is present and the rc11 stamp is absent. It translates all 28 records' `jbut` through the plain or sticks rc10→rc11 map (unmappable → −1), stamps only if every write succeeded, and clears `.gt-h700-layout`.
- [ ] Migrating 0.4.0's rc10 blob (xbox) yields the shipped rc11 blob byte for byte.
- [ ] Conform: nintendo JUMP=1/FIRE=0, xbox JUMP=0/FIRE=1. The layout stamp still gates re-application, and the magic/size guards still hold.
- [ ] `make test` passes.

**Verify:** `sh tests/test-15-nxengine-settings.sh && make test` → `ALL TESTS PASSED`.

**Steps:**

- [ ] **Step 1: Write the failing tests.** Save as `$SCR/t3_tests.py` and run `python3 "$SCR/t3_tests.py" .`.

```python
import sys, os
p = os.path.join(sys.argv[1], "tests/test-15-nxengine-settings.sh")
s = open(p).read()
def rep(old, new):
    global s
    n = s.count(old)
    if n != 1: sys.exit(f"expected 1 of:\n{old[:300]}\n--- found {n}")
    s = s.replace(old, new)

rep("""# is an SDL hat and the faces sit at raw 3-13, so directions were dead and faces
# scrambled, and the default 720x720 render overran the 720x480 fb. run_port
# installs an h700-correct settings.dat ONCE per port install (marker-gated, so
# a player's in-game rebinds/resolution survive — unlike the always-overwrite
# F27 overlay); a port reinstall recreates conf/ and re-heals.
""", """# is an SDL hat and the faces sat at rc10 raw 3-13, so directions were dead and
# faces scrambled, and the default 720x720 render overran the 720x480 fb.
# run_port installs an h700-correct settings.dat ONCE per port install
# (marker-gated, so a player's in-game rebinds/resolution survive — unlike the
# always-overwrite F27 overlay); a port reinstall recreates conf/ and re-heals.
# F65: the shipped file is rc11-numbered and stamped .gt-h700-rc11; an install
# made before rc11 is translated once by the conform helper.
""")
rep("""# shellcheck disable=SC2016
assert_contains "$work/launch.sh" 'touch "$GAMEDIR/conf/nxengine/.gt-h700-settings"'
""", """# shellcheck disable=SC2016
assert_contains "$work/launch.sh" 'touch "$GAMEDIR/conf/nxengine/.gt-h700-settings" "$GAMEDIR/conf/nxengine/.gt-h700-rc11"'
""")
rep("""[ -f "$fake/nxengine-evo/conf/nxengine/.gt-h700-settings" ] || { echo "marker not written"; exit 1; }
""", """[ -f "$fake/nxengine-evo/conf/nxengine/.gt-h700-settings" ] || { echo "marker not written"; exit 1; }
[ -f "$fake/nxengine-evo/conf/nxengine/.gt-h700-rc11" ] || { echo "F65: rc11 stamp not written on a fresh install"; exit 1; }
""")
rep("""# the shipped blob is the validated h700 mapping: 964 bytes, NXS7 magic, res=2
# (640x480), directions bound to hat0 (jbut=-1, jhat=0, jhat_value L=8/R=2/U=1/
# D=4), JUMP->raw4, FIRE->raw3. Guards the binary artifact against corruption.
""", """# the shipped blob is the validated h700 mapping: 964 bytes, NXS7 magic, res=2
# (640x480), directions bound to hat0 (jbut=-1, jhat=0, jhat_value L=8/R=2/U=1/
# D=4), and (F65) rc11 button numbers in the xbox layout: records 4-10 =
# 0,1,2,6,7,4,5 (JUMP=B b0, FIRE=A b1), records 11-27 unbound. Guards the
# binary artifact against corruption.
""")
rep("""assert field(4, 4) == 4, "JUMP jbut should be raw 4"
assert field(5, 4) == 3, "FIRE jbut should be raw 3"
""", """jb = [field(r, 4) for r in range(28)]
assert jb[4:11] == [0, 1, 2, 6, 7, 4, 5], f"records 4-10 jbut {jb[4:11]} != rc11 0,1,2,6,7,4,5"
assert jb[11:] == [-1] * 17, f"records 11-27 must stay unbound: {jb[11:]}"
""")
rep("""byte_at() { dd if="$1" bs=1 skip="$2" count=1 2>/dev/null | od -An -tu1 | tr -d ' '; }

"$conform" "$tmp/settings.dat" nintendo
[ "$(byte_at "$tmp/settings.dat" 136)" = "3" ] || { echo "nintendo JUMP.jbut != 3"; exit 1; }
[ "$(byte_at "$tmp/settings.dat" 160)" = "4" ] || { echo "nintendo FIRE.jbut != 4"; exit 1; }
""", """byte_at() { dd if="$1" bs=1 skip="$2" count=1 2>/dev/null | od -An -tu1 | tr -d ' '; }

# F65: rc11 values — B = b0 (bottom), A = b1 (right)
"$conform" "$tmp/settings.dat" nintendo
[ "$(byte_at "$tmp/settings.dat" 136)" = "1" ] || { echo "nintendo JUMP.jbut != 1"; exit 1; }
[ "$(byte_at "$tmp/settings.dat" 160)" = "0" ] || { echo "nintendo FIRE.jbut != 0"; exit 1; }
""")
rep("""[ "$(byte_at "$tmp/settings.dat" 136)" = "4" ] || { echo "xbox JUMP.jbut != 4"; exit 1; }
[ "$(byte_at "$tmp/settings.dat" 160)" = "3" ] || { echo "xbox FIRE.jbut != 3"; exit 1; }
""", """[ "$(byte_at "$tmp/settings.dat" 136)" = "0" ] || { echo "xbox JUMP.jbut != 0"; exit 1; }
[ "$(byte_at "$tmp/settings.dat" 160)" = "1" ] || { echo "xbox FIRE.jbut != 1"; exit 1; }
""")
rep("""# F49: helper staged + injector wired into the staged launch.sh.
""", """# --- F65: one-time rc10 -> rc11 migration of an install made before rc11 ---
jbuts() { # all 28 records' jbut, comma-separated
    python3 - "$1" <<'PY'
import struct, sys
b = open(sys.argv[1], "rb").read()
print(",".join(str(struct.unpack_from("<i", b, 36 + r * 24 + 4)[0]) for r in range(28)))
PY
}
mk_rc10() { # $1=dir [$2=rebinds]: a pre-F65 install — rc10 numbering as 0.4.0 shipped it
    mkdir -p "$1"
    python3 - "$ROOT/assets/nxengine-evo-h700-settings.dat" "$1/settings.dat" "${2:-}" <<'PY'
import struct, sys
b = bytearray(open(sys.argv[1], "rb").read())
for r, v in zip(range(4, 11), [4, 3, 5, 9, 10, 7, 8]):
    struct.pack_into("<i", b, 36 + r * 24 + 4, v)
if sys.argv[3]:   # a player's in-game rebinds: raw 12, 15, 13, 0 (ESC), 16, 2 (Vol+)
    for r, v in [(6, 12), (7, 15), (8, 13), (9, 0), (10, 16), (11, 2)]:
        struct.pack_into("<i", b, 36 + r * 24 + 4, v)
open(sys.argv[2], "wb").write(b)
PY
    touch "$1/.gt-h700-settings"
    echo xbox > "$1/.gt-h700-layout"
}
m="$SANDBOX/mig"; unbound16="-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1"
# the shipped rc11 blob IS the rc10 blob translated: migrating 0.4.0's file lands on it byte for byte
mk_rc10 "$m/stock"
GT_NEXTUI_RC11=1 GT_INPUT_CLASS=plain "$conform" "$m/stock/settings.dat" xbox
cmp -s "$m/stock/settings.dat" "$ROOT/assets/nxengine-evo-h700-settings.dat" || { echo "migrated 0.4.0 blob != shipped rc11 blob"; exit 1; }
[ -f "$m/stock/.gt-h700-rc11" ] || { echo "migration did not stamp .gt-h700-rc11"; exit 1; }
assert_eq "$(cat "$m/stock/.gt-h700-layout")" "xbox" "layout re-applied after migration"
# plain (RG SP) rebinds: L2 (12) / R2 (13) are axes on rc11, 15 was a park, ESC/GOTO gone -> -1; Vol+ 2 -> 14
mk_rc10 "$m/plain" rebinds
GT_NEXTUI_RC11=1 GT_INPUT_CLASS=plain "$conform" "$m/plain/settings.dat" xbox
assert_eq "$(jbuts "$m/plain/settings.dat")" "-1,-1,-1,-1,0,1,-1,-1,-1,-1,-1,14,$unbound16" "plain migration"
# sticks rebinds: L3 12 -> 9, R3 15 -> 10, L2 13 / ESC / GOTO 16 -> -1, Vol+ 2 -> 14
mk_rc10 "$m/sticks" rebinds
GT_NEXTUI_RC11=1 GT_INPUT_CLASS=sticks "$conform" "$m/sticks/settings.dat" xbox
assert_eq "$(jbuts "$m/sticks/settings.dat")" "-1,-1,-1,-1,0,1,9,10,-1,-1,-1,14,$unbound16" "sticks migration"
# once only: a second launch leaves the migrated file alone
cp "$m/sticks/settings.dat" "$m/sticks.bak"
GT_NEXTUI_RC11=1 GT_INPUT_CLASS=sticks "$conform" "$m/sticks/settings.dat" xbox
cmp -s "$m/sticks/settings.dat" "$m/sticks.bak" || { echo "migration re-ran on a stamped file"; exit 1; }
# waits for rc11: GT_NEXTUI_RC11 unset/0 -> no translation, no stamp
mk_rc10 "$m/old"
GT_NEXTUI_RC11=0 "$conform" "$m/old/settings.dat" xbox
assert_eq "$(jbuts "$m/old/settings.dat")" "-1,-1,-1,-1,4,3,5,9,10,7,8,-1,$unbound16" "no migration before rc11 (file untouched)"
[ ! -f "$m/old/.gt-h700-rc11" ] || { echo "stamped without rc11"; exit 1; }
# not a pak-installed file (no F39 marker) -> no translation
mk_rc10 "$m/foreign"; rm -f "$m/foreign/.gt-h700-settings"
GT_NEXTUI_RC11=1 "$conform" "$m/foreign/settings.dat" xbox
[ ! -f "$m/foreign/.gt-h700-rc11" ] || { echo "migrated a file the pak did not install"; exit 1; }

# F49: helper staged + injector wired into the staged launch.sh.
""")
open(p, "w").write(s)
print("t15 patched")
```

- [ ] **Step 2: Run the tests and see them fail.**

Run: `sh tests/test-15-nxengine-settings.sh`
Expected: FAIL at the F39 touch-line assert (no `.gt-h700-rc11`).

- [ ] **Step 3: Renumber the shipped blob.** Save as `$SCR/t3_blob.py` and run `python3 "$SCR/t3_blob.py"` from the worktree root. It asserts the current rc10 values first.

```python
# F65: renumber the shipped Cave Story blob from rc10 to rc11 (records 4-10 jbut only).
import struct
p = "assets/nxengine-evo-h700-settings.dat"
b = bytearray(open(p, "rb").read())
assert len(b) == 964 and b[:4] == b"NXS7"
old = [struct.unpack_from("<i", b, 36 + 24 * r + 4)[0] for r in range(4, 11)]
assert old == [4, 3, 5, 9, 10, 7, 8], f"unexpected rc10 values {old}"
for r, v in zip(range(4, 11), [0, 1, 2, 6, 7, 4, 5]):
    struct.pack_into("<i", b, 36 + 24 * r + 4, v)
open(p, "wb").write(b)
print("blob renumbered to rc11")
```

- [ ] **Step 4: Replace the conform helper** (full content of `assets/gt-nxengine-conform-layout.sh`; keep it executable, as `git` tracks mode 755):

```sh
#!/bin/sh
# gt-nxengine-conform-layout (F49/F65): keep Cave Story (nxengine-evo)
# settings.dat in line with NextUI rc11 and the resolved controller layout.
#   $1 = settings.dat path   $2 = layout (nintendo|xbox)
#   env GT_NEXTUI_RC11 (1 = rc11 firmware, from launch.sh's gt-h700-rc11 check)
#   env GT_INPUT_CLASS (plain|sticks, from launch.sh's gt-h700-input-class)
# Format (verified): magic "NXS7"@0, 964 bytes, 28 binding records of 24 bytes
# from offset 36; jbut = field 1 (record+4, LE int32, -1 = unbound).
# JUMP = record 4 -> jbut@136, FIRE = record 5 -> jbut@160.
#
# Step 1 (F65, once): a settings.dat the pak installed before rc11 (F39 marker
# present, no .gt-h700-rc11 stamp) binds rc10 raw indices. Translate every
# record's jbut to rc11's fixed numbering, so in-game rebinds survive, then
# stamp. Waits for rc11 firmware (GT_NEXTUI_RC11=1).
# Step 2 (F49): swap JUMP/FIRE to the layout, idempotent via .gt-h700-layout.
# rc11: B = b0 (bottom), A = b1 (right).
#   nintendo: JUMP=1 (A, right), FIRE=0 (B, bottom)   xbox: JUMP=0, FIRE=1
f="$1"
layout="$2"
[ -f "$f" ] || exit 0
case "$layout" in nintendo|xbox) ;; *) layout=nintendo ;; esac
dir=$(dirname "$f")

# Magic guard: bytes 0-3 must be "NXS7".
if [ "$(dd if="$f" bs=1 count=4 2>/dev/null)" != "NXS7" ]; then
    exit 0
fi

# Size guard: must be exactly the known 964-byte layout, else the record
# offsets are meaningless and conv=notrunc would zero-extend a truncated file.
[ "$(wc -c < "$f")" -eq 964 ] || exit 0

# Little-endian int32 for -1 or 0..255, as printf octal escapes.
le32() {
    if [ "$1" -lt 0 ]; then
        printf '\377\377\377\377'
    else
        printf "\\$(printf '%03o' "$1")\\000\\000\\000"
    fi
}

# rc10 raw SDL index -> rc11 index for one binding ($1 = old, $2 = class).
# rc10 (measured, F25/F52): 0 ESC, 1/2 Vol-/Vol+, 3 A, 4 B, 5 Y, 6 X, 7 L1,
# 8 R1, 9 Select, 10 Start, 11 Menu; plain 12/13 L2/R2, 14 GOTO echo; sticks
# 12 L3, 13/14 L2/R2, 15 R3, 16 GOTO echo. rc11 has no ESC/echo button and
# reports L2/R2 as axes, so those become -1 (unbound).
rc11_jbut() {
    case "$1" in
        1) echo 13 ;;  2) echo 14 ;;
        3) echo 1 ;;   4) echo 0 ;;   5) echo 2 ;;   6) echo 3 ;;
        7) echo 4 ;;   8) echo 5 ;;   9) echo 6 ;;  10) echo 7 ;;  11) echo 8 ;;
        12) if [ "$2" = sticks ]; then echo 9; else echo -1; fi ;;
        15) if [ "$2" = sticks ]; then echo 10; else echo -1; fi ;;
        *) echo -1 ;;
    esac
}

if [ "${GT_NEXTUI_RC11:-0}" = 1 ] && [ -f "$dir/.gt-h700-settings" ] && [ ! -f "$dir/.gt-h700-rc11" ]; then
    class=${GT_INPUT_CLASS:-plain}
    ok=1; n=0
    # All 28 records x 6 int32 fields in one read; field 1 of each is jbut.
    for v in $(od -An -v -t d4 -j 36 -N 672 "$f"); do
        if [ $((n % 6)) -eq 1 ]; then
            new=$(rc11_jbut "$v" "$class")
            if [ "$new" != "$v" ]; then
                le32 "$new" | dd of="$f" bs=1 seek=$((36 + n * 4)) conv=notrunc 2>/dev/null || ok=0
            fi
        fi
        n=$((n + 1))
    done
    [ "$n" -eq 168 ] || ok=0
    if [ "$ok" = 1 ]; then
        touch "$dir/.gt-h700-rc11"
        rm -f "$dir/.gt-h700-layout"   # re-apply the layout below on the rc11 values
    fi
fi

stamp="$dir/.gt-h700-layout"
if [ -f "$stamp" ] && [ "$(cat "$stamp" 2>/dev/null)" = "$layout" ]; then
    exit 0
fi

ok=1
if [ "$layout" = "nintendo" ]; then
    le32 1 | dd of="$f" bs=1 seek=136 conv=notrunc 2>/dev/null || ok=0  # JUMP=1 (A, right)
    le32 0 | dd of="$f" bs=1 seek=160 conv=notrunc 2>/dev/null || ok=0  # FIRE=0 (B, bottom)
else
    le32 0 | dd of="$f" bs=1 seek=136 conv=notrunc 2>/dev/null || ok=0  # JUMP=0 (bottom)
    le32 1 | dd of="$f" bs=1 seek=160 conv=notrunc 2>/dev/null || ok=0  # FIRE=1 (right)
fi

# Only record success if both writes actually succeeded — a swallowed dd
# failure (read-only fs, disk full) must not stamp a mapping that was never
# written, or a later launch would skip re-patching and silently keep the
# wrong bindings.
[ "$ok" = 1 ] && echo "$layout" > "$stamp"
```

- [ ] **Step 5: Stamp fresh installs.** Save as `$SCR/t3_build.py` and run `python3 "$SCR/t3_build.py" build/build-pak.sh`.

```python
import sys
p = sys.argv[1]
s = open(p).read()

def rep(old, new, count=1):
    global s
    n = s.count(old)
    if n != count:
        sys.exit(f"expected {count} of:\n{old[:300]}\n--- found {n}")
    s = s.replace(old, new)

# ---- Task 3: F39 install writes the rc11 stamp ----
rep('''      print "    # gt-h700-nxengine-settings: install h700-correct nxengine-evo controls +"
      print "    # resolution once (d-pad->hat0, faces->raw indices, res 640x480). Marker-"
      print "    # gated so in-game rebinds persist; port reinstall wipes conf/ -> re-heals."
''', '''      print "    # gt-h700-nxengine-settings: install h700-correct nxengine-evo controls +"
      print "    # resolution once (d-pad->hat0, faces->rc11 indices, res 640x480). Marker-"
      print "    # gated so in-game rebinds persist; port reinstall wipes conf/ -> re-heals."
      print "    # F65: the shipped file is rc11-numbered, so it is stamped as such."
''')
rep('''      print "        touch \\"$GAMEDIR/conf/nxengine/.gt-h700-settings\\""
''', '''      print "        touch \\"$GAMEDIR/conf/nxengine/.gt-h700-settings\\" \\"$GAMEDIR/conf/nxengine/.gt-h700-rc11\\""
''')

open(p, "w").write(s)
print("build-pak.sh edited (Task 3)")
```

- [ ] **Step 6: Run the tests and see them pass.**

Run: `sh tests/test-15-nxengine-settings.sh && make test`
Expected: `ALL TESTS PASSED`. The planning pass also saw test-15 FAIL against the old helper, which proves the new asserts bite.

- [ ] **Step 7: Commit.**

```bash
git add assets/nxengine-evo-h700-settings.dat assets/gt-nxengine-conform-layout.sh build/build-pak.sh tests/test-15-nxengine-settings.sh
git commit -m "feat(F65): Cave Story settings follow NextUI rc11 numbering

The shipped settings.dat is renumbered to rc11 and stamped .gt-h700-rc11 on
install; an install made before rc11 is translated once (all 28 bindings, per
input class, unmappable -> unbound) so in-game rebinds survive. The layout
conform writes rc11 JUMP/FIRE values.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

```json:metadata
{"files": ["assets/nxengine-evo-h700-settings.dat", "assets/gt-nxengine-conform-layout.sh", "build/build-pak.sh", "tests/test-15-nxengine-settings.sh"], "verifyCommand": "sh tests/test-15-nxengine-settings.sh && make test", "acceptanceCriteria": ["blob records 4-10 = 0,1,2,6,7,4,5, 11-27 = -1", "fresh install touches .gt-h700-rc11", "one-time migration gated on GT_NEXTUI_RC11=1 + F39 marker + no stamp; plain/sticks maps; stamp on success; layout stamp cleared", "migrated 0.4.0 blob == shipped blob", "rc11 conform values; stamp gate + guards intact", "make test ALL TESTS PASSED"], "modelTier": "standard"}
```

---

### Task 4: Balatro: move a pre-rc11 button map aside

**Goal:** On rc11, a Balatro-class `$BUTTON_MAP_FILE` recorded on the pre-rc11 built-in ID is renamed to `.pre-rc11`, so the port's own wizard asks once. The launcher is never edited.

**Files:**
- Create: `assets/gt-button-map-rc11.sh` (mode 755)
- Modify: `build/build-pak.sh` (new `gt-h700-button-map-rc11` run_port hook, plus staging in `do_portmaster`)
- Create test: `tests/test-36-rc11-button-map.sh`

**Acceptance Criteria:**
- [ ] The hook sits inside run_port, after GAMEDIR resolution and before the port exec. It is gated on `PLATFORM=h700` and `GT_NEXTUI_RC11=1`, and is inserted once.
- [ ] The helper renames the map only when the launcher sets `BUTTON_MAP_FILE="$GAMEDIR/…"` and the map's first non-comment, non-blank line matches `190000000100000001000000????0000,*`. It logs the exact line and never modifies the launcher (content and mtime unchanged).
- [ ] rc11-ID maps, comment-only maps, external-pad maps, launchers without `BUTTON_MAP_FILE`, and missing maps are all untouched, with exit 0.
- [ ] `do_portmaster` stages `files/gt-button-map-rc11.sh` as executable.
- [ ] `make test` passes (36 suites).

**Verify:** `sh tests/test-36-rc11-button-map.sh && make test` → prints `test-36-rc11-button-map OK`, then `ALL TESTS PASSED`.

**Steps:**

- [ ] **Step 1: Write the failing test** `tests/test-36-rc11-button-map.sh` (full content):

```sh
#!/bin/sh
. "$(dirname -- "$0")/helpers.sh"

# F65: Balatro-class ports (a first-run button wizard that saves an SDL
# mapping line to $BUTTON_MAP_FILE) record the pad GUID of the moment. NextUI
# rc11 gives the built-in pad a new, tagged GUID, so a map saved on older
# firmware silently stops matching. run_port calls files/gt-button-map-rc11.sh
# on rc11, which moves such a map aside; the port's own "no file -> ask" rule
# then runs the button check once. The launcher is never edited (its mtime is
# a Balatro rebuild source, F32).
work="$SANDBOX/pmpak"; mkdir -p "$work"
cp "$TROOT/fixtures/portmaster-pak-skeleton/pak.json.fixture" "$work/pak.json"
cp "$TROOT/fixtures/portmaster-pak-skeleton/launch.sh.fixture" "$work/launch.sh"
GT_STAGE_EDIT_ONLY="$work" sh "$ROOT/build/build-pak.sh" portmaster

assert_contains "$work/launch.sh" 'gt-h700-button-map-rc11 (F65)'
# shellcheck disable=SC2016
assert_contains "$work/launch.sh" '"$PAK_DIR/files/gt-button-map-rc11.sh" "$ROM_PATH" "$GAMEDIR"'
# placement: inside run_port — after GAMEDIR resolution, before the port exec
gamedir_line=$(grep -n 'echo "Game dir is: \$GAMEDIR"' "$work/launch.sh" | head -1 | cut -d: -f1)
hook_line=$(grep -n 'gt-h700-button-map-rc11 (F65)' "$work/launch.sh" | head -1 | cut -d: -f1)
# shellcheck disable=SC2016
bash_exec_line=$(grep -n '"\$PAK_DIR/bin/bash" "\$ROM_PATH"' "$work/launch.sh" | head -1 | cut -d: -f1)
[ "$gamedir_line" -lt "$hook_line" ] || { echo "hook is not after GAMEDIR resolution"; exit 1; }
[ "$hook_line" -lt "$bash_exec_line" ] || { echo "hook is not before the port exec"; exit 1; }
sh -n "$work/launch.sh" || { echo "edited launch.sh does not parse"; exit 1; }
GT_STAGE_EDIT_ONLY="$work" sh "$ROOT/build/build-pak.sh" portmaster
assert_eq "$(grep -c 'gt-h700-button-map-rc11 (F65)' "$work/launch.sh")" "1" "hook inserted exactly once"

# --- the helper, against a fake Balatro install ---
helper="$ROOT/assets/gt-button-map-rc11.sh"
[ -x "$helper" ] || { echo "helper missing/not executable"; exit 1; }
fake="$SANDBOX/fake"; mkdir -p "$fake/balatro/saves"
# shellcheck disable=SC2016  # the launcher text is literal on purpose
printf '%s\n' '#!/bin/bash' 'GAMEDIR="/$directory/ports/balatro"' 'FORCE_BUTTON_SETUP=0' \
    'BUTTON_MAP_FILE="$GAMEDIR/saves/controller-map.txt"' \
    'export BALATRO_PM_BUTTON_MAP_FILE="$BUTTON_MAP_FILE"' > "$fake/Balatro.sh"
cp "$fake/Balatro.sh" "$SANDBOX/Balatro.sh.orig"
touch -t 202601010000 "$fake/Balatro.sh" "$SANDBOX/ref"
map="$fake/balatro/saves/controller-map.txt"
launcher_untouched() {
    cmp -s "$fake/Balatro.sh" "$SANDBOX/Balatro.sh.orig" || { echo "launcher content changed"; exit 1; }
    if [ "$fake/Balatro.sh" -nt "$SANDBOX/ref" ] || [ "$fake/Balatro.sh" -ot "$SANDBOX/ref" ]; then
        echo "launcher mtime changed (would trigger a Balatro rebuild)"; exit 1
    fi
}

# 1. a map on the pre-rc11 built-in GUID is moved aside, with a log line
printf '%s\n' '# Balatro button setup.' '19000000010000000100000000010000,RG SP Gamepad,a:b3,b:b4,platform:Linux,' > "$map"
out=$("$helper" "$fake/Balatro.sh" "$fake/balatro")
[ ! -e "$map" ] || { echo "old-GUID map was not moved aside"; exit 1; }
assert_contains "$map.pre-rc11" '19000000010000000100000000010000,RG SP Gamepad'
case "$out" in *'gt-h700: Balatro button map predates rc11 - the port will ask for its button check once'*) ;;
    *) echo "missing log line: $out"; exit 1;; esac
launcher_untouched
# 2. a map the wizard saved on rc11 (tagged GUID) stays
printf '%s\n' '# Balatro button setup.' '19000000010000000100000000016e01,ANBERNIC-keys,a:b1,b:b0,platform:Linux,' > "$map"
"$helper" "$fake/Balatro.sh" "$fake/balatro" >/dev/null
assert_contains "$map" '19000000010000000100000000016e01,ANBERNIC-keys'
# 3. a skipped / timed-out check writes a comment-only file: nothing to move
printf '%s\n' '# Balatro button setup: skipped.' > "$map"
"$helper" "$fake/Balatro.sh" "$fake/balatro" >/dev/null
assert_contains "$map" 'skipped'
# 4. a map recorded on an external pad stays
printf '%s\n' '030000005e0400008e02000014010000,Xbox 360 Controller,a:b0,b:b1,platform:Linux,' > "$map"
"$helper" "$fake/Balatro.sh" "$fake/balatro" >/dev/null
assert_contains "$map" 'Xbox 360 Controller'
# 5. a launcher without BUTTON_MAP_FILE is never considered
printf '%s\n' '19000000010000000100000000010000,RG SP Gamepad,a:b3,platform:Linux,' > "$map"
printf '%s\n' '#!/bin/bash' 'GAMEDIR="/$directory/ports/balatro"' > "$SANDBOX/Other.sh"
"$helper" "$SANDBOX/Other.sh" "$fake/balatro" >/dev/null
assert_contains "$map" '19000000010000000100000000010000'
# 6. a missing map is a clean no-op
rm -f "$map"
"$helper" "$fake/Balatro.sh" "$fake/balatro" || { echo "missing map must exit 0"; exit 1; }
launcher_untouched

# --- the run_port hook waits for rc11 ---
sed -n '/gt-h700-button-map-rc11 (F65)/,/^    fi$/p' "$work/launch.sh" > "$SANDBOX/hook.sh"
mkdir -p "$SANDBOX/pak/files"; cp "$helper" "$SANDBOX/pak/files/"
printf '%s\n' '19000000010000000100000000010000,RG SP Gamepad,a:b3,platform:Linux,' > "$map"
PLATFORM=h700 GT_NEXTUI_RC11=0 PAK_DIR="$SANDBOX/pak" ROM_PATH="$fake/Balatro.sh" GAMEDIR="$fake/balatro" \
    sh "$SANDBOX/hook.sh" >/dev/null
[ -e "$map" ] || { echo "hook acted before rc11"; exit 1; }
PLATFORM=h700 GT_NEXTUI_RC11=1 PAK_DIR="$SANDBOX/pak" ROM_PATH="$fake/Balatro.sh" GAMEDIR="$fake/balatro" \
    sh "$SANDBOX/hook.sh" >/dev/null
[ ! -e "$map" ] || { echo "hook did not act on rc11"; exit 1; }

echo "test-36-rc11-button-map OK"
```

- [ ] **Step 2: Run it and see it fail.**

Run: `sh tests/test-36-rc11-button-map.sh`
Expected: FAIL at `assert_contains … 'gt-h700-button-map-rc11 (F65)'`.

- [ ] **Step 3: Create the helper** `assets/gt-button-map-rc11.sh` (full content), then `chmod 755 assets/gt-button-map-rc11.sh`:

```sh
#!/bin/sh
# gt-button-map-rc11 (F65): Balatro-class ports (a first-run button wizard
# that saves an SDL mapping line to $BUTTON_MAP_FILE) record the pad GUID of
# the moment. NextUI rc11 gives the built-in pad a new, tagged GUID, so a map
# saved on older firmware silently stops matching. Move such a map aside; the
# port's own "no file -> run the button check" rule then asks the player once.
# Never edits the launcher (its mtime is a rebuild source, F32).
#   $1 = port launcher (.sh)   $2 = the port's GAMEDIR
# Only launchers that set BUTTON_MAP_FILE="$GAMEDIR/..." are considered.
launcher="$1"
gamedir="$2"
[ -f "$launcher" ] && [ -n "$gamedir" ] || exit 0
# shellcheck disable=SC2016  # literal $GAMEDIR in the launcher text is the point
rel=$(sed -n 's|^[[:space:]]*BUTTON_MAP_FILE="\$GAMEDIR/\([^"]*\)".*|\1|p' "$launcher" | head -n 1)
[ -n "$rel" ] || exit 0
map="$gamedir/$rel"
[ -f "$map" ] || exit 0
# The port's own reader: first non-comment, non-blank line.
line=$(grep -v '^[[:space:]]*#' "$map" | grep -m 1 '[^[:space:]]')
case "$line" in
    190000000100000001000000????0000,*)
        # pre-rc11 built-in pad ID (bus 0x19, vendor 1, product 1, untagged)
        if mv -f "$map" "$map.pre-rc11"; then
            echo "gt-h700: $(basename "$launcher" .sh) button map predates rc11 - the port will ask for its button check once"
        fi ;;
esac
exit 0
```

- [ ] **Step 4: Add the hook and the staging.** Save as `$SCR/t4_build.py` and run `python3 "$SCR/t4_build.py" build/build-pak.sh`.

```python
import sys
p = sys.argv[1]
s = open(p).read()

def rep(old, new, count=1):
    global s
    n = s.count(old)
    if n != count:
        sys.exit(f"expected {count} of:\n{old[:300]}\n--- found {n}")
    s = s.replace(old, new)

# ---- Task 4: Balatro hook (after the F39 block) ----
rep('''  # gt-h700-ac-launcher: F45 — Animal Crossing is a 32-bit armhf port (NextUI is
''', '''  # gt-h700-button-map-rc11: F65 — Balatro-class ports save their first-run
  # button wizard's SDL mapping to $BUTTON_MAP_FILE, keyed on the pad GUID of
  # the moment. NextUI rc11 gives the built-in pad a new, tagged GUID, so a map
  # saved on older firmware silently stops matching. The helper moves such a
  # map aside and the port's own "no file -> run the button check" rule asks
  # the player once. It never edits the launcher (a rebuild source, F32).
  # Waits for rc11 (GT_NEXTUI_RC11, set on the common path by gt-h700-rc11).
  # Anchored on the nintendo_file line (inside run_port, after GAMEDIR
  # resolves, before the port executes) like the F27/F39/F45 blocks.
  if ! grep -q 'gt-h700-button-map-rc11' "$f"; then
    awk '$0 == "    nintendo_file=$(find \\"$USERDATA_PATH/PORTS-portmaster\\" -maxdepth 1 -iname \\"nintendo*\\" -type f)" {
      print "    # gt-h700-button-map-rc11 (F65): a Balatro-class button map saved before rc11"
      print "    # names the old pad GUID; move it aside so the port asks for its button check once."
      print "    if [ \\"$PLATFORM\\" = \\"h700\\" ] && [ \\"${GT_NEXTUI_RC11:-0}\\" = 1 ]; then"
      print "        \\"$PAK_DIR/files/gt-button-map-rc11.sh\\" \\"$ROM_PATH\\" \\"$GAMEDIR\\""
      print "    fi"
      print ""
      print $0
      next
    }
    { print }' "$f" > "$f.awk.tmp" && mv "$f.awk.tmp" "$f"
  fi

  # gt-h700-ac-launcher: F45 — Animal Crossing is a 32-bit armhf port (NextUI is
''')
rep('''  # F49: stage the nxengine-evo (Cave Story) settings.dat layout-conform helper.
  cp -f "$ASSETS/gt-nxengine-conform-layout.sh" "$assembled/files/gt-nxengine-conform-layout.sh"
  chmod +x "$assembled/files/gt-nxengine-conform-layout.sh"
''', '''  # F49: stage the nxengine-evo (Cave Story) settings.dat layout-conform helper.
  cp -f "$ASSETS/gt-nxengine-conform-layout.sh" "$assembled/files/gt-nxengine-conform-layout.sh"
  chmod +x "$assembled/files/gt-nxengine-conform-layout.sh"

  # F65: stage the Balatro-class button-map check run_port calls on rc11.
  cp -f "$ASSETS/gt-button-map-rc11.sh" "$assembled/files/gt-button-map-rc11.sh"
  chmod +x "$assembled/files/gt-button-map-rc11.sh"
''')

open(p, "w").write(s)
print("build-pak.sh edited (Task 4)")
```

- [ ] **Step 5: Run the tests and see them pass.**

Run: `sh tests/test-36-rc11-button-map.sh && make test`
Expected: `test-36-rc11-button-map OK`, then `ALL TESTS PASSED`.

- [ ] **Step 6: Commit.**

```bash
git add assets/gt-button-map-rc11.sh build/build-pak.sh tests/test-36-rc11-button-map.sh
git commit -m "feat(F65): Balatro asks for its button check once on NextUI rc11

A Balatro-class button map saved on the pre-rc11 built-in pad ID stops
matching on rc11; files/gt-button-map-rc11.sh moves it to .pre-rc11 so the
port's own wizard runs once. The launcher is never edited (F32).

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

```json:metadata
{"files": ["assets/gt-button-map-rc11.sh", "build/build-pak.sh", "tests/test-36-rc11-button-map.sh"], "verifyCommand": "sh tests/test-36-rc11-button-map.sh && make test", "acceptanceCriteria": ["hook in run_port after GAMEDIR, before exec, gated on h700 + GT_NEXTUI_RC11=1, inserted once", "old-ID map -> .pre-rc11 + exact log; launcher content+mtime unchanged", "rc11/comment-only/external/no-BUTTON_MAP_FILE/missing untouched, exit 0", "helper staged executable", "make test ALL TESTS PASSED"], "modelTier": "mechanical"}
```

---

### Task 5: Docs: F65 section, 0.5.0 changelog and release notes, README

**Goal:** Document F65 in the existing 0.5.0 blocks and the README, in the pak's release-notes style.

**Files:**
- Modify: `docs/h700-fixes.md` (0.5.0 changelog block, upgrade line, six "superseded" notes, new F65 section at the end)
- Modify: `docs/release-notes-v0.5.0.md` (pre-release line, New, two ⚠️ Changes, upgrade step)
- Modify: `README.md` (requirement, upgrading, layout/Balatro, other devices, what works, keyboard-fallback list, technical details)

**Acceptance Criteria:**
- [ ] `h700-fixes.md` has a `**NextUI rc11 (F65).**` entry in `### 0.5.0`, an updated "Upgrading from 0.4.0" line, seven `Superseded on NextUI rc11` notes (under F4, F8, F26, F39, F49, F52, F53), and a final `## NextUI rc11: one fixed pad layout on every h700 model (F65)` section.
- [ ] The release notes open with `Pre-release for testing with the NextUI rc11 preview.` and have a New bullet, two new ⚠️ Changes bullets (NextUI rc11 required; Balatro check once) and an "Update NextUI to rc11 or newer first." upgrade bullet.
- [ ] README states the rc11 requirement in "Read this first", no longer claims raw-joystick ports need setup or that the list fixes button numbering, and renames the list section to "keyboard-fallback list".
- [ ] `make test` still passes. It doesn't read docs, but it's the cheap regression check.

**Verify:** `grep -c 'Superseded on NextUI rc11' docs/h700-fixes.md` → `7`; `grep -n 'rc11' README.md docs/release-notes-v0.5.0.md` shows the new lines; `make test` → `ALL TESTS PASSED`.

**Steps:**

- [ ] **Step 1: Apply the docs edits.** Save as `$SCR/t5_docs.py` and run `python3 "$SCR/t5_docs.py"` from the worktree root.

```python
# F65 docs: docs/h700-fixes.md, docs/release-notes-v0.5.0.md, README.md.
# Run from the repo root: python3 t5_docs.py
import sys

def edit(path, pairs):
    s = open(path).read()
    for old, new in pairs:
        n = s.count(old)
        if n != 1:
            sys.exit(f"{path}: expected 1 of:\n{old[:300]}\n--- found {n}")
        s = s.replace(old, new)
    open(path, "w").write(s)

ANCHOR = "nextui-rc11-one-fixed-pad-layout-on-every-h700-model-f65"
NOTE = (f"*Superseded on NextUI rc11 by [F65](#{ANCHOR}): the rc10 button numbering "
        "described here no longer applies.*\n\n")

# ------------------------------------------------------------ h700-fixes.md
edit("docs/h700-fixes.md", [
("""- F64: Luanti's text renders correctly instead of `<invalid UTF-8 string>` —
  shipped glibc's missing UTF-16/UTF-32 `gconv` conversion modules

**Build:**""", """- F64: Luanti's text renders correctly instead of `<invalid UTF-8 string>` —
  shipped glibc's missing UTF-16/UTF-32 `gconv` conversion modules

**NextUI rc11 (F65).** This release requires NextUI h700-rc11 or newer and is
published as a pre-release alongside the rc11 preview.
- F65: the input stack moves to rc11's fixed TrimUI/Xbox 360 pad numbering —
  the rc10 index-remap tables, the per-class controller-DB copies and the
  Menu-echo handling are removed; one rc11 controller-DB line per layout
  serves every h700 model; the shim synthesizes gptk `l2`/`r2` keys from
  rc11's trigger axes; Cave Story's settings are renumbered (installs made
  before rc11 migrate once, keeping in-game rebinds); a Balatro button map
  saved on the old pad ID is moved aside so the game asks for its button check
  once; launch.sh logs a warning on firmware older than rc11

**Build:**"""),
("""**Upgrading from 0.4.0:** unzip-over (self-healing); no manual steps.""",
 """**Upgrading from 0.4.0:** update NextUI to rc11 or newer first, then
unzip-over (self-healing); Balatro asks for its button check once."""),
("## Controller mapping (F4)\n\n", "## Controller mapping (F4)\n\n" + NOTE),
("## Keyboard-driven ports: SDL-layer key synthesis (F26)\n\n",
 "## Keyboard-driven ports: SDL-layer key synthesis (F26)\n\n" + NOTE),
("## Cave Story (Evo): raw-joystick bindings baked into settings.dat (F39)\n\n",
 "## Cave Story (Evo): raw-joystick bindings baked into settings.dat (F39)\n\n" + NOTE),
("## Cave Story (Evo): face buttons now follow the resolved layout (F49)\n\n",
 "## Cave Story (Evo): face buttons now follow the resolved layout (F49)\n\n" + NOTE),
("## Stick-equipped devices: input class and per-class tables (F52)\n\n",
 "## Stick-equipped devices: input class and per-class tables (F52)\n\n" + NOTE),
("## Stick-equipped devices: analog sticks as keys, and a truthful profile (F53)\n\n",
 "## Stick-equipped devices: analog sticks as keys, and a truthful profile (F53)\n\n" + NOTE),
])
with open("docs/h700-fixes.md", "a") as fh:
    fh.write("""
## NextUI rc11: one fixed pad layout on every h700 model (F65)

NextUI h700-rc11 changed how its SDL fork numbers the built-in pad. The change
is in LoveRetro/h700-toolchain `support/sdl2-h700.patch` (commits `46cc4d73`
and `04faa348`), not in the NextUI repository. The built-in pad
(`ANBERNIC-keys`) now gets one fixed layout on every model, "matching TrimUI
Player1 and Xbox 360 raw indices", under a tagged GUID
`19000000010000000100000000016e01` (rc10 reported `…00010000`):

| control | rc11 SDL | | control | rc11 SDL |
|---|---|---|---|---|
| B (south) | b0 | | Select | b6 |
| A (east) | b1 | | Start | b7 |
| Y (west) | b2 | | Menu | b8 (one event; no ESC, no KEY_GOTO echo) |
| X (north) | b3 | | L3 / R3 | b9 / b10 |
| L1 / R1 | b4 / b5 | | Vol− / Vol+ | b13 / b14 |

L2/R2 are trigger axes a2/a5 (+32767 pressed, −32768 released), the sticks
are a0/a1 and a3/a4, and the d-pad is hat 0. SDL adds a built-in positional
mapping for the tagged GUID at default priority, so the pak's DB lines
override it. `SDL_JOYSTICK_H700_FIXED_LAYOUT=0` restores the rc10 numbering;
the pak supports neither that nor anything older than rc11.

rc11's numbering is what the shim's rc10 index remap existed to fake, so F65
is mostly removal:

- **Shim (`gt-input-remap.c`):** the rc10 index tables (RG SP and stick
  class), the ESC/Vol/echo parking and the `GT_INPUT_REMAP` flag are gone.
  The gptk slot space is rc11's SDL numbering (`r3` moved from slot 12 to
  10); `l2`/`r2` keys live in a separate trigger table driven by axis 2/5
  edges (pressed iff value > 0; an unmapped trigger passes through as an
  axis). The F53 stick synthesis reads a0/a1 + a3/a4, the evdev path (F45)
  maps codes to the same slots, and the HUD swallows b8 only.
- **Controller DB:** one rc11 line per layout (xbox = SDL's own built-in
  mapping, nintendo = a/b and x/y swapped). F52's `_sticks` copies and the
  `gt-h700-controller-db-class` hook are gone — the layout is the same on
  every model.
- **Firmware check (`gt-h700-rc11`):** `GT_NEXTUI_RC11=1` when the tagged
  GUID string is in the system `libSDL2`, else `0` plus a log warning. The
  scan is `tr -cs 0-9a-f "\\n" | grep -x`: busybox `grep` alone needs ~2.8 s
  on the 8 MB library, the tr pipe 0.13 s. Only the two migrations below
  read it.
- **Cave Story (F39/F49):** the shipped `settings.dat` is renumbered (records
  4–10: `4,3,5,9,10,7,8` → `0,1,2,6,7,4,5`) and stamped `.gt-h700-rc11`. An
  install made before rc11 is translated once — all 28 bindings, per input
  class — and buttons rc11 lacks (ESC, the echo, L2/R2) become unbound. The
  layout conform writes rc11 values (Nintendo JUMP=1/FIRE=0, Xbox
  JUMP=0/FIRE=1).
- **Balatro-class ports:** `files/gt-button-map-rc11.sh` moves a
  `$BUTTON_MAP_FILE` whose first mapping line names the pre-rc11 built-in ID
  (`190000000100000001000000????0000`) to `<file>.pre-rc11`, so the port's
  own wizard asks once. The launcher is never edited (F32).

Unaffected: the evdev HUD toggle (F35), sleep (F47), gptokeyb passthrough
(F54), the input-class detection (still drives the device profile and the
F53 gate), and Animal Crossing (its own 32-bit SDL; its gameplay input is
evdev).
""")

# ------------------------------------------------------ release notes 0.5.0
edit("docs/release-notes-v0.5.0.md", [
("""### New
- **Keyboard-and-mouse games get their controls.**""", """Pre-release for testing with the NextUI rc11 preview.

### New
- **Works with NextUI rc11's new button handling.** The PortMaster app, the
  Nintendo/Xbox setting and games that read the buttons directly all follow
  it. Cave Story (Evo) keeps its controls, including any you changed in its
  own menu.
- **Keyboard-and-mouse games get their controls.**"""),
("""### Changes
- ⚠️ **The keyboard-and-mouse emulation is on by default.**""", """### Changes
- ⚠️ **Needs NextUI rc11 or newer.** On older NextUI versions many games get
  the wrong buttons. Update NextUI before installing this release.
- ⚠️ **Balatro asks for its button check once more** the first time you start
  it on NextUI rc11. Press each button as asked.
- ⚠️ **The keyboard-and-mouse emulation is on by default.**"""),
("""### Upgrading from v0.4.0
- Unzip the new""", """### Upgrading from v0.4.0
- Update NextUI to rc11 or newer first.
- Unzip the new"""),
])

# ------------------------------------------------------------------ README
edit("README.md", [
("""- **Only the Anbernic RG SP is confirmed working.**""",
 """- **Needs NextUI rc11 or newer.** On older NextUI versions many games get the wrong buttons.
- **Only the Anbernic RG SP is confirmed working.**"""),
("""- Coming from 0.3.2 or earlier, the default button layout changes""",
 """- Coming from 0.4.0 or earlier: update NextUI to rc11 or newer first. Balatro asks for its button check once more the first time you start it.
- Coming from 0.3.2 or earlier, the default button layout changes"""),
("""— Balatro is one; PortMaster shows a note on the game's page when that's the
case.""", """— Balatro is one; PortMaster shows a note on the game's page when that's the
case. On NextUI rc11 Balatro asks for its button check once more, because rc11
changed how the device reports its buttons."""),
("""- Devices with analog sticks get a mapping that includes both sticks, and the
  right buttons for triggers, stick clicks and Menu.""",
 """- NextUI rc11 reports the buttons the same way on every model, so one
  controller mapping — with both sticks, the triggers and the stick clicks —
  covers them all."""),
("""- ✅ **Out of the box** — ports using SDL's GameController API. LÖVE-based games also work.
- ⚠️ **With a little setup** — ports that read raw joystick input, and keyboard-style ports (the ones whose title screen asks for a key like SPACE): both are handled by the built-in input translator — see [Fixing games that ignore your buttons](#fixing-games-that-ignore-your-buttons).""",
 """- ✅ **Out of the box** — ports using SDL's GameController API, and (since NextUI rc11) ports that read the raw joystick. LÖVE-based games also work.
- ⚠️ **With a little setup** — keyboard-style ports (the ones whose title screen asks for a key like SPACE) — see [Fixing games that ignore your buttons](#fixing-games-that-ignore-your-buttons)."""),
("""so any rebinding or resolution change you make in-game afterward is kept. Nothing to turn on.""",
 """so any rebinding or resolution change you make in-game afterward is kept. On NextUI rc11 the pak renumbers that config once, keeping your changes. Nothing to turn on."""),
("""- **Button numbering.** A few older games read the gamepad directly and see
  this device's buttons in a shifted order. The pak fixes the numbering for
  games on its built-in list — currently **Tunics!**, **BYTEPATH**, **Lasagna
  Boy Classic**, **Road Invaders**, **The Starlit Escape**, **Sonic 1** and
  **Sonic 2** — and you can add a game yourself (below). Games on this list
  also keep a built-in keyboard fallback for the rare case where the helper is
  not running.""",
 """- **Keyboard fallback.** Games on the pak's built-in list — currently
  **Tunics!**, **BYTEPATH**, **Lasagna Boy Classic**, **Road Invaders**, **The
  Starlit Escape**, **Sonic 1** and **Sonic 2** — keep a built-in keyboard
  translation for the rare case where the helper is not running, and you can
  add a game yourself (below). (Before NextUI rc11 this list also fixed
  shifted button numbers; rc11 numbers the buttons correctly itself.)"""),
("### Adding a game to the button-numbering list", "### Adding a game to the keyboard-fallback list"),
("game is on the button-numbering list, otherwise no keyboard translation at all.",
 "game is on the keyboard-fallback list, otherwise no keyboard translation at all."),
("""- **The input translator (opt-in):** corrects this device's shifted SDL
  joystick button indices (hardware-measured table) and, when the launcher
  finds a <code>.gptk</code> in the port's game directory and no gptokeyb is
  running, replaces mapped joystick events with synthesized
  <code>SDL_KEYDOWN/KEYUP</code> at the SDL event layer (the pre-F54 path, now
  the fallback).""",
 """- **The input translator (opt-in):** when the launcher finds a
  <code>.gptk</code> in the port's game directory and no gptokeyb is running,
  replaces mapped joystick events (buttons, d-pad, sticks and the L2/R2
  trigger axes) with synthesized <code>SDL_KEYDOWN/KEYUP</code> at the SDL
  event layer (the pre-F54 path, now the fallback). NextUI rc11 numbers the
  buttons the way ports expect, so the earlier index correction is gone
  (F65)."""),
])
print("docs edited")
```

- [ ] **Step 2: Proofread the rendered result.** Run `git diff docs/ README.md`. Check that the F65 table renders, that the `"\n"` inside the F65 bullet is a literal backslash-n, and that the README anchor `#fixing-games-that-ignore-your-buttons` still exists.

- [ ] **Step 3: Run the tests.** Run: `make test` → `ALL TESTS PASSED`.

- [ ] **Step 4: Commit.**

```bash
git add docs/h700-fixes.md docs/release-notes-v0.5.0.md README.md
git commit -m "docs(F65): NextUI rc11 pad layout — changelog, release notes, README

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

```json:metadata
{"files": ["docs/h700-fixes.md", "docs/release-notes-v0.5.0.md", "README.md"], "verifyCommand": "grep -c 'Superseded on NextUI rc11' docs/h700-fixes.md && make test", "acceptanceCriteria": ["h700-fixes: 0.5.0 F65 entry, upgrade line, 7 superseded notes (incl. F8), F65 section", "release notes: pre-release line, New bullet, two warning bullets, upgrade step", "README: rc11 requirement, no stale raw-joystick/numbering claims, keyboard-fallback list", "make test passes"], "modelTier": "mechanical"}
```

---

### Task 6: Full build, final device gate on rc11, hand-off

**Goal:** Build the pak, install it on the RG SP with Camille's OK, pass the nine-item device gate on rc11, record the results, and hand the branch to Camille for the squash merge.

> **USER-ORDERED GATE — NON-SKIPPABLE.** This task was requested by the user in the current conversation. It MUST NOT be closed by walking around it, by declaring it "verified inline", or by substituting a cheaper check. Close only after every item in `acceptanceCriteria` has been re-validated independently, with output captured.

**Files:**
- Modify: `docs/h700-fixes.md` (append the device-gate paragraph to the F65 section)
- Build output (untracked): `dist/Emus/h700/PORTS.pak.zip`

**Acceptance Criteria:**
- [ ] `make test` → `ALL TESTS PASSED`. `make pak` builds the zip, and `unzip -l` shows `PORTS.pak/files/gt-button-map-rc11.sh`, `PORTS.pak/files/gamecontrollerdb_{nintendo,xbox}.txt` and no `_sticks` DB.
- [ ] Installed on the RG SP only after Camille's explicit OK, by unzip-over with md5 matching on both sides and PortMaster idle.
- [ ] Gate 1: after a launch, `/mnt/SDCARD/.userdata/h700/logs/PORTS.txt` contains `gt-h700: NextUI pad layout rc11`.
- [ ] Gate 2: PortMaster GUI navigation works. Confirm/back follow the layout for both Nintendo and Xbox, and the Options → Controller Layout toggle works.
- [ ] Gate 3: Celeste plays correctly on each layout.
- [ ] Gate 4: BYTEPATH and Tunics! play through gptokeyb passthrough, and Select+Start quits. Also under passthrough: OpenTTD's L2/R2 still type `-`/`=` (zoom), as in the F54 gate. rc11 moved the triggers from buttons to axes `a2`/`a5` in the controller DB, and gptokeyb must follow.
- [ ] Gate 5: Sonic 1 plays on the synthesis path (log shows `keyboard synthesis on`). Trigger synthesis: with Camille's OK, temporarily add `l2 = q` and `r2 = e` to Sonic 1's `.gptk` on the device and touch `.userdata/h700/PORTS-portmaster/use-input-debug` (the pak's real input-debug flag file — it sets `GT_INPUT_REMAP_DEBUG=1` via the `gt-h700-port-remap` hook in `build/build-pak.sh`). The trace must show exactly one synthesized key down and one up per L2/R2 press, then restore the `.gptk` and remove the flag file. Also watch that Sonic doesn't get native controller input and synthesized keys at once. rc11's built-in mapping may revive RSDK's native pad path (F43): for example, B must not both jump and pause.
- [ ] Gate 6: in a game, a Menu tap toggles the overlay without the game reacting, and Menu+Vol still changes brightness.
- [ ] Gate 7: Cave Story's existing install migrates. `.gt-h700-rc11` appears, JUMP/FIRE work for the layout, an in-game rebind made before the upgrade survives (or one made after the migration persists), and a layout change re-conforms. Note: the RG SP is already on rc11, so a rebind made in-game now is recorded in rc11 numbering, and the migration would mistranslate it. Judge rebinds only by (a) a rebind that existed before the upgrade, or (b) one made after the migration, which must persist. Don't use JUMP/FIRE for this: the migration re-applies the layout to those.
- [ ] Gate 8: Balatro asks for its button check exactly once. `saves/controller-map.txt.pre-rc11` exists if an old map was present. The second launch doesn't ask, and the new map works.
- [ ] Gate 9: Animal Crossing plays (evdev path), and sleep/resume works from power and lid with sound. Animal Crossing's camera rotates with L2/R2. This is the evdev path, where codes 314/315 now feed the gptk `l2`/`r2` trigger keys.
- [ ] A gate paragraph, dated and naming which items passed plus any caveat, is appended to the F65 section and committed.

**Verify:** each gate item's evidence (log lines, stamp listings, `od` output, Camille's confirmation) quoted in the close note. `make test` → `ALL TESTS PASSED`.

**Steps:**

- [ ] **Step 1: Test and build** (sandbox disabled for the build).

```bash
make test
make pak
unzip -l dist/Emus/h700/PORTS.pak.zip | grep -E 'gt-button-map-rc11|gamecontrollerdb_|gt-input-remap'
```
Expected: `ALL TESTS PASSED`; the listing shows `files/gt-button-map-rc11.sh`, `files/gamecontrollerdb_nintendo.txt`, `files/gamecontrollerdb_xbox.txt`, `lib/gt-input-remap.so` and the armhf shim, and no `_sticks`.

- [ ] **Step 2: Snapshot the device's pre-install state (read-only)** for gates 7 and 8:

```bash
ssh root@10.0.1.16 'for d in $(find /mnt/SDCARD -type d -name nxengine-evo 2>/dev/null); do ls -a $d/conf/nxengine 2>/dev/null; od -An -v -t d4 -j 36 -N 672 $d/conf/nxengine/settings.dat 2>/dev/null | head -4; done
find /mnt/SDCARD -path "*balatro/saves/controller-map.txt*" 2>/dev/null | while read -r f; do echo "== $f"; grep -v "^#" "$f" | head -1 | cut -c1-40; done'
```
If Balatro has no `controller-map.txt`, or has one without the old ID, ask Camille whether to seed the move-aside path by writing a pre-rc11 line (`19000000010000000100000000010000,RG SP Gamepad,a:b3,b:b4,platform:Linux,`) into it. Otherwise gate 8 exercises only the ordinary first-run check, and the close note must say so.

- [ ] **Step 3: Ask Camille, then install by unzip-over.** Use plain chat text: "Ready to install the F65 build on the RG SP (unzip-over, PortMaster must be closed) — OK?" Wait for his yes. Then:

```bash
ssh root@10.0.1.16 'pgrep -f PORTS.pak >/dev/null && echo "PortMaster RUNNING - stop" || echo idle'
md5 -q dist/Emus/h700/PORTS.pak.zip
scp -O dist/Emus/h700/PORTS.pak.zip root@10.0.1.16:/mnt/SDCARD/PORTS.pak.zip
ssh root@10.0.1.16 'md5sum /mnt/SDCARD/PORTS.pak.zip && cd /mnt/SDCARD/Emus/h700 && unzip -o -q /mnt/SDCARD/PORTS.pak.zip && rm -f /mnt/SDCARD/PORTS.pak.zip && grep -c gt-h700 PORTS.pak/launch.sh'
```
Expected: `idle`, matching md5s, and a non-zero `gt-h700` count.

- [ ] **Step 4: Run the gate with Camille, item by item.** Camille drives the device; after each launch, read the log (it keeps only the last launch):

```bash
ssh root@10.0.1.16 'grep -E "gt-h700|gt-input-remap|Enabling input synthesis|keyboard synthesis|passthrough" /mnt/SDCARD/.userdata/h700/logs/PORTS.txt | head -40'
```
Go in this order: GUI (gates 1–2) → Celeste on both layouts (3) → BYTEPATH, Tunics! (4) → Sonic 1 (5) → Menu tap and brightness in any of them (6) → Cave Story (7: re-run the Step 2 `od`/`ls` after launch; expect records 4–5 = the layout's JUMP/FIRE and the `.gt-h700-rc11` stamp) → Balatro twice (8: `ls` the saves dir after the first launch) → Animal Crossing, then sleep via power and lid (9). A failure → `superpowers-extended-cc:systematic-debugging`, fix it on the branch with a test, rebuild, reinstall (with Camille's OK), and re-run the affected items.

**Watch at the gate:**
- **Gate 6:** GameController ports still see Guide on a Menu tap. The DB maps `guide:b8`, and the shim's swallow only covers joystick events, the same as `guide:b11` on rc10. Judge "no leak" with a game that doesn't bind Guide.
- **Gate 4:** under passthrough, Tunics! (Solarus) still receives raw joystick events, whose numbering changed. Re-check that no actions are doubled.

- [ ] **Step 5: Record the gate.** Append to the end of `docs/h700-fixes.md` (the F65 section), filling in the real date and outcomes:

```markdown

**Device gate (<YYYY-MM-DD>, RG SP, NextUI h700-rc11).** Measurement pass
(Task 0): pad GUID, 15 buttons / 6 axes / 1 hat, b0–b10/b13/b14, Menu as one
b8, L2/R2 on a2/a5 — all as the patch source says. Gate: <PASS/FAIL per item 1–9,
with the Balatro path exercised (move-aside or first-run)>. Stick devices:
host-tested only (no hardware), EXPERIMENTAL label kept.
```

Then commit:

```bash
git add docs/h700-fixes.md
git commit -m "docs(F65): rc11 device gate results

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

- [ ] **Step 6: Hand off.** Invoke `superpowers-extended-cc:finishing-a-development-branch`. The pak convention is ONE squash commit on main (`git merge --squash feat/rc11-pad-layout`, with a consolidated `feat: F65 — …` message and a per-change bulleted body). Camille decides and does the merge, push, tag and the GitHub pre-release; don't do them unasked.

```json:metadata
{"files": ["docs/h700-fixes.md"], "verifyCommand": "make test && make pak && unzip -l dist/Emus/h700/PORTS.pak.zip | grep -E 'gt-button-map-rc11|gamecontrollerdb_'", "acceptanceCriteria": ["make test passes; make pak zip contains the helper, 2 DBs, no _sticks", "installed only after Camille's OK; md5 match; PortMaster idle", "gate 1 rc11 log line", "gate 2 GUI nav + confirm/back per layout + toggle", "gate 3 Celeste both layouts", "gate 4 BYTEPATH + Tunics! passthrough, Select+Start quit, OpenTTD L2/R2 zoom keys, Tunics raw-joystick re-check", "gate 5 Sonic 1 synthesis, L2/R2 trigger-key trace via use-input-debug, no native+synth double input", "gate 6 Menu tap no leak, Menu+Vol brightness, GameController Guide-leak caveat", "gate 7 Cave Story migrates, stamp, JUMP/FIRE, rebind survives (pre-upgrade or post-migration only), re-conform", "gate 8 Balatro asks once; .pre-rc11 if old map", "gate 9 Animal Crossing + sleep power/lid, L2/R2 camera via evdev 314/315", "gate paragraph appended + committed"], "modelTier": "frontier", "userGate": true, "tags": ["user-gate"]}
```
