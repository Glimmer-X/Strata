#!/bin/zsh
# Renders the pictures in the README from a made-up disk (Sources/Strata/DemoDisk.swift),
# once per language, without opening a window: docs/images/<language>/<name>.png, plus the
# icon as docs/images/icon.png.
set -euo pipefail
source "${0:A:h}/_env.sh"

# The packaged app, because only the bundle carries the translations.
"$ROOT/scripts/build-app.sh" >/dev/null
BIN="$STAGED_APP/Contents/MacOS/Strata"

for language in en zh-Hans ja; do
    OUT="$ROOT/docs/images/$language"
    mkdir -p "$OUT"
    shot() {
        local name="$1"; shift
        "$BIN" --snapshot "$OUT/$name.png" --demo on --window on -AppleLanguages "($language)" "$@" >/dev/null
    }
    shot bubbles --hover Library
    shot flow --mode flow --theme moss
    shot folder --theme frost --focus Users/alex/Library
    shot cleanup --theme dusk --tab cleanup
done

sips -s format png -z 512 512 "$ROOT/Resources/AppIcon.icns" --out "$ROOT/docs/images/icon.png" >/dev/null
_strata_remove_staged_app
echo "Wrote docs/images/"
