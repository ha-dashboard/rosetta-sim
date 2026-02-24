#!/bin/bash
#
# run_rosettasim.sh — Unified RosettaSim launcher
#
# Builds all components and launches the broker, which in turn
# spawns backboardd with the PurpleFBServer shim. CARenderServer
# ports are shared via the broker for app processes to connect.
#
# Usage:
#   ./scripts/run_rosettasim.sh --timeout <seconds>               # build + run
#   ./scripts/run_rosettasim.sh --timeout <seconds> --no-build    # run only (skip build)
#   ./scripts/run_rosettasim.sh --timeout <seconds> --background  # run in background
#   ./scripts/run_rosettasim.sh --timeout 0 ...                   # infinite (manual use only)
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

SDK_DEFAULT="/Applications/Xcode-8.3.3.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator10.3.sdk"
SDK="${ROSETTASIM_SDK:-$SDK_DEFAULT}"
BROKER="$PROJECT_ROOT/src/bridge/rosettasim_broker"
PFB="$PROJECT_ROOT/src/bridge/purple_fb_server.dylib"
APP_SHIM="$PROJECT_ROOT/src/bridge/app_shim.dylib"
usage() {
    echo "Usage: $0 --timeout <seconds> [--no-build] [--background]"
    echo ""
    echo "  --timeout <seconds>   Required. Non-negative integer seconds."
    echo "                        Use 0 for infinite (manual use only)."
    echo "  --no-build            Skip build step"
    echo "  --background          Run broker in background (log: /tmp/rosettasim.log)"
}

NO_BUILD=0
BACKGROUND=0
TIMEOUT_SECS=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-build) NO_BUILD=1; shift ;;
        --background) BACKGROUND=1; shift ;;
        --timeout|--timeout-seconds)
            if [[ $# -lt 2 ]]; then
                echo "ERROR: $1 requires a value" >&2
                usage
                exit 2
            fi
            TIMEOUT_SECS="$2"
            shift 2
            ;;
        --timeout=*|--timeout-seconds=*)
            TIMEOUT_SECS="${1#*=}"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "ERROR: Unknown argument: $1" >&2
            usage
            exit 2
            ;;
    esac
done

if [[ -z "$TIMEOUT_SECS" ]]; then
    echo "ERROR: --timeout <seconds> is required" >&2
    usage
    exit 2
fi

if ! [[ "$TIMEOUT_SECS" =~ ^[0-9]+$ ]]; then
    echo "ERROR: --timeout must be a non-negative integer (seconds). Got: '$TIMEOUT_SECS'" >&2
    exit 2
fi

if [[ "$TIMEOUT_SECS" -gt 0 ]]; then
    if ! command -v gtimeout >/dev/null 2>&1; then
        echo "ERROR: gtimeout not found. Install coreutils (e.g. 'brew install coreutils')." >&2
        exit 1
    fi
else
    echo "WARNING: --timeout 0 means infinite. Use only for manual interactive runs." >&2
fi

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
    if [[ "$TIMEOUT_SECS" -gt 0 ]]; then
        gtimeout -k 5 "${TIMEOUT_SECS}s" "$BROKER" --sdk "$SDK" --shim "$PFB" > /tmp/rosettasim.log 2>&1 &
    else
        "$BROKER" --sdk "$SDK" --shim "$PFB" > /tmp/rosettasim.log 2>&1 &
    fi
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
    if [[ "$TIMEOUT_SECS" -gt 0 ]]; then
        gtimeout -k 5 "${TIMEOUT_SECS}s" "$BROKER" --sdk "$SDK" --shim "$PFB"
    else
        exec "$BROKER" --sdk "$SDK" --shim "$PFB"
    fi
fi
