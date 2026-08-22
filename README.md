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

- **Decline PortMaster's update prompt.** Updating replaces this h700 build with the official one, which won't run on the RG SP.
- **Buttons use the Xbox layout** (A / B / X / Y in their Xbox positions).
- Not every port runs — see below.

## Confirmed working games

Confirmed working out of the box on the RG SP:

- Balatro
- VVVVVV
- 2048 Plus (the *Plus* version — **not** the regular 2048)

**Games not on this list may still work** — this is only what's been verified so far. The list will grow as more are confirmed; if you get another one working, please open an issue.

## What works

Gamepad input on this platform has limits, so ports fall into three groups:

- ✅ **Out of the box** — ports using SDL's GameController API. LÖVE-based games also work.
- ⚠️ **With a little setup** — ports that read raw joystick input; fix via the port's own in-game remapping, or the optional [input-remap shim](#input-remap-shim).
- ❌ **Not yet** — ports that rely on PortMaster's keyboard-emulation layer, or that poll raw button state.

Full details: [`docs/h700-fixes.md`](docs/h700-fixes.md).

## Build from source

Needs a POSIX shell with `curl`, `zip`/`unzip`, `tar`, `ar`, `awk`, `sed`, `shasum`, and `file` — no Docker. (Tests also need `python3` and a C compiler.)

```sh
make pak     # builds dist/Emus/h700/PORTS.pak.zip from pinned, checksum-verified upstream
make test    # runs the shell test suite
```

The input-remap shim ships prebuilt in `assets/`; rebuilding it (`make shim`) needs Docker.

## Input-remap shim

Off by default. Some ports read raw controller indices and need them corrected — enabling the shim fixes those, but can break ports that were already fine. To turn it on, create an empty file named `use-remap` in the pak's userdata directory; delete it to turn it back off.

## Credits & license

Builds on [ben16w/minui-portmaster](https://github.com/ben16w/minui-portmaster), [PortMaster](https://portmaster.games/), and [josegonzalez/minui-presenter](https://github.com/josegonzalez/minui-presenter). MIT-licensed (see [`LICENSE`](LICENSE)); bundled upstream components keep their own licenses (see [`NOTICE`](NOTICE)).
