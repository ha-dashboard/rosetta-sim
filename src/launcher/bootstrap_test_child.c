/*
 * bootstrap_test_child.c
 *
 * Simple x86_64 test binary compiled against iOS 10.3 SDK that exercises
 * bootstrap_check_in and bootstrap_look_up to verify port propagation.
 *
 * Uses write() instead of printf because the iOS SDK's libc doesn't flush
 * stdio to terminal properly under DYLD_ROOT_PATH.
 */

#include <mach/mach.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>

/* bootstrap.h not in iOS SDK - declare manually */
typedef char name_t[128];
extern mach_port_t bootstrap_port;
extern kern_return_t bootstrap_look_up(mach_port_t bp, const name_t service_name, mach_port_t *sp);
extern kern_return_t bootstrap_check_in(mach_port_t bp, const name_t service_name, mach_port_t *sp);
extern kern_return_t bootstrap_register(mach_port_t bp, const name_t service_name, mach_port_t sp);

/* Direct write() logging - bypasses iOS SDK's broken stdio */
static int g_fd = -1;

static void LOG(const char *fmt, ...) {
    char buf[512];
    va_list args;
    va_start(args, fmt);
    int len = vsnprintf(buf, sizeof(buf), fmt, args);
    va_end(args);
    if (len > 0) {
        write(STDERR_FILENO, buf, len);
        if (g_fd >= 0) write(g_fd, buf, len);
    }
}

int main(void) {
    g_fd = open("/tmp/bootstrap_test_child.log", O_WRONLY | O_CREAT | O_TRUNC, 0644);

    LOG("[child] PID=%d\n", getpid());

    /* Check bootstrap port via task_get_special_port */
    mach_port_t bp = MACH_PORT_NULL;
    kern_return_t kr = task_get_special_port(mach_task_self(), TASK_BOOTSTRAP_PORT, &bp);
    LOG("[child] task_get_special_port(TASK_BOOTSTRAP_PORT): kr=0x%x, port=0x%x\n", kr, bp);

    /* Check the global bootstrap_port variable */
    LOG("[child] bootstrap_port global = 0x%x\n", bootstrap_port);

    if (bp == MACH_PORT_NULL && bootstrap_port == MACH_PORT_NULL) {
        LOG("[child] ERROR: No bootstrap port!\n");
        if (g_fd >= 0) close(g_fd);
        return 1;
    }

    mach_port_t use_bp = (bp != MACH_PORT_NULL) ? bp : bootstrap_port;
    LOG("[child] Using bootstrap port: 0x%x\n", use_bp);

    /* Test 1: bootstrap_look_up */
    LOG("\n[child] === Test 1: bootstrap_look_up ===\n");
    mach_port_t svc = MACH_PORT_NULL;
    kr = bootstrap_look_up(use_bp, "com.apple.test.service1", &svc);
    LOG("[child] look_up('com.apple.test.service1'): kr=0x%x (%d), port=0x%x\n", kr, kr, svc);

    /* Test 2: bootstrap_check_in */
    LOG("\n[child] === Test 2: bootstrap_check_in ===\n");
    mach_port_t checkin_port = MACH_PORT_NULL;
    kr = bootstrap_check_in(use_bp, "com.apple.test.myservice", &checkin_port);
    LOG("[child] check_in('com.apple.test.myservice'): kr=0x%x (%d), port=0x%x\n", kr, kr, checkin_port);

    /* Test 3: bootstrap_register */
    LOG("\n[child] === Test 3: bootstrap_register ===\n");
    if (checkin_port != MACH_PORT_NULL) {
        kr = bootstrap_register(use_bp, "com.apple.test.registered", checkin_port);
        LOG("[child] register('com.apple.test.registered'): kr=0x%x (%d)\n", kr, kr);
    } else {
        LOG("[child] skipping register (no port from check_in)\n");
    }

    /* Test 4: look_up CARenderServer */
    LOG("\n[child] === Test 4: bootstrap_look_up CARenderServer ===\n");
    mach_port_t ca_port = MACH_PORT_NULL;
    kr = bootstrap_look_up(use_bp, "com.apple.CARenderServer", &ca_port);
    LOG("[child] look_up('com.apple.CARenderServer'): kr=0x%x (%d), port=0x%x\n", kr, kr, ca_port);

    /* Test 5: look_up PurpleFBServer */
    LOG("\n[child] === Test 5: bootstrap_look_up PurpleFBServer ===\n");
    mach_port_t pfb_port = MACH_PORT_NULL;
    kr = bootstrap_look_up(use_bp, "PurpleFBServer", &pfb_port);
    LOG("[child] look_up('PurpleFBServer'): kr=0x%x (%d), port=0x%x\n", kr, kr, pfb_port);

    /* Test 6: raw mach_msg to bootstrap port (to verify it's our port) */
    LOG("\n[child] === Test 6: raw mach_msg to bootstrap port ===\n");
    struct {
        mach_msg_header_t head;
        char pad[164]; /* enough for bootstrap message */
    } raw_msg;
    memset(&raw_msg, 0, sizeof(raw_msg));
    raw_msg.head.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, MACH_MSG_TYPE_MAKE_SEND_ONCE);
    raw_msg.head.msgh_size = sizeof(raw_msg);
    raw_msg.head.msgh_remote_port = use_bp;
    mach_port_t reply_port;
    mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &reply_port);
    raw_msg.head.msgh_local_port = reply_port;
    raw_msg.head.msgh_id = 9999; /* custom test ID */
    /* Put a marker string at offset 32 */
    strcpy(raw_msg.pad + 8, "HELLO_FROM_CHILD");

    kr = mach_msg(&raw_msg.head, MACH_SEND_MSG | MACH_SEND_TIMEOUT,
                  sizeof(raw_msg), 0, MACH_PORT_NULL, 1000, MACH_PORT_NULL);
    LOG("[child] raw mach_msg send: kr=0x%x\n", kr);

    LOG("\n[child] All tests complete\n");
    if (g_fd >= 0) close(g_fd);
    return 0;
}
