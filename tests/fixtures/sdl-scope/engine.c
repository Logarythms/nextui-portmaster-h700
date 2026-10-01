/* F68 fixture: the libxash.so shape — a library that links SDL2 and EGL
 * (NEEDED) and is itself dlopen'd by a launcher. Like Xash3D it carries on
 * after a failed SDL_Init, so a NULL-forwarding shim crashes here instead of
 * just returning an error. */
#include <stdio.h>

int SDL_Init(unsigned int flags);
int SDL_PollEvent(void *ev);
int SDL_WaitEventTimeout(void *ev, int timeout);
const unsigned char *SDL_GetKeyboardState(int *numkeys);
void SDL_GL_SwapWindow(void *win);
void SDL_RenderPresent(void *r);
unsigned int eglSwapBuffers(void *dpy, void *surf);

int engine_run(void) {
    char ev[64];
    int n = 0;
    setvbuf(stdout, NULL, _IONBF, 0);   /* keep every line if a call segfaults */
    printf("engine: SDL_Init=%d\n", SDL_Init(0x20u /* SDL_INIT_VIDEO */));
    printf("engine: SDL_PollEvent=%d\n", SDL_PollEvent(ev));
    printf("engine: SDL_WaitEventTimeout=%d\n", SDL_WaitEventTimeout(ev, 0));
    SDL_GetKeyboardState(&n);
    printf("engine: numkeys=%d\n", n);
    SDL_GL_SwapWindow(0);
    SDL_RenderPresent(0);
    printf("engine: eglSwapBuffers=%u\n", eglSwapBuffers(0, 0));
    printf("engine: done\n");
    return 0;
}
