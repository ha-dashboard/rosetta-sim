/*
 * main.m — Plugin entry point
 *
 * Exports simdeviceio_get_interface(), the sole entry point for .simdeviceio bundles.
 * CoreSimulator calls this via dlsym after loading the bundle.
 */

#import <Foundation/Foundation.h>
#import "LegacyFBBundleInterface.h"
#import <os/log.h>

/*
 * Entry point called by CoreSimulator when loading the plugin bundle.
 * Must return YES and set *outInterface to our bundle interface object.
 */
__attribute__((visibility("default")))
BOOL simdeviceio_get_interface(id *outInterface) {
    static os_log_t sLog;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sLog = os_log_create("com.rosetta.LegacyFramebuffer", "Entry");
    });

    os_log(sLog, "simdeviceio_get_interface called");

    if (!outInterface) {
        return NO;
    }

    *outInterface = [[LegacyFBBundleInterface alloc] init];
    return (*outInterface != nil);
}
