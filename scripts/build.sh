#!/bin/zsh
# Builds everything in release mode into .build/.
set -euo pipefail
source "${0:A:h}/_env.sh"

swift build -c release "$@"
