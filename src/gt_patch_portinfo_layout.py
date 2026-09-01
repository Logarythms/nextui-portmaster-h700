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
