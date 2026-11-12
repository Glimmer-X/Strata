#!/bin/zsh
# Builds Strata.app (release).
#   scripts/build-app.sh            -> build/stage.noindex/Strata.app
#   scripts/build-app.sh --install  -> also installs it to /Applications (or ~/Applications)
#                                      and removes the staged copy
#   add --open to launch the installed app
#
# The app is signed with the Developer ID certificate when the keychain has one (or the one
# STRATA_IDENTITY names), so that macOS keeps the Full Disk Access grant across rebuilds;
# otherwise ad hoc, and the grant has to be given again after every build.
set -euo pipefail
source "${0:A:h}/_env.sh"

swift build -c release --product Strata
BIN="$(swift build -c release --show-bin-path)/Strata"

APP="$STAGED_APP"
_strata_remove_staged_app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Strata"
# Debug symbols name the object files and sources by their paths on this Mac; the app does
# not need them.
strip -S -x "$APP/Contents/MacOS/Strata"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
xcrun xcstringstool compile "$ROOT/Resources/Localizable.xcstrings" --output-directory "$APP/Contents/Resources"
# The catalog's keys are the Chinese text, so Chinese gets no table from the compiler. Without
# one, macOS would fall back to English (the development region), so write it: every key
# standing for itself.
mkdir -p "$APP/Contents/Resources/zh-Hans.lproj"
/usr/bin/python3 - "$ROOT/Resources/Localizable.xcstrings" "$APP/Contents/Resources/zh-Hans.lproj/Localizable.strings" <<'PY'
import json, plistlib, sys
strings = json.load(open(sys.argv[1]))["strings"]
table = {key: key for key, entry in strings.items() if entry.get("shouldTranslate", True)}
with open(sys.argv[2], "wb") as out:
    plistlib.dump(table, out, fmt=plistlib.FMT_BINARY)
PY
# The icon.
if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
    cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist"
fi

IDENTITY="${STRATA_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)}"
# A release needs Apple's secure timestamp; everyday builds skip the round trip.
TIMESTAMP="--timestamp=none"
[[ -n "${STRATA_RELEASE:-}" ]] && TIMESTAMP="--timestamp"
if [[ -n "$IDENTITY" ]]; then
    codesign --force --options runtime "$TIMESTAMP" --sign "$IDENTITY" "$APP"
else
    codesign --force --sign - --timestamp=none "$APP"
fi
codesign --verify --strict "$APP"
echo "Built $APP"

if [[ " $* " == *" --install "* ]]; then
    DEST_DIR="/Applications"
    [[ -w "$DEST_DIR" ]] || DEST_DIR="$HOME/Applications"
    mkdir -p "$DEST_DIR"
    DEST="$DEST_DIR/Strata.app"

    if pgrep -x Strata >/dev/null; then
        osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
        for _ in {1..20}; do pgrep -x Strata >/dev/null || break; sleep 0.25; done
        if pgrep -x Strata >/dev/null; then
            echo "Strata is still running; quit it and re-run." >&2
            exit 1
        fi
    fi

    rm -rf "$DEST"
    cp -R "$APP" "$DEST"
    _strata_remove_staged_app
    touch "$DEST"
    "$LSREGISTER" -f "$DEST"
    echo "Installed $DEST"
    if [[ " $* " == *" --open "* ]]; then open "$DEST"; fi
fi
