#!/bin/sh
# F47: functional check of the ALSA suspend-proxy in the arm64 bullseye
# container against a `type null` slave — no audio hardware needed.
# Run manually (or from CI); NOT part of tests/run.sh (needs docker+network).
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
docker run --rm --platform linux/arm64 -v "$ROOT/assets:/w" -w /w debian:bullseye sh -ec '
  apt-get update -qq && apt-get install -y -qq gcc libasound2-dev alsa-utils >/dev/null
  gcc -O2 -Wall -shared -fPIC -DPIC -o /tmp/libasound_module_pcm_gt_suspend.so gt-alsa-suspend.c -lasound
  # NOTE (F55): deliberately NO alsa.conf include here -- this mirrors the real
  # gt-asound.conf, which is self-contained by design (see F47 notes). Loading
  # alsa.conf changes how snd_device_name_hint() behaves: with it included,
  # alsa-lib enumerates every top-level pcm node regardless of a hint{} block,
  # which would make the enumeration check below pass for the wrong reason.
  # Device/container-proven 2026-09-04: only a self-contained tree reproduces
  # "unhinted nodes are invisible to aplay -L" -- the rule the gt-asound.conf
  # pcm.default hint{} block relies on.
  cat > /tmp/test.conf <<EOF
pcm_type.gt_suspend { lib "/tmp/libasound_module_pcm_gt_suspend.so" }
pcm.gt_null { type null }
pcm.gt_test { type gt_suspend slave.pcm "gt_null" }
pcm.gt_hinted { type gt_suspend slave.pcm "gt_null" hint { show on description "hinted proxy" } }
EOF
  # 30s of silence: the null slave negotiates a ~5512-frame period here, so a
  # forced reopen (which fires at gt_transfer() call #50, see GT_SUSPEND_FORCE_REOPEN
  # in gt-alsa-suspend.c) needs well over 50 periods worth of frames to actually
  # be reached; 3s (the original size) only produced ~24 transfer() calls.
  dd if=/dev/zero of=/tmp/z.raw bs=176400 count=30 2>/dev/null
  ALSA_CONFIG_PATH=/tmp/test.conf aplay -q -D gt_test -t raw -f S16_LE -c 2 -r 44100 /tmp/z.raw
  echo "plain pass OK"
  # F55: snd_device_name_hint() (aplay -L, and SDL2) lists ONLY hinted pcm nodes —
  # the rule the gt-asound.conf hint block relies on. gt_test has no hint and must
  # NOT appear; gt_hinted must.
  ALSA_CONFIG_PATH=/tmp/test.conf aplay -L > /tmp/hints
  grep -qx gt_hinted /tmp/hints || { echo "hinted pcm not enumerated:"; cat /tmp/hints; exit 1; }
  if grep -qx gt_test /tmp/hints; then echo "UNHINTED pcm enumerated - alsa-lib rule changed?"; cat /tmp/hints; exit 1; fi
  echo "hint enumeration OK"
  ALSA_CONFIG_PATH=/tmp/test.conf GT_SUSPEND_FORCE_REOPEN=1 \
    aplay -q -D gt_test -t raw -f S16_LE -c 2 -r 44100 /tmp/z.raw 2>&1 | tee /tmp/out
  grep -q "gt-alsa-suspend: reopening slave" /tmp/out
  echo CONTAINER-ALSA-OK'
