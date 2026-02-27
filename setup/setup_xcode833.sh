#!/bin/bash
# =============================================================================
# Xcode 8.3.3 on macOS 26 - Automated Setup Script
# =============================================================================
#
# This script patches Xcode 8.3.3 to run on macOS 26 (ARM64 Apple Silicon)
# under Rosetta 2. It builds and installs a compatibility layer consisting of:
#
#   1. PubSub.framework stub (removed from macOS)
#   2. AppKit compatibility wrapper (re-exports AppKit + missing private ivar symbols)
#   3. DVT plugin system hooks (scan record lazy loading, prune/activation bypass,
#      platform validation bypass, missing method stubs)
#   4. Python 2.7 stub (for LLDB dependency)
#   5. Binary patches (install_name_tool redirects, flat namespace, ad-hoc signing)
#
# Prerequisites:
#   - macOS 26+ on Apple Silicon
#   - Rosetta 2 installed
#   - Xcode 8.3.3 installed at /Applications/Xcode-8.3.3.app
#     (install with: xcodes install 8.3.3)
#   - Modern Xcode (for clang compiler and install_name_tool)
#
# Usage:
#   chmod +x setup.sh
#   ./setup.sh
#
# To launch after setup:
#   /Applications/Xcode-8.3.3.app/Contents/MacOS/Xcode
#
# =============================================================================

set -e

XCODE="/Applications/Xcode-8.3.3.app"
STUBS="$(cd "$(dirname "$0")" && pwd)/stubs"
SHARED="$XCODE/Contents/SharedFrameworks"
PLUGINS="$XCODE/Contents/PlugIns"
DISABLED="$XCODE/Contents/PlugIns.disabled"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err() { echo -e "${RED}[-]${NC} $1"; exit 1; }

# =============================================================================
# Preflight checks
# =============================================================================

[ -d "$XCODE" ] || err "Xcode 8.3.3 not found at $XCODE. Install with: xcodes install 8.3.3"
arch -x86_64 /usr/bin/true 2>/dev/null || err "Rosetta 2 not available. Install with: softwareupdate --install-rosetta"
which clang >/dev/null 2>&1 || err "clang not found. Install Xcode command line tools."

log "Xcode 8.3.3 found at $XCODE"
log "Stubs directory: $STUBS"

mkdir -p "$DISABLED"

# =============================================================================
# Step 1: Build PubSub.framework stub
# =============================================================================

log "Building PubSub.framework stub..."
mkdir -p "$STUBS/PubSub.framework/Versions/A"

cat > /tmp/pubsub_stub.c << 'EOF'
#include <stdio.h>
__attribute__((constructor)) static void init(void) {}
EOF

arch -x86_64 clang -arch x86_64 -dynamiclib \
    -install_name /System/Library/Frameworks/PubSub.framework/Versions/A/PubSub \
    -compatibility_version 1.0.0 -current_version 1.0.0 \
    -o "$STUBS/PubSub.framework/Versions/A/PubSub" /tmp/pubsub_stub.c 2>/dev/null
cd "$STUBS/PubSub.framework/Versions" && ln -sf A Current 2>/dev/null || true
cd "$STUBS/PubSub.framework" && ln -sf Versions/Current/PubSub PubSub 2>/dev/null || true
codesign --force --sign - "$STUBS/PubSub.framework/Versions/A/PubSub" 2>/dev/null

# =============================================================================
# Step 2: Build Python 2.7 stub
# =============================================================================

log "Building Python 2.7 stub..."
mkdir -p "$STUBS/Python.framework/Versions/2.7"

cat > /tmp/python27_stub.c << 'EOF'
#include <stdio.h>
void Py_Initialize(void) {}
void Py_Finalize(void) {}
int Py_IsInitialized(void) { return 0; }
__attribute__((constructor)) static void init(void) {}
EOF

arch -x86_64 clang -arch x86_64 -dynamiclib \
    -install_name /System/Library/Frameworks/Python.framework/Versions/2.7/Python \
    -compatibility_version 2.7.0 -current_version 2.7.0 \
    -o "$STUBS/Python.framework/Versions/2.7/Python" /tmp/python27_stub.c 2>/dev/null
codesign --force --sign - "$STUBS/Python.framework/Versions/2.7/Python" 2>/dev/null

# =============================================================================
# Step 3: Build AppKit compatibility wrapper
# =============================================================================

log "Building AppKit compatibility wrapper..."

cat > /tmp/appkit_wrapper.m << 'APPKITEOF'
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#include <stdio.h>

// Missing ivar offset symbols
ptrdiff_t nsFont_fFlags __asm__("_OBJC_IVAR_$_NSFont._fFlags") = 8;
ptrdiff_t nsText_ivars __asm__("_OBJC_IVAR_$_NSText._ivars") = 0;
ptrdiff_t nsTextStorage_editedDelta __asm__("_OBJC_IVAR_$_NSTextStorage._editedDelta") = 0;
ptrdiff_t nsTextStorage_editedRange __asm__("_OBJC_IVAR_$_NSTextStorage._editedRange") = 0;
ptrdiff_t nsTextStorage_flags __asm__("_OBJC_IVAR_$_NSTextStorage._flags") = 0;
ptrdiff_t nsATSTypesetter_lineFragmentPadding __asm__("_OBJC_IVAR_$_NSATSTypesetter.lineFragmentPadding") = 0;
ptrdiff_t nsTextViewIvars_sharedData __asm__("_OBJC_IVAR_$_NSTextViewIvars.sharedData") = 0;
ptrdiff_t nsTextViewIvars_tvFlags __asm__("_OBJC_IVAR_$_NSTextViewIvars.tvFlags") = 0;
ptrdiff_t nsTextViewSharedData_sdFlags __asm__("_OBJC_IVAR_$_NSTextViewSharedData._sdFlags") = 0;
ptrdiff_t nsUndoTextOperation_layoutManager __asm__("_OBJC_IVAR_$_NSUndoTextOperation._layoutManager") = 0;
ptrdiff_t nsTableView_reserved __asm__("_OBJC_IVAR_$_NSTableView._reserved") = 0;

static ptrdiff_t resolveIvar(const char *cls, const char *ivar, ptrdiff_t fb) {
    Class c = objc_getClass(cls);
    if (!c) return fb;
    Ivar i = class_getInstanceVariable(c, ivar);
    return i ? ivar_getOffset(i) : fb;
}

__attribute__((constructor)) static void init(void) {
    nsFont_fFlags = 8;
    nsText_ivars = resolveIvar("NSText", "_ivars", 536);
    nsTextStorage_editedDelta = resolveIvar("NSTextStorage", "_editedDelta", 56);
    nsTextStorage_editedRange = resolveIvar("NSTextStorage", "_editedRange", 40);
    nsTextStorage_flags = resolveIvar("NSTextStorage", "_flags", 64);
    nsATSTypesetter_lineFragmentPadding = resolveIvar("NSATSTypesetter", "lineFragmentPadding", 64);
    nsTextViewIvars_sharedData = resolveIvar("NSTextViewIvars", "sharedData", 0);
    nsTextViewIvars_tvFlags = resolveIvar("NSTextViewIvars", "tvFlags", 0);
    nsTextViewSharedData_sdFlags = resolveIvar("NSTextViewSharedData", "_sdFlags", 8);
    nsUndoTextOperation_layoutManager = resolveIvar("NSUndoTextOperation", "_layoutManager", 0);
    nsTableView_reserved = resolveIvar("NSTableView", "_reserved", 0);
}
APPKITEOF

arch -x86_64 clang -arch x86_64 -dynamiclib -Wl,-reexport_framework,AppKit \
    -framework Foundation -lobjc \
    -install_name @rpath/AppKit_compat.dylib \
    -o "$STUBS/AppKit_compat.dylib" /tmp/appkit_wrapper.m 2>/dev/null
codesign --force --sign - "$STUBS/AppKit_compat.dylib" 2>/dev/null

# =============================================================================
# Step 4: Build DVT plugin system hooks
# =============================================================================

log "Building DVT plugin system hooks..."

# The hook source is already at stubs/dvt_plugin_hook.m
if [ ! -f "$STUBS/dvt_plugin_hook.m" ]; then
    err "stubs/dvt_plugin_hook.m not found. This file should be in the rosetta project."
fi

arch -x86_64 clang -arch x86_64 -dynamiclib \
    -framework Foundation -framework AppKit -framework QuartzCore -lobjc \
    -install_name @rpath/dvt_plugin_hook.dylib \
    -o "$STUBS/dvt_plugin_hook.dylib" "$STUBS/dvt_plugin_hook.m" 2>/dev/null
codesign --force --sign - "$STUBS/dvt_plugin_hook.dylib" 2>/dev/null

# =============================================================================
# Step 5: Install stubs into Xcode bundle
# =============================================================================

log "Installing stubs into Xcode bundle..."

cp "$STUBS/AppKit_compat.dylib" "$SHARED/AppKit_compat.dylib"
cp "$STUBS/dvt_plugin_hook.dylib" "$SHARED/dvt_plugin_hook.dylib"

# Also install the appkit_compat_shim (loaded via LC_LOAD_DYLIB in Xcode binary)
if [ -f "$STUBS/appkit_compat_shim.dylib" ]; then
    cp "$STUBS/appkit_compat_shim.dylib" "$SHARED/appkit_compat_shim.dylib"
fi

# =============================================================================
# Step 6: Redirect framework dependencies
# =============================================================================

log "Redirecting framework dependencies..."

# DADocSetAccess: PubSub -> our stub
install_name_tool -change \
    /System/Library/Frameworks/PubSub.framework/Versions/A/PubSub \
    "$STUBS/PubSub.framework/Versions/A/PubSub" \
    "$SHARED/DADocSetAccess.framework/Versions/A/DADocSetAccess" 2>/dev/null || true

# DVTKit: AppKit -> our wrapper
install_name_tool -change \
    /System/Library/Frameworks/AppKit.framework/Versions/C/AppKit \
    @rpath/AppKit_compat.dylib \
    "$SHARED/DVTKit.framework/Versions/A/DVTKit" 2>/dev/null || true

# IDEInterfaceBuilderKit: AppKit -> our wrapper (if it exists)
if [ -f "$PLUGINS/IDEInterfaceBuilderKit.framework/Versions/A/IDEInterfaceBuilderKit" ]; then
    install_name_tool -change \
        /System/Library/Frameworks/AppKit.framework/Versions/C/AppKit \
        @rpath/AppKit_compat.dylib \
        "$PLUGINS/IDEInterfaceBuilderKit.framework/Versions/A/IDEInterfaceBuilderKit" 2>/dev/null || true
fi

# LLDB: Python 2.7 -> our stub
install_name_tool -change \
    /System/Library/Frameworks/Python.framework/Versions/2.7/Python \
    "$STUBS/Python.framework/Versions/2.7/Python" \
    "$SHARED/LLDB.framework/Versions/A/LLDB" 2>/dev/null || true

# =============================================================================
# Step 7: Patch Xcode binary (flat namespace + shim dependencies)
# =============================================================================

log "Patching Xcode binary..."

python3 << 'PYEOF'
import struct

path = '/Applications/Xcode-8.3.3.app/Contents/MacOS/Xcode'
with open(path, 'rb') as f:
    data = bytearray(f.read())

magic, cputype, cpusub, filetype, ncmds, sizeofcmds, flags = struct.unpack_from('<IIIIIiI', data, 0)

if magic != 0xfeedfacf:
    print(f'Not a 64-bit Mach-O: 0x{magic:08x}')
    exit(1)

# Remove MH_TWOLEVEL flag (0x80) for flat namespace
if flags & 0x80:
    new_flags = flags & ~0x80
    struct.pack_into('<I', data, 24, new_flags)
    print(f'Removed TWOLEVEL flag: 0x{flags:08x} -> 0x{new_flags:08x}')

# Add LC_LOAD_DYLIB for shim libraries
header_size = 32
load_cmd_end = header_size + sizeofcmds

# Find first segment offset for available space check
first_segment_offset = None
offset = header_size
for i in range(ncmds):
    cmd, cmdsize = struct.unpack_from('<II', data, offset)
    if cmd == 0x19:  # LC_SEGMENT_64
        fileoff = struct.unpack_from('<Q', data, offset+48)[0]
        if fileoff > 0 and (first_segment_offset is None or fileoff < first_segment_offset):
            first_segment_offset = fileoff
    offset += cmdsize

available = first_segment_offset - load_cmd_end if first_segment_offset else 0

# Check if shims are already linked
existing = data[header_size:load_cmd_end].decode('ascii', errors='ignore')
libs_to_add = []
for lib in ['appkit_compat_shim.dylib', 'dvt_plugin_hook.dylib']:
    if lib not in existing:
        libs_to_add.append(f'@rpath/{lib}')

for lib_name in libs_to_add:
    name_bytes = lib_name.encode('utf-8') + b'\x00'
    while (24 + len(name_bytes)) % 8 != 0:
        name_bytes += b'\x00'
    cmd_size = 24 + len(name_bytes)

    if available < cmd_size:
        print(f'Not enough space for {lib_name} ({available} < {cmd_size})')
        continue

    new_cmd = struct.pack('<IIIIII', 0xC, cmd_size, 24, 0, 0x00010000, 0x00010000)
    new_cmd += name_bytes
    data[load_cmd_end:load_cmd_end+cmd_size] = new_cmd
    ncmds += 1
    sizeofcmds += cmd_size
    load_cmd_end += cmd_size
    available -= cmd_size
    struct.pack_into('<I', data, 16, ncmds)
    struct.pack_into('<i', data, 20, sizeofcmds)
    print(f'Added LC_LOAD_DYLIB: {lib_name}')

with open(path, 'wb') as f:
    f.write(data)
print('Binary patched')
PYEOF

# Also make DVTKit flat namespace
python3 -c "
import struct
path = '$SHARED/DVTKit.framework/Versions/A/DVTKit'
with open(path, 'rb') as f:
    data = bytearray(f.read())
flags = struct.unpack_from('<I', data, 24)[0]
if flags & 0x80:
    struct.pack_into('<I', data, 24, flags & ~0x80)
    with open(path, 'wb') as f:
        f.write(data)
    print('DVTKit: flat namespace applied')
" 2>/dev/null || true

# =============================================================================
# Step 8: Disable incompatible plugins
# =============================================================================

log "Disabling incompatible plugins..."

# LLDB debugger (needs Python 2.7)
for p in DebuggerLLDB.ideplugin DebuggerLLDBService.ideplugin; do
    [ -d "$PLUGINS/$p" ] && mv "$PLUGINS/$p" "$DISABLED/" && echo "  Disabled: $p"
done

# Interface Builder (private API heartbeat/swizzling incompatibilities)
for p in IDEInterfaceBuilderCocoaIntegration.framework IDEInterfaceBuilderCocoaTouchIntegration.framework IDEInterfaceBuilderKit.framework; do
    [ -d "$PLUGINS/$p" ] && mv "$PLUGINS/$p" "$DISABLED/" && echo "  Disabled: $p"
done
for p in IDEInterfaceBuilderEditorDFRSupport.ideplugin IDEInterfaceBuilderDFRSupport.ideplugin IBBuildSupport.ideplugin IBCocoaBuildSupport.ideplugin; do
    [ -d "$PLUGINS/$p" ] && mv "$PLUGINS/$p" "$DISABLED/" && echo "  Disabled: $p"
done

# Platform IB integrations
find "$XCODE/Contents/Developer/Platforms" -name "*InterfaceBuilder*" -type d \( -name "*.ideplugin" -o -name "*.framework" \) 2>/dev/null | while read p; do
    [ -d "$p" ] && mv "$p" "$DISABLED/" && echo "  Disabled: $(basename "$p")"
done
find "$XCODE/Contents/Developer/Platforms" -name "IBCocoaTouchBuildSupport*" -type d 2>/dev/null | while read p; do
    [ -d "$p" ] && mv "$p" "$DISABLED/" && echo "  Disabled: $(basename "$p")"
done

# GPU debugger (needs Python 2.7)
for p in GPUDebuggerFoundation.ideplugin GPUDebuggerKit.ideplugin GPUTraceDebuggerUI.ideplugin GPUTraceDebugger.ideplugin GPURenderTargetEditor.ideplugin GPUDebuggerMTLSupport.ideplugin GPUDebuggerGLSupport.ideplugin; do
    [ -d "$PLUGINS/$p" ] && mv "$PLUGINS/$p" "$DISABLED/" && echo "  Disabled: $p"
done
find "$XCODE/Contents/Developer/Platforms" -name "GPU*" -type d \( -name "*.ideplugin" -o -name "*.framework" \) 2>/dev/null | while read p; do
    [ -d "$p" ] && mv "$p" "$DISABLED/" && echo "  Disabled: $(basename "$p")"
done

# =============================================================================
# Step 9: Re-sign everything
# =============================================================================

log "Re-signing Xcode bundle (this may take a moment)..."

# Sign individual modified binaries
for bin in \
    "$SHARED/AppKit_compat.dylib" \
    "$SHARED/dvt_plugin_hook.dylib" \
    "$SHARED/DVTKit.framework/Versions/A/DVTKit" \
    "$SHARED/DADocSetAccess.framework/Versions/A/DADocSetAccess" \
    "$SHARED/LLDB.framework/Versions/A/LLDB" \
    "$XCODE/Contents/MacOS/Xcode"
do
    [ -f "$bin" ] && codesign --force --sign - "$bin" 2>/dev/null
done

# Sign plugin binaries
for plugin in "$PLUGINS"/*.ideplugin "$PLUGINS"/*.dvtplugin; do
    name=$(basename "$plugin" | sed 's/\..*//')
    binary="$plugin/Contents/MacOS/$name"
    [ -f "$binary" ] && codesign --force --sign - "$binary" 2>/dev/null
done

# Sign framework binaries
for dir in SharedFrameworks Frameworks; do
    for fw in "$XCODE/Contents/$dir"/*.framework; do
        name=$(basename "$fw" .framework)
        binary="$fw/Versions/A/$name"
        [ -f "$binary" ] && codesign --force --sign - "$binary" 2>/dev/null
    done
done

# Sign Swift runtime libraries (needed for simctl/SimulatorKit)
for lib in "$XCODE/Contents/Frameworks"/libswift*.dylib; do
    [ -f "$lib" ] && codesign --force --sign - "$lib" 2>/dev/null
done

# Sign Developer tool binaries
for bin in \
    "$XCODE/Contents/Developer/usr/bin/simctl" \
    "$XCODE/Contents/Developer/Library/PrivateFrameworks/SimulatorKit.framework/Versions/A/SimulatorKit" \
    "$XCODE/Contents/Developer/Library/PrivateFrameworks/CoreSimulator.framework/Versions/A/CoreSimulator"
do
    [ -f "$bin" ] && codesign --force --sign - "$bin" 2>/dev/null
done

# Sign outer bundle (may fail due to PlugIns.disabled - that's OK)
codesign --force --sign - "$XCODE" 2>/dev/null || true

# =============================================================================
# Done!
# =============================================================================

echo ""
log "Setup complete!"
echo ""
echo "To launch Xcode 8.3.3:"
echo "  $XCODE/Contents/MacOS/Xcode"
echo ""
echo "Known limitations:"
echo "  - Interface Builder is disabled (private API incompatibilities)"
echo "  - LLDB debugger is disabled (Python 2.7 dependency)"
echo "  - GPU debugger is disabled (Python 2.7 dependency)"
echo "  - Devices, Preferences, and Simulator management work"
echo ""
echo "To install the iOS 9.3 Simulator:"
echo "  ./install_sim93.sh"
echo ""
echo "Disabled plugins are saved in:"
echo "  $DISABLED"
