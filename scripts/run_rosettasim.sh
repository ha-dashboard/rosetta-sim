#!/bin/bash
#
# run_rosettasim.sh — Unified RosettaSim launcher
#
# Builds all components and launches the broker, which in turn
# spawns backboardd with the PurpleFBServer shim. CARenderServer
# ports are shared via the broker for app processes to connect.
#
# Usage:
#   ./scripts/run_rosettasim.sh                # build + run
#   ./scripts/run_rosettasim.sh --no-build     # run only (skip build)
#   ./scripts/run_rosettasim.sh --background   # run in background
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

SDK_DEFAULT="/Applications/Xcode-8.3.3.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator10.3.sdk"
SDK="${ROSETTASIM_SDK:-$SDK_DEFAULT}"
BROKER="$PROJECT_ROOT/src/bridge/rosettasim_broker"
PFB="$PROJECT_ROOT/src/bridge/purple_fb_server.dylib"
APP_SHIM="$PROJECT_ROOT/src/bridge/app_shim.dylib"

NO_BUILD=0
BACKGROUND=0
for arg in "$@"; do
    case "$arg" in
        --no-build) NO_BUILD=1 ;;
        --background) BACKGROUND=1 ;;
    esac
done

# Clean up any existing processes
cleanup() {
    echo "Cleaning up..."
    kill $(pgrep -f "rosettasim_broker" 2>/dev/null) 2>/dev/null || true
    kill $(pgrep -f "backboardd.*PurpleFBServer" 2>/dev/null) 2>/dev/null || true
    rm -f /tmp/rosettasim_broker.pid
}
trap cleanup EXIT

echo "========================================"
echo " RosettaSim"
echo "========================================"

# Build if needed
if [[ $NO_BUILD -eq 0 ]]; then
    echo ""
    echo "Building components..."
    "$SCRIPT_DIR/build_purple_fb.sh" 2>&1 | tail -2
    "$SCRIPT_DIR/build_broker.sh" 2>&1 | tail -2
    "$SCRIPT_DIR/build_app_shim.sh" 2>&1 | tail -2
    echo ""
fi

# Verify all binaries exist
for bin in "$BROKER" "$PFB" "$APP_SHIM"; do
    if [[ ! -f "$bin" ]]; then
        echo "ERROR: Missing $bin"
        echo "Run: ./scripts/run_rosettasim.sh (without --no-build)"
        exit 1
    fi
done

echo "SDK:       $SDK"
echo "Broker:    $BROKER"
echo "Shim:      $PFB"
echo "App Shim:  $APP_SHIM"
echo "========================================"
echo ""

if [[ $BACKGROUND -eq 1 ]]; then
    "$BROKER" --sdk "$SDK" --shim "$PFB" > /tmp/rosettasim.log 2>&1 &
    BROKER_PID=$!
    echo "Broker PID: $BROKER_PID"
    echo "$BROKER_PID" > /tmp/rosettasim_broker.pid
    echo "Log: /tmp/rosettasim.log"
    echo ""
    sleep 3
    if kill -0 $BROKER_PID 2>/dev/null; then
        echo "RosettaSim running."
        echo ""
        echo "To check status:"
        echo "  tail -f /tmp/rosettasim.log"
        echo ""
        echo "To stop:"
        echo "  kill \$(cat /tmp/rosettasim_broker.pid)"
        # Don't let the trap kill it
        trap - EXIT
    else
        echo "ERROR: Broker exited. Check /tmp/rosettasim.log"
        exit 1
    fi
else
    exec "$BROKER" --sdk "$SDK" --shim "$PFB"
fi
