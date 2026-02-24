# Session 10 Handoff — Complete System Audit & Next Steps

**Date:** 2026-02-21
**Commit:** `87d389d` (feat: broker pipeline with full hass-dashboard login screen rendering)

---

## 1. What Was Achieved This Session

### Broker + Bridge Integration
Connected the broker pipeline (Sessions 8-9) with the bridge library (Sessions 1-6) to get the **hass-dashboard login screen rendering at 30fps through the broker-managed pipeline**.

**Key technical discoveries:**
1. **DYLD interposition cannot intercept intra-library calls.** `CARenderServerGetServerPort()` is called WITHIN QuartzCore — our interposition of it never fires. The fix: interpose `bootstrap_look_up` instead (which IS a cross-library call from QuartzCore to libSystem).
2. **iOS SDK's `bootstrap_look_up` uses `mach_msg2`/XPC internally on macOS 26.** The broker uses standard `mach_msg` and cannot receive `mach_msg2` format messages. Fix: custom broker protocol (msg_id 701) with raw `mach_msg` from the bridge.
3. **CARenderServer connection breaks CPU rendering.** When CA connects to the real server, `renderInContext:` returns empty layers (backing stores moved to server memory). Only animated layers (spinners, CAKeyframeAnimation) render through the server. Static content (text, backgrounds, controls) requires proper CADisplay association which we don't have.
4. **PurpleFBServer and bridge framebuffer conflict.** Both write to `/tmp/rosettasim_framebuffer`. Fix: separate paths — PurpleFBServer uses default, bridge uses `ROSETTASIM_FB_PATH=/tmp/rosettasim_app_framebuffer`.

### Proven Working
- Full login screen: constellation animation, "Connect to your server" card, discovered HA server, URL field, segmented control
- Touch events delivered through native `[UIApplication sendEvent:]` with IOHIDEvent + gesture recognizers
- mDNS discovery finds Home Assistant on network
- 30fps CPU rendering via `renderInContext:`
- Host app (RosettaSim.app) reads app framebuffer and runs as native ARM64

---

## 2. Complete Architecture

```
                     macOS 26 ARM64 Host
    ┌─────────────────────────────────────────────┐
    │  RosettaSim.app (ARM64 native SwiftUI)      │
    │  ├─ Reads /tmp/rosettasim_app_framebuffer   │
    │  ├─ Displays simulated iPhone screen        │
    │  └─ Writes touch/keyboard to input region   │
    └───────────────┬─────────────────────────────┘
                    │ mmap (shared memory)
    ┌───────────────┴─────────────────────────────┐
    │  /tmp/rosettasim_app_framebuffer            │
    │  ├─ Header (64 bytes): magic, dimensions    │
    │  ├─ Input region (552 bytes): touch ring,   │
    │  │   keyboard events                        │
    │  └─ Pixels (750x1334x4 = ~4MB BGRA)        │
    └───────────────┬─────────────────────────────┘
                    │ mmap (shared memory)
    ┌───────────────┴─────────────────────────────┐
    │  HA Dashboard.app (x86_64 via Rosetta 2)    │
    │  ├─ DYLD_INSERT_LIBRARIES=bridge.dylib      │
    │  ├─ DYLD_ROOT_PATH=iOS 10.3 SDK             │
    │  ├─ Bridge: UIKit lifecycle, CPU rendering,  │
    │  │   touch/keyboard injection                │
    │  └─ TASK_BOOTSTRAP_PORT → broker             │
    └───────────────┬─────────────────────────────┘
                    │ Mach IPC (broker protocol)
    ┌───────────────┴─────────────────────────────┐
    │  rosettasim_broker (x86_64 macOS native)    │
    │  ├─ Mach port registry (64 service slots)   │
    │  ├─ Spawns backboardd + app via posix_spawn  │
    │  ├─ Sets TASK_BOOTSTRAP_PORT on children    │
    │  └─ Custom protocol: msg_id 700-702         │
    └───────────────┬─────────────────────────────┘
                    │ Mach IPC (broker protocol)
    ┌───────────────┴─────────────────────────────┐
    │  backboardd (x86_64 iOS SDK via Rosetta 2)  │
    │  ├─ DYLD_INSERT_LIBRARIES=purple_fb.dylib   │
    │  ├─ CARenderServer running at ~60fps        │
    │  ├─ PurpleFBServer: framebuffer surface      │
    │  └─ IOHIDEventSystem (partially initialized) │
    └─────────────────────────────────────────────┘
```

---

## 3. Complete Service Map

### Services the Real Simulator Provides

| Service | Provider | Our Status | How We Handle It |
|---------|----------|------------|------------------|
| `com.apple.CARenderServer` | backboardd | **RUNNING** but app not connected to display | Broker registers port; bridge can look it up but CPU rendering used instead because CADisplay association missing |
| `PurpleFBServer` | SpringBoard/host | **SHIMMED** | `purple_fb_server.c` provides framebuffer surface for backboardd's `PurpleDisplay::open()` |
| `com.apple.iohideventsystem` | backboardd | **REGISTERED** but non-functional | Port created and registered with broker, but no events flow through it |
| `com.apple.backboard.display.services` | backboardd | **BYPASSED** | Bridge stubs `BKSDisplayServicesStart` to call `GSSetMainScreenInfo` directly |
| `com.apple.backboard.hid.services` | backboardd | **BYPASSED** | Bridge stubs `BKSHIDEventRegisterEventCallbackOnRunLoop` to no-op |
| `com.apple.backboard.watchdog` | backboardd | **STUBBED** | Returns `MACH_PORT_NULL` / `isAlive=true` |
| `com.apple.springboard.backgroundappservices` | SpringBoard | **MISSING** | `bootstrap_look_up` fails. No SpringBoard running. |
| FBSWorkspace / FBSScene lifecycle | SpringBoard | **BYPASSED** | All FBSWorkspace/FBSSceneImpl methods swizzled to no-op/nil |
| `IndigoHIDRegistrationPort` | CoreSimulatorService | **MISSING** | Lookup fails. SimulatorHIDFallback can't connect (Error Code=3 "No such process") |
| XPC services (BSBaseXPCServer) | backboardd/SpringBoard | **BYPASSED** | `registerServer`/`registerServerSuspended` swizzled to no-op |
| Purple ports (GSEventSystem) | backboardd | **STUBBED** | All GSGet/GSRegister functions return dummy ports or no-op |
| CoreText font services (fontd) | fontd daemon | **BYPASSED** | `__CTFontManagerDisableAutoActivation=1`, fonts registered manually from SDK paths |
| Keychain services | securityd | **WORKING** | Host macOS keychain accessible via Rosetta 2 |
| Network services (mDNS, HTTP) | System | **WORKING** | Host macOS networking works transparently |
| File system | System | **WORKING** | `DYLD_ROOT_PATH` + `HOME`/`CFFIXED_USER_HOME` redirect correctly |

### What the Custom HID System Manager Would Replace

The `SIMULATOR_HID_SYSTEM_MANAGER` bundle loaded by `IndigoHIDSystemSpawnLoopback` in backboardd's `SimulatorClient.framework` is responsible for:

1. **CADisplay creation** — Creates display objects that CARenderServer renders to. This is the missing link that would make CARenderServer render the full UI (not just animations).
2. **Touch event delivery** — Receives touch events from the host and delivers them through `IOHIDEventSystem` into UIKit's native pipeline. Would replace the bridge's entire touch injection system.
3. **Keyboard event delivery** — Same path for keyboard events.
4. **Display configuration** — Screen dimensions, scale factor, device profile.

If this bundle works, it would eliminate the need for:
- The bridge's `replacement_BKSDisplayServicesStart` (PARTIAL)
- The bridge's `replacement_BKSHIDEventRegisterEventCallbackOnRunLoop` (BYPASS)
- The bridge's entire `check_and_inject_touch` system (HACK)
- The bridge's entire `check_and_inject_keyboard` system (HACK)
- The bridge's `frame_capture_tick` CPU rendering (the framebuffer would come from CARenderServer)
- All SIGSEGV crash guards around touch delivery
- All `@try/@catch` guards around UITouch property manipulation
- The `_force_display_recursive` hack
- The IOHIDEvent creation via dlsym

---

## 4. Complete Interposition & Bypass Audit

### Bridge (rosettasim_bridge.m) — 4547 lines

#### DYLD Interpositions (19 entries)

| # | Function | Classification | What It Does |
|---|----------|---------------|--------------|
| 1 | `BKSDisplayServicesStart` | PARTIAL | Calls GSSetMainScreenInfo with hardcoded dimensions, returns true. Skips backboardd connection and CADisplay assertion. |
| 2 | `BKSDisplayServicesServerPort` | STUB | Returns MACH_PORT_NULL |
| 3 | `BKSDisplayServicesGetMainScreenInfo` | CORRECT | Returns configurable screen dimensions |
| 4 | `BKSWatchdogGetIsAlive` | STUB | Always returns true |
| 5 | `BKSWatchdogServerPort` | STUB | Returns MACH_PORT_NULL |
| 6 | `CARenderServerGetServerPort` | CORRECT | Broker lookup with CPU fallback (but intra-library call means it's never actually called) |
| 7 | `GSGetPurpleSystemEventPort` | STUB | Returns dummy port |
| 8 | `GSGetPurpleWorkspacePort` | STUB | Returns dummy port |
| 9 | `GSGetPurpleSystemAppPort` | STUB | Returns dummy port |
| 10 | `GSRegisterPurpleNamedPerPIDPort` | BYPASS | No-op, prevents abort on registration failure |
| 11 | `GSRegisterPurpleNamedPort` | BYPASS | No-op |
| 12 | `_GSEventInitializeApp` | PARTIAL | Wraps original in abort guard, falls back to GSEventInitialize(false) |
| 13 | `BKSHIDEventRegisterEventCallbackOnRunLoop` | BYPASS | No-op. Touch delivered via mmap polling instead. |
| 14 | `UIApplicationMain` | PARTIAL | Calls real impl, abort recovery does manual UIKit init |
| 15 | `bootstrap_register2` | HACK | Fakes KERN_SUCCESS on failure to prevent abort |
| 16 | `abort` | HACK | longjmp recovery (undefined behavior) |
| 17 | `exit` | HACK | Blocks exits: parks background threads in select() forever, main thread longjmps |
| 18 | `_exit` | HACK | Same as exit (signature mismatch) |
| 19 | `bootstrap_look_up` | CORRECT | Routes CARenderServer/IOHIDEventSystem through broker, passes through everything else |

#### ObjC Swizzles (14 entries)

| # | Class.method | Classification | What It Does |
|---|-------------|---------------|--------------|
| 1 | `UIWindow.makeKeyAndVisible` | CORRECT | Calls original + tracks window in bridge stack |
| 2 | `UIApplication.workspaceShouldExit:` | BYPASS | No-op |
| 3 | `UIApplication.workspaceShouldExit:withTransitionContext:` | BYPASS | No-op |
| 4 | `UIApplication._runWithMainScene:transitionContext:completion:` | PARTIAL | Replicates UIKit init: EventDispatcher, delegate, lifecycle notifications, CFRunLoopRun. Misses scene lifecycle. |
| 5 | `UIApplication._run` | HACK | Points to same replacement as #4 with signature mismatch |
| 6 | `FBSWorkspaceClient.initWithServiceName:endpoint:` | BYPASS | Returns nil |
| 7 | `FBSWorkspaceClient.initWithDelegate:` | BYPASS | Returns nil |
| 8 | `FBSWorkspace.init` | BYPASS | Returns nil |
| 9 | `FBSSceneImpl.*` (bulk) | BYPASS | All client/workspace/invalidate methods → no-op |
| 10 | `UIKeyboardImpl.sharedInstance` | BYPASS | Returns nil. Prevents keyboard hang but breaks cursor/keyboard UI. |
| 11 | `UIInputWindowController.sharedInputWindowController` | BYPASS | Returns nil |
| 12 | `BKSEventFocusManager.*` (bulk) | BYPASS | All defer/register/fence/client methods → no-op |
| 13 | `BKSAnimationFenceHandle.*` (bulk) | BYPASS | ALL methods → no-op |
| 14 | `BKSTextInputSessionManager.*` (bulk) | BYPASS | ALL methods → no-op |

#### Signal Handlers & Crash Guards

| Type | Count | Classification |
|------|-------|---------------|
| SIGSEGV/SIGBUS handler | 1 handler, 4 installation sites | HACK — siglongjmp from signal handler into ObjC code |
| setjmp/longjmp abort guards | 2 | HACK — longjmp out of abort() is undefined behavior |
| sigsetjmp/siglongjmp guards | 7 | HACK (6 runtime), CORRECT (3 pre-warm) |
| @try/@catch guards | 50+ sites | CORRECT — defensive ObjC exception handling |

#### Known Bugs

1. **SA_SIGINFO flag overwritten** at 2 of 4 signal handler installation sites (lines 1800-1803, 3590-3593). Handler gets garbage `siginfo_t*` and `ucontext_t*` parameters.
2. **Dead code**: `_render_guard_active`, `_render_recovery` declared but never used. `replacement_isKeyWindow`/`replacement_keyWindow` defined but never installed.
3. **Signature mismatch**: `_run` swizzle points to `_runWithMainScene` replacement (different parameter count).

### PurpleFBServer (purple_fb_server.c) — 1136 lines

#### DYLD Interpositions (15 entries)

| # | Function | Classification |
|---|----------|---------------|
| 1 | `bootstrap_look_up` | CORRECT — intercepts PurpleFBServer, passes through others |
| 2 | `bootstrap_register` | PARTIAL — tries real, falls back to local registry |
| 3 | `bootstrap_check_in` | PARTIAL — creates synthetic ports on failure |
| 4 | `vm_map` | CORRECT — passthrough with logging |
| 5 | `abort` | HACK — permanently suppressed (`g_suppress_exceptions` never reset to 0) |
| 6 | `objc_exception_throw` | HACK — permanently suppressed |
| 7 | `GSEventInitializeWorkspaceWithQueue` | BYPASS — skips Purple port registration |
| 8-15 | `GSGet*/GSRegister*/GSCopy*` (8 entries) | CORRECT — return dummy ports |

#### ObjC Swizzles (5 entries)

| # | Class.method | Classification |
|---|-------------|---------------|
| 1 | `NSAssertionHandler.handleFailureInFunction:...` | HACK — suppresses ALL assertions |
| 2 | `NSAssertionHandler.handleFailureInMethod:...` | HACK — suppresses ALL assertions |
| 3 | `CAWindowServer._detectDisplays` | HACK — wraps original, logs count, does nothing if 0 |
| 4 | `BSBaseXPCServer.registerServerSuspended` | BYPASS — no-op |
| 5 | `BSBaseXPCServer.registerServer` | BYPASS — no-op |

#### Known Bug
`g_suppress_exceptions` initialized to 1 and **never reset to 0**. All aborts and exceptions suppressed permanently after init.

### Broker (rosettasim_broker.c) — 741 lines

No interpositions or swizzles. Pure C Mach IPC server.

| Component | Classification |
|-----------|---------------|
| Service registry (64 slots) | CORRECT |
| MIG bootstrap protocol (msg 400-405) | CORRECT |
| Custom broker protocol (msg 700-702) | CORRECT (700, 701), STUB (702 not implemented) |
| posix_spawn with TASK_BOOTSTRAP_PORT | CORRECT |
| Environment setup | CORRECT — matches run_sim.sh |
| .app bundle resolution | CORRECT — Info.plist parsing |
| Signal handling | CORRECT — SIGCHLD, SIGTERM, SIGINT |

---

## 5. What Actually Works End-to-End

| Feature | Status | Evidence |
|---------|--------|---------|
| App launch + UIApplicationMain | **WORKS** | didFinishLaunchingWithOptions called, delegate initialized |
| View hierarchy creation | **WORKS** | viewDidLoad, setupUI, viewWillAppear all fire |
| UINavigationController | **WORKS** | Root VC pushed, nav bar visible |
| CPU rendering (renderInContext) | **WORKS** | 30fps, full UI visible in framebuffer screenshots |
| Font rendering (CoreText) | **WORKS** | Text labels, buttons, MaterialDesignIcons all render |
| Network (mDNS discovery) | **WORKS** | Found HA server on network via Bonjour |
| Network (HTTP/HTTPS) | **WORKS** (inferred) | App resolves server URLs |
| Keychain | **WORKS** | Auth credentials read successfully |
| NSUserDefaults | **WORKS** | Preferences read correctly |
| Touch delivery (sendEvent) | **WORKS** | Events delivered, gesture recognizers process them |
| IOHIDEvent creation | **WORKS** | Real IOHIDEventCreateDigitizerFingerEvent used |
| Basic text input (insertText) | **WORKS** | Characters inserted via UIFieldEditor |
| UIActivityIndicatorView | **WORKS** | Spinner animates (via CARenderServer when connected) |
| UISegmentedControl rendering | **WORKS** | Segments visible with correct styling |
| UIButton rendering | **WORKS** | Buttons visible |
| UITextField rendering | **WORKS** | Text fields visible with placeholder text |
| Background animations | **WORKS** | Constellation animation progresses between frames |

| Feature | Status | Issue |
|---------|--------|-------|
| Segment control tap | **BROKEN** | Touch delivered but visual state doesn't update. `_force_full_refresh` destroys tint cache. |
| Scroll/pan gestures | **BROKEN** | MOVED events + autorelease pool corruption → crash in scroll deceleration |
| Keyboard UI | **MISSING** | UIKeyboardImpl returns nil. No on-screen keyboard. |
| Special keys (backspace, arrows) | **PARTIAL** | Key codes mapped but delivery unreliable |
| Cmd+shortcuts | **PARTIAL** | Mapped but untested through broker pipeline |
| Multi-touch | **MISSING** | Single touch only |
| CABasicAnimation | **MISSING** | No display cycle without CADisplay |
| UIVisualEffectView (blur) | **MISSING** | Requires CARenderServer + display association |
| tintColor persistence | **BROKEN** | `_force_full_refresh` destroys cached tint state |
| UIAlertController | **UNTESTED** | Window stack tracking exists but untested |
| Rotation / orientation | **MISSING** | No accelerometer/gyroscope simulation |
| Status bar | **MISSING** | No SpringBoard status bar |
| App backgrounding/foregrounding | **MISSING** | No FBSWorkspace scene lifecycle |

---

## 6. Services That Need Real Implementation

### Priority 1: Custom HID System Manager Bundle

**What:** An Objective-C bundle loaded by backboardd's `SimulatorClient.framework` via `SIMULATOR_HID_SYSTEM_MANAGER` env var.

**Protocol to implement** (`SimulatorClientHIDSystemManager`):
```objc
@protocol SimulatorClientHIDSystemManager
- (instancetype)initUsingHIDService:(id)service error:(NSError **)error;
- (NSArray *)displays;           // Array of CADisplay objects
- (BOOL)hasTouchScreen;
- (BOOL)hasTouchScreenLofi;
- (BOOL)hasWheel;
- (NSString *)name;
- (NSString *)uniqueId;
- (id)interfaceCapabilities;
@end
```

**What it replaces:** Entries 1, 2, 7-11, 13 in the bridge interpose table. All touch/keyboard injection code. All crash guards around sendEvent. The entire `_force_display_recursive` system. CPU rendering (maybe — depends on CADisplay working).

**Approach** (same methodology as PurpleFBServer):
1. Ghidra-analyze `SimulatorClient.framework` and `SimulatorHIDFallback` to understand the full protocol
2. Analyze what `IndigoHIDSystemSpawnLoopback` does with the returned manager
3. Analyze how `CADisplay` objects are created (what constructor, what parameters)
4. Build a minimal bundle that creates a single CADisplay from PurpleFBServer's surface
5. Read touch/keyboard events from the shared framebuffer input region
6. Deliver them through `IOHIDEventSystem` (the native path)
7. Set `SIMULATOR_HID_SYSTEM_MANAGER=/path/to/our/bundle.bundle` in backboardd's environment

**Key unknowns:**
- What does `CADisplay._initWithDisplay:` take as parameter? (Ghidra target)
- How does the manager connect its displays to CARenderServer? (Ghidra target)
- Does IOHIDEventSystem in backboardd need special configuration? (Test empirically)

### Priority 2: Fix CARenderServer Display Association

Even without the full HID manager, if we can create a `CADisplay` object and associate it with UIScreen, CARenderServer would render the full UI. This would:
- Eliminate CPU rendering overhead
- Enable real animations (CABasicAnimation, CAKeyframeAnimation)
- Enable UIVisualEffectView (blur, vibrancy)
- Enable proper tintColor rendering
- Enable CADisplayLink vsync

**Approach:**
1. Ghidra-analyze `CADisplay._initWithDisplay:` and `CAWindowServerDisplay`
2. Try creating a CADisplay from the CARenderServer port + PurpleFBServer surface
3. Associate it with `[UIScreen mainScreen]`

### Priority 3: Fix FBSWorkspace/Scene Lifecycle

Currently ALL FBSWorkspace/FBSScene methods are no-op'd. This means:
- No app state transitions (background/foreground)
- No scene lifecycle callbacks
- No state restoration
- No URL handling

A minimal FBSWorkspace implementation could provide scene lifecycle without SpringBoard.

---

## 7. How We Approach Each Problem (Methodology)

This is the methodology that produced results across Sessions 7-10:

### Step 1: Understand the Real Architecture
- Use Ghidra to disassemble the relevant framework
- Map the call chain from the entry point to the service
- Identify the Mach IPC protocol (message IDs, struct layouts)
- Document environment variables and configuration

### Step 2: Identify the Minimal Shim
- What's the minimum we need to implement for the feature to work?
- What can we stub vs what must be real?
- What messages does the protocol use?

### Step 3: Build the Shim
- Compile against the iOS simulator SDK (x86_64)
- Use DYLD interposition for function replacement
- Use ObjC swizzling for method replacement
- Test each piece individually before combining

### Step 4: Integrate via Broker
- Register service ports with the broker
- Set TASK_BOOTSTRAP_PORT for child processes
- Use custom broker protocol (msg_id 700-702) for port sharing
- Test cross-process communication

### Step 5: Verify Empirically
- Screenshots via `fb_screenshot.py`
- Log analysis via stderr (use `write(STDERR_FILENO, ...)` not printf)
- Process monitoring via `ps`
- Port verification via `lsmp`

### Key Lessons Learned
1. **DYLD interposition only catches cross-library calls.** For intra-library functions, interpose the function they CALL instead.
2. **iOS SDK's bootstrap functions use mach_msg2 on macOS 26.** Use raw mach_msg with custom protocol instead.
3. **posix_spawnattr_setspecialport_np is the only way to set TASK_BOOTSTRAP_PORT before exec.** fork+exec across Rosetta boundary loses Mach port names.
4. **Never use printf in iOS simulator binaries.** stdout is fully buffered. Use `write(STDERR_FILENO, ...)`.
5. **#pragma pack(4) required for mach_msg_port_descriptor_t** — without it, struct alignment is wrong and port names are garbage.
6. **NDR_record (8 bytes) required in all MIG-style messages** between header and inline data.
7. **g_suppress_exceptions must be reset to 0 after init** — leaving it permanently suppresses real errors.

---

## 8. Build & Run Commands

```bash
# Build everything
cd ~/Projects/rosetta
bash scripts/build_purple_fb.sh   # purple_fb_server.dylib
bash scripts/build_broker.sh      # rosettasim_broker
bash scripts/build_bridge.sh      # rosettasim_bridge.dylib

# Run full pipeline (broker + backboardd + app + host app)
bash scripts/run_full.sh --timeout 120

# Run standalone (no broker, CPU rendering only)
bash scripts/run_sim.sh ~/Projects/hass-dashboard/build/rosettasim/Build/Products/Debug-iphonesimulator/HA\ Dashboard.app

# Take screenshot
ROSETTASIM_FB_PATH=/tmp/rosettasim_app_framebuffer python3 tests/fb_screenshot.py /tmp/screenshot.png

# Check framebuffer state
python3 -c "import struct; d=open('/tmp/rosettasim_app_framebuffer','rb').read(64); m,v,w,h=struct.unpack('<IIII',d[:16]); fc=struct.unpack('<Q',d[24:32])[0]; print(f'{w}x{h} frames={fc}')"
```

---

## 9. File Inventory

| File | Size | Role |
|------|------|------|
| `src/bridge/rosettasim_bridge.m` | ~4547 lines | App-side: UIKit lifecycle, CPU rendering, touch/keyboard |
| `src/bridge/purple_fb_server.c` | ~1136 lines | backboardd-side: PurpleFBServer, CARenderServer, bootstrap |
| `src/bridge/rosettasim_broker.c` | ~741 lines | Mach port broker, process spawner |
| `src/bridge/app_shim.c` | ~250 lines | Standalone app shim (reference, superseded by bridge) |
| `src/shared/rosettasim_framebuffer.h` | ~100 lines | Shared framebuffer format (v3, ring buffer) |
| `src/host/RosettaSimApp/RosettaSimApp.swift` | ~700 lines | Host app: display, touch/keyboard input |
| `scripts/run_full.sh` | ~80 lines | Unified launcher |
| `scripts/run_sim.sh` | ~200 lines | Standalone launcher |
| `scripts/build_bridge.sh` | ~50 lines | Bridge build script |
| `scripts/build_purple_fb.sh` | ~50 lines | PurpleFBServer build script |
| `scripts/build_broker.sh` | ~30 lines | Broker build script |
| `tests/fb_screenshot.py` | ~100 lines | Framebuffer screenshot tool |
