#!/bin/sh
. "$(dirname -- "$0")/helpers.sh"

# F59: NextUI launches paks with the console (ttyS0) as stdin and run_port
# passed it straight to the port; every other CFW hands ports /dev/null. ECWolf
# (Wolfenstein 3D) falls into its console IWAD picker (the launcher's --data
# never matches: case-sensitive compare vs. an uppercase VSWAP.WL1) and then
# blocks in scanf() forever — the "black screen" in issue #1, gdb-proven on the
# RG SP 2026-09-04. With stdin=/dev/null the scanf fails and the picker returns
# the last set silently, exactly as on other CFWs. Generic: any port prompting on
# stdin gets an EOF instead of a hang.
work="$SANDBOX/pmpak"; mkdir -p "$work"
cp "$TROOT/fixtures/portmaster-pak-skeleton/pak.json.fixture" "$work/pak.json"
cp "$TROOT/fixtures/portmaster-pak-skeleton/launch.sh.fixture" "$work/launch.sh"
GT_STAGE_EDIT_ONLY="$work" sh "$ROOT/build/build-pak.sh" portmaster

assert_contains "$work/launch.sh" 'gt-h700-port-stdin'
# the exec line itself carries the redirect: upstream text + </dev/null + marker, one line
# shellcheck disable=SC2016
assert_contains "$work/launch.sh" '^    "\$PAK_DIR/bin/bash" "\$ROM_PATH" </dev/null  # gt-h700-port-stdin'
n=$(grep -c '"\$PAK_DIR/bin/bash" "\$ROM_PATH"' "$work/launch.sh")
assert_eq "$n" 1 "exactly one port exec line"

# every run_port splice that anchors on the PRISTINE exec line must still have
# fired — proves F59 runs last in edit_portmaster_launch
for m in 'gt-h700-port-remap / gt-h700-hud (F25/F26/F34)' 'gt-h700-fmod-audio' \
         'gt-h700-gles3-profile' 'gt-sdl-audio-init' 'gt-h700-sleepmon / gt-h700-alsa-suspend (F47)' \
         'gt-h700-preload-snapshot (F54)'; do
  assert_contains "$work/launch.sh" "$m"
done

# behavioral: the redirect really detaches the port from the launcher's stdin
exec_line=$(grep '"\$PAK_DIR/bin/bash" "\$ROM_PATH" </dev/null' "$work/launch.sh" | head -1)
printf '#!/bin/sh\nif read -r gt_x; then echo "READ:$gt_x"; else echo "EOF"; fi\n' > "$SANDBOX/port.sh"
mkdir -p "$SANDBOX/pak/bin"; ln -s "$(command -v sh)" "$SANDBOX/pak/bin/bash"
out=$(printf 'typed\n' | PAK_DIR="$SANDBOX/pak" ROM_PATH="$SANDBOX/port.sh" sh -c "$exec_line")
assert_eq "$out" "EOF" "port stdin is /dev/null, not the launcher's stdin"

sh -n "$work/launch.sh" || { echo "edited launch.sh does not parse"; exit 1; }
GT_STAGE_EDIT_ONLY="$work" sh "$ROOT/build/build-pak.sh" portmaster
assert_eq "$(grep -c 'gt-h700-port-stdin' "$work/launch.sh")" 1 "marker once after re-run"
assert_eq "$(grep -c '"\$PAK_DIR/bin/bash" "\$ROM_PATH"' "$work/launch.sh")" 1 "still one exec line after re-run"

echo "test-31-port-stdin: OK"
