# Session 14 Handoff — RosettaSim Bootstrap & FBSWorkspace

## Mission
Make the iOS 9.3/10.3 simulator work with the hass-dashboard app on macOS 26 ARM64 via Rosetta 2. No fakes, no swizzles on the app itself, proper implementations of all shimmed services. Full GPU rendering, touch, keyboard, scrolling.

## What Was Accomplished (27 commits)

### Phase 1: Cross-Process Bootstrap Namespace (SOLVED)
**Root cause found**: iOS 10.3 SDK's `libxpc` caches `bootstrap_port=0` during its initializer, ignoring `TASK_BOOTSTRAP_PORT` set by `posix_spawnattr_setspecialport_np`.

**Solution**: `bootstrap_fix.dylib` — DYLD interposition replacing `bootstrap_look_up`, `bootstrap_check_in`, `bootstrap_register` with raw MIG implementations that read `TASK_BOOTSTRAP_PORT` via `task_get_special_port()` on every call.

**Broker fixes**:
- Correct MIG IDs: check_in=402, register=403, look_up=404 (were wrong: 400, 401, 402)
- check_in sends `MACH_MSG_TYPE_MOVE_RECEIVE` (was `COPY_SEND`)
- Compiled as arm64 native (was x86_64 under Rosetta)
- Port set for broker + rendezvous port
- Pre-creates MachServices for assertiond (5 services) and SpringBoard frontboard (2 services)
- `handle_check_in` returns pre-created ports instead of creating new ones

### Phase 2: GPU Rendering Pipeline (RESEARCH COMPLETE)
- RegisterClient MIG 40202 succeeds (client_id, server_port, slot all non-zero)
- `connect_remote()` returns true; `renderContext=nil` is NORMAL for remote contexts (lives server-side)
- CARenderServer has 3 channels: MIG control (40200+), private data (40002+), client callbacks (40400+)
- Render commits flow (commits=3 after detach/re-attach) but CALayerHost doesn't composite
- `commit_root` gate: `layer->0xa4` vs `context->0x5c` (local_id) must match — fails because layers created before context
- Server-side context uses `arc4random()` contextId at offset 0x0c, stored in `_context_table`

### Phase 3: FBSWorkspace Lifecycle (IN PROGRESS — next step is clear)

**Completed**:
- Removed `FBSWorkspaceClient` nil swizzle from bridge
- Removed `rendersLocally=YES` hack
- `XPC_SIMULATOR_LAUNCHD_NAME=com.apple.xpc.sim.launchd.rendezvous` eliminates error 141 (reentrancy)
- SpringBoard's "Bootstrap failed" is **GONE**
- SpringBoard registers `com.apple.frontboard.workspace`
- Pre-created rendezvous Mach service in broker with port set

**Current blocker**: Intra-library `bootstrap_look_up` / `launch_msg` in libxpc
- libxpc's `_xpc_pipe_create` calls `bootstrap_look_up` internally (intra-library)
- DYLD interposition can't catch intra-library calls
- XPC pipe creation fails with I/O error 5 → assertiond XPC listeners fail → workspace connection drops

## Next Step: Runtime Binary Patch of bootstrap_look_up in libxpc

The same technique used for `CARenderServerGetClientPort` rewrite:
1. `dlsym(RTLD_DEFAULT, "bootstrap_look_up")` to find the function in libxpc
2. `vm_protect` to make the code page writable
3. Write x86_64 trampoline: `movabs rax, <replacement_addr>; jmp rax` (12 bytes)
4. This redirects ALL calls (both intra and cross-library) to our `replacement_bootstrap_look_up`

This makes the XPC pipe connect to our rendezvous port → assertiond XPC listeners work → SpringBoard FBSWorkspace lifecycle flows naturally → UIKit creates windows with proper timing → GPU rendering works.

## Key Files
- `src/launcher/bootstrap_fix.c` — DYLD interposition + runtime patches (~640 lines)
- `src/bridge/rosettasim_broker.c` — arm64 native broker with MIG protocol, port set, pre-created services
- `src/bridge/rosettasim_bridge.m` — app bridge (FBSWorkspace swizzle removed, _runWithMainScene still intercepted)
- `src/bridge/springboard_shim.c` — SpringBoard/assertiond XPC handling
- `src/bridge/purple_fb_server.c` — CARenderServer + PurpleFBServer + display services

## Architecture (Proper, No Hacks)
```
Broker (arm64 native macOS)
  ├── Creates bootstrap namespace (Mach port)
  ├── Pre-creates MachServices from daemon plists
  ├── Port set: broker port + rendezvous port
  ├── Sets TASK_BOOTSTRAP_PORT for all children
  └── Sets XPC_SIMULATOR_LAUNCHD_NAME env var

bootstrap_fix.dylib (x86_64 iOS SDK, DYLD_INSERT_LIBRARIES first)
  ├── DYLD interposes: bootstrap_look_up, check_in, register
  ├── DYLD interposes: GSGetPurpleApplicationPort, launch_msg
  ├── Runtime patches: CARenderServerGetClientPort (function rewrite)
  └── Constructor: sets bootstrap_port, early CARenderServer lookup

Processes:
  backboardd → CARenderServer at 60fps, PurpleFBServer, display.services
  assertiond → XPC listeners (check_in works, XPC pipe fails — BLOCKER)
  SpringBoard → workspace registered, bootstrap succeeds
  app → REMOTE context created, RegisterClient succeeds
```

## Key Observations (saved in Happy memory)
- `d7d7d47c`: Comprehensive session progress
- `25ed0f7d`: Stop hacking — implement FBSWorkspace lifecycle
- `87028910`: Full remote context pipeline verified
- `ddce2e38`: RegisterClient reply format decoded
- `eac874d5`: Cross-process bootstrap namespace solved
- `139331be`: IOSurface backing store issue analysis

## Agent Research Transcripts
Available in `~/.claude/projects/.../subagents/`:
- `agent-a0b79a7.jsonl` — CA::Transaction::commit path (complete)
- `agent-a789fd9.jsonl` — CALayerHost compositing mechanism (complete)
- `agent-acb0306.jsonl` — CARenderServer MIG dispatch (complete)
- `agent-a8df1c5.jsonl` — commit_transaction skip logic (complete)
- `agent-ab4aa5e.jsonl` — Server-side context creation (complete)
- `agent-a995eb9.jsonl` — SpringBoard FBSWorkspace lifecycle (complete)
- `agent-a31758f.jsonl` — XPC listener initialization (complete)

## Git Log (27 commits this session)
```
422443f feat: port set for broker + rendezvous port, XPC pipe detection
e652614 feat: rendezvous port registration + launch_msg protocol investigation
d1aae8c feat: XPC_SIMULATOR_LAUNCHD_NAME + rendezvous service pre-creation
3819847 feat: launch_msg interposition attempt for XPC listener check-in
3b3eb65 feat: remove FBSWorkspaceClient nil swizzle — allow natural connection
04f2d57 feat: pre-create MachServices + fix check_in for pre-created ports
dd35849 wip: FBSWorkspace implementation research + assertiond XPC diagnosis
53c013f diag: commit_root gate found — layer->0xa4 vs context->0x5c mismatch
94b6d0e diag: commits=3 flowing but CALayerHost doesn't resolve
553756e feat: render commits now flow (commits=3) + contextId investigation
eefe961 diag: encoder_ctxId != client_id + commits=0 discovery
0099a63 revert: remove rendersLocally=YES hack — use REMOTE context only
caf2724 feat: rendersLocally=YES override for reliable CPU rendering
a87ff91 diag: inspect CA::Context C++ fields after connect_remote
bb4ce58 feat: fix contextId IPC + connect_remote disassembly findings
e2ba44d feat: GSGetPurpleApplicationPort interposition + UIKit natural context path
fe6525e feat: add iokitsimd spawning + remove broken GetClientPort interposition
6a76951 feat: runtime CARenderServerGetClientPort function rewrite + diagnostic
6af8fd3 feat: RegisterClient MIG message successfully sent to CARenderServer
3b0f21b feat: early remote CAContext creation to trigger connect_remote
1f74aa8 feat: early CARenderServer lookup + Display Pipeline wiring
d7e451f feat: cross-process bootstrap namespace via bootstrap_fix.dylib + MIG
```
