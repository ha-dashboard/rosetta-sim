#!/bin/bash
#
# build_bootstrap_fix.sh - Compile and ad-hoc sign bootstrap_fix.dylib
#
# bootstrap_fix.dylib is injected first via DYLD_INSERT_LIBRARIES and must stay
# in sync with src/launcher/bootstrap_fix.c for assertiond/XPC experiments.
#
# Usage:
#   ./scripts/build_bootstrap_fix.sh
#   ./scripts/build_bootstrap_fix.sh --force   # rebuild even if up-to-date
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

SDK="/Applications/Xcode-8.3.3.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator10.3.sdk"
SRC="$PROJECT_ROOT/src/launcher/bootstrap_fix.c"
OUT="$PROJECT_ROOT/src/bridge/bootstrap_fix.dylib"

FORCE=0
if [[ "${1:-}" == "--force" ]]; then
    FORCE=1
fi

if [[ ! -d "$SDK" ]]; then
    echo "ERROR: iOS 10.3 simulator SDK not found at:"
    echo "  $SDK"
    exit 1
fi

if [[ ! -f "$SRC" ]]; then
    echo "ERROR: bootstrap_fix source not found:"
    echo "  $SRC"
    exit 1
fi

NEEDS_REBUILD=0
REBUILD_REASON=""

if [[ $FORCE -eq 1 ]]; then
    NEEDS_REBUILD=1
    REBUILD_REASON="--force"
elif [[ ! -f "$OUT" ]]; then
    NEEDS_REBUILD=1
    REBUILD_REASON="output missing"
elif [[ "$SRC" -nt "$OUT" ]]; then
    NEEDS_REBUILD=1
    REBUILD_REASON="source newer than output"
elif ! codesign -v "$OUT" 2>/dev/null; then
    NEEDS_REBUILD=1
    REBUILD_REASON="invalid signature"
fi

if [[ $NEEDS_REBUILD -eq 0 ]]; then
    echo "bootstrap_fix is up-to-date and signed: $OUT"
    exit 0
fi

echo "Building bootstrap_fix.dylib ($REBUILD_REASON)..."
echo "  Source: $SRC"
echo "  Output: $OUT"
echo "  SDK:    $SDK"

clang -arch x86_64 -x objective-c -dynamiclib \
    -isysroot "$SDK" \
    -mios-simulator-version-min=10.0 \
    -F"$SDK/System/Library/Frameworks" \
    -F"$SDK/System/Library/PrivateFrameworks" \
    -framework Foundation \
    -framework CoreFoundation \
    -framework QuartzCore \
    -framework GraphicsServices \
    -framework BackBoardServices \
    -install_name @rpath/bootstrap_fix.dylib \
    -o "$OUT" \
    "$SRC"

codesign -s - -f "$OUT"
echo "bootstrap_fix ready: $OUT"
file "$OUT"
