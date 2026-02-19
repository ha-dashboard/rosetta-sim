/*
 * Phase 1 Test C: Resolve and call symbols from old frameworks
 *
 * Goes beyond loading - attempts to resolve key symbols from
 * the old iOS simulator UIKit and call basic functions.
 *
 * Tests:
 * 1. Can we resolve NSStringFromClass (Foundation)?
 * 2. Can we resolve UIApplicationMain (UIKit)?
 * 3. Can we call CFStringCreateWithCString (CoreFoundation)?
 * 4. Can we call NSLog (Foundation)?
 */

#include <stdio.h>
#include <stdlib.h>
#include <dlfcn.h>
#include <string.h>

/* CoreFoundation types we need */
typedef const void *CFTypeRef;
typedef const struct __CFString *CFStringRef;
typedef const struct __CFAllocator *CFAllocatorRef;
typedef unsigned int CFStringEncoding;
#define kCFStringEncodingUTF8 0x08000100
#define kCFAllocatorDefault NULL

/* Function pointer types */
typedef CFStringRef (*CFStringCreateWithCStringFunc)(CFAllocatorRef, const char *, CFStringEncoding);
typedef void (*CFReleaseFunc)(CFTypeRef);
typedef const char *(*CFStringGetCStringPtrFunc)(CFStringRef, CFStringEncoding);
typedef void (*NSLogFunc)(CFStringRef, ...);

int main(int argc, char *argv[]) {
    printf("=== Phase 1 Test C: Symbol Resolution & Calling ===\n\n");

    const char *sdk_root = getenv("DYLD_ROOT_PATH");
    if (!sdk_root) {
        sdk_root = getenv("IPHONE_SIMULATOR_ROOT");
    }
    if (!sdk_root) {
        fprintf(stderr, "ERROR: Set DYLD_ROOT_PATH or IPHONE_SIMULATOR_ROOT\n");
        return 1;
    }

    printf("SDK Root: %s\n\n", sdk_root);

    /* Load CoreFoundation */
    char cf_path[1024];
    snprintf(cf_path, sizeof(cf_path), "%s/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation", sdk_root);
    void *cf = dlopen(cf_path, RTLD_LAZY | RTLD_GLOBAL);
    if (!cf) {
        printf("FAILED to load CoreFoundation: %s\n", dlerror());
        return 1;
    }
    printf("CoreFoundation loaded.\n");

    /* Load Foundation */
    char fn_path[1024];
    snprintf(fn_path, sizeof(fn_path), "%s/System/Library/Frameworks/Foundation.framework/Foundation", sdk_root);
    void *fn = dlopen(fn_path, RTLD_LAZY | RTLD_GLOBAL);
    if (!fn) {
        printf("FAILED to load Foundation: %s\n", dlerror());
        return 1;
    }
    printf("Foundation loaded.\n");

    /* Test 1: Resolve CFStringCreateWithCString */
    printf("\n--- Test 1: CFStringCreateWithCString ---\n");
    CFStringCreateWithCStringFunc createStr = (CFStringCreateWithCStringFunc)dlsym(cf, "CFStringCreateWithCString");
    CFReleaseFunc release = (CFReleaseFunc)dlsym(cf, "CFRelease");

    if (createStr && release) {
        printf("  Resolved CFStringCreateWithCString: %p\n", (void *)createStr);
        printf("  Resolved CFRelease: %p\n", (void *)release);

        /* Actually call it */
        CFStringRef str = createStr(kCFAllocatorDefault, "Hello from RosettaSim!", kCFStringEncodingUTF8);
        if (str) {
            printf("  Created CFString: %p\n", (void *)str);

            /* Try to read it back */
            CFStringGetCStringPtrFunc getCStr = (CFStringGetCStringPtrFunc)dlsym(cf, "CFStringGetCStringPtr");
            if (getCStr) {
                const char *cstr = getCStr(str, kCFStringEncodingUTF8);
                if (cstr) {
                    printf("  String value: \"%s\"\n", cstr);
                } else {
                    printf("  (CFStringGetCStringPtr returned NULL - string exists but uses internal storage)\n");
                }
            }

            release(str);
            printf("  Released CFString successfully.\n");
            printf("  Test 1: PASSED\n");
        } else {
            printf("  CFStringCreateWithCString returned NULL!\n");
            printf("  Test 1: FAILED\n");
        }
    } else {
        printf("  Failed to resolve symbols.\n");
        printf("  Test 1: FAILED\n");
    }

    /* Test 2: Resolve NSLog */
    printf("\n--- Test 2: NSLog ---\n");
    NSLogFunc nslog = (NSLogFunc)dlsym(fn, "NSLog");
    if (nslog) {
        printf("  Resolved NSLog: %p\n", (void *)nslog);
        CFStringRef fmt = createStr(kCFAllocatorDefault, "RosettaSim: NSLog works! Calling from x86_64 on ARM64 macOS.", kCFStringEncodingUTF8);
        if (fmt) {
            nslog(fmt);
            release(fmt);
            printf("  NSLog called successfully (check stderr for output).\n");
            printf("  Test 2: PASSED\n");
        }
    } else {
        printf("  Failed to resolve NSLog: %s\n", dlerror());
        printf("  Test 2: FAILED\n");
    }

    /* Test 3: Resolve UIApplicationMain (just resolve, don't call it) */
    printf("\n--- Test 3: UIApplicationMain symbol resolution ---\n");
    char uikit_path[1024];
    snprintf(uikit_path, sizeof(uikit_path), "%s/System/Library/Frameworks/UIKit.framework/UIKit", sdk_root);
    void *uikit = dlopen(uikit_path, RTLD_LAZY | RTLD_GLOBAL);
    if (uikit) {
        printf("  UIKit loaded.\n");
        void *uiAppMain = dlsym(uikit, "UIApplicationMain");
        if (uiAppMain) {
            printf("  Resolved UIApplicationMain: %p\n", uiAppMain);
            printf("  Test 3: PASSED\n");
        } else {
            printf("  Failed to resolve UIApplicationMain: %s\n", dlerror());
            printf("  Test 3: FAILED\n");
        }
    } else {
        printf("  Failed to load UIKit: %s\n", dlerror());
        printf("  Test 3: FAILED\n");
    }

    printf("\n=== Phase 1 Test C Complete ===\n");

    /* Cleanup */
    if (uikit) dlclose(uikit);
    dlclose(fn);
    dlclose(cf);

    return 0;
}
