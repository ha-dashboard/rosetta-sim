/*
 * sim_viewer.m — Standalone framebuffer viewer for legacy iOS simulators
 *
 * Displays the IOSurface created by purple_fb_bridge in a native macOS window.
 * Reads IOSurface ID from /tmp/rosettasim_surface_id, refreshes at 30fps.
 *
 * Build:
 *   cc -o sim_viewer sim_viewer.m -framework Foundation -framework AppKit \
 *      -framework IOSurface -framework QuartzCore -fobjc-arc
 *
 * Usage:
 *   1. Start purple_fb_bridge <UDID>
 *   2. Boot sim: xcrun simctl boot <UDID>
 *   3. Run: ./sim_viewer
 */

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <IOSurface/IOSurface.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreGraphics/CoreGraphics.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>

#define VIEWER_SCALE 0.5  /* Display at 50% of pixel size (375x667 window for 750x1334) */
#define FB_WIDTH  750
#define FB_HEIGHT 1334
#define FB_BPR    (FB_WIDTH * 4)
#define FB_SIZE   (FB_BPR * FB_HEIGHT)

static IOSurfaceRef g_surface = NULL;
static CALayer *g_display_layer = nil;
static int g_frame_count = 0;
static uint8_t *g_read_buf = NULL;

static void refresh_display(NSTimer *timer) {
    g_frame_count++;

    /* Allocate read buffer once */
    if (!g_read_buf) {
        g_read_buf = malloc(FB_SIZE);
        if (!g_read_buf) return;
    }

    /* Read the raw framebuffer file each frame (bridge does atomic rename) */
    int fd = open("/tmp/sim_framebuffer.raw", O_RDONLY);
    if (fd < 0) {
        if (g_frame_count <= 3)
            NSLog(@"[viewer] Waiting for /tmp/sim_framebuffer.raw...");
        return;
    }
    ssize_t nread = read(fd, g_read_buf, FB_SIZE);
    close(fd);
    if (nread < FB_SIZE) {
        if (g_frame_count <= 3)
            NSLog(@"[viewer] Short read: %zd < %d", nread, FB_SIZE);
        return;
    }

    /* Convert raw BGRA pixels to CGImage and set on layer */
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(g_read_buf, FB_WIDTH, FB_HEIGHT, 8, FB_BPR,
        cs, kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
    if (ctx) {
        CGImageRef img = CGBitmapContextCreateImage(ctx);
        if (img) {
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            g_display_layer.contents = (__bridge id)img;
            [CATransaction commit];
            CGImageRelease(img);
        }
        CGContextRelease(ctx);
    }
    CGColorSpaceRelease(cs);

    if (g_frame_count <= 5 || g_frame_count % 300 == 0) {
        uint32_t *rpx = (uint32_t *)g_read_buf;
        NSLog(@"[viewer] frame %d: px[0]=%08x [100]=%08x [1000]=%08x layer.contents=%p frame=%@",
              g_frame_count, rpx[0], rpx[100], rpx[1000],
              (__bridge void *)g_display_layer.contents,
              NSStringFromRect(g_display_layer.frame));
    }
}

@interface ViewerDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate>
@property (strong) NSWindow *window;
@property (strong) NSTimer *refreshTimer;
@end

@implementation ViewerDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)note {
    CGFloat pw = FB_WIDTH, ph = FB_HEIGHT;
    CGFloat winW = pw * VIEWER_SCALE;
    CGFloat winH = ph * VIEWER_SCALE;

    NSRect frame = NSMakeRect(100, 100, winW, winH);
    self.window = [[NSWindow alloc] initWithContentRect:frame
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable
        backing:NSBackingStoreBuffered defer:NO];
    self.window.title = [NSString stringWithFormat:@"iOS Sim — %gx%g @%.0f%%", pw, ph, VIEWER_SCALE * 100];
    self.window.delegate = self;
    self.window.backgroundColor = [NSColor blackColor];

    /* Layer-backed view with display layer */
    NSView *contentView = self.window.contentView;
    contentView.wantsLayer = YES;
    contentView.layer.backgroundColor = [NSColor blackColor].CGColor;

    g_display_layer = [CALayer layer];
    g_display_layer.frame = contentView.bounds;
    g_display_layer.contentsGravity = kCAGravityResize;
    g_display_layer.contentsScale = self.window.backingScaleFactor;
    g_display_layer.autoresizingMask = kCALayerWidthSizable | kCALayerHeightSizable;
    g_display_layer.magnificationFilter = kCAFilterLinear;
    /* geometryFlipped on the PARENT layer — flips coordinate system for sublayers */
    contentView.layer.geometryFlipped = YES;
    [contentView.layer addSublayer:g_display_layer];
    NSLog(@"[viewer] backingScaleFactor=%.1f", self.window.backingScaleFactor);

    [self.window makeKeyAndOrderFront:nil];
    NSLog(@"[viewer] Window created %.0fx%.0f — waiting for framebuffer", winW, winH);

    /* 30fps refresh */
    self.refreshTimer = [NSTimer timerWithTimeInterval:1.0/30.0 repeats:YES block:^(NSTimer *t) {
        refresh_display(t);
    }];
    [[NSRunLoop mainRunLoop] addTimer:self.refreshTimer forMode:NSRunLoopCommonModes];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)app {
    return YES;
}

- (void)windowWillClose:(NSNotification *)note {
    [self.refreshTimer invalidate];
    if (g_surface) { CFRelease(g_surface); g_surface = NULL; }
}

@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        ViewerDelegate *del = [[ViewerDelegate alloc] init];
        app.delegate = del;
        [app activateIgnoringOtherApps:YES];
        [app run];
    }
    return 0;
}
