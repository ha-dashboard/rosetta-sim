# Display Bridge — Legacy iOS Simulator Framebuffer

Tools for providing framebuffer display services to legacy iOS simulators (9.3, 10.3) that use the PurpleFBServer protocol.

## Architecture

```
backboardd (in sim)              purple_fb_bridge (host)
    │                                   │
    │  bootstrap_look_up                │
    │  ("PurpleFBServer")               │
    ├──────────────────────────────────►│
    │                                   │ dispatch_source_mach_recv
    │  msg_id=4 (map_surface)           │
    ├──────────────────────────────────►│
    │                                   │ allocate IOSurface + memory_entry
    │  reply: dimensions + mem_entry    │
    │◄──────────────────────────────────┤
    │                                   │
    │  msg_id=3 (flush_shmem)           │ (each frame)
    ├──────────────────────────────────►│
    │  reply (ack)                      │ dump to /tmp/sim_framebuffer.raw
    │◄──────────────────────────────────┤
```

## Files

| File | Description |
|------|-------------|
| `purple_fb_bridge.m` | PurpleFB bridge tool. Registers PurpleFBServer Mach service, handles map_surface and flush_shmem messages. Creates IOSurface backed framebuffer. |
| `sim_display_inject.m` | Dylib injected into Simulator.app via lldb. Picks up the IOSurface from the bridge and displays it in Simulator.app's window. |
| `rockit_bridge.m` | Phase 2 prototype exploring the ROCKit/SimulatorKit display path. Found that SimulatorKit APIs are Swift-only (not ObjC-accessible). |

## Quick Start

```bash
# One command:
./scripts/run_legacy_sim.sh

# Or with a specific device:
./scripts/run_legacy_sim.sh 03291AC5-5138-4486-A818-F86197A9BFAB

# Or iOS 10.3:
./scripts/run_legacy_sim.sh --ios10
```

## Manual Steps

### 1. Build

```bash
cd tools/display_bridge

# PurpleFB bridge
clang -fobjc-arc -fmodules -arch arm64e \
    -framework Foundation -framework IOSurface \
    -Wl,-undefined,dynamic_lookup \
    -o purple_fb_bridge purple_fb_bridge.m

# Display injection dylib
clang -dynamiclib -fobjc-arc -fmodules -arch arm64e \
    -framework Foundation -framework IOSurface -framework AppKit \
    -Wl,-undefined,dynamic_lookup \
    -o sim_display_inject.dylib sim_display_inject.m
```

### 2. Run

```bash
# Terminal 1: Start bridge (registers PurpleFBServer for the device)
./purple_fb_bridge 647B6002-AD33-46AE-A78B-A7DAE3128A69

# Terminal 2: Boot the simulator
xcrun simctl boot 647B6002-AD33-46AE-A78B-A7DAE3128A69

# Wait for "map_surface reply sent" in Terminal 1
# Then "flush #1" messages confirm rendering is active
```

### 3. View Framebuffer

```bash
# Raw dump (updated on each flush)
ls -la /tmp/sim_framebuffer.raw

# View with Swift viewer
swift tools/view_raw_framebuffer.swift

# Or inject into Simulator.app
open -a Simulator
lldb -p $(pgrep -x Simulator) \
    -o "expr (void*)dlopen(\"$(pwd)/sim_display_inject.dylib\", 2)" \
    -o "detach" -o "quit"
```

## Supported Runtimes

| Runtime | Protocol | Status |
|---------|----------|--------|
| iOS 9.3 | PurpleFBServer | Working |
| iOS 10.3 | PurpleFBServer | Working |
| iOS 11+ | SimFramebuffer | Not supported (different protocol) |

## PurpleFBServer Protocol

Messages are 72-byte Mach messages:

- **msg_id=4** (map_surface): Client requests framebuffer info. Reply contains memory_entry port descriptor + dimensions (width, height, stride, point size).
- **msg_id=3** (flush_shmem): Client notifies a frame was rendered. Reply is a simple ack.
- **msg_id=1011** (display state): Display power/state change notification.

Reply format (72 bytes):
```
+0x00  mach_msg_header_t (24 bytes)
+0x18  mach_msg_body_t { descriptor_count=1 } (4 bytes)
+0x1c  mach_msg_port_descriptor_t { memory_entry } (12 bytes)
+0x28  memory_size (uint32)
+0x2c  stride (uint32) — bytes per row
+0x30  pad1 (uint32)
+0x34  pad2 (uint32)
+0x38  pixel_width (uint32)
+0x3c  pixel_height (uint32)
+0x40  point_width (uint32)
+0x44  point_height (uint32)
```

## Device UUIDs

Create devices if they don't exist:
```bash
# iOS 9.3
xcrun simctl create "iPhone 6s (iOS 9.3)" com.apple.CoreSimulator.SimDeviceType.iPhone-6s com.apple.CoreSimulator.SimRuntime.iOS-9-3

# iOS 10.3
xcrun simctl create "iPhone 6s (10.3)" com.apple.CoreSimulator.SimDeviceType.iPhone-6s com.apple.CoreSimulator.SimRuntime.iOS-10-3
```
