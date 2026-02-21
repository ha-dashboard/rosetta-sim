/*
 * rosettasim_broker.c
 *
 * Mach port broker for RosettaSim - enables cross-process Mach port sharing
 * between backboardd and iOS app processes.
 *
 * Compiled as x86_64 macOS binary (NOT against iOS SDK).
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

/* Message IDs */
#define BOOTSTRAP_CHECK_IN      400
#define BOOTSTRAP_REGISTER      401
#define BOOTSTRAP_LOOK_UP       402
#define BOOTSTRAP_PARENT        404
#define BOOTSTRAP_SUBSET        405

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

/* Maximum registry entries */
#define MAX_SERVICES    64
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

/* Message structures */
#pragma pack(4)
typedef struct {
    mach_msg_header_t head;
    NDR_record_t ndr;
    uint32_t name_len;
    char name[MAX_NAME_LEN];
} bootstrap_simple_request_t;

typedef struct {
    mach_msg_header_t head;
    mach_msg_body_t body;
    mach_msg_port_descriptor_t port_desc;
    NDR_record_t ndr;
    uint32_t name_len;
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

/* Send reply with port descriptor */
static kern_return_t send_port_reply(mach_port_t reply_port, uint32_t msg_id, mach_port_t port) {
    bootstrap_port_reply_t reply;
    memset(&reply, 0, sizeof(reply));

    reply.head.msgh_bits = MACH_MSGH_BITS_COMPLEX | MACH_MSGH_BITS(MACH_MSG_TYPE_MOVE_SEND_ONCE, 0);
    reply.head.msgh_size = sizeof(reply);
    reply.head.msgh_remote_port = reply_port;
    reply.head.msgh_local_port = MACH_PORT_NULL;
    reply.head.msgh_id = msg_id;

    reply.body.msgh_descriptor_count = 1;

    reply.port_desc.name = port;
    reply.port_desc.disposition = MACH_MSG_TYPE_COPY_SEND;
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

/* Handle bootstrap_check_in */
static void handle_check_in(mach_msg_header_t *request) {
    bootstrap_simple_request_t *req = (bootstrap_simple_request_t *)request;
    char service_name[MAX_NAME_LEN];

    /* Extract service name */
    uint32_t name_len = req->name_len;
    if (name_len >= MAX_NAME_LEN) {
        name_len = MAX_NAME_LEN - 1;
    }

    memcpy(service_name, req->name, name_len);
    service_name[name_len] = '\0';

    broker_log("[broker] check_in request: %s\n", service_name);

    /* Create receive port for service */
    mach_port_t service_port = MACH_PORT_NULL;
    kern_return_t kr = mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &service_port);

    if (kr != KERN_SUCCESS) {
        broker_log("[broker] failed to allocate port for check_in: 0x%x\n", kr);
        send_error_reply(request->msgh_remote_port, request->msgh_id + MIG_REPLY_OFFSET, BOOTSTRAP_NO_MEMORY);
        return;
    }

    /* Insert send right */
    kr = mach_port_insert_right(mach_task_self(), service_port, service_port, MACH_MSG_TYPE_MAKE_SEND);
    if (kr != KERN_SUCCESS) {
        broker_log("[broker] failed to insert send right: 0x%x\n", kr);
        mach_port_deallocate(mach_task_self(), service_port);
        send_error_reply(request->msgh_remote_port, request->msgh_id + MIG_REPLY_OFFSET, BOOTSTRAP_NO_MEMORY);
        return;
    }

    /* Register service */
    int result = register_service(service_name, service_port);
    if (result != BOOTSTRAP_SUCCESS) {
        mach_port_deallocate(mach_task_self(), service_port);
        send_error_reply(request->msgh_remote_port, request->msgh_id + MIG_REPLY_OFFSET, result);
        return;
    }

    /* Send port to client */
    send_port_reply(request->msgh_remote_port, request->msgh_id + MIG_REPLY_OFFSET, service_port);
}

/* Handle bootstrap_register */
static void handle_register(mach_msg_header_t *request) {
    bootstrap_complex_request_t *req = (bootstrap_complex_request_t *)request;
    char service_name[MAX_NAME_LEN];

    /* Extract service name */
    uint32_t name_len = req->name_len;
    if (name_len >= MAX_NAME_LEN) {
        name_len = MAX_NAME_LEN - 1;
    }

    memcpy(service_name, req->name, name_len);
    service_name[name_len] = '\0';

    mach_port_t service_port = req->port_desc.name;

    broker_log("[broker] register request: %s -> 0x%x\n", service_name, service_port);

    /* Register service */
    int result = register_service(service_name, service_port);

    /* Send reply */
    send_error_reply(request->msgh_remote_port, request->msgh_id + MIG_REPLY_OFFSET, result);
}

/* Handle bootstrap_look_up */
static void handle_look_up(mach_msg_header_t *request) {
    bootstrap_simple_request_t *req = (bootstrap_simple_request_t *)request;
    char service_name[MAX_NAME_LEN];

    /* Extract service name */
    uint32_t name_len = req->name_len;
    if (name_len >= MAX_NAME_LEN) {
        name_len = MAX_NAME_LEN - 1;
    }

    memcpy(service_name, req->name, name_len);
    service_name[name_len] = '\0';

    broker_log("[broker] look_up request: %s\n", service_name);

    /* Look up service */
    mach_port_t service_port = lookup_service(service_name);

    if (service_port == MACH_PORT_NULL) {
        send_error_reply(request->msgh_remote_port, request->msgh_id + MIG_REPLY_OFFSET, BOOTSTRAP_UNKNOWN_SERVICE);
    } else {
        send_port_reply(request->msgh_remote_port, request->msgh_id + MIG_REPLY_OFFSET, service_port);
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
            bootstrap_complex_request_t *req = (bootstrap_complex_request_t *)request;
            char service_name[MAX_NAME_LEN];

            uint32_t name_len = req->name_len;
            if (name_len >= MAX_NAME_LEN) {
                name_len = MAX_NAME_LEN - 1;
            }

            memcpy(service_name, req->name, name_len);
            service_name[name_len] = '\0';

            mach_port_t service_port = req->port_desc.name;

            broker_log("[broker] custom register_port: %s -> 0x%x\n", service_name, service_port);

            int result = register_service(service_name, service_port);
            send_error_reply(request->msgh_remote_port, request->msgh_id + MIG_REPLY_OFFSET, result);
            break;
        }

        case BROKER_LOOKUP_PORT: {
            bootstrap_simple_request_t *req = (bootstrap_simple_request_t *)request;
            char service_name[MAX_NAME_LEN];

            uint32_t name_len = req->name_len;
            if (name_len >= MAX_NAME_LEN) {
                name_len = MAX_NAME_LEN - 1;
            }

            memcpy(service_name, req->name, name_len);
            service_name[name_len] = '\0';

            broker_log("[broker] custom lookup_port: %s\n", service_name);

            mach_port_t service_port = lookup_service(service_name);

            if (service_port == MACH_PORT_NULL) {
                send_error_reply(request->msgh_remote_port, request->msgh_id + MIG_REPLY_OFFSET, BOOTSTRAP_UNKNOWN_SERVICE);
            } else {
                send_port_reply(request->msgh_remote_port, request->msgh_id + MIG_REPLY_OFFSET, service_port);
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

    snprintf(env_dyld_root, sizeof(env_dyld_root), "DYLD_ROOT_PATH=%s", sdk_path);
    snprintf(env_dyld_insert, sizeof(env_dyld_insert), "DYLD_INSERT_LIBRARIES=%s", shim_path);
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
    char env_dyld_root[1024], env_dyld_insert[1024];
    char env_iphone_sim_root[1024], env_sim_root[1024];
    char env_home[1024], env_cffixed_home[1024], env_tmpdir[1024];
    char env_bundle_exec[256] = "", env_bundle_path[1280] = "", env_proc_path[1280] = "";
    char env_ca_mode[64] = "";

    snprintf(env_dyld_root, sizeof(env_dyld_root), "DYLD_ROOT_PATH=%s", sdk_path);
    if (bridge_path && bridge_path[0]) {
        snprintf(env_dyld_insert, sizeof(env_dyld_insert), "DYLD_INSERT_LIBRARIES=%s", bridge_path);
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
    /* Use separate framebuffer path for the app to avoid conflict with
     * PurpleFBServer's 60Hz sync in backboardd */
    env[ei++] = "ROSETTASIM_FB_PATH=/tmp/rosettasim_app_framebuffer";
    if (env_bundle_exec[0]) env[ei++] = env_bundle_exec;
    if (env_bundle_path[0]) env[ei++] = env_bundle_path;
    if (env_proc_path[0]) env[ei++] = env_proc_path;
    if (env_ca_mode[0]) env[ei++] = env_ca_mode;
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

            /* Check if CARenderServer is now registered */
            for (int i = 0; i < MAX_SERVICES; i++) {
                if (g_services[i].active && strstr(g_services[i].name, "CARenderServer")) {
                    ca_found = 1;
                    break;
                }
            }
        }

        if (ca_found) {
            broker_log("[broker] CARenderServer registered, spawning app\n");
        } else {
            broker_log("[broker] WARNING: CARenderServer not registered after timeout, spawning app anyway\n");
        }

        /* Spawn the app with the bridge library injected.
         * The bridge handles UIKit lifecycle AND connects to CARenderServer
         * via the broker port (set as TASK_BOOTSTRAP_PORT). */
        spawn_app(app_path, sdk_path, bridge_path);
    }

    /* Run message loop */
    message_loop();

    /* Cleanup */
    broker_log("[broker] cleaning up\n");

    if (g_backboardd_pid > 0) {
        broker_log("[broker] killing backboardd (pid %d)\n", g_backboardd_pid);
        kill(g_backboardd_pid, SIGTERM);
        waitpid(g_backboardd_pid, NULL, 0);
    }

    if (g_broker_port != MACH_PORT_NULL) {
        mach_port_deallocate(mach_task_self(), g_broker_port);
    }

    unlink("/tmp/rosettasim_broker.pid");

    broker_log("[broker] shutdown complete\n");

    return 0;
}
