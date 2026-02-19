/*
 * Phase 4b Simplified: Skip makeKeyAndVisible, render layer directly
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

static char _buf[8192];
void out(const char *msg) { write(STDOUT_FILENO, msg, strlen(msg)); }
void outf(const char *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    int n = vsnprintf(_buf, sizeof(_buf), fmt, ap); va_end(ap);
    if (n > 0) write(STDOUT_FILENO, _buf, n);
}

@interface SimpleDelegate : NSObject
@end

@implementation SimpleDelegate
- (BOOL)application:(id)application didFinishLaunchingWithOptions:(id)options {
    out("\n=== Phase 4b Simple Render Test ===\n\n");

    /* Check screen info globals */
    out("--- Screen info globals ---\n");
    double *gsWidth = (double *)dlsym(RTLD_DEFAULT, "kGSMainScreenWidth");
    double *gsHeight = (double *)dlsym(RTLD_DEFAULT, "kGSMainScreenHeight");
    double *gsScale = (double *)dlsym(RTLD_DEFAULT, "kGSMainScreenScale");
    if (gsWidth) outf("  kGSMainScreenWidth:  %f\n", *gsWidth);
    if (gsHeight) outf("  kGSMainScreenHeight: %f\n", *gsHeight);
    if (gsScale) outf("  kGSMainScreenScale:  %f\n", *gsScale);

    /* Also check SIMULATOR env vars */
    outf("  SIMULATOR_MAINSCREEN_WIDTH:  %s\n", getenv("SIMULATOR_MAINSCREEN_WIDTH") ?: "(not set)");
    outf("  SIMULATOR_MAINSCREEN_HEIGHT: %s\n", getenv("SIMULATOR_MAINSCREEN_HEIGHT") ?: "(not set)");
    outf("  SIMULATOR_MAINSCREEN_SCALE:  %s\n", getenv("SIMULATOR_MAINSCREEN_SCALE") ?: "(not set)");

    /* Check UIScreen */
    out("\n--- UIScreen ---\n");
    Class uiScreenClass = objc_getClass("UIScreen");
    SEL mainScreenSel = sel_registerName("mainScreen");
    id screen = ((id(*)(id, SEL))objc_msgSend)((id)uiScreenClass, mainScreenSel);
    outf("  mainScreen: %p\n", (__bridge void *)screen);

    if (screen) {
        SEL scaleSel = sel_registerName("scale");
        double scale = ((double(*)(id, SEL))objc_msgSend)(screen, scaleSel);
        outf("  scale: %.1f\n", scale);
    }

    /* Create a simple UIView with a colored background */
    out("\n--- Creating UIView (no window) ---\n");
    Class uiViewClass = objc_getClass("UIView");
    SEL allocSel = sel_registerName("alloc");
    SEL initFrameSel = sel_registerName("initWithFrame:");

    CGRect_t frame = {0, 0, 200, 200};
    typedef id (*initWithFrame_fn)(id, SEL, CGRect_t);

    id view = ((initWithFrame_fn)objc_msgSend)(
        ((id(*)(id, SEL))objc_msgSend)((id)uiViewClass, allocSel),
        initFrameSel, frame);
    outf("  UIView created: %p\n", (__bridge void *)view);

    /* Set red background */
    Class uiColorClass = objc_getClass("UIColor");
    SEL redSel = sel_registerName("redColor");
    id red = ((id(*)(id, SEL))objc_msgSend)((id)uiColorClass, redSel);
    SEL setBgSel = sel_registerName("setBackgroundColor:");
    ((void(*)(id, SEL, id))objc_msgSend)(view, setBgSel, red);

    /* Get the layer */
    SEL layerSel = sel_registerName("layer");
    id layer = ((id(*)(id, SEL))objc_msgSend)(view, layerSel);
    outf("  layer: %p\n", (__bridge void *)layer);

    /* Force layout */
    SEL layoutSel = sel_registerName("layoutIfNeeded");
    ((void(*)(id, SEL))objc_msgSend)(view, layoutSel);
    out("  layoutIfNeeded called\n");

    /* Render the layer into a bitmap */
    out("\n--- Rendering layer to bitmap ---\n");
    int w = 200, h = 200;

    typedef void * CGColorSpaceRef;
    typedef void * CGContextRef;

    CGColorSpaceRef (*createCS)(void) = dlsym(RTLD_DEFAULT, "CGColorSpaceCreateDeviceRGB");
    CGContextRef (*createBitmap)(void*, size_t, size_t, size_t, size_t, CGColorSpaceRef, uint32_t) =
        dlsym(RTLD_DEFAULT, "CGBitmapContextCreate");
    void (*releaseCtx)(CGContextRef) = dlsym(RTLD_DEFAULT, "CGContextRelease");
    void (*releaseCS)(CGColorSpaceRef) = dlsym(RTLD_DEFAULT, "CGColorSpaceRelease");

    if (createCS && createBitmap) {
        CGColorSpaceRef cs = createCS();
        void *pixels = calloc(w * h, 4);
        CGContextRef ctx = createBitmap(pixels, w, h, 8, w * 4, cs, 0x2002);

        if (ctx) {
            outf("  Bitmap context created: %dx%d\n", w, h);

            /* Render the layer */
            out("  Calling [layer renderInContext:]...\n");
            SEL renderSel = sel_registerName("renderInContext:");
            ((void(*)(id, SEL, CGContextRef))objc_msgSend)(layer, renderSel, ctx);
            out("  renderInContext completed!\n");

            /* Check pixels */
            uint32_t *px = (uint32_t *)pixels;
            int nonzero = 0;
            uint32_t sample = 0;
            for (int i = 0; i < w * h; i++) {
                if (px[i] != 0) {
                    if (nonzero == 0) sample = px[i];
                    nonzero++;
                }
            }
            outf("  Non-zero pixels: %d/%d (%.1f%%)\n",
                 nonzero, w * h, 100.0 * nonzero / (w * h));

            if (nonzero > 0) {
                /* Decode the sample pixel (BGRA format) */
                uint8_t b = sample & 0xFF;
                uint8_t g = (sample >> 8) & 0xFF;
                uint8_t r = (sample >> 16) & 0xFF;
                uint8_t a = (sample >> 24) & 0xFF;
                outf("  Sample pixel: R=%d G=%d B=%d A=%d (0x%08x)\n", r, g, b, a, sample);

                /* Save raw bitmap */
                FILE *f = fopen("/tmp/rosettasim_view.raw", "wb");
                if (f) { fwrite(pixels, 4, w * h, f); fclose(f); }
                outf("  Saved to /tmp/rosettasim_view.raw (%dx%d BGRA)\n", w, h);

                out("\n*** RENDERING WORKS! UIView rendered to bitmap! ***\n");
            } else {
                out("\n  No pixels rendered. Layer may be empty.\n");

                /* Try rendering a solid color rectangle directly with CG */
                out("  Fallback: drawing directly with CoreGraphics...\n");
                void (*cgSetFill)(CGContextRef, double, double, double, double) =
                    dlsym(RTLD_DEFAULT, "CGContextSetRGBFillColor");
                void (*cgFillRect)(CGContextRef, CGRect_t) =
                    dlsym(RTLD_DEFAULT, "CGContextFillRect");

                if (cgSetFill && cgFillRect) {
                    memset(pixels, 0, w * h * 4);
                    cgSetFill(ctx, 0.0, 0.0, 1.0, 1.0); /* blue */
                    CGRect_t fillRect = {0, 0, 200, 200};
                    cgFillRect(ctx, fillRect);

                    /* Check again */
                    nonzero = 0;
                    for (int i = 0; i < w * h; i++) {
                        if (px[i] != 0) { if (nonzero == 0) sample = px[i]; nonzero++; }
                    }
                    outf("  After CG fill: %d/%d non-zero pixels\n", nonzero, w * h);
                    if (nonzero > 0) {
                        uint8_t b2 = sample & 0xFF;
                        uint8_t g2 = (sample >> 8) & 0xFF;
                        uint8_t r2 = (sample >> 16) & 0xFF;
                        uint8_t a2 = (sample >> 24) & 0xFF;
                        outf("  Sample: R=%d G=%d B=%d A=%d\n", r2, g2, b2, a2);
                        out("  CoreGraphics rendering works!\n");
                    }
                }
            }

            releaseCtx(ctx);
        }

        releaseCS(cs);
        free(pixels);
    }

    out("\n=== Phase 4b simple test complete ===\n");
    _exit(0);
    return YES;
}
@end

int main(int argc, char *argv[]) {
    signal(SIGABRT, SIG_DFL);  /* Let bridge handle abort */
    signal(SIGSEGV, SIG_DFL);

    setenv("SIMULATOR_DEVICE_NAME", "iPhone 6s", 1);
    setenv("SIMULATOR_MODEL_IDENTIFIER", "iPhone8,1", 1);
    setenv("SIMULATOR_RUNTIME_VERSION", "10.3", 1);
    setenv("SIMULATOR_MAINSCREEN_WIDTH", "750", 1);
    setenv("SIMULATOR_MAINSCREEN_HEIGHT", "1334", 1);
    setenv("SIMULATOR_MAINSCREEN_SCALE", "2.0", 1);

    @autoreleasepool {
        typedef int (*UIAppMainFn)(int, char*[], id, id);
        UIAppMainFn fn = (UIAppMainFn)dlsym(RTLD_DEFAULT, "UIApplicationMain");
        return fn(argc, argv, nil, @"SimpleDelegate");
    }
}
