# In-game status overlay (HUD) for ports — design (F34)

**Date:** 2026-08-26
**Status:** approved design; implementation pending (feature branch `feat/ingame-overlay-hud`)
**Ships in:** 0.3.0, bundled with F33 (startup-latency trims)

## Motivation

Regular NextUI emulators show a NextUI menu on the Menu button (battery, clock,
etc.) without quitting the game. Ports have no such thing — each port is a
standalone binary that owns the display, and nothing composites above it. The
goal: a toggleable on-screen status overlay while a port runs, showing
**battery, time, volume, and screen brightness**, so users can glance at status
(especially battery) without quitting the port.

## Background: why a hardware overlay is impossible here (spike, 2026-08-26)

A NextUI-style menu can't be reproduced the way emulators do it — that menu is a
`minarch` feature (it loads the libretro core as a library and owns fb0). Ports
don't run under minarch.

The one architecturally-clean alternative — a **hardware DE overlay layer** via
the sunxi `/dev/disp` disp2 driver (a second display-engine layer composited
above the port's framebuffer, present-API-agnostic, immune to GL-state bugs) —
was spiked on the device and **ruled out**:

- `/dev/disp` (disp2), `/dev/ion`, 64 MB CMA are all present; no `/dev/dri` (no
  KMS). At idle the DE uses exactly **one** layer (`screen0 mgr0 720x480,
  ch[1] lyr[0] z[0] addr[ff800000]`, from `cat /sys/class/disp/disp/attr/sys`),
  with other channels/layers free. NextUI drives that layer via **legacy
  fbdev**, not layer ioctls.
- But `DISP_LAYER_SET_CONFIG`/`GET_CONFIG` (0x40/0x41) and the v2 variants
  (0x42/0x43) **all return `EPERM` as root**, for every channel/offset — while
  `DISP_GET_SCN_WIDTH/HEIGHT` (0x07/0x08) work fine (720/480). So the driver
  **specifically refuses userspace DE-layer programming**; it is not a privilege
  or ioctl-convention bug (convention confirmed: `unsigned long a[4]={disp,
  (ulong)&cfg,layer_num,0}; ioctl(fd,cmd,a)`).
- Most plausible cause: the DE manager is in **fbdev mode** (NextUI and every
  port present through `/dev/fb0` → that single auto-created layer), and the
  driver forbids mixing fb-mode with direct composer layer config. The two
  stacks are mutually exclusive; confirming the exact gate would need the h700
  BSP kernel source.

**Conclusion:** the overlay must be a MangoHUD/Steam-style **swap-interpose HUD**
that draws into the port's own GL context. There is no compositor and no second
fbdev to use.

## Architecture (Section 1)

The HUD is a new "present-interpose" half added to the existing LD_PRELOAD shim
`assets/gt-input-remap.c` (already injected into port processes; already
interposes SDL input functions via `dlsym(RTLD_NEXT, …)`; already host-testable
behind `-DGT_REMAP_TEST`).

- **Toggle:** the input-side interposers already see the pad. When the HUD is
  enabled, they watch for the **Menu** button, flip a `hud_visible` bool, and
  **swallow** that event (exactly like ESC/volume are parked today).
- **Draw hook:** interpose the buffer-swap and, when `hud_visible`, draw the HUD
  into the port's own context immediately before the real swap.
  - **Stage 1 (0.3.0):** `SDL_GL_SwapWindow` + `eglSwapBuffers` — the GL/GLES
    path, covering every engine we ship (GameMaker/gmloadernext, LÖVE, solarus,
    Godot).
  - **Stage 2 (later, out of scope for 0.3.0):** `SDL_RenderPresent` for the SDL
    software-renderer path. Pure-software ports show no HUD until then.
- **Sampling:** a sampler reads the four metrics **once per second** into a
  cached struct; the draw hook only formats the cache (no per-frame syscalls).
- **Platform:** RG SP / h700 only, like the rest of the shim.

**Committed risk:** drawing in the port's live GL context means saving and
restoring every GL state object we touch; a leak corrupts the game's rendering.
This is why Stage 1 is GL-first and why per-engine device testing is mandatory.

## Rendering — GL/GLES backend (Section 2)

Core simplification that also contains the GL-state risk: **compose the whole
HUD on the CPU, then draw it as one textured quad.**

- **Font:** a compact bitmap font (~6×8 mono: digits, letters, `%`, `:`, a
  couple of symbols) baked into the `.so` as a static array. No freetype, no
  font files — self-contained like the shim today.
- **Compose on CPU:** once a second (or when a value changes), rasterize the
  four readouts + a translucent background into a small RGBA buffer (~256×40).
  All text layout/formatting is **pure C, host-testable** behind
  `-DGT_REMAP_TEST`.
- **Upload + draw:** lazily compile a tiny shader (position + texcoord) and
  create the texture/VBO on the first swap while the context is current;
  re-upload the texture only when the text changes; draw **one** alpha-blended
  quad in normalized device coords, positioned from the viewport we save.
- **GL-state discipline (the footgun):** save and restore active program,
  active texture unit + bound texture, blend enable/func, depth-test & cull
  enable, viewport, array-buffer binding, and our vertex-attrib arrays (own VAO
  on GLES3). **Toggle-off must fully restore state** (no persistent leak after
  hiding).
- **Dynamic GL resolution:** resolve GL entry points via
  `eglGetProcAddress`/`dlsym` so we call into whatever GL library the port
  actually loaded.
- **Single-draw-per-frame guard:** the padding-marker trick already used for the
  poll/wait double-pass, so a port whose `SDL_GL_SwapWindow` internally calls
  `eglSwapBuffers` doesn't draw the HUD twice.
- **Crash-safety bar:** the draw path is wrapped defensively — a bad state or
  failed shader compile disables the HUD for the session rather than crashing
  the host (opt-out model means an unguarded crash would lose game progress and
  a blocklist can't protect whoever hits it first).

**Per-engine variable:** whether a port uses **GL4ES** (desktop-GL→GLES) vs
native GLES2 is the main render-path difference; dynamic resolution copes with
both, but it's the top reason we device-test each engine.

## Data sampling (Section 3)

All four sources confirmed present and readable from a port (ports run as root).

- **Battery** → `/sys/class/power_supply/axp2202-battery/{capacity,status}`
  (robust kernel ABI). Show percent + a charging indicator.
- **Time** → libc `localtime`/`strftime`. Device clock is accurate and
  timezone-correct (CEST observed).
- **Volume + Brightness** → **primary: `/dev/shm/SharedSettings`**, NextUI's
  132-byte shared struct (33 × int32), holding both in NextUI's own units (the
  0–20 volume / 0–10 brightness shown in the NextUI UI). Cheapest possible read
  (mmap a tiny shm file, no fork, no extra libs); keymon keeps it live during a
  port. It is a NextUI-version-coupled layout → field offsets are locked by an
  empirical check at implementation start (nudge each setting, see which int32
  moves) and re-validated whenever the pinned NextUI is bumped.
  - There is no `/sys/class/backlight`; the disp `attr/sys` dump shows
    `backlight(N)`, confirming brightness lives in NextUI/disp, not standard
    sysfs.
  - **Fallback** (kernel-ABI-robust, but raw units) if SharedSettings proves
    unstable: ALSA `digital volume` control (0–63) via a control-`ioctl`
    (`amixer` is present; control shows e.g. 34 ≈ 54%), plus brightness parsed
    from the disp `attr/sys` `backlight(N)` line.
- **Cadence:** sample all four once per second into a cached struct.

**Open validation items (confirm on-device early):** the SharedSettings offsets,
and that keymon updates volume/brightness live *while a port runs* (so the
readout actually moves).

## Interaction & layout (Section 4)

- **Behavior:** **toggle** on/off (closest to the NextUI emulator-menu model);
  stays up while playing until toggled off. Default state: **off** — the user
  opts in per session by pressing Menu.
- **Trigger:** **Menu** button, single tap; swallowed from the game. Matches the
  NextUI mental model; the shim already sees Menu as a pad button (it currently
  maps to `guide`, which ports almost never use). Reliability on-device and any
  keymon interaction (e.g. sleep) is a gate confirm-item.
- **Layout:** **top-right panel** — a compact stacked box in the top-right
  corner (matches where NextUI itself shows battery/clock; least screen
  occlusion), over a **semi-transparent dark rounded strip with white text**,
  sized for readability on the 720×480 panel:

  ```
  +------------------------------+
  |                  +----------+|
  |                  |BAT  16% +||
  |                  |TIME 13:31||
  |                  |VOL   54% ||
  |                  |BRI   78% ||
  |                  +----------+|
  |      (game plays here)       |
  +------------------------------+
  ```

## Enabling & gating (Section 5)

The shim's **v1 input remap is unconditional on load** and is not safe on
arbitrary ports — which is why the shim is opt-in today. The HUD lives in the
same `.so`, so the two halves get **asymmetric defaults**:

- **Input remap stays opt-in (allowlist):** `GT_INPUT_REMAP=1` only for ports
  that need the TrimUI remap (today's behavior, made an explicit flag).
- **HUD is opt-out (blocklist):** the shim is preloaded on **every** port,
  `GT_HUD` defaults **on**, and `build-pak.sh` carries a **blocklist** that sets
  `GT_HUD=0` for ports where the HUD is known to break.

Mechanics:

- **Universal preload, inert by default.** `run_port` adds the shim to
  `LD_PRELOAD` for all ports. On a non-allowlisted port it does **no** input
  remapping — the poll interposer passes events through and only watches for the
  Menu toggle. On a non-SDL/statically-linked port the shim is simply never
  called (graceful no-op). Universal load does not change input behavior
  anywhere.
- **Blast radius is user-initiated.** The HUD draws nothing until the user
  presses Menu, so even on an untested port the worst case is: toggle on → see a
  glitch → toggle off. This makes opt-out safe **provided** toggle-off fully
  restores GL state and the draw can't crash the host (see Rendering).
- **Toggle detection** lives in the always-on `SDL_PollEvent` /
  `SDL_WaitEventTimeout` interposers; if a HUD port doesn't open a joystick
  itself, reuse the existing lazy `gt_ensure_joystick_open` (today gated on gptk
  synthesis) so the toggle still gets events.
- **Blocklist** = a small list in `build-pak.sh`, same machinery as the existing
  remap/FMOD/gptk lists; adding a port is a one-line change.
- **Footprint note:** Menu is swallowed on every non-blocklisted port when the
  HUD is on. Ports almost never use `guide`/Menu for gameplay; any that do go on
  the blocklist.
- **Debug:** `GT_HUD_DEBUG=1` traces sampling + draw + GL-state save/restore to
  stderr (→ pak log), mirroring `GT_INPUT_REMAP_DEBUG`.

## Testing (Section 6)

**Host-testable (TDD, `-DGT_REMAP_TEST`, run by test-05):**

- HUD text formatting, the bitmap-font rasterizer, the **SharedSettings decode**
  (fixed byte buffer → expected values), the once-a-second sample cache, and the
  Menu toggle state machine (press → flip → swallow). Pure C, no SDL/GL.
- The `build-pak.sh` injection — universal `LD_PRELOAD`, the `GT_INPUT_REMAP`
  (allowlist) / `GT_HUD` (blocklist) env plumbing, idempotency — via the
  `GT_STAGE_EDIT_ONLY` fixture harness, like F33's test-12. New test file
  (e.g. `tests/test-13-overlay-hud.sh`).

**Device gate — per *engine*, not just per port** (render path varies by
present-API; GL4ES-vs-native-GLES is per-engine). One port per family:

- GameMaker (UFO 50 / Deltarune), LÖVE (Balatro), solarus (Tunics!), plus a
  raw-SDL port (2048) to confirm Stage-1 shows **no** HUD there and is a clean
  no-op (not a crash).
- Per port: toggles on/off via Menu; all four values correct **and live**
  (change volume/brightness mid-game and watch them move; charge state);
  **toggle-off leaves rendering pristine**; no crash; no input/audio regression;
  debug trace shows the expected swap path.
- Confirm the two Section-3 open items early (SharedSettings offsets; keymon
  live-update during a port).
- Opt-out safety check: on a normal non-allowlisted port, input is unchanged
  (remap stays off) and the shim is inert until toggled.

## Rollout / 0.3.0

- New fix ID **F34**. Implement on `feat/ingame-overlay-hud` via TDD (host tests
  → `make shim` rebuild → device gate). Squash-commit per the usual flow; docs
  commits fold in.
- Ships as **0.3.0 bundled with F33** (startup trims, already on `main`,
  unreleased). Full `make pak` (needs network → `dangerouslyDisableSandbox`),
  full device gate across the engine matrix, `docs/h700-fixes.md` F34 section +
  terse release notes, then push + tag → CI release. Install = safe unzip-over.
- **Stage 1 only** in 0.3.0 (GL/EGL path). The `SDL_RenderPresent` software path
  is a documented later stage.
- **Regression guard (explicit gate item):** because the shim now loads on
  *every* port, the `GT_INPUT_REMAP` refactor must keep today's remap/keyboard
  ports behaving **identically**.

## Risks / open items

- SharedSettings struct offsets (version-coupled) — lock empirically, re-validate
  on NextUI bumps. Fallback: ALSA control + `attr/sys` parse.
- keymon must update volume/brightness live during a port (else those readouts
  are static) — confirm on-device.
- GL-state leak or crash in the draw path (opt-out amplifies the cost) — rigorous
  save/restore + defensive wrapping + per-engine gate.
- GL4ES vs native GLES2 per engine — dynamic GL resolution; per-engine testing.
- Menu/keymon interaction — confirm; blocklist any port that uses `guide`.

## Out of scope

- Stage 2 `SDL_RenderPresent` software-renderer backend (later).
- RG DS / any non-h700 device.
- The hardware DE-overlay-layer route (spiked and ruled out — EPERM).
