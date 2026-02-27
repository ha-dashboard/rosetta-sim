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

/* No fishhook needed — using __DATA,__interpose instead */

/* Forward declaration */
static void hid_log(const char *fmt, ...) __attribute__((format(printf, 1, 2)));

/* ================================================================
 * HID event receive handler
 * ================================================================ */

static mach_port_t g_hid_recv_port = MACH_PORT_NULL;
static dispatch_source_t g_hid_source = nil;

/* IOHIDEvent creation from serialized data (IOKit private API) */
typedef void *IOHIDEventRef;
typedef void *IOHIDEventSystemClientRef;
typedef IOHIDEventRef (*IOHIDEventCreateWithDataFn)(void *allocator, void *data, uint32_t options);
typedef void (*IOHIDEventSystemClientDispatchEventFn)(IOHIDEventSystemClientRef client, IOHIDEventRef event);
typedef IOHIDEventSystemClientRef (*IOHIDEventSystemClientCreateWithTypeFn)(void *allocator, int type, void *props);

static IOHIDEventCreateWithDataFn g_create_event = NULL;
static IOHIDEventSystemClientDispatchEventFn g_dispatch_event = NULL;
static IOHIDEventSystemClientRef g_hid_client = NULL;

/* Resolve IOHIDEvent functions at init time (called from constructor) */
static void resolve_iohid_functions(void) {
    g_create_event = (IOHIDEventCreateWithDataFn)dlsym(RTLD_DEFAULT, "IOHIDEventCreateWithData");
    g_dispatch_event = (IOHIDEventSystemClientDispatchEventFn)dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientDispatchEvent");

    /* Try to get existing HID client, or create one */
    IOHIDEventSystemClientCreateWithTypeFn create_client =
        (IOHIDEventSystemClientCreateWithTypeFn)dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientCreateWithType");
    if (create_client) {
        /* Type 1 = monitor client (receives events without exclusive access) */
        g_hid_client = create_client(NULL, 1, NULL);
    }

    hid_log("[HID-backport] IOHIDEvent functions: create=%p dispatch=%p client=%p",
            (void *)g_create_event, (void *)g_dispatch_event, (void *)g_hid_client);
}

/* IndigoHID message format (from Agent A Finding 69):
 * mach_msg_header_t (24 bytes) + IndigoHIDMessageStruct
 * IndigoHIDMessageStruct has event data at offset +8 from header end */

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
    recv_count++;
    if (recv_count <= 10) {
        hid_log("[HID-backport] HID msg #%d: id=%d size=%d",
                recv_count, msg.header.msgh_id, msg.header.msgh_size);
    }

    /* Try to create IOHIDEvent from the message payload and dispatch it */
    if (g_create_event && g_dispatch_event && g_hid_client) {
        uint32_t payload_size = msg.header.msgh_size - sizeof(mach_msg_header_t);
        if (payload_size > 8) {
            /* The event data starts after the IndigoHID header (8 bytes) */
            CFDataRef data = CFDataCreateWithBytesNoCopy(NULL,
                msg.payload + 8, payload_size - 8, kCFAllocatorNull);
            if (data) {
                IOHIDEventRef event = g_create_event(NULL, (void *)data, 0);
                if (event) {
                    g_dispatch_event(g_hid_client, event);
                    CFRelease(event);
                    if (recv_count <= 10)
                        hid_log("[HID-backport] Dispatched IOHIDEvent (payload=%u)", payload_size);
                }
                CFRelease(data);
            }
        }
    }

    /* Reply if expected */
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

/* Declare the original function for the interpose table */
extern bool IndigoHIDSystemSpawnLoopback(void *hidSystem);

__attribute__((used, section("__DATA,__interpose")))
static struct { void *replacement; void *original; } interpose_table[] = {
    { (void *)hook_SpawnLoopback, (void *)IndigoHIDSystemSpawnLoopback },
};

/* ================================================================
 * Constructor — diagnostics only (interpose already happened at load time)
 * ================================================================ */

__attribute__((constructor))
static void hid_backport_init(void) {
    int logfd = open("/tmp/rosettasim_hid_debug.txt", O_WRONLY | O_CREAT | O_APPEND, 0644);
    FILE *out = logfd >= 0 ? fdopen(logfd, "a") : stderr;

    fprintf(out, "\n=== [HID-backport] constructor pid=%d prog=%s ===\n",
            getpid(), getprogname());
    fprintf(out, "  g_hid_recv_port = 0x%x (0=interpose didn't fire)\n", g_hid_recv_port);

    const char *envs[] = {
        "SIMULATOR_UDID", "DYLD_ROOT_PATH",
        "SIMULATOR_HID_SYSTEM_MANAGER", NULL
    };
    for (int i = 0; envs[i]; i++) {
        const char *val = getenv(envs[i]);
        fprintf(out, "  env %s = %s\n", envs[i], val ?: "(null)");
    }

    fprintf(out, "=== [HID-backport] constructor done ===\n");
    if (out != stderr) fclose(out);

    /* Resolve IOHIDEvent dispatch functions for HID event forwarding */
    resolve_iohid_functions();
}
