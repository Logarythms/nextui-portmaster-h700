#!/bin/sh
. "$(dirname -- "$0")/helpers.sh"

# F28: solarus quests run with LuaJIT's JIT disabled. The solarus runtime
# bundles LuaJIT 2.1.0-beta3, whose aarch64 JIT miscompiles under quest
# load on this device — gdb-attach caught SIGSEGV jumps into unmapped
# trace memory from libluajit during Tunics! map transitions (2026-08-23).
#
# F36: solarus's -s= flag runs its VALUE as inline Lua, not a path, so the
# original F28 form (-s=<pak>/files/solarus-nojit.lua) errored at launch
# and the JIT stayed on. run_port now injects
# -s="dofile('<pak>/files/solarus-nojit.lua')" (still a jit.off()
# pre-script, just loaded via dofile()) into any port script that defines
# a solarus runtime, and self-heals launchers still carrying the old
# bare-path -s= form from before F36.
work="$SANDBOX/pmpak"; mkdir -p "$work"
cp "$TROOT/fixtures/portmaster-pak-skeleton/pak.json.fixture" "$work/pak.json"
cp "$TROOT/fixtures/portmaster-pak-skeleton/launch.sh.fixture" "$work/launch.sh"
GT_STAGE_EDIT_ONLY="$work" sh "$ROOT/build/build-pak.sh" portmaster

assert_contains "$work/launch.sh" 'gt-h700-solarus-nojit'
# shellcheck disable=SC2016
assert_contains "$work/launch.sh" 'solarus-nojit.lua'
sh -n "$work/launch.sh" || { echo "edited launch.sh does not parse"; exit 1; }
# placement: inside run_port, after GAMEDIR resolution, before the port exec
gamedir_line=$(grep -n 'echo "Game dir is: \$GAMEDIR"' "$work/launch.sh" | head -1 | cut -d: -f1)
nojit_line=$(grep -n 'gt-h700-solarus-nojit' "$work/launch.sh" | head -1 | cut -d: -f1)
# shellcheck disable=SC2016
bash_exec_line=$(grep -n '"\$PAK_DIR/bin/bash" "\$ROM_PATH"' "$work/launch.sh" | head -1 | cut -d: -f1)
[ "$gamedir_line" -lt "$nojit_line" ] || { echo "nojit hook is not after GAMEDIR resolution"; exit 1; }
[ "$nojit_line" -lt "$bash_exec_line" ] || { echo "nojit hook is not before the port exec"; exit 1; }

# behavioral: the extracted hook must inject -s= into a solarus port script
# exactly once (guard holds on re-run) and leave non-solarus scripts alone.
fake="$SANDBOX/fake"; mkdir -p "$fake"
cat > "$fake/Tunics.sh" <<'EOF'
runtime="solarus-1.6.5"
"$runtime" $GAMEDIR/*.solarus
EOF
cat > "$fake/Other.sh" <<'EOF'
runtime="love_11.5"
"$runtime" $GAMEDIR/game.love
EOF
sed -n '/grep -q "\^runtime=/,/^    fi$/p' "$work/launch.sh" > "$fake/hook.sh"
[ -s "$fake/hook.sh" ] || { echo "could not extract nojit hook"; exit 1; }
# the inner "fi" (heal/elif if) is 8-space-indented; only the outer
# 4-space "fi" should end the sed range, so both branches must be present.
assert_contains "$fake/hook.sh" 'Healing solarus no-JIT'
assert_contains "$fake/hook.sh" 'elif ! grep -q "solarus-nojit"'
# the hook uses device-style `sed -i` (busybox/GNU); BSD sed (macOS dev
# machines) needs `-i ''`. Shim it into PATH only where sed is not GNU.
case $(sed --version 2>/dev/null) in
  *GNU*) : ;;
  *)
    mkdir -p "$fake/bin"
    printf '#!/bin/sh\nif [ "$1" = "-i" ]; then shift; exec /usr/bin/sed -i "" "$@"; fi\nexec /usr/bin/sed "$@"\n' > "$fake/bin/sed"
    chmod +x "$fake/bin/sed"
    PATH="$fake/bin:$PATH"; export PATH
    ;;
esac
PLATFORM=h700 PAK_DIR=/mnt/PAK ROM_PATH="$fake/Tunics.sh" ROM_NAME="Tunics.sh" sh "$fake/hook.sh" >/dev/null
assert_contains "$fake/Tunics.sh" "\"\$runtime\" -s=\"dofile('/mnt/PAK/files/solarus-nojit.lua')\" \$GAMEDIR/\*.solarus"
PLATFORM=h700 PAK_DIR=/mnt/PAK ROM_PATH="$fake/Tunics.sh" ROM_NAME="Tunics.sh" sh "$fake/hook.sh" >/dev/null
assert_eq "$(grep -c 'solarus-nojit' "$fake/Tunics.sh")" "1" "guard held on second run"
PLATFORM=h700 PAK_DIR=/mnt/PAK ROM_PATH="$fake/Other.sh" ROM_NAME="Other.sh" sh "$fake/hook.sh" >/dev/null
assert_not_contains "$fake/Other.sh" 'solarus-nojit'

# behavioral: F36 self-heal — a launcher still carrying the old bare-path
# -s= form (pre-F36) must be rewritten to the dofile() form, not left
# broken or double-injected.
cat > "$fake/Heal.sh" <<'EOF'
runtime="solarus-1.6.5"
"$runtime" -s=/mnt/PAK/files/solarus-nojit.lua $GAMEDIR/*.solarus
EOF
PLATFORM=h700 PAK_DIR=/mnt/PAK ROM_PATH="$fake/Heal.sh" ROM_NAME="Heal.sh" sh "$fake/hook.sh" >/dev/null
assert_contains "$fake/Heal.sh" "\"\$runtime\" -s=\"dofile('/mnt/PAK/files/solarus-nojit.lua')\" \$GAMEDIR/\*.solarus"
assert_not_contains "$fake/Heal.sh" '-s=/mnt/PAK/files/solarus-nojit.lua '
PLATFORM=h700 PAK_DIR=/mnt/PAK ROM_PATH="$fake/Heal.sh" ROM_NAME="Heal.sh" sh "$fake/hook.sh" >/dev/null
assert_eq "$(grep -c 'solarus-nojit' "$fake/Heal.sh")" "1" "heal idempotent on second run"
assert_contains "$fake/Heal.sh" "\"\$runtime\" -s=\"dofile('/mnt/PAK/files/solarus-nojit.lua')\" \$GAMEDIR/\*.solarus"

# the pre-script asset itself must exist and actually turn the JIT off
assert_contains "$ROOT/assets/solarus-nojit.lua" 'jit.off()'

# --- idempotency of the edit itself ---
GT_STAGE_EDIT_ONLY="$work" sh "$ROOT/build/build-pak.sh" portmaster
assert_eq "$(grep -c 'gt-h700-solarus-nojit' "$work/launch.sh")" "1" "nojit marker idempotent"
sh -n "$work/launch.sh" || { echo "edited launch.sh does not parse after rerun"; exit 1; }
