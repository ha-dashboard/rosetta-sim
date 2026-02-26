/*
 * sim_display_inject.m — DYLD_INSERT dylib for Simulator.app
 *
 * Injects iOS 9.3/10.3 framebuffer pixels into Simulator.app's display view.
 * Reads IOSurface ID from /tmp/rosettasim_surface_id (written by purple_fb_bridge).
 * Finds SimDisplayRenderableView's surfaceLayer and sets .contents = IOSurface.
 *
 * Build:
 *   cc -dynamiclib -o sim_display_inject.dylib sim_display_inject.m \
 *      -framework Foundation -framework AppKit -framework IOSurface -framework QuartzCore \
 *      -fobjc-arc
 *
 * Usage:
 *   cp .../Simulator.app/.../Simulator /tmp/Simulator_nolv
 *   codesign --force --sign - --options=0 /tmp/Simulator_nolv
 *   DYLD_INSERT_LIBRARIES=sim_display_inject.dylib /tmp/Simulator_nolv
 */

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <IOSurface/IOSurface.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <fcntl.h>

#define FB_WIDTH  750
#define FB_HEIGHT 1334
#define FB_BPR    (FB_WIDTH * 4)
#define FB_SIZE   (FB_BPR * FB_HEIGHT)

static NSTimer *g_refresh_timer = nil;
static CALayer *g_surface_layer = nil;
static uint8_t *g_read_buf = NULL;

/* No longer needed — we read the raw file directly */

/* Recursively find SimDisplayRenderableView in view hierarchy */
static NSView *find_renderable_view(NSView *root) {
    const char *cls = object_getClassName(root);
    /* Swift-mangled class name contains "SimDisplayRenderableView" */
    if (cls && strstr(cls, "SimDisplayRenderableView")) {
        return root;
    }
    for (NSView *sub in root.subviews) {
        NSView *found = find_renderable_view(sub);
        if (found) return found;
    }
    return nil;
}

/* Get the surfaceLayer ivar from SimDisplayRenderableView */
static CALayer *get_surface_layer(NSView *renderableView) {
    /* Try ivar first — the ivar name from nm is "surfaceLayer" */
    Ivar ivar = class_getInstanceVariable(object_getClass(renderableView), "surfaceLayer");
    if (ivar) {
        id val = object_getIvar(renderableView, ivar);
        if ([val isKindOfClass:[CALayer class]]) {
            NSLog(@"[inject] Found surfaceLayer via ivar: %@", val);
            return (CALayer *)val;
        }
    }

    /* Try KVC — property might have different ivar name */
    @try {
        id val = [renderableView valueForKey:@"surfaceLayer"];
        if ([val isKindOfClass:[CALayer class]]) {
            NSLog(@"[inject] Found surfaceLayer via KVC: %@", val);
            return (CALayer *)val;
        }
    } @catch (id e) {
        NSLog(@"[inject] surfaceLayer KVC failed: %@", e);
    }

    /* Fallback: use the view's own layer */
    NSLog(@"[inject] Using view.layer as fallback");
    return renderableView.layer;
}

static int g_frame_count = 0;
static void refresh_surface(NSTimer *timer) {
    if (!g_surface_layer) return;
    g_frame_count++;

    /* Allocate read buffer once */
    if (!g_read_buf) {
        g_read_buf = malloc(FB_SIZE);
        if (!g_read_buf) return;
    }

    /* Read raw framebuffer file */
    int fd = open("/tmp/sim_framebuffer.raw", O_RDONLY);
    if (fd < 0) {
        if (g_frame_count <= 3) NSLog(@"[inject] Waiting for framebuffer file...");
        return;
    }
    ssize_t nread = read(fd, g_read_buf, FB_SIZE);
    close(fd);
    if (nread < FB_SIZE) return;

    /* Convert to CGImage and set on layer */
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(g_read_buf, FB_WIDTH, FB_HEIGHT, 8, FB_BPR,
        cs, kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
    if (ctx) {
        CGImageRef img = CGBitmapContextCreateImage(ctx);
        if (img) {
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            g_surface_layer.contents = (__bridge id)img;
            [CATransaction commit];
            CGImageRelease(img);
        }
        CGContextRelease(ctx);
    }
    CGColorSpaceRelease(cs);

    if (g_frame_count <= 3 || g_frame_count % 300 == 0)
        NSLog(@"[inject] frame %d: set CGImage on surfaceLayer", g_frame_count);
}

static void attempt_injection(void) {
    NSLog(@"[inject] Scanning Simulator.app windows...");

    NSArray *windows = [NSApp windows];
    NSLog(@"[inject] Found %lu windows", (unsigned long)windows.count);

    for (NSWindow *win in windows) {
        NSLog(@"[inject] Window: '%@' class=%s frame=%@",
              win.title, object_getClassName(win), NSStringFromRect(win.frame));

        NSView *renderable = find_renderable_view(win.contentView);
        if (renderable) {
            NSLog(@"[inject] FOUND SimDisplayRenderableView in window '%@': %@ class=%s",
                  win.title, renderable, object_getClassName(renderable));

            g_surface_layer = get_surface_layer(renderable);
            if (!g_surface_layer) {
                NSLog(@"[inject] ERROR: no surfaceLayer found");
                continue;
            }

            NSLog(@"[inject] surfaceLayer: %@ bounds=%@",
                  g_surface_layer, NSStringFromRect(g_surface_layer.bounds));

            /* Do first refresh immediately */
            refresh_surface(nil);

            /* Set up 30fps refresh timer */
            g_refresh_timer = [NSTimer scheduledTimerWithTimeInterval:1.0/30.0
                                                              target:[NSBlockOperation blockOperationWithBlock:^{}]
                                                            selector:@selector(main)
                                                            userInfo:nil
                                                             repeats:YES];
            /* Use a proper timer with block */
            [g_refresh_timer invalidate];
            g_refresh_timer = [NSTimer timerWithTimeInterval:1.0/30.0 repeats:YES block:^(NSTimer *t) {
                refresh_surface(t);
            }];
            [[NSRunLoop mainRunLoop] addTimer:g_refresh_timer forMode:NSRunLoopCommonModes];

            NSLog(@"[inject] Display injection ACTIVE — 30fps refresh on surfaceLayer");
            return;
        }
    }

    NSLog(@"[inject] SimDisplayRenderableView not found yet — will retry...");
}

/* Retry injection periodically until we find the view */
static int g_retry_count = 0;
static void retry_injection(void) {
    g_retry_count++;
    if (g_surface_layer) return; /* already connected */
    if (g_retry_count > 60) {
        NSLog(@"[inject] Gave up after 60 retries");
        return;
    }

    attempt_injection();

    if (!g_surface_layer) {
        /* Retry in 2 seconds */
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2*NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{ retry_injection(); });
    }
}

__attribute__((constructor))
static void inject_init(void) {
    NSLog(@"[inject] sim_display_inject loaded into %s (pid=%d)",
          getprogname(), getpid());

    /* Wait for Simulator.app to finish launching and create windows */
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5*NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        retry_injection();
    });
}
