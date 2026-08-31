#!/bin/sh
. "$(dirname -- "$0")/helpers.sh"

# F43: RSDK Sonic ports use SDL_GameController, which IS recognized correctly
# on h700 (probe-confirmed isGameController=1, valid mapping) — yet controls
# are dead, an RSDK-internal defect this pak can't fix natively. Fall back to
# the pak's keyboard-synthesis path: put the launchers on the remap list and
# overlay a corrected sonic.gptk per game (via the generic F27 overlay
# mechanism, already covered by test-07).
#
# Device trace (2026-08-28) showed the shim's v1 index-remap cross-swaps
# physical faces vs. gptk button names on h700: physical A(south)=gptk `b`,
# B(east)=gptk `a`, X(west)=gptk `y`, Y(north)=gptk `x`. RSDK's shared action
# map has only two jump actions (A=jump, C=jump; B=pause; X/Y/Z=nothing), so
# to make the physical A+B faces jump with DISTINCT keys (no duplicate-key
# crash class) gptk `b`->RSDK-A key and gptk `a`->RSDK-C key. The RSDK-A/
# RSDK-C keys differ per [Keyboard 1] table, so sonic1 and sonic2 gptks are
# NOT identical: sonic1 = b->z(29,A) a->c(6,C); sonic2 = b->a(4,A) a->d(7,C).
# X/Y are deliberately left unmapped. back=esc is deliberately kept, not
# repurposed, to preserve a quit path.

assert_contains "$ROOT/assets/gt-remap-ports.txt" '^Sonic 1.sh$'
assert_contains "$ROOT/assets/gt-remap-ports.txt" '^Sonic 2.sh$'

for p in sonic1 sonic2; do
  f="$ROOT/assets/port-fixes/$p/sonic.gptk"
  [ -f "$f" ] || { echo "missing overlay gptk: $f"; exit 1; }
  assert_contains "$f" '^start = enter$'
  assert_contains "$f" '^back = esc$' # quit safety: NOT repurposed to tab
  assert_contains "$f" '^up = up$'
  assert_contains "$f" '^down = down$'
  assert_contains "$f" '^left = left$'
  assert_contains "$f" '^right = right$'
done

# per-game mapping: physical A(south)=gptk b, physical B(east)=gptk a (shim
# baseline). F48 device gate: a<->b swapped to the Nintendo baseline so
# menu-confirm (RSDK-A) sits on the physical A/right face; the shim flips to
# Xbox on demand. So RSDK-A key is on gptk a, RSDK-C key on gptk b.
f1="$ROOT/assets/port-fixes/sonic1/sonic.gptk"
assert_contains "$f1" '^a = z$'  # sonic1 RSDK-A key (gptk a)
assert_contains "$f1" '^b = c$'  # sonic1 RSDK-C key (gptk b)

f2="$ROOT/assets/port-fixes/sonic2/sonic.gptk"
assert_contains "$f2" '^a = a$'  # sonic2 RSDK-A key (gptk a)
assert_contains "$f2" '^b = d$'  # sonic2 RSDK-C key (gptk b)

sh -n "$ROOT/build/build-pak.sh"
assert_contains "$ROOT/build/build-pak.sh" 'port-fixes/sonic1'
assert_contains "$ROOT/build/build-pak.sh" 'port-fixes/sonic2'

echo "test-19 ok"
