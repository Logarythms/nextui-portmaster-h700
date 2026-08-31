#!/bin/sh
. "$(dirname -- "$0")/helpers.sh"

# F48: gt_patch_platform_layout.py inserts PlatformTrimUI.loaded() reading the
# config key, is idempotent, and produces valid Python.
if ! command -v python3 >/dev/null 2>&1; then
    echo "SKIP: no python3; platform-layout patch test not run"
    exit 0
fi
fix="$SANDBOX/platform.py"
cat > "$fix" <<'PY'
class PlatformBase():
    WANT_SWAP_BUTTONS = False

class PlatformTrimUI(PlatformBase):
    WANT_XBOX_FIX = True
    ES_NAME = "trimui"

    def first_run(self):
        pass
PY

python3 "$ROOT/src/gt_patch_platform_layout.py" "$fix" || { echo "helper failed"; exit 1; }
grep -q "cfg_data.get('gt-controller-layout', 'nintendo')" "$fix" || { echo "loaded() not inserted"; exit 1; }
grep -q "self.WANT_XBOX_FIX = False" "$fix" || { echo "WANT_XBOX_FIX polarity line not inserted"; exit 1; }
grep -q "self.WANT_SWAP_BUTTONS = (layout == 'nintendo')" "$fix" || { echo "WANT_SWAP_BUTTONS polarity line not inserted"; exit 1; }
python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$fix" || { echo "patched file is not valid python"; exit 1; }

# idempotent
python3 "$ROOT/src/gt_patch_platform_layout.py" "$fix" || { echo "second run failed"; exit 1; }
n=$(grep -c "def loaded(self):" "$fix")
assert_eq "$n" "1" "loaded() inserted more than once"

echo "test-27-platform-layout-patch OK"
