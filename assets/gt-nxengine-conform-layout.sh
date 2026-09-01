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

# Size guard: must be exactly the known 964-byte layout, else the @136/@160
# offsets are meaningless and conv=notrunc would zero-extend a truncated file.
[ "$(wc -c < "$f")" -eq 964 ] || exit 0

ok=1
if [ "$layout" = "nintendo" ]; then
    printf '\003\000\000\000' | dd of="$f" bs=1 seek=136 conv=notrunc 2>/dev/null || ok=0  # JUMP=3 (right)
    printf '\004\000\000\000' | dd of="$f" bs=1 seek=160 conv=notrunc 2>/dev/null || ok=0  # FIRE=4 (bottom)
else
    printf '\004\000\000\000' | dd of="$f" bs=1 seek=136 conv=notrunc 2>/dev/null || ok=0  # JUMP=4 (bottom)
    printf '\003\000\000\000' | dd of="$f" bs=1 seek=160 conv=notrunc 2>/dev/null || ok=0  # FIRE=3 (right)
fi

# Only record success if both writes actually succeeded — a swallowed dd
# failure (read-only fs, disk full) must not stamp a mapping that was never
# written, or a later launch would skip re-patching and silently keep the
# wrong bindings.
[ "$ok" = 1 ] && echo "$layout" > "$stamp"
