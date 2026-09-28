# Mouse synthesis in gt-input-remap.so — feasibility (2026-09-04)

> **RE-SCOPED 2026-09-04 18:50 — read `2026-09-04-issue-1.md`, section "Keyboard delivery on NextUI" first.**
> The device pass found WHY gptokeyb's output never reaches ports: NextUI's SDL is a no-libudev build whose evdev
> keyboard/mouse layer opens only devices listed in the env var `SDL_EVDEV_DEVICES`. Setting it to gptokeyb's "Fake
> Keyboard" node before the game starts made BYTEPATH's keyboard menu work through gptokeyb itself (shim off). The same
> SDL path delivers REL mouse events. So the cheaper, more faithful design is **gptokeyb passthrough** (set
> `SDL_EVDEV_DEVICES` from the preload shim at `SDL_Init`, bounded wait for the uinput node) rather than re-implementing
> gptokeyb's mouse in the shim. The synthesis design below stays valid only as a FALLBACK for ports that run without
> gptokeyb (Sonic F43 overlay, Animal Crossing F45 evdev path). Verify mouse delivery first (OpenTTD, d-pad→mouse gptk).

Context: triage of issue #1 (`docs/triage/2026-09-04-issue-1.md`) showed that 7 of 9 reported ports are
keyboard+mouse designs driven by gptokeyb. On NextUI-h700 gptokeyb's uinput keyboard/mouse never reaches the
game (README "Fixing games that ignore your buttons"). The pak's translator (`assets/gt-input-remap.c`) synthesizes
SDL keyboard events from the port's `.gptk` for allowlisted ports; it deliberately synthesizes **nothing** for
mouse-driven sticks (`analog_mouse[]`, "stick is mouse-driven in the gptk -> synthesize nothing") and ignores
`mouse_left/right/middle` button values. Mouse synthesis is what would unlock that class.

This is an ARCHITECTURAL item: brainstorm → spec → plan (superpowers), not a bounded fix. Working name: F54.

## Verdict

Feasible, medium-sized (comparable to F53 stick support: ~8 plan tasks). Most plumbing exists. Its analog half
cannot be device-verified on the RG SP (no sticks); the d-pad→mouse half can.

## What the shim already has (as of v0.4.0, `assets/gt-input-remap.c`, 2334 lines)

- Interposed: `SDL_PollEvent`, `SDL_WaitEventTimeout`, `SDL_GetKeyboardState` (F31 polling mirror),
  `SDL_GL_SwapWindow` + `SDL_RenderPresent` (HUD). 8-entry `gt_stash[]` for extra synthesized events.
- gptk parser (`gt_gptk_line`) already recognizes `mouse_movement_*` (sets `analog_mouse[stick]`); hotkey
  variants (`x_hk`) and `mouse_*` button values are NOT handled.
- F53 axis handling: `gt_axis_dir(value, deadzone)`, `analog_key[2][4]`, `gt_evdev_hat_edges`, gptokeyb-parity
  defaults; SDL_JOYAXISMOTION branch in `gt_rewrite`; evdev thread (F45 path) handles EV_ABS only for HAT0X/Y.
- `gt_ensure_joystick_open()` opens every joystick lazily when synthesis or the HUD is on (prints
  "opened N/N joystick(s) for key synthesis" — misleading wording, fires for HUD-only too).
- No clock anywhere in the shim (no SDL_GetTicks/clock_gettime).
- Host test harness: `-DGT_REMAP_TEST` pure-logic tests (`tests/test-05-input-remap.sh`, `test-26-…`).
- HUD overlay draw path (GL + software renderer) could draw a cursor sprite (stage 2).

## What has to be built

1. **Motion generation with a clock.** On each poll with an empty real queue, emit one `SDL_MOUSEMOTION` per
   `mouse_delay` tick (gptokeyb default 16 ms) with delta scaled by stick deflection × `mouse_scale`;
   `mouse_slow` modifier; d-pad→`mouse_movement_*` too (stickless `.gptk.0` variants use it, e.g. Fallout 1).
   Use `clock_gettime(CLOCK_MONOTONIC)`.
2. **Virtual mouse state.** Absolute position clamped to the window (size via `SDL_GetWindowSize` on
   `SDL_GetMouseFocus()`/intercepted `SDL_CreateWindow`), accumulated relative deltas, button mask. Every motion
   event carries x,y AND xrel,yrel so relative-look games (OpenJK) and cursor games (FreeSerf, Fallout) both work.
   `which = 0` (never SDL_TOUCH_MOUSEID).
3. **Polling half.** Interpose `SDL_GetMouseState`, `SDL_GetRelativeMouseState`, `SDL_GetGlobalMouseState`,
   `SDL_WarpMouseInWindow`/`SDL_WarpMouseGlobal` (engines re-center when relative mode is unavailable — likely on
   the mali driver; the warp must move the virtual cursor). Also interpose `SDL_WaitEvent`: SDL's internal call to
   the timeout variant does not pass through our preload, and a game blocked in WaitEvent with a deflected stick
   must still receive motion (bounded wait = mouse_delay).
4. **Buttons.** `mouse_left/right/middle` (and `_hk` variants if cheap) → `SDL_MOUSEBUTTONDOWN/UP` at the virtual
   position, `clicks = 1`; mirror into the polled button mask.
5. **Policy.** Coverage stays opt-in via `gt-remap-ports.txt` / `use-remap-ports` unless the design decides to
   auto-enable when a gptk has mouse lines. Decide in the spec.

Estimate: 300–450 lines of C + host tests; no launch.sh change required beyond policy.

## Risks and limits

- **Cursor visibility.** The fbdev/mali driver almost certainly draws no OS cursor. Fallout, FreeSerf and OpenJK
  draw their own; games relying on the system cursor would be blind → HUD-drawn cursor as stage 2.
- **Relative mouse mode** may be unsupported on NextUI's SDL; covered by the warp interposer.
- **Device gate.** RG SP has no sticks: analog-mouse untestable locally (label experimental like F53); d-pad→mouse
  testable. Free gate candidate: OpenTTD (mouse-driven, PortMaster gptk). Jedi Outcast / FreeSerf / Fallout need
  owned data.
- **Engines bypassing the preload** (mono/FNA) are out of scope, as before.
- **Ports that call `SDL_PeepEvents` directly** would miss injected events (rare).
- Alternative route rejected: shipping a patched SDL2 with an evdev input layer for the mali driver so uinput
  devices work — heavy, unknown, not started.

## Coordination with the v0.4.1 bugfix phase (running in the main tree)

- v0.4.1 should stay **shim-free** (conf/pins/launch.sh/docs only) so only ONE branch rebuilds
  `assets/gt-input-remap.so` — the prebuilt `.so` files are committed and would conflict as binaries. Fold the
  log-spam cleanup ("loaded"/"HUD enabled" per subprocess) and the "opened … for key synthesis" wording fix into
  the mouse branch, which rebuilds the shim anyway.
- Shared docs (`docs/h700-fixes.md`, `README.md`) will conflict textually; keep new sections at the end.
- One RG SP: coordinate port sessions (never two at once; PortMaster idle before installs).

## Reading list for the new session

- `assets/gt-input-remap.c` (F25/F26/F31/F34/F35/F45/F48/F52/F53 comments at the top), `assets/gt-remap-ports.txt`
- `docs/h700-fixes.md` sections F26, F31, F53; `docs/superpowers/specs/2026-09-01-stick-device-support-design.md`
- gptokeyb semantics: PortsMaster/gptokeyb (mouse_scale, mouse_delay, mouse_slow, deadzone_*), and
  https://portmaster.games/gptokeyb-documentation.html
- Example gptks in `docs/triage/2026-09-04-issue-1.md` (Jedi Outcast, FreeSerf, Quakespasm)
