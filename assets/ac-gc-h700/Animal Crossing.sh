#!/bin/bash
# PortMaster launcher — Animal Crossing (GameCube decomp port)
# Target: Anbernic RG-34XX SP and other armhf PortMaster devices.
#
# gt-h700 (F45): Animal Crossing is a 32-bit armhf port; NextUI is aarch64-only.
# The pak ships a complete 32-bit runtime and a build of the input shim and this
# launcher wires them up. run_port re-installs this launcher over the port's own
# every launch (copy_game_scripts reverts it to the porter's pristine source);
# see edit_portmaster_launch's gt-h700-ac-launcher block. Everything the port
# needs beyond the porter's own files is pak-hosted and referenced by absolute
# $PAK_DIR paths, so the harbourmaster install stays untouched (save/conf only):
#   $PAK_DIR/files/ac-gc-h700/libs.armhf/   — the 15-lib 32-bit runtime (Mali blob)
#   $PAK_DIR/files/ac-gc-h700/animalcrossing.gptk — the pad->key map for the shim
#   $PAK_DIR/lib/gt-input-remap.armhf.so     — the 32-bit build of the input shim

XDG_DATA_HOME=${XDG_DATA_HOME:-$HOME/.local/share}

if [ -d "/opt/system/Tools/PortMaster/" ]; then
  controlfolder="/opt/system/Tools/PortMaster"
elif [ -d "/opt/tools/PortMaster/" ]; then
  controlfolder="/opt/tools/PortMaster"
elif [ -d "$XDG_DATA_HOME/PortMaster/" ]; then
  controlfolder="$XDG_DATA_HOME/PortMaster"
else
  controlfolder="/mnt/SDCARD/Emus/h700/PORTS.pak/PortMaster"
fi

source $controlfolder/control.txt
[ -f "${controlfolder}/mod_${CFW_NAME}.txt" ] && source "${controlfolder}/mod_${CFW_NAME}.txt"
get_controls

GAMEDIR="/$directory/ports/ac-gc"
CONFDIR="$GAMEDIR/conf"
mkdir -p "$CONFDIR" "$GAMEDIR/rom"

# GT-F45: the pak-hosted 32-bit runtime + shim + gptk (referenced below by
# absolute $PAK_DIR paths). PAK_DIR is exported by the pak's launch.sh.
GT_AC_RUNTIME="$PAK_DIR/files/ac-gc-h700"

cd "$GAMEDIR"
: > "$GAMEDIR/log.txt"
# Plain redirect: the previous tee process-substitution silently dropped
# stdout on the device shell, truncating log.txt at early init.
exec >> "$GAMEDIR/log.txt" 2>&1

# First-run settings tuned for these handhelds (Mali-G31): fullscreen,
# no MSAA, vsync on, dynamic FPS target. Resolution is intentionally NOT
# set here: the game auto-detects the panel's native mode at startup
# (RG35XX 640x480, RG-34XX SP 720x480, CubeXX 720x720). Add
# window_width/window_height under [Graphics] only to force a resolution.
# The in-game settings menu can change all of these afterwards.
if [ ! -f "$GAMEDIR/settings.ini" ]; then
cat > "$GAMEDIR/settings.ini" <<'EOF'
[Graphics]
fullscreen = 1
vsync = 1
msaa = 0
[Performance]
fps_target = 6
particle_quality = 2
EOF
fi

export XDG_DATA_HOME="$CONFDIR"
export LD_LIBRARY_PATH="/usr/lib32:$GT_AC_RUNTIME/libs.armhf:$GAMEDIR/libs.${DEVICE_ARCH}:$LD_LIBRARY_PATH:/mnt/SDCARD/.system/h700/lib:/mnt/SDCARD/Emus/h700/PORTS.pak/lib"   # GT-F45: NextUI DEVICE_ARCH=aarch64, so add the pak-hosted 32-bit libs.armhf explicitly
# muOS audio is PipeWire; 32-bit clients need the lib32 plugin paths set
# explicitly or pw_loop_new fails with "can't make support.system handle".
[ -d /usr/lib32/spa-0.2 ] && export SPA_PLUGIN_DIR=/usr/lib32/spa-0.2
[ -d /usr/lib32/pipewire-0.3 ] && export PIPEWIRE_MODULE_DIR=/usr/lib32/pipewire-0.3
export SDL_AUDIODRIVER=alsa   # GT-F45: stock SDL 2.0.12 can't parse a comma-list (pre-2.24) + NextUI has no PipeWire; force plain ALSA or SDL_Init aborts

# gt-h700-alsa-armhf (F47): run_port routes every h700 port's ALSA "default"
# through the pak's suspend-proxy plugin (ALSA_CONFIG_PATH -> /tmp/gt-asound.conf),
# unless this port is sleep-blocklisted, in which case ALSA_CONFIG_PATH is unset
# and this block is a no-op. That template's pcm_type.gt_suspend.lib line points
# at the AARCH64 build of the plugin — AC's own 32-bit libasound.so.2
# (libs.armhf/, loaded via LD_LIBRARY_PATH above) would dlopen it and fail on
# ELF class mismatch, so snd_pcm_open("default") fails and AC launches silent.
# Regenerate the same template with the armhf plugin build swapped in and
# re-export ALSA_CONFIG_PATH to point at the armhf variant instead.
if [ -n "${ALSA_CONFIG_PATH:-}" ] && [ -f "$PAK_DIR/files/gt-asound.conf" ]; then
    sed -e "s|@PAK_DIR@|$PAK_DIR|g" \
        -e "s|libasound_module_pcm_gt_suspend\.so|libasound_module_pcm_gt_suspend.armhf.so|" \
        "$PAK_DIR/files/gt-asound.conf" > /tmp/gt-asound-armhf.conf
    if [ -s /tmp/gt-asound-armhf.conf ]; then
        export ALSA_CONFIG_PATH=/tmp/gt-asound-armhf.conf
    else
        unset ALSA_CONFIG_PATH   # fail closed: fall back to the system default rather than the broken aarch64 config
    fi
fi

export SDL_GAMECONTROLLERCONFIG="$sdl_controllerconfig"
export SDL_VIDEODRIVER=mali   # GT-F45: the stock 32-bit SDL2 compiles only the mali/dummy video drivers; force mali (fbdev) — NextUI has no DRM/KMS
export SDL_VIDEO_EGL_DRIVER="$GT_AC_RUNTIME/libs.armhf/libEGL.so"     # GT-F45: load EGL from our 32-bit lib by absolute path (robust vs LD search order)
export SDL_VIDEO_GL_DRIVER="$GT_AC_RUNTIME/libs.armhf/libGLESv2.so"   # GT-F45: same for GLES
export LD_PRELOAD="$PAK_DIR/lib/gt-input-remap.armhf.so"             # GT-F45: 32-bit build of the input shim — synthesizes keyboard state from the pad (gptokeyb uinput doesn't reach AC's polled SDL_GetKeyboardState)
export GT_REMAP_GPTK="$GT_AC_RUNTIME/animalcrossing.gptk"            # GT-F45: pad -> keybindings.ini key map for the shim
export GT_EVDEV_KEYS=1                                               # GT-F45: synthesize keys straight from the pad's evdev device — AC's stock 32-bit SDL delivers ZERO joystick events, so every SDL-based path (native controller, gptokeyb, the shim's SDL synth) is dead; the evdev thread is the only source that reaches the game
chmod +x "$GAMEDIR/AnimalCrossing"

$GPTOKEYB "AnimalCrossing" &   # GT-F45: gptokeyb kept ONLY for the start+select quit hotkey; gameplay input comes from the armhf gt-input-remap shim (uinput keyboard doesn't reach AC's polled SDL_GetKeyboardState)
pm_platform_helper "$GAMEDIR/AnimalCrossing"
./AnimalCrossing

pm_finish
