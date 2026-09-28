#!/bin/sh
# gt-nxengine-conform-layout (F49/F65): keep Cave Story (nxengine-evo)
# settings.dat in line with NextUI rc11 and the resolved controller layout.
#   $1 = settings.dat path   $2 = layout (nintendo|xbox)
#   env GT_NEXTUI_RC11 (1 = rc11 firmware, from launch.sh's gt-h700-rc11 check)
#   env GT_INPUT_CLASS (plain|sticks, from launch.sh's gt-h700-input-class)
# Format (verified): magic "NXS7"@0, 964 bytes, 28 binding records of 24 bytes
# from offset 36; jbut = field 1 (record+4, LE int32, -1 = unbound).
# JUMP = record 4 -> jbut@136, FIRE = record 5 -> jbut@160.
#
# Step 1 (F65, once): a settings.dat the pak installed before rc11 (F39 marker
# present, no .gt-h700-rc11 stamp) binds rc10 raw indices. Translate every
# record's jbut to rc11's fixed numbering, so in-game rebinds survive, then
# stamp. Waits for rc11 firmware (GT_NEXTUI_RC11=1).
# Step 2 (F49): swap JUMP/FIRE to the layout, idempotent via .gt-h700-layout.
# rc11: B = b0 (bottom), A = b1 (right).
#   nintendo: JUMP=1 (A, right), FIRE=0 (B, bottom)   xbox: JUMP=0, FIRE=1
f="$1"
layout="$2"
[ -f "$f" ] || exit 0
case "$layout" in nintendo|xbox) ;; *) layout=nintendo ;; esac
dir=$(dirname "$f")

# Magic guard: bytes 0-3 must be "NXS7".
if [ "$(dd if="$f" bs=1 count=4 2>/dev/null)" != "NXS7" ]; then
    exit 0
fi

# Size guard: must be exactly the known 964-byte layout, else the record
# offsets are meaningless and conv=notrunc would zero-extend a truncated file.
[ "$(wc -c < "$f")" -eq 964 ] || exit 0

# Little-endian int32 for -1 or 0..255, as printf octal escapes.
le32() {
    if [ "$1" -lt 0 ]; then
        printf '\377\377\377\377'
    else
        printf "\\$(printf '%03o' "$1")\\000\\000\\000"
    fi
}

# rc10 raw SDL index -> rc11 index for one binding ($1 = old, $2 = class).
# rc10 (measured, F25/F52): 0 ESC, 1/2 Vol-/Vol+, 3 A, 4 B, 5 Y, 6 X, 7 L1,
# 8 R1, 9 Select, 10 Start, 11 Menu; plain 12/13 L2/R2, 14 GOTO echo; sticks
# 12 L3, 13/14 L2/R2, 15 R3, 16 GOTO echo. rc11 has no ESC/echo button and
# reports L2/R2 as axes, so those become -1 (unbound).
rc11_jbut() {
    case "$1" in
        1) echo 13 ;;  2) echo 14 ;;
        3) echo 1 ;;   4) echo 0 ;;   5) echo 2 ;;   6) echo 3 ;;
        7) echo 4 ;;   8) echo 5 ;;   9) echo 6 ;;  10) echo 7 ;;  11) echo 8 ;;
        12) if [ "$2" = sticks ]; then echo 9; else echo -1; fi ;;
        15) if [ "$2" = sticks ]; then echo 10; else echo -1; fi ;;
        *) echo -1 ;;
    esac
}

if [ "${GT_NEXTUI_RC11:-0}" = 1 ] && [ -f "$dir/.gt-h700-settings" ] && [ ! -f "$dir/.gt-h700-rc11" ]; then
    class=${GT_INPUT_CLASS:-plain}
    ok=1; n=0
    # Translate into a temp copy, not the file in place: a write failure
    # partway through would leave some records already rc11-numbered and
    # others still at rc10 raw indices, indistinguishable on retry from an
    # untouched file. rc11_jbut() is not idempotent on its own output range
    # (rc11_jbut(2)=14, rc11_jbut(0)=-1, rc11_jbut(1)=13), so re-running it
    # over a partially translated file would scramble the already-migrated
    # records instead of retrying cleanly.
    tmp="$f.gt-rc11.tmp"
    cp -f "$f" "$tmp" 2>/dev/null || ok=0
    # All 28 records x 6 int32 fields in one read; field 1 of each is jbut.
    for v in $(od -An -v -t d4 -j 36 -N 672 "$f"); do
        if [ "$ok" = 1 ] && [ $((n % 6)) -eq 1 ]; then
            new=$(rc11_jbut "$v" "$class")
            if [ "$new" != "$v" ]; then
                le32 "$new" | dd of="$tmp" bs=1 seek=$((36 + n * 4)) conv=notrunc 2>/dev/null || ok=0
            fi
        fi
        n=$((n + 1))
    done
    [ "$n" -eq 168 ] || ok=0
    if [ "$ok" = 1 ]; then
        mv -f "$tmp" "$f" 2>/dev/null || ok=0
    fi
    if [ "$ok" = 1 ]; then
        # The only remaining window: a crash between the mv above and this
        # touch would leave $f already rc11-numbered but unstamped, so a
        # retry would re-run rc11_jbut() over already-rc11 values.
        touch "$dir/.gt-h700-rc11"
        rm -f "$dir/.gt-h700-layout"   # re-apply the layout below on the rc11 values
    else
        rm -f "$tmp"
    fi
fi

stamp="$dir/.gt-h700-layout"
if [ -f "$stamp" ] && [ "$(cat "$stamp" 2>/dev/null)" = "$layout" ]; then
    exit 0
fi

ok=1
if [ "$layout" = "nintendo" ]; then
    le32 1 | dd of="$f" bs=1 seek=136 conv=notrunc 2>/dev/null || ok=0  # JUMP=1 (A, right)
    le32 0 | dd of="$f" bs=1 seek=160 conv=notrunc 2>/dev/null || ok=0  # FIRE=0 (B, bottom)
else
    le32 0 | dd of="$f" bs=1 seek=136 conv=notrunc 2>/dev/null || ok=0  # JUMP=0 (bottom)
    le32 1 | dd of="$f" bs=1 seek=160 conv=notrunc 2>/dev/null || ok=0  # FIRE=1 (right)
fi

# Only record success if both writes actually succeeded — a swallowed dd
# failure (read-only fs, disk full) must not stamp a mapping that was never
# written, or a later launch would skip re-patching and silently keep the
# wrong bindings.
[ "$ok" = 1 ] && echo "$layout" > "$stamp"
