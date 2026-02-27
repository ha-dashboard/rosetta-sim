/*
 * hid_backport.m — Backport iOS 9.3-style IndigoHID loopback for iOS 12.4
 *
 * Uses DYLD __interpose to replace IndigoHIDSystemSpawnLoopback at load time
 * (before constructors), since the function is called during backboardd init.
 *
 * Build:
 *   clang -arch x86_64 -dynamiclib -framework Foundation \
 *     -mios-simulator-version-min=9.0 \
 *     -isysroot $(xcrun --show-sdk-path --sdk iphonesimulator) \
 *     -install_name /usr/lib/hid_backport.dylib \
 *     -Wl,-not_for_dyld_shared_cache -undefined dynamic_lookup \
 *     -o hid_backport.dylib hid_backport.m
 *
 * Deploy: insert_dylib into backboardd + codesign
 */

#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <mach/mach.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <fcntl.h>
#include <unistd.h>
#include <dispatch/dispatch.h>
#include <stdarg.h>

extern kern_return_t bootstrap_look_up(mach_port_t bp, const char *name, mach_port_t *sp);
extern mach_port_t bootstrap_port;

/* Declare the original function so the linker can resolve it for __interpose */
extern bool IndigoHIDSystemSpawnLoopback(void *hidSystem);

/* ================================================================
 * HID event receive handler
 * ================================================================ */

static mach_port_t g_hid_recv_port = MACH_PORT_NULL;
static dispatch_source_t g_hid_source = nil;

static void hid_receive_handler(void) {
    struct {
        mach_msg_header_t header;
        uint8_t payload[4096];
    } msg;
    memset(&msg, 0, sizeof(msg));

    kern_return_t kr = mach_msg(&msg.header, MACH_RCV_MSG | MACH_RCV_TIMEOUT,
                                0, sizeof(msg), g_hid_recv_port,
                                0, MACH_PORT_NULL);
    if (kr != KERN_SUCCESS) return;

    static int recv_count = 0;
    if (recv_count++ < 5) {
        NSLog(@"[HID-backport] Received HID msg: id=%d size=%d",
              msg.header.msgh_id, msg.header.msgh_size);
    }

    if (msg.header.msgh_remote_port != MACH_PORT_NULL) {
        mach_msg_header_t reply = {
            .msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_MOVE_SEND_ONCE, 0),
            .msgh_size = sizeof(reply),
            .msgh_remote_port = msg.header.msgh_remote_port,
            .msgh_local_port = MACH_PORT_NULL,
            .msgh_id = msg.header.msgh_id
        };
        mach_msg_send(&reply);
    }
}

/* ================================================================
 * Replacement IndigoHIDSystemSpawnLoopback (DYLD interpose target)
 * ================================================================ */

/* Helper: append line to log file (safe to call before constructors) */
static void hid_log(const char *fmt, ...) {
    int fd = open("/tmp/rosettasim_hid_backport.txt", O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd < 0) return;
    char buf[512];
    va_list ap;
    va_start(ap, fmt);
    int len = vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    write(fd, buf, len);
    write(fd, "\n", 1);
    close(fd);
}

static bool hook_SpawnLoopback(void *hidSystem) {
    hid_log("[HID-backport] INTERPOSE FIRED: hidSystem=%p pid=%d", hidSystem, getpid());

    /* Step 1: bootstrap_look_up */
    mach_port_t send_port = MACH_PORT_NULL;
    kern_return_t kr = bootstrap_look_up(bootstrap_port, "IndigoHIDRegistrationPort", &send_port);
    hid_log("[HID-backport] Step 1: bootstrap_look_up kr=%d port=0x%x", kr, send_port);
    if (kr != KERN_SUCCESS || send_port == MACH_PORT_NULL) {
        hid_log("[HID-backport] FAILED at step 1");
        return false;
    }

    /* Step 2: mach_port_allocate */
    mach_port_t recv_port = MACH_PORT_NULL;
    kr = mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &recv_port);
    hid_log("[HID-backport] Step 2: mach_port_allocate kr=%d port=0x%x", kr, recv_port);
    if (kr != KERN_SUCCESS) {
        hid_log("[HID-backport] FAILED at step 2");
        return false;
    }

    kr = mach_port_insert_right(mach_task_self(), recv_port, recv_port, MACH_MSG_TYPE_MAKE_SEND);
    hid_log("[HID-backport] Step 2b: insert_right kr=%d", kr);

    /* Step 3: Send handshake */
    mach_msg_header_t handshake = {
        .msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, MACH_MSG_TYPE_MAKE_SEND),
        .msgh_size = sizeof(handshake),
        .msgh_remote_port = send_port,
        .msgh_local_port = recv_port,
        .msgh_id = 0
    };
    kr = mach_msg_send(&handshake);
    hid_log("[HID-backport] Step 3: mach_msg_send kr=%d", kr);
    if (kr != KERN_SUCCESS) {
        hid_log("[HID-backport] FAILED at step 3");
        return false;
    }

    g_hid_recv_port = recv_port;
    hid_log("[HID-backport] HANDSHAKE SUCCESS: recv_port=0x%x", recv_port);

    /* Step 4: Set up dispatch_source for HID events */
    dispatch_queue_t q = dispatch_queue_create("com.rosettasim.hid.recv",
        dispatch_queue_attr_make_with_autorelease_frequency(
            DISPATCH_QUEUE_SERIAL, DISPATCH_AUTORELEASE_FREQUENCY_WORK_ITEM));
    g_hid_source = dispatch_source_create(DISPATCH_SOURCE_TYPE_MACH_RECV,
                                           g_hid_recv_port, 0, q);
    dispatch_source_set_event_handler(g_hid_source, ^{
        hid_receive_handler();
    });
    dispatch_activate(g_hid_source);

    hid_log("[HID-backport] dispatch_source activated — returning true");
    return true;
}

/* ================================================================
 * DYLD __interpose section — processed at load time, before constructors
 * ================================================================ */

__attribute__((used, section("__DATA,__interpose")))
static struct { void *replacement; void *original; } interpose_table[] = {
    { (void *)hook_SpawnLoopback, (void *)IndigoHIDSystemSpawnLoopback },
};

/* ================================================================
 * Constructor — diagnostic logging only (interpose already happened)
 * ================================================================ */

__attribute__((constructor))
static void hid_backport_init(void) {
    int fd = open("/tmp/rosettasim_hid_debug.txt", O_WRONLY | O_CREAT | O_APPEND, 0644);
    FILE *out = fd >= 0 ? fdopen(fd, "a") : stderr;

    fprintf(out, "\n=== [HID-backport] constructor pid=%d prog=%s ===\n",
            getpid(), getprogname());

    const char *envs[] = {
        "SIMULATOR_UDID", "DYLD_ROOT_PATH",
        "SIMULATOR_FRAMEBUFFER_FRAMEWORK",
        "SIMULATOR_HID_SYSTEM_MANAGER", NULL
    };
    for (int i = 0; envs[i]; i++) {
        const char *val = getenv(envs[i]);
        fprintf(out, "  env %s = %s\n", envs[i], val ?: "(null)");
    }

    fprintf(out, "  g_hid_recv_port = 0x%x (0=interpose didn't fire)\n", g_hid_recv_port);
    fprintf(out, "=== [HID-backport] done ===\n");
    if (out != stderr) fclose(out);
}
