/*
 * launch_launchd_sim.c v6 — Threaded bootstrap proxy for launchd_sim
 *
 * Uses a dispatch queue to handle message forwarding without blocking
 * the main message receive loop.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <spawn.h>
#include <pthread.h>
#include <mach/mach.h>
#include <servers/bootstrap.h>
#include <sys/wait.h>

#define LOG(fmt, ...) fprintf(stderr, "[launcher] " fmt "\n", ##__VA_ARGS__)

static const char *SDK_PATH = "/Applications/Xcode-8.3.3.app/Contents/Developer/"
    "Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator.sdk";

static mach_port_t g_host_bootstrap;
static mach_port_t g_service_port;

static void hexdump(const void *data, int size) {
    const unsigned char *p = data;
    if (size > 128) size = 128;
    for (int j = 0; j < size; j += 16) {
        fprintf(stderr, "  %04x: ", j);
        for (int k = 0; k < 16 && (j+k) < size; k++) fprintf(stderr, "%02x ", p[j+k]);
        fprintf(stderr, "\n");
    }
}

static void reply_look_up(mach_msg_header_t *req) {
    const char *name = (const char *)req + 32;
    if (req->msgh_size < 48) return;
    LOG("look_up('%s')", name);

    mach_port_t sp = MACH_PORT_NULL;
    kern_return_t kr = bootstrap_look_up(g_host_bootstrap, name, &sp);

    if (kr == KERN_SUCCESS && sp != MACH_PORT_NULL) {
        LOG("  -> port 0x%x", sp);
        struct { mach_msg_header_t h; mach_msg_body_t b; mach_msg_port_descriptor_t p; } r;
        memset(&r, 0, sizeof(r));
        r.h.msgh_bits = MACH_MSGH_BITS_COMPLEX | MACH_MSGH_BITS(MACH_MSG_TYPE_MOVE_SEND_ONCE, 0);
        r.h.msgh_size = sizeof(r); r.h.msgh_remote_port = req->msgh_remote_port;
        r.h.msgh_id = req->msgh_id + 100;
        r.b.msgh_descriptor_count = 1;
        r.p.name = sp; r.p.disposition = MACH_MSG_TYPE_COPY_SEND; r.p.type = MACH_MSG_PORT_DESCRIPTOR;
        mach_msg(&r.h, MACH_SEND_MSG, sizeof(r), 0, MACH_PORT_NULL, 0, MACH_PORT_NULL);
    } else {
        LOG("  -> not found");
        struct { mach_msg_header_t h; uint32_t ndr[2]; int32_t ret; uint32_t port; } r;
        memset(&r, 0, sizeof(r));
        r.h.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_MOVE_SEND_ONCE, 0);
        r.h.msgh_size = sizeof(r); r.h.msgh_remote_port = req->msgh_remote_port;
        r.h.msgh_id = req->msgh_id + 100; r.ret = 1102;
        mach_msg(&r.h, MACH_SEND_MSG, sizeof(r), 0, MACH_PORT_NULL, 0, MACH_PORT_NULL);
    }
}

static void reply_checkin_5395(mach_msg_header_t *req) {
    LOG("MIG 0x1513 check-in -> service port 0x%x", g_service_port);
    struct { mach_msg_header_t h; mach_msg_body_t b; mach_msg_port_descriptor_t p; } r;
    memset(&r, 0, sizeof(r));
    r.h.msgh_bits = MACH_MSGH_BITS_COMPLEX | MACH_MSGH_BITS(MACH_MSG_TYPE_MOVE_SEND_ONCE, 0);
    r.h.msgh_size = sizeof(r); r.h.msgh_remote_port = req->msgh_remote_port;
    r.h.msgh_id = 0x328;
    r.b.msgh_descriptor_count = 1;
    r.p.name = g_service_port; r.p.disposition = MACH_MSG_TYPE_COPY_SEND; r.p.type = MACH_MSG_PORT_DESCRIPTOR;
    kern_return_t kr = mach_msg(&r.h, MACH_SEND_MSG, sizeof(r), 0, MACH_PORT_NULL, 0, MACH_PORT_NULL);
    LOG("  -> %s", kr == KERN_SUCCESS ? "OK" : mach_error_string(kr));
}

/* Thread function to forward a message to host bootstrap and relay reply */
struct forward_args {
    char buf[8192];
    mach_msg_size_t size;
    mach_port_t reply_port;
};

static void *forward_thread(void *arg) {
    struct forward_args *fa = arg;
    mach_msg_header_t *msg = (mach_msg_header_t *)fa->buf;

    LOG("  [fwd] Sending to host bootstrap (id=%d)", msg->msgh_id);

    /* Create a receive port for the reply */
    mach_port_t recv_port;
    mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &recv_port);

    msg->msgh_remote_port = g_host_bootstrap;
    msg->msgh_local_port = recv_port;
    msg->msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, MACH_MSG_TYPE_MAKE_SEND_ONCE);

    union { mach_msg_header_t h; char b[8192]; } reply_buf;

    kern_return_t kr = mach_msg(msg, MACH_SEND_MSG | MACH_RCV_MSG | MACH_RCV_TIMEOUT,
                                fa->size, sizeof(reply_buf), recv_port, 5000, MACH_PORT_NULL);
    if (kr != KERN_SUCCESS) {
        LOG("  [fwd] failed: %s", mach_error_string(kr));
        free(fa);
        return NULL;
    }

    LOG("  [fwd] Got reply id=%d, relaying to 0x%x", msg->msgh_id, fa->reply_port);

    /* Relay reply */
    mach_msg_header_t *rh = (mach_msg_header_t *)msg;
    rh->msgh_remote_port = fa->reply_port;
    rh->msgh_local_port = MACH_PORT_NULL;
    if (rh->msgh_bits & MACH_MSGH_BITS_COMPLEX)
        rh->msgh_bits = MACH_MSGH_BITS_COMPLEX | MACH_MSGH_BITS(MACH_MSG_TYPE_MOVE_SEND_ONCE, 0);
    else
        rh->msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_MOVE_SEND_ONCE, 0);
    mach_msg(rh, MACH_SEND_MSG, rh->msgh_size, 0, MACH_PORT_NULL, 0, MACH_PORT_NULL);

    mach_port_destroy(mach_task_self(), recv_port);
    free(fa);
    return NULL;
}

static void forward_async(mach_msg_header_t *msg, mach_msg_size_t size) {
    struct forward_args *fa = calloc(1, sizeof(*fa));
    memcpy(fa->buf, msg, size);
    fa->size = size;
    fa->reply_port = msg->msgh_remote_port;

    pthread_t t;
    pthread_create(&t, NULL, forward_thread, fa);
    pthread_detach(t);
}

int main(int argc, char *argv[])
{
    kern_return_t kr;
    LOG("Starting launcher v6 (threaded)");

    task_get_special_port(mach_task_self(), TASK_BOOTSTRAP_PORT, &g_host_bootstrap);

    mach_port_t proxy;
    mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &proxy);
    mach_port_insert_right(mach_task_self(), proxy, proxy, MACH_MSG_TYPE_MAKE_SEND);

    mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &g_service_port);
    mach_port_insert_right(mach_task_self(), g_service_port, g_service_port, MACH_MSG_TYPE_MAKE_SEND);
    LOG("proxy=0x%x service=0x%x host=0x%x", proxy, g_service_port, g_host_bootstrap);

    pid_t hold = fork();
    if (hold == 0) { sleep(30); _exit(0); }

    const char *name = "com.apple.CoreSimulator.SimDevice.rosettasim-test";
    char cmd[256]; snprintf(cmd, sizeof(cmd), "mkdir -p /private/tmp/%s", name); system(cmd);

    char e1[1024], e2[64], e3[256];
    snprintf(e1, sizeof(e1), "DYLD_ROOT_PATH=%s", SDK_PATH);
    snprintf(e2, sizeof(e2), "XPC_SIMULATOR_HOLDING_TANK_HACK=%d", hold);
    snprintf(e3, sizeof(e3), "XPC_SIMULATOR_LAUNCHD_NAME=%s", name);
    char *env[] = { e1, e2, e3,
        "HOME=/tmp/launchd_sim_test", "TMPDIR=/tmp/launchd_sim_test/tmp",
        "SIMULATOR_RUNTIME_VERSION=10.3.1", "SIMULATOR_RUNTIME_BUILD_VERSION=14E8301",
        NULL };

    char path[1024]; snprintf(path, sizeof(path), "%s/sbin/launchd_sim", SDK_PATH);
    char *av[] = { path, "/tmp/launchd_sim_config.plist", NULL };
    system("mkdir -p /tmp/launchd_sim_test/tmp");

    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    short flags = 0;
    posix_spawnattr_getflags(&attr, &flags);
    flags |= 0x0100; /* disable ASLR */
    posix_spawnattr_setflags(&attr, flags);
    posix_spawnattr_setspecialport_np(&attr, proxy, TASK_BOOTSTRAP_PORT);

    pid_t pid;
    int r = posix_spawn(&pid, path, NULL, &attr, av, env);
    posix_spawnattr_destroy(&attr);
    if (r) { LOG("spawn: %s", strerror(r)); return 1; }
    LOG("launchd_sim pid=%d", pid);

    int msg_count = 0;
    for (int i = 0; i < 120; i++) {
        union { mach_msg_header_t h; char b[8192]; } msg;
        memset(&msg, 0, sizeof(msg));
        msg.h.msgh_size = sizeof(msg);
        msg.h.msgh_local_port = proxy;

        kr = mach_msg(&msg.h, MACH_RCV_MSG | MACH_RCV_TIMEOUT,
                      0, sizeof(msg), proxy, 500, MACH_PORT_NULL);

        if (kr == MACH_RCV_TIMED_OUT) {
            int st; pid_t w = waitpid(pid, &st, WNOHANG);
            if (w == pid) {
                LOG("EXIT: sig=%d code=%d (%d msgs)",
                    WIFSIGNALED(st)?WTERMSIG(st):0, WIFEXITED(st)?WEXITSTATUS(st):-1, msg_count);
                goto done;
            }
            if (i % 10 == 9) LOG("Alive %ds (%d msgs)", (i+1)/2, msg_count);
            continue;
        }
        if (kr != KERN_SUCCESS) break;

        msg_count++;
        LOG("[%d] id=%d (0x%x) size=%d", msg_count, msg.h.msgh_id, msg.h.msgh_id, msg.h.msgh_size);

        switch (msg.h.msgh_id) {
        case 404: case 407: {
            const char *sname = (msg.h.msgh_size > 48) ? (const char*)&msg + 32 : "?";
            LOG("look_up('%s')", sname);
            /* For oahd specifically, try NOT forwarding */
            if (strncmp(sname, "com.apple.oahd", 14) == 0) {
                LOG("  -> NOT forwarding oahd (replying NOT_FOUND)");
                struct { mach_msg_header_t h; uint32_t ndr[2]; int32_t ret; uint32_t port; } r;
                memset(&r, 0, sizeof(r));
                r.h.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_MOVE_SEND_ONCE, 0);
                r.h.msgh_size = sizeof(r); r.h.msgh_remote_port = msg.h.msgh_remote_port;
                r.h.msgh_id = msg.h.msgh_id + 100; r.ret = 1102;
                mach_msg(&r.h, MACH_SEND_MSG, sizeof(r), 0, MACH_PORT_NULL, 0, MACH_PORT_NULL);
            } else {
                reply_look_up(&msg.h);
            }
            break;
        }
        case 5395: reply_checkin_5395(&msg.h); break;
        case 402: {
            const char *sn = (msg.h.msgh_size > 48) ? (const char*)&msg + 32 : "?";
            LOG("check_in('%s')", sn);
            mach_port_t sp; mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &sp);
            mach_port_insert_right(mach_task_self(), sp, sp, MACH_MSG_TYPE_MAKE_SEND);
            struct { mach_msg_header_t h; mach_msg_body_t b; mach_msg_port_descriptor_t p; } rp;
            memset(&rp, 0, sizeof(rp));
            rp.h.msgh_bits = MACH_MSGH_BITS_COMPLEX | MACH_MSGH_BITS(MACH_MSG_TYPE_MOVE_SEND_ONCE, 0);
            rp.h.msgh_size = sizeof(rp); rp.h.msgh_remote_port = msg.h.msgh_remote_port;
            rp.h.msgh_id = 502; rp.b.msgh_descriptor_count = 1;
            rp.p.name = sp; rp.p.disposition = MACH_MSG_TYPE_COPY_SEND; rp.p.type = MACH_MSG_PORT_DESCRIPTOR;
            mach_msg(&rp.h, MACH_SEND_MSG, sizeof(rp), 0, MACH_PORT_NULL, 0, MACH_PORT_NULL);
            break;
        }
        case 403: {
            const char *sn = (msg.h.msgh_size > 48) ? (const char*)&msg + 32 : "?";
            LOG("register('%s')", sn);
            struct { mach_msg_header_t h; uint32_t ndr[2]; int32_t ret; } rp;
            memset(&rp, 0, sizeof(rp)); rp.h.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_MOVE_SEND_ONCE, 0);
            rp.h.msgh_size = sizeof(rp); rp.h.msgh_remote_port = msg.h.msgh_remote_port; rp.h.msgh_id = 503;
            mach_msg(&rp.h, MACH_SEND_MSG, sizeof(rp), 0, MACH_PORT_NULL, 0, MACH_PORT_NULL);
            break;
        }
        default:
            LOG("Unknown id=%d, forwarding async", msg.h.msgh_id);
            forward_async(&msg.h, msg.h.msgh_size);
            break;
        }
    }

    LOG("Loop done, killing...");
    kill(pid, SIGTERM);
done:
    { int st; waitpid(pid, &st, 0); }
    kill(hold, SIGTERM); waitpid(hold, NULL, 0);
    LOG("Done");
    return 0;
}
