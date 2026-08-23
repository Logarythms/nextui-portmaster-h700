/* gt-input-remap.so — an optional LD_PRELOAD shim for PortMaster processes
 * on the RG SP (h700). Two halves:
 *
 * v1 — joystick index remap (shipped v0.1.0). The stock tg5040 PortMaster
 * binaries map raw SDL joystick button indices against a compile-time TrimUI
 * table (A=1 B=0 Y=2 X=3 L1=4 R1=5 SELECT=6 START=7 MENU=8 L2=10 R2=11).
 * NextUI's h700 SDL2 enumerates evdev keycodes in plain ascending order, so
 * on the RG SP the low keycodes come first (ESC=b0, VolDown=b1, VolUp=b2)
 * and every gamepad button lands +3 off the TrimUI layout those binaries
 * expect. Indices below were MEASURED live on the device via this shim's own
 * jbtn trace during a scripted press sequence (2026-08-19) — a vanilla-SDL
 * derivation from evtest keycodes gave a different, wrong table.
 *
 *   A 3→1, B 4→0, Y 5→2, X 6→3, L1 7→4, R1 8→5,
 *   Select 9→6, Start 10→7, Menu 11→8, L2 12→10, R2 13→11;
 *   parked on the unmapped index 15: 0-2 (ESC/volume — would otherwise act
 *   as B/A/Y) and 14 (Menu's second emission, KEY_GOTO — would otherwise
 *   double-fire). Identity elsewhere. The d-pad rides SDL hat events and
 *   needs no index remap. Unconditional for all joysticks: the RG SP is a
 *   clamshell with no external pad expected; revisit if one is attached.
 *
 * v2 — keyboard-event synthesis (F26, 2026-08-23). NextUI's SDL never
 * delivers gptokeyb's uinput "Fake Keyboard" to SDL apps, so every port
 * whose game reads keyboard input (the whole gptokeyb tier) is input-dead
 * on this device even though gptokeyb itself runs fine. When the launcher
 * exports GT_REMAP_GPTK=<path to the port's .gptk file>, this shim does
 * gptokeyb's job at the SDL layer instead: joystick button events whose
 * (post-v1-remap) button carries a .gptk key mapping are REPLACED in the
 * event stream by the corresponding SDL_KEYDOWN/SDL_KEYUP, and hat motions
 * become the mapped direction keys (edge-tracked, releases before presses;
 * a single hat transition can yield up to four key events — the first
 * replaces the hat event, the rest are served from a small internal stash
 * on subsequent polls). Buttons with no mapping keep their (remapped)
 * joystick events, so hybrid ports lose nothing. Only the simple
 * `name = key` subset of the gptk format is honored (letters, digits,
 * space/esc/tab/enter/backspace/shift/ctrl/alt, arrows); everything else —
 * analog lines (the RG SP has no sticks), deadzone config, gptokeyb's \"
 * placeholder, hold_state modifiers — is deliberately ignored. gptokeyb
 * keeps running untouched alongside: its synthetic keyboard is inert here,
 * but its Select+Start kill hotkey works off direct pad reads and stays
 * the quit path.
 *
 * Both SDL_PollEvent and SDL_WaitEventTimeout are interposed (apps pump
 * through both). SDL_WaitEventTimeout may internally route through
 * SDL_PollEvent via the PLT — in that case one event would pass through the
 * shim twice, and the v1 0↔1 swap would undo itself. A marker in the
 * event's padding byte (always zero from SDL) makes the jbutton rewrite
 * once-only; v2 replacements are naturally idempotent (a key event is never
 * rewritten, and a hat re-pass sees prev==cur and yields no edges).
 *
 * GT_INPUT_REMAP_DEBUG=1 traces every rewrite to stderr (which launch.sh
 * redirects into the pak log) — used for the hands-on hardware gate.
 *
 * Built via `make shim` (a linux/arm64 Debian container); never compiled
 * for the host except with -DGT_REMAP_TEST, which strips the interposer
 * half and exposes a main() asserting the pure logic (exercised by
 * test-05). Everything outside the #ifdef uses plain libc only, so the
 * table, the gptk parser, and the hat edge logic are host-testable.
 */

#define _GNU_SOURCE  /* must precede the first libc include: dlfcn.h's
                      * RTLD_NEXT (used by the interposer half) needs it */
#include <string.h>

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

/* ---- v2 shared logic (no SDL types; host-testable) -------------------- */

/* SDL keycode/scancode constants, hardcoded (SDL2 ABI-stable): printable
 * keys use their ASCII value as keycode; non-printables use
 * 0x40000000|scancode. */
#define GT_SCANCODE_MASK 0x40000000

typedef struct { int sym; int scancode; } gt_key;

static gt_key gt_keyname(const char *name) {
    gt_key k = {0, 0};
    if (!name || !*name) return k;
    if (!name[1]) { /* single character: letter or digit */
        char c = name[0];
        if (c >= 'A' && c <= 'Z') c = (char)(c - 'A' + 'a');
        if (c >= 'a' && c <= 'z') { k.sym = c; k.scancode = 4 + (c - 'a'); return k; }
        if (c >= '1' && c <= '9') { k.sym = c; k.scancode = 30 + (c - '1'); return k; }
        if (c == '0') { k.sym = c; k.scancode = 39; return k; }
        return k;
    }
    if (!strcmp(name, "space"))     { k.sym = ' ';  k.scancode = 44; return k; }
    if (!strcmp(name, "esc") ||
        !strcmp(name, "escape"))    { k.sym = 27;   k.scancode = 41; return k; }
    if (!strcmp(name, "tab"))       { k.sym = 9;    k.scancode = 43; return k; }
    if (!strcmp(name, "enter") ||
        !strcmp(name, "return"))    { k.sym = 13;   k.scancode = 40; return k; }
    if (!strcmp(name, "backspace")) { k.sym = 8;    k.scancode = 42; return k; }
    if (!strcmp(name, "up"))        { k.scancode = 82;  k.sym = GT_SCANCODE_MASK | 82;  return k; }
    if (!strcmp(name, "down"))      { k.scancode = 81;  k.sym = GT_SCANCODE_MASK | 81;  return k; }
    if (!strcmp(name, "left"))      { k.scancode = 80;  k.sym = GT_SCANCODE_MASK | 80;  return k; }
    if (!strcmp(name, "right"))     { k.scancode = 79;  k.sym = GT_SCANCODE_MASK | 79;  return k; }
    if (!strcmp(name, "shift") ||
        !strcmp(name, "left_shift") ||
        !strcmp(name, "lshift"))    { k.scancode = 225; k.sym = GT_SCANCODE_MASK | 225; return k; }
    if (!strcmp(name, "ctrl") ||
        !strcmp(name, "left_ctrl") ||
        !strcmp(name, "lctrl"))     { k.scancode = 224; k.sym = GT_SCANCODE_MASK | 224; return k; }
    if (!strcmp(name, "alt") ||
        !strcmp(name, "left_alt") ||
        !strcmp(name, "lalt"))      { k.scancode = 226; k.sym = GT_SCANCODE_MASK | 226; return k; }
    return k; /* unknown (incl. gptokeyb's \" placeholder): no mapping */
}

/* Post-v1-remap (TrimUI-layout) button index for each gptk button name. */
static int gt_button_slot(const char *name) {
    if (!strcmp(name, "b"))     return 0;
    if (!strcmp(name, "a"))     return 1;
    if (!strcmp(name, "y"))     return 2;
    if (!strcmp(name, "x"))     return 3;
    if (!strcmp(name, "l1"))    return 4;
    if (!strcmp(name, "r1"))    return 5;
    if (!strcmp(name, "back") ||
        !strcmp(name, "select")) return 6;
    if (!strcmp(name, "start")) return 7;
    if (!strcmp(name, "guide")) return 8;
    if (!strcmp(name, "l2"))    return 10;
    if (!strcmp(name, "r2"))    return 11;
    return -1;
}

/* hat direction slots: 0=up 1=down 2=left 3=right (SDL_HAT_* bit order is
 * UP=1 RIGHT=2 DOWN=4 LEFT=8 — mapped in gt_hat_bit_slot). */
static int gt_dir_slot(const char *name) {
    if (!strcmp(name, "up"))    return 0;
    if (!strcmp(name, "down"))  return 1;
    if (!strcmp(name, "left"))  return 2;
    if (!strcmp(name, "right")) return 3;
    return -1;
}

static int gt_hat_bit_slot(int bit) {
    switch (bit) {
        case 1: return 0; /* SDL_HAT_UP */
        case 4: return 1; /* SDL_HAT_DOWN */
        case 8: return 2; /* SDL_HAT_LEFT */
        case 2: return 3; /* SDL_HAT_RIGHT */
        default: return -1;
    }
}

typedef struct {
    gt_key button_key[16]; /* indexed by post-v1-remap button index */
    gt_key dir_key[4];     /* up/down/left/right */
    int loaded;            /* any mapping present */
} gt_keymap;

/* Parse one gptk line into the map. Returns 1 if the line mapped something,
 * 0 otherwise. Accepts the `name = value` subset; trims spaces/CR; ignores
 * comments, blanks, analog/deadzone/config lines, and unknown key names. */
static int gt_gptk_line(gt_keymap *m, const char *line) {
    char name[32], value[32];
    unsigned ni = 0, vi = 0;
    const char *p = line;
    while (*p == ' ' || *p == '\t') p++;
    if (!*p || *p == '#' || *p == '\n' || *p == '\r') return 0;
    while (*p && *p != ' ' && *p != '\t' && *p != '=' && ni < sizeof(name) - 1)
        name[ni++] = *p++;
    name[ni] = 0;
    while (*p == ' ' || *p == '\t') p++;
    if (*p != '=') return 0;
    p++;
    while (*p == ' ' || *p == '\t') p++;
    while (*p && *p != ' ' && *p != '\t' && *p != '\n' && *p != '\r' && vi < sizeof(value) - 1)
        value[vi++] = *p++;
    value[vi] = 0;
    if (!ni || !vi) return 0;

    gt_key k = gt_keyname(value);
    if (!k.sym) return 0;

    int slot = gt_button_slot(name);
    if (slot >= 0) { m->button_key[slot] = k; m->loaded = 1; return 1; }
    slot = gt_dir_slot(name);
    if (slot >= 0) { m->dir_key[slot] = k; m->loaded = 1; return 1; }
    return 0; /* analog/config/unknown names: ignored by design */
}

/* Hat edge computation: given previous and current hat bitmasks, list the
 * (slot, pressed) transitions — releases first, then presses, so a
 * diagonal flip never holds two opposite directions at once. Returns the
 * count (0..4). out_slot/out_pressed must hold 4 entries. */
static int gt_hat_edges(int prev, int cur, int *out_slot, int *out_pressed) {
    static const int bits[4] = {1, 2, 4, 8};
    int n = 0, i;
    for (i = 0; i < 4; i++) {
        if ((prev & bits[i]) && !(cur & bits[i])) {
            out_slot[n] = gt_hat_bit_slot(bits[i]); out_pressed[n] = 0; n++;
        }
    }
    for (i = 0; i < 4; i++) {
        if (!(prev & bits[i]) && (cur & bits[i])) {
            out_slot[n] = gt_hat_bit_slot(bits[i]); out_pressed[n] = 1; n++;
        }
    }
    return n;
}

#ifdef GT_REMAP_TEST

#include <stdio.h>

static int fail(const char *what) { fprintf(stderr, "FAIL: %s\n", what); return 1; }

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

    /* v2: key-name table — the whole set tunics.gptk needs, plus specials */
    if (gt_keyname("space").sym != ' ' || gt_keyname("space").scancode != 44)
        return fail("keyname space");
    if (gt_keyname("s").sym != 's' || gt_keyname("s").scancode != 22)
        return fail("keyname s");
    if (gt_keyname("w").sym != 'w' || gt_keyname("w").scancode != 26)
        return fail("keyname w");
    if (gt_keyname("esc").sym != 27 || gt_keyname("esc").scancode != 41)
        return fail("keyname esc");
    if (gt_keyname("tab").sym != 9 || gt_keyname("tab").scancode != 43)
        return fail("keyname tab");
    if (gt_keyname("up").sym != (GT_SCANCODE_MASK | 82))
        return fail("keyname up");
    if (gt_keyname("\\\"").sym != 0)
        return fail("gptokeyb quote placeholder must not map");
    if (gt_keyname("nosuchkey").sym != 0)
        return fail("unknown key must not map");

    /* v2: gptk parsing — the exact lines from the Tunics! port */
    {
        gt_keymap m; memset(&m, 0, sizeof m);
        if (!gt_gptk_line(&m, "a = space")) return fail("parse a=space");
        if (!gt_gptk_line(&m, "b = s")) return fail("parse b=s");
        if (!gt_gptk_line(&m, "back = esc")) return fail("parse back=esc");
        if (!gt_gptk_line(&m, "start = w")) return fail("parse start=w");
        if (!gt_gptk_line(&m, "up = up")) return fail("parse up=up");
        if (gt_gptk_line(&m, "l2 = \\\"")) return fail("quote placeholder parsed");
        if (gt_gptk_line(&m, "deadzone = 2000")) return fail("config line parsed");
        if (gt_gptk_line(&m, "left_analog_up = up")) return fail("analog line parsed");
        if (gt_gptk_line(&m, "# comment")) return fail("comment parsed");
        if (m.button_key[1].sym != ' ') return fail("A slot != space");
        if (m.button_key[0].sym != 's') return fail("B slot != s");
        if (m.button_key[6].sym != 27) return fail("back slot != esc");
        if (m.button_key[7].sym != 'w') return fail("start slot != w");
        if (m.dir_key[0].sym != (GT_SCANCODE_MASK | 82)) return fail("up dir != Up key");
        if (!m.loaded) return fail("map not marked loaded");
    }

    /* v2: hat edges — releases before presses, diagonal transitions */
    {
        int slots[4], pressed[4], n;
        n = gt_hat_edges(0, 1, slots, pressed); /* centered -> up */
        if (n != 1 || slots[0] != 0 || pressed[0] != 1) return fail("hat 0->UP");
        n = gt_hat_edges(1, 1 | 8, slots, pressed); /* up -> up-left */
        if (n != 1 || slots[0] != 2 || pressed[0] != 1) return fail("hat UP->UPLEFT");
        n = gt_hat_edges(1 | 8, 4 | 2, slots, pressed); /* up-left -> down-right */
        if (n != 4) return fail("hat diagonal flip count");
        if (pressed[0] != 0 || pressed[1] != 0) return fail("releases must come first");
        if (pressed[2] != 1 || pressed[3] != 1) return fail("presses must come last");
        n = gt_hat_edges(4 | 2, 0, slots, pressed); /* down-right -> centered */
        if (n != 2 || pressed[0] != 0 || pressed[1] != 0) return fail("hat release-all");
        n = gt_hat_edges(2, 2, slots, pressed); /* re-pass: no change, no edges */
        if (n != 0) return fail("hat re-pass must be edge-free");
    }

    puts("remap ok");
    return 0;
}

#else /* the real interposer */

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

/* v2 state: the gptk keymap (loaded once at init) and the pending-event
 * stash (a single hat transition can yield up to 4 key events; the first
 * replaces the hat event, the rest are served on subsequent polls before
 * SDL is consulted). Single-threaded event pumping is assumed, as
 * elsewhere in this shim. */
static gt_keymap gt_map;
static SDL_Event gt_stash[8];
static int gt_stash_n;
static int gt_hat_prev;

/* One unconditional line at load: launch.sh redirects stderr into the pak
 * log, so this is the cheap on-device proof that the preload took effect. */
__attribute__((constructor))
static void gt_init(void) {
    fprintf(stderr, "gt-input-remap: loaded\n");
    const char *path = getenv("GT_REMAP_GPTK");
    if (!path || !*path) return;
    FILE *fh = fopen(path, "r");
    if (!fh) {
        fprintf(stderr, "gt-input-remap: cannot open GT_REMAP_GPTK=%s\n", path);
        return;
    }
    char line[256];
    int n = 0;
    while (fgets(line, sizeof line, fh))
        n += gt_gptk_line(&gt_map, line);
    fclose(fh);
    fprintf(stderr, "gt-input-remap: keyboard synthesis on, %d mapping(s) from %s\n",
            n, path);
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

/* v2: a keyboard-only game has no reason to open a joystick — and SDL only
 * delivers SDL_JOYBUTTONDOWN/JOYHATMOTION for joysticks something in the
 * process has opened. Solarus proved it on-device (2026-08-23): its event
 * pump ran through this shim, yet no joystick event ever arrived to
 * translate. So when synthesis is active, the shim opens every joystick
 * itself — lazily, on the first event poll after SDL's video or joystick
 * subsystem is up (the constructor is too early), initializing the joystick
 * subsystem if the app never did. Opens are refcounted by SDL, so an app
 * that also opens the pad is unaffected. */
static void gt_ensure_joystick_open(void) {
    static int done;
    if (done || !gt_map.loaded) return;
    static Uint32 (*was_init)(Uint32);
    static int (*init_sub)(Uint32);
    static int (*num_joy)(void);
    static SDL_Joystick *(*joy_open)(int);
    if (!was_init) {
        was_init = (Uint32 (*)(Uint32))dlsym(RTLD_NEXT, "SDL_WasInit");
        init_sub = (int (*)(Uint32))dlsym(RTLD_NEXT, "SDL_InitSubSystem");
        num_joy  = (int (*)(void))dlsym(RTLD_NEXT, "SDL_NumJoysticks");
        joy_open = (SDL_Joystick *(*)(int))dlsym(RTLD_NEXT, "SDL_JoystickOpen");
    }
    if (!was_init || !init_sub || !num_joy || !joy_open) { done = 1; return; }
    if (!was_init(SDL_INIT_VIDEO) && !was_init(SDL_INIT_JOYSTICK))
        return; /* SDL not up yet — retry on a later poll */
    if (!was_init(SDL_INIT_JOYSTICK) && init_sub(SDL_INIT_JOYSTICK) != 0) {
        fprintf(stderr, "gt-input-remap: joystick subsystem init failed\n");
        done = 1;
        return;
    }
    int n = num_joy(), i, opened = 0;
    for (i = 0; i < n; i++)
        if (joy_open(i)) opened++;
    fprintf(stderr, "gt-input-remap: opened %d/%d joystick(s) for key synthesis\n",
            opened, n);
    done = 1;
}

static void gt_make_key_event(SDL_Event *ev, Uint32 timestamp,
                              gt_key k, int pressed) {
    memset(ev, 0, sizeof *ev);
    ev->type = pressed ? SDL_KEYDOWN : SDL_KEYUP;
    ev->key.timestamp = timestamp;
    ev->key.state = pressed ? SDL_PRESSED : SDL_RELEASED;
    ev->key.keysym.sym = (SDL_Keycode)k.sym;
    ev->key.keysym.scancode = (SDL_Scancode)k.scancode;
    if (gt_debug())
        fprintf(stderr, "gt-input-remap: synth key sym=0x%x (%s)\n",
                (unsigned)k.sym, pressed ? "down" : "up");
}

static void gt_rewrite(SDL_Event *ev) {
    if (!ev) return;

    if (ev->type == SDL_JOYBUTTONDOWN || ev->type == SDL_JOYBUTTONUP) {
        if (ev->jbutton.padding1 != GT_REMAPPED_MARKER) {
            unsigned char from = ev->jbutton.button;
            ev->jbutton.button = gt_remap(from);
            ev->jbutton.padding1 = GT_REMAPPED_MARKER;
            if (gt_debug() && from != ev->jbutton.button)
                fprintf(stderr, "gt-input-remap: jbutton %u -> %u (%s)\n",
                        from, ev->jbutton.button,
                        ev->type == SDL_JOYBUTTONDOWN ? "down" : "up");
        }
        /* v2: replace the button event with its mapped key event */
        if (gt_map.loaded && ev->jbutton.button < 16) {
            gt_key k = gt_map.button_key[ev->jbutton.button];
            if (k.sym)
                gt_make_key_event(ev, ev->jbutton.timestamp, k,
                                  ev->type == SDL_JOYBUTTONDOWN);
        }
        return;
    }

    if (ev->type == SDL_JOYHATMOTION && gt_map.loaded) {
        int slots[4], pressed[4];
        int cur = ev->jhat.value;
        int n = gt_hat_edges(gt_hat_prev, cur, slots, pressed);
        gt_hat_prev = cur;
        Uint32 ts = ev->jhat.timestamp;
        int emitted = 0, i;
        for (i = 0; i < n; i++) {
            gt_key k = gt_map.dir_key[slots[i]];
            if (!k.sym) continue;
            if (!emitted) {
                gt_make_key_event(ev, ts, k, pressed[i]); /* replace in place */
            } else if (gt_stash_n < (int)(sizeof gt_stash / sizeof gt_stash[0])) {
                gt_make_key_event(&gt_stash[gt_stash_n++], ts, k, pressed[i]);
            }
            emitted++;
        }
        /* no mapped edges: leave the hat event for the game as-is */
        return;
    }
}

int SDL_PollEvent(SDL_Event *ev) {
    static int (*real)(SDL_Event *);
    if (!real) real = (int (*)(SDL_Event *))dlsym(RTLD_NEXT, "SDL_PollEvent");
    gt_ensure_joystick_open();
    if (ev && gt_stash_n > 0) {
        *ev = gt_stash[0];
        gt_stash_n--;
        memmove(&gt_stash[0], &gt_stash[1], (size_t)gt_stash_n * sizeof gt_stash[0]);
        return 1;
    }
    int r = real(ev);
    if (r == 1) { gt_trace("poll", ev); gt_rewrite(ev); }
    return r;
}

int SDL_WaitEventTimeout(SDL_Event *ev, int timeout) {
    static int (*real)(SDL_Event *, int);
    if (!real) real = (int (*)(SDL_Event *, int))dlsym(RTLD_NEXT, "SDL_WaitEventTimeout");
    gt_ensure_joystick_open();
    if (ev && gt_stash_n > 0) {
        *ev = gt_stash[0];
        gt_stash_n--;
        memmove(&gt_stash[0], &gt_stash[1], (size_t)gt_stash_n * sizeof gt_stash[0]);
        return 1;
    }
    int r = real(ev, timeout);
    if (r == 1) { gt_trace("wait", ev); gt_rewrite(ev); }
    return r;
}

#endif /* GT_REMAP_TEST */
