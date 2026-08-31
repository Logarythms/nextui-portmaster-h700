# Configurable controller layout (Nintendo / Xbox) — design

**Date:** 2026-08-31
**Status:** proposed (round 1)
**Repo:** nextui-portmaster-h700 (branch `controller-layout-config`, off `8882c79`)

## Goal

Let the user choose whether a game's abstract **A/B/X/Y** map to the RG SP's
face buttons in **Nintendo** layout (game "A" = the physically-A / right button,
matching the printed labels) or **Xbox** layout (game "A" = the bottom button).
Today this is effectively fixed and inconsistent across port classes — a "wild
jungle." The choice must be:

- a **changeable global default** that applies to every game, and
- settable from the **PortMaster GUI** (not only by editing files), with the
  GUI's own confirm/back honoring the same choice,
- **per-game overridable** — round 1 exposes this via config only; a GUI
  per-game control is a documented follow-up.

Camille's approved factory default: **Nintendo** (match the printed labels).

### In scope (round 1)

Single source of truth in PortMaster's `config.json`; global layout as a GUI
Options toggle; **all** the port classes below driven by the resolved value;
per-game override readable from `config.json`; the GUI's own A/B honoring the
choice.

### Out of scope (documented follow-up round)

- A **per-game toggle in the GUI** (round 1 reads per-game overrides from
  `config.json`; nothing in the GUI writes them yet).
- **Opaque binary-config ports** (Cave-Story-class: `nxengine` binds raw button
  indices to game *actions* in a binary `settings.dat`). These have no A/B-label
  semantics to flip from a single value; covering them means shipping a
  layout-swapped second blob per port and picking by layout. Deferred.

## Current state (what exists today)

- The pak ships two SDL maps: `gamecontrollerdb_nintendo.txt`
  (`a:b3` right, `b:b4` bottom) and `gamecontrollerdb_xbox.txt` (`a:b4` bottom,
  `b:b3` right). `set_controller_layout <nintendo|xbox>` copies the chosen one to
  the active `$EMU_DIR/gamecontrollerdb.txt` (exported as
  `SDL_GAMECONTROLLERCONFIG_FILE`, launch.sh:41).
- Selection today (launch.sh `run_port`, ~line 759): global-only and hidden — a
  file named `nintendo*` in `PORTS-portmaster` → nintendo, else **xbox**
  (default). No per-game path, nothing user-facing.
- `HM_TOOLS_DIR="$PAK_DIR"`; PortMaster's own config is
  `$EMU_DIR/config/config.json` (`$EMU_DIR = .../PORTS.pak/PortMaster`), loaded
  into `hm.cfg_data` and written by `save_config()`. The pak already bundles
  `jq`.
- The GUI (pugwash / pylibs) already has the swap machinery, in two layers:
  - **input** — `PlatformBase` sets `WANT_XBOX_FIX`; when set, `fix_xbox_mode()`
    (pySDL2gui) rewrites `BUTTON_MAP` so A↔B / X↔Y at input. `PlatformTrimUI`
    (our h700 class) has `WANT_XBOX_FIX = True` and **no `loaded()` override**,
    so it never reads any config.
  - **glyphs** — `WANT_SWAP_BUTTONS` (base default `False`, never set on TrimUI)
    swaps only the on-screen prompt icons (`pugscene` ~line 371).
  `PlatformKnulli.loaded()` is the template for driving both from one value.
- `OptionScene` (pugscene ~line 723) already renders `cfg_data`-backed toggles
  (`trimui-port-mode`, `show_all`, `show_experimental`, …) via
  `cfg_data[...] = ...; hm.save_config()` — the exact pattern a layout toggle
  mirrors.
- The shim `gt-input-remap.c` resolves gptk/evdev button *names* to physical
  indices through **one hardcoded table**, `gt_button_slot()`:
  `b→0, a→1, y→2, x→3, l1→4, r1→5, …`. It interposes at the **joystick event
  layer** (`SDL_PollEvent`), not SDL's GameController mapping.

## Approaches considered

1. **DB-only.** Extend just the `gamecontrollerdb` selection. Rejected: covers
   only clean SDL-GameController ports. Shim/keyboard/evdev ports keep their
   hardcoded mapping → the setting silently applies to some games and not others
   (the exact confusion we're removing).
2. **Two versions of every bundled remap.** Ship nintendo/xbox variants of every
   shim config / launcher. Rejected: massive duplication; the shim's mapping is a
   single table, so one conditional covers all shim ports at once.
3. **Text-file-only config.** Rejected on UX: Camille wants a GUI setting;
   PortMaster already has the GUI swap machinery.
4. **Chosen — single source of truth + one resolved value consulted per layer.**
   One key in `config.json`, written by the GUI, read by both the GUI and
   `launch.sh`. `launch.sh` resolves the effective layout once and every port
   class consults it (SDL via the DB; shim via an env var + a table swap;
   custom launcher via the shim). No duplicated remaps; no partial coverage.

## Architecture

### Single source of truth

`config.json` key **`gt-controller-layout`**, value `"nintendo"` | `"xbox"`.
Absent → **`nintendo`** (factory default), resolved identically on both sides:

- GUI: `hm.cfg_data.get('gt-controller-layout', 'nintendo')`.
- Shell: `jq -r '."gt-controller-layout" // "nintendo"' "$EMU_DIR/config/config.json"`.

Because both sides default when the key is absent, **no config migration is
needed** — existing installs (no key) resolve to `nintendo`, which is the
intended default flip. The shipped `files/config.json` is left untouched.

Per-game override (read-only in round 1): optional object
**`gt-port-layout`**, mapping a launcher filename (`ROM_NAME`, e.g.
`"Sonic 1.sh"`) to `"nintendo"` | `"xbox"`. Absent/empty by default.

### Effective-layout resolution (launch.sh `run_port`)

Replace the current `nintendo_file` block with a resolver, precedence high→low:

1. per-game: `gt-port-layout[ROM_NAME]` from `config.json` (if a valid value);
2. global: `gt-controller-layout` from `config.json`;
3. legacy back-compat: a `nintendo*` marker file in `PORTS-portmaster` → `nintendo`;
4. factory default: `nintendo`.

Then:

```sh
set_controller_layout "$layout"        # writes gamecontrollerdb.txt (SDL ports)
export GT_CONTROLLER_LAYOUT="$layout"  # consumed by the shim (all synth ports)
```

`resolve_controller_layout` is a new shell function beside `set_controller_layout`
so its precedence logic is unit-testable; all `jq` reads fail safe to the next
tier on missing file / missing key / malformed JSON / unrecognized value.

### Port classes → how each honors the resolved value

| Class | Examples | Mechanism | Round-1 cost |
|---|---|---|---|
| Clean SDL GameController | most ports | `gamecontrollerdb.txt` swap (exists) | free |
| Shim keyboard/gptk synth | BYTEPATH, Tunics!, Sonic 1/2, Lasagna Boy, Road Invaders, The Starlit Escape | shim reads `GT_CONTROLLER_LAYOUT`; `gt_button_slot()` swaps a↔b (0↔1) and x↔y (2↔3) for `xbox` | one conditional |
| Custom launcher (evdev) | OpenCrossing / Animal Crossing | already routes through `gt-input-remap.armhf.so` → covered by the same shim change; its inline `SDL_GAMECONTROLLERCONFIG` swapped for consistency | rides the shim change |
| Opaque binary config | Cave Story (`settings.dat`) | **follow-up** — dual blob | out of scope |

### Shim (`gt-input-remap.c`)

- Read `GT_CONTROLLER_LAYOUT` once (mirrors the existing `GT_REMAP_GPTK` /
  `GT_EVDEV_KEYS` env reads).
- In `gt_button_slot()`: one layout leaves the current table unchanged and the
  other swaps the returned slot for `a`↔`b` and `x`↔`y`. **Which layout is the
  swapped one is pinned at the gate** — the shim ports were tuned while the global
  default was Xbox, so the current table's perceived layout must be measured, not
  assumed. Everything else (shoulders, start, guide, d-pad) is unaffected.
- Keep the pure-logic swap inside the `-DGT_REMAP_TEST` host-test surface.
- **Polarity is confirmed at the device gate:** the shipped SDL DBs and the shim
  swap must agree so "confirm" lands on the same physical button the SDL ports
  use for a given layout.

### GUI (`patch_pylibs`, the F22 rail)

Two patches applied at launch by `build-pak.sh`'s existing pylibs-patch machinery:

- **`platform.py` — add `PlatformTrimUI.loaded()`** (mirrors
  `PlatformKnulli.loaded()`'s explicit-value branch):

  ```python
  def loaded(self):
      layout = self.hm.cfg_data.get('gt-controller-layout', 'nintendo')
      self.WANT_XBOX_FIX = False
      self.WANT_SWAP_BUTTONS = (layout == 'nintendo')   # polarity pinned at gate
  ```

  Turning `WANT_XBOX_FIX` off and driving `WANT_SWAP_BUTTONS` from the value keeps
  input (BUTTON_MAP) and glyphs consistent.

- **`pugscene.py` — add a "Controller Layout: Nintendo / Xbox" entry to
  `OptionScene`**, mirroring the `trimui-port-mode` / `show_all` toggles: on
  activate, flip `cfg_data['gt-controller-layout']`, `hm.save_config()`, update
  the row label, and re-sync the live GUI (call `platform.loaded()` then
  `gui.SWAP_BUTTONS = platform.WANT_SWAP_BUTTONS`). If a fully-live re-sync proves
  fiddly, fall back to writing the value + a "restarts PortMaster" note; the value
  still takes effect on next GUI start and for all ports immediately.

### GUI DB consistency

`run_portmaster_gui` applies the global layout to `gamecontrollerdb.txt` before
pugwash starts (today `set_controller_layout` only runs per-port), so the pad the
GUI's SDL sees matches the chosen layout.

## Data flow

```
GUI OptionScene toggle ──► cfg_data['gt-controller-layout'] ──► save_config()
                                        │
      $EMU_DIR/config/config.json ◄─────┘
                │                                  │
   PlatformTrimUI.loaded() (jq-free, python)   launch.sh resolve_controller_layout (jq)
     → WANT_XBOX_FIX / WANT_SWAP_BUTTONS         → set_controller_layout (SDL DB)
       (GUI confirm/back + glyphs)               → export GT_CONTROLLER_LAYOUT
                                                     → shim a↔b / x↔y (synth ports)
```

## Error handling / edge cases

- Missing config file / key / malformed JSON / unknown value → each read falls
  through to the next precedence tier, ending at `nintendo`. `jq` failures are
  swallowed (`2>/dev/null`), never fatal to a launch.
- **Default flip risk (xbox→nintendo).** Changes A/B (and X/Y) for every SDL
  GameController port on existing installs. Mitigation: per-game xbox pin via
  `gt-port-layout`; recommend seeding known-correct-under-xbox ports there before
  the gate. Ports on raw-index/action bindings (Cave Story, etc.) are unaffected
  (they ignore the DB) and are handled in the follow-up.
- Legacy `nintendo*` marker still honored (tier 3) so any existing user marker
  keeps working; it is now redundant with the nintendo default.
- Mid-session GUI change: applies live if the re-sync path works, else on next
  GUI start; ports always pick it up on their next launch.

## Testing (fixture-based, mirrors existing suites)

- **`resolve_controller_layout`** (new shell test): per-game > global > legacy
  marker > default `nintendo`; malformed/missing config → default; verifies
  `GT_CONTROLLER_LAYOUT` is exported and `gamecontrollerdb.txt` written.
- **Shim host test** (`-DGT_REMAP_TEST`): `gt_button_slot()` under both layouts —
  `nintendo` unchanged; `xbox` swaps a↔b / x↔y and leaves all other names intact.
- **Build injection**: `run_port` resolver block present and anchored; the two
  `patch_pylibs` edits produce a `PlatformTrimUI.loaded()` reading the key and an
  `OptionScene` entry writing it.
- `make test` green (new suites added to the existing count).

## Device gate (RG SP — request device back online)

1. **GUI**: Options toggle flips confirm/back consistently (input *and* glyphs);
   persists across a PortMaster restart.
2. **Clean SDL port**: A/B matches labels under `nintendo`, flips under `xbox`.
3. **Every shim port** (BYTEPATH, Tunics!, Sonic 1/2, Lasagna Boy, Road Invaders,
   The Starlit Escape): still plays; A/B consistent with the layout; regression
   pass in both layouts.
4. **OpenCrossing**: still plays; A/B consistent.
5. **Per-game override**: set one port to `xbox` in `gt-port-layout` while global
   is `nintendo`; confirm only that port differs.
6. Confirm shim/DB **polarity** agree (task 2 vs 3 land on the same physical
   button per layout).

## Files touched

- `assets/gt-input-remap.c` — `GT_CONTROLLER_LAYOUT` env + `gt_button_slot()` swap
  (rebuilt via `make shim` → `gt-input-remap.so` + `.armhf.so`).
- `dist/.../launch.sh` **source-of-truth** (the injected gt-h700 blocks live in
  `build/build-pak.sh`, not hand-edited in dist): new `resolve_controller_layout`,
  the `run_port` resolver replacing the `nintendo_file` block, `GT_CONTROLLER_LAYOUT`
  export, and the GUI DB-consistency line.
- `build/build-pak.sh` — the awk anchors for the above (the `nintendo_file=`
  anchor is being replaced) + two `patch_pylibs` edits (`platform.py`,
  `pugscene.py`).
- `tests/` — new resolver + shim-swap + injection suites.
- `docs/h700-fixes.md` — new fix entry (next F-number) + changelog.

## Process

Feature branch `controller-layout-config` off `8882c79`; TDD; one squashed
commit at the end (docs folded in). Joins the existing unpushed local bundle —
**no push / tag / release until Camille says**; device gate required first.
Follow-up round (per-game GUI + Cave-Story-class dual configs) gets its own
spec/plan.
