/*
 * Phase 4b: UIWindow rendering test
 *
 * Creates a UIWindow with a colored view, forces a render,
 * and tries to capture the output. This tests whether
 * CoreAnimation can render without a CARenderServer.
 *
 * Compile:
 *   clang -arch x86_64 -isysroot {SDK} -mios-simulator-version-min=10.0
 *         -framework CoreFoundation -framework Foundation -framework UIKit
 *         -framework QuartzCore -framework CoreGraphics
 *         -fobjc-arc -o phase4b_render_test phase4b_render_test.m
 *
 * Run:
 *   DYLD_ROOT_PATH={SDK} DYLD_INSERT_LIBRARIES=bridge.dylib ./phase4b_render_test
 */

#import <stdlib.h>
#import <string.h>
#import <unistd.h>
#import <stdio.h>
#import <stdarg.h>
#import <signal.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <execinfo.h>
#import <CoreFoundation/CoreFoundation.h>
#import <Foundation/Foundation.h>

typedef struct { double x, y, w, h; } CGRect_t;

/* ---- Raw output ---- */
static char _buf[8192];
void out(const char *msg) { write(STDOUT_FILENO, msg, strlen(msg)); }
void outf(const char *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    int n = vsnprintf(_buf, sizeof(_buf), fmt, ap); va_end(ap);
    if (n > 0) write(STDOUT_FILENO, _buf, n);
}

/* ---- Signal handler ---- */
void signal_handler(int sig) {
    outf("\n!!! SIGNAL %d received\n", sig);
    void *frames[32];
    int count = backtrace(frames, 32);
    backtrace_symbols_fd(frames, count, STDOUT_FILENO);
    _exit(128 + sig);
}

/* ---- App Delegate ---- */
@interface RenderTestDelegate : NSObject
@end

@implementation RenderTestDelegate

- (BOOL)application:(id)application didFinishLaunchingWithOptions:(id)options {
    out("\n╔══════════════════════════════════════════════════════╗\n");
    out("║  Phase 4b: Rendering Test - didFinishLaunching      ║\n");
    out("╚══════════════════════════════════════════════════════╝\n\n");

    /* ---- UIScreen info ---- */
    Class uiScreenClass = objc_getClass("UIScreen");
    SEL mainScreenSel = sel_registerName("mainScreen");
    id mainScreen = ((id(*)(id, SEL))objc_msgSend)((id)uiScreenClass, mainScreenSel);

    if (mainScreen) {
        SEL boundsSel = sel_registerName("bounds");

        /* CGRect is returned in registers on x86_64 for small structs,
           but UIScreen.bounds returns CGRect which is 32 bytes.
           Use objc_msgSend_stret for structs > 16 bytes on x86_64 */
        CGRect_t bounds;

        /* On x86_64, CGRect (32 bytes) is returned via hidden pointer (stret) */
        typedef void (*stret_fn)(CGRect_t *, id, SEL);
        stret_fn getBounds = (stret_fn)dlsym(RTLD_DEFAULT, "objc_msgSend_stret");
        if (getBounds) {
            getBounds(&bounds, mainScreen, boundsSel);
            outf("UIScreen.mainScreen.bounds: {{%.0f, %.0f}, {%.0f, %.0f}}\n",
                 bounds.x, bounds.y, bounds.w, bounds.h);
        } else {
            out("WARNING: objc_msgSend_stret not found\n");
        }

        SEL scaleSel = sel_registerName("scale");
        /* scale returns CGFloat (double on 64-bit) - fits in register */
        double scale = ((double(*)(id, SEL))objc_msgSend)(mainScreen, scaleSel);
        outf("UIScreen.mainScreen.scale: %.1f\n\n", scale);
    } else {
        out("WARNING: UIScreen.mainScreen is nil!\n\n");
    }

    /* ---- Create UIWindow ---- */
    out("--- Creating UIWindow ---\n");
    Class uiWindowClass = objc_getClass("UIWindow");
    if (!uiWindowClass) {
        out("ERROR: UIWindow class not found\n");
        _exit(1);
    }

    SEL allocSel = sel_registerName("alloc");
    SEL initFrameSel = sel_registerName("initWithFrame:");

    /* Create window with screen bounds */
    CGRect_t screenBounds = {0, 0, 375, 667};  /* iPhone 6s points */

    /* initWithFrame: takes a CGRect by value */
    typedef id (*initWithFrame_fn)(id, SEL, CGRect_t);
    initWithFrame_fn initFrame = (initWithFrame_fn)objc_msgSend;

    id window = initFrame(
        ((id(*)(id, SEL))objc_msgSend)((id)uiWindowClass, allocSel),
        initFrameSel, screenBounds);

    if (window) {
        outf("  UIWindow created: %p\n", (__bridge void *)window);
    } else {
        out("  ERROR: UIWindow creation failed\n");
        _exit(1);
    }

    /* ---- Set background color ---- */
    out("--- Setting background color ---\n");
    Class uiColorClass = objc_getClass("UIColor");
    SEL redColorSel = sel_registerName("redColor");
    id redColor = ((id(*)(id, SEL))objc_msgSend)((id)uiColorClass, redColorSel);

    SEL setBgSel = sel_registerName("setBackgroundColor:");
    ((void(*)(id, SEL, id))objc_msgSend)(window, setBgSel, redColor);
    outf("  backgroundColor set to red: %p\n", (__bridge void *)redColor);

    /* ---- Add a label ---- */
    out("--- Creating UILabel ---\n");
    Class uiLabelClass = objc_getClass("UILabel");
    if (uiLabelClass) {
        CGRect_t labelFrame = {50, 200, 275, 100};
        id label = initFrame(
            ((id(*)(id, SEL))objc_msgSend)((id)uiLabelClass, allocSel),
            initFrameSel, labelFrame);

        if (label) {
            /* Set text */
            SEL setTextSel = sel_registerName("setText:");
            NSString *text = @"Hello from RosettaSim!\niOS 10.3 on macOS 26";
            ((void(*)(id, SEL, id))objc_msgSend)(label, setTextSel, text);

            /* Set text color to white */
            SEL whiteColorSel = sel_registerName("whiteColor");
            id whiteColor = ((id(*)(id, SEL))objc_msgSend)((id)uiColorClass, whiteColorSel);
            SEL setTextColorSel = sel_registerName("setTextColor:");
            ((void(*)(id, SEL, id))objc_msgSend)(label, setTextColorSel, whiteColor);

            /* Set font size */
            Class uiFontClass = objc_getClass("UIFont");
            SEL boldFontSel = sel_registerName("boldSystemFontOfSize:");
            id font = ((id(*)(id, SEL, double))objc_msgSend)((id)uiFontClass, boldFontSel, 24.0);
            SEL setFontSel = sel_registerName("setFont:");
            ((void(*)(id, SEL, id))objc_msgSend)(label, setFontSel, font);

            /* Set number of lines */
            SEL setLinesSel = sel_registerName("setNumberOfLines:");
            ((void(*)(id, SEL, long))objc_msgSend)(label, setLinesSel, 0);

            /* Set text alignment to center */
            SEL setAlignSel = sel_registerName("setTextAlignment:");
            ((void(*)(id, SEL, long))objc_msgSend)(label, setAlignSel, 1); /* NSTextAlignmentCenter */

            /* Add to window */
            SEL addSubSel = sel_registerName("addSubview:");
            ((void(*)(id, SEL, id))objc_msgSend)(window, addSubSel, label);
            outf("  UILabel created and added: %p\n", (__bridge void *)label);
        }
    }

    /* ---- Make window visible ---- */
    out("--- Making window visible ---\n");
    SEL makeKeySel = sel_registerName("makeKeyAndVisible");
    ((void(*)(id, SEL))objc_msgSend)(window, makeKeySel);
    out("  makeKeyAndVisible called\n");

    /* ---- Force layout ---- */
    out("--- Forcing layout ---\n");
    SEL layoutSel = sel_registerName("layoutIfNeeded");
    ((void(*)(id, SEL))objc_msgSend)(window, layoutSel);
    out("  layoutIfNeeded called\n");

    /* ---- Try to render the layer to a CGContext ---- */
    out("\n--- Attempting to render layer to bitmap ---\n");
    SEL layerSel = sel_registerName("layer");
    id layer = ((id(*)(id, SEL))objc_msgSend)(window, layerSel);
    outf("  Window layer: %p\n", (__bridge void *)layer);

    if (layer) {
        /* Create a bitmap context */
        int width = 750;   /* 375 * 2 */
        int height = 1334; /* 667 * 2 */
        int bpp = 4;

        typedef void * CGColorSpaceRef;
        typedef void * CGContextRef;

        /* CGColorSpaceCreateDeviceRGB */
        typedef CGColorSpaceRef (*CGColorSpaceCreateFn)(void);
        CGColorSpaceCreateFn createColorSpace =
            (CGColorSpaceCreateFn)dlsym(RTLD_DEFAULT, "CGColorSpaceCreateDeviceRGB");

        /* CGBitmapContextCreate */
        typedef CGContextRef (*CGBitmapContextCreateFn)(void *, size_t, size_t,
            size_t, size_t, CGColorSpaceRef, uint32_t);
        CGBitmapContextCreateFn createCtx =
            (CGBitmapContextCreateFn)dlsym(RTLD_DEFAULT, "CGBitmapContextCreate");

        /* CGContextScaleCTM */
        typedef void (*CGContextScaleCTMFn)(CGContextRef, double, double);
        CGContextScaleCTMFn scaleCTM =
            (CGContextScaleCTMFn)dlsym(RTLD_DEFAULT, "CGContextScaleCTM");

        /* CGContextRelease */
        typedef void (*CGContextReleaseFn)(CGContextRef);
        CGContextReleaseFn releaseCtx =
            (CGContextReleaseFn)dlsym(RTLD_DEFAULT, "CGContextRelease");

        /* CGColorSpaceRelease */
        typedef void (*CGColorSpaceReleaseFn)(CGColorSpaceRef);
        CGColorSpaceReleaseFn releaseCS =
            (CGColorSpaceReleaseFn)dlsym(RTLD_DEFAULT, "CGColorSpaceRelease");

        /* CGBitmapContextGetData */
        typedef void * (*CGBitmapContextGetDataFn)(CGContextRef);
        CGBitmapContextGetDataFn getData =
            (CGBitmapContextGetDataFn)dlsym(RTLD_DEFAULT, "CGBitmapContextGetData");

        if (createColorSpace && createCtx) {
            CGColorSpaceRef cs = createColorSpace();
            /* kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little = 0x2002 */
            void *pixels = calloc(width * height, bpp);
            CGContextRef ctx = createCtx(pixels, width, height, 8, width * bpp, cs, 0x2002);

            if (ctx) {
                outf("  Created bitmap context: %dx%d\n", width, height);

                /* Scale to 2x for Retina */
                scaleCTM(ctx, 2.0, 2.0);

                /* Render the layer into the bitmap context */
                SEL renderSel = sel_registerName("renderInContext:");
                outf("  Calling [layer renderInContext:ctx]...\n");
                ((void(*)(id, SEL, CGContextRef))objc_msgSend)(layer, renderSel, ctx);
                out("  renderInContext: completed!\n");

                /* Check if any pixels are non-zero (rendered something) */
                uint32_t *px = (uint32_t *)pixels;
                int nonzero = 0;
                uint32_t first_nonzero = 0;
                for (int i = 0; i < width * height; i++) {
                    if (px[i] != 0) {
                        if (nonzero == 0) first_nonzero = px[i];
                        nonzero++;
                    }
                }
                outf("  Non-zero pixels: %d / %d (%.1f%%)\n",
                     nonzero, width * height,
                     100.0 * nonzero / (width * height));
                if (nonzero > 0) {
                    outf("  First non-zero pixel: 0x%08x (BGRA)\n", first_nonzero);

                    /* Try to save as raw bitmap for inspection */
                    const char *outpath = "/tmp/rosettasim_render.raw";
                    FILE *f = fopen(outpath, "wb");
                    if (f) {
                        fwrite(pixels, bpp, width * height, f);
                        fclose(f);
                        outf("  Saved raw bitmap to: %s (%dx%d BGRA)\n", outpath, width, height);
                        out("  (View with: convert -size 750x1334 -depth 8 bgra:/tmp/rosettasim_render.raw /tmp/rosettasim_render.png)\n");
                    }

                    out("\n*** PHASE 4b: RENDERING WORKS! ***\n");
                } else {
                    out("\n  All pixels are zero - no rendering occurred.\n");
                    out("  This may mean CoreAnimation needs a display connection.\n");
                }

                releaseCtx(ctx);
            } else {
                out("  ERROR: Could not create bitmap context\n");
            }

            releaseCS(cs);
            free(pixels);
        } else {
            out("  ERROR: CoreGraphics functions not found\n");
        }
    }

    out("\n*** Phase 4b test complete - exiting ***\n");
    _exit(0);
    return YES;
}
@end

/* ---- Main ---- */
int main(int argc, char *argv[]) {
    out("╔══════════════════════════════════════════════════════╗\n");
    out("║  RosettaSim Phase 4b: Rendering Test                ║\n");
    out("╚══════════════════════════════════════════════════════╝\n\n");

    signal(SIGABRT, signal_handler);
    signal(SIGSEGV, signal_handler);
    signal(SIGBUS, signal_handler);
    signal(SIGTRAP, signal_handler);

    typedef void (*NSSetUncaughtExceptionHandlerFunc)(void (*)(id));
    NSSetUncaughtExceptionHandlerFunc setHandler =
        (NSSetUncaughtExceptionHandlerFunc)dlsym(RTLD_DEFAULT, "NSSetUncaughtExceptionHandler");
    /* Exception handler set up in bridge library */

    setenv("SIMULATOR_DEVICE_NAME", "iPhone 6s", 1);
    setenv("SIMULATOR_MODEL_IDENTIFIER", "iPhone8,1", 1);
    setenv("SIMULATOR_RUNTIME_VERSION", "10.3", 1);
    setenv("SIMULATOR_MAINSCREEN_WIDTH", "750", 1);
    setenv("SIMULATOR_MAINSCREEN_HEIGHT", "1334", 1);
    setenv("SIMULATOR_MAINSCREEN_SCALE", "2.0", 1);

    @autoreleasepool {
        typedef int (*UIApplicationMainFunc)(int, char *[], id, id);
        UIApplicationMainFunc uiAppMain =
            (UIApplicationMainFunc)dlsym(RTLD_DEFAULT, "UIApplicationMain");
        return uiAppMain(argc, argv, nil, @"RenderTestDelegate");
    }
}
