# gptokeyb passthrough (F54) — design

Date: 2026-09-04. Branch: `feat/gptokeyb-passthrough` (worktree off main at v0.4.0, e96c1af).
Status: approved design, awaiting implementation plan. Replaces the earlier "mouse synthesis" idea
(`docs/triage/2026-09-04-mouse-synthesis-feasibility.md`, re-scope note), which becomes a follow-up
fallback and is NOT built here.

## Context

Seven of the nine ports in GitHub issue #1 are keyboard-and-mouse games driven by gptokeyb. On
NextUI-h700 they are input-dead. The pak's F26/F31/F53 synthesis (SDL-layer key events generated from the
port's `.gptk`) covers only allowlisted keyboard ports and no mouse at all.

The 2026-09-04 device pass on the RG SP found the real cause (details in
`docs/triage/2026-09-04-issue-1.md`, section "Keyboard delivery on NextUI"):

- NextUI's SDL2 fork is a **no-libudev** build. Its evdev keyboard/mouse layer (`SDL_EVDEV_Init`) opens
  ONLY the devices named in the env var `SDL_EVDEV_DEVICES` (`class:path,...`; class bits 1 = mouse,
  2 = keyboard). Nothing on NextUI sets it, so gptokeyb's uinput device is never opened by any game.
- gptokeyb's uinput device is named `Fake Keyboard`, advertises `EV=7` and `REL=3` (keyboard + mouse
  even for a keyboard-only gptk), and appeared as `/dev/input/event3` on the RG SP. gptokeyb2 uses the
  same device name (per its source, `src/keyboard.c`).
- Exporting `SDL_EVDEV_DEVICES="2:/dev/input/event3"` in the BYTEPATH launcher after gptokeyb started,
  with the shim's synthesis OFF, made BYTEPATH's keyboard-event menus AND keyboard-polling gameplay work
  through gptokeyb itself. The game held event3 open. A 1.5 s wait alone changed nothing (not a race).
- Console keyboard mode (`KDGKBMODE` on tty0/tty1) was `K_UNICODE` after the game exited; no side
  effect observed.
- Quakespasm's controls are native `SDL_GameController` (its config sets `joy_enable 1`), not keyboard.

So gptokeyb's output CAN reach ports here; SDL just has to be told about the device. Doing that from the
shim, inside the game process, at SDL init, is the whole feature. Everything else is policy and cleanup.

## Goals

1. gptokeyb's keyboard AND mouse reach every SDL port on h700 without a per-port list.
2. No double input: the shim's own synthesis is off whenever passthrough is active.
3. Synthesis stays available as the fallback for ports that run without gptokeyb (Animal Crossing, F45).
4. Launchers that overwrite `LD_PRELOAD` (Doom Engines: `export LD_PRELOAD=hacksdl.so`) still get every
   pak shim.
5. Two shim hygiene fixes ride along: no log lines from non-SDL children, and no misleading
   "opened N/N joystick(s) for key synthesis" line when only the HUD is on.

## Non-goals

- Mouse synthesis in the shim (fallback only if a gptokeyb-less mouse port ever appears).
- Engines that reach SDL via `dlopen` + `dlsym` (mono/FNA): interposers never fire there. No known
  gptokeyb-tier port uses them; documented limit.
- Migrating Sonic 1/2 off the pak's synthesis (see Decisions and Follow-ups).
- Release, version bump, tagging, pushing — Camille's calls, outside this phase.

## Decisions (2026-09-04, Camille)

1. **Mechanism:** shim-side, interposing `SDL_Init` / `SDL_InitSubSystem`. Rejected: launcher-side
   patching of the `$GPTOKEYB ... &` line (fragile across launcher shapes; its only unique win, mono/FNA
   coverage, has zero known members) and a hybrid of both (second mechanism for a member count of zero).
2. **Policy:** passthrough ON for every h700 port; opt-out via pak `files/gt-passthrough-blocklist.txt`
   and the user's `use-passthrough-blocklist`. Same shape as the HUD and sleep blocklists.
3. **Allowlist:** `files/gt-remap-ports.txt` / `use-remap-ports` stay exactly as they are (they gate the
   v1 index remap and arm the synthesis fallback). Passthrough suppresses synthesis at runtime. README
   rewritten accordingly.
4. **LD_PRELOAD-overwriting launchers:** generic `run_port` patch inside the F32 mtime window, prepending
   the pak's preload chain to every overwrite-style `export LD_PRELOAD=` line.
5. **Sonic 1/2 ship on the passthrough blocklist.** Finding: the Sonic launchers DO run gptokeyb, against
   the very `sonic.gptk` the pak overlays (F43). Under passthrough gptokeyb would deliver that gptk itself,
   but gptokeyb's face naming follows the controller database while the shim's follows the v1 index remap
   plus the F48 layout flip; whether physical A/B land on the same keys is unverified. Exempting Sonic
   keeps the device-verified v0.4.0 behavior; migration is a device-gated follow-up.

## Design

### 1. Passthrough core (shim, `assets/gt-input-remap.c`)

New interposers: `SDL_Init(Uint32 flags)` and `SDL_InitSubSystem(Uint32 flags)`, resolved to the real
functions via `dlsym(RTLD_NEXT)` like every other interposer in the file.

**Trigger.** Act once, on the first call whose `flags` include `SDL_INIT_VIDEO` (SDL's evdev layer is
initialized by the video driver). A static `done` guard makes re-entry harmless: `SDL_Init` calls
`SDL_InitSubSystem` internally and, depending on PLT binding, that inner call hits the interposer again.
Calls without the video flag pass straight through (this also excludes gptokeyb's own
`SDL_Init(SDL_INIT_GAMECONTROLLER)`).

**Preconditions** (all must hold, else pass through untouched; debug-log the reason):

- `GT_PASSTHROUGH` is unset or not `"0"` (the blocklist sets `0`).
- `SDL_EVDEV_DEVICES` is unset or empty (a launcher that sets its own wins).
- `/proc/self/comm` does not start with `gptokeyb` (the preload is inherited by every child).

**Detection.** Scan `/proc/[0-9]*/comm`; a process counts if its comm starts with `gptokeyb` (covers
`gptokeyb2`) and its pid is not ours. No session or process-group filter: a stale gptokeyb left by a
crashed launcher injects keys on every other CFW too, so attaching to it is faithful behavior; recorded as
a known limit.

**Node resolution.** Read `/proc/bus/input/devices` whole with a `read()` loop into a fixed 64 KiB buffer
(never `fgets`/seek on procfs; a truncated read is parsed as far as it goes). Split into stanzas at blank
lines. For each stanza whose `N:` line is exactly `N: Name="Fake Keyboard"`, take the `eventN` token from
`H: Handlers=` and the trailing `inputN` from `S: Sysfs=.../input/inputN`; a stanza missing either is
ignored. Choose the stanza with the highest `inputN` (input numbers are monotonic for the boot; event
numbers are recycled, so "newest" must key on `inputN`). Result: `/dev/input/eventN`, or none.

**Wait.** If at least one gptokeyb process exists but no node resolves, poll every 50 ms for at most
2000 ms. If no gptokeyb process exists, do not wait at all: native ports pay one `/proc` scan and nothing
else.

**Activation.** `setenv("SDL_EVDEV_DEVICES", "3:/dev/input/eventN", 1)` (class 3 = keyboard | mouse;
overwrite = 1 because the precondition admits a set-but-empty value),
set `gt_map.loaded = 0` (the single existing gate of every synthesis path), set a `gt_passthrough` flag,
log `gt-input-remap: gptokeyb passthrough -> 3:/dev/input/eventN (synthesis off)`, then call the real
init. If the wait expires: log `gt-input-remap: gptokeyb running but no Fake Keyboard node after 2 s ->
synthesis fallback` and leave the gptk loaded.

The parser (`buffer -> node path`) and the env-string builder (`node path -> "3:<path>"`) live in the
libc-only half of the file so they compile under `-DGT_REMAP_TEST`; the `/proc` scan, the wait and the
interposers live in the interposer half.

Stick-class devices gain gptokeyb's own analog handling (including mouse_movement) for free; the shim's
F53 analog synthesis is simply off under passthrough.

### 2. Synthesis fallback and shim cleanups

- **Fallback:** no code change in the v2/v3/F53 synthesis paths. They stay keyed on `gt_map.loaded`,
  which activation clears. When no gptokeyb is found (Animal Crossing's pak launcher never starts one; the
  32-bit shim is the same source) or the node never appears, behavior is identical to v0.4.0.
- **Joystick opens follow synthesis only.** `gt_ensure_joystick_open` condition becomes `gt_map.loaded`
  (drop `|| gt_hud_on()`; the HUD stopped consuming SDL joystick events when F35 moved the Menu toggle to
  the evdev thread). The message "opened N/N joystick(s) for key synthesis" is true again and never
  prints under passthrough, so a keyboard-only game does not receive joystick events it would not get on
  any other device.
- **Once-only announce.** The constructor becomes silent: it still parses `GT_REMAP_GPTK` and records the
  outcome (ok with N mappings / cannot open / not set). A `gt_announce()` runs once from the first SDL
  entry point the shim sees — the init interposers, with `SDL_PollEvent`, `SDL_WaitEventTimeout`,
  `SDL_GL_SwapWindow`, `eglSwapBuffers` and `SDL_RenderPresent` as the safety net. It prints, in order:
  `gt-input-remap: loaded`; `gt-input-remap: HUD enabled` when `GT_HUD` is set; the passthrough decision
  line (above; if a safety-net call fires before any init interposer ran, the line reads
  `gt-input-remap: gptokeyb passthrough not evaluated (no SDL init seen)`);
  then the synthesis state: `gt-input-remap: keyboard synthesis on, N mapping(s) from
  <path>` or `gt-input-remap: keyboard synthesis off (gptokeyb passthrough)` or `gt-input-remap: cannot
  open GT_REMAP_GPTK=<path>`. The input-class line stays debug-only. Result: bash, tee and gptokeyb print
  nothing; the game prints each line once.
- **Debug tracing** rides on the existing `GT_INPUT_REMAP_DEBUG` (`use-input-debug`); no new flag.

### 3. Launcher-side (`build/build-pak.sh`, `run_port` window, h700 only)

- **Blocklist gating** (inside the existing `gt-h700-port-remap` awk block, after the HUD blocklist
  check, same shape): if `$ROM_NAME` matches a line of `$PAK_DIR/files/gt-passthrough-blocklist.txt` or
  `$USERDATA_PATH/PORTS-portmaster/use-passthrough-blocklist`, echo
  `gptokeyb passthrough disabled (blocklisted) for $ROM_NAME` and `export GT_PASSTHROUGH=0`. Unset = on.
  New asset `assets/gt-passthrough-blocklist.txt`, staged to `files/`, shipping `Sonic 1.sh` and
  `Sonic 2.sh` with a comment on the face-naming question and the follow-up.
- **Preload snapshot** (new hook `gt-h700-preload-snapshot`, inserted LAST so it lands immediately before
  `"$PAK_DIR/bin/bash" "$ROM_PATH"`, after every preload-composing hook):
  `export GT_LD_PRELOAD="$LD_PRELOAD"`. The complete pak chain, frozen once, so patched launcher lines can
  reference it without double-prepending when a launcher reassigns `LD_PRELOAD` more than once.
- **Preload append** (new hook `gt-h700-preload-append`, inside the F32 mtime window right after the
  Sonic width hook): `sh "$PAK_DIR/files/gt-preload-append.sh" "$ROM_PATH"`. The helper
  (`assets/gt-preload-append.sh`, POSIX sh, staged to `files/`) first greps for a candidate line and
  returns without touching the file if there is none; otherwise it runs one `sed -i` that rewrites every
  line matching `^[[:space:]]*export LD_PRELOAD=` whose value does not contain `LD_PRELOAD` to

      export LD_PRELOAD="${GT_LD_PRELOAD}${GT_LD_PRELOAD:+:}"<original value>

  Shell concatenation keeps the launcher's own library (quoted or not) loading after ours; a trailing
  comment stays a comment. The `LD_PRELOAD` guard makes the rewrite idempotent (the new value contains
  `GT_LD_PRELOAD`) and skips append-style launchers that already reference `$LD_PRELOAD`. Comment lines
  never match (anchored on `export`). `unset LD_PRELOAD` lines are not handled (none known).
  `copy_game_scripts` reverts launchers each GUI session; the hook re-patches every launch, like the Sonic
  width rewrite. A separate helper file (rather than inline awk text) is what lets the host test run the
  real code against sample launchers.

### 4. Testing

**Host (`make test`).**

- `-DGT_REMAP_TEST` binary gains a fixture mode `remap-test --fake-kbd <file>` printing the resolved
  node path or `none`, exit status 0 in both cases (a missing or unreadable file exits 1). Fixtures under `tests/fixtures/input-devices/`: existing `rgsp.txt` -> `none`; new
  `rgsp-gptokeyb.txt` (one Fake Keyboard stanza) -> its node; new `rgsp-gptokeyb-two.txt` (two stanzas,
  where the higher `inputN` has the LOWER `eventN`) -> the higher-`inputN` node, proving the selection key.
  The env builder is asserted inside the existing `main` (the `remap ok` path).
- `gt-preload-append.sh` run against a sample launcher with every line shape: unquoted, quoted with a
  variable, indented, append-style with `$LD_PRELOAD`, commented-out, empty assignment. Output checked
  line by line; a second run must be byte-identical; a launcher with no candidate line keeps inode and
  mtime.
- launch.sh edit asserts (`GT_STAGE_EDIT_ONLY`, shape of test-05/test-13): the two blocklist greps,
  `export GT_PASSTHROUGH=0`, `export GT_LD_PRELOAD=`, and the helper call after the
  `touch -r "$ROM_PATH" "$gt_launcher_mtime_ref"` line.
- test-05 and test-26 keep passing (shim still compiles on the host with the interposer half stripped).

New test file: `tests/test-30-gptokeyb-passthrough.sh`.

**Device gate (RG SP, `ssh root@10.0.1.16`, Camille's hands; one port session at a time, PortMaster idle
before installs, never overwrite a running `.sh` in place).**

1. BYTEPATH on the allowlist as shipped: menus + gameplay work; log shows the passthrough line with the
   node and NO "opened N/N joystick(s)" line. Repeat once with BYTEPATH removed from the allowlist
   (default-on path).
2. Tunics!: playable, no double input, index remap still logged.
3. Sonic 1: log shows the blocklist message; plays as in v0.4.0.
4. OpenTTD with a d-pad-to-mouse gptk: cursor moves, clicks land (mouse-delivery proof; exact gptk syntax
   settled at gate time from the gptokeyb version the port uses).
5. Text input: OpenTTD town/save-name field accepts typed characters.
6. Doom Engines Crispy shareware: the engine's log shows the shim loaded and passthrough active; keyboard
   controls work. Depends on the v0.4.1 library pins being on the device; runs after that phase lands.
7. HUD Menu toggle and sleep/resume during a passthrough port.
8. Select+Start quit works; NextUI's menu is responsive afterwards.
9. Balatro: no double input (its launcher runs gptokeyb; the game now receives those keys as on every
   other CFW).

### 5. Docs, artifacts, coordination

- `docs/h700-fixes.md`: new F54 section appended at the END (no textual collision with the v0.4.1 phase
  editing earlier sections). One-line pointers to F54 in F8 and F26 only.
- `README.md` "Fixing games that ignore your buttons": rewritten — keyboard games now work automatically
  through the port's own translation helper; the built-in list and `use-remap-ports` recipe remain for the
  button-numbering case; a short paragraph on opting a game out via `use-passthrough-blocklist`; the
  technical-details block gains the passthrough half. Review = the file plus the diff, not chat prose.
- Artifacts: `make shim` (Docker) rebuilds `assets/gt-input-remap.so` and `assets/gt-input-remap.armhf.so`;
  `file` every output before committing. This branch is the only one that rebuilds the shims; v0.4.1 in
  the main tree is deliberately shim-free.
- Branch: `feat/mouse-synthesis` renamed to `feat/gptokeyb-passthrough` (keeps its one `.gitignore`
  commit). The triage docs stay untracked on this branch. Nothing is pushed, merged or tagged without
  Camille's say.

## Known limits

- Stale gptokeyb from a crashed launcher: passthrough attaches to it (faithful to other CFWs).
- mono/FNA engines: no interposer fires, no passthrough (no known gptokeyb-tier member).
- `unset LD_PRELOAD` in a launcher is not repaired.
- SDL's evdev keyboard layer may mute the console keyboard while running; observed restored after a normal
  exit, checked after a Select+Start kill in gate 8.

## Follow-ups (recorded, not built)

- Migrate Sonic 1/2 off the passthrough blocklist after a device check of gptokeyb's face naming against
  the overlaid `sonic.gptk`.
- Mouse synthesis fallback, only if a gptokeyb-less mouse-driven port appears.
- Upstream: NextUI SDL fork could scan `/dev/input` itself (its manual-scan branch is an unimplemented stub), making
  this shim step unnecessary.

## Task map

| # | Task | Blocked by |
|---|------|-----------|
| 1 | Passthrough core in `gt-input-remap.c` | — |
| 2 | Shim cleanups: joystick-open gate, once-only announce | 1 |
| 3 | Launcher-side: blocklist, preload snapshot, preload-append helper + assets | — |
| 4 | Host tests: fixtures, env builder, helper, launch.sh edits | 1, 3 |
| 5 | Docs, shim rebuild, branch housekeeping | 2, 4 |
| 6 | Device gate on the RG SP (Camille) | 5 |
