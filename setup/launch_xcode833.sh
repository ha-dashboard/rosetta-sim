#!/bin/bash
# Launch Xcode 8.3.3 on macOS 26
#
# Run this from a LOCAL Terminal.app (not SSH) to get the GUI.
#
# What this script does:
# 1. Launches the patched Xcode 8.3.3 binary directly
# 2. Captures stderr to a log file for debugging
# 3. Reports the process status
#
# Prerequisites (already applied):
# - Xcode 8.3.3 installed at /Applications/Xcode-8.3.3.app
# - Ad-hoc code signatures applied
# - PubSub.framework stub created and linked
# - AppKit compatibility wrapper created and linked to DVTKit
# - DVT plugin hook installed (prune bypass + presence override)
# - Python 2.7 stub created and linked to LLDB
# - DebuggerLLDB/DebuggerLLDBService plugins moved to PlugIns.disabled

set -e

XCODE="/Applications/Xcode-8.3.3.app/Contents/MacOS/Xcode"
LOGFILE="/tmp/xcode833_$(date +%Y%m%d_%H%M%S).log"

if [ ! -f "$XCODE" ]; then
    echo "ERROR: Xcode 8.3.3 not found at $XCODE"
    exit 1
fi

echo "Launching Xcode 8.3.3..."
echo "Log file: $LOGFILE"
echo ""

"$XCODE" 2>"$LOGFILE" &
XCODE_PID=$!
echo "PID: $XCODE_PID"
echo ""
echo "Xcode 8.3.3 is starting. Check the GUI on your screen."
echo "Press Ctrl+C to stop monitoring (Xcode will keep running)."
echo ""

# Monitor
while kill -0 $XCODE_PID 2>/dev/null; do
    RSS=$(ps -p $XCODE_PID -o rss= 2>/dev/null || echo "0")
    printf "\r[%s] RSS: %s KB  " "$(date +%H:%M:%S)" "$RSS"
    sleep 2
done
echo ""
echo "Xcode exited."
echo "Check log: $LOGFILE"

# Show any errors
ERRORS=$(grep -v "^objc\[" "$LOGFILE" | grep -i "error\|fail" | grep -v "\[dvt\]" | grep -v "\[appkit_" | head -5)
if [ -n "$ERRORS" ]; then
    echo ""
    echo "=== Errors found ==="
    echo "$ERRORS"
fi
