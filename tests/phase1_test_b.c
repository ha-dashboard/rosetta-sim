/*
 * Phase 1 Test B: dlopen() old simulator frameworks
 *
 * Attempts to dynamically load UIKit, Foundation, and CoreFoundation
 * from the old iOS simulator SDK via dlopen().
 *
 * This tests whether the old x86_64 frameworks can be loaded into
 * a process on macOS 26 with Rosetta 2 translation.
 */

#include <stdio.h>
#include <stdlib.h>
#include <dlfcn.h>
#include <string.h>

typedef struct {
    const char *name;
    const char *path;
    void *handle;
    int loaded;
} framework_t;

int main(int argc, char *argv[]) {
    printf("=== Phase 1 Test B: Framework Loading ===\n\n");

    const char *sdk_root = getenv("DYLD_ROOT_PATH");
    if (!sdk_root) {
        sdk_root = getenv("IPHONE_SIMULATOR_ROOT");
    }

    if (!sdk_root) {
        fprintf(stderr, "ERROR: Set DYLD_ROOT_PATH or IPHONE_SIMULATOR_ROOT to SDK root\n");
        return 1;
    }

    printf("SDK Root: %s\n\n", sdk_root);

    /* Frameworks to test, in dependency order */
    framework_t frameworks[] = {
        {"CoreFoundation", "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation", NULL, 0},
        {"Foundation",     "/System/Library/Frameworks/Foundation.framework/Foundation", NULL, 0},
        {"CoreGraphics",   "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", NULL, 0},
        {"QuartzCore",     "/System/Library/Frameworks/QuartzCore.framework/QuartzCore", NULL, 0},
        {"UIKit",          "/System/Library/Frameworks/UIKit.framework/UIKit", NULL, 0},
    };
    int num_frameworks = sizeof(frameworks) / sizeof(frameworks[0]);

    int passed = 0;
    int failed = 0;

    for (int i = 0; i < num_frameworks; i++) {
        char full_path[1024];
        snprintf(full_path, sizeof(full_path), "%s%s", sdk_root, frameworks[i].path);

        printf("Loading %s...\n", frameworks[i].name);
        printf("  Path: %s\n", full_path);

        frameworks[i].handle = dlopen(full_path, RTLD_LAZY | RTLD_LOCAL);
        if (frameworks[i].handle) {
            frameworks[i].loaded = 1;
            passed++;
            printf("  Result: LOADED\n\n");
        } else {
            failed++;
            printf("  Result: FAILED\n");
            printf("  Error:  %s\n\n", dlerror());
        }
    }

    printf("=== Summary ===\n");
    printf("Loaded: %d/%d\n", passed, num_frameworks);
    printf("Failed: %d/%d\n", failed, num_frameworks);

    /* Clean up */
    for (int i = 0; i < num_frameworks; i++) {
        if (frameworks[i].handle) {
            dlclose(frameworks[i].handle);
        }
    }

    if (failed == 0) {
        printf("\nTest B: PASSED - all frameworks loaded successfully\n");
    } else {
        printf("\nTest B: PARTIAL - %d/%d frameworks loaded\n", passed, num_frameworks);
    }

    return failed > 0 ? 1 : 0;
}
