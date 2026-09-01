#!/bin/sh
# build-pak.sh — assemble a PortMaster.pak for the Anbernic RG SP (h700) under
# NextUI, from ben16w/minui-portmaster 2.14.0 + pinned upstream deps.
# Usage: build-pak.sh portmaster
#   GT_STAGE_EDIT_ONLY=<dir> runs ONLY the in-place edit functions against <dir>
#   (no network, no docker) — used by tests/.
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$here/.." && pwd)
ASSETS="$ROOT/assets"
DIST="$ROOT/dist"
. "$ROOT/pins.sh"

fetch() { # $1=url $2=sha256 $3=out
  curl -fsSL -o "$3.dl" "$1"
  got=$(shasum -a 256 "$3.dl" | cut -d' ' -f1)
  [ "$got" = "$2" ] || { echo "SHA-256 mismatch for $1: got $got want $2" >&2; rm -f "$3.dl"; exit 1; }
  mv "$3.dl" "$3"
}

edit_portmaster_pak_json() { # $1=pak.json path
  f=$1
  if ! grep -q '"h700"' "$f"; then
    awk '{ print } $0 ~ /"platforms": \[/ { print "    \"h700\"," }' "$f" > "$f.awk.tmp" \
      && mv "$f.awk.tmp" "$f"
  fi
}

edit_portmaster_launch() { # $1=launch.sh path
  f=$1

  # E2: allow h700 (append, upstream list preserved)
  grep -q 'allowed_platforms=".*h700"' "$f" || \
    sed -i.bak 's|allowed_platforms="\([^"]*\)"|allowed_platforms="\1 h700"|' "$f"

  # E4: platform-conditional CPU boost — h700 tops out at 1512000 (measured
  # on-device 2026-08-22: available 480000..1512000); the tg5040 values would
  # be rejected by the kernel. tg5040 keeps upstream values on the else-branch.
  if ! grep -q 'gt-h700-cpufreq' "$f"; then
    awk '$0 == "    echo 1608000 >/sys/devices/system/cpu/cpu0/cpufreq/scaling_min_freq" {
      print "    # gt-h700-cpufreq: h700 max is 1512000 (tg5040 values rejected by kernel)"
      print "    if [ \"$PLATFORM\" = \"h700\" ]; then"
      print "        echo 1200000 >/sys/devices/system/cpu/cpu0/cpufreq/scaling_min_freq"
      print "        echo 1512000 >/sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq"
      print "    else"
      print "        echo 1608000 >/sys/devices/system/cpu/cpu0/cpufreq/scaling_min_freq"
      print "        echo 1800000 >/sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq"
      print "    fi"
      next
    }
    $0 == "    echo 1800000 >/sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq" { next }
    { print }' "$f" > "$f.awk.tmp" && mv "$f.awk.tmp" "$f"
  fi

  # E3: platform-conditional system-lib dir. One guard covers the case-block
  # insert (SYSTEM_LIB_DIR + PM_PYSDL2_DIR + the gt-h700-sdl-core launch-time
  # sync) AND the two export rewrites (the seds are no-ops once rewritten,
  # but keeping them under the guard makes the intent explicit).
  #
  # PM_PYSDL2_DIR is its own var, NOT a reuse of SYSTEM_LIB_DIR: the vendored
  # pysdl2's exlibs/sdl2/dll.py cannot handle a multi-entry PYSDL2_DLL_PATH —
  # it os.pathsep-splits for the exact-name lookup but then unconditionally
  # os.listdir()s the UNSPLIT string (FileNotFoundError, reproduced on-device
  # 2026-08-22). So on h700 PYSDL2_DLL_PATH must be ONE dir, and that dir must
  # be self-sufficient (gate finding F3: NextUI's system lib dir has no
  # SDL2_mixer and a too-old SDL2_ttf 2.0.13 < pysdl2's 2.0.14 minimum) — the
  # pak's own lib/ is that dir on h700; tg5040 keeps the upstream value.
  if ! grep -q 'gt-h700-syslib:' "$f"; then
    awk '$0 == "export LD_LIBRARY_PATH=\"$PAK_DIR/lib:/usr/trimui/lib:$LD_LIBRARY_PATH\"" {
      print "# gt-h700-syslib: the system SDL2 stack is /usr/trimui/lib on TrimUI but"
      print "# NextUI ships its own SDL2 under .system on h700 (BaseOS has none)."
      print "case \"$PLATFORM\" in"
      print "    h700) SYSTEM_LIB_DIR=\"$SDCARD_PATH/.system/h700/lib\"; PM_PYSDL2_DIR=\"$PAK_DIR/lib\" ;;"
      print "    *) SYSTEM_LIB_DIR=\"/usr/trimui/lib\"; PM_PYSDL2_DIR=\"/usr/trimui/lib\" ;;"
      print "esac"
      print "# gt-h700-sdl-core: pysdl2 searches ONE dir; core SDL2 must be the"
      print "# NextUI mali-fbdev build, so sync it from the system dir at launch"
      print "# (also tracks NextUI updates going forward). SDL2_image is NOT"
      print "# copied here: NextUI'\''s build lacks JPEG support, so a JPEG-capable"
      print "# SDL2_image ships from bullseye at staging instead."
      print "if [ \"$PLATFORM\" = \"h700\" ] && [ -f \"$SYSTEM_LIB_DIR/libSDL2-2.0.so.0\" ]; then"
      print "    cp -f \"$SYSTEM_LIB_DIR/libSDL2-2.0.so.0\" \"$PAK_DIR/lib/\""
      print "fi"
    }
    { print }' "$f" > "$f.awk.tmp" && mv "$f.awk.tmp" "$f"
    # shellcheck disable=SC2016  # literal $SYSTEM_LIB_DIR/$PAK_DIR/$PM_PYSDL2_DIR in the sed pattern is the point
    sed -i.bak \
      -e 's|export LD_LIBRARY_PATH="\$PAK_DIR/lib:/usr/trimui/lib:\$LD_LIBRARY_PATH"|export LD_LIBRARY_PATH="$PAK_DIR/lib:$SYSTEM_LIB_DIR:$LD_LIBRARY_PATH"|' \
      -e 's|export PYSDL2_DLL_PATH="/usr/trimui/lib"|export PYSDL2_DLL_PATH="$PM_PYSDL2_DIR"|' \
      "$f"
  fi

  # gt-h700-redraw-env: F6 — pugwash's do_draw only presents once per dirty
  # flag; on the h700 malifbdev EGL swap chain a single present never
  # reliably reaches the panel, so static scenes (message boxes, quit
  # confirm, static lists) show as black (confirmed on-device: with the gate
  # neutralized the whole GUI renders and navigates correctly). This env var
  # is read by edit_portmaster_pugwash's gt-h700-redraw patch to force
  # continuous redraw on h700 only; tg5040 never sets it, so pugwash's
  # runtime behavior there stays byte-identical to upstream. Anchored on the
  # bare "esac" that closes the gt-h700-syslib case block above (E3) — the
  # only NON-indented "esac" in the whole file (the other two belong to
  # indented function-body case blocks further down), so it is a safe,
  # unique, already-guaranteed-post-edit anchor.
  if ! grep -q 'gt-h700-redraw-env' "$f"; then
    awk '{ print } $0 == "esac" {
      print "if [ \"$PLATFORM\" = \"h700\" ]; then"
      print "    export GT_FORCE_REDRAW=1  # gt-h700-redraw-env: see edit_portmaster_pugwash gt-h700-redraw"
      print "fi"
    }' "$f" > "$f.awk.tmp" && mv "$f.awk.tmp" "$f"
  fi

  # gt-h700-love-gles: F10b — the mali blob's EGL fbdev winsys ABORTS
  # (close_fd EBADF, mali_egl_winsys_fbdev.c:85) when LÖVE attempts a
  # desktop-GL context and tears it down before falling back to GLES.
  # LOVE_GRAPHICS_USE_OPENGLES=1 makes LÖVE request GLES directly — validated
  # on the RG SP: the previously-aborting love app runs clean (RC=0). Anchored
  # on the exact line gt-h700-redraw-env just inserted, so this edit MUST run
  # after it (it does, immediately below) — the anchor doesn't exist before.
  if ! grep -q 'gt-h700-love-gles' "$f"; then
    awk '{ print } $0 == "    export GT_FORCE_REDRAW=1  # gt-h700-redraw-env: see edit_portmaster_pugwash gt-h700-redraw" {
      print "    export LOVE_GRAPHICS_USE_OPENGLES=1  # gt-h700-love-gles: mali blob aborts on desktop-GL teardown; LOVE must request GLES directly"
    }' "$f" > "$f.awk.tmp" && mv "$f.awk.tmp" "$f"
  fi

  # E3b: replace the inject function body with the snippet (state-machine splice
  # from "inject_trimui_lib_path() {" to the first bare "}").
  if ! grep -q 'gt-h700-syslib-inject' "$f"; then
    awk -v snippet="$ASSETS/snippet-inject-syslib.sh" '
      $0 == "inject_trimui_lib_path() {" {
        while ((getline line < snippet) > 0) print line
        close(snippet)
        skip = 1
        next
      }
      skip == 1 && $0 == "}" { skip = 0; next }
      skip == 1 { next }
      { print }
    ' "$f" > "$f.awk.tmp" && mv "$f.awk.tmp" "$f"
  fi

  # E6/F51: pin the PortMaster device. PortMaster cannot detect NextUI/BaseOS
  # (devicetree says "sun50iw9", os-release says "Base OS"; harbourmaster's own
  # sun50iw9 fallback would claim rg35xx-h, 640x480 + 2 sticks — wrong for the
  # RG SP). $HOME/.config/.DEVICE is read by harbourmaster hardware.py
  # (~/.config/.DEVICE, expanduser -> the pak-owned $HOME) AND by the payload
  # device_info.txt at port runtime — one write pins both. F51: the pin is
  # keyed on NextUI's $DEVICE SKU token so other h700 devices get their own
  # profile; unknown/absent token = rg34xx-h 720x480 (the RG SP profile, the
  # exact pre-F51 behavior). The RG SP's token is rgsp (device-verified in
  # nextui.elf's environ 2026-09-01). NOTE two token generations, both
  # handled: the current NextUI-h700 build emits FAMILY buckets (its
  # launch.sh maps RG34xx*->rg34xx, RG35xx*->rg35xx, RG40xx*->rg40xx,
  # RGcubexx->cube, unknown->rg40xx; each bucket is geometry-uniform), while
  # the wiki documents exact SKUs (rg34xxsp, rg35xxsp, ...) for newer
  # builds. GT_PANEL_W/H feed the device_info resolution
  # fallback and the F41 Sonic width, and sit on the common path so both the
  # GUI and run_port inherit them. RAM is live-detected on both code paths
  # (hardware.py sysconf override; device_info free), so profile RAM never
  # matters. rgcubexx: harbourmaster has no CubeXX profile — nearest h700 pin,
  # but the panel exports carry the true 720x720. Only the RG SP arm is
  # device-verified; the rest follow the NextUI-h700 wiki token list.
  if ! grep -q 'gt-h700-device-pin' "$f"; then
    awk '{ print } $0 == "mkdir -p \"$XDG_DATA_HOME\"" {
      print ""
      print "# gt-h700-device-pin: pin the harbourmaster profile + panel size from"
      print "# NextUI'\''s $DEVICE SKU token (F51); unknown/absent = RG SP profile."
      print "if [ \"$PLATFORM\" = \"h700\" ]; then"
      print "    mkdir -p \"$HOME/.config\""
      print "    case \"${DEVICE:-}\" in"
      print "        rg34xxsp)             gt_pm_device=rg34xx-sp;   GT_PANEL_W=720; GT_PANEL_H=480 ;;"
      print "        rg35xxh)              gt_pm_device=rg35xx-h;    GT_PANEL_W=640; GT_PANEL_H=480 ;;"
      print "        rg35xxplus|rg35xxpro) gt_pm_device=rg35xx-plus; GT_PANEL_W=640; GT_PANEL_H=480 ;;"
      print "        rg35xxsp)             gt_pm_device=rg35xx-sp;   GT_PANEL_W=640; GT_PANEL_H=480 ;;"
      print "        rg35xx)               gt_pm_device=rg35xx-plus; GT_PANEL_W=640; GT_PANEL_H=480 ;;"
      print "        rg40xxh|rg40xx)       gt_pm_device=rg40xx-h;    GT_PANEL_W=640; GT_PANEL_H=480 ;;"
      print "        rg40xxv)              gt_pm_device=rg40xx-v;    GT_PANEL_W=640; GT_PANEL_H=480 ;;"
      print "        rg28xx)               gt_pm_device=rg28xx;      GT_PANEL_W=640; GT_PANEL_H=480 ;;"
      print "        rgcubexx|cube)        gt_pm_device=rg34xx-h;    GT_PANEL_W=720; GT_PANEL_H=720 ;;"
      print "        *)                    gt_pm_device=rg34xx-h;    GT_PANEL_W=720; GT_PANEL_H=480 ;;  # rgsp/rg34xx*/unknown"
      print "    esac"
      print "    echo \"$gt_pm_device\" >\"$HOME/.config/.DEVICE\""
      print "    export GT_PANEL_W GT_PANEL_H"
      print "fi"
    }' "$f" > "$f.awk.tmp" && mv "$f.awk.tmp" "$f"
  fi

  # E7 hook: opt-in SDL joystick remap for the GUI only. The measured
  # controller-DB entry is the primary fix; the shim preload is the gate
  # measurement tool + fallback, enabled by touching a flag file on-device
  # (no restage cycle needed mid-gate). LD_PRELOAD on the non-SDL busybox
  # children after the loop is harmless — the interposed SDL symbols are
  # never called there.
  if ! grep -q 'gt-h700-remap-hook' "$f"; then
    awk '{ print } $0 == "    rm -f \"$EMU_DIR/.pugwash-reboot\"" {
      print ""
      print "    # gt-h700-remap-hook: touch $USERDATA_PATH/PORTS-portmaster/use-remap to"
      print "    # LD_PRELOAD the SDL joystick index remap shim into the GUI (gate tool)."
      print "    if [ \"$PLATFORM\" = \"h700\" ] && [ -f \"$USERDATA_PATH/PORTS-portmaster/use-remap\" ]; then"
      print "        export LD_PRELOAD=\"$PAK_DIR/lib/gt-input-remap.so${LD_PRELOAD:+:$LD_PRELOAD}\""
      print "    fi"
    }' "$f" > "$f.awk.tmp" && mv "$f.awk.tmp" "$f"
  fi

  # gt-h700-mount-hygiene: F11 — setup_ports_mount's skip-if-mounted check
  # (`mount | grep -q "on $TEMP_DATA_DIR/ports type"`) treats ANY existing
  # mount as "already set up", but a failed exit-unmount (busy fds, killed
  # wrappers) leaves a STALE bind stacked underneath (observed 3 deep on
  # device); harbourmaster then installs/uninstalls through a detached layer
  # whose contents evaporate on unmount/reboot — real data loss, reproduced
  # 2026-08-22. Lazily unmount ALL stale layers before the upstream skip
  # check runs, so it always finds a clean slate and (re)mounts fresh.
  # Anchored on the exact unique line "setup_ports_mount() {" (upstream
  # content, pin-safe); tg5040 is unguarded here so its behavior is
  # byte-identical to upstream.
  # F11 fix (hardware-validated 2026-08-22): busybox's mount table prints the
  # CANONICAL lowercase path (/mnt/sdcard/...) while $TEMP_DATA_DIR holds
  # /mnt/SDCARD/... (a symlinked-case alias), so a case-sensitive `grep -q`
  # NEVER matches on this device — the hygiene loop cleared nothing on first
  # try. This same case mismatch is WHY upstream's own skip-if-mounted check
  # never worked here and stale binds were able to stack up 3 deep in the
  # first place. `grep -qi` fixes both: confirmed on-device clearing a real
  # 3-deep stale stack (count 3 -> 0; `umount -l` confirmed supported).
  if ! grep -q 'gt-h700-mount-hygiene' "$f"; then
    awk '{ print } $0 == "setup_ports_mount() {" {
      print "    # gt-h700-mount-hygiene: failed exit-unmounts leave stale binds stacked and"
      print "    # installs then write into detached layers that evaporate (data loss,"
      print "    # observed 2026-08-22). Lazily clear ALL stale layers before (re)mounting."
      print "    # grep -qi: busybox mount prints the canonical lowercase path"
      print "    # (/mnt/sdcard/...) while $TEMP_DATA_DIR is the /mnt/SDCARD/... alias —"
      print "    # a case-sensitive match never fires on this device, which is also why"
      print "    # the upstream skip-if-mounted check below never worked and let stale"
      print "    # binds stack up in the first place."
      print "    if [ \"$PLATFORM\" = \"h700\" ]; then"
      print "        while mount | grep -qi \"on $TEMP_DATA_DIR/ports type\"; do"
      print "            umount -l \"$TEMP_DATA_DIR/ports\" 2>/dev/null || break"
      print "        done"
      print "    fi"
    }' "$f" > "$f.awk.tmp" && mv "$f.awk.tmp" "$f"
  fi

  # gt-h700-cp-preserve: F12 — ports with rebuild-if-source-newer heuristics
  # (e.g. Balatro's `[ "$source" -nt "$OUTPUT_GAME" ]`, where $source is the
  # launcher's own $0) re-patch on EVERY launch, because copy_game_scripts
  # republishes the Roms launchers with `cp -f` (fresh mtime) each run.
  # Preserving mtimes with `cp -fp` fixes it — validated on-device: with -fp
  # and the mtime reset once, the rebuild trigger clears.
  #
  # DELIBERATELY UNCONDITIONAL — unlike every other edit in this function,
  # there is NO h700 guard here: mtime preservation is the correct upstream
  # behavior everywhere, not an h700-specific workaround. copy_game_scripts
  # is unconditional in upstream (no platform branch), and the same
  # rebuild-every-launch loop affects TrimUI too. This is the shape an
  # upstream PR would take, so tg5040's launch.sh gets the fix as well.
  if ! grep -q 'gt-h700-cp-preserve' "$f"; then
    # shellcheck disable=SC2016  # literal $PORTS_DIR/$ROM_DIR in the sed pattern is the point
    sed -i.bak \
      's|    cp -f "\$PORTS_DIR"/\*\.sh "\$ROM_DIR/" 2>/dev/null \|\| true|    cp -fp "$PORTS_DIR"/*.sh "$ROM_DIR/" 2>/dev/null \|\| true  # gt-h700-cp-preserve: fresh mtimes retrigger ports'"'"' rebuild-if-newer heuristics every launch|' \
      "$f"
  fi

  # gt-h700-shebang-guard: F13 — the OTHER half of the every-launch-repatch
  # bug (F12 alone didn't stop it, hardware-diagnosed): update_file_shebang()
  # runs an UNCONDITIONAL `sed -i '1s|.*|#!/usr/bin/env bash|'` on the
  # launched .sh at every port launch. sed -i rewrites the file even when the
  # shebang is already correct, which refreshes $0's mtime on every launch —
  # retriggering ports' rebuild-if-source-newer heuristics forever (Balatro
  # re-patched per launch even after F12's gt-h700-cp-preserve). Skip the
  # rewrite entirely when the shebang is already correct.
  #
  # DELIBERATELY UNCONDITIONAL — no h700 guard, same reasoning as F12's
  # gt-h700-cp-preserve: a no-op mtime bump is wrong upstream behavior
  # everywhere, not an h700-specific workaround, and the same rebuild loop
  # affects TrimUI too.
  #
  # Anchored on the exact unique line "update_file_shebang() {" via a
  # state-machine awk (same splice precedent as gt-h700-syslib-inject/E3b):
  # emit the function-open line, then the next line (the upstream
  # `file="$1"` assignment) unchanged, then the guard, then resume passthrough.
  if ! grep -q 'gt-h700-shebang-guard' "$f"; then
    awk '$0 == "update_file_shebang() {" {
      print
      gt_after_shebang_open = 1
      next
    }
    gt_after_shebang_open == 1 {
      print
      print "    [ \"$(head -n 1 \"$file\")\" = \"#!/usr/bin/env bash\" ] && return 0  # gt-h700-shebang-guard: unconditional sed -i refreshes mtime every launch and retriggers rebuild-if-newer ports (see gt-h700-cp-preserve)"
      gt_after_shebang_open = 0
      next
    }
    { print }' "$f" > "$f.awk.tmp" && mv "$f.awk.tmp" "$f"
  fi

  # gt-h700-launcher-mtime: F32 — run_port patches the launched .sh in place
  # (update_file_shebang + the /roms/ports/PortMaster path rewrite). That is
  # necessary, but copy_game_scripts reverts the ROM_DIR launcher to its
  # pristine .ports source after every PortMaster-GUI session (cp -fp), so the
  # edits re-fire on the next launch and their sed -i bumps the launcher mtime.
  # LOVE-patch ports test $0 (the launcher) as a rebuild source in needs_build
  # — Balatro (hardware-diagnosed 2026-08-24) and UFO 50 — so a purely cosmetic
  # re-patch forced a full, minutes-long rebuild after any GUI session. The
  # F12b gt-h700-shebang-guard only skipped the shebang rewrite when it was
  # already correct; the reverted launcher is NOT correct, and the path rewrite
  # had no guard at all, so neither stopped the loop. Wrap the three ROM_PATH
  # edits in an mtime snapshot/restore: content still changes, mtime does not,
  # so the pristine source mtime stays authoritative (a genuine port update,
  # which bumps that source mtime and is propagated by cp -fp, still rebuilds).
  # Anchored on run_port's opening echo (snapshot) and the directory= line that
  # begins GAMEDIR resolution (restore) — one awk pass, so a single marker
  # guards both inserts and the restore always runs before the No-GAMEDIR exit.
  if ! grep -q 'gt-h700-launcher-mtime' "$f"; then
    awk '
    $0 == "    echo \"Starting PortMaster with port: $ROM_PATH\"" {
      print
      print "    # gt-h700-launcher-mtime: run_port re-patches the launched .sh in place"
      print "    # (shebang + the \"/roms/ports/PortMaster\" path). copy_game_scripts reverts"
      print "    # that launcher to its pristine .ports source after every PortMaster-GUI"
      print "    # session (cp -fp), so both edits re-fire next launch and bump the mtime"
      print "    # of $0. LOVE-patch ports key rebuild-if-source-newer on $0 (Balatro and"
      print "    # UFO 50 list \"$LAUNCHER\" in needs_build), so a cosmetic re-patch forced a"
      print "    # full, minutes-long rebuild after any GUI session. Snapshot the launcher"
      print "    # mtime and restore it just below the edits so the pristine source mtime"
      print "    # stays authoritative (a genuine port update still rebuilds). Completes the"
      print "    # F12b shebang guard, which the unguarded path rewrite defeated."
      print "    # DELIBERATELY UNCONDITIONAL (no h700 guard): a no-op mtime bump is wrong"
      print "    # upstream everywhere (same reasoning as gt-h700-cp-preserve)."
      print "    gt_launcher_mtime_ref=\"$(mktemp)\""
      print "    touch -r \"$ROM_PATH\" \"$gt_launcher_mtime_ref\""
      next
    }
    $0 == "    directory=\"${TEMP_DATA_DIR#/}\"" {
      print "    touch -r \"$gt_launcher_mtime_ref\" \"$ROM_PATH\"  # gt-h700-launcher-mtime: restore the pre-patch mtime (see snapshot at run_port head)"
      print "    rm -f \"$gt_launcher_mtime_ref\""
      print
      next
    }
    { print }' "$f" > "$f.awk.tmp" && mv "$f.awk.tmp" "$f"
  fi

  # gt-h700-sonic-resolution: F41/F51 — the RSDK Sonic ports set ScreenWidth
  # LOW=214 (0.89:1) for a 3:2 display, which renders a narrow vertical strip
  # with huge side bars on the h700's 720x480. The filling value is
  # 240*panel_w/panel_h (360 on the RG SP); F51 computes it from GT_PANEL_W/H
  # (the launch.sh device profile), defaulting to the RG SP panel. We rewrite
  # the launcher's LOW value before run_port execs it, INSIDE the F32 mtime
  # window (snapshot just above) so the edit doesn't retrigger a rebuild.
  # copy_game_scripts reverts the launcher to pristine 214 each PortMaster
  # session -> this self-heals (and re-fits a card moved between devices); the
  # sed is a no-op once the value is already rewritten.
  if ! grep -q 'gt-h700-sonic-resolution' "$f"; then
    awk '
    $0 == "    touch -r \"$ROM_PATH\" \"$gt_launcher_mtime_ref\"" {
      print
      print ""
      print "    # gt-h700-sonic-resolution: F41/F51 — fill the panel (see docs)"
      print "    case \"${ROM_PATH##*/}\" in"
      print "    \"Sonic 1.sh\"|\"Sonic 2.sh\")"
      print "        if [ \"$PLATFORM\" = \"h700\" ]; then"
      print "            gt_low=$(( 240 * ${GT_PANEL_W:-720} / ${GT_PANEL_H:-480} ))"
      print "            sed -i \"s/LOW=214/LOW=$gt_low/\" \"$ROM_PATH\" 2>/dev/null || true"
      print "        fi"
      print "        ;;"
      print "    esac"
      next
    }
    { print }' "$f" > "$f.awk.tmp" && mv "$f.awk.tmp" "$f"
  fi

  # gt-h700-presenter-kill: F15 — every in-pak kill of the presenter via the
  # upstream killall silently no-ops: create_busybox_wrappers + the pak PATH
  # shadow it with the pinned bullseye busybox, whose killall never matches
  # minui-presenter (observed on-device 2026-08-22: presenters survived every
  # kill site, leaking a --disable-auto-sleep process past pak exit — the G8
  # caveat-b re-sleep refusal, and a live fb/EGL context loitering under
  # NextUI). Replace with a /proc comm-scan + shell-builtin kill, and WAIT
  # for exit: F14 below depends on teardown completing before pugwash starts.
  # DELIBERATELY UNCONDITIONAL (no h700 guard): kills that actually kill are
  # correct upstream behavior everywhere; on TrimUI presenters die promptly,
  # so the wait loop exits on its first iteration.
  if ! grep -q 'gt-h700-presenter-kill' "$f"; then
    awk '$0 == "show_message() (" {
      print "# gt-h700-presenter-kill: the pak busybox wrappers shadow PATH and their"
      print "# killall never matches minui-presenter — kill by /proc comm scan with the"
      print "# shell builtin, then wait for exit (teardown must finish before pugwash"
      print "# starts — see the F14 quiesce edit in run_portmaster_gui)."
      print "gt_kill_presenters() {"
      print "    for gt_p in /proc/[0-9]*; do"
      print "        [ \"$(cat \"$gt_p/comm\" 2>/dev/null)\" = \"minui-presenter\" ] || continue"
      print "        kill \"${gt_p##*/}\" 2>/dev/null || true"
      print "    done"
      print "    gt_i=0"
      print "    while [ \"$gt_i\" -lt 20 ]; do"
      print "        gt_alive=0"
      print "        for gt_p in /proc/[0-9]*; do"
      print "            [ \"$(cat \"$gt_p/comm\" 2>/dev/null)\" = \"minui-presenter\" ] && gt_alive=1"
      print "        done"
      print "        [ \"$gt_alive\" = \"0\" ] && return 0"
      print "        gt_i=$((gt_i+1))"
      print "        sleep 0.1"
      print "    done"
      print "    for gt_p in /proc/[0-9]*; do"
      print "        [ \"$(cat \"$gt_p/comm\" 2>/dev/null)\" = \"minui-presenter\" ] || continue"
      print "        kill -9 \"${gt_p##*/}\" 2>/dev/null || true"
      print "    done"
      print "}"
      print ""
    }
    { print }' "$f" > "$f.awk.tmp" && mv "$f.awk.tmp" "$f"
    awk '$0 == "    killall minui-presenter >/dev/null 2>&1 || true" {
      print "    gt_kill_presenters  # gt-h700-presenter-kill: in-pak killall never matches (busybox wrapper shadow)"
      next
    }
    { print }' "$f" > "$f.awk.tmp" && mv "$f.awk.tmp" "$f"
  fi

  # gt-h700-presenter-quiesce: F14 — a minui-presenter whose fb/EGL teardown
  # overlaps pugwash's lifetime desyncs the mali damage-tracked present path:
  # from that moment the GUI repaints only input-touched rects — the shipped
  # "refresh quirk" (G3 caveat-a). Hardware-diagnosed 2026-08-22: wedge onset
  # matches this 10s splash's natural exit t≈10s (~6s after the menu appears,
  # the counted interval); mid-wedge fb page forensics showed only the
  # debug-counter rect landing; a presenter-free control run showed zero
  # glitches with instant response. On h700: skip the redundant 10s splash
  # (the boot splash's pixels persist on fb0 until pugwash paints over them)
  # and kill+wait ALL presenters so none is alive when pugwash's video
  # initializes. tg5040 keeps the upstream call on the else branch.
  if ! grep -q 'gt-h700-presenter-quiesce' "$f"; then
    awk '$0 == "    show_message \"Starting PortMaster...\" 10 &" {
      print "    # gt-h700-presenter-quiesce: no presenter may be alive once pugwash"
      print "    # starts — a presenter torn down while pugwash runs desyncs the mali"
      print "    # present path (repaint-only-on-input; hardware-diagnosed 2026-08-22)."
      print "    if [ \"$PLATFORM\" = \"h700\" ]; then"
      print "        gt_kill_presenters"
      print "    else"
      print "        show_message \"Starting PortMaster...\" 10 &"
      print "    fi"
      next
    }
    { print }' "$f" > "$f.awk.tmp" && mv "$f.awk.tmp" "$f"
  fi

  # gt-h700-presenter-sync: F16 — show_message's forever branch already
  # self-backgrounds the presenter, so the upstream call-site trailing "&" on
  # the post-GUI "Applying changes" message is a DOUBLE background: the
  # detached subshell may spawn its presenter AFTER cleanup's kill has
  # already scanned (observed on-device 2026-08-22 during the F14/F15 gate —
  # the presenter outlived the pak; gt_kill_presenters' fork-heavy /proc scan
  # at the restored 480MHz floor widens the pre-existing upstream race).
  # Dropping the redundant "&" orders the spawn before post-processing, so
  # cleanup's kill deterministically sees the presenter.
  # DELIBERATELY UNCONDITIONAL: the outer & is redundant for forever-messages
  # on every platform; the added inline latency is one kill scan + one spawn.
  if ! grep -q 'gt-h700-presenter-sync' "$f"; then
    awk '$0 == "    show_message \"Applying changes, please wait...\" &" {
      print "    show_message \"Applying changes, please wait...\"  # gt-h700-presenter-sync: forever-messages self-background; outer & races cleanup"
      next
    }
    { print }' "$f" > "$f.awk.tmp" && mv "$f.awk.tmp" "$f"
  fi

  # gt-h700-devfd: F17 — BaseOS/NextUI's devtmpfs lacks the standard POSIX
  # /dev/fd family (/dev/fd -> /proc/self/fd plus stdin/stdout/stderr).
  # Every modern port script and every port patcher logs via bash process
  # substitution (`exec > >(tee log.txt)`), which opens /dev/fd/N — without
  # the symlink the exec redirection fails, every log stays 0 bytes, and
  # downstream failures become invisible (the deltarune patcher's silent
  # data loss was masked exactly this way; hardware-diagnosed 2026-08-23).
  # [ -e ] guards make this a no-op on TrimUI, where the links exist.
  # devtmpfs is per-boot, so this runs at every pak launch by design.
  if ! grep -q 'gt-h700-devfd' "$f"; then
    awk '{ print } $0 == "    echo \"1\" >/tmp/stay_awake" {
      print "    # gt-h700-devfd: BaseOS lacks the POSIX /dev/fd family; bash process"
      print "    # substitution (exec > >(tee log.txt) — every modern port script and"
      print "    # patcher) opens /dev/fd/N and silently loses ALL logging without it."
      print "    # devtmpfs is per-boot, so (re)create at every launch; no-op on TrimUI."
      print "    [ -e /dev/fd ] || ln -sf /proc/self/fd /dev/fd"
      print "    [ -e /dev/stdin ] || ln -sf /proc/self/fd/0 /dev/stdin"
      print "    [ -e /dev/stdout ] || ln -sf /proc/self/fd/1 /dev/stdout"
      print "    [ -e /dev/stderr ] || ln -sf /proc/self/fd/2 /dev/stderr"
    }' "$f" > "$f.awk.tmp" && mv "$f.awk.tmp" "$f"
  fi

  # gt-h700-no-self-update: F22 — the GUI's self-update half-overwrites the
  # pinned repackage: observed on-device 2026-08-23, the update's zipfile
  # extraction died on a Text-file-busy binary after already replacing ~20
  # control-folder files (funcs.txt, utils/, device_info.txt, a new
  # pylibs.zip primed to clobber the patched pylibs on next launch), leaving
  # a 2025.03/2026 chimera. Two launch.sh sides (the pugwash prompt gate is
  # in edit_portmaster_pugwash): (1) export the env the pugwash patch reads;
  # (2) neutralize harbourmaster's _install_portmaster with the same
  # disable_python_function mechanism patch_pylibs already uses for
  # portmaster_install, so even a manually-triggered update is a no-op.
  if ! grep -q 'gt-h700-no-self-update' "$f"; then
    awk '{ print } $0 == "export SSL_CERT_FILE=\"$PAK_DIR/files/ca-certificates.crt\"" {
      print "export GT_DISABLE_PM_UPDATE=1  # gt-h700-no-self-update: a self-update half-overwrites the pinned repackage; see edit_portmaster_pugwash"
    }' "$f" > "$f.awk.tmp" && mv "$f.awk.tmp" "$f"
    awk '{ print } $0 == "        \"$EMU_DIR/pylibs/harbourmaster/platform.py\" portmaster_install" {
      print "    # gt-h700-no-self-update: neutralize the updater itself as well — even a"
      print "    # user-accepted update must not overwrite the pinned repackage (a partial"
      print "    # overwrite chimera-ed the control folder on-device 2026-08-23)."
      print "    python3 \"$PAK_DIR/src/disable_python_function.py\" \\"
      print "        \"$EMU_DIR/pylibs/harbourmaster/harbour.py\" _install_portmaster"
    }' "$f" > "$f.awk.tmp" && mv "$f.awk.tmp" "$f"
  fi

  # gt-h700-port-fixes: F27 — overlay pak-shipped replacement files onto
  # known-broken port installs before launching them. First case: the
  # tunics_pm port bundles a libmodplug.so.1 that dies on an illegal
  # instruction (udf #0) on this device the moment a map transition changes
  # the tracker music — gdb-attach caught the SIGSEGV inside the port's own
  # copy, and bullseye's build fixed it live on hardware (2026-08-23).
  # Files live under files/port-fixes/<port-dir-name>/ mirroring the port's
  # layout. Re-applied at every launch so a port reinstall self-heals;
  # cmp-guarded so unchanged files are never rewritten (a fresh mtime would
  # retrigger rebuild-if-newer ports — the F12 lesson). Anchored on the
  # nintendo_file line (upstream content, pin-safe), i.e. inside run_port
  # after GAMEDIR is resolved and before the port executes.
  if ! grep -q 'gt-h700-port-fixes' "$f"; then
    awk '$0 == "    nintendo_file=$(find \"$USERDATA_PATH/PORTS-portmaster\" -maxdepth 1 -iname \"nintendo*\" -type f)" {
      print "    # gt-h700-port-fixes: overlay pak-shipped replacement files onto known-"
      print "    # broken port installs (e.g. tunics_pm ships a libmodplug.so.1 that dies"
      print "    # on an illegal instruction here). cmp-guarded: unchanged files are never"
      print "    # rewritten (fresh mtimes retrigger rebuild-if-newer ports)."
      print "    gt_fix_dir=\"$PAK_DIR/files/port-fixes/${GAMEDIR##*/}\""
      print "    if [ \"$PLATFORM\" = \"h700\" ] && [ -d \"$gt_fix_dir\" ]; then"
      print "        find \"$gt_fix_dir\" -type f | while IFS= read -r gt_fix_src; do"
      print "            gt_rel=\"${gt_fix_src#\"$gt_fix_dir\"/}\""
      print "            if ! cmp -s \"$gt_fix_src\" \"$GAMEDIR/$gt_rel\" 2>/dev/null; then"
      print "                echo \"Port-fix overlay: replacing $gt_rel in ${GAMEDIR##*/}\""
      print "                case \"$gt_rel\" in */*) mkdir -p \"$GAMEDIR/${gt_rel%/*}\" ;; esac"
      print "                cp -fp \"$gt_fix_src\" \"$GAMEDIR/$gt_rel\""
      print "            fi"
      print "        done"
      print "    fi"
      print ""
      print $0
      next
    }
    { print }' "$f" > "$f.awk.tmp" && mv "$f.awk.tmp" "$f"
  fi

  # gt-h700-nxengine-settings: F39 — install the h700-correct nxengine-evo
  # (Cave Story Evo) controls + resolution ONCE per port install. The port
  # reads the raw SDL joystick and binds directions to buttons 8-11 (h700's
  # d-pad is hat0, so they were dead) and faces to 0-7 (h700 faces are raw
  # 3-13, so they were scrambled), and defaults resolution to 720x720 (overran
  # the 720x480 fb). Marker-gated — NOT the always-overwrite F27 overlay — so a
  # player's in-game rebinds / resolution changes persist across launches; a
  # port reinstall recreates conf/ without the marker and re-heals. Anchored on
  # the nintendo_file line (inside run_port, after GAMEDIR resolves, before the
  # port executes and would pick its own width-variant settings.dat).
  if ! grep -q 'gt-h700-nxengine-settings' "$f"; then
    awk '$0 == "    nintendo_file=$(find \"$USERDATA_PATH/PORTS-portmaster\" -maxdepth 1 -iname \"nintendo*\" -type f)" {
      print "    # gt-h700-nxengine-settings: install h700-correct nxengine-evo controls +"
      print "    # resolution once (d-pad->hat0, faces->raw indices, res 640x480). Marker-"
      print "    # gated so in-game rebinds persist; port reinstall wipes conf/ -> re-heals."
      print "    gt_nxe_src=\"$PAK_DIR/files/nxengine-h700/settings.dat\""
      print "    if [ \"$PLATFORM\" = \"h700\" ] && [ \"${GAMEDIR##*/}\" = \"nxengine-evo\" ] \\"
      print "        && [ -f \"$gt_nxe_src\" ] && [ ! -f \"$GAMEDIR/conf/nxengine/.gt-h700-settings\" ]; then"
      print "        echo \"Installing h700 controls/resolution for nxengine-evo (Cave Story Evo)\""
      print "        mkdir -p \"$GAMEDIR/conf/nxengine\""
      print "        cp -f \"$gt_nxe_src\" \"$GAMEDIR/conf/nxengine/settings.dat\""
      print "        touch \"$GAMEDIR/conf/nxengine/.gt-h700-settings\""
      print "    fi"
      print ""
      print $0
      next
    }
    { print }' "$f" > "$f.awk.tmp" && mv "$f.awk.tmp" "$f"
  fi

  # gt-h700-ac-launcher: F45 — Animal Crossing is a 32-bit armhf port (NextUI is
  # aarch64-only). The pak ships a complete 32-bit runtime + a 32-bit build of
  # the input shim + a launcher that wires them up (files/ac-gc-h700/ and
  # lib/gt-input-remap.armhf.so, staged in do_portmaster). copy_game_scripts
  # reverts the port's launcher to its pristine porter source every
  # PortMaster-GUI session (which on NextUI has the wrong controlfolder fallback
  # and none of the armhf runtime wiring), so re-install our launcher over the
  # live ROM_PATH each launch. cmp-guarded so an unchanged launcher is never
  # rewritten (a fresh mtime would retrigger rebuild-if-newer ports — the F12/F27
  # rule; AC itself is a native binary and doesn't rebuild, but the guard keeps
  # the mtime honest). Detected by the AnimalCrossing binary in the resolved
  # GAMEDIR, so a user-renamed .sh still heals and no other port is ever touched.
  # Anchored on the nintendo_file line (inside run_port, after GAMEDIR resolves,
  # before the port executes) like the F27/F39 overlays.
  if ! grep -q 'gt-h700-ac-launcher' "$f"; then
    awk '$0 == "    nintendo_file=$(find \"$USERDATA_PATH/PORTS-portmaster\" -maxdepth 1 -iname \"nintendo*\" -type f)" {
      print "    # gt-h700-ac-launcher: F45 — re-install the pak-hosted armhf launcher for"
      print "    # Animal Crossing (32-bit port on aarch64 NextUI); copy_game_scripts reverts"
      print "    # it to the pristine porter source each GUI session. cmp-guarded; detected by"
      print "    # the AnimalCrossing binary in GAMEDIR so no other port is touched."
      print "    gt_ac_src=\"$PAK_DIR/files/ac-gc-h700/Animal Crossing.sh\""
      print "    if [ \"$PLATFORM\" = \"h700\" ] && [ \"${GAMEDIR##*/}\" = \"ac-gc\" ] \\"
      print "        && [ -f \"$GAMEDIR/AnimalCrossing\" ] && [ -f \"$gt_ac_src\" ] \\"
      print "        && ! cmp -s \"$gt_ac_src\" \"$ROM_PATH\" 2>/dev/null; then"
      print "        echo \"Installing h700 armhf launcher for Animal Crossing\""
      print "        cp -f \"$gt_ac_src\" \"$ROM_PATH\""
      print "    fi"
      print ""
      print $0
      next
    }
    { print }' "$f" > "$f.awk.tmp" && mv "$f.awk.tmp" "$f"
  fi

  # gt-h700-solarus-nojit: F28 — the solarus runtime bundles LuaJIT
  # 2.1.0-beta3, whose aarch64 JIT miscompiles under quest load on this
  # device: gdb-attach caught SIGSEGV jumps into unmapped trace memory from
  # libluajit during Tunics! map transitions (2026-08-23; a software-
  # rendering "fix" earlier the same day was a red herring — different
  # timing merely dodged the bad trace). Inject a -s pre-script that turns
  # the JIT off (interpreter mode; solarus's heavy lifting is C++ —
  # play-verified at normal speed). Applied to any port script that defines
  # a solarus runtime; guarded per file, and the invocation line is matched
  # by its leading "$runtime" call shape.
  if ! grep -q 'gt-h700-solarus-nojit' "$f"; then
    awk '$0 == "    nintendo_file=$(find \"$USERDATA_PATH/PORTS-portmaster\" -maxdepth 1 -iname \"nintendo*\" -type f)" {
      print "    # gt-h700-solarus-nojit: LuaJIT 2.1.0-beta3 aarch64 JIT miscompiles under"
      print "    # quest load (gdb-verified); run solarus quests with the JIT off. F36:"
      print "    # solarus -s= runs its VALUE as inline Lua, so the F28 path form"
      print "    # (-s=<path>) errored (\"unexpected symbol near '\''/'\''\") and the JIT stayed"
      print "    # on; pass -s=\"dofile('\''<path>'\'')\" and self-heal launchers still on the"
      print "    # path form. Solarus ports define runtime=\"solarus...\"."
      print "    if [ \"$PLATFORM\" = \"h700\" ] && grep -q \"^runtime=\\\"solarus\" \"$ROM_PATH\"; then"
      print "        gt_nojit=\"$PAK_DIR/files/solarus-nojit.lua\""
      print "        if grep -qF -- \"-s=$gt_nojit \" \"$ROM_PATH\"; then"
      print "            echo \"Healing solarus no-JIT pre-script (F36) in $ROM_NAME\""
      print "            sed -i \"s|-s=$gt_nojit |-s=\\\"dofile('\''$gt_nojit'\'')\\\" |\" \"$ROM_PATH\""
      print "        elif ! grep -q \"solarus-nojit\" \"$ROM_PATH\"; then"
      print "            echo \"Injecting solarus no-JIT pre-script into $ROM_NAME\""
      print "            sed -i \"s|^\\\"\\$runtime\\\" |\\\"\\$runtime\\\" -s=\\\"dofile('\''$gt_nojit'\'')\\\" |\" \"$ROM_PATH\""
      print "        fi"
      print "    fi"
      print ""
      print $0
      next
    }
    { print }' "$f" > "$f.awk.tmp" && mv "$f.awk.tmp" "$f"
  fi

  # gt-h700-port-remap / gt-h700-hud: F25/F26/F34 — preload the SDL joystick
  # index-remap + in-game HUD shim (LD_PRELOAD) into EVERY h700 port. The
  # README documented the shim as a port-level fix since v0.1.0, but only
  # run_portmaster_gui ever honored the flag — run_port had no preload path
  # at all (doc/code mismatch found while fixing Tunics!, whose Solarus
  # engine reads raw joystick events: it launched fine and ignored every
  # button, hardware-diagnosed 2026-08-23). What the shim actually DOES stays
  # gated: the v1 index remap + gptk keyboard synthesis (h700 button indices
  # sit +3 off the layout ports expect; measured table in
  # assets/gt-input-remap.c) are opt-in via GT_INPUT_REMAP=1, set only for
  # launcher filenames listed in files/gt-remap-ports.txt (pak-shipped
  # defaults) or the user's $USERDATA_PATH/PORTS-portmaster/use-remap-ports
  # (one name per line, no rebuild needed) — GameController-tier ports get
  # correct input natively and must stay untouched. The in-game HUD (F34) is
  # the opposite shape: GT_HUD=1 by default for every port, opt-OUT via
  # files/gt-hud-blocklist.txt (pak-shipped) or the user's
  # use-hud-blocklist, for ports where the overlay is known to misbehave.
  if ! grep -q 'gt-h700-port-remap' "$f"; then
    awk '$0 == "    \"$PAK_DIR/bin/bash\" \"$ROM_PATH\"" {
      print "    # gt-h700-port-remap / gt-h700-hud (F25/F26/F34)"
      print "    if [ \"$PLATFORM\" = \"h700\" ]; then"
      print "        export LD_PRELOAD=\"$PAK_DIR/lib/gt-input-remap.so${LD_PRELOAD:+:$LD_PRELOAD}\""
      print "        # input remap stays opt-in (allowlist): TrimUI index remap + gptk synthesis"
      print "        if grep -Fxq \"$ROM_NAME\" \"$PAK_DIR/files/gt-remap-ports.txt\" 2>/dev/null \\"
      print "            || grep -Fxq \"$ROM_NAME\" \"$USERDATA_PATH/PORTS-portmaster/use-remap-ports\" 2>/dev/null; then"
      print "            echo \"Enabling input remap for $ROM_NAME\""
      print "            export GT_INPUT_REMAP=1"
      print "            for gt_gptk in \"$GAMEDIR\"/*.gptk; do"
      print "                [ -f \"$gt_gptk\" ] && export GT_REMAP_GPTK=\"$gt_gptk\""
      print "                break"
      print "            done"
      print "        fi"
      print "        # HUD is opt-out (blocklist): on for every port unless listed"
      print "        if grep -Fxq \"$ROM_NAME\" \"$PAK_DIR/files/gt-hud-blocklist.txt\" 2>/dev/null \\"
      print "            || grep -Fxq \"$ROM_NAME\" \"$USERDATA_PATH/PORTS-portmaster/use-hud-blocklist\" 2>/dev/null; then"
      print "            echo \"HUD disabled (blocklisted) for $ROM_NAME\""
      print "        else"
      print "            export GT_HUD=1"
      print "        fi"
      print "    fi"
      print ""
      print $0
      next
    }
    { print }' "$f" > "$f.awk.tmp" && mv "$f.awk.tmp" "$f"
  fi

  # gt-h700-fmod-audio: F30 — preload the FMOD-audio shim for gmloadernext FMOD
  # ports. The h700 audio codec is single-client (no SysV IPC => no ALSA dmix),
  # so a GameMaker port that ships FMOD opens it twice — the runner's own audio
  # device first, then FMOD_SDL — and the runner wins the race, leaving FMOD
  # (and thus the whole game's sound, which routes through FMOD) silent. The
  # shim suppresses the runner's non-FMOD_SDL open so FMOD_SDL gets the device.
  # The same ports have sound on an RG DS because ROCKNIX runs shareable
  # PulseAudio. Diagnosed + hardware-verified on the RG SP (Pizza Tower,
  # 2026-08-24). Auto-gated, no per-port list: only ports carrying
  # libs/libfmod*.so* get it, so non-FMOD ports are untouched. Placed in the
  # same run_port window as gt-h700-port-remap; order between the two is
  # irrelevant (disjoint interposed symbols, both prepend LD_PRELOAD).
  if ! grep -q 'gt-h700-fmod-audio' "$f"; then
    awk '$0 == "    \"$PAK_DIR/bin/bash\" \"$ROM_PATH\"" {
      print "    # gt-h700-fmod-audio: FMOD ports open the single-client h700 codec twice"
      print "    # (the runner audio first, then FMOD_SDL) and the runner wins, so FMOD"
      print "    # is silent. Preload the shim that suppresses the runner non-FMOD_SDL"
      print "    # open so FMOD_SDL gets the codec. Auto-gated on the FMOD libs a port"
      print "    # ships, so non-FMOD ports are untouched."
      print "    if [ \"$PLATFORM\" = \"h700\" ] && ls \"$GAMEDIR\"/libs/libfmod*.so* >/dev/null 2>&1; then"
      print "        echo \"Preloading gt-fmod-audio.so for $ROM_NAME (FMOD port)\""
      print "        export LD_PRELOAD=\"$PAK_DIR/lib/gt-fmod-audio.so${LD_PRELOAD:+:$LD_PRELOAD}\""
      print "    fi"
      print ""
      print $0
      next
    }
    { print }' "$f" > "$f.awk.tmp" && mv "$f.awk.tmp" "$f"
  fi

  # gt-h700-gles3-profile: F37 — gothic-engine (Yacht Club) machismo ports —
  # e.g. Mina the Hollower by bmdhacks, a Darling/machismo Mac-arm64 port —
  # emit GLSL ES 3.10 shaders and take a GLES fallback when Vulkan is absent,
  # which on h700 is ALWAYS (Mali-G31 Bifrost exports no vk*). On this pak that
  # GLES context binds GL4ES (libGL.so.1, GL 2.1/GLSL 1.20), whose ShaderConv
  # down-converts "#version 310 es" to "#version 100" while leaving layout(...)
  # in — invalid ES1.00, so the first shader fails to compile and the render
  # thread SIGABRTs before anything draws: the port never starts. The device's
  # Mali r20p0 blob natively speaks OpenGL ES 3.2 and compiles the shaders
  # as-is; it just never got reached. Fix, two parts together: (1) shadow the
  # pak's GL4ES libGL/libEGL with the device's NATIVE Mali ES3 wrappers
  # (/usr/lib/libGLESv2.so.2 -> libGL.so.1, /usr/lib/libEGL.so.1 -> libEGL.so.1)
  # inside the port's own libs dir, which its launcher puts first in
  # LD_LIBRARY_PATH, so SDL dlopens native Mali GL/EGL by name and GL4ES never
  # loads (must shadow libEGL too: the pak's libEGL is GL4ES's own and needs
  # symbol `hardext` from GL4ES's libGL, so a libGL-only shadow breaks
  # libgothic_patches' load); (2) preload gt-gles3-profile.so, which forces an
  # ES3 SDL GL profile (without it SDL binds EGL_OPENGL_API on native Mali EGL
  # and the context creation fails). LD_PRELOAD-alone can't do part 1: the GL
  # library is committed at the game's SDL_CreateWindow via machismo's Mach-O
  # resolver + gothic's in-memory SDL trampoline, both bypassing LD_PRELOAD.
  # Auto-gated on the gothic signature libs/libgothic_patches.so (like the FMOD
  # auto-gate on libs/libfmod*.so*): the failure is engine-level and
  # h700-invariant, so the fix is gothic-generic by construction — every gothic
  # port on h700 needs exactly this, none can use GL4ES. cmp-guarded + cp -fp
  # (F12/F27: a fresh mtime would retrigger rebuild-if-newer ports); source-
  # existence guarded (a future BaseOS without the wrapper just skips, no broken
  # file). Self-contained to the port dir and self-heals on reinstall. Same
  # run_port window as gt-h700-port-remap / gt-h700-fmod-audio; order among the
  # three is irrelevant (disjoint interposed symbols, all prepend LD_PRELOAD).
  # Device-verified on Mina the Hollower 2026-08-27 (boots + plays on native
  # ES3, with sound); Mina is the only gothic port installed/tested so far.
  # NOTE: on a native-ES3 context the F34 HUD first drew a solid black quad
  # (the engine binds a sampler object to texture unit 0, which overrides the
  # HUD's glTexParameteri); that is fixed at the source in F38 (gt-input-remap.c
  # unbinds it around the HUD draw), so gothic ports are NOT HUD-blocklisted.
  if ! grep -q 'gt-h700-gles3-profile' "$f"; then
    awk '$0 == "    \"$PAK_DIR/bin/bash\" \"$ROM_PATH\"" {
      print "    # gt-h700-gles3-profile (F37): gothic-engine machismo ports need a NATIVE"
      print "    # Mali ES3 GL context; on GL4ES their ES 3.10 shaders fail to compile and"
      print "    # the port never starts. Shadow the pak GL4ES libGL/libEGL with the device"
      print "    # native Mali wrappers (the port libs dir is first in LD_LIBRARY_PATH) and"
      print "    # preload gt-gles3-profile.so to force an ES3 SDL profile. Auto-gated on the"
      print "    # gothic signature; cmp-guarded + cp -fp (a fresh mtime retriggers rebuilds)."
      print "    if [ \"$PLATFORM\" = \"h700\" ] && [ -f \"$GAMEDIR/libs/libgothic_patches.so\" ]; then"
      print "        echo \"Applying native-GLES3 GL fix for $ROM_NAME (gothic-engine machismo port)\""
      print "        for gt_gl in \"/usr/lib/libGLESv2.so.2:libGL.so.1\" \"/usr/lib/libEGL.so.1:libEGL.so.1\"; do"
      print "            gt_gl_src=\"${gt_gl%%:*}\"; gt_gl_dst=\"$GAMEDIR/libs/${gt_gl##*:}\""
      print "            if [ -f \"$gt_gl_src\" ] && ! cmp -s \"$gt_gl_src\" \"$gt_gl_dst\" 2>/dev/null; then"
      print "                echo \"GL fix: shadowing ${gt_gl_dst##*/} with native $gt_gl_src\""
      print "                cp -fp \"$gt_gl_src\" \"$gt_gl_dst\""
      print "            fi"
      print "        done"
      print "        export LD_PRELOAD=\"$PAK_DIR/lib/gt-gles3-profile.so${LD_PRELOAD:+:$LD_PRELOAD}\""
      print "    fi"
      print ""
      print $0
      next
    }
    { print }' "$f" > "$f.awk.tmp" && mv "$f.awk.tmp" "$f"
  fi

  # gt-h700-sonic-audio: F42 — RSDKv4's InitAudioPlayback() calls
  # SDL_OpenAudioDevice without ever calling SDL_InitSubSystem(SDL_INIT_AUDIO)
  # first. On h700 the audio subsystem is not up at that point, so the open
  # fails ("Audio subsystem is not initialized") and the port runs silent.
  # Preload a shim that interposes SDL_OpenAudioDevice and force-inits
  # SDL_INIT_AUDIO first if it isn't already up. Auto-gated on the sonic2013
  # binary (Sonic 1) so non-Sonic ports are untouched; sonicforever /
  # sonic2absolute (F40) are not covered by this gate. Same run_port window
  # as the other preload hooks; order is irrelevant (disjoint interposed
  # symbols, all prepend LD_PRELOAD).
  if ! grep -q 'gt-h700-sonic-audio' "$f"; then
    awk '$0 == "    \"$PAK_DIR/bin/bash\" \"$ROM_PATH\"" {
      print "    # gt-h700-sonic-audio (F42): RSDKv4 opens the SDL audio device without"
      print "    # ever initializing SDL_INIT_AUDIO first, so on h700 the open fails and"
      print "    # the port runs silent. Preload the shim that force-inits the audio"
      print "    # subsystem before the open. Auto-gated on the sonic2013 binary."
      print "    if [ \"$PLATFORM\" = \"h700\" ] && [ -f \"$GAMEDIR/sonic2013\" ]; then"
      print "        export LD_PRELOAD=\"$PAK_DIR/lib/gt-sdl-audio-init.so${LD_PRELOAD:+:$LD_PRELOAD}\""
      print "    fi"
      print ""
      print $0
      next
    }
    { print }' "$f" > "$f.awk.tmp" && mv "$f.awk.tmp" "$f"
  fi

  # gt-h700-sleepmon: F47 — sleep for ports. NextUI sleep is a foreground-app
  # feature (nextui/minarch watch event0 + hallkey and run bin/suspend; keymon
  # does volume/brightness only), so during a port NOBODY watches the power
  # key or lid. gt-sleepmon (pak bin/) fills that role: KEY_POWER release or
  # lid-close on the power-key node (F51: found by EVIOCGBIT capability scan;
  # event0 on the RG SP) -> SIGSTOP the port tree -> stock suspend script ->
  # SIGCONT -> 2s event swallow (the waking press would otherwise instantly
  # re-suspend). The ALSA env routes "default" through the pak's
  # suspend-proxy plugin so audio survives (the BSP wedges any PCM open
  # across a suspend; only close+reopen recovers). Opt-out via
  # files/gt-sleep-blocklist.txt or the user's use-sleep-blocklist.
  if ! grep -q 'gt-h700-sleepmon' "$f"; then
    awk '$0 == "    \"$PAK_DIR/bin/bash\" \"$ROM_PATH\"" {
      print "    # gt-h700-sleepmon / gt-h700-alsa-suspend (F47)"
      print "    if [ \"$PLATFORM\" = \"h700\" ]; then"
      print "        if grep -Fxq \"$ROM_NAME\" \"$PAK_DIR/files/gt-sleep-blocklist.txt\" 2>/dev/null \\"
      print "            || grep -Fxq \"$ROM_NAME\" \"$USERDATA_PATH/PORTS-portmaster/use-sleep-blocklist\" 2>/dev/null; then"
      print "            echo \"Sleep support disabled (blocklisted) for $ROM_NAME\""
      print "        else"
      print "            sed \"s|@PAK_DIR@|$PAK_DIR|g\" \"$PAK_DIR/files/gt-asound.conf\" > /tmp/gt-asound.conf"
      print "            if [ -s /tmp/gt-asound.conf ]; then"
      print "                export ALSA_CONFIG_PATH=/tmp/gt-asound.conf"
      print "            else"
      print "                echo \"gt-asound.conf template missing/empty; sleep audio proxy disabled for $ROM_NAME\""
      print "            fi"
      print "            \"$PAK_DIR/bin/gt-sleepmon\" $$ >/tmp/gt-sleepmon.log 2>&1 &"
      print "            gt_sleepmon_pid=$!"
      print "        fi"
      print "    fi"
      print ""
      print $0
      next
    }
    { print }' "$f" > "$f.awk.tmp" && mv "$f.awk.tmp" "$f"
  fi

  # gt-h700-source-heal: F29 — harbourmaster recreates its default
  # *.source.json files ONLY on first-run or a config-version migration
  # (harbour.py: the first-run branch writes HM_SOURCE_DEFAULTS;
  # update_config() is the only other writer). A config dir that kept
  # config.json (first-run:false, version:2) but lost the source files is
  # stuck forever: zero sources mean every port resolves as "unknown", all
  # lists render empty, and Featured shows a bogus internet-required
  # message — featured/porters/ports_info fetch through separate paths,
  # masking the real cause. Observed on-device 2026-08-23: a half-applied
  # upstream self-update (pre-F22) had deleted the source files, and a
  # recovery that restored config.json without them wedged the GUI in
  # exactly this state. Restore the pinned defaults (last_checked:null,
  # data:{} — harbourmaster refetches the port database on next load).
  # Deliberately conservative: ANY surviving *.source.json skips the heal
  # (never fight a user-modified source set), and a missing config.json
  # skips too (that's a fresh install; harbourmaster's own first-run path
  # writes the defaults itself).
  if ! grep -q 'gt-h700-source-heal' "$f"; then
    awk '$0 == "    echo \"Starting PortMaster GUI\"" {
      print "    # gt-h700-source-heal: harbourmaster only recreates its default sources on"
      print "    # first-run or a config-version migration — a config dir with config.json"
      print "    # but no *.source.json is stuck with empty ports lists forever. Restore"
      print "    # the pinned defaults; any surviving source file skips the heal."
      print "    if [ -f \"$EMU_DIR/config/config.json\" ] \\"
      print "        && ! ls \"$EMU_DIR/config/\"*.source.json >/dev/null 2>&1; then"
      print "        echo \"Restoring default harbourmaster port sources\""
      print "        cp -f \"$PAK_DIR/files/gt-source-defaults/\"*.source.json \"$EMU_DIR/config/\""
      print "    fi"
      print ""
      print $0
      next
    }
    { print }' "$f" > "$f.awk.tmp" && mv "$f.awk.tmp" "$f"
  fi

  # gt-h700-squashfs-tmp-guard: F23 — /tmp is a small RAM tmpfs on the 1GB
  # h700; process_squashfs_files' unsquashfs of a large runtime image fills
  # it mid-extract ("No space left on device" on the 120MB
  # gmtoolkit.squashfs, observed on-device 2026-08-23), and since a failed
  # image never gets its .processed marker, the doomed extract re-runs on
  # EVERY GUI exit. Skip images whose conservative size estimate (4x the
  # compressed file) exceeds free /tmp space, with an honest log line.
  # Extracting to the SD instead is NOT an option: the card is vfat, which
  # cannot hold the symlinks/exec bits a rebuilt squashfs must preserve.
  # Ports needing tools from an oversized runtime are handled case-by-case
  # (RHH's gmtoolkit ships as a control-folder BINARY via F24, no squashfs).
  if ! grep -q 'gt-h700-squashfs-tmp-guard' "$f"; then
    awk '$0 == "    tmpdir=$(mktemp -d) || return 1" {
      print "    # gt-h700-squashfs-tmp-guard: a too-big-for-tmpfs image would fail its"
      print "    # extract mid-flight and retry forever (no .processed marker on failure);"
      print "    # skip it honestly instead. 4x compressed size is the estimate; vfat SD"
      print "    # space is no fallback (symlinks/exec bits would be lost on rebuild)."
      print "    gt_sq_bytes=$(wc -c < \"$squashfs_file\")"
      print "    gt_tmp_free_kb=$(df -k /tmp | awk '\''NR==2 {print $4}'\'')"
      print "    if [ -n \"$gt_tmp_free_kb\" ] && [ \"$((gt_sq_bytes / 256))\" -gt \"$gt_tmp_free_kb\" ]; then"
      print "        echo \"Skipping $squashfs_basename: estimated extracted size exceeds free /tmp (tmpfs); leaving unprocessed\""
      print "        return 0"
      print "    fi"
      print ""
      print $0
      next
    }
    { print }' "$f" > "$f.awk.tmp" && mv "$f.awk.tmp" "$f"
  fi

  # gt-h700-fast-splash: F33 — run_port's "Starting <port>..." splash is a
  # FOREGROUND minui-presenter with a 3s timeout (show_message's numeric-timeout
  # branch does NOT background), so every port launch blocks a full 3s on a
  # screen that does no work before exec-ing the game. Cut it to 1s. The call is
  # KEPT and stays FOREGROUND on purpose: show_message first kills the "Starting,
  # please wait..." forever-presenter (gt_kill_presenters), so a presenter must
  # not still be alive when the port grabs the mali fbdev surface — that is the
  # F14/F15 present-path desync. Backgrounding or deleting this call would
  # reintroduce it; only the timeout value changes. Exact-line awk match; the
  # anchor is upstream content (pin-safe), and ${ROM_NAME%.*} is a literal string
  # to awk (no shell expansion inside the awk program).
  if ! grep -q 'gt-h700-fast-splash' "$f"; then
    awk '$0 == "    show_message \"Starting ${ROM_NAME%.*}...\" 3" {
      print "    show_message \"Starting ${ROM_NAME%.*}...\" 1  # gt-h700-fast-splash: was a 3s foreground blocking splash doing no work; 1s still kills the please-wait presenter and paints before the port takes fb0 (do NOT background/drop — F14/F15 mali desync)"
      next
    }
    { print }' "$f" > "$f.awk.tmp" && mv "$f.awk.tmp" "$f"
  fi

  # gt-h700-skip-redundant-patch: F33 — patch_pylibs unpacks pylibs.zip once (the
  # zip is deleted on success) but then re-ran its two seds and TWO python3
  # disable_python_function.py spawns on EVERY launch (~0.5s of python cold-start
  # doing nothing — the log says "may already be disabled" twice). Guard the
  # patch block so it runs only when pylibs was (re)extracted this launch
  # (gt_fresh, captured BEFORE unzip_pylibs consumes the zip) or the .gt-patched
  # marker is absent. Self-healing is preserved by construction: the marker is
  # written only AFTER the patches, so a crash between the unzip and the marker
  # re-patches next launch; and a pak upgrade's unzip-over ships a fresh
  # pylibs.zip, so gt_fresh forces a re-patch against the new (unpatched) files.
  # launch.sh runs without set -e, but the guard uses an explicit `if` (not
  # `&& gt_fresh=1`) so it stays correct even if that ever changes. awk state
  # machine: emit the gt_fresh capture right after the function opens, the
  # `if...then` right after unzip_pylibs, and the marker `touch` + `fi` right
  # before the function's closing brace — so it wraps the seds AND both python
  # calls (including the harbour.py one gt-h700-no-self-update injects, which
  # runs earlier in this function so it is already present). The first bare "}"
  # after "patch_pylibs() {" is the function close (its body has no nested "}").
  if ! grep -q 'gt-h700-skip-redundant-patch' "$f"; then
    awk '
    $0 == "patch_pylibs() {" {
      print
      print "    gt_fresh=0  # gt-h700-skip-redundant-patch: re-patch only on a (re)extracted pylibs or a missing marker; steady-state launches skip the ~0.5s of python cold-starts"
      print "    if [ -f \"$EMU_DIR/pylibs.zip\" ]; then gt_fresh=1; fi"
      gt_in_pp = 1
      next
    }
    gt_in_pp == 1 && $0 == "    unzip_pylibs \"$EMU_DIR/pylibs.zip\"" {
      print
      print "    if [ \"$gt_fresh\" = 1 ] || [ ! -f \"$EMU_DIR/pylibs/.gt-patched\" ]; then  # gt-h700-skip-redundant-patch"
      next
    }
    gt_in_pp == 1 && $0 == "}" {
      print "    touch \"$EMU_DIR/pylibs/.gt-patched\"  # gt-h700-skip-redundant-patch: written AFTER patching so a crash mid-patch re-patches next launch"
      print "    fi"
      print
      gt_in_pp = 0
      next
    }
    { print }' "$f" > "$f.awk.tmp" && mv "$f.awk.tmp" "$f"
  fi

  # gt-h700-sleepmon-kill: F47 — reap the sleep watcher on pak exit. A leaked
  # gt-sleepmon would keep suspending NextUI after the port exits. kill by
  # recorded PID plus a /proc comm scan (in-pak killall never matches through
  # the busybox wrapper shadow — the F15 lesson).
  if ! grep -q 'gt-h700-sleepmon-kill' "$f"; then
    awk '$0 == "cleanup() {" {
      print $0
      print "    # gt-h700-sleepmon-kill (F47): see edit_portmaster_launch"
      print "    [ -n \"${gt_sleepmon_pid:-}\" ] && kill \"$gt_sleepmon_pid\" 2>/dev/null"
      print "    for gt_p in /proc/[0-9]*/comm; do"
      print "        [ \"$(cat \"$gt_p\" 2>/dev/null)\" = \"gt-sleepmon\" ] && kill \"$(basename \"$(dirname \"$gt_p\")\")\" 2>/dev/null"
      print "    done"
      next
    }
    { print }' "$f" > "$f.awk.tmp" && mv "$f.awk.tmp" "$f"
  fi

  # NOTE (F49): do NOT add a controller-map.txt transform for apply_button_map
  # ports (Balatro-class). Those ports export their own inline
  # SDL_GAMECONTROLLERCONFIG captured by the user in the port's first-run wizard;
  # it deliberately overrides our layout. The GUI (F50) shows a disclaimer for
  # them instead. See docs/h700-fixes.md (Balatro-class exclusion).

  # gt-h700-controller-layout: F48 — replace the upstream nintendo/xbox pick
  # (a single global "nintendo*" marker file) with the config.json resolver:
  # per-game > global > legacy marker > nintendo. Also export GT_CONTROLLER_LAYOUT
  # so the input shim swaps a<->b / x<->y for gptk/evdev synth ports. The
  # upstream "nintendo_file=" line is left in place (anchor for the other blocks
  # + tier-3 legacy input); only the if/else that consumes it is replaced.
  if ! grep -q 'gt-h700-controller-layout (F48): resolve' "$f"; then
    awk '
    /^    if \[ -n "\$nintendo_file" \]; then$/ {
      print "    # gt-h700-controller-layout (F48): resolve nintendo/xbox from config.json"
      print "    gt_layout=$(\"$PAK_DIR/files/gt-controller-layout.sh\" \"$ROM_NAME\" 2>/dev/null)"
      print "    [ \"$gt_layout\" = nintendo ] || [ \"$gt_layout\" = xbox ] || gt_layout=nintendo"
      print "    set_controller_layout \"$gt_layout\""
      print "    export GT_CONTROLLER_LAYOUT=\"$gt_layout\""
      gt_skip=1; next
    }
    gt_skip==1 && /^    fi$/ { gt_skip=0; next }
    gt_skip==1 { next }
    { print }' "$f" > "$f.awk.tmp" && mv "$f.awk.tmp" "$f"
  fi

  # gt-h700-controller-layout-gui: F48 — the GUI (pugwash) reads the same choice.
  # Replace run_portmaster_gui's hardcoded `set_controller_layout xbox` with the
  # RESOLVED global layout so the GUI pad map matches config.json. Scoped to
  # run_portmaster_gui via in_gui so run_port's identical line is untouched.
  if ! grep -q 'gt-h700-controller-layout-gui' "$f"; then
    awk '
    $0 == "run_portmaster_gui() {" { print; gt_in_gui=1; next }
    gt_in_gui==1 && $0 == "    set_controller_layout xbox" {
      print "    # gt-h700-controller-layout-gui (F48): apply the resolved global layout for the GUI"
      print "    gt_gui_layout=$(\"$PAK_DIR/files/gt-controller-layout.sh\" 2>/dev/null)"
      print "    [ \"$gt_gui_layout\" = nintendo ] || [ \"$gt_gui_layout\" = xbox ] || gt_gui_layout=nintendo"
      print "    set_controller_layout \"$gt_gui_layout\""
      gt_in_gui=0; next
    }
    { print }' "$f" > "$f.awk.tmp" && mv "$f.awk.tmp" "$f"
  fi

  # gt-h700-controller-layout-platform: F48 — patch PlatformTrimUI.loaded() so the
  # GUI's confirm/back follows config.json (same key launch.sh reads for ports).
  if ! grep -q 'gt-h700-controller-layout-platform' "$f"; then
    awk '{ print } $0 == "        \"$EMU_DIR/pylibs/harbourmaster/platform.py\" portmaster_install" {
      print "    # gt-h700-controller-layout-platform (F48): drive the GUI swap from config.json"
      print "    python3 \"$PAK_DIR/src/gt_patch_platform_layout.py\" \\"
      print "        \"$EMU_DIR/pylibs/harbourmaster/platform.py\""
    }' "$f" > "$f.awk.tmp" && mv "$f.awk.tmp" "$f"
  fi

  # gt-h700-controller-layout-options: F48 — add the layout toggle to OptionScene.
  if ! grep -q 'gt-h700-controller-layout-options' "$f"; then
    awk '{ print } $0 == "        \"$EMU_DIR/pylibs/harbourmaster/platform.py\" portmaster_install" {
      print "    # gt-h700-controller-layout-options (F48): OptionScene layout toggle"
      print "    python3 \"$PAK_DIR/src/gt_patch_optionscene_layout.py\" \\"
      print "        \"$EMU_DIR/pylibs/pugscene.py\""
    }' "$f" > "$f.awk.tmp" && mv "$f.awk.tmp" "$f"
  fi

  # gt-h700-portinfo-layout: F50 — per-game controller-layout control on
  # PortInfoScene's free X button (cycles Default -> Nintendo -> Xbox, writing
  # gt-port-layout); apply_button_map/BUTTON_MAP_FILE ports (e.g. Balatro) get
  # a disclaimer instead since they manage their own mapping.
  if ! grep -q 'gt-h700-portinfo-layout' "$f"; then
    awk '{ print } $0 == "        \"$EMU_DIR/pylibs/harbourmaster/platform.py\" portmaster_install" {
      print "    # gt-h700-portinfo-layout (F50): per-game layout control + disclaimer"
      print "    python3 \"$PAK_DIR/src/gt_patch_portinfo_layout.py\" \\"
      print "        \"$EMU_DIR/pylibs/pugscene.py\""
    }' "$f" > "$f.awk.tmp" && mv "$f.awk.tmp" "$f"
  fi

  # gt-h700-nxengine-layout: F49 — after the layout resolves, conform Cave Story's
  # JUMP/FIRE face-button bindings in settings.dat to $gt_layout (idempotent via a
  # stamp; preserves resolution + in-game rebinds). Runs after F39 installed the
  # base blob. Scoped to the nxengine-evo GAMEDIR; off the shim remap list.
  if ! grep -q 'gt-h700-nxengine-layout' "$f"; then
    awk '$0 == "    export GT_CONTROLLER_LAYOUT=\"$gt_layout\"" {
      print $0
      print "    # gt-h700-nxengine-layout (F49): conform Cave Story JUMP/FIRE to $gt_layout"
      print "    if [ \"$PLATFORM\" = \"h700\" ] && [ \"${GAMEDIR##*/}\" = \"nxengine-evo\" ] \\"
      print "        && [ -f \"$GAMEDIR/conf/nxengine/settings.dat\" ]; then"
      print "        \"$PAK_DIR/files/gt-nxengine-conform-layout.sh\" \"$GAMEDIR/conf/nxengine/settings.dat\" \"$gt_layout\""
      print "    fi"
      next
    }
    { print }' "$f" > "$f.awk.tmp" && mv "$f.awk.tmp" "$f"
  fi

  rm -f "$f.bak"
}

edit_portmaster_device_info() { # $1=PortMaster/device_info.txt path
  # The payload resolves resolution via its sdl_resolution probe and falls back
  # to 640x480 when the probe fails — wrong panel for the RG SP (720x480,
  # fb0 mode U:720x480p-59, measured 2026-08-21). F51: the fallback now reads
  # GT_PANEL_W/H (exported by the launch.sh gt-h700-device-pin profile, which
  # reaches this file via run_port -> port script -> control.txt sourcing it),
  # defaulting to the RG SP panel when unset — pre-F51 behavior.
  f=$1
  if ! grep -q 'gt-h700-fallback' "$f"; then
    sed -i.bak \
      -e 's|^    DISPLAY_WIDTH=640$|    DISPLAY_WIDTH=${GT_PANEL_W:-720}   # gt-h700-fallback: panel from the launch.sh device profile (F51)|' \
      -e 's|^    DISPLAY_HEIGHT=480$|    DISPLAY_HEIGHT=${GT_PANEL_H:-480}  # gt-h700-fallback|' \
      "$f"
    rm -f "$f.bak"
  fi
}

edit_portmaster_pugwash() { # $1=PortMaster/pugwash path
  # gt-h700-redraw: F6 — do_draw only presents once per self.updated dirty
  # flag; on h700's malifbdev EGL swap chain a single present never
  # reliably reaches the panel, so any static scene (message boxes, quit
  # confirm, static lists) shows as black (confirmed on-device: with the
  # gate neutralized the whole GUI renders and navigates correctly).
  # GT_FORCE_REDRAW=1 (set h700-only by launch.sh's gt-h700-redraw-env) keeps
  # do_draw drawing every frame; the pre-existing "if self.draw_counter > 30"
  # limiter a few lines down is untouched — it still caps the forced redraw
  # at its built-in ~30fps, it is a frame limiter, not a stop, so leaving it
  # alone is correct. tg5040 never sets the env, so pugwash's runtime
  # behavior there is byte-identical to upstream. Exact-line sed match is
  # safe: the pak.zip is checksum-pinned (2.14.0) and this exact 12-space
  # line occurs exactly once in the file.
  f=$1
  if ! grep -q 'gt-h700-redraw' "$f"; then
    sed -i.bak \
      's|            if not self.updated:|            if not self.updated and os.environ.get("GT_FORCE_REDRAW") != "1":  # gt-h700-redraw: single-present frames are lost on the malifbdev swap chain|' \
      "$f"
    rm -f "$f.bak"
  fi

  # gt-h700-no-self-update: F22 — gate the periodic update prompt off
  # entirely when launch.sh sets GT_DISABLE_PM_UPDATE=1 (it always does in
  # this repackage). A self-update half-overwrites the pinned pak (observed
  # on-device 2026-08-23: partial zip extraction died on a busy binary,
  # leaving a 2025.03/2026 chimera) and any surviving pieces are re-clobbered
  # by launch-time re-patching anyway — the prompt is a foot-gun with no
  # working "yes" path here. Returning None takes the same no-update path the
  # function's own network-failure branch already uses. `os` is imported by
  # upstream pugwash (and the gt-h700-redraw patch relies on it too). Anchor
  # is the def line — unique, upstream content, pin-safe.
  if ! grep -q 'gt-h700-no-self-update' "$f"; then
    awk '{ print } $0 == "def portmaster_check_update(pm, config, temp_dir):" {
      print "    if os.environ.get(\"GT_DISABLE_PM_UPDATE\") == \"1\":  # gt-h700-no-self-update: a self-update half-overwrites the pinned repackage; launch.sh sets this env"
      print "        return None"
    }' "$f" > "$f.awk.tmp" && mv "$f.awk.tmp" "$f"
  fi
}

edit_portmaster_control() { # $1=files/control.txt path
  # gt-h700-pm-platform-helper: F19 — 2026-era port scripts call
  # pm_platform_helper unguarded; the 2025.03 runtime this pak pinned through
  # v0.3.2 predated it, so every such launch logged "command not found" (and
  # any script running under `set -e` would die outright). Upstream's
  # implementation is an effective no-op — a PM_PIPE dialog-exit plus
  # `printf ""` — so a faithful stub is behavior-correct. The 2.14.0 base
  # (PortMaster 2026.07.28) defines it in funcs.txt itself; the stub is kept
  # as belt-and-braces (control.txt sources funcs.txt first, so this later
  # definition wins — identical behavior) and still self-heals a control
  # folder whose funcs.txt went missing.
  # Appended to files/control.txt, which install_control_txt re-installs
  # into the live control folder at EVERY launch — also self-healing after
  # a partial GUI self-update replaces the live copy (observed 2026-08-23).
  f=$1
  if ! grep -q 'gt-h700-pm-platform-helper' "$f"; then
    cat >> "$f" <<'PMEOF'

# gt-h700-pm-platform-helper: no-op stub for 2026-era ports (upstream's own
# funcs.txt definition is the same PM_PIPE dialog-exit + printf ""); kept as
# belt-and-braces since the 2.14.0 base. See build-pak.sh.
pm_platform_helper() {
    if [ -e "${PM_PIPE:-}" ] && command -v PortMasterDialogExit >/dev/null 2>&1; then
        PortMasterDialogExit
    fi
    printf ""
}
PMEOF
  fi
}

strip_weston_runtime() { # $1=pak root (the dir holding files/)
  # gt-h700-weston-strip: F46 — upstream builds its release zip from a
  # get-weston branch that bundles a 44.6MB custom weston_pkg_0.2.squashfs
  # under files/ and moves it into PortMaster/libs at first boot
  # (bootstrap_files). Weston/Crusty ports cannot display on h700 at all (no
  # DRM/KMS scanout — docs/h700-fixes.md "Ports this platform can't run"), so
  # the image is dead weight in the zip and on the SD card. Remove it at
  # build; upstream's bootstrap block stays (its `[ -f ]` guard makes it a
  # no-op) and the official runtime remains downloadable through
  # harbourmaster should a future fix ever need it. A copy already sitting in
  # a device's PortMaster/libs is not touched (the zip ships no libs/).
  rm -f "$1/files/weston_pkg_0.2.squashfs"
}

append_controllerdb() { # $1=repo mapping file $2=target gamecontrollerdb
  # Appends measured RG SP mapping lines (gate-filled; header-only = no-op).
  # Dedupe by GUID so restaging after the gate stays idempotent.
  [ -f "$1" ] || return 0
  grep -v '^#' "$1" | grep -v '^[[:space:]]*$' | while IFS= read -r line; do
    guid=${line%%,*}
    grep -q "^$guid," "$2" || printf '%s\n' "$line" >> "$2"
  done
}

if [ -n "${GT_STAGE_EDIT_ONLY:-}" ]; then
  cmd=${1:?usage: build-pak.sh portmaster}
  case "$cmd" in
    portmaster)
      edit_portmaster_pak_json "$GT_STAGE_EDIT_ONLY/pak.json"
      edit_portmaster_launch "$GT_STAGE_EDIT_ONLY/launch.sh"
      if [ -f "$GT_STAGE_EDIT_ONLY/device_info.txt" ]; then
        edit_portmaster_device_info "$GT_STAGE_EDIT_ONLY/device_info.txt"
      fi
      if [ -f "$GT_STAGE_EDIT_ONLY/pugwash" ]; then
        edit_portmaster_pugwash "$GT_STAGE_EDIT_ONLY/pugwash"
      fi
      if [ -f "$GT_STAGE_EDIT_ONLY/control.txt" ]; then
        edit_portmaster_control "$GT_STAGE_EDIT_ONLY/control.txt"
      fi
      pm_db_dir=${GT_PM_DB_DIR:-$ASSETS}
      if [ -f "$GT_STAGE_EDIT_ONLY/gamecontrollerdb_xbox.txt" ]; then
        append_controllerdb "$pm_db_dir/gamecontrollerdb-h700-xbox.txt" "$GT_STAGE_EDIT_ONLY/gamecontrollerdb_xbox.txt"
      fi
      if [ -f "$GT_STAGE_EDIT_ONLY/gamecontrollerdb_nintendo.txt" ]; then
        append_controllerdb "$pm_db_dir/gamecontrollerdb-h700-nintendo.txt" "$GT_STAGE_EDIT_ONLY/gamecontrollerdb_nintendo.txt"
      fi
      strip_weston_runtime "$GT_STAGE_EDIT_ONLY"
      ;;
    *) echo "usage: build-pak.sh portmaster" >&2; exit 1 ;;
  esac
  exit 0
fi

# Driver glue (verbatim from the original build script's driver) —
# do_portmaster below references $tmp throughout; GT_STAGE_EDIT_ONLY always
# exits above this point, so tests never touch $DIST or create a tmp dir.
mkdir -p "$DIST"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

do_portmaster() {
  # h700 repackage of ben16w/minui-portmaster 2.14.0 — see docs/h700-fixes.md
  # for the fix-by-fix rationale. Everything assembles in $tmp; a pin
  # mismatch or failed build leaves $DIST untouched.
  fetch "$PM_PAK_URL" "$PM_PAK_SHA256" "$tmp/ports-pak.zip"
  fetch "$MP_URL" "$MP_SHA256" "$tmp/minui-presenter"

  # gt-h700-libffi: extract the real libffi.so.7.1.0 out of the pinned .deb.
  # A .deb is an ar archive; `ar p` streams its data.tar.xz payload member to
  # stdout (portable across macOS cctools and Linux binutils, unlike a plain
  # tar which only reads ar on bsdtar/libarchive). Fail-closed here, before any
  # $DIST write, same as every other fetch above.
  fetch "$PM_LIBFFI_DEB_URL" "$PM_LIBFFI_DEB_SHA256" "$tmp/libffi7.deb"
  ar p "$tmp/libffi7.deb" data.tar.xz | tar -xJ -C "$tmp" ./usr/lib/aarch64-linux-gnu/libffi.so.7.1.0
  file "$tmp/usr/lib/aarch64-linux-gnu/libffi.so.7.1.0" | grep -q 'shared object.*aarch64' \
    || { echo "extracted libffi.so.7.1.0 is not an aarch64 shared object" >&2; exit 1; }

  # gt-h700-sdl-ttf-stack: extract the SDL2_ttf dependency chain (F3) the same
  # way — fail-closed here, before any $DIST write. See the PM_SDL2TTF_DEB_URL
  # pins comment for why bullseye's exact package versions differ per-lib.
  fetch "$PM_SDL2TTF_DEB_URL" "$PM_SDL2TTF_DEB_SHA256" "$tmp/sdl2ttf.deb"
  fetch "$PM_FREETYPE_DEB_URL" "$PM_FREETYPE_DEB_SHA256" "$tmp/freetype.deb"
  fetch "$PM_PNG16_DEB_URL" "$PM_PNG16_DEB_SHA256" "$tmp/png16.deb"
  fetch "$PM_BROTLI_DEB_URL" "$PM_BROTLI_DEB_SHA256" "$tmp/brotli.deb"
  ar p "$tmp/sdl2ttf.deb" data.tar.xz | tar -xJ -C "$tmp" ./usr/lib/aarch64-linux-gnu/libSDL2_ttf-2.0.so.0.14.1
  ar p "$tmp/freetype.deb" data.tar.xz | tar -xJ -C "$tmp" ./usr/lib/aarch64-linux-gnu/libfreetype.so.6.17.4
  ar p "$tmp/png16.deb" data.tar.xz | tar -xJ -C "$tmp" ./usr/lib/aarch64-linux-gnu/libpng16.so.16.37.0
  ar p "$tmp/brotli.deb" data.tar.xz \
    | tar -xJ -C "$tmp" ./usr/lib/aarch64-linux-gnu/libbrotlidec.so.1.0.9 ./usr/lib/aarch64-linux-gnu/libbrotlicommon.so.1.0.9
  for gt_sdl_ttf_f in libSDL2_ttf-2.0.so.0.14.1 libfreetype.so.6.17.4 libpng16.so.16.37.0 \
                      libbrotlidec.so.1.0.9 libbrotlicommon.so.1.0.9; do
    file "$tmp/usr/lib/aarch64-linux-gnu/$gt_sdl_ttf_f" | grep -q 'shared object.*aarch64' \
      || { echo "extracted $gt_sdl_ttf_f is not an aarch64 shared object" >&2; exit 1; }
  done

  # gt-h700-sdl-image-stack: extract the SDL2_image codec chain (F5) the same
  # way — fail-closed here, before any $DIST write. See the PM_SDL2IMAGE_DEB_URL
  # pins comment for why libtiff5 needed the debian-security fallback.
  fetch "$PM_SDL2IMAGE_DEB_URL" "$PM_SDL2IMAGE_DEB_SHA256" "$tmp/sdl2image.deb"
  fetch "$PM_JPEG_DEB_URL" "$PM_JPEG_DEB_SHA256" "$tmp/jpeg.deb"
  fetch "$PM_TIFF_DEB_URL" "$PM_TIFF_DEB_SHA256" "$tmp/tiff.deb"
  fetch "$PM_WEBP_DEB_URL" "$PM_WEBP_DEB_SHA256" "$tmp/webp.deb"
  fetch "$PM_JBIG_DEB_URL" "$PM_JBIG_DEB_SHA256" "$tmp/jbig.deb"
  fetch "$PM_DEFLATE_DEB_URL" "$PM_DEFLATE_DEB_SHA256" "$tmp/deflate.deb"
  ar p "$tmp/sdl2image.deb" data.tar.xz | tar -xJ -C "$tmp" ./usr/lib/aarch64-linux-gnu/libSDL2_image-2.0.so.0.2.3
  ar p "$tmp/jpeg.deb" data.tar.xz | tar -xJ -C "$tmp" ./usr/lib/aarch64-linux-gnu/libjpeg.so.62.3.0
  ar p "$tmp/tiff.deb" data.tar.xz | tar -xJ -C "$tmp" ./usr/lib/aarch64-linux-gnu/libtiff.so.5.6.0
  ar p "$tmp/webp.deb" data.tar.xz | tar -xJ -C "$tmp" ./usr/lib/aarch64-linux-gnu/libwebp.so.6.0.2
  ar p "$tmp/jbig.deb" data.tar.xz | tar -xJ -C "$tmp" ./usr/lib/aarch64-linux-gnu/libjbig.so.0
  ar p "$tmp/deflate.deb" data.tar.xz | tar -xJ -C "$tmp" ./usr/lib/aarch64-linux-gnu/libdeflate.so.0
  for gt_sdl_img_f in libSDL2_image-2.0.so.0.2.3 libjpeg.so.62.3.0 libtiff.so.5.6.0 \
                      libwebp.so.6.0.2 libjbig.so.0 libdeflate.so.0; do
    file "$tmp/usr/lib/aarch64-linux-gnu/$gt_sdl_img_f" | grep -q 'shared object.*aarch64' \
      || { echo "extracted $gt_sdl_img_f is not an aarch64 shared object" >&2; exit 1; }
  done

  # gt-h700-bash-ncurses: extract libncurses5/libtinfo5 (F7) the same way —
  # fail-closed here, before any $DIST write. NOTE the member path prefix is
  # ./lib/aarch64-linux-gnu/ (not ./usr/lib/...) for these two debs — verified
  # via `tar -tJ` before writing this, not assumed from the other rounds'
  # ./usr/lib/ pattern.
  fetch "$PM_NCURSES5_DEB_URL" "$PM_NCURSES5_DEB_SHA256" "$tmp/ncurses5.deb"
  fetch "$PM_TINFO5_DEB_URL" "$PM_TINFO5_DEB_SHA256" "$tmp/tinfo5.deb"
  ar p "$tmp/ncurses5.deb" data.tar.xz | tar -xJ -C "$tmp" ./lib/aarch64-linux-gnu/libncurses.so.5.9
  ar p "$tmp/tinfo5.deb" data.tar.xz | tar -xJ -C "$tmp" ./lib/aarch64-linux-gnu/libtinfo.so.5.9
  for gt_bash_f in libncurses.so.5.9 libtinfo.so.5.9; do
    file "$tmp/lib/aarch64-linux-gnu/$gt_bash_f" | grep -q 'shared object.*aarch64' \
      || { echo "extracted $gt_bash_f is not an aarch64 shared object" >&2; exit 1; }
  done

  # gt-h700-openal: extract the OpenAL audio chain (F9) the same way —
  # fail-closed here, before any $DIST write. All four members verified via
  # `tar -tJ` to live under ./usr/lib/aarch64-linux-gnu/ (back to the usual
  # prefix, unlike F7's ncurses/tinfo). libsndio.so.7.0 IS its own soname —
  # the deb ships no separate versioned file, so no rename is needed for it.
  fetch "$PM_OPENAL_DEB_URL" "$PM_OPENAL_DEB_SHA256" "$tmp/openal.deb"
  fetch "$PM_SNDIO_DEB_URL" "$PM_SNDIO_DEB_SHA256" "$tmp/sndio.deb"
  fetch "$PM_LIBBSD_DEB_URL" "$PM_LIBBSD_DEB_SHA256" "$tmp/libbsd.deb"
  fetch "$PM_LIBMD_DEB_URL" "$PM_LIBMD_DEB_SHA256" "$tmp/libmd.deb"
  ar p "$tmp/openal.deb" data.tar.xz | tar -xJ -C "$tmp" ./usr/lib/aarch64-linux-gnu/libopenal.so.1.19.1
  ar p "$tmp/sndio.deb" data.tar.xz | tar -xJ -C "$tmp" ./usr/lib/aarch64-linux-gnu/libsndio.so.7.0
  ar p "$tmp/libbsd.deb" data.tar.xz | tar -xJ -C "$tmp" ./usr/lib/aarch64-linux-gnu/libbsd.so.0.11.3
  ar p "$tmp/libmd.deb" data.tar.xz | tar -xJ -C "$tmp" ./usr/lib/aarch64-linux-gnu/libmd.so.0.0.4
  for gt_openal_f in libopenal.so.1.19.1 libsndio.so.7.0 libbsd.so.0.11.3 libmd.so.0.0.4; do
    file "$tmp/usr/lib/aarch64-linux-gnu/$gt_openal_f" | grep -q 'shared object.*aarch64' \
      || { echo "extracted $gt_openal_f is not an aarch64 shared object" >&2; exit 1; }
  done

  # gt-h700-libogg: F20 — the container layer under the vorbis stack; Solarus
  # ports (Tunics!) link it directly, and the F9/F10 vorbis libs reference it
  # too. DT_NEEDED closure walk of solarus-1.6.5 on-device showed it as the
  # SINGLE unresolvable soname (fix validated live: Tunics! reached its
  # splash screen with this pushed). Same fail-closed extract as F9.
  fetch "$PM_OGG_DEB_URL" "$PM_OGG_DEB_SHA256" "$tmp/ogg.deb"
  ar p "$tmp/ogg.deb" data.tar.xz | tar -xJ -C "$tmp" ./usr/lib/aarch64-linux-gnu/libogg.so.0.8.4
  file "$tmp/usr/lib/aarch64-linux-gnu/libogg.so.0.8.4" | grep -q 'shared object.*aarch64' \
    || { echo "extracted libogg.so.0.8.4 is not an aarch64 shared object" >&2; exit 1; }

  # gt-h700-love-av: extract the LÖVE 11.5 runtime's AV/font/uuid chain (F10)
  # the same way — fail-closed here, before any $DIST write. All seven
  # members verified via `tar -tJ` to live under ./usr/lib/aarch64-linux-gnu/
  # (the usual prefix). Beyond the aarch64 `file` check every other round
  # uses, each extracted file here ALSO gets a MANDATORY exact-hash check
  # against the pinned PM_*_SO_SHA256 value — a mismatch means the deb has
  # moved upstream and blocks staging rather than shipping unverified bytes.
  fetch "$PM_VORBISFILE_DEB_URL" "$PM_VORBISFILE_DEB_SHA256" "$tmp/vorbisfile.deb"
  fetch "$PM_VORBIS_DEB_URL" "$PM_VORBIS_DEB_SHA256" "$tmp/vorbis.deb"
  fetch "$PM_THEORA_DEB_URL" "$PM_THEORA_DEB_SHA256" "$tmp/theora.deb"
  fetch "$PM_MPG123_DEB_URL" "$PM_MPG123_DEB_SHA256" "$tmp/mpg123.deb"
  fetch "$PM_PIXMAN_DEB_URL" "$PM_PIXMAN_DEB_SHA256" "$tmp/pixman.deb"
  fetch "$PM_FONTCONFIG_DEB_URL" "$PM_FONTCONFIG_DEB_SHA256" "$tmp/fontconfig.deb"
  fetch "$PM_UUID_DEB_URL" "$PM_UUID_DEB_SHA256" "$tmp/uuid.deb"
  ar p "$tmp/vorbisfile.deb" data.tar.xz | tar -xJ -C "$tmp" ./usr/lib/aarch64-linux-gnu/libvorbisfile.so.3.3.8
  ar p "$tmp/vorbis.deb" data.tar.xz | tar -xJ -C "$tmp" ./usr/lib/aarch64-linux-gnu/libvorbis.so.0.4.9
  ar p "$tmp/theora.deb" data.tar.xz | tar -xJ -C "$tmp" ./usr/lib/aarch64-linux-gnu/libtheoradec.so.1.1.4
  ar p "$tmp/mpg123.deb" data.tar.xz | tar -xJ -C "$tmp" ./usr/lib/aarch64-linux-gnu/libmpg123.so.0.45.3
  ar p "$tmp/pixman.deb" data.tar.xz | tar -xJ -C "$tmp" ./usr/lib/aarch64-linux-gnu/libpixman-1.so.0.40.0
  ar p "$tmp/fontconfig.deb" data.tar.xz | tar -xJ -C "$tmp" ./usr/lib/aarch64-linux-gnu/libfontconfig.so.1.12.0
  ar p "$tmp/uuid.deb" data.tar.xz | tar -xJ -C "$tmp" ./usr/lib/aarch64-linux-gnu/libuuid.so.1.3.0
  for gt_love_av_f in libvorbisfile.so.3.3.8 libvorbis.so.0.4.9 libtheoradec.so.1.1.4 libmpg123.so.0.45.3 \
                      libpixman-1.so.0.40.0 libfontconfig.so.1.12.0 libuuid.so.1.3.0; do
    file "$tmp/usr/lib/aarch64-linux-gnu/$gt_love_av_f" | grep -q 'shared object.*aarch64' \
      || { echo "extracted $gt_love_av_f is not an aarch64 shared object" >&2; exit 1; }
  done
  gt_check_extracted_hash() { # $1=file $2=expected sha256 — F10 MANDATORY check
    got=$(shasum -a 256 "$1" | cut -d' ' -f1)
    [ "$got" = "$2" ] \
      || { echo "extracted-file SHA-256 mismatch for $1: got $got want $2 — BLOCKED, not shipping" >&2; exit 1; }
  }
  gt_check_extracted_hash "$tmp/usr/lib/aarch64-linux-gnu/libvorbisfile.so.3.3.8" "$PM_VORBISFILE_SO_SHA256"
  gt_check_extracted_hash "$tmp/usr/lib/aarch64-linux-gnu/libvorbis.so.0.4.9" "$PM_VORBIS_SO_SHA256"
  gt_check_extracted_hash "$tmp/usr/lib/aarch64-linux-gnu/libtheoradec.so.1.1.4" "$PM_THEORADEC_SO_SHA256"
  gt_check_extracted_hash "$tmp/usr/lib/aarch64-linux-gnu/libmpg123.so.0.45.3" "$PM_MPG123_SO_SHA256"
  gt_check_extracted_hash "$tmp/usr/lib/aarch64-linux-gnu/libpixman-1.so.0.40.0" "$PM_PIXMAN_SO_SHA256"
  gt_check_extracted_hash "$tmp/usr/lib/aarch64-linux-gnu/libfontconfig.so.1.12.0" "$PM_FONTCONFIG_SO_SHA256"
  gt_check_extracted_hash "$tmp/usr/lib/aarch64-linux-gnu/libuuid.so.1.3.0" "$PM_UUID_SO_SHA256"

  # gt-h700-libsndfile: F40 — the RSDK Sonic ports (sonic2013/sonicforever/
  # sonic2absolute) link libsndfile.so.1, absent everywhere on h700, so the
  # loader aborts before main() and the ports exit instantly. Stage it plus the
  # two sonames its DT_NEEDED closure adds that aren't already shipped —
  # libvorbisenc.so.2 and libopus.so.0 (libFLAC/libvorbis/libogg are F9/F10/F20).
  # Same fail-closed extract as F9/F10, with the F10 mandatory extracted-hash
  # check. All three members verified via `tar -tJ` under ./usr/lib/aarch64-linux-gnu/.
  fetch "$PM_SNDFILE_DEB_URL" "$PM_SNDFILE_DEB_SHA256" "$tmp/sndfile.deb"
  fetch "$PM_VORBISENC_DEB_URL" "$PM_VORBISENC_DEB_SHA256" "$tmp/vorbisenc.deb"
  fetch "$PM_OPUS_DEB_URL" "$PM_OPUS_DEB_SHA256" "$tmp/opus.deb"
  ar p "$tmp/sndfile.deb" data.tar.xz | tar -xJ -C "$tmp" ./usr/lib/aarch64-linux-gnu/libsndfile.so.1.0.31
  ar p "$tmp/vorbisenc.deb" data.tar.xz | tar -xJ -C "$tmp" ./usr/lib/aarch64-linux-gnu/libvorbisenc.so.2.0.12
  ar p "$tmp/opus.deb" data.tar.xz | tar -xJ -C "$tmp" ./usr/lib/aarch64-linux-gnu/libopus.so.0.8.0
  for gt_snd_f in libsndfile.so.1.0.31 libvorbisenc.so.2.0.12 libopus.so.0.8.0; do
    file "$tmp/usr/lib/aarch64-linux-gnu/$gt_snd_f" | grep -q 'shared object.*aarch64' \
      || { echo "extracted $gt_snd_f is not an aarch64 shared object" >&2; exit 1; }
  done
  gt_check_extracted_hash "$tmp/usr/lib/aarch64-linux-gnu/libsndfile.so.1.0.31" "$PM_SNDFILE_SO_SHA256"
  gt_check_extracted_hash "$tmp/usr/lib/aarch64-linux-gnu/libvorbisenc.so.2.0.12" "$PM_VORBISENC_SO_SHA256"
  gt_check_extracted_hash "$tmp/usr/lib/aarch64-linux-gnu/libopus.so.0.8.0" "$PM_OPUS_SO_SHA256"

  assembled="$tmp/PORTS.pak"
  mkdir -p "$assembled"
  unzip -q "$tmp/ports-pak.zip" -d "$assembled"
  { [ -f "$assembled/launch.sh" ] && [ -d "$assembled/PortMaster" ]; } \
    || { echo "zip layout changed: launch.sh / PortMaster/ not at zip root" >&2; exit 1; }

  edit_portmaster_pak_json "$assembled/pak.json"
  edit_portmaster_launch "$assembled/launch.sh"
  edit_portmaster_device_info "$assembled/PortMaster/device_info.txt"
  edit_portmaster_pugwash "$assembled/PortMaster/pugwash"
  edit_portmaster_control "$assembled/files/control.txt"
  append_controllerdb "$ASSETS/gamecontrollerdb-h700-xbox.txt" "$assembled/files/gamecontrollerdb_xbox.txt"
  append_controllerdb "$ASSETS/gamecontrollerdb-h700-nintendo.txt" "$assembled/files/gamecontrollerdb_nintendo.txt"

  # F48: stage the layout resolver run_port/run_portmaster_gui call into.
  cp -f "$ASSETS/gt-controller-layout.sh" "$assembled/files/gt-controller-layout.sh"
  chmod +x "$assembled/files/gt-controller-layout.sh"

  # F49: stage the nxengine-evo (Cave Story) settings.dat layout-conform helper.
  cp -f "$ASSETS/gt-nxengine-conform-layout.sh" "$assembled/files/gt-nxengine-conform-layout.sh"
  chmod +x "$assembled/files/gt-nxengine-conform-layout.sh"

  # F48: stage the GUI PlatformTrimUI patch helper that patch_pylibs invokes.
  # $assembled/src/ already exists from the upstream ports-pak.zip extraction
  # (it ships disable_python_function.py); mkdir -p is defensive.
  mkdir -p "$assembled/src"
  cp "$ROOT/src/gt_patch_platform_layout.py" "$assembled/src/gt_patch_platform_layout.py"

  # F48: stage the OptionScene layout-toggle patch helper that patch_pylibs invokes.
  cp "$ROOT/src/gt_patch_optionscene_layout.py" "$assembled/src/gt_patch_optionscene_layout.py"

  # F50: stage the PortInfoScene per-game layout patch helper that patch_pylibs invokes.
  cp "$ROOT/src/gt_patch_portinfo_layout.py" "$assembled/src/gt_patch_portinfo_layout.py"

  strip_weston_runtime "$assembled"

  # libgl insurance: CFW_NAME resolves to "Base OS" on the device; if a port
  # sources libgl_${CFW_NAME}.txt unguarded, hand it the default config
  # (byte-identical to the muOS one; handles no-/dev/dri via LIBGL_FB=2).
  cp "$assembled/PortMaster/libgl_default.txt" "$assembled/PortMaster/libgl_Base OS.txt"

  # E5: h700-nextui minui-presenter — bin/ copy (pak UI) AND files/ copy (the
  # one replace_progressor_binaries injects into installed ports).
  cp "$tmp/minui-presenter" "$assembled/bin/minui-presenter"
  cp "$tmp/minui-presenter" "$assembled/files/minui-presenter"
  chmod +x "$assembled/bin/minui-presenter" "$assembled/files/minui-presenter" || :

  # E5: power-control stub — upstream binary is tg5040-built and cannot run on
  # h700. This stub is NOT the port-sleep feature: deep sleep during a port is
  # provided separately by gt-sleepmon (F47; see edit_portmaster_launch's
  # gt-h700-sleepmon splice) watching the power-key node directly.
  # preflight_checks only requires minui-power-control to exist; launch.sh backgrounds it, so an
  # instant exit 0 here is fine. NOTE: this repackage is h700-only — do not
  # deploy the staged pak to a tg5040.
  cat > "$assembled/bin/minui-power-control" <<'PMEOF'
#!/bin/sh
# gt-h700-stub: upstream binary is tg5040-built; port sleep is provided by gt-sleepmon instead (F47).
exit 0
PMEOF
  chmod +x "$assembled/bin/minui-power-control"

  # E7: ship the remap shim; preloaded only via the gt-h700-remap-hook flag.
  mkdir -p "$assembled/lib"
  cp "$ASSETS/gt-input-remap.so" "$assembled/lib/gt-input-remap.so"
  cp "$ASSETS/gt-fmod-audio.so" "$assembled/lib/gt-fmod-audio.so"
  # gt-h700-gles3-profile: F37 — the ES3-profile shim, preloaded by run_port
  # only for gothic-engine machismo ports (auto-gated on libgothic_patches.so;
  # see edit_portmaster_launch).
  cp "$ASSETS/gt-gles3-profile.so" "$assembled/lib/gt-gles3-profile.so"

  # gt-sdl-audio-init: F42 — force SDL audio-subsystem init for the RSDK Sonic
  # ports (auto-gated on $GAMEDIR/sonic2013; see edit_portmaster_launch).
  cp "$ASSETS/gt-sdl-audio-init.so" "$assembled/lib/gt-sdl-audio-init.so"

  # gt-input-remap.armhf.so: F45 — the 32-bit build of the input shim, preloaded
  # by the Animal Crossing launcher (a 32-bit armhf port; see the ac-gc-h700
  # staging below and edit_portmaster_launch's gt-h700-ac-launcher). Fail-closed
  # on the ELF class so a stale aarch64 build can never ship under this name.
  cp "$ASSETS/gt-input-remap.armhf.so" "$assembled/lib/gt-input-remap.armhf.so"
  file "$assembled/lib/gt-input-remap.armhf.so" | grep -q 'ELF 32-bit.*ARM' \
    || { echo "gt-input-remap.armhf.so is not a 32-bit ARM shared object" >&2; exit 1; }

  # gt-h700-port-remap: F25 — pak-shipped default list of ports that get the
  # shim preloaded at launch (read by the run_port hook that
  # edit_portmaster_launch adds; users extend via use-remap-ports in
  # userdata without rebuilding).
  cp "$ASSETS/gt-remap-ports.txt" "$assembled/files/gt-remap-ports.txt"

  # gt-h700-hud: F34 — pak-shipped default blocklist of ports where the
  # in-game HUD overlay is known to misbehave (read by the same run_port
  # hook); users extend via use-hud-blocklist in userdata without rebuilding.
  cp "$ASSETS/gt-hud-blocklist.txt" "$assembled/files/gt-hud-blocklist.txt"

  # gt-h700-sleepmon / gt-h700-alsa-suspend: F47 — sleep watcher + ALSA
  # suspend-proxy (see edit_portmaster_launch). Fail closed on arch so a
  # wrong-arch docker build can never ship (F45 lesson).
  cp "$ASSETS/gt-sleepmon" "$assembled/bin/gt-sleepmon"
  file "$assembled/bin/gt-sleepmon" | grep -q 'ELF 64-bit.*aarch64' \
    || { echo "gt-sleepmon is not an aarch64 executable" >&2; exit 1; }
  cp "$ASSETS/libasound_module_pcm_gt_suspend.so" "$assembled/lib/libasound_module_pcm_gt_suspend.so"
  file "$assembled/lib/libasound_module_pcm_gt_suspend.so" | grep -q 'ELF 64-bit.*aarch64' \
    || { echo "gt_suspend plugin is not an aarch64 shared object" >&2; exit 1; }
  cp "$ASSETS/libasound_module_pcm_gt_suspend.armhf.so" "$assembled/lib/libasound_module_pcm_gt_suspend.armhf.so"
  file "$assembled/lib/libasound_module_pcm_gt_suspend.armhf.so" | grep -q 'ELF 32-bit.*ARM' \
    || { echo "gt_suspend armhf plugin is not a 32-bit ARM shared object" >&2; exit 1; }
  cp "$ASSETS/gt-sleep-blocklist.txt" "$assembled/files/gt-sleep-blocklist.txt"
  cp "$ASSETS/gt-asound.conf" "$assembled/files/gt-asound.conf"

  # gt-h700-nxengine-settings: F39 — h700-correct nxengine-evo (Cave Story Evo)
  # controls + resolution. nxengine-evo reads the raw SDL joystick and binds
  # actions to button INDICES (and a resolution INDEX) in settings.dat; the
  # porter's defaults assume a device whose d-pad is buttons 8-11 and a taller
  # screen, so on h700 (d-pad = hat0, faces raw 3-13, 720x480 fb) the d-pad was
  # dead, faces scrambled, and the 720x720 render overran the screen. run_port
  # installs this file ONCE per port install (see edit_portmaster_launch). Kept
  # OUT of files/port-fixes/ on purpose: the F27 overlay re-copies every launch,
  # which would revert the user's in-game rebinds/resolution changes.
  mkdir -p "$assembled/files/nxengine-h700"
  cp "$ASSETS/nxengine-evo-h700-settings.dat" "$assembled/files/nxengine-h700/settings.dat"

  # gt-h700-solarus-nojit: F28 — the -s pre-script run_port injects into
  # solarus port invocations (see edit_portmaster_launch).
  cp "$ASSETS/solarus-nojit.lua" "$assembled/files/solarus-nojit.lua"

  # gt-h700-source-heal: F29 — pinned copies of harbourmaster's
  # HM_SOURCE_DEFAULTS, restored by run_portmaster_gui when config.json
  # survives but the *.source.json files are gone (see
  # edit_portmaster_launch).
  mkdir -p "$assembled/files/gt-source-defaults"
  cp "$ASSETS/gt-source-defaults/"*.source.json "$assembled/files/gt-source-defaults/"

  # gt-h700-libffi: TrimUI provides libffi.so.7 via /usr/trimui/lib; h700 has
  # none (BaseOS ships only ABI-incompatible libffi.so.8), and the bundled
  # bullseye python3.11's _ctypes needs it or pugwash crashes on `import
  # ctypes` (gate finding 2026-08-22). Ship the real file, not a symlink.
  cp "$tmp/usr/lib/aarch64-linux-gnu/libffi.so.7.1.0" "$assembled/lib/libffi.so.7"

  # gt-h700-sdl-ttf-stack / gt-h700-sdl-image-stack: F3 + F5 — ship as
  # SONAME-named real files (renamed off the full versioned deb filename; the
  # device SD is vfat, so no symlinks). PYSDL2_DLL_PATH is this one dir on
  # h700 (edit_portmaster_launch's E3), so it must be self-sufficient. WHY
  # both are overridden while core SDL2 (gt-h700-sdl-core, in
  # edit_portmaster_launch) is instead synced from the system dir at launch:
  # NextUI's SDL2_ttf is 2.0.13 (< pysdl2's 2.0.14 minimum) and its
  # libSDL2_image is built without JPEG support (the GUI theme loads a .jpg) —
  # core SDL2 itself has no such gap, so it doesn't need pak-side replacing.
  cp "$tmp/usr/lib/aarch64-linux-gnu/libSDL2_ttf-2.0.so.0.14.1" "$assembled/lib/libSDL2_ttf-2.0.so.0"
  cp "$tmp/usr/lib/aarch64-linux-gnu/libfreetype.so.6.17.4" "$assembled/lib/libfreetype.so.6"
  cp "$tmp/usr/lib/aarch64-linux-gnu/libpng16.so.16.37.0" "$assembled/lib/libpng16.so.16"
  cp "$tmp/usr/lib/aarch64-linux-gnu/libbrotlidec.so.1.0.9" "$assembled/lib/libbrotlidec.so.1"
  cp "$tmp/usr/lib/aarch64-linux-gnu/libbrotlicommon.so.1.0.9" "$assembled/lib/libbrotlicommon.so.1"
  cp "$tmp/usr/lib/aarch64-linux-gnu/libSDL2_image-2.0.so.0.2.3" "$assembled/lib/libSDL2_image-2.0.so.0"
  cp "$tmp/usr/lib/aarch64-linux-gnu/libjpeg.so.62.3.0" "$assembled/lib/libjpeg.so.62"
  cp "$tmp/usr/lib/aarch64-linux-gnu/libtiff.so.5.6.0" "$assembled/lib/libtiff.so.5"
  cp "$tmp/usr/lib/aarch64-linux-gnu/libwebp.so.6.0.2" "$assembled/lib/libwebp.so.6"
  cp "$tmp/usr/lib/aarch64-linux-gnu/libjbig.so.0" "$assembled/lib/libjbig.so.0"
  cp "$tmp/usr/lib/aarch64-linux-gnu/libdeflate.so.0" "$assembled/lib/libdeflate.so.0"

  # gt-h700-bash-ncurses: F7 — the pak's bundled DYNAMIC bash needs
  # libncurses.so.5; TrimUI provides it via /usr/trimui/lib, h700 doesn't, so
  # every port launch died at loader time without it.
  cp "$tmp/lib/aarch64-linux-gnu/libncurses.so.5.9" "$assembled/lib/libncurses.so.5"
  cp "$tmp/lib/aarch64-linux-gnu/libtinfo.so.5.9" "$assembled/lib/libtinfo.so.5"

  # gt-h700-openal: F9 — OpenAL audio chain for GL/gl4es ports; TrimUI
  # provides it, h700 doesn't.
  cp "$tmp/usr/lib/aarch64-linux-gnu/libopenal.so.1.19.1" "$assembled/lib/libopenal.so.1"
  cp "$tmp/usr/lib/aarch64-linux-gnu/libsndio.so.7.0" "$assembled/lib/libsndio.so.7.0"
  cp "$tmp/usr/lib/aarch64-linux-gnu/libbsd.so.0.11.3" "$assembled/lib/libbsd.so.0"
  cp "$tmp/usr/lib/aarch64-linux-gnu/libmd.so.0.0.4" "$assembled/lib/libmd.so.0"

  # gt-h700-libogg: F20 — SONAME-named real file, same vfat-no-symlinks rule.
  cp "$tmp/usr/lib/aarch64-linux-gnu/libogg.so.0.8.4" "$assembled/lib/libogg.so.0"

  # gt-h700-libsndfile: F40 — the RSDK Sonic ports' audio chain. SONAME-named
  # real files (same vfat-no-symlinks rule); libsndfile NEEDs both of the other
  # two, and the pak lib/ is on every port's LD_LIBRARY_PATH, so this fixes
  # Sonic 1 and Sonic 2 with no per-port change.
  cp "$tmp/usr/lib/aarch64-linux-gnu/libsndfile.so.1.0.31" "$assembled/lib/libsndfile.so.1"
  cp "$tmp/usr/lib/aarch64-linux-gnu/libvorbisenc.so.2.0.12" "$assembled/lib/libvorbisenc.so.2"
  cp "$tmp/usr/lib/aarch64-linux-gnu/libopus.so.0.8.0" "$assembled/lib/libopus.so.0"

  # gt-h700-7zzs: F18 — modern port patchscripts (deltarune, the RHH
  # GameMaker ports) invoke "$controlfolder/7zzs.$DEVICE_ARCH" for archive
  # surgery. ben16w's repackage ships 7zzs.aarch64 only inside
  # files/bin.tar.gz (unpacked to bin/ at first boot, which is NOT the
  # control folder), so the call failed silently — the deltarune patcher
  # then shipped empty skeleton APKs and DELETED the user's data.win files
  # (observed on-device 2026-08-23; the failure was invisible until F17
  # restored patcher logging). Stage the same pinned binary into
  # PortMaster/ at build time, fail-closed like every other staged file.
  # Since the 2.14.0 base the control folder ships its own 7zzs.aarch64
  # (PortMaster-GUI 2026.07.28); staging ben16w's bin/ copy over it keeps the
  # path guaranteed regardless of upstream packaging (same tool, fail-closed).
  gt_7zzs_src="$assembled/bin/7zzs.aarch64"
  if [ ! -f "$gt_7zzs_src" ]; then
    mkdir -p "$tmp/binx"
    tar -xzf "$assembled/files/bin.tar.gz" -C "$tmp/binx"
    gt_7zzs_src=$(find "$tmp/binx" -name 7zzs.aarch64 -type f | head -1)
  fi
  { [ -n "$gt_7zzs_src" ] && [ -f "$gt_7zzs_src" ]; } \
    || { echo "7zzs.aarch64 not found in bin/ or files/bin.tar.gz" >&2; exit 1; }
  cp "$gt_7zzs_src" "$assembled/PortMaster/7zzs.aarch64"
  chmod +x "$assembled/PortMaster/7zzs.aarch64"
  file "$assembled/PortMaster/7zzs.aarch64" | grep -q 'aarch64' \
    || { echo "staged 7zzs.aarch64 is not an aarch64 binary" >&2; exit 1; }

  # gt-h700-port-fixes: F27 — pak-shipped replacement files for known-broken
  # port installs, applied per launch by the run_port overlay hook (see
  # edit_portmaster_launch). First case: tunics_pm's bundled libmodplug dies
  # on an illegal instruction on this device (see the PM_MODPLUG pin
  # comment); ship bullseye's build under the port's own libs.aarch64 name.
  fetch "$PM_MODPLUG_DEB_URL" "$PM_MODPLUG_DEB_SHA256" "$tmp/modplug.deb"
  ar p "$tmp/modplug.deb" data.tar.xz | tar -xJ -C "$tmp" ./usr/lib/aarch64-linux-gnu/libmodplug.so.1.0.0
  file "$tmp/usr/lib/aarch64-linux-gnu/libmodplug.so.1.0.0" | grep -q 'shared object.*aarch64' \
    || { echo "extracted libmodplug.so.1.0.0 is not an aarch64 shared object" >&2; exit 1; }
  mkdir -p "$assembled/files/port-fixes/tunics_pm/libs.aarch64"
  cp "$tmp/usr/lib/aarch64-linux-gnu/libmodplug.so.1.0.0" \
     "$assembled/files/port-fixes/tunics_pm/libs.aarch64/libmodplug.so.1"

  # gt-h700-sonic-gptk: F43 — RSDK Sonic ports read SDL_GameController (which
  # is correctly recognized on h700) but controls stay dead — an
  # RSDK-internal defect this pak can't fix natively. Fall back to the pak's
  # keyboard-synthesis path (same F27 overlay mechanism): ship a corrected
  # sonic.gptk mapping the gamepad to RSDK's [Keyboard 1] scancodes, read by
  # gt-input-remap.so once Sonic 1.sh/Sonic 2.sh are on the remap list.
  mkdir -p "$assembled/files/port-fixes/sonic1"
  cp "$ASSETS/port-fixes/sonic1/sonic.gptk" "$assembled/files/port-fixes/sonic1/sonic.gptk"
  mkdir -p "$assembled/files/port-fixes/sonic2"
  cp "$ASSETS/port-fixes/sonic2/sonic.gptk" "$assembled/files/port-fixes/sonic2/sonic.gptk"

  # gt-h700-ac-runtime: F45 — the complete pak-hosted runtime for Animal
  # Crossing (a 32-bit armhf port; NextUI is aarch64-only, so the port's own
  # aarch64 libs dir is empty and the stock SDL/GL/Mali stack is missing). The
  # launcher (files/ac-gc-h700/Animal Crossing.sh, re-installed over the port's
  # own every launch by run_port's gt-h700-ac-launcher hook) points at this
  # runtime and gptk by absolute $PAK_DIR path, so the harbourmaster install
  # itself stays untouched (only save/conf are written there). libs.armhf is the
  # 15-lib 32-bit runtime — SDL 2.0.12, the Mali-G31 blob (libmali.so.0), and
  # their deps — sourced from the stock Anbernic card; the gptk is the pad->key
  # map read by the shim (GT_EVDEV_KEYS synthesis). Fail-closed on the Mali
  # blob's ELF class so an aarch64 lib set can never ship under this name.
  mkdir -p "$assembled/files/ac-gc-h700/libs.armhf"
  cp "$ASSETS/ac-gc-h700/libs.armhf/"* "$assembled/files/ac-gc-h700/libs.armhf/"
  cp "$ASSETS/ac-gc-h700/animalcrossing.gptk" "$assembled/files/ac-gc-h700/animalcrossing.gptk"
  cp "$ASSETS/ac-gc-h700/Animal Crossing.sh" "$assembled/files/ac-gc-h700/Animal Crossing.sh"
  file "$assembled/files/ac-gc-h700/libs.armhf/libmali.so.0" | grep -q 'ELF 32-bit.*ARM' \
    || { echo "ac-gc-h700 libmali.so.0 is not a 32-bit ARM shared object" >&2; exit 1; }

  # gt-h700-gmtoolkit: F24 — RHH GameMaker patchscripts hard-require
  # "$controlfolder/gmtoolkit.$DEVICE_ARCH" (see the PM_GMTOOLKIT pin
  # comment). Fetched pinned, license shipped alongside, fail-closed.
  fetch "$PM_GMTOOLKIT_ZIP_URL" "$PM_GMTOOLKIT_ZIP_SHA256" "$tmp/gmtoolkit.zip"
  mkdir -p "$tmp/gmtk"
  unzip -q "$tmp/gmtoolkit.zip" -d "$tmp/gmtk"
  cp "$tmp/gmtk/gmtoolkit.aarch64" "$assembled/PortMaster/gmtoolkit.aarch64"
  cp "$tmp/gmtk/gmtoolkit.LICENSE.txt" "$assembled/PortMaster/gmtoolkit.LICENSE.txt"
  chmod +x "$assembled/PortMaster/gmtoolkit.aarch64"
  file "$assembled/PortMaster/gmtoolkit.aarch64" | grep -q 'aarch64' \
    || { echo "staged gmtoolkit.aarch64 is not an aarch64 binary" >&2; exit 1; }

  # gt-h700-love-av: F10 — the LÖVE 11.5 runtime's liblove links
  # vorbisfile/theoradec/mpg123 (readelf-verified) with pixman/fontconfig/uuid
  # pulled in transitively; TrimUI provides them, h700 doesn't. Gate-validated
  # on-device 2026-08-22 (love.aarch64 --version runs). Ship as real files,
  # not symlinks — the device SD is vfat.
  cp "$tmp/usr/lib/aarch64-linux-gnu/libvorbisfile.so.3.3.8" "$assembled/lib/libvorbisfile.so.3"
  cp "$tmp/usr/lib/aarch64-linux-gnu/libvorbis.so.0.4.9" "$assembled/lib/libvorbis.so.0"
  cp "$tmp/usr/lib/aarch64-linux-gnu/libtheoradec.so.1.1.4" "$assembled/lib/libtheoradec.so.1"
  cp "$tmp/usr/lib/aarch64-linux-gnu/libmpg123.so.0.45.3" "$assembled/lib/libmpg123.so.0"
  cp "$tmp/usr/lib/aarch64-linux-gnu/libpixman-1.so.0.40.0" "$assembled/lib/libpixman-1.so.0"
  cp "$tmp/usr/lib/aarch64-linux-gnu/libfontconfig.so.1.12.0" "$assembled/lib/libfontconfig.so.1"
  cp "$tmp/usr/lib/aarch64-linux-gnu/libuuid.so.1.3.0" "$assembled/lib/libuuid.so.1"

  PAK="$DIST/Emus/h700/PORTS.pak"
  mkdir -p "$DIST/Emus/h700"
  rm -rf "$PAK"
  mv "$assembled" "$PAK"
  (cd "$DIST/Emus/h700" && rm -f PORTS.pak.zip && zip -qr PORTS.pak.zip PORTS.pak)
  mkdir -p "$DIST/Roms/Ports (PORTS)"
  # Upstream canon: a non-empty comment-only trigger (102 bytes) — gate G1
  # found the Ports GUI entry didn't show with a 0-byte `touch`ed file.
  cat > "$DIST/Roms/Ports (PORTS)/0) Portmaster.sh" <<'PMEOF'
# Portmaster.sh
# This file will signal to open the PortMaster GUI when placed in the Roms directory.
PMEOF
  echo "staged: $PAK (+ .zip, + Roms trigger)"
}

cmd=${1:?usage: build-pak.sh portmaster}
case "$cmd" in
  portmaster) do_portmaster ;;
  *) echo "usage: build-pak.sh portmaster" >&2; exit 1 ;;
esac
