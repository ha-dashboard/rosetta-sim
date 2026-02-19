/*
 * Phase 4b: Text rendering test
 * Renders a UILabel with text to verify fonts, CoreText, and text layout work.
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

@interface TextDelegate : NSObject
@end

@implementation TextDelegate
- (BOOL)application:(id)app didFinishLaunchingWithOptions:(id)opts {
    out("\n=== Phase 4b: Text Rendering Test ===\n\n");

    Class viewCls = objc_getClass("UIView");
    Class labelCls = objc_getClass("UILabel");
    Class colorCls = objc_getClass("UIColor");
    Class fontCls = objc_getClass("UIFont");
    SEL allocSel = sel_registerName("alloc");
    SEL initFrameSel = sel_registerName("initWithFrame:");
    typedef id (*initFrame_fn)(id, SEL, CGRect_t);

    /* Create a container view with blue background */
    CGRect_t containerFrame = {0, 0, 375, 667};
    id container = ((initFrame_fn)objc_msgSend)(
        ((id(*)(id, SEL))objc_msgSend)((id)viewCls, allocSel),
        initFrameSel, containerFrame);

    id blue = ((id(*)(id, SEL))objc_msgSend)((id)colorCls, sel_registerName("blueColor"));
    ((void(*)(id, SEL, id))objc_msgSend)(container, sel_registerName("setBackgroundColor:"), blue);

    /* Create a label */
    CGRect_t labelFrame = {20, 100, 335, 200};
    id label = ((initFrame_fn)objc_msgSend)(
        ((id(*)(id, SEL))objc_msgSend)((id)labelCls, allocSel),
        initFrameSel, labelFrame);

    /* Set text */
    NSString *text = @"RosettaSim\niOS 10.3.1 Simulator\nRunning on macOS 26\nvia Rosetta 2";
    ((void(*)(id, SEL, id))objc_msgSend)(label, sel_registerName("setText:"), text);

    /* White text, bold font, centered, multi-line */
    id white = ((id(*)(id, SEL))objc_msgSend)((id)colorCls, sel_registerName("whiteColor"));
    ((void(*)(id, SEL, id))objc_msgSend)(label, sel_registerName("setTextColor:"), white);

    id font = ((id(*)(id, SEL, double))objc_msgSend)((id)fontCls, sel_registerName("boldSystemFontOfSize:"), 28.0);
    ((void(*)(id, SEL, id))objc_msgSend)(label, sel_registerName("setFont:"), font);

    ((void(*)(id, SEL, long))objc_msgSend)(label, sel_registerName("setNumberOfLines:"), 0);
    ((void(*)(id, SEL, long))objc_msgSend)(label, sel_registerName("setTextAlignment:"), 1); /* center */

    /* Add label to container */
    ((void(*)(id, SEL, id))objc_msgSend)(container, sel_registerName("addSubview:"), label);

    /* Layout */
    ((void(*)(id, SEL))objc_msgSend)(container, sel_registerName("layoutIfNeeded"));

    /* Render to bitmap */
    int w = 375, h = 667;
    typedef void *CGColorSpaceRef, *CGContextRef;

    CGColorSpaceRef (*mkCS)(void) = dlsym(RTLD_DEFAULT, "CGColorSpaceCreateDeviceRGB");
    CGContextRef (*mkBmp)(void*,size_t,size_t,size_t,size_t,CGColorSpaceRef,uint32_t) =
        dlsym(RTLD_DEFAULT, "CGBitmapContextCreate");
    void (*relCtx)(CGContextRef) = dlsym(RTLD_DEFAULT, "CGContextRelease");
    void (*relCS)(CGColorSpaceRef) = dlsym(RTLD_DEFAULT, "CGColorSpaceRelease");

    CGColorSpaceRef cs = mkCS();
    void *pixels = calloc(w * h, 4);
    CGContextRef ctx = mkBmp(pixels, w, h, 8, w * 4, cs, 0x2002);

    if (ctx) {
        /* Render */
        id containerLayer = ((id(*)(id, SEL))objc_msgSend)(container, sel_registerName("layer"));
        ((void(*)(id, SEL, CGContextRef))objc_msgSend)(containerLayer, sel_registerName("renderInContext:"), ctx);

        /* Analyze pixels */
        uint32_t *px = (uint32_t *)pixels;
        int blue_px = 0, white_px = 0, other_px = 0, zero_px = 0;
        for (int i = 0; i < w * h; i++) {
            uint8_t r = (px[i] >> 16) & 0xFF;
            uint8_t g = (px[i] >> 8) & 0xFF;
            uint8_t b = px[i] & 0xFF;
            uint8_t a = (px[i] >> 24) & 0xFF;
            if (px[i] == 0) zero_px++;
            else if (r == 0 && g == 0 && b == 255 && a == 255) blue_px++;
            else if (r > 200 && g > 200 && b > 200 && a > 200) white_px++;
            else other_px++;
        }
        outf("Pixel analysis (%dx%d):\n", w, h);
        outf("  Blue  (background): %d pixels (%.1f%%)\n", blue_px, 100.0*blue_px/(w*h));
        outf("  White (text):       %d pixels (%.1f%%)\n", white_px, 100.0*white_px/(w*h));
        outf("  Other (antialiased):%d pixels (%.1f%%)\n", other_px, 100.0*other_px/(w*h));
        outf("  Zero  (empty):      %d pixels (%.1f%%)\n", zero_px, 100.0*zero_px/(w*h));

        if (white_px > 0 || other_px > 1000) {
            out("\n*** TEXT RENDERING WORKS! ***\n");
            out("*** UIKit + CoreText + Fonts all functional ***\n");
        } else if (blue_px > 0) {
            out("\n  Background rendered but no text visible.\n");
        } else {
            out("\n  Nothing rendered.\n");
        }

        /* Save for visual inspection */
        FILE *f = fopen("/tmp/rosettasim_text.raw", "wb");
        if (f) { fwrite(pixels, 4, w * h, f); fclose(f); }
        outf("  Saved to /tmp/rosettasim_text.raw (%dx%d BGRA)\n", w, h);
        out("  Convert: magick -size 375x667 -depth 8 bgra:/tmp/rosettasim_text.raw /tmp/rosettasim_text.png\n");

        relCtx(ctx);
    }
    relCS(cs);
    free(pixels);

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
        Fn fn = (Fn)dlsym(RTLD_DEFAULT, "UIApplicationMain");
        return fn(argc, argv, nil, @"TextDelegate");
    }
}
