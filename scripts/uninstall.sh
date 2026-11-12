#!/bin/zsh
# Removes the installed app and everything it keeps on this Mac: the saved scan and its
# settings. The Full Disk Access entry in System Settings has to be removed by hand.
set -euo pipefail
source "${0:A:h}/_env.sh"

if pgrep -x Strata >/dev/null; then
    osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
    sleep 1
fi
for APP in "/Applications/Strata.app" "$HOME/Applications/Strata.app"; do
    if [[ -d "$APP" ]]; then
        "$LSREGISTER" -u "$APP" 2>/dev/null || true
        rm -rf "$APP"
        echo "Removed $APP"
    fi
done
rm -rf "$HOME/Library/Application Support/Strata"
defaults delete "$BUNDLE_ID" 2>/dev/null || true
rm -f "$HOME/Library/Preferences/$BUNDLE_ID.plist"
echo "Removed saved scans and settings"
