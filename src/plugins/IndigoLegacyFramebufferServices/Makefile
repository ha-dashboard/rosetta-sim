# Makefile for IndigoLegacyFramebufferServices.simdeviceio plugin
#
# Builds a Mach-O bundle (MH_BUNDLE) that can be loaded by CoreSimulator.
# Links against CoreSimDeviceIO.framework for SimDeviceIOPortDescriptor, SimMachPort, etc.

PLUGIN_NAME = IndigoLegacyFramebufferServices
BUNDLE_DIR  = $(PLUGIN_NAME).simdeviceio/Contents

# CoreSimulator framework paths
CORESIM_FW  = /Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A
CORESIM_FRAMEWORKS = $(CORESIM_FW)/Frameworks

CC     = clang
CFLAGS = -fobjc-arc -fmodules \
         -arch arm64e \
         -Wall -Wextra -Wno-unused-parameter \
         -F$(CORESIM_FRAMEWORKS) \
         -I$(CORESIM_FRAMEWORKS)/CoreSimDeviceIO.framework/Headers \
         -mmacosx-version-min=14.0

LDFLAGS = -bundle \
          -arch arm64e \
          -framework Foundation \
          -framework IOSurface \
          -F$(CORESIM_FRAMEWORKS) \
          -Wl,-rpath,$(CORESIM_FRAMEWORKS) \
          -Wl,-undefined,dynamic_lookup

SRCS = IndigoLegacyFramebufferServices.m
OBJS = $(SRCS:.m=.o)

.PHONY: all clean install

all: $(BUNDLE_DIR)/MacOS/$(PLUGIN_NAME)

$(BUNDLE_DIR)/MacOS/$(PLUGIN_NAME): $(OBJS)
	@mkdir -p $(BUNDLE_DIR)/MacOS
	@cp Info.plist $(BUNDLE_DIR)/
	$(CC) $(LDFLAGS) -o $@ $(OBJS)
	@echo "Built: $@"

%.o: %.m
	$(CC) $(CFLAGS) -c -o $@ $<

clean:
	rm -rf $(OBJS) $(PLUGIN_NAME).simdeviceio

# Install into CoreSimulator's plugin directory (requires sudo)
install: all
	sudo cp -R $(PLUGIN_NAME).simdeviceio $(CORESIM_FW)/Resources/
	@echo "Installed to $(CORESIM_FW)/Resources/$(PLUGIN_NAME).simdeviceio"
	@echo "Restart CoreSimulator for changes to take effect:"
	@echo "  sudo launchctl kickstart -k system/com.apple.CoreSimulator.CoreSimulatorService"
