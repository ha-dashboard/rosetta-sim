/*
 * Phase 1 Test D: Minimal simulator binary diagnostic
 *
 * The simplest possible test to see if a simulator-targeted binary
 * can even start executing with DYLD_ROOT_PATH set.
 * Uses raw write() syscall to avoid any library dependencies for output.
 */

#include <unistd.h>
#include <string.h>
#include <stdlib.h>

/* Use raw write syscall for output to avoid libc issues */
void raw_print(const char *msg) {
    write(STDOUT_FILENO, msg, strlen(msg));
}

int main(int argc, char *argv[]) {
    raw_print("=== Test D: Simulator binary started ===\n");

    /* Check key env vars */
    const char *root = getenv("DYLD_ROOT_PATH");
    raw_print("DYLD_ROOT_PATH: ");
    raw_print(root ? root : "(not set)");
    raw_print("\n");

    const char *sim_root = getenv("IPHONE_SIMULATOR_ROOT");
    raw_print("IPHONE_SIMULATOR_ROOT: ");
    raw_print(sim_root ? sim_root : "(not set)");
    raw_print("\n");

    raw_print("Test D: binary executed successfully\n");
    return 0;
}
