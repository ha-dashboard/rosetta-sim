# Session 27 Handoff — Multi-Device Daemon Working, pt_width Unsolved

## Date: 2026-02-26 (end of Session 26)

## What Works RIGHT NOW

**Multi-device daemon (`rosettasim_daemon`):**
- Pre-registers PurpleFBServer for ALL legacy devices at startup
- Auto-detects boot/shutdown via CoreSimulator notification API
- Handles multiple devices simultaneously (iPad Air + iPad Pro + iPhone 6s tested)
- Per-device framebuffer files at `/tmp/rosettasim_fb_<UDID>.raw`
- Active devices JSON at `/tmp/rosettasim_active_devices.json`

**One-command launcher:**
```bash
./scripts/start_rosettasim.sh    # daemon + Simulator.app
./scripts/start_rosettasim.sh --stop   # clean shutdown
```

**Display in Simulator.app:**
- Multi-device injection dylib matches windows by device name
- Dynamic allocation (no device limit)
- Layer re-scan every 5s if connection lost
- Backwards-compatible with single-device standalone bridge

**Device support (iOS 9.3):**
- iPhone 6s, 6s Plus, SE (1st gen) — in modern Xcode
- iPhone 5s, 6, 6 Plus, iPad Air — copied from Xcode 8.3.3
- iPad Air 2, iPad Pro 12.9" (1st gen), iPad Pro 9.7" — in modern Xcode
- All verified working with dynamic dimensions from SimDeviceType API

**iOS 10.3** — runtime exists but boot crashed when daemon had nil deviceType. Now fixed with validation. Needs re-test.

## What DOESN'T Work Yet

### Priority 1: pt_width/pt_height — Incorrect UIKit Layout on iPads
**The central unresolved issue.** Two modes tested:
- `pt_width = pixel_width` → Full buffer rendering, but UIKit at 1x (icons too small on iPads, no wallpaper)
- `pt_width = pixel_width / scale` → Correct UIKit layout (2x), but QUARTER-SIZE rendering (only top-left 1/4 of buffer used)

**Agent A's RE analysis (Finding 29):**
- `PurpleDisplay::map_surface` computes `scale = pixel_w / pt_w`
- `Display::set_size({pt_w, pt_h}, {pt_w, pt_h})` — this likely sets BOTH the UIKit point dimensions AND the rendering viewport
- The quarter-size bug happens because `set_size(768, 1024)` limits the renderer to 768x1024 pixels of the 1536x2048 buffer

**Possible solutions to investigate in Session 27:**
1. **Allocate smaller IOSurface at point dimensions** — Create 768x1024 IOSurface, set pt_width=768. UIKit renders at 2x in a 768x1024 buffer. Host displays at 768x1024 points with contentsScale=2.0. But backboardd might reject a buffer smaller than pixel dimensions.
2. **Patch Display::set_size separately** — If we can call set_size with pixel dims but set the scale transform to 2.0 through another path, UIKit would layout correctly while the renderer uses the full buffer.
3. **Set contentsScale=1.0 on host + pt_width=pixel_width** — Current behavior. The image fills the window but UIKit lays out at 1x. Could we scale the CGImage on the host to compensate?
4. **Investigate what real PurpleFBServer sends** — On a real Mac with an iOS 9.3 SDK, what pt_width/pt_height does Apple's own PurpleFBServer use? This would definitively answer the question.

### Priority 2: iOS 10.3 Boot Crash
- The daemon crashed when trying to register PurpleFBServer for a device with nil deviceType
- Now fixed with validation (`is_legacy_runtime` checks deviceType exists)
- Needs re-testing to confirm iOS 10.3 boots and renders correctly

### Priority 3: Layer Pointer Invalidation
- The injection dylib's CALayer pointer gets released after ~10s
- Workaround: re-scan windows every 5s when active count drops to 0
- Proper fix: use `__strong` reference or observe window lifecycle

## Session 26 Commits (14 total)

| Commit | Description |
|--------|-------------|
| `b8ec3df` | Re-add deviceType null check without pt_width change |
| `7fbcbe5` | Revert pt_width change (caused quarter rendering) |
| `40b99fa` | Null-safety + pt_width fix (reverted) |
| `05b2763` | Remove MAX_DEVICES limit, dynamic allocation |
| `db97be6` | Layer re-scan + boot device before Simulator |
| `f2027ac` | One-command launcher (start_rosettasim.sh) |
| `d18387a` | Bridge daemon + multi-device display + JSON compat |
| `ae199da` | Multi-device injection dylib |
| `2382756` | Docs: dynamic dims, multi-device, reproducibility |
| `18936f3` | Dynamic dimensions from SimDeviceType + SDK stub |
| `6c8602e` | Build infrastructure: Makefile, setup.sh, run script |
| `b9eb5e5` | Gotchas section in handoff doc |
| `47bf263` | Session 26 handoff + archive old broker |

## Key Files (CURRENT)

| File | Purpose |
|------|---------|
| `tools/display_bridge/rosettasim_daemon.m` | Multi-device daemon with pre-registration |
| `tools/display_bridge/purple_fb_bridge.m` | Standalone single-device bridge |
| `tools/display_bridge/sim_display_inject.m` | Multi-device injection dylib |
| `tools/display_bridge/sim_viewer.m` | Standalone framebuffer viewer |
| `tools/display_bridge/Makefile` | 4 targets: bridge, inject, viewer, daemon |
| `scripts/start_rosettasim.sh` | One-command daemon + Simulator launcher |
| `scripts/run_legacy_sim.sh` | Single-device CLI workflow |
| `scripts/setup.sh` | First-time setup (build, re-sign, devices) |
| `install_sim93.sh` | iOS 9.3 runtime downloader + installer |

## Architecture

```
rosettasim_daemon (launchd agent)
  startup:
    foreach legacy device with valid deviceType:
      create IOSurface (dimensions from SimDeviceType.mainScreenSize)
      create memory_entry
      registerPort:@"PurpleFBServer"
      start dispatch_source_mach_recv

  on boot:
    backboardd connects → msg_id=4 → reply with dims
    backboardd renders → msg_id=3 → reply + write per-device fb file
    write active_devices.json

  on shutdown:
    deactivate → cleanup → re-register for next boot

sim_display_inject.dylib (DYLD_INSERT into Simulator.app)
  startup:
    read /tmp/rosettasim_active_devices.json (or single-device fallback)
    dynamically allocate DeviceDisplay array

  attempt_injection:
    find SimDisplayRenderableView in each window
    match window title to device name
    set surfaceLayer.contents = CGImage from fb file
    30fps refresh timer
    re-scan if all devices lost
```

## Reproducibility (for new users)

```bash
# 1. Install modern Xcode (26.x)
# 2. Download iOS 9.3 runtime
./install_sim93.sh

# 3. Create SDK stub (requires sudo — setup.sh prints the command)
# 4. One-time setup
./scripts/setup.sh

# 5. Run
./scripts/start_rosettasim.sh
# Select devices from Simulator menu → display appears automatically
```

## CDN URLs for Legacy Runtimes (from Agent C)

| Runtime | Available | URL Fragment |
|---------|-----------|-------------|
| iOS 9.3 | ✅ | `com.apple.pkg.iPhoneSimulatorSDK9_3-9.3.1.1460411551.dmg` |
| iOS 10.0 | ✅ | `com.apple.pkg.iPhoneSimulatorSDK10_0-10.0.1.1474488730.dmg` |
| iOS 10.1 | ✅ | `com.apple.pkg.iPhoneSimulatorSDK10_1-10.1.1.1476902849.dmg` |
| iOS 10.2 | ✅ | `com.apple.pkg.iPhoneSimulatorSDK10_2-10.2.1.1484185528.dmg` |
| iOS 10.3 | ❌ 403 | Blocked |
| iOS 11.x | ❌ 403 | Blocked |
| iOS 12.4 | ✅ | `com.apple.pkg.iPhoneSimulatorSDK12_4-12.4.1.1568665771.dmg` |

Base: `https://devimages-cdn.apple.com/downloads/xcode/simulators/`

## PurpleFB pt_width Gotcha (CORRECTED from Session 25)

Session 25 gotcha #6 said "pt_width must equal pixel dimensions." This is a **workaround**, not the correct behavior. The actual semantics:

- `pt_width/pt_height` control BOTH UIKit's point coordinate system AND the rendering viewport size
- Setting `pt_width = pixel_width` makes UIKit lay out at 1x (wrong for @2x devices) but fills the buffer
- Setting `pt_width = pixel_width / scale` makes UIKit lay out correctly at @2x but the renderer only uses 1/4 of the buffer
- The correct fix requires decoupling these two effects — either via a different API call or by matching the buffer size to the point dimensions

## Agent Sessions
- Agent A: `cmm2kr8hg5x20nq32pt5ca76g` — RE specialist (pt_width analysis, crash investigation)
- Agent B: `cmm2kyo475x3anq32ul3awimd` — Execution (all implementation)
- Agent C: `cmm3jdwnz00h1nh343wc8wxtw` — Research (CDN URLs, device profiles, reproducibility)
- Agent D: `cmm3jdykd02c3ma37ogdkilav` — Testing (daemon E2E, multi-device, pt_width validation)

## Simulator.app Crash: setHardwareKeyboardEnabled on Legacy Devices

**Exception**: `-[__NSArrayM userInfo]: unrecognized selector sent to instance`
**Location**: `[SimDevice _sendBridgeRequest:] → setHardwareKeyboardEnabled:keyboardType:error:`
**Thread**: Background dispatch queue (not our code)

CoreSimulator's bridge request to legacy iOS 9.3 devices returns an NSArray where modern CoreSimulator expects an NSDictionary (with `userInfo` method). This crashes when Simulator.app configures keyboard settings for legacy devices.

**Our code is not involved** — thread 0 shows the injection dylib rendering normally (refresh_device → CA::Transaction::commit). The crash is purely in Simulator.app's keyboard configuration path.

**Session 27 fixes**:
1. Swizzle `[SimDevice setHardwareKeyboardEnabled:keyboardType:error:]` in injection dylib — wrap in try/catch
2. Or prevent Simulator.app from calling it on legacy devices
