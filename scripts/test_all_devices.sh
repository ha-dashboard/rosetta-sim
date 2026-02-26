#!/bin/bash
#
# test_all_devices.sh — Boot every available iOS simulator device and verify rendering
#
# For each runtime, picks one iPhone device, boots it, checks for framebuffer
# activity (legacy) or successful boot (native), and optionally launches Safari.
#
# Prerequisites:
#   - rosettasim_daemon running (for legacy devices)
#   - tools built: make -C tools/display_bridge
#
# Usage:
#   ./scripts/test_all_devices.sh              # test all runtimes
#   ./scripts/test_all_devices.sh --legacy     # test only iOS 9.3/10.3

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

LEGACY_ONLY=0
[[ "${1:-}" == "--legacy" ]] && LEGACY_ONLY=1

BOOT_TIMEOUT=30
FLUSH_WAIT=15

# Results tracking
declare -a RESULTS_DEVICE
declare -a RESULTS_RUNTIME
declare -a RESULTS_STATUS
declare -a RESULTS_DETAIL
RESULT_COUNT=0

log() { echo "[test] $*"; }
pass() { RESULTS_STATUS[$RESULT_COUNT]="PASS"; RESULTS_DETAIL[$RESULT_COUNT]="$1"; }
fail() { RESULTS_STATUS[$RESULT_COUNT]="FAIL"; RESULTS_DETAIL[$RESULT_COUNT]="$1"; }
skip() { RESULTS_STATUS[$RESULT_COUNT]="SKIP"; RESULTS_DETAIL[$RESULT_COUNT]="$1"; }

# Check prerequisites
log "Checking prerequisites..."

DAEMON_PID=$(pgrep -f "rosettasim_daemon" 2>/dev/null | head -1)
if [[ -n "$DAEMON_PID" ]]; then
    log "  Daemon running (PID $DAEMON_PID)"
else
    log "  WARNING: rosettasim_daemon not running — legacy devices will fail"
fi

SIM_PID=$(pgrep -x "Simulator" 2>/dev/null | head -1)
if [[ -n "$SIM_PID" ]]; then
    log "  Simulator.app running (PID $SIM_PID)"
else
    log "  NOTE: Simulator.app not running — display injection unavailable"
fi

# Get all runtimes
log ""
log "Discovering runtimes..."

RUNTIMES=$(xcrun simctl list runtimes 2>/dev/null | grep -E '^iOS' | sed 's/ (.*//')
echo "$RUNTIMES" | while read -r rt; do log "  $rt"; done

# For each runtime, find a test device and run
while IFS= read -r RUNTIME_LINE; do
    [[ -z "$RUNTIME_LINE" ]] && continue

    # Extract runtime name and identifier
    RT_NAME=$(echo "$RUNTIME_LINE" | sed 's/ (.*//')
    RT_ID=$(xcrun simctl list runtimes 2>/dev/null | grep "$RT_NAME" | sed 's/.*- //')

    # Filter legacy-only if requested
    if [[ "$LEGACY_ONLY" -eq 1 ]]; then
        if ! echo "$RT_ID" | grep -qE 'iOS-9|iOS-10'; then
            continue
        fi
    fi

    IS_LEGACY=0
    echo "$RT_ID" | grep -qE 'iOS-9|iOS-10' && IS_LEGACY=1

    # Find a device: parse section under "-- $RT_NAME --" header
    UDID=""
    DEVICE_NAME=""

    # Extract devices under this runtime's section
    SECTION=$(xcrun simctl list devices 2>/dev/null \
        | sed -n "/-- ${RT_NAME} --/,/^--/p" \
        | grep -v '^--' \
        | grep -v unavailable)

    for pattern in "iPhone 6s" "iPhone 6" "iPhone" "iPad"; do
        LINE=$(echo "$SECTION" | grep "$pattern" | head -1)
        if [[ -n "$LINE" ]]; then
            UDID=$(echo "$LINE" | sed 's/.*(\([A-F0-9-]*\)).*/\1/')
            DEVICE_NAME=$(echo "$LINE" | sed 's/ *\(.*\) (.*/\1/')
            break
        fi
    done

    if [[ -z "$UDID" ]]; then
        RESULTS_DEVICE[$RESULT_COUNT]="(none)"
        RESULTS_RUNTIME[$RESULT_COUNT]="$RT_NAME"
        skip "No device found for runtime"
        RESULT_COUNT=$((RESULT_COUNT + 1))
        continue
    fi

    RESULTS_DEVICE[$RESULT_COUNT]="$DEVICE_NAME"
    RESULTS_RUNTIME[$RESULT_COUNT]="$RT_NAME"

    log ""
    log "=== $RT_NAME: $DEVICE_NAME ($UDID) ==="
    log "  Legacy: $([[ $IS_LEGACY -eq 1 ]] && echo YES || echo NO)"

    # Ensure shutdown
    xcrun simctl shutdown "$UDID" 2>/dev/null || true
    sleep 1

    # Boot
    log "  Booting..."
    if ! xcrun simctl boot "$UDID" 2>/dev/null; then
        fail "Boot failed"
        RESULT_COUNT=$((RESULT_COUNT + 1))
        continue
    fi

    # Wait for boot (state=3)
    BOOTED=0
    for i in $(seq 1 $BOOT_TIMEOUT); do
        STATE=$(xcrun simctl list devices 2>/dev/null | grep "$UDID" | grep -c "Booted")
        if [[ "$STATE" -gt 0 ]]; then
            BOOTED=1
            break
        fi
        sleep 1
    done

    if [[ "$BOOTED" -eq 0 ]]; then
        fail "Boot timeout (${BOOT_TIMEOUT}s)"
        xcrun simctl shutdown "$UDID" 2>/dev/null || true
        RESULT_COUNT=$((RESULT_COUNT + 1))
        continue
    fi
    log "  Booted in ${i}s"

    # For legacy devices: check daemon flushes
    if [[ "$IS_LEGACY" -eq 1 ]]; then
        log "  Waiting ${FLUSH_WAIT}s for framebuffer flushes..."
        sleep "$FLUSH_WAIT"

        # Check daemon log for this device
        FB_FILE="/tmp/rosettasim_fb_${UDID}.raw"
        if [[ -f "$FB_FILE" ]]; then
            FB_SIZE=$(wc -c < "$FB_FILE" 2>/dev/null || echo 0)
            log "  Framebuffer: $FB_SIZE bytes"

            if [[ "$FB_SIZE" -gt 100000 ]]; then
                # Try launching Safari
                log "  Attempting openurl..."
                if xcrun simctl openurl "$UDID" "https://apple.com" 2>/dev/null; then
                    pass "Boot OK, FB ${FB_SIZE}B, openurl OK"
                else
                    pass "Boot OK, FB ${FB_SIZE}B, openurl FAILED (expected for legacy)"
                fi
            else
                fail "Framebuffer too small ($FB_SIZE bytes)"
            fi
        else
            # Check shared framebuffer
            if [[ -f /tmp/sim_framebuffer.raw ]]; then
                FB_SIZE=$(wc -c < /tmp/sim_framebuffer.raw)
                pass "Boot OK, shared FB ${FB_SIZE}B"
            else
                fail "No framebuffer file (daemon not handling?)"
            fi
        fi
    else
        # Native runtime: just verify it booted
        sleep 5
        log "  Attempting openurl..."
        if xcrun simctl openurl "$UDID" "https://apple.com" 2>/dev/null; then
            pass "Boot OK, openurl OK"
        else
            pass "Boot OK (openurl may need more time)"
        fi
    fi

    # Shutdown
    log "  Shutting down..."
    xcrun simctl shutdown "$UDID" 2>/dev/null || true
    sleep 2

    RESULT_COUNT=$((RESULT_COUNT + 1))

done <<< "$(xcrun simctl list runtimes 2>/dev/null | grep -E '^iOS')"

# Summary
log ""
log "========================================="
log "  TEST SUMMARY"
log "========================================="

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

for i in $(seq 0 $((RESULT_COUNT - 1))); do
    STATUS="${RESULTS_STATUS[$i]}"
    ICON="?"
    case "$STATUS" in
        PASS) ICON="✅"; PASS_COUNT=$((PASS_COUNT + 1)) ;;
        FAIL) ICON="❌"; FAIL_COUNT=$((FAIL_COUNT + 1)) ;;
        SKIP) ICON="⏭️"; SKIP_COUNT=$((SKIP_COUNT + 1)) ;;
    esac
    printf "  %s %-12s %-20s %s\n" "$ICON" "${RESULTS_RUNTIME[$i]}" "${RESULTS_DEVICE[$i]}" "${RESULTS_DETAIL[$i]}"
done

log ""
log "  PASS: $PASS_COUNT  FAIL: $FAIL_COUNT  SKIP: $SKIP_COUNT  TOTAL: $RESULT_COUNT"
log "========================================="

[[ "$FAIL_COUNT" -eq 0 ]] && exit 0 || exit 1
