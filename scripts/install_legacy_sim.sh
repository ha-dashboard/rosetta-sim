#!/usr/bin/env bash
# =============================================================================
# Legacy iOS Simulator Runtime Installer
# =============================================================================
#
# Downloads and installs iOS simulator runtimes from Apple's CDN.
# Handles profile patching (maxHostVersion, platformIdentifier, headServices)
# for compatibility with macOS 26 and the RosettaSim bridge.
#
# Usage:
#   ./scripts/install_legacy_sim.sh <version>     # install specific version
#   ./scripts/install_legacy_sim.sh --list        # show available versions
#   ./scripts/install_legacy_sim.sh --status      # show installed runtimes
#   ./scripts/install_legacy_sim.sh --patch-all   # patch all installed runtimes
#
# Examples:
#   ./scripts/install_legacy_sim.sh 13.7
#   ./scripts/install_legacy_sim.sh 14.5
#
# =============================================================================

set -euo pipefail

RUNTIME_BASE="$HOME/Library/Developer/CoreSimulator/Profiles/Runtimes"
CACHE_DIR="$HOME/Library/Caches/com.apple.dt.Xcode/Downloads"
CDN_BASE="https://devimages-cdn.apple.com/downloads/xcode/simulators"
SDK_STUB_DIR="/Library/Developer/CoreSimulator/Profiles/Runtimes"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[-]${NC} $1"; exit 1; }
info() { echo -e "${CYAN}[i]${NC} $1"; }

# =============================================================================
# Known CDN URLs (verified HTTP 200)
# =============================================================================

# Map version to CDN filename (bash 3.2 compatible)
cdn_url_for() {
    case "$1" in
        9.3)  echo "com.apple.pkg.iPhoneSimulatorSDK9_3-9.3.1.1460411551.dmg" ;;
        10.0) echo "com.apple.pkg.iPhoneSimulatorSDK10_0-10.0.1.1474488730.dmg" ;;
        10.1) echo "com.apple.pkg.iPhoneSimulatorSDK10_1-10.1.1.1476902849.dmg" ;;
        10.2) echo "com.apple.pkg.iPhoneSimulatorSDK10_2-10.2.1.1484185528.dmg" ;;
        12.4) echo "com.apple.pkg.iPhoneSimulatorSDK12_4-12.4.1.1568665771.dmg" ;;
        13.7) echo "com.apple.pkg.iPhoneSimulatorSDK13_7-13.7.1.1600362474.dmg" ;;
        14.5) echo "com.apple.pkg.iPhoneSimulatorSDK14_5-14.5.1.1621461325.dmg" ;;
        15.5) echo "com.apple.pkg.iPhoneSimulatorSDK15_5-15.5.1.1653527639.dmg" ;;
        *)    echo "" ;;
    esac
}

ALL_VERSIONS="9.3 10.0 10.1 10.2 12.4 13.7 14.5 15.5"

# Does this version use PurpleFBServer? (needs headServices in profile)
# NOTE: iOS 13.7/14.5 QuartzCore DOES contain PurpleFBServer strings, but these
# runtimes crash during launchd bootstrap on macOS 26 (XPC/launchd incompatibility)
# before backboardd ever connects to PurpleFBServer. Only iOS 9.3-12.4 actually
# boot successfully on modern macOS. iOS 15.7+ works natively via SimRenderServer.
is_purplefb() {
    case "$1" in
        9.3|10.0|10.1|10.2|10.3|12.4) return 0 ;;
        *) return 1 ;;
    esac
}

# =============================================================================
# Commands
# =============================================================================

cmd_list() {
    echo "Available iOS simulator runtimes from Apple CDN:"
    echo ""
    for ver in $ALL_VERSIONS; do
        local installed=""
        local dir_name="iOS_${ver}.simruntime"
        if [ -d "$RUNTIME_BASE/$dir_name" ]; then
            installed=" (installed)"
        fi
        local proto="SimFramebuffer"
        is_purplefb "$ver" && proto="PurpleFBServer"
        printf "  ${CYAN}iOS %-5s${NC}  %-16s %s\n" "$ver" "$proto" "$installed"
    done
    echo ""
    echo "Not available from CDN (need old Xcode DMG):"
    echo "  iOS 7.x, 8.x, 10.3, 11.x"
    echo ""
    echo "Usage: $0 <version>  (e.g., $0 13.7)"
}

cmd_status() {
    echo "Installed iOS simulator runtimes:"
    echo ""
    xcrun simctl list runtimes 2>/dev/null | grep -i iOS | while read -r line; do
        echo "  $line"
    done
    echo ""
    echo "Runtime directories:"
    ls -1d "$RUNTIME_BASE"/iOS_*.simruntime 2>/dev/null | while read -r dir; do
        local name=$(basename "$dir")
        local profile="$dir/Contents/Resources/profile.plist"
        local has_head="no"
        local max_host="?"
        if [ -f "$profile" ]; then
            /usr/libexec/PlistBuddy -c "Print :headServices" "$profile" 2>/dev/null | grep -q PurpleFB && has_head="yes"
            max_host=$(/usr/libexec/PlistBuddy -c "Print :maxHostVersion" "$profile" 2>/dev/null || echo "unset")
        fi
        printf "  %-30s headServices=%-3s maxHost=%s\n" "$name" "$has_head" "$max_host"
    done
}

cmd_patch_all() {
    log "Patching all installed runtimes..."
    for dir in "$RUNTIME_BASE"/iOS_*.simruntime; do
        [ -d "$dir" ] || continue
        local name=$(basename "$dir")
        local profile="$dir/Contents/Resources/profile.plist"
        [ -f "$profile" ] || continue

        local changed=0

        # Ensure maxHostVersion
        local max=$(/usr/libexec/PlistBuddy -c "Print :maxHostVersion" "$profile" 2>/dev/null || echo "")
        if [ "$max" != "99.99.99" ]; then
            /usr/libexec/PlistBuddy -c "Delete :maxHostVersion" "$profile" 2>/dev/null || true
            /usr/libexec/PlistBuddy -c "Add :maxHostVersion string 99.99.99" "$profile"
            changed=1
        fi

        # Ensure platformIdentifier
        local plat=$(/usr/libexec/PlistBuddy -c "Print :platformIdentifier" "$profile" 2>/dev/null || echo "")
        if [ "$plat" != "com.apple.platform.iphonesimulator" ]; then
            /usr/libexec/PlistBuddy -c "Delete :platformIdentifier" "$profile" 2>/dev/null || true
            /usr/libexec/PlistBuddy -c "Add :platformIdentifier string com.apple.platform.iphonesimulator" "$profile"
            changed=1
        fi

        # Check if this runtime has PurpleFBServer in QuartzCore (needs headServices)
        local rtroot="$dir/Contents/Resources/RuntimeRoot"
        local needs_head=0
        if strings "$rtroot/System/Library/Frameworks/QuartzCore.framework/QuartzCore" 2>/dev/null | grep -q "PurpleFBServer"; then
            needs_head=1
        fi

        if [ "$needs_head" -eq 1 ]; then
            local has_head=$(/usr/libexec/PlistBuddy -c "Print :headServices" "$profile" 2>/dev/null | grep -c PurpleFB || echo 0)
            if [ "$has_head" -eq 0 ]; then
                /usr/libexec/PlistBuddy -c "Delete :headServices" "$profile" 2>/dev/null || true
                /usr/libexec/PlistBuddy \
                    -c "Add :headServices array" \
                    -c "Add :headServices:0 string PurpleFBServer" \
                    -c "Add :headServices:1 string PurpleFBTVOutServer" \
                    -c "Add :headServices:2 string IndigoHIDRegistrationPort" \
                    "$profile"
                changed=1
            fi
        fi

        if [ "$changed" -eq 1 ]; then
            log "Patched: $name"
        else
            info "OK: $name (no changes needed)"
        fi
    done
}

# =============================================================================
# Install a specific version
# =============================================================================

install_version() {
    local VERSION="$1"
    local DMG_NAME
    DMG_NAME=$(cdn_url_for "$VERSION")

    if [ -z "$DMG_NAME" ]; then
        err "Unknown version: $VERSION. Run '$0 --list' to see available versions."
    fi

    local DMG_URL="$CDN_BASE/$DMG_NAME"
    local DMG_FILE="$CACHE_DIR/iPhoneSimulatorSDK${VERSION//./_}.dmg"
    local RUNTIME_DIR="$RUNTIME_BASE/iOS_${VERSION}.simruntime"
    local MAJOR_MINOR="${VERSION%.*}"

    # Check if already installed
    if [ -d "$RUNTIME_DIR" ]; then
        if xcrun simctl list runtimes 2>/dev/null | grep -q "iOS $VERSION"; then
            log "iOS $VERSION already installed and recognized"
            xcrun simctl list runtimes 2>/dev/null | grep "$VERSION"
            return 0
        fi
        warn "Runtime directory exists but not recognized. Reinstalling."
        rm -rf "$RUNTIME_DIR"
    fi

    # Download
    mkdir -p "$CACHE_DIR"
    if [ -f "$DMG_FILE" ]; then
        log "Using cached DMG: $DMG_FILE"
    else
        log "Downloading iOS $VERSION Simulator Runtime..."
        curl -L -o "$DMG_FILE" "$DMG_URL" --progress-bar
        log "Download complete"
    fi

    # Mount and extract
    local MOUNT_POINT=$(mktemp -d /tmp/sim_mount_XXXXXX)
    local EXTRACT_DIR=$(mktemp -d /tmp/sim_extract_XXXXXX)

    log "Mounting DMG..."
    hdiutil attach "$DMG_FILE" -mountpoint "$MOUNT_POINT" -nobrowse -quiet

    local PKG_FILE=$(find "$MOUNT_POINT" -name "*.pkg" -maxdepth 1 | head -1)
    if [ -z "$PKG_FILE" ]; then
        hdiutil detach "$MOUNT_POINT" -quiet 2>/dev/null
        err "No .pkg found in DMG"
    fi

    log "Expanding package..."
    pkgutil --expand "$PKG_FILE" "$EXTRACT_DIR/expanded"

    log "Extracting payload (this may take a moment)..."
    mkdir -p "$EXTRACT_DIR/contents"
    (cd "$EXTRACT_DIR/contents" && cat "$EXTRACT_DIR/expanded/Payload" | gzip -d | cpio -id 2>/dev/null)

    log "Unmounting DMG..."
    hdiutil detach "$MOUNT_POINT" -quiet 2>/dev/null

    # Install
    log "Installing to $RUNTIME_DIR..."
    mkdir -p "$RUNTIME_BASE"

    # Find the .simruntime bundle in extracted contents
    local SIM_BUNDLE=$(find "$EXTRACT_DIR/contents" -name "*.simruntime" -maxdepth 3 | head -1)
    if [ -n "$SIM_BUNDLE" ]; then
        mv "$SIM_BUNDLE" "$RUNTIME_DIR"
    else
        # Payload might be the runtime itself
        mv "$EXTRACT_DIR/contents" "$RUNTIME_DIR"
    fi

    # Fix nested Contents/Contents
    if [ ! -f "$RUNTIME_DIR/Contents/Info.plist" ] && [ -f "$RUNTIME_DIR/Contents/Contents/Info.plist" ]; then
        mv "$RUNTIME_DIR/Contents" "$RUNTIME_DIR/Contents_tmp"
        mv "$RUNTIME_DIR/Contents_tmp/Contents" "$RUNTIME_DIR/Contents"
        rm -rf "$RUNTIME_DIR/Contents_tmp"
    fi

    [ -f "$RUNTIME_DIR/Contents/Info.plist" ] || err "Extraction failed — Info.plist not found"

    # Patch profile
    log "Patching profile for macOS 26 compatibility..."
    local PROFILE="$RUNTIME_DIR/Contents/Resources/profile.plist"
    if [ -f "$PROFILE" ]; then
        # maxHostVersion
        /usr/libexec/PlistBuddy -c "Delete :maxHostVersion" "$PROFILE" 2>/dev/null || true
        /usr/libexec/PlistBuddy -c "Add :maxHostVersion string 99.99.99" "$PROFILE"

        # platformIdentifier
        /usr/libexec/PlistBuddy -c "Delete :platformIdentifier" "$PROFILE" 2>/dev/null || true
        /usr/libexec/PlistBuddy -c "Add :platformIdentifier string com.apple.platform.iphonesimulator" "$PROFILE"

        # headServices for PurpleFB runtimes
        if is_purplefb "$VERSION"; then
            /usr/libexec/PlistBuddy -c "Delete :headServices" "$PROFILE" 2>/dev/null || true
            /usr/libexec/PlistBuddy \
                -c "Add :headServices array" \
                -c "Add :headServices:0 string PurpleFBServer" \
                -c "Add :headServices:1 string PurpleFBTVOutServer" \
                -c "Add :headServices:2 string IndigoHIDRegistrationPort" \
                "$PROFILE"
            log "Added headServices (PurpleFBServer) for legacy display bridge"
        fi
    fi

    # Create SDK stub if needed
    local SDK_MAJOR=$(echo "$VERSION" | cut -d. -f1)
    local SDK_STUB="$SDK_STUB_DIR/iPhoneSimulator${VERSION}.sdk"
    if [ ! -d "$SDK_STUB" ] && [ -w "$(dirname "$SDK_STUB_DIR")" ]; then
        warn "SDK stub not found at $SDK_STUB"
        info "Create with: sudo mkdir -p '$SDK_STUB' && sudo tee '$SDK_STUB/SDKSettings.plist' <<< '<plist><dict><key>DefaultProperties</key><dict/></dict></plist>'"
    fi

    # Re-sign Swift libraries if Xcode 8.3.3 is present (for iOS 9.x/10.x)
    if [[ "$SDK_MAJOR" -le 10 ]] && [ -d "/Applications/Xcode-8.3.3.app" ]; then
        log "Re-signing Swift libraries..."
        for lib in "/Applications/Xcode-8.3.3.app/Contents/Frameworks"/libswift*.dylib; do
            [ -f "$lib" ] && codesign --force --sign - "$lib" 2>/dev/null
        done
    fi

    # Cleanup
    rm -rf "$EXTRACT_DIR" "$MOUNT_POINT" 2>/dev/null

    # Verify
    echo ""
    log "Installation complete!"
    if xcrun simctl list runtimes 2>/dev/null | grep -q "iOS $VERSION"; then
        log "iOS $VERSION recognized:"
        xcrun simctl list runtimes 2>/dev/null | grep "$VERSION"
    else
        warn "iOS $VERSION installed but not yet recognized. Try restarting CoreSimulator."
    fi
}

# =============================================================================
# Main
# =============================================================================

case "${1:-}" in
    --list|-l)
        cmd_list
        ;;
    --status|-s)
        cmd_status
        ;;
    --patch-all|-p)
        cmd_patch_all
        ;;
    --help|-h|"")
        echo "Usage: $0 <version|--list|--status|--patch-all>"
        echo ""
        echo "Commands:"
        echo "  <version>    Install a specific iOS runtime (e.g., 13.7)"
        echo "  --list       Show available versions from Apple CDN"
        echo "  --status     Show installed runtimes and their patch status"
        echo "  --patch-all  Patch all installed runtimes for macOS 26 compatibility"
        echo ""
        echo "The script automatically:"
        echo "  - Downloads from Apple's CDN"
        echo "  - Patches maxHostVersion for macOS 26"
        echo "  - Adds headServices for PurpleFBServer runtimes (iOS 9-12)"
        echo "  - Sets platformIdentifier for CoreSimulator discovery"
        ;;
    *)
        install_version "$1"
        ;;
esac
