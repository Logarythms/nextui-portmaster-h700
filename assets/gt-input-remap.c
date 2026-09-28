/* gt-input-remap.so — an optional LD_PRELOAD shim for PortMaster processes
 * on NextUI-h700 handhelds (RG SP and siblings). F65: it assumes NextUI rc11
 * or newer. rc11's SDL (LoveRetro h700-toolchain sdl2-h700.patch) gives the
 * built-in pad ONE fixed layout on every model, "matching TrimUI Player1 and
 * Xbox 360 raw indices":
 *
 *   B 0, A 1, Y 2, X 3, L1 4, R1 5, Select 6, Start 7, Menu 8, L3 9, R3 10,
 *   Vol- 13, Vol+ 14 (11 and 12 never fire; ESC and Menu's KEY_GOTO echo are
 *   dropped). L2/R2 are trigger AXES 2/5 (+32767 pressed, -32768 released),
 *   the sticks are axes 0/1 (left) and 3/4 (right), the d-pad is hat 0.
 *
 * That is the numbering the TrimUI-built PortMaster binaries expect, so the
 * shim no longer rewrites button indices: the rc10-era v1 remap tables (and
 * GT_INPUT_REMAP) are gone. The gptk slot space below IS that SDL numbering,
 * and a class-free table (gt_evdev_code_slot) maps kernel evdev codes to the
 * same slots for the evdev path (F45).
 *
 * v2 — keyboard-event synthesis (F26, 2026-08-23). NextUI's SDL never
 * delivers gptokeyb's uinput "Fake Keyboard" to SDL apps, so every port
 * whose game reads keyboard input (the whole gptokeyb tier) is input-dead
 * on this device even though gptokeyb itself runs fine. When the launcher
 * exports GT_REMAP_GPTK=<path to the port's .gptk file>, this shim does
 * gptokeyb's job at the SDL layer instead: joystick button events whose
 * button carries a .gptk key mapping are REPLACED in the
 * event stream by the corresponding SDL_KEYDOWN/SDL_KEYUP, and hat motions
 * become the mapped direction keys (edge-tracked, releases before presses;
 * a single hat transition can yield up to four key events — the first
 * replaces the hat event, the rest are served from a small internal stash
 * on subsequent polls). Buttons with no mapping keep their joystick events
 * unchanged, so hybrid ports lose nothing. Only the simple
 * `name = key` subset of the gptk format is honored (letters, digits,
 * space/esc/tab/enter/backspace/shift/ctrl/alt, arrows); everything else —
 * deadzone modes/scaling, gptokeyb's \" placeholder, hold_state modifiers —
 * is deliberately ignored. gptokeyb keeps running untouched alongside: its
 * synthetic keyboard is inert here, but its Select+Start kill hotkey works
 * off direct pad reads and stays the quit path. F53: on stick-class devices
 * the eight analog lines (with gptokeyb's defaults and unified `deadzone`)
 * are honored — stick deflections synthesize their keys the same way hats
 * do. F65: the gptk's l2/r2 keys are synthesized from the trigger axes.
 *
 * Both SDL_PollEvent and SDL_WaitEventTimeout are interposed (apps pump
 * through both). SDL_WaitEventTimeout may internally route through
 * SDL_PollEvent via the PLT — in that case one event passes through the
 * shim twice. Every rewrite is idempotent: a key event is never rewritten,
 * an unmapped button stays as it is, and a hat/axis/trigger re-pass sees
 * prev==cur and yields no edges.
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
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <stdint.h> /* uint32_t for the HUD's RGBA buffer (shared section is
                     * compiled under -DGT_REMAP_TEST with libc only — the
                     * interposer's SDL2/SDL.h, which would otherwise pull
                     * this in, is stripped from that build) */
#include <fcntl.h>   /* F54: open — gt_read_whole (pure half, also used by the fixture mode) */
#include <unistd.h>  /* F54: read, close */
#include <errno.h>   /* F54: EINTR */

/* F52: the pad's input class, loaded once from GT_INPUT_CLASS (exported by
 * launch.sh's gt-h700-input-class block from the joystick node's EV_KEY
 * bitmap): "sticks" = a stick-equipped device (RG34XXSP class), anything else
 * (incl. absent) = stickless (RG SP). F65: rc11 numbers the buttons the same
 * on both, so the class no longer picks a table; it only gates the F53
 * analog synthesis, which keeps the RG SP's phantom axes inert. */
static int gt_sticks_class = 0;
static void gt_class_load(void) {
    const char *c = getenv("GT_INPUT_CLASS");
    gt_sticks_class = (c && !strcmp(c, "sticks")) ? 1 : 0;
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
    if (!strcmp(name, "home"))      { k.scancode = 74;  k.sym = GT_SCANCODE_MASK | 74;  return k; }
    if (!strcmp(name, "end"))       { k.scancode = 77;  k.sym = GT_SCANCODE_MASK | 77;  return k; }
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

/* gt-h700-controller-layout (F48): when the user picks the xbox layout, the
 * gptk/evdev synth swaps a<->b and x<->y so the physical button acting as "A"
 * matches the SDL gamecontrollerdb the same launch installs. Loaded once from
 * GT_CONTROLLER_LAYOUT. Default (nintendo) leaves the measured table unchanged
 * so today's shim ports keep their working mapping. POLARITY (which layout
 * swaps) is confirmed at the device gate — a one-line flip here if reversed. */
static int gt_ab_swap = 0;
static void gt_layout_load(void) {
    const char *l = getenv("GT_CONTROLLER_LAYOUT");
    gt_ab_swap = (l && !strcmp(l, "xbox")) ? 1 : 0;
}

/* gptk button name -> slot. F65: the slot IS rc11's SDL button index; the
 * xbox layout swaps a<->b and x<->y. l2/r2 are not buttons on rc11 (see
 * gt_trigger_slot). */
static int gt_button_slot(const char *name) {
    if (!strcmp(name, "b"))     return gt_ab_swap ? 1 : 0;
    if (!strcmp(name, "a"))     return gt_ab_swap ? 0 : 1;
    if (!strcmp(name, "y"))     return gt_ab_swap ? 3 : 2;
    if (!strcmp(name, "x"))     return gt_ab_swap ? 2 : 3;
    if (!strcmp(name, "l1"))    return 4;
    if (!strcmp(name, "r1"))    return 5;
    if (!strcmp(name, "back") ||
        !strcmp(name, "select")) return 6;
    if (!strcmp(name, "start")) return 7;
    if (!strcmp(name, "guide")) return 8;
    if (!strcmp(name, "l3"))    return 9;   /* F52: stick clicks (stick-class devices) */
    if (!strcmp(name, "r3"))    return 10;
    return -1;
}

/* F65: gptk trigger name -> trigger index (0 = l2, 1 = r2). rc11 reports
 * L2/R2 as trigger axes 2/5, so their keys live in gt_keymap.trigger_key,
 * which no raw button index can reach. */
static int gt_trigger_slot(const char *name) {
    if (!strcmp(name, "l2")) return 0;
    if (!strcmp(name, "r2")) return 1;
    return -1;
}

/* F45/F52: evdev key code -> slot, directly, for the evdev gameplay path
 * (OpenCrossing: its stock 32-bit SDL yields no joystick events). The evdev
 * codes are the hardware truth on every h700 Anbernic. F65: the slot space is
 * rc11's SDL numbering, so this is the patch's own code -> index table for
 * the gameplay buttons (main() asserts it). L2/R2 go through
 * gt_evdev_trigger_slot. Returns -1 for codes that are not plain gameplay
 * buttons. */
static int gt_evdev_code_slot(int code) {
    switch (code) {
        case 304: return 1;   /* A  (east)  */
        case 305: return 0;   /* B  (south) */
        case 306: return 2;   /* Y  (west)  */
        case 307: return 3;   /* X  (north) */
        case 308: return 4;   /* L1 */
        case 309: return 5;   /* R1 */
        case 310: return 6;   /* Select */
        case 311: return 7;   /* Start  */
        case 313: return 9;   /* L3 click (stick devices) */
        case 316: return 10;  /* R3 click (stick devices) */
        default:  return -1;  /* 312 Menu / 354 GOTO / 1 ESC / 114-115 Vol / 314-315 L2-R2 */
    }
}

/* F65: evdev L2/R2 key codes -> trigger index (gt_trigger_slot's order). */
static int gt_evdev_trigger_slot(int code) {
    if (code == 314) return 0;   /* L2 */
    if (code == 315) return 1;   /* R2 */
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

/* F53: "left_analog_up" -> stick 0, dir 0 (dir uses gt_dir_slot's order). */
static int gt_analog_name(const char *name, int *stick, int *dir) {
    const char *rest;
    if (!strncmp(name, "left_analog_", 12))       { *stick = 0; rest = name + 12; }
    else if (!strncmp(name, "right_analog_", 13)) { *stick = 1; rest = name + 13; }
    else return 0;
    *dir = gt_dir_slot(rest);
    return *dir >= 0;   /* rejects left_analog_up_repeat and friends */
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
    gt_key button_key[16];   /* indexed by rc11 SDL button index (F65) */
    gt_key trigger_key[2];   /* F65: [0 = l2, 1 = r2], driven by trigger axes 2/5 */
    gt_key dir_key[4];       /* up/down/left/right (hat) */
    gt_key analog_key[2][4]; /* F53: [stick 0=left 1=right][0=up 1=down 2=left 3=right] */
    int analog_mouse[2];     /* F53: stick is mouse-driven in the gptk -> synthesize nothing */
    int deadzone;            /* F53: |axis| >= deadzone = deflected */
    int loaded;              /* any mapping present */
} gt_keymap;

/* F53: gptokeyb's built-in analog defaults (PortsMaster/gptokeyb, structs.h):
 * left stick W/S/A/D, right stick End/Home/Left/Right, deadzone 15000. A gptk
 * that names no analog line still gets these under gptokeyb, so the shim
 * mirrors them. Does NOT mark the map loaded — only parsed lines do. */
#define GT_DEADZONE_DEFAULT 15000
static void gt_keymap_defaults(gt_keymap *m) {
    m->analog_key[0][0] = gt_keyname("w");    m->analog_key[0][1] = gt_keyname("s");
    m->analog_key[0][2] = gt_keyname("a");    m->analog_key[0][3] = gt_keyname("d");
    m->analog_key[1][0] = gt_keyname("end");  m->analog_key[1][1] = gt_keyname("home");
    m->analog_key[1][2] = gt_keyname("left"); m->analog_key[1][3] = gt_keyname("right");
    m->analog_mouse[0] = m->analog_mouse[1] = 0;
    m->deadzone = GT_DEADZONE_DEFAULT;
}

/* Parse one gptk line into the map. Returns 1 if the line mapped something,
 * 0 otherwise. Accepts the `name = value` subset; trims spaces/CR; ignores
 * comments, blanks, non-`deadzone` config lines, and unknown key names;
 * analog lines and `deadzone` are honored (F53). */
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

    /* F53: analog lines. A PRESENT line replaces the gptokeyb default: a known
     * key sets it, an unknown name / the \" placeholder clears it, and a
     * mouse_movement_* value marks the whole stick mouse-driven (gptokeyb
     * emits no keys for a mouse stick). */
    int stick, dir;
    if (gt_analog_name(name, &stick, &dir)) {
        if (!strncmp(value, "mouse_movement", 14)) {
            m->analog_mouse[stick] = 1;
            m->analog_key[stick][dir].sym = 0; m->analog_key[stick][dir].scancode = 0;
        } else {
            m->analog_key[stick][dir] = gt_keyname(value);   /* unknown -> sym 0 = cleared */
        }
        m->loaded = 1;
        return 1;
    }
    if (!strcmp(name, "deadzone")) {   /* gptokeyb's unified deadzone; 0 would read a centered stick as deflected */
        int dz = atoi(value);
        if (dz >= 1 && dz <= 32767) m->deadzone = dz;
        return 0;   /* config, not a mapping */
    }

    gt_key k = gt_keyname(value);
    if (!k.sym) return 0;

    int slot = gt_button_slot(name);
    if (slot >= 0) { m->button_key[slot] = k; m->loaded = 1; return 1; }
    slot = gt_trigger_slot(name);
    if (slot >= 0) { m->trigger_key[slot] = k; m->loaded = 1; return 1; }
    slot = gt_dir_slot(name);
    if (slot >= 0) { m->dir_key[slot] = k; m->loaded = 1; return 1; }
    return 0; /* other config/unknown names: ignored by design */
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

/* F45: evdev D-pad edge computation. This device reports the D-pad as two
 * absolute axes (ABS_HAT0X/ABS_HAT0Y) valued -1/0/+1, not as the SDL hat
 * bitmask gt_hat_edges handles. Given one axis's previous and current value
 * and the direction slots for its negative/positive ends, list the
 * (slot, pressed) transitions — release before press, so passing straight
 * through center (e.g. -1 -> +1) never holds both ends at once. Returns 0..2;
 * out_slot/out_pressed must hold 2 entries. */
static int gt_evdev_hat_edges(int prev, int cur, int slot_neg, int slot_pos,
                              int *out_slot, int *out_pressed) {
    int n = 0;
    if (prev == cur) return 0;
    if (prev < 0)      { out_slot[n] = slot_neg; out_pressed[n] = 0; n++; }
    else if (prev > 0) { out_slot[n] = slot_pos; out_pressed[n] = 0; n++; }
    if (cur < 0)       { out_slot[n] = slot_neg; out_pressed[n] = 1; n++; }
    else if (cur > 0)  { out_slot[n] = slot_pos; out_pressed[n] = 1; n++; }
    return n;
}

/* F53: axis value -> direction. gptokeyb: zero iff |v| < deadzone, so a value
 * AT the deadzone counts as deflected. */
static int gt_axis_dir(int value, int deadzone) {
    if (value <= -deadzone) return -1;
    if (value >=  deadzone) return  1;
    return 0;
}

/* F53/F65: which stick an rc11 SDL axis belongs to and which analog_key
 * slots its negative / positive ends drive: a0 left X, a1 left Y, a3 right X,
 * a4 right Y; negative = up / left. Slot order = gt_dir_slot. Returns 0 for
 * every other axis (a2/a5 are the L2/R2 triggers, see gt_trigger_index). */
static int gt_axis_slots(int axis, int *stick, int *slot_neg, int *slot_pos) {
    switch (axis) {
        case 0: *stick = 0; *slot_neg = 2; *slot_pos = 3; return 1;   /* left X: left / right */
        case 1: *stick = 0; *slot_neg = 0; *slot_pos = 1; return 1;   /* left Y: up / down    */
        case 3: *stick = 1; *slot_neg = 2; *slot_pos = 3; return 1;   /* right X */
        case 4: *stick = 1; *slot_neg = 0; *slot_pos = 1; return 1;   /* right Y */
        default: return 0;
    }
}

/* F65: rc11 trigger axis -> trigger index (0 = L2 on a2, 1 = R2 on a5), else -1. */
static int gt_trigger_index(int axis) {
    return axis == 2 ? 0 : axis == 5 ? 1 : -1;
}

/* F65: trigger edge. rc11 reports a trigger as +32767 pressed and -32768
 * released (plus a seed value when the pad is opened); pressed iff value > 0.
 * Returns 1 on a press, 0 on a release, -1 when the state did not change (a
 * repeat, the released seed, or a re-pass of the same event). *held is the
 * per-trigger state. */
static int gt_trigger_edge(int *held, int value) {
    int now = value > 0 ? 1 : 0;
    if (now == *held) return -1;
    *held = now;
    return now;
}

/* ---- v3 state-polling half (no SDL types; host-testable) --------------
 * The v2 half synthesizes SDL key EVENTS, which only games that consume the
 * event stream (love.keypressed, SDL_PollEvent loops) ever see. Games that
 * POLL key state instead — SDL_GetKeyboardState, i.e. love.keyboard.isDown —
 * read SDL's internal keystate array, which the fabricated events never
 * touch, so their in-game input stays dead (BYTEPATH: menus work off events,
 * gameplay polls). Maintain a synthetic keystate array (indexed by SDL
 * scancode) that the interposed SDL_GetKeyboardState merges over SDL's real
 * state. */
#define GT_NUM_SCANCODES 512

/* Set/clear one scancode in the synthetic keystate; out-of-range is a no-op
 * (SDL scancodes are bounded by GT_NUM_SCANCODES). */
static void gt_synth_set(unsigned char *state, int scancode, int pressed) {
    if (scancode >= 0 && scancode < GT_NUM_SCANCODES)
        state[scancode] = (unsigned char)(pressed ? 1 : 0);
}

/* Merge SDL's real keystate with the synthetic one into out[0..n): a key is
 * down if either source has it down. n is clamped to GT_NUM_SCANCODES. */
static void gt_merge_keystate(unsigned char *out, const unsigned char *real,
                              const unsigned char *synth, int n) {
    int i;
    if (n > GT_NUM_SCANCODES) n = GT_NUM_SCANCODES;
    for (i = 0; i < n; i++)
        out[i] = (unsigned char)(real[i] | synth[i]);
}

/* ---- HUD sampling + formatting (no SDL/GL; host-testable) -------------- */
/* NextUI /dev/shm/SharedSettings: an array of int32 byte-offset fields.
 * brightness = idx1 (offset 4), volume = idx4 (offset 16); both device-
 * confirmed 2026-08-26 (rc8, 132-byte block) AND re-confirmed 2026-09-18
 * (h700-rc10, 64-byte block) by nudging each setting and re-dumping — the two
 * fields kept their offsets across the shrink. Units: volume 0-20, brightness
 * 0-10 (NextUI). GT_SS_LEN is only the read-buffer upper bound; the DECODE
 * guard is GT_SS_MIN_LEN, the minimum that still covers the volume int32, so a
 * build that resizes the block (rc10 shrank it to 64) keeps working as long as
 * brightness@4 / volume@16 hold. */
#define GT_SS_LEN            132   /* read-buffer cap (largest block seen) */
#define GT_SS_OFF_BRIGHTNESS 4     /* int32 idx1 (0-10) */
#define GT_SS_OFF_VOLUME     16    /* int32 idx4 (0-20) */
#define GT_SS_MIN_LEN        (GT_SS_OFF_VOLUME + 4)  /* bytes needed through volume */
#define GT_SS_VOLUME_MAX     20
#define GT_SS_BRIGHTNESS_MAX 10

typedef struct {
    int battery_pct;     /* 0-100 */
    int charging;        /* 0/1 */
    int volume;          /* 0..GT_SS_VOLUME_MAX, -1 if unknown */
    int brightness;      /* 0..GT_SS_BRIGHTNESS_MAX, -1 if unknown */
    int hour, minute;    /* 0-23, 0-59 */
    int valid;           /* SharedSettings decoded ok */
} gt_metrics;

static int gt_rd_i32(const unsigned char *b, int off) {
    int v; memcpy(&v, b + off, 4); return v;
}

/* Decode volume+brightness from a SharedSettings buffer. Returns 1 on success. */
static int gt_shared_settings_decode(const unsigned char *buf, int len, gt_metrics *m) {
    if (!buf || len < GT_SS_MIN_LEN) { m->volume = m->brightness = -1; m->valid = 0; return 0; }
    m->volume = gt_rd_i32(buf, GT_SS_OFF_VOLUME);
    m->brightness = gt_rd_i32(buf, GT_SS_OFF_BRIGHTNESS);
    if (m->volume < 0) m->volume = 0; if (m->volume > GT_SS_VOLUME_MAX) m->volume = GT_SS_VOLUME_MAX;
    if (m->brightness < 0) m->brightness = 0; if (m->brightness > GT_SS_BRIGHTNESS_MAX) m->brightness = GT_SS_BRIGHTNESS_MAX;
    m->valid = 1;
    return 1;
}

/* Parse the battery sysfs contents. capacity="NN\n", status="Charging\n". */
static void gt_battery_parse(const char *cap, const char *status, gt_metrics *m) {
    m->battery_pct = cap ? atoi(cap) : -1;
    if (m->battery_pct < 0) m->battery_pct = 0; if (m->battery_pct > 100) m->battery_pct = 100;
    m->charging = (status && (status[0] == 'C' || status[0] == 'c')) ? 1 : 0; /* "Charging" */
}

/* Set hour/minute from a struct tm (host-testable substitute for localtime,
 * which the shared/host-test section deliberately does not call). */
static void gt_time_set(gt_metrics *m, const struct tm *t) {
    m->hour = t->tm_hour;
    m->minute = t->tm_min;
}

/* Pure, host-testable text formatters for the two NUMERIC HUD values (row
 * labels are drawn as constants in gt_hud_compose; volume/brightness are
 * gauges, not text). Battery: "+42%" charging, "42%" otherwise. Time: HH:MM. */
static void gt_fmt_battery(const gt_metrics *m, char *out, int cap) {
    snprintf(out, (size_t)cap, "%s%d%%", m->charging ? "+" : "", m->battery_pct);
}
static void gt_fmt_time(const gt_metrics *m, char *out, int cap) {
    snprintf(out, (size_t)cap, "%02d:%02d", m->hour, m->minute);
}

/* ---- HUD font + RGBA compose (no SDL/GL; host-testable) ---------------
 * An embedded 6x8 mono bitmap font (5 columns of glyph + 1 blank spacer
 * column, so glyphs never touch when blitted at a fixed 6px pitch) covering
 * every character the labels and values can produce (A-Z, digits, :%+-).
 * gt_hud_compose rasterizes four rows over a translucent dark panel into an
 * RGBA8888 buffer: a left-aligned label and a right-aligned value each —
 * BATTERY (numeric %), BRIGHTNESS + VOLUME (horizontal gauges), TIME (HH:MM).
 * Everything is integer-upscaled by GT_HUD_SCALE. gt_hud_rect places the
 * panel's top-right origin on screen. */
#define GT_GLYPH_W 6
#define GT_GLYPH_H 8
/* index: 0=space 1..10='0'..'9' 11..36='A'..'Z' 37=':' 38='%' 39='+' 40='-' */
static int gt_glyph_index(char c) {
    if (c == ' ') return 0;
    if (c >= '0' && c <= '9') return 1 + (c - '0');
    if (c >= 'A' && c <= 'Z') return 11 + (c - 'A');
    if (c == ':') return 37;
    if (c == '%') return 38;
    if (c == '+') return 39;
    if (c == '-') return 40;
    return 0; /* unknown -> space */
}
#define GT_FONT_N 41
/* Each row byte is a column bitmask, bit 5..0 = columns 0..5 left-to-right
 * (gt_draw_glyph tests bit (GT_GLYPH_W-1-cx)). Every glyph leaves column 5
 * blank by design — a 1px spacer at the fixed 6px column pitch — so adjacent
 * characters never touch. Rows 0..6 carry the glyph; row 7 is always blank
 * (a classic 5x7-in-8 look, matching the line gap already added between
 * text rows). */
static const unsigned char GT_FONT[GT_FONT_N][GT_GLYPH_H] = {
    /* space */ {0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00},
    /* 0 */ {0x1C,0x22,0x26,0x2A,0x32,0x22,0x1C,0x00},
    /* 1 */ {0x08,0x18,0x08,0x08,0x08,0x08,0x1C,0x00},
    /* 2 */ {0x1C,0x22,0x02,0x04,0x08,0x10,0x3E,0x00},
    /* 3 */ {0x1C,0x22,0x02,0x0C,0x02,0x22,0x1C,0x00},
    /* 4 */ {0x04,0x0C,0x14,0x24,0x3E,0x04,0x04,0x00},
    /* 5 */ {0x3E,0x20,0x3C,0x02,0x02,0x22,0x1C,0x00},
    /* 6 */ {0x0C,0x10,0x20,0x3C,0x22,0x22,0x1C,0x00},
    /* 7 */ {0x3E,0x02,0x04,0x08,0x08,0x08,0x08,0x00},
    /* 8 */ {0x1C,0x22,0x22,0x1C,0x22,0x22,0x1C,0x00},
    /* 9 */ {0x1C,0x22,0x22,0x1E,0x02,0x04,0x18,0x00},
    /* A */ {0x08,0x14,0x22,0x22,0x3E,0x22,0x22,0x00},
    /* B */ {0x3C,0x22,0x22,0x3C,0x22,0x22,0x3C,0x00},
    /* C */ {0x1E,0x22,0x20,0x20,0x20,0x22,0x1E,0x00},
    /* D */ {0x3C,0x22,0x22,0x22,0x22,0x22,0x3C,0x00},
    /* E */ {0x3E,0x20,0x20,0x3C,0x20,0x20,0x3E,0x00},
    /* F */ {0x3E,0x20,0x20,0x3C,0x20,0x20,0x20,0x00},
    /* G */ {0x1E,0x22,0x20,0x26,0x22,0x22,0x1E,0x00},
    /* H */ {0x22,0x22,0x22,0x3E,0x22,0x22,0x22,0x00},
    /* I */ {0x1C,0x08,0x08,0x08,0x08,0x08,0x1C,0x00},
    /* J */ {0x06,0x02,0x02,0x02,0x02,0x22,0x1C,0x00},
    /* K */ {0x22,0x24,0x28,0x30,0x28,0x24,0x22,0x00},
    /* L */ {0x20,0x20,0x20,0x20,0x20,0x20,0x3E,0x00},
    /* M */ {0x22,0x36,0x2A,0x2A,0x22,0x22,0x22,0x00},
    /* N */ {0x22,0x32,0x2A,0x2A,0x26,0x22,0x22,0x00},
    /* O */ {0x1C,0x22,0x22,0x22,0x22,0x22,0x1C,0x00},
    /* P */ {0x3C,0x22,0x22,0x3C,0x20,0x20,0x20,0x00},
    /* Q */ {0x1C,0x22,0x22,0x22,0x2A,0x24,0x1A,0x00},
    /* R */ {0x3C,0x22,0x22,0x3C,0x28,0x24,0x22,0x00},
    /* S */ {0x1E,0x20,0x20,0x1C,0x02,0x02,0x3C,0x00},
    /* T */ {0x1C,0x08,0x08,0x08,0x08,0x08,0x08,0x00},
    /* U */ {0x22,0x22,0x22,0x22,0x22,0x22,0x1C,0x00},
    /* V */ {0x22,0x22,0x22,0x22,0x14,0x14,0x08,0x00},
    /* W */ {0x22,0x22,0x22,0x2A,0x2A,0x36,0x22,0x00},
    /* X */ {0x22,0x22,0x14,0x08,0x14,0x22,0x22,0x00},
    /* Y */ {0x22,0x22,0x14,0x08,0x08,0x08,0x08,0x00},
    /* Z */ {0x3E,0x02,0x04,0x08,0x10,0x20,0x3E,0x00},
    /* : */ {0x00,0x08,0x08,0x00,0x08,0x08,0x00,0x00},
    /* % */ {0x22,0x24,0x04,0x08,0x10,0x12,0x22,0x00},
    /* + */ {0x00,0x08,0x08,0x3E,0x08,0x08,0x00,0x00},
    /* - */ {0x00,0x00,0x00,0x3E,0x00,0x00,0x00,0x00},
};

/* Panel scale: every glyph pixel becomes a SCALE x SCALE block and every layout
 * dimension is multiplied by SCALE. Single knob so the size can be tuned after
 * eyeballing on the device. */
#define GT_HUD_SCALE 2
#define GT_CELL_W (GT_GLYPH_W * GT_HUD_SCALE)   /* scaled glyph advance (incl. 1px spacer) */
#define GT_CELL_H (GT_GLYPH_H * GT_HUD_SCALE)   /* scaled glyph height */

#define GT_HUD_ROWS          4
#define GT_HUD_PAD           (4 * GT_HUD_SCALE)  /* panel inner padding */
#define GT_HUD_LINE_GAP      (2 * GT_HUD_SCALE)  /* vertical gap between rows */
#define GT_HUD_COL_GAP       (6 * GT_HUD_SCALE)  /* gap between label and value columns */
#define GT_HUD_LABEL_CHARS   10                  /* widest label: BRIGHTNESS */
#define GT_HUD_VALTEXT_CHARS 5                   /* widest text value: "+100%" / "HH:MM" */
#define GT_HUD_LABEL_W       (GT_HUD_LABEL_CHARS   * GT_CELL_W)
#define GT_HUD_VALTEXT_W     (GT_HUD_VALTEXT_CHARS * GT_CELL_W)
#define GT_HUD_GAUGE_W       (18 * GT_HUD_SCALE)  /* fixed gauge bar width */
#define GT_HUD_GAUGE_H       GT_CELL_H            /* one glyph tall */
/* value column width = max(gauge, widest text value) */
#define GT_HUD_VALUE_W       (GT_HUD_VALTEXT_W > GT_HUD_GAUGE_W ? GT_HUD_VALTEXT_W : GT_HUD_GAUGE_W)

#define GT_HUD_BG   0xC0202020u        /* ~75% opaque dark */
#define GT_HUD_FG   0xFFFFFFFFu        /* opaque white */

/* Panel = pad + widest label + col gap + value column + pad (all scaled);
 * height = pad + ROWS rows (scaled cell) + gaps + pad. These feed the static
 * RGBA buffer and the GL quad, so they are compile-time constants. */
#define GT_HUD_MAX_W (GT_HUD_PAD + GT_HUD_LABEL_W + GT_HUD_COL_GAP + GT_HUD_VALUE_W + GT_HUD_PAD)
#define GT_HUD_MAX_H (GT_HUD_PAD + GT_HUD_ROWS * GT_CELL_H + (GT_HUD_ROWS - 1) * GT_HUD_LINE_GAP + GT_HUD_PAD)

static void gt_put_px(uint32_t *rgba, int w, int h, int x, int y, uint32_t c) {
    if (x >= 0 && x < w && y >= 0 && y < h) rgba[y * w + x] = c;
}
static void gt_fill_rect(uint32_t *rgba, int w, int h, int x, int y, int rw, int rh, uint32_t col) {
    for (int j = 0; j < rh; j++)
        for (int i = 0; i < rw; i++)
            gt_put_px(rgba, w, h, x + i, y + j, col);
}
/* One glyph, upscaled: each set font pixel -> a SCALE x SCALE block. */
static void gt_draw_glyph(uint32_t *rgba, int w, int h, int x, int y, char c, uint32_t col) {
    const unsigned char *g = GT_FONT[gt_glyph_index(c)];
    for (int row = 0; row < GT_GLYPH_H; row++)
        for (int cx = 0; cx < GT_GLYPH_W; cx++)
            if (g[row] & (1 << (GT_GLYPH_W - 1 - cx)))
                gt_fill_rect(rgba, w, h, x + cx * GT_HUD_SCALE, y + row * GT_HUD_SCALE,
                             GT_HUD_SCALE, GT_HUD_SCALE, col);
}
/* A string left-aligned at x (fixed GT_CELL_W pitch). */
static void gt_draw_text(uint32_t *rgba, int w, int h, int x, int y, const char *s, uint32_t col) {
    for (int i = 0; s[i]; i++)
        gt_draw_glyph(rgba, w, h, x + i * GT_CELL_W, y, s[i], col);
}
/* A string whose block right edge is right_x. */
static void gt_draw_text_right(uint32_t *rgba, int w, int h, int right_x, int y, const char *s, uint32_t col) {
    int n = (int)strlen(s);
    gt_draw_text(rgba, w, h, right_x - n * GT_CELL_W, y, s, col);
}
/* Horizontal meter: a SCALE-thick outline rectangle (gw x gh) with an inner
 * fill from the left proportional to level/max. level<=0 (incl. an unknown -1)
 * -> outline only; level>=max -> full inner width. */
static void gt_draw_gauge(uint32_t *rgba, int w, int h, int x, int y,
                          int gw, int gh, int level, int max, uint32_t col) {
    int t = GT_HUD_SCALE;                                    /* outline thickness (1px scaled) */
    gt_fill_rect(rgba, w, h, x, y, gw, t, col);              /* top */
    gt_fill_rect(rgba, w, h, x, y + gh - t, gw, t, col);     /* bottom */
    gt_fill_rect(rgba, w, h, x, y, t, gh, col);              /* left */
    gt_fill_rect(rgba, w, h, x + gw - t, y, t, gh, col);     /* right */
    int iw = gw - 2 * t, ih = gh - 2 * t;                    /* inner region */
    if (max > 0 && level > 0 && iw > 0 && ih > 0) {
        if (level > max) level = max;
        int fw = (iw * level + max / 2) / max;               /* rounded */
        if (fw > iw) fw = iw;
        if (fw > 0) gt_fill_rect(rgba, w, h, x + t, y + t, fw, ih, col);
    }
}

/* Compose the panel: BATTERY / BRIGHTNESS / VOLUME / TIME, one per row. Labels
 * left-aligned at the pad; values right-aligned to (width - pad): battery %
 * text and time HH:MM as text, brightness and volume as gauges. rgba must hold
 * GT_HUD_MAX_W*GT_HUD_MAX_H px. */
static void gt_hud_compose(const gt_metrics *m, uint32_t *rgba, int *out_w, int *out_h) {
    static const char *const LABELS[GT_HUD_ROWS] = { "BATTERY", "BRIGHTNESS", "VOLUME", "TIME" };
    int w = GT_HUD_MAX_W, h = GT_HUD_MAX_H;
    for (int i = 0; i < w * h; i++) rgba[i] = GT_HUD_BG;

    int right_x = w - GT_HUD_PAD;                    /* common right edge for all values */
    int gauge_x = right_x - GT_HUD_GAUGE_W;          /* gauges right-aligned like the rest */

    for (int row = 0; row < GT_HUD_ROWS; row++) {
        int y = GT_HUD_PAD + row * (GT_CELL_H + GT_HUD_LINE_GAP);
        gt_draw_text(rgba, w, h, GT_HUD_PAD, y, LABELS[row], GT_HUD_FG);
        if (row == 0) {                              /* BATTERY: numeric % (+ when charging) */
            char bt[8]; gt_fmt_battery(m, bt, sizeof bt);
            gt_draw_text_right(rgba, w, h, right_x, y, bt, GT_HUD_FG);
        } else if (row == 1) {                       /* BRIGHTNESS gauge */
            gt_draw_gauge(rgba, w, h, gauge_x, y, GT_HUD_GAUGE_W, GT_HUD_GAUGE_H,
                          m->brightness, GT_SS_BRIGHTNESS_MAX, GT_HUD_FG);
        } else if (row == 2) {                       /* VOLUME gauge */
            gt_draw_gauge(rgba, w, h, gauge_x, y, GT_HUD_GAUGE_W, GT_HUD_GAUGE_H,
                          m->volume, GT_SS_VOLUME_MAX, GT_HUD_FG);
        } else {                                     /* TIME: HH:MM */
            char tt[8]; gt_fmt_time(m, tt, sizeof tt);
            gt_draw_text_right(rgba, w, h, right_x, y, tt, GT_HUD_FG);
        }
    }
    *out_w = w; *out_h = h;
}

static void gt_hud_rect(int sw, int sh, int pw, int ph, int *x, int *y) {
    int margin = 8;
    *x = sw - pw - margin; if (*x < 0) *x = 0;
    *y = margin;           if (*y + ph > sh) *y = sh - ph;
}

/* ---- HUD Menu-toggle state machine (no SDL types; host-testable) ------
 * The interposer's Menu-button intercept (gt_hud_intercept, interposer half)
 * calls this on EVERY joystick-button edge (Menu or not); it is kept
 * pure/host-testable so main() can assert the tap + swallow behavior
 * without linking SDL.
 *
 * True single-tap, not flip-on-press: keymon's brightness shortcut is
 * Menu-held + Vol. If the HUD flipped on Menu-DOWN, starting a brightness
 * adjustment would also flip the HUD (and flip it back OFF if it was
 * already up, since the Vol press happens mid-hold). So the flip is
 * deferred to Menu-UP, and only fires if no other button went down while
 * Menu was held (a clean tap). Both Menu edges are still always swallowed
 * either way, so the game never sees Menu; keymon reads Menu from evdev
 * independently of SDL, so its brightness combo keeps working regardless
 * of what this shim does to the SDL event stream. */
/* F65: the SDL Menu button. rc11 delivers Menu as ONE clean button, b8 (no
 * ESC, no KEY_GOTO echo), so identity and swallow are the same test:
 * gt_hud_intercept swallows both b8 edges so the game never sees Menu, and the
 * toggle itself runs in the evdev thread. Pure/host-testable. */
#define GT_MENU_BUTTON 8
static int gt_is_menu_button(unsigned char b) {
    return b == GT_MENU_BUTTON;
}

/* evdev key codes for the Menu/Volume buttons on this device family (RG SP,
 * ANBERNIC-keys / event1, device-confirmed 2026-08-26). The universal evdev
 * toggle thread (interposer half) classifies raw kernel key codes with this
 * pure helper. KEY_GOTO (354) is Menu's second emission — SKIPPED (classified
 * GT_EVK_OTHER, so it synthesizes no key); only BTN_TL2 (312) drives the tap.
 * Pre-F65 the SDL path skipped an analogous echo at raw 14; rc11 sends Menu
 * as one clean b8, so gt_is_menu_button needs no such skip. */
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

typedef struct { int menu_held, disqualified; } gt_tap_state;

static int gt_menu_toggle(gt_tap_state *s, volatile int *visible, int is_menu, int is_down) {
    if (is_menu) {
        if (is_down) {
            if (!s->menu_held) { s->menu_held = 1; s->disqualified = 0; }  /* reset only on first press */
            /* a repeated Menu-down while already held is a no-op (defensive) */
        } else if (s->menu_held) {              /* Menu release */
            if (!s->disqualified) *visible = !*visible;
            s->menu_held = 0;
        }
        return 1;                             /* swallow both Menu edges */
    }
    if (is_down && s->menu_held) s->disqualified = 1;  /* any other press cancels the tap */
    return 0;                                 /* never swallow non-Menu events */
}

/* ======================================================================
 * F54: gptokeyb passthrough — pure helpers (host-tested via test-30).
 *
 * NextUI's SDL2 is a no-libudev build: its evdev keyboard/mouse layer
 * (SDL_EVDEV_Init) opens ONLY the devices named in SDL_EVDEV_DEVICES
 * ("class:path,..."; class bits 1 = mouse, 2 = keyboard). Nothing on NextUI
 * sets it, so gptokeyb's uinput "Fake Keyboard" was never opened and every
 * keyboard/mouse port was input-dead — the whole reason the F26/F31 synthesis
 * exists. Device-proven 2026-09-04 (RG SP, BYTEPATH: menus AND polled
 * gameplay work through gptokeyb once the variable names its node). The
 * interposer half resolves the node at SDL init and exports the variable;
 * these helpers do the parsing and string building with libc only.
 */
#define GT_FAKE_KBD_NAME "Fake Keyboard"     /* gptokeyb AND gptokeyb2 */
#define GT_EVDEV_CLASS_KBD_MOUSE 3           /* SDL_UDEV_DEVICE_MOUSE|KEYBOARD: the node
                                              * advertises EV=7/REL=3 even for a
                                              * keyboard-only gptk */
#define GT_INPUT_DEVICES_CAP (64 * 1024)     /* /proc/bus/input/devices is ~1.5 KB here */

/* Read a file whole with read(2) until EOF into buf (NUL-terminated, at most
 * cap-1 bytes; a larger file is truncated and parsed as far as it goes).
 * procfs must never be read with line-at-a-time shell semantics (F52 lesson:
 * busybox `read` on /proc/bus/input/devices hangs); a single read loop is the
 * safe shape. Returns bytes read, or -1 (errno set). */
static long gt_read_whole(const char *path, char *buf, size_t cap) {
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return -1;
    size_t got = 0;
    while (got < cap - 1) {
        ssize_t r = read(fd, buf + got, cap - 1 - got);
        if (r < 0) { if (errno == EINTR) continue; close(fd); return -1; }
        if (r == 0) break;
        got += (size_t)r;
    }
    close(fd);
    buf[got] = 0;
    return (long)got;
}

/* Parse a NUL-terminated /proc/bus/input/devices snapshot and pick the
 * "Fake Keyboard" stanza with the HIGHEST inputN in its
 * "S: Sysfs=.../input/inputN" line: input numbers are monotonic for the boot
 * while event numbers are recycled, so "newest" must key on inputN (Doom
 * Engines starts gptokeyb twice). Writes "/dev/input/eventN" (eventN from the
 * "H: Handlers=" line) into out. Returns 1 if found, else 0. A stanza missing
 * either line is ignored; the name must match exactly. */
static int gt_fake_kbd_resolve(const char *buf, char *out, size_t outsz) {
    long best_input = -1, cur_input = -1;
    int best_event = -1, cur_event = -1, in_fake = 0;
    const size_t want = strlen(GT_FAKE_KBD_NAME);
    const char *line = buf;
    for (;;) {
        const char *nl = strchr(line, '\n');
        size_t n = nl ? (size_t)(nl - line) : strlen(line);
        if (n == 0) {                                   /* blank line: stanza ends */
            if (in_fake && cur_input >= 0 && cur_event >= 0 && cur_input > best_input) {
                best_input = cur_input; best_event = cur_event;
            }
            in_fake = 0; cur_input = -1; cur_event = -1;
        } else if (!strncmp(line, "N: Name=\"", 9)) {
            in_fake = (n == 9 + want + 1 && !strncmp(line + 9, GT_FAKE_KBD_NAME, want)
                       && line[9 + want] == '"');
        } else if (!strncmp(line, "S: Sysfs=", 9)) {
            const char *p = NULL, *q = line + 9;
            while ((q = strstr(q, "/input")) && q < line + n) {   /* LAST "/input<digits>" wins */
                if (q[6] >= '0' && q[6] <= '9') p = q + 6;
                q += 6;
            }
            if (p) cur_input = strtol(p, NULL, 10);
        } else if (!strncmp(line, "H: Handlers=", 12)) {
            const char *q = line + 12;
            while ((q = strstr(q, "event")) && q < line + n) {
                if (q[5] >= '0' && q[5] <= '9' && (q[-1] == ' ' || q[-1] == '=')) {
                    cur_event = (int)strtol(q + 5, NULL, 10);
                    break;
                }
                q += 5;
            }
        }
        if (!nl) break;
        line = nl + 1;
    }
    if (in_fake && cur_input >= 0 && cur_event >= 0 && cur_input > best_input) {
        best_input = cur_input; best_event = cur_event;   /* no trailing blank line */
    }
    if (best_event < 0) return 0;
    snprintf(out, outsz, "/dev/input/event%d", best_event);
    return 1;
}

/* "3:/dev/input/eventN" for SDL_EVDEV_DEVICES. Returns 0 if out is too small
 * (the caller then leaves the variable alone). */
static int gt_evdev_env_build(char *out, size_t outsz, const char *node) {
    int n = snprintf(out, outsz, "%d:%s", GT_EVDEV_CLASS_KBD_MOUSE, node);
    return (n > 0 && (size_t)n < outsz) ? 1 : 0;
}

/* 1 if a /proc/<pid>/cmdline buffer (len bytes, NUL-separated arguments)
 * holds `arg` as one whole argument. F54 device-gate finding (2026-09-28):
 * gptokeyb creates its uinput "Fake Keyboard" only when started with a
 * mapping (-c <gptk>). Run without one, as native-controller ports do to get
 * just the Select+Start quit watcher (Balatro, Deltarune, Mina, ...), it
 * never creates a keyboard, and waiting 2 s for one delayed every such
 * launch. */
static int gt_cmdline_has_arg(const char *buf, size_t len, const char *arg) {
    const size_t n = strlen(arg);
    size_t i = 0;
    while (i < len) {
        size_t l = 0;
        while (i + l < len && buf[i + l]) l++;
        if (l == n && !memcmp(buf + i, arg, n)) return 1;
        i += l + 1;
    }
    return 0;
}

#ifdef GT_REMAP_TEST

static int fail(const char *what) { fprintf(stderr, "FAIL: %s\n", what); return 1; }

/* Count opaque-white (FG) pixels in [x0,x1) x [y0,y1) of an w-wide RGBA buffer
 * — used by the compose layout asserts below. */
static int gt_count_fg(const uint32_t *buf, int w, int x0, int y0, int x1, int y1) {
    int n = 0;
    for (int y = y0; y < y1; y++)
        for (int x = x0; x < x1; x++)
            if (buf[y * w + x] == GT_HUD_FG) n++;
    return n;
}

int main(int argc, char **argv) {
    /* F54 fixture mode (test-30): resolve gptokeyb's node from a saved
     * /proc/bus/input/devices snapshot. Prints the node path or "none". */
    if (argc == 3 && !strcmp(argv[1], "--fake-kbd")) {
        static char buf[GT_INPUT_DEVICES_CAP];
        char node[64];
        if (gt_read_whole(argv[2], buf, sizeof buf) < 0) { perror(argv[2]); return 1; }
        puts(gt_fake_kbd_resolve(buf, node, sizeof node) ? node : "none");
        return 0;
    }
    (void)argc; (void)argv;
    unsigned i;
    /* F65: GT_INPUT_CLASS only gates F53 now (rc11 has one table for all). */
    setenv("GT_INPUT_CLASS", "sticks", 1); gt_class_load();
    if (!gt_sticks_class) return fail("GT_INPUT_CLASS=sticks not loaded");
    setenv("GT_INPUT_CLASS", "plain", 1); gt_class_load();
    if (gt_sticks_class) return fail("GT_INPUT_CLASS=plain must be stickless");
    unsetenv("GT_INPUT_CLASS"); gt_class_load();
    if (gt_sticks_class) return fail("absent GT_INPUT_CLASS must be stickless");

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
        if (!gt_gptk_line(&m, "l3 = q")) return fail("parse l3=q");
        if (m.button_key[9].sym != 'q') return fail("l3 slot != q");
        if (gt_gptk_line(&m, "l2 = \\\"")) return fail("quote placeholder parsed");
        if (gt_gptk_line(&m, "deadzone = 2000")) return fail("deadzone config line is not a mapping (returns 0)");
        if (m.deadzone != 2000) return fail("deadzone = 2000 not honored");
        if (!gt_gptk_line(&m, "left_analog_up = up")) return fail("F53: analog line must map");
        if (m.analog_key[0][0].sym != (GT_SCANCODE_MASK | 82)) return fail("left_analog_up != Up key");
        if (gt_gptk_line(&m, "# comment")) return fail("comment parsed");
        if (m.button_key[1].sym != ' ') return fail("A slot != space");
        if (m.button_key[0].sym != 's') return fail("B slot != s");
        if (m.button_key[6].sym != 27) return fail("back slot != esc");
        if (m.button_key[7].sym != 'w') return fail("start slot != w");
        if (m.dir_key[0].sym != (GT_SCANCODE_MASK | 82)) return fail("up dir != Up key");
        if (!m.loaded) return fail("map not marked loaded");
        /* F65: r3 is rc11 b10; l2/r2 are trigger keys, never button slots */
        if (!gt_gptk_line(&m, "r3 = e")) return fail("parse r3=e");
        if (m.button_key[10].sym != 'e') return fail("F65: r3 slot != 10");
        if (!gt_gptk_line(&m, "l2 = left")) return fail("parse l2=left");
        if (!gt_gptk_line(&m, "r2 = right")) return fail("parse r2=right");
        if (m.trigger_key[0].sym != (GT_SCANCODE_MASK | 80)) return fail("F65: l2 -> trigger 0");
        if (m.trigger_key[1].sym != (GT_SCANCODE_MASK | 79)) return fail("F65: r2 -> trigger 1");
        for (i = 11; i < 16; i++)
            if (m.button_key[i].sym) return fail("F65: nothing may land in button slots 11-15");
    }

    /* F48: layout swap. gt_layout_load is exercised once here (pre-F52 host
     * builds never called it under -DGT_REMAP_TEST, since it is otherwise
     * only reached from gt_init in the interposer half that this build
     * strips out, leaving it an unused-function warning until now); the two
     * branches below drive gt_ab_swap directly since the env-parsing itself
     * is asserted by this one call. */
    unsetenv("GT_CONTROLLER_LAYOUT"); gt_layout_load();
    if (gt_ab_swap) return fail("default (no GT_CONTROLLER_LAYOUT) must not swap a/b");
    gt_ab_swap = 0;
    if (gt_button_slot("a") != 1 || gt_button_slot("b") != 0) return fail("nintendo a/b slots");
    if (gt_button_slot("x") != 3 || gt_button_slot("y") != 2) return fail("nintendo x/y slots");
    if (gt_button_slot("l1") != 4) return fail("nintendo l1 slot moved");
    if (gt_button_slot("l3") != 9 || gt_button_slot("r3") != 10) return fail("F65: l3/r3 slots 9/10");
    if (gt_button_slot("l2") != -1 || gt_button_slot("r2") != -1) return fail("F65: l2/r2 are not button slots");
    if (gt_trigger_slot("l2") != 0 || gt_trigger_slot("r2") != 1) return fail("F65: l2/r2 trigger slots 0/1");
    if (gt_trigger_slot("l1") != -1) return fail("F65: l1 is not a trigger");
    gt_ab_swap = 1;
    if (gt_button_slot("a") != 0 || gt_button_slot("b") != 1) return fail("xbox a/b slots");
    if (gt_button_slot("x") != 2 || gt_button_slot("y") != 3) return fail("xbox x/y slots");
    if (gt_button_slot("l1") != 4) return fail("xbox l1 slot moved");
    if (gt_trigger_slot("l2") != 0 || gt_trigger_slot("r2") != 1) return fail("F65: xbox leaves triggers alone");
    gt_ab_swap = 0;

    /* F53: analog synthesis — gptokeyb parity (PortsMaster/gptokeyb structs.h
     * defaults, keyboard.cpp deadzone semantics). */
    if (gt_keyname("home").scancode != 74 || gt_keyname("home").sym != (GT_SCANCODE_MASK | 74)) return fail("keyname home");
    if (gt_keyname("end").scancode  != 77 || gt_keyname("end").sym  != (GT_SCANCODE_MASK | 77)) return fail("keyname end");
    {
        gt_keymap m; memset(&m, 0, sizeof m);
        gt_keymap_defaults(&m);
        if (m.analog_key[0][0].sym != 'w' || m.analog_key[0][1].sym != 's' ||
            m.analog_key[0][2].sym != 'a' || m.analog_key[0][3].sym != 'd') return fail("left analog defaults w/s/a/d");
        if (m.analog_key[1][0].sym != (GT_SCANCODE_MASK | 77) ||   /* up = End */
            m.analog_key[1][1].sym != (GT_SCANCODE_MASK | 74) ||   /* down = Home */
            m.analog_key[1][2].sym != (GT_SCANCODE_MASK | 80) ||   /* left */
            m.analog_key[1][3].sym != (GT_SCANCODE_MASK | 79))     /* right */
            return fail("right analog defaults end/home/left/right");
        if (m.deadzone != 15000) return fail("deadzone default 15000");
        if (m.loaded) return fail("defaults alone must not mark the map loaded");
        if (!gt_gptk_line(&m, "left_analog_up = i")) return fail("parse left_analog_up=i");
        if (m.analog_key[0][0].sym != 'i' || !m.loaded) return fail("left_analog_up override");
        if (!gt_gptk_line(&m, "left_analog_down = \\\"")) return fail("placeholder analog line must count as present");
        if (m.analog_key[0][1].sym != 0) return fail("placeholder must CLEAR the default");
        if (!gt_gptk_line(&m, "left_analog_left = nosuchkey")) return fail("unknown analog value counts as present");
        if (m.analog_key[0][2].sym != 0) return fail("unknown analog value must clear");
        if (!gt_gptk_line(&m, "right_analog_left = mouse_movement_left")) return fail("parse mouse_movement");
        if (!m.analog_mouse[1]) return fail("mouse_movement marks the right stick mouse-driven");
        if (m.analog_key[1][2].sym != 0) return fail("mouse direction cleared");
        if (m.analog_mouse[0]) return fail("left stick must not be marked mouse");
        if (gt_gptk_line(&m, "deadzone = 20000")) return fail("deadzone is config, returns 0");
        if (m.deadzone != 20000) return fail("deadzone 20000");
        gt_gptk_line(&m, "deadzone = 0");     if (m.deadzone != 20000) return fail("deadzone 0 rejected");
        gt_gptk_line(&m, "deadzone = 99999"); if (m.deadzone != 20000) return fail("deadzone 99999 rejected");
        gt_gptk_line(&m, "deadzone = abc");   if (m.deadzone != 20000) return fail("deadzone abc rejected");
        gt_gptk_line(&m, "deadzone = 32767"); if (m.deadzone != 32767) return fail("deadzone 32767 accepted");
        gt_gptk_line(&m, "deadzone = 1");     if (m.deadzone != 1) return fail("deadzone 1 accepted");
        if (gt_gptk_line(&m, "deadzone_x = 5000")) return fail("deadzone_x stays ignored");
        if (gt_gptk_line(&m, "left_analog_up_repeat = true")) return fail("repeat flags stay ignored");
    }
    /* axis value -> direction, per-axis (gptokeyb: zero iff |v| < deadzone) */
    if (gt_axis_dir(14999, 15000) != 0)   return fail("14999 inside deadzone");
    if (gt_axis_dir(15000, 15000) != 1)   return fail("15000 deflected +");
    if (gt_axis_dir(-15000, 15000) != -1) return fail("-15000 deflected -");
    if (gt_axis_dir(27935, 15000) != 1)   return fail("short-range max still deflects");
    if (gt_axis_dir(-32768, 15000) != -1) return fail("full negative");
    if (gt_axis_dir(0, 15000) != 0)       return fail("centered");
    if (gt_axis_dir(500, 1) != 1)         return fail("deadzone 1: any offset deflects");
    /* F65 axis -> stick + slot ends: rc11 a0/a1 = left X/Y, a3/a4 = right X/Y;
     * X: left 2 / right 3, Y: up 0 / down 1; a2/a5 are triggers, not sticks */
    {
        int st, sn, sp;
        if (!gt_axis_slots(0, &st, &sn, &sp) || st != 0 || sn != 2 || sp != 3) return fail("axis 0 = left X");
        if (!gt_axis_slots(1, &st, &sn, &sp) || st != 0 || sn != 0 || sp != 1) return fail("axis 1 = left Y");
        if (!gt_axis_slots(3, &st, &sn, &sp) || st != 1 || sn != 2 || sp != 3) return fail("axis 3 = right X");
        if (!gt_axis_slots(4, &st, &sn, &sp) || st != 1 || sn != 0 || sp != 1) return fail("axis 4 = right Y");
        if (gt_axis_slots(2, &st, &sn, &sp) || gt_axis_slots(5, &st, &sn, &sp)) return fail("axes 2/5 are triggers, not sticks");
        if (gt_axis_slots(6, &st, &sn, &sp)) return fail("axis 6 is not a stick");
    }
    /* F65 triggers: a2 = L2 (0), a5 = R2 (1); pressed iff value > 0, edges only */
    if (gt_trigger_index(2) != 0 || gt_trigger_index(5) != 1) return fail("trigger axes 2/5");
    if (gt_trigger_index(0) != -1 || gt_trigger_index(3) != -1) return fail("stick axes are not triggers");
    {
        int held = 0;
        if (gt_trigger_edge(&held, -32768) != -1) return fail("released seed is no edge");
        if (gt_trigger_edge(&held, 32767) != 1 || !held) return fail("trigger press");
        if (gt_trigger_edge(&held, 32767) != -1) return fail("repeat / re-pass is no edge");
        if (gt_trigger_edge(&held, -32768) != 0 || held) return fail("trigger release");
        if (gt_trigger_edge(&held, 0) != -1) return fail("0 counts as released");
    }
    /* edge sequence on a Y axis: center -> up (press up), up -> down through
     * center (release up BEFORE press down), down -> center (release down) */
    {
        int es[2], ep[2], en;
        en = gt_evdev_hat_edges(0, -1, 0, 1, es, ep);
        if (en != 1 || es[0] != 0 || ep[0] != 1) return fail("stick center->up");
        en = gt_evdev_hat_edges(-1, 1, 0, 1, es, ep);
        if (en != 2 || es[0] != 0 || ep[0] != 0 || es[1] != 1 || ep[1] != 1) return fail("stick up->down releases first");
        en = gt_evdev_hat_edges(1, 0, 0, 1, es, ep);
        if (en != 1 || es[0] != 1 || ep[0] != 0) return fail("stick down->center");
        en = gt_evdev_hat_edges(1, 1, 0, 1, es, ep);
        if (en != 0) return fail("held stick emits nothing");
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

    /* v3: synthetic keystate array + merge (state-polling half) */
    {
        unsigned char synth[GT_NUM_SCANCODES];
        memset(synth, 0, sizeof synth);
        gt_synth_set(synth, 26, 1);              /* 'w' scancode down */
        if (synth[26] != 1) return fail("synth set key down");
        gt_synth_set(synth, 26, 0);              /* 'w' up */
        if (synth[26] != 0) return fail("synth clear key up");
        gt_synth_set(synth, -1, 1);              /* out of range: no crash */
        gt_synth_set(synth, GT_NUM_SCANCODES, 1);

        unsigned char real[GT_NUM_SCANCODES], out[GT_NUM_SCANCODES];
        memset(real, 0, sizeof real);
        memset(out, 0, sizeof out);
        real[44] = 1;                            /* space held on a real keyboard */
        synth[82] = 1;                           /* Up synthesized by the shim */
        gt_merge_keystate(out, real, synth, GT_NUM_SCANCODES);
        if (out[44] != 1) return fail("merge keeps real key");
        if (out[82] != 1) return fail("merge adds synth key");
        if (out[26] != 0) return fail("merge leaves untouched key clear");
    }

    /* HUD: SharedSettings decode */
    {
        unsigned char ss[GT_SS_LEN]; memset(ss, 0, sizeof ss);
        int vol = 10, bri = 7;
        memcpy(ss + GT_SS_OFF_VOLUME, &vol, 4);
        memcpy(ss + GT_SS_OFF_BRIGHTNESS, &bri, 4);
        gt_metrics m; memset(&m, 0, sizeof m);
        if (!gt_shared_settings_decode(ss, GT_SS_LEN, &m)) return fail("ss decode");
        if (m.volume != 10 || m.brightness != 7) return fail("ss values");
        /* F57: NextUI h700-rc10 shrank /dev/shm/SharedSettings to 64 bytes.
         * Decode must succeed on any buffer that reaches through the volume
         * int32 — the old exact-132 guard rejected the 64-byte block and left
         * both gauges dead. */
        if (!gt_shared_settings_decode(ss, 64, &m)) return fail("64-byte (rc10) layout must decode");
        if (m.volume != 10 || m.brightness != 7) return fail("64-byte ss values");
        /* boundary: a buffer that stops before the volume int32 ends must fail
         * (guarding against an out-of-bounds read of the volume field). */
        if (!gt_shared_settings_decode(ss, GT_SS_OFF_VOLUME + 3, &m)) {} else return fail("sub-volume buf must fail");
        if (!gt_shared_settings_decode(ss, 4, &m)) {} else return fail("short buf must fail");
    }
    /* HUD: battery + time text formatters (pure) */
    {
        gt_metrics m; memset(&m, 0, sizeof m);
        gt_battery_parse("16\n", "Charging\n", &m);
        if (m.battery_pct != 16 || !m.charging) return fail("battery parse");
        char bt[8]; gt_fmt_battery(&m, bt, sizeof bt);
        if (strcmp(bt, "+16%")) return fail("fmt battery charging");   /* + when charging */
        gt_battery_parse("83\n", "Discharging\n", &m);
        if (m.battery_pct != 83 || m.charging) return fail("battery discharge");
        gt_fmt_battery(&m, bt, sizeof bt);
        if (strcmp(bt, "83%")) return fail("fmt battery discharging"); /* no + otherwise */
        m.hour = 13; m.minute = 31;
        char tt[8]; gt_fmt_time(&m, tt, sizeof tt);
        if (strcmp(tt, "13:31")) return fail("fmt time");
    }
    /* HUD: time-of-day setter (pure struct-tm -> gt_metrics, no localtime) */
    {
        gt_metrics m; memset(&m, 0, sizeof m);
        struct tm t; memset(&t, 0, sizeof t);
        t.tm_hour = 13; t.tm_min = 31;
        gt_time_set(&m, &t);
        if (m.hour != 13 || m.minute != 31) return fail("time set");
        char tt[8]; gt_fmt_time(&m, tt, sizeof tt);
        if (strcmp(tt, "13:31")) return fail("time set fmt");
    }

    /* HUD: compose layout — dims, left labels, right-aligned values, gauges,
     * and row order (Battery, Brightness, Volume, Time). */
    {
        static uint32_t buf[GT_HUD_MAX_W * GT_HUD_MAX_H];
        int w = 0, hh = 0;
        gt_metrics m; memset(&m, 0, sizeof m);
        m.battery_pct = 42; m.charging = 1; m.volume = 10; m.brightness = 5; m.hour = 9; m.minute = 5;
        gt_hud_compose(&m, buf, &w, &hh);
        /* (a) panel dims == the macros */
        if (w != GT_HUD_MAX_W || hh != GT_HUD_MAX_H) return fail("hud dims");
        if (buf[0] != GT_HUD_BG) return fail("hud bg corner");
        int right_x = w - GT_HUD_PAD;
        int gauge_x = right_x - GT_HUD_GAUGE_W;
        int row_y[GT_HUD_ROWS];
        for (int r = 0; r < GT_HUD_ROWS; r++)
            row_y[r] = GT_HUD_PAD + r * (GT_CELL_H + GT_HUD_LINE_GAP);
        /* (b) each label has FG pixels in its first-glyph band at the left pad */
        for (int r = 0; r < GT_HUD_ROWS; r++)
            if (gt_count_fg(buf, w, GT_HUD_PAD, row_y[r], GT_HUD_PAD + GT_CELL_W,
                            row_y[r] + GT_CELL_H) == 0)
                return fail("label not at left pad");
        /* (c) battery (row 0) + time (row 3): rightmost FG pixel within one
         * glyph of the common right edge */
        for (int ri = 0; ri < 2; ri++) {
            int r = ri ? 3 : 0, maxx = -1;
            for (int y = row_y[r]; y < row_y[r] + GT_CELL_H; y++)
                for (int x = 0; x < w; x++)
                    if (buf[y * w + x] == GT_HUD_FG && x > maxx) maxx = x;
            if (maxx > right_x || maxx < right_x - GT_CELL_W) return fail("value not right-aligned");
        }
        /* (d) gauge proportionality on the brightness row (row 1): full > half >
         * 0, and 0% leaves the inner region empty */
        {
            int gx0 = gauge_x + GT_HUD_SCALE, gy0 = row_y[1] + GT_HUD_SCALE;
            int gx1 = gauge_x + GT_HUD_GAUGE_W - GT_HUD_SCALE;
            int gy1 = row_y[1] + GT_HUD_GAUGE_H - GT_HUD_SCALE;
            gt_metrics g = m;
            g.brightness = GT_SS_BRIGHTNESS_MAX;     gt_hud_compose(&g, buf, &w, &hh);
            int full = gt_count_fg(buf, w, gx0, gy0, gx1, gy1);
            g.brightness = GT_SS_BRIGHTNESS_MAX / 2; gt_hud_compose(&g, buf, &w, &hh);
            int half = gt_count_fg(buf, w, gx0, gy0, gx1, gy1);
            g.brightness = 0;                        gt_hud_compose(&g, buf, &w, &hh);
            int zero = gt_count_fg(buf, w, gx0, gy0, gx1, gy1);
            if (!(full > half && half > zero)) return fail("gauge not proportional");
            if (zero != 0) return fail("0% gauge must be empty inside");
        }
        /* (e) row order via structure: gauges are rows 1 (BRIGHTNESS) & 2
         * (VOLUME) — a solid FG bar spanning the full gauge width at the row top;
         * text rows 0 (BATTERY) & 3 (TIME) have no such solid bar. */
        gt_hud_compose(&m, buf, &w, &hh);
        for (int r = 0; r < GT_HUD_ROWS; r++) {
            int solid = 1;
            for (int x = gauge_x; x < gauge_x + GT_HUD_GAUGE_W; x++)
                if (buf[row_y[r] * w + x] != GT_HUD_FG) { solid = 0; break; }
            int want = (r == 1 || r == 2);
            if (solid != want) return fail("row order / gauge placement");
        }
        /* placement stays on-screen (top-right) */
        int x = 0, y = 0; gt_hud_rect(640, 480, w, hh, &x, &y);
        if (x + w > 640 || x < 0 || y < 0) return fail("hud rect top-right");
    }

    /* HUD: Menu single-tap toggle (flip on clean release, swallow both Menu
     * edges, other-button-during-hold disqualifies the tap) */
    { gt_tap_state s; memset(&s, 0, sizeof s); int vis = 0;
      if (!gt_menu_toggle(&s,&vis,1,1) || vis != 0) return fail("menu down: swallow, no flip yet");
      if (!gt_menu_toggle(&s,&vis,1,0) || vis != 1) return fail("menu up clean: flip on");
      if (!gt_menu_toggle(&s,&vis,1,1) || vis != 1) return fail("menu down2: swallow, no flip");
      if (!gt_menu_toggle(&s,&vis,1,0) || vis != 0) return fail("menu up clean2: flip off");
      if (!gt_menu_toggle(&s,&vis,1,1)) return fail("menu down3");
      if (gt_menu_toggle(&s,&vis,0,1)) return fail("other-button must not be swallowed"); /* Vol during hold */
      if (!gt_menu_toggle(&s,&vis,1,0) || vis != 0) return fail("menu up after combo: no flip");
      if (gt_menu_toggle(&s,&vis,0,1)) return fail("lone non-menu must not be swallowed"); }

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

    /* F65: rc11 Menu = one clean b8 (no ESC, no GOTO echo); the SDL path
     * swallows exactly b8 and nothing else in the pad's range. */
    { gt_tap_state s; memset(&s,0,sizeof s); int vis = 0;
      if (!gt_is_menu_button(8)) return fail("b8 is Menu");
      for (i = 0; i <= 14; i++)
          if (i != 8 && gt_is_menu_button((unsigned char)i)) return fail("only b8 is Menu");
      /* clean b8 tap (one down + one up) -> exactly one flip */
      gt_menu_toggle(&s,&vis,gt_is_menu_button(8),1);
      gt_menu_toggle(&s,&vis,gt_is_menu_button(8),0);
      if (vis != 1) return fail("clean b8 tap must flip once");
      /* Menu + Vol- (b13) during the hold -> no flip (disqualified) */
      memset(&s,0,sizeof s); vis = 0;
      gt_menu_toggle(&s,&vis,gt_is_menu_button(8),1);
      gt_menu_toggle(&s,&vis,gt_is_menu_button(13),1);
      gt_menu_toggle(&s,&vis,gt_is_menu_button(8),0);
      if (vis != 0) return fail("Menu+Vol combo must not flip"); }

    /* F65: evdev code -> slot equals rc11's own code -> SDL index table
     * (sdl2-h700.patch h700_buttons) for every gameplay button; Menu, GOTO,
     * ESC, Vol and L2/R2 get no button slot; L2/R2 are triggers 0/1. */
    {
        static const int code[] = {305, 304, 306, 307, 308, 309, 310, 311, 313, 316};
        static const int idx[]  = {  0,   1,   2,   3,   4,   5,   6,   7,   9,  10};
        for (i = 0; i < sizeof code / sizeof code[0]; i++)
            if (gt_evdev_code_slot(code[i]) != idx[i]) return fail("evdev slot != rc11 SDL index");
        static const int none[] = {312, 354, 1, 114, 115, 314, 315};
        for (i = 0; i < sizeof none / sizeof none[0]; i++)
            if (gt_evdev_code_slot(none[i]) != -1) return fail("non-gameplay evdev code got a button slot");
        if (gt_evdev_trigger_slot(314) != 0 || gt_evdev_trigger_slot(315) != 1) return fail("evdev 314/315 -> triggers 0/1");
        if (gt_evdev_trigger_slot(313) != -1 || gt_evdev_trigger_slot(316) != -1) return fail("stick clicks are not triggers");
    }

    /* F45: evdev hat edges — release-before-press, center + straight-through */
    {
        int es[2], ep[2], en;
        en = gt_evdev_hat_edges(0, -1, 2, 3, es, ep);   /* center -> left */
        if (en != 1 || es[0] != 2 || ep[0] != 1) return fail("evdev hat 0->left");
        en = gt_evdev_hat_edges(-1, 1, 2, 3, es, ep);   /* left -> right (through center) */
        if (en != 2 || ep[0] != 0 || es[0] != 2 || ep[1] != 1 || es[1] != 3) return fail("evdev hat left->right");
        en = gt_evdev_hat_edges(1, 0, 2, 3, es, ep);    /* right -> center */
        if (en != 1 || es[0] != 3 || ep[0] != 0) return fail("evdev hat right->center");
        en = gt_evdev_hat_edges(-1, -1, 0, 1, es, ep);  /* no change */
        if (en != 0) return fail("evdev hat no-change");
        en = gt_evdev_hat_edges(0, 1, 0, 1, es, ep);    /* center -> down (Y axis) */
        if (en != 1 || es[0] != 1 || ep[0] != 1) return fail("evdev hat 0->down");
    }

    /* F54: SDL_EVDEV_DEVICES string + parser selection rule */
    {
        char env[80], node[64];
        if (!gt_evdev_env_build(env, sizeof env, "/dev/input/event3") || strcmp(env, "3:/dev/input/event3"))
            return fail("evdev env string");
        if (gt_evdev_env_build(env, 8, "/dev/input/event3"))
            return fail("evdev env string: too-small buffer must fail");
        static const char two[] =
            "I: Bus=0003 Vendor=0000 Product=0000 Version=0000\n"
            "N: Name=\"Fake Keyboard\"\n"
            "S: Sysfs=/devices/virtual/input/input6\n"
            "H: Handlers=sysrq kbd event3 \n"
            "B: EV=7\n"
            "\n"
            "I: Bus=0003 Vendor=0000 Product=0000 Version=0000\n"
            "N: Name=\"Fake Keyboard\"\n"
            "S: Sysfs=/devices/virtual/input/input5\n"
            "H: Handlers=sysrq kbd event4 \n"
            "B: EV=7\n";                         /* no trailing blank line on purpose */
        if (!gt_fake_kbd_resolve(two, node, sizeof node) || strcmp(node, "/dev/input/event3"))
            return fail("fake kbd: highest inputN (input6 -> event3) must beat the higher eventN");
        if (gt_fake_kbd_resolve("N: Name=\"Fake Keyboards\"\nS: Sysfs=/devices/virtual/input/input9\n"
                                "H: Handlers=kbd event9 \n\n", node, sizeof node))
            return fail("fake kbd: name must match exactly");
        if (gt_fake_kbd_resolve("N: Name=\"Fake Keyboard\"\nH: Handlers=kbd event9 \n\n", node, sizeof node))
            return fail("fake kbd: stanza without Sysfs line is ignored");
        if (gt_fake_kbd_resolve("", node, sizeof node))
            return fail("fake kbd: empty buffer -> none");
        if (!gt_fake_kbd_resolve("N: Name=\"Fake Keyboard\"\nS: Sysfs=/devices/virtual/input/input2\n"
                                 "H: Handlers=event7", node, sizeof node) || strcmp(node, "/dev/input/event7"))
            return fail("fake kbd: handler directly after '=' and no trailing newline");
        static const char cl_map[]    = "gptokeyb\0-1\0love.aarch64\0-c\0bytepath.gptk";
        static const char cl_nomap[]  = "gptokeyb\0-1\0love.aarch64";
        static const char cl_joined[] = "gptokeyb\0-cbytepath.gptk";
        if (!gt_cmdline_has_arg(cl_map, sizeof cl_map, "-c"))
            return fail("cmdline: a whole -c argument must be found");
        if (gt_cmdline_has_arg(cl_nomap, sizeof cl_nomap, "-c"))
            return fail("cmdline: no -c must read as no mapping");
        if (gt_cmdline_has_arg(cl_joined, sizeof cl_joined, "-c"))
            return fail("cmdline: -c must match a whole argument, not a prefix");
        if (gt_cmdline_has_arg(cl_map, 0, "-c"))
            return fail("cmdline: empty buffer holds no argument");
    }

    puts("remap ok");
    return 0;
}

#else /* the real interposer */

#include <dlfcn.h>
#include <fcntl.h>     /* open, O_RDONLY — HUD device sampler (Task 4) */
#include <unistd.h>    /* read, close — HUD device sampler */
#include <SDL2/SDL.h>
#include <GLES2/gl2.h> /* GL types + enum constants only; NO link dependency —
                        * every entry point is resolved at runtime (Task 4). */
#include <EGL/egl.h>   /* eglGetProcAddress / eglSwapBuffers prototypes only */
#include <pthread.h>       /* F35: evdev toggle thread */
#include <dirent.h>        /* scan /dev/input for the Menu device */
#include <sys/ioctl.h>     /* EVIOCGBIT / EVIOCGNAME */
#include <linux/input.h>   /* struct input_event, EV_KEY, KEY_MAX */
#include <string.h>        /* strncmp, memset */
#include <errno.h>         /* EINTR */

static void gt_announce(int final);   /* F54: once-only log, defined with the passthrough block */

static int gt_debug(void) {
    static int v = -1;
    if (v < 0) {
        const char *e = getenv("GT_INPUT_REMAP_DEBUG");
        v = (e && *e) ? 1 : 0;
    }
    return v;
}

/* F34: env-flag gating for the HUD half, decoupled from v2/v3 gptk synthesis
 * (which stays keyed on gt_map.loaded). F65 removed the v1 index remap and
 * with it the GT_INPUT_REMAP flag. */
static int gt_flag(const char *name) {
    const char *e = getenv(name); return (e && *e && e[0] != '0') ? 1 : 0;
}
static int gt_hud_on(void)    { static int v = -1; if (v < 0) v = gt_flag("GT_HUD"); return v; }
static int gt_hud_debug(void) { static int v = -1; if (v < 0) v = gt_flag("GT_HUD_DEBUG"); return v; }
/* F45: opt-in evdev->key synthesis (only OpenCrossing sets it; see the evdev
 * thread). Kept separate from GT_HUD so a port can use one without the other. */
static int gt_evdev_keys_on(void) { static int v = -1; if (v < 0) v = gt_flag("GT_EVDEV_KEYS"); return v; }

/* HUD visibility. Written ONLY by the evdev toggle thread (Task 3); read by
 * the GL and software draw paths. volatile so the reader never caches it in a
 * register across frames; a single word on this target is written atomically. */
static volatile int gt_hud_visible;

/* F35: universal evdev toggle. A detached thread reads the Menu button from
 * /dev/input/event* — BELOW mono P/Invoke, gptokeyb, and SDL — so the toggle
 * works on every engine (Celeste/mono and Apotris/gptokeyb included, where no
 * SDL interposer ever fires). Non-grabbing, so keymon + the game keep the
 * button. gt_tap is owned solely by this thread (the SDL path no longer
 * toggles — Decision A). */
static gt_tap_state gt_tap;

/* The gptk keymap and the synthetic keystate array. Declared here — ahead of
 * the evdev thread, which for F45 also maps gamepad codes into gt_synth_keys —
 * though most writers/readers are the SDL-path interposers further below. */
static gt_keymap gt_map;
static unsigned char gt_synth_keys[GT_NUM_SCANCODES];

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
        char path[280];   /* "/dev/input/" + dirent d_name (up to 256) */
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
    int fd = gt_open_menu_device();   /* event1 also carries the gamepad codes */
    if (fd < 0) {
        if (gt_hud_debug()) fprintf(stderr, "gt-hud: no evdev Menu device -> toggle disabled\n");
        return NULL;
    }
    const int keys_on = gt_evdev_keys_on() && gt_map.loaded;  /* F45 gameplay synth */
    int hat_x = 0, hat_y = 0;                                 /* D-pad axis edge state */
    for (;;) {
        struct input_event ev;
        ssize_t n = read(fd, &ev, sizeof ev);
        if (n != (ssize_t)sizeof ev) {
            if (n < 0 && errno == EINTR) continue;
            break;   /* device gone / error -> exit thread (benign) */
        }
        if (ev.type == EV_KEY) {
            if (ev.value == 2) continue;   /* skip autorepeat */
            int down = (ev.value == 1);
            int cls  = gt_evkey_class(ev.code);
            if (cls == GT_EVK_MENU) {
                gt_menu_toggle(&gt_tap, &gt_hud_visible, 1, down);
                if (gt_hud_debug() && !down)
                    fprintf(stderr, "gt-input-remap: HUD toggle -> %s\n",
                            gt_hud_visible ? "on" : "off");
            } else if (cls == GT_EVK_VOL) {
                gt_menu_toggle(&gt_tap, &gt_hud_visible, 0, down);
            } else if (keys_on) {
                /* F45/F52/F65: gameplay button or L2/R2 -> synthesized
                 * keystate, straight from the evdev code (see gt_evdev_code_slot). */
                int slot = gt_evdev_code_slot(ev.code), t = -1;
                gt_key k = {0, 0};
                if (slot >= 0 && slot < 16) k = gt_map.button_key[slot];
                else if ((t = gt_evdev_trigger_slot(ev.code)) >= 0) k = gt_map.trigger_key[t];
                if (k.sym) {
                    gt_synth_set(gt_synth_keys, k.scancode, down);
                    if (gt_debug())
                        fprintf(stderr, "gt-input-remap: evdev btn %d -> %s %d key 0x%x (%s)\n",
                                (int)ev.code, t >= 0 ? "trigger" : "slot", t >= 0 ? t : slot,
                                (unsigned)k.sym, down ? "down" : "up");
                }
            }
        } else if (ev.type == EV_ABS && keys_on) {
            /* F45: D-pad hat (ABS_HAT0X/Y, -1/0/+1) -> direction keys. */
            int slots[2], pressed[2], m = 0, i;
            if (ev.code == ABS_HAT0X)      { m = gt_evdev_hat_edges(hat_x, ev.value, 2, 3, slots, pressed); hat_x = ev.value; }
            else if (ev.code == ABS_HAT0Y) { m = gt_evdev_hat_edges(hat_y, ev.value, 0, 1, slots, pressed); hat_y = ev.value; }
            for (i = 0; i < m; i++) {
                gt_key k = gt_map.dir_key[slots[i]];
                if (k.sym) {
                    gt_synth_set(gt_synth_keys, k.scancode, pressed[i]);
                    if (gt_debug())
                        fprintf(stderr, "gt-input-remap: evdev hat %d=%d -> dir %d key 0x%x (%s)\n",
                                (int)ev.code, (int)ev.value, slots[i], (unsigned)k.sym,
                                pressed[i] ? "down" : "up");
                }
            }
        }
    }
    close(fd);
    return NULL;
}

/* F35 fix: start the evdev toggle thread lazily, ONCE, and only in a process
 * that actually presents frames (the game). Constructor-start put a blocked
 * evdev reader in every LD_PRELOAD'd helper (bash, busybox tee, gptokeyb),
 * which added ~8s to port exit. Helpers never call the present interposers. */
static pthread_once_t gt_evdev_once = PTHREAD_ONCE_INIT;
static void gt_evdev_start_once(void) {
    pthread_t t;
    if (pthread_create(&t, NULL, gt_evdev_thread, NULL) == 0)
        pthread_detach(t);
    else if (gt_hud_debug())
        fprintf(stderr, "gt-hud: evdev thread start failed -> toggle disabled\n");
}
static void gt_evdev_ensure(void) {
    if (gt_hud_on() || gt_evdev_keys_on())
        pthread_once(&gt_evdev_once, gt_evdev_start_once);
}

/* v2 state: the pending-event stash (a single hat transition can yield up to
 * 4 key events; the first replaces the hat event, the rest are served on
 * subsequent polls before SDL is consulted). Single-threaded event pumping is
 * assumed, as elsewhere in this shim. gt_map is declared earlier now (the F45
 * evdev thread also reads it). */
static SDL_Event gt_stash[8];
static int gt_stash_n;
static int gt_hat_prev;
static int gt_axis_prev[6];  /* F53: per-axis last direction (-1/0/+1), rc11 axes 0..5 */
static int gt_trigger_held[2]; /* F65: per-trigger pressed state (gt_trigger_edge) */

/* v3 state-polling half: the synthetic keyboard-state array (set as keys are
 * synthesized) and the merged buffer handed to the app. gt_ks_active flips on
 * once the app calls SDL_GetKeyboardState — after that every event poll
 * refreshes the merged buffer, because SDL apps (LÖVE among them) grab the
 * state pointer ONCE and then just index it every frame. gt_synth_keys is
 * declared earlier now (the F45 evdev thread also writes it). */
static Uint8 gt_merged_keys[GT_NUM_SCANCODES];
static int gt_ks_numkeys;
static int gt_ks_active;

/* F54: the gptk is parsed here, but NOTHING is printed. This constructor runs
 * in every LD_PRELOAD'd child of run_port — bash, busybox tee, gptokeyb — and
 * used to spam "loaded"/"HUD enabled"/"keyboard synthesis on" once per child.
 * gt_announce() prints the same lines exactly once, from the first SDL entry
 * point the shim sees, i.e. in the game. */
static int gt_gptk_status;          /* 0 = no GT_REMAP_GPTK, 1 = parsed, -1 = cannot open */
static const char *gt_gptk_path;
static int gt_gptk_n;

__attribute__((constructor))
static void gt_init(void) {
    gt_layout_load(); /* F48: independent of GT_REMAP_GPTK/GT_EVDEV_KEYS below */
    gt_class_load();  /* F52: plain (RG SP) unless launch.sh exported GT_INPUT_CLASS=sticks */
    const char *path = getenv("GT_REMAP_GPTK");
    if (!path || !*path) return;
    gt_gptk_path = path;
    FILE *fh = fopen(path, "r");
    if (!fh) { gt_gptk_status = -1; return; }
    gt_keymap_defaults(&gt_map);   /* F53: gptokeyb analog defaults; a parsed line overrides */
    char line[256];
    int n = 0;
    while (fgets(line, sizeof line, fh))
        n += gt_gptk_line(&gt_map, line);
    fclose(fh);
    gt_gptk_n = n;
    gt_gptk_status = 1;
}

/* ======================================================================
 * F54: gptokeyb passthrough (device half; pure helpers live above the
 * GT_REMAP_TEST split). Decided ONCE, at the first SDL_Init/SDL_InitSubSystem
 * that brings up SDL_INIT_VIDEO — the video driver is what runs
 * SDL_EVDEV_Init — in the game process only. On activation the gptk is
 * unloaded: every synthesis path (v2 buttons/hats, F53 axes, F31 keystate
 * merge, F45 evdev keys) keys on gt_map.loaded, so gptokeyb's real keyboard
 * and mouse become the only source and nothing is delivered twice. Ports
 * whose gptokeyb creates no keyboard (no -c mapping, e.g. Animal Crossing's
 * pak launcher) or that run none keep the fallback. */
enum gt_pt_state_e {
    GT_PT_UNDECIDED = 0,   /* no video init seen yet */
    GT_PT_ACTIVE,          /* SDL_EVDEV_DEVICES exported, synthesis off */
    GT_PT_NO_GPTOKEYB,     /* no gptokeyb process: synthesis fallback */
    GT_PT_NO_NODE,         /* gptokeyb runs but no Fake Keyboard node within the wait */
    GT_PT_NO_MAPPING,      /* gptokeyb runs without -c: it never creates a keyboard, so no wait */
    GT_PT_DISABLED,        /* GT_PASSTHROUGH=0 (blocklisted by run_port) */
    GT_PT_PRESET,          /* the launcher set SDL_EVDEV_DEVICES itself: untouched */
    GT_PT_SELF             /* this process IS gptokeyb (inherited preload) */
};
static enum gt_pt_state_e gt_pt_state;
static char gt_pt_env[96];          /* "3:/dev/input/eventN", kept for the log */

#define GT_PT_WAIT_MS 2000
#define GT_PT_POLL_MS 50

/* /proc/<pid>/comm = the 15-char task name + '\n'. Prefix match covers
 * gptokeyb and gptokeyb2 (both name their uinput device "Fake Keyboard"). */
static int gt_comm_is_gptokeyb(const char *path) {
    char comm[32];
    if (gt_read_whole(path, comm, sizeof comm) <= 0) return 0;
    return strncmp(comm, "gptokeyb", 8) == 0;
}

/* 0 = no gptokeyb-named process other than ourselves; 1 = gptokeyb running
 * without a mapping (no -c: it never creates the Fake Keyboard); 2 = at
 * least one gptokeyb started with -c. No session/pgrp filter: a stale
 * gptokeyb from a crashed launcher injects keys on every other CFW too, so
 * attaching to it is the faithful behavior (documented limit). */
static int gt_gptokeyb_state(void) {
    DIR *d = opendir("/proc");
    if (!d) return 0;
    struct dirent *e; int st = 0; pid_t self = getpid();
    while (st < 2 && (e = readdir(d))) {
        if (e->d_name[0] < '0' || e->d_name[0] > '9') continue;
        if ((pid_t)atol(e->d_name) == self) continue;
        char path[288];   /* "/proc/" + d_name (<=255) + "/cmdline": no -Wformat-truncation */
        snprintf(path, sizeof path, "/proc/%s/comm", e->d_name);
        if (!gt_comm_is_gptokeyb(path)) continue;
        char cl[4096];
        snprintf(path, sizeof path, "/proc/%s/cmdline", e->d_name);
        long n = gt_read_whole(path, cl, sizeof cl);
        int s = (n > 0 && gt_cmdline_has_arg(cl, (size_t)n, "-c")) ? 2 : 1;
        if (s > st) st = s;
    }
    closedir(d);
    return st;
}

static int gt_fake_kbd_node(char *node, size_t nodesz) {
    static char buf[GT_INPUT_DEVICES_CAP];
    if (gt_read_whole("/proc/bus/input/devices", buf, sizeof buf) < 0) return 0;
    return gt_fake_kbd_resolve(buf, node, nodesz);
}

static void gt_passthrough_decide(void) {
    const char *pt = getenv("GT_PASSTHROUGH");
    const char *pre = getenv("SDL_EVDEV_DEVICES");
    if (pt && !strcmp(pt, "0"))  { gt_pt_state = GT_PT_DISABLED; return; }
    if (pre && *pre)             { gt_pt_state = GT_PT_PRESET;   return; }
    if (gt_comm_is_gptokeyb("/proc/self/comm")) { gt_pt_state = GT_PT_SELF; return; }
    int gk = gt_gptokeyb_state();
    if (!gk)                     { gt_pt_state = GT_PT_NO_GPTOKEYB; return; }
    char node[64];
    int waited = 0;
    while (!gt_fake_kbd_node(node, sizeof node)) {     /* gptokeyb is up; its node may lag */
        if (gk < 2)                  { gt_pt_state = GT_PT_NO_MAPPING; return; }   /* no -c: no keyboard will come */
        if (waited >= GT_PT_WAIT_MS) { gt_pt_state = GT_PT_NO_NODE; return; }
        usleep(GT_PT_POLL_MS * 1000);
        waited += GT_PT_POLL_MS;
    }
    if (!gt_evdev_env_build(gt_pt_env, sizeof gt_pt_env, node)) { gt_pt_state = GT_PT_NO_NODE; return; }
    setenv("SDL_EVDEV_DEVICES", gt_pt_env, 1);   /* overwrite=1: the precondition admits an empty value */
    gt_map.loaded = 0;                            /* the single gate of every synthesis path */
    gt_pt_state = GT_PT_ACTIVE;
}

/* Run the decision once, on the first init that brings up VIDEO. SDL_Init
 * calls SDL_InitSubSystem internally (through the PLT on some builds), so the
 * interposer below can fire twice for one app call — the guard makes the
 * second pass a no-op. */
static void gt_passthrough_on_init(Uint32 flags) {
    static int done;
    if (done || !(flags & SDL_INIT_VIDEO)) return;
    done = 1;
    gt_passthrough_decide();
}

/* The announcement, once per process, in the game only (silent inside
 * gptokeyb, which also links SDL and would otherwise print too). Two halves
 * with separate latches: "loaded" / "HUD enabled" print at the first SDL
 * entry point; the passthrough and synthesis lines wait for the decision.
 * LÖVE (and any engine that initialises EVENTS or JOYSTICK before VIDEO)
 * reaches SDL_InitSubSystem well before the video init that decides, and a
 * single latch there logged "not evaluated" and "keyboard synthesis on" for a
 * game that was running under passthrough (device gate 2026-09-27, BYTEPATH).
 * final=0 (the init interposers) defers while undecided; final=1 (the event
 * poll / present safety net) prints whatever state holds by then. */
static void gt_announce(int final) {
    static int head_done, tail_done;
    if (tail_done) return;
    if (!head_done) {
        head_done = 1;
        if (gt_comm_is_gptokeyb("/proc/self/comm")) { tail_done = 1; return; }
        fprintf(stderr, "gt-input-remap: loaded\n");
        if (gt_hud_on()) fprintf(stderr, "gt-input-remap: HUD enabled\n");
        if (gt_debug())
            fprintf(stderr, "gt-input-remap: input class %s\n", gt_sticks_class ? "sticks" : "plain");
    }
    if (!final && gt_pt_state == GT_PT_UNDECIDED) return;   /* wait for the video init */
    tail_done = 1;
    switch (gt_pt_state) {
    case GT_PT_ACTIVE:
        fprintf(stderr, "gt-input-remap: gptokeyb passthrough -> %s (synthesis off)\n", gt_pt_env);
        break;
    case GT_PT_NO_NODE:
        fprintf(stderr, "gt-input-remap: gptokeyb running but no Fake Keyboard node after %d ms -> synthesis fallback\n",
                GT_PT_WAIT_MS);
        break;
    case GT_PT_NO_MAPPING:
        if (gt_debug()) fprintf(stderr, "gt-input-remap: gptokeyb has no keyboard mapping (-c) -> no passthrough\n");
        break;
    case GT_PT_UNDECIDED:
        fprintf(stderr, "gt-input-remap: gptokeyb passthrough not evaluated (no SDL video init seen)\n");
        break;
    case GT_PT_NO_GPTOKEYB:
        if (gt_debug()) fprintf(stderr, "gt-input-remap: no gptokeyb -> synthesis fallback\n");
        break;
    case GT_PT_DISABLED:
        if (gt_debug()) fprintf(stderr, "gt-input-remap: gptokeyb passthrough disabled (GT_PASSTHROUGH=0)\n");
        break;
    case GT_PT_PRESET:
        if (gt_debug()) fprintf(stderr, "gt-input-remap: SDL_EVDEV_DEVICES preset by the launcher -> untouched\n");
        break;
    case GT_PT_SELF:
        break;
    }
    if (gt_gptk_status < 0)
        fprintf(stderr, "gt-input-remap: cannot open GT_REMAP_GPTK=%s\n", gt_gptk_path);
    else if (gt_gptk_status > 0 && gt_map.loaded)
        fprintf(stderr, "gt-input-remap: keyboard synthesis on, %d mapping(s) from %s\n", gt_gptk_n, gt_gptk_path);
    else if (gt_gptk_status > 0)
        fprintf(stderr, "gt-input-remap: keyboard synthesis off (gptokeyb passthrough)\n");
}

int SDL_Init(Uint32 flags) {
    static int (*real)(Uint32);
    if (!real) real = (int (*)(Uint32))dlsym(RTLD_NEXT, "SDL_Init");
    gt_passthrough_on_init(flags);
    gt_announce(0);
    return real ? real(flags) : -1;
}

int SDL_InitSubSystem(Uint32 flags) {
    static int (*real)(Uint32);
    if (!real) real = (int (*)(Uint32))dlsym(RTLD_NEXT, "SDL_InitSubSystem");
    gt_passthrough_on_init(flags);
    gt_announce(0);
    return real ? real(flags) : -1;
}

/* Debug-only event trace, capped so an axis-jitter flood can't fill the
 * log: first 60 events of any type, then joystick buttons only. Buttons
 * print their raw SDL index (how the rc10 table was read off the device;
 * F65: on rc11 it is the fixed TrimUI/Xbox 360 numbering). */
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
 * that also opens the pad is unaffected.
 * F54: under gptokeyb passthrough the gptk is unloaded, so this never runs
 * and a keyboard-only game receives no joystick events it would not get on
 * any other device — and the log line below is only ever true again. */
static void gt_ensure_joystick_open(void) {
    static int done;
    if (done || !gt_map.loaded) return;   /* F54: synthesis only — the HUD toggle is evdev (F35) */
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
    gt_synth_set(gt_synth_keys, k.scancode, pressed);  /* v3: mirror into the polled keystate */
    if (gt_debug())
        fprintf(stderr, "gt-input-remap: synth key sym=0x%x (%s)\n",
                (unsigned)k.sym, pressed ? "down" : "up");
}

static void gt_rewrite(SDL_Event *ev) {
    if (!ev) return;

    if (ev->type == SDL_JOYBUTTONDOWN || ev->type == SDL_JOYBUTTONUP) {
        /* v2: replace the button event with its mapped key event. F65: the
         * raw rc11 index IS the slot, so there is no remap step; an unmapped
         * button passes through untouched. */
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

    /* F65: L2/R2 -> the gptk's l2/r2 keys. rc11 reports them as trigger axes
     * 2/5; a press/release edge REPLACES the axis event with the key event.
     * An unmapped trigger, or a value that is no edge, passes through, so a
     * port that reads the trigger axis natively keeps it. */
    if (ev->type == SDL_JOYAXISMOTION && gt_map.loaded) {
        int t = gt_trigger_index(ev->jaxis.axis);
        if (t >= 0) {
            gt_key k = gt_map.trigger_key[t];
            if (!k.sym) return;
            int e = gt_trigger_edge(&gt_trigger_held[t], ev->jaxis.value);
            if (e >= 0) gt_make_key_event(ev, ev->jaxis.timestamp, k, e);
            return;
        }
    }

    /* F53: analog stick -> the gptk's analog keys. Stick-class devices only
     * (the RG SP's phantom axes never move, and plain must stay byte-for-byte
     * pre-F53). F65: rc11 sticks are a0/a1 + a3/a4 (gt_axis_slots). Same shape
     * as the hat path: release-before-press edges from gt_evdev_hat_edges, the
     * first key REPLACES the axis event, the rest ride the stash; no mapped
     * edge -> the axis passes through, so a hybrid port that reads raw axes
     * keeps them. A mouse-driven stick is left alone entirely (gptokeyb emits
     * no keys for it). */
    if (ev->type == SDL_JOYAXISMOTION && gt_map.loaded && gt_sticks_class) {
        int axis = ev->jaxis.axis, stick, sneg, spos;
        if (!gt_axis_slots(axis, &stick, &sneg, &spos)) return;
        if (gt_map.analog_mouse[stick]) return;
        int cur = gt_axis_dir(ev->jaxis.value, gt_map.deadzone);
        int slots[2], pressed[2];
        int n = gt_evdev_hat_edges(gt_axis_prev[axis], cur, sneg, spos, slots, pressed);
        if (gt_debug() && cur != gt_axis_prev[axis])
            fprintf(stderr, "gt-input-remap: axis %d %d -> dir %d\n", axis, (int)ev->jaxis.value, cur);
        gt_axis_prev[axis] = cur;
        Uint32 ts = ev->jaxis.timestamp;
        int emitted = 0, i;
        for (i = 0; i < n; i++) {
            gt_key k = gt_map.analog_key[stick][slots[i]];
            if (!k.sym) continue;
            if (!emitted) {
                gt_make_key_event(ev, ts, k, pressed[i]);              /* replace in place */
            } else if (gt_stash_n < (int)(sizeof gt_stash / sizeof gt_stash[0])) {
                gt_make_key_event(&gt_stash[gt_stash_n++], ts, k, pressed[i]);
            }
            emitted++;
        }
        return;
    }
}

/* F35 (Decision A): Menu-edge SWALLOWER for the SDL path. Runs on the raw
 * event, in the poll interposers' real-poll branch, BEFORE gt_rewrite. It
 * never toggles the HUD — the toggle authority is gt_evdev_thread, the one
 * evdev source every engine shares (mono/gptokeyb ports never reach this SDL
 * hook at all). F65: rc11 sends Menu as one clean b8, so both b8 edges are
 * swallowed (gt_is_menu_button) and every other edge passes through. Returns
 * 1 if consumed (the caller must not deliver it to the app). */
static int gt_hud_intercept(SDL_Event *ev) {
    if (!gt_hud_on() || !ev) return 0;
    if (ev->type != SDL_JOYBUTTONDOWN && ev->type != SDL_JOYBUTTONUP) return 0;
    unsigned char b = ev->jbutton.button;
    int swallow = gt_is_menu_button(b);
    if (gt_hud_debug() && swallow)
        fprintf(stderr, "gt-hud: menu b%u %s swallowed, vis=%d\n", (unsigned)b,
                ev->type == SDL_JOYBUTTONDOWN ? "down" : "up", gt_hud_visible);
    return swallow;
}

/* v3: recompute the merged keystate = SDL's real state OR the synthetic one.
 * Called from the interposed SDL_GetKeyboardState and — once the app has taken
 * our pointer — from every event poll, so a cached pointer keeps updating. */
static void gt_refresh_keystate(void) {
    static const Uint8 *(*real_gks)(int *);
    if (!real_gks)
        real_gks = (const Uint8 *(*)(int *))dlsym(RTLD_NEXT, "SDL_GetKeyboardState");
    if (!real_gks) return;
    int n = 0;
    const Uint8 *real = real_gks(&n);
    if (!real) return;
    if (n <= 0 || n > GT_NUM_SCANCODES) n = GT_NUM_SCANCODES;
    gt_ks_numkeys = n;
    gt_merge_keystate(gt_merged_keys, real, gt_synth_keys, n);
}

/* v3: hand the app OUR buffer (real | synthetic) instead of SDL's, so
 * SDL_GetKeyboardState / love.keyboard.isDown polling sees synthesized keys.
 * The buffer is static (valid for the process lifetime) and kept fresh by the
 * poll interposers below. */
const Uint8 *SDL_GetKeyboardState(int *numkeys) {
    gt_refresh_keystate();
    gt_ks_active = 1;
    if (numkeys) *numkeys = gt_ks_numkeys;
    return gt_merged_keys;
}

int SDL_PollEvent(SDL_Event *ev) {
    gt_announce(1);
    static int (*real)(SDL_Event *);
    if (!real) real = (int (*)(SDL_Event *))dlsym(RTLD_NEXT, "SDL_PollEvent");
    gt_ensure_joystick_open();
    int r;
    if (ev && gt_stash_n > 0) {
        *ev = gt_stash[0];
        gt_stash_n--;
        memmove(&gt_stash[0], &gt_stash[1], (size_t)gt_stash_n * sizeof gt_stash[0]);
        r = 1;
    } else {
        r = real(ev);
        while (r == 1 && gt_hud_intercept(ev)) r = real(ev);  /* swallow Menu */
        if (r == 1) { gt_trace("poll", ev); gt_rewrite(ev); }
    }
    if (gt_ks_active) gt_refresh_keystate();  /* keep a cached keystate pointer live */
    return r;
}

int SDL_WaitEventTimeout(SDL_Event *ev, int timeout) {
    gt_announce(1);
    static int (*real)(SDL_Event *, int);
    if (!real) real = (int (*)(SDL_Event *, int))dlsym(RTLD_NEXT, "SDL_WaitEventTimeout");
    gt_ensure_joystick_open();
    int r;
    if (ev && gt_stash_n > 0) {
        *ev = gt_stash[0];
        gt_stash_n--;
        memmove(&gt_stash[0], &gt_stash[1], (size_t)gt_stash_n * sizeof gt_stash[0]);
        r = 1;
    } else {
        r = real(ev, timeout);
        while (r == 1 && gt_hud_intercept(ev)) r = real(ev, timeout);  /* swallow Menu */
        if (r == 1) { gt_trace("wait", ev); gt_rewrite(ev); }
    }
    if (gt_ks_active) gt_refresh_keystate();  /* keep a cached keystate pointer live */
    return r;
}

/* ======================================================================
 * F34 Task 4: GL/GLES swap-interpose HUD draw backend (device-only).
 *
 * When gt_hud_visible, the CPU-composed HUD (gt_hud_compose, shared section)
 * is uploaded as one textured quad in the port's live GL context, drawn just
 * before the real buffer swap. Both SDL_GL_SwapWindow and eglSwapBuffers are
 * interposed; a reentrancy guard (gt_in_swap) prevents a double draw when SDL
 * routes its swap through EGL internally.
 *
 * CRASH-SAFETY IS THE POINT (opt-out model — an unguarded crash loses game
 * progress):
 *   - Every GL/EGL entry point is resolved lazily at runtime (eglGetProcAddress
 *     first, dlsym(RTLD_DEFAULT) fallback). If ANY required symbol is missing,
 *     gt_gl_dead latches and the HUD never touches GL again.
 *   - gt_hud_draw's first line is `if (gt_gl_dead || !gt_hud_visible) return;`
 *     so toggle-off / a dead HUD costs one branch and touches ZERO GL state.
 *   - Shader compile/link and object creation are lazy on first draw (the
 *     context is current inside the swap). Any failure latches gt_gl_dead.
 *   - FULL GL-state save/restore wraps the draw; a post-draw glGetError latches
 *     gt_gl_dead (state is still restored that frame). A leak here corrupts the
 *     game's own rendering, so the save/restore set is exhaustive — see
 *     gt_hud_draw.
 *
 * Self-contained: linked with -ldl only. GLES2/EGL headers supply types and
 * enum constants at compile time; not one GL/EGL symbol is referenced by name
 * for the linker (all go through the p_gl* / p_eglGetProcAddress pointers).
 * ====================================================================== */

/* Runtime-resolved entry points. Both loader handles are declared as returning
 * void* rather than their true function-pointer type: the two are ABI-identical
 * (pointer-sized, same return register on every target here) and this keeps
 * every cast an object<->function-pointer cast — silent under -Wall — with no
 * function-pointer-to-function-pointer cast anywhere.
 *
 * SDL_GL_GetProcAddress is the PRIMARY resolver (fix round 1, device gate). On
 * the GL4ES stack (desktop-GL->GLES translation used by gmloadernext/GameMaker
 * — the swap trace confirms SDL_GL_SwapWindow is the present path — and every
 * SDL+GL engine we target) libGL is dlopen'd into a private namespace, so
 * dlsym(RTLD_DEFAULT, "glCreateShader") returns NULL and eglGetProcAddress is
 * unreachable too: on real hardware all 34 symbols came back missing.
 * SDL_GL_GetProcAddress uses SDL's own loader handle for the SDL-created GL
 * context, returning valid pointers whether the driver is GL4ES's libGL or a
 * native libGLESv2, and sidestepping the namespace problem. It is resolved via
 * dlsym(RTLD_NEXT) (SDL2 is loaded after this preloaded shim) so the link stays
 * -ldl-only. eglGetProcAddress + dlsym(RTLD_DEFAULT) remain as fallbacks for a
 * future non-SDL / eglSwapBuffers-only port. */
static void *(*p_SDL_GL_GetProcAddress)(const char *);
static void *(*p_eglGetProcAddress)(const char *);
static int gt_gl_src_sdl, gt_gl_src_egl, gt_gl_src_dlsym; /* debug: resolver tallies */

/* ES3-only glGet params (GLES2/gl2.h stops at ES2). Used by the GT_HUD_DEBUG
 * state dump in gt_hud_draw to see what a native-ES3 engine (e.g. the gothic
 * machismo ports) leaves bound — a sampler object or non-default VAO on unit 0
 * overrides/redirects our texture setup and can make the HUD sample black,
 * neither of which exists on the GL4ES (GL 2.1) contexts the HUD was built on. */
#ifndef GL_SAMPLER_BINDING
#define GL_SAMPLER_BINDING 0x8919
#endif
#ifndef GL_VERTEX_ARRAY_BINDING
#define GL_VERTEX_ARRAY_BINDING 0x85B5
#endif
/* ES3-only; NULL on GL4ES (resolved non-fatally) — see gt_gl_resolve / gt_hud_draw. */
static void (*p_glBindSampler)(GLuint, GLuint);

static GLuint    (*p_glCreateShader)(GLenum);
static void      (*p_glShaderSource)(GLuint, GLsizei, const GLchar *const *, const GLint *);
static void      (*p_glCompileShader)(GLuint);
static void      (*p_glGetShaderiv)(GLuint, GLenum, GLint *);
static GLuint    (*p_glCreateProgram)(void);
static void      (*p_glAttachShader)(GLuint, GLuint);
static void      (*p_glLinkProgram)(GLuint);
static void      (*p_glGetProgramiv)(GLuint, GLenum, GLint *);
static void      (*p_glUseProgram)(GLuint);
static void      (*p_glGenTextures)(GLsizei, GLuint *);
static void      (*p_glBindTexture)(GLenum, GLuint);
static void      (*p_glTexImage2D)(GLenum, GLint, GLint, GLsizei, GLsizei, GLint, GLenum, GLenum, const void *);
static void      (*p_glTexParameteri)(GLenum, GLenum, GLint);
static void      (*p_glActiveTexture)(GLenum);
static void      (*p_glGenBuffers)(GLsizei, GLuint *);
static void      (*p_glBindBuffer)(GLenum, GLuint);
static void      (*p_glBufferData)(GLenum, GLsizeiptr, const void *, GLenum);
static void      (*p_glVertexAttribPointer)(GLuint, GLint, GLenum, GLboolean, GLsizei, const void *);
static void      (*p_glEnableVertexAttribArray)(GLuint);
static void      (*p_glDisableVertexAttribArray)(GLuint);
static GLint     (*p_glGetAttribLocation)(GLuint, const GLchar *);
static GLint     (*p_glGetUniformLocation)(GLuint, const GLchar *);
static void      (*p_glUniform1i)(GLint, GLint);
static void      (*p_glDrawArrays)(GLenum, GLint, GLsizei);
static void      (*p_glEnable)(GLenum);
static void      (*p_glDisable)(GLenum);
static void      (*p_glBlendFunc)(GLenum, GLenum);
static void      (*p_glBlendFuncSeparate)(GLenum, GLenum, GLenum, GLenum);
static void      (*p_glViewport)(GLint, GLint, GLsizei, GLsizei);
static void      (*p_glGetIntegerv)(GLenum, GLint *);
static GLboolean (*p_glIsEnabled)(GLenum);
static GLenum    (*p_glGetError)(void);
static void      (*p_glGetVertexAttribiv)(GLuint, GLenum, GLint *);
static void      (*p_glGetVertexAttribPointerv)(GLuint, GLenum, void **);

static int    gt_gl_dead;    /* latched: any resolve/compile/link/GL error */
static int    gt_gl_ready;   /* shader/program/objects built */
static GLuint gt_prog, gt_tex, gt_vbo;
static GLint  gt_loc_pos, gt_loc_uv, gt_loc_tex;

/* Per-symbol resolve order (fix round 1): SDL_GL_GetProcAddress (authoritative
 * for the SDL GL context — beats GL4ES's private-namespace libGL), then
 * eglGetProcAddress, then dlsym(RTLD_DEFAULT). First non-NULL wins; tally which
 * source served it for the debug summary. */
static void *gt_resolve1(const char *name) {
    void *f;
    if (p_SDL_GL_GetProcAddress && (f = p_SDL_GL_GetProcAddress(name))) { gt_gl_src_sdl++;   return f; }
    if (p_eglGetProcAddress     && (f = p_eglGetProcAddress(name)))     { gt_gl_src_egl++;   return f; }
    if ((f = dlsym(RTLD_DEFAULT, name)))                                { gt_gl_src_dlsym++; return f; }
    return NULL;
}

/* Resolve every entry point once. Latches gt_gl_dead (and returns 0) if any is
 * missing, so a context without full GLES2 disables the HUD instead of
 * crashing. glUniform4f (listed in the brief) is intentionally omitted: the
 * final fragment shader has no vec4 uniform, so requiring it would needlessly
 * gate the HUD on an unused symbol. */
static int gt_gl_resolve(void) {
    static int done;
    if (done) return !gt_gl_dead;
    done = 1;
    /* SDL2 sits below this preloaded shim, so RTLD_NEXT finds its GL loader;
     * eglGetProcAddress is a fallback for a future eglSwapBuffers-only port. */
    p_SDL_GL_GetProcAddress = (void *(*)(const char *))dlsym(RTLD_NEXT, "SDL_GL_GetProcAddress");
    p_eglGetProcAddress     = (void *(*)(const char *))dlsym(RTLD_DEFAULT, "eglGetProcAddress");
    int missing = 0;
#define GT_GL(fp, NAME, ...) do { \
        fp = (__VA_ARGS__)gt_resolve1(NAME); \
        if (!fp) { missing++; if (gt_hud_debug()) fprintf(stderr, "gt-hud: missing GL symbol %s\n", NAME); } \
    } while (0)
    GT_GL(p_glCreateShader, "glCreateShader", GLuint(*)(GLenum));
    GT_GL(p_glShaderSource, "glShaderSource", void(*)(GLuint,GLsizei,const GLchar*const*,const GLint*));
    GT_GL(p_glCompileShader, "glCompileShader", void(*)(GLuint));
    GT_GL(p_glGetShaderiv, "glGetShaderiv", void(*)(GLuint,GLenum,GLint*));
    GT_GL(p_glCreateProgram, "glCreateProgram", GLuint(*)(void));
    GT_GL(p_glAttachShader, "glAttachShader", void(*)(GLuint,GLuint));
    GT_GL(p_glLinkProgram, "glLinkProgram", void(*)(GLuint));
    GT_GL(p_glGetProgramiv, "glGetProgramiv", void(*)(GLuint,GLenum,GLint*));
    GT_GL(p_glUseProgram, "glUseProgram", void(*)(GLuint));
    GT_GL(p_glGenTextures, "glGenTextures", void(*)(GLsizei,GLuint*));
    GT_GL(p_glBindTexture, "glBindTexture", void(*)(GLenum,GLuint));
    GT_GL(p_glTexImage2D, "glTexImage2D", void(*)(GLenum,GLint,GLint,GLsizei,GLsizei,GLint,GLenum,GLenum,const void*));
    GT_GL(p_glTexParameteri, "glTexParameteri", void(*)(GLenum,GLenum,GLint));
    GT_GL(p_glActiveTexture, "glActiveTexture", void(*)(GLenum));
    GT_GL(p_glGenBuffers, "glGenBuffers", void(*)(GLsizei,GLuint*));
    GT_GL(p_glBindBuffer, "glBindBuffer", void(*)(GLenum,GLuint));
    GT_GL(p_glBufferData, "glBufferData", void(*)(GLenum,GLsizeiptr,const void*,GLenum));
    GT_GL(p_glVertexAttribPointer, "glVertexAttribPointer", void(*)(GLuint,GLint,GLenum,GLboolean,GLsizei,const void*));
    GT_GL(p_glEnableVertexAttribArray, "glEnableVertexAttribArray", void(*)(GLuint));
    GT_GL(p_glDisableVertexAttribArray, "glDisableVertexAttribArray", void(*)(GLuint));
    GT_GL(p_glGetAttribLocation, "glGetAttribLocation", GLint(*)(GLuint,const GLchar*));
    GT_GL(p_glGetUniformLocation, "glGetUniformLocation", GLint(*)(GLuint,const GLchar*));
    GT_GL(p_glUniform1i, "glUniform1i", void(*)(GLint,GLint));
    GT_GL(p_glDrawArrays, "glDrawArrays", void(*)(GLenum,GLint,GLsizei));
    GT_GL(p_glEnable, "glEnable", void(*)(GLenum));
    GT_GL(p_glDisable, "glDisable", void(*)(GLenum));
    GT_GL(p_glBlendFunc, "glBlendFunc", void(*)(GLenum,GLenum));
    GT_GL(p_glBlendFuncSeparate, "glBlendFuncSeparate", void(*)(GLenum,GLenum,GLenum,GLenum));
    GT_GL(p_glViewport, "glViewport", void(*)(GLint,GLint,GLsizei,GLsizei));
    GT_GL(p_glGetIntegerv, "glGetIntegerv", void(*)(GLenum,GLint*));
    GT_GL(p_glIsEnabled, "glIsEnabled", GLboolean(*)(GLenum));
    GT_GL(p_glGetError, "glGetError", GLenum(*)(void));
    GT_GL(p_glGetVertexAttribiv, "glGetVertexAttribiv", void(*)(GLuint,GLenum,GLint*));
    GT_GL(p_glGetVertexAttribPointerv, "glGetVertexAttribPointerv", void(*)(GLuint,GLenum,void**));
#undef GT_GL
    /* Optional, ES3-only — NOT counted in `missing`. A native-ES3 engine can
     * bind a sampler object to a texture unit, which OVERRIDES the unit's
     * glTexParameteri; the gothic machismo ports (e.g. Mina the Hollower) leave
     * sampler #1 on unit 0, forcing a mipmap min-filter our no-mipmap HUD
     * texture can't satisfy, so it samples opaque BLACK (device-confirmed
     * 2026-08-27: "sampler[unit0]=1"). gt_hud_draw unbinds it around our draw.
     * GL4ES (GL 2.1) has no sampler objects, so this stays NULL there and the
     * HUD is byte-for-byte unaffected on every existing port. */
    p_glBindSampler = (void (*)(GLuint, GLuint))gt_resolve1("glBindSampler");
    if (gt_hud_debug())
        fprintf(stderr, "gt-hud: glBindSampler = %p (%s)\n",
                (void *)p_glBindSampler, p_glBindSampler ? "ES3 sampler-objects" : "absent (GL4ES/ES2)");
    if (missing) {
        gt_gl_dead = 1;
        if (gt_hud_debug())
            fprintf(stderr, "gt-hud: GL resolve failed (%d symbol(s) missing) -> HUD disabled\n", missing);
        return 0;
    }
    if (gt_hud_debug()) {
        const char *primary = gt_gl_src_sdl ? "SDL_GL_GetProcAddress"
                            : gt_gl_src_egl ? "eglGetProcAddress" : "dlsym";
        fprintf(stderr, "gt-hud: GL via %s (sdl=%d egl=%d dlsym=%d)\n",
                primary, gt_gl_src_sdl, gt_gl_src_egl, gt_gl_src_dlsym);
    }
    return 1;
}

static const char *GT_VS =
  "attribute vec2 aPos; attribute vec2 aUV; varying vec2 vUV;"
  "void main(){ vUV = aUV; gl_Position = vec4(aPos, 0.0, 1.0); }";
static const char *GT_FS =
  "precision mediump float; varying vec2 vUV; uniform sampler2D uTex;"
  "void main(){ gl_FragColor = texture2D(uTex, vUV); }";

static GLuint gt_gl_compile(GLenum type, const char *src) {
    GLuint sh = p_glCreateShader(type);
    if (!sh) return 0;
    p_glShaderSource(sh, 1, &src, NULL);
    p_glCompileShader(sh);
    GLint ok = 0;
    p_glGetShaderiv(sh, GL_COMPILE_STATUS, &ok);
    return ok ? sh : 0;
}

/* Build program + texture/buffer names. STATE-NEUTRAL by construction: it
 * makes no bind/use/active-texture call, so it is safe to run before the
 * per-frame save block. Texture parameters and binding happen inside the
 * saved region of gt_hud_draw. Latches gt_gl_dead on any failure. */
static int gt_gl_init(void) {
    if (gt_gl_ready) return 1;
    if (gt_gl_dead)  return 0;
    GLuint vs = gt_gl_compile(GL_VERTEX_SHADER, GT_VS);
    GLuint fs = gt_gl_compile(GL_FRAGMENT_SHADER, GT_FS);
    if (!vs || !fs) {
        gt_gl_dead = 1;
        if (gt_hud_debug()) fprintf(stderr, "gt-hud: shader compile failed -> HUD disabled\n");
        return 0;
    }
    GLuint prog = p_glCreateProgram();
    if (!prog) { gt_gl_dead = 1; return 0; }
    p_glAttachShader(prog, vs);
    p_glAttachShader(prog, fs);
    p_glLinkProgram(prog);
    GLint ok = 0;
    p_glGetProgramiv(prog, GL_LINK_STATUS, &ok);
    if (!ok) {
        gt_gl_dead = 1;
        if (gt_hud_debug()) fprintf(stderr, "gt-hud: program link failed -> HUD disabled\n");
        return 0;
    }
    gt_prog = prog;
    gt_loc_pos = p_glGetAttribLocation(prog, "aPos");
    gt_loc_uv  = p_glGetAttribLocation(prog, "aUV");
    gt_loc_tex = p_glGetUniformLocation(prog, "uTex");
    if (gt_loc_pos < 0 || gt_loc_uv < 0) {
        gt_gl_dead = 1;
        if (gt_hud_debug()) fprintf(stderr, "gt-hud: attribute location missing -> HUD disabled\n");
        return 0;
    }
    p_glGenTextures(1, &gt_tex);
    p_glGenBuffers(1, &gt_vbo);
    if (!gt_tex || !gt_vbo) { gt_gl_dead = 1; return 0; }
    gt_gl_ready = 1;
    if (gt_hud_debug())
        fprintf(stderr, "gt-hud: GL init ok (prog=%u tex=%u vbo=%u pos=%d uv=%d tex_unit_loc=%d)\n",
                (unsigned)gt_prog, (unsigned)gt_tex, (unsigned)gt_vbo,
                (int)gt_loc_pos, (int)gt_loc_uv, (int)gt_loc_tex);
    return 1;
}

/* Sample all four metrics into *m from the live device. Interposer-only
 * (POSIX file I/O + libc time); the decoders it calls are the shared Task 1
 * functions. Defensive: any read failure leaves that metric at its decoder's
 * failure value (e.g. volume/brightness -1 -> shown as "--"). A fresh
 * open+read+close each call gets current values (keymon rewrites SharedSettings
 * live) and is robust to the file being recreated. */
static void gt_hud_sample(gt_metrics *m) {
    char cap[16] = {0}, st[24] = {0};
    int fd;
    ssize_t r;
    fd = open("/sys/class/power_supply/axp2202-battery/capacity", O_RDONLY);
    if (fd >= 0) { r = read(fd, cap, sizeof cap - 1); if (r > 0) cap[r] = 0; close(fd); }
    fd = open("/sys/class/power_supply/axp2202-battery/status", O_RDONLY);
    if (fd >= 0) { r = read(fd, st, sizeof st - 1); if (r > 0) st[r] = 0; close(fd); }
    gt_battery_parse(cap, st, m);

    unsigned char ss[GT_SS_LEN];
    int n = 0;
    fd = open("/dev/shm/SharedSettings", O_RDONLY);
    if (fd >= 0) {
        while (n < GT_SS_LEN) {                    /* fill fully; tmpfs may short-read */
            r = read(fd, ss + n, (size_t)(GT_SS_LEN - n));
            if (r <= 0) break;
            n += (int)r;
        }
        close(fd);
    }
    gt_shared_settings_decode(ss, n, m);           /* short/zero read -> -1 (shown "--") */

    time_t now = time(NULL);
    struct tm tmv;
    localtime_r(&now, &tmv);
    gt_time_set(m, &tmv);
}

/* 1-second sample cache + composed RGBA (re-uploaded only when the text
 * changed). */
static gt_metrics gt_cache;
static time_t     gt_last_sample;
static int        gt_have_sample;
static uint32_t   gt_rgba[GT_HUD_MAX_W * GT_HUD_MAX_H];
static int        gt_tex_w = GT_HUD_MAX_W, gt_tex_h = GT_HUD_MAX_H;
static int        gt_tex_dirty;

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

/* Draw the HUD in the current (swap-time) GL context. Called ONLY from the
 * swap interposers. Full GL-state save/restore — the save set below is the
 * exhaustive list the review scrutinizes:
 *   current program, active texture unit, unit-0 2D texture binding,
 *   GL_ARRAY_BUFFER binding, viewport, blend enable + separate blend func
 *   (RGB & alpha src/dst), depth-test enable, cull-face enable, scissor-test
 *   enable, and — for each of the two vertex-attrib arrays we bind — its
 *   enabled flag, size/type/normalized/stride, buffer binding, and pointer.
 * (Scissor is beyond the brief's list but uses only already-resolved symbols;
 * disabling+restoring it keeps a game's scissor rect from clipping the HUD
 * without leaking state — see the report.) Restored in reverse. */
static void gt_hud_draw(void) {
    if (gt_gl_dead || !gt_hud_visible) return;   /* toggle-off touches zero GL state */
    if (!gt_gl_resolve()) return;
    if (!gt_gl_init())    return;

    /* CPU sample + recompose at most once per second (shared with the SW path). */
    gt_hud_refresh();

    /* ---- SAVE (all reads; no GL state changed yet) ---- */
    GLint s_prog = 0, s_active = GL_TEXTURE0, s_arraybuf = 0, s_vp[4] = {0,0,0,0};
    GLint s_bs_rgb = GL_ONE, s_bd_rgb = GL_ZERO, s_bs_a = GL_ONE, s_bd_a = GL_ZERO;
    GLboolean s_blend, s_depth, s_cull, s_scissor;
    p_glGetIntegerv(GL_CURRENT_PROGRAM, &s_prog);
    p_glGetIntegerv(GL_ACTIVE_TEXTURE, &s_active);
    p_glGetIntegerv(GL_ARRAY_BUFFER_BINDING, &s_arraybuf);
    p_glGetIntegerv(GL_VIEWPORT, s_vp);
    p_glGetIntegerv(GL_BLEND_SRC_RGB, &s_bs_rgb);
    p_glGetIntegerv(GL_BLEND_DST_RGB, &s_bd_rgb);
    p_glGetIntegerv(GL_BLEND_SRC_ALPHA, &s_bs_a);
    p_glGetIntegerv(GL_BLEND_DST_ALPHA, &s_bd_a);
    s_blend   = p_glIsEnabled(GL_BLEND);
    s_depth   = p_glIsEnabled(GL_DEPTH_TEST);
    s_cull    = p_glIsEnabled(GL_CULL_FACE);
    s_scissor = p_glIsEnabled(GL_SCISSOR_TEST);

    int vw = s_vp[2], vh = s_vp[3];
    if (vw <= 0 || vh <= 0) return;              /* no viewport yet; nothing written */

    /* Switch to unit 0 (a write, undone last via s_active) so the unit-0 2D
     * binding can be read and later restored on the correct unit. */
    p_glActiveTexture(GL_TEXTURE0);
    GLint s_tex0 = 0;
    p_glGetIntegerv(GL_TEXTURE_BINDING_2D, &s_tex0);
    /* Save the sampler object bound to unit 0 (ES3 only) so we can unbind it for
     * our draw and put the engine's back afterward. Zero on GL4ES (skipped). */
    GLint s_sampler0 = 0;
    if (p_glBindSampler) p_glGetIntegerv(GL_SAMPLER_BINDING, &s_sampler0);

    /* Save the two vertex-attrib arrays we are about to overwrite. */
    GLint aloc[2]; aloc[0] = gt_loc_pos; aloc[1] = gt_loc_uv;
    GLint a_en[2], a_size[2], a_type[2], a_norm[2], a_stride[2], a_buf[2];
    void *a_ptr[2] = {NULL, NULL};
    for (int i = 0; i < 2; i++) {
        p_glGetVertexAttribiv(aloc[i], GL_VERTEX_ATTRIB_ARRAY_ENABLED, &a_en[i]);
        p_glGetVertexAttribiv(aloc[i], GL_VERTEX_ATTRIB_ARRAY_SIZE, &a_size[i]);
        p_glGetVertexAttribiv(aloc[i], GL_VERTEX_ATTRIB_ARRAY_TYPE, &a_type[i]);
        p_glGetVertexAttribiv(aloc[i], GL_VERTEX_ATTRIB_ARRAY_NORMALIZED, &a_norm[i]);
        p_glGetVertexAttribiv(aloc[i], GL_VERTEX_ATTRIB_ARRAY_STRIDE, &a_stride[i]);
        p_glGetVertexAttribiv(aloc[i], GL_VERTEX_ATTRIB_ARRAY_BUFFER_BINDING, &a_buf[i]);
        p_glGetVertexAttribPointerv(aloc[i], GL_VERTEX_ATTRIB_ARRAY_POINTER, &a_ptr[i]);
    }

    /* Drain any error the game left pending, so the post-draw check is ours. */
    { int guard = 0; while (p_glGetError() != GL_NO_ERROR && guard++ < 16) {} }

    /* GT_HUD_DEBUG: dump the ES3-only state the game left bound (once). A bound
     * sampler object on unit 0 overrides our glTexParameteri (mipmap filter ->
     * our no-mipmap texture samples opaque black); a non-default VAO redirects
     * our attrib setup; a masked colormask blocks our writes. None exist on
     * GL4ES, so this is inert there. Queries may raise GL_INVALID_ENUM on a
     * non-ES3 context — drained right after so the post-draw check stays ours. */
    if (gt_hud_debug()) {
        static int dumped = 0;
        if (!dumped) {
            GLint d_samp = -1, d_vao = -1, d_cmask[4] = {-1,-1,-1,-1};
            p_glGetIntegerv(GL_SAMPLER_BINDING, &d_samp);
            p_glGetIntegerv(GL_VERTEX_ARRAY_BINDING, &d_vao);
            p_glGetIntegerv(GL_COLOR_WRITEMASK, d_cmask);
            fprintf(stderr, "gt-hud: ES3-state @draw: sampler[unit0]=%d vao=%d "
                    "colormask=%d,%d,%d,%d tex0=%d prog=%d\n",
                    d_samp, d_vao, d_cmask[0], d_cmask[1], d_cmask[2], d_cmask[3],
                    s_tex0, s_prog);
            { int g = 0; while (p_glGetError() != GL_NO_ERROR && g++ < 16) {} }
            dumped = 1;
        }
    }

    /* ---- geometry: top-left-origin pixel rect -> NDC with a Y-flip (GL NDC
     * is +y up, origin bottom-left). Panel lands top-right. UVs put buffer
     * row 0 (top of the panel) at v=0 so the top-loaded texture is upright. */
    int px, py;
    gt_hud_rect(vw, vh, gt_tex_w, gt_tex_h, &px, &py);
    float xl = 2.0f * px / vw - 1.0f;
    float xr = 2.0f * (px + gt_tex_w) / vw - 1.0f;
    float yt = 1.0f - 2.0f * py / vh;
    float yb = 1.0f - 2.0f * (py + gt_tex_h) / vh;
    float verts[16] = {
        xl, yb, 0.0f, 1.0f,   /* bottom-left  */
        xr, yb, 1.0f, 1.0f,   /* bottom-right */
        xl, yt, 0.0f, 0.0f,   /* top-left     */
        xr, yt, 1.0f, 0.0f,   /* top-right    */
    };

    /* ---- SET our state ---- */
    p_glUseProgram(gt_prog);
    /* active unit is already GL_TEXTURE0 */
    p_glBindTexture(GL_TEXTURE_2D, gt_tex);
    /* Unbind any sampler object the engine left on unit 0, so the params below
     * actually govern our texture (a leftover mipmap-filter sampler otherwise
     * makes our no-mipmap texture sample black). No-op on GL4ES (NULL). */
    if (p_glBindSampler) p_glBindSampler(0, 0);
    /* NPOT-safe params (panel is 80x46): CLAMP_TO_EDGE + NEAREST, no mipmaps.
     * Row stride 80*4 = 320 B is 4-aligned, so the default UNPACK_ALIGNMENT
     * holds and glPixelStorei is not needed. */
    p_glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    p_glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    p_glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    p_glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    if (gt_tex_dirty) {
        p_glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, gt_tex_w, gt_tex_h, 0,
                       GL_RGBA, GL_UNSIGNED_BYTE, gt_rgba);
        gt_tex_dirty = 0;
    }
    p_glUniform1i(gt_loc_tex, 0);
    p_glBindBuffer(GL_ARRAY_BUFFER, gt_vbo);
    p_glBufferData(GL_ARRAY_BUFFER, (GLsizeiptr)sizeof verts, verts, GL_DYNAMIC_DRAW);
    p_glVertexAttribPointer((GLuint)gt_loc_pos, 2, GL_FLOAT, GL_FALSE,
                            4 * (GLsizei)sizeof(float), (const void *)0);
    p_glEnableVertexAttribArray((GLuint)gt_loc_pos);
    p_glVertexAttribPointer((GLuint)gt_loc_uv, 2, GL_FLOAT, GL_FALSE,
                            4 * (GLsizei)sizeof(float), (const void *)(uintptr_t)(2u * sizeof(float)));
    p_glEnableVertexAttribArray((GLuint)gt_loc_uv);
    p_glEnable(GL_BLEND);
    p_glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
    p_glDisable(GL_DEPTH_TEST);
    p_glDisable(GL_CULL_FACE);
    p_glDisable(GL_SCISSOR_TEST);

    p_glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);

    GLenum err = p_glGetError();

    /* ---- RESTORE (reverse order) ---- */
    if (s_scissor) p_glEnable(GL_SCISSOR_TEST); else p_glDisable(GL_SCISSOR_TEST);
    if (s_cull)    p_glEnable(GL_CULL_FACE);    else p_glDisable(GL_CULL_FACE);
    if (s_depth)   p_glEnable(GL_DEPTH_TEST);   else p_glDisable(GL_DEPTH_TEST);
    p_glBlendFuncSeparate((GLenum)s_bs_rgb, (GLenum)s_bd_rgb, (GLenum)s_bs_a, (GLenum)s_bd_a);
    if (s_blend)   p_glEnable(GL_BLEND);        else p_glDisable(GL_BLEND);
    for (int i = 1; i >= 0; i--) {             /* uv then pos */
        p_glBindBuffer(GL_ARRAY_BUFFER, (GLuint)a_buf[i]);   /* pointer captures this buffer */
        p_glVertexAttribPointer((GLuint)aloc[i], a_size[i], (GLenum)a_type[i],
                                (GLboolean)a_norm[i], (GLsizei)a_stride[i], a_ptr[i]);
        if (a_en[i]) p_glEnableVertexAttribArray((GLuint)aloc[i]);
        else         p_glDisableVertexAttribArray((GLuint)aloc[i]);
    }
    p_glBindBuffer(GL_ARRAY_BUFFER, (GLuint)s_arraybuf);
    p_glBindTexture(GL_TEXTURE_2D, (GLuint)s_tex0); /* on unit 0, still active */
    if (p_glBindSampler) p_glBindSampler(0, (GLuint)s_sampler0); /* engine's sampler back on unit 0 */
    p_glActiveTexture((GLenum)s_active);
    p_glUseProgram((GLuint)s_prog);
    p_glViewport(s_vp[0], s_vp[1], s_vp[2], s_vp[3]);  /* unchanged by us; restored defensively */

    if (err != GL_NO_ERROR) {
        gt_gl_dead = 1;
        if (gt_hud_debug())
            fprintf(stderr, "gt-hud: glGetError=0x%x after draw -> HUD disabled\n", (unsigned)err);
    }
}

/* Interpose both swap paths, drawing the HUD immediately before the real swap.
 * gt_in_swap makes eglSwapBuffers skip its own draw when SDL_GL_SwapWindow
 * (which may route through EGL internally) already drew this frame. */
static int gt_in_swap;   /* reentrancy guard for the nested egl call */

/* Signature matches SDL_video.h's prototype (SDL_Window*, not void*) — SDL.h
 * is included, so the declared and defined types must agree. */
void SDL_GL_SwapWindow(SDL_Window *win) {
    gt_announce(1);
    gt_evdev_ensure();
    static void (*real)(SDL_Window*); if (!real) real = (void(*)(SDL_Window*))dlsym(RTLD_NEXT, "SDL_GL_SwapWindow");
    if (gt_hud_debug()) { static int once; if (!once) { once = 1;
        fprintf(stderr, "gt-hud: swap path = SDL_GL_SwapWindow\n"); } }
    gt_in_swap = 1; gt_hud_draw(); real(win); gt_in_swap = 0;
}

unsigned int eglSwapBuffers(void *dpy, void *surf) {
    gt_announce(1);
    gt_evdev_ensure();
    static unsigned int (*real)(void*,void*); if (!real) real = (unsigned int(*)(void*,void*))dlsym(RTLD_NEXT, "eglSwapBuffers");
    if (gt_hud_debug()) { static int once; if (!once) { once = 1;
        fprintf(stderr, "gt-hud: swap path = eglSwapBuffers (nested=%d)\n", gt_in_swap); } }
    if (!gt_in_swap) gt_hud_draw();      /* skip if SDL_GL_SwapWindow already drew */
    return real(dpy, surf);
}

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

/* F44: renderer geometry accessors. RSDK-class ports drive the renderer through
 * SDL_RenderSetLogicalSize, which remaps RenderCopy into the game's small logical
 * space — so the HUD's physical top-right rect lands off-screen. We snapshot and
 * reset these to draw in physical output pixels, then restore the port's state. */
static void      (*p_SDL_RenderGetLogicalSize)(SDL_Renderer*, int*, int*);
static int       (*p_SDL_RenderSetLogicalSize)(SDL_Renderer*, int, int);
static void      (*p_SDL_RenderGetScale)(SDL_Renderer*, float*, float*);
static int       (*p_SDL_RenderSetScale)(SDL_Renderer*, float, float);
static void      (*p_SDL_RenderGetViewport)(SDL_Renderer*, SDL_Rect*);
static int       (*p_SDL_RenderSetViewport)(SDL_Renderer*, const SDL_Rect*);
static void      (*p_SDL_RenderGetClipRect)(SDL_Renderer*, SDL_Rect*);
static int       (*p_SDL_RenderSetClipRect)(SDL_Renderer*, const SDL_Rect*);
static SDL_bool  (*p_SDL_RenderIsClipEnabled)(SDL_Renderer*);

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
    p_SDL_RenderGetLogicalSize = (void (*)(SDL_Renderer*,int*,int*))dlsym(RTLD_NEXT, "SDL_RenderGetLogicalSize");
    p_SDL_RenderSetLogicalSize = (int (*)(SDL_Renderer*,int,int))dlsym(RTLD_NEXT, "SDL_RenderSetLogicalSize");
    p_SDL_RenderGetScale       = (void (*)(SDL_Renderer*,float*,float*))dlsym(RTLD_NEXT, "SDL_RenderGetScale");
    p_SDL_RenderSetScale       = (int (*)(SDL_Renderer*,float,float))dlsym(RTLD_NEXT, "SDL_RenderSetScale");
    p_SDL_RenderGetViewport    = (void (*)(SDL_Renderer*,SDL_Rect*))dlsym(RTLD_NEXT, "SDL_RenderGetViewport");
    p_SDL_RenderSetViewport    = (int (*)(SDL_Renderer*,const SDL_Rect*))dlsym(RTLD_NEXT, "SDL_RenderSetViewport");
    p_SDL_RenderGetClipRect    = (void (*)(SDL_Renderer*,SDL_Rect*))dlsym(RTLD_NEXT, "SDL_RenderGetClipRect");
    p_SDL_RenderSetClipRect    = (int (*)(SDL_Renderer*,const SDL_Rect*))dlsym(RTLD_NEXT, "SDL_RenderSetClipRect");
    p_SDL_RenderIsClipEnabled  = (SDL_bool (*)(SDL_Renderer*))dlsym(RTLD_NEXT, "SDL_RenderIsClipEnabled");
    if (!p_SDL_CreateTexture || !p_SDL_DestroyTexture || !p_SDL_UpdateTexture ||
        !p_SDL_RenderCopy || !p_SDL_SetTextureBlendMode || !p_SDL_GetRendererOutputSize ||
        !p_SDL_RenderGetLogicalSize || !p_SDL_RenderSetLogicalSize ||
        !p_SDL_RenderGetScale || !p_SDL_RenderSetScale ||
        !p_SDL_RenderGetViewport || !p_SDL_RenderSetViewport ||
        !p_SDL_RenderGetClipRect || !p_SDL_RenderSetClipRect || !p_SDL_RenderIsClipEnabled) {
        gt_sw_dead = 1;
        if (gt_hud_debug()) fprintf(stderr, "gt-hud: SDL_Render symbol(s) missing -> SW HUD disabled\n");
        return 0;
    }
    return 1;
}

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

    /* F44: RSDK-class ports drive the renderer through SDL_RenderSetLogicalSize,
     * so RenderCopy is remapped into the game's small logical space and our
     * physical top-right rect lands off-screen. Snapshot the port's geometry,
     * drop to physical 1:1 for our own copy, then restore it exactly (the same
     * exhaustive save/restore the GL path uses). A port that sets none of these
     * has identity state, so this is a no-op there. */
    int save_lw = 0, save_lh = 0; p_SDL_RenderGetLogicalSize(r, &save_lw, &save_lh);
    float save_sx = 1.0f, save_sy = 1.0f; p_SDL_RenderGetScale(r, &save_sx, &save_sy);
    SDL_Rect save_vp = { 0, 0, 0, 0 }; p_SDL_RenderGetViewport(r, &save_vp);
    SDL_bool save_clip_on = p_SDL_RenderIsClipEnabled(r);
    SDL_Rect save_clip = { 0, 0, 0, 0 }; p_SDL_RenderGetClipRect(r, &save_clip);

    p_SDL_RenderSetLogicalSize(r, 0, 0);   /* clear logical scaling; ... */
    p_SDL_RenderSetScale(r, 1.0f, 1.0f);   /* ... reset scale/viewport explicitly to physical 1:1 */
    p_SDL_RenderSetViewport(r, NULL);      /* (older SDL's SetLogicalSize(0,0) left these set) */
    p_SDL_RenderSetClipRect(r, NULL);      /* no clip */

    p_SDL_RenderCopy(r, tex, NULL, &dst);

    p_SDL_RenderSetLogicalSize(r, save_lw, save_lh);   /* logical>0: regenerates the exact scale+viewport */
    if (!(save_lw > 0 && save_lh > 0)) {               /* non-logical: restore any manual scale/viewport */
        p_SDL_RenderSetScale(r, save_sx, save_sy);
        p_SDL_RenderSetViewport(r, &save_vp);
    }
    p_SDL_RenderSetClipRect(r, save_clip_on ? &save_clip : NULL);
}

void SDL_RenderPresent(SDL_Renderer *r) {
    gt_announce(1);
    gt_evdev_ensure();
    static void (*real)(SDL_Renderer*);
    if (!real) real = (void (*)(SDL_Renderer*))dlsym(RTLD_NEXT, "SDL_RenderPresent");
    if (gt_hud_debug()) { static int once; if (!once) { once = 1;
        fprintf(stderr, "gt-hud: present path = SDL_RenderPresent\n"); } }
    gt_hud_draw_sw(r);
    if (real) real(r);
}

#endif /* GT_REMAP_TEST */
