# RosettaSim: Custom iOS Simulator for Legacy Runtimes

## Project Goal

Run legacy iOS applications (targeting iOS 9.x / 10.x) in a simulated environment on modern macOS 26 (ARM64 Apple Silicon), without requiring Apple's CoreSimulator or old Xcode versions at runtime.

## Problem Statement

Apple's iOS Simulator is tightly coupled to CoreSimulator.framework, which is version-locked to specific Xcode and macOS releases. Old simulator runtimes (iOS 9, 10) cannot be loaded by modern CoreSimulator, and old CoreSimulator cannot run on modern macOS. This project bypasses CoreSimulator entirely with a custom simulator host.

## Target Configuration

| Component | Value |
|---|---|
| Host OS | macOS 26.x (ARM64, Apple Silicon) |
| Host Xcode | Xcode 26.x (for modern development) |
| Translation Layer | Rosetta 2 (x86_64 → ARM64) |
| Source SDK | Xcode 8.3.3 iPhoneSimulator10.3.sdk |
| Target iOS | iOS 9.x and 10.x simulator apps |
| App Architecture | x86_64 (64-bit simulator target) |

### Out of Scope (Initially)

- i386 (32-bit x86) simulator apps — Rosetta 2 does not translate i386
- armv7 (32-bit ARM) — Apple Silicon has no AArch32 execution state
- Physical device deployment — only simulator execution
- Full Xcode IDE integration — standalone app first

---

## Architecture Overview

### System Diagram

```
┌─────────────────────────────────────────────────────────┐
│  RosettaSim.app  (native ARM64 macOS application)       │
│                                                          │
│  ┌────────────────────────────────────────────────────┐ │
│  │ Device Window (NSWindow + CALayer)                  │ │
│  │  ┌──────────────────────────────────────────────┐  │ │
│  │  │ Display Surface                               │  │ │
│  │  │ (IOSurface shared with simulated process)     │  │ │
│  │  └──────────────────────────────────────────────┘  │ │
│  │  Mouse → UITouch translation                       │ │
│  │  Keyboard → UIKeyboard events                      │ │
│  └────────────────────────────────────────────────────┘ │
│                                                          │
│  ┌────────────────────────────────────────────────────┐ │
│  │ Services Layer                                      │ │
│  │  - Process Manager (launch, monitor, kill)          │ │
│  │  - Mach Port Server (IPC with simulated process)    │ │
│  │  - IOSurface Server (frame sharing)                 │ │
│  │  - Host Service Proxy (FSEvents, configd, audio)    │ │
│  │  - Device Model (screen size, scale, rotation)      │ │
│  └────────────────────────────────────────────────────┘ │
└──────────────────────────┬──────────────────────────────┘
                           │
              Mach IPC + IOSurface (cross-architecture)
                           │
┌──────────────────────────▼──────────────────────────────┐
│  Simulated Process  (x86_64, runs under Rosetta 2)      │
│                                                          │
│  ┌──────────────────────────────────────────────────┐   │
│  │ User's iOS App                                    │   │
│  │ (Mach-O x86_64, compiled for simulator target)    │   │
│  └──────────────┬───────────────────────────────────┘   │
│                  ▼                                       │
│  ┌──────────────────────────────────────────────────┐   │
│  │ dyld_sim  (from iPhoneSimulator10.3.sdk)          │   │
│  │ Rewrites /System/Library/... → {SDK_ROOT}/...     │   │
│  └──────────────┬───────────────────────────────────┘   │
│                  ▼                                       │
│  ┌──────────────────────────────────────────────────┐   │
│  │ iOS Simulator Frameworks (from SDK)               │   │
│  │                                                    │   │
│  │  UIKit.framework          (48 MB, x86_64+i386)    │   │
│  │  Foundation.framework     (9.9 MB)                 │   │
│  │  CoreGraphics.framework                            │   │
│  │  CoreAnimation (QuartzCore.framework)              │   │
│  │  + 88 more public frameworks                       │   │
│  │  + 475 private frameworks                          │   │
│  │  + 105 system dylibs                               │   │
│  └──────────────┬───────────────────────────────────┘   │
│                  ▼                                       │
│  ┌──────────────────────────────────────────────────┐   │
│  │ RosettaSim Bridge  (x86_64 dylib, our code)       │   │
│  │                                                    │   │
│  │  - Replaces Apple's SimulatorBridge Mach service   │   │
│  │  - Intercepts CoreAnimation rendering output       │   │
│  │  - Shares rendered frames via IOSurface to host    │   │
│  │  - Receives touch/keyboard events via Mach IPC     │   │
│  │  - Provides simulated device properties            │   │
│  │  - Shims any macOS APIs that changed since 10.12   │   │
│  └──────────────┬───────────────────────────────────┘   │
│                  ▼                                       │
│  ┌──────────────────────────────────────────────────┐   │
│  │ macOS 26 System Libraries                         │   │
│  │ (accessed via Rosetta 2 x86_64→ARM64 translation) │   │
│  │                                                    │   │
│  │  XNU kernel syscalls (Mach + BSD)                  │   │
│  │  libSystem, libdispatch, libobjc                   │   │
│  │  IOKit, Security, CoreServices                     │   │
│  └──────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────┘
```

---

## Component Details

### 1. RosettaSim Host App (ARM64)

**Language:** Swift + AppKit/SwiftUI
**Purpose:** Native macOS application that manages and displays simulated iOS devices.

**Responsibilities:**
- Render a window representing the simulated device screen
- Optionally display device chrome (phone bezel, home button, notch)
- Translate mouse events to touch coordinates relative to the simulated screen
- Forward keyboard events to the simulated process
- Provide toolbar controls: rotation, shake, screenshot, slow animations
- Manage simulated device lifecycle (boot, shutdown, reset)
- Serve as the Mach bootstrap port parent for the simulated process

**Key Implementation Details:**
- The display surface is backed by an `IOSurface` that is shared with the simulated process
- The host creates a `CALayer` whose contents are set to this `IOSurface`
- Frame updates are signaled via Mach IPC notification from the bridge
- Input events are serialized and sent via Mach message to the bridge

### 2. Process Launcher

**Purpose:** Launch the simulated app as a child process with the correct environment.

**Environment Variables Set:**
```bash
DYLD_ROOT_PATH={SDK_ROOT}
IPHONE_SIMULATOR_ROOT={SDK_ROOT}
SIMULATOR_ROOT={SDK_ROOT}
SIMULATOR_RUNTIME_BUILD_VERSION=14E8301
SIMULATOR_DEVICE_NAME=iPhone 6s
SIMULATOR_MODEL_IDENTIFIER=iPhone8,1
SIMULATOR_RUNTIME_VERSION=10.3
SIMULATOR_MAINSCREEN_WIDTH=750
SIMULATOR_MAINSCREEN_HEIGHT=1334
SIMULATOR_MAINSCREEN_SCALE=2.0
HOME={simulated_home_directory}
CFFIXED_USER_HOME={simulated_home_directory}
TMPDIR={simulated_tmp_directory}
```

**Launch Sequence:**
1. Create simulated device filesystem (~/Library, ~/Documents, ~/tmp, etc.)
2. Set up Mach bootstrap port subset for the simulated process
3. Register RosettaSim Bridge Mach services in the bootstrap subset
4. Fork and exec the app binary with `arch -x86_64` prefix
5. The kernel loads `dyld_sim` as the dynamic linker (from LC_DYLINKER in the app binary)
6. `dyld_sim` loads all frameworks from `DYLD_ROOT_PATH`
7. App's `main()` calls `UIApplicationMain()` which initializes UIKit

### 3. RosettaSim Bridge Library (x86_64)

**Language:** C/Objective-C (must be x86_64 to run in the simulated process)
**Injection:** Via `DYLD_INSERT_LIBRARIES` environment variable
**Purpose:** Replace Apple's SimulatorBridge and provide the rendering/input bridge.

**Responsibilities:**

#### Rendering Bridge
- Hook `CAContext` or `CARemoteLayerServer` initialization
- Create a shared `IOSurface` for the simulated screen dimensions
- Direct CoreAnimation's rendering output to this surface
- Signal the host process when a new frame is ready via Mach notification

#### Input Bridge
- Listen on a Mach port for input events from the host
- Translate received events into UIKit-compatible touch/keyboard events
- Inject events into the UIKit event queue via `GraphicsServices` or `UIApplication` private API

#### Device Property Provider
- Respond to UIKit queries for device properties (screen size, scale, model)
- Provide simulated status bar information
- Handle orientation change requests

#### macOS Compatibility Shims
- Intercept calls to macOS APIs that changed between 10.12 and 26
- Provide stub implementations for removed private frameworks
- Redirect deprecated API calls to modern equivalents

### 4. Host Service Proxy

**Purpose:** The simulator runtime expects certain macOS services to be available via Mach IPC.

**Required Services (from profile.plist):**
| Service | Purpose | Strategy |
|---|---|---|
| `com.apple.FSEvents` | File system event monitoring | Proxy to real service |
| `com.apple.audio.coreaudiod` | Audio playback/recording | Proxy to real service |
| `com.apple.audio.audiohald` | Audio hardware abstraction | Proxy to real service |
| `com.apple.SystemConfiguration.configd` | Network configuration | Proxy to real service |
| `com.apple.PowerManagement.control` | Power/battery simulation | Stub (return fake battery info) |

**Strategy:** Most services can be proxied directly to the real macOS services (they're still present in macOS 26). For services that changed incompatibly, we provide adapter implementations.

### 5. SDK Root (Framework Provider)

**Source:** `/Applications/Xcode-8.3.3.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator10.3.sdk`

**Contents:**
- 91 public frameworks (UIKit, Foundation, CoreGraphics, AVFoundation, etc.)
- 475 private frameworks (GraphicsServices, FrontBoardServices, BackBoardServices, etc.)
- 105 system dylibs (libSystem, libobjc, libc++, libdispatch, etc.)
- `dyld_sim` — the simulator's custom dynamic linker
- `usr/lib/system/` — low-level system library implementations
- `usr/lib/system/host/` — libraries explicitly loaded from host macOS

**Key Libraries in the Dependency Chain:**
```
UIKit
  → Foundation, CoreFoundation
  → CoreGraphics, QuartzCore (CoreAnimation)
  → UIFoundation, CoreUI (private)
  → GraphicsServices, FrontBoardServices, BackBoardServices (private)
  → OpenGLES (iOS-specific, in SDK)
  → IOKit (bridged to host)
  → libSystem.B.dylib
    → libdyld_sim.dylib (simulator-specific dyld bridge)
    → libdispatch.dylib
    → libsystem_c.dylib
    → libsystem_kernel.dylib (real syscalls to host XNU)
    → libsystem_pthread.dylib
    → libobjc.A.dylib
```

All framework paths in the binary use absolute paths like `/System/Library/Frameworks/UIKit.framework/UIKit`. `dyld_sim` prepends the SDK root to resolve these to the correct location.

---

## Rendering Pipeline Detail

### Apple's Simulator Rendering (Reference)

```
UIView hierarchy
  → CALayer tree
    → CoreAnimation commit
      → Render server (backboardd equivalent in sim)
        → GPU compositing
          → CARemoteLayerServer / IOSurface
            → SimulatorBridge Mach service
              → Simulator.app host window
```

### RosettaSim Rendering (Our Implementation)

```
UIView hierarchy
  → CALayer tree
    → CoreAnimation commit
      → [INTERCEPTED by RosettaSim Bridge]
        → Render to shared IOSurface
          → Mach notification to host
            → Host CALayer.contents = IOSurface
              → Native macOS window display
```

**Interception Strategy Options:**

1. **Method swizzle on CAContext** — Override the method that submits frames to the render server. Redirect output to our IOSurface instead.

2. **Custom backboardd** — The simulator normally runs its own `backboardd` process (the display server). We could provide a custom minimal implementation that renders to IOSurface directly.

3. **Window server redirection** — If the simulated UIKit creates a real macOS window, we could capture it directly. However, this is unlikely to work cleanly since the simulated process shouldn't have window server access.

4. **offscreen rendering via CARenderer** — Force CoreAnimation to render offscreen into our IOSurface using `CARenderer`.

Option 2 (custom backboardd) is probably the cleanest separation of concerns. We control the entire display pipeline.

---

## Experimental Findings (2026-02-19)

### Critical Discovery: Platform Check Bypass

A macOS-targeted x86_64 binary **cannot** `dlopen()` iOS simulator frameworks. Modern dyld rejects them:

```
incompatible platform (have 'iOS-simulator', need 'macOS')
```

The solution: compile the test binary for the **iphonesimulator** platform:

```bash
clang -arch x86_64 \
  -isysroot {SDK_ROOT} \
  -mios-simulator-version-min=10.0 \
  -o test test.c
```

This produces a Mach-O with `LC_VERSION_MIN_IPHONEOS`. When executed with `DYLD_ROOT_PATH` set, host dyld recognizes the simulator platform and chains to `dyld_sim` from the SDK root. The platform check passes because everything in the process is iOS-simulator platform.

**Key requirement:** `DYLD_ROOT_PATH` must be set in the environment. The `arch -x86_64` wrapper strips `DYLD_*` variables (SIP protection), so the binary must be launched directly (Rosetta 2 activates automatically for x86_64 binaries on Apple Silicon).

`DYLD_FORCE_PLATFORM` env var exists in dyld but did not bypass the check (likely requires SIP disabled or special entitlements).

### Phase 1 Results: PASSED

**Test:** Compile a minimal C program for iphonesimulator x86_64 target, set `DYLD_ROOT_PATH` to the iOS 10.3 SDK, run directly.

| Component | Result |
|---|---|
| `dyld_sim` from 2017 on macOS 26 kernel | **Works** |
| Old `libSystem.B.dylib` via Rosetta 2 | **Works** |
| `write()` syscall from old libc | **Works** |
| Environment variables (`DYLD_ROOT_PATH`, etc.) | **Visible in process** |

**Conclusion:** The fundamental execution chain — old `dyld_sim` → old libSystem → Rosetta 2 translation → ARM64 XNU kernel — is functional.

### Phase 2 Results: PASSED (13/13 tests)

**Test:** Load frameworks via `dlopen()`, resolve symbols, call functions, use the Objective-C runtime.

#### 2A — CoreFoundation

| Function | Result | Notes |
|---|---|---|
| `CFStringCreateWithCString` | Works | Returns valid CFStringRef |
| `CFStringGetLength` | Works | Returns correct length (34) |
| `CFStringGetCString` | Works | Round-trips string exactly |
| `CFGetRetainCount` | Works | Returns 1 for new object |
| `CFRetain` / `CFRelease` | Works | Retain count cycles 1→2→1 correctly |
| `CFArrayCreate` | Works | Creates array with correct count |

#### 2B — Foundation

| Function | Result | Notes |
|---|---|---|
| `NSLog` with format args | Works | Produces timestamped output with PID |
| `NSLog` with unicode | Works | éàü ✓ rendered correctly |

#### 2C — Objective-C Runtime

| Function | Result | Notes |
|---|---|---|
| `objc_getClass("NSObject")` | Works | Root class found |
| `objc_getClass("NSString")` | Works | Foundation class found |
| `objc_getClass("NSMutableArray")` | Works | Collection class found |
| `[[NSString alloc] initWithUTF8String:]` | Works | Full alloc/init chain via `objc_msgSend` |
| `NSMutableArray` create/addObject:/count | Works | 3 items added, count verified |
| `objc_getClass("UIView")` | Works | **UIKit class accessible** |

**Conclusion:** The entire iOS 10.3 simulator framework stack from 2017 — CoreFoundation, Foundation, the Objective-C runtime, and UIKit — loads, links, and executes correctly on macOS 26 ARM64 via Rosetta 2.

### SDK Inventory (Xcode 8.3.3 iPhoneSimulator10.3.sdk)

| Category | Count | Architecture |
|---|---|---|
| Public Frameworks | 91 | Universal i386 + x86_64 |
| Private Frameworks | 475 | Universal i386 + x86_64 |
| System dylibs (`usr/lib/`) | 105 | Universal i386 + x86_64 |
| **Total libraries** | **671** | All real implementations (not stubs) |

Notable sizes: UIKit 48MB, Foundation 9.9MB, dyld_sim 482K.

The SDK is nearly self-contained. The dependency chain bottoms out at:
- `libSystem.B.dylib` → re-exports `libdyld_sim.dylib`, `libdispatch.dylib`, `libsystem_c.dylib`, `libsystem_kernel.dylib`, etc.
- `usr/lib/system/host/` → libraries explicitly loaded from host macOS
- `_sim` variants (e.g. `libdyld_sim.dylib`) bridge simulator behavior to host

The runtime profile (`profile.plist`) declares:
- `minHostVersion`: 10.11.0 (El Capitan)
- Required host services: FSEvents, coreaudiod, audiohald, configd, PowerManagement

### Compilation Recipe

```bash
SDK="/Applications/Xcode-8.3.3.app/Contents/Developer/Platforms/\
iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator10.3.sdk"

# Compile for simulator
clang -arch x86_64 \
  -isysroot "$SDK" \
  -mios-simulator-version-min=10.0 \
  -F"$SDK/System/Library/Frameworks" \
  -framework CoreFoundation \
  -framework Foundation \
  -o my_test my_test.c

# Run (DYLD_ROOT_PATH is mandatory)
DYLD_ROOT_PATH="$SDK" ./my_test
```

The binary must be run directly — not via `arch -x86_64` (which strips DYLD_* vars).

---

## Phased Development Plan

### Phase 1: Feasibility Test — COMPLETED ✓
**Goal:** Determine if old x86_64 simulator libraries can load on macOS 26 via Rosetta 2.

**Result:** Full success. dyld_sim, libSystem, and all 671 framework libraries load and execute.

### Phase 2: Framework Function Calling — COMPLETED ✓
**Goal:** Call CoreFoundation, Foundation, and Objective-C runtime functions from old simulator frameworks.

**Result:** Full success. 13/13 tests passed. CFString creation/manipulation, NSLog, objc_msgSend, NSString/NSMutableArray creation and method calling all work. UIKit classes are accessible.

### Phase 3: UIKit Initialization — COMPLETED ✓
**Goal:** Call `UIApplicationMain()` and get UIKit to initialize its internal state.

**Result:** UIKit initialization proceeds through `_UIApplicationMainPreparations` and crashes at exactly the expected point: `BKSDisplayServicesStart()` in BackBoardServices. The crash is a clean `NSInternalInconsistencyException`:

```
backboardd isn't running, result: 268435459 isAlive: 0
```

Call stack at crash:
```
UIApplicationMain → _UIApplicationMainPreparations → BKSDisplayServicesStart
  → Tries to connect to backboardd Mach service
  → Bootstrap port lookup fails (0x10000003)
  → Assertion failure → NSException
```

**Everything before this point works:** UIKit, BackBoardServices, FrontBoardServices, GraphicsServices, and all dependencies load and initialize. The failure is at a single, well-defined service boundary — the connection to `backboardd`.

**Phase 4 requirement identified:** Provide a stub `backboardd` Mach service that `BKSDisplayServicesStart()` can connect to.

### Phase 4: Rendering Bridge — PLANNED
**Goal:** Display a simulated iOS screen in a native macOS window.

**Approach:** Hybrid interposition (DYLD_INSERT_LIBRARIES + selective Mach service stubs).
Three independent agent analyses all converged on this recommendation.

**Key discovery (agent team, 2026-02-19):** The backboardd plist in the SDK declares 14 Mach services. The exact MIG protocol was reverse-engineered from the BackBoardServices binary:
- `BKSDisplayServicesStart` sends MIG msg ID **6001000** (0x5B9168), expects reply ID **6001100** with `{RetCode=0, isAlive=TRUE}`
- `BKSDisplayServicesGetMainScreenInfo` sends MIG msg ID **6001005**, expects reply with `{width, height, scaleX, scaleY}` as floats
- After display services pass, UIKit calls `[CADisplay mainDisplay]` which needs `com.apple.CARenderServer`

**Sub-phases:**

**4a:** Interpose `BKSDisplayServicesStart()` + call `GSSetMainScreenInfo()` → bypass "backboardd isn't running"
**4b:** Handle `CADisplay`/`CARenderServer` → bypass "[CADisplay mainDisplay] is nil"
**4c:** Get `application:didFinishLaunchingWithOptions:` called
**4d:** Render a frame to IOSurface via `CARenderer` + display in native ARM64 host window

**Implementation detail:**
```c
// Bridge library injected via DYLD_INSERT_LIBRARIES
// Interposes C functions via __DATA,__interpose section:
//   BKSDisplayServicesStart()         → return true, call GSSetMainScreenInfo
//   BKSDisplayServicesServerPort()    → return MACH_PORT_NULL
//   BKSDisplayServicesGetMainScreenInfo() → fill screen dimensions
//   BKSWatchdogGetIsAlive()           → return true
//   CARenderServerGetServerPort()     → return MACH_PORT_NULL (forces local rendering)
```

**Phase 4a Results (2026-02-19):**
- `application:didFinishLaunchingWithOptions:` successfully called
- `UIScreen.mainScreen` exists with valid properties
- `UIDevice.model` = "iPhone", `UIDevice.systemVersion` = "10.3.1"
- Technique: UIApplicationMain wrapped with setjmp/longjmp abort guard
- Key gotchas discovered:
  - `bootstrap_port` is NULL in simulator — fix via `task_get_special_port(TASK_BOOTSTRAP_PORT)`
  - `__DATA,__interpose` doesn't work for all functions under old `dyld_sim`
  - Runtime binary patching (write `ret`) doesn't work under Rosetta 2 (translation cache)
  - UIApplication singleton survives the abort but `sharedApplication` returns nil

**Phase 4b Results (2026-02-19):**
- UIView + UILabel + fonts + CoreText all render correctly via `[CALayer renderInContext:]`
- Full Retina 750x1334 pixel output verified
- One-shot rendering confirmed in test harnesses

**Deliverable:** A macOS window showing content rendered by the simulated UIKit.

### Phase 5: Continuous Rendering + Live Display — COMPLETE (2026-02-20)
**Goal:** Timer-driven frame capture with live display in native host app.

**Architecture:**
```
Bridge (x86_64):                      Host App (ARM64):
  CFRunLoopTimer @ 30fps                Timer @ 60fps poll
       │                                     │
  [CALayer renderInContext:]            mmap(framebuffer)
       │                                     │
  CGBitmapContext → mmap'd file         CGDataProvider → CGImage
       │                                     │
  frame_counter++                       NSImage → SwiftUI
```

**Shared Framebuffer (IPC):**
- File: `/tmp/rosettasim_framebuffer` (~4MB mmap'd file)
- Header: 64 bytes (magic, dimensions, frame counter, flags)
- Pixel data: 750×1334 BGRA @ 32bpp
- Bridge writes, host reads; frame_counter used for change detection
- Defined in `src/shared/rosettasim_framebuffer.h`

**Key discoveries:**
1. **UIWindow.hidden defaults to YES** — Phase 4b tests used UIView (hidden=NO), Phase 5 uses UIWindow which defaults hidden=YES. `renderInContext:` respects the hidden flag and produces zero pixels. Fix: explicit `setHidden:NO`.
2. **CATransaction flush required** — Without CARenderServer, the normal CoreAnimation commit cycle never runs. Pending property changes (background colors, text) don't reach layer backing stores. Fix: `[CATransaction flush]` before rendering.
3. **displayIfNeeded on layer tree** — Layer contents (backing stores) are never populated without the display server pipeline. Fix: recursive `setNeedsDisplay` + `displayIfNeeded` on the root layer and all sublayers before `renderInContext:`.
4. **makeKeyAndVisible crashes** — UIWindow.makeKeyAndVisible requires UIApplication.sharedApplication (nil after longjmp). Process exits immediately. Work around by setting hidden=NO manually.

**Performance:** ~29 FPS sustained (30 FPS target), frame counter reaches 580+ in 20s.

**Live content verified:** Uptime counter and clock label update every second, confirming the run loop, NSTimer, and re-rendering pipeline all function correctly.

### Phase 6: Touch Injection + Real App Loading — COMPLETE (2026-02-20)
**Goal:** Interactive touch from host app, real .app bundle loading.

**Architecture (touch):**
```
Host App (ARM64):                Bridge (x86_64):
  NSView mouseDown/Up              check_and_inject_touch()
       │                                │
  Convert to iOS points            Read input region from mmap
  (375x667 coordinate space)            │
       │                           convertPoint:fromView: per subview
  Write to mmap input region       pointInside:withEvent: for hit test
  (offset 64, counter+phase+xy)         │
                                   touchesBegan:/touchesEnded: on target
```

**Shared Framebuffer v2:**
- Meta region expanded to 128 bytes (64-byte header + 64-byte input region)
- Input region: touch_counter(u64), phase(u32), x(f32), y(f32), id(u32), timestamp(u64)
- Pixel data at offset 128

**Key fixes this session:**
1. **UIApplication.sharedApplication recovered** — singleton pointer `_UIApp` was nil after longjmp. Fix: catch "only one UIApplication" NSException from alloc+init, then alloc again post-exception to get the existing instance, write it to `_UIApp` via dlsym.
2. **BKSEventFocusManager swizzled** — with sharedApplication working, UIKit triggers more code paths that call backboardd. Swizzled BKSEventFocusManager and BKSAnimationFenceHandle methods to no-ops.
3. **makeKeyAndVisible swizzled** — real apps call this during didFinishLaunching. Replaced with layer setHidden:NO to avoid BKSEventFocusManager crash.
4. **Multi-box rendering** — `_force_display_recursive` was calling displayIfNeeded on ALL layers, creating empty backing stores that covered backgroundColor. Fix: compare drawRect: IMP against UIView base to only force display for views with custom drawing (UILabel, etc.).
5. **Font rendering in .app bundles** — CoreText auto-activation fails without fontd. Fix: `__CTFontManagerDisableAutoActivation=1` env var.
6. **Host app mmap** — O_RDONLY fd with PROT_WRITE mmap fails silently. Fix: O_RDWR.
7. **Display orientation** — Bridge renders in standard CG coords (bottom-up, text correct). Host app flips via translateBy/scaleBy(-1) in NSView draw().
8. **Position-based hit testing** — Uses convertPoint:fromView: + pointInside:withEvent: per subview instead of CGRect reading (which crashes under Rosetta 2 via objc_msgSend_stret).

**Real app results:**
- **Preferences.app** (iOS 10.3 SDK system app): Launches, UIApplication subclass detected, didFinishLaunchingWithOptions called. Hangs in UI setup (needs more infrastructure stubs).
- **hass-dashboard** (user's real iOS app): Compiled for x86_64 simulator with modern Xcode. Full startup: font loading, keychain reads, login view controller, navigation controller. Enters run loop at 30fps.

### Phase 6b: White Screen Fix + Performance (2026-02-20, Session 2)
**Goal:** Fix hass-dashboard white screen, improve display forcing, add UIEvent touch delivery, eliminate flashing.

**Key fixes:**
1. **makeKeyAndVisible rootVC loading** — The swizzled makeKeyAndVisible only set layer hidden=NO but didn't load the rootViewController's view. Real apps set `window.rootViewController = navController` and expect makeKeyAndVisible to call `_installRootViewControllerIntoWindow:`. Fix: manually get rootVC.view, set its frame, add as subview, call viewWillAppear:. Avoids CGRect struct return (crashes under Rosetta 2 via objc_msgSend_stret) by using known screen dimensions.

2. **Widened display forcing** — Original only checked drawRect: IMP. Now also checks: drawLayer:inContext: (UIPageControl, UIProgressView), displayLayer: (custom CALayer delegates), and private UIKit classes (class name starts with `_`, e.g. _UIBarBackground, _UINavigationBarBackground). Still skips plain UIView to preserve backgroundColor rendering.

3. **UITouch/UIEvent-based touch delivery** — Previous approach called touchesBegan: directly with empty NSSet + nil event. New approach: creates UITouch objects with phase, location (_setLocationInWindow:resetPrevious:), window, view, and timestamp properties. Attempts UIEvent creation via _initWithEvent:touches: and delivery via [UIApplication sendEvent:]. Falls back to direct dispatch for custom UIView subclasses.

4. **Recursive hit testing** — Replaced flat window-subviews iteration with full recursive _hitTestView that walks the entire view hierarchy, respecting userInteractionEnabled, hidden, and back-to-front z-ordering. Hit target locked on BEGAN, reused for MOVED/ENDED.

5. **Frame-limited force-display** — _force_display_recursive was running every frame (30fps), causing visible flashing as backing stores were constantly recreated. Fix: countdown system — force first 10 frames for initial population, 5 frames after touch events, periodic refresh every ~1s for timer-driven updates. All other frames use cached backing stores.

6. **hass-dashboard compile script** — `scripts/build_hassdash.sh` builds with modern Xcode (`-sdk iphonesimulator ARCHS=x86_64 IPHONEOS_DEPLOYMENT_TARGET=10.0 CODE_SIGNING_ALLOWED=NO`), ad-hoc signs output.

7. **View hierarchy diagnostic dump** — One-time dump of the full UIView tree on first frame capture tick, logging class name, pointer, hidden state, and alpha for every view.

**hass-dashboard results (updated):**
- Full view hierarchy loads: UINavigationController → UINavigationBar, HALoginViewController → UIScrollView → HAConnectionFormView → UITextFields, UISegmentedControl, UIButton, UILabels, UIActivityIndicatorView
- 45+ distinct colors rendered (constellation gradient background visible)
- Light gray theme renders instead of dark theme (UIAppearance proxies not yet activated)
- ~14fps with selective display forcing

### Phase 6c: Flashing Fix, Touch Infrastructure, Keyboard Input (2026-02-20, Session 3)
**Goal:** Eliminate display flashing, build proper touch event delivery infrastructure, add keyboard input.

**Display flashing — root cause and fix:**

The display flashed because `CGBitmapContextCreate` clears the pixel buffer to white (#ffffff) before `renderInContext:` draws content. With the bitmap context pointing directly at the shared mmap'd framebuffer, the host caught this transient white state ~13% of the time. Investigation via per-frame pixel sampling confirmed the pattern: binary alternation between rendered content (#f2f2f2) and blank white (#ffffff), correlated with the RENDERING flag state.

**Fix: Double-buffer rendering.** Render to a local `malloc`'d buffer, then `memcpy` the completed frame to the shared framebuffer in one shot. The host only ever sees complete frames. This eliminated all flashing.

Additional display fixes:
- **`updateNSView` frame counter guard** — Only set `displayImage` (triggering `needsDisplay`) when `frameCount` changes, not on every SwiftUI state update
- **`_force_display_recursive` improvements:**
  - Only call `setNeedsDisplay` on layers with nil `contents` (preserves existing backing stores)
  - Restricted `_` prefix catch-all to private views that actually override `drawRect:` (was creating empty opaque backing stores on container views like `_UIBarBackground`)
- **RENDERING flag** added to framebuffer header (bridge sets before writing, clears after) — not used as hard gate since bridge spends most time rendering, but available for future optimization

**App lifecycle completeness:**
- Added `viewDidAppear:` call in `makeKeyAndVisible` replacement
- Added `applicationDidBecomeActive:` delegate method call
- Post `UIApplicationDidFinishLaunchingNotification` and `UIApplicationDidBecomeActiveNotification`

**Touch event delivery — multi-layered approach:**

The touch pipeline went through several iterations to handle UIKit's complex event infrastructure:

1. **UITouchesEvent creation**: `[[UITouchesEvent alloc] _init]` creates a bridge-owned event with all internal CFMutableDictionaries properly initialized by `_UITouchesEventCommonInit`. The `[UIApplication _touchesEvent]` singleton is nil because `_eventDispatcher` was never initialized (our longjmp recovery skips that code path).

2. **Dictionary population via ivar manipulation**: `_addTouch:forDelayedDelivery:` crashes in `_addGestureRecognizersForView:toTouch:` because UIScrollView's gesture recognizers reference internal state that doesn't exist without backboardd. Instead, we directly populate `_touches` (NSMutableSet), `_keyedTouches[view]` (CFMutableDictionary), and `_keyedTouchesByWindow[window]` (CFMutableDictionary) using `class_getInstanceVariable` + `ivar_getOffset`. Dictionary keys are raw pointers (NULL key callbacks = pointer equality).

3. **SIGSEGV crash guard**: `sendEvent:` still crashes in `_sendTouchesForEvent:` due to missing `_gestureRecognizersByWindow` population. A `sigsetjmp`/`siglongjmp` handler catches SIGSEGV/SIGBUS and recovers to the direct delivery fallback. Process stays alive.

4. **Direct delivery fallback**: Walks the responder chain to find nearest UIControl ancestor. UIButton/UISegmentedControl: `setHighlighted:` + `beginTrackingWithTouch:` + `endTrackingWithTouch:` + `sendActionsForControlEvents:UIControlEventTouchUpInside`. UITextField: `becomeFirstResponder` crashes (UITextInteractionAssistant's gesture recognizer setup needs backboardd), so touch is delivered but text input uses the keyboard mechanism instead.

**Keyboard input:**
- Host: `SimulatorDisplayView.keyDown` captures `keyCode`, modifier flags, and character → writes to mmap input region (`key_code`, `key_flags`, `key_char` fields added to `RosettaSimInputRegion`)
- Bridge: `check_and_inject_keyboard()` reads key events, finds first responder via `[UIApplication _firstResponder]` or `[keyWindow firstResponder]`, delivers via `[responder insertText:]` for regular characters. Special keys: Backspace → `deleteBackward`, Return → `resignFirstResponder` (UITextField) or `insertText:"\n"` (UITextView), Tab → `insertText:"\t"`.

**Known issues for next session:**

| Priority | Problem | Root Cause | Potential Fix |
|---|---|---|---|
| 1 | `sendEvent:` crashes in `_sendTouchesForEvent:` | `_gestureRecognizersByWindow` not populated; UIGestureEnvironment not initialized | Initialize UIEventDispatcher + UIGestureEnvironment during manual UIApplicationMain recovery. Or swizzle `_sendTouchesForEvent:` to skip gesture recognizer phase. |
| 2 | UITextField.becomeFirstResponder crashes | UITextInteractionAssistant.setGestureRecognizers calls removeGestureRecognizer: on nil | Swizzle UITextInteractionAssistant to skip gesture setup, or initialize gesture environment |
| 3 | Dark theme not applied | UIAppearance proxies not activated despite viewDidAppear/applicationDidBecomeActive calls | May need view removal + re-addition to window to trigger appearance, or explicit UIAppearance application |
| 4 | ~15fps / 120% CPU | Per-frame renderInContext: is expensive for complex view hierarchies | IOSurface zero-copy rendering; reduce force-display frequency for unchanged views |
| 5 | 318 colors rendered but mostly white/light gray | Many views' backgroundColors render but custom content needs more force-display coverage | Investigate which views aren't getting their drawRect: called |

**Session 3 commits:**
```
3ed358a feat: proper UITouchesEvent infrastructure with crash-safe fallback
2c3c477 fix: skip sendEvent: (crashes), skip becomeFirstResponder (crashes)
b514fad fix: revert UITouchesEvent (crashes), add UIControl tracking fallback
4790787 fix: use UITouchesEvent for proper UIControl touch delivery
8b329d3 fix: eliminate display flashing with double-buffer rendering
b2eee66 fix: bridge rendering flag and host frame counter optimization
```

### Phase 7: App Management
**Goal:** Install and launch arbitrary simulator apps.

**Implementation:**
- Simulated device filesystem (sandbox, app containers)
- App installation (extract .app bundle, register with simulated SpringBoard)
- App lifecycle management (launch, suspend, terminate)
- Simulated SpringBoard (home screen) — or skip this and launch apps directly

**Deliverable:** Standalone RosettaSim.app that can run legacy iOS simulator apps.

### Phase 7: iOS 9 Runtime Support
**Goal:** Support iOS 9.x simulator apps in addition to 10.x.

**Implementation:**
- Obtain iOS 9.x simulator runtime (from Xcode 7.x or Apple's downloads)
- Test framework loading with iOS 9 SDK
- Handle any API differences between iOS 9 and 10 simulator frameworks
- Support iOS 9-era device types (iPhone 5s, 6, 6 Plus)

**Deliverable:** iOS 9 simulator support in RosettaSim.

### Phase 8: Xcode Integration (Stretch)
**Goal:** Use RosettaSim as a build destination in modern Xcode.

**Implementation:**
- Register as a simulator provider with CoreSimulator
- Support `simctl` commands
- Integrate with Xcode's build system for simulator targeting

**Deliverable:** Build and run legacy simulator apps from modern Xcode.

---

## Risk Assessment (Updated with experimental results)

| Risk | Severity | Status | Notes |
|---|---|---|---|
| `dyld_sim` incompatible with macOS 26 kernel | Critical | **RESOLVED** | Phase 1 confirmed it works. |
| Old libSystem bridge libraries fail | Critical | **RESOLVED** | Phase 1/2 confirmed they work. |
| Platform check blocks framework loading | High | **RESOLVED** | Binary must target iphonesimulator platform. |
| `DYLD_*` env vars stripped by SIP | Medium | **RESOLVED** | Don't use `arch` wrapper; launch binary directly. |
| CoreAnimation rendering cannot be intercepted | High | Low | Multiple interception strategies available. **Next to test (Phase 4).** |
| UIKit initialization fails (missing services) | High | **RESOLVED** | Fails only at backboardd connection. All prior init works. |
| Too many macOS API changes to shim | High | Medium | Phase 2 showed basic APIs work. Rendering APIs untested. |
| Rosetta 2 JIT restrictions block bridge injection | High | Low | `DYLD_INSERT_LIBRARIES` works under Rosetta 2. |
| Performance too poor for interactive use | Medium | Low | Most work is GPU rendering, which is native speed. |
| Code signing prevents framework loading | Medium | **RESOLVED** | Frameworks load without issues in simulator context. |

---

## Technology Stack

| Component | Language | Architecture | Notes |
|---|---|---|---|
| Host App | Swift | ARM64 | Native macOS app |
| Bridge Library | C/Obj-C | x86_64 | Injected into simulated process |
| Compatibility Shims | C | x86_64 | Injected alongside bridge |
| Build System | Make/CMake | — | Cross-compiles x86_64 components |
| Test Harness | C/Obj-C | x86_64 | Compiled against simulator SDK |

## References

- Xcode 8.3.3 iPhoneSimulator10.3.sdk framework analysis (this project)
- Facebook idb / FBSimulatorControl (reverse-engineered CoreSimulator usage)
- PrivateHeaderKit (simulator framework header extraction)
- WWDC sessions on simulator architecture (2016-2017)
- Apple `dyld` open source: https://github.com/apple-oss-distributions/dyld
