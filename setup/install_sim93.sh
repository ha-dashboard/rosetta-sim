#!/bin/bash
# =============================================================================
# iOS 9.3 Simulator Runtime - Manual Installation Script
# =============================================================================
#
# Xcode 8.3.3's built-in download works but the PackageKit installation
# service rejects the old client. This script downloads and installs the
# iOS 9.3 simulator runtime manually, bypassing PackageKit entirely.
#
# What it does:
#   1. Downloads the iOS 9.3 simulator DMG from Apple's CDN (~1.5GB)
#   2. Mounts the DMG and extracts the .pkg payload
#   3. Installs the runtime to ~/Library/Developer/CoreSimulator/Profiles/Runtimes/
#   4. Adds platformIdentifier (required for modern CoreSimulator discovery)
#   5. Overrides maxHostVersion (CoreSimulator hardcodes 10.14.99 for iOS 9.x)
#   6. Re-signs Swift libraries needed by simctl/SimulatorKit
#
# After running this script:
#   - `xcrun simctl list runtimes` will show iOS 9.3 as available
#   - `xcrun simctl create "iPhone 6s (9.3)" "iPhone 6s" com.apple.CoreSimulator.SimRuntime.iOS-9-3`
#   - `xcrun simctl boot <device-uuid>` to boot
#   - `open -a Simulator` to see the GUI
#
# =============================================================================

set -e

DMG_URL="https://devimages-cdn.apple.com/downloads/xcode/simulators/com.apple.pkg.iPhoneSimulatorSDK9_3-9.3.1.1460411551.dmg"
CACHE_DIR="$HOME/Library/Caches/com.apple.dt.Xcode/Downloads"
DMG_FILE="$CACHE_DIR/iPhoneSimulatorSDK9_3.dmg"
RUNTIME_DIR="$HOME/Library/Developer/CoreSimulator/Profiles/Runtimes/iOS_9.3.simruntime"
XCODE="/Applications/Xcode-8.3.3.app"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err() { echo -e "${RED}[-]${NC} $1"; exit 1; }

# =============================================================================
# Preflight
# =============================================================================

if [ -d "$RUNTIME_DIR" ]; then
    # Check if already recognized
    if xcrun simctl list runtimes 2>/dev/null | grep -q "iOS 9.3"; then
        log "iOS 9.3 simulator runtime already installed and recognized"
        xcrun simctl list runtimes 2>/dev/null | grep "9.3"
        exit 0
    fi
    warn "Runtime directory exists but not recognized. Will reinstall."
    rm -rf "$RUNTIME_DIR"
fi

# =============================================================================
# Step 1: Download DMG
# =============================================================================

mkdir -p "$CACHE_DIR"

if [ -f "$DMG_FILE" ]; then
    EXPECTED_SIZE=1526875288
    ACTUAL_SIZE=$(stat -f%z "$DMG_FILE" 2>/dev/null || echo 0)
    if [ "$ACTUAL_SIZE" -eq "$EXPECTED_SIZE" ]; then
        log "Using cached DMG ($DMG_FILE)"
    else
        warn "Cached DMG is incomplete ($ACTUAL_SIZE/$EXPECTED_SIZE bytes), re-downloading"
        rm -f "$DMG_FILE"
    fi
fi

if [ ! -f "$DMG_FILE" ]; then
    log "Downloading iOS 9.3 Simulator Runtime (~1.5GB)..."
    curl -L -o "$DMG_FILE" "$DMG_URL" --progress-bar
    log "Download complete"
fi

# =============================================================================
# Step 2: Mount and extract
# =============================================================================

MOUNT_POINT=$(mktemp -d /tmp/sim93_mount_XXXXXX)
EXTRACT_DIR=$(mktemp -d /tmp/sim93_extract_XXXXXX)

log "Mounting DMG..."
hdiutil attach "$DMG_FILE" -mountpoint "$MOUNT_POINT" -nobrowse -quiet

PKG_FILE=$(find "$MOUNT_POINT" -name "*.pkg" -maxdepth 1 | head -1)
if [ -z "$PKG_FILE" ]; then
    hdiutil detach "$MOUNT_POINT" -quiet 2>/dev/null
    err "No .pkg found in DMG"
fi

log "Expanding package..."
pkgutil --expand "$PKG_FILE" "$EXTRACT_DIR/expanded"

log "Extracting payload (this may take a moment)..."
mkdir -p "$EXTRACT_DIR/contents"
cd "$EXTRACT_DIR/contents"
cat "$EXTRACT_DIR/expanded/Payload" | gzip -d | cpio -id 2>/dev/null

log "Unmounting DMG..."
hdiutil detach "$MOUNT_POINT" -quiet 2>/dev/null

# =============================================================================
# Step 3: Install runtime
# =============================================================================

log "Installing runtime to $RUNTIME_DIR..."
mkdir -p "$(dirname "$RUNTIME_DIR")"
cp -R "$EXTRACT_DIR/contents/"* "$RUNTIME_DIR/" 2>/dev/null || \
    mv "$EXTRACT_DIR/contents" "$RUNTIME_DIR"

# Verify structure
if [ ! -f "$RUNTIME_DIR/Contents/Info.plist" ]; then
    # The contents might be one level deeper
    if [ -f "$RUNTIME_DIR/Contents/Contents/Info.plist" ]; then
        mv "$RUNTIME_DIR/Contents" "$RUNTIME_DIR/Contents_tmp"
        mv "$RUNTIME_DIR/Contents_tmp/Contents" "$RUNTIME_DIR/Contents"
        rm -rf "$RUNTIME_DIR/Contents_tmp"
    else
        err "Runtime extraction failed - Info.plist not found"
    fi
fi

# =============================================================================
# Step 4: Patch profile for modern CoreSimulator compatibility
# =============================================================================

PROFILE="$RUNTIME_DIR/Contents/Resources/profile.plist"

if [ -f "$PROFILE" ]; then
    # Add platformIdentifier (required for modern CoreSimulator discovery)
    if ! plutil -extract platformIdentifier raw "$PROFILE" 2>/dev/null; then
        plutil -replace platformIdentifier -string "com.apple.platform.iphonesimulator" "$PROFILE"
        log "Added platformIdentifier to profile"
    fi

    # Override maxHostVersion (CoreSimulator hardcodes 10.14.99 for iOS 9.x)
    plutil -replace maxHostVersion -string "99.99.99" "$PROFILE"
    log "Set maxHostVersion=99.99.99 in profile"
else
    warn "profile.plist not found - runtime may not be recognized"
fi

# =============================================================================
# Step 5: Re-sign Swift libraries for simctl/SimulatorKit
# =============================================================================

if [ -d "$XCODE" ]; then
    log "Re-signing Swift libraries for simulator tools..."
    for lib in "$XCODE/Contents/Frameworks"/libswift*.dylib; do
        [ -f "$lib" ] && codesign --force --sign - "$lib" 2>/dev/null
    done
    for bin in \
        "$XCODE/Contents/Developer/usr/bin/simctl" \
        "$XCODE/Contents/Developer/Library/PrivateFrameworks/SimulatorKit.framework/Versions/A/SimulatorKit" \
        "$XCODE/Contents/Developer/Library/PrivateFrameworks/CoreSimulator.framework/Versions/A/CoreSimulator"
    do
        [ -f "$bin" ] && codesign --force --sign - "$bin" 2>/dev/null
    done
    log "Swift libraries re-signed"
fi

# =============================================================================
# Step 6: Cleanup
# =============================================================================

rm -rf "$EXTRACT_DIR" "$MOUNT_POINT" 2>/dev/null

# =============================================================================
# Verify
# =============================================================================

echo ""
log "Installation complete!"
echo ""

if xcrun simctl list runtimes 2>/dev/null | grep -q "iOS 9.3"; then
    log "iOS 9.3 runtime recognized by CoreSimulator:"
    xcrun simctl list runtimes 2>/dev/null | grep "9.3"
    echo ""
    echo "To create a simulator device:"
    echo "  xcrun simctl create \"iPhone 6s (9.3)\" \"iPhone 6s\" com.apple.CoreSimulator.SimRuntime.iOS-9-3"
    echo ""
    echo "To boot and open:"
    echo "  xcrun simctl boot <device-uuid>"
    echo "  open -a Simulator"
else
    warn "iOS 9.3 runtime installed but not yet recognized by CoreSimulator"
    echo "Try: xcrun simctl list runtimes"
fi
