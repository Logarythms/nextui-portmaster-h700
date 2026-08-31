#!/usr/bin/env python3
# gt-h700-controller-layout (F48): give PlatformTrimUI a loaded() that drives the
# GUI's confirm/back (input BUTTON_MAP via WANT_XBOX_FIX + prompt glyphs via
# WANT_SWAP_BUTTONS) from PortMaster's own config.json key 'gt-controller-layout'
# (nintendo|xbox) -- the same key launch.sh reads for ports. Mirrors
# PlatformKnulli.loaded()'s explicit-value branch. Idempotent.
# POLARITY (which layout maps to WANT_SWAP_BUTTONS True) is confirmed at the
# device gate -- a one-line flip here if reversed.
import sys

path = sys.argv[1]
with open(path) as fh:
    src = fh.read()

if 'gt-controller-layout' in src:
    sys.exit(0)  # already patched

marker = 'class PlatformTrimUI(PlatformBase):\n'
i = src.find(marker)
if i < 0:
    sys.stderr.write('gt_patch_platform_layout: PlatformTrimUI not found\n')
    sys.exit(1)

at = i + len(marker)
method = (
    "    def loaded(self):\n"
    "        # gt-h700-controller-layout (F48): drive confirm/back from config.json\n"
    "        layout = self.hm.cfg_data.get('gt-controller-layout', 'nintendo')\n"
    "        self.WANT_XBOX_FIX = False\n"
    "        self.WANT_SWAP_BUTTONS = (layout == 'nintendo')\n"
    "\n"
)
with open(path, 'w') as fh:
    fh.write(src[:at] + method + src[at:])
