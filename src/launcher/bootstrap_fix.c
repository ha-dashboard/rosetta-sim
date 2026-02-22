/*
 * bootstrap_fix.c
 *
 * DYLD_INSERT_LIBRARIES shim that replaces the iOS 10.3 SDK's broken
 * bootstrap_look_up and bootstrap_check_in with implementations that
 * use raw MIG messages to the real TASK_BOOTSTRAP_PORT.
 *
 * Problem: The iOS SDK's libxpc caches the bootstrap port during its
 * initializer (which runs before any constructors). At that point,
 * bootstrap_port is 0x0 because libxpc hasn't read TASK_BOOTSTRAP_PORT.
 * Even setting bootstrap_port later doesn't help because libxpc uses
 * its cached copy.
 *
 * Fix: DYLD interposition replaces bootstrap_look_up, bootstrap_check_in,
 * and bootstrap_register with implementations that read TASK_BOOTSTRAP_PORT
 * on every call and send standard MIG messages directly.
 *
 * Compile: clang -arch x86_64 -isysroot <ios_sdk> -shared -o bootstrap_fix.dylib bootstrap_fix.c
 */

#include <mach/mach.h>
#include <stdio.h>
#include <unistd.h>
#include <string.h>
#include <stdarg.h>

/* bootstrap types */
typedef char name_t[128];
extern mach_port_t bootstrap_port;

/* MIG message IDs (from bootstrap.defs subsystem 400) */
#define BOOTSTRAP_MSG_CHECK_IN   402
#define BOOTSTRAP_MSG_REGISTER   403
#define BOOTSTRAP_MSG_LOOK_UP    404

/* Bootstrap error codes */
#define BOOTSTRAP_SUCCESS            0
#define BOOTSTRAP_UNKNOWN_SERVICE    1102

/* Logging */
static void bfix_log(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void bfix_log(const char *fmt, ...) {
    char buf[512];
    va_list args;
    va_start(args, fmt);
    int len = vsnprintf(buf, sizeof(buf), fmt, args);
    va_end(args);
    if (len > 0) write(STDERR_FILENO, buf, len);
}

/* Get the real bootstrap port from the kernel */
static mach_port_t get_bootstrap_port(void) {
    mach_port_t bp = MACH_PORT_NULL;
    task_get_special_port(mach_task_self(), TASK_BOOTSTRAP_PORT, &bp);
    return bp;
}

/*
 * MIG request for bootstrap_look_up (ID 404) and bootstrap_check_in (ID 402):
 *   header (24) + NDR (8) + name_t (128) = 160 bytes
 *
 * MIG reply for port-returning operations:
 *   header (24) + body (4) + port_desc (12) = 40 bytes
 *
 * MIG reply for error:
 *   header (24) + NDR (8) + retcode (4) = 36 bytes
 *
 * MIG request for bootstrap_register (ID 403):
 *   header (24) + body (4) + port_desc (12) + NDR (8) + name_t (128) = 176 bytes
 */

#pragma pack(4)
typedef struct {
    mach_msg_header_t head;
    NDR_record_t ndr;
    name_t service_name;
} bootstrap_lookup_request_t;

typedef struct {
    mach_msg_header_t head;
    mach_msg_body_t body;
    mach_msg_port_descriptor_t port;
} bootstrap_port_reply_t;

typedef struct {
    mach_msg_header_t head;
    NDR_record_t ndr;
    kern_return_t ret_code;
} bootstrap_error_reply_t;

typedef struct {
    mach_msg_header_t head;
    mach_msg_body_t body;
    mach_msg_port_descriptor_t port;
    NDR_record_t ndr;
    name_t service_name;
} bootstrap_register_request_t;
#pragma pack()

/* Union for receiving either reply type */
typedef union {
    mach_msg_header_t head;
    bootstrap_port_reply_t port_reply;
    bootstrap_error_reply_t error_reply;
    char buf[256];
} bootstrap_reply_t;

/* Replacement bootstrap_look_up */
kern_return_t replacement_bootstrap_look_up(mach_port_t bp,
                                             const name_t service_name,
                                             mach_port_t *service_port) {
    mach_port_t real_bp = get_bootstrap_port();
    if (real_bp == MACH_PORT_NULL) {
        bfix_log("[bfix] look_up('%s'): no bootstrap port\n", service_name);
        return MACH_SEND_INVALID_DEST;
    }

    bfix_log("[bfix] look_up('%s') via port 0x%x\n", service_name, real_bp);

    /* Build MIG request */
    bootstrap_lookup_request_t req;
    memset(&req, 0, sizeof(req));
    req.head.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, MACH_MSG_TYPE_MAKE_SEND_ONCE);
    req.head.msgh_size = sizeof(req);
    req.head.msgh_remote_port = real_bp;

    /* Create reply port */
    mach_port_t reply_port;
    kern_return_t kr = mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &reply_port);
    if (kr != KERN_SUCCESS) return kr;

    req.head.msgh_local_port = reply_port;
    req.head.msgh_id = BOOTSTRAP_MSG_LOOK_UP;
    req.ndr = NDR_record;
    strncpy(req.service_name, service_name, sizeof(req.service_name) - 1);

    /* Send request */
    kr = mach_msg(&req.head, MACH_SEND_MSG, sizeof(req), 0,
                  MACH_PORT_NULL, 5000, MACH_PORT_NULL);
    if (kr != KERN_SUCCESS) {
        bfix_log("[bfix] look_up('%s'): send failed: 0x%x\n", service_name, kr);
        mach_port_deallocate(mach_task_self(), reply_port);
        return kr;
    }

    /* Receive reply into separate buffer */
    bootstrap_reply_t reply;
    memset(&reply, 0, sizeof(reply));
    kr = mach_msg(&reply.head, MACH_RCV_MSG, 0, sizeof(reply), reply_port,
                  5000, MACH_PORT_NULL);
    mach_port_deallocate(mach_task_self(), reply_port);

    if (kr != KERN_SUCCESS) {
        bfix_log("[bfix] look_up('%s'): recv failed: 0x%x\n", service_name, kr);
        return kr;
    }

    bfix_log("[bfix] look_up('%s'): reply id=%d bits=0x%x size=%u\n",
             service_name, reply.head.msgh_id, reply.head.msgh_bits, reply.head.msgh_size);

    /* Check if complex (has port descriptor) = success */
    if (reply.head.msgh_bits & MACH_MSGH_BITS_COMPLEX) {
        *service_port = reply.port_reply.port.name;
        bfix_log("[bfix] look_up('%s'): found port 0x%x\n", service_name, *service_port);
        return KERN_SUCCESS;
    }

    /* Simple message = error */
    kern_return_t ret = reply.error_reply.ret_code;
    bfix_log("[bfix] look_up('%s'): error %d\n", service_name, ret);
    *service_port = MACH_PORT_NULL;
    return ret;
}

/* Replacement bootstrap_check_in */
kern_return_t replacement_bootstrap_check_in(mach_port_t bp,
                                              const name_t service_name,
                                              mach_port_t *service_port) {
    mach_port_t real_bp = get_bootstrap_port();
    if (real_bp == MACH_PORT_NULL) {
        bfix_log("[bfix] check_in('%s'): no bootstrap port\n", service_name);
        return MACH_SEND_INVALID_DEST;
    }

    bfix_log("[bfix] check_in('%s') via port 0x%x\n", service_name, real_bp);

    /* Build MIG request (same format as look_up) */
    bootstrap_lookup_request_t req;
    memset(&req, 0, sizeof(req));
    req.head.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, MACH_MSG_TYPE_MAKE_SEND_ONCE);
    req.head.msgh_size = sizeof(req);
    req.head.msgh_remote_port = real_bp;

    mach_port_t reply_port;
    kern_return_t kr = mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &reply_port);
    if (kr != KERN_SUCCESS) return kr;

    req.head.msgh_local_port = reply_port;
    req.head.msgh_id = BOOTSTRAP_MSG_CHECK_IN;
    req.ndr = NDR_record;
    strncpy(req.service_name, service_name, sizeof(req.service_name) - 1);

    /* Send request */
    kr = mach_msg(&req.head, MACH_SEND_MSG, sizeof(req), 0,
                  MACH_PORT_NULL, 5000, MACH_PORT_NULL);
    if (kr != KERN_SUCCESS) {
        bfix_log("[bfix] check_in('%s'): send failed: 0x%x\n", service_name, kr);
        mach_port_deallocate(mach_task_self(), reply_port);
        return kr;
    }

    /* Receive reply */
    bootstrap_reply_t reply;
    memset(&reply, 0, sizeof(reply));
    kr = mach_msg(&reply.head, MACH_RCV_MSG, 0, sizeof(reply), reply_port,
                  5000, MACH_PORT_NULL);
    mach_port_deallocate(mach_task_self(), reply_port);

    if (kr != KERN_SUCCESS) {
        bfix_log("[bfix] check_in('%s'): recv failed: 0x%x\n", service_name, kr);
        return kr;
    }

    bfix_log("[bfix] check_in('%s'): reply id=%d bits=0x%x size=%u\n",
             service_name, reply.head.msgh_id, reply.head.msgh_bits, reply.head.msgh_size);

    if (reply.head.msgh_bits & MACH_MSGH_BITS_COMPLEX) {
        *service_port = reply.port_reply.port.name;
        bfix_log("[bfix] check_in('%s'): got port 0x%x\n", service_name, *service_port);
        return KERN_SUCCESS;
    }

    kern_return_t ret = reply.error_reply.ret_code;
    bfix_log("[bfix] check_in('%s'): error %d\n", service_name, ret);
    *service_port = MACH_PORT_NULL;
    return ret;
}

/* Replacement bootstrap_register */
kern_return_t replacement_bootstrap_register(mach_port_t bp,
                                              const name_t service_name,
                                              mach_port_t service_port) {
    mach_port_t real_bp = get_bootstrap_port();
    if (real_bp == MACH_PORT_NULL) {
        bfix_log("[bfix] register('%s'): no bootstrap port\n", service_name);
        return MACH_SEND_INVALID_DEST;
    }

    bfix_log("[bfix] register('%s', 0x%x) via port 0x%x\n", service_name, service_port, real_bp);

    /* Build MIG request (complex, includes port descriptor) */
    bootstrap_register_request_t req;
    memset(&req, 0, sizeof(req));
    req.head.msgh_bits = MACH_MSGH_BITS_COMPLEX |
                         MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, MACH_MSG_TYPE_MAKE_SEND_ONCE);
    req.head.msgh_size = sizeof(req);
    req.head.msgh_remote_port = real_bp;

    mach_port_t reply_port;
    kern_return_t kr = mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &reply_port);
    if (kr != KERN_SUCCESS) return kr;

    req.head.msgh_local_port = reply_port;
    req.head.msgh_id = BOOTSTRAP_MSG_REGISTER;
    req.body.msgh_descriptor_count = 1;
    req.port.name = service_port;
    req.port.disposition = MACH_MSG_TYPE_COPY_SEND;
    req.port.type = MACH_MSG_PORT_DESCRIPTOR;
    req.ndr = NDR_record;
    strncpy(req.service_name, service_name, sizeof(req.service_name) - 1);

    /* Send request */
    kr = mach_msg(&req.head, MACH_SEND_MSG, sizeof(req), 0,
                  MACH_PORT_NULL, 5000, MACH_PORT_NULL);
    if (kr != KERN_SUCCESS) {
        bfix_log("[bfix] register('%s'): send failed: 0x%x\n", service_name, kr);
        mach_port_deallocate(mach_task_self(), reply_port);
        return kr;
    }

    /* Receive reply */
    bootstrap_reply_t reply;
    memset(&reply, 0, sizeof(reply));
    kr = mach_msg(&reply.head, MACH_RCV_MSG, 0, sizeof(reply), reply_port,
                  5000, MACH_PORT_NULL);
    mach_port_deallocate(mach_task_self(), reply_port);

    if (kr != KERN_SUCCESS) {
        bfix_log("[bfix] register('%s'): recv failed: 0x%x\n", service_name, kr);
        return kr;
    }

    kern_return_t ret = reply.error_reply.ret_code;
    bfix_log("[bfix] register('%s'): result %d\n", service_name, ret);
    return ret;
}

/* Forward declarations for interposition targets */
extern kern_return_t bootstrap_look_up(mach_port_t, const name_t, mach_port_t *);
extern kern_return_t bootstrap_check_in(mach_port_t, const name_t, mach_port_t *);
extern kern_return_t bootstrap_register(mach_port_t, const name_t, mach_port_t);

/* DYLD interposition */
__attribute__((used))
static const struct {
    const void *replacement;
    const void *replacee;
} interpositions[] __attribute__((section("__DATA,__interpose"))) = {
    { (void *)replacement_bootstrap_look_up,   (void *)bootstrap_look_up },
    { (void *)replacement_bootstrap_check_in,  (void *)bootstrap_check_in },
    { (void *)replacement_bootstrap_register,  (void *)bootstrap_register },
};

/* Also set the global for any code that reads it directly */
__attribute__((constructor))
static void bootstrap_fix_constructor(void) {
    mach_port_t bp = get_bootstrap_port();
    bfix_log("[bfix] constructor: setting bootstrap_port = 0x%x (was 0x%x)\n", bp, bootstrap_port);
    if (bp != MACH_PORT_NULL) {
        bootstrap_port = bp;
    }
}
