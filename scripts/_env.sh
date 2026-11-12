# Sourced by every script in this folder.
# Keeps build byproducts inside the project: SwiftPM and the compiler write temporary
# directories, lock files and module caches to $TMPDIR and the global clang cache.
# Pointing them into .build/ contains them, and the EXIT trap removes the temporary part.

ROOT="${0:A:h:h}"
cd "$ROOT"

export TMPDIR="$ROOT/.build/tmp"
export CLANG_MODULE_CACHE_PATH="$ROOT/.build/module-cache"
mkdir -p "$TMPDIR"

_strata_cleanup_tmp() {
    if [[ -n "${TMPDIR:-}" && "$TMPDIR" == "$ROOT/.build/tmp" ]]; then
        rm -rf "$TMPDIR"
    fi
    # The compiler writes macro expansions to the system temp folder whatever TMPDIR says.
    # Remove the ones from this package's modules (the module name is spelled with its length).
    setopt local_options null_glob
    local generated="$(getconf DARWIN_USER_TEMP_DIR)swift-generated-sources"
    if [[ -d "$generated" ]]; then
        local module
        for module in 6Strata 8ScanCore 9MapLayout 11StrataTests 13ScanCoreTests 14MapLayoutTests; do
            rm -f -- "$generated"/@__swiftmacro_${module}[0-9]*
        done
    fi
}
trap _strata_cleanup_tmp EXIT

BUNDLE_ID="com.glimmer.strata"
# The app bundle is staged in a ".noindex" folder: Spotlight skips it, so a build copy never
# shows up next to the installed app.
STAGED_APP="$ROOT/build/stage.noindex/Strata.app"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

_strata_remove_staged_app() {
    if [[ -d "$STAGED_APP" ]]; then
        "$LSREGISTER" -u "$STAGED_APP" 2>/dev/null || true
    fi
    rm -rf "${STAGED_APP:h}"
}
