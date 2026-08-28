#!/bin/sh
. "$(dirname -- "$0")/helpers.sh"

# pure decision compiles + behaves
cc -DGT_SDL_AUDIO_TEST -O2 -o "$SANDBOX/audio-test" "$ROOT/assets/gt-sdl-audio-init.c"
assert_eq "$("$SANDBOX/audio-test" 0)" "1"   # not inited -> init
assert_eq "$("$SANDBOX/audio-test" 1)" "0"   # already inited -> skip

# staged + gated in build-pak.sh
sh -n "$ROOT/build/build-pak.sh"
assert_contains "$ROOT/build/build-pak.sh" 'gt-sdl-audio-init.so'
assert_contains "$ROOT/build/build-pak.sh" '$GAMEDIR/sonic2013'
echo "test-18 ok"
