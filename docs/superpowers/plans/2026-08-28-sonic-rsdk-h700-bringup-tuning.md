# Sonic 1 & 2 (RSDK) h700 bring-up — tuning fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the two RSDK Sonic ports (Sonic 1 & Sonic 2) fully playable on NextUI-h700 — correct render size, working audio, working controls — then ship all four fixes (F40 already committed + F41/F42/F43) as one "Sonic 1 & 2 now work" 0.3.2 release.

**Architecture:** All three fixes follow existing pak idioms. Resolution (F41) is a mtime-neutral `run_port` launcher sed inside the F32 window. Audio (F42) is a new single-purpose LD_PRELOAD shim (interpose `SDL_OpenAudioDevice` → force `SDL_InitSubSystem(SDL_INIT_AUDIO)` first), compiled by the Makefile `shim` target and preloaded by a `run_port` gate. Controls (F43) starts with an on-device SDL-enumerate probe to settle the root cause, then lands either a native `gamecontrollerdb` GUID correction (preferred) or the pak's keyboard-synthesis remap pattern (fallback).

**Tech Stack:** POSIX sh (`build/build-pak.sh` `edit_portmaster_launch` awk injections), C LD_PRELOAD shims (`assets/*.c`, Docker bullseye arm64 gcc via `make shim`), shell test suite (`tests/test-*.sh` + `tests/helpers.sh`), PortMaster/RSDKv4 runtime on the device.

**Spec:** `docs/superpowers/specs/2026-08-28-sonic-rsdk-h700-bringup-design.md` (findings + fix design; read it alongside this plan).

## Global Constraints

- **Repo:** `/Users/camillemainz/dev/nextui-portmaster-h700`, branch `fix/f40-libsndfile-sonic` (already holds F40: commits `dc62adb` + design doc `dabcec5`). All F41–F43 work lands on this branch. The pak repo uses **per-fix `feat:` commits** (see git log F34–F39), NOT one-squash-per-phase.
- **Device gate is mandatory and only Camille can run it** (he holds the RG SP, `ssh root@10.0.1.16`; both ports already have valid `RSDKvB` `Data.rsdk`). No fix is "done" until device-verified on a real menu launch.
- **Resolution target is `LOW=360`** exactly (240 × 720/480 = 3:2 fills 720×480). Confirmed token in the launcher is `LOW=214 # 3:2` (line 39 of `Sonic {1,2}.sh`).
- **Any edit that touches `$ROM_PATH` (the port launcher) MUST be mtime-neutral** — placed inside the F32 mtime snapshot/restore window (`build/build-pak.sh:268-312`) — or it retriggers a full re-patch every PortMaster session (the exact bug F32 fixed).
- **vfat SD card: no symlinks.** Ship real files named by SONAME.
- **Shims are compiled by `make shim`** (Docker `debian:bullseye` `--platform linux/arm64`, `Makefile:14-20`) and the built `.so` is committed to `assets/`. `build-pak.sh` only `cp`s prebuilt `.so` into the pak `lib/`. `build-pak.sh` contains zero `gcc`.
- **`make pak` needs network** → run it with the sandbox disabled. `make test` runs `tests/run.sh` (globs `test-*.sh`; no registration).
- **Gate Sonic-only behavior** on `[ -f "$GAMEDIR/sonic2013" ]` (the RSDK binary present in both port dirs) for `$GAMEDIR`-scoped hooks, or `case "${ROM_PATH##*/}" in "Sonic 1.sh"|"Sonic 2.sh")` for the early (pre-GAMEDIR) resolution hook. Port dirs are `.ports/sonic1` / `.ports/sonic2`; launchers `Sonic 1.sh` / `Sonic 2.sh`.
- **Never push, merge to main, tag, or publish a release without Camille's explicit approval** (standing invariant). Release notes follow the terse `### Fixes` / `### Upgrading` style (see the pak-release-notes memory).

**User decisions (already made):**
- "Do it as its own planned session" — this plan is that session.
- Bundle F40 with the completed bring-up as **one 0.3.2 release** ("Sonic 1 & 2 now work"); hold F40's standalone release. (Expand the existing `### 0.3.2` changelog stub, don't cut a new version.)
- Camille sourced correct `RSDKvB` `Data.rsdk` packs; the data prerequisite is satisfied and is out of scope for the pak.

---

### Task 1: F41 — Resolution (ScreenWidth LOW=214 → 360)

**Goal:** The Sonic ports render full-screen (no side bars) on the h700 by rewriting the launcher's `LOW=214` to `LOW=360`, mtime-neutrally, inside `run_port`.

**USER-ORDERED GATE — NON-SKIPPABLE.** This task ends in a device verification only Camille can perform. It MUST NOT be closed by walking around it or declaring it "verified inline". Close only after the device gate below is observed with output/description captured.

**Files:**
- Modify: `build/build-pak.sh` — add a new awk block in `edit_portmaster_launch()` (after the F32 block, ends `:312`).
- Create: `tests/test-17-sonic-resolution.sh`
- Modify: `docs/h700-fixes.md` (F41 bullet — folded into Task 5, but the test asserts `F41` present, so add the bullet here or ensure Task 5 runs before this test's docs assertion; add the one-line F41 bullet in this task to keep the test self-contained).

**Acceptance Criteria:**
- [ ] `edit_portmaster_launch` injects a `gt-h700-sonic-resolution` block that, for `${ROM_PATH##*/}` in `Sonic 1.sh`/`Sonic 2.sh` on h700, runs `sed -i "s/LOW=214/LOW=360/" "$ROM_PATH"`.
- [ ] The block is placed **after** the F32 `touch -r "$ROM_PATH" "$gt_launcher_mtime_ref"` snapshot line (so it's inside the mtime window) and **before** the `directory=` restore anchor.
- [ ] Injection is idempotent (marker count stays 1 on a second `edit_portmaster_launch` pass).
- [ ] Behavioral: a fake `Sonic 1.sh` containing `LOW=214 # 3:2` becomes `LOW=360` after the extracted block runs; a non-Sonic launcher is untouched.
- [ ] Edited `launch.sh` still passes `sh -n`.
- [ ] `docs/h700-fixes.md` contains `F41`.
- [ ] **Device gate (Camille):** launch Sonic 1 and Sonic 2 from the PortMaster menu → image fills the 720×480 screen, no huge side bars.

**Verify:** `sh tests/test-17-sonic-resolution.sh` → prints nothing and exits 0; then `make test` all green.

**Steps:**

- [ ] **Step 1: Confirm the launcher token (device, read-only).** Already confirmed this session: `.ports/Sonic 1.sh` line 39 is `LOW=214 # 3:2`, line 41 `HIGH=426 # 16:9`, and lines 60-61 do `sed -i "s/^ScreenWidth=[0-9]\+/ScreenWidth=$WIDTH/" "$GAMEDIR/settings.ini"`. No further read needed; proceed.

- [ ] **Step 2: Write the failing test** `tests/test-17-sonic-resolution.sh`:

```sh
#!/bin/sh
. "$(dirname -- "$0")/helpers.sh"

# parse-check
sh -n "$ROOT/build/build-pak.sh"

# run only the edit functions against the fixture pair
work="$SANDBOX/pmpak"; mkdir -p "$work"
cp "$TROOT/fixtures/portmaster-pak-skeleton/pak.json.fixture" "$work/pak.json"
cp "$TROOT/fixtures/portmaster-pak-skeleton/launch.sh.fixture" "$work/launch.sh"
GT_STAGE_EDIT_ONLY="$work" sh "$ROOT/build/build-pak.sh" portmaster

# marker + content present
assert_contains "$work/launch.sh" 'gt-h700-sonic-resolution'
assert_contains "$work/launch.sh" 's/LOW=214/LOW=360/'
assert_contains "$work/launch.sh" '"Sonic 1.sh"|"Sonic 2.sh")'

# placed INSIDE the F32 mtime window: resolution block after the snapshot touch -r line
snap=$(grep -n 'touch -r "$ROM_PATH" "$gt_launcher_mtime_ref"' "$work/launch.sh" | head -1 | cut -d: -f1)
res=$(grep -n 'gt-h700-sonic-resolution' "$work/launch.sh" | head -1 | cut -d: -f1)
[ -n "$snap" ] && [ -n "$res" ] && [ "$res" -gt "$snap" ] \
  || { echo "resolution block not inside F32 mtime window (snap=$snap res=$res)"; exit 1; }

# idempotent
GT_STAGE_EDIT_ONLY="$work" sh "$ROOT/build/build-pak.sh" portmaster
assert_eq "$(grep -c 'gt-h700-sonic-resolution' "$work/launch.sh")" "1"

# still parses
sh -n "$work/launch.sh"

# behavioral: slice the injected case block, run it against fake launchers
block=$(sed -n '/# gt-h700-sonic-resolution:/,/esac/p' "$work/launch.sh")
mkfake() { printf 'LOW=214 # 3:2\nHIGH=426 # 16:9\n' > "$1"; }
run_block() { ROM_PATH="$1" PLATFORM="h700"; eval "$block"; }
mkfake "$SANDBOX/Sonic 1.sh"; run_block "$SANDBOX/Sonic 1.sh"
assert_contains "$SANDBOX/Sonic 1.sh" 'LOW=360'
mkfake "$SANDBOX/Other.sh";  run_block "$SANDBOX/Other.sh"
assert_contains "$SANDBOX/Other.sh" 'LOW=214'   # untouched

# docs coverage
assert_contains "$ROOT/docs/h700-fixes.md" 'F41'
echo "test-17 ok"
```

- [ ] **Step 3: Run the test, watch it fail** (`sh tests/test-17-sonic-resolution.sh` → fails on the first `assert_contains 'gt-h700-sonic-resolution'`, block not yet injected).

- [ ] **Step 4: Add the injection block** in `build/build-pak.sh` immediately after the F32 block (after `:312`). Model exactly on the F32/F39 awk idiom:

```sh
  # gt-h700-sonic-resolution: F41 — the RSDK Sonic ports set ScreenWidth
  # LOW=214 (0.89:1) for a 3:2 display, which renders a narrow vertical strip
  # with huge side bars on the h700's 720x480. 360 = 240*720/480 fills it. We
  # rewrite the launcher's LOW value before run_port execs it, INSIDE the F32
  # mtime window (snapshot just above) so the edit doesn't retrigger a rebuild.
  # copy_game_scripts reverts the launcher to pristine 214 each PortMaster
  # session -> this self-heals; the sed is a no-op once it already reads 360.
  if ! grep -q 'gt-h700-sonic-resolution' "$f"; then
    awk '
    $0 == "    touch -r \"$ROM_PATH\" \"$gt_launcher_mtime_ref\"" {
      print
      print ""
      print "    # gt-h700-sonic-resolution: F41 — fill the 720x480 screen (see docs)"
      print "    case \"${ROM_PATH##*/}\" in"
      print "    \"Sonic 1.sh\"|\"Sonic 2.sh\")"
      print "        if [ \"$PLATFORM\" = \"h700\" ]; then"
      print "            sed -i \"s/LOW=214/LOW=360/\" \"$ROM_PATH\" 2>/dev/null || true"
      print "        fi"
      print "        ;;"
      print "    esac"
      next
    }
    { print }' "$f" > "$f.awk.tmp" && mv "$f.awk.tmp" "$f"
  fi
```

- [ ] **Step 5: Add the F41 docs bullet** in `docs/h700-fixes.md` (in the "Missing shared libraries" section is wrong here — put it near the F39 material; a one-liner is fine, full write-up folds into Task 5). Minimum to satisfy the test: a line containing `F41`, e.g.:

```markdown
- **F41 — the RSDK Sonic ports render as a narrow vertical strip.** The port
  launcher hardcodes `ScreenWidth` `LOW=214` (0.89:1) for a 3:2 display; on the
  h700 720×480 that leaves huge side bars. `run_port` rewrites `LOW=214`→`LOW=360`
  (240×720/480, fills the screen), mtime-neutrally inside the F32 window.
```

- [ ] **Step 6: Run the test, watch it pass**, then `make test` (all `test-*.sh` green).

- [ ] **Step 7: Build + device-gate.** `make pak` (network → sandbox disabled). Install/refresh on the device (safe unzip-over), then **Camille launches both ports** and confirms full-screen, no bars. Capture the observation.

- [ ] **Step 8: Commit** (`feat: F41 — full-screen render for the RSDK Sonic ports`).

```json:metadata
{"files": ["build/build-pak.sh", "tests/test-17-sonic-resolution.sh", "docs/h700-fixes.md"], "verifyCommand": "sh tests/test-17-sonic-resolution.sh && make test", "acceptanceCriteria": ["gt-h700-sonic-resolution block injected, seds LOW=214->360 for Sonic launchers", "block sits inside the F32 mtime window", "idempotent (marker count 1)", "behavioral: fake Sonic launcher 214->360, non-Sonic untouched", "edited launch.sh passes sh -n", "docs contain F41", "DEVICE: both ports full-screen, no side bars"], "modelTier": "standard", "userGate": true, "tags": ["user-gate"]}
```

---

### Task 2: F42 — Audio (force SDL_INIT_AUDIO before SDL_OpenAudioDevice)

**Goal:** Sonic music/SFX plays. RSDKv4's `InitAudioPlayback()` calls `SDL_OpenAudioDevice` without ever calling `SDL_InitSubSystem(SDL_INIT_AUDIO)`, so on h700 it fails with "Audio subsystem is not initialized" and the game runs silent. Ship a tiny LD_PRELOAD shim that inits the audio subsystem first.

**USER-ORDERED GATE — NON-SKIPPABLE.** Ends in a device verification only Camille can perform (codec is free only on a real menu launch — SSH tests are confounded by NextUI holding the single-client codec). Close only after Camille confirms audio, output captured.

**Files:**
- Create: `assets/gt-sdl-audio-init.c`
- Modify: `Makefile` (`shim` target — add one gcc line; add the `.so` to the trailing `file` check)
- Modify: `build/build-pak.sh` — `cp` the `.so` into `lib/` (near `:1141-1147`) and add a `run_port` preload gate (model on F30 fmod, `:609-624`) keyed on `[ -f "$GAMEDIR/sonic2013" ]`
- Create: `tests/test-18-sdl-audio-init.sh`

**Acceptance Criteria:**
- [ ] `assets/gt-sdl-audio-init.c` interposes `SDL_OpenAudioDevice` via `dlsym(RTLD_NEXT,...)`; if `SDL_WasInit(SDL_INIT_AUDIO)` is 0 it calls `SDL_InitSubSystem(SDL_INIT_AUDIO)` (both resolved via `dlsym`) before chaining to the real function. Pure decision helper `gt_should_init_audio(int wasinit)` is unit-testable under `-DGT_SDL_AUDIO_TEST`.
- [ ] `make shim` compiles it and the committed `assets/gt-sdl-audio-init.so` is aarch64.
- [ ] `build-pak.sh` `cp`s it into the pak `lib/` and adds it to `LD_PRELOAD` only when `[ -f "$GAMEDIR/sonic2013" ]` on h700.
- [ ] `tests/test-18` compiles the `.c` with `-DGT_SDL_AUDIO_TEST` and asserts `gt_should_init_audio(0)==1`, `gt_should_init_audio(1)==0`; plus structural asserts (staged in `lib/`, preload gate present, gated on `sonic2013`).
- [ ] **Device gate (Camille):** Sonic music is audible on a real launch.

**Verify:** `sh tests/test-18-sdl-audio-init.sh && make test` → green; `make shim` → `assets/gt-sdl-audio-init.so: ELF 64-bit ... aarch64`.

**Steps:**

- [ ] **Step 1: Write the failing test** `tests/test-18-sdl-audio-init.sh`:

```sh
#!/bin/sh
. "$(dirname -- "$0")/helpers.sh"

# pure decision compiles + behaves
cc -DGT_SDL_AUDIO_TEST -O2 -o "$SANDBOX/audio-test" "$ROOT/assets/gt-sdl-audio-init.c"
assert_eq "$("$SANDBOX/audio-test" 0)" "1"   # not inited -> init
assert_eq "$("$SANDBOX/audio-test" 1)" "0"   # already inited -> skip

# staged + gated in build-pak.sh
sh -n "$ROOT/build/build-pak.sh"
assert_contains "$ROOT/build/build-pak.sh" 'gt-sdl-audio-init.so'
assert_contains "$ROOT/build/build-pak.sh" '$GAMEDIR/sonic2013'
echo "test-18 ok"
```

- [ ] **Step 2: Run it, watch it fail** (the `.c` doesn't exist yet).

- [ ] **Step 3: Write `assets/gt-sdl-audio-init.c`** (model on `gt-fmod-audio.c`'s interpose + `-DGT_..._TEST` split):

```c
/* gt-sdl-audio-init.so — F42. RSDKv4 InitAudioPlayback() calls
 * SDL_OpenAudioDevice without SDL_InitSubSystem(SDL_INIT_AUDIO); on h700 audio
 * is not inited at that point, so the open fails ("Audio subsystem is not
 * initialized") and the game runs silent. We force-init the audio subsystem
 * on the first open. Preloaded only for the RSDK Sonic ports (build-pak.sh
 * gate on $GAMEDIR/sonic2013). Harmless if audio is already inited. */
#include <stdint.h>

#define GT_SDL_INIT_AUDIO 0x00000010u

/* Pure, testable decision: init only when the audio subsystem is not up. */
static int gt_should_init_audio(unsigned wasinit_audio) { return wasinit_audio ? 0 : 1; }

#ifdef GT_SDL_AUDIO_TEST
#include <stdlib.h>
#include <stdio.h>
int main(int argc, char **argv) {
    unsigned w = (argc > 1) ? (unsigned)atoi(argv[1]) : 0;
    printf("%d\n", gt_should_init_audio(w));
    return 0;
}
#else
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>

static int gt_debug(void) { const char *e = getenv("GT_SDL_AUDIO_DEBUG"); return e && *e == '1'; }

__attribute__((constructor)) static void gt_load(void) {
    if (gt_debug()) fprintf(stderr, "gt-sdl-audio-init: loaded\n");
}

/* SDL_OpenAudioDevice(const char*, int iscapture, const SDL_AudioSpec*, SDL_AudioSpec*, int allowed) -> SDL_AudioDeviceID (uint32) */
uint32_t SDL_OpenAudioDevice(const char *device, int iscapture,
                             const void *desired, void *obtained, int allowed_changes) {
    static uint32_t (*real)(const char *, int, const void *, void *, int);
    static unsigned (*p_wasinit)(unsigned);
    static int (*p_initsub)(unsigned);
    if (!real)      real      = (uint32_t (*)(const char *, int, const void *, void *, int))dlsym(RTLD_NEXT, "SDL_OpenAudioDevice");
    if (!p_wasinit) p_wasinit = (unsigned (*)(unsigned))dlsym(RTLD_NEXT, "SDL_WasInit");
    if (!p_initsub) p_initsub = (int (*)(unsigned))dlsym(RTLD_NEXT, "SDL_InitSubSystem");

    unsigned w = p_wasinit ? (p_wasinit(GT_SDL_INIT_AUDIO) & GT_SDL_INIT_AUDIO) : GT_SDL_INIT_AUDIO;
    if (gt_should_init_audio(w) && p_initsub) {
        int rc = p_initsub(GT_SDL_INIT_AUDIO);
        if (gt_debug()) fprintf(stderr, "gt-sdl-audio-init: SDL_InitSubSystem(AUDIO) rc=%d\n", rc);
    }
    return real ? real(device, iscapture, desired, obtained, allowed_changes) : 0;
}
#endif
```

- [ ] **Step 4: Add the compile line** to the `Makefile` `shim` target (after the gles3 line):

```makefile
	   gcc -O2 -Wall -shared -fPIC -o gt-sdl-audio-init.so gt-sdl-audio-init.c -ldl && strip gt-sdl-audio-init.so'
```
and append `assets/gt-sdl-audio-init.so` to the trailing `file assets/...` line. Run `make shim`; commit the built `.so`.

- [ ] **Step 5: Stage + gate in `build/build-pak.sh`.** Add the `cp` near `:1141-1147`:

```sh
  # gt-sdl-audio-init: F42 — force SDL audio-subsystem init for the RSDK Sonic
  # ports (auto-gated on $GAMEDIR/sonic2013; see edit_portmaster_launch).
  cp "$ASSETS/gt-sdl-audio-init.so" "$assembled/lib/gt-sdl-audio-init.so"
```
Add the preload gate inside `edit_portmaster_launch` (a new awk block modeled on F30 fmod `:609-624`, anchored on the pre-exec `"$PAK_DIR/bin/bash" "$ROM_PATH"` line), marker `gt-h700-sonic-audio`:

```sh
      print "    if [ \"$PLATFORM\" = \"h700\" ] && [ -f \"$GAMEDIR/sonic2013\" ]; then"
      print "        export LD_PRELOAD=\"$PAK_DIR/lib/gt-sdl-audio-init.so${LD_PRELOAD:+:$LD_PRELOAD}\""
      print "    fi"
```
(Match F30's exact `export LD_PRELOAD=` shape in that file when implementing.)

- [ ] **Step 6: Run test → pass**, `make test` green, `make pak` builds.

- [ ] **Step 7: Device-gate (Camille).** Refresh on device; Camille launches Sonic, listens for music. **Decision branch:** if audible → done. If still silent → set `GT_SDL_AUDIO_DEBUG=1`, relaunch, read the gamedir `log.txt` for the `SDL_InitSubSystem(AUDIO) rc=` line: `rc=0` but still silent ⇒ try adding `export SDL_AUDIODRIVER=alsa` to the same gate; `rc<0` ⇒ ALSA init itself fails on h700 (codec contention/driver) — investigate the ALSA path before claiming F42. Do NOT close on a silent launch.

- [ ] **Step 8: Commit** (`feat: F42 — audio for the RSDK Sonic ports (force SDL audio init)`).

```json:metadata
{"files": ["assets/gt-sdl-audio-init.c", "assets/gt-sdl-audio-init.so", "Makefile", "build/build-pak.sh", "tests/test-18-sdl-audio-init.sh"], "verifyCommand": "sh tests/test-18-sdl-audio-init.sh && make test", "acceptanceCriteria": ["shim interposes SDL_OpenAudioDevice, inits SDL_INIT_AUDIO when not up", "gt_should_init_audio(0)==1 and (1)==0 under -DGT_SDL_AUDIO_TEST", "make shim builds aarch64 .so", "staged in lib/ and preloaded only when $GAMEDIR/sonic2013 on h700", "DEVICE: Sonic music audible on a real launch"], "modelTier": "standard", "userGate": true, "tags": ["user-gate"]}
```

---

### Task 3: F43 — Controls, part 1: root-cause probe + native gamecontrollerdb fix

**Goal:** Settle *why* RSDK's `SDL_GameController` reads no pad on h700 (gptokeyb's SDL does), then — if it's a GUID/mapping mismatch — fix it natively by correcting the `RG SP Gamepad` entry in the pak's `gamecontrollerdb`. RSDKv4 uses the `SDL_GameController` API exclusively.

**USER-ORDERED GATE — NON-SKIPPABLE.** Ends in a device verification only Camille can perform (buttons must be pressed and observed in-game). Close only after Camille confirms controls respond, output captured.

**Files:**
- Create (throwaway, NOT committed — build in the scratchpad): a ~30-line SDL enumerate probe.
- Modify (only if the probe shows a GUID mismatch): `assets/gamecontrollerdb-h700-xbox.txt` and `assets/gamecontrollerdb-h700-nintendo.txt` (line 8, the `RG SP Gamepad` entry).

**Acceptance Criteria:**
- [ ] The on-device probe (using the pak's `libSDL2` + the pak's `gamecontrollerdb.txt`) prints, for the `ANBERNIC-keys` pad: the **actual GUID SDL computes**, `SDL_IsGameController()`, and (if true) the resolved mapping. Root cause recorded in the ledger.
- [ ] If GUID mismatch: the `RG SP Gamepad` entry GUID in both `assets/gamecontrollerdb-h700-*.txt` is corrected to the measured GUID (button mapping unchanged); `make pak` rebuilds; the entry appears in the built `files/gamecontrollerdb_*.txt`.
- [ ] **Device gate (Camille):** d-pad moves Sonic, jump button works, in both ports. (If native cannot be made to work — probe shows `IsGameController` unfixable, or RSDK ignores a valid controller — record that and hand off to Task 4.)

**Verify:** device probe output shows `IsGameController=1` for the pad after the fix; Camille confirms movement + jump. (`make test` stays green — a db-line edit needs no new unit test, but re-run it.)

**Steps:**

- [ ] **Step 1: Build the probe** (scratchpad, not the repo). Cross-compile via the same Docker env as `make shim`:

```c
/* sdl-probe.c — enumerate joysticks/gamecontrollers as this SDL sees them */
#include <SDL2/SDL.h>
#include <stdio.h>
int main(void) {
    if (SDL_Init(SDL_INIT_JOYSTICK | SDL_INIT_GAMECONTROLLER) != 0) {
        printf("SDL_Init failed: %s\n", SDL_GetError()); return 1;
    }
    int n = SDL_NumJoysticks();
    printf("NumJoysticks=%d\n", n);
    for (int i = 0; i < n; i++) {
        char g[64];
        SDL_JoystickGetGUIDString(SDL_JoystickGetDeviceGUID(i), g, sizeof g);
        printf("js %d: name=%s guid=%s isGameController=%d\n",
               i, SDL_JoystickNameForIndex(i), g, SDL_IsGameController(i));
        if (SDL_IsGameController(i)) {
            const char *m = SDL_GameControllerMappingForGUID(SDL_JoystickGetDeviceGUID(i));
            printf("  mapping=%s\n", m ? m : "(none)");
        }
    }
    SDL_Quit();
    return 0;
}
```
```
docker run --rm --platform linux/arm64 -v "$PWD:/w" -w /w debian:bullseye sh -c \
  'apt-get update -qq && apt-get install -y -qq gcc libsdl2-dev >/dev/null && \
   gcc -O2 -o sdl-probe sdl-probe.c $(sdl2-config --cflags --libs)'
```

- [ ] **Step 2: Run it on device** against the pak's SDL2 + gamecontrollerdb. `scp sdl-probe root@10.0.1.16:/tmp/`, then over SSH (NextUI must not hold the codec — but joystick enumeration is fine over SSH):
```
LD_LIBRARY_PATH=/mnt/SDCARD/Emus/h700/PORTS.pak/lib:/mnt/SDCARD/.system/h700/lib \
SDL_GAMECONTROLLERCONFIG_FILE=/mnt/SDCARD/Emus/h700/PORTS.pak/... (the active gamecontrollerdb.txt) \
/tmp/sdl-probe
```
Record the GUID and `isGameController`.

- [ ] **Step 3: Diagnose + decide.**
  - **GUID printed ≠ `19000000010000000100000000010000`** → the db entry never matches this device. **Fix (native):** set the `RG SP Gamepad` entry GUID (line 8 of both `assets/gamecontrollerdb-h700-*.txt`) to the measured GUID, keep the button mapping. Go to Step 4.
  - **GUID matches but `isGameController=0`** → SDL rejects the entry (malformed field / bad axis). Inspect and correct the mapping fields, or if unrecoverable, hand to Task 4.
  - **`isGameController=1` in the probe already** → the pad *is* recognized by this SDL; RSDK's own init/precedence is the problem (it reads controllers before the mapping applies, or doesn't `SDL_INIT_GAMECONTROLLER`). Native is a dead end from the pak side → **record and unblock Task 4** (keyboard-synthesis).

- [ ] **Step 4 (native branch): apply + rebuild.** Edit both `assets/gamecontrollerdb-h700-*.txt` line 8. `make pak`. Confirm the corrected line lands in `dist/.../files/gamecontrollerdb_*.txt`. Re-run `make test`.

- [ ] **Step 5: Device-gate (Camille).** Refresh on device, launch both ports, confirm d-pad + jump. Capture the result.

- [ ] **Step 6: Commit** (native branch only) — `feat: F43 — native controller support for the RSDK Sonic ports (correct RG SP GUID)`. If Task 4 is taken instead, F43 commits there.

```json:metadata
{"files": ["assets/gamecontrollerdb-h700-xbox.txt", "assets/gamecontrollerdb-h700-nintendo.txt"], "verifyCommand": "make test", "acceptanceCriteria": ["on-device SDL probe prints the pad's real GUID + IsGameController + mapping; root cause recorded", "if GUID mismatch: RG SP entry GUID corrected in both db files, rebuilt into files/gamecontrollerdb_*.txt", "DEVICE: d-pad moves Sonic and jump works in both ports, OR native ruled out and Task 4 unblocked"], "modelTier": "frontier", "userGate": true, "tags": ["user-gate"], "requiresUserSpecification": false}
```

---

### Task 4: F43 — Controls, part 2 (fallback): keyboard-synthesis remap

**Goal:** ONLY IF Task 3 proves the native controller path unworkable — make controls work via the pak's BYTEPATH keyboard-synthesis pattern: add the Sonic launchers to the remap list and overlay a corrected `sonic.gptk` that maps the gamepad to RSDK's `[Keyboard 1]` scancodes, which `gt-input-remap.so` synthesizes as SDL key events. **If Task 3 lands native controls, close this task as "not needed."**

**USER-ORDERED GATE — NON-SKIPPABLE.** Ends in a device verification only Camille can perform. Close only after Camille confirms controls respond, output captured.

**Files:**
- Modify: `assets/gt-remap-ports.txt` (append two launcher filenames)
- Create: `assets/port-fixes/sonic1/sonic.gptk`, `assets/port-fixes/sonic2/sonic.gptk`
- Modify: `build/build-pak.sh` — stage the overlay files (model on the tunics_pm overlay `:1264-1266`)
- Create: `tests/test-19-sonic-remap.sh`

**Acceptance Criteria:**
- [ ] `assets/gt-remap-ports.txt` contains `Sonic 1.sh` and `Sonic 2.sh` (exact lines).
- [ ] A corrected `sonic.gptk` is overlaid into `sonic1`/`sonic2` at build (staged under `files/port-fixes/sonic{1,2}/sonic.gptk`), mapping gamepad → the `[Keyboard 1]` keys (Up/Down/Left/Right arrows; A→`z`(29), B→`x`(27), X→`a`(4), Y→`s`(22); Start→`enter`(40), Select/back→`tab`(43)). The exact gptk key-name vocabulary MUST match `assets/gt-input-remap.c`'s parser (read it first).
- [ ] `tests/test-19` asserts both launcher names in the remap list, both overlay `sonic.gptk` files staged, and the gptk maps to the correct keys.
- [ ] **Device gate (Camille):** d-pad + jump work in both ports.

**Verify:** `sh tests/test-19-sonic-remap.sh && make test` → green.

**Steps:**

- [ ] **Step 1: Read `assets/gt-input-remap.c`** to confirm the accepted `.gptk` key-name vocabulary and how it maps names → SDL scancodes (so the overlay gptk uses the exact tokens the shim parses).

- [ ] **Step 2: Write the failing test** `tests/test-19-sonic-remap.sh`:

```sh
#!/bin/sh
. "$(dirname -- "$0")/helpers.sh"
assert_contains "$ROOT/assets/gt-remap-ports.txt" '^Sonic 1.sh$'
assert_contains "$ROOT/assets/gt-remap-ports.txt" '^Sonic 2.sh$'
for p in sonic1 sonic2; do
  f="$ROOT/assets/port-fixes/$p/sonic.gptk"
  [ -f "$f" ] || { echo "missing overlay gptk: $f"; exit 1; }
  assert_contains "$f" 'z'   # A -> jump (scancode 29)
done
sh -n "$ROOT/build/build-pak.sh"
assert_contains "$ROOT/build/build-pak.sh" 'port-fixes/sonic1'
echo "test-19 ok"
```
(Note: `assert_contains` uses `grep` — `^Sonic 1.sh$` matches the whole line.)

- [ ] **Step 3: Append to `assets/gt-remap-ports.txt`:**
```
# v0.3.2: RSDK Sonic ports — native SDL_GameController unrecognized on h700
# (see F43); keyboard-synthesis via gt-input-remap + overlaid sonic.gptk.
Sonic 1.sh
Sonic 2.sh
```

- [ ] **Step 4: Write the overlay gptk** (`assets/port-fixes/sonic1/sonic.gptk`, identical for sonic2), using the vocabulary confirmed in Step 1. Target keys = `[Keyboard 1]`: Up/Down/Left/Right = arrows; A=z, B=x, C=c, X=a, Y=s, Z=d; Start=enter; Select=tab. Example (adjust names to the parser):
```
up = up
down = down
left = left
right = right
a = z
b = x
x = a
y = s
start = enter
back = tab
```

- [ ] **Step 5: Stage the overlay** in `build/build-pak.sh` (model on tunics_pm `:1264-1266`):
```sh
  for sp in sonic1 sonic2; do
    mkdir -p "$assembled/files/port-fixes/$sp"
    cp "$ASSETS/port-fixes/$sp/sonic.gptk" "$assembled/files/port-fixes/$sp/sonic.gptk"
  done
```

- [ ] **Step 6: Run test → pass**, `make test` green, `make pak` builds.

- [ ] **Step 7: Device-gate (Camille).** Refresh, launch both ports, confirm d-pad + jump.

- [ ] **Step 8: Commit** (`feat: F43 — controls for the RSDK Sonic ports (keyboard-synthesis remap)`).

```json:metadata
{"files": ["assets/gt-remap-ports.txt", "assets/port-fixes/sonic1/sonic.gptk", "assets/port-fixes/sonic2/sonic.gptk", "build/build-pak.sh", "tests/test-19-sonic-remap.sh"], "verifyCommand": "sh tests/test-19-sonic-remap.sh && make test", "acceptanceCriteria": ["Sonic 1.sh + Sonic 2.sh in gt-remap-ports.txt", "corrected sonic.gptk overlaid for both ports, maps gamepad -> [Keyboard 1] keys", "gptk vocabulary matches gt-input-remap.c parser", "build stages the overlay files", "DEVICE: d-pad + jump work in both ports"], "modelTier": "standard", "userGate": true, "tags": ["user-gate"]}
```

---

### Task 5: Bundle docs + tests + one 0.3.2 release ("Sonic 1 & 2 now work")

**Goal:** Fold F41/F42/F43 into the docs, expand the existing `### 0.3.2` changelog stub, verify the whole suite, and — with Camille's explicit approval — merge to main, tag `v0.3.2`, and publish the GitHub release covering F40–F43.

**USER-ORDERED GATE — NON-SKIPPABLE.** Merge/push/tag/release are irreversible outward actions. This task MUST NOT merge, push, tag, or publish without Camille's explicit, in-conversation approval at the moment of the action. A green suite is necessary but NOT sufficient.

**Files:**
- Modify: `docs/h700-fixes.md` (Fix IDs range `F1–F40`→`F1–F43`; full F41/F42 write-ups; F43 as its own `##` section like F39; expand `### 0.3.2`)
- Modify: `docs/superpowers/ideas.md` (delete any delivered Sonic items, if present — fold into a commit)
- Modify: memory `rgsp-sonic-rsdk-bringup.md` (mark shipped) — do this after the release lands.

**Acceptance Criteria:**
- [ ] `docs/h700-fixes.md` line 11 reads `Fix IDs (F1–F43)`.
- [ ] F41, F42 write-ups added; F43 has its own `##` section describing the confirmed root cause + the fix that actually landed (native GUID or keyboard-synthesis) + the device-verified date.
- [ ] `### 0.3.2` lists F40 + F41 + F42 + F43 one-liners under `**Fixes**`, with the `**Upgrading from 0.3.1:**` line.
- [ ] `make test` fully green; `make pak` builds clean; the built pak size is recorded.
- [ ] **Final device gate (Camille):** a real clean reinstall of BOTH ports → each boots, full-screen, sound, controls all work.
- [ ] **Release (Camille-approved):** branch merged to `main`, pushed; `v0.3.2` tagged + pushed; GitHub release published (`PORTS.pak.zip`), release notes in the terse `### Fixes`/`### Upgrading` style; CI build size == local.

**Verify:** `make test` green; `git log --oneline` shows F41/F42/F43 commits; the GitHub release shows `v0.3.2` Latest with the asset.

**Steps:**

- [ ] **Step 1: Docs.** Bump the Fix IDs range to `F1–F43`. Promote the F41 bullet to a full paragraph; add F42; write F43 as its own `## ` section (like F39) recording the probe's root cause + the landed fix. Expand `### 0.3.2`:
```markdown
### 0.3.2

**Fixes**
- F40: Sonic 1 & Sonic 2 (RSDK decompilation) now launch — shipped the missing `libsndfile` audio chain
- F41: Sonic 1 & 2 render full-screen on the RG SP (ScreenWidth fit for 720×480)
- F42: Sonic 1 & 2 audio now plays (force SDL audio-subsystem init)
- F43: Sonic 1 & 2 controls work (<native RG SP mapping | gamepad→keyboard remap>)

**Upgrading from 0.3.1:** unzip-over (self-healing); no manual steps.
```

- [ ] **Step 2: Delete delivered items** from `docs/superpowers/ideas.md` if the Sonic bring-up is listed there.

- [ ] **Step 3: Full suite.** `make test` (all green), `make pak` (network → sandbox disabled); record the built `PORTS.pak.zip` byte size.

- [ ] **Step 4: Final device gate (Camille).** Real clean reinstall of both ports; confirm boot + full-screen + sound + controls. Capture the observation. **Do not proceed to release on any failure.**

- [ ] **Step 5: Release — HARD GATE.** Only after Camille says go, in these words or clearly equivalent:
  - `git checkout main && git merge --no-ff fix/f40-libsndfile-sonic` (or fast-forward per the repo's convention), push `main`.
  - `git tag v0.3.2 && git push origin v0.3.2` → CI builds + publishes the release.
  - Verify the GitHub release: `v0.3.2` Latest, `PORTS.pak.zip` present, CI size == local size from Step 3.
  - Draft release notes in the terse pak style (`### Fixes` bullets: what, not why; `### Upgrading from v0.3.1`).

- [ ] **Step 6: Update memory** `rgsp-sonic-rsdk-bringup.md` → shipped (commit hashes, release, device-verified). Fold the ideas.md edit into the appropriate commit.

```json:metadata
{"files": ["docs/h700-fixes.md", "docs/superpowers/ideas.md"], "verifyCommand": "make test", "acceptanceCriteria": ["Fix IDs range now F1-F43", "F41/F42 write-ups + F43 section added with confirmed root cause and landed fix", "0.3.2 changelog lists F40-F43", "make test green + make pak clean, size recorded", "DEVICE: clean reinstall of both ports boots full-screen with sound + controls", "Camille-approved: merged to main, v0.3.2 tagged + pushed, GitHub release published, CI size == local"], "modelTier": "standard", "userGate": true, "tags": ["user-gate"]}
```

---

## Notes on execution

- **Only Camille can run every device gate** — subagents cannot press buttons on the handheld. Whoever coordinates (this session) runs the device commands over SSH and relays what Camille observes.
- **Scope discipline (last session's lesson):** if controls debugging balloons, stop at the Task 3 probe result and take the Task 4 fallback rather than open-ended native spelunking. Never leave Camille in a state where he can't quit a running game (keep a working `back=esc`/quit path at every device test).
- **Suggested order:** Task 1 (easy win) → Task 2 → Task 3 (→ Task 4 only if needed) → Task 5. Tasks 1–3 are independent; do them in whatever order the device session flows.
