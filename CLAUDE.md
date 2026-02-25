# RosettaSim

## Mission

Build a working iOS 9.3 simulator for Apple Silicon Macs (macOS 26). The goal is to give developers access to a simulator for developing and testing legacy iOS apps, preventing e-waste of iPad 2s and other devices that can't run anything newer than iOS 9.3.

## Why This Matters

- iPad 2, iPad mini 1, iPod touch 5 are all stuck on iOS 9.3.5
- Apple dropped simulator support for iOS 9.x in modern Xcode/macOS
- Millions of these devices are still in use (schools, kiosks, accessibility)
- Without a simulator, developers can't maintain apps for these devices
- The alternative is physical hardware that's increasingly hard to source

## Technical Approach

We run the iOS 10.3 SDK's simulator frameworks (from Xcode 8.3.3) via Rosetta 2 on Apple Silicon. An ARM64-native broker process acts as a fake `launchd`, managing the bootstrap namespace and spawning the iOS simulator daemon processes (backboardd, assertiond, SpringBoard) and the target app.

### Architecture

```
┌─────────────────────────────────────────────────────┐
│  RosettaSim.app (ARM64 native macOS host)           │
│  - Reads shared framebuffer, sends touch/keyboard   │
└────────────────────┬────────────────────────────────┘
                     │ mmap'd framebuffer
┌────────────────────┴────────────────────────────────┐
│  rosettasim_broker (ARM64 native)                    │
│  - Bootstrap namespace (Mach IPC service registry)   │
│  - XPC pipe protocol (CheckIn/GetJobs/LookUp)        │
│  - PurpleFBServer (for iOS <10 runtimes)             │
│  - Process lifecycle management                       │
├──────────────────────────────────────────────────────┤
│  Spawned processes (all x86_64 via Rosetta 2):       │
│  ├── iokitsimd      (IOKit device services)          │
│  ├── backboardd     (display, HID, CARenderServer)   │
│  ├── assertiond     (process assertions)             │
│  ├── SpringBoard    (app lifecycle, FBSWorkspace)    │
│  └── Target App     (the iOS 9.3 app being tested)  │
│                                                       │
│  Injected libraries (via DYLD_INSERT_LIBRARIES):     │
│  ├── bootstrap_fix.dylib  (all processes)            │
│  │   └── Redirects bootstrap_look_up/check_in to     │
│  │       broker via MIG; patches intra-library calls  │
│  └── rosettasim_bridge.dylib (app process only)      │
│      └── UIKit lifecycle, frame capture, HID input    │
└──────────────────────────────────────────────────────┘
```

### Key Files

| File | Purpose |
|------|---------|
| `src/bridge/rosettasim_broker.c` | ARM64 broker: bootstrap namespace, XPC pipe, process spawning |
| `src/launcher/bootstrap_fix.c` | x86_64 DYLD shim: bootstrap interposition + runtime patching |
| `src/bridge/rosettasim_bridge.m` | x86_64 app bridge: UIKit lifecycle, frame capture, input |
| `src/bridge/purple_fb_server.c` | x86_64 PurpleFBServer: framebuffer surface sharing |
| `src/bridge/springboard_shim.c` | x86_64 SpringBoard XPC handling |
| `src/shared/rosettasim_framebuffer.h` | Shared framebuffer header format |
| `scripts/run_full.sh` | Master launcher script |
| `scripts/build_*.sh` | Component build scripts |

### SDK Location

```
/Applications/Xcode-8.3.3.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator10.3.sdk
```

### Test App

```
/Users/ashhopkins/Projects/hass-dashboard/build/rosettasim/Build/Products/Debug-iphonesimulator/HA Dashboard.app
```

## Development Principles

### Protocol Correctness Over Hacks

**This is the single most important principle.** The project's history proves:

- Every time a protocol constant, message format, or wire type was corrected, a cascade of problems resolved at once (e.g., fixing LAUNCH_DATA_STRING from 2 to 7 immediately fixed all assertiond crashes)
- Every time a timeout, swizzle, or longjmp guard was added to paper over a service gap, it created new problems and obscured the real issue

**DO:**
- Reverse-engineer what message a framework sends, to which port, in what format, and what reply it expects
- Implement the handler in the broker (or shim) that speaks the correct protocol
- Use Ghidra on the iOS 10.3 SDK frameworks to understand private APIs and MIG protocols

**DO NOT:**
- Add timeouts to `xpc_connection_send_message_with_reply_sync` to skip unresponsive services
- Use `siglongjmp` to catch crashes from missing services
- Swizzle framework methods to return dummy values unless you understand WHY the original fails
- Add patches to "just get past" a crash without understanding the root cause
- Stub out functions with hardcoded return values when the real function would work if its dependencies were properly implemented
- Comment out DYLD interpositions to "try something" without documenting why
- Add crash guards around code that crashes, instead of fixing why it crashes

### When to Stub vs When to Implement

- **Stub**: Only when the real service is genuinely unnecessary (e.g., cfprefsd write operations that don't need to persist)
- **Implement**: When the framework uses the service response to configure state (e.g., BKSDisplayServicesStart configures UIScreen — stubbing it means UIScreen is misconfigured)
- **Pass-through**: When the real function would work if its Mach port dependencies are routed correctly through the broker. Prefer letting the real function run over replacing it with a stub.

### Service Implementation Checklist

When the simulator crashes or hangs on a missing service:

1. **Identify** the service name and the framework calling it (from logs)
2. **Reverse-engineer** the protocol (Ghidra on the framework binary)
3. **Implement** the handler in the broker or appropriate shim
4. **Validate** by checking that:
   - The specific failure signature is gone from logs
   - No new crashes were introduced
   - The process that was crashing now survives 30+ seconds

### Build & Run

```bash
# Full pipeline (builds everything, spawns all processes, starts host app)
scripts/run_full.sh --timeout 120

# Individual builds
scripts/build_broker.sh       # ARM64 broker
scripts/build_bridge.sh       # x86_64 app bridge
scripts/build_purple_fb.sh    # x86_64 PurpleFBServer
scripts/build_springboard_shim.sh

# Kill everything safely
scripts/kill_sim.sh
```

### Process Safety

**NEVER use `pkill -f` with generic names** like `backboardd`, `SpringBoard`, etc. These match macOS system daemons and will crash the Mac. Always kill by exact PID. The `kill_sim.sh` script handles this correctly.

## Current State (as of 2026-02-23, commit 9569dd3)

### What Works
- All 5 processes spawn and stay alive: broker, backboardd, assertiond, SpringBoard, app
- **Acceptance gate PASSES**: framebuffer exists, frame_counter advancing, all processes alive
- **GPU Display Pipeline ACTIVE**: CARenderServer connected, RegisterClient succeeded, PurpleFBServer syncing to `/tmp/rosettasim_framebuffer_gpu` at 60Hz
- App fully starts: `didFinishLaunching` completes in ~173ms, `makeKeyAndVisible` with original UIKit IMP
- Bootstrap namespace: 23+ services registered, per-process mobilegestalt check_in (fresh ports)
- XPC pipe protocol: CheckIn, GetJobs, LookUp all working
- Broker drains Mach messages during acceptance gate (prevents bootstrap port death)
- `com.apple.system.logger` stub prevents SpringBoard workspace disconnect
- SBShim only injected into SpringBoard (not assertiond/backboardd)
- CPU debug mode available via `ROSETTASIM_CA_MODE=cpu` (frame_counter=3608/90s verified)
- Broker enters message loop and stays alive indefinitely

### Active Issues
1. **UIScreen.scale** — not yet verified in GPU mode. `GSSetMainScreenInfo` sets GS-level scale (750x1334 @2x), but UIScreen's internal `_scale` ivar path (via BKSDisplayServices) needs verification.
2. **Scroll crash (SIGSEGV)** — not yet tested in GPU mode. Previously: UIScrollView pan gesture triggers CA layout passes that access CARenderServer state.
3. ~~**Frame counter slow**~~ **RESOLVED (Session 19)**: CPU rendering at 77fps. Session 18's "25% non-zero GPU pixels" was a false positive (alpha channel of opaque black — PurpleFBServer init fill). CARenderServer doesn't composite onto PurpleDisplay (contextIdAtPosition=0). Fix: `ROSETTASIM_CA_MODE=cpu` forces LOCAL CA context + CPU renderInContext in the app process. 100% colored pixels with real app UI content.
4. ~~**CFRunLoop timers don't fire**~~ **RESOLVED (Session 18)**: CFRunLoop works correctly under Rosetta 2. `CFRunLoopRunInMode(default, 0.5, false)` returns `kCFRunLoopRunTimedOut` (3) — it blocks properly. CFRunLoopTimer callbacks fire at expected intervals. The previous assumption was wrong — `CFRunLoopRunInMode` with `returnAfterSourceHandled=true` and `timeout=0` returns immediately by design (kCFRunLoopRunHandledSource or kCFRunLoopRunFinished), not due to Rosetta. The `ROSETTASIM_RUNLOOP_PUMP` manual pump is no longer needed for the app process.
5. **Workspace listener not servicing** — recv port obtained but dispatch_mach channel monitors wrong port. Not needed for compat mode (app works without workspace). GPU compositing works WITHOUT workspace (connect_remote succeeds directly).

### Key Architectural Decisions (Session 17)
- **Acceptance gate serves messages**: replaced `usleep()` loop with `drain_pending_messages()` so the broker keeps processing bootstrap/XPC requests while waiting for the app framebuffer
- **Per-process check_in**: the broker creates fresh ports for repeat check_ins (e.g., mobilegestalt) instead of blocking with error 1103
- **SIGUSR1 timeout**: if UIApplicationMain blocks before calling `_run` (workspace handshake stalls), a 5s timer sends SIGUSR1 to the main thread which `siglongjmp`s to the recovery path
- **UIApplicationMain runtime patch disabled**: the code-patching trampoline conflicted with DYLD `__interpose`, causing infinite recursion. DYLD interposition alone is sufficient.

### Session History
- Sessions 1-6: UIKit works, basic display
- Sessions 7-9: Display services, CARenderServer
- Sessions 10-11: GPU rendering investigation
- Session 12: FBSWorkspace lifecycle
- Sessions 13-14: Bootstrap namespace, XPC pipe, all processes alive
- Session 15: XPC wire type fixes, broker-hosted PFB, app startup
- Session 16: Screen scale fix (GSSetMainScreenInfo takes pixels), app rendering working
- Session 17: GPU display pipeline active — acceptance gate passes. Fixed: broker message drain, per-process mobilegestalt, SBShim injection target, system.logger stub, UIApplicationMain timeout, makeKeyAndVisible IMP timing
- Session 18: **SpringBoard survives FBSystemAppMain** — all 30 init steps. SB alive via exit/abort interposition + _run swizzle. App fully functional (HA Dashboard, cameras, 60s+). **CFRunLoop WORKS under Rosetta 2** — debunked false timer assumption. GPU framebuffer investigation. Simplified CARenderServerGetServerPort. Corrected CA::Context C++ object layout (4 mutexes, not encoder IDs).
- Session 19: **MILESTONE — Real iOS app visible on screen at 77fps.** HA Dashboard showing temperatures, zone controls, camera feeds in macOS host window. Session 18's "GPU pixels" was false positive (alpha channel of opaque black). CARenderServer display binding doesn't work (contextIdAtPosition=0). Fix: ROSETTASIM_CA_MODE=cpu for LOCAL context + CPU renderInContext. Fixed run_full.sh framebuffer wait logic. Added CALayerHost renderInContext to PurpleFBServer (future GPU path).

## Mach IPC Reference

### Bootstrap Protocol (MIG subsystem 400)
| ID | Name | Purpose |
|----|------|---------|
| 402 | BOOTSTRAP_CHECK_IN | Daemon registers as listener for a service |
| 403 | BOOTSTRAP_REGISTER | Register a named service port |
| 404 | BOOTSTRAP_LOOK_UP | Look up a service by name |

### XPC Pipe Protocol
| Constant | Value | Purpose |
|----------|-------|---------|
| XPC_PIPE_MSG_ID | 0x10000000 | Request message |
| XPC_PIPE_REPLY_MSG_ID | 0x20000000 | Reply message (MUST be this exact value) |
| XPC_LISTENER_REG_ID | 0x77303074 | Listener registration |

### Wire Types (in XPC serialized dicts)
| Type | Value | Notes |
|------|-------|-------|
| DICTIONARY | 0xF000 | Container |
| STRING | 0x9000 | UTF-8 string |
| BOOL | 0x2000 | Boolean |
| INT64 | 0x3000 | 64-bit integer |
| MACH_SEND | 0xC000 | Mach send right |
| MACH_RECV | 0xB000 | Mach receive right |

### GraphicsServices Screen Info (confirmed via disassembly)

```c
// GSSetMainScreenInfo(double pixelWidth, double pixelHeight, float scale, float orientation)
// Internally: cvttsd2si → __screenWidth (int32), cvttsd2si → __screenHeight (int32)
//             movss → __screenScale (float), movss → __screenOrientation (float)
// 4th param is orientation (0.0 = portrait), NOT scaleY!

// GSMainScreenPointSize() returns: __screenWidth/__screenScale, __screenHeight/__screenScale
// GSMainScreenPixelSize() returns: __screenWidth, __screenHeight (raw ints → doubles)
// GSMainScreenScaleFactor() returns: __screenScale

// kGSMainScreenWidth/Height/Scale are SEPARATE symbols from __screenWidth/Height/Scale
// The kGS* symbols are exported data (for other frameworks to read)
// The __screen* symbols are internal data (set by GSSetMainScreenInfo)
// Both need to be set for full compatibility
```

### CARenderServer (MIG subsystem 40000)
| ID | Name |
|----|------|
| 40200 | Control channel base |
| 40202 | RegisterClient |
| 40002+ | Data channel |
| 40400+ | Callback channel |
