# In-game status overlay (HUD) — F34 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a toggleable in-game status overlay (battery, time, volume, brightness) to PortMaster ports on the RG SP, drawn by a swap-interpose HUD in the existing LD_PRELOAD shim.

**Architecture:** Extend `assets/gt-input-remap.c` with (a) pure-C sampling + HUD-compose logic (host-testable behind `-DGT_REMAP_TEST`) and (b) a device-only GL/GLES swap-interpose that uploads the CPU-composed HUD as one textured quad. `build/build-pak.sh` preloads the shim on every h700 port (HUD opt-out via a blocklist) while keeping the input remap opt-in (allowlist). Ships in 0.3.0 with F33.

**Tech Stack:** C (LD_PRELOAD shim, `dlsym(RTLD_NEXT)` interposition, GLES2/EGL resolved dynamically), POSIX shell + awk (`build-pak.sh` injection), the pak's `GT_STAGE_EDIT_ONLY` fixture test harness.

**Spec:** `docs/superpowers/specs/2026-08-26-ingame-overlay-hud-design.md`

## Global Constraints

- **Shim stays self-contained:** resolve every SDL/GL/EGL symbol via `dlsym(RTLD_NEXT, …)` / `eglGetProcAddress` — NO link-time dependency on libSDL2, libGLESv2, or libEGL (the shim links only `-ldl`, as today). Compile-time GL/EGL *headers* are allowed for types/enums.
- **Regression invariant (hard):** allowlisted remap/keyboard ports (`assets/gt-remap-ports.txt`) must behave **identically** after this change. The v1 index remap and gptk keyboard synthesis are unchanged in effect; they are merely gated behind the new `GT_INPUT_REMAP=1` env, which `build-pak.sh` sets for exactly those ports.
- **Pure-C logic is host-testable:** all sampling/compose/toggle logic goes OUTSIDE the interposer `#ifdef GT_REMAP_TEST` block and is asserted in the shim's `main()`, which must still print exactly `remap ok`. `tests/test-05-input-remap.sh` runs it.
- **Injection edits:** marker-guarded, idempotent, and `sh -n`-clean, matching the existing `gt-h700-*` awk blocks in `build-pak.sh`. `launch.sh` has **no `set -e`** — use explicit `if`, never `&&`-chained state.
- **HUD draw must be crash-safe:** any GL failure (shader compile, missing symbol, bad state) disables the HUD for the session rather than aborting the host process. Toggle-off must fully restore GL state.
- **Device:** RG SP = `ssh root@10.0.1.16`. Never overwrite a running `.so`/script in place (scp to temp + `mv`).
- **No push / tag / release / `make pak` publish without Camille's explicit go-ahead** (hard gate). Local commits on `feat/ingame-overlay-hud` only.

**User decisions (already made):**
- All four metrics (battery, time, volume, brightness). — "all four"
- Toggle on/off behavior (not hold-to-peek), default **off**. — "Toggle on/off"
- Trigger = **Menu** button, single tap, swallowed. — "Menu button (single tap)"
- Layout = **top-right** stacked panel over a translucent dark strip. — "Top-right panel"
- Volume+brightness source = **SharedSettings** primary, ALSA `digital volume` + `attr/sys backlight(N)` fallback. — "SharedSettings-primary… sounds good"
- HUD is **opt-out** (blocklist, on by default on every port); input remap stays **opt-in** (allowlist). — "enable it for every port, and also have a blocklist"
- Stage 1 = GL/EGL path only; software-renderer (`SDL_RenderPresent`) is a later stage. — approved Section 6
- Hardware DE-layer route rejected (disp2 `LAYER_SET_CONFIG` → EPERM). — spike verdict, approved
- Bundle with F33 into 0.3.0. — prior decision, re-confirmed

---

### Task 1: Shim — HUD sampling + formatting (pure C, host-tested)

**Goal:** Add pure-C logic that decodes the four metrics from their sources into a cache struct and formats them into the display strings, with host assertions in `main()`.

**Files:**
- Modify: `assets/gt-input-remap.c` (new shared-logic section before `#ifdef GT_REMAP_TEST`; new asserts inside `main()`)
- Test: `tests/test-05-input-remap.sh` (unchanged runner — it already asserts `main()` prints `remap ok`)

**Acceptance Criteria:**
- [ ] `gt_shared_settings_decode(const unsigned char *buf, int len, gt_metrics *m)` extracts volume (0–20) and brightness (0–10) from a SharedSettings byte buffer at named offset constants.
- [ ] `gt_fmt_metrics(const gt_metrics *m, char lines[4][24])` produces the four display strings (`BAT  16% +`, `TIME 13:31`, `VOL   54%`, `BRI   78%`) — volume/brightness shown as a percent of their NextUI-unit max.
- [ ] Battery percent + charging flag parse from the raw sysfs strings (`"16\n"`, `"Charging\n"`).
- [ ] Time formats from a fixed `struct tm` to `HH:MM`.
- [ ] `main()` still prints exactly `remap ok`; all new asserts pass.

**Verify:** `sh tests/test-05-input-remap.sh` → exits 0 (prints nothing on success; `run.sh` reports pass)

**Steps:**

- [ ] **Step 1: Add the shared-logic types + functions** (in `assets/gt-input-remap.c`, immediately before the `#ifdef GT_REMAP_TEST` line ~251). SharedSettings offsets are the project's current best guess and are CONFIRMED/CORRECTED on-device in Task 8 — the host test is self-consistent regardless.

```c
/* ---- HUD sampling + formatting (no SDL/GL; host-testable) -------------- */
/* NextUI /dev/shm/SharedSettings: 33 x int32. Offsets are byte offsets.
 * VOL/BRI indices are the project's current read of the layout (idx1=volume
 * 0-20, and brightness one of idx2..4); CONFIRM on-device (Task 8) by nudging
 * each setting and re-dumping. Units: volume 0-20, brightness 0-10 (NextUI). */
#define GT_SS_LEN            132
#define GT_SS_OFF_VOLUME     4     /* int32 idx1 */
#define GT_SS_OFF_BRIGHTNESS 8     /* int32 idx2 — VERIFY on device */
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
    if (!buf || len < GT_SS_LEN) { m->volume = m->brightness = -1; m->valid = 0; return 0; }
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

static int gt_pct_of(int v, int max) { return (max > 0) ? (v * 100 + max / 2) / max : 0; }

/* Format the four fixed-width lines. lines[i] is >= 24 bytes. */
static void gt_fmt_metrics(const gt_metrics *m, char lines[4][24]) {
    snprintf(lines[0], 24, "BAT  %3d%% %s", m->battery_pct, m->charging ? "+" : " ");
    snprintf(lines[1], 24, "TIME %02d:%02d", m->hour, m->minute);
    if (m->volume >= 0) snprintf(lines[2], 24, "VOL  %3d%%", gt_pct_of(m->volume, GT_SS_VOLUME_MAX));
    else                snprintf(lines[2], 24, "VOL    --");
    if (m->brightness >= 0) snprintf(lines[3], 24, "BRI  %3d%%", gt_pct_of(m->brightness, GT_SS_BRIGHTNESS_MAX));
    else                    snprintf(lines[3], 24, "BRI    --");
}
```

- [ ] **Step 2: Ensure includes.** The shared section uses `memcpy` (`<string.h>`, already included), `atoi`/`snprintf` (`<stdlib.h>`/`<stdio.h>`). These are only guaranteed under the test build; add at top of file (they are harmless for the interposer build too):

```c
#include <stdio.h>
#include <stdlib.h>
```
(If already present under the `#else` branch, move them to the top so the shared section can use them in the test build.)

- [ ] **Step 3: Add asserts inside `main()`** (before the final `puts("remap ok")`):

```c
    /* HUD: SharedSettings decode */
    {
        unsigned char ss[GT_SS_LEN]; memset(ss, 0, sizeof ss);
        int vol = 10, bri = 7;
        memcpy(ss + GT_SS_OFF_VOLUME, &vol, 4);
        memcpy(ss + GT_SS_OFF_BRIGHTNESS, &bri, 4);
        gt_metrics m; memset(&m, 0, sizeof m);
        if (!gt_shared_settings_decode(ss, GT_SS_LEN, &m)) return fail("ss decode");
        if (m.volume != 10 || m.brightness != 7) return fail("ss values");
        if (!gt_shared_settings_decode(ss, 4, &m)) {} else return fail("short buf must fail");
    }
    /* HUD: battery + time + formatting */
    {
        gt_metrics m; memset(&m, 0, sizeof m);
        gt_battery_parse("16\n", "Charging\n", &m);
        if (m.battery_pct != 16 || !m.charging) return fail("battery parse");
        gt_battery_parse("83\n", "Discharging\n", &m);
        if (m.battery_pct != 83 || m.charging) return fail("battery discharge");
        m.volume = 10; m.brightness = 5; m.hour = 13; m.minute = 31;
        char L[4][24]; gt_fmt_metrics(&m, L);
        if (strncmp(L[0], "BAT   83%", 9)) return fail("fmt bat");
        if (strcmp(L[1], "TIME 13:31")) return fail("fmt time");
        if (strcmp(L[2], "VOL   50%")) return fail("fmt vol");   /* 10/20 = 50% */
        if (strcmp(L[3], "BRI   50%")) return fail("fmt bri");   /* 5/10 = 50% */
    }
```

- [ ] **Step 4: Build + run the host test — expect PASS**

Run: `sh tests/test-05-input-remap.sh`
Expected: exits 0. (First run BEFORE Step 1/3 added, temporarily add one asserting call to see it FAIL to compile/assert, then implement — standard red→green.)

- [ ] **Step 5: Commit**

```bash
git add assets/gt-input-remap.c
git commit -m "feat(F34): HUD metric sampling + formatting (pure C, host-tested)"
```

```json:metadata
{"files": ["assets/gt-input-remap.c", "tests/test-05-input-remap.sh"], "verifyCommand": "sh tests/test-05-input-remap.sh", "acceptanceCriteria": ["gt_shared_settings_decode extracts volume/brightness at named offsets", "gt_fmt_metrics produces the four display strings", "battery percent + charging parse from sysfs strings", "time formats HH:MM from struct tm", "main() still prints 'remap ok'"], "modelTier": "standard"}
```

---

### Task 2: Shim — bitmap font + HUD compose to RGBA (pure C, host-tested)

**Goal:** Rasterize the four text lines + a translucent panel into an RGBA buffer at the top-right, using an embedded bitmap font. Pure C, host-tested.

**Files:**
- Modify: `assets/gt-input-remap.c` (shared-logic section; asserts in `main()`)
- Test: `tests/test-05-input-remap.sh` (unchanged runner)

**Acceptance Criteria:**
- [ ] An embedded 6×8 (or similar) mono bitmap font covers `0-9 A-Z : % + space -` (the glyphs the four lines need).
- [ ] `gt_hud_compose(gt_metrics*, uint32_t *rgba, int *w, int *h)` writes an RGBA8888 image of the panel (translucent dark background, white glyphs) and returns its dimensions.
- [ ] `gt_hud_rect(int screen_w, int screen_h, int panel_w, int panel_h, int *x, int *y)` returns the top-right origin with a small margin.
- [ ] Host asserts: a known glyph sets known pixels; composing a known metrics struct yields nonzero (opaque) background pixels and white text pixels; the panel dims are stable.

**Verify:** `sh tests/test-05-input-remap.sh` → exits 0

**Steps:**

- [ ] **Step 1: Embed the font** (shared-logic section). Use a compact 6×8 mono font as a static array `static const unsigned char GT_FONT[GT_FONT_N][8];` indexed by a `gt_glyph_index(char)` mapping the needed characters; each byte is a row bitmask (bit 5..0 = 6 columns). Provide the actual glyph rows for `0-9 A-Z : % + - space`. (A minimal public-domain 6×8 set — fill each glyph's 8 bytes explicitly; no external file.)

```c
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
static const unsigned char GT_FONT[GT_FONT_N][GT_GLYPH_H] = {
    /* space */ {0,0,0,0,0,0,0,0},
    /* 0 */ {0x1E,0x21,0x25,0x29,0x31,0x21,0x1E,0x00},
    /* ... provide all 41 glyphs explicitly ... */
};
```
(The executor fills the remaining glyph bitmaps; any legible 6×8 set is acceptable — this is data, not logic.)

- [ ] **Step 2: Blitter + compose.** Draw each line's glyphs into the RGBA buffer over a translucent dark panel. Colors are `0xAABBGGRR` (RGBA8888 little-endian as consumed by GL later).

```c
#define GT_HUD_COLS 12                 /* widest line, chars */
#define GT_HUD_PAD  4
#define GT_HUD_LINE_GAP 2
#define GT_HUD_BG   0xC0202020u        /* ~75% opaque dark */
#define GT_HUD_FG   0xFFFFFFFFu        /* opaque white */

static void gt_put_px(uint32_t *rgba, int w, int h, int x, int y, uint32_t c) {
    if (x >= 0 && x < w && y >= 0 && y < h) rgba[y * w + x] = c;
}
static void gt_draw_glyph(uint32_t *rgba, int w, int h, int x, int y, char c, uint32_t col) {
    const unsigned char *g = GT_FONT[gt_glyph_index(c)];
    for (int row = 0; row < GT_GLYPH_H; row++)
        for (int cx = 0; cx < GT_GLYPH_W; cx++)
            if (g[row] & (1 << (GT_GLYPH_W - 1 - cx)))
                gt_put_px(rgba, w, h, x + cx, y + row, col);
}

/* Compose the 4-line panel. rgba must hold GT_HUD_MAX_W*GT_HUD_MAX_H px. */
#define GT_HUD_MAX_W (GT_HUD_COLS * GT_GLYPH_W + 2 * GT_HUD_PAD)
#define GT_HUD_MAX_H (4 * GT_GLYPH_H + 3 * GT_HUD_LINE_GAP + 2 * GT_HUD_PAD)
static void gt_hud_compose(const gt_metrics *m, uint32_t *rgba, int *out_w, int *out_h) {
    char L[4][24]; gt_fmt_metrics(m, L);
    int w = GT_HUD_MAX_W, h = GT_HUD_MAX_H;
    for (int i = 0; i < w * h; i++) rgba[i] = GT_HUD_BG;
    for (int line = 0; line < 4; line++) {
        int y = GT_HUD_PAD + line * (GT_GLYPH_H + GT_HUD_LINE_GAP);
        for (int col = 0; L[line][col] && col < GT_HUD_COLS; col++)
            gt_draw_glyph(rgba, w, h, GT_HUD_PAD + col * GT_GLYPH_W, y, L[line][col], GT_HUD_FG);
    }
    *out_w = w; *out_h = h;
}

static void gt_hud_rect(int sw, int sh, int pw, int ph, int *x, int *y) {
    int margin = 8;
    *x = sw - pw - margin; if (*x < 0) *x = 0;
    *y = margin;           if (*y + ph > sh) *y = sh - ph;
}
```

- [ ] **Step 3: Asserts in `main()`**

```c
    {
        gt_metrics m; memset(&m, 0, sizeof m);
        m.battery_pct = 16; m.charging = 1; m.volume = 10; m.brightness = 5; m.hour = 9; m.minute = 5;
        static uint32_t buf[GT_HUD_MAX_W * GT_HUD_MAX_H];
        int w = 0, hh = 0; gt_hud_compose(&m, buf, &w, &hh);
        if (w != GT_HUD_MAX_W || hh != GT_HUD_MAX_H) return fail("hud dims");
        int white = 0; for (int i = 0; i < w * hh; i++) if (buf[i] == GT_HUD_FG) white++;
        if (white == 0) return fail("hud has no text pixels");
        if (buf[0] != GT_HUD_BG) return fail("hud bg corner");
        int x = 0, y = 0; gt_hud_rect(640, 480, w, hh, &x, &y);
        if (x + w > 640 || x < 0 || y < 0) return fail("hud rect top-right");
    }
```

- [ ] **Step 4: Build + run — expect PASS**: `sh tests/test-05-input-remap.sh`

- [ ] **Step 5: Commit**

```bash
git add assets/gt-input-remap.c
git commit -m "feat(F34): embedded font + HUD compose to RGBA (pure C, host-tested)"
```

```json:metadata
{"files": ["assets/gt-input-remap.c", "tests/test-05-input-remap.sh"], "verifyCommand": "sh tests/test-05-input-remap.sh", "acceptanceCriteria": ["embedded 6x8 font covers 0-9 A-Z : % + space -", "gt_hud_compose writes RGBA panel + returns dims", "gt_hud_rect returns top-right origin with margin", "host asserts: text pixels present, bg set, rect in-bounds"], "modelTier": "standard"}
```

---

### Task 3: Shim — env-flag gating, Menu toggle, remap decouple (interposer, host-tested where pure)

**Goal:** Introduce `GT_INPUT_REMAP` (gates the v1 index remap), `GT_HUD` (enables the HUD half), and `GT_HUD_DEBUG`; add the Menu-tap toggle with event-swallow; keep gptk synthesis unchanged. Preserve remap behavior exactly for allowlisted ports.

**Files:**
- Modify: `assets/gt-input-remap.c` (constructor, poll interposers, `gt_rewrite`, `gt_ensure_joystick_open`; a pure toggle helper + asserts in `main()`)
- Test: `tests/test-05-input-remap.sh` (unchanged runner)

**Acceptance Criteria:**
- [ ] The v1 remap (`gt_rewrite`'s jbutton path) runs only when `GT_INPUT_REMAP=1`; with it unset, jbutton events pass through unmodified.
- [ ] gptk synthesis still activates from `GT_REMAP_GPTK` (unchanged), independent of `GT_HUD`.
- [ ] When `GT_HUD=1`, a Menu-button *down* (post-remap `guide`/index 8, and its raw form when remap is off) toggles a `gt_hud_visible` bool and the event is swallowed (not delivered to the app); Menu-up is also swallowed.
- [ ] `gt_ensure_joystick_open` opens joysticks when EITHER gptk synthesis OR HUD is active (so the toggle gets events on a HUD-only port).
- [ ] Pure toggle helper `gt_toggle_on_menu(int is_menu_down)` flips and reports swallow; asserted in `main()`.
- [ ] `main()` still prints `remap ok`.

**Verify:** `sh tests/test-05-input-remap.sh` → exits 0

**Steps:**

- [ ] **Step 1: Pure toggle helper** (shared-logic section):

```c
/* Toggle state machine (pure): returns 1 if the event should be swallowed. */
static int gt_menu_toggle(int *visible, int is_menu, int is_down) {
    if (!is_menu) return 0;
    if (is_down) *visible = !*visible;   /* flip on press */
    return 1;                            /* swallow both down and up */
}
```
Assert in `main()`:
```c
    { int vis = 0;
      if (!gt_menu_toggle(&vis, 1, 1) || vis != 1) return fail("toggle on");
      if (!gt_menu_toggle(&vis, 1, 0) || vis != 1) return fail("toggle up swallow");
      if (!gt_menu_toggle(&vis, 1, 1) || vis != 0) return fail("toggle off");
      if (gt_menu_toggle(&vis, 0, 1)) return fail("non-menu not swallowed"); }
```

- [ ] **Step 2: Env flags in the interposer half.** Add getters mirroring `gt_debug()`:

```c
static int gt_flag(const char *name) {
    const char *e = getenv(name); return (e && *e && e[0] != '0') ? 1 : 0;
}
static int gt_remap_on(void) { static int v = -1; if (v < 0) v = gt_flag("GT_INPUT_REMAP"); return v; }
static int gt_hud_on(void)   { static int v = -1; if (v < 0) v = gt_flag("GT_HUD"); return v; }
```
Global: `static int gt_hud_visible;`

- [ ] **Step 3: Gate v1 remap.** In `gt_rewrite`, wrap the jbutton index-remap so it only runs when `gt_remap_on()`. The gptk replacement (which needs `gt_map.loaded`) stays as-is. Concretely, the `ev->jbutton.button = gt_remap(from)` block becomes:

```c
        if (gt_remap_on() && ev->jbutton.padding1 != GT_REMAPPED_MARKER) {
            unsigned char from = ev->jbutton.button;
            ev->jbutton.button = gt_remap(from);
            ev->jbutton.padding1 = GT_REMAPPED_MARKER;
            /* ...existing debug print... */
        }
```
(Leave the gptk `gt_map.loaded` replacement below it unchanged. Note: the Menu button index the HUD checks is 8 when remap is on; when remap is off it is the raw device index for Menu — handle both in Step 4 by checking the pre/post value.)

- [ ] **Step 4: Toggle in the poll interposers.** In BOTH `SDL_PollEvent` and `SDL_WaitEventTimeout`, after obtaining a real event (`r == 1`), when `gt_hud_on()` and the event is a JOYBUTTONDOWN/UP for Menu, run the toggle and, if swallowed, turn the event into a no-op the app ignores (set `ev->type = SDL_FIRSTEVENT` / return as if no event — simplest: skip returning it by re-polling). Recommended: detect Menu on the *raw* button before remap. Add a helper called from the `r==1` branch:

```c
/* returns 1 if the event was consumed by the HUD (caller should not deliver it) */
static int gt_hud_intercept(SDL_Event *ev) {
    if (!gt_hud_on() || !ev) return 0;
    if (ev->type != SDL_JOYBUTTONDOWN && ev->type != SDL_JOYBUTTONUP) return 0;
    unsigned char b = ev->jbutton.button;
    int is_menu = (b == 8) || (gt_remap(b) == 8);  /* post- or pre-remap Menu */
    return gt_menu_toggle(&gt_hud_visible, is_menu, ev->type == SDL_JOYBUTTONDOWN);
}
```
In each interposer, replace the `if (r == 1) { gt_trace(...); gt_rewrite(ev); }` with a loop that drops HUD-consumed events:
```c
        r = real(ev);
        while (r == 1 && gt_hud_intercept(ev)) r = real(ev);  /* swallow Menu */
        if (r == 1) { gt_trace("poll", ev); gt_rewrite(ev); }
```
(Do the analogous change in `SDL_WaitEventTimeout` using `real(ev, timeout)`.)

- [ ] **Step 5: Joystick-open gating.** In `gt_ensure_joystick_open`, change the early-out from `!gt_map.loaded` to `!(gt_map.loaded || gt_hud_on())`, so a HUD-only port still opens joysticks to receive Menu.

- [ ] **Step 6: Constructor.** In `gt_init`, add a debug line when `gt_hud_on()` (e.g. `fprintf(stderr, "gt-input-remap: HUD enabled\n")`). Leave gptk loading unchanged.

- [ ] **Step 7: Build + run host test — expect PASS**: `sh tests/test-05-input-remap.sh`

- [ ] **Step 8: Commit**

```bash
git add assets/gt-input-remap.c
git commit -m "feat(F34): GT_INPUT_REMAP/GT_HUD gating + Menu toggle; decouple remap"
```

```json:metadata
{"files": ["assets/gt-input-remap.c", "tests/test-05-input-remap.sh"], "verifyCommand": "sh tests/test-05-input-remap.sh", "acceptanceCriteria": ["v1 remap runs only when GT_INPUT_REMAP=1", "gptk synthesis unchanged, independent of GT_HUD", "Menu down toggles gt_hud_visible and both edges are swallowed when GT_HUD=1", "gt_ensure_joystick_open opens for HUD too", "gt_menu_toggle asserted in main()", "main() prints 'remap ok'"], "modelTier": "standard"}
```

---

### Task 4: Shim — GL/GLES swap-interpose draw backend + Makefile (device-verified)

**Goal:** When `gt_hud_visible`, upload the CPU-composed HUD as one textured quad in the port's GL context, interposing `SDL_GL_SwapWindow` and `eglSwapBuffers`, with full GL-state save/restore, a single-draw-per-frame guard, and crash-safe disable-on-error. Resolve all GL/EGL symbols dynamically.

**Files:**
- Modify: `assets/gt-input-remap.c` (interposer half: GL loader, shader, draw, swap interposers)
- Modify: `Makefile` (`shim` target: add GLES2/EGL headers)

**Acceptance Criteria:**
- [ ] `SDL_GL_SwapWindow(SDL_Window*)` and `eglSwapBuffers(void*, void*)` are interposed; both call the real function via `dlsym(RTLD_NEXT, …)` and, when `gt_hud_visible`, draw the HUD immediately before it.
- [ ] A per-frame guard prevents drawing twice when `SDL_GL_SwapWindow` internally calls `eglSwapBuffers`.
- [ ] GL state saved before / restored after: current program, active texture + bound 2D texture, blend enable + blend func, depth-test enable, cull-face enable, viewport, `GL_ARRAY_BUFFER` binding, and the vertex-attrib arrays used.
- [ ] On any GL error (symbol resolve fail, shader compile fail), the HUD self-disables for the session (no host crash).
- [ ] `make shim` compiles `gt-input-remap.so` (and `gt-fmod-audio.so`) cleanly; `-ldl` only at link (GL/EGL resolved at runtime).
- [ ] The shim still passes `sh tests/test-05-input-remap.sh` (host build unaffected).

**Verify:** `make shim` → prints the built `.so` files; `sh tests/test-05-input-remap.sh` → exits 0. (Visual/behavioral proof is Task 8.)

**Steps:**

- [ ] **Step 1: Makefile — add GL/EGL headers** to the `shim` target's apt install (still link `-ldl` only):

```make
	  'apt-get update -qq && apt-get install -y -qq gcc libsdl2-dev libgles2-mesa-dev libegl1-mesa-dev >/dev/null && \
	   gcc -O2 -Wall -shared -fPIC -o gt-input-remap.so gt-input-remap.c -ldl && strip gt-input-remap.so && \
	   gcc -O2 -Wall -shared -fPIC -o gt-fmod-audio.so gt-fmod-audio.c -ldl && strip gt-fmod-audio.so'
```

- [ ] **Step 2: GL types/loader** (interposer half only, under the `#else`). Include `<GLES2/gl2.h>` and `<EGL/egl.h>`. Resolve entry points once via `eglGetProcAddress` with `dlsym(RTLD_DEFAULT, …)` fallback into function pointers (`glCreateShader`, `glShaderSource`, `glCompileShader`, `glGetShaderiv`, `glCreateProgram`, `glAttachShader`, `glLinkProgram`, `glUseProgram`, `glGenTextures`, `glBindTexture`, `glTexImage2D`, `glTexParameteri`, `glActiveTexture`, `glGenBuffers`, `glBindBuffer`, `glBufferData`, `glVertexAttribPointer`, `glEnableVertexAttribArray`, `glGetAttribLocation`, `glGetUniformLocation`, `glUniform1i`, `glUniform4f`, `glDrawArrays`, `glEnable`, `glDisable`, `glBlendFunc`, `glViewport`, `glGetIntegerv`, `glIsEnabled`, `glGetError`). A single `gt_gl_resolve()` returns 0 and sets `gt_gl_dead = 1` if any required symbol is missing.

- [ ] **Step 3: Shader + geometry.** A minimal GLES2 program drawing a screen-space quad from NDC with a sampled texture:

```c
static const char *GT_VS =
  "attribute vec2 aPos; attribute vec2 aUV; varying vec2 vUV;"
  "void main(){ vUV = aUV; gl_Position = vec4(aPos, 0.0, 1.0); }";
static const char *GT_FS =
  "precision mediump float; varying vec2 vUV; uniform sampler2D uTex;"
  "void main(){ gl_FragColor = texture2D(uTex, vUV); }";
```
Compile lazily on first draw (context is current in the swap call); on failure set `gt_gl_dead = 1`. Build the quad vertices from `gt_hud_rect` + the viewport, converting pixel rect → NDC.

- [ ] **Step 4: Draw with state save/restore.** Implement `gt_hud_draw(void)`:
  - `if (gt_gl_dead || !gt_hud_visible) return;`
  - Recompose the RGBA (Task 2) at most once per second (reuse the sample cache; Task 1); upload via `glTexImage2D` only when the text changed.
  - **Save:** `GLint p; glGetIntegerv(GL_CURRENT_PROGRAM,&p);` plus `GL_ACTIVE_TEXTURE`, `GL_TEXTURE_BINDING_2D`, `GL_ARRAY_BUFFER_BINDING`, `GL_VIEWPORT` (4), `glIsEnabled(GL_BLEND/GL_DEPTH_TEST/GL_CULL_FACE)`, and blend func (`GL_BLEND_SRC_ALPHA`/`GL_BLEND_DST_ALPHA` via `glGetIntegerv`). Save the two vertex-attrib enables/pointers we use.
  - Set our state (use program, bind texture unit 0, enable blend `GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA`, disable depth/cull), draw the quad with `glDrawArrays(GL_TRIANGLE_STRIP, 0, 4)`.
  - **Restore** every saved item in reverse.
  - If `glGetError()` is nonzero after setup, set `gt_gl_dead = 1` and restore.

- [ ] **Step 5: Interpose the swaps** with a per-frame guard:

```c
static int gt_in_swap;   /* reentrancy guard for the nested egl call */
void SDL_GL_SwapWindow(void *win) {
    static void (*real)(void*); if (!real) real = (void(*)(void*))dlsym(RTLD_NEXT, "SDL_GL_SwapWindow");
    gt_in_swap = 1; gt_hud_draw(); real(win); gt_in_swap = 0;
}
unsigned int eglSwapBuffers(void *dpy, void *surf) {
    static unsigned int (*real)(void*,void*); if (!real) real = (unsigned int(*)(void*,void*))dlsym(RTLD_NEXT, "eglSwapBuffers");
    if (!gt_in_swap) gt_hud_draw();      /* skip if SDL_GL_SwapWindow already drew */
    return real(dpy, surf);
}
```

- [ ] **Step 6: Build the shim**

Run: `make shim`
Expected: builds and lists `assets/gt-input-remap.so` and `assets/gt-fmod-audio.so`. Then `sh tests/test-05-input-remap.sh` still exits 0.

- [ ] **Step 7: Commit**

```bash
git add assets/gt-input-remap.c Makefile
git commit -m "feat(F34): GL swap-interpose HUD draw backend + shim build deps"
```

```json:metadata
{"files": ["assets/gt-input-remap.c", "Makefile"], "verifyCommand": "make shim && sh tests/test-05-input-remap.sh", "acceptanceCriteria": ["SDL_GL_SwapWindow + eglSwapBuffers interposed via RTLD_NEXT, draw before real swap when visible", "per-frame guard prevents double draw", "full GL-state save/restore around the draw", "GL error self-disables the HUD (no crash)", "make shim builds cleanly, -ldl only", "host test still passes"], "modelTier": "frontier"}
```

---

### Task 5: build-pak.sh — universal preload + flag plumbing + HUD blocklist (host-tested via fixtures)

**Goal:** Preload the shim on every h700 port; set `GT_INPUT_REMAP=1` + `GT_REMAP_GPTK` only for allowlisted ports; set `GT_HUD=1` unless the port is on a blocklist. Ship `assets/gt-hud-blocklist.txt`. Update `test-05`; add `test-13`.

**Files:**
- Modify: `build/build-pak.sh` (the `gt-h700-port-remap` injected block ~526-548; ensure `gt-hud-blocklist.txt` is copied into the pak `files/` like `gt-remap-ports.txt`)
- Create: `assets/gt-hud-blocklist.txt` (pak-shipped defaults; header comment + initially empty of entries)
- Modify: `tests/test-05-input-remap.sh` (LD_PRELOAD now unconditional; add `GT_INPUT_REMAP` gating assertions)
- Create: `tests/test-13-overlay-hud.sh`

**Acceptance Criteria:**
- [ ] In `run_port`, `export LD_PRELOAD=…/gt-input-remap.so` is emitted **unconditionally** for `PLATFORM=h700` (not inside the allowlist check).
- [ ] `GT_INPUT_REMAP=1` and `GT_REMAP_GPTK` are exported only inside the allowlist check (`gt-remap-ports.txt` / user `use-remap-ports`).
- [ ] `GT_HUD=1` is exported unless `$ROM_NAME` is in `files/gt-hud-blocklist.txt` or the user's `PORTS-portmaster/use-hud-blocklist`; `GT_HUD_DEBUG` wired the same way as `GT_INPUT_REMAP_DEBUG` (optional, off by default).
- [ ] `assets/gt-hud-blocklist.txt` exists and is copied to the pak's `files/` during build.
- [ ] Edits are marker-guarded, idempotent, `sh -n`-clean; `test-05` and `test-13` pass.

**Verify:** `sh tests/test-05-input-remap.sh && sh tests/test-13-overlay-hud.sh` → both exit 0

**Steps:**

- [ ] **Step 1: Restructure the injected block** in `build/build-pak.sh`. Replace the body printed by the `gt-h700-port-remap` awk block so it emits (into `launch.sh`) this structure — LD_PRELOAD out of the list check, remap env in it, HUD env gated by blocklist:

```sh
    # gt-h700-port-remap / gt-h700-hud (F25/F26/F34)
    if [ "$PLATFORM" = "h700" ]; then
        export LD_PRELOAD="$PAK_DIR/lib/gt-input-remap.so${LD_PRELOAD:+:$LD_PRELOAD}"
        # input remap stays opt-in (allowlist): TrimUI index remap + gptk synthesis
        if grep -Fxq "$ROM_NAME" "$PAK_DIR/files/gt-remap-ports.txt" 2>/dev/null \
            || grep -Fxq "$ROM_NAME" "$USERDATA_PATH/PORTS-portmaster/use-remap-ports" 2>/dev/null; then
            echo "Enabling input remap for $ROM_NAME"
            export GT_INPUT_REMAP=1
            for gt_gptk in "$GAMEDIR"/*.gptk; do
                [ -f "$gt_gptk" ] && export GT_REMAP_GPTK="$gt_gptk"
                break
            done
        fi
        # HUD is opt-out (blocklist): on for every port unless listed
        if grep -Fxq "$ROM_NAME" "$PAK_DIR/files/gt-hud-blocklist.txt" 2>/dev/null \
            || grep -Fxq "$ROM_NAME" "$USERDATA_PATH/PORTS-portmaster/use-hud-blocklist" 2>/dev/null; then
            echo "HUD disabled (blocklisted) for $ROM_NAME"
        else
            export GT_HUD=1
        fi
    fi
```
Keep the awk anchor (`$0 == "    \"$PAK_DIR/bin/bash\" \"$ROM_PATH\""`) and the marker guard; update the marker check to cover the combined block (e.g. still `grep -q 'gt-h700-port-remap'`).

- [ ] **Step 2: Ship the blocklist file.** Wherever `gt-remap-ports.txt` is copied from `assets/` into the pak's `files/`, add `gt-hud-blocklist.txt` alongside. Create `assets/gt-hud-blocklist.txt`:

```
# gt-hud-blocklist.txt — ports where the in-game HUD (F34) misbehaves.
# One launcher filename per line (exact, e.g. "SomePort.sh"). Comment lines
# (leading #) are inert. The HUD is ON by default for every other port;
# users can add their own entries in
# $USERDATA_PATH/PORTS-portmaster/use-hud-blocklist (no rebuild needed).
```

- [ ] **Step 3: Update `test-05`.** The LD_PRELOAD assertion (line ~40) stays (still present), but add:
```sh
# F34: LD_PRELOAD is now unconditional for h700; remap is gated by GT_INPUT_REMAP
assert_contains "$work/launch.sh" 'export GT_INPUT_REMAP=1'
# GT_INPUT_REMAP must sit inside the allowlist check, LD_PRELOAD outside it
lp=$(grep -n 'export LD_PRELOAD=' "$work/launch.sh" | head -1 | cut -d: -f1)
gate=$(grep -n 'gt-remap-ports.txt' "$work/launch.sh" | head -1 | cut -d: -f1)
ir=$(grep -n 'export GT_INPUT_REMAP=1' "$work/launch.sh" | head -1 | cut -d: -f1)
[ "$lp" -lt "$gate" ] || { echo "LD_PRELOAD must precede (be outside) the remap allowlist gate"; exit 1; }
[ "$gate" -lt "$ir" ] || { echo "GT_INPUT_REMAP must be inside the allowlist gate"; exit 1; }
```

- [ ] **Step 4: Write `tests/test-13-overlay-hud.sh`** (mirrors `test-12`): build the fixture with `GT_STAGE_EDIT_ONLY`, then assert:
  - marker present; `export GT_HUD=1` present; blocklist grep against `files/gt-hud-blocklist.txt` AND `use-hud-blocklist` present;
  - `GT_HUD=1` is in the `else` (not gated by the allowlist); LD_PRELOAD unconditional;
  - `assets/gt-hud-blocklist.txt` exists;
  - `sh -n "$work/launch.sh"` parses;
  - idempotency: rerun build, marker count == 1, still parses.

```sh
#!/bin/sh
. "$(dirname -- "$0")/helpers.sh"
work="$SANDBOX/pmpak"; mkdir -p "$work"
cp "$TROOT/fixtures/portmaster-pak-skeleton/pak.json.fixture" "$work/pak.json"
cp "$TROOT/fixtures/portmaster-pak-skeleton/launch.sh.fixture" "$work/launch.sh"
GT_STAGE_EDIT_ONLY="$work" sh "$ROOT/build/build-pak.sh" portmaster
assert_contains "$work/launch.sh" 'export GT_HUD=1'
assert_contains "$work/launch.sh" 'gt-hud-blocklist.txt'
assert_contains "$work/launch.sh" 'use-hud-blocklist'
assert_contains "$work/launch.sh" 'export LD_PRELOAD="$PAK_DIR/lib/gt-input-remap.so'
[ -f "$ROOT/assets/gt-hud-blocklist.txt" ] || { echo "missing assets/gt-hud-blocklist.txt"; exit 1; }
sh -n "$work/launch.sh" || { echo "launch.sh does not parse"; exit 1; }
GT_STAGE_EDIT_ONLY="$work" sh "$ROOT/build/build-pak.sh" portmaster
assert_eq "$(grep -c 'gt-h700-port-remap' "$work/launch.sh")" "1" "combined block idempotent"
sh -n "$work/launch.sh" || { echo "launch.sh does not parse after rerun"; exit 1; }
```

- [ ] **Step 5: Run both fixture tests — expect PASS**: `sh tests/test-05-input-remap.sh && sh tests/test-13-overlay-hud.sh`

- [ ] **Step 6: Commit**

```bash
git add build/build-pak.sh assets/gt-hud-blocklist.txt tests/test-05-input-remap.sh tests/test-13-overlay-hud.sh
git commit -m "feat(F34): universal shim preload + HUD blocklist plumbing"
```

```json:metadata
{"files": ["build/build-pak.sh", "assets/gt-hud-blocklist.txt", "tests/test-05-input-remap.sh", "tests/test-13-overlay-hud.sh"], "verifyCommand": "sh tests/test-05-input-remap.sh && sh tests/test-13-overlay-hud.sh", "acceptanceCriteria": ["LD_PRELOAD unconditional for h700", "GT_INPUT_REMAP + GT_REMAP_GPTK only inside allowlist check", "GT_HUD=1 unless blocklisted (pak file or user override)", "assets/gt-hud-blocklist.txt exists + shipped to files/", "marker-guarded, idempotent, sh -n clean; test-05 + test-13 pass"], "modelTier": "standard"}
```

---

### Task 6: Docs — F34 section in docs/h700-fixes.md + release-notes stub

**Goal:** Document F34 (what it does, the opt-out/allowlist model, the SharedSettings source + fallback, the spike verdict pointer) and prep terse 0.3.0 release notes covering F33+F34.

**Files:**
- Modify: `docs/h700-fixes.md` (bump the `Fix IDs (F1–F33)` line to `F34`; add a `## In-game status overlay (F34)` section)
- Modify: `README.md` if it enumerates fixes/ports behavior (check; update the shim/ports section to mention the universal preload + HUD)

**Acceptance Criteria:**
- [ ] `docs/h700-fixes.md` has an F34 section: swap-interpose HUD, Menu toggle, four metrics, opt-out blocklist vs opt-in remap, SharedSettings primary + fallback, and a one-line pointer to the spike verdict (hardware-layer EPERM) and the spec.
- [ ] The `F1–F33` range line reads `F1–F34`.
- [ ] Release-notes stub follows the terse style (`### Fixes` bullets + `### Upgrading from v0.2.3`), covering F33 + F34.

**Verify:** `grep -n 'F34' docs/h700-fixes.md` → shows the new section and the bumped range line.

**Steps:**

- [ ] **Step 1: Bump the range line** in `docs/h700-fixes.md` (`Fix IDs (F1–F33)` → `F1–F34`).
- [ ] **Step 2: Add the F34 section** (prose, matching the doc's style; describe behavior, gating, sources, and reference the spec + spike verdict).
- [ ] **Step 3: Draft release notes** for 0.3.0 (terse; `### Fixes` with F33 + F34 bullets stating *what*, and `### Upgrading from v0.2.3` = unzip-over). Keep in the commit message or a scratch notes file per the usual release flow.
- [ ] **Step 4: Commit**

```bash
git add docs/h700-fixes.md README.md
git commit -m "docs(F34): in-game overlay HUD section + range bump"
```

```json:metadata
{"files": ["docs/h700-fixes.md", "README.md"], "verifyCommand": "grep -n 'F34' docs/h700-fixes.md", "acceptanceCriteria": ["F34 section describes HUD, toggle, metrics, opt-out/allowlist, SharedSettings + fallback, spike-verdict pointer", "F1-F33 range line bumped to F1-F34", "terse 0.3.0 release-notes stub covering F33+F34"], "modelTier": "mechanical"}
```

---

### Task 7: Device gate — per-engine verification + SharedSettings/keymon confirm (RG SP)

**Goal:** USER-ORDERED GATE. Prove the HUD works on-device across each engine family, confirm the SharedSettings offsets and live keymon updates, verify toggle-off restores rendering, and confirm zero regression to allowlisted remap/keyboard ports.

> **USER-ORDERED GATE — NON-SKIPPABLE.** This task was requested by the user in the current conversation. It MUST NOT be closed by walking around it, by declaring it "verified inline", or by substituting a cheaper check. Close only after every item in `acceptanceCriteria` has been re-validated independently, with output captured.

**Files:**
- None (verification). May produce a one-line correction to `GT_SS_OFF_*` in `assets/gt-input-remap.c` (Task 1) and/or additions to `assets/gt-hud-blocklist.txt` (Task 5) if a port is found broken.

**Acceptance Criteria:**
- [ ] **SharedSettings offsets confirmed:** on the RG SP, nudge volume then brightness and re-dump `/dev/shm/SharedSettings`; the int32 that moves for each matches `GT_SS_OFF_VOLUME` / `GT_SS_OFF_BRIGHTNESS` (correct the constants + re-run `test-05` if not).
- [ ] **keymon live-update confirmed:** with a port running, changing volume/brightness updates the values the HUD reads (readout moves).
- [ ] **Per-engine HUD pass** (install the rebuilt shim via scp-temp+`mv`; enable HUD): GameMaker (UFO 50 or Deltarune), LÖVE (Balatro), solarus (Tunics!) — Menu toggles the panel on/off; all four values correct + live; **toggle-off leaves the game rendering pristine** (no leaked GL state / artifacts); no crash.
- [ ] **Raw-SDL no-op:** a software-rendered port (2048) shows no HUD and does not crash when Menu is pressed.
- [ ] **Regression:** an allowlisted remap port and a gptk keyboard port (e.g. Tunics! + BYTEPATH) still play with correct input (remap + keyboard synthesis intact under `GT_INPUT_REMAP=1`).
- [ ] `GT_HUD_DEBUG=1` trace in the pak log shows the expected swap path per engine.

**Verify:** device session on `ssh root@10.0.1.16`: install shim, launch each engine's port, toggle HUD, capture the pak log (`GT_HUD_DEBUG=1`) + Camille's visual confirmation for each acceptance item.

**Steps:**

- [ ] **Step 1:** Build the shim (`make shim`) and stage it: `scp` `assets/gt-input-remap.so` to a temp path on the RG SP, then `mv` into the pak's `lib/` (never overwrite in place). Confirm the launch.sh in place exports `GT_HUD=1` (rebuild/install launch.sh if testing the full pak).
- [ ] **Step 2:** Confirm SharedSettings offsets (nudge + re-dump) and keymon live-update; correct `GT_SS_OFF_*` and re-run `test-05` if needed.
- [ ] **Step 3:** For each engine port: enable HUD, toggle via Menu, verify the four values (change volume/brightness mid-game), toggle off and confirm pristine rendering, watch for crashes; capture `GT_HUD_DEBUG` log.
- [ ] **Step 4:** Raw-SDL no-op check (2048).
- [ ] **Step 5:** Regression check on a remap port + a keyboard port.
- [ ] **Step 6:** Record results in the status report; add any broken port to `assets/gt-hud-blocklist.txt`.

```json:metadata
{"files": ["assets/gt-input-remap.c", "assets/gt-hud-blocklist.txt"], "verifyCommand": "ssh root@10.0.1.16 (device gate — see steps)", "acceptanceCriteria": ["SharedSettings VOL/BRI offsets confirmed on-device (constants corrected + test-05 re-run if needed)", "keymon updates volume/brightness live during a port", "HUD toggles + shows correct live values on GameMaker, LOVE, solarus; toggle-off leaves rendering pristine; no crash", "raw-SDL port shows no HUD and does not crash", "allowlisted remap + keyboard ports still have correct input", "GT_HUD_DEBUG trace shows expected swap path"], "userGate": true, "tags": ["user-gate"], "requiresUserSpecification": false, "gateScope": "one-then-all", "modelTier": "standard"}
```

---

## Self-Review

**Spec coverage:**
- Architecture (shim, present-interpose, toggle, sampling) → Tasks 1,3,4. ✓
- Rendering (CPU-compose one quad, font, GL-state discipline, dynamic resolution, single-draw guard, crash-safety) → Tasks 2,4. ✓
- Data sampling (battery/time/SharedSettings/fallback, cadence) → Task 1 (+ device confirm Task 7). ✓
- Interaction & layout (Menu toggle default-off, top-right panel) → Tasks 2,3. ✓
- Enabling & gating (universal preload, asymmetric defaults, blocklist, decouple flags) → Tasks 3,5. ✓
- Testing (host + per-engine device gate) → Tasks 1–5 host, Task 7 device. ✓
- Rollout/0.3.0 (F34, bundle w/ F33, Stage-1, regression guard, docs) → Task 6 + Global Constraints + Task 7. ✓
- Out of scope (Stage-2 software path, RG DS, hardware-layer) → excluded; hardware-layer rationale in Task 6 doc pointer. ✓

**Type consistency:** `gt_metrics`, `gt_shared_settings_decode`, `gt_fmt_metrics`, `gt_hud_compose`, `gt_hud_rect`, `gt_menu_toggle`, `gt_hud_visible`, `gt_hud_on`/`gt_remap_on`, `gt_hud_draw`, `gt_in_swap`, `GT_SS_OFF_*`, `GT_HUD_*W/H` used consistently across Tasks 1→4. ✓

**Placeholder scan:** the only deferred value is the SharedSettings offset constants — explicitly flagged as device-confirmed in Task 7 with a self-consistent host test in Task 1 (not a code placeholder). Font glyph bytes are data to fill (any legible 6×8 set), not logic. ✓

## Notes for execution
- Tasks 1→2→3 are same-file sequential (avoid merge churn). Task 4 depends on 2+3. Task 5 depends on 3 (flag names). Task 6 depends on 4+5. Task 7 (device gate) depends on 4+5+6 and needs the RG SP online + Camille.
- Do NOT push, tag, run a publishing `make pak`, or cut the 0.3.0 release without Camille's explicit go-ahead.
