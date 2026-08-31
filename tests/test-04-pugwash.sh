#!/bin/sh
. "$(dirname -- "$0")/helpers.sh"

# F6: pugwash's do_draw only presents once per self.updated dirty flag; on
# h700's malifbdev EGL swap chain a single present never reliably reaches
# the panel, so static scenes (message boxes, quit confirm, static lists)
# render black (confirmed on-device: with the gate neutralized the whole
# GUI renders and navigates correctly). gt-h700-redraw patches pugwash to
# also redraw when GT_FORCE_REDRAW=1; gt-h700-redraw-env sets that env
# h700-only in launch.sh, anchored on the gt-h700-syslib case block's bare
# "esac" (E3 must run first for that anchor to exist — exercised here via
# the full edit_portmaster_launch call, same as test-02/test-03).
work="$SANDBOX/pmpak"; mkdir -p "$work"
cp "$TROOT/fixtures/portmaster-pak-skeleton/pak.json.fixture" "$work/pak.json"
cp "$TROOT/fixtures/portmaster-pak-skeleton/launch.sh.fixture" "$work/launch.sh"
cp "$TROOT/fixtures/portmaster-pak-skeleton/pugwash.fixture" "$work/pugwash"
GT_STAGE_EDIT_ONLY="$work" sh "$ROOT/build/build-pak.sh" portmaster

# --- pugwash: marker present once, bare line gone, env-gated line present ---
assert_eq "$(grep -c 'gt-h700-redraw' "$work/pugwash")" "1" "redraw marker present once"
# 12-space prefix distinguishes the real code line from the fixture's own
# header comment, which also mentions the anchor text for documentation.
assert_not_contains "$work/pugwash" '            if not self.updated:'
assert_contains "$work/pugwash" 'os.environ.get("GT_FORCE_REDRAW")'
python3 -c "import ast; ast.parse(open('$work/pugwash').read())" \
  || { echo "patched pugwash does not parse"; exit 1; }

# --- launch.sh: gt-h700-redraw-env present once, h700-only export ---
assert_eq "$(grep -c 'gt-h700-redraw-env' "$work/launch.sh")" "1" "redraw-env marker present once"
# shellcheck disable=SC2016
assert_contains "$work/launch.sh" 'export GT_FORCE_REDRAW=1'
esac_line=$(grep -n '^esac$' "$work/launch.sh" | head -1 | cut -d: -f1)
env_line=$(grep -n 'gt-h700-redraw-env' "$work/launch.sh" | head -1 | cut -d: -f1)
[ "$esac_line" -lt "$env_line" ] || { echo "gt-h700-redraw-env is not after the syslib case block"; exit 1; }
sh -n "$work/launch.sh" || { echo "edited launch.sh does not parse"; exit 1; }

# --- launch.sh: F10b gt-h700-love-gles present once, after GT_FORCE_REDRAW ---
# The mali blob's EGL fbdev winsys ABORTS (close_fd EBADF,
# mali_egl_winsys_fbdev.c:85) when LÖVE attempts a desktop-GL context and
# tears it down before falling back to GLES; LOVE_GRAPHICS_USE_OPENGLES=1
# makes LÖVE request GLES directly (validated on the RG SP: RC=0).
assert_eq "$(grep -c 'gt-h700-love-gles' "$work/launch.sh")" "1" "love-gles marker present once"
assert_contains "$work/launch.sh" 'export LOVE_GRAPHICS_USE_OPENGLES=1'
redraw_line=$(grep -n 'export GT_FORCE_REDRAW=1' "$work/launch.sh" | head -1 | cut -d: -f1)
gles_line=$(grep -n 'gt-h700-love-gles' "$work/launch.sh" | head -1 | cut -d: -f1)
[ "$redraw_line" -lt "$gles_line" ] || { echo "gt-h700-love-gles is not after GT_FORCE_REDRAW=1"; exit 1; }

# --- launch.sh: F11 gt-h700-mount-hygiene present once, correctly bracketed ---
# setup_ports_mount's skip-if-mounted check treats ANY existing mount as
# "already set up", but a failed exit-unmount leaves a STALE bind stacked
# (observed 3 deep on device) and harbourmaster then installs/uninstalls
# through a detached layer that evaporates on unmount/reboot (data loss,
# reproduced 2026-08-22). Lazily clear all stale layers before the upstream
# skip check runs.
assert_eq "$(grep -c 'gt-h700-mount-hygiene' "$work/launch.sh")" "1" "mount-hygiene marker present once"
setup_fn_line=$(grep -n 'setup_ports_mount() {' "$work/launch.sh" | head -1 | cut -d: -f1)
hygiene_line=$(grep -n 'gt-h700-mount-hygiene' "$work/launch.sh" | head -1 | cut -d: -f1)
# shellcheck disable=SC2016  # literal $ROM_DIR in the grep pattern is the point
ports_mkdir_line=$(grep -n 'mkdir -p "\$ROM_DIR/.ports"' "$work/launch.sh" | head -1 | cut -d: -f1)
[ "$setup_fn_line" -lt "$hygiene_line" ] || { echo "gt-h700-mount-hygiene is not after setup_ports_mount() {"; exit 1; }
[ "$hygiene_line" -lt "$ports_mkdir_line" ] || { echo "gt-h700-mount-hygiene is not before the upstream mkdir -p \"\$ROM_DIR/.ports\" line"; exit 1; }
# F11 fix (hardware-validated): busybox's mount table prints the canonical
# lowercase path (/mnt/sdcard/...) while $TEMP_DATA_DIR holds the
# /mnt/SDCARD/... alias, so a case-sensitive `grep -q` NEVER matched on
# device (confirmed clearing a real 3-deep stale stack only after switching
# to -i). Assert the case-insensitive flag so a regression back to -q fails.
# shellcheck disable=SC2016  # literal $TEMP_DATA_DIR in the grep pattern is the point
assert_contains "$work/launch.sh" 'grep -qi "on $TEMP_DATA_DIR/ports type"'

# --- launch.sh: F12 gt-h700-cp-preserve present once, cp -f -> cp -fp ---
# Ports with rebuild-if-source-newer heuristics (e.g. Balatro's
# `[ "$source" -nt "$OUTPUT_GAME" ]`, where $source is the launcher's own
# $0) re-patch on EVERY launch, because copy_game_scripts republishes the
# Roms launchers with `cp -f` (fresh mtime) each run. `cp -fp` preserves
# mtimes, clearing the spurious rebuild trigger (validated on-device).
# DELIBERATELY UNCONDITIONAL: no h700 guard, since mtime preservation is
# correct upstream behavior everywhere, not an h700-specific workaround.
assert_eq "$(grep -c 'cp -fp "\$PORTS_DIR"' "$work/launch.sh")" "1" "F12 cp -fp present once"
# NOTE: matches the FULL F12 comment text, not the bare "gt-h700-cp-preserve"
# substring — F13's gt-h700-shebang-guard line below deliberately
# cross-references "(see gt-h700-cp-preserve)", so the bare substring count
# is 2 once both edits are applied. This pattern is specific to F12's own
# line and stays 1.
assert_eq "$(grep -c 'gt-h700-cp-preserve: fresh mtimes' "$work/launch.sh")" "1" "cp-preserve marker present once"
# shellcheck disable=SC2016  # literal $PORTS_DIR in the grep pattern is the point
assert_not_contains "$work/launch.sh" '    cp -f "$PORTS_DIR"/*.sh "$ROM_DIR/" 2>/dev/null || true'

# --- launch.sh: F13 gt-h700-shebang-guard present once, correctly bracketed ---
# The OTHER half of the every-launch-repatch bug (F12 alone didn't stop it,
# hardware-diagnosed): update_file_shebang() runs an UNCONDITIONAL
# `sed -i '1s|.*|#!/usr/bin/env bash|'` on the launched .sh at every port
# launch. sed -i rewrites the file even when the shebang is already
# correct, refreshing $0's mtime every launch and retriggering ports'
# rebuild-if-newer heuristics forever (Balatro re-patched per launch even
# after F12). Skip the rewrite entirely when the shebang is already
# correct. DELIBERATELY UNCONDITIONAL: no h700 guard, same reasoning as F12.
assert_eq "$(grep -c 'gt-h700-shebang-guard' "$work/launch.sh")" "1" "shebang-guard marker present once"
assert_contains "$work/launch.sh" 'head -n 1'
shebang_fn_line=$(grep -n 'update_file_shebang() {' "$work/launch.sh" | head -1 | cut -d: -f1)
guard_line=$(grep -n 'gt-h700-shebang-guard' "$work/launch.sh" | head -1 | cut -d: -f1)
updating_echo_line=$(grep -n 'echo "Updating shebang' "$work/launch.sh" | head -1 | cut -d: -f1)
[ "$shebang_fn_line" -lt "$guard_line" ] || { echo "gt-h700-shebang-guard is not after update_file_shebang() {"; exit 1; }
[ "$guard_line" -lt "$updating_echo_line" ] || { echo "gt-h700-shebang-guard is not before the upstream echo \"Updating shebang line"; exit 1; }

# --- launch.sh: F15 gt-h700-presenter-kill — comm-scan kill helper ---
# Every in-pak killall of the presenter silently no-ops: the pak's busybox
# wrappers shadow PATH and the pinned bullseye busybox's killall never
# matches minui-presenter (observed on-device 2026-08-22: presenters
# survive every kill site, leaking a --disable-auto-sleep process past pak
# exit — the G8 caveat-b re-sleep refusal). Marker count 3 = helper header
# + the two replaced kill sites (cleanup + show_message).
assert_eq "$(grep -c 'gt-h700-presenter-kill' "$work/launch.sh")" "3" "presenter-kill marker: helper + 2 replaced kill sites"
assert_not_contains "$work/launch.sh" 'killall minui-presenter'
assert_contains "$work/launch.sh" 'gt_kill_presenters() {'
helper_line=$(grep -n 'gt_kill_presenters() {' "$work/launch.sh" | head -1 | cut -d: -f1)
showmsg_line=$(grep -n 'show_message() (' "$work/launch.sh" | head -1 | cut -d: -f1)
[ "$helper_line" -lt "$showmsg_line" ] || { echo "gt_kill_presenters is not defined before show_message"; exit 1; }
# helper def + 2 replaced kill sites + 1 quiesce call = 4 name occurrences
assert_eq "$(grep -c 'gt_kill_presenters' "$work/launch.sh")" "4" "gt_kill_presenters referenced at all call sites"

# --- launch.sh: F14 gt-h700-presenter-quiesce — no presenter overlaps pugwash ---
# A presenter whose fb/EGL teardown overlaps pugwash's lifetime desyncs the
# mali damage-tracked present path: the GUI then repaints only
# input-touched rects (the shipped "refresh quirk", G3 caveat-a).
# Hardware-diagnosed 2026-08-22: wedge onset matches the 10s splash's
# natural exit, and a presenter-free control run showed zero glitches. On
# h700 the redundant 10s splash is not spawned and presenters are
# killed+waited before pugwash starts; tg5040 keeps the upstream call.
assert_eq "$(grep -c 'gt-h700-presenter-quiesce' "$work/launch.sh")" "1" "presenter-quiesce marker present once"
assert_contains "$work/launch.sh" 'show_message "Starting PortMaster..." 10 &'
gui_fn_line=$(grep -n 'run_portmaster_gui() {' "$work/launch.sh" | head -1 | cut -d: -f1)
quiesce_line=$(grep -n 'gt-h700-presenter-quiesce' "$work/launch.sh" | head -1 | cut -d: -f1)
layout_line=$(grep -Fn 'set_controller_layout "$gt_gui_layout"' "$work/launch.sh" | head -1 | cut -d: -f1)
[ "$gui_fn_line" -lt "$quiesce_line" ] || { echo "gt-h700-presenter-quiesce is not inside run_portmaster_gui"; exit 1; }
[ "$quiesce_line" -lt "$layout_line" ] || { echo "gt-h700-presenter-quiesce is not before the GUI controller-layout selection"; exit 1; }

# --- launch.sh: F16 gt-h700-presenter-sync — no double-background spawn race ---
# show_message's forever branch self-backgrounds the presenter, so the
# upstream call-site `show_message "Applying changes..." &` is DOUBLE
# backgrounded: cleanup's kill can run before the detached subshell has
# even spawned its presenter, which then outlives the pak (observed
# on-device 2026-08-22 during the F14/F15 gate; the comm-scan's fork cost
# at 480MHz widens the pre-existing upstream race). Dropping the redundant
# outer & orders the spawn before post-processing, making cleanup's kill
# deterministic.
assert_eq "$(grep -c 'gt-h700-presenter-sync' "$work/launch.sh")" "1" "presenter-sync marker present once"
assert_not_contains "$work/launch.sh" 'show_message "Applying changes, please wait..." &'
assert_contains "$work/launch.sh" 'show_message "Applying changes, please wait..."  # gt-h700-presenter-sync'

# --- launch.sh: F17 gt-h700-devfd — POSIX /dev/fd family created at launch ---
# BaseOS/NextUI's devtmpfs lacks /dev/fd (+ stdin/stdout/stderr). Every
# modern port script and patcher logs via bash process substitution
# (exec > >(tee log.txt)), which opens /dev/fd/N — without the symlink the
# exec redirection fails and ALL port/patch logging is silently lost
# (0-byte log.txt everywhere; the deltarune patcher's data loss was masked
# exactly this way; hardware-diagnosed 2026-08-23). Created inside main()
# right after the stay_awake write, [ -e ] guarded (no-op on TrimUI),
# re-created per boot by design (devtmpfs is volatile).
assert_eq "$(grep -c 'gt-h700-devfd' "$work/launch.sh")" "1" "devfd marker present once"
assert_contains "$work/launch.sh" '\[ -e /dev/fd \] || ln -sf /proc/self/fd /dev/fd'
assert_contains "$work/launch.sh" '\[ -e /dev/stdin \] || ln -sf /proc/self/fd/0 /dev/stdin'
assert_contains "$work/launch.sh" '\[ -e /dev/stdout \] || ln -sf /proc/self/fd/1 /dev/stdout'
assert_contains "$work/launch.sh" '\[ -e /dev/stderr \] || ln -sf /proc/self/fd/2 /dev/stderr'
stay_awake_line=$(grep -n '/tmp/stay_awake' "$work/launch.sh" | head -1 | cut -d: -f1)
devfd_line=$(grep -n 'ln -sf /proc/self/fd /dev/fd' "$work/launch.sh" | head -1 | cut -d: -f1)
trap_line=$(grep -n 'trap "cleanup" EXIT INT TERM HUP QUIT' "$work/launch.sh" | head -1 | cut -d: -f1)
[ "$stay_awake_line" -lt "$devfd_line" ] || { echo "gt-h700-devfd is not after the stay_awake write"; exit 1; }
[ "$devfd_line" -lt "$trap_line" ] || { echo "gt-h700-devfd is not before the cleanup trap (i.e. not inside main's prologue)"; exit 1; }

# --- F22 gt-h700-no-self-update — the GUI self-update is fully disarmed ---
# A self-update half-overwrites the pinned repackage (observed on-device
# 2026-08-23: partial zip extraction died on a Text-file-busy binary,
# leaving a 2025.03/2026 chimera control folder). Three coordinated edits:
# (1) launch.sh exports GT_DISABLE_PM_UPDATE=1; (2) pugwash's
# portmaster_check_update early-returns on that env (prompt never shows);
# (3) patch_pylibs additionally no-ops harbourmaster's _install_portmaster
# via the same disable_python_function mechanism upstream ben16w already
# uses for portmaster_install — so even a manually-triggered update path
# cannot write over the pak.
assert_eq "$(grep -c 'gt-h700-no-self-update' "$work/launch.sh")" "2" "no-self-update: env export + pylibs disable in launch.sh"
assert_contains "$work/launch.sh" 'export GT_DISABLE_PM_UPDATE=1'
# shellcheck disable=SC2016
assert_contains "$work/launch.sh" '"$EMU_DIR/pylibs/harbourmaster/harbour.py" _install_portmaster'
ssl_line=$(grep -n 'export SSL_CERT_FILE=' "$work/launch.sh" | head -1 | cut -d: -f1)
disupd_line=$(grep -n 'export GT_DISABLE_PM_UPDATE=1' "$work/launch.sh" | head -1 | cut -d: -f1)
[ "$ssl_line" -lt "$disupd_line" ] || { echo "GT_DISABLE_PM_UPDATE export is not after SSL_CERT_FILE"; exit 1; }
platform_disable_line=$(grep -n 'platform.py" portmaster_install' "$work/launch.sh" | head -1 | cut -d: -f1)
harbour_disable_line=$(grep -n 'harbour.py" _install_portmaster' "$work/launch.sh" | head -1 | cut -d: -f1)
[ "$platform_disable_line" -lt "$harbour_disable_line" ] || { echo "harbour.py disable is not after the upstream platform.py disable (i.e. not inside patch_pylibs)"; exit 1; }
assert_eq "$(grep -c 'gt-h700-no-self-update' "$work/pugwash")" "1" "no-self-update marker present once in pugwash"
assert_contains "$work/pugwash" 'os.environ.get("GT_DISABLE_PM_UPDATE")'
def_line=$(grep -n '^def portmaster_check_update(pm, config, temp_dir):$' "$work/pugwash" | head -1 | cut -d: -f1)
gate_line=$(grep -n 'GT_DISABLE_PM_UPDATE' "$work/pugwash" | head -1 | cut -d: -f1)
assert_eq "$((def_line + 1))" "$gate_line" "update gate is the first line inside portmaster_check_update"

# --- launch.sh: F23 gt-h700-squashfs-tmp-guard — oversized images skipped ---
# /tmp is a small RAM tmpfs on the 1GB h700; unsquashfs of a large runtime
# (the 120MB gmtoolkit.squashfs) fills it mid-extract ("No space left on
# device", observed 2026-08-23) and — with no .processed marker written on
# failure — the doomed extract re-runs on every GUI exit. The guard skips
# images whose 4x-compressed-size estimate exceeds free /tmp, logging
# honestly. Placed inside modify_squashfs_scripts BEFORE the mktemp so no
# tmpdir is leaked on the skip path.
# Marker count 2: the guard's own header comment + the F23 comment block.
assert_contains "$work/launch.sh" 'gt-h700-squashfs-tmp-guard'
# shellcheck disable=SC2016
assert_contains "$work/launch.sh" 'gt_sq_bytes=$(wc -c < "$squashfs_file")'
# the free-space probe must survive the double-quoting gauntlet intact
# shellcheck disable=SC2016
assert_contains "$work/launch.sh" "df -k /tmp | awk 'NR==2 {print \$4}'"
basename_line=$(grep -n 'squashfs_basename=$(basename "$squashfs_file")' "$work/launch.sh" | head -1 | cut -d: -f1)
guard_probe_line=$(grep -n 'gt_sq_bytes=' "$work/launch.sh" | head -1 | cut -d: -f1)
mktemp_line=$(grep -n 'tmpdir=$(mktemp -d) || return 1' "$work/launch.sh" | head -1 | cut -d: -f1)
[ "$basename_line" -lt "$guard_probe_line" ] || { echo "tmp guard is not after the basename assignment"; exit 1; }
[ "$guard_probe_line" -lt "$mktemp_line" ] || { echo "tmp guard is not before the mktemp (would leak tmpdir on skip)"; exit 1; }

# --- idempotency ---
GT_STAGE_EDIT_ONLY="$work" sh "$ROOT/build/build-pak.sh" portmaster
assert_eq "$(grep -c 'gt-h700-redraw' "$work/pugwash")" "1" "redraw marker idempotent"
assert_eq "$(grep -c 'gt-h700-redraw-env' "$work/launch.sh")" "1" "redraw-env marker idempotent"
assert_eq "$(grep -c 'gt-h700-love-gles' "$work/launch.sh")" "1" "love-gles marker idempotent"
assert_eq "$(grep -c 'gt-h700-mount-hygiene' "$work/launch.sh")" "1" "mount-hygiene marker idempotent"
assert_eq "$(grep -c 'cp -fp "\$PORTS_DIR"' "$work/launch.sh")" "1" "F12 cp -fp idempotent"
assert_eq "$(grep -c 'gt-h700-cp-preserve: fresh mtimes' "$work/launch.sh")" "1" "cp-preserve marker idempotent"
assert_eq "$(grep -c 'gt-h700-shebang-guard' "$work/launch.sh")" "1" "shebang-guard marker idempotent"
assert_eq "$(grep -c 'gt-h700-presenter-kill' "$work/launch.sh")" "3" "presenter-kill marker idempotent"
assert_eq "$(grep -c 'gt-h700-presenter-quiesce' "$work/launch.sh")" "1" "presenter-quiesce marker idempotent"
assert_eq "$(grep -c 'gt-h700-presenter-sync' "$work/launch.sh")" "1" "presenter-sync marker idempotent"
assert_eq "$(grep -c 'gt-h700-devfd' "$work/launch.sh")" "1" "devfd marker idempotent"
assert_eq "$(grep -c 'gt-h700-no-self-update' "$work/launch.sh")" "2" "no-self-update launch.sh markers idempotent"
assert_eq "$(grep -c 'gt-h700-no-self-update' "$work/pugwash")" "1" "no-self-update pugwash marker idempotent"
assert_eq "$(grep -c 'gt-h700-squashfs-tmp-guard' "$work/launch.sh")" "1" "squashfs-tmp-guard marker idempotent"
python3 -c "import ast; ast.parse(open('$work/pugwash').read())" \
  || { echo "patched pugwash does not parse after rerun"; exit 1; }
sh -n "$work/launch.sh" || { echo "edited launch.sh does not parse after rerun"; exit 1; }
