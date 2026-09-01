/* gt-sleepmon.c — F47: sleep watcher for ports on NextUI-h700.
 *
 * Spawned by run_port (see build-pak.sh gt-h700-sleepmon) with one arg:
 * the launch.sh PID (tree root). Watches the input node that advertises
 * KEY_POWER (axp2202-pek — event0 on the RG SP, but enumeration order is
 * not a contract, so F51 scans /dev/input by EVIOCGBIT capability like the
 * shim's Menu-device discovery; falls back to event0). Non-grabbing; keymon
 * reads the same node:
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

/* F51: bit test over an EVIOCGBIT(EV_KEY) keymap buffer. Pure — used by the
 * power-device scan below and asserted by the GT_SLEEPMON_TEST main. */
static int gt_keybit_has(const unsigned char *bits, size_t len, unsigned code) {
    if (code / 8 >= len) return 0;
    return (bits[code / 8] >> (code % 8)) & 1;
}

#ifndef GT_SLEEPMON_TEST

#include <dirent.h>
#include <sys/ioctl.h>
#include <poll.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <linux/input.h>

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

/* F51: open the input node whose EV_KEY capability includes KEY_POWER (the
 * axp2202 power key; also the lid codes on clamshells — same node on the
 * RG SP). First match wins; only the PMIC key node carries KEY_POWER here. */
static int gt_open_power_device(void) {
    DIR *d = opendir("/dev/input");
    struct dirent *e;
    if (!d) return -1;
    while ((e = readdir(d)) != NULL) {
        char path[280];   /* "/dev/input/" + dirent d_name (up to 256) */
        unsigned char bits[(GT_KEY_POWER / 8) + 1];
        int f;
        if (strncmp(e->d_name, "event", 5) != 0) continue;
        snprintf(path, sizeof path, "/dev/input/%s", e->d_name);
        f = open(path, O_RDONLY | O_NONBLOCK);
        if (f < 0) continue;
        memset(bits, 0, sizeof bits);
        if (ioctl(f, EVIOCGBIT(EV_KEY, sizeof bits), bits) >= 0 &&
            gt_keybit_has(bits, sizeof bits, GT_KEY_POWER)) {
            fprintf(stderr, "gt-sleepmon: power key on %s\n", path);
            closedir(d);
            return f;
        }
        close(f);
    }
    closedir(d);
    return -1;
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

    fd = gt_open_power_device();
    if (fd < 0)   /* scan failed (permissions, exotic layout): pre-F51 path */
        fd = open("/dev/input/event0", O_RDONLY | O_NONBLOCK);
    if (fd < 0) { perror("gt-sleepmon: no power-key input device"); return 1; }

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
    /* F51: EVIOCGBIT keymap bit test used by the power-device scan */
    {
        unsigned char bits[15] = {0};            /* 15 bytes = codes 0..119 */
        bits[GT_KEY_POWER / 8] = (unsigned char)(1u << (GT_KEY_POWER % 8));
        if (!gt_keybit_has(bits, sizeof bits, GT_KEY_POWER)) return 10;
        if (gt_keybit_has(bits, sizeof bits, GT_KEY_POWER - 1)) return 11;
        if (gt_keybit_has(bits, sizeof bits, 120)) return 12;  /* past the buffer */
        if (gt_keybit_has(bits, 0, GT_KEY_POWER)) return 13;   /* empty buffer */
    }
    printf("sleepmon-test-ok\n");
    return 0;
}

#endif
