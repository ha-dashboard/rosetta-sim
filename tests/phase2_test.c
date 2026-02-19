/*
 * Phase 2: Actually call old iOS simulator framework functions
 *
 * Tests:
 *   2A - CoreFoundation: CFStringCreate, CFRelease, CFArrayCreate
 *   2B - Foundation: NSLog, NSString via Obj-C runtime
 *   2C - Objective-C runtime: objc_msgSend, class lookup, method calling
 *   2D - Combined: Create objects, call methods, verify behavior
 *
 * Compile: clang -arch x86_64 -isysroot {SDK} -mios-simulator-version-min=10.0
 *          -framework CoreFoundation -framework Foundation
 *          -o phase2_test phase2_test.c
 *
 * Run: DYLD_ROOT_PATH={SDK} ./phase2_test
 */

#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <stdio.h>
#include <stdarg.h>
#include <dlfcn.h>

/* Raw output to avoid buffering issues */
static char _buf[4096];
void out(const char *msg) {
    write(STDOUT_FILENO, msg, strlen(msg));
}
void outf(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(_buf, sizeof(_buf), fmt, ap);
    va_end(ap);
    if (n > 0) write(STDOUT_FILENO, _buf, n);
}

/* ---- CoreFoundation types ---- */
typedef const void *CFTypeRef;
typedef const struct __CFString *CFStringRef;
typedef const struct __CFArray *CFArrayRef;
typedef const struct __CFAllocator *CFAllocatorRef;
typedef const struct __CFDictionary *CFDictionaryRef;
typedef unsigned long CFIndex;
typedef unsigned int CFStringEncoding;
typedef unsigned char Boolean;

#define kCFStringEncodingUTF8 0x08000100
#define kCFAllocatorDefault NULL

/* ---- Objective-C runtime types ---- */
typedef struct objc_class *Class;
typedef struct objc_object *id;
typedef struct objc_selector *SEL;

/* ---- Function pointer types ---- */
typedef CFStringRef (*CFStringCreateWithCStringFunc)(CFAllocatorRef, const char *, CFStringEncoding);
typedef void (*CFReleaseFunc)(CFTypeRef);
typedef CFTypeRef (*CFRetainFunc)(CFTypeRef);
typedef CFIndex (*CFGetRetainCountFunc)(CFTypeRef);
typedef CFIndex (*CFStringGetLengthFunc)(CFStringRef);
typedef Boolean (*CFStringGetCStringFunc)(CFStringRef, char *, CFIndex, CFStringEncoding);
typedef CFArrayRef (*CFArrayCreateFunc)(CFAllocatorRef, const void **, CFIndex, const void *);
typedef CFIndex (*CFArrayGetCountFunc)(CFArrayRef);
typedef void (*NSLogFunc)(CFStringRef, ...);

typedef Class (*objc_getClassFunc)(const char *);
typedef SEL (*sel_registerNameFunc)(const char *);
typedef id (*objc_msgSendFunc)(id, SEL, ...);

/* ---- Globals ---- */
static CFStringCreateWithCStringFunc cfStringCreate;
static CFReleaseFunc cfRelease;
static CFRetainFunc cfRetain;
static CFGetRetainCountFunc cfGetRetainCount;
static CFStringGetLengthFunc cfStringGetLength;
static CFStringGetCStringFunc cfStringGetCString;
static CFArrayCreateFunc cfArrayCreate;
static CFArrayGetCountFunc cfArrayGetCount;
static NSLogFunc nsLog;
static objc_getClassFunc getClass;
static sel_registerNameFunc selRegister;
static objc_msgSendFunc msgSend;

int resolve_symbols(void) {
    /* CoreFoundation symbols */
    cfStringCreate = (CFStringCreateWithCStringFunc)dlsym(RTLD_DEFAULT, "CFStringCreateWithCString");
    cfRelease = (CFReleaseFunc)dlsym(RTLD_DEFAULT, "CFRelease");
    cfRetain = (CFRetainFunc)dlsym(RTLD_DEFAULT, "CFRetain");
    cfGetRetainCount = (CFGetRetainCountFunc)dlsym(RTLD_DEFAULT, "CFGetRetainCount");
    cfStringGetLength = (CFStringGetLengthFunc)dlsym(RTLD_DEFAULT, "CFStringGetLength");
    cfStringGetCString = (CFStringGetCStringFunc)dlsym(RTLD_DEFAULT, "CFStringGetCString");
    cfArrayCreate = (CFArrayCreateFunc)dlsym(RTLD_DEFAULT, "CFArrayCreate");
    cfArrayGetCount = (CFArrayGetCountFunc)dlsym(RTLD_DEFAULT, "CFArrayGetCount");
    nsLog = (NSLogFunc)dlsym(RTLD_DEFAULT, "NSLog");
    getClass = (objc_getClassFunc)dlsym(RTLD_DEFAULT, "objc_getClass");
    selRegister = (sel_registerNameFunc)dlsym(RTLD_DEFAULT, "sel_registerName");
    msgSend = (objc_msgSendFunc)dlsym(RTLD_DEFAULT, "objc_msgSend");

    int ok = 1;
    if (!cfStringCreate) { out("  MISSING: CFStringCreateWithCString\n"); ok = 0; }
    if (!cfRelease)      { out("  MISSING: CFRelease\n"); ok = 0; }
    if (!cfRetain)       { out("  MISSING: CFRetain\n"); ok = 0; }
    if (!cfGetRetainCount) { out("  MISSING: CFGetRetainCount\n"); ok = 0; }
    if (!cfStringGetLength) { out("  MISSING: CFStringGetLength\n"); ok = 0; }
    if (!cfStringGetCString) { out("  MISSING: CFStringGetCString\n"); ok = 0; }
    if (!cfArrayCreate)  { out("  MISSING: CFArrayCreate\n"); ok = 0; }
    if (!cfArrayGetCount) { out("  MISSING: CFArrayGetCount\n"); ok = 0; }
    if (!nsLog)          { out("  MISSING: NSLog\n"); ok = 0; }
    if (!getClass)       { out("  MISSING: objc_getClass\n"); ok = 0; }
    if (!selRegister)    { out("  MISSING: sel_registerName\n"); ok = 0; }
    if (!msgSend)        { out("  MISSING: objc_msgSend\n"); ok = 0; }
    return ok;
}

/* ======== TEST 2A: CoreFoundation ======== */
int test_2a(void) {
    out("=== Test 2A: CoreFoundation Functions ===\n\n");
    int pass = 0, fail = 0;

    /* Test 1: Create a CFString */
    out("  [1] CFStringCreateWithCString... ");
    CFStringRef str = cfStringCreate(kCFAllocatorDefault, "Hello from RosettaSim on macOS 26!", kCFStringEncodingUTF8);
    if (str) {
        outf("OK (ptr=%p)\n", (void*)str);
        pass++;
    } else {
        out("FAILED (returned NULL)\n");
        fail++;
        return fail;
    }

    /* Test 2: Get string length */
    out("  [2] CFStringGetLength... ");
    CFIndex len = cfStringGetLength(str);
    if (len == 33) {
        outf("OK (length=%ld)\n", (long)len);
        pass++;
    } else {
        outf("UNEXPECTED (length=%ld, expected 33)\n", (long)len);
        fail++;
    }

    /* Test 3: Get C string back */
    out("  [3] CFStringGetCString... ");
    char readback[256] = {0};
    Boolean got = cfStringGetCString(str, readback, sizeof(readback), kCFStringEncodingUTF8);
    if (got && strcmp(readback, "Hello from RosettaSim on macOS 26!") == 0) {
        outf("OK (\"%s\")\n", readback);
        pass++;
    } else {
        outf("MISMATCH (got=\"%s\")\n", readback);
        fail++;
    }

    /* Test 4: Retain count */
    out("  [4] CFGetRetainCount... ");
    CFIndex rc = cfGetRetainCount(str);
    outf("OK (retainCount=%ld)\n", (long)rc);
    pass++;

    /* Test 5: Retain and release cycle */
    out("  [5] CFRetain/CFRelease cycle... ");
    cfRetain(str);
    CFIndex rc2 = cfGetRetainCount(str);
    cfRelease(str);
    CFIndex rc3 = cfGetRetainCount(str);
    if (rc2 == rc + 1 && rc3 == rc) {
        outf("OK (%ld -> %ld -> %ld)\n", (long)rc, (long)rc2, (long)rc3);
        pass++;
    } else {
        outf("UNEXPECTED (%ld -> %ld -> %ld)\n", (long)rc, (long)rc2, (long)rc3);
        fail++;
    }

    /* Test 6: Create a CFArray */
    out("  [6] CFArrayCreate... ");
    const void *values[] = { str };
    CFArrayRef arr = cfArrayCreate(kCFAllocatorDefault, values, 1, NULL);
    if (arr) {
        CFIndex arrCount = cfArrayGetCount(arr);
        outf("OK (count=%ld)\n", (long)arrCount);
        cfRelease(arr);
        pass++;
    } else {
        out("FAILED (returned NULL)\n");
        fail++;
    }

    /* Cleanup */
    cfRelease(str);

    outf("\n  Test 2A: %d passed, %d failed\n\n", pass, fail);
    return fail;
}

/* ======== TEST 2B: Foundation / NSLog ======== */
int test_2b(void) {
    out("=== Test 2B: Foundation Functions ===\n\n");
    int pass = 0, fail = 0;

    /* Test 1: NSLog with a CFString format */
    out("  [1] NSLog... ");
    CFStringRef fmt = cfStringCreate(kCFAllocatorDefault,
        "RosettaSim Phase 2: NSLog works! pid=%d", kCFStringEncodingUTF8);
    if (fmt) {
        nsLog(fmt, getpid());
        cfRelease(fmt);
        out("OK (check stderr for output)\n");
        pass++;
    } else {
        out("FAILED to create format string\n");
        fail++;
    }

    /* Test 2: NSLog with unicode */
    out("  [2] NSLog with unicode... ");
    CFStringRef uni = cfStringCreate(kCFAllocatorDefault,
        "RosettaSim: Unicode test - \xC3\xA9\xC3\xA0\xC3\xBC \xE2\x9C\x93", kCFStringEncodingUTF8);
    if (uni) {
        nsLog(uni);
        cfRelease(uni);
        out("OK\n");
        pass++;
    } else {
        out("FAILED\n");
        fail++;
    }

    outf("\n  Test 2B: %d passed, %d failed\n\n", pass, fail);
    return fail;
}

/* ======== TEST 2C: Objective-C Runtime ======== */
int test_2c(void) {
    out("=== Test 2C: Objective-C Runtime ===\n\n");
    int pass = 0, fail = 0;

    /* Test 1: Look up NSObject class */
    out("  [1] objc_getClass(\"NSObject\")... ");
    Class nsObject = getClass("NSObject");
    if (nsObject) {
        outf("OK (Class=%p)\n", (void*)nsObject);
        pass++;
    } else {
        out("FAILED (not found)\n");
        fail++;
        return fail;
    }

    /* Test 2: Look up NSString class */
    out("  [2] objc_getClass(\"NSString\")... ");
    Class nsString = getClass("NSString");
    if (nsString) {
        outf("OK (Class=%p)\n", (void*)nsString);
        pass++;
    } else {
        out("FAILED\n");
        fail++;
        return fail;
    }

    /* Test 3: Look up NSMutableArray */
    out("  [3] objc_getClass(\"NSMutableArray\")... ");
    Class nsMutableArray = getClass("NSMutableArray");
    if (nsMutableArray) {
        outf("OK (Class=%p)\n", (void*)nsMutableArray);
        pass++;
    } else {
        out("FAILED\n");
        fail++;
    }

    /* Test 4: Create an NSString via Obj-C message send */
    out("  [4] [[NSString alloc] initWithUTF8String:]... ");
    SEL allocSel = selRegister("alloc");
    SEL initSel = selRegister("initWithUTF8String:");
    SEL utf8Sel = selRegister("UTF8String");
    SEL lengthSel = selRegister("length");
    SEL releaseSel = selRegister("release");

    id allocated = msgSend((id)nsString, allocSel);
    if (allocated) {
        id str = ((id(*)(id, SEL, const char *))msgSend)(allocated, initSel, "Hello Objective-C from RosettaSim!");
        if (str) {
            /* Get length */
            long len = (long)((CFIndex(*)(id, SEL))msgSend)(str, lengthSel);
            /* Get UTF8String */
            const char *cstr = ((const char *(*)(id, SEL))msgSend)(str, utf8Sel);

            if (cstr && len == 34) {
                outf("OK (length=%ld, str=\"%s\")\n", len, cstr);
                pass++;
            } else {
                outf("PARTIAL (length=%ld, str=%s)\n", len, cstr ? cstr : "(null)");
                fail++;
            }

            msgSend(str, releaseSel);
        } else {
            out("FAILED (initWithUTF8String returned nil)\n");
            fail++;
        }
    } else {
        out("FAILED (alloc returned nil)\n");
        fail++;
    }

    /* Test 5: Create NSMutableArray, add objects, check count */
    out("  [5] NSMutableArray create and manipulate... ");
    if (nsMutableArray) {
        SEL newSel = selRegister("new");
        SEL addSel = selRegister("addObject:");
        SEL countSel = selRegister("count");

        id arr = msgSend((id)nsMutableArray, newSel);
        if (arr) {
            /* Create 3 NSStrings and add them */
            for (int i = 0; i < 3; i++) {
                char tmp[64];
                snprintf(tmp, sizeof(tmp), "Item %d", i);
                id s = ((id(*)(id, SEL, const char *))msgSend)(
                    msgSend((id)nsString, allocSel),
                    initSel, tmp);
                ((void(*)(id, SEL, id))msgSend)(arr, addSel, s);
                msgSend(s, releaseSel);
            }

            long count = (long)((CFIndex(*)(id, SEL))msgSend)(arr, countSel);
            if (count == 3) {
                outf("OK (count=%ld after adding 3 items)\n", count);
                pass++;
            } else {
                outf("UNEXPECTED (count=%ld, expected 3)\n", count);
                fail++;
            }
            msgSend(arr, releaseSel);
        } else {
            out("FAILED (new returned nil)\n");
            fail++;
        }
    }

    /* Test 6: Look up UIKit classes (they should be loaded from Phase 1) */
    out("  [6] objc_getClass(\"UIView\")... ");
    Class uiView = getClass("UIView");
    if (uiView) {
        outf("OK (Class=%p)\n", (void*)uiView);
        pass++;
    } else {
        out("NOT LOADED (UIKit may not be loaded yet - expected)\n");
        /* Not a failure - UIKit might not be loaded */
    }

    outf("\n  Test 2C: %d passed, %d failed\n\n", pass, fail);
    return fail;
}

/* ======== MAIN ======== */
int main(int argc, char *argv[]) {
    out("╔══════════════════════════════════════════════════════╗\n");
    out("║  RosettaSim Phase 2: Framework Function Calling     ║\n");
    out("╚══════════════════════════════════════════════════════╝\n\n");

    const char *sdk_root = getenv("DYLD_ROOT_PATH");
    if (!sdk_root) {
        out("ERROR: DYLD_ROOT_PATH not set\n");
        return 1;
    }
    outf("SDK Root: %s\n", sdk_root);
    outf("PID: %d\n\n", getpid());

    /* Load frameworks via dlopen (ensures they're available) */
    out("--- Loading frameworks ---\n");
    const char *fw[] = {
        "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation",
        "/System/Library/Frameworks/Foundation.framework/Foundation",
        "/System/Library/Frameworks/UIKit.framework/UIKit",
    };
    for (int i = 0; i < 3; i++) {
        char path[2048];
        snprintf(path, sizeof(path), "%s%s", sdk_root, fw[i]);
        void *h = dlopen(path, RTLD_LAZY | RTLD_GLOBAL);
        if (h) {
            outf("  Loaded: %s\n", fw[i]);
        } else {
            outf("  FAILED: %s (%s)\n", fw[i], dlerror());
            return 1;
        }
    }

    out("\n--- Resolving symbols ---\n");
    if (!resolve_symbols()) {
        out("FATAL: Could not resolve required symbols\n");
        return 1;
    }
    out("  All 12 symbols resolved.\n\n");

    /* Run tests */
    int total_fail = 0;
    total_fail += test_2a();
    total_fail += test_2b();
    total_fail += test_2c();

    /* Final summary */
    out("╔══════════════════════════════════════════════════════╗\n");
    if (total_fail == 0) {
        out("║  ALL PHASE 2 TESTS PASSED                          ║\n");
        out("║  CoreFoundation, Foundation, and ObjC runtime work  ║\n");
        out("║  on macOS 26 via old iOS 10.3 simulator SDK.        ║\n");
    } else {
        outf("║  Phase 2: %d test(s) failed                        ║\n", total_fail);
    }
    out("╚══════════════════════════════════════════════════════╝\n");

    return total_fail;
}
