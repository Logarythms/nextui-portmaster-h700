# gt-h700-syslib-inject — spliced verbatim over the upstream function body by
# this repo's edit_portmaster_launch (build/build-pak.sh). Appends the
# platform system-lib dir (resolved by the gt-h700-syslib case block) instead
# of a hardcoded TrimUI path, PLUS the pak's own lib/ (F21): ports that
# hard-reset LD_LIBRARY_PATH otherwise lose every pak-shipped compat lib —
# Tunics!/Solarus faulted on libopenal.so.1 while the pak carried it
# (hardware-diagnosed 2026-08-23). Pak lib/ goes LAST so port-bundled and
# system libs keep priority. Keeps the upstream function name so both call
# sites stay untouched.
# Idempotency: per-FILE skip via grep on the pak-lib suffix (upstream skipped
# per-line via a sed address; per-file is what the callers need). A script a
# pre-F21 pak already injected carries $SYSTEM_LIB_DIR but not $PAK_DIR/lib;
# it gets one harmless duplicate SYSTEM_LIB_DIR entry when re-injected here.
# shellcheck disable=SC2154  # SYSTEM_LIB_DIR and PAK_DIR are defined by the host launch.sh
# shellcheck disable=SC2329  # invoked by the host launch.sh, not this fragment
inject_trimui_lib_path() {
    while IFS= read -r file || [ -n "$file" ]; do
        [ -z "$file" ] && continue
        grep -q "$PAK_DIR/lib" "$file" && continue
        echo "Ensuring $SYSTEM_LIB_DIR and $PAK_DIR/lib are on LD_LIBRARY_PATH in $file"
        sed -i \
            -e "s|\\(LD_LIBRARY_PATH=\"[^\"]*\\)\"|\\1:$SYSTEM_LIB_DIR:$PAK_DIR/lib\"|g" \
            -e "s|\\(LD_LIBRARY_PATH='[^']*\\)'|\\1:$SYSTEM_LIB_DIR:$PAK_DIR/lib'|g" \
            "$file"
    done
}
