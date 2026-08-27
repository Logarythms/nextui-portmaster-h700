# h700 compatibility fixes

This document explains, fix by fix, what breaks when you run an unmodified
[ben16w/minui-portmaster](https://github.com/ben16w/minui-portmaster) PortMaster
pak on an Anbernic RG SP (Allwinner h700 SoC) under NextUI, why it breaks, and
what this repository's build script changes to fix it. The upstream pak targets
the tg5040 family of devices (TrimUI Brick/Smart Pro); the h700 family has a
thinner system image, a different SDL2 build, and a different GPU driver stack,
so several of its assumptions don't hold.

Fix IDs (F1–F36) below match the internal numbering used while these were
found and verified on real hardware; they're kept here mainly so a diff or an
issue report can refer to a specific one. A closing section records the ports
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

## Roms launcher trigger file (F2)

NextUI shows the PortMaster GUI entry in its Ports list only when a
specific placeholder file exists in the Roms directory. Reproducing that
file as an empty, zero-byte placeholder is not enough — NextUI's own
canonical trigger is a small (102-byte) comment-only shell script, and
the entry silently fails to appear without that exact content. Fix: write
the real comment-only file instead of an empty one.

## Controller mapping (F4)

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
the patcher's expected path exists.

## `pm_platform_helper: command not found` (F19)

2026-era port scripts call `pm_platform_helper` unguarded; the runtime
version this pak pins (2025.03) predates it. In current upstream
PortMaster the function is an effective no-op (a dialog-pipe close plus
`printf ""`), so the fix appends a faithful stub to the pak's
`control.txt` — which `launch.sh` re-installs into the live control
folder at every launch, making the stub self-healing as well.

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
are handled by the state-polling half added in F31.

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
  stay exactly as opt-in as before (`GT_INPUT_REMAP=1`, gated by the
  `gt-remap-ports.txt` allowlist) — universal preload does not change input
  behavior on a port that isn't on that list. `GT_HUD_DEBUG=1` traces the
  sample/draw/swap path the same way `GT_INPUT_REMAP_DEBUG` does for remap.
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

### Unreleased

**Fixes**
- F37: native OpenGL ES 3 for gothic/machismo ports — Mina the Hollower now boots
- F38: in-game HUD renders on native-ES3 contexts (sampler-object fix)

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
  the ROCKNIX device, which carries the 32-bit stack.
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
