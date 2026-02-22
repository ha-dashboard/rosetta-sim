# RosettaSim Mach Port Broker

The RosettaSim broker is a production-quality Mach port broker that enables cross-process Mach port sharing between backboardd and iOS app processes running in the simulator environment.

## Overview

The broker acts as a mini bootstrap server, allowing iOS binaries running via Rosetta 2 to register and lookup Mach services. This is necessary because the iOS SDK's bootstrap functions cannot directly interact with macOS launchd.

## Architecture

```
┌─────────────────────────────────────────┐
│   RosettaSim Broker (arm64 macOS)      │
│                                         │
│  - Mach port registry                   │
│  - Message dispatch loop                │
│  - Child process spawning               │
└────────┬──────────────────┬─────────────┘
         │                  │
         │ TASK_           │ TASK_
         │ BOOTSTRAP_      │ BOOTSTRAP_
         │ PORT            │ PORT
         │                 │
         ▼                 ▼
┌─────────────────┐  ┌──────────────────┐
│   backboardd    │  │   iOS App        │
│   (x86_64 iOS)  │  │   (x86_64 iOS)   │
│                 │  │                  │
│  - CARenderServer│  │ - CA Client      │
└─────────────────┘  └──────────────────┘
```

## Building

```bash
./scripts/build_broker.sh
```

This compiles `rosettasim_broker.c` as an arm64 macOS binary (NOT against the iOS SDK) and code-signs it.

## Usage

```bash
./src/bridge/rosettasim_broker [--sdk PATH] [--shim PATH] [--app PATH]
```

### Options

- `--sdk PATH`: iOS SDK path (default: Xcode 8.3.3 iOS 10.3 simulator SDK)
- `--shim PATH`: Path to purple_fb_server.dylib (default: src/bridge/purple_fb_server.dylib)
- `--app PATH`: Path to iOS app binary to launch after backboardd init (optional)

### Example

```bash
# Launch broker with default settings
./src/bridge/rosettasim_broker

# Launch with custom SDK
./src/bridge/rosettasim_broker --sdk /path/to/SDK

# Launch and run an app
./src/bridge/rosettasim_broker --app /path/to/app/binary
```

## Protocol

The broker handles three categories of IPC:

### 1. MIG bootstrap messages

These are `mach_msg` requests sent to the task’s bootstrap port. **Note:** the message IDs observed for the iOS 10.3 simulator runtime differ from older docs — see the `BOOTSTRAP_*` defines in `src/bridge/rosettasim_broker.c`.

- **bootstrap_check_in (402)**: service check-in / acquire the receive right for a Mach service
- **bootstrap_register (403)**: register an existing port under a name
- **bootstrap_look_up (404)**: look up a named service (returns a send right)
- **bootstrap_parent (406)**: requested by dyld; broker replies with `KERN_INVALID_RIGHT`
- **bootstrap_subset (409)**: broker replies with `KERN_INVALID_RIGHT` (matches modern macOS behavior)

### 2. Legacy custom broker messages (700-799)

Used by injected shims (e.g. `purple_fb_server.dylib`) that need a stable path to the broker even when the iOS SDK’s bootstrap APIs take an incompatible fast path on modern macOS.

- **BROKER_REGISTER_PORT (700)**: register a port under a name (includes a `name_len` field)
- **BROKER_LOOKUP_PORT (701)**: look up a port by name (includes a `name_len` field)
- **BROKER_SPAWN_APP (702)**: placeholder (not yet implemented as an IPC message)

### 3. XPC pipe (sim launchd rendezvous)

Many iOS 10.3 daemons register XPC Mach services via `xpc_connection_create_mach_service()`, which talks to “launchd” over an XPC pipe connection. The broker emulates the simulator launchd rendezvous port:

- Service name: `com.apple.xpc.sim.launchd.rendezvous`
- Request Mach msg ID: `0x10000000` (`XPC_LAUNCH_MSG_ID`)
- Reply Mach msg ID: **must** be `0x20000000` (`XPC_PIPE_REPLY_MSG_ID`) or libxpc will ignore the reply’s ports/payload.

Implemented launchd routines:
- `routine=100` (GetJobs)
- `routine=804` (endpoint lookup): returns a `mach_send` right (`MOVE_SEND`) and XPC `"port"` typed `mach_send`
- `routine=805` (check-in): returns a `mach_recv` receive right (`MOVE_RECEIVE`) and XPC `"port"` typed `mach_recv`

XPC wire type IDs (iOS 10.3 simulator `libxpc.dylib`):
- `bool = 0x00002000`
- `int64 = 0x00003000`
- `uint64 = 0x00004000`
- `string = 0x00009000`
- `dict = 0x0000f000`
- `mach_send = 0x0000d000`
- `mach_recv = 0x00015000`

## Message Formats

### MIG simple request (look_up, check_in)
```c
mach_msg_header_t (24 bytes)
NDR_record_t (8 bytes)
char name[128]
Total: 160 bytes
```

### MIG complex request (register)
```c
mach_msg_header_t (24 bytes)
mach_msg_body_t (4 bytes)
mach_msg_port_descriptor_t (12 bytes)
NDR_record_t (8 bytes)
char name[128]
Total: 176 bytes
```

### MIG port reply (success)
```c
mach_msg_header_t (24 bytes) - COMPLEX flag set
mach_msg_body_t (4 bytes)
mach_msg_port_descriptor_t (12 bytes)
Total: 40 bytes
```
### MIG error reply
```c
mach_msg_header_t (24 bytes)
NDR_record_t (8 bytes)
kern_return_t (4 bytes)
Total: 36 bytes
```

### Legacy broker request formats (700/701)

These mirror the old “name_len + name[128]” layout used by some injected shims:

```c
// Simple (lookup): header + NDR + name_len + name[128]
Total: 164 bytes

// Complex (register): header + body + port_desc + NDR + name_len + name[128]
Total: 180 bytes
```

## Process Spawning

The broker spawns backboardd using `posix_spawn` with:

1. **Special port**: `TASK_BOOTSTRAP_PORT` set to broker port via `posix_spawnattr_setspecialport_np`
2. **Environment variables**:
   - `DYLD_ROOT_PATH`: iOS SDK path (enables Rosetta 2 iOS mode)
   - `DYLD_INSERT_LIBRARIES`: purple_fb_server.dylib (CARenderServer shim)
   - `IPHONE_SIMULATOR_ROOT`: iOS SDK path
   - `SIMULATOR_ROOT`: iOS SDK path
   - `HOME`: User's home directory
   - `CFFIXED_USER_HOME`: User's home directory
   - `TMPDIR`: Temporary directory
   - `SIMULATOR_DEVICE_NAME`: "RosettaSim"

Child processes inherit the broker port as their bootstrap port and can immediately start registering/looking up services.

## Service Registry

The broker maintains an in-memory registry with:

- **Capacity**: 128 services
- **Key**: Service name (max 128 chars)
- **Value**: Mach port send right
- **Operations**: Register, lookup

## Logging

All output is written to stderr using `write(STDERR_FILENO, ...)` for debugging. Example output:

```
[broker] RosettaSim broker starting
[broker] broker port created: 0x1303
[broker] spawning backboardd
[broker] backboardd spawned with pid 12345
[broker] entering message loop
[broker] received message: id=404 size=188
[broker] bootstrap_parent request (ignoring)
[broker] received message: id=400 size=164
[broker] check_in request: com.apple.PurpleFBServer
[broker] registered service com.apple.PurpleFBServer in slot 0
```

## Process Lifecycle

1. Broker starts and creates broker port
2. Broker spawns backboardd with broker port as bootstrap port
3. backboardd's dyld sends bootstrap_parent (406) - broker ignores
4. backboardd initializes, purple_fb_server.dylib creates CARenderServer
5. purple_fb_server.dylib registers \"PurpleFBServer\" and Purple ports via BROKER_REGISTER_PORT (700)
6. Apps can now lookup "com.apple.PurpleFBServer" and connect
7. Broker receives SIGCHLD when backboardd exits
8. Broker shuts down gracefully

## Signals

- **SIGCHLD**: Handled to detect child process termination
- **SIGTERM/SIGINT**: Triggers graceful shutdown
- **Shutdown**: Kills backboardd, deallocates ports, removes PID file

## PID File

The broker writes its PID to `/tmp/rosettasim_broker.pid` on startup.

## Error Handling

All mach_msg operations check return values and log errors. Common errors:

- `BOOTSTRAP_UNKNOWN_SERVICE (1102)`: Service not found in registry
- `BOOTSTRAP_NAME_IN_USE (1101)`: Service already registered
- `BOOTSTRAP_NO_MEMORY (1105)`: Registry full or port allocation failed
- `KERN_INVALID_RIGHT (17)`: Returned for unsupported operations (subset)
- `MIG_BAD_ID (-303)`: Unknown message ID

## Memory Management

- Mach ports are deallocated on shutdown
- Service registry is statically allocated (no dynamic allocation)
- Message buffers use stack allocation (4096 bytes)

## Security Considerations

- No authentication - any process with access to the broker port can register/lookup services
- Service names are not validated beyond length checks
- No rate limiting on message processing
- Intended for development/testing only, not production use

## Future Enhancements

- Implement BROKER_SPAWN_APP (702) for on-demand app launching
- Add service lifecycle management (unregister on client death)
- Support for bootstrap subsets
- Audit logging for security monitoring

## Debugging

To debug the broker:

```bash
# Run with stderr visible
./src/bridge/rosettasim_broker 2>&1 | tee broker.log

# Check if broker is running
ps aux | grep rosettasim_broker

# Check PID file
cat /tmp/rosettasim_broker.pid

# Monitor Mach ports
lsmp -p $(cat /tmp/rosettasim_broker.pid)
```

## Integration with purple_fb_server.dylib

The purple_fb_server.dylib shim uses the broker like this:

```c
// Get broker port from bootstrap port
mach_port_t broker_port;
task_get_special_port(mach_task_self(), TASK_BOOTSTRAP_PORT, &broker_port);

// Register CARenderServer port
// (via bootstrap_check_in or bootstrap_register)
// Message format: see protocol documentation above
```

## References

- `posix_spawnattr_setspecialport_np(3)` - Setting special ports for spawned processes
- `mach_msg(2)` - Mach message primitives
- `bootstrap.h` - Bootstrap server interface
- iOS 10.3 SDK documentation
- Rosetta 2 architecture documentation
