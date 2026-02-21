# Session 11 Handoff — Full App Authentication & Live Dashboard

**Date:** 2026-02-21
**Commits:** `cd5e62c`, `5fffc0f`
**Result:** hass-dashboard authenticates with a real Home Assistant server and loads the live dashboard with sensor data, zone controls, and camera feeds.

---

## 1. What Was Achieved

### End-to-End Application Working

The HA Dashboard iOS app (compiled x86_64 for the iOS simulator) now runs in RosettaSim on macOS 26 Apple Silicon and successfully:

1. **Renders the login screen** at 30fps with full UI (constellation animation, form card, text fields, buttons, segmented controls)
2. **Discovers the HA server** via mDNS/Bonjour (`_home-assistant._tcp.`)
3. **Authenticates** via Trusted Networks (auto-detected from `/auth/providers`)
4. **Exchanges tokens** (auth code → access/refresh tokens via `/auth/token`)
5. **Connects via WebSocket** (SocketRocket/SRWebSocket to the HA server)
6. **Loads the Lovelace dashboard** (52 cards, 2086 entities, 23 areas, 2 floors)
7. **Displays live data** (temperature sensors: 21.65°C, zone toggles, lighting controls)
8. **Streams camera feeds** (two outdoor security cameras with real-time image updates)

### Proven Working Authentication Flow

```
User taps "Home" discovered server
  → GET /auth/providers → 200 (trusted_networks detected)
  → Auto-connect: finds HAConnectionFormView, calls connectTapped
  → POST /auth/login_flow → 200 (3 users: Ash, Emily, Display)
  → UIAlertController auto-select → first user (Ash)
  → POST /auth/login_flow/{id} → 200 (auth code received)
  → POST /auth/token → 200 (access + refresh tokens)
  → WebSocket connect + authenticate
  → Lovelace config loaded → Dashboard rendered
  → Camera proxy images streaming continuously
```

### Key Technical Innovations This Session

#### 1. NSURLProtocol Bypass (BSD Sockets)

CFNetwork/NSURLSession requires `configd_sim` (a simulator-specific daemon) for DNS resolution, proxy configuration, and network interface enumeration. Without it, NSURLSession data tasks never complete — completion handlers never fire.

**Solution:** Implemented `RosettaSimURLProtocol` — a custom `NSURLProtocol` subclass that routes HTTP requests through raw BSD sockets, bypassing CFNetwork entirely. The protocol:

- Resolves hostnames via `getaddrinfo` (falls back to `ROSETTASIM_DNS_MAP` for `.local` domains)
- Connects via TCP (BSD `socket` + `connect`)
- Builds and sends HTTP/1.1 requests manually
- Parses HTTP responses (status, headers, body)
- Delivers `NSHTTPURLResponse` + `NSData` to NSURLSession clients

Registration:
- `[NSURLProtocol registerClass:]` for global registration
- Swizzle `__NSCFURLSessionConfiguration.protocolClasses` to inject into NSURLSession
- Also swizzle `[NSURLSession dataTaskWithRequest:completionHandler:]` as backup path

#### 2. SystemConfiguration Stubs

Without `configd_sim`, SystemConfiguration functions hang or return NULL. Stubbed:

| Function | Replacement |
|----------|-------------|
| `SCNetworkReachabilityCreateWithAddress` | Returns fake CF ref (always valid) |
| `SCNetworkReachabilityCreateWithName` | Returns fake CF ref (always valid) |
| `SCNetworkReachabilityGetFlags` | Returns `kSCNetworkReachabilityFlagsReachable` |
| `SCNetworkReachabilitySetCallback` | Accepts callback, no-op |
| `SCNetworkReachabilityScheduleWithRunLoop` | No-op |
| `SCDynamicStoreCreate` | Returns fake CF ref |
| `SCDynamicStoreCopyProxies` | Returns empty dictionary (no proxy) |

#### 3. Bootstrap Fast-Fail

The iOS SDK's `bootstrap_look_up` uses `mach_msg2`/XPC internally on macOS 26, which hangs for missing simulator services. Added fast-fail for known-missing services:

```
com.apple.SystemConfiguration.configd_sim → BOOTSTRAP_UNKNOWN_SERVICE (1102)
com.apple.springboard.backgroundappservices → BOOTSTRAP_UNKNOWN_SERVICE
com.apple.backboard.hid.services → BOOTSTRAP_UNKNOWN_SERVICE
com.apple.backboard.display.services → BOOTSTRAP_UNKNOWN_SERVICE
com.apple.analyticsd → BOOTSTRAP_UNKNOWN_SERVICE
```

#### 4. UIAlertController Auto-Select

UIAlertController presentation fails silently in the simulator (requires full windowing infrastructure). Swizzled `[UIViewController presentViewController:animated:completion:]` to detect UIAlertController and auto-invoke the first action's handler via the private `_handler` ivar.

#### 5. Auto-Connect Mechanism

The Connect button is laid out below the card view's `clipsToBounds` area (not tappable). After the `/auth/providers` response is delivered, the bridge:
1. Waits 2 seconds (for UI to update with auth modes)
2. Searches the view hierarchy for `HAConnectionFormView`
3. Calls `[formView connectTapped]` directly

#### 6. UIButton Action Dispatch Fallback

UIKit's gesture recognizer pipeline doesn't fully complete action dispatch in the bridged environment. Added a fallback: on touch ENDED phase, if the target is a `UIButton`, explicitly calls `[button sendActionsForControlEvents:UIControlEventTouchUpInside]`.

#### 7. CADisplay/CARenderServer Diagnostics

Added comprehensive diagnostic code that:
- Queries CARenderServer for displays via `[CADisplay displays]` (found 1: "LCD", displayId=1)
- Inspects UIScreen's 30 ivars (confirmed `_display` ivar holds CADisplay reference)
- Creates a remote `CAContext` with the display ID
- Auto-enables CARenderServer mode when running under the broker

**Finding:** CARenderServer IS running with a display, UIScreen IS associated with the correct CADisplay, but the app's layer tree isn't composited because the app isn't registered as a display client. This requires the full display services protocol (or HID System Manager bundle). CPU rendering is used as fallback.

---

## 2. Complete Architecture

```
                     macOS 26 ARM64 Host
    ┌─────────────────────────────────────────────┐
    │  RosettaSim.app (ARM64 native SwiftUI)      │
    │  ├─ Reads /tmp/rosettasim_framebuffer       │
    │  ├─ Displays simulated iPhone screen        │
    │  └─ Writes touch/keyboard to input region   │
    └───────────────┬─────────────────────────────┘
                    │ mmap (shared memory, 4MB BGRA)
    ┌───────────────┴─────────────────────────────┐
    │  HA Dashboard.app (x86_64 via Rosetta 2)    │
    │  ├─ DYLD_INSERT_LIBRARIES=bridge.dylib      │
    │  ├─ DYLD_ROOT_PATH=iOS 10.3 SDK            │
    │  ├─ Bridge: UIKit lifecycle, CPU rendering   │
    │  ├─ NSURLProtocol: HTTP via BSD sockets      │
    │  ├─ Touch: IOHIDEvent + gesture recognizers  │
    │  ├─ Keyboard: insertText via UIFieldEditor   │
    │  ├─ WebSocket: SRWebSocket (native TCP)      │
    │  └─ Auth: OAuth2 + Trusted Networks          │
    └───────────────┬─────────────────────────────┘
                    │ TCP/HTTP/WebSocket
    ┌───────────────┴─────────────────────────────┐
    │  Home Assistant Server (192.168.1.162:8123)  │
    │  ├─ REST API: /auth/providers, /auth/token   │
    │  ├─ WebSocket: real-time state updates        │
    │  ├─ Camera proxy: MJPEG frame delivery       │
    │  └─ 2086 entities, 23 areas, 52 cards        │
    └─────────────────────────────────────────────┘
```

---

## 3. What Works End-to-End

| Feature | Status | Evidence |
|---------|--------|----------|
| Login screen rendering | **WORKING** | 30fps, full UI with constellation animation, tintColor, fonts |
| mDNS server discovery | **WORKING** | Found "Home" at homeassistant.local:8123 v2026.2.2 |
| Touch input (IOHIDEvent) | **WORKING** | UIButton, UISegmentedControl, UITextField taps via gesture recognizers |
| Keyboard input (insertText) | **WORKING** | Characters delivered via UIFieldEditor, text visible in fields |
| HTTP networking | **WORKING** | NSURLProtocol bypass via BSD sockets, all auth requests succeed |
| Trusted Networks auth | **WORKING** | Auto-detected, auto-selected, auto-connected |
| OAuth2 token exchange | **WORKING** | Auth code → access/refresh tokens via POST /auth/token |
| WebSocket connection | **WORKING** | SRWebSocket connects, authenticates, receives state updates |
| Lovelace dashboard | **WORKING** | 52 cards loaded, rendered at 30fps |
| Sensor data | **WORKING** | Temperature (21.65°C), zone controls, lighting buttons |
| Camera feeds | **WORKING** | Two cameras streaming real-time images via proxy |
| Keychain | **WORKING** | Auth credentials stored and read |
| NSUserDefaults | **WORKING** | App preferences persist |
| Background animations | **WORKING** | Constellation dots and lines animate |

---

## 4. What Doesn't Work Yet

| Feature | Status | Root Cause | Fix |
|---------|--------|------------|-----|
| Scroll/pan | **CRASHES** | siglongjmp from scroll deceleration corrupts autorelease pool | Remove siglongjmp crash guards; use @try/@catch only. With CARenderServer connected, scroll internals may not crash. |
| GPU rendering | **NOT COMPOSITING** | App not registered as display client with CARenderServer | Build HID System Manager bundle or proxy display services through broker |
| On-screen keyboard | **MISSING** | UIKeyboardImpl suppressed (returns nil) to prevent hang | Build HID System Manager bundle for native keyboard delivery |
| First responder | **UNRELIABLE** | becomeFirstResponder sometimes fails due to UIKeyboardImpl=nil | Fix UIKeyboardImpl to return a functional instance |
| HTTPS | **NOT IMPLEMENTED** | NSURLProtocol only handles HTTP (no TLS) | Add TLS via SecureTransport or raw OpenSSL for HTTPS requests |
| Connect button | **NOT TAPPABLE** | Button outside card's clipsToBounds area | Auto-connect workaround in place; permanent fix: adjust card constraints |

---

## 5. Bridge Component Sizes

| File | Lines | Session 10 | Change |
|------|-------|-----------|--------|
| `src/bridge/rosettasim_bridge.m` | 5,927 | 4,547 | +1,380 lines |
| `src/bridge/purple_fb_server.c` | 1,135 | 1,136 | -1 line |
| `src/bridge/rosettasim_broker.c` | 862 | 741 | +121 lines |
| **Total** | **7,924** | **6,424** | **+1,500 lines** |

### New Interpositions Added (Session 11)

| # | Function | Purpose |
|---|----------|---------|
| 20 | `SCNetworkReachabilityCreateWithAddress` | Fake ref (always valid) |
| 21 | `SCNetworkReachabilityCreateWithName` | Fake ref (always valid) |
| 22 | `SCNetworkReachabilityGetFlags` | Always reachable |
| 23 | `SCNetworkReachabilitySetCallback` | Accept, no-op |
| 24 | `SCNetworkReachabilityScheduleWithRunLoop` | No-op |
| 25 | `SCNetworkReachabilityUnscheduleFromRunLoop` | No-op |
| 26 | `SCDynamicStoreCreate` | Fake ref |
| 27 | `SCDynamicStoreCopyProxies` | Empty dict (no proxy) |

### New ObjC Swizzles Added (Session 11)

| # | Class.method | Purpose |
|---|-------------|---------|
| 15 | `UIViewController.presentViewController:animated:completion:` | UIAlertController auto-select first action |
| 16 | `__NSCFURLSessionConfiguration.protocolClasses` | Inject RosettaSimURLProtocol |
| 17 | `NSURLSession.dataTaskWithRequest:completionHandler:` | Direct HTTP via BSD sockets |

---

## 6. How to Run

### Standalone Mode (simplest, proven working)

```bash
cd ~/Projects/rosetta

# Build
bash scripts/build_bridge.sh --force

# Run with DNS mapping for .local hostname resolution
ROSETTASIM_DNS_MAP="homeassistant.local=192.168.1.162" \
bash scripts/run_sim.sh ~/Projects/hass-dashboard/build/rosettasim/Build/Products/Debug-iphonesimulator/HA\ Dashboard.app

# In another terminal, take screenshot:
python3 tests/fb_screenshot.py /tmp/screenshot.png

# Send a tap (coordinates in iOS points):
python3 -c "
import struct, time, mmap, os
path = '/tmp/rosettasim_framebuffer'
fd = os.open(path, os.O_RDWR)
mm = mmap.mmap(fd, 0)
wi_off = 64; ring_off = 72; esz = 32
wi = struct.unpack('<Q', mm[wi_off:wi_off+8])[0]
# BEGAN (phase=1)
s = wi % 16; off = ring_off + s * esz
mm[off:off+esz] = struct.pack('<IffiQ4x', 1, 187.0, 270.0, 1, int(time.time()*1e6))
struct.pack_into('<Q', mm, wi_off, wi+1)
time.sleep(0.15)
# ENDED (phase=3)
wi = struct.unpack('<Q', mm[wi_off:wi_off+8])[0]
s = wi % 16; off = ring_off + s * esz
mm[off:off+esz] = struct.pack('<IffiQ4x', 3, 187.0, 270.0, 1, int(time.time()*1e6))
struct.pack_into('<Q', mm, wi_off, wi+1)
mm.close(); os.close(fd)
"
```

### Full Pipeline Mode (broker + backboardd + CARenderServer)

```bash
# Build everything
bash scripts/build_purple_fb.sh
bash scripts/build_broker.sh
bash scripts/build_bridge.sh --force

# Run (auto-builds if needed)
ROSETTASIM_DNS_MAP="homeassistant.local=192.168.1.162" \
bash scripts/run_full.sh
```

### Environment Variables

| Variable | Purpose | Example |
|----------|---------|---------|
| `ROSETTASIM_DNS_MAP` | Map .local hostnames to IPs | `homeassistant.local=192.168.1.162` |
| `ROSETTASIM_CA_MODE` | CARenderServer mode | `server` (auto when broker), `cpu` (force CPU) |
| `ROSETTASIM_DEVICE_PROFILE` | Device dimensions | `iphone6s`, `ipad`, `iphonese` |
| `ROSETTASIM_SCREEN_WIDTH` | Override width (points) | `375` |
| `ROSETTASIM_SCREEN_HEIGHT` | Override height (points) | `667` |
| `ROSETTASIM_SCREEN_SCALE` | Override scale | `2.0` |
| `ROSETTASIM_FB_PATH` | Framebuffer path | `/tmp/rosettasim_framebuffer` |
| `ROSETTASIM_EXCEPTION_MODE` | Exception handling | `verbose`, `quiet`, `strict` |

---

## 7. Touch Event Protocol

Touch events use the v3 framebuffer format (ring buffer at offset 64):

```
Offset 64: touch_write_index (uint64_t) — host increments after each event
Offset 72: touch_ring[16] — 16 slots × 32 bytes each

Each slot (32 bytes):
  uint32_t phase;     // 1=BEGAN, 2=MOVED, 3=ENDED (NOT 0!)
  float    x;         // iOS points (0-375 for iPhone 6s)
  float    y;         // iOS points (0-667 for iPhone 6s)
  uint32_t id;        // touch identifier (usually 1)
  uint64_t timestamp; // microseconds since epoch
  uint8_t  pad[4];    // padding to 32 bytes
```

**Critical:** Phase 0 = NONE (no-op, silently skipped). Use phase 1 for BEGAN.

---

## 8. HTTP Networking Architecture

```
App calls NSURLSession.dataTaskWithRequest:completionHandler:
  │
  ├─ Swizzled method intercepts the call
  │   ├─ Extracts URL, method, headers, body
  │   ├─ Resolves hostname:
  │   │   ├─ ROSETTASIM_DNS_MAP lookup (for .local domains)
  │   │   └─ getaddrinfo fallback (for regular domains)
  │   ├─ TCP connect via BSD socket()
  │   ├─ Sends HTTP/1.1 request
  │   ├─ Receives and parses response
  │   ├─ Creates NSHTTPURLResponse + NSData
  │   └─ Invokes completionHandler on main queue
  │
  └─ Also registered as NSURLProtocol (backup path)
      └─ RosettaSimURLProtocol.canInitWithRequest: → YES for HTTP
```

---

## 9. Next Steps (Priority Order)

### Priority 1: Fix Scroll

The dashboard shows the first screenful but can't scroll. The crash is in scroll deceleration code that uses CARenderServer internals. With CARenderServer connected (via broker), the deceleration code might work. Test with `ROSETTASIM_CA_MODE=server`.

If it still crashes, remove the siglongjmp crash guards and replace with @try/@catch. The autorelease pool corruption from siglongjmp is the root cause.

### Priority 2: HID System Manager Bundle

Build a custom x86_64 `.bundle` that:
1. Conforms to `SimulatorClientHIDSystemManager` protocol
2. Creates virtual IOHIDServices (touch, keyboard, buttons)
3. Reads from the shared framebuffer input region
4. Dispatches IOHIDEvents through IOHIDEventSystem

Set `SIMULATOR_HID_SYSTEM_MANAGER=/path/to/bundle` in backboardd's environment. This would:
- Enable native touch/keyboard through the real IOHIDEventSystem
- Potentially fix CARenderServer display client registration
- Enable GPU-accelerated rendering (eliminating CPU renderInContext)

### Priority 3: HTTPS Support

The NSURLProtocol only handles HTTP. If the HA server requires HTTPS:
- Add TLS via `SSLCreateContext` / `SSLHandshake` (SecureTransport, available in iOS SDK)
- Or use raw `SSL_*` functions from OpenSSL
- Or configure the HA server to allow HTTP for local connections

### Priority 4: iPad Mode

Change device profile to iPad for the target iPad 2 simulation:
```bash
ROSETTASIM_DEVICE_PROFILE=ipad bash scripts/run_sim.sh ...
```
This sets screen to 768×1024 @2x (1536×2048 pixels). The framebuffer size increases to ~12MB.

---

## 10. Gotchas for the Next Agent

1. **Touch phase constants**: 1=BEGAN, 2=MOVED, 3=ENDED. Phase 0 is NONE (skipped). The bridge drops MOVED/ENDED without a preceding BEGAN.

2. **DNS for .local domains**: `getaddrinfo` cannot resolve `.local` mDNS hostnames inside the simulator. Use `ROSETTASIM_DNS_MAP=hostname=ip` to provide explicit mappings.

3. **NSURLSession swizzle is the primary HTTP path**: The NSURLProtocol registration works but NSURLSession's completion handler integration is unreliable under Rosetta 2. The direct swizzle of `dataTaskWithRequest:completionHandler:` is the proven path.

4. **UIAlertController needs ivar access**: The auto-select reads `_handler` ivar from UIAlertAction. If the ivar name changes in a different iOS version, this breaks.

5. **Auto-connect fires 2 seconds after /auth/providers**: This delay allows the UI to update with auth modes. Too short and the form isn't ready; too long and the user notices the pause.

6. **The Connect button IS in the view hierarchy** but outside the card's clipsToBounds. Don't waste time trying to fix tap coordinates — the auto-connect workaround bypasses this entirely.

7. **HTTPBody is stripped by NSURLProtocol**: When NSURLProtocol intercepts a request, `HTTPBody` is nil. Read from `HTTPBodyStream` instead for POST bodies.

8. **Camera feeds work via HTTP proxy**: The app fetches camera images via `GET /api/camera_proxy/{entity_id}` which returns JPEG data. These requests go through our NSURLProtocol and render as UIImageView content.

---

## 11. Session Statistics

| Metric | Value |
|--------|-------|
| Session duration | ~8 hours |
| Commits | 2 |
| Lines added | +1,500 |
| New DYLD interpositions | 8 |
| New ObjC swizzles | 3 |
| HTTP requests verified | 5 (auth/providers, login_flow×2, auth/token, camera proxy) |
| Entities loaded | 2,086 |
| Dashboard cards | 52 |
| Camera feeds | 2 (live streaming) |
| Crashes | 0 (during full auth + dashboard flow) |
