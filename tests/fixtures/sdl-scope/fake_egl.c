/* F68 fixture: a stand-in libEGL.so.1 for the interposed eglSwapBuffers. */
#include <stdio.h>

unsigned int eglSwapBuffers(void *dpy, void *surf) {
    (void)dpy; (void)surf;
    printf("fake: eglSwapBuffers\n");
    return 1;
}
