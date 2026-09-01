#!/usr/bin/env python3
# gt-h700-controller-layout (F48): add a "Controller Layout: Nintendo/Xbox" toggle
# to PortMaster's OptionScene. Writes cfg_data['gt-controller-layout'] (the key
# launch.sh + PlatformTrimUI.loaded() read). Mirrors the toggle-experimental
# option. Edits are confined to the OptionScene class. Idempotent.
import sys

path = sys.argv[1]
with open(path) as fh:
    src = fh.read()

if 'gt-controller-layout-toggle' in src:
    sys.exit(0)

start = src.find('class OptionScene(BaseScene):')
if start < 0:
    sys.stderr.write('gt_patch_optionscene_layout: OptionScene not found\n')
    sys.exit(1)
nxt = src.find('\nclass ', start + 1)
end = nxt if nxt >= 0 else len(src)
block = src[start:end]

add_anchor = "        self.tags['option_list'].add_option(None, _(\"Interface\"))\n"
add_option = (
    "        # gt-h700-controller-layout (F48)\n"
    "        self.tags['option_list'].add_option(\n"
    "            'gt-controller-layout-toggle',\n"
    "            _(\"Controller Layout: \") + (self.gui.hm.cfg_data.get('gt-controller-layout', 'nintendo') == 'nintendo' and _(\"Nintendo\") or _(\"Xbox\")),\n"
    "            description=_(\"Which face button is A/confirm: Nintendo (A right) or Xbox (A bottom).\"))\n"
)
if add_anchor not in block:
    sys.stderr.write('gt_patch_optionscene_layout: add anchor not found\n')
    sys.exit(1)
block = block.replace(add_anchor, add_anchor + add_option, 1)

press_anchor = "            self.button_activate()\n"
press_branch = (
    "            self.button_activate()\n"
    "\n"
    "            if selected_option == 'gt-controller-layout-toggle':\n"
    "                # gt-h700-controller-layout (F48)\n"
    "                current = self.gui.hm.cfg_data.get('gt-controller-layout', 'nintendo')\n"
    "                new_layout = (current != 'nintendo') and 'nintendo' or 'xbox'\n"
    "                self.gui.hm.cfg_data['gt-controller-layout'] = new_layout\n"
    "                self.gui.hm.save_config()\n"
    "                item = self.tags['option_list'].list_selected()\n"
    "                self.tags['option_list'].list[item] = (\n"
    "                    _(\"Controller Layout: \") + (new_layout == 'nintendo' and _(\"Nintendo\") or _(\"Xbox\")))\n"
    "                return True\n"
)
if press_anchor not in block:
    sys.stderr.write('gt_patch_optionscene_layout: press anchor not found\n')
    sys.exit(1)
block = block.replace(press_anchor, press_branch, 1)

with open(path, 'w') as fh:
    fh.write(src[:start] + block + src[end:])
