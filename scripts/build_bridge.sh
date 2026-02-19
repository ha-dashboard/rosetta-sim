#!/bin/bash
#
# build_bridge.sh - Compile and ad-hoc sign the RosettaSim bridge library
#
# The bridge library is an x86_64 dylib compiled against the iOS 10.3
# simulator SDK. It is injected into the simulated process via
# DYLD_INSERT_LIBRARIES to interpose BackBoardServices, GraphicsServices,
# and other functions that require backboardd or CARenderServer.
#
# Usage:
#   ./scripts/build_bridge.sh
#   ./scripts/build_bridge.sh --force   # rebuild even if up-to-date
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# SDK path
SDK="/Applications/Xcode-8.3.3.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator10.3.sdk"

# Source and output
BRIDGE_SRC="$PROJECT_ROOT/src/bridge/rosettasim_bridge.m"
BRIDGE_OUT="$PROJECT_ROOT/src/bridge/rosettasim_bridge.dylib"

FORCE=0
if [[ "${1:-}" == "--force" ]]; then
    FORCE=1
fi

# --- Preflight checks ---

if [[ ! -d "$SDK" ]]; then
    echo "ERROR: iOS 10.3 simulator SDK not found at:"
    echo "  $SDK"
    echo ""
    echo "Install Xcode 8.3.3 to /Applications/Xcode-8.3.3.app"
    exit 1
fi

if [[ ! -f "$BRIDGE_SRC" ]]; then
    echo "ERROR: Bridge source not found at:"
    echo "  $BRIDGE_SRC"
    exit 1
fi

# --- Check if rebuild is needed ---

if [[ $FORCE -eq 0 ]] && [[ -f "$BRIDGE_OUT" ]] && [[ "$BRIDGE_OUT" -nt "$BRIDGE_SRC" ]]; then
    # Verify it's signed
    if codesign -v "$BRIDGE_OUT" 2>/dev/null; then
        echo "Bridge library is up-to-date and signed: $BRIDGE_OUT"
        exit 0
    fi
    echo "Bridge library exists but signature is invalid. Rebuilding..."
fi

# --- Compile ---

echo "Compiling bridge library..."
echo "  Source: $BRIDGE_SRC"
echo "  Output: $BRIDGE_OUT"
echo "  SDK:    $SDK"

clang -arch x86_64 -dynamiclib \
    -isysroot "$SDK" \
    -mios-simulator-version-min=10.0 \
    -F"$SDK/System/Library/Frameworks" \
    -F"$SDK/System/Library/PrivateFrameworks" \
    -framework CoreFoundation \
    -framework Foundation \
    -framework BackBoardServices \
    -framework GraphicsServices \
    -framework QuartzCore \
    -framework UIKit \
    -install_name @rpath/rosettasim_bridge.dylib \
    -o "$BRIDGE_OUT" \
    "$BRIDGE_SRC"

echo "  Compiled successfully."

# --- Ad-hoc code sign ---

echo "Ad-hoc code signing..."
codesign -s - -f "$BRIDGE_OUT"

# --- Verify ---

echo ""
echo "Verification:"
file "$BRIDGE_OUT"
codesign -d -v "$BRIDGE_OUT" 2>&1 | head -4

echo ""
echo "Bridge library ready: $BRIDGE_OUT"
