# Session 32 Summary — Legacy Simulator Commands

## Date: 2026-02-28

## Achievements

### 1. CoreSimulatorBridge Running on Legacy Sims
- Xcode 8.3.3's CoreSimulatorBridge runs under Rosetta 2 inside launchd_sim
- Approach: replace sim root `platform_launch_helper` with patched bridge binary
- `bridge_compat_stubs.dylib` provides 19 missing symbols + nil-safe LSApplicationProxy swizzles
- Both CoreSimulatorBridge and SimulatorBridge processes stable on iOS 9.3
- Bridge wrapper at CoreSimulator framework path dispatches legacy vs modern binary
- MIG protocol v1↔v2 incompatibility prevents direct `simctl` usage (error -300)

### 2. Persistent App Install on iOS 9.3 and 10.3
- `rosettasim-ctl install` copies app, registers via LSApplicationWorkspace, persists across reboot
- Persistence mechanism: `rosettasim_installed_apps.plist` in device Library/
- `sim_app_installer.dylib` re-registers all apps from plist on boot (poll cycle 5, ~10s)
- iOS 10+: `notify_post("com.apple.LaunchServices.ApplicationsChanged")` refreshes SpringBoard
- iOS 10+: app copied to runtime root `/Applications/` for CSStore2 scan
- `listapps` falls back to `rosettasim_installed_apps.plist` when LS map missing

### 3. Screenshot Working on Both Runtimes
- `rosettasim-ctl screenshot` via `fb_to_png` + IOSurface from daemon's `active_devices.json`
- Works reliably on both iOS 9.3 and 10.3

### 4. Launch Working
- `rosettasim-ctl launch` via `LSApplicationWorkspace openApplicationWithBundleID:`
- Fallback to `FBSSystemService` if available

### 5. iOS 10.3 Runtime Restored
- Runtime root was corrupted by multiple binary modifications across sessions
- Restored from Xcode 8.3.3's `iPhoneSimulator10.3.sdk`
- `install_name_tool -change` used to neutralize unwanted LC_LOAD_DYLIB in SDK SpringBoard
- Key lesson: never modify Xcode SDK binaries directly

## What Doesn't Work Yet

### Touch Input
- **Root cause identified**: SimulatorHID.framework loaded in backboardd but `SimHIDSystem` never initialized
- backboardd logs: `Couldn't find the digitizer HID service`
- The digitizer service comes from CoreSimulatorBridge registering `IndigoHIDRegistrationPort`
- Bridge's `host_support` endpoint has ownership conflict between modern and legacy plists
- IndigoHID message sender (host-side) works: `IndigoHIDMessageForMouseNSEvent` + `SimDeviceLegacyHIDClient`
- Multiple approaches tried from dylib (NSEvent, CGEvent, direct mouseDown) — none worked
- **Next step**: Initialize SimHIDSystem in backboardd constructor, or resolve bridge endpoint conflict

### MIG Protocol Bridging
- Modern CoreSimulator sends MIG v2 messages; legacy bridge speaks MIG v1
- Same msg_ids (base 1000) but different reply format validation
- 21 MIG handlers mapped: install=1003, launch=1005, list_apps=1010, terminate=1018
- `SimDevice.launchHostClient.findServiceInSession` provides direct Mach port access
- **Next step**: Build MIG v1 client in rosettasim-ctl OR accept current direct approach

## Key Technical Discoveries

1. Custom plists in `CoreSimulator.framework/.../iphoneos/Library/LaunchDaemons/` ARE deployed by CoreSimulatorService
2. `launchd_sim` only loads plists from device overlay, NOT from runtime root `System/Library/LaunchDaemons/`
3. `NSHomeDirectory()` inside sim returns device data path, not host home
4. `dispatch_after` on main queue doesn't fire from constructor — use poll loop
5. `MobileInstallation/` directory is wiped by CoreSimulator on boot
6. CSStore2 doesn't follow symlinks in `/Applications/` — must be real copy
7. `codesign --force --sign -` required for dylibs on iOS 10.3 (stricter code signing)
8. Xcode 8.3.3 SimulatorHID.framework loads in iOS 9.3 backboardd under Rosetta 2

## Files Modified This Session

| File | Changes |
|------|---------|
| `src/tools/rosettasim_ctl.m` | Install persistence, /Applications/ copy, listapps fallback, touch experiments |
| `src/tools/sim_app_installer.m` | Boot-time re-registration, iOS 10+ notification, custom plist path |
| `src/bridge/bridge_compat_stubs.m` | NEW: 19 FBS stubs + nil-safe LSApplicationProxy swizzles |
| `src/tools/bridge_wrapper.c` | NEW: Legacy/modern bridge dispatcher |
| `src/display/sim_display_inject.m` | Touch handler experiments (WIP) |

## Runtime Root Modifications

### iOS 9.3 (`iOS_9.3.simruntime`)
- `/usr/libexec/platform_launch_helper` → replaced with RosettaSimBridge (`.orig` backup)
- `/usr/libexec/RosettaSimBridge` → patched Xcode 8.3.3 CoreSimulatorBridge
- `/usr/lib/bridge_compat_stubs.dylib` → compatibility stubs
- `/usr/lib/SimulatorHID.dylib` → Xcode 8.3.3 SimulatorHID
- `/usr/lib/sim_app_installer.dylib` → app installer dylib
- `/usr/libexec/backboardd` → insert_dylib'd with SimulatorHID (`.orig` backup)

### iOS 10.3 (`iOS_10.3.simruntime`)
- RuntimeRoot restored from Xcode 8.3.3 `iPhoneSimulator10.3.sdk`
- `/usr/lib/sim_app_installer.dylib` → app installer dylib (signed)
- SpringBoard has LC_LOAD_DYLIB for sim_app_installer (via SDK modification)

### Host System
- `/Library/Developer/.../CoreSimulatorBridge` → bridge_wrapper (universal arm64+x86_64)
- `/usr/local/lib/rosettasim/CoreSimulatorBridge.legacy` → patched Xcode 8.3.3 bridge
- `/usr/local/lib/rosettasim/CoreSimulatorBridge.modern` → original modern bridge

## Agent Sessions
- Agent A (`cmm2kr8hg5x20nq32pt5ca76g`): RE specialist — MIG protocol, IndigoHID struct, SimHIDSystem
- Agent B (`cmm2kyo475x3anq32ul3awimd`): Code writer — bridge stubs, install persistence, builds
- Agent C (`cmm3jdwnz00h1nh343wc8wxtw`): Research — MIG compatibility, HID pipeline, idb source
- Agent D (`cmm3jdykd02c3ma37ogdkilav`): Testing — iOS 9.3/10.3 deployment and verification
- Agent E (`cmm4kj3lx045jme33ryso9v5c`): Infrastructure — standing by
- Hass-dashboard (`cmm5019qc0ayfme3384smh0pk`): Separate project agent

## Next Session (33) Priorities

1. **Touch input** — Resolve bridge endpoint conflict, initialize SimHIDSystem, get IndigoHID messages flowing
2. **iOS 10.3 full verification** — Verify all commands work after runtime restore
3. **Clean up touch handler** — Remove debug code from sim_display_inject.m
4. **Consider MIG v1 client** — If touch needs bridge MIG, implement direct v1 messaging
