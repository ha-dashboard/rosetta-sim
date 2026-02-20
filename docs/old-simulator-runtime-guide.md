# Running Old iOS Simulator Runtimes on macOS 26 (Apple Silicon)

## The Goal

Get an iOS 9 iPad simulator running on a modern MacBook Pro (M2 Max, macOS 26)
with Xcode 26.2, for testing HADashboard against the oldest supported iOS versions.
iOS 9 simulators were last available in Xcode 10 — which can't run on macOS 26.

## Current State

**iOS 15.7 — WORKING with full visual display.** Safari, Settings, push notifications,
touch input all functional. Runs natively on ARM64 alongside modern iOS 17.4 simulators.

**iOS 12.4 — boots headless (~80 processes, HID connected) but no display.** The final
blocker is a display discovery protocol mismatch in `backboardd`.

**iOS 9.x — not yet attempted.** Would face the same issues as iOS 12.4 plus more.

**Tested on:** MacBook Pro M2 Max (Mac14,6), macOS 26.3 (25D125), Xcode 26.2

## What We Tried — Full Investigation Log

### Phase 1: Initial Research

**Question:** Can old iOS simulator runtimes work on macOS 26 Apple Silicon?

**Findings:**
- iPad 2 (iOS 9 device) requires **i386 architecture** — impossible on Apple Silicon
  (Rosetta 2 only does x86_64→arm64, not i386)
- iPad Air 2 and iPad mini 4 support **arm64 + x86_64** AND iOS 9+ — viable device types
- Xcode 13.2.1 (installed on the system) has iPad 2, iPad Air 2, iPad mini 4 device
  type profiles with `minRuntimeVersion: 8.0`
- Apple's download index (`index2.dvtdownloadableindex`) lists iOS 12.4 as the oldest
  runtime, with `maxHostVersion: 12.99.0` — but this is just a UI hint
- The runtime's own `profile.plist` has `minHostVersion: 10.12.1` and NO `maxHostVersion`
- iOS 9.3 runtime DMGs are still available at `download.developer.apple.com` (requires auth)

### Phase 2: Identifier Masquerade (SUCCESS)

**Problem:** CoreSimulatorService has a hardcoded table mapping runtime identifiers
to max macOS versions. `iOS-12-4` → max macOS 12.99.

**Discovery:** Found the table by running `strings` on the CoreSimulator framework:
```
com.apple.CoreSimulator.SimRuntime.iOS-12-4
12.99
com.apple.CoreSimulator.SimRuntime.iOS-13-0
```

**Fix:** Changed the runtime's `CFBundleIdentifier` from `iOS-12-4` to `iOS-15-4`.
The runtime immediately showed as available in `simctl list runtimes` with no
"unavailable" flag.

**Result:** Runtime boots! 80 processes start, SpringBoard runs. But no display —
`backboardd` crashes immediately.

### Phase 3: Diagnosing the Crash

**Crash analysis** (from `.ips` crash reports):
- Process: `backboardd` (ARM64, from the iOS 15.7 runtime, or x86_64 from iOS 12.4)
- Exception: `EXC_BAD_ACCESS (SIGSEGV)` at `0x0010000000010980`
- Crash report says "possible pointer authentication failure"
- Stack trace:
  ```
  _platform_strlen (crash)
  objc_stringhash_t::getIndex  [libdyld.dylib - RUNTIME]
  _dyld_get_objc_selector      [libdyld.dylib - RUNTIME]
  __sel_registerName            [libobjc.A.dylib - RUNTIME]
  map_images_nolock             [libobjc.A.dylib - RUNTIME]
  dlopen_internal               [libdyld.dylib - RUNTIME]
  ___getSimFramebufferHandle_block_invoke  [SimFramebufferClient - RUNTIME]
  IndigoHIDSystemSpawnLoopback  [SimulatorClient - RUNTIME]
  -[BKHIDSystem startHIDSystem] [backboardd - RUNTIME]
  ```

**Key insight:** The crash is entirely within the RUNTIME's libraries. The runtime's
`libdyld.dylib` tries to look up ObjC selectors in an optimization hash table. The
table contains data in a format the old code can't parse — the value `0x10982` is
being treated as an absolute pointer but it's actually a relative offset or
chained fixup metadata.

### Phase 4: Approaches That Failed

#### 4a. Patching libdyld to return NULL
Patched `_dyld_get_objc_selector` to immediately `return NULL`. This makes libobjc
fall back to its own selector table.

**Result:** `backboardd` appeared in process list (didn't crash!) but all processes
were stuck at "dyld has initialized but libSystem has not". The function is needed
during early init — returning NULL prevents libSystem from initializing.

#### 4b. Patching libdyld to skip hash table (targeted branch)
Changed `cbz x8, 0x689c` to `b 0x689c` (unconditional branch to fallback path).

**Result:** Same freeze. The fallback path's global is NULL, so it also returns NULL.

#### 4c. Swapping dyld_sim from iOS 17.4
Replaced the runtime's `dyld_sim` with iOS 17.4's version.

**Result:** Boot fails — "Failed to start launchd_sim". iOS 17.4's dyld_sim needs
newer `liblaunch_sim.dylib` and other system libraries.

#### 4d. Swapping libobjc from iOS 17.4
Replaced the runtime's `libobjc.A.dylib` with iOS 17.4's version.

**Result:** Boot fails — "Failed to start launchd_sim". ABI mismatch with other
system libraries.

#### 4e. Swapping all system libraries from iOS 17.4
Replaced `dyld_sim`, `libobjc`, and entire `usr/lib/system/` from iOS 17.4.

**Result:** Boot fails — 0 processes. Too many incompatibilities with the runtime's
higher-level frameworks (UIKit, Foundation, etc.)

#### 4f. Stripping ObjC from host frameworks
Zeroed out `__objc_classlist` and `__objc_imageinfo` in SimFramebuffer, SimulatorHID,
CoreSimulatorUtilities, SimPasteboardPlus.

**Result:** No crash, but `backboardd` never started. The ObjC classes are needed
by the HOST-side CoreSimulatorService for device I/O setup. Stripping them breaks
the host side while fixing the simulator side.

#### 4g. Environment variable redirect
Tried `SIMCTL_CHILD_DYLD_SHARED_REGION=avoid`, launchd plist `EnvironmentVariables`,
`SIMULATOR_FRAMEBUFFER_FRAMEWORK` override, and a C wrapper binary.

**Result:** AMFI strips `DYLD_*` variables. Custom env vars don't override because
CoreSimulatorService pre-caches the framework path before the process starts.

### Phase 5: Root Cause Discovery — Chained Fixups

**Breakthrough:** Checked the host frameworks' Mach-O load commands:
```
otool -l SimFramebuffer | grep LC_DYLD_CHAINED_FIXUPS
→ cmd LC_DYLD_CHAINED_FIXUPS    ← MODERN FORMAT
→ No LC_DYLD_INFO               ← NO TRADITIONAL FORMAT
```

The host frameworks (SimFramebuffer, SimulatorHID, etc.) from Xcode 26.2 use
`LC_DYLD_CHAINED_FIXUPS` exclusively. Old `dyld_sim` only understands
`LC_DYLD_INFO` (traditional rebase/bind). When `dyld_sim` loads these frameworks,
all pointer data remains as raw fixup chain metadata — explaining the
`0x0010000000010982` "pointer" that causes the crash.

### Phase 6: Shared Cache + Host Framework Swap (SUCCESS for iOS 15.7)

**Solution for arm64 runtimes (iOS 15.7):**

1. **Build old-format shared cache** using `update_dyld_sim_shared_cache` from
   Xcode 13.2.1. This tool produces `dyld_sim_shared_cache_arm64` with ObjC
   optimization tables in the old format. The runtime's `libdyld.dylib` reads
   these tables correctly during init.

2. **Swap host frameworks** from Xcode 13.2.1's `XcodeSystemResources.pkg`.
   Extracted with `pkgutil --expand-full` (handles `pbzx` compression — install
   `brew install pbzx` first). The Xcode 13 frameworks use `LC_DYLD_INFO_ONLY`
   (no chained fixups) and are universal (arm64 + x86_64).

3. **Fix SystemVersion.plist** — the runtime was mislabeled as iOS 14.5 but was
   actually iOS 15.7. CoreSimulatorBridge (from Xcode 13, min iOS 10.3 on x86_64,
   min iOS 14.0 on arm64) checks this version and aborts if too old.

**Result:** iOS 15.7 simulator fully working — 140+ processes, backboardd rendering,
Safari loading web pages, Settings app, push notifications. Runs alongside iOS 17.4.

### Phase 7: iOS 12.4 Investigation

iOS 12.4 has a fundamentally different challenge: it's **x86_64 only** (runs under
Rosetta 2 on Apple Silicon). The arm64 shared cache approach that worked for iOS 15.7
doesn't directly apply.

#### Issues found and fixed:

1. **`_vfork` symbol missing** — `libarchive.2.dylib` references `_vfork` which
   doesn't exist in the runtime's libSystem. Binary-patched the symbol table to
   replace `_vfork\0` with `_fork\0\0` (same length). Without this, the shared
   cache builder (`update_dyld_sim_shared_cache`) fails fatally.

2. **Double-slash install names** — `libLLVMContainer.dylib` has install name
   `/System/Library/Frameworks/OpenGLES.framework//libLLVMContainer.dylib` (note `//`).
   `libCoreSymbolicationLTO.dylib` has a similar issue. The cache builder rejects
   these, causing a cascade: OpenGLES rejected → UIKit rejected → Foundation
   rejected → Security rejected → everything rejected. Fixed with
   `install_name_tool -id` to remove the double slash. **This turned a 78MB cache
   (135 libraries) into a 1.0GB cache (1,102 libraries).**

3. **Foundation iCloud deadlock** — `NSFileManager._registerForUbiquityAccountChangeNotifications`
   does a `dispatch_once` that calls into macOS 26's iCloud notification system,
   which doesn't respond to the old protocol, causing a permanent deadlock.
   Binary-patched at offset `0x3d6d6` (x86_64): replaced `push rbp` (0x55) with
   `ret` (0xC3) to make the function a no-op. **Must rebuild the shared cache after
   this patch** so the cached Foundation includes the fix.

4. **`_dyld_get_objc_selector` doesn't exist in iOS 12.4** — this function was
   introduced in iOS 13+. iOS 12.4's libobjc uses its own selector tables entirely.
   The shared cache ObjC optimization ("IMP caches") reports "0 bytes" / "metadata
   not optimized" because iOS 12.4's libobjc doesn't have the section format the
   Xcode 13 cache builder expects. This means the cache provides library consolidation
   but NOT the ObjC optimization that fixed the crash for iOS 15.7.

5. **Host framework version matching** — tried three approaches:
   - **Xcode 13 (CoreSimulator-783.5):** arm64+x86_64, no chained fixups, but
     version gap to client (554→783) causes display protocol mismatch
   - **Xcode 10 (CoreSimulator-587.35):** x86_64+i386 only, close version (554→587),
     but different Mach port naming scheme (`simFramebufferRandomCookie` vs
     `com.apple.CoreSimulator.SimFramebufferServer`)
   - **Merged (Xcode 10 x86_64 + Xcode 13 arm64):** using `lipo -create` to combine
     slices from different Xcode versions. Host side (arm64 from Xcode 13) works with
     CoreSimulatorService. Simulator side (x86_64 from Xcode 10) has correct protocol
     but wrong port naming for the current host.

   Downloaded Xcode 10.3 via `xcodes download "10.3"` (~5.7GB), extracted
   `XcodeSystemResources.pkg` from the `.xip`.

#### The unsolved blocker:

**`BKDisplayStartWindowServer()` assertion failure** in `backboardd` v195.65.1
(from iOS 12.4). After all fixes above, backboardd fully initializes (530 lines of
log output, HID system connected with all services: touch, buttons, gamepad,
proximity sensor, etc.) but then hits:

```
*** Assertion failure in void BKDisplayStartWindowServer()(),
    backboarddaemon-195.65.1/megatrond/BKDisplay.m:417
*** Terminating app due to uncaught exception 'NSInternalInconsistencyException',
    reason: 'No window server display found'
```

This is in the **backboardd binary itself** (not in host frameworks). The display
enumeration/discovery protocol changed between iOS 12's backboardd and the current
CoreSimulatorService. The HID side works, but the framebuffer side uses a different
connection handshake. This cannot be fixed by swapping host frameworks — it requires
patching backboardd's display discovery code or creating a protocol bridge.

### Version Gap Analysis

The SimFramebufferClient inside each runtime has a version, and it needs a
compatible SimFramebuffer host framework:

| Runtime | SimFBClient version | What works | What doesn't |
|---------|---------------------|-----------|--------------|
| iOS 15.7 | CoreSimulator-732.8 | Xcode 13 host (783.5) | — |
| iOS 12.4 | CoreSimulator-554 | HID via Xcode 10 (587.35) | Framebuffer (display protocol changed) |
| iOS 9.x | ~CoreSimulator-350? | Unknown | Everything (not attempted) |

## Current System State

### Installed Runtimes
```
iOS 12.4 (Legacy) (12.4 - 16G73) - com.apple.CoreSimulator.SimRuntime.iOS-15-4  [identifier masquerade]
iOS 15.7 (15.7 - 19H12)          - com.apple.CoreSimulator.SimRuntime.iOS-15-7  [WORKING]
iOS 17.4 (17.4 - 21E213)         - com.apple.CoreSimulator.SimRuntime.iOS-17-4  [always worked]
iOS 26.2 (26.2 - 23C54)          - com.apple.CoreSimulator.SimRuntime.iOS-26-2  [always worked]
```

### Host Framework State
The iphoneos-platform host frameworks at `/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/Resources/Platforms/iphoneos/` are currently **Xcode 13 versions** (CoreSimulator-783.5, `LC_DYLD_INFO_ONLY`, arm64+x86_64).

Originals backed up with `.v1051` suffix. Restore with:
```bash
DEST="/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/Resources/Platforms/iphoneos"
for FW_PATH in \
    "Library/PrivateFrameworks/SimFramebuffer.framework/SimFramebuffer" \
    "Library/Frameworks/SimulatorHID.framework/SimulatorHID" \
    "Library/PrivateFrameworks/SimPasteboardPlus.framework/SimPasteboardPlus" \
    "usr/libexec/CoreSimulatorBridge"; do
    sudo cp "$DEST/${FW_PATH}.v1051" "$DEST/$FW_PATH"
done
sudo pkill -f CoreSimulatorService
```

### Xcode Versions Available
- `/Applications/Xcode.app` — Xcode 26.2 (selected)
- `/Applications/Xcode-13.2.1.app` — Xcode 13.2.1
- `~/Downloads/Xcode-10.3.0-GM+10G8.xip` — Xcode 10.3 (downloaded, extracted to `/tmp/xcode10_extract`)

### Extracted Framework Caches
- `/tmp/xcode13_expanded/` — Xcode 13 XcodeSystemResources fully expanded
- `/tmp/xcode10_expanded/` — Xcode 10 XcodeSystemResources fully expanded
- `/tmp/merged_fw/` — merged binaries (Xcode 10 x86_64 + Xcode 13 arm64)

### iOS 12.4 Runtime Patches Applied
- `Info.plist`: `CFBundleIdentifier` → `iOS-15-4` (masquerade)
- `libarchive.2.dylib`: `_vfork` → `_fork` (symbol table patch)
- `libLLVMContainer.dylib`: fixed `//` install name
- `libCoreSymbolicationLTO.dylib`: fixed `//` install name
- `Foundation`: `_registerForUbiquityAccountChangeNotifications` patched to `ret`
- Shared cache: `dyld_sim_shared_cache_x86_64` (1.0GB, 1102 libraries)

## The Three Core Fixes (Recipe)

### Fix 1: Identifier Masquerade (Bypass Host Version Check)

CoreSimulatorService has a hardcoded table mapping runtime identifiers to max
macOS versions:
```
iOS-12-4 and earlier     → maxHostVersion 12.99 (macOS Monterey)
iOS-13-0 through iOS-14-5 → maxHostVersion 13.3.99 (macOS Ventura)
iOS-15-0 and later       → no restriction
```

**Fix:** Change `CFBundleIdentifier` in the runtime's `Info.plist` to `iOS-15-*`.

### Fix 2: Old-Format Shared Cache

Build `dyld_sim_shared_cache_{arch}` using `update_dyld_sim_shared_cache` from
Xcode 13.2.1. Place in `RuntimeRoot/var/db/dyld/`.

For arm64 runtimes (iOS 15.x): produces ~1.6GB cache with ObjC optimization tables.
For x86_64 runtimes (iOS 12.x): produces ~1.0GB cache but WITHOUT ObjC optimization
(iOS 12's libobjc lacks the required sections).

### Fix 3: Unchained Host Frameworks

Replace host frameworks with Xcode 13.2.1 versions (`LC_DYLD_INFO_ONLY`).
Requires `sudo`. Affects ALL simulator runtimes. Modern simulators (iOS 17+)
are unaffected because their dyld handles both formats.

## Step-by-Step: iOS 15.7 (Working)

### 1. Obtain the Runtime

Apple's CDN provides iOS 12.4-15.x as `.pkg` inside `.dmg`:
```
https://devimages-cdn.apple.com/downloads/xcode/simulators/com.apple.pkg.iPhoneSimulatorSDK{VERSION}.dmg
```

Extract the `.simruntime` bundle:
```bash
hdiutil attach download.dmg -mountpoint /tmp/mount
pkgutil --expand /tmp/mount/*.pkg /tmp/expanded
mkdir -p ~/Library/Developer/CoreSimulator/Profiles/Runtimes/iOS_15.simruntime
cd ~/Library/Developer/CoreSimulator/Profiles/Runtimes/iOS_15.simruntime
cat /tmp/expanded/Payload | gzip -d | cpio -id
```

### 2. Patch Info.plist
```bash
RUNTIME=~/Library/Developer/CoreSimulator/Profiles/Runtimes/iOS_15.simruntime
plutil -replace CFBundleIdentifier -string "com.apple.CoreSimulator.SimRuntime.iOS-15-4" \
    "$RUNTIME/Contents/Info.plist"
```

### 3. Fix SystemVersion.plist (if mismatched)
```bash
chmod 644 "$RUNTIME/Contents/Resources/RuntimeRoot/System/Library/CoreServices/SystemVersion.plist"
plutil -replace ProductVersion -string "15.7" "$RUNTIME/.../SystemVersion.plist"
plutil -replace ProductBuildVersion -string "19H12" "$RUNTIME/.../SystemVersion.plist"
```

### 4. Build the Shared Cache
```bash
TOOL="/Applications/Xcode-13.2.1.app/.../iOS.simruntime/Contents/Resources/update_dyld_sim_shared_cache"
RUNTIME_ROOT="$RUNTIME/Contents/Resources/RuntimeRoot"
mkdir -p "$RUNTIME_ROOT/var/db/dyld"
$TOOL -root "$RUNTIME_ROOT" -cache_dir "$RUNTIME_ROOT/var/db/dyld" \
      -arch arm64 -iOS -force \
      -skip /usr/lib/system/libsystem_networkextension.dylib
```

### 5. Swap Host Frameworks
```bash
pkgutil --expand-full \
    /Applications/Xcode-13.2.1.app/Contents/Resources/Packages/XcodeSystemResources.pkg \
    /tmp/xcode13_expanded

BASE13="/tmp/xcode13_expanded/Payload/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/Resources/Platforms/iphoneos"
DEST="/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/Resources/Platforms/iphoneos"

for FW_PATH in \
    "Library/PrivateFrameworks/SimFramebuffer.framework/SimFramebuffer" \
    "Library/Frameworks/SimulatorHID.framework/SimulatorHID" \
    "Library/PrivateFrameworks/SimPasteboardPlus.framework/SimPasteboardPlus" \
    "usr/libexec/CoreSimulatorBridge"; do
    sudo cp "$DEST/$FW_PATH" "$DEST/${FW_PATH}.v1051"
    sudo cp "$BASE13/$FW_PATH" "$DEST/$FW_PATH"
    sudo codesign -f -s - "$DEST/$FW_PATH"
done

xcrun simctl shutdown all && sudo pkill -f CoreSimulatorService && sleep 5
```

### 6. Create Device and Boot
```bash
xcrun simctl create "iPad Air 2 (iOS 15.7)" \
    com.apple.CoreSimulator.SimDeviceType.iPad-Air-2 \
    com.apple.CoreSimulator.SimRuntime.iOS-15-7
xcrun simctl boot "iPad Air 2 (iOS 15.7)"
open -a Simulator
```

## Next Steps: Getting Older Versions Working

### For iOS 12.4 (and by extension iOS 9.x)

The **final unsolved problem** is `BKDisplayStartWindowServer()` in backboardd
asserting "No window server display found". Potential approaches:

1. **Try iOS 13.x or 14.x runtimes** — they have newer backboardd versions that
   might be compatible with the current display protocol. iOS 14's backboardd might
   be close enough to iOS 15's to work. Download from Apple CDN (iOS 13/14 are
   `.pkg` format, same extraction process).

2. **Reverse engineer BKDisplayStartWindowServer** — disassemble backboardd's
   `BKDisplay.m:417` to understand what display service name or Mach port it looks
   up. Then either patch it to use the modern name, or configure the host to
   register under the old name.

3. **Create a display protocol bridge** — a native arm64 process that registers
   the old Mach service name that iOS 12's backboardd expects, translates messages
   to the modern framebuffer protocol, and forwards to the real SimFramebuffer.

4. **Replace backboardd with iOS 15.7's version** — iOS 15.7's backboardd IS
   compatible with the host. If we could make iOS 12.4's launchd_sim run
   iOS 15.7's backboardd, the display would work. The risk is ABI mismatch with
   iOS 12.4's UIKit/CoreAnimation that expect backboardd v195's interfaces.

### For iOS 9.x specifically

- Download from `https://download.developer.apple.com/Developer_Tools/iOS_9.3_Simulator_Runtime/iOS_9.3_Simulator_Runtime.dmg` (requires Apple Developer auth)
- Same extraction process, same three core fixes
- Additional challenges: even older system libraries, likely more Foundation/ObjC issues
- Use iPad Air 2 or iPad mini 4 device type (64-bit x86_64, NOT iPad 2 which is i386)

## Architecture Notes

The iOS simulator is NOT an emulator. Simulator apps compile to the host
architecture (arm64 on Apple Silicon) and run natively. The "simulator runtime"
provides iOS system frameworks (UIKit, Foundation, etc.) that the app links against.

Key components:
- **dyld_sim** — the runtime's dynamic linker, loaded by the host's dyld
- **CoreSimulatorService** — host daemon managing all simulator devices (v1051.17.7)
- **SimFramebuffer/SimulatorHID** — host frameworks loaded INTO simulator processes via dlopen
- **CoreSimulatorBridge** — host binary running inside the sim for device I/O setup
- **backboardd** — the simulator's display server (equivalent of WindowServer)
- **update_dyld_sim_shared_cache** — tool that builds the simulator's dyld shared cache

The crash chain for old runtimes:
```
backboardd starts
  → -[BKHIDSystem startHIDSystem]
  → IndigoHIDSystemSpawnLoopback (loads IndigoHIDServices bundle)
  → SimFramebufferClient does dlopen(SimFramebuffer.framework)
  → dyld_sim processes the host framework's ObjC metadata
  → CRASH: old dyld_sim can't parse LC_DYLD_CHAINED_FIXUPS / new ObjC selector format
```

The fix breaks this chain at step 4: the shared cache provides old-format ObjC tables
for init, and the Xcode 13 host frameworks use `LC_DYLD_INFO_ONLY` (old format) for dlopen.

## Why Each Fix is Needed

| Problem | Symptom | Fix |
|---------|---------|-----|
| Host version check | `simctl list` shows "unavailable, not supported on hosts after macOS X" | Identifier masquerade |
| ObjC selector table format | `backboardd` crashes in `_dyld_get_objc_selector` → `objc_stringhash_t::getIndex` | Build old-format shared cache |
| Chained fixups in host frameworks | `backboardd` SIGSEGV in `_platform_strlen` on `0x001000000001xxxx` pointer | Swap in Xcode 13 host frameworks |
| SystemVersion mismatch | `CoreSimulatorBridge` abort: "app was built for iOS 15.0 which is newer than this simulator 14.5" | Fix SystemVersion.plist |
| `_vfork` missing (iOS 12.4) | Shared cache builder fails | Binary-patch libarchive symbol table |
| `//` in install names (iOS 12.4) | Shared cache has only 135 libraries instead of 1102 | Fix with install_name_tool |
| Foundation iCloud deadlock (iOS 12.4) | `backboardd` hangs at dispatch_once during init | Patch Foundation to skip ubiquity registration |
| Display discovery protocol (iOS 12.4) | "No window server display found" assertion | **IN PROGRESS — Protocol bridge needed** |

## Phase 8: Display Protocol Deep Dive (2026-02-19)

### Root Cause Confirmed: Mach IPC Protocol Mismatch

The display failure is a **wire protocol mismatch** between two components:

| Component | Location | Version | Protocol |
|-----------|----------|---------|----------|
| SimFramebufferClient | iOS 12.4 runtime (in shared cache) | CoreSimulator-554 | Old (session ID `S` field, old struct layouts) |
| SimFramebuffer.framework | Xcode 13 host frameworks | CoreSimulator-783.5 | New (no session ID, different struct layouts) |

#### Struct comparison (`_SimDisplayProperties`):
```
v554 (iOS 12.4 client):  [64c][64c]Q{SimSize}{SimSize}QI{SimSize}{SimSize}IIIISSS
v783 (Xcode 13 host):    [64c][64c]QQI{SimSize}{SimSize}IIISS
```

Multiple other message types also changed: `_SimSwapchainPresent`, `_SimSwapchainPresentCallback`,
`_SimErrorReply`, and the v783 protocol added entirely new message types (`_SimDisplayMaskPath`,
`_SimDisplayMode`, `_SimDisplaySetCurrentMode`, `_SimDisplaySetCanvasSize`, etc.).

The outer `_SimFramebufferMessageData` envelope also changed: v554 has field `S` (session ID/cookie),
v783 removed it.

### Key Architecture Discovery

**iOS 15.7 does NOT have SimFramebufferClient.** The SFB* API was migrated from the runtime's
SimFramebufferClient into the host SimFramebuffer.framework between iOS 12 and iOS 15. This is
why iOS 15.7 works — the host framework provides everything, no protocol translation needed.

| Runtime | Has SimFramebufferClient? | Protocol | Compatible with Xcode 13 host? |
|---------|--------------------------|----------|-------------------------------|
| iOS 12.4 | Yes (v554) | Old | **No** — struct layouts differ |
| iOS 15.7 | **No** | N/A — host provides everything | **Yes** |
| iOS 17.4+ | No | N/A | Yes |

### Symbol Export Changes

The SimFramebuffer.framework API completely changed between Xcode eras:

**Xcode 10 (v587.35):** Exports low-level `simFramebufferMessage*` functions (message serialization).
**Xcode 13 (v783.5):** Exports high-level `SFB*` functions (SFBConnectionCreate, SFBDisplayGet*, etc.)
AND the old `simFramebufferMessage*` functions — but with different struct layouts.

The iOS 12.4 SimFramebufferClient exports the SFB* high-level API and has its OWN built-in
message serialization (no imports from SimFramebuffer). It dlopen's SimFramebuffer for the
server-side Mach service registration, not for message building.

### Service Name Architecture

Both Xcode 10 and Xcode 13 SimFramebuffer use the same Mach service name:
`com.apple.CoreSimulator.SimFramebufferServer` (returned by `simFramebufferServerPortName()`).

The Xcode 10 version also references `simFramebufferRandomCookie` (an environment variable
containing a session token). Modern CoreSimulatorService does NOT set this variable. The
launchd_bootstrap.plist is regenerated by CoreSimulatorService on every boot, preventing
manual env var injection.

### Approaches Tried and Failed

| Approach | Result |
|----------|--------|
| Merged SimFramebuffer (Xcode 10 x86_64 + Xcode 13 arm64) | Same SIGABRT — Xcode 10 x86_64 framework can't connect to modern CoreSimulatorService |
| Patch backboardd `BKDisplayStartWindowServer` assertion (NOP `je` at 0x1cee4) | Gets past first assertion but hits second in `BKSDisplayServicesStart` ("main display is nil") |
| Patch `BKSDisplayServicesStart` to return TRUE (`mov eax,1; ret` at 0xfbeb) | Cascade SIGABRT in both backboardd AND SpringBoard — too many downstream nil display accesses |
| Inject `simFramebufferRandomCookie` via launchd_bootstrap.plist | CoreSimulatorService regenerates the plist on boot, wiping modifications |
| Replace SimFramebufferClient with custom bridge + iOS 15.7 v732.8 backend | Bridge exported all 57 old SFB* functions but missed internal functions like `__getSimFramebufferHandle` |
| Direct swap: iOS 15.7 SimFramebufferClient v732.8 as drop-in replacement | Same SIGABRT — v732.8 has `__getSimFramebufferHandle` and loads SimFramebuffer, but display still not created |

### Deeper Analysis: Why the Display Is Never Created

After extensive testing, the evidence points to the issue being at the **CoreSimulatorService
level**, not just the client/host framework protocol. Key evidence:

1. **The iOS 15.7 SimFramebufferClient v732.8 binary, when used directly in the iOS 12.4 runtime,
   still fails.** This binary is identical to what works for iOS 15.7. The only difference is the
   runtime environment (x86_64 vs arm64, iOS 12.4 system frameworks vs 15.7).

2. **CoreSimulatorService may not register `com.apple.CoreSimulator.SimFramebufferServer` for
   x86_64-only runtimes.** The service registration might be conditional on runtime architecture
   or version. A probe running OUTSIDE the simulator confirmed the service doesn't exist in the
   host bootstrap. We couldn't run the probe INSIDE the simulator to check the sim's bootstrap.

3. **The `com.apple.CoreSimulator.IndigoFramebufferServices.Display` service** is the only
   framebuffer-related string in the modern CoreSimulator framework. This is a different name
   than what SimFramebuffer looks for, suggesting an architectural change in how framebuffers
   are managed.

### iOS 14.5 vs 15.7 SimFramebufferClient Comparison

The iOS 14.5 runtime on disk is actually iOS 15.7 (same build 19H12). A real iOS 14.5 runtime
was not available for testing. The SimFramebufferClient API changed significantly between
iOS 12.4 (v554) and iOS 15.7 (v732.8):

- **26 functions removed** (including `SFBClientInitialize`, swapchain acquire/present, color modes)
- **25 functions added** (display modes, canvas sizing, new swapchain model)
- **31 functions shared** (connection management, display properties)
- **Swapchain model changed**: old 2-op (acquire → present) to new 5-op (begin → add → callback → submit/cancel)

### Architecture Change: SimFramebufferClient Loading

| Runtime | How SimFramebufferClient is loaded | Who creates CADisplay? |
|---------|-----------------------------------|----------------------|
| iOS 12.4 | SimulatorClient → IndigoHIDSystemSpawnLoopback → `__getSimFramebufferHandle` | Unknown — QuartzCore has NO SimFramebufferClient link |
| iOS 14.5/15.7 | QuartzCore **weak-links** to SimFramebufferClient | QuartzCore calls SFBConnectionCreate → SFBConnectionCopyDisplays |

This is a fundamental architecture change: in iOS 14.5+, QuartzCore drives display creation.
In iOS 12.4, the display creation path goes through SimulatorClient/HID setup.

### Remaining Strategy Options

1. **Download a REAL iOS 13 or iOS 14 runtime** to test the protocol boundary. iOS 13/14
   runtimes are available from Apple's CDN. If iOS 14 works with Xcode 13 host frameworks,
   that narrows the gap to iOS 12 specifically.

2. **Reverse engineer CoreSimulatorService's framebuffer setup** to understand exactly what
   Mach services it registers and under what conditions. Use class-dump or Hopper on the
   CoreSimulator framework.

3. **Custom backboardd replacement** — as explored in the RosettaSim/ARCHITECTURE.md project,
   build a custom display server that creates CADisplays from the host's framebuffer using the
   modern protocol, bypassing the old display discovery entirely.

4. **Try an iOS 13 runtime** which is the closest to iOS 12 but with the newer `_dyld_get_objc_selector`
   support. Its SimFramebufferClient might be at an intermediate protocol version that's compatible.

### Planned Fix: SimFramebuffer Protocol Bridge

Build a custom x86_64 dylib that replaces the iOS 12.4 SimFramebufferClient in the shared cache:
- Exports the same SFB* C API that iOS 12.4's backboardd/QuartzCore expects
- Internally delegates to the Xcode 13 SimFramebuffer's SFB* API (new protocol)
- Translates struct layouts between old client expectations and new host responses
- Must be compiled for iphonesimulator x86_64 platform and included in the shared cache

This approach is mandatory for any runtime older than iOS 15 (where SimFramebufferClient exists)
and would support iOS 9 through iOS 14.
