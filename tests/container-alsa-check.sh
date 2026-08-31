#!/bin/sh
# F47: functional check of the ALSA suspend-proxy in the arm64 bullseye
# container against a `type null` slave — no audio hardware needed.
# Run manually (or from CI); NOT part of tests/run.sh (needs docker+network).
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
docker run --rm --platform linux/arm64 -v "$ROOT/assets:/w" -w /w debian:bullseye sh -ec '
  apt-get update -qq && apt-get install -y -qq gcc libasound2-dev alsa-utils >/dev/null
  gcc -O2 -Wall -shared -fPIC -DPIC -o /tmp/libasound_module_pcm_gt_suspend.so gt-alsa-suspend.c -lasound
  cat > /tmp/test.conf <<EOF
</usr/share/alsa/alsa.conf>
pcm_type.gt_suspend { lib "/tmp/libasound_module_pcm_gt_suspend.so" }
pcm.gt_null { type null }
pcm.gt_test { type gt_suspend slave.pcm "gt_null" }
EOF
  # 30s of silence: the null slave negotiates a ~5512-frame period here, so a
  # forced reopen (which fires at gt_transfer() call #50, see GT_SUSPEND_FORCE_REOPEN
  # in gt-alsa-suspend.c) needs well over 50 periods worth of frames to actually
  # be reached; 3s (the original size) only produced ~24 transfer() calls.
  dd if=/dev/zero of=/tmp/z.raw bs=176400 count=30 2>/dev/null
  ALSA_CONFIG_PATH=/tmp/test.conf aplay -q -D gt_test -t raw -f S16_LE -c 2 -r 44100 /tmp/z.raw
  echo "plain pass OK"
  ALSA_CONFIG_PATH=/tmp/test.conf GT_SUSPEND_FORCE_REOPEN=1 \
    aplay -q -D gt_test -t raw -f S16_LE -c 2 -r 44100 /tmp/z.raw 2>&1 | tee /tmp/out
  grep -q "gt-alsa-suspend: reopening slave" /tmp/out
  echo CONTAINER-ALSA-OK'
