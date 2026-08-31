#!/bin/sh
. "$(dirname -- "$0")/helpers.sh"

# F47: sleep support for ports — gt-sleepmon spawn/kill wiring + ALSA
# suspend-proxy routing. See docs/h700-fixes.md F47 and the spec at
# docs/superpowers/specs/2026-08-31-port-sleep-design.md.
work="$SANDBOX/pmpak"; mkdir -p "$work"
cp "$TROOT/fixtures/portmaster-pak-skeleton/pak.json.fixture" "$work/pak.json"
cp "$TROOT/fixtures/portmaster-pak-skeleton/launch.sh.fixture" "$work/launch.sh"
GT_STAGE_EDIT_ONLY="$work" sh "$ROOT/build/build-pak.sh" portmaster

# ---------- markers present ----------
assert_contains "$work/launch.sh" 'gt-h700-sleepmon'
assert_contains "$work/launch.sh" 'gt-h700-sleepmon-kill'

# ---------- spawn block wiring ----------
# shellcheck disable=SC2016
assert_contains "$work/launch.sh" 'export ALSA_CONFIG_PATH=/tmp/gt-asound.conf'
# shellcheck disable=SC2016
assert_contains "$work/launch.sh" 'sed "s|@PAK_DIR@|\$PAK_DIR|g" "\$PAK_DIR/files/gt-asound.conf"'
# shellcheck disable=SC2016
assert_contains "$work/launch.sh" '"\$PAK_DIR/bin/gt-sleepmon" \$\$ >/tmp/gt-sleepmon.log'
# shellcheck disable=SC2016
assert_contains "$work/launch.sh" 'files/gt-sleep-blocklist.txt'
assert_contains "$work/launch.sh" 'use-sleep-blocklist'

# ---------- fail-closed: the export is gated on a non-empty generated conf ----------
# (a missing/empty template must not leave the port routed at an empty
# ALSA_CONFIG_PATH — that is worse than no routing at all)
# (patterns avoid an unescaped '[' — BRE bracket-expression trap, see test-20)
# shellcheck disable=SC2016
assert_contains "$work/launch.sh" '-s /tmp/gt-asound.conf ]; then'
assert_contains "$work/launch.sh" 'gt-asound.conf template missing/empty; sleep audio proxy disabled'

# ---------- placement: gen -> non-empty guard -> export; spawn unconditional; kill inside cleanup ----------
exec_line=$(grep -n '"\$PAK_DIR/bin/bash" "\$ROM_PATH"' "$work/launch.sh" | head -1 | cut -d: -f1)
spawn_line=$(grep -n 'bin/gt-sleepmon' "$work/launch.sh" | head -1 | cut -d: -f1)
[ "$spawn_line" -lt "$exec_line" ] || { echo "sleepmon spawn not before exec"; exit 1; }
# shellcheck disable=SC2016
gen_line=$(grep -n 'sed "s|@PAK_DIR@|\$PAK_DIR|g" "\$PAK_DIR/files/gt-asound.conf"' "$work/launch.sh" | head -1 | cut -d: -f1)
guard_line=$(grep -n 'if \[ -s /tmp/gt-asound.conf \]; then' "$work/launch.sh" | head -1 | cut -d: -f1)
export_line=$(grep -n 'export ALSA_CONFIG_PATH=/tmp/gt-asound.conf' "$work/launch.sh" | head -1 | cut -d: -f1)
[ "$gen_line" -lt "$guard_line" ] || { echo "conf not generated before the non-empty guard"; exit 1; }
[ "$guard_line" -lt "$export_line" ] || { echo "export not inside the non-empty guard"; exit 1; }
[ "$export_line" -lt "$spawn_line" ] || { echo "export not before sleepmon spawn"; exit 1; }
# the spawn call itself must sit AFTER the guard's closing fi (unconditional: sleep still
# works with no audio proxy), not nested inside the non-empty branch only
guard_fi_line=$(awk -v start="$guard_line" 'NR>start && /^ +fi$/ {print NR; exit}' "$work/launch.sh")
[ "$guard_fi_line" -lt "$spawn_line" ] || { echo "sleepmon spawn nested inside the non-empty guard"; exit 1; }
cleanup_line=$(grep -n '^cleanup() {' "$work/launch.sh" | head -1 | cut -d: -f1)
kill_line=$(grep -n 'gt-h700-sleepmon-kill (F47)' "$work/launch.sh" | head -1 | cut -d: -f1)
[ "$kill_line" -gt "$cleanup_line" ] || { echo "kill not inside cleanup"; exit 1; }
[ "$kill_line" -lt "$((cleanup_line + 8))" ] || { echo "kill not at cleanup head"; exit 1; }

# ---------- behavioral: the guard actually withholds export on an empty/missing template ----------
# Slice the spawn block's live body (conf generation through the sleepmon
# spawn call) out of the staged launch.sh and run it standalone against a
# fake PAK_DIR, once with a real template and once with an empty one — proves
# the guard, not just its text, controls the export.
fake="$SANDBOX/fake-alsa"; mkdir -p "$fake/pak/files" "$fake/pak/bin"
sed -n "${gen_line},${spawn_line}p" "$work/launch.sh" > "$fake/spawn-body.sh"
printf '#!/bin/sh\ntrue\n' > "$fake/pak/bin/gt-sleepmon"; chmod +x "$fake/pak/bin/gt-sleepmon"

printf 'pcm.!default { type plug slave.pcm "@PAK_DIR@/hw" }\n' > "$fake/pak/files/gt-asound.conf"
rm -f /tmp/gt-asound.conf
( cd "$fake" && PAK_DIR="$fake/pak" sh -c '. ./spawn-body.sh; [ "$ALSA_CONFIG_PATH" = "/tmp/gt-asound.conf" ]' >/dev/null 2>&1 ) \
  || { echo "ALSA_CONFIG_PATH not exported for a real template"; exit 1; }

: > "$fake/pak/files/gt-asound.conf"  # empty template (e.g. a missing/corrupt asset)
rm -f /tmp/gt-asound.conf
( cd "$fake" && PAK_DIR="$fake/pak" sh -c '. ./spawn-body.sh; [ -z "${ALSA_CONFIG_PATH:-}" ]' >/dev/null 2>&1 ) \
  || { echo "ALSA_CONFIG_PATH stayed exported for an empty template — fail-open regression"; exit 1; }
rm -f /tmp/gt-asound.conf

# ---------- parses + idempotent ----------
sh -n "$work/launch.sh" || { echo "edited launch.sh does not parse"; exit 1; }
GT_STAGE_EDIT_ONLY="$work" sh "$ROOT/build/build-pak.sh" portmaster
n=$(grep -c 'gt-h700-sleepmon-kill (F47)' "$work/launch.sh")
assert_eq "$n" 1 "cleanup kill spliced twice — marker guard broken"
n2=$(grep -c 'gt-h700-sleepmon / gt-h700-alsa-suspend (F47)' "$work/launch.sh")
assert_eq "$n2" 1 "spawn block spliced twice — marker guard broken"

# ---------- gt-asound.conf shape: self-contained, no alsa.conf include ----------
# alsa.conf's @hooks node loads /etc/asound.conf only AFTER the entire
# ALSA_CONFIG_PATH file is parsed, so an include here would let the stock
# pcm.!default clobber our override regardless of textual order
# (device-proven — see docs/h700-fixes.md F47). The config must instead be
# fully self-contained: its own ctl.hw stanza (for the ctl_elems hook) and
# an unconditional pcm.default (nothing left to override).
assert_not_contains "$ROOT/assets/gt-asound.conf" '^</usr/share/alsa/alsa.conf>'
assert_contains "$ROOT/assets/gt-asound.conf" 'ctl.hw {'
assert_contains "$ROOT/assets/gt-asound.conf" 'pcm.default {'
assert_not_contains "$ROOT/assets/gt-asound.conf" '^pcm\.!default'

# ---------- staging code present in build-pak.sh (fail-closed arch checks) ----------
assert_contains "$ROOT/build/build-pak.sh" 'cp "\$ASSETS/gt-sleepmon"'
assert_contains "$ROOT/build/build-pak.sh" 'cp "\$ASSETS/libasound_module_pcm_gt_suspend.so"'
assert_contains "$ROOT/build/build-pak.sh" 'cp "\$ASSETS/libasound_module_pcm_gt_suspend.armhf.so"'
assert_contains "$ROOT/build/build-pak.sh" 'cp "\$ASSETS/gt-sleep-blocklist.txt"'
assert_contains "$ROOT/build/build-pak.sh" 'cp "\$ASSETS/gt-asound.conf"'
assert_contains "$ROOT/build/build-pak.sh" 'gt-sleepmon is not an aarch64 executable'
assert_contains "$ROOT/build/build-pak.sh" 'gt_suspend plugin is not an aarch64 shared object'
assert_contains "$ROOT/build/build-pak.sh" 'gt_suspend armhf plugin is not a 32-bit ARM shared object'

echo "test-22-port-sleep OK"
