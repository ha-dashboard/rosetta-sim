#!/bin/bash
#
# RosettaSim.command — Double-click to launch RosettaSim
#
# One-click launcher for legacy iOS simulator display bridge.
# Ensures daemon is running, Simulator.app is re-signed, and
# display injection is active.
#
# Double-click this file in Finder, or run from Terminal:
#   ./RosettaSim.command
#

set -euo pipefail

# Resolve project root from this script's location
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

BUILD_DIR="$SCRIPT_DIR/src/build"
DAEMON="$BUILD_DIR/rosettasim_daemon"
INJECT="$BUILD_DIR/sim_display_inject.dylib"
SIMULATOR_CACHE="/tmp/Simulator_nolv.app"
SIMULATOR_BIN="$SIMULATOR_CACHE/Contents/MacOS/Simulator"
SIMULATOR_SRC="/Applications/Xcode.app/Contents/Developer/Applications/Simulator.app"
DYLD_FW_PATH="/Applications/Xcode.app/Contents/Developer/Library/PrivateFrameworks:/Library/Developer/PrivateFrameworks"

echo "=== RosettaSim ==="
echo ""

# --- Build if needed ---
if [[ ! -x "$DAEMON" ]] || [[ ! -f "$INJECT" ]]; then
    echo "Building tools (first run)..."
    cd src && make && cd ..
    echo ""
fi

# --- Create re-signed Simulator if needed ---
if [[ ! -f "$SIMULATOR_BIN" ]]; then
    echo "Creating re-signed Simulator.app..."
    if [[ ! -f "$SIMULATOR_SRC/Contents/MacOS/Simulator" ]]; then
        echo "ERROR: Xcode Simulator.app not found at $SIMULATOR_SRC"
        echo "Install Xcode.app first."
        read -rp "Press Enter to close..."
        exit 1
    fi
    cp -R "$SIMULATOR_SRC" "$SIMULATOR_CACHE"
    codesign --force --sign - --options=0 "$SIMULATOR_BIN" 2>/dev/null
    echo "  Done."
    echo ""
fi

# --- Start daemon if not running ---
if ! pgrep -f rosettasim_daemon >/dev/null 2>&1; then
    echo "Starting daemon..."
    "$DAEMON" &
    DAEMON_PID=$!
    sleep 3
    if ! kill -0 "$DAEMON_PID" 2>/dev/null; then
        echo "ERROR: Daemon failed to start."
        read -rp "Press Enter to close..."
        exit 1
    fi
    echo "  Daemon running (PID $DAEMON_PID)"
else
    DAEMON_PID=$(pgrep -f rosettasim_daemon | head -1)
    echo "Daemon already running (PID $DAEMON_PID)"
fi

# --- Boot a legacy device if none booted ---
BOOTED=$(xcrun simctl list devices 2>/dev/null | grep Booted | head -1 || true)
if [[ -z "$BOOTED" ]]; then
    echo "Booting a legacy device..."
    # Find first available legacy device
    for ver in 9.3 10.3 8.2 12.4 13.7 7.0; do
        UDID=$(xcrun simctl list devices 2>/dev/null \
            | grep -E "iOS ${ver}" -A 50 \
            | grep -E 'Shutdown' \
            | grep -v unavailable \
            | grep -oE '[A-F0-9-]{36}' \
            | head -1) || true
        if [[ -n "$UDID" ]]; then
            xcrun simctl boot "$UDID" 2>/dev/null && \
                echo "  Booted: $UDID" || true
            sleep 3
            break
        fi
    done
fi

# --- Kill existing Simulator.app (needs re-launch with injection) ---
if pgrep -x Simulator >/dev/null 2>&1; then
    echo "Restarting Simulator.app with display injection..."
    pkill -x Simulator 2>/dev/null || true
    sleep 2
fi

# --- Launch Simulator.app with injection ---
echo "Launching Simulator.app..."
DYLD_FRAMEWORK_PATH="$DYLD_FW_PATH" \
DYLD_INSERT_LIBRARIES="$INJECT" \
"$SIMULATOR_BIN" &
SIM_PID=$!
sleep 2

if kill -0 "$SIM_PID" 2>/dev/null; then
    echo "  Simulator.app running (PID $SIM_PID)"
else
    echo "  WARNING: Simulator.app exited immediately."
fi

echo ""
echo "=== RosettaSim Ready ==="
echo ""
echo "  Boot legacy devices from Simulator's menu or CLI."
echo "  Close this window or press Ctrl-C to stop."
echo ""

# --- Cleanup on exit ---
cleanup() {
    echo ""
    echo "Shutting down..."
    kill "$SIM_PID" 2>/dev/null || true
    # Leave daemon running — it's lightweight
    echo "Simulator stopped. Daemon still running."
    echo "  To stop daemon: pkill -f rosettasim_daemon"
}
trap cleanup EXIT INT TERM

# Keep window open
wait "$SIM_PID" 2>/dev/null || true
