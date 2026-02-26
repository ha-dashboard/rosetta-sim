/*
 * LegacyFBBundleInterface.m
 *
 * Bundle-level interface: creates port descriptors when devices boot.
 * Modeled after IndigoHIDLegacyServicesBundleInterface.
 */

#import "LegacyFBBundleInterface.h"
#import "LegacyFBDescriptor.h"
#import <os/log.h>

static os_log_t sLog;

@implementation LegacyFBBundleInterface

+ (void)initialize {
    if (self == [LegacyFBBundleInterface class]) {
        sLog = os_log_create("com.rosetta.LegacyFramebuffer", "Bundle");
    }
}

- (unsigned short)majorVersion { return 1; }
- (unsigned short)minorVersion { return 0; }

#pragma mark - SimDeviceIOBundleInterface

- (void)bundleLoadedWithOptions:(NSDictionary *)options {
    os_log(sLog, "LegacyFramebufferServices bundle loaded");
}

/*
 * Called by CoreSimulator to get the list of port descriptors this plugin provides.
 * We return a single LegacyFBDescriptor that will register the framebuffer server Mach service.
 */
- (NSArray *)createDefaultPortsForDevice:(id /* SimDeviceIOInterface */)device
                                   error:(NSError **)error
{
    os_log(sLog, "createDefaultPortsForDevice: creating LegacyFBDescriptor");

    LegacyFBDescriptor *descriptor = [[LegacyFBDescriptor alloc]
        initWithDevice:device
                 error:error];
    if (!descriptor) {
        os_log_error(sLog, "Failed to create LegacyFBDescriptor");
        return nil;
    }
    return @[descriptor];
}

- (BOOL)device:(id /* SimDeviceIOInterface */)device
  didCreatePort:(id /* SimDeviceIOPortInterface */)port
          error:(NSError **)error
{
    os_log(sLog, "device:didCreatePort: port created");
    return YES;
}

- (void)deviceWillBoot:(id /* SimDeviceIOInterface */)device
           withOptions:(NSDictionary *)options
                 error:(NSError **)error
{
    os_log(sLog, "deviceWillBoot");
}

- (void)deviceDidBoot:(id /* SimDeviceIOInterface */)device {
    os_log(sLog, "deviceDidBoot");
}

- (void)deviceWillShutdown:(id /* SimDeviceIOInterface */)device {
    os_log(sLog, "deviceWillShutdown");
}

- (void)deviceDidShutdown:(id /* SimDeviceIOInterface */)device {
    os_log(sLog, "deviceDidShutdown");
}

- (NSArray *)dependsOnPortIdentifiers {
    return @[];
}

@end
