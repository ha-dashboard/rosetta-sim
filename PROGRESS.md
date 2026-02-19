# Xcode 8.3.3 on macOS 26 - Progress Log

## Goal
Run Xcode 8.3.3 (latest with iOS 9 simulator support) on macOS 26.3 (ARM64 Apple Silicon) under Rosetta 2, to deploy apps to iOS 9 devices and use the iOS 9 simulator.

## Environment
- macOS 26.3 (Build 25D125), Mac14,6 (Apple M2 Max)
- Rosetta 2 active, x86_64 dyld shared cache present (~5.5GB)
- Xcode 8.3.3 (8E3004b) - x86_64 only

## Current State: WORKING (with limitations)
- Welcome screen displays
- Preferences window works
- Devices window works (shows simulators)
- Components tab shows downloadable iOS 9.x simulator runtimes
- Simulator management works
- Creating new projects crashes (CALayer.view private API change - next fix)
- iOS 9 simulator download reported "non-interactive" error

## Architecture

### Compatibility Layer Components

```
Xcode-8.3.3.app/Contents/
├── MacOS/Xcode                    [PATCHED: flat namespace, LC_LOAD_DYLIB for shims]
├── SharedFrameworks/
│   ├── DVTKit.framework           [PATCHED: flat namespace, AppKit→AppKit_compat]
│   ├── DADocSetAccess.framework   [PATCHED: PubSub→stub]
│   ├── LLDB.framework             [PATCHED: Python→stub]
│   ├── AppKit_compat.dylib        [NEW: re-exports AppKit + 11 ivar offset symbols]
│   ├── appkit_compat_shim.dylib   [NEW: additional ivar resolver]
│   └── dvt_plugin_hook.dylib      [NEW: DVT plugin system hooks]
├── PlugIns/
│   └── IDEInterfaceBuilderKit.fw  [PATCHED: AppKit→AppKit_compat]
├── PlugIns.disabled/              [Incompatible plugins moved here]
│   ├── DebuggerLLDB*.ideplugin
│   ├── IDEInterfaceBuilder*.framework
│   ├── GPU*.ideplugin
│   └── ...
└── Developer/Platforms/           [All platforms intact]
```

### Issues Fixed (in discovery order)

| # | Issue | Root Cause | Fix |
|---|-------|-----------|-----|
| 1 | SIGKILL Code Signature Invalid | macOS 26 taskgated rejects old Apple cert | Ad-hoc re-sign |
| 2 | Missing PubSub.framework | Removed from macOS | Stub dylib + install_name_tool redirect |
| 3 | Missing AppKit private ivar symbols | 10 ivar offset symbols no longer exported | AppKit_compat.dylib wrapper re-exporting AppKit |
| 4 | DYLD_* env vars stripped | Security restriction for Rosetta apps | Direct binary patching instead |
| 5 | All 118 plugin scan records pruned | Unknown check in _pruneUnusablePlugInsAndScanRecords | Prune-then-restore strategy |
| 6 | Scan record properties nil (identifier, UUIDs) | Info.plist not loaded during scan on macOS 26 | Lazy-loading hooks on property getters |
| 7 | Platform support plugins filtered by activation | "build-system" capability chicken-and-egg | Bypass activation rules |
| 8 | "Required content for platform X missing" | Extension points not yet registered when queried | Platform validation bypass + error clearing |
| 9 | Missing Python 2.7 for LLDB/GPU debugger | Python 2.7 removed from macOS | Stub + move plugins to disabled |
| 10 | IB heartbeat method swizzle assertion | _addHeartBeatClientView: removed from AppKit | Missing method stubs + move IB plugins |
| 11 | NSTableView._reserved ivar missing | Private ivar removed from AppKit | Added to AppKit_compat wrapper |

### Key Technical Discoveries

1. **macOS 26 ships a full x86_64 dyld shared cache** at `/System/Cryptexes/OS/System/Library/dyld/dyld_shared_cache_x86_64` (~5.5GB) with all system frameworks including QTKit, OpenGL, Carbon, and QuickTime
2. **DYLD_* environment variables are stripped** from Rosetta-translated processes regardless of code signing
3. **DVTPlugInScanRecord properties are lazily initialized** on macOS 26 - the scan creates empty records that need explicit loading
4. **Plugin activation rules create a chicken-and-egg** - platform plugins require "build-system" capability, but the build system needs platform plugins
5. **253 extension points and 4411 extensions** successfully register once the plugin system is properly hooked
6. **NSFont is fully opaque** in modern AppKit (0 ivars) - old code accessing _fFlags reads dummy memory

### Remaining Issues

1. **CALayer.view crash** - DVTKit's `CALayer(DVTCALayerAdditions)` calls a removed private CoreAnimation API when creating project windows
2. **Simulator download** - Reports "non-interactive" error
3. **Interface Builder** disabled - heartbeat method swizzling and type encoding mismatches
4. **LLDB/GPU Debugger** disabled - Python 2.7 dependency (needs full C API stub)
5. **Unknown prune reason** - All scan records marked "unusable" by the prune step (we bypass but root cause unknown)

## Files

```
rosetta/
├── setup.sh                    # Automated setup script
├── launch_xcode833.sh          # Launch helper
├── PROGRESS.md                 # This file
└── stubs/
    ├── dvt_plugin_hook.m       # DVT plugin system hooks (source)
    ├── dvt_plugin_hook.dylib   # Compiled hooks
    ├── appkit_compat_shim.m    # AppKit ivar shim (source)
    ├── appkit_compat_shim.dylib
    ├── AppKit_compat.dylib     # AppKit wrapper (re-exports + ivars)
    ├── PubSub.framework/       # PubSub stub
    └── Python.framework/       # Python 2.7 stub
```
