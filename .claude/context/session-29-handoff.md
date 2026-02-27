# Session 29 Handoff

## Session 28 Summary

**10 commits**, covering scale fix investigation (failed), screenshot tooling, repo cleanup, and restructuring.

### Commit Log (Session 28)

```
ecd0c83 refactor: restructure repo — source under src/, setup scripts separated
0bb7e8b feat: simdeviceio screenshot plugin (source + build target)
c7c8843 chore: remove abandoned broker/bridge code — keep working display bridge only
a9148ea feat: daemon stores runtime_root per device for future plugin integration
51c5558 feat: screenshot tool + simctl wrapper for legacy iOS simulators
d7b3c26 docs: session 29 handoff — scale fix investigation, SimFramebuffer RE
7df5543 revert: restore pt_width=pixel_width — BSMainScreenScale patch has no visual effect
bef851c feat: 2x scale fix via BaseBoard binary patch + daemon pt_width/2
```

### Repo Structure (NEW — restructured in Session 28)

```
rosetta/
  README.md
  CLAUDE.md
  src/
    daemon/        rosettasim_daemon.m
    display/       sim_display_inject.m
    bridge/        purple_fb_bridge.m
    screenshot/    fb_to_png.m, rosettasim_screenshot_plugin.m
    scale/         sim_scale_fix.m
    viewer/        sim_viewer.m
    Makefile       builds all → src/build/
  scripts/
    setup.sh, start_rosettasim.sh, install_legacy_sim.sh
    test_all_devices.sh, simctl
  setup/
    setup_xcode833.sh, install_sim93.sh, launch_xcode833.sh, stubs/
  docs/
    milestone_*.png
  .claude/
    context/, plans/, agents/
```

### Runtime Compatibility Matrix

| iOS | Display Protocol | Status |
|-----|-----------------|--------|
| 9.3 | PurpleFBServer | Working (scale=1, square icons) |
| 10.3 | PurpleFBServer | Working (scale=1, square icons) |
| 12.4 | PurpleFBServer | Working (100% coverage, full display) |
| 13.7 | Crashes | launchd bootstrap failure on macOS 26 |
| 14.5 | Crashes | launchd bootstrap failure on macOS 26 |
| 15.7+ | Native | Works natively via SimRenderServer |

### Screenshot Support

- `scripts/simctl io <UDID> screenshot <file>` — works for ALL devices
  - Legacy: reads daemon's IOSurface via `fb_to_png` tool
  - Native: delegates to `xcrun simctl io screenshot`
- Native `xcrun simctl io screenshot` for legacy: NOT possible without modifying Apple's signed binaries

### Scale Fix Attempts (ALL FAILED)

| Approach | Result |
|----------|--------|
| DYLD_INSERT via SIMCTL_CHILD | launchd_sim strips DYLD_ vars |
| insert_dylib + __interpose | dyld_sim ignores interpose for LC_LOAD_DYLIB |
| insert_dylib + constructor | Infinite unmap/remap loop |
| BaseBoard binary patch | BSMainScreenScale→2.0 doesn't reach Display::set_scale |
| Constant patch (Session 27) | Breaks display init entirely |

### simdeviceio Plugin Attempts (ALL FAILED)

| Approach | Result |
|----------|--------|
| Custom .simdeviceio bundle | CoreSimulatorService won't load third-party plugins |
| insert_dylib into IndigoLegacy | Plugin never loads for legacy devices |
| DYLD_INSERT into CoreSimulatorService | Binary has library-validation flag |

### Session 28 Findings

| # | Agent | Finding |
|---|-------|---------|
| 37 | A | SimFramebuffer protocol RE (SFB API, IOSurface swapchains) |
| 38 | A | Screenshot via Display port descriptor (SimDisplayIOSurfaceRenderable) |
| 39 | A | SimDevice → Display port selector chain |
| 40 | A | Screenshot IOSurface transport via XPC/ROCKit |
| 41 | A | simdeviceio plugin bundle structure + loading mechanism |
| 42 | C | Complete SFB C API surface (SFBConnection/SFBDisplay/SFBSwapchain) |
| 43 | C | PurpleFBServer in all runtimes through iOS 14.5 |
| 44 | C | iOS 13.7/14.5 crash during launchd bootstrap |
| 45 | C | Display port class hierarchy (SimDisplayIOSurfaceRenderable) |
| 46 | B | IndigoLegacyFramebufferServices never loads for legacy devices |

### Session 29 Priorities

#### P1: 2x Scale (Deeper RE)
- Must trace BSMainScreenScale → Display::set_scale in backboardd
- The function returns 2.0 after binary patch but value never reaches set_scale
- Need to find the exact code path and what conditions gate the call
- Ghidra RE task on iOS 9.3 backboardd

#### P2: iOS 8/11 Runtimes
- CDN 403 for both — needs Xcode 7.3.1 (iOS 8) or 9.4.1 (iOS 11) with Apple ID auth

#### P3: Native simctl Screenshot
- Requires deeper CoreSimulator integration (modifying SimRenderServer's display descriptor)
- Or implementing a full SimRenderServer-compatible display service
- Low priority — scripts/simctl wrapper works

### Communication Protocol
- Documented in `~/.claude/CLAUDE.md`
- Use `mcp__happy-mcp__happy_send_message` (NOT built-in SendMessage)
- Sign off: `[Role - session_id]`
