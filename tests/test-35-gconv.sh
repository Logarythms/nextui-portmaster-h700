#!/bin/sh
. "$(dirname -- "$0")/helpers.sh"

# F64: NextUI-h700 ships no glibc gconv modules, so iconv_open() fails for any
# charset outside glibc's builtins. Luanti converts every UI string UTF-8 ->
# UTF-32LE via iconv, so all its text read "<invalid UTF-8 string>" (v0.5.0
# device gate, RG SP rc10). The pak ships glibc's UTF-16/UTF-32 modules from the
# Ubuntu jammy libc6 build whose libc.so.6 is byte-identical to the device's,
# plus a trimmed gconv-modules, and run_port exports GCONV_PATH when it is safe.
# Device-proven: an iconv(UTF-8 -> UTF-32LE) probe fails without, works with.
PINS="$ROOT/pins.sh"; BUILD="$ROOT/build/build-pak.sh"; CONF="$ROOT/assets/gt-gconv-modules"
sh -n "$BUILD" || { echo "build-pak.sh does not parse"; exit 1; }
sh -n "$PINS"  || { echo "pins.sh does not parse"; exit 1; }

# ---------- pins: defined, referenced, well-formed ----------
for v in PM_LIBC6_JAMMY_DEB_URL PM_LIBC6_JAMMY_DEB_SHA256 PM_GCONV_UTF16_SO_SHA256 PM_GCONV_UTF32_SO_SHA256; do
  grep -q "^${v}=" "$PINS" || { echo "pins.sh missing definition: $v"; exit 1; }
  grep -q "\$${v}\b\|\${${v}}" "$BUILD" || { echo "build-pak.sh never references: $v"; exit 1; }
done
for v in PM_LIBC6_JAMMY_DEB_SHA256 PM_GCONV_UTF16_SO_SHA256 PM_GCONV_UTF32_SO_SHA256; do
  val=$(grep "^${v}=" "$PINS" | head -1 | cut -d= -f2)
  printf '%s' "$val" | grep -Eq '^[0-9a-f]{64}$' || { echo "$v is not a 64-hex sha256: '$val'"; exit 1; }
done
grep -q '^PM_LIBC6_JAMMY_DEB_URL="https://launchpadlibrarian.net/[0-9]*/libc6_2.35-0ubuntu3_arm64.deb"' "$PINS" \
  || { echo "PM_LIBC6_JAMMY_DEB_URL is not the Launchpad libc6 2.35-0ubuntu3 arm64 build"; exit 1; }

# ---------- build: explicit zstd unpack, each module checked against ITS OWN pin, staged under lib/gconv ----------
assert_contains "$BUILD" 'command -v zstd'
assert_contains "$BUILD" 'data.tar.zst | zstd -dc | tar -x'
# shellcheck disable=SC2016
assert_contains "$BUILD" 'gconv/UTF-16.so" "\$PM_GCONV_UTF16_SO_SHA256"'
# shellcheck disable=SC2016
assert_contains "$BUILD" 'gconv/UTF-32.so" "\$PM_GCONV_UTF32_SO_SHA256"'
# shellcheck disable=SC2016
assert_contains "$BUILD" 'mkdir -p "\$assembled/lib/gconv"'
# shellcheck disable=SC2016
assert_contains "$BUILD" '"\$assembled/lib/gconv/UTF-16.so"'
# shellcheck disable=SC2016
assert_contains "$BUILD" '"\$assembled/lib/gconv/UTF-32.so"'
# shellcheck disable=SC2016
assert_contains "$BUILD" 'cp "\$ASSETS/gt-gconv-modules" "\$assembled/lib/gconv/gconv-modules"'

# ---------- config asset: only shipped modules, and the conversions Luanti needs ----------
[ -f "$CONF" ] || { echo "assets/gt-gconv-modules missing"; exit 1; }
bad=$(awk '$1 == "module" && $4 != "UTF-16" && $4 != "UTF-32"' "$CONF")
[ -z "$bad" ] || { echo "gt-gconv-modules names a module the pak does not ship: $bad"; exit 1; }
awk '$1 == "module" && $2 == "UTF-32LE//" && $3 == "INTERNAL" && $4 == "UTF-32"' "$CONF" | grep -q . \
  || { echo "no UTF-32LE -> INTERNAL module line"; exit 1; }
awk '$1 == "module" && $2 == "INTERNAL" && $3 == "UTF-32LE//" && $4 == "UTF-32"' "$CONF" | grep -q . \
  || { echo "no INTERNAL -> UTF-32LE module line"; exit 1; }
awk '$1 == "module" && $2 == "UTF-16LE//" && $3 == "INTERNAL" && $4 == "UTF-16"' "$CONF" | grep -q . \
  || { echo "no UTF-16LE -> INTERNAL module line"; exit 1; }

# ---------- run_port splice: placement ----------
work="$SANDBOX/pmpak"; mkdir -p "$work"
cp "$TROOT/fixtures/portmaster-pak-skeleton/pak.json.fixture" "$work/pak.json"
cp "$TROOT/fixtures/portmaster-pak-skeleton/launch.sh.fixture" "$work/launch.sh"
GT_STAGE_EDIT_ONLY="$work" sh "$ROOT/build/build-pak.sh" portmaster
assert_contains "$work/launch.sh" 'gt-h700-gconv (F64)'
gamedir_line=$(grep -n 'echo "Game dir is: \$GAMEDIR"' "$work/launch.sh" | head -1 | cut -d: -f1)
exec_line=$(grep -n '"\$PAK_DIR/bin/bash" "\$ROM_PATH"' "$work/launch.sh" | head -1 | cut -d: -f1)
gc_line=$(grep -n 'gt-h700-gconv (F64)' "$work/launch.sh" | head -1 | cut -d: -f1)
[ "$gamedir_line" -lt "$gc_line" ] && [ "$gc_line" -lt "$exec_line" ] \
  || { echo "gconv splice not between GAMEDIR resolution and exec"; exit 1; }

# ---------- run_port splice: behaviour (sliced block, hooks for libc + system gconv) ----------
sed -n '/# gt-h700-gconv (F64)/,/^    fi$/p' "$work/launch.sh" > "$SANDBOX/gconv-block.sh"
pak="$SANDBOX/gcpak"; mkdir -p "$pak/lib/gconv"; : > "$pak/lib/gconv/gconv-modules"
printf 'x GNU C Library (Ubuntu GLIBC 2.35-0ubuntu3) stable release version 2.35. x\n' > "$SANDBOX/libc-match"
printf 'x GNU C Library (Ubuntu GLIBC 2.35-0ubuntu3.8) stable release version 2.35. x\n' > "$SANDBOX/libc-other"
: > "$SANDBOX/sys-gconv-present"
run_gc() { # $1=PLATFORM $2=libc file $3=system gconv path $4=preset GCONV_PATH ('' = unset); prints GCONV_PATH or "unset"
  ( env -i PATH="$PATH" PLATFORM="$1" PAK_DIR="$pak" GT_LIBC_PATH="$2" GT_SYS_GCONV="$3" ${4:+GCONV_PATH="$4"} \
      sh -c ". \"$SANDBOX/gconv-block.sh\" >/dev/null; printf '%s' \"\${GCONV_PATH:-unset}\"" )
}
assert_eq "$(run_gc h700 "$SANDBOX/libc-match" "$SANDBOX/none" '')" "$pak/lib/gconv" "h700 + matching glibc + no system gconv -> pak gconv"
assert_eq "$(run_gc h700 "$SANDBOX/libc-other" "$SANDBOX/none" '')" "unset" "a different glibc build -> no GCONV_PATH"
assert_eq "$(run_gc h700 "$SANDBOX/libc-match" "$SANDBOX/sys-gconv-present" '')" "unset" "firmware with its own gconv -> left alone"
assert_eq "$(run_gc h700 "$SANDBOX/libc-match" "$SANDBOX/none" /port/gconv)" "/port/gconv" "a port's own GCONV_PATH wins"
assert_eq "$(run_gc tg5040 "$SANDBOX/libc-match" "$SANDBOX/none" '')" "unset" "non-h700 untouched"
out=$(env -i PATH="$PATH" PLATFORM=h700 PAK_DIR="$pak" GT_LIBC_PATH="$SANDBOX/libc-match" GT_SYS_GCONV="$SANDBOX/none" sh -c ". \"$SANDBOX/gconv-block.sh\"")
case "$out" in *'GCONV_PATH -> pak UTF-16/UTF-32 conversion modules (F64)'*) ;; *) echo "missing F64 log line: $out"; exit 1;; esac
rm -f "$pak/lib/gconv/gconv-modules"
assert_eq "$(run_gc h700 "$SANDBOX/libc-match" "$SANDBOX/none" '')" "unset" "pak config not staged -> no GCONV_PATH"

sh -n "$work/launch.sh" || { echo "edited launch.sh does not parse"; exit 1; }
GT_STAGE_EDIT_ONLY="$work" sh "$ROOT/build/build-pak.sh" portmaster
assert_eq "$(grep -c 'gt-h700-gconv (F64)' "$work/launch.sh")" 1 "gconv marker once after re-run"

assert_contains "$ROOT/docs/h700-fixes.md" 'F64'
assert_contains "$ROOT/docs/h700-fixes.md" 'gconv'

echo "test-35-gconv: OK"
