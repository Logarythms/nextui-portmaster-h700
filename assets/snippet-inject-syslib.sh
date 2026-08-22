# gt-h700-syslib-inject — spliced verbatim over the upstream function body by
# this repo's edit_portmaster_launch (build/build-pak.sh). Appends the
# platform system-lib dir (resolved by the gt-h700-syslib case block) instead
# of a hardcoded TrimUI path. Keeps the upstream function name so both call
# sites stay untouched.
# Idempotency: per-FILE skip via grep (upstream skipped per-line via a sed
# address; per-file is what the callers need).
# shellcheck disable=SC2154  # SYSTEM_LIB_DIR is defined by the host launch.sh
# shellcheck disable=SC2329  # invoked by the host launch.sh, not this fragment
inject_trimui_lib_path() {
    while IFS= read -r file || [ -n "$file" ]; do
        [ -z "$file" ] && continue
        grep -q "$SYSTEM_LIB_DIR" "$file" && continue
        echo "Ensuring $SYSTEM_LIB_DIR is on LD_LIBRARY_PATH in $file"
        sed -i \
            -e "s|\\(LD_LIBRARY_PATH=\"[^\"]*\\)\"|\\1:$SYSTEM_LIB_DIR\"|g" \
            -e "s|\\(LD_LIBRARY_PATH='[^']*\\)'|\\1:$SYSTEM_LIB_DIR'|g" \
            "$file"
    done
}
