/* gt-sdl-audio-init.so — F42. RSDKv4 InitAudioPlayback() calls
 * SDL_OpenAudioDevice without SDL_InitSubSystem(SDL_INIT_AUDIO); on h700 audio
 * is not inited at that point, so the open fails ("Audio subsystem is not
 * initialized") and the game runs silent. We force-init the audio subsystem
 * on the first open. Preloaded only for the RSDK Sonic ports (build-pak.sh
 * gate on $GAMEDIR/sonic2013). Harmless if audio is already inited. */
#include <stdint.h>

#define GT_SDL_INIT_AUDIO 0x00000010u

/* Pure, testable decision: init only when the audio subsystem is not up. */
static int gt_should_init_audio(unsigned wasinit_audio) { return wasinit_audio ? 0 : 1; }

#ifdef GT_SDL_AUDIO_TEST
#include <stdlib.h>
#include <stdio.h>
int main(int argc, char **argv) {
    unsigned w = (argc > 1) ? (unsigned)atoi(argv[1]) : 0;
    printf("%d\n", gt_should_init_audio(w));
    return 0;
}
#else
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>

static int gt_debug(void) { const char *e = getenv("GT_SDL_AUDIO_DEBUG"); return e && *e == '1'; }

__attribute__((constructor)) static void gt_load(void) {
    if (gt_debug()) fprintf(stderr, "gt-sdl-audio-init: loaded\n");
}

/* SDL_OpenAudioDevice(const char*, int iscapture, const SDL_AudioSpec*, SDL_AudioSpec*, int allowed) -> SDL_AudioDeviceID (uint32) */
uint32_t SDL_OpenAudioDevice(const char *device, int iscapture,
                             const void *desired, void *obtained, int allowed_changes) {
    static uint32_t (*real)(const char *, int, const void *, void *, int);
    static unsigned (*p_wasinit)(unsigned);
    static int (*p_initsub)(unsigned);
    if (!real)      real      = (uint32_t (*)(const char *, int, const void *, void *, int))dlsym(RTLD_NEXT, "SDL_OpenAudioDevice");
    if (!p_wasinit) p_wasinit = (unsigned (*)(unsigned))dlsym(RTLD_NEXT, "SDL_WasInit");
    if (!p_initsub) p_initsub = (int (*)(unsigned))dlsym(RTLD_NEXT, "SDL_InitSubSystem");

    unsigned w = p_wasinit ? (p_wasinit(GT_SDL_INIT_AUDIO) & GT_SDL_INIT_AUDIO) : GT_SDL_INIT_AUDIO;
    if (gt_should_init_audio(w) && p_initsub) {
        int rc = p_initsub(GT_SDL_INIT_AUDIO);
        if (gt_debug()) fprintf(stderr, "gt-sdl-audio-init: SDL_InitSubSystem(AUDIO) rc=%d\n", rc);
    }
    return real ? real(device, iscapture, desired, obtained, allowed_changes) : 0;
}
#endif
