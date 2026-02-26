#!/bin/bash
#
# run_legacy_sim.sh — Launch a legacy iOS simulator with display support
#
# Boots a legacy iOS simulator (9.3 / 10.3) with the PurpleFB bridge
# providing framebuffer services, then optionally injects the display
# surface into Simulator.app so it appears in the normal Xcode window.
#
# Usage:
#   ./scripts/run_legacy_sim.sh                     # default: iOS 9.3 iPhone 6s
#   ./scripts/run_legacy_sim.sh <UDID>              # specific device
#   ./scripts/run_legacy_sim.sh --no-inject <UDID>  # skip Simulator.app injection
#
# Prerequisites:
#   - Device must be created: xcrun simctl create "iPhone 6s (9.3)" ...
#   - purple_fb_bridge must be built: tools/display_bridge/purple_fb_bridge
#   - sim_display_inject.dylib must be built: tools/display_bridge/sim_display_inject.dylib
#
# How it works:
#   1. Registers PurpleFBServer Mach service for the device via CoreSimulator API
#   2. Boots the sim — backboardd finds PurpleFBServer and creates a display
#   3. Optionally injects display dylib into Simulator.app to show the surface
#   4. Keeps running until Ctrl-C (bridge must stay alive for display to work)
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Tools
BRIDGE="$PROJECT_ROOT/tools/display_bridge/purple_fb_bridge"
INJECT="$PROJECT_ROOT/tools/display_bridge/sim_display_inject.dylib"

# Default device UDIDs
DEFAULT_93="647B6002-AD33-46AE-A78B-A7DAE3128A69"
DEFAULT_103="03291AC5-5138-4486-A818-F86197A9BFAB"

# Parse args
DO_INJECT=1
UDID=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-inject)
            DO_INJECT=0
            shift
            ;;
        --ios10|--10.3|--103)
            UDID="$DEFAULT_103"
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [--no-inject] [--ios10] [UDID]"
            echo ""
            echo "Options:"
            echo "  --no-inject  Skip Simulator.app display injection"
            echo "  --ios10      Use default iOS 10.3 device"
            echo "  UDID         Specific device UUID"
            echo ""
            echo "Default: iOS 9.3 iPhone 6s ($DEFAULT_93)"
            exit 0
            ;;
        *)
            UDID="$1"
            shift
            ;;
    esac
done

UDID="${UDID:-$DEFAULT_93}"

# Verify tools exist
if [[ ! -x "$BRIDGE" ]]; then
    echo "ERROR: PurpleFB bridge not found at $BRIDGE"
    echo "Build it: cd tools/display_bridge && clang -fobjc-arc -fmodules -arch arm64e -framework Foundation -framework IOSurface -Wl,-undefined,dynamic_lookup -o purple_fb_bridge purple_fb_bridge.m"
    exit 1
fi

# Verify device exists
if ! xcrun simctl list devices 2>/dev/null | grep -q "$UDID"; then
    echo "ERROR: Device $UDID not found"
    echo "Available legacy devices:"
    xcrun simctl list devices 2>&1 | grep -E '9\.3|10\.3' | grep -v unavailable
    exit 1
fi

# Ensure device is shutdown
echo "Ensuring device is shutdown..."
xcrun simctl shutdown "$UDID" 2>/dev/null || true

# Cleanup on exit
BRIDGE_PID=""
cleanup() {
    echo ""
    echo "Shutting down..."
    if [[ -n "$BRIDGE_PID" ]]; then
        kill "$BRIDGE_PID" 2>/dev/null || true
        wait "$BRIDGE_PID" 2>/dev/null || true
    fi
    xcrun simctl shutdown "$UDID" 2>/dev/null || true
    echo "Done."
}
trap cleanup EXIT INT TERM

# Step 1: Start PurpleFB bridge
echo "Starting PurpleFB bridge for $UDID..."
"$BRIDGE" "$UDID" &
BRIDGE_PID=$!

# Wait for bridge to register service
sleep 2

# Verify bridge is running
if ! kill -0 "$BRIDGE_PID" 2>/dev/null; then
    echo "ERROR: PurpleFB bridge died. Check output above."
    exit 1
fi

echo "PurpleFB bridge running (PID $BRIDGE_PID)"

# Step 2: Boot the simulator
echo "Booting simulator..."
if ! xcrun simctl boot "$UDID"; then
    echo "ERROR: Failed to boot simulator"
    exit 1
fi

echo "Simulator booted. Waiting for backboardd to connect..."
sleep 5

# Step 3: Verify rendering
if [[ -f /tmp/sim_framebuffer.raw ]]; then
    echo "Framebuffer active: $(ls -la /tmp/sim_framebuffer.raw | awk '{print $5}') bytes"
else
    echo "WARNING: No framebuffer dump yet. backboardd may still be starting."
fi

# Step 4: Inject display into Simulator.app (optional)
if [[ "$DO_INJECT" -eq 1 ]] && [[ -f "$INJECT" ]]; then
    SIMPID=$(pgrep -x Simulator 2>/dev/null || true)
    if [[ -n "$SIMPID" ]]; then
        echo "Injecting display surface into Simulator.app (PID $SIMPID)..."
        lldb -p "$SIMPID" \
            -o "expr (void*)dlopen(\"$INJECT\", 2)" \
            -o "detach" \
            -o "quit" \
            2>/dev/null || echo "WARNING: lldb injection failed (may need SIP disabled)"
        echo "Display injection complete."
    else
        echo "NOTE: Simulator.app not running. Start it manually or use 'open -a Simulator'."
        echo "Then inject: lldb -p \$(pgrep -x Simulator) -o 'expr (void*)dlopen(\"$INJECT\", 2)' -o detach -o quit"
    fi
elif [[ "$DO_INJECT" -eq 1 ]]; then
    echo "NOTE: sim_display_inject.dylib not found. Skipping display injection."
    echo "Build it: cd tools/display_bridge && clang -dynamiclib -fobjc-arc -fmodules -arch arm64e -framework Foundation -framework IOSurface -framework AppKit -o sim_display_inject.dylib sim_display_inject.m"
fi

# Step 5: Keep running
echo ""
echo "=== Legacy simulator running ==="
echo "  Device: $UDID"
echo "  Bridge: PID $BRIDGE_PID"
echo "  Framebuffer: /tmp/sim_framebuffer.raw"
echo "  Surface ID: $(cat /tmp/rosettasim_surface_id 2>/dev/null || echo 'unknown')"
echo ""
echo "View framebuffer:"
echo "  swift tools/display_bridge/../view_raw_framebuffer.swift"
echo ""
echo "Press Ctrl-C to stop."
echo ""

wait "$BRIDGE_PID"
