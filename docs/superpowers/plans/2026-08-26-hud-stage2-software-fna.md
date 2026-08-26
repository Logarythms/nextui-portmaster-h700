# HUD Stage 2 (F35) — Software-Renderer Draw + Universal evdev Toggle — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend the F34 in-game HUD so it draws on SDL-software-renderer ports (Apotris) via a `SDL_RenderPresent` backend, and toggles on every engine (Celeste/mono, Apotris/gptokeyb, all GL ports) via a universal evdev reader thread.

**Architecture:** Two additions to the existing `assets/gt-input-remap.c` LD_PRELOAD shim plus one behavioral change. (1) Interpose `SDL_RenderPresent`, drawing the already-composed HUD RGBA through the SDL_Renderer API (backend-agnostic). (2) A detached `pthread` reads the Menu button straight from `/dev/input/event*` — below mono/gptokeyb/SDL — and becomes the sole toggle authority, reusing the host-tested `gt_menu_toggle` state machine. (3) The F34 SDL `SDL_PollEvent`/`SDL_WaitEventTimeout` interposers keep *swallowing* the Menu edges but no longer toggle (Decision A).

**Tech Stack:** C (LD_PRELOAD shim, `-fPIC -shared`), SDL2 (headers only; symbols resolved at runtime via `dlsym(RTLD_NEXT, …)`), GLES2/EGL (F34, unchanged), Linux evdev (`linux/input.h`), pthreads. Build in an arm64 Debian container via `make shim`. Host-only pure-logic tests behind `-DGT_REMAP_TEST` run natively (`tests/test-05-input-remap.sh`).

**Spec:** `docs/superpowers/specs/2026-08-26-hud-stage2-software-fna-design.md`

## Global Constraints

- **Device safety:** never overwrite a running `.so` or script in place on the RG SP — always `scp` to a temp path then `mv` over. Keep a `.pre-f35.bak` of any file replaced during the gate.
- **Device-confirmed evdev codes (RG SP, 2026-08-26):** Menu = `BTN_TL2` (312) + `KEY_GOTO` (354); Volume = `KEY_VOLUMEUP` (115) / `KEY_VOLUMEDOWN` (114); all on the `ANBERNIC-keys` device (`/dev/input/event1`, which is also `js0`). The toggle device is **discovered by capability** (a device whose `EV_KEY` bitmap has BOTH 312 and 354), never a hardcoded index.
- **Toggle semantics (reuse F34's `gt_menu_toggle` verbatim):** MENU drives the tap with `is_menu=1`; VOL drives it with `is_menu=0` (so a Vol press during a Menu hold disqualifies the tap → keymon's Menu+Vol brightness combo is untouched); `KEY_GOTO` (354) is **skipped**, exactly as raw 14 is in the SDL path. `input_event.value`: 1=down, 0=up, 2=autorepeat (skip 2).
- **Thread safety:** `gt_hud_visible` is written only by the evdev thread and read by the draw paths → declare it `volatile int`; `gt_menu_toggle`'s `visible` param becomes `volatile int *` (compiles for both builds — `int*`→`volatile int*` is a valid implicit qualification conversion, so the host test's plain `int vis` still passes).
- **Software texture format:** `SDL_PIXELFORMAT_ABGR8888` (little-endian byte order R,G,B,A) — matches the exact RGBA buffer F34 already feeds `glTexImage2D` as `GL_RGBA`.
- **Crash-safety (opt-out feature):** each new path has an independent dead-latch (`gt_sw_dead` for the software draw) or a benign exit (the evdev thread on any error) — a failure disables that path for the session, never crashes the host.
- **Decision A is binding:** the SDL interposers keep swallowing raw 11/14 but MUST NOT call `gt_menu_toggle` anymore. The evdev thread is the only toggle authority.
- **No `build/build-pak.sh` change** — F34 already made LD_PRELOAD + `GT_HUD=1` universal for h700 ports.
- **Release discipline:** do NOT merge, push, tag, or cut 0.3.0 without Camille's explicit go-ahead. One squashed commit per phase at merge time (docs fold in).

**User decisions (already made):**
- "go with A" — hybrid: keep the SDL Menu-swallow, make the evdev thread the sole toggle authority (non-regressive).
- The device gate on the RG SP (`ssh root@10.0.1.16`) is user-ordered and non-skippable.
- 0.3.0 (F33+F34+F35) ships only after all three engine paths work and the gate passes — and only on Camille's go-ahead.

---

### Task 1: Thread-safe visibility + host-tested evdev-decode helper (pure)

**Goal:** Make `gt_hud_visible` safe to write from a second thread, and add a pure, host-tested classifier that maps an evdev key code to Menu / Volume / Other so the (device-only) thread body reduces to "read → classify → `gt_menu_toggle`".

**Files:**
- Modify: `assets/gt-input-remap.c` — shared/pure section (classifier + `gt_menu_toggle` param), interposer decl (`gt_hud_visible`), and `main()` asserts under `#ifdef GT_REMAP_TEST`.
- Test: `tests/test-05-input-remap.sh` (unchanged runner).

**Acceptance Criteria:**
- [ ] `gt_menu_toggle`'s signature is `int gt_menu_toggle(gt_tap_state *s, volatile int *visible, int is_menu, int is_down)`; the existing host-test calls (which pass `&vis` for a plain `int vis`) still compile and pass.
- [ ] `gt_hud_visible` is declared `static volatile int gt_hud_visible;`.
- [ ] A pure `gt_evkey_class(int code)` returns `GT_EVK_MENU` for 312, `GT_EVK_VOL` for 114 and 115, and `GT_EVK_OTHER` for everything else (354 included).
- [ ] `main()` asserts the classifier for 312/114/115/354/0 and runs one evdev-style tap sequence through `gt_menu_toggle` (MENU-down, MENU-up → visible flips on; MENU-down, VOL-down, MENU-up → no flip). `main()` still prints `remap ok`.

**Verify:** `sh tests/test-05-input-remap.sh` → exits 0, prints `remap ok`.

**Steps:**

- [ ] **Step 1: Add evdev code constants + classifier (shared section).** Immediately after `gt_menu_swallow` (the block ending at line ~539, before `typedef struct { int menu_held … } gt_tap_state;`), add:

```c
/* evdev key codes for the Menu/Volume buttons on this device family (RG SP,
 * ANBERNIC-keys / event1, device-confirmed 2026-08-26). The universal evdev
 * toggle thread (interposer half) classifies raw kernel key codes with this
 * pure helper. KEY_GOTO (354) is Menu's second emission — SKIPPED, exactly as
 * raw 14 is skipped in the SDL path; only BTN_TL2 (312) drives the tap. */
#define GT_EVCODE_MENU      312   /* BTN_TL2       */
#define GT_EVCODE_MENU_ALT  354   /* KEY_GOTO      */
#define GT_EVCODE_VOLUP     115   /* KEY_VOLUMEUP  */
#define GT_EVCODE_VOLDOWN   114   /* KEY_VOLUMEDOWN */
enum { GT_EVK_OTHER = 0, GT_EVK_MENU = 1, GT_EVK_VOL = 2 };
static int gt_evkey_class(int code) {
    if (code == GT_EVCODE_MENU) return GT_EVK_MENU;
    if (code == GT_EVCODE_VOLUP || code == GT_EVCODE_VOLDOWN) return GT_EVK_VOL;
    return GT_EVK_OTHER;   /* includes KEY_GOTO (354) */
}
```

- [ ] **Step 2: Widen `gt_menu_toggle`'s `visible` param to `volatile int *`.** Change the signature at line ~543 from `int *visible` to `volatile int *visible`. The body is unchanged (`*visible = !*visible` on a volatile int is well-defined; single writer, so no RMW race). This lets the evdev thread pass `&gt_hud_visible` (a `volatile int *`) while the host test keeps passing `&vis` for a plain `int` (implicit `int*`→`volatile int*` conversion).

```c
static int gt_menu_toggle(gt_tap_state *s, volatile int *visible, int is_menu, int is_down) {
```

- [ ] **Step 3: Make `gt_hud_visible` volatile (interposer decl).** At line ~840 change:

```c
/* HUD visibility. Written ONLY by the evdev toggle thread (Task 3); read by
 * the GL and software draw paths. volatile so the reader never caches it in a
 * register across frames; a single word on this target is written atomically. */
static volatile int gt_hud_visible;
```

- [ ] **Step 4: Add host asserts (in `main()`, `#ifdef GT_REMAP_TEST`).** After the existing tap-machine block (the one ending at line ~777, `"lone non-menu must not be swallowed"`), add:

```c
    /* evdev classifier: exact code → class */
    if (gt_evkey_class(GT_EVCODE_MENU)     != GT_EVK_MENU)  return fail("evkey 312 = MENU");
    if (gt_evkey_class(GT_EVCODE_VOLUP)    != GT_EVK_VOL)   return fail("evkey 115 = VOL");
    if (gt_evkey_class(GT_EVCODE_VOLDOWN)  != GT_EVK_VOL)   return fail("evkey 114 = VOL");
    if (gt_evkey_class(GT_EVCODE_MENU_ALT) != GT_EVK_OTHER) return fail("evkey 354 (GOTO) = OTHER");
    if (gt_evkey_class(0)                  != GT_EVK_OTHER) return fail("evkey 0 = OTHER");

    /* evdev-thread tap sequence: MENU tap flips; Vol-during-hold disqualifies. */
    { gt_tap_state s; memset(&s, 0, sizeof s); int vis = 0;
      /* clean tap: MENU down then up -> flip on */
      gt_menu_toggle(&s, &vis, gt_evkey_class(GT_EVCODE_MENU) == GT_EVK_MENU, 1);
      gt_menu_toggle(&s, &vis, gt_evkey_class(GT_EVCODE_MENU) == GT_EVK_MENU, 0);
      if (vis != 1) return fail("evdev clean tap flips HUD on");
      /* Menu+Vol combo: MENU down, VOL down, MENU up -> no flip */
      gt_menu_toggle(&s, &vis, gt_evkey_class(GT_EVCODE_MENU)  == GT_EVK_MENU, 1);
      gt_menu_toggle(&s, &vis, gt_evkey_class(GT_EVCODE_VOLUP) == GT_EVK_MENU, 1); /* VOL -> is_menu=0 */
      gt_menu_toggle(&s, &vis, gt_evkey_class(GT_EVCODE_MENU)  == GT_EVK_MENU, 0);
      if (vis != 1) return fail("evdev Menu+Vol combo does NOT toggle"); }
```

- [ ] **Step 5: Build + run the host test.**

Run: `sh tests/test-05-input-remap.sh`
Expected: exits 0, prints `remap ok`.

- [ ] **Step 6: Commit.**

```bash
git add assets/gt-input-remap.c
git commit -m "feat(F35): thread-safe gt_hud_visible + pure evdev-decode helper (host-tested)"
```

```json:metadata
{"files": ["assets/gt-input-remap.c", "tests/test-05-input-remap.sh"], "verifyCommand": "sh tests/test-05-input-remap.sh", "acceptanceCriteria": ["gt_menu_toggle takes volatile int *visible; host-test calls still compile + pass", "gt_hud_visible is volatile int", "gt_evkey_class maps 312->MENU, 114/115->VOL, else (incl 354)->OTHER", "main() asserts the classifier + an evdev-style tap sequence and still prints 'remap ok'"], "modelTier": "mechanical"}
```

---

### Task 2: Software-renderer draw backend — `SDL_RenderPresent` interpose

**Goal:** Draw the HUD on SDL_Renderer ports (Apotris) by interposing `SDL_RenderPresent` and blitting the already-composed HUD RGBA through the SDL_Renderer API, backend-agnostic, with an independent crash-latch. Extract F34's once-per-second sample/compose throttle into a shared helper both draw paths call (DRY).

**Files:**
- Modify: `assets/gt-input-remap.c` — interposer half only (extract `gt_hud_refresh`; add `gt_sw_dead`, the SDL_Render resolver, `gt_hud_draw_sw`, and the `SDL_RenderPresent` interposer).

**Acceptance Criteria:**
- [ ] The throttle block in `gt_hud_draw` (sample+compose at most 1×/sec, set `gt_tex_dirty`) is extracted verbatim into `static void gt_hud_refresh(void)` placed after the cache statics and before `gt_hud_draw`; `gt_hud_draw` now calls `gt_hud_refresh();` in its place (behaviour identical).
- [ ] `SDL_RenderPresent(SDL_Renderer *)` is interposed, resolves the real symbol via `dlsym(RTLD_NEXT, …)`, and calls it every frame; the HUD is drawn immediately before it when `gt_hud_visible`.
- [ ] The SDL_Render entry points are resolved once via `dlsym(RTLD_NEXT, …)`; any missing symbol, or any texture-create failure, latches an independent `gt_sw_dead` and the port still presents normally.
- [ ] The HUD texture is a `SDL_PIXELFORMAT_ABGR8888` streaming texture created on the passed renderer (recreated if the renderer or panel size changes), blended `SDL_BLENDMODE_BLEND`, uploaded only when the composed buffer changed, and copied to the top-right via `gt_hud_rect` over `SDL_GetRendererOutputSize`.
- [ ] `make shim` builds cleanly; `sh tests/test-05-input-remap.sh` still passes.

**Verify:** `make shim && sh tests/test-05-input-remap.sh` → build lists `assets/gt-input-remap.so`; test exits 0. (Behavioural proof is the Task 5 device gate.)

**Steps:**

- [ ] **Step 1: Extract the throttle into `gt_hud_refresh`.** After the cache statics (`gt_tex_dirty` at line ~1389) and before `gt_hud_draw` (line ~1402), add the helper; then delete the identical block from `gt_hud_draw` and call the helper instead. New helper:

```c
/* Sample the four metrics + recompose the RGBA panel at most once per second,
 * marking gt_tex_dirty on change. Shared by the GL (gt_hud_draw) and software
 * (gt_hud_draw_sw) paths — a port uses exactly one, so gt_tex_dirty has a
 * single consumer per process. */
static void gt_hud_refresh(void) {
    time_t now = time(NULL);
    if (!gt_have_sample || now != gt_last_sample) {
        gt_last_sample = now;
        gt_have_sample = 1;
        gt_hud_sample(&gt_cache);
        gt_hud_compose(&gt_cache, gt_rgba, &gt_tex_w, &gt_tex_h);
        gt_tex_dirty = 1;
        if (gt_hud_debug())
            fprintf(stderr, "gt-hud: sample bat=%d%c time=%02d:%02d vol=%d bri=%d\n",
                    gt_cache.battery_pct, gt_cache.charging ? '+' : ' ',
                    gt_cache.hour, gt_cache.minute, gt_cache.volume, gt_cache.brightness);
    }
}
```

  In `gt_hud_draw`, replace the block currently at lines ~1407–1419 (the `/* CPU sample + recompose at most once per second. */` comment through the closing brace of the `if (!gt_have_sample …)`) with a single call:

```c
    /* CPU sample + recompose at most once per second (shared with the SW path). */
    gt_hud_refresh();
```

- [ ] **Step 2: Add the software draw state + resolver.** Place this in the interposer half, after `gt_hud_draw`'s definition and before the swap interposers (near line ~1546). `SDL_Renderer`, `SDL_Texture`, `SDL_Rect`, and the format/access/blend enums all come from the already-included `<SDL2/SDL.h>`.

```c
/* ======================================================================
 * F35: software-renderer HUD draw backend (device-only).
 *
 * SDL_Renderer ports (e.g. Apotris) present via SDL_RenderPresent, not a GL
 * swap. We interpose it, upload the same CPU-composed RGBA (gt_hud_refresh)
 * into one streaming texture on the port's own renderer, and RenderCopy it
 * top-right before the real present. Backend-agnostic (works whether the
 * renderer is software or GLES). Independent crash-latch gt_sw_dead. */
static int gt_sw_dead;   /* latched: any resolve/texture failure */

static SDL_Texture *(*p_SDL_CreateTexture)(SDL_Renderer*, Uint32, int, int, int);
static void         (*p_SDL_DestroyTexture)(SDL_Texture*);
static int          (*p_SDL_UpdateTexture)(SDL_Texture*, const SDL_Rect*, const void*, int);
static int          (*p_SDL_RenderCopy)(SDL_Renderer*, SDL_Texture*, const SDL_Rect*, const SDL_Rect*);
static int          (*p_SDL_SetTextureBlendMode)(SDL_Texture*, SDL_BlendMode);
static int          (*p_SDL_GetRendererOutputSize)(SDL_Renderer*, int*, int*);

static int gt_sw_resolve(void) {
    static int done;
    if (done) return !gt_sw_dead;
    done = 1;
    p_SDL_CreateTexture        = (SDL_Texture *(*)(SDL_Renderer*,Uint32,int,int,int))dlsym(RTLD_NEXT, "SDL_CreateTexture");
    p_SDL_DestroyTexture       = (void (*)(SDL_Texture*))dlsym(RTLD_NEXT, "SDL_DestroyTexture");
    p_SDL_UpdateTexture        = (int (*)(SDL_Texture*,const SDL_Rect*,const void*,int))dlsym(RTLD_NEXT, "SDL_UpdateTexture");
    p_SDL_RenderCopy           = (int (*)(SDL_Renderer*,SDL_Texture*,const SDL_Rect*,const SDL_Rect*))dlsym(RTLD_NEXT, "SDL_RenderCopy");
    p_SDL_SetTextureBlendMode  = (int (*)(SDL_Texture*,SDL_BlendMode))dlsym(RTLD_NEXT, "SDL_SetTextureBlendMode");
    p_SDL_GetRendererOutputSize= (int (*)(SDL_Renderer*,int*,int*))dlsym(RTLD_NEXT, "SDL_GetRendererOutputSize");
    if (!p_SDL_CreateTexture || !p_SDL_DestroyTexture || !p_SDL_UpdateTexture ||
        !p_SDL_RenderCopy || !p_SDL_SetTextureBlendMode || !p_SDL_GetRendererOutputSize) {
        gt_sw_dead = 1;
        if (gt_hud_debug()) fprintf(stderr, "gt-hud: SDL_Render symbol(s) missing -> SW HUD disabled\n");
        return 0;
    }
    return 1;
}
```

- [ ] **Step 3: Implement `gt_hud_draw_sw`.**

```c
static void gt_hud_draw_sw(SDL_Renderer *r) {
    if (gt_sw_dead || !gt_hud_visible || !r) return;
    if (!gt_sw_resolve()) return;

    gt_hud_refresh();   /* updates gt_rgba, gt_tex_w/h, gt_tex_dirty */

    static SDL_Texture *tex;
    static SDL_Renderer *tex_r;
    static int tex_w, tex_h;
    if (!tex || tex_r != r || tex_w != gt_tex_w || tex_h != gt_tex_h) {
        if (tex) { p_SDL_DestroyTexture(tex); tex = NULL; }
        tex = p_SDL_CreateTexture(r, SDL_PIXELFORMAT_ABGR8888,
                                  SDL_TEXTUREACCESS_STREAMING, gt_tex_w, gt_tex_h);
        if (!tex) { gt_sw_dead = 1;
            if (gt_hud_debug()) fprintf(stderr, "gt-hud: SDL_CreateTexture failed -> SW HUD disabled\n");
            return; }
        p_SDL_SetTextureBlendMode(tex, SDL_BLENDMODE_BLEND);
        tex_r = r; tex_w = gt_tex_w; tex_h = gt_tex_h;
        gt_tex_dirty = 1;   /* fresh texture needs an upload */
    }
    if (gt_tex_dirty) {
        p_SDL_UpdateTexture(tex, NULL, gt_rgba, gt_tex_w * 4);
        gt_tex_dirty = 0;
    }

    int ow = 0, oh = 0;
    if (p_SDL_GetRendererOutputSize(r, &ow, &oh) != 0 || ow <= 0 || oh <= 0) return;
    int px = 0, py = 0;
    gt_hud_rect(ow, oh, gt_tex_w, gt_tex_h, &px, &py);
    SDL_Rect dst = { px, py, gt_tex_w, gt_tex_h };
    p_SDL_RenderCopy(r, tex, NULL, &dst);
}
```

- [ ] **Step 4: Interpose `SDL_RenderPresent`.** Add near the swap interposers (after `gt_hud_draw_sw`):

```c
void SDL_RenderPresent(SDL_Renderer *r) {
    static void (*real)(SDL_Renderer*);
    if (!real) real = (void (*)(SDL_Renderer*))dlsym(RTLD_NEXT, "SDL_RenderPresent");
    if (gt_hud_debug()) { static int once; if (!once) { once = 1;
        fprintf(stderr, "gt-hud: present path = SDL_RenderPresent\n"); } }
    gt_hud_draw_sw(r);
    if (real) real(r);
}
```

- [ ] **Step 5: Build the shim + run the host test.**

Run: `make shim && sh tests/test-05-input-remap.sh`
Expected: `make shim` builds and lists `assets/gt-input-remap.so` (+ `gt-fmod-audio.so`); host test exits 0.
Note: `make shim` needs network for the container apt step — run with the sandbox disabled (`dangerouslyDisableSandbox: true`).

- [ ] **Step 6: Commit.**

```bash
git add assets/gt-input-remap.c
git commit -m "feat(F35): software-renderer HUD draw via SDL_RenderPresent interpose"
```

```json:metadata
{"files": ["assets/gt-input-remap.c"], "verifyCommand": "make shim && sh tests/test-05-input-remap.sh", "acceptanceCriteria": ["throttle extracted into gt_hud_refresh; gt_hud_draw calls it (behaviour identical)", "SDL_RenderPresent interposed via RTLD_NEXT, draws before the real present when visible", "gt_sw_dead latches on missing symbol or texture-create failure; port still presents", "ABGR8888 streaming texture on the passed renderer, recreated on renderer/size change, blended, uploaded only when changed, copied top-right via gt_hud_rect + SDL_GetRendererOutputSize", "make shim builds; host test passes"], "modelTier": "frontier"}
```

---

### Task 3: Universal evdev toggle thread + swallow-only SDL path + Makefile `-pthread`

**Goal:** Add a detached background thread that reads the Menu button directly from evdev (discovered by capability) and is the sole HUD toggle authority across all engines; strip the toggle call out of the SDL interposers (leaving swallow intact, Decision A); add `-pthread` to the shim build.

**Files:**
- Modify: `assets/gt-input-remap.c` — interposer half (new includes, device discovery, thread, constructor start; edit `gt_hud_intercept` to swallow-only).
- Modify: `Makefile` — `shim` target: add `-pthread` to the `gt-input-remap.so` compile/link.

**Acceptance Criteria:**
- [ ] `gt_hud_intercept` no longer calls `gt_menu_toggle`; it still returns `gt_menu_swallow(b)` (raw 11/14 swallowed) and keeps its debug logging. `gt_tap` is now touched only by the evdev thread.
- [ ] A capability-based device discovery opens the `/dev/input/event*` whose `EV_KEY` bitmap has BOTH `GT_EVCODE_MENU` (312) and `GT_EVCODE_MENU_ALT` (354); returns `-1` (benign) if none.
- [ ] A detached pthread, started from the constructor when `gt_hud_on()`, reads `struct input_event`s and drives `gt_menu_toggle(&gt_tap, &gt_hud_visible, …)` — MENU (312)→`is_menu=1`, VOL (114/115)→`is_menu=0`, everything else skipped; `value==2` (autorepeat) skipped. Any read/open error exits the thread quietly (no crash, no toggle).
- [ ] The thread never `EVIOCGRAB`s the device (game/keymon keep receiving Menu).
- [ ] `make shim` links with `-pthread` and builds cleanly; `sh tests/test-05-input-remap.sh` still passes (thread code is in the `#else` interposer half, not compiled into the host test).

**Verify:** `make shim && sh tests/test-05-input-remap.sh` → build lists `assets/gt-input-remap.so`; test exits 0. (Behavioural proof is the Task 5 device gate.)

**Steps:**

- [ ] **Step 1: Add includes (interposer half).** With the other interposer-half includes (near line ~813, after `<EGL/egl.h>`), add:

```c
#include <pthread.h>       /* F35: evdev toggle thread */
#include <dirent.h>        /* scan /dev/input for the Menu device */
#include <sys/ioctl.h>     /* EVIOCGBIT / EVIOCGNAME */
#include <linux/input.h>   /* struct input_event, EV_KEY, KEY_MAX */
#include <string.h>        /* strncmp, memset */
#include <errno.h>         /* EINTR */
```

- [ ] **Step 2: Make `gt_hud_intercept` swallow-only (Decision A).** In `gt_hud_intercept` (line ~1025) delete the `gt_menu_toggle` call. Replace the block at lines ~1031–1035:

```c
    /* Raw 11 drives the toggle; other jbuttons feed the Vol-during-hold
     * disqualification; raw 14 (KEY_GOTO) must NOT reach the tap machine. The
     * swallow decision is gt_menu_swallow(b) in every case (raw 11 + raw 14). */
    if (b != 14)
        gt_menu_toggle(&gt_tap, &gt_hud_visible, gt_is_menu_button(b), is_down);
    int swallow = gt_menu_swallow(b);
```

  with:

```c
    /* F35 (Decision A): the SDL path only SWALLOWS the Menu edges from the game;
     * the toggle authority moved to the evdev thread (gt_evdev_thread), which is
     * the one source every engine shares (mono/gptokeyb ports never reach this
     * SDL hook at all). raw 11 + raw 14 are swallowed as before. */
    int swallow = gt_menu_swallow(b);
    (void)is_down;
```

  Leave the two `gt_hud_debug()` trace lines below it as-is (they read `gt_hud_visible` and `gt_is_menu_button(b)`, both still valid).

- [ ] **Step 3: Device discovery + thread (interposer half).** Add before the constructor `gt_init` (so it's in scope there), e.g. just after `gt_hud_debug()` / the `gt_hud_visible` decl block (~line 841). `gt_tap` is defined lower at line ~1024; forward-declare it here or move its definition up — move `static gt_tap_state gt_tap;` to just above this block and delete the later definition to avoid a duplicate.

```c
/* F35: universal evdev toggle. A detached thread reads the Menu button from
 * /dev/input/event* — BELOW mono P/Invoke, gptokeyb, and SDL — so the toggle
 * works on every engine (Celeste/mono and Apotris/gptokeyb included, where no
 * SDL interposer ever fires). Non-grabbing, so keymon + the game keep the
 * button. gt_tap is owned solely by this thread (the SDL path no longer
 * toggles — Decision A). */
static gt_tap_state gt_tap;

#define GT_EVBIT_TEST(arr, b) (((arr)[(b) / 8] >> ((b) % 8)) & 1u)

/* Open the input device that exposes BOTH BTN_TL2 (312) and KEY_GOTO (354) —
 * the Menu button's two codes. Capability match, not a hardcoded index, so the
 * shim survives node renumbering / other h700 units. Returns fd or -1. */
static int gt_open_menu_device(void) {
    DIR *d = opendir("/dev/input");
    if (!d) return -1;
    struct dirent *e;
    int fd = -1;
    while ((e = readdir(d))) {
        if (strncmp(e->d_name, "event", 5) != 0) continue;
        char path[64];
        snprintf(path, sizeof path, "/dev/input/%s", e->d_name);
        int f = open(path, O_RDONLY | O_CLOEXEC);
        if (f < 0) continue;
        unsigned char bits[(KEY_MAX / 8) + 1];
        memset(bits, 0, sizeof bits);
        if (ioctl(f, EVIOCGBIT(EV_KEY, sizeof bits), bits) >= 0 &&
            GT_EVBIT_TEST(bits, GT_EVCODE_MENU) && GT_EVBIT_TEST(bits, GT_EVCODE_MENU_ALT)) {
            if (gt_hud_debug()) {
                char name[128] = {0};
                if (ioctl(f, EVIOCGNAME(sizeof name - 1), name) < 0) name[0] = 0;
                fprintf(stderr, "gt-hud: evdev toggle device = %s (%s)\n", path, name);
            }
            fd = f;
            break;
        }
        close(f);
    }
    closedir(d);
    return fd;
}

static void *gt_evdev_thread(void *arg) {
    (void)arg;
    int fd = gt_open_menu_device();
    if (fd < 0) {
        if (gt_hud_debug()) fprintf(stderr, "gt-hud: no evdev Menu device -> toggle disabled\n");
        return NULL;
    }
    for (;;) {
        struct input_event ev;
        ssize_t n = read(fd, &ev, sizeof ev);
        if (n != (ssize_t)sizeof ev) {
            if (n < 0 && errno == EINTR) continue;
            break;   /* device gone / error -> exit thread (benign) */
        }
        if (ev.type != EV_KEY || ev.value == 2) continue;   /* skip autorepeat */
        int down = (ev.value == 1);
        int cls  = gt_evkey_class(ev.code);
        if (cls == GT_EVK_MENU)
            gt_menu_toggle(&gt_tap, &gt_hud_visible, 1, down);
        else if (cls == GT_EVK_VOL)
            gt_menu_toggle(&gt_tap, &gt_hud_visible, 0, down);
        else
            continue;
        if (gt_hud_debug() && cls == GT_EVK_MENU && !down)
            fprintf(stderr, "gt-input-remap: HUD toggle -> %s\n", gt_hud_visible ? "on" : "off");
    }
    close(fd);
    return NULL;
}
```

  Then delete the now-duplicate `static gt_tap_state gt_tap;` at its old location (~line 1024).

- [ ] **Step 4: Start the thread from the constructor.** In `gt_init` (line ~865), inside the existing `if (gt_hud_on())` path, start the detached thread. Change:

```c
    fprintf(stderr, "gt-input-remap: loaded\n");
    if (gt_hud_on())
        fprintf(stderr, "gt-input-remap: HUD enabled\n");
```

  to:

```c
    fprintf(stderr, "gt-input-remap: loaded\n");
    if (gt_hud_on()) {
        fprintf(stderr, "gt-input-remap: HUD enabled\n");
        pthread_t t;
        if (pthread_create(&t, NULL, gt_evdev_thread, NULL) == 0)
            pthread_detach(t);
        else if (gt_hud_debug())
            fprintf(stderr, "gt-hud: evdev thread start failed -> toggle disabled\n");
    }
```

- [ ] **Step 5: Add `-pthread` to the Makefile shim target.** In `Makefile`, the `gt-input-remap.so` gcc line (line ~17) currently ends `-ldl && strip …`. Change that one command to add `-pthread`:

```make
	   gcc -O2 -Wall -shared -fPIC -o gt-input-remap.so gt-input-remap.c -ldl -pthread && strip gt-input-remap.so && \
```

  Leave the `gt-fmod-audio.so` line unchanged.

- [ ] **Step 6: Build the shim + run the host test.**

Run: `make shim && sh tests/test-05-input-remap.sh`
Expected: builds and lists `assets/gt-input-remap.so`; host test exits 0.
(Run `make shim` with the sandbox disabled — it needs network for apt.)

- [ ] **Step 7: Commit.**

```bash
git add assets/gt-input-remap.c Makefile
git commit -m "feat(F35): universal evdev toggle thread; SDL path swallow-only (Decision A)"
```

```json:metadata
{"files": ["assets/gt-input-remap.c", "Makefile"], "verifyCommand": "make shim && sh tests/test-05-input-remap.sh", "acceptanceCriteria": ["gt_hud_intercept no longer toggles; still swallows raw 11/14; gt_tap owned only by the thread", "capability-based discovery opens the event* with BTN_TL2+KEY_GOTO; -1 if none", "detached constructor-started thread drives gt_menu_toggle: MENU->is_menu=1, VOL->is_menu=0, else skip; value==2 skipped; errors exit quietly", "no EVIOCGRAB", "make shim links -pthread and builds; host test passes"], "modelTier": "frontier"}
```

---

### Task 4: Docs — F35 section + 0.3.0 release-notes stub

**Goal:** Document F35 in `docs/h700-fixes.md` (software draw + universal evdev toggle, the device-spike grounding, Decision A), bump the fix range to F1–F35, mark the F34 Stage-1 limitations resolved, add a terse 0.3.0 release-notes stub, and remove any delivered items from the ideas file.

**Files:**
- Modify: `docs/h700-fixes.md` — add the F35 section; bump the `F1–F34` range line to `F1–F35`; update the F34 "Known limitations (Stage 1)" to point to F35.
- Modify: `docs/superpowers/ideas.md` — delete any now-delivered software-renderer / FNA-toggle idea entries, if present (per the "update ideas file on phase finish" convention). Skip if the file has no such entry.

**Acceptance Criteria:**
- [ ] A new `## …(F35)` section describes: the `SDL_RenderPresent` software draw path (Apotris); the universal evdev toggle thread (device-discovered by BTN_TL2+KEY_GOTO capability, engine-agnostic); Decision A (SDL path swallow-only); the mono-P/Invoke-bypass finding that killed the "interpose SDL_PumpEvents" idea; and that this clears the two F34 Stage-1 limitations.
- [ ] The `F1–F34` range line is bumped to `F1–F35`.
- [ ] The F34 "Known limitations (Stage 1)" text is updated to say F35 resolves both (software draw + FNA/mono toggle).
- [ ] A terse `0.3.0` release-notes stub exists (Fixes: F33 startup trims, F34 in-game HUD, F35 software-renderer + universal toggle; Upgrading from v0.2.3 = unzip-over), matching the pak's terse release-notes style.

**Verify:** `grep -n 'F35' docs/h700-fixes.md` → shows the new section + the bumped range line.

**Steps:**

- [ ] **Step 1: Read the current F34 section + range line.** Open `docs/h700-fixes.md`; find the `F1–F34` range line (near the top, ~line 11) and the F34 section (`## In-game status overlay (F34)`, ~line 636) with its "Known limitations (Stage 1)" block (~line 692).

- [ ] **Step 2: Bump the range line** from `F1–F34` to `F1–F35`.

- [ ] **Step 3: Update the F34 Stage-1 limitations block** so both bullets note they are resolved in F35 — append to each bullet a sentence like: "*(Resolved in F35 — see below.)*" Keep the historical description intact.

- [ ] **Step 4: Add the F35 section** after the F34 section (before the "hardware overlay layer" spike-verdict paragraph if that reads as a shared tail, otherwise directly after F34). Write it in the established terse, factual style. It MUST cover, in prose:
  - **Software draw:** interpose `SDL_RenderPresent`; upload the same composed RGBA into one `ABGR8888` streaming texture on the port's renderer and `SDL_RenderCopy` it top-right before the real present; backend-agnostic; covers Apotris and any 2D-renderer port; independent `gt_sw_dead` crash-latch. Celeste needs nothing here — its `libFNA3D`→`SDL_GL_SwapWindow` path already draws through F34's GL hook.
  - **Universal evdev toggle:** a detached shim thread reads the Menu button (`BTN_TL2` 312 + `KEY_GOTO` 354, device-discovered by capability, Vol 114/115 for the keymon-combo disqualification) straight from `/dev/input/event*`, below mono/gptokeyb/SDL, and is the sole toggle authority for every engine. Non-grabbing, so keymon + the game keep the button.
  - **Decision A:** the F34 SDL interposers keep swallowing the Menu edges from GL ports but no longer toggle — non-regressive; mono/gptokeyb ports never reached that hook anyway.
  - **Why not `SDL_PumpEvents`:** the 2026-08-26 device spike found Celeste pumps input in managed C# via mono `[DllImport]` P/Invoke, which resolves SDL by explicit `dlopen` handle and bypasses LD_PRELOAD entirely — so no SDL input hook could ever fire for it; the evdev layer is the only universal one.
  - **Device-gate results (2026-08-26):** leave a one-line placeholder to be filled from the Task 5 gate (Apotris software HUD + toggle; Celeste GL HUD + evdev toggle; GL-port regression; keymon combo intact).

- [ ] **Step 5: Add the 0.3.0 release-notes stub.** Where F34 left its `0.3.0`/"Targeted for 0.3.0" note, replace/extend it with a terse stub:

```markdown
### 0.3.0 (targeted)

**Fixes**
- F33: faster port startup (splash + redundant-patch trims)
- F34: in-game status overlay (battery/brightness/volume/time), GL/EGL engines
- F35: overlay on software-renderer ports + universal Menu toggle (all engines)

**Upgrading from v0.2.3:** unzip-over (self-healing); no manual steps.
```

- [ ] **Step 6: Trim the ideas file.** Open `docs/superpowers/ideas.md`; if it lists the software-renderer draw and/or FNA/mono toggle as future ideas, delete those entries (they ship in F35). If no such entry exists, make no change.

- [ ] **Step 7: Commit.**

```bash
git add docs/h700-fixes.md docs/superpowers/ideas.md
git commit -m "docs(F35): software-renderer draw + universal evdev toggle; 0.3.0 notes stub"
```

```json:metadata
{"files": ["docs/h700-fixes.md", "docs/superpowers/ideas.md"], "verifyCommand": "grep -n 'F35' docs/h700-fixes.md", "acceptanceCriteria": ["F35 section covers software draw, universal evdev toggle, Decision A, the mono-P/Invoke-bypass finding, and clearing the F34 Stage-1 limitations", "F1-F34 range line bumped to F1-F35", "F34 Stage-1 limitations marked resolved in F35", "terse 0.3.0 release-notes stub (F33+F34+F35, upgrade = unzip-over)"], "modelTier": "mechanical"}
```

---

### Task 5: Device gate — per-engine verification on the RG SP

**Goal:** Prove on-device that the software-renderer HUD and the universal evdev toggle work across every engine, and that nothing F34 verified regressed.

**USER-ORDERED GATE — NON-SKIPPABLE.** This task was requested by the user in the current conversation. It MUST NOT be closed by walking around it, by declaring it "verified inline", or by substituting a cheaper check. Close only after every item in `acceptanceCriteria` has been re-validated independently, with output captured.

**Files:** None (verification). May yield a one-line `GT_EVCODE_*` correction in `assets/gt-input-remap.c` and/or a fill-in of the Task 4 device-gate placeholder.

**Acceptance Criteria:**
- [ ] **Apotris (software path):** HUD appears; a single Menu tap toggles it on/off; battery/brightness/volume/time are live and correct; toggle-off leaves rendering pristine; no crash. `GT_HUD_DEBUG` shows `present path = SDL_RenderPresent`.
- [ ] **Celeste (GL draw + evdev toggle):** HUD appears (first visual confirmation of the FNA3D GL draw) AND a single Menu tap toggles it; no crash. This proves the evdev thread is the working toggle under mono.
- [ ] **Regression across F34 GL ports** (at least Balatro, BYTEPATH, a GameMaker title, Tunics!, 2048 Plus): each still toggles (now via the evdev thread), Menu is still swallowed from the game, and F25/F26/F31 input-remap + gptk-keyboard behaviour is intact.
- [ ] **keymon combo:** Menu+Vol-up/down brightness still works during a port; a Menu-held+Vol sequence does NOT spuriously toggle the HUD (the Vol-during-hold disqualification holds at the evdev layer).
- [ ] **`GT_HUD_DEBUG` trace** captured for one software port and one GL port, showing the evdev toggle device discovery + the present/swap path.

**Verify:** device session on `ssh root@10.0.1.16`: build (`make shim`), install the shim via scp-to-temp+`mv` (keep a `.pre-f35.bak`), launch each engine's port, toggle the HUD, and capture `GT_HUD_DEBUG` output + Camille's visual confirmation per item. Software-path evidence must come from an actual Apotris run (`SDL_RenderPresent` present-path log + visible HUD); GL/toggle evidence from an actual Celeste run (`SDL_GL_SwapWindow` swap-path log + HUD toggling under mono).

**Steps:**

- [ ] **Step 1: Build + stage the shim.** `make shim` (sandbox disabled). `scp assets/gt-input-remap.so root@10.0.1.16:/tmp/gt-input-remap.so.new`.

- [ ] **Step 2: Install safely (never overwrite in place).** On device: `cp -p /mnt/SDCARD/Emus/h700/PORTS.pak/lib/gt-input-remap.so /mnt/SDCARD/Emus/h700/PORTS.pak/lib/gt-input-remap.so.pre-f35.bak` then `mv /tmp/gt-input-remap.so.new /mnt/SDCARD/Emus/h700/PORTS.pak/lib/gt-input-remap.so`.

- [ ] **Step 3: Enable debug for the gate.** Temporarily add `export GT_HUD_DEBUG=1` to the port env in `/mnt/SDCARD/Emus/h700/PORTS.pak/launch.sh` (scp-temp+mv; keep a backup) so the per-port `log.txt` / pak log captures device discovery + present path. Revert after the gate.

- [ ] **Step 4: Apotris (software).** Launch; confirm HUD visible; Camille taps Menu → toggles; verify values; toggle-off pristine; check `log.txt` for `present path = SDL_RenderPresent` and the evdev toggle device line. Capture output.

- [ ] **Step 5: Celeste (GL + evdev).** Launch; confirm HUD visible (GL draw) AND Menu tap toggles under mono; check `log.txt` for `swap path = SDL_GL_SwapWindow` and the toggle device line; no crash. Capture output.

- [ ] **Step 6: GL-port regression + keymon combo.** Launch each of Balatro, BYTEPATH, a GameMaker title, Tunics!, 2048 Plus; confirm the Menu tap still toggles, Menu is still swallowed from the game, input/remap behaviour is intact. Then confirm Menu+Vol brightness still works and does not spuriously toggle the HUD.

- [ ] **Step 7: Revert the debug edit** to `launch.sh` (restore from backup); leave the new shim installed. Fill the Task 4 device-gate placeholder with the results, and correct any `GT_EVCODE_*` if the gate contradicts them (then re-run `sh tests/test-05-input-remap.sh`).

```json:metadata
{"files": ["assets/gt-input-remap.c"], "verifyCommand": "ssh root@10.0.1.16 (device gate — see steps)", "acceptanceCriteria": ["Apotris: software-path HUD appears, Menu tap toggles, live values, toggle-off pristine, no crash, present path = SDL_RenderPresent", "Celeste: GL HUD appears AND Menu tap toggles under mono, no crash", "F34 GL ports (Balatro/BYTEPATH/GameMaker/Tunics!/2048) still toggle + swallow + input intact", "keymon Menu+Vol brightness works and does not spuriously toggle", "GT_HUD_DEBUG trace captured for a software and a GL port"], "userGate": true, "tags": ["user-gate"], "requiresUserSpecification": false, "gateScope": "one-then-all", "requireEvidenceTokens": [["Apotris", "software", "SDL_RenderPresent"], ["Celeste", "evdev", "SDL_GL_SwapWindow"]], "modelTier": "standard"}
```
