/*
 * rockit_bridge.m — Phase 2: Push IOSurface to Simulator.app via CoreSimulator APIs
 *
 * Strategy: Use the host-side CoreSimulator + SimulatorKit frameworks to register as a
 * screen adapter client and inject our IOSurface into the display pipeline.
 *
 * The display path in Simulator.app is:
 *   SimDeviceScreenAdapter._screenAdapterPort → registerScreenAdapterCallbacksWithUUID:
 *     → screenConnectedCallback(SimScreen) → registerScreenCallbacksWithUUID:
 *       → surfacesChangedCallback(IOSurface?, IOSurface?)
 *         → SimDeviceScreen.unmaskedSurface → SimDisplayRenderableView.surfaceLayer
 *
 * We need to get into this path. Three approaches tried in order:
 *
 * Approach A: Use SimDevice._ioServer to get the framebuffer server IO port,
 *   then call registerScreenAdapterCallbacks directly from our process.
 *
 * Approach B: Create a SimDeviceScreen and connect a SimDisplayRenderableView,
 *   then push IOSurface to the screen.
 *
 * Approach C: Directly set layer.contents on a CALayerHost connected to the
 *   sim's CAContext.
 *
 * Usage: rockit_bridge <device-UDID>
 */

#import <Foundation/Foundation.h>
#import <IOSurface/IOSurface.h>
#import <mach/mach.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <os/log.h>

#define PIXEL_WIDTH  750
#define PIXEL_HEIGHT 1334
#define BPR          (PIXEL_WIDTH * 4)

static os_log_t sLog;

#pragma mark - IOSurface creation

static IOSurfaceRef create_test_surface(void) {
    NSDictionary *props = @{
        (id)kIOSurfaceWidth:           @(PIXEL_WIDTH),
        (id)kIOSurfaceHeight:          @(PIXEL_HEIGHT),
        (id)kIOSurfaceBytesPerElement: @4,
        (id)kIOSurfaceBytesPerRow:     @(BPR),
        (id)kIOSurfacePixelFormat:     @(0x42475241), /* 'BGRA' */
        (id)kIOSurfaceAllocSize:       @(BPR * PIXEL_HEIGHT),
    };
    IOSurfaceRef surf = IOSurfaceCreate((__bridge CFDictionaryRef)props);
    if (!surf) { os_log_error(sLog, "IOSurfaceCreate failed"); return NULL; }

    /* Fill with a gradient so we can visually verify it's our surface */
    IOSurfaceLock(surf, 0, NULL);
    uint32_t *px = (uint32_t *)IOSurfaceGetBaseAddress(surf);
    for (int y = 0; y < PIXEL_HEIGHT; y++) {
        for (int x = 0; x < PIXEL_WIDTH; x++) {
            uint8_t r = (uint8_t)(x * 255 / PIXEL_WIDTH);
            uint8_t g = (uint8_t)(y * 255 / PIXEL_HEIGHT);
            uint8_t b = 128;
            px[y * PIXEL_WIDTH + x] = (0xFF << 24) | (r << 16) | (g << 8) | b;
        }
    }
    IOSurfaceUnlock(surf, 0, NULL);

    os_log(sLog, "Test surface: %dx%d id=%u", PIXEL_WIDTH, PIXEL_HEIGHT, IOSurfaceGetID(surf));
    return surf;
}

#pragma mark - Helpers

static void dump_methods(id obj, const char *filter) {
    unsigned int count = 0;
    Method *methods = class_copyMethodList(object_getClass(obj), &count);
    for (unsigned int i = 0; i < count; i++) {
        NSString *name = NSStringFromSelector(method_getName(methods[i]));
        if (!filter || [name containsString:@(filter)]) {
            os_log(sLog, "  %{public}s %{public}@", object_getClassName(obj), name);
        }
    }
    free(methods);
}

static void dump_protocols(id obj) {
    unsigned int pcount = 0;
    Protocol * __unsafe_unretained *protocols = class_copyProtocolList(object_getClass(obj), &pcount);
    for (unsigned int i = 0; i < pcount; i++) {
        os_log(sLog, "  protocol: %{public}s", protocol_getName(protocols[i]));
    }
    free(protocols);
}

#pragma mark - Approach A: Access FramebufferServerDescriptor via SimDevice._ioServer

static BOOL try_screen_adapter_approach(id device, IOSurfaceRef surface) {
    os_log(sLog, "=== Approach A: FramebufferServerDescriptor screen adapter ===");

    /* Get the device's IO server */
    id ioServer = nil;
    @try {
        ioServer = ((id(*)(id,SEL))objc_msgSend)(device, sel_registerName("_ioServer"));
    } @catch (id e) {
        os_log(sLog, "_ioServer threw: %{public}@", e);
    }

    if (!ioServer) {
        os_log(sLog, "No _ioServer available (device may not be booted)");
        return NO;
    }
    os_log(sLog, "_ioServer: %{public}s", object_getClassName(ioServer));

    /* Get IO ports */
    NSArray *ports = nil;
    @try {
        ports = ((id(*)(id,SEL))objc_msgSend)(ioServer, sel_registerName("ioPorts"));
    } @catch (id e) {
        os_log(sLog, "ioPorts threw: %{public}@", e);
        return NO;
    }

    os_log(sLog, "IO ports count: %lu", (unsigned long)[ports count]);
    for (id port in ports) {
        os_log(sLog, "  port: %{public}s", object_getClassName(port));

        id descriptor = nil;
        @try {
            descriptor = ((id(*)(id,SEL))objc_msgSend)(port, sel_registerName("ioPortDescriptor"));
        } @catch (id e) { continue; }

        if (!descriptor) continue;
        os_log(sLog, "    descriptor: %{public}s", object_getClassName(descriptor));

        /* Check if this is the framebuffer server descriptor */
        NSString *portId = nil;
        @try {
            portId = ((id(*)(id,SEL))objc_msgSend)(descriptor, sel_registerName("portIdentifier"));
        } @catch (id e) { continue; }

        os_log(sLog, "    portIdentifier: %{public}@", portId);

        if ([portId containsString:@"framebuffer"] || [portId containsString:@"Framebuffer"] ||
            [portId containsString:@"display"] || [portId containsString:@"Display"]) {
            os_log(sLog, "  >>> Found framebuffer descriptor!");

            /* Try registerScreenAdapterCallbacks */
            NSUUID *uuid = [NSUUID UUID];
            dispatch_queue_t q = dispatch_get_main_queue();

            @try {
                ((void(*)(id,SEL,id,id,id,id))objc_msgSend)(
                    descriptor,
                    sel_registerName("registerScreenAdapterCallbacksWithUUID:callbackQueue:screenConnectedCallback:screenWillDisconnectCallback:"),
                    uuid, q,
                    ^(id screen) {
                        os_log(sLog, "screenConnected: %{public}@", screen);
                        /* Register per-screen callbacks to get surfacesChanged */
                        NSUUID *screenUUID = [NSUUID UUID];
                        @try {
                            ((void(*)(id,SEL,id,id,id,id,id))objc_msgSend)(
                                screen,
                                sel_registerName("registerScreenCallbacksWithUUID:callbackQueue:frameCallback:surfacesChangedCallback:propertiesChangedCallback:"),
                                screenUUID, q,
                                ^{ os_log(sLog, "frameCallback"); },
                                ^(IOSurfaceRef unmasked, IOSurfaceRef masked) {
                                    os_log(sLog, "surfacesChanged: unmasked=%p masked=%p", unmasked, masked);
                                },
                                ^(id props) {
                                    os_log(sLog, "propertiesChanged: %{public}@", props);
                                }
                            );
                        } @catch (id e) {
                            os_log(sLog, "registerScreenCallbacks threw: %{public}@", e);
                        }
                    },
                    ^(uint32_t screenID) {
                        os_log(sLog, "screenWillDisconnect: ID=%u", screenID);
                    }
                );
                os_log(sLog, "Registered screen adapter callbacks with UUID %{public}@", uuid);
                return YES;
            } @catch (id e) {
                os_log(sLog, "registerScreenAdapterCallbacks threw: %{public}@", e);
            }
        }
    }

    return NO;
}

#pragma mark - Approach B: SimDeviceScreen + SimDisplayRenderableView

static BOOL try_simulatorkit_approach(id device, IOSurfaceRef surface) {
    os_log(sLog, "=== Approach B: SimulatorKit SimDeviceScreen ===");

    /* Load SimulatorKit */
    void *kit = dlopen("/Applications/Xcode.app/Contents/Developer/Library/PrivateFrameworks/SimulatorKit.framework/SimulatorKit", RTLD_NOW);
    if (!kit) {
        os_log_error(sLog, "Failed to load SimulatorKit: %{public}s", dlerror());
        return NO;
    }

    /* Create SimDeviceScreen for screen ID 1 */
    Class screenCls = objc_getClass("SimulatorKit.SimDeviceScreen");
    if (!screenCls) screenCls = objc_getClass("SimDeviceScreen");
    if (!screenCls) {
        /* Try Swift mangled name */
        screenCls = NSClassFromString(@"SimulatorKit.SimDeviceScreen");
    }

    if (!screenCls) {
        os_log(sLog, "SimDeviceScreen class not found, trying SimDeviceScreenAdapter");

        Class adapterCls = NSClassFromString(@"SimulatorKit.SimDeviceScreenAdapter");
        if (!adapterCls) adapterCls = objc_getClass("SimDeviceScreenAdapter");
        if (!adapterCls) {
            os_log(sLog, "SimDeviceScreenAdapter class not found either");

            /* List all classes from SimulatorKit */
            unsigned int classCount = 0;
            Class *classes = objc_copyClassList(&classCount);
            for (unsigned int i = 0; i < classCount; i++) {
                NSString *name = @(class_getName(classes[i]));
                if ([name containsString:@"SimDisplay"] || [name containsString:@"SimDeviceScreen"] ||
                    [name containsString:@"SimulatorKit"]) {
                    os_log(sLog, "  class: %{public}@", name);
                }
            }
            free(classes);
            return NO;
        }

        os_log(sLog, "Found SimDeviceScreenAdapter: %{public}s", class_getName(adapterCls));
        dump_methods((id)adapterCls, NULL);
        return NO;
    }

    os_log(sLog, "Found SimDeviceScreen: %{public}s", class_getName(screenCls));

    /* Create screen: initWithDevice:screenID: */
    id screen = ((id(*)(id,SEL,id,uint32_t))objc_msgSend)(
        (id)screenCls,
        sel_registerName("alloc"),
        0, 0);
    screen = ((id(*)(id,SEL,id,uint32_t))objc_msgSend)(
        screen,
        sel_registerName("initWithDevice:screenID:"),
        device, (uint32_t)1);

    if (!screen) {
        os_log(sLog, "SimDeviceScreen initWithDevice:screenID: returned nil");
        return NO;
    }

    os_log(sLog, "Created SimDeviceScreen: %{public}@", screen);

    /* Try to set the surface directly */
    @try {
        Ivar ivar = class_getInstanceVariable(object_getClass(screen), "_unmaskedSurface");
        if (!ivar) ivar = class_getInstanceVariable(object_getClass(screen), "unmaskedSurface");
        if (ivar) {
            os_log(sLog, "Found _unmaskedSurface ivar, setting IOSurface");
            object_setIvar(screen, ivar, (__bridge id)surface);
            os_log(sLog, "Set unmaskedSurface to our IOSurface");
            return YES;
        } else {
            os_log(sLog, "_unmaskedSurface ivar not found");
        }
    } @catch (id e) {
        os_log(sLog, "Setting surface threw: %{public}@", e);
    }

    return NO;
}

#pragma mark - Approach C: Direct CALayerHost (bonus)

static BOOL try_calayerhost_approach(id device, IOSurfaceRef surface) {
    os_log(sLog, "=== Approach C: Direct framebuffer display descriptor ===");

    /* Try getting the FramebufferDisplayDescriptor directly from device IO */
    id ioServer = nil;
    @try {
        ioServer = ((id(*)(id,SEL))objc_msgSend)(device, sel_registerName("_ioServer"));
    } @catch (id e) { return NO; }
    if (!ioServer) return NO;

    /* Get all port descriptors and find the display one */
    NSArray *ports = ((id(*)(id,SEL))objc_msgSend)(ioServer, sel_registerName("ioPorts"));
    for (id port in ports) {
        id descriptor = nil;
        @try { descriptor = ((id(*)(id,SEL))objc_msgSend)(port, sel_registerName("ioPortDescriptor")); }
        @catch (id e) { continue; }
        if (!descriptor) continue;

        NSString *cls = @(object_getClassName(descriptor));
        os_log(sLog, "  descriptor class: %{public}@", cls);

        /* Check if it has framebufferSurface property */
        if ([cls containsString:@"FramebufferDisplay"] || [cls containsString:@"Display"]) {
            os_log(sLog, "  >>> Found display descriptor: %{public}s", object_getClassName(descriptor));

            /* Try setting framebufferSurface */
            Ivar fbIvar = class_getInstanceVariable(object_getClass(descriptor), "_framebufferSurface");
            if (fbIvar) {
                os_log(sLog, "  Found _framebufferSurface ivar!");
                /* Don't set it directly — that might crash. Just note we found it. */
            }

            /* Try calling sendIOSurfacesChangedAsync */
            SEL sendSel = sel_registerName("sendIOSurfacesChangedAsync:");
            if ([descriptor respondsToSelector:sendSel]) {
                os_log(sLog, "  descriptor responds to sendIOSurfacesChangedAsync:");
                return YES;
            }

            /* Dump all methods */
            dump_methods(descriptor, NULL);
        }
    }

    return NO;
}

#pragma mark - Main

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        sLog = os_log_create("com.rosetta.ROCKitBridge", "Main");

        if (argc < 2) { fprintf(stderr, "Usage: %s <UDID>\n", argv[0]); return 1; }
        NSString *udid = [NSString stringWithUTF8String:argv[1]];

        /* Load CoreSimulator */
        dlopen("/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator", RTLD_NOW);

        /* Load SimulatorKit */
        dlopen("/Applications/Xcode.app/Contents/Developer/Library/PrivateFrameworks/SimulatorKit.framework/SimulatorKit", RTLD_NOW);

        /* Get device */
        Class SimServiceContext = objc_getClass("SimServiceContext");
        NSError *err = nil;
        id ctx = ((id(*)(id,SEL,id,NSError**))objc_msgSend)(
            (id)SimServiceContext, sel_registerName("sharedServiceContextForDeveloperDir:error:"),
            @"/Applications/Xcode.app/Contents/Developer", &err);
        if (!ctx) { os_log_error(sLog, "SimServiceContext: %{public}@", err); return 1; }

        id devSet = ((id(*)(id,SEL,NSError**))objc_msgSend)(ctx, sel_registerName("defaultDeviceSetWithError:"), &err);
        NSDictionary *devs = ((id(*)(id,SEL))objc_msgSend)(devSet, sel_registerName("devicesByUDID"));
        id device = [devs objectForKey:[[NSUUID alloc] initWithUUIDString:udid]];
        if (!device) { os_log_error(sLog, "Device %{public}@ not found", udid); return 1; }

        NSString *devName = ((id(*)(id,SEL))objc_msgSend)(device, sel_registerName("name"));
        os_log(sLog, "Device: %{public}@ (%{public}@)", devName, udid);

        /* Dump device methods related to IO/screen/display */
        os_log(sLog, "--- Device IO/Screen methods ---");
        {
            unsigned int count = 0;
            Method *methods = class_copyMethodList(object_getClass(device), &count);
            for (unsigned int i = 0; i < count; i++) {
                NSString *name = NSStringFromSelector(method_getName(methods[i]));
                if ([name containsString:@"screen"] || [name containsString:@"Screen"] ||
                    [name containsString:@"display"] || [name containsString:@"Display"] ||
                    [name containsString:@"surface"] || [name containsString:@"Surface"] ||
                    [name containsString:@"ioServer"] || [name containsString:@"IOServer"] ||
                    [name containsString:@"deviceIO"] || [name containsString:@"ioPort"] ||
                    [name containsString:@"framebuffer"] || [name containsString:@"Framebuffer"]) {
                    os_log(sLog, "  %{public}@", name);
                }
            }
            free(methods);
        }

        /* Create test IOSurface */
        IOSurfaceRef surface = create_test_surface();
        if (!surface) return 1;

        /* Try approaches in order */
        BOOL ok = try_screen_adapter_approach(device, surface);
        if (!ok) {
            ok = try_simulatorkit_approach(device, surface);
        }
        if (!ok) {
            ok = try_calayerhost_approach(device, surface);
        }

        if (ok) {
            os_log(sLog, "Bridge established. Running event loop...");
            CFRunLoopRun();
        } else {
            os_log(sLog, "All approaches failed. Check logs for details.");
            /* Still run briefly to capture all async log output */
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, 2.0, false);
        }
    }
    return 0;
}
