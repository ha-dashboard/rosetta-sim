# RosettaSim Implementation Plan — Session 5 Onwards

**Created**: 2026-02-20T15:58:12Z
**Updated**: 2026-02-20 (Session 6)
**Status**: All 17 items implemented in commit ca3e5b8. See `docs/SESSION_6_RESULTS.md` for detailed session results including the IOHIDEvent discovery that makes the native sendEvent pipeline work.

## Project Overview

RosettaSim runs legacy iOS 10.3 simulator apps on macOS 26 (ARM64 Apple Silicon) via Rosetta 2. The bridge library (`src/bridge/rosettasim_bridge.m`, ~2900 lines) is injected via `DYLD_INSERT_LIBRARIES` into the x86_64 simulator process and provides the services that UIKit expects from backboardd, SpringBoard, and CARenderServer.

**Current state (post-session 6)**: Native `sendEvent:` pipeline works with IOHIDEvent. Gesture recognizers fire. Text input via native `insertText:`. Touch ring buffer with zero event loss. However, `_force_full_refresh` rendering change caused visual regressions (segment colors lost, visual state destroyed). See SESSION_6_RESULTS.md for details and recommendations.

## Architecture

```
Host App (ARM64 native macOS)          Bridge (x86_64 Rosetta 2)
  NSView displays CGImage               Injected via DYLD_INSERT_LIBRARIES
  Mouse → mmap touch events             Polls mmap for touch/key input
  Keyboard → mmap key events            Creates UITouch, calls sendEvent:
  60fps poll of shared framebuffer       30fps renderInContext: → memcpy to mmap
```

**SDK**: `/Applications/Xcode-8.3.3.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator10.3.sdk`

**Key files**:
- `src/bridge/rosettasim_bridge.m` — the bridge (all interpositions, swizzles, touch/render/keyboard injection)
- `src/host/RosettaSimApp/RosettaSimApp.swift` — the host app (display, mouse/keyboard capture)
- `src/shared/rosettasim_framebuffer.h` — shared memory IPC format
- `docs/ARCHITECTURE.md` — full project architecture and session history

## How UIApplicationMain Currently Works

```
UIApplicationMain (interposed)
  → _UIApplicationMainPreparations:
    [1] BKSDisplayServicesStart        → INTERPOSED: returns TRUE + GSSetMainScreenInfo
    [2] CARenderServerGetServerPort    → INTERPOSED: returns MACH_PORT_NULL
    [3] BKSHIDEventRegister...         → INTERPOSED: no-op
    [4] UIApplication alloc+init       → succeeds (singleton created)
    [5] _GSEventInitializeApp          → bootstrap_register2 INTERPOSED: fakes success
    [6] _run                           → SWIZZLED to replacement_runWithMainScene
  → replacement_runWithMainScene:
    [6a] UIEventDispatcher created via initWithApplication: (by UIKit itself)
    [6b] Delegate's didFinishLaunchingWithOptions: called
    [6c] Lifecycle notifications posted
    [6d] Frame capture + run loop started
```

UIEventDispatcher IS properly created. UIGestureEnvironment exists. But touch delivery still fails because our touch injection bypasses gesture recognizer registration.

---

## WORK ITEMS — Each Needs Proper Implementation

### ITEM 1: CARenderServer

**File**: `rosettasim_bridge.m` line 204
**Current state**: `CARenderServerGetServerPort` returns `MACH_PORT_NULL`
**What breaks**: No CoreAnimation compositing pipeline. `[CADisplay mainDisplay]` returns nil. No implicit/explicit animations. No CADisplayLink. No GPU-backed content (Metal, OpenGL, video). The entire rendering is done via `renderInContext:` at 30fps — a CPU-only fallback.
**What proper implementation needs**: A local CARenderServer that handles `CA::Render::Server::create_context`, `commit_transaction`, and display link registration. Even a minimal server that provides a valid `CADisplay` object would unlock the normal CA compositing path.
**Dependencies**: This is the foundation — fixing this would eliminate the need for `_force_display_recursive`, the double-buffer hack, and the 30fps timer rendering.

### ITEM 2: Touch Injection via HID Events

**File**: `rosettasim_bridge.m` line 769 (`replacement_BKSHIDEventRegisterEventCallbackOnRunLoop`)
**Current state**: No-op. All touch input comes through manual mmap polling → UITouch creation → ivar manipulation → sendEvent:.
**What breaks**: Gesture recognizers don't fire because touches aren't registered with UIGestureEnvironment properly. UIButton tap, UITextField tap, UIScrollView pan — none work through the native pipeline.
**What proper implementation needs**: Either (a) make `_addTouch:forDelayedDelivery:NO` work reliably (it currently succeeds but sendEvent crashes on first 1-2 touches), or (b) create IOHIDEvents and deliver them through the GraphicsServices callback registered via `BKSHIDEventRegisterEventCallbackOnRunLoop`. Option (b) is the "real" approach — it's how Apple's simulator delivers input.
**Context**: `_addTouch:forDelayedDelivery:NO` now SUCCEEDS (UIGestureEnvironment exists) but `sendEvent:` crashes on the first 1-2 touches (signal 11). After those initial crashes (caught by SIGSEGV guard), subsequent `sendEvent:` calls succeed with gesture recognizers. The initial crash likely comes from gesture recognizer state that needs one-time initialization.

### ITEM 3: Hit Testing

**File**: `rosettasim_bridge.m` line 1019 (`_hitTestView`)
**Current state**: Custom recursive hit test that walks subviews, checks `userInteractionEnabled`, `hidden`, and `pointInside:withEvent:`.
**What breaks**: Does NOT call the view's own `hitTest:withEvent:` method (many UIKit views override this to expand/contract hit areas). Does NOT check `alpha < 0.01` (UIKit skips transparent views). UISegmentedControl width is hardcoded to 335pt for segment selection.
**What proper implementation needs**: Call `[view hitTest:point withEvent:event]` directly instead of reimplementing the algorithm. This respects custom hit test overrides, alpha thresholds, and all UIKit behaviors.

### ITEM 4: Window Management (makeKeyAndVisible)

**File**: `rosettasim_bridge.m` line 2419 (`replacement_makeKeyAndVisible`)
**Current state**: Manually sets layer.hidden=NO, loads rootVC view, calls viewWillAppear/viewDidAppear, sets `_bridge_root_window`.
**What breaks**: Only one window supported. UIAlertController, UIActionSheet, keyboard window — all present in separate UIWindows that never become key. No proper window ordering (UIWindowLevel).
**What proper implementation needs**: Track multiple windows. Support `makeKeyWindow`/`resignKeyWindow` lifecycle. Return the correct key window from `[UIApplication keyWindow]`. Handle UIWindowLevel for proper z-ordering.

### ITEM 5: isKeyWindow / keyWindow

**File**: `rosettasim_bridge.m` lines 2491-2498
**Current state**: `isKeyWindow` returns YES only for `_bridge_root_window`. `keyWindow` always returns `_bridge_root_window`.
**What breaks**: Same as ITEM 4 — any secondary window (alerts, keyboards) is never "key".
**What proper implementation needs**: Linked to ITEM 4 — a proper window stack with tracked key window state.

### ITEM 6: Storyboard/NIB Loading

**File**: `rosettasim_bridge.m` line 2607 (in `replacement_runWithMainScene`)
**Current state**: `_loadMainInterfaceFile` is explicitly skipped because it crashed with nil FBSScene.
**What breaks**: Any app that uses a main storyboard or nib shows a blank screen. This blocks Preferences.app and most real iOS apps.
**What proper implementation needs**: Call `_loadMainInterfaceFile` or manually load the storyboard from the app's Info.plist `UIMainStoryboardFile` key. The nil FBSScene crash needs investigation — it may work now that UIEventDispatcher is initialized.

### ITEM 7: Keyboard Infrastructure

**File**: `rosettasim_bridge.m` lines 2826-2842
**Current state**: `UIKeyboardImpl.sharedInstance` returns nil. `UIInputWindowController.sharedInputWindowController` returns nil. `BKSTextInputSessionManager` methods are no-op'd.
**What breaks**: No cursor/caret display in text fields. No text selection UI. No autocorrect. No input accessory views. `becomeFirstResponder` may work but with degraded visual feedback.
**What proper implementation needs**: A minimal UIKeyboardImpl that provides at least cursor display and text selection without requiring backboardd. The on-screen keyboard isn't needed (host provides hardware keyboard input via mmap), but the text interaction infrastructure is.

### ITEM 8: Keyboard Input Completeness

**File**: `rosettasim_bridge.m` line 1648 (`check_and_inject_keyboard`)
**Current state**: Handles regular characters, backspace, return, tab. Delivered via `insertText:`.
**What breaks**: No arrow keys, no Cmd+A/C/V, no UITextFieldDelegate `shouldChangeCharactersInRange:` check, no `UITextFieldTextDidChangeNotification` posted, no modifier key support.
**What proper implementation needs**: Handle arrow keys (move cursor), modifier combinations (select all, copy, paste), call delegate methods before text changes, post change notifications after.

### ITEM 9: Exception Handler

**File**: `rosettasim_bridge.m` line 2879 (`_rsim_exception_handler`)
**Current state**: Catches ALL uncaught ObjC exceptions, logs them, and silently continues.
**What breaks**: Real bugs are hidden. Objects left in inconsistent state. Memory leaks from skipped @finally cleanup. Makes debugging impossible.
**What proper implementation needs**: Log with full stack trace. Only catch known-safe UIKit initialization exceptions. Re-throw everything else. Or at minimum, make it configurable (verbose vs quiet mode).

### ITEM 10: Dual Initialization Path Cleanup

**File**: `rosettasim_bridge.m` lines 426-719 (`replacement_UIApplicationMain`)
**Current state**: The longjmp recovery path (lines 448-719) is a fallback that does manual initialization. The primary path goes through `replacement_runWithMainScene`. Both exist, creating risk of double `didFinishLaunchingWithOptions:` calls.
**What breaks**: Potential double initialization if the swizzle path partially runs then falls through.
**What proper implementation needs**: Either remove the fallback path entirely (if the swizzle path is reliable) or add a flag to prevent double execution.

### ITEM 11: Dead Code Removal

**Files**: `rosettasim_bridge.m` multiple locations
**Items**:
- `replacement_sendTouchesForEvent` (lines 2220-2280, 60 lines) — defined but never installed
- `replacement_UITextFieldBecomeFirstResponder` (lines 2294-2401, 107 lines) — defined but never installed
- `_last_key_code` (line 1646) — unused variable
- `_init_phase` (line 367) — written but never read
- `_force_display_recursive` redundant private class check (lines 920-926) — dead branch
**What proper implementation needs**: Remove all dead code. Update stale comments (lines 1604, 362-366, 773, 401-415).

### ITEM 12: BKSEventFocusManager

**File**: `rosettasim_bridge.m` line 2847
**Current state**: All methods matching `defer|register|fence|invalidate|client` replaced with no-ops.
**What breaks**: No event focus management. In multi-window scenarios, focus doesn't shift properly.
**What proper implementation needs**: A local event focus manager that tracks which window has focus and routes events accordingly.

### ITEM 13: BKSAnimationFenceHandle

**File**: `rosettasim_bridge.m` line 2847
**Current state**: All methods no-op'd.
**What breaks**: View controller transition animations may appear jumpy or incomplete — the animation commit fence is never signaled.
**What proper implementation needs**: A local animation fence that signals immediately (no inter-process coordination needed).

### ITEM 14: FBSWorkspace / FBSScene

**File**: `rosettasim_bridge.m` lines 2774-2799
**Current state**: `FBSWorkspace.init` and `FBSWorkspaceClient.initWithServiceName:endpoint:` return nil. No workspace, no scene.
**What breaks**: Scene-based lifecycle doesn't work. `_callInitializationDelegatesForMainScene:transitionContext:` crashes with nil scene. Apps using UIScene API get nil.
**What proper implementation needs**: A minimal FBSScene that provides the context UIKit expects during initialization. This would unlock `_callInitializationDelegatesForMainScene:` and proper storyboard loading (ITEM 6).

### ITEM 15: Device Configuration

**File**: `rosettasim_bridge.m` lines 112-116
**Current state**: Hardcoded to iPhone 6s (375x667 @2x).
**What breaks**: No support for other devices (iPad, iPhone Plus, etc.). No rotation support.
**What proper implementation needs**: Configurable device profiles read from environment variables or a config file.

### ITEM 16: exit()/_exit() Handling

**File**: `rosettasim_bridge.m` line 369
**Current state**: ALL exit calls blocked unconditionally. Background threads sleep via `select()`. Main thread returns from exit() (undefined behavior).
**What breaks**: Process can never cleanly terminate. The main thread UB case is a latent crash risk.
**What proper implementation needs**: Track the source of each exit call. For workspace disconnects, block. For real app exits (user-initiated), allow. For the main thread, use a proper mechanism instead of return-from-exit UB.

### ITEM 17: Rendering Pipeline

**File**: `rosettasim_bridge.m` lines 882 and 1887
**Current state**: `_force_display_recursive` walks layer tree calling `setNeedsDisplay`/`displayIfNeeded`. `frame_capture_tick` renders via `renderInContext:` into double-buffered malloc'd memory, then memcpy to shared mmap framebuffer.
**What breaks**: CPU-only rendering. No animations. No GPU content. No CADisplayLink. 30fps hardcoded. ~1 second latency for timer-driven updates (periodic force-display every 30 frames).
**What proper implementation needs**: If CARenderServer (ITEM 1) is implemented, most of this becomes unnecessary. Otherwise: improve force-display to be less invasive, support CADisplayLink via the render timer, and consider IOSurface for zero-copy frame sharing.

---

## Build & Test Commands

```bash
# Build bridge (x86_64, iOS simulator target)
bash scripts/build_bridge.sh

# Build host app (ARM64, native macOS)
bash src/host/RosettaSimApp/build.sh

# Run hass-dashboard
bash scripts/run_sim.sh "/tmp/rosettasim_hassdash/HA Dashboard.app"

# Build hass-dashboard from source
bash scripts/build_hassdash.sh

# Run any .app bundle
bash scripts/run_sim.sh /path/to/SomeApp.app

# Run Preferences.app (system app)
SDK="/Applications/Xcode-8.3.3.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator10.3.sdk"
bash scripts/run_sim.sh "$SDK/Applications/Preferences.app/Preferences"
```

## Session History

- **Session 1-2**: Phases 1-5 — SDK loading, framework calling, UIApplicationMain interception, renderInContext rendering, live display
- **Session 3**: Phase 6 — touch injection, UITouchesEvent infrastructure, double-buffer rendering, keyboard input
- **Session 4**: Phase 6d — touch reliability (6 bug fixes), bootstrap_register2 interposition, _runWithMainScene replacement, UIEventDispatcher creation, UITextField crash fix, process death fix, _addTouch:forDelayedDelivery:NO (gesture recognizer registration)

## Current Git State

```
fd9c41b feat: use real _touchesEvent singleton + _addTouch for gesture recognizers
28ad2dc fix: block all exit/_exit paths, process stays alive indefinitely
64a0124 fix: use select() instead of dispatch_semaphore for XPC thread suspension
2d3c6e7 feat: stub keyboard infrastructure, fix UITextField crash
9790c99 feat: remove sendEvent: and becomeFirstResponder swizzles
c2fbbcd feat: UIApplicationMain completes naturally with UIEventDispatcher
74296d0 feat: _runWithMainScene replacement + UIEventDispatcher creation
9e33f15 docs: update architecture with session 4 findings
7b7cfff feat: bootstrap_register2 interposition + workspace disconnect handling
548ee3b feat: sendEvent: swizzle, UITextField editing, touch reliability fixes
```
