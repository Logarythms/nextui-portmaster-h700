#!/bin/sh
. "$(dirname -- "$0")/helpers.sh"

# F61: run_port resolves the port folder from a GAMEDIR= line in the launcher
# and refuses to run when there is none ("No GAMEDIR found ... not executing
# game", exit 1). Fallout 1's launcher declares PORTDIR= only (issue #1). Fall
# back to PORTDIR= when GAMEDIR is empty; run_port's own $PORTDIR
# ("/$directory/ports") is saved and restored around the eval.
work="$SANDBOX/pmpak"; mkdir -p "$work"
cp "$TROOT/fixtures/portmaster-pak-skeleton/pak.json.fixture" "$work/pak.json"
cp "$TROOT/fixtures/portmaster-pak-skeleton/launch.sh.fixture" "$work/launch.sh"
GT_STAGE_EDIT_ONLY="$work" sh "$ROOT/build/build-pak.sh" portmaster

assert_contains "$work/launch.sh" 'gt-h700-gamedir-fallback (F61)'
# shellcheck disable=SC2016
resolve_line=$(grep -n '^    GAMEDIR="\${GAMEDIR:-\$gamedir}"$' "$work/launch.sh" | head -1 | cut -d: -f1)
fb_line=$(grep -n 'gt-h700-gamedir-fallback (F61)' "$work/launch.sh" | head -1 | cut -d: -f1)
echo_line=$(grep -n 'echo "Game dir is: \$GAMEDIR"' "$work/launch.sh" | head -1 | cut -d: -f1)
[ "$resolve_line" -lt "$fb_line" ] && [ "$fb_line" -lt "$echo_line" ] \
  || { echo "fallback must sit between the GAMEDIR resolution and the 'Game dir is' echo"; exit 1; }
# upstream's refusal path is untouched (it still guards a launcher with neither line)
assert_contains "$work/launch.sh" 'No GAMEDIR found in \$ROM_PATH, not executing game.'

# ---------- behavioral: slice the block and run it against fake launchers ----------
sed -n '/# gt-h700-gamedir-fallback (F61)/,/^    fi$/p' "$work/launch.sh" > "$SANDBOX/fb-block.sh"
run_fb() { # $1=launcher $2=preset GAMEDIR ; prints "<GAMEDIR>|<PORTDIR>"
    ( directory=roms PORTDIR=/roms/ports GAMEDIR="$2" ROM_PATH="$1" ROM_NAME="$(basename "$1")" \
        sh -c ". \"$SANDBOX/fb-block.sh\" >/dev/null; printf '%s|%s' \"\$GAMEDIR\" \"\$PORTDIR\"" )
}
printf '#!/bin/bash\nPORTDIR="/$directory/ports/fallout1"\ncd $PORTDIR\n' > "$SANDBOX/fallout.sh"
assert_eq "$(run_fb "$SANDBOX/fallout.sh" '')" "/roms/ports/fallout1|/roms/ports" "PORTDIR= taken as GAMEDIR, run_port PORTDIR restored"
printf '#!/bin/bash\nexport PORTDIR="/$directory/ports/fo1"\n' > "$SANDBOX/fallout-export.sh"
assert_eq "$(run_fb "$SANDBOX/fallout-export.sh" '')" "/roms/ports/fo1|/roms/ports" "export PORTDIR= form"
assert_eq "$(run_fb "$SANDBOX/fallout.sh" /roms/ports/other)" "/roms/ports/other|/roms/ports" "a resolved GAMEDIR is never overridden"
printf '#!/bin/bash\nPORTDIR="/$directory/ports"\ncd $PORTDIR\n' > "$SANDBOX/bare-portdir.sh"
assert_eq "$(run_fb "$SANDBOX/bare-portdir.sh" '')" "|/roms/ports" "PORTDIR= at the bare ports root is rejected, GAMEDIR stays empty"
out_bare=$( ( directory=roms PORTDIR=/roms/ports GAMEDIR= ROM_PATH="$SANDBOX/bare-portdir.sh" ROM_NAME=bare-portdir.sh \
    sh -c ". \"$SANDBOX/fb-block.sh\"" ) || true )
case "$out_bare" in *'using PORTDIR= as the game dir'*) echo "fallback log line printed though GAMEDIR ended up empty: $out_bare"; exit 1;; *) ;; esac
printf '#!/bin/bash\nportdir="/$directory/ports/x"\ncd $portdir\n' > "$SANDBOX/lowercase-portdir.sh"
assert_eq "$(run_fb "$SANDBOX/lowercase-portdir.sh" '')" "/roms/ports/x|/roms/ports" "lowercase portdir= form is accepted"
printf '#!/bin/bash\necho hi\n' > "$SANDBOX/plain.sh"
assert_eq "$(run_fb "$SANDBOX/plain.sh" '')" "|/roms/ports" "neither line -> GAMEDIR stays empty (upstream refusal follows)"
out=$( ( directory=roms PORTDIR=/roms/ports GAMEDIR= ROM_PATH="$SANDBOX/fallout.sh" ROM_NAME=fallout.sh sh -c ". \"$SANDBOX/fb-block.sh\"" ) )
case "$out" in *'using PORTDIR= as the game dir: /roms/ports/fallout1 (F61)'*) ;; *) echo "missing fallback log line: $out"; exit 1;; esac

sh -n "$work/launch.sh" || { echo "edited launch.sh does not parse"; exit 1; }
GT_STAGE_EDIT_ONLY="$work" sh "$ROOT/build/build-pak.sh" portmaster
assert_eq "$(grep -c 'gt-h700-gamedir-fallback (F61)' "$work/launch.sh")" 1 "marker once after re-run"

echo "test-33-gamedir-fallback: OK"
