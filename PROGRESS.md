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
- **iOS 9.3 Simulator runtime installed** and recognized by modern CoreSimulator
- iOS 9.3 device creates and boots (~40 processes, backboardd stable)
- SpringBoard launches but crashes — display pipeline has no working framebuffer
- **Creating/opening projects works** — workspace window renders with all 120 plugins loaded
- Xcode's built-in simulator download UI still fails (use `install_sim93.sh` instead)
- **All plugins enabled** — no plugins in PlugIns.disabled, IB/LLDB/GPU all load
- **Next step**: inject RosettaSim bridge into runtime for display bypass

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
├── PlugIns/                       [All 120 plugins load — IB, LLDB, GPU all enabled]
└── Developer/Platforms/           [All platforms intact]
```

### Issues Fixed (in discovery order)

| # | Issue | Root Cause | Fix |
|---|-------|-----------|-----|
| 1 | SIGKILL Code Signature Invalid | macOS 26 taskgated rejects old Apple cert | Ad-hoc re-sign |
| 2 | Missing PubSub.framework | Removed from macOS | Stub dylib + install_name_tool redirect |
| 3 | Missing AppKit private ivar symbols | 10 ivar offset symbols no longer exported | AppKit_compat.dylib wrapper re-exporting AppKit |
| 4 | DYLD_* env vars stripped | Security restriction for Rosetta apps | Direct binary patching instead |
| 5 | All 118 plugin scan records pruned | Unknown check in _pruneUnusablePlugInsAndScanRecords | Prune-then-restore (only restores bundles that exist on disk) |
| 6 | Scan record properties nil (identifier, UUIDs) | Info.plist not loaded during scan on macOS 26 | Lazy-loading hooks on property getters |
| 7 | Platform support plugins filtered by activation | "build-system" capability chicken-and-egg | Bypass activation rules |
| 8 | "Required content for platform X missing" | Extension points not yet registered when queried | Platform validation bypass + error clearing |
| 9 | Missing Python 2.7 for LLDB/GPU debugger | Python 2.7 removed from macOS | Full 124-symbol no-op stub (all plugins load) |
| 10 | IB heartbeat method swizzle assertion | _addHeartBeatClientView: removed from AppKit | Method stubs with correct type encodings (v@:c for NSProgressIndicator) |
| 11 | NSTableView._reserved ivar missing | Private ivar removed from AppKit | Added to AppKit_compat wrapper |
| 12 | CALayer.view crash creating projects | DVTKit category calls removed private CALayer API | Replaced DVTKit's `-[CALayer view]` via `method_setImplementation` → returns delegate if NSView |
| 13 | Simulator download fails at install | PackageKit XPC service rejects old Xcode's client | Manual DMG extraction + direct runtime install |
| 14 | iOS 9.3 runtime "unavailable" | CoreSimulator hardcodes maxHostVersion=10.14.99 for iOS 9.x | Override `maxHostVersion` in profile.plist to 99.99.99 |
| 15 | simctl/SimulatorKit code signing | Swift libs flagged as non-platform binaries | Ad-hoc re-sign all libswift*.dylib + SimulatorKit |
| 16 | backboardd "No window server display found" | `BKDisplayStartWindowServer()` can't enumerate displays from modern CoreSimulator | Binary patch: skip assertion (`je` → `jmp` to post-assertion path) |
| 17 | SpringBoard "main display is nil" in BKSDisplayServicesStart | Cascading nil display through BackBoardServices | Binary patch: `BKSDisplayServicesStart` → `mov eax,1; ret` |
| 18 | SpringBoard FBSceneManager crash | `_createSceneWithIdentifier:display:` called with nil display | **UNSOLVED** — requires display protocol bridge or RosettaSim approach |
| 19 | DVTExtension valueForKey:error: throws | Extensions from broken/disabled plugins throw NSInternalInconsistencyException | Wrapped in `@try/@catch`, returns nil+NSError instead |
| 20 | DVTInvalidExtension crashes Rosetta | `__cxa_throw` under Rosetta causes pointer auth SIGSEGV | Hook `valueForKey:` to return defaults, prevent `_throwInvalidExtensionExceptionForProperty:` |
| 21 | IDEMenuBuilder assertion on disabled plugins | Menu definitions reference extensions from disabled plugins | Wrapped `_appendItemsToMenu:` in `@try/@catch`, skips missing |
| 22 | _autolayout_cellSize infinite recursion | `_autolayout_cellSize` calls `[self cellSize]`, subclass calls back | Call `NSCell` IMP directly via `class_getMethodImplementation`, bypassing override |
| 23 | NSFont._fFlags reads CoreText internals | Dummy offset 8 reads CTFont data (NSFont instance_size=8) | Changed offset to 16 (consistently zero across all font instances) |
| 24 | IB _whenResizingUseEngineFrame: missing | `IBCocoaTouchPlugin` swizzles removed NSView private method | Added stub with correct encoding `v@:^c^c` |
| 25 | IDEAssertionHandler aborts on stale refs | Assertions from disabled plugin stale references kill process | Convert assertion failures to warnings, uncaught exceptions to log-only |

### Key Technical Discoveries

1. **macOS 26 ships a full x86_64 dyld shared cache** at `/System/Cryptexes/OS/System/Library/dyld/dyld_shared_cache_x86_64` (~5.5GB) with all system frameworks including QTKit, OpenGL, Carbon, and QuickTime
2. **DYLD_* environment variables are stripped** from Rosetta-translated processes regardless of code signing
3. **DVTPlugInScanRecord properties are lazily initialized** on macOS 26 - the scan creates empty records that need explicit loading
4. **Plugin activation rules create a chicken-and-egg** - platform plugins require "build-system" capability, but the build system needs platform plugins
5. **253 extension points and 4411 extensions** successfully register once the plugin system is properly hooked
6. **NSFont is fully opaque** in modern AppKit (0 ivars) - old code accessing _fFlags reads dummy memory
7. **CoreSimulator's maxHostVersion is overridable** - the profile.plist `maxHostVersion` key takes precedence over the hardcoded version table in the CoreSimulator binary. Setting it to `99.99.99` makes any runtime "available" on any macOS version.
8. **Modern CoreSimulator (1051.x) can boot legacy x86_64 runtimes** - iOS 9.3 boots via `SimLaunchHost.x86` on Apple Silicon. The old simctl can't connect (protocol mismatch) but the modern simctl works.
9. **iOS 9.3 simulator DMG still available** on Apple CDN at `devimages-cdn.apple.com/downloads/xcode/simulators/` (as of Feb 2026)
10. **CALayer.view was a private property** returning the NSView backing a layer. Removed in modern CoreAnimation. `self.delegate` is the backing view in layer-backed views.
11. **Simulator display pipeline requires protocol bridging** — backboardd → BackBoardServices → FrontBoard → UIKit all assume a non-nil CADisplay from `BKSDisplayServicesStart`. Patching individual assertions reveals the next one downstream. The entire display init chain needs either: (a) a working SimFramebuffer connection, or (b) a RosettaSim-style bridge that provides screen info + offscreen rendering.
12. **iOS 9.3 backboardd survives patching** — with the assertion bypassed, backboardd starts successfully, monitors SpringBoard, and accepts connections. The crash cascade is entirely in SpringBoard/UIKit, not backboardd.
13. **Existing RosettaSim bridge is the proven approach** — `rosettasim_bridge.m` already solves this for standalone apps via DYLD_INSERT_LIBRARIES interposition of BKSDisplayServicesStart + GSSetMainScreenInfo + offscreen CALayer rendering. Phase 5 achieved 29fps continuous rendering. The challenge is injecting it into CoreSimulator-managed processes where env vars are stripped.

### Remaining Issues

1. **Simulator display — the final blocker** — iOS 9.3 boots ~40 processes, backboardd starts, SpringBoard launches but crashes in FBSceneManager because there's no display. Three possible paths forward:
   - **Path A: RosettaSim bridge injection** — patch BackBoardServices.framework in the runtime to load a bridge dylib (via LC_LOAD_DYLIB) that interposes BKSDisplayServicesStart with screen info + offscreen rendering. The bridge code already exists and works (`rosettasim_bridge.m`, Phase 5 proven at 29fps). **This is the active path — waiting on RosettaSim bridge agent to reach maturity.**
   - **Path B: SimFramebuffer protocol bridge** — build a v554→v783 protocol translator so the old SimFramebufferClient can talk to the modern host. Complex but would enable native display pipeline.
2. **Simulator download UI broken** — workaround: use `install_sim93.sh`
3. **LLDB debugging non-functional** — Python 2.7 stub is no-ops, breakpoints/debugger console won't work
4. **GPU frame capture non-functional** — GPU debugger loads but capture functionality depends on missing system frameworks
5. **Unknown prune reason** — all scan records marked "unusable" by the prune step (we bypass but root cause unknown)
6. **Some assertion warnings at startup** — non-fatal, from stale extension references in disabled plugin menu definitions

### Binary Patches Applied to iOS 9.3 Runtime

| Binary | Offset | Patch | Purpose |
|--------|--------|-------|---------|
| `backboardd` (x86_64) | 0x10daa (fat: 0x86daa) | `0f8490000000` → `0f8412010000` | Skip assertion in BKDisplayStartWindowServer |
| `BackBoardServices` (x86_64) | 0xade3 (fat: 0x58de3) | `c645df00` → `c645df01` | Set display-started flag to TRUE |
| `BackBoardServices` (x86_64) | 0xadf4 (fat: 0x58df4) | `e8c7beffff` → `9090909090` | NOP call to _BKSDisplayStart |
| `BackBoardServices` (x86_64) | 0xaf06 (fat: 0x59f06) | `0f8589000000` → `90e989000000` | Skip "main display is nil" assertion |
| `BackBoardServices` (x86_64) | 0xadd4 (fat: 0x58dd4) | `554889e54157` → `b801000000c3` | BKSDisplayServicesStart returns TRUE immediately |

## Files

```
rosetta/
├── setup.sh                    # Automated Xcode 8.3.3 patching script
├── install_sim93.sh            # iOS 9.3 simulator manual install script
├── launch_xcode833.sh          # Launch helper with log capture
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
