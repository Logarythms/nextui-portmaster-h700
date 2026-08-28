# Sonic 1 & 2 (RSDK) — NextUI-h700 bring-up (findings + design)

**Date:** 2026-08-28
**Branch:** `fix/f40-libsndfile-sonic`
**Status:** F40 (libsndfile) done + committed. Three tuning issues diagnosed, not yet built.
**Release plan:** HOLD F40's release; ship it bundled with the completed bring-up as one
"Sonic 1 & 2 now work" release (the way Mina F37/F38 and Cave Story F39 shipped complete).

This doc captures the hard-won diagnosis so the dedicated bring-up session doesn't re-derive it.
It is *findings + design direction*, not a task-level implementation plan — do the plan (writing-plans)
in the bring-up session.

---

## The ports

Sonic 1 (`sonic1`) and Sonic 2 (`sonic2`), both from the Rubberduckycooly **RSDKv4
decompilation** (RSDKModding/RSDKv4-Decompilation) — this is the "same decompilation project"
that made them fail identically. Binaries in each gamedir:
- `sonic2013` (default; runs when the mod flag in `mods/modconfig.ini` is off — the normal case)
- `sonic1` → `sonicforever` (Sonic Forever mod), `sonic2` → `sonic2absolute` (Sonic 2 Absolute mod)

Porter: Christian_Haitian / Jeod. Device: `ssh root@10.0.1.16`, ports under
`/mnt/SDCARD/Roms/Ports (PORTS)/.ports/sonic{1,2}`, launchers `"Sonic {1,2}.sh"`,
pak at `/mnt/SDCARD/Emus/h700/PORTS.pak`. Display 720×480 (3:2), `/dev/fb0`.

---

## Prerequisite (NOT a pak fix): the data pack format

The ports need a **user-supplied `Data.rsdk`**. The engine binary accepts **ONLY** packs whose
first 6 bytes are `RSDKvB` (the signature is baked into `sonic2013`; verify with `head -c6 Data.rsdk`).
Packs signed **`RSDKv4_`** (from Steam/Sonic Origins, Epic, eShop, or the *updated* mobile apps, or
community re-packs) **do not load** — the engine registers no data, every `Data/Game/*` lookup misses,
and it exits silently. Correct source = the **pre-Forever mobile Android APK** (per the port's
`sonic.N.md`, which links rsdkmodding.com's file-path guide). Sizes ≈ 17.5 MB (S1), 18.7 MB (S2).
Camille sourced correct `RSDKvB` packs on 2026-08-28 and the ports then booted to the title screen.

**Diagnosis aid:** set `[Dev] EngineDebugMode=true` in `settings.ini` → the engine appends its
own log (data-load, audio, scene) to the gamedir `log.txt` (the same file the launcher tees to).
Without it the engine is silent on every failure, including the "place a data pack" usage guide.

---

## F40 — missing `libsndfile` (DONE, committed, proven)

The RSDK binaries link `libsndfile.so.1`, absent everywhere on NextUI-h700 → loader abort before
`main()` → instant exit (the original symptom). Fix: ship three bullseye libs in the pak `lib/`
(same "h700 lib gap" pattern as F9/F10/F20): `libsndfile.so.1` (1.0.31-2), plus the two sonames its
DT_NEEDED closure adds that weren't already shipped — `libvorbisenc.so.2` (1.3.7-1) and
`libopus.so.0` (1.3.1-0.1). `libFLAC`/`libvorbis`/`libogg` were already present. Pinned in `pins.sh`,
staged in `build/build-pak.sh`, tested by `tests/test-16-libsndfile.sh`, documented as F40 in
`docs/h700-fixes.md`. Device-proven: all four Sonic binaries LD_TRACE clean (zero unresolved).
`make pak` builds; the three built libs match the pinned `_SO_SHA256`.

---

## Issue 1 — Render too narrow (huge side bars, taller-than-wide strip)

**Root cause:** the port launcher (`Sonic N.sh`) computes `ScreenWidth` from the display aspect and
seds it into `settings.ini` every launch. For h700's 720×480 (aspect 1.50) it hits the hardcoded
`LOW=214`. RSDK renders `ScreenWidth × 240`, so 214 → 0.89:1 (a narrow vertical strip; on-screen
≈428 px wide of 720 → ~146 px bars each side). The launcher's `LOW=214` for 3:2 is a port bug — no
aspect branch yields a screen-filling width. **Correct value = 360** (240 × 720/480 = 3:2, fills
720×480 exactly). A `settings.ini`-only change is reverted by the launcher's per-launch sed.

**Proposed fix:** a `run_port` hook (in `edit_portmaster_launch`) that, for the Sonic launchers on
h700, rewrites `LOW=214` → `LOW=360` in the launcher *before* it runs (the same shape as the existing
run_port launcher edits; wrap in the F32 mtime pin so it doesn't retrigger rebuilds). Device-gate:
full-screen, no bars. Confidence: HIGH.

---

## Issue 2 — No sound

**Root cause (engine-level, confirmed on a REAL launch):** RSDKv4's `InitAudioPlayback()` calls
`SDL_OpenAudioDevice` but **never** calls `SDL_InitSubSystem(SDL_INIT_AUDIO)` — it relies on the main
`SDL_Init` having initialized audio. On h700 audio is not initialized at that point, so
`SDL_OpenAudioDevice` fails with **"Unable to open audio device: Audio subsystem is not initialized."**
The engine sets `audioEnabled=false` and continues (no crash, just silent). This is NOT the SSH
codec-contention confound — it reproduced on Camille's real menu launch.

Facts: NextUI's SDL2 (`.system/h700/lib/libSDL2-2.0.so.0`) exposes only **alsa + dummy** audio drivers;
ALSA cards are present (`audiocodec` = card 0). `SDL_AUDIODRIVER=alsa` alone did not fix it in the SSH
test — but that test is confounded (NextUI holds the single-client h700 codec while SSH'd in), so it is
inconclusive for the real launch.

**Proposed fix:** an LD_PRELOAD shim (new, or a sibling to `gt-fmod-audio.so`) interposing
`SDL_OpenAudioDevice`: if `!SDL_WasInit(SDL_INIT_AUDIO)`, call `SDL_InitSubSystem(SDL_INIT_AUDIO)`
first, then chain to the real function. **Open question to resolve on-device (codec free = real launch):**
does `SDL_InitSubSystem(SDL_INIT_AUDIO)` actually succeed on h700 at that point? If ALSA init itself
fails (not merely "was never attempted"), the shim alone won't help and we need to fix *why* alsa init
fails (driver hint, device contention). Confidence: MEDIUM; needs device iteration.

---

## Issue 3 — Controls totally dead (the hard one)

**What's ruled out (all confirmed this session):**
- RSDKv4 uses the **SDL_GameController API exclusively** — no raw-joystick fallback. A pad works only
  if `SDL_IsGameController()` is true (pad present in SDL's mapping DB).
- The pak's `gamecontrollerdb.txt` has a **complete, correct** RG SP entry:
  `19000000010000000100000000010000,RG SP Gamepad,a:b4,b:b3,x:b5,y:b6,back:b9,start:b10,guide:b11,`
  `leftshoulder:b7,rightshoulder:b8,lefttrigger:b12,righttrigger:b13,dpup:h0.1,dpdown:h0.4,`
  `dpleft:h0.8,dpright:h0.2,platform:Linux,` (faces reflect the h700 +3 shift; d-pad is hat 0). The pak
  exports `SDL_GAMECONTROLLERCONFIG_FILE=…/gamecontrollerdb.txt` (control.txt) — and **gptokeyb's SDL
  recognizes the pad by that exact name** in the same env, so the file hint IS loaded by SDL there.
- **gptokeyb is NOT the cause:** controls stayed dead with gptokeyb fully bypassed (launcher line 77
  commented). It's also not the input-remap/HUD shim: dead with the shim inert (HUD blocklisted; the
  shim's `gt_ensure_joystick_open`/`gt_rewrite` are both gated off when remap+HUD are off).

**So:** RSDK's own SDL isn't recognizing/reading the pad on h700, even though a sibling SDL process
(gptokeyb) does. Additionally, on NextUI-h700 **gptokeyb's uinput virtual keyboard does not reach
games** (documented as F26 — the whole reason the input-remap shim synthesizes SDL key events), so the
keyboard path is inherently broken here without shim synthesis. The port's `sonic.gptk` is a no-op
(every button → `\"`, only `back=esc`), implying the port intends native controller.

**Open question for the bring-up session (investigate first, cheaply):** WHY does RSDK's
`SDL_GameController` see no pad when gptokeyb's SDL does? Candidates: RSDK doesn't `SDL_Init` the
gamecontroller subsystem; RSDK init order vs when SDL reads `SDL_GAMECONTROLLERCONFIG_FILE`; the empty
inline `SDL_GAMECONTROLLERCONFIG` (the launcher exports it from `$sdl_controllerconfig`, but
`get_controls()` is a stub `sleep`, so it's empty) overriding/shadowing the file hint. Instrument RSDK
controller detection (source: RSDKModding/RSDKv4-Decompilation `Input.cpp`) or trace SDL.

**Proposed fixes (two candidate paths):**
- **(A) Keyboard-synthesis — the pak's BYTEPATH pattern (robust, idiomatic):** add `Sonic 1.sh` /
  `Sonic 2.sh` to the pak remap list (`files/gt-remap-ports.txt` → `GT_INPUT_REMAP=1`) **and** ship a
  *proper* `sonic.gptk` (via the port-fixes overlay) that maps gamepad → RSDK's `[Keyboard 1]`
  scancodes. The shim then synthesizes SDL key events from the gamepad → RSDK reads keyboard. Sidesteps
  the native-controller mystery entirely.
- **(B) Fix the native controller:** find and fix why RSDK's SDL doesn't recognize the pad
  (env/init/precedence). Cleaner if it's a one-line env fix (e.g. set inline
  `SDL_GAMECONTROLLERCONFIG` to the RG SP mapping string, like Mina's launcher does at line 193).

Recommend: cheap native-controller instrumentation first; if not a quick env fix, take (A).

**Reference — RSDK input mappings (from each `settings.ini`):**
- `[Keyboard 1]` (SDL scancodes): Up=82(↑) Down=81(↓) Left=80(←) Right=79(→); A=29(Z) B=27(X) C=6(C)
  X=4(A) Y=22(S) Z=7(D); Start=40(Return) Select=43(Tab).
- `[Controller 1]` (SDL_GameControllerButton): Up=11 Down=12 Left=13 Right=14; A=0 B=1 C=2 X=3 Y=22
  Z=23; Start=6 Select=5.

---

## Sequencing

Three independent fixes. Suggested order: **resolution** (easy, high-confidence win) → **audio**
(shim) → **controls** (hardest, most iteration). Each device-gated on a real menu launch with valid
`RSDKvB` data present. Ship F40 + all three bundled.

## Device state left after this session

Diagnostic changes to revert (or already reverted): HUD blocklisted for Sonic 1/2 in the device pak
`files/gt-hud-blocklist.txt`; `EngineDebugMode=true` in both `settings.ini`; the launcher edit is
already restored (`Sonic 1.sh.gtbak` removed). **KEEP** the three `libsndfile`/`libvorbisenc`/`libopus`
libs hot-pushed to the device pak `lib/` — they are the F40 fix and let the ports boot for the next
session's testing (removing them reverts to the loader crash).
