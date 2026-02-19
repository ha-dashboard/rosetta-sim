# RosettaSim Host Application

Native ARM64 macOS application that displays the simulated iOS device screen.

## Overview

This is the **host** side of RosettaSim - a native macOS application written in SwiftUI that:
- Displays the rendered content from the simulated iOS process
- Provides device chrome (bezel) around the screen
- Will eventually handle input forwarding and process lifecycle management

## Architecture

```
┌─────────────────────────────────────┐
│  RosettaSim.app (ARM64 native)      │
│  ┌───────────────────────────────┐  │
│  │  SwiftUI Window               │  │
│  │  - Device chrome (bezel)      │  │
│  │  - Screen display (375x667)   │  │
│  │  - Toolbar controls           │  │
│  └───────────────────────────────┘  │
│                                     │
│  Reads: /tmp/rosettasim_text.png    │
│  (Later: /tmp/rosettasim_render.raw)│
└─────────────────────────────────────┘
```

## Current Implementation

### What Works
- ✅ Native ARM64 macOS app
- ✅ SwiftUI interface
- ✅ Device chrome (iPhone 6s bezel)
- ✅ PNG frame loading from `/tmp/rosettasim_text.png`
- ✅ "Capture Frame" button to refresh display
- ✅ Correct aspect ratio (375x667 - iPhone 6s)

### What's Planned
- ⏳ "Launch Sim" button (will spawn the x86_64 simulated process)
- ⏳ Raw BGRA frame reading from `/tmp/rosettasim_render.raw`
- ⏳ IOSurface-based frame sharing (zero-copy)
- ⏳ Mouse → touch event forwarding
- ⏳ Keyboard event forwarding
- ⏳ Device rotation
- ⏳ Process lifecycle management

## Building

```bash
cd /Users/ashhopkins/Projects/rosetta/src/host/RosettaSimApp
./build.sh
```

The build script:
- Compiles `RosettaSimApp.swift` with the system Swift compiler
- Links against AppKit and SwiftUI frameworks
- Produces a native ARM64 binary in `build/RosettaSim`
- Verifies the architecture

## Running

```bash
# From the build directory
./build/RosettaSim

# Or double-click in Finder
open ./build/RosettaSim
```

The app will:
1. Open a window with device chrome
2. Attempt to load `/tmp/rosettasim_text.png`
3. Display the rendered content (if available)
4. Show "No Frame Available" if no content exists yet

## Testing with Existing Rendered Content

If you've already run the bridge rendering test:

```bash
# Check if rendered PNG exists
ls -lh /tmp/rosettasim_text.png

# Launch the host app
./build/RosettaSim
```

Click "Capture Frame" to refresh the display if the content has changed.

## Frame Sharing Protocol (Current)

**Phase 1: File-based (current)**
- Simulated process writes PNG to `/tmp/rosettasim_text.png`
- Host app reads and displays on demand
- Simple but not real-time

**Phase 2: Raw BGRA (next)**
- Simulated process writes raw BGRA bitmap to `/tmp/rosettasim_render.raw`
- Host app reads, converts to NSImage, displays
- Format: 32-bit BGRA, 375×667 pixels = 1,000,500 bytes

**Phase 3: IOSurface (future)**
- Simulated process renders directly to IOSurface
- Host app displays via `CALayer.contents = IOSurface`
- Zero-copy, real-time rendering
- Requires Mach IPC for surface handle sharing

## File Structure

```
src/host/
├── README.md                    (this file)
└── RosettaSimApp/
    ├── RosettaSimApp.swift      (SwiftUI app source)
    ├── build.sh                 (build script)
    └── build/
        └── RosettaSim           (compiled binary)
```

## Dependencies

- macOS 26.x (ARM64 Apple Silicon)
- Swift compiler (comes with Xcode)
- AppKit framework
- SwiftUI framework

No third-party dependencies required.

## Next Steps

1. **Process spawning**: Implement "Launch Sim" button to spawn the x86_64 simulated process
2. **Raw frame reading**: Add support for reading `/tmp/rosettasim_render.raw`
3. **Auto-refresh**: Poll for frame updates or use FSEvents
4. **IOSurface migration**: Switch to zero-copy rendering
5. **Input forwarding**: Mouse/keyboard → touch/key events
6. **Process management**: Monitor, restart, kill simulated process

## Design Decisions

### Why SwiftUI?
- Modern, declarative UI
- Built-in support for native macOS controls
- Easy to add features (toolbar, settings, multiple windows)
- Good performance for display-only workload

### Why Single-File?
- Simple to build without Xcode project
- Easy to understand and modify
- No build system complexity
- Can be split later if needed

### Why PNG First?
- Validates the rendering pipeline end-to-end
- Easy to debug (can inspect the PNG file directly)
- No protocol complexity
- Migration path to raw/IOSurface is straightforward

## Known Limitations

- No real-time updates (manual refresh required)
- No input handling yet
- "Launch Sim" button not implemented
- No device rotation support
- No device selection (hardcoded to iPhone 6s)

These will be addressed in subsequent phases.
