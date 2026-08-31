#!/bin/sh
. "$(dirname -- "$0")/helpers.sh"

# F48: gt_patch_optionscene_layout.py adds the layout toggle to OptionScene,
# confined to that class, idempotent, valid python.
if ! command -v python3 >/dev/null 2>&1; then
    echo "SKIP: no python3; optionscene-layout patch test not run"
    exit 0
fi
fix="$SANDBOX/pugscene.py"
cat > "$fix" <<'PY'
class BaseScene:
    pass

class OptionScene(BaseScene):
    def __init__(self, gui):
        self.gui = gui
        self.tags['option_list'].add_option(
            'toggle-experimental',
            _("Experimental Ports: ") + "x")
        self.tags['option_list'].list_select(0)
        self.set_buttons({'A': _('Enter'), 'B': _('Back')})

    def do_update(self, events):
        if events.was_pressed('A'):
            selected_option = self.tags['option_list'].selected_option()
            self.button_activate()
            if selected_option == 'toggle-experimental':
                return True

class MainMenuScene(BaseScene):
    def __init__(self, gui):
        self.button_activate()
        self.tags['option_list'].list_select(0)
PY

python3 "$ROOT/src/gt_patch_optionscene_layout.py" "$fix" || { echo "helper failed"; exit 1; }
grep -q "'gt-controller-layout-toggle'" "$fix" || { echo "toggle option not added"; exit 1; }
grep -q "self.gui.hm.cfg_data\['gt-controller-layout'\] = new_layout" "$fix" || { echo "press handler not added"; exit 1; }
python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$fix" || { echo "patched file not valid python"; exit 1; }
# confined to OptionScene: MainMenuScene must be untouched (its button_activate has no branch after it)
awk '/class MainMenuScene/,0' "$fix" | grep -q 'gt-controller-layout' && { echo "leaked into MainMenuScene"; exit 1; }

# idempotent
python3 "$ROOT/src/gt_patch_optionscene_layout.py" "$fix" || { echo "second run failed"; exit 1; }
# 'gt-controller-layout-toggle' legitimately appears on two lines per single,
# correct application (the add_option key + the press-branch comparison), so
# grep -c on that literal can't distinguish "applied once" from "duplicated".
# The cfg_data assignment line is unique per application; count that instead.
n=$(grep -c "self.gui.hm.cfg_data\['gt-controller-layout'\] = new_layout" "$fix")
assert_eq "$n" "1" "toggle inserted more than once"

echo "test-28-optionscene-layout-patch OK"
