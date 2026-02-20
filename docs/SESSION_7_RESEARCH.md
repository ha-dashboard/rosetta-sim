# Session 7 Research — The Real Simulator Architecture & Path Forward

**Date**: 2026-02-20
**Focus**: Understanding why the bridge approach has hit a ceiling, and mapping the proper simulator service architecture for a correct implementation.

## Executive Summary

Session 7 started by attempting to fix the 5 user-reported issues from Session 6 (resolution, segmented control colors, touch delivery, keyboard, scroll crash). After implementing several fixes and testing them, we discovered that the fundamental problem is architectural: **the bridge interposition approach cannot properly render UIKit because it operates without CARenderServer.** No amount of crash guards or rendering hacks will fix tintColor, animations, scroll deceleration, or template image colorization — they all fundamentally require CARenderServer.

This session's most important contribution is the **complete mapping of the real iOS simulator service architecture** — what backboardd actually is, what SimulatorClient does, how displays are created, and what specifically blocks us from running the real services. This document captures every detail for the next agent.

---

## Part 1: What the Bridge Approach Cannot Fix

### The Ceiling

The bridge (`src/bridge/rosettasim_bridge.m`, ~4000 lines) works by:
1. Interposing `CARenderServerGetServerPort()` → returns `MACH_PORT_NULL`
2. Interposing all BackBoardServices functions → stubs/no-ops
3. CPU-only rendering via `CALayer.renderInContext:` at 30fps
4. Manual touch injection via IOHIDEvent + sendEvent:
5. Manual keyboard injection via insertText:
6. ~30 SIGSEGV crash guards with sigsetjmp/siglongjmp

### What Breaks Without CARenderServer (Proven in Testing)

| Feature | Status | Root Cause |
|---------|--------|------------|
| **tintColor / template images** | BROKEN | Template image colorization is a GPU shader operation via CARenderServer |
| **UISegmentedControl selected state** | BROKEN | Selected segment blue fill uses template rendering |
| **Animations (CABasicAnimation etc.)** | BROKEN | No animation thread without render server |
| **CADisplayLink** | BROKEN | No vsync source without render server |
| **Scroll deceleration** | CRASHES | Scroll gesture triggers CA internals that crash without CARenderServer |
| **UIScrollView bounce** | CRASHES | Same as above |
| **Video playback** | BROKEN | Needs GPU compositing |
| **Metal/OpenGL** | BROKEN | Needs GPU context from render server |
| **Visual effects (blur, vibrancy)** | BROKEN | UIVisualEffectView needs GPU compositing |

### The siglongjmp Problem

Every crash guard uses `sigsetjmp`/`siglongjmp` for SIGSEGV recovery. This is fundamentally unsafe because:
- `siglongjmp` from inside `@autoreleasepool` corrupts the ARC pool stack
- The next run loop iteration crashes fatally in `_wrapRunLoopWithAutoreleasePoolHandler`
- This is what caused the scroll crash: sendEvent → scroll gesture → CA crash → siglongjmp → pool corruption → fatal crash on next frame

**You cannot safely recover from SIGSEGV in ObjC code that uses autorelease.** The bridge approach requires recovering from crashes that happen inside UIKit's autorelease-heavy code. This is fundamentally incompatible.

---

## Part 2: The Real iOS Simulator Architecture

### Overview

```
HOST SIDE (ARM64 macOS)                    SIMULATOR SIDE (x86_64 iOS SDK)
┌─────────────────────────┐                ┌─────────────────────────────────┐
│ CoreSimulatorService     │                │ launchd_sim                     │
│   ├─ SimFramebuffer     │  Mach IPC      │   ├─ backboardd                 │
│   ├─ IndigoLegacyHID    │◄──────────────►│   │   ├─ SimulatorClient.fw     │
│   └─ SimDeviceIO        │                │   │   ├─ CARenderServer         │
│                         │                │   │   ├─ HID services           │
│ Simulator.app           │                │   │   └─ Display services       │
│   └─ Window display     │                │   ├─ SpringBoard               │
│                         │                │   └─ App processes              │
└─────────────────────────┘                └─────────────────────────────────┘
```

### backboardd — The Central Hub

**Location**: `/Applications/Xcode-8.3.3.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator10.3.sdk/usr/libexec/backboardd`

**Architecture**: Mach-O universal binary (i386 + x86_64), 1.3MB

**Launchd plist**: `.../iPhoneSimulator10.3.sdk/System/Library/LaunchDaemons/com.apple.backboardd.plist`

**Registered Mach Services** (16 total):
```
com.apple.CARenderServer              (ResetAtClose) — THE critical one
com.apple.backboard.display.services  (ResetAtClose)
com.apple.backboard.hid.services      (ResetAtClose)
com.apple.backboard.hid.focus
com.apple.iohideventsystem            (ResetAtClose)
com.apple.uikit.GestureServer
com.apple.backboard.TouchDeliveryPolicyServer
com.apple.backboard.animation-fence-arbiter (ResetAtClose)
com.apple.backboard.checkin
com.apple.backboard.system-app-server
com.apple.backboard.altsysapp
com.apple.backboard.watchdog
com.apple.backlightd
PurpleSystemEventPort                 (ResetAtClose)
PurpleWorkspacePort                   (ResetAtClose)
```

**Linked Frameworks** (in link order):
1. `SimulatorClient.framework` (v719.0.0) — THE bridge to host display/HID
2. `ButtonResolver.framework`
3. `Haptics.framework`
4. `AssertionServices.framework`
5. `AggregateDictionary.framework`
6. `AVFoundation.framework`
7. `BackBoardServices.framework`
8. `BaseBoard.framework`
9. `CoreBrightness.framework`
10. `CoreGraphics.framework`
11. `CoreMotion.framework`
12. `DataMigration.framework`
13. `Foundation.framework`
14. `GraphicsServices.framework`
15. `ImageIO.framework`
16. `IOKit.framework`
17. `libAccessibility.dylib`
18. `libMobileGestalt.dylib`
19. `MobileCoreServices.framework`
20. `ProgressUI.framework`
21. `QuartzCore.framework`
22. `Security.framework`
23. `SystemConfiguration.framework`
24. `libSystem.dylib`
25. `CoreFoundation.framework`
26. `libobjc.A.dylib`

All paths are `/System/Library/...` relative — resolved through `DYLD_ROOT_PATH` to the iOS SDK.

### SimulatorClient.framework — The Display/HID Bridge

**Location**: `.../iPhoneSimulator10.3.sdk/System/Library/PrivateFrameworks/SimulatorClient.framework/SimulatorClient`

**Architecture**: Universal (i386 + x86_64)

**Project**: `Indigo-719` (from `@(#)PROGRAM:SimulatorClient PROJECT:Indigo-719`)

**Source path**: `IndigoClient_Sim/Indigo-719/SimulatorClient/SimulatorClient.m`

**Exported Symbols** (7 total):
```
IndigoHIDMainScreen          (D) — global: primary display handle
IndigoHIDStarkScreen         (D) — global: secondary display handle
IndigoHIDSystemSpawnLoopback (T) — THE key function: initializes display + HID
IndigoTvOutExtendedState     (T) — TV output state
IndigoTvOutUniqueId          (T) — TV output identifier
SimulatorClientVersionNumber (S) — version number
SimulatorClientVersionString (S) — version string
```

**Imported Symbols of Interest**:
```
_OBJC_CLASS_$_CADisplay      (U) — Creates CADisplay objects!
```

**Linked Frameworks**:
1. GraphicsServices.framework
2. QuartzCore.framework
3. Foundation.framework
4. IOKit.framework
5. libobjc.A.dylib
6. libSystem.dylib
7. CoreFoundation.framework

### IndigoHIDSystemSpawnLoopback — The Critical Function

**Signature**: `BOOL IndigoHIDSystemSpawnLoopback(IOHIDEventSystemRef hidEventSystem)`

**Behavior** (reconstructed from strings analysis):
1. Can only be called once (enforced by assertion)
2. Reads `SIMULATOR_HID_SYSTEM_MANAGER` environment variable
3. Loads a bundle from that path (NSBundle.bundleWithPath:)
4. Gets the bundle's `principalClass`
5. Checks if the class conforms to `SimulatorClientHIDSystemManager` protocol
6. If no bundle specified or load fails, falls back to `SimulatorHIDFallback` (built-in)
7. Initializes the HID system manager: `initUsingHIDService:error:`
8. Queries: `displays`, `hasTouchScreen`, `hasTouchScreenLofi`, `hasWheel`
9. Display identifiers: `Screen#0`, `Screen#1`
10. Creates CADisplay objects from display descriptors
11. Sets `IndigoHIDMainScreen` = primary display
12. Sets `IndigoHIDStarkScreen` = secondary display (if exists)
13. Logs: `Initialized Simulator HID System Manager: %@`

**Error messages**:
- `API MISUSE: hidEventSystem was NULL.`
- `API MISUSE: IndigoHIDSystemSpawnLoopback() can only be called once.`
- `Simulator HID System Manager bundle %@ does not conform to our protocol.`
- `Unable to initialize Simulator HID System Manager (%@): %@`

**Static variable**: `IndigoHIDSystemSpawnLoopback.hidSystemManager` — holds the loaded manager

### The SimulatorClientHIDSystemManager Protocol

The HID system manager bundle must provide a class conforming to this protocol. Required methods (inferred from SimulatorClient strings):

```objc
@protocol SimulatorClientHIDSystemManager
- (instancetype)initUsingHIDService:(IOHIDEventSystemRef)hidService error:(NSError **)error;
- (NSArray *)displays;           // Array of display descriptor objects
- (BOOL)hasTouchScreen;
- (BOOL)hasTouchScreenLofi;
- (BOOL)hasWheel;
- (NSString *)name;
- (NSString *)uniqueId;          // e.g., "888ea5d0-700a-11e2-bcfd-0800200c9a66"
- (id)interfaceCapabilities;
@end
```

Each display descriptor must provide (inferred):
```objc
- (NSString *)uniqueID;          // e.g., "Screen#0"
- (NSString *)name;
- (CGSize)screenSize;            // or width/height properties
- (CGFloat)scale;
// ... whatever CADisplay._initWithDisplay: needs
```

### The Host-Side Display Provider

**IndigoLegacyHIDServices.simdeviceio** — Modern CoreSimulator's legacy support

**Location**: `/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/Resources/IndigoLegacyHIDServices.simdeviceio/`

**Architecture**: Universal (x86_64 + arm64e)

**Bundle ID**: `com.apple.CoreSimulator.IndigoLegacyHIDServices`

**Version**: 1051.17.7 (built with Xcode 26.2)

**Exported symbols**:
```
_OBJC_CLASS_$_IndigoHIDLegacyServicesBundleInterface
_OBJC_CLASS_$_IndigoLegacyHIDDescriptor
_simdeviceio_get_interface  — CoreSimulator device I/O plugin entry point
```

This is the ARM64 plugin that the modern CoreSimulatorService loads to provide display/HID services to legacy simulator runtimes. It runs on the HOST side (ARM64 macOS), not in the simulator.

### CoreSimulatorBridge — Inside the Simulator

**Location**: `.../CoreSimulator/RuntimeOverlay/usr/libexec/CoreSimulatorBridge`

**Launch plist**: `.../CoreSimulator/RuntimeOverlay/System/Library/LaunchDaemons/com.apple.CoreSimulator.bridge.plist`

**Mach Services**:
```
com.apple.CoreSimulator.CoreSimulatorBridge.lifecycle_support (ResetAtClose)
com.apple.CoreSimulator.host_support
com.apple.CoreSimulator.pasteboard_support
com.apple.CoreSimulator.pasteboard_promise_support
com.apple.CoreSimulator.accessibility_support
com.apple.CoreSimulator.SimPasteboardInterface
```

**Notification subscriptions**:
- `com.apple.backboardd.safetosetidletimer`
- `com.apple.springboard.ringerstate`
- `com.apple.springboard.volumestate`
- `CSLSCarouselLaunchDidHideLogoNotification`
- `com.apple.CoreSimulator.audio.devices_changed`

### SimulatorBridge — The Host Connection

**Location**: `.../CoreSimulator/RuntimeOverlay/usr/libexec/SimulatorBridge`

**Architecture**: Universal (i386 + x86_64)

**Mach Services**: `com.apple.iphonesimulator.bridge` (ResetAtClose)

**Entitlements**: backboardd launch/debug, frontboard launch/debug

---

## Part 3: The Display Creation Chain (Why It Fails)

### Normal Flow (when simulator works)

```
1. launchd_sim starts backboardd
2. backboardd calls IndigoHIDSystemSpawnLoopback(hidEventSystem)
3. SimulatorClient reads SIMULATOR_HID_SYSTEM_MANAGER env var
4. SimulatorClient loads the HID system manager bundle
5. Bundle connects to host-side IndigoLegacyHIDServices via Mach IPC
6. Host creates IOSurface-backed display surfaces
7. Bundle returns display descriptors to SimulatorClient
8. SimulatorClient creates CADisplay objects
9. backboardd creates CARenderServer render contexts for the displays
10. backboardd registers all 16 Mach services
11. App processes connect to these services normally
12. CoreAnimation commits go through CARenderServer → GPU → IOSurface
13. Host reads IOSurface and displays in Simulator.app window
```

### What Fails (documented in old-simulator-runtime-guide.md)

The failure point is **step 5**: the HID system manager bundle tries to connect to the host's CoreSimulatorService. The protocol has changed between iOS 10.3 era and macOS 26:

**iOS 10.3 backboardd expects**:
- SimulatorClient → `__getSimFramebufferHandle` (old Indigo protocol)
- Display creation through SimulatorClient/HID setup path

**Modern CoreSimulatorService provides**:
- `com.apple.CoreSimulator.IndigoFramebufferServices.Display` (new protocol)
- IndigoLegacyHIDServices.simdeviceio bridge (but mismatched protocol)

The specific error from old-simulator-runtime-guide.md line 226:
```
*** Assertion failure in void BKDisplayStartWindowServer()(),
    backboarddaemon-195.65.1/megatrond/BKDisplay.m:417
*** Terminating app due to uncaught exception 'NSInternalInconsistencyException',
    reason: 'No window server display found'
```

This was from iOS 12.4's backboardd (v195.65.1). iOS 10.3's backboardd (v719) is from a different era and may have different behavior.

### Architecture Change Between iOS Versions

From old-simulator-runtime-guide.md line 566:

| Runtime | How SimFramebufferClient is loaded | Who creates CADisplay? |
|---------|-----------------------------------|----------------------|
| **iOS 12.4** | SimulatorClient → IndigoHIDSystemSpawnLoopback → `__getSimFramebufferHandle` | Unknown — QuartzCore has NO SimFramebufferClient link |
| **iOS 14.5+** | QuartzCore **weak-links** to SimFramebufferClient | QuartzCore calls SFBConnectionCreate → SFBConnectionCopyDisplays |

iOS 10.3 likely uses the iOS 12.4 path (SimulatorClient-driven, not QuartzCore-driven).

---

## Part 4: The Proposed Solution — Custom HID System Manager Bundle

### Approach

Instead of running the full CoreSimulatorService stack, create a **custom x86_64 bundle** that SimulatorClient loads via the `SIMULATOR_HID_SYSTEM_MANAGER` environment variable. This bundle:

1. Conforms to `SimulatorClientHIDSystemManager` protocol
2. Creates display descriptors with the correct properties (375x667 @2x)
3. Provides `hasTouchScreen` → YES
4. Returns display descriptors that SimulatorClient can use to create CADisplay objects

### What This Solves

If SimulatorClient successfully creates CADisplay objects, then:
- backboardd's `BKDisplayStartWindowServer()` finds a display → no crash
- backboardd registers `com.apple.CARenderServer` → CoreAnimation works
- backboardd registers HID services → gesture recognizers work natively
- The entire UIKit rendering pipeline works properly
- tintColor, animations, scroll, keyboard — all work

### The Critical Unknown

**What does CADisplay._initWithDisplay: need?** SimulatorClient imports CADisplay and creates instances. The `_initWithDisplay:` private initializer takes a `CA::WindowServer::Display*` pointer. We need to understand:

1. What is `CA::WindowServer::Display`?
2. Can we fabricate one without a real window server?
3. Does CADisplay initialization require a CARenderServer connection?

This is a chicken-and-egg problem: backboardd IS the CARenderServer, but it needs a CADisplay to start, and CADisplay might need a CARenderServer to initialize.

### Alternative: The SimulatorHIDFallback Path

SimulatorClient has a built-in `SimulatorHIDFallback` class. If `SIMULATOR_HID_SYSTEM_MANAGER` is not set (or the bundle fails to load), SimulatorClient falls back to this class. We should investigate:

1. What does `SimulatorHIDFallback` do?
2. Does it create displays?
3. Can we trigger it intentionally?

### Alternative: Patch BKDisplayStartWindowServer

From old-simulator-runtime-guide.md line 528:
```
Patch backboardd BKDisplayStartWindowServer assertion (NOP je at 0x1cee4)
→ Gets past first assertion but hits second in BKSDisplayServicesStart
  ("main display is nil")
```

This was with iOS 12.4. iOS 10.3's backboardd may have different addresses but the same pattern. Binary patching is fragile but could be tried as a diagnostic tool.

---

## Part 5: Key File Locations (Complete Reference)

### iOS 10.3 SDK (x86_64 simulator binaries)
```
SDK=/Applications/Xcode-8.3.3.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator10.3.sdk

$SDK/usr/libexec/backboardd                              (1.3MB, universal)
$SDK/System/Library/PrivateFrameworks/SimulatorClient.framework/SimulatorClient
$SDK/System/Library/PrivateFrameworks/BackBoardServices.framework/BackBoardServices
$SDK/System/Library/PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices
$SDK/System/Library/PrivateFrameworks/GraphicsServices.framework/GraphicsServices
$SDK/System/Library/Frameworks/QuartzCore.framework/QuartzCore
$SDK/System/Library/Frameworks/UIKit.framework/UIKit
$SDK/System/Library/LaunchDaemons/com.apple.backboardd.plist
```

### RuntimeOverlay (simulator-specific executables)
```
OVERLAY=/Applications/Xcode-8.3.3.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/Library/CoreSimulator/RuntimeOverlay

$OVERLAY/usr/libexec/SimulatorBridge                     (universal i386+x86_64)
$OVERLAY/usr/libexec/CoreSimulatorBridge
$OVERLAY/System/Library/LaunchDaemons/com.apple.SimulatorBridge.plist
$OVERLAY/System/Library/LaunchDaemons/com.apple.CoreSimulator.bridge.plist
```

### iOS 9.3 Runtime
```
RUNTIME=/Library/Developer/CoreSimulator/Profiles/Runtimes/iOS 9.3.simruntime/Contents/Resources/RuntimeRoot

$RUNTIME/usr/lib/dyld_sim
$RUNTIME/usr/libexec/backboardd                          (may differ from 10.3)
```

### Host-Side (ARM64 macOS)
```
/Library/Developer/PrivateFrameworks/CoreSimulator.framework/
  Versions/A/Resources/IndigoLegacyHIDServices.simdeviceio/
    Contents/MacOS/IndigoLegacyHIDServices              (x86_64 + arm64e)
    Contents/Info.plist

/Applications/Xcode-8.3.3.app/Contents/Developer/Library/PrivateFrameworks/SimulatorKit.framework/
/Applications/Xcode-8.3.3.app/Contents/SharedFrameworks/DVTiPhoneSimulatorRemoteClient.framework/
```

### Environment Variables (set by CoreSimulatorService when booting a device)
```
SIMULATOR_HID_SYSTEM_MANAGER  — path to HID system manager bundle
SIMULATOR_DEVICE_NAME         — e.g., "iPhone 6s"
SIMULATOR_MODEL_IDENTIFIER    — e.g., "iPhone8,1"
SIMULATOR_RUNTIME_VERSION     — e.g., "10.3"
SIMULATOR_MAINSCREEN_WIDTH    — e.g., "750"
SIMULATOR_MAINSCREEN_HEIGHT   — e.g., "1334"
SIMULATOR_MAINSCREEN_SCALE    — e.g., "2.0"
SIMULATOR_EXTENDED_DISPLAY_PROPERTIES — display config
DYLD_ROOT_PATH               — SDK root for framework resolution
```

---

## Part 6: CARenderServer API Surface

### Complete Function List (114 public C functions)

**Capture (10)**:
CARenderServerCaptureClient, CARenderServerCaptureClientList, CARenderServerCaptureDisplay, CARenderServerCaptureDisplayClientList, CARenderServerCaptureDisplayClientListWithTransform, CARenderServerCaptureDisplayClientListWithTransformList, CARenderServerCaptureDisplayExcludeList, CARenderServerCaptureLayer, CARenderServerCaptureLayerWithTransform, CARenderServerCaptureLayerWithTransformAndTimeOffset

**Render (11)**:
CARenderServerRenderClient, CARenderServerRenderClientList, CARenderServerRenderDisplay, CARenderServerRenderDisplayClientList, CARenderServerRenderDisplayClientListWithTransform, CARenderServerRenderDisplayClientListWithTransformList, CARenderServerRenderDisplayExcludeList, CARenderServerRenderDisplayLayerWithTransformAndTimeOffset, CARenderServerRenderDisplayLayerWithTransformTimeOffsetAndFlags, CARenderServerRenderLayer, CARenderServerRenderLayerWithTransform

**Buffer (8)**:
CARenderServerCreateBuffer, CARenderServerDestroyBuffer, CARenderServerGetBufferData, CARenderServerGetBufferDataSize, CARenderServerGetBufferHeight, CARenderServerGetBufferRowBytes, CARenderServerGetBufferWidth, CARenderServerGetNeededAlignment

**Port (3)**: CARenderServerGetClientPort, CARenderServerGetPort, CARenderServerGetServerPort

**Lifecycle (4)**: CARenderServerStart, CARenderServerShutdown, CARenderServerIsRunning, CARenderServerRegister, CARenderServerPurgeServer

**Debug (11)**: CARenderServerClearDebugOptions, CARenderServerCopyUpdateHistograms, CARenderServerGetDebugFlags, CARenderServerGetDebugOption, CARenderServerGetDebugValue, CARenderServerSetDebugFlags, CARenderServerSetDebugMessage, CARenderServerSetDebugOption, CARenderServerSetDebugValue, CARenderServerSetMessageFile

**Statistics (5)**: CARenderServerGetFrameCounter, CARenderServerGetFrameCounterByIndex, CARenderServerGetInfo, CARenderServerGetPerformanceInfo, CARenderServerGetStatistics

### MIG Protocol (from BackBoardServices analysis)
- `BKSDisplayServicesStart` sends MIG msg ID **6001000** (0x5B9168)
  - Expected reply ID: **6001100** with `{RetCode=0, isAlive=TRUE}`
- `BKSDisplayServicesGetMainScreenInfo` sends MIG msg ID **6001005**
  - Expected reply: `{width, height, scaleX, scaleY}` as floats

### CA::Render::Server Key Methods (from demangled symbols)
```cpp
CA::Render::Server::server_port()
CA::Render::Server::notify_port()
CA::Render::Server::port_set()
CA::Render::Server::port_set_qlimit()
CA::Render::Server::destroy_ports()
CA::Render::Server::register_name()
CA::Render::Server::start()
CA::Render::Server::stop()
CA::Render::Server::is_running()
CA::Render::Server::kick_server()
CA::Render::Server::server_thread(void*)
CA::Render::Server::dispatch_notify_message(mach_msg_header_t*)
CA::Render::Server::dispatch_services_message(mach_msg_header_t*)
CA::Render::Server::ReceivedMessage::dispatch()
CA::Render::Server::ReceivedMessage::send_reply()
CA::Render::Server::ReceivedMessage::run_command_stream()
```

### CA::Render::Context Key Methods
```cpp
CA::Render::Context::server_port()
CA::Render::Context::will_commit()
CA::Render::Context::did_commit(bool, bool)
CA::Render::Context::synchronize(uint32_t, uint32_t)
CA::Render::Context::update_layer(uint64_t)
CA::Render::Context::root_layer()
CA::Render::Context::set_visible(bool)
CA::Render::Context::invalidate(const Bounds&)
```

---

## Part 7: What Session 7 Changed in the Code

### Bridge Changes (`src/bridge/rosettasim_bridge.m`)

1. **`_force_full_refresh` no longer set on every touch/keyboard event** — `_mark_display_dirty()` now only sets `_force_display_countdown` without setting `_force_full_refresh`. This preserves cached backing stores (tint colors, selection states) during interaction.

2. **`_force_display_recursive` now handles tintColor views** — Added detection for UISegmentedControl and UIImageView, calls `tintColorDidChange` to trigger CPU-side template image colorization.

3. **Removed @autoreleasepool around sendEvent: crash guard** — `siglongjmp` from inside `@autoreleasepool` corrupts the pool stack. The `@autoreleasepool` was causing the scroll/drag crash.

4. **Added SIGSEGV guard around frame_capture_tick rendering** — The layout/render phase (`CATransaction.flush`, `layoutIfNeeded`, `_force_display_recursive`, `renderInContext:`) is now wrapped in a crash guard so rendering crashes skip the frame instead of killing the process.

### Host App Changes (`src/host/RosettaSimApp/RosettaSimApp.swift`)

1. **GeometryReader-based device chrome** — `DeviceChromeView` now scales to fill available space instead of fixed 375x667.

2. **Keyboard write order fix** — `sendKeyEvent` now writes `key_char` and `key_flags` BEFORE `key_code`. `key_code` is the signal to the bridge; writing it last prevents partial event reads. Character-only input (key_code=0, char!=0) uses sentinel 0xFFFF.

3. **Keyboard focus improvements** — Added `keyUp`, `flagsChanged`, and `performKeyEquivalent` overrides to `SimulatorDisplayView` for robust keyboard capture.

### Test Tool Changes (`tests/fb_interact.c`)

1. **Added `drag` command** — `drag x1 y1 x2 y2` sends BEGAN + 10 MOVED + ENDED.
2. **Keyboard write order fix** — Matches host app change (key_char before key_code).

### Bridge-Side Keyboard Protocol

Bridge's `check_and_inject_keyboard()` updated to:
- Only check `key_code != 0` as the event signal (not `key_char`)
- Handle sentinel value 0xFFFF (character-only input, convert to key_code=0)

---

## Part 8: Recommended Next Steps

### Priority 1: Try Launching backboardd

The most valuable next step is to simply TRY launching the iOS 10.3 SDK's backboardd binary and capture the exact failure. The previous attempts (documented in old-simulator-runtime-guide.md) were with iOS 12.4's backboardd. iOS 10.3's may behave differently.

```bash
SDK=".../iPhoneSimulator10.3.sdk"
export DYLD_ROOT_PATH="$SDK"
export HOME="$PROJECT_ROOT/.sim_home"
export CFFIXED_USER_HOME="$HOME"
# Set display env vars
export SIMULATOR_MAINSCREEN_WIDTH="750"
export SIMULATOR_MAINSCREEN_HEIGHT="1334"
export SIMULATOR_MAINSCREEN_SCALE="2.0"
export SIMULATOR_DEVICE_NAME="iPhone 6s"
# Try running backboardd
"$SDK/usr/libexec/backboardd" 2>&1
```

Capture the exact error. It will either:
a) Crash at IndigoHIDSystemSpawnLoopback (no HID manager bundle) → fixable
b) Crash at BKDisplayStartWindowServer (no display) → needs display bridge
c) Hang waiting for launchd service registration → needs bootstrap setup
d) Something else entirely

### Priority 2: Investigate SimulatorHIDFallback

If backboardd crashes because SIMULATOR_HID_SYSTEM_MANAGER is unset, SimulatorClient falls back to its built-in `SimulatorHIDFallback`. Understanding what this fallback does could reveal a path that doesn't require the host-side infrastructure.

### Priority 3: Write a Custom HID System Manager Bundle

If the fallback doesn't work, write a minimal x86_64 `.bundle` that:
1. Has an ObjC class conforming to `SimulatorClientHIDSystemManager`
2. Returns a display descriptor for iPhone 6s (375x667 @2x)
3. Returns `hasTouchScreen` → YES
4. Point `SIMULATOR_HID_SYSTEM_MANAGER` at this bundle

The display descriptor must satisfy whatever `CADisplay._initWithDisplay:` expects. This is the critical unknown that needs Ghidra analysis of the `_initWithDisplay:` method in QuartzCore.

### Priority 4: Bootstrap Port Setup

backboardd registers its services via launchd's MachServices dictionary. Without launchd, it needs to use `bootstrap_register` directly. Our existing `bootstrap_register2` interposition handles this for the app process. If backboardd runs as a separate process, both processes need to share a bootstrap namespace.

Options:
a) Run backboardd and the app in the same process (unlikely to work — backboardd has its own run loop)
b) Create a shared Mach port that both processes use as their bootstrap port
c) Use launchd's standard subprocess mechanism

### Priority 5: Analyze with Ghidra

Use Ghidra to decompile:
1. `IndigoHIDSystemSpawnLoopback` in SimulatorClient.framework — full function body
2. `CADisplay._initWithDisplay:` in QuartzCore.framework — what does it need?
3. `BKDisplayStartWindowServer` in backboardd — what assertion fails?
4. `SimulatorHIDFallback` class methods — what does the fallback do?

---

## Part 9: What We MUST Stop Doing

1. **Stop adding crash guards** — Every siglongjmp is a ticking time bomb for pool corruption
2. **Stop adding rendering hacks** — renderInContext: cannot replicate CARenderServer
3. **Stop adding UIControl-specific handling** — The direct delivery fallback (UIButton tracking, UISegmentedControl segment calculation) is duplicating what gesture recognizers do natively when CARenderServer works
4. **Stop growing the bridge** — It's 4000+ lines and every addition makes the code harder to maintain

### What We SHOULD Do

Provide the real services. The architecture is clear. The question is whether we can make backboardd run. If we can, the bridge shrinks from 4000 lines to maybe 200 (just framebuffer capture from the real rendering pipeline).
