# RosettaSim Mach Port Broker

The RosettaSim broker is a production-quality Mach port broker that enables cross-process Mach port sharing between backboardd and iOS app processes running in the simulator environment.

## Overview

The broker acts as a mini bootstrap server, allowing iOS binaries running via Rosetta 2 to register and lookup Mach services. This is necessary because the iOS SDK's bootstrap functions cannot directly interact with macOS launchd.

## Architecture

```
┌─────────────────────────────────────────┐
│   RosettaSim Broker (x86_64 macOS)     │
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

This compiles `rosettasim_broker.c` as an x86_64 macOS binary (NOT against the iOS SDK) and code-signs it.

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

The broker handles two types of messages:

### 1. MIG Bootstrap Messages (subsystem 400)

These are standard bootstrap protocol messages sent by dyld and iOS frameworks:

- **bootstrap_check_in (400)**: Create a new receive port for a service
  - Client sends: service name
  - Broker creates: receive port + send right
  - Broker returns: send right to client
  - Broker registers: name → port in registry

- **bootstrap_register (401)**: Register an existing port
  - Client sends: service name + port descriptor
  - Broker registers: name → port in registry
  - Broker returns: success/error

- **bootstrap_look_up (402)**: Look up a service by name
  - Client sends: service name
  - Broker looks up: name → port
  - Broker returns: send right to port or error 1102

- **bootstrap_parent (404)**: Request parent bootstrap port
  - Sent by dyld during initialization
  - Broker returns: error (not supported)

- **bootstrap_subset (405)**: Create bootstrap subset
  - Broker returns: KERN_INVALID_RIGHT (17) - same as real macOS

### 2. Custom Broker Messages (700-799)

These are RosettaSim-specific messages:

- **BROKER_REGISTER_PORT (700)**: Register a port (same as bootstrap_register)
- **BROKER_LOOKUP_PORT (701)**: Look up a port (same as bootstrap_look_up)
- **BROKER_SPAWN_APP (702)**: Request to spawn an app process (not yet implemented)

## Message Formats

### Simple Request (look_up, check_in)
```c
mach_msg_header_t (24 bytes)
NDR_record_t (8 bytes)
uint32_t name_len
char name[128]
Total: 164 bytes
```

### Complex Request (register)
```c
mach_msg_header_t (24 bytes)
mach_msg_body_t (4 bytes)
mach_msg_port_descriptor_t (12 bytes)
NDR_record_t (8 bytes)
uint32_t name_len
char name[128]
Total: 180 bytes
```

### Port Reply (success)
```c
mach_msg_header_t (24 bytes) - COMPLEX flag set
mach_msg_body_t (4 bytes)
mach_msg_port_descriptor_t (12 bytes)
Total: 40 bytes
```

### Error Reply
```c
mach_msg_header_t (24 bytes)
NDR_record_t (8 bytes)
kern_return_t (4 bytes)
Total: 36 bytes
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

- **Capacity**: 64 services
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
3. backboardd's dyld sends bootstrap_parent (404) - broker ignores
4. backboardd initializes, purple_fb_server.dylib creates CARenderServer
5. purple_fb_server.dylib registers "com.apple.PurpleFBServer" via check_in (400)
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
