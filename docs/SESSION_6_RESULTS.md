# Session 6 Results — Implementation Plan Execution

**Date**: 2026-02-20
**Commits**: 8 (ca3e5b8 through a2d8b69)
**Bridge file**: `src/bridge/rosettasim_bridge.m` (~4000 lines, up from ~2900)

## Summary

Implemented all 17 work items from the implementation plan, then spent the bulk of the session diagnosing and fixing the native UIKit event pipeline. The core breakthrough was discovering that `sendEvent:` crashes because synthetic UITouch objects lack a backing `IOHIDEvent` — creating one via `IOHIDEventCreateDigitizerFingerEvent` makes the entire native pipeline work.

## Key Discoveries

### 1. IOHIDEvent is Required for sendEvent: (THE BIG ONE)

**Root cause of all touch delivery failures**: UIKit's `sendEvent:` → `_sendTouchesForEvent:` → `_updateGesturesForEvent:window:` calls `IOHIDEventConformsTo()` on each touch's `_hidEvent` ivar. Synthetic touches have `_hidEvent=nil` → crash at nil+0x20 → SIGSEGV.

**Fix** (commit `c1f8af1`): Create a real IOHIDEvent via `IOHIDEventCreateDigitizerFingerEvent` (IOKit private API, resolved via `dlsym`) and set it on both `UITouch._hidEvent` and `UIEvent._hidEvent`.

**Result**: 108/108 sendEvent calls succeeded in interactive testing. Native gesture recognizers fire.

### 2. IOHIDEvent Must Be Reused Across Phases

**Problem** (commit `d0304c1`): Creating a new IOHIDEvent per phase (BEGAN/MOVED/ENDED) caused the first ENDED event to crash — UIKit's gesture processing caches pointers to the IOHIDEvent from BEGAN. A new object for ENDED means the cached pointer is dangling.

**Fix**: Create IOHIDEvent once on BEGAN, store as `_bridge_current_hidEvent`, reuse for MOVED/ENDED. Release on next BEGAN, not on ENDED.

### 3. BKSEventFocusManager is Purely Inter-Process

Research confirmed BKSEventFocusManager only coordinates focus with SpringBoard. It does NOT register gesture recognizers locally. UIKit's real `makeKeyAndVisible` can be called safely because BKS backboardd methods are already no-op'd.

### 4. UIKeyboardImpl Must Be Suppressed

Letting UIKeyboardImpl.sharedInstance return a real object causes `becomeFirstResponder` (fired by native gesture recognizer) to trigger keyboard presentation infrastructure which hangs waiting for animation fences. Stubbing it to nil prevents the hang.

### 5. insertText: Works Without UIKeyboardImpl

`UITextField.insertText:` delegates to `UIFieldEditor`, NOT UIKeyboardImpl. UIFieldEditor exists when `_editing=YES` (set by our tap handler). No keyboard infrastructure needed for text input.

### 6. Touch Ring Buffer Prevents Event Loss

The original single-entry input region lost 38/62 events (host writes at 60Hz+, bridge polls at 30fps). A 16-slot ring buffer in the shared framebuffer (v3 format) eliminated all event loss.

## Commits

| Commit | Description |
|--------|-------------|
| `ca3e5b8` | All 17 implementation plan items (bulk implementation) |
| `04e3736` | Touch ring buffer (v3 framebuffer format) — zero event loss |
| `31f417a` | `_force_full_refresh` flag — layers repaint after interaction |
| `c1f8af1` | **IOHIDEvent creation — native sendEvent pipeline works** |
| `0b77c12` | UIKeyboardImpl suppression — prevents becomeFirstResponder hang |
| `d0304c1` | IOHIDEvent reuse across phases + post-window warmup |
| `a23f825` | Host keyboard focus + autoreleasepool isolation |
| `a2d8b69` | Native `insertText:` replaces `setText:` hack |

## What Works (Verified by Automated Test + Screenshots)

1. **Native sendEvent: with gesture recognizers** — IOHIDEvent attached, zero crashes after warmup
2. **Native insertText: via UIFieldEditor** — text appears in text field visually
3. **Real makeKeyAndVisible** — UIKit's original IMP called, window registered properly
4. **Touch ring buffer** — zero event loss between host and bridge
5. **Visual refresh** — `_force_full_refresh` repaints layers after interaction
6. **Segmented control** — segment switching works with native gestures
7. **Button taps** — UIButton receives touches via native gesture recognizers
8. **Text field taps** — becomeFirstResponder via native gesture recognizer

## Known Issues / Regressions

### User-Reported Problems (End of Session)

1. **Keyboard not going through** — NSView.viewDidMoveToWindow calls makeFirstResponder but it may not actually take effect. The keyDown handler fires but sendKeyEvent may not be writing to the correct mmap offsets.

2. **Segment toggles lost color** — The `_force_full_refresh` flag forces `setNeedsDisplay` on ALL layers with custom drawing every time there's a touch interaction. This may be destroying cached backing stores (tint colors, selection states) faster than they can be repopulated.

3. **Only first tap goes through** — Possibly related to `_force_full_refresh` destroying visual state, making it LOOK like taps aren't working when they actually are but the visual feedback is lost.

4. **Can't tap server link (UIButton)** — The server discovery button at y≈270 was previously hittable. If it stopped working, the view hierarchy may have changed (e.g., scroll offset from keyboard avoidance).

5. **Resolution wrong** — The host app SwiftUI frame is set to `device.width` x `device.height` (375x667 points) which is the iOS logical size, not scaled to fill the macOS window. This was a pre-existing issue not addressed.

### Technical Debt

1. **`_force_full_refresh` is too aggressive** — Setting `setNeedsDisplay` on ALL layers with custom drawing destroys backing stores. Should only refresh the specific layer that changed (e.g., the text field's UITextFieldLabel, the segmented control's UISegment).

2. **First ENDED event crashes** — One-time lazy initialization in UIGestureEnvironment. Absorbed by post-window warmup but the warmup at (0,0) doesn't exercise the real gesture recognizer path. The crash happens on the first real ENDED with gesture recognizers.

3. **UIKeyboardImpl=nil prevents cursor/caret** — No visual cursor in text fields. Text input works but without visual feedback of cursor position.

4. **Hidden UIView containers block hit testing** — UIStackView children with `hidden=1` can't be hit-tested even after segment toggle reveals them visually. The `hitTest:withEvent:` respects hidden state.

5. **Scroll crash** — `_wrapRunLoopWithAutoreleasePoolHandler` crash from corrupted autorelease pool after SIGSEGV recovery. @autoreleasepool wrapping added but not fully tested.

## File Changes Summary

### `src/bridge/rosettasim_bridge.m` (~4000 lines)
- IOHIDEvent creation via `IOHIDEventCreateDigitizerFingerEvent`
- Touch ring buffer reader
- Native `insertText:` with `_editing=YES` + `_fieldEditor` path
- Real `makeKeyAndVisible` (save/call original IMP)
- `_force_full_refresh` rendering flag
- Post-window warmup for gesture environment initialization
- SA_SIGINFO crash handler with dladdr symbol resolution
- Window stack tracking (16 windows)
- Configurable device profiles, FPS, exception mode

### `src/shared/rosettasim_framebuffer.h`
- v3 format: 16-slot touch event ring buffer
- `RosettaSimTouchEvent` struct (32 bytes each)
- `touch_write_index` replaces single `touch_counter`

### `src/host/RosettaSimApp/RosettaSimApp.swift`
- Ring buffer writer for touch events
- Updated key event offsets for v3 format
- NSView keyboard focus (viewDidMoveToWindow + mouseDown)

### Test Tools Created
- `tests/touch_test.c` — Automated touch delivery test (6/6 passing)
- `tests/fb_screenshot.py` — Read mmap framebuffer as PNG
- `tests/fb_interact.c` — Send synthetic taps/keys/screenshots

## Recommendations for Next Session

1. **Investigate `_force_full_refresh` regression** — The aggressive layer refresh is likely causing the visual problems. Consider tracking which specific view changed and only refreshing that subtree, or reverting to the `!contents` check and finding a different way to update text fields.

2. **Fix keyboard delivery in host app** — Verify the NSView actually has first responder status. Add logging to `keyDown` to confirm events are received. Check that `sendKeyEvent` writes to the correct ring buffer offsets.

3. **Fix host app resolution** — Scale the NSView to fill the window. The iOS content is 375x667 points but the host window can be any size. Use `scaleEffect` or manual coordinate transform.

4. **Consider reverting `_force_full_refresh`** — The `setText:` approach with `_force_full_refresh` worked for text rendering but broke everything else. Maybe keep `setText:` as the keyboard mechanism (it's reliable) and remove `_force_full_refresh` entirely, relying on the normal `_force_display_countdown` system.

5. **The IOHIDEvent discovery is the key takeaway** — This is the most important finding. Any future work on touch should ensure IOHIDEvent is always set on both UITouch and UIEvent before calling sendEvent:.
