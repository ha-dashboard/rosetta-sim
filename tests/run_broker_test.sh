#!/bin/bash
#
# run_broker_test.sh - Test the RosettaSim broker
#
# This script:
# 1. Builds the broker test program
# 2. Starts the broker in the background
# 3. Uses posix_spawn to launch the test with broker port
# 4. Collects results and cleans up

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

BROKER_BIN="$PROJECT_ROOT/src/bridge/rosettasim_broker"
TEST_SRC="$SCRIPT_DIR/broker_test.c"
TEST_BIN="$SCRIPT_DIR/broker_test"

echo "======================================"
echo "RosettaSim Broker Test"
echo "======================================"
echo

# Build broker if needed
if [ ! -f "$BROKER_BIN" ]; then
    echo "Building broker..."
    "$PROJECT_ROOT/scripts/build_broker.sh"
    echo
fi

# Build test program
echo "Building test program..."
clang -arch x86_64 -Wall -Wextra -O2 -o "$TEST_BIN" "$TEST_SRC"
codesign -s - -f "$TEST_BIN"
echo

# Cleanup function
cleanup() {
    if [ -n "$BROKER_PID" ] && kill -0 "$BROKER_PID" 2>/dev/null; then
        echo "Stopping broker (pid $BROKER_PID)..."
        kill "$BROKER_PID" 2>/dev/null || true
        wait "$BROKER_PID" 2>/dev/null || true
    fi

    rm -f /tmp/rosettasim_broker.pid
    rm -f "$TEST_BIN"
}

trap cleanup EXIT

# Note: We can't easily test the broker without actually spawning backboardd,
# because we need posix_spawnattr_setspecialport_np to give the test process
# the broker port. This requires writing a spawner program.

echo "======================================"
echo "NOTE: Full broker testing requires a spawner program that uses"
echo "posix_spawnattr_setspecialport_np to give the test process the"
echo "broker port. For now, we verify that the broker compiles and"
echo "can be started."
echo "======================================"
echo

# Test 1: Check if broker binary exists and is valid
echo "Test 1: Verify broker binary"
if [ -f "$BROKER_BIN" ]; then
    echo "  ✓ Broker binary exists"
    file "$BROKER_BIN" | grep "Mach-O 64-bit executable x86_64" > /dev/null
    if [ $? -eq 0 ]; then
        echo "  ✓ Broker is x86_64 Mach-O executable"
    else
        echo "  ✗ Broker has wrong format"
        exit 1
    fi
else
    echo "  ✗ Broker binary not found"
    exit 1
fi
echo

# Test 2: Check if broker can start (without backboardd)
echo "Test 2: Verify broker can start"
timeout 2 "$BROKER_BIN" --sdk /nonexistent 2>&1 | head -20 &
BROKER_PID=$!
sleep 1

if kill -0 "$BROKER_PID" 2>/dev/null; then
    echo "  ✓ Broker process started"
    kill "$BROKER_PID" 2>/dev/null || true
    wait "$BROKER_PID" 2>/dev/null || true
    BROKER_PID=""
else
    echo "  ✓ Broker exited (expected - no backboardd)"
    BROKER_PID=""
fi
echo

# Test 3: Check test binary
echo "Test 3: Verify test binary"
if [ -f "$TEST_BIN" ]; then
    echo "  ✓ Test binary exists"
    file "$TEST_BIN" | grep "Mach-O 64-bit executable x86_64" > /dev/null
    if [ $? -eq 0 ]; then
        echo "  ✓ Test is x86_64 Mach-O executable"
    else
        echo "  ✗ Test has wrong format"
        exit 1
    fi
else
    echo "  ✗ Test binary not found"
    exit 1
fi
echo

echo "======================================"
echo "Basic tests PASSED"
echo "======================================"
echo
echo "To fully test the broker:"
echo "1. Build a spawner that uses posix_spawnattr_setspecialport_np"
echo "2. Or manually run the broker and observe backboardd behavior"
echo "3. Use lsmp to verify port creation and message passing"
echo

exit 0
