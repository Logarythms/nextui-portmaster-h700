/* gt-input-remap.so — an optional LD_PRELOAD shim for the PortMaster GUI
 * (pugwash) on the RG SP (h700). It corrects the h700's SDL joystick button
 * index shift, and is preloaded only when the user opts in by touching the
 * `use-remap` marker file (see the gt-h700-remap-hook logic in
 * build/build-pak.sh); otherwise it is not loaded and the GUI is unaffected.
 *
 * The stock tg5040 PortMaster binaries map raw SDL joystick button indices
 * against a compile-time TrimUI table (A=1 B=0 Y=2 X=3 L1=4 R1=5 SELECT=6
 * START=7 MENU=8 L2=10 R2=11). NextUI's h700 SDL2 enumerates evdev keycodes
 * in plain ascending order, so on the RG SP the low keycodes come first
 * (ESC=b0, VolDown=b1, VolUp=b2) and every gamepad button lands +3 off the
 * TrimUI layout those binaries expect. Indices below were MEASURED live on
 * the device via this shim's own jbtn trace during a scripted press sequence
 * (2026-08-19) — a vanilla-SDL derivation from evtest keycodes gave a
 * different, wrong table.
 *
 * The shim rewrites jbutton indices in the SDL event stream:
 *   A 3→1, B 4→0, Y 5→2, X 6→3, L1 7→4, R1 8→5,
 *   Select 9→6, Start 10→7, Menu 11→8, L2 12→10, R2 13→11;
 *   parked on the unmapped index 15: 0-2 (ESC/volume — would otherwise act
 *   as B/A/Y) and 14 (Menu's second emission, KEY_GOTO — would otherwise
 *   double-fire). Identity elsewhere. The d-pad rides SDL hat events and
 *   needs no remap. Unconditional for all joysticks: the RG SP is a
 *   clamshell with no external pad expected; revisit if one is attached.
 *
 * Both SDL_PollEvent and SDL_WaitEventTimeout are interposed (pugwash pumps
 * through both). SDL_WaitEventTimeout may internally route through
 * SDL_PollEvent via the PLT — in that case one event would pass through the
 * shim twice, and the 0↔1 swap would undo itself. A marker in the event's
 * padding byte (always zero from SDL) makes the rewrite once-only.
 *
 * GT_INPUT_REMAP_DEBUG=1 traces every rewrite to stderr (which launch.sh
 * redirects into the pak log) — used for the hands-on hardware gate.
 *
 * Built via `make shim` (a linux/arm64 Debian container); never compiled
 * for the host except with -DGT_REMAP_TEST, which strips the interposer
 * half and exposes a main() asserting the table (exercised by test-05).
 */

static unsigned char gt_remap(unsigned char b) {
    switch (b) {
        case 0:  return 15;  /* ESC — park (would act as B) */
        case 1:  return 15;  /* VolDown — park (would act as A) */
        case 2:  return 15;  /* VolUp — park (would act as Y) */
        case 3:  return 1;   /* A */
        case 4:  return 0;   /* B */
        case 5:  return 2;   /* Y */
        case 6:  return 3;   /* X */
        case 7:  return 4;   /* L1 */
        case 8:  return 5;   /* R1 */
        case 9:  return 6;   /* Select */
        case 10: return 7;   /* Start */
        case 11: return 8;   /* Menu (TL2 half) */
        case 12: return 10;  /* L2 */
        case 13: return 11;  /* R2 */
        case 14: return 15;  /* Menu's KEY_GOTO half — park (double-fire) */
        default: return b;
    }
}

#ifdef GT_REMAP_TEST

#include <stdio.h>

int main(void) {
    static const struct { unsigned char in, out; } cases[] = {
        /* gamepad buttons: measured device index → TrimUI-table index */
        {3, 1}, {4, 0}, {5, 2}, {6, 3}, {7, 4}, {8, 5},
        {9, 6}, {10, 7}, {11, 8}, {12, 10}, {13, 11},
        /* parked: ESC/volume (0-2) and Menu's KEY_GOTO half (14) */
        {0, 15}, {1, 15}, {2, 15}, {14, 15},
        /* beyond the device's range: identity */
        {15, 15}, {16, 16},
    };
    unsigned i;
    for (i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
        if (gt_remap(cases[i].in) != cases[i].out) {
            fprintf(stderr, "remap(%u) = %u, want %u\n",
                    cases[i].in, gt_remap(cases[i].in), cases[i].out);
            return 1;
        }
    }
    puts("remap ok");
    return 0;
}

#else /* the real interposer */

#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <SDL2/SDL.h>

#define GT_REMAPPED_MARKER 0x5A

static int gt_debug(void) {
    static int v = -1;
    if (v < 0) {
        const char *e = getenv("GT_INPUT_REMAP_DEBUG");
        v = (e && *e) ? 1 : 0;
    }
    return v;
}

/* One unconditional line at load: launch.sh redirects stderr into the pak
 * log, so this is the cheap on-device proof that the preload took effect. */
__attribute__((constructor))
static void gt_init(void) {
    fprintf(stderr, "gt-input-remap: loaded\n");
}

/* Debug-only event trace, capped so an axis-jitter flood can't fill the
 * log: first 60 events of any type, then joystick buttons only. Buttons
 * print their raw (pre-remap) index — this is how the real SDL index table
 * was read off the device (NextUI's custom SDL2 assigns its own order; the
 * vanilla ascending-keycode derivation from evtest was wrong). */
static void gt_trace(const char *src, SDL_Event *ev) {
    static unsigned long n;
    if (!gt_debug() || !ev) return;
    if (ev->type == SDL_JOYBUTTONDOWN || ev->type == SDL_JOYBUTTONUP) {
        fprintf(stderr, "gt-input-remap: %s jbtn=%u (%s)\n", src,
                (unsigned)ev->jbutton.button,
                ev->type == SDL_JOYBUTTONDOWN ? "down" : "up");
    } else if (n < 60) {
        fprintf(stderr, "gt-input-remap: %s type=0x%x\n", src, (unsigned)ev->type);
        n++;
    }
}

static void gt_rewrite(SDL_Event *ev) {
    if (!ev) return;
    if (ev->type != SDL_JOYBUTTONDOWN && ev->type != SDL_JOYBUTTONUP) return;
    if (ev->jbutton.padding1 == GT_REMAPPED_MARKER) return; /* already done */
    unsigned char from = ev->jbutton.button;
    ev->jbutton.button = gt_remap(from);
    ev->jbutton.padding1 = GT_REMAPPED_MARKER;
    if (gt_debug() && from != ev->jbutton.button)
        fprintf(stderr, "gt-input-remap: jbutton %u -> %u (%s)\n",
                from, ev->jbutton.button,
                ev->type == SDL_JOYBUTTONDOWN ? "down" : "up");
}

int SDL_PollEvent(SDL_Event *ev) {
    static int (*real)(SDL_Event *);
    if (!real) real = (int (*)(SDL_Event *))dlsym(RTLD_NEXT, "SDL_PollEvent");
    int r = real(ev);
    if (r == 1) { gt_trace("poll", ev); gt_rewrite(ev); }
    return r;
}

int SDL_WaitEventTimeout(SDL_Event *ev, int timeout) {
    static int (*real)(SDL_Event *, int);
    if (!real) real = (int (*)(SDL_Event *, int))dlsym(RTLD_NEXT, "SDL_WaitEventTimeout");
    int r = real(ev, timeout);
    if (r == 1) { gt_trace("wait", ev); gt_rewrite(ev); }
    return r;
}

#endif /* GT_REMAP_TEST */
