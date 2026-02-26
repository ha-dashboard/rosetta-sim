# Session 26 Handoff — From Prototype to Product

## Date: 2026-02-26 (end of Session 25)

## What Works RIGHT NOW

**iOS 9.3 iPhone 6s simulator running on Apple Silicon (macOS 26) inside Simulator.app:**
- Full SpringBoard home screen: status bar, 7 app icons, dock with Safari
- Touch input: tap icons to open apps (Settings, Health confirmed)
- Apps render correctly: Settings shows full menu list at @2x resolution
- 30fps display refresh via CGImage on Simulator.app's surfaceLayer
- CARenderServer GPU compositing (no CPU renderInContext fallback)
- 55+ system processes (launchd_sim, backboardd, SpringBoard, assertiond, etc.)
- IndigoHID for touch, keyboard, hardware buttons (all connected)

**iOS 10.3 also verified** (same bridge, different UDID) — 60fps, 50%+ pixel coverage.

## Architecture (2 custom tools + Apple's infrastructure)

```
┌─────────────────────────────────────────────────────┐
│ HOST (macOS, arm64)                                  │
│                                                      │
│  purple_fb_bridge <UDID>                             │
│    → [SimDevice registerPort:@"PurpleFBServer"]      │
│    → Handles msg_id=4: replies with IOSurface dims   │
│    → Handles msg_id=3: replies to flush, writes raw  │
│    → Writes /tmp/sim_framebuffer.raw on each flush   │
│                                                      │
│  Re-signed Simulator.app (library-validation removed)│
│    + DYLD_INSERT sim_display_inject.dylib            │
│    → Finds SimDisplayRenderableView.surfaceLayer     │
│    → Reads /tmp/sim_framebuffer.raw at 30fps         │
│    → Creates CGImage, sets on surfaceLayer            │
│                                                      │
├─────────────────────────────────────────────────────┤
│ SIM (x86_64 under Rosetta 2)                         │
│                                                      │
│  launchd_sim (from runtime)                          │
│    → 55+ processes: backboardd, SpringBoard, etc.    │
│                                                      │
│  backboardd → PurpleFBServer (our bridge)            │
│    → CARenderServer composites to shared framebuffer │
│    → Sends msg_id=3 (flush) on each frame            │
│                                                      │
│  IndigoHIDRegistrationPort → touch/keyboard/buttons  │
│    → Already wired by IndigoLegacyHIDServices plugin │
└─────────────────────────────────────────────────────┘
```

## What DOESN'T Work Yet

1. **iPad Pro (iOS 9.3) shows black** — dimensions are hardcoded for iPhone 6s (750x1334). iPad needs different dimensions.
2. **Can't launch from Simulator menu** — must use CLI sequence (bridge → boot → inject)
3. **Only works with re-signed Simulator** — Apple's original blocks DYLD_INSERT
4. **Bridge must start BEFORE boot** — if booted without bridge, backboardd hangs on PurpleFBServer lookup
5. **Single device at a time** — bridge is hardcoded to one UDID
6. **No app installation tested** — simctl install should work but untested
7. **Display refresh via file I/O** — not optimal (should use IOSurface sharing)

## Session 26 Goals

### Priority 1: Multi-device support (iPad Pro, iPhone 5s, etc.)
- The PurpleFB reply hardcodes 750x1334 for iPhone 6s
- Need to read device type from SimDevice and set dimensions dynamically
- iPad Pro: 2048x2732 @2x, iPhone 5s: 640x1136 @2x, etc.
- The device type profiles are at: `~/Library/Developer/CoreSimulator/Profiles/DeviceTypes/`

### Priority 2: One-click launch from Simulator menu
- When user selects a device in Simulator.app → it calls simctl boot
- Our bridge must detect the boot and register PurpleFBServer automatically
- Options:
  a. File system watcher on the device data directory
  b. CoreSimulator notification listener
  c. Override the boot sequence to start bridge first

### Priority 3: Reproducible for other users
- Document: what Xcode/runtime versions are needed
- Package: bridge binary + injection dylib + re-sign script + launch script
- One-time setup: re-sign Simulator.app, build tools
- Test on a clean machine if possible

## Key Files (CURRENT, in use)

| File | Purpose |
|------|---------|
| `tools/display_bridge/purple_fb_bridge.m` | PurpleFB bridge tool (IOSurface-backed) |
| `tools/display_bridge/sim_display_inject.m` | Injection dylib for Simulator.app |
| `tools/display_bridge/sim_viewer.m` | Standalone framebuffer viewer |
| `tools/display_bridge/Makefile` | Build system |
| `tools/display_bridge/README.md` | Documentation |
| `scripts/run_legacy_sim.sh` | Automation script |

## Files to ARCHIVE (from old broker approach, sessions 22-24)

| File | Reason |
|------|--------|
| `src/bridge/rosettasim_broker.c` | Old custom broker — replaced by native simctl boot |
| `src/bridge/rosettasim_bridge.m` | Old app-side bridge — not needed with native sim |
| `src/bridge/purple_fb_server.c` | Old PurpleFBServer injected into backboardd — replaced by standalone bridge |
| `src/launcher/bootstrap_fix.c` | Old bootstrap interpositions — not needed |
| `src/bridge/springboard_shim.c` | Old SpringBoard stubs — not needed |
| `src/host/RosettaSimApp/` | Old host display app — replaced by Simulator.app injection |
| `src/shared/` | Old shared headers — not needed |

## PurpleFB Protocol (complete, for reference)

### Service: `PurpleFBServer` (registered with sim's launchd_sim)

### msg_id=4 (map_surface) — Request from backboardd
- 72 bytes, mostly zeros
- backboardd sends this once at startup

### msg_id=4 — Reply (our bridge sends)
```
+0x00: mach_msg_header_t (COMPLEX, MOVE_SEND_ONCE reply)
+0x18: mach_msg_body_t (1 descriptor)
+0x1c: mach_msg_port_descriptor_t (memory_entry port, COPY_SEND)
+0x28: size (uint32_t) — total bytes (e.g., 4002000 = 1334*3000)
+0x2c: stride (uint32_t) — bytes per row (e.g., 3000 = 750*4)
+0x30: padding (8 bytes)
+0x38: width (uint32_t) — PIXEL width (e.g., 750)
+0x3c: height (uint32_t) — PIXEL height (e.g., 1334)
+0x40: pt_width (uint32_t) — display width (e.g., 750 for full-size rendering)
+0x44: pt_height (uint32_t) — display height (e.g., 1334 for full-size rendering)
```

### msg_id=3 (flush_shmem) — From backboardd
- 72 bytes with dirty rect at +0x28
- msgh_local_port = reply port (MUST reply or backboardd blocks forever)
- Reply: bare mach_msg_header_t (24 bytes, MOVE_SEND_ONCE)

### msg_id=1011 (display state notification)
- Fire-and-forget, no reply needed

## Device Dimensions (for multi-device support)

| Device | Pixels | Points | Scale | Stride |
|--------|--------|--------|-------|--------|
| iPhone 5s | 640x1136 | 320x568 | 2x | 2560 |
| iPhone 6 | 750x1334 | 375x667 | 2x | 3000 |
| iPhone 6 Plus | 1242x2208 | 414x736 | 3x | 4968 |
| iPhone 6s | 750x1334 | 375x667 | 2x | 3000 |
| iPad 2 | 768x1024 | 768x1024 | 1x | 3072 |
| iPad Air | 1536x2048 | 768x1024 | 2x | 6144 |
| iPad Air 2 | 1536x2048 | 768x1024 | 2x | 6144 |
| iPad Pro (12.9) | 2048x2732 | 1024x1366 | 2x | 8192 |
| iPad Pro (9.7) | 1536x2048 | 768x1024 | 2x | 6144 |

## Gotchas (from Session 25 debugging)

1. **`cc` alias**: The shell has `cc` aliased to an interactive process that hangs. Always use `/usr/bin/cc` for compilation.
2. **IOSurfaceLookup fails cross-process**: Cannot share IOSurface by ID between bridge and viewer. Use file-based transfer (`/tmp/sim_framebuffer.raw`) instead.
3. **IOSurface as CALayer.contents shows black**: Setting an IOSurface directly on `layer.contents` doesn't render. Must convert to CGImage via `CGBitmapContextCreate` + `CGBitmapContextCreateImage`.
4. **Re-signed Simulator crashes without booted sim**: The XPC bridge to CoreSimulatorService fails on `setHardwareKeyboardEnabled:` if no device is booted. Always boot the sim BEFORE launching the re-signed Simulator.
5. **Bridge must write every flush**: The viewer reads `/tmp/sim_framebuffer.raw` at 30fps. Bridge uses atomic rename (`write to .tmp`, then `rename`) to avoid partial reads.
6. **pt_width/pt_height must equal pixel dimensions**: Setting pt_width=375 (points) causes compositor to render at 1/4 size. Set pt_width=750 (same as pixels) for full-screen rendering.
7. **DYLD_INSERT silently ignored on Apple-signed binaries**: Must re-sign with `codesign --force --sign - --options=0` to remove library-validation.
8. **lldb attach blocked even with DevToolsSecurity**: The `lldb -p` approach failed from our CLI session. The DYLD_INSERT approach on re-signed binary is the working path.

## How to Run (current state)

```bash
# 1. Build tools
cd tools/display_bridge
make clean && make

# 2. Create re-signed Simulator
mkdir -p /tmp/Simulator_nolv.app/Contents/MacOS
cp /Applications/Xcode.app/Contents/Developer/Applications/Simulator.app/Contents/MacOS/Simulator /tmp/Simulator_nolv.app/Contents/MacOS/
cp /Applications/Xcode.app/Contents/Developer/Applications/Simulator.app/Contents/Info.plist /tmp/Simulator_nolv.app/Contents/
codesign --force --sign - --options=0 /tmp/Simulator_nolv.app/Contents/MacOS/Simulator

# 3. Start bridge (registers PurpleFBServer)
./purple_fb_bridge 647B6002-AD33-46AE-A78B-A7DAE3128A69 &

# 4. Boot sim
xcrun simctl boot 647B6002-AD33-46AE-A78B-A7DAE3128A69

# 5. Wait for rendering
sleep 10

# 6. Launch re-signed Simulator with injection
DYLD_FRAMEWORK_PATH=/Applications/Xcode.app/Contents/Developer/Library/PrivateFrameworks:/Library/Developer/PrivateFrameworks \
DYLD_INSERT_LIBRARIES=$(pwd)/sim_display_inject.dylib \
/tmp/Simulator_nolv.app/Contents/MacOS/Simulator
```

## RE Notes for Future Work (Agent A additions)

### PurpleFB pt_width/pt_height semantics
The reply fields at +0x40/+0x44 are **point dimensions**, not "display dimensions." PurpleDisplay::map_surface (QC9+0xf1a4a) computes a scale transform: `Transform::scale(pixel_w/point_w, pixel_h/point_h, 1.0)` stored at display+0x138. If pt_width equals pixel_width, scale=1.0 and UIKit lays out at 1x → 1/4 area bug. For @2x devices, pt_width = pixel_width/2.

### IOS_FRAMEBUFFER_PREFIX env var
PurpleDisplay::open (QC9+0xf189e) checks for `IOS_FRAMEBUFFER_PREFIX` env var and prepends it to the `"PurpleFBServer"` service name. This could be used for multi-device support — each device gets a unique service name without changing the bridge protocol.

### flush_shmem blocks with infinite timeout
PurpleDisplay::finish_update calls flush_shmem with wait_for_reply=TRUE. The send_msg function (QC9+0xf1e9e) does `mach_msg(SEND|RCV, timeout=0)` — infinite wait. If the bridge doesn't reply to every msg_id=3, backboardd hangs permanently after the first render. The reply body is ignored — just needs any mach_msg_header_t delivered to the reply port.

### ROCKit architecture (for eliminating file I/O)
The file I/O path (/tmp/sim_framebuffer.raw) could be replaced by pushing IOSurface directly through Simulator.app's display pipeline. ROCKit (the framework underlying CoreSimDeviceIO) is a transparent ObjC RPC system — you can't fake it with raw XPC messages. Two viable paths:
- **DYLIB inject upgrade**: instead of reading from file, share IOSurface from bridge via `IOSurfaceCreateMachPort()` and set `surfaceLayer.contents = IOSurface` directly.
- **simdeviceio plugin**: write a `.simdeviceio` bundle implementing `SimDeviceIOBundleInterface`. Entry point: `simdeviceio_get_interface()`. This gives legitimate ROCKit session access and the `didChangeIOSurface:` callback path.

### Touch is free — no extra work needed
SimDisplayView.connect(screen:inputs:.all) sets up SimDigitizerInputView overlay + SimDeviceLegacyHIDClient. Mouse clicks → IndigoHIDMessageForMouseNSEvent → IndigoHIDMessageStruct (160 bytes) → ROCKit → IndigoLegacyHIDServices plugin → mach_msg to IndigoHIDRegistrationPort. Keyboard and hardware buttons use the same path. All already wired for iOS 9.3 via profile.plist headServices.

### iPhone 6 Plus is @3x
The device dimensions table is correct but note: iPhone 6 Plus uses @3x rendering at 1242x2208 pixels downsampled to 1080x1920 physical. The PurpleFB reply should use 1242x2208 pixels with pt_width=414, pt_height=736. Downsampling is handled by the host display, not the compositor.

### Key QuartzCore offsets (iOS 9.3 runtime)
| Function | Offset |
|----------|--------|
| PurpleDisplay::open | +0xf189e |
| PurpleDisplay::map_surface | +0xf1a4a |
| PurpleDisplay::flush_shmem | +0xf20a2 |
| PurpleDisplay::finish_update | +0xf2124 |
| PurpleDisplay::send_msg | +0xf1e9e |
| TimerDisplayLink::update_timer | +0x142dc0 |

## Agent Sessions (for continuity)
- Agent A: `cmm2kr8hg5x20nq32pt5ca76g` — RE specialist
- Agent B: `cmm2kyo475x3anq32ul3awimd` — Execution agent
- Agent C: `cmm3jdwnz00h1nh343wc8wxtw` — Research agent
- Agent D: `cmm3jdykd02c3ma37ogdkilav` — RE + iOS 10.3 specialist

## Commits (Session 25)
- `215abe7`: PurpleFB bridge — first real pixels
- `eaaf7e0`: Continuous rendering with flush replies
- `d77b09f`: SpringBoard milestone + IO integration
- `e16525d`: IOSurface + SFB protocol exploration
- `6621bab`: Phase 2 display bridge — injection into Simulator.app
- `fedc11f`: Interactive iOS 9.3 with touch
- `98780da`: Retina contentsScale fix
- `3173489`: Full SpringBoard rendering (pt_width fix)

## RE Findings (from Agent D, for future reference)

### SimFramebuffer Protocol (iOS 11+, NOT used by 9.3/10.3)
The modern SimFramebuffer protocol was fully mapped from type encodings in the sim-side
`SimFramebuffer.framework`. Uses a tagged-union message format (`SimFramebufferMessageData`
with magic + struct_type + union of 18 payload types). Complete struct definitions at
`src/plugins/IndigoLegacyFramebufferServices/SimFramebufferProtocol.h`.
Service name: `com.apple.CoreSimulator.SimFramebufferServer`.

**If iOS 11+ support is needed, this is the protocol to implement** — completely different
from PurpleFBServer. Uses IOSurface ports (not memory entries), has swapchain/present
callbacks, display modes, and a richer display model.

### SimulatorKit Display Pipeline (Swift-only barrier)
SimulatorKit display APIs are **100% Swift vtable dispatch** — not ObjC-callable:
- `SimDevice.screenAdapter` → Swift extension, no ObjC selector
- `SimDeviceScreen.unmaskedSurface/maskedSurface` → Swift-only getters
- `SimDeviceScreenAdapter.register()` → Swift-only
- ObjC runtime only sees: `initWithDevice:screenID:`, `screenID`, `isDefault`, `isCarPlay`
- A **Swift bridge tool** is required to use native display pipeline

### CoreSimulator Plugin API (.simdeviceio)
Every plugin exports: `BOOL simdeviceio_get_interface(id *outInterface)`.
Mach-O bundle type. Protocol: `createDefaultPortsForDevice:error:` returns descriptors,
`machServicesToRegister` → `[String: SimMachPort]` for Mach service registration.
Full analysis at `src/plugins/IndigoLegacyFramebufferServices/`.

### pt_width/pt_height Semantics
PurpleFB reply +0x40/+0x44: QuartzCore's PurpleDisplay coordinate system.
Setting pt_width=pt_height=pixel dims (750x1334) → 1:1 pixel mapping.
Then `contentsScale=2.0` on the Mac CALayer → correct Retina display.

### IOPort Enumeration for Old Runtimes (Agent C)
`xcrun simctl io 647B6002 enumerate` shows iOS 9.3 has full IO port infrastructure:
- DisplayAdapter (`com.apple.framebuffer.server`) with LCD 750x1334 + TVOut + CarPlay already connected
- 2× Display ports (class 0 and class 1)
- LegacyHID, 3× StreamProcessors (SW/Metal/OpenGL), CaptureService, GPUTools
The ports are identical in structure to iOS 26.2's — CoreSimulator sets them up, just doesn't spawn SimRenderServer.

### Re-signing Gotchas (Agent C)
- **Private entitlements + ad-hoc signing = AMFI kill (signal 9)**. The `com.apple.private.CoreSimulator.client` entitlement cannot be used.
- **No entitlements needed** — the re-signed Simulator connects to CoreSimulatorService anyway and creates DeviceWindows for all booted devices.
- The binary needs `DYLD_FRAMEWORK_PATH` for both `/Applications/Xcode.app/.../PrivateFrameworks` and `/Library/Developer/PrivateFrameworks`.
- Must kill the real Simulator first — only one instance can run (checks at launch).
- Both DYLD_INSERT (at launch) and lldb dlopen (post-launch) work for injection.

### IOSurface Direct Path (Agent C — for eliminating file I/O)
Instead of `/tmp/sim_framebuffer.raw`, the bridge could share its IOSurface directly:
1. Bridge creates IOSurface (already does: `g_iosurface`)
2. `IOSurfaceCreateMachPort(g_iosurface)` → mach port
3. Write mach port to a known location (e.g., file with IOSurfaceID)
4. Inject dylib does `IOSurfaceLookup(surfaceID)` → gets the same IOSurface
5. Set `surfaceLayer.contents = (__bridge id)iosurface` directly
This eliminates the 4MB/frame file copy and gives zero-copy display.

### iOS Runtime Version Detection
- iOS 9.3 & 10.3: PurpleFBServer (confirmed via QuartzCore strings)
- iOS 10.3 SDK has NO SimFramebuffer.framework
- iOS 11+: SimFramebuffer replaces PurpleFB
- `headServices` in profile.plist lists `PurpleFBServer` for legacy runtimes
