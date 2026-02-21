# Session 12 Handoff — SpringBoard Bootstrap Chain & XPC Gap

**Date:** 2026-02-21
**Commit:** 5361a40
**Focus:** Getting the real iOS simulator stack running (backboardd + SpringBoard + app)

## What Was Achieved

### 1. HID System Manager Bundle (WORKING)

Created `src/bridge/RosettaSimHIDManager.bundle` — an x86_64 bundle that SimulatorClient.framework loads via `SIMULATOR_HID_SYSTEM_MANAGER` environment variable.

**Proven:**
- `IndigoHIDSystemSpawnLoopback()` returns YES
- `Initialized Simulator HID System Manager: <RosettaSimHIDManager: 0x...>`
- backboardd initializes fully with 1 display, CARenderServer at ~60fps
- The `displays` method returns `[CADisplay displays]` from the running CARenderServer

**Source:** `src/bridge/rosettasim_hid_manager.m` (350 lines)
**Build:** `bash scripts/build_hid_manager.sh`
**Protocol implemented:** `SimulatorClientHIDSystemManager` with `initUsingHIDService:error:`, `displays`, `hasTouchScreen`, `hasTouchScreenLofi`, `hasWheel`, `name`, `uniqueId`

### 2. SpringBoard Shim (WORKING)

Created `src/bridge/springboard_shim.c` — DYLD interposition library that routes `bootstrap_look_up`, `bootstrap_check_in`, and `bootstrap_register` through the broker.

**Why needed:** iOS SDK's `bootstrap_look_up` on macOS 26 uses `mach_msg2`/XPC internally, which doesn't go through the broker's `mach_msg`-based handler. The shim intercepts the cross-library call and routes it via msg_id 701 (BROKER_LOOKUP_PORT).

**Proven:**
- SpringBoard finds `com.apple.CARenderServer` through the shim → broker → backboardd
- SpringBoard registers `PurpleSystemAppPort` (check-in through MIG protocol)

**Source:** `src/bridge/springboard_shim.c` (~200 lines)
**Build:** `bash scripts/build_springboard_shim.sh`

### 3. Broker Enhancements

- `spawn_sim_daemon()` — generic function to spawn any iOS SDK daemon with broker port and shim
- `spawn_assertiond()` — spawns assertiond before SpringBoard
- `spawn_springboard()` — uses generic function
- `MAX_SERVICES` increased from 64 to 128
- Launch order: backboardd → wait for services → assertiond → wait → SpringBoard → wait → app
- PID-based cleanup (no more pattern-matching kills)

### 4. purple_fb_server Enhancements

- Pre-registers all Purple system ports during init (before SpringBoard starts):
  - `PurpleSystemEventPort`, `PurpleWorkspacePort`, `PurpleSystemAppPort`
  - `com.apple.backboard.system-app-server`, `com.apple.backboard.checkin`
  - `com.apple.backboard.animation-fence-arbiter`, `com.apple.backboard.hid.focus`
  - `com.apple.backboard.TouchDeliveryPolicyServer`
- Each GSRegisterPurpleNamedPort now creates a unique port (not shared dummy) and notifies broker
- Each GSGetPurple* function creates a singleton port and notifies broker

### 5. Scroll Investigation Results

Tested extensively. The scroll crash is **not fixable in CPU rendering mode**:
- `UIScrollView.setContentOffset:` triggers CA internal layout
- `layoutIfNeeded` in the render loop accesses CARenderServer internals
- Without proper display client registration, CA layout causes SIGSEGV
- `siglongjmp` recovery from SIGSEGV corrupts the Objective-C autorelease pool
- Removing `siglongjmp` lets the process die cleanly but still crashes
- Swizzling `setContentOffset:` to bypass CA also fails — `setBounds:` on any UIView or CALayer triggers the same CA path
- Setting just the ivar without any CA operation makes scroll invisible

**Conclusion:** Scroll requires the real display pipeline. CPU-only `renderInContext` cannot support UIScrollView.

## The Blocking Issue: XPC Service Registration

### The Problem

iOS simulator daemons (assertiond, SpringBoard, etc.) register their Mach services via `xpc_connection_create_mach_service()`. This XPC function:

1. On real iOS/launchd: sends an XPC message to launchd which manages service namespaces
2. On macOS 26: goes through an XPC/mach_msg2 path that requires a real launchd

Our broker only handles MIG bootstrap protocol (msg_ids 400-405, 700-702) via standard `mach_msg`. It cannot process XPC service registration requests.

### What Fails

**assertiond** crashes immediately:
```
Error getting job dictionaries. Error: Reentrancy avoided (141)
Invalid connection to the Application State Server
Terminating app due to uncaught exception 'NSInternalInconsistencyException',
  reason: 'Error on <BSXPCConnectionListener: service: com.apple.assertiond.processassertionconnection>:
  Connection invalid'
```

This happens because `xpc_connection_create_mach_service("com.apple.assertiond.processassertionconnection", ...)` with `XPC_CONNECTION_MACH_SERVICE_LISTENER` flag tries to register as a listener for that service — and our broker can't handle this.

**SpringBoard** then fails because `BKSProcessAssertionClient` (from `AssertionServices.framework`) can't connect to assertiond's XPC services, producing "Bootstrap failed with error: (null)".

### What assertiond Needs

Binary: `$SDK/usr/libexec/assertiond` (x86_64, from iOS 10.3 SDK)

XPC services it registers (from launchd plist):
- `com.apple.assertiond.processassertionconnection`
- `com.apple.assertiond.applicationstateconnection`
- `com.apple.assertiond.processinfoservice`
- `com.apple.assertiond.appwatchdog`
- `com.apple.assertiond.expiration`

### The Two Approaches

#### Approach A: XPC Interposition in the Shim

Add `xpc_connection_create_mach_service` interposition to `springboard_shim.c` (which is loaded into all daemons). When a daemon calls this with `XPC_CONNECTION_MACH_SERVICE_LISTENER`:

1. Create a local Mach port (receive right)
2. Register the service name + port with the broker
3. Create a dispatch_source on the port to handle incoming connections
4. Return an xpc_connection_t that wraps our local port

When a client calls `xpc_connection_create_mach_service` WITHOUT the listener flag:
1. Look up the service in the broker
2. Create an xpc_connection_t targeting the broker-provided port
3. Return it

**Complexity:** High. XPC connections have a complex lifecycle (event handlers, cancellation, message serialization). We'd need to implement enough of the XPC connection protocol for assertiond's simple request/reply pattern.

**Advantage:** Works for ALL daemons without changes. Same shim injected everywhere.

#### Approach B: Minimal launchd_sim

Build a replacement for `launchd_sim` that:
1. Handles MIG bootstrap protocol (already done in broker)
2. Handles XPC service registration via `xpc_connection_create_mach_service`
3. Manages a service namespace that all child processes inherit

Apple's real `launchd_sim` existed in older Xcode versions. The key insight: `launchd_sim` was just a special bootstrap namespace provider. On macOS, `bootstrap_subset()` creates child namespaces. Our broker already tried this (error 17 = KERN_INVALID_RIGHT on modern macOS).

The actual mechanism used by CoreSimulatorService:
1. `launchd_sim` is spawned inside a bootstrap subset
2. All simulator processes inherit `launchd_sim` as their bootstrap port
3. `launchd_sim` handles both MIG bootstrap AND XPC service registration

**Complexity:** Very high. Would need to implement the XPC server-side protocol that launchd provides.

**Advantage:** Most correct solution. All daemons work naturally.

#### Approach C: Skip assertiond, Stub Its Client

Instead of running assertiond, intercept `BKSProcessAssertionClient` in SpringBoard to not require the assertiond connection. This is a targeted fix:

1. In `springboard_shim.c`, interpose `xpc_connection_create_mach_service` only for assertiond's service names
2. Return a dummy XPC connection that never fires events
3. `BKSProcessAssertionClient` gets a "connected" connection and doesn't crash

**Complexity:** Medium. Need to understand enough of the XPC connection lifecycle to fake a valid connection.

**Advantage:** Targeted, doesn't require full XPC support. Only fakes the specific services assertiond provides.

**Disadvantage:** The user explicitly said "no bypasses, proper implementations." This feels like a bypass.

## Architecture Reference

### Current Launch Chain (Proven Working)

```
rosettasim_broker (x86_64 macOS)
  ├─ posix_spawn(backboardd, BOOTSTRAP=broker, DYLD_INSERT=purple_fb_server.dylib)
  │   ├─ PurpleFBServer: framebuffer + bootstrap interception
  │   ├─ RosettaSimHIDManager.bundle: display/HID for SimulatorClient
  │   ├─ CARenderServer: GPU rendering at ~60fps
  │   └─ Registers: CARenderServer, iohideventsystem, Purple ports, backboard services
  │
  ├─ posix_spawn(assertiond, BOOTSTRAP=broker, DYLD_INSERT=springboard_shim.dylib)
  │   └─ CRASHES: xpc_connection_create_mach_service fails (error 141)
  │
  ├─ posix_spawn(SpringBoard, BOOTSTRAP=broker, DYLD_INSERT=springboard_shim.dylib)
  │   ├─ Finds CARenderServer via shim → broker ✅
  │   ├─ Registers PurpleSystemAppPort ✅
  │   └─ "Bootstrap failed": assertiond connection missing
  │
  └─ posix_spawn(app, BOOTSTRAP=broker, DYLD_INSERT=rosettasim_bridge.dylib)
      ├─ Finds CARenderServer via bridge → broker ✅
      └─ CPU rendering partial (backing stores migrated to GPU)
```

### Target Launch Chain

```
rosettasim_broker (x86_64 macOS)
  ├─ backboardd + purple_fb_server.dylib + RosettaSimHIDManager.bundle
  │   └─ CARenderServer, display, HID, Purple services
  │
  ├─ assertiond + springboard_shim.dylib (XPC support needed)
  │   └─ Process assertion services
  │
  ├─ SpringBoard + springboard_shim.dylib
  │   └─ System app, FBSWorkspace, app lifecycle, display assignment
  │
  └─ HA Dashboard app (NO bridge needed if SpringBoard works)
      └─ Normal iOS app connecting via FBSWorkspace
```

### Services Registered with Broker (14 total as of last run)

| Slot | Service | Source |
|------|---------|--------|
| 0 | PurpleSystemEventPort | purple_fb_server (pre-init) |
| 1 | PurpleWorkspacePort | purple_fb_server (pre-init) |
| 2 | PurpleSystemAppPort | purple_fb_server (pre-init) |
| 3 | com.apple.backboard.system-app-server | purple_fb_server (pre-init) |
| 4 | com.apple.backboard.checkin | purple_fb_server (pre-init) |
| 5 | com.apple.backboard.animation-fence-arbiter | purple_fb_server (pre-init) |
| 6 | com.apple.backboard.hid.focus | purple_fb_server (pre-init) |
| 7 | com.apple.backboard.TouchDeliveryPolicyServer | purple_fb_server (pre-init) |
| 8 | com.apple.CARenderServer | backboardd (bootstrap_check_in) |
| 9 | com.apple.iohideventsystem | backboardd (bootstrap_check_in) |
| 10 | com.apple.backboard.watchdog | backboardd (GSRegisterPurple) |
| 11 | com.apple.backboard.hid.services | backboardd (GSRegisterPurple) |
| 12 | com.apple.backboard.display.services | backboardd (GSRegisterPurple) |
| 13 | com.apple.accessibility.AXBackBoardServer | backboardd (GSRegisterPurple) |

## Files Created/Modified This Session

| File | Lines | Purpose |
|------|-------|---------|
| src/bridge/rosettasim_hid_manager.m | 350 | HID System Manager bundle source |
| src/bridge/RosettaSimHIDManager.bundle/ | - | Compiled x86_64 bundle |
| src/bridge/springboard_shim.c | 200 | Bootstrap routing for SpringBoard/daemons |
| scripts/build_hid_manager.sh | 45 | HID bundle build script |
| scripts/build_springboard_shim.sh | 12 | Shim build script |
| src/bridge/rosettasim_broker.c | +248 | assertiond, generic daemon spawner, safe cleanup |
| src/bridge/purple_fb_server.c | +114 | Pre-register Purple ports, unique port allocation |
| scripts/run_full.sh | +33 | PID-based cleanup, longer timeout |
| scripts/run_backboardd.sh | +11 | HID bundle env var |

## Critical Safety Note

**NEVER use `pkill -f` with generic process names** like `backboardd`, `SpringBoard`, `WindowServer`. These match macOS system services and will crash the Mac. Always kill by exact PID. This is documented in `~/.claude/CLAUDE.md`.

## What the Next Agent Must Do

### Priority 1: XPC Service Registration

The broker needs to handle `xpc_connection_create_mach_service()` calls from iOS daemons. The interposition approach (in springboard_shim.c) is the most practical:

1. Interpose `xpc_connection_create_mach_service` in the shim
2. When called with `XPC_CONNECTION_MACH_SERVICE_LISTENER` flag:
   - Allocate a Mach receive port
   - Register service name + port with broker (msg_id 700)
   - Create an `xpc_connection_t` that wraps the port (use `xpc_connection_create_from_endpoint` or manual construction)
   - Return the connection
3. When called WITHOUT listener flag (client mode):
   - Look up service in broker (msg_id 701)
   - Create `xpc_connection_t` targeting the broker-provided port
   - Return it

Key challenge: the XPC connection lifecycle. assertiond sets event handlers and expects messages. The connection must be valid enough that `xpc_connection_set_event_handler` and `xpc_connection_resume` don't crash.

Research needed:
- How does `xpc_connection_create_mach_service` actually create the underlying Mach port?
- Can we use `xpc_connection_create_from_endpoint` with a Mach port we control?
- What's the minimum viable XPC connection that assertiond accepts?

### Priority 2: Verify assertiond Boots

Once XPC interposition works, assertiond should register its 5 services and stay alive. Verify with logs.

### Priority 3: SpringBoard Full Boot

With assertiond running, SpringBoard's `BKSProcessAssertionClient` should connect. Check what else fails after that — there may be more daemons needed (splashboardd, configd_sim, lsd, etc.).

### Priority 4: App Display Through SpringBoard

Once SpringBoard boots fully, it should:
1. Create a display scene for itself
2. Accept app launch requests
3. Assign display contexts to apps
4. CARenderServer composites app content onto PurpleDisplay

The app should NOT need the bridge library at all if SpringBoard properly manages its lifecycle.

## Build & Run Commands

```bash
# Build everything
bash scripts/build_purple_fb.sh
bash scripts/build_broker.sh
bash scripts/build_bridge.sh
bash scripts/build_hid_manager.sh
bash scripts/build_springboard_shim.sh

# Run full pipeline (launches host display app too)
ROSETTASIM_DNS_MAP="homeassistant.local=192.168.1.162" \
  bash scripts/run_full.sh "/path/to/HA Dashboard.app"

# Check logs
tail -f /tmp/rosettasim_broker.log

# Take screenshot
python3 tests/fb_screenshot.py /tmp/screenshot.png
```
