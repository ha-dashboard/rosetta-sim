#!/bin/bash
#
# build_hid_manager.sh — Compile the RosettaSimHIDManager bundle
#
# This x86_64 .bundle is loaded by SimulatorClient.framework via the
# SIMULATOR_HID_SYSTEM_MANAGER environment variable. It provides a
# class conforming to SimulatorClientHIDSystemManager protocol so that
# IndigoHIDSystemSpawnLoopback() succeeds.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

SDK="/Applications/Xcode-8.3.3.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator10.3.sdk"

SRC="$PROJECT_ROOT/src/bridge/rosettasim_hid_manager.m"
OUT="$PROJECT_ROOT/src/bridge/RosettaSimHIDManager.bundle"

FORCE=0
if [[ "${1:-}" == "--force" ]]; then
    FORCE=1
fi

if [[ ! -d "$SDK" ]]; then
    echo "ERROR: iOS 10.3 simulator SDK not found at: $SDK"
    exit 1
fi

if [[ ! -f "$SRC" ]]; then
    echo "ERROR: Source file not found: $SRC"
    exit 1
fi

BINARY="$OUT/Contents/MacOS/RosettaSimHIDManager"

if [[ $FORCE -eq 0 ]] && [[ -f "$BINARY" ]] && [[ "$BINARY" -nt "$SRC" ]]; then
    if codesign -v "$BINARY" 2>/dev/null; then
        echo "RosettaSimHIDManager bundle is up-to-date: $OUT"
        exit 0
    fi
fi

echo "Compiling RosettaSimHIDManager..."
echo "  Source: $SRC"
echo "  Output: $OUT"

# Create bundle directory structure
mkdir -p "$OUT/Contents/MacOS"

# Compile as a Mach-O bundle (loadable with NSBundle)
# -bundle produces a .bundle Mach-O type (MH_BUNDLE)
# Link against Foundation for NSObject/NSArray/etc.
# Link against IOKit for IOHIDEventSystem APIs
clang -arch x86_64 -bundle \
    -isysroot "$SDK" \
    -mios-simulator-version-min=10.0 \
    -F"$SDK/System/Library/Frameworks" \
    -F"$SDK/System/Library/PrivateFrameworks" \
    -framework Foundation \
    -framework IOKit \
    -fno-objc-arc \
    -o "$BINARY" \
    "$SRC"

echo "  Compiled successfully."

# Create Info.plist with NSPrincipalClass
cat > "$OUT/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>RosettaSimHIDManager</string>
    <key>CFBundleIdentifier</key>
    <string>com.rosettasim.hidmanager</string>
    <key>CFBundleExecutable</key>
    <string>RosettaSimHIDManager</string>
    <key>CFBundlePackageType</key>
    <string>BNDL</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>NSPrincipalClass</key>
    <string>RosettaSimHIDManager</string>
    <key>MinimumOSVersion</key>
    <string>10.0</string>
    <key>CFBundleSupportedPlatforms</key>
    <array>
        <string>iPhoneSimulator</string>
    </array>
</dict>
</plist>
PLIST

echo "Ad-hoc code signing..."
codesign -s - -f "$OUT"

echo ""
file "$BINARY"
echo ""
echo "RosettaSimHIDManager bundle ready: $OUT"
