#!/bin/zsh
# Removes every build product of this project.
set -euo pipefail
ROOT="${0:A:h:h}"
cd "$ROOT"

rm -rf "$ROOT/.build" "$ROOT/build"
echo "Removed .build/ and build/"
