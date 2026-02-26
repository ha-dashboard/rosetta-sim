#!/bin/bash
#
# start_rosettasim.sh — One-command launcher for RosettaSim daemon + Simulator.app
#
# Starts the daemon (auto-manages all legacy devices), then launches
# re-signed Simulator.app with display injection. Boot any legacy device
# from Simulator's menu and it works automatically.
#
# Usage:
#   ./scripts/start_rosettasim.sh          # start daemon + Simulator
#   ./scripts/start_rosettasim.sh --stop   # stop everything
#
# Prerequisites:
#   Run scripts/setup.sh first.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

DAEMON="$PROJECT_ROOT/tools/display_bridge/rosettasim_daemon"
INJECT="$PROJECT_ROOT/tools/display_bridge/sim_display_inject.dylib"
SIMULATOR="/tmp/Simulator_nolv.app/Contents/MacOS/Simulator"
DYLD_FW_PATH="/Applications/Xcode.app/Contents/Developer/Library/PrivateFrameworks:/Library/Developer/PrivateFrameworks"

PIDFILE_DAEMON="/tmp/rosettasim_daemon.pid"
PIDFILE_SIM="/tmp/rosettasim_simulator.pid"

# --- Stop mode ---
if [[ "${1:-}" == "--stop" ]] || [[ "${1:-}" == "stop" ]]; then
    echo "Stopping RosettaSim..."
    if [[ -f "$PIDFILE_SIM" ]]; then
        kill "$(cat "$PIDFILE_SIM")" 2>/dev/null || true
        rm -f "$PIDFILE_SIM"
    fi
    pkill -x Simulator 2>/dev/null || true
    if [[ -f "$PIDFILE_DAEMON" ]]; then
        kill "$(cat "$PIDFILE_DAEMON")" 2>/dev/null || true
        rm -f "$PIDFILE_DAEMON"
    fi
    pkill -f rosettasim_daemon 2>/dev/null || true
    # Shutdown all legacy sims
    for udid in $(xcrun simctl list devices 2>/dev/null | grep -E -e '9\.3|10\.3' | grep -v unavailable | grep Booted | sed 's/.*(\([A-F0-9-]*\)).*/\1/'); do
        xcrun simctl shutdown "$udid" 2>/dev/null || true
    done
    rm -f /tmp/rosettasim_*.json /tmp/rosettasim_fb_*.raw /tmp/sim_framebuffer.raw
    echo "Done."
    exit 0
fi

# --- Verify tools ---
if [[ ! -x "$DAEMON" ]]; then
    echo "ERROR: Daemon not built. Run: scripts/setup.sh"
    exit 1
fi
if [[ ! -f "$INJECT" ]]; then
    echo "ERROR: Injection dylib not built. Run: scripts/setup.sh"
    exit 1
fi
if [[ ! -f "$SIMULATOR" ]]; then
    echo "ERROR: Re-signed Simulator not found. Run: scripts/setup.sh"
    exit 1
fi

echo "=== RosettaSim ==="
echo ""

# --- Cleanup function ---
cleanup() {
    echo ""
    echo "Stopping RosettaSim..."
    [[ -n "${SIM_PID:-}" ]] && kill "$SIM_PID" 2>/dev/null || true
    [[ -n "${DAEMON_PID:-}" ]] && kill "$DAEMON_PID" 2>/dev/null || true
    rm -f "$PIDFILE_DAEMON" "$PIDFILE_SIM"
    # Shutdown all legacy sims
    for udid in $(xcrun simctl list devices 2>/dev/null | grep -E -e '9\.3|10\.3' | grep -v unavailable | grep Booted | sed 's/.*(\([A-F0-9-]*\)).*/\1/'); do
        xcrun simctl shutdown "$udid" 2>/dev/null || true
    done
    rm -f /tmp/rosettasim_*.json /tmp/rosettasim_fb_*.raw /tmp/sim_framebuffer.raw
    echo "Done."
}
trap cleanup EXIT INT TERM

# --- Step 1: Ensure clean slate ---
echo "Ensuring clean state..."
xcrun simctl shutdown all 2>/dev/null || true
pkill -f rosettasim_daemon 2>/dev/null || true
sleep 1

# --- Step 2: Start daemon ---
echo "Starting RosettaSim daemon..."
"$DAEMON" &
DAEMON_PID=$!
echo "$DAEMON_PID" > "$PIDFILE_DAEMON"
sleep 3

if ! kill -0 "$DAEMON_PID" 2>/dev/null; then
    echo "ERROR: Daemon failed to start."
    exit 1
fi
echo "  Daemon running (PID $DAEMON_PID)"

# --- Step 2b: Boot a default device (Simulator crashes without a booted device) ---
echo "Booting default legacy device..."
DEFAULT_UDID=$(xcrun simctl list devices 2>/dev/null \
    | grep -E '(Shutdown|Booted)' \
    | grep -E '9\.3|10\.3' \
    | grep -v unavailable \
    | head -1 \
    | sed 's/.*(\([A-F0-9-]*\)).*/\1/')
if [[ -n "$DEFAULT_UDID" ]]; then
    DEFAULT_NAME=$(xcrun simctl list devices 2>/dev/null | grep "$DEFAULT_UDID" | head -1 | sed 's/ *\(.*\) (.*/\1/')
    xcrun simctl boot "$DEFAULT_UDID" 2>/dev/null || true
    echo "  Booted: $DEFAULT_NAME ($DEFAULT_UDID)"
    sleep 5
else
    echo "  WARNING: No legacy device found to boot."
fi

# --- Step 3: Kill existing Simulator.app ---
if pgrep -x Simulator >/dev/null 2>&1; then
    echo "Killing existing Simulator.app..."
    pkill -x Simulator 2>/dev/null || true
    sleep 2
fi

# --- Step 4: Launch Simulator.app with injection ---
echo "Launching Simulator.app with display injection..."
DYLD_FRAMEWORK_PATH="$DYLD_FW_PATH" \
DYLD_INSERT_LIBRARIES="$INJECT" \
"$SIMULATOR" &
SIM_PID=$!
echo "$SIM_PID" > "$PIDFILE_SIM"
sleep 3

if kill -0 "$SIM_PID" 2>/dev/null; then
    echo "  Simulator.app running (PID $SIM_PID)"
else
    echo "  WARNING: Simulator.app exited."
    SIM_PID=""
fi

# --- Ready ---
echo ""
echo "=== RosettaSim Ready ==="
echo ""
echo "  Boot any legacy device from Simulator's menu:"
echo "    File → Open Simulator → iPhone 6s (iOS 9.3)"
echo "    File → Open Simulator → iPad Pro (iOS 9.3)"
echo "    File → Open Simulator → iPhone 6s (10.3) (iOS 10.3)"
echo ""
echo "  Or from the command line:"
echo "    xcrun simctl boot <UDID>"
echo ""
echo "  Display appears automatically in the Simulator window."
echo "  Touch, keyboard, and hardware buttons all work."
echo ""
echo "  Stop: Ctrl-C or ./scripts/start_rosettasim.sh --stop"
echo ""

# Keep running until interrupted
wait "$DAEMON_PID" 2>/dev/null || true
