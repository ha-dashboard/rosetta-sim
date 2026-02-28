# Makefile for legacy iOS simulator tools (rosettasim)
#
# Source layout:
#   daemon/     — rosettasim_daemon.m
#   display/    — sim_display_inject.m (injection dylib for Simulator.app)
#   screenshot/ — fb_to_png.m, rosettasim_screenshot_plugin.m
#   scale/      — sim_scale_fix.m (scale fix dylib)
#   bridge/     — purple_fb_bridge.m, bridge_compat_stubs.m, bridge_wrapper.c
#   viewer/     — sim_viewer.m (standalone viewer)
#   touch/      — sim_touch_inject.m (backboardd touch/keyboard injection)
#   tools/      — rosettasim_ctl.m, sim_app_installer.m
#
# Build outputs go to build/ (gitignored).
#
# Usage:
#   make              # build all
#   make deploy       # build all + deploy to iOS 9.3 and 10.3 runtimes
#   make clean        # remove build artifacts

# IMPORTANT: Use /usr/bin/cc, NOT cc (shell alias hangs in this environment)
CC = /usr/bin/cc

BUILD = build

CFLAGS_COMMON = -fobjc-arc -fmodules -arch arm64e -Wall -Wextra -Wno-unused-parameter -I.

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

# rosettasim-ctl: simctl replacement for legacy devices
CTL_SRC       = tools/rosettasim_ctl.m
CTL_BIN       = $(BUILD)/rosettasim-ctl

# Screenshot plugin: simdeviceio companion
PLUGIN_SRC    = screenshot/rosettasim_screenshot_plugin.m
PLUGIN_BIN    = $(BUILD)/RosettaSimScreenshot.simdeviceio/Contents/MacOS/RosettaSimScreenshot

IPHONE_SIM_SDK = $(shell xcrun --sdk iphonesimulator --show-sdk-path 2>/dev/null)

# Sim-side dylibs (x86_64, run under Rosetta 2 inside the simulator)
CFLAGS_SIM = -arch x86_64 -isysroot $(IPHONE_SIM_SDK) -mios-simulator-version-min=9.0 \
	-fobjc-arc -I. -Wl,-undefined,dynamic_lookup -Wl,-not_for_dyld_shared_cache

# Touch/keyboard injection dylib (loaded into backboardd)
TOUCH_INJECT_SRC = touch/sim_touch_inject.m
TOUCH_INJECT_BIN = $(BUILD)/sim_touch_inject.dylib

# App installer dylib (loaded into SpringBoard — install, launch, UIA touch)
APP_INSTALLER_SRC = tools/sim_app_installer.m
APP_INSTALLER_BIN = $(BUILD)/sim_app_installer.dylib

# Bridge compat stubs (loaded into CoreSimulatorBridge for legacy runtimes)
BRIDGE_STUBS_SRC = bridge/bridge_compat_stubs.m
BRIDGE_STUBS_BIN = $(BUILD)/bridge_compat_stubs.dylib

# Bridge wrapper (universal binary, dispatches to legacy or modern bridge)
BRIDGE_WRAPPER_SRC = tools/bridge_wrapper.c
BRIDGE_WRAPPER_BIN = $(BUILD)/bridge_wrapper

# Runtime root paths for deployment
RUNTIME_93 = $(HOME)/Library/Developer/CoreSimulator/Profiles/Runtimes/iOS_9.3.simruntime/Contents/Resources/RuntimeRoot
RUNTIME_10 = $(HOME)/Library/Developer/CoreSimulator/Profiles/Runtimes/iOS_10.3.simruntime/Contents/Resources/RuntimeRoot

.PHONY: all daemon inject bridge viewer scale_fix screenshot screenshot_plugin ctl \
	touch_inject app_installer bridge_stubs bridge_wrapper \
	deploy deploy_93 deploy_10 clean

all: daemon inject bridge viewer scale_fix screenshot screenshot_plugin ctl \
	touch_inject app_installer bridge_stubs bridge_wrapper

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

ctl: $(CTL_BIN)

$(CTL_BIN): $(CTL_SRC) | $(BUILD)
	$(CC) $(CFLAGS_COMMON) -framework Foundation -framework IOSurface -framework CoreGraphics \
		-framework ImageIO -framework UniformTypeIdentifiers \
		-Wl,-undefined,dynamic_lookup -o $@ $<
	@echo "Built: $@"

# --- Sim-side dylibs (x86_64) ---

touch_inject: $(TOUCH_INJECT_BIN)

$(TOUCH_INJECT_BIN): $(TOUCH_INJECT_SRC) | $(BUILD)
	$(CC) $(CFLAGS_SIM) -dynamiclib -framework Foundation -framework IOKit \
		-install_name /usr/lib/sim_touch_inject.dylib -o $@ $<
	@echo "Built: $@"

app_installer: $(APP_INSTALLER_BIN)

$(APP_INSTALLER_BIN): $(APP_INSTALLER_SRC) | $(BUILD)
	$(CC) $(CFLAGS_SIM) -dynamiclib -framework Foundation \
		-install_name /usr/lib/sim_app_installer.dylib -o $@ $<
	@echo "Built: $@"

bridge_stubs: $(BRIDGE_STUBS_BIN)

$(BRIDGE_STUBS_BIN): $(BRIDGE_STUBS_SRC) | $(BUILD)
	$(CC) $(CFLAGS_SIM) -dynamiclib -framework Foundation \
		-install_name /usr/lib/bridge_compat_stubs.dylib -o $@ $<
	@echo "Built: $@"

bridge_wrapper: $(BRIDGE_WRAPPER_BIN)

$(BRIDGE_WRAPPER_BIN): $(BRIDGE_WRAPPER_SRC) | $(BUILD)
	$(CC) -arch x86_64 -arch arm64 -o $@ $<
	@echo "Built: $@"

# --- Deploy to runtime roots ---
# Copies sim-side dylibs, codesigns for iOS 10.3, checks insert_dylib status.
# Usage: make deploy
# NOTE: insert_dylib into SpringBoard/backboardd is only done once (idempotent check).
#       iOS 10.3 binaries MUST be codesigned after insert_dylib modifies them.

deploy: deploy_93 deploy_10
	@echo ""
	@echo "=== Deploy complete ==="

deploy_93: touch_inject app_installer bridge_stubs
	@echo "--- Deploying to iOS 9.3 ---"
	@if [ ! -d "$(RUNTIME_93)" ]; then echo "iOS 9.3 runtime not found"; exit 0; fi
	cp $(TOUCH_INJECT_BIN) "$(RUNTIME_93)/usr/lib/sim_touch_inject.dylib"
	cp $(APP_INSTALLER_BIN) "$(RUNTIME_93)/usr/lib/sim_app_installer.dylib"
	cp $(BRIDGE_STUBS_BIN) "$(RUNTIME_93)/usr/lib/bridge_compat_stubs.dylib"
	@# Check if insert_dylib needed for backboardd
	@if ! otool -L "$(RUNTIME_93)/usr/libexec/backboardd" 2>/dev/null | grep -q sim_touch_inject; then \
		echo "  Injecting sim_touch_inject into backboardd..."; \
		echo y | insert_dylib --inplace --no-strip-codesig /usr/lib/sim_touch_inject.dylib \
			"$(RUNTIME_93)/usr/libexec/backboardd" 2>&1; \
	else \
		echo "  sim_touch_inject already in backboardd"; \
	fi
	@# Check if insert_dylib needed for SpringBoard
	@if ! otool -L "$(RUNTIME_93)/System/Library/CoreServices/SpringBoard.app/SpringBoard" 2>/dev/null | grep -q sim_app_installer; then \
		echo "  Injecting sim_app_installer into SpringBoard..."; \
		echo y | insert_dylib --inplace --no-strip-codesig /usr/lib/sim_app_installer.dylib \
			"$(RUNTIME_93)/System/Library/CoreServices/SpringBoard.app/SpringBoard" 2>&1; \
	else \
		echo "  sim_app_installer already in SpringBoard"; \
	fi
	@echo "  iOS 9.3 deploy done"

deploy_10: touch_inject app_installer bridge_stubs
	@echo "--- Deploying to iOS 10.3 ---"
	@if [ ! -d "$(RUNTIME_10)" ]; then echo "iOS 10.3 runtime not found"; exit 0; fi
	cp $(TOUCH_INJECT_BIN) "$(RUNTIME_10)/usr/lib/sim_touch_inject.dylib"
	cp $(APP_INSTALLER_BIN) "$(RUNTIME_10)/usr/lib/sim_app_installer.dylib"
	cp $(BRIDGE_STUBS_BIN) "$(RUNTIME_10)/usr/lib/bridge_compat_stubs.dylib"
	@# Codesign all sim dylibs (iOS 10.3 requires this)
	codesign --force --sign - "$(RUNTIME_10)/usr/lib/sim_touch_inject.dylib"
	codesign --force --sign - "$(RUNTIME_10)/usr/lib/sim_app_installer.dylib"
	codesign --force --sign - "$(RUNTIME_10)/usr/lib/bridge_compat_stubs.dylib"
	@# Check if insert_dylib needed for backboardd
	@if ! otool -L "$(RUNTIME_10)/usr/libexec/backboardd" 2>/dev/null | grep -q sim_touch_inject; then \
		echo "  Injecting sim_touch_inject into backboardd..."; \
		echo y | insert_dylib --inplace --no-strip-codesig /usr/lib/sim_touch_inject.dylib \
			"$(RUNTIME_10)/usr/libexec/backboardd" 2>&1; \
		codesign --force --sign - "$(RUNTIME_10)/usr/libexec/backboardd"; \
	else \
		echo "  sim_touch_inject already in backboardd"; \
	fi
	@# Check if insert_dylib needed for SpringBoard
	@if ! otool -L "$(RUNTIME_10)/System/Library/CoreServices/SpringBoard.app/SpringBoard" 2>/dev/null | grep -q sim_app_installer; then \
		echo "  Injecting sim_app_installer into SpringBoard..."; \
		echo y | insert_dylib --inplace --no-strip-codesig /usr/lib/sim_app_installer.dylib \
			"$(RUNTIME_10)/System/Library/CoreServices/SpringBoard.app/SpringBoard" 2>&1; \
		codesign --force --sign - "$(RUNTIME_10)/System/Library/CoreServices/SpringBoard.app/SpringBoard"; \
	else \
		echo "  sim_app_installer already in SpringBoard"; \
	fi
	@echo "  iOS 10.3 deploy done"

clean:
	rm -rf $(BUILD)
	@echo "Cleaned."
