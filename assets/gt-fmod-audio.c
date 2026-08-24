/* gt-fmod-audio.so — an auto-gating LD_PRELOAD shim for gmloadernext FMOD
 * ports on the RG SP (h700), where the audio codec is single-client.
 *
 * The h700 kernel has no SysV IPC, so ALSA cannot build a dmix (software
 * mixing) device: only ONE client may hold hw:audiocodec at a time. A
 * GameMaker port that ships FMOD opens the codec TWICE — first the runner's
 * own GameMaker-native audio device (a plain playback open, ~22050 Hz), then
 * FMOD's FMOD_SDL output plugin (48000 Hz, requesting SDL_AUDIO_ALLOW_FORMAT_
 * CHANGE). The runner wins the race and holds the device, so FMOD_SDL's open
 * fails EBUSY, FMOD ends up with no output, and the game is SILENT — while
 * every non-FMOD sound (menus, the runner's own effects) works. The same port
 * has sound on an RG DS because ROCKNIX runs PulseAudio, which is shareable.
 *
 * This shim interposes SDL_OpenAudioDevice and SUPPRESSES the runner's own
 * (non-FMOD_SDL) playback open — returning failure so the runner proceeds
 * without native audio — which leaves the single codec free for FMOD_SDL's
 * open to succeed. FMOD_SDL is identified by ALLOW_FORMAT_CHANGE (0x4), which
 * FMOD_SDL always requests and the GameMaker runner never does; capture opens
 * are never touched.
 *
 * Trade-off: the runner's GameMaker-native audio is lost. FMOD-shipping ports
 * route all audio through FMOD, so in practice that is nothing; a port that
 * mixed runner-native and FMOD audio would lose the runner-native half.
 *
 * The gate is the launcher (build-pak.sh gt-h700-fmod-audio): this shim is
 * only preloaded for ports that carry libs/libfmod*.so*, so it never loads
 * for a non-FMOD port. Once loaded it acts unconditionally — the launcher's
 * FMOD-lib detection IS the gate, which keeps this shim byte-for-byte
 * identical in behavior to the version verified on hardware (Pizza Tower,
 * 2026-08-24).
 *
 * Build: see the Makefile `shim` target (aarch64, -shared -fPIC -ldl).
 * Not compiled for the host except with -DGT_FMOD_TEST, which strips the
 * interposer and exposes a main() that asserts the suppression decision.
 */
#define _GNU_SOURCE

/* The one decision, factored out so it can be unit-tested without SDL.
 * Returns 1 if this SDL_OpenAudioDevice call is the GameMaker runner's own
 * native-audio open (suppress it), 0 if it must pass through to real SDL.
 * FMOD_SDL sets SDL_AUDIO_ALLOW_FORMAT_CHANGE (0x4); capture opens (cap != 0)
 * are always passed through untouched. */
static int gt_fmod_suppress(int cap, int allow) {
    return !cap && !(allow & 0x4);
}

#ifdef GT_FMOD_TEST

#include <stdio.h>

int main(void) {
    /* runner: playback open without FORMAT_CHANGE -> suppress */
    if (!gt_fmod_suppress(0, 0x0)) { puts("FAIL: runner open must be suppressed"); return 1; }
    if (!gt_fmod_suppress(0, 0x1)) { puts("FAIL: runner open (freq-change only) must be suppressed"); return 1; }
    if (!gt_fmod_suppress(0, 0x3)) { puts("FAIL: runner open (freq+format) must be suppressed"); return 1; }
    /* FMOD_SDL: playback open carrying FORMAT_CHANGE (0x4; typically 0x7) -> pass */
    if (gt_fmod_suppress(0, 0x4)) { puts("FAIL: FMOD_SDL open (bare FORMAT_CHANGE) must pass"); return 1; }
    if (gt_fmod_suppress(0, 0x7)) { puts("FAIL: FMOD_SDL open (all allow flags) must pass"); return 1; }
    /* capture opens always pass, whatever the allow flags */
    if (gt_fmod_suppress(1, 0x0)) { puts("FAIL: capture open must pass"); return 1; }
    if (gt_fmod_suppress(1, 0x7)) { puts("FAIL: capture open must pass"); return 1; }
    puts("fmod-audio ok");
    return 0;
}

#else /* the real interposer */

#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>

/* SDL_AudioDeviceID is a Uint32; the first field of SDL_AudioSpec is `int freq`. */
typedef uint32_t gt_devid;

static int gt_debug(void) {
    static int v = -1;
    if (v < 0) {
        const char *e = getenv("GT_FMOD_AUDIO_DEBUG");
        v = (e && *e) ? 1 : 0;
    }
    return v;
}

/* One unconditional line at load: launch.sh redirects stderr into the pak
 * log, so this is the cheap on-device proof that the preload took effect. */
__attribute__((constructor))
static void gt_init(void) {
    fprintf(stderr, "gt-fmod-audio: loaded\n");
}

gt_devid SDL_OpenAudioDevice(const char *dev, int cap, const void *want, void *have, int allow) {
    static gt_devid (*real)(const char *, int, const void *, void *, int);
    if (!real)
        real = (gt_devid (*)(const char *, int, const void *, void *, int))
               dlsym(RTLD_NEXT, "SDL_OpenAudioDevice");

    if (gt_fmod_suppress(cap, allow)) {
        if (gt_debug()) {
            int wf = want ? *(const int *)want : 0;
            fprintf(stderr, "gt-fmod-audio: suppressed runner open (freq=%d allow=0x%x) to free the codec\n",
                    wf, allow);
        }
        return 0; /* report failure; the runner proceeds without native audio */
    }

    gt_devid id = real(dev, cap, want, have, allow);
    if (gt_debug()) {
        int wf = want ? *(const int *)want : 0;
        const char *(*ge)(void) = (const char *(*)(void)) dlsym(RTLD_NEXT, "SDL_GetError");
        fprintf(stderr, "gt-fmod-audio: passed FMOD_SDL open (freq=%d allow=0x%x) -> id=%u%s%s\n",
                wf, allow, id,
                (id == 0 && ge) ? " err=" : "",
                (id == 0 && ge) ? ge() : "");
    }
    return id;
}

#endif /* GT_FMOD_TEST */
