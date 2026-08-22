# h700 compatibility fixes

This document explains, fix by fix, what breaks when you run an unmodified
[ben16w/minui-portmaster](https://github.com/ben16w/minui-portmaster) PortMaster
pak on an Anbernic RG SP (Allwinner h700 SoC) under NextUI, why it breaks, and
what this repository's build script changes to fix it. The upstream pak targets
the tg5040 family of devices (TrimUI Brick/Smart Pro); the h700 family has a
thinner system image, a different SDL2 build, and a different GPU driver stack,
so several of its assumptions don't hold.

Fix IDs (F1–F16) below match the internal numbering used while these were
found and verified on real hardware; they're kept here mainly so a diff or an
issue report can refer to a specific one.

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

## Ports re-patch themselves on every single launch (F12/F13)

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
2. **Works with per-port help.** Ports that read raw joystick/event
   input directly (rather than through the GameController API) see
   button indices shifted by this device's particular hardware layout.
   These are fixable per port, either through the port's own in-game
   remapping options, or by opting into this repository's bundled input
   index-remap shim (see the README) for that one port.
3. **Currently unsupported.** Ports that depend on the gamepad-to-keyboard
   translation layer, and ports that poll raw controller button state
   directly (as opposed to reading discrete button-press events), have
   no working input path yet on this platform. Fixing this tier needs a
   more invasive shim (intercepting state-polling calls and injecting
   synthetic keyboard events) that is not yet part of this repository.

The gamepad-to-keyboard translation tool itself does not interfere with
tier-1 input and is left enabled by default.
