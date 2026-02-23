/*
 * rosettasim_broker.c
 *
 * Mach port broker for RosettaSim - enables cross-process Mach port sharing
 * between backboardd and iOS app processes.
 *
 * Compiled as arm64 native macOS binary (NOT against iOS SDK).
 */

#include <mach/mach.h>
#include <mach/message.h>
#include <servers/bootstrap.h>
#include <spawn.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <sys/wait.h>
#include <sys/stat.h>
#include <stdarg.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <pthread.h>

#include "../shared/rosettasim_framebuffer.h"

/* MIG Message IDs (from bootstrap.defs subsystem 400) */
#define BOOTSTRAP_CHECK_IN      402
#define BOOTSTRAP_REGISTER      403
#define BOOTSTRAP_LOOK_UP       404
#define BOOTSTRAP_PARENT        406
#define BOOTSTRAP_SUBSET        409

#define BROKER_REGISTER_PORT    700
#define BROKER_LOOKUP_PORT      701
#define BROKER_SPAWN_APP        702
#define XPC_LAUNCH_MSG_ID       0x10000000
#define XPC_PIPE_REPLY_MSG_ID   0x20000000  /* libxpc expects replies to xpc_pipe_routine with this msgh_id */
#define XPC_LISTENER_REG_ID     0x77303074  /* listener registration from _xpc_connection_check_in */

#define MIG_REPLY_OFFSET        100

/* Error codes */
#define BOOTSTRAP_SUCCESS           0
#define BOOTSTRAP_NOT_PRIVILEGED    1100
#define BOOTSTRAP_NAME_IN_USE       1101
#define BOOTSTRAP_UNKNOWN_SERVICE   1102
#define BOOTSTRAP_SERVICE_ACTIVE    1103
#define BOOTSTRAP_BAD_COUNT         1104
#define BOOTSTRAP_NO_MEMORY         1105

/* Maximum registry entries — backboardd registers ~17, SpringBoard ~35, app ~5 */
#define MAX_SERVICES    128
#define MAX_NAME_LEN    128
#define BROKER_RECV_BUF_SIZE (64 * 1024)
/* ================================================================
 * PurpleFBServer (QuartzCore PurpleDisplay) protocol support
 *
 * For iOS 9.x runtimes, injecting our PurpleFBServer shim dylib into backboardd
 * can crash very early during libobjc image mapping. To keep backboardd alive,
 * we can host the PurpleFBServer Mach service directly in the broker and just
 * return its port from bootstrap_look_up("PurpleFBServer").
 * ================================================================ */

#define PFB_SERVICE_NAME      "PurpleFBServer"
#define PFB_TVOUT_SERVICE_NAME "PurpleFBTVOutServer"

/* iPhone 6s @ 2x (default device) */
#define PFB_PIXEL_WIDTH    750
#define PFB_PIXEL_HEIGHT   1334
#define PFB_POINT_WIDTH    375
#define PFB_POINT_HEIGHT   667
#define PFB_BYTES_PER_ROW  (PFB_PIXEL_WIDTH * 4)  /* BGRA = 4 bytes/pixel */
#define PFB_SURFACE_SIZE   (PFB_BYTES_PER_ROW * PFB_PIXEL_HEIGHT)
#define PFB_PAGE_SIZE      4096
#define PFB_SURFACE_PAGES  ((PFB_SURFACE_SIZE + PFB_PAGE_SIZE - 1) / PFB_PAGE_SIZE)
#define PFB_SURFACE_ALLOC  (PFB_SURFACE_PAGES * PFB_PAGE_SIZE)

typedef struct {
    mach_msg_header_t header;       /* 24 bytes */
    uint8_t           body[48];     /* remaining 48 bytes to reach 72 total */
} PurpleFBRequest;

#pragma pack(4)
typedef struct {
    mach_msg_header_t          header;          /* 24 bytes, offset 0 */
    mach_msg_body_t            body;            /*  4 bytes, offset 24 */
    mach_msg_port_descriptor_t port_desc;       /* 12 bytes, offset 28 */
    /* Inline data (32 bytes): */
    uint32_t                   memory_size;     /*  4 bytes, offset 40 */
    uint32_t                   stride;          /*  4 bytes, offset 44 */
    uint32_t                   unknown1;        /*  4 bytes, offset 48 */
    uint32_t                   unknown2;        /*  4 bytes, offset 52 */
    uint32_t                   pixel_width;     /*  4 bytes, offset 56 */
    uint32_t                   pixel_height;    /*  4 bytes, offset 60 */
    uint32_t                   point_width;     /*  4 bytes, offset 64 */
    uint32_t                   point_height;    /*  4 bytes, offset 68 */
} PurpleFBReply;
#pragma pack()

/* Service registry entry */
typedef struct {
    char name[MAX_NAME_LEN];
    mach_port_t port;
    int active;
    int receive_moved;  /* 1 if receive right already MOVE_RECEIVE'd to a caller */
} service_entry_t;

/* Global state */
static service_entry_t g_services[MAX_SERVICES];
static mach_port_t g_broker_port = MACH_PORT_NULL;
static mach_port_t g_rendezvous_port = MACH_PORT_NULL; /* XPC sim launchd rendezvous */
static mach_port_t g_port_set = MACH_PORT_NULL;        /* Port set for receiving */
static pid_t g_backboardd_pid = -1;
static volatile sig_atomic_t g_shutdown = 0;
/* Simulator runtime identity (used to populate SIMULATOR_RUNTIME_* env vars). */
static char g_sim_runtime_version[64] = "10.3";
static char g_sim_runtime_build_version[64] = "14E8301";

/* Broker-hosted PurpleFBServer state (used to boot iOS 9.x runtimes without
 * injecting purple_fb_server.dylib into backboardd). */
static int g_pfb_broker_enabled = 0;
static mach_port_t g_pfb_port = MACH_PORT_NULL;
static mach_port_t g_pfb_memory_entry = MACH_PORT_NULL;
static vm_address_t g_pfb_surface_addr = 0;
static void *g_pfb_shared_fb = MAP_FAILED;
static int g_pfb_shared_fd = -1;
static pthread_t g_pfb_sync_thread;
static volatile int g_pfb_sync_running = 0;

/* Use system's NDR_record - already defined in mach/ndr.h */

static int pfb_broker_init(void);
static void pfb_handle_message(mach_msg_header_t *request);

/* Message structures — match actual MIG wire format:
 * look_up/check_in request: header(24) + NDR(8) + name_t(128) = 160 bytes
 * register request: header(24) + body(4) + port_desc(12) + NDR(8) + name_t(128) = 176 bytes
 * port reply: header(24) + body(4) + port_desc(12) = 40 bytes
 * error reply: header(24) + NDR(8) + retcode(4) = 36 bytes
 */
#pragma pack(4)
typedef struct {
    mach_msg_header_t head;
    NDR_record_t ndr;
    char name[MAX_NAME_LEN]; /* name_t: fixed 128 bytes, no length prefix */
} bootstrap_simple_request_t;

typedef struct {
    mach_msg_header_t head;
    mach_msg_body_t body;
    mach_msg_port_descriptor_t port_desc;
    NDR_record_t ndr;
    char name[MAX_NAME_LEN];
} bootstrap_complex_request_t;

typedef struct {
    mach_msg_header_t head;
    mach_msg_body_t body;
    mach_msg_port_descriptor_t port_desc;
} bootstrap_port_reply_t;

typedef struct {
    mach_msg_header_t head;
    NDR_record_t ndr;
    kern_return_t ret_code;
} bootstrap_error_reply_t;

/* Legacy custom broker message format (used by purple_fb_server.c, ID 700+).
 * These have a name_len prefix unlike the standard MIG format. */
typedef struct {
    mach_msg_header_t head;
    NDR_record_t ndr;
    uint32_t name_len;
    char name[MAX_NAME_LEN];
} broker_simple_request_t;

typedef struct {
    mach_msg_header_t head;
    mach_msg_body_t body;
    mach_msg_port_descriptor_t port_desc;
    NDR_record_t ndr;
    uint32_t name_len;
    char name[MAX_NAME_LEN];
} broker_complex_request_t;
#pragma pack()

/* Logging function */
static void broker_log(const char *fmt, ...) {
    char buf[512];
    va_list args;
    va_start(args, fmt);
    int len = vsnprintf(buf, sizeof(buf), fmt, args);
    va_end(args);

    if (len > 0 && (size_t)len < sizeof(buf)) {
        write(STDERR_FILENO, buf, len);
    }
}

/* Signal handlers */
static void sigchld_handler(int sig) {
    (void)sig;
    int status;
    pid_t pid;

    while ((pid = waitpid(-1, &status, WNOHANG)) > 0) {
        if (pid == g_backboardd_pid) {
            broker_log("[broker] backboardd (pid %d) terminated\n", pid);
            g_backboardd_pid = -1;
            g_shutdown = 1;
        } else {
            if (WIFEXITED(status)) {
                broker_log("[broker] child process (pid %d) exited with status %d\n", pid, WEXITSTATUS(status));
            } else if (WIFSIGNALED(status)) {
                broker_log("[broker] child process (pid %d) killed by signal %d\n", pid, WTERMSIG(status));
            } else {
                broker_log("[broker] child process (pid %d) terminated (raw status 0x%x)\n", pid, status);
            }
        }
    }
}

static void sigterm_handler(int sig) {
    (void)sig;
    broker_log("[broker] received signal %d, shutting down\n", sig);
    g_shutdown = 1;
}

/* Service registry functions */
static int register_service(const char *name, mach_port_t port) {
    broker_log("[broker] registering service: %s -> 0x%x\n", name, port);

    /* Check if already registered */
    for (int i = 0; i < MAX_SERVICES; i++) {
        if (g_services[i].active && strcmp(g_services[i].name, name) == 0) {
            broker_log("[broker] service already registered: %s\n", name);
            return BOOTSTRAP_NAME_IN_USE;
        }
    }

    /* Find empty slot */
    for (int i = 0; i < MAX_SERVICES; i++) {
        if (!g_services[i].active) {
            strncpy(g_services[i].name, name, MAX_NAME_LEN - 1);
            g_services[i].name[MAX_NAME_LEN - 1] = '\0';
            g_services[i].port = port;
            g_services[i].active = 1;
            broker_log("[broker] registered service %s in slot %d\n", name, i);
            return BOOTSTRAP_SUCCESS;
        }
    }

    broker_log("[broker] no free slots for service: %s\n", name);
    return BOOTSTRAP_NO_MEMORY;
}

static mach_port_t lookup_service(const char *name) {
    broker_log("[broker] looking up service: %s\n", name);

    for (int i = 0; i < MAX_SERVICES; i++) {
        if (g_services[i].active && strcmp(g_services[i].name, name) == 0) {
            broker_log("[broker] found service %s -> 0x%x\n", name, g_services[i].port);
            return g_services[i].port;
        }
    }

    broker_log("[broker] service not found: %s\n", name);
    return MACH_PORT_NULL;
}

/* Send reply with port descriptor.
 * disposition: MACH_MSG_TYPE_MOVE_RECEIVE for check_in,
 *              MACH_MSG_TYPE_COPY_SEND for look_up */
static kern_return_t send_port_reply(mach_port_t reply_port, uint32_t msg_id,
                                      mach_port_t port, mach_msg_type_name_t disposition) {
    bootstrap_port_reply_t reply;
    memset(&reply, 0, sizeof(reply));

    reply.head.msgh_bits = MACH_MSGH_BITS_COMPLEX | MACH_MSGH_BITS(MACH_MSG_TYPE_MOVE_SEND_ONCE, 0);
    reply.head.msgh_size = sizeof(reply);
    reply.head.msgh_remote_port = reply_port;
    reply.head.msgh_local_port = MACH_PORT_NULL;
    reply.head.msgh_id = msg_id;

    reply.body.msgh_descriptor_count = 1;

    reply.port_desc.name = port;
    reply.port_desc.disposition = disposition;
    reply.port_desc.type = MACH_MSG_PORT_DESCRIPTOR;

    kern_return_t kr = mach_msg(&reply.head, MACH_SEND_MSG, sizeof(reply), 0,
                                 MACH_PORT_NULL, MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL);

    if (kr != KERN_SUCCESS) {
        broker_log("[broker] failed to send port reply: 0x%x\n", kr);
    }

    return kr;
}

/* Send error reply */
static kern_return_t send_error_reply(mach_port_t reply_port, uint32_t msg_id, kern_return_t error) {
    bootstrap_error_reply_t reply;
    memset(&reply, 0, sizeof(reply));

    reply.head.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_MOVE_SEND_ONCE, 0);
    reply.head.msgh_size = sizeof(reply);
    reply.head.msgh_remote_port = reply_port;
    reply.head.msgh_local_port = MACH_PORT_NULL;
    reply.head.msgh_id = msg_id;

    reply.ndr = NDR_record;
    reply.ret_code = error;

    kern_return_t kr = mach_msg(&reply.head, MACH_SEND_MSG, sizeof(reply), 0,
                                 MACH_PORT_NULL, MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL);

    if (kr != KERN_SUCCESS) {
        broker_log("[broker] failed to send error reply: 0x%x\n", kr);
    }

    return kr;
}

/* Handle bootstrap_check_in (ID 402)
 * Creates a new port, sends RECEIVE right to caller, keeps SEND right for look_ups.
 * This is how launchd works: the service daemon gets the receive right,
 * and clients get send rights through look_up. */
static void handle_check_in(mach_msg_header_t *request) {
    bootstrap_simple_request_t *req = (bootstrap_simple_request_t *)request;
    char service_name[MAX_NAME_LEN];

    memcpy(service_name, req->name, MAX_NAME_LEN);
    service_name[MAX_NAME_LEN - 1] = '\0';

    /* Find existing service entry */
    int slot = -1;
    for (int i = 0; i < MAX_SERVICES; i++) {
        if (g_services[i].active && strcmp(g_services[i].name, service_name) == 0) {
            slot = i;
            break;
        }
    }

    broker_log("[broker] check_in '%s': reply_port=0x%x slot=%d moved=%d\n",
               service_name, request->msgh_remote_port,
               slot, slot >= 0 ? g_services[slot].receive_moved : 0);

    /* GUARD: if receive right was already moved, block the repeat */
    if (slot >= 0 && g_services[slot].receive_moved) {
        broker_log("[broker] check_in '%s': repeat-blocked (receive already moved for port 0x%x)\n",
                   service_name, g_services[slot].port);
        send_error_reply(request->msgh_remote_port,
                         request->msgh_id + MIG_REPLY_OFFSET,
                         BOOTSTRAP_SERVICE_ACTIVE);
        return;
    }

    mach_port_t service_port = MACH_PORT_NULL;

    if (slot >= 0) {
        /* First check_in for pre-created service */
        service_port = g_services[slot].port;
        broker_log("[broker] check_in '%s': FIRST, pre-created port 0x%x\n",
                   service_name, service_port);
    } else {
        /* Not pre-created — create a new port */
        kern_return_t kr = mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &service_port);
        if (kr != KERN_SUCCESS) {
            send_error_reply(request->msgh_remote_port, request->msgh_id + MIG_REPLY_OFFSET, BOOTSTRAP_NO_MEMORY);
            return;
        }
        kr = mach_port_insert_right(mach_task_self(), service_port, service_port, MACH_MSG_TYPE_MAKE_SEND);
        if (kr != KERN_SUCCESS) {
            mach_port_deallocate(mach_task_self(), service_port);
            send_error_reply(request->msgh_remote_port, request->msgh_id + MIG_REPLY_OFFSET, BOOTSTRAP_NO_MEMORY);
            return;
        }
        int result = register_service(service_name, service_port);
        if (result != BOOTSTRAP_SUCCESS) {
            mach_port_deallocate(mach_task_self(), service_port);
            send_error_reply(request->msgh_remote_port, request->msgh_id + MIG_REPLY_OFFSET, result);
            return;
        }
        for (int i = 0; i < MAX_SERVICES; i++) {
            if (g_services[i].active && strcmp(g_services[i].name, service_name) == 0) {
                slot = i;
                break;
            }
        }
    }

    /* Send RECEIVE right to caller (MOVE_RECEIVE transfers ownership) */
    send_port_reply(request->msgh_remote_port, request->msgh_id + MIG_REPLY_OFFSET,
                    service_port, MACH_MSG_TYPE_MOVE_RECEIVE);

    if (slot >= 0) {
        g_services[slot].receive_moved = 1;
    }
    broker_log("[broker] check_in '%s': MOVE_RECEIVE sent, port=0x%x\n",
               service_name, service_port);
}

/* Handle bootstrap_register (ID 403)
 * Caller sends a send right, broker stores it for look_ups. */
static void handle_register(mach_msg_header_t *request) {
    bootstrap_complex_request_t *req = (bootstrap_complex_request_t *)request;
    char service_name[MAX_NAME_LEN];

    /* Extract service name (fixed 128-byte field) */
    memcpy(service_name, req->name, MAX_NAME_LEN);
    service_name[MAX_NAME_LEN - 1] = '\0';

    mach_port_t service_port = req->port_desc.name;

    broker_log("[broker] register request: %s -> 0x%x\n", service_name, service_port);

    /* Register service */
    int result = register_service(service_name, service_port);

    /* Send reply */
    send_error_reply(request->msgh_remote_port, request->msgh_id + MIG_REPLY_OFFSET, result);
}

/* Handle bootstrap_look_up (ID 404)
 * Returns a COPY_SEND right to the caller. */
static void handle_look_up(mach_msg_header_t *request) {
    bootstrap_simple_request_t *req = (bootstrap_simple_request_t *)request;
    char service_name[MAX_NAME_LEN];

    /* Extract service name (fixed 128-byte field) */
    memcpy(service_name, req->name, MAX_NAME_LEN);
    service_name[MAX_NAME_LEN - 1] = '\0';

    broker_log("[broker] look_up request: %s\n", service_name);

    /* Look up service */
    mach_port_t service_port = lookup_service(service_name);

    if (service_port == MACH_PORT_NULL) {
        send_error_reply(request->msgh_remote_port, request->msgh_id + MIG_REPLY_OFFSET, BOOTSTRAP_UNKNOWN_SERVICE);
    } else {
        send_port_reply(request->msgh_remote_port, request->msgh_id + MIG_REPLY_OFFSET,
                        service_port, MACH_MSG_TYPE_COPY_SEND);
    }
}

/* Handle bootstrap_parent */
static void handle_parent(mach_msg_header_t *request) {
    broker_log("[broker] bootstrap_parent request (ignoring)\n");

    /* Reply with error to indicate we don't support this */
    send_error_reply(request->msgh_remote_port, request->msgh_id + MIG_REPLY_OFFSET, KERN_INVALID_RIGHT);
}

/* Handle bootstrap_subset */
static void handle_subset(mach_msg_header_t *request) {
    broker_log("[broker] bootstrap_subset request (unsupported)\n");

    /* Reply with error - same as real macOS bootstrap */
    send_error_reply(request->msgh_remote_port, request->msgh_id + MIG_REPLY_OFFSET, KERN_INVALID_RIGHT);
}

/* Handle custom broker messages */
static void handle_broker_message(mach_msg_header_t *request) {
    switch (request->msgh_id) {
        case BROKER_REGISTER_PORT: {
            /* Legacy format with name_len prefix */
            broker_complex_request_t *req = (broker_complex_request_t *)request;
            char service_name[MAX_NAME_LEN];

            uint32_t name_len = req->name_len;
            if (name_len >= MAX_NAME_LEN) name_len = MAX_NAME_LEN - 1;
            memcpy(service_name, req->name, name_len);
            service_name[name_len] = '\0';

            mach_port_t service_port = req->port_desc.name;

            broker_log("[broker] custom register_port: %s -> 0x%x\n", service_name, service_port);

            int result = register_service(service_name, service_port);
            send_error_reply(request->msgh_remote_port, request->msgh_id + MIG_REPLY_OFFSET, result);
            break;
        }

        case BROKER_LOOKUP_PORT: {
            /* Legacy format with name_len prefix */
            broker_simple_request_t *req = (broker_simple_request_t *)request;
            char service_name[MAX_NAME_LEN];

            uint32_t name_len = req->name_len;
            if (name_len >= MAX_NAME_LEN) name_len = MAX_NAME_LEN - 1;
            memcpy(service_name, req->name, name_len);
            service_name[name_len] = '\0';

            broker_log("[broker] custom lookup_port: %s\n", service_name);

            mach_port_t service_port = lookup_service(service_name);

            if (service_port == MACH_PORT_NULL) {
                send_error_reply(request->msgh_remote_port, request->msgh_id + MIG_REPLY_OFFSET, BOOTSTRAP_UNKNOWN_SERVICE);
            } else {
                send_port_reply(request->msgh_remote_port, request->msgh_id + MIG_REPLY_OFFSET,
                                service_port, MACH_MSG_TYPE_COPY_SEND);
            }
            break;
        }

        case BROKER_SPAWN_APP:
            broker_log("[broker] spawn_app request (not yet implemented)\n");
            send_error_reply(request->msgh_remote_port, request->msgh_id + MIG_REPLY_OFFSET, KERN_NOT_SUPPORTED);
            break;

        default:
            broker_log("[broker] unknown broker message: %d\n", request->msgh_id);
            send_error_reply(request->msgh_remote_port, request->msgh_id + MIG_REPLY_OFFSET, MIG_BAD_ID);
            break;
    }
}

/* --- XPC pipe check-in protocol handler ---
 *
 * libxpc's xpc_connection_create_mach_service(LISTENER) sends an XPC pipe
 * message (ID 0x10000000) to the bootstrap port requesting check-in.
 * We must respond with a proper XPC-formatted reply containing the
 * MachServices dictionary with receive rights for the requested service.
 *
 * XPC wire format:
 *   4 bytes: magic "!CPX" (0x58504321)
 *   4 bytes: version (5)
 *   4 bytes: root type (0x0000f000 = dictionary)
 *   4 bytes: root size
 *   4 bytes: entry count
 *   entries: key (null-padded to 4-byte align) + type(4) + value
 *
 * Type codes (iOS 10.3 simulator libxpc.dylib):
 *   0x00002000 = bool
 *   0x00003000 = int64
 *   0x00004000 = uint64
 *   0x00009000 = string (4-byte length prefix, null-terminated, padded)
 *   0x0000f000 = dictionary
 *   0x0000d000 = mach_send (port in descriptor, not inline)
 *   0x00015000 = mach_recv (port in descriptor, not inline)
 *
 * NOTE: If the XPC type (mach_send vs mach_recv) or the Mach descriptor disposition
 * mismatches what libxpc expects, libxpc will clean up the right and treat the value
 * as invalid (leading to later "Connection invalid" failures).
 */

#define XPC_MAGIC       0x58504321  /* "!CPX" */
#define XPC_VERSION     5
/* XPC wire type IDs — from libxpc.dylib class table (iOS 10.3 simulator).
 * These are index << 12: null=1, bool=2, int64=3, uint64=4, ... */
#define XPC_TYPE_BOOL   0x00002000  /* index 2 */
#define XPC_TYPE_INT64  0x00003000  /* index 3 */
#define XPC_TYPE_UINT64 0x00004000  /* index 4 */
#define XPC_TYPE_STRING 0x00009000  /* index 9 */
#define XPC_TYPE_MACH_SEND 0x0000d000  /* index 13 */
#define XPC_TYPE_ARRAY  0x0000e000  /* index 14 */
#define XPC_TYPE_DICT   0x0000f000  /* index 15 */
#define XPC_TYPE_MACH_RECV 0x00015000  /* index 21 */

/* Extract the service name from an XPC pipe check-in request.
 * Scans the XPC dictionary for the "name" key and returns its string value. */
static const char *xpc_extract_service_name(const uint8_t *xpc_data, uint32_t xpc_len) {
    if (xpc_len < 16) return NULL;

    uint32_t magic = *(uint32_t *)xpc_data;
    if (magic != XPC_MAGIC) return NULL;

    uint32_t root_type = *(uint32_t *)(xpc_data + 8);
    if (root_type != XPC_TYPE_DICT) return NULL;

    uint32_t root_size = *(uint32_t *)(xpc_data + 12);
    uint32_t entry_count = *(uint32_t *)(xpc_data + 16);

    /* Walk entries starting at offset 20 */
    uint32_t pos = 20;
    for (uint32_t i = 0; i < entry_count && pos < xpc_len; i++) {
        /* Key: null-terminated string, padded to 4-byte boundary */
        const char *key = (const char *)(xpc_data + pos);
        uint32_t key_len = (uint32_t)strnlen(key, xpc_len - pos);
        uint32_t key_padded = (key_len + 1 + 3) & ~3; /* align to 4 */
        pos += key_padded;

        if (pos + 8 > xpc_len) break;

        /* Value: type (4 bytes) + type-specific data */
        uint32_t val_type = *(uint32_t *)(xpc_data + pos);
        pos += 4;

        if (val_type == XPC_TYPE_INT64 || val_type == XPC_TYPE_UINT64) {
            /* 8-byte integer (int64=0x3000 or uint64=0x4000) */
            if (pos + 8 > xpc_len) break;
            pos += 8;
        } else if (val_type == XPC_TYPE_STRING) {
            /* 4-byte length + string data (padded) */
            if (pos + 4 > xpc_len) break;
            uint32_t str_len = *(uint32_t *)(xpc_data + pos);
            pos += 4;
            if (strcmp(key, "name") == 0 && pos + str_len <= xpc_len) {
                return (const char *)(xpc_data + pos);
            }
            uint32_t str_padded = (str_len + 3) & ~3;
            pos += str_padded;
        } else if (val_type == XPC_TYPE_BOOL) {
            /* Bool: value is in the size field (already read as type) */
            /* Actually bool has a 4-byte value after type */
            if (pos + 4 > xpc_len) break;
            pos += 4;
        } else if (val_type == XPC_TYPE_DICT) {
            /* Nested dictionary — skip by reading its size */
            if (pos + 4 > xpc_len) break;
            uint32_t dict_size = *(uint32_t *)(xpc_data + pos);
            pos += 4;
            pos += dict_size;
        } else {
            /* Unknown type — try to skip using size */
            if (pos + 4 > xpc_len) break;
            uint32_t skip = *(uint32_t *)(xpc_data + pos);
            pos += 4;
            if (skip < 0x10000) pos += skip; /* sanity limit */
            else break;
        }
    }

    return NULL;
}

/* Extract an int64 value for a specific key from the root XPC dictionary.
 * Returns 0 if not found. */
static uint64_t xpc_extract_int64_key(const uint8_t *xpc_data, uint32_t xpc_len,
                                      const char *wanted_key) {
    if (xpc_len < 20) return 0;
    uint32_t magic = *(uint32_t *)xpc_data;
    if (magic != XPC_MAGIC) return 0;
    uint32_t root_type = *(uint32_t *)(xpc_data + 8);
    if (root_type != XPC_TYPE_DICT) return 0;
    uint32_t entry_count = *(uint32_t *)(xpc_data + 16);
    uint32_t pos = 20;
    for (uint32_t i = 0; i < entry_count && pos < xpc_len; i++) {
        const char *key = (const char *)(xpc_data + pos);
        uint32_t key_len = (uint32_t)strnlen(key, xpc_len - pos);
        uint32_t key_padded = (key_len + 1 + 3) & ~3;
        pos += key_padded;
        if (pos + 4 > xpc_len) break;
        uint32_t val_type = *(uint32_t *)(xpc_data + pos);
        pos += 4;
        if (val_type == XPC_TYPE_INT64 || val_type == XPC_TYPE_UINT64) {
            if (pos + 8 > xpc_len) break;
            if (strcmp(key, wanted_key) == 0) {
                return *(uint64_t *)(xpc_data + pos);
            }
            pos += 8;
        } else if (val_type == XPC_TYPE_STRING) {
            if (pos + 4 > xpc_len) break;
            uint32_t str_len = *(uint32_t *)(xpc_data + pos);
            pos += 4;
            uint32_t str_padded = (str_len + 3) & ~3;
            pos += str_padded;
        } else if (val_type == XPC_TYPE_BOOL) {
            if (pos + 4 > xpc_len) break;
            pos += 4;
        } else if (val_type == XPC_TYPE_DICT) {
            if (pos + 4 > xpc_len) break;
            uint32_t dict_size = *(uint32_t *)(xpc_data + pos);
            pos += 4;
            pos += dict_size;
        } else {
            if (pos + 4 > xpc_len) break;
            uint32_t skip = *(uint32_t *)(xpc_data + pos);
            pos += 4;
            if (skip < 0x10000) pos += skip;
            else break;
        }
    }
    return 0;
}

/* Extract the "routine" int64 value from XPC dict. Returns 0 if not found. */
static uint64_t xpc_extract_routine(const uint8_t *xpc_data, uint32_t xpc_len) {
    return xpc_extract_int64_key(xpc_data, xpc_len, "routine");
}

/* Extract the "handle" int64 value from XPC dict. Returns 0 if not found. */
static uint64_t xpc_extract_handle(const uint8_t *xpc_data, uint32_t xpc_len) {
    return xpc_extract_int64_key(xpc_data, xpc_len, "handle");
}

/* Send a proper XPC-formatted reply (non-complex, no ports).
 * Used for non-check-in launchd routines and error cases on XPC pipe.
 *
 * NOTE: libxpc's _xpc_pipe_routine expects replies to use a fixed Mach
 * message ID (XPC_PIPE_REPLY_MSG_ID = 0x20000000). If we echo the request
 * ID (0x10000000), libxpc will not unpack the reply dictionary.
 *
 * NEVER use send_error_reply (MIG format) for XPC pipe messages. */
static void send_xpc_pipe_reply(mach_port_t reply_port, uint32_t msg_id,
                                 uint64_t routine, int64_t error_code) {
    if (reply_port == MACH_PORT_NULL) return;

    /* Build minimal XPC dict: { subsystem=3, error=<code>, routine=<routine> } */
    uint8_t xpc_buf[256];
    uint32_t xpc_pos = 20; /* skip header (magic+version+type+size) + entry_count */
    uint32_t entries = 0;

    /* "subsystem" → int64(3) */
    {
        const char *k = "subsystem";
        uint32_t kpad = ((uint32_t)strlen(k) + 1 + 3) & ~3;
        memset(xpc_buf + xpc_pos, 0, kpad);
        memcpy(xpc_buf + xpc_pos, k, strlen(k));
        xpc_pos += kpad;
        *(uint32_t *)(xpc_buf + xpc_pos) = XPC_TYPE_INT64; xpc_pos += 4;
        *(uint64_t *)(xpc_buf + xpc_pos) = 3; xpc_pos += 8;
        entries++;
    }
    /* "error" → int64(error_code) */
    {
        const char *k = "error";
        uint32_t kpad = ((uint32_t)strlen(k) + 1 + 3) & ~3;
        memset(xpc_buf + xpc_pos, 0, kpad);
        memcpy(xpc_buf + xpc_pos, k, strlen(k));
        xpc_pos += kpad;
        *(uint32_t *)(xpc_buf + xpc_pos) = XPC_TYPE_INT64; xpc_pos += 4;
        *(uint64_t *)(xpc_buf + xpc_pos) = (uint64_t)error_code; xpc_pos += 8;
        entries++;
    }
    /* "routine" → int64(routine) */
    {
        const char *k = "routine";
        uint32_t kpad = ((uint32_t)strlen(k) + 1 + 3) & ~3;
        memset(xpc_buf + xpc_pos, 0, kpad);
        memcpy(xpc_buf + xpc_pos, k, strlen(k));
        xpc_pos += kpad;
        *(uint32_t *)(xpc_buf + xpc_pos) = XPC_TYPE_INT64; xpc_pos += 4;
        *(uint64_t *)(xpc_buf + xpc_pos) = routine; xpc_pos += 8;
        entries++;
    }

    /* Fill XPC header */
    *(uint32_t *)(xpc_buf + 0) = XPC_MAGIC;
    *(uint32_t *)(xpc_buf + 4) = XPC_VERSION;
    *(uint32_t *)(xpc_buf + 8) = XPC_TYPE_DICT;
    *(uint32_t *)(xpc_buf + 12) = xpc_pos - 16;
    *(uint32_t *)(xpc_buf + 16) = entries;

    uint32_t xpc_padded = (xpc_pos + 3) & ~3;

    /* Build non-complex Mach message with XPC payload */
    struct {
        mach_msg_header_t head;
        uint8_t data[256];
    } reply;
    memset(&reply, 0, sizeof(reply));

    reply.head.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_MOVE_SEND_ONCE, 0);
    reply.head.msgh_size = sizeof(mach_msg_header_t) + xpc_padded;
    reply.head.msgh_remote_port = reply_port;
    reply.head.msgh_local_port = MACH_PORT_NULL;
    (void)msg_id; /* Requests use XPC_LAUNCH_MSG_ID; libxpc expects a fixed reply ID. */
    reply.head.msgh_id = XPC_PIPE_REPLY_MSG_ID;

    memcpy(reply.data, xpc_buf, xpc_pos);

    kern_return_t kr = mach_msg(&reply.head, MACH_SEND_MSG, reply.head.msgh_size,
                                 0, MACH_PORT_NULL, MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL);
    if (kr != KERN_SUCCESS) {
        broker_log("[broker] send_xpc_pipe_reply failed: 0x%x\n", kr);
    }
}

/* Send routine=100 (GetJobs) reply with a jobs dict containing
 * assertiond's MachServices. assertiond calls launch_msg("GetJobs")
 * via _xpc_pipe_routine early in init; "Error getting job dictionaries.
 * Error: Input/output error (5)" fires when this returns empty/error.
 * The response must include: { subsystem=3, error=0, routine=100,
 *   jobs → { "com.apple.assertiond" → { MachServices → { svc → true, ... } } } } */
static void send_xpc_pipe_getjobs_reply(mach_port_t reply_port, uint32_t msg_id,
                                         uint64_t request_handle) {
    if (reply_port == MACH_PORT_NULL) return;

    uint8_t xpc_buf[2048];
    uint32_t xpc_pos = 20;
    uint32_t entries = 0;
    int total_svc_count = 0;

    /* Helper macro for adding an int64 entry */
    #define ADD_INT64(key_str, val) do { \
        const char *_k = (key_str); \
        uint32_t _kpad = ((uint32_t)strlen(_k) + 1 + 3) & ~3; \
        memset(xpc_buf + xpc_pos, 0, _kpad); \
        memcpy(xpc_buf + xpc_pos, _k, strlen(_k)); \
        xpc_pos += _kpad; \
        *(uint32_t *)(xpc_buf + xpc_pos) = XPC_TYPE_INT64; xpc_pos += 4; \
        *(uint64_t *)(xpc_buf + xpc_pos) = (uint64_t)(val); xpc_pos += 8; \
        entries++; \
    } while(0)

    ADD_INT64("subsystem", 3);
    ADD_INT64("error", 0);
    ADD_INT64("routine", 100);
    ADD_INT64("handle", request_handle);

    /* "jobs" → dict { "com.apple.assertiond" → dict { "MachServices" → dict { svc→true } } } */
    {
        const char *k = "jobs";
        uint32_t kpad = ((uint32_t)strlen(k) + 1 + 3) & ~3;
        memset(xpc_buf + xpc_pos, 0, kpad);
        memcpy(xpc_buf + xpc_pos, k, strlen(k));
        xpc_pos += kpad;

        *(uint32_t *)(xpc_buf + xpc_pos) = XPC_TYPE_DICT; xpc_pos += 4;
        uint32_t jobs_size_pos = xpc_pos; xpc_pos += 4;
        uint32_t jobs_start = xpc_pos;
        *(uint32_t *)(xpc_buf + xpc_pos) = 1; xpc_pos += 4; /* 1 job entry */

        /* Job key: "com.apple.assertiond" */
        const char *job_label = "com.apple.assertiond";
        uint32_t jpad = ((uint32_t)strlen(job_label) + 1 + 3) & ~3;
        memset(xpc_buf + xpc_pos, 0, jpad);
        memcpy(xpc_buf + xpc_pos, job_label, strlen(job_label));
        xpc_pos += jpad;

        /* Job value: dict { "Label" → string, "MachServices" → dict { svc→true, ... } } */
        *(uint32_t *)(xpc_buf + xpc_pos) = XPC_TYPE_DICT; xpc_pos += 4;
        uint32_t job_size_pos = xpc_pos; xpc_pos += 4;
        uint32_t job_start = xpc_pos;
        *(uint32_t *)(xpc_buf + xpc_pos) = 2; xpc_pos += 4; /* 2 entries: Label + MachServices */

        /* "Label" → string("com.apple.assertiond") */
        {
            const char *lk = "Label";
            uint32_t lkpad = ((uint32_t)strlen(lk) + 1 + 3) & ~3;
            memset(xpc_buf + xpc_pos, 0, lkpad);
            memcpy(xpc_buf + xpc_pos, lk, strlen(lk));
            xpc_pos += lkpad;
            *(uint32_t *)(xpc_buf + xpc_pos) = XPC_TYPE_STRING; xpc_pos += 4;
            uint32_t lv_len = (uint32_t)strlen(job_label) + 1; /* include null */
            *(uint32_t *)(xpc_buf + xpc_pos) = lv_len; xpc_pos += 4;
            uint32_t lv_pad = (lv_len + 3) & ~3;
            memset(xpc_buf + xpc_pos, 0, lv_pad);
            memcpy(xpc_buf + xpc_pos, job_label, strlen(job_label));
            xpc_pos += lv_pad;
        }

        /* "MachServices" key */
        const char *ms_key = "MachServices";
        uint32_t mspad = ((uint32_t)strlen(ms_key) + 1 + 3) & ~3;
        memset(xpc_buf + xpc_pos, 0, mspad);
        memcpy(xpc_buf + xpc_pos, ms_key, strlen(ms_key));
        xpc_pos += mspad;

        /* MachServices value: dict of assertiond services → bool(true) */
        *(uint32_t *)(xpc_buf + xpc_pos) = XPC_TYPE_DICT; xpc_pos += 4;
        uint32_t ms_size_pos = xpc_pos; xpc_pos += 4;
        uint32_t ms_start = xpc_pos;

        /* Count assertiond services */
        for (int i = 0; i < MAX_SERVICES; i++) {
            if (g_services[i].active && strstr(g_services[i].name, "assertiond")) {
                total_svc_count++;
            }
        }
        *(uint32_t *)(xpc_buf + xpc_pos) = (uint32_t)total_svc_count; xpc_pos += 4;

        /* Add each assertiond service as bool(true) */
        for (int i = 0; i < MAX_SERVICES; i++) {
            if (g_services[i].active && strstr(g_services[i].name, "assertiond")) {
                uint32_t slen = (uint32_t)strlen(g_services[i].name);
                uint32_t spad_n = (slen + 1 + 3) & ~3;
                memset(xpc_buf + xpc_pos, 0, spad_n);
                memcpy(xpc_buf + xpc_pos, g_services[i].name, slen);
                xpc_pos += spad_n;
                *(uint32_t *)(xpc_buf + xpc_pos) = XPC_TYPE_BOOL; xpc_pos += 4;
                *(uint32_t *)(xpc_buf + xpc_pos) = 1; xpc_pos += 4; /* true */
            }
        }

        *(uint32_t *)(xpc_buf + ms_size_pos) = xpc_pos - ms_start;
        *(uint32_t *)(xpc_buf + job_size_pos) = xpc_pos - job_start;
        *(uint32_t *)(xpc_buf + jobs_size_pos) = xpc_pos - jobs_start;
        entries++;
    }

    /* ALSO add root-level "com.apple.assertiond" → job dict.
     * Legacy GetJobs callers may look for job-label keys at root level
     * rather than inside "jobs" sub-dict. Include both for compatibility. */
    {
        const char *jk = "com.apple.assertiond";
        uint32_t jkpad = ((uint32_t)strlen(jk) + 1 + 3) & ~3;
        memset(xpc_buf + xpc_pos, 0, jkpad);
        memcpy(xpc_buf + xpc_pos, jk, strlen(jk));
        xpc_pos += jkpad;

        *(uint32_t *)(xpc_buf + xpc_pos) = XPC_TYPE_DICT; xpc_pos += 4;
        uint32_t rj_size_pos = xpc_pos; xpc_pos += 4;
        uint32_t rj_start = xpc_pos;
        *(uint32_t *)(xpc_buf + xpc_pos) = 2; xpc_pos += 4; /* Label + MachServices */

        /* Label */
        {
            const char *lk = "Label";
            uint32_t lkp = ((uint32_t)strlen(lk) + 1 + 3) & ~3;
            memset(xpc_buf + xpc_pos, 0, lkp);
            memcpy(xpc_buf + xpc_pos, lk, strlen(lk));
            xpc_pos += lkp;
            *(uint32_t *)(xpc_buf + xpc_pos) = XPC_TYPE_STRING; xpc_pos += 4;
            uint32_t lv_len = (uint32_t)strlen(jk) + 1;
            *(uint32_t *)(xpc_buf + xpc_pos) = lv_len; xpc_pos += 4;
            uint32_t lv_pad = (lv_len + 3) & ~3;
            memset(xpc_buf + xpc_pos, 0, lv_pad);
            memcpy(xpc_buf + xpc_pos, jk, strlen(jk));
            xpc_pos += lv_pad;
        }

        /* MachServices */
        {
            const char *mk = "MachServices";
            uint32_t mkp = ((uint32_t)strlen(mk) + 1 + 3) & ~3;
            memset(xpc_buf + xpc_pos, 0, mkp);
            memcpy(xpc_buf + xpc_pos, mk, strlen(mk));
            xpc_pos += mkp;
            *(uint32_t *)(xpc_buf + xpc_pos) = XPC_TYPE_DICT; xpc_pos += 4;
            uint32_t rms_size_pos = xpc_pos; xpc_pos += 4;
            uint32_t rms_start = xpc_pos;
            *(uint32_t *)(xpc_buf + xpc_pos) = (uint32_t)total_svc_count; xpc_pos += 4;
            for (int i = 0; i < MAX_SERVICES; i++) {
                if (g_services[i].active && strstr(g_services[i].name, "assertiond")) {
                    uint32_t sl = (uint32_t)strlen(g_services[i].name);
                    uint32_t sp = (sl + 1 + 3) & ~3;
                    memset(xpc_buf + xpc_pos, 0, sp);
                    memcpy(xpc_buf + xpc_pos, g_services[i].name, sl);
                    xpc_pos += sp;
                    *(uint32_t *)(xpc_buf + xpc_pos) = XPC_TYPE_BOOL; xpc_pos += 4;
                    *(uint32_t *)(xpc_buf + xpc_pos) = 1; xpc_pos += 4;
                }
            }
            *(uint32_t *)(xpc_buf + rms_size_pos) = xpc_pos - rms_start;
        }

        *(uint32_t *)(xpc_buf + rj_size_pos) = xpc_pos - rj_start;
        entries++;
    }

    #undef ADD_INT64

    /* Fill XPC header */
    *(uint32_t *)(xpc_buf + 0) = XPC_MAGIC;
    *(uint32_t *)(xpc_buf + 4) = XPC_VERSION;
    *(uint32_t *)(xpc_buf + 8) = XPC_TYPE_DICT;
    *(uint32_t *)(xpc_buf + 12) = xpc_pos - 16;
    *(uint32_t *)(xpc_buf + 16) = entries;

    uint32_t xpc_padded = (xpc_pos + 3) & ~3;

    struct {
        mach_msg_header_t head;
        uint8_t data[2048];
    } reply;
    memset(&reply, 0, sizeof(reply));

    reply.head.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_MOVE_SEND_ONCE, 0);
    reply.head.msgh_size = sizeof(mach_msg_header_t) + xpc_padded;
    reply.head.msgh_remote_port = reply_port;
    reply.head.msgh_local_port = MACH_PORT_NULL;
    (void)msg_id;
    reply.head.msgh_id = XPC_PIPE_REPLY_MSG_ID;

    memcpy(reply.data, xpc_buf, xpc_pos);

    kern_return_t kr = mach_msg(&reply.head, MACH_SEND_MSG, reply.head.msgh_size,
                                 0, MACH_PORT_NULL, MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL);
    if (kr != KERN_SUCCESS) {
        broker_log("[broker] send_xpc_pipe_getjobs_reply failed: 0x%x\n", kr);
    } else {
        broker_log("[broker] sent GetJobs reply (%u bytes xpc, %d assertiond services)\n",
                   xpc_pos, total_svc_count);
    }
}

/* Build an XPC pipe check-in response (routine 805).
 * The response is a complex Mach message with:
 *   - Port descriptor (MOVE_RECEIVE for the service port)
 *   - XPC wire data containing a dictionary with:
 *     - "port" → mach_recv (consumes the port descriptor)
 */
static void handle_xpc_checkin(mach_msg_header_t *request,
                                const char *service_name,
                                mach_port_t service_port,
                                uint64_t request_handle) {
    broker_log("[broker] XPC check-in: building response for '%s' port=0x%x handle=%llu\n",
               service_name, service_port, request_handle);

    /* Build the XPC response payload:
     * Dictionary {
     *   "subsystem" → int64(3)
     *   "error" → int64(0)
     *   "routine" → int64(805)
     *   "handle" → int64(request_handle)
     *   "port" → mach_recv
     * }
     */
    uint8_t xpc_buf[512];
    uint32_t xpc_pos = 0;

    /* XPC header */
    *(uint32_t *)(xpc_buf + 0) = XPC_MAGIC;
    *(uint32_t *)(xpc_buf + 4) = XPC_VERSION;
    *(uint32_t *)(xpc_buf + 8) = XPC_TYPE_DICT; /* root type */
    /* root size and entry count filled later */
    xpc_pos = 20; /* skip header + size + count */

    uint32_t root_entries = 0;

    /* Helper: add int64 entry inline */
    #define CHECKIN_INT64(key_str, val) do { \
        const char *_ck = (key_str); \
        uint32_t _ckp = ((uint32_t)strlen(_ck) + 1 + 3) & ~3; \
        memset(xpc_buf + xpc_pos, 0, _ckp); \
        memcpy(xpc_buf + xpc_pos, _ck, strlen(_ck)); \
        xpc_pos += _ckp; \
        *(uint32_t *)(xpc_buf + xpc_pos) = XPC_TYPE_INT64; xpc_pos += 4; \
        *(uint64_t *)(xpc_buf + xpc_pos) = (uint64_t)(val); xpc_pos += 8; \
        root_entries++; \
    } while(0)

    CHECKIN_INT64("subsystem", 3);
    CHECKIN_INT64("error", 0);
    CHECKIN_INT64("routine", 805);

    /* Entry: \"port\" → mach_recv (no inline payload; consumes next descriptor)
     * Place before "handle" to match potential libxpc expectations */
    {
        const char *k = "port";
        uint32_t klen = (uint32_t)strlen(k);
        uint32_t kpad = (klen + 1 + 3) & ~3;
        memset(xpc_buf + xpc_pos, 0, kpad);
        memcpy(xpc_buf + xpc_pos, k, klen);
        xpc_pos += kpad;
        *(uint32_t *)(xpc_buf + xpc_pos) = XPC_TYPE_MACH_RECV;
        xpc_pos += 4;
        root_entries++;
    }

    CHECKIN_INT64("handle", request_handle);

    #undef CHECKIN_INT64

    broker_log("[broker] 805-reply: '%s' handle=%llu entries=%u port=0x%x\n",
               service_name, request_handle, root_entries, service_port);

    /* Fill root dict size and entry count.
     * Size includes count(4) + entries — matches the request format
     * where magic(4)+version(4)+type(4)+size(4) = 16 byte header,
     * and total XPC data = 16 + size. */
    *(uint32_t *)(xpc_buf + 16) = root_entries;
    *(uint32_t *)(xpc_buf + 12) = xpc_pos - 16; /* count + entries */

    /* Build the Mach message with ONE port descriptor + XPC payload.
     * desc[0] = service receive right (MOVE_RECEIVE) — consumed by the
     * XPC \"port\" mach_recv value above. */
    uint32_t xpc_data_len = xpc_pos;
    uint32_t xpc_padded = (xpc_data_len + 3) & ~3;

#pragma pack(4)
    struct {
        mach_msg_header_t head;
        mach_msg_body_t body;
        mach_msg_port_descriptor_t port_desc[1];
        uint8_t xpc_data[512];
    } reply;
#pragma pack()

    memset(&reply, 0, sizeof(reply));

    reply.head.msgh_bits = MACH_MSGH_BITS_COMPLEX |
        MACH_MSGH_BITS(MACH_MSG_TYPE_MOVE_SEND_ONCE, 0);
    reply.head.msgh_size = sizeof(mach_msg_header_t) + sizeof(mach_msg_body_t) +
        1 * sizeof(mach_msg_port_descriptor_t) + xpc_padded;
    reply.head.msgh_remote_port = request->msgh_remote_port;
    reply.head.msgh_local_port = MACH_PORT_NULL;
    reply.head.msgh_id = XPC_PIPE_REPLY_MSG_ID;
    reply.body.msgh_descriptor_count = 1;

    reply.port_desc[0].name = service_port;
    reply.port_desc[0].disposition = MACH_MSG_TYPE_MOVE_RECEIVE;
    reply.port_desc[0].type = MACH_MSG_PORT_DESCRIPTOR;

    memcpy(reply.xpc_data, xpc_buf, xpc_data_len);

    /* Hex dump the response for debugging */
    broker_log("[broker] XPC response for '%s' (%u bytes): ", service_name, reply.head.msgh_size);
    uint8_t *rraw = (uint8_t *)&reply;
    uint32_t dump = reply.head.msgh_size < 120 ? reply.head.msgh_size : 120;
    for (uint32_t d = 0; d < dump; d++) {
        if (d % 16 == 0) broker_log("\n[broker]   %04x: ", d);
        broker_log("%02x ", rraw[d]);
    }
    broker_log("\n");

    kern_return_t kr = mach_msg(&reply.head, MACH_SEND_MSG, reply.head.msgh_size,
                                 0, MACH_PORT_NULL, MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL);

    if (kr == KERN_SUCCESS) {
        broker_log("[broker] XPC check-in response sent for '%s'\n", service_name);
    } else {
        broker_log("[broker] XPC check-in response FAILED: 0x%x\n", kr);
    }
}
/* Build an XPC pipe endpoint lookup response (routine 804).
 * The response is a complex Mach message with:
 *   - Port descriptor (MOVE_SEND for the service port)
 *   - XPC wire data containing a dictionary with:
 *     - "port" → mach_send (consumes the port descriptor) */
static void handle_xpc_endpoint_lookup(mach_msg_header_t *request,
                                        const char *service_name,
                                        mach_port_t service_port,
                                        uint64_t request_handle) {
    broker_log("[broker] XPC endpoint lookup: building response for '%s' port=0x%x handle=%llu\n",
               service_name, service_port, request_handle);

    /* We must send MOVE_SEND (0x11) to satisfy libxpc's serializer.
     * Retain one extra send right so the broker keeps its original right. */
    kern_return_t kr = mach_port_mod_refs(mach_task_self(), service_port, MACH_PORT_RIGHT_SEND, 1);
    if (kr != KERN_SUCCESS) {
        broker_log("[broker] XPC endpoint lookup '%s': mach_port_mod_refs(+send) failed: 0x%x\n",
                   service_name, kr);
        send_xpc_pipe_reply(request->msgh_remote_port, request->msgh_id, 804, 5 /* EIO */);
        return;
    }

    uint8_t xpc_buf[512];
    uint32_t xpc_pos = 20;
    uint32_t root_entries = 0;

    #define LOOKUP_INT64(key_str, val) do { \
        const char *_lk = (key_str); \
        uint32_t _lkp = ((uint32_t)strlen(_lk) + 1 + 3) & ~3; \
        memset(xpc_buf + xpc_pos, 0, _lkp); \
        memcpy(xpc_buf + xpc_pos, _lk, strlen(_lk)); \
        xpc_pos += _lkp; \
        *(uint32_t *)(xpc_buf + xpc_pos) = XPC_TYPE_INT64; xpc_pos += 4; \
        *(uint64_t *)(xpc_buf + xpc_pos) = (uint64_t)(val); xpc_pos += 8; \
        root_entries++; \
    } while(0)

    LOOKUP_INT64("subsystem", 3);
    LOOKUP_INT64("error", 0);
    LOOKUP_INT64("routine", 804);
    LOOKUP_INT64("handle", request_handle);

    /* "port" → mach_send (no inline payload; consumes next descriptor) */
    {
        const char *k = "port";
        uint32_t klen = (uint32_t)strlen(k);
        uint32_t kpad = (klen + 1 + 3) & ~3;
        memset(xpc_buf + xpc_pos, 0, kpad);
        memcpy(xpc_buf + xpc_pos, k, klen);
        xpc_pos += kpad;
        *(uint32_t *)(xpc_buf + xpc_pos) = XPC_TYPE_MACH_SEND;
        xpc_pos += 4;
        root_entries++;
    }

    #undef LOOKUP_INT64

    *(uint32_t *)(xpc_buf + 0) = XPC_MAGIC;
    *(uint32_t *)(xpc_buf + 4) = XPC_VERSION;
    *(uint32_t *)(xpc_buf + 8) = XPC_TYPE_DICT; /* root type */
    *(uint32_t *)(xpc_buf + 16) = root_entries;
    *(uint32_t *)(xpc_buf + 12) = xpc_pos - 16;

    uint32_t xpc_padded = (xpc_pos + 3) & ~3;

#pragma pack(4)
    struct {
        mach_msg_header_t head;
        mach_msg_body_t body;
        mach_msg_port_descriptor_t port_desc[1];
        uint8_t xpc_data[512];
    } reply;
#pragma pack()

    memset(&reply, 0, sizeof(reply));
    reply.head.msgh_bits = MACH_MSGH_BITS_COMPLEX |
        MACH_MSGH_BITS(MACH_MSG_TYPE_MOVE_SEND_ONCE, 0);
    reply.head.msgh_size = sizeof(mach_msg_header_t) + sizeof(mach_msg_body_t) +
        1 * sizeof(mach_msg_port_descriptor_t) + xpc_padded;
    reply.head.msgh_remote_port = request->msgh_remote_port;
    reply.head.msgh_local_port = MACH_PORT_NULL;
    reply.head.msgh_id = XPC_PIPE_REPLY_MSG_ID;
    reply.body.msgh_descriptor_count = 1;

    reply.port_desc[0].name = service_port;
    reply.port_desc[0].disposition = MACH_MSG_TYPE_MOVE_SEND;
    reply.port_desc[0].type = MACH_MSG_PORT_DESCRIPTOR;

    memcpy(reply.xpc_data, xpc_buf, xpc_pos);

    kr = mach_msg(&reply.head, MACH_SEND_MSG, reply.head.msgh_size,
                   0, MACH_PORT_NULL, MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL);
    if (kr == KERN_SUCCESS) {
        broker_log("[broker] XPC endpoint lookup response sent for '%s'\n", service_name);
    } else {
        broker_log("[broker] XPC endpoint lookup response FAILED: 0x%x\n", kr);
    }
}

/* Handle XPC pipe message (msg_id 0x10000000) */
static void handle_xpc_launch_msg(mach_msg_header_t *request) {
    uint8_t *raw = (uint8_t *)request;
    uint32_t total = request->msgh_size;
    int is_complex = (request->msgh_bits & MACH_MSGH_BITS_COMPLEX) != 0;
    uint32_t data_offset = sizeof(mach_msg_header_t);
    uint32_t desc_count = 0;

    if (is_complex) {
        mach_msg_body_t *body = (mach_msg_body_t *)(raw + data_offset);
        desc_count = body->msgh_descriptor_count;
        data_offset += sizeof(mach_msg_body_t) + desc_count * sizeof(mach_msg_port_descriptor_t);
    }

    /* Extract XPC fields from inline data */
    const char *service_name = NULL;
    uint64_t routine = 0;
    uint64_t handle = 0;
    if (data_offset < total) {
        const uint8_t *xpc_data = raw + data_offset;
        uint32_t xpc_len = total - data_offset;
        service_name = xpc_extract_service_name(xpc_data, xpc_len);
        routine = xpc_extract_routine(xpc_data, xpc_len);
        handle = xpc_extract_handle(xpc_data, xpc_len);
    }

    broker_log("[broker] XPC pipe msg: size=%u routine=%llu handle=%llu name='%s'\n",
               total, routine, handle, service_name ? service_name : "(none)");
    broker_log("[broker] XPC pipe hdr: id=%u bits=0x%x complex=%d desc_count=%u remote=0x%x local=0x%x data_off=%u\n",
               request->msgh_id, request->msgh_bits, is_complex, desc_count,
               request->msgh_remote_port, request->msgh_local_port, data_offset);

    if (routine == 805 && service_name &&
        strncmp(service_name, "com.apple.assertiond.", 21) == 0) {
        uint32_t dump_len = total < 160 ? total : 160;
        broker_log("[broker] XPC 805 request dump '%s' (%u bytes):", service_name, total);
        for (uint32_t d = 0; d < dump_len; d++) {
            if (d % 16 == 0) broker_log("\n[broker]   %04x: ", d);
            broker_log("%02x ", raw[d]);
        }
        broker_log("\n");
    }

    /* Routine 804 = endpoint lookup (used by _xpc_look_up_endpoint). */
    if (routine == 804 && service_name) {
        mach_port_t service_port = lookup_service(service_name);
        if (service_port == MACH_PORT_NULL) {
            broker_log("[broker] XPC endpoint lookup: service '%s' not found\n", service_name);
            send_xpc_pipe_reply(request->msgh_remote_port, request->msgh_id, routine, 2 /* ENOENT */);
            return;
        }
        handle_xpc_endpoint_lookup(request, service_name, service_port, handle);
        return;
    }
    /* Routine 805 = check-in (LAUNCH_ROUTINE_CHECKIN) */
    if (routine == 805 && service_name) {
        /* Find the pre-created port for this service */
        mach_port_t service_port = MACH_PORT_NULL;
        int slot = -1;
        for (int i = 0; i < MAX_SERVICES; i++) {
            if (g_services[i].active && strcmp(g_services[i].name, service_name) == 0) {
                slot = i;
                break;
            }
        }

        /* GUARD: block repeat MOVE_RECEIVE via XPC pipe path too */
        if (slot >= 0 && g_services[slot].receive_moved) {
            broker_log("[broker] XPC check-in '%s': repeat-blocked (receive already moved for 0x%x)\n",
                       service_name, g_services[slot].port);
            send_xpc_pipe_reply(request->msgh_remote_port, request->msgh_id, routine, 17 /* EEXIST */);
            return;
        }

        if (slot >= 0) {
            service_port = g_services[slot].port;
            handle_xpc_checkin(request, service_name, service_port, handle);
            g_services[slot].receive_moved = 1;
            return;
        }

        broker_log("[broker] XPC check-in: service '%s' not found, creating\n", service_name);
        kern_return_t kr = mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &service_port);
        if (kr == KERN_SUCCESS) {
            mach_port_insert_right(mach_task_self(), service_port, service_port, MACH_MSG_TYPE_MAKE_SEND);
            register_service(service_name, service_port);
            handle_xpc_checkin(request, service_name, service_port, handle);
            for (int i = 0; i < MAX_SERVICES; i++) {
                if (g_services[i].active && strcmp(g_services[i].name, service_name) == 0) {
                    g_services[i].receive_moved = 1;
                    break;
                }
            }
            return;
        }
        /* Port alloc failed — send XPC error reply */
        send_xpc_pipe_reply(request->msgh_remote_port, request->msgh_id, routine, 12 /* ENOMEM */);
        return;
    }

    /* Routine 100 = GetJobs (LAUNCH_ROUTINE_GETJOBS).
     * assertiond calls this early to get its job dictionary with MachServices.
     * Without proper response, assertiond logs "Error getting job dictionaries.
     * Error: Input/output error (5)". */
    if (routine == 100) {
        broker_log("[broker] XPC pipe: routine=100 (GetJobs), sending jobs reply\n");
        send_xpc_pipe_getjobs_reply(request->msgh_remote_port, request->msgh_id, handle);
        return;
    }

    /* Other non-check-in XPC launchd routines — generic XPC success reply.
     * CRITICAL: never use send_error_reply (MIG format) here. */
    broker_log("[broker] XPC pipe: non-checkin routine=%llu handle=%llu, sending XPC success reply\n",
               routine, handle);

    /* Hex dump raw Mach message for unknown routines */
    {
        uint8_t *rraw = (uint8_t *)request;
        uint32_t dump_len = total < 256 ? total : 256;
        broker_log("[broker] XPC pipe routine=%llu raw msg (%u bytes):\n", routine, total);
        for (uint32_t d = 0; d < dump_len; d++) {
            if (d % 16 == 0) broker_log("[broker]   %04x: ", d);
            broker_log("%02x ", rraw[d]);
            if (d % 16 == 15 || d == dump_len - 1) broker_log("\n");
        }
    }

    send_xpc_pipe_reply(request->msgh_remote_port, request->msgh_id, routine, 0);
}

/* Message dispatch loop */
static void message_loop(void) {
    uint8_t recv_buffer[BROKER_RECV_BUF_SIZE];
    mach_msg_header_t *request = (mach_msg_header_t *)recv_buffer;

    broker_log("[broker] entering message loop\n");

    while (!g_shutdown) {
        memset(recv_buffer, 0, sizeof(recv_buffer));

        kern_return_t kr = mach_msg(request, MACH_RCV_MSG | MACH_RCV_LARGE,
                                     0, sizeof(recv_buffer), g_port_set,
                                     MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL);

        if (kr != KERN_SUCCESS) {
            if (kr == MACH_RCV_INTERRUPTED) {
                broker_log("[broker] mach_msg interrupted\n");
                continue;
            }
            if (kr == MACH_RCV_TOO_LARGE) {
                broker_log("[broker] mach_msg too large: needed=%u buffer=%u\n",
                           request->msgh_size, (unsigned)sizeof(recv_buffer));
                continue;
            }
            broker_log("[broker] mach_msg failed: 0x%x\n", kr);
            break;
        }

        broker_log("[broker] received message: id=%d size=%d local=0x%x\n",
                   request->msgh_id, request->msgh_size, request->msgh_local_port);

        /* Check if message arrived on the rendezvous port (XPC pipe protocol).
         * Route ALL rendezvous messages to handle_xpc_launch_msg which sends
         * proper XPC-formatted replies. NEVER send MIG replies on this port. */
        if (request->msgh_local_port == g_rendezvous_port) {
            handle_xpc_launch_msg(request);
            continue;
        }
        /* PurpleFBServer protocol messages (QuartzCore PurpleDisplay) */
        if (g_pfb_broker_enabled && request->msgh_local_port == g_pfb_port) {
            pfb_handle_message(request);
            continue;
        }

        /* Dispatch bootstrap message */
        switch (request->msgh_id) {
            case BOOTSTRAP_CHECK_IN:
                handle_check_in(request);
                break;

            case BOOTSTRAP_REGISTER:
                handle_register(request);
                break;

            case BOOTSTRAP_LOOK_UP:
                handle_look_up(request);
                break;

            case BOOTSTRAP_PARENT:
                handle_parent(request);
                break;

            case BOOTSTRAP_SUBSET:
                handle_subset(request);
                break;

            case BROKER_REGISTER_PORT:
            case BROKER_LOOKUP_PORT:
            case BROKER_SPAWN_APP:
                handle_broker_message(request);
                break;
            case XPC_LAUNCH_MSG_ID:
                handle_xpc_launch_msg(request);
                break;

            case XPC_LISTENER_REG_ID: {
                /* Listener registration handshake from _xpc_connection_check_in.
                 * Contract: 52-byte complex message with 2 port descriptors.
                 *   desc[0]: service recv port (MAKE_SEND disposition)
                 *   desc[1]: extra port (COPY_SEND disposition)
                 * No reply needed — registration is fire-and-forget. */
                int valid = 1;
                if (request->msgh_size != 52) {
                    broker_log("[broker] listener-reg: WARN size=%u (expected 52)\n", request->msgh_size);
                    valid = 0;
                }
                if (!(request->msgh_bits & MACH_MSGH_BITS_COMPLEX)) {
                    broker_log("[broker] listener-reg: WARN not complex\n");
                    valid = 0;
                }
                if (valid) {
                    mach_msg_body_t *body = (mach_msg_body_t *)((uint8_t *)request + sizeof(mach_msg_header_t));
                    if (body->msgh_descriptor_count != 2) {
                        broker_log("[broker] listener-reg: WARN desc_count=%u (expected 2)\n",
                                   body->msgh_descriptor_count);
                        valid = 0;
                    } else {
                        mach_msg_port_descriptor_t *d0 = (mach_msg_port_descriptor_t *)(body + 1);
                        mach_msg_port_descriptor_t *d1 = d0 + 1;
                        broker_log("[broker] listener-reg: OK desc0=0x%x(disp=%u) desc1=0x%x(disp=%u)\n",
                                   d0->name, d0->disposition, d1->name, d1->disposition);
                    }
                }
                if (!valid) {
                    broker_log("[broker] listener-reg: accepted with warnings (size=%u)\n", request->msgh_size);
                }
                /* No reply — registration is acknowledged by consuming the message */
                break;
            }

            default:
                broker_log("[broker] unknown msg: id=%d (0x%x) size=%u complex=%d local=0x%x\n",
                           request->msgh_id, request->msgh_id, request->msgh_size,
                           (request->msgh_bits & MACH_MSGH_BITS_COMPLEX) != 0,
                           request->msgh_local_port);
                /* Check if this looks structurally like a listener-reg (complex, ~52 bytes, 2 descs) */
                if ((request->msgh_bits & MACH_MSGH_BITS_COMPLEX) && request->msgh_size >= 48 && request->msgh_size <= 64) {
                    mach_msg_body_t *ub = (mach_msg_body_t *)((uint8_t *)request + sizeof(mach_msg_header_t));
                    broker_log("[broker] unknown msg: possible listener-reg alias (desc_count=%u)\n",
                               ub->msgh_descriptor_count);
                }
                if (request->msgh_remote_port != MACH_PORT_NULL) {
                    send_error_reply(request->msgh_remote_port, request->msgh_id + MIG_REPLY_OFFSET, MIG_BAD_ID);
                }
                break;
        }
    }

    broker_log("[broker] exiting message loop\n");
}

/* Project root — derived from the broker binary path (fallback: cwd). */
static char g_project_root[1024] = "";

/* Sim home directory — created under project root */
static char g_sim_home[1024] = "";

static void path_pop_dir(char *path) {
    if (!path || !path[0]) return;
    char *slash = strrchr(path, '/');
    if (!slash) return;
    if (slash == path) {
        /* Preserve "/" */
        path[1] = '\0';
        return;
    }
    *slash = '\0';
}

static void init_project_root(const char *argv0) {
    if (g_project_root[0]) return;

    char resolved[2048];
    resolved[0] = '\0';

    if (argv0 && argv0[0] && realpath(argv0, resolved)) {
        /* /.../rosetta/src/bridge/rosettasim_broker -> /.../rosetta */
        path_pop_dir(resolved); /* bridge */
        path_pop_dir(resolved); /* src */
        path_pop_dir(resolved); /* project root */
        snprintf(g_project_root, sizeof(g_project_root), "%s", resolved);
        broker_log("[broker] project_root: %s\n", g_project_root);
        return;
    }

    /* Fallback: cwd */
    char cwd[1024];
    if (getcwd(cwd, sizeof(cwd))) {
        snprintf(g_project_root, sizeof(g_project_root), "%s", cwd);
        broker_log("[broker] project_root (fallback=cwd): %s\n", g_project_root);
    }
}

static void resolve_project_path(const char *in, char *out, size_t out_sz) {
    if (!out || out_sz == 0) return;
    out[0] = '\0';
    if (!in || !in[0]) return;

    if (in[0] == '/') {
        snprintf(out, out_sz, "%s", in);
        return;
    }
    if (g_project_root[0]) {
        snprintf(out, out_sz, "%s/%s", g_project_root, in);
        return;
    }
    snprintf(out, out_sz, "%s", in);
}

static void ensure_sim_home(void) {
    if (g_sim_home[0]) return;

    const char *root = NULL;
    char cwd[1024];
    if (g_project_root[0]) {
        root = g_project_root;
    } else if (getcwd(cwd, sizeof(cwd))) {
        root = cwd;
    } else {
        root = "/tmp";
    }

    snprintf(g_sim_home, sizeof(g_sim_home), "%s/.sim_home", root);

    /* Create sim_home directory structure */
    char path[1280];
    const char *subdirs[] = {
        "/Library/Preferences", "/Library/Caches", "/Library/Logs",
        "/Library/SpringBoard", "/Documents", "/Media", "/tmp", NULL
    };
    for (int i = 0; subdirs[i]; i++) {
        snprintf(path, sizeof(path), "%s%s", g_sim_home, subdirs[i]);
        /* Create parent dirs too (mkdir -p equivalent for 2 levels) */
        char parent[1280];
        snprintf(parent, sizeof(parent), "%s/Library", g_sim_home);
        mkdir(parent, 0755);
        mkdir(path, 0755);
    }
    broker_log("[broker] sim_home: %s\n", g_sim_home);
}

static void trim_newline(char *s) {
    if (!s) return;
    s[strcspn(s, "\r\n")] = 0;
}

/* Normalize ProductVersion (e.g. "10.3.1") to major.minor ("10.3"). */
static void normalize_major_minor(const char *in, char *out, size_t out_sz) {
    if (!out || out_sz == 0) return;
    out[0] = '\0';
    if (!in || !in[0]) return;

    snprintf(out, out_sz, "%s", in);

    int dots = 0;
    for (size_t i = 0; out[i]; i++) {
        if (out[i] == '.') {
            dots++;
            if (dots >= 2) {
                out[i] = '\0';
                break;
            }
        }
    }
}

static int plutil_extract_raw(const char *plist_path, const char *key,
                              char *out, size_t out_sz) {
    if (!out || out_sz == 0) return -1;
    out[0] = '\0';
    if (!plist_path || !plist_path[0] || !key || !key[0]) return -1;

    char cmd[2048];
    snprintf(cmd, sizeof(cmd),
             "plutil -extract %s raw -o - '%s' 2>/dev/null",
             key, plist_path);
    FILE *fp = popen(cmd, "r");
    if (!fp) return -1;

    if (!fgets(out, (int)out_sz, fp)) {
        pclose(fp);
        out[0] = '\0';
        return -1;
    }
    trim_newline(out);
    pclose(fp);
    return out[0] ? 0 : -1;
}

static void detect_simulator_runtime(const char *sdk_path) {
    /* Allow manual override for quick experiments. */
    const char *ov_ver = getenv("ROSETTASIM_RUNTIME_VERSION");
    const char *ov_bld = getenv("ROSETTASIM_RUNTIME_BUILD_VERSION");
    if (ov_ver && ov_ver[0]) {
        normalize_major_minor(ov_ver, g_sim_runtime_version, sizeof(g_sim_runtime_version));
    }
    if (ov_bld && ov_bld[0]) {
        snprintf(g_sim_runtime_build_version, sizeof(g_sim_runtime_build_version), "%s", ov_bld);
    }

    char sysver_plist[2048];
    snprintf(sysver_plist, sizeof(sysver_plist),
             "%s/System/Library/CoreServices/SystemVersion.plist", sdk_path);

    if (access(sysver_plist, R_OK) != 0) {
        broker_log("[broker] runtime detect: SystemVersion.plist not readable: %s\n", sysver_plist);
        broker_log("[broker] runtime: version=%s build=%s\n",
                   g_sim_runtime_version, g_sim_runtime_build_version);
        return;
    }

    if (!(ov_ver && ov_ver[0])) {
        char pv[64] = "";
        if (plutil_extract_raw(sysver_plist, "ProductVersion", pv, sizeof(pv)) == 0) {
            normalize_major_minor(pv, g_sim_runtime_version, sizeof(g_sim_runtime_version));
        }
    }
    if (!(ov_bld && ov_bld[0])) {
        char pbv[64] = "";
        if (plutil_extract_raw(sysver_plist, "ProductBuildVersion", pbv, sizeof(pbv)) == 0) {
            snprintf(g_sim_runtime_build_version, sizeof(g_sim_runtime_build_version), "%s", pbv);
        }
    }

    broker_log("[broker] runtime: version=%s build=%s (from %s)\n",
               g_sim_runtime_version, g_sim_runtime_build_version, sysver_plist);
}

/* ================================================================
 * Broker-hosted PurpleFBServer implementation
 * ================================================================ */

extern kern_return_t mach_make_memory_entry_64(
    vm_map_t target_task,
    memory_object_size_t *size,
    memory_object_offset_t offset,
    vm_prot_t permission,
    mach_port_t *object_handle,
    mem_entry_name_port_t parent_entry
);

static kern_return_t pfb_create_surface(void) {
    if (g_pfb_surface_addr != 0 && g_pfb_memory_entry != MACH_PORT_NULL) {
        return KERN_SUCCESS;
    }

    kern_return_t kr = vm_allocate(mach_task_self(), &g_pfb_surface_addr,
                                   PFB_SURFACE_ALLOC, VM_FLAGS_ANYWHERE);
    if (kr != KERN_SUCCESS) {
        broker_log("[broker][pfb] vm_allocate failed: 0x%x\n", kr);
        return kr;
    }

    /* Clear to black (BGRA) with opaque alpha */
    memset((void *)g_pfb_surface_addr, 0, PFB_SURFACE_ALLOC);
    uint8_t *pixels = (uint8_t *)g_pfb_surface_addr;
    for (uint32_t i = 0; i < PFB_PIXEL_WIDTH * PFB_PIXEL_HEIGHT; i++) {
        pixels[i * 4 + 3] = 0xFF;
    }

    memory_object_size_t entry_size = PFB_SURFACE_ALLOC;
    kr = mach_make_memory_entry_64(
        mach_task_self(),
        &entry_size,
        (memory_object_offset_t)g_pfb_surface_addr,
        VM_PROT_READ | VM_PROT_WRITE,
        &g_pfb_memory_entry,
        MACH_PORT_NULL
    );
    if (kr != KERN_SUCCESS) {
        broker_log("[broker][pfb] mach_make_memory_entry_64 failed: 0x%x\n", kr);
        vm_deallocate(mach_task_self(), g_pfb_surface_addr, PFB_SURFACE_ALLOC);
        g_pfb_surface_addr = 0;
        g_pfb_memory_entry = MACH_PORT_NULL;
        return kr;
    }

    broker_log("[broker][pfb] surface: %ux%u px (%u bytes/row), mem_entry=0x%x\n",
               PFB_PIXEL_WIDTH, PFB_PIXEL_HEIGHT, PFB_BYTES_PER_ROW, g_pfb_memory_entry);
    return KERN_SUCCESS;
}

static void pfb_setup_shared_framebuffer(void) {
    if (g_pfb_shared_fb != MAP_FAILED) return;

    uint32_t total_size = ROSETTASIM_FB_TOTAL_SIZE(PFB_PIXEL_WIDTH, PFB_PIXEL_HEIGHT);
    g_pfb_shared_fd = open(ROSETTASIM_FB_GPU_PATH, O_RDWR | O_CREAT | O_TRUNC, 0666);
    if (g_pfb_shared_fd < 0) {
        broker_log("[broker][pfb] WARNING: open(%s) failed: %s\n",
                   ROSETTASIM_FB_GPU_PATH, strerror(errno));
        return;
    }
    if (ftruncate(g_pfb_shared_fd, (off_t)total_size) < 0) {
        broker_log("[broker][pfb] WARNING: ftruncate failed: %s\n", strerror(errno));
        close(g_pfb_shared_fd);
        g_pfb_shared_fd = -1;
        return;
    }
    g_pfb_shared_fb = mmap(NULL, total_size, PROT_READ | PROT_WRITE, MAP_SHARED, g_pfb_shared_fd, 0);
    if (g_pfb_shared_fb == MAP_FAILED) {
        broker_log("[broker][pfb] WARNING: mmap failed: %s\n", strerror(errno));
        close(g_pfb_shared_fd);
        g_pfb_shared_fd = -1;
        return;
    }

    RosettaSimFramebufferHeader *hdr = (RosettaSimFramebufferHeader *)g_pfb_shared_fb;
    hdr->magic = ROSETTASIM_FB_MAGIC;
    hdr->version = ROSETTASIM_FB_VERSION;
    hdr->width = PFB_PIXEL_WIDTH;
    hdr->height = PFB_PIXEL_HEIGHT;
    hdr->stride = PFB_BYTES_PER_ROW;
    hdr->format = ROSETTASIM_FB_FORMAT_BGRA;
    hdr->frame_counter = 0;
    hdr->timestamp_ns = 0;
    hdr->flags = ROSETTASIM_FB_FLAG_APP_RUNNING;
    hdr->fps_target = 60;

    broker_log("[broker][pfb] shared fb: %s (%u bytes)\n", ROSETTASIM_FB_GPU_PATH, total_size);
}

static void pfb_sync_to_shared(void) {
    if (g_pfb_shared_fb == MAP_FAILED || g_pfb_surface_addr == 0) return;

    uint8_t *pixel_dest = (uint8_t *)g_pfb_shared_fb + ROSETTASIM_FB_META_SIZE;
    memcpy(pixel_dest, (void *)g_pfb_surface_addr, PFB_SURFACE_SIZE);

    RosettaSimFramebufferHeader *hdr = (RosettaSimFramebufferHeader *)g_pfb_shared_fb;
    hdr->frame_counter++;
    hdr->flags |= ROSETTASIM_FB_FLAG_FRAME_READY;
}

static void *pfb_sync_thread_main(void *arg) {
    (void)arg;
    broker_log("[broker][pfb] sync thread started\n");
    while (g_pfb_sync_running) {
        pfb_sync_to_shared();
        usleep(16666); /* ~60Hz */
    }
    broker_log("[broker][pfb] sync thread exiting\n");
    return NULL;
}

static void pfb_handle_message(mach_msg_header_t *request) {
    PurpleFBRequest *req = (PurpleFBRequest *)request;
    mach_port_t reply_port = req->header.msgh_remote_port;

    /* Limit log spam */
    static int msg_log_count = 0;
    if (msg_log_count < 50) {
        broker_log("[broker][pfb] msg id=%u size=%u reply=0x%x\n",
                   req->header.msgh_id, req->header.msgh_size, reply_port);
        msg_log_count++;
    }

    if (req->header.msgh_id == 4 && reply_port != MACH_PORT_NULL) {
        /* map_surface request */
        PurpleFBReply reply;
        memset(&reply, 0, sizeof(reply));

        reply.header.msgh_bits = MACH_MSGH_BITS_COMPLEX |
                                 MACH_MSGH_BITS(MACH_MSG_TYPE_MOVE_SEND_ONCE, 0);
        reply.header.msgh_size = sizeof(PurpleFBReply);
        reply.header.msgh_remote_port = reply_port;
        reply.header.msgh_local_port = MACH_PORT_NULL;
        reply.header.msgh_id = 4;

        reply.body.msgh_descriptor_count = 1;
        reply.port_desc.name = g_pfb_memory_entry;
        reply.port_desc.pad1 = 0;
        reply.port_desc.pad2 = 0;
        reply.port_desc.disposition = MACH_MSG_TYPE_COPY_SEND;
        reply.port_desc.type = MACH_MSG_PORT_DESCRIPTOR;

        reply.memory_size = PFB_SURFACE_ALLOC;
        reply.stride = PFB_BYTES_PER_ROW;
        reply.unknown1 = 0;
        reply.unknown2 = 0;
        reply.pixel_width = PFB_PIXEL_WIDTH;
        reply.pixel_height = PFB_PIXEL_HEIGHT;
        reply.point_width = PFB_POINT_WIDTH;
        reply.point_height = PFB_POINT_HEIGHT;

        kern_return_t kr = mach_msg(&reply.header, MACH_SEND_MSG, sizeof(reply),
                                    0, MACH_PORT_NULL, MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL);
        if (kr != KERN_SUCCESS) {
            broker_log("[broker][pfb] map_surface reply failed: 0x%x\n", kr);
        }
        return;
    }

    if (reply_port != MACH_PORT_NULL) {
        /* Protocol expects 72-byte replies; send a simple empty reply. */
        uint8_t reply_buf[72];
        memset(reply_buf, 0, sizeof(reply_buf));
        mach_msg_header_t *hdr = (mach_msg_header_t *)reply_buf;
        hdr->msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_MOVE_SEND_ONCE, 0);
        hdr->msgh_size = 72;
        hdr->msgh_remote_port = reply_port;
        hdr->msgh_local_port = MACH_PORT_NULL;
        hdr->msgh_id = req->header.msgh_id;
        mach_msg(hdr, MACH_SEND_MSG, 72, 0, MACH_PORT_NULL, MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL);
    }
}

static int pfb_broker_init(void) {
    if (!g_pfb_broker_enabled) return 0;
    if (g_pfb_port != MACH_PORT_NULL) return 0;

    kern_return_t kr = pfb_create_surface();
    if (kr != KERN_SUCCESS) return -1;
    pfb_setup_shared_framebuffer();

    kr = mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &g_pfb_port);
    if (kr != KERN_SUCCESS) {
        broker_log("[broker][pfb] mach_port_allocate failed: 0x%x\n", kr);
        return -1;
    }
    kr = mach_port_insert_right(mach_task_self(), g_pfb_port, g_pfb_port, MACH_MSG_TYPE_MAKE_SEND);
    if (kr != KERN_SUCCESS) {
        broker_log("[broker][pfb] mach_port_insert_right failed: 0x%x\n", kr);
        return -1;
    }

    /* Register both names — QuartzCore probes TVOut too. */
    register_service(PFB_SERVICE_NAME, g_pfb_port);
    register_service(PFB_TVOUT_SERVICE_NAME, g_pfb_port);

    /* Start sync thread for the shared framebuffer */
    g_pfb_sync_running = 1;
    if (pthread_create(&g_pfb_sync_thread, NULL, pfb_sync_thread_main, NULL) == 0) {
        pthread_detach(g_pfb_sync_thread);
    } else {
        broker_log("[broker][pfb] WARNING: failed to start sync thread\n");
    }

    broker_log("[broker][pfb] enabled on port 0x%x\n", g_pfb_port);
    return 0;
}
/* Spawn backboardd with broker port */
static int spawn_backboardd(const char *sdk_path, const char *shim_path) {
    broker_log("[broker] spawning backboardd\n");
    broker_log("[broker] sdk: %s\n", sdk_path);
    broker_log("[broker] shim: %s\n", shim_path);

    ensure_sim_home();

    /* Build backboardd path */
    char backboardd_path[1024];
    snprintf(backboardd_path, sizeof(backboardd_path), "%s/usr/libexec/backboardd", sdk_path);

    /* Check if backboardd exists */
    if (access(backboardd_path, X_OK) != 0) {
        broker_log("[broker] backboardd not found or not executable: %s\n", backboardd_path);
        return -1;
    }

    /* Build environment — must match run_backboardd.sh exactly */
    char env_dyld_root[1024], env_dyld_insert[2048];
    char env_iphone_sim_root[1024], env_sim_root[1024];
    char env_home[1024], env_cffixed_home[1024], env_tmpdir[1024];
    char env_hid_manager[1280];
    const char *root = g_project_root[0] ? g_project_root : NULL;
    char cwd[1024];
    if (!root) {
        if (getcwd(cwd, sizeof(cwd))) root = cwd;
        else root = "/tmp";
    }
    getcwd(cwd, sizeof(cwd));

    snprintf(env_dyld_root, sizeof(env_dyld_root), "DYLD_ROOT_PATH=%s", sdk_path);
    /* bootstrap_fix.dylib MUST be first — it interposes bootstrap_check_in/look_up
     * so that the iOS SDK sends MIG messages to our broker port. */
    char bfix_path[1280];
    snprintf(bfix_path, sizeof(bfix_path), "%s/src/bridge/bootstrap_fix.dylib", root);
    if (!g_pfb_broker_enabled && shim_path && shim_path[0]) {
        char shim_abs[1280];
        resolve_project_path(shim_path, shim_abs, sizeof(shim_abs));
        snprintf(env_dyld_insert, sizeof(env_dyld_insert),
                 "DYLD_INSERT_LIBRARIES=%s:%s", bfix_path, shim_abs);
    } else {
        snprintf(env_dyld_insert, sizeof(env_dyld_insert),
                 "DYLD_INSERT_LIBRARIES=%s", bfix_path);
    }
    snprintf(env_iphone_sim_root, sizeof(env_iphone_sim_root), "IPHONE_SIMULATOR_ROOT=%s", sdk_path);
    snprintf(env_sim_root, sizeof(env_sim_root), "SIMULATOR_ROOT=%s", sdk_path);
    snprintf(env_home, sizeof(env_home), "HOME=%s", g_sim_home);
    snprintf(env_cffixed_home, sizeof(env_cffixed_home), "CFFIXED_USER_HOME=%s", g_sim_home);
    snprintf(env_tmpdir, sizeof(env_tmpdir), "TMPDIR=%s/tmp", g_sim_home);
    char env_runtime_version[128], env_runtime_build[128];
    snprintf(env_runtime_version, sizeof(env_runtime_version),
             "SIMULATOR_RUNTIME_VERSION=%s", g_sim_runtime_version);
    snprintf(env_runtime_build, sizeof(env_runtime_build),
             "SIMULATOR_RUNTIME_BUILD_VERSION=%s", g_sim_runtime_build_version);

    /* HID System Manager bundle path — resolve relative to project root */
    snprintf(env_hid_manager, sizeof(env_hid_manager),
             "SIMULATOR_HID_SYSTEM_MANAGER=%s/src/bridge/RosettaSimHIDManager.bundle", root);

    char *env[] = {
        env_dyld_root,
        "DYLD_SHARED_REGION=avoid",
        env_dyld_insert,
        env_iphone_sim_root,
        env_sim_root,
        env_home,
        env_cffixed_home,
        env_tmpdir,
        "XPC_SIMULATOR_LAUNCHD_NAME=com.apple.xpc.sim.launchd.rendezvous",
        "SIMULATOR_DEVICE_NAME=iPhone 6s",
        "SIMULATOR_MODEL_IDENTIFIER=iPhone8,1",
        env_runtime_version,
        env_runtime_build,
        "SIMULATOR_MAINSCREEN_WIDTH=750",
        "SIMULATOR_MAINSCREEN_HEIGHT=1334",
        "SIMULATOR_MAINSCREEN_SCALE=2.0",
        env_hid_manager,
        NULL
    };

    /* Setup spawn attributes */
    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);

    /* Set broker port as bootstrap port */
    kern_return_t kr = posix_spawnattr_setspecialport_np(&attr, g_broker_port, TASK_BOOTSTRAP_PORT);
    if (kr != KERN_SUCCESS) {
        broker_log("[broker] failed to set bootstrap port: 0x%x\n", kr);
        posix_spawnattr_destroy(&attr);
        return -1;
    }

    /* Spawn backboardd */
    char *argv[] = { backboardd_path, NULL };
    pid_t pid;

    int result = posix_spawn(&pid, backboardd_path, NULL, &attr, argv, env);
    posix_spawnattr_destroy(&attr);

    if (result != 0) {
        broker_log("[broker] posix_spawn failed: %s\n", strerror(result));
        return -1;
    }

    broker_log("[broker] backboardd spawned with pid %d\n", pid);
    g_backboardd_pid = pid;

    return 0;
}

/* Track child PIDs for cleanup */
static pid_t g_assertiond_pid = -1;
static pid_t g_springboard_pid = -1;

/* Generic function to spawn an iOS simulator daemon with broker port.
 * Uses DYLD_ROOT_PATH for framework resolution and springboard_shim.dylib
 * for bootstrap_look_up routing through the broker. */
static int spawn_sim_daemon(const char *binary_path, const char *sdk_path,
                             const char *label, pid_t *out_pid) {
    broker_log("[broker] spawning %s: %s\n", label, binary_path);

    if (access(binary_path, X_OK) != 0) {
        broker_log("[broker] %s not found: %s\n", label, binary_path);
        return -1;
    }

    ensure_sim_home();

    char env_dyld_root[1024], env_dyld_insert[2048];
    char env_iphone_sim_root[1024], env_sim_root[1024];
    char env_home[1024], env_cffixed_home[1024], env_tmpdir[1024];

    snprintf(env_dyld_root, sizeof(env_dyld_root), "DYLD_ROOT_PATH=%s", sdk_path);
    const char *root = g_project_root[0] ? g_project_root : NULL;
    char cwd[1024];
    if (!root) {
        if (getcwd(cwd, sizeof(cwd))) root = cwd;
        else root = "/tmp";
    }
    /* All daemons get both bootstrap_fix.dylib + springboard_shim.dylib */
    snprintf(env_dyld_insert, sizeof(env_dyld_insert),
             "DYLD_INSERT_LIBRARIES=%s/src/bridge/bootstrap_fix.dylib:%s/src/bridge/springboard_shim.dylib",
             root, root);
    snprintf(env_iphone_sim_root, sizeof(env_iphone_sim_root), "IPHONE_SIMULATOR_ROOT=%s", sdk_path);
    snprintf(env_sim_root, sizeof(env_sim_root), "SIMULATOR_ROOT=%s", sdk_path);
    snprintf(env_home, sizeof(env_home), "HOME=%s", g_sim_home);
    snprintf(env_cffixed_home, sizeof(env_cffixed_home), "CFFIXED_USER_HOME=%s", g_sim_home);
    snprintf(env_tmpdir, sizeof(env_tmpdir), "TMPDIR=%s/tmp", g_sim_home);
    char env_runtime_version[128], env_runtime_build[128];
    snprintf(env_runtime_version, sizeof(env_runtime_version),
             "SIMULATOR_RUNTIME_VERSION=%s", g_sim_runtime_version);
    snprintf(env_runtime_build, sizeof(env_runtime_build),
             "SIMULATOR_RUNTIME_BUILD_VERSION=%s", g_sim_runtime_build_version);

    char *env[] = {
        env_dyld_root,
        "DYLD_SHARED_REGION=avoid",
        env_dyld_insert,
        env_iphone_sim_root,
        env_sim_root,
        env_home,
        env_cffixed_home,
        env_tmpdir,
        "XPC_SIMULATOR_LAUNCHD_NAME=com.apple.xpc.sim.launchd.rendezvous",
        "SIMULATOR_DEVICE_NAME=iPhone 6s",
        "SIMULATOR_MODEL_IDENTIFIER=iPhone8,1",
        env_runtime_version,
        env_runtime_build,
        "SIMULATOR_MAINSCREEN_WIDTH=750",
        "SIMULATOR_MAINSCREEN_HEIGHT=1334",
        "SIMULATOR_MAINSCREEN_SCALE=2.0",
        NULL
    };

    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    posix_spawnattr_setspecialport_np(&attr, g_broker_port, TASK_BOOTSTRAP_PORT);

    char *bin_copy = strdup(binary_path);
    char *argv[] = { bin_copy, NULL };
    pid_t pid;
    int result = posix_spawn(&pid, binary_path, NULL, &attr, argv, env);
    posix_spawnattr_destroy(&attr);
    free(bin_copy);

    if (result != 0) {
        broker_log("[broker] %s spawn failed: %s\n", label, strerror(result));
        return -1;
    }

    broker_log("[broker] %s spawned with pid %d\n", label, pid);
    if (out_pid) *out_pid = pid;
    return 0;
}

/* Track iokitsimd PID */
static pid_t g_iokitsimd_pid = -1;

/* Spawn iokitsimd — the IOKit simulator daemon.
 * This is a NATIVE macOS x86_64 binary (NOT against iOS SDK) that provides
 * IOKit MIG services including IOConnectMapMemory for IOSurface sharing.
 * The wrapper script _iokitsimd unsets DYLD_ROOT_PATH before exec'ing. */
static int spawn_iokitsimd(const char *sdk_path) {
    /* The actual binary path within the SDK */
    char iokitsimd_path[1024];
    snprintf(iokitsimd_path, sizeof(iokitsimd_path), "%s/usr/sbin/iokitsimd", sdk_path);

    if (access(iokitsimd_path, X_OK) != 0) {
        broker_log("[broker] iokitsimd not found: %s\n", iokitsimd_path);
        return -1;
    }

    broker_log("[broker] spawning iokitsimd: %s\n", iokitsimd_path);

    /* iokitsimd is a macOS native binary — do NOT inject iOS-simulator dylibs. */
    char *env[] = {
        "HOME=/tmp",
        "TMPDIR=/tmp",
        NULL
    };

    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    posix_spawnattr_setspecialport_np(&attr, g_broker_port, TASK_BOOTSTRAP_PORT);

    char *argv[] = { iokitsimd_path, NULL };
    pid_t pid;
    int result = posix_spawn(&pid, iokitsimd_path, NULL, &attr, argv, env);
    posix_spawnattr_destroy(&attr);

    if (result != 0) {
        broker_log("[broker] iokitsimd spawn failed: %s\n", strerror(result));
        return -1;
    }

    broker_log("[broker] iokitsimd spawned with pid %d\n", pid);
    g_iokitsimd_pid = pid;
    return 0;
}

/* Spawn assertiond — process assertion daemon.
 * Must start BEFORE SpringBoard (SpringBoard's AssertionServices
 * framework connects to assertiond's XPC services during bootstrap). */
static int spawn_assertiond(const char *sdk_path) {
    char path[1024];
    snprintf(path, sizeof(path), "%s/usr/libexec/assertiond", sdk_path);
    return spawn_sim_daemon(path, sdk_path, "assertiond", &g_assertiond_pid);
}

/* Spawn SpringBoard — the system app.
 * Connects to backboardd (CARenderServer, display/HID) and assertiond
 * (process assertions). Manages app lifecycle and display assignment. */
static int spawn_springboard(const char *sdk_path) {
    char path[1024];
    snprintf(path, sizeof(path),
             "%s/System/Library/CoreServices/SpringBoard.app/SpringBoard", sdk_path);
    return spawn_sim_daemon(path, sdk_path, "SpringBoard", &g_springboard_pid);
}

/* Spawn an app process with broker port as bootstrap.
 * The app is injected with the bridge library (NOT the app_shim),
 * which handles UIKit lifecycle AND connects to CARenderServer via broker. */
static int spawn_app(const char *app_path, const char *sdk_path, const char *bridge_path) {
    broker_log("[broker] spawning app: %s\n", app_path);

    ensure_sim_home();

    /* Resolve .app bundle → executable */
    char exec_path[1024];
    char bundle_path[1024] = "";

    /* Check if app_path is a .app bundle directory */
    size_t pathlen = strlen(app_path);
    if (pathlen > 4 && strcmp(app_path + pathlen - 4, ".app") == 0) {
        /* It's a .app bundle — extract executable name from Info.plist */
        snprintf(bundle_path, sizeof(bundle_path), "%s", app_path);

        char plist_path[1280];
        snprintf(plist_path, sizeof(plist_path), "%s/Info.plist", app_path);

        /* Read CFBundleExecutable from Info.plist using plutil */
        char cmd[2048];
        snprintf(cmd, sizeof(cmd),
                 "plutil -p '%s' 2>/dev/null | grep CFBundleExecutable | head -1 | "
                 "sed 's/.*=> \"\\(.*\\)\"/\\1/'", plist_path);
        FILE *fp = popen(cmd, "r");
        char exec_name[256] = "";
        if (fp) {
            if (fgets(exec_name, sizeof(exec_name), fp)) {
                /* Trim newline */
                exec_name[strcspn(exec_name, "\n")] = 0;
            }
            pclose(fp);
        }

        if (exec_name[0] == '\0') {
            /* Fallback: basename of .app without extension */
            const char *base = strrchr(app_path, '/');
            base = base ? base + 1 : app_path;
            strncpy(exec_name, base, sizeof(exec_name) - 5);
            char *dot = strrchr(exec_name, '.');
            if (dot) *dot = '\0';
        }

        snprintf(exec_path, sizeof(exec_path), "%s/%s", app_path, exec_name);
        broker_log("[broker] app bundle: %s\n", bundle_path);
        broker_log("[broker] executable: %s\n", exec_path);
    } else {
        snprintf(exec_path, sizeof(exec_path), "%s", app_path);
        /* Check if executable is inside a .app */
        const char *parent = strrchr(app_path, '/');
        if (parent) {
            size_t dir_len = parent - app_path;
            if (dir_len > 4 && strncmp(app_path + dir_len - 4, ".app", 4) == 0) {
                snprintf(bundle_path, sizeof(bundle_path), "%.*s", (int)dir_len, app_path);
            }
        }
    }

    if (access(exec_path, X_OK) != 0) {
        broker_log("[broker] app executable not found: %s\n", exec_path);
        return -1;
    }

    /* Build environment — matches run_sim.sh */
    char env_dyld_root[1024], env_dyld_insert[2048];
    char env_iphone_sim_root[1024], env_sim_root[1024];
    char env_home[1024], env_cffixed_home[1024], env_tmpdir[1024];
    char env_bundle_exec[256] = "", env_bundle_path[1280] = "", env_proc_path[1280] = "";
    char env_ca_mode[64] = "";
    char env_runtime_version[128] = "", env_runtime_build[128] = "";

    snprintf(env_dyld_root, sizeof(env_dyld_root), "DYLD_ROOT_PATH=%s", sdk_path);
    if (bridge_path && bridge_path[0]) {
        /* bootstrap_fix.dylib first, then bridge */
        const char *root = g_project_root[0] ? g_project_root : NULL;
        char cwd_app[1024];
        if (!root) {
            if (getcwd(cwd_app, sizeof(cwd_app))) root = cwd_app;
            else root = "/tmp";
        }
        char bridge_abs[1280];
        resolve_project_path(bridge_path, bridge_abs, sizeof(bridge_abs));
        snprintf(env_dyld_insert, sizeof(env_dyld_insert),
                 "DYLD_INSERT_LIBRARIES=%s/src/bridge/bootstrap_fix.dylib:%s",
                 root, bridge_abs);
    } else {
        env_dyld_insert[0] = '\0';
    }
    snprintf(env_iphone_sim_root, sizeof(env_iphone_sim_root), "IPHONE_SIMULATOR_ROOT=%s", sdk_path);
    snprintf(env_sim_root, sizeof(env_sim_root), "SIMULATOR_ROOT=%s", sdk_path);
    snprintf(env_home, sizeof(env_home), "HOME=%s", g_sim_home);
    snprintf(env_cffixed_home, sizeof(env_cffixed_home), "CFFIXED_USER_HOME=%s", g_sim_home);
    snprintf(env_tmpdir, sizeof(env_tmpdir), "TMPDIR=%s/tmp", g_sim_home);

    /* App bundle variables */
    if (bundle_path[0]) {
        const char *exec_name = strrchr(exec_path, '/');
        exec_name = exec_name ? exec_name + 1 : exec_path;
        snprintf(env_bundle_exec, sizeof(env_bundle_exec), "CFBundleExecutable=%s", exec_name);
        snprintf(env_bundle_path, sizeof(env_bundle_path), "NSBundlePath=%s", bundle_path);
        snprintf(env_proc_path, sizeof(env_proc_path), "CFProcessPath=%s", exec_path);
    }

    /* Pass through ROSETTASIM_CA_MODE from parent environment */
    const char *ca_mode = getenv("ROSETTASIM_CA_MODE");
    if (ca_mode) {
        snprintf(env_ca_mode, sizeof(env_ca_mode), "ROSETTASIM_CA_MODE=%s", ca_mode);
    }

    /* Pass through ROSETTASIM_DNS_MAP for hostname resolution */
    char env_dns_map[1024] = "";
    const char *dns_map = getenv("ROSETTASIM_DNS_MAP");
    if (dns_map) {
        snprintf(env_dns_map, sizeof(env_dns_map), "ROSETTASIM_DNS_MAP=%s", dns_map);
    }

    char *env[32];
    int ei = 0;
    env[ei++] = env_dyld_root;
    env[ei++] = "DYLD_SHARED_REGION=avoid";
    if (env_dyld_insert[0]) env[ei++] = env_dyld_insert;
    env[ei++] = env_iphone_sim_root;
    env[ei++] = env_sim_root;
    env[ei++] = env_home;
    env[ei++] = env_cffixed_home;
    env[ei++] = env_tmpdir;
    env[ei++] = "XPC_SIMULATOR_LAUNCHD_NAME=com.apple.xpc.sim.launchd.rendezvous";
    env[ei++] = "SIMULATOR_DEVICE_NAME=iPhone 6s";
    env[ei++] = "SIMULATOR_MODEL_IDENTIFIER=iPhone8,1";
    env[ei++] = env_runtime_version;
    env[ei++] = env_runtime_build;
    env[ei++] = "SIMULATOR_MAINSCREEN_WIDTH=750";
    env[ei++] = "SIMULATOR_MAINSCREEN_HEIGHT=1334";
    env[ei++] = "SIMULATOR_MAINSCREEN_SCALE=2.0";
    env[ei++] = "SIMULATOR_LEGACY_ASSET_SUFFIX=";
    env[ei++] = "__CTFontManagerDisableAutoActivation=1";
    /* CA debug flags (can add CA_ALWAYS_RENDER=1, CA_PRINT_TREE=1, etc.) */
    /* Use separate framebuffer path for the app to avoid conflict with
     * PurpleFBServer's 60Hz sync in backboardd */
    env[ei++] = "ROSETTASIM_FB_PATH=/tmp/rosettasim_app_framebuffer";
    /* Enable XPC send_sync timeout for app only — prevents MobileGestalt block
     * in [UIApplication init]. Daemons handle the block on background threads. */
    env[ei++] = "ROSETTASIM_XPC_TIMEOUT=1";
    if (env_bundle_exec[0]) env[ei++] = env_bundle_exec;
    if (env_bundle_path[0]) env[ei++] = env_bundle_path;
    if (env_proc_path[0]) env[ei++] = env_proc_path;
    if (env_ca_mode[0]) env[ei++] = env_ca_mode;
    if (env_dns_map[0]) env[ei++] = env_dns_map;
    env[ei] = NULL;

    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    posix_spawnattr_setspecialport_np(&attr, g_broker_port, TASK_BOOTSTRAP_PORT);

    char *argv[] = { exec_path, NULL };
    pid_t pid;
    int result = posix_spawn(&pid, exec_path, NULL, &attr, argv, env);
    posix_spawnattr_destroy(&attr);

    if (result != 0) {
        broker_log("[broker] app spawn failed: %s\n", strerror(result));
        return -1;
    }

    broker_log("[broker] app spawned with pid %d\n", pid);
    return pid;
}

/* Write PID file */
static void write_pid_file(void) {
    int fd = open("/tmp/rosettasim_broker.pid", O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) {
        broker_log("[broker] failed to create pid file: %s\n", strerror(errno));
        return;
    }

    char buf[32];
    int len = snprintf(buf, sizeof(buf), "%d\n", getpid());
    write(fd, buf, len);
    close(fd);
}

/* Main */
int main(int argc, char *argv[]) {
    const char *sdk_path = "/Applications/Xcode-8.3.3.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator10.3.sdk";
    const char *shim_path = "src/bridge/purple_fb_server.dylib";
    const char *bridge_path = "src/bridge/rosettasim_bridge.dylib";
    const char *app_path = NULL;

    /* Parse command line */
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--sdk") == 0 && i + 1 < argc) {
            sdk_path = argv[++i];
        } else if (strcmp(argv[i], "--shim") == 0 && i + 1 < argc) {
            shim_path = argv[++i];
        } else if (strcmp(argv[i], "--bridge") == 0 && i + 1 < argc) {
            bridge_path = argv[++i];
        } else if (strcmp(argv[i], "--app") == 0 && i + 1 < argc) {
            app_path = argv[++i];
        }
    }

    broker_log("[broker] RosettaSim broker starting\n");
    init_project_root(argv[0]);
    detect_simulator_runtime(sdk_path);
    if (atoi(g_sim_runtime_version) < 10) {
        g_pfb_broker_enabled = 1;
        broker_log("[broker] PurpleFBServer: broker-hosted mode ENABLED for runtime %s\n",
                   g_sim_runtime_version);
    }

    /* Initialize service registry */
    memset(g_services, 0, sizeof(g_services));

    /* Setup signal handlers */
    signal(SIGCHLD, sigchld_handler);
    signal(SIGTERM, sigterm_handler);
    signal(SIGINT, sigterm_handler);

    /* Create broker port */
    kern_return_t kr = mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &g_broker_port);
    if (kr != KERN_SUCCESS) {
        broker_log("[broker] failed to allocate broker port: 0x%x\n", kr);
        return 1;
    }

    /* Insert send right */
    kr = mach_port_insert_right(mach_task_self(), g_broker_port, g_broker_port, MACH_MSG_TYPE_MAKE_SEND);
    if (kr != KERN_SUCCESS) {
        broker_log("[broker] failed to insert send right: 0x%x\n", kr);
        return 1;
    }

    broker_log("[broker] broker port created: 0x%x\n", g_broker_port);

    /* Write PID file */
    write_pid_file();

    /* Pre-create MachServices from daemon plists.
     * These must exist BEFORE daemons spawn so their XPC listeners
     * can bootstrap_check_in and get receive rights.
     * Without pre-creation, check_in happens on-demand but the daemon's
     * XPC listener may fail if the port doesn't exist yet. */
    {
        const char *precreate_services[] = {
            /* NOTE: com.apple.xpc.sim.launchd.rendezvous is NOT pre-created here.
             * It's handled specially — the broker keeps the receive right and
             * listens on it for launch_msg check-in requests. See below. */
            /* assertiond */
            "com.apple.assertiond.applicationstateconnection",
            "com.apple.assertiond.appwatchdog",
            "com.apple.assertiond.expiration",
            "com.apple.assertiond.processassertionconnection",
            "com.apple.assertiond.processinfoservice",
            /* SpringBoard's frontboard workspace */
            "com.apple.frontboard.systemappservices",
            "com.apple.frontboard.workspace",
            NULL
        };
        for (int i = 0; precreate_services[i]; i++) {
            mach_port_t svc_port = MACH_PORT_NULL;
            kern_return_t kr2 = mach_port_allocate(mach_task_self(),
                                                    MACH_PORT_RIGHT_RECEIVE, &svc_port);
            if (kr2 == KERN_SUCCESS) {
                mach_port_insert_right(mach_task_self(), svc_port, svc_port,
                                        MACH_MSG_TYPE_MAKE_SEND);
                register_service(precreate_services[i], svc_port);
                broker_log("[broker] pre-created service: %s (port 0x%x)\n",
                           precreate_services[i], svc_port);
            }
        }
    }

    /* Create the XPC simulator launchd rendezvous port.
     * This is the port that libxpc's _launch_msg2 connects to when
     * XPC_SIMULATOR_LAUNCHD_NAME is set. The broker KEEPS the receive right
     * and adds it to the port set for message handling. */
    {
        kr = mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &g_rendezvous_port);
        if (kr == KERN_SUCCESS) {
            mach_port_insert_right(mach_task_self(), g_rendezvous_port, g_rendezvous_port, MACH_MSG_TYPE_MAKE_SEND);
            register_service("com.apple.xpc.sim.launchd.rendezvous", g_rendezvous_port);
            broker_log("[broker] rendezvous port created: 0x%x\n", g_rendezvous_port);
        }
    }

    /* Create a port set containing both the broker port and the rendezvous port.
     * This lets us receive messages from both in a single mach_msg loop. */
    {
        kr = mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_PORT_SET, &g_port_set);
        if (kr == KERN_SUCCESS) {
            mach_port_move_member(mach_task_self(), g_broker_port, g_port_set);
            if (g_rendezvous_port != MACH_PORT_NULL) {
                mach_port_move_member(mach_task_self(), g_rendezvous_port, g_port_set);
            }
            broker_log("[broker] port set created: 0x%x (broker + rendezvous)\n", g_port_set);
        } else {
            /* Fallback: use broker port directly */
            g_port_set = g_broker_port;
            broker_log("[broker] WARNING: port set allocation failed, using broker port directly\n");
        }
    }

    /* If enabled, host PurpleFBServer inside the broker and listen on its port too. */
    if (g_pfb_broker_enabled) {
        if (pfb_broker_init() != 0) {
            broker_log("[broker] WARNING: PurpleFBServer broker-hosted init failed\n");
        } else if (g_pfb_port != MACH_PORT_NULL) {
            if (g_port_set != g_broker_port) {
                mach_port_move_member(mach_task_self(), g_pfb_port, g_port_set);
                broker_log("[broker] added PurpleFBServer port to port set: 0x%x\n", g_pfb_port);
            } else {
                broker_log("[broker] WARNING: no port set available; cannot receive PurpleFBServer messages\n");
            }
        }
    }

    /* Spawn iokitsimd — IOKit simulator daemon.
     * Must start BEFORE backboardd (backboardd uses IOKit for display/HID). */
    if (spawn_iokitsimd(sdk_path) != 0) {
        broker_log("[broker] WARNING: iokitsimd failed to spawn (IOKit stubs unavailable)\n");
    } else {
        /* Brief pause for iokitsimd to register its MachService */
        usleep(200000); /* 200ms */
    }

    /* Spawn backboardd */
    if (spawn_backboardd(sdk_path, shim_path) != 0) {
        broker_log("[broker] failed to spawn backboardd\n");
        return 1;
    }

    /* If app specified, spawn it after backboardd registers CARenderServer.
     * We run a brief message loop first to let backboardd init, then spawn the app,
     * then continue the main message loop. */
    if (app_path) {
        broker_log("[broker] waiting for CARenderServer before spawning app...\n");
        /* Process messages until CARenderServer is registered or timeout */
        uint8_t tmp_buf[BROKER_RECV_BUF_SIZE];
        mach_msg_header_t *tmp_req = (mach_msg_header_t *)tmp_buf;
        int ca_found = 0;
        for (int attempt = 0; attempt < 50 && !ca_found; attempt++) {
            memset(tmp_buf, 0, sizeof(tmp_buf));
            kern_return_t msg_kr = mach_msg(tmp_req, MACH_RCV_MSG | MACH_RCV_TIMEOUT,
                                             0, sizeof(tmp_buf), g_port_set,
                                             500, MACH_PORT_NULL);
            if (msg_kr == MACH_RCV_TIMED_OUT) continue;
            if (msg_kr == MACH_RCV_TOO_LARGE) {
                broker_log("[broker] pre-app loop: message too large (needed=%u)\n",
                           tmp_req->msgh_size);
                continue;
            }
            if (msg_kr != KERN_SUCCESS) break;

            broker_log("[broker] received message: id=%d size=%d\n", tmp_req->msgh_id, tmp_req->msgh_size);

            /* Route XPC pipe messages before bootstrap dispatch */
            if (tmp_req->msgh_local_port == g_rendezvous_port ||
                tmp_req->msgh_id == XPC_LAUNCH_MSG_ID) {
                handle_xpc_launch_msg(tmp_req);
                goto ca_check;
            }
            if (tmp_req->msgh_id == XPC_LISTENER_REG_ID) {
                broker_log("[broker] pre-app: listener-reg consumed\n");
                goto ca_check;
            }
            if (g_pfb_broker_enabled && tmp_req->msgh_local_port == g_pfb_port) {
                pfb_handle_message(tmp_req);
                goto ca_check;
            }

            /* Dispatch the message */
            switch (tmp_req->msgh_id) {
                case BOOTSTRAP_CHECK_IN: handle_check_in(tmp_req); break;
                case BOOTSTRAP_REGISTER: handle_register(tmp_req); break;
                case BOOTSTRAP_LOOK_UP: handle_look_up(tmp_req); break;
                case BOOTSTRAP_PARENT: handle_parent(tmp_req); break;
                case BOOTSTRAP_SUBSET: handle_subset(tmp_req); break;
                case BROKER_REGISTER_PORT:
                case BROKER_LOOKUP_PORT:
                case BROKER_SPAWN_APP:
                    handle_broker_message(tmp_req); break;
                default:
                    if (tmp_req->msgh_remote_port != MACH_PORT_NULL)
                        send_error_reply(tmp_req->msgh_remote_port, tmp_req->msgh_id + MIG_REPLY_OFFSET, MIG_BAD_ID);
                    break;
            }

            ca_check: ;
            /* Check if CARenderServer AND all critical services are registered.
             * display.services is required by the app's BKSDisplayServicesStart(). */
            int has_ca = 0, has_event = 0, has_workspace = 0, has_display = 0;
            for (int i = 0; i < MAX_SERVICES; i++) {
                if (!g_services[i].active) continue;
                if (strstr(g_services[i].name, "CARenderServer")) has_ca = 1;
                if (strstr(g_services[i].name, "PurpleSystemEventPort")) has_event = 1;
                if (strstr(g_services[i].name, "PurpleWorkspacePort")) has_workspace = 1;
                if (strstr(g_services[i].name, "display.services")) has_display = 1;
            }
            if (has_ca && has_event && has_workspace && has_display) {
                ca_found = 1;
            }
        }

        if (ca_found) {
            broker_log("[broker] backboardd services ready (CARenderServer + Purple ports)\n");
        } else {
            broker_log("[broker] WARNING: backboardd services not all registered after timeout\n");
        }

        /* Phase 2: Spawn assertiond (process assertion daemon).
         * Must start BEFORE SpringBoard — SpringBoard's AssertionServices
         * framework connects to assertiond's XPC services during bootstrap. */
        broker_log("[broker] spawning assertiond...\n");
        if (spawn_assertiond(sdk_path) != 0) {
            broker_log("[broker] WARNING: failed to spawn assertiond\n");
        } else {
            /* Give assertiond a moment to register its XPC services */
            broker_log("[broker] waiting for assertiond to initialize...\n");
            for (int attempt = 0; attempt < 10; attempt++) {
                memset(tmp_buf, 0, sizeof(tmp_buf));
                kern_return_t msg_kr = mach_msg(tmp_req, MACH_RCV_MSG | MACH_RCV_TIMEOUT,
                                                 0, sizeof(tmp_buf), g_port_set,
                                                 500, MACH_PORT_NULL);
                if (msg_kr == MACH_RCV_TIMED_OUT) continue;
                if (msg_kr == MACH_RCV_TOO_LARGE) {
                    broker_log("[broker] assertiond wait: message too large (needed=%u)\n",
                               tmp_req->msgh_size);
                    continue;
                }
                if (msg_kr != KERN_SUCCESS) break;
                broker_log("[broker] received message: id=%d size=%d\n", tmp_req->msgh_id, tmp_req->msgh_size);

                /* Route XPC pipe messages */
                if (tmp_req->msgh_local_port == g_rendezvous_port ||
                    tmp_req->msgh_id == XPC_LAUNCH_MSG_ID) {
                    handle_xpc_launch_msg(tmp_req);
                    goto assertiond_svc_check;
                }
                if (tmp_req->msgh_id == XPC_LISTENER_REG_ID) {
                    broker_log("[broker] assertiond-wait: listener-reg consumed\n");
                    goto assertiond_svc_check;
                }
                if (g_pfb_broker_enabled && tmp_req->msgh_local_port == g_pfb_port) {
                    pfb_handle_message(tmp_req);
                    goto assertiond_svc_check;
                }

                switch (tmp_req->msgh_id) {
                    case BOOTSTRAP_CHECK_IN: handle_check_in(tmp_req); break;
                    case BOOTSTRAP_REGISTER: handle_register(tmp_req); break;
                    case BOOTSTRAP_LOOK_UP: handle_look_up(tmp_req); break;
                    case BOOTSTRAP_PARENT: handle_parent(tmp_req); break;
                    case BOOTSTRAP_SUBSET: handle_subset(tmp_req); break;
                    case BROKER_REGISTER_PORT:
                    case BROKER_LOOKUP_PORT:
                    case BROKER_SPAWN_APP:
                        handle_broker_message(tmp_req); break;
                    default:
                        if (tmp_req->msgh_remote_port != MACH_PORT_NULL)
                            send_error_reply(tmp_req->msgh_remote_port, tmp_req->msgh_id + MIG_REPLY_OFFSET, MIG_BAD_ID);
                        break;
                }
                assertiond_svc_check:
                /* Check if assertiond registered any services */
                for (int i = 0; i < MAX_SERVICES; i++) {
                    if (g_services[i].active && strstr(g_services[i].name, "assertiond")) {
                        broker_log("[broker] assertiond service registered: %s\n", g_services[i].name);
                        goto assertiond_ready;
                    }
                }
            }
            assertiond_ready:
            broker_log("[broker] assertiond init phase complete\n");
        }

        /* Phase 3: Spawn SpringBoard. */
        broker_log("[broker] spawning SpringBoard...\n");
        if (spawn_springboard(sdk_path) != 0) {
            broker_log("[broker] WARNING: failed to spawn SpringBoard, spawning app directly\n");
            unlink("/tmp/rosettasim_context_id");
            spawn_app(app_path, sdk_path, bridge_path);
        } else {
            /* Wait for SpringBoard to register its services before spawning app.
             * Key service: com.apple.frontboard.workspace (FBSWorkspace) */
            broker_log("[broker] waiting for SpringBoard services...\n");
            int sb_ready = 0;
            for (int attempt = 0; attempt < 40 && !sb_ready; attempt++) {
                memset(tmp_buf, 0, sizeof(tmp_buf));
                kern_return_t msg_kr = mach_msg(tmp_req, MACH_RCV_MSG | MACH_RCV_TIMEOUT,
                                                 0, sizeof(tmp_buf), g_port_set,
                                                 500, MACH_PORT_NULL);
                if (msg_kr == MACH_RCV_TIMED_OUT) continue;
                if (msg_kr == MACH_RCV_TOO_LARGE) {
                    broker_log("[broker] springboard wait: message too large (needed=%u)\n",
                               tmp_req->msgh_size);
                    continue;
                }
                if (msg_kr != KERN_SUCCESS) break;

                broker_log("[broker] received message: id=%d size=%d\n", tmp_req->msgh_id, tmp_req->msgh_size);

                /* Route XPC pipe messages */
                if (tmp_req->msgh_local_port == g_rendezvous_port ||
                    tmp_req->msgh_id == XPC_LAUNCH_MSG_ID) {
                    handle_xpc_launch_msg(tmp_req);
                    goto sb_svc_check;
                }
                if (tmp_req->msgh_id == XPC_LISTENER_REG_ID) {
                    broker_log("[broker] sb-wait: listener-reg consumed\n");
                    goto sb_svc_check;
                }
                if (g_pfb_broker_enabled && tmp_req->msgh_local_port == g_pfb_port) {
                    pfb_handle_message(tmp_req);
                    goto sb_svc_check;
                }

                switch (tmp_req->msgh_id) {
                    case BOOTSTRAP_CHECK_IN: handle_check_in(tmp_req); break;
                    case BOOTSTRAP_REGISTER: handle_register(tmp_req); break;
                    case BOOTSTRAP_LOOK_UP: handle_look_up(tmp_req); break;
                    case BOOTSTRAP_PARENT: handle_parent(tmp_req); break;
                    case BOOTSTRAP_SUBSET: handle_subset(tmp_req); break;
                    case BROKER_REGISTER_PORT:
                    case BROKER_LOOKUP_PORT:
                    case BROKER_SPAWN_APP:
                        handle_broker_message(tmp_req); break;
                    default:
                        if (tmp_req->msgh_remote_port != MACH_PORT_NULL)
                            send_error_reply(tmp_req->msgh_remote_port, tmp_req->msgh_id + MIG_REPLY_OFFSET, MIG_BAD_ID);
                        break;
                }

                sb_svc_check:
                /* Check if SpringBoard registered its key services */
                for (int i = 0; i < MAX_SERVICES; i++) {
                    if (g_services[i].active &&
                        (strstr(g_services[i].name, "PurpleSystemAppPort") ||
                         strstr(g_services[i].name, "frontboard.workspace"))) {
                        sb_ready = 1;
                        broker_log("[broker] SpringBoard service registered: %s\n", g_services[i].name);
                        break;
                    }
                }
            }

            if (sb_ready) {
                broker_log("[broker] SpringBoard ready, spawning app\n");
            } else {
                broker_log("[broker] WARNING: SpringBoard services not registered after timeout, spawning app anyway\n");
            }

            /* Phase 3: Spawn the app.
             * Delete stale context ID file BEFORE spawning — the app will write
             * its UIKit _layerContext.contextId after window creation. */
            unlink("/tmp/rosettasim_context_id");
            spawn_app(app_path, sdk_path, bridge_path);
        }
    }

    /* Run message loop */
    message_loop();

    /* Cleanup */
    broker_log("[broker] cleaning up\n");

    if (g_springboard_pid > 0) {
        broker_log("[broker] killing SpringBoard (pid %d)\n", g_springboard_pid);
        kill(g_springboard_pid, SIGTERM);
        waitpid(g_springboard_pid, NULL, WNOHANG);
    }

    if (g_assertiond_pid > 0) {
        broker_log("[broker] killing assertiond (pid %d)\n", g_assertiond_pid);
        kill(g_assertiond_pid, SIGTERM);
        waitpid(g_assertiond_pid, NULL, WNOHANG);
    }

    if (g_backboardd_pid > 0) {
        broker_log("[broker] killing backboardd (pid %d)\n", g_backboardd_pid);
        kill(g_backboardd_pid, SIGTERM);
        waitpid(g_backboardd_pid, NULL, 0);
    }

    if (g_iokitsimd_pid > 0) {
        broker_log("[broker] killing iokitsimd (pid %d)\n", g_iokitsimd_pid);
        kill(g_iokitsimd_pid, SIGTERM);
        waitpid(g_iokitsimd_pid, NULL, WNOHANG);
    }

    if (g_broker_port != MACH_PORT_NULL) {
        mach_port_deallocate(mach_task_self(), g_broker_port);
    }

    unlink("/tmp/rosettasim_broker.pid");

    broker_log("[broker] shutdown complete\n");

    return 0;
}
