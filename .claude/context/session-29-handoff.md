# Session 29 Handoff (Final)

## Summary
Major session — iOS 7, 8, 13, 14, 15 runtime support investigated. Display rendering achieved on iOS 12.4 and 13.7 (in addition to existing 9.3, 10.3). Touch/HID on iOS 12.4/13.7 remains unsolved. RosettaSim.app and rosettasim-ctl built.

## Commits (Session 29)
- `b0ff220` — iOS 8.2 + 13.7 runtime support (msg_id=2, FrontBoard fix, SFB stub, install script)
- `584b9f7` — Daemon periodic re-scan + CFRunLoopRun stability
- `225296c` — Daemon re-scan stability
- `cf84eed` — RosettaSim.app builder
- `654c27b` — RosettaSim.app cleanup on exit
- `3be9cef` — Idle CPU fix + iOS 8.2 CFDictionaryCreate crash fix
- `e2a73d1` — iOS 8.2 crash protection (7-layer shim)
- `7b563e4` — iOS 8.2 comprehensive status doc
- `a767e36` — iOS 15.7 daemon allowlist
- `b70ded5` — rosettasim-ctl (simctl replacement for legacy devices)
- `69d40d2` — Daemon re-scan fix (only deactivate shutdown devices)
- `b24ef3b` — Daemon re-scan fix (only deactivate used devices)
- `e5f5646` — rosettasim-ctl launch command
- `2b09ac1` — timeout binary path fix for macOS

## Runtime Status (End of Session 29)

| Runtime | Arch | Display | Touch | Status |
|---------|------|---------|-------|--------|
| iOS 7.0 | x86_64 | — | — | Parked — liblaunch_sim protocol mismatch (needs SimLaunchHost re-sign) |
| iOS 8.2 | x86_64 | Black | — | Parked — processes alive, zero flushes. Full doc: ios82-status.md |
| iOS 9.3 | x86_64 | ✅ | ✅ | **Working** |
| iOS 10.3 | x86_64 | ✅ | ✅ | **Working** |
| iOS 12.4 | x86_64 | ✅ | ❌ | Display works, HID broken (port protocol mismatch) |
| iOS 13.7 | x86_64 | ✅ | ❌ | Display works (SFB stub), HID broken (same as 12.4) |
| iOS 14.5 | x86_64+arm64 | ❌ | ❌ | Blocked — systemic SIGBUS |
| iOS 15.7 | arm64+x86_64 | ❌ | ❌ | Blocked — SIGBUS (same as 14.5) |
| iOS 16.4+ | arm64 | ✅ | ✅ | **Working (native)** |

## Key Deliverables

### RosettaSim.app
`scripts/build_app.sh` → double-clickable macOS app. Auto-starts daemon, sets DYLD injection, kills daemon on exit.

### rosettasim-ctl
`src/tools/rosettasim_ctl.m` → proper simctl replacement. Commands: list, boot, shutdown, install, launch, screenshot, status. Legacy devices use direct implementations; native delegates to xcrun simctl.

### SimFramebufferClient stub
`src/shims/sim_framebuffer_stub.c` — returns NULL from SFBConnectionCreate. Prevents ud2 trap on iOS 13.7. Needs universal build for iOS 15.7 (deployed but SIGBUS is a different issue).

### Install script
`scripts/install_legacy_sim.sh` — archive.org downloads for Xcode 5.0/6.2, iOS 7.0/8.2 extraction, plist generation.

### Daemon improvements
- Periodic 5s re-scan (discovers new devices dynamically)
- Runtime allowlist (iOS 7.0–15.7)
- Only deactivates devices with flush_count > 0
- Idle CPU fix (CADisplayLink paused when no devices)

## Open Issues for Session 30

### P0: iOS 12.4/13.7 HID (touch doesn't work)
**Root cause hypothesis**: Port handshake protocol mismatch.
- iOS 9.3: `bootstrap_check_in("IndigoHIDRegistrationPort")` — backboardd OWNS the port
- iOS 12.4: `bootstrap_look_up("IndigoHIDRegistrationPort")` + handshake — sends NEW port to host
- Host plugin (IndigoLegacyHIDServices) may only understand iOS 9.3 protocol
- SFB stub didn't help — tested and confirmed
- SimulatorHID copy into RuntimeRoot didn't help
- All env vars are set correctly
- `IndigoHIDSystemSpawnLoopback` returns 0 (success)
- Agent A analyzing the protocol mismatch (Finding 67)

### P1: iOS 7.0 (parked)
Needs SimLaunchHost.x86 re-signed to remove library-validation. Requires sudo. All other approaches exhausted (Finding 58).

### P2: iOS 8.2 display (parked)
Both processes alive with 7-layer shim. Zero flushes due to [NSBundle mainBundle] nil → bundleID nil → no scene hosting. Full doc: ios82-status.md.

### P3: iOS 14.5/15.7 SIGBUS
Systemic crash-loop, different from iOS 13.7's SIGSEGV. The SFB stub doesn't help. Likely Metal/GPU memory mapping issues with arm64 native binaries.

## Key Findings (Session 29)
- Finding 46: iOS 8.2 PurpleFB uses msg_id=2 (not 4)
- Finding 51: iOS 13.7 QuartzCore PurpleFB fallback
- Finding 53: SimFramebufferClient ud2 trap
- Finding 55: iOS 7.0 liblaunch_sim CDv20100 signature rejected
- Finding 58: SimLaunchHost library-validation blocks all non-Apple signatures
- Finding 60: iOS 8.2 [NSBundle mainBundle] nil cascades through entire system
- Finding 62-67: iOS 12.4 HID protocol analysis (host identical, sim-side protocol changed)

## Rosetta 2 Gotchas
- @try/@catch doesn't prevent SIGTRAP — must prevent exceptions, not catch them
- SIMCTL_CHILD_DYLD_INSERT_LIBRARIES doesn't reach launchd_sim daemons
- dyld_sim requires Apple's original AMFI signature — never ad-hoc re-sign
- CDv20100 code signatures rejected by macOS 26 SimLaunchHost
- ReportCrash doesn't generate .ips for Rosetta sim processes
- /usr/bin/timeout doesn't exist on macOS — use gtimeout from Homebrew

## Agent Session IDs
- Analyst: cmm120gys49xlm733xq7vztjb
- Agent A (RE): cmm2kr8hg5x20nq32pt5ca76g
- Agent B (Execution): cmm2kyo475x3anq32ul3awimd
- Agent C (Research): cmm3jdwnz00h1nh343wc8wxtw
- Agent D (Testing): cmm3jdykd02c3ma37ogdkilav
- Agent E (Infrastructure): cmm4kj3lx045jme33ryso9v5c
