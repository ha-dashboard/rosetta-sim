#!/bin/bash
#
# run_legacy_sim.sh — Launch a legacy iOS simulator with display in Simulator.app
#
# Starts PurpleFB bridge, boots the sim, waits for rendering, then launches
# a re-signed Simulator.app with DYLD_INSERT of the display injection dylib.
#
# Usage:
#   ./scripts/run_legacy_sim.sh                        # default: first iOS 9.3 device
#   ./scripts/run_legacy_sim.sh "iPhone 6s"            # by device name
#   ./scripts/run_legacy_sim.sh "iPad Pro"             # iPad
#   ./scripts/run_legacy_sim.sh --ios10                # default iOS 10.3 device
#   ./scripts/run_legacy_sim.sh --no-inject <name>     # bridge only, no Simulator.app
#   ./scripts/run_legacy_sim.sh <UDID>                 # by exact UDID
#
# Prerequisites:
#   Run scripts/setup.sh first to build tools and create re-signed Simulator.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Tools
BRIDGE="$PROJECT_ROOT/tools/display_bridge/purple_fb_bridge"
INJECT="$PROJECT_ROOT/tools/display_bridge/sim_display_inject.dylib"
SIMULATOR="/tmp/Simulator_nolv.app/Contents/MacOS/Simulator"

# Framework paths needed by re-signed Simulator
DYLD_FW_PATH="/Applications/Xcode.app/Contents/Developer/Library/PrivateFrameworks:/Library/Developer/PrivateFrameworks"

# Parse args
DO_INJECT=1
DEVICE_SPEC=""
USE_IOS10=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-inject)
            DO_INJECT=0
            shift
            ;;
        --ios10|--10.3|--103)
            USE_IOS10=1
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS] [DEVICE_NAME_OR_UDID]"
            echo ""
            echo "Options:"
            echo "  --no-inject  Skip Simulator.app display injection (bridge + viewer only)"
            echo "  --ios10      Use default iOS 10.3 device"
            echo ""
            echo "Examples:"
            echo "  $0                      # default iOS 9.3 iPhone 6s"
            echo "  $0 \"iPhone 6s\"          # by name"
            echo "  $0 \"iPad Pro\"           # iPad"
            echo "  $0 --ios10              # iOS 10.3"
            echo "  $0 647B6002-...         # by UDID"
            exit 0
            ;;
        *)
            DEVICE_SPEC="$1"
            shift
            ;;
    esac
done

# --- Resolve device UDID ---
resolve_udid() {
    local spec="$1"

    # If it looks like a UDID (contains hyphens, all hex), use directly
    if [[ "$spec" =~ ^[0-9A-Fa-f-]{36}$ ]]; then
        echo "$spec"
        return
    fi

    # Search by name in legacy runtimes
    local udid
    udid=$(xcrun simctl list devices 2>/dev/null \
        | grep -E '9\.3|10\.3' \
        | grep -v unavailable \
        | grep "$spec" \
        | head -1 \
        | sed 's/.*(\([A-F0-9-]*\)).*/\1/')

    if [[ -z "$udid" ]]; then
        echo ""
        return
    fi
    echo "$udid"
}

if [[ -n "$DEVICE_SPEC" ]]; then
    UDID=$(resolve_udid "$DEVICE_SPEC")
    if [[ -z "$UDID" ]]; then
        echo "ERROR: Device '$DEVICE_SPEC' not found in legacy runtimes."
        echo ""
        echo "Available legacy devices:"
        xcrun simctl list devices 2>&1 | grep -E '9\.3|10\.3' | grep -v unavailable | sed 's/^/  /'
        exit 1
    fi
elif [[ "$USE_IOS10" -eq 1 ]]; then
    UDID=$(xcrun simctl list devices 2>/dev/null \
        | grep "10\.3" \
        | grep -v unavailable \
        | head -1 \
        | sed 's/.*(\([A-F0-9-]*\)).*/\1/')
    if [[ -z "$UDID" ]]; then
        echo "ERROR: No iOS 10.3 device found."
        exit 1
    fi
else
    # Default: first available iOS 9.3 device
    UDID=$(xcrun simctl list devices 2>/dev/null \
        | grep "9\.3" \
        | grep -v unavailable \
        | head -1 \
        | sed 's/.*(\([A-F0-9-]*\)).*/\1/')
    if [[ -z "$UDID" ]]; then
        echo "ERROR: No iOS 9.3 device found. Run scripts/setup.sh first."
        exit 1
    fi
fi

# Get device name for display
DEVICE_NAME=$(xcrun simctl list devices 2>/dev/null | grep "$UDID" | head -1 | sed 's/ *\(.*\) (.*/\1/')

echo "=== RosettaSim ==="
echo "Device: $DEVICE_NAME ($UDID)"
echo ""

# --- Verify tools ---
if [[ ! -x "$BRIDGE" ]]; then
    echo "ERROR: Bridge not built. Run: scripts/setup.sh"
    exit 1
fi
if [[ "$DO_INJECT" -eq 1 ]]; then
    if [[ ! -f "$INJECT" ]]; then
        echo "ERROR: Injection dylib not built. Run: scripts/setup.sh"
        exit 1
    fi
    if [[ ! -f "$SIMULATOR" ]]; then
        echo "ERROR: Re-signed Simulator not found. Run: scripts/setup.sh"
        exit 1
    fi
fi

# --- Cleanup function ---
BRIDGE_PID=""
SIM_PID=""
cleanup() {
    echo ""
    echo "Shutting down..."
    [[ -n "$SIM_PID" ]] && kill "$SIM_PID" 2>/dev/null || true
    [[ -n "$BRIDGE_PID" ]] && kill "$BRIDGE_PID" 2>/dev/null || true
    xcrun simctl shutdown "$UDID" 2>/dev/null || true
    rm -f /tmp/sim_framebuffer.raw /tmp/sim_framebuffer.raw.tmp /tmp/rosettasim_surface_id
    echo "Done."
}
trap cleanup EXIT INT TERM

# --- Kill existing Simulator.app (only one instance allowed) ---
if pgrep -x Simulator >/dev/null 2>&1; then
    echo "Killing existing Simulator.app..."
    pkill -x Simulator 2>/dev/null || true
    sleep 2
fi

# --- Ensure device is shutdown ---
xcrun simctl shutdown "$UDID" 2>/dev/null || true
sleep 1

# --- Step 1: Start PurpleFB bridge ---
echo "Starting PurpleFB bridge..."
"$BRIDGE" "$UDID" &
BRIDGE_PID=$!
sleep 2

if ! kill -0 "$BRIDGE_PID" 2>/dev/null; then
    echo "ERROR: Bridge failed to start."
    exit 1
fi
echo "  Bridge running (PID $BRIDGE_PID)"

# --- Step 2: Boot simulator ---
echo "Booting simulator..."
if ! xcrun simctl boot "$UDID" 2>/dev/null; then
    echo "ERROR: Failed to boot simulator."
    exit 1
fi
echo "  Simulator booted."

# --- Step 3: Wait for framebuffer ---
echo "Waiting for framebuffer..."
for i in $(seq 1 20); do
    if [[ -f /tmp/sim_framebuffer.raw ]]; then
        SIZE=$(wc -c < /tmp/sim_framebuffer.raw)
        if [[ "$SIZE" -gt 100000 ]]; then
            echo "  Framebuffer active ($SIZE bytes)"
            break
        fi
    fi
    sleep 1
done

# --- Step 4: Launch Simulator.app with injection ---
if [[ "$DO_INJECT" -eq 1 ]]; then
    echo "Launching Simulator.app with display injection..."
    DYLD_FRAMEWORK_PATH="$DYLD_FW_PATH" \
    DYLD_INSERT_LIBRARIES="$INJECT" \
    "$SIMULATOR" &
    SIM_PID=$!
    sleep 5

    if kill -0 "$SIM_PID" 2>/dev/null; then
        echo "  Simulator.app running (PID $SIM_PID)"
    else
        echo "  WARNING: Simulator.app exited. Display may not be available."
        SIM_PID=""
    fi
else
    echo "Skipping Simulator.app injection (--no-inject)."
    echo "Use the standalone viewer: tools/display_bridge/sim_viewer"
fi

# --- Summary ---
echo ""
echo "=== Legacy Simulator Running ==="
echo "  Device: $DEVICE_NAME"
echo "  UDID:   $UDID"
echo "  Bridge: PID $BRIDGE_PID"
[[ -n "$SIM_PID" ]] && echo "  Simulator: PID $SIM_PID"
echo ""
echo "Press Ctrl-C to stop."
echo ""

# Keep running until interrupted
wait "$BRIDGE_PID" 2>/dev/null || true
