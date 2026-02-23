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
#include <objc/runtime.h>
#include <objc/message.h>
#import <Foundation/Foundation.h>
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

        /* Handle GetJobs — assertiond calls this to get its job dictionary.
         * Without a proper response, assertiond logs "Error getting job
         * dictionaries. Error: Input/output error (5)". */
        if (cmd && strcmp(cmd, LAUNCH_KEY_GETJOBS) == 0) {
            const char *progname = getprogname();
            bfix_log("[bfix] launch_msg('GetJobs') intercepted (process: %s)\n",
                     progname ? progname : "unknown");

            static const char *assertiond_services[] = {
                "com.apple.assertiond.applicationstateconnection",
                "com.apple.assertiond.appwatchdog",
                "com.apple.assertiond.expiration",
                "com.apple.assertiond.processassertionconnection",
                "com.apple.assertiond.processinfoservice",
                NULL
            };

            const char *job_label = NULL;
            const char **svc_list = NULL;
            if (progname && strstr(progname, "assertiond")) {
                job_label = "com.apple.assertiond";
                svc_list = assertiond_services;
            }

            if (job_label && svc_list) {
                /* Build: { job_label → { Label → job_label, MachServices → { svc → true } } } */
                launch_data_t resp = launch_data_alloc(LAUNCH_DATA_DICTIONARY);
                launch_data_t job_dict = launch_data_alloc(LAUNCH_DATA_DICTIONARY);
                launch_data_t ms_dict = launch_data_alloc(LAUNCH_DATA_DICTIONARY);

                int count = 0;
                for (int i = 0; svc_list[i]; i++) {
                    launch_data_dict_insert(ms_dict, launch_data_new_bool(1), svc_list[i]);
                    count++;
                }

                launch_data_dict_insert(job_dict, launch_data_new_string(job_label), LAUNCH_JOBKEY_LABEL);
                launch_data_dict_insert(job_dict, ms_dict, LAUNCH_JOBKEY_MACHSERVICES);
                launch_data_dict_insert(resp, job_dict, job_label);

                bfix_log("[bfix] launch_msg GetJobs: returning %d MachServices for %s\n",
                         count, job_label);
                return resp;
            }

            bfix_log("[bfix] launch_msg GetJobs: no job data for '%s', falling through\n",
                     progname ? progname : "unknown");
        }
    }

    /* Handle DICTIONARY form of GetJobs: { LAUNCH_KEY_GETJOBS → ... } */
    if (msg && launch_data_get_type(msg) == LAUNCH_DATA_DICTIONARY) {
        if (launch_data_dict_lookup(msg, LAUNCH_KEY_GETJOBS) != NULL) {
            const char *progname = getprogname();
            bfix_log("[bfix] launch_msg(dict GetJobs) intercepted (process: %s)\n",
                     progname ? progname : "unknown");

            static const char *assertiond_services_d[] = {
                "com.apple.assertiond.applicationstateconnection",
                "com.apple.assertiond.appwatchdog",
                "com.apple.assertiond.expiration",
                "com.apple.assertiond.processassertionconnection",
                "com.apple.assertiond.processinfoservice",
                NULL
            };

            const char *job_label = NULL;
            const char **svc_list = NULL;
            if (progname && strstr(progname, "assertiond")) {
                job_label = "com.apple.assertiond";
                svc_list = assertiond_services_d;
            }

            if (job_label && svc_list) {
                launch_data_t resp = launch_data_alloc(LAUNCH_DATA_DICTIONARY);
                launch_data_t job_dict = launch_data_alloc(LAUNCH_DATA_DICTIONARY);
                launch_data_t ms_dict = launch_data_alloc(LAUNCH_DATA_DICTIONARY);

                int count = 0;
                for (int i = 0; svc_list[i]; i++) {
                    launch_data_dict_insert(ms_dict, launch_data_new_bool(1), svc_list[i]);
                    count++;
                }

                launch_data_dict_insert(job_dict, launch_data_new_string(job_label), LAUNCH_JOBKEY_LABEL);
                launch_data_dict_insert(job_dict, ms_dict, LAUNCH_JOBKEY_MACHSERVICES);
                launch_data_dict_insert(resp, job_dict, job_label);

                bfix_log("[bfix] launch_msg dict GetJobs: returning %d MachServices for %s\n",
                         count, job_label);
                return resp;
            }

            bfix_log("[bfix] launch_msg dict GetJobs: no job data for '%s', falling through\n",
                     progname ? progname : "unknown");
        }
    }

    /* Pass through to original for unhandled messages */
    return launch_msg(msg);
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
        /* CLIENT: same as original — no registration message */
        g_dispatch_mach_connect(channel, port1, port2, NULL);
        bfix_log("[bfix] _xpc_connection_check_in: CLIENT channel=%p port1=0x%x\n",
                 channel, port1);
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
 * This is the function that builds the XPC pipe check-in request and sends it
 * via _xpc_domain_routine. We bypass the XPC pipe protocol entirely and use
 * our broker's bootstrap_check_in/look_up directly.
 *
 * Signature (from disassembly):
 *   mach_port_t _xpc_look_up_endpoint(
 *     const char *name,        // rdi — service name
 *     int type,                // esi — 5=client, 7=listener
 *     uint64_t handle,         // rdx
 *     uint64_t lookup_handle,  // rcx
 *     void *something,         // r8
 *     uint64_t flags           // r9
 *   );
 */
static mach_port_t replacement_xpc_look_up_endpoint(
    const char *name, int type, uint64_t handle,
    uint64_t lookup_handle, void *something, uint64_t flags) {

    mach_port_t port = MACH_PORT_NULL;
    mach_port_t bp = get_bootstrap_port();

    int is_assertiond = (name && strncmp(name, "com.apple.assertiond.", 21) == 0);
    if (is_assertiond) {
        bfix_log("[bfix] _xpc_look_up_endpoint ASSERTIOND '%s' type=%d handle=%llu bp=0x%x\n",
                 name, type, handle, bp);
    } else {
        bfix_log("[bfix] _xpc_look_up_endpoint('%s', type=%d)\n",
                 name ? name : "(null)", type);
    }

    if (!name || bp == MACH_PORT_NULL) return MACH_PORT_NULL;

    if (type == 7) {
        /* LISTENER check-in: get receive right from broker */
        kern_return_t kr = replacement_bootstrap_check_in(bp, name, &port);
        if (kr == KERN_SUCCESS && port != MACH_PORT_NULL) {
            bfix_remember_port_name(port, name);
        }
        if (is_assertiond) {
            bfix_log("[bfix] _xpc_look_up_endpoint ASSERTIOND LISTENER '%s': port=0x%x kr=%d\n",
                     name, port, kr);
        } else {
            bfix_log("[bfix] _xpc_look_up_endpoint LISTENER '%s': port=0x%x (kr=%d)\n",
                     name, port, kr);
        }
    } else {
        /* CLIENT look-up: get send right from broker */
        kern_return_t kr = replacement_bootstrap_look_up(bp, name, &port);
        if (kr != KERN_SUCCESS || port == MACH_PORT_NULL) {
            /* Service not found. Return a DEAD port instead of NULL.
             * With NULL, xpc_connection_send_message_with_reply_sync hangs
             * forever waiting for a dispatch event that never fires.
             * With a dead port, the send fails immediately with
             * MACH_SEND_INVALID_DEST and libxpc reports an error. */
            mach_port_t dead = MACH_PORT_NULL;
            mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &dead);
            /* Deallocate immediately → port becomes dead name for anyone holding send right */
            mach_port_deallocate(mach_task_self(), dead);
            port = dead;
            bfix_log("[bfix] _xpc_look_up_endpoint CLIENT '%s': NOT FOUND → dead port 0x%x\n",
                     name, port);
        } else {
            bfix_log("[bfix] _xpc_look_up_endpoint CLIENT '%s': port=0x%x\n", name, port);
        }
    }

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
        /* Bypass the XPC pipe protocol entirely for endpoint lookups.
         * _xpc_look_up_endpoint would send an XPC pipe message to launchd
         * and parse the response. We replace it with direct broker calls. */
        { "_xpc_look_up_endpoint", (void *)replacement_xpc_look_up_endpoint },
        /* Listener registration: builds proper 52-byte registration message
         * for dispatch_mach_connect (required for LISTENER mode to work). */
        { "_xpc_connection_check_in", (void *)replacement_xpc_connection_check_in },
        /* NOTE: launch_msg runtime trampoline REMOVED — causes infinite recursion
         * because fallthrough calls the patched function. DYLD interposition handles
         * cross-library calls; intra-library calls need saved-original approach. */
    };
    int n_patches = sizeof(patches) / sizeof(patches[0]);

    for (int i = 0; i < n_patches; i++) {
        void *orig = find_original_function(patches[i].name);
        if (orig) {
            write_trampoline(orig, patches[i].replacement, patches[i].name);
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
}
