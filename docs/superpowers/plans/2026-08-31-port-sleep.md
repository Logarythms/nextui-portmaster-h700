# F47 Port Sleep Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Power button / lid close suspends the device during a running port; power press wakes it with game, controls, screen, and audio working.

**Architecture:** A `gt-sleepmon` C daemon (spawned per port by `run_port`) watches `/dev/input/event0`, freezes the port tree, and runs NextUI's stock `suspend` script; a pak-shipped ALSA ioplug proxy (`libasound_module_pcm_gt_suspend.so`), routed in via an env-supplied ALSA config, transparently closes+reopens the real audio device after resume (the only thing that un-wedges the BSP's post-suspend PCM).

**Tech Stack:** C (evdev, /proc, signals; alsa-lib ioplug API), POSIX sh (build-pak.sh awk splices), Docker bullseye cross-builds (arm64 + arm/v7), fixture-based sh tests.

**Spec:** `docs/superpowers/specs/2026-08-31-port-sleep-design.md` — read it first; its "Grounding" section carries all device-proven facts (event codes, suspend-script contract, audio-wedge root cause, stock asound.conf). Do NOT re-derive them.

## Global Constraints

- Branch `feat/port-sleep` in `/Users/camillemainz/dev/nextui-portmaster-h700`. **NEVER push, tag, or release** — local main holds unreleased v0.4.0; Camille bundles releases himself.
- All launch.sh edits are marker-guarded awk splices in `build/build-pak.sh` (`if ! grep -q 'gt-h700-<name>' "$f"`), POSIX sh only in injected code (launch.sh runs under BusyBox sh, no bashisms, no `set -e` assumptions).
- The stock suspend script must always be invoked with explicit env: `SYSTEM_PATH=/mnt/SDCARD/.system/h700`, `LD_LIBRARY_PATH=/mnt/SDCARD/.system/h700/lib`, and a system `PATH` (`/usr/bin:/bin:/usr/sbin:/sbin`) — the pak's busybox wrapper dir must NOT shadow `pgrep`/`alsactl` (F15-class trap).
- On suspend failure: log and continue. **NEVER escalate to poweroff** (ports have no autosave).
- Docker cross-builds must be `file`(1)-verified fail-closed (F45 wrong-arch trap).
- Device test hygiene: never overwrite a running sh script in place (scp→temp+`mv`); fire the suspend script detached (`nohup … &`) when triggering over ssh (it stops wifi); resolve PIDs via `/proc/*/comm`, never `pgrep -f`.
- `make test` green from repo root before every commit. RG SP = `ssh root@10.0.1.16`.

**User decisions (already made):** Full package — watcher + ALSA proxy ("option 2", 2026-08-31). Ports only; PortMaster GUI keeps its no-sleep ruling. Spec approved as committed (`fb8c04c`).

---

### Task 1: Device spike — ALSA config routing mechanics

**Goal:** Prove on the RG SP that an env-supplied ALSA config can reroute a port's "default" PCM (config include + `pcm.!default` override + absolute-path plugin `lib` key), and record the exact working config text.

**Files:**
- No repo changes (throwaway spike; findings recorded as a task comment and, if they contradict the templates in Tasks 3–4, those templates are corrected before implementation).

**Acceptance Criteria:**
- [ ] A file passed via `ALSA_CONFIG_PATH` that starts with `</usr/share/alsa/alsa.conf>` and then redefines `pcm.!default` as `type plug` over a verbatim copy of the stock hooks chain still plays port audio (hw_ptr advances on `/proc/asound/card0/pcm0p/sub0/status` while Balatro runs with the env set).
- [ ] An absolute-path `pcm_type.<x>.lib` definition dlopens a module from a pak-style path on the SD card (probe with a copy of `/usr/lib/aarch64-linux-gnu/alsa-lib/libasound_module_pcm_bluealsa.so` under `/mnt/SDCARD/…`; a config/args error from bluealsa is PASS — only `cannot open shared object` is FAIL).
- [ ] Findings (env semantics, include/override behavior, any deviation from the Task 4 template) posted as a comment on this task.
- [ ] Device left clean: spike files removed, no port left running, no launch.sh modified.

**Verify:** `ssh root@10.0.1.16 'grep -E "state|hw_ptr" /proc/asound/card0/pcm0p/sub0/status'` shows `state: RUNNING` with hw_ptr advancing between two samples ~0.5s apart, while Balatro runs with the test env.

**Steps:**

- [ ] **Step 1: Write the test config to the device** (`/tmp/gt-spike-asound.conf`):

```
</usr/share/alsa/alsa.conf>

pcm.gt_stock_hooks {
    type hooks
    slave.pcm "hw:audiocodec"
    hooks.0 {
        type ctl_elems
        hook_args [
            { name "LINEOUT Switch" preserve true lock true value 1 }
            { name "SPK Switch" preserve true lock true value 1 }
            { name "OutputL Mixer DACL Switch" preserve true lock true value 1 }
            { name "OutputR Mixer DACR Switch" preserve true lock true value 1 }
            { name "digital volume" preserve true lock true value 63 }
        ]
    }
}

pcm.!default {
    type plug
    slave.pcm "gt_stock_hooks"
}
```

- [ ] **Step 2: Launch Balatro with the env and verify audio flows.** Either ask Camille to launch Balatro after you add a temporary env hop, or launch headless over ssh (detached):

```bash
ssh root@10.0.1.16 'nohup env ALSA_CONFIG_PATH=/tmp/gt-spike-asound.conf \
  SYSTEM_PATH=/mnt/SDCARD/.system/h700 PLATFORM=h700 \
  USERDATA_PATH=/mnt/SDCARD/.userdata/h700 LOGS_PATH=/mnt/SDCARD/.userdata/h700/logs \
  SDCARD_PATH=/mnt/SDCARD \
  sh "/mnt/SDCARD/Emus/h700/PORTS.pak/launch.sh" "/mnt/SDCARD/Roms/Ports (PORTS)/Balatro.sh" \
  </dev/null >/tmp/gt-spike-launch.log 2>&1 &'
# then sample twice:
ssh root@10.0.1.16 'grep -E "state|hw_ptr" /proc/asound/card0/pcm0p/sub0/status; sleep 0.5; grep -E "state|hw_ptr" /proc/asound/card0/pcm0p/sub0/status'
```

hw_ptr advancing = the game opened OUR default and audio flows. If ssh-launching misbehaves (fb contention with the NextUI menu is cosmetic and acceptable for the spike), fall back to Camille launching by hand — but then the env must be injected via a temporary marker-guarded edit... prefer the ssh route first.

- [ ] **Step 3: Probe absolute-path plugin loading**:

```bash
ssh root@10.0.1.16 'mkdir -p /mnt/SDCARD/gt-spike && cp /usr/lib/aarch64-linux-gnu/alsa-lib/libasound_module_pcm_bluealsa.so /mnt/SDCARD/gt-spike/ && cat > /tmp/gt-spike2.conf <<EOF
</usr/share/alsa/alsa.conf>
pcm_type.gt_probe { lib "/mnt/SDCARD/gt-spike/libasound_module_pcm_bluealsa.so" }
pcm.gt_probe_test { type gt_probe }
EOF
ALSA_CONFIG_PATH=/tmp/gt-spike2.conf aplay -D gt_probe_test /dev/null 2>&1 | head -5'
```

A bluealsa arg/connection error = dlopen from SD PASS; `cannot open shared object file` = FAIL (then test `/tmp/` placement to isolate a noexec-mount cause and record the workaround: copy the module to `/tmp` at launch).

- [ ] **Step 4: Kill the spike Balatro tree (by `/proc/*/comm`), remove `/tmp/gt-spike*` + `/mnt/SDCARD/gt-spike`, post findings as a task comment.**

---

### Task 2: gt-sleepmon watcher daemon

**Goal:** The C daemon: watches event0, freezes the port tree, runs the stock suspend script, unfreezes, swallows post-resume events; pure trigger logic host-tested.

**Files:**
- Create: `assets/gt-sleepmon.c`
- Modify: `Makefile` (shim target: add gt-sleepmon compile + `file` check to the arm64 container run)
- Test: host-compile check inside the same task (see Steps)

**Acceptance Criteria:**
- [ ] `assets/gt-sleepmon.c` compiles in the bullseye arm64 container to `assets/gt-sleepmon` (static-ish plain gcc, `-pthread` not needed), `file` reports ELF 64-bit ARM aarch64.
- [ ] Host test binary (`cc -DGT_SLEEPMON_TEST`) passes: power release triggers, power press/repeat doesn't, lid close (value 1) triggers, lid autorepeat (value 2) and lid open don't, and triggers inside the 2s swallow window are ignored.
- [ ] Signal/exit paths always SIGCONT anything frozen (code-inspection criterion: TERM/INT/HUP handler and post-suspend path both CONT).

**Verify:** `make shim` succeeds and `file assets/gt-sleepmon` shows `ELF 64-bit LSB … ARM aarch64`; host test prints `sleepmon-test-ok`.

**Steps:**

- [ ] **Step 1: Write `assets/gt-sleepmon.c`:**

```c
/* gt-sleepmon.c — F47: sleep watcher for ports on NextUI-h700.
 *
 * Spawned by run_port (see build-pak.sh gt-h700-sleepmon) with one arg:
 * the launch.sh PID (tree root). Watches /dev/input/event0 (axp2202-pek,
 * non-grabbing; keymon reads it too):
 *   KEY_POWER (116) release  -> suspend
 *   KEY_INSERT (110) press   -> suspend (lid close; hall sensor)
 *   KEY_DELETE (111)         -> ignored (lid open; wake is power-only)
 * On trigger: SIGSTOP all live descendants of the tree root (except self),
 * run $SYSTEM_PATH/bin/suspend with a fixed env (system PATH — the pak's
 * busybox wrappers must not shadow pgrep/alsactl), SIGCONT everything,
 * then swallow event0 for 2s of CLOCK_BOOTTIME (the waking power press
 * arrives here post-resume and would instantly re-suspend; minarch has
 * the same guard). Suspend failure: log, CONT, keep playing — NEVER
 * poweroff (ports have no autosave). Exits when the tree root dies.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <signal.h>
#include <time.h>
#include <errno.h>
#include <dirent.h>
#include <poll.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <linux/input.h>

#define GT_KEY_POWER 116
#define GT_KEY_LID_CLOSE 110  /* KEY_INSERT */
#define GT_SWALLOW_NS 2000000000LL
#define GT_MAX_TREE 512

/* ---- pure trigger logic (host-tested) ---- */
/* returns 1 if this event should fire a suspend, given now (CLOCK_BOOTTIME ns)
 * and the end of the current swallow window. */
static int gt_should_trigger(unsigned short code, int value,
                             long long now_ns, long long swallow_until_ns) {
    if (now_ns < swallow_until_ns) return 0;
    if (code == GT_KEY_POWER && value == 0) return 1;      /* release */
    if (code == GT_KEY_LID_CLOSE && value == 1) return 1;  /* press only */
    return 0;
}

#ifndef GT_SLEEPMON_TEST

static long long gt_boottime_ns(void) {
    struct timespec t;
    clock_gettime(CLOCK_BOOTTIME, &t);
    return (long long)t.tv_sec * 1000000000LL + t.tv_nsec;
}

static pid_t gt_root;
static pid_t gt_frozen[GT_MAX_TREE];
static int gt_nfrozen;

/* ppid of pid via /proc/<pid>/stat, parsing after the last ')' so comms
 * containing spaces/parens can't shift fields. 0 on error. */
static pid_t gt_ppid_of(pid_t pid) {
    char path[64], buf[512];
    int fd, n; char *p; long ppid = 0;
    snprintf(path, sizeof path, "/proc/%d/stat", (int)pid);
    fd = open(path, O_RDONLY);
    if (fd < 0) return 0;
    n = read(fd, buf, sizeof buf - 1);
    close(fd);
    if (n <= 0) return 0;
    buf[n] = 0;
    p = strrchr(buf, ')');
    if (!p) return 0;
    /* after ')': " S ppid ..." */
    if (sscanf(p + 1, " %*c %ld", &ppid) != 1) return 0;
    return (pid_t)ppid;
}

static int gt_is_descendant(pid_t pid, pid_t root) {
    int depth;
    for (depth = 0; depth < 64 && pid > 1; depth++) {
        pid = gt_ppid_of(pid);
        if (pid == root) return 1;
    }
    return 0;
}

static void gt_freeze_tree(void) {
    DIR *d = opendir("/proc");
    struct dirent *e;
    pid_t self = getpid();
    gt_nfrozen = 0;
    if (!d) return;
    while ((e = readdir(d)) && gt_nfrozen < GT_MAX_TREE) {
        pid_t p = (pid_t)atoi(e->d_name);
        if (p <= 1 || p == self || p == gt_root) continue;
        if (!gt_is_descendant(p, gt_root)) continue;
        if (kill(p, SIGSTOP) == 0)
            gt_frozen[gt_nfrozen++] = p;
    }
    closedir(d);
}

static void gt_thaw_tree(void) {
    int i;
    for (i = gt_nfrozen - 1; i >= 0; i--)
        kill(gt_frozen[i], SIGCONT);
    gt_nfrozen = 0;
}

static void gt_on_signal(int sig) {
    (void)sig;
    gt_thaw_tree();           /* kill(2) is async-signal-safe */
    _exit(0);
}

static int gt_run_suspend(void) {
    pid_t pid = fork();
    int status = -1;
    if (pid < 0) return -1;
    if (pid == 0) {
        char *const envp[] = {
            "SYSTEM_PATH=/mnt/SDCARD/.system/h700",
            "LD_LIBRARY_PATH=/mnt/SDCARD/.system/h700/lib",
            "PATH=/usr/bin:/bin:/usr/sbin:/sbin",
            NULL
        };
        execle("/mnt/SDCARD/.system/h700/bin/suspend",
               "suspend", (char *)NULL, envp);
        _exit(127);
    }
    while (waitpid(pid, &status, 0) < 0 && errno == EINTR) ;
    return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
}

static void gt_drain_fd(int fd) {
    struct input_event ev;
    while (read(fd, &ev, sizeof ev) == (ssize_t)sizeof ev) ;
}

int main(int argc, char **argv) {
    struct sigaction sa;
    struct pollfd pfd;
    long long swallow_until = 0;
    int fd;

    if (argc < 2) { fprintf(stderr, "usage: gt-sleepmon <root-pid>\n"); return 2; }
    gt_root = (pid_t)atoi(argv[1]);
    if (gt_root <= 1) return 2;

    memset(&sa, 0, sizeof sa);
    sa.sa_handler = gt_on_signal;
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGHUP, &sa, NULL);

    fd = open("/dev/input/event0", O_RDONLY | O_NONBLOCK);
    if (fd < 0) { perror("gt-sleepmon: /dev/input/event0"); return 1; }

    pfd.fd = fd; pfd.events = POLLIN;
    for (;;) {
        int n = poll(&pfd, 1, 5000);
        if (kill(gt_root, 0) < 0 && errno == ESRCH) break;  /* port session gone */
        if (n <= 0) continue;
        for (;;) {
            struct input_event ev;
            ssize_t r = read(fd, &ev, sizeof ev);
            if (r != (ssize_t)sizeof ev) break;
            if (ev.type != EV_KEY) continue;
            if (!gt_should_trigger(ev.code, ev.value, gt_boottime_ns(), swallow_until))
                continue;
            fprintf(stderr, "gt-sleepmon: trigger (code %u), suspending\n", ev.code);
            gt_freeze_tree();
            {
                int rv = gt_run_suspend();
                fprintf(stderr, "gt-sleepmon: suspend rv=%d\n", rv);
                /* rv != 0: log only. NEVER poweroff — port has no autosave. */
            }
            gt_thaw_tree();
            gt_drain_fd(fd);
            swallow_until = gt_boottime_ns() + GT_SWALLOW_NS;
        }
    }
    close(fd);
    return 0;
}

#else /* GT_SLEEPMON_TEST: host-run unit test of the pure trigger logic */

int main(void) {
    /* power release fires; press/repeat don't */
    if (!gt_should_trigger(GT_KEY_POWER, 0, 100, 0)) return 1;
    if (gt_should_trigger(GT_KEY_POWER, 1, 100, 0)) return 2;
    if (gt_should_trigger(GT_KEY_POWER, 2, 100, 0)) return 3;
    /* lid close press fires; autorepeat and release don't */
    if (!gt_should_trigger(GT_KEY_LID_CLOSE, 1, 100, 0)) return 4;
    if (gt_should_trigger(GT_KEY_LID_CLOSE, 2, 100, 0)) return 5;
    if (gt_should_trigger(GT_KEY_LID_CLOSE, 0, 100, 0)) return 6;
    /* lid open never fires */
    if (gt_should_trigger(111, 1, 100, 0)) return 7;
    /* swallow window suppresses everything, then expires */
    if (gt_should_trigger(GT_KEY_POWER, 0, 100, 200)) return 8;
    if (!gt_should_trigger(GT_KEY_POWER, 0, 201, 200)) return 9;
    printf("sleepmon-test-ok\n");
    return 0;
}

#endif
```

- [ ] **Step 2: Run the host test (red→green: run before creating the file to see the compile fail, then after):**

```bash
cc -DGT_SLEEPMON_TEST -o /tmp/gt-sleepmon-test assets/gt-sleepmon.c && /tmp/gt-sleepmon-test
```
Expected: `sleepmon-test-ok`, exit 0.

- [ ] **Step 3: Add the device build to `Makefile`.** In the existing arm64 `docker run` of the `shim` target, append one gcc line and extend the final `file` check:

```make
	   gcc -O2 -Wall -o gt-sleepmon gt-sleepmon.c && strip gt-sleepmon'
```
(added inside the arm64 container command, after the gt-sdl-audio-init line; keep the single-quote shell string intact) and add `assets/gt-sleepmon` to the `file` line. Then run `make shim` (docker; verify with `file assets/gt-sleepmon` → `ELF 64-bit … ARM aarch64`).

- [ ] **Step 4: Commit**

```bash
git add assets/gt-sleepmon.c assets/gt-sleepmon Makefile
git commit -m "feat(f47): gt-sleepmon — evdev sleep watcher for ports"
```

---

### Task 3: ALSA suspend-proxy plugin

**Goal:** `libasound_module_pcm_gt_suspend.so` — an ioplug proxy that forwards playback to the stock chain and transparently closes+reopens the slave when it detects the system suspended, validated functionally in the arm64 container against a null slave.

**Files:**
- Create: `assets/gt-alsa-suspend.c`
- Create: `tests/container-alsa-check.sh` (manual/CI-optional container functional check; NOT wired into tests/run.sh — it needs docker+network)
- Modify: `Makefile` (compile plugin in both container lanes: aarch64 `libasound_module_pcm_gt_suspend.so`, armhf `libasound_module_pcm_gt_suspend.armhf.so`; add `libasound2-dev` to both apt-get lines; extend `file` checks)

**Acceptance Criteria:**
- [ ] Plugin compiles in both lanes; `file` shows ELF 64-bit aarch64 and ELF 32-bit ARM respectively.
- [ ] Container functional check passes: `aplay -D gt_test` through the plugin over a `type null` slave plays a generated raw stream to completion (exit 0), and a forced-reopen run (`GT_SUSPEND_FORCE_REOPEN=1`) also completes and logs `gt-alsa-suspend: reopening slave`.
- [ ] Suspend detection is CLOCK_BOOTTIME−CLOCK_MONOTONIC delta based; reopen path bounded-retries then surfaces errors (no infinite loop).

**Verify:** `sh tests/container-alsa-check.sh` → last line `CONTAINER-ALSA-OK`.

**Steps:**

- [ ] **Step 1: Write `assets/gt-alsa-suspend.c`:**

```c
/* gt-alsa-suspend.c — F47: ALSA ioplug proxy that survives suspend-to-RAM.
 *
 * The h700 BSP wedges any PCM that was open across a suspend (stream stays
 * RUNNING, DMA dead, no -ESTRPIPE ever delivered); only a full
 * snd_pcm_close+open re-initializes the DMA/codec path. This plugin sits
 * between the port and the stock chain ("default" is routed here by the
 * pak's ALSA config, see files/gt-asound.conf): it forwards writes, and on
 * each transfer compares CLOCK_BOOTTIME-CLOCK_MONOTONIC against the value
 * captured at slave-open time — a jump means a suspend happened, so it
 * closes and reopens the slave (which also re-fires NextUI's ctl_elems
 * hooks, restoring the codec output routing).
 *
 * Debug/test: GT_SUSPEND_FORCE_REOPEN=1 forces one reopen after ~50
 * transfers (container functional test, no suspend needed).
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <alsa/asoundlib.h>
#include <alsa/pcm_external.h>

#define GT_DELTA_JUMP_NS 500000000LL /* >0.5s boottime-vs-mono jump = suspend */
#define GT_REOPEN_TRIES 5

typedef struct {
    snd_pcm_ioplug_t io;
    char *slave_name;
    snd_pcm_t *slave;
    long long delta_base_ns;
    int force_reopen;        /* GT_SUSPEND_FORCE_REOPEN test hook */
    long transfers;
} gt_pcm_t;

static long long gt_delta_ns(void) {
    struct timespec b, m;
    clock_gettime(CLOCK_BOOTTIME, &b);
    clock_gettime(CLOCK_MONOTONIC, &m);
    return ((long long)b.tv_sec - m.tv_sec) * 1000000000LL
         + ((long long)b.tv_nsec - m.tv_nsec);
}

static int gt_open_slave(gt_pcm_t *pcm) {
    snd_pcm_ioplug_t *io = &pcm->io;
    int err = snd_pcm_open(&pcm->slave, pcm->slave_name,
                           SND_PCM_STREAM_PLAYBACK, 0);
    if (err < 0) return err;
    err = snd_pcm_set_params(pcm->slave, io->format,
                             SND_PCM_ACCESS_RW_INTERLEAVED,
                             io->channels, io->rate, 1 /* soft_resample */,
                             (unsigned int)((unsigned long long)io->buffer_size
                                            * 1000000ULL / io->rate));
    if (err < 0) { snd_pcm_close(pcm->slave); pcm->slave = NULL; return err; }
    pcm->delta_base_ns = gt_delta_ns();
    return 0;
}

static void gt_close_slave(gt_pcm_t *pcm) {
    if (pcm->slave) { snd_pcm_close(pcm->slave); pcm->slave = NULL; }
}

static int gt_reopen_slave(gt_pcm_t *pcm) {
    int i, err = -EIO;
    fprintf(stderr, "gt-alsa-suspend: reopening slave\n");
    gt_close_slave(pcm);
    for (i = 0; i < GT_REOPEN_TRIES; i++) {
        err = gt_open_slave(pcm);
        if (err >= 0) return 0;
        usleep(100000);
    }
    return err;
}

static int gt_suspend_happened(gt_pcm_t *pcm) {
    if (pcm->force_reopen && pcm->transfers == 50) return 1;
    return gt_delta_ns() - pcm->delta_base_ns > GT_DELTA_JUMP_NS;
}

static snd_pcm_sframes_t gt_transfer(snd_pcm_ioplug_t *io,
                                     const snd_pcm_channel_area_t *areas,
                                     snd_pcm_uframes_t offset,
                                     snd_pcm_uframes_t size) {
    gt_pcm_t *pcm = io->private_data;
    const char *buf = (const char *)areas[0].addr
                    + (areas[0].first + areas[0].step * offset) / 8;
    snd_pcm_sframes_t n;
    pcm->transfers++;
    if (!pcm->slave || gt_suspend_happened(pcm)) {
        int err = gt_reopen_slave(pcm);
        if (err < 0) return err;
    }
    n = snd_pcm_writei(pcm->slave, buf, size);
    if (n < 0) {
        if (n == -ESTRPIPE || n == -EPIPE || n == -EBADFD) {
            if (snd_pcm_recover(pcm->slave, (int)n, 1) < 0
                && gt_reopen_slave(pcm) < 0)
                return n;
            n = snd_pcm_writei(pcm->slave, buf, size);
            if (n < 0) return n;
        } else {
            return n;
        }
    }
    return n;
}

static snd_pcm_sframes_t gt_pointer(snd_pcm_ioplug_t *io) {
    gt_pcm_t *pcm = io->private_data;
    snd_pcm_sframes_t delay = 0, hw;
    if (pcm->slave)
        if (snd_pcm_delay(pcm->slave, &delay) < 0) delay = 0;
    if (delay < 0) delay = 0;
    if (delay > (snd_pcm_sframes_t)io->buffer_size)
        delay = (snd_pcm_sframes_t)io->buffer_size;
    hw = (snd_pcm_sframes_t)io->appl_ptr - delay;
    if (hw < 0) hw = 0;
    return hw % (snd_pcm_sframes_t)io->buffer_size;
}

static int gt_delay(snd_pcm_ioplug_t *io, snd_pcm_sframes_t *delayp) {
    gt_pcm_t *pcm = io->private_data;
    if (pcm->slave && snd_pcm_delay(pcm->slave, delayp) >= 0) return 0;
    *delayp = 0;
    return 0;
}

static int gt_start(snd_pcm_ioplug_t *io) {
    gt_pcm_t *pcm = io->private_data;
    if (pcm->slave && snd_pcm_state(pcm->slave) == SND_PCM_STATE_PREPARED)
        snd_pcm_start(pcm->slave);
    return 0;
}

static int gt_stop(snd_pcm_ioplug_t *io) {
    gt_pcm_t *pcm = io->private_data;
    if (pcm->slave) snd_pcm_drop(pcm->slave);
    return 0;
}

static int gt_prepare(snd_pcm_ioplug_t *io) {
    gt_pcm_t *pcm = io->private_data;
    if (!pcm->slave || gt_suspend_happened(pcm))
        return gt_reopen_slave(pcm);
    return snd_pcm_prepare(pcm->slave);
}

static int gt_drain(snd_pcm_ioplug_t *io) {
    gt_pcm_t *pcm = io->private_data;
    if (pcm->slave) snd_pcm_drain(pcm->slave);
    return 0;
}

static int gt_hw_params(snd_pcm_ioplug_t *io, snd_pcm_hw_params_t *params) {
    gt_pcm_t *pcm = io->private_data;
    (void)params;
    gt_close_slave(pcm);           /* io->format/rate/... now final; (re)open */
    return gt_open_slave(pcm);
}

static int gt_poll_descriptors_count(snd_pcm_ioplug_t *io) {
    gt_pcm_t *pcm = io->private_data;
    return pcm->slave ? snd_pcm_poll_descriptors_count(pcm->slave) : 0;
}

static int gt_poll_descriptors(snd_pcm_ioplug_t *io, struct pollfd *pfd,
                               unsigned int space) {
    gt_pcm_t *pcm = io->private_data;
    return pcm->slave ? snd_pcm_poll_descriptors(pcm->slave, pfd, space) : 0;
}

static int gt_poll_revents(snd_pcm_ioplug_t *io, struct pollfd *pfd,
                           unsigned int nfds, unsigned short *revents) {
    gt_pcm_t *pcm = io->private_data;
    if (!pcm->slave) { *revents = POLLERR; return 0; }
    return snd_pcm_poll_descriptors_revents(pcm->slave, pfd, nfds, revents);
}

static int gt_close(snd_pcm_ioplug_t *io) {
    gt_pcm_t *pcm = io->private_data;
    gt_close_slave(pcm);
    free(pcm->slave_name);
    free(pcm);
    return 0;
}

static const snd_pcm_ioplug_callback_t gt_callbacks = {
    .start = gt_start,
    .stop = gt_stop,
    .pointer = gt_pointer,
    .transfer = gt_transfer,
    .close = gt_close,
    .hw_params = gt_hw_params,
    .prepare = gt_prepare,
    .drain = gt_drain,
    .delay = gt_delay,
    .poll_descriptors_count = gt_poll_descriptors_count,
    .poll_descriptors = gt_poll_descriptors,
    .poll_revents = gt_poll_revents,
};

static int gt_set_constraints(snd_pcm_ioplug_t *io) {
    static const unsigned int accesses[] = { SND_PCM_ACCESS_RW_INTERLEAVED };
    static const unsigned int formats[] = {
        SND_PCM_FORMAT_U8, SND_PCM_FORMAT_S16_LE,
        SND_PCM_FORMAT_S32_LE, SND_PCM_FORMAT_FLOAT_LE,
    };
    int err;
    if ((err = snd_pcm_ioplug_set_param_list(io, SND_PCM_IOPLUG_HW_ACCESS,
            1, accesses)) < 0) return err;
    if ((err = snd_pcm_ioplug_set_param_list(io, SND_PCM_IOPLUG_HW_FORMAT,
            sizeof(formats)/sizeof(formats[0]), formats)) < 0) return err;
    if ((err = snd_pcm_ioplug_set_param_minmax(io, SND_PCM_IOPLUG_HW_CHANNELS,
            1, 2)) < 0) return err;
    if ((err = snd_pcm_ioplug_set_param_minmax(io, SND_PCM_IOPLUG_HW_RATE,
            8000, 192000)) < 0) return err;
    if ((err = snd_pcm_ioplug_set_param_minmax(io,
            SND_PCM_IOPLUG_HW_PERIOD_BYTES, 128, 2 * 1024 * 1024)) < 0) return err;
    if ((err = snd_pcm_ioplug_set_param_minmax(io, SND_PCM_IOPLUG_HW_PERIODS,
            2, 64)) < 0) return err;
    return 0;
}

SND_PCM_PLUGIN_DEFINE_FUNC(gt_suspend) {
    snd_config_iterator_t i, next;
    const char *slave_name = NULL;
    gt_pcm_t *pcm;
    int err;
    (void)root;

    snd_config_for_each(i, next, conf) {
        snd_config_t *n = snd_config_iterator_entry(i);
        const char *id;
        if (snd_config_get_id(n, &id) < 0) continue;
        if (!strcmp(id, "comment") || !strcmp(id, "type") || !strcmp(id, "hint"))
            continue;
        if (!strcmp(id, "slave")) {
            snd_config_iterator_t j, jnext;
            snd_config_for_each(j, jnext, n) {
                snd_config_t *s = snd_config_iterator_entry(j);
                const char *sid;
                if (snd_config_get_id(s, &sid) < 0) continue;
                if (!strcmp(sid, "pcm"))
                    snd_config_get_string(s, &slave_name);
            }
            continue;
        }
        SNDERR("unknown field %s", id);
        return -EINVAL;
    }
    if (!slave_name) { SNDERR("gt_suspend: slave.pcm not set"); return -EINVAL; }
    if (stream != SND_PCM_STREAM_PLAYBACK) return -ENOTSUP;

    pcm = calloc(1, sizeof *pcm);
    if (!pcm) return -ENOMEM;
    pcm->slave_name = strdup(slave_name);
    pcm->force_reopen = getenv("GT_SUSPEND_FORCE_REOPEN") != NULL;
    pcm->io.version = SND_PCM_IOPLUG_VERSION;
    pcm->io.name = "gt suspend-safe proxy";
    pcm->io.callback = &gt_callbacks;
    pcm->io.private_data = pcm;
    pcm->io.mmap_rw = 0;

    err = snd_pcm_ioplug_create(&pcm->io, name, stream, mode);
    if (err < 0) { free(pcm->slave_name); free(pcm); return err; }
    err = gt_set_constraints(&pcm->io);
    if (err < 0) { snd_pcm_ioplug_delete(&pcm->io); return err; }
    *pcmp = pcm->io.pcm;
    return 0;
}

SND_PCM_PLUGIN_SYMBOL(gt_suspend);
```

- [ ] **Step 2: Write `tests/container-alsa-check.sh`** (manual functional check; docker + network — same caveat as `make shim`):

```sh
#!/bin/sh
# F47: functional check of the ALSA suspend-proxy in the arm64 bullseye
# container against a `type null` slave — no audio hardware needed.
# Run manually (or from CI); NOT part of tests/run.sh (needs docker+network).
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
docker run --rm --platform linux/arm64 -v "$ROOT/assets:/w" -w /w debian:bullseye sh -ec '
  apt-get update -qq && apt-get install -y -qq gcc libasound2-dev alsa-utils >/dev/null
  gcc -O2 -Wall -shared -fPIC -o /tmp/libasound_module_pcm_gt_suspend.so gt-alsa-suspend.c -lasound
  cat > /tmp/test.conf <<EOF
</usr/share/alsa/alsa.conf>
pcm_type.gt_suspend { lib "/tmp/libasound_module_pcm_gt_suspend.so" }
pcm.gt_null { type null }
pcm.gt_test { type gt_suspend slave.pcm "gt_null" }
EOF
  dd if=/dev/zero of=/tmp/z.raw bs=176400 count=3 2>/dev/null
  ALSA_CONFIG_PATH=/tmp/test.conf aplay -q -D gt_test -t raw -f S16_LE -c 2 -r 44100 /tmp/z.raw
  echo "plain pass OK"
  ALSA_CONFIG_PATH=/tmp/test.conf GT_SUSPEND_FORCE_REOPEN=1 \
    aplay -q -D gt_test -t raw -f S16_LE -c 2 -r 44100 /tmp/z.raw 2>&1 | tee /tmp/out
  grep -q "gt-alsa-suspend: reopening slave" /tmp/out
  echo CONTAINER-ALSA-OK'
```

- [ ] **Step 3: Run it (red first — before writing the .c it fails at compile; green after):** `sh tests/container-alsa-check.sh` → `CONTAINER-ALSA-OK`. Debug the plugin here until green; this is where pointer/poll accounting bugs surface. If aplay stalls, instrument `gt_pointer` (stderr) inside the container.

- [ ] **Step 4: Add both Makefile lanes.** arm64 container command gains:

```make
	   gcc -O2 -Wall -shared -fPIC -o libasound_module_pcm_gt_suspend.so gt-alsa-suspend.c -lasound && strip libasound_module_pcm_gt_suspend.so && \
```
armhf container command gains the same with `-o libasound_module_pcm_gt_suspend.armhf.so`, and both apt-get lines gain `libasound2-dev`. Extend the `file` line with both .so files. Run `make shim`; verify `file` output shows 64-bit and 32-bit ARM respectively.

- [ ] **Step 5: Commit**

```bash
git add assets/gt-alsa-suspend.c assets/libasound_module_pcm_gt_suspend.so assets/libasound_module_pcm_gt_suspend.armhf.so tests/container-alsa-check.sh Makefile
git commit -m "feat(f47): ALSA suspend-proxy ioplug plugin (aarch64 + armhf)"
```

---

### Task 4: build-pak.sh wiring — staging, run_port spawn/kill, ALSA env

**Goal:** The pak ships and wires everything: sleepmon spawn (blocklist-gated) + cleanup kill, ALSA config generation + env export, asset staging with fail-closed arch checks.

**Files:**
- Create: `assets/gt-sleep-blocklist.txt` (shipped empty, with a `#` usage comment header)
- Create: `assets/gt-asound.conf` (template with `@PAK_DIR@` placeholder — content below; adjust ONLY if Task 1's findings contradict it)
- Modify: `build/build-pak.sh` (staging section near the other `cp "$ASSETS/…"` lines ~1247–1280; `edit_portmaster_launch` — two new marker-guarded splices; E5 stub comment ~line 1233)
- Test: covered by Task 5's suite (this task keeps `make test` green — existing tests must not break)

**Acceptance Criteria:**
- [ ] `assets/gt-asound.conf`: includes `</usr/share/alsa/alsa.conf>`, defines `pcm_type.gt_suspend` with `lib "@PAK_DIR@/lib/libasound_module_pcm_gt_suspend.so"`, replicates the stock hooks chain as `pcm.gt_stock_hooks`, wraps it as `pcm.gt_stock_slave { type plug … }`, and overrides `pcm.!default { type gt_suspend slave.pcm "gt_stock_slave" }`.
- [ ] Staging: `bin/gt-sleepmon`, `lib/libasound_module_pcm_gt_suspend.so` (+ `.armhf.so`), `files/gt-sleep-blocklist.txt`, `files/gt-asound.conf` land in the assembled pak; sleepmon and the armhf .so get fail-closed `file` checks (aarch64 executable / 32-bit ARM .so).
- [ ] `gt-h700-sleepmon` splice: before the `"$PAK_DIR/bin/bash" "$ROM_PATH"` anchor, gated on `[ "$PLATFORM" = "h700" ]` + NOT blocklisted (`files/gt-sleep-blocklist.txt` or `$USERDATA_PATH/PORTS-portmaster/use-sleep-blocklist`), generates `/tmp/gt-asound.conf` from the template (`sed "s|@PAK_DIR@|$PAK_DIR|g"`), exports `ALSA_CONFIG_PATH=/tmp/gt-asound.conf`, spawns `"$PAK_DIR/bin/gt-sleepmon" $$ >/tmp/gt-sleepmon.log 2>&1 &` and records `gt_sleepmon_pid=$!`.
- [ ] `gt-h700-sleepmon-kill` splice: first lines inside `cleanup()` kill `$gt_sleepmon_pid` if set, plus a `/proc/*/comm` scan fallback for `gt-sleepmon` (the F15 busybox-killall lesson).
- [ ] Edited launch.sh passes `sh -n`; all existing tests stay green.

**Verify:** `make test` → all suites pass (Task 5 adds the F47 suite; here the pre-existing 21 must not regress). Spot-check: `GT_STAGE_EDIT_ONLY=<tmp> sh build/build-pak.sh portmaster` then grep the edited launch.sh for both markers.

**Steps:**

- [ ] **Step 1: Write `assets/gt-sleep-blocklist.txt`:**

```
# gt-sleep-blocklist.txt — F47: launcher filenames (one per line, exact match
# against $ROM_NAME) for which the sleep watcher + ALSA suspend-proxy are
# DISABLED. Users can extend on-device without a rebuild via
# $USERDATA_PATH/PORTS-portmaster/use-sleep-blocklist.
```

- [ ] **Step 2: Write `assets/gt-asound.conf`** (template; `@PAK_DIR@` substituted at launch):

```
# gt-asound.conf — F47: route the port's "default" PCM through the pak's
# suspend-proxy plugin so audio survives suspend-to-RAM (the BSP wedges any
# PCM open across a suspend; only close+reopen recovers — see
# docs/h700-fixes.md F47). pcm.gt_stock_hooks is a verbatim copy of NextUI's
# stock /etc/asound.conf default chain (drift risk documented in F47 notes).
</usr/share/alsa/alsa.conf>

pcm_type.gt_suspend {
    lib "@PAK_DIR@/lib/libasound_module_pcm_gt_suspend.so"
}

pcm.gt_stock_hooks {
    type hooks
    slave.pcm "hw:audiocodec"
    hooks.0 {
        type ctl_elems
        hook_args [
            { name "LINEOUT Switch" preserve true lock true value 1 }
            { name "SPK Switch" preserve true lock true value 1 }
            { name "OutputL Mixer DACL Switch" preserve true lock true value 1 }
            { name "OutputR Mixer DACR Switch" preserve true lock true value 1 }
            { name "digital volume" preserve true lock true value 63 }
        ]
    }
}

pcm.gt_stock_slave {
    type plug
    slave.pcm "gt_stock_hooks"
}

pcm.!default {
    type gt_suspend
    slave.pcm "gt_stock_slave"
}
```

- [ ] **Step 3: Add the staging block** in `build/build-pak.sh` next to the existing shim staging (after the gt-hud-blocklist cp, ~line 1275):

```sh
  # gt-h700-sleepmon / gt-h700-alsa-suspend: F47 — sleep watcher + ALSA
  # suspend-proxy (see edit_portmaster_launch). Fail closed on arch so a
  # wrong-arch docker build can never ship (F45 lesson).
  cp "$ASSETS/gt-sleepmon" "$assembled/bin/gt-sleepmon"
  file "$assembled/bin/gt-sleepmon" | grep -q 'ELF 64-bit.*aarch64' \
    || { echo "gt-sleepmon is not an aarch64 executable" >&2; exit 1; }
  cp "$ASSETS/libasound_module_pcm_gt_suspend.so" "$assembled/lib/libasound_module_pcm_gt_suspend.so"
  file "$assembled/lib/libasound_module_pcm_gt_suspend.so" | grep -q 'ELF 64-bit.*aarch64' \
    || { echo "gt_suspend plugin is not an aarch64 shared object" >&2; exit 1; }
  cp "$ASSETS/libasound_module_pcm_gt_suspend.armhf.so" "$assembled/lib/libasound_module_pcm_gt_suspend.armhf.so"
  file "$assembled/lib/libasound_module_pcm_gt_suspend.armhf.so" | grep -q 'ELF 32-bit.*ARM' \
    || { echo "gt_suspend armhf plugin is not a 32-bit ARM shared object" >&2; exit 1; }
  cp "$ASSETS/gt-sleep-blocklist.txt" "$assembled/files/gt-sleep-blocklist.txt"
  cp "$ASSETS/gt-asound.conf" "$assembled/files/gt-asound.conf"
```

- [ ] **Step 4: Add the run_port splice** in `edit_portmaster_launch` (after the F42 gt-sdl-audio-init block, same anchor):

```sh
  # gt-h700-sleepmon: F47 — sleep for ports. NextUI sleep is a foreground-app
  # feature (nextui/minarch watch event0 + hallkey and run bin/suspend; keymon
  # does volume/brightness only), so during a port NOBODY watches the power
  # key or lid. gt-sleepmon (pak bin/) fills that role: KEY_POWER release or
  # lid-close on event0 -> SIGSTOP the port tree -> stock suspend script ->
  # SIGCONT -> 2s event swallow (the waking press would otherwise instantly
  # re-suspend). The ALSA env routes "default" through the pak's
  # suspend-proxy plugin so audio survives (the BSP wedges any PCM open
  # across a suspend; only close+reopen recovers). Opt-out via
  # files/gt-sleep-blocklist.txt or the user's use-sleep-blocklist.
  if ! grep -q 'gt-h700-sleepmon' "$f"; then
    awk '$0 == "    \"$PAK_DIR/bin/bash\" \"$ROM_PATH\"" {
      print "    # gt-h700-sleepmon / gt-h700-alsa-suspend (F47)"
      print "    if [ \"$PLATFORM\" = \"h700\" ]; then"
      print "        if grep -Fxq \"$ROM_NAME\" \"$PAK_DIR/files/gt-sleep-blocklist.txt\" 2>/dev/null \\"
      print "            || grep -Fxq \"$ROM_NAME\" \"$USERDATA_PATH/PORTS-portmaster/use-sleep-blocklist\" 2>/dev/null; then"
      print "            echo \"Sleep support disabled (blocklisted) for $ROM_NAME\""
      print "        else"
      print "            sed \"s|@PAK_DIR@|$PAK_DIR|g\" \"$PAK_DIR/files/gt-asound.conf\" > /tmp/gt-asound.conf"
      print "            export ALSA_CONFIG_PATH=/tmp/gt-asound.conf"
      print "            \"$PAK_DIR/bin/gt-sleepmon\" $$ >/tmp/gt-sleepmon.log 2>&1 &"
      print "            gt_sleepmon_pid=$!"
      print "        fi"
      print "    fi"
      print ""
      print $0
      next
    }
    { print }' "$f" > "$f.awk.tmp" && mv "$f.awk.tmp" "$f"
  fi
```

- [ ] **Step 5: Add the cleanup kill splice** (anchor: the `cleanup() {` line):

```sh
  # gt-h700-sleepmon-kill: F47 — reap the sleep watcher on pak exit. A leaked
  # gt-sleepmon would keep suspending NextUI after the port exits. kill by
  # recorded PID plus a /proc comm scan (in-pak killall never matches through
  # the busybox wrapper shadow — the F15 lesson).
  if ! grep -q 'gt-h700-sleepmon-kill' "$f"; then
    awk '$0 == "cleanup() {" {
      print $0
      print "    # gt-h700-sleepmon-kill (F47): see edit_portmaster_launch"
      print "    [ -n \"${gt_sleepmon_pid:-}\" ] && kill \"$gt_sleepmon_pid\" 2>/dev/null"
      print "    for gt_p in /proc/[0-9]*/comm; do"
      print "        [ \"$(cat \"$gt_p\" 2>/dev/null)\" = \"gt-sleepmon\" ] && kill \"$(basename \"$(dirname \"$gt_p\")\")\" 2>/dev/null"
      print "    done"
      next
    }
    { print }' "$f" > "$f.awk.tmp" && mv "$f.awk.tmp" "$f"
  fi
```

- [ ] **Step 6: Update the E5 stub comment** (~line 1233-1240): change the heredoc comment line `# gt-h700-stub: deep sleep inside ports is out of scope on h700 (v1).` to `# gt-h700-stub: upstream binary is tg5040-built; port sleep is provided by gt-sleepmon instead (F47).` (keep the stub itself — upstream calls it).

- [ ] **Step 7: Sanity-run and commit**

```bash
work=$(mktemp -d); cp tests/fixtures/portmaster-pak-skeleton/pak.json.fixture "$work/pak.json"; cp tests/fixtures/portmaster-pak-skeleton/launch.sh.fixture "$work/launch.sh"
GT_STAGE_EDIT_ONLY="$work" sh build/build-pak.sh portmaster
grep -c 'gt-h700-sleepmon' "$work/launch.sh"   # expect >= 2 (spawn + kill markers)
sh -n "$work/launch.sh"
make test                                       # existing 21 suites stay green
git add assets/gt-sleep-blocklist.txt assets/gt-asound.conf build/build-pak.sh
git commit -m "feat(f47): wire sleep watcher + ALSA suspend-proxy into the pak"
```

---

### Task 5: F47 test suite + docs

**Goal:** `tests/test-22-port-sleep.sh` locks the wiring in; `docs/h700-fixes.md` + README document F47.

**Files:**
- Create: `tests/test-22-port-sleep.sh`
- Modify: `docs/h700-fixes.md` (new F47 section, house style: problem → root cause → fix, terse), `README.md` (feature bullet + blocklist/opt-out note)

**Acceptance Criteria:**
- [ ] test-22 asserts, on a `GT_STAGE_EDIT_ONLY` edit of the fixture: both markers present; the spawn block sits BEFORE the `"$PAK_DIR/bin/bash" "$ROM_PATH"` line and the kill block INSIDE `cleanup()`; `ALSA_CONFIG_PATH` export and the `sed` template line present; blocklist greps for both the pak file and `use-sleep-blocklist` present; edited file passes `sh -n`; edit is idempotent (run build twice → single marker occurrence each).
- [ ] test-22 asserts the staging code exists in `build/build-pak.sh` (greps for the five `cp "$ASSETS/…"` targets and both fail-closed `file` checks).
- [ ] `make test` green (22 suites).
- [ ] `docs/h700-fixes.md` F47 section covers: why ports couldn't sleep, the trigger map (event0 codes), the suspend-script contract, the audio wedge + why close/reopen, the asound.conf lock/hooks discovery, blocklist opt-out, and the never-poweroff rule.

**Verify:** `make test` → `test-22-port-sleep` listed and passing, 22/22 suites green.

**Steps:**

- [ ] **Step 1: Write `tests/test-22-port-sleep.sh`** (follow the test-12 idiom exactly — helpers.sh header, fixture copy, `GT_STAGE_EDIT_ONLY`, `assert_contains`):

```sh
#!/bin/sh
. "$(dirname -- "$0")/helpers.sh"

# F47: sleep support for ports — gt-sleepmon spawn/kill wiring + ALSA
# suspend-proxy routing. See docs/h700-fixes.md F47 and the spec at
# docs/superpowers/specs/2026-08-31-port-sleep-design.md.
work="$SANDBOX/pmpak"; mkdir -p "$work"
cp "$TROOT/fixtures/portmaster-pak-skeleton/pak.json.fixture" "$work/pak.json"
cp "$TROOT/fixtures/portmaster-pak-skeleton/launch.sh.fixture" "$work/launch.sh"
GT_STAGE_EDIT_ONLY="$work" sh "$ROOT/build/build-pak.sh" portmaster

# ---------- markers present ----------
assert_contains "$work/launch.sh" 'gt-h700-sleepmon'
assert_contains "$work/launch.sh" 'gt-h700-sleepmon-kill'

# ---------- spawn block wiring ----------
# shellcheck disable=SC2016
assert_contains "$work/launch.sh" 'export ALSA_CONFIG_PATH=/tmp/gt-asound.conf'
# shellcheck disable=SC2016
assert_contains "$work/launch.sh" 'sed "s|@PAK_DIR@|\$PAK_DIR|g" "\$PAK_DIR/files/gt-asound.conf"'
# shellcheck disable=SC2016
assert_contains "$work/launch.sh" '"\$PAK_DIR/bin/gt-sleepmon" \$\$ >/tmp/gt-sleepmon.log'
# shellcheck disable=SC2016
assert_contains "$work/launch.sh" 'files/gt-sleep-blocklist.txt'
assert_contains "$work/launch.sh" 'use-sleep-blocklist'

# ---------- placement: spawn before exec, kill inside cleanup ----------
exec_line=$(grep -n '"\$PAK_DIR/bin/bash" "\$ROM_PATH"' "$work/launch.sh" | head -1 | cut -d: -f1)
spawn_line=$(grep -n 'bin/gt-sleepmon' "$work/launch.sh" | head -1 | cut -d: -f1)
[ "$spawn_line" -lt "$exec_line" ] || { echo "sleepmon spawn not before exec"; exit 1; }
cleanup_line=$(grep -n '^cleanup() {' "$work/launch.sh" | head -1 | cut -d: -f1)
kill_line=$(grep -n 'gt-h700-sleepmon-kill (F47)' "$work/launch.sh" | head -1 | cut -d: -f1)
[ "$kill_line" -gt "$cleanup_line" ] || { echo "kill not inside cleanup"; exit 1; }
[ "$kill_line" -lt "$((cleanup_line + 8))" ] || { echo "kill not at cleanup head"; exit 1; }

# ---------- parses + idempotent ----------
sh -n "$work/launch.sh" || { echo "edited launch.sh does not parse"; exit 1; }
GT_STAGE_EDIT_ONLY="$work" sh "$ROOT/build/build-pak.sh" portmaster
n=$(grep -c 'gt-h700-sleepmon-kill (F47)' "$work/launch.sh")
assert_eq "$n" 1 "cleanup kill spliced twice — marker guard broken"

# ---------- staging code present in build-pak.sh (fail-closed arch checks) ----------
assert_contains "$ROOT/build/build-pak.sh" 'cp "\$ASSETS/gt-sleepmon"'
assert_contains "$ROOT/build/build-pak.sh" 'cp "\$ASSETS/libasound_module_pcm_gt_suspend.so"'
assert_contains "$ROOT/build/build-pak.sh" 'cp "\$ASSETS/libasound_module_pcm_gt_suspend.armhf.so"'
assert_contains "$ROOT/build/build-pak.sh" 'cp "\$ASSETS/gt-sleep-blocklist.txt"'
assert_contains "$ROOT/build/build-pak.sh" 'cp "\$ASSETS/gt-asound.conf"'
assert_contains "$ROOT/build/build-pak.sh" 'gt-sleepmon is not an aarch64 executable'
assert_contains "$ROOT/build/build-pak.sh" 'gt_suspend armhf plugin is not a 32-bit ARM shared object'

echo "test-22-port-sleep OK"
```

(Adjust the escaped-grep patterns against real output while writing — `assert_contains` uses `grep -q --`, so patterns above are regex; verify each matches the actual edited file, the same way test-12 mixes `assert_contains` and `grep -qF`.)

- [ ] **Step 2: Run red→green:** `sh tests/test-22-port-sleep.sh` (against the Task 4 tree it should pass immediately — if any assertion fails, the WIRING is wrong; fix build-pak.sh, not the test, unless the pattern itself is mis-escaped).

- [ ] **Step 3: Write the docs.** `docs/h700-fixes.md`: add an F47 section in house style covering the items in the AC. `README.md`: one feature bullet ("Sleep works during ports — power button or lid close suspends; power wakes with audio intact") + the `use-sleep-blocklist` opt-out in the existing user-override list.

- [ ] **Step 4: Full suite + commit**

```bash
make test
git add tests/test-22-port-sleep.sh docs/h700-fixes.md README.md
git commit -m "test(f47): wiring suite; docs: F47 section + README"
```

---

### Task 6: Device gate — full engine matrix on the RG SP

**Goal:** Prove sleep/wake with working audio across every engine class on real hardware, from a real pak install, with Camille hands-on.

**USER-ORDERED GATE — NON-SKIPPABLE.** This task was requested by the user in the current conversation. It MUST NOT be closed by walking around it, by declaring it "verified inline", or by substituting a cheaper check. Close only after every item in `acceptanceCriteria` has been re-validated independently, with output captured.

**Files:**
- None (device verification; any fixes discovered go back through Tasks 2–5 with tests).

**Acceptance Criteria:**
- [ ] Local `make pak` build installed on the RG SP by unzip-over into `Emus/h700/` (backups kept: previous `launch.sh` and `lib/` as `.pre-f47.bak`).
- [ ] Balatro (LÖVE/OpenAL): power-button sleep AND lid-close sleep; power wake; game alive, controls work, **music audible after wake** (Camille confirms by ear); ≥3 consecutive sleep/wake cycles in one session.
- [ ] Deltarune or Pizza Tower (GameMaker/gmloadernext; Pizza Tower preferred — also exercises F30 FMOD_SDL): sleep/wake with audio after wake.
- [ ] Apotris (native SDL_Renderer under gptokeyb): sleep/wake with audio after wake; gptokeyb input still works.
- [ ] Celeste (FNA/FAudio): sleep/wake with audio after wake.
- [ ] Animal Crossing (armhf): sleep/wake; if audio does not survive, record it as a documented per-port limitation in docs/h700-fixes.md (non-blocking per spec).
- [ ] Volume keys (keymon) still work after wake; HUD toggle (F34/F35) still works after wake; Tunics! or BYTEPATH launches and plays (remap regression); a PortMaster GUI session opens and installs normally (no sleepmon leaked into it — `/proc/*/comm` shows no gt-sleepmon after GUI exit and after port exit).
- [ ] `/tmp/gt-sleepmon.log` shows the trigger and `suspend rv=0` lines for at least one cycle (captured into the task comment).
- [ ] No frozen processes left after any cycle (`ps` shows no `T` state stragglers post-wake).

**Verify:** `ssh root@10.0.1.16 'cat /tmp/gt-sleepmon.log'` shows `gt-sleepmon: trigger` + `suspend rv=0`; per-engine PASS list confirmed by Camille in conversation; `ssh root@10.0.1.16 'for p in /proc/[0-9]*/comm; do [ "$(cat $p 2>/dev/null)" = gt-sleepmon ] && echo LEAKED; done; true'` prints nothing after exit.

**Steps:**

- [ ] **Step 1: Build + install.** `make pak` (needs network → run with sandbox disabled), scp the zip, back up device `launch.sh` + `lib/gt-*` as `.pre-f47.bak`, unzip-over into `/mnt/SDCARD/Emus/h700/` (install is self-healing by design; never overwrite a RUNNING launch.sh — install while no port runs).
- [ ] **Step 2: Run the matrix with Camille** (he presses buttons/lid and confirms audio by ear; agent watches logs/PCM state over ssh between cycles — remember ssh dies during each suspend, reconnect after).
- [ ] **Step 3: Capture evidence** (log excerpts, per-engine confirmations) into the task comment; fix-and-loop through Tasks 2–5 for any failure; re-run the affected engine after every fix.
- [ ] **Step 4: Leave the device in the gated state** (F47 build installed) and STOP — merging `feat/port-sleep` to main, release bundling, and any push remain Camille's explicit calls.

---

## Self-review notes (already applied)

- Spec coverage: watcher (Task 2+4), proxy (Task 3+4), routing env (Task 1+4), blocklist escape hatch (Task 4), tests (Task 5), docs (Task 5), device gate matrix incl. FMOD interplay + armhf caveat (Task 6). GUI exclusion honored (no GUI-path edits anywhere).
- The Task 4 conf/env template is the plan's best pre-validated guess; Task 1 exists precisely to confirm or correct it before Task 4 runs. Task 4's executor must read Task 1's findings comment first.
- Type/name consistency: `gt-sleepmon` (binary, `bin/`), `libasound_module_pcm_gt_suspend.so` / `.armhf.so` (`lib/`), `gt-sleep-blocklist.txt` + `gt-asound.conf` (`files/`), markers `gt-h700-sleepmon` / `gt-h700-sleepmon-kill`, env `ALSA_CONFIG_PATH=/tmp/gt-asound.conf`, user override `use-sleep-blocklist` — used identically across Tasks 2–6.
