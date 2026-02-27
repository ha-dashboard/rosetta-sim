# Session 29 Handoff

## Session 28 Summary

**3 commits**, focused on 2x scale fix investigation (all approaches failed) and deep protocol research.

### Commit Log (Session 28)

```
7df5543 revert: restore pt_width=pixel_width — BSMainScreenScale patch has no visual effect
bef851c feat: 2x scale fix via BaseBoard binary patch + daemon pt_width/2
031d00d docs: session 28 handoff — 26 commits, 10 iOS runtimes, zero-copy IOSurface
```

### Architecture (Unchanged from Session 27)

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

### Key Files (Updated)

| File | Purpose |
|------|---------|
| `tools/display_bridge/rosettasim_daemon.m` | Multi-device PurpleFBServer daemon. Now stores runtime_root per device. |
| `tools/display_bridge/sim_display_inject.m` | Injection dylib for Simulator.app. Unchanged. |
| `tools/display_bridge/sim_scale_fix.m` | Constructor + interpose scale fix (replaces .c). Built but NOT deployed — all approaches failed. |
| `tools/display_bridge/Makefile` | scale_fix now uses iOS sim target flags. |
| `scripts/start_rosettasim.sh` | grep patterns now include iOS 12.4. |
| `scripts/install_legacy_sim.sh` | Documented iOS 13.7/14.5 launchd crash. |
| `.claude/context/session-28-findings.md` | SimFramebuffer API, PurpleFB fallback, crash analysis. |

### Runtime Compatibility Matrix (UPDATED from Session 28)

| iOS | Build | Display Protocol | Status | Notes |
|-----|-------|-----------------|--------|-------|
| 9.3 | 13E233 | PurpleFBServer | ✅ Working (scale=1) | Square icons, no wallpaper |
| 10.3 | 14E8301 | PurpleFBServer | ✅ Working (scale=1) | Square icons, no wallpaper |
| 12.4 | 16G73 | PurpleFBServer | ✅ Working (100% coverage) | Full display |
| 13.7 | 17H22 | PurpleFB (has strings) | ❌ Crashes on boot | launchd bootstrap failure |
| 14.5 | 18E182 | PurpleFB (has strings) | ❌ Crashes on boot | launchd bootstrap failure |
| 15.7 | 19H12 | Native (SimRenderServer) | ✅ Works natively | |
| 16.4 | 20E247 | Native | ✅ Works natively | |
| 17.4 | 21E213 | Native | ✅ Works natively | |
| 18.0 | 22A3351 | Native | ✅ Works natively | |
| 26.2 | 23C54 | Native | ✅ Works natively | |

**Missing**: iOS 7, 8, 11 (CDN returns 403; need Xcode 7.3.1/9.4.1 with Apple ID auth)

### Session 28 Scale Fix Attempts (ALL FAILED)

| # | Approach | Result |
|---|----------|--------|
| 1 | SIMCTL_CHILD_DYLD_INSERT_LIBRARIES | launchd_sim strips all DYLD_ env vars |
| 2 | insert_dylib + __interpose section | Dylib loads but dyld_sim ignores __interpose for LC_LOAD_DYLIB |
| 3 | insert_dylib + constructor setScale:2.0 | Causes infinite unmap/remap loop (setScale triggers display_changed → unmap → map → repeat) |
| 4 | BaseBoard binary patch (BSMainScreenScale→2.0) | Function returns 2.0 but value never reaches Display::set_scale — no visual change |
| 5 | Constant patch at 0xbb460 (Session 27) | Broke display init entirely (zero flushes) |

**Root cause still unsolved**: BSMainScreenScale returns 2.0 after patch, but the code path from BSMainScreenScale → Display::set_scale is broken or bypassed. The scale value is consumed somewhere that doesn't affect the display geometry.

**Next approach to try**: RE the exact code path in backboardd from BSMainScreenScale() call site to Display::set_scale(). Find where the value is stored, what conditions gate the set_scale call, and whether there's a check that prevents it on simulator. This is a Ghidra/disassembly task on the iOS 9.3 backboardd binary.

### Agent Findings (Session 28)

| # | Agent | Finding |
|---|-------|---------|
| 37 | A | SimFramebuffer protocol RE: iOS 13.7 uses SFB API (SFBConnection/SFBDisplay/SFBSwapchain), IOSurface swapchains. SimFramebufferClient is a dlopen shim to host-side framework. |
| 37b | A | iOS 13.7 QuartzCore has both SimDisplay AND PurpleDisplay code paths. headServices triggers PurpleFB path. |
| 38 | A | BSMainScreenScale is in BaseBoard.framework (not BackBoardServices). Patched function entry to return 2.0 — no visual effect. |
| 39 | A | Constructor setScale:2.0 fires but triggers infinite unmap/remap loop. set_scale → update_geometry → post_display_changed → unmap_surface → map_surface → repeat. |
| 40 | A | Per-runtime scale function mapping: iOS 9.3/10.3 use BSMainScreenScale (imported), iOS 13.7 uses BKMainDisplayScaleFromMobileGestalt (local, not interposable). |
| 41 | C | CDN dead end for iOS 8/11. Only Xcode 7.3.1/9.4.1 contain these runtimes. |
| 42 | C | Complete SimFramebuffer C API extracted: 3 object types (Connection, Display, Swapchain), full function list, rendering flow documented. |
| 43 | C | PurpleFBServer strings confirmed in ALL runtimes through iOS 14.5. But 13.7/14.5 crash during launchd bootstrap on macOS 26 before reaching display init. |
| 44 | C | iOS 13.7/14.5 crash analysis: "Failed to bootstrap path: .../backboardd, error = 2" — macOS 26 launchd rejects these binaries during XPC bootstrap. |

### Session 29 Priorities

#### P1: 2x Scale (Deeper RE Required)
- Must trace BSMainScreenScale → Display::set_scale in backboardd disassembly
- Key question: does backboardd CALL set_scale at all? Or does it rely on the host framework to set it?
- Check if CAWindowServer::init sets scale from BSMainScreenScale or if it's a different path
- The Ghidra instance should have iOS 9.3 backboardd loaded

#### P2: iOS 13.7/14.5 Boot Fix (launchd Compatibility)
- These crash during launchd bootstrap, not display protocol
- Need to understand what XPC/launchd changes in macOS 26 break iOS 13.x binaries
- May require patching launchd_sim or the runtime's launchd plists
- Lower priority than P1 since 15.7+ works natively

#### P3: Install iOS 8/11
- Requires Apple ID auth for Xcode 7.3.1 (iOS 8) or 9.4.1 (iOS 11)
- User must initiate the download
- Once downloaded, extract sim runtime and use install_legacy_sim.sh --patch-all

### What's Working Well
- Multi-device simultaneous display in Simulator.app
- UDID-based window matching (no name collisions)
- Double-buffered IOSurface (no tearing)
- CADisplayLink vsync-aligned rendering
- Zero file I/O display pipeline
- Daemon resilience (SIGTERM, watchdog, dynamic alloc)
- 10 iOS runtimes installed (9.3 through 26.2)
- iOS 12.4 at 100% pixel coverage
- iOS 9.3/10.3 working at scale=1 (functional, interactive)
- start_rosettasim.sh updated for iOS 12.4

### Known Issues
- Square icons on iOS 9.3/10.3 (scale=1.0, needs deeper RE)
- No wallpaper on iOS 9.3/10.3 (procedural wallpaper fails at scale=1.0)
- iOS 13.7/14.5 crash during launchd bootstrap on macOS 26
- iOS 8/11 runtimes unavailable (CDN 403, need old Xcode)
- 30 flushes then stops on iOS 9.3 (render stall after initial boot — possibly normal idle behavior)
