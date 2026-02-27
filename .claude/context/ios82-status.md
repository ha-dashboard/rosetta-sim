# iOS 8.2 Status — Parked (Session 29)

## Summary
Both SpringBoard and backboardd survive boot with a 7-layer crash protection shim. The display pipeline connects (map_surface kr=0) but the compositor never starts rendering (zero flushes). The root cause is `[NSBundle mainBundle]` returning nil under Rosetta 2, which cascades through the entire system.

## What Works
- **PurpleFB msg_id=2**: Daemon handles iOS 8.2's map_surface (one-line fix in `rosettasim_daemon.m`)
- **Crash protection**: 7-layer shim keeps both processes alive
- **map_surface**: backboardd connects to PurpleFBServer, daemon replies with 750x1334 surface

## What Doesn't Work
- **Zero flushes**: Compositor never starts rendering
- **@try/@catch under Rosetta 2**: SIGTRAP — ObjC exception unwinding broken
- **SIMCTL_CHILD_DYLD_INSERT_LIBRARIES**: launchd_sim blocks DYLD_ env vars
- **GOT rebinding for CFDictionaryCreate substitution**: Doesn't trigger for the HID call site

## Root Cause Chain
```
[NSBundle mainBundle] → nil (Rosetta 2 / macOS 26 incompatibility)
  → bundleIdentifier → nil (in SpringBoard process)
    → BKSHIDEventCreateClientAttributes() → dict with nil bundleID
      → IOHIDEventSystemClient sends nil bundleID to backboardd
        → backboardd can't map SpringBoard PID → no scene hosting
          → no UIWindow → no CATransaction::commit → ZERO FLUSHES
```

## Crash Protection Shim (`src/shims/ios8_frontboard_fix.m`, 393 lines)

| Layer | What | Why | Status |
|-------|------|-----|--------|
| 1 | Nil-safe CFDictionaryCreate (fishhook GOT) | BKSHIDEventCreateClientAttributes nil bundleID | Works |
| 2 | Nil-safe NSMutableArray (ObjC swizzle) | FrontBoard _cacheFolderNamesForSystemApp | Works |
| 3 | NSAssertionHandler suppression | Multiple NSAssert failures → std::terminate | Works |
| 4 | [NSBundle mainBundle] fallback | CFBundleGetInfoDictionary SIGSEGV | Partially works (bundle created, bundleIdentifier still nil) |
| 5 | bundleIdentifier fallback | Process-name-based identifiers | Deployed, untested with substitution |
| 6 | C++ exception logging | __cxa_bad_cast diagnostic | Works |
| 7 | Crash signal handler | SIGABRT/SIGSEGV backtrace to file | Works |

## Binary Modifications (in iOS 8.2 runtime)

| Binary | Modification | Backup |
|--------|-------------|--------|
| `SpringBoard.app/SpringBoard` | insert_dylib + codesign --options=0 | `SpringBoard.orig` |
| `usr/libexec/backboardd` | insert_dylib + codesign --options=0 | `backboardd.orig` |
| `usr/lib/ios8_frontboard_fix.dylib` | Our shim (deployed) | N/A |

## Key Crash Backtraces Found

**Crash A — FrontBoard nil insertion (SIGABRT)**:
`FBApplicationInfo._cacheFolderNamesForSystemApp: +354` → `addObject:nil`
Cause: `localizedStringForKey:value:table:` returns nil because mainBundle is nil.

**Crash B — HID connection assertion (std::terminate)**:
`NSAssertionHandler handleFailureInMethod:` at backboardd+0x26565
Message: "The connection doesn't have a bundleID"

**Crash C — CFBundleGetIdentifier SIGSEGV**:
`CFBundleGetInfoDictionary +35` → null pointer deref
Cause: `[NSBundle mainBundle]` returns nil in `GSEventLogRunLoopEventStartTime`.

## Recommended Next Steps (Future Session)

1. **P0**: Fix CFDictionaryCreate substitution — ensure "com.apple.springboard" is actually sent as the bundleID value (current GOT rebinding may not trigger for this call site)
2. **P1**: Investigate WHY `[NSBundle mainBundle]` returns nil — diagnostic needed: is it nil or present-but-broken?
3. **P2**: Set `IPHONE_SIMULATOR_DEVICE=iPhone` env var (MobileGestalt device class)
4. **P3**: Consider a comprehensive compatibility shim that interposes CFBundleGetMainBundle (C function) in addition to [NSBundle mainBundle] (ObjC method)

## Key Addresses

| Symbol | Binary | Offset |
|--------|--------|--------|
| PurpleDisplay::map_surface | QuartzCore | +0xe8760 |
| PurpleDisplay::openMain | QuartzCore | +0x136ba0 |
| shared_server_init | QuartzCore | +0x1347dd |
| BKSHIDEventCreateClientAttributes | BackBoardServices | +0x13298 |
| _cacheFolderNamesForSystemApp: | FrontBoard | +0x2f22e |
| _queue_handleConnect:forClient: | backboardd | +0x27c36 |

## Build & Deploy

```bash
# Build shim
SDK=$(xcrun --show-sdk-path --sdk iphonesimulator)
/usr/bin/cc -arch x86_64 -dynamiclib -framework Foundation -framework CoreFoundation \
    -mios-simulator-version-min=8.0 -isysroot "$SDK" \
    -install_name /usr/lib/ios8_frontboard_fix.dylib \
    -Wl,-not_for_dyld_shared_cache \
    -o src/build/ios8_frontboard_fix.dylib src/shims/ios8_frontboard_fix.m

# Deploy (dylib only — binaries already patched)
RT8=~/Library/Developer/CoreSimulator/Profiles/Runtimes/iOS_8.2.simruntime/Contents/Resources/RuntimeRoot
cp src/build/ios8_frontboard_fix.dylib "$RT8/usr/lib/"
codesign --force --sign - --options=0 "$RT8/usr/lib/ios8_frontboard_fix.dylib"
```

## Diagnostic Files (after boot)
- `/tmp/rosettasim_frontboard_fix_loaded` — constructor fired + PID
- `/tmp/rosettasim_frontboard_rebound` — CFDictionaryCreate GOT rebinding status
- `/tmp/rosettasim_crash_backtrace.txt` — signal handler backtrace
- `/tmp/rosettasim_cxa_throw.txt` — C++ exception log
