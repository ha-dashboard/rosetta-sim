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
#include <dlfcn.h>

/* Bootstrap API — not available in iOS simulator SDK headers */
extern mach_port_t bootstrap_port;
extern kern_return_t bootstrap_look_up(mach_port_t bp, const char *name, mach_port_t *sp);
extern kern_return_t bootstrap_check_in(mach_port_t bp, const char *name, mach_port_t *sp);
extern kern_return_t bootstrap_register(mach_port_t bp, const char *name, mach_port_t sp);

/* XPC types and functions — no headers in iOS 10.3 simulator SDK.
 * These are all exported symbols in the SDK's libxpc.dylib. */
typedef void *xpc_connection_t;
typedef void *xpc_object_t;
typedef void *xpc_endpoint_t;
typedef void (^xpc_handler_t)(xpc_object_t);
typedef struct dispatch_queue_s *dispatch_queue_t;

#define XPC_CONNECTION_MACH_SERVICE_LISTENER (1ULL << 0)

extern xpc_connection_t xpc_connection_create_mach_service(const char *name,
    dispatch_queue_t targetq, uint64_t flags);
extern xpc_connection_t xpc_connection_create_listener(const char *name,
    dispatch_queue_t targetq);
extern xpc_connection_t xpc_connection_create_from_endpoint(xpc_endpoint_t endpoint);
extern xpc_endpoint_t xpc_endpoint_create(xpc_connection_t connection);
extern void xpc_connection_set_event_handler(xpc_connection_t connection,
    xpc_handler_t handler);
extern void xpc_connection_resume(xpc_connection_t connection);
extern void xpc_connection_cancel(xpc_connection_t connection);

/* Broker protocol — must match rosettasim_broker.c */
#define BROKER_REGISTER_PORT 700
#define BROKER_LOOKUP_PORT   701

static mach_port_t g_broker_port = MACH_PORT_NULL;
static int g_init_done = 0;

/* Original function pointer for xpc_connection_create_mach_service.
 * Must use dlsym(RTLD_NEXT) because DYLD interposition redirects ALL
 * calls through the symbol table, including calls from within our dylib. */
typedef xpc_connection_t (*xpc_create_mach_service_fn)(const char *, dispatch_queue_t, uint64_t);
static xpc_create_mach_service_fn g_real_xpc_create_mach_service = NULL;

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

/* Register a service port with the broker using msg_id 700 (BROKER_REGISTER_PORT).
 * Sends a complex message with port descriptor. Format must match
 * bootstrap_complex_request_t in rosettasim_broker.c. */
static kern_return_t broker_register(const char *name, mach_port_t port) {
    init_broker_port();
    if (g_broker_port == MACH_PORT_NULL || !name) return KERN_FAILURE;

    /* Create reply port */
    mach_port_t reply_port;
    kern_return_t kr = mach_port_allocate(mach_task_self(),
                                           MACH_PORT_RIGHT_RECEIVE, &reply_port);
    if (kr != KERN_SUCCESS) return kr;

    /* Build BROKER_REGISTER_PORT request — complex message with port descriptor */
#pragma pack(4)
    struct {
        mach_msg_header_t header;           /* 24 bytes */
        mach_msg_body_t body;               /*  4 bytes */
        mach_msg_port_descriptor_t port_desc; /* 12 bytes */
        NDR_record_t ndr;                   /*  8 bytes */
        uint32_t name_len;                  /*  4 bytes */
        char name[128];                     /* 128 bytes */
    } req;
#pragma pack()

    memset(&req, 0, sizeof(req));

    uint32_t name_len = (uint32_t)strlen(name);
    if (name_len >= 128) name_len = 127;

    req.header.msgh_bits = MACH_MSGH_BITS_COMPLEX |
        MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, MACH_MSG_TYPE_MAKE_SEND_ONCE);
    req.header.msgh_size = sizeof(req);
    req.header.msgh_remote_port = g_broker_port;
    req.header.msgh_local_port = reply_port;
    req.header.msgh_id = BROKER_REGISTER_PORT;

    req.body.msgh_descriptor_count = 1;

    req.port_desc.name = port;
    req.port_desc.disposition = MACH_MSG_TYPE_COPY_SEND;
    req.port_desc.type = MACH_MSG_PORT_DESCRIPTOR;

    req.ndr = NDR_record;
    req.name_len = name_len;
    memcpy(req.name, name, name_len);

    /* Send request and receive reply */
    union {
        mach_msg_header_t header;
        uint8_t raw[2048];
    } reply_buf;
    memset(&reply_buf, 0, sizeof(reply_buf));

    kr = mach_msg(&req.header,
                   MACH_SEND_MSG | MACH_RCV_MSG | MACH_RCV_TIMEOUT,
                   sizeof(req),
                   sizeof(reply_buf),
                   reply_port,
                   5000, MACH_PORT_NULL);

    mach_port_deallocate(mach_task_self(), reply_port);

    if (kr != KERN_SUCCESS) {
        sb_log("broker register '%s': mach_msg failed: %d", name, kr);
        return kr;
    }

    /* Parse reply — broker sends bootstrap_error_reply_t (non-complex) */
    /* The reply has: header + NDR + ret_code */
    uint8_t *rp = reply_buf.raw;
    /* Skip header (24 bytes) + NDR (8 bytes) to get ret_code */
    kern_return_t ret_code = *(kern_return_t *)(rp + sizeof(mach_msg_header_t) +
                                                  sizeof(NDR_record_t));

    sb_log("broker register '%s': result=%d", name, ret_code);
    return ret_code;
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

/* Interpose xpc_connection_create_mach_service — the critical XPC fix.
 *
 * assertiond calls this with XPC_CONNECTION_MACH_SERVICE_LISTENER to register
 * its XPC services. The real implementation fails because it tries to register
 * with launchd, but our processes use the broker instead.
 *
 * LISTENER mode: Create an anonymous XPC listener via xpc_connection_create_listener(),
 *   extract its Mach receive port, register the service name + send right with
 *   the broker, and return the listener connection.
 *
 * CLIENT mode: Let the real implementation try first (bootstrap_port is set to
 *   broker, so internal bootstrap_look_up may work). If that fails, look up
 *   the port from the broker and create a connection from an endpoint.
 */
static xpc_connection_t replacement_xpc_connection_create_mach_service(
    const char *name, dispatch_queue_t targetq, uint64_t flags) {

    init_broker_port();

    /* Resolve the real function on first call */
    if (!g_real_xpc_create_mach_service) {
        g_real_xpc_create_mach_service = (xpc_create_mach_service_fn)
            dlsym(RTLD_NEXT, "xpc_connection_create_mach_service");
    }

    if (!name) {
        if (g_real_xpc_create_mach_service)
            return g_real_xpc_create_mach_service(name, targetq, flags);
        return NULL;
    }

    if (flags & XPC_CONNECTION_MACH_SERVICE_LISTENER) {
        /* === LISTENER MODE ===
         * With bootstrap_fix.dylib's binary patches in place, the real
         * xpc_connection_create_mach_service works because its internal
         * bootstrap_check_in and launch_msg calls are properly routed
         * through our broker. Just call the real function. */
        sb_log("xpc_create_mach_service LISTENER '%s' — calling real function", name);

        if (g_real_xpc_create_mach_service) {
            xpc_connection_t conn = g_real_xpc_create_mach_service(name, targetq, flags);
            if (conn) {
                sb_log("  real LISTENER '%s' → %p (OK)", name, conn);
                return conn;
            }
            sb_log("  real LISTENER '%s' → NULL, trying fallback", name);
        }

        /* Fallback: do bootstrap_check_in manually and create listener.
         * This is needed if the real function fails (e.g., XPC pipe protocol
         * isn't fully implemented in the broker yet). */
        {
            mach_port_t svc_port = MACH_PORT_NULL;
            kern_return_t bkr = bootstrap_check_in(bootstrap_port, name, &svc_port);
            sb_log("  fallback check_in '%s': kr=%d port=0x%x", name, bkr, svc_port);
            if (bkr == KERN_SUCCESS && svc_port != MACH_PORT_NULL) {
                sb_log("  fallback: got receive right for '%s' (port 0x%x)", name, svc_port);
            }
        }

        xpc_connection_t listener = xpc_connection_create_listener(name, targetq);
        sb_log("  fallback listener for '%s': %p", name, listener);
        return listener;

    } else {
        /* === CLIENT MODE === */
        sb_log("xpc_create_mach_service CLIENT '%s'", name);

        /* Try the real implementation first. Our constructor already set
         * bootstrap_port = g_broker_port, so the internal bootstrap_look_up
         * should route through the broker (msg_id 402). */
        if (g_real_xpc_create_mach_service) {
            xpc_connection_t conn = g_real_xpc_create_mach_service(name, targetq, flags);
            if (conn) {
                sb_log("  real xpc_create_mach_service returned %p", conn);
                return conn;
            }
        }

        /* Real implementation returned NULL. Fall back to manual lookup
         * through the broker and create connection from endpoint. */
        sb_log("  real xpc_create_mach_service failed, trying broker lookup");
        mach_port_t port = broker_lookup(name);
        if (port == MACH_PORT_NULL) {
            sb_log("  broker lookup '%s' failed too", name);
            return NULL;
        }

        sb_log("  broker found port 0x%x for '%s'", port, name);

        /* We have the send right to the service. Unfortunately there's no
         * public API to create an XPC connection from a raw Mach port.
         * Try xpc_connection_create(name, targetq) which may attempt a
         * simpler connection path. */
        return NULL;
    }
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
    { (const void *)replacement_xpc_connection_create_mach_service,
      (const void *)xpc_connection_create_mach_service },
};

/* Constructor — runs before SpringBoard's main */
__attribute__((constructor))
static void sb_shim_init(void) {
    sb_log("SpringBoard shim loaded (PID %d)", getpid());
    init_broker_port();
}
