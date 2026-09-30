.POSIX:
.PHONY: pak test clean shim gl4es-egl libcurl

pak:
	sh build/build-pak.sh portmaster
	@echo "pak: dist/Emus/h700/PORTS.pak.zip"

test:
	sh tests/run.sh

clean:
	rm -rf dist

# Debian bullseye is EOL/archived (~2026-08); deb.debian.org no longer serves it
# (the debian-security pool 404s), so the shim toolchain pins apt to a pre-EOL
# snapshot. Bump BULLSEYE_SNAPSHOT if a needed package version predates it.
# (The pak's own pinned .debs in pins.sh point at the same snapshot date.)
BULLSEYE_SNAPSHOT = 20260801T000000Z
APT_PIN = printf "deb [check-valid-until=no] http://snapshot.debian.org/archive/debian/$(BULLSEYE_SNAPSHOT) bullseye main\ndeb [check-valid-until=no] http://snapshot.debian.org/archive/debian-security/$(BULLSEYE_SNAPSHOT) bullseye-security main\n" > /etc/apt/sources.list && apt-get -o Acquire::Check-Valid-Until=false -o Acquire::Retries=3 update -qq

shim:
	# Pull each arch explicitly before its lane: the local `debian:bullseye` tag
	# caches whichever arch was pulled last, and `docker run --platform` will
	# silently reuse a wrong-arch cached image (producing e.g. a 32-bit
	# gt-input-remap.so). Pulling first pins the tag to this lane's arch.
	docker pull --platform linux/arm64 debian:bullseye
	docker run --rm --platform linux/arm64 -v "$$PWD/assets:/w" -w /w debian:bullseye sh -c \
	  '$(APT_PIN) && apt-get install -y -qq gcc libsdl2-dev libgles2-mesa-dev libegl1-mesa-dev libasound2-dev >/dev/null && \
	   gcc -O2 -Wall -shared -fPIC -o gt-input-remap.so gt-input-remap.c -ldl -pthread && strip gt-input-remap.so && \
	   gcc -O2 -Wall -shared -fPIC -o gt-fmod-audio.so gt-fmod-audio.c -ldl && strip gt-fmod-audio.so && \
	   gcc -O2 -Wall -shared -fPIC -o gt-gles3-profile.so gt-gles3-profile.c -ldl && strip gt-gles3-profile.so && \
	   gcc -O2 -Wall -shared -fPIC -o gt-sdl-audio-init.so gt-sdl-audio-init.c -ldl && strip gt-sdl-audio-init.so && \
	   gcc -O2 -Wall -o gt-sleepmon gt-sleepmon.c && strip gt-sleepmon && \
	   gcc -O2 -Wall -shared -fPIC -DPIC -o libasound_module_pcm_gt_suspend.so gt-alsa-suspend.c -lasound && strip libasound_module_pcm_gt_suspend.so'
	# gt-input-remap.armhf.so (F45): the 32-bit build of the same shim source, for
	# Animal Crossing (a 32-bit armhf port on aarch64 NextUI). Built in an armhf
	# bullseye container so the ELF is ARM/EABI5; only the input shim is needed in
	# 32-bit (the other shims serve aarch64-only ports).
	# libasound_module_pcm_gt_suspend.armhf.so (F47): the 32-bit build of the ALSA
	# suspend-proxy ioplug, for routing "default" on any armhf port.
	docker pull --platform linux/arm/v7 debian:bullseye
	docker run --rm --platform linux/arm/v7 -v "$$PWD/assets:/w" -w /w debian:bullseye sh -c \
	  '$(APT_PIN) && apt-get install -y -qq gcc libsdl2-dev libgles2-mesa-dev libegl1-mesa-dev libasound2-dev >/dev/null && \
	   gcc -O2 -Wall -shared -fPIC -o gt-input-remap.armhf.so gt-input-remap.c -ldl -pthread && strip gt-input-remap.armhf.so && \
	   gcc -O2 -Wall -shared -fPIC -DPIC -o libasound_module_pcm_gt_suspend.armhf.so gt-alsa-suspend.c -lasound && strip libasound_module_pcm_gt_suspend.armhf.so'
	file assets/gt-input-remap.so assets/gt-fmod-audio.so assets/gt-gles3-profile.so assets/gt-sdl-audio-init.so assets/gt-sleepmon assets/gt-input-remap.armhf.so assets/libasound_module_pcm_gt_suspend.so assets/libasound_module_pcm_gt_suspend.armhf.so

# F60: gl4es's fake EGL from a pinned ptitSeb/gl4es commit (master as of 2026-07-25),
# arm64 bullseye lane like `shim`. Outputs assets/gl4es-libEGL.so.1 + .txt provenance.
# Commit the outputs; build-pak.sh stages the .so under lib/gl4es-egl/ (a subdir on
# purpose - lib/ itself is on every port's LD_LIBRARY_PATH).
GL4ES_COMMIT = 81547d986798e876de8b434193920b606a72363f
# The gl4es lane pins apt to the same BULLSEYE_SNAPSHOT as `make shim` (defined
# above); build/gl4es-egl.sh writes the sources.list itself from the env var.

gl4es-egl:
	docker pull --platform linux/arm64 debian:bullseye
	docker run --rm --platform linux/arm64 -v "$$PWD:/repo" -w /repo -e GL4ES_COMMIT=$(GL4ES_COMMIT) -e BULLSEYE_SNAPSHOT=$(BULLSEYE_SNAPSHOT) debian:bullseye sh /repo/build/gl4es-egl.sh
	file assets/gl4es-libEGL.so.1

# F67: a slim libcurl.so.4 (HTTP/HTTPS only) from a pinned curl release, for
# ports that link libcurl and bundle none (Sonic 3 AIR, Doom 3). Built in a
# digest-pinned ubuntu:22.04 arm64 container — NOT the bullseye lane: it links
# rc11's own jammy libssl.so.3/libcrypto.so.3/zlib (bullseye's OpenSSL is 1.1).
# Outputs assets/libcurl.so.4 + .txt provenance; commit both. build-pak.sh
# stages the .so straight into lib/ (on every port's LD_LIBRARY_PATH).
CURL_VERSION = 8.22.0
CURL_SHA256 = d54dd598bf05927a726deb38df31c6a255ba83ff1de57c5d1464dac3ed8f44a1
LIBCURL_IMAGE = ubuntu@sha256:b8b6ee6aa931ecd9d0d952abc34dc0e5f7c6a30c6bb71b079fe399fde0329c02

libcurl:
	docker run --rm --platform linux/arm64 -v "$$PWD:/repo" -w /repo -e CURL_VERSION=$(CURL_VERSION) -e CURL_SHA256=$(CURL_SHA256) -e LIBCURL_IMAGE=$(LIBCURL_IMAGE) $(LIBCURL_IMAGE) sh /repo/build/libcurl.sh
	file assets/libcurl.so.4
