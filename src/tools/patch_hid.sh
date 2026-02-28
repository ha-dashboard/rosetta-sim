#!/bin/bash
# patch_hid.sh — Replace iOS 12.4's SimulatorClient with iOS 9.3's version
#
# iOS 12.4's SimulatorClient delegates HID to SimulatorHID.framework (host-side dlopen)
# which fails under Rosetta 2. iOS 9.3's SimulatorClient handles HID entirely in-process
# via bootstrap_look_up("IndigoHIDRegistrationPort") + Mach port handshake.
#
# Both versions export the same critical symbol: _IndigoHIDSystemSpawnLoopback
# and have the same install name: /System/Library/PrivateFrameworks/SimulatorClient.framework/SimulatorClient
#
# Usage:
#   ./src/tools/patch_hid.sh [runtime_version]
#   ./src/tools/patch_hid.sh 12.4     # patch iOS 12.4
#   ./src/tools/patch_hid.sh 13.7     # patch iOS 13.7
#   ./src/tools/patch_hid.sh --revert 12.4  # restore original

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RUNTIMES_DIR="$HOME/Library/Developer/CoreSimulator/Profiles/Runtimes"
DONOR_VER="9.3"

# Parse args
REVERT=false
if [[ "${1:-}" == "--revert" ]]; then
    REVERT=true
    shift
fi

TARGET_VER="${1:-12.4}"
TARGET_RT="$RUNTIMES_DIR/iOS_${TARGET_VER}.simruntime/Contents/Resources/RuntimeRoot"
DONOR_RT="$RUNTIMES_DIR/iOS_${DONOR_VER}.simruntime/Contents/Resources/RuntimeRoot"

SC_REL="System/Library/PrivateFrameworks/SimulatorClient.framework/SimulatorClient"
TARGET="$TARGET_RT/$SC_REL"
DONOR="$DONOR_RT/$SC_REL"
BACKUP="$TARGET.orig_hid"

if [[ ! -f "$TARGET" ]]; then
    echo "ERROR: Target not found: $TARGET"
    exit 1
fi

if [[ "$REVERT" == true ]]; then
    if [[ -f "$BACKUP" ]]; then
        cp "$BACKUP" "$TARGET"
        echo "Reverted iOS $TARGET_VER SimulatorClient from backup"
    else
        echo "No backup found at $BACKUP"
        exit 1
    fi
    exit 0
fi

if [[ ! -f "$DONOR" ]]; then
    echo "ERROR: Donor (iOS $DONOR_VER) not found: $DONOR"
    exit 1
fi

# Backup original
if [[ ! -f "$BACKUP" ]]; then
    cp "$TARGET" "$BACKUP"
    echo "Backed up original to $BACKUP"
fi

# Extract x86_64 slice from iOS 9.3's universal binary
TMPFILE="/tmp/SimulatorClient_x86_64_$$"
lipo "$DONOR" -extract x86_64 -output "$TMPFILE" 2>/dev/null || cp "$DONOR" "$TMPFILE"

# Verify the extracted slice has the needed symbols
EXPORTS=$(nm -gU "$TMPFILE" 2>/dev/null | awk '{print $NF}')
if ! echo "$EXPORTS" | grep -q '_IndigoHIDSystemSpawnLoopback'; then
    echo "ERROR: Donor doesn't export IndigoHIDSystemSpawnLoopback"
    rm -f "$TMPFILE"
    exit 1
fi
if ! echo "$EXPORTS" | grep -q '_IndigoTvOutExtendedState'; then
    echo "ERROR: Donor doesn't export IndigoTvOutExtendedState"
    rm -f "$TMPFILE"
    exit 1
fi

# Verify install name matches
DONOR_ID=$(otool -D "$TMPFILE" 2>/dev/null | tail -1)
TARGET_ID=$(otool -D "$TARGET" 2>/dev/null | tail -1)
if [[ "$DONOR_ID" != "$TARGET_ID" ]]; then
    echo "WARNING: Install name mismatch: donor='$DONOR_ID' target='$TARGET_ID'"
    echo "Fixing install name..."
    install_name_tool -id "$TARGET_ID" "$TMPFILE"
fi

# Replace
cp "$TMPFILE" "$TARGET"
rm -f "$TMPFILE"

# Re-sign (ad-hoc, needed after binary replacement)
codesign --force --sign - "$TARGET" 2>/dev/null || true

echo "=== Patched iOS $TARGET_VER SimulatorClient ==="
echo "Replaced with iOS $DONOR_VER version (in-process HID handshake)"
echo ""
echo "Exports:"
nm -gU "$TARGET" 2>/dev/null | grep -E 'IndigoHID|IndigoTvOut' | awk '{print "  " $NF}'
echo ""
echo "Dependencies:"
otool -L "$TARGET" 2>/dev/null | tail -n +2 | awk '{print "  " $1}'
echo ""
echo "To revert: $0 --revert $TARGET_VER"
