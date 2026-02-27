/*
 * rosettasim_screenshot_plugin.m — simdeviceio companion plugin
 *
 * Adds framebufferSurface support to PurpleFBDescriptor so that
 * `xcrun simctl io <UDID> screenshot` works for legacy iOS simulators.
 *
 * This plugin loads alongside IndigoLegacyFramebufferServices.simdeviceio
 * in CoreSimulatorService. On load, it swizzles PurpleFBDescriptor to add
 * framebufferSurface / maskedFramebufferSurface methods that wrap the raw
 * vm_allocated framebuffer (_surfaceAddr) in an IOSurface.
 *
 * Build:
 *   See Makefile target 'screenshot_plugin'
 *
 * Install:
 *   sudo cp -R RosettaSimScreenshot.simdeviceio \
 *     /Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/Resources/
 *   sudo launchctl kickstart -k system/com.apple.CoreSimulator.CoreSimulatorService
 */

#import <Foundation/Foundation.h>
#import <IOSurface/IOSurface.h>
#import <objc/runtime.h>
#import <objc/message.h>

/* ================================================================
 * Associated-object key for per-instance cached IOSurface
 * ================================================================ */
static const void *kRosettaIOSurface = &kRosettaIOSurface;

/* ================================================================
 * framebufferSurface implementation — injected into PurpleFBDescriptor
 * ================================================================ */
static id rosetta_framebufferSurface(id self, SEL _cmd) {
    /* Check for cached IOSurface */
    id cached = objc_getAssociatedObject(self, kRosettaIOSurface);
    if (cached) {
        /* Update: memcpy latest pixel data from _surfaceAddr into IOSurface */
        IOSurfaceRef surf = (__bridge IOSurfaceRef)cached;
        Ivar addrIvar = class_getInstanceVariable([self class], "_surfaceAddr");
        if (addrIvar) {
            uint64_t addr = 0;
            memcpy(&addr, (char *)(__bridge void *)self + ivar_getOffset(addrIvar), sizeof(addr));
            if (addr) {
                size_t allocSize = IOSurfaceGetAllocSize(surf);
                IOSurfaceLock(surf, 0, NULL);
                memcpy(IOSurfaceGetBaseAddress(surf), (void *)addr, allocSize);
                IOSurfaceUnlock(surf, 0, NULL);
            }
        }
        return cached;
    }

    /* First call — read _surfaceAddr and create IOSurface */
    Ivar addrIvar = class_getInstanceVariable([self class], "_surfaceAddr");
    if (!addrIvar) {
        NSLog(@"[RosettaSim] framebufferSurface: _surfaceAddr ivar not found");
        return nil;
    }

    uint64_t surfaceAddr = 0;
    memcpy(&surfaceAddr, (char *)(__bridge void *)self + ivar_getOffset(addrIvar), sizeof(surfaceAddr));
    if (!surfaceAddr) {
        NSLog(@"[RosettaSim] framebufferSurface: _surfaceAddr is NULL (surface not created yet)");
        return nil;
    }

    /* Get dimensions from the descriptor state */
    id state = ((id(*)(id, SEL))objc_msgSend)(self, sel_registerName("state"));
    uint32_t width = 0, height = 0;

    if (state && [state respondsToSelector:sel_registerName("defaultWidthForDisplay")]) {
        width = ((uint32_t(*)(id, SEL))objc_msgSend)(state, sel_registerName("defaultWidthForDisplay"));
        height = ((uint32_t(*)(id, SEL))objc_msgSend)(state, sel_registerName("defaultHeightForDisplay"));
    }

    /* Fallback: common legacy device sizes */
    if (width == 0 || height == 0) {
        /* Default to iPhone 6s dimensions (750x1334) */
        width = 750;
        height = 1334;
        NSLog(@"[RosettaSim] framebufferSurface: no dimensions from state, using fallback %ux%u",
              width, height);
    }

    uint32_t bytesPerRow = width * 4;
    uint32_t allocSize = bytesPerRow * height;
    /* Round up to page size */
    allocSize = ((allocSize + 4095) / 4096) * 4096;

    NSLog(@"[RosettaSim] Creating IOSurface %ux%u (stride=%u, alloc=%u) from surfaceAddr=0x%llx",
          width, height, bytesPerRow, allocSize, surfaceAddr);

    NSDictionary *props = @{
        (id)kIOSurfaceWidth:           @(width),
        (id)kIOSurfaceHeight:          @(height),
        (id)kIOSurfaceBytesPerElement: @4,
        (id)kIOSurfaceBytesPerRow:     @(bytesPerRow),
        (id)kIOSurfacePixelFormat:     @(0x42475241), /* BGRA */
        (id)kIOSurfaceAllocSize:       @(allocSize),
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        (id)kIOSurfaceIsGlobal:        @YES,
#pragma clang diagnostic pop
    };

    IOSurfaceRef surf = IOSurfaceCreate((__bridge CFDictionaryRef)props);
    if (!surf) {
        NSLog(@"[RosettaSim] framebufferSurface: IOSurfaceCreate failed");
        return nil;
    }

    /* Copy current framebuffer data */
    IOSurfaceLock(surf, 0, NULL);
    memcpy(IOSurfaceGetBaseAddress(surf), (void *)surfaceAddr, allocSize);
    IOSurfaceUnlock(surf, 0, NULL);

    /* Cache on the descriptor instance */
    id surfObj = (__bridge id)surf;
    objc_setAssociatedObject(self, kRosettaIOSurface, surfObj, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    NSLog(@"[RosettaSim] IOSurface created (id=%u) for %@",
          IOSurfaceGetID(surf), [self class]);

    /* We hold one extra retain from IOSurfaceCreate; the associated object also retains.
     * Release our create-ref so the associated object is the sole owner. */
    CFRelease(surf);

    return surfObj;
}

/* ================================================================
 * Bundle interface — simdeviceio plugin entry point
 * ================================================================ */

@interface RosettaScreenshotBundleInterface : NSObject
@end

@implementation RosettaScreenshotBundleInterface

- (int)majorVersion { return 1; }
- (int)minorVersion { return 0; }

- (NSArray *)dependsOnPortIdentifiers {
    return @[@"com.apple.CoreSimulator.framebuffer.server"];
}

- (void)bundleLoadedWithOptions:(NSDictionary *)options {
    Class cls = objc_getClass("PurpleFBDescriptor");
    if (!cls) {
        NSLog(@"[RosettaSim] PurpleFBDescriptor not found — IndigoLegacy not loaded?");
        return;
    }

    /* Add framebufferSurface to PurpleFBDescriptor */
    BOOL added = class_addMethod(cls, sel_registerName("framebufferSurface"),
                                 (IMP)rosetta_framebufferSurface, "@@:");
    NSLog(@"[RosettaSim] Added framebufferSurface to PurpleFBDescriptor: %s",
          added ? "YES" : "NO (already exists)");

    class_addMethod(cls, sel_registerName("maskedFramebufferSurface"),
                    (IMP)rosetta_framebufferSurface, "@@:");

    /* Also conform to SimDisplayIOSurfaceRenderable protocol */
    Protocol *proto = objc_getProtocol("SimDisplayIOSurfaceRenderable");
    if (proto) {
        class_addProtocol(cls, proto);
        NSLog(@"[RosettaSim] Added SimDisplayIOSurfaceRenderable conformance");
    }

    /* Add no-op callback registration methods required by the protocol */
    class_addMethod(cls, sel_registerName("registerCallbackWithUUID:ioSurfacesChangeCallback:"),
                    imp_implementationWithBlock(^(id _self, id uuid, id callback) {}),
                    "v32@0:8@16@?24");
    class_addMethod(cls, sel_registerName("unregisterIOSurfacesChangeCallbackWithUUID:"),
                    imp_implementationWithBlock(^(id _self, id uuid) {}),
                    "v24@0:8@16");

    NSLog(@"[RosettaSim] Screenshot plugin loaded successfully");
}

- (BOOL)createDefaultPortsForDevice:(id)device error:(NSError **)error {
    /* We don't create ports — IndigoLegacy handles that */
    return YES;
}

- (BOOL)device:(id)device didCreatePort:(id)port error:(NSError **)error {
    return YES;
}

- (void)deviceDidBoot:(id)device {}
- (void)deviceDidShutdown:(id)device {}
- (BOOL)deviceWillBoot:(id)device withOptions:(id)options error:(NSError **)error {
    return YES;
}
- (void)deviceWillShutdown:(id)device {}

@end

/* ================================================================
 * Plugin entry point — called by CoreSimulator's bundle loader
 * ================================================================ */

/* Constructor: fires on dlopen to confirm the bundle was loaded */
__attribute__((constructor))
static void rosettasim_plugin_init(void) {
    NSLog(@"[RosettaSim] Screenshot plugin binary loaded (constructor fired)");
}

/* ================================================================
 * Plugin entry point — called by CoreSimulator's bundle loader
 * ================================================================ */

__attribute__((visibility("default")))
id simdeviceio_get_interface(void) {
    static id instance = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        instance = [[RosettaScreenshotBundleInterface alloc] init];
    });
    return instance;
}
