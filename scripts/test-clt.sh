#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CLT_FRAMEWORKS="/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
CLT_SWIFT_LIB="/Library/Developer/CommandLineTools/Library/Developer/usr/lib"

swift test \
  --package-path "$PROJECT_ROOT" \
  --configuration debug \
  -Xswiftc -F \
  -Xswiftc "$CLT_FRAMEWORKS" \
  -Xlinker "-F$CLT_FRAMEWORKS" \
  -Xlinker -rpath \
  -Xlinker "$CLT_FRAMEWORKS" \
  -Xlinker -rpath \
  -Xlinker "$CLT_SWIFT_LIB"
