.POSIX:
.PHONY: pak test clean shim

pak:
	sh build/build-pak.sh portmaster
	@echo "pak: dist/Emus/h700/PORTS.pak.zip"

test:
	sh tests/run.sh

clean:
	rm -rf dist

shim:
	docker run --rm --platform linux/arm64 -v "$$PWD/assets:/w" -w /w debian:bullseye sh -c \
	  'apt-get update -qq && apt-get install -y -qq gcc libsdl2-dev libgles2-mesa-dev libegl1-mesa-dev >/dev/null && \
	   gcc -O2 -Wall -shared -fPIC -o gt-input-remap.so gt-input-remap.c -ldl -pthread && strip gt-input-remap.so && \
	   gcc -O2 -Wall -shared -fPIC -o gt-fmod-audio.so gt-fmod-audio.c -ldl && strip gt-fmod-audio.so && \
	   gcc -O2 -Wall -shared -fPIC -o gt-gles3-profile.so gt-gles3-profile.c -ldl && strip gt-gles3-profile.so'
	file assets/gt-input-remap.so assets/gt-fmod-audio.so assets/gt-gles3-profile.so
