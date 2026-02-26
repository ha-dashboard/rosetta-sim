# Session 25 Final State — iOS 9.3 + 10.3 Simulators WORKING on Apple Silicon

## Date: 2026-02-26

## Achievement
First real GPU-composited pixels from iOS 9.3 and iOS 10.3 simulators on Apple Silicon (macOS 26). SpringBoard home screen with app icons renders via CARenderServer. Full CoreSimulator IO integration (display, HID, Metal, audio).

## Architecture (What Works)

```
xcrun simctl boot <UDID>          ← native CoreSimulator boot
  → launchd_sim (55+ processes)   ← real Apple bootstrap
  → backboardd + CARenderServer   ← real GPU compositor
  → SpringBoard                   ← real system UI

purple_fb_bridge <UDID>           ← our ONLY custom tool
  → [SimDevice registerPort:service:error:]  ← registers PurpleFBServer
  → dispatch_source_mach_recv     ← listens for backboardd
  → msg_id=4 reply: memory_entry + dims  ← provides framebuffer
  → msg_id=3 reply: ack flush    ← enables continuous rendering
```

## Key Discoveries

### What Failed (broker approach, sessions 22-24)
- Custom broker with ad-hoc bootstrap = endless hacks
- Bootstrap port delivery unreliable under Rosetta 2
- Shmem client pointer issue (cross-process mach_vm_remap fails with broken bootstrap)
- 12+ patches across 4 sessions, 0 pixels

### What Worked (native sim + bridge tool)
- `xcrun simctl boot` boots the REAL simulator perfectly
- `[SimDevice registerPort:service:error:]` registers PurpleFBServer in sim's launchd_sim
- PurpleFB protocol (msg_id 3/4) provides framebuffer to backboardd
- Flush reply unblocks continuous rendering
- Shmem works natively (proper launchd_sim infrastructure)
- No DYLD_INSERT, no interpositions, no Shmem hacks

### Root Causes Found
| Issue | Cause | Fix |
|-------|-------|-----|
| No display for old runtimes | CoreSimulatorService "Unable to determine platform" (Code 401) | Bypass: register PurpleFBServer ourselves |
| Error 401 | Missing platform-SDK match in modern Xcode | Not fixable via config (7 attempts failed) |
| AMFI blocks SimFramebuffer | Ad-hoc signed binary | Restored Apple-signed v1051 |
| Framebuffer 0x0 | No SimDisplayProperties sent (platform check blocks it) | PurpleFBServer bridge provides dimensions |
| Only 1 flush | flush_shmem blocks on reply (wait_for_reply=TRUE) | Send minimal mach_msg reply |
| simctl spawn fails | launchd_sim "memory failure" on modern macOS | Not needed — registerPort works from host |

## Files Created

| File | Purpose |
|------|---------|
| `src/plugins/IndigoLegacyFramebufferServices/` | PurpleFB bridge tool + plugin code |
| `tools/view_raw_framebuffer.swift` | Live framebuffer viewer |
| `.claude/context/session-25-state.md` | Mid-session state |
| `docs/milestone_ios93_springboard.png` | SpringBoard screenshot |

## Runtime Support

| Runtime | Status | Notes |
|---------|--------|-------|
| iOS 9.3 | WORKING | Installed runtime, SpringBoard renders, 31+ flushes |
| iOS 10.3 | WORKING | Created .simruntime bundle, 60fps, 50%+ pixel coverage |
| iOS 12.4 | Untested | Should work with same bridge |

## IO Integration (from simctl io enumerate)

```
Display (class 0): 750x1334 BGRA ✅
Display (class 1): 720x480 BGRA (TVOut) ✅
DisplayAdapter: LCD @326dpi @2x, 60Hz ✅
LegacyHID: Power On ✅
StreamProcessor: Apple M2 Max Metal ✅
StreamProcessor: Apple Software Renderer ✅
Audio: Host route ✅
```

## Next Steps (Session 26)

1. **Touch input** — Send IOHIDDigitizerEvents via IndigoHIDRegistrationPort
2. **Live display** — Integrate with RosettaSimApp (RSIM format) or build dedicated viewer
3. **App launching** — Install and launch apps via simctl
4. **iOS 12.4 test** — Same bridge for another runtime
5. **Packaging** — Clean up bridge tool, make it a proper CLI

## Commits This Session
- `215abe7`: PurpleFB bridge tool — first real pixels
- `eaaf7e0`: Continuous rendering with flush replies
- `d77b09f`: SpringBoard milestone screenshot + IO integration

## Agent Sessions
- Agent A: `cmm2kr8hg5x20nq32pt5ca76g` — SimFramebuffer protocol RE, PurpleFB verification
- Agent B: `cmm2kyo475x3anq32ul3awimd` — Bridge tool implementation, testing
- Agent C: `cmm3jdwnz00h1nh343wc8wxtw` — Display pipeline research, viewer tool
- Agent D: `cmm3jdykd02c3ma37ogdkilav` — SimRenderServer RE, iOS 10.3 runtime bundle + test
