# Session 9 Handoff — Cross-Process Mach Port Sharing via Broker

**Date**: 2026-02-20
**Status**: Cross-process Mach port sharing SOLVED. App processes can obtain CARenderServer send rights from backboardd via the broker. Next step: connect an actual iOS app's CoreAnimation to CARenderServer and verify pixels render.

---

## What Was Achieved

The blocking problem from Session 8 — "how do app processes connect to backboardd's CARenderServer?" — is now solved. We built a **native x86_64 macOS Mach port broker** that acts as a mini bootstrap server, enabling service port sharing between processes that can't use the real macOS bootstrap.

### End-to-End Pipeline (Proven Working)

```
rosettasim_broker (x86_64 macOS)
  │
  ├─ Creates Mach receive port (broker_port)
  ├─ posix_spawn(backboardd, TASK_BOOTSTRAP_PORT=broker_port)
  │    │
  │    └─ backboardd + purple_fb_server.dylib
  │         ├─ CARenderServer starts, creates port 11523
  │         ├─ Sends BROKER_REGISTER_PORT(700) to broker
  │         │    → broker stores "com.apple.CARenderServer" → port
  │         ├─ Also registers "com.apple.iohideventsystem"
  │         └─ Renders at ~60fps (flush_shmem continuously)
  │
  ├─ Waits for CARenderServer registration
  ├─ posix_spawn(app, TASK_BOOTSTRAP_PORT=broker_port)
  │    │
  │    └─ app + app_shim.dylib
  │         ├─ Gets broker_port from TASK_BOOTSTRAP_PORT
  │         ├─ Sends BROKER_LOOKUP_PORT(701) for CARenderServer
  │         ├─ Receives valid SEND right to CARenderServer
  │         └─ Interposes bootstrap_look_up for transparent access
  │
  └─ Message loop: handles bootstrap MIG + custom broker messages
```

**Test output confirming success:**
```
[broker] registered service com.apple.CARenderServer in slot 0
[broker] registered service com.apple.iohideventsystem in slot 1
[AppShim] broker lookup 'com.apple.CARenderServer': found port=3331
[AppShim] Pre-fetched 'com.apple.CARenderServer' → port 3331
[AppShim] Pre-fetched 'com.apple.iohideventsystem' → port 3843
[APP_TEST] CARenderServer port type: 0x10000 SEND
[APP_TEST] RESULT: SUCCESS — CARenderServer port is valid SEND right!
```

---

## Files Created/Modified in This Session

### New Files

| File | Lines | Architecture | Purpose |
|------|-------|-------------|---------|
| `src/bridge/rosettasim_broker.c` | ~740 | x86_64 macOS SDK | Mini bootstrap server + port relay broker |
| `src/bridge/app_shim.c` | ~250 | x86_64 iOS 10.3 SDK | App-side DYLD_INSERT shim for port lookup |
| `scripts/build_broker.sh` | ~30 | bash | Build script for broker |
| `scripts/build_app_shim.sh` | ~40 | bash | Build script for app shim |
| `scripts/run_rosettasim.sh` | ~80 | bash | Unified launcher (builds + runs everything) |
| `tests/test_spawn_port.c` | ~400 | x86_64 both | posix_spawn + mini bootstrap server PoC |
| `tests/test_app_lookup.c` | ~130 | x86_64 iOS SDK | App-side CARenderServer lookup test |
| `tests/test_cross_bootstrap.c` | ~160 | both | Cross-arch bootstrap test |
| `tests/test_raw_bootstrap.c` | ~300 | both | Raw MIG bootstrap protocol test |
| `tests/test_bootstrap_init.c` | ~40 | both | Bootstrap port initialization timing |
| `tests/test_x86_fork_port.c` | ~200 | x86_64 both | x86_64 fork+exec port survival |
| `tests/test_intercept_bootstrap.c` | ~100 | arm64 | mach_msg interception for protocol discovery |
| `tests/test_e2e_lookup.sh` | ~60 | bash | End-to-end lookup test script |

### Modified Files

| File | Change |
|------|--------|
| `src/bridge/purple_fb_server.c` | Added broker notification: `pfb_notify_broker()` sends CARenderServer port to broker via BROKER_REGISTER_PORT (msg_id 700). Constructor reads broker port from TASK_BOOTSTRAP_PORT. |

---

## Critical Technical Findings

### 1. iOS SDK bootstrap_port is ALWAYS Zero

The iOS 10.3 SDK's `libSystem` does not initialize the `bootstrap_port` global variable. It's always `0x0` in simulator binaries. However, the kernel-level `TASK_BOOTSTRAP_PORT` (readable via `task_get_special_port`) IS valid — it's inherited from the parent process.

```c
// In any x86_64 iOS simulator binary:
bootstrap_port == 0x0           // ALWAYS zero
task_get_special_port(self, TASK_BOOTSTRAP_PORT, &bp) → bp = 0xe03  // valid!
```

**Fix**: In both `purple_fb_server.c` and `app_shim.c`, the constructor reads the kernel bootstrap port and sets `bootstrap_port = kernel_bp`.

### 2. macOS 26 Bootstrap Functions Use mach_msg2, Not mach_msg

The macOS SDK's `bootstrap_register()`, `bootstrap_look_up()`, etc. do NOT use `mach_msg()` internally. They use `mach_msg2()` or XPC pipes. This means:
- DYLD interposition of `mach_msg` cannot intercept bootstrap calls
- Constructing raw MIG bootstrap messages via `mach_msg` gets `MIG_BAD_ARGUMENTS` (-304) from launchd
- The SDK's `bootstrap_register` works (for native macOS processes) but through a different code path

**Implication**: We cannot replicate the SDK's bootstrap protocol manually. The broker approach was the only viable path.

### 3. ARM64 → x86_64 fork+exec LOSES Mach Port Names

When a native ARM64 process forks and execs an x86_64 binary (which runs under Rosetta), **all Mach port names become invalid** in the child. The Rosetta translation boundary resets the port namespace.

```
ARM64 parent: broker_port = 0xa03 (valid)
  fork+exec x86_64 child: broker_port = 0xa03 → MACH_SEND_INVALID_DEST
```

**Fix**: The broker is compiled as **x86_64 macOS** (not ARM64). Both broker and backboardd/apps are x86_64, so there's no architecture transition during exec.

### 4. posix_spawnattr_setspecialport_np Is the Key API

This macOS-specific API sets special ports on a child process BEFORE exec:
```c
posix_spawnattr_setspecialport_np(&attr, broker_port, TASK_BOOTSTRAP_PORT);
posix_spawn(&pid, binary, NULL, &attr, argv, envp);
```

The child gets `broker_port` as its `TASK_BOOTSTRAP_PORT`. This is the only reliable way to establish a Mach connection between the broker and simulator processes.

### 5. iOS SDK Sends bootstrap_parent (msg_id 404) During Init

When a simulator binary starts with a custom TASK_BOOTSTRAP_PORT, the iOS SDK's `libSystem` initialization sends a `bootstrap_parent` message (ID 404, 188 bytes) to the bootstrap port. This message contains a reference to `com.apple.oahd` (the Rosetta translation daemon). The broker must handle this gracefully (we return an error reply and continue).

### 6. NDR Records Are Required in All MIG-style Messages

Every message sent to the broker must include an `NDR_record_t` (8 bytes) between the header and inline data. Without it, the broker reads data from the wrong offset. This caused the initial "truncated service name" bug (`e.CARenderServer` instead of `com.apple.CARenderServer`).

```c
// CORRECT message layout for BROKER_REGISTER_PORT:
header(24) + body(4) + port_desc(12) + NDR(8) + name_len(4) + name(128) = 180 bytes

// CORRECT message layout for BROKER_LOOKUP_PORT:
header(24) + NDR(8) + name_len(4) + name(128) = 164 bytes
```

### 7. Mach Message Receive Buffers Need Extra Space for Trailers

The kernel appends trailer data to received messages. A 72-byte send becomes ~100+ bytes on receive. Always use a receive buffer significantly larger than the expected message (2048 bytes minimum).

---

## Broker Protocol Reference

### Bootstrap MIG Messages (subsystem 400)

The broker handles standard MIG bootstrap messages from the iOS SDK:

| ID | Name | Direction | Format |
|----|------|-----------|--------|
| 400 | bootstrap_check_in | Client → Broker | Simple: header(24) + NDR(8) + name_len(4) + name(128) |
| 401 | bootstrap_register | Client → Broker | Complex: header(24) + body(4) + port_desc(12) + NDR(8) + name_len(4) + name(128) |
| 402 | bootstrap_look_up | Client → Broker | Simple: header(24) + NDR(8) + name_len(4) + name(128) |
| 404 | bootstrap_parent | Client → Broker | Complex: 188 bytes (iOS SDK init, contains oahd port) |
| 405 | bootstrap_subset | Client → Broker | Handled: returns KERN_INVALID_RIGHT (17) |

**Reply format (success with port):**
```
header(24): COMPLEX | MOVE_SEND_ONCE, id = request_id + 100
body(4): descriptor_count = 1
port_desc(12): name=port, disposition=COPY_SEND (look_up) or MAKE_SEND (check_in)
Total: 40 bytes
```

**Reply format (error):**
```
header(24): MOVE_SEND_ONCE, id = request_id + 100
NDR(8): { 0, 0, 0, 0, 1, 0, 0, 0 }
ret_code(4): error code (e.g., 1102 = BOOTSTRAP_UNKNOWN_SERVICE)
Total: 36 bytes
```

### Custom Broker Messages

| ID | Name | Direction | Format |
|----|------|-----------|--------|
| 700 | BROKER_REGISTER_PORT | backboardd → Broker | Complex: header(24) + body(4) + port_desc(12) + NDR(8) + name_len(4) + name(128) = 180 bytes |
| 701 | BROKER_LOOKUP_PORT | App → Broker | Simple: header(24) + NDR(8) + name_len(4) + name(128) = 164 bytes |
| 702 | BROKER_SPAWN_APP | Reserved | Not yet implemented in message handler |

---

## Build & Run Commands

```bash
# Build everything
./scripts/build_purple_fb.sh --force   # purple_fb_server.dylib (x86_64 iOS SDK)
./scripts/build_broker.sh              # rosettasim_broker (x86_64 macOS SDK)
./scripts/build_app_shim.sh --force    # app_shim.dylib (x86_64 iOS SDK)

# Run everything (builds first if needed)
./scripts/run_rosettasim.sh

# Run in background
./scripts/run_rosettasim.sh --background
# Log: /tmp/rosettasim.log
# Stop: kill $(cat /tmp/rosettasim_broker.pid)

# Run broker with a specific app
src/bridge/rosettasim_broker --app /path/to/ios/app/binary

# Verify framebuffer
ls -la /tmp/rosettasim_framebuffer

# Check rendering
grep -c flush_shmem /tmp/rosettasim.log
```

---

## Service Registry State (After Init)

After backboardd fully initializes via the broker, these services are registered:

| Slot | Service Name | Source |
|------|-------------|--------|
| 0 | `com.apple.CARenderServer` | purple_fb_server.c `pfb_bootstrap_check_in` |
| 1 | `com.apple.iohideventsystem` | purple_fb_server.c `pfb_bootstrap_check_in` |

The broker maintains a flat array of 64 service slots. Each has a `name[128]`, `port`, and `active` flag.

---

## What Remains — Ordered by Priority

### Priority 1: Connect an iOS App's CoreAnimation to CARenderServer

**Status**: The app has a valid SEND right to CARenderServer. The next step is to run a real iOS app (not just our test binary) with `app_shim.dylib` injected and verify that `CA::Render::Context` connects to CARenderServer and submits render commands.

**What to try**:
1. Build a minimal iOS app that creates a `UIWindow` + `UIView` with a colored background
2. Launch it via the broker: `src/bridge/rosettasim_broker --app path/to/app`
3. Check if `CA::Render::Context` connects (watch broker log for look_up of CARenderServer)
4. Check if pixels appear in `/tmp/rosettasim_framebuffer`

**Potential issues**:
- The app's CoreAnimation uses `bootstrap_look_up("com.apple.CARenderServer")` internally. Our `app_shim.c` interposes this and returns the cached port. But CA might also use MIG or direct Mach messages that we don't intercept.
- The app may need additional services beyond CARenderServer (e.g., `com.apple.backboard.display.services` for client registration).
- UIKit's initialization is complex — it needs an app delegate, main nib, Info.plist, etc. A minimal test might just use CoreAnimation directly without UIKit.

**Minimal CoreAnimation test approach**:
```objc
// No UIKit, just CoreAnimation + render to CARenderServer
#import <QuartzCore/QuartzCore.h>

int main() {
    // app_shim.dylib is already loaded, CARenderServer port is cached
    // CoreAnimation should find it via bootstrap_look_up

    CALayer *layer = [CALayer layer];
    layer.bounds = CGRectMake(0, 0, 375, 667);
    layer.backgroundColor = [UIColor redColor].CGColor;

    // How to commit to CARenderServer? Need CA::Render::Context
    // This is the unknown part — how does CA::Render::Context init?
    // Might need to trace backboardd's own initialization to understand
}
```

### Priority 2: Handle Additional Bootstrap Services

Apps may need services beyond CARenderServer. The broker currently handles:
- `bootstrap_check_in` → creates a new port in broker's task
- `bootstrap_look_up` → returns stored port
- `bootstrap_register` → stores port from client

But these services go through the broker as MIG messages. If the iOS SDK doesn't send proper MIG messages (since its bootstrap functions are XPC-based), the calls might fail. In that case, the `app_shim.c` would need to intercept more functions and handle them locally (similar to what `purple_fb_server.c` does with its local registry).

### Priority 3: Framebuffer Display in Host App

The host app (`src/host/RosettaSimApp/RosettaSimApp.swift`) currently reads PNG frames with manual refresh. It needs to be updated to:
1. Memory-map `/tmp/rosettasim_framebuffer`
2. Read the `RosettaSimFramebufferHeader` (magic, version, width, height, stride, frame_counter)
3. Poll `frame_counter` at 60Hz
4. Render BGRA pixels to a `CGImage` → `NSImage` → SwiftUI `Image`
5. Display in the device chrome view

The shared framebuffer header is defined in `src/shared/rosettasim_framebuffer.h`.

### Priority 4: Touch Input Forwarding

The host app needs to capture mouse events and write them to the touch ring buffer in the shared framebuffer. The input region starts at offset 64 (after the 64-byte header) and contains:
- `touch_write_index` (8 bytes) — host increments after each event
- `touch_ring[16]` (512 bytes) — 16 slots of `RosettaSimTouchEvent` (32 bytes each)
- Keyboard fields (remaining bytes)

The bridge side (`purple_fb_server.c` or a separate thread) reads the ring buffer and injects IOHIDEvents into backboardd.

### Priority 5: HID Input System

Currently `IndigoHIDRegistrationPort` lookup fails, and `SimulatorHIDFallback` can't initialize. Options:
- Provide a fake `IndigoHIDRegistrationPort` in the broker
- Bypass HID registration entirely and inject events via `IOHIDEventSystemClientDispatchEvent`
- Use the shared framebuffer's touch ring buffer as the input source

---

## Architecture Decisions Made & Why

### Why x86_64 Broker (Not ARM64)?

ARM64 → x86_64 `fork+exec` loses Mach port names due to the Rosetta translation boundary. By making the broker x86_64 (compiled against macOS SDK, not iOS SDK), it runs under Rosetta alongside backboardd and apps. All processes share the same architecture context, so `posix_spawn` with `TASK_BOOTSTRAP_PORT` works correctly.

### Why posix_spawn (Not fork+exec)?

`posix_spawnattr_setspecialport_np` is the only clean way to set `TASK_BOOTSTRAP_PORT` on a child before exec. With `fork+exec`, you'd need to call `task_set_special_port` in the child between fork and exec, but this is unsafe in the presence of ObjC/dispatch (fork creates a broken threading state).

### Why a Broker (Not Direct Registration)?

The iOS SDK's `bootstrap_register` returns error 141 from simulator processes. The macOS SDK's `bootstrap_register` uses `mach_msg2`/XPC internally, which we can't replicate via `mach_msg`. A broker sidesteps both issues: the broker manages its own port registry using plain `mach_msg`, and processes communicate with it through `TASK_BOOTSTRAP_PORT`.

### Why Custom Messages 700/701 (Not Standard Bootstrap)?

The standard MIG bootstrap messages (400-405) are sent by the iOS SDK's `libSystem` during initialization — we can't control their format or timing. Our custom messages (700 REGISTER_PORT, 701 LOOKUP_PORT) use a format we fully control, making debugging simpler. The broker handles both standard and custom messages.

---

## Gotchas for the Next Agent

1. **Never use `printf` in iOS simulator binaries** — stdout is fully buffered and may never flush. Use `write(STDERR_FILENO, ...)` with `vsnprintf`.

2. **DYLD interposition only works for cross-dylib calls** — if function A calls function B within the same dylib, interposition is bypassed. This is why `GSEventInitializeWorkspaceWithQueue` is interposed (cross-dylib entry point) instead of `GSRegisterPurpleNamedPerPIDPort` (same dylib).

3. **The broker is x86_64 macOS** — it compiles against the macOS SDK (not the iOS SDK). It includes `<servers/bootstrap.h>` which is NOT available in the iOS SDK.

4. **Message struct packing** — all structs containing `mach_msg_port_descriptor_t` must use `#pragma pack(4)`. The port descriptor is 12 bytes with this packing.

5. **bootstrap_check_in creates the RECEIVE right in the broker's task** — the client gets a SEND right. For `bootstrap_look_up`, the broker already has a SEND right and copies it to the client.

6. **The broker's message loop is single-threaded** — all messages are processed sequentially. If a client sends a request while the broker is handling another, it queues in the Mach port. This is fine for the current use case but may need threading for high-throughput scenarios.

7. **Error 141 from bootstrap_check_in** — this is not a standard Mach error. It comes from the iOS SDK's `libxpc` when bootstrap operations are attempted outside a launchd context. The shim catches this and creates local ports as a fallback.

---

## Observation IDs

Session 9 observations stored in Happy MCP:
- `0e1516db-008d-4c40-88c8-1b36fb345ccd` — Cross-process Mach port sharing via native x86_64 broker

Session 8 observation:
- `701c3231-adc9-45b8-84ba-dda7708e1a00` — backboardd CARenderServer PurpleFBServer

Query with:
```
observation_search(query="broker CARenderServer posix_spawn bootstrap", project="rosetta")
```
