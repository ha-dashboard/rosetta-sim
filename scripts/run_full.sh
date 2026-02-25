#!/bin/bash
#
# run_full.sh — Launch complete RosettaSim pipeline
#
# Starts broker (which spawns backboardd + app) and host app together.
# The host app displays the app's framebuffer and sends touch/keyboard input.
#
# Usage:
#   ./scripts/run_full.sh --timeout <seconds> [app_path]
#   ./scripts/run_full.sh --timeout <seconds>            # defaults to hass-dashboard
#   ./scripts/run_full.sh --timeout 0 [app_path]         # infinite (manual use only)
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Paths
SDK_DEFAULT="/Applications/Xcode-8.3.3.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator10.3.sdk"
SDK="${ROSETTASIM_SDK:-$SDK_DEFAULT}"
BROKER="$PROJECT_ROOT/src/bridge/rosettasim_broker"
PFB="$PROJECT_ROOT/src/bridge/purple_fb_server.dylib"
BRIDGE="$PROJECT_ROOT/src/bridge/rosettasim_bridge.dylib"
BFIX="$PROJECT_ROOT/src/bridge/bootstrap_fix.dylib"
HOST_APP="$PROJECT_ROOT/src/host/RosettaSimApp/build/RosettaSim"
usage() {
    echo "Usage: $0 --timeout <seconds> [app_path]"
    echo ""
    echo "  --timeout <seconds>   Required. Non-negative integer seconds."
    echo "                        Use 0 for infinite (manual use only)."
}

TIMEOUT_SECS=""
WRAPPED=0
# Default app
APP_PATH=""
APP_PATH_DEFAULT="/Users/ashhopkins/Projects/hass-dashboard/build/rosettasim/Build/Products/Debug-iphonesimulator/HA Dashboard.app"

while [[ $# -gt 0 ]]; do
    case "$1" in
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
        --wrapped)
            WRAPPED=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            break
            ;;
        -*)
            echo "ERROR: Unknown option: $1" >&2
            usage
            exit 2
            ;;
        *)
            if [[ -z "$APP_PATH" ]]; then
                APP_PATH="$1"
                shift
            else
                echo "ERROR: Unexpected argument: $1" >&2
                usage
                exit 2
            fi
            ;;
    esac
done

if [[ -z "$APP_PATH" ]]; then
    APP_PATH="$APP_PATH_DEFAULT"
fi

if [[ -z "$TIMEOUT_SECS" ]]; then
    echo "ERROR: --timeout <seconds> is required" >&2
    usage
    exit 2
fi

if ! [[ "$TIMEOUT_SECS" =~ ^[0-9]+$ ]]; then
    echo "ERROR: --timeout must be a non-negative integer (seconds). Got: '$TIMEOUT_SECS'" >&2
    exit 2
fi

if [[ "$TIMEOUT_SECS" -gt 0 && "$WRAPPED" -eq 0 ]]; then
    if ! command -v gtimeout >/dev/null 2>&1; then
        echo "ERROR: gtimeout not found. Install coreutils (e.g. 'brew install coreutils')." >&2
        exit 1
    fi
    exec gtimeout -k 5 "${TIMEOUT_SECS}s" "$0" --wrapped --timeout "$TIMEOUT_SECS" "$APP_PATH"
fi

if [[ "$TIMEOUT_SECS" -eq 0 ]]; then
    echo "WARNING: --timeout 0 means infinite. Use only for manual interactive runs." >&2
fi

# App framebuffer (separate from backboardd's)
APP_FB="/tmp/rosettasim_app_framebuffer"
GPU_FB="/tmp/rosettasim_framebuffer_gpu"

# Build if needed
echo "========================================"
echo " RosettaSim — Full Pipeline"
echo "========================================"
echo "Ensuring bootstrap_fix.dylib is fresh..."
bash "$SCRIPT_DIR/build_bootstrap_fix.sh"

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
echo "Bootstrap: $BFIX"
echo "App FB:    $APP_FB"
echo "Timeout:   ${TIMEOUT_SECS}s"
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
    rm -f /tmp/rosettasim_broker.pid "$APP_FB" "$GPU_FB" /tmp/rosettasim_framebuffer
    echo "Done."
}
trap cleanup EXIT
trap 'exit 0' INT TERM

# Clean old state
rm -f "$APP_FB" "$GPU_FB" /tmp/rosettasim_framebuffer /tmp/rosettasim_broker.pid

# Start broker (spawns backboardd + app)
echo "Starting broker..."
"$BROKER" \
    --sdk "$SDK" \
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
    # Only fall back to GPU framebuffer if app FB doesn't appear after 30s
    if [[ $i -gt 60 ]] && [[ -f "$GPU_FB" ]]; then
        APP_FB="$GPU_FB"
        echo "GPU framebuffer ready (app FB not found after 30s)."
        break
    fi
    sleep 0.5
done

if [[ ! -f "$APP_FB" ]]; then
    echo "ERROR: Framebuffer not created after 60s"
    echo "Check: tail -f /tmp/rosettasim_broker.log"
    # Don't exit — try GPU framebuffer, then backboardd framebuffer
    if [[ -f "$GPU_FB" ]]; then
        echo "Using GPU framebuffer instead..."
        APP_FB="$GPU_FB"
    else
        echo "Trying with backboardd framebuffer instead..."
        APP_FB="/tmp/rosettasim_framebuffer"
        if [[ ! -f "$APP_FB" ]]; then
            echo "No framebuffer at all — check logs"
            exit 1
        fi
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
if [[ "$TIMEOUT_SECS" -gt 0 ]]; then
    echo "This run will auto-stop after ${TIMEOUT_SECS}s."
else
    echo "Press Ctrl+C to stop."
fi

# Wait for either process to exit
wait $HOST_PID 2>/dev/null || true
