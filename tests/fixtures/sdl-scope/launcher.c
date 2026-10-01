/* F68 fixture: the xash3d.aarch64 shape — links only libdl/libc and dlopens
 * the engine. "local" = dlopen(RTLD_NOW), exactly what Xash3D does (its SDL2
 * lands in a private scope the preloaded shim's RTLD_NEXT can't see);
 * "global" = RTLD_NOW|RTLD_GLOBAL, the control case. */
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>

int main(int argc, char **argv) {
    int mode = RTLD_NOW;
    if (argc > 1 && strcmp(argv[1], "global") == 0) mode |= RTLD_GLOBAL;
    void *h = dlopen("libengine.so", mode);
    if (!h) { fprintf(stderr, "launcher: %s\n", dlerror()); return 2; }
    int (*run)(void) = (int (*)(void))dlsym(h, "engine_run");
    if (!run) { fprintf(stderr, "launcher: no engine_run\n"); return 2; }
    return run();
}
