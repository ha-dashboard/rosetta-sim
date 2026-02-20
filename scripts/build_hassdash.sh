#!/bin/bash
#
# build_hassdash.sh - Compile hass-dashboard for x86_64 simulator use with RosettaSim
#
# Builds the HADashboard app as an x86_64 simulator binary using modern Xcode
# toolchain. At runtime, DYLD_ROOT_PATH redirects framework loading to the
# iOS 10.3 SDK, so the modern SDK is only used at compile time.
#
# Usage:
#   ./scripts/build_hassdash.sh                        # build from default location
#   ./scripts/build_hassdash.sh /path/to/hass-dashboard # build from custom location
#
# After building, run with:
#   ./scripts/run_sim.sh /tmp/rosettasim_hassdash/HA\ Dashboard.app
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ================================================================
# Configuration
# ================================================================

HASSDASH_DIR="${1:-$HOME/Projects/hass-dashboard}"
BUILD_DIR="/tmp/rosettasim_hassdash"
SCHEME="HADashboard"

# ================================================================
# Preflight
# ================================================================

if [[ ! -d "$HASSDASH_DIR/HADashboard.xcodeproj" ]]; then
    echo "ERROR: HADashboard.xcodeproj not found in: $HASSDASH_DIR"
    echo "Usage: $0 [/path/to/hass-dashboard]"
    exit 1
fi

echo "========================================"
echo "Building hass-dashboard for RosettaSim"
echo "========================================"
echo "Source:  $HASSDASH_DIR"
echo "Output:  $BUILD_DIR"
echo "Arch:    x86_64 (for Rosetta 2)"
echo "========================================"
echo ""

# ================================================================
# Clean previous build
# ================================================================

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# ================================================================
# Build with xcodebuild
# ================================================================

echo "Compiling with modern Xcode (x86_64 simulator target)..."
echo ""

xcodebuild \
    -project "$HASSDASH_DIR/HADashboard.xcodeproj" \
    -scheme "$SCHEME" \
    -sdk iphonesimulator \
    -configuration Debug \
    ARCHS=x86_64 \
    ONLY_ACTIVE_ARCH=NO \
    VALID_ARCHS=x86_64 \
    EXCLUDED_ARCHS="" \
    IPHONEOS_DEPLOYMENT_TARGET=10.0 \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGN_IDENTITY="" \
    ENABLE_BITCODE=NO \
    CONFIGURATION_BUILD_DIR="$BUILD_DIR" \
    COMPILER_INDEX_STORE_ENABLE=NO \
    GCC_TREAT_WARNINGS_AS_ERRORS=NO \
    2>&1 | tail -20

BUILD_EXIT=${PIPESTATUS[0]}

if [[ $BUILD_EXIT -ne 0 ]]; then
    echo ""
    echo "ERROR: xcodebuild failed (exit $BUILD_EXIT)"
    echo "Try running with full output:"
    echo "  xcodebuild -project $HASSDASH_DIR/HADashboard.xcodeproj -scheme $SCHEME -sdk iphonesimulator ARCHS=x86_64 IPHONEOS_DEPLOYMENT_TARGET=10.0 CODE_SIGNING_ALLOWED=NO build"
    exit 1
fi

# ================================================================
# Find the .app bundle
# ================================================================

APP_BUNDLE="$(find "$BUILD_DIR" -name "*.app" -type d | head -1)"

if [[ -z "$APP_BUNDLE" ]]; then
    echo "ERROR: No .app bundle found in $BUILD_DIR"
    exit 1
fi

echo ""
echo "Built: $APP_BUNDLE"

# ================================================================
# Verify architecture
# ================================================================

EXEC_NAME="$(plutil -p "$APP_BUNDLE/Info.plist" 2>/dev/null | grep CFBundleExecutable | head -1 | sed 's/.*=> "\(.*\)"/\1/')"
if [[ -z "$EXEC_NAME" ]]; then
    EXEC_NAME="$(basename "$APP_BUNDLE" .app)"
fi

EXEC_PATH="$APP_BUNDLE/$EXEC_NAME"

if [[ -f "$EXEC_PATH" ]]; then
    ARCH_INFO="$(file "$EXEC_PATH")"
    echo "Executable: $EXEC_PATH"
    echo "Architecture: $ARCH_INFO"

    if [[ "$ARCH_INFO" != *"x86_64"* ]]; then
        echo ""
        echo "WARNING: Binary is not x86_64! RosettaSim requires x86_64."
        exit 1
    fi
fi

# ================================================================
# Ad-hoc sign everything (required for Rosetta 2)
# ================================================================

echo ""
echo "Ad-hoc signing..."

# Sign frameworks and dylibs inside the bundle
find "$APP_BUNDLE" \( -name "*.dylib" -o -name "*.framework" \) -print0 2>/dev/null | \
while IFS= read -r -d '' item; do
    codesign -s - --force "$item" 2>/dev/null || true
done

# Sign the main executable
codesign -s - --force "$EXEC_PATH" 2>/dev/null || true

echo "Done."

# ================================================================
# Summary
# ================================================================

echo ""
echo "========================================"
echo "Build complete!"
echo "========================================"
echo ""
echo "To run with RosettaSim:"
echo "  $PROJECT_ROOT/scripts/run_sim.sh '$APP_BUNDLE'"
echo ""
echo "Or launch the host app and use it to load the binary."
echo ""
