# Sleep support for ports — watcher daemon + ALSA suspend-proxy (F47)

## Goal

Pressing the power button or closing the lid during a running port suspends the
device (real suspend-to-RAM, same as NextUI's emulators); pressing power wakes
it with the game, controls, screen, and **audio** all working. Scope is ports
only — the PortMaster GUI keeps its v0.2.0 no-sleep ruling.

## Grounding — device spike (RG SP, 2026-08-31)

All facts device-proven during live suspend rounds with a running port
(Balatro). This section is self-contained — do not re-derive on device.

- **Why ports don't sleep:** sleep on NextUI-h700 is a foreground-app feature.
  `nextui.elf`/`minarch.elf` watch the power key and lid themselves and run
  `$SYSTEM_PATH/bin/suspend`; `keymon.elf` handles volume/brightness/colortemp
  only. During a port, nextui is blocked waiting on the port, so nobody watches.
- **Triggers, all on `/dev/input/event0`** (`axp2202-pek`): `KEY_POWER` (116)
  press+release = power button; `KEY_INSERT` (110) = lid close; `KEY_DELETE`
  (111) = lid open. Lid events arrive as ~1s driver-generated autorepeat bursts
  (devicetree wires `hall_key` into the powerkey driver). There is **no EV_SW
  device**. Lid state sysfs: `/sys/class/power_supply/axp2202-battery/hallkey`
  (1 = open, 0 = closed).
- **Wake source is the power button ONLY.** Lid-open does not wake (platform
  behavior, same as NextUI everywhere). The stock suspend script already
  re-suspends if woken with the lid closed (pocket-wake guard).
- **The stock suspend script works mid-port.** `$SYSTEM_PATH/bin/suspend`
  (`SYSTEM_PATH=/mnt/SDCARD/.system/h700`) does: work_led/mcu_pwr, pre-sleep.d
  hooks, `alsactl store`, bluetoothd/wpa_supplicant stop, `os_sleep` Super
  Standby attr, `echo mem > /sys/power/state` (retry loop + false-negative
  guard), hallkey re-suspend loop, then `alsactl restore`, `syncsettings.elf`,
  wifi/BT restart (async). It MUST run with
  `LD_LIBRARY_PATH=/mnt/SDCARD/.system/h700/lib` (syncsettings needs
  libmsettings) as well as `SYSTEM_PATH`. Proven result: device suspends, wakes
  on power press, **screen restores automatically (kernel), game + controls +
  gptokeyb survive**. Suspend failure exits nonzero (NextUI escalates to
  poweroff in that case — we must NOT).
- **The audio wall:** the BSP kernel wedges any ALSA PCM open across a suspend
  — stream stays `state: RUNNING`, DMA dead (hw_ptr frozen), the app blocks in
  `snd_pcm_writei` forever; no `-ESTRPIPE` is ever delivered. Freezing the app
  and draining to XRUN before suspend does NOT help: on resume the app recovers
  textbook-correctly (EPIPE → prepare → fresh trigger) but the DMA consumes ~1
  period and re-wedges. **Only a full `snd_pcm_close` + `snd_pcm_open`
  re-initializes the DMA/codec path** — which is why minarch closes/reopens its
  audio device around suspend (documented in the suspend script's own
  comments).
- **Stock `/etc/asound.conf`:** `pcm.!default` = `type hooks` over
  `hw:audiocodec`, whose `ctl_elems` hook sets and **`lock true`s** five
  controls (LINEOUT Switch, SPK Switch, OutputL/R Mixer DACL/R Switch, digital
  volume). This explains the `alsactl restore` EPERMs (harmless, present in
  NextUI's own path too) — and it means a slave REOPEN re-fires those hooks,
  rewriting the output routing after resume for free. There is also
  `pcm.playback_hp` (same minus SPK) and `pcm.playback_hdmi`. Ports carry no
  ALSA env vars today. `/usr/share/alsa/alsa.conf` exists; external plugin
  modules load fine on this alsa-lib (bluealsa precedent in
  `/usr/lib/aarch64-linux-gnu/alsa-lib/`).
- NextUI hook dirs exist and are run by the suspend script:
  `/mnt/sdcard/.userdata/h700/.hooks/{pre-sleep.d,post-resume.d}` (unused by
  us; available extension point).
- ssh/debug trap: triggering the suspend script over ssh kills the session
  (wifi stops) — always fire it detached (`nohup ... &`) when testing remotely.

## Architecture

### Component 1 — `gt-sleepmon` (watcher daemon, pak `bin/`)

Small C program (source in `assets/`, built by the `make shim` container lanes
like the other pak binaries), started by `run_port` before the game launches
and killed in `run_port` cleanup.

- Opens `/dev/input/event0` read-only, non-grabbing (keymon reads it too;
  coexistence proven).
- Trigger = `KEY_POWER` value 0 (release — matches "power key release" minarch
  semantics) OR `KEY_INSERT` value 1 (lid close; ignore autorepeats value 2).
- On trigger (single-flight; ignore triggers while one is in progress):
  1. Freeze the port process tree: walk `/proc` for descendants of the
     `run_port` bash (PID handed to sleepmon via argv or env at spawn),
     SIGSTOP them (excluding itself).
  2. Run `$SYSTEM_PATH/bin/suspend` synchronously with `SYSTEM_PATH` and
     `LD_LIBRARY_PATH` set as above.
  3. On return (any exit code): SIGCONT the tree.
  4. Drain/ignore all event0 input for ~2s after resume — the waking power
     press arrives on event0 post-resume and would instantly re-suspend
     (minarch: "ignoring spurious power button press (just resumed)").
- Suspend failure (nonzero rv): log, CONT, keep playing. NEVER poweroff —
  ports have no autosave.
- Robustness: SIGCONT the tree from signal/atexit paths so no crash of
  sleepmon leaves a frozen game; if event0 can't be opened, log and exit
  (port unaffected).
- The pure trigger/debounce state machine is host-testable (compile with a
  test define, like `-DGT_REMAP_TEST` in gt-input-remap).

### Component 2 — `libasound_module_pcm_gt_suspend.so` (ALSA ioplug proxy)

External alsa-lib PCM plugin (ioplug API), built for **aarch64 and armhf**
(the armhf lane exists for AC/F45). Loaded from an absolute pak path via the
config's `pcm_type.<name>.lib` key — no writes to the system.

- Transparent proxy: opens the previous default chain (the stock `hooks`
  pcm over `hw:audiocodec`) as its slave; forwards transfers/params/state.
- Suspend detection: sample `CLOCK_BOOTTIME - CLOCK_MONOTONIC` on each
  transfer; a jump in the delta = a suspend happened while the handle was
  open.
- On detection: close the slave, reopen it (re-fires the ctl_elems hooks →
  output routing rewritten), replay hw/sw params, prepare, continue. Bounded
  retries with short backoff; if reopen ultimately fails, return errors to
  the app (no worse than today's silent wedge).
- The poll/wait path must never surface a dead slave as an error
  (device-proven during the gate, Pizza Tower round): a forwarded `POLLERR`
  becomes `-EIO` at `snd_pcm_wait`, which SDL2 treats as a permanent device
  disconnect — its audio thread then never writes again, defeating every
  later reopen. `poll_revents` reports "writable" for a
  missing/suspended/XRUN slave or a detected suspend, and the pointer
  callback returns a negative error for a non-live/post-suspend slave
  (never a fabricated ring position: the modulo-buffer pointer interface
  cannot distinguish empty from full, so a frozen full ring would read as
  zero progress and spin the writer — Celeste round), which flags the
  frontend XRUN and routes the app's standard recover→prepare into the
  reopen.
- Must behave sanely for capture opens and non-default devices (pass-through
  or decline gracefully) — playback via "default" is the target path.

### Component 3 — launch.sh glue (build-pak.sh injections)

- `run_port`: spawn `gt-sleepmon` (with the port bash PID) before launching
  the game; kill it in the existing cleanup path. Gate on a shipped-empty
  blocklist `files/gt-sleep-blocklist.txt` + user opt-out (mirror the
  gt-hud-blocklist pattern) — blocklisted ports get NO sleepmon and NO audio
  proxy routing.
- ALSA routing env for the port process: point `ALSA_CONFIG_PATH` at a
  pak-shipped, fully self-contained config (no `/usr/share/alsa/alsa.conf`
  include) that re-points `pcm.default` at the proxy wrapping the stock
  chain, with the plugin `lib` given as an absolute pak path. Device-proven
  during execution: alsa.conf's `@hooks` node loads `/etc/asound.conf` only
  *after* the entire `ALSA_CONFIG_PATH` file is parsed, so a layered
  "system config then ours" file cannot work on this alsa-lib — the stock
  `pcm.!default` always wins regardless of textual order. The config must
  therefore replicate everything alsa.conf would otherwise provide that the
  chain needs (e.g. a `ctl.hw` stanza for the `ctl_elems` hook).
- GUI path (`run_portmaster_gui`): untouched.

## Sequence

trigger → sleepmon freezes tree → stock suspend script (mixer store, wifi/BT
stop, suspend-to-RAM, hallkey pocket-wake loop, syncsettings + mixer restore +
wifi/BT restart on wake) → sleepmon CONTs tree → game's next audio write hits
the proxy → boottime-delta jump detected → slave reopen (hooks re-fire) →
audio continues. Screen restore is automatic (kernel); HUD values (battery,
time) are read live and self-correct.

## Build

- `make shim` gains the plugin + sleepmon compile steps in the existing
  bullseye containers (aarch64 + armhf lanes; alsa-lib dev headers
  (`libasound2-dev`) apt-installed in the build containers alongside the
  sibling `-dev` packages, same as `libsdl2-dev`/`libgles2-mesa-dev`/
  `libegl1-mesa-dev` — `pins.sh` only pins the runtime `.deb`s the pak ships,
  not build-container packages; the staged `file(1)` checks are the
  fail-closed net). Always `file`-check produced .so/binaries (docker
  tag-cache wrong-arch trap, F45).
- `build-pak.sh`: new marker-guarded injections for run_port (sleepmon spawn +
  kill + env routing), following the existing gt-h700-* anchor/injection
  pattern; ship `gt-sleep-blocklist.txt` + the pak asound conf fragment.

## Testing

- Host: sleepmon trigger/debounce state machine unit tests; proxy
  delta-detection logic unit tests (pure parts extracted, test define).
- Build wiring: new test suite asserting injection anchors fire, sleepmon +
  both plugin arch builds land in the zip, env/config lines present, blocklist
  respected (fixture-based via `GT_STAGE_EDIT_ONLY`, like tests 1–21).
- `make test` green from repo root.

## Device gate (USER-ORDERED, non-skippable)

Per engine class, from a normal launch: sleep via power button AND via lid
close; wake via power; verify game alive, controls work, **audio resumes**;
several repeat cycles in one session; volume keys still work after wake.

- Balatro (LÖVE/OpenAL — music)
- Deltarune or Pizza Tower (GameMaker/gmloadernext; Pizza Tower also gates the
  F30 FMOD_SDL interplay)
- Apotris (native SDL_Renderer under gptokeyb)
- Celeste (FNA/FAudio)
- Animal Crossing (armhf runtime; if its 2.0.12-era stack resists the proxy,
  document a per-port limitation — non-blocking)
- One no-audio/quiet port sanity pass (no regression from routing)
- Regression: HUD toggle (F34/F35), input remap ports (Tunics!, BYTEPATH),
  PortMaster GUI session unaffected.

## Risks / notes

- alsa-lib config override mechanics (env name, file ordering, `!default`
  override, bundled-libasound behavior) are the main execution-time unknowns —
  verify on-device early (cheap spike within Task 1 of the plan).
- ioplug vs mmap-preferring clients: ioplug exposes RW-style access; OpenAL/SDL
  fall back correctly (pulse-plugin precedent). Watch for a port that demands
  mmap.
- Suspend while patch/install scripts run: sleepmon starts with the game, so
  pre-game patcher phases are uncovered by design (same as today).
- Playtime accounting: suspend freezes wall-clock sessions the same way
  NextUI's own sleep does; NextUI hook dirs exist if this ever needs tuning.
  Out of scope.
- Deploy hygiene during gating: never overwrite a running sh in place
  (scp→temp+`mv`); fire the suspend script detached when testing over ssh.

## Out of scope

- PortMaster GUI sleep (v0.2.0 ruling stands, per Camille 2026-08-31).
- Idle auto-sleep timer (`suspendTimeout`) for ports.
- Poweroff escalation on failed suspend.
- Kernel/BSP fixes for the PCM suspend wedge.
