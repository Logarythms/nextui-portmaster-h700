# Controller layout follow-ups (per-game GUI, Cave Story, toggle visibility) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a user pick the controller layout per game from the PortMaster GUI, make the global toggle discoverable, and make Cave Story honor the layout — closing the two items F48 deferred plus one device-gate polish item.

**Architecture:** Three independent changes on the F48 rails: (C) reposition the global `OptionScene` toggle via the existing `patch_pylibs` helper; (B) a launch-time byte-patch of Cave Story's binary `settings.dat` face-button fields, keyed to the resolved layout and idempotent via a stamp, wired by a marker-guarded `awk` injector in build-pak.sh after F48's resolver; (A) a new `patch_pylibs` helper that adds a per-game layout control to `PortInfoScene`'s free `X` button (cycle Default/Nintendo/Xbox for normal ports; a disclaimer for self-configuring `apply_button_map` ports). Balatro-class exclusion is documentation only.

**Tech Stack:** POSIX sh (busybox on device), `awk`-based launch.sh injectors in `build/build-pak.sh` (marker-guarded, idempotent), Python 3 string-injection `patch_pylibs` helpers against PortMaster `pugscene.py`, fixture-based `tests/test-*.sh` (run via `make test`), `make pak` (needs network).

**Spec:** `docs/superpowers/specs/2026-09-01-controller-layout-per-game-followups-design.md`

## Global Constraints

- **Layout values are exactly `nintendo` | `xbox`.** The resolver (`assets/gt-controller-layout.sh`) and the two `gamecontrollerdb_<layout>.txt` are unchanged. No third value.
- **config.json keys:** global `gt-controller-layout`; per-game `gt-port-layout["<launcher>.sh"]` where the launcher filename is `ROM_NAME`. In the GUI, read/write via `self.gui.hm.cfg_data[...]` then `self.gui.hm.save_config()` (the F48 / OptionScene pattern). Selecting "Default" **removes** the per-game key (resolver falls through to global); an empty `gt-port-layout` map is removed entirely.
- **Cave Story byte offsets (device-verified against `assets/nxengine-evo-h700-settings.dat`):** magic `NXS7` at bytes 0–3; `JUMP.jbut` little-endian int32 at **offset 136**; `FIRE.jbut` at **offset 160**. `nintendo` → JUMP=3 (right), FIRE=4 (bottom); `xbox` → JUMP=4 (bottom), FIRE=3 (right). **Only those two 4-byte fields may change** — resolution (offset 4), keyboard binds, and everything else must be byte-identical.
- **All launch.sh edits go through marker-guarded `awk` injectors in `build/build-pak.sh`** (idempotent via `grep -q '<marker>'`), mirroring the F39/F48 blocks. Never edit the staged `launch.sh` directly.
- **pylib patches are idempotent** (early-exit on a marker string), **scoped to the target class**, and mirror `src/gt_patch_optionscene_layout.py`.
- **`make test` stays green.** When you move any line that a sibling test greps as a landmark, sweep `grep -rn '<moved string>' tests/` and retarget (the F48 R4/R5 lesson).
- **One feature branch (`controller-layout-followups`), one squashed commit at finish** (docs fold in). **NO push / NO tag** — main is already ahead of origin and Camille is bundling; this round joins the bundle.
- **`make pak` needs network** → run with `dangerouslyDisableSandbox` (deps are sha256-pinned).

**User decisions (already made):**
- "One combined phase, B first" — land the Cave Story fix before the GUI enhancement.
- "include cave story" — Cave Story IS in scope for the layout transform.
- Balatro / `apply_button_map` ports are **excluded from remapping by design** (the user's own in-port mapping wins); the GUI shows a disclaimer, no runtime transform.
- "make the global layout toggle a bit more visible" — move it up from the bottom of Options.
- The five other ports (Apotris, 2048 Plus, Dusklight, Mina, Pizza Tower) are **confirmed already-covered by F48** (device-tested 2026-09-01) — no code.

---

### Task 1: C — make the global layout toggle visible in Options

**Goal:** Move the global "Controller Layout" toggle from the bottom of `OptionScene` to the top, under the first "Interface" section, so it's visible without scrolling.

**Files:**
- Modify: `src/gt_patch_optionscene_layout.py` (change the insertion anchor + insert position)
- Test: `tests/test-28-optionscene-layout-patch.sh` (assert new placement)

**Acceptance Criteria:**
- [ ] The toggle option is inserted immediately **after** the `add_option(None, _("Interface"))` header, not before `list_select(0)`.
- [ ] Helper stays idempotent (re-run is a no-op) and confined to `OptionScene`.
- [ ] `test-28` asserts the option now follows the Interface header; the leak-guard (must not appear in `MainMenuScene`) still holds.
- [ ] `make test` green.

**Verify:** `cd ~/dev/nextui-portmaster-h700 && make test` → all suites PASS (incl. test-28)

**Steps:**

- [ ] **Step 1: Update the test to pin the new placement.** In `tests/test-28-optionscene-layout-patch.sh`, after the existing "toggle option added" assertions, add a placement assertion that the toggle line comes right after the Interface header. Add near the other `grep` checks:

```sh
# F50 (C): toggle sits under the first "Interface" section, not at the bottom.
# Assert the add_option for our toggle appears within a few lines AFTER the
# Interface header and BEFORE the Audio header.
awk '/add_option\(None, _\("Interface"\)\)/{i=NR} /gt-controller-layout-toggle/{t=NR} /add_option\(None, _\("Audio"\)\)/{a=NR} END{exit !(i>0 && t>i && (a==0 || t<a))}' "$fix" \
  || { echo "layout toggle not placed under Interface section"; exit 1; }
```

- [ ] **Step 2: Run test to verify it fails** against the current (bottom) placement.

Run: `cd ~/dev/nextui-portmaster-h700 && ROOT=. bash tests/test-28-optionscene-layout-patch.sh` (or `make test`)
Expected: FAIL on "layout toggle not placed under Interface section".

- [ ] **Step 3: Change the insertion anchor + position in `src/gt_patch_optionscene_layout.py`.** Replace the `add_anchor` definition and the insert call. Current:

```python
add_anchor = "        self.tags['option_list'].list_select(0)\n"
...
block = block.replace(add_anchor, add_option + add_anchor, 1)
```

New — anchor on the Interface header and insert AFTER it:

```python
add_anchor = "        self.tags['option_list'].add_option(None, _(\"Interface\"))\n"
...
block = block.replace(add_anchor, add_anchor + add_option, 1)
```

(Leave the `if add_anchor not in block:` guard as-is — it now guards on the Interface header, which is present in `OptionScene`.)

- [ ] **Step 4: Run test to verify it passes.**

Run: `cd ~/dev/nextui-portmaster-h700 && make test`
Expected: PASS (test-28 incl. the new placement assertion).

- [ ] **Step 5: Sweep for any other test that greps the old anchor as a landmark.**

Run: `cd ~/dev/nextui-portmaster-h700 && grep -rn "list_select(0)" tests/`
Expected: no test depends on the toggle being adjacent to `list_select(0)`. If one does, retarget it.

- [ ] **Step 6: Commit.**

```bash
cd ~/dev/nextui-portmaster-h700
git add src/gt_patch_optionscene_layout.py tests/test-28-optionscene-layout-patch.sh
git commit -m "fix(F50): surface the global controller-layout toggle under Interface"
```

---

### Task 2: B — Cave Story settings.dat layout-conform

**Goal:** At launch, swap Cave Story's `JUMP`/`FIRE` face-button bindings in the binary `settings.dat` to match the resolved layout, idempotently (via a stamp), preserving all other settings.

**Files:**
- Create: `assets/gt-nxengine-conform-layout.sh` (the byte-patch + stamp)
- Modify: `build/build-pak.sh` (stage the helper into `files/`; new `awk` injector anchored on the F48 `export GT_CONTROLLER_LAYOUT` line)
- Test: `tests/test-15-nxengine-settings.sh` (extend: staging + wiring + behavioral swap + idempotency)

**Acceptance Criteria:**
- [ ] `gt-nxengine-conform-layout.sh <settings.dat> <layout>` writes JUMP.jbut@136 / FIRE.jbut@160 to (3,4) for nintendo, (4,3) for xbox, and touches nothing else (byte-diff limited to those two 4-byte fields).
- [ ] It is idempotent: a second run with the same layout (stamp matches) exits 0 and leaves the file byte-identical.
- [ ] It refuses a non-`NXS7` file (exits 0, writes nothing).
- [ ] build-pak.sh stages the helper to `files/gt-nxengine-conform-layout.sh` (executable) and injects a launch.sh block (marker `gt-h700-nxengine-layout`) that runs it for the `nxengine-evo` GAMEDIR after `export GT_CONTROLLER_LAYOUT`.
- [ ] `make test` green.

**Verify:** `cd ~/dev/nextui-portmaster-h700 && make test` → all suites PASS (incl. test-15)

**Steps:**

- [ ] **Step 1: Write the conform helper `assets/gt-nxengine-conform-layout.sh`.**

```sh
#!/bin/sh
# gt-nxengine-conform-layout (F49): swap Cave Story (nxengine-evo) JUMP/FIRE
# face-button bindings in settings.dat to match the resolved controller layout.
# Idempotent via a sidecar stamp; preserves resolution and all other bindings.
#   $1 = settings.dat path   $2 = layout (nintendo|xbox)
# Format (verified): magic "NXS7"@0; 24-byte binding records @36; jbut = field 1
# (record+4). JUMP=enum4 -> jbut@136; FIRE=enum5 -> jbut@160 (LE int32).
# nintendo: JUMP=3 (right), FIRE=4 (bottom).  xbox: JUMP=4 (bottom), FIRE=3.
f="$1"
layout="$2"
[ -f "$f" ] || exit 0
case "$layout" in nintendo|xbox) ;; *) layout=nintendo ;; esac

stamp="$(dirname "$f")/.gt-h700-layout"
if [ -f "$stamp" ] && [ "$(cat "$stamp" 2>/dev/null)" = "$layout" ]; then
    exit 0
fi

# Magic guard: bytes 0-3 must be "NXS7".
if [ "$(dd if="$f" bs=1 count=4 2>/dev/null)" != "NXS7" ]; then
    exit 0
fi

if [ "$layout" = "nintendo" ]; then
    printf '\003\000\000\000' | dd of="$f" bs=1 seek=136 conv=notrunc 2>/dev/null  # JUMP=3 (right)
    printf '\004\000\000\000' | dd of="$f" bs=1 seek=160 conv=notrunc 2>/dev/null  # FIRE=4 (bottom)
else
    printf '\004\000\000\000' | dd of="$f" bs=1 seek=136 conv=notrunc 2>/dev/null  # JUMP=4 (bottom)
    printf '\003\000\000\000' | dd of="$f" bs=1 seek=160 conv=notrunc 2>/dev/null  # FIRE=3 (right)
fi

echo "$layout" > "$stamp"
```

- [ ] **Step 2: Write the failing behavioral test** in `tests/test-15-nxengine-settings.sh` (append a new section; mirror the file's existing helper/assert style). Copy the shipped blob as a fixture, run conform both ways, assert the two fields and byte-length, and assert idempotency:

```sh
# --- F49: layout-conform (byte-patch JUMP/FIRE, idempotent) ---
conform="$ROOT/assets/gt-nxengine-conform-layout.sh"
[ -x "$conform" ] || { echo "conform helper missing/not executable"; exit 1; }
tmp=$(mktemp -d)
cp "$ROOT/assets/nxengine-evo-h700-settings.dat" "$tmp/settings.dat"

byte_at() { dd if="$1" bs=1 skip="$2" count=1 2>/dev/null | od -An -tu1 | tr -d ' '; }

"$conform" "$tmp/settings.dat" nintendo
[ "$(byte_at "$tmp/settings.dat" 136)" = "3" ] || { echo "nintendo JUMP.jbut != 3"; exit 1; }
[ "$(byte_at "$tmp/settings.dat" 160)" = "4" ] || { echo "nintendo FIRE.jbut != 4"; exit 1; }
[ "$(wc -c < "$tmp/settings.dat")" -eq 964 ] || { echo "size changed"; exit 1; }
[ "$(dd if="$tmp/settings.dat" bs=1 count=4 2>/dev/null)" = "NXS7" ] || { echo "magic clobbered"; exit 1; }

"$conform" "$tmp/settings.dat" xbox
[ "$(byte_at "$tmp/settings.dat" 136)" = "4" ] || { echo "xbox JUMP.jbut != 4"; exit 1; }
[ "$(byte_at "$tmp/settings.dat" 160)" = "3" ] || { echo "xbox FIRE.jbut != 3"; exit 1; }

# Idempotency: same layout again is byte-identical (stamp match).
cp "$tmp/settings.dat" "$tmp/before"
"$conform" "$tmp/settings.dat" xbox
cmp -s "$tmp/before" "$tmp/settings.dat" || { echo "conform not idempotent"; exit 1; }

# Non-NXS7 file untouched.
printf 'JUNKdata' > "$tmp/junk"; cp "$tmp/junk" "$tmp/junk.bak"
"$conform" "$tmp/junk" nintendo
cmp -s "$tmp/junk" "$tmp/junk.bak" || { echo "conform touched non-NXS7 file"; exit 1; }
rm -rf "$tmp"
```

- [ ] **Step 3: Run the test to verify it fails** (helper not yet executable / staged).

Run: `cd ~/dev/nextui-portmaster-h700 && chmod +x assets/gt-nxengine-conform-layout.sh && ROOT=. bash tests/test-15-nxengine-settings.sh`
Expected: initially FAIL if any assertion is off; iterate until the behavioral block PASSES.

- [ ] **Step 4: Stage the helper + inject the launch.sh block in `build/build-pak.sh`.**

(4a) Where the other `assets/*.sh` helpers are copied into the assembled `files/` (near the `cp -f "$ASSETS/gt-controller-layout.sh" ...` around build-pak.sh:1331), add:

```sh
  cp -f "$ASSETS/gt-nxengine-conform-layout.sh" "$assembled/files/gt-nxengine-conform-layout.sh"
  chmod +x "$assembled/files/gt-nxengine-conform-layout.sh"
```

(4b) Add a new injector AFTER the F48 blocks (after build-pak.sh:~1009), anchored on the F48-injected export line so `$gt_layout` and `$GAMEDIR` are both set:

```sh
  # gt-h700-nxengine-layout: F49 — after the layout resolves, conform Cave Story's
  # JUMP/FIRE face-button bindings in settings.dat to $gt_layout (idempotent via a
  # stamp; preserves resolution + in-game rebinds). Runs after F39 installed the
  # base blob. Scoped to the nxengine-evo GAMEDIR; off the shim remap list.
  if ! grep -q 'gt-h700-nxengine-layout' "$f"; then
    awk '$0 == "    export GT_CONTROLLER_LAYOUT=\"$gt_layout\"" {
      print $0
      print "    # gt-h700-nxengine-layout (F49): conform Cave Story JUMP/FIRE to $gt_layout"
      print "    if [ \"$PLATFORM\" = \"h700\" ] && [ \"${GAMEDIR##*/}\" = \"nxengine-evo\" ] \\"
      print "        && [ -f \"$GAMEDIR/conf/nxengine/settings.dat\" ]; then"
      print "        \"$PAK_DIR/files/gt-nxengine-conform-layout.sh\" \"$GAMEDIR/conf/nxengine/settings.dat\" \"$gt_layout\""
      print "    fi"
      next
    }
    { print }' "$f" > "$f.awk.tmp" && mv "$f.awk.tmp" "$f"
  fi
```

- [ ] **Step 5: Add wiring assertions to `test-15`** (mirror the file's existing static-placement style, using the same `GT_STAGE_EDIT_ONLY` staged-launch fixture the suite already builds):

```sh
# F49: helper staged + injector wired into the staged launch.sh.
assert_contains "$work/launch.sh" 'gt-h700-nxengine-layout (F49)'
assert_contains "$work/launch.sh" 'files/gt-nxengine-conform-layout.sh'
```

(Use the same `$work`/staged-launch variable the earlier part of test-15 already sets up; if the suite exposes the assembled `files/` dir, also assert `gt-nxengine-conform-layout.sh` is present and executable.)

- [ ] **Step 6: Run the full suite.**

Run: `cd ~/dev/nextui-portmaster-h700 && make test`
Expected: PASS (test-15 incl. the new behavioral + wiring assertions).

- [ ] **Step 7: Commit.**

```bash
cd ~/dev/nextui-portmaster-h700
git add assets/gt-nxengine-conform-layout.sh build/build-pak.sh tests/test-15-nxengine-settings.sh
git commit -m "feat(F49): conform Cave Story controls to the resolved layout"
```

---

### Task 3: A — per-game controller layout in the GUI (+ Balatro-class disclaimer)

**Goal:** Add a per-game layout control to `PortInfoScene`'s free `X` button: for a normal installed port, press `X` to cycle Default → Nintendo → Xbox (persisted to `gt-port-layout`); for an `apply_button_map` port, `X` shows a disclaimer instead.

**Files:**
- Create: `src/gt_patch_portinfo_layout.py` (idempotent string-injection into `PortInfoScene`)
- Modify: `build/build-pak.sh` (stage `src/`, if not already; new injector to run the helper against `pugscene.py`, on the same `platform.py portmaster_install` rail as F48's OptionScene patch)
- Test: `tests/test-29-portinfo-layout-patch.sh` (new; mirrors test-27/28)

**Acceptance Criteria:**
- [ ] The helper injects an `X` label (`Layout: Default/Nintendo/Xbox`, or `Layout: in-game` for self-mapping ports) into `PortInfoScene.update_port` and an `X` handler into `PortInfoScene.do_update`.
- [ ] Cycle path writes/clears `gt-port-layout["<launcher>.sh"]` for **every** `.sh` in `port_info['items']`, then `save_config()`; "Default" removes the key(s); an emptied map is removed.
- [ ] Self-mapping detection: reads each installed launcher and treats the port as self-mapping if any contains `apply_button_map` or `BUTTON_MAP_FILE`.
- [ ] The control is gated to installed ports (`'installed' in self.port_attrs`).
- [ ] Helper is idempotent, confined to `PortInfoScene` (does not leak into other scenes), and the new test asserts injection + the disclaimer branch.
- [ ] `make test` green.

**Verify:** `cd ~/dev/nextui-portmaster-h700 && make test` → all suites PASS (incl. new test-29)

**Steps:**

- [ ] **Step 1: Write `src/gt_patch_portinfo_layout.py`.** Two injections into the `PortInfoScene` class only (scope by finding the class start and the next `\nclass `, like `gt_patch_optionscene_layout.py`). Anchors: `        self.set_buttons(buttons)\n` in `update_port` (insert the label block before it) and `        super().do_update(events)\n` in `do_update` (insert the handler after it).

```python
#!/usr/bin/env python3
# gt-h700-portinfo-layout (F50): add a per-game controller-layout control to
# PortMaster's PortInfoScene (the free X button). Normal port: X cycles
# Default -> Nintendo -> Xbox, written to config.json key 'gt-port-layout'
# keyed by launcher filename (the ROM_NAME the resolver reads). Self-mapping
# ports (apply_button_map / BUTTON_MAP_FILE, e.g. Balatro) show a disclaimer
# instead. Confined to PortInfoScene. Idempotent.
import sys

path = sys.argv[1]
with open(path) as fh:
    src = fh.read()

if 'gt-h700-portinfo-layout' in src:
    sys.exit(0)

start = src.find('class PortInfoScene(BaseScene):')
if start < 0:
    sys.stderr.write('gt_patch_portinfo_layout: PortInfoScene not found\n')
    sys.exit(1)
nxt = src.find('\nclass ', start + 1)
end = nxt if nxt >= 0 else len(src)
block = src[start:end]

# 1) X-button label in update_port, computed before set_buttons(buttons).
label_anchor = "        self.set_buttons(buttons)\n"
label_code = (
    "        # gt-h700-portinfo-layout (F50): per-game controller layout on X\n"
    "        self.gt_launchers = [it for it in (self.port_info.get('items') or []) if it.lower().endswith('.sh')]\n"
    "        self.gt_selfmap = False\n"
    "        for _gt_sh in self.gt_launchers:\n"
    "            try:\n"
    "                _gt_p = self.gui.hm.ports_dir / _gt_sh\n"
    "                if _gt_p.is_file():\n"
    "                    _gt_txt = _gt_p.read_text(errors='ignore')\n"
    "                    if 'apply_button_map' in _gt_txt or 'BUTTON_MAP_FILE' in _gt_txt:\n"
    "                        self.gt_selfmap = True\n"
    "                        break\n"
    "            except Exception:\n"
    "                pass\n"
    "        if 'installed' in self.port_attrs and self.gt_launchers:\n"
    "            if self.gt_selfmap:\n"
    "                buttons['X'] = _(\"Layout: in-game\")\n"
    "            else:\n"
    "                _gt_pg = self.gui.hm.cfg_data.get('gt-port-layout', {}) or {}\n"
    "                _gt_cur = _gt_pg.get(self.gt_launchers[0])\n"
    "                _gt_lbl = (_gt_cur == 'nintendo' and _(\"Nintendo\")) or (_gt_cur == 'xbox' and _(\"Xbox\")) or _(\"Default\")\n"
    "                buttons['X'] = _(\"Layout: \") + _gt_lbl\n"
)
if label_anchor not in block:
    sys.stderr.write('gt_patch_portinfo_layout: set_buttons anchor not found\n')
    sys.exit(1)
block = block.replace(label_anchor, label_code + label_anchor, 1)

# 2) X handler in do_update, after super().do_update(events).
press_anchor = "        super().do_update(events)\n"
press_code = (
    "        super().do_update(events)\n"
    "\n"
    "        # gt-h700-portinfo-layout (F50)\n"
    "        if events.was_pressed('X') and 'installed' in self.port_attrs and getattr(self, 'gt_launchers', None):\n"
    "            if getattr(self, 'gt_selfmap', False):\n"
    "                self.gui.message_box(_(\"This game sets up its controller in its own first-run screen. To change the layout, delete its saved mapping and relaunch.\"))\n"
    "            else:\n"
    "                _gt_pg = self.gui.hm.cfg_data.get('gt-port-layout', {}) or {}\n"
    "                _gt_cur = _gt_pg.get(self.gt_launchers[0])\n"
    "                _gt_nxt = {None: 'nintendo', 'nintendo': 'xbox', 'xbox': None}.get(_gt_cur, 'nintendo')\n"
    "                for _gt_sh in self.gt_launchers:\n"
    "                    if _gt_nxt is None:\n"
    "                        _gt_pg.pop(_gt_sh, None)\n"
    "                    else:\n"
    "                        _gt_pg[_gt_sh] = _gt_nxt\n"
    "                if _gt_pg:\n"
    "                    self.gui.hm.cfg_data['gt-port-layout'] = _gt_pg\n"
    "                elif 'gt-port-layout' in self.gui.hm.cfg_data:\n"
    "                    del self.gui.hm.cfg_data['gt-port-layout']\n"
    "                self.gui.hm.save_config()\n"
    "                self.update_port()\n"
    "            self.button_activate()\n"
    "            return True\n"
)
if press_anchor not in block:
    sys.stderr.write('gt_patch_portinfo_layout: do_update anchor not found\n')
    sys.exit(1)
block = block.replace(press_anchor, press_code, 1)

with open(path, 'w') as fh:
    fh.write(src[:start] + block + src[end:])
```

- [ ] **Step 2: Confirm the `hm.ports_dir` attribute against the live pylib** (the one runtime unknown). Extract and grep:

```bash
cd ~/dev/nextui-portmaster-h700/dist/Emus/h700/PORTS.pak/PortMaster
mkdir -p /tmp/gtpyl && unzip -o -q pylibs.zip -d /tmp/gtpyl
grep -nE "self\.ports_dir|ports_dir *=" /tmp/gtpyl/pylibs/harbourmaster/harbour.py
```

Expected: `self.ports_dir = ...` in `HarbourMaster.__init__`. If the attribute differs (e.g. `HM_PORTS_DIR`), update the two `self.gui.hm.ports_dir` references in the helper before proceeding.

- [ ] **Step 3: Write the failing patch test `tests/test-29-portinfo-layout-patch.sh`** (mirror `test-28`'s shape: copy a `pugscene.py` fixture, run the helper, assert injection + idempotency + scope + disclaimer text). Use the real staged `pugscene.py` from `dist/.../pylibs.zip` as the fixture source, or the suite's existing pugscene fixture if one exists.

```sh
#!/bin/sh
# F50: gt_patch_portinfo_layout.py injects the per-game layout control into
# PortInfoScene only, is idempotent, and includes the self-mapping disclaimer.
set -eu
ROOT="${ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
helper="$ROOT/src/gt_patch_portinfo_layout.py"
command -v python3 >/dev/null 2>&1 || { echo "SKIP: no python3"; exit 0; }

tmp=$(mktemp -d)
# Fixture: extract the real pugscene.py.
unzip -o -q "$ROOT/dist/Emus/h700/PORTS.pak/PortMaster/pylibs.zip" pylibs/pugscene.py -d "$tmp"
fix="$tmp/pylibs/pugscene.py"

python3 "$helper" "$fix"

grep -q "gt-h700-portinfo-layout" "$fix" || { echo "marker not inserted"; exit 1; }
grep -q "buttons\['X'\] = _(\"Layout: \")" "$fix" || { echo "X label not inserted"; exit 1; }
grep -q "gt-port-layout" "$fix" || { echo "per-game key write not inserted"; exit 1; }
grep -q "its own first-run screen" "$fix" || { echo "disclaimer not inserted"; exit 1; }

# Confined to PortInfoScene: nothing leaked into the next class.
awk '/^class PortInfoScene\(BaseScene\):/{p=1} /^class /{ if(p && $0 !~ /PortInfoScene/) p=0 } p && /gt-h700-portinfo-layout/{c++} END{exit !(c>=2)}' "$fix" \
  || { echo "injection not confined to PortInfoScene"; exit 1; }
awk '/^class FiltersScene/{f=1} f && /gt-h700-portinfo-layout/{print "leaked"; exit 1}' "$fix"

# Idempotent.
cp "$fix" "$tmp/once"
python3 "$helper" "$fix"
cmp -s "$tmp/once" "$fix" || { echo "not idempotent"; exit 1; }

echo "test-29 PASS"
rm -rf "$tmp"
```

- [ ] **Step 4: Run the test to verify it fails** (helper absent), then implement until it passes.

Run: `cd ~/dev/nextui-portmaster-h700 && ROOT=. bash tests/test-29-portinfo-layout-patch.sh`
Expected: FAIL (No such file) → PASS after Step 1's helper exists.

- [ ] **Step 5: Inject the helper into launch.sh via `build/build-pak.sh`.** Mirror the F48 `gt-h700-controller-layout-options` block (build-pak.sh:1002-1008); anchor on the same `platform.py portmaster_install` line, targeting `pugscene.py`:

```sh
  # gt-h700-portinfo-layout: F50 — per-game controller-layout control on PortInfoScene.
  if ! grep -q 'gt-h700-portinfo-layout' "$f"; then
    awk '{ print } $0 == "        \"$EMU_DIR/pylibs/harbourmaster/platform.py\" portmaster_install" {
      print "    # gt-h700-portinfo-layout (F50): per-game layout control + disclaimer"
      print "    python3 \"$PAK_DIR/src/gt_patch_portinfo_layout.py\" \\"
      print "        \"$EMU_DIR/pylibs/pugscene.py\""
    }' "$f" > "$f.awk.tmp" && mv "$f.awk.tmp" "$f"
  fi
```

Confirm `src/` is already staged into the pak (F48 stages `src/gt_patch_*.py`); if the stage step lists files explicitly, add `gt_patch_portinfo_layout.py`.

- [ ] **Step 6: Add a wiring assertion** to the relevant staged-launch test (whichever suite asserts F48's `gt-h700-controller-layout-options` wiring — likely `test-28` or the staged-launch test). Assert the staged `launch.sh` contains `gt-h700-portinfo-layout (F50)` and `gt_patch_portinfo_layout.py`.

- [ ] **Step 7: Full suite + leak sweep.**

Run: `cd ~/dev/nextui-portmaster-h700 && make test && grep -rn "set_buttons(buttons)" tests/`
Expected: all PASS; confirm no sibling test depends on the `set_buttons(buttons)` anchor in a way the insertion breaks.

- [ ] **Step 8: Commit.**

```bash
cd ~/dev/nextui-portmaster-h700
git add src/gt_patch_portinfo_layout.py build/build-pak.sh tests/test-29-portinfo-layout-patch.sh
git commit -m "feat(F50): per-game controller layout in the PortMaster GUI"
```

---

### Task 4: Docs — F49/F50 write-up, Balatro-class exclusion, changelog, README

**Goal:** Document the round, make the Balatro-class exclusion an explicit design decision (docs + a guard comment), and update the changelog + README.

**Files:**
- Modify: `docs/h700-fixes.md` (F49 Cave Story conform, F50 per-game GUI + visibility; Balatro-class exclusion note; Unreleased changelog entry)
- Modify: `build/build-pak.sh` (a guard comment next to the F48 `gt-h700-controller-layout (F48): resolve` block — no behavior change)
- Modify: `README.md` (per-game layout + Cave Story user-facing bullets)

**Acceptance Criteria:**
- [ ] `docs/h700-fixes.md` has F49 + F50 sections describing what shipped, and an explicit "apply_button_map ports are governed by their own in-port config — excluded by design" note.
- [ ] A guard comment in build-pak.sh warns against adding a `controller-map.txt` transform for `apply_button_map` ports (it would fight the user's captured mapping).
- [ ] README mentions per-game layout selection and Cave Story's layout-awareness.
- [ ] `make test` green (docs-only + comment change; verifies nothing regressed).

**Verify:** `cd ~/dev/nextui-portmaster-h700 && make test` → PASS

**Steps:**

- [ ] **Step 1: Add the guard comment** in `build/build-pak.sh` immediately above the F48 `# gt-h700-controller-layout (F48): resolve` injector block:

```sh
  # NOTE (F49): do NOT add a controller-map.txt transform for apply_button_map
  # ports (Balatro-class). Those ports export their own inline
  # SDL_GAMECONTROLLERCONFIG captured by the user in the port's first-run wizard;
  # it deliberately overrides our layout. The GUI (F50) shows a disclaimer for
  # them instead. See docs/h700-fixes.md (Balatro-class exclusion).
```

- [ ] **Step 2: Write the F49/F50 sections + exclusion note + changelog** in `docs/h700-fixes.md`, matching the file's existing F-entry style. F49 = Cave Story conform (offsets 136/160, stamp, idempotent, preserves other settings; note the factory-nintendo default flips a fresh install from F39's xbox). F50 = per-game GUI control on `PortInfoScene` X + the moved global toggle + the Balatro-class disclaimer/exclusion.

- [ ] **Step 3: Update `README.md`** with the two user-facing bullets (per-game layout via the port's info screen; Cave Story now follows the layout).

- [ ] **Step 4: Verify + commit.**

```bash
cd ~/dev/nextui-portmaster-h700 && make test
git add docs/h700-fixes.md build/build-pak.sh README.md
git commit -m "docs(F49/F50): controller-layout follow-ups + Balatro-class exclusion"
```

---

### Task 5: Device gate on the RG SP

**USER-ORDERED GATE — NON-SKIPPABLE.** This task was requested by the user in the current conversation. It MUST NOT be closed by walking around it, by declaring it "verified inline", or by substituting a cheaper check. Close only after every item in `acceptanceCriteria` has been re-validated independently, with output captured.

**Goal:** Build the pak, install on the RG SP, and confirm all three pieces work on-device before merge — with regressions checked.

**Files:** none (build + on-device verification)

**Acceptance Criteria:**
- [ ] `make pak` builds clean (`dangerouslyDisableSandbox`), installed via unzip-over into `Emus/h700/`.
- [ ] **A** — per-game screen: set one game Nintendo, another Xbox, one Default; relaunch each; A/B follow the per-game value and Default follows the global toggle; `config.json` `gt-port-layout` reflects the choices.
- [ ] **A disclaimer** — Balatro's port-info screen shows the disclaimer on X (not a toggle).
- [ ] **B** — Cave Story: flip the global layout, relaunch; jump/fire swap physical buttons; then a no-op relaunch (same layout) preserves resolution and an unrelated in-game rebind (stamp match, no re-patch).
- [ ] **C** — the global "Controller Layout" toggle is visible in Options without scrolling.
- [ ] **Regression** — Celeste (clean SDL) and Tunics!/Sonic (shim) still switch; the five already-covered ports unaffected.

**Verify:** On-device (`ssh root@10.0.1.16`) per the checklist above; capture the relevant `config.json` diff, the Cave Story `settings.dat` byte check, and the on-screen behavior. Report results in the ledger.

**Steps:**

- [ ] **Step 1: Build.** `cd ~/dev/nextui-portmaster-h700 && make pak` (with `dangerouslyDisableSandbox`; `file` the built `.so`/zip per the arch-drift trap in memory).
- [ ] **Step 2: Install.** scp `dist/Emus/h700/PORTS.pak.zip` to the device and `unzip -o … -d Emus/h700/`.
- [ ] **Step 3: Run the A / A-disclaimer / B / C / regression checks above**, capturing evidence for each (config.json diff; `dd`/`od` on Cave Story's `settings.dat` at 136/160; observed A/B behavior).
- [ ] **Step 4: Record results** in the execution ledger. Do not mark complete until every criterion has captured evidence. Any failure → fix on the branch and re-gate.

---

## Notes on order & finish

- Tasks are chained C → B → A → docs → gate to match the user's "B first" intent for the *fix* work while keeping the trivial visibility change first, and to serialize the shared `build/build-pak.sh` edits. (C and B are logically independent; A depends on nothing but shares build-pak.sh.)
- After the device gate passes: `superpowers-extended-cc:finishing-a-development-branch` → squash to one commit (docs fold in) → **STOP. No push, no tag** until Camille says (main is bundling unpushed work).
