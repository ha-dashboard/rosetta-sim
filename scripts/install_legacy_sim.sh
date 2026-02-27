#!/usr/bin/env bash
# =============================================================================
# Legacy iOS Simulator Runtime Installer
# =============================================================================
#
# Downloads and installs iOS simulator runtimes from Apple's CDN or old Xcode
# DMGs/XIPs. Handles profile patching (maxHostVersion, platformIdentifier,
# headServices) for compatibility with macOS 26 and the RosettaSim bridge.
#
# Usage:
#   ./scripts/install_legacy_sim.sh <version>        # install specific version
#   ./scripts/install_legacy_sim.sh --list            # show available versions
#   ./scripts/install_legacy_sim.sh --status          # show installed runtimes
#   ./scripts/install_legacy_sim.sh --patch-all       # patch all installed runtimes
#   ./scripts/install_legacy_sim.sh --keep-xcode 7.0  # keep Xcode after extraction
#
# Examples:
#   ./scripts/install_legacy_sim.sh 13.7    # CDN download
#   ./scripts/install_legacy_sim.sh 7.0     # Xcode-based extraction via xcodes
#   ./scripts/install_legacy_sim.sh 8.2     # Xcode-based extraction via xcodes
#
# =============================================================================

set -euo pipefail

RUNTIME_BASE="$HOME/Library/Developer/CoreSimulator/Profiles/Runtimes"
CACHE_DIR="$HOME/Library/Caches/com.apple.dt.Xcode/Downloads"
CDN_BASE="https://devimages-cdn.apple.com/downloads/xcode/simulators"
SDK_STUB_DIR="/Library/Developer/CoreSimulator/Profiles/Runtimes"
XCODES="/opt/homebrew/bin/xcodes"
KEEP_XCODE=0
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

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

ALL_VERSIONS="7.0 8.2 9.3 10.0 10.1 10.2 11.4 12.4 13.7 14.5 15.5"
CDN_VERSIONS="9.3 10.0 10.1 10.2 12.4 13.7 14.5 15.5"
XCODE_VERSIONS="7.0 8.2 11.4"

# Does this version use PurpleFBServer? (needs headServices in profile)
# NOTE: iOS 13.7/14.5 QuartzCore DOES contain PurpleFBServer strings, but these
# runtimes crash during launchd bootstrap on macOS 26 (XPC/launchd incompatibility)
# before backboardd ever connects to PurpleFBServer. Only iOS 7.0-12.4 actually
# boot successfully on modern macOS. iOS 15.7+ works natively via SimRenderServer.
is_purplefb() {
    case "$1" in
        7.0|8.2|9.3|10.0|10.1|10.2|10.3|11.4|12.4) return 0 ;;
        *) return 1 ;;
    esac
}

# Map iOS version to Xcode version for Xcode-bundled runtimes
xcode_version_for() {
    case "$1" in
        7.0)  echo "5.0" ;;
        8.2)  echo "6.2" ;;
        11.4) echo "9.4.1" ;;
        *)    echo "" ;;
    esac
}

# Archive.org mirror URLs (no auth needed, direct download)
archive_url_for() {
    case "$1" in
        7.0)  echo "https://archive.org/download/xcode-5/Xcode_5.dmg" ;;
        8.2)  echo "https://archive.org/download/xcode-6.2_202510/Xcode_6.2.dmg" ;;
        11.4) echo "https://archive.org/download/xcode-9.4.1/Xcode_9.4.1.xip" ;;
        *)    echo "" ;;
    esac
}

# Map iOS version to min host macOS version
min_host_for() {
    case "$1" in
        7.0)  echo "10.9" ;;
        8.2)  echo "10.9.3" ;;
        11.4) echo "10.12.4" ;;
        *)    echo "10.10.2" ;;
    esac
}

# Map iOS version to supported architectures
supported_archs_for() {
    case "$1" in
        7.0|8.2) echo "i386 x86_64" ;;
        *)       echo "x86_64" ;;
    esac
}

# =============================================================================
# Commands
# =============================================================================

cmd_list() {
    echo "Available iOS simulator runtimes:"
    echo ""
    echo "  From Apple CDN (direct download):"
    for ver in $CDN_VERSIONS; do
        local installed=""
        local dir_name="iOS_${ver}.simruntime"
        [ -d "$RUNTIME_BASE/$dir_name" ] && installed=" (installed)"
        local proto="SimFramebuffer"
        is_purplefb "$ver" && proto="PurpleFBServer"
        printf "    ${CYAN}iOS %-5s${NC}  %-16s %s\n" "$ver" "$proto" "$installed"
    done
    echo ""
    echo "  From old Xcode (via xcodes CLI — requires Apple ID):"
    for ver in $XCODE_VERSIONS; do
        local installed=""
        local dir_name="iOS_${ver}.simruntime"
        [ -d "$RUNTIME_BASE/$dir_name" ] && installed=" (installed)"
        local xc_ver
        xc_ver=$(xcode_version_for "$ver")
        printf "    ${CYAN}iOS %-5s${NC}  PurpleFBServer    Xcode %-6s %s\n" "$ver" "$xc_ver" "$installed"
    done
    echo ""
    echo "Usage: $0 <version>  (e.g., $0 13.7 or $0 7.0)"
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
# Generate plists for runtimes that don't ship with them (iOS 7.x, 8.x)
# =============================================================================

generate_info_plist() {
    local VERSION="$1"
    local RUNTIME_DIR="$2"
    local DASH_VER="${VERSION//./-}"

    cat > "$RUNTIME_DIR/Contents/Info.plist" << INFOPLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>English</string>
    <key>CFBundleExecutable</key>
    <string>iOS ${VERSION}</string>
    <key>CFBundleIdentifier</key>
    <string>com.apple.CoreSimulator.SimRuntime.iOS-${DASH_VER}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>iOS ${VERSION}</string>
    <key>CFBundlePackageType</key>
    <string>BNDL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleSignature</key>
    <string>????</string>
    <key>CFBundleSupportedPlatforms</key>
    <array>
        <string>MacOSX</string>
    </array>
    <key>CFBundleVersion</key>
    <string>1</string>
</dict>
</plist>
INFOPLIST
    log "Generated Info.plist for iOS $VERSION"
}

generate_profile_plist() {
    local VERSION="$1"
    local RUNTIME_DIR="$2"
    local MIN_HOST
    MIN_HOST=$(min_host_for "$VERSION")
    local ARCHS
    ARCHS=$(supported_archs_for "$VERSION")
    local MAJOR
    MAJOR=$(echo "$VERSION" | cut -d. -f1)

    local PROFILE="$RUNTIME_DIR/Contents/Resources/profile.plist"
    mkdir -p "$RUNTIME_DIR/Contents/Resources"

    # Build arch array entries
    local ARCH_ENTRIES=""
    local idx=0
    for arch in $ARCHS; do
        ARCH_ENTRIES="${ARCH_ENTRIES}
        <string>${arch}</string>"
    done

    cat > "$PROFILE" << PROFILEPLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>defaultVersionString</key>
    <string>${VERSION}</string>
    <key>devicePlatformFolderName</key>
    <string>iPhoneOS.platform</string>
    <key>forwardHostNotifications</key>
    <dict>
        <key>com.apple.system.clock_set</key>
        <string>com.apple.system.clock_set</string>
    </dict>
    <key>forwardHostNotificationsWithState</key>
    <dict>
        <key>com.apple.system.thermalpressurelevel</key>
        <string>com.apple.system.thermalpressurelevel</string>
    </dict>
    <key>headServices</key>
    <array>
        <string>PurpleFBServer</string>
        <string>PurpleFBTVOutServer</string>
        <string>IndigoHIDRegistrationPort</string>
    </array>
    <key>maxHostVersion</key>
    <string>99.99.99</string>
    <key>minHostVersion</key>
    <string>${MIN_HOST}</string>
    <key>platformIdentifier</key>
    <string>com.apple.platform.iphonesimulator</string>
    <key>platformName</key>
    <string>iPhoneSimulator</string>
    <key>runtimeDir</key>
    <string>iPhoneSimulator${VERSION}.sdk</string>
    <key>simulatorPlatformFolderName</key>
    <string>iPhoneSimulator.platform</string>
    <key>supportedArchs</key>
    <array>${ARCH_ENTRIES}
    </array>
    <key>supportedFeatures</key>
    <dict>
        <key>com.apple.instruments.remoteserver</key>
        <true/>
    </dict>
    <key>supportedProductFamilyIDs</key>
    <array>
        <integer>1</integer>
        <integer>2</integer>
    </array>
</dict>
</plist>
PROFILEPLIST
    log "Generated profile.plist for iOS $VERSION (archs: $ARCHS, minHost: $MIN_HOST)"
}

# =============================================================================
# =============================================================================
# Post-install runtime modifications
# =============================================================================

patch_runtime_binaries() {
    local VERSION="$1"
    local RUNTIME_DIR="$2"
    local RTROOT="$RUNTIME_DIR/Contents/Resources/RuntimeRoot"
    local MAJOR
    MAJOR=$(echo "$VERSION" | cut -d. -f1)

    # --- SimFramebufferClient stub (iOS 12+) ---
    # Prevents backboardd ud2 trap from SimFramebufferClient framework
    local SFB_STUB="$PROJECT_ROOT/src/build/SimFramebufferClient"
    local SFB_FW="$RTROOT/System/Library/PrivateFrameworks/SimFramebufferClient.framework"
    if [ -f "$SFB_STUB" ] && [ -d "$SFB_FW" ] && [ "$MAJOR" -ge 12 ]; then
        if [ ! -f "$SFB_FW/SimFramebufferClient.orig" ]; then
            cp "$SFB_FW/SimFramebufferClient" "$SFB_FW/SimFramebufferClient.orig" 2>/dev/null || true
        fi
        cp "$SFB_STUB" "$SFB_FW/SimFramebufferClient"
        codesign --force --sign - "$SFB_FW/SimFramebufferClient" 2>/dev/null
        log "Deployed SimFramebufferClient stub (iOS $VERSION)"
    fi

    # --- App installer dylib (all legacy runtimes) ---
    local INSTALLER="$PROJECT_ROOT/src/build/sim_app_installer.dylib"
    local SB="$RTROOT/System/Library/CoreServices/SpringBoard.app/SpringBoard"
    if [ -f "$INSTALLER" ] && [ -f "$SB" ]; then
        if ! otool -L "$SB" 2>/dev/null | grep -q sim_app_installer; then
            cp "$INSTALLER" "$RTROOT/usr/lib/" 2>/dev/null
            codesign --force --sign - "$RTROOT/usr/lib/sim_app_installer.dylib" 2>/dev/null
            cp "$SB" "${SB}.orig_installer" 2>/dev/null || true
            insert_dylib --inplace --all-yes /usr/lib/sim_app_installer.dylib "$SB" 2>/dev/null
            codesign --force --sign - --options=0 "$SB" 2>/dev/null
            log "Patched SpringBoard with app installer"
        fi
    fi

    # --- Scale fix (iOS 9.x/10.x) ---
    local SCALE_FIX="$PROJECT_ROOT/src/build/sim_scale_fix.dylib"
    local BB="$RTROOT/usr/libexec/backboardd"
    if [ -f "$SCALE_FIX" ] && [ -f "$BB" ] && [ "$MAJOR" -le 10 ]; then
        if [ ! -f "$RTROOT/usr/lib/sim_scale_fix.dylib" ]; then
            cp "$SCALE_FIX" "$RTROOT/usr/lib/"
            codesign --force --sign - "$RTROOT/usr/lib/sim_scale_fix.dylib" 2>/dev/null
            log "Deployed scale fix dylib"
        fi
        if ! otool -L "$BB" 2>/dev/null | grep -q sim_scale_fix; then
            cp "$BB" "${BB}.orig" 2>/dev/null || true
            insert_dylib --inplace --all-yes /usr/lib/sim_scale_fix.dylib "$BB" 2>/dev/null
            codesign --force --sign - --options=0 "$BB" 2>/dev/null
            log "Patched backboardd with scale fix"
        fi
    fi

    # --- HID backport (iOS 12.4) ---
    local HID_BACKPORT="$PROJECT_ROOT/src/build/hid_backport.dylib"
    if [ -f "$HID_BACKPORT" ] && [ -f "$BB" ] && [ "$VERSION" = "12.4" ]; then
        if ! otool -L "$BB" 2>/dev/null | grep -q hid_backport; then
            cp "$HID_BACKPORT" "$RTROOT/usr/lib/"
            codesign --force --sign - --options=0 "$RTROOT/usr/lib/hid_backport.dylib" 2>/dev/null
            # backboardd may already have been patched by scale_fix above
            if [ ! -f "${BB}.orig" ]; then
                cp "$BB" "${BB}.orig" 2>/dev/null || true
            fi
            insert_dylib --inplace --all-yes /usr/lib/hid_backport.dylib "$BB" 2>/dev/null
            codesign --force --sign - --options=0 "$BB" 2>/dev/null
            log "Patched backboardd with HID backport"
        fi
    fi
}

# =============================================================================
# Install from old Xcode via xcodes CLI
# =============================================================================

install_from_xcode() {
    local VERSION="$1"
    local XCODE_VER
    XCODE_VER=$(xcode_version_for "$VERSION")

    if [ -z "$XCODE_VER" ]; then
        err "No Xcode mapping for iOS $VERSION"
    fi

    local RUNTIME_DIR="$RUNTIME_BASE/iOS_${VERSION}.simruntime"

    # Check if already installed
    if [ -d "$RUNTIME_DIR" ] && [ -f "$RUNTIME_DIR/Contents/Resources/profile.plist" ]; then
        if xcrun simctl list runtimes 2>/dev/null | grep -q "iOS $VERSION"; then
            log "iOS $VERSION already installed and recognized"
            xcrun simctl list runtimes 2>/dev/null | grep "$VERSION"
            return 0
        fi
    fi

    local XCODE_APP="/Applications/Xcode-${XCODE_VER}.app"
    # Also check for Xcode named without dash (xcodes naming varies)
    [ -d "$XCODE_APP" ] || XCODE_APP="/Applications/Xcode_${XCODE_VER}.app"
    [ -d "$XCODE_APP" ] || XCODE_APP=$(find /Applications -maxdepth 1 -name "Xcode*${XCODE_VER}*" -type d 2>/dev/null | head -1)

    # Download Xcode if not present
    if [ -n "$XCODE_APP" ] && [ -d "$XCODE_APP" ]; then
        log "Found existing Xcode $XCODE_VER at $XCODE_APP"
    else
        XCODE_APP="/Applications/Xcode-${XCODE_VER}.app"
        local ARCHIVE_URL
        ARCHIVE_URL=$(archive_url_for "$VERSION")
        local DOWNLOADED=0

        # Try archive.org first (no auth needed)
        if [ -n "$ARCHIVE_URL" ]; then
            local EXT="${ARCHIVE_URL##*.}"
            local DL_FILE="$CACHE_DIR/Xcode_${XCODE_VER}.${EXT}"
            mkdir -p "$CACHE_DIR"

            if [ -f "$DL_FILE" ]; then
                log "Using cached download: $DL_FILE"
                DOWNLOADED=1
            else
                log "Downloading Xcode $XCODE_VER from archive.org (~2-6 GB)..."
                if curl -L -o "$DL_FILE" "$ARCHIVE_URL" --progress-bar --fail; then
                    log "Download complete"
                    DOWNLOADED=1
                else
                    warn "Archive.org download failed, trying xcodes CLI..."
                    rm -f "$DL_FILE"
                fi
            fi

            if [ "$DOWNLOADED" -eq 1 ]; then
                if [ "$EXT" = "xip" ]; then
                    log "Extracting XIP (this takes a while)..."
                    xip -x "$DL_FILE" -C /Applications 2>&1 || err "XIP extraction failed"
                    # Find the extracted app
                    XCODE_APP=$(find /Applications -maxdepth 1 -name "Xcode*.app" -newer "$DL_FILE" -type d 2>/dev/null | head -1)
                    [ -d "$XCODE_APP" ] || XCODE_APP="/Applications/Xcode.app"
                    # Rename to versioned name
                    if [ -d "$XCODE_APP" ] && [ "$XCODE_APP" != "/Applications/Xcode-${XCODE_VER}.app" ]; then
                        mv "$XCODE_APP" "/Applications/Xcode-${XCODE_VER}.app" 2>/dev/null || true
                        XCODE_APP="/Applications/Xcode-${XCODE_VER}.app"
                    fi
                else
                    # DMG
                    local XCODE_MOUNT=$(mktemp -d /tmp/xcode_mount_XXXXXX)
                    log "Mounting Xcode DMG..."
                    hdiutil attach "$DL_FILE" -mountpoint "$XCODE_MOUNT" -nobrowse -quiet
                    # Copy the .app from the mounted DMG
                    local XCODE_IN_DMG=$(find "$XCODE_MOUNT" -maxdepth 1 -name "Xcode*.app" -type d | head -1)
                    if [ -z "$XCODE_IN_DMG" ]; then
                        hdiutil detach "$XCODE_MOUNT" -quiet 2>/dev/null
                        err "No Xcode.app found in DMG"
                    fi
                    log "Copying Xcode from DMG (this takes a while)..."
                    cp -R "$XCODE_IN_DMG" "/Applications/Xcode-${XCODE_VER}.app"
                    hdiutil detach "$XCODE_MOUNT" -quiet 2>/dev/null
                    rmdir "$XCODE_MOUNT" 2>/dev/null
                    XCODE_APP="/Applications/Xcode-${XCODE_VER}.app"
                fi
            fi
        fi

        # Fallback to xcodes CLI if archive.org didn't work
        if [ ! -d "$XCODE_APP" ]; then
            if [ ! -x "$XCODES" ]; then
                err "Xcode $XCODE_VER not available. Install xcodes (brew install xcodes) or download manually."
            fi
            log "Downloading Xcode $XCODE_VER via xcodes (requires Apple ID)..."
            info "This downloads ~2-6 GB. You may be prompted to authenticate."
            "$XCODES" install "$XCODE_VER" 2>&1 || err "Failed to download Xcode $XCODE_VER"
            # Find installed app
            XCODE_APP=$(find /Applications -maxdepth 1 -name "Xcode*${XCODE_VER}*" -o -name "Xcode*$(echo "$XCODE_VER" | cut -d. -f1-2)*" 2>/dev/null | head -1)
        fi

        [ -d "$XCODE_APP" ] || err "Xcode $XCODE_VER not found in /Applications after download"
        log "Xcode installed at: $XCODE_APP"
    fi

    # Find simulator SDK in Xcode
    local SDK_PATH="$XCODE_APP/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs"
    local SIM_SDK=$(find "$SDK_PATH" -maxdepth 1 -name "iPhoneSimulator*.sdk" -type d 2>/dev/null | head -1)
    if [ -z "$SIM_SDK" ]; then
        err "No iPhoneSimulator SDK found in $SDK_PATH"
    fi
    log "Found SDK: $(basename "$SIM_SDK")"

    # Check if this Xcode has a pre-built simruntime
    local XCODE_RUNTIMES="$XCODE_APP/Contents/Developer/Platforms/iPhoneSimulator.platform/Library/Developer/CoreSimulator/Profiles/Runtimes"
    local EXISTING_RUNTIME=$(find "$XCODE_RUNTIMES" -name "*.simruntime" -maxdepth 1 2>/dev/null | head -1)

    if [ -n "$EXISTING_RUNTIME" ] && [ -f "$EXISTING_RUNTIME/Contents/Info.plist" ]; then
        # Xcode has a proper .simruntime bundle — copy it directly
        log "Found pre-built simruntime in Xcode: $(basename "$EXISTING_RUNTIME")"
        rm -rf "$RUNTIME_DIR"
        cp -R "$EXISTING_RUNTIME" "$RUNTIME_DIR"
    else
        # Build runtime from SDK directory
        log "Building simruntime from SDK..."
        rm -rf "$RUNTIME_DIR"
        mkdir -p "$RUNTIME_DIR/Contents/Resources/RuntimeRoot"

        # Copy the SDK contents as RuntimeRoot
        log "Copying RuntimeRoot (this may take a moment)..."
        cp -R "$SIM_SDK"/ "$RUNTIME_DIR/Contents/Resources/RuntimeRoot/"

        # Generate Info.plist
        generate_info_plist "$VERSION" "$RUNTIME_DIR"

        # Generate profile.plist
        generate_profile_plist "$VERSION" "$RUNTIME_DIR"
    fi

    # Ensure profile is patched (even if we copied from Xcode)
    local PROFILE="$RUNTIME_DIR/Contents/Resources/profile.plist"
    if [ -f "$PROFILE" ]; then
        /usr/libexec/PlistBuddy -c "Delete :maxHostVersion" "$PROFILE" 2>/dev/null || true
        /usr/libexec/PlistBuddy -c "Add :maxHostVersion string 99.99.99" "$PROFILE"

        /usr/libexec/PlistBuddy -c "Delete :platformIdentifier" "$PROFILE" 2>/dev/null || true
        /usr/libexec/PlistBuddy -c "Add :platformIdentifier string com.apple.platform.iphonesimulator" "$PROFILE"

        if is_purplefb "$VERSION"; then
            local has_head=$(/usr/libexec/PlistBuddy -c "Print :headServices" "$PROFILE" 2>/dev/null | grep -c PurpleFB || echo 0)
            if [ "$has_head" -eq 0 ]; then
                /usr/libexec/PlistBuddy -c "Delete :headServices" "$PROFILE" 2>/dev/null || true
                /usr/libexec/PlistBuddy \
                    -c "Add :headServices array" \
                    -c "Add :headServices:0 string PurpleFBServer" \
                    -c "Add :headServices:1 string PurpleFBTVOutServer" \
                    -c "Add :headServices:2 string IndigoHIDRegistrationPort" \
                    "$PROFILE"
            fi
        fi
        log "Profile patched for macOS 26 compatibility"
    else
        # No profile — generate one
        generate_profile_plist "$VERSION" "$RUNTIME_DIR"
    fi

    # Patch runtime binaries (SFB stub, app installer, scale fix, HID backport)
    patch_runtime_binaries "$VERSION" "$RUNTIME_DIR"

    # Cleanup Xcode (unless --keep-xcode)
    if [ "$KEEP_XCODE" -eq 0 ]; then
        local xcode_size
        xcode_size=$(du -sh "$XCODE_APP" 2>/dev/null | cut -f1)
        log "Removing Xcode $XCODE_VER ($xcode_size) to save disk space..."
        rm -rf "$XCODE_APP"
        log "Xcode removed. Use --keep-xcode to retain it."
    else
        info "Keeping Xcode $XCODE_VER at $XCODE_APP (--keep-xcode)"
    fi

    # Verify
    echo ""
    log "Installation complete!"
    if xcrun simctl list runtimes 2>/dev/null | grep -q "iOS $VERSION"; then
        log "iOS $VERSION recognized:"
        xcrun simctl list runtimes 2>/dev/null | grep "$VERSION"
    else
        warn "iOS $VERSION installed but not yet recognized. Try restarting CoreSimulator."
        info "Restart: kill -9 \$(pgrep -f CoreSimulatorService)"
    fi
}

# =============================================================================
# Install a specific version
# =============================================================================

install_version() {
    local VERSION="$1"
    local DMG_NAME
    DMG_NAME=$(cdn_url_for "$VERSION")

    if [ -z "$DMG_NAME" ]; then
        # Check if this is a Xcode-based runtime
        local XCODE_VER
        XCODE_VER=$(xcode_version_for "$VERSION")
        if [ -n "$XCODE_VER" ]; then
            install_from_xcode "$VERSION"
            return $?
        fi
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

    # Patch runtime binaries (SFB stub, app installer, scale fix, HID backport)
    patch_runtime_binaries "$VERSION" "$RUNTIME_DIR"

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

# Parse --keep-xcode flag
args=()
for arg in "$@"; do
    case "$arg" in
        --keep-xcode) KEEP_XCODE=1 ;;
        *) args+=("$arg") ;;
    esac
done
set -- "${args[@]+"${args[@]}"}"

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
        echo "Usage: $0 [--keep-xcode] <version|--list|--status|--patch-all>"
        echo ""
        echo "Commands:"
        echo "  <version>      Install a specific iOS runtime (e.g., 13.7 or 7.0)"
        echo "  --list         Show available versions"
        echo "  --status       Show installed runtimes and their patch status"
        echo "  --patch-all    Patch all installed runtimes for macOS 26 compatibility"
        echo ""
        echo "Options:"
        echo "  --keep-xcode   Don't delete downloaded Xcode after extracting runtime"
        echo ""
        echo "CDN versions download directly (~1-2 GB). Xcode-based versions (7.0, 8.2,"
        echo "11.4) require the xcodes CLI and an Apple ID to download the full Xcode,"
        echo "then extract just the simulator runtime."
        ;;
    *)
        install_version "$1"
        ;;
esac
