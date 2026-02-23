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
scripts/run_full.sh

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

## Current State (as of 2026-02-23)

### What Works
- All 5 processes spawn and stay alive (broker, backboardd, SpringBoard, app; assertiond dies after ~30s)
- Bootstrap namespace: services register and look up correctly via broker
- XPC pipe protocol: CheckIn, GetJobs, LookUp all working
- XPC listener registration: dispatch_mach_connect flow working
- App reaches UIApplicationMain and starts initialization
- Frame capture pipeline exists (CPU rendering path)
- Broker-hosted PurpleFBServer for iOS 9.x runtimes

### Active Blockers
1. **BKSDisplayServicesStart assertion** — app crashes: "backboardd isn't running, isAlive: 0". The `BKSWatchdogGetIsAlive()` check fails because the watchdog Mach message isn't handled.
2. **assertiond "Connection invalid"** — BSXPCConnectionListener fails because of port right management issues in the broker (double-move of receive rights for pre-created services).
3. **CARenderServer rendering** — commits not flowing to shared framebuffer. Downstream of blockers 1 and 2.

### Session History
- Sessions 1-6: UIKit works, basic display
- Sessions 7-9: Display services, CARenderServer
- Sessions 10-11: GPU rendering investigation
- Session 12: FBSWorkspace lifecycle
- Sessions 13-14: Bootstrap namespace, XPC pipe, all processes alive
- Session 15+: XPC wire type fixes, broker-hosted PFB, app startup

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

### CARenderServer (MIG subsystem 40000)
| ID | Name |
|----|------|
| 40200 | Control channel base |
| 40202 | RegisterClient |
| 40002+ | Data channel |
| 40400+ | Callback channel |
