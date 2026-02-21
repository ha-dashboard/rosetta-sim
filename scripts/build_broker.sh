#!/bin/bash
#
# build_broker.sh - Build the RosettaSim Mach port broker
#
# This script compiles rosettasim_broker.c as an x86_64 macOS binary
# (NOT against the iOS SDK).

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

SRC_FILE="$PROJECT_ROOT/src/bridge/rosettasim_broker.c"
OUT_FILE="$PROJECT_ROOT/src/bridge/rosettasim_broker"

echo "Building RosettaSim broker..."
echo "Source: $SRC_FILE"
echo "Output: $OUT_FILE"

# Check if source file exists
if [ ! -f "$SRC_FILE" ]; then
    echo "Error: Source file not found: $SRC_FILE"
    exit 1
fi

# Compile as x86_64 macOS binary
clang -arch x86_64 \
    -Wall -Wextra \
    -O2 \
    -o "$OUT_FILE" \
    "$SRC_FILE"

# Code sign the binary
codesign -s - -f "$OUT_FILE"

echo "Build complete: $OUT_FILE"

# Show file info
file "$OUT_FILE"
