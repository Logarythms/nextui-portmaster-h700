/* F68 fixture: a stand-in libSDL2-2.0.so.0 (built with that soname) exporting
 * just the entry points gt-input-remap.so interposes or resolves. Each one
 * prints a "fake:" line, so the check can tell a call that reached SDL from
 * one the shim swallowed. Plain C types only — no SDL headers. */
#include <stdio.h>

static unsigned int inited;

int SDL_Init(unsigned int flags) { inited |= flags; printf("fake: SDL_Init\n"); return 0; }
int SDL_InitSubSystem(unsigned int flags) { inited |= flags; return 0; }
unsigned int SDL_WasInit(unsigned int flags) { return inited & flags; }
const char *SDL_GetError(void) { return ""; }
int SDL_PollEvent(void *ev) { (void)ev; printf("fake: SDL_PollEvent\n"); return 0; }
int SDL_WaitEventTimeout(void *ev, int t) { (void)ev; (void)t; printf("fake: SDL_WaitEventTimeout\n"); return 0; }
const unsigned char *SDL_GetKeyboardState(int *n) {
    static unsigned char keys[512];
    printf("fake: SDL_GetKeyboardState\n");
    if (n) *n = 512;
    return keys;
}
int SDL_NumJoysticks(void) { return 0; }
void *SDL_JoystickOpen(int i) { (void)i; return 0; }
void *SDL_GL_GetProcAddress(const char *name) { (void)name; return 0; }
void SDL_GL_SwapWindow(void *win) { (void)win; printf("fake: SDL_GL_SwapWindow\n"); }
void SDL_RenderPresent(void *r) { (void)r; printf("fake: SDL_RenderPresent\n"); }
