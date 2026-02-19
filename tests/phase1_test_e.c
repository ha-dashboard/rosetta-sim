/*
 * Phase 1 Test E: Framework loading with raw I/O
 *
 * Same as Test B but uses write() syscall for output
 * to avoid any stdio buffering issues with the old SDK.
 */

#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <dlfcn.h>
#include <stdio.h>

void out(const char *msg) {
    write(STDOUT_FILENO, msg, strlen(msg));
}

int main(int argc, char *argv[]) {
    out("=== Phase 1 Test E: Framework Loading (raw I/O) ===\n\n");

    const char *sdk_root = getenv("DYLD_ROOT_PATH");
    if (!sdk_root) sdk_root = getenv("IPHONE_SIMULATOR_ROOT");
    if (!sdk_root) {
        out("ERROR: No SDK root set\n");
        return 1;
    }

    out("SDK Root: ");
    out(sdk_root);
    out("\n\n");

    /* Frameworks to test */
    const char *names[] = {
        "CoreFoundation",
        "Foundation",
        "CoreGraphics",
        "QuartzCore",
        "UIKit"
    };
    const char *paths[] = {
        "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation",
        "/System/Library/Frameworks/Foundation.framework/Foundation",
        "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics",
        "/System/Library/Frameworks/QuartzCore.framework/QuartzCore",
        "/System/Library/Frameworks/UIKit.framework/UIKit"
    };
    int count = 5;
    int passed = 0;

    for (int i = 0; i < count; i++) {
        char full_path[2048];
        snprintf(full_path, sizeof(full_path), "%s%s", sdk_root, paths[i]);

        out("Loading ");
        out(names[i]);
        out("...\n");
        out("  Path: ");
        out(full_path);
        out("\n");

        void *handle = dlopen(full_path, RTLD_LAZY | RTLD_GLOBAL);
        if (handle) {
            out("  Result: LOADED ✓\n\n");
            passed++;
        } else {
            const char *err = dlerror();
            out("  Result: FAILED ✗\n");
            out("  Error: ");
            out(err ? err : "(unknown)");
            out("\n\n");
        }
    }

    out("=== Summary ===\n");
    char buf[64];
    snprintf(buf, sizeof(buf), "Loaded: %d/%d\n", passed, count);
    out(buf);

    if (passed == count) {
        out("\n*** ALL FRAMEWORKS LOADED SUCCESSFULLY ***\n");
        out("*** The old iOS simulator stack is viable on macOS 26! ***\n");
    } else if (passed > 0) {
        out("\nPartial success - some frameworks loaded.\n");
    } else {
        out("\nNo frameworks loaded.\n");
    }

    /* Bonus: if UIKit loaded, try resolving UIApplicationMain */
    if (passed == count) {
        out("\n=== Bonus: Symbol Resolution ===\n");

        void *sym = dlsym(RTLD_DEFAULT, "UIApplicationMain");
        if (sym) {
            snprintf(buf, sizeof(buf), "UIApplicationMain: %p ✓\n", sym);
            out(buf);
        } else {
            out("UIApplicationMain: not found\n");
        }

        sym = dlsym(RTLD_DEFAULT, "NSLog");
        if (sym) {
            snprintf(buf, sizeof(buf), "NSLog: %p ✓\n", sym);
            out(buf);
        } else {
            out("NSLog: not found\n");
        }

        sym = dlsym(RTLD_DEFAULT, "objc_msgSend");
        if (sym) {
            snprintf(buf, sizeof(buf), "objc_msgSend: %p ✓\n", sym);
            out(buf);
        } else {
            out("objc_msgSend: not found\n");
        }

        sym = dlsym(RTLD_DEFAULT, "CFRunLoopRun");
        if (sym) {
            snprintf(buf, sizeof(buf), "CFRunLoopRun: %p ✓\n", sym);
            out(buf);
        } else {
            out("CFRunLoopRun: not found\n");
        }
    }

    return (passed == count) ? 0 : 1;
}
