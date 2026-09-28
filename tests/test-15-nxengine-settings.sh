#!/bin/sh
. "$(dirname -- "$0")/helpers.sh"

# F39: nxengine-evo (Cave Story Evo) controls + resolution. The engine reads the
# raw SDL joystick and binds actions to button INDICES + a resolution INDEX in
# conf/nxengine/settings.dat. The porter's defaults bind directions to buttons
# 8-11 and faces to 0-7 for a device whose d-pad is buttons; on h700 the d-pad
# is an SDL hat and the faces sat at rc10 raw 3-13, so directions were dead and
# faces scrambled, and the default 720x720 render overran the 720x480 fb.
# run_port installs an h700-correct settings.dat ONCE per port install
# (marker-gated, so a player's in-game rebinds/resolution survive — unlike the
# always-overwrite F27 overlay); a port reinstall recreates conf/ and re-heals.
# F65: the shipped file is rc11-numbered and stamped .gt-h700-rc11; an install
# made before rc11 is translated once by the conform helper.
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
assert_contains "$work/launch.sh" 'touch "$GAMEDIR/conf/nxengine/.gt-h700-settings" "$GAMEDIR/conf/nxengine/.gt-h700-rc11"'

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
[ -f "$fake/nxengine-evo/conf/nxengine/.gt-h700-rc11" ] || { echo "F65: rc11 stamp not written on a fresh install"; exit 1; }
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
# D=4), and (F65) rc11 button numbers in the xbox layout: records 4-10 =
# 0,1,2,6,7,4,5 (JUMP=B b0, FIRE=A b1), records 11-27 unbound. Guards the
# binary artifact against corruption.
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
jb = [field(r, 4) for r in range(28)]
assert jb[4:11] == [0, 1, 2, 6, 7, 4, 5], f"records 4-10 jbut {jb[4:11]} != rc11 0,1,2,6,7,4,5"
assert jb[11:] == [-1] * 17, f"records 11-27 must stay unbound: {jb[11:]}"
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

# F65: rc11 values — B = b0 (bottom), A = b1 (right)
"$conform" "$tmp/settings.dat" nintendo
[ "$(byte_at "$tmp/settings.dat" 136)" = "1" ] || { echo "nintendo JUMP.jbut != 1"; exit 1; }
[ "$(byte_at "$tmp/settings.dat" 160)" = "0" ] || { echo "nintendo FIRE.jbut != 0"; exit 1; }
[ "$(wc -c < "$tmp/settings.dat")" -eq 964 ] || { echo "size changed"; exit 1; }
[ "$(dd if="$tmp/settings.dat" bs=1 count=4 2>/dev/null)" = "NXS7" ] || { echo "magic clobbered"; exit 1; }

"$conform" "$tmp/settings.dat" xbox
[ "$(byte_at "$tmp/settings.dat" 136)" = "0" ] || { echo "xbox JUMP.jbut != 0"; exit 1; }
[ "$(byte_at "$tmp/settings.dat" 160)" = "1" ] || { echo "xbox FIRE.jbut != 1"; exit 1; }

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

# --- F65: one-time rc10 -> rc11 migration of an install made before rc11 ---
jbuts() { # all 28 records' jbut, comma-separated
    python3 - "$1" <<'PY'
import struct, sys
b = open(sys.argv[1], "rb").read()
print(",".join(str(struct.unpack_from("<i", b, 36 + r * 24 + 4)[0]) for r in range(28)))
PY
}
mk_rc10() { # $1=dir [$2=rebinds]: a pre-F65 install — rc10 numbering as 0.4.0 shipped it
    mkdir -p "$1"
    python3 - "$ROOT/assets/nxengine-evo-h700-settings.dat" "$1/settings.dat" "${2:-}" <<'PY'
import struct, sys
b = bytearray(open(sys.argv[1], "rb").read())
for r, v in zip(range(4, 11), [4, 3, 5, 9, 10, 7, 8]):
    struct.pack_into("<i", b, 36 + r * 24 + 4, v)
if sys.argv[3]:   # a player's in-game rebinds: raw 12, 15, 13, 0 (ESC), 16, 2 (Vol+)
    for r, v in [(6, 12), (7, 15), (8, 13), (9, 0), (10, 16), (11, 2)]:
        struct.pack_into("<i", b, 36 + r * 24 + 4, v)
open(sys.argv[2], "wb").write(b)
PY
    touch "$1/.gt-h700-settings"
    echo xbox > "$1/.gt-h700-layout"
}
m="$SANDBOX/mig"; unbound16="-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1"
# the shipped rc11 blob IS the rc10 blob translated: migrating 0.4.0's file lands on it byte for byte
mk_rc10 "$m/stock"
GT_NEXTUI_RC11=1 GT_INPUT_CLASS=plain "$conform" "$m/stock/settings.dat" xbox
cmp -s "$m/stock/settings.dat" "$ROOT/assets/nxengine-evo-h700-settings.dat" || { echo "migrated 0.4.0 blob != shipped rc11 blob"; exit 1; }
[ -f "$m/stock/.gt-h700-rc11" ] || { echo "migration did not stamp .gt-h700-rc11"; exit 1; }
assert_eq "$(cat "$m/stock/.gt-h700-layout")" "xbox" "layout re-applied after migration"
# plain (RG SP) rebinds: L2 (12) / R2 (13) are axes on rc11, 15 was a park, ESC/GOTO gone -> -1; Vol+ 2 -> 14
mk_rc10 "$m/plain" rebinds
GT_NEXTUI_RC11=1 GT_INPUT_CLASS=plain "$conform" "$m/plain/settings.dat" xbox
assert_eq "$(jbuts "$m/plain/settings.dat")" "-1,-1,-1,-1,0,1,-1,-1,-1,-1,-1,14,$unbound16" "plain migration"
# sticks rebinds: L3 12 -> 9, R3 15 -> 10, L2 13 / ESC / GOTO 16 -> -1, Vol+ 2 -> 14
mk_rc10 "$m/sticks" rebinds
GT_NEXTUI_RC11=1 GT_INPUT_CLASS=sticks "$conform" "$m/sticks/settings.dat" xbox
assert_eq "$(jbuts "$m/sticks/settings.dat")" "-1,-1,-1,-1,0,1,9,10,-1,-1,-1,14,$unbound16" "sticks migration"
# once only: a second launch leaves the migrated file alone
cp "$m/sticks/settings.dat" "$m/sticks.bak"
GT_NEXTUI_RC11=1 GT_INPUT_CLASS=sticks "$conform" "$m/sticks/settings.dat" xbox
cmp -s "$m/sticks/settings.dat" "$m/sticks.bak" || { echo "migration re-ran on a stamped file"; exit 1; }
# waits for rc11: GT_NEXTUI_RC11 unset/0 -> no translation, no stamp
mk_rc10 "$m/old"
GT_NEXTUI_RC11=0 "$conform" "$m/old/settings.dat" xbox
assert_eq "$(jbuts "$m/old/settings.dat")" "-1,-1,-1,-1,4,3,5,9,10,7,8,-1,$unbound16" "no migration before rc11 (file untouched)"
[ ! -f "$m/old/.gt-h700-rc11" ] || { echo "stamped without rc11"; exit 1; }
# not a pak-installed file (no F39 marker) -> no translation
mk_rc10 "$m/foreign"; rm -f "$m/foreign/.gt-h700-settings"
GT_NEXTUI_RC11=1 "$conform" "$m/foreign/settings.dat" xbox
[ ! -f "$m/foreign/.gt-h700-rc11" ] || { echo "migrated a file the pak did not install"; exit 1; }

# a write failure partway through migration must not corrupt settings.dat or
# leave a stray temp file — retry-safety via the temp-copy-then-mv swap.
# a dd shim that fails from its 3rd of= call onward simulates a write dying
# mid-loop (real dd for the reads/other calls: found via `command -v` before
# the shim dir is prepended to PATH).
dd_real=$(command -v dd)
shim_dir="$SANDBOX/dd-shim"; mkdir -p "$shim_dir"
dd_count="$SANDBOX/dd-shim-count"
cat > "$shim_dir/dd" <<SHIMEOF
#!/bin/sh
has_of=0
for a in "\$@"; do
    case "\$a" in of=*) has_of=1 ;; esac
done
if [ "\$has_of" = 1 ]; then
    n=0
    [ -f "$dd_count" ] && n=\$(cat "$dd_count")
    n=\$((n + 1))
    echo "\$n" > "$dd_count"
    if [ "\$n" -ge 3 ]; then
        exit 1
    fi
fi
exec "$dd_real" "\$@"
SHIMEOF
chmod +x "$shim_dir/dd"
mk_rc10 "$m/crash" rebinds
cp "$m/crash/settings.dat" "$m/crash.bak"
PATH="$shim_dir:$PATH" GT_NEXTUI_RC11=1 GT_INPUT_CLASS=plain "$conform" "$m/crash/settings.dat" xbox
cmp -s "$m/crash/settings.dat" "$m/crash.bak" || { echo "crashed migration corrupted settings.dat"; exit 1; }
[ ! -f "$m/crash/.gt-h700-rc11" ] || { echo "crashed migration stamped .gt-h700-rc11"; exit 1; }
[ ! -f "$m/crash/settings.dat.gt-rc11.tmp" ] || { echo "crashed migration left a temp file behind"; exit 1; }
# retry with a healthy PATH must translate cleanly from the untouched original
GT_NEXTUI_RC11=1 GT_INPUT_CLASS=plain "$conform" "$m/crash/settings.dat" xbox
assert_eq "$(jbuts "$m/crash/settings.dat")" "-1,-1,-1,-1,0,1,-1,-1,-1,-1,-1,14,$unbound16" "retry after crashed migration"
[ -f "$m/crash/.gt-h700-rc11" ] || { echo "retry after crash did not stamp .gt-h700-rc11"; exit 1; }

# F49: helper staged + injector wired into the staged launch.sh.
assert_contains "$work/launch.sh" 'gt-h700-nxengine-layout (F49)'
assert_contains "$work/launch.sh" 'files/gt-nxengine-conform-layout.sh'
# $work/launch.sh has already been through a second GT_STAGE_EDIT_ONLY pass
# (the F39 idempotency rerun above) — verify that pass did not double-insert
# the F49 block (a bare assert_contains/grep -q would pass either way).
n_nxlayout=$(grep -c 'gt-h700-nxengine-layout' "$work/launch.sh")
assert_eq "$n_nxlayout" "1" "nxengine layout injector inserted more than once"
