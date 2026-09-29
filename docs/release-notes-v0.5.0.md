### New
- **Updated control mappings for [NextUI rc11][rc11]. Previous releases are not supported anymore and will have broken controls.**
- **Adds support for Keyboard/Mouse games** (e.g. OpenTTD).

### Fixes
- **Game fixes:** Duke Nukem 3D and games on its engine, Quake, Wolfenstein 3D, Doom Engines, Luanti.
- **HUD fixed** on the latest BaseOS/NextUI releases.
- **RG35XX Pro** is now recognised as a two-stick device. Untested.

### Changes
- ⚠️ **Needs [NextUI rc11][rc11] or newer.** On older versions most games get the wrong buttons.
- ⚠️ **Keyboard-and-mouse emulation is now on by default.** If a game reacts twice or to the wrong button, switch it off for that game (see [the README][opt-out]).
- Balatro needs to re-map its controls on first launch.

### Upgrading from v0.4.0
- Make sure you're running [NextUI rc11][rc11] or newer.
- Unzip the new `PORTS.pak.zip` over your SD card, replacing files when asked.
- Installed games, saves, and settings are untouched.

[rc11]: https://github.com/pvaibhav/NextUI/releases/tag/h700-rc11
[opt-out]: https://github.com/Logarythms/nextui-portmaster-h700/blob/v0.5.0/README.md#switching-the-automatic-keyboard-path-off-for-a-game
