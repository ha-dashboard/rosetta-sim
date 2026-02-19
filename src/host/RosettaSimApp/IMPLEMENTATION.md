# RosettaSim Host App - Implementation Details

## Overview

Native ARM64 macOS application built with SwiftUI to display the simulated iOS device screen.

## Architecture

### Components

```swift
// Main app structure
NSApplication (AppKit)
  └── AppDelegate
      └── NSWindow
          └── NSHostingView (SwiftUI bridge)
              └── ContentView (SwiftUI)
                  ├── Toolbar (HStack with buttons)
                  └── DeviceChromeView
                      └── Device screen display

// Frame loading
FrameLoader (ObservableObject)
  - Reads frame from filesystem
  - Converts to NSImage
  - Publishes to SwiftUI views
```

### Key Classes

#### `DeviceConfig`
```swift
struct DeviceConfig {
    let name: String    // "iPhone 6s"
    let width: Int      // 375 (logical points)
    let height: Int     // 667 (logical points)
    let scale: CGFloat  // 2.0 (@2x retina)
}
```

Defines the simulated device characteristics. Currently hardcoded to iPhone 6s, but designed for easy addition of other devices.

#### `FrameLoader`
```swift
class FrameLoader: ObservableObject {
    @Published var currentFrame: NSImage?

    func loadFrame()
    private func loadRawBGRA()
}
```

**Responsibilities:**
- Load rendered frames from filesystem
- Convert to NSImage for display
- Notify SwiftUI views when frame changes

**Current Implementation:**
- Tries to load PNG from `/tmp/rosettasim_text.png`
- Falls back to placeholder if no frame exists
- Future: will support raw BGRA and IOSurface

#### `DeviceChromeView`
```swift
struct DeviceChromeView: View {
    let device: DeviceConfig
    @ObservedObject var frameLoader: FrameLoader
}
```

**Responsibilities:**
- Render device bezel (dark rounded rectangle)
- Display screen content with correct aspect ratio
- Add device-specific UI elements (future: home button, notch, etc.)

**Design:**
- 40px horizontal padding (20px bezel on each side)
- 60px top padding (camera, speaker area)
- 60px bottom padding (home button area)
- 8px corner radius on screen
- Drop shadow for depth

#### `ContentView`
```swift
struct ContentView: View {
    let device = DeviceConfig.iPhone6s
    @StateObject private var frameLoader = FrameLoader()
}
```

**Responsibilities:**
- Main app UI layout
- Toolbar with controls
- Title bar text
- Frame loading lifecycle

**Toolbar Controls:**
- "Launch Sim" - disabled (future: spawn simulated process)
- "Capture Frame" - refreshes display from filesystem
- Device name display

## Build Process

### Compilation

```bash
swiftc -o RosettaSim \
    -framework AppKit \
    -framework SwiftUI \
    RosettaSimApp.swift
```

**Why single file?**
- No Xcode project needed
- Simple command-line build
- Easy to understand
- Fast iteration
- Can be split later if needed

**Why no Info.plist?**
- SwiftUI apps can run without it
- Not building an .app bundle yet
- Just a binary for now
- Will add bundle structure later for distribution

### Architecture Verification

The build script verifies the output is ARM64:

```bash
$ file build/RosettaSim
build/RosettaSim: Mach-O 64-bit executable arm64
```

**Critical:** This must be ARM64, not x86_64. The host app runs natively on Apple Silicon, while the simulated process runs as x86_64 under Rosetta 2.

## Frame Display Pipeline

### Current: PNG File Reading

```
Simulated Process (x86_64)
  → CoreGraphics rendering
    → CGImageWriteToFile()
      → /tmp/rosettasim_text.png

Host App (ARM64)
  → FrameLoader.loadFrame()
    → NSImage(contentsOfFile:)
      → SwiftUI Image view
        → Display on screen
```

**Latency:** ~100ms (file I/O overhead)
**Pros:** Simple, debuggable, proven to work
**Cons:** Not real-time, wasteful (encoding/decoding)

### Future: Raw BGRA Reading

```
Simulated Process (x86_64)
  → CoreGraphics rendering
    → Raw BGRA buffer
      → write() to /tmp/rosettasim_render.raw

Host App (ARM64)
  → read() raw file
    → Create CGImage from BGRA data
      → NSImage wrapper
        → Display
```

**Format:**
- 32-bit per pixel (BGRA8888)
- 375×667 pixels = 1,000,500 bytes per frame
- No compression

**Latency:** ~50ms (no codec overhead)
**Pros:** Faster than PNG, no codec
**Cons:** Still file I/O, not zero-copy

### Future: IOSurface Sharing

```
Simulated Process (x86_64)
  → Create IOSurface
    → Register with Mach bootstrap
      → Render directly to surface

Host App (ARM64)
  → Lookup IOSurface by name
    → CALayer.contents = IOSurface
      → Zero-copy display
```

**Latency:** <5ms (zero-copy GPU memory)
**Pros:** Real-time, efficient, correct approach
**Cons:** Requires Mach IPC setup, more complex

## SwiftUI Details

### Why SwiftUI?

**Advantages:**
- Declarative syntax (clear data flow)
- Automatic view updates via `@Published`/`@ObservedObject`
- Native macOS controls
- Easy to add features (menus, preferences, multiple windows)
- Modern, maintained by Apple

**Disadvantages:**
- Less control than AppKit
- Some AppKit features require bridging
- Debugging can be tricky

**Verdict:** Good fit for this use case. The display workload is simple, and SwiftUI handles it well. If we need more control (e.g., custom Metal rendering), we can always drop to AppKit.

### Bridging to AppKit

```swift
// AppDelegate is pure AppKit
class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!  // AppKit window

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Create SwiftUI view
        let contentView = ContentView()

        // Bridge to AppKit via NSHostingView
        window.contentView = NSHostingView(rootView: contentView)
    }
}
```

**Why not pure SwiftUI?**
- SwiftUI's `WindowGroup` doesn't give us enough control
- Need programmatic window creation for device chrome
- Future: multiple windows, custom window behavior

### Reactive State Management

```swift
// FrameLoader publishes changes
class FrameLoader: ObservableObject {
    @Published var currentFrame: NSImage?
}

// ContentView observes and re-renders
struct ContentView: View {
    @StateObject private var frameLoader = FrameLoader()
}
```

When `currentFrame` changes:
1. `@Published` notifies all observers
2. SwiftUI invalidates `ContentView`
3. View re-renders with new image
4. AppKit composites the updated layer tree

## Input Handling (Future)

### Mouse → Touch Translation

```swift
// Future implementation
extension DeviceChromeView {
    func onMouseDown(_ location: CGPoint) {
        // Convert window coordinates to device coordinates
        let deviceCoords = convertToDeviceSpace(location)

        // Create UITouch event
        let touchEvent = createTouchEvent(
            phase: .began,
            location: deviceCoords,
            timestamp: CACurrentMediaTime()
        )

        // Send to simulated process via Mach IPC
        sendInputEvent(touchEvent)
    }
}
```

**Coordinate systems:**
- Window space: AppKit coordinates (origin = bottom-left)
- Device space: UIKit coordinates (origin = top-left, scaled)

**Touch types:**
- began (mouse down)
- moved (mouse drag)
- ended (mouse up)
- cancelled (mouse exited window)

### Keyboard → UIKeyboard Events

Similar approach:
1. Capture NSEvent.keyDown/keyUp
2. Translate to UIKeyboard event structure
3. Send via Mach IPC to simulated process

## Process Management (Future)

### Launch Sequence

```swift
func launchSimulator() {
    // 1. Set up Mach bootstrap port subset
    let bootstrapPort = createBootstrapSubset()

    // 2. Set environment variables
    let env = [
        "DYLD_ROOT_PATH": sdkPath,
        "IPHONE_SIMULATOR_ROOT": sdkPath,
        "SIMULATOR_DEVICE_NAME": "iPhone 6s",
        // ... more vars
    ]

    // 3. Spawn process
    let process = Process()
    process.executableURL = URL(fileURLWithPath: appPath)
    process.environment = env
    process.launch()

    // 4. Monitor for frames
    startFrameMonitoring()
}
```

### Lifecycle Management

**States:**
- Not running
- Launching
- Running
- Suspended (future: simulate app backgrounding)
- Terminating

**Controls:**
- Launch (spawn process)
- Kill (SIGTERM → SIGKILL)
- Restart (kill + launch)
- Screenshot (capture current frame)

## Device Models (Future)

```swift
extension DeviceConfig {
    static let iPhone6s = DeviceConfig(
        name: "iPhone 6s", width: 375, height: 667, scale: 2.0)
    static let iPhone6sPlus = DeviceConfig(
        name: "iPhone 6s Plus", width: 414, height: 736, scale: 3.0)
    static let iPhone5s = DeviceConfig(
        name: "iPhone 5s", width: 320, height: 568, scale: 2.0)
    static let iPhoneSE = DeviceConfig(
        name: "iPhone SE", width: 320, height: 568, scale: 2.0)
}
```

**Selection UI:**
- Dropdown in toolbar
- Or menu: Device → iPhone 6s, iPhone 6s Plus, ...
- Changing device:
  - Resizes window
  - Updates environment variables
  - Restarts simulated process

## Performance Considerations

### Current Bottlenecks
1. **File I/O**: PNG encoding/decoding
2. **Manual refresh**: User must click button

### Optimization Path
1. Switch to raw BGRA (eliminates codec)
2. Add auto-refresh via FSEvents or timer
3. Migrate to IOSurface (eliminates file I/O)

### Expected Performance (with IOSurface)
- Frame latency: <5ms
- Throughput: 60 FPS (matches iOS display rate)
- Memory: Single IOSurface allocation (~1MB)

## Testing

### Manual Test
```bash
# 1. Generate a test frame
cd /Users/ashhopkins/Projects/rosetta/test/phase4
./run_test.sh render_to_png

# 2. Launch host app
cd /Users/ashhopkins/Projects/rosetta/src/host/RosettaSimApp
./run.sh

# 3. Verify
# - Window opens
# - Device chrome visible
# - Rendered text appears in screen area
# - Click "Capture Frame" refreshes display
```

### Automated Test (Future)
```swift
// XCTest suite
class RosettaSimHostTests: XCTestCase {
    func testFrameLoading() {
        // Create test PNG
        // Load via FrameLoader
        // Assert image properties
    }

    func testDeviceChrome() {
        // Render DeviceChromeView
        // Assert dimensions
    }
}
```

## File Locations

```
/tmp/rosettasim_text.png       - Rendered frame (PNG)
/tmp/rosettasim_render.raw     - Rendered frame (raw BGRA) [future]
/tmp/rosettasim_input.sock     - Input event socket [future]
/tmp/rosettasim_control.sock   - Control commands [future]
```

## Known Issues

1. **No error handling for missing frame**: App shows placeholder but doesn't indicate why
2. **Fixed device**: Cannot change device model at runtime
3. **Manual refresh**: Must click button to update
4. **No scaling**: Window is fixed size (cannot zoom in/out)
5. **No rotation**: Device is always portrait

All will be addressed in future iterations.

## Next Steps

1. **Raw BGRA support**: Implement `loadRawBGRA()` method
2. **Auto-refresh**: Poll `/tmp/` for file changes
3. **Launch button**: Spawn simulated process
4. **Process monitoring**: Detect when simulated app exits
5. **IOSurface migration**: Zero-copy frame sharing
6. **Input forwarding**: Mouse → touch events
7. **Device selection**: Dropdown to choose device model
8. **Rotation**: Landscape support
9. **Scaling**: Zoom in/out controls
10. **Settings panel**: Configure SDK path, device models, etc.
