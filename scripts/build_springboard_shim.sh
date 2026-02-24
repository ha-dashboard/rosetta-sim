#!/bin/bash
set -euo pipefail

SDK="/Applications/Xcode-8.3.3.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator10.3.sdk"
SRC="src/bridge/springboard_shim.c"
OUT="src/bridge/springboard_shim.dylib"

echo "Building SpringBoard shim..."
clang -arch x86_64 -x objective-c -dynamiclib \
    -isysroot "$SDK" \
    -mios-simulator-version-min=10.0 \
    -F"$SDK/System/Library/PrivateFrameworks" \
    -framework Foundation \
    -framework BaseBoard \
    -framework GraphicsServices \
    -framework UIKit \
    -install_name @rpath/springboard_shim.dylib \
    -o "$OUT" "$SRC"

codesign -s - -f "$OUT"
echo "SpringBoard shim ready: $OUT"
file "$OUT"
