#!/bin/zsh
# Renders the app window to a PNG without showing it, from a scan kept in build/.
# The first run scans the disk (about half a minute); later runs reuse that scan.
#   scripts/snapshot.sh build/shots/a.png [--mode bubbles|flow] [--theme abyss|frost|moss|dusk]
#                                         [--size 1280x800] [--focus Users/name/Library]
#                                         [--hover Library/Developer] [--tab cleanup]
#                                         [--state access|scanning] [--seconds 6]
#                                         [--move sub/folder|.. --at 0.3] [--switch flow --at 0.3]
#                                         [--menu disks|settings] [--extra-disks 2] [--demo on]
#                                         [--window on] [--scale 3]
set -euo pipefail
source "${0:A:h}/_env.sh"

[[ $# -ge 1 ]] || { echo "usage: scripts/snapshot.sh OUT.png [options]" >&2; exit 2; }
OUT="$1"; shift
swift build -c release --product Strata >/dev/null
mkdir -p "$ROOT/build" "${OUT:h}"
"$ROOT/.build/release/Strata" --snapshot "$OUT" --cache "$ROOT/build/dev-scan.strata" "$@"
# Run outside its bundle, the binary gets a preferences domain of its own ("Strata") that
# AppKit creates even though nothing is saved in it. Remove it again.
defaults delete Strata 2>/dev/null || true
rm -f "$HOME/Library/Preferences/Strata.plist"
