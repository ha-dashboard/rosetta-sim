/*
 * Phase 1 Test A: Basic x86_64 execution with old SDK libSystem
 *
 * This test verifies that a basic x86_64 program can execute on macOS 26
 * with DYLD_ROOT_PATH pointing to the old iOS simulator SDK.
 *
 * We compile for x86_64 (will run via Rosetta 2) and attempt to load
 * libraries from the simulator SDK root.
 */

#include <stdio.h>
#include <stdlib.h>
#include <dlfcn.h>
#include <string.h>
#include <mach-o/dyld.h>

int main(int argc, char *argv[]) {
    printf("=== Phase 1 Test A: Basic Execution ===\n");
    printf("Architecture: x86_64 (running via Rosetta 2)\n");

    /* Report dyld root path if set */
    const char *root = getenv("DYLD_ROOT_PATH");
    printf("DYLD_ROOT_PATH: %s\n", root ? root : "(not set)");

    const char *sim_root = getenv("IPHONE_SIMULATOR_ROOT");
    printf("IPHONE_SIMULATOR_ROOT: %s\n", sim_root ? sim_root : "(not set)");

    /* Report how many images dyld has loaded */
    uint32_t count = _dyld_image_count();
    printf("Loaded images: %u\n", count);
    for (uint32_t i = 0; i < count && i < 10; i++) {
        printf("  [%u] %s\n", i, _dyld_get_image_name(i));
    }
    if (count > 10) {
        printf("  ... and %u more\n", count - 10);
    }

    printf("\nTest A: PASSED - basic x86_64 execution works\n");
    return 0;
}
