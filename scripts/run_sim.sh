#!/bin/bash
#
# run_sim.sh - Launch a RosettaSim simulated process
#
# Sets up the environment and launches an x86_64 simulator binary with
# the iOS 10.3 SDK frameworks, bridge library injection, and a fake
# home directory. The binary runs under Rosetta 2 on Apple Silicon.
#
# IMPORTANT: The binary is launched directly (NOT via arch -x86_64).
# The arch wrapper strips DYLD_* environment variables due to SIP
# protection. Rosetta 2 activates automatically for x86_64 binaries.
#
# Usage:
#   ./scripts/run_sim.sh                          # runs default test (phase4b_text)
#   ./scripts/run_sim.sh ./tests/phase3_test      # runs a specific binary
#   ./scripts/run_sim.sh ./tests/phase2_test      # runs phase 2 test
#   ./scripts/run_sim.sh /path/to/any_x86_64_sim_binary
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ================================================================
# SDK and bridge paths
# ================================================================

SDK="/Applications/Xcode-8.3.3.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator10.3.sdk"
BRIDGE="$PROJECT_ROOT/src/bridge/rosettasim_bridge.dylib"

# ================================================================
# Determine which binary to run
# ================================================================

if [[ $# -ge 1 ]]; then
    TARGET_BIN="$1"
    shift
else
    TARGET_BIN="$PROJECT_ROOT/tests/phase4b_text"
fi

# Resolve relative paths
if [[ ! "$TARGET_BIN" = /* ]]; then
    TARGET_BIN="$PROJECT_ROOT/$TARGET_BIN"
fi

# ================================================================
# Preflight checks
# ================================================================

if [[ ! -d "$SDK" ]]; then
    echo "ERROR: iOS 10.3 simulator SDK not found at:"
    echo "  $SDK"
    echo ""
    echo "Install Xcode 8.3.3 to /Applications/Xcode-8.3.3.app"
    exit 1
fi

if [[ ! -f "$TARGET_BIN" ]]; then
    echo "ERROR: Target binary not found: $TARGET_BIN"
    exit 1
fi

if [[ ! -x "$TARGET_BIN" ]]; then
    echo "ERROR: Target binary is not executable: $TARGET_BIN"
    exit 1
fi

# Verify it's an x86_64 binary
BINARY_ARCH="$(file "$TARGET_BIN" 2>/dev/null || true)"
if [[ ! "$BINARY_ARCH" == *"x86_64"* ]]; then
    echo "WARNING: Binary does not appear to be x86_64:"
    echo "  $BINARY_ARCH"
    echo "  RosettaSim requires x86_64 simulator binaries."
    echo ""
fi

# ================================================================
# Build/verify bridge library
# ================================================================

if [[ ! -f "$BRIDGE" ]] || ! codesign -v "$BRIDGE" 2>/dev/null; then
    echo "Bridge library missing or unsigned. Building..."
    "$SCRIPT_DIR/build_bridge.sh"
    echo ""
fi

if [[ ! -f "$BRIDGE" ]]; then
    echo "ERROR: Bridge library not found after build: $BRIDGE"
    exit 1
fi

# ================================================================
# Create fake home directory structure
# ================================================================

SIM_HOME="$PROJECT_ROOT/.sim_home"
SIM_TMPDIR="$SIM_HOME/tmp"

mkdir -p "$SIM_HOME/Library/Preferences"
mkdir -p "$SIM_HOME/Library/Caches"
mkdir -p "$SIM_HOME/Library/Logs"
mkdir -p "$SIM_HOME/Documents"
mkdir -p "$SIM_HOME/Media"
mkdir -p "$SIM_TMPDIR"

# ================================================================
# Environment variables
# ================================================================

# --- Core dyld variables ---
# DYLD_ROOT_PATH: tells dyld (and dyld_sim) to resolve /System/Library/...
#   paths relative to this SDK root instead of the host macOS root.
export DYLD_ROOT_PATH="$SDK"

# DYLD_INSERT_LIBRARIES: injects our bridge library into the process.
#   The bridge interposes BackBoardServices, GraphicsServices, and other
#   functions to bypass the backboardd/CARenderServer requirements.
export DYLD_INSERT_LIBRARIES="$BRIDGE"

# --- Simulator root variables ---
# Various frameworks check these to determine the SDK location.
export IPHONE_SIMULATOR_ROOT="$SDK"
export SIMULATOR_ROOT="$SDK"

# --- Home directory ---
# UIKit and Foundation use these to locate app data, preferences, caches.
export HOME="$SIM_HOME"
export CFFIXED_USER_HOME="$SIM_HOME"
export TMPDIR="$SIM_TMPDIR"

# --- Simulated device properties ---
# UIKit reads these to configure UIScreen, UIDevice, and the status bar.
# iPhone 6s: 375x667 points at 2x = 750x1334 pixels
export SIMULATOR_DEVICE_NAME="iPhone 6s"
export SIMULATOR_MODEL_IDENTIFIER="iPhone8,1"
export SIMULATOR_RUNTIME_VERSION="10.3"
export SIMULATOR_RUNTIME_BUILD_VERSION="14E8301"
export SIMULATOR_MAINSCREEN_WIDTH="750"
export SIMULATOR_MAINSCREEN_HEIGHT="1334"
export SIMULATOR_MAINSCREEN_SCALE="2.0"

# ================================================================
# Launch
# ================================================================

echo "========================================"
echo "RosettaSim Launch"
echo "========================================"
echo "Binary:    $TARGET_BIN"
echo "SDK:       $SDK"
echo "Bridge:    $BRIDGE"
echo "Sim Home:  $SIM_HOME"
echo "Device:    $SIMULATOR_DEVICE_NAME ($SIMULATOR_MODEL_IDENTIFIER)"
echo "Screen:    ${SIMULATOR_MAINSCREEN_WIDTH}x${SIMULATOR_MAINSCREEN_HEIGHT} @${SIMULATOR_MAINSCREEN_SCALE}x"
echo "========================================"
echo ""

# Launch the binary directly. Do NOT use 'arch -x86_64' as that strips
# DYLD_* environment variables (SIP protection). Rosetta 2 activates
# automatically when macOS encounters an x86_64 Mach-O binary.
exec "$TARGET_BIN" "$@"
