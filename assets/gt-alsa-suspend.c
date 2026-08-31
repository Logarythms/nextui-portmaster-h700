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
#include <unistd.h>
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
        if (err >= 0) { pcm->force_reopen = 0; return 0; }
        usleep(100000);
    }
    return err;
}

static int gt_suspend_happened(gt_pcm_t *pcm) {
    /* Like the real delta check, the force hook stays true until a reopen
     * cures it (gt_reopen_slave clears it) — a reopen via the
     * XRUN/prepare path doesn't advance the transfer count, so consuming
     * the flag here instead would fire the XRUN without the reopen. */
    if (pcm->force_reopen && pcm->transfers >= 50) return 1;
    return gt_delta_ns() - pcm->delta_base_ns > GT_DELTA_JUMP_NS;
}

/* A slave in any other state (SUSPENDED, XRUN, SETUP, DISCONNECTED, ...)
 * must never be trusted for delay/poll answers — only reopened. */
static int gt_slave_live(gt_pcm_t *pcm) {
    snd_pcm_state_t st;
    if (!pcm->slave) return 0;
    st = snd_pcm_state(pcm->slave);
    return st == SND_PCM_STATE_PREPARED || st == SND_PCM_STATE_RUNNING
        || st == SND_PCM_STATE_DRAINING;
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
        /* Known-recoverable trio: try in-place recovery first. Anything
         * else (or failed recovery) gets the full close+reopen cure before
         * the error is allowed to reach the app — SDL2 treats an
         * unrecoverable write error as a device disconnect and never
         * writes again. */
        if (!((n == -ESTRPIPE || n == -EPIPE || n == -EBADFD)
              && snd_pcm_recover(pcm->slave, (int)n, 1) >= 0)
            && gt_reopen_slave(pcm) < 0)
            return n;
        n = snd_pcm_writei(pcm->slave, buf, size);
        if (n < 0) return n;
    }
    return n;
}

static snd_pcm_sframes_t gt_pointer(snd_pcm_ioplug_t *io) {
    gt_pcm_t *pcm = io->private_data;
    snd_pcm_sframes_t delay = 0, hw;
    /* A dead or post-suspend slave cannot report progress through this
     * interface at all: the return is modulo buffer_size, where "empty"
     * and "full" are the same position — with a full ring an empty-ring
     * report computes zero delta, avail stays 0, and the writer spins on
     * poll forever (gate round D, Celeste). Return negative instead:
     * ioplug flags the frontend XRUN, the app's standard recover() calls
     * prepare, and gt_prepare performs the reopen. */
    if (!gt_slave_live(pcm) || gt_suspend_happened(pcm))
        return -EPIPE;
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
    if (gt_slave_live(pcm) && !gt_suspend_happened(pcm)
        && snd_pcm_delay(pcm->slave, delayp) >= 0) return 0;
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
    if (snd_pcm_prepare(pcm->slave) < 0)
        return gt_reopen_slave(pcm);
    return 0;
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
    int err;
    if (!pcm->slave) { *revents = POLLOUT; return 0; }
    err = snd_pcm_poll_descriptors_revents(pcm->slave, pfd, nfds, revents);
    /* Never surface a dead slave's error bits: snd_pcm_wait turns POLLERR
     * on a RUNNING frontend into -EIO, which SDL2 treats as a permanent
     * device disconnect (gate round B: audio dead from the second wake
     * on). Reporting "writable" instead routes the app's next write into
     * gt_transfer, where the reopen cure lives. */
    if (err < 0 || (*revents & (POLLERR | POLLHUP | POLLNVAL))
        || !gt_slave_live(pcm) || gt_suspend_happened(pcm)) {
        *revents = POLLOUT;
        return 0;
    }
    return err;
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
    if (!pcm->slave_name) { free(pcm); return -ENOMEM; }
    pcm->force_reopen = getenv("GT_SUSPEND_FORCE_REOPEN") != NULL;
    pcm->io.version = SND_PCM_IOPLUG_VERSION;
    pcm->io.name = "gt suspend-safe proxy";
    pcm->io.callback = &gt_callbacks;
    pcm->io.private_data = pcm;
    pcm->io.mmap_rw = 0;

    err = snd_pcm_ioplug_create(&pcm->io, name, stream, mode);
    if (err < 0) { free(pcm->slave_name); free(pcm); return err; }
    err = gt_set_constraints(&pcm->io);
    if (err < 0) {
        snd_pcm_ioplug_delete(&pcm->io);
        free(pcm->slave_name);
        free(pcm);
        return err;
    }
    *pcmp = pcm->io.pcm;
    return 0;
}

SND_PCM_PLUGIN_SYMBOL(gt_suspend);
