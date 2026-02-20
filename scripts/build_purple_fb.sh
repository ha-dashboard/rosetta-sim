#!/bin/bash
#
# build_purple_fb.sh — Compile the PurpleFBServer shim library
#
# This x86_64 dylib is injected into backboardd to provide the
# PurpleFBServer Mach service that PurpleDisplay::open() expects.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

SDK="/Applications/Xcode-8.3.3.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator10.3.sdk"

SRC="$PROJECT_ROOT/src/bridge/purple_fb_server.c"
OUT="$PROJECT_ROOT/src/bridge/purple_fb_server.dylib"

FORCE=0
if [[ "${1:-}" == "--force" ]]; then
    FORCE=1
fi

if [[ ! -d "$SDK" ]]; then
    echo "ERROR: iOS 10.3 simulator SDK not found at: $SDK"
    exit 1
fi

if [[ $FORCE -eq 0 ]] && [[ -f "$OUT" ]] && [[ "$OUT" -nt "$SRC" ]]; then
    if codesign -v "$OUT" 2>/dev/null; then
        echo "PurpleFBServer library is up-to-date: $OUT"
        exit 0
    fi
fi

echo "Compiling PurpleFBServer..."
echo "  Source: $SRC"
echo "  Output: $OUT"

clang -arch x86_64 -dynamiclib \
    -isysroot "$SDK" \
    -mios-simulator-version-min=10.0 \
    -F"$SDK/System/Library/Frameworks" \
    -F"$SDK/System/Library/PrivateFrameworks" \
    -framework Foundation \
    -framework GraphicsServices \
    -install_name @rpath/purple_fb_server.dylib \
    -o "$OUT" \
    "$SRC"

echo "  Compiled successfully."

echo "Ad-hoc code signing..."
codesign -s - -f "$OUT"

echo ""
file "$OUT"
echo ""
echo "PurpleFBServer library ready: $OUT"
