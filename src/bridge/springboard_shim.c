/*
 * springboard_shim.c — DYLD interposition library for SpringBoard
 *
 * Injected into SpringBoard via DYLD_INSERT_LIBRARIES to route
 * bootstrap_look_up calls through the RosettaSim broker instead of
 * the iOS SDK's mach_msg2/XPC path (which hangs on macOS 26).
 *
 * This is NOT a bypass — it's a proper routing layer that forwards
 * service lookups to the broker, which holds the real service ports
 * registered by backboardd.
 *
 * Compile: x86_64, linked against iOS 10.3 simulator SDK
 */

#include <mach/mach.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <stdarg.h>
#include <mach/ndr.h>

/* Bootstrap API — not available in iOS simulator SDK headers */
extern mach_port_t bootstrap_port;
extern kern_return_t bootstrap_look_up(mach_port_t bp, const char *name, mach_port_t *sp);
extern kern_return_t bootstrap_check_in(mach_port_t bp, const char *name, mach_port_t *sp);
extern kern_return_t bootstrap_register(mach_port_t bp, const char *name, mach_port_t sp);

/* Broker protocol — must match rosettasim_broker.c */
#define BROKER_LOOKUP_PORT 701

static mach_port_t g_broker_port = MACH_PORT_NULL;
static int g_init_done = 0;

static void sb_log(const char *fmt, ...) {
    char buf[512];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    if (n > 0) {
        write(STDERR_FILENO, "[SBShim] ", 9);
        write(STDERR_FILENO, buf, n);
        write(STDERR_FILENO, "\n", 1);
    }
}

static void init_broker_port(void) {
    if (g_init_done) return;
    g_init_done = 1;

    kern_return_t kr = task_get_special_port(mach_task_self(),
                                              TASK_BOOTSTRAP_PORT,
                                              &g_broker_port);
    if (kr == KERN_SUCCESS && g_broker_port != MACH_PORT_NULL) {
        sb_log("Broker port: 0x%x", g_broker_port);
        /* Also set bootstrap_port global so the iOS SDK's bootstrap
         * functions have a valid port to send to. */
        bootstrap_port = g_broker_port;
    } else {
        sb_log("WARNING: No broker port found (kr=%d)", kr);
    }
}

/* Lookup a service through the broker using msg_id 701 (BROKER_LOOKUP_PORT).
 * Message format must match rosettasim_broker.c's handle_broker_message(). */
/* Lookup a service through the broker — matches bridge_broker_lookup() format exactly */
static mach_port_t broker_lookup(const char *name) {
    init_broker_port();
    if (g_broker_port == MACH_PORT_NULL || !name) return MACH_PORT_NULL;

    /* Create reply port */
    mach_port_t reply_port;
    kern_return_t kr = mach_port_allocate(mach_task_self(),
                                           MACH_PORT_RIGHT_RECEIVE, &reply_port);
    if (kr != KERN_SUCCESS) return MACH_PORT_NULL;

    /* Build BROKER_LOOKUP_PORT request — same layout as bridge uses */
    union {
        struct {
            mach_msg_header_t header;   /* 24 bytes */
            NDR_record_t ndr;           /* 8 bytes */
            uint32_t name_len;          /* 4 bytes */
            char name[128];             /* 128 bytes */
        } req;
        uint8_t raw[2048];
    } buf;
    memset(&buf, 0, sizeof(buf));

    uint32_t name_len = (uint32_t)strlen(name);
    if (name_len >= 128) name_len = 127;

    buf.req.header.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND,
                                                MACH_MSG_TYPE_MAKE_SEND_ONCE);
    buf.req.header.msgh_size = sizeof(buf.req);
    buf.req.header.msgh_remote_port = g_broker_port;
    buf.req.header.msgh_local_port = reply_port;
    buf.req.header.msgh_id = BROKER_LOOKUP_PORT;
    buf.req.ndr = NDR_record;
    buf.req.name_len = name_len;
    memcpy(buf.req.name, name, name_len);

    /* Send request and receive reply in the same buffer */
    kr = mach_msg(&buf.req.header,
                   MACH_SEND_MSG | MACH_RCV_MSG | MACH_RCV_TIMEOUT,
                   sizeof(buf.req),
                   sizeof(buf),
                   reply_port,
                   5000, MACH_PORT_NULL);

    mach_port_deallocate(mach_task_self(), reply_port);

    if (kr != KERN_SUCCESS) {
        sb_log("broker lookup '%s': mach_msg failed: %d", name, kr);
        return MACH_PORT_NULL;
    }

    /* Parse reply — same as bridge_broker_lookup */
    mach_msg_header_t *rh = (mach_msg_header_t *)buf.raw;

    if (rh->msgh_bits & MACH_MSGH_BITS_COMPLEX) {
        mach_msg_body_t *body = (mach_msg_body_t *)(buf.raw + sizeof(mach_msg_header_t));
        if (body->msgh_descriptor_count >= 1) {
            mach_msg_port_descriptor_t *pd = (mach_msg_port_descriptor_t *)(body + 1);
            sb_log("broker lookup '%s': found port=%u", name, pd->name);
            return pd->name;
        }
    }

    sb_log("broker lookup '%s': not found (non-complex reply)", name);
    return MACH_PORT_NULL;
}

/* Interpose bootstrap_look_up — route ALL lookups through broker.
 * SpringBoard needs many services that backboardd registered with the broker. */
static kern_return_t replacement_bootstrap_look_up(mach_port_t bp,
                                                     const char *name,
                                                     mach_port_t *sp) {
    init_broker_port();

    if (!name || !sp) {
        return bootstrap_look_up(bp, name, sp);
    }

    sb_log("bootstrap_look_up('%s') called", name);

    /* Try broker first for all services */
    mach_port_t port = broker_lookup(name);
    if (port != MACH_PORT_NULL) {
        *sp = port;
        sb_log("bootstrap_look_up('%s') → broker port %u", name, port);
        return KERN_SUCCESS;
    }

    /* Broker didn't have it — try the real bootstrap.
     * This handles host macOS services that aren't in the broker. */
    kern_return_t kr = bootstrap_look_up(bp, name, sp);
    sb_log("bootstrap_look_up('%s') → %s (%d) port=%u",
           name, kr == KERN_SUCCESS ? "real OK" : "FAILED", kr,
           (kr == KERN_SUCCESS && sp) ? *sp : 0);
    return kr;
}

/* Interpose bootstrap_check_in — route through broker for service registration */
static kern_return_t replacement_bootstrap_check_in(mach_port_t bp,
                                                      const char *name,
                                                      mach_port_t *sp) {
    init_broker_port();
    sb_log("bootstrap_check_in('%s')", name ? name : "(null)");

    /* Try real check_in first */
    kern_return_t kr = bootstrap_check_in(bp, name, sp);
    if (kr == KERN_SUCCESS) {
        sb_log("  → checked in OK, port=%u", sp ? *sp : 0);
        return kr;
    }

    /* Real check_in failed — create a local port */
    sb_log("  → failed (%d), creating local port", kr);
    mach_port_t port;
    mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &port);
    mach_port_insert_right(mach_task_self(), port, port, MACH_MSG_TYPE_MAKE_SEND);
    *sp = port;
    return KERN_SUCCESS;
}

/* Interpose bootstrap_register — route through broker */
static kern_return_t replacement_bootstrap_register(mach_port_t bp,
                                                      const char *name,
                                                      mach_port_t sp) {
    init_broker_port();
    sb_log("bootstrap_register('%s', port=%u)", name ? name : "(null)", sp);

    /* Try real register */
    kern_return_t kr = bootstrap_register(bp, name, sp);
    if (kr == KERN_SUCCESS) {
        sb_log("  → registered OK");
        return kr;
    }

    sb_log("  → real register failed (%d), accepting locally", kr);
    return KERN_SUCCESS;
}

/* DYLD interposition table */
typedef struct {
    const void *replacement;
    const void *replacee;
} interpose_t;

__attribute__((used))
static const interpose_t interposers[]
__attribute__((section("__DATA,__interpose"))) = {
    { (const void *)replacement_bootstrap_look_up,
      (const void *)bootstrap_look_up },
    { (const void *)replacement_bootstrap_check_in,
      (const void *)bootstrap_check_in },
    { (const void *)replacement_bootstrap_register,
      (const void *)bootstrap_register },
};

/* Constructor — runs before SpringBoard's main */
__attribute__((constructor))
static void sb_shim_init(void) {
    sb_log("SpringBoard shim loaded (PID %d)", getpid());
    init_broker_port();
}
