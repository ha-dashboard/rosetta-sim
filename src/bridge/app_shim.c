/*
 * app_shim.c — DYLD_INSERT_LIBRARIES shim for iOS app processes
 *
 * This library is injected into iOS app binaries launched by the
 * rosettasim broker. It communicates with the broker to obtain
 * Mach service ports (especially CARenderServer) that the app's
 * UIKit/CoreAnimation frameworks need.
 *
 * How it works:
 * 1. Constructor runs before app's main()
 * 2. Gets broker port from TASK_BOOTSTRAP_PORT (set by broker via posix_spawn)
 * 3. Requests service ports from broker (BROKER_LOOKUP_PORT msg_id=701)
 * 4. Interposes bootstrap_look_up to return cached ports
 * 5. App's CoreAnimation connects to CARenderServer transparently
 *
 * Build: compiled as x86_64 against iOS 10.3 simulator SDK
 */

#include <mach/mach.h>
#include <mach/vm_map.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <stdarg.h>
#include <mach/ndr.h>

/* Forward declarations */
extern mach_port_t bootstrap_port;
extern kern_return_t bootstrap_look_up(mach_port_t, const char *, mach_port_t *);
extern kern_return_t bootstrap_register(mach_port_t, const char *, mach_port_t);
extern kern_return_t bootstrap_check_in(mach_port_t, const char *, mach_port_t *);
extern kern_return_t task_get_special_port(mach_port_t, int, mach_port_t *);
#define TASK_BOOTSTRAP_PORT 4

/* Broker protocol message IDs */
#define BROKER_REGISTER_PORT_ID  700
#define BROKER_LOOKUP_PORT_ID    701

#define APP_SHIM_LOG_PREFIX "[AppShim] "
#define MAX_CACHED_SERVICES 32

/* ================================================================
 * Globals
 * ================================================================ */

static mach_port_t g_broker_port = MACH_PORT_NULL;

/* Cached service ports obtained from broker */
static struct {
    char name[128];
    mach_port_t port;
} g_cached_services[MAX_CACHED_SERVICES];
static int g_cached_count = 0;

/* ================================================================
 * Logging — uses write() to avoid iOS SDK buffering issues
 * ================================================================ */

static char _app_logbuf[4096];
static void app_log(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    char *p = _app_logbuf;
    int remaining = sizeof(_app_logbuf);

    int n = snprintf(p, remaining, APP_SHIM_LOG_PREFIX);
    p += n; remaining -= n;

    n = vsnprintf(p, remaining, fmt, ap);
    p += n; remaining -= n;
    va_end(ap);

    n = snprintf(p, remaining, "\n");
    p += n;

    write(STDERR_FILENO, _app_logbuf, (size_t)(p - _app_logbuf));
}

/* ================================================================
 * Broker communication
 * ================================================================ */

/*
 * Request a service port from the broker via BROKER_LOOKUP_PORT (msg_id=701)
 *
 * Request (simple message):
 *   header(24) + NDR(8) + name_len:uint32(4) + name:char[128]
 *   Must match bootstrap_simple_request_t in rosettasim_broker.c
 *
 * Reply (complex, on success):
 *   header(24) + body(4) + port_descriptor(12)
 *
 * Reply (simple, on failure):
 *   header(24) + NDR(8) + ret_code(4)
 */
static mach_port_t app_broker_lookup(const char *name) {
    if (g_broker_port == MACH_PORT_NULL || !name) return MACH_PORT_NULL;

    /* Create reply port */
    mach_port_t reply_port;
    kern_return_t kr = mach_port_allocate(mach_task_self(),
                                           MACH_PORT_RIGHT_RECEIVE, &reply_port);
    if (kr != KERN_SUCCESS) return MACH_PORT_NULL;

    /* Build request — matches bootstrap_simple_request_t in broker */
    union {
        struct {
            mach_msg_header_t header;
            NDR_record_t ndr;
            uint32_t name_len;
            char name[128];
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
    buf.req.header.msgh_id = BROKER_LOOKUP_PORT_ID;
    buf.req.ndr = NDR_record;
    buf.req.name_len = name_len;
    memcpy(buf.req.name, name, name_len);

    /* Send and receive */
    kr = mach_msg(&buf.req.header,
                   MACH_SEND_MSG | MACH_RCV_MSG | MACH_RCV_TIMEOUT,
                   sizeof(buf.req),
                   sizeof(buf),
                   reply_port,
                   5000,  /* 5 second timeout */
                   MACH_PORT_NULL);

    mach_port_deallocate(mach_task_self(), reply_port);

    if (kr != KERN_SUCCESS) {
        app_log("broker lookup '%s': mach_msg failed: %s (%d)",
                name, mach_error_string(kr), kr);
        return MACH_PORT_NULL;
    }

    mach_msg_header_t *rh = (mach_msg_header_t *)buf.raw;

    /* Check for complex reply (success — contains port) */
    if (rh->msgh_bits & MACH_MSGH_BITS_COMPLEX) {
        mach_msg_body_t *body = (mach_msg_body_t *)(buf.raw + sizeof(mach_msg_header_t));
        if (body->msgh_descriptor_count >= 1) {
            mach_msg_port_descriptor_t *pd = (mach_msg_port_descriptor_t *)(body + 1);
            app_log("broker lookup '%s': found port=%u", name, pd->name);
            return pd->name;
        }
    }

    /* Non-complex: error */
    app_log("broker lookup '%s': not found", name);
    return MACH_PORT_NULL;
}

/* Cache a service port */
static void app_cache_service(const char *name, mach_port_t port) {
    if (g_cached_count >= MAX_CACHED_SERVICES) return;
    strncpy(g_cached_services[g_cached_count].name, name, 127);
    g_cached_services[g_cached_count].name[127] = 0;
    g_cached_services[g_cached_count].port = port;
    g_cached_count++;
}

/* Look up a cached service */
static mach_port_t app_find_cached(const char *name) {
    for (int i = 0; i < g_cached_count; i++) {
        if (strcmp(g_cached_services[i].name, name) == 0) {
            return g_cached_services[i].port;
        }
    }
    return MACH_PORT_NULL;
}

/* ================================================================
 * DYLD interpositions — intercept bootstrap calls
 * ================================================================ */

kern_return_t app_bootstrap_look_up(mach_port_t bp, const char *name, mach_port_t *sp) {
    if (!name || !sp) {
        return bootstrap_look_up(bp, name, sp);
    }

    /* Check cache first */
    mach_port_t cached = app_find_cached(name);
    if (cached != MACH_PORT_NULL) {
        *sp = cached;
        app_log("bootstrap_look_up('%s') → cached port %u", name, *sp);
        return KERN_SUCCESS;
    }

    /* Ask the broker */
    mach_port_t port = app_broker_lookup(name);
    if (port != MACH_PORT_NULL) {
        app_cache_service(name, port);
        *sp = port;
        app_log("bootstrap_look_up('%s') → broker port %u", name, *sp);
        return KERN_SUCCESS;
    }

    /* Fall through to real bootstrap_look_up (goes to broker via TASK_BOOTSTRAP_PORT) */
    kern_return_t kr = bootstrap_look_up(bp, name, sp);
    app_log("bootstrap_look_up('%s') → %s (%d) port=%u",
            name, kr == KERN_SUCCESS ? "OK" : "FAILED", kr,
            (kr == KERN_SUCCESS && sp) ? *sp : 0);
    return kr;
}

kern_return_t app_bootstrap_register(mach_port_t bp, const char *name, mach_port_t sp) {
    app_log("bootstrap_register('%s', port=%u)", name ? name : "(null)", sp);
    /* Forward to real (goes to broker) */
    kern_return_t kr = bootstrap_register(bp, name, sp);
    app_log("  → %s (%d)", kr == KERN_SUCCESS ? "OK" : "FAILED", kr);
    return kr;
}

kern_return_t app_bootstrap_check_in(mach_port_t bp, const char *name, mach_port_t *sp) {
    app_log("bootstrap_check_in('%s')", name ? name : "(null)");
    /* Forward to real (goes to broker) */
    kern_return_t kr = bootstrap_check_in(bp, name, sp);
    app_log("  → %s (%d) port=%u",
            kr == KERN_SUCCESS ? "OK" : "FAILED", kr,
            (kr == KERN_SUCCESS && sp) ? *sp : 0);
    return kr;
}

/* Suppress abort during app init (same approach as purple_fb_server.c) */
#include <execinfo.h>
extern void abort(void);
static volatile int g_app_suppress_abort = 1;

void app_abort(void) {
    app_log("abort() called!");
    void *frames[10];
    int n = backtrace(frames, 10);
    char **syms = backtrace_symbols(frames, n);
    if (syms) {
        for (int i = 0; i < n && i < 5; i++) {
            app_log("  %s", syms[i]);
        }
        free(syms);
    }
    if (g_app_suppress_abort) {
        app_log("SUPPRESSING abort()");
        return;
    }
    abort();
}

/* Suppress ObjC exceptions during init */
extern void objc_exception_throw(void *exception);

void app_objc_exception_throw(void *exception) {
    app_log("Exception thrown: %p", exception);
    if (g_app_suppress_abort) {
        app_log("SUPPRESSING exception");
        return;
    }
    objc_exception_throw(exception);
}

/* ================================================================
 * Interposition table
 * ================================================================ */

__attribute__((used, section("__DATA,__interpose")))
static struct {
    void *replacement;
    void *original;
} app_interpositions[] = {
    { (void *)app_bootstrap_look_up, (void *)bootstrap_look_up },
    { (void *)app_bootstrap_register, (void *)bootstrap_register },
    { (void *)app_bootstrap_check_in, (void *)bootstrap_check_in },
    { (void *)app_abort, (void *)abort },
    { (void *)app_objc_exception_throw, (void *)objc_exception_throw },
};

/* ================================================================
 * Constructor — runs before app's main()
 * ================================================================ */

__attribute__((constructor))
static void app_shim_init(void) {
    app_log("Initializing app shim (PID=%d)", getpid());

    /* Get broker port from TASK_BOOTSTRAP_PORT (set by broker via posix_spawn) */
    kern_return_t kr = task_get_special_port(mach_task_self(),
                                              TASK_BOOTSTRAP_PORT, &g_broker_port);
    if (kr == KERN_SUCCESS && g_broker_port != MACH_PORT_NULL) {
        app_log("Broker port: %u (from TASK_BOOTSTRAP_PORT)", g_broker_port);
        /* Set the global so iOS SDK bootstrap calls go through our broker */
        bootstrap_port = g_broker_port;
    } else {
        app_log("WARNING: No broker port (kr=%d). Bootstrap services unavailable.", kr);
    }

    /* Pre-fetch critical service ports from the broker */
    const char *critical_services[] = {
        "com.apple.CARenderServer",
        "com.apple.iohideventsystem",
        NULL
    };

    for (int i = 0; critical_services[i] != NULL; i++) {
        mach_port_t port = app_broker_lookup(critical_services[i]);
        if (port != MACH_PORT_NULL) {
            app_cache_service(critical_services[i], port);
            app_log("Pre-fetched '%s' → port %u", critical_services[i], port);
        } else {
            app_log("Service '%s' not yet available (will retry on demand)",
                    critical_services[i]);
        }
    }

    app_log("App shim ready — %d services cached", g_cached_count);
}

/* ================================================================
 * Destructor
 * ================================================================ */

__attribute__((destructor))
static void app_shim_cleanup(void) {
    app_log("Cleaning up");
}
