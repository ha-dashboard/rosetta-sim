#!/bin/bash
#
# build_app.sh — Build RosettaSim.app (double-clickable macOS app)
#
# Creates a self-contained app bundle in the project root that:
#   1. Starts the rosettasim_daemon automatically
#   2. Launches Simulator.app with DYLD injection for legacy display
#   3. Works with a single double-click from Finder
#
# The app is a modified copy of Xcode's Simulator.app with:
#   - Library validation removed (allows DYLD_INSERT_LIBRARIES)
#   - Real binary renamed to Simulator.real
#   - Shell wrapper as the main executable
#
# Usage:
#   ./scripts/build_app.sh
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$PROJECT_ROOT/src/build"

SIMULATOR_SRC="/Applications/Xcode.app/Contents/Developer/Applications/Simulator.app"
APP_DST="$PROJECT_ROOT/RosettaSim.app"

echo "=== Building RosettaSim.app ==="
echo ""

# --- Check prerequisites ---
if [[ ! -f "$SIMULATOR_SRC/Contents/MacOS/Simulator" ]]; then
    echo "ERROR: Xcode Simulator.app not found at $SIMULATOR_SRC"
    echo "Install Xcode.app first."
    exit 1
fi

if [[ ! -x "$BUILD_DIR/rosettasim_daemon" ]] || [[ ! -f "$BUILD_DIR/sim_display_inject.dylib" ]]; then
    echo "Building tools first..."
    cd "$PROJECT_ROOT/src" && make
    echo ""
fi

# --- Copy Simulator.app ---
echo "Copying Simulator.app..."
rm -rf "$APP_DST"
cp -R "$SIMULATOR_SRC" "$APP_DST"

# --- Rename real binary ---
echo "Installing wrapper..."
mv "$APP_DST/Contents/MacOS/Simulator" "$APP_DST/Contents/MacOS/Simulator.real"

# --- Create wrapper script ---
cat > "$APP_DST/Contents/MacOS/Simulator" << 'WRAPPER'
#!/bin/bash
#
# RosettaSim wrapper — starts daemon and launches Simulator with display injection
#
DIR="$(cd "$(dirname "$0")" && pwd)"

# Find project root by walking up from the .app bundle
# RosettaSim.app/Contents/MacOS/Simulator → 3 levels up
PROJECT="$(cd "$DIR/../../.." && pwd)"

BUILD="$PROJECT/src/build"
DAEMON="$BUILD/rosettasim_daemon"
INJECT="$BUILD/sim_display_inject.dylib"
SCALE_FIX="$BUILD/sim_scale_fix.dylib"

# Start daemon if not running
if ! pgrep -f rosettasim_daemon >/dev/null 2>&1; then
    if [[ -x "$DAEMON" ]]; then
        "$DAEMON" &
        sleep 3
    fi
fi

# Set scale fix for sim processes
if [[ -f "$SCALE_FIX" ]]; then
    export SIMCTL_CHILD_DYLD_INSERT_LIBRARIES="$SCALE_FIX"
    export SIMCTL_CHILD_ROSETTA_SCREEN_SCALE=2
fi

# Launch real Simulator with display injection
export DYLD_INSERT_LIBRARIES="$INJECT"
export DYLD_FRAMEWORK_PATH="/Applications/Xcode.app/Contents/Developer/Library/PrivateFrameworks:/Library/Developer/PrivateFrameworks"
exec "$DIR/Simulator.real" "$@"
WRAPPER

chmod +x "$APP_DST/Contents/MacOS/Simulator"

# --- Update display name ---
/usr/libexec/PlistBuddy -c "Set :CFBundleName RosettaSim" "$APP_DST/Contents/Info.plist" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Add :CFBundleName string RosettaSim" "$APP_DST/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName RosettaSim" "$APP_DST/Contents/Info.plist" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string RosettaSim" "$APP_DST/Contents/Info.plist"

# --- Re-sign (remove library validation so DYLD_INSERT works on .real) ---
echo "Re-signing..."
codesign --force --sign - --options=0 "$APP_DST/Contents/MacOS/Simulator.real" 2>/dev/null
codesign --force --sign - "$APP_DST" 2>/dev/null || true

echo ""
echo "=== Done ==="
echo ""
echo "  Created: $APP_DST"
echo ""
echo "  Double-click RosettaSim.app in Finder to launch."
echo "  The daemon starts automatically. Boot legacy devices from"
echo "  Simulator's menu or xcrun simctl."
echo ""
