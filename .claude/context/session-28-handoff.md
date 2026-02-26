# Session 28 Handoff

## Session 27 Summary

**26 commits**, massive session covering stability, performance, multi-version support.

### Architecture (Current State)

```
┌─────────────┐    PurpleFBServer    ┌──────────────────┐
│ backboardd  │◄────Mach msg────────►│ rosettasim_daemon │
│ (sim-side)  │    (map_surface,     │  (host-side)      │
│             │     flush_shmem)     │                    │
│ Renders to  │                      │ IOSurface A (write)│
│ IOSurface A │                      │ IOSurface B (read) │
└─────────────┘                      │ memcpy A→B on flush│
                                     └────────┬───────────┘
                                              │ IOSurfaceLookup(B)
                                     ┌────────▼───────────┐
                                     │ sim_display_inject  │
                                     │ (in Simulator.app)  │
                                     │                     │
                                     │ CADisplayLink vsync  │
                                     │ CGImage from IOSurf  │
                                     │ → CALayer.contents   │
                                     │ UDID window matching │
                                     └─────────────────────┘
```

### Commit Log (Session 27)

```
e7bac6b feat: generalized legacy simulator runtime installer
397f0f5 perf: memcpy timing instrumentation + remove mtime gate from IOSurface
fa5f4a9 feat: double-buffered IOSurface, headServices detection, dynamic alloc
15c838e feat: hybrid sync (mtime-gated IOSurface read) + iOS 12.4 detection
788ba3e fix: prevent same-model windows stealing layers from each other
060f591 fix: remove IOSurface seed check — backboardd writes via raw memory
6aba39e perf: zero-copy CGImage + seed-based change detection
4c73df5 feat: CGImage-from-IOSurface rendering (zero file I/O, no blanking)
2eaa4ca fix: kIOSurfaceIsGlobal enables cross-process IOSurface sharing
ea07c87 feat: IOSurface zero-copy display path
3f567cd feat: daemon exposes IOSurface ID in device JSON for zero-copy display
ac6341c fix: keyboard swizzle uses void* to prevent ARC retain of garbage ptr
c8ca408 fix: inode-based change detection fixes 1fps frame drops
8e41fcd docs: PurpleFBServer protocol + Display struct reference
97d5a8a fix: pixel stats logging window + E2E test openurl timeout
27073c6 perf: persistent fd + pread for framebuffer reads
67d8495 feat: E2E test script for all iOS simulator runtimes
9019a31 fix: quiet rescan logs, daemon resilience, watchdog timer
a1df8e9 feat: BSMainScreenScale interpose dylib + scale fix infrastructure
8d5fa1b fix: periodic device list reload rescans unmatched devices
b3bba3c feat: CADisplayLink vsync rendering + mtime change detection
8d78ad9 feat: UDID-based window matching with name fallback, rescan on new devices
dc244db fix: keyboard swizzle skips original (SIGSEGV), grep bug in start script
0587bcc fix: stable baseline — layer persistence, message drain, pt_width=pixel
1a1ad5f fix: swizzle timing, message drain loop, layer re-scan on detach
3c168a1 fix: keyboard crash swizzle, layer CFRetain lifecycle, pt_width/scale, daemon diagnostics
```

### Key Files

| File | Purpose |
|------|---------|
| `tools/display_bridge/rosettasim_daemon.m` | Multi-device PurpleFBServer daemon. Double-buffered IOSurface, dynamic alloc, headServices-based runtime detection, SIGTERM/SIGINT cleanup, watchdog. |
| `tools/display_bridge/sim_display_inject.m` | Injection dylib for Simulator.app. UDID-based window matching, CADisplayLink vsync, zero-copy CGImage from IOSurface, keyboard swizzle (void*). |
| `tools/display_bridge/sim_scale_fix.c` | x86_64 BSMainScreenScale interpose (built, NOT yet injected into backboardd). |
| `tools/display_bridge/Makefile` | 5 targets: bridge, inject, viewer, daemon, scale_fix. |
| `scripts/start_rosettasim.sh` | One-command launcher. |
| `scripts/test_all_devices.sh` | E2E test: boots devices, checks framebuffer. |
| `scripts/install_legacy_sim.sh` | Generalized runtime installer from Apple CDN. |
| `.claude/context/purplefb-protocol-reference.md` | Complete PurpleFBServer protocol + Display struct reference. |

### Installed Runtimes (10 major versions)

| iOS | Build | Identifier | Display Protocol | Bridge Status |
|-----|-------|-----------|-----------------|---------------|
| 9.3 | 13E233 | iOS-9-3 | PurpleFBServer | ✅ Working |
| 10.3 | 14E8301 | iOS-10-3 | PurpleFBServer | ✅ Working |
| 12.4 | 16G73 | iOS-12-4 | PurpleFB hybrid | ✅ Working (100% pixel coverage) |
| 13.7 | 17H22 | iOS-13-7 | SimFramebuffer | Boots, needs SimFB bridge |
| 14.5 | 18E182 | iOS-14-5 | SimFramebuffer | Boots, needs SimFB bridge |
| 15.7 | 19H12 | iOS-15-7 | Native | ✅ Works natively |
| 16.4 | 20E247 | iOS-16-4 | Native | ✅ Works natively |
| 17.4 | 21E213 | iOS-17-4 | Native | ✅ Works natively |
| 18.0 | 22A3351 | iOS-18-0 | Native | ✅ Works natively |
| 26.2 | 23C54 | iOS-26-2 | Native | ✅ Works natively |

**Missing**: iOS 7, 8, 11 (Apple download service was unavailable; retry with `xcodes download "7.3.1"` / `"10.1"` for Xcode DMG extraction)

### Session 28 Priorities

#### P1: 2x Rendering (insert_dylib approach)
- **Root cause**: BSMainScreenScale() returns ≤0 → scale=1.0 → broken display geometry
- **Fix**: Use `insert_dylib` to add `sim_scale_fix.dylib` to backboardd's Mach-O header
- **insert_dylib** is installed at `/usr/local/bin/insert_dylib`
- **Workflow** (from Agent C research):
  ```bash
  RTROOT=~/Library/Developer/.../iOS_9.3.simruntime/.../RuntimeRoot
  cp sim_scale_fix.dylib "$RTROOT/usr/lib/"
  cp "$RTROOT/usr/libexec/backboardd" "$RTROOT/usr/libexec/backboardd.orig"
  insert_dylib --inplace --strip-codesig --all-yes \
    /usr/lib/sim_scale_fix.dylib "$RTROOT/usr/libexec/backboardd"
  ```
- **After insert_dylib**: change daemon pt_width to `pixel_width / scale`
- **Expected result**: correct 2x layout, full-buffer rendering, wallpaper, rounded icons

#### P2: SimFramebuffer Bridge
- iOS 13.7 and 14.5 use SimFramebuffer protocol, not PurpleFBServer
- Struct definitions at `src/plugins/IndigoLegacyFramebufferServices/SimFramebufferProtocol.h`
- Would enable display for iOS 11-14 simulators

#### P3: Install iOS 8 and 11
- Retry `xcodes download "7.3.1"` (Xcode with iOS 8 sim)
- Retry `xcodes download "10.1"` (Xcode with iOS 11 sim)
- Extract simulator runtime from the Xcode .xip, patch, install

#### P4: Display Quality
- **Square icons on 9.3/10.3**: Caused by scale=1.0 — fixed by P1
- **No wallpaper on 9.3/10.3**: Procedural wallpaper fails at scale=1.0 — fixed by P1. Workaround: copied iOS 12.4 wallpaper images to 9.3 runtime.
- **Framerate**: Pipeline is fast (1ms memcpy + ~0ms CGImage wrap). Bottleneck is backboardd's flush rate (on-demand, idle when no UI changes — this is normal iOS behavior).

### Agent Findings (Session 27)

| # | Agent | Finding |
|---|-------|---------|
| 30 | A | Display struct layout: set_size stores point dims, render transform maps points→pixels (PARTIALLY WRONG — see 32) |
| 31 | A | NSWindow→UDID path: windowController.device.UDID |
| 32 | A | Root cause: update_actual_bounds copies logical_bounds to clip rect. Display::set_scale(2.0) needed. |
| 33 | A | BSMainScreenScale returns ≤0 → scale=1 fallback. Interpose BSMainScreenScale to return 2.0. |
| 34 | A | launchd_sim blocks DYLD_ env vars. Three alternatives: patch constant, insert_dylib, plist wrapper. |
| 35 | A | iOS 12.4 DOES use PurpleFBServer (confirmed by binary analysis). Missing headServices key was the issue. |
| 36 | A | No wallpaper images in iOS 9.3 — uses procedural wallpaper that fails at scale=1.0. |

### What's Working Well
- Multi-device simultaneous display in Simulator.app
- UDID-based window matching (no name collisions)
- Double-buffered IOSurface (no tearing)
- CADisplayLink vsync-aligned rendering
- Zero file I/O display pipeline
- Daemon resilience (SIGTERM, watchdog, dynamic alloc)
- 10 iOS versions installed (9.3 through 26.2)
- iOS 12.4 at 100% pixel coverage

### Known Issues
- Square icons on iOS 9.3/10.3 (scale=1.0, needs insert_dylib fix)
- No wallpaper on iOS 9.3/10.3 (same root cause)
- iOS 13.7/14.5 boot but no display (SimFramebuffer bridge needed)
- `start_rosettasim.sh` grep patterns only match 9.3/10.3 — needs updating for 12.4
- Occasional flicker at very high activity (double-buffer helps but memcpy is synchronous)
