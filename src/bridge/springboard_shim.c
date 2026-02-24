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
#include <dispatch/dispatch.h>
#include <CoreFoundation/CoreFoundation.h>

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
/* dispatch_queue_t provided by dispatch/dispatch.h */

#define XPC_CONNECTION_MACH_SERVICE_LISTENER (1ULL << 0)

/* XPC dict API — used for synthetic replies */
extern xpc_object_t xpc_dictionary_create(const char *const *keys,
                                           const xpc_object_t *values, size_t count);
extern int64_t xpc_dictionary_get_int64(xpc_object_t dict, const char *key);
extern void xpc_dictionary_set_int64(xpc_object_t dict, const char *key, int64_t val);

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
typedef void (*xpc_connection_resume_fn)(xpc_connection_t);
static xpc_connection_resume_fn g_real_xpc_connection_resume = NULL;
#define SB_CONN_TRACK_SLOTS 32
typedef struct {
    xpc_connection_t conn;
    char name[128];
} sb_conn_track_t;
static sb_conn_track_t g_sb_conn_track[SB_CONN_TRACK_SLOTS];


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


/* Logging-only helper to inspect key xpc_connection object fields
 * from libxpc disassembly offsets used in bootstrap_fix.c. */
static void sb_log_listener_fields(const char *name, xpc_connection_t conn) {
    if (!name || !conn) return;
    if (strncmp(name, "com.apple.assertiond.", 21) != 0) return;
    uint8_t *obj = (uint8_t *)conn;
    sb_log("  ASSERTIOND conn '%s': ptr=%p state=0x%x port1=0x%x send=0x%x port2=0x%x channel=%p flags_d8=0x%x flags_d9=0x%x",
           name, conn,
           *(uint32_t *)(obj + 0x28),
           *(mach_port_t *)(obj + 0x34),
           *(mach_port_t *)(obj + 0x38),
           *(mach_port_t *)(obj + 0x3c),
           *(void **)(obj + 0x58),
           (unsigned)*(uint8_t *)(obj + 0xd8),
           (unsigned)*(uint8_t *)(obj + 0xd9));
}
static void sb_track_assertiond_conn(const char *name, xpc_connection_t conn) {
    if (!name || !conn) return;
    /* Track assertiond AND backboard system-app-server connections */
    if (strncmp(name, "com.apple.assertiond.", 21) != 0 &&
        strstr(name, "system-app-server") == NULL) return;
    for (int i = 0; i < SB_CONN_TRACK_SLOTS; i++) {
        if (g_sb_conn_track[i].conn == conn || g_sb_conn_track[i].conn == NULL) {
            g_sb_conn_track[i].conn = conn;
            strncpy(g_sb_conn_track[i].name, name, sizeof(g_sb_conn_track[i].name) - 1);
            g_sb_conn_track[i].name[sizeof(g_sb_conn_track[i].name) - 1] = '\0';
            return;
        }
    }
}
static const char *sb_lookup_assertiond_conn(xpc_connection_t conn) {
    if (!conn) return NULL;
    for (int i = 0; i < SB_CONN_TRACK_SLOTS; i++) {
        if (g_sb_conn_track[i].conn == conn) return g_sb_conn_track[i].name;
    }
    return NULL;
}
static void replacement_xpc_connection_resume(xpc_connection_t connection) {
    if (!g_real_xpc_connection_resume) {
        g_real_xpc_connection_resume = (xpc_connection_resume_fn)
            dlsym(RTLD_NEXT, "xpc_connection_resume");
    }
    const char *name = sb_lookup_assertiond_conn(connection);
    if (name) {
        sb_log("xpc_connection_resume ASSERTIOND '%s' conn=%p", name, connection);
        sb_log_listener_fields(name, connection);
    }
    if (g_real_xpc_connection_resume) {
        g_real_xpc_connection_resume(connection);
    } else {
        xpc_connection_resume(connection);
    }
    if (name) {
        sb_log("xpc_connection_resume ASSERTIOND DONE '%s' conn=%p", name, connection);
        sb_log_listener_fields(name, connection);
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
        /* === LISTENER MODE === */

        /* Call real function — bootstrap_fix trampolines handle routing */
        sb_log("xpc_create_mach_service LISTENER '%s' — calling real function", name);
        if (g_real_xpc_create_mach_service) {
            xpc_connection_t conn = g_real_xpc_create_mach_service(name, targetq, flags);
            sb_log("  real LISTENER '%s' → %p", name, conn);
            sb_log_listener_fields(name, conn);
            sb_track_assertiond_conn(name, conn);
            return conn;
        }

        sb_log("  LISTENER '%s': no real function available", name);
        return NULL;

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
                /* Track CLIENT connections too (for xpc_send_sync intercept) */
                sb_track_assertiond_conn(name, conn);
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

/* ================================================================
 * SpringBoard BKSProcess bootstrap instrumentation
 *
 * Swizzle -[BKSProcess _bootstrapWithError:] to log entry/exit + error.
 * Interpose xpc_connection_send_message_with_reply_sync to log PI sends.
 * ================================================================ */
#include <objc/runtime.h>
#include <objc/message.h>

static IMP g_orig_bks_bootstrapWithError = NULL;
static int g_bks_bootstrap_logged = 0;
static int g_bks_bootstrap_in_progress = 0;

/* Swizzled -[BKSProcess _bootstrapWithError:] */
static BOOL replacement_bks_bootstrapWithError(id self, SEL _cmd, id *errorPtr) {
    /* Log entry with process info — use _bundleID ivar (not a public method) */
    const char *bid = "?";
    Ivar bidIvar = class_getInstanceVariable(object_getClass(self), "_bundleID");
    if (bidIvar) {
        id bundleID = object_getIvar(self, bidIvar);
        if (bundleID)
            bid = ((const char *(*)(id, SEL))objc_msgSend)(bundleID, sel_registerName("UTF8String"));
    }

    /* Check the _client connection */
    Ivar clientIvar = class_getInstanceVariable(object_getClass(self), "_client");
    id client = clientIvar ? object_getIvar(self, clientIvar) : nil;

    sb_log("BKS_BOOTSTRAP ENTRY: self=%p bundleID='%s' client=%p errorPtr=%p",
           (void *)self, bid, (void *)client, (void *)errorPtr);

    /* Set flag so BSDeserialize interpose knows we're in bootstrap.
     * The reply handler block runs asynchronously on a dispatch queue,
     * so g_bks_bootstrap_in_progress must stay set until EXIT. */
    g_bks_bootstrap_in_progress = 1;
    sb_log("BKS_BOOTSTRAP: set g_bks_bootstrap_in_progress=1");

    /* Call original */
    BOOL result = ((BOOL(*)(id, SEL, id *))g_orig_bks_bootstrapWithError)(self, _cmd, errorPtr);

    g_bks_bootstrap_in_progress = 0;

    /* Log exit */
    id error = (errorPtr && *errorPtr) ? *errorPtr : nil;
    const char *errDesc = "nil";
    if (error) {
        id desc = ((id(*)(id, SEL))objc_msgSend)(error, sel_registerName("description"));
        errDesc = desc ? ((const char *(*)(id, SEL))objc_msgSend)(desc, sel_registerName("UTF8String")) : "?";
    }
    sb_log("BKS_BOOTSTRAP EXIT: result=%d error=%s bundleID='%s'",
           result, errDesc, bid);

    return result;
}

/* Interpose xpc_connection_send_message_with_reply_sync to log PI sends */
extern xpc_object_t xpc_connection_send_message_with_reply_sync(
    xpc_connection_t conn, xpc_object_t message);
extern const char *xpc_copy_description(xpc_object_t obj);

static xpc_object_t replacement_xpc_send_sync(xpc_connection_t conn, xpc_object_t message) {
    /* Check if this connection targets assertiond.processinfoservice */
    const char *conn_name = NULL;
    for (int i = 0; i < SB_CONN_TRACK_SLOTS; i++) {
        if (g_sb_conn_track[i].conn == conn) {
            conn_name = g_sb_conn_track[i].name;
            break;
        }
    }

    int is_pi = (conn_name && strstr(conn_name, "processinfoservice"));
    int is_sas = (conn_name && strstr(conn_name, "system-app-server"));

    if (is_pi) {
        sb_log("BKS_SEND_SYNC: conn=%p name='%s' msg=%p", (void *)conn, conn_name, (void *)message);
    }

    /* Intercept messages to com.apple.backboard.system-app-server.
     * This port has no real listener — purple_fb_server pre-created it
     * as a dummy. SpringBoard's BKSSystemApplicationClient sends:
     *   - messageType=5 (ping): expects any valid XPC dict reply
     *   - messageType=1 (checkIn): expects reply with data migration signal
     * Without replies, SpringBoard blocks forever in FBSystemAppMain. */
    if (is_sas && message) {
        int64_t msgType = xpc_dictionary_get_int64(message, "BKSSystemApplicationMessageKeyMessageType");
        sb_log("SAS_INTERCEPT: conn=%p msgType=%lld (5=ping, 1=checkIn)", (void *)conn, msgType);

        /* Return a synthetic reply — empty dict signals "success" for both ping and checkIn */
        xpc_object_t synthetic = xpc_dictionary_create(NULL, NULL, 0);
        if (msgType == 1) {
            /* checkIn reply: include data migration completed flag.
             * BKSSystemApplicationClient checks for this to unblock
             * checkInAndWaitForDataMigration's dispatch_semaphore. */
            xpc_dictionary_set_int64(synthetic, "BKSSystemApplicationMessageKeyMessageType", 1);
        }
        sb_log("SAS_INTERCEPT: returning synthetic reply for msgType=%lld", msgType);
        return synthetic;
    }

    /* Call real function via dlsym(RTLD_NEXT) */
    static xpc_object_t (*real_send_sync)(xpc_connection_t, xpc_object_t) = NULL;
    if (!real_send_sync) {
        real_send_sync = dlsym(RTLD_NEXT, "xpc_connection_send_message_with_reply_sync");
    }
    xpc_object_t reply = real_send_sync ? real_send_sync(conn, message) : NULL;

    if (is_pi) {
        sb_log("BKS_SEND_SYNC REPLY: conn=%p reply=%p (NULL=%s)",
               (void *)conn, (void *)reply, reply ? "NO" : "YES");
    }

    return reply;
}

static void install_bks_bootstrap_swizzle(void) {
    /* Delay until BKSProcess class is loaded */
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        for (int i = 0; i < 200; i++) {
            if (g_bks_bootstrap_logged) return;
            Class cls = objc_getClass("BKSProcess");
            if (cls) {
                SEL sel = sel_registerName("_bootstrapWithError:");
                Method m = class_getInstanceMethod(cls, sel);
                if (m) {
                    g_orig_bks_bootstrapWithError = method_getImplementation(m);
                    method_setImplementation(m, (IMP)replacement_bks_bootstrapWithError);
                    g_bks_bootstrap_logged = 1;
                    sb_log("BKS_BOOTSTRAP: swizzled -[BKSProcess _bootstrapWithError:]");
                    return;
                }
            }
            usleep(50000);
        }
        sb_log("BKS_BOOTSTRAP: FAILED to install swizzle (BKSProcess not found after 10s)");
    });
}

/* ================================================================
 * BSDeserialize ProcessHandle fix
 *
 * When assertiond's reply lacks BKSProcessInfoServiceMessageKeyProcessHandle,
 * synthesize a BSProcessHandle for SpringBoard's own PID so the bootstrap
 * succeeds. This is the minimal intervention to unblock the lifecycle.
 * ================================================================ */
extern id BSDeserializeBSXPCEncodableObjectFromXPCDictionaryWithKey(
    xpc_object_t dict, id key);
extern const char *xpc_dictionary_get_string(xpc_object_t dict, const char *key);

static id replacement_BSDeserialize(xpc_object_t dict, id key) {
    /* Call real function first — only intervene if it returns nil */
    static id (*real_fn)(xpc_object_t, id) = NULL;
    if (!real_fn) {
        real_fn = dlsym(RTLD_NEXT, "BSDeserializeBSXPCEncodableObjectFromXPCDictionaryWithKey");
    }
    id result = real_fn ? real_fn(dict, key) : nil;

    /* If result is nil AND we're inside _bootstrapWithError AND the result
     * would be a BSProcessHandle type, inject one.
     * We detect the ProcessHandle call by checking if the result's expected
     * class is BSProcessHandle — if real_fn returned nil and we're in
     * bootstrap, try to synthesize a handle. */
    if (!result && g_bks_bootstrap_in_progress) {
        /* Nil deserialization during bootstrap. Always try to inject a
         * BSProcessHandle. If this was actually the Error key (1st call),
         * the caller checks [result isKindOfClass:[NSError class]] and
         * ignores it. If it's the ProcessHandle key (2nd call), this
         * is exactly what's needed. Safe either way. */
        {
            /* Synthesize a BSProcessHandle for the current process */
            Class handleClass = objc_getClass("BSProcessHandle");
            if (handleClass) {
                SEL pidSel = sel_registerName("processHandleForPID:");
                result = ((id(*)(id, SEL, int))objc_msgSend)(
                    (id)handleClass, pidSel, getpid());
                if (result) {
                    sb_log("HANDLE_FIX: synthesized BSProcessHandle=%p for pid=%d",
                           (void *)result, getpid());
                } else {
                    sb_log("HANDLE_FIX: processHandleForPID:%d returned nil", getpid());
                }
            } else {
                sb_log("HANDLE_FIX: BSProcessHandle class not found");
            }
        }
    }

    return result;
}

/* ================================================================
 * NSLog interpose — capture return address when "Bootstrap failed" is logged.
 * This tells us which of the two NSLog sites in _bootstrapWithError: fires
 * (0x5c89 vs 0x5d2a in AssertionServices x86_64).
 * ================================================================ */
#include <execinfo.h>

extern void NSLog(id format, ...);
typedef void (*NSLog_fn)(id format, ...);

static void replacement_NSLog(id format, ...) {
    /* Check if this is the "Bootstrap failed" log */
    const char *fmt_str = NULL;
    if (format) {
        fmt_str = ((const char *(*)(id, SEL))objc_msgSend)(
            format, sel_registerName("UTF8String"));
    }

    int is_bootstrap_fail = (fmt_str && strstr(fmt_str, "Bootstrap failed"));

    if (is_bootstrap_fail) {
        void *ret_addr = __builtin_return_address(0);
        void *bt[8];
        int n = backtrace(bt, 8);
        sb_log("NSLOG_TRAP: 'Bootstrap failed' from ret_addr=%p", ret_addr);
        for (int i = 0; i < n; i++) {
            Dl_info info;
            if (dladdr(bt[i], &info)) {
                sb_log("  bt[%d]: %p %s + %ld (%s)",
                       i, bt[i], info.dli_sname ? info.dli_sname : "?",
                       (long)((char *)bt[i] - (char *)info.dli_saddr),
                       info.dli_fname ? strrchr(info.dli_fname, '/') + 1 : "?");
            } else {
                sb_log("  bt[%d]: %p (no dladdr)", i, bt[i]);
            }
        }
    }

    /* Forward to real NSLog via dlsym */
    static NSLog_fn real_nslog = NULL;
    if (!real_nslog) {
        real_nslog = (NSLog_fn)dlsym(RTLD_NEXT, "NSLog");
    }
    if (real_nslog) {
        va_list ap;
        va_start(ap, format);
        /* NSLog doesn't have a va_list variant easily accessible.
         * Use NSLogv instead: */
        extern void NSLogv(id format, va_list args);
        typedef void (*NSLogv_fn)(id, va_list);
        static NSLogv_fn real_nslogv = NULL;
        if (!real_nslogv) real_nslogv = (NSLogv_fn)dlsym(RTLD_NEXT, "NSLogv");
        if (real_nslogv) real_nslogv(format, ap);
        va_end(ap);
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
    { (const void *)replacement_xpc_connection_resume,
      (const void *)xpc_connection_resume },
    { (const void *)replacement_xpc_send_sync,
      (const void *)xpc_connection_send_message_with_reply_sync },
    { (const void *)replacement_NSLog,
      (const void *)NSLog },
    { (const void *)replacement_BSDeserialize,
      (const void *)BSDeserializeBSXPCEncodableObjectFromXPCDictionaryWithKey },
};

/* ================================================================
 * NSAssertionHandler suppression (diagnostic — log instead of abort)
 *
 * SpringBoard init hits various assertions in our minimal env.
 * We keep assertion suppression as a safety net but the primary fix
 * for step 12 is the FBApplicationLibrary swizzle below.
 * ================================================================ */

static IMP g_orig_handleFailureInMethod = NULL;
static IMP g_orig_handleFailureInFunction = NULL;

static void replacement_handleFailureInMethod(id self, SEL _cmd,
    SEL method, id object, id file, NSInteger line, id desc, ...) {
    const char *method_name = method ? sel_getName(method) : "?";
    const char *file_str = "?";
    if (file)
        file_str = ((const char *(*)(id, SEL))objc_msgSend)(file, sel_registerName("UTF8String"));
    const char *desc_str = desc ?
        ((const char *(*)(id, SEL))objc_msgSend)(desc, sel_registerName("UTF8String")) : "?";
    sb_log("ASSERT_SUPPRESSED [method] -%s in %s:%ld: %s",
           method_name, file_str, (long)line, desc_str);
}

static void replacement_handleFailureInFunction(id self, SEL _cmd,
    id function, id file, NSInteger line, id desc, ...) {
    const char *func_str = function ?
        ((const char *(*)(id, SEL))objc_msgSend)(function, sel_registerName("UTF8String")) : "?";
    const char *file_str = file ?
        ((const char *(*)(id, SEL))objc_msgSend)(file, sel_registerName("UTF8String")) : "?";
    const char *desc_str = desc ?
        ((const char *(*)(id, SEL))objc_msgSend)(desc, sel_registerName("UTF8String")) : "?";
    sb_log("ASSERT_SUPPRESSED [function] %s in %s:%ld: %s",
           func_str, file_str, (long)line, desc_str);
}

static void install_assertion_suppression(void) {
    Class cls = objc_getClass("NSAssertionHandler");
    if (!cls) { sb_log("ASSERT: NSAssertionHandler class not found"); return; }

    SEL methodSel = sel_registerName("handleFailureInMethod:object:file:lineNumber:description:");
    Method m = class_getInstanceMethod(cls, methodSel);
    if (m) {
        g_orig_handleFailureInMethod = method_setImplementation(m, (IMP)replacement_handleFailureInMethod);
        sb_log("ASSERT: swizzled handleFailureInMethod");
    }

    SEL funcSel = sel_registerName("handleFailureInFunction:file:lineNumber:description:");
    Method m2 = class_getInstanceMethod(cls, funcSel);
    if (m2) {
        g_orig_handleFailureInFunction = method_setImplementation(m2, (IMP)replacement_handleFailureInFunction);
        sb_log("ASSERT: swizzled handleFailureInFunction");
    }
}

/* ================================================================
 * FBApplicationLibrary — empty app catalog
 *
 * Step 12 of FBSystemAppMain calls [FBSystemApp sharedApplicationLibrary]
 * which inits FBApplicationLibrary and calls _load, enumerating apps
 * via LSApplicationWorkspace. In our minimal env, this returns nil
 * proxies → assertions → NSException (nil URL).
 *
 * Fix: swizzle _load to no-op and allInstalledApplications to return @[].
 * This lets SB proceed past step 12 without touching LaunchServices.
 * ================================================================ */

static IMP g_orig_fb_applib_load = NULL;
static IMP g_orig_fb_applib_allInstalled = NULL;

/* Replacement for -[FBApplicationLibrary _load] — no-op */
static void replacement_fb_applib_load(id self, SEL _cmd) {
    sb_log("FB_APPLIB: _load intercepted — returning empty (no app enumeration)");
    /* Don't call original — it would enumerate LSApplicationWorkspace */
}

/* Replacement for -[FBApplicationLibrary allInstalledApplications] — return @[] */
static id replacement_fb_applib_allInstalled(id self, SEL _cmd) {
    sb_log("FB_APPLIB: allInstalledApplications → empty array");
    return ((id(*)(id, SEL))objc_msgSend)(
        (id)objc_getClass("NSArray"), sel_registerName("array"));
}

static void install_fb_applib_swizzle(void) {
    /* Try synchronously first — FrontBoard may already be loaded */
    Class cls = objc_getClass("FBApplicationLibrary");
    if (!cls) {
        /* Force-load FrontBoard framework so the class is available */
        void *fb = dlopen("/System/Library/PrivateFrameworks/FrontBoard.framework/FrontBoard", RTLD_LAZY);
        if (fb) sb_log("FB_APPLIB: force-loaded FrontBoard");
        cls = objc_getClass("FBApplicationLibrary");
    }
    if (!cls) {
        /* Fall back to async polling if still not available */
        sb_log("FB_APPLIB: class not available yet, deferring to async poll");
        dispatch_async(dispatch_get_global_queue(0, 0), ^{
            for (int i = 0; i < 200; i++) {
                Class c = objc_getClass("FBApplicationLibrary");
                if (c) {
                    SEL loadSel = sel_registerName("_load");
                    Method loadM = class_getInstanceMethod(c, loadSel);
                    if (loadM) {
                        g_orig_fb_applib_load = method_setImplementation(loadM, (IMP)replacement_fb_applib_load);
                        sb_log("FB_APPLIB: swizzled _load (async)");
                    }
                    SEL allSel = sel_registerName("allInstalledApplications");
                    Method allM = class_getInstanceMethod(c, allSel);
                    if (allM) {
                        g_orig_fb_applib_allInstalled = method_setImplementation(allM, (IMP)replacement_fb_applib_allInstalled);
                        sb_log("FB_APPLIB: swizzled allInstalledApplications (async)");
                    }
                    return;
                }
                usleep(50000);
            }
            sb_log("FB_APPLIB: FAILED — class not found after 10s");
        });
        return;
    }

    /* Synchronous install */
    SEL loadSel = sel_registerName("_load");
    Method loadM = class_getInstanceMethod(cls, loadSel);
    if (loadM) {
        g_orig_fb_applib_load = method_setImplementation(loadM, (IMP)replacement_fb_applib_load);
        sb_log("FB_APPLIB: swizzled _load (sync)");
    }

    SEL allSel = sel_registerName("allInstalledApplications");
    Method allM = class_getInstanceMethod(cls, allSel);
    if (allM) {
        g_orig_fb_applib_allInstalled = method_setImplementation(allM, (IMP)replacement_fb_applib_allInstalled);
        sb_log("FB_APPLIB: swizzled allInstalledApplications (sync)");
    }
}

/* ================================================================
 * UIApplication._fetchInfoPlistFlags crash fix
 *
 * SpringBoard's UIApplication init calls _fetchInfoPlistFlags which
 * calls xpc_copy_bootstrap() — a private libxpc function that tries
 * to get the bootstrap dictionary from launchd. In our environment
 * this segfaults because we're not running under real launchd.
 *
 * Fix: swizzle _fetchInfoPlistFlags to skip when bundle info is nil.
 * Same approach as rosettasim_bridge.m uses for the app process.
 * ================================================================ */

static IMP g_orig_fetchInfoPlistFlags = NULL;

static void replacement_fetchInfoPlistFlags(id self, SEL _cmd) {
    /* Check if main bundle has an info dictionary. If not, skip to
     * avoid the xpc_copy_bootstrap crash. For SpringBoard, the main
     * bundle is the SpringBoard.app bundle. */
    id mainBundle = ((id(*)(id, SEL))objc_msgSend)(
        (id)objc_getClass("NSBundle"), sel_registerName("mainBundle"));
    id info = mainBundle ?
        ((id(*)(id, SEL))objc_msgSend)(mainBundle, sel_registerName("infoDictionary")) : NULL;

    if (!info) {
        sb_log("FETCHINFO: _fetchInfoPlistFlags skipped — no infoDictionary");
        return;
    }

    /* infoDictionary exists — try calling original but guard against crash */
    if (g_orig_fetchInfoPlistFlags) {
        sb_log("FETCHINFO: _fetchInfoPlistFlags calling original");
        ((void(*)(id, SEL))g_orig_fetchInfoPlistFlags)(self, _cmd);
    }
}

static void install_fetchinfo_swizzle(void) {
    /* Try synchronous first — UIKit should be loaded by SpringBoard */
    Class cls = objc_getClass("UIApplication");
    if (!cls) {
        /* Force-load UIKit */
        void *uikit = dlopen("/System/Library/Frameworks/UIKit.framework/UIKit", RTLD_LAZY);
        if (uikit) sb_log("FETCHINFO: force-loaded UIKit");
        cls = objc_getClass("UIApplication");
    }
    if (cls) {
        SEL sel = sel_registerName("_fetchInfoPlistFlags");
        Method m = class_getInstanceMethod(cls, sel);
        if (m) {
            g_orig_fetchInfoPlistFlags = method_setImplementation(m, (IMP)replacement_fetchInfoPlistFlags);
            sb_log("FETCHINFO: swizzled UIApplication._fetchInfoPlistFlags (sync)");
            return;
        }
    }
    /* Fallback: async poll */
    sb_log("FETCHINFO: UIApplication not available yet, deferring");
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        for (int i = 0; i < 200; i++) {
            Class c = objc_getClass("UIApplication");
            if (c) {
                SEL s = sel_registerName("_fetchInfoPlistFlags");
                Method mt = class_getInstanceMethod(c, s);
                if (mt) {
                    g_orig_fetchInfoPlistFlags = method_setImplementation(mt, (IMP)replacement_fetchInfoPlistFlags);
                    sb_log("FETCHINFO: swizzled (async)");
                    return;
                }
            }
            usleep(50000);
        }
        sb_log("FETCHINFO: FAILED — not found after 10s");
    });
}

/* Constructor — runs before SpringBoard's main */
__attribute__((constructor))
static void sb_shim_init(void) {
    sb_log("SpringBoard shim loaded (PID %d)", getpid());
    init_broker_port();
    install_assertion_suppression();
    install_fb_applib_swizzle();
    install_fetchinfo_swizzle();
    install_bks_bootstrap_swizzle();
}
