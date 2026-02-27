#!/bin/bash
#
# setup.sh — One-time setup for RosettaSim legacy iOS simulator
#
# Checks prerequisites, builds tools, creates re-signed Simulator.app,
# and creates default legacy simulator devices.
#
# Usage:
#   ./scripts/setup.sh
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC_DIR="$PROJECT_ROOT/src"
BUILD_DIR="$SRC_DIR/build"

SIMULATOR_SRC="/Applications/Xcode.app/Contents/Developer/Applications/Simulator.app"
SIMULATOR_DST="/tmp/Simulator_nolv.app"

# Runtime identifiers
RUNTIME_93="com.apple.CoreSimulator.SimRuntime.iOS-9-3"
RUNTIME_103="com.apple.CoreSimulator.SimRuntime.iOS-10-3"

echo "=== RosettaSim Setup ==="
echo ""

# --- Step 1: Check prerequisites ---
echo "Checking prerequisites..."

# Xcode
if [[ ! -d "/Applications/Xcode.app" ]]; then
    echo "ERROR: Xcode.app not found at /Applications/Xcode.app"
    exit 1
fi
echo "  Xcode: OK"

# Simulator.app
if [[ ! -f "$SIMULATOR_SRC/Contents/MacOS/Simulator" ]]; then
    echo "ERROR: Simulator.app not found in Xcode"
    exit 1
fi
echo "  Simulator.app: OK"

# iOS 9.3 runtime
HAS_93=0
HAS_103=0
if xcrun simctl list runtimes 2>/dev/null | grep -q "iOS 9.3"; then
    HAS_93=1
    echo "  iOS 9.3 runtime: OK"
else
    echo "  iOS 9.3 runtime: NOT INSTALLED"
fi

if xcrun simctl list runtimes 2>/dev/null | grep -q "iOS 10.3"; then
    HAS_103=1
    echo "  iOS 10.3 runtime: OK"
else
    echo "  iOS 10.3 runtime: NOT INSTALLED"
fi

if [[ "$HAS_93" -eq 0 ]] && [[ "$HAS_103" -eq 0 ]]; then
    echo ""
    echo "ERROR: No legacy iOS runtimes found."
    echo "Install iOS 9.3 or 10.3 simulator runtime first."
    echo "See: https://developer.apple.com/documentation/xcode/installing-additional-simulator-runtimes"
    exit 1
fi

echo ""

# --- Step 2: Build tools ---
echo "Building display bridge tools..."
cd "$SRC_DIR"
make clean
make
echo ""

# --- Step 3: Create re-signed Simulator.app ---
echo "Creating re-signed Simulator.app..."

if [[ -d "$SIMULATOR_DST" ]]; then
    echo "  Removing existing $SIMULATOR_DST"
    rm -rf "$SIMULATOR_DST"
fi

# Copy the full .app bundle (needed for NIBs, frameworks, Info.plist)
cp -R "$SIMULATOR_SRC" "$SIMULATOR_DST"

# Re-sign with ad-hoc signature, removing library-validation
# This allows DYLD_INSERT_LIBRARIES to work
codesign --force --sign - --options=0 "$SIMULATOR_DST/Contents/MacOS/Simulator" 2>/dev/null
echo "  Created: $SIMULATOR_DST"
echo "  Re-signed: library-validation removed"
echo ""

# --- Step 3b: Check SDK stub for legacy runtimes ---
SDK_STUB_DIR="/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs"

check_sdk_stub() {
    local version="$1"
    local sdk_name="iPhoneSimulator${version}.sdk"
    local sdk_path="$SDK_STUB_DIR/$sdk_name"

    if [[ -d "$sdk_path" ]]; then
        echo "  SDK stub $sdk_name: OK"
        return
    fi

    echo "  SDK stub $sdk_name: MISSING"
    echo ""
    echo "  The iOS $version SDK stub is needed for CoreSimulator to detect the platform."
    echo "  Create it with:"
    echo ""
    echo "    sudo mkdir -p '$sdk_path'"
    echo "    sudo tee '$sdk_path/SDKSettings.plist' > /dev/null << 'SDKEOF'"
    cat << SDKEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Version</key><string>${version}</string>
    <key>CanonicalName</key><string>iphonesimulator${version}</string>
    <key>DisplayName</key><string>Simulator - iOS ${version}</string>
    <key>MinimalDisplayName</key><string>Simulator - ${version}</string>
    <key>MaximumDeploymentTarget</key><string>${version}.99</string>
    <key>DefaultDeploymentTarget</key><string>${version}</string>
    <key>DefaultProperties</key><dict>
        <key>PLATFORM_NAME</key><string>iphonesimulator</string>
        <key>LLVM_TARGET_TRIPLE_SUFFIX</key><string>-simulator</string>
    </dict>
    <key>SupportedTargets</key><dict>
        <key>iphonesimulator</key><dict>
            <key>Archs</key><array><string>x86_64</string><string>i386</string></array>
        </dict>
    </dict>
</dict>
</plist>
SDKEOF
    echo "SDKEOF"
    echo ""
}

echo "Checking SDK stubs..."
[[ "$HAS_93" -eq 1 ]] && check_sdk_stub "9.3"
[[ "$HAS_103" -eq 1 ]] && check_sdk_stub "10.3"
echo ""

# --- Step 4: Create default devices ---
echo "Creating legacy simulator devices..."

create_device() {
    local name="$1"
    local device_type="$2"
    local runtime="$3"

    # Check if device already exists
    if xcrun simctl list devices 2>/dev/null | grep -q "$name"; then
        local udid
        udid=$(xcrun simctl list devices 2>/dev/null | grep "$name" | grep -v unavailable | head -1 | sed 's/.*(\([A-F0-9-]*\)).*/\1/')
        echo "  $name: already exists ($udid)"
        return
    fi

    # Check if runtime is available
    if ! xcrun simctl list runtimes 2>/dev/null | grep -q "$runtime"; then
        echo "  $name: SKIPPED (runtime not installed)"
        return
    fi

    local udid
    udid=$(xcrun simctl create "$name" "$device_type" "$runtime" 2>/dev/null) || {
        echo "  $name: FAILED to create"
        return
    }
    echo "  $name: created ($udid)"
}

if [[ "$HAS_93" -eq 1 ]]; then
    create_device "iPhone 6s" \
        "com.apple.CoreSimulator.SimDeviceType.iPhone-6s" \
        "$RUNTIME_93"
    create_device "iPhone 6s Plus" \
        "com.apple.CoreSimulator.SimDeviceType.iPhone-6s-Plus" \
        "$RUNTIME_93"
    create_device "iPad Air 2" \
        "com.apple.CoreSimulator.SimDeviceType.iPad-Air-2" \
        "$RUNTIME_93"
    create_device "iPad Pro" \
        "com.apple.CoreSimulator.SimDeviceType.iPad-Pro" \
        "$RUNTIME_93"
fi

if [[ "$HAS_103" -eq 1 ]]; then
    create_device "iPhone 6s (10.3)" \
        "com.apple.CoreSimulator.SimDeviceType.iPhone-6s" \
        "$RUNTIME_103"
fi

echo ""

# --- Step 5: Summary ---
echo "=== Setup Complete ==="
echo ""
echo "Tools built:"
echo "  $BUILD_DIR/rosettasim_daemon"
echo "  $BUILD_DIR/sim_display_inject.dylib"
echo "  $BUILD_DIR/purple_fb_bridge"
echo "  $BUILD_DIR/sim_viewer"
echo ""
echo "Re-signed Simulator:"
echo "  $SIMULATOR_DST"
echo ""
echo "Available legacy devices:"
xcrun simctl list devices 2>&1 | grep -E '9\.3|10\.3' | grep -v unavailable | sed 's/^/  /'
echo ""
echo "To run:"
echo "  ./scripts/start_rosettasim.sh"
echo ""
