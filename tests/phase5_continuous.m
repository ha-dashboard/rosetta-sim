/*
 * Phase 5: Continuous rendering test
 *
 * Creates a UIWindow with dynamic content (updating counter label).
 * Does NOT call _exit() — the bridge's CFRunLoop and frame capture timer
 * handle continuous rendering to the shared framebuffer.
 *
 * The delegate exposes a `window` property so the bridge can find it
 * via find_root_window().
 *
 * Compile:
 *   SDK="/Applications/Xcode-8.3.3.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator10.3.sdk"
 *   clang -arch x86_64 \
 *     -isysroot "$SDK" -mios-simulator-version-min=10.0 \
 *     -F"$SDK/System/Library/Frameworks" \
 *     -framework CoreFoundation -framework Foundation \
 *     -framework UIKit -framework QuartzCore -framework CoreGraphics \
 *     -fobjc-arc \
 *     -o tests/phase5_continuous tests/phase5_continuous.m && \
 *   codesign -s - tests/phase5_continuous
 *
 * Run:
 *   ./scripts/run_sim.sh ./tests/phase5_continuous
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
 * App Delegate with window property
 * ================================================================ */

@interface ContinuousDelegate : NSObject {
    id _window;
    id _counterLabel;
    id _timeLabel;
    int _tickCount;
}
@property (nonatomic, strong) id window;
@end

@implementation ContinuousDelegate
@synthesize window = _window;

- (BOOL)application:(id)app didFinishLaunchingWithOptions:(id)opts {
    out("\n=== Phase 5: Continuous Rendering ===\n\n");

    Class viewCls  = objc_getClass("UIView");
    Class labelCls = objc_getClass("UILabel");
    Class colorCls = objc_getClass("UIColor");
    Class fontCls  = objc_getClass("UIFont");
    Class winCls   = objc_getClass("UIWindow");
    SEL allocSel     = sel_registerName("alloc");
    SEL initFrameSel = sel_registerName("initWithFrame:");

    /* ---- Create UIWindow ---- */
    CGRect_t screenFrame = {0, 0, 375, 667};
    id window = ((initFrame_fn)objc_msgSend)(
        ((id(*)(id, SEL))objc_msgSend)((id)winCls, allocSel),
        initFrameSel, screenFrame);
    self.window = window;
    outf("UIWindow created: %p\n", (__bridge void *)window);

    /* ---- Window visibility (UIWindow defaults to hidden=YES, unlike UIView) ---- */
    ((void(*)(id, SEL, bool))objc_msgSend)(window, sel_registerName("setHidden:"), false);
    ((void(*)(id, SEL, bool))objc_msgSend)(window, sel_registerName("setOpaque:"), true);

    /* ---- Dark background ---- */
    id bgColor = ((id(*)(id, SEL, double, double, double, double))objc_msgSend)(
        (id)colorCls, sel_registerName("colorWithRed:green:blue:alpha:"),
        0.08, 0.08, 0.3, 1.0);
    ((void(*)(id, SEL, id))objc_msgSend)(window, sel_registerName("setBackgroundColor:"), bgColor);

    /* ---- Status bar area ---- */
    CGRect_t statusFrame = {0, 0, 375, 20};
    id statusBar = ((initFrame_fn)objc_msgSend)(
        ((id(*)(id, SEL))objc_msgSend)((id)viewCls, allocSel),
        initFrameSel, statusFrame);
    id darkColor = ((id(*)(id, SEL, double, double, double, double))objc_msgSend)(
        (id)colorCls, sel_registerName("colorWithRed:green:blue:alpha:"),
        0.04, 0.04, 0.15, 1.0);
    ((void(*)(id, SEL, id))objc_msgSend)(statusBar, sel_registerName("setBackgroundColor:"), darkColor);
    ((void(*)(id, SEL, id))objc_msgSend)(window, sel_registerName("addSubview:"), statusBar);

    /* ---- Title ---- */
    CGRect_t titleFrame = {20, 70, 335, 50};
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
    ((void(*)(id, SEL, id))objc_msgSend)(window, sel_registerName("addSubview:"), titleLabel);

    /* ---- Subtitle ---- */
    CGRect_t subFrame = {20, 125, 335, 80};
    id subLabel = ((initFrame_fn)objc_msgSend)(
        ((id(*)(id, SEL))objc_msgSend)((id)labelCls, allocSel),
        initFrameSel, subFrame);
    ((void(*)(id, SEL, id))objc_msgSend)(subLabel, sel_registerName("setText:"),
        @"iOS 10.3.1 Simulator\nRunning on macOS 26\nApple Silicon via Rosetta 2");
    id lightGray = ((id(*)(id, SEL, double, double, double, double))objc_msgSend)(
        (id)colorCls, sel_registerName("colorWithRed:green:blue:alpha:"),
        0.75, 0.75, 0.85, 1.0);
    ((void(*)(id, SEL, id))objc_msgSend)(subLabel, sel_registerName("setTextColor:"), lightGray);
    id subFont = ((id(*)(id, SEL, double))objc_msgSend)(
        (id)fontCls, sel_registerName("systemFontOfSize:"), 17.0);
    ((void(*)(id, SEL, id))objc_msgSend)(subLabel, sel_registerName("setFont:"), subFont);
    ((void(*)(id, SEL, long))objc_msgSend)(subLabel, sel_registerName("setNumberOfLines:"), 0);
    ((void(*)(id, SEL, long))objc_msgSend)(subLabel, sel_registerName("setTextAlignment:"), 1);
    ((void(*)(id, SEL, id))objc_msgSend)(window, sel_registerName("addSubview:"), subLabel);

    /* ---- System info (green monospace) ---- */
    CGRect_t infoFrame = {20, 250, 335, 180};
    id infoLabel = ((initFrame_fn)objc_msgSend)(
        ((id(*)(id, SEL))objc_msgSend)((id)labelCls, allocSel),
        initFrameSel, infoFrame);
    ((void(*)(id, SEL, id))objc_msgSend)(infoLabel, sel_registerName("setText:"),
        @"UIKit: Loaded\n"
        "Foundation: Loaded\n"
        "CoreGraphics: Working\n"
        "CoreText: Working\n"
        "Obj-C Runtime: Working\n"
        "Rendering: Continuous\n"
        "Mode: Live Framebuffer");
    id green = ((id(*)(id, SEL, double, double, double, double))objc_msgSend)(
        (id)colorCls, sel_registerName("colorWithRed:green:blue:alpha:"),
        0.3, 1.0, 0.3, 1.0);
    ((void(*)(id, SEL, id))objc_msgSend)(infoLabel, sel_registerName("setTextColor:"), green);
    id monoFont = ((id(*)(id, SEL, double))objc_msgSend)(
        (id)fontCls, sel_registerName("systemFontOfSize:"), 13.0);
    ((void(*)(id, SEL, id))objc_msgSend)(infoLabel, sel_registerName("setFont:"), monoFont);
    ((void(*)(id, SEL, long))objc_msgSend)(infoLabel, sel_registerName("setNumberOfLines:"), 0);
    ((void(*)(id, SEL, id))objc_msgSend)(window, sel_registerName("addSubview:"), infoLabel);

    /* ---- Live counter label (updates every second) ---- */
    CGRect_t counterFrame = {20, 470, 335, 40};
    _counterLabel = ((initFrame_fn)objc_msgSend)(
        ((id(*)(id, SEL))objc_msgSend)((id)labelCls, allocSel),
        initFrameSel, counterFrame);
    ((void(*)(id, SEL, id))objc_msgSend)(_counterLabel, sel_registerName("setText:"),
        @"Uptime: 0s");
    id cyan = ((id(*)(id, SEL, double, double, double, double))objc_msgSend)(
        (id)colorCls, sel_registerName("colorWithRed:green:blue:alpha:"),
        0.3, 0.8, 1.0, 1.0);
    ((void(*)(id, SEL, id))objc_msgSend)(_counterLabel, sel_registerName("setTextColor:"), cyan);
    id counterFont = ((id(*)(id, SEL, double))objc_msgSend)(
        (id)fontCls, sel_registerName("boldSystemFontOfSize:"), 22.0);
    ((void(*)(id, SEL, id))objc_msgSend)(_counterLabel, sel_registerName("setFont:"), counterFont);
    ((void(*)(id, SEL, long))objc_msgSend)(_counterLabel, sel_registerName("setTextAlignment:"), 1);
    ((void(*)(id, SEL, id))objc_msgSend)(window, sel_registerName("addSubview:"), _counterLabel);

    /* ---- Time label (updates every second) ---- */
    CGRect_t timeFrame = {20, 515, 335, 30};
    _timeLabel = ((initFrame_fn)objc_msgSend)(
        ((id(*)(id, SEL))objc_msgSend)((id)labelCls, allocSel),
        initFrameSel, timeFrame);
    ((void(*)(id, SEL, id))objc_msgSend)(_timeLabel, sel_registerName("setTextColor:"), lightGray);
    id timeFont = ((id(*)(id, SEL, double))objc_msgSend)(
        (id)fontCls, sel_registerName("systemFontOfSize:"), 14.0);
    ((void(*)(id, SEL, id))objc_msgSend)(_timeLabel, sel_registerName("setFont:"), timeFont);
    ((void(*)(id, SEL, long))objc_msgSend)(_timeLabel, sel_registerName("setTextAlignment:"), 1);
    ((void(*)(id, SEL, id))objc_msgSend)(window, sel_registerName("addSubview:"), _timeLabel);

    /* ---- Bottom bar ---- */
    CGRect_t bottomFrame = {0, 617, 375, 50};
    id bottomBar = ((initFrame_fn)objc_msgSend)(
        ((id(*)(id, SEL))objc_msgSend)((id)viewCls, allocSel),
        initFrameSel, bottomFrame);
    ((void(*)(id, SEL, id))objc_msgSend)(bottomBar, sel_registerName("setBackgroundColor:"), darkColor);
    ((void(*)(id, SEL, id))objc_msgSend)(window, sel_registerName("addSubview:"), bottomBar);

    /* ---- Layout (skip makeKeyAndVisible - no UIApplication.sharedApplication) ---- */
    ((void(*)(id, SEL))objc_msgSend)(window, sel_registerName("layoutIfNeeded"));

    /* ---- Schedule a 1-second update timer ---- */
    _tickCount = 0;
    [self performSelector:@selector(updateTick) withObject:nil afterDelay:1.0];

    out("UI created. Returning YES — bridge will start frame capture.\n");
    out("The counter label updates every second to prove live rendering.\n\n");

    /* Do NOT call _exit(0) — let the bridge's run loop take over */
    return YES;
}

- (void)updateTick {
    _tickCount++;

    /* Update counter */
    NSString *counterText = [NSString stringWithFormat:@"Uptime: %ds", _tickCount];
    ((void(*)(id, SEL, id))objc_msgSend)(_counterLabel, sel_registerName("setText:"), counterText);

    /* Update time */
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    [fmt setDateFormat:@"HH:mm:ss"];
    NSString *timeText = [fmt stringFromDate:[NSDate date]];
    ((void(*)(id, SEL, id))objc_msgSend)(_timeLabel, sel_registerName("setText:"), timeText);

    /* Log every 10 seconds */
    if (_tickCount % 10 == 0) {
        outf("  [tick %d] Still running, labels updating\n", _tickCount);
    }

    /* Schedule next tick */
    [self performSelector:@selector(updateTick) withObject:nil afterDelay:1.0];
}

@end

/* ---- Main ---- */
int main(int argc, char *argv[]) {
    out("Phase 5: Continuous Rendering Test\n");
    out("==================================\n\n");

    setenv("SIMULATOR_DEVICE_NAME", "iPhone 6s", 1);
    setenv("SIMULATOR_MODEL_IDENTIFIER", "iPhone8,1", 1);
    setenv("SIMULATOR_RUNTIME_VERSION", "10.3", 1);
    setenv("SIMULATOR_MAINSCREEN_WIDTH", "750", 1);
    setenv("SIMULATOR_MAINSCREEN_HEIGHT", "1334", 1);
    setenv("SIMULATOR_MAINSCREEN_SCALE", "2.0", 1);

    @autoreleasepool {
        typedef int (*Fn)(int, char*[], id, id);
        Fn fn = (Fn)dlsym(RTLD_DEFAULT, "UIApplicationMain");
        return fn(argc, argv, nil, @"ContinuousDelegate");
    }
}
