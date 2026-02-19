/*
 * Phase 4a Bootstrap Test
 *
 * Test whether bootstrap_register() works in our simulator environment.
 * If it does, we can pre-register the Purple port names before
 * _GSEventInitializeApp tries to, avoiding its abort().
 */

#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <stdio.h>
#include <stdarg.h>
#include <mach/mach.h>

/* bootstrap.h not in simulator SDK - declare manually */
extern mach_port_t bootstrap_port;
kern_return_t bootstrap_look_up(mach_port_t bp, const char *name, mach_port_t *sp);
kern_return_t bootstrap_register(mach_port_t bp, const char *name, mach_port_t sp);
kern_return_t bootstrap_check_in(mach_port_t bp, const char *name, mach_port_t *sp);
kern_return_t bootstrap_subset(mach_port_t bp, mach_port_t requestor, mach_port_t *subset);

static char _buf[4096];
void out(const char *msg) { write(STDOUT_FILENO, msg, strlen(msg)); }
void outf(const char *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    int n = vsnprintf(_buf, sizeof(_buf), fmt, ap); va_end(ap);
    if (n > 0) write(STDOUT_FILENO, _buf, n);
}

int main(int argc, char *argv[]) {
    out("=== Bootstrap Registration Test ===\n\n");

    outf("PID: %d\n", getpid());
    outf("bootstrap_port: 0x%x\n\n", bootstrap_port);

    /* Test 1: Can we look up existing services? */
    out("--- Test 1: bootstrap_look_up for known services ---\n");
    mach_port_t port;
    kern_return_t kr;

    kr = bootstrap_look_up(bootstrap_port, "com.apple.backboard.display.services", &port);
    outf("  com.apple.backboard.display.services: %s (kr=%d)\n",
         kr == KERN_SUCCESS ? "FOUND" : "NOT FOUND", kr);

    kr = bootstrap_look_up(bootstrap_port, "PurpleSystemEventPort", &port);
    outf("  PurpleSystemEventPort: %s (kr=%d)\n",
         kr == KERN_SUCCESS ? "FOUND" : "NOT FOUND", kr);

    /* Test 2: Can we register a port? */
    out("\n--- Test 2: bootstrap_register ---\n");
    mach_port_t recv_port;
    mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &recv_port);
    mach_port_insert_right(mach_task_self(), recv_port, recv_port, MACH_MSG_TYPE_MAKE_SEND);

    kr = bootstrap_register(bootstrap_port, "com.rosettasim.test", recv_port);
    outf("  bootstrap_register(com.rosettasim.test): %s (kr=%d, 0x%x)\n",
         kr == KERN_SUCCESS ? "SUCCESS" : "FAILED", kr, kr);

    /* Test 3: Try to register a Purple-like name */
    out("\n--- Test 3: Register Purple-style name ---\n");
    mach_port_t recv_port2;
    mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &recv_port2);
    mach_port_insert_right(mach_task_self(), recv_port2, recv_port2, MACH_MSG_TYPE_MAKE_SEND);

    char pid_name[256];
    snprintf(pid_name, sizeof(pid_name), "com.apple.iphone.purpleevents.%d", getpid());
    kr = bootstrap_register(bootstrap_port, pid_name, recv_port2);
    outf("  bootstrap_register(%s): %s (kr=%d, 0x%x)\n",
         pid_name, kr == KERN_SUCCESS ? "SUCCESS" : "FAILED", kr, kr);

    /* Test 4: Try bootstrap_check_in */
    out("\n--- Test 4: bootstrap_check_in ---\n");
    mach_port_t checkin_port;
    kr = bootstrap_check_in(bootstrap_port, "com.rosettasim.test2", &checkin_port);
    outf("  bootstrap_check_in(com.rosettasim.test2): %s (kr=%d, 0x%x)\n",
         kr == KERN_SUCCESS ? "SUCCESS" : "FAILED", kr, kr);

    /* Test 5: Can we create a bootstrap subset? */
    out("\n--- Test 5: bootstrap_subset ---\n");
    mach_port_t subset_port;
    kr = bootstrap_subset(bootstrap_port, mach_task_self(), &subset_port);
    outf("  bootstrap_subset: %s (kr=%d, 0x%x, port=0x%x)\n",
         kr == KERN_SUCCESS ? "SUCCESS" : "FAILED", kr, kr, subset_port);

    if (kr == KERN_SUCCESS) {
        /* Try registering in the subset */
        mach_port_t recv_port3;
        mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &recv_port3);
        mach_port_insert_right(mach_task_self(), recv_port3, recv_port3, MACH_MSG_TYPE_MAKE_SEND);

        kr = bootstrap_register(subset_port, "PurpleSystemEventPort.test", recv_port3);
        outf("  register in subset: %s (kr=%d, 0x%x)\n",
             kr == KERN_SUCCESS ? "SUCCESS" : "FAILED", kr, kr);
    }

    out("\n=== Test complete ===\n");
    return 0;
}
