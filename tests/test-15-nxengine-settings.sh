#!/bin/sh
. "$(dirname -- "$0")/helpers.sh"

# F39: nxengine-evo (Cave Story Evo) controls + resolution. The engine reads the
# raw SDL joystick and binds actions to button INDICES + a resolution INDEX in
# conf/nxengine/settings.dat. The porter's defaults bind directions to buttons
# 8-11 and faces to 0-7 for a device whose d-pad is buttons; on h700 the d-pad
# is an SDL hat and the faces sit at raw 3-13, so directions were dead and faces
# scrambled, and the default 720x720 render overran the 720x480 fb. run_port
# installs an h700-correct settings.dat ONCE per port install (marker-gated, so
# a player's in-game rebinds/resolution survive — unlike the always-overwrite
# F27 overlay); a port reinstall recreates conf/ and re-heals.
work="$SANDBOX/pmpak"; mkdir -p "$work"
cp "$TROOT/fixtures/portmaster-pak-skeleton/pak.json.fixture" "$work/pak.json"
cp "$TROOT/fixtures/portmaster-pak-skeleton/launch.sh.fixture" "$work/launch.sh"
GT_STAGE_EDIT_ONLY="$work" sh "$ROOT/build/build-pak.sh" portmaster

assert_contains "$work/launch.sh" 'gt-h700-nxengine-settings'
# shellcheck disable=SC2016
assert_contains "$work/launch.sh" 'gt_nxe_src="$PAK_DIR/files/nxengine-h700/settings.dat"'
# port-specific gate + the install-once marker are both load-bearing.
# (patterns are BRE — avoid a leading '[' / '*', which grep reads as a
#  bracket expression; assert regex-safe substrings of the same lines.)
# shellcheck disable=SC2016
assert_contains "$work/launch.sh" '= "nxengine-evo" ]'
# shellcheck disable=SC2016
assert_contains "$work/launch.sh" 'conf/nxengine/.gt-h700-settings" ]; then'
# shellcheck disable=SC2016
assert_contains "$work/launch.sh" 'touch "$GAMEDIR/conf/nxengine/.gt-h700-settings"'

# placement: inside run_port — after GAMEDIR resolution, before the port exec
gamedir_line=$(grep -n 'echo "Game dir is: \$GAMEDIR"' "$work/launch.sh" | head -1 | cut -d: -f1)
inst_line=$(grep -n 'gt-h700-nxengine-settings: install' "$work/launch.sh" | head -1 | cut -d: -f1)
# shellcheck disable=SC2016
bash_exec_line=$(grep -n '"\$PAK_DIR/bin/bash" "\$ROM_PATH"' "$work/launch.sh" | head -1 | cut -d: -f1)
[ "$gamedir_line" -lt "$inst_line" ] || { echo "install is not after GAMEDIR resolution"; exit 1; }
[ "$inst_line" -lt "$bash_exec_line" ] || { echo "install is not before the port exec"; exit 1; }
sh -n "$work/launch.sh" || { echo "edited launch.sh does not parse"; exit 1; }

# behavioral: extract run_port's install fragment and run it against a fake
# nxengine-evo port dir. First run (no marker) installs the pak file + marker;
# a second run must NOT clobber a settings.dat the player has since changed.
fake="$SANDBOX/fake"
mkdir -p "$fake/pak/files/nxengine-h700" "$fake/nxengine-evo/conf/nxengine"
printf 'PAKDEFAULT' > "$fake/pak/files/nxengine-h700/settings.dat"
sed -n '/gt_nxe_src=/,/^    fi$/p' "$work/launch.sh" > "$fake/install.sh"

PAK_DIR="$fake/pak" GAMEDIR="$fake/nxengine-evo" PLATFORM=h700 sh "$fake/install.sh" >/dev/null 2>&1 || true
assert_eq "$(cat "$fake/nxengine-evo/conf/nxengine/settings.dat")" "PAKDEFAULT" "first run installs pak settings"
[ -f "$fake/nxengine-evo/conf/nxengine/.gt-h700-settings" ] || { echo "marker not written"; exit 1; }
# player rebinds in-game -> settings.dat changes; the marker must keep it
printf 'USERCHANGED' > "$fake/nxengine-evo/conf/nxengine/settings.dat"
PAK_DIR="$fake/pak" GAMEDIR="$fake/nxengine-evo" PLATFORM=h700 sh "$fake/install.sh" >/dev/null 2>&1 || true
assert_eq "$(cat "$fake/nxengine-evo/conf/nxengine/settings.dat")" "USERCHANGED" "second run preserves the player's settings (install-once)"
# a non-nxengine port must never be touched
mkdir -p "$fake/otherport/conf/nxengine"
PAK_DIR="$fake/pak" GAMEDIR="$fake/otherport" PLATFORM=h700 sh "$fake/install.sh" >/dev/null 2>&1 || true
[ ! -f "$fake/otherport/conf/nxengine/settings.dat" ] || { echo "installed into a non-nxengine port"; exit 1; }

# the shipped blob is the validated h700 mapping: 964 bytes, NXS7 magic, res=2
# (640x480), directions bound to hat0 (jbut=-1, jhat=0, jhat_value L=8/R=2/U=1/
# D=4), JUMP->raw4, FIRE->raw3. Guards the binary artifact against corruption.
[ -f "$ROOT/assets/nxengine-evo-h700-settings.dat" ] || { echo "missing assets/nxengine-evo-h700-settings.dat"; exit 1; }
python3 - "$ROOT/assets/nxengine-evo-h700-settings.dat" <<'PY'
import struct, sys
b = open(sys.argv[1], "rb").read()
assert len(b) == 964, f"size {len(b)}"
assert b[:4] == b"NXS7", "magic"
assert struct.unpack_from("<i", b, 4)[0] == 2, "resolution != 2 (640x480)"
def field(idx, off): return struct.unpack_from("<i", b, 36 + idx*24 + off)[0]
for idx, hv in [(0, 8), (1, 2), (2, 1), (3, 4)]:   # LEFT RIGHT UP DOWN
    assert field(idx, 4) == -1, f"dir {idx} jbut should be unbound"
    assert field(idx, 8) == 0,  f"dir {idx} jhat should be hat 0"
    assert field(idx, 12) == hv, f"dir {idx} jhat_value should be {hv}"
assert field(4, 4) == 4, "JUMP jbut should be raw 4"
assert field(5, 4) == 3, "FIRE jbut should be raw 3"
print("blob ok")
PY

# --- idempotency of the edit itself ---
GT_STAGE_EDIT_ONLY="$work" sh "$ROOT/build/build-pak.sh" portmaster
assert_eq "$(grep -c 'gt_nxe_src=' "$work/launch.sh")" "1" "install hook inserted exactly once"
sh -n "$work/launch.sh" || { echo "edited launch.sh does not parse after rerun"; exit 1; }

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

# Idempotency: the stamp must actually GATE the write, not merely happen to
# reproduce the same bytes (re-running conform with a layout that's already
# in place would look byte-identical even with the stamp check deleted).
# Simulate a player's in-game rebind (mutate JUMP.jbut to a sentinel) right
# after a conform, then rerun conform with the SAME layout — a working stamp
# short-circuits and must leave the rebind untouched.
printf '\143\000\000\000' | dd of="$tmp/settings.dat" bs=1 seek=136 conv=notrunc 2>/dev/null  # sentinel=99
[ "$(byte_at "$tmp/settings.dat" 136)" = "99" ] || { echo "setup: sentinel write failed"; exit 1; }
"$conform" "$tmp/settings.dat" xbox
[ "$(byte_at "$tmp/settings.dat" 136)" = "99" ] || { echo "stamp did not gate the write: in-game rebind was clobbered"; exit 1; }

# Non-NXS7 file untouched.
printf 'JUNKdata' > "$tmp/junk"; cp "$tmp/junk" "$tmp/junk.bak"
"$conform" "$tmp/junk" nintendo
cmp -s "$tmp/junk" "$tmp/junk.bak" || { echo "conform touched non-NXS7 file"; exit 1; }

# Wrong-size file (even with the correct NXS7 magic) must be a no-op: the
# @136/@160 offsets are meaningless on a truncated file and conv=notrunc
# would zero-extend it into a corrupt 964-byte file. Refuse instead. Uses its
# own directory since the stamp path is dirname($f)/.gt-h700-layout, and
# $tmp already holds a stamp from the earlier settings.dat conform calls.
mkdir -p "$tmp/shortdir"
printf 'NXS7short' > "$tmp/shortdir/settings.dat"; cp "$tmp/shortdir/settings.dat" "$tmp/shortdir/settings.dat.bak"
"$conform" "$tmp/shortdir/settings.dat" nintendo
cmp -s "$tmp/shortdir/settings.dat" "$tmp/shortdir/settings.dat.bak" || { echo "conform touched wrong-size NXS7 file"; exit 1; }
[ -f "$tmp/shortdir/.gt-h700-layout" ] && { echo "conform stamped a wrong-size file"; exit 1; }
rm -rf "$tmp"

# F49: helper staged + injector wired into the staged launch.sh.
assert_contains "$work/launch.sh" 'gt-h700-nxengine-layout (F49)'
assert_contains "$work/launch.sh" 'files/gt-nxengine-conform-layout.sh'
# $work/launch.sh has already been through a second GT_STAGE_EDIT_ONLY pass
# (the F39 idempotency rerun above) — verify that pass did not double-insert
# the F49 block (a bare assert_contains/grep -q would pass either way).
n_nxlayout=$(grep -c 'gt-h700-nxengine-layout' "$work/launch.sh")
assert_eq "$n_nxlayout" "1" "nxengine layout injector inserted more than once"
