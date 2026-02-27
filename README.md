# RosettaSim

Display bridge for legacy iOS simulators (iOS 7.0–13.7) on modern macOS (Apple Silicon).

Legacy simulators use the PurpleFBServer Mach protocol for framebuffer display, which modern Simulator.app no longer supports. RosettaSim bridges this gap by intercepting PurpleFBServer registrations, rendering framebuffer data to IOSurfaces, and injecting display code into Simulator.app.

## Quick Start

```bash
# Build the app (one-time):
./scripts/build_app.sh

# Then double-click RosettaSim.app in Finder!
# It starts the daemon and Simulator with display injection automatically.

# Or use the CLI:
./scripts/setup.sh              # one-time: build tools, create devices
./scripts/start_rosettasim.sh   # start daemon + Simulator

# Boot a legacy device from Simulator's menu or CLI
xcrun simctl boot <UDID>

# Screenshot (works for legacy devices)
./scripts/simctl io <UDID> screenshot output.png

# Stop
./scripts/start_rosettasim.sh --stop
```

## Prerequisites

- macOS with Apple Silicon (Rosetta 2)
- Xcode (modern, for SDK and Simulator.app)
- Legacy iOS simulator runtimes installed via `scripts/install_legacy_sim.sh`

### Optional: Xcode 8.3.3

For running Xcode 8.3.3 itself on modern macOS:
```bash
setup/setup_xcode833.sh    # patch Xcode 8.3.3
setup/install_sim93.sh     # install iOS 9.3 runtime
setup/launch_xcode833.sh   # launch
```

## Project Structure

```
RosettaSim.app             # Double-click to launch (built by scripts/build_app.sh)

src/                       # Source code
  daemon/                  # rosettasim_daemon — monitors devices, registers PurpleFBServer
  display/                 # sim_display_inject — DYLD_INSERT dylib for Simulator.app
  bridge/                  # purple_fb_bridge — standalone PurpleFBServer bridge
  screenshot/              # fb_to_png + screenshot plugin
  scale/                   # sim_scale_fix — 2x scale interpose for sim processes
  shims/                   # iOS 8.2 FrontBoard fix, iOS 13.7 SimFramebufferClient stub
  viewer/                  # sim_viewer — standalone framebuffer viewer
  Makefile                 # builds everything → src/build/

scripts/                   # Operational scripts
  build_app.sh             # builds RosettaSim.app (double-clickable)
  setup.sh                 # one-time build + device creation
  start_rosettasim.sh      # daemon + Simulator launcher
  install_legacy_sim.sh    # iOS runtime installer
  test_all_devices.sh      # E2E test across all legacy runtimes
  simctl                   # screenshot wrapper for legacy devices

setup/                     # Xcode 8.3.3 compatibility (optional)
  setup_xcode833.sh        # patches Xcode 8.3.3 for macOS 26
  install_sim93.sh         # iOS 9.3 runtime manual installer
  launch_xcode833.sh       # Xcode 8.3.3 launcher
  stubs/                   # PubSub, Python 2.7, AppKit compat stubs
```

## Building

```bash
cd src && make        # build all tools → src/build/
cd src && make clean  # remove build artifacts
```
