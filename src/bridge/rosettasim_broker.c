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

/* MIG Message IDs (from bootstrap.defs subsystem 400) */
#define BOOTSTRAP_CHECK_IN      402
#define BOOTSTRAP_REGISTER      403
#define BOOTSTRAP_LOOK_UP       404
#define BOOTSTRAP_PARENT        406
#define BOOTSTRAP_SUBSET        409

#define BROKER_REGISTER_PORT    700
#define BROKER_LOOKUP_PORT      701
#define BROKER_SPAWN_APP        702

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

/* Service registry entry */
typedef struct {
    char name[MAX_NAME_LEN];
    mach_port_t port;
    int active;
} service_entry_t;

/* Global state */
static service_entry_t g_services[MAX_SERVICES];
static mach_port_t g_broker_port = MACH_PORT_NULL;
static pid_t g_backboardd_pid = -1;
static volatile sig_atomic_t g_shutdown = 0;

/* Use system's NDR_record - already defined in mach/ndr.h */

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
            broker_log("[broker] child process (pid %d) terminated\n", pid);
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

    /* Extract service name (fixed 128-byte field, null-terminated) */
    memcpy(service_name, req->name, MAX_NAME_LEN);
    service_name[MAX_NAME_LEN - 1] = '\0';

    broker_log("[broker] check_in request: %s\n", service_name);

    /* Create receive port for service */
    mach_port_t service_port = MACH_PORT_NULL;
    kern_return_t kr = mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &service_port);

    if (kr != KERN_SUCCESS) {
        broker_log("[broker] failed to allocate port for check_in: 0x%x\n", kr);
        send_error_reply(request->msgh_remote_port, request->msgh_id + MIG_REPLY_OFFSET, BOOTSTRAP_NO_MEMORY);
        return;
    }

    /* Insert send right (broker keeps this for look_up responses) */
    kr = mach_port_insert_right(mach_task_self(), service_port, service_port, MACH_MSG_TYPE_MAKE_SEND);
    if (kr != KERN_SUCCESS) {
        broker_log("[broker] failed to insert send right: 0x%x\n", kr);
        mach_port_deallocate(mach_task_self(), service_port);
        send_error_reply(request->msgh_remote_port, request->msgh_id + MIG_REPLY_OFFSET, BOOTSTRAP_NO_MEMORY);
        return;
    }

    /* Register service (store send right for future look_ups) */
    int result = register_service(service_name, service_port);
    if (result != BOOTSTRAP_SUCCESS) {
        mach_port_deallocate(mach_task_self(), service_port);
        send_error_reply(request->msgh_remote_port, request->msgh_id + MIG_REPLY_OFFSET, result);
        return;
    }

    /* Send RECEIVE right to caller (MOVE_RECEIVE transfers ownership).
     * After this, broker has: send right. Caller has: receive right.
     * Clients doing look_up will get send rights to the same port. */
    send_port_reply(request->msgh_remote_port, request->msgh_id + MIG_REPLY_OFFSET,
                    service_port, MACH_MSG_TYPE_MOVE_RECEIVE);
    broker_log("[broker] check_in '%s': sent receive right 0x%x\n", service_name, service_port);
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

/* Message dispatch loop */
static void message_loop(void) {
    uint8_t recv_buffer[4096];
    mach_msg_header_t *request = (mach_msg_header_t *)recv_buffer;

    broker_log("[broker] entering message loop\n");

    while (!g_shutdown) {
        memset(recv_buffer, 0, sizeof(recv_buffer));

        kern_return_t kr = mach_msg(request, MACH_RCV_MSG | MACH_RCV_LARGE,
                                     0, sizeof(recv_buffer), g_broker_port,
                                     MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL);

        if (kr != KERN_SUCCESS) {
            if (kr == MACH_RCV_INTERRUPTED) {
                broker_log("[broker] mach_msg interrupted\n");
                continue;
            }
            broker_log("[broker] mach_msg failed: 0x%x\n", kr);
            break;
        }

        broker_log("[broker] received message: id=%d size=%d\n", request->msgh_id, request->msgh_size);

        /* Dispatch message */
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

            default:
                broker_log("[broker] unknown message id: %d\n", request->msgh_id);
                if (request->msgh_remote_port != MACH_PORT_NULL) {
                    send_error_reply(request->msgh_remote_port, request->msgh_id + MIG_REPLY_OFFSET, MIG_BAD_ID);
                }
                break;
        }
    }

    broker_log("[broker] exiting message loop\n");
}

/* Sim home directory — created under project root */
static char g_sim_home[1024] = "";

static void ensure_sim_home(void) {
    if (g_sim_home[0]) return;

    char cwd[1024];
    getcwd(cwd, sizeof(cwd));
    snprintf(g_sim_home, sizeof(g_sim_home), "%s/.sim_home", cwd);

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
    char env_dyld_root[1024], env_dyld_insert[1024];
    char env_iphone_sim_root[1024], env_sim_root[1024];
    char env_home[1024], env_cffixed_home[1024], env_tmpdir[1024];
    char env_hid_manager[1280];

    char cwd[1024];
    getcwd(cwd, sizeof(cwd));

    snprintf(env_dyld_root, sizeof(env_dyld_root), "DYLD_ROOT_PATH=%s", sdk_path);
    /* bootstrap_fix.dylib MUST be first — it interposes bootstrap_check_in/look_up
     * so that the iOS SDK sends MIG messages to our broker port. */
    char bfix_path[1280];
    snprintf(bfix_path, sizeof(bfix_path), "%s/src/bridge/bootstrap_fix.dylib", cwd);
    snprintf(env_dyld_insert, sizeof(env_dyld_insert), "DYLD_INSERT_LIBRARIES=%s:%s", bfix_path, shim_path);
    snprintf(env_iphone_sim_root, sizeof(env_iphone_sim_root), "IPHONE_SIMULATOR_ROOT=%s", sdk_path);
    snprintf(env_sim_root, sizeof(env_sim_root), "SIMULATOR_ROOT=%s", sdk_path);
    snprintf(env_home, sizeof(env_home), "HOME=%s", g_sim_home);
    snprintf(env_cffixed_home, sizeof(env_cffixed_home), "CFFIXED_USER_HOME=%s", g_sim_home);
    snprintf(env_tmpdir, sizeof(env_tmpdir), "TMPDIR=%s/tmp", g_sim_home);

    /* HID System Manager bundle path — resolve relative to cwd */
    snprintf(env_hid_manager, sizeof(env_hid_manager),
             "SIMULATOR_HID_SYSTEM_MANAGER=%s/src/bridge/RosettaSimHIDManager.bundle", cwd);

    char *env[] = {
        env_dyld_root,
        env_dyld_insert,
        env_iphone_sim_root,
        env_sim_root,
        env_home,
        env_cffixed_home,
        env_tmpdir,
        "SIMULATOR_DEVICE_NAME=iPhone 6s",
        "SIMULATOR_MODEL_IDENTIFIER=iPhone8,1",
        "SIMULATOR_RUNTIME_VERSION=10.3",
        "SIMULATOR_RUNTIME_BUILD_VERSION=14E8301",
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

    char env_dyld_root[1024], env_dyld_insert[1280];
    char env_iphone_sim_root[1024], env_sim_root[1024];
    char env_home[1024], env_cffixed_home[1024], env_tmpdir[1024];

    snprintf(env_dyld_root, sizeof(env_dyld_root), "DYLD_ROOT_PATH=%s", sdk_path);

    char cwd[1024];
    getcwd(cwd, sizeof(cwd));
    /* bootstrap_fix.dylib first, then springboard_shim */
    snprintf(env_dyld_insert, sizeof(env_dyld_insert),
             "DYLD_INSERT_LIBRARIES=%s/src/bridge/bootstrap_fix.dylib:%s/src/bridge/springboard_shim.dylib",
             cwd, cwd);
    snprintf(env_iphone_sim_root, sizeof(env_iphone_sim_root), "IPHONE_SIMULATOR_ROOT=%s", sdk_path);
    snprintf(env_sim_root, sizeof(env_sim_root), "SIMULATOR_ROOT=%s", sdk_path);
    snprintf(env_home, sizeof(env_home), "HOME=%s", g_sim_home);
    snprintf(env_cffixed_home, sizeof(env_cffixed_home), "CFFIXED_USER_HOME=%s", g_sim_home);
    snprintf(env_tmpdir, sizeof(env_tmpdir), "TMPDIR=%s/tmp", g_sim_home);

    char *env[] = {
        env_dyld_root,
        env_dyld_insert,
        env_iphone_sim_root,
        env_sim_root,
        env_home,
        env_cffixed_home,
        env_tmpdir,
        "SIMULATOR_DEVICE_NAME=iPhone 6s",
        "SIMULATOR_MODEL_IDENTIFIER=iPhone8,1",
        "SIMULATOR_RUNTIME_VERSION=10.3",
        "SIMULATOR_RUNTIME_BUILD_VERSION=14E8301",
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

    /* iokitsimd is a macOS native binary — do NOT set DYLD_ROOT_PATH.
     * Only set HOME and bootstrap_fix for bootstrap interception. */
    char cwd[1024];
    getcwd(cwd, sizeof(cwd));
    char env_bfix[1280];
    snprintf(env_bfix, sizeof(env_bfix),
             "DYLD_INSERT_LIBRARIES=%s/src/bridge/bootstrap_fix.dylib", cwd);

    /* iokitsimd uses launch_msg for check-in, which requires bootstrap port.
     * With bootstrap_fix, bootstrap operations go through our broker. */
    char *env[] = {
        env_bfix,
        "HOME=/tmp",
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

    char cwd_app[1024];
    getcwd(cwd_app, sizeof(cwd_app));
    snprintf(env_dyld_root, sizeof(env_dyld_root), "DYLD_ROOT_PATH=%s", sdk_path);
    if (bridge_path && bridge_path[0]) {
        /* bootstrap_fix.dylib first, then bridge */
        snprintf(env_dyld_insert, sizeof(env_dyld_insert),
                 "DYLD_INSERT_LIBRARIES=%s/src/bridge/bootstrap_fix.dylib:%s",
                 cwd_app, bridge_path);
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
    if (env_dyld_insert[0]) env[ei++] = env_dyld_insert;
    env[ei++] = env_iphone_sim_root;
    env[ei++] = env_sim_root;
    env[ei++] = env_home;
    env[ei++] = env_cffixed_home;
    env[ei++] = env_tmpdir;
    env[ei++] = "SIMULATOR_DEVICE_NAME=iPhone 6s";
    env[ei++] = "SIMULATOR_MODEL_IDENTIFIER=iPhone8,1";
    env[ei++] = "SIMULATOR_RUNTIME_VERSION=10.3";
    env[ei++] = "SIMULATOR_RUNTIME_BUILD_VERSION=14E8301";
    env[ei++] = "SIMULATOR_MAINSCREEN_WIDTH=750";
    env[ei++] = "SIMULATOR_MAINSCREEN_HEIGHT=1334";
    env[ei++] = "SIMULATOR_MAINSCREEN_SCALE=2.0";
    env[ei++] = "SIMULATOR_LEGACY_ASSET_SUFFIX=";
    env[ei++] = "__CTFontManagerDisableAutoActivation=1";
    /* CA debug flags (can add CA_ALWAYS_RENDER=1, CA_PRINT_TREE=1, etc.) */
    /* Use separate framebuffer path for the app to avoid conflict with
     * PurpleFBServer's 60Hz sync in backboardd */
    env[ei++] = "ROSETTASIM_FB_PATH=/tmp/rosettasim_app_framebuffer";
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
        uint8_t tmp_buf[4096];
        mach_msg_header_t *tmp_req = (mach_msg_header_t *)tmp_buf;
        int ca_found = 0;
        for (int attempt = 0; attempt < 50 && !ca_found; attempt++) {
            memset(tmp_buf, 0, sizeof(tmp_buf));
            kern_return_t msg_kr = mach_msg(tmp_req, MACH_RCV_MSG | MACH_RCV_TIMEOUT,
                                             0, sizeof(tmp_buf), g_broker_port,
                                             500, MACH_PORT_NULL);
            if (msg_kr == MACH_RCV_TIMED_OUT) continue;
            if (msg_kr != KERN_SUCCESS) break;

            broker_log("[broker] received message: id=%d size=%d\n", tmp_req->msgh_id, tmp_req->msgh_size);

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
         * framework connects to assertiond's XPC services during bootstrap.
         * Without assertiond, SpringBoard fails with "Bootstrap failed". */
        broker_log("[broker] spawning assertiond...\n");
        if (spawn_assertiond(sdk_path) != 0) {
            broker_log("[broker] WARNING: failed to spawn assertiond\n");
        } else {
            /* Give assertiond a moment to register its XPC services */
            broker_log("[broker] waiting for assertiond to initialize...\n");
            for (int attempt = 0; attempt < 10; attempt++) {
                memset(tmp_buf, 0, sizeof(tmp_buf));
                kern_return_t msg_kr = mach_msg(tmp_req, MACH_RCV_MSG | MACH_RCV_TIMEOUT,
                                                 0, sizeof(tmp_buf), g_broker_port,
                                                 500, MACH_PORT_NULL);
                if (msg_kr == MACH_RCV_TIMED_OUT) continue;
                if (msg_kr != KERN_SUCCESS) break;
                broker_log("[broker] received message: id=%d size=%d\n", tmp_req->msgh_id, tmp_req->msgh_size);
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

        /* Phase 3: Spawn SpringBoard.
         * SpringBoard connects to backboardd's services (CARenderServer,
         * PurpleSystemEventPort, etc.) and assertiond. It becomes the
         * system app and manages app lifecycle and display assignment. */
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
                                                 0, sizeof(tmp_buf), g_broker_port,
                                                 500, MACH_PORT_NULL);
                if (msg_kr == MACH_RCV_TIMED_OUT) continue;
                if (msg_kr != KERN_SUCCESS) break;

                broker_log("[broker] received message: id=%d size=%d\n", tmp_req->msgh_id, tmp_req->msgh_size);

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
