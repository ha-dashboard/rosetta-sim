# Session 29 Handoff

## Summary
Session focused on iOS 7, 8, 13, 14, 15 runtime support. Went from 5 working runtimes to 7+ with display rendering, multiple root causes found and fixed.

## Commits (Session 29)
- `b0ff220` — iOS 8.2 + 13.7 runtime support (msg_id=2, FrontBoard fix, SFB stub, install script)
- `584b9f7` — Daemon periodic re-scan + CFRunLoopRun stability
- `225296c` — Daemon re-scan stability (only deactivate used devices)
- `cf84eed` — RosettaSim.app builder (double-clickable macOS app)
- `654c27b` — RosettaSim.app cleanup on exit
- `3be9cef` — Idle CPU fix + iOS 8.2 CFDictionaryCreate crash fix
- `e2a73d1` — iOS 8.2 crash protection (6-layer shim)
- `7b563e4` — iOS 8.2 comprehensive status doc (parked)
- `a767e36` — iOS 15.7 daemon allowlist + iOS 8.2 bundleIdentifier fix

## Runtime Status

| Runtime | Arch | Display | Touch | Status |
|---------|------|---------|-------|--------|
| iOS 7.0 | x86_64 | — | — | Parked — liblaunch_sim protocol mismatch |
| iOS 8.2 | x86_64 | Black | — | Parked — zero flushes (bundleID nil chain). Full doc: ios82-status.md |
| iOS 9.3 | x86_64 | ✅ | ✅ | Working |
| iOS 10.3 | x86_64 | ✅ | ✅ | Working |
| iOS 12.4 | x86_64 | ✅ | Testing | SimulatorHID copied into RuntimeRoot — awaiting touch test |
| iOS 13.7 | x86_64 | ✅ | Testing | SFB stub + PurpleFB fallback — needs SimulatorHID copy like 12.4 |
| iOS 14.5 | x86_64+arm64 | ❌ | ❌ | Blocked — systemic SIGBUS crash-loop |
| iOS 15.7 | arm64+x86_64 | Testing | — | Universal SFB stub + headServices — Agent D testing |
| iOS 16.4+ | arm64 | ✅ | ✅ | Working (native) |

## Key Fixes

### SimFramebufferClient stub (iOS 13.7, 15.7)
`src/shims/sim_framebuffer_stub.c` — returns NULL from SFBConnectionCreate instead of ud2 trap. With headServices → PurpleFB fallback. iOS 15.7 needs universal (arm64+x86_64) build.

### iOS 8.2 crash protection (parked)
`src/shims/ios8_frontboard_fix.m` — 7-layer shim. Both processes survive but zero flushes. Root cause: [NSBundle mainBundle] nil under Rosetta 2. Full analysis in ios82-status.md.

### Daemon re-scan
5s periodic re-scan, runtime allowlist (7.0–15.7), idle CPU fix (CADisplayLink paused when no devices).

### RosettaSim.app
`scripts/build_app.sh` — double-clickable app, auto-starts daemon, kills on exit.

### Install script
`scripts/install_legacy_sim.sh` — archive.org downloads for Xcode 5.0/6.2, extraction, plist generation.

## Key Findings
- Finding 51: iOS 13.7 QuartzCore has PurpleFB fallback (_detectSimDisplays fails → _detectDisplays)
- Finding 53: SimFramebufferClient ud2 trap when SIMULATOR_FRAMEBUFFER_FRAMEWORK unset
- Finding 62: HID protocol identical on host side for all runtimes
- Finding 66: iOS 12.4+ HID needs SimulatorHID.framework inside RuntimeRoot (DYLD_ROOT_PATH blocks host paths)
- Rosetta 2: @try/@catch triggers SIGTRAP, SIMCTL_CHILD doesn't reach launchd_sim daemons, dyld_sim needs Apple signature

## In Progress
- rosettasim-ctl utility (Agent C building)
- iOS 12.4/13.7 HID touch test (SimulatorHID deployed)
- iOS 15.7 display test (universal SFB stub deployed)
