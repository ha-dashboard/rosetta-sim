# Session 8 Results — backboardd Running with CARenderServer

**Date**: 2026-02-20
**Duration**: ~2 hours
**Status**: Major breakthrough — backboardd running stable with real CARenderServer

## Executive Summary

Following Session 7's research recommendations, we successfully got the iOS 10.3 backboardd binary running on macOS 26 Apple Silicon via Rosetta 2. CARenderServer starts, creates a display, and actively renders at ~60fps to a shared framebuffer. This is the first time backboardd has run outside of the real CoreSimulator infrastructure.

## What Was Achieved

### 1. PurpleFBServer Shim (`src/bridge/purple_fb_server.c`)

Reverse-engineered the PurpleFBServer Mach protocol from QuartzCore disassembly:

- **msg_id=4 (map_surface)**: 72-byte complex reply with memory entry port + surface dimensions
- **msg_id=3 (flush_shmem)**: 72-byte reply acknowledging dirty region
- Created a complete C implementation that provides the PurpleFBServer service
- The framebuffer is shared with the host app via `/tmp/rosettasim_framebuffer`

### 2. Bootstrap Service Registration

backboardd needs to register ~14 Mach services. Without launchd:
- Interposed `bootstrap_check_in` to create local ports for each service
- Interposed `bootstrap_look_up` to find services in local registry
- Interposed `bootstrap_register` as fallback
- CARenderServer properly checked in and looked up

### 3. GraphicsServices Purple Port Bypass

`GSEventInitializeWorkspaceWithQueue` → `_GSEventInitializeApp` → `GSRegisterPurpleNamedPerPIDPort` would abort without launchd. Solution:
- **Key insight**: `_GSEventInitializeApp` is an intra-dylib call that CANNOT be DYLD-interposed
- Interposed `GSEventInitializeWorkspaceWithQueue` (the cross-dylib entry from backboardd) as a no-op
- Also interposed individual `GSGet*Port` / `GSRegister*Port` functions for any cross-dylib callers

### 4. XPC Server Registration Bypass

`BSBaseXPCServer.registerServerSuspended` throws when XPC listener creation fails without launchd:
- Swizzled the method to a no-op using ObjC runtime
- This prevents the XPC exception that was causing SIGBUS after abort suppression

### 5. Display Creation — Works!

The full PurpleDisplay chain works:
1. `_detectDisplays` calls `PurpleDisplay::openMain()`
2. `PurpleDisplay::open()` → `bootstrap_look_up("PurpleFBServer")` → our interposition
3. `PurpleDisplay::map_surface()` → msg_id=4 → we reply with memory entry
4. `vm_map` maps our framebuffer into the process ✓
5. `PurpleDisplay::new_server()` → creates PurpleServer with CFRunLoop thread
6. `CAWindowServerDisplay` created and added → **1 display detected**
7. `BKDisplayStartWindowServer()` passes without assertion ✓

### 6. CARenderServer Active

- CARenderServer checks in via local port registry
- Render server thread starts (`com.apple.CoreAnimation.render-server`)
- Continuous flush_shmem messages at ~60fps
- Process runs stable for 30+ seconds (killed for testing, not crashed)

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│  backboardd (x86_64 via Rosetta 2)                      │
│                                                         │
│  ┌─────────────┐   ┌──────────────────┐                │
│  │ PurpleDisplay│──►│ PurpleFBServer   │ (our shim)    │
│  │  ::open()   │   │ msg_id=4: surface │                │
│  │  ::flush()  │   │ msg_id=3: flush   │                │
│  └──────┬──────┘   └──────────────────┘                │
│         │                                               │
│  ┌──────▼──────┐   ┌──────────────────┐                │
│  │ CAWindowSrv │──►│ CARenderServer   │ (real!)        │
│  │ _detect...  │   │ render thread    │                │
│  │ 1 display   │   │ 60fps rendering  │                │
│  └─────────────┘   └────────┬─────────┘                │
│                              │ flush_shmem              │
│  ┌──────────────────────────▼────────────────────────┐ │
│  │ Shared Memory (memory entry)                      │ │
│  │ 750x1334 BGRA, 4MB, vm_map'd                     │ │
│  └──────────────────────┬────────────────────────────┘ │
│                          │ sync @ 60Hz                  │
│  ┌──────────────────────▼────────────────────────────┐ │
│  │ /tmp/rosettasim_framebuffer (shared file)          │ │
│  │ Header + Input + Pixels                            │ │
│  └────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────┘
           │ host app reads framebuffer
           ▼
┌─────────────────────┐
│ RosettaSimApp (ARM64)│
│ SwiftUI display      │
└─────────────────────┘
```

## Files Created/Modified

### New Files
- `src/bridge/purple_fb_server.c` — PurpleFBServer shim library (~950 lines)
- `scripts/build_purple_fb.sh` — Build script for the shim
- `scripts/run_backboardd.sh` — Launcher script for backboardd
- `docs/SESSION_8_RESULTS.md` — This document

### Key Interpositions in purple_fb_server.c

| Function | Purpose |
|----------|---------|
| `bootstrap_look_up` | Intercept PurpleFBServer + local registry |
| `bootstrap_check_in` | Create local ports for services |
| `bootstrap_register` | Store in local registry |
| `vm_map` | Trace framebuffer mapping |
| `abort` | Suppress during init |
| `objc_exception_throw` | Suppress during init |
| `GSEventInitializeWorkspaceWithQueue` | Skip Purple port registration |
| `GSGet*Port` / `GSRegister*Port` | Provide dummy Purple ports |
| ObjC: `NSAssertionHandler` | Suppress assertions |
| ObjC: `BSBaseXPCServer.registerServerSuspended` | Skip XPC |
| ObjC: `CAWindowServer._detectDisplays` | Trace display creation |

## Remaining Issues

### 1. No Shared Bootstrap Namespace (Critical for App Connection)

backboardd's CARenderServer port is in a **local registry** (within the same process). App processes can't look it up because:
- `bootstrap_register` is blocked on modern macOS (error 141)
- Mach port names are per-task (can't share via file)
- Need either launchd_sim or a custom bootstrap sub-namespace

**Possible solutions**:
- Use `bootstrap_create_server()` / `bootstrap_subset()` to create a shared namespace
- Use `task_set_special_port()` to share a bootstrap port between processes
- Run both backboardd and the app in the same process (fork + exec with shared ports)
- Write a minimal launchd_sim replacement that provides the namespace

### 2. SimulatorHIDFallback Not Connected

The HID fallback system fails because `IndigoHIDRegistrationPort` is not available:
```
Unable to initialize Simulator HID System Manager (SimulatorHIDFallbackSystem):
Error Domain=NSPOSIXErrorDomain Code=3 "No such process"
```
This means touch/keyboard input from the host won't reach backboardd natively. May need to provide IndigoHIDRegistrationPort or use a different input injection path.

### 3. Display Shows Black (Expected)

The framebuffer is black because no apps are rendering to the display. Once an app connects to CARenderServer, the display will show the app's UI rendered by the real GPU pipeline.

### 4. BSBaseXPCServer Skipped

The XPC service registration is skipped, meaning backboardd's services (com.apple.backboard.checkin, etc.) are not available to client processes. This needs to be solved alongside the bootstrap namespace issue.

## Protocol Reference

### PurpleFBServer msg_id=4 (map_surface) Reply Format

```
Offset  Size  Field
0       24    mach_msg_header_t
24      4     mach_msg_body_t { descriptor_count = 1 }
28      12    mach_msg_port_descriptor_t { memory_entry_port }
40      4     memory_size (uint32, page-aligned)
44      4     stride (bytes_per_row)
48      8     padding/unknown
56      4     pixel_width
60      4     pixel_height
64      4     point_width
68      4     point_height
Total: 72 bytes
```

### PurpleFBServer msg_id=3 (flush_shmem)

Request contains dirty bounds at offset 0x28 (16 bytes: x, y, width, height).
Reply: 72-byte non-complex message (acknowledgment).

## Next Steps (Priority Order)

1. **Shared Bootstrap Namespace** — Create a way for app processes to find CARenderServer
2. **App Connection Test** — Launch a simple UIKit app that renders through CARenderServer
3. **Input Pipeline** — Provide IndigoHIDRegistrationPort or alternative input injection
4. **Host App Integration** — Update RosettaSimApp to display CARenderServer output
5. **Replace Bridge** — Once apps render through CARenderServer, the 4000-line bridge shrinks to ~200 lines
