#!/bin/zsh
# Builds the release for GitHub: signed with a Developer ID, notarized by Apple and stapled.
# Writes build/release/Strata-VERSION.zip and its .sha256, and prints the zip's path last.
#
#   scripts/release.sh
#
# Needs a notarytool keychain profile (made with `xcrun notarytool store-credentials`), named
# by STRATA_NOTARY_PROFILE in local.env or the environment. STRATA_IDENTITY picks the
# Developer ID certificate when the keychain holds several.
set -euo pipefail
source "${0:A:h}/_env.sh"
[[ -f "$ROOT/local.env" ]] && source "$ROOT/local.env"

[[ -n "${STRATA_NOTARY_PROFILE:-}" ]] || { echo "Set STRATA_NOTARY_PROFILE in local.env." >&2; exit 1; }
[[ "$(security find-identity -v -p codesigning)" == *"Developer ID Application"* ]] \
    || { echo "No Developer ID Application certificate in the keychain." >&2; exit 1; }

STRATA_RELEASE=1 "$ROOT/scripts/build-app.sh" >/dev/null
APP="$STAGED_APP"

codesign --verify --strict --verbose=2 "$APP"
# Read whole before matching: grep -q stopping early would break the pipe under pipefail.
SIGNATURE="$(codesign -dvv "$APP" 2>&1)"
[[ "$SIGNATURE" == *"Authority=Developer ID Application"* && "$SIGNATURE" != *"Timestamp=none"* ]] \
    || { echo "The app is not signed with a Developer ID and a secure timestamp." >&2; exit 1; }
if [[ "$(codesign -d --entitlements - "$APP" 2>/dev/null)" == *get-task-allow* ]]; then
    echo "The app carries get-task-allow; notarization would refuse it." >&2
    exit 1
fi
# Nothing of the machine that built it: no home folder paths or user name in any file.
if grep -rlaF -e "$HOME" -e "/Users/$USER/" "$APP" >/dev/null 2>&1; then
    echo "The app holds paths of this Mac:" >&2
    grep -rlaF -e "$HOME" -e "/Users/$USER/" "$APP" >&2
    exit 1
fi

# Notarize a zip of the app, staple the ticket to the app, then package the stapled app.
SUBMISSION="$TMPDIR/Strata-notarize.zip"
ditto -c -k --keepParent "$APP" "$SUBMISSION"
xcrun notarytool submit "$SUBMISSION" --keychain-profile "$STRATA_NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
OUT="$ROOT/build/release"
mkdir -p "$OUT"
ZIP="$OUT/Strata-$VERSION.zip"
rm -f "$ZIP" "$ZIP.sha256"
ditto -c -k --keepParent "$APP" "$ZIP"
(cd "$OUT" && shasum -a 256 "${ZIP:t}" > "${ZIP:t}.sha256")
_strata_remove_staged_app
cat "$ZIP.sha256"
echo "$ZIP"
