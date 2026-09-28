### New
- **Keyboard-and-mouse games get their controls.** Games that rely on
  PortMaster's keyboard and mouse emulation now receive it (for example
  OpenTTD, where the d-pad moves the mouse pointer).

### Fixes
- **Games that list sound devices before playing start again** (Duke Nukem 3D
  and other games built on its engine).
- **Quake (Quakespasm) no longer crashes at launch.**
- **Games that sat on a black screen waiting for console input now start**
  (Wolfenstein 3D).
- **Doom Engines and Luanti (Minetest) start** — the system libraries they
  were missing are now bundled.
- **Luanti's on-screen text shows properly** instead of "invalid UTF-8
  string".
- **The in-game overlay shows brightness and volume again** after the NextUI
  rc10 update.
- **Games whose start script names its folder differently are no longer
  refused** (reported with Fallout 1; not yet confirmed on a device).
- **RG35XX Pro is recognised as a two-stick device** (not yet confirmed on a
  real RG35XX Pro).

### Changes
- ⚠️ **The keyboard-and-mouse emulation is on by default.** If a game that
  worked before now reacts twice or to the wrong button, you can switch it off
  for that game — see "Switching the automatic keyboard path off for a game"
  in the README.

### Upgrading from v0.4.0
- Unzip the new `PORTS.pak.zip` over your SD card, replacing files when
  asked.
- Installed games, saves and settings are untouched.
- Games copied over from another device's SD card may be outdated builds. If
  one still misbehaves, let PortMaster update or reinstall it first.
