#!/bin/sh
. "$(dirname -- "$0")/helpers.sh"

# F43: RSDK Sonic ports use SDL_GameController, which IS recognized correctly
# on h700 (probe-confirmed isGameController=1, valid mapping) — yet controls
# are dead, an RSDK-internal defect this pak can't fix natively. Fall back to
# the pak's keyboard-synthesis path: put the launchers on the remap list and
# overlay a corrected sonic.gptk (via the generic F27 overlay mechanism,
# already covered by test-07) mapping the gamepad to RSDK's [Keyboard 1]
# scancodes (Up=82 Down=81 Left=80 Right=79, A=29(z) B=27(x) X=4(a) Y=22(s),
# Start=40(enter)). back=esc is deliberately kept, not repurposed, to
# preserve a quit path.

assert_contains "$ROOT/assets/gt-remap-ports.txt" '^Sonic 1.sh$'
assert_contains "$ROOT/assets/gt-remap-ports.txt" '^Sonic 2.sh$'

for p in sonic1 sonic2; do
  f="$ROOT/assets/port-fixes/$p/sonic.gptk"
  [ -f "$f" ] || { echo "missing overlay gptk: $f"; exit 1; }
  assert_contains "$f" '^a = z$'      # A -> jump (scancode 29)
  assert_contains "$f" '^b = x$'      # B (scancode 27)
  assert_contains "$f" '^x = a$'      # X (scancode 4)
  assert_contains "$f" '^y = s$'      # Y (scancode 22)
  assert_contains "$f" '^start = enter$'
  assert_contains "$f" '^back = esc$' # quit safety: NOT repurposed to tab
  assert_contains "$f" '^up = up$'
  assert_contains "$f" '^down = down$'
  assert_contains "$f" '^left = left$'
  assert_contains "$f" '^right = right$'
done

# sonic1 and sonic2 overlays are identical
diff "$ROOT/assets/port-fixes/sonic1/sonic.gptk" "$ROOT/assets/port-fixes/sonic2/sonic.gptk" \
  || { echo "sonic1/sonic2 gptk overlays differ"; exit 1; }

sh -n "$ROOT/build/build-pak.sh"
assert_contains "$ROOT/build/build-pak.sh" 'port-fixes/sonic1'
assert_contains "$ROOT/build/build-pak.sh" 'port-fixes/sonic2'

echo "test-19 ok"
