#!/bin/bash
#
# run_full.sh — Launch complete RosettaSim pipeline
#
# Starts broker (which spawns backboardd + app) and host app together.
# The host app displays the app's framebuffer and sends touch/keyboard input.
#
# Usage:
#   ./scripts/run_full.sh [app_path]
#   ./scripts/run_full.sh  # defaults to hass-dashboard
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Paths
SDK="/Applications/Xcode-8.3.3.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator10.3.sdk"
BROKER="$PROJECT_ROOT/src/bridge/rosettasim_broker"
PFB="$PROJECT_ROOT/src/bridge/purple_fb_server.dylib"
BRIDGE="$PROJECT_ROOT/src/bridge/rosettasim_bridge.dylib"
HOST_APP="$PROJECT_ROOT/src/host/RosettaSimApp/build/RosettaSim"

# Default app
APP_PATH="${1:-/Users/ashhopkins/Projects/hass-dashboard/build/rosettasim/Build/Products/Debug-iphonesimulator/HA Dashboard.app}"

# App framebuffer (separate from backboardd's)
APP_FB="/tmp/rosettasim_app_framebuffer"

# Build if needed
echo "========================================"
echo " RosettaSim — Full Pipeline"
echo "========================================"

for bin in "$BROKER" "$PFB" "$BRIDGE"; do
    if [[ ! -f "$bin" ]]; then
        echo "Building components..."
        "$SCRIPT_DIR/build_purple_fb.sh" 2>&1 | tail -1
        "$SCRIPT_DIR/build_broker.sh" 2>&1 | tail -1
        "$SCRIPT_DIR/build_bridge.sh" 2>&1 | tail -1
        break
    fi
done

if [[ ! -f "$HOST_APP" ]]; then
    echo "Building host app..."
    "$PROJECT_ROOT/src/host/RosettaSimApp/build.sh" 2>&1 | tail -1
fi

echo "SDK:       $SDK"
echo "App:       $APP_PATH"
echo "Host App:  $HOST_APP"
echo "App FB:    $APP_FB"
echo "========================================"
echo ""

# Cleanup — ALWAYS kill by PID, never by pattern matching.
# Pattern-based kills (pgrep -f "backboardd") can match macOS system services.
cleanup() {
    echo ""
    echo "Shutting down..."
    # Kill broker by PID (it kills its own children on SIGTERM)
    if [[ -n "${BROKER_PID:-}" ]]; then
        kill "$BROKER_PID" 2>/dev/null || true
        wait "$BROKER_PID" 2>/dev/null || true
    fi
    # Kill host app by PID
    if [[ -n "${HOST_PID:-}" ]]; then
        kill "$HOST_PID" 2>/dev/null || true
    fi
    rm -f /tmp/rosettasim_broker.pid "$APP_FB" /tmp/rosettasim_framebuffer
    echo "Done."
}
trap cleanup EXIT

# Clean old state
rm -f "$APP_FB" /tmp/rosettasim_framebuffer /tmp/rosettasim_broker.pid

# Start broker (spawns backboardd + app)
echo "Starting broker..."
"$BROKER" \
    --shim "$PFB" \
    --bridge "$BRIDGE" \
    --app "$APP_PATH" \
    > /tmp/rosettasim_broker.log 2>&1 &
BROKER_PID=$!

# Wait for app framebuffer to appear.
# The broker waits for backboardd services + SpringBoard + then spawns app,
# which can take up to 60 seconds.
echo "Waiting for app to start (this may take up to 60s with SpringBoard)..."
for i in $(seq 1 120); do
    if [[ -f "$APP_FB" ]]; then
        echo "App framebuffer ready."
        break
    fi
    sleep 0.5
done

if [[ ! -f "$APP_FB" ]]; then
    echo "ERROR: App framebuffer not created after 60s"
    echo "Check: tail -f /tmp/rosettasim_broker.log"
    # Don't exit — try to continue with backboardd framebuffer
    echo "Trying with backboardd framebuffer instead..."
    APP_FB="/tmp/rosettasim_framebuffer"
    if [[ ! -f "$APP_FB" ]]; then
        echo "No framebuffer at all — check logs"
        exit 1
    fi
fi

# Start host app reading from the app framebuffer
echo "Starting host app..."
ROSETTASIM_FB_PATH="$APP_FB" \
ROSETTASIM_PROJECT_ROOT="$PROJECT_ROOT" \
    "$HOST_APP" &
HOST_PID=$!

echo ""
echo "RosettaSim running:"
echo "  Broker:   PID $BROKER_PID (log: /tmp/rosettasim_broker.log)"
echo "  Host App: PID $HOST_PID"
echo ""
echo "Press Ctrl+C to stop."

# Wait for either process to exit
wait $HOST_PID 2>/dev/null || true
