#!/bin/sh
. "$(dirname -- "$0")/helpers.sh"

# F50: gt_patch_portinfo_layout.py adds a per-game controller-layout control to
# PortInfoScene's free X button, confined to that class, idempotent, valid
# python. Fixture is hand-rolled (NOT extracted from dist/.../pylibs.zip,
# which is a gitignored build artifact absent in a clean checkout/CI/the LXC)
# — mirrors the test-27/test-28 pattern.
if ! command -v python3 >/dev/null 2>&1; then
    echo "SKIP: no python3; portinfo-layout patch test not run"
    exit 0
fi
fix="$SANDBOX/pugscene.py"
cat > "$fix" <<'PY'
class BaseScene:
    def do_update(self, events):
        pass

class PortInfoScene(BaseScene):
    def __init__(self, gui):
        self.gui = gui
        self.port_info = {}
        self.port_attrs = {}

    def update_port(self):
        buttons = {}
        buttons['A'] = _("Install")
        buttons['B'] = _("Back")
        self.set_buttons(buttons)

    def do_update(self, events):
        super().do_update(events)
        if events.was_pressed('A'):
            self.button_activate()
            return True

class FiltersScene(BaseScene):
    def __init__(self, gui):
        self.gui = gui

    def do_update(self, events):
        super().do_update(events)
PY

python3 "$ROOT/src/gt_patch_portinfo_layout.py" "$fix" || { echo "helper failed"; exit 1; }

grep -q "gt-h700-portinfo-layout" "$fix" || { echo "marker not inserted"; exit 1; }
grep -q "buttons\['X'\] = _(\"Layout: \")" "$fix" || { echo "X label not inserted"; exit 1; }
grep -q "gt-port-layout" "$fix" || { echo "per-game key write not inserted"; exit 1; }
grep -q "its own first-run screen" "$fix" || { echo "disclaimer not inserted"; exit 1; }

python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$fix" \
  || { echo "patched file is not valid python"; exit 1; }

# Confined to PortInfoScene: nothing leaked into the next class.
awk '/^class PortInfoScene\(BaseScene\):/{p=1} /^class /{ if(p && $0 !~ /PortInfoScene/) p=0 } p && /gt-h700-portinfo-layout/{c++} END{exit !(c>=2)}' "$fix" \
  || { echo "injection not confined to PortInfoScene"; exit 1; }
awk '/^class FiltersScene/{f=1} f && /gt-h700-portinfo-layout/{print "leaked"; exit 1}' "$fix"

# idempotent
cp "$fix" "$SANDBOX/once"
python3 "$ROOT/src/gt_patch_portinfo_layout.py" "$fix" || { echo "second run failed"; exit 1; }
cmp -s "$SANDBOX/once" "$fix" || { echo "not idempotent"; exit 1; }

echo "test-29-portinfo-layout-patch OK"
