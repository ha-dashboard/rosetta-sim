/*
 * platform_launch_helper — Native arm64 replacement for the sim runtime's
 * platform_launch_helper. Runs on the host side to avoid ecosystemd sandbox
 * denials on sim-rooted paths.
 *
 * Usage: platform_launch_helper <binary_path_in_sim_root>
 *
 * Resolves the binary path using SIMULATOR_PLATFORM_RUNTIME_OVERLAY_ROOT
 * or DYLD_ROOT_PATH, sets x86_64 arch preference, then execs.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <spawn.h>
#include <errno.h>
#include <sys/stat.h>
#include <mach-o/arch.h>

extern char **environ;

int main(int argc, char *argv[]) {
    if (argc < 2) {
        fprintf(stderr, "Usage: platform_launch_helper <binary>\n");
        return 1;
    }

    const char *target = argv[1];
    const char *overlay = getenv("SIMULATOR_PLATFORM_RUNTIME_OVERLAY_ROOT");
    const char *dyld_root = getenv("DYLD_ROOT_PATH");
    char resolved[4096];
    int found = 0;

    /* Try overlay root first */
    if (overlay && overlay[0]) {
        snprintf(resolved, sizeof(resolved), "%s%s", overlay, target);
        struct stat st;
        if (stat(resolved, &st) == 0) found = 1;
    }

    /* Try DYLD_ROOT_PATH */
    if (!found && dyld_root && dyld_root[0]) {
        snprintf(resolved, sizeof(resolved), "%s%s", dyld_root, target);
        struct stat st;
        if (stat(resolved, &st) == 0) found = 1;
    }

    /* Try as absolute path */
    if (!found) {
        struct stat st;
        if (stat(target, &st) == 0) {
            snprintf(resolved, sizeof(resolved), "%s", target);
            found = 1;
        }
    }

    if (!found) {
        fprintf(stderr, "platform_launch_helper: cannot find %s\n", target);
        fprintf(stderr, "  overlay=%s\n  dyld_root=%s\n", overlay ?: "(null)", dyld_root ?: "(null)");
        return 1;
    }

    /* Set up posix_spawn with x86_64 arch preference and SETEXEC */
    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);

    /* POSIX_SPAWN_SETEXEC makes posix_spawn behave like execv */
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETEXEC);

    /* Prefer x86_64 architecture */
    cpu_type_t pref[] = { CPU_TYPE_X86_64, CPU_TYPE_I386 };
    posix_spawnattr_setbinpref_np(&attr, 2, pref, NULL);

    /* Build argv for the target: shift argv[0] to be the target path */
    argv[1] = (char *)resolved;
    char **new_argv = &argv[1];

    /* Exec via posix_spawn (SETEXEC replaces current process) */
    int rc = posix_spawn(NULL, resolved, NULL, &attr, new_argv, environ);

    /* If we get here, posix_spawn failed */
    fprintf(stderr, "platform_launch_helper: posix_spawn(%s) failed: %s\n",
            resolved, strerror(rc));
    posix_spawnattr_destroy(&attr);
    return 1;
}
