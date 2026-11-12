#!/bin/zsh
# Brings Resources/Localizable.xcstrings in line with the code: the compiler lists every
# localizable string of the app, new ones are added to the catalog and unused ones are
# marked stale. Translations are filled in by hand.
set -euo pipefail
source "${0:A:h}/_env.sh"

# A build folder of its own, built with the compiler writing a .stringsdata file next to
# every object file. It is kept, so later runs only recompile what changed.
SCRATCH="$ROOT/.build/strings"
swift build -c release --product Strata --scratch-path "$SCRATCH" -Xswiftc -emit-localized-strings >/dev/null
DATA=("${(@f)$(find "$SCRATCH" -path "*Strata-p.build*" -name "*.stringsdata")}")
[[ ${#DATA} -gt 0 ]] || { echo "no .stringsdata found" >&2; exit 1; }
xcrun xcstringstool sync "$ROOT/Resources/Localizable.xcstrings" --stringsdata "${DATA[@]}"
echo "Synced Resources/Localizable.xcstrings from ${#DATA} files"
