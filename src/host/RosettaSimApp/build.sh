#!/bin/bash
set -e

# RosettaSim Host App Build Script
# Builds native ARM64 macOS application

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/build"
APP_NAME="RosettaSim"

echo "Building RosettaSim Host Application..."
echo "Architecture: ARM64 (native macOS)"
echo "Location: $SCRIPT_DIR"
echo ""

# Clean previous build
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# Compile the Swift file
echo "Compiling Swift source..."
swiftc \
    -o "$BUILD_DIR/$APP_NAME" \
    -framework AppKit \
    -framework SwiftUI \
    "$SCRIPT_DIR/RosettaSimApp.swift"

if [ $? -ne 0 ]; then
    echo "❌ Build failed"
    exit 1
fi

# Verify architecture
echo ""
echo "Build successful!"
echo "Binary architecture:"
file "$BUILD_DIR/$APP_NAME"
echo ""

# Check if it's ARM64
if file "$BUILD_DIR/$APP_NAME" | grep -q "arm64"; then
    echo "✅ Confirmed: Native ARM64 binary"
else
    echo "⚠️  Warning: Expected ARM64 architecture"
fi

echo ""
echo "To run the application:"
echo "  $BUILD_DIR/$APP_NAME"
echo ""
echo "Or double-click the binary in Finder to launch it."
