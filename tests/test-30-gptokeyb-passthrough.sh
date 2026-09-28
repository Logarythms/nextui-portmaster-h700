#!/bin/sh
. "$(dirname -- "$0")/helpers.sh"

# F54 gptokeyb passthrough. NextUI's SDL2 is a no-libudev build: its evdev
# keyboard/mouse layer opens ONLY the devices named in SDL_EVDEV_DEVICES, so
# gptokeyb's uinput "Fake Keyboard" never reached games. The shim now resolves
# that node at SDL init and exports the variable; the pure parser + env
# builder are host-tested here through the -DGT_REMAP_TEST binary's fixture
# mode. Parts B (preload-append helper) and C (launch.sh edits) follow.

# --- Part A: /proc/bus/input/devices parser + SDL_EVDEV_DEVICES builder ---
command -v cc >/dev/null 2>&1 || { echo "cc not found"; exit 1; }
cc -DGT_REMAP_TEST -O2 -Wall -o "$SANDBOX/remap-test" "$ROOT/assets/gt-input-remap.c" \
    || { echo "gt-input-remap.c failed to compile under -DGT_REMAP_TEST"; exit 1; }
FIX="$TROOT/fixtures/input-devices"
assert_eq "$("$SANDBOX/remap-test" --fake-kbd "$FIX/rgsp.txt")" "none" \
    "bare RG SP snapshot has no Fake Keyboard"
assert_eq "$("$SANDBOX/remap-test" --fake-kbd "$FIX/rgsp-gptokeyb.txt")" "/dev/input/event3" \
    "single Fake Keyboard stanza resolves to its event node"
assert_eq "$("$SANDBOX/remap-test" --fake-kbd "$FIX/rgsp-gptokeyb-two.txt")" "/dev/input/event3" \
    "two stanzas: highest inputN (input6 -> event3) wins over the higher eventN (input5 -> event4)"
if "$SANDBOX/remap-test" --fake-kbd "$SANDBOX/does-not-exist" >/dev/null 2>&1; then
    echo "missing snapshot file must exit nonzero"; exit 1
fi
# the no-argument path (test-05 / test-26 contract) must be untouched
assert_eq "$("$SANDBOX/remap-test")" "remap ok" "no-arg host test still passes"

# --- Part B: gt-preload-append.sh — launchers that OVERWRITE LD_PRELOAD ---
# Doom Engines does `export LD_PRELOAD="$GAMEDIR/libs/hacksdl.so"`, dropping
# every pak shim from the engine. run_port runs this helper on the launcher
# (inside the F32 mtime window); it prepends run_port's snapshot of the pak
# chain, GT_LD_PRELOAD, to every overwrite-style export line.
helper="$ROOT/assets/gt-preload-append.sh"
[ -f "$helper" ] || { echo "missing assets/gt-preload-append.sh"; exit 1; }
L="$SANDBOX/Doom Engines.sh"
cat > "$L" <<'EOF'
#!/bin/bash
export LD_PRELOAD=hacksdl.so
export LD_PRELOAD="$GAMEDIR/libs/hacksdl.so"
    export LD_PRELOAD="$GAMEDIR/libs/hacksdl.so" # keyboard only
export LD_PRELOAD="$GAMEDIR/libs/x.so:$LD_PRELOAD"
# export LD_PRELOAD=commented.so
export LD_PRELOAD=
./engines/$ENGINE $ARGS
EOF
cat > "$SANDBOX/want.sh" <<'EOF'
#!/bin/bash
export LD_PRELOAD="${GT_LD_PRELOAD}${GT_LD_PRELOAD:+:}"hacksdl.so
export LD_PRELOAD="${GT_LD_PRELOAD}${GT_LD_PRELOAD:+:}""$GAMEDIR/libs/hacksdl.so"
    export LD_PRELOAD="${GT_LD_PRELOAD}${GT_LD_PRELOAD:+:}""$GAMEDIR/libs/hacksdl.so" # keyboard only
export LD_PRELOAD="$GAMEDIR/libs/x.so:$LD_PRELOAD"
# export LD_PRELOAD=commented.so
export LD_PRELOAD="${GT_LD_PRELOAD}${GT_LD_PRELOAD:+:}"
./engines/$ENGINE $ARGS
EOF
sh "$helper" "$L"
cmp -s "$L" "$SANDBOX/want.sh" || { echo "preload-append: output mismatch"; diff "$SANDBOX/want.sh" "$L"; exit 1; }
cp "$L" "$SANDBOX/first.sh"
sh "$helper" "$L"
cmp -s "$L" "$SANDBOX/first.sh" || { echo "preload-append: second run must be a no-op"; diff "$SANDBOX/first.sh" "$L"; exit 1; }
# semantics: the pak chain loads first, the launcher's own lib after it
printf '%s\n' 'export LD_PRELOAD=hacksdl.so' > "$SANDBOX/s1.sh"; sh "$helper" "$SANDBOX/s1.sh"
assert_eq "$(GT_LD_PRELOAD=/pak/a.so:/pak/b.so sh -c '. "$1"; printf %s "$LD_PRELOAD"' sh "$SANDBOX/s1.sh")" \
    "/pak/a.so:/pak/b.so:hacksdl.so" "pak chain first, launcher lib after"
assert_eq "$(GT_LD_PRELOAD= sh -c '. "$1"; printf %s "$LD_PRELOAD"' sh "$SANDBOX/s1.sh")" \
    "hacksdl.so" "empty snapshot adds no leading colon"
printf '%s\n' 'export LD_PRELOAD="$GAMEDIR/libs/hacksdl.so"' > "$SANDBOX/s2.sh"; sh "$helper" "$SANDBOX/s2.sh"
assert_eq "$(GT_LD_PRELOAD=/pak/a.so GAMEDIR=/g sh -c '. "$1"; printf %s "$LD_PRELOAD"' sh "$SANDBOX/s2.sh")" \
    "/pak/a.so:/g/libs/hacksdl.so" "quoted variable value survives"
# a launcher with no candidate line is never rewritten (inode + mtime kept)
printf '%s\n' '#!/bin/bash' 'echo hi' > "$SANDBOX/plain.sh"
touch -t 200001010000 "$SANDBOX/plain.sh"; touch -r "$SANDBOX/plain.sh" "$SANDBOX/plain.ref"
inode_before=$(ls -i "$SANDBOX/plain.sh" | awk '{print $1}')
sh "$helper" "$SANDBOX/plain.sh"
assert_eq "$(ls -i "$SANDBOX/plain.sh" | awk '{print $1}')" "$inode_before" "untouched launcher keeps its inode"
[ -z "$(find "$SANDBOX/plain.sh" -newer "$SANDBOX/plain.ref")" ] || { echo "untouched launcher must keep its mtime"; exit 1; }
# a patched launcher keeps its exec bit AND its inode (cat-back, not rename)
printf '%s\n' 'export LD_PRELOAD=hacksdl.so' > "$SANDBOX/sx.sh"
chmod +x "$SANDBOX/sx.sh"
inode_x_before=$(ls -i "$SANDBOX/sx.sh" | awk '{print $1}')
sh "$helper" "$SANDBOX/sx.sh"
[ -x "$SANDBOX/sx.sh" ] || { echo "patched launcher lost its exec bit"; exit 1; }
assert_eq "$(ls -i "$SANDBOX/sx.sh" | awk '{print $1}')" "$inode_x_before" "patched launcher keeps its inode"
grep -q 'GT_LD_PRELOAD' "$SANDBOX/sx.sh" || { echo "helper did not rewrite the executable launcher"; exit 1; }

# --- Part C: run_port edits (edit_portmaster_launch) ---
work="$SANDBOX/pmpak"; mkdir -p "$work"
cp "$TROOT/fixtures/portmaster-pak-skeleton/pak.json.fixture" "$work/pak.json"
cp "$TROOT/fixtures/portmaster-pak-skeleton/launch.sh.fixture" "$work/launch.sh"
GT_STAGE_EDIT_ONLY="$work" sh "$ROOT/build/build-pak.sh" portmaster
# blocklist gate (opt-out, HUD/sleep shape) inside the port-remap block
assert_contains "$work/launch.sh" 'gt-passthrough-blocklist.txt'
assert_contains "$work/launch.sh" 'use-passthrough-blocklist'
assert_contains "$work/launch.sh" 'gptokeyb passthrough disabled (blocklisted) for $ROM_NAME'
assert_contains "$work/launch.sh" 'export GT_PASSTHROUGH=0'
# helper call inside the F32 mtime window, h700 only
assert_contains "$work/launch.sh" 'sh "$PAK_DIR/files/gt-preload-append.sh" "$ROM_PATH"'
snap=$(grep -n 'touch -r "$ROM_PATH" "$gt_launcher_mtime_ref"' "$work/launch.sh" | head -1 | cut -d: -f1)
restore=$(grep -n 'touch -r "$gt_launcher_mtime_ref" "$ROM_PATH"' "$work/launch.sh" | head -1 | cut -d: -f1)
helper_line=$(grep -n 'gt-preload-append.sh" "$ROM_PATH"' "$work/launch.sh" | head -1 | cut -d: -f1)
[ "$snap" -lt "$helper_line" ] && [ "$helper_line" -lt "$restore" ] \
    || { echo "preload-append call must sit inside the mtime window ($snap < $helper_line < $restore)"; exit 1; }
# snapshot of the final pak chain, immediately before the launcher exec
assert_contains "$work/launch.sh" 'export GT_LD_PRELOAD="${LD_PRELOAD:-}"'
snapshot_line=$(grep -n 'export GT_LD_PRELOAD=' "$work/launch.sh" | head -1 | cut -d: -f1)
exec_line=$(grep -n '"$PAK_DIR/bin/bash" "$ROM_PATH"' "$work/launch.sh" | head -1 | cut -d: -f1)
assert_eq "$((exec_line - snapshot_line))" "2" "GT_LD_PRELOAD export is the last statement before the launcher exec"
lp=$(grep -n 'export LD_PRELOAD="$PAK_DIR/lib/gt-input-remap.so' "$work/launch.sh" | head -1 | cut -d: -f1)
[ "$lp" -lt "$snapshot_line" ] || { echo "snapshot must follow the shim preload export"; exit 1; }
# idempotent re-run
GT_STAGE_EDIT_ONLY="$work" sh "$ROOT/build/build-pak.sh" portmaster
assert_eq "$(grep -c 'export GT_LD_PRELOAD=' "$work/launch.sh")" "1" "one snapshot after rerun"
assert_eq "$(grep -c 'gt-preload-append.sh" "$ROM_PATH"' "$work/launch.sh")" "1" "one helper call after rerun"
assert_eq "$(grep -c 'export GT_PASSTHROUGH=0' "$work/launch.sh")" "1" "one blocklist gate after rerun"
# pak-shipped blocklist: Sonic 1/2 stay on synthesis (F43 overlay; face naming under gptokeyb unverified)
bl="$ROOT/assets/gt-passthrough-blocklist.txt"
[ -f "$bl" ] || { echo "missing assets/gt-passthrough-blocklist.txt"; exit 1; }
assert_eq "$(grep -v '^#' "$bl" | grep -v '^$' | sort | tr '\n' '|')" "Sonic 1.sh|Sonic 2.sh|" "blocklist ships exactly Sonic 1/2"
# staging: both assets copied into files/ (grep the build script; edit-only mode does not stage)
assert_contains "$ROOT/build/build-pak.sh" 'cp "$ASSETS/gt-passthrough-blocklist.txt" "$assembled/files/gt-passthrough-blocklist.txt"'
assert_contains "$ROOT/build/build-pak.sh" 'cp -f "$ASSETS/gt-preload-append.sh" "$assembled/files/gt-preload-append.sh"'
assert_contains "$ROOT/build/build-pak.sh" 'chmod +x "$assembled/files/gt-preload-append.sh"'

echo "test-30-gptokeyb-passthrough OK"
