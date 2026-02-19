#!/bin/bash

# Quick launch script for RosettaSim host app

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BINARY="$SCRIPT_DIR/build/RosettaSim"

if [ ! -f "$BINARY" ]; then
    echo "❌ Binary not found. Building first..."
    echo ""
    "$SCRIPT_DIR/build.sh"
    echo ""
fi

echo "Launching RosettaSim host application..."
echo ""

# Check if frame exists
if [ -f /tmp/rosettasim_text.png ]; then
    echo "✅ Found rendered frame: /tmp/rosettasim_text.png"
    ls -lh /tmp/rosettasim_text.png
else
    echo "⚠️  No rendered frame found at /tmp/rosettasim_text.png"
    echo "   The app will show 'No Frame Available'"
    echo ""
    echo "   To generate a frame, run the bridge rendering test:"
    echo "   cd /Users/ashhopkins/Projects/rosetta/test/phase4"
    echo "   ./run_test.sh render_to_png"
fi

echo ""
exec "$BINARY"
