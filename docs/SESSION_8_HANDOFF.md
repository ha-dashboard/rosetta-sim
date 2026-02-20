# Session 8 Handoff — Complete Technical Guide for Next Agent

**Date**: 2026-02-20
**Status**: backboardd running stable with CARenderServer. Blocked on bootstrap namespace sharing.
**Priority for next agent**: Solve cross-process Mach port sharing so app processes can connect to backboardd's CARenderServer.

---

## What Was Achieved

iOS 10.3's `backboardd` binary now runs on macOS 26 Apple Silicon (via Rosetta 2) with a real CARenderServer providing GPU-accelerated rendering. This was accomplished by creating `src/bridge/purple_fb_server.c`, a DYLD_INSERT_LIBRARIES shim that:

1. **Provides PurpleFBServer** — the Mach service that QuartzCore's `PurpleDisplay::open()` uses to create displays
2. **Handles bootstrap services** — local port registry for `com.apple.CARenderServer` and other services
3. **Bypasses GraphicsServices init** — `GSEventInitializeWorkspaceWithQueue` replaced with no-op
4. **Bypasses XPC registration** — `BSBaseXPCServer.registerServerSuspended` swizzled to no-op
5. **Suppresses init-phase crashes** — `abort()` and `objc_exception_throw` interposed

### Proven State

- **1 display detected** by `_detectDisplays` (confirmed via swizzle trace)
- **CARenderServer thread running** (`com.apple.CoreAnimation.render-server`)
- **~60fps rendering** (continuous `flush_shmem` messages from PurpleDisplay)
- **Process stable 30+ seconds** (only killed for testing, never crashed)
- **Framebuffer shared** via `/tmp/rosettasim_framebuffer` (RosettaSim v3 format)

---

## The Blocking Problem: Cross-Process Mach Port Sharing

backboardd's CARenderServer is running but its Mach port is only accessible within backboardd's process (stored in a local in-memory registry at `purple_fb_server.c:697`). App processes that need to connect to CARenderServer cannot find it because:

### Why bootstrap_register Fails (Error 141)

When `purple_fb_server.c` tries to register services via `bootstrap_register()`, it fails with error 141. This is NOT a standard Mach error code. Investigation revealed:

- `bootstrap_register()` WORKS for native x86_64 macOS processes (tested with a standalone binary compiled against macOS SDK, returned KERN_SUCCESS=0)
- `bootstrap_register()` FAILS when called from within the iOS simulator environment (x86_64 binary with `DYLD_ROOT_PATH` set to the iOS 10.3 SDK)
- The likely cause: the iOS SDK's `libxpc.dylib` (resolved via DYLD_ROOT_PATH) has a different implementation that the macOS bootstrap server rejects, OR the bootstrap server treats simulator processes differently

### Why bootstrap_subset Fails (Error 17)

`bootstrap_subset(bootstrap_port, mach_task_self(), &subset_port)` returns `KERN_INVALID_RIGHT` (17). This API is restricted on modern macOS (SIP/sandbox policy). Even without SIP, the bootstrap subset API may be deprecated for non-launchd processes.

### What This Means

Mach port names are per-task. Port 11523 (CARenderServer) in backboardd's task is meaningless in another task. To share a Mach port between processes, you MUST use one of:
- Bootstrap namespace (register/look_up) — blocked as described above
- Mach IPC message with port descriptor — requires existing connection
- `task_for_pid` + `mach_port_extract_right` — requires root/entitlement
- Shared bootstrap port via fork — child inherits parent's port namespace

---

## Options to Explore (Priority Order)

### Option A: Fix bootstrap_register for Simulator Environment

**Theory**: The iOS SDK's `bootstrap_register` uses a different code path than the macOS native one. If we bypass the SDK's implementation and call the HOST macOS `bootstrap_register` directly, it should succeed (proven by the native test).

**How to try**:
```c
// In purple_fb_server.c constructor, BEFORE DYLD_ROOT_PATH takes effect:
// dlopen the HOST libxpc directly with an absolute path
void *host_xpc = dlopen("/usr/lib/system/libxpc.dylib", RTLD_NOW | RTLD_FIRST);
// BUT: DYLD_ROOT_PATH redirects /usr/lib to the SDK
// Need to find a path that isn't redirected

// Alternative: use the macOS SDK path that Rosetta preserves
// On Apple Silicon, Rosetta keeps host libraries at their real paths
// The actual macOS libxpc might be at a different location under Rosetta
```

**Key question**: Does `DYLD_ROOT_PATH` affect `dlopen` absolute paths? If so, can we use `DYLD_FALLBACK_LIBRARY_PATH` or `@rpath` to escape the redirect?

**Quick test**: Check if the real macOS bootstrap_register symbol can be obtained via `dlsym(RTLD_DEFAULT, "bootstrap_register")` and if it differs from the one linked via the SDK.

### Option B: Relay Port via Unix Domain Socket

**Theory**: Use a Unix domain socket as a rendezvous point. backboardd creates a socket at `/tmp/rosettasim.sock`. When an app process connects, backboardd sends the CARenderServer Mach port via `SCM_RIGHTS`... except `SCM_RIGHTS` transfers file descriptors, NOT Mach ports.

**How to adapt**: Use `fileport_makeport()` / `fileport_makefd()` if the port type is compatible. OR use a different mechanism:

1. backboardd creates a "relay" Mach port and registers it via bootstrap (this MIGHT work if we use the native bootstrap_register approach from Option A)
2. App sends a request to the relay port
3. backboardd replies with the CARenderServer port as an OOL port descriptor
4. App now has a send right to CARenderServer

### Option C: Same-Process Approach (App Inside backboardd)

**Theory**: Instead of separate processes, load the app's code into backboardd's process space. Since CARenderServer is local, the app's UIKit would automatically find it.

**How to try**:
```c
// After backboardd finishes initializing:
// 1. dlopen the app binary
void *app = dlopen("/path/to/app/binary", RTLD_NOW);
// 2. Find UIApplicationMain
typedef int (*UIAppMainFn)(int, char**, void*, void*);
UIAppMainFn appMain = dlsym(app, "UIApplicationMain");
// 3. Run in a new thread (backboardd owns the main run loop)
pthread_create(&app_thread, NULL, ^{ appMain(0, NULL, nil, nil); }, NULL);
```

**Risks**:
- backboardd and the app have different process roles (daemon vs app)
- UIKit expects to be the main run loop owner
- Potential ObjC class conflicts between backboardd's frameworks and the app's
- CARenderServer might expect clients on different tasks (for context isolation)

### Option D: Fork-Based Approach

**Theory**: `fork()` creates a child that inherits the parent's Mach port namespace. If we fork AFTER backboardd registers CARenderServer in the local registry, and we also set the child's bootstrap port to our local registry port, the child can look up services.

**How to try**:
```c
// After backboardd init completes:
pid_t child = fork();
if (child == 0) {
    // Child: we inherited all of parent's Mach ports
    // CARenderServer port (11523) is valid in our namespace too
    // BUT: fork() in ObjC/dispatch is extremely dangerous
    // All dispatch queues, threads, locks are in invalid state
    // Solution: exec() immediately into the app binary
    execve("/path/to/app", argv, envp);
}
```

**Key issue**: After `fork()`, `exec()` replaces the address space but preserves the Mach port namespace. If we `exec()` the app binary with the right DYLD_INSERT_LIBRARIES (our bridge that knows the CARenderServer port number), the app can use it.

**BUT**: `exec()` under DYLD_ROOT_PATH is complex. The child needs the same DYLD_ROOT_PATH, DYLD_INSERT_LIBRARIES, etc. And SIP may strip DYLD_* from exec'd processes.

### Option E: Minimal launchd_sim Replacement

**Theory**: Write a tiny process that acts as a bootstrap namespace provider. It creates a Mach port set, registers as the bootstrap server for a private namespace, and lets both backboardd and app processes register/look_up services.

**How to try**:
```c
// mini_launchd.c:
// 1. Create a port set for the namespace
// 2. Register as bootstrap server via bootstrap_subset + task_set_special_port
// 3. Start backboardd as a child (inherits our bootstrap)
// 4. Start app as another child (also inherits our bootstrap)
// 5. Handle bootstrap_register/look_up messages on the port set
```

**This is the cleanest solution** but requires implementing a mini Mach bootstrap server. The protocol is documented in Apple's open-source `launchd` code.

### Option F: Native Helper Process

**Theory**: Write a small NATIVE (ARM64 macOS) helper that:
1. Creates a bootstrap subset (which WORKS for native processes)
2. Sets it as the bootstrap port for its children
3. Launches backboardd as a child via `posix_spawn` with the subset bootstrap
4. Launches the app as another child with the same bootstrap
5. Both children can register and look up services in the subset

**Why this might work**: `bootstrap_subset` might only be restricted for Rosetta/simulator processes but work for native ARM64 processes. The native helper creates the namespace, then spawns x86_64 children that inherit it.

**Quick test**: Run this native code:
```c
// Compile as ARM64:
// clang -arch arm64 test_subset.c -o test_subset
mach_port_t subset;
kern_return_t kr = bootstrap_subset(bootstrap_port, mach_task_self(), &subset);
printf("bootstrap_subset: %d\n", kr);  // Does this return 0?
```

---

## Technical Details for Implementation

### Current File Layout

```
src/bridge/purple_fb_server.c    — The shim library (1005 lines)
src/bridge/purple_fb_server.dylib — Compiled x86_64 dylib
scripts/build_purple_fb.sh       — Build script
scripts/run_backboardd.sh        — Launch script
```

### How to Build and Test

```bash
# Build the shim
./scripts/build_purple_fb.sh --force

# Run backboardd (foreground, ctrl-C to stop)
./scripts/run_backboardd.sh

# Or background
./scripts/run_backboardd.sh --background
# Check: tail -f /tmp/backboardd.log
```

### Successful Init Sequence (from logs)

```
1. [constructor] bootstrap_subset → FAILS (error 17, expected on macOS 26)
2. [constructor] Surface created: 750x1334, mem_entry port allocated
3. [constructor] Shared framebuffer at /tmp/rosettasim_framebuffer
4. [constructor] PurpleFBServer port created (recv + send rights)
5. [constructor] Server thread + sync thread started
6. [constructor] NSAssertionHandler swizzled (function + method)
7. [constructor] _detectDisplays swizzled for tracing
8. [constructor] BSBaseXPCServer.registerServerSuspended swizzled → no-op
9. [backboardd main] _detectDisplays called → calls PurpleDisplay::openMain()
10.   bootstrap_look_up('PurpleFBServer') → intercepted, returns our port
11.   msg_id=4 received → replied with surface (750x1334, mem_entry)
12.   vm_map of memory entry → OK, addr mapped
13.   bootstrap_look_up('PurpleFBTVOutServer') → FAILED (expected, no TV out)
14.   _detectDisplays: original added 1 displays ← SUCCESS
15. bootstrap_check_in('com.apple.CARenderServer') → local port created
16. bootstrap_look_up('com.apple.CARenderServer') → found in local registry
17. [CARenderServer starts, begins rendering]
18. flush_shmem messages begin (msg_id=3, ~60fps) ← RENDERING ACTIVE
19. BSBaseXPCServer.registerServerSuspended → SKIPPED
20. GSEventInitializeWorkspaceWithQueue → intercepted, Purple registration skipped
21. bootstrap_check_in('com.apple.iohideventsystem') → local port created
22. IndigoHIDRegistrationPort lookup → FAILED (no host connection)
23. SimulatorHIDFallback init → FAILED (no HID registration port)
24. [backboardd continues running indefinitely, rendering at 60fps]
```

### What CARenderServer Provides

When running, these Mach services are in the local registry:
- `com.apple.CARenderServer` (port created by bootstrap_check_in)
- `com.apple.iohideventsystem` (port created by bootstrap_check_in)

The CARenderServer render thread (`CA::Render::Server::server_thread`) is actively running and listening for client connections on the CARenderServer port. It processes render commits and flushes to the PurpleDisplay surface.

### The Rendering Pipeline (Once Apps Connect)

```
App Process                          backboardd Process
─────────────                        ─────────────────
UIKit layout + draw
  → CATransaction.commit()
  → CA::Render::Context
  → Mach msg to CARenderServer   →  CA::Render::Server receives
                                     → GPU compositing
                                     → PurpleDisplay::flush_shmem
                                     → Our msg_id=3 handler
                                     → pfb_sync_to_shared()
                                     → /tmp/rosettasim_framebuffer updated
                                                    ↓
Host App (ARM64)
  → reads /tmp/rosettasim_framebuffer
  → displays in SwiftUI window
```

### Key Mach Port Numbers (Example from Last Run)

These change every run but the pattern is:
- `g_server_port` = PurpleFBServer receive/send port (e.g., 6147)
- `g_memory_entry` = memory entry for framebuffer surface (e.g., 6403)
- CARenderServer port = created by bootstrap_check_in (e.g., 11523)
- IOHIDEventSystem port = created by bootstrap_check_in (e.g., 18179)

### Important DYLD Interposition Gotcha

**DYLD interposition only works for CROSS-DYLIB calls.** If function A calls function B, and both are in the same dylib, the interposition is BYPASSED.

This was discovered when trying to interpose `GSRegisterPurpleNamedPerPIDPort` (in GraphicsServices). The caller `_GSEventInitializeApp` is also in GraphicsServices, so the interposition doesn't work. The solution was to interpose the CROSS-DYLIB entry point: `GSEventInitializeWorkspaceWithQueue` which backboardd imports from GraphicsServices.

### Bootstrap Error Codes

- **Error 141**: Not a standard Mach/bootstrap error. Returned by iOS SDK's libxpc when `bootstrap_register`/`bootstrap_check_in` is called outside launchd context. Does NOT occur for native macOS processes.
- **Error 17** (`KERN_INVALID_RIGHT`): Returned by `bootstrap_subset` — restricted on modern macOS.
- **Error 0x10000003** (`MACH_SEND_INVALID_DEST`): Returned when sending to a port that has been deallocated.

### PurpleFBServer Protocol (Fully Reverse-Engineered)

**Message format**: All messages are 72 bytes (0x48).

**msg_id=4 (map_surface)**:
- Request: `mach_msg_header_t` (24B) + body (48B), `msgh_id=4`
- Reply: Complex message with `mach_msg_port_descriptor_t` (12B with `#pragma pack(4)`) containing memory entry port
- Reply inline data at offsets: 40=memory_size, 44=stride, 56=pixel_width, 60=pixel_height, 64=point_width, 68=point_height
- Verified: `sizeof(mach_msg_port_descriptor_t)==12` on iOS 10.3 SDK, `sizeof(PurpleFBReply)==72`

**msg_id=3 (flush_shmem)**:
- Request: `mach_msg_header_t` + dirty bounds at byte offset 0x28 (16 bytes: 4 ints)
- Reply: 72-byte simple (non-complex) message

**send_msg behavior**: After receiving the reply into a local buffer, `send_msg` copies the first 72 bytes back into the CALLER's message buffer via `rep movsl` (18 dwords). This is why `map_surface` reads reply data from its own stack frame.

### QuartzCore Display Architecture (from Disassembly)

```
CAWindowServer._detectDisplays
  → open_funcs[0] = PurpleDisplay::openMain()
  → open_funcs[1] = PurpleDisplay::openTVOut()

PurpleDisplay::open(bool isTVOut)
  → task_get_special_port(self, 4, &bootstrap)  // get bootstrap port
  → bootstrap_look_up(bootstrap, "PurpleFBServer"/"PurpleFBTVOutServer", &port)
  → allocate 0x1E8 bytes for PurpleDisplay
  → PurpleDisplay constructor → map_surface() → PurpleFBServer msg_id=4

_detectDisplays (after open):
  → vtable[0x200] → new_server() → PurpleServer (with CFRunLoop thread)
  → Server::attach_contexts()
  → [[CAWindowServerDisplay alloc] _initWithCADisplayServer:server]
  → [self addDisplay:display]
```

### What Remains Not Working

1. **HID input**: SimulatorHIDFallback can't connect (`IndigoHIDRegistrationPort` not found). Touch/keyboard from host won't reach backboardd natively. May need to provide this port or use alternative input injection.

2. **XPC services**: `BSBaseXPCServer.registerServerSuspended` is skipped, meaning backboardd's XPC services (com.apple.backboard.checkin, etc.) are unavailable. This prevents proper client checkin.

3. **Framebuffer content**: Currently shows black (opaque, BGRA 0x000000FF) because no app is rendering to the display.

---

## Quick Validation Commands

```bash
# Build everything
./scripts/build_purple_fb.sh --force

# Run backboardd in background
./scripts/run_backboardd.sh --background

# Check it's running
ps aux | grep backboardd

# Check log
tail -20 /tmp/backboardd.log

# Check framebuffer exists
ls -la /tmp/rosettasim_framebuffer

# Count rendering frames in log
grep -c flush_shmem /tmp/backboardd.log

# Kill it
kill $(cat /tmp/backboardd.pid 2>/dev/null || pgrep -f "backboardd.*PurpleFBServer")
```

---

## Observations Stored

The Happy MCP observation system has this session recorded at ID `701c3231-adc9-45b8-84ba-dda7708e1a00`. Query with:
```
observation_search(query="backboardd CARenderServer PurpleFBServer", project="rosetta")
```
