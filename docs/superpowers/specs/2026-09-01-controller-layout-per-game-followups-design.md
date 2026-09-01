# Controller layout — per-game GUI, Cave Story, and toggle visibility — design

Follow-up round to F48 (`2026-08-31-controller-layout-config-design.md`). F48
shipped the global Nintendo/Xbox layout as a single `config.json` source of
truth driving every port class, plus a per-game override *readable* from
`config.json`. This round closes the two items F48 deferred and adds one polish
item the device gate surfaced.

## Goal

Let a user pick a controller layout **per game** from the PortMaster GUI (not
just globally, and not only by hand-editing `config.json`); make the global
toggle **discoverable**; and make **Cave Story** honor the layout like every
other non-self-configuring port.

### In scope

- **A — per-game layout in the GUI.** A control on the per-port screen
  (`PortInfoScene`) that writes/clears the per-game override F48 already reads
  (`gt-port-layout["<launcher>.sh"]`), with three states: **Default (follow
  global) / Nintendo / Xbox**.
- **A (disclaimer) — self-configuring ports.** For ports that manage their own
  mapping in-port (the `apply_button_map` class, e.g. Balatro), the per-game
  screen shows an explanatory message instead of a toggle. Detected generically,
  no hardcoded list.
- **B — Cave Story (`nxengine`) layout-conform.** Swap the two face-button
  bindings in its binary `settings.dat` to match the resolved layout, at launch,
  idempotently, preserving all other settings.
- **B — Balatro-class exclusion, made explicit.** Documentation + a guard
  comment; no runtime transform (these ports already win by construction).
- **C — global toggle visibility.** Move the `OptionScene` "Controller Layout"
  toggle up from the bottom of the list.

### Out of scope

- Any layout work for the five ports confirmed already-covered by F48 (below) —
  Apotris, 2048 Plus, Dusklight, Mina the Hollower, Pizza Tower. No code.
- Other opaque-binary-config ports beyond Cave Story. The Cave Story transform
  is a **known per-port mapping**, not a generic `nxengine`/binary mechanism; a
  future such port is a new, separate item.
- A `playstation`/third layout value. The resolver and DB remain binary
  (nintendo | xbox), unchanged from F48.

## Current state (what exists today)

- **F48 core.** `set_controller_layout <nintendo|xbox>` (launch.sh:422) copies
  `files/gamecontrollerdb_<layout>.txt` → `$EMU_DIR/gamecontrollerdb.txt`
  (exported as `SDL_GAMECONTROLLERCONFIG_FILE`). The resolver
  `files/gt-controller-layout.sh` (staged from `assets/`) resolves per-game >
  global > legacy marker > factory **nintendo**; the launch.sh `run_port` block
  (injected by build-pak.sh ~955) calls it with `$ROM_NAME` and exports
  `GT_CONTROLLER_LAYOUT`. `run_portmaster_gui` resolves the global value; two
  `patch_pylibs` helpers drive the GUI's own A/B (`gt_patch_platform_layout.py`)
  and add the global toggle (`gt_patch_optionscene_layout.py`).
- **Why the five other ports already switch (device-confirmed 2026-09-01).**
  These ports do `export SDL_GAMECONTROLLERCONFIG="$sdl_controllerconfig"`, but
  this pak's `get_controls` (trimui/control.txt) is a splash-only stub and
  **`$sdl_controllerconfig` is never assigned anywhere** — so the inline var is
  empty and SDL falls back to `SDL_GAMECONTROLLERCONFIG_FILE`, i.e. the
  F48-swapped `gamecontrollerdb.txt`. Pizza Tower's own `swapabxy` is gated on a
  `swapabxy.txt` that does not exist and, even if it ran, swaps the *empty*
  inline var (a no-op) — the file still governs. Confirmed switching on Apotris,
  2048 Plus, Mina, Pizza Tower; Dusklight is the same LÖVE class as the first two.
- **Why Balatro does NOT switch (and shouldn't).** `Balatro.sh` defines
  `apply_button_map()` (reads `saves/controller-map.txt`, captured by the port's
  own first-run wizard) and exports it as an **inline** `SDL_GAMECONTROLLERCONFIG`
  *appended after* anything we set — so the user's captured mapping wins over our
  file. This is the user's deliberate choice; the layout toggle must not override it.
- **Why Cave Story does NOT switch.** `nxengine-evo` ignores SDL GameController
  entirely; it binds in-game *actions* to **raw joystick button indices** in
  `conf/nxengine/settings.dat`. F48's DB swap never reaches it. F39 ships a
  rebound blob (`assets/nxengine-evo-h700-settings.dat` →
  `files/nxengine-h700/settings.dat`), installed **once** by the
  `gt-h700-nxengine-settings` build-pak.sh block (marker `.gt-h700-settings`),
  deliberately not the always-overwrite F27 overlay so in-game rebinds survive.
- **GUI.** `PortInfoScene` (pugscene.py ~2016) is the per-port screen; it binds
  `A`=Install/Reinstall, `Y`=Uninstall, `B`=Back, `UP`=Show Info via
  `set_buttons` — **`X` is free**. `OptionScene` toggles are `cfg_data[...] =
  ...; hm.save_config()`. F48's `gt_patch_optionscene_layout.py` inserts the
  toggle immediately before the `self.tags['option_list'].list_select(0)` anchor,
  which appends it **last** in the list — hence bottom-of-list, needs scrolling.

## Approaches considered

- **A (per-game GUI).** (1) A cycling `X`-button on `PortInfoScene` whose label
  shows the current per-game state; (2) **an `X`-opened sub-screen** offering the
  three states (and hosting the disclaimer). Chosen: **(2)** — a sub-screen is
  the only clean home for the Balatro-class disclaimer, and reads clearly for a
  tri-state. Rejected (1): cramming Default/Nintendo/Xbox + a conditional
  disclaimer onto one button label is opaque.
- **B (Cave Story).** (1) F48's originally-anticipated "ship a second
  layout-swapped blob, pick by layout"; (2) **byte-patch the two `jbut` fields in
  the installed blob at launch, keyed to the resolved layout, idempotent via a
  sidecar stamp.** Chosen: **(2)** — swapping only the two face-button fields
  preserves resolution *and* any in-game rebinds; a whole-blob reinstall clobbers
  both. Both variants are already device-tested (F39). Rejected: interposing the
  shim (nxengine reads the raw joystick, which the shim deliberately does not
  translate; would also fight the hat handling).
- **Balatro class.** No runtime code — it is already excluded by construction.
  Make the decision explicit (docs + guard comment + GUI disclaimer).

## Architecture

### B1 — Cave Story `settings.dat` layout-conform

Extend F39's install path. After the base blob is present (F39 installs it once),
**conform the two face-button bindings to the resolved layout at launch**:

- **Semantics.** `JUMP` (enum 4) is Cave Story's primary action = SDL "A";
  `FIRE` (enum 5) = SDL "B". Matching the DB convention
  (`gamecontrollerdb_nintendo` `a:b3` right / `gamecontrollerdb_xbox` `a:b4`
  bottom):
  - **nintendo** → `JUMP.jbut = 3` (right/east), `FIRE.jbut = 4` (bottom)
  - **xbox** → `JUMP.jbut = 4` (bottom), `FIRE.jbut = 3` (right)  *(today's F39 blob)*
- **Format (F39-verified).** 964 bytes; 24-byte binding records at offset 36,
  each 6 LE int32 `key, jbut, jhat, jhat_value, jaxis, jaxis_value`. `jbut` is
  field 1 (record offset +4). Derived byte offsets — **verify against the real
  blob / `scratchpad/nxe/patch_settings.py` during implementation**:
  `JUMP.jbut` @ `36 + 4*24 + 4 = 136`; `FIRE.jbut` @ `36 + 5*24 + 4 = 160`.
- **Idempotency.** A sidecar stamp `conf/nxengine/.gt-h700-layout` records the
  last-applied layout. At launch: resolve layout; if stamp == resolved, do
  nothing (leaves res + in-game rebinds untouched); else byte-patch the two
  fields and rewrite the stamp. nxengine rewrites `settings.dat` from the
  *loaded* mappings, so our patch persists across the engine's own saves.
- **Wiring.** A new launch-time block (new build-pak.sh injector + a small
  `assets/` helper, e.g. `gt-nxengine-conform-layout.sh`), gated behind F39's
  existing install so the base blob exists first. Off the shim remap list
  (unchanged).
- **Accepted caveats (documented):** (1) flipping the layout overrides an in-game
  jump/fire rebind — all other settings preserved; (2) with F48's factory default
  now nintendo, a fresh Cave Story install conforms to **nintendo**, not F39's
  xbox.

### B2 — Balatro-class exclusion (documentation only)

- A note in `docs/h700-fixes.md`: ports carrying their own in-port controller
  config (the `apply_button_map`/`BUTTON_MAP_FILE` pattern) are governed by that
  config, not the global/per-game layout — by design.
- A guard comment beside the F48 launch.sh block so a future pass does not add a
  `controller-map.txt` transform that would fight the user's captured mapping.
- The user-facing half is the disclaimer in A.

### A — Per-game layout in the GUI

- **Entry point.** Bind `X` on `PortInfoScene` → push a small "Controller Layout"
  sub-scene. Delivered as a new `patch_pylibs` helper (mirrors F48's two:
  idempotent, marker-guarded, staged from `src/`, wired by a build-pak.sh
  injector on the same `platform.py portmaster_install` rail). Gate the control
  to installed ports (`'installed' in port_attrs`) — `PortInfoScene` also renders
  for store browsing, where a per-game key would target a not-yet-present launcher.
- **Normal port.** Three selectable states writing PortMaster's `hm.cfg_data`
  then `hm.save_config()`:
  - **Default (follow global)** → *remove* the port's key from `gt-port-layout`
    (resolver falls through to global). Absent map / absent key both mean default.
  - **Nintendo / Xbox** → set `gt-port-layout["<launcher>.sh"] = "<value>"`.
- **`apply_button_map` port.** Show the disclaimer instead of the states:
  *"This game sets up its controller in its own first-run screen. To change the
  layout, delete its saved mapping (controller-map.txt) and relaunch."* Detected
  by reading the installed launcher `.sh` for `apply_button_map` / `BUTTON_MAP_FILE`.
- **Config-key mapping.** The resolver keys on `ROM_NAME` = the launcher
  filename (`Balatro.sh`), but the GUI identifies a port by its PortMaster name.
  Resolve the launcher filename from harbourmaster's `port_info` installed-file
  list. **Verify the `port_info` structure during planning** (which field lists
  the installed `.sh`; behavior if a port ships more than one launcher — key on
  the primary/played one).

### C — Global toggle visibility

- In `gt_patch_optionscene_layout.py`, change the insertion anchor so the toggle
  lands **near the top** of `OptionScene`'s option list instead of immediately
  before `list_select(0)` (which appends last). Pick a stable early anchor (e.g.
  after the first existing `add_option`, or before a known option such as
  `trimui-port-mode`); assert placement in the test.

## Data flow

```
Per-game set (A):  PortInfoScene[X] → layout sub-scene → hm.cfg_data['gt-port-layout'][<launcher>.sh]
                   = nintendo|xbox  (or key removed for Default) → hm.save_config()
Launch (existing): run_port → gt-controller-layout.sh <ROM_NAME>
                   → per-game > global > legacy > nintendo → GT_CONTROLLER_LAYOUT + gamecontrollerdb swap
Cave Story (B):    run_port → (F39 install-once) → conform-layout.sh: stamp≠resolved?
                   → byte-patch JUMP/FIRE jbut in settings.dat → rewrite stamp
```

## Error handling / edge cases

- **Missing/malformed `port_info` launcher field** → the per-game screen falls
  back to showing only the global value read-only (or a "cannot determine port
  launcher" note); never writes a wrong key.
- **`config.json` missing `gt-port-layout`** → creating a per-game override
  creates the map; selecting Default on an absent key is a no-op.
- **Cave Story blob absent / wrong size / bad magic (`NXS7`)** → conform step
  no-ops and logs; never writes a truncated file.
- **Stamp present but `settings.dat` user-deleted** → F39's install-once
  re-installs the base blob (its marker also gone), then conform re-applies.
- **Unknown resolved value** → clamp to nintendo (as F48 already does).

## Testing (fixture-based, mirrors existing suites)

- **B1 (Cave Story):** extend `test-15-nxengine-settings.sh` — assert the
  conform block is staged/wired; behavioral: run conform on a fixture blob for
  each layout and assert the two `jbut` fields flip and nothing else changes;
  idempotency (stamp match → byte-identical); stamp rewrite on change.
- **A (per-game GUI):** new patch test (mirrors `test-27`/`test-28`) — the helper
  inserts the `X` binding + sub-scene, is idempotent, is confined to
  `PortInfoScene`, writes/removes the `gt-port-layout` key, and renders the
  disclaimer branch for an `apply_button_map` launcher.
- **A (key mapping):** unit-cover the port_info → launcher-filename resolution.
- **C (visibility):** update `test-28` to assert the toggle is placed at the new
  (early) anchor, not last.
- Sweep `grep -rn` for any test that greps the moved OptionScene insertion as a
  landmark (F48 R4/R5 lesson: editing a shipped/staged line breaks sibling tests
  that grep it).

## Device gate (RG SP — `ssh root@10.0.1.16`; reachable)

Build (`make pak`, needs network → dangerouslyDisableSandbox), install via
unzip-over, then verify on-device:

1. **A** — per-game screen: set a game to Nintendo, another to Xbox, one to
   Default; relaunch each and confirm A/B follow the per-game value and Default
   follows the global toggle. Confirm `config.json` `gt-port-layout` updated.
2. **A disclaimer** — Balatro's per-game screen shows the disclaimer, not a toggle.
3. **B** — Cave Story: flip layout, relaunch, confirm jump/fire swap physical
   buttons; confirm resolution + an in-game rebind of an unrelated key survive a
   no-op relaunch (stamp match).
4. **C** — the global toggle is visible in Options without scrolling.
5. **Regression** — a clean-SDL port (Celeste) and a shim port (Tunics!/Sonic)
   still switch; the five already-covered ports unaffected.

## Files touched

- `build/build-pak.sh` — new injectors for the Cave Story conform block and the
  `PortInfoScene` per-game patch; stage the new `assets/`/`src/` helpers.
- `assets/gt-nxengine-conform-layout.sh` (new) — Cave Story byte-patch + stamp.
- `src/gt_patch_portinfo_layout.py` (new) — per-game GUI sub-scene + disclaimer.
- `src/gt_patch_optionscene_layout.py` — change insertion anchor (C).
- `tests/test-15-nxengine-settings.sh` (extend), new per-game patch test,
  `tests/test-28-optionscene-layout-patch.sh` (update).
- `docs/h700-fixes.md` — F49 section (this round) + Balatro-class exclusion note;
  changelog entry.
- `README.md` — per-game layout + Cave Story bullets if user-facing.

## Process

- One feature branch (`controller-layout-followups`, off main `2d3b1f7`), one
  squashed commit at finish (docs fold in), per Camille's convention.
- **No push/tag** — main is already 4 ahead of origin, unpushed; Camille is
  bundling. This round joins the bundle; do not push/tag until he says.
- Device-gate before merge. Cave Story byte offsets and the harbourmaster
  `port_info` launcher field are the two facts to verify against reality before
  building the code that depends on them.
