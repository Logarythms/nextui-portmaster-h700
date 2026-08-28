#!/bin/sh
. "$(dirname -- "$0")/helpers.sh"

# parse-check
sh -n "$ROOT/build/build-pak.sh"

# run only the edit functions against the fixture pair
work="$SANDBOX/pmpak"; mkdir -p "$work"
cp "$TROOT/fixtures/portmaster-pak-skeleton/pak.json.fixture" "$work/pak.json"
cp "$TROOT/fixtures/portmaster-pak-skeleton/launch.sh.fixture" "$work/launch.sh"
GT_STAGE_EDIT_ONLY="$work" sh "$ROOT/build/build-pak.sh" portmaster

# marker + content present
assert_contains "$work/launch.sh" 'gt-h700-sonic-resolution'
assert_contains "$work/launch.sh" 's/LOW=214/LOW=360/'
assert_contains "$work/launch.sh" '"Sonic 1.sh"|"Sonic 2.sh")'

# placed INSIDE the F32 mtime window: resolution block after the snapshot touch -r line
snap=$(grep -n 'touch -r "$ROM_PATH" "$gt_launcher_mtime_ref"' "$work/launch.sh" | head -1 | cut -d: -f1)
res=$(grep -n 'gt-h700-sonic-resolution' "$work/launch.sh" | head -1 | cut -d: -f1)
[ -n "$snap" ] && [ -n "$res" ] && [ "$res" -gt "$snap" ] \
  || { echo "resolution block not inside F32 mtime window (snap=$snap res=$res)"; exit 1; }

# idempotent
GT_STAGE_EDIT_ONLY="$work" sh "$ROOT/build/build-pak.sh" portmaster
assert_eq "$(grep -c 'gt-h700-sonic-resolution' "$work/launch.sh")" "1"

# still parses
sh -n "$work/launch.sh"

# behavioral: slice the injected case block, run it against fake launchers.
# the block uses device-style `sed -i` (busybox/GNU); BSD sed (macOS dev
# machines) needs `-i ''`. Shim it into PATH only where sed is not GNU
# (same precedent as test-08-solarus-nojit.sh).
case $(sed --version 2>/dev/null) in
  *GNU*) : ;;
  *)
    mkdir -p "$SANDBOX/bin"
    printf '#!/bin/sh\nif [ "$1" = "-i" ]; then shift; exec /usr/bin/sed -i "" "$@"; fi\nexec /usr/bin/sed "$@"\n' > "$SANDBOX/bin/sed"
    chmod +x "$SANDBOX/bin/sed"
    PATH="$SANDBOX/bin:$PATH"; export PATH
    ;;
esac
block=$(sed -n '/# gt-h700-sonic-resolution:/,/esac/p' "$work/launch.sh")
mkfake() { printf 'LOW=214 # 3:2\nHIGH=426 # 16:9\n' > "$1"; }
run_block() { ROM_PATH="$1" PLATFORM="h700"; eval "$block"; }
mkfake "$SANDBOX/Sonic 1.sh"; run_block "$SANDBOX/Sonic 1.sh"
assert_contains "$SANDBOX/Sonic 1.sh" 'LOW=360'
mkfake "$SANDBOX/Other.sh";  run_block "$SANDBOX/Other.sh"
assert_contains "$SANDBOX/Other.sh" 'LOW=214'   # untouched

# docs coverage
assert_contains "$ROOT/docs/h700-fixes.md" 'F41'
echo "test-17 ok"
