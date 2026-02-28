#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <time.h>

int main(int argc, char *argv[]) {
    /* Write debug to multiple locations */
    const char *debug_paths[] = {
        "/tmp/rosettasim_bridge_debug.txt",
        "/var/tmp/rosettasim_bridge_debug.txt",
        NULL
    };
    
    for (int i = 0; debug_paths[i]; i++) {
        int fd = open(debug_paths[i], O_WRONLY|O_CREAT|O_APPEND, 0666);
        if (fd >= 0) {
            dprintf(fd, "=== bridge_wrapper pid=%d time=%ld ===\n", getpid(), time(NULL));
            
            const char *runtime_ver = getenv("SIMULATOR_RUNTIME_VERSION");
            const char *sim_root = getenv("IPHONE_SIMULATOR_ROOT");
            dprintf(fd, "SIMULATOR_RUNTIME_VERSION=%s\n", runtime_ver ?: "(null)");
            dprintf(fd, "IPHONE_SIMULATOR_ROOT=%s\n", sim_root ?: "(null)");
            
            int is_legacy = 0;
            if (runtime_ver) {
                is_legacy = (strncmp(runtime_ver, "7.", 2) == 0 ||
                             strncmp(runtime_ver, "8.", 2) == 0 ||
                             strncmp(runtime_ver, "9.", 2) == 0 ||
                             strncmp(runtime_ver, "10.", 3) == 0);
            }
            if (!is_legacy && sim_root) {
                if (strstr(sim_root, "iOS_7.") || strstr(sim_root, "iOS_8.") ||
                    strstr(sim_root, "iOS_9.") || strstr(sim_root, "iOS_10."))
                    is_legacy = 1;
            }
            
            const char *legacy_path = "/usr/local/lib/rosettasim/CoreSimulatorBridge.legacy";
            const char *modern_path = "/usr/local/lib/rosettasim/CoreSimulatorBridge.modern";
            
            if (is_legacy) {
                dprintf(fd, "LEGACY detected, execv(%s)\n", legacy_path);
                close(fd);
                execv(legacy_path, argv);
                /* If we're still here, execv failed */
                fd = open(debug_paths[i], O_WRONLY|O_APPEND, 0666);
                if (fd >= 0) {
                    dprintf(fd, "execv FAILED: %s\n", strerror(errno));
                    close(fd);
                }
            } else {
                dprintf(fd, "MODERN detected, execv(%s)\n", modern_path);
                close(fd);
                execv(modern_path, argv);
                fd = open(debug_paths[i], O_WRONLY|O_APPEND, 0666);
                if (fd >= 0) {
                    dprintf(fd, "execv FAILED: %s\n", strerror(errno));
                    close(fd);
                }
            }
            break;
        }
    }
    return 1;
}
