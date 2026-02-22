# Session 15 Handoff — XPC Pipe Bypass + All Processes Stable

## Update (2026-02-22) — assertiond fixed; next: backboard display.services

Status (confirmed in `/tmp/rosettasim_broker.log`):
- `assertiond` stays alive past the +30s gate (observed +38s) with **zero** `Connection invalid` failures.
- `SpringBoard` stays alive.
- The app currently crashes with: `backboardd isn't running, result: 268435459 isAlive: 0` (`0x10000003` / `MACH_SEND_INVALID_DEST`).

Root cause for the earlier assertiond crash:
- Broker’s XPC pipe routine 805 reply had incorrect libxpc wire type constants (notably `mach_recv`), causing libxpc to destroy the receive right during deserialization.
- libxpc also requires XPC pipe replies to use `msgh_id = 0x20000000` (`XPC_PIPE_REPLY_MSG_ID`).

Next fix target:
- Ensure `com.apple.backboard.display.services` is registered before the app launches (in `src/bridge/purple_fb_server.c`), and start the display services handler thread exactly once.

> NOTE: The remainder of this handoff file predates the protocol fixes above and is now stale/contradictory. Treat it as historical notes only.

## Update (2026-02-22) — assertiond still crashes (Connection invalid)
The earlier “SOLVED / all stable” status is out-of-date.

Current goal: keep `assertiond` alive past the ~+30s gate by fixing mach-service LISTENER registration for:
- `com.apple.assertiond.processinfoservice`
- `com.apple.assertiond.processassertionconnection`

Evidence from `/tmp/rosettasim_broker.log` (current runs):
- Broker receives XPC pipe requests (`msgh_id=0x10000000`) with `routine=805` for multiple `com.apple.assertiond.*` services.
- Broker replies with a complex Mach message containing a port descriptor + an XPC dictionary with `"port"` typed as `mach_recv`.
- Despite this, `assertiond` still terminates with:
  - `NSInternalInconsistencyException ... Connection invalid`
  - `BSXPCServerException ... "Connection invalid"`

Key new protocol-level finding (iOS 10.3 simulator `libxpc.dylib`):
- `_xpc_pipe_routine` checks the *reply* Mach message ID before unpacking the XPC reply dictionary.
- It expects `reply->msgh_id == 0x20000000`.
- If we echo the request ID (`0x10000000`) in the reply, libxpc will not unpack/consume descriptors → listener ports remain 0.

Action (in `src/bridge/rosettasim_broker.c`):
- Set **all** XPC pipe replies (routine 805 check-in, routine 100 GetJobs, generic replies, routine 804 endpoint lookup) to use:
  - `msgh_id = 0x20000000` (`XPC_PIPE_REPLY_MSG_ID`)

Next verification discriminator:
- After rebuilding broker + bounded run, confirm:
  - assertiond listener connections have non-zero port fields post-resume
  - no `Connection invalid` crash for the two services above

## Mission
Make the iOS 9.3/10.3 simulator work with the hass-dashboard app on macOS 26 ARM64 via Rosetta 2. No fakes, no swizzles on the app itself, proper implementations.

## What Was Accomplished

### The XPC Listener Problem (SOLVED)
**Root cause**: libxpc's `xpc_connection_create_mach_service(LISTENER)` goes through a deep internal call chain that ends at `_xpc_look_up_endpoint`, which sends an XPC pipe message (msg_id 0x10000000) to launchd via `_xpc_domain_routine`. Without a real launchd, this fails silently. The `_xpc_connection_check_in` function is never reached, and the listener gets `Connection invalid`.

**Solution**: Runtime binary patching of TWO private functions in libxpc:
1. `_xpc_look_up_endpoint` → replaced with direct `bootstrap_check_in/look_up` to our broker
2. `_xpc_connection_check_in` → simplified to just call `dispatch_mach_connect` without launchd registration

### Full Call Chain Discovered
```
xpc_connection_create_mach_service(LISTENER)
  → xpc_connection_create_listener (trivial: just creates object + sets flag)

xpc_connection_resume
  → _xpc_connection_activate_if_needed → dispatch_async_f
    → _xpc_connection_resume_init
      → _xpc_connection_init
        → _xpc_connection_bootstrap_look_up_slow
          → _xpc_look_up_endpoint  ← PATCHED (bypasses XPC pipe)
          → _xpc_connection_check_in ← PATCHED (bypasses launchd registration)
```

### Binary Patching System
- Mach-O `nlist` symbol table walking finds both public AND private symbols
- x86_64 trampoline: `movabs rax, <addr>; jmp rax` (12 bytes)
- `sys_icache_invalidate` for Rosetta translation cache flush
- ALL bootstrap variants patched: look_up/2/3, check_in/2/3, register
- Private XPC functions patched: `_xpc_look_up_endpoint`, `_xpc_connection_check_in`

### XPC Pipe Protocol Analysis
- msg_id 0x10000000 for xpc_pipe_routine
- XPC wire format: `!CPX` magic (0x58504321) + version 5 + TLV entries
- Dict type: 0x0000f000, Int64: 0x00004000, String: 0x00009000
- Size field INCLUDES the count (4 bytes)
- Check-in request has keys: subsystem=3, handle, routine=805, flags, name, type
- Broker implemented XPC response builder (functional but not needed with bypass)

### Result: ALL 5 PROCESSES STABLE
```
broker (arm64 native)     — message loop running
backboardd (x86_64 iOS)   — CARenderServer active, 60Hz display sync
assertiond (x86_64 iOS)   — XPC listeners active, NO CRASH
SpringBoard (x86_64 iOS)  — workspace registered, bootstrap succeeded
HA Dashboard (x86_64 iOS) — loaded, bridge active, FBSWorkspace connected
```

## Current State
- All processes start and remain stable
- No "Connection invalid" errors
- No "Bootstrap failed" errors
- Framebuffer exists but not being updated (GPU rendering pipeline next)
- App loaded but rendering not flowing to display

## Next Steps
1. **GPU rendering pipeline**: Investigate why render commits aren't flowing to the framebuffer. The CARenderServer is running (port found, RegisterClient succeeds), but the compositing path needs work.
2. **Remove _runWithMainScene bypass**: The bridge still intercepts `_runWithMainScene`. Try removing this to let the natural UIKit lifecycle flow.
3. **Touch/keyboard/scroll**: Wire up the HID event pipeline through backboardd.

## Key Files
- `src/launcher/bootstrap_fix.c` — DYLD interposition + runtime binary patches (~900 lines)
- `src/bridge/rosettasim_broker.c` — arm64 broker with XPC pipe handler (~1400 lines)
- `src/bridge/springboard_shim.c` — simplified, delegates to real functions
- `src/bridge/rosettasim_bridge.m` — app bridge (unchanged this session)

## Key Observations (Happy memory)
- `e3928052`: Runtime binary patching + XPC pipe bypass (this session)
- `d7d7d47c`: Comprehensive session progress
- `eac874d5`: Cross-process bootstrap namespace solved
- `87028910`: Full remote context pipeline verified

## Git Log
```
7c4d500 feat: runtime binary patching of libxpc + XPC pipe bypass — all 5 processes stable
309ecb4 doc: Session 14 handoff document
```
