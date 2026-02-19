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

**Deliverable:** A macOS window showing content rendered by the simulated UIKit.

### Phase 5: Input and Interaction
**Goal:** Touch, keyboard, and device interaction.

**Implementation:**
- Mouse click → UITouch event injection via GraphicsServices
- Keyboard → UIKeyboard event injection
- Rotation → UIDevice orientation change notification
- Shake gesture, screenshot, etc.

**Deliverable:** Interactive simulated iOS app.

### Phase 6: App Management
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
