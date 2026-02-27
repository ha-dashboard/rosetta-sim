# Session 28 Findings — Agent C (Research)

## Date: 2026-02-27

## 1. iOS 8/11 Runtime Availability

### CDN Status
Apple's CDN (`devimages-cdn.apple.com/downloads/xcode/simulators/`) only serves:
- iOS 9.3, 10.0, 10.1, 10.2 (old pkg format, specific timestamps)
- iOS 12.4-15.5 (old pkg format, from index2 manifest)
- iOS 16.x-17.x (new dmg format, auth required via download.developer.apple.com)
- iOS 18.x-26.x (cryptex format, no direct URL)

**iOS 8.x**: All 403 on CDN. Requires Xcode 7.3.1 extraction (Apple ID auth needed).
**iOS 11.x**: All 403 on CDN. Requires Xcode 9.4.1 extraction (Apple ID auth needed).
**Xcode 10.3**: Extracted from local xip — only bundles iOS 12.4, NOT iOS 11.

### `xcodes runtimes` list
Only shows iOS 12.4+. Same data as CDN index2.

## 2. SimFramebuffer Protocol — Complete C API Surface

Extracted from `SimFramebufferClient.framework` in iOS 13.7 runtime. The framework is a thin shim that dlopen's `SimFramebuffer.framework` from the HOST side and resolves C function pointers.

### Three Object Types

**SFBConnection** — top-level connection:
- `SFBConnectionCreate()`, `SFBConnectionConnect()`
- `SFBConnectionCreateDisplay()`, `SFBConnectionCopyDisplay[s|ByUID]()`
- `SFBConnectionRemoveDisplay()`, `SFBConnectionUpdateDisplay()`
- `SFBConnectionSetDisplay{Connected|Disconnected|Updated}Handler()`

**SFBDisplay** — represents a display:
- `SFBDisplayGetID()`, `SFBDisplayGetName()`, `SFBDisplayGetType()`
- `SFBDisplayGetDeviceSize()`, `SFBDisplayGetDotPitch()`, `SFBDisplayGetPowerState()`
- `SFBDisplayGetMode[Count]()`, `SFBDisplayGetCurrentMode()`, `SFBDisplayGetPreferredMode()`
- `SFBDisplayGetMaskPath()`, `SFBDisplayGetExtendedProperties()`
- `SFBDisplayGetMaxLayerCount()`, `SFBDisplayGetMaxSwapchainCount()`
- `SFBDisplaySetCurrentMode()`, `SFBDisplayCreateSwapchain()`

**SFBSwapchain** — framebuffer swap chain:
- `SFBSwapchainGetFramebufferSize()`, `SFBSwapchainGetPixelFormat()`
- `SFBSwapchainAcquireSurfaceFence()` — get IOSurface for writing
- `SFBSwapchainSwapBegin()` → `SFBSwapchainSwapAddSurface()` → `SFBSwapchainSwapSubmit()`
- `SFBSwapchainSwapCancel()`, `SFBSwapchainSwapSetCallback()`

### Message Layer (wire format over Mach ports)
- `simFramebufferMessageCreate/Dealloc/Receive/Send`
- `simFramebufferMessageAdd{Checkin,Data,DisplayProperties,DisplayMode,Swapchain,SwapchainPresent,...}`
- `simFramebufferMessageEnumerate[OfType|WithBlock]()`
- `simFramebufferServerPortName()` — returns Mach service name

### Key Difference from PurpleFBServer
| Aspect | PurpleFB (iOS 9-12) | SimFramebuffer (iOS 11+) |
|--------|---------------------|-------------------------|
| API style | Raw Mach msg | C function pointers (dlopen from host) |
| IOSurface | memory_entry via Mach port | IOSurface via function return |
| Swapchain | Implicit (single buffer) | Explicit (acquire/begin/submit) |
| Service name | `PurpleFBServer` | `simFramebufferServerPortName()` |

## 3. PurpleFBServer Presence Across Runtimes

**All tested runtimes through iOS 14.5 have PurpleFBServer strings in QuartzCore:**

| Runtime | PurpleFBServer in QC | SimFramebufferClient |
|---------|---------------------|---------------------|
| iOS 9.3 | YES | NO |
| iOS 10.3 | YES | NO |
| iOS 12.4 | YES | YES (v554/v732) |
| iOS 13.7 | YES | YES |
| iOS 14.5 | YES | YES |

iOS 12.4 is a hybrid — has both PurpleFBServer in headServices AND SimFramebufferClient.

## 4. iOS 13.7/14.5 Boot Failure on macOS 26

### Test Results
Added `headServices` with PurpleFBServer to both profiles. Both boot briefly (state→3) then immediately crash (state→4→1). No PurpleFB flush messages ever received — backboardd never gets far enough to connect.

### System Log Errors
- `"Failed to bootstrap path: .../backboardd, error = 2: No such file or directory"` — misleading; file exists but launchd rejects it
- `"SpringBoard: assertion failed: libxpc.dylib + 83586 [0x7d]"` — XPC assertion
- `"Failed to bootstrap path: .../IOKit.framework/Versions/A/IOKit, error = 2"` — framework bootstrap failure

### Root Cause
macOS 26's launchd has stricter XPC bootstrap requirements. iOS 13+ introduced new XPC/launchd features that don't work under Rosetta 2 + modern CoreSimulator. The older runtimes (9.3, 10.3, 12.4) use simpler launchd integration that macOS 26 still supports.

### Conclusion
PurpleFB fallback path exists in iOS 13.7/14.5 code but is **unreachable** — the runtimes crash before display setup. Making these work would require launchd/XPC compatibility patches similar to the libxpc work done for iOS 9.3 in Session 22-24.

## 5. Runtime Compatibility Matrix (Final)

| iOS | Display Protocol | Boots on macOS 26 | Bridge Status |
|-----|-----------------|-------------------|---------------|
| 9.3 | PurpleFB | YES | Working (scale fix applied) |
| 10.3 | PurpleFB | YES | Working |
| 12.4 | PurpleFB hybrid | YES | Working (100% pixel coverage) |
| 13.7 | SimFB (PurpleFB in code) | NO — launchd crash | Blocked |
| 14.5 | SimFB (PurpleFB in code) | NO — launchd crash | Blocked |
| 15.7 | SimRenderServer | YES (native) | No bridge needed |
| 16.4+ | SimRenderServer | YES (native) | No bridge needed |

## 6. Installed Runtimes After Session 28

- iOS 9.3 ✅ (PurpleFB, working)
- iOS 10.3 ✅ (PurpleFB, working)
- iOS 12.4 ✅ (PurpleFB, working — identifier fixed from iOS-15-4 to iOS-12-4)
- iOS 13.7 ✅ (installed, headServices patched, but crashes on boot)
- iOS 14.5 ✅ (real 14.5 downloaded from CDN, headServices patched, crashes on boot)
- iOS 15.7 ✅ (native — was masquerading as iOS 14.5, identity restored)
- iOS 16.4 ✅ (native)
- iOS 17.4 ✅ (native)
- iOS 18.0 ✅ (native)
- iOS 26.2 ✅ (native)
