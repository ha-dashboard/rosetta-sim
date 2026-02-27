#!/bin/bash
#
# test_all_devices.sh — Boot every available legacy iOS simulator and verify rendering
#
# For each legacy runtime, picks one iPhone device, boots it, checks framebuffer.
# Leaves the last device booted so the user can see it in Simulator.app.
#
# Prerequisites:
#   - rosettasim_daemon running (starts automatically if not)
#   - tools built: make -C src
#
# Usage:
#   ./scripts/test_all_devices.sh              # test all legacy runtimes
#   ./scripts/test_all_devices.sh --all        # include native runtimes too

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TOOLS="$PROJECT_ROOT/src/build"

TEST_ALL=0
[[ "${1:-}" == "--all" ]] && TEST_ALL=1

BOOT_TIMEOUT=30
FLUSH_WAIT=20

declare -a R_DEV R_RT R_ST R_DT
RC=0

log() { echo "[test] $*"; }

# Ensure daemon is running
if ! pgrep -f "rosettasim_daemon" > /dev/null 2>&1; then
    log "Starting daemon..."
    "$TOOLS/rosettasim_daemon" > /tmp/daemon_test.log 2>&1 &
    sleep 3
fi
DAEMON_PID=$(pgrep -f "rosettasim_daemon" | head -1)
log "Daemon: PID $DAEMON_PID"

# Ensure Simulator.app with injection is running
if ! pgrep -x "Simulator" > /dev/null 2>&1; then
    log "Starting Simulator.app with injection..."
    DYLD_FRAMEWORK_PATH="/Applications/Xcode.app/Contents/Developer/Library/PrivateFrameworks:/Library/Developer/PrivateFrameworks" \
    DYLD_INSERT_LIBRARIES="$TOOLS/sim_display_inject.dylib" \
    /tmp/Simulator_nolv.app/Contents/MacOS/Simulator > /tmp/sim_test.log 2>&1 &
    sleep 5
fi
SIM_PID=$(pgrep -x "Simulator" | head -1)
[[ -n "$SIM_PID" ]] && log "Simulator.app: PID $SIM_PID" || log "WARNING: Simulator.app not running"

# Discover runtimes
log ""
log "Discovering legacy runtimes..."
LAST_BOOTED_UDID=""

while IFS= read -r RUNTIME_LINE; do
    [[ -z "$RUNTIME_LINE" ]] && continue
    RT_NAME=$(echo "$RUNTIME_LINE" | sed 's/ (.*//')
    RT_ID=$(xcrun simctl list runtimes 2>/dev/null | grep "$RT_NAME" | sed 's/.*- //')

    IS_LEGACY=0
    echo "$RT_ID" | grep -qE 'iOS-9|iOS-10' && IS_LEGACY=1

    if [[ "$TEST_ALL" -eq 0 ]] && [[ "$IS_LEGACY" -eq 0 ]]; then
        continue
    fi

    # Find device
    SECTION=$(xcrun simctl list devices 2>/dev/null \
        | sed -n "/-- ${RT_NAME} --/,/^--/p" \
        | grep -v '^--' \
        | grep -v unavailable)

    UDID="" DEVICE_NAME=""
    for pat in "iPhone 6s" "iPhone 6" "iPhone" "iPad"; do
        LINE=$(echo "$SECTION" | grep "$pat" | head -1)
        if [[ -n "$LINE" ]]; then
            UDID=$(echo "$LINE" | sed 's/.*(\([A-F0-9-]*\)).*/\1/')
            DEVICE_NAME=$(echo "$LINE" | sed 's/ *\(.*\) (.*/\1/')
            break
        fi
    done

    R_DEV[$RC]="${DEVICE_NAME:-(none)}"
    R_RT[$RC]="$RT_NAME"

    if [[ -z "$UDID" ]]; then
        R_ST[$RC]="SKIP"; R_DT[$RC]="No device"
        RC=$((RC+1)); continue
    fi

    log ""
    log "=== $RT_NAME: $DEVICE_NAME ($UDID) ==="

    # Shutdown previous device (except keep going)
    if [[ -n "$LAST_BOOTED_UDID" ]]; then
        xcrun simctl shutdown "$LAST_BOOTED_UDID" 2>/dev/null || true
        sleep 1
    fi

    # Boot
    xcrun simctl shutdown "$UDID" 2>/dev/null || true
    sleep 1
    log "  Booting..."
    if ! xcrun simctl boot "$UDID" 2>/dev/null; then
        R_ST[$RC]="FAIL"; R_DT[$RC]="Boot failed"
        RC=$((RC+1)); continue
    fi

    # Wait for Booted state
    BOOTED=0
    for i in $(seq 1 $BOOT_TIMEOUT); do
        if xcrun simctl list devices 2>/dev/null | grep "$UDID" | grep -q "Booted"; then
            BOOTED=1; break
        fi
        sleep 1
    done
    if [[ "$BOOTED" -eq 0 ]]; then
        R_ST[$RC]="FAIL"; R_DT[$RC]="Boot timeout"
        xcrun simctl shutdown "$UDID" 2>/dev/null || true
        RC=$((RC+1)); continue
    fi
    log "  Booted in ${i}s"

    if [[ "$IS_LEGACY" -eq 1 ]]; then
        log "  Waiting ${FLUSH_WAIT}s for rendering..."
        sleep "$FLUSH_WAIT"

        FB_FILE="/tmp/rosettasim_fb_${UDID}.raw"
        FB_SHARED="/tmp/sim_framebuffer.raw"
        FB=""
        [[ -f "$FB_FILE" ]] && FB="$FB_FILE"
        [[ -z "$FB" ]] && [[ -f "$FB_SHARED" ]] && FB="$FB_SHARED"

        if [[ -n "$FB" ]]; then
            FB_SIZE=$(wc -c < "$FB" 2>/dev/null || echo 0)
            # Count non-zero pixels (sample every 16th)
            NZ=$(python3 -c "
d=open('$FB','rb').read()
w,h=750,1334
nz=sum(1 for i in range(0,len(d),64) if d[i]|d[i+1]|d[i+2])
print(nz)" 2>/dev/null || echo 0)
            log "  FB: ${FB_SIZE}B, ~${NZ} non-zero (sampled)"
            if [[ "$FB_SIZE" -gt 100000 ]]; then
                R_ST[$RC]="PASS"; R_DT[$RC]="FB ${FB_SIZE}B, nz~${NZ}"
            else
                R_ST[$RC]="FAIL"; R_DT[$RC]="FB too small (${FB_SIZE}B)"
            fi
        else
            R_ST[$RC]="FAIL"; R_DT[$RC]="No framebuffer file"
        fi
    else
        sleep 5
        # Native: just check it booted
        R_ST[$RC]="PASS"; R_DT[$RC]="Booted (native)"
    fi

    LAST_BOOTED_UDID="$UDID"
    RC=$((RC+1))

done <<< "$(xcrun simctl list runtimes 2>/dev/null | grep -E '^iOS')"

# Leave last device booted for user to see
if [[ -n "$LAST_BOOTED_UDID" ]]; then
    log ""
    log "Left device $LAST_BOOTED_UDID booted for visual inspection."
fi

# Ensure Simulator.app still running
if ! pgrep -x "Simulator" > /dev/null 2>&1; then
    log "Re-launching Simulator.app..."
    DYLD_FRAMEWORK_PATH="/Applications/Xcode.app/Contents/Developer/Library/PrivateFrameworks:/Library/Developer/PrivateFrameworks" \
    DYLD_INSERT_LIBRARIES="$TOOLS/sim_display_inject.dylib" \
    /tmp/Simulator_nolv.app/Contents/MacOS/Simulator > /tmp/sim_test.log 2>&1 &
    sleep 5
fi

# Summary
log ""
log "========================================="
log "  TEST SUMMARY"
log "========================================="
P=0 F=0 S=0
for i in $(seq 0 $((RC-1))); do
    ST="${R_ST[$i]}"
    case "$ST" in PASS) P=$((P+1));; FAIL) F=$((F+1));; SKIP) S=$((S+1));; esac
    IC="?"; [[ "$ST" == "PASS" ]] && IC="OK"; [[ "$ST" == "FAIL" ]] && IC="XX"; [[ "$ST" == "SKIP" ]] && IC="--"
    printf "  [%s] %-12s %-24s %s\n" "$IC" "${R_RT[$i]}" "${R_DEV[$i]}" "${R_DT[$i]}"
done
log ""
log "  PASS=$P  FAIL=$F  SKIP=$S  TOTAL=$RC"
log "========================================="
