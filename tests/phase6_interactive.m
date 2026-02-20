/*
 * Phase 6: Interactive touch test
 *
 * Creates a UIWindow with tappable colored rectangles that change color
 * when touched, proving the touch injection pipeline works end-to-end.
 *
 * Compile:
 *   SDK="/Applications/Xcode-8.3.3.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator10.3.sdk"
 *   clang -arch x86_64 -isysroot "$SDK" -mios-simulator-version-min=10.0 \
 *     -F"$SDK/System/Library/Frameworks" \
 *     -framework CoreFoundation -framework Foundation \
 *     -framework UIKit -framework QuartzCore -framework CoreGraphics \
 *     -fobjc-arc -o tests/phase6_interactive tests/phase6_interactive.m && \
 *   codesign -s - tests/phase6_interactive
 */

#import <stdlib.h>
#import <string.h>
#import <unistd.h>
#import <stdio.h>
#import <stdarg.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <CoreFoundation/CoreFoundation.h>
#import <Foundation/Foundation.h>

typedef struct { double x, y, w, h; } CGRect_t;
typedef id (*initFrame_fn)(id, SEL, CGRect_t);

static char _buf[4096];
void out(const char *msg) { write(STDOUT_FILENO, msg, strlen(msg)); }
void outf(const char *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    int n = vsnprintf(_buf, sizeof(_buf), fmt, ap); va_end(ap);
    if (n > 0) write(STDOUT_FILENO, _buf, n);
}

/* ================================================================
 * TapView — a UIView subclass that responds to touches
 * Created entirely at runtime to avoid @interface conflicts with ARC.
 * ================================================================ */

static void tapView_touchesBegan(id self, SEL _cmd, id touches, id event) {
    outf("  [TapView] touchesBegan! view=%p\n", (__bridge void *)self);

    /* Change background to a bright color */
    Class colorCls = objc_getClass("UIColor");
    id green = ((id(*)(id, SEL, double, double, double, double))objc_msgSend)(
        (id)colorCls, sel_registerName("colorWithRed:green:blue:alpha:"),
        0.2, 0.9, 0.3, 1.0);
    ((void(*)(id, SEL, id))objc_msgSend)(self, sel_registerName("setBackgroundColor:"), green);

    /* Also update the tag to track tap count */
    long tag = ((long(*)(id, SEL))objc_msgSend)(self, sel_registerName("tag"));
    ((void(*)(id, SEL, long))objc_msgSend)(self, sel_registerName("setTag:"), tag + 1);
    outf("  [TapView] Tap count: %ld\n", tag + 1);
}

static void tapView_touchesEnded(id self, SEL _cmd, id touches, id event) {
    outf("  [TapView] touchesEnded! view=%p\n", (__bridge void *)self);

    /* Cycle through colors based on tap count */
    long tag = ((long(*)(id, SEL))objc_msgSend)(self, sel_registerName("tag"));
    Class colorCls = objc_getClass("UIColor");

    double r, g, b;
    switch (tag % 5) {
        case 0: r=0.9; g=0.2; b=0.2; break;  /* Red */
        case 1: r=0.2; g=0.2; b=0.9; break;  /* Blue */
        case 2: r=0.9; g=0.9; b=0.2; break;  /* Yellow */
        case 3: r=0.9; g=0.2; b=0.9; break;  /* Purple */
        case 4: r=0.2; g=0.9; b=0.9; break;  /* Cyan */
        default: r=0.5; g=0.5; b=0.5; break;
    }

    id color = ((id(*)(id, SEL, double, double, double, double))objc_msgSend)(
        (id)colorCls, sel_registerName("colorWithRed:green:blue:alpha:"),
        r, g, b, 1.0);
    ((void(*)(id, SEL, id))objc_msgSend)(self, sel_registerName("setBackgroundColor:"), color);
}

static Class createTapViewClass(void) {
    Class existing = objc_getClass("RSTapView");
    if (existing) return existing;

    Class uiViewClass = objc_getClass("UIView");
    Class tapClass = objc_allocateClassPair(uiViewClass, "RSTapView", 0);
    if (!tapClass) return nil;

    class_addMethod(tapClass, sel_registerName("touchesBegan:withEvent:"),
                    (IMP)tapView_touchesBegan, "v@:@@");
    class_addMethod(tapClass, sel_registerName("touchesEnded:withEvent:"),
                    (IMP)tapView_touchesEnded, "v@:@@");

    objc_registerClassPair(tapClass);
    return tapClass;
}

/* ================================================================
 * App Delegate
 * ================================================================ */

@interface InteractiveDelegate : NSObject {
    id _window;
    id _statusLabel;
}
@property (nonatomic, strong) id window;
@end

@implementation InteractiveDelegate
@synthesize window = _window;

- (BOOL)application:(id)app didFinishLaunchingWithOptions:(id)opts {
    out("\n=== Phase 6: Interactive Touch Test ===\n\n");

    Class viewCls  = objc_getClass("UIView");
    Class labelCls = objc_getClass("UILabel");
    Class colorCls = objc_getClass("UIColor");
    Class fontCls  = objc_getClass("UIFont");
    Class winCls   = objc_getClass("UIWindow");
    Class tapCls   = createTapViewClass();
    SEL allocSel     = sel_registerName("alloc");
    SEL initFrameSel = sel_registerName("initWithFrame:");

    /* ---- Create UIWindow ---- */
    CGRect_t screenFrame = {0, 0, 375, 667};
    id window = ((initFrame_fn)objc_msgSend)(
        ((id(*)(id, SEL))objc_msgSend)((id)winCls, allocSel),
        initFrameSel, screenFrame);
    self.window = window;

    /* Dark background */
    id bgColor = ((id(*)(id, SEL, double, double, double, double))objc_msgSend)(
        (id)colorCls, sel_registerName("colorWithRed:green:blue:alpha:"),
        0.12, 0.12, 0.15, 1.0);
    ((void(*)(id, SEL, id))objc_msgSend)(window, sel_registerName("setBackgroundColor:"), bgColor);

    /* ---- Title ---- */
    CGRect_t titleFrame = {20, 40, 335, 40};
    id titleLabel = ((initFrame_fn)objc_msgSend)(
        ((id(*)(id, SEL))objc_msgSend)((id)labelCls, allocSel),
        initFrameSel, titleFrame);
    ((void(*)(id, SEL, id))objc_msgSend)(titleLabel, sel_registerName("setText:"),
        @"Touch Test");
    id white = ((id(*)(id, SEL))objc_msgSend)((id)colorCls, sel_registerName("whiteColor"));
    ((void(*)(id, SEL, id))objc_msgSend)(titleLabel, sel_registerName("setTextColor:"), white);
    id titleFont = ((id(*)(id, SEL, double))objc_msgSend)(
        (id)fontCls, sel_registerName("boldSystemFontOfSize:"), 28.0);
    ((void(*)(id, SEL, id))objc_msgSend)(titleLabel, sel_registerName("setFont:"), titleFont);
    ((void(*)(id, SEL, long))objc_msgSend)(titleLabel, sel_registerName("setTextAlignment:"), 1);
    ((void(*)(id, SEL, id))objc_msgSend)(window, sel_registerName("addSubview:"), titleLabel);

    /* ---- Instruction ---- */
    CGRect_t instrFrame = {20, 85, 335, 30};
    id instrLabel = ((initFrame_fn)objc_msgSend)(
        ((id(*)(id, SEL))objc_msgSend)((id)labelCls, allocSel),
        initFrameSel, instrFrame);
    ((void(*)(id, SEL, id))objc_msgSend)(instrLabel, sel_registerName("setText:"),
        @"Click the colored boxes to change them");
    id gray = ((id(*)(id, SEL, double, double, double, double))objc_msgSend)(
        (id)colorCls, sel_registerName("colorWithRed:green:blue:alpha:"),
        0.6, 0.6, 0.7, 1.0);
    ((void(*)(id, SEL, id))objc_msgSend)(instrLabel, sel_registerName("setTextColor:"), gray);
    id instrFont = ((id(*)(id, SEL, double))objc_msgSend)(
        (id)fontCls, sel_registerName("systemFontOfSize:"), 14.0);
    ((void(*)(id, SEL, id))objc_msgSend)(instrLabel, sel_registerName("setFont:"), instrFont);
    ((void(*)(id, SEL, long))objc_msgSend)(instrLabel, sel_registerName("setTextAlignment:"), 1);
    ((void(*)(id, SEL, id))objc_msgSend)(window, sel_registerName("addSubview:"), instrLabel);

    /* ---- Create tappable colored boxes ---- */
    struct { double x, y, w, h, r, g, b; } boxes[] = {
        { 30,  140, 145, 145, 0.9, 0.2, 0.2 },  /* Red */
        { 200, 140, 145, 145, 0.2, 0.2, 0.9 },  /* Blue */
        { 30,  310, 145, 145, 0.2, 0.8, 0.2 },  /* Green */
        { 200, 310, 145, 145, 0.9, 0.9, 0.2 },  /* Yellow */
        { 115, 480, 145, 100, 0.9, 0.4, 0.1 },  /* Orange (wide) */
    };
    int numBoxes = sizeof(boxes) / sizeof(boxes[0]);

    for (int i = 0; i < numBoxes; i++) {
        CGRect_t boxFrame = { boxes[i].x, boxes[i].y, boxes[i].w, boxes[i].h };
        id box = ((initFrame_fn)objc_msgSend)(
            ((id(*)(id, SEL))objc_msgSend)((id)tapCls, allocSel),
            initFrameSel, boxFrame);

        id color = ((id(*)(id, SEL, double, double, double, double))objc_msgSend)(
            (id)colorCls, sel_registerName("colorWithRed:green:blue:alpha:"),
            boxes[i].r, boxes[i].g, boxes[i].b, 1.0);
        ((void(*)(id, SEL, id))objc_msgSend)(box, sel_registerName("setBackgroundColor:"), color);

        /* Enable user interaction (UIView default is YES but TapView might differ) */
        ((void(*)(id, SEL, bool))objc_msgSend)(box, sel_registerName("setUserInteractionEnabled:"), true);

        /* Round corners */
        id layer = ((id(*)(id, SEL))objc_msgSend)(box, sel_registerName("layer"));
        ((void(*)(id, SEL, double))objc_msgSend)(layer, sel_registerName("setCornerRadius:"), 12.0);

        ((void(*)(id, SEL, id))objc_msgSend)(window, sel_registerName("addSubview:"), box);
    }

    /* ---- Status label ---- */
    CGRect_t statusFrame = {20, 610, 335, 40};
    _statusLabel = ((initFrame_fn)objc_msgSend)(
        ((id(*)(id, SEL))objc_msgSend)((id)labelCls, allocSel),
        initFrameSel, statusFrame);
    ((void(*)(id, SEL, id))objc_msgSend)(_statusLabel, sel_registerName("setText:"),
        @"Waiting for touch...");
    ((void(*)(id, SEL, id))objc_msgSend)(_statusLabel, sel_registerName("setTextColor:"), gray);
    id statusFont = ((id(*)(id, SEL, double))objc_msgSend)(
        (id)fontCls, sel_registerName("systemFontOfSize:"), 13.0);
    ((void(*)(id, SEL, id))objc_msgSend)(_statusLabel, sel_registerName("setFont:"), statusFont);
    ((void(*)(id, SEL, long))objc_msgSend)(_statusLabel, sel_registerName("setTextAlignment:"), 1);
    ((void(*)(id, SEL, id))objc_msgSend)(window, sel_registerName("addSubview:"), _statusLabel);

    /* ---- Layout ---- */
    ((void(*)(id, SEL))objc_msgSend)(window, sel_registerName("layoutIfNeeded"));

    out("UI created with 5 tappable boxes.\n");
    out("Click boxes in the host app to change their colors.\n\n");
    return YES;
}

@end

/* ---- Main ---- */
int main(int argc, char *argv[]) {
    @autoreleasepool {
        typedef int (*Fn)(int, char*[], id, id);
        Fn fn = (Fn)dlsym(RTLD_DEFAULT, "UIApplicationMain");
        return fn(argc, argv, nil, @"InteractiveDelegate");
    }
}
