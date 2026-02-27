# Makefile for legacy iOS simulator display tools
#
# Builds:
#   purple_fb_bridge       — PurpleFBServer bridge (registers with sim, handles framebuffer)
#   sim_display_inject.dylib — DYLD_INSERT injection for Simulator.app display
#   sim_viewer             — Standalone framebuffer viewer window
#
# Usage:
#   make              # build all
#   make bridge       # build bridge only
#   make inject       # build injection dylib only
#   make viewer       # build viewer only
#   make clean        # remove build artifacts

# IMPORTANT: Use /usr/bin/cc, NOT cc (shell alias hangs in this environment)
CC = /usr/bin/cc

CFLAGS_COMMON = -fobjc-arc -fmodules -arch arm64e -Wall -Wextra -Wno-unused-parameter

# Bridge: links IOSurface, loads CoreSimulator at runtime via dlopen
BRIDGE_SRC    = purple_fb_bridge.m
BRIDGE_BIN    = purple_fb_bridge
BRIDGE_CFLAGS = $(CFLAGS_COMMON)
BRIDGE_LDFLAGS = -framework Foundation -framework IOSurface -Wl,-undefined,dynamic_lookup

# Injection dylib: loaded into Simulator.app via DYLD_INSERT_LIBRARIES
INJECT_SRC    = sim_display_inject.m
INJECT_BIN    = sim_display_inject.dylib
INJECT_CFLAGS = $(CFLAGS_COMMON)
INJECT_LDFLAGS = -dynamiclib -framework Foundation -framework AppKit \
                 -framework IOSurface -framework QuartzCore -framework CoreGraphics

# Standalone viewer: native macOS window displaying the framebuffer
VIEWER_SRC    = sim_viewer.m
VIEWER_BIN    = sim_viewer
VIEWER_CFLAGS = $(CFLAGS_COMMON)
VIEWER_LDFLAGS = -framework Foundation -framework AppKit \
                 -framework IOSurface -framework QuartzCore -framework CoreGraphics

# Daemon: monitors all legacy devices, auto-registers PurpleFBServer on boot
DAEMON_SRC    = rosettasim_daemon.m
DAEMON_BIN    = rosettasim_daemon
DAEMON_CFLAGS = $(CFLAGS_COMMON)
DAEMON_LDFLAGS = -framework Foundation -framework IOSurface -framework CoreGraphics \
                 -Wl,-undefined,dynamic_lookup

# Scale fix: x86_64 interpose dylib injected into sim processes via insert_dylib
# Must be built with iOS simulator target or dyld_sim will reject it
SCALE_SRC     = sim_scale_fix.m
SCALE_BIN     = sim_scale_fix.dylib
# Screenshot tool: reads IOSurface or raw framebuffer, saves PNG
SCREENSHOT_SRC = fb_to_png.m
SCREENSHOT_BIN = fb_to_png

IPHONE_SIM_SDK = $(shell xcrun --sdk iphonesimulator --show-sdk-path 2>/dev/null)

.PHONY: all bridge inject viewer daemon scale_fix screenshot clean

all: bridge inject viewer daemon scale_fix screenshot

bridge: $(BRIDGE_BIN)

inject: $(INJECT_BIN)

viewer: $(VIEWER_BIN)

$(BRIDGE_BIN): $(BRIDGE_SRC)
	$(CC) $(BRIDGE_CFLAGS) $(BRIDGE_LDFLAGS) -o $@ $<
	@echo "Built: $@"

$(INJECT_BIN): $(INJECT_SRC)
	$(CC) $(INJECT_CFLAGS) $(INJECT_LDFLAGS) -o $@ $<
	@echo "Built: $@"

$(VIEWER_BIN): $(VIEWER_SRC)
	$(CC) $(VIEWER_CFLAGS) $(VIEWER_LDFLAGS) -o $@ $<
	@echo "Built: $@"

daemon: $(DAEMON_BIN)

$(DAEMON_BIN): $(DAEMON_SRC)
	$(CC) $(DAEMON_CFLAGS) $(DAEMON_LDFLAGS) -o $@ $<
	@echo "Built: $@"

screenshot: $(SCREENSHOT_BIN)

$(SCREENSHOT_BIN): $(SCREENSHOT_SRC)
	$(CC) -fobjc-arc -framework Foundation -framework CoreGraphics \
		-framework ImageIO -framework IOSurface -framework UniformTypeIdentifiers \
		-o $@ $<
	@echo "Built: $@"

scale_fix: $(SCALE_BIN)

$(SCALE_BIN): $(SCALE_SRC)
	$(CC) -arch x86_64 -target x86_64-apple-ios9.0-simulator -isysroot $(IPHONE_SIM_SDK) \
		-shared -flat_namespace -undefined suppress \
		-framework Foundation -framework QuartzCore \
		-o $@ $<
	@echo "Built: $@"

clean:
	rm -f $(BRIDGE_BIN) $(INJECT_BIN) $(VIEWER_BIN) $(DAEMON_BIN) $(SCALE_BIN) $(SCREENSHOT_BIN)
	@echo "Cleaned."
