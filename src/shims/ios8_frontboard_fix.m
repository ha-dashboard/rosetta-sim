/*
 * ios8_frontboard_fix.m — Fix crashes in iOS 8.2 simulator on macOS 26
 *
 * Includes:
 * 1. Nil-safe CFDictionaryCreate (interpose — fixes BKSHIDEventCreateClientAttributes crash)
 * 2. Nil-safe NSMutableArray (swizzle — catches nil addObject:/insertObject:atIndex:)
 * 3. Crash signal handler that prints backtrace to file for diagnosis
 *
 * Build (x86_64 — runs inside Rosetta sim):
 *   clang -arch x86_64 -dynamiclib -framework Foundation -framework CoreFoundation \
 *     -mios-simulator-version-min=8.0 \
 *     -isysroot $(xcrun --show-sdk-path --sdk iphonesimulator) \
 *     -install_name /usr/lib/ios8_frontboard_fix.dylib \
 *     -o ios8_frontboard_fix.dylib ios8_frontboard_fix.m
 *
 * Injection: via insert_dylib on SpringBoard binary + codesign
 */

#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/runtime.h>
#include <stdio.h>
#include <execinfo.h>
#include <signal.h>
#include <unistd.h>
#include <dlfcn.h>
#include <fcntl.h>

/* ================================================================
 * Nil-safe CFDictionaryCreate interpose
 * ================================================================ */

CFDictionaryRef my_CFDictionaryCreate(CFAllocatorRef allocator,
                                       const void **keys,
                                       const void **values,
                                       CFIndex numValues,
                                       const CFDictionaryKeyCallBacks *keyCallBacks,
                                       const CFDictionaryValueCallBacks *valueCallBacks) {
    typedef CFDictionaryRef (*orig_fn)(CFAllocatorRef, const void **, const void **,
                                      CFIndex, const CFDictionaryKeyCallBacks *,
                                      const CFDictionaryValueCallBacks *);
    static orig_fn orig = NULL;
    if (!orig) orig = (orig_fn)dlsym(RTLD_NEXT, "CFDictionaryCreate");

    if (numValues > 0 && keys && values) {
        /* Filter out nil keys/values */
        const void *safeKeys[numValues];
        const void *safeValues[numValues];
        CFIndex safeCount = 0;
        for (CFIndex i = 0; i < numValues; i++) {
            if (keys[i] != NULL && values[i] != NULL) {
                safeKeys[safeCount] = keys[i];
                safeValues[safeCount] = values[i];
                safeCount++;
            }
        }
        return orig(allocator, safeKeys, safeValues, safeCount, keyCallBacks, valueCallBacks);
    }
    return orig(allocator, keys, values, numValues, keyCallBacks, valueCallBacks);
}

__attribute__((used, section("__DATA,__interpose")))
static struct { void *replacement; void *original; } interpose_dict[] = {
    { (void *)my_CFDictionaryCreate, (void *)CFDictionaryCreate },
};

/* ================================================================
 * Crash signal handler — writes backtrace to file
 * ================================================================ */

static void crash_handler(int sig) {
    void *bt[64];
    int count = backtrace(bt, 64);

    int fd = open("/tmp/rosettasim_crash_backtrace.txt",
                  O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd >= 0) {
        char buf[128];
        int len = snprintf(buf, sizeof(buf),
            "[RosettaSim] CRASH signal=%d pid=%d\n", sig, getpid());
        write(fd, buf, len);
        backtrace_symbols_fd(bt, count, fd);
        close(fd);
    }
    fprintf(stderr, "\n[RosettaSim] CRASH signal=%d pid=%d\n", sig, getpid());
    backtrace_symbols_fd(bt, count, STDERR_FILENO);
    _exit(128 + sig);
}

/* ================================================================
 * Nil-safe NSMutableArray swizzle
 * ================================================================ */

static void (*orig_insertObject)(id, SEL, id, NSUInteger);
static void (*orig_addObject)(id, SEL, id);

static void safe_insertObject(id self, SEL _cmd, id obj, NSUInteger idx) {
    if (obj == nil) return;
    orig_insertObject(self, _cmd, obj, idx);
}

static void safe_addObject(id self, SEL _cmd, id obj) {
    if (obj == nil) return;
    orig_addObject(self, _cmd, obj);
}

/* ================================================================
 * Constructor
 * ================================================================ */

__attribute__((constructor))
static void fix_frontboard(void) {
    /* Install crash signal handlers FIRST */
    signal(SIGABRT, crash_handler);
    signal(SIGSEGV, crash_handler);
    signal(SIGBUS, crash_handler);
    signal(SIGTRAP, crash_handler);
    signal(SIGILL, crash_handler);

    /* Write marker file */
    FILE *f = fopen("/tmp/rosettasim_frontboard_fix_loaded", "w");
    if (f) { fprintf(f, "loaded pid=%d\n", getpid()); fclose(f); }

    /* Swizzle __NSArrayM */
    Class cls = objc_getClass("__NSArrayM");
    if (!cls) return;

    Method m1 = class_getInstanceMethod(cls, sel_registerName("insertObject:atIndex:"));
    if (m1) {
        orig_insertObject = (void *)method_getImplementation(m1);
        method_setImplementation(m1, (IMP)safe_insertObject);
    }

    Method m2 = class_getInstanceMethod(cls, sel_registerName("addObject:"));
    if (m2) {
        orig_addObject = (void *)method_getImplementation(m2);
        method_setImplementation(m2, (IMP)safe_addObject);
    }
}
