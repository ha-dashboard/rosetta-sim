# Makefile for legacy iOS simulator display tools
#
# Source layout:
#   daemon/     — rosettasim_daemon.m
#   display/    — sim_display_inject.m (injection dylib)
#   screenshot/ — fb_to_png.m, rosettasim_screenshot_plugin.m
#   scale/      — sim_scale_fix.m (scale fix dylib)
#   bridge/     — purple_fb_bridge.m (PurpleFB bridge)
#   viewer/     — sim_viewer.m (standalone viewer)
#
# Build outputs go to build/ (gitignored).
#
# Usage:
#   make              # build all
#   make daemon       # build daemon only
#   make inject       # build injection dylib only
#   make bridge       # build bridge only
#   make viewer       # build viewer only
#   make clean        # remove build artifacts

# IMPORTANT: Use /usr/bin/cc, NOT cc (shell alias hangs in this environment)
CC = /usr/bin/cc

BUILD = build

CFLAGS_COMMON = -fobjc-arc -fmodules -arch arm64e -Wall -Wextra -Wno-unused-parameter

# Daemon: monitors all legacy devices, auto-registers PurpleFBServer on boot
DAEMON_SRC    = daemon/rosettasim_daemon.m
DAEMON_BIN    = $(BUILD)/rosettasim_daemon

# Injection dylib: loaded into Simulator.app via DYLD_INSERT_LIBRARIES
INJECT_SRC    = display/sim_display_inject.m
INJECT_BIN    = $(BUILD)/sim_display_inject.dylib

# Bridge: links IOSurface, loads CoreSimulator at runtime via dlopen
BRIDGE_SRC    = bridge/purple_fb_bridge.m
BRIDGE_BIN    = $(BUILD)/purple_fb_bridge

# Standalone viewer: native macOS window displaying the framebuffer
VIEWER_SRC    = viewer/sim_viewer.m
VIEWER_BIN    = $(BUILD)/sim_viewer

# Scale fix: x86_64 interpose dylib injected into sim processes
SCALE_SRC     = scale/sim_scale_fix.m
SCALE_BIN     = $(BUILD)/sim_scale_fix.dylib

# Screenshot tool: reads IOSurface or raw framebuffer, saves PNG
SCREENSHOT_SRC = screenshot/fb_to_png.m
SCREENSHOT_BIN = $(BUILD)/fb_to_png

# Screenshot plugin: simdeviceio companion
PLUGIN_SRC    = screenshot/rosettasim_screenshot_plugin.m
PLUGIN_BIN    = $(BUILD)/RosettaSimScreenshot.simdeviceio/Contents/MacOS/RosettaSimScreenshot

IPHONE_SIM_SDK = $(shell xcrun --sdk iphonesimulator --show-sdk-path 2>/dev/null)

.PHONY: all daemon inject bridge viewer scale_fix screenshot screenshot_plugin clean

all: daemon inject bridge viewer scale_fix screenshot screenshot_plugin

$(BUILD):
	@mkdir -p $(BUILD)

daemon: $(DAEMON_BIN)

$(DAEMON_BIN): $(DAEMON_SRC) | $(BUILD)
	$(CC) $(CFLAGS_COMMON) -framework Foundation -framework IOSurface -framework CoreGraphics \
		-Wl,-undefined,dynamic_lookup -o $@ $<
	@echo "Built: $@"

inject: $(INJECT_BIN)

$(INJECT_BIN): $(INJECT_SRC) | $(BUILD)
	$(CC) $(CFLAGS_COMMON) -dynamiclib -framework Foundation -framework AppKit \
		-framework IOSurface -framework QuartzCore -framework CoreGraphics -o $@ $<
	@echo "Built: $@"

bridge: $(BRIDGE_BIN)

$(BRIDGE_BIN): $(BRIDGE_SRC) | $(BUILD)
	$(CC) $(CFLAGS_COMMON) -framework Foundation -framework IOSurface \
		-Wl,-undefined,dynamic_lookup -o $@ $<
	@echo "Built: $@"

viewer: $(VIEWER_BIN)

$(VIEWER_BIN): $(VIEWER_SRC) | $(BUILD)
	$(CC) $(CFLAGS_COMMON) -framework Foundation -framework AppKit \
		-framework IOSurface -framework QuartzCore -framework CoreGraphics -o $@ $<
	@echo "Built: $@"

scale_fix: $(SCALE_BIN)

$(SCALE_BIN): $(SCALE_SRC) | $(BUILD)
	$(CC) -arch x86_64 -target x86_64-apple-ios9.0-simulator -isysroot $(IPHONE_SIM_SDK) \
		-shared -flat_namespace -undefined suppress \
		-framework Foundation -framework QuartzCore \
		-o $@ $<
	@echo "Built: $@"

screenshot: $(SCREENSHOT_BIN)

$(SCREENSHOT_BIN): $(SCREENSHOT_SRC) | $(BUILD)
	$(CC) -fobjc-arc -framework Foundation -framework CoreGraphics \
		-framework ImageIO -framework IOSurface -framework UniformTypeIdentifiers \
		-o $@ $<
	@echo "Built: $@"

screenshot_plugin: $(PLUGIN_BIN)

$(PLUGIN_BIN): $(PLUGIN_SRC) | $(BUILD)
	@mkdir -p $(BUILD)/RosettaSimScreenshot.simdeviceio/Contents/MacOS
	$(CC) $(CFLAGS_COMMON) -bundle -framework Foundation -framework IOSurface \
		-Wl,-undefined,dynamic_lookup -o $@ $<
	@/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string com.rosettasim.screenshot" \
		$(BUILD)/RosettaSimScreenshot.simdeviceio/Contents/Info.plist 2>/dev/null || true
	@/usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string RosettaSimScreenshot" \
		$(BUILD)/RosettaSimScreenshot.simdeviceio/Contents/Info.plist 2>/dev/null || true
	@/usr/libexec/PlistBuddy -c "Add :CFBundlePackageType string BNDL" \
		$(BUILD)/RosettaSimScreenshot.simdeviceio/Contents/Info.plist 2>/dev/null || true
	codesign --force --sign - $(BUILD)/RosettaSimScreenshot.simdeviceio
	@echo "Built: $(BUILD)/RosettaSimScreenshot.simdeviceio"

clean:
	rm -rf $(BUILD)
	@echo "Cleaned."
