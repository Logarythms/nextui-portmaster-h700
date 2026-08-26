# In-game HUD — Stage 2: software-renderer draw + universal evdev toggle (F35)

**Status:** design, approved direction (Camille, 2026-08-26)
**Builds on:** F34 (`docs/superpowers/specs/2026-08-26-ingame-overlay-hud-design.md`),
branch `feat/hud-stage2-software-fna` off the F34 tip `52f3cbe`.

## Goal

Extend the F34 in-game overlay so it **draws and toggles on every engine this
pak ships**, closing the two Stage-1 gaps: SDL-software-renderer ports (e.g.
*Apotris*) drew nothing, and FNA/mono + gptokeyb ports (e.g. *Celeste*) could
not toggle. After this phase every installed port gets the full HUD, which is
the precondition for cutting **0.3.0** (F33 + F34 + this phase, F35).

## Grounding — device spike (RG SP, 2026-08-26)

The design is built on facts established by an on-device probe, not inference:

- **Celeste already *draws*.** `libFNA3D.so.0` is a native ELF that links
  `libSDL2-2.0.so.0` and calls `SDL_GL_SwapWindow` directly, so F34's existing
  GL swap interposer fires for it. Its *toggle* is dead for a structural
  reason: FNA pumps input in managed C# via mono `[DllImport("SDL2")]`
  P/Invoke, which resolves SDL through an explicit `dlopen` handle and
  **bypasses LD_PRELOAD symbol interposition entirely**. No SDL input hook we
  could add (`SDL_PumpEvents`/`SDL_PeepEvents` included) would ever be called
  from Celeste. The original F34 "interpose the pump functions" idea is a
  **confirmed dead end.**
- **Apotris is a native `SDL_Renderer` port.** Its binary imports
  `SDL_CreateRenderer` / `SDL_CreateTexture` / `SDL_RenderCopy` /
  `SDL_RenderPresent` and links the system `libSDL2-2.0.so.0`. Being a native
  ELF, its `SDL_RenderPresent` call **is** interposable via LD_PRELOAD. It runs
  under `$GPTOKEYB` (gamepad→keyboard), so it emits no SDL joystick events —
  the F34 SDL-joystick toggle never fires for it either.
- **The Menu button is readable from evdev even while a gptokeyb port owns the
  pad.** Capture during a running Apotris returned 8/8 Menu presses on the
  `ANBERNIC-keys` device (`/dev/input/event1`): Menu = `BTN_TL2` (code 312) +
  `KEY_GOTO` (code 354), Volume = `KEY_VOLUMEUP` (115) / `KEY_VOLUMEDOWN`
  (114). gptokeyb does **not** `EVIOCGRAB` the device, and keymon reads it
  unguarded too — so a non-grabbing evdev reader coexists with the game,
  keymon, and gptokeyb. evdev is the one input layer *below* mono, gptokeyb,
  and SDL alike.

## Architecture

Everything lives in the existing `assets/gt-input-remap.c` shim (the
`LD_PRELOAD` library already preloaded on every h700 port by F34). Two
additions plus one behavioral change:

1. **Software draw backend** — interpose `SDL_RenderPresent`; draw the HUD
   through the SDL_Renderer API. Covers Apotris and any 2D-renderer port.
2. **Universal evdev toggle thread** — a detached background thread reads the
   Menu device directly and becomes the *sole* toggle authority for all
   engines. Covers Celeste, Apotris, and (now redundantly but harmlessly) the
   GL ports.
3. **Decision A (chosen):** keep the F34 SDL `SDL_PollEvent` /
   `SDL_WaitEventTimeout` interposers **only to swallow** the Menu edges from
   games where they fire — the toggle call is removed from them. This is
   strictly non-regressive: GL ports keep hiding Menu from the game exactly as
   today; mono/gptokeyb ports get a toggle they never had; nothing newly sees
   the Menu button that didn't already (their SDL hook never fired anyway).

No `build/build-pak.sh` change is needed — F34 already made the LD_PRELOAD and
`GT_HUD=1` gating universal. No new env flag — `GT_HUD` gates both new pieces,
`GT_HUD_DEBUG` traces them.

### Component 1 — Software-renderer draw path (device-only, interposer half)

Interpose `void SDL_RenderPresent(SDL_Renderer *r)`; resolve the real symbol
via `dlsym(RTLD_NEXT, "SDL_RenderPresent")`. On each call:

- `if (gt_sw_dead || !gt_hud_visible) { real(r); return; }` — one branch, zero
  SDL calls, when off or after a failure. `gt_sw_dead` is an independent
  crash-latch mirroring `gt_gl_dead`.
- Resolve the SDL_Render entry points once via `dlsym(RTLD_NEXT, …)`:
  `SDL_CreateTexture`, `SDL_DestroyTexture`, `SDL_UpdateTexture`,
  `SDL_RenderCopy`, `SDL_SetTextureBlendMode`, `SDL_GetRendererOutputSize`. Any
  missing → latch `gt_sw_dead`, call `real(r)`, return.
- Reuse F34's CPU compositor: sample metrics at most ~1×/sec (`gt_hud_sample`
  into `gt_cache`) and recompose the RGBA panel (`gt_hud_compose`) only when
  the text changed — identical cadence to the GL path.
- Lazily create one streaming texture on `r` sized to the composed panel,
  format **`SDL_PIXELFORMAT_ABGR8888`** (little-endian byte order R,G,B,A —
  matches the buffer F34 already feeds `glTexImage2D` as `GL_RGBA`). Cache it
  keyed to the renderer pointer; if `r` differs from the cached one (renderer
  recreated), destroy and rebuild. `SDL_SetTextureBlendMode(tex,
  SDL_BLENDMODE_BLEND)`.
- `SDL_UpdateTexture` from the composed buffer only when it changed.
- Destination rect: `SDL_GetRendererOutputSize(r, &w, &h)` → reuse
  `gt_hud_rect(w, h)` for the top-right origin + margin.
- `SDL_RenderCopy(r, tex, NULL, &dst)`, then `real(r)`.
- If any call fails, latch `gt_sw_dead` and still call `real(r)` — the game
  must present normally no matter what.

A renderer-based port does not reach our `SDL_GL_SwapWindow` interposer (SDL's
internal renderer→GL swap is a direct intra-library call, not a PLT call), so
there is no double-draw between the GL and software paths; each port uses
exactly one. The two dead-latches stay independent.

### Component 2 — Universal evdev toggle thread (device-only, interposer half)

A detached `pthread` started once from the shim constructor **when
`gt_hud_on()`**. It owns HUD visibility for every engine.

- **Device discovery (portability):** scan `/dev/input/event*`; for each, open
  `O_RDONLY` and `ioctl(EVIOCGBIT(EV_KEY, …))` — pick the first device whose
  key bitmap reports **both `BTN_TL2` (312) and `KEY_GOTO` (354)**. Prefer
  capability match over a hardcoded index so the shim survives across h700
  units; `EVIOCGNAME` (`ANBERNIC-keys`) is logged for diagnostics only. If no
  device qualifies, log under `GT_HUD_DEBUG` and exit the thread quietly — the
  HUD simply has no toggle (benign, no crash).
- **Read loop:** blocking `read()` of `struct input_event`. On `EV_KEY`:
  - `BTN_TL2` (312) is the Menu button — drive the existing tap machine with
    `is_menu = 1`. (`KEY_GOTO` 354 is the same button's second emission; it is
    ignored by the tap machine, mirroring F34's raw-11-only toggle.)
  - `KEY_VOLUMEUP`/`KEY_VOLUMEDOWN` (115/114) drive the machine with
    `is_menu = 0` so a Vol press during a Menu hold disqualifies the tap —
    preserving keymon's Menu+Vol brightness combo untouched.
- **Reuse the pure state machine verbatim:** call the existing
  `gt_menu_toggle(&gt_tap, &gt_hud_visible, is_menu, is_down)` from the thread.
  It already encodes single-tap detection + Vol-hold disqualification and is
  host-tested. No new toggle logic — only a new *event source*.
- **Thread safety:** `gt_hud_visible` is written only by this thread and read
  by the draw paths; promote it to `_Atomic int` (or `volatile sig_atomic_t`).
  Single writer, single reader, no compound update — a relaxed atomic is
  sufficient. The tap state (`gt_tap`) is touched only by the evdev thread.
- **No grab:** the device is opened read-only and never `EVIOCGRAB`-ed, so the
  game, keymon, and gptokeyb all keep receiving Menu. This is why Decision A's
  SDL swallow (below) is still needed for the GL ports.
- **Crash safety:** any error (no device, `read()` failure) exits the thread
  silently. Detached, so it never blocks process exit.

### Component 3 — SDL swallow becomes swallow-only (Decision A)

In `gt_hud_intercept` (the SDL `SDL_PollEvent`/`SDL_WaitEventTimeout` path),
**remove the `gt_menu_toggle` call**; keep the swallow of raw 11 / raw 14. The
function no longer flips `gt_hud_visible` — that authority is now the evdev
thread alone, so GL ports (where both paths observe Menu) toggle exactly once
while still hiding Menu from the game.

## Build

`Makefile` `shim` target: add `-pthread` to the `gt-input-remap.so` compile/link
(the evdev thread). `SDL_render.h` is already in the `libsdl2-dev` that F34's
target installs; GL/EGL/SDL symbols stay resolved at runtime. Still no link
against libSDL2 itself.

## Testing

- **Host (`tests/test-05-input-remap.sh`, `-DGT_REMAP_TEST`):** the tap machine
  is already asserted. Add a pure, host-tested **evdev decode helper** —
  `gt_evkey_class(code) → {menu, vol, other}` and an
  `is_down = (value == 1)` mapping — so the thread body reduces to
  "read → classify → `gt_menu_toggle`", with the classification unit-tested.
  Assert `gt_hud_rect` reused by the software path returns an in-bounds
  top-right rect for a renderer size. `main()` still prints `remap ok`.
- **Interposer halves are device-only** (as the GL backend was in F34) — proven
  by the gate, not host asserts.
- **`make shim`** builds cleanly, host test still green.

## Device gate (USER-ORDERED, non-skippable)

On the RG SP (`ssh root@10.0.1.16`), install shim via scp-temp+mv, then:

- **Apotris (software path):** HUD appears, a Menu tap toggles it, values are
  live and correct, toggle-off leaves rendering pristine, no crash.
- **Celeste (GL draw + evdev toggle):** HUD appears (first visual confirmation
  of the FNA3D GL draw) *and* a Menu tap toggles it; no crash. Under mono this
  proves the evdev thread is the working toggle.
- **Regression across F34 GL ports** (Balatro, BYTEPATH, a GameMaker title,
  Tunics!, 2048 Plus): each still toggles (now via evdev), Menu is still
  swallowed from the game, and F25/F26/F31 input-remap + gptk-keyboard behavior
  is intact.
- **keymon combo:** Menu+Vol-up/down brightness still works during a port (the
  Vol-hold disqualification suppresses a spurious toggle).
- **`GT_HUD_DEBUG` trace** shows device discovery + the toggle path for both a
  software and a GL port.

## Risks / notes

- **SDL texture byte order** — `SDL_PIXELFORMAT_ABGR8888` is the expected match
  for the existing RGBA buffer; colors are validated at the gate (a wrong guess
  shows swapped R/B, not a crash).
- **Device-discovery portability** — codes are confirmed only on the RG SP; the
  capability scan (BTN_TL2 + KEY_GOTO) rather than a fixed `event1` is the
  hedge for other h700 units. Gate is RG SP only.
- **Menu no longer swallowed on mono/gptokeyb ports** — those never had swallow
  (their SDL hook never fired), so this is not a regression; documented for
  completeness.
- **evdev thread + keymon both read Menu** — both non-grabbing, so no conflict.

## Out of scope

- Any hardware/compositor overlay (still impossible on this stack — see F34
  spike verdict).
- New metrics or HUD layout changes (F34's layout is final).
- The ALSA/`attr/sys` SharedSettings fallback (still deferred; SharedSettings
  offsets are stable and device-confirmed).
