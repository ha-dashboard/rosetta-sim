#!/bin/bash
#
# run_backboardd.sh — Launch backboardd with PurpleFBServer shim
#
# This runs the iOS 10.3 backboardd binary with the PurpleFBServer
# shim injected to provide the display framebuffer and bypass
# service registration. CARenderServer starts and renders at 60fps.
#
# Usage:
#   ./scripts/run_backboardd.sh                # foreground
#   ./scripts/run_backboardd.sh --background   # background, print PID
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

SDK="/Applications/Xcode-8.3.3.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator10.3.sdk"
PFB="$PROJECT_ROOT/src/bridge/purple_fb_server.dylib"
HID_BUNDLE="$PROJECT_ROOT/src/bridge/RosettaSimHIDManager.bundle"
SIM_HOME="$PROJECT_ROOT/.sim_home"

# Build PurpleFBServer if needed
if [[ ! -f "$PFB" ]] || ! codesign -v "$PFB" 2>/dev/null; then
    echo "Building PurpleFBServer..."
    "$SCRIPT_DIR/build_purple_fb.sh"
fi

# Build HID Manager bundle if needed
if [[ ! -f "$HID_BUNDLE/Contents/MacOS/RosettaSimHIDManager" ]] || \
   ! codesign -v "$HID_BUNDLE" 2>/dev/null; then
    echo "Building RosettaSimHIDManager..."
    "$SCRIPT_DIR/build_hid_manager.sh"
fi

# Create sim home
mkdir -p "$SIM_HOME/Library/Preferences" "$SIM_HOME/Library/Caches" "$SIM_HOME/Library/Logs"
mkdir -p "$SIM_HOME/Documents" "$SIM_HOME/Media" "$SIM_HOME/tmp"

# Clean old framebuffer
rm -f /tmp/rosettasim_framebuffer

BACKGROUND=0
if [[ "${1:-}" == "--background" ]]; then
    BACKGROUND=1
fi

echo "========================================"
echo "RosettaSim backboardd"
echo "========================================"
echo "SDK:       $SDK"
echo "Shim:      $PFB"
echo "HID Mgr:   $HID_BUNDLE"
echo "Sim Home:  $SIM_HOME"
echo "========================================"

if [[ $BACKGROUND -eq 1 ]]; then
    env \
      DYLD_ROOT_PATH="$SDK" \
      DYLD_INSERT_LIBRARIES="$PFB" \
      IPHONE_SIMULATOR_ROOT="$SDK" \
      SIMULATOR_ROOT="$SDK" \
      HOME="$SIM_HOME" \
      CFFIXED_USER_HOME="$SIM_HOME" \
      TMPDIR="$SIM_HOME/tmp" \
      SIMULATOR_DEVICE_NAME="iPhone 6s" \
      SIMULATOR_MODEL_IDENTIFIER="iPhone8,1" \
      SIMULATOR_RUNTIME_VERSION="10.3" \
      SIMULATOR_RUNTIME_BUILD_VERSION="14E8301" \
      SIMULATOR_MAINSCREEN_WIDTH="750" \
      SIMULATOR_MAINSCREEN_HEIGHT="1334" \
      SIMULATOR_MAINSCREEN_SCALE="2.0" \
      SIMULATOR_HID_SYSTEM_MANAGER="$HID_BUNDLE" \
      "$SDK/usr/libexec/backboardd" > /tmp/backboardd.log 2>&1 &

    BBD_PID=$!
    echo "backboardd PID: $BBD_PID"
    echo "Log: /tmp/backboardd.log"
    echo ""
    sleep 2
    if kill -0 $BBD_PID 2>/dev/null; then
        echo "backboardd is running."
    else
        echo "ERROR: backboardd exited immediately. Check /tmp/backboardd.log"
        exit 1
    fi
else
    exec env \
      DYLD_ROOT_PATH="$SDK" \
      DYLD_INSERT_LIBRARIES="$PFB" \
      IPHONE_SIMULATOR_ROOT="$SDK" \
      SIMULATOR_ROOT="$SDK" \
      HOME="$SIM_HOME" \
      CFFIXED_USER_HOME="$SIM_HOME" \
      TMPDIR="$SIM_HOME/tmp" \
      SIMULATOR_DEVICE_NAME="iPhone 6s" \
      SIMULATOR_MODEL_IDENTIFIER="iPhone8,1" \
      SIMULATOR_RUNTIME_VERSION="10.3" \
      SIMULATOR_RUNTIME_BUILD_VERSION="14E8301" \
      SIMULATOR_MAINSCREEN_WIDTH="750" \
      SIMULATOR_MAINSCREEN_HEIGHT="1334" \
      SIMULATOR_MAINSCREEN_SCALE="2.0" \
      SIMULATOR_HID_SYSTEM_MANAGER="$HID_BUNDLE" \
      "$SDK/usr/libexec/backboardd"
fi
