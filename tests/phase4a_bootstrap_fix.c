/*
 * Phase 4a: Bootstrap port investigation and fix
 *
 * The simulator process has bootstrap_port == 0x0 because
 * the old dyld_sim/libSystem doesn't inherit it properly.
 * Let's check if the kernel-level bootstrap port exists
 * and try to use it.
 */

#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <stdio.h>
#include <stdarg.h>
#include <mach/mach.h>

extern mach_port_t bootstrap_port;
kern_return_t bootstrap_look_up(mach_port_t bp, const char *name, mach_port_t *sp);
kern_return_t bootstrap_register(mach_port_t bp, const char *name, mach_port_t sp);

static char _buf[4096];
void out(const char *msg) { write(STDOUT_FILENO, msg, strlen(msg)); }
void outf(const char *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    int n = vsnprintf(_buf, sizeof(_buf), fmt, ap); va_end(ap);
    if (n > 0) write(STDOUT_FILENO, _buf, n);
}

int main(int argc, char *argv[]) {
    out("=== Bootstrap Port Investigation ===\n\n");

    /* Check the global bootstrap_port */
    outf("bootstrap_port (global): 0x%x\n", bootstrap_port);

    /* Check the kernel-level bootstrap port */
    mach_port_t task_bp = MACH_PORT_NULL;
    kern_return_t kr = task_get_special_port(mach_task_self(),
                                              TASK_BOOTSTRAP_PORT, &task_bp);
    outf("task_get_special_port(TASK_BOOTSTRAP_PORT): kr=%d port=0x%x\n", kr, task_bp);

    /* If kernel has a bootstrap port but the global doesn't, set it */
    if (task_bp != MACH_PORT_NULL && bootstrap_port == MACH_PORT_NULL) {
        out("\n*** Found kernel bootstrap port but global is NULL! ***\n");
        out("*** Setting bootstrap_port = task bootstrap port ***\n\n");
        bootstrap_port = task_bp;
        outf("bootstrap_port (after fix): 0x%x\n\n", bootstrap_port);

        /* Now try service operations */
        out("--- Testing with fixed bootstrap_port ---\n");

        mach_port_t recv;
        mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &recv);
        mach_port_insert_right(mach_task_self(), recv, recv, MACH_MSG_TYPE_MAKE_SEND);

        kr = bootstrap_register(bootstrap_port, "com.rosettasim.test", recv);
        outf("  bootstrap_register: %s (kr=%d, 0x%x)\n",
             kr == KERN_SUCCESS ? "SUCCESS" : "FAILED", kr, kr);

        mach_port_t found;
        kr = bootstrap_look_up(bootstrap_port, "com.apple.CoreSimulator.SimDevice.SpringBoard.launchd_sim",
                                &found);
        outf("  look_up launchd_sim: %s (kr=%d)\n",
             kr == KERN_SUCCESS ? "FOUND" : "NOT FOUND", kr);

        kr = bootstrap_look_up(bootstrap_port, "com.apple.audio.coreaudiod", &found);
        outf("  look_up coreaudiod: %s (kr=%d)\n",
             kr == KERN_SUCCESS ? "FOUND" : "NOT FOUND", kr);
    } else if (task_bp == MACH_PORT_NULL) {
        out("\n*** Kernel also has no bootstrap port! ***\n");
        out("*** Need to create one from the parent process ***\n");
    }

    out("\n=== Done ===\n");
    return 0;
}
