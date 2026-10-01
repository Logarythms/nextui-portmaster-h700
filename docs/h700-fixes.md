# h700 compatibility fixes

This document explains, fix by fix, what breaks when you run an unmodified
[ben16w/minui-portmaster](https://github.com/ben16w/minui-portmaster) PortMaster
pak on an Anbernic RG SP (Allwinner h700 SoC) under NextUI, why it breaks, and
what this repository's build script changes to fix it. The upstream pak targets
the tg5040 family of devices (TrimUI Brick/Smart Pro); the h700 family has a
thinner system image, a different SDL2 build, and a different GPU driver stack,
so several of its assumptions don't hold.

Fix IDs (up to F68) below match the internal numbering used while these were
found and verified on real hardware; they're kept here mainly so a diff or an
issue report can refer to a specific one. The numbering has gaps — some IDs are
reserved or live on other branches until release. A closing section records the ports
that this platform genuinely can't run.

## Missing shared libraries ("the h700 lib gap")

The pak ships prebuilt Python, bash, and native binaries built for the TrimUI
system image, which provides a shared-library directory
(`/usr/trimui/lib`) that fills in everything those binaries need beyond
libc. NextUI on h700 has no equivalent catch-all directory — its system SDL2
build is present, but several dependency libraries those binaries expect are
simply absent, or present in an incompatible version. Every case below was
diagnosed the same way: run the failing binary, read the loader's "shared
object not found" error (or trace its dependency graph with `readelf -d` /
`LD_TRACE_LOADED_OBJECTS`), and ship the missing library — pinned by exact
version and SHA-256, sourced from Debian bullseye (the distribution the
pak's own binaries were built against) — inside the pak's own `lib/`
directory so it never depends on what the host image happens to provide.

- **F1 — GUI crashes on launch: `libffi.so.7` missing.** The bundled
  Python interpreter's `_ctypes` module is linked against `libffi.so.7`.
  NextUI's h700 image only has the ABI-incompatible `libffi.so.8`. Fix:
  ship `libffi7` (bullseye 3.3-6) in the pak's lib directory.
- **F3 — GUI crashes loading fonts/text, and pysdl2 refuses to start.**
  Two related problems. First, NextUI's SDL2_ttf on h700 is older
  (2.0.13) than the minimum the bundled `pysdl2` binding requires
  (2.0.14), and there is no SDL2_mixer on the system at all — so the pak
  needs to ship a full SDL2_ttf stack (ttf, freetype, libpng16, brotli)
  itself. Second, and more subtly: pysdl2's vendored library loader
  (`dll.py`) only supports a *single* directory in `PYSDL2_DLL_PATH` — if
  you point it at more than one path (say, the pak's own lib dir *and*
  the system SDL2 dir) it silently fails to find libraries in whichever
  directory isn't checked first. Since the SD card is FAT-formatted
  (no symlinks), the fix ships the SDL2_ttf chain as real files
  alongside a copy of NextUI's *own* SDL2 core library, so
  `PYSDL2_DLL_PATH` can point at exactly one, self-sufficient directory
  on h700. That core-library copy is refreshed from the system at launch
  time (rather than pinned once), so the GUI always runs against the
  same SDL2 build the rest of NextUI uses instead of a possibly-stale
  bundled copy.
- **F5 — GUI theme fails to load images.** NextUI's SDL2_image build on
  h700 has no JPEG codec compiled in, and the GUI's theme assets include
  a `.jpg`. Fix: ship a full-featured SDL2_image plus its JPEG/TIFF/WebP/
  JBIG/deflate codec chain, pinned from bullseye.
- **F7 — every port launch fails at the shell level.** Port scripts run
  through the pak's own bundled, dynamically-linked bash 5.2.0, which
  needs `libncurses.so.5`. TrimUI supplies it; the h700 image doesn't.
  Fix: ship `libncurses5` and `libtinfo5`.
- **F9 — GL/GLES ports load but produce no sound.** Ports that render
  through gl4es commonly link against OpenAL for audio. Tracing the full
  dependency graph turned up a four-library chain that h700 doesn't
  provide at all: `libopenal` → `libsndio` → `libbsd` → `libmd`. Fix:
  ship all four, pinned from bullseye.
- **F10 — LÖVE-based ports (e.g. any `love2d` port) fail to start.**
  The bundled LÖVE 11.5 runtime's shared library links seven additional
  libraries beyond what its own runtime folder carries: `libvorbisfile`,
  `libtheoradec`, `libmpg123` (and transitively `libvorbis`), plus
  `libpixman-1`, `libfontconfig`, and `libuuid` — an audio/video decode
  chain, a font-rendering dependency, and a UUID library that just
  happen not to be part of any h700 system image. Fix: ship all seven,
  pinned from bullseye, the same way as the other lib-gap fixes above.
- **F20 — Solarus-engine ports (e.g. Tunics!) fail to start: `libogg`
  missing.** The one library the F9/F10 rounds didn't catch: `libogg` is
  the container layer *underneath* the vorbis stack, and the Solarus
  engine links it directly. A full dependency-closure walk of the
  solarus binary on-device showed it as the single unresolvable soname —
  the F10 vorbis libraries reference it too, but LÖVE never faulted
  because its runtime folder bundles its own copy. Fix: ship `libogg0`,
  pinned from bullseye.
- **F40 — the RSDK Sonic ports (Sonic 1, Sonic 2) exit instantly:
  `libsndfile.so.1` missing.** Both ports are from the same
  [Rubberduckycooly](https://github.com/Rubberduckycooly) RSDK decompilation
  project (`sonic2013`/`sonicforever`/`sonic2absolute`) and link
  `libsndfile.so.1` for audio decode, which no h700 image, port folder, or
  earlier pak round provides — so the dynamic loader aborts before `main()`
  and the game exits the moment it launches (device log: `error while loading
  shared libraries: libsndfile.so.1`). `libsndfile`'s dependency closure adds
  two more sonames the pak didn't yet carry — `libvorbisenc.so.2` (from
  `libvorbisenc2`, the same 1.3.7-1 source as the F10 vorbis libraries) and
  `libopus.so.0` — while `libFLAC`, `libvorbis` and `libogg` were already
  shipped by F9/F10/F20. Fix: ship all three, pinned from bullseye. Because
  the pak's `lib/` is on every port's `LD_LIBRARY_PATH`, this fixes both Sonic
  ports at once with no per-port change; confirmed on-device by tracing all
  four Sonic binaries (every soname resolves).
- **F41 — the RSDK Sonic ports render as a narrow vertical strip.** The port
  launcher hardcodes `ScreenWidth` `LOW=214` (0.89:1) for a 3:2 display; on the
  h700 720×480 that leaves huge side bars. `run_port` rewrites `LOW=214` to the
  filling value `240×W/H` (360 on the RG SP's 720×480; panel size from the F51
  device profile), mtime-neutrally inside the F32 window.
- **F58 — Doom Engines and Luanti exit at load: `libgomp.so.1`,
  `libgthread-2.0.so.0`, `libgmp.so.10` missing.** Reported in issue #1 and
  re-traced on the RG SP against the *current* port builds with
  `LD_TRACE_LOADED_OBJECTS`: Crispy Doom/Heretic/Hexen need OpenMP's
  `libgomp.so.1` and — through their bundled fluidsynth — glib's
  `libgthread-2.0.so.0` (glib itself is on the system image in
  `/lib/aarch64-linux-gnu`; only the gthread sublibrary is absent); GZDoom
  4.11/4.14 need `libgomp.so.1`; Luanti's `bin/luanti` needs `libgmp.so.10`
  and nothing else — the `libcurl.so.4` error in the report came from a stale
  Minetest build carried over from another CFW. Fix: ship the three sonames
  (only gthread out of `libglib2.0-0`), pinned from bullseye with the F10
  extracted-hash rule.
- **F63 — Doom Engines exits straight back to the menu: `libxcb-shm.so.0`,
  `libxcb-render.so.0`, `libXrender.so.1`, `libXext.so.6` missing.** Found in
  the v0.5.0 device gate (RG SP, NextUI rc10): the port's front-end menu is a
  LÖVE app whose bundled `libs/lovelibs/libcairo.so.2` is built with cairo's X
  backends, and the port does not ship their libraries (other CFWs have them
  in the system image). `love` failed at load, so no game was ever picked and
  the launcher exited. Fix: ship the four sonames from bullseye with the F10
  extracted-hash rule; the rest of the chain (`libxcb`, `libX11`, `libXau`,
  `libXdmcp`) was already in the pak's `lib/`.
- **F64 — Luanti shows `<invalid UTF-8 string>` for every label: glibc's
  UTF-16/UTF-32 conversion modules missing.** Found in the v0.5.0 device gate
  once F58 let Luanti start: NextUI-h700 ships no glibc `gconv` modules at all,
  and Luanti converts every UI string from UTF-8 to UTF-32LE through `iconv`,
  so each conversion failed. Fix: ship `UTF-16.so` and `UTF-32.so` from the
  Ubuntu 22.04 `libc6` build whose `libc.so.6` is byte-identical to the
  device's, with a trimmed `gconv-modules`, under `lib/gconv/`; `run_port`
  exports `GCONV_PATH` there — only on h700, only when the port has not set its
  own, the firmware still has no gconv of its own, and the system glibc is still
  that exact build (a firmware glibc update falls back to today's behaviour).
- **F67 — Sonic 3 AIR and Doom 3 exit at load: `libcurl.so.4` missing.**
  Reported in issue #2 (Sonic 3 AIR). Both ports link libcurl and bundle none,
  expecting the firmware to provide it; NextUI-h700 has none. Fix: ship a slim
  HTTP/HTTPS-only libcurl built from a pinned curl release against the
  device's own OpenSSL 3 and zlib — see
  [its section below](#ports-that-link-libcurl-a-slim-libcurl-built-for-rc11-f67).

## Roms launcher trigger file (F2)

NextUI shows the PortMaster GUI entry in its Ports list only when a
specific placeholder file exists in the Roms directory. Reproducing that
file as an empty, zero-byte placeholder is not enough — NextUI's own
canonical trigger is a small (102-byte) comment-only shell script, and
the entry silently fails to appear without that exact content. Fix: write
the real comment-only file instead of an empty one.

## Controller mapping (F4)

*Superseded on NextUI rc11 by [F65](#nextui-rc11-one-fixed-pad-layout-on-every-h700-model-f65): the rc10 button numbering described here no longer applies.*

SDL ships a large database of known controller GUID → button-layout
mappings. The RG SP's gamepad reports a generic HID GUID that collides
with SDL's built-in "ODROID Go 2" entry, which maps the physical B button
to what games see as L1 — usable for menus by accident, unusable for
actual gameplay. Fix: measure the pad's real button indices on-device
(never trust a generic USB/HID enumeration tool for this — the indices
you get from an `evtest`-style probe do not necessarily match what the
game's SDL build reports at runtime) and append a corrected entry, keyed
on the pad's exact GUID, to both the "Xbox-style" and "Nintendo-style"
controller database files the pak ships. SDL applies mapping-database
entries in file order and a later entry for the same GUID overrides an
earlier one, so appending is sufficient — no upstream entry needs to be
deleted.

## CPU frequency ceiling

The upstream pak boosts the CPU to a fixed high frequency while a port is
running and restores the saved value on exit. The fixed value it uses
(1.8 GHz) is outside the h700 SoC's supported range (this chip tops out
at 1.512 GHz); writing an out-of-range value to the frequency-scaling
sysfs node is rejected by the kernel, silently leaving the CPU at
whatever frequency it happened to be at. Fix: clamp the boost range to
1.2 GHz–1.512 GHz on h700 specifically, while leaving the original
values in place for the tg5040 branch of the same code path.

## Static scenes don't reach the screen (F6)

The GUI only repaints (calls its present/swap function) when something
on screen changes — a reasonable optimization on most SDL backends. On
h700's fbdev-based Mali GPU driver, however, a single present call does
not reliably make it all the way to the visible framebuffer: reading the
framebuffer back after a "static" dialog was shown could show a
completely blank page, even though the draw call had clearly happened.
Fix: force the GUI to redraw continuously on h700 (capped by its
existing frame-rate limiter, so this costs no more CPU than the game
loop already budgets for), which papers over the present-path
unreliability by simply presenting the same frame again a moment later.
This same underlying present-path issue turned out to be the root cause
of two other symptoms described further down.

## LÖVE must request GLES, not desktop GL (F10b)

The h700 Mali GPU driver's fbdev EGL layer aborts outright (an assertion
failure inside its own window-system code) when a client first requests
a desktop-GL context and only falls back to GLES after that context
fails to initialize — which is exactly the sequence the LÖVE runtime
uses by default. Fix: set the environment variable that tells LÖVE to
request a GLES context directly, skipping the failing desktop-GL attempt
entirely. This also has to be set during the runtime's own first-run
setup screens (display/font/performance questions), since those run
through the same LÖVE binary before the actual game loads.

## Mount hygiene — a bug that could delete an installed game (F11)

Each port launch bind-mounts the ports folder into a temporary working
location, and the wrapper script checks whether that mount already
exists before mounting again — by grepping the system mount table for
the expected path. On h700, the underlying path is presented to the
running mount table in all-lowercase, while the variable the wrapper
checks against holds a mixed-case alias for the same location. The
string comparison never matches, so *every single launch* added another
stacked bind-mount on top of the last one, and mounts left over from a
non-clean exit were never cleaned up either. With enough stacked mounts,
an install (or even just gameplay progress) could land in a
now-detached upper layer that evaporates the moment any one of the
stacked mounts gets unwound — which is exactly what happened during
testing, twice, to an installed game. Fix: before mounting, unmount
every stale layer in a loop, matching case-insensitively so the
comparison actually works, then mount exactly once.

## Ports re-patch themselves on every launch, then after every GUI session (F12/F13/F32)

Several ports (again, LÖVE-based ones in particular) only re-run their
one-time setup/patch step when their launcher script's on-disk
modification time is newer than some reference. Two bugs in the wrapper
script defeated this cache on every platform, h700 included, by
refreshing that modification time on every launch regardless of whether
anything actually changed:

- the step that copies each port's launcher script used a plain copy
  that does not preserve file timestamps, so the copy always looked
  "just modified";
- a separate step that rewrites the launcher's shebang line ran an
  unconditional in-place edit even when the shebang was already correct,
  which also bumps the modification time.

Fix: preserve timestamps on the copy, and skip the shebang rewrite when
it's already a no-op. Two consecutive launches of the same port then
correctly skip the expensive setup step the second time.

That closed the *per-launch* loop but not a slower one that surfaced
later (F32, Balatro hardware-diagnosed 2026-08-24). Whenever the
PortMaster GUI is opened, the wrapper's post-GUI cleanup re-publishes
every port launcher from its pristine install copy — reverting both the
shebang and the `/roms/ports/PortMaster` path rewrite that the wrapper
applies at launch time. So the *next* launch of a port re-applies those
two edits, and either one bumps the launcher's modification time to
"now". LÖVE-patch ports whose rebuild check lists the launcher itself as
a source (Balatro and UFO 50 both do) then see a launcher newer than the
built game and do a full, minutes-long rebuild — after every GUI
session, even though nothing about the game changed. The F12/F13 shebang
guard didn't help here: the reverted launcher's shebang is genuinely
wrong again, and the path rewrite never had a guard at all.

Fix (F32): the launch step that patches a port's launcher now snapshots
the launcher's modification time before its in-place edits and restores
it afterward. The launcher's content still gets patched; its timestamp
stays pinned to the pristine install copy, which is always older than an
already-built game — so a no-op re-patch no longer triggers a rebuild. A
genuine port update still bumps the install copy's timestamp (carried
through by the timestamp-preserving copy), so real updates still rebuild
correctly. This is deliberately unconditional (not h700-only): a no-op
timestamp bump is wrong on every platform.

## Ports are slow to start for reasons the launch script controls (F33)

Two "starting…" screens show before a port runs — first *"Starting,
please wait…"*, then *"Starting `<port>`…"* — and both are drawn by this
pak's own `launch.sh`, not by NextUI. Some of the wait between them is
inherent (a big LÖVE/GameMaker port loads hundreds of MB of assets on
slow storage, and there's nothing a launch script can do about that),
but an on-device trace found two chunks that are pure launch-script
overhead:

- **A 3-second splash that does no work.** The *"Starting `<port>`…"*
  screen is a `minui-presenter` call with a fixed 3-second timeout, run
  in the *foreground* — so every single port launch simply sleeps on it
  for three seconds before the game is exec'd. Fix (`gt-h700-fast-splash`):
  drop the timeout to 1 second. The call is deliberately kept and kept
  foreground, because it does one necessary thing besides showing a
  message: it tears down the earlier *"please wait"* presenter, so that
  no presenter is still alive when the port takes over the framebuffer
  (a live presenter overlapping the port's fbdev grab is the F14/F15
  present-path desync). Backgrounding or removing the call would bring
  that back; only the duration changes. The game's own loading screen
  simply appears about two seconds sooner.

- **Re-patching the Python runtime on every launch.** `patch_pylibs`
  unpacks the bundled `pylibs.zip` once (the archive is deleted on
  success) and then applies a few edits to PortMaster's `platform.py` /
  `harbour.py` — two of them by spawning `python3` to neutralize an
  installer function. Those edits are idempotent, but they were re-run on
  *every* launch, and the two `python3` cold-starts cost roughly half a
  second doing nothing (the log even says *"may already be disabled"*
  twice). Fix (`gt-h700-skip-redundant-patch`): guard the patch block so
  it runs only when `pylibs.zip` was just (re)extracted this launch, or
  when a `.gt-patched` marker is missing. The design stays self-healing:
  the marker is written only *after* the patches, so an interrupted patch
  re-runs next launch; and a pak upgrade (installed by unzipping over the
  old one) ships a fresh `pylibs.zip`, which forces the patches to re-run
  against the new, unpatched files.

Neither change touches the genuinely necessary work, so a first launch
(or the first launch after an upgrade) behaves exactly as before; it's
the steady-state repeat launches that get faster.

## GUI freezes into "repaints only on keypress" (F14/F15/F16)

This was the most involved fix, and it turned out to explain two
separate-looking symptoms as one root cause.

**Symptom:** partway through a GUI run — reliably, a fixed number of
seconds after the menu first appears — the screen would stop updating on
its own. The GUI process was still alive and still drawing at its normal
frame rate, but the screen only actually updated the moment you pressed
a button, one rectangle at a time (each keypress visibly "painted in"
only the part of the screen it affected).

**Root cause:** the GUI framework briefly shows a splash/progress overlay
(rendered by a separate helper process, "the presenter") both when a
port is *installed* and, it turns out, redundantly again for about ten
seconds right at GUI startup — overlapping with the main GUI process's
own graphics initialization. On h700's Mali fbdev driver, having two
processes with a live graphics context overlapping like that corrupts
the driver's damage-tracking: from that point on, only the screen
rectangles the driver *believes* changed get pushed to the panel, which
is exactly the "repaints only where I clicked" symptom. This is also
retroactively the explanation for the earlier "static scenes don't
reach the screen" issue — same underlying present-path corruption, just
a milder case of it.

A second, related bug meant the presenter helper process was
essentially unkillable from inside the pak: the pak's own bundled
`busybox` provides a `killall` that shadows the system's version (via
`PATH`), and that bundled `killall` simply never matched the presenter
process by name, so every attempted kill silently no-op'd. That let the
startup splash's presenter process survive for the entire GUI run *and*
past the point where the pak itself exited — leaving an orphaned process
holding a live graphics context, which was the root cause of a second
symptom: the device refusing to go to sleep a second time while the GUI
had been open (the first sleep would work, using power controls the
leaked process happened to still provide; the second attempt found
those controls gone from under it).

**Fixes:**

- replace every in-pak process-kill call with a small helper that reads
  process names directly from `/proc` and sends the kill itself
  (bypassing the shadowed, broken `killall` entirely), and wait for the
  process to actually exit before continuing;
- skip the redundant startup splash entirely on h700, and unconditionally
  kill and wait for *any* leftover presenter process before the main GUI
  starts drawing, so no two processes ever hold a graphics context at
  the same time;
- a third bug surfaced while testing the fix above: the "applying
  changes" message shown after closing the GUI was started as a
  background job *inside* code that itself already runs as a background
  job, so the new cleanup-and-kill logic could scan for presenter
  processes before the doubly-backgrounded one had even started —
  letting it slip through and outlive the pak run in the exact same
  way. Fixed by removing the redundant extra backgrounding and making
  sure the process is spawned before any cleanup step that might look
  for it.

With all three fixes in place, extended hands-off runs plus deliberate
navigation produced zero recurrences of the repaint freeze, and process
listings confirmed no orphaned presenter process survives either a
normal launch or an exit.

## Port and patcher logs were always silently empty (F17)

Every modern PortMaster port script — and every port patcher — sets up its
logging the same way: `exec > >(tee "$GAMEDIR/log.txt") 2>&1`. That bash
process-substitution idiom opens a path of the form `/dev/fd/N`, and
BaseOS/NextUI's device tree simply doesn't provide the standard POSIX
`/dev/fd` family (`/dev/fd → /proc/self/fd`, plus `/dev/stdin`,
`/dev/stdout`, `/dev/stderr`). The `exec` redirection fails, the script
carries on with its previous stdout, and every `log.txt` and
`patchlog.txt` on the card stays zero bytes forever.

That sounds cosmetic; it isn't. It means every downstream failure is
invisible — the F18 data-loss bug below shipped a broken result while
*appearing* to have patched successfully for twenty-four minutes,
precisely because its log had nowhere to go. Fix: `launch.sh` (re)creates
the four symlinks at every launch (`devtmpfs` is per-boot, and the links
are `[ -e ]`-guarded so this is a no-op on TrimUI, which has them).

## The Deltarune patcher silently destroyed game data (F18)

Modern port patchscripts (the official Deltarune port, the RHH GameMaker
ports) call `"$controlfolder/7zzs.$DEVICE_ARCH"` for archive surgery —
in Deltarune's case, to inject each chapter's patched `game.droid` into a
copy of the port's skeleton APK. The upstream pak ships `7zzs.aarch64`
only inside `files/bin.tar.gz` (unpacked to `bin/` at first boot), so the
control-folder path doesn't exist and the injection step fails — but the
patchscript's surrounding steps don't check that failure: the bare
skeleton copy ships anyway, and the patcher's cleanup then **deletes the
user's original `data.win` files**. Observed live on hardware: a
24-minute "successful" patch left six byte-identical empty APKs, and the
game data was gone (with F17 masking the whole thing). Fix: the build
stages the same pinned `7zzs.aarch64` into `PortMaster/` fail-closed, so
the patcher's expected path exists. (Since 0.4.0 the upstream control
folder ships its own `7zzs.aarch64` too; the staged copy keeps the path
guaranteed regardless of upstream packaging.)

## `pm_platform_helper: command not found` (F19)

2026-era port scripts call `pm_platform_helper` unguarded; the runtime
version this pak pinned through 0.3.2 (PortMaster 2025.03) predated it. In
current upstream PortMaster the function is an effective no-op (a
dialog-pipe close plus `printf ""`), so the fix appends a faithful stub to
the pak's `control.txt` — which `launch.sh` re-installs into the live
control folder at every launch, making the stub self-healing as well.
Since 0.4.0 the pinned base (PortMaster 2026.07.28) defines the function in
`funcs.txt` itself; the stub is kept as belt-and-braces (it is sourced
after `funcs.txt`, with identical behavior).

## Ports that reset `LD_LIBRARY_PATH` lost every pak-shipped library (F21)

All the "lib gap" fixes above ship libraries in the pak's own `lib/`
directory — but many port scripts hard-reset `LD_LIBRARY_PATH` to their
own value (`"$GAMEDIR/libs:$runtime_dir:..."`), which threw the pak's
directory away again. Tunics! faulted on `libopenal.so.1` while the pak
carried that exact file. The existing launch-time injection (which
already re-appends the system lib dir to such scripts) now appends the
pak's `lib/` as well — last in the search order, so port-bundled and
system libraries keep priority.

## The GUI's self-update must never run here (F22)

This pak is a *pinned repackage*: its GUI, python libraries, and control
files carry h700-specific patches applied at build and launch time. The
GUI's periodic "There is a new version of PortMaster" prompt is therefore
a foot-gun with no working "yes" path — accepting it overwrites the
patched runtime with upstream files. Observed live: an accidental accept
half-extracted the new runtime, died on a Text-file-busy binary
mid-archive, and left a 2025.03/2026 chimera control folder. Fix, in
three coordinated parts: `launch.sh` exports `GT_DISABLE_PM_UPDATE=1`;
the GUI's update check early-returns on that env (the prompt never
appears); and the updater function itself (`_install_portmaster`) is
no-op'd at launch time through the same mechanism the pak already uses
to disable upstream's `portmaster_install` — so even a manually
triggered update cannot write over the pak. Runtime *data* updates
(ports lists, runtime images) are unaffected.

## Oversized runtime images vs the RAM-backed /tmp (F23)

After the GUI exits, the pak post-processes downloaded runtime squashfs
images (rewriting `#!/bin/bash` shebangs and PortMaster paths inside
them). That extraction happens under `/tmp` — a small RAM tmpfs on this
1GB device — and a large image (the 120MB `gmtoolkit.squashfs`) fills it
mid-extract ("No space left on device"). Worse, a failed image never
receives its `.processed` marker, so the doomed extract re-ran on every
GUI exit. Extracting to the SD card instead is not an option: the card
is vfat, which cannot represent the symlinks and exec bits a rebuilt
squashfs must preserve. Fix: skip images whose conservative size
estimate (4× the compressed file) exceeds free `/tmp` space, with an
honest log line. Ports that need tools out of an oversized runtime are
handled case-by-case — see F24.

## RHH GameMaker ports: gmtoolkit and the gmloadernext runtime (F24)

[RHH-Ports](https://github.com/JeodC/RHH-Ports) GameMaker ports (UFO 50,
Undertale Yellow, …) have two requirements beyond official PortMaster
ports:

1. **A prebuilt `gmtoolkit` binary** at
   `"$controlfolder/gmtoolkit.$DEVICE_ARCH"` — in RHH's design a
   user-installed extra from
   [JeodC/gmtoolkit](https://github.com/JeodC/gmtoolkit/releases). The
   build now ships it (pinned, license alongside; note the upstream
   release tag is a rolling `latest`, so the pin fails closed and must
   be refreshed deliberately if upstream rolls it). The binary is
   byte-identical to the one the official Deltarune port bundles, which
   already proved itself against this device's glibc (2.35, device-verified
   2026-08-26; an earlier version of this note said 2.30, now stale).
2. **The `gmloadernext.squashfs` runtime**, which is *not* an official
   PortMaster runtime — it lives in RHH's own
   [`runtimes-latest`](https://github.com/JeodC/RHH-Ports/releases/tag/runtimes-latest)
   release, so the pinned harbourmaster's `runtime_check` reports
   "Unknown runtime" and cannot fetch it. Until the pin is bumped to a
   runtime that knows RHH sources, download it manually and place it at
   `PortMaster/libs/gmloadernext.squashfs` inside the installed pak.

## Keyboard-driven ports: SDL-layer key synthesis (F26)

*Superseded on NextUI rc11 by [F65](#nextui-rc11-one-fixed-pad-layout-on-every-h700-model-f65): the rc10 button numbering described here no longer applies.*

The largest class of dead ports on this platform was the
gamepad-to-keyboard tier: games written for a keyboard, which supported
PortMaster devices serve through gptokeyb's virtual uinput keyboard —
a device NextUI's SDL never delivers to games (F8). Tunics! made the
failure vivid: with every other layer fixed it booted to its title
screen and asked for SPACE, unreachable from a gamepad.

The fix extends the input-remap shim (F25's per-port `LD_PRELOAD`) to do
gptokeyb's job at the SDL layer, inside the game process. The launcher
hands the shim the port's own `.gptk` mapping file via `GT_REMAP_GPTK` —
the same file gptokeyb would have used, so each port keeps the exact
key layout its author designed. Joystick button events whose
(index-corrected) button carries a mapping are replaced in the event
stream by the corresponding `SDL_KEYDOWN`/`SDL_KEYUP`; hat motions become
the mapped arrow keys, edge-tracked with releases emitted before presses
(a diagonal flip can produce up to four key events — the extras are
served from a small internal stash on subsequent polls). Unmapped
buttons keep their corrected joystick events, so hybrid ports lose
nothing, and gptokeyb itself stays running untouched — its synthetic
keyboard is inert here, but its Select+Start kill hotkey reads the pad
directly and remains the quit path.

The decisive subtlety, found on hardware when the first synthesis build
still produced a dead title screen: SDL only delivers joystick events to
processes that have *opened* a joystick — and a keyboard-only game has
no reason to ever open one. Solarus's event pump ran straight through
the shim's interposers, yet not a single joystick event arrived to
translate. So when synthesis is active, the shim opens every joystick
itself (lazily, on the first event poll after SDL is up, initializing
the joystick subsystem if the game never did; opens are refcounted, so
games that open their own pad are unaffected). With that in place the
whole chain lit up: `opened 1/1 joystick(s)` → button events → key
events → Tunics! playable, hardware-verified 2026-08-23.

Deliberate limits: only the simple `name = key` subset of the gptk
format is honored (letters, digits, space/esc/tab/enter/backspace,
modifiers, arrows) — hold-state layers, mouse emulation, and analog
handling are ignored (the RG SP has no sticks). This half covers
event-consuming games; games that instead *poll* `SDL_GetKeyboardState`
are handled by the state-polling half added in F31. Since F54 this synthesis
is the fallback only: when the port's own gptokeyb is running, the shim hands
its uinput device to SDL instead (see F54 at the end of this file).

## Broken binaries inside a port: the port-fixes overlay (F27)

Some ports bundle their own native libraries, and one of them can be
broken for this device even when everything the pak provides is healthy.
First confirmed case: the Tunics! port (`tunics_pm`) ships a
`libmodplug.so.1` (tracker-music decoder) that dies on an illegal
instruction (`udf #0`) the moment a map transition changes the music —
caught red-handed with gdb attached on-device, and fixed live by
swapping in Debian bullseye's build of the same library.

The pak therefore carries a small overlay: replacement files live under
`files/port-fixes/<port-dir-name>/`, mirroring the port's own layout,
and `run_port` copies them over the installed port just before it
launches. Re-applied at every launch, so reinstalling the port
self-heals; `cmp`-guarded, so an unchanged file is never rewritten
(a fresh mtime would retrigger rebuild-if-newer ports — the F12
lesson). This is a mitigation, not a cure: the real fix belongs in the
port itself, and reporting it to the port's packager is on the
follow-up list.

## LuaJIT's aarch64 JIT miscompiles solarus quests (F28)

With input (F25/F26) and the music decoder (F27) fixed, Tunics! still
segfaulted on its first map transition — but only on the GL renderer,
which briefly pointed suspicion at the Mali driver. A second gdb-attach
told the real story: the crash was a jump into unmapped memory from
`libluajit-5.1.so.2` with a corrupt stack — the signature of a JIT
miscompile, not a GPU bug. The solarus runtime bundles LuaJIT
2.1.0-beta3, whose aarch64 JIT has known codegen defects; the earlier
"software rendering fixed it" observation was a red herring (different
timing compiled different traces and merely dodged the bad one).

Fix: run solarus quests with the JIT off. The engine's `-s` option runs
a pre-script before the quest's `main.lua`; the pak ships a one-liner
(`if jit then jit.off() end`) and `run_port` injects
`-s=<pak>/files/solarus-nojit.lua` into any port script that defines a
solarus runtime. LuaJIT's interpreter is stable and fast enough —
solarus does its heavy lifting in C++, and the result was play-verified
at normal speed on hardware (rooms, transitions, music). The real fix
belongs upstream in the solarus runtime image (a current LuaJIT 2.1
rolling release, or plain Lua); reporting it is on the follow-up list.

## An empty ports store that no update button fixes (F29)

A day after v0.2.0 shipped, the store GUI on the reference device showed
zero entries under All, Ready-to-run, and Featured; Featured claimed an
internet connection was required despite working WiFi, and Settings →
Update ports list changed nothing. The launch log told the story: every
featured port was rejected with `unknown port <name>.zip` — the featured
*collections* file had downloaded fine, but the main port database it
references was empty.

harbourmaster builds that database from two `*.source.json` files in
`PortMaster/config/` and recreates them in exactly two situations:
first-run, or a config-version migration. The 2026 self-updater's
migration (the one the F22 incident ran half of) deletes the old source
files as one of its steps; a config dir that keeps `config.json`
(`first-run: false, version: 2`) but loses the source files is therefore
stuck forever — no code path ever writes them again. The misleading part
is that featured collections, porter lists, and `ports_info.json` all
fetch through separate paths, so the GUI looks "partly online" and blames
the network instead.

Fix: the pak ships pinned copies of harbourmaster's two source defaults
(`files/gt-source-defaults/`), and `run_portmaster_gui` restores them
whenever `config.json` exists but no `*.source.json` does. The shipped
defaults carry `last_checked: null` and empty data, so harbourmaster
refetches the full database on the next load. The heal is deliberately
conservative: any surviving source file skips it (a user-modified source
set is intent, not damage), and a missing `config.json` skips it too
(fresh installs take harbourmaster's own first-run path).

Diagnostic note for future spelunking: the pak session log
(`.userdata/h700/logs/PORTS.txt`) is truncated per launch — evidence
from a failed attempt is gone by the time the next launch starts.

## Silent FMOD ports: the single-client audio codec (F30)

Pizza Tower ran fine on the reference device but was completely silent —
while every other port, and the store GUI itself, had working sound. The
same port has audio on an RG DS (ROCKNIX), where PortMaster is officially
supported, which pointed at a device difference rather than a port bug.

The h700 kernel is built without System V IPC, so ALSA cannot construct a
`dmix` (software-mixing) device: the audio codec is single-client — exactly
one process may hold `hw:audiocodec` at a time. A GameMaker port that ships
FMOD opens the codec twice: first the gmloadernext runner's own
GameMaker-native audio device (a plain playback open at ~22 kHz), then
FMOD's `FMOD_SDL` output plugin (48 kHz, requesting
`SDL_AUDIO_ALLOW_FORMAT_CHANGE`). The runner wins the race and holds the
device, so FMOD_SDL's open fails with `Device or resource busy` and FMOD —
where the game routes all of its sound — ends up with no output. The RG DS
escapes this because ROCKNIX runs PulseAudio, which is shareable. The
failure is FMOD-wide on this device, not specific to Pizza Tower.

Fix: a small `LD_PRELOAD` shim (`gt-fmod-audio.so`, built from
`assets/gt-fmod-audio.c`) that interposes `SDL_OpenAudioDevice` and
suppresses the runner's own open — returning failure so the runner proceeds
without native audio — which leaves the single codec free for FMOD_SDL to
grab. FMOD_SDL is told apart by the `ALLOW_FORMAT_CHANGE` flag it always
sets and the runner never does; capture opens are never touched. `run_port`
preloads it automatically for any port that carries `libs/libfmod*.so*`
(only gmloadernext FMOD ports do), so there is no per-port list and
non-FMOD ports are untouched. `GT_FMOD_AUDIO_DEBUG=1` traces each decision
to the pak log. Hardware-verified on the RG SP (Pizza Tower, sound in-game,
2026-08-24).

Trade-off: the runner's own GameMaker-native audio is lost. FMOD-shipping
ports route all sound through FMOD, so in practice nothing is; a port that
mixed runner-native and FMOD audio would lose the runner-native half. The
real fix belongs upstream — a shareable audio path (a userspace mixer, or
FMOD_SDL learning to share the device) — and is on the follow-up list.

## Polling ports: keeping `SDL_GetKeyboardState` in sync (F31)

F26 synthesizes SDL key *events* from the gamepad, which serves every port
that reads input by consuming events. But some games never read the event
stream for gameplay — they *poll* the current key state each frame through
`SDL_GetKeyboardState` (LÖVE exposes exactly this as `love.keyboard.isDown`).
Those synthesized events never touch SDL's internal keyboard-state array, so
polling saw nothing. BYTEPATH, a user-reported case, made it vivid: its menus
(event-driven) navigated fine while gameplay (its run loop polls) was dead.

The shim now keeps a synthetic keyboard-state array beside the event
synthesis — every key it presses or releases for the game is mirrored into
that array — and interposes `SDL_GetKeyboardState` to return `real | synthetic`
(SDL's own state OR'd with the synthetic one, so a real keyboard, if any, still
works). SDL apps grab the state pointer once and index it every frame, so the
merged buffer is refreshed on every event poll as well as on each
`SDL_GetKeyboardState` call, keeping a cached pointer live. The array-update
and merge logic is pure and host-tested (`-DGT_REMAP_TEST`); the interposition
itself is device-gated. Verified on hardware 2026-08-24: BYTEPATH plays in-game
and in-menu (`keyboard synthesis on, 15 mapping(s)` … `opened 1/1 joystick(s)`).

The joystick-state counterpart (`SDL_JoystickGetButton`) is deliberately not
interposed — no installed port has needed it — so raw-joystick *polling* ports
remain the one open input sub-tier (see F8).

## Input architecture: an honest compatibility statement (F8)

*Superseded on NextUI rc11 by [F65](#nextui-rc11-one-fixed-pad-layout-on-every-h700-model-f65): the rc10 button numbering described here no longer applies.*

NextUI's SDL2 build on h700 does not deliver PortMaster's usual
gamepad-to-keyboard translation layer to games at all — that translation
tool runs and successfully creates its virtual keyboard device, but game
processes never actually receive input through it (confirmed by checking
that a running game process holds no open file descriptor for it). This
is a platform limitation, not something a repackaging fix can paper over
in general, so ports fall into three honest tiers:

1. **Works out of the box.** Ports that use SDL's GameController API
   read the shipped controller-database mapping directly and get
   correct, zero-configuration input.
2. **Works with per-port help.** Two kinds. Ports that read raw
   joystick/event input directly (rather than through the
   GameController API) see button indices shifted by this device's
   particular hardware layout — fixed by the bundled index-remap shim
   (F25), or via the port's own in-game remapping options. And ports
   written for a keyboard — the gamepad-to-keyboard tier — are served
   by the same shim's SDL-layer key synthesis (F26), driven by each
   port's own `.gptk` mapping. Both are enabled per port via the
   shipped default list or the user's `use-remap-ports` file (see the
   README).
3. **Mostly covered; one open sub-tier.** Ports that *poll* the current
   input state, rather than reading discrete press events, used to have
   no path here. Keyboard-state polling — `SDL_GetKeyboardState`, i.e.
   `love.keyboard.isDown` — is now served by the shim's state-polling
   half (F31). The remaining gap is raw *joystick*-state polling
   (`SDL_JoystickGetButton`); no installed port has needed it, so its
   interposition isn't in the repository yet.

The gamepad-to-keyboard translation tool itself does not interfere with
tier-1 input and is left enabled by default.

F54 update: the platform limitation described here was a configuration gap,
not a wall — NextUI's SDL opens the translation tool's device once told about
it, so the gamepad-to-keyboard tier now works through the tool itself on every
port by default; see F54.

## In-game status overlay (F34)

Regular NextUI emulators show a Menu-button status screen (battery, clock,
etc.) without quitting the game; ports have no equivalent — each port is a
standalone binary that owns the display, and nothing composites above it.
F34 adds a toggleable on-screen overlay for ports, showing battery, time,
volume, and screen brightness, drawn MangoHUD/Steam-overlay style: the shim
renders directly into the port's own GL context rather than through any
system compositor or hardware layer, because neither exists here (see the
spike note below).

- **Where it lives.** The draw path is a new half of the existing
  `gt-input-remap.so` `LD_PRELOAD` shim — the same one that already does
  index remap (F25), gptk key-event synthesis (F26), and keyboard
  state-polling (F31) — interposing `SDL_GL_SwapWindow`/`eglSwapBuffers`
  and drawing one alpha-blended textured quad into the port's own context
  immediately before the real swap, saving and restoring every GL state
  object it touches so a toggle-off leaves rendering exactly as it was.
  This first stage covers the GL/GLES present path only (the engines this
  pak ships: GameMaker/gmloadernext, LÖVE, solarus); the SDL
  software-renderer path (`SDL_RenderPresent`) is a documented later
  stage, so a pure-software port shows no overlay for now rather than a
  partial or broken one. h700 only, like the rest of the shim.
- **Trigger.** A single Menu tap — press then release with no other button
  held during that press — toggles the overlay on or off; default is off,
  and the Menu event is swallowed from the game either way. The tap
  requirement is deliberate: keymon's existing Menu-held-plus-Volume
  brightness shortcut has to keep working exactly as before, so the overlay
  only flips on a clean, isolated tap and is never triggered by the leading
  edge of a Menu-hold that turns into a brightness adjustment.
- **What it shows.** A compact translucent panel in the top-right corner —
  battery percent plus charging state, time, volume, and brightness —
  refreshed about once a second.
- **Metric sources.** Battery from
  `/sys/class/power_supply/axp2202-battery/{capacity,status}`; time from
  libc. Volume and brightness come from `/dev/shm/SharedSettings`, NextUI's
  own shared struct (the same live values keymon writes and the numbers
  the user actually set in the NextUI UI) — if that read fails or comes
  back short, those two lines show `--` rather than a stale or guessed
  number. (A future ALSA-control-plus-disp-`attr/sys`-backlight fallback is
  sketched in the design spec for if the SharedSettings layout ever proves
  unstable; it is not part of 0.3.0.)
- **Gating: opt-out, not opt-in.** The shim now preloads on every h700
  port, but only the overlay half defaults to on: `GT_HUD=1` unless the
  port is listed in the pak-shipped `files/gt-hud-blocklist.txt` or the
  user's own `use-hud-blocklist`. The input remap and gptk key synthesis
  stay exactly as opt-in as before (gated by the `gt-remap-ports.txt`
  allowlist; the `GT_INPUT_REMAP=1` flag of the time was removed in F65) —
  universal preload does not change input behavior on a port that isn't on
  that list. `GT_HUD_DEBUG=1` traces the sample/draw/swap path the same way
  `GT_INPUT_REMAP_DEBUG` does for remap.
- **Crash safety.** The draw path is wrapped so any GL failure (a bad
  shader compile, a missing GL entry point, an unexpected error) disables
  the overlay for the rest of that session instead of crashing the host —
  an opt-out feature that can't rely on a blocklist to protect whoever hits
  a problem first has to fail this way.

**Known limitations (Stage 1).** Two engine paths don't get the full
experience yet — both are deliberate scope for this stage, not bugs:

  - **Software-rendered ports show no overlay.** The shim only hooks the
    GL/EGL swap functions (`SDL_GL_SwapWindow`/`eglSwapBuffers`); a pure
    SDL-software-renderer port (`SDL_RenderPresent`, e.g. *Apotris*) never
    calls either, so it shows nothing rather than a partial or broken
    overlay. A software-path draw is a later stage. *(Resolved in F35 —
    see below.)*
  - **FNA/XNA-style ports render the overlay but can't toggle it.** The
    toggle is driven from the interposed `SDL_PollEvent`/
    `SDL_WaitEventTimeout`. FNA-based ports (e.g. *Celeste*) pump input via
    `SDL_PumpEvents`/`SDL_PeepEvents` instead, so the Menu tap never reaches
    the toggle logic. The overlay itself renders fine (its GL swap path is
    hooked the same as any other GL port) — it's just permanently stuck at
    whatever state it started in. Benign either way: the game plays
    normally, no crash. *(Resolved in F35 — see below.)*

**Device-gate results (2026-08-26).** HUD confirmed on-device across every
GL/EGL-presenting engine this pak ships: GameMaker (*UFO 50*, *Deltarune*),
LÖVE (*Balatro*, *BYTEPATH*), solarus/GL4ES (*Tunics!*), and *2048 Plus*. A
single Menu tap toggles cleanly, toggle-off leaves rendering pristine, and
the F25/F26/F31 input-remap and gptk-keyboard regression is intact
(*Tunics!*/*BYTEPATH* still play correctly). The gate also corrected the
`/dev/shm/SharedSettings` offsets used for the volume/brightness lines
above: volume is int32 index 4 (byte offset 16) and brightness is int32
index 1 (byte offset 4), both on NextUI's 0–20 / 0–10 scales — the pre-gate
guess was wrong, and the shipped shim now reads 16/4.

### 0.5.1

**Fixes**
- F66: the pak's on-screen messages ("Starting, please wait...", "Unpacking
  files, please wait...", "Applying changes, please wait...") show again on
  NextUI rc10 and later. minui-presenter is now pinned at 0.13.4, which is
  built against rc11; 0.13.0 died on `GetMute`, a symbol rc10 stopped exporting

### 0.5.0

**Fixes** (from GitHub issue #1, an RG35XX Pro report, plus two rc10
regressions; device-verified on the RG SP except F56, F61 and F62's pre-rc10
path)
- F54: gptokeyb passthrough — keyboard/mouse ports now get gptokeyb's own
  virtual keyboard and mouse through `SDL_EVDEV_DEVICES`, on top of the shim's
  existing synthesis fallback; Sonic 1/2 stay on the synthesis path
  (blocklisted); OpenTTD's launcher gets the `ANALOGSTICKS` alias it was
  missing
- F55: Duke Nukem 3D and the rest of the EDuke32 family (Blood, Redneck
  Rampage, PowerSlave) start again — the 0.4.0 sleep-proxy ALSA config carried
  no `hint {}`, so SDL enumerated zero audio devices
- F56: RG35XX Pro gets its own two-stick `rg35xx-h` profile instead of the
  stickless `rg35xx-plus` one; a stickless profile on a sticks-class pad now
  logs a warning
- F57: the in-game HUD's brightness and volume gauges read live again on
  NextUI h700-rc10 — the decoder now guards on a minimum block length instead
  of the old rc8 struct size
- F58: Doom Engines and Luanti load — shipped the three missing sonames
  (`libgomp.so.1`, `libgthread-2.0.so.0`, `libgmp.so.10`)
- F59: ports run with stdin from `/dev/null` (Wolfenstein 3D / ECWolf no
  longer hangs in its console IWAD picker)
- F60: gl4es ports whose bundled fake EGL predates `eglDestroySyncKHR`
  (Quakespasm) get the pak's own pinned stub swapped in at launch; a launcher
  that sets no `LD_LIBRARY_PATH` gets its own `libs.aarch64`/`libs` back
- F61: launchers that declare `PORTDIR=` but no `GAMEDIR=` (Fallout 1) run
  instead of being refused
- F62: `DEVICE_HAS_ARMHF` is claimed only when a 32-bit libdl exists behind
  the loader, correcting the value port scripts see and the `device_info.txt`
  dump — harbourmaster works out armhf capability itself from the loader
  alone, so pre-rc10 firmware still offers armhf-only ports (Serious Sam: The
  First Encounter) and they still fail to load ("wrong ELF class"); rc10
  ships a real 32-bit userland and keeps `Y`; the stray `lscpu` probe is
  silenced
- F63: Doom Engines' menu loads — shipped four more sonames its bundled
  cairo needed (`libxcb-shm`, `libxcb-render`, `libXrender`, `libXext`)
- F64: Luanti's text renders correctly instead of `<invalid UTF-8 string>` —
  shipped glibc's missing UTF-16/UTF-32 `gconv` conversion modules

**NextUI rc11 (F65).** This release requires NextUI h700-rc11 or newer and is
published as a pre-release alongside the rc11 preview.
- F65: the input stack moves to rc11's fixed TrimUI/Xbox 360 pad numbering —
  the rc10 index-remap tables, the per-class controller-DB copies and the
  Menu-echo handling are removed; one rc11 controller-DB line per layout
  serves every h700 model; the shim synthesizes gptk `l2`/`r2` keys from
  rc11's trigger axes; Cave Story's settings are renumbered (installs made
  before rc11 migrate once, keeping in-game rebinds; JUMP/FIRE are
  re-conformed to the layout); a Balatro button map
  saved on the old pad ID is moved aside so the game asks for its button check
  once; launch.sh logs a warning on firmware older than rc11

**Build:** the pinned bullseye `.deb`s now come from snapshot.debian.org
(bullseye itself is archived on deb.debian.org); the gmtoolkit pin was
refreshed to the bytes upstream re-published under the same tag (not
re-verified on device with a GameMaker port that patches on first launch).

**Upgrading from 0.4.0:** update NextUI to rc11 or newer first, then
unzip-over (self-healing); Balatro asks for its button check once. Ports
carried over from another CFW's card may be stale builds — let PortMaster
update/reinstall them before retesting.

### 0.4.0

**Upstream base:** ben16w/minui-portmaster 2.13.0 → 2.14.0 — the bundled
PortMaster runtime moves from the 2025.07 release to PortMaster-GUI
2026.07.28 (a year of harbourmaster/GUI/patcher fixes, rebuilt
gptokeyb/libinterpose, `funcs.txt` now defines `pm_platform_helper`, the
control folder now ships `7zzs`), plus jq 1.8.2, squashfs-tools 4.7.5 and
7-Zip 26.02. Every h700 patch applies unchanged; F18 and F19 become
belt-and-braces.

**Fixes**
- F46: dropped the bundled tg5040 Weston runtime image from the pak (−44 MB download and SD footprint) — Weston ports can't display on the RG SP regardless, and the official image stays downloadable on demand
- F47: ports can now sleep — a watcher daemon suspends the port tree on the power button / lid close, plus an ALSA suspend-proxy so audio survives the resume
- F48: controller face-button layout (Nintendo vs Xbox A/B/X/Y) is now configurable — a `config.json` key plus a PortMaster GUI toggle drive the SDL gamecontrollerdb, the input-remap shim's synth ports, and OpenCrossing from one resolved value; factory default flips to Nintendo, matching the RG SP's printed labels
- F49: Cave Story (Evo) now follows the resolved controller layout — its `settings.dat` face-button bindings are conformed on launch, byte-patched and idempotent
- F50: the controller layout can now be set per game from that port's own info screen in the PortMaster GUI, and the global toggle moved up to be visible without scrolling; self-configuring ports (Balatro-class) show a disclaimer instead, by design
- F51: the RG SP-specific hardware constants are now device-keyed — other h700 NextUI devices (RG34XXSP, RG35XX family, RG40XX family) get their own PortMaster profile, panel geometry, Sonic screen fit and sleep trigger (still unverified on those devices)
- F52: stick-equipped h700 devices with the RG34XXSP key set (two sticks, L3/R3 clicks) get the matching controller tables — the pak reads the input node's key set at launch and picks the measured mapping for it, fixing triggers, stick clicks and a Menu-button echo that swallowed R2 in every port; anything else falls back to the RG SP tables plus a warning; `use-input-debug` flag file traces the input shim for reports
- F53: analog sticks (Experimental — not yet verified on hardware) — sticks mapped in the controller DB for native ports and the GUI, stick-to-keys synthesis in the input translator with gptokeyb's own keys and defaults, a truthful 2-stick device profile, and a `use-stickless` flag file to fall back to d-pad control schemes

**Upgrading from 0.3.2:** unzip-over (self-healing); no manual steps. A
`weston_pkg_0.2.squashfs` already in `PortMaster/libs/` is left as is.

### 0.3.2

**Fixes**
- F40: Sonic 1 & Sonic 2 (RSDK decompilation) now launch — shipped the missing `libsndfile` audio chain
- F41: Sonic 1 & 2 fill the screen — corrected the RSDK render width for the 720×480 panel
- F42: Sonic 1 & 2 sound — force the SDL audio-subsystem init the RSDK runtime skips
- F43: Sonic 1 & 2 controls — keyboard-synthesis fallback for the dead RSDK GameController path
- F44: in-game HUD on the Sonic ports — geometry save/restore around the software-HUD draw
- F45: Animal Crossing (GameCube decomp) now plays — a bundled 32-bit armhf runtime brings render, audio, input and the HUD to the aarch64-only NextUI

**Upgrading from 0.3.1:** unzip-over (self-healing); no manual steps.

### 0.3.1

**Fixes**
- F37: native OpenGL ES 3 for gothic/machismo ports — Mina the Hollower now boots
- F38: in-game HUD renders on native-ES3 contexts (sampler-object fix)
- F39: Cave Story (Evo) controls + screen fit — d-pad, buttons and resolution corrected for the RG SP

**Upgrading from 0.3.0:** unzip-over (self-healing); no manual steps.

### 0.3.0

**Fixes**
- F33: faster port startup (splash + redundant-patch trims)
- F34: in-game status overlay (battery/brightness/volume/time), GL/EGL engines
- F35: overlay on software-renderer ports + universal Menu toggle (all engines)
- F36: Tunics! (solarus) no-JIT fix — stops the LuaJIT crash on map transitions

**Upgrading from v0.2.3:** unzip-over (self-healing); no manual steps.

A hardware overlay layer — compositing above the port's framebuffer via the
sunxi `/dev/disp` DE driver, immune to any of the GL-state risk above — was
spiked and ruled out first: `DISP_LAYER_SET_CONFIG` returns `EPERM` for
every channel on this device, root or not, because the DE manager runs in
legacy fbdev mode and the driver refuses to mix that with direct layer
programming. Full spike detail and the swap-interpose design are in
`docs/superpowers/specs/2026-08-26-ingame-overlay-hud-design.md`.

## In-game status overlay: software draw + universal toggle (F35)

F34 shipped the overlay for GL/EGL-presenting ports only, with two Stage-1
gaps: no draw path for software-rendered ports, and no working toggle for
FNA/mono-hosted ports. F35 closes both by extending the same
`gt-input-remap.so` shim rather than replacing any of its F34 machinery.

- **Software draw.** A new interpose on `SDL_RenderPresent` composes the
  same panel content the GL path draws into one CPU-side RGBA buffer,
  uploads it into a single `SDL_PIXELFORMAT_ABGR8888` streaming texture
  created on the port's own `SDL_Renderer`, and `SDL_RenderCopy`s it into
  the top-right corner immediately before the real present. This is
  backend-agnostic — it works whether that renderer happens to be
  `software` or a GLES-backed `SDL_Renderer` — and covers *Apotris* and
  any future 2D-renderer port. It has its own crash latch, `gt_sw_dead`,
  independent of the GL path's latch, so a failure in one draw path
  disables only that path for the rest of the session. *Celeste* needs
  nothing from this half: its `libFNA3D` back end still ultimately calls
  `SDL_GL_SwapWindow`, so it already draws through F34's GL hook.
- **Universal evdev toggle.** Toggling no longer depends on which SDL
  entry point a port's input loop happens to call. A detached thread
  started by the shim reads `/dev/input/event*` directly, discovering the
  right node by capability — the one whose `EV_KEY` bitmap reports both
  `BTN_TL2` (312) and `KEY_GOTO` (354), NextUI's Menu button — rather than
  a hardcoded event-node number, and watches it below mono, gptokeyb, and
  SDL alike. It is the sole toggle authority for every engine this pak
  ships, GL/EGL and software and FNA together. It opens the node
  non-grabbing (no `EVIOCGRAB`), so keymon's existing Menu-hold brightness
  combo and the game itself both keep seeing the same events; Vol- (114)
  and Vol+ (115) are read from the same node purely to disqualify a
  Menu-tap that's actually the leading edge of that brightness combo.
- **Decision A: leave the F34 SDL interposers swallow-only.** The
  `SDL_PollEvent`/`SDL_WaitEventTimeout` hooks added in F34 keep eating the
  Menu press/release pair for GL-presenting ports so it never reaches the
  game, but they no longer drive the toggle themselves — the evdev thread
  does that for every port now. Non-regressive: mono- and gptokeyb-driven
  ports never called those SDL entry points in the first place, so nothing
  that used to work stops working, and GL ports keep the exact swallow
  behavior they had under F34.
- **Why not `SDL_PumpEvents`.** F34 assumed an eventual
  `SDL_PumpEvents`/`SDL_PeepEvents` interpose would cover FNA-style input
  pumping. The 2026-08-26 device spike killed that idea outright: *Celeste*
  pumps input from managed C# via mono's `[DllImport]` P/Invoke
  marshalling, which resolves the SDL entry points through an explicit
  `dlopen` handle rather than the dynamic symbol table, so `LD_PRELOAD`
  interposition never sees those calls at all — no SDL-level hook,
  present or future, could ever have worked for this port. The evdev
  layer is the only point in the input stack that is genuinely universal.
- **Clears both Stage-1 limitations.** Software-rendered ports now both
  show and toggle the overlay via the new draw path; FNA/mono-hosted ports
  now toggle correctly via the evdev thread even though their input pump
  is invisible to every SDL-level hook. See "Known limitations (Stage 1)"
  under F34 above.
- **Thread starts lazily, in the rendering process only.** The device
  gate found that starting the evdev thread from the shim constructor
  spawned it in *every* `LD_PRELOAD`'d process of a port launch — busybox
  is dynamically linked here, so the shim loads into `bash`, `busybox
  tee` (the log sink), gptokeyb, and the game alike — leaving several
  extra threads each blocked in a `read()` on the input node. That added
  ~8s to port *exit* (device A/B: same port exits &lt;2s with the thread
  off, ~9–10s with it on). The thread is now started once per process
  (`pthread_once`) from the present/swap interposers themselves, so only a
  process that actually presents frames — the game — ever opens the node;
  the shell and helper processes never do. Exit time is back to the F34
  baseline, device-verified, with the toggle unchanged.
- **Device-gate results (2026-08-26, RG SP).** Passed across every engine.
  *Apotris* (software `SDL_RenderPresent` path): HUD shows and toggles,
  values live and correct (brightness/volume update on change), colors
  correct (ABGR8888), toggle-off leaves rendering pristine, no crash.
  *Celeste* (FNA/mono, GL-drawn): HUD shows and toggles via the evdev
  thread — the first working toggle under mono. The F34 GL-port set
  (*Balatro*, *BYTEPATH*, *Deltarune*, *UFO 50*, *Tunics!*, *2048 Plus*)
  still toggles and still swallows Menu from the game. keymon's Menu-hold
  brightness combo works and does not spuriously toggle the overlay. The
  exit-time regression above was found here and fixed before sign-off.

## The F28 no-JIT pre-script never actually ran (F36)

F28's fix for the LuaJIT aarch64 miscompile injected `-s=<pak>/files/solarus-nojit.lua`
into the port's launch line. Solarus's `-s` option doesn't take a path — it
runs its *value* as inline Lua source. A bare path is not valid Lua, so the
engine logged `unexpected symbol near '/'`, the pre-script never executed,
and the JIT stayed on: Tunics! kept crashing (`Illegal instruction`) on map
transitions, intermittently, exactly as before F28 — device-diagnosed on
Tunics!.

Fix: inject `-s="dofile('<pak>/files/solarus-nojit.lua')"` instead — `dofile`
is a real Lua call, so the engine loads and runs the pre-script and the JIT
turns off as F28 intended. `run_port` also self-heals any launcher already
carrying the broken F28 path form (checked ahead of the plain injection
guard), so an upgrade fixes existing installs without a reinstall.
Device-verified: Tunics! no longer crashes on the stairs transition, and A/B
(reverting to the F28 form) reproduces the crash again.

## Ports this platform can't run

A few ports depend on capabilities the h700's NextUI/BaseOS image simply
doesn't provide, and no repackaging fix reaches them. Recorded here so a user
report can be answered quickly. All four below were checked against a ROCKNIX
device (officially PortMaster-supported) to separate "the port is broken" from
"this platform can't host it" — in every case it's the latter.

- **Weston ports** — e.g. *Alex the Allegator 1*, *Mage Recall*. These launch a
  bundled Weston compositor (the *Westonpack* runtime, `weston_pkg_0.2`) and
  render through the Crusty GL shim. A 2026-08-25 on-device spike corrected an
  earlier, coarser reading of why they fail — the real blocker is **display
  scanout**, not input and not GPU rendering:
    - *Not input.* The compositor comes up fine on the `headless` backend with
      the bundled `seatd` — no `udev` needed — once one missing library,
      `libevdev.so.2`, is supplied (the runtime bundles `libinput` but not
      `libevdev`). That absent `.so` was the entire reason `wp_weston` wouldn't
      even load; with it, Weston 13 reaches "xserver listening on display :0".
    - *Not GPU rendering.* The pak already ships **gl4es** as `libGL.so.1`, and
      it initializes on the h700's proprietary mali blob (desktop GL 2.1 over
      GLES) — the closed driver is enough to render.
    - *The wall is present/scanout.* The h700's Allwinner 4.9 kernel exposes
      only the legacy framebuffer (`/dev/fb0`) and the sunxi `/dev/disp` ioctl
      device — there is **no DRM/KMS** (`/sys/class/drm` is absent; `lsmod`
      shows `mali_kbase` for rendering but no display driver). Weston 13 has no
      fbdev backend (only drm/headless/wayland/x11), and Crusty presents only
      via DRM+GBM. The one scanout path the device does have — the mali blob's
      own fbdev EGL, which every native GLES port here uses — is exactly the one
      Weston and Crusty cannot drive, so a Weston-hosted frame has no route to
      the panel. On a ROCKNIX device these run because its kernel provides
      DRM/KMS (sun4i-drm / Panfrost).
    - *What would actually help* (all beyond a repackaging fix): an
      fbdev/sunxi-disp present frontend added to Crusty; a sun50i DRM/KMS driver
      in the NextUI kernel; or — per-port, and only where the game doesn't need
      an X server — bypassing Weston to run on SDL2 + gl4es-fbdev + the mali
      fbdev EGL (the native path). Westonpack itself does not target NextUI/minui.
- **box64 ports** — e.g. *Momodora: Reverie under the Moonlight* (an RHH
  port). These emulate an x86-64 Linux binary through box64 *and* use the
  Weston stack above, so they inherit its scanout wall; the box64 runtime is
  additionally an RHH-specific artifact the pinned harbourmaster can't fetch
  (like `gmloadernext`, it would need manual placement — and even official
  PortMaster on ROCKNIX has no button to install it).
- **32-bit armhf ports** — e.g. *Curseball* (an old-`gmloader` port). These
  need a 32-bit armhf userspace, including a 32-bit mali GLES driver, that
  NextUI-h700 doesn't ship (the armhf loader is present, the libraries are
  not); its `gmloader` dies resolving a 64-bit `libstdc++.so.6`. It renders on
  the ROCKNIX device, which carries the 32-bit stack. This description holds
  for NextUI-h700 before rc10; rc10 ships the 32-bit userland and GL stack
  described in F62, and these ports are untested there. Harbourmaster works
  out armhf capability itself from the loader alone, so PortMaster still
  offers these ports on pre-rc10 firmware and they still fail to load
  ("wrong ELF class") — *Serious Sam: The First Encounter* was the reported
  case (issue #1). Since 0.5.0 (F62) the pak corrects the `DEVICE_HAS_ARMHF`
  value port scripts see and the `device_info.txt` dump to match, but that
  alone can't stop harbourmaster from listing them; only a patch to
  harbourmaster's own probe could.
- **libretro-class ports** — need the CFW's RetroArch, which NextUI doesn't
  expose to paks.

## Newer-glibc ports: a validated per-port glibc sandbox (on the shelf, not yet needed)

Some newest-generation ports link against glibc symbols
(`GLIBC_2.36`/`2.37`/`2.38`) that this device's glibc doesn't export, and fail
at load with `version 'GLIBC_2.3x' not found`. None of the currently-known
unsupported ports (above) fail this way — their blockers are display scanout or
CPU architecture, not libc — so nothing needs this today. It is recorded here as
a validated technique to reach for the first time a specific port hits that wall.

**Device baseline (verified 2026-08-26 over ssh).** kernel 4.9.170, **glibc
2.35**, **SDL2 2.28.5** (`/.system/h700/lib/libSDL2-2.0.so.0.2800.5`). This came
out of evaluating the *StockOS MOD* PortMaster fork (kai4man), whose entire
"100 % ports" story turns out to be a userland modernization — a system patch
that swaps glibc up to 2.38 and SDL2 up to 2.28.5 (it ships **no** kernel, DRM
driver, Weston, or box64). NextUI-h700 has already banked most of that on its
own: we are at **parity on SDL2** (both 2.28.5) and within three minor versions
on glibc. So the only userland gap left to StockOS MOD is the glibc 2.35 → 2.38
tail; the scanout / architecture gaps in the section above are unrelated to it
and this technique does not address them.

**The technique — a per-port alternate loader, never a system swap.** StockOS MOD
repoints the *system* loader (`/lib/ld-linux-aarch64.so.1`) at a bundled
`/opt/glibc-2.38`. We must never do that on NextUI: its launcher, `minarch`, and
the mali blob are built against the system glibc, and repointing it risks
bricking the UI. Instead, sandbox only the port process — ship a glibc tree in
the pak and launch the port binary through *that* tree's loader:

```sh
GLIBC="$controlfolder/glibc-2.38"
"$GLIBC/lib/ld-linux-aarch64.so.1" \
  --library-path "$GLIBC/lib/aarch64-linux-gnu:$GLIBC/lib:$PORT_LIBS" \
  ./the_port_binary
```

Only that process and its children see the newer glibc; the rest of the system
is untouched. This is the same shape as upstream PortMaster's optional `glibc`
runtime.

**Why it's safe.** glibc symbol versioning is strictly additive: a 2.38 libc is a
superset of 2.35, so every library already on the device (SDL2, the mali blob,
gl4es, …) keeps resolving under it. Nothing that runs today can break inside the
sandbox — the only new capability is serving a binary that needs 2.36–2.38.

**Feasibility — proven on-device (2026-08-26 spike; non-destructive, torn down).**
Using StockOS MOD's own extracted glibc-2.38 `lib/` subtree staged in `/tmp`
(tmpfs — the SD card is vfat and cannot hold glibc's symlinks/hardlinks; `/` and
`/data` are ext4 if a persistent copy is ever wanted):

- **T1** — the 2.38 `ld.so` executes on the 4.9.170 kernel
  (`ld.so (GNU libc) stable release version 2.38`).
- **T2** — a stock binary (`/bin/ls`) runs under
  `ld-linux-aarch64.so.1 --library-path …`.
- **T3** — Deltarune's real GameMaker + SDL2 runner (`gmloadernext.aarch64`)
  resolves cleanly under the sandbox: `libc`/`libm`/`libpthread`/`librt`/`libdl`
  from the 2.38 tree, `libSDL2-2.0.so.0` from the pak's 2.28.5, everything else
  found, zero errors.

**If/when it ships.** Make it a per-port opt-in (a flag or a small allow-list in
`launch.sh`), not a blanket wrapper — running every port through the sandbox is
needless overhead and a larger surface for the rare port that dislikes a swapped
loader. Bundle a glibc tree in the pak (StockOS MOD's is a ready, device-matched
2.38 build; a clean-room build from Debian/crosstool-NG is the licensing-safe
long-term source) and gate each candidate port with an on-device run. Priority is
**low** until a wanted port actually needs it.

## Native OpenGL ES 3 for gothic/machismo ports (F37)

*Mina the Hollower* (porter: bmdhacks) runs the macOS Apple-Silicon build of the
game through `machismo` — a Mach-O loader based on Darling — plus a port shim
`libgothic_patches.so` that translates Yacht Club's "gothic" engine (Metal) to
GLES. The engine emits GLSL **ES 3.10** shaders and, when Vulkan is absent —
always on this hardware, the Mali-G31 (Bifrost) blob exports no `vk*` — takes a
GLES fallback. On this pak that fallback bound **GL4ES** (`libGL.so.1`, a desktop
GL 2.1 / GLSL 1.20 wrapper), whose ShaderConv rewrites `#version 310 es` down to
`#version 100` while leaving `layout(...)` in place — invalid GLSL ES 1.00, so
the first shader (`copy.vert`) fails to compile and the render thread `SIGABRT`s
before drawing a frame. The port never started.

The device is fully capable: the Mali r20p0 blob natively exposes **OpenGL ES 3.2
/ GLSL ES 3.20** and compiles those shaders as-is. It just never got reached,
because SDL only binds the native GLES driver when the context is requested with
an ES profile, and the profile is chosen inside the port's own compiled window
shim (no env knob — `LIBGL_ES`, `LIBGL_SHADERNOGLES`, `SDL_VIDEO_GL_DRIVER`,
`SDL_VIDEODRIVER=mali` were all tried on-device; each still landed on GL4ES).

The fix is two parts, applied together by `run_port` and gated on the gothic
signature `libs/libgothic_patches.so` (auto-detected like the FMOD gate, not a
per-port list — the failure is engine-level and h700-invariant, so it is
gothic-generic by construction):

1. **Shadow the GL stack with the device's native Mali wrappers.** Copy
   `/usr/lib/libGLESv2.so.2` → `$GAMEDIR/libs/libGL.so.1` and
   `/usr/lib/libEGL.so.1` → `$GAMEDIR/libs/libEGL.so.1` (the port launcher puts
   its own `libs` first in `LD_LIBRARY_PATH`), so SDL `dlopen`s native Mali GL/EGL
   by name and GL4ES never loads. `libEGL` **must** be shadowed too: the pak's
   `libEGL.so.1` is GL4ES's own and needs the `hardext` symbol from GL4ES's
   `libGL`, so a `libGL`-only shadow breaks `libgothic_patches`' load. Copies are
   `cmp`-guarded and `cp -fp` (a fresh mtime would retrigger rebuild-if-newer
   ports), and copied straight from the device — no proprietary blob is bundled.
2. **Preload `gt-gles3-profile.so`**, which forces an ES3 SDL GL profile
   (interposing `SDL_GL_SetAttribute`/`SDL_GL_CreateContext`). Without it SDL
   binds `EGL_OPENGL_API` on native Mali EGL and context creation fails.
   `LD_PRELOAD` alone can't do part 1: the GL library is committed at the game's
   `SDL_CreateWindow` via machismo's Mach-O resolver and gothic's in-memory SDL
   trampoline, both of which bypass `LD_PRELOAD`.

Device-verified 2026-08-27: `GL caps version="OpenGL ES 3.2 … r20p0" renderer=
"Mali-G31" glsl="OpenGL ES GLSL ES 3.20"`, boots and plays. Sound works too — the
gothic audio path is native SDL2 → ALSA, and the 214 MB `pcm_cache` the engine
builds is a decode cache, not a prerequisite (a fresh, deleted-cache launch still
had sound from the loading screen). Likely unblocks the whole class of bmdhacks
gothic/machismo ES3 ports, not just Mina, though Mina is the only one tested.

## In-game HUD on native-ES3 contexts: the sampler-object fix (F38)

With F37, Mina runs on a native ES3 context — and the F34 HUD, which had only
ever run on GL4ES (desktop GL 2.1) contexts, drew a **solid black rectangle**
there (correct size, toggled correctly, but no content). Geometry, shader and
blend were all fine; only the sampled texel came back black, and the HUD's own
texture setup was ES-correct (NEAREST filter, CLAMP_TO_EDGE, no mipmaps → a
complete texture).

The cause is an ES3-only piece of state that does not exist in GL4ES's GL 2.1:
a **sampler object**. A `GT_HUD_DEBUG` dump added to the draw path showed the
engine leaves **sampler object #1 bound to texture unit 0** (`sampler[unit0]=1`).
A bound sampler object *overrides* the texture unit's `glTexParameteri`, so the
HUD's NEAREST/no-mipmap parameters were ignored and the engine's sampler (a
mipmap filter) governed our no-mipmap texture — an incomplete combination that
samples opaque black on ES.

The fix (`gt-input-remap.c`): save the sampler bound to unit 0, `glBindSampler(0,
0)` to unbind it so the HUD's own parameters apply, and restore the engine's
sampler afterward. `glBindSampler` is resolved **non-fatally** — it does not
exist on GL4ES/ES2, so the pointer stays `NULL` there and the entire code path is
skipped, leaving the HUD byte-for-byte unchanged on every existing port
(regression-checked on-device across the full installed set, 2026-08-27). Because
the HUD now renders on native ES3, gothic ports are **not** HUD-blocklisted.

## Cave Story (Evo): raw-joystick bindings baked into settings.dat (F39)

*Superseded on NextUI rc11 by [F65](#nextui-rc11-one-fixed-pad-layout-on-every-h700-model-f65): the rc10 button numbering described here no longer applies.*

Cave Story (Evo) runs on **nxengine-evo**, which reads the **raw SDL joystick**
directly (`SDL_JoystickOpen` + `SDL_JOYBUTTONDOWN`/`SDL_JOYHATMOTION` events — no
GameController API, and no `SDL_JoystickGetButton` polling) and binds each in-game
action to a specific joystick **button index**, plus a **resolution index**, in a
binary config file `conf/nxengine/settings.dat`. The port ships that file per
display width, tuned for the porter's reference hardware. On the RG SP three of
those assumptions are wrong:

- **Directions** were bound to joystick **buttons 8–11**. The RG SP's d-pad is
  not buttons — it is an SDL **hat** (evdev `ANBERNIC-keys` exposes `ABS_HAT0X`/
  `ABS_HAT0Y` → SDL hat 0; the device's three real axes are `ABS_RX/RY/RZ`). So
  the engine waited for button events the hardware never sends → **d-pad dead**.
- **Face actions** were bound to buttons **0–7**, but this device's face buttons
  enumerate at raw indices **3–13** (the hardware-measured table in
  `assets/gt-input-remap.c`) → **scrambled buttons**.
- **Resolution** defaulted to index 3 = **720×720** (a square mode), 240 px taller
  than the RG SP's **720×480** visible framebuffer → the picture **overran the
  bottom** of the screen.

This is not the F25 joystick-index shift and not something the `gt-input-remap.so`
shim can fix: the shim rewrites the SDL event stream, but nxengine's problem is
its *stored binding table*, and no index rewrite turns a hat into the buttons the
table names. The fix is to give the port an **RG SP-correct `settings.dat`**.

`settings.dat` format (verified): magic `"NXS7"` (u32 @0), then config bytes, a
`resolution` int32 @4, and 28 binding records @36 — each 24 bytes = six
little-endian int32 `key, jbut, jhat, jhat_value, jaxis, jaxis_value` (`-1` =
unbound; `jhat_value` is the SDL_HAT bitmask UP=1/RIGHT=2/DOWN=4/LEFT=8). Records
run in enum order (Left, Right, Up, Down, Jump, Fire, Strafe, PrevWpn, NextWpn,
Inventory, MapSystem, Esc, …). The engine rewrites the file from its loaded
mappings on options-close and on every in-game save/load, so a hand-authored file
survives as long as `NXS7` is intact — it is written back byte-identical.

`assets/nxengine-evo-h700-settings.dat` is that file: directions → hat 0, faces →
this device's raw indices (JUMP = raw 4 / bottom, FIRE = raw 3 / right, Strafe =
Y, Prev/Next weapon = Select/Start, Inventory = L1, Map = R1), resolution index 2
= **640×480** (the largest 4:3 mode that fits 720×480). Keyboard bindings are left
intact. `run_port` installs it into the port's `conf/nxengine/` **once**, gated by
a `.gt-h700-settings` marker — deliberately *not* the F27 port-fixes overlay,
which re-copies every launch and would revert a player's in-game rebinds or
resolution changes. A port reinstall recreates `conf/` without the marker, so the
fix self-heals. Cave Story stays **off** the input-remap allowlist (it needs
bindings, not translation); the HUD is unaffected.

Device-verified 2026-08-27 (boots, plays, d-pad + A=jump/B=fire + down-to-interact
all correct). Two accepted limitations, both engine/platform-level, not
config-fixable: nxengine's hat handler resolves a single direction on a hard
diagonal (horizontal wins — no simultaneous up+left), and the 640×480 frame lands
left-aligned rather than centered because the RG SP presents straight to fbdev
with no compositor to honor SDL's window-centering request (the frame is fully
visible; a thin bar sits on the right). The engine's own Options → Controls /
Resolution menus can be used to adjust either, and those choices persist.

## Animal Crossing: a 32-bit armhf port on aarch64-only NextUI (F45)

Animal Crossing (the OpenCrossing GameCube decompilation) ships a **32-bit
armhf** `AnimalCrossing` binary and an armhf runtime, targeting the 32-bit
PortMaster handhelds (RG35XX and friends). NextUI on the RG SP is
**aarch64-only** — `DEVICE_ARCH=aarch64`, so the porter's `libs.${DEVICE_ARCH}`
directory is empty and none of the 32-bit SDL / GL / Mali stack the binary links
against is present. The port could not even reach `main()`. The device's kernel
carries `CONFIG_COMPAT`, so a 32-bit userspace *runs*; it just has nothing to run
against. The fix is to bundle a complete 32-bit runtime and wire the launcher to
it, then solve render, audio and input on top — each of which fails differently
on this platform.

**Runtime.** `files/ac-gc-h700/libs.armhf/` is a 15-library 32-bit set sourced
from the stock Anbernic card: SDL 2.0.12, the Mali-G31 userspace blob
(`libmali.so.0`, ~14 MB), `libstdc++`, `libasound`, `libudev`, the tiny
EGL/GLESv2 name-shims the blob backs, and the C-runtime deps. The launcher puts
this dir on `LD_LIBRARY_PATH` (ahead of the port's own empty aarch64 dir), so the
32-bit loader resolves everything the binary needs.

**Render.** The stock SDL2 was built with only the `mali`/`dummy` video drivers,
and NextUI has no DRM/KMS, so `SDL_VIDEODRIVER=mali` (fbdev) is forced, with
`SDL_VIDEO_EGL_DRIVER` / `SDL_VIDEO_GL_DRIVER` pointed at the bundled 32-bit
`libEGL.so` / `libGLESv2.so` by absolute path (robust against LD search order).
The game then binds a **native Mali-G31 OpenGL ES 3.2** context at 720×480 — no
GL4ES down-conversion is involved (unlike the gothic ports in F37).

**Audio.** The porter sets `SDL_AUDIODRIVER=pipewire,alsa,dsp`. SDL 2.0.12
predates comma-list driver parsing (2.24+) and NextUI has no PipeWire, so
`SDL_Init(SDL_INIT_AUDIO)` aborted on the unparseable value. Forcing plain
`SDL_AUDIODRIVER=alsa` gives sound from the loading screen on.

**Input — the hard part.** On NextUI the port's stock 32-bit SDL 2.0.12 delivers
**zero** joystick or controller events to the game: the native-controller path is
dead, `gptokeyb`'s uinput keyboard never reaches the game, and even the
`gt-input-remap` shim's own SDL-layer synthesis (F26/F31) sees nothing to work
from. AC drives movement and actions by polling `SDL_GetKeyboardState` by
scancode every frame. The one input source that *does* reach the game is the
shim's **evdev thread** — the same `/dev/input`-reading thread that already made
the Menu/HUD toggle work, which bypasses SDL entirely. F45 extends that thread
(behind a per-port `GT_EVDEV_KEYS=1`) to read the gamepad's evdev codes directly
and synthesize the keys `SDL_GetKeyboardState` returns. The codes map through the
same `gt_remap` table and the port's gptk as every other remapped port, so the
layout matches the rest of the pak. AC's `keybindings.ini` binds the four faces,
L/R, Start and a Z key plus WASD (main stick) and arrows (camera); the D-pad
drives WASD and L2/R2 rotate the camera. Because the RG SP is Nintendo-labelled
but the pak runs an Xbox-positional layout, the four face buttons carry a
**Nintendo↔Xbox cross-swap** in `animalcrossing.gptk` (gptk `a`→game B, `b`→A,
`x`→Y, `y`→X) — device-confirmed after A/B and X/Y felt swapped under the straight
mapping.

**HUD.** The in-game overlay (F34/F35) needs no AC-specific work: the pak sets
`GT_HUD=1` for every port and the shim's HUD draws over the game's GL present
path; it toggles and renders correctly here.

**Packaging.** Everything beyond the porter's own files is **pak-hosted** and
referenced by absolute `$PAK_DIR` paths — the runtime and gptk under
`files/ac-gc-h700/`, the 32-bit shim as `lib/gt-input-remap.armhf.so` (the same
`gt-input-remap.c` source, built in an armhf container; see `make shim`). So the
harbourmaster install itself is never modified — only `save/` and `conf/` are
written there, and reinstalling the port from PortMaster does not have to be
undone. The one file that must change is the port's launcher, and
`copy_game_scripts` reverts it to the pristine porter source (wrong
`controlfolder` fallback, none of the runtime wiring) after every
PortMaster-GUI session. `run_port`'s `gt-h700-ac-launcher` hook re-installs the
pak launcher over `ROM_PATH` each launch — cmp-guarded (an unchanged launcher is
never rewritten), detected by the `AnimalCrossing` binary in the resolved
`GAMEDIR` so a user-renamed `.sh` still heals and no other port is ever touched.
The build fail-closes on the ELF class of both the shim and the Mali blob, so an
aarch64 artifact can never ship under a 32-bit name.

Device-verified 2026-08-28 on a clean install: boots, plays, native ES 3.2
render, sound from the loading screen, every control correct (Camille confirmed),
and the in-game HUD working.

## The bundled Weston runtime image is dead weight here (F46)

Upstream's release zips are not built from the tagged source: the release
workflow runs on a `get-weston` branch whose `launch.sh` carries a
`bootstrap_files` block that moves a bundled `files/weston_pkg_0.2.squashfs`
(44.6 MB, a custom Westonpack build fetched from a Google Drive link at
upstream build time) into `PortMaster/libs/` on first boot, and — since
2.14.0 — writes an `.md5` sidecar plus a `harbour.py` tweak so harbourmaster
treats that custom build as "Verified" instead of replacing it with the
official one. That is how every RG SP running this pak came to have a
Weston runtime installed: not from a PortMaster download, but from the zip.

On h700 the whole Weston/Crusty class cannot reach the panel (no DRM/KMS
scanout — see "Ports this platform can't run" above), so the image is pure
dead weight: 44 MB in every download and on every SD card, for a runtime no
installed port can use. Fix: the build removes the file from the assembled
pak. Upstream's bootstrap block is left in place — its `[ -f ... ]` guard
makes it a no-op — and the `.md5`/`harbour.py` tweak is harmless without the
file. Nothing on an existing device changes (the zip ships no `libs/`, so a
previously installed copy stays), and should a future fix ever make Weston
viable here, harbourmaster can still download the official
`weston_pkg_0.2.squashfs` on demand.

## Sleep during ports: a watcher, plus an ALSA proxy that survives it (F47)

**Why ports couldn't sleep.** NextUI's sleep support is a foreground-app
feature: `nextui`/`minarch` watch `/dev/input/event0` for the power key and
the lid's hall sensor, then run `$SYSTEM_PATH/bin/suspend`. `keymon`, the
daemon that stays alive while a port runs, only handles volume and
brightness — it has no sleep role. Once a port launches, nothing on-device
is watching the power button or lid at all, so pressing power does nothing.

**Trigger map.** `gt-sleepmon` (`assets/gt-sleepmon.c`) opens the input node
whose `EV_KEY` capability includes `KEY_POWER` (the `axp2202-pek` node —
event0 on the RG SP; F51 scans for it instead of assuming the index, falling
back to event0) — non-grabbing, so keymon keeps reading it too — and watches
three codes:

- `KEY_POWER` (116), **release** (value 0) — suspend
- `KEY_INSERT` (110, the lid-close hall sensor), **press** (value 1) — suspend
- `KEY_DELETE` (111, lid open) — ignored; the power button is the only wake
  source

Triggering on the power key's *release* (matching `minarch`'s own edge)
avoids a second trigger firing on the way down. After a suspend/resume
cycle the watcher swallows the node for 2s of `CLOCK_BOOTTIME`: the waking
power press arrives here too, and would otherwise instantly re-suspend.

**The suspend-script contract.** On trigger, `gt-sleepmon` `SIGSTOP`s every
live descendant of the launch.sh tree root — found by walking `/proc/*/stat`
ppid chains rather than matching by name — execs `$SYSTEM_PATH/bin/suspend`
with a fixed env (`SYSTEM_PATH`/`LD_LIBRARY_PATH` set explicitly, `PATH`
pinned to the real system directories so the pak's own busybox wrappers
can't shadow whatever `suspend` calls internally), waits for it to exit,
then `SIGCONT`s the tree. On the way out, the launcher's `cleanup()` reaps
the watcher by its recorded PID plus a `/proc/*/comm` scan for
`gt-sleepmon` — a bare `killall` never matches through the pak's busybox
wrapper shadow (the F15 lesson) — so a leaked watcher can't keep suspending
NextUI after the port exits.

**The audio wedge, and why only close+reopen recovers it.** The h700 BSP
kernel wedges any ALSA PCM that was open across a suspend-to-RAM cycle: the
stream stays `RUNNING` with the DMA engine dead, and — unlike a
well-behaved ALSA driver — it never delivers `-ESTRPIPE` to tell the app to
recover. A drained or XRUN'd stream re-wedges the same way on the next
resume, so there is no recovery available at the PCM-state level; only a
full `snd_pcm_close`+`snd_pcm_open` re-initializes the DMA/codec path. The
port process itself never gets a signal telling it to do this, so the fix
sits underneath it: `libasound_module_pcm_gt_suspend.so`
(`assets/gt-alsa-suspend.c`) is an ALSA `ioplug` proxy between the port and
the real hardware PCM. On every write it compares
`CLOCK_BOOTTIME − CLOCK_MONOTONIC` against the value captured when its
slave was last opened — monotonic time freezes across a suspend but
boottime doesn't, so a jump past 0.5s means a suspend happened — and
closes+reopens the slave before writing if so.

**The asound.conf lock/hooks discovery.** NextUI's stock `/etc/asound.conf`
locks the five h700 codec output controls (`LINEOUT Switch`, `SPK Switch`,
both output-mixer switches, and digital volume) via `ctl_elems` hooks with
`lock true`, which re-fire and reassert those values whenever their PCM is
opened. `gt-asound.conf` copies that exact hook chain into
`pcm.gt_stock_hooks`, so the suspend-proxy's slave reopen doesn't just
recover the DMA path — it also re-fires the same routing hooks NextUI
itself relies on, restoring codec output routing after resume rather than
just raw playback.

**The hook-clobber discovery, and why the config must be self-contained.**
The first cut of `gt-asound.conf` included `/usr/share/alsa/alsa.conf` and
then redefined `pcm.!default` to point at the proxy, on the assumption that
a later definition in the env-supplied file would win. It doesn't: this was
proven on the device — a `type null` slave override was silently ignored,
and `aplay -v`'s chain dump showed the stock hooks chain still in effect.
The reason is alsa.conf's own `@hooks` node, which loads `/etc/asound.conf`
*after* the entire `ALSA_CONFIG_PATH` file has been parsed — so the stock
`pcm.!default` always applies last and clobbers any override written
earlier in that file, regardless of textual order. Layering "system config
then ours" cannot work through `ALSA_CONFIG_PATH` on this alsa-lib.

The fix, also device-proven (`aplay -v` shows "gt suspend-safe proxy" as
the chain head), is for `gt-asound.conf` to skip the include entirely and
define everything a port's ALSA client needs on its own: the routing chain
below, plus a `ctl.hw` stanza — normally supplied by `/usr/share/alsa/
alsa.conf` — that the `ctl_elems` hook needs to open `hw:0`; without it the
hook fails with "Invalid CTL hw:0". `pcm.default` (no `!`, since there is no
stock definition left to override) is then routed straight through the
suspend proxy. `ALSA_CONFIG_PATH` is pointed at this `gt-asound.conf`
(templated from `files/gt-asound.conf` with `@PAK_DIR@` substituted at
launch), so this is transparent to every port that just opens ALSA's
`"default"` device. One consequence of this design: ports see *only* this
config, so stock alsa.conf device names like `pcm.playback_hp` are not
visible to them — nothing currently uses them, so this is a non-issue today
but worth knowing before adding a port-side device selector.

This copy is a hand-maintained snapshot, not a generated one: if a future
NextUI build ever changes the control names, lock values, or slave PCM in
the stock `/etc/asound.conf` default chain, `files/gt-asound.conf`'s
`pcm.gt_stock_hooks` must be updated to match or the suspend-proxy's reopen
will restore the wrong (stale) routing — this now matters even more since
there is no fallback to the system file to catch a stale drift underneath
it.

**The poll path must lie, or SDL dies (gate-discovered).** The first cut
forwarded the slave's poll fds and revents verbatim and relied on the
boottime-delta check in the transfer callback alone. The device gate
(Pizza Tower, second wake) showed why that isn't enough: when the app is
waiting for buffer space at the moment errors surface, recovery starts from
`snd_pcm_wait`, not from a write. The suspended slave wakes `poll()` with
`POLLERR`; alsa-lib sees an error revent while the ioplug frontend still
reports `RUNNING` and turns it into `-EIO`; SDL2's ALSA backend treats an
error `snd_pcm_recover` can't fix as a device disconnect
(`SDL_OpenedAudioDeviceDisconnected`) and its audio thread never writes
again — permanent silence no later wake can cure (observed live: audio
thread idling in `nanosleep`, slave PCM parked in `SUSPENDED`, `appl_ptr`
frozen). The first wake had recovered only because that cycle's first
post-resume action happened to be a plain write, which reached the transfer
callback's reopen. The fix: `poll_revents` never surfaces a dead slave's
error bits — for a missing/suspended/XRUN slave, a detected boottime jump,
or any `POLLERR/POLLHUP/POLLNVAL`, it reports `POLLOUT` instead, so the
app's next write lands in the transfer callback where the reopen cure
lives; and `prepare`/write errors fall back to a full reopen before any
error is allowed to reach the app. OpenAL-soft (Balatro) masked all of
this in round A because its backend retries rather than disconnecting —
every SDL-audio engine (GameMaker via FMOD_SDL, native SDL2, FNA) was
exposed.

**The pointer must go through XRUN, not fake an empty ring
(gate-discovered, take two).** The first repair had the pointer callback
report an empty ring (delay 0) for a dead slave, so a stale full-buffer
delay couldn't park the app in `poll()`. Celeste (FNA→SDL2) showed why
that can't work: the ioplug pointer interface is modulo `buffer_size`,
where "empty" and "full" are the *same position* — an app frozen with an
exactly-full ring computes a delta of zero from the empty-ring report,
`avail` stays 0, and the writer spins forever on an always-ready `poll()`
(observed live via on-device gdb: `ALSA_PlayDevice` → `avail_update` →
`snd_pcm_state` ioctl loop, ~100% CPU, no reopen ever reached). The
correct route is the idiomatic ioplug one: for a non-live or post-suspend
slave the pointer returns a negative error, ioplug flags the frontend
`XRUN`, the app's standard `snd_pcm_recover(-EPIPE)` calls `prepare`, and
the prepare callback performs the reopen. Ring fullness is irrelevant on
that path.

**Capture is not supported.** The routed `"default"` only implements the
playback (`SND_PCM_STREAM_PLAYBACK`) side of the `ioplug` interface, so any
port that opens `"default"` for capture gets `-ENOTSUP` instead of the stock
chain's behavior — a no-op today since no installed port records audio, but
worth knowing before adding one.

**Blocklist opt-out.** Sleep support is on by default for every port. A
launcher filename listed in the pak-shipped `files/gt-sleep-blocklist.txt`,
or in the user's own
`$USERDATA_PATH/PORTS-portmaster/use-sleep-blocklist`, disables both the
watcher spawn and the ALSA proxy for that port — the same
default-list-plus-user-override shape as F25's remap list and F34's HUD
blocklist.

**Never-poweroff.** Ports have no autosave, so a suspend failure is
deliberately non-fatal: `gt-sleepmon` logs the `suspend` script's exit
code, resumes the frozen tree anyway, and keeps playing. Escalating to a
poweroff on failure was considered and rejected — losing unsaved progress
to a sleep hiccup would be worse than just staying awake.

## Configurable controller layout: Nintendo vs Xbox A/B/X/Y (F48)

**Why.** Which physical button a game's abstract "A" maps to was previously
fixed and inconsistent across port classes: clean SDL-GameController ports
picked up whichever `gamecontrollerdb.txt` variant a hidden marker file
selected (xbox by default), while shim-driven ports used a separate,
independently-tuned table. Nothing was user-facing and the two paths could
silently disagree. F48 replaces both with one config value that every port
class consults.

**Config keys (`$EMU_DIR/config/config.json` — PortMaster's own config
file; `$EMU_DIR` = `.../PORTS.pak/PortMaster`).**

- `gt-controller-layout` — global default, `"nintendo"` or `"xbox"`.
- `gt-port-layout` — optional per-game override, an object mapping a
  launcher filename (`ROM_NAME`, e.g. `"Sonic 1.sh"`) to `"nintendo"` or
  `"xbox"`.

**Resolver precedence (`files/gt-controller-layout.sh`, high→low).**

1. per-game: `gt-port-layout[ROM_NAME]`, if present and a valid value;
2. global: `gt-controller-layout`, if present and a valid value;
3. legacy: a `nintendo*` marker file in `PORTS-portmaster` → `nintendo`
   (kept for back-compat; redundant now that the factory default is
   already `nintendo`);
4. factory default: `nintendo`.

Every read fails safe to the next tier — missing config file, missing key,
malformed JSON, or an unrecognized value all fall through rather than
aborting a launch. `run_port` resolves once per launch and both exports the
result (`GT_CONTROLLER_LAYOUT`) and applies it to the active
`gamecontrollerdb.txt` (`set_controller_layout`); `run_portmaster_gui` does
the same `gamecontrollerdb.txt` step (global only) before pugwash starts,
so the GUI's own SDL pad matches whatever the toggle last set.

**Port-class coverage — one resolved value, every launch path.**

| Class | Examples | Mechanism |
|---|---|---|
| Clean SDL GameController | most ports | `gamecontrollerdb.txt` swap (`set_controller_layout`) |
| gptk/evdev-synth ports | BYTEPATH, Tunics!, Sonic 1/2, Lasagna Boy, Road Invaders, The Starlit Escape | the input-remap shim reads `GT_CONTROLLER_LAYOUT` and swaps `gt_button_slot()`'s a↔b / x↔y output |
| Custom launcher (evdev) | OpenCrossing / Animal Crossing | the same shim change, via the armhf build (`gt-input-remap.armhf.so`) |
| GUI confirm/back | PortMaster-GUI itself | two `patch_pylibs` helpers — `gt_patch_platform_layout.py` adds `PlatformTrimUI.loaded()` (drives `WANT_XBOX_FIX`/`WANT_SWAP_BUTTONS` from the config key) and `gt_patch_optionscene_layout.py` adds the "Controller Layout" toggle to `OptionScene` (writes the key, calls `save_config()`) |
| Per-game stored mapping | Cave Story (Evo) `settings.dat` | covered by F49 — see below |
| Self-configuring (opaque) | LÖVE / `apply_button_map` ports (Balatro, etc.) | excluded by design — see F50 below |

> The clean-SDL row covers ports that read the shared
> `SDL_GAMECONTROLLERCONFIG_FILE` we swap. Ports that export their **own**
> inline `SDL_GAMECONTROLLERCONFIG` — the PortMaster `apply_button_map` /
> LÖVE-runtime pattern, sourced from a per-game `controller-map.txt` the port
> writes from its own in-game button setup — override that file, so the swap
> never reaches them. They're the self-configuring (opaque) class, excluded
> by design (F50), not the clean-SDL row — and a different class from Cave
> Story's `settings.dat`, which F49 now conforms directly.

**Factory-default flip: xbox → nintendo.** The RG SP's face buttons are
printed with Nintendo labels, so `nintendo` (A = the physically-A/right
button) is now the out-of-the-box default, matching what's printed on the
hardware. No config migration is needed: both the GUI and `launch.sh`
resolve the same way when `gt-controller-layout` is absent, so an existing
install with no key already resolves to the new default. A per-game
`gt-port-layout` entry lets a specific game stay on the other layout if
needed.

**Round 1 (this feature) vs the follow-up round.** Round 1 covered: the
global toggle in the PortMaster GUI, every port class above except
opaque-binary-config ports, and per-game overrides via `config.json`
(read-only — nothing in the GUI wrote `gt-port-layout` yet). The follow-up
round shipped as **F49** (Cave Story's `settings.dat` now conforms to the
resolved layout on launch) and **F50** (a per-game toggle in the GUI itself,
on `PortInfoScene`'s X button, plus a visibility fix for the global toggle) —
see both below. LÖVE / `apply_button_map` ports (Balatro and similar) stay
out of scope, not as unfinished work but as an **explicit exclusion**: they
persist their own `SDL_GAMECONTROLLERCONFIG`, captured from the player's own
button presses in the port's first-run wizard, which is meant to override
ours.

**Polarity confirmed on device (RG SP, 2026-09-01).** The *global* polarity
shipped correct — the shim's a↔b/x↔y swap sense and the GUI's
`WANT_SWAP_BUTTONS` sense both needed no flip. Every class agreed at the gate:
Nintendo = confirm/"A" on the physical-A/right face, Xbox = the bottom face —
across the GUI, a clean SDL port (Celeste), the shim ports, OpenCrossing, and a
per-game override. Two ports needed a per-port **gptk** correction (not a global
flip): Sonic 1/2 and Animal Crossing had gptk button conventions authored for
the pre-F48 static layout, so their `a`/`b` (and, for Animal Crossing, `x`/`y`)
bindings were swapped to the Nintendo baseline and now let the shim drive the
layout dynamically.

## Cave Story (Evo): face buttons now follow the resolved layout (F49)

*Superseded on NextUI rc11 by [F65](#nextui-rc11-one-fixed-pad-layout-on-every-h700-model-f65): the rc10 button numbering described here no longer applies.*

F39 shipped Cave Story (Evo) an RG SP-correct `settings.dat` with a fixed
JUMP/FIRE binding (JUMP → raw index 4/bottom, FIRE → raw index 3/right — an
xbox-style pairing). F48 then made the confirm-button layout configurable
everywhere else, but nxengine-evo reads the **raw SDL joystick** and binds
actions to button *indices* baked into that file — the same reason F39
existed in the first place — so neither F48's `gamecontrollerdb.txt` swap
nor the input-remap shim's a↔b/x↔y translation reaches it. Cave Story stayed
locked to F39's xbox-style pairing regardless of the resolved layout.

**The fix.** `assets/gt-nxengine-conform-layout.sh` (staged to `files/`)
byte-patches the two face-button fields directly, using the binding-record
layout F39 already documented (magic `NXS7`@0, 24-byte records @36, `jbut`
is field 1 of a record): `JUMP.jbut` at offset 136 (`36 + 4×24 + 4`, JUMP is
enum index 4) and `FIRE.jbut` at offset 160 (`36 + 5×24 + 4`, FIRE is enum
index 5).

- `nintendo` → JUMP=3 (right), FIRE=4 (bottom)
- `xbox` → JUMP=4 (bottom), FIRE=3 (right)

`run_port` runs it immediately after the F48 layout resolves and after F39
installs the base blob (anchored on `export GT_CONTROLLER_LAYOUT="$gt_layout"`),
scoped to the `nxengine-evo` GAMEDIR.

Idempotent via a sidecar stamp, `.gt-h700-layout`, next to `settings.dat`:
relaunching with the same layout is a no-op and leaves the file
byte-identical. The stamp is written only once both `dd` writes actually
succeed, so a swallowed write failure (read-only fs, disk full) can't leave
a stale stamp that skips re-patching on the next launch. The script also
refuses to touch a file that doesn't start with `NXS7`, and only rewrites
the two 4-byte `jbut` fields — resolution and every other binding
(directions, Strafe, weapon switch, Inventory, Map, Esc) are untouched, so a
player's in-game rebinds survive a same-layout relaunch.

**Factory-default note.** F48's factory default flipped to `nintendo`, but
F39's shipped blob predates F48 and is xbox-style (JUMP=bottom, FIRE=right).
A fresh Cave Story install is now conformed to `nintendo` on first launch,
matching every other port's out-of-the-box layout.

## Per-game controller layout in the GUI, and a more visible global toggle (F50)

F48 shipped a per-game override (`gt-port-layout` in `config.json`), but
nothing in the GUI wrote it — changing a single game's layout meant hand-
editing the config file. F50 adds a control to PortMaster's own UI for that,
and fixes a visibility gap in the global toggle F48 shipped alongside it.

**Per-game control (`src/gt_patch_portinfo_layout.py`).** Adds a control to
`PortInfoScene` — the screen showing a port's details — on its free **X**
button:

- For a normal installed port, X cycles Default → Nintendo → Xbox, writing
  `gt-port-layout["<launcher>.sh"]` in `config.json` (`Default` removes the
  key; an emptied map is removed entirely). This is the same key F48's
  resolver already reads at launch, so nothing changes on the read side.
- For a self-configuring `apply_button_map` port (Balatro-class — see
  below), X shows a `message_box` disclaimer instead of cycling. This is a
  cycling-X-button-plus-disclaimer design, not a sub-scene.
- Gated to installed ports.

**Global toggle visibility.** The "Controller Layout" toggle F48 added to
`OptionScene` sat at the bottom of the options list. F50 moves it up under
the first "Interface" section header, so it's visible without scrolling.

**Balatro-class exclusion — by design, not a gap.** Ports using PortMaster's
`apply_button_map` / `BUTTON_MAP_FILE` pattern (Balatro and similar
LÖVE-runtime ports) export their **own** inline `SDL_GAMECONTROLLERCONFIG`,
captured from the player's own button presses in the port's first-run
wizard. That config deliberately overrides ours — overriding it is the
whole point of the wizard. These ports are governed by their own captured
mapping, not the global or per-game layout, and are excluded from
remapping **by design**: there is no runtime transform to write for them,
and the GUI shows the disclaimer above instead of a cycling control that
would have nothing to act on. `build/build-pak.sh` carries a guard comment
next to the F48 resolve block warning against adding a `controller-map.txt`
transform for these ports for exactly this reason.

## One pak, many h700 devices: the device profile (F51)

Everything in this pak keys on NextUI's `h700` platform, which several
Anbernic devices share — but four constants were pinned to the RG SP's
hardware. F51 keys them on NextUI's `$DEVICE` SKU token instead:

- **PortMaster device pin.** `launch.sh` resolves a per-device profile: the
  harbourmaster device name written to `$HOME/.config/.DEVICE`, plus the
  panel size exported as `GT_PANEL_W`/`GT_PANEL_H` — on the common path, so
  the GUI, `run_port`, and everything a port sources (including
  `device_info.txt`) all inherit it. Two token generations are handled. The
  current NextUI-h700 build emits family buckets (its launch script maps
  `RG34xx*`→`rg34xx`, `RG35xx*`→`rg35xx`, `RG40xx*`→`rg40xx`,
  `RGcubexx`→`cube`, unknown models→`rg40xx`; the RG SP is `rgsp` —
  device-verified) — each bucket is geometry-uniform, so `rg35xx` →
  `rg35xx-plus` 640×480, `rg40xx` → `rg40xx-h` 640×480, `cube` → 720×720,
  `rg34xx` → `rg34xx-h` 720×480. The wiki's exact SKUs are also arms for
  newer builds: `rg34xxsp` → `rg34xx-sp` 720×480 (the 2.14.0 harbourmaster
  knows this profile: 2 sticks);
  `rg35xxh`/`rg35xxplus`/`rg35xxpro`/`rg35xxsp`/`rg40xxh`/`rg40xxv`/`rg28xx`
  → their 640×480 profiles; `rgcubexx` → nearest profile `rg34xx-h` with
  true 720×720 panel exports (harbourmaster has no CubeXX profile). An
  unknown or absent token — including a NextUI build that doesn't export
  `$DEVICE` — falls back to `rg34xx-h` 720×480, the RG SP profile: exactly
  the pre-F51 behavior. (RAM is live-detected on both code paths, so profile
  RAM never matters — both RG34XXSP RAM revisions report correctly.)
- **Resolution fallback.** `device_info.txt`'s 640×480 fallback (taken when
  its `sdl_resolution` probe fails) now reads
  `${GT_PANEL_W:-720}`/`${GT_PANEL_H:-480}`.
- **Sonic render width (F41).** Computed as `240×W/H` — 360 on 720×480, 320
  on 640×480 — instead of a literal 360.
- **Sleep trigger (F47).** `gt-sleepmon` no longer assumes the power key
  lives on `/dev/input/event0`: it scans `/dev/input` for the node whose
  `EV_KEY` capability includes `KEY_POWER` (`EVIOCGBIT`, the same discovery
  pattern as the shim's Menu-device scan), falling back to event0.

Only the RG SP is device-verified; the other arms follow the NextUI-h700
wiki's token list. The controller tables became device-keyed in F52/F53
(below). Still out of scope: RG28XX's rotated panel, and the ALSA
suspend-proxy chain is a copy of the RG SP's stock output chain.

## Stick-equipped devices: input class and per-class tables (F52)

*Superseded on NextUI rc11 by [F65](#nextui-rc11-one-fixed-pad-layout-on-every-h700-model-f65): the rc10 button numbering described here no longer applies.*

Every button table in the pak was measured on the RG SP: the two SDL
controller-DB lines, the shim's raw-index remap, the HUD's Menu-echo
swallow, and the F45 evdev-code table. The first non-RG-SP probe log — an
RG34XXSP, captured with the GT Probe pak on NextUI's own SDL — showed the
difference is small and exact. Its `ANBERNIC-keys` node carries **two extra
evdev codes**, 313 (`BTN_TR2`, the L3 click) and 316 (`BTN_MODE`, R3).
NextUI's SDL enumerates the node's codes in ascending order after the three
keyboard-type codes (ESC, Vol−, Vol+ at b0–b2), so those two codes push
L2/R2 from b12/b13 to **b13/b14**, Menu's `KEY_GOTO` echo from b14 to
**b16**, and put L3/R3 at b12/b15; faces, shoulders, Select, Start, Menu
and the hat d-pad are identical. The SDL GUID is identical too, so a
controller-DB line cannot tell the devices apart.

What a stick device got from the pak before F52: L3 acted as L2, L2 as R2,
and **R2 was dead in every port** — the HUD's Menu intercept, preloaded
everywhere, swallowed raw index 14 unconditionally because on the RG SP that
is the Menu echo.

- **Input class.** `launch.sh` reads `/proc/bus/input/devices`, takes the
  `js0` record's `B: KEY=` bitmap word for codes 256–319 (fifth word from
  the right) and classifies it: `dff000000000000` = `plain` (RG SP),
  `1fff000000000000` = `sticks`. It exports `GT_INPUT_CLASS` on the common
  path and logs `gt-h700: input class <class> (js0 key word <word>)`.
  Anything else — missing node, unrecognized word — is `plain` plus a
  warning asking for a probe run: exactly the pre-F52 behavior. GT Probe,
  the measurement pak the warning names, is not published yet — an issue
  quoting the `gt-h700:` lines (the bracketed key word in particular) is
  what actually adds a device. (The RG40XX-V, listed by harbourmaster with
  one stick, may be such a third layout.) It reads a `cat` copy of the proc
  file, never the file itself: busybox `read` polls fd 0 before every byte,
  and `/proc/bus/input/devices` only polls readable on input hotplug, so a
  direct `read` loop hung `launch.sh` forever (found at the RG SP gate).
- **Controller DB per class.** The build stages four files:
  `gamecontrollerdb_{nintendo,xbox}.txt` (unchanged) and
  `gamecontrollerdb_{nintendo,xbox}_sticks.txt` — the same upstream DB with
  the measured stick line (`lefttrigger:b13,righttrigger:b14,leftstick:b12,
  rightstick:b15,leftx:a0,lefty:a1,rightx:a2,righty:a3`). Upstream's
  `set_controller_layout` picks the `_sticks` copy when the class says so;
  the F48 layout choice composes with it.
- **Shim tables.** `gt-input-remap.so` loads the class once and switches its
  raw-index remap (stick table: 12→L3 slot 9, 13→L2, 14→R2, 15→R3 slot 12,
  park at 17) and the Menu-echo swallow index (14 → 16). The F45 evdev path
  now maps evdev code → slot directly, which is device-independent by
  construction. gptk `l3`/`r3` names bind the stick clicks.
- **Reporting switch.** A `use-input-debug` flag file exports the shim's
  debug variable for every port, so a report carries the full trace.

Wording for users and the volunteer-gate decision: stick support ships
**experimental**, gated only by the RG SP regression run; the design and
measured tables are in `docs/superpowers/specs/2026-09-01-stick-device-support-design.md`.

## Stick-equipped devices: analog sticks as keys, and a truthful profile (F53)

*Superseded on NextUI rc11 by [F65](#nextui-rc11-one-fixed-pad-layout-on-every-h700-model-f65): the rc10 button numbering described here no longer applies.*

With the buttons right, two things kept stick devices second-class: the
shim ignored every analog line in a gptk (the RG SP has no sticks), and the
F51 profile pinned the `rg34xx` family bucket to the stickless `rg34xx-h`,
so device_info reported zero sticks and ports picked their d-pad control
schemes.

- **Analog synthesis** (shim, stick class only, gptk loaded). Mirrors
  gptokeyb (PortsMaster/gptokeyb source): the eight `left_analog_*` /
  `right_analog_*` lines, gptokeyb's built-in defaults when a line is absent
  (left W/S/A/D, right End/Home/Left/Right), a present line with an unknown
  name or the `\"` placeholder clears the default, a `mouse_movement_*`
  value marks that stick mouse-driven and it synthesizes nothing, and the
  unified `deadzone` (default 15000, deflected when |value| ≥ deadzone) is
  honored. Axes a0–a3 are left X/Y, right X/Y with negative = up/left. Each
  axis keeps its last direction; edges go through the same
  release-before-press helper the evdev d-pad uses, the first key replaces
  the axis event and the rest ride the existing stash, and every key is
  mirrored into the polled keystate (F31), so polling games see the stick
  too. Unmapped axes pass through untouched.
- **Profile.** The pin tries the exact SKU from `RGXX_MODEL` first (this
  NextUI build exports it: `RGSP`, `RG34xxSP`, …), then the `DEVICE`
  bucket, then the RG SP default; the input class upgrades the ambiguous
  buckets (`rg34xx` + sticks → `rg34xx-sp`, `rg35xx` + sticks → `rg35xx-h`,
  unknown + sticks → `rg34xx-sp`). Exact SKUs are never overridden.
- **Hatch.** `use-stickless` exports `GT_ANALOG_STICKS=0`, which
  device_info applies after upstream's own per-device case — ports see zero
  sticks and pick their d-pad schemes again, while harbourmaster keeps the
  true profile and the button tables are untouched.

Not done, deliberately: mouse emulation, deadzone modes/scaling, key
repeat and hold-state modifiers in the shim; a third key layout (RG40XX-V)
until a probe log exists.

## In-game HUD: brightness and volume went blank after the rc10 update (F57)

The status overlay (F34/F35) reads live brightness and volume from NextUI's
shared settings block at `/dev/shm/SharedSettings`; battery comes from sysfs
and the clock from libc, so those two are independent of that file. keymon
writes the block, and the HUD reads two `int32` fields from it — brightness at
byte offset 4, volume at byte offset 16 — offsets first confirmed on hardware
in 2026-08 by nudging each setting and re-dumping.

NextUI `h700-rc10` changed the size of that block. The rc8-era build exposed a
132-byte structure; rc10 exposes a 64-byte one (dumped live: a smaller layout
keymon writes). The HUD's decoder guarded on the *exact* old size (`len < 132`
→ give up), so against the 64-byte block it bailed on every sample and reported
both values as unknown — the brightness and volume gauges went dead while
battery and time kept updating. That asymmetry (only the two SharedSettings-fed
values break) is the signature of this regression.

The two fields did not move — re-confirmed on an rc10 device by nudging:
brightness still at offset 4 (9 → 0 on full-down), volume still at offset 16
(0 → 11 at about half). Only the block's overall size changed. Fix: the decoder
now guards on a *minimum* length that covers the volume `int32`
(`GT_SS_MIN_LEN = offset 16 + 4 = 20 bytes`) rather than the exact struct size.
It accepts the 64-byte rc10 block and the 132-byte rc8 block alike (reading the
same two offsets in each), stays correct across a future resize as long as
those offsets hold, and the minimum also prevents an out-of-bounds read of the
volume field on a truncated block. The read buffer is unchanged; a smaller file
is simply a short read.

Out of scope: NextUI tracks speaker and headphone volume as separate fields
gated by a jack flag; the HUD reads the speaker field (offset 16) as it always
has, so with headphones plugged the gauge shows the speaker level. That was the
pre-existing behavior and is unchanged here.

## gptokeyb passthrough: SDL finally sees the virtual keyboard (F54)

Seven of the nine ports in GitHub issue #1 are keyboard-and-mouse games that
every other PortMaster device serves through gptokeyb's virtual uinput
keyboard. F8 recorded that this device "never reaches games" on NextUI and
F26/F31/F53 built an SDL-layer re-implementation of gptokeyb inside the shim
for allowlisted ports — keyboard only, no mouse. The 2026-09-04 device pass
on the RG SP found the actual mechanism: NextUI's SDL2 fork is a
**no-libudev** build, and upstream SDL's evdev keyboard/mouse layer
(`SDL_EVDEV_Init`) then opens **only** the devices listed in the environment
variable `SDL_EVDEV_DEVICES` (`class:path,…`; class bits 1 = mouse,
2 = keyboard). Nothing on NextUI sets it, so no keyboard or mouse device was
ever opened — gptokeyb's output was dead not because the platform could not
deliver it, but because SDL was never told where it was. Exporting
`SDL_EVDEV_DEVICES=2:/dev/input/event3` (gptokeyb's node that day) in the
BYTEPATH launcher, with the shim's synthesis off, made BYTEPATH's
event-driven menus **and** its polled gameplay work through gptokeyb itself.

- **Mechanism.** The shim (`gt-input-remap.so`, preloaded into every h700
  port) interposes `SDL_Init`/`SDL_InitSubSystem`. On the first call that
  brings up the video subsystem it scans `/proc/*/comm` for a process named
  `gptokeyb`/`gptokeyb2`; if one exists it reads `/proc/bus/input/devices`
  whole and picks the `Fake Keyboard` stanza with the highest `inputN`
  (input numbers are monotonic for the boot, event numbers are recycled —
  Doom Engines starts gptokeyb twice), waiting up to 2 s for the node to
  appear — but only when some gptokeyb was started with a mapping (`-c`).
  Without one (and without its text-input mode, `TEXTINPUTINTERACTIVE` /
  `TEXTINPUTPRESET`) gptokeyb creates no virtual keyboard (native-controller
  ports run it only as the Select+Start quit watcher: Balatro, Deltarune,
  Mina the Hollower, …), so the shim checks once and moves on instead of
  holding the game's start for 2 s (device-gate finding). It then exports
  `SDL_EVDEV_DEVICES=3:/dev/input/eventN` — class 3, keyboard **and** mouse,
  because gptokeyb's node advertises `EV=7`/`REL=3` even for a keyboard-only
  gptk — unloads the gptk so every synthesis path goes quiet, and calls the
  real init. Ports without a keyboard-producing gptokeyb (Animal Crossing's
  pak launcher runs it without a mapping, F45) fall back to the shim's
  synthesis unchanged. A launcher that sets `SDL_EVDEV_DEVICES` itself is
  respected.
- **Policy.** Passthrough is **on for every h700 port**, opt-out via the
  pak-shipped `files/gt-passthrough-blocklist.txt` or the user's
  `use-passthrough-blocklist` (`GT_PASSTHROUGH=0`), the same shape as the HUD
  and sleep blocklists. The F25/F26 allowlist (`gt-remap-ports.txt` /
  `use-remap-ports`) is unchanged: it still gates the joystick index remap and
  arms the synthesis fallback, which passthrough suppresses at runtime.
- **Sonic 1/2 are blocklisted.** Their launchers do run gptokeyb — against
  the very `sonic.gptk` this pak overlays (F43) — but gptokeyb's face naming
  follows the controller database while the shim's follows the v1 index remap
  plus the F48 layout flip, and whether physical A/B land on the same keys is
  unverified. They keep the device-verified synthesis path; migrating them is
  a follow-up.
- **Launchers that overwrite `LD_PRELOAD`.** Doom Engines runs its engine
  with `export LD_PRELOAD="$GAMEDIR/libs/hacksdl.so"`, dropping every pak shim.
  `run_port` now snapshots the final pak preload chain as `GT_LD_PRELOAD`
  right before executing the launcher and, inside the F32 mtime window, runs
  `files/gt-preload-append.sh`, which rewrites every overwrite-style
  `export LD_PRELOAD=` line to prepend that snapshot (idempotent; append-style
  and commented lines untouched; a launcher without such a line is never
  rewritten). `copy_game_scripts` reverts launchers each GUI session; the
  hook re-patches every launch.
- **`ANALOGSTICKS` alias.** OpenTTD's launcher picks its gptk as
  `openttd.gptk.$ANALOGSTICKS`, a name this PortMaster's `device_info.txt`
  never set (it has only `ANALOG_STICKS`), so gptokeyb got `openttd.gptk.`
  and loaded no mapping — the d-pad mouse was dead. Invisible until F54 let
  gptokeyb input reach games (device-gate finding). The pak's
  `device_info.txt` now also exports `ANALOGSTICKS`, equal to the resolved
  `ANALOG_STICKS` (after the `use-stickless` override).
- **Shim hygiene.** The constructor no longer logs — it used to print
  "loaded"/"HUD enabled"/"keyboard synthesis on" from every preloaded child
  (bash, tee, gptokeyb). The announcement now prints in the game only:
  "loaded" / "HUD enabled" at the first SDL entry point, the passthrough
  decision and the synthesis state once that decision exists at the video
  init. (The first version printed everything at the first SDL call; LÖVE
  initialises events and joystick before video, so BYTEPATH logged "not
  evaluated" and "keyboard synthesis on" while running under passthrough —
  caught by the device gate.) Joystick opens follow synthesis only (the
  HUD toggle has been evdev-driven since F35), so the line "opened N/N
  joystick(s) for key synthesis" is true again and a keyboard-only game under
  passthrough receives no joystick events it would not get on any other
  device.

**Known limits.** Engines that load SDL through `dlopen`+`dlsym` (mono/FNA)
bypass every preload interposer and get no passthrough (no known
gptokeyb-tier port uses them). An engine whose video comes up inside SDL
without an `SDL_Init` / `SDL_InitSubSystem` call carrying `SDL_INIT_VIDEO`
(e.g. relying on `SDL_CreateWindow`'s implicit video init) gets no
passthrough either; its log then reads `gptokeyb passthrough not evaluated
(no SDL video init seen)`. A stale gptokeyb left by a crashed launcher is
attached to, as it would be on any other CFW. `unset LD_PRELOAD` in a
launcher is not repaired. SDL's evdev keyboard layer may mute the console
keyboard while a game runs; the mode was observed restored after a normal
exit (`K_UNICODE`).

**Device gate (RG SP, NextUI h700-rc10, 2026-09-27/28):** run on the final
F54 build; every result below is from the port's `PORTS.txt` plus play on the
device.

1. BYTEPATH, allowlisted — **PASS**: menus and ship normal; one
   `gt-input-remap: loaded`, `gptokeyb passthrough -> 3:/dev/input/event3
   (synthesis off)`, `keyboard synthesis off (gptokeyb passthrough)`, no
   joystick-open line; the game held the Fake Keyboard (`event3`) open.
2. BYTEPATH, removed from the allowlist — **PASS**: same play, passthrough
   line present, no `Enabling input remap`.
3. Tunics! — **PASS**: title/movement/menus fine, no doubled actions; log has
   both `Enabling input remap` and the passthrough line.
4. Sonic 1, blocklisted — **PASS**: `gptokeyb passthrough disabled
   (blocklisted) for Sonic 1.sh`, `keyboard synthesis on, 8 mapping(s)`;
   jump/pause as in v0.4.0.
5. OpenTTD mouse — **PASS**: d-pad moves the cursor, A clicks, B slows it.
6. OpenTTD text input — **PASS**: L2/R2 typed `-`/`=` into the Multiplayer
   player-name field. (Y is unassigned in the port's own gptk; X is forward
   Delete and could not be exercised with the text cursor at the end.)
7. Doom Engines — **PASS** (2026-09-28, on the merged 0.5.0 build with the
   F58/F63 library pins): Crispy Doom and GZDoom both play (the 0.5.0 device
   gate below); the engine's `log.txt` shows `gt-input-remap: loaded` and
   `gptokeyb passthrough -> 3:/dev/input/event3 (synthesis off)`. The engine
   picker attached too: its gptokeyb has no `-c` but the launcher exports
   `TEXTINPUTINTERACTIVE`, which makes gptokeyb create its keyboard anyway,
   and the single node check found it.
8. HUD toggle + sleep/resume during a passthrough port (BYTEPATH) — **PASS**:
   Menu toggles the overlay; power sleeps, power resumes with music.
9. Select+Start quit — **PASS**: ports quit, NextUI responsive.
10. Balatro — **PASS**: one press = one action. Its launcher runs gptokeyb
    without a mapping, so passthrough never engages there by design.

The gate found three defects, fixed on this branch before the final run: (a)
the announcement printed before LÖVE's video init decided, so BYTEPATH logged
"not evaluated" / "synthesis on" while running under passthrough; (b)
gptokeyb without `-c` made every such launch wait the full 2 s; (c)
OpenTTD's `$ANALOGSTICKS` gptk path (see the bullets above).

**Follow-ups.** Sonic 1/2 off the blocklist after a device check of
gptokeyb's face naming against the overlaid gptk; mouse synthesis as a
fallback only if a gptokeyb-less mouse port ever appears; upstream, NextUI's
SDL could scan `/dev/input` itself and make this step unnecessary.

## The sleep-proxy output was invisible to SDL's device enumeration (F55)

0.4.0's F47 routed every port's `default` PCM through the pak's suspend-proxy
plugin via a self-contained `ALSA_CONFIG_PATH` file. That file declared
`pcm.default` without a `hint {}` block — and alsa-lib's
`snd_device_name_hint()`, which is what SDL2's ALSA backend enumerates output
devices with, lists only hinted nodes (the stock `/etc/asound.conf` chain is
hinted; `defaults.namehint.showall` is never set in a self-contained file).
Result: SDL saw zero audio devices, `SDL_GetAudioDeviceName(0,0)` returned
NULL, and the EDuke32 family's `Xstrdup()` of it segfaulted at sound init —
Duke Nukem 3D, Blood, Redneck Rampage and PowerSlave all "closed immediately"
since 0.4.0 (issue #1). Device-proven with `aplay -L` (the same alsa-lib call):
nothing listed; with one `hint { show on description "…" }` inside
`pcm.default`, exactly `default` listed and still playing through the proxy.
Fix: that hint block. `tests/container-alsa-check.sh` now proves the
hinted/unhinted enumeration rule in the arm64 container.

## RG35XX Pro is a two-stick device (F56)

The F51 pin table folded `rg35xxpro` into the stickless `rg35xx-plus` arm, and
exact-SKU pins are deliberately never class-refined (F53), so the Pro — two
hall sticks, the sticks key set on `js0` — got a zero-stick profile and every
port chose its d-pad control scheme (issue #1's `PORTS.txt` showed the
mismatch). Fix: its own arm, `rg35xx-h`. Because this is exactly how a mispin
hides, the pin block now logs `gt-h700: WARNING: profile <p> has no analog
sticks but this pad reports sticks` whenever a stickless profile meets the
sticks class (the CubeXX, pinned `rg34xx-h` for its 720×720 panel, is exempt).

## Ports that read stdin hung on NextUI (F59)

NextUI starts paks with the serial console as stdin and `run_port` passed it
straight to the port; every other CFW hands ports `/dev/null`. ECWolf
(Wolfenstein 3D) ends up in its console IWAD picker — its launcher passes
`--data wl1` but ECWolf compares the extension case-sensitively against the
uppercase `VSWAP.WL1` FAT keeps, so nothing matches (an upstream launcher
bug) — and then blocks in `scanf()` forever: the "black screen" in issue #1
(gdb-attached on the RG SP; the game had drawn nothing yet). With `/dev/null`
the `scanf` fails and the picker returns the last set silently, exactly as on
other CFWs. Fix: `run_port` runs the port with `</dev/null`. Generic — any
port that prompts on stdin now gets EOF instead of a hang.

## gl4es ports crashed on the first frame: the fake EGL and NextUI's SDL (F60)

Quakespasm segfaulted the moment it started. `gdb` on the RG SP put the crash
at `MALI_GLES_SwapWindow` in NextUI's SDL fork (`SDL_maliopengles.c:73`),
calling address 0: the fork calls `egl_data->eglCreateSyncKHR` and
`->eglDestroySyncKHR` **unguarded**, resolving both through
`eglGetProcAddress` on whatever `SDL_VIDEO_EGL_DRIVER` names. gl4es ports point
SDL at gl4es's *fake EGL* stub (`libgl_default.txt` → `LIBGL_FB=2` → the
launcher's `SDL_VIDEO_EGL_DRIVER="$GAMEDIR/gl4es.aarch64/libEGL.so.1"`).
Quakespasm's stub predates gl4es's `eglDestroySyncKHR` and returns NULL for
unknown names; Jedi Outcast's newer stub exports it plus a catch-all
`eglStub`, and JO runs. Substituting JO's stub made Quakespasm play with its
own older `libGL.so.1` (the mix is device-proven). Bypassing the fake EGL is
not a fix: with the real Mali EGL these ports fail `SDL_CreateWindow` and hit a
*second* unguarded pointer in the fork's cleanup (`SDL_malivideo.c:396`).

Fix: the pak ships gl4es's fake EGL built from a pinned ptitSeb/gl4es commit
(`make gl4es-egl`, provenance in `assets/gl4es-libEGL.txt`), staged under
`lib/gl4es-egl/` — a subdirectory on purpose. `lib/` itself is on every port's
`LD_LIBRARY_PATH`, and upstream's own `files/lib.tar.gz` already carries a
top-level `libEGL.so.1` (an older gl4es fake EGL) that `launch.sh` unpacks
into the pak's `lib/` on the first boot after an install or unzip-over; a
top-level stub here would collide with that unpack. That build lane pins apt
to a snapshot.debian.org date and takes CMake from PyPI, since bullseye's
packaged CMake (3.18) predates the 3.19 the pinned gl4es commit needs.
`run_port` swaps the built stub into any `gl4es.aarch64/` or `gl4es/` dir
whose stub lacks the symbol (original kept as `.gt-orig`; idempotent; 32-bit
`gl4es.armhf/` never touched). Companion: PortMaster-New's Quakespasm 0.97.0
launcher dropped the `LD_LIBRARY_PATH` line every earlier version had, so its
bundled `libs.aarch64/` (libmad, libmikmod) was never searched and a fresh
install died at load on lib-poor CFWs; when a launcher sets no
`LD_LIBRARY_PATH` at all, `run_port` now prepends the port's own
`libs.aarch64`/`libs` dirs. Both
are upstream bugs (NextUI: guard the two pointers; PortMaster: refresh
Quakespasm's gl4es and restore its lib path).

## Launchers without `GAMEDIR=` were refused (F61)

`run_port` resolves the port folder from a `GAMEDIR=` line in the launcher and
otherwise refuses to run ("No GAMEDIR found … not executing game"). Fallout 1's
launcher declares `PORTDIR=` only (issue #1). Fix: fall back to `PORTDIR=`
when `GAMEDIR` is empty, restoring `run_port`'s own `$PORTDIR` around the eval.

## The armhf capability claim, and a stray `lscpu` (F62)

`device_info.txt` sets `DEVICE_HAS_ARMHF="Y"` when `/lib/ld-linux-armhf.so.3`
exists. The rc8-era NextUI-h700 image (the one the issue #1 reporter's logs
match) had that loader — and behind it exactly one 32-bit library,
`libc.so.6` — but `device_info.txt` still said `DEVICE_HAS_ARMHF="Y"`, so
armhf-only ports (`PORT_32BIT="Y"`, e.g. *Serious Sam: The First Encounter*)
installed and then died at load resolving the 64-bit `libdl.so.2` ("wrong ELF
class", issue #1). Found in the final review: harbourmaster doesn't read
`DEVICE_HAS_ARMHF` at all — `cpu_info_v2()` in its own
`pylibs/harbourmaster/hardware.py` works out armhf capability itself from
`/lib/ld-linux-armhf.so.3`, the same loader check `device_info.txt` makes, and
neither harbourmaster nor the PortMaster GUI reads this variable. So this fix
claims `Y` only when a 32-bit `libdl.so.2` exists next to the loader
(`/usr/lib/arm-linux-gnueabihf/` or `/lib/arm-linux-gnueabihf/`), correcting
the value port scripts see and the `device_info.txt` dump — but it does NOT
stop harbourmaster from listing armhf-only ports on pre-rc10 firmware. They're
still offered there and still fail to load the same way; stopping that would
need a patch to harbourmaster's own `cpu_info_v2`, a possible follow-up that
can't be device-tested on rc10 because rc10 has the libraries. Same edit also
silences the `lscpu` probe BaseOS can't satisfy (`lscpu: command not found`
headed every port log).

NextUI `h700-rc10` (found in the v0.5.0 device gate) ships a real armhf
userland — 14 libraries including libc/libdl/libm/libpthread/libstdc++, plus a
32-bit GL stack in `/usr/lib32` (libEGL, libGLESv2, libSDL2, libmali). On rc10
the probe therefore keeps `Y`, correct by design; no armhf-only harbourmaster
port has been tried on rc10 yet. F45's pak-hosted runtime for Animal Crossing
is not a harbourmaster install and is unaffected either way.

Not done, deliberately: generalizing F45's pak-hosted armhf runtime to every
`PORT_32BIT` port (a possible future phase — the runtime would need the full
32-bit GLES stack the Serious Sam class expects).

Planned as F57; renumbered because the rc10 HUD fix took that ID on main.

**Device gate (2026-09-28, RG SP, NextUI h700-rc10).** PASS: Wolfenstein 3D
(F59); Quakespasm (F60 — both the gl4es-EGL swap and the library-path fallback
fired on first launch, and stayed idempotent on repeat launches); Doom
Engines, both Crispy Doom and GZDoom (F58, F63); Luanti with Mineclonia (F58,
F64; the first world load takes a few minutes); Duke Nukem 3D with the Atomic
data (F55 — menu, game and sound all confirmed; the port only walks with the
analog stick, so it can't move on the stickless RG SP, which is the port's own
control design, not a pak bug); and the regression check on Celeste
(sleep/resume keeps its sound), BYTEPATH, Tunics!, and OpenTTD (d-pad mouse,
the F54 `ANALOGSTICKS` alias). Not device-tested: F56 (no RG35XX Pro on hand),
F61 (Fallout 1 not owned), and F62's pre-rc10 path (on rc10 the probe prints
`Y`, which is correct).

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
  scan is `tr -cs 0-9a-f "\n" | grep -x`: busybox `grep` alone needs ~2.8 s
  on the 8 MB library, the tr pipe 0.13 s. Only the two migrations below
  read it.
- **Cave Story (F39/F49):** the shipped `settings.dat` is renumbered (records
  4–10: `4,3,5,9,10,7,8` → `0,1,2,6,7,4,5`) and stamped `.gt-h700-rc11`. An
  install made before rc11 is translated once — all 28 bindings, per input
  class — and buttons rc11 lacks (ESC, the echo, L2/R2) become unbound. The
  migration then clears `.gt-h700-layout`, so the conform below re-applies
  JUMP/FIRE. The layout conform writes rc11 values (Nintendo JUMP=1/FIRE=0,
  Xbox JUMP=0/FIRE=1).
- **Balatro-class ports:** `files/gt-button-map-rc11.sh` moves a
  `$BUTTON_MAP_FILE` whose first mapping line names the pre-rc11 built-in ID
  (`190000000100000001000000????0000`) to `<file>.pre-rc11`, so the port's
  own wizard asks once. The launcher is never edited (F32).

Unaffected: the evdev HUD toggle (F35), sleep (F47), gptokeyb passthrough
(F54), the input-class detection (still drives the device profile and the
F53 gate), and Animal Crossing (its own 32-bit SDL; its gameplay input is
evdev, and its L2/R2 now reach the same gptk keys through the trigger
table).

**Device gate (2026-09-29, RG SP, NextUI h700-rc11).** Measurement pass
(Task 0, 2026-09-28): pad GUID `…016e01`, 15 buttons / 6 axes / 1 hat,
built-in mapping as the patch source says; B, A, Y, X, L1, R1, Select, Start
= b0–b7, Menu = one b8 (no ESC, no echo), Vol−/Vol+ = b13/b14, L2/R2 on
a2/a5, d-pad on hat 0; nothing on b11/b12. Gate, installed by unzip-over, all
nine items PASS: (1) launch log shows `NextUI pad layout rc11`; (2) PortMaster
GUI navigation, confirm/back and the Controller Layout toggle on both
layouts; (3) Celeste on Nintendo and Xbox; (4) BYTEPATH, Tunics! (no doubled
actions) and OpenTTD's L2/R2 zoom through gptokeyb passthrough, Select+Start
quits; (5) Sonic 1 on the synthesis path, B only jumps, and with `l2`/`r2`
temporarily added to its gptk each trigger press produced exactly one
synthesized key down/up from the axis events; (6) a Menu tap toggles the
overlay without the game reacting, Menu+Vol changes brightness; (7) Cave
Story's 0.4.0-era settings migrated once (stamp written, all 28 bindings
equal to the shipped rc11 file), JUMP/FIRE follow each layout, and rebinds
made after the migration (Inventory → north, Map → Vol+) persist across a
layout change; (8) Balatro's map recorded on the pre-rc11 ID moved to
`controller-map.txt.pre-rc11` unchanged, the port asked for its button check
exactly once and recorded the new map on the rc11 ID, the launcher's mtime
was untouched; (9) Animal Crossing plays, L2/R2 rotate the camera, sleep and
resume from power and lid keep sound. Stick devices: host-tested only (no
hardware), EXPERIMENTAL label kept.

## Pak messages never appeared on NextUI rc10 and later (F66)

The pak shows its progress messages through josegonzalez's
[minui-presenter](https://github.com/josegonzalez/minui-presenter), pinned at
its h700-nextui build: "Starting, please wait...", "Unpacking files, please
wait..." on the first launch after an install or update, "Applying changes,
please wait..." after the GUI, and "Starting <game>...". NextUI `h700-rc10`
stopped exporting four settings functions from
`.system/h700/lib/libmsettings.so`: `GetMute`, `GetMutedBrightness`,
`GetMutedColortemp` and `GetMutedVolume` became header-only stubs. The 0.13.0
build imports all four. Symbols bind lazily, so it started, then died on its
first `GetMute` call with `minui-presenter: symbol lookup error: … undefined
symbol: GetMute`, which `PORTS.txt` logs for every message. Nothing in
`launch.sh` waits on a message, so the pak kept working behind a blank
screen. The worst case was a fresh install's first launch, which unpacks about
73 MB with no sign of progress.

Fix: pin minui-presenter 0.13.4, the upstream release built against rc11. On
rc11, `LD_BIND_NOW=1` resolves every symbol 0.13.4 imports (0.13.0 fails on
`GetMutedVolume`). `tests/test-37-presenter-pin.sh` keeps the pin at 0.13.4 or
newer.

**Device check (2026-09-30, RG SP, NextUI h700-rc11).** With 0.13.4 in
`bin/`, the PortMaster GUI showed "Starting, please wait..." and then started
normally, "Applying changes, please wait..." appeared on exit, and Celeste
launched and played. Each time the presenter was gone before the next program
drew, and there was no F14-style repaint wedge.

Known gap: `replace_progressor_binaries` copies `files/minui-presenter` next to
a port's `progressor` only when no copy is there (upstream behavior). Ports
installed under 0.5.0 or earlier therefore keep their 0.13.0 copy, and their
own progress screens (such as Celeste's first-launch repack) stay blank until
that copy is removed.

## Ports that link libcurl: a slim libcurl built for rc11 (F67)

Sonic 3 AIR (issue #2) exited straight back to the menu with
`./sonic3air_linux: error while loading shared libraries: libcurl.so.4: cannot
open shared object file`. The port ships only its binary and expects the
firmware to provide libcurl, as ArkOS, ROCKNIX and the other big CFWs do.
NextUI-h700 has no libcurl anywhere. Upstream's Doom 3 (dhewm3) links it the
same way. `LD_TRACE_LOADED_OBJECTS` on the RG SP (rc11) showed `libcurl.so.4`
as Sonic 3 AIR's only unresolved library.

Sonic 3 AIR uses curl for one thing: the optional download of its remastered
soundtrack, which the port already bundles. The game carries on if curl can't
start. A do-nothing stub would therefore get it to launch, but every other
port's curl features would stay dead, and Ubuntu's own `libcurl4` pulls in
about 20 more libraries (nghttp2, libssh, LDAP, Kerberos, GnuTLS…) that the
device lacks.

Fix: the pak ships its own `lib/libcurl.so.4`, built by `make libcurl`
(`build/libcurl.sh`) from a pinned curl release tarball (version and SHA-256
in the `Makefile`):

- **HTTP and HTTPS only.** Every other protocol and optional dependency is
  off. The library needs `libssl.so.3`, `libcrypto.so.3`, `libz.so.1` and
  glibc, all of which rc11 ships (`libz.so.1` is also in the pak's `lib/`).
- **Built on Ubuntu 22.04, not the pak's usual bullseye.** rc11's userland is
  jammy (its `libc.so.6` is byte-identical to jammy's), and bullseye's
  OpenSSL is 1.1. The base image is pinned by digest. Ubuntu's snapshot
  archive serves no arm64, so apt itself is not date-pinned; the compiler and
  header versions are recorded in `assets/libcurl.txt` instead.
- **Ubuntu's symbol version.** Ports built on Debian or Ubuntu bind libcurl's
  functions under the version `CURL_OPENSSL_4` (Sonic 3 AIR imports
  `curl_easy_init`, `curl_easy_setopt`, `curl_easy_perform` and
  `curl_easy_cleanup` under it); `--enable-versioned-symbols` with the OpenSSL
  backend produces the same.
- **rc11's CA bundle.** libcurl ignores `SSL_CERT_FILE`, so the path
  `/etc/ssl/certs/ca-certificates.crt` is compiled in as the default.
- **Straight into `lib/`**, which is on every port's `LD_LIBRARY_PATH`, so no
  launcher changes. A port that bundles its own libcurl (Enigma, F1 Spirit)
  still loads its own, because the port's `libs/` comes first. Upstream's
  `files/lib.tar.gz`, unpacked into `lib/` on the first boot after an
  install, has no libcurl to overwrite it with.

The build script refuses to write the library unless it is aarch64, named
`libcurl.so.4`, needs exactly the four libraries above, exports the easy API
under `CURL_OPENSSL_4` and needs no glibc newer than 2.35.
`tests/test-38-libcurl.sh` checks the committed library (architecture, symbol
version, no extra dependencies), its provenance against the `Makefile` pins,
and the staging line.

**Device check (2026-09-30, RG SP, NextUI h700-rc11).** With the pak
installed by unzip-over, `LD_TRACE_LOADED_OBJECTS` on `sonic3air_linux`
resolved `libcurl.so.4` from the pak's `lib/` (the committed hash) and
`libssl.so.3`/`libcrypto.so.3` from the system, with nothing unresolved. An
HTTPS request through the same library to `sonic3air.org` verified against
rc11's CA bundle. Sonic 3 AIR (with the Steam `Sonic_Knuckles_wSonic3.bin`)
launched, found its ROM, and played with working sound and controls.

Known gap: if a later NextUI ships its own libcurl, the pak's copy still wins,
because the pak's `lib/` comes before the system directory — the same as every
library the pak ships.

## Engines that load SDL2 privately crashed at start (F68)

Half-Life (the `half-life` port, Xash3D FWGS) went straight back to the menu on
every launch, even with the game files in place. The port writes its own log,
`Roms/Ports (PORTS)/.ports/Half-Life/log.txt`, and it showed
`Sys_Warn: SDL_Init failed: ` with an empty reason, the engine falling back to
dedicated-server mode, then `Crash: signal 11 … at (nil)`.

The port's `xash3d` launcher links only libdl and libc and loads the engine
with `dlopen("libxash.so", RTLD_NOW)`, without `RTLD_GLOBAL`. `libxash.so` links
SDL2, so SDL2 lands in that private scope too. The pak preloads
`gt-input-remap.so` into every port (it carries the HUD, the gptokeyb
passthrough and the keyboard fallback), so the engine's calls to `SDL_Init`,
`SDL_PollEvent` and the rest reach the shim first. The shim looked up the real
functions with `dlsym(RTLD_NEXT, …)`, which searches only the global scope, and
every lookup returned NULL. `SDL_Init` returned -1 without SDL ever running,
hence the empty reason, and `SDL_PollEvent` called address 0. This is older than
0.5: 0.3.0 and 0.4.0 already forwarded `SDL_PollEvent` and `SDL_GL_SwapWindow`
this way, and F54's `SDL_Init` wrapper only moved the failure earlier.

Fix: every lookup goes through one resolver. It still tries `RTLD_NEXT` first,
so every port that resolved before resolves exactly as before. Only when that
returns NULL does it take the copy that is already loaded,
`dlopen("libSDL2-2.0.so.0", RTLD_NOW | RTLD_NOLOAD)` (for `eglSwapBuffers`,
`libEGL.so.1` or `libEGL.so`), and look the symbol up there. `RTLD_NOLOAD`
never loads anything new. A wrapper whose real function still can't be found
no longer calls NULL: event polls return no events, the present calls are
skipped, `SDL_Init` returns -1, and the log gets one
`gt-input-remap: cannot resolve real <name>` line.

`tests/test-39-shim-symbol-lookup.sh` fails if a bare `dlsym(RTLD_NEXT, "…")`
comes back. `tests/container-sdl-scope-check.sh` (Docker, not part of
`make test`) loads a fake engine the way Xash3D does, under the preloaded shim
and against stand-in SDL2 and EGL libraries. Before the fix it reproduced the
device log (`SDL_Init` -1, then a segfault). Now every call reaches the
stand-ins, the `RTLD_GLOBAL` control run is unchanged, and with stand-ins the
fallback can't find either, the shim degrades and logs instead of crashing.

**Device check (2026-10-01, RG SP, NextUI h700-rc11).** Only
`lib/gt-input-remap.so` was swapped for the F68 build; the Half-Life launcher
was the unmodified one. Half-Life (current Steam `valve` files) reached the
menu, started a new game with working controls, toggled the HUD and quit
cleanly (Mali-G31 GLES2, SDL ALSA audio). Regression runs: BYTEPATH (gptokeyb
passthrough to `event3`), Sonic 1 (keyboard synthesis, joystick opened) and
Mina the Hollower (GL HUD) all played as before. No `cannot resolve real` line
appeared in any of the four logs. Before the fix, putting SDL2 into the global
scope (`LD_PRELOAD` of the system `libSDL2-2.0.so.0` behind the shim) was the
one change that let Half-Life start, which is what pinned the cause on the
shim's lookup.

Known gap: the three port-specific shims (`gt-fmod-audio`, `gt-gles3-profile`,
`gt-sdl-audio-init`) still use bare `RTLD_NEXT`. They load only for their own
port classes (FMOD ports, the gothic/machismo engines, Sonic), which load SDL
the usual way.

