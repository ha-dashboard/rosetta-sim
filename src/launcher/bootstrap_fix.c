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
#include <pthread.h>
#include <objc/runtime.h>
#include <objc/message.h>
#import <Foundation/Foundation.h>
#include <dispatch/dispatch.h>
#include <mach-o/dyld.h>
#include <mach-o/nlist.h>
#include <mach-o/loader.h>

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

/* Track processinfoservice receive port for diagnostic probing.
 * Set when assertiond checks in for com.apple.assertiond.processinfoservice
 * via the MIG check_in path. If the XPC pipe check_in (routine=805)
 * delivers the port instead, this stays NULL. */
static mach_port_t g_processinfoservice_port = MACH_PORT_NULL;
static int g_is_assertiond = 0; /* set in constructor if process is assertiond */

/* Forward declarations for functions defined later */
static mach_port_t get_bootstrap_port(void);
kern_return_t replacement_bootstrap_check_in(mach_port_t bp,
                                              const name_t service_name,
                                              mach_port_t *service_port);

/* ================================================================
 * MobileGestalt stub (ROSETTASIM_MG_STUB=1)
 *
 * Interposes MGCopyAnswer, MGCopyAnswerWithError, and MGGetBoolAnswer
 * to bypass the NSXPC path to com.apple.mobilegestalt.xpc which returns
 * corrupted replies in our environment. Returns sane iPhone simulator
 * defaults for common keys; NULL/false for unknown keys.
 * ================================================================ */
#include <CoreFoundation/CoreFoundation.h>

/* Original function pointers (saved before trampoline) */
typedef CFPropertyListRef (*MGCopyAnswer_fn)(CFStringRef key);
typedef CFPropertyListRef (*MGCopyAnswerWithError_fn)(CFStringRef key, void *unused, int *err);
typedef int (*MGGetBoolAnswer_fn)(CFStringRef key);

static MGCopyAnswer_fn g_orig_MGCopyAnswer = NULL;
static int g_mg_stub_active = 0;
static int g_mg_log_count = 0;

/* Rate-limited key logger — logs first 50 unique keys */
static void mg_log_key(const char *func, CFStringRef key) {
    if (g_mg_log_count >= 50) return;
    char buf[256] = {0};
    if (key) CFStringGetCString(key, buf, sizeof(buf), kCFStringEncodingUTF8);
    bfix_log("[bfix] MG_STUB %s('%s')\n", func, buf);
    g_mg_log_count++;
}

static CFPropertyListRef replacement_MGCopyAnswer(CFStringRef key) {
    if (!g_mg_stub_active || !key) {
        return g_orig_MGCopyAnswer ? g_orig_MGCopyAnswer(key) : NULL;
    }
    mg_log_key("MGCopyAnswer", key);

    /* Common simulator defaults (iPhone 6s / iPhone8,1) */
    if (CFStringCompare(key, CFSTR("ProductType"), 0) == 0)
        return CFRetain(CFSTR("iPhone8,1"));
    if (CFStringCompare(key, CFSTR("HWModelStr"), 0) == 0)
        return CFRetain(CFSTR("N71AP"));
    if (CFStringCompare(key, CFSTR("DeviceClassNumber"), 0) == 0)
        return CFRetain((__bridge CFTypeRef)@(1)); /* 1 = iPhone */
    if (CFStringCompare(key, CFSTR("DeviceClass"), 0) == 0)
        return CFRetain(CFSTR("iPhone"));
    if (CFStringCompare(key, CFSTR("DeviceName"), 0) == 0)
        return CFRetain(CFSTR("iPhone"));
    if (CFStringCompare(key, CFSTR("UserAssignedDeviceName"), 0) == 0)
        return CFRetain(CFSTR("RosettaSim iPhone"));
    if (CFStringCompare(key, CFSTR("BuildVersion"), 0) == 0)
        return CFRetain(CFSTR("14E8301"));
    if (CFStringCompare(key, CFSTR("ProductVersion"), 0) == 0)
        return CFRetain(CFSTR("10.3.1"));
    if (CFStringCompare(key, CFSTR("UniqueDeviceID"), 0) == 0)
        return CFRetain(CFSTR("ROSETTASIM-0000-0000-0000-000000000000"));
    if (CFStringCompare(key, CFSTR("ComputerName"), 0) == 0)
        return CFRetain(CFSTR("RosettaSim"));
    if (CFStringCompare(key, CFSTR("DeviceSupportsNavigationUI"), 0) == 0)
        return CFRetain(kCFBooleanTrue);
    if (CFStringCompare(key, CFSTR("DeviceSupports3DMaps"), 0) == 0)
        return CFRetain(kCFBooleanTrue);
    if (CFStringCompare(key, CFSTR("ArtworkTraits"), 0) == 0)
        return NULL; /* complex — skip */

    /* For unknown keys, return NULL (not found) rather than calling
     * the real function which would hit the broken NSXPC path. */
    return NULL;
}

static CFPropertyListRef replacement_MGCopyAnswerWithError(
    CFStringRef key, void *unused, int *err) {
    if (!g_mg_stub_active) return NULL;
    /* Delegate to MGCopyAnswer stub (ignore unused). */
    (void)unused;
    if (err) *err = 0;
    return replacement_MGCopyAnswer(key);
}

static int replacement_MGGetBoolAnswer(CFStringRef key) {
    if (!g_mg_stub_active || !key) return 0;
    mg_log_key("MGGetBoolAnswer", key);

    /* Common boolean queries */
    if (CFStringCompare(key, CFSTR("HasBaseband"), 0) == 0) return 0;
    if (CFStringCompare(key, CFSTR("IsSimulator"), 0) == 0) return 1;
    if (CFStringCompare(key, CFSTR("IsClassic"), 0) == 0) return 0;
    if (CFStringCompare(key, CFSTR("SupportsForceTouch"), 0) == 0) return 1;
    if (CFStringCompare(key, CFSTR("DeviceSupportsNavigation"), 0) == 0) return 1;
    if (CFStringCompare(key, CFSTR("DeviceSupports1080p"), 0) == 0) return 1;
    if (CFStringCompare(key, CFSTR("DeviceSupports720p"), 0) == 0) return 1;
    if (CFStringCompare(key, CFSTR("wifi"), 0) == 0) return 1;
    if (CFStringCompare(key, CFSTR("telephony"), 0) == 0) return 0;
    if (CFStringCompare(key, CFSTR("multitasking"), 0) == 0) return 1;
    if (CFStringCompare(key, CFSTR("opengles-2"), 0) == 0) return 1;
    if (CFStringCompare(key, CFSTR("armv7"), 0) == 0) return 1;
    if (CFStringCompare(key, CFSTR("accelerometer"), 0) == 0) return 1;
    if (CFStringCompare(key, CFSTR("gyroscope"), 0) == 0) return 1;
    if (CFStringCompare(key, CFSTR("magnetometer"), 0) == 0) return 1;
    if (CFStringCompare(key, CFSTR("camera-flash"), 0) == 0) return 1;
    if (CFStringCompare(key, CFSTR("front-facing-camera"), 0) == 0) return 1;
    if (CFStringCompare(key, CFSTR("auto-focus-camera"), 0) == 0) return 1;
    if (CFStringCompare(key, CFSTR("bluetooth"), 0) == 0) return 1;
    if (CFStringCompare(key, CFSTR("location-services"), 0) == 0) return 1;
    if (CFStringCompare(key, CFSTR("gps"), 0) == 0) return 1;
    if (CFStringCompare(key, CFSTR("microphone"), 0) == 0) return 1;

    /* Unknown bool key — default false */
    return 0;
}

/* XPC public API declarations (from libxpc). */
typedef void *xpc_object_t;
typedef void *xpc_pipe_t;
extern xpc_object_t xpc_dictionary_create(const char * const *keys,
                                           const xpc_object_t *values,
                                           size_t count);
extern void xpc_dictionary_set_int64(xpc_object_t dict, const char *key, int64_t val);
extern void xpc_dictionary_set_mach_recv(xpc_object_t dict, const char *key, mach_port_t port);
extern void xpc_dictionary_set_mach_send(xpc_object_t dict, const char *key, mach_port_t port);
extern int64_t xpc_dictionary_get_int64(xpc_object_t dict, const char *key);
extern const char *xpc_dictionary_get_string(xpc_object_t dict, const char *key);
extern void xpc_release(xpc_object_t obj);

/* Original _xpc_pipe_routine saved here by trampoline setup.
 * Since we trampoline the code, calling the original by address is complex.
 * Instead, we handle routine=805 locally and let other routines fall through
 * by calling the ORIGINAL function via a saved pointer. */
typedef int (*xpc_pipe_routine_fn)(xpc_pipe_t pipe, xpc_object_t dict, xpc_object_t *reply);
static xpc_pipe_routine_fn g_orig_xpc_pipe_routine = NULL;

/* Replacement _xpc_pipe_routine for assertiond.
 *
 * For routine=805 (CheckIn): build the reply locally using libxpc's own
 * dictionary API. Get the service port from our MIG bootstrap_check_in.
 * This avoids the broken XPC pipe wire format entirely — libxpc creates
 * the XPC dict natively, so __xpc_serializer_unpack never runs.
 *
 * For all other routines: fall through to the real implementation. */
/* Cached recv ports from first check_in — used by FORCE_LISTENER */
static mach_port_t g_cached_workspace_recv = MACH_PORT_NULL;
static mach_port_t g_cached_sysappsvcs_recv = MACH_PORT_NULL;

static int replacement_xpc_pipe_routine(xpc_pipe_t pipe, xpc_object_t dict,
                                         xpc_object_t *reply) {
    int64_t routine = xpc_dictionary_get_int64(dict, "routine");

    if (routine == 805) {
        /* CheckIn — handle locally */
        const char *name = xpc_dictionary_get_string(dict, "name");
        int64_t handle = xpc_dictionary_get_int64(dict, "handle");

        if (!name) {
            bfix_log("[bfix] xpc_pipe_routine 805: no service name\n");
            if (reply) *reply = NULL;
            return 5; /* EIO */
        }

        /* Get the port from our MIG check_in path */
        mach_port_t svc_port = MACH_PORT_NULL;
        kern_return_t kr = replacement_bootstrap_check_in(
            get_bootstrap_port(), name, &svc_port);

        if (kr != KERN_SUCCESS || svc_port == MACH_PORT_NULL) {
            bfix_log("[bfix] xpc_pipe_routine 805 '%s': MIG check_in failed (kr=%d)\n",
                     name, kr);
            if (reply) *reply = NULL;
            return 5;
        }

        /* For workspace/systemappservices: cache the recv port and give
         * libxpc a send right. FORCE_LISTENER uses the cached recv port. */
        int is_ws = (strstr(name, "frontboard.workspace") ||
                     strstr(name, "frontboard.systemappservices"));

        if (is_ws) {
            /* svc_port is recv right from check_in. Add a send right too. */
            mach_port_insert_right(mach_task_self(), svc_port, svc_port,
                                    MACH_MSG_TYPE_MAKE_SEND);
            /* Cache recv for FORCE_LISTENER */
            if (strstr(name, "frontboard.workspace") &&
                !strstr(name, "systemappservices"))
                g_cached_workspace_recv = svc_port;
            else if (strstr(name, "systemappservices"))
                g_cached_sysappsvcs_recv = svc_port;

            bfix_log("[bfix] xpc_pipe_routine 805 '%s': CACHED recv 0x%x\n", name, svc_port);

            /* Give libxpc a send right (it just needs something valid) */
            xpc_object_t resp = xpc_dictionary_create(NULL, NULL, 0);
            xpc_dictionary_set_int64(resp, "subsystem", 3);
            xpc_dictionary_set_int64(resp, "error", 0);
            xpc_dictionary_set_int64(resp, "routine", 805);
            xpc_dictionary_set_int64(resp, "handle", handle);
            xpc_dictionary_set_mach_send(resp, "port", svc_port);
            if (reply) *reply = resp;
            return 0;
        }

        /* Non-workspace: normal flow with MOVE_RECEIVE */
        xpc_object_t resp = xpc_dictionary_create(NULL, NULL, 0);
        xpc_dictionary_set_int64(resp, "subsystem", 3);
        xpc_dictionary_set_int64(resp, "error", 0);
        xpc_dictionary_set_int64(resp, "routine", 805);
        xpc_dictionary_set_int64(resp, "handle", handle);
        xpc_dictionary_set_mach_recv(resp, "port", svc_port);

        if (reply) *reply = resp;
        bfix_log("[bfix] xpc_pipe_routine 805 '%s': LOCAL reply with port 0x%x\n",
                 name, svc_port);
        return 0;
    }

    /* Non-805: fall through to real implementation.
     * We can't easily call the original since we trampolined it.
     * For assertiond, the only pipe routines are 805 (CheckIn) and
     * 100 (GetJobs). GetJobs is handled by launch_msg interception.
     * Any other routine: return error. */
    bfix_log("[bfix] xpc_pipe_routine %lld: not handled (assertiond)\n", routine);
    if (reply) *reply = NULL;
    return 5; /* EIO */
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
static void bfix_remember_port_name(mach_port_t port, const char *name);
static const char *bfix_lookup_port_name(mach_port_t port);

/* Cached recv ports from first check_in — used by FORCE_LISTENER */
/* (cache declarations moved earlier, near replacement_xpc_pipe_routine) */

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
        bfix_remember_port_name(*service_port, service_name);
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

    bfix_log("[bfix] check_in('%s') via port 0x%x pid=%d proc=%s\n",
             service_name, real_bp, getpid(), getprogname() ? getprogname() : "?");

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
        bfix_remember_port_name(*service_port, service_name);
        /* Cache workspace/systemappservices recv ports for FORCE_LISTENER */
        if (strstr(service_name, "frontboard.workspace") &&
            !strstr(service_name, "systemappservices")) {
            g_cached_workspace_recv = *service_port;
            bfix_log("[bfix] CACHED workspace recv port 0x%x\n", *service_port);
        }
        if (strstr(service_name, "frontboard.systemappservices")) {
            g_cached_sysappsvcs_recv = *service_port;
            bfix_log("[bfix] CACHED systemappservices recv port 0x%x\n", *service_port);
        }
        /* Track processinfoservice port unconditionally (any process) */
        if (strstr(service_name, "processinfoservice")) {
            g_processinfoservice_port = *service_port;
            bfix_log("[bfix] *** TRACKING processinfoservice recv port 0x%x (is_assertiond=%d) ***\n",
                     *service_port, g_is_assertiond);
        }
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

/* CARenderServerGetClientPort interposition.
 *
 * Problem: CoreAnimation's internal connect_remote() populates a per-server
 * client port cache. Since we call RegisterClient manually (not through
 * connect_remote), the cache is empty and CARenderServerGetClientPort returns 0.
 * When UIKit checks this (cross-library call → CAN be interposed), it decides
 * to use LOCAL backing stores (vm_allocate) instead of IOSurface.
 *
 * Fix: Return a non-zero port when a CARenderServer connection exists.
 * The actual port value is stored by the bridge after RegisterClient succeeds. */
extern mach_port_t CARenderServerGetClientPort(mach_port_t server_port);

/* Shared state: set by the bridge after RegisterClient reply */
static mach_port_t g_bfix_client_port = MACH_PORT_NULL;

/* Called by the bridge to store the client port from RegisterClient reply */
void bfix_set_client_port(mach_port_t port) {
    g_bfix_client_port = port;
    bfix_log("[bfix] client port set to 0x%x\n", port);
}

/* GSGetPurpleApplicationPort interposition.
 *
 * UIKit's _createContextAttached: calls:
 *   [CAContext setClientPort:GSGetPurpleApplicationPort()];
 *   _layerContext = [CAContext remoteContextWithOptions:opts];
 *
 * If GSGetPurpleApplicationPort returns 0, setClientPort:0 makes connect_remote
 * fail, and no remote context is created. UIKit falls back to no rendering.
 *
 * Fix: Return a valid Mach port so connect_remote can establish the connection
 * to CARenderServer via the broker's bootstrap namespace. */
extern mach_port_t GSGetPurpleApplicationPort(void);

static mach_port_t g_purple_app_port = MACH_PORT_NULL;

static mach_port_t replacement_GSGetPurpleApplicationPort(void) {
    if (g_purple_app_port != MACH_PORT_NULL) {
        return g_purple_app_port;
    }

    /* Create a port for the app's Purple registration.
     * This is used by CAContext setClientPort: before connect_remote. */
    mach_port_t bp = get_bootstrap_port();
    if (bp != MACH_PORT_NULL) {
        mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &g_purple_app_port);
        if (g_purple_app_port != MACH_PORT_NULL) {
            mach_port_insert_right(mach_task_self(), g_purple_app_port,
                                    g_purple_app_port, MACH_MSG_TYPE_MAKE_SEND);
            bfix_log("[bfix] GSGetPurpleApplicationPort() → 0x%x (created)\n", g_purple_app_port);
            return g_purple_app_port;
        }
    }

    /* Not running under broker — return 0 (original behavior) */
    return GSGetPurpleApplicationPort();
}

/* launch_msg interposition.
 *
 * The XPC library uses launch_msg (NOT bootstrap_check_in) for service
 * check-in when creating LISTENER connections. launch_msg talks to launchd
 * which we don't have. We interpose it to handle "CheckIn" requests by
 * returning MachServices ports from our broker.
 *
 * launch_data_t is an opaque type. We use the public launch.h API to
 * create response objects. */
typedef void *launch_data_t;
extern launch_data_t launch_msg(launch_data_t);
extern launch_data_t launch_data_new_string(const char *);
extern launch_data_t launch_data_alloc(unsigned int);
extern launch_data_t launch_data_dict_lookup(launch_data_t, const char *);
extern int launch_data_get_type(launch_data_t);
extern const char *launch_data_get_string(launch_data_t);
extern mach_port_t launch_data_get_machport(launch_data_t);
extern launch_data_t launch_data_new_machport(mach_port_t);
extern void launch_data_dict_insert(launch_data_t, launch_data_t, const char *);
extern void launch_data_free(launch_data_t);
extern launch_data_t launch_data_new_bool(int);

#define LAUNCH_DATA_DICTIONARY 1
#define LAUNCH_DATA_ARRAY      2
#define LAUNCH_DATA_FD         3
#define LAUNCH_DATA_INTEGER    4
#define LAUNCH_DATA_REAL       5
#define LAUNCH_DATA_BOOL       6
#define LAUNCH_DATA_STRING     7
#define LAUNCH_DATA_OPAQUE     8
#define LAUNCH_DATA_ERRNO      9
#define LAUNCH_DATA_MACHPORT   10

#define LAUNCH_KEY_CHECKIN     "CheckIn"
#define LAUNCH_KEY_GETJOBS     "GetJobs"
#define LAUNCH_JOBKEY_LABEL    "Label"
#define LAUNCH_JOBKEY_MACHSERVICES "MachServices"

static launch_data_t replacement_launch_msg(launch_data_t msg) {
    int msg_type = msg ? launch_data_get_type(msg) : -1;
    const char *prog = getprogname();
    bfix_log("[bfix] launch_msg enter: type=%d process=%s\n",
             msg_type, prog ? prog : "unknown");

    /* Only intercept check-in requests */
    if (msg && launch_data_get_type(msg) == LAUNCH_DATA_STRING) {
        const char *cmd = launch_data_get_string(msg);
        if (cmd && strcmp(cmd, LAUNCH_KEY_CHECKIN) == 0) {
            const char *progname = getprogname();
            bfix_log("[bfix] launch_msg('CheckIn') intercepted (process: %s)\n",
                     progname ? progname : "unknown");

            /* Only check_in services that belong to THIS process.
             * In real launchd, each daemon's plist lists its MachServices.
             * launch_msg("CheckIn") returns only that daemon's services.
             * We emulate this by matching process name to service prefix. */
            static const char *assertiond_services[] = {
                "com.apple.assertiond.applicationstateconnection",
                "com.apple.assertiond.appwatchdog",
                "com.apple.assertiond.expiration",
                "com.apple.assertiond.processassertionconnection",
                "com.apple.assertiond.processinfoservice",
                NULL
            };
            static const char *frontboard_services[] = {
                "com.apple.frontboard.systemappservices",
                "com.apple.frontboard.workspace",
                NULL
            };

            const char **my_services = NULL;
            if (progname && strstr(progname, "assertiond")) {
                my_services = assertiond_services;
            } else if (progname && (strstr(progname, "SpringBoard") ||
                                     strstr(progname, "springboard"))) {
                my_services = frontboard_services;
            }

            if (!my_services) {
                bfix_log("[bfix] launch_msg CheckIn: no services for process '%s'\n",
                         progname ? progname : "unknown");
                /* Fall through to original — might be a process we don't know about */
                return launch_msg(msg);
            }

            /* Build check-in response with only this process's services */
            launch_data_t resp = launch_data_alloc(LAUNCH_DATA_DICTIONARY);
            launch_data_t mach_services = launch_data_alloc(LAUNCH_DATA_DICTIONARY);

            mach_port_t bp = get_bootstrap_port();
            int found = 0;
            for (int i = 0; my_services[i]; i++) {
                mach_port_t svc_port = MACH_PORT_NULL;
                kern_return_t kr = replacement_bootstrap_check_in(bp, my_services[i], &svc_port);
                if (kr == KERN_SUCCESS && svc_port != MACH_PORT_NULL) {
                    launch_data_t port_data = launch_data_new_machport(svc_port);
                    launch_data_dict_insert(mach_services, port_data, my_services[i]);
                    bfix_log("[bfix] launch_msg CheckIn: %s → port 0x%x\n", my_services[i], svc_port);
                    found++;
                }
            }

            if (found > 0) {
                launch_data_dict_insert(resp, mach_services, LAUNCH_JOBKEY_MACHSERVICES);
                bfix_log("[bfix] launch_msg CheckIn: returning %d services for %s\n",
                         found, progname);
                return resp;
            }

            launch_data_free(mach_services);
            launch_data_free(resp);
            bfix_log("[bfix] launch_msg CheckIn: no services found, falling through\n");
        }

    }

    /* Pass through to original for unhandled messages */
    return launch_msg(msg);
}

/* Forward declarations for interposition targets */
extern kern_return_t bootstrap_look_up(mach_port_t, const name_t, mach_port_t *);
extern kern_return_t bootstrap_check_in(mach_port_t, const name_t, mach_port_t *);
extern kern_return_t bootstrap_register(mach_port_t, const name_t, mach_port_t);
extern kern_return_t mach_msg(mach_msg_header_t *msg,
                               mach_msg_option_t option,
                               mach_msg_size_t send_size,
                               mach_msg_size_t rcv_size,
                               mach_port_name_t rcv_name,
                               mach_msg_timeout_t timeout,
                               mach_port_name_t notify);

static kern_return_t replacement_mach_msg(mach_msg_header_t *msg,
                                           mach_msg_option_t option,
                                           mach_msg_size_t send_size,
                                           mach_msg_size_t rcv_size,
                                           mach_port_name_t rcv_name,
                                           mach_msg_timeout_t timeout,
                                           mach_port_name_t notify);

/* DYLD interposition */
__attribute__((used))
static const struct {
    const void *replacement;
    const void *replacee;
} interpositions[] __attribute__((section("__DATA,__interpose"))) = {
    { (void *)replacement_mach_msg,            (void *)mach_msg },
    { (void *)replacement_bootstrap_look_up,   (void *)bootstrap_look_up },
    { (void *)replacement_bootstrap_check_in,  (void *)bootstrap_check_in },
    { (void *)replacement_bootstrap_register,  (void *)bootstrap_register },
    { (void *)replacement_GSGetPurpleApplicationPort, (void *)GSGetPurpleApplicationPort },
    { (void *)replacement_launch_msg,          (void *)launch_msg },
};

/* Find and patch the _user_client_port static variable inside CoreAnimation.
 *
 * CARenderServerGetClientPort is a C function in QuartzCore that reads a
 * static variable via a RIP-relative MOV. We disassemble the function to
 * find the variable's address and write to it directly. This works for
 * both intra-library and cross-library calls.
 *
 * Typical x86_64 pattern:
 *   mov eax, dword ptr [rip + offset]  ; 8B 05 xx xx xx xx
 *   ret                                 ; C3
 */
#include <dlfcn.h>
#include <mach/vm_map.h>
/* ================================================================
 * assertiond processinfoservice instrumentation
 *
 * Goal: determine whether assertiond receives and replies to SpringBoard's
 * bootstrap message (often "messageType=0") sent over
 * com.apple.assertiond.processinfoservice.
 *
 * We interpose mach_msg and:
 *   - observe XPC pipe routine=805 check-in requests (msg_id=0x10000000)
 *     to map handle -> service name
 *   - observe matching check-in replies (msg_id=0x20000000) to capture the
 *     local port name for com.apple.assertiond.processinfoservice
 *   - log any messages received on that port and whether a reply is sent
 * ================================================================ */

#define BFIX_XPC_MAGIC           0x58504321  /* "!CPX" */
#define BFIX_XPC_TYPE_BOOL       0x00002000
#define BFIX_XPC_TYPE_INT64      0x00003000
#define BFIX_XPC_TYPE_UINT64     0x00004000
#define BFIX_XPC_TYPE_STRING     0x00009000
#define BFIX_XPC_TYPE_MACH_SEND  0x0000d000
#define BFIX_XPC_TYPE_MACH_RECV  0x00015000
#define BFIX_XPC_TYPE_ARRAY      0x0000e000
#define BFIX_XPC_TYPE_DICT       0x0000f000

#define BFIX_XPC_LAUNCH_MSG_ID      0x10000000
#define BFIX_XPC_PIPE_REPLY_MSG_ID  0x20000000

typedef kern_return_t (*mach_msg_fn)(mach_msg_header_t *, mach_msg_option_t,
                                      mach_msg_size_t, mach_msg_size_t,
                                      mach_port_name_t, mach_msg_timeout_t,
                                      mach_port_name_t);
static mach_msg_fn g_orig_mach_msg = NULL;

static int bfix_is_assertiond_process(void) {
    static int cached = -1;
    if (cached != -1) return cached;
    const char *pn = getprogname();
    cached = (pn && strstr(pn, "assertiond")) ? 1 : 0;
    return cached;
}

static int bfix_trace_pi_enabled(void) {
    const char *e = getenv("ROSETTASIM_ASSERTIOND_TRACE");
    return (e && e[0] == '1');
}

typedef struct {
    uint64_t handle;
    char name[128];
} bfix_handle_map_entry_t;

#define BFIX_HANDLE_MAP_SLOTS 32
static bfix_handle_map_entry_t g_bfix_handle_map[BFIX_HANDLE_MAP_SLOTS];

static void bfix_handle_map_set(uint64_t handle, const char *name) {
    if (!handle || !name || !name[0]) return;
    int slot = (int)(handle % BFIX_HANDLE_MAP_SLOTS);
    g_bfix_handle_map[slot].handle = handle;
    strncpy(g_bfix_handle_map[slot].name, name, sizeof(g_bfix_handle_map[slot].name) - 1);
    g_bfix_handle_map[slot].name[sizeof(g_bfix_handle_map[slot].name) - 1] = '\0';
}

static const char *bfix_handle_map_get(uint64_t handle) {
    if (!handle) return NULL;
    int slot = (int)(handle % BFIX_HANDLE_MAP_SLOTS);
    if (g_bfix_handle_map[slot].handle == handle && g_bfix_handle_map[slot].name[0])
        return g_bfix_handle_map[slot].name;
    return NULL;
}
/* For XPC pipe routine=805, the "handle" field is frequently 0.
 * Instead, correlate reply → request via the Mach reply port
 * (request msgh_local_port / reply msgh_local_port in receiver namespace). */
typedef struct {
    mach_port_t reply_port;
    char name[128];
} bfix_checkin_map_entry_t;

#define BFIX_CHECKIN_MAP_SLOTS 64
static bfix_checkin_map_entry_t g_bfix_checkin_map[BFIX_CHECKIN_MAP_SLOTS];

static void bfix_checkin_map_set(mach_port_t reply_port, const char *name) {
    if (reply_port == MACH_PORT_NULL || !name || !name[0]) return;
    int slot = (int)(((uint32_t)reply_port) % BFIX_CHECKIN_MAP_SLOTS);
    g_bfix_checkin_map[slot].reply_port = reply_port;
    strncpy(g_bfix_checkin_map[slot].name, name, sizeof(g_bfix_checkin_map[slot].name) - 1);
    g_bfix_checkin_map[slot].name[sizeof(g_bfix_checkin_map[slot].name) - 1] = '\0';
}

static const char *bfix_checkin_map_get(mach_port_t reply_port) {
    if (reply_port == MACH_PORT_NULL) return NULL;
    int slot = (int)(((uint32_t)reply_port) % BFIX_CHECKIN_MAP_SLOTS);
    if (g_bfix_checkin_map[slot].reply_port == reply_port && g_bfix_checkin_map[slot].name[0])
        return g_bfix_checkin_map[slot].name;
    return NULL;
}

static void bfix_checkin_map_clear(mach_port_t reply_port) {
    if (reply_port == MACH_PORT_NULL) return;
    int slot = (int)(((uint32_t)reply_port) % BFIX_CHECKIN_MAP_SLOTS);
    if (g_bfix_checkin_map[slot].reply_port == reply_port) {
        g_bfix_checkin_map[slot].reply_port = MACH_PORT_NULL;
        g_bfix_checkin_map[slot].name[0] = '\0';
    }
}

typedef struct {
    mach_port_t reply_port;
    uint32_t req_id;
    uint64_t seq;
} bfix_pending_reply_t;

#define BFIX_PENDING_REPLY_SLOTS 64
static bfix_pending_reply_t g_bfix_pending_replies[BFIX_PENDING_REPLY_SLOTS];
static uint64_t g_bfix_pending_seq = 0;

static void bfix_pending_add(mach_port_t reply_port, uint32_t req_id) {
    if (reply_port == MACH_PORT_NULL) return;
    uint64_t seq = ++g_bfix_pending_seq;
    int slot = (int)(seq % BFIX_PENDING_REPLY_SLOTS);
    g_bfix_pending_replies[slot].reply_port = reply_port;
    g_bfix_pending_replies[slot].req_id = req_id;
    g_bfix_pending_replies[slot].seq = seq;
}

static int bfix_pending_match_and_clear(mach_port_t reply_port, uint32_t *out_req_id) {
    if (reply_port == MACH_PORT_NULL) return 0;
    for (int i = 0; i < BFIX_PENDING_REPLY_SLOTS; i++) {
        if (g_bfix_pending_replies[i].reply_port == reply_port) {
            if (out_req_id) *out_req_id = g_bfix_pending_replies[i].req_id;
            g_bfix_pending_replies[i].reply_port = MACH_PORT_NULL;
            g_bfix_pending_replies[i].req_id = 0;
            g_bfix_pending_replies[i].seq = 0;
            return 1;
        }
    }
    return 0;
}

static const uint8_t *bfix_find_xpc_payload(const uint8_t *raw, uint32_t total,
                                            uint32_t *out_off) {
    if (!raw || total < sizeof(mach_msg_header_t) + 20) return NULL;
    uint32_t start = (uint32_t)sizeof(mach_msg_header_t);
    uint32_t end = total;
    if (end > 512) end = 512;
    if (end < start + 4) return NULL;
    for (uint32_t off = start; off + 4 <= end; off += 4) {
        if (*(const uint32_t *)(raw + off) == BFIX_XPC_MAGIC) {
            if (out_off) *out_off = off;
            return raw + off;
        }
    }
    return NULL;
}

static uint64_t bfix_xpc_extract_int64_key(const uint8_t *xpc, uint32_t xpc_len,
                                           const char *wanted_key, int *found) {
    if (found) *found = 0;
    if (!xpc || xpc_len < 20 || !wanted_key) return 0;
    if (*(const uint32_t *)xpc != BFIX_XPC_MAGIC) return 0;
    if (*(const uint32_t *)(xpc + 8) != BFIX_XPC_TYPE_DICT) return 0;
    uint32_t entry_count = *(const uint32_t *)(xpc + 16);
    uint32_t pos = 20;
    for (uint32_t i = 0; i < entry_count && pos < xpc_len; i++) {
        const char *key = (const char *)(xpc + pos);
        uint32_t key_len = (uint32_t)strnlen(key, xpc_len - pos);
        uint32_t key_padded = (key_len + 1 + 3) & ~3;
        pos += key_padded;
        if (pos + 4 > xpc_len) break;
        uint32_t val_type = *(const uint32_t *)(xpc + pos);
        pos += 4;
        if (val_type == BFIX_XPC_TYPE_INT64 || val_type == BFIX_XPC_TYPE_UINT64) {
            if (pos + 8 > xpc_len) break;
            uint64_t v = *(const uint64_t *)(xpc + pos);
            if (strcmp(key, wanted_key) == 0) {
                if (found) *found = 1;
                return v;
            }
            pos += 8;
        } else if (val_type == BFIX_XPC_TYPE_STRING) {
            if (pos + 4 > xpc_len) break;
            uint32_t slen = *(const uint32_t *)(xpc + pos);
            pos += 4;
            uint32_t spad = (slen + 3) & ~3;
            pos += spad;
        } else if (val_type == BFIX_XPC_TYPE_BOOL) {
            if (pos + 4 > xpc_len) break;
            pos += 4;
        } else if (val_type == BFIX_XPC_TYPE_MACH_SEND || val_type == BFIX_XPC_TYPE_MACH_RECV) {
            /* no inline payload */
        } else if (val_type == BFIX_XPC_TYPE_DICT || val_type == BFIX_XPC_TYPE_ARRAY) {
            if (pos + 4 > xpc_len) break;
            uint32_t sz = *(const uint32_t *)(xpc + pos);
            pos += 4;
            pos += sz;
        } else {
            if (pos + 4 > xpc_len) break;
            uint32_t sz = *(const uint32_t *)(xpc + pos);
            pos += 4;
            if (sz < 0x10000) pos += sz;
            else break;
        }
    }
    return 0;
}

static int bfix_xpc_extract_string_key_copy(const uint8_t *xpc, uint32_t xpc_len,
                                            const char *wanted_key,
                                            char *out, size_t out_len) {
    if (!xpc || xpc_len < 24 || !wanted_key || !out || out_len == 0) return 0;
    out[0] = '\0';
    if (*(const uint32_t *)xpc != BFIX_XPC_MAGIC) return 0;
    if (*(const uint32_t *)(xpc + 8) != BFIX_XPC_TYPE_DICT) return 0;
    uint32_t entry_count = *(const uint32_t *)(xpc + 16);
    uint32_t pos = 20;
    for (uint32_t i = 0; i < entry_count && pos < xpc_len; i++) {
        const char *key = (const char *)(xpc + pos);
        uint32_t key_len = (uint32_t)strnlen(key, xpc_len - pos);
        uint32_t key_padded = (key_len + 1 + 3) & ~3;
        pos += key_padded;
        if (pos + 4 > xpc_len) break;
        uint32_t val_type = *(const uint32_t *)(xpc + pos);
        pos += 4;
        if (val_type == BFIX_XPC_TYPE_STRING) {
            if (pos + 4 > xpc_len) break;
            uint32_t slen = *(const uint32_t *)(xpc + pos);
            pos += 4;
            if (strcmp(key, wanted_key) == 0 && pos + slen <= xpc_len) {
                /* slen includes null terminator in this wire format */
                size_t n = slen;
                if (n == 0) n = 1;
                if (n > out_len) n = out_len;
                strncpy(out, (const char *)(xpc + pos), n - 1);
                out[n - 1] = '\0';
                return 1;
            }
            uint32_t spad = (slen + 3) & ~3;
            pos += spad;
        } else if (val_type == BFIX_XPC_TYPE_INT64 || val_type == BFIX_XPC_TYPE_UINT64) {
            if (pos + 8 > xpc_len) break;
            pos += 8;
        } else if (val_type == BFIX_XPC_TYPE_BOOL) {
            if (pos + 4 > xpc_len) break;
            pos += 4;
        } else if (val_type == BFIX_XPC_TYPE_MACH_SEND || val_type == BFIX_XPC_TYPE_MACH_RECV) {
            /* no inline payload */
        } else if (val_type == BFIX_XPC_TYPE_DICT || val_type == BFIX_XPC_TYPE_ARRAY) {
            if (pos + 4 > xpc_len) break;
            uint32_t sz = *(const uint32_t *)(xpc + pos);
            pos += 4;
            pos += sz;
        } else {
            if (pos + 4 > xpc_len) break;
            uint32_t sz = *(const uint32_t *)(xpc + pos);
            pos += 4;
            if (sz < 0x10000) pos += sz;
            else break;
        }
    }
    return 0;
}

static mach_port_t bfix_extract_first_port_desc_name(mach_msg_header_t *msg,
                                                     uint32_t total,
                                                     uint32_t *out_desc_count) {
    if (out_desc_count) *out_desc_count = 0;
    if (!msg || total < sizeof(mach_msg_header_t) + sizeof(mach_msg_body_t)) return MACH_PORT_NULL;
    if ((msg->msgh_bits & MACH_MSGH_BITS_COMPLEX) == 0) return MACH_PORT_NULL;
    uint8_t *raw = (uint8_t *)msg;
    mach_msg_body_t *body = (mach_msg_body_t *)(raw + sizeof(mach_msg_header_t));
    uint32_t dc = body->msgh_descriptor_count;
    if (out_desc_count) *out_desc_count = dc;
    if (dc == 0) return MACH_PORT_NULL;
    size_t off = sizeof(mach_msg_header_t) + sizeof(mach_msg_body_t);
    if (off + sizeof(mach_msg_port_descriptor_t) > total) return MACH_PORT_NULL;
    mach_msg_port_descriptor_t *pd = (mach_msg_port_descriptor_t *)(raw + off);
    return pd->name;
}

static void bfix_trace_received_on_pi_port(mach_msg_header_t *msg, uint32_t total) {
    static int log_count = 0;
    if (!msg || total < sizeof(mach_msg_header_t)) return;
    if (log_count++ > 200) return;

    uint32_t xpc_off = 0;
    const uint8_t *xpc = bfix_find_xpc_payload((const uint8_t *)msg, total, &xpc_off);
    int mt_found = 0;
    uint64_t mt = 0;
    if (xpc) {
        mt = bfix_xpc_extract_int64_key(xpc, total - xpc_off, "messageType", &mt_found);
        if (!mt_found) mt = bfix_xpc_extract_int64_key(xpc, total - xpc_off, "type", &mt_found);
    }

    if (mt_found) {
        bfix_log("[bfix] PI RECV: id=0x%x size=%u bits=0x%x local=0x%x reply=0x%x messageType=%llu\n",
                 msg->msgh_id, total, msg->msgh_bits,
                 msg->msgh_local_port, msg->msgh_remote_port,
                 (unsigned long long)mt);
    } else {
        bfix_log("[bfix] PI RECV: id=0x%x size=%u bits=0x%x local=0x%x reply=0x%x (no messageType)\n",
                 msg->msgh_id, total, msg->msgh_bits,
                 msg->msgh_local_port, msg->msgh_remote_port);
    }
}

/* Thread-local flag: set when a CA commit (40002/40003) is received.
 * On the NEXT mach_msg call (after MIG processes the commit), we send
 * a kick_server message (40001) to the CARenderServer port to trigger
 * rendering on the correct PurpleMain display thread. */
static __thread int g_commit_render_pending = 0;

/* File-scope state for post-commit rendering */
static void *g_pcr_rft_fn = NULL;   /* render_for_time function pointer */
static void *g_pcr_rft_srv = NULL;  /* CA::Render::Server* C++ object */
static int g_pcr_init = 0;
static int g_pcr_render_count = 0;
static mach_port_t g_pcr_car_port = MACH_PORT_NULL; /* CARenderServer port */

/* Send kick_server (msg_id 40001) to CARenderServer port.
 * This is the NATIVE mechanism for waking the render loop.
 * The PurpleMain display thread should handle it and trigger
 * render_display on the correct thread with correct CA state. */
static void _pcr_send_kick(void) {
    if (!g_pcr_car_port) return;

    mach_msg_header_t kick = {0};
    kick.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0);
    kick.msgh_size = sizeof(kick);
    kick.msgh_remote_port = g_pcr_car_port;
    kick.msgh_id = 40001; /* kick_server native message */
    kern_return_t kr = mach_msg(&kick, MACH_SEND_MSG | MACH_SEND_TIMEOUT,
                                 sizeof(kick), 0, 0, 100, 0);

    static int _kick_log = 0;
    if (_kick_log < 5 || _kick_log % 200 == 0) {
        bfix_log("KICK_SERVER[%d]: msg_id=40001 to port=%u kr=%d(%s)",
            _kick_log, g_pcr_car_port, kr,
            kr == KERN_SUCCESS ? "ok" : mach_error_string(kr));
    }
    _kick_log++;
}

static void _pcr_do_render(void) {
    /* Lazy init */
    if (!g_pcr_init) {
        g_pcr_init = 1;
        const char *pn = getprogname();
        if (!(pn && strstr(pn, "backboardd"))) return;

        /* Get CARenderServer port for kick_server messages */
        typedef mach_port_t (*GSPFn)(void);
        GSPFn gsp = (GSPFn)dlsym(RTLD_DEFAULT, "CARenderServerGetServerPort");
        if (gsp) {
            g_pcr_car_port = gsp();
            Dl_info dinfo;
            if (dladdr((void *)gsp, &dinfo) && dinfo.dli_fbase) {
                uintptr_t qc_base = (uintptr_t)dinfo.dli_fbase;
                g_pcr_rft_fn = (void *)(qc_base + 0x1287ea);
            }
        }
        Class wsCls = (Class)objc_getClass("CAWindowServer");
        if (wsCls) {
            id ws = ((id(*)(id, SEL))objc_msgSend)((id)wsCls, sel_registerName("server"));
            if (ws) {
                id disps = ((id(*)(id, SEL))objc_msgSend)(ws, sel_registerName("displays"));
                unsigned long dcnt = disps ? ((unsigned long(*)(id, SEL))objc_msgSend)(
                    disps, sel_registerName("count")) : 0;
                if (dcnt > 0) {
                    id disp = ((id(*)(id, SEL, unsigned long))objc_msgSend)(
                        disps, sel_registerName("objectAtIndex:"), 0UL);
                    Ivar iI = class_getInstanceVariable(object_getClass(disp), "_impl");
                    if (iI) {
                        void *impl = *(void **)((uint8_t *)disp + ivar_getOffset(iI));
                        if (impl) g_pcr_rft_srv = *(void **)((uint8_t *)impl + 0x40);
                    }
                }
            }
        }
        bfix_log("POST_COMMIT_RENDER: init fn=%p srv=%p car_port=%u %s",
            g_pcr_rft_fn, g_pcr_rft_srv, g_pcr_car_port,
            (g_pcr_rft_fn && g_pcr_rft_srv) ? "READY" : "FAILED");

        /* Check PurpleDisplay::can_update() gate — Display+0xfa bit 1
         * If bit 1 is set, can_update returns false and render_for_time
         * SKIPS ALL RENDERING (jumps to cleanup at 0x129413). */
        if (g_pcr_rft_srv) {
            void *display_cpp = *(void **)((uint8_t *)g_pcr_rft_srv + 0x58);
            if (display_cpp) {
                uint8_t fa_byte = *(uint8_t *)((uint8_t *)display_cpp + 0xfa);
                bfix_log("CAN_UPDATE: Display+0xfa = 0x%02x bit1=%d can_update=%d",
                    fa_byte, (fa_byte >> 1) & 1, !(fa_byte & 0x2));
                if (fa_byte & 0x2) {
                    *(uint8_t *)((uint8_t *)display_cpp + 0xfa) &= ~0x02;
                    bfix_log("CAN_UPDATE: CLEARED bit 1 → can_update=1");
                }
            } else {
                bfix_log("CAN_UPDATE: display_cpp is NULL!");
            }

            /* Check OGL::Renderer at Server+0xc0 — if NULL, no compositor */
            void *renderer = *(void **)((uint8_t *)g_pcr_rft_srv + 0xc0);
            bfix_log("RENDERER: Server+0xc0 = %p", renderer);

            /* Dump full Server layout from +0x00 to +0xd8 to map fields */
            uint8_t *srv = (uint8_t *)g_pcr_rft_srv;
            bfix_log("SERVER_LAYOUT: ptr=%p", g_pcr_rft_srv);
            for (int off = 0; off <= 0xd8; off += 8) {
                void *val = *(void **)(srv + off);
                bfix_log("  Server+0x%02x = %p", off, val);
            }
        }
    }

    /* APPROACH A: Send kick_server (40001) to trigger render on PurpleMain thread */
    _pcr_send_kick();

    /* APPROACH B (fallback): Direct render_for_time on current thread */
    if (!g_pcr_rft_fn || !g_pcr_rft_srv) return;

    /* Ensure can_update gate is open BEFORE each render */
    {
        void *display_cpp = *(void **)((uint8_t *)g_pcr_rft_srv + 0x58);
        if (display_cpp) {
            uint8_t fa_byte = *(uint8_t *)((uint8_t *)display_cpp + 0xfa);
            if (fa_byte & 0x2) {
                *(uint8_t *)((uint8_t *)display_cpp + 0xfa) &= ~0x02;
                static int _cu_clear = 0;
                if (_cu_clear < 5)
                    bfix_log("CAN_UPDATE[%d]: cleared bit1 before render (was 0x%02x)",
                        ++_cu_clear, fa_byte);
            }
        }
    }

    /* Log renderer pointer on first few renders to verify it's populated */
    if (g_pcr_render_count < 3) {
        void *renderer = *(void **)((uint8_t *)g_pcr_rft_srv + 0xc0);
        void *swctx = *(void **)((uint8_t *)g_pcr_rft_srv + 0xb8);
        bfix_log("PRE_RENDER[%d]: renderer=%p swctx=%p", g_pcr_render_count, renderer, swctx);
    }

    /* Check display vtable gates — is_ready, ignore_update_p, is_enabled */
    if (g_pcr_render_count < 5) {
        void *display_cpp = *(void **)((uint8_t *)g_pcr_rft_srv + 0x58);
        if (display_cpp) {
            void **dv = *(void ***)display_cpp;

            /* is_ready: vtable[9] = +0x48 */
            typedef int (*IsReadyFn)(void*);
            int ready = ((IsReadyFn)dv[9])(display_cpp);

            /* ignore_update_p: vtable[16] = +0x80 */
            typedef int (*IgnoreUpdateFn)(void*);
            int ignore = ((IgnoreUpdateFn)dv[16])(display_cpp);

            /* is_enabled: Display+0x1e0 bit 0 */
            uint8_t e0 = *(uint8_t *)((uint8_t *)display_cpp + 0x1e0);

            bfix_log("DISPLAY_GATES[%d]: is_ready=%d ignore_update=%d is_enabled=%d(+0x1e0=0x%02x)",
                g_pcr_render_count, ready, ignore, e0 & 1, e0);
        }
    }

    /* EXPERIMENT: Inject server contexts into display context list.
     * The display list at display+0xC0 contains only a sentinel (0xFFFFFFFFFFFFFFFF).
     * Try replacing it with actual server context handles to see if render_display
     * produces pixels when it has real contexts to iterate. */
    static int _ctx_injected = 0;
    if (!_ctx_injected && g_pcr_rft_srv && g_pcr_render_count >= 2) {
        void *display_cpp = *(void **)((uint8_t *)g_pcr_rft_srv + 0x58);
        if (display_cpp) {
            void **dlist_begin = (void **)*(void **)((uint8_t *)display_cpp + 0xC0);
            void **dlist_end   = (void **)*(void **)((uint8_t *)display_cpp + 0xC8);
            int dcount = (dlist_begin && dlist_end && dlist_end > dlist_begin) ?
                (int)((uintptr_t)dlist_end - (uintptr_t)dlist_begin) / sizeof(void*) : 0;

            /* Find first server context with a valid handle (non-NULL, seed > 0) */
            /* Server context list: pointer at +0x68, iterate looking for handles */
            void *ctx_list_ptr = *(void **)((uint8_t *)g_pcr_rft_srv + 0x68);
            if (ctx_list_ptr && dcount == 1 && dlist_begin) {
                /* The server ctx list layout: array of pointers to Context objects.
                 * Each Context has: +0x00=vtable, we iterate Server+0x68 entries.
                 * But we need the Context* pointers themselves.
                 *
                 * Actually, the CTX dump shows handle= values. Let me collect
                 * non-NULL handles from the server ctx list. The list at +0x68
                 * is a std::vector-like structure. Let me read it as pointer pairs. */

                /* Read from the hash map at Server+0x68 to find Context* pointers */
                /* For now, try the simplest approach: iterate the known context
                 * dump and find the first one with a handle. We already have the
                 * server at g_pcr_rft_srv.
                 *
                 * Server ctx iteration: the CTX dump code walks an internal map.
                 * Let me just try writing the first context's handle directly. */

                /* Actually let's just gather context handles from the CTX_DIAG path.
                 * We need to walk the server's context map. For simplicity, store
                 * context handles we've seen in the CTX dump. */

                /* Walk server context list (same layout as CTX_DIAG code).
                 * Array at Server+0x68, count at Server+0x78, stride=0x10 per entry.
                 * Context* at offset 0 of each 0x10-byte entry. */
                uint64_t ctx_count = *(uint64_t *)((uint8_t *)g_pcr_rft_srv + 0x78);

                /* Collect up to 8 valid Context* pointers */
                void *ctx_handles[8];
                int n_handles = 0;

                if (ctx_count > 0 && ctx_count < 100) {
                    for (uint64_t ci = 0; ci < ctx_count && n_handles < 8; ci++) {
                        void *ctx = *(void **)((uint8_t *)ctx_list_ptr + ci * 0x10);
                        if (ctx && (uintptr_t)ctx > 0x100000) {
                            ctx_handles[n_handles++] = ctx;
                        }
                    }
                }

                if (n_handles > 0) {
                    bfix_log("CTX_INJECT: found %d contexts, injecting into display list", n_handles);

                    /* Allocate new display context array.
                     * For safety, use malloc (lives in our heap, won't be freed by CA). */
                    void **new_list = (void **)malloc(n_handles * sizeof(void *));
                    if (new_list) {
                        for (int i = 0; i < n_handles; i++) {
                            new_list[i] = ctx_handles[i];
                            bfix_log("CTX_INJECT[%d]: %p", i, ctx_handles[i]);
                        }

                        /* Overwrite display context list pointers */
                        *(void **)((uint8_t *)display_cpp + 0xC0) = new_list;
                        *(void **)((uint8_t *)display_cpp + 0xC8) = new_list + n_handles;
                        *(void **)((uint8_t *)display_cpp + 0xD0) = new_list + n_handles;
                        _ctx_injected = 1;
                        bfix_log("CTX_INJECT: display ctx list updated, count=%d", n_handles);
                    }
                } else {
                    bfix_log("CTX_INJECT: no valid context handles found in server map");
                }
            }
        }
    }

    /* === DIRTY FLAG PROPAGATION EXPERIMENTS === */
    static uintptr_t _qc_base = 0;
    if (!_qc_base) {
        void *sym = dlsym(RTLD_DEFAULT, "CARenderServerGetServerPort");
        if (sym) {
            Dl_info di;
            if (dladdr(sym, &di) && di.dli_fbase)
                _qc_base = (uintptr_t)di.dli_fbase;
        }
    }

    /* Option A: Try Server::invalidate(NULL) via dlsym */
    {
        static void *_inv_fn = NULL;
        static int _inv_tried = 0;
        if (!_inv_tried) {
            _inv_tried = 1;
            _inv_fn = dlsym(RTLD_DEFAULT, "_ZN2CA12WindowServer6Server10invalidateEPNS_5ShapeE");
            bfix_log("INVALIDATE: dlsym=%p", _inv_fn);
        }
        if (_inv_fn) {
            typedef void (*InvFn)(void*, void*);
            ((InvFn)_inv_fn)(g_pcr_rft_srv, NULL);
        }
    }

    /* Option D: Call set_next_update + attach_contexts from background thread.
     * context_created deadlocks from server thread (MIG 40400 self-send).
     * Dispatching to a background queue lets the server thread process
     * the 40400 message while we call context_created. */
    {
        void **srv_vt = *(void ***)g_pcr_rft_srv;
        typedef void (*SetNextUpdateFn)(void*, double, double);
        SetNextUpdateFn set_next = (SetNextUpdateFn)srv_vt[3];
        set_next(g_pcr_rft_srv, 0.0, 0.0);
        static int _snu_log = 0;
        if (_snu_log < 3) {
            bfix_log("SET_NEXT_UPDATE[%d]: vtable[3]=%p", ++_snu_log, (void *)srv_vt[3]);
        }
    }

    /* Option E: Dispatch attach_contexts to background queue.
     * attach_contexts at QC+0x1286de calls copy_all_contexts then
     * context_created on each. Must run on non-server thread. */
    {
        static int _attach_tried = 0;
        if (!_attach_tried && _qc_base && g_pcr_render_count >= 3) {
            _attach_tried = 1;
            /* Create a struct to pass to the block */
            typedef void (*AttachFn)(void*);
            AttachFn attach = (AttachFn)(_qc_base + 0x1286de);
            void *srv_copy = g_pcr_rft_srv;
            bfix_log("ATTACH_CTX: dispatching attach_contexts(%p) to bg queue, fn=%p",
                srv_copy, (void *)attach);

            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                bfix_log("ATTACH_CTX: calling attach_contexts from bg thread");
                char tname[64] = {0};
                pthread_getname_np(pthread_self(), tname, sizeof(tname));
                bfix_log("ATTACH_CTX: thread='%s'", tname[0] ? tname : "(unnamed)");
                attach(srv_copy);
                bfix_log("ATTACH_CTX: returned!");
            });
        }
    }

    /* Option B: Check Display+0x28/+0x30 early exit flags */
    {
        void *display_cpp = *(void **)((uint8_t *)g_pcr_rft_srv + 0x58);
        if (display_cpp) {
            void *d28 = *(void **)((uint8_t *)display_cpp + 0x28);
            uint8_t d30 = *(uint8_t *)((uint8_t *)display_cpp + 0x30);
            static int _exit_log = 0;
            if (_exit_log < 5) {
                _exit_log++;
                bfix_log("EARLY_EXIT[%d]: Display+0x28=%p +0x30=0x%02x bit5=%d",
                    _exit_log, d28, d30, (d30 >> 5) & 1);
            }
            /* Clear bit 5 if set — might prevent early exit */
            if (d30 & 0x20) {
                *(uint8_t *)((uint8_t *)display_cpp + 0x30) &= ~0x20;
                bfix_log("EARLY_EXIT: cleared bit5 of Display+0x30");
            }
        }
    }

    /* Option C: Call kick_server at QC+0xb2cde BEFORE render */
    if (_qc_base) {
        typedef void (*KickFn)(void*);
        KickFn kick = (KickFn)(_qc_base + 0xb2cde);
        kick(g_pcr_rft_srv);
        static int _kick_log = 0;
        if (_kick_log < 5) {
            _kick_log++;
            bfix_log("KICK_DIRECT[%d]: called kick_server(%p)", _kick_log, g_pcr_rft_srv);
        }
    }

    /* Option F: Check if Shmem is mapped at 0x100000000 in backboardd.
     * The client writes commit data to a Shmem region at this address.
     * If the server can't access it, layers are empty skeletons. */
    {
        static int _shmem_checked = 0;
        if (!_shmem_checked) {
            _shmem_checked = 1;
            vm_offset_t test_data = 0;
            mach_msg_type_number_t test_cnt = 0;
            kern_return_t kr = vm_read(mach_task_self(), 0x100000000ULL, 64,
                                        &test_data, &test_cnt);
            if (kr == KERN_SUCCESS && test_cnt > 0) {
                uint32_t *words = (uint32_t *)test_data;
                bfix_log("SHMEM_TEST: vm_read(self, 0x100000000) SUCCESS cnt=%u "
                    "magic=0x%x 0x%x 0x%x 0x%x",
                    test_cnt, words[0], words[1], words[2], words[3]);
                vm_deallocate(mach_task_self(), test_data, test_cnt);
            } else {
                bfix_log("SHMEM_TEST: vm_read(self, 0x100000000) FAILED kr=%d(%s)",
                    kr, mach_error_string(kr));
            }

            /* Also scan for mapped regions near 0x100000000 */
            vm_address_t addr = 0x100000000ULL;
            vm_size_t size = 0;
            natural_t depth = 0;
            struct vm_region_submap_info_64 info;
            mach_msg_type_number_t count = VM_REGION_SUBMAP_INFO_COUNT_64;
            kr = vm_region_recurse_64(mach_task_self(), &addr, &size, &depth,
                                       (vm_region_info_64_t)&info, &count);
            bfix_log("SHMEM_TEST: region at 0x%llx size=0x%llx kr=%d prot=%d/%d",
                (unsigned long long)addr, (unsigned long long)size, kr,
                info.protection, info.max_protection);
        }
    }

    /* === END DIRTY FLAG EXPERIMENTS === */

    g_pcr_render_count++;
    extern double CACurrentMediaTime(void);
    typedef void (*RFTFn)(void*, double, void*, unsigned int);
    ((RFTFn)g_pcr_rft_fn)(g_pcr_rft_srv, CACurrentMediaTime(), NULL, 0);

    if (g_pcr_render_count <= 10 || g_pcr_render_count % 200 == 0) {
        char tname[64] = {0};
        pthread_getname_np(pthread_self(), tname, sizeof(tname));
        bfix_log("POST_COMMIT_RENDER[%d]: render_for_time on thread='%s'",
            g_pcr_render_count, tname[0] ? tname : "(unnamed)");

        if (g_pcr_render_count <= 5 || g_pcr_render_count == 100 || g_pcr_render_count == 500 || g_pcr_render_count == 1000) {
            /* Check SWContext pixel buffer (FRESH read after render) */
            void *swctx = *(void **)((uint8_t *)g_pcr_rft_srv + 0xb8);
            if (swctx) {
                void *pixbuf = *(void **)((uint8_t *)swctx + 0x668);
                if (pixbuf && (uint64_t)pixbuf > 0x100000) {
                    uint8_t *pp = (uint8_t *)pixbuf;
                    int nz = 0;
                    for (int i = 0; i < 2000; i++)
                        if (pp[i*4]||pp[i*4+1]||pp[i*4+2]) nz++;
                    bfix_log("PIXELS[%d]: SWCTX %d/2000 nz RGB pixbuf=%p px[0]=(%u,%u,%u,%u)",
                        g_pcr_render_count, nz, pixbuf, pp[0], pp[1], pp[2], pp[3]);
                } else {
                    bfix_log("PIXELS[%d]: SWCTX pixbuf=%p (invalid)", g_pcr_render_count, pixbuf);
                }
            } else {
                bfix_log("PIXELS[%d]: no SWContext", g_pcr_render_count);
            }

            /* Check display surface (the FINAL rendered output) */
            void *disp = *(void **)((uint8_t *)g_pcr_rft_srv + 0x58);
            if (disp) {
                void *surface = *(void **)((uint8_t *)disp + 0x138);
                if (surface) {
                    void *surf_data = *(void **)((uint8_t *)surface + 0x40);
                    int64_t surf_stride = *(int64_t *)((uint8_t *)surface + 0x48);
                    if (surf_data && (uint64_t)surf_data > 0x100000) {
                        uint8_t *sp = (uint8_t *)surf_data;
                        int snz = 0;
                        for (int i = 0; i < 2000; i++)
                            if (sp[i*4]||sp[i*4+1]||sp[i*4+2]) snz++;
                        bfix_log("PIXELS[%d]: SURFACE %d/2000 nz RGB data=%p stride=%lld px[0]=(%u,%u,%u,%u)",
                            g_pcr_render_count, snz, surf_data, (long long)surf_stride,
                            sp[0], sp[1], sp[2], sp[3]);
                    } else {
                        bfix_log("PIXELS[%d]: SURFACE data=%p (invalid)", g_pcr_render_count, surf_data);
                    }
                } else {
                    bfix_log("PIXELS[%d]: no surface at display+0x138", g_pcr_render_count);
                }
            }

            /* Diagnostic: dump context states + root layer details */
            void *srv = g_pcr_rft_srv;
            void **ctx_list = *(void ***)((uint8_t *)srv + 0x68);
            uint64_t ctx_count = *(uint64_t *)((uint8_t *)srv + 0x78);
            bfix_log("CTX_DIAG[%d]: ctx_count=%llu",
                g_pcr_render_count, (unsigned long long)ctx_count);

            for (uint64_t ci = 0; ci < ctx_count && ci < 10; ci++) {
                void *ctx = *(void **)((uint8_t *)ctx_list + ci * 0x10);
                if (!ctx) continue;
                uint32_t cid = *(uint32_t *)((uint8_t *)ctx + 0x0C);
                uint32_t commit_seed = *(uint32_t *)((uint8_t *)ctx + 0x24);
                void *root_handle = *(void **)((uint8_t *)ctx + 0xB8);
                /* Dump context fields to find server port and flags.
                 * Scan uint32s looking for port-sized values (1000-65535 range) */
                uint32_t *ctx32 = (uint32_t *)ctx;
                bfix_log("CTX[%llu]: id=%u seed=%u handle=%p",
                    (unsigned long long)ci, cid, commit_seed, root_handle);
                if (g_pcr_render_count <= 2 && ci == 0) {
                    /* Dump first 64 uint32s of context to map layout */
                    for (int off32 = 0; off32 < 64; off32 += 8) {
                        bfix_log("  ctx32[%d-%d]: %08x %08x %08x %08x %08x %08x %08x %08x",
                            off32, off32+7,
                            ctx32[off32], ctx32[off32+1], ctx32[off32+2], ctx32[off32+3],
                            ctx32[off32+4], ctx32[off32+5], ctx32[off32+6], ctx32[off32+7]);
                    }
                }

                if (!root_handle) continue;

                /* Root layer at handle+0x18 (from static analysis) */
                void *root_layer = *(void **)((uint8_t *)root_handle + 0x18);
                if (!root_layer) {
                    bfix_log("  ROOT: handle=%p but layer=NULL", root_handle);
                    continue;
                }

                /* Scan root layer for dimension-like doubles */
                int found_dims = 0;
                for (int off = 0x20; off < 0x200 && !found_dims; off += 8) {
                    double val = *(double *)((uint8_t *)root_layer + off);
                    if (val > 100.0 && val < 2000.0) {
                        double val2 = *(double *)((uint8_t *)root_layer + off + 8);
                        if (val2 > 100.0 && val2 < 2000.0) {
                            bfix_log("  ROOT: DIMS at +0x%x: %.1f x %.1f", off, val, val2);
                            found_dims = 1;
                        }
                    }
                }
                if (!found_dims)
                    bfix_log("  ROOT: no dimension-like doubles found");

                /* Sublayer array at +0x70 */
                void *sub_array = *(void **)((uint8_t *)root_layer + 0x70);
                int sub_count = sub_array ? *(int *)((uint8_t *)sub_array + 0x0C) : -1;

                /* Dump raw first 32 uint64s of root_layer for analysis */
                if (g_pcr_render_count <= 2) {
                    uint64_t *raw = (uint64_t *)root_layer;
                    bfix_log("  ROOT raw[0-7]:  %016llx %016llx %016llx %016llx %016llx %016llx %016llx %016llx",
                        raw[0],raw[1],raw[2],raw[3],raw[4],raw[5],raw[6],raw[7]);
                    bfix_log("  ROOT raw[8-15]: %016llx %016llx %016llx %016llx %016llx %016llx %016llx %016llx",
                        raw[8],raw[9],raw[10],raw[11],raw[12],raw[13],raw[14],raw[15]);
                    bfix_log("  ROOT raw[16-23]: %016llx %016llx %016llx %016llx %016llx %016llx %016llx %016llx",
                        raw[16],raw[17],raw[18],raw[19],raw[20],raw[21],raw[22],raw[23]);
                }

                bfix_log("  ROOT: sublayers=%d", sub_count);

                /* Inspect first sublayer — does it have content/backing store? */
                if (sub_array && sub_count > 0 && g_pcr_render_count <= 3) {
                    /* CA::Render::ShmemArray layout: +0x00=count?, +0x04=..., +0x08=reserved, +0x10=data_ptr */
                    /* Each sublayer is a pointer at data_ptr + i*8 */
                    void *sub_data = *(void **)((uint8_t *)sub_array + 0x10);
                    if (!sub_data) sub_data = *(void **)((uint8_t *)sub_array + 0x08);
                    if (sub_data && (uintptr_t)sub_data > 0x100000) {
                        void *sublayer = *(void **)sub_data;
                        if (sublayer && (uintptr_t)sublayer > 0x100000) {
                            /* Dump sublayer raw data to find contents/backing */
                            uint64_t *sraw = (uint64_t *)sublayer;
                            bfix_log("  SUB[0] raw[0-7]:  %016llx %016llx %016llx %016llx %016llx %016llx %016llx %016llx",
                                sraw[0],sraw[1],sraw[2],sraw[3],sraw[4],sraw[5],sraw[6],sraw[7]);
                            bfix_log("  SUB[0] raw[8-15]: %016llx %016llx %016llx %016llx %016llx %016llx %016llx %016llx",
                                sraw[8],sraw[9],sraw[10],sraw[11],sraw[12],sraw[13],sraw[14],sraw[15]);
                            /* Check for backgroundColor at known Render::Layer offsets */
                            /* flags at +0x20, backgroundColor might be at +0xC0-0xE0 range */
                            double *colors = (double *)((uint8_t *)sublayer + 0xC0);
                            bfix_log("  SUB[0] potential_colors: %.2f %.2f %.2f %.2f",
                                colors[0], colors[1], colors[2], colors[3]);
                        }
                    }
                }
            }

            /* Check DISPLAY context list — different from server context list */
            void *display_cpp = *(void **)((uint8_t *)srv + 0x58);
            if (display_cpp) {
                /* Check display context list — std::vector at display+0xC0 {begin, end, capacity} */
                void *dlist_begin = *(void **)((uint8_t *)display_cpp + 0xC0);
                void *dlist_end   = *(void **)((uint8_t *)display_cpp + 0xC8);
                int dcount = (dlist_begin && dlist_end && dlist_end > dlist_begin) ?
                    (int)((uintptr_t)dlist_end - (uintptr_t)dlist_begin) / 8 : 0;
                bfix_log("DISPLAY_CTX: begin=%p end=%p count=%d", dlist_begin, dlist_end, dcount);

                /* Dump the actual context pointers in the display list */
                if (dcount > 0 && dcount <= 20 && g_pcr_render_count <= 3) {
                    void **dptrs = (void **)dlist_begin;
                    for (int di = 0; di < dcount; di++) {
                        bfix_log("DISPLAY_CTX[%d]: ctx_ptr=%p", di, dptrs[di]);
                    }
                }

                /* Also scan wider range for any vector-like patterns */
                for (int doff = 0x60; doff <= 0x100; doff += 8) {
                    void *a = *(void **)((uint8_t *)display_cpp + doff);
                    void *b = *(void **)((uint8_t *)display_cpp + doff + 8);
                    if (a && b && b > a && (uintptr_t)b - (uintptr_t)a <= 0x1000 &&
                        (uintptr_t)a > 0x100000000ULL) {
                        int cnt = (int)((uintptr_t)b - (uintptr_t)a) / 8;
                        if (cnt > 0 && cnt < 100) {
                            bfix_log("DISPLAY_VEC: disp+0x%x: %p..%p count=%d", doff, a, b, cnt);
                        }
                    }
                }
                /* Also dump display raw data for analysis */
                if (g_pcr_render_count <= 2) {
                    uint64_t *draw = (uint64_t *)display_cpp;
                    bfix_log("DISPLAY raw[0-7]: %016llx %016llx %016llx %016llx %016llx %016llx %016llx %016llx",
                        draw[0],draw[1],draw[2],draw[3],draw[4],draw[5],draw[6],draw[7]);
                    bfix_log("DISPLAY raw[8-15]: %016llx %016llx %016llx %016llx %016llx %016llx %016llx %016llx",
                        draw[8],draw[9],draw[10],draw[11],draw[12],draw[13],draw[14],draw[15]);
                    bfix_log("DISPLAY raw[16-23]: %016llx %016llx %016llx %016llx %016llx %016llx %016llx %016llx",
                        draw[16],draw[17],draw[18],draw[19],draw[20],draw[21],draw[22],draw[23]);
                    bfix_log("DISPLAY raw[24-31]: %016llx %016llx %016llx %016llx %016llx %016llx %016llx %016llx",
                        draw[24],draw[25],draw[26],draw[27],draw[28],draw[29],draw[30],draw[31]);
                }
            } else {
                bfix_log("DISPLAY_CTX: no display at srv+0x58");
            }
        }
    }
}

kern_return_t replacement_mach_msg(mach_msg_header_t *msg,
                                   mach_msg_option_t option,
                                   mach_msg_size_t send_size,
                                   mach_msg_size_t rcv_size,
                                   mach_port_name_t rcv_name,
                                   mach_msg_timeout_t timeout,
                                   mach_port_name_t notify) {
    if (!g_orig_mach_msg) {
        g_orig_mach_msg = (mach_msg_fn)dlsym(RTLD_NEXT, "mach_msg");
        if (!g_orig_mach_msg) {
            /* Best-effort fallback */
            g_orig_mach_msg = (mach_msg_fn)dlsym(RTLD_DEFAULT, "mach_msg");
        }
        if (!g_orig_mach_msg) {
            return KERN_FAILURE;
        }
    }

    const int is_assertiond = bfix_is_assertiond_process();

    /* Track flush_shmem (msg_id=3) sends from backboardd */
    static int g_flush_count = 0;
    if ((option & MACH_SEND_MSG) && msg && msg->msgh_id == 3) {
        static int _is_bbd = -1;
        if (_is_bbd == -1) {
            const char *pn = getprogname();
            _is_bbd = (pn && strstr(pn, "backboardd")) ? 1 : 0;
        }
        if (_is_bbd) {
            g_flush_count++;
            if (g_flush_count <= 5 || g_flush_count % 100 == 0)
                bfix_log("FLUSH_SHMEM[%d]: msg_id=3 sent", g_flush_count);
        }
    }

    /* Log ALL 40002/40003 sends from ANY process — identifies which process sends commits */
    if ((option & MACH_SEND_MSG) && msg) {
        if (msg->msgh_id == 40002 || msg->msgh_id == 40003) {
            static int _app_commit_count = 0;
            _app_commit_count++;
            if (_app_commit_count <= 20 || _app_commit_count % 100 == 0) {
                int is_complex = (msg->msgh_bits & MACH_MSGH_BITS_COMPLEX) != 0;
                bfix_log("APP_COMMIT[%d]: proc=%s id=%u size=%u port=%u complex=%d",
                    _app_commit_count, getprogname(), msg->msgh_id,
                    msg->msgh_size, msg->msgh_remote_port, is_complex);
                if (is_complex) {
                    mach_msg_body_t *body = (mach_msg_body_t *)(msg + 1);
                    bfix_log("APP_COMMIT[%d]: desc_count=%u", _app_commit_count,
                        body->msgh_descriptor_count);
                }
            }
        }
    }

    /* Fire post-commit render if a commit was received on the previous call.
     * This runs AFTER MIG processed the commit, so the scene graph is updated.
     * Guard against re-entrancy: render_for_time may trigger mach_msg internally
     * (e.g. flush_shmem notification), which would re-enter this function. */
    static __thread int _pcr_in_render = 0;
    if (g_commit_render_pending && (option & MACH_RCV_MSG) && !_pcr_in_render) {
        g_commit_render_pending = 0;
        _pcr_in_render = 1;
        _pcr_do_render();
        _pcr_in_render = 0;
    }

    /* Pre-send trace: capture routine=805 name/handle mapping for assertiond. */
    uint64_t pre_handle = 0;
    char pre_name[128] = {0};
    int pre_is_pi_checkin = 0;
    if (is_assertiond && (option & MACH_SEND_MSG) && msg) {
        uint32_t total = msg->msgh_size;
        if (send_size && send_size < total) total = send_size;
        uint32_t xpc_off = 0;
        const uint8_t *xpc = bfix_find_xpc_payload((const uint8_t *)msg, total, &xpc_off);
        if (xpc) {
            int f1 = 0, f2 = 0;
            uint64_t routine = bfix_xpc_extract_int64_key(xpc, total - xpc_off, "routine", &f1);
            pre_handle = bfix_xpc_extract_int64_key(xpc, total - xpc_off, "handle", &f2);
            if (routine == 805 && f2) {
                if (bfix_xpc_extract_string_key_copy(xpc, total - xpc_off, "name",
                                                     pre_name, sizeof(pre_name))) {
                    bfix_handle_map_set(pre_handle, pre_name);
                    bfix_checkin_map_set(msg->msgh_local_port, pre_name);
                    if (strstr(pre_name, "processinfoservice")) pre_is_pi_checkin = 1;
                }
            }
        }
    }

    /* Track CA MIG sends + dump RegisterClient descriptors */
    if ((option & MACH_SEND_MSG) && msg) {
        mach_msg_header_t *hdr = (mach_msg_header_t *)msg;
        if (hdr->msgh_id >= 40000 && hdr->msgh_id < 41000) {
            static int _ca_send_count = 0;
            if (_ca_send_count < 30) {
                _ca_send_count++;
                int is_complex = (hdr->msgh_bits & MACH_MSGH_BITS_COMPLEX) != 0;
                bfix_log("CA_SEND[%d]: id=%u size=%u port=%u complex=%d",
                    _ca_send_count, hdr->msgh_id, hdr->msgh_size,
                    hdr->msgh_remote_port, is_complex);

                /* Dump descriptors for RegisterClient (40203) */
                if (hdr->msgh_id == 40203 && is_complex) {
                    mach_msg_body_t *body = (mach_msg_body_t *)(hdr + 1);
                    bfix_log("  REGISTER: %u descriptors", body->msgh_descriptor_count);
                    uint8_t *dp = (uint8_t *)(body + 1);
                    for (uint32_t d = 0; d < body->msgh_descriptor_count && d < 8; d++) {
                        uint32_t dtype = *(uint32_t *)(dp + 8) & 0xFF; /* type at offset 8 in descriptor */
                        if (dtype == MACH_MSG_PORT_DESCRIPTOR) {
                            mach_msg_port_descriptor_t *pd = (mach_msg_port_descriptor_t *)dp;
                            bfix_log("  desc[%u]: PORT name=%u disp=%u type=%u",
                                d, pd->name, pd->disposition, pd->type);
                            dp += sizeof(mach_msg_port_descriptor_t);
                        } else if (dtype == MACH_MSG_OOL_DESCRIPTOR) {
                            mach_msg_ool_descriptor_t *od = (mach_msg_ool_descriptor_t *)dp;
                            bfix_log("  desc[%u]: OOL addr=%p size=%u copy=%u dealloc=%u",
                                d, od->address, od->size, od->copy, od->deallocate);
                            dp += sizeof(mach_msg_ool_descriptor_t);
                        } else {
                            bfix_log("  desc[%u]: type=%u (raw: %08x %08x %08x)",
                                d, dtype,
                                *(uint32_t *)dp, *(uint32_t *)(dp+4), *(uint32_t *)(dp+8));
                            dp += 12; /* minimum descriptor size */
                        }
                    }
                }
            }
        }
    }

    kern_return_t kr = g_orig_mach_msg(msg, option, send_size, rcv_size, rcv_name, timeout, notify);

    /* Handle custom "render now" message (49999) in backboardd */
    if ((option & MACH_RCV_MSG) && kr == KERN_SUCCESS && msg && msg->msgh_id == 49999) {
        static int _is_bbd_rn = -1;
        if (_is_bbd_rn == -1) {
            const char *pn = getprogname();
            _is_bbd_rn = (pn && strstr(pn, "backboardd")) ? 1 : 0;
        }
        if (_is_bbd_rn) {
            static void *_rft_fn = NULL;
            static void *_rft_srv = NULL;
            static int _rft_init = 0;
            static int _rft_count = 0;

            if (!_rft_init) {
                _rft_init = 1;
                /* Find render_for_time via QuartzCore base */
                void *sym = dlsym(RTLD_DEFAULT, "CARenderServerGetServerPort");
                if (sym) {
                    Dl_info dinfo;
                    if (dladdr(sym, &dinfo) && dinfo.dli_fbase) {
                        uintptr_t qc_base = (uintptr_t)dinfo.dli_fbase;
                        _rft_fn = (void *)(qc_base + 0x1287ea);
                        bfix_log("RENDER_NOW: qc_base=0x%lx rft_fn=%p",
                                (unsigned long)qc_base, _rft_fn);
                    }
                }
                /* Find server C++ object via CAWindowServer */
                Class wsCls = (Class)objc_getClass("CAWindowServer");
                if (wsCls) {
                    id ws = ((id(*)(id, SEL))objc_msgSend)((id)wsCls, sel_registerName("server"));
                    if (ws) {
                        id disps = ((id(*)(id, SEL))objc_msgSend)(ws, sel_registerName("displays"));
                        unsigned long dcnt = disps ? ((unsigned long(*)(id, SEL))objc_msgSend)(
                            disps, sel_registerName("count")) : 0;
                        if (dcnt > 0) {
                            id disp = ((id(*)(id, SEL, unsigned long))objc_msgSend)(
                                disps, sel_registerName("objectAtIndex:"), 0UL);
                            Ivar iI = class_getInstanceVariable(object_getClass(disp), "_impl");
                            if (iI) {
                                void *impl = *(void **)((uint8_t *)disp + ivar_getOffset(iI));
                                if (impl) {
                                    _rft_srv = *(void **)((uint8_t *)impl + 0x40);
                                    bfix_log("RENDER_NOW: server_cpp=%p", _rft_srv);
                                }
                            }
                        }
                    }
                }
                if (_rft_fn && _rft_srv)
                    bfix_log("RENDER_NOW: ready to render");
                else
                    bfix_log("RENDER_NOW: FAILED init fn=%p srv=%p", _rft_fn, _rft_srv);
            }

            if (_rft_fn && _rft_srv) {
                _rft_count++;
                extern double CACurrentMediaTime(void);
                typedef void (*RFTFn)(void*, double, void*, unsigned int);
                ((RFTFn)_rft_fn)(_rft_srv, CACurrentMediaTime(), NULL, 0);

                if (_rft_count <= 5 || _rft_count % 100 == 0) {
                    bfix_log("RENDER_NOW[%d]: render_for_time called", _rft_count);

                    /* Check pixels on first few calls */
                    if (_rft_count <= 5) {
                        void *swctx = *(void **)((uint8_t *)_rft_srv + 0xb8);
                        if (swctx) {
                            void *pixbuf = *(void **)((uint8_t *)swctx + 0x668);
                            if (pixbuf && (uint64_t)pixbuf > 0x100000) {
                                uint8_t *pp = (uint8_t *)pixbuf;
                                int nz = 0;
                                for (int i = 0; i < 2000; i++)
                                    if (pp[i*4]||pp[i*4+1]||pp[i*4+2]) nz++;
                                bfix_log("RENDER_NOW[%d]: %d/2000 nz RGB px[0]=(%u,%u,%u,%u)",
                                    _rft_count, nz, pp[0], pp[1], pp[2], pp[3]);
                            }
                        }
                    }
                }
            }

            /* Don't let MIG dispatch see this message — return to receive loop */
            /* We need to re-receive, so modify the msg to be a no-op */
            msg->msgh_id = 0; /* MIG will ignore id=0 */
        }
    }

    /* Track CA MIG messages RECEIVED in backboardd */
    if ((option & MACH_RCV_MSG) && kr == KERN_SUCCESS && msg) {
        static int _recv_is_bbd = -1;
        if (_recv_is_bbd == -1) {
            const char *pn = getprogname();
            _recv_is_bbd = (pn && strstr(pn, "backboardd")) ? 1 : 0;
        }
        if (_recv_is_bbd && msg->msgh_id > 40000) {
            static int _ca_recv_count = 0;

            /* Log kick_server (40001) receipt to verify it's dispatched */
            if (msg->msgh_id == 40001) {
                static int _kick_recv = 0;
                _kick_recv++;
                if (_kick_recv <= 10 || _kick_recv % 200 == 0) {
                    char _kt[64] = {0};
                    pthread_getname_np(pthread_self(), _kt, sizeof(_kt));
                    bfix_log("KICK_RECV[%d]: msg_id=40001 on thread='%s' port=%u",
                        _kick_recv, _kt[0] ? _kt : "(unnamed)", msg->msgh_local_port);
                }
            }

            /* Always log 40002/40003 commit data messages with thread info */
            if (msg->msgh_id == 40002 || msg->msgh_id == 40003) {
                int is_complex = (msg->msgh_bits & MACH_MSGH_BITS_COMPLEX) != 0;
                /* Identify which thread receives commits */
                char _tname[64] = {0};
                pthread_getname_np(pthread_self(), _tname, sizeof(_tname));
                static int _commit_thread_logged = 0;
                if (_commit_thread_logged < 5) {
                    _commit_thread_logged++;
                    bfix_log("COMMIT_RECV: id=%u size=%u port=%u complex=%d thread='%s' tid=%p",
                        msg->msgh_id, msg->msgh_size, msg->msgh_local_port, is_complex,
                        _tname[0] ? _tname : "(unnamed)", (void *)pthread_self());
                } else {
                    bfix_log("COMMIT_RECV: id=%u size=%u port=%u complex=%d",
                        msg->msgh_id, msg->msgh_size, msg->msgh_local_port, is_complex);
                }
                /* Schedule render_for_time on the next mach_msg call */
                g_commit_render_pending = 1;

                /* Check if commit arrives on server port vs context port.
                 * If on server port, context_by_server_port returns NULL
                 * and run_command_stream processes with no context → commands lost. */
                {
                    static mach_port_t _cached_srv_port = 0;
                    static int _port_chk_n = 0;
                    if (!_cached_srv_port) {
                        typedef mach_port_t (*GSPFn)(void);
                        GSPFn gsp = (GSPFn)dlsym(RTLD_DEFAULT, "CARenderServerGetServerPort");
                        if (gsp) _cached_srv_port = gsp();
                    }
                    if (_port_chk_n < 10) {
                        _port_chk_n++;
                        bfix_log("COMMIT_PORT: local=%u srv=%u %s",
                            msg->msgh_local_port, _cached_srv_port,
                            (msg->msgh_local_port == _cached_srv_port)
                                ? "ON_SERVER(ctx=NULL!)" : "ON_CONTEXT(ok)");
                    }
                }

                /* Minimal diagnostic: log commit port + server ctx count (no binding code) */
                static int _port_map_done = 0;
                if (!_port_map_done && g_pcr_rft_srv) {
                    _port_map_done = 1;
                    void *_srv = g_pcr_rft_srv;
                    uint64_t _cc = *(uint64_t *)((uint8_t *)_srv + 0x78);
                    bfix_log("CLEAN_DIAG: server ctx_count=%llu local_port=%u",
                        (unsigned long long)_cc, msg->msgh_local_port);
                    /* Display binding code stripped for clean baseline.
                     * See commits 8d9f0bc..4abc03a for full investigation. */
                }

                /* Check for magic 0x9C42/0x9C43 at expected offset */
                uint8_t *raw = (uint8_t *)msg;
                if (msg->msgh_size >= 0x18) {
                    uint32_t inner_id = *(uint32_t *)(raw + 0x14);
                    bfix_log("COMMIT_RECV: inner_id=0x%x (expect 0x9C42 or 0x9C43)", inner_id);
                }
                if (is_complex) {
                    mach_msg_body_t *body = (mach_msg_body_t *)(msg + 1);
                    bfix_log("COMMIT_RECV: desc_count=%u", body->msgh_descriptor_count);
                    /* Dump descriptor types */
                    uint8_t *dp = (uint8_t *)(body + 1);
                    for (uint32_t d = 0; d < body->msgh_descriptor_count && d < 4; d++) {
                        uint32_t dtype = *(uint32_t *)(dp + 8) & 0xFF;
                        if (dtype == MACH_MSG_PORT_DESCRIPTOR) {
                            mach_msg_port_descriptor_t *pd = (mach_msg_port_descriptor_t *)dp;
                            bfix_log("COMMIT_RECV: desc[%u] PORT name=%u disp=%u", d, pd->name, pd->disposition);
                            dp += sizeof(mach_msg_port_descriptor_t);
                        } else if (dtype == MACH_MSG_OOL_DESCRIPTOR) {
                            mach_msg_ool_descriptor_t *od = (mach_msg_ool_descriptor_t *)dp;
                            bfix_log("COMMIT_RECV: desc[%u] OOL addr=%p size=%u", d, od->address, od->size);
                            dp += sizeof(mach_msg_ool_descriptor_t);
                        } else {
                            bfix_log("COMMIT_RECV: desc[%u] type=%u", d, dtype);
                            dp += 12;
                        }
                    }
                }
            }
            if (_ca_recv_count < 30) {
                _ca_recv_count++;
                int is_complex = (msg->msgh_bits & MACH_MSGH_BITS_COMPLEX) != 0;
                if (is_complex) {
                    mach_msg_body_t *body = (mach_msg_body_t *)(msg + 1);
                    bfix_log("CA_RECV[%d]: id=%u size=%u port=%u COMPLEX desc=%u",
                        _ca_recv_count, msg->msgh_id, msg->msgh_size,
                        msg->msgh_local_port, body->msgh_descriptor_count);
                } else {
                    bfix_log("CA_RECV[%d]: id=%u size=%u port=%u SIMPLE",
                        _ca_recv_count, msg->msgh_id, msg->msgh_size,
                        msg->msgh_local_port);
                }

                /* Probe 40203 (RegisterClient) — try vm_read with received task port */
                if (msg->msgh_id == 40203 && (msg->msgh_bits & MACH_MSGH_BITS_COMPLEX)) {
                    mach_msg_body_t *rbody = (mach_msg_body_t *)(msg + 1);
                    uint32_t ndesc = rbody->msgh_descriptor_count;
                    uint8_t *dp = (uint8_t *)(rbody + 1);
                    bfix_log("40203_RECV: %u descriptors, msg_size=%u", ndesc, msg->msgh_size);
                    for (uint32_t d = 0; d < ndesc && d < 8; d++) {
                        uint32_t dtype = *(uint32_t *)(dp + 8) & 0xFF;
                        if (dtype == MACH_MSG_PORT_DESCRIPTOR) {
                            mach_msg_port_descriptor_t *pd = (mach_msg_port_descriptor_t *)dp;
                            mach_port_type_t pt = 0;
                            kern_return_t tkr = mach_port_type(mach_task_self(), pd->name, &pt);
                            bfix_log("40203_RECV: desc[%u] PORT name=%u disp=%u ptype=0x%x (kr=%d)",
                                d, pd->name, pd->disposition, pt, tkr);

                            /* If this looks like a task port (send right, no receive), try vm_read */
                            if (tkr == KERN_SUCCESS && (pt & MACH_PORT_TYPE_SEND) && d == 0) {
                                vm_offset_t rd = 0;
                                mach_msg_type_number_t rc = 0;
                                kern_return_t vkr = vm_read(pd->name, 0x100000000ULL, 64, &rd, &rc);
                                bfix_log("40203_RECV: VM_READ(port=%u, 0x100000000) = %d (%s) got=%u",
                                    pd->name, vkr, mach_error_string(vkr), rc);
                                if (vkr == KERN_SUCCESS && rc > 0) {
                                    uint8_t *rp = (uint8_t *)rd;
                                    bfix_log("40203_RECV: first 16 bytes: %02x%02x%02x%02x %02x%02x%02x%02x %02x%02x%02x%02x %02x%02x%02x%02x",
                                        rp[0],rp[1],rp[2],rp[3],rp[4],rp[5],rp[6],rp[7],
                                        rp[8],rp[9],rp[10],rp[11],rp[12],rp[13],rp[14],rp[15]);
                                    vm_deallocate(mach_task_self(), rd, rc);
                                } else {
                                    /* Also try scanning for any readable region in the task */
                                    vm_address_t scan = 0;
                                    vm_size_t ssize = 0;
                                    natural_t depth = 0;
                                    struct vm_region_submap_info_64 sinfo;
                                    mach_msg_type_number_t scnt = VM_REGION_SUBMAP_INFO_COUNT_64;
                                    kern_return_t skr = vm_region_recurse_64(pd->name, &scan, &ssize,
                                        &depth, (vm_region_info_64_t)&sinfo, &scnt);
                                    bfix_log("40203_RECV: vm_region_recurse on port=%u: kr=%d addr=0x%lx size=0x%lx",
                                        pd->name, skr, (unsigned long)scan, (unsigned long)ssize);
                                }
                            }
                            dp += sizeof(mach_msg_port_descriptor_t);
                        } else if (dtype == MACH_MSG_OOL_DESCRIPTOR) {
                            mach_msg_ool_descriptor_t *od = (mach_msg_ool_descriptor_t *)dp;
                            bfix_log("40203_RECV: desc[%u] OOL addr=%p size=%u", d, od->address, od->size);
                            dp += sizeof(mach_msg_ool_descriptor_t);
                        } else {
                            bfix_log("40203_RECV: desc[%u] type=%u", d, dtype);
                            dp += 12;
                        }
                    }
                }

                /* Dump 40206 (commit notification) body */
                if (msg->msgh_id == 40206 && msg->msgh_size >= 36) {
                    uint32_t *body = (uint32_t *)((uint8_t *)msg + 24); /* after header */
                    bfix_log("MSG_40206: body: %08x %08x %08x",
                        body[0], body[1], body[2]);
                    /* Also as uint64 + uint32 */
                    uint64_t addr64 = *(uint64_t *)body;
                    uint32_t len32 = body[2];
                    bfix_log("MSG_40206: addr=0x%llx len=%u",
                        (unsigned long long)addr64, len32);
                }
            }
        }
    }

    if (!is_assertiond) return kr;

    /* Post-recv trace: capture the processinfoservice port from routine=805 reply. */
    if ((option & MACH_RCV_MSG) && kr == KERN_SUCCESS && msg) {
        uint32_t total = msg->msgh_size;
        if (msg->msgh_id == BFIX_XPC_PIPE_REPLY_MSG_ID) {
            uint32_t xpc_off = 0;
            const uint8_t *xpc = bfix_find_xpc_payload((const uint8_t *)msg, total, &xpc_off);
            if (xpc) {
                int f1 = 0, f2 = 0;
                uint64_t routine = bfix_xpc_extract_int64_key(xpc, total - xpc_off, "routine", &f1);
                uint64_t handle = bfix_xpc_extract_int64_key(xpc, total - xpc_off, "handle", &f2);
                if (routine == 805) {
                    const char *svc = bfix_checkin_map_get(msg->msgh_local_port);
                    if (svc && strstr(svc, "com.apple.assertiond.processinfoservice")) {
                        if (g_processinfoservice_port == MACH_PORT_NULL) {
                            uint32_t dc = 0;
                            mach_port_t p = bfix_extract_first_port_desc_name(msg, total, &dc);
                            if (p != MACH_PORT_NULL) {
                                g_processinfoservice_port = p;
                                bfix_log("[bfix] PI PORT CAPTURED: svc=%s reply_port=0x%x handle=%llu port=0x%x desc_count=%u\n",
                                         svc, msg->msgh_local_port,
                                         (unsigned long long)(f2 ? handle : 0),
                                         p, dc);
                            } else if (bfix_trace_pi_enabled()) {
                                bfix_log("[bfix] PI PORT CAPTURE FAILED: svc=%s reply_port=0x%x (no port desc)\n",
                                         svc, msg->msgh_local_port);
                            }
                        }
                        /* One-shot mapping. */
                        bfix_checkin_map_clear(msg->msgh_local_port);
                    }
                }
            }
        }

        /* Log messages received on processinfoservice port + track reply port. */
        if (g_processinfoservice_port != MACH_PORT_NULL &&
            msg->msgh_local_port == g_processinfoservice_port) {
            if (bfix_trace_pi_enabled()) {
                bfix_trace_received_on_pi_port(msg, total);
            }
            if (msg->msgh_remote_port != MACH_PORT_NULL) {
                bfix_pending_add(msg->msgh_remote_port, msg->msgh_id);
            }
        }
    }

    /* Post-send trace: did we send a reply to a pending reply port? */
    if ((option & MACH_SEND_MSG) && msg && bfix_trace_pi_enabled()) {
        uint32_t req_id = 0;
        if (bfix_pending_match_and_clear(msg->msgh_remote_port, &req_id)) {
            bfix_log("[bfix] PI REPLY SENT: req_id=0x%x reply_to=0x%x send_id=0x%x kr=0x%x\n",
                     req_id, msg->msgh_remote_port, msg->msgh_id, kr);
        } else if (pre_is_pi_checkin) {
            bfix_log("[bfix] PI CHECKIN SEND: name=%s handle=%llu kr=0x%x\n",
                     pre_name, (unsigned long long)pre_handle, kr);
        }
    }

    return kr;
}

/* ================================================================
 * SpringBoard strict-lifecycle fix: synthesize BSProcessHandle
 *
 * In strict mode with real FBSWorkspace, SpringBoard's FrontBoard code path
 * can abort early if FBApplicationProcess/_FBProcess has a nil BSProcessHandle
 * (normally provided by CoreSimulator process launch/registration).
 *
 * We patch SpringBoard only (guarded by ROSETTASIM_SB_HANDLE_FIX=1):
 *   - Swizzle -[FBApplicationProcess _queue_bootstrapAndExecWithContext:]
 *   - If its FBProcess has a nil handle, create one via
 *       +[BSProcessHandle processHandleForPID:]
 *     using PID from the process/context or /tmp/rosettasim_app_pid.
 * ================================================================ */

static int bfix_is_springboard_process(void) {
    const char *pn = getprogname();
    return (pn && strstr(pn, "SpringBoard")) ? 1 : 0;
}

static int bfix_sb_handle_fix_enabled(void) {
    const char *e = getenv("ROSETTASIM_SB_HANDLE_FIX");
    return (e && e[0] == '1');
}

static int bfix_read_int_file(const char *path) {
    if (!path) return 0;
    FILE *f = fopen(path, "r");
    if (!f) return 0;
    int v = 0;
    if (fscanf(f, "%d", &v) != 1) v = 0;
    fclose(f);
    return v;
}

static int bfix_get_pid_from_obj(id obj) {
    if (!obj) return 0;
    SEL s = sel_registerName("pid");
    if ([obj respondsToSelector:s]) {
        return (int)((int(*)(id, SEL))objc_msgSend)(obj, s);
    }
    s = sel_registerName("processIdentifier");
    if ([obj respondsToSelector:s]) {
        return (int)((int(*)(id, SEL))objc_msgSend)(obj, s);
    }
    s = sel_registerName("PID");
    if ([obj respondsToSelector:s]) {
        return (int)((int(*)(id, SEL))objc_msgSend)(obj, s);
    }
    return 0;
}

static id bfix_create_bsprocesshandle_for_pid(int pid) {
    if (pid <= 0) return nil;
    Class cls = objc_getClass("BSProcessHandle");
    if (!cls) return nil;
    SEL s = sel_registerName("processHandleForPID:");
    if (class_respondsToSelector(cls, s)) {
        return ((id(*)(id, SEL, int))objc_msgSend)((id)cls, s, pid);
    }
    s = sel_registerName("processHandleForPid:");
    if (class_respondsToSelector(cls, s)) {
        return ((id(*)(id, SEL, int))objc_msgSend)((id)cls, s, pid);
    }
    return nil;
}

static int bfix_set_process_handle(id process, id handle) {
    if (!process || !handle) return 0;

    SEL setSel = sel_registerName("setHandle:");
    if ([process respondsToSelector:setSel]) {
        ((void(*)(id, SEL, id))objc_msgSend)(process, setSel, handle);
        return 1;
    }

    /* KVC fallback (safe under @try) */
    @try {
        [process setValue:handle forKey:@"handle"];
        return 1;
    } @catch (id ex) {
        /* ignore */
    }

    Ivar iv = class_getInstanceVariable(object_getClass(process), "_handle");
    if (iv) {
        object_setIvar(process, iv, handle);
        return 1;
    }
    return 0;
}

static IMP g_orig_fbapp_queue_bootstrap = NULL;
static int g_sb_handle_fix_swizzled = 0;

static void replacement_FBApplicationProcess_queue_bootstrap(id self, SEL _cmd, id context) {
    static int log_budget = 100;

    bfix_log("[bfix] SB_HANDLE_FIX: ENTRY self=%p _cmd=%s ctx=%p budget=%d\n",
             (void *)self, sel_getName(_cmd), (void *)context, log_budget);

    if (bfix_sb_handle_fix_enabled() && log_budget > 0) {
        id process = nil;
        SEL procSel = sel_registerName("process");
        if ([self respondsToSelector:procSel]) {
            process = ((id(*)(id, SEL))objc_msgSend)(self, procSel);
        }
        if (!process) {
            Ivar iv = class_getInstanceVariable(object_getClass(self), "_process");
            if (iv) process = object_getIvar(self, iv);
        }

        id handle = nil;
        if (process) {
            SEL hSel = sel_registerName("handle");
            if ([process respondsToSelector:hSel]) {
                handle = ((id(*)(id, SEL))objc_msgSend)(process, hSel);
            }
            if (!handle) {
                Ivar hiv = class_getInstanceVariable(object_getClass(process), "_handle");
                if (hiv) handle = object_getIvar(process, hiv);
            }
        }

        if (!handle) {
            int pid = bfix_get_pid_from_obj(process);
            if (pid <= 0) pid = bfix_get_pid_from_obj(context);
            if (pid <= 0) pid = bfix_read_int_file("/tmp/rosettasim_app_pid");

            id newHandle = bfix_create_bsprocesshandle_for_pid(pid);
            if (newHandle && process) {
                int ok = bfix_set_process_handle(process, newHandle);
                bfix_log("[bfix] SB_HANDLE_FIX: set handle=%p pid=%d ok=%d proc=%p ctx=%p\n",
                         newHandle, pid, ok, process, context);
                log_budget--;
            } else {
                bfix_log("[bfix] SB_HANDLE_FIX: unable to create handle (pid=%d proc=%p ctx=%p)\n",
                         pid, process, context);
                log_budget--;
            }
        }
    }

    if (g_orig_fbapp_queue_bootstrap) {
        ((void(*)(id, SEL, id))g_orig_fbapp_queue_bootstrap)(self, _cmd, context);
    }
}

static void bfix_try_install_springboard_handle_fix(void) {
    if (!bfix_is_springboard_process()) return;
    if (!bfix_sb_handle_fix_enabled()) return;
    if (g_sb_handle_fix_swizzled) return;

    Class cls = objc_getClass("FBApplicationProcess");
    if (!cls) return;

    SEL sel = sel_registerName("_queue_bootstrapAndExecWithContext:");
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;

    g_orig_fbapp_queue_bootstrap = method_getImplementation(m);
    method_setImplementation(m, (IMP)replacement_FBApplicationProcess_queue_bootstrap);
    g_sb_handle_fix_swizzled = 1;
    bfix_log("[bfix] SB_HANDLE_FIX: installed FBApplicationProcess swizzle\n");
}

static void bfix_install_springboard_handle_fix_async(void) {
    if (!bfix_is_springboard_process()) return;
    if (!bfix_sb_handle_fix_enabled()) return;

    /* Poll for FBApplicationProcess to load; install once. */
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        for (int i = 0; i < 200; i++) { /* up to ~10s */
            if (g_sb_handle_fix_swizzled) return;
            bfix_try_install_springboard_handle_fix();
            if (g_sb_handle_fix_swizzled) return;
            usleep(50000);
        }
        bfix_log("[bfix] SB_HANDLE_FIX: FAILED to install (FBApplicationProcess not found)\n");
    });
}
static void patch_client_port(mach_port_t port_value) {
    /* Find the real CARenderServerGetClientPort function */
    void *fn = dlsym(RTLD_DEFAULT, "CARenderServerGetClientPort");
    if (!fn) {
        bfix_log("[bfix] patch: CARenderServerGetClientPort not found\n");
        return;
    }
    bfix_log("[bfix] patch: CARenderServerGetClientPort at %p\n", fn);

    /* Read the x86_64 code to find the RIP-relative reference to the static var.
     * We look for:
     *   8B 05 xx xx xx xx  = mov eax, [rip + disp32]
     *   48 8B 05 xx xx xx xx = mov rax, [rip + disp32]
     *   Any instruction with a [rip + disp32] pattern
     */
    const uint8_t *code = (const uint8_t *)fn;
    mach_port_t *var_addr = NULL;

    /* Scan first 256 bytes for RIP-relative mov patterns */
    for (int i = 0; i < 256; i++) {
        /* Check for: 8B 05 xx xx xx xx (mov eax, [rip+disp32]) */
        if (code[i] == 0x8B && code[i+1] == 0x05) {
            int32_t disp = *(int32_t *)(code + i + 2);
            uintptr_t target = (uintptr_t)(code + i + 6) + disp;
            var_addr = (mach_port_t *)target;
            bfix_log("[bfix] patch: found mov eax,[rip+0x%x] at +%d → var at %p\n",
                     disp, i, (void *)var_addr);
            break;
        }
        /* Check for: 48 8B 05 xx xx xx xx (mov rax, [rip+disp32]) */
        if (code[i] == 0x48 && code[i+1] == 0x8B && code[i+2] == 0x05) {
            int32_t disp = *(int32_t *)(code + i + 3);
            uintptr_t target = (uintptr_t)(code + i + 7) + disp;
            var_addr = (mach_port_t *)target;
            bfix_log("[bfix] patch: found mov rax,[rip+0x%x] at +%d → var at %p\n",
                     disp, i, (void *)var_addr);
            break;
        }
    }

    if (var_addr) {
        /* Found a simple variable reference — try data patch */
        mach_port_t old_val = *var_addr;
        bfix_log("[bfix] patch: var value = 0x%x (might be pointer, not port)\n", old_val);
        if (old_val == 0) {
            *var_addr = port_value;
            bfix_log("[bfix] patch: set variable = 0x%x\n", port_value);
        }
    }

    /* More reliable approach: REWRITE the function to always return our port.
     * Overwrite first bytes with: mov eax, <port_value>; ret
     * x86_64: B8 xx xx xx xx C3 (6 bytes) */
    bfix_log("[bfix] patch: rewriting function at %p to return 0x%x\n", fn, port_value);

    /* Make the code page writable */
    vm_address_t page = (vm_address_t)fn & ~0xFFF;
    kern_return_t pkr = vm_protect(mach_task_self(), page, 0x1000,
                                    FALSE, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_EXECUTE);
    if (pkr != KERN_SUCCESS) {
        bfix_log("[bfix] patch: vm_protect failed: 0x%x\n", pkr);
        return;
    }

    /* Write: mov eax, <port_value>  (B8 + 4-byte immediate) */
    uint8_t *fn_bytes = (uint8_t *)fn;
    fn_bytes[0] = 0xB8; /* mov eax, imm32 */
    fn_bytes[1] = (port_value) & 0xFF;
    fn_bytes[2] = (port_value >> 8) & 0xFF;
    fn_bytes[3] = (port_value >> 16) & 0xFF;
    fn_bytes[4] = (port_value >> 24) & 0xFF;
    fn_bytes[5] = 0xC3; /* ret */

    /* Restore page protections */
    vm_protect(mach_task_self(), page, 0x1000,
               FALSE, VM_PROT_READ | VM_PROT_EXECUTE);

    bfix_log("[bfix] patch: function rewritten — CARenderServerGetClientPort() now returns 0x%x\n",
             port_value);

    /* Verify by calling the function */
    mach_port_t verify = CARenderServerGetClientPort(0);
    bfix_log("[bfix] patch: verify call = 0x%x %s\n", verify,
             verify == port_value ? "OK" : "FAILED (Rosetta may cache old translation)");
}

/* --- Runtime binary patching for intra-library bootstrap calls ---
 *
 * DYLD interposition only catches cross-library calls. When libxpc's
 * _xpc_pipe_create calls bootstrap_look_up internally, the call goes
 * directly to the function body (not through GOT), bypassing interposition.
 *
 * Fix: Find the original function in the loaded Mach-O image and overwrite
 * its first 12 bytes with a trampoline to our replacement. This catches
 * ALL calls — both intra-library and cross-library.
 */

/* Find a symbol in a Mach-O 64-bit image by walking its symbol table.
 * This bypasses DYLD interposition, which only affects GOT entries. */
static void *find_symbol_in_macho(const struct mach_header_64 *header,
                                   intptr_t slide,
                                   const char *symbol_name) {
    const uint8_t *ptr = (const uint8_t *)header + sizeof(struct mach_header_64);
    const struct symtab_command *symtab_cmd = NULL;
    const struct segment_command_64 *linkedit_seg = NULL;

    for (uint32_t i = 0; i < header->ncmds; i++) {
        const struct load_command *cmd = (const struct load_command *)ptr;
        if (cmd->cmd == LC_SYMTAB) {
            symtab_cmd = (const struct symtab_command *)cmd;
        } else if (cmd->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)cmd;
            if (strcmp(seg->segname, SEG_LINKEDIT) == 0) {
                linkedit_seg = seg;
            }
        }
        ptr += cmd->cmdsize;
    }

    if (!symtab_cmd || !linkedit_seg) return NULL;

    /* Symbol and string tables live in __LINKEDIT */
    uintptr_t linkedit_base = (uintptr_t)slide + linkedit_seg->vmaddr
                              - linkedit_seg->fileoff;
    const struct nlist_64 *symtab =
        (const struct nlist_64 *)(linkedit_base + symtab_cmd->symoff);
    const char *strtab = (const char *)(linkedit_base + symtab_cmd->stroff);

    for (uint32_t j = 0; j < symtab_cmd->nsyms; j++) {
        if ((symtab[j].n_type & N_TYPE) != N_SECT) continue;
        uint32_t strx = symtab[j].n_un.n_strx;
        if (strx == 0) continue;
        if (strcmp(strtab + strx, symbol_name) == 0) {
            return (void *)(symtab[j].n_value + slide);
        }
    }

    return NULL;
}

/* Find the original (non-interposed) address of a function.
 * Searches all loaded Mach-O images EXCEPT bootstrap_fix.dylib. */
static void *find_original_function(const char *func_name) {
    char mangled[256];
    snprintf(mangled, sizeof(mangled), "_%s", func_name);

    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *image_name = _dyld_get_image_name(i);
        if (!image_name) continue;
        if (strstr(image_name, "bootstrap_fix")) continue;

        const struct mach_header *mh = _dyld_get_image_header(i);
        if (!mh || mh->magic != MH_MAGIC_64) continue;

        intptr_t slide = _dyld_get_image_vmaddr_slide(i);
        void *sym = find_symbol_in_macho(
            (const struct mach_header_64 *)mh, slide, mangled);
        if (sym) {
            bfix_log("[bfix] found original '%s' at %p in %s\n",
                     func_name, sym, image_name);
            return sym;
        }
    }

    bfix_log("[bfix] WARNING: original '%s' not found\n", func_name);
    return NULL;
}

/* Write x86_64 trampoline at target address.
 * movabs rax, <replacement_addr>   ; 48 B8 <8 bytes>
 * jmp rax                           ; FF E0
 * Total: 12 bytes */
static int write_trampoline(void *target, void *replacement, const char *name) {
    if (!target || !replacement || target == replacement) {
        bfix_log("[bfix] trampoline '%s': skip (target=%p repl=%p)\n",
                 name, target, replacement);
        return -1;
    }

    bfix_log("[bfix] trampoline '%s': %p → %p\n", name, target, replacement);

    /* Make code page writable (2 pages in case patch spans boundary) */
    vm_address_t page = (vm_address_t)target & ~(vm_address_t)0xFFF;
    kern_return_t kr = vm_protect(mach_task_self(), page, 0x2000, FALSE,
                                   VM_PROT_READ | VM_PROT_WRITE | VM_PROT_EXECUTE);
    if (kr != KERN_SUCCESS) {
        kr = vm_protect(mach_task_self(), page, 0x1000, FALSE,
                        VM_PROT_READ | VM_PROT_WRITE | VM_PROT_EXECUTE);
        if (kr != KERN_SUCCESS) {
            bfix_log("[bfix] trampoline '%s': vm_protect failed 0x%x\n", name, kr);
            return -1;
        }
    }

    uint8_t *code = (uint8_t *)target;
    uint64_t addr = (uint64_t)(uintptr_t)replacement;

    code[0]  = 0x48;           /* REX.W */
    code[1]  = 0xB8;           /* mov rax, imm64 */
    memcpy(&code[2], &addr, 8);
    code[10] = 0xFF;           /* jmp rax */
    code[11] = 0xE0;

    /* Verify the write by reading back */
    if (code[0] != 0x48 || code[1] != 0xB8 || code[10] != 0xFF || code[11] != 0xE0) {
        bfix_log("[bfix] trampoline '%s': WRITE VERIFY FAILED\n", name);
    }

    /* Restore protections — vm_protect RW→RX flushes Rosetta translation cache */
    vm_protect(mach_task_self(), page, 0x2000, FALSE,
               VM_PROT_READ | VM_PROT_EXECUTE);

    /* Force Rosetta to re-translate by invalidating the instruction cache.
     * On Apple Silicon under Rosetta 2, sys_icache_invalidate signals that
     * translated code at this address is stale. */
    extern void sys_icache_invalidate(void *start, size_t len);
    sys_icache_invalidate(target, 12);

    bfix_log("[bfix] trampoline '%s': OK (icache invalidated)\n", name);
    return 0;
}

/* Replacement for _xpc_connection_check_in inside libxpc.
 *
 * The original LISTENER path builds a 52-byte Mach registration message and
 * sends it to launchd via dispatch_mach_connect. Since we don't have launchd,
 * we bypass the registration message and just call dispatch_mach_connect
 * directly with NULL message — same as the non-listener path.
 *
 * Connection object layout (from disassembly):
 *   0x28: state (6 = success)
 *   0x34: port1 (recv_right for listener, send_right for client)
 *   0x3c: port2 (extra_port)
 *   0x58: dispatch_mach_channel (void *)
 *   0xd9: flags byte (bit 0x2 = LISTENER mode)
 */
typedef void (*dispatch_mach_connect_fn)(void *channel, mach_port_t port1,
                                          mach_port_t port2, void *msg);
static dispatch_mach_connect_fn g_dispatch_mach_connect = NULL;
static dispatch_mach_connect_fn g_orig_dispatch_mach_connect = NULL;

/* ================================================================
 * Pending listener table — maps send_port → recv_port for known
 * LISTENER services. When dispatch_mach_connect is called with a
 * send right (from look_up), we swap it with the recv right
 * (from check_in) so the listener gets the correct port.
 * ================================================================ */
#define MAX_PENDING_LISTENERS 8
static struct {
    mach_port_t send_port;
    mach_port_t recv_port;
    char name[128];
    int pending;
} g_pending_listeners[MAX_PENDING_LISTENERS];

static void register_pending_listener(const char *name, mach_port_t send_port, mach_port_t recv_port) {
    for (int i = 0; i < MAX_PENDING_LISTENERS; i++) {
        if (!g_pending_listeners[i].pending) {
            g_pending_listeners[i].send_port = send_port;
            g_pending_listeners[i].recv_port = recv_port;
            strncpy(g_pending_listeners[i].name, name, 127);
            g_pending_listeners[i].name[127] = '\0';
            g_pending_listeners[i].pending = 1;
            bfix_log("[bfix] PENDING_LISTENER: '%s' send=0x%x recv=0x%x\n",
                     name, send_port, recv_port);
            return;
        }
    }
    bfix_log("[bfix] PENDING_LISTENER: table full, can't register '%s'\n", name);
}

/* Replacement for dispatch_mach_connect — swaps send→recv for pending listeners */
static void replacement_dispatch_mach_connect(void *channel, mach_port_t recv,
                                               mach_port_t send, void *msg) {
    /* Check if recv (first port arg) is a send right for a pending listener */
    for (int i = 0; i < MAX_PENDING_LISTENERS; i++) {
        if (g_pending_listeners[i].pending && g_pending_listeners[i].send_port == recv) {
            mach_port_t real_recv = g_pending_listeners[i].recv_port;
            bfix_log("[bfix] DMC_SWAP: '%s' send=0x%x → recv=0x%x channel=%p\n",
                     g_pending_listeners[i].name, recv, real_recv, channel);
            recv = real_recv;
            /* Also fix send param if it matches */
            if (send == g_pending_listeners[i].send_port)
                send = real_recv;
            g_pending_listeners[i].pending = 0;
            break;
        }
    }

    if (g_orig_dispatch_mach_connect) {
        g_orig_dispatch_mach_connect(channel, recv, send, msg);
    }
}

/* dispatch_mach_msg types */
typedef void *dispatch_mach_msg_t;
extern dispatch_mach_msg_t dispatch_mach_msg_create(void *header,
    size_t size, void *destructor, mach_msg_header_t **msg_ptr);
#define BFIX_PORT_NAME_SLOTS 128
typedef struct {
    mach_port_t port;
    char name[128];
} bfix_port_name_entry_t;
static bfix_port_name_entry_t g_bfix_port_names[BFIX_PORT_NAME_SLOTS];

static void bfix_remember_port_name(mach_port_t port, const char *name) {
    if (!name || !name[0] || port == MACH_PORT_NULL) return;
    for (int i = 0; i < BFIX_PORT_NAME_SLOTS; i++) {
        if (g_bfix_port_names[i].port == port) {
            strncpy(g_bfix_port_names[i].name, name, sizeof(g_bfix_port_names[i].name) - 1);
            g_bfix_port_names[i].name[sizeof(g_bfix_port_names[i].name) - 1] = '\0';
            return;
        }
    }
    for (int i = 0; i < BFIX_PORT_NAME_SLOTS; i++) {
        if (g_bfix_port_names[i].port == MACH_PORT_NULL) {
            g_bfix_port_names[i].port = port;
            strncpy(g_bfix_port_names[i].name, name, sizeof(g_bfix_port_names[i].name) - 1);
            g_bfix_port_names[i].name[sizeof(g_bfix_port_names[i].name) - 1] = '\0';
            return;
        }
    }
}

static const char *bfix_lookup_port_name(mach_port_t port) {
    if (port == MACH_PORT_NULL) return NULL;
    for (int i = 0; i < BFIX_PORT_NAME_SLOTS; i++) {
        if (g_bfix_port_names[i].port == port && g_bfix_port_names[i].name[0]) {
            return g_bfix_port_names[i].name;
        }
    }
    return NULL;
}

static void replacement_xpc_connection_check_in(void *conn) {
    uint8_t *obj = (uint8_t *)conn;
    int is_listener = (obj[0xd9] & 0x2) != 0;
    mach_port_t port1_hint = *(mach_port_t *)(obj + 0x34);

    /* Try to identify service name from connection object for logging.
     * XPC connection name is typically a pointer at offset +0x70 or +0x78. */
    const char *conn_name = NULL;
    {
        void *name_ptr = *(void **)(obj + 0x70);
        if (name_ptr && (uintptr_t)name_ptr > 0x1000 && (uintptr_t)name_ptr < 0x7fffffffffff) {
            const char *try_name = (const char *)name_ptr;
            if (try_name[0] == 'c' && try_name[1] == 'o' && try_name[2] == 'm')
                conn_name = try_name;
        }
        if (!conn_name) {
            name_ptr = *(void **)(obj + 0x78);
            if (name_ptr && (uintptr_t)name_ptr > 0x1000 && (uintptr_t)name_ptr < 0x7fffffffffff) {
                const char *try_name = (const char *)name_ptr;
                if (try_name[0] == 'c' && try_name[1] == 'o' && try_name[2] == 'm')
                    conn_name = try_name;
            }
        }
    }
    if (!conn_name) {
        conn_name = bfix_lookup_port_name(port1_hint);
    }
    int is_assertiond = (conn_name && strncmp(conn_name, "com.apple.assertiond.", 21) == 0);

    /* For known SpringBoard LISTENER services, handle the full LISTENER
     * check_in ourselves. The springboard_shim already populated port1
     * with the recv port via bootstrap_check_in. We just need to do:
     * state=6, flag 0x40, port_destroyed, 52-byte reg msg, dispatch_mach_connect.
     *
     * We return early to prevent the CLIENT path from double-connecting. */
    /* FORCE_LISTENER only applies to SpringBoard process — not the app.
     * The app should connect as CLIENT (look_up), not check_in. */
    const char *pn = getprogname();
    int is_sb_proc = (pn && strstr(pn, "SpringBoard"));
    int is_sb_listener = (is_sb_proc && conn_name && (
        strstr(conn_name, "frontboard.workspace") ||
        strstr(conn_name, "frontboard.systemappservices")));

    /* Track channels that had FORCE_LISTENER applied — skip CLIENT connect for these */
    #define MAX_FORCE_LISTENER_CHANNELS 8
    static void *g_force_listener_channels[MAX_FORCE_LISTENER_CHANNELS];

    if (is_sb_listener) {
        mach_port_t fl_port1 = *(mach_port_t *)(obj + 0x34);
        mach_port_t fl_port2 = *(mach_port_t *)(obj + 0x3c);
        mach_port_t fl_send = *(mach_port_t *)(obj + 0x38);
        void *fl_channel = *(void **)(obj + 0x58);

        bfix_log("[bfix] FORCE_LISTENER '%s': port1=0x%x port2=0x%x send=0x%x channel=%p\n",
                 conn_name, fl_port1, fl_port2, fl_send, fl_channel);

        /* Use CACHED recv port from the first check_in (via 805 handler).
         * Do NOT call check_in again — it would create a fresh port that
         * doesn't match what the app's look_up returns. */
        mach_port_t cached_recv = MACH_PORT_NULL;
        if (strstr(conn_name, "frontboard.workspace") &&
            !strstr(conn_name, "systemappservices")) {
            cached_recv = g_cached_workspace_recv;
        } else if (strstr(conn_name, "frontboard.systemappservices")) {
            cached_recv = g_cached_sysappsvcs_recv;
        }

        if (cached_recv != MACH_PORT_NULL) {
            fl_port1 = cached_recv;
            fl_port2 = cached_recv;
            *(mach_port_t *)(obj + 0x34) = fl_port1;
            *(mach_port_t *)(obj + 0x3c) = fl_port2;
            bfix_log("[bfix] FORCE_LISTENER '%s': using CACHED recv=0x%x\n",
                     conn_name, cached_recv);
        } else {
            bfix_log("[bfix] FORCE_LISTENER '%s': NO cached recv port! Trying check_in fallback\n",
                     conn_name);
            mach_port_t recv = MACH_PORT_NULL;
            replacement_bootstrap_check_in(get_bootstrap_port(), (char *)conn_name, &recv);
            if (recv != MACH_PORT_NULL) {
                fl_port1 = recv;
                fl_port2 = recv;
                *(mach_port_t *)(obj + 0x34) = fl_port1;
                *(mach_port_t *)(obj + 0x3c) = fl_port2;
            }
        }

        if (fl_port1 == MACH_PORT_NULL || !fl_channel) {
            bfix_log("[bfix] FORCE_LISTENER '%s': ABORT — port1=0x%x channel=%p\n",
                     conn_name, fl_port1, fl_channel);
            return;
        }

        if (fl_send == MACH_PORT_NULL) {
            fl_send = get_bootstrap_port();
            *(mach_port_t *)(obj + 0x38) = fl_send;
        }

        /* Set flag 0x40 */
        *(uint16_t *)(obj + 0xd8) = *(uint16_t *)(obj + 0xd8) | 0x40;

        /* Port destroyed notification */
        {
            typedef int (*setup_fn)(mach_port_t, mach_port_t, int *);
            static setup_fn g_setup = NULL;
            if (!g_setup) {
                g_setup = (setup_fn)dlsym(RTLD_DEFAULT, "_xpc_mach_port_setup_port_destroyed");
                if (!g_setup) g_setup = (setup_fn)find_original_function("_xpc_mach_port_setup_port_destroyed");
            }
            if (g_setup) { int result = 0; g_setup(fl_port2, fl_port1, &result); }
        }

        /* dispatch_mach_connect with registration message */
        if (!g_dispatch_mach_connect)
            g_dispatch_mach_connect = (dispatch_mach_connect_fn)dlsym(RTLD_DEFAULT, "dispatch_mach_connect");

        mach_msg_header_t *msg_ptr = NULL;
        dispatch_mach_msg_t dmsg = dispatch_mach_msg_create(NULL, 0x34, NULL, &msg_ptr);
        if (dmsg && msg_ptr) {
            uint8_t *m = (uint8_t *)msg_ptr;
            *(uint32_t *)(m+0x00)=0x80000013; *(uint32_t *)(m+0x04)=0x34;
            *(uint32_t *)(m+0x08)=fl_send; *(uint32_t *)(m+0x0c)=0;
            *(uint32_t *)(m+0x10)=0; *(uint32_t *)(m+0x14)=0x77303074;
            *(uint32_t *)(m+0x18)=2;
            *(uint32_t *)(m+0x1c)=fl_port1; *(uint32_t *)(m+0x20)=0;
            *(uint16_t *)(m+0x24)=0; *(uint8_t *)(m+0x26)=0x14; *(uint8_t *)(m+0x27)=0;
            *(uint32_t *)(m+0x28)=fl_port2; *(uint32_t *)(m+0x2c)=0;
            *(uint16_t *)(m+0x30)=0; *(uint8_t *)(m+0x32)=0x10; *(uint8_t *)(m+0x33)=0;
            bfix_log("[bfix] FORCE_LISTENER '%s': dispatch_mach_connect(recv=0x%x send=0x%x)\n",
                     conn_name, fl_port1, fl_send);
            g_dispatch_mach_connect(fl_channel, fl_port1, fl_port2, dmsg);
        } else {
            g_dispatch_mach_connect(fl_channel, fl_port1, fl_port2, NULL);
        }

        bfix_log("[bfix] FORCE_LISTENER '%s': DONE recv=0x%x\n", conn_name, fl_port1);
        /* Record this channel so CLIENT path skips it */
        for (int i = 0; i < MAX_FORCE_LISTENER_CHANNELS; i++) {
            if (!g_force_listener_channels[i]) {
                g_force_listener_channels[i] = fl_channel;
                break;
            }
        }
        return;
    }

    if (is_assertiond) {
        bfix_log("[bfix] CHECK_IN ASSERTIOND '%s' conn=%p listener=%d\n",
                 conn_name, conn, is_listener);
        bfix_log("[bfix]   state=0x%x port1=0x%x port2=0x%x send=0x%x channel=%p flags_d8=0x%x flags_d9=0x%x\n",
                 *(uint32_t *)(obj + 0x28),
                 *(mach_port_t *)(obj + 0x34),
                 *(mach_port_t *)(obj + 0x3c),
                 *(mach_port_t *)(obj + 0x38),
                 *(void **)(obj + 0x58),
                 (unsigned)*(uint8_t *)(obj + 0xd8),
                 (unsigned)*(uint8_t *)(obj + 0xd9));
    }

    /* Set state to 6 (success) */
    *(uint32_t *)(obj + 0x28) = 6;

    /* Get ports and channel from connection object */
    void *channel = *(void **)(obj + 0x58);
    mach_port_t port1 = *(mach_port_t *)(obj + 0x34);
    mach_port_t port2 = *(mach_port_t *)(obj + 0x3c);
    mach_port_t send_right = *(mach_port_t *)(obj + 0x38);

    /* If name not found via offsets, try the port→name table, then
     * try to identify the service by doing look_ups for known listener names */
    if ((!conn_name || strcmp(conn_name, "?") == 0) && port1 != MACH_PORT_NULL) {
        const char *table_name = bfix_lookup_port_name(port1);
        if (table_name) {
            conn_name = table_name;
        } else {
            /* Try known listener service names */
            static const char *known_listeners[] = {
                "com.apple.frontboard.workspace",
                "com.apple.frontboard.systemappservices",
                NULL
            };
            for (int i = 0; known_listeners[i]; i++) {
                mach_port_t test_port = MACH_PORT_NULL;
                kern_return_t kr = replacement_bootstrap_look_up(
                    get_bootstrap_port(), (char *)known_listeners[i], &test_port);
                if (kr == KERN_SUCCESS && test_port == port1) {
                    conn_name = known_listeners[i];
                    bfix_remember_port_name(port1, conn_name);
                    bfix_log("[bfix] _xpc_connection_check_in: identified port 0x%x as '%s'\n",
                             port1, conn_name);
                    break;
                }
            }
        }
    }

    /* Log all check-ins with service name for debugging */
    bfix_log("[bfix] _xpc_connection_check_in: '%s' conn=%p listener=%d port1=0x%x port2=0x%x send=0x%x\n",
             conn_name ? conn_name : "?", conn, is_listener, port1, port2, send_right);

    /* For LISTENER connections, we need a RECEIVE right, not a SEND right.
     * _xpc_look_up_endpoint always does look_up (returns send right).
     * For LISTENER mode, we need check_in (returns receive right).
     *
     * Detection: check if we have a send right but not a receive right
     * for this port. If so, do check_in to get the receive right. */
    if (port1 != MACH_PORT_NULL && conn_name && strcmp(conn_name, "?") != 0) {
        /* We have a name — check if this should be a listener (check_in) */
        int needs_recv = (strstr(conn_name, "frontboard.workspace") ||
                          strstr(conn_name, "frontboard.systemappservices"));
        if (needs_recv) {
            mach_port_t recv_port = MACH_PORT_NULL;
            kern_return_t kr = replacement_bootstrap_check_in(
                get_bootstrap_port(), (char *)conn_name, &recv_port);
            if (kr == KERN_SUCCESS && recv_port != MACH_PORT_NULL) {
                bfix_log("[bfix] _xpc_connection_check_in: '%s' upgraded send→recv: "
                         "old=0x%x new=0x%x\n", conn_name, port1, recv_port);
                port1 = recv_port;
                *(mach_port_t *)(obj + 0x34) = port1;
                port2 = recv_port;
                *(mach_port_t *)(obj + 0x3c) = port2;
            }
        }
    }
    /* If port1 is 0 but we can identify the service, try check_in */
    if (port1 == MACH_PORT_NULL && conn_name && strcmp(conn_name, "?") != 0) {
        mach_port_t checked_in_port = MACH_PORT_NULL;
        kern_return_t kr = replacement_bootstrap_check_in(
            get_bootstrap_port(), (char *)conn_name, &checked_in_port);
        if (kr == KERN_SUCCESS && checked_in_port != MACH_PORT_NULL) {
            port1 = checked_in_port;
            *(mach_port_t *)(obj + 0x34) = port1;
            bfix_log("[bfix] _xpc_connection_check_in: '%s' check_in → port 0x%x\n",
                     conn_name, port1);
        }
    }

    /* If send_right is 0 (not populated by _xpc_look_up_endpoint), use the
     * bootstrap port as the registration target. The broker will receive and
     * handle the listener registration message. */
    if (send_right == MACH_PORT_NULL) {
        send_right = get_bootstrap_port();
        *(mach_port_t *)(obj + 0x38) = send_right;
        if (is_assertiond)
            bfix_log("[bfix]   ASSERTIOND send_right was NULL, set to broker 0x%x\n", send_right);
    }

    if (!g_dispatch_mach_connect) {
        g_dispatch_mach_connect = (dispatch_mach_connect_fn)
            dlsym(RTLD_DEFAULT, "dispatch_mach_connect");
    }

    if (!g_dispatch_mach_connect || !channel) {
        if (is_assertiond)
            bfix_log("[bfix]   ASSERTIOND ABORT: dispatch_mach_connect=%p channel=%p\n",
                     g_dispatch_mach_connect, channel);
        return;
    }

    if (!is_listener) {
        /* Skip dispatch_mach_connect for channels that already had FORCE_LISTENER,
         * or for known SB listener services. Prevents double-connect. */
        int skip_connect = is_sb_listener;
        if (!skip_connect) {
            for (int i = 0; i < MAX_FORCE_LISTENER_CHANNELS; i++) {
                if (g_force_listener_channels[i] == channel) {
                    skip_connect = 1;
                    bfix_log("[bfix] _xpc_connection_check_in: SKIP CLIENT connect (FORCE_LISTENER channel %p)\n", channel);
                    break;
                }
            }
        }
        if (skip_connect) {
            bfix_log("[bfix] _xpc_connection_check_in: SKIP CLIENT connect for '%s'\n",
                     conn_name ? conn_name : "?");
        } else {
            g_dispatch_mach_connect(channel, port1, port2, NULL);
            bfix_log("[bfix] _xpc_connection_check_in: CLIENT channel=%p port1=0x%x\n",
                     channel, port1);
        }
    } else {
        /* LISTENER: build the 52-byte registration message.
         * Format from libxpc disassembly:
         *   header: msgh_bits=0x80000013 (COMPLEX|MAKE_SEND+COPY_SEND)
         *           msgh_size=0x34 (52)
         *           msgh_remote_port=[obj+0x38] (send_right to launchd/broker)
         *           msgh_local_port=0, msgh_voucher_port=0
         *           msgh_id=0x77303074 (extracted from literal pool)
         *   body:   descriptor_count=2
         *   desc0:  port=[obj+0x34] (recv_right), disposition=MAKE_SEND (0x14)
         *   desc1:  port=[obj+0x3c] (extra_port), disposition=COPY_SEND (0x10) */

        /* Step 1: Set up port notification (MACH_NOTIFY_PORT_DESTROYED).
         * The original code calls _xpc_mach_port_setup_port_destroyed(port2, port1, &result)
         * BEFORE dispatch_mach_connect. Without this, the dispatch_mach system
         * cannot properly monitor the listener port. */
        {
            typedef int (*setup_port_destroyed_fn)(mach_port_t, mach_port_t, int *);
            static setup_port_destroyed_fn g_setup_fn = NULL;
            if (!g_setup_fn) {
                g_setup_fn = (setup_port_destroyed_fn)
                    dlsym(RTLD_DEFAULT, "_xpc_mach_port_setup_port_destroyed");
                /* Private symbol — try Mach-O walking */
                if (!g_setup_fn)
                    g_setup_fn = (setup_port_destroyed_fn)
                        find_original_function("_xpc_mach_port_setup_port_destroyed");
            }
            if (g_setup_fn) {
                int result = 0;
                int kr_setup = g_setup_fn(port2, port1, &result);
                if (is_assertiond)
                    bfix_log("[bfix]   ASSERTIOND port_destroyed_setup(port2=0x%x, port1=0x%x) → %d result=%d\n",
                             port2, port1, kr_setup, result);
                else
                    bfix_log("[bfix] _xpc_mach_port_setup_port_destroyed(%x,%x) = %d\n",
                             port2, port1, kr_setup);
            }
        }

        /* Step 2: Set flag 0x40 at offset 0xd8 (original sets this before connect) */
        {
            uint16_t flags_d8 = *(uint16_t *)(obj + 0xd8);
            flags_d8 |= 0x40;
            *(uint16_t *)(obj + 0xd8) = flags_d8;
        }

        /* Step 3: Build 52-byte registration message and connect */
        mach_msg_header_t *msg_ptr = NULL;
        dispatch_mach_msg_t dmsg = dispatch_mach_msg_create(NULL, 0x34, NULL, &msg_ptr);
        if (dmsg && msg_ptr) {
            uint8_t *m = (uint8_t *)msg_ptr;
            *(uint32_t *)(m + 0x00) = 0x80000013; /* msgh_bits */
            *(uint32_t *)(m + 0x04) = 0x34;       /* msgh_size */
            *(uint32_t *)(m + 0x08) = send_right;  /* msgh_remote_port */
            *(uint32_t *)(m + 0x0c) = 0;           /* msgh_local_port */
            *(uint32_t *)(m + 0x10) = 0;           /* msgh_voucher_port */
            *(uint32_t *)(m + 0x14) = 0x77303074;  /* msgh_id */
            *(uint32_t *)(m + 0x18) = 2;           /* descriptor_count */
            /* desc0: port1 → MAKE_SEND */
            *(uint32_t *)(m + 0x1c) = port1;
            *(uint32_t *)(m + 0x20) = 0;
            *(uint16_t *)(m + 0x24) = 0;
            *(uint8_t *)(m + 0x26) = 0x14;
            *(uint8_t *)(m + 0x27) = 0x00;
            /* desc1: port2 → COPY_SEND */
            *(uint32_t *)(m + 0x28) = port2;
            *(uint32_t *)(m + 0x2c) = 0;
            *(uint16_t *)(m + 0x30) = 0;
            *(uint8_t *)(m + 0x32) = 0x10;
            *(uint8_t *)(m + 0x33) = 0x00;

            if (is_assertiond)
                bfix_log("[bfix]   ASSERTIOND pre-connect: channel=%p port1=0x%x port2=0x%x send=0x%x dmsg=%p\n",
                         channel, port1, port2, send_right, dmsg);
            g_dispatch_mach_connect(channel, port1, port2, dmsg);
            if (is_assertiond)
                bfix_log("[bfix]   ASSERTIOND post-connect: '%s' DONE\n", conn_name ? conn_name : "?");
            else
                bfix_log("[bfix] _xpc_connection_check_in: LISTENER channel=%p port1=0x%x send=0x%x\n",
                         channel, port1, send_right);
        } else {
            if (is_assertiond)
                bfix_log("[bfix]   ASSERTIOND LISTENER no-msg fallback: channel=%p port1=0x%x\n",
                         channel, port1);
            g_dispatch_mach_connect(channel, port1, port2, NULL);
            if (is_assertiond)
                bfix_log("[bfix]   ASSERTIOND post-connect (no-msg): '%s' DONE\n", conn_name ? conn_name : "?");
            else
                bfix_log("[bfix] _xpc_connection_check_in: LISTENER (no msg) channel=%p port1=0x%x\n",
                         channel, port1);
        }
    }
}

/* Logging-only wrapper for _xpc_connection_check_in (strict mode, assertiond only).
 * Captures the listener port for processinfoservice then calls the original.
 * Does NOT modify connection state — the original handles everything. */
typedef void (*xpc_connection_check_in_fn)(void *conn);
static xpc_connection_check_in_fn g_orig_xpc_connection_check_in = NULL;

static void strict_logging_xpc_connection_check_in(void *conn) {
    uint8_t *obj = (uint8_t *)conn;
    int is_listener = (obj[0xd9] & 0x2) != 0;
    mach_port_t port1 = *(mach_port_t *)(obj + 0x34);

    /* Try to get connection name */
    const char *conn_name = NULL;
    void *name_ptr = *(void **)(obj + 0x70);
    if (name_ptr && (uintptr_t)name_ptr > 0x1000 && (uintptr_t)name_ptr < 0x7fffffffffff) {
        const char *try_name = (const char *)name_ptr;
        if (try_name[0] == 'c' && try_name[1] == 'o' && try_name[2] == 'm')
            conn_name = try_name;
    }
    if (!conn_name) {
        name_ptr = *(void **)(obj + 0x78);
        if (name_ptr && (uintptr_t)name_ptr > 0x1000 && (uintptr_t)name_ptr < 0x7fffffffffff) {
            const char *try_name = (const char *)name_ptr;
            if (try_name[0] == 'c' && try_name[1] == 'o' && try_name[2] == 'm')
                conn_name = try_name;
        }
    }

    /* Capture processinfoservice listener port */
    if (is_listener && conn_name && strstr(conn_name, "processinfoservice")) {
        g_processinfoservice_port = port1;
        bfix_log("[bfix] STRICT PI PORT CAPTURED: svc=%s listener port=0x%x\n",
                 conn_name, port1);
    }

    if (is_listener) {
        bfix_log("[bfix] STRICT check_in LISTENER '%s' port1=0x%x\n",
                 conn_name ? conn_name : "?", port1);
    }

    /* Call the original */
    if (g_orig_xpc_connection_check_in) {
        g_orig_xpc_connection_check_in(conn);
    }
}

/* Replacement for xpc_connection_send_message_with_reply_sync.
 *
 * The original function blocks forever waiting for a reply. In our simulator,
 * many system services exist (have listener ports) but don't actually process
 * messages (e.g., mobilegestalt.xpc, cfprefsd.daemon). The original blocks
 * on mach_msg waiting for a reply that never comes.
 *
 * Fix: Use the async xpc_connection_send_message_with_reply + dispatch_semaphore
 * with a 2-second timeout. If the service doesn't reply in time, return an
 * XPC error object instead of blocking forever. */
/* Use dispatch/xpc headers properly — compiled as ObjC with ARC */
#include <dispatch/dispatch.h>
typedef void *xpc_object_t_bfix;
typedef void *xpc_connection_t_bfix;
extern void xpc_connection_send_message_with_reply(xpc_connection_t_bfix connection,
    xpc_object_t_bfix message, dispatch_queue_t replyq,
    void (^handler)(xpc_object_t_bfix));
extern xpc_object_t_bfix xpc_connection_send_message_with_reply_sync(
    xpc_connection_t_bfix connection, xpc_object_t_bfix message);

/* Return an XPC error object that callers can handle gracefully.
 * Returning NULL from send_sync causes crashes in callers that don't
 * check for nil (e.g., backboardd's MobileGestalt code). */
extern xpc_object_t_bfix xpc_dictionary_create(const char *const *keys,
                                                  xpc_object_t_bfix const *values,
                                                  size_t count);
extern void xpc_dictionary_set_int64(xpc_object_t_bfix dict, const char *key, int64_t value);
extern void xpc_dictionary_set_string(xpc_object_t_bfix dict, const char *key, const char *value);

static xpc_object_t_bfix replacement_xpc_send_sync(
    xpc_connection_t_bfix connection, xpc_object_t_bfix message) {

    __block xpc_object_t_bfix reply = NULL;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);

    xpc_connection_send_message_with_reply(connection, message, NULL,
        ^(xpc_object_t_bfix response) {
            reply = response;
            dispatch_semaphore_signal(sem);
        });

    /* Wait with 2-second timeout instead of blocking forever */
    long result = dispatch_semaphore_wait(sem,
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)));

    if (result != 0) {
        /* Timeout — service didn't respond. Return an empty XPC dictionary
         * instead of NULL. Callers (MobileGestalt, cfprefsd) typically check
         * for specific keys and handle missing keys gracefully, but crash on NULL. */
        bfix_log("[bfix] xpc_send_sync: TIMEOUT (2s) — returning empty dict\n");
        xpc_object_t_bfix empty = xpc_dictionary_create(NULL, NULL, 0);
        return empty;
    }

    return reply;
}

/* Replacement for _xpc_look_up_endpoint inside libxpc.
 *
 * iOS 10.3 sim libxpc's __xpc_look_up_endpoint issues domain routine 804
 * (endpoint lookup) and extracts reply["port"] as a mach_send.
 *
 * Therefore, this replacement MUST return a send right (bootstrap_look_up),
 * and must NOT attempt to return a receive right (check_in), regardless of
 * the 'type' argument.
 */
static mach_port_t replacement_xpc_look_up_endpoint(
    const char *name, int type, uint64_t handle,
    uint64_t lookup_handle, void *something, uint64_t flags) {

    mach_port_t port = MACH_PORT_NULL;
    mach_port_t bp = get_bootstrap_port();
    (void)type;
    (void)handle;
    (void)lookup_handle;
    (void)something;
    (void)flags;

    int is_assertiond = (name && strncmp(name, "com.apple.assertiond.", 21) == 0);
    if (is_assertiond) {
        bfix_log("[bfix] _xpc_look_up_endpoint ASSERTIOND '%s' type=%d handle=%llu bp=0x%x\n",
                 name, type, handle, bp);
    } else {
        bfix_log("[bfix] _xpc_look_up_endpoint('%s', type=%d)\n",
                 name ? name : "(null)", type);
    }

    if (!name || bp == MACH_PORT_NULL) return MACH_PORT_NULL;
    /* Endpoint lookup: return a mach_send right. */
    kern_return_t kr = replacement_bootstrap_look_up(bp, name, &port);
    if (kr != KERN_SUCCESS || port == MACH_PORT_NULL) {
        /* Service not found. Return a DEAD port instead of NULL.
         * With NULL, xpc_connection_send_message_with_reply_sync can hang
         * forever waiting for a dispatch event that never fires.
         * With a dead port, the send fails immediately with
         * MACH_SEND_INVALID_DEST and libxpc reports an error. */
        mach_port_t dead = MACH_PORT_NULL;
        mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &dead);
        /* Deallocate immediately → port becomes dead name for anyone holding send right */
        mach_port_deallocate(mach_task_self(), dead);
        port = dead;
        if (is_assertiond) {
            bfix_log("[bfix] _xpc_look_up_endpoint ASSERTIOND '%s': NOT FOUND → dead port 0x%x\n",
                     name, port);
        } else {
            bfix_log("[bfix] _xpc_look_up_endpoint '%s': NOT FOUND → dead port 0x%x\n",
                     name, port);
        }
    } else {
        if (is_assertiond) {
            bfix_log("[bfix] _xpc_look_up_endpoint ASSERTIOND '%s': port=0x%x\n", name, port);
        } else {
            bfix_log("[bfix] _xpc_look_up_endpoint '%s': port=0x%x\n", name, port);
        }
    }

    /* Remember port→name mapping for _xpc_connection_check_in lookup */
    if (port != MACH_PORT_NULL && name) {
        bfix_remember_port_name(port, name);
    }

    /* No longer doing check_in in look_up_endpoint — the cached recv port
     * from the first 805 check_in is used by FORCE_LISTENER instead. */

    return port;
}

/* Patch bootstrap functions so intra-library calls in libxpc are redirected.
 * We must patch ALL variants: the basic functions plus the 2/3 variants
 * that take additional parameters (flags, instance_id). The trampoline
 * redirects to our basic replacement — extra args are harmlessly ignored
 * because our replacement only reads rdi/rsi/rdx (first 3 params). */
static void patch_bootstrap_functions(void) {
    bfix_log("[bfix] === patching bootstrap functions for intra-library calls ===\n");

    struct { const char *name; void *replacement; } patches[] = {
        { "bootstrap_look_up",   (void *)replacement_bootstrap_look_up },
        { "bootstrap_look_up2",  (void *)replacement_bootstrap_look_up },
        { "bootstrap_look_up3",  (void *)replacement_bootstrap_look_up },
        { "bootstrap_check_in",  (void *)replacement_bootstrap_check_in },
        { "bootstrap_check_in2", (void *)replacement_bootstrap_check_in },
        { "bootstrap_check_in3", (void *)replacement_bootstrap_check_in },
        { "bootstrap_register",  (void *)replacement_bootstrap_register },
        /* In compat mode: bypass XPC pipe protocol for endpoint lookups.
         * In strict mode: let libxpc use the XPC pipe natively (the 805
         * reply format is now correct with MACH_RECV=0x15000). */
        { "_xpc_look_up_endpoint", NULL },  /* filled conditionally below */
        { "_xpc_connection_check_in", NULL },
        { "_xpc_pipe_routine", NULL },  /* filled for assertiond and SpringBoard */
        /* NOTE: launch_msg runtime trampoline REMOVED — causes infinite recursion
         * because fallthrough calls the patched function. DYLD interposition handles
         * cross-library calls; intra-library calls need saved-original approach. */
    };
    int n_patches = sizeof(patches) / sizeof(patches[0]);

    /* In compat mode, patch _xpc_look_up_endpoint + _xpc_connection_check_in
     * to bypass XPC pipe and use direct MIG bootstrap calls.
     * In strict mode, leave them NULL (unpatched) so libxpc uses the native
     * XPC pipe protocol — which now works with correct type constants. */
    {
        const char *lifecycle = getenv("ROSETTASIM_LIFECYCLE_MODE");
        int strict = (lifecycle && strcmp(lifecycle, "strict") == 0);
        if (!strict) {
            const char *pn_compat = getprogname();
            int is_sb_compat = (pn_compat && strstr(pn_compat, "SpringBoard"));
            for (int i = 0; i < n_patches; i++) {
                if (strcmp(patches[i].name, "_xpc_look_up_endpoint") == 0)
                    patches[i].replacement = (void *)replacement_xpc_look_up_endpoint;
                else if (strcmp(patches[i].name, "_xpc_connection_check_in") == 0)
                    patches[i].replacement = (void *)replacement_xpc_connection_check_in;
                /* SpringBoard also needs _xpc_pipe_routine for workspace recv caching */
                else if (is_sb_compat && strcmp(patches[i].name, "_xpc_pipe_routine") == 0)
                    patches[i].replacement = (void *)replacement_xpc_pipe_routine;
            }
            if (is_sb_compat)
                bfix_log("[bfix] COMPAT+SpringBoard: added _xpc_pipe_routine patch\n");
        } else {
            const char *pn = getprogname();
            int is_sb = (pn && strstr(pn, "SpringBoard"));
            int is_assertiond = (pn && strstr(pn, "assertiond"));
            bfix_log("[bfix] STRICT mode: progname='%s' is_sb=%d is_assertiond=%d\n",
                     pn ? pn : "(null)", is_sb, is_assertiond);

            if (is_sb) {
                /* STRICT+SpringBoard: patch _xpc_look_up_endpoint,
                 * _xpc_connection_check_in, AND _xpc_pipe_routine.
                 * The pipe routine 805 handler caches the recv port for
                 * workspace/systemappservices so FORCE_LISTENER can use it. */
                for (int i = 0; i < n_patches; i++) {
                    if (strcmp(patches[i].name, "_xpc_look_up_endpoint") == 0)
                        patches[i].replacement = (void *)replacement_xpc_look_up_endpoint;
                    else if (strcmp(patches[i].name, "_xpc_connection_check_in") == 0)
                        patches[i].replacement = (void *)replacement_xpc_connection_check_in;
                    else if (strcmp(patches[i].name, "_xpc_pipe_routine") == 0)
                        patches[i].replacement = (void *)replacement_xpc_pipe_routine;
                }
                bfix_log("[bfix] STRICT+SpringBoard: _xpc_look_up_endpoint + _xpc_connection_check_in + _xpc_pipe_routine PATCHED\n");
            } else if (is_assertiond) {
                /* STRICT+assertiond:
                 * Do NOT trampoline _xpc_connection_check_in.
                 * The previous logging wrapper recursed (because our trampoline
                 * overwrote the original entry point, so calling it re-entered
                 * the wrapper) and assertiond would crash with a stack overflow.
                 *
                 * We already have a mach_msg-based capture path for the
                 * processinfoservice port, so keep assertiond stable. */
                bfix_log("[bfix] STRICT+assertiond: skipping _xpc_connection_check_in port-capture patch\n");
            } else {
                bfix_log("[bfix] STRICT: skipping _xpc_look_up_endpoint + _xpc_connection_check_in patches\n");
            }
        }
    }

    for (int i = 0; i < n_patches; i++) {
        if (!patches[i].replacement) continue;  /* skip NULL (strict mode) */
        void *orig = find_original_function(patches[i].name);
        if (orig) {
            write_trampoline(orig, patches[i].replacement, patches[i].name);
        }
    }

    /* Trampoline dispatch_mach_connect for SpringBoard — swaps send→recv
     * for LISTENER services (see pending_listeners table).
     *
     * We need to call the ORIGINAL after our replacement, so we create
     * an executable thunk: save original's first 14 bytes, then jmp to
     * original+14. Our replacement calls the thunk as the "original". */
    {
        const char *pn = getprogname();
        if (pn && strstr(pn, "SpringBoard")) {
            void *dmc_orig = dlsym(RTLD_DEFAULT, "dispatch_mach_connect");
            if (dmc_orig) {
                /* Allocate executable thunk page */
                vm_address_t thunk_page = 0;
                kern_return_t kr = vm_allocate(mach_task_self(), &thunk_page, 0x1000,
                                                VM_FLAGS_ANYWHERE);
                if (kr == KERN_SUCCESS) {
                    kr = vm_protect(mach_task_self(), thunk_page, 0x1000, FALSE,
                                    VM_PROT_READ | VM_PROT_WRITE | VM_PROT_EXECUTE);
                    if (kr == KERN_SUCCESS) {
                        uint8_t *thunk = (uint8_t *)thunk_page;
                        /* Copy first 14 bytes of original function */
                        memcpy(thunk, dmc_orig, 14);
                        /* Then: movabs rax, original+14; jmp rax */
                        uint64_t cont_addr = (uint64_t)(uintptr_t)dmc_orig + 14;
                        thunk[14] = 0x48; thunk[15] = 0xB8;
                        memcpy(&thunk[16], &cont_addr, 8);
                        thunk[24] = 0xFF; thunk[25] = 0xE0;

                        extern void sys_icache_invalidate(void *start, size_t len);
                        sys_icache_invalidate(thunk, 26);

                        g_orig_dispatch_mach_connect = (dispatch_mach_connect_fn)thunk;
                        g_dispatch_mach_connect = (dispatch_mach_connect_fn)thunk;

                        /* Now trampoline the original */
                        write_trampoline(dmc_orig, (void *)replacement_dispatch_mach_connect,
                                         "dispatch_mach_connect");
                        bfix_log("[bfix] dispatch_mach_connect: trampolined (thunk=%p orig=%p)\n",
                                 thunk, dmc_orig);
                    }
                }
            }
        }
    }

    /* Detect assertiond for diagnostic probing */
    {
        const char *pn = getprogname();
        if (pn && strstr(pn, "assertiond")) g_is_assertiond = 1;
    }

    /* MobileGestalt stub: bypass NSXPC to avoid corrupted replies.
     * Gate behind ROSETTASIM_MG_STUB=1 (set by broker for all processes). */
    {
        const char *mg_env = getenv("ROSETTASIM_MG_STUB");
        if (mg_env && mg_env[0] == '1') {
            g_mg_stub_active = 1;
            /* Force-load libMobileGestalt.dylib so find_original_function can find it */
            dlopen("libMobileGestalt.dylib", RTLD_LAZY);
            void *orig_copy = find_original_function("MGCopyAnswer");
            if (orig_copy) {
                g_orig_MGCopyAnswer = (MGCopyAnswer_fn)orig_copy;
                write_trampoline(orig_copy, (void *)replacement_MGCopyAnswer,
                                 "MGCopyAnswer");
            }
            void *orig_copy_err = find_original_function("MGCopyAnswerWithError");
            if (orig_copy_err) {
                write_trampoline(orig_copy_err, (void *)replacement_MGCopyAnswerWithError,
                                 "MGCopyAnswerWithError");
            }
            void *orig_bool = find_original_function("MGGetBoolAnswer");
            if (orig_bool) {
                write_trampoline(orig_bool, (void *)replacement_MGGetBoolAnswer,
                                 "MGGetBoolAnswer");
            }
            bfix_log("[bfix] MobileGestalt stub ACTIVE (bypassing NSXPC)\n");
        }
    }

    /* Conditionally install xpc_send_sync timeout for APP process only.
     * Daemons (backboardd, assertiond, SpringBoard) block on MobileGestalt
     * harmlessly on background threads. The app blocks on main thread inside
     * [UIApplication init], preventing _run from ever being called.
     * Broker sets ROSETTASIM_XPC_TIMEOUT=1 for the app process only. */
    {
        const char *timeout_env = getenv("ROSETTASIM_XPC_TIMEOUT");
        if (timeout_env && timeout_env[0] == '1') {
            void *orig_send_sync = find_original_function("xpc_connection_send_message_with_reply_sync");
            if (orig_send_sync) {
                write_trampoline(orig_send_sync, (void *)replacement_xpc_send_sync,
                                 "xpc_connection_send_message_with_reply_sync");
                bfix_log("[bfix] XPC send_sync timeout enabled (app process)\n");
            }
        }
    }

    /* Verify trampolines work by calling the original address.
     * If the trampoline is working, it redirects to our replacement,
     * which logs "[bfix] look_up('__trampoline_verify__')". */
    void *orig_look_up = find_original_function("bootstrap_look_up");
    if (orig_look_up) {
        typedef kern_return_t (*bootstrap_look_up_fn)(mach_port_t, const char *, mach_port_t *);
        mach_port_t dummy = MACH_PORT_NULL;
        bfix_log("[bfix] trampoline verify: calling original bootstrap_look_up at %p...\n", orig_look_up);
        kern_return_t vkr = ((bootstrap_look_up_fn)orig_look_up)(
            get_bootstrap_port(), "__trampoline_verify__", &dummy);
        bfix_log("[bfix] trampoline verify: result=%d (expect look_up log above)\n", vkr);
    }

    bfix_log("[bfix] === bootstrap patching complete ===\n");
}

/* Also set the global for any code that reads it directly */
__attribute__((constructor))
static void bootstrap_fix_constructor(void) {
    mach_port_t bp = get_bootstrap_port();
    bfix_log("[bfix] constructor: setting bootstrap_port = 0x%x (was 0x%x)\n", bp, bootstrap_port);
    if (bp != MACH_PORT_NULL) {
        bootstrap_port = bp;

        /* Patch bootstrap functions for intra-library calls.
         * DYLD interposition catches cross-library calls, but _xpc_pipe_create
         * in libxpc calls bootstrap_look_up as an intra-library call.
         * This must happen BEFORE any XPC operations. */
        patch_bootstrap_functions();
        bfix_install_springboard_handle_fix_async();

        /* Look up CARenderServer and patch the client port.
         * This must happen BEFORE UIKit creates any windows. */
        mach_port_t ca_port = MACH_PORT_NULL;
        kern_return_t kr = replacement_bootstrap_look_up(bp, "com.apple.CARenderServer", &ca_port);
        if (kr == KERN_SUCCESS && ca_port != MACH_PORT_NULL) {
            bfix_log("[bfix] constructor: CARenderServer port = 0x%x\n", ca_port);

            /* Check _user_client_port BEFORE any context creation */
            void *fn = dlsym(RTLD_DEFAULT, "CARenderServerGetClientPort");
            mach_port_t pre_cp = 0;
            if (fn) {
                pre_cp = ((mach_port_t(*)(mach_port_t))fn)(ca_port);
                bfix_log("[bfix] constructor: GetClientPort BEFORE = 0x%x\n", pre_cp);
            }

            /* DON'T patch _user_client_port yet — let connect_remote try naturally.
             * Create a remote context which triggers connect_remote internally. */
            @try {
                Class caCtxCls = (Class)objc_getClass("CAContext");
                if (caCtxCls) {
                    id opts = @{@"displayable": @YES, @"display": @(1)};
                    bfix_log("[bfix] constructor: creating remote context...\n");
                    id ctx = ((id(*)(id, SEL, id))objc_msgSend)(
                        (id)caCtxCls,
                        sel_registerName("remoteContextWithOptions:"),
                        opts);
                    if (ctx) {
                        unsigned int cid = ((unsigned int(*)(id, SEL))objc_msgSend)(
                            ctx, sel_registerName("contextId"));
                        bfix_log("[bfix] constructor: remote context id=%u\n", cid);

                        /* Dump impl fields */
                        Ivar implI = class_getInstanceVariable(object_getClass(ctx), "_impl");
                        if (implI) {
                            void *imp = *(void **)((uint8_t *)ctx + ivar_getOffset(implI));
                            if (imp) {
                                bfix_log("[bfix] constructor: impl=%p", imp);
                                for (int off = 0; off < 0xB0; off += 8) {
                                    uint64_t val = *(uint64_t *)((uint8_t *)imp + off);
                                    if (val != 0)
                                        bfix_log("  IMPL+0x%02x = 0x%016llx", off, (unsigned long long)val);
                                }
                            }
                        }
                    } else {
                        bfix_log("[bfix] constructor: remoteContextWithOptions returned nil\n");
                    }
                }
            } @catch (id ex) {
                bfix_log("[bfix] constructor: remote context threw\n");
            }

            /* Check _user_client_port AFTER remote context creation */
            if (fn) {
                mach_port_t post_cp = ((mach_port_t(*)(mach_port_t))fn)(ca_port);
                bfix_log("[bfix] constructor: GetClientPort AFTER = 0x%x\n", post_cp);

                if (post_cp == MACH_PORT_NULL) {
                    /* connect_remote didn't set it. Patch with a created port as fallback. */
                    mach_port_t cp = MACH_PORT_NULL;
                    mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &cp);
                    if (cp != MACH_PORT_NULL) {
                        mach_port_insert_right(mach_task_self(), cp, cp, MACH_MSG_TYPE_MAKE_SEND);
                        patch_client_port(cp);
                        g_bfix_client_port = cp;
                        bfix_log("[bfix] constructor: patched _user_client_port = 0x%x (fallback)\n", cp);
                    }
                } else {
                    g_bfix_client_port = post_cp;
                    bfix_log("[bfix] constructor: connect_remote set _user_client_port = 0x%x!\n", post_cp);
                }
            }
        } else {
            bfix_log("[bfix] constructor: CARenderServer not found (kr=0x%x) — app process?\n", kr);
        }
    }

    /* Detect assertiond and schedule a diagnostic probe.
     * After 8 seconds (well into the workspace handshake window), enumerate
     * all ports and check for queued messages. This tells us if messages
     * arrive at assertiond's listener ports but aren't being processed. */
    const char *pn = getprogname();
    if (pn && strstr(pn, "assertiond")) {
        g_is_assertiond = 1;
        bfix_log("[bfix] constructor: assertiond detected — scheduling qcount sampler\n");

        /* Tight-loop qcount sampler: sample g_processinfoservice_port every 50ms
         * for 5 seconds, starting 3 seconds after launch. This captures whether
         * SpringBoard's bootstrap message actually arrives at the port. */
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                       dispatch_get_global_queue(0, 0), ^{
            mach_port_t port = g_processinfoservice_port;
            bfix_log("[bfix] === QCOUNT SAMPLER START: port=0x%x ===\n", port);

            if (port == MACH_PORT_NULL) {
                bfix_log("[bfix] QCOUNT SAMPLER: port is NULL (not tracked)\n");
                return;
            }

            int max_qcount = 0;
            int max_seqno = 0;
            for (int i = 0; i < 100; i++) { /* 100 * 50ms = 5 seconds */
                mach_port_status_t status;
                mach_msg_type_number_t cnt = MACH_PORT_RECEIVE_STATUS_COUNT;
                kern_return_t kr = mach_port_get_attributes(mach_task_self(), port,
                    MACH_PORT_RECEIVE_STATUS, (mach_port_info_t)&status, &cnt);

                if (kr == KERN_SUCCESS) {
                    if (status.mps_msgcount > 0 || (i < 5) || (i % 20 == 0)) {
                        bfix_log("[bfix] QCOUNT[%d]: port=0x%x qcount=%d seqno=%d\n",
                                 i, port, status.mps_msgcount, status.mps_seqno);
                    }
                    if (status.mps_msgcount > max_qcount) max_qcount = status.mps_msgcount;
                    if (status.mps_seqno > max_seqno) max_seqno = status.mps_seqno;
                } else {
                    bfix_log("[bfix] QCOUNT[%d]: port=0x%x DEAD (kr=%d)\n", i, port, kr);
                    break;
                }
                usleep(50000); /* 50ms */
            }
            bfix_log("[bfix] === QCOUNT SAMPLER END: max_qcount=%d max_seqno=%d ===\n",
                     max_qcount, max_seqno);
        });
    }
}
