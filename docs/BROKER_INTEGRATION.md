# Broker Integration Guide

> NOTE (2026-02-22): This guide was written for the earlier bootstrap-only broker.
> The current broker also implements XPC pipe (launchd) routines needed for iOS 10.3 XPC mach-service registration.
> See `src/bridge/README_BROKER.md` and `src/bridge/rosettasim_broker.c` for up-to-date protocol details.

This guide explains how to integrate the RosettaSim broker with the existing RosettaSim project.

## Overview

The broker replaces the previous approach of having purple_fb_server.dylib handle bootstrap messages directly. Instead:

1. **Broker** runs as the top-level process and manages all service registration
2. **backboardd** runs as a child of the broker with the broker port as its bootstrap port
3. **Apps** run as children of the broker with the broker port as their bootstrap port
4. **All processes** use standard bootstrap functions (check_in, look_up) to communicate

## Architecture Comparison

### Previous (Session 6)
```
backboardd (with purple_fb_server.dylib)
  └─ Handled bootstrap messages directly
  └─ Apps connected via hardcoded ports
```

### New (With Broker)
```
rosettasim_broker
  ├─ backboardd (with purple_fb_server.dylib)
  │    └─ Registers CARenderServer port via bootstrap_check_in
  └─ Apps
       └─ Look up CARenderServer port via bootstrap_look_up
```

## Files Created

1. **`src/bridge/rosettasim_broker.c`** - The broker implementation (~700 lines)
2. **`scripts/build_broker.sh`** - Build script for the broker
3. **`src/bridge/README_BROKER.md`** - Detailed broker documentation
4. **`tests/broker_test.c`** - Test program for broker functionality
5. **`tests/run_broker_test.sh`** - Test runner script
6. **`docs/BROKER_INTEGRATION.md`** - This file

## Building

```bash
./scripts/build_broker.sh
```

This creates `src/bridge/rosettasim_broker` as an x86_64 macOS binary.

## Running

### Basic Usage

```bash
./src/bridge/rosettasim_broker
```

This will:
1. Create the broker port
2. Spawn backboardd with default SDK and purple_fb_server.dylib
3. Run the message loop to handle bootstrap requests
4. Exit when backboardd terminates

### With Custom Paths

```bash
./src/bridge/rosettasim_broker \
  --sdk /path/to/iOS.sdk \
  --shim /path/to/purple_fb_server.dylib
```

### Running an App

```bash
./src/bridge/rosettasim_broker --app /path/to/app/binary
```

(Note: App spawning is not yet implemented - this is a placeholder for future work)

## Integration Steps

### Step 1: Update purple_fb_server.dylib

The shim no longer needs to handle bootstrap messages directly. Instead, it should:

1. Get the broker port from bootstrap port:
```c
mach_port_t broker_port;
task_get_special_port(mach_task_self(), TASK_BOOTSTRAP_PORT, &broker_port);
```

2. Register the CARenderServer port using standard bootstrap_check_in:
```c
// Build bootstrap_check_in message (msg_id=400)
// Send to broker_port
// Receive port reply
// Store the port for CARenderServer to use
```

See `src/bridge/README_BROKER.md` for the exact message format.

### Step 2: Update App Launch

Apps should be spawned via the broker (or manually with the broker port):

```c
posix_spawnattr_t attr;
posix_spawnattr_init(&attr);

// Get broker port (from environment, PID file, or registry)
mach_port_t broker_port = get_broker_port();

// Set as app's bootstrap port
posix_spawnattr_setspecialport_np(&attr, broker_port, TASK_BOOTSTRAP_PORT);

// Spawn app
posix_spawn(&pid, app_path, NULL, &attr, argv, envp);
```

Apps will then automatically have access to the broker for service lookup.

### Step 3: Update CA Client Code

In the app's CoreAnimation initialization code:

1. Get broker port from bootstrap port:
```c
mach_port_t broker_port;
task_get_special_port(mach_task_self(), TASK_BOOTSTRAP_PORT, &broker_port);
```

2. Look up CARenderServer using bootstrap_look_up:
```c
// Build bootstrap_look_up message (msg_id=402)
// Send to broker_port with service name "com.apple.PurpleFBServer"
// Receive port reply
// Use the port to connect to CARenderServer
```

### Step 4: Testing the Integration

1. Build the broker:
```bash
./scripts/build_broker.sh
```

2. Run the broker with verbose logging:
```bash
./src/bridge/rosettasim_broker 2>&1 | tee broker.log
```

3. Watch for these log messages:
```
[broker] broker port created: 0x1003
[broker] backboardd spawned with pid 12345
[broker] received message: id=400 size=164
[broker] check_in request: com.apple.PurpleFBServer
[broker] registered service com.apple.PurpleFBServer in slot 0
```

4. Use `lsmp` to verify port creation:
```bash
lsmp -p $(cat /tmp/rosettasim_broker.pid)
```

### Step 5: Update Scripts

Update your launch scripts to use the broker:

**Before:**
```bash
DYLD_ROOT_PATH=$SDK DYLD_INSERT_LIBRARIES=purple_fb_server.dylib \
  $SDK/usr/libexec/backboardd
```

**After:**
```bash
./src/bridge/rosettasim_broker \
  --sdk $SDK \
  --shim purple_fb_server.dylib
```

## Message Protocol Reference

### bootstrap_check_in (400)

**Request:**
```c
mach_msg_header_t {
  msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, MACH_MSG_TYPE_MAKE_SEND_ONCE),
  msgh_size = 164,
  msgh_remote_port = broker_port,
  msgh_local_port = reply_port,
  msgh_id = 400
}
NDR_record_t ndr
uint32_t name_len
char name[128]
```

**Reply (success):**
```c
mach_msg_header_t {
  msgh_bits = MACH_MSGH_BITS_COMPLEX | MACH_MSGH_BITS(MACH_MSG_TYPE_MOVE_SEND_ONCE, 0),
  msgh_size = 40,
  msgh_remote_port = reply_port,
  msgh_id = 500
}
mach_msg_body_t {
  msgh_descriptor_count = 1
}
mach_msg_port_descriptor_t {
  name = service_port,
  disposition = MACH_MSG_TYPE_MAKE_SEND,
  type = MACH_MSG_PORT_DESCRIPTOR
}
```

### bootstrap_look_up (402)

**Request:** Same as check_in but with msgh_id = 402

**Reply (success):** Same as check_in but with disposition = MACH_MSG_TYPE_COPY_SEND

**Reply (error):**
```c
mach_msg_header_t {
  msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_MOVE_SEND_ONCE, 0),
  msgh_size = 36,
  msgh_remote_port = reply_port,
  msgh_id = 502
}
NDR_record_t ndr
kern_return_t ret_code = 1102  // BOOTSTRAP_UNKNOWN_SERVICE
```

## Debugging Tips

### Check if broker is running
```bash
ps aux | grep rosettasim_broker
cat /tmp/rosettasim_broker.pid
```

### Monitor broker messages
```bash
# Run broker in foreground with logging
./src/bridge/rosettasim_broker 2>&1 | tee broker.log

# Watch for specific messages
grep "check_in\|look_up\|register" broker.log
```

### Verify port creation
```bash
# List Mach ports for broker process
lsmp -p $(cat /tmp/rosettasim_broker.pid)

# Look for the broker port in task special ports
lsmp -p $(cat /tmp/rosettasim_broker.pid) | grep "bootstrap"
```

### Debug message passing
```bash
# Use dtrace to monitor Mach messages (requires SIP disabled)
sudo dtrace -n 'mach_msg_trap:entry { printf("%s -> %d", execname, arg0); }'
```

### Common Issues

**Issue:** App can't find service
- **Check:** Is the service registered? Look for "registered service" in broker log
- **Fix:** Ensure backboardd/purple_fb_server calls check_in before app calls look_up

**Issue:** Broker exits immediately
- **Check:** Is backboardd path correct? Look for "backboardd not found"
- **Fix:** Verify --sdk path points to valid iOS SDK

**Issue:** No messages received
- **Check:** Is broker port set correctly? Look for "broker port created"
- **Fix:** Verify posix_spawnattr_setspecialport_np is called with correct port

**Issue:** Messages have wrong format
- **Check:** Message size and structure
- **Fix:** Use `#pragma pack(4)` and verify NDR record matches system definition

## Performance Considerations

- **Message latency:** Each bootstrap operation requires a round-trip to the broker
- **Registry size:** Limited to 64 services (configurable via MAX_SERVICES)
- **Memory usage:** ~4KB per message buffer, statically allocated
- **CPU usage:** Minimal - broker spends most time blocked in mach_msg

## Security Considerations

**WARNING:** The broker has NO authentication or access control. Any process with the broker port can:
- Register services with any name
- Look up any registered service
- Potentially interfere with other processes

This is acceptable for development/testing but **NOT for production use**.

For production, you would need:
- Service name validation (e.g., bundle ID prefixes)
- Client authentication (e.g., via audit tokens)
- Rate limiting on message processing
- Audit logging for security monitoring

## Future Enhancements

1. **App Spawning** - Implement BROKER_SPAWN_APP (msg_id 702) to launch apps on demand
2. **Service Lifecycle** - Track client ports and unregister services when clients exit
3. **Bootstrap Subsets** - Implement proper subset support for sandboxing
4. **Port Sets** - Use port sets to handle multiple service ports efficiently
5. **Persistence** - Optionally persist service registry across broker restarts
6. **IPC Debugging** - Add dtrace probes for message tracing

## References

- Session 6 Results: `docs/session-6-results.md`
- Broker Implementation: `src/bridge/rosettasim_broker.c`
- Broker Documentation: `src/bridge/README_BROKER.md`
- Test Program: `tests/broker_test.c`
- purple_fb_server.c: `src/bridge/purple_fb_server.c`

## Next Steps

To complete the integration:

1. Update purple_fb_server.c to use bootstrap_check_in instead of custom messages
2. Test broker + backboardd together
3. Update app launch code to spawn via broker
4. Verify CA client can connect to CARenderServer through broker
5. Document any issues found during integration
6. Update AGENTS.md with broker architecture details

## Conclusion

The broker provides a clean, production-ready foundation for Mach port sharing in RosettaSim. It follows standard bootstrap server patterns and should integrate cleanly with existing code.

The key insight is that by using `posix_spawnattr_setspecialport_np`, we can give each child process access to our broker as if it were the system bootstrap server. This allows unmodified iOS frameworks to work correctly, since they already know how to talk to bootstrap servers.
