/*
 * sim_display_inject.m — DYLD_INSERT dylib for Simulator.app
 *
 * Injects legacy iOS framebuffer pixels into Simulator.app's display views.
 * Supports multiple devices simultaneously. Each device window gets its own
 * framebuffer file and dimensions.
 *
 * Data sources (checked in order):
 *   1. /tmp/rosettasim_active_devices.json — multi-device daemon
 *   2. /tmp/rosettasim_dimensions.json — single-device standalone bridge
 *
 * Build:
 *   make inject   (from tools/display_bridge/)
 *
 * Usage:
 *   codesign --force --sign - --options=0 /tmp/Simulator_nolv.app/Contents/MacOS/Simulator
 *   DYLD_INSERT_LIBRARIES=sim_display_inject.dylib /tmp/Simulator_nolv.app/Contents/MacOS/Simulator
 */

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <IOSurface/IOSurface.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <fcntl.h>

/* --- Per-device display state --- */

typedef struct {
    char     udid[64];
    char     name[128];
    char     fb_path[256];    /* path to raw framebuffer file */
    uint32_t width;
    uint32_t height;
    uint32_t bpr;
    uint32_t fb_size;
    float    scale;
    void     *layer_ref;  /* CFRetain'd CALayer* — use DEVICE_LAYER() to access */
    uint8_t  *read_buf;
    BOOL     active;
} DeviceDisplay;

#define DEVICE_LAYER(dd) ((__bridge CALayer *)(dd)->layer_ref)

static void device_set_layer(DeviceDisplay *dd, CALayer *layer) {
    if (dd->layer_ref) CFRelease(dd->layer_ref);
    dd->layer_ref = layer ? (void *)CFRetain((__bridge CFTypeRef)layer) : NULL;
}

static DeviceDisplay *g_devices = NULL;
static int g_device_count = 0;
static int g_device_capacity = 0;
static NSTimer *g_refresh_timer = nil;
static int g_frame_count = 0;
static BOOL g_multi_device_mode = NO;

/* --- Single-device fallback state (backwards compat) --- */
static DeviceDisplay g_single_device = {0};
static BOOL g_single_loaded = NO;

/* --- Helper: find SimDisplayRenderableView in view hierarchy --- */

static NSView *find_renderable_view(NSView *root) {
    const char *cls = object_getClassName(root);
    if (cls && strstr(cls, "SimDisplayRenderableView"))
        return root;
    for (NSView *sub in root.subviews) {
        NSView *found = find_renderable_view(sub);
        if (found) return found;
    }
    return nil;
}

/* --- Helper: get surfaceLayer ivar from SimDisplayRenderableView --- */

static CALayer *get_surface_layer(NSView *renderableView) {
    Ivar ivar = class_getInstanceVariable(object_getClass(renderableView), "surfaceLayer");
    if (ivar) {
        id val = object_getIvar(renderableView, ivar);
        if ([val isKindOfClass:[CALayer class]])
            return (CALayer *)val;
    }
    @try {
        id val = [renderableView valueForKey:@"surfaceLayer"];
        if ([val isKindOfClass:[CALayer class]])
            return (CALayer *)val;
    } @catch (id e) { /* ignore */ }
    return renderableView.layer;
}

/* --- Helper: extract device UDID from a Simulator.app window --- */

static NSString *extract_udid_from_window(NSWindow *win) {
    /* Try windowController → device → UDID */
    @try {
        id wc = win.windowController;
        if (wc) {
            /* Try KVC paths that Simulator's DeviceCoordinator might expose */
            for (NSString *path in @[@"device.UDID", @"device.udid",
                                      @"simDevice.UDID", @"simDevice.udid",
                                      @"deviceUDID"]) {
                @try {
                    id val = [wc valueForKeyPath:path];
                    if ([val isKindOfClass:[NSUUID class]])
                        return [val UUIDString];
                    if ([val isKindOfClass:[NSString class]] && [val length] == 36)
                        return val;
                } @catch (id e) { /* try next path */ }
            }
        }
    } @catch (id e) { /* no windowController */ }

    /* Try window's contentViewController.representedObject */
    @try {
        id vc = win.contentViewController;
        if (vc) {
            for (NSString *path in @[@"representedObject.UDID",
                                      @"representedObject.udid",
                                      @"representedObject.device.UDID",
                                      @"device.UDID", @"deviceUDID"]) {
                @try {
                    id val = [vc valueForKeyPath:path];
                    if ([val isKindOfClass:[NSUUID class]])
                        return [val UUIDString];
                    if ([val isKindOfClass:[NSString class]] && [val length] == 36)
                        return val;
                } @catch (id e) { /* try next */ }
            }
        }
    } @catch (id e) { /* no contentViewController */ }

    /* Try SimDisplayView.device (the SimDisplayView wraps the renderable view) */
    @try {
        NSView *renderable = find_renderable_view(win.contentView);
        if (renderable) {
            /* Walk up to SimDisplayView (parent of SimDisplayRenderableView) */
            NSView *displayView = renderable.superview;
            while (displayView) {
                const char *cls = object_getClassName(displayView);
                if (cls && strstr(cls, "SimDisplayView")) {
                    @try {
                        id dev = [displayView valueForKey:@"device"];
                        if (dev) {
                            @try {
                                id udid = [dev valueForKey:@"UDID"];
                                if ([udid isKindOfClass:[NSUUID class]])
                                    return [udid UUIDString];
                            } @catch (id e) { /* no UDID on device */ }
                        }
                    } @catch (id e) { /* no device on view */ }
                    break;
                }
                displayView = displayView.superview;
            }
        }
    } @catch (id e) { /* view walk failed */ }

    return nil; /* couldn't extract UDID — fall back to name matching */
}

/* --- Load device list from daemon or single bridge --- */

static BOOL load_multi_device_list(void) {
    NSData *data = [NSData dataWithContentsOfFile:@"/tmp/rosettasim_active_devices.json"];
    if (!data) return NO;

    NSError *err = nil;
    id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
    if (!parsed) return NO;
    /* Support both bare array [...] and wrapped {"devices":[...]} */
    NSArray *devices = nil;
    if ([parsed isKindOfClass:[NSArray class]]) {
        devices = parsed;
    } else if ([parsed isKindOfClass:[NSDictionary class]]) {
        devices = ((NSDictionary *)parsed)[@"devices"];
    }
    if (!devices || ![devices isKindOfClass:[NSArray class]]) return NO;

    int count = (int)[devices count];
    if (count > g_device_capacity) {
        g_devices = realloc(g_devices, count * sizeof(DeviceDisplay));
        memset(g_devices + g_device_capacity, 0, (count - g_device_capacity) * sizeof(DeviceDisplay));
        g_device_capacity = count;
    }

    /* Build new device list, preserving layer/active for existing UDIDs */
    int new_count = 0;
    for (NSDictionary *dev in devices) {
        NSString *udid = dev[@"udid"];
        NSString *name = dev[@"name"];
        NSNumber *w = dev[@"width"];
        NSNumber *h = dev[@"height"];
        NSNumber *s = dev[@"scale"];
        if (!udid || !name || !w || !h) continue;

        DeviceDisplay *dd = &g_devices[new_count];

        /* Check if this slot already has the same UDID with a live layer */
        BOOL preserve = (new_count < g_device_count &&
                         strcmp(dd->udid, udid.UTF8String) == 0 &&
                         dd->layer_ref != NULL);

        strlcpy(dd->udid, udid.UTF8String, sizeof(dd->udid));
        strlcpy(dd->name, name.UTF8String, sizeof(dd->name));
        snprintf(dd->fb_path, sizeof(dd->fb_path), "/tmp/rosettasim_fb_%s.raw", dd->udid);
        dd->width   = w.unsignedIntValue;
        dd->height  = h.unsignedIntValue;
        dd->scale   = s ? s.floatValue : 2.0f;
        dd->bpr     = dd->width * 4;
        dd->fb_size = dd->bpr * dd->height;

        if (!preserve) {
            /* New device or no layer yet — reset */
            device_set_layer(dd, nil);
            dd->active = NO;
        }
        /* else: keep existing layer_ref and active state */

        if (!dd->read_buf || dd->fb_size > dd->bpr * dd->height) {
            free(dd->read_buf);
            dd->read_buf = malloc(dd->fb_size);
        }
        new_count++;
    }
    /* Release layers for devices that were removed */
    for (int i = new_count; i < g_device_count; i++) {
        device_set_layer(&g_devices[i], nil);
        g_devices[i].active = NO;
    }
    g_device_count = new_count;

    if (g_device_count > 0) {
        NSLog(@"[inject] Loaded %d devices from daemon", g_device_count);
        g_multi_device_mode = YES;
        return YES;
    }
    return NO;
}

static void load_single_device(void) {
    if (g_single_loaded) return;
    FILE *f = fopen("/tmp/rosettasim_dimensions.json", "r");
    if (!f) return;
    char buf[256];
    if (fgets(buf, sizeof(buf), f)) {
        unsigned w = 0, h = 0, bpr = 0;
        float scale = 0;
        if (sscanf(buf, "{\"width\":%u,\"height\":%u,\"scale\":%f,\"bpr\":%u}",
                   &w, &h, &scale, &bpr) >= 3 && w > 0 && h > 0) {
            g_single_device.width   = w;
            g_single_device.height  = h;
            g_single_device.bpr     = bpr > 0 ? bpr : w * 4;
            g_single_device.fb_size = g_single_device.bpr * h;
            g_single_device.scale   = scale > 0 ? scale : 2.0f;
            strlcpy(g_single_device.fb_path, "/tmp/sim_framebuffer.raw",
                    sizeof(g_single_device.fb_path));
            g_single_device.active = YES;
            if (!g_single_device.read_buf) {
                g_single_device.read_buf = malloc(g_single_device.fb_size);
            }
            g_single_loaded = YES;
            NSLog(@"[inject] Single-device mode: %ux%u @%.0fx",
                  w, h, g_single_device.scale);
        }
    }
    fclose(f);
}

/* --- Refresh a single device display --- */

/* Check if a window still has a valid renderable view + surfaceLayer */
static CALayer *rescan_window_layer(NSWindow *win) {
    NSView *renderable = find_renderable_view(win.contentView);
    if (!renderable) return nil;
    return get_surface_layer(renderable);
}

static void refresh_device(DeviceDisplay *dd) {
    if (!dd->layer_ref || !dd->read_buf || !dd->fb_path[0]) return;

    /* Check layer is still in the view hierarchy — Simulator.app may have replaced it */
    CALayer *layer = DEVICE_LAYER(dd);
    if (!layer.superlayer) {
        NSLog(@"[inject] Layer for '%s' lost superlayer — re-scanning", dd->name);
        /* Find the window matching this device and re-scan */
        for (NSWindow *win in [NSApp windows]) {
            BOOL match = dd->name[0]
                ? [win.title containsString:[NSString stringWithUTF8String:dd->name]]
                : (find_renderable_view(win.contentView) != nil);
            if (match) {
                CALayer *newLayer = rescan_window_layer(win);
                if (newLayer && newLayer != layer) {
                    device_set_layer(dd, newLayer);
                    newLayer.contentsScale = dd->scale;
                    newLayer.contentsGravity = kCAGravityResize;
                    NSLog(@"[inject] Re-attached to new layer for '%s'", dd->name);
                } else if (!newLayer) {
                    device_set_layer(dd, nil);
                    dd->active = NO;
                    NSLog(@"[inject] No renderable view found for '%s'", dd->name);
                    return;
                }
                break;
            }
        }
        if (!dd->layer_ref) return;
    }

    int fd = open(dd->fb_path, O_RDONLY);
    if (fd < 0) return;
    ssize_t nread = read(fd, dd->read_buf, dd->fb_size);
    close(fd);
    if (nread < (ssize_t)dd->fb_size) return;

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(dd->read_buf, dd->width, dd->height,
        8, dd->bpr, cs, kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
    if (ctx) {
        CGImageRef img = CGBitmapContextCreateImage(ctx);
        if (img) {
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            DEVICE_LAYER(dd).contents = (__bridge id)img;
            [CATransaction commit];
            CGImageRelease(img);
        }
        CGContextRelease(ctx);
    }
    CGColorSpaceRelease(cs);
}

/* Forward declarations */
static void attempt_injection(void);
static BOOL g_injection_done;

/* --- 30fps refresh timer callback --- */

static void refresh_all(NSTimer *timer) {
    g_frame_count++;

    if (g_multi_device_mode) {
        /* Periodically reload device list (every 5s) */
        if (g_frame_count % 150 == 0) {
            int prev_count = g_device_count;
            load_multi_device_list();
            /* If new devices appeared, re-scan windows to match them */
            if (g_device_count > prev_count) {
                NSLog(@"[inject] New devices in JSON (%d → %d) — re-scanning windows",
                      prev_count, g_device_count);
                attempt_injection();
            }
        }

        for (int i = 0; i < g_device_count; i++) {
            if (g_devices[i].active)
                refresh_device(&g_devices[i]);
        }
    } else {
        /* Single-device fallback */
        load_single_device();
        if (g_single_device.active)
            refresh_device(&g_single_device);
    }

    /* Count active devices and re-scan if all lost */
    int active = 0;
    if (g_multi_device_mode) {
        for (int i = 0; i < g_device_count; i++)
            if (g_devices[i].active) active++;
    } else if (g_single_device.active) {
        active = 1;
    }

    /* Re-scan every 5s if no active devices (layer may have been released) */
    if (active == 0 && g_frame_count % 150 == 0) {
        NSLog(@"[inject] No active devices — re-scanning windows...");
        g_injection_done = NO;
        attempt_injection();
    }

    if (g_frame_count <= 3 || g_frame_count % 300 == 0) {
        NSLog(@"[inject] frame %d: %d active device(s)", g_frame_count, active);
    }
}

/* --- Match windows to devices and set up layers --- */

static void attempt_injection(void) {
    NSLog(@"[inject] Scanning Simulator.app windows...");

    /* Try multi-device mode first */
    if (!g_multi_device_mode)
        load_multi_device_list();

    NSArray *windows = [NSApp windows];
    NSLog(@"[inject] Found %lu windows", (unsigned long)windows.count);

    int connected = 0;

    for (NSWindow *win in windows) {
        NSView *renderable = find_renderable_view(win.contentView);
        if (!renderable) continue;

        CALayer *layer = get_surface_layer(renderable);
        if (!layer) continue;

        NSString *title = win.title;
        NSLog(@"[inject] Window '%@' has SimDisplayRenderableView, layer bounds=%@",
              title, NSStringFromRect(layer.bounds));

        if (g_multi_device_mode) {
            /* Match by UDID first (reliable), fall back to longest name match */
            int match_idx = -1;

            /* Try UDID extraction from Simulator.app object graph */
            NSString *winUDID = extract_udid_from_window(win);
            if (winUDID) {
                for (int i = 0; i < g_device_count; i++) {
                    if (strcmp(g_devices[i].udid, winUDID.UTF8String) == 0) {
                        match_idx = i;
                        break;
                    }
                }
                if (match_idx >= 0)
                    NSLog(@"[inject] UDID match: %@ → '%s'", winUDID, g_devices[match_idx].name);
            }

            /* Fall back to longest name match if UDID extraction failed */
            if (match_idx < 0) {
                size_t best_len = 0;
                for (int i = 0; i < g_device_count; i++) {
                    NSString *name = [NSString stringWithUTF8String:g_devices[i].name];
                    if ([title containsString:name] && name.length > best_len) {
                        match_idx = i;
                        best_len = name.length;
                    }
                }
                if (match_idx >= 0)
                    NSLog(@"[inject] Name match: '%s' → window '%@' (len=%zu)",
                          g_devices[match_idx].name, title, best_len);
            }

            if (match_idx >= 0) {
                DeviceDisplay *dd = &g_devices[match_idx];
                device_set_layer(dd, layer);
                dd->active = YES;
                layer.contentsScale = dd->scale;
                layer.contentsGravity = kCAGravityResize;
                NSLog(@"[inject] Connected '%s' → window '%@' (%ux%u @%.0fx)",
                      dd->name, title, dd->width, dd->height, dd->scale);
                connected++;
            } else {
                NSLog(@"[inject] Window '%@' — no matching device (UDID=%@)",
                      title, winUDID ?: @"unknown");
            }
        } else {
            /* Single-device: use first window with a renderable view */
            load_single_device();
            device_set_layer(&g_single_device, layer);
            g_single_device.active = YES;
            layer.contentsScale = g_single_device.scale;
            layer.contentsGravity = kCAGravityResize;
            NSLog(@"[inject] Single-device mode: connected to '%@' (%ux%u @%.0fx)",
                  title, g_single_device.width, g_single_device.height,
                  g_single_device.scale);
            connected++;
            break; /* only one in single mode */
        }
    }

    if (connected > 0) {
        NSLog(@"[inject] Connected %d device(s). Starting 30fps refresh.", connected);

        if (g_refresh_timer) {
            [g_refresh_timer invalidate];
            g_refresh_timer = nil;
        }
        g_refresh_timer = [NSTimer timerWithTimeInterval:1.0/30.0 repeats:YES
                                                   block:^(NSTimer *t) { refresh_all(t); }];
        [[NSRunLoop mainRunLoop] addTimer:g_refresh_timer forMode:NSRunLoopCommonModes];

        /* First frame immediately */
        refresh_all(nil);
    }
}

/* --- Retry injection until windows appear --- */

static int g_retry_count = 0;

static void retry_injection(void) {
    g_retry_count++;
    if (g_injection_done) return;
    if (g_retry_count > 60) {
        NSLog(@"[inject] Gave up after 60 retries");
        return;
    }

    attempt_injection();

    /* Check if we connected at least one device */
    BOOL any_active = NO;
    if (g_multi_device_mode) {
        for (int i = 0; i < g_device_count; i++)
            if (g_devices[i].active) { any_active = YES; break; }
    } else {
        any_active = g_single_device.active;
    }

    if (any_active) {
        g_injection_done = YES;
    } else {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2*NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{ retry_injection(); });
    }
}

/* --- Keyboard crash fix: swizzle setHardwareKeyboardEnabled:keyboardType:error: --- */

static IMP g_orig_setHardwareKeyboard = NULL;

static BOOL swizzled_setHardwareKeyboardEnabled(id self, SEL _cmd, BOOL enabled, id keyboardType, NSError **error) {
    /* Never call original — legacy device bridge returns garbage that causes
     * SIGSEGV in objc_storeStrong (ARC retains corrupt pointer before any
     * ObjC exception). Safe to skip: keyboard config is non-critical. */
    (void)self; (void)_cmd; (void)enabled; (void)keyboardType; (void)error;
    return YES;
}

static void install_keyboard_swizzle(void) {
    /* SimDevice is loaded from CoreSimulator.framework */
    Class cls = objc_getClass("SimDevice");
    if (!cls) {
        NSLog(@"[inject] SimDevice class not found — keyboard swizzle skipped");
        return;
    }
    SEL sel = sel_registerName("setHardwareKeyboardEnabled:keyboardType:error:");
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) {
        NSLog(@"[inject] setHardwareKeyboardEnabled: method not found — swizzle skipped");
        return;
    }
    g_orig_setHardwareKeyboard = method_setImplementation(m, (IMP)swizzled_setHardwareKeyboardEnabled);
    NSLog(@"[inject] Installed keyboard crash swizzle on SimDevice");
}

__attribute__((constructor))
static void inject_init(void) {
    NSLog(@"[inject] sim_display_inject loaded into %s (pid=%d)",
          getprogname(), getpid());

    /* Wait for Simulator.app to finish launching, then install fixes and scan windows */
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5*NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        /* Install keyboard crash fix (must be after Simulator init completes) */
        install_keyboard_swizzle();
        retry_injection();
    });
}
