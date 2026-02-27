#!/bin/bash
#
# start_rosettasim.sh — One-command launcher for RosettaSim daemon + Simulator.app
#
# Starts the daemon (auto-manages all legacy devices), launches re-signed
# Simulator.app with display injection, and boots one device per installed
# iOS runtime.
#
# Usage:
#   ./scripts/start_rosettasim.sh                  # start everything (iPhones)
#   ./scripts/start_rosettasim.sh --ipad           # boot iPads instead
#   ./scripts/start_rosettasim.sh --clean          # terminate all sims first
#   ./scripts/start_rosettasim.sh --clean --ipad   # both
#   ./scripts/start_rosettasim.sh --stop           # stop everything
#   ./scripts/start_rosettasim.sh --list           # list available devices
#
# Prerequisites:
#   Run scripts/setup.sh first.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

DAEMON="$PROJECT_ROOT/src/build/rosettasim_daemon"
INJECT="$PROJECT_ROOT/src/build/sim_display_inject.dylib"
FRONTBOARD_FIX="$PROJECT_ROOT/src/build/ios8_frontboard_fix.dylib"
SIMULATOR="/tmp/Simulator_nolv.app/Contents/MacOS/Simulator"
DYLD_FW_PATH="/Applications/Xcode.app/Contents/Developer/Library/PrivateFrameworks:/Library/Developer/PrivateFrameworks"

PIDFILE_DAEMON="/tmp/rosettasim_daemon.pid"
PIDFILE_SIM="/tmp/rosettasim_simulator.pid"

# --- Parse arguments ---
CLEAN=false
DEVICE_TYPE="iPhone"
STOP=false
LIST=false

for arg in "$@"; do
    case "$arg" in
        --stop|stop)     STOP=true ;;
        --clean)         CLEAN=true ;;
        --ipad)          DEVICE_TYPE="iPad" ;;
        --list)          LIST=true ;;
    esac
done

# --- Stop mode ---
if $STOP; then
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
    xcrun simctl shutdown all 2>/dev/null || true
    rm -f /tmp/rosettasim_*.json /tmp/rosettasim_fb_*.raw /tmp/sim_framebuffer.raw
    echo "Done."
    exit 0
fi

# --- Runtimes we support ---
# Each entry: "version|preferred_iphone|preferred_ipad|needs_shim"
# needs_shim: frontboard = iOS 8.2 FrontBoard fix
SUPPORTED_RUNTIMES=(
    "7.0|iPhone 5s|iPad Air|none"
    "8.2|iPhone 6|iPad Air 2|frontboard"
    "9.3|iPhone 6s|iPad Pro (9.7-inch)|none"
    "10.3|iPhone 6s|iPad Pro (12.9-inch) (2nd generation)|none"
    "12.4|iPhone 7|iPad (6th generation)|none"
    "13.7|iPhone 11|iPad Air (3rd generation)|none"
)

# --- List mode ---
if $LIST; then
    echo "Supported iOS runtimes and preferred devices:"
    echo ""
    printf "  %-8s %-10s %-40s %s\n" "iOS" "Status" "Device ($DEVICE_TYPE)" "Shim"
    printf "  %-8s %-10s %-40s %s\n" "---" "------" "------" "----"
    for entry in "${SUPPORTED_RUNTIMES[@]}"; do
        IFS='|' read -r ver iphone ipad shim <<< "$entry"
        if [ "$DEVICE_TYPE" = "iPad" ]; then dev="$ipad"; else dev="$iphone"; fi
        # Check if runtime is available
        status="missing"
        if xcrun simctl list runtimes 2>/dev/null | grep -q "iOS $ver "; then
            if xcrun simctl list runtimes 2>/dev/null | grep "iOS $ver " | grep -q unavailable; then
                status="unavail"
            else
                status="ready"
            fi
        fi
        printf "  %-8s %-10s %-40s %s\n" "$ver" "$status" "$dev" "$shim"
    done
    echo ""
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

# --- Clean mode: shutdown all simulators first ---
if $CLEAN; then
    echo "Cleaning up existing simulators..."
    xcrun simctl shutdown all 2>/dev/null || true
    pkill -f rosettasim_daemon 2>/dev/null || true
    pkill -x Simulator 2>/dev/null || true
    rm -f /tmp/rosettasim_*.json /tmp/rosettasim_fb_*.raw /tmp/sim_framebuffer.raw
    sleep 2
    echo "  All simulators shut down."
fi

# --- Step 1: Boot one device per installed runtime ---
# Boot BEFORE starting daemon — daemon scans on startup and registers
# PurpleFBServer for all devices it finds (booted or not).
echo "Booting devices ($DEVICE_TYPE)..."

find_and_boot_device() {
    local ios_ver="$1"
    local preferred_name="$2"
    local shim="$3"

    # Check runtime exists and is available
    if ! xcrun simctl list runtimes 2>/dev/null | grep -q "iOS $ios_ver "; then
        echo "  iOS $ios_ver: runtime not installed — skipping"
        return
    fi
    if xcrun simctl list runtimes 2>/dev/null | grep "iOS $ios_ver " | grep -q unavailable; then
        echo "  iOS $ios_ver: runtime unavailable — skipping"
        return
    fi

    local runtime_id="com.apple.CoreSimulator.SimRuntime.iOS-${ios_ver//./-}"

    # Find existing device matching preferred name, or any device for this runtime
    local udid=""
    local name=""

    # Try preferred device name first (Shutdown or Booted, not transitional)
    udid=$(xcrun simctl list devices "$runtime_id" 2>/dev/null \
        | grep -E "(Shutdown|Booted)" \
        | grep "$preferred_name" \
        | grep -oE '[A-F0-9-]{36}' \
        | head -1) || true

    if [[ -z "$udid" ]]; then
        # Try any device of the right type (iPhone or iPad)
        udid=$(xcrun simctl list devices "$runtime_id" 2>/dev/null \
            | grep -E "(Shutdown|Booted)" \
            | grep "$DEVICE_TYPE" \
            | grep -oE '[A-F0-9-]{36}' \
            | head -1) || true
    fi

    if [[ -z "$udid" ]]; then
        # Create a new device
        echo "  iOS $ios_ver: creating $preferred_name..."
        udid=$(xcrun simctl create "$preferred_name ($ios_ver)" "$preferred_name" "$runtime_id" 2>/dev/null) || true
        if [[ -z "$udid" ]]; then
            echo "  iOS $ios_ver: could not create device — skipping"
            return
        fi
    fi

    name=$(xcrun simctl list devices 2>/dev/null | grep "$udid" | head -1 | sed 's/^ *//;s/ (.*//')

    # Check if already booted
    if xcrun simctl list devices 2>/dev/null | grep "$udid" | grep -q Booted; then
        echo "  iOS $ios_ver: $name already booted"
        return
    fi

    # Apply shim env vars if needed
    local boot_env=""
    if [[ "$shim" == "frontboard" ]] && [[ -f "$FRONTBOARD_FIX" ]]; then
        local runtime_root
        runtime_root="$HOME/Library/Developer/CoreSimulator/Profiles/Runtimes/iOS_${ios_ver}.simruntime/Contents/Resources/RuntimeRoot"
        # Copy fix dylib into runtime if needed
        if [[ ! -f "$runtime_root/usr/lib/ios8_frontboard_fix.dylib" ]]; then
            cp "$FRONTBOARD_FIX" "$runtime_root/usr/lib/" 2>/dev/null || true
        fi
        boot_env="SIMCTL_CHILD_DYLD_INSERT_LIBRARIES=$runtime_root/usr/lib/ios8_frontboard_fix.dylib"
    fi

    # Boot
    if [[ -n "$boot_env" ]]; then
        env $boot_env xcrun simctl boot "$udid" 2>/dev/null && \
            echo "  iOS $ios_ver: $name booted (with ${shim} fix)" || \
            echo "  iOS $ios_ver: $name FAILED to boot"
    else
        xcrun simctl boot "$udid" 2>/dev/null && \
            echo "  iOS $ios_ver: $name booted" || \
            echo "  iOS $ios_ver: $name FAILED to boot"
    fi
}

for entry in "${SUPPORTED_RUNTIMES[@]}"; do
    IFS='|' read -r ver iphone ipad shim <<< "$entry"
    if [ "$DEVICE_TYPE" = "iPad" ]; then
        find_and_boot_device "$ver" "$ipad" "$shim"
    else
        find_and_boot_device "$ver" "$iphone" "$shim"
    fi
done

# Wait for devices to settle
echo ""
echo "Waiting for devices to initialize..."
sleep 5

# --- Step 2: Start daemon (after devices are booted) ---
# Daemon scans all devices on startup and registers PurpleFBServer
# for legacy runtimes. Starting after boot ensures it sees booted devices.
if pgrep -f rosettasim_daemon >/dev/null 2>&1; then
    echo "Daemon already running (PID $(pgrep -f rosettasim_daemon | head -1)). Restarting..."
    pkill -f rosettasim_daemon 2>/dev/null || true
    sleep 2
fi

echo "Starting RosettaSim daemon..."
"$DAEMON" &
DAEMON_PID=$!
echo "$DAEMON_PID" > "$PIDFILE_DAEMON"
sleep 5

if ! kill -0 "$DAEMON_PID" 2>/dev/null; then
    echo "ERROR: Daemon failed to start."
    exit 1
fi
echo "  Daemon running (PID $DAEMON_PID)"

# --- Step 3: Launch Simulator.app with injection ---
if pgrep -x Simulator >/dev/null 2>&1; then
    echo "Killing existing Simulator.app..."
    pkill -x Simulator 2>/dev/null || true
    sleep 2
fi

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

# --- Summary ---
echo ""
echo "=== RosettaSim Ready ==="
echo ""
echo "  Booted devices:"
xcrun simctl list devices 2>/dev/null | grep Booted | sed 's/^/    /'
echo ""
echo "  Stop: Ctrl-C or ./scripts/start_rosettasim.sh --stop"
echo ""

# Keep running until interrupted — daemon stays in foreground
cleanup() {
    echo ""
    echo "Stopping RosettaSim..."
    [[ -n "${SIM_PID:-}" ]] && kill "$SIM_PID" 2>/dev/null || true
    kill "$DAEMON_PID" 2>/dev/null || true
    rm -f "$PIDFILE_DAEMON" "$PIDFILE_SIM"
    # Don't shutdown devices on exit — let user decide
    echo "Daemon and Simulator stopped. Devices still booted."
    echo "  To shutdown all: xcrun simctl shutdown all"
    echo "  To restart: ./scripts/start_rosettasim.sh"
}
trap cleanup EXIT INT TERM

wait "$DAEMON_PID" 2>/dev/null || true
