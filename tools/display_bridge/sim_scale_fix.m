/*
 * sim_scale_fix.m — Constructor + interpose to fix display scale in legacy iOS simulators
 *
 * Problem: backboardd calls BSMainScreenScale() which returns ≤0 on Apple Silicon,
 * causing it to fall back to scale=1.0. Display::set_scale() is never called with 2.0,
 * so native_scale stays at 0, update_geometry produces empty clip bounds, and the
 * renderer only fills a fraction of the pixel buffer.
 *
 * Fix: Two-pronged approach:
 *   1. Constructor with dispatch_after calls [CAWindowServerDisplay setScale:2.0]
 *      directly after CAWindowServer initializes. This works via LC_LOAD_DYLIB.
 *   2. DYLD interpose of BSMainScreenScale (belt-and-suspenders, only fires if
 *      loaded via DYLD_INSERT_LIBRARIES).
 *
 * Injected into backboardd via insert_dylib (adds LC_LOAD_DYLIB to Mach-O header).
 *
 * Build (x86_64 iOS simulator target):
 *   /usr/bin/cc -arch x86_64 -target x86_64-apple-ios9.0-simulator \
 *     -isysroot .../iPhoneSimulator.sdk -shared -flat_namespace \
 *     -undefined suppress -framework Foundation -framework QuartzCore \
 *     -o sim_scale_fix.dylib sim_scale_fix.m
 */

#import <Foundation/Foundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <dispatch/dispatch.h>
#include <objc/runtime.h>
#include <objc/message.h>

#pragma mark - Constructor: Direct setScale call

static void attempt_set_scale(void) {
    const char *s = getenv("ROSETTA_SCREEN_SCALE");
    double scale = s ? atof(s) : 2.0;
    if (scale <= 0.0) scale = 2.0;

    @autoreleasepool {
        Class cls = objc_getClass("CAWindowServerDisplay");
        if (!cls) {
            fprintf(stderr, "[scale_fix] CAWindowServerDisplay class not found\n");
            return;
        }

        /* [CAWindowServerDisplay mainDisplay] */
        SEL mainDisplaySel = sel_registerName("mainDisplay");
        id display = ((id(*)(Class, SEL))objc_msgSend)(cls, mainDisplaySel);
        if (!display) {
            fprintf(stderr, "[scale_fix] mainDisplay returned nil\n");
            return;
        }

        /* [display setScale:scale] */
        SEL setScaleSel = sel_registerName("setScale:");
        ((void(*)(id, SEL, double))objc_msgSend)(display, setScaleSel, scale);

        fprintf(stderr, "[scale_fix] Called [CAWindowServerDisplay setScale:%.1f] on %p\n",
                scale, (void *)display);
    }
}

__attribute__((constructor))
static void scale_fix_init(void) {
    /* Only act in backboardd */
    const char *prog = getprogname();
    if (!prog || strstr(prog, "backboardd") == NULL) {
        return;
    }

    fprintf(stderr, "[scale_fix] Constructor fired in %s (pid=%d)\n", prog, getpid());

    /* Schedule setScale call after CAWindowServer has initialized.
     * backboardd's BKDisplayStartWindowServer runs early in main().
     * A 3-second delay should be sufficient. We also retry at 5s and 8s
     * in case the first attempt is too early. */
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        fprintf(stderr, "[scale_fix] Attempting setScale (3s)...\n");
        attempt_set_scale();
    });

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        fprintf(stderr, "[scale_fix] Attempting setScale (5s)...\n");
        attempt_set_scale();
    });

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        fprintf(stderr, "[scale_fix] Attempting setScale (8s)...\n");
        attempt_set_scale();
    });
}

#pragma mark - BSMainScreenScale interpose (belt-and-suspenders)

/* Only effective when loaded via DYLD_INSERT_LIBRARIES.
 * When loaded via LC_LOAD_DYLIB (insert_dylib), the interpose doesn't fire
 * on old dyld_sim, but the constructor above handles it. */

double replacement_BSMainScreenScale(void) {
    const char *s = getenv("ROSETTA_SCREEN_SCALE");
    double scale = s ? atof(s) : 2.0;
    static int logged = 0;
    if (!logged) {
        fprintf(stderr, "[scale_fix] BSMainScreenScale interpose -> %.1f\n", scale);
        logged = 1;
    }
    return scale;
}

/* Weak reference to avoid link failure on runtimes that don't have BSMainScreenScale */
extern double BSMainScreenScale(void) __attribute__((weak_import));

__attribute__((used, section("__DATA,__interpose")))
static struct { void *replacement; void *original; } interpose[] = {
    { (void *)replacement_BSMainScreenScale, (void *)BSMainScreenScale },
};
