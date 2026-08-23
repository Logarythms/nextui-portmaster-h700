# nextui-portmaster-h700

[PortMaster](https://portmaster.games/) for the **Anbernic RG SP** running [NextUI](https://github.com/LoveRetro/NextUI) — a repackage of [ben16w/minui-portmaster](https://github.com/ben16w/minui-portmaster) with the fixes the RG SP's h700 chip needs. (The official pak targets other hardware and won't run here as-is.)

## ⚠️ Read this first

- **Experimental. Provided as-is, with no support and no warranty — use at your own risk.**
- **Only the Anbernic RG SP is confirmed working.** Other devices may not work at all.
- **Do not ask the official PortMaster team for support.** This is an unofficial, modified build — open an issue here instead.
- **Made with AI assistance.**

## Install

You'll need the device's SD card — browse it on the device, or take it out and use a card reader on your computer.

1. Download **`PORTS.pak.zip`** from the [Releases](../../releases) page.
2. Unzip it. You'll get a folder named **`PORTS.pak`**.
3. On the SD card, open **`Emus/h700/`** and copy the **`PORTS.pak`** folder into it.
4. On the SD card, open **`Roms/Ports (PORTS)/`** and create a text file named **`0) Portmaster.sh`** containing exactly these two lines:
   ```
   # Portmaster.sh
   # This file will signal to open the PortMaster GUI when placed in the Roms directory.
   ```
   ⚠️ The file must **not** be empty, or PortMaster won't appear.
5. Put the card back, restart the device, and open **PortMaster** under **Ports**.

## Using it

- **PortMaster's self-update is disabled by this build.** Updating would replace the h700-patched runtime with the official one, which won't run on the RG SP — so the update prompt never appears, and even a manually triggered update is a no-op. New pak versions come as releases of this repository instead.
- **Buttons use the Xbox layout** (A / B / X / Y in their Xbox positions).
- Not every port runs — see below.

## Confirmed working games

Confirmed working out of the box on the RG SP:

- [2048 Plus](https://portmaster.games/detail.html?name=2048plus) (the *Plus* version — **not** the regular 2048)
- [Apotris](https://portmaster.games/detail.html?name=apotris)
- [Balatro](https://portmaster.games/detail.html?name=balatro)
- [Deltarune](https://portmaster.games/detail.html?name=deltarune)
- [Downwell](https://portmaster.games/detail.html?name=downwell)
- [Undertale](https://portmaster.games/detail.html?name=undertale)
- [VVVVVV](https://portmaster.games/detail.html?name=vvvvvv)

Each link is the game's PortMaster page, with what you need to provide (e.g. purchased game files) and where to put it.

**Games not on this list may still work** — this is only what's been verified so far. The list will grow as more are confirmed; if you get another one working, please open an issue.

## What works

Gamepad input on this platform has limits, so ports fall into three groups:

- ✅ **Out of the box** — ports using SDL's GameController API. LÖVE-based games also work.
- ⚠️ **With a little setup** — ports that read raw joystick input, and keyboard-style ports (the ones whose title screen asks for a key like SPACE): both are handled by the built-in input translator — see [Fixing games that ignore your buttons](#fixing-games-that-ignore-your-buttons).
- ❌ **Not yet** — ports that *poll* keyboard or button state instead of listening for presses.

Full details: [`docs/h700-fixes.md`](docs/h700-fixes.md).

## Build from source

Needs a POSIX shell with `curl`, `zip`/`unzip`, `tar`, `ar`, `awk`, `sed`, `shasum`, and `file` — no Docker. (Tests also need `python3` and a C compiler.)

```sh
make pak     # builds dist/Emus/h700/PORTS.pak.zip from pinned, checksum-verified upstream
make test    # runs the shell test suite
```

The input-remap shim ships prebuilt in `assets/`; rebuilding it (`make shim`) needs Docker.

## Fixing games that ignore your buttons

Some games start fine but then don't react to any button — often the title
screen even asks for a keyboard key ("PRESS SPACE"). Those games were written
for a keyboard. On most PortMaster devices a background helper silently turns
gamepad presses into keystrokes, but NextUI on the RG SP never delivers that
helper's keystrokes to games. This pak therefore includes its own translator
that does the same job from the inside.

**It's automatic, per game.** Every affected port ships a little mapping file
(ending in `.gptk`) written by the port's author that says which button
should press which key — for Tunics! that's A = Space, Start = W, d-pad =
arrow keys, and so on. When the translator is enabled for a game, that game's
own mapping file is picked up automatically. You never have to write a
mapping yourself.

Games on the built-in list (currently: **Tunics!**) need no setup at all.

### Turning it on for another game

If a game starts but ignores every button, try this:

1. Power the RG SP off and put its SD card into your computer.
2. On the card, open the folder `.userdata/h700/PORTS-portmaster/`.
   Folders starting with a dot are hidden by default — turn on
   "show hidden files" (Windows: View menu; Mac Finder: Cmd+Shift+.).
3. Create a plain text file there named exactly `use-remap-ports`
   (no `.txt` at the end).
4. Inside it, write the game's launcher filename exactly as it appears in
   the card's `Roms/Ports (PORTS)` folder, for example:

   ```
   Some Game.sh
   ```

   One game per line. Spelling, capitalization, and spaces must match.
5. Save the file, put the card back in, and start the game normally.

Changed your mind? Remove the game's line (or delete the file) and it's back
to how it was. Nothing else on the card is touched.

**If this makes a game playable for you, please open an issue with the
game's name** — it can then join the built-in list, and the next release
fixes it for everyone out of the box.

Two honest limitations: a game with no `.gptk` mapping file only gets its
button numbering fixed (that alone cures some games); and a few games read
the keyboard in a way the translator can't reach yet ("state polling") —
those stay broken for now.

<details>
<summary>Technical details</summary>

The translator is <code>lib/gt-input-remap.so</code>, an <code>LD_PRELOAD</code>
shim the launcher injects only for listed ports. It always corrects this
device's shifted SDL joystick button indices (hardware-measured table), and —
when the launcher finds a <code>.gptk</code> in the port's game directory —
replaces mapped joystick events with synthesized <code>SDL_KEYDOWN/KEYUP</code>
at the SDL event layer, honoring the simple <code>name = key</code> subset of
the gptk format. The pak-shipped default list lives at
<code>files/gt-remap-ports.txt</code>; the GUI has a separate opt-in flag file
<code>use-remap</code> (normally not needed — the GUI has its own mapping fix).
Full story: <a href="docs/h700-fixes.md">docs/h700-fixes.md</a>.
</details>

## Credits & license

Builds on [ben16w/minui-portmaster](https://github.com/ben16w/minui-portmaster), [PortMaster](https://portmaster.games/), and [josegonzalez/minui-presenter](https://github.com/josegonzalez/minui-presenter). MIT-licensed (see [`LICENSE`](LICENSE)); bundled upstream components keep their own licenses (see [`NOTICE`](NOTICE)).
