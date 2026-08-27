/* gt-gles3-profile.so — an optional LD_PRELOAD shim for PortMaster processes
 * on the RG SP (h700). One job: force SDL to create a NATIVE OpenGL ES 3.x
 * context instead of the GL4ES desktop-GL wrapper.
 *
 * Background (measured on-device 2026-08-27, port: Mina the Hollower by
 * bmdhacks — a Darling/machismo Mac-arm64 port whose "gothic" engine emits
 * GLSL ES 3.10 shaders and, when Vulkan is absent, renders through a GLES
 * backend):
 *
 *   The port's window/context shim sets up its GL context under SDL's KMSDRM
 *   video path with the DEFAULT (desktop) GL profile. On this pak that resolves
 *   to GL4ES (libGL.so.1) — a GL 2.1 / GLSL 1.20 wrapper. GL4ES runs its
 *   ShaderConv on every shader and rewrites `#version 310 es` down to
 *   `#version 100`, while leaving the `layout(...)` qualifiers in place. That is
 *   invalid GLSL ES 1.00, so the first shader (copy.vert) fails to compile and
 *   the render thread aborts (SIGABRT) before anything draws.
 *
 *   The h700's Mali r20p0 blob natively exposes OpenGL ES 3.2 / GLSL ES 3.20 and
 *   compiles those shaders as-is — but the port never reaches it, because SDL
 *   only binds the native GLES driver (libGLESv2.so.2 + EGL_OPENGL_ES_API) when
 *   the context is requested with an ES profile. No environment variable moves
 *   the port off GL4ES (LIBGL_ES=3, LIBGL_SHADERNOGLES, SDL_VIDEO_GL_DRIVER and
 *   SDL_VIDEODRIVER=mali were all tried on-device; each still landed on GL4ES),
 *   because the profile is chosen inside the port's own compiled shim, which
 *   exposes no knob. This preload supplies the missing knob.
 *
 * Mechanism: interpose SDL_GL_CreateContext. Immediately before the real call,
 * set the three GL attributes that steer SDL's KMSDRM/EGL path onto the native
 * Mali GLES driver:
 *
 *   SDL_GL_CONTEXT_PROFILE_MASK  = SDL_GL_CONTEXT_PROFILE_ES
 *   SDL_GL_CONTEXT_MAJOR_VERSION = 3
 *   SDL_GL_CONTEXT_MINOR_VERSION = 1   (>= the highest #version the game uses,
 *                                       310 es; Mali grants its 3.2 max)
 *
 * SDL uses the most-recently-set attribute values at CreateContext time, so
 * setting them here (last, on the same thread the engine creates its context on
 * — the render thread) wins over whatever the port requested. Buttons/audio and
 * every other subsystem are untouched.
 *
 * Scope: this is deliberately NOT global. launch.sh preloads it ONLY for ports
 * that need a native-ES3 context (currently Mina) — forcing an ES profile on the
 * many ports that legitimately want GL4ES/desktop-GL would break them. Gating by
 * WHO gets the preload keeps the shim itself dumb: whenever it is loaded, it
 * forces ES3. Same arrangement as gt-fmod-audio.
 *
 * Real SDL functions are reached via dlsym(RTLD_NEXT, ...) — SDL2 is loaded
 * after this preloaded shim — so the link stays -ldl only (no -lSDL2), matching
 * the other gt-* shims.
 *
 * GT_GLES3_DEBUG=1 traces each forced context to stderr (which launch.sh
 * redirects into the pak log) — used for the hands-on hardware gate.
 *
 * Built via `make shim` (a linux/arm64 Debian container). The SDL2 headers there
 * are only used for the stable ABI enum values and opaque types; the three
 * attribute enums and the ES profile bit have been fixed since SDL 2.0.0, so a
 * shim built against the container's SDL2 runs correctly against the device's
 * SDL 2.28.5.
 */

#define _GNU_SOURCE  /* must precede the first libc include: dlfcn.h's RTLD_NEXT */
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <SDL2/SDL.h>

static int gt_gles3_debug(void)
{
    static int d = -1;
    if (d < 0) {
        const char *e = getenv("GT_GLES3_DEBUG");
        d = (e && *e && *e != '0') ? 1 : 0;
    }
    return d;
}

/* Also interpose SDL_GL_SetAttribute. SDL commits to a GL library (native
 * libGLESv2 for an ES profile, GL4ES's libGL for a desktop/default profile)
 * when the GL library is first loaded — which, for a window created with
 * SDL_WINDOW_OPENGL, happens during SDL_CreateWindow, BEFORE the later
 * SDL_GL_CreateContext. So forcing the profile only at CreateContext time is
 * too late. If the port's Metal->GL window shim configures GL attributes while
 * it adds SDL_WINDOW_OPENGL (i.e. before the real SDL_CreateWindow), rewriting
 * the profile/version attributes here flips the library to native GLES before
 * it is committed. Non-profile/version attributes pass through untouched. */
int SDL_GL_SetAttribute(SDL_GLattr attr, int value)
{
    static int (*real)(SDL_GLattr, int);
    if (!real)
        real = (int (*)(SDL_GLattr, int))dlsym(RTLD_NEXT, "SDL_GL_SetAttribute");

    int forced = value;
    switch (attr) {
    case SDL_GL_CONTEXT_PROFILE_MASK:  forced = SDL_GL_CONTEXT_PROFILE_ES; break;
    case SDL_GL_CONTEXT_MAJOR_VERSION: forced = 3; break;
    case SDL_GL_CONTEXT_MINOR_VERSION: forced = 1; break;
    default: break;
    }
    if (forced != value && gt_gles3_debug())
        fprintf(stderr, "gt-gles3-profile: SDL_GL_SetAttribute(%d) %d -> %d (forced ES3)\n",
                (int)attr, value, forced);

    return real ? real(attr, forced) : -1;
}

SDL_GLContext SDL_GL_CreateContext(SDL_Window *window)
{
    static SDL_GLContext (*real_create)(SDL_Window *);
    static int (*real_setattr)(SDL_GLattr, int);

    if (!real_create)
        real_create = (SDL_GLContext (*)(SDL_Window *))dlsym(RTLD_NEXT, "SDL_GL_CreateContext");
    if (!real_setattr)
        real_setattr = (int (*)(SDL_GLattr, int))dlsym(RTLD_NEXT, "SDL_GL_SetAttribute");

    if (real_setattr) {
        real_setattr(SDL_GL_CONTEXT_PROFILE_MASK, SDL_GL_CONTEXT_PROFILE_ES);
        real_setattr(SDL_GL_CONTEXT_MAJOR_VERSION, 3);
        real_setattr(SDL_GL_CONTEXT_MINOR_VERSION, 1);
        if (gt_gles3_debug())
            fprintf(stderr, "gt-gles3-profile: forced GLES 3.1 profile before SDL_GL_CreateContext\n");
    } else if (gt_gles3_debug()) {
        fprintf(stderr, "gt-gles3-profile: SDL_GL_SetAttribute unavailable — passing through\n");
    }

    SDL_GLContext ctx = real_create ? real_create(window) : NULL;
    if (gt_gles3_debug())
        fprintf(stderr, "gt-gles3-profile: SDL_GL_CreateContext(window=%p) -> %p\n",
                (void *)window, (void *)ctx);
    return ctx;
}
