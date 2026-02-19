/*
 * Phase 4b: Full Retina resolution render (750x1334 pixels)
 * Renders at 2x scale for iPhone 6s equivalent output.
 */

#import <stdlib.h>
#import <string.h>
#import <unistd.h>
#import <stdio.h>
#import <stdarg.h>
#import <execinfo.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <CoreFoundation/CoreFoundation.h>
#import <Foundation/Foundation.h>

typedef struct { double x, y, w, h; } CGRect_t;

static char _buf[4096];
void out(const char *msg) { write(STDOUT_FILENO, msg, strlen(msg)); }
void outf(const char *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    int n = vsnprintf(_buf, sizeof(_buf), fmt, ap); va_end(ap);
    if (n > 0) write(STDOUT_FILENO, _buf, n);
}

@interface RetinaDelegate : NSObject
@end

@implementation RetinaDelegate
- (BOOL)application:(id)app didFinishLaunchingWithOptions:(id)opts {
    out("\n=== Phase 4b: Retina Resolution Render ===\n\n");

    Class viewCls = objc_getClass("UIView");
    Class labelCls = objc_getClass("UILabel");
    Class colorCls = objc_getClass("UIColor");
    Class fontCls = objc_getClass("UIFont");
    SEL allocSel = sel_registerName("alloc");
    SEL initFrameSel = sel_registerName("initWithFrame:");
    typedef id (*initFrame_fn)(id, SEL, CGRect_t);

    /* Container: full iPhone 6s screen in points */
    CGRect_t screen = {0, 0, 375, 667};
    id container = ((initFrame_fn)objc_msgSend)(
        ((id(*)(id, SEL))objc_msgSend)((id)viewCls, allocSel),
        initFrameSel, screen);

    /* Gradient-like background: dark blue */
    id bgColor = ((id(*)(id, SEL, double, double, double, double))objc_msgSend)(
        (id)colorCls, sel_registerName("colorWithRed:green:blue:alpha:"),
        0.1, 0.1, 0.4, 1.0);
    ((void(*)(id, SEL, id))objc_msgSend)(container, sel_registerName("setBackgroundColor:"), bgColor);

    /* Status bar area */
    CGRect_t statusFrame = {0, 0, 375, 20};
    id statusBar = ((initFrame_fn)objc_msgSend)(
        ((id(*)(id, SEL))objc_msgSend)((id)viewCls, allocSel),
        initFrameSel, statusFrame);
    id darkColor = ((id(*)(id, SEL, double, double, double, double))objc_msgSend)(
        (id)colorCls, sel_registerName("colorWithRed:green:blue:alpha:"),
        0.05, 0.05, 0.2, 1.0);
    ((void(*)(id, SEL, id))objc_msgSend)(statusBar, sel_registerName("setBackgroundColor:"), darkColor);
    ((void(*)(id, SEL, id))objc_msgSend)(container, sel_registerName("addSubview:"), statusBar);

    /* Title label */
    CGRect_t titleFrame = {20, 80, 335, 50};
    id titleLabel = ((initFrame_fn)objc_msgSend)(
        ((id(*)(id, SEL))objc_msgSend)((id)labelCls, allocSel),
        initFrameSel, titleFrame);

    ((void(*)(id, SEL, id))objc_msgSend)(titleLabel, sel_registerName("setText:"),
        @"RosettaSim");
    id white = ((id(*)(id, SEL))objc_msgSend)((id)colorCls, sel_registerName("whiteColor"));
    ((void(*)(id, SEL, id))objc_msgSend)(titleLabel, sel_registerName("setTextColor:"), white);
    id titleFont = ((id(*)(id, SEL, double))objc_msgSend)(
        (id)fontCls, sel_registerName("boldSystemFontOfSize:"), 36.0);
    ((void(*)(id, SEL, id))objc_msgSend)(titleLabel, sel_registerName("setFont:"), titleFont);
    ((void(*)(id, SEL, long))objc_msgSend)(titleLabel, sel_registerName("setTextAlignment:"), 1);
    ((void(*)(id, SEL, id))objc_msgSend)(container, sel_registerName("addSubview:"), titleLabel);

    /* Subtitle */
    CGRect_t subFrame = {20, 140, 335, 80};
    id subLabel = ((initFrame_fn)objc_msgSend)(
        ((id(*)(id, SEL))objc_msgSend)((id)labelCls, allocSel),
        initFrameSel, subFrame);
    ((void(*)(id, SEL, id))objc_msgSend)(subLabel, sel_registerName("setText:"),
        @"iOS 10.3.1 Simulator\nRunning on macOS 26\nApple Silicon via Rosetta 2");
    id lightGray = ((id(*)(id, SEL, double, double, double, double))objc_msgSend)(
        (id)colorCls, sel_registerName("colorWithRed:green:blue:alpha:"),
        0.8, 0.8, 0.9, 1.0);
    ((void(*)(id, SEL, id))objc_msgSend)(subLabel, sel_registerName("setTextColor:"), lightGray);
    id subFont = ((id(*)(id, SEL, double))objc_msgSend)(
        (id)fontCls, sel_registerName("systemFontOfSize:"), 18.0);
    ((void(*)(id, SEL, id))objc_msgSend)(subLabel, sel_registerName("setFont:"), subFont);
    ((void(*)(id, SEL, long))objc_msgSend)(subLabel, sel_registerName("setNumberOfLines:"), 0);
    ((void(*)(id, SEL, long))objc_msgSend)(subLabel, sel_registerName("setTextAlignment:"), 1);
    ((void(*)(id, SEL, id))objc_msgSend)(container, sel_registerName("addSubview:"), subLabel);

    /* Info section */
    CGRect_t infoFrame = {20, 300, 335, 200};
    id infoLabel = ((initFrame_fn)objc_msgSend)(
        ((id(*)(id, SEL))objc_msgSend)((id)labelCls, allocSel),
        initFrameSel, infoFrame);
    ((void(*)(id, SEL, id))objc_msgSend)(infoLabel, sel_registerName("setText:"),
        @"UIKit: Loaded (48MB)\n"
        "Foundation: Loaded (9.9MB)\n"
        "CoreGraphics: Working\n"
        "CoreText: Working\n"
        "Obj-C Runtime: Working\n"
        "Frameworks: 671 loaded\n"
        "dyld_sim: 2017 vintage");
    id green = ((id(*)(id, SEL, double, double, double, double))objc_msgSend)(
        (id)colorCls, sel_registerName("colorWithRed:green:blue:alpha:"),
        0.4, 1.0, 0.4, 1.0);
    ((void(*)(id, SEL, id))objc_msgSend)(infoLabel, sel_registerName("setTextColor:"), green);
    id monoFont = ((id(*)(id, SEL, double))objc_msgSend)(
        (id)fontCls, sel_registerName("systemFontOfSize:"), 14.0);
    ((void(*)(id, SEL, id))objc_msgSend)(infoLabel, sel_registerName("setFont:"), monoFont);
    ((void(*)(id, SEL, long))objc_msgSend)(infoLabel, sel_registerName("setNumberOfLines:"), 0);
    ((void(*)(id, SEL, id))objc_msgSend)(container, sel_registerName("addSubview:"), infoLabel);

    /* Bottom bar */
    CGRect_t bottomFrame = {0, 617, 375, 50};
    id bottomBar = ((initFrame_fn)objc_msgSend)(
        ((id(*)(id, SEL))objc_msgSend)((id)viewCls, allocSel),
        initFrameSel, bottomFrame);
    ((void(*)(id, SEL, id))objc_msgSend)(bottomBar, sel_registerName("setBackgroundColor:"), darkColor);
    ((void(*)(id, SEL, id))objc_msgSend)(container, sel_registerName("addSubview:"), bottomBar);

    /* Layout */
    ((void(*)(id, SEL))objc_msgSend)(container, sel_registerName("layoutIfNeeded"));

    /* Render at 2x (750x1334 pixels) */
    int px_w = 750, px_h = 1334;
    out("Rendering at 2x Retina resolution...\n");

    typedef void *CGColorSpaceRef, *CGContextRef;
    CGColorSpaceRef (*mkCS)(void) = dlsym(RTLD_DEFAULT, "CGColorSpaceCreateDeviceRGB");
    CGContextRef (*mkBmp)(void*,size_t,size_t,size_t,size_t,CGColorSpaceRef,uint32_t) =
        dlsym(RTLD_DEFAULT, "CGBitmapContextCreate");
    void (*scaleCTM)(CGContextRef, double, double) =
        dlsym(RTLD_DEFAULT, "CGContextScaleCTM");
    void (*relCtx)(CGContextRef) = dlsym(RTLD_DEFAULT, "CGContextRelease");
    void (*relCS)(CGColorSpaceRef) = dlsym(RTLD_DEFAULT, "CGColorSpaceRelease");

    CGColorSpaceRef cs = mkCS();
    void *pixels = calloc(px_w * px_h, 4);
    CGContextRef ctx = mkBmp(pixels, px_w, px_h, 8, px_w * 4, cs, 0x2002);

    if (ctx) {
        /* Scale to 2x for Retina rendering */
        scaleCTM(ctx, 2.0, 2.0);

        id layer = ((id(*)(id, SEL))objc_msgSend)(container, sel_registerName("layer"));
        ((void(*)(id, SEL, CGContextRef))objc_msgSend)(layer, sel_registerName("renderInContext:"), ctx);

        /* Pixel analysis */
        uint32_t *px = (uint32_t *)pixels;
        int nonzero = 0;
        for (int i = 0; i < px_w * px_h; i++) if (px[i] != 0) nonzero++;

        outf("Rendered: %dx%d pixels, %d/%d non-zero (%.1f%%)\n",
             px_w, px_h, nonzero, px_w * px_h, 100.0*nonzero/(px_w*px_h));

        /* Save raw */
        FILE *f = fopen("/tmp/rosettasim_retina.raw", "wb");
        if (f) { fwrite(pixels, 4, px_w * px_h, f); fclose(f); }

        relCtx(ctx);
    }
    relCS(cs);
    free(pixels);

    out("Saved /tmp/rosettasim_retina.raw (750x1334 BGRA)\n");
    _exit(0);
    return YES;
}
@end

int main(int argc, char *argv[]) {
    setenv("SIMULATOR_DEVICE_NAME", "iPhone 6s", 1);
    setenv("SIMULATOR_MODEL_IDENTIFIER", "iPhone8,1", 1);
    setenv("SIMULATOR_RUNTIME_VERSION", "10.3", 1);
    setenv("SIMULATOR_MAINSCREEN_WIDTH", "750", 1);
    setenv("SIMULATOR_MAINSCREEN_HEIGHT", "1334", 1);
    setenv("SIMULATOR_MAINSCREEN_SCALE", "2.0", 1);
    @autoreleasepool {
        typedef int (*Fn)(int, char*[], id, id);
        return ((Fn)dlsym(RTLD_DEFAULT, "UIApplicationMain"))(argc, argv, nil, @"RetinaDelegate");
    }
}
