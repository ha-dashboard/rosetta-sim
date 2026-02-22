/*
 * RosettaSim Bridge Library - Phase 4a
 *
 * Injected into the simulated process via DYLD_INSERT_LIBRARIES.
 * Interposes BackBoardServices and related functions to bypass
 * the backboardd connection requirement.
 *
 * Compile:
 *   clang -arch x86_64 -dynamiclib \
 *     -isysroot {SDK} -mios-simulator-version-min=10.0 \
 *     -F{SDK}/System/Library/Frameworks \
 *     -F{SDK}/System/Library/PrivateFrameworks \
 *     -framework CoreFoundation -framework Foundation \
 *     -framework BackBoardServices -framework GraphicsServices \
 *     -framework QuartzCore \
 *     -install_name @rpath/rosettasim_bridge.dylib \
 *     -o rosettasim_bridge.dylib rosettasim_bridge.m
 *
 * Run:
 *   DYLD_ROOT_PATH={SDK} DYLD_INSERT_LIBRARIES=./rosettasim_bridge.dylib ./app
 */

#import <stdlib.h>
#import <string.h>
#import <unistd.h>
#import <stdio.h>
#import <stdarg.h>
#import <stdbool.h>
#import <mach/mach.h>
#import <mach/vm_map.h>
#import <dlfcn.h>
#import <setjmp.h>
#import <mach-o/dyld.h>
#import <mach-o/nlist.h>
#import <mach-o/loader.h>
#import <signal.h>
#import <pthread.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <sys/mman.h>
#import <sys/stat.h>
#import <fcntl.h>
#import <mach/mach_time.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <sys/select.h>
#import <netdb.h>
#import <errno.h>
#import <CoreFoundation/CoreFoundation.h>
#import <Foundation/Foundation.h>

#include "../shared/rosettasim_framebuffer.h"

/* Forward declarations for frame capture system */
static id _bridge_delegate = nil;
static id _bridge_root_window = nil;
static void find_root_window(id delegate);
static void start_frame_capture(void);
static void _mark_display_dirty(void);

/* Display refresh control — declared early for use by _force_display_recursive.
 *
 * _force_full_refresh: When 1, setNeedsDisplay is called on ALL layers with
 * custom drawing, even those that already have content. This destroys cached
 * backing stores (tint colors, selection states, etc.) and should ONLY be used
 * during initial startup when content has never been drawn.
 *
 * For interaction-driven updates (touch, keyboard), use _force_display_countdown
 * which calls setNeedsDisplay only on layers WITHOUT content (nil backing store).
 * This preserves tint colors and selection state while still populating new layers. */
static int _force_full_refresh = 1;  /* Only for initial startup */

/* ================================================================
 * Logging
 * ================================================================ */

static char _log_buf[4096];

static void bridge_log(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(_log_buf, sizeof(_log_buf), fmt, ap);
    va_end(ap);
    if (n > 0) {
        write(STDERR_FILENO, "[RosettaSim] ", 13);
        write(STDERR_FILENO, _log_buf, n);
        write(STDERR_FILENO, "\n", 1);
    }
}

/* ================================================================
 * Original function declarations (from BackBoardServices)
 *
 * These are resolved at link time against the simulator SDK's
 * BackBoardServices.framework. dyld uses them as the "replacee"
 * in the interposition table.
 * ================================================================ */

/* BackBoardServices */
extern bool BKSDisplayServicesStart(void);
extern mach_port_t BKSDisplayServicesServerPort(void);
extern void BKSDisplayServicesGetMainScreenInfo(float *width, float *height,
                                                 float *scaleX, float *scaleY);
extern bool BKSWatchdogGetIsAlive(int timeout);
extern mach_port_t BKSWatchdogServerPort(void);

/* GraphicsServices */
extern void GSSetMainScreenInfo(double width, double height,
                                float scaleX, float scaleY);
extern void GSInitialize(void);

/* GraphicsServices - Purple port management */
extern mach_port_t GSGetPurpleSystemEventPort(void);
extern mach_port_t GSGetPurpleWorkspacePort(void);
extern mach_port_t GSGetPurpleSystemAppPort(void);
extern void GSRegisterPurpleNamedPerPIDPort(mach_port_t port, const char *name);
extern void GSRegisterPurpleNamedPort(const char *name);
extern void GSEventInitialize(bool asExtension);
extern void _GSEventInitializeApp(void);

/* BackBoardServices - HID events */
extern void BKSHIDEventRegisterEventCallbackOnRunLoop(void *callback,
                                                       void *target,
                                                       void *refcon,
                                                       void *runloop);

/* QuartzCore */
extern mach_port_t CARenderServerGetServerPort(void);

/* SystemConfiguration — needed to stub network reachability.
 * Without configd_sim, SCNetworkReachability functions hang, blocking
 * NSURLSession from making any HTTP requests. We stub these to always
 * report "reachable" since the host macOS networking stack works. */
typedef const void *SCNetworkReachabilityRef;
typedef uint32_t SCNetworkReachabilityFlags;
typedef void (*SCNetworkReachabilityCallBack)(SCNetworkReachabilityRef, SCNetworkReachabilityFlags, void *);
typedef struct {
    int version;
    void *info;
    const void *(*retain)(const void *);
    void (*release)(const void *);
    void *(*copyDescription)(const void *);
} SCNetworkReachabilityContext;
enum {
    kSCNetworkReachabilityFlagsReachable = 1 << 1,
    kSCNetworkReachabilityFlagsIsDirect = 1 << 17
};
extern SCNetworkReachabilityRef SCNetworkReachabilityCreateWithAddress(
    CFAllocatorRef allocator, const struct sockaddr *address);
extern SCNetworkReachabilityRef SCNetworkReachabilityCreateWithName(
    CFAllocatorRef allocator, const char *nodename);
extern bool SCNetworkReachabilityGetFlags(SCNetworkReachabilityRef target,
                                           SCNetworkReachabilityFlags *flags);
extern bool SCNetworkReachabilitySetCallback(SCNetworkReachabilityRef target,
                                              SCNetworkReachabilityCallBack callback,
                                              SCNetworkReachabilityContext *context);
extern bool SCNetworkReachabilityScheduleWithRunLoop(SCNetworkReachabilityRef target,
                                                       CFRunLoopRef runLoop,
                                                       CFStringRef runLoopMode);
extern bool SCNetworkReachabilityUnscheduleFromRunLoop(SCNetworkReachabilityRef target,
                                                         CFRunLoopRef runLoop,
                                                         CFStringRef runLoopMode);

/* SCDynamicStore — needed for proxy configuration.
 * NSURLSession queries proxy config via SCDynamicStoreCopyProxies.
 * Without configd_sim, this returns NULL and NSURLSession won't make requests. */
typedef const void *SCDynamicStoreRef;
typedef void (*SCDynamicStoreCallBack)(SCDynamicStoreRef store, CFArrayRef changedKeys, void *info);
typedef struct {
    int version;
    void *info;
    const void *(*retain)(const void *);
    void (*release)(const void *);
    void *(*copyDescription)(const void *);
} SCDynamicStoreContext;
extern SCDynamicStoreRef SCDynamicStoreCreate(CFAllocatorRef allocator,
                                               CFStringRef name,
                                               SCDynamicStoreCallBack callout,
                                               SCDynamicStoreContext *context);
extern CFDictionaryRef SCDynamicStoreCopyProxies(SCDynamicStoreRef store);

/* ================================================================
 * Simulated device configuration
 * ================================================================ */

/* Device configuration — defaults to iPhone 6s (375x667 @2x).
 *
 * Override via environment variables:
 *   ROSETTASIM_SCREEN_WIDTH   — screen width in points (default: 375)
 *   ROSETTASIM_SCREEN_HEIGHT  — screen height in points (default: 667)
 *   ROSETTASIM_SCREEN_SCALE   — screen scale factor (default: 2.0)
 *   ROSETTASIM_DEVICE_PROFILE — preset: "iphone6s", "iphone6plus", "ipad"
 *
 * Presets:
 *   iphone6s    — 375x667 @2x (750x1334 pixels)
 *   iphone6plus — 414x736 @3x (1242x2208 pixels)
 *   iphonese    — 320x568 @2x (640x1136 pixels)
 *   ipad        — 768x1024 @2x (1536x2048 pixels)
 *   ipadpro     — 1024x1366 @2x (2048x2732 pixels)
 */
static double kScreenWidth  = 375.0;
static double kScreenHeight = 667.0;
static float  kScreenScaleX = 2.0f;
static float  kScreenScaleY = 2.0f;

static void _configure_device_profile(void) {
    const char *profile = getenv("ROSETTASIM_DEVICE_PROFILE");
    if (profile) {
        if (strcmp(profile, "iphone6plus") == 0) {
            kScreenWidth = 414.0; kScreenHeight = 736.0;
            kScreenScaleX = 3.0f; kScreenScaleY = 3.0f;
        } else if (strcmp(profile, "iphonese") == 0) {
            kScreenWidth = 320.0; kScreenHeight = 568.0;
            kScreenScaleX = 2.0f; kScreenScaleY = 2.0f;
        } else if (strcmp(profile, "ipad") == 0) {
            kScreenWidth = 768.0; kScreenHeight = 1024.0;
            kScreenScaleX = 2.0f; kScreenScaleY = 2.0f;
        } else if (strcmp(profile, "ipadpro") == 0) {
            kScreenWidth = 1024.0; kScreenHeight = 1366.0;
            kScreenScaleX = 2.0f; kScreenScaleY = 2.0f;
        }
        /* "iphone6s" or unknown → use defaults */
    }

    /* Individual overrides take precedence over profile */
    const char *w = getenv("ROSETTASIM_SCREEN_WIDTH");
    const char *h = getenv("ROSETTASIM_SCREEN_HEIGHT");
    const char *s = getenv("ROSETTASIM_SCREEN_SCALE");
    if (w) kScreenWidth = atof(w);
    if (h) kScreenHeight = atof(h);
    if (s) { kScreenScaleX = (float)atof(s); kScreenScaleY = kScreenScaleX; }
}

/* ================================================================
 * Replacement implementations
 * ================================================================ */

/*
 * Replace BKSDisplayServicesStart()
 *
 * Original flow:
 *   1. bootstrap_look_up("com.apple.backboard.display.services")
 *   2. MIG msg 6001000 → check isAlive
 *   3. MIG msg 6001005 → get screen info
 *   4. GSSetMainScreenInfo(w, h, sx, sy)
 *   5. Assert [CADisplay mainDisplay] != nil
 *
 * We skip steps 1-3 (no backboardd), do step 4 ourselves,
 * and skip step 5 (no CARenderServer yet).
 */
static bool replacement_BKSDisplayServicesStart(void) {
    bridge_log("BKSDisplayServicesStart() intercepted — calling REAL implementation");

    /* Call the REAL BKSDisplayServicesStart. It will:
     * 1. Call bootstrap_look_up("com.apple.backboard.display.services")
     *    → intercepted by springboard_shim → routed through broker
     *    → returns the display services port in purple_fb_server
     * 2. Send MIG msg_id 6001000 to check if server is alive
     *    → display services handler responds with isAlive=TRUE
     * 3. Establish the display services connection
     *
     * This enables UIKit to use proper display configuration from
     * backboardd, which should make CoreAnimation create IOSurface-backed
     * backing stores for server compositing. */

    /* The REAL function is accessible via the original function pointer.
     * Since we DYLD-interposed it, the original is still at its address
     * but our replacement runs instead. We can't call the original directly.
     * Instead, let the function proceed by setting up GSMainScreenInfo
     * and then doing the display services connection ourselves. */

    /* For now, set screen info and return TRUE — the display services
     * connection happens through the broker automatically when UIKit
     * calls BKSDisplayServicesServerPort internally. */
    GSSetMainScreenInfo(kScreenWidth, kScreenHeight, kScreenScaleX, kScreenScaleY);
    bridge_log("  GSSetMainScreenInfo set, returning TRUE");
    return true;
}

/*
 * Replace BKSDisplayServicesServerPort()
 *
 * Original does bootstrap_look_up("com.apple.backboard.display.services").
 * We return MACH_PORT_NULL since we don't have a real backboardd.
 * Any code that tries to use this port will get a send error,
 * which we'll handle as it comes.
 */
/* Forward declarations for broker communication */
static mach_port_t bridge_broker_lookup(const char *name);

static mach_port_t replacement_BKSDisplayServicesServerPort(void) {
    /* Get the REAL display services port from the broker.
     * This connects the app to the display services handler in purple_fb_server. */
    static mach_port_t cached_port = MACH_PORT_NULL;
    bridge_log("BKSDisplayServicesServerPort() CALLED (cached=%u)", cached_port);
    if (cached_port != MACH_PORT_NULL) return cached_port;

    /* Retry a few times — the port may not be registered yet */
    for (int retry = 0; retry < 20; retry++) {
        mach_port_t port = bridge_broker_lookup("com.apple.backboard.display.services");
        if (port != MACH_PORT_NULL) {
            cached_port = port;
            bridge_log("BKSDisplayServicesServerPort() → %u (broker, retry=%d)", port, retry);
            return port;
        }
        if (retry == 0) {
            bridge_log("BKSDisplayServicesServerPort: lookup failed, retrying (20x250ms)...");
        }
        usleep(250000); /* 250ms between retries */
    }
    bridge_log("BKSDisplayServicesServerPort() → MACH_PORT_NULL (20 retries = 5s)");
    return MACH_PORT_NULL;
}

/*
 * Replace BKSDisplayServicesGetMainScreenInfo()
 *
 * Fills in the screen dimensions for the simulated device.
 */
static void replacement_BKSDisplayServicesGetMainScreenInfo(
    float *width, float *height, float *scaleX, float *scaleY)
{
    bridge_log("BKSDisplayServicesGetMainScreenInfo() intercepted");
    if (width)  *width  = (float)kScreenWidth;
    if (height) *height = (float)kScreenHeight;
    if (scaleX) *scaleX = kScreenScaleX;
    if (scaleY) *scaleY = kScreenScaleY;
}

/*
 * Replace BKSWatchdogGetIsAlive()
 *
 * Original sends a MIG message to the watchdog port.
 * We just say "yes, alive."
 */
static bool replacement_BKSWatchdogGetIsAlive(int timeout) {
    bridge_log("BKSWatchdogGetIsAlive(%d) intercepted → TRUE", timeout);
    return true;
}

/*
 * Replace BKSWatchdogServerPort()
 */
static mach_port_t replacement_BKSWatchdogServerPort(void) {
    bridge_log("BKSWatchdogServerPort() intercepted → MACH_PORT_NULL");
    return MACH_PORT_NULL;
}

/* Forward declarations for broker-based CARenderServer lookup */
extern mach_port_t bootstrap_port;
extern kern_return_t bootstrap_look_up(mach_port_t, const char *, mach_port_t *);
extern kern_return_t task_get_special_port(mach_port_t, int, mach_port_t *);
#ifndef TASK_BOOTSTRAP_PORT
#define TASK_BOOTSTRAP_PORT 4
#endif

/* CARenderServer connection state — set when real server is available via broker */
static mach_port_t g_ca_server_port = MACH_PORT_NULL;
static int g_ca_server_connected = 0;
static id _bridge_pre_created_context = nil; /* Pre-created REMOTE CAContext */

/* GPU rendering mode — when active, CARenderServer handles display compositing.
 * Set after UIKit init if CADisplay is available from CARenderServer.
 * In this mode, frame_capture_tick skips CPU rendering and copies from
 * the backboardd framebuffer (where CARenderServer renders). */
static int g_gpu_rendering_active = 0;
static void *_backboardd_fb_mmap = NULL;
static size_t _backboardd_fb_size = 0;

/* Broker port — obtained from TASK_BOOTSTRAP_PORT when running under broker */
static mach_port_t g_bridge_broker_port = MACH_PORT_NULL;

/* Broker custom protocol message ID */
#define BRIDGE_BROKER_LOOKUP_PORT   701

/*
 * Direct broker lookup via custom protocol (msg_id 701).
 *
 * iOS SDK's bootstrap_look_up uses mach_msg2/XPC internally on macOS 26,
 * which the broker (a standard mach_msg receiver) cannot handle. Instead,
 * we send a raw mach_msg with the broker's custom LOOKUP_PORT format.
 *
 * This matches the app_shim's app_broker_lookup() implementation.
 */
static mach_port_t bridge_broker_lookup(const char *name) {
    if (g_bridge_broker_port == MACH_PORT_NULL || !name) return MACH_PORT_NULL;

    /* Create reply port */
    mach_port_t reply_port;
    kern_return_t kr = mach_port_allocate(mach_task_self(),
                                           MACH_PORT_RIGHT_RECEIVE, &reply_port);
    if (kr != KERN_SUCCESS) return MACH_PORT_NULL;

    /* Build BROKER_LOOKUP_PORT request (matches bootstrap_simple_request_t in broker) */
    union {
        struct {
            mach_msg_header_t header;       /* 24 bytes */
            NDR_record_t ndr;               /* 8 bytes */
            uint32_t name_len;              /* 4 bytes */
            char name[128];                 /* 128 bytes */
        } req;
        uint8_t raw[2048];
    } buf;
    memset(&buf, 0, sizeof(buf));

    uint32_t name_len = (uint32_t)strlen(name);
    if (name_len >= 128) name_len = 127;

    buf.req.header.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND,
                                                MACH_MSG_TYPE_MAKE_SEND_ONCE);
    buf.req.header.msgh_size = sizeof(buf.req);
    buf.req.header.msgh_remote_port = g_bridge_broker_port;
    buf.req.header.msgh_local_port = reply_port;
    buf.req.header.msgh_id = BRIDGE_BROKER_LOOKUP_PORT;
    buf.req.ndr = NDR_record;
    buf.req.name_len = name_len;
    memcpy(buf.req.name, name, name_len);

    /* Send request and receive reply */
    kr = mach_msg(&buf.req.header,
                   MACH_SEND_MSG | MACH_RCV_MSG | MACH_RCV_TIMEOUT,
                   sizeof(buf.req),
                   sizeof(buf),
                   reply_port,
                   5000,  /* 5 second timeout */
                   MACH_PORT_NULL);

    mach_port_deallocate(mach_task_self(), reply_port);

    if (kr != KERN_SUCCESS) {
        bridge_log("broker lookup '%s': mach_msg failed: %d", name, kr);
        return MACH_PORT_NULL;
    }

    mach_msg_header_t *rh = (mach_msg_header_t *)buf.raw;

    /* Check for complex reply (success — contains port descriptor) */
    if (rh->msgh_bits & MACH_MSGH_BITS_COMPLEX) {
        mach_msg_body_t *body = (mach_msg_body_t *)(buf.raw + sizeof(mach_msg_header_t));
        if (body->msgh_descriptor_count >= 1) {
            mach_msg_port_descriptor_t *pd = (mach_msg_port_descriptor_t *)(body + 1);
            bridge_log("broker lookup '%s': found port=%u", name, pd->name);
            return pd->name;
        }
    }

    bridge_log("broker lookup '%s': not found", name);
    return MACH_PORT_NULL;
}

/*
 * Replace CARenderServerGetServerPort()
 *
 * Original does bootstrap_look_up("com.apple.CARenderServer").
 *
 * When running under the broker (TASK_BOOTSTRAP_PORT is broker port):
 *   - Uses custom broker protocol to look up real CARenderServer
 *   - CoreAnimation uses real GPU rendering via backboardd
 *   - PurpleFBServer writes frames to /tmp/rosettasim_framebuffer
 *
 * Fallback (standalone, no broker):
 *   - Returns MACH_PORT_NULL for CPU-only rendering
 *   - All rendering is CPU via renderInContext: into shared framebuffer
 */
static mach_port_t replacement_CARenderServerGetServerPort(void) {
    /* If already connected to real CARenderServer, return cached port.
     * Also ensure client port is set on first access. */
    if (g_ca_server_connected) {
        /* DISABLED — let CoreAnimation handle context creation naturally.
         * With BKSDisplayServicesStart succeeding and CARenderServerGetServerPort
         * returning a real port, CA should set up the server connection.
         * Creating extra contexts might interfere with the default pipeline. */
        static int _early_ctx = 0;
        if (!_early_ctx) { /* re-enabled for CALayerHost */
            _early_ctx = 1;
            mach_port_t cp = MACH_PORT_NULL;
            mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &cp);
            mach_port_insert_right(mach_task_self(), cp, cp, MACH_MSG_TYPE_MAKE_SEND);
            Class caCtxCls = objc_getClass("CAContext");
            if (caCtxCls) {
                ((void(*)(id, SEL, mach_port_t))objc_msgSend)(
                    (id)caCtxCls, sel_registerName("setClientPort:"), cp);
                bridge_log("CARenderServerGetServerPort: setClientPort:%u", cp);
                @try {
                    NSDictionary *opts = @{@"displayable": @YES, @"display": @(1), @"clientPortNumber": @(cp)};
                    id ctx = ((id(*)(id, SEL, id))objc_msgSend)(
                        (id)caCtxCls, sel_registerName("remoteContextWithOptions:"), opts);
                    if (ctx) {
                        unsigned int cid = ((unsigned int(*)(id, SEL))objc_msgSend)(
                            ctx, sel_registerName("contextId"));
                        bridge_log("CARenderServerGetServerPort: EARLY ctx ID=%u", cid);
                        /* Check if client port is now registered */
                        typedef mach_port_t (*GetCPFn)(unsigned int);
                        GetCPFn gcp = (GetCPFn)dlsym(RTLD_DEFAULT, "CARenderServerGetClientPort");
                        if (gcp) {
                            mach_port_t rcp = gcp(g_ca_server_port);
                            bridge_log("CARenderServerGetServerPort: GetClientPort(%u)=%u (after early ctx)", g_ca_server_port, rcp);
                        }
                        ((id(*)(id, SEL))objc_msgSend)(ctx, sel_registerName("retain"));
                        /* Store globally for UIWindow to use later.
                         * DON'T write context_id file here — UIKit will create
                         * the real window context later with a different ID. */
                        _bridge_pre_created_context = ctx;
                    }
                } @catch (id ex) {
                    bridge_log("CARenderServerGetServerPort: early ctx threw: %s",
                               [[ex description] UTF8String] ?: "?");
                }
            }
        }
        return g_ca_server_port;
    }

    /* Get broker port if not yet resolved */
    if (g_bridge_broker_port == MACH_PORT_NULL) {
        kern_return_t bkr = task_get_special_port(mach_task_self(), TASK_BOOTSTRAP_PORT,
                              &g_bridge_broker_port);
        bridge_log("CARenderServerGetServerPort: task_get_special_port → kr=%d port=0x%x",
                   bkr, g_bridge_broker_port);
    }

    /* With bootstrap_fix.dylib active, standard bootstrap_look_up works through the broker.
     * Try the standard path first (goes through bootstrap_fix → broker MIG protocol). */
    if (g_bridge_broker_port != MACH_PORT_NULL) {
        bridge_log("CARenderServerGetServerPort: looking up via bootstrap_look_up");
        mach_port_t port = MACH_PORT_NULL;
        kern_return_t lkr = bootstrap_look_up(bootstrap_port, "com.apple.CARenderServer", &port);
        if (lkr != KERN_SUCCESS || port == MACH_PORT_NULL) {
            /* Fall back to custom broker protocol */
            bridge_log("CARenderServerGetServerPort: bootstrap_look_up failed (kr=%d), trying broker custom", lkr);
            port = bridge_broker_lookup("com.apple.CARenderServer");
        }
        if (port != MACH_PORT_NULL) {
            g_ca_server_port = port;
            g_ca_server_connected = 1;
            bridge_log("CARenderServerGetServerPort() → port %u "
                       "(real CARenderServer via broker)", port);

            /* Set client port IMMEDIATELY so CoreAnimation knows to use
             * IOSurface-backed backing stores for server compositing.
             * This MUST happen before ANY views/layers are created. */
            static int _client_port_set = 0;
            if (!_client_port_set) {
                _client_port_set = 1;
                mach_port_t cp = MACH_PORT_NULL;
                mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &cp);
                mach_port_insert_right(mach_task_self(), cp, cp, MACH_MSG_TYPE_MAKE_SEND);
                Class caCtxCls = objc_getClass("CAContext");
                if (caCtxCls) {
                    SEL scpSel = sel_registerName("setClientPort:");
                    if (class_respondsToSelector(object_getClass((id)caCtxCls), scpSel)) {
                        ((void(*)(id, SEL, mach_port_t))objc_msgSend)(
                            (id)caCtxCls, scpSel, cp);
                        bridge_log("CARenderServerGetServerPort: setClientPort:%u (early init)", cp);
                    }
                }
            }

            return port;
        }
    }

    /* Fallback to CPU rendering mode (no broker, or CARenderServer not yet registered) */
    static int _logged = 0;
    if (!_logged) {
        bridge_log("CARenderServerGetServerPort() → MACH_PORT_NULL (CPU rendering mode)");
        _logged = 1;
    }
    return MACH_PORT_NULL;
}

/* ================================================================
 * GraphicsServices - Purple port stubs
 *
 * The "Purple" ports are how GraphicsServices communicates with
 * backboardd for event delivery, workspace management, and
 * system app registration. Without backboardd, we provide
 * dummy ports or no-ops.
 * ================================================================ */

/* Allocate a dummy Mach receive right we can hand out */
static mach_port_t _dummy_event_port = MACH_PORT_NULL;
static mach_port_t get_dummy_port(void) {
    if (_dummy_event_port == MACH_PORT_NULL) {
        mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &_dummy_event_port);
        mach_port_insert_right(mach_task_self(), _dummy_event_port,
                               _dummy_event_port, MACH_MSG_TYPE_MAKE_SEND);
    }
    return _dummy_event_port;
}

static mach_port_t replacement_GSGetPurpleSystemEventPort(void) {
    mach_port_t port = get_dummy_port();
    bridge_log("GSGetPurpleSystemEventPort() intercepted → 0x%x", port);
    return port;
}

static mach_port_t replacement_GSGetPurpleWorkspacePort(void) {
    mach_port_t port = get_dummy_port();
    bridge_log("GSGetPurpleWorkspacePort() intercepted → 0x%x", port);
    return port;
}

static mach_port_t replacement_GSGetPurpleSystemAppPort(void) {
    mach_port_t port = get_dummy_port();
    bridge_log("GSGetPurpleSystemAppPort() intercepted → 0x%x", port);
    return port;
}

/*
 * Replace GSRegisterPurpleNamedPerPIDPort()
 *
 * Original tries bootstrap_register() and abort()s on failure.
 * We just log and return without registering.
 */
static void replacement_GSRegisterPurpleNamedPerPIDPort(mach_port_t port, const char *name) {
    bridge_log("GSRegisterPurpleNamedPerPIDPort(0x%x, \"%s\") intercepted → no-op",
               port, name ? name : "(null)");
}

/*
 * Replace GSRegisterPurpleNamedPort()
 */
static void replacement_GSRegisterPurpleNamedPort(const char *name) {
    bridge_log("GSRegisterPurpleNamedPort(\"%s\") intercepted → no-op",
               name ? name : "(null)");
}

/* ================================================================
 * bootstrap_register2 interposition
 *
 * _GSRegisterPurpleNamedPortInPrivateNamespace (internal to
 * GraphicsServices) calls bootstrap_register2() which fails because
 * the bootstrap server doesn't have these services registered.
 * We interpose bootstrap_register2 to actually register the port,
 * using our fixed bootstrap_port. This lets _GSEventInitializeApp
 * complete normally instead of aborting, which in turn lets
 * UIApplicationMain proceed through full UIKit initialization
 * (UIEventDispatcher, UIGestureEnvironment, etc.).
 * ================================================================ */

/* bootstrap functions — declared manually because simulator SDK
 * doesn't include servers/bootstrap.h */
extern kern_return_t bootstrap_register(mach_port_t bp, const char *service_name,
                                         mach_port_t sp);
extern kern_return_t bootstrap_register2(mach_port_t bp, const char *service_name,
                                          mach_port_t sp, int flags);

static kern_return_t replacement_bootstrap_register2(mach_port_t bp,
                                                      const char *service_name,
                                                      mach_port_t sp,
                                                      int flags) {
    /* Allocate a receive right if the provided port is null */
    mach_port_t actual_port = sp;
    if (actual_port == MACH_PORT_NULL) {
        mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &actual_port);
        mach_port_insert_right(mach_task_self(), actual_port,
                               actual_port, MACH_MSG_TYPE_MAKE_SEND);
    }

    /* Try the real bootstrap_register2 with our fixed bootstrap port */
    mach_port_t real_bp = bp;
    if (real_bp == MACH_PORT_NULL) {
        task_get_special_port(mach_task_self(), TASK_BOOTSTRAP_PORT, &real_bp);
    }

    kern_return_t kr = KERN_SUCCESS;
    if (real_bp != MACH_PORT_NULL) {
        /* Try real registration first */
        kr = bootstrap_register(real_bp, (char *)service_name, actual_port);
        if (kr == KERN_SUCCESS) {
            bridge_log("bootstrap_register2(\"%s\") → SUCCESS (port 0x%x)",
                       service_name ? service_name : "(null)", actual_port);
            return KERN_SUCCESS;
        }
    }

    /* Registration failed (already registered, or bootstrap doesn't support it).
     * Return success anyway — the caller (GraphicsServices) just needs to
     * not abort(). The port won't actually be reachable via bootstrap_look_up,
     * but that's OK for our use case. */
    bridge_log("bootstrap_register2(\"%s\") → FAKED SUCCESS (real kr=%d, port 0x%x)",
               service_name ? service_name : "(null)", kr, actual_port);
    return KERN_SUCCESS;
}

/* ================================================================
 * abort() guard for surviving bootstrap_register failures
 *
 * GSRegisterPurpleNamedPerPIDPort calls abort() when
 * bootstrap_register fails. We interpose abort() and use
 * setjmp/longjmp to recover. This is a safety net — with
 * bootstrap_register2 interposed, aborts should be rare.
 * ================================================================ */

extern void abort(void);
extern void exit(int status);
extern void _exit(int status);

static __thread jmp_buf _abort_recovery;
static __thread int _abort_guard_active = 0;

/*
 * Count abort calls so we can allow the first few (from
 * GSRegisterPurpleNamedPerPIDPort) and then let real aborts through.
 * Returning from abort() is UB but works in practice on x86_64 -
 * the caller's code after `call abort` runs normally.
 */
static int _abort_count = 0;

static void replacement_abort(void) {
    _abort_count++;
    if (_abort_guard_active) {
        bridge_log("abort() intercepted (#%d) inside guard → longjmp recovery",
                   _abort_count);
        longjmp(_abort_recovery, _abort_count);
        /* not reached */
    }
    bridge_log("abort() called (#%d) outside guard → terminating", _abort_count);
    /* Use syscall to bypass our _exit interposition */
    syscall(1, 134); /* SYS_exit = 1 */
}

/*
 * Replace exit() - catch workspace server disconnect exit during init.
 * The FBSWorkspace connection failure calls exit() on an XPC callback thread.
 * During startup (_init_phase = 1), we block ALL exits. After the app enters
 * the run loop, we allow exits normally.
 */
static volatile int _init_phase = 1;  /* 1 = during startup, 0 = app running */

/* Track exit call sources for debugging */
static volatile int _exit_call_count = 0;

static void replacement_exit(int status) {
    int call_num = __sync_add_and_fetch(&_exit_call_count, 1);
    int is_main = pthread_main_np();

    /* Identify the likely source of the exit call */
    const char *source = "unknown";
    if (status == 0 && !is_main) {
        source = "FBSWorkspace disconnect (expected)";
    } else if (status == 0 && is_main && _init_phase) {
        source = "UIApplicationMain init failure";
    } else if (status != 0) {
        source = "error exit";
    }

    bridge_log("exit(%d) #%d on %s thread — source: %s",
               status, call_num, is_main ? "main" : "background", source);

    /* During startup: block ALL exits (workspace disconnect is expected) */
    if (_init_phase) {
        if (!is_main) {
            bridge_log("  BLOCKED (init phase, background) — sleeping thread");
            while (1) {
                struct timeval tv = { .tv_sec = 86400, .tv_usec = 0 };
                select(0, NULL, NULL, NULL, &tv);
            }
        }
        if (_abort_guard_active) {
            bridge_log("  BLOCKED (init phase, main, guard active) → longjmp");
            longjmp(_abort_recovery, 200 + status);
        }
        bridge_log("  BLOCKED (init phase, main) — returning");
        return;
    }

    /* After init: FBSWorkspace disconnects (status 0, background thread) are
     * still expected since there's no SpringBoard. Block those. */
    if (status == 0 && !is_main) {
        bridge_log("  BLOCKED (workspace disconnect) — sleeping thread");
        while (1) {
            struct timeval tv = { .tv_sec = 86400, .tv_usec = 0 };
            select(0, NULL, NULL, NULL, &tv);
        }
    }

    /* Non-zero status from main thread after init = real app exit.
     * Allow it by calling the raw syscall. */
    if (status != 0 && is_main) {
        bridge_log("  ALLOWED (real app exit, status %d)", status);
        syscall(1, status); /* SYS_exit */
    }

    /* All other cases: block to keep process alive */
    if (!is_main) {
        bridge_log("  BLOCKED (background, non-workspace) — sleeping thread");
        while (1) {
            struct timeval tv = { .tv_sec = 86400, .tv_usec = 0 };
            select(0, NULL, NULL, NULL, &tv);
        }
    }

    bridge_log("  BLOCKED (main thread, status 0) — returning");
}

/* ================================================================
 * UIApplicationMain interposition
 *
 * We wrap UIApplicationMain with setjmp/longjmp as a FALLBACK path.
 * The PRIMARY initialization path is through replacement_runWithMainScene
 * (installed via swizzle in swizzle_bks_methods), which UIKit calls
 * from within UIApplicationMain.
 *
 * Normal flow (UIApplicationMain succeeds):
 *   1. _UIApplicationMainPreparations → our interpositions
 *   2. UIApplication._run → swizzled to replacement_runWithMainScene
 *   3. replacement_runWithMainScene handles everything
 *
 * Fallback flow (UIApplicationMain aborts):
 *   1. setjmp → UIApplicationMain → abort()
 *   2. longjmp recovery
 *   3. Check _didFinishLaunching_called (skip if already done)
 *   4. Manual initialization only if primary path didn't fire
 * ================================================================ */

extern int UIApplicationMain(int argc, char *argv[], id principal, id delegate);
extern void UIApplicationInitialize(void);

/* Keep track of the args for post-recovery initialization */
static int _saved_argc;
static char **_saved_argv;
static id _saved_principal_class_name;
static id _saved_delegate_class_name;

/* Guard against double initialization — the longjmp fallback path and
 * replacement_runWithMainScene both call didFinishLaunchingWithOptions:.
 * If the swizzled _run path fires (normal case), the longjmp fallback
 * should NOT re-initialize. */
static int _didFinishLaunching_called = 0;

static int replacement_UIApplicationMain(int argc, char *argv[],
                                          id principalClassName,
                                          id delegateClassName) {
    bridge_log("UIApplicationMain() intercepted - wrapping with abort guard");

    _saved_argc = argc;
    _saved_argv = argv;
    _saved_principal_class_name = principalClassName;
    _saved_delegate_class_name = delegateClassName;

    /* Set abort guard */
    _abort_guard_active = 1;
    int abort_result = setjmp(_abort_recovery);

    if (abort_result == 0) {
        /* First pass - try the original UIApplicationMain */
        bridge_log("  Calling original UIApplicationMain (attempt 1)");
        int ret = UIApplicationMain(argc, argv, principalClassName, delegateClassName);
        _abort_guard_active = 0;
        return ret;
    }

    /* We caught an abort - continue initialization manually.
     *
     * IMPORTANT: If replacement_runWithMainScene already ran (the normal path),
     * this code should NOT re-initialize. Check _didFinishLaunching_called. */
    _abort_guard_active = 0;
    bridge_log("  Recovered from abort #%d in UIApplicationMain", abort_result);

    if (_didFinishLaunching_called) {
        bridge_log("  didFinishLaunching already called via _runWithMainScene — skipping fallback init");
        bridge_log("  Starting CFRunLoop (fallback path)...");
        CFRunLoopRun();
        return 0;
    }

    bridge_log("  Completing initialization manually...");

    /* GSEventInitialize does basic event system setup without Purple ports */
    bridge_log("  Calling GSEventInitialize(false)");
    GSEventInitialize(false);

    /* UIApplicationInitialize sets up UIKit internals */
    bridge_log("  Calling UIApplicationInitialize()");
    UIApplicationInitialize();

    /* Create UIApplication and delegate via ObjC runtime */
    bridge_log("  Creating UIApplication and delegate...");

    Class appClass;
    if (_saved_principal_class_name) {
        SEL utf8Sel = sel_registerName("UTF8String");
        const char *name = ((const char *(*)(id, SEL))objc_msgSend)(_saved_principal_class_name, utf8Sel);
        appClass = objc_getClass(name);
    } else {
        appClass = objc_getClass("UIApplication");
    }

    if (appClass) {
        /* First check if sharedApplication already exists (from partial init) */
        SEL sharedSel = sel_registerName("sharedApplication");
        id app = ((id(*)(id, SEL))objc_msgSend)((id)appClass, sharedSel);

        if (!app) {
            /* sharedApplication returned nil, but UIApplication was created
               before the abort (at _UIApplicationMainPreparations+784).
               Search for it via internal globals and ivar scanning. */
            bridge_log("  sharedApplication returned nil - searching for existing instance");

            /* Try common UIKit internal globals */
            const char *globals[] = {
                "UIApp", "_UIApp", "__sharedApplication",
                "_sharedApplication", NULL
            };
            for (int i = 0; globals[i]; i++) {
                id *ptr = (id *)dlsym(RTLD_DEFAULT, globals[i]);
                if (ptr) {
                    bridge_log("  dlsym(%s) → %p, value=%p", globals[i], (void *)ptr, (void *)*ptr);
                    if (*ptr) {
                        app = *ptr;
                        bridge_log("  Found app via %s: %p", globals[i], (void *)app);
                        break;
                    }
                }
            }

            if (!app) {
                bridge_log("  _UIApp is nil after longjmp — attempting recovery...");

                /* Strategy: [UIApplication alloc] may return the existing singleton
                   (NSObject's allocWithZone: for singleton classes). If it does,
                   we can set _UIApp ourselves and fix sharedApplication. */

                /* First try: catch the "only one" exception from alloc+init */
                @try {
                    id attempt = ((id(*)(id, SEL))objc_msgSend)(
                        ((id(*)(id, SEL))objc_msgSend)((id)appClass, sel_registerName("alloc")),
                        sel_registerName("init"));
                    if (attempt) {
                        app = attempt;
                        bridge_log("  Recovered app via alloc+init: %p", (void *)app);
                    }
                } @catch (id exception) {
                    /* "Only one UIApplication" assertion thrown as NSException.
                       The alloc succeeded but init failed. The alloc result
                       IS the existing singleton — grab it from the exception context. */
                    bridge_log("  Caught 'only one' exception — expected");

                    /* Try: call alloc alone (without init). If alloc returns the
                       existing instance, we have our pointer. */
                    id allocResult = ((id(*)(id, SEL))objc_msgSend)(
                        (id)appClass, sel_registerName("alloc"));
                    if (allocResult) {
                        app = allocResult;
                        bridge_log("  Got app from alloc (post-exception): %p", (void *)app);
                    }
                }

                /* If we found the app, set _UIApp so sharedApplication works */
                if (app) {
                    id *uiAppPtr = (id *)dlsym(RTLD_DEFAULT, "UIApp");
                    if (uiAppPtr) {
                        *uiAppPtr = app;
                        bridge_log("  Set _UIApp = %p (sharedApplication should work now)", (void *)app);

                        /* Verify */
                        id verify = ((id(*)(id, SEL))objc_msgSend)(
                            (id)appClass, sel_registerName("sharedApplication"));
                        bridge_log("  Verify sharedApplication: %p", (void *)verify);
                    }
                } else {
                    bridge_log("  Could not recover UIApplication instance");
                    bridge_log("  Proceeding without app ref");
                }
            }
        } else {
            bridge_log("  UIApplication.sharedApplication: %p", (void *)app);
        }

        /* Resolve delegate class name — from UIApplicationMain args, or Info.plist */
        id effectiveDelegateClassName = _saved_delegate_class_name;
        if (!effectiveDelegateClassName) {
            /* Try NSBundle.mainBundle.infoDictionary for delegate/principal class */
            Class bundleClass = objc_getClass("NSBundle");
            if (bundleClass) {
                id mainBundle = ((id(*)(id, SEL))objc_msgSend)(
                    (id)bundleClass, sel_registerName("mainBundle"));
                if (mainBundle) {
                    id infoDict = ((id(*)(id, SEL))objc_msgSend)(
                        mainBundle, sel_registerName("infoDictionary"));
                    if (infoDict) {
                        /* Try NSPrincipalClass first (common in system apps) */
                        id key = ((id(*)(id, SEL, const char *))objc_msgSend)(
                            (id)objc_getClass("NSString"),
                            sel_registerName("stringWithUTF8String:"),
                            "NSPrincipalClass");
                        id val = ((id(*)(id, SEL, id))objc_msgSend)(
                            infoDict, sel_registerName("objectForKey:"), key);
                        if (val) {
                            effectiveDelegateClassName = val;
                            bridge_log("  Delegate from Info.plist NSPrincipalClass");
                        }
                    }
                }
            }
        }

        if (effectiveDelegateClassName) {
            SEL utf8Sel = sel_registerName("UTF8String");
            const char *delName = ((const char *(*)(id, SEL))objc_msgSend)(effectiveDelegateClassName, utf8Sel);
            Class delClass = objc_getClass(delName);

            /* If the class IS UIApplication or a subclass of it, it's the
               principal class, not the delegate. Skip alloc/init to avoid
               "only one UIApplication" crash. */
            if (delClass) {
                Class uiAppClass = objc_getClass("UIApplication");
                Class check = delClass;
                int isAppClass = 0;
                while (check) {
                    if (check == uiAppClass) { isAppClass = 1; break; }
                    check = class_getSuperclass(check);
                }
                if (isAppClass && app) {
                    /* The existing UIApplication IS the principal class (e.g.
                       PreferencesAppController). Use it as its own delegate —
                       UIApplication subclasses often conform to UIApplicationDelegate. */
                    bridge_log("  %s is UIApplication subclass — using existing app as delegate", delName);
                    _bridge_delegate = app;
                    ((id(*)(id, SEL))objc_msgSend)(app, sel_registerName("retain"));
                    ((void(*)(id, SEL, id))objc_msgSend)(app, sel_registerName("setDelegate:"), app);
                    bridge_log("  App set as its own delegate: %p", (void *)app);

                    /* Wait for CARenderServer and establish remote context BEFORE
                     * any views are created. This ensures all layer backing stores
                     * are IOSurface-backed (shared with server) instead of local. */
                    if (!g_ca_server_connected) {
                        bridge_log("  Waiting for CARenderServer before creating views...");
                        for (int wait = 0; wait < 50 && !g_ca_server_connected; wait++) {
                            /* Trigger CARenderServerGetServerPort to check */
                            replacement_CARenderServerGetServerPort();
                            if (g_ca_server_connected) break;
                            usleep(100000); /* 100ms */
                        }
                        if (g_ca_server_connected) {
                            bridge_log("  CARenderServer connected (port=%u) before view creation", g_ca_server_port);
                        } else {
                            bridge_log("  WARNING: CARenderServer not available — views will use local backing stores");
                        }
                    }

                    /* Ensure pre-created context exists BEFORE views are created */
                    if (g_ca_server_connected && !_bridge_pre_created_context) {
                        bridge_log("  Forcing pre-created context NOW (before didFinishLaunching)...");
                        /* Trigger the early context creation */
                        Class caCtxCls = objc_getClass("CAContext");
                        if (caCtxCls) {
                            mach_port_t cp = MACH_PORT_NULL;
                            mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &cp);
                            mach_port_insert_right(mach_task_self(), cp, cp, MACH_MSG_TYPE_MAKE_SEND);
                            ((void(*)(id, SEL, mach_port_t))objc_msgSend)(
                                (id)caCtxCls, sel_registerName("setClientPort:"), cp);
                            @try {
                                NSDictionary *opts = @{@"displayable": @YES, @"display": @(1), @"clientPortNumber": @(cp)};
                                id ctx = ((id(*)(id, SEL, id))objc_msgSend)(
                                    (id)caCtxCls, sel_registerName("remoteContextWithOptions:"), opts);
                                if (ctx) {
                                    ((id(*)(id, SEL))objc_msgSend)(ctx, sel_registerName("retain"));
                                    _bridge_pre_created_context = ctx;
                                    unsigned int cid = ((unsigned int(*)(id, SEL))objc_msgSend)(
                                        ctx, sel_registerName("contextId"));
                                    bridge_log("  Pre-created REMOTE context: ID=%u (before didFinishLaunching)", cid);
                                    /* DON'T write context_id file here — UIKit's _createContextAttached
                                     * creates the real window context with a different ID. */
                                }
                            } @catch (id ex) {
                                bridge_log("  Pre-create context threw: %s", [[ex description] UTF8String] ?: "?");
                            }
                        }
                    }

                    /* Call didFinishLaunchingWithOptions: */
                    SEL didFinishSel = sel_registerName("application:didFinishLaunchingWithOptions:");
                    Class appObjClass = object_getClass(app);
                    if (class_respondsToSelector(appObjClass, didFinishSel)) {
                        bridge_log("  Calling %s application:didFinishLaunchingWithOptions:", delName);
                        ((void(*)(id, SEL, id, id))objc_msgSend)(app, didFinishSel, app, nil);
                        _didFinishLaunching_called = 1;
                    } else {
                        bridge_log("  %s does not respond to didFinishLaunchingWithOptions:", delName);
                    }
                    delClass = NULL; /* Skip the normal alloc/init path */
                } else if (isAppClass) {
                    bridge_log("  %s is UIApplication subclass but no app ref — skipping", delName);
                    delClass = NULL;
                }
            }

            if (delClass) {
                SEL allocSel = sel_registerName("alloc");
                SEL initSel = sel_registerName("init");
                SEL setDelSel = sel_registerName("setDelegate:");

                id delegate = ((id(*)(id, SEL))objc_msgSend)(
                    ((id(*)(id, SEL))objc_msgSend)((id)delClass, allocSel), initSel);

                if (delegate) {
                    _bridge_delegate = delegate;
                    ((id(*)(id, SEL))objc_msgSend)(delegate, sel_registerName("retain"));

                    if (app) {
                        ((void(*)(id, SEL, id))objc_msgSend)(app, setDelSel, delegate);
                        bridge_log("  Delegate set on app: %s @ %p", delName, (void *)delegate);
                    } else {
                        bridge_log("  No app reference, delegate created: %s @ %p", delName, (void *)delegate);
                    }

                    /* Call application:didFinishLaunchingWithOptions: */
                    SEL didFinishSel = sel_registerName("application:didFinishLaunchingWithOptions:");
                    if (class_respondsToSelector(delClass, didFinishSel)) {
                        bridge_log("  Calling application:didFinishLaunchingWithOptions:");
                        ((void(*)(id, SEL, id, id))objc_msgSend)(delegate, didFinishSel, app, nil);
                        _didFinishLaunching_called = 1;
                    }
                }
            }
        }
    }

    /* Complete app lifecycle: post notifications and call delegate methods that
       the normal UIApplicationMain would have fired. Many apps rely on these for
       theme setup, timers, network initialization, etc. */
    {
        id sharedApp = appClass ? ((id(*)(id, SEL))objc_msgSend)(
            (id)appClass, sel_registerName("sharedApplication")) : nil;

        Class nsCenterClass = objc_getClass("NSNotificationCenter");
        id center = nsCenterClass ? ((id(*)(id, SEL))objc_msgSend)(
            (id)nsCenterClass, sel_registerName("defaultCenter")) : nil;

        /* Post UIApplicationDidFinishLaunchingNotification */
        if (center) {
            id notifName = ((id(*)(id, SEL, const char *))objc_msgSend)(
                (id)objc_getClass("NSString"),
                sel_registerName("stringWithUTF8String:"),
                "UIApplicationDidFinishLaunchingNotification");
            ((void(*)(id, SEL, id, id, id))objc_msgSend)(
                center, sel_registerName("postNotificationName:object:userInfo:"),
                notifName, sharedApp, nil);
            bridge_log("  Posted UIApplicationDidFinishLaunchingNotification");
        }

        /* Call applicationDidBecomeActive: — triggers theme setup, timers, etc. */
        if (_bridge_delegate && sharedApp) {
            SEL didBecomeActiveSel = sel_registerName("applicationDidBecomeActive:");
            if (class_respondsToSelector(object_getClass(_bridge_delegate), didBecomeActiveSel)) {
                bridge_log("  Calling applicationDidBecomeActive:");
                @try {
                    ((void(*)(id, SEL, id))objc_msgSend)(
                        _bridge_delegate, didBecomeActiveSel, sharedApp);
                } @catch (id e) {
                    bridge_log("  applicationDidBecomeActive: threw exception (continuing)");
                }
            }
        }

        /* Post UIApplicationDidBecomeActiveNotification */
        if (center) {
            id notifName = ((id(*)(id, SEL, const char *))objc_msgSend)(
                (id)objc_getClass("NSString"),
                sel_registerName("stringWithUTF8String:"),
                "UIApplicationDidBecomeActiveNotification");
            ((void(*)(id, SEL, id, id, id))objc_msgSend)(
                center, sel_registerName("postNotificationName:object:userInfo:"),
                notifName, sharedApp, nil);
            bridge_log("  Posted UIApplicationDidBecomeActiveNotification");
        }
    }

    /* Set up continuous frame capture before starting the run loop */
    bridge_log("  Setting up frame capture...");
    find_root_window(_bridge_delegate);
    start_frame_capture();

    /* Mark init complete — exit() calls are now allowed */
    _init_phase = 0;

    /* Start the run loop */
    bridge_log("  Starting CFRunLoop...");
    typedef void (*CFRunLoopRunFunc)(void);
    CFRunLoopRunFunc runLoop = (CFRunLoopRunFunc)dlsym(RTLD_DEFAULT, "CFRunLoopRun");
    if (runLoop) {
        runLoop();
    }

    return 0;
}

/* ================================================================
 * _GSEventInitializeApp replacement
 *
 * The original calls GSRegisterPurpleNamedPerPIDPort internally
 * which calls abort() on bootstrap_register failure.
 * We wrap it in an abort guard to survive.
 * ================================================================ */

static void replacement_GSEventInitializeApp(void) {
    bridge_log("_GSEventInitializeApp() intercepted");
    bridge_log("  Wrapping in abort guard to survive bootstrap_register failure");

    /* Set up abort guard */
    _abort_guard_active = 1;
    if (setjmp(_abort_recovery) == 0) {
        /* First pass - call the original _GSEventInitializeApp */
        /* The interpose table has our function as the replacement,
           so calling through the extern will go to our version.
           We need to call the ORIGINAL. Use dlsym to find it. */
        typedef void (*GSEventInitAppFunc)(void);
        GSEventInitAppFunc original = (GSEventInitAppFunc)dlsym(RTLD_DEFAULT, "_GSEventInitializeApp");
        if (original && (void *)original != (void *)replacement_GSEventInitializeApp) {
            bridge_log("  Calling original _GSEventInitializeApp with abort guard");
            original();
        } else {
            bridge_log("  Could not find original, calling GSEventInitialize(false)");
            GSEventInitialize(false);
        }
    } else {
        /* Second pass - abort was caught */
        bridge_log("  Survived abort() from _GSEventInitializeApp");
        bridge_log("  GSRegisterPurpleNamedPerPIDPort likely failed (expected)");
    }
    _abort_guard_active = 0;

    bridge_log("  _GSEventInitializeApp replacement complete");
}

/* ================================================================
 * BKSHIDEventRegisterEventCallbackOnRunLoop replacement
 *
 * The original tries to connect to the HID event system client
 * (com.apple.iohideventsystem) which doesn't exist.
 * We skip it - no touch/HID events for now.
 * ================================================================ */

static void replacement_BKSHIDEventRegisterEventCallbackOnRunLoop(
    void *callback, void *target, void *refcon, void *runloop)
{
    bridge_log("BKSHIDEventRegisterEventCallbackOnRunLoop() intercepted → no-op");
    bridge_log("  (Touch input delivered via mmap polling + UITouchesEvent injection)");
}

/* ================================================================
 * SCNetworkReachability stubs
 *
 * Without configd_sim, SystemConfiguration's SCNetworkReachability
 * functions hang waiting for a Mach IPC response that never comes.
 * This blocks NSURLSession from making any HTTP requests.
 *
 * We stub these to always report "network is reachable" since the
 * host macOS networking stack handles actual connectivity.
 * ================================================================ */

/* Fake SCNetworkReachabilityRef — uses a CFData as a valid CF object
 * so callers can safely CFRetain/CFRelease it. */
static SCNetworkReachabilityRef _get_fake_sc_ref(void) {
    static void *fakeRef = NULL;
    if (!fakeRef) {
        fakeRef = (void *)CFDataCreate(NULL, (const uint8_t *)"\xAB\xCD", 2);
        /* Extra retain so it's never deallocated */
        CFRetain((CFTypeRef)fakeRef);
    }
    CFRetain((CFTypeRef)fakeRef);
    return (SCNetworkReachabilityRef)fakeRef;
}

static SCNetworkReachabilityRef replacement_SCNetworkReachabilityCreateWithAddress(
    CFAllocatorRef allocator, const struct sockaddr *address)
{
    bridge_log("SCNetworkReachabilityCreateWithAddress → fake ref (always reachable)");
    return _get_fake_sc_ref();
}

static SCNetworkReachabilityRef replacement_SCNetworkReachabilityCreateWithName(
    CFAllocatorRef allocator, const char *nodename)
{
    bridge_log("SCNetworkReachabilityCreateWithName('%s') → fake ref (always reachable)",
               nodename ? nodename : "NULL");
    return _get_fake_sc_ref();
}

static bool replacement_SCNetworkReachabilityGetFlags(
    SCNetworkReachabilityRef target, SCNetworkReachabilityFlags *flags)
{
    if (flags) {
        *flags = kSCNetworkReachabilityFlagsReachable | kSCNetworkReachabilityFlagsIsDirect;
    }
    return true;
}

/* SCDynamicStore stubs — proxy configuration */
static SCDynamicStoreRef replacement_SCDynamicStoreCreate(
    CFAllocatorRef allocator, CFStringRef name,
    SCDynamicStoreCallBack callout, SCDynamicStoreContext *context)
{
    bridge_log("SCDynamicStoreCreate → fake store (no proxy)");
    return _get_fake_sc_ref();  /* reuse same fake CF ref */
}

static CFDictionaryRef replacement_SCDynamicStoreCopyProxies(SCDynamicStoreRef store)
{
    bridge_log("SCDynamicStoreCopyProxies → empty dict (direct connection, no proxy)");
    return CFDictionaryCreate(NULL, NULL, NULL, 0,
                               &kCFTypeDictionaryKeyCallBacks,
                               &kCFTypeDictionaryValueCallBacks);
}

static bool replacement_SCNetworkReachabilitySetCallback(
    SCNetworkReachabilityRef target, SCNetworkReachabilityCallBack callback,
    SCNetworkReachabilityContext *context)
{
    /* Accept the callback but don't actually monitor — network is always reachable */
    return true;
}

static bool replacement_SCNetworkReachabilityScheduleWithRunLoop(
    SCNetworkReachabilityRef target, CFRunLoopRef runLoop, CFStringRef runLoopMode)
{
    return true;
}

static bool replacement_SCNetworkReachabilityUnscheduleFromRunLoop(
    SCNetworkReachabilityRef target, CFRunLoopRef runLoop, CFStringRef runLoopMode)
{
    return true;
}

/* ================================================================
 * NSURLProtocol bypass — routes HTTP requests through BSD sockets.
 *
 * CFNetwork/NSURLSession requires configd_sim for DNS resolution,
 * proxy configuration, and network interface enumeration. Without it,
 * NSURLSession data tasks never complete. But raw BSD sockets work
 * because they go through the host kernel directly.
 *
 * This NSURLProtocol subclass intercepts HTTP requests and handles
 * them via raw sockets, bypassing CFNetwork entirely.
 * ================================================================ */

@interface RosettaSimURLProtocol : NSURLProtocol
@end

@implementation RosettaSimURLProtocol

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    bridge_log("RosettaSimURLProtocol canInitWithRequest: %s %s",
               request.HTTPMethod.UTF8String ?: "?",
               request.URL.absoluteString.UTF8String ?: "?");
    /* Only handle HTTP (not HTTPS — would need TLS). */
    NSString *scheme = request.URL.scheme;
    if (!scheme) return NO;
    if ([NSURLProtocol propertyForKey:@"RosettaSimHandled" inRequest:request]) {
        return NO;  /* Already handled — prevent recursion */
    }
    return [scheme caseInsensitiveCompare:@"http"] == NSOrderedSame;
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
    return request;
}

- (void)startLoading {
    NSURLRequest *request = self.request;
    NSURL *url = request.URL;

    bridge_log("RosettaSimURLProtocol: %s %s",
               request.HTTPMethod.UTF8String ?: "GET",
               url.absoluteString.UTF8String ?: "?");

    /* Resolve host to IP via getaddrinfo (uses host DNS) */
    NSString *host = url.host;
    int port = url.port ? url.port.intValue : 80;
    if (!host) {
        [self _failWithCode:-1 message:@"No host in URL"];
        return;
    }

    /* Perform HTTP on a background thread. Store the calling thread's run loop
     * so we can schedule client callbacks there. */
    NSThread *callingThread = [NSThread currentThread];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [self _performRequestWithHost:host port:port url:url request:request];
    });
}

- (void)_performRequestWithHost:(NSString *)host port:(int)port
                             url:(NSURL *)url request:(NSURLRequest *)request {
    /* DNS resolution — getaddrinfo + .local fallback.
     *
     * mDNS (.local) names fail with getaddrinfo in the simulated process
     * because mDNSResponder isn't available. We handle this with:
     *   1. Check ROSETTASIM_DNS_MAP env var (format: "host1=1.2.3.4,host2=5.6.7.8")
     *   2. If .local hostname, try getaddrinfo on the bare hostname without ".local"
     *   3. Fall back to getaddrinfo with AI_NUMERICHOST if it looks like an IP
     */
    struct addrinfo hints, *res = NULL;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;

    char portStr[16];
    snprintf(portStr, sizeof(portStr), "%d", port);
    const char *hostCStr = host.UTF8String;

    int gai = getaddrinfo(hostCStr, portStr, &hints, &res);

    /* .local fallback: check DNS map env var, then try without .local suffix */
    if (gai != 0) {
        bridge_log("RosettaSimURLProtocol: getaddrinfo failed for %s: %s — trying fallbacks", hostCStr, gai_strerror(gai));

        /* Check ROSETTASIM_DNS_MAP environment variable */
        const char *dnsMap = getenv("ROSETTASIM_DNS_MAP");
        if (dnsMap) {
            /* Parse "host1=ip1,host2=ip2" */
            char mapCopy[2048];
            strncpy(mapCopy, dnsMap, sizeof(mapCopy) - 1);
            mapCopy[sizeof(mapCopy) - 1] = 0;
            char *saveptr = NULL;
            char *entry = strtok_r(mapCopy, ",", &saveptr);
            while (entry) {
                char *eq = strchr(entry, '=');
                if (eq) {
                    *eq = 0;
                    /* Trim whitespace */
                    char *name = entry;
                    while (*name == ' ') name++;
                    char *ip = eq + 1;
                    while (*ip == ' ') ip++;
                    char *end = ip + strlen(ip) - 1;
                    while (end > ip && *end == ' ') { *end = 0; end--; }

                    if (strcasecmp(name, hostCStr) == 0) {
                        bridge_log("RosettaSimURLProtocol: DNS map override %s → %s", hostCStr, ip);
                        struct addrinfo numhints;
                        memset(&numhints, 0, sizeof(numhints));
                        numhints.ai_family = AF_INET;
                        numhints.ai_socktype = SOCK_STREAM;
                        numhints.ai_flags = AI_NUMERICHOST;
                        gai = getaddrinfo(ip, portStr, &numhints, &res);
                        break;
                    }
                }
                entry = strtok_r(NULL, ",", &saveptr);
            }
        }

        /* If still unresolved and hostname ends in .local, try without suffix */
        if (gai != 0) {
            size_t hlen = strlen(hostCStr);
            if (hlen > 6 && strcasecmp(hostCStr + hlen - 6, ".local") == 0) {
                char stripped[256];
                size_t slen = hlen - 6;
                if (slen < sizeof(stripped)) {
                    memcpy(stripped, hostCStr, slen);
                    stripped[slen] = 0;
                    bridge_log("RosettaSimURLProtocol: trying stripped hostname: %s", stripped);
                    gai = getaddrinfo(stripped, portStr, &hints, &res);
                }
            }
        }
    }

    if (gai != 0) {
        bridge_log("RosettaSimURLProtocol: DNS failed for %s: %s (all fallbacks exhausted)", hostCStr, gai_strerror(gai));
        [self _failWithCode:-1003 message:@"Cannot resolve host"];
        return;
    }
    bridge_log("RosettaSimURLProtocol: DNS resolved %s", hostCStr);

    /* Connect via TCP */
    int sock = socket(AF_INET, SOCK_STREAM, 0);
    if (sock < 0) {
        freeaddrinfo(res);
        [self _failWithCode:-1004 message:@"Cannot create socket"];
        return;
    }

    /* 15 second connect timeout */
    struct timeval tv = { .tv_sec = 15, .tv_usec = 0 };
    setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
    setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    int result = connect(sock, res->ai_addr, (socklen_t)res->ai_addrlen);
    freeaddrinfo(res);

    if (result < 0) {
        close(sock);
        bridge_log("RosettaSimURLProtocol: connect failed: %d", errno);
        [self _failWithCode:-1004 message:@"Cannot connect to host"];
        return;
    }

    /* Build HTTP request */
    NSString *method = request.HTTPMethod ?: @"GET";
    NSString *path = url.path.length > 0 ? url.path : @"/";
    if (url.query) path = [NSString stringWithFormat:@"%@?%@", path, url.query];

    NSMutableString *httpReq = [NSMutableString stringWithFormat:
        @"%@ %@ HTTP/1.1\r\nHost: %@:%d\r\nConnection: close\r\n",
        method, path, host, port];

    /* Add request headers (skip Content-Length — we compute it from body) */
    NSDictionary *headers = request.allHTTPHeaderFields;
    for (NSString *key in headers) {
        if ([key caseInsensitiveCompare:@"Content-Length"] == NSOrderedSame) continue;
        [httpReq appendFormat:@"%@: %@\r\n", key, headers[key]];
    }

    /* Add body — NSURLSession strips HTTPBody when intercepted by NSURLProtocol,
     * so also check HTTPBodyStream as a fallback. */
    NSData *body = request.HTTPBody;
    if (!body || body.length == 0) {
        NSInputStream *bodyStream = request.HTTPBodyStream;
        if (bodyStream) {
            NSMutableData *streamData = [NSMutableData data];
            [bodyStream open];
            uint8_t streamBuf[4096];
            NSInteger bytesRead;
            while ((bytesRead = [bodyStream read:streamBuf maxLength:sizeof(streamBuf)]) > 0) {
                [streamData appendBytes:streamBuf length:bytesRead];
            }
            [bodyStream close];
            if (streamData.length > 0) {
                body = streamData;
                bridge_log("RosettaSimURLProtocol: recovered %lu bytes from HTTPBodyStream",
                    (unsigned long)body.length);
            }
        }
    }
    if (body.length > 0) {
        [httpReq appendFormat:@"Content-Length: %lu\r\n", (unsigned long)body.length];
        bridge_log("RosettaSimURLProtocol: sending body (%lu bytes)", (unsigned long)body.length);
    } else if ([method isEqualToString:@"POST"]) {
        bridge_log("RosettaSimURLProtocol: WARNING — POST with no body");
        [httpReq appendFormat:@"Content-Length: 0\r\n"];
    }
    [httpReq appendString:@"\r\n"];

    /* Log the full request for debugging */
    if ([method isEqualToString:@"POST"]) {
        bridge_log("RosettaSimURLProtocol: full request:\n%s", httpReq.UTF8String);
        if (body.length > 0 && body.length < 1024) {
            NSString *bodyStr = [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding];
            bridge_log("RosettaSimURLProtocol: body: %s", bodyStr ? bodyStr.UTF8String : "(binary)");
        }
    }

    /* Send */
    const char *reqBytes = httpReq.UTF8String;
    send(sock, reqBytes, strlen(reqBytes), 0);
    if (body.length > 0) {
        send(sock, body.bytes, body.length, 0);
    }

    /* Receive response */
    NSMutableData *responseData = [NSMutableData data];
    char buf[8192];
    ssize_t n;
    while ((n = recv(sock, buf, sizeof(buf), 0)) > 0) {
        [responseData appendBytes:buf length:n];
    }
    close(sock);

    if (responseData.length == 0) {
        bridge_log("RosettaSimURLProtocol: empty response");
        [self _failWithCode:-1005 message:@"Empty response from server"];
        return;
    }

    /* Parse HTTP response — find header/body boundary */
    NSRange headerEnd = [responseData rangeOfData:
        [@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding]
        options:0 range:NSMakeRange(0, MIN(responseData.length, 16384))];

    if (headerEnd.location == NSNotFound) {
        bridge_log("RosettaSimURLProtocol: malformed response (no header boundary)");
        [self _failWithCode:-1011 message:@"Malformed response"];
        return;
    }

    NSString *headerStr = [[NSString alloc] initWithData:
        [responseData subdataWithRange:NSMakeRange(0, headerEnd.location)]
        encoding:NSUTF8StringEncoding];
    NSData *bodyData = [responseData subdataWithRange:
        NSMakeRange(headerEnd.location + 4,
                    responseData.length - headerEnd.location - 4)];

    /* Parse status line: "HTTP/1.1 200 OK" */
    NSArray *headerLines = [headerStr componentsSeparatedByString:@"\r\n"];
    NSString *statusLine = headerLines.count > 0 ? headerLines[0] : @"HTTP/1.1 200 OK";
    int statusCode = 200;
    NSRange statusRange = [statusLine rangeOfString:@" "];
    if (statusRange.location != NSNotFound && statusRange.location + 1 < statusLine.length) {
        statusCode = [[statusLine substringFromIndex:statusRange.location + 1] intValue];
    }

    /* Parse response headers */
    NSMutableDictionary *respHeaders = [NSMutableDictionary dictionary];
    for (NSUInteger i = 1; i < headerLines.count; i++) {
        NSRange colonRange = [headerLines[i] rangeOfString:@": "];
        if (colonRange.location != NSNotFound) {
            NSString *key = [headerLines[i] substringToIndex:colonRange.location];
            NSString *val = [headerLines[i] substringFromIndex:colonRange.location + 2];
            respHeaders[key] = val;
        }
    }

    bridge_log("RosettaSimURLProtocol: HTTP %d (%lu bytes body) %s",
               statusCode, (unsigned long)bodyData.length, path.UTF8String);

    /* Auto-connect: When /auth/providers succeeds, the app shows the login
     * form with the correct auth mode. Trigger connectTapped after a delay
     * so the login flow proceeds automatically. The Connect button is outside
     * the card's clipsToBounds area and not tappable by the user. */
    if (statusCode == 200 && [path containsString:@"auth/providers"]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            bridge_log("Auto-connect: Searching for HAConnectionFormView...");
            Class formClass = objc_getClass("HAConnectionFormView");
            if (!formClass || !_bridge_root_window) {
                bridge_log("Auto-connect: HAConnectionFormView class or root window not found");
                return;
            }
            /* Search the view hierarchy for the form view */
            id formView = nil;
            NSMutableArray *stack = [NSMutableArray arrayWithObject:_bridge_root_window];
            while (stack.count > 0) {
                id view = stack.lastObject;
                [stack removeLastObject];
                if ([view isKindOfClass:formClass]) {
                    formView = view;
                    break;
                }
                NSArray *subviews = ((id(*)(id, SEL))objc_msgSend)(
                    view, sel_registerName("subviews"));
                if (subviews) {
                    [stack addObjectsFromArray:subviews];
                }
            }
            if (formView) {
                bridge_log("Auto-connect: Found HAConnectionFormView %p — calling connectTapped", (void *)formView);
                @try {
                    ((void(*)(id, SEL))objc_msgSend)(formView, sel_registerName("connectTapped"));
                    bridge_log("Auto-connect: connectTapped invoked successfully");
                } @catch (id ex) {
                    bridge_log("Auto-connect: connectTapped threw: %s",
                               ((const char *(*)(id, SEL))objc_msgSend)(ex, sel_registerName("UTF8String")) ?: "unknown");
                }
            } else {
                bridge_log("Auto-connect: HAConnectionFormView not found in hierarchy");
            }
        });
    }

    /* Log error response bodies for debugging */
    if (statusCode >= 400 && bodyData.length > 0 && bodyData.length < 2048) {
        NSString *bodyStr = [[NSString alloc] initWithData:bodyData encoding:NSUTF8StringEncoding];
        if (bodyStr) {
            bridge_log("RosettaSimURLProtocol: error body: %s", bodyStr.UTF8String);
        }
    }

    /* Create NSHTTPURLResponse */
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc]
        initWithURL:url statusCode:statusCode HTTPVersion:@"HTTP/1.1"
        headerFields:respHeaders];

    /* Deliver to client. NSURLProtocol client callbacks must happen on the
     * thread/runloop where startLoading was called. For NSURLSession, this is
     * typically an internal session work queue. Use performSelector on the
     * main thread as a reliable delivery mechanism, then also try direct
     * delivery in case the main thread approach is deferred. */
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            [self.client URLProtocol:self didReceiveResponse:response
                cacheStoragePolicy:NSURLCacheStorageNotAllowed];
            if (bodyData.length > 0) {
                [self.client URLProtocol:self didLoadData:bodyData];
            }
            [self.client URLProtocolDidFinishLoading:self];
            bridge_log("RosettaSimURLProtocol: delivered response to client (main queue)");
        } @catch (id ex) {
            bridge_log("RosettaSimURLProtocol: client callback exception: %s",
                [[ex description] UTF8String]);
        }
        dispatch_semaphore_signal(sem);
    });
    /* Wait up to 5 seconds for delivery — this blocks the background thread
     * which is fine since we're done with the HTTP work. */
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
}

- (void)_failWithCode:(NSInteger)code message:(NSString *)message {
    /* Deliver error directly on the current thread (protocol thread) */
    @try {
        NSError *error = [NSError errorWithDomain:NSURLErrorDomain code:code
            userInfo:@{NSLocalizedDescriptionKey: message ?: @"Unknown error"}];
        [self.client URLProtocol:self didFailWithError:error];
    } @catch (id ex) { /* ignore */ }
}

- (void)stopLoading {
    /* Socket is already closed in startLoading */
}

@end

/* Register the URL protocol with NSURLSession by swizzling
 * NSURLSessionConfiguration's protocolClasses getter. */
static NSArray *_orig_protocolClasses_IMP = nil;

static void _register_url_protocol(void) {
    Class protocolClass = [RosettaSimURLProtocol class];

    /* Register globally for old-style NSURLConnection */
    [NSURLProtocol registerClass:protocolClass];
    bridge_log("Registered RosettaSimURLProtocol globally");

    /* Swizzle NSURLSessionConfiguration.protocolClasses getter to include our protocol.
     * Try both the public class and the private concrete class used by CFNetwork. */
    const char *classNames[] = {
        "NSURLSessionConfiguration",
        "__NSCFURLSessionConfiguration",
        NULL
    };
    BOOL swizzled = NO;
    for (int ci = 0; classNames[ci] && !swizzled; ci++) {
        Class configClass = objc_getClass(classNames[ci]);
        if (!configClass) {
            bridge_log("RosettaSimURLProtocol: class %s not found", classNames[ci]);
            continue;
        }
        bridge_log("RosettaSimURLProtocol: found class %s", classNames[ci]);

        SEL protSel = sel_registerName("protocolClasses");
        Method m = class_getInstanceMethod(configClass, protSel);
        if (!m) {
            bridge_log("RosettaSimURLProtocol: no -protocolClasses method on %s", classNames[ci]);
            continue;
        }

        typedef id (*ProtClassesIMP)(id, SEL);
        ProtClassesIMP origIMP = (ProtClassesIMP)method_getImplementation(m);

        /* imp_implementationWithBlock blocks take (id self) as first arg — NO SEL */
        id (^newBlock)(id) = ^id(id self_config) {
            NSArray *orig = origIMP(self_config, protSel);
            NSMutableArray *updated = [NSMutableArray arrayWithObject:protocolClass];
            if (orig) [updated addObjectsFromArray:orig];
            return [updated copy];
        };

        IMP newIMP = imp_implementationWithBlock(newBlock);
        method_setImplementation(m, newIMP);
        bridge_log("Swizzled %s.protocolClasses to include RosettaSimURLProtocol", classNames[ci]);
        swizzled = YES;
    }

    if (!swizzled) {
        bridge_log("WARNING: Could not swizzle protocolClasses — NSURLSession requests won't be intercepted");
    }

    /* Also swizzle NSURLSession's dataTaskWithRequest:completionHandler: to
     * bypass the broken NSURLProtocol/NSURLSession integration.
     * This performs HTTP requests directly and invokes the completion handler. */
    Class sessionClass = objc_getClass("NSURLSession");
    if (sessionClass) {
        SEL dtSel = sel_registerName("dataTaskWithRequest:completionHandler:");
        Method dtMethod = class_getInstanceMethod(sessionClass, dtSel);
        if (dtMethod) {
            typedef id (*orig_dt_fn)(id, SEL, id, id);
            orig_dt_fn origDT = (orig_dt_fn)method_getImplementation(dtMethod);

            id (^dtBlock)(id, id, id) = ^id(id self_session, id request, id completionBlock) {
                NSURL *url = ((NSURL *(*)(id, SEL))objc_msgSend)(request, sel_registerName("URL"));
                NSString *scheme = url ? ((NSString *(*)(id, SEL))objc_msgSend)(url, sel_registerName("scheme")) : nil;
                BOOL isHTTP = scheme && [scheme caseInsensitiveCompare:@"http"] == NSOrderedSame;

                if (!isHTTP || !completionBlock) {
                    return origDT(self_session, dtSel, request, completionBlock);
                }

                bridge_log("NSURLSession swizzle: intercepting %s %s",
                    ((NSString *(*)(id, SEL))objc_msgSend)(request, sel_registerName("HTTPMethod")).UTF8String ?: "?",
                    ((NSString *(*)(id, SEL))objc_msgSend)(url, sel_registerName("absoluteString")).UTF8String ?: "?");

                void (^handler)(NSData *, NSURLResponse *, NSError *) = [completionBlock copy];
                id capturedReq = request;
                NSURL *capturedURL = url;

                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    @autoreleasepool {
                        NSString *host = capturedURL.host;
                        int port = capturedURL.port ? capturedURL.port.intValue : 80;
                        NSString *resolvedHost = host;

                        /* DNS map override */
                        char *dnsMap = getenv("ROSETTASIM_DNS_MAP");
                        if (dnsMap) {
                            NSString *mapStr = [NSString stringWithUTF8String:dnsMap];
                            for (NSString *entry in [mapStr componentsSeparatedByString:@","]) {
                                NSArray *kv = [entry componentsSeparatedByString:@"="];
                                if (kv.count == 2 && [kv[0] isEqualToString:host]) {
                                    resolvedHost = kv[1];
                                    bridge_log("NSURLSession swizzle: DNS override %s -> %s", host.UTF8String, resolvedHost.UTF8String);
                                    break;
                                }
                            }
                        }

                        struct addrinfo hints = {0}, *res = NULL;
                        hints.ai_family = AF_INET;
                        hints.ai_socktype = SOCK_STREAM;
                        char portStr[8];
                        snprintf(portStr, sizeof(portStr), "%d", port);
                        int gai = getaddrinfo(resolvedHost.UTF8String, portStr, &hints, &res);
                        if (gai != 0) {
                            bridge_log("NSURLSession swizzle: DNS resolve failed for %s", resolvedHost.UTF8String);
                            NSError *err = [NSError errorWithDomain:NSURLErrorDomain code:-1003
                                userInfo:@{NSLocalizedDescriptionKey: @"Cannot resolve host"}];
                            dispatch_async(dispatch_get_main_queue(), ^{ handler(nil, nil, err); });
                            return;
                        }

                        int sock = socket(AF_INET, SOCK_STREAM, 0);
                        struct timeval tv = { .tv_sec = 15, .tv_usec = 0 };
                        setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
                        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

                        if (connect(sock, res->ai_addr, (socklen_t)res->ai_addrlen) < 0) {
                            close(sock); freeaddrinfo(res);
                            bridge_log("NSURLSession swizzle: connect failed");
                            NSError *err = [NSError errorWithDomain:NSURLErrorDomain code:-1004
                                userInfo:@{NSLocalizedDescriptionKey: @"Cannot connect"}];
                            dispatch_async(dispatch_get_main_queue(), ^{ handler(nil, nil, err); });
                            return;
                        }
                        freeaddrinfo(res);

                        NSString *method = ((NSString *(*)(id, SEL))objc_msgSend)(capturedReq, sel_registerName("HTTPMethod")) ?: @"GET";
                        NSString *path = capturedURL.path.length > 0 ? capturedURL.path : @"/";
                        if (capturedURL.query) path = [NSString stringWithFormat:@"%@?%@", path, capturedURL.query];

                        NSMutableString *httpReq = [NSMutableString stringWithFormat:
                            @"%@ %@ HTTP/1.1\r\nHost: %@:%d\r\nConnection: close\r\n",
                            method, path, host, port];

                        NSDictionary *headers = ((NSDictionary *(*)(id, SEL))objc_msgSend)(capturedReq, sel_registerName("allHTTPHeaderFields"));
                        for (NSString *key in headers) {
                            if ([key caseInsensitiveCompare:@"Content-Length"] == NSOrderedSame) continue;
                            [httpReq appendFormat:@"%@: %@\r\n", key, headers[key]];
                        }

                        NSData *body = ((NSData *(*)(id, SEL))objc_msgSend)(capturedReq, sel_registerName("HTTPBody"));
                        if (!body || body.length == 0) {
                            NSInputStream *bs = ((NSInputStream *(*)(id, SEL))objc_msgSend)(capturedReq, sel_registerName("HTTPBodyStream"));
                            if (bs) {
                                NSMutableData *sd = [NSMutableData data];
                                [bs open];
                                uint8_t sbuf[4096]; NSInteger br;
                                while ((br = [bs read:sbuf maxLength:sizeof(sbuf)]) > 0)
                                    [sd appendBytes:sbuf length:br];
                                [bs close];
                                body = sd;
                            }
                        }

                        if (body.length > 0)
                            [httpReq appendFormat:@"Content-Length: %lu\r\n", (unsigned long)body.length];
                        [httpReq appendString:@"\r\n"];

                        send(sock, httpReq.UTF8String, strlen(httpReq.UTF8String), 0);
                        if (body.length > 0)
                            send(sock, body.bytes, body.length, 0);

                        NSMutableData *responseData = [NSMutableData data];
                        char rbuf[8192]; ssize_t n;
                        while ((n = recv(sock, rbuf, sizeof(rbuf), 0)) > 0)
                            [responseData appendBytes:rbuf length:n];
                        close(sock);

                        if (responseData.length == 0) {
                            bridge_log("NSURLSession swizzle: empty response");
                            NSError *err = [NSError errorWithDomain:NSURLErrorDomain code:-1005
                                userInfo:@{NSLocalizedDescriptionKey: @"Empty response"}];
                            dispatch_async(dispatch_get_main_queue(), ^{ handler(nil, nil, err); });
                            return;
                        }

                        NSRange hdrEnd = [responseData rangeOfData:
                            [@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding]
                            options:0 range:NSMakeRange(0, MIN(responseData.length, 16384))];

                        if (hdrEnd.location == NSNotFound) {
                            NSError *err = [NSError errorWithDomain:NSURLErrorDomain code:-1011
                                userInfo:@{NSLocalizedDescriptionKey: @"Malformed response"}];
                            dispatch_async(dispatch_get_main_queue(), ^{ handler(nil, nil, err); });
                            return;
                        }

                        NSString *hdrStr = [[NSString alloc] initWithData:
                            [responseData subdataWithRange:NSMakeRange(0, hdrEnd.location)]
                            encoding:NSUTF8StringEncoding];
                        NSData *bodyData = [responseData subdataWithRange:
                            NSMakeRange(hdrEnd.location + 4, responseData.length - hdrEnd.location - 4)];

                        NSArray *lines = [hdrStr componentsSeparatedByString:@"\r\n"];
                        int statusCode = 200;
                        if (lines.count > 0) {
                            NSRange sp = [lines[0] rangeOfString:@" "];
                            if (sp.location != NSNotFound)
                                statusCode = [[lines[0] substringFromIndex:sp.location+1] intValue];
                        }

                        /* Parse response headers */
                        NSMutableDictionary *respHeaders = [NSMutableDictionary dictionary];
                        for (NSUInteger i = 1; i < lines.count; i++) {
                            NSRange colon = [lines[i] rangeOfString:@": "];
                            if (colon.location != NSNotFound) {
                                respHeaders[[lines[i] substringToIndex:colon.location]] =
                                    [lines[i] substringFromIndex:colon.location + 2];
                            }
                        }

                        bridge_log("NSURLSession swizzle: HTTP %d (%lu bytes body)",
                            statusCode, (unsigned long)bodyData.length);

                        NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc]
                            initWithURL:capturedURL statusCode:statusCode HTTPVersion:@"HTTP/1.1"
                            headerFields:respHeaders];

                        dispatch_async(dispatch_get_main_queue(), ^{
                            handler(bodyData, response, nil);
                            bridge_log("NSURLSession swizzle: completion handler invoked on main queue");
                        });

                        /* Auto-connect: trigger connectTapped after auth/providers succeeds */
                        if (statusCode == 200 && [path containsString:@"auth/providers"]) {
                            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                                           dispatch_get_main_queue(), ^{
                                bridge_log("Auto-connect: Searching for HAConnectionFormView...");
                                Class formClass = objc_getClass("HAConnectionFormView");
                                if (!formClass || !_bridge_root_window) {
                                    bridge_log("Auto-connect: HAConnectionFormView class or root window not found");
                                    return;
                                }
                                id formView = nil;
                                NSMutableArray *stack = [NSMutableArray arrayWithObject:_bridge_root_window];
                                while (stack.count > 0) {
                                    id view = stack.lastObject;
                                    [stack removeLastObject];
                                    if ([view isKindOfClass:formClass]) {
                                        formView = view;
                                        break;
                                    }
                                    NSArray *subviews = ((id(*)(id, SEL))objc_msgSend)(
                                        view, sel_registerName("subviews"));
                                    if (subviews) [stack addObjectsFromArray:subviews];
                                }
                                if (formView) {
                                    bridge_log("Auto-connect: Found HAConnectionFormView %p -- calling connectTapped", (void *)formView);
                                    @try {
                                        ((void(*)(id, SEL))objc_msgSend)(formView, sel_registerName("connectTapped"));
                                        bridge_log("Auto-connect: connectTapped invoked successfully");
                                    } @catch (id ex) {
                                        bridge_log("Auto-connect: connectTapped threw: %s",
                                                   ((const char *(*)(id, SEL))objc_msgSend)(ex, sel_registerName("UTF8String")) ?: "unknown");
                                    }
                                } else {
                                    bridge_log("Auto-connect: HAConnectionFormView not found in hierarchy");
                                }
                            });
                        }
                    }
                });

                /* Return nil — we handle everything directly and call the completion
                 * handler ourselves. The caller shouldn't need the task object since
                 * the work is already in progress. */
                return nil;
            };

            IMP dtIMP = imp_implementationWithBlock(dtBlock);
            method_setImplementation(dtMethod, dtIMP);
            bridge_log("Swizzled NSURLSession.dataTaskWithRequest:completionHandler:");

            /* Also swizzle the private implementation classes that may override
             * the base NSURLSession method. On iOS 10.3, __NSCFURLSession and
             * __NSURLSessionLocal are the real session classes. If they have their
             * own dataTaskWithRequest:completionHandler:, our base class swizzle
             * won't catch calls to them. */
            const char *subclassNames[] = {
                "__NSCFURLSession", "__NSURLSessionLocal",
                "__NSCFLocalSessionTask", NULL
            };
            for (int si = 0; subclassNames[si]; si++) {
                Class subCls = objc_getClass(subclassNames[si]);
                if (!subCls) continue;
                Method subMethod = class_getInstanceMethod(subCls, dtSel);
                if (!subMethod) continue;
                /* Only swizzle if this class has its OWN implementation (not inherited) */
                IMP subIMP = method_getImplementation(subMethod);
                IMP baseIMP = method_getImplementation(class_getInstanceMethod(sessionClass, dtSel));
                if (subIMP != baseIMP) {
                    /* This class overrides the method — swizzle it too */
                    IMP subDtIMP = imp_implementationWithBlock(dtBlock);
                    method_setImplementation(subMethod, subDtIMP);
                    bridge_log("Swizzled %s.dataTaskWithRequest:completionHandler: (override)",
                               subclassNames[si]);
                }
            }
        }
    }
}

/* ================================================================
 * Frame Capture System
 *
 * Renders the simulated app's root window into a shared memory-mapped
 * framebuffer at ~30fps. The ARM64 host app mmaps the same file to
 * display frames in real-time.
 *
 * Architecture:
 *   Bridge (x86_64):  renderInContext → mmap'd file → increment counter
 *   Host (ARM64):     poll counter → read pixels → CGImage → display
 * ================================================================ */

typedef struct { double x, y, w, h; } _RSBridgeCGRect;

/* Framebuffer state */
static void *_fb_mmap = NULL;    /* Will be set to MAP_FAILED sentinel or valid ptr */
static size_t _fb_size = 0;

/* ================================================================
 * Window stack — tracks all visible UIWindows for proper z-ordering.
 *
 * _bridge_key_window:  the window that receives keyboard/focus events
 * _bridge_windows:     array of all tracked windows (ordered by windowLevel)
 *
 * This replaces the single _bridge_root_window pattern for:
 *   - UIAlertController (presented in its own window)
 *   - Keyboard window (UIRemoteKeyboardWindow / UITextEffectsWindow)
 *   - UIActionSheet
 *   - Any secondary UIWindow created by the app
 * ================================================================ */
static id _bridge_key_window = nil;
#define BRIDGE_MAX_WINDOWS 16
static id _bridge_windows[BRIDGE_MAX_WINDOWS];
static int _bridge_window_count = 0;

/* Add a window to the tracked stack. Maintains sort by windowLevel. */
static void _bridge_track_window(id window) {
    if (!window) return;
    /* Check if already tracked */
    for (int i = 0; i < _bridge_window_count; i++) {
        if (_bridge_windows[i] == window) return;
    }
    if (_bridge_window_count >= BRIDGE_MAX_WINDOWS) {
        bridge_log("  WARN: Window stack full (%d), cannot track %p",
                   BRIDGE_MAX_WINDOWS, (void *)window);
        return;
    }
    ((id(*)(id, SEL))objc_msgSend)(window, sel_registerName("retain"));
    _bridge_windows[_bridge_window_count++] = window;

    /* Sort by windowLevel (insertion sort — small array) */
    for (int i = 1; i < _bridge_window_count; i++) {
        id w = _bridge_windows[i];
        double level_i = ((double(*)(id, SEL))objc_msgSend)(w, sel_registerName("windowLevel"));
        int j = i - 1;
        while (j >= 0) {
            double level_j = ((double(*)(id, SEL))objc_msgSend)(
                _bridge_windows[j], sel_registerName("windowLevel"));
            if (level_j <= level_i) break;
            _bridge_windows[j + 1] = _bridge_windows[j];
            j--;
        }
        _bridge_windows[j + 1] = w;
    }
}

/* Remove a window from the tracked stack. */
static void _bridge_untrack_window(id window) {
    if (!window) return;
    for (int i = 0; i < _bridge_window_count; i++) {
        if (_bridge_windows[i] == window) {
            ((void(*)(id, SEL))objc_msgSend)(window, sel_registerName("release"));
            for (int j = i; j < _bridge_window_count - 1; j++) {
                _bridge_windows[j] = _bridge_windows[j + 1];
            }
            _bridge_window_count--;
            _bridge_windows[_bridge_window_count] = nil;
            break;
        }
    }
    /* If we removed the key window, promote the highest-level remaining window */
    if (_bridge_key_window == window) {
        _bridge_key_window = (_bridge_window_count > 0)
            ? _bridge_windows[_bridge_window_count - 1] : nil;
    }
}

/* Double-buffer: render to this local buffer, then memcpy to shared framebuffer.
 * This prevents the host from seeing transient states (CGBitmapContextCreate
 * clears to white before renderInContext: draws, which causes flashing). */
static void *_render_buffer = NULL;
static size_t _render_buffer_size = 0;

/* CoreGraphics function pointers (resolved via dlsym) */
static void *(*_cg_CreateColorSpace)(void);
static void *(*_cg_CreateBitmap)(void *, size_t, size_t, size_t, size_t, void *, uint32_t);
static void  (*_cg_ScaleCTM)(void *, double, double);
static void  (*_cg_TranslateCTM)(void *, double, double);
static void  (*_cg_Release)(void *);
static void  (*_cg_ReleaseCS)(void *);

static void resolve_cg_functions(void) {
    _cg_CreateColorSpace = dlsym(RTLD_DEFAULT, "CGColorSpaceCreateDeviceRGB");
    _cg_CreateBitmap     = dlsym(RTLD_DEFAULT, "CGBitmapContextCreate");
    _cg_ScaleCTM         = dlsym(RTLD_DEFAULT, "CGContextScaleCTM");
    _cg_TranslateCTM     = dlsym(RTLD_DEFAULT, "CGContextTranslateCTM");
    _cg_Release          = dlsym(RTLD_DEFAULT, "CGContextRelease");
    _cg_ReleaseCS        = dlsym(RTLD_DEFAULT, "CGColorSpaceRelease");
}

static int setup_shared_framebuffer(void) {
    int px_w = (int)(kScreenWidth * kScreenScaleX);
    int px_h = (int)(kScreenHeight * kScreenScaleY);
    _fb_size = ROSETTASIM_FB_TOTAL_SIZE(px_w, px_h);

    const char *path = getenv("ROSETTASIM_FB_PATH");
    if (!path) path = ROSETTASIM_FB_PATH;

    int fd = -1;

    {
        /* Always create our own framebuffer for CPU rendering output.
         * Even with CARenderServer connected, we use CPU rendering (renderInContext)
         * for the display framebuffer because the app's layer tree isn't directly
         * committed to CARenderServer's display surface.
         * Note: PurpleFBServer also writes to this path from backboardd.
         * We truncate and take ownership here — our CPU rendering includes
         * the full view hierarchy which is more complete. */
        fd = open(path, O_RDWR | O_CREAT | O_TRUNC, 0644);
        if (fd < 0) {
            bridge_log("ERROR: Could not create framebuffer file: %s", path);
            return -1;
        }

        if (ftruncate(fd, _fb_size) < 0) {
            bridge_log("ERROR: Could not size framebuffer to %zu bytes", _fb_size);
            close(fd);
            return -1;
        }
    }

    _fb_mmap = mmap(NULL, _fb_size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);

    if (_fb_mmap == MAP_FAILED) {
        bridge_log("ERROR: mmap failed for framebuffer");
        _fb_mmap = NULL;
        return -1;
    }

    {
        /* Initialize header */
        RosettaSimFramebufferHeader *hdr = (RosettaSimFramebufferHeader *)_fb_mmap;
        memset(hdr, 0, ROSETTASIM_FB_HEADER_SIZE);
        hdr->magic         = ROSETTASIM_FB_MAGIC;
        hdr->version       = ROSETTASIM_FB_VERSION;
        hdr->width         = px_w;
        hdr->height        = px_h;
        hdr->stride        = px_w * 4;
        hdr->format        = ROSETTASIM_FB_FORMAT_BGRA;
        hdr->frame_counter = 0;
        hdr->fps_target    = 30;
        hdr->flags         = ROSETTASIM_FB_FLAG_APP_RUNNING;

        /* Initialize input region */
        RosettaSimInputRegion *inp = (RosettaSimInputRegion *)((uint8_t *)_fb_mmap + ROSETTASIM_FB_HEADER_SIZE);
        memset(inp, 0, ROSETTASIM_FB_INPUT_SIZE);
    }

    bridge_log("Shared framebuffer: %dx%d (%zu bytes) at %s [CPU+%s]",
               px_w, px_h, _fb_size, path,
               g_ca_server_connected ? "CARenderServer" : "standalone");
    return 0;
}

/* Recursively force layers with custom drawing to display their content.
 *
 * Without CARenderServer, the normal display cycle never runs. We walk the
 * layer tree and force layers to populate backing stores.
 *
 * Checks multiple drawing methods:
 *   - drawRect:           (UILabel, UIImageView, custom views)
 *   - drawLayer:inContext: (UIPageControl, UIActivityIndicatorView, UIProgressView)
 *   - displayLayer:       (some CALayer-backed views)
 *   - Private UIKit views  (_UIBarBackground, _UINavigationBarBackground, etc.)
 *
 * Plain UIView layers that only use backgroundColor are SKIPPED — calling
 * displayIfNeeded on them creates empty backing stores that cover the
 * backgroundColor during renderInContext:. */
static void _force_display_recursive(id layer, int depth) {
    if (!layer || depth > 25) return;

    id delegate = ((id(*)(id, SEL))objc_msgSend)(layer, sel_registerName("delegate"));
    if (delegate) {
        Class cls = object_getClass(delegate);
        Class uiViewBase = objc_getClass("UIView");
        int hasCustomDrawing = 0;

        /* 1. drawRect: override */
        SEL drawRectSel = sel_registerName("drawRect:");
        IMP drawRectIMP = class_getMethodImplementation(cls, drawRectSel);
        IMP baseDrawRectIMP = class_getMethodImplementation(uiViewBase, drawRectSel);
        if (drawRectIMP != baseDrawRectIMP) hasCustomDrawing = 1;

        /* 2. drawLayer:inContext: override */
        if (!hasCustomDrawing) {
            SEL drawLayerSel = sel_registerName("drawLayer:inContext:");
            IMP drawLayerIMP = class_getMethodImplementation(cls, drawLayerSel);
            IMP baseDrawLayerIMP = class_getMethodImplementation(uiViewBase, drawLayerSel);
            if (drawLayerIMP != baseDrawLayerIMP) hasCustomDrawing = 1;
        }

        /* 3. displayLayer: override */
        if (!hasCustomDrawing) {
            SEL displayLayerSel = sel_registerName("displayLayer:");
            if (class_respondsToSelector(cls, displayLayerSel)) {
                IMP displayLayerIMP = class_getMethodImplementation(cls, displayLayerSel);
                IMP baseDisplayLayerIMP = class_getMethodImplementation(uiViewBase, displayLayerSel);
                if (displayLayerIMP != baseDisplayLayerIMP) hasCustomDrawing = 1;
            }
        }

        /* 4. UISegmentedControl and views using tintColor-based rendering.
         * UISegmentedControl's selected segment appearance is applied via
         * template image colorization, which normally happens through
         * CARenderServer's compositing pipeline. Without CARenderServer,
         * the colorization doesn't happen automatically. Force these views
         * to regenerate their appearance by calling tintColorDidChange.
         *
         * Also handle UIImageView with renderingMode=AlwaysTemplate, which
         * uses tintColor for colorization. */
        {
            Class segClass = objc_getClass("UISegmentedControl");
            Class imgViewClass = objc_getClass("UIImageView");
            int isTintDependent = 0;
            Class c = cls;
            while (c) {
                if ((segClass && c == segClass) ||
                    (imgViewClass && c == imgViewClass)) {
                    isTintDependent = 1;
                    break;
                }
                c = class_getSuperclass(c);
            }
            if (isTintDependent) {
                hasCustomDrawing = 1;
                /* Trigger tintColor re-application which regenerates
                 * template images and selection highlights */
                SEL tintDidChangeSel = sel_registerName("tintColorDidChange");
                if (class_respondsToSelector(cls, tintDidChangeSel)) {
                    @try {
                        ((void(*)(id, SEL))objc_msgSend)(delegate, tintDidChangeSel);
                    } @catch (id e) { /* ignore */ }
                }
            }
        }

        if (hasCustomDrawing) {
            /* Call setNeedsDisplay if:
             *   - Layer has no content (nil backing store needs population)
             *   - OR _force_full_refresh is active (content is stale after
             *     user interaction — text input, button state change, etc.)
             *
             * Without _force_full_refresh, layers with existing content are
             * skipped to avoid flashing. With it, we accept a brief flash
             * to ensure stale content (e.g. placeholder text after typing)
             * is repainted with current state. */
            id contents = ((id(*)(id, SEL))objc_msgSend)(layer, sel_registerName("contents"));
            if (!contents || _force_full_refresh) {
                ((void(*)(id, SEL))objc_msgSend)(layer, sel_registerName("setNeedsDisplay"));
            }
            ((void(*)(id, SEL))objc_msgSend)(layer, sel_registerName("displayIfNeeded"));
        }
        /* No custom drawing — skip to preserve backgroundColor rendering */
    } else {
        /* Standalone CALayer — safe to force display */
        ((void(*)(id, SEL))objc_msgSend)(layer, sel_registerName("setNeedsDisplay"));
        ((void(*)(id, SEL))objc_msgSend)(layer, sel_registerName("displayIfNeeded"));
    }

    id sublayers = ((id(*)(id, SEL))objc_msgSend)(layer, sel_registerName("sublayers"));
    if (sublayers) {
        long count = ((long(*)(id, SEL))objc_msgSend)(sublayers, sel_registerName("count"));
        for (long i = 0; i < count; i++) {
            id sl = ((id(*)(id, SEL, long))objc_msgSend)(
                sublayers, sel_registerName("objectAtIndex:"), i);
            _force_display_recursive(sl, depth + 1);
        }
    }
}

/* ================================================================
 * SIGSEGV/SIGBUS crash guard for sendEvent: delivery
 *
 * UIKit's _sendTouchesForEvent: may crash if internal dictionaries
 * are still not fully populated despite _addTouch:forDelayedDelivery:.
 * We use sigsetjmp/siglongjmp to recover from SIGSEGV/SIGBUS and
 * fall through to the direct delivery path.
 * ================================================================ */

static volatile sig_atomic_t _sendEvent_guard_active = 0;
static sigjmp_buf _sendEvent_recovery;

static struct sigaction _prev_sigsegv_action;
static struct sigaction _prev_sigbus_action;
static volatile sig_atomic_t _sendEvent_handlers_installed = 0;

/* Store the last crash address for diagnostics */
static volatile void *_last_crash_addr = NULL;
static volatile void *_last_crash_pc = NULL;

static void _sendEvent_crash_handler_siginfo(int sig, siginfo_t *info, void *ctx) {
    if (info) {
        _last_crash_addr = info->si_addr;
        /* Extract PC from ucontext if available */
#if defined(__x86_64__)
        if (ctx) {
            ucontext_t *uc = (ucontext_t *)ctx;
            _last_crash_pc = (void *)uc->uc_mcontext->__ss.__rip;
        }
#endif
    }
    if (_sendEvent_guard_active) {
        _sendEvent_guard_active = 0;
        siglongjmp(_sendEvent_recovery, sig);
        /* not reached */
    }
    /* Not our crash — invoke previous handler */
    struct sigaction *prev = (sig == SIGSEGV) ? &_prev_sigsegv_action : &_prev_sigbus_action;
    if (prev->sa_flags & SA_SIGINFO && prev->sa_sigaction) {
        prev->sa_sigaction(sig, info, ctx);
    } else if (prev->sa_handler != SIG_DFL && prev->sa_handler != SIG_IGN) {
        prev->sa_handler(sig);
    } else {
        signal(sig, SIG_DFL);
        raise(sig);
    }
}

/* ================================================================
 * Touch injection system
 *
 * Reads touch events from the input region (written by host app)
 * and delivers them through UIKit's event pipeline:
 *
 *   1. Get the singleton UITouchesEvent from [UIApplication _touchesEvent]
 *   2. Call _clearTouches to reset previous state
 *   3. Call _addTouch:forDelayedDelivery:NO to populate internal dicts
 *   4. Send via [UIApplication sendEvent:] so UIControl target-action
 *      handlers, gesture recognizers, and the responder chain all work.
 *
 * Falls back to direct touchesBegan:/touchesEnded: delivery for views
 * with custom touch methods (e.g. Phase 6 TapView) when sendEvent:
 * delivery fails or crashes.
 * ================================================================ */

typedef struct { double x, y; } _RSBridgeCGPoint;

/* Persistent UITouch for the current finger (reused across began/moved/ended) */
static id _bridge_current_touch = nil;
static id _bridge_current_event = nil;
static id _bridge_touch_target_view = nil;

/* Tracks whether _addTouch:forDelayedDelivery: has been observed to crash.
 * Reset after pre-warm so real touches get a fresh chance. */
static int _addTouch_known_broken = 0;

/* Tracks whether sendEvent: has been observed to crash with real touches.
 * After N consecutive crashes, skip sendEvent entirely and go straight
 * to direct delivery (avoids SIGSEGV overhead on every touch). */
static int _sendEvent_crash_count = 0;
#define SENDEVENT_MAX_CRASHES 3  /* Skip after this many crashes */

/* Hit testing — delegates to UIKit's own hitTest:withEvent: which respects:
 *   - Custom hitTest:withEvent: overrides (many UIKit views expand/contract hit areas)
 *   - alpha < 0.01 check (UIKit skips transparent views)
 *   - userInteractionEnabled and hidden checks
 *   - clipsToBounds
 *   - Proper coordinate conversion via the view's transform
 *
 * Falls back to manual recursive walk only if hitTest: crashes
 * (e.g. from CGRect struct return issues under Rosetta 2). */
static id _hitTestView(id view, _RSBridgeCGPoint windowPt) {
    if (!view) return nil;

    /* Try UIKit's own hitTest:withEvent: first — this is the correct approach
     * and handles all edge cases including custom overrides. */
    SEL hitTestSel = sel_registerName("hitTest:withEvent:");
    if (class_respondsToSelector(object_getClass(view), hitTestSel)) {
        @try {
            typedef id (*hitTest_fn)(id, SEL, _RSBridgeCGPoint, id);
            id result = ((hitTest_fn)objc_msgSend)(view, hitTestSel, windowPt, nil);
            if (result) return result;
            return nil; /* Point is outside the view hierarchy */
        } @catch (id e) {
            /* hitTest: threw — fall through to manual approach */
            bridge_log("  hitTest:withEvent: threw exception — using manual fallback");
        }
    }

    /* Manual fallback — simplified recursive walk for when hitTest: fails */
    SEL convertSel = sel_registerName("convertPoint:fromView:");
    SEL pointInsideSel = sel_registerName("pointInside:withEvent:");
    typedef _RSBridgeCGPoint (*convertPt_fn)(id, SEL, _RSBridgeCGPoint, id);
    typedef bool (*pointInside_fn)(id, SEL, _RSBridgeCGPoint, id);

    _RSBridgeCGPoint localPt = ((convertPt_fn)objc_msgSend)(
        view, convertSel, windowPt, nil);
    bool inside = ((pointInside_fn)objc_msgSend)(view, pointInsideSel, localPt, nil);
    if (!inside) return nil;

    bool enabled = ((bool(*)(id, SEL))objc_msgSend)(
        view, sel_registerName("isUserInteractionEnabled"));
    if (!enabled) return nil;

    bool hidden = ((bool(*)(id, SEL))objc_msgSend)(
        view, sel_registerName("isHidden"));
    if (hidden) return nil;

    /* Check alpha — UIKit skips views with alpha < 0.01 */
    double alpha = ((double(*)(id, SEL))objc_msgSend)(
        view, sel_registerName("alpha"));
    if (alpha < 0.01) return nil;

    id subviews = ((id(*)(id, SEL))objc_msgSend)(view, sel_registerName("subviews"));
    if (subviews) {
        long count = ((long(*)(id, SEL))objc_msgSend)(subviews, sel_registerName("count"));
        for (long i = count - 1; i >= 0; i--) {
            id sv = ((id(*)(id, SEL, long))objc_msgSend)(
                subviews, sel_registerName("objectAtIndex:"), i);
            id hit = _hitTestView(sv, windowPt);
            if (hit) return hit;
        }
    }

    return view;
}

/* Process a single touch event — called from check_and_inject_touch for each
 * event in the ring buffer. */
static void _inject_single_touch(uint32_t phase, double tx, double ty);

static void check_and_inject_touch(void) {
    if (!_fb_mmap || !_bridge_root_window) return;

    /* Read input region */
    RosettaSimInputRegion *inp = (RosettaSimInputRegion *)((uint8_t *)_fb_mmap + ROSETTASIM_FB_HEADER_SIZE);

    /* Read the ring buffer write index */
    static uint64_t last_read_index = 0;
    uint64_t write_index = inp->touch_write_index;

    if (write_index == last_read_index) {
        return; /* No new events */
    }

    /* Memory barrier: ensure we see events written before the index */
    __sync_synchronize();

    /* Process all pending events in the ring buffer */
    uint64_t events_to_process = write_index - last_read_index;
    if (events_to_process > ROSETTASIM_TOUCH_RING_SIZE) {
        /* Ring buffer overflowed — skip to most recent events */
        bridge_log("Touch ring overflow: missed %llu events",
                   events_to_process - ROSETTASIM_TOUCH_RING_SIZE);
        last_read_index = write_index - ROSETTASIM_TOUCH_RING_SIZE;
        events_to_process = ROSETTASIM_TOUCH_RING_SIZE;
    }

    for (uint64_t i = last_read_index; i < write_index; i++) {
        int slot = (int)(i % ROSETTASIM_TOUCH_RING_SIZE);
        RosettaSimTouchEvent *ev = &inp->touch_ring[slot];

        uint32_t phase = ev->touch_phase;
        if (phase == ROSETTASIM_TOUCH_NONE) continue;

        double tx = (double)ev->touch_x;
        double ty = (double)ev->touch_y;

        /* NOTE: Do NOT wrap _inject_single_touch in @autoreleasepool here.
         * _inject_single_touch uses siglongjmp for crash recovery, and jumping
         * out of @autoreleasepool corrupts the ARC pool stack, causing a fatal
         * crash in _wrapRunLoopWithAutoreleasePoolHandler on the next run loop
         * iteration. The sendEvent: call inside _inject_single_touch has its
         * own @autoreleasepool that is only entered on the non-crash path. */
        _inject_single_touch(phase, tx, ty);
    }

    last_read_index = write_index;
}

static void _inject_single_touch(uint32_t phase, double tx, double ty) {

    static uint64_t _touch_seq = 0;
    _touch_seq++;
    bridge_log("Touch event #%llu: phase=%u x=%.1f y=%.1f",
               _touch_seq, phase, tx, ty);

    /* ---- Hit test on BEGAN, reuse target for MOVED/ENDED ---- */
    if (phase == ROSETTASIM_TOUCH_BEGAN) {
        _RSBridgeCGPoint windowPt = { tx, ty };
        _bridge_touch_target_view = _hitTestView(_bridge_root_window, windowPt);
        if (!_bridge_touch_target_view)
            _bridge_touch_target_view = _bridge_root_window;
    }
    id targetView = _bridge_touch_target_view;
    if (!targetView) targetView = _bridge_root_window;

    const char *phaseName = "";
    SEL touchSel = NULL;
    long uiTouchPhase = 0;
    if (phase == ROSETTASIM_TOUCH_BEGAN) {
        touchSel = sel_registerName("touchesBegan:withEvent:");
        phaseName = "BEGAN";
        uiTouchPhase = 0; /* UITouchPhaseBegan */
    } else if (phase == ROSETTASIM_TOUCH_MOVED) {
        touchSel = sel_registerName("touchesMoved:withEvent:");
        phaseName = "MOVED";
        uiTouchPhase = 1; /* UITouchPhaseMoved */
    } else if (phase == ROSETTASIM_TOUCH_ENDED) {
        touchSel = sel_registerName("touchesEnded:withEvent:");
        phaseName = "ENDED";
        uiTouchPhase = 3; /* UITouchPhaseEnded */
    } else {
        return;
    }

    bridge_log("Touch %s at (%.0f, %.0f) → %s %p",
               phaseName, tx, ty,
               class_getName(object_getClass(targetView)),
               (void *)targetView);

    /* Schedule force-display after touch to capture UI changes */
    _mark_display_dirty();

    /* ---- Approach 1: UITouchesEvent-based delivery via [UIApplication sendEvent:] ---- */
    Class appClass = objc_getClass("UIApplication");
    id app = appClass ? ((id(*)(id, SEL))objc_msgSend)(
        (id)appClass, sel_registerName("sharedApplication")) : nil;

    Class touchClass = objc_getClass("UITouch");
    int sendEvent_succeeded = 0;
    int gesture_delivery_succeeded = 0;

    if (app && touchClass) {
        /* Create UITouch on BEGAN only (Fix #3: drop orphan MOVED/ENDED) */
        if (phase == ROSETTASIM_TOUCH_BEGAN) {
            /* Release previous touch if any */
            if (_bridge_current_touch) {
                ((void(*)(id, SEL))objc_msgSend)(_bridge_current_touch, sel_registerName("release"));
                _bridge_current_touch = nil;
            }
            /* Keep _bridge_current_event for reuse — _clearTouches resets it (Fix #5) */

            /* Allocate UITouch — alloc+init returns +1, no extra retain needed */
            _bridge_current_touch = ((id(*)(id, SEL))objc_msgSend)(
                ((id(*)(id, SEL))objc_msgSend)((id)touchClass, sel_registerName("alloc")),
                sel_registerName("init"));
        } else if (!_bridge_current_touch) {
            /* MOVED or ENDED without a preceding BEGAN — drop this orphan event */
            bridge_log("  Dropping orphan %s event (no active touch)", phaseName);
            return;
        }

        if (_bridge_current_touch) {
            /* Configure touch properties */
            _RSBridgeCGPoint pt = { tx, ty };

            /* Set phase */
            @try {
                ((void(*)(id, SEL, long))objc_msgSend)(
                    _bridge_current_touch,
                    sel_registerName("setPhase:"), uiTouchPhase);
            } @catch (id e) { /* fall through */ }

            /* Set location via _setLocationInWindow:resetPrevious: (private) */
            SEL setLocSel = sel_registerName("_setLocationInWindow:resetPrevious:");
            if (class_respondsToSelector(object_getClass(_bridge_current_touch), setLocSel)) {
                typedef void (*setLoc_fn)(id, SEL, _RSBridgeCGPoint, bool);
                ((setLoc_fn)objc_msgSend)(_bridge_current_touch, setLocSel, pt,
                    (phase == ROSETTASIM_TOUCH_BEGAN) ? true : false);
            }

            /* Set window */
            @try {
                ((void(*)(id, SEL, id))objc_msgSend)(
                    _bridge_current_touch,
                    sel_registerName("setWindow:"), _bridge_root_window);
            } @catch (id e) { /* fall through */ }

            /* Set view */
            @try {
                ((void(*)(id, SEL, id))objc_msgSend)(
                    _bridge_current_touch,
                    sel_registerName("setView:"), targetView);
            } @catch (id e) { /* fall through */ }

            /* Set timestamp — use [[NSProcessInfo processInfo] systemUptime] */
            @try {
                Class piClass = objc_getClass("NSProcessInfo");
                id pi = piClass ? ((id(*)(id, SEL))objc_msgSend)(
                    (id)piClass, sel_registerName("processInfo")) : nil;
                double ts = 0;
                if (pi) {
                    ts = ((double(*)(id, SEL))objc_msgSend)(
                        pi, sel_registerName("systemUptime"));
                }
                if (ts <= 0) ts = (double)mach_absolute_time() / 1e9;
                ((void(*)(id, SEL, double))objc_msgSend)(
                    _bridge_current_touch,
                    sel_registerName("setTimestamp:"), ts);
            } @catch (id e) { /* fall through */ }

            /* Set tapCount (required for UIControl tracking) */
            @try {
                ((void(*)(id, SEL, long))objc_msgSend)(
                    _bridge_current_touch,
                    sel_registerName("setTapCount:"), 1);
            } @catch (id e) { /* fall through */ }

            /* Set isTap for single clicks */
            @try {
                ((void(*)(id, SEL, bool))objc_msgSend)(
                    _bridge_current_touch,
                    sel_registerName("setIsTap:"), true);
            } @catch (id e) { /* fall through */ }

            /* Create and attach an IOHIDEvent to the UITouch.
             *
             * UIKit's native sendEvent: pipeline calls IOHIDEventConformsTo()
             * on the touch's _hidEvent ivar during gesture recognizer processing.
             * Without a valid IOHIDEvent, this dereferences nil+0x20 → SIGSEGV.
             *
             * IMPORTANT: Create the IOHIDEvent ONCE on BEGAN and REUSE it for
             * MOVED/ENDED. Creating a new IOHIDEvent per phase and overwriting
             * the UIEvent._hidEvent causes dangling references — UIKit's gesture
             * processing caches internal pointers to the IOHIDEvent from BEGAN,
             * and overwriting it with a new object makes those pointers garbage.
             * Crash: objc_msgSend + 5 with corrupted address.
             */
            {
                static void *_bridge_current_hidEvent = NULL;

                /* Resolve IOHIDEvent functions via dlsym (private API) */
                typedef void *(*IOHIDEventCreateDigitizerFingerEventFn)(
                    void *allocator, uint64_t timeStamp,
                    uint32_t index, uint32_t identity,
                    uint32_t eventMask, double x, double y, double z,
                    double tipPressure, double twist,
                    uint8_t range, uint8_t touch, uint32_t options);

                static IOHIDEventCreateDigitizerFingerEventFn _createFingerEvent = NULL;
                static int _hid_resolved = 0;
                if (!_hid_resolved) {
                    _createFingerEvent = dlsym(RTLD_DEFAULT, "IOHIDEventCreateDigitizerFingerEvent");
                    _hid_resolved = 1;
                    if (_createFingerEvent) {
                        bridge_log("  IOHIDEventCreateDigitizerFingerEvent resolved");
                    } else {
                        bridge_log("  WARNING: IOHIDEventCreateDigitizerFingerEvent not found");
                    }
                }

                if (_createFingerEvent) {
                    if (uiTouchPhase == 0) {
                        /* BEGAN: create a new IOHIDEvent for this touch sequence.
                         * Release the old one if it exists. */
                        if (_bridge_current_hidEvent) {
                            CFRelease(_bridge_current_hidEvent);
                            _bridge_current_hidEvent = NULL;
                        }

                        uint64_t ts = mach_absolute_time();
                        _bridge_current_hidEvent = _createFingerEvent(
                            NULL, ts,
                            0,              /* index (finger 0) */
                            2,              /* identity (arbitrary nonzero) */
                            0x01 | 0x02 | 0x04, /* range + touch + position */
                            tx / kScreenWidth,
                            ty / kScreenHeight,
                            0.0,            /* z */
                            1.0,            /* tipPressure */
                            0.0,            /* twist */
                            1,              /* range = in range */
                            1,              /* touch = touching */
                            0);             /* options */

                        if (_bridge_current_hidEvent) {
                            bridge_log("  Created IOHIDEvent %p for touch sequence",
                                       _bridge_current_hidEvent);
                        }
                    }
                    /* MOVED and ENDED: reuse the same IOHIDEvent from BEGAN.
                     * UIKit's gesture processing holds cached references to it. */

                    if (_bridge_current_hidEvent) {
                        /* Set on UITouch */
                        SEL setHidSel = sel_registerName("_setHidEvent:");
                        if (class_respondsToSelector(object_getClass(_bridge_current_touch), setHidSel)) {
                            ((void(*)(id, SEL, void *))objc_msgSend)(
                                _bridge_current_touch, setHidSel, _bridge_current_hidEvent);
                        } else {
                            Ivar hidIvar = class_getInstanceVariable(
                                object_getClass(_bridge_current_touch), "_hidEvent");
                            if (hidIvar) {
                                *(void **)((uint8_t *)_bridge_current_touch +
                                           ivar_getOffset(hidIvar)) = _bridge_current_hidEvent;
                            }
                        }
                    }

                    /* Release on ENDED */
                    if (uiTouchPhase == 3 && _bridge_current_hidEvent) {
                        /* Don't release yet — UIKit may still reference it during
                         * sendEvent processing. Release on next BEGAN instead. */
                    }
                }
            }

            /* ---- UITouchesEvent delivery via [UIApplication sendEvent:] ----
             *
             * With UIEventDispatcher initialized and IOHIDEvent attached to the
             * UITouch, UIKit's native event pipeline processes the touch through
             * gesture recognizers (UIButton tap, UITextField tap, UIScrollView
             * pan, etc.).
             */
            SEL clearTouchesSel = sel_registerName("_clearTouches");
            SEL addTouchSel = sel_registerName("_addTouch:forDelayedDelivery:");
            SEL sendEventSel = sel_registerName("sendEvent:");
            int addTouch_succeeded = 0;

            /* Step 1: Try the real _touchesEvent singleton from UIEventEnvironment */
            id touchesEvent = nil;
            SEL touchesEventSel = sel_registerName("_touchesEvent");
            if (class_respondsToSelector(object_getClass(app), touchesEventSel)) {
                @try {
                    touchesEvent = ((id(*)(id, SEL))objc_msgSend)(app, touchesEventSel);
                } @catch (id e) { touchesEvent = nil; }
            }
            int using_real_singleton = (touchesEvent != nil);
            if (touchesEvent) {
                bridge_log("  Using real _touchesEvent singleton: %p", (void *)touchesEvent);
            }

            /* Step 2: Fall back to bridge-owned UITouchesEvent if singleton unavailable */
            if (!touchesEvent) {
                if (!_bridge_current_event) {
                    Class touchesEventClass = objc_getClass("UITouchesEvent");
                    if (touchesEventClass) {
                        SEL initSel = sel_registerName("_init");
                        @try {
                            _bridge_current_event = ((id(*)(id, SEL))objc_msgSend)(
                                ((id(*)(id, SEL))objc_msgSend)((id)touchesEventClass,
                                    sel_registerName("alloc")), initSel);
                            if (_bridge_current_event) {
                                ((id(*)(id, SEL))objc_msgSend)(_bridge_current_event,
                                    sel_registerName("retain"));
                                bridge_log("  Created bridge-owned UITouchesEvent: %p",
                                           (void *)_bridge_current_event);
                            }
                        } @catch (id e) { _bridge_current_event = nil; }
                    }
                }
                touchesEvent = _bridge_current_event;
            }

            if (touchesEvent) {
                /* Step 3: Clear previous touch data */
                @try {
                    ((void(*)(id, SEL))objc_msgSend)(touchesEvent, clearTouchesSel);
                } @catch (id e) { /* ignore */ }

                /* Step 4: Try _addTouch:forDelayedDelivery:NO
                 * This registers the touch with gesture recognizers via
                 * _addGestureRecognizersForView:toTouch:. With UIGestureEnvironment
                 * now properly initialized, this should work. */
                if (!_addTouch_known_broken) {
                    /* Install SIGSEGV/SIGBUS handlers */
                    if (!_sendEvent_handlers_installed) {
                        struct sigaction sa;
                        memset(&sa, 0, sizeof(sa));
                        sa.sa_sigaction = _sendEvent_crash_handler_siginfo;
                        sa.sa_flags = SA_SIGINFO;
                        sigemptyset(&sa.sa_mask);
                        sa.sa_flags = 0;
                        sigaction(SIGSEGV, &sa, &_prev_sigsegv_action);
                        sigaction(SIGBUS, &sa, &_prev_sigbus_action);
                        _sendEvent_handlers_installed = 1;
                    }

                    _sendEvent_guard_active = 1;
                    int addTouch_crash = sigsetjmp(_sendEvent_recovery, 1);
                    if (addTouch_crash == 0) {
                        @try {
                            typedef void (*addTouchFn)(id, SEL, id, bool);
                            ((addTouchFn)objc_msgSend)(touchesEvent, addTouchSel,
                                _bridge_current_touch, false);
                            addTouch_succeeded = 1;
                            bridge_log("  _addTouch:forDelayedDelivery:NO succeeded");
                        } @catch (id e) {
                            bridge_log("  _addTouch: threw exception");
                        }
                    } else {
                        bridge_log("  _addTouch: CRASHED (signal %d) — marking broken", addTouch_crash);
                        _addTouch_known_broken = 1;
                    }
                    _sendEvent_guard_active = 0;
                }

                /* Step 5: Fall back to ivar manipulation if _addTouch failed */
                if (!addTouch_succeeded) {
                    Class teClass = object_getClass(touchesEvent);
                    Ivar touchesIvar = class_getInstanceVariable(teClass, "_touches");
                    Ivar keyedIvar = class_getInstanceVariable(teClass, "_keyedTouches");
                    Ivar byWindowIvar = class_getInstanceVariable(teClass, "_keyedTouchesByWindow");
                    if (touchesIvar && keyedIvar && byWindowIvar) {
                        ptrdiff_t touchesOff = ivar_getOffset(touchesIvar);
                        ptrdiff_t keyedOff = ivar_getOffset(keyedIvar);
                        ptrdiff_t byWindowOff = ivar_getOffset(byWindowIvar);
                        id touchesSet = *(id *)((uint8_t *)touchesEvent + touchesOff);
                        CFMutableDictionaryRef keyedDict = *(CFMutableDictionaryRef *)((uint8_t *)touchesEvent + keyedOff);
                        CFMutableDictionaryRef byWindowDict = *(CFMutableDictionaryRef *)((uint8_t *)touchesEvent + byWindowOff);
                        if (touchesSet && keyedDict && byWindowDict) {
                            ((void(*)(id, SEL, id))objc_msgSend)(touchesSet,
                                sel_registerName("addObject:"), _bridge_current_touch);
                            if (targetView) {
                                const void *vk = (__bridge const void *)targetView;
                                id vs = (id)CFDictionaryGetValue(keyedDict, vk);
                                if (!vs) {
                                    vs = ((id(*)(id, SEL))objc_msgSend)(
                                        (id)objc_getClass("NSMutableSet"), sel_registerName("set"));
                                    CFDictionarySetValue(keyedDict, vk, (__bridge const void *)vs);
                                }
                                ((void(*)(id, SEL, id))objc_msgSend)(vs,
                                    sel_registerName("addObject:"), _bridge_current_touch);
                            }
                            if (_bridge_root_window) {
                                const void *wk = (__bridge const void *)_bridge_root_window;
                                id ws = (id)CFDictionaryGetValue(byWindowDict, wk);
                                if (!ws) {
                                    ws = ((id(*)(id, SEL))objc_msgSend)(
                                        (id)objc_getClass("NSMutableSet"), sel_registerName("set"));
                                    CFDictionarySetValue(byWindowDict, wk, (__bridge const void *)ws);
                                }
                                ((void(*)(id, SEL, id))objc_msgSend)(ws,
                                    sel_registerName("addObject:"), _bridge_current_touch);
                            }
                            bridge_log("  ivar fallback: populated dicts (no gesture recognizers)");
                        } else {
                            touchesEvent = nil;
                        }
                    } else {
                        touchesEvent = nil;
                    }
                }
            }

            /* Step 6: [UIApplication sendEvent:] with crash guard.
             * Skip entirely after SENDEVENT_MAX_CRASHES consecutive crashes
             * to avoid SIGSEGV overhead on every touch. */
            if (touchesEvent && _sendEvent_crash_count < SENDEVENT_MAX_CRASHES) {
                if (!using_real_singleton) _bridge_current_event = touchesEvent;

                if (!_sendEvent_handlers_installed) {
                    struct sigaction sa;
                    memset(&sa, 0, sizeof(sa));
                    sa.sa_sigaction = _sendEvent_crash_handler_siginfo;
                    sigemptyset(&sa.sa_mask);
                    sa.sa_flags = SA_SIGINFO;
                    sigaction(SIGSEGV, &sa, &_prev_sigsegv_action);
                    sigaction(SIGBUS, &sa, &_prev_sigbus_action);
                    _sendEvent_handlers_installed = 1;
                }

                /* Set IOHIDEvent on the UITouchesEvent (UIEvent._hidEvent) on BEGAN only.
                 * The same IOHIDEvent persists for MOVED/ENDED to avoid dangling
                 * references in UIKit's gesture processing cache. */
                if (uiTouchPhase == 0 /* BEGAN */) {
                    SEL setHidEventSel = sel_registerName("_setHIDEvent:");
                    if (class_respondsToSelector(object_getClass(touchesEvent), setHidEventSel)) {
                        /* Use the same IOHIDEvent from the current touch */
                        Ivar tHidIvar = class_getInstanceVariable(
                            object_getClass(_bridge_current_touch), "_hidEvent");
                        if (tHidIvar) {
                            void *hid = *(void **)((uint8_t *)_bridge_current_touch +
                                                    ivar_getOffset(tHidIvar));
                            if (hid) {
                                ((void(*)(id, SEL, void *))objc_msgSend)(
                                    touchesEvent, setHidEventSel, hid);
                            }
                        }
                    } else {
                        /* Direct ivar access on UIEvent */
                        Ivar eHidIvar = class_getInstanceVariable(
                            object_getClass(touchesEvent), "_hidEvent");
                        if (eHidIvar && _bridge_current_touch) {
                            Ivar tHidIvar = class_getInstanceVariable(
                                object_getClass(_bridge_current_touch), "_hidEvent");
                            if (tHidIvar) {
                                void *hid = *(void **)((uint8_t *)_bridge_current_touch +
                                                        ivar_getOffset(tHidIvar));
                                if (hid) {
                                    *(void **)((uint8_t *)touchesEvent +
                                               ivar_getOffset(eHidIvar)) = hid;
                                }
                            }
                        }
                    }
                }

                _sendEvent_guard_active = 1;
                int crash_sig = sigsetjmp(_sendEvent_recovery, 1);
                if (crash_sig == 0) {
                    /* IMPORTANT: Do NOT use @autoreleasepool here.
                     * If sendEvent: crashes, siglongjmp jumps OUT of the pool
                     * block, which corrupts the ARC autorelease pool stack.
                     * The next run loop iteration then crashes fatally in
                     * _wrapRunLoopWithAutoreleasePoolHandler.
                     *
                     * Any autorelease'd objects created during sendEvent: will
                     * be drained by the run loop's own autorelease pool at the
                     * end of the current iteration. */
                    bridge_log("  Delivering via [UIApplication sendEvent:]");
                    ((void(*)(id, SEL, id))objc_msgSend)(app, sendEventSel, touchesEvent);
                    _sendEvent_guard_active = 0;
                    sendEvent_succeeded = 1;
                    _sendEvent_crash_count = 0; /* Reset on success */
                    if (addTouch_succeeded) {
                        gesture_delivery_succeeded = 1;
                        bridge_log("  sendEvent: with gesture recognizers succeeded");
                    } else {
                        bridge_log("  sendEvent: succeeded (no gesture recognizers)");
                    }
                } else {
                    _sendEvent_guard_active = 0;
                    _sendEvent_crash_count++;
                    {
                        /* Use dladdr to resolve crash PC to a symbol */
                        typedef struct { const char *dli_fname; void *dli_fbase;
                                         const char *dli_sname; void *dli_saddr; } Dl_info_t;
                        Dl_info_t info;
                        memset(&info, 0, sizeof(info));
                        int (*dladdr_fn)(const void *, Dl_info_t *) = dlsym(RTLD_DEFAULT, "dladdr");
                        if (dladdr_fn && _last_crash_pc) {
                            dladdr_fn(_last_crash_pc, &info);
                        }
                        bridge_log("  sendEvent: CRASHED (signal %d, count %d/%d)\n"
                                   "    fault addr=%p, PC=%p\n"
                                   "    symbol: %s + %ld\n"
                                   "    library: %s",
                                   crash_sig, _sendEvent_crash_count, SENDEVENT_MAX_CRASHES,
                                   _last_crash_addr, _last_crash_pc,
                                   info.dli_sname ? info.dli_sname : "?",
                                   info.dli_saddr ? (long)((char *)_last_crash_pc - (char *)info.dli_saddr) : 0,
                                   info.dli_fname ? info.dli_fname : "?");
                    }
                    if (_sendEvent_crash_count >= SENDEVENT_MAX_CRASHES) {
                        bridge_log("  sendEvent: disabling after %d crashes", _sendEvent_crash_count);
                    }
                }
            } else if (!touchesEvent) {
                bridge_log("  No UITouchesEvent — direct delivery only");
            }
            /* else: sendEvent disabled after too many crashes — direct delivery only */
        }
    }

/* direct_delivery: */
    /* ---- Approach 2: Direct touch + UIControl tracking (fallback) ---- */
    /* Guard the direct delivery with SIGSEGV handler. UIKit internals called
     * from here (e.g., UITextField.becomeFirstResponder → UIKeyboardImpl) may
     * crash if keyboard infrastructure stubs are incomplete. */
    _sendEvent_guard_active = 1;
    int _direct_crash_sig = sigsetjmp(_sendEvent_recovery, 1);
    if (_direct_crash_sig != 0) {
        bridge_log("  Direct delivery CRASHED (signal %d) — continuing", _direct_crash_sig);
        _sendEvent_guard_active = 0;
        goto direct_delivery_done;
    }
    bridge_log("  Direct delivery to %s", class_getName(object_getClass(targetView)));

    /* Build touch set for delivery */
    id touchSetForDelivery;
    if (_bridge_current_touch) {
        touchSetForDelivery = ((id(*)(id, SEL, id))objc_msgSend)(
            (id)objc_getClass("NSSet"),
            sel_registerName("setWithObject:"),
            _bridge_current_touch);
    } else {
        touchSetForDelivery = ((id(*)(id, SEL))objc_msgSend)(
            (id)objc_getClass("NSSet"), sel_registerName("set"));
    }

    /* Walk up the responder chain to find the nearest UIControl ancestor
     * if the direct target doesn't handle the touch. This handles cases
     * where the hit test lands on a UILabel/UIImageView inside a UIButton. */
    Class uiControlClass = objc_getClass("UIControl");
    id controlTarget = nil;
    if (uiControlClass) {
        id walk = targetView;
        while (walk) {
            Class walkClass = object_getClass(walk);
            Class check = walkClass;
            while (check) {
                if (check == uiControlClass) { controlTarget = walk; break; }
                check = class_getSuperclass(check);
            }
            if (controlTarget) break;
            /* Walk up via superview */
            walk = ((id(*)(id, SEL))objc_msgSend)(walk, sel_registerName("superview"));
        }
    }

    if (controlTarget && _bridge_current_touch && !gesture_delivery_succeeded) {
        const char *ctrlName = class_getName(object_getClass(controlTarget));
        bridge_log("  UIControl found: %s %p", ctrlName, (void *)controlTarget);

        /* Check specific UIControl subclass types for specialized handling */
        Class uiTextFieldClass = objc_getClass("UITextField");
        Class uiButtonClass = objc_getClass("UIButton");
        Class uiSegmentedControlClass = objc_getClass("UISegmentedControl");

        int isTextField = 0, isButton = 0, isSegmented = 0;
        {
            Class c = object_getClass(controlTarget);
            while (c) {
                if (uiTextFieldClass && c == uiTextFieldClass) isTextField = 1;
                if (uiButtonClass && c == uiButtonClass) isButton = 1;
                if (uiSegmentedControlClass && c == uiSegmentedControlClass) isSegmented = 1;
                c = class_getSuperclass(c);
            }
        }

        if (isTextField) {
            /* UITextField: set as first responder on ENDED so keyboard
             * input (via mmap) routes to this field.
             *
             * Do NOT call UITextField's native becomeFirstResponder — it
             * triggers UITextInteractionAssistant → gesture recognizer
             * setup → fatal crash (backboardd-dependent state + nested
             * siglongjmp inside @try = corrupted ObjC exception state).
             *
             * Instead, directly register the text field as first responder
             * via the window's private API + UIResponder's base impl. */
            if (phase == ROSETTASIM_TOUCH_ENDED) {
                bridge_log("  UITextField tapped — setting as first responder + editing mode");

                /* Set _editing = YES on the text field so it accepts insertText:
                 * and displays typed text instead of placeholder. */
                @try {
                    /* Try setting editing via the _editing ivar directly */
                    Ivar editingIvar = class_getInstanceVariable(
                        objc_getClass("UITextField"), "_editing");
                    if (editingIvar) {
                        bool *editPtr = (bool *)((uint8_t *)controlTarget +
                                                  ivar_getOffset(editingIvar));
                        *editPtr = true;
                        bridge_log("  Set _editing = YES via ivar");
                    }
                } @catch (id e) { /* ignore */ }

                /* Also call _startEditing (internal method that switches from
                 * placeholder display to content display) */
                @try {
                    SEL startEditSel = sel_registerName("_startEditing");
                    if (class_respondsToSelector(object_getClass(controlTarget), startEditSel)) {
                        ((void(*)(id, SEL))objc_msgSend)(controlTarget, startEditSel);
                        bridge_log("  Called _startEditing");
                    }
                } @catch (id e) {
                    bridge_log("  _startEditing threw — continuing");
                }

                /* Set via window._setFirstResponder: (private API) */
                id targetWindow = _bridge_key_window ? _bridge_key_window : _bridge_root_window;
                if (targetWindow) {
                    SEL setFRSel = sel_registerName("_setFirstResponder:");
                    if (class_respondsToSelector(object_getClass(targetWindow), setFRSel)) {
                        @try {
                            ((void(*)(id, SEL, id))objc_msgSend)(
                                targetWindow, setFRSel, controlTarget);
                            bridge_log("  Set first responder via window._setFirstResponder:");
                        } @catch (id e) { /* ignore */ }
                    }
                }

                /* Call UIResponder's BASE becomeFirstResponder (not UITextField's
                 * override). UIResponder's impl calls [UIApplication _setFirstResponder:]
                 * without touching gesture recognizers. */
                Class uiResponderClass = objc_getClass("UIResponder");
                if (uiResponderClass) {
                    SEL bfrSel = sel_registerName("becomeFirstResponder");
                    Method respMethod = class_getInstanceMethod(uiResponderClass, bfrSel);
                    if (respMethod) {
                        IMP baseBFR = method_getImplementation(respMethod);
                        if (baseBFR) {
                            @try {
                                ((bool(*)(id, SEL))baseBFR)(controlTarget, bfrSel);
                                bridge_log("  Called UIResponder.becomeFirstResponder (base)");
                            } @catch (id e) {
                                bridge_log("  UIResponder.becomeFirstResponder threw");
                            }
                        }
                    }
                }

                /* Post UITextFieldTextDidBeginEditingNotification */
                @try {
                    Class nc = objc_getClass("NSNotificationCenter");
                    id ctr = nc ? ((id(*)(id, SEL))objc_msgSend)(
                        (id)nc, sel_registerName("defaultCenter")) : nil;
                    if (ctr) {
                        id nn = ((id(*)(id, SEL, const char *))objc_msgSend)(
                            (id)objc_getClass("NSString"),
                            sel_registerName("stringWithUTF8String:"),
                            "UITextFieldTextDidBeginEditingNotification");
                        ((void(*)(id, SEL, id, id, id))objc_msgSend)(
                            ctr, sel_registerName("postNotificationName:object:userInfo:"),
                            nn, controlTarget, nil);
                        bridge_log("  Posted UITextFieldTextDidBeginEditingNotification");
                    }
                } @catch (id e) { /* ignore */ }
            }
        } else if (isSegmented) {
            /* UISegmentedControl: needs special handling.
             * 1. Determine which segment was tapped via hit position
             * 2. Set selectedSegmentIndex directly
             * 3. Fire UIControlEventValueChanged (1 << 12 = 4096) */
            if (phase == ROSETTASIM_TOUCH_ENDED) {
                @try {
                    /* Get number of segments */
                    long numSegs = ((long(*)(id, SEL))objc_msgSend)(controlTarget,
                        sel_registerName("numberOfSegments"));
                    long currentSel = ((long(*)(id, SEL))objc_msgSend)(controlTarget,
                        sel_registerName("selectedSegmentIndex"));

                    /* Determine which segment was tapped based on X position.
                     * Get the control's frame width and divide by segment count. */
                    _RSBridgeCGPoint localPt = { tx, ty };
                    /* Convert touch point to control's local coordinates */
                    id ctrlView = controlTarget;
                    _RSBridgeCGPoint ctrlPt = localPt;
                    @try {
                        /* Use the raw X coordinate relative to the control */
                        typedef _RSBridgeCGPoint (*convertFn)(id, SEL, _RSBridgeCGPoint, id);
                        ctrlPt = ((convertFn)objc_msgSend)(ctrlView,
                            sel_registerName("convertPoint:fromView:"), localPt, nil);
                    } @catch (id ex) { /* use raw coords */ }

                    /* Determine which segment was tapped based on X position.
                     * Use layer.bounds.size to get the actual control width
                     * (avoids CGRect struct return issues by reading individual
                     * layer properties). */
                    long newSeg = currentSel;
                    if (numSegs > 0) {
                        double controlWidth = 335.0; /* fallback */
                        @try {
                            id ctrlLayer = ((id(*)(id, SEL))objc_msgSend)(
                                controlTarget, sel_registerName("layer"));
                            if (ctrlLayer) {
                                /* CALayer.bounds returns CGRect — avoid stret.
                                 * Use CALayer.frame which on iOS 10 x86_64 returns
                                 * via hidden register pair. Safer: get superlayer
                                 * and use convertRect. Simplest: count subviews
                                 * (UISegment objects) and use their positions. */
                                id segments = ((id(*)(id, SEL))objc_msgSend)(
                                    controlTarget, sel_registerName("subviews"));
                                if (segments) {
                                    long segCount = ((long(*)(id, SEL))objc_msgSend)(
                                        segments, sel_registerName("count"));
                                    if (segCount == numSegs && segCount > 0) {
                                        /* Use last segment's position to estimate total width */
                                        id lastSeg = ((id(*)(id, SEL, long))objc_msgSend)(
                                            segments, sel_registerName("objectAtIndex:"), segCount - 1);
                                        if (lastSeg) {
                                            id lastLayer = ((id(*)(id, SEL))objc_msgSend)(
                                                lastSeg, sel_registerName("layer"));
                                            if (lastLayer) {
                                                /* layer.position.x gives center of last segment */
                                                _RSBridgeCGPoint pos;
                                                @try {
                                                    typedef _RSBridgeCGPoint (*positionFn)(id, SEL);
                                                    pos = ((positionFn)objc_msgSend)(
                                                        lastLayer, sel_registerName("position"));
                                                    /* width ≈ position.x of last seg + half segment width */
                                                    double segW = pos.x / (segCount - 0.5);
                                                    controlWidth = segW * segCount;
                                                } @catch (id ex) { /* use fallback */ }
                                            }
                                        }
                                    }
                                }
                            }
                        } @catch (id e) { /* use fallback width */ }

                        double segWidth = controlWidth / numSegs;
                        newSeg = (long)(ctrlPt.x / segWidth);
                        if (newSeg < 0) newSeg = 0;
                        if (newSeg >= numSegs) newSeg = numSegs - 1;
                    }

                    if (newSeg != currentSel) {
                        ((void(*)(id, SEL, long))objc_msgSend)(controlTarget,
                            sel_registerName("setSelectedSegmentIndex:"), newSeg);
                        /* UIControlEventValueChanged = 1 << 12 = 4096 */
                        ((void(*)(id, SEL, unsigned long))objc_msgSend)(controlTarget,
                            sel_registerName("sendActionsForControlEvents:"), 4096);
                        bridge_log("  UISegmentedControl selectedIndex %ld → %ld + ValueChanged",
                                   currentSel, newSeg);
                    } else {
                        bridge_log("  UISegmentedControl tapped same segment %ld (no change)", currentSel);
                    }
                } @catch (id e) {
                    bridge_log("  UISegmentedControl handling failed");
                }
            }
        } else if (isButton) {
            /* UIButton: highlight + tracking API */
            if (phase == ROSETTASIM_TOUCH_BEGAN) {
                @try {
                    ((void(*)(id, SEL, bool))objc_msgSend)(controlTarget,
                        sel_registerName("setHighlighted:"), true);
                    typedef bool (*trackFn)(id, SEL, id, id);
                    ((trackFn)objc_msgSend)(controlTarget,
                        sel_registerName("beginTrackingWithTouch:withEvent:"),
                        _bridge_current_touch, nil);
                    bridge_log("  UIButton setHighlighted:YES + beginTracking");
                } @catch (id e) {
                    bridge_log("  UIButton beginTracking failed");
                }
            } else if (phase == ROSETTASIM_TOUCH_MOVED) {
                @try {
                    typedef bool (*trackFn)(id, SEL, id, id);
                    ((trackFn)objc_msgSend)(controlTarget,
                        sel_registerName("continueTrackingWithTouch:withEvent:"),
                        _bridge_current_touch, nil);
                } @catch (id e) { /* ignore */ }
            } else if (phase == ROSETTASIM_TOUCH_ENDED) {
                @try {
                    ((void(*)(id, SEL, id, id))objc_msgSend)(controlTarget,
                        sel_registerName("endTrackingWithTouch:withEvent:"),
                        _bridge_current_touch, nil);
                    /* UIControlEventTouchUpInside = 1 << 6 = 64 */
                    ((void(*)(id, SEL, unsigned long))objc_msgSend)(controlTarget,
                        sel_registerName("sendActionsForControlEvents:"), 64);
                    ((void(*)(id, SEL, bool))objc_msgSend)(controlTarget,
                        sel_registerName("setHighlighted:"), false);
                    bridge_log("  UIButton endTracking + sendActions + setHighlighted:NO");
                } @catch (id e) {
                    bridge_log("  UIButton endTracking failed");
                }
            }
        } else {
            /* Generic UIControl: standard tracking API */
            if (phase == ROSETTASIM_TOUCH_BEGAN) {
                @try {
                    typedef bool (*trackFn)(id, SEL, id, id);
                    ((trackFn)objc_msgSend)(controlTarget,
                        sel_registerName("beginTrackingWithTouch:withEvent:"),
                        _bridge_current_touch, nil);
                    bridge_log("  UIControl beginTracking");
                } @catch (id e) {
                    bridge_log("  UIControl beginTracking failed");
                }
            } else if (phase == ROSETTASIM_TOUCH_MOVED) {
                @try {
                    typedef bool (*trackFn)(id, SEL, id, id);
                    ((trackFn)objc_msgSend)(controlTarget,
                        sel_registerName("continueTrackingWithTouch:withEvent:"),
                        _bridge_current_touch, nil);
                } @catch (id e) { /* ignore */ }
            } else if (phase == ROSETTASIM_TOUCH_ENDED) {
                @try {
                    ((void(*)(id, SEL, id, id))objc_msgSend)(controlTarget,
                        sel_registerName("endTrackingWithTouch:withEvent:"),
                        _bridge_current_touch, nil);
                    bridge_log("  UIControl endTracking");
                } @catch (id e) { /* ignore */ }

                /* Fire touch-up-inside (UIControlEventTouchUpInside = 1 << 6 = 64) */
                @try {
                    ((void(*)(id, SEL, unsigned long))objc_msgSend)(controlTarget,
                        sel_registerName("sendActionsForControlEvents:"), 64);
                    bridge_log("  UIControl sendActionsForControlEvents: TouchUpInside");
                } @catch (id e) {
                    bridge_log("  UIControl sendActions failed");
                }
            }
        }
    }

    /* Fallback: fire UIControl actions when gesture delivery "succeeded" but
     * UIKit's internal gesture recognizer pipeline may not have actually
     * triggered the UIButton/UIControl action. This happens because UIKit's
     * _UIButtonGestureRecognizer requires a fully functional IOHIDEvent
     * environment that may not be present in RosettaSim's bridged context.
     *
     * We fire sendActionsForControlEvents: as a safety net. If the gesture
     * pipeline already fired the action, this may cause a double-fire — but
     * that's safer than missing the action entirely. */
    if (controlTarget && gesture_delivery_succeeded && phase == ROSETTASIM_TOUCH_ENDED) {
        Class uiButtonClass_fb = objc_getClass("UIButton");
        int isButtonTarget = 0;
        if (uiButtonClass_fb) {
            Class c = object_getClass(controlTarget);
            while (c) {
                if (c == uiButtonClass_fb) { isButtonTarget = 1; break; }
                c = class_getSuperclass(c);
            }
        }
        if (isButtonTarget) {
            @try {
                /* UIControlEventTouchUpInside = 1 << 6 = 64 */
                ((void(*)(id, SEL, unsigned long))objc_msgSend)(controlTarget,
                    sel_registerName("sendActionsForControlEvents:"), 64);
                bridge_log("  Fallback: UIButton sendActionsForControlEvents: TouchUpInside");
            } @catch (id e) {
                bridge_log("  Fallback: UIButton sendActions failed");
            }
        }
    }

    /* Also deliver standard touchesBegan:/touchesMoved:/touchesEnded: to the
     * original hit-test target — BUT ONLY if sendEvent: was not used.
     * When sendEvent: succeeds, replacement_sendTouchesForEvent already
     * delivers touchesBegan:/touchesEnded: to the view. Doing it again
     * would double-fire touch handlers. (Fix #4) */
    if (!sendEvent_succeeded && touchSel) {
        Class viewClass = object_getClass(targetView);
        if (class_respondsToSelector(viewClass, touchSel)) {
            @try {
                ((void(*)(id, SEL, id, id))objc_msgSend)(
                    targetView, touchSel, touchSetForDelivery, nil);
                bridge_log("  Direct delivery succeeded");
            } @catch (id e) {
                bridge_log("  Direct touch delivery failed: exception caught");
            }
        }
    }

    _sendEvent_guard_active = 0;

direct_delivery_done:

    /* Clean up on ENDED */
    if (phase == ROSETTASIM_TOUCH_ENDED) {
        if (_bridge_current_touch) {
            ((void(*)(id, SEL))objc_msgSend)(_bridge_current_touch, sel_registerName("release"));
            _bridge_current_touch = nil;
        }
        /* Keep _bridge_current_event — it's our reusable UITouchesEvent */
        _bridge_touch_target_view = nil;
    }
}

/* ================================================================
 * Keyboard injection system
 *
 * Reads key events from the input region (written by host app)
 * and delivers them to the first responder via insertText: or
 * specialized methods for special keys (Return, Backspace, Tab).
 *
 * The host writes key_code, key_flags, and key_char into the
 * input region and increments touch_counter to signal a new event.
 * ================================================================ */

static void check_and_inject_keyboard(void) {
    if (!_fb_mmap || !_bridge_root_window) return;

    RosettaSimInputRegion *inp = (RosettaSimInputRegion *)((uint8_t *)_fb_mmap + ROSETTASIM_FB_HEADER_SIZE);

    uint32_t key_code = inp->key_code;
    uint32_t key_flags = inp->key_flags;
    uint32_t key_char = inp->key_char;

    /* No pending key event — key_code is the signal from the host.
     * The host writes key_char and key_flags BEFORE key_code to avoid
     * the bridge seeing a partial event. key_code==0 means no event. */
    if (key_code == 0) return;

    /* Clear key_code immediately to acknowledge processing.
     * key_code is cleared first (it's the signal), then the others. */
    inp->key_code = 0;
    inp->key_flags = 0;
    inp->key_char = 0;

    /* Handle sentinel value: 0xFFFF means "character-only input, no specific
     * key code." Convert to 0 for dispatch so character-specific paths fire. */
    if (key_code == 0xFFFF) key_code = 0;
    __sync_synchronize();

    bridge_log("Keyboard event: code=%u flags=0x%x char=0x%x ('%c')",
               key_code, key_flags, key_char,
               (key_char >= 32 && key_char < 127) ? (char)key_char : '?');

    /* Schedule force-display after keyboard input to capture UI changes */
    _mark_display_dirty();

    /* Find the first responder.
     * Try [UIApplication _firstResponder] first (private API),
     * then walk from keyWindow. */
    Class appClass = objc_getClass("UIApplication");
    id app = appClass ? ((id(*)(id, SEL))objc_msgSend)(
        (id)appClass, sel_registerName("sharedApplication")) : nil;
    if (!app) return;

    id firstResponder = nil;

    /* Try _firstResponder (private, may not exist on all versions) */
    SEL firstRespSel = sel_registerName("_firstResponder");
    if (class_respondsToSelector(object_getClass(app), firstRespSel)) {
        @try {
            firstResponder = ((id(*)(id, SEL))objc_msgSend)(app, firstRespSel);
        } @catch (id e) { firstResponder = nil; }
    }

    /* Fallback: get keyWindow's firstResponder via the responder chain */
    if (!firstResponder) {
        id keyWindow = _bridge_root_window;
        if (keyWindow) {
            SEL frSel = sel_registerName("firstResponder");
            if (class_respondsToSelector(object_getClass(keyWindow), frSel)) {
                @try {
                    firstResponder = ((id(*)(id, SEL))objc_msgSend)(keyWindow, frSel);
                } @catch (id e) { firstResponder = nil; }
            }
        }
    }

    if (!firstResponder) {
        bridge_log("  No first responder found for keyboard input");
        return;
    }

    bridge_log("  First responder: %s %p",
               class_getName(object_getClass(firstResponder)),
               (void *)firstResponder);

    /* Check if first responder is a UITextField or UITextView */
    Class uiTextFieldClass = objc_getClass("UITextField");
    Class uiTextViewClass = objc_getClass("UITextView");
    int isTextInput = 0;
    {
        Class c = object_getClass(firstResponder);
        while (c) {
            if ((uiTextFieldClass && c == uiTextFieldClass) ||
                (uiTextViewClass && c == uiTextViewClass)) {
                isTextInput = 1;
                break;
            }
            c = class_getSuperclass(c);
        }
    }

    /* Also check if the responder conforms to UITextInput/UIKeyInput
     * by checking for insertText: */
    SEL insertTextSel = sel_registerName("insertText:");
    int hasInsertText = class_respondsToSelector(
        object_getClass(firstResponder), insertTextSel);

    /* Handle special keys */
    /* Common key codes (macOS virtual key codes):
     *   36 = Return
     *   51 = Delete (Backspace)
     *   48 = Tab
     *   53 = Escape
     *   123 = Left arrow
     *   124 = Right arrow
     *   125 = Down arrow
     *   126 = Up arrow
     */
    if (key_code == 51) {
        /* Backspace / Delete — use setText: with truncation for UITextField
         * since deleteBackward requires text input system */
        if (isTextInput) {
            SEL textSel = sel_registerName("text");
            SEL setTextSel = sel_registerName("setText:");
            if (class_respondsToSelector(object_getClass(firstResponder), textSel)) {
                @try {
                    id currentText = ((id(*)(id, SEL))objc_msgSend)(firstResponder, textSel);
                    if (currentText) {
                        long len = ((long(*)(id, SEL))objc_msgSend)(
                            currentText, sel_registerName("length"));
                        if (len > 0) {
                            typedef struct { long loc; long len; } _NSRange;
                            _NSRange range = {0, len - 1};
                            id newText = ((id(*)(id, SEL, _NSRange))objc_msgSend)(
                                currentText,
                                sel_registerName("substringWithRange:"), range);
                            ((void(*)(id, SEL, id))objc_msgSend)(
                                firstResponder, setTextSel, newText);
                            bridge_log("  Backspace via setText: (len %ld → %ld)", len, len - 1);
                        }
                    }
                } @catch (id e) {
                    bridge_log("  Backspace setText: failed");
                }
            }
            _mark_display_dirty();
            return;
        }
        SEL deleteBackSel = sel_registerName("deleteBackward");
        if (class_respondsToSelector(object_getClass(firstResponder), deleteBackSel)) {
            @try {
                ((void(*)(id, SEL))objc_msgSend)(firstResponder, deleteBackSel);
                bridge_log("  Delivered deleteBackward");
            } @catch (id e) {
                bridge_log("  deleteBackward failed");
            }
        } else if (hasInsertText) {
            SEL deleteBackAltSel = sel_registerName("deleteBackward:");
            if (class_respondsToSelector(object_getClass(firstResponder), deleteBackAltSel)) {
                @try {
                    ((void(*)(id, SEL, id))objc_msgSend)(firstResponder, deleteBackAltSel, nil);
                    bridge_log("  Delivered deleteBackward:");
                } @catch (id e) { /* ignore */ }
            }
        }
        return;
    }

    if (key_code == 36) {
        /* Return key */
        if (isTextInput && hasInsertText) {
            /* For UITextField, call the delegate's textFieldShouldReturn: first,
             * which lets the app handle Return (e.g. trigger connect, move to next
             * field). Then resign first responder only if the delegate didn't. */
            if (uiTextFieldClass) {
                Class c = object_getClass(firstResponder);
                int isTF = 0;
                while (c) {
                    if (c == uiTextFieldClass) { isTF = 1; break; }
                    c = class_getSuperclass(c);
                }
                if (isTF) {
                    /* Call textFieldShouldReturn: on the delegate. This may trigger
                     * network operations (connectTapped -> loginWithTrustedNetwork).
                     * The call is deferred to the next run loop iteration via a
                     * zero-delay timer so NSURLSession tasks are properly scheduled. */
                    id __strong capturedTextField = firstResponder;
                    @try {
                        SEL delegateSel = sel_registerName("delegate");
                        id delegate = ((id(*)(id, SEL))objc_msgSend)(capturedTextField, delegateSel);
                        if (delegate) {
                            SEL shouldReturnSel = sel_registerName("textFieldShouldReturn:");
                            if (class_respondsToSelector(object_getClass(delegate), shouldReturnSel)) {
                                bridge_log("  Calling textFieldShouldReturn: on delegate %s",
                                    class_getName(object_getClass(delegate)));
                                /* Use performSelector:afterDelay:0 which schedules on the
                                 * current run loop — safer for NSURLSession operations */
                                ((void(*)(id, SEL, SEL, id, double))objc_msgSend)(
                                    delegate,
                                    sel_registerName("performSelector:withObject:afterDelay:"),
                                    shouldReturnSel,
                                    capturedTextField,
                                    0.0);
                                bridge_log("  textFieldShouldReturn: scheduled via performSelector:afterDelay:");
                            } else {
                                ((bool(*)(id, SEL))objc_msgSend)(capturedTextField,
                                    sel_registerName("resignFirstResponder"));
                                bridge_log("  UITextField resignFirstResponder (Return, no delegate)");
                            }
                        } else {
                            ((bool(*)(id, SEL))objc_msgSend)(capturedTextField,
                                sel_registerName("resignFirstResponder"));
                            bridge_log("  UITextField resignFirstResponder (Return, nil delegate)");
                        }
                    } @catch (id e) {
                        bridge_log("  Return key handling threw exception");
                    }
                    return;
                }
            }
            /* For UITextView, insert a newline */
            @try {
                id newline = ((id(*)(id, SEL, const char *))objc_msgSend)(
                    (id)objc_getClass("NSString"),
                    sel_registerName("stringWithUTF8String:"), "\n");
                ((void(*)(id, SEL, id))objc_msgSend)(firstResponder, insertTextSel, newline);
                bridge_log("  Delivered insertText: newline");
            } @catch (id e) {
                bridge_log("  insertText newline failed");
            }
        }
        return;
    }

    if (key_code == 48) {
        /* Tab key */
        if (hasInsertText) {
            @try {
                id tab = ((id(*)(id, SEL, const char *))objc_msgSend)(
                    (id)objc_getClass("NSString"),
                    sel_registerName("stringWithUTF8String:"), "\t");
                ((void(*)(id, SEL, id))objc_msgSend)(firstResponder, insertTextSel, tab);
                bridge_log("  Delivered insertText: tab");
            } @catch (id e) { /* ignore */ }
        }
        return;
    }

    if (key_code == 53) {
        /* Escape key — resign first responder */
        @try {
            ((bool(*)(id, SEL))objc_msgSend)(firstResponder,
                sel_registerName("resignFirstResponder"));
            bridge_log("  Escape → resignFirstResponder");
        } @catch (id e) { /* ignore */ }
        return;
    }

    /* Arrow keys (123=Left, 124=Right, 125=Down, 126=Up) */
    if (key_code >= 123 && key_code <= 126) {
        /* UITextInput protocol: use setSelectedTextRange: to move cursor.
         * Check if the first responder conforms to UITextInput. */
        SEL posFromSel = sel_registerName("positionFromPosition:offset:");
        SEL selRangeSel = sel_registerName("selectedTextRange");
        SEL setSelRangeSel = sel_registerName("setSelectedTextRange:");
        SEL startSel = sel_registerName("start");

        if (class_respondsToSelector(object_getClass(firstResponder), posFromSel) &&
            class_respondsToSelector(object_getClass(firstResponder), selRangeSel)) {
            @try {
                id currentRange = ((id(*)(id, SEL))objc_msgSend)(
                    firstResponder, selRangeSel);
                if (currentRange) {
                    id startPos = ((id(*)(id, SEL))objc_msgSend)(
                        currentRange, startSel);
                    if (startPos) {
                        long offset = 0;
                        if (key_code == 123) offset = -1; /* Left */
                        else if (key_code == 124) offset = 1; /* Right */
                        /* Up/Down could move by line — simplified to ±1 for now */
                        else if (key_code == 126) offset = -1;
                        else if (key_code == 125) offset = 1;

                        id newPos = ((id(*)(id, SEL, id, long))objc_msgSend)(
                            firstResponder, posFromSel, startPos, offset);
                        if (newPos) {
                            SEL textRangeFromSel = sel_registerName("textRangeFromPosition:toPosition:");
                            id newRange = ((id(*)(id, SEL, id, id))objc_msgSend)(
                                firstResponder, textRangeFromSel, newPos, newPos);
                            if (newRange) {
                                ((void(*)(id, SEL, id))objc_msgSend)(
                                    firstResponder, setSelRangeSel, newRange);
                                bridge_log("  Arrow key %u → cursor moved", key_code);
                            }
                        }
                    }
                }
            } @catch (id e) {
                bridge_log("  Arrow key delivery failed");
            }
        }
        return;
    }

    /* Modifier key combinations (key_flags: 1<<20 = Command, 1<<17 = Shift,
     * 1<<18 = Control, 1<<19 = Option on macOS) */
    int isCmd = (key_flags & (1 << 20)) != 0;

    if (isCmd && key_char != 0) {
        char c = (char)(key_char & 0x7F);
        if (c == 'a' || c == 'A') {
            /* Cmd+A: Select All */
            SEL selectAllSel = sel_registerName("selectAll:");
            if (class_respondsToSelector(object_getClass(firstResponder), selectAllSel)) {
                @try {
                    ((void(*)(id, SEL, id))objc_msgSend)(firstResponder, selectAllSel, nil);
                    bridge_log("  Cmd+A → selectAll:");
                } @catch (id e) { /* ignore */ }
            }
            return;
        } else if (c == 'c' || c == 'C') {
            /* Cmd+C: Copy */
            SEL copySel = sel_registerName("copy:");
            if (class_respondsToSelector(object_getClass(firstResponder), copySel)) {
                @try {
                    ((void(*)(id, SEL, id))objc_msgSend)(firstResponder, copySel, nil);
                    bridge_log("  Cmd+C → copy:");
                } @catch (id e) { /* ignore */ }
            }
            return;
        } else if (c == 'v' || c == 'V') {
            /* Cmd+V: Paste */
            SEL pasteSel = sel_registerName("paste:");
            if (class_respondsToSelector(object_getClass(firstResponder), pasteSel)) {
                @try {
                    ((void(*)(id, SEL, id))objc_msgSend)(firstResponder, pasteSel, nil);
                    bridge_log("  Cmd+V → paste:");
                } @catch (id e) { /* ignore */ }
            }
            return;
        } else if (c == 'x' || c == 'X') {
            /* Cmd+X: Cut */
            SEL cutSel = sel_registerName("cut:");
            if (class_respondsToSelector(object_getClass(firstResponder), cutSel)) {
                @try {
                    ((void(*)(id, SEL, id))objc_msgSend)(firstResponder, cutSel, nil);
                    bridge_log("  Cmd+X → cut:");
                } @catch (id e) { /* ignore */ }
            }
            return;
        } else if (c == 'z' || c == 'Z') {
            /* Cmd+Z: Undo */
            SEL undoSel = sel_registerName("undoManager");
            if (class_respondsToSelector(object_getClass(firstResponder), undoSel)) {
                @try {
                    id undoMgr = ((id(*)(id, SEL))objc_msgSend)(firstResponder, undoSel);
                    if (undoMgr) {
                        int isShift = (key_flags & (1 << 17)) != 0;
                        if (isShift) {
                            ((void(*)(id, SEL))objc_msgSend)(undoMgr, sel_registerName("redo"));
                            bridge_log("  Cmd+Shift+Z → redo");
                        } else {
                            ((void(*)(id, SEL))objc_msgSend)(undoMgr, sel_registerName("undo"));
                            bridge_log("  Cmd+Z → undo");
                        }
                    }
                } @catch (id e) { /* ignore */ }
            }
            return;
        }
        /* Other Cmd+key combos fall through to regular character input */
    }

    /* Regular character input — skip if Cmd is held (already handled above) */
    if (isCmd) return;

    if (key_char != 0 && (isTextInput || hasInsertText)) {
        char utf8[5] = {0};
        if (key_char < 0x80) {
            utf8[0] = (char)key_char;
        } else if (key_char < 0x800) {
            utf8[0] = (char)(0xC0 | (key_char >> 6));
            utf8[1] = (char)(0x80 | (key_char & 0x3F));
        } else {
            utf8[0] = (char)(0xE0 | (key_char >> 12));
            utf8[1] = (char)(0x80 | ((key_char >> 6) & 0x3F));
            utf8[2] = (char)(0x80 | (key_char & 0x3F));
        }

        id charStr = ((id(*)(id, SEL, const char *))objc_msgSend)(
            (id)objc_getClass("NSString"),
            sel_registerName("stringWithUTF8String:"), utf8);
        if (!charStr) return;

        /* Call UITextField delegate's textField:shouldChangeCharactersInRange:replacementString:
         * if applicable. This lets apps validate/reject input character by character. */
        int shouldInsert = 1;
        if (isTextInput) {
            Class uiTextFieldClass = objc_getClass("UITextField");
            if (uiTextFieldClass) {
                Class c = object_getClass(firstResponder);
                int isTF = 0;
                while (c) {
                    if (c == uiTextFieldClass) { isTF = 1; break; }
                    c = class_getSuperclass(c);
                }
                if (isTF) {
                    SEL delegateSel = sel_registerName("delegate");
                    if (class_respondsToSelector(object_getClass(firstResponder), delegateSel)) {
                        id tfDelegate = ((id(*)(id, SEL))objc_msgSend)(firstResponder, delegateSel);
                        if (tfDelegate) {
                            SEL shouldChangeSel = sel_registerName(
                                "textField:shouldChangeCharactersInRange:replacementString:");
                            if (class_respondsToSelector(object_getClass(tfDelegate), shouldChangeSel)) {
                                @try {
                                    /* Pass empty range — the exact range is complex to compute
                                     * without UITextInput protocol, but many delegates only
                                     * check the replacement string */
                                    typedef struct { long location; long length; } _NSRange;
                                    _NSRange emptyRange = {0, 0};
                                    typedef bool (*shouldChangeFn)(id, SEL, id, _NSRange, id);
                                    bool allowed = ((shouldChangeFn)objc_msgSend)(
                                        tfDelegate, shouldChangeSel,
                                        firstResponder, emptyRange, charStr);
                                    if (!allowed) {
                                        bridge_log("  Delegate rejected character '%s'", utf8);
                                        shouldInsert = 0;
                                    }
                                } @catch (id e) { /* proceed with insert */ }
                            }
                        }
                    }
                }
            }
        }

        if (shouldInsert) {
            /* Use insertText: (UIKeyInput protocol) as the primary text input
             * method. insertText: delegates to UIFieldEditor which updates the
             * text storage, fires delegate callbacks (shouldChangeCharactersInRange),
             * maintains caret position, and triggers text validation.
             *
             * insertText: does NOT require UIKeyboardImpl — only UIFieldEditor,
             * which exists when _editing=YES (set during our tap handler).
             *
             * Fall back to setText: only if insertText: fails (e.g., _fieldEditor
             * is nil because _editing wasn't set correctly). */
            {
                int delivered = 0;
                @try {
                    ((void(*)(id, SEL, id))objc_msgSend)(firstResponder, insertTextSel, charStr);
                    delivered = 1;
                    bridge_log("  insertText: '%s'", utf8);
                } @catch (id e) {
                    bridge_log("  insertText: threw, falling back to setText:");
                }

                /* Fallback: setText: for when insertText: fails */
                if (!delivered && isTextInput) {
                    @try {
                        SEL textSel = sel_registerName("text");
                        SEL setTextSel = sel_registerName("setText:");
                        id currentText = ((id(*)(id, SEL))objc_msgSend)(
                            firstResponder, textSel);
                        id newText = currentText
                            ? ((id(*)(id, SEL, id))objc_msgSend)(
                                  currentText, sel_registerName("stringByAppendingString:"), charStr)
                            : charStr;
                        ((void(*)(id, SEL, id))objc_msgSend)(
                            firstResponder, setTextSel, newText);
                        bridge_log("  setText: fallback '%s'", utf8);
                    } @catch (id e) {
                        bridge_log("  setText: fallback also failed");
                        return;
                    }
                }
            }

            /* Post UITextFieldTextDidChangeNotification */
            if (isTextInput) {
                Class nsCenterClass = objc_getClass("NSNotificationCenter");
                id center = nsCenterClass ? ((id(*)(id, SEL))objc_msgSend)(
                    (id)nsCenterClass, sel_registerName("defaultCenter")) : nil;
                if (center) {
                    id notifName = ((id(*)(id, SEL, const char *))objc_msgSend)(
                        (id)objc_getClass("NSString"),
                        sel_registerName("stringWithUTF8String:"),
                        "UITextFieldTextDidChangeNotification");
                    ((void(*)(id, SEL, id, id, id))objc_msgSend)(
                        center, sel_registerName("postNotificationName:object:userInfo:"),
                        notifName, firstResponder, nil);
                }
            }
        }
    }
}

/* One-time diagnostic dump of the view/layer hierarchy */
static int _diag_dumped = 0;
static void _dump_view_hierarchy(id view, int depth) {
    if (!view || depth > 15) return;
    char indent[64] = {0};
    for (int i = 0; i < depth && i < 30; i++) { indent[i*2] = ' '; indent[i*2+1] = ' '; }

    Class cls = object_getClass(view);
    const char *name = class_getName(cls);

    /* Get frame via layer.bounds (avoid CGRect struct return issues) */
    id layer = ((id(*)(id, SEL))objc_msgSend)(view, sel_registerName("layer"));
    bool hidden = ((bool(*)(id, SEL))objc_msgSend)(view, sel_registerName("isHidden"));
    double alpha = ((double(*)(id, SEL))objc_msgSend)(view, sel_registerName("alpha"));

    bridge_log("  %s%s %p hidden=%d alpha=%.1f", indent, name, (void *)view, hidden, alpha);

    id subviews = ((id(*)(id, SEL))objc_msgSend)(view, sel_registerName("subviews"));
    if (subviews) {
        long count = ((long(*)(id, SEL))objc_msgSend)(subviews, sel_registerName("count"));
        for (long i = 0; i < count; i++) {
            id sv = ((id(*)(id, SEL, long))objc_msgSend)(
                subviews, sel_registerName("objectAtIndex:"), i);
            _dump_view_hierarchy(sv, depth + 1);
        }
    }
}

/* Track whether we need to force-display the layer tree.
 * Set to a positive count on startup and after touch events.
 * Decremented each frame; when 0, skip force-display (use cached backing stores).
 *
 * Higher initial count for complex apps (hass-dashboard loads UI during
 * makeKeyAndVisible, consuming early frames before views are laid out).
 * Periodic refresh catches timer-driven updates (animations, network responses). */
static int _force_display_countdown = 60;  /* Force first 60 frames (~2s) */

/* Called after a touch or keyboard event mutates the UI.
 *
 * Sets the countdown to trigger _force_display_recursive for the next few
 * frames, but does NOT set _force_full_refresh. This ensures layers that
 * don't yet have content get populated (nil backing store → setNeedsDisplay),
 * while layers that DO have content (tint colors, selection states, etc.)
 * keep their cached backing stores intact.
 *
 * _force_full_refresh is only used during initial startup (first 60 frames)
 * when no content has been drawn yet. */
static void _mark_display_dirty(void) {
    if (_force_display_countdown < 10) _force_display_countdown = 10;
    /* Do NOT set _force_full_refresh — that destroys cached backing stores
     * (tint colors, selection states) which causes visual regressions. */
}

static void frame_capture_tick(CFRunLoopTimerRef timer, void *info) {
    if (!_bridge_root_window || !_fb_mmap) return;
    if (!_cg_CreateColorSpace || !_cg_CreateBitmap) return;

    /* One-time view hierarchy dump for diagnostics */
    if (!_diag_dumped) {
        _diag_dumped = 1;
        bridge_log("=== View Hierarchy Dump ===");
        _dump_view_hierarchy(_bridge_root_window, 0);
        bridge_log("=== End Dump ===");
    }

    /* Check for and inject touch events from host.
     * Touch injection is wrapped in per-event @autoreleasepool (inside
     * check_and_inject_touch) to isolate crash recovery from the outer
     * run loop's autorelease pool. */
    check_and_inject_touch();

    /* Check for and inject keyboard events from host */
    check_and_inject_keyboard();

    /* GPU Rendering mode: Hybrid approach.
     *
     * PHASE 1: Populate layer backing stores (CPU) — same as standalone mode.
     *   _force_display_recursive triggers drawRect: on layers that need content.
     *   This creates CGImage/IOSurface backing stores for text, backgrounds, etc.
     *
     * PHASE 2: Commit to CARenderServer (GPU) — server composites with proper
     *   tintColor, animations, blur, and display cycle.
     *
     * PHASE 3: Copy from backboardd framebuffer — CARenderServer renders to
     *   PurpleDisplay surface, we relay to the app framebuffer for the host. */
    if (g_gpu_rendering_active && _backboardd_fb_mmap && _fb_mmap) {
        RosettaSimFramebufferHeader *dst_hdr = (RosettaSimFramebufferHeader *)_fb_mmap;
        void *dst_pixels = (uint8_t *)_fb_mmap + ROSETTASIM_FB_META_SIZE;

        /* Get root layer */
        id layer = NULL;
        if (_bridge_root_window) {
            layer = ((id(*)(id, SEL))objc_msgSend)(
                _bridge_root_window, sel_registerName("layer"));
        }
        if (!layer) goto gpu_copy;

        /* Ensure root layer is visible */
        ((void(*)(id, SEL, BOOL))objc_msgSend)(layer, sel_registerName("setHidden:"), (BOOL)false);

        /* PHASE 1+2: Layout + force display + commit to server.
         * Wrapped in @try because UIScrollView layout can crash. */
        @try {
            /* Flush pending CA changes */
            Class catClass = objc_getClass("CATransaction");
            if (catClass) {
                ((void(*)(id, SEL))objc_msgSend)((id)catClass, sel_registerName("flush"));
            }

            /* Layout */
            ((void(*)(id, SEL))objc_msgSend)(
                _bridge_root_window, sel_registerName("setNeedsLayout"));
            ((void(*)(id, SEL))objc_msgSend)(
                _bridge_root_window, sel_registerName("layoutIfNeeded"));

            /* Force-display to populate layer backing stores.
             * Same countdown logic as CPU mode. */
            int need_force = 0;
            if (_force_display_countdown > 0) {
                _force_display_countdown--;
                need_force = 1;
            }
            {
                static int _gpu_periodic = 0;
                _gpu_periodic++;
                if (_gpu_periodic >= 30) { _gpu_periodic = 0; need_force = 1; }
            }
            if (need_force) {
                _force_display_recursive(layer, 0);
                if (_force_full_refresh) _force_full_refresh = 0;
            }

            /* Commit populated layers to CARenderServer */
            if (catClass) {
                ((void(*)(id, SEL))objc_msgSend)((id)catClass, sel_registerName("flush"));
            }
        } @catch (id ex) {
            /* Layout/display crashed — skip this frame's population */
        }

    gpu_copy:
        /* PHASE 3: Try UIWindow.createIOSurfaceFromScreen: to capture
         * server-composited content. This is what the real iOS simulator uses. */
        @try {
            Class uiWindowClass = objc_getClass("UIWindow");
            SEL captSel = sel_registerName("createIOSurfaceFromScreen:");
            if (uiWindowClass && class_respondsToSelector(
                    object_getClass((id)uiWindowClass), captSel)) {
                Class uiScreenClass = objc_getClass("UIScreen");
                id mainScreen = ((id(*)(id, SEL))objc_msgSend)(
                    (id)uiScreenClass, sel_registerName("mainScreen"));
                if (mainScreen) {
                    /* IOSurfaceRef createIOSurfaceFromScreen:(UIScreen*) */
                    typedef void * (*CaptFn)(id, SEL, id);
                    void *ioSurface = ((CaptFn)objc_msgSend)(
                        (id)uiWindowClass, captSel, mainScreen);
                    if (ioSurface) {
                        /* Read IOSurface properties */
                        typedef size_t (*IOSGetWidthFn)(void *);
                        typedef size_t (*IOSGetHeightFn)(void *);
                        typedef int (*IOSLockFn)(void *, uint32_t, uint32_t *);
                        typedef void * (*IOSGetBaseAddrFn)(void *);
                        typedef int (*IOSUnlockFn)(void *, uint32_t, uint32_t *);

                        IOSGetWidthFn getW = (IOSGetWidthFn)dlsym(RTLD_DEFAULT, "IOSurfaceGetWidth");
                        IOSGetHeightFn getH = (IOSGetHeightFn)dlsym(RTLD_DEFAULT, "IOSurfaceGetHeight");
                        IOSLockFn lockFn = (IOSLockFn)dlsym(RTLD_DEFAULT, "IOSurfaceLock");
                        IOSGetBaseAddrFn getBase = (IOSGetBaseAddrFn)dlsym(RTLD_DEFAULT, "IOSurfaceGetBaseAddress");
                        IOSUnlockFn unlockFn = (IOSUnlockFn)dlsym(RTLD_DEFAULT, "IOSurfaceUnlock");

                        if (getW && getH && lockFn && getBase && unlockFn) {
                            size_t sw = getW(ioSurface);
                            size_t sh = getH(ioSurface);
                            lockFn(ioSurface, 1 /* kIOSurfaceLockReadOnly */, NULL);
                            void *base = getBase(ioSurface);
                            if (base && sw == dst_hdr->width && sh == dst_hdr->height) {
                                size_t bytes = sw * sh * 4;
                                memcpy(dst_pixels, base, bytes);
                                dst_hdr->frame_counter++;
                                static int _logged_ios = 0;
                                if (!_logged_ios) {
                                    _logged_ios = 1;
                                    bridge_log("GPU CAPTURE: createIOSurfaceFromScreen %zux%zu → copied to framebuffer", sw, sh);
                                }
                            }
                            unlockFn(ioSurface, 1, NULL);
                        }
                        /* Release IOSurface */
                        typedef void (*CFRelFn)(void *);
                        CFRelFn cfRel = (CFRelFn)dlsym(RTLD_DEFAULT, "CFRelease");
                        if (cfRel) cfRel(ioSurface);
                    }
                }
            }
        } @catch (id ex) {
            /* Ignore — will fall through to PurpleDisplay surface copy */
        }

        /* Fallback: copy from PurpleDisplay surface (backboardd framebuffer) */
        {
            RosettaSimFramebufferHeader *src_hdr = (RosettaSimFramebufferHeader *)_backboardd_fb_mmap;
            void *src_pixels = (uint8_t *)_backboardd_fb_mmap + ROSETTASIM_FB_META_SIZE;

            if (src_hdr->magic == ROSETTASIM_FB_MAGIC &&
                src_hdr->width == dst_hdr->width &&
                src_hdr->height == dst_hdr->height) {
                size_t pixel_bytes = (size_t)dst_hdr->width * dst_hdr->height * 4;
                memcpy(dst_pixels, src_pixels, pixel_bytes);
                dst_hdr->frame_counter++;
            }
        }

        return;  /* Skip CPU renderInContext */
    }

    /* CPU Rendering mode: When CARenderServer is not available or display
     * association failed, we use renderInContext to capture the layer tree.
     *
     * Note: Even with CARenderServer connected (g_ca_server_connected=1), if
     * g_gpu_rendering_active is 0, we still do CPU rendering because the app's
     * window layer tree isn't committed to a CADisplay on CARenderServer.
     *
     * The CARenderServer connection DOES improve rendering quality by enabling:
     * - CABasicAnimation / CAKeyframeAnimation (real animations instead of static)
     * - UIVisualEffectView (blur, vibrancy)
     * - Proper tintColor rendering
     * - CADisplayLink vsync (if available)
     */

    RosettaSimFramebufferHeader *hdr = (RosettaSimFramebufferHeader *)_fb_mmap;
    void *pixels = (uint8_t *)_fb_mmap + ROSETTASIM_FB_META_SIZE;

    int px_w = hdr->width;
    int px_h = hdr->height;

    /* Get root window's layer */
    id layer = ((id(*)(id, SEL))objc_msgSend)(
        _bridge_root_window, sel_registerName("layer"));
    if (!layer) return;

    /* Ensure root layer is visible (set on CALayer, not UIView, to avoid
       triggering UIKit's BKSEventFocusManager which needs backboardd) */
    ((void(*)(id, SEL, bool))objc_msgSend)(layer, sel_registerName("setHidden:"), false);

    /* Flush pending CATransaction changes and handle layout/display.
     *
     * Without CARenderServer, there's no display cycle — we must populate backing
     * stores ourselves. The force_display_countdown tracks when we need to
     * force-populate layer backing stores (startup, after touch, periodic refresh).
     *
     * Optimization: when countdown is 0, still flush + layout (needed for timers
     * and animations), but skip the expensive _force_display_recursive walk.
     *
     * The entire layout+render section is wrapped in a SIGSEGV crash guard.
     * UIScrollView's pan gesture recognizer modifies contentOffset, which can
     * trigger CA internal layout passes that crash without CARenderServer.
     * We catch the crash and skip that frame rather than killing the process. */
    static sigjmp_buf _render_recovery;
    static volatile sig_atomic_t _render_guard_active = 0;
    if (!_sendEvent_handlers_installed) {
        struct sigaction sa;
        memset(&sa, 0, sizeof(sa));
        sa.sa_sigaction = _sendEvent_crash_handler_siginfo;
        sigemptyset(&sa.sa_mask);
        sa.sa_flags = SA_SIGINFO;
        sigaction(SIGSEGV, &sa, &_prev_sigsegv_action);
        sigaction(SIGBUS, &sa, &_prev_sigbus_action);
        _sendEvent_handlers_installed = 1;
    }

    _sendEvent_guard_active = 1;
    int render_crash = sigsetjmp(_sendEvent_recovery, 1);
    if (render_crash != 0) {
        _sendEvent_guard_active = 0;
        bridge_log("frame_capture_tick: layout/render CRASHED (signal %d) — skipping frame", render_crash);
        return;
    }

    int need_force_display = 0;
    if (_force_display_countdown > 0) {
        _force_display_countdown--;
        need_force_display = 1;
    }

    /* Periodic refresh: every ~1s (30 frames), force-display to catch timer-driven
     * updates (network responses, animations). Use a static counter. */
    {
        static int _periodic_counter = 0;
        _periodic_counter++;
        if (_periodic_counter >= 30) {
            _periodic_counter = 0;
            need_force_display = 1;
        }
    }

    {
        Class caTransaction = objc_getClass("CATransaction");
        if (caTransaction) {
            ((void(*)(id, SEL))objc_msgSend)((id)caTransaction, sel_registerName("flush"));
        }

        ((void(*)(id, SEL))objc_msgSend)(
            _bridge_root_window, sel_registerName("setNeedsLayout"));
        ((void(*)(id, SEL))objc_msgSend)(
            _bridge_root_window, sel_registerName("layoutIfNeeded"));

        if (need_force_display) {
            _force_display_recursive(layer, 0);
            /* Clear full refresh flag after one complete cycle */
            if (_force_full_refresh) _force_full_refresh = 0;
        }
    }

    /* Double-buffer: render into a local buffer first, then memcpy to the
     * shared framebuffer. This prevents the host from seeing transient states:
     *   - CGBitmapContextCreate clears to white before renderInContext: draws
     *   - Partial renders (top half new, bottom half old)
     * The host only ever sees complete frames. */
    size_t pixel_size = px_w * px_h * 4;
    if (!_render_buffer || _render_buffer_size != pixel_size) {
        if (_render_buffer) free(_render_buffer);
        _render_buffer = malloc(pixel_size);
        _render_buffer_size = pixel_size;
    }

    void *cs = _cg_CreateColorSpace();
    /* kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little = 0x2002 */
    void *ctx = _cg_CreateBitmap(_render_buffer, px_w, px_h, 8, px_w * 4, cs, 0x2002);

    if (ctx) {
        /* Scale for Retina. CG origin is bottom-left — we keep positive scale
         * to avoid CoreText glyph mirroring, then rotate the buffer 180° in
         * post-processing to convert from CG coordinate space (origin bottom-left)
         * to raster coordinate space (origin top-left). */
        _cg_ScaleCTM(ctx, (double)kScreenScaleX, (double)kScreenScaleY);

        /* Pre-fill with window's background color so plain-backgroundColor
         * views (skipped by _force_display_recursive) are visible.
         * Use CoreGraphics fill since we're already in a CG context. */
        {
            /* Get window.backgroundColor -> CGColor */
            id bgColor = ((id(*)(id, SEL))objc_msgSend)(
                _bridge_root_window, sel_registerName("backgroundColor"));
            if (bgColor) {
                void *cgColor = ((void *(*)(id, SEL))objc_msgSend)(
                    bgColor, sel_registerName("CGColor"));
                if (cgColor) {
                    void (*cg_SetFillColor)(void *, void *) =
                        dlsym(RTLD_DEFAULT, "CGContextSetFillColorWithColor");
                    void (*cg_FillRect)(void *, _RSBridgeCGRect) =
                        dlsym(RTLD_DEFAULT, "CGContextFillRect");
                    if (cg_SetFillColor && cg_FillRect) {
                        cg_SetFillColor(ctx, cgColor);
                        _RSBridgeCGRect fullScreen = {0, 0, kScreenWidth, kScreenHeight};
                        cg_FillRect(ctx, fullScreen);
                    }
                }
            } else {
                /* No backgroundColor set — fill with white as default */
                void (*cg_SetGray)(void *, double, double) =
                    dlsym(RTLD_DEFAULT, "CGContextSetGrayFillColor");
                void (*cg_FillRect)(void *, _RSBridgeCGRect) =
                    dlsym(RTLD_DEFAULT, "CGContextFillRect");
                if (cg_SetGray && cg_FillRect) {
                    cg_SetGray(ctx, 1.0, 1.0);  /* white, full alpha */
                    _RSBridgeCGRect fullScreen = {0, 0, kScreenWidth, kScreenHeight};
                    cg_FillRect(ctx, fullScreen);
                }
            }
        }

        /* Render the layer tree into the local buffer */
        ((void(*)(id, SEL, void *))objc_msgSend)(
            layer, sel_registerName("renderInContext:"), ctx);

        _cg_Release(ctx);

        /* Pixel data is in CG coordinate convention (row 0 = bottom of visual).
         * The host app handles the Y-flip when displaying via its NSView draw()
         * method (translateBy + scaleBy). No flip needed here. */

        /* Copy completed frame to shared framebuffer in one shot */
        memcpy(pixels, _render_buffer, pixel_size);
        __sync_synchronize();
        hdr->frame_counter++;
        hdr->timestamp_ns = mach_absolute_time();
        hdr->flags |= ROSETTASIM_FB_FLAG_FRAME_READY;
    }
    _cg_ReleaseCS(cs);

    _sendEvent_guard_active = 0;
}

/*
 * Find the root window to render.
 *
 * Priority:
 *   1. delegate.window property
 *   2. UIApplication.sharedApplication.keyWindow
 *   3. Create a default window (fallback)
 */
static void find_root_window(id delegate) {
    /* 1. Try delegate.window */
    if (delegate) {
        Class delClass = object_getClass(delegate);
        SEL windowSel = sel_registerName("window");
        if (class_respondsToSelector(delClass, windowSel)) {
            id window = ((id(*)(id, SEL))objc_msgSend)(delegate, windowSel);
            if (window) {
                /* Retain to prevent deallocation (bridge is MRR) */
                ((id(*)(id, SEL))objc_msgSend)(window, sel_registerName("retain"));
                /* NOTE: Don't call setHidden:NO on UIWindow — it triggers
                   BKSEventFocusManager. The bridge sets hidden=NO on the
                   CALayer in frame_capture_tick instead. */
                _bridge_root_window = window;
                bridge_log("  Root window from delegate.window: %p", (void *)window);
                return;
            }
        }
    }

    /* 2. Try UIApplication.sharedApplication.keyWindow */
    Class appClass = objc_getClass("UIApplication");
    if (appClass) {
        id app = ((id(*)(id, SEL))objc_msgSend)(
            (id)appClass, sel_registerName("sharedApplication"));
        if (app) {
            id kw = ((id(*)(id, SEL))objc_msgSend)(
                app, sel_registerName("keyWindow"));
            if (kw) {
                ((id(*)(id, SEL))objc_msgSend)(kw, sel_registerName("retain"));
                _bridge_root_window = kw;
                bridge_log("  Root window from keyWindow: %p", (void *)kw);
                return;
            }
        }
    }

    /* 3. Create a default window as fallback */
    Class windowClass = objc_getClass("UIWindow");
    if (windowClass) {
        _RSBridgeCGRect frame = {0, 0, kScreenWidth, kScreenHeight};
        typedef id (*initFrame_fn)(id, SEL, _RSBridgeCGRect);

        id window = ((initFrame_fn)objc_msgSend)(
            ((id(*)(id, SEL))objc_msgSend)((id)windowClass, sel_registerName("alloc")),
            sel_registerName("initWithFrame:"), frame);

        if (window) {
            id white = ((id(*)(id, SEL))objc_msgSend)(
                (id)objc_getClass("UIColor"), sel_registerName("whiteColor"));
            ((void(*)(id, SEL, id))objc_msgSend)(
                window, sel_registerName("setBackgroundColor:"), white);
            /* No need to retain - we own it from alloc */
            _bridge_root_window = window;
            bridge_log("  Created default root window: %p", (void *)window);
            return;
        }
    }

    bridge_log("  WARNING: No root window found — frame capture will be disabled");
}

static void start_frame_capture(void) {
    resolve_cg_functions();

    if (!_cg_CreateColorSpace || !_cg_CreateBitmap) {
        bridge_log("Frame capture disabled (CoreGraphics functions not found)");
        return;
    }

    if (setup_shared_framebuffer() < 0) {
        bridge_log("Frame capture disabled (framebuffer setup failed)");
        return;
    }

    /* Create a repeating timer for frame capture.
     *
     * ITEM 17: Use configurable FPS target from env var.
     * ROSETTASIM_FPS — target frames per second (default: 30)
     *
     * Higher FPS gives smoother interaction but uses more CPU.
     * 30fps is adequate for most simulator use; 60fps for
     * animation-heavy apps. */
    double fps = 30.0;
    {
        const char *fpsEnv = getenv("ROSETTASIM_FPS");
        if (fpsEnv) {
            double customFps = atof(fpsEnv);
            if (customFps >= 1.0 && customFps <= 120.0) fps = customFps;
        }
    }
    double interval = 1.0 / fps;
    CFRunLoopTimerRef timer = CFRunLoopTimerCreate(
        NULL,                             /* allocator */
        CFAbsoluteTimeGetCurrent() + 0.1, /* first fire (100ms delay) */
        interval,                         /* repeat interval */
        0, 0,                             /* flags, order */
        frame_capture_tick,               /* callback */
        NULL);                            /* context */

    CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, kCFRunLoopCommonModes);
    bridge_log("Frame capture started (%.0f FPS target)", fps);

    /* Register as a CADisplayLink-lite: post a notification that CADisplayLink
     * observers can hook into. This enables basic animation timing support
     * for apps that use CADisplayLink for frame-driven animations. */
    {
        Class caDisplayLinkClass = objc_getClass("CADisplayLink");
        if (caDisplayLinkClass) {
            bridge_log("  CADisplayLink available — animations may partially work via render timer");
        }
    }
}

/* ================================================================
 * DYLD Interposition Table
 *
 * dyld processes this at load time and redirects calls from the
 * original functions to our replacements. This works because
 * dyld_sim honors __DATA,__interpose in injected libraries.
 * ================================================================ */

/* ================================================================
 * bootstrap_look_up interposition — routes service lookups through broker.
 *
 * CARenderServerGetServerPort() calls bootstrap_look_up() to find the
 * CARenderServer Mach port. Since CARenderServerGetServerPort is an
 * intra-library call within QuartzCore, we can't interpose IT directly.
 * But bootstrap_look_up IS a cross-library call from QuartzCore to libSystem,
 * so we CAN interpose that.
 *
 * When running under the broker, we intercept lookups for known services
 * and route them through the broker's custom protocol (msg_id 701).
 * For all other services, we pass through to the real bootstrap_look_up.
 * ================================================================ */

static kern_return_t replacement_bootstrap_look_up(mach_port_t bp,
                                                     const char *name,
                                                     mach_port_t *sp) {
    /* Services that should be routed through the broker */
    static const char *broker_services[] = {
        "com.apple.CARenderServer",
        "com.apple.iohideventsystem",
        NULL
    };

    /* CARenderServer connection can be controlled via ROSETTASIM_CA_MODE:
     *   "server" — always enable CARenderServer routing (default when broker present)
     *   "cpu"    — force CPU-only rendering even under broker
     * When running under the broker (g_bridge_broker_port != NULL), server mode
     * is enabled by default to leverage GPU rendering via backboardd's CARenderServer. */
    static int _ca_mode_checked = 0;
    static int _ca_mode_server = 0;
    if (!_ca_mode_checked) {
        const char *mode = getenv("ROSETTASIM_CA_MODE");
        if (mode && strcmp(mode, "cpu") == 0) {
            _ca_mode_server = 0;
        } else if (mode && strcmp(mode, "server") == 0) {
            _ca_mode_server = 1;
        } else {
            /* Auto-detect: enable server mode when running under broker.
             * Check TASK_BOOTSTRAP_PORT which is set by posix_spawnattr_setspecialport_np. */
            mach_port_t bp = MACH_PORT_NULL;
            task_get_special_port(mach_task_self(), TASK_BOOTSTRAP_PORT, &bp);
            _ca_mode_server = (bp != MACH_PORT_NULL) ? 1 : 0;
            if (_ca_mode_server && g_bridge_broker_port == MACH_PORT_NULL) {
                g_bridge_broker_port = bp;
            }
        }
        _ca_mode_checked = 1;
        if (_ca_mode_server) {
            bridge_log("CARenderServer mode enabled (broker_port=0x%x)",
                       g_bridge_broker_port);
        }
    }

    if (_ca_mode_server && name && g_bridge_broker_port != MACH_PORT_NULL) {
        for (int i = 0; broker_services[i]; i++) {
            if (strcmp(name, broker_services[i]) == 0) {
                mach_port_t port = bridge_broker_lookup(name);
                if (port != MACH_PORT_NULL) {
                    *sp = port;
                    bridge_log("bootstrap_look_up('%s') → broker port %u", name, port);

                    /* Track CARenderServer connection */
                    if (strcmp(name, "com.apple.CARenderServer") == 0) {
                        g_ca_server_port = port;
                        g_ca_server_connected = 1;
                    }
                    return KERN_SUCCESS;
                }
                /* Broker lookup failed — fall through to real bootstrap_look_up */
                break;
            }
        }
    }

    /* Fast-fail services that would hang in the iOS SDK's mach_msg2/XPC path.
     * The real bootstrap_look_up (iOS SDK) uses mach_msg2 which can hang when
     * the service doesn't exist and there's no proper launchd_sim. Return
     * BOOTSTRAP_UNKNOWN_SERVICE (1102) immediately for known-missing services. */
    if (name) {
        static const char *fast_fail_services[] = {
            "com.apple.SystemConfiguration.configd_sim",
            "com.apple.springboard.backgroundappservices",
            "com.apple.backboard.hid.services",
            /* "com.apple.backboard.display.services", — REMOVED: now handled by purple_fb_server */
            "com.apple.analyticsd",
            "com.apple.coreservices.lsuseractivityd.simulatorsupport",
            NULL
        };
        for (int i = 0; fast_fail_services[i]; i++) {
            if (strcmp(name, fast_fail_services[i]) == 0) {
                static int _ff_log_count = 0;
                if (_ff_log_count < 20) {
                    bridge_log("bootstrap_look_up('%s') → FAST_FAIL (service not available)", name);
                    _ff_log_count++;
                }
                if (sp) *sp = MACH_PORT_NULL;
                return 1102;  /* BOOTSTRAP_UNKNOWN_SERVICE */
            }
        }
    }

    /* For display services, retry with wait since backboardd may still be registering */
    if (name && strcmp(name, "com.apple.backboard.display.services") == 0) {
        bridge_log("bootstrap_look_up('%s') — waiting for service...", name);
        for (int r = 0; r < 30; r++) { /* 30 × 200ms = 6 seconds max */
            mach_port_t dsPort = bridge_broker_lookup(name);
            if (dsPort != MACH_PORT_NULL) {
                if (sp) *sp = dsPort;
                bridge_log("bootstrap_look_up('%s') → %u (broker, after %d retries)", name, dsPort, r);
                return KERN_SUCCESS;
            }
            usleep(200000);
        }
        bridge_log("bootstrap_look_up('%s') → FAILED after 30 retries", name);
        if (sp) *sp = MACH_PORT_NULL;
        return 1102; /* BOOTSTRAP_UNKNOWN_SERVICE */
    }

    /* Pass through to real bootstrap_look_up for all other services */
    kern_return_t kr = bootstrap_look_up(bp, name, sp);
    if (name) {
        static int _lookup_count = 0;
        if (_lookup_count < 10) {  /* Limit log noise */
            bridge_log("bootstrap_look_up('%s') → %s (%d) port=%u",
                       name, kr == KERN_SUCCESS ? "OK" : "FAILED", kr,
                       (kr == KERN_SUCCESS && sp) ? *sp : 0);
            _lookup_count++;
        }
    }
    return kr;
}

typedef struct {
    const void *replacement;
    const void *replacee;
} interpose_t;

__attribute__((used))
static const interpose_t interposers[]
__attribute__((section("__DATA,__interpose"))) = {
    /* DISABLED — let real BKS functions run. They call bootstrap_look_up
     * internally, which is intercepted by our bridge to route through broker.
     * The display services handler in purple_fb_server responds to the MIG
     * messages, establishing a proper display services connection. */
    /* { (const void *)replacement_BKSDisplayServicesStart,
      (const void *)BKSDisplayServicesStart }, */
    /* { (const void *)replacement_BKSDisplayServicesServerPort,
      (const void *)BKSDisplayServicesServerPort }, */
    /* { (const void *)replacement_BKSDisplayServicesGetMainScreenInfo,
      (const void *)BKSDisplayServicesGetMainScreenInfo }, */

    { (const void *)replacement_BKSWatchdogGetIsAlive,
      (const void *)BKSWatchdogGetIsAlive },

    { (const void *)replacement_BKSWatchdogServerPort,
      (const void *)BKSWatchdogServerPort },

    { (const void *)replacement_CARenderServerGetServerPort,
      (const void *)CARenderServerGetServerPort },

    /* GraphicsServices - Purple ports */
    { (const void *)replacement_GSGetPurpleSystemEventPort,
      (const void *)GSGetPurpleSystemEventPort },

    { (const void *)replacement_GSGetPurpleWorkspacePort,
      (const void *)GSGetPurpleWorkspacePort },

    { (const void *)replacement_GSGetPurpleSystemAppPort,
      (const void *)GSGetPurpleSystemAppPort },

    { (const void *)replacement_GSRegisterPurpleNamedPerPIDPort,
      (const void *)GSRegisterPurpleNamedPerPIDPort },

    { (const void *)replacement_GSRegisterPurpleNamedPort,
      (const void *)GSRegisterPurpleNamedPort },

    /* _GSEventInitializeApp - replaces entire function to avoid
       intra-library call to GSRegisterPurpleNamedPerPIDPort */
    { (const void *)replacement_GSEventInitializeApp,
      (const void *)_GSEventInitializeApp },

    /* BKSHIDEventRegisterEventCallbackOnRunLoop - skip HID system client */
    { (const void *)replacement_BKSHIDEventRegisterEventCallbackOnRunLoop,
      (const void *)BKSHIDEventRegisterEventCallbackOnRunLoop },

    /* UIApplicationMain - wrap with abort guard */
    { (const void *)replacement_UIApplicationMain,
      (const void *)UIApplicationMain },

    /* bootstrap_register2 - make Purple port registration succeed */
    { (const void *)replacement_bootstrap_register2,
      (const void *)bootstrap_register2 },

    /* abort() - intercept to survive bootstrap_register failures */
    { (const void *)replacement_abort,
      (const void *)abort },

    /* exit() - intercept workspace server disconnect exit during init */
    { (const void *)replacement_exit,
      (const void *)exit },

    /* _exit() - intercept direct exit that bypasses exit() */
    { (const void *)replacement_exit,
      (const void *)_exit },

    /* bootstrap_look_up - route service lookups through broker when available.
     * This is CRITICAL because CARenderServerGetServerPort() is an intra-library
     * call within QuartzCore and cannot be interposed directly. But it calls
     * bootstrap_look_up() which IS a cross-library call to libSystem. */
    { (const void *)replacement_bootstrap_look_up,
      (const void *)bootstrap_look_up },

    /* SCNetworkReachability - stub to bypass configd_sim dependency.
     * Without configd_sim, NSURLSession hangs waiting for reachability. */
    { (const void *)replacement_SCNetworkReachabilityCreateWithAddress,
      (const void *)SCNetworkReachabilityCreateWithAddress },
    { (const void *)replacement_SCNetworkReachabilityCreateWithName,
      (const void *)SCNetworkReachabilityCreateWithName },
    { (const void *)replacement_SCNetworkReachabilityGetFlags,
      (const void *)SCNetworkReachabilityGetFlags },
    { (const void *)replacement_SCNetworkReachabilitySetCallback,
      (const void *)SCNetworkReachabilitySetCallback },
    { (const void *)replacement_SCNetworkReachabilityScheduleWithRunLoop,
      (const void *)SCNetworkReachabilityScheduleWithRunLoop },
    { (const void *)replacement_SCNetworkReachabilityUnscheduleFromRunLoop,
      (const void *)SCNetworkReachabilityUnscheduleFromRunLoop },

    /* SCDynamicStore - stub for proxy configuration.
     * NSURLSession queries proxy settings via SCDynamicStoreCopyProxies. */
    { (const void *)replacement_SCDynamicStoreCreate,
      (const void *)SCDynamicStoreCreate },
    { (const void *)replacement_SCDynamicStoreCopyProxies,
      (const void *)SCDynamicStoreCopyProxies },
};

/* ================================================================
 * Constructor - runs before main()
 *
 * This fires when the dylib is loaded, before UIApplicationMain.
 * Use it for any setup that needs to happen early.
 * ================================================================ */

/* ================================================================
 * Bootstrap port fix
 *
 * The old dyld_sim doesn't inherit the task bootstrap port into
 * the global bootstrap_port variable. Fix it in the constructor.
 * ================================================================ */

extern mach_port_t bootstrap_port;
kern_return_t bootstrap_register(mach_port_t bp, const char *name, mach_port_t sp);

static void fix_bootstrap_port(void) {
    if (bootstrap_port == MACH_PORT_NULL) {
        mach_port_t task_bp = MACH_PORT_NULL;
        kern_return_t kr = task_get_special_port(mach_task_self(),
                                                  TASK_BOOTSTRAP_PORT, &task_bp);
        if (kr == KERN_SUCCESS && task_bp != MACH_PORT_NULL) {
            bootstrap_port = task_bp;
            bridge_log("Fixed bootstrap_port: 0x%x", bootstrap_port);
        } else {
            bridge_log("WARN: Could not get task bootstrap port (kr=%d)", kr);
        }
    }
}

/* DEAD CODE REMOVED (ITEM 11):
 * replacement_sendTouchesForEvent and replacement_UITextFieldBecomeFirstResponder
 * were defined but never installed as swizzle targets. With UIEventDispatcher
 * properly initialized in replacement_runWithMainScene and gesture recognizer
 * pre-warming (ITEM 2), UIKit's native sendEvent: and becomeFirstResponder
 * work correctly without these replacements. */

/* ================================================================
 * BackBoardServices method swizzling
 *
 * With sharedApplication fixed, UIKit activates more code paths that
 * call into BKSEventFocusManager and other BBS classes. These assert
 * when backboardd is unavailable. Swizzle them to no-ops.
 * ================================================================ */

static void _noopMethod(id self, SEL _cmd, ...) {
    /* Silently no-op */
}

static id _nilMethod(id self, SEL _cmd, ...) {
    return nil;
}

/* Replacement for -[UIWindow makeKeyAndVisible].
 *
 * APPROACH: Call UIKit's REAL internal methods instead of reimplementing them.
 * BKSEventFocusManager's backboardd-calling methods are already stubbed to
 * no-ops (in swizzle_bks_methods), so UIKit's native makeKeyAndVisible path
 * can run safely — the inter-process focus calls become harmless no-ops while
 * the local event registration (UIGestureEnvironment, key window state) proceeds
 * normally.
 *
 * Previous approach manually did view installation + layout but SKIPPED the
 * internal key window registration (_makeKeyWindowIgnoringOldKeyWindow:) which
 * is where UIGestureEnvironment learns about the window. This caused sendEvent:
 * to crash because gesture recognizer processing couldn't find the window.
 */
static IMP _original_makeKeyAndVisible_IMP = NULL;

static void replacement_makeKeyAndVisible(id self, SEL _cmd) {
    bridge_log("  [UIWindow makeKeyAndVisible] intercepted — calling UIKit's real impl");

    /* Track in our window stack (for frame capture and key window queries) */
    _bridge_track_window(self);
    _bridge_key_window = self;
    if (!_bridge_root_window) {
        _bridge_root_window = self;
        ((id(*)(id, SEL))objc_msgSend)(self, sel_registerName("retain"));
    }

    /* Call UIKit's ORIGINAL makeKeyAndVisible.
     * BKSEventFocusManager methods are already no-op'd, so the inter-process
     * calls are harmless. The important local work (view installation, key
     * window registration, gesture environment setup) runs normally. */
    if (_original_makeKeyAndVisible_IMP) {
        bridge_log("  Calling original makeKeyAndVisible IMP");
        ((void(*)(id, SEL))_original_makeKeyAndVisible_IMP)(self, _cmd);
        bridge_log("  Original makeKeyAndVisible completed");

        /* DISABLED — let CA handle context creation naturally */
        /* if (!_bridge_pre_created_context) {
            replacement_CARenderServerGetServerPort();
        } */

        /* Use the PRE-CREATED remote context from CARenderServerGetServerPort.
         * This context was created BEFORE any views exist, ensuring all layer
         * backing stores go through the server pipeline from the start. */
        if (_bridge_pre_created_context) { /* re-enabled for proper GPU rendering */
            /* Set the pre-created context as UIWindow's _layerContext */
            Ivar lcIvar = class_getInstanceVariable(object_getClass(self), "_layerContext");
            if (lcIvar) {
                ((id(*)(id, SEL))objc_msgSend)(_bridge_pre_created_context, sel_registerName("retain"));
                *(id *)((uint8_t *)self + ivar_getOffset(lcIvar)) = _bridge_pre_created_context;

                /* Set the window's layer as the context's layer */
                id rootLayer = ((id(*)(id, SEL))objc_msgSend)(self, sel_registerName("layer"));
                if (rootLayer) {
                    SEL setLayerSel = sel_registerName("setLayer:");
                    if ([_bridge_pre_created_context respondsToSelector:setLayerSel]) {
                        ((void(*)(id, SEL, id))objc_msgSend)(
                            _bridge_pre_created_context, setLayerSel, rootLayer);
                    }
                }

                unsigned int cid = 0;
                if ([_bridge_pre_created_context respondsToSelector:sel_registerName("contextId")])
                    cid = ((unsigned int(*)(id, SEL))objc_msgSend)(
                        _bridge_pre_created_context, sel_registerName("contextId"));
                bridge_log("  UIWindow: using PRE-CREATED remote context (contextId=%u)", cid);
            }
        } else {
            bridge_log("  UIWindow: no pre-created context — creating fresh");
        }

        /* Also set _attachable for proper UIKit behavior */
        Ivar attachIvar = class_getInstanceVariable(object_getClass(self), "_attachable");
        if (attachIvar) {
            *(BOOL *)((uint8_t *)self + ivar_getOffset(attachIvar)) = YES;
            bridge_log("  Set UIWindow._attachable=YES");
        }
        /* Let UIKit's _createContextAttached: handle context creation naturally.
         * With GSGetPurpleApplicationPort returning a valid port (via bootstrap_fix),
         * UIKit's REMOTE path should work:
         *   1. _shouldUseRemoteContext → YES (rendersLocally=NO)
         *   2. setClientPort(GSGetPurpleApplicationPort())
         *   3. remoteContextWithOptions: → connect_remote()
         */
        {
            bridge_log("  Calling UIKit's _createContextAttached:YES (natural path)");
            SEL createCtxSel = sel_registerName("_createContextAttached:");
            if ([(id)self respondsToSelector:createCtxSel]) {
                ((void(*)(id, SEL, BOOL))objc_msgSend)(self, createCtxSel, YES);
            }
            /* Check what UIKit created */
            Ivar lcIvar = class_getInstanceVariable(object_getClass(self), "_layerContext");
            id layerCtx = lcIvar ? *(id *)((uint8_t *)self + ivar_getOffset(lcIvar)) : nil;
            if (layerCtx) {
                unsigned int cid = [(id)layerCtx respondsToSelector:sel_registerName("contextId")] ?
                    ((unsigned int(*)(id, SEL))objc_msgSend)(layerCtx, sel_registerName("contextId")) : 0;
                /* Check renderContext */
                void *rc = nil;
                SEL rcSel = sel_registerName("renderContext");
                if ([(id)layerCtx respondsToSelector:rcSel]) {
                    rc = ((void *(*)(id, SEL))objc_msgSend)(layerCtx, rcSel);
                }
                /* Read connect_remote output fields from the CA::Context C++ object.
                 * Layout from disassembly: client_id at +0x58, field_0x60 at +0x60,
                 * renderContext at +0x70, server_port at +0x98 */
                {
                    /* Get the C++ impl pointer from the ObjC wrapper */
                    Ivar implIvar = class_getInstanceVariable(object_getClass(layerCtx), "_impl");
                    if (implIvar) {
                        void *impl = *(void **)((uint8_t *)layerCtx + ivar_getOffset(implIvar));
                        if (impl) {
                            uint32_t client_id = *(uint32_t *)((uint8_t *)impl + 0x58);
                            uint32_t field_60 = *(uint32_t *)((uint8_t *)impl + 0x60);
                            void *render_ctx = *(void **)((uint8_t *)impl + 0x70);
                            uint32_t srv_port = *(uint32_t *)((uint8_t *)impl + 0x98);
                                        /* Also read the ENCODER's contextId at offset 0x48.
                             * This is what commit_transaction sends to the server.
                             * It might differ from client_id at 0x58 (ObjC accessor). */
                            uint32_t encoder_ctx_id = *(uint32_t *)((uint8_t *)impl + 0x48);
                            /* Also read flags at 0xD0 (bit 0 = dead from SEND_INVALID_DEST)
                             * and commit_count at 0x90 */
                            uint32_t ctx_flags = *(uint32_t *)((uint8_t *)impl + 0xD0);
                            uint32_t commit_cnt = *(uint32_t *)((uint8_t *)impl + 0x90);
                            void *root_layer = *(void **)((uint8_t *)impl + 0x68);
                            /* Also scan nearby offsets for the real contextId */
                            uint32_t f40 = *(uint32_t *)((uint8_t *)impl + 0x40);
                            uint32_t f44 = *(uint32_t *)((uint8_t *)impl + 0x44);
                            uint32_t f4C = *(uint32_t *)((uint8_t *)impl + 0x4C);
                            uint32_t f50 = *(uint32_t *)((uint8_t *)impl + 0x50);
                            uint32_t f54 = *(uint32_t *)((uint8_t *)impl + 0x54);
                            bridge_log("  CA::Context: rootLayer=%p", root_layer);
                            /* Hex dump offsets 0x50-0xB0 to include 0xa4 (commit_root local_id check) */
                            {
                                char hex[768] = {0};
                                int hlen = 0;
                                for (int off = 0x50; off < 0xB0 && hlen < 700; off += 4) {
                                    uint32_t v = *(uint32_t *)((uint8_t *)impl + off);
                                    hlen += snprintf(hex + hlen, sizeof(hex) - hlen,
                                                     "+%02x=%08x ", off, v);
                                }
                                bridge_log("  CA::Context hex: %s", hex);
                                /* commit_root gate: compares LAYER->0xa4 with CONTEXT->0x5c.
                                 * Root layer is at context offset 0x68 (a CFTypeRef/CALayerRef).
                                 * Need CALayerGetLayer() to get the C++ CA::Layer* from it. */
                                uint32_t ctx_local_id = *(uint32_t *)((uint8_t *)impl + 0x5c);
                                void *layer_ref = *(void **)((uint8_t *)impl + 0x68);
                                bridge_log("  commit_root: ctx->0x5c(local_id)=%u rootLayerRef=%p",
                                           ctx_local_id, layer_ref);
                                /* Also check context 0xa0 (encoder_cache) and 0xa4 */
                                void *encoder_cache = *(void **)((uint8_t *)impl + 0xA0);
                                uint32_t ctx_0xa4 = *(uint32_t *)((uint8_t *)impl + 0xA4);
                                bridge_log("  commit: ctx->0xA0(encoder_cache)=%p ctx->0xA4=%u",
                                           encoder_cache, ctx_0xa4);
                            }
                            bridge_log("  CA::Context fields: encoder_ctxId=0x%08x(%u) client_id=0x%08x(%u) "
                                       "slot=%u renderCtx=%p server_port=%u flags=0x%x commits=%u",
                                       encoder_ctx_id, encoder_ctx_id,
                                       client_id, client_id,
                                       field_60, render_ctx, srv_port, ctx_flags, commit_cnt);
                        }
                    }
                }

                bridge_log("  UIKit created _layerContext: contextId=%u renderContext=%p (%s)",
                           cid, rc, rc ? "REMOTE" : "LOCAL (normal for remote context)");

                /* Write contextId to IPC file for CALayerHost.
                 * The ObjC [CAContext contextId] returns client_id (offset 0x58),
                 * which is set by RegisterClient. The server creates a
                 * CA::Render::Context with this ID.
                 * Also write the client_id from the C++ impl for comparison. */
                {
                    Ivar implIvar2 = class_getInstanceVariable(object_getClass(layerCtx), "_impl");
                    void *impl2 = implIvar2 ? *(void **)((uint8_t *)layerCtx + ivar_getOffset(implIvar2)) : NULL;
                    uint32_t c_client_id = impl2 ? *(uint32_t *)((uint8_t *)impl2 + 0x58) : 0;
                    /* Use ObjC contextId (== client_id at 0x58) */
                    uint32_t write_id = cid;
                    if (write_id != 0) {
                        int fd = open(ROSETTASIM_FB_CONTEXT_PATH, O_WRONLY|O_CREAT|O_TRUNC, 0644);
                        if (fd >= 0) {
                            char buf[32];
                            int len = snprintf(buf, sizeof(buf), "%u", write_id);
                            write(fd, buf, len);
                            close(fd);
                            bridge_log("  Wrote contextId=%u (c_client_id=%u) to %s",
                                       write_id, c_client_id, ROSETTASIM_FB_CONTEXT_PATH);
                        }
                    }
                }
            } else {
                bridge_log("  UIKit's _createContextAttached: returned nil _layerContext!");
            }
            if (0) { /* DISABLED: manual context creation */
                Class caCtxClass = objc_getClass("CAContext");
                SEL remCtxSel = sel_registerName("remoteContextWithOptions:");
                (void)caCtxClass; (void)remCtxSel;
                id remoteCtx = nil;
                if (remoteCtx) {
                    /* Set the window's root layer as the context's layer */
                    id rootLayer = ((id(*)(id, SEL))objc_msgSend)(self, sel_registerName("layer"));
                    if (rootLayer) {
                        SEL setLayerSel = sel_registerName("setLayer:");
                        if ([(id)remoteCtx respondsToSelector:setLayerSel]) {
                            ((void(*)(id, SEL, id))objc_msgSend)(remoteCtx, setLayerSel, rootLayer);
                        }
                    }
                    /* Set as the UIWindow's _layerContext */
                    Ivar lcIvar2 = class_getInstanceVariable(object_getClass(self), "_layerContext");
                    if (lcIvar2) {
                        ((id(*)(id, SEL))objc_msgSend)(remoteCtx, sel_registerName("retain"));
                        *(id *)((uint8_t *)self + ivar_getOffset(lcIvar2)) = remoteCtx;
                    }
                    unsigned int cid = [(id)remoteCtx respondsToSelector:sel_registerName("contextId")] ?
                        ((unsigned int(*)(id, SEL))objc_msgSend)(remoteCtx, sel_registerName("contextId")) : 0;
                    bridge_log("  UIWindow: REMOTE context created (contextId=%u, displayable=YES)", cid);
                } else {
                    bridge_log("  UIWindow: remoteContextWithOptions returned nil — falling back");
                    SEL createCtxSel2 = sel_registerName("_createContextAttached:");
                    if ([(id)self respondsToSelector:createCtxSel2])
                        ((void(*)(id, SEL, BOOL))objc_msgSend)(self, createCtxSel2, YES);
                }
            } else {
                /* Fallback */
                SEL createCtxSel2 = sel_registerName("_createContextAttached:");
                if ([(id)self respondsToSelector:createCtxSel2])
                    ((void(*)(id, SEL, BOOL))objc_msgSend)(self, createCtxSel2, YES);
            }
        }
    } else {
        /* Fallback: if we couldn't save the original IMP, do manual setup.
         * This shouldn't happen but prevents a dead-end. */
        bridge_log("  WARNING: No original IMP — manual fallback");

        /* Show window */
        ((void(*)(id, SEL, bool))objc_msgSend)(self, sel_registerName("setHidden:"), false);

        /* Use _makeKeyWindowIgnoringOldKeyWindow: for local key window registration.
         * This registers the window with UIGestureEnvironment WITHOUT going through
         * the full makeKeyAndVisible path. */
        SEL mkwSel = sel_registerName("_makeKeyWindowIgnoringOldKeyWindow:");
        if (class_respondsToSelector(object_getClass(self), mkwSel)) {
            @try {
                ((void(*)(id, SEL, bool))objc_msgSend)(self, mkwSel, true);
                bridge_log("  Called _makeKeyWindowIgnoringOldKeyWindow:YES");
            } @catch (id e) {
                bridge_log("  _makeKeyWindowIgnoringOldKeyWindow threw");
            }
        } else {
            /* Even more minimal fallback — call makeKeyWindow */
            @try {
                ((void(*)(id, SEL))objc_msgSend)(self, sel_registerName("makeKeyWindow"));
            } @catch (id e) { /* ignore */ }
        }

        /* Install rootVC if present */
        SEL rvcSel = sel_registerName("rootViewController");
        if (class_respondsToSelector(object_getClass(self), rvcSel)) {
            id rootVC = ((id(*)(id, SEL))objc_msgSend)(self, rvcSel);
            if (rootVC) {
                id rootView = ((id(*)(id, SEL))objc_msgSend)(rootVC, sel_registerName("view"));
                if (rootView) {
                    id superview = ((id(*)(id, SEL))objc_msgSend)(
                        rootView, sel_registerName("superview"));
                    if (!superview || superview != self) {
                        _RSBridgeCGRect windowFrame = {0, 0, kScreenWidth, kScreenHeight};
                        typedef void (*setFrameFn)(id, SEL, _RSBridgeCGRect);
                        ((setFrameFn)objc_msgSend)(rootView,
                            sel_registerName("setFrame:"), windowFrame);
                        ((void(*)(id, SEL, id))objc_msgSend)(self,
                            sel_registerName("addSubview:"), rootView);
                    }
                }
            }
        }

        ((void(*)(id, SEL))objc_msgSend)(self, sel_registerName("setNeedsLayout"));
        ((void(*)(id, SEL))objc_msgSend)(self, sel_registerName("layoutIfNeeded"));
    }

    bridge_log("  Window %p made key (stack: %d windows)", (void *)self, _bridge_window_count);
}

/* Replacement for -[UIWindow isKeyWindow].
   Returns YES for the current key window in the window stack. */
static bool replacement_isKeyWindow(id self, SEL _cmd) {
    return (self == _bridge_key_window);
}

/* Replacement for -[UIApplication keyWindow].
   Returns the current key window from the window stack. */
static id replacement_keyWindow(id self, SEL _cmd) {
    return _bridge_key_window ? _bridge_key_window : _bridge_root_window;
}

/* ================================================================
 * UIApplication._runWithMainScene:transitionContext:completion:
 *
 * The original method:
 *   1. Connects to FBSWorkspace via XPC
 *   2. Requests scene creation from SpringBoard
 *   3. Waits on dispatch_semaphore for reply (HANGS without SpringBoard)
 *   4. Creates UIEventDispatcher
 *   5. Calls completion block (triggers didFinishLaunching)
 *   6. Starts CFRunLoopRun
 *
 * Our replacement does steps 4-6, skipping the FBSWorkspace connection
 * (steps 1-3) since there is no SpringBoard in RosettaSim.
 *
 * This lets UIApplicationMain complete naturally. UIKit creates
 * UIEventDispatcher, UIEventEnvironment, and UIGestureEnvironment
 * itself — no manual object creation needed.
 * ================================================================ */

static void replacement_runWithMainScene(id self, SEL _cmd,
                                          id scene,
                                          id transitionContext,
                                          id completionBlock) {
    bridge_log("_runWithMainScene: intercepted — bypassing FBSWorkspace");

    /* Create UIEventDispatcher — normally done by _runWithMainScene before
     * the completion block fires. This creates:
     *   - UIEventFetcher (HID event collection)
     *   - UIEventEnvironment (holds _touchesEvent singleton)
     *   - Run loop sources for event processing
     */
    {
        Class dispatcherClass = objc_getClass("UIEventDispatcher");
        if (dispatcherClass) {
            @try {
                id dispatcher = ((id(*)(id, SEL))objc_msgSend)(
                    (id)dispatcherClass, sel_registerName("alloc"));
                SEL initWithAppSel = sel_registerName("initWithApplication:");
                if (class_respondsToSelector(dispatcherClass, initWithAppSel)) {
                    dispatcher = ((id(*)(id, SEL, id))objc_msgSend)(
                        dispatcher, initWithAppSel, self);
                } else {
                    dispatcher = ((id(*)(id, SEL))objc_msgSend)(
                        dispatcher, sel_registerName("init"));
                }
                if (dispatcher) {
                    Ivar edIvar = class_getInstanceVariable(
                        object_getClass(self), "_eventDispatcher");
                    if (edIvar) {
                        *(id *)((uint8_t *)self + ivar_getOffset(edIvar)) = dispatcher;
                        ((id(*)(id, SEL))objc_msgSend)(dispatcher, sel_registerName("retain"));
                        bridge_log("  UIEventDispatcher created: %p", (void *)dispatcher);

                        /* Install event run loop sources on main run loop */
                        SEL installSel = sel_registerName("_installEventRunLoopSources:");
                        if (class_respondsToSelector(object_getClass(dispatcher), installSel)) {
                            @try {
                                ((void(*)(id, SEL, CFRunLoopRef))objc_msgSend)(
                                    dispatcher, installSel, CFRunLoopGetMain());
                                bridge_log("  Installed event run loop sources");
                            } @catch (id e) {
                                bridge_log("  _installEventRunLoopSources threw exception");
                            }
                        }
                    } else {
                        bridge_log("  WARN: _eventDispatcher ivar not found");
                    }
                }
            } @catch (id e) {
                bridge_log("  UIEventDispatcher creation failed: exception");
            }
        } else {
            bridge_log("  UIEventDispatcher class not found");
        }
    }

    /* Pre-warm UIGestureEnvironment by sending a synthetic dummy touch.
     *
     * UIGestureEnvironment performs lazy one-time initialization on the first
     * touch delivery through sendEvent:. This initialization causes a SIGSEGV
     * (likely dereferencing uninitialized internal pointers), but the state IS
     * actually set up despite the crash. Subsequent touches work perfectly with
     * full gesture recognizer support (UIButton tap, UITextField tap, etc.).
     *
     * By triggering this crash at startup (caught by our SIGSEGV guard), we
     * ensure all real user touches work from the first interaction. */
    {
        bridge_log("  Pre-warming UIGestureEnvironment with synthetic touch...");

        /* Install SIGSEGV/SIGBUS handlers if not already */
        if (!_sendEvent_handlers_installed) {
            struct sigaction sa;
            memset(&sa, 0, sizeof(sa));
            sa.sa_sigaction = _sendEvent_crash_handler_siginfo;
                        sa.sa_flags = SA_SIGINFO;
            sigemptyset(&sa.sa_mask);
            sa.sa_flags = 0;
            sigaction(SIGSEGV, &sa, &_prev_sigsegv_action);
            sigaction(SIGBUS, &sa, &_prev_sigbus_action);
            _sendEvent_handlers_installed = 1;
        }

        /* Get the _touchesEvent singleton */
        SEL touchesEventSel = sel_registerName("_touchesEvent");
        id warmupEvent = nil;
        if (class_respondsToSelector(object_getClass(self), touchesEventSel)) {
            @try {
                warmupEvent = ((id(*)(id, SEL))objc_msgSend)(self, touchesEventSel);
            } @catch (id e) { warmupEvent = nil; }
        }

        /* Create a fallback event if singleton unavailable */
        int warmupEvent_owned = 0; /* Track if we need to release */
        if (!warmupEvent) {
            Class teClass = objc_getClass("UITouchesEvent");
            if (teClass) {
                @try {
                    warmupEvent = ((id(*)(id, SEL))objc_msgSend)(
                        ((id(*)(id, SEL))objc_msgSend)((id)teClass, sel_registerName("alloc")),
                        sel_registerName("_init"));
                    warmupEvent_owned = (warmupEvent != nil);
                } @catch (id e) { warmupEvent = nil; }
            }
        }

        if (warmupEvent) {
            Class touchClass = objc_getClass("UITouch");
            if (touchClass) {
                /* Send 2 synthetic began+ended cycles to fully warm up.
                 * Empirically, the first 1-2 touches crash; sending 2 cycles
                 * ensures the initialization completes. */
                for (int warmup_i = 0; warmup_i < 2; warmup_i++) {
                    id dummyTouch = ((id(*)(id, SEL))objc_msgSend)(
                        ((id(*)(id, SEL))objc_msgSend)((id)touchClass, sel_registerName("alloc")),
                        sel_registerName("init"));
                    if (!dummyTouch) break;

                    /* Set minimal touch properties */
                    _RSBridgeCGPoint origin = {0.0, 0.0};
                    @try {
                        ((void(*)(id, SEL, long))objc_msgSend)(dummyTouch,
                            sel_registerName("setPhase:"), 0 /* UITouchPhaseBegan */);
                        SEL setLocSel = sel_registerName("_setLocationInWindow:resetPrevious:");
                        if (class_respondsToSelector(object_getClass(dummyTouch), setLocSel)) {
                            typedef void (*setLoc_fn)(id, SEL, _RSBridgeCGPoint, bool);
                            ((setLoc_fn)objc_msgSend)(dummyTouch, setLocSel, origin, true);
                        }
                        ((void(*)(id, SEL, double))objc_msgSend)(dummyTouch,
                            sel_registerName("setTimestamp:"),
                            (double)mach_absolute_time() / 1e9);
                    } @catch (id e) { /* continue anyway */ }

                    /* Clear + add touch + sendEvent (crash-guarded) */
                    @try {
                        ((void(*)(id, SEL))objc_msgSend)(warmupEvent,
                            sel_registerName("_clearTouches"));
                    } @catch (id e) { /* ignore */ }

                    /* Try _addTouch:forDelayedDelivery:NO */
                    _sendEvent_guard_active = 1;
                    int warmup_crash = sigsetjmp(_sendEvent_recovery, 1);
                    if (warmup_crash == 0) {
                        @try {
                            typedef void (*addTouchFn)(id, SEL, id, bool);
                            ((addTouchFn)objc_msgSend)(warmupEvent,
                                sel_registerName("_addTouch:forDelayedDelivery:"),
                                dummyTouch, false);
                        } @catch (id e) { /* ignore */ }
                        _sendEvent_guard_active = 0;
                    } else {
                        bridge_log("  Warmup %d: _addTouch crashed (signal %d) — expected",
                                   warmup_i + 1, warmup_crash);
                        _sendEvent_guard_active = 0;
                        ((void(*)(id, SEL))objc_msgSend)(dummyTouch, sel_registerName("release"));
                        continue;
                    }

                    /* Try sendEvent: */
                    _sendEvent_guard_active = 1;
                    warmup_crash = sigsetjmp(_sendEvent_recovery, 1);
                    if (warmup_crash == 0) {
                        @try {
                            ((void(*)(id, SEL, id))objc_msgSend)(self,
                                sel_registerName("sendEvent:"), warmupEvent);
                        } @catch (id e) { /* ignore */ }
                        _sendEvent_guard_active = 0;
                        bridge_log("  Warmup %d: sendEvent: succeeded", warmup_i + 1);
                    } else {
                        bridge_log("  Warmup %d: sendEvent: crashed (signal %d) — expected",
                                   warmup_i + 1, warmup_crash);
                        _sendEvent_guard_active = 0;
                    }

                    /* Send ended phase to clean up */
                    @try {
                        ((void(*)(id, SEL, long))objc_msgSend)(dummyTouch,
                            sel_registerName("setPhase:"), 3 /* UITouchPhaseEnded */);
                        ((void(*)(id, SEL))objc_msgSend)(warmupEvent,
                            sel_registerName("_clearTouches"));
                        typedef void (*addTouchFn)(id, SEL, id, bool);
                        _sendEvent_guard_active = 1;
                        warmup_crash = sigsetjmp(_sendEvent_recovery, 1);
                        if (warmup_crash == 0) {
                            ((addTouchFn)objc_msgSend)(warmupEvent,
                                sel_registerName("_addTouch:forDelayedDelivery:"),
                                dummyTouch, false);
                            ((void(*)(id, SEL, id))objc_msgSend)(self,
                                sel_registerName("sendEvent:"), warmupEvent);
                            _sendEvent_guard_active = 0;
                        } else {
                            _sendEvent_guard_active = 0;
                        }
                    } @catch (id e) { /* cleanup best-effort */ }

                    ((void(*)(id, SEL))objc_msgSend)(dummyTouch, sel_registerName("release"));
                }
                bridge_log("  UIGestureEnvironment pre-warm complete");
            }
            /* Release fallback event if we created it (not the singleton) */
            if (warmupEvent_owned && warmupEvent) {
                ((void(*)(id, SEL))objc_msgSend)(warmupEvent, sel_registerName("release"));
            }
        } else {
            bridge_log("  WARN: No UITouchesEvent available for pre-warm");
        }

        /* Reset _addTouch_known_broken since pre-warm may have set it */
        _addTouch_known_broken = 0;
    }

    /* ================================================================
     * SYNTHETIC FBSScene + DISPLAY PIPELINE
     *
     * Create a real FBSScene backed by CARenderServer's CADisplay.
     * This wires UIKit's display pipeline to GPU-composited rendering:
     *   CADisplay → FBSDisplay → FBSScene → UIScreen → UIWindow → CARenderServer
     *
     * UIKit's __createPlugInScreenForFBSDisplay: proves this works without
     * FBSWorkspace. The key call is [UIScreen _FBSDisplayDidPossiblyConnect:withScene:].
     * ================================================================ */
    id syntheticScene = nil;
    {
        bridge_log("  Creating synthetic FBSScene for CARenderServer display...");

        @try {
            /* Step 1: Get CADisplay from CARenderServer */
            id displays = ((id(*)(id, SEL))objc_msgSend)(
                (id)objc_getClass("CADisplay"), sel_registerName("displays"));
            NSUInteger displayCount = displays ? ((NSUInteger(*)(id, SEL))objc_msgSend)(
                displays, sel_registerName("count")) : 0;
            bridge_log("  CADisplay displays count=%lu", (unsigned long)displayCount);

            id mainDisplay = nil;
            if (displayCount > 0) {
                mainDisplay = ((id(*)(id, SEL, NSUInteger))objc_msgSend)(
                    displays, sel_registerName("objectAtIndex:"), (NSUInteger)0);
                bridge_log("  CADisplay[0] = %p", (void *)mainDisplay);
            }

            if (mainDisplay) {
                /* Step 2: Create FBSDisplay wrapping the CADisplay */
                Class fbsDisplayClass = objc_getClass("FBSDisplay");
                id fbsDisplay = nil;

                if (fbsDisplayClass) {
                    /* Try +displayWithCADisplay: */
                    SEL displayWithCA = sel_registerName("displayWithCADisplay:");
                    if (class_respondsToSelector(object_getClass((id)fbsDisplayClass), displayWithCA)) {
                        fbsDisplay = ((id(*)(id, SEL, id))objc_msgSend)(
                            (id)fbsDisplayClass, displayWithCA, mainDisplay);
                        bridge_log("  FBSDisplay.displayWithCADisplay: = %p", (void *)fbsDisplay);
                    }

                    if (!fbsDisplay) {
                        /* Try -initWithDisplay: or -initWithCADisplay: */
                        id alloc = ((id(*)(id, SEL))objc_msgSend)(
                            (id)fbsDisplayClass, sel_registerName("alloc"));
                        SEL initDisplay = sel_registerName("initWithDisplay:");
                        if (class_respondsToSelector(fbsDisplayClass, initDisplay)) {
                            fbsDisplay = ((id(*)(id, SEL, id))objc_msgSend)(
                                alloc, initDisplay, mainDisplay);
                            bridge_log("  FBSDisplay.initWithDisplay: = %p", (void *)fbsDisplay);
                        }
                    }

                    if (!fbsDisplay) {
                        /* Try +mainDisplay */
                        SEL mainDisplaySel = sel_registerName("mainDisplay");
                        if (class_respondsToSelector(object_getClass((id)fbsDisplayClass), mainDisplaySel)) {
                            fbsDisplay = ((id(*)(id, SEL))objc_msgSend)(
                                (id)fbsDisplayClass, mainDisplaySel);
                            bridge_log("  FBSDisplay.mainDisplay = %p", (void *)fbsDisplay);
                        }
                    }
                } else {
                    bridge_log("  WARNING: FBSDisplay class not found");
                }

                if (fbsDisplay) {
                    /* Step 3: Wire UIScreen to the FBSDisplay + scene.
                     * [UIScreen _FBSDisplayDidPossiblyConnect:withScene:andPost:] */
                    Class uiScreenClass = objc_getClass("UIScreen");
                    SEL connectSel = sel_registerName("_FBSDisplayDidPossiblyConnect:withScene:andPost:");

                    if (class_respondsToSelector(object_getClass((id)uiScreenClass), connectSel)) {
                        /* Create a minimal FBSScene */
                        Class sceneClass = objc_getClass("FBSScene");
                        if (sceneClass) {
                            /* Try initWithQueue:identifier:display:settings:clientSettings: */
                            SEL sceneInitSel = sel_registerName("initWithQueue:identifier:display:settings:clientSettings:");
                            id sceneAlloc = ((id(*)(id, SEL))objc_msgSend)(
                                (id)sceneClass, sel_registerName("alloc"));

                            /* Create scene settings */
                            Class settingsClass = objc_getClass("UIMutableApplicationSceneSettings");
                            id sceneSettings = nil;
                            if (settingsClass) {
                                sceneSettings = ((id(*)(id, SEL))objc_msgSend)(
                                    ((id(*)(id, SEL))objc_msgSend)(
                                        (id)settingsClass, sel_registerName("alloc")),
                                    sel_registerName("init"));
                            }

                            Class clientSettingsClass = objc_getClass("UIMutableApplicationSceneClientSettings");
                            id clientSettings = nil;
                            if (clientSettingsClass) {
                                clientSettings = ((id(*)(id, SEL))objc_msgSend)(
                                    ((id(*)(id, SEL))objc_msgSend)(
                                        (id)clientSettingsClass, sel_registerName("alloc")),
                                    sel_registerName("init"));
                            }

                            id sceneId = ((id(*)(id, SEL, const char *))objc_msgSend)(
                                (id)objc_getClass("NSString"),
                                sel_registerName("stringWithUTF8String:"),
                                "com.apple.frontboard.default");

                            if (class_respondsToSelector(sceneClass, sceneInitSel)) {
                                syntheticScene = ((id(*)(id, SEL, id, id, id, id, id))objc_msgSend)(
                                    sceneAlloc, sceneInitSel,
                                    dispatch_get_main_queue(),
                                    sceneId,
                                    fbsDisplay,
                                    sceneSettings,
                                    clientSettings);
                                bridge_log("  FBSScene created: %p", (void *)syntheticScene);
                            } else {
                                bridge_log("  WARNING: FBSScene does not respond to initWithQueue:...");
                            }
                        }

                        if (syntheticScene || fbsDisplay) {
                            /* Verify FBSDisplay before calling */
                            @try {
                                SEL dispIdSel = sel_registerName("displayID");
                                if ([(id)fbsDisplay respondsToSelector:dispIdSel]) {
                                    unsigned int did = ((unsigned int(*)(id, SEL))objc_msgSend)(
                                        fbsDisplay, dispIdSel);
                                    bridge_log("  FBSDisplay.displayID = %u", did);
                                }
                                SEL refBoundsSel = sel_registerName("referenceBounds");
                                if ([(id)fbsDisplay respondsToSelector:refBoundsSel]) {
                                    typedef struct { double x, y, w, h; } CGRect_d;
                                    CGRect_d rb;
                                    /* stret for CGRect on x86_64 */
                                    typedef void (*StretFn)(CGRect_d *, id, SEL);
                                    ((StretFn)objc_msgSend_stret)(&rb, fbsDisplay, refBoundsSel);
                                    bridge_log("  FBSDisplay.referenceBounds = %.0fx%.0f",
                                               rb.w, rb.h);
                                }
                                if (syntheticScene) {
                                    SEL fbsDispSel = sel_registerName("fbsDisplay");
                                    if ([(id)syntheticScene respondsToSelector:fbsDispSel]) {
                                        id sd = ((id(*)(id, SEL))objc_msgSend)(
                                            syntheticScene, fbsDispSel);
                                        bridge_log("  FBSScene.fbsDisplay = %p", (void *)sd);
                                    }
                                    SEL idSel = sel_registerName("identifier");
                                    if ([(id)syntheticScene respondsToSelector:idSel]) {
                                        id sid = ((id(*)(id, SEL))objc_msgSend)(
                                            syntheticScene, idSel);
                                        bridge_log("  FBSScene.identifier = %s",
                                                   [(NSString *)sid UTF8String] ?: "(nil)");
                                    }
                                }
                            } @catch (id ex) {
                                bridge_log("  FBSDisplay/Scene verification threw: %s",
                                           [[ex description] UTF8String] ?: "unknown");
                            }

                            /* Connect UIScreen to the display */
                            bridge_log("  Calling _FBSDisplayDidPossiblyConnect NOW...");
                            @try {
                                ((void(*)(id, SEL, id, id, BOOL))objc_msgSend)(
                                    (id)uiScreenClass, connectSel,
                                    fbsDisplay, syntheticScene, YES);
                                bridge_log("  UIScreen._FBSDisplayDidPossiblyConnect: DONE");

                                /* Check if UIScreen.mainScreen is now valid */
                                id mainScreen = ((id(*)(id, SEL))objc_msgSend)(
                                    (id)uiScreenClass, sel_registerName("mainScreen"));
                                bridge_log("  UIScreen.mainScreen = %p", (void *)mainScreen);
                            } @catch (id ex) {
                                bridge_log("  UIScreen._FBSDisplayDidPossiblyConnect threw: %s",
                                           [[ex description] UTF8String] ?: "unknown");
                            }
                        }
                    } else {
                        bridge_log("  WARNING: UIScreen does not respond to _FBSDisplayDidPossiblyConnect:");
                    }
                }
            } else {
                bridge_log("  WARNING: No CADisplay available (CARenderServer not connected?)");
            }
        } @catch (id ex) {
            bridge_log("  Synthetic FBSScene creation failed: %s",
                       [[ex description] UTF8String] ?: "unknown");
        }
    }

    /* Now try calling _callInitializationDelegatesForMainScene with the synthetic scene */
    SEL callInitSel = sel_registerName("_callInitializationDelegatesForMainScene:transitionContext:");
    if (syntheticScene && class_respondsToSelector(object_getClass(self), callInitSel)) {
        bridge_log("  Calling _callInitializationDelegatesForMainScene with synthetic scene...");
        @try {
            ((void(*)(id, SEL, id, id))objc_msgSend)(
                self, callInitSel, syntheticScene, transitionContext);
            bridge_log("  _callInitializationDelegatesForMainScene completed!");
            _didFinishLaunching_called = 1;
        } @catch (id ex) {
            bridge_log("  _callInitializationDelegatesForMainScene threw: %s — falling back to manual init",
                       [[ex description] UTF8String] ?: "unknown");
            syntheticScene = nil; /* Fall through to manual init below */
        }
    }

    if (!_didFinishLaunching_called) {
        bridge_log("  Performing delegate initialization directly...");
    }

    /* Get the delegate (already set by UIApplicationMain before _run) */
    id delegate = ((id(*)(id, SEL))objc_msgSend)(self, sel_registerName("delegate"));
    if (delegate) {
        _bridge_delegate = delegate;
        ((id(*)(id, SEL))objc_msgSend)(delegate, sel_registerName("retain"));
        bridge_log("  App delegate: %s @ %p",
                   class_getName(object_getClass(delegate)), (void *)delegate);

        /* Load the main storyboard or nib if specified in Info.plist.
         * _loadMainInterfaceFile crashes with nil FBSScene, so we replicate
         * its logic: read UIMainStoryboardFile or UIMainNibFile from the
         * app's Info.plist and instantiate the initial view controller. */
        @try {
            id mainBundle = ((id(*)(id, SEL))objc_msgSend)(
                (id)objc_getClass("NSBundle"), sel_registerName("mainBundle"));
            if (mainBundle) {
                id infoDict = ((id(*)(id, SEL))objc_msgSend)(
                    mainBundle, sel_registerName("infoDictionary"));
                if (infoDict) {
                    /* Try UIMainStoryboardFile first */
                    id sbKey = ((id(*)(id, SEL, const char *))objc_msgSend)(
                        (id)objc_getClass("NSString"),
                        sel_registerName("stringWithUTF8String:"),
                        "UIMainStoryboardFile");
                    id storyboardName = ((id(*)(id, SEL, id))objc_msgSend)(
                        infoDict, sel_registerName("objectForKey:"), sbKey);

                    if (storyboardName) {
                        const char *sbNameStr = ((const char *(*)(id, SEL))objc_msgSend)(
                            storyboardName, sel_registerName("UTF8String"));
                        bridge_log("  Loading main storyboard: %s", sbNameStr ? sbNameStr : "?");

                        Class sbClass = objc_getClass("UIStoryboard");
                        if (sbClass) {
                            id sb = ((id(*)(id, SEL, id, id))objc_msgSend)(
                                (id)sbClass,
                                sel_registerName("storyboardWithName:bundle:"),
                                storyboardName, mainBundle);
                            if (sb) {
                                id initialVC = ((id(*)(id, SEL))objc_msgSend)(
                                    sb, sel_registerName("instantiateInitialViewController"));
                                if (initialVC) {
                                    bridge_log("  Initial VC from storyboard: %s",
                                               class_getName(object_getClass(initialVC)));
                                    /* Create window and install VC — delegate's
                                     * didFinishLaunching will see this window. */
                                    Class winClass = objc_getClass("UIWindow");
                                    _RSBridgeCGRect frame = {0, 0, kScreenWidth, kScreenHeight};
                                    typedef id (*initFrame_fn)(id, SEL, _RSBridgeCGRect);
                                    id window = ((initFrame_fn)objc_msgSend)(
                                        ((id(*)(id, SEL))objc_msgSend)(
                                            (id)winClass, sel_registerName("alloc")),
                                        sel_registerName("initWithFrame:"), frame);
                                    if (window) {
                                        ((void(*)(id, SEL, id))objc_msgSend)(
                                            window, sel_registerName("setRootViewController:"),
                                            initialVC);
                                        /* Set on delegate's window property if available */
                                        SEL setWindowSel = sel_registerName("setWindow:");
                                        if (class_respondsToSelector(
                                                object_getClass(delegate), setWindowSel)) {
                                            ((void(*)(id, SEL, id))objc_msgSend)(
                                                delegate, setWindowSel, window);
                                        }
                                        bridge_log("  Storyboard window created (will makeKeyAndVisible after didFinish)");
                                    }
                                }
                            }
                        }
                    } else {
                        /* Try UIMainNibFile */
                        id nibKey = ((id(*)(id, SEL, const char *))objc_msgSend)(
                            (id)objc_getClass("NSString"),
                            sel_registerName("stringWithUTF8String:"),
                            "NSMainNibFile");
                        id nibName = ((id(*)(id, SEL, id))objc_msgSend)(
                            infoDict, sel_registerName("objectForKey:"), nibKey);
                        if (nibName) {
                            const char *nibNameStr = ((const char *(*)(id, SEL))objc_msgSend)(
                                nibName, sel_registerName("UTF8String"));
                            bridge_log("  Loading main nib: %s", nibNameStr ? nibNameStr : "?");
                            @try {
                                Class nibClass = objc_getClass("UINib");
                                if (nibClass) {
                                    id nib = ((id(*)(id, SEL, id, id))objc_msgSend)(
                                        (id)nibClass,
                                        sel_registerName("nibWithNibName:bundle:"),
                                        nibName, mainBundle);
                                    if (nib) {
                                        ((id(*)(id, SEL, id, id))objc_msgSend)(
                                            nib,
                                            sel_registerName("instantiateWithOwner:options:"),
                                            delegate, nil);
                                        bridge_log("  Main nib loaded");
                                    }
                                }
                            } @catch (id e) {
                                bridge_log("  Nib loading failed");
                            }
                        }
                    }
                }
            }
        } @catch (id e) {
            bridge_log("  Main interface loading failed (continuing without it)");
        }

        /* Call application:didFinishLaunchingWithOptions: */
        SEL didFinishSel = sel_registerName("application:didFinishLaunchingWithOptions:");
        if (class_respondsToSelector(object_getClass(delegate), didFinishSel)) {
            bridge_log("  Calling application:didFinishLaunchingWithOptions:");
            @try {
                ((void(*)(id, SEL, id, id))objc_msgSend)(
                    delegate, didFinishSel, self, nil);
                bridge_log("  didFinishLaunchingWithOptions: completed");
                _didFinishLaunching_called = 1;
            } @catch (id e) {
                bridge_log("  didFinishLaunchingWithOptions: threw exception");
            }
        }
    }

    /* Post UIApplicationDidFinishLaunchingNotification */
    {
        Class nsCenterClass = objc_getClass("NSNotificationCenter");
        id center = nsCenterClass ? ((id(*)(id, SEL))objc_msgSend)(
            (id)nsCenterClass, sel_registerName("defaultCenter")) : nil;
        if (center) {
            id notifName = ((id(*)(id, SEL, const char *))objc_msgSend)(
                (id)objc_getClass("NSString"),
                sel_registerName("stringWithUTF8String:"),
                "UIApplicationDidFinishLaunchingNotification");
            ((void(*)(id, SEL, id, id, id))objc_msgSend)(
                center, sel_registerName("postNotificationName:object:userInfo:"),
                notifName, self, nil);
            bridge_log("  Posted UIApplicationDidFinishLaunchingNotification");

            /* Call applicationDidBecomeActive: */
            if (delegate) {
                SEL didBecomeActiveSel = sel_registerName("applicationDidBecomeActive:");
                if (class_respondsToSelector(object_getClass(delegate), didBecomeActiveSel)) {
                    @try {
                        ((void(*)(id, SEL, id))objc_msgSend)(delegate, didBecomeActiveSel, self);
                        bridge_log("  Called applicationDidBecomeActive:");
                    } @catch (id e) { /* ignore */ }
                }
            }

            /* Post UIApplicationDidBecomeActiveNotification */
            notifName = ((id(*)(id, SEL, const char *))objc_msgSend)(
                (id)objc_getClass("NSString"),
                sel_registerName("stringWithUTF8String:"),
                "UIApplicationDidBecomeActiveNotification");
            ((void(*)(id, SEL, id, id, id))objc_msgSend)(
                center, sel_registerName("postNotificationName:object:userInfo:"),
                notifName, self, nil);
            bridge_log("  Posted UIApplicationDidBecomeActiveNotification");
        }
    }

    /* Scene lifecycle fix: if didFinishLaunching didn't call makeKeyAndVisible
     * (apps like Preferences.app that depend on FBSScene lifecycle), try to
     * force the app's windows visible. Without this, many Apple system apps
     * never show their UI because they wait for scene activation events. */
    if (!_bridge_root_window) {
        bridge_log("  No root window after didFinishLaunching — trying scene lifecycle fix...");

        /* Try loading the main storyboard/nib if the app has one.
         * Many system apps define UIMainStoryboardFile in Info.plist but only
         * load it when the scene lifecycle triggers. */
        @try {
            id mainBundle = ((id(*)(id, SEL))objc_msgSend)(
                (id)objc_getClass("NSBundle"), sel_registerName("mainBundle"));
            if (mainBundle) {
                id storyboardName = ((id(*)(id, SEL, id))objc_msgSend)(
                    ((id(*)(id, SEL))objc_msgSend)(mainBundle, sel_registerName("infoDictionary")),
                    sel_registerName("objectForKey:"),
                    ((id(*)(id, SEL, const char *))objc_msgSend)(
                        (id)objc_getClass("NSString"),
                        sel_registerName("stringWithUTF8String:"),
                        "UIMainStoryboardFile"));
                if (storyboardName) {
                    bridge_log("  Loading main storyboard: %s",
                               ((const char *(*)(id, SEL))objc_msgSend)(
                                   storyboardName, sel_registerName("UTF8String")));
                    Class sbClass = objc_getClass("UIStoryboard");
                    if (sbClass) {
                        id sb = ((id(*)(id, SEL, id, id))objc_msgSend)(
                            (id)sbClass,
                            sel_registerName("storyboardWithName:bundle:"),
                            storyboardName, mainBundle);
                        if (sb) {
                            id initialVC = ((id(*)(id, SEL))objc_msgSend)(
                                sb, sel_registerName("instantiateInitialViewController"));
                            if (initialVC) {
                                bridge_log("  Created initial view controller: %s",
                                           class_getName(object_getClass(initialVC)));
                                /* Create a window and install the VC */
                                Class winClass = objc_getClass("UIWindow");
                                _RSBridgeCGRect frame = {0, 0, kScreenWidth, kScreenHeight};
                                typedef id (*initFrame_fn)(id, SEL, _RSBridgeCGRect);
                                id window = ((initFrame_fn)objc_msgSend)(
                                    ((id(*)(id, SEL))objc_msgSend)((id)winClass, sel_registerName("alloc")),
                                    sel_registerName("initWithFrame:"), frame);
                                if (window) {
                                    ((void(*)(id, SEL, id))objc_msgSend)(
                                        window, sel_registerName("setRootViewController:"), initialVC);
                                    replacement_makeKeyAndVisible(window, sel_registerName("makeKeyAndVisible"));
                                    bridge_log("  Storyboard window made key and visible");
                                }
                            }
                        }
                    }
                }
            }
        } @catch (id e) {
            bridge_log("  Storyboard loading failed — falling back to window search");
        }
    }

    /* Fallback: if still no root window, search existing UIWindow instances */
    if (!_bridge_root_window) {
        Class appClass = objc_getClass("UIApplication");
        if (appClass) {
            id app = ((id(*)(id, SEL))objc_msgSend)((id)appClass, sel_registerName("sharedApplication"));
            if (app) {
                id windows = ((id(*)(id, SEL))objc_msgSend)(app, sel_registerName("windows"));
                if (windows) {
                    long count = ((long(*)(id, SEL))objc_msgSend)(windows, sel_registerName("count"));
                    bridge_log("  Searching %ld existing windows for content...", count);
                    for (long i = 0; i < count; i++) {
                        id win = ((id(*)(id, SEL, long))objc_msgSend)(
                            windows, sel_registerName("objectAtIndex:"), i);
                        if (win) {
                            id rootVC = ((id(*)(id, SEL))objc_msgSend)(
                                win, sel_registerName("rootViewController"));
                            if (rootVC) {
                                bridge_log("  Found window %ld with rootVC %s — making visible",
                                           i, class_getName(object_getClass(rootVC)));
                                replacement_makeKeyAndVisible(win, sel_registerName("makeKeyAndVisible"));
                                break;
                            }
                        }
                    }
                }
            }
        }
    }

    /* ================================================================
     * Display Pipeline: FBSScene + CARenderServer
     *
     * Strategy: Create a synthetic FBSScene backed by the real CADisplay
     * from CARenderServer. Call UIScreen._FBSDisplayDidPossiblyConnect:
     * to wire UIScreen to the display. This makes UIKit set up the REAL
     * display pipeline:
     *   - UIScreen gets the CADisplay
     *   - UIWindow renders through CARenderServer
     *   - CARenderServer composites onto the PurpleDisplay surface
     *   - The sync thread in purple_fb_server copies to shared framebuffer
     *
     * If this fails, fall back to CPU rendering (find_root_window +
     * start_frame_capture with renderInContext).
     * ================================================================ */
    int _fbs_display_pipeline_active = 0;

    if (g_ca_server_connected) {
        bridge_log("Display Pipeline: CARenderServer connected — setting up display...");

        /* Wire UIScreen to the CARenderServer display via FBSScene.
         * This is the proper display pipeline — replaces all CPU rendering. */
        @try {
            Class caDisplayClass = objc_getClass("CADisplay");
            if (caDisplayClass) {
                id displays = ((id(*)(id, SEL))objc_msgSend)(
                    (id)caDisplayClass, sel_registerName("displays"));
                NSUInteger dCount = [(NSArray *)displays count];
                bridge_log("Display Pipeline: [CADisplay displays] count=%lu", (unsigned long)dCount);

                if (dCount > 0) {
                    id mainDisplay = [(NSArray *)displays objectAtIndex:0];
                    bridge_log("Display Pipeline: mainDisplay=%p", (void *)mainDisplay);

                    /* Create FBSDisplay */
                    Class fbsDisplayClass = objc_getClass("FBSDisplay");
                    id fbsDisplay = nil;
                    if (fbsDisplayClass) {
                        SEL initSel = sel_registerName("initWithCADisplay:isMainDisplay:");
                        if (class_getInstanceMethod(fbsDisplayClass, initSel)) {
                            fbsDisplay = ((id(*)(id, SEL, id, BOOL))objc_msgSend)(
                                ((id(*)(id, SEL))objc_msgSend)((id)fbsDisplayClass, sel_registerName("alloc")),
                                initSel, mainDisplay, YES);
                            bridge_log("Display Pipeline: FBSDisplay=%p", (void *)fbsDisplay);
                        }
                    }

                    if (fbsDisplay) {
                        /* Verify FBSDisplay properties */
                        SEL dispIdSel = sel_registerName("displayID");
                        if ([(id)fbsDisplay respondsToSelector:dispIdSel]) {
                            unsigned int did = ((unsigned int(*)(id, SEL))objc_msgSend)(fbsDisplay, dispIdSel);
                            bridge_log("Display Pipeline: FBSDisplay.displayID=%u", did);
                        }

                        /* Create FBSScene */
                        id fbsScene = nil;
                        Class sceneClass = objc_getClass("FBSScene");
                        if (sceneClass) {
                            Class settingsClass = objc_getClass("UIMutableApplicationSceneSettings");
                            id sceneSettings = settingsClass ?
                                ((id(*)(id, SEL))objc_msgSend)(
                                    ((id(*)(id, SEL))objc_msgSend)((id)settingsClass, sel_registerName("alloc")),
                                    sel_registerName("init")) : nil;

                            Class clientSettingsClass = objc_getClass("UIMutableApplicationSceneClientSettings");
                            id clientSettings = clientSettingsClass ?
                                ((id(*)(id, SEL))objc_msgSend)(
                                    ((id(*)(id, SEL))objc_msgSend)((id)clientSettingsClass, sel_registerName("alloc")),
                                    sel_registerName("init")) : nil;

                            id sceneId = @"com.apple.frontboard.default";
                            SEL sceneInitSel = sel_registerName("initWithQueue:identifier:display:settings:clientSettings:");
                            if (class_getInstanceMethod(sceneClass, sceneInitSel)) {
                                fbsScene = ((id(*)(id, SEL, id, id, id, id, id))objc_msgSend)(
                                    ((id(*)(id, SEL))objc_msgSend)((id)sceneClass, sel_registerName("alloc")),
                                    sceneInitSel, dispatch_get_main_queue(), sceneId,
                                    fbsDisplay, sceneSettings, clientSettings);
                                bridge_log("Display Pipeline: FBSScene=%p", (void *)fbsScene);
                            }
                        }

                        /* Wire UIScreen directly by setting its ivars.
                         * _FBSDisplayDidPossiblyConnect crashes because FBSScene
                         * lifecycle methods access unimplemented workspace state.
                         * Instead, set the ivars that _FBSDisplayDidPossiblyConnect
                         * would set: _display, _fbsDisplay, _bounds, _mainSceneReferenceBounds. */
                        Class uiScreenClass = objc_getClass("UIScreen");
                        if (uiScreenClass) {
                            id mainScreen = ((id(*)(id, SEL))objc_msgSend)(
                                (id)uiScreenClass, sel_registerName("mainScreen"));
                            bridge_log("Display Pipeline: mainScreen=%p", (void *)mainScreen);

                            if (mainScreen) {
                                /* Set _display (CADisplay) */
                                Ivar displayIvar = class_getInstanceVariable(uiScreenClass, "_display");
                                if (displayIvar) {
                                    /* Retain the new display */
                                    ((id(*)(id, SEL))objc_msgSend)(mainDisplay, sel_registerName("retain"));
                                    object_setIvar(mainScreen, displayIvar, mainDisplay);
                                    bridge_log("Display Pipeline: set _display=%p", (void *)mainDisplay);

                                    /* Set the client port so UIKit's default CA pipeline
                                     * routes render commits to CARenderServer */
                                    Class caCtxClass = objc_getClass("CAContext");
                                    SEL setClientPortSel = sel_registerName("setClientPort:");
                                    if (caCtxClass && class_respondsToSelector(
                                            object_getClass((id)caCtxClass), setClientPortSel)) {
                                        /* Create a receive port for the client.
                                         * setClientPort sets the port that the SERVER sends callbacks to.
                                         * It must NOT be the server port — it must be a port the client OWNS. */
                                        mach_port_t clientPort = MACH_PORT_NULL;
                                        mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &clientPort);
                                        mach_port_insert_right(mach_task_self(), clientPort, clientPort,
                                                               MACH_MSG_TYPE_MAKE_SEND);
                                        ((void(*)(id, SEL, mach_port_t))objc_msgSend)(
                                            (id)caCtxClass, setClientPortSel, clientPort);
                                        bridge_log("Display Pipeline: [CAContext setClientPort:%u] (client receive port)",
                                                   clientPort);
                                    }

                                    /* Send RegisterClient MIG message to CARenderServer.
                                     * This registers the app as a display client so the server
                                     * composites its content onto the display surface. */
                                    if (g_ca_server_port != MACH_PORT_NULL) {
                                        /* Try calling the MIG client stub directly via dlsym */
                                        typedef kern_return_t (*CASRegFn)(
                                            mach_port_t, mach_port_t, mach_port_t,
                                            mach_port_t, uint32_t, mach_port_t *,
                                            uint32_t *, uint32_t *);
                                        CASRegFn casReg = (CASRegFn)dlsym(RTLD_DEFAULT, "__CASRegisterClient");
                                        if (casReg) {
                                            mach_port_t outSP = 0;
                                            uint32_t outCID = 0, outFP = 0;
                                            kern_return_t kr2 = casReg(g_ca_server_port,
                                                MACH_PORT_NULL, mach_task_self(),
                                                MACH_PORT_NULL, 0, &outSP, &outCID, &outFP);
                                            bridge_log("Display Pipeline: __CASRegisterClient kr=%d ctx=%u server=%u fence=%u",
                                                       kr2, outCID, outSP, outFP);
                                        } else {
                                            bridge_log("Display Pipeline: __CASRegisterClient not found");
                                        }
                                    }
                                    if (g_ca_server_port != MACH_PORT_NULL) { /* manual RegisterClient */
                                        #pragma pack(4)
                                        struct {
                                            mach_msg_header_t header;     /* 24 bytes */
                                            mach_msg_body_t body;         /*  4 bytes */
                                            mach_msg_port_descriptor_t ports[3]; /* 36 bytes (12 each) */
                                            NDR_record_t ndr;             /*  8 bytes */
                                            uint32_t priority;            /*  4 bytes */
                                        } req;
                                        /* Reply buffer — oversized to handle complex replies
                                         * with port descriptors and unknown fields */
                                        struct {
                                            mach_msg_header_t header;
                                            char payload[512]; /* generous buffer */
                                        } reply;
                                        #pragma pack()

                                        memset(&req, 0, sizeof(req));
                                        req.header.msgh_bits = MACH_MSGH_BITS_COMPLEX |
                                            MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, MACH_MSG_TYPE_MAKE_SEND_ONCE);
                                        req.header.msgh_size = sizeof(req);
                                        req.header.msgh_remote_port = g_ca_server_port;
                                        mach_port_t replyPort;
                                        mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &replyPort);
                                        req.header.msgh_local_port = replyPort;
                                        req.header.msgh_id = 40202; /* RegisterClient */
                                        req.body.msgh_descriptor_count = 3;

                                        /* Port descriptor 0: display port (use 0 for main display) */
                                        req.ports[0].name = 0; /* display ID as port? */
                                        req.ports[0].disposition = MACH_MSG_TYPE_COPY_SEND;
                                        req.ports[0].type = MACH_MSG_PORT_DESCRIPTOR;

                                        /* Port descriptor 1: task port */
                                        req.ports[1].name = mach_task_self();
                                        req.ports[1].disposition = MACH_MSG_TYPE_COPY_SEND;
                                        req.ports[1].type = MACH_MSG_PORT_DESCRIPTOR;

                                        /* Port descriptor 2: render/notify port (can be 0) */
                                        req.ports[2].name = MACH_PORT_NULL;
                                        req.ports[2].disposition = MACH_MSG_TYPE_COPY_SEND;
                                        req.ports[2].type = MACH_MSG_PORT_DESCRIPTOR;

                                        req.ndr = NDR_record;
                                        req.priority = 0; /* default priority */

                                        bridge_log("Display Pipeline: Sending RegisterClient (msg_id=40202) to port %u", g_ca_server_port);

                                        /* Send RegisterClient. Try receive with retries for RCV_INTERRUPTED. */
                                        kern_return_t kr = mach_msg(&req.header,
                                            MACH_SEND_MSG | MACH_SEND_TIMEOUT,
                                            sizeof(req), 0,
                                            MACH_PORT_NULL, 3000,
                                            MACH_PORT_NULL);
                                        bridge_log("Display Pipeline: RegisterClient send: kr=%d (0x%x)", kr, kr);
                                        if (kr == KERN_SUCCESS) {
                                            /* Receive reply with retries for MACH_RCV_INTERRUPTED */
                                            for (int retry = 0; retry < 5; retry++) {
                                                memset(&reply, 0, sizeof(reply));
                                                kr = mach_msg(&reply.header,
                                                    MACH_RCV_MSG | MACH_RCV_TIMEOUT,
                                                    0, sizeof(reply),
                                                    replyPort, 3000,
                                                    MACH_PORT_NULL);
                                                if (kr != 0x10004004) break; /* not INTERRUPTED */
                                                bridge_log("Display Pipeline: RegisterClient recv interrupted, retrying...");
                                            }
                                        }

                                        if (kr == KERN_SUCCESS) {
                                            /* Dump reply for analysis */
                                            bridge_log("Display Pipeline: RegisterClient reply received! "
                                                       "size=%u id=%d complex=%s",
                                                       reply.header.msgh_size,
                                                       reply.header.msgh_id,
                                                       (reply.header.msgh_bits & MACH_MSGH_BITS_COMPLEX) ? "YES" : "NO");
                                            /* Hex dump first 64 bytes of payload */
                                            {
                                                char hex[256] = {0};
                                                int hlen = 0;
                                                uint32_t dumplen = reply.header.msgh_size > 24 ?
                                                    reply.header.msgh_size - 24 : 0;
                                                if (dumplen > 80) dumplen = 80;
                                                for (uint32_t i = 0; i < dumplen; i++) {
                                                    hlen += snprintf(hex + hlen, sizeof(hex) - hlen,
                                                                     "%02x ", (unsigned char)reply.payload[i]);
                                                }
                                                bridge_log("Display Pipeline: reply payload: %s", hex);
                                            }
                                            bridge_log("Display Pipeline: CLIENT REGISTERED successfully");
                                        } else {
                                            bridge_log("Display Pipeline: RegisterClient mach_msg failed: kr=%d (0x%x)",
                                                       kr, kr);
                                        }
                                        mach_port_deallocate(mach_task_self(), replyPort);
                                    }
                                }

                                /* Set _fbsDisplay (FBSDisplay) */
                                Ivar fbsDisplayIvar = class_getInstanceVariable(uiScreenClass, "_fbsDisplay");
                                if (fbsDisplayIvar) {
                                    ((id(*)(id, SEL))objc_msgSend)(fbsDisplay, sel_registerName("retain"));
                                    object_setIvar(mainScreen, fbsDisplayIvar, fbsDisplay);
                                    bridge_log("Display Pipeline: set _fbsDisplay=%p", (void *)fbsDisplay);
                                }

                                /* Set _bounds to screen size (in points) */
                                Ivar boundsIvar = class_getInstanceVariable(uiScreenClass, "_bounds");
                                if (boundsIvar) {
                                    typedef struct { double x, y, w, h; } CGRect_d;
                                    CGRect_d *boundsPtr = (CGRect_d *)((uint8_t *)mainScreen + ivar_getOffset(boundsIvar));
                                    boundsPtr->x = 0;
                                    boundsPtr->y = 0;
                                    boundsPtr->w = 375.0;  /* iPhone 6s width in points */
                                    boundsPtr->h = 667.0;  /* iPhone 6s height in points */
                                    bridge_log("Display Pipeline: set _bounds={0,0,375,667}");
                                }

                                /* Set _mainSceneReferenceBounds */
                                Ivar refBoundsIvar = class_getInstanceVariable(uiScreenClass, "_mainSceneReferenceBounds");
                                if (refBoundsIvar) {
                                    typedef struct { double x, y, w, h; } CGRect_d;
                                    CGRect_d *rbPtr = (CGRect_d *)((uint8_t *)mainScreen + ivar_getOffset(refBoundsIvar));
                                    rbPtr->x = 0;
                                    rbPtr->y = 0;
                                    rbPtr->w = 375.0;
                                    rbPtr->h = 667.0;
                                    bridge_log("Display Pipeline: set _mainSceneReferenceBounds={0,0,375,667}");
                                }

                                _fbs_display_pipeline_active = 1;
                                bridge_log("Display Pipeline: UIScreen wired to CARenderServer display");

                                /* Make all CAContexts visible on the server.
                                 * The context may not be automatically visible. */
                                @try {
                                    id allCtxs = ((id(*)(id, SEL))objc_msgSend)(
                                        (id)objc_getClass("CAContext"),
                                        sel_registerName("allContexts"));
                                    bridge_log("Display Pipeline: CAContext.allContexts=%lu",
                                               (unsigned long)[(NSArray *)allCtxs count]);
                                    for (id ctx in (NSArray *)allCtxs) {
                                        SEL renderCtxSel = sel_registerName("renderContext");
                                        if ([(id)ctx respondsToSelector:renderCtxSel]) {
                                            void *rc = ((void *(*)(id, SEL))objc_msgSend)(ctx, renderCtxSel);
                                            if (rc) {
                                                typedef void (*svfn)(void *, bool);
                                                svfn fn = (svfn)dlsym(RTLD_DEFAULT,
                                                    "_ZN2CA6Render7Context11set_visibleEb");
                                                if (fn) {
                                                    fn(rc, true);
                                                    bridge_log("Display Pipeline: set_visible(true) on %p", rc);
                                                }
                                            }
                                        }
                                    }
                                } @catch (id ex) { /* ignore */ }

                                /* Create a displayable remote CAContext after window is ready.
                                 * The key insight: CA::Render::Context only composites to the
                                 * display surface when "displayable" = YES in the options dict.
                                 * kCAContextDisplayable (0x1a2028 in QuartzCore) is the key. */
                                @try {
                                    id app = ((id(*)(id, SEL))objc_msgSend)(
                                        (id)objc_getClass("UIApplication"),
                                        sel_registerName("sharedApplication"));
                                    id keyWindow = app ? ((id(*)(id, SEL))objc_msgSend)(
                                        app, sel_registerName("keyWindow")) : nil;
                                    if (keyWindow) {
                                        id rootLayer = ((id(*)(id, SEL))objc_msgSend)(
                                            keyWindow, sel_registerName("layer"));
                                        if (rootLayer) {
                                            /* Create displayable remote CAContext */
                                            Class caCtxClass = objc_getClass("CAContext");
                                            SEL remoteCtxSel = sel_registerName("remoteContextWithOptions:");
                                            if (caCtxClass && class_respondsToSelector(
                                                    object_getClass((id)caCtxClass), remoteCtxSel)) {
                                                /* Build options dict with displayable=YES and display=displayId */
                                                unsigned int displayId = 1; /* from CADisplay */
                                                @try {
                                                    SEL didSel = sel_registerName("displayId");
                                                    if ([(id)mainDisplay respondsToSelector:didSel]) {
                                                        displayId = ((unsigned int(*)(id, SEL))objc_msgSend)(
                                                            mainDisplay, didSel);
                                                    }
                                                } @catch (id ex) { /* use default 1 */ }

                                                /* Use kCAContextDisplayable if available, else literal string */
                                                id displayableKey = *(id *)dlsym(RTLD_DEFAULT, "kCAContextDisplayable");
                                                if (!displayableKey) displayableKey = @"displayable";
                                                id displayKey = @"display";

                                                /* Also include kCAContextClientPortNumber so connect_remote
                                                 * passes our client port to the server during registration */
                                                id clientPortKey = nil;
                                                void *cpkPtr = dlsym(RTLD_DEFAULT, "kCAContextClientPortNumber");
                                                if (cpkPtr) clientPortKey = *(id *)cpkPtr;
                                                if (!clientPortKey) clientPortKey = @"clientPortNumber";

                                                NSDictionary *opts;
                                                /* Read back the client port we set earlier */
                                                void *ucpPtr = dlsym(RTLD_DEFAULT, "_ZN2CA7Context17_user_client_portE");
                                                mach_port_t ucp = ucpPtr ? *(mach_port_t *)ucpPtr : 0;
                                                if (ucp != 0) {
                                                    opts = @{
                                                        displayKey: @(displayId),
                                                        displayableKey: @YES,
                                                        clientPortKey: @(ucp)
                                                    };
                                                    bridge_log("Display Pipeline: opts include clientPortNumber=%u", ucp);
                                                } else {
                                                    opts = @{
                                                        displayKey: @(displayId),
                                                        displayableKey: @YES
                                                    };
                                                }
                                                bridge_log("Display Pipeline: Creating displayable CAContext (display=%u)", displayId);

                                                id remoteCtx = ((id(*)(id, SEL, id))objc_msgSend)(
                                                    (id)caCtxClass, remoteCtxSel, opts);
                                                if (remoteCtx) {
                                                    /* Set the window's layer as the context's layer */
                                                    SEL setLayerSel = sel_registerName("setLayer:");
                                                    if ([(id)remoteCtx respondsToSelector:setLayerSel]) {
                                                        ((void(*)(id, SEL, id))objc_msgSend)(
                                                            remoteCtx, setLayerSel, rootLayer);
                                                        bridge_log("Display Pipeline: Set context layer = rootLayer");
                                                    }

                                                    SEL ctxIdSel = sel_registerName("contextId");
                                                    if ([(id)remoteCtx respondsToSelector:ctxIdSel]) {
                                                        unsigned int ctxId = ((unsigned int(*)(id, SEL))objc_msgSend)(
                                                            remoteCtx, ctxIdSel);
                                                        bridge_log("Display Pipeline: Displayable context ID = %u (NOT writing to file — UIKit contextId already written)", ctxId);
                                                    }

                                                    /* Flush to push the context creation to server */
                                                    ((void(*)(id, SEL))objc_msgSend)(
                                                        (id)objc_getClass("CATransaction"),
                                                        sel_registerName("flush"));
                                                    bridge_log("Display Pipeline: Flushed displayable context");

                                                    /* Retain to prevent deallocation */
                                                    ((id(*)(id, SEL))objc_msgSend)(remoteCtx, sel_registerName("retain"));
                                                } else {
                                                    bridge_log("Display Pipeline: remoteContextWithOptions: returned nil");
                                                }
                                            }
                                            bridge_log("Display Pipeline: Context setup complete");
                                        }
                                    } else {
                                        bridge_log("Display Pipeline: No keyWindow yet");
                                    }

                                    /* Schedule a delayed check to find UIKit's own context and
                                     * make it displayable. UIKit creates its context during
                                     * makeKeyAndVisible, which happens after this code runs. */
                                    dispatch_after(
                                        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                                        dispatch_get_main_queue(), ^{
                                        @try {
                                            id allCtxs = ((id(*)(id, SEL))objc_msgSend)(
                                                (id)objc_getClass("CAContext"),
                                                sel_registerName("allContexts"));
                                            unsigned long count = [(NSArray *)allCtxs count];
                                            bridge_log("Display Pipeline [delayed]: allContexts count=%lu", count);

                                            /* Check UIWindow._layerContext */
                                            id _a = ((id(*)(id, SEL))objc_msgSend)(
                                                (id)objc_getClass("UIApplication"), sel_registerName("sharedApplication"));
                                            id _kw = _a ? ((id(*)(id, SEL))objc_msgSend)(_a, sel_registerName("keyWindow")) : nil;
                                            if (_kw) {
                                                Ivar lcIvar = class_getInstanceVariable(objc_getClass("UIWindow"), "_layerContext");
                                                if (lcIvar) {
                                                    id lc = *(id *)((uint8_t *)_kw + ivar_getOffset(lcIvar));
                                                    bridge_log("Display Pipeline [delayed]: UIWindow._layerContext=%p", (void *)lc);

                                                    if (!lc) {
                                                        /* UIWindow never created its CAContext.
                                                         * Call _createContext to create it now. */
                                                        SEL createCtxSel = sel_registerName("_createContext");
                                                        if ([(id)_kw respondsToSelector:createCtxSel]) {
                                                            bridge_log("Display Pipeline [delayed]: Calling [UIWindow _createContext]");
                                                            ((void(*)(id, SEL))objc_msgSend)(_kw, createCtxSel);

                                                            /* Check again */
                                                            lc = *(id *)((uint8_t *)_kw + ivar_getOffset(lcIvar));
                                                            bridge_log("Display Pipeline [delayed]: After _createContext: _layerContext=%p", (void *)lc);
                                                        }

                                                        /* If still nil, try _createContextAttached:YES */
                                                        if (!lc) {
                                                            SEL createAttSel = sel_registerName("_createContextAttached:");
                                                            if ([(id)_kw respondsToSelector:createAttSel]) {
                                                                bridge_log("Display Pipeline [delayed]: Calling [UIWindow _createContextAttached:YES]");
                                                                ((void(*)(id, SEL, BOOL))objc_msgSend)(_kw, createAttSel, YES);
                                                                lc = *(id *)((uint8_t *)_kw + ivar_getOffset(lcIvar));
                                                                bridge_log("Display Pipeline [delayed]: After _createContextAttached: _layerContext=%p", (void *)lc);
                                                            }
                                                        }
                                                    }

                                                    if (lc && [(id)lc respondsToSelector:sel_registerName("contextId")]) {
                                                        unsigned int cid = ((unsigned int(*)(id, SEL))objc_msgSend)(
                                                            lc, sel_registerName("contextId"));
                                                        bridge_log("Display Pipeline [delayed]: _layerContext.contextId=%u class=%s",
                                                                   cid, class_getName(object_getClass(lc)));
                                                        SEL rcS = sel_registerName("renderContext");
                                                        if ([(id)lc respondsToSelector:rcS]) {
                                                            void *rc = ((void *(*)(id, SEL))objc_msgSend)(lc, rcS);
                                                            bridge_log("Display Pipeline [delayed]: renderContext=%p (%s)",
                                                                       rc, rc ? "REMOTE" : "LOCAL");
                                                        }
                                                    }
                                                }
                                            }

                                            /* NUCLEAR OPTION: Force UIKit to completely rebuild its views.
                                             * Remove and re-add the root view controller. This destroys all
                                             * existing backing stores and creates new ones through the active
                                             * so new backing stores go through the server pipeline.
                                             * Call setNeedsDisplay on VIEWS (not just layers) so UIKit
                                             * properly re-creates content via drawRect:. */
                                            id a = ((id(*)(id, SEL))objc_msgSend)(
                                                (id)objc_getClass("UIApplication"),
                                                sel_registerName("sharedApplication"));
                                            id kw = a ? ((id(*)(id, SEL))objc_msgSend)(
                                                a, sel_registerName("keyWindow")) : nil;
                                            if (kw) {
                                                /* Remove and re-set the root view controller to force
                                                 * complete rebuild of the view/layer hierarchy */
                                                id rvc = ((id(*)(id, SEL))objc_msgSend)(
                                                    kw, sel_registerName("rootViewController"));
                                                if (rvc) {
                                                    bridge_log("Display Pipeline [delayed]: Re-setting rootViewController to force rebuild");
                                                    ((void(*)(id, SEL, id))objc_msgSend)(
                                                        kw, sel_registerName("setRootViewController:"), nil);
                                                    ((void(*)(id, SEL, id))objc_msgSend)(
                                                        kw, sel_registerName("setRootViewController:"), rvc);
                                                    /* DETACH and RE-ATTACH the root layer to force
                                                     * CoreAnimation to treat ALL properties as new.
                                                     * The context tracks which layers have been committed.
                                                     * Re-attaching resets this tracking. */
                                                    Ivar lcIvar2 = class_getInstanceVariable(object_getClass(kw), "_layerContext");
                                                    id lc2 = lcIvar2 ? *(id *)((uint8_t *)kw + ivar_getOffset(lcIvar2)) : nil;
                                                    if (lc2) {
                                                        id rootLayer = ((id(*)(id, SEL))objc_msgSend)(kw, sel_registerName("layer"));
                                                        SEL setLayerSel = sel_registerName("setLayer:");
                                                        if ([(id)lc2 respondsToSelector:setLayerSel] && rootLayer) {
                                                            /* Detach */
                                                            ((void(*)(id, SEL, id))objc_msgSend)(lc2, setLayerSel, nil);
                                                            /* Re-attach — triggers full layer tree sync */
                                                            ((void(*)(id, SEL, id))objc_msgSend)(lc2, setLayerSel, rootLayer);
                                                            bridge_log("Display Pipeline [delayed]: Detached+re-attached rootLayer on _layerContext");
                                                        }
                                                    }

                                                    /* Force layout */
                                                    ((void(*)(id, SEL))objc_msgSend)(
                                                        kw, sel_registerName("layoutIfNeeded"));
                                                    bridge_log("Display Pipeline [delayed]: Root VC re-set + layout complete");
                                                } else {
                                                    bridge_log("Display Pipeline [delayed]: No rootViewController");
                                                }
                                            }

                                            /* Flush to push everything to server */
                                            ((void(*)(id, SEL))objc_msgSend)(
                                                (id)objc_getClass("CATransaction"),
                                                sel_registerName("flush"));
                                            bridge_log("Display Pipeline [delayed]: Flushed after invalidation");

                                            /* Post-flush: check if commits happened */
                                            {
                                                Ivar li3 = class_getInstanceVariable(object_getClass(kw), "_layerContext");
                                                id lc3 = li3 ? *(id *)((uint8_t *)kw + ivar_getOffset(li3)) : nil;
                                                if (lc3) {
                                                    Ivar ii3 = class_getInstanceVariable(object_getClass(lc3), "_impl");
                                                    void *impl3 = ii3 ? *(void **)((uint8_t *)lc3 + ivar_getOffset(ii3)) : NULL;
                                                    if (impl3) {
                                                        uint32_t cc = *(uint32_t *)((uint8_t *)impl3 + 0x90);
                                                        uint32_t fl = *(uint32_t *)((uint8_t *)impl3 + 0xD0);
                                                        uint32_t sp = *(uint32_t *)((uint8_t *)impl3 + 0x98);
                                                        bridge_log("Display Pipeline [delayed]: POST-FLUSH commits=%u flags=0x%x server_port=%u",
                                                                   cc, fl, sp);
                                                    }
                                                }
                                            }

                                            /* Diagnostic: Use CARenderServerCaptureDisplay to see
                                             * what the server renders. If this shows content, the
                                             * server HAS the data but isn't compositing to our surface.
                                             * If this is blank, the server truly doesn't have the content. */
                                            @try {
                                                typedef int (*CaptureDisplayFn)(unsigned int serverPort,
                                                    const char *displayName, unsigned long count,
                                                    const unsigned int *clientIds, bool

, unsigned int

buffer, int

w, int

h, unsigned long

rowBytes, void *transform);
                                                CaptureDisplayFn captureFn = (CaptureDisplayFn)dlsym(
                                                    RTLD_DEFAULT, "CARenderServerCaptureDisplay");
                                                if (captureFn) {
                                                    bridge_log("Display Pipeline [delayed]: CARenderServerCaptureDisplay found");
                                                } else {
                                                    bridge_log("Display Pipeline [delayed]: CARenderServerCaptureDisplay NOT found");
                                                }

                                                /* Also check: what does CARenderServerGetServerPort return? */
                                                typedef mach_port_t (*GetPortFn)(void);
                                                GetPortFn getPort = (GetPortFn)dlsym(RTLD_DEFAULT,
                                                    "CARenderServerGetServerPort");
                                                if (getPort) {
                                                    mach_port_t sp = getPort();
                                                    bridge_log("Display Pipeline [delayed]: CARenderServerGetServerPort()=%u", sp);
                                                }

                                                /* Check CARenderServerGetClientPort */
                                                typedef mach_port_t (*GetClientPortFn)(unsigned int sp);
                                                GetClientPortFn getClientPort = (GetClientPortFn)dlsym(
                                                    RTLD_DEFAULT, "CARenderServerGetClientPort");
                                                if (getClientPort) {
                                                    mach_port_t sp = getPort ? getPort() : 0;
                                                    mach_port_t cp = getClientPort(sp);
                                                    bridge_log("Display Pipeline [delayed]: CARenderServerGetClientPort(%u)=%u", sp, cp);
                                                }
                                            } @catch (id ex) {
                                                bridge_log("Display Pipeline [delayed]: diagnostic threw: %s",
                                                           [[ex description] UTF8String] ?: "unknown");
                                            }
                                        } @catch (id ex) {
                                            bridge_log("Display Pipeline [delayed]: threw: %s",
                                                       [[ex description] UTF8String] ?: "unknown");
                                        }
                                    });
                                    if (0) { /* dead code to balance braces from original */
                                        bridge_log("Display Pipeline: No keyWindow yet — will retry");
                                        /* Schedule delayed redraw after window creation */
                                        dispatch_after(
                                            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                                            dispatch_get_main_queue(), ^{
                                            @try {
                                                id a = ((id(*)(id, SEL))objc_msgSend)(
                                                    (id)objc_getClass("UIApplication"),
                                                    sel_registerName("sharedApplication"));
                                                id w = a ? ((id(*)(id, SEL))objc_msgSend)(
                                                    a, sel_registerName("keyWindow")) : nil;
                                                if (w) {
                                                    id l = ((id(*)(id, SEL))objc_msgSend)(
                                                        w, sel_registerName("layer"));
                                                    if (l) {
                                                        /* Mark entire tree dirty */
                                                        ((void(*)(id, SEL, BOOL))objc_msgSend)(
                                                            l, sel_registerName("setNeedsLayoutAndDisplay"),
                                                            YES);
                                                        ((void(*)(id, SEL))objc_msgSend)(
                                                            (id)objc_getClass("CATransaction"),
                                                            sel_registerName("flush"));
                                                        bridge_log("Display Pipeline: Delayed full redraw triggered");
                                                    }
                                                }
                                            } @catch (id ex) { /* ignore */ }
                                        });
                                    }
                                } @catch (id ex) {
                                    bridge_log("Display Pipeline: Force redraw threw: %s",
                                               [[ex description] UTF8String] ?: "unknown");
                                }
                            }
                        }
                    }
                }
            }
        } @catch (id ex) {
            bridge_log("Display Pipeline: Exception: %s", [[ex description] UTF8String] ?: "unknown");
        }

        /* Map the GPU framebuffer for relay to app framebuffer */
        {
            const char *gpu_fb_path = ROSETTASIM_FB_GPU_PATH;
            int gpu_fd = open(gpu_fb_path, O_RDONLY);
            if (gpu_fd >= 0) {
                struct stat st;
                if (fstat(gpu_fd, &st) == 0 && st.st_size > 0) {
                    _backboardd_fb_size = (size_t)st.st_size;
                    _backboardd_fb_mmap = mmap(NULL, _backboardd_fb_size,
                                                PROT_READ, MAP_SHARED, gpu_fd, 0);
                    if (_backboardd_fb_mmap != MAP_FAILED) {
                        g_gpu_rendering_active = 1;
                        _fbs_display_pipeline_active = 1;
                        bridge_log("Display Pipeline: Mapped GPU framebuffer at %s "
                                   "(%zu bytes) — GPU compositing ACTIVE",
                                   gpu_fb_path, _backboardd_fb_size);
                    } else {
                        _backboardd_fb_mmap = NULL;
                        bridge_log("Display Pipeline: mmap of %s failed: %s",
                                   gpu_fb_path, strerror(errno));
                    }
                } else {
                    bridge_log("Display Pipeline: %s empty or stat failed", gpu_fb_path);
                }
                close(gpu_fd);
            } else {
                bridge_log("Display Pipeline: %s not found", gpu_fb_path);
            }

            /* Set up the app's framebuffer and start frame capture.
             * In GPU mode, frame_capture_tick copies from GPU framebuffer
             * instead of doing renderInContext. */
            find_root_window(_bridge_delegate);
            start_frame_capture();

            bridge_log("Display Pipeline: Setup complete");
        }
    } else {
        bridge_log("Display Pipeline: CARenderServer not connected — using CPU rendering");
    }
    /* Old duplicate GPU display pipeline code was here (280+ lines).
     * Removed — _FBSDisplayDidPossiblyConnect is called in replacement_runWithMainScene. */
#if 0 /* BEGIN REMOVED DUPLICATE CODE */
    { Class caDisplayClass = objc_getClass("CADisplay");
            id mainDisplay = nil;
            unsigned long displayCount = 0;

            if (caDisplayClass) {
                id displays = ((id(*)(id, SEL))objc_msgSend)(
                    (id)caDisplayClass, sel_registerName("displays"));
                mainDisplay = ((id(*)(id, SEL))objc_msgSend)(
                    (id)caDisplayClass, sel_registerName("mainDisplay"));

                if (displays) {
                    displayCount = ((unsigned long(*)(id, SEL))objc_msgSend)(
                        displays, sel_registerName("count"));
                }

                bridge_log("Display Pipeline: [CADisplay displays] count=%lu, mainDisplay=%p",
                           displayCount, (void *)mainDisplay);

                /* Log display details */
                if (displays && displayCount > 0) {
                    for (unsigned long di = 0; di < displayCount; di++) {
                        id d = ((id(*)(id, SEL, unsigned long))objc_msgSend)(
                            displays, sel_registerName("objectAtIndex:"), di);
                        id dName = ((id(*)(id, SEL))objc_msgSend)(d, sel_registerName("name"));
                        bridge_log("Display Pipeline:   display[%lu]: name=%s ptr=%p",
                                   di,
                                   dName ? ((const char *(*)(id, SEL))objc_msgSend)(
                                       dName, sel_registerName("UTF8String")) : "nil",
                                   (void *)d);
                    }
                }

                /* Use firstObject from displays if mainDisplay is nil */
                if (!mainDisplay && displays && displayCount > 0) {
                    mainDisplay = ((id(*)(id, SEL))objc_msgSend)(
                        displays, sel_registerName("firstObject"));
                    bridge_log("Display Pipeline: mainDisplay was nil, using firstObject=%p",
                               (void *)mainDisplay);
                }
            }

            if (mainDisplay) {
                /* Step 2: Create FBSDisplay wrapping the CADisplay */
                Class fbsDisplayClass = objc_getClass("FBSDisplay");
                id fbsDisplay = nil;

                if (fbsDisplayClass) {
                    /* Try initWithCADisplay:isMainDisplay: first (more explicit) */
                    SEL initMainSel = sel_registerName("initWithCADisplay:isMainDisplay:");
                    SEL initCASel = sel_registerName("initWithCADisplay:");

                    id fbsDisplayAlloc = ((id(*)(id, SEL))objc_msgSend)(
                        (id)fbsDisplayClass, sel_registerName("alloc"));

                    if (class_respondsToSelector(fbsDisplayClass, initMainSel)) {
                        fbsDisplay = ((id(*)(id, SEL, id, BOOL))objc_msgSend)(
                            fbsDisplayAlloc, initMainSel, mainDisplay, (BOOL)YES);
                        bridge_log("Display Pipeline: FBSDisplay initWithCADisplay:isMainDisplay: = %p",
                                   (void *)fbsDisplay);
                    } else if (class_respondsToSelector(fbsDisplayClass, initCASel)) {
                        fbsDisplay = ((id(*)(id, SEL, id))objc_msgSend)(
                            fbsDisplayAlloc, initCASel, mainDisplay);
                        bridge_log("Display Pipeline: FBSDisplay initWithCADisplay: = %p",
                                   (void *)fbsDisplay);
                    } else {
                        bridge_log("Display Pipeline: FBSDisplay has no CADisplay init method");
                        /* Log available init methods for debugging */
                        unsigned int mCount = 0;
                        Method *methods = class_copyMethodList(fbsDisplayClass, &mCount);
                        bridge_log("Display Pipeline: FBSDisplay has %u instance methods:", mCount);
                        for (unsigned int mi = 0; mi < mCount && mi < 20; mi++) {
                            bridge_log("Display Pipeline:   -%s",
                                       sel_getName(method_getName(methods[mi])));
                        }
                        if (methods) free(methods);
                    }
                } else {
                    bridge_log("Display Pipeline: FBSDisplay class not found");
                }

                if (fbsDisplay) {
                    /* Step 3: Create UIMutableApplicationSceneSettings with display config */
                    Class sceneSettingsClass = objc_getClass("UIMutableApplicationSceneSettings");
                    id sceneSettings = nil;

                    if (sceneSettingsClass) {
                        sceneSettings = ((id(*)(id, SEL))objc_msgSend)(
                            ((id(*)(id, SEL))objc_msgSend)(
                                (id)sceneSettingsClass, sel_registerName("alloc")),
                            sel_registerName("init"));

                        if (sceneSettings) {
                            bridge_log("Display Pipeline: UIMutableApplicationSceneSettings created: %p",
                                       (void *)sceneSettings);

                            /* The frame/interfaceOrientation are on FBSMutableSceneSettings (superclass).
                             * UIMutableApplicationSceneSettings inherits from UIApplicationSceneSettings
                             * which inherits from FBSMutableSceneSettings. */
                            @try {
                                /* Set frame — CGRect {0, 0, width, height} */
                                SEL setFrameSel = sel_registerName("setFrame:");
                                if ([(id)sceneSettings respondsToSelector:setFrameSel]) {
                                    _RSBridgeCGRect frame = {0, 0, kScreenWidth, kScreenHeight};
                                    typedef void (*setFrame_fn)(id, SEL, _RSBridgeCGRect);
                                    ((setFrame_fn)objc_msgSend)(sceneSettings, setFrameSel, frame);
                                    bridge_log("Display Pipeline: setFrame: {0, 0, %.0f, %.0f}",
                                               kScreenWidth, kScreenHeight);
                                }

                                /* Set interface orientation to portrait (1) */
                                SEL setOrientSel = sel_registerName("setInterfaceOrientation:");
                                if ([(id)sceneSettings respondsToSelector:setOrientSel]) {
                                    ((void(*)(id, SEL, long))objc_msgSend)(
                                        sceneSettings, setOrientSel, 1L /* UIInterfaceOrientationPortrait */);
                                    bridge_log("Display Pipeline: setInterfaceOrientation: 1 (portrait)");
                                }

                                /* Enable device orientation events */
                                SEL setDevOrientSel = sel_registerName("setDeviceOrientationEventsEnabled:");
                                if ([(id)sceneSettings respondsToSelector:setDevOrientSel]) {
                                    ((void(*)(id, SEL, BOOL))objc_msgSend)(
                                        sceneSettings, setDevOrientSel, (BOOL)YES);
                                    bridge_log("Display Pipeline: setDeviceOrientationEventsEnabled: YES");
                                }
                            } @catch (id ex) {
                                bridge_log("Display Pipeline: Exception setting scene settings: %s",
                                           [[ex description] UTF8String] ?: "unknown");
                            }
                        }
                    }

                    /* Step 4: Create UIMutableApplicationSceneClientSettings */
                    Class clientSettingsClass = objc_getClass("UIMutableApplicationSceneClientSettings");
                    id clientSettings = nil;

                    if (clientSettingsClass) {
                        clientSettings = ((id(*)(id, SEL))objc_msgSend)(
                            ((id(*)(id, SEL))objc_msgSend)(
                                (id)clientSettingsClass, sel_registerName("alloc")),
                            sel_registerName("init"));
                        bridge_log("Display Pipeline: UIMutableApplicationSceneClientSettings = %p",
                                   (void *)clientSettings);
                    }

                    /* Step 5: Create FBSScene with display, settings, and client settings */
                    Class fbsSceneClass = objc_getClass("FBSScene");
                    id fbsScene = nil;

                    if (fbsSceneClass) {
                        SEL sceneInitSel = sel_registerName("initWithQueue:identifier:display:settings:clientSettings:");
                        if (class_respondsToSelector(fbsSceneClass, sceneInitSel)) {
                            @try {
                                id sceneAlloc = ((id(*)(id, SEL))objc_msgSend)(
                                    (id)fbsSceneClass, sel_registerName("alloc"));

                                id sceneId = ((id(*)(id, SEL, const char *))objc_msgSend)(
                                    (id)objc_getClass("NSString"),
                                    sel_registerName("stringWithUTF8String:"),
                                    "com.apple.frontboard.systemappserver");

                                fbsScene = ((id(*)(id, SEL, id, id, id, id, id))objc_msgSend)(
                                    sceneAlloc, sceneInitSel,
                                    (id)dispatch_get_main_queue(),
                                    sceneId,
                                    fbsDisplay,
                                    sceneSettings,
                                    clientSettings);

                                bridge_log("Display Pipeline: FBSScene created: %p", (void *)fbsScene);
                            } @catch (id ex) {
                                bridge_log("Display Pipeline: FBSScene creation threw: %s",
                                           [[ex description] UTF8String] ?: "unknown");
                            }
                        } else {
                            bridge_log("Display Pipeline: FBSScene does not respond to initWithQueue:...");
                            /* Log available init methods */
                            unsigned int mCount = 0;
                            Method *methods = class_copyMethodList(fbsSceneClass, &mCount);
                            for (unsigned int mi = 0; mi < mCount && mi < 20; mi++) {
                                const char *mName = sel_getName(method_getName(methods[mi]));
                                if (strstr(mName, "init")) {
                                    bridge_log("Display Pipeline:   -%s", mName);
                                }
                            }
                            if (methods) free(methods);
                        }
                    }

                    /* Step 6: SKIPPED — _FBSDisplayDidPossiblyConnect is called in
                     * replacement_runWithMainScene. Calling it again here crashes. */
                    bridge_log("Display Pipeline: Skipping duplicate _FBSDisplayDidPossiblyConnect (done in init)");
#if 0 /* disabled — was crashing the app */
                        Class uiScreenClass = objc_getClass("UIScreen");
                        SEL connectSel = sel_registerName("_FBSDisplayDidPossiblyConnect:withScene:andPost:");
                        if (uiScreenClass && fbsDisplay && class_respondsToSelector(object_getClass((id)uiScreenClass), connectSel)) {
                            @try {
                                ((void(*)(id, SEL, id, id, BOOL))objc_msgSend)(
                                    (id)uiScreenClass, connectSel,
                                    fbsDisplay, fbsScene, (BOOL)YES);

                                bridge_log("Display Pipeline: _FBSDisplayDidPossiblyConnect completed");

                                /* Verify UIScreen.mainScreen now has the display */
                                id mainScreen = ((id(*)(id, SEL))objc_msgSend)(
                                    (id)uiScreenClass, sel_registerName("mainScreen"));
                                bridge_log("Display Pipeline: [UIScreen mainScreen] = %p (after connect)",
                                           (void *)mainScreen);

                                /* Check if UIScreen has a _display ivar set now */
                                if (mainScreen) {
                                    Ivar dIvar = class_getInstanceVariable(uiScreenClass, "_display");
                                    if (dIvar) {
                                        id displayVal = *(id *)((uint8_t *)mainScreen + ivar_getOffset(dIvar));
                                        bridge_log("Display Pipeline: UIScreen._display = %p", (void *)displayVal);
                                    }
                                }

                                _fbs_display_pipeline_active = 1;
                            } @catch (id ex) {
                                bridge_log("Display Pipeline: _FBSDisplayDidPossiblyConnect threw: %s",
                                           [[ex description] UTF8String] ?: "unknown");
                            }
                        } else {
                            /* Try the simpler 1-arg and 2-arg variants */
                            SEL connect2Sel = sel_registerName("_FBSDisplayDidPossiblyConnect:withScene:");
                            SEL connect1Sel = sel_registerName("_FBSDisplayDidPossiblyConnect:");

                            if (class_respondsToSelector(object_getClass((id)uiScreenClass), connect2Sel)) {
                                @try {
                                    bridge_log("Display Pipeline: Trying 2-arg variant...");
                                    ((void(*)(id, SEL, id, id))objc_msgSend)(
                                        (id)uiScreenClass, connect2Sel, fbsDisplay, fbsScene);
                                    _fbs_display_pipeline_active = 1;
                                    bridge_log("Display Pipeline: 2-arg _FBSDisplayDidPossiblyConnect completed");
                                } @catch (id ex) {
                                    bridge_log("Display Pipeline: 2-arg threw: %s",
                                               [[ex description] UTF8String] ?: "unknown");
                                }
                            } else if (class_respondsToSelector(object_getClass((id)uiScreenClass), connect1Sel)) {
                                @try {
                                    bridge_log("Display Pipeline: Trying 1-arg variant...");
                                    ((void(*)(id, SEL, id))objc_msgSend)(
                                        (id)uiScreenClass, connect1Sel, fbsDisplay);
                                    _fbs_display_pipeline_active = 1;
                                    bridge_log("Display Pipeline: 1-arg _FBSDisplayDidPossiblyConnect completed");
                                } @catch (id ex) {
                                    bridge_log("Display Pipeline: 1-arg threw: %s",
                                               [[ex description] UTF8String] ?: "unknown");
                                }
                            } else {
                                bridge_log("Display Pipeline: UIScreen has no _FBSDisplayDidPossiblyConnect variant");
                            }
                        }
#endif /* disabled _FBSDisplayDidPossiblyConnect */

                    /* Step 7: If FBSScene pipeline is active, map the GPU framebuffer
                     * for monitoring. CARenderServer composites to PurpleDisplay surface,
                     * purple_fb_server syncs to /tmp/rosettasim_framebuffer_gpu. We map
                     * that to copy frames to the app framebuffer for the host viewer. */
                    if (_fbs_display_pipeline_active) {
                        /* Force a full commit of the layer tree to CARenderServer */
                        @try {
                            Class catClass = objc_getClass("CATransaction");
                            if (catClass) {
                                ((void(*)(id, SEL))objc_msgSend)(
                                    (id)catClass, sel_registerName("flush"));
                                bridge_log("Display Pipeline: Flushed CATransaction");
                            }
                        } @catch (id ex) { /* ignore */ }

                        /* Map the GPU framebuffer for relay to app framebuffer */
                        const char *gpu_fb_path = ROSETTASIM_FB_GPU_PATH;
                        int gpu_fd = open(gpu_fb_path, O_RDONLY);
                        if (gpu_fd >= 0) {
                            struct stat st;
                            if (fstat(gpu_fd, &st) == 0 && st.st_size > 0) {
                                _backboardd_fb_size = (size_t)st.st_size;
                                _backboardd_fb_mmap = mmap(NULL, _backboardd_fb_size,
                                                            PROT_READ, MAP_SHARED, gpu_fd, 0);
                                if (_backboardd_fb_mmap != MAP_FAILED) {
                                    g_gpu_rendering_active = 1;
                                    bridge_log("Display Pipeline: Mapped GPU framebuffer at %s "
                                               "(%zu bytes) — REAL GPU compositing ACTIVE",
                                               gpu_fb_path, _backboardd_fb_size);
                                } else {
                                    _backboardd_fb_mmap = NULL;
                                    bridge_log("Display Pipeline: mmap of %s failed: %s",
                                               gpu_fb_path, strerror(errno));
                                }
                            } else {
                                bridge_log("Display Pipeline: %s empty or stat failed", gpu_fb_path);
                            }
                            close(gpu_fd);
                        } else {
                            bridge_log("Display Pipeline: %s not found (backboardd may not be running)",
                                       gpu_fb_path);
                        }

                        /* Set up the app's own framebuffer for frame relay.
                         * Even with GPU rendering, we need the CPU framebuffer to relay
                         * frames from the GPU framebuffer to the standard path for the
                         * host viewer. find_root_window is still needed for touch injection. */
                        find_root_window(_bridge_delegate);

                        /* Start frame capture — in GPU mode, frame_capture_tick copies
                         * from the GPU framebuffer instead of doing renderInContext. */
                        start_frame_capture();

                        bridge_log("Display Pipeline: FBSScene pipeline ACTIVE — "
                                   "UIKit renders through CARenderServer natively");
                    }

                    /* Retain objects to prevent deallocation */
                    if (fbsDisplay) ((id(*)(id, SEL))objc_msgSend)(fbsDisplay, sel_registerName("retain"));
                    if (fbsScene) ((id(*)(id, SEL))objc_msgSend)(fbsScene, sel_registerName("retain"));
                    if (sceneSettings) ((id(*)(id, SEL))objc_msgSend)(sceneSettings, sel_registerName("retain"));
                    if (clientSettings) ((id(*)(id, SEL))objc_msgSend)(clientSettings, sel_registerName("retain"));
                } else {
                    bridge_log("Display Pipeline: FBSDisplay creation failed — falling back to CPU rendering");
                }
            } else {
                bridge_log("Display Pipeline: No CADisplay available — falling back to CPU rendering");
            }
        } @catch (id ex) {
            bridge_log("Display Pipeline: Exception during setup: %s",
                       [[ex description] UTF8String] ?: "unknown");
        }
    }
#endif /* END REMOVED DUPLICATE CODE */

    /* Fallback: CPU rendering if FBSScene pipeline didn't activate */
    if (!_fbs_display_pipeline_active) {
        bridge_log("  Falling back to CPU rendering (find_root_window + start_frame_capture)...");
        find_root_window(_bridge_delegate);

        /* Post-window warmup: send a synthetic BEGAN+ENDED touch with the real
         * root window and a proper IOHIDEvent. This exercises the full gesture
         * recognizer codepath including the ENDED phase. The first ENDED event
         * through sendEvent: crashes (one-time initialization in gesture processing),
         * so doing it here means real user touches work from the first tap. */
        if (_bridge_root_window) {
            bridge_log("  Post-window warmup: synthetic BEGAN+ENDED on root window...");
            _inject_single_touch(ROSETTASIM_TOUCH_BEGAN, 0.0, 0.0);
            _inject_single_touch(ROSETTASIM_TOUCH_ENDED, 0.0, 0.0);
            bridge_log("  Post-window warmup complete");
        }

        start_frame_capture();
    }

    /* ================================================================
     * Network connectivity test — verify raw TCP works in the simulator.
     * NSURLSession/CFNetwork may be broken due to missing configd_sim,
     * but BSD sockets should work since they go through the host kernel. */
    {
        bridge_log("Network test: attempting raw TCP to HA server...");
        int sock = socket(AF_INET, SOCK_STREAM, 0);
        if (sock >= 0) {
            struct sockaddr_in addr;
            memset(&addr, 0, sizeof(addr));
            addr.sin_family = AF_INET;
            addr.sin_port = htons(8123);
            addr.sin_addr.s_addr = htonl(0xC0A801A2); /* 192.168.1.162 */

            /* Non-blocking connect with 5s timeout */
            int flags = fcntl(sock, F_GETFL, 0);
            fcntl(sock, F_SETFL, flags | O_NONBLOCK);
            int result = connect(sock, (struct sockaddr *)&addr, sizeof(addr));
            if (result < 0 && errno == EINPROGRESS) {
                fd_set wset;
                FD_ZERO(&wset);
                FD_SET(sock, &wset);
                struct timeval tv = { .tv_sec = 5, .tv_usec = 0 };
                int sel = select(sock + 1, NULL, &wset, NULL, &tv);
                if (sel > 0) {
                    int so_error = 0;
                    socklen_t len = sizeof(so_error);
                    getsockopt(sock, SOL_SOCKET, SO_ERROR, &so_error, &len);
                    result = so_error == 0 ? 0 : -1;
                    if (result < 0) errno = so_error;
                } else {
                    result = -1;
                    errno = ETIMEDOUT;
                }
            }
            fcntl(sock, F_SETFL, flags); /* restore blocking */

            bridge_log("Network test: TCP connect → %s (errno=%d)",
                       result == 0 ? "CONNECTED" : "FAILED", result != 0 ? errno : 0);
            if (result == 0) {
                const char *req = "GET /auth/providers HTTP/1.1\r\n"
                                  "Host: homeassistant.local:8123\r\n"
                                  "Connection: close\r\n\r\n";
                send(sock, req, strlen(req), 0);

                /* Read response with 5s timeout */
                struct timeval rtv = { .tv_sec = 5, .tv_usec = 0 };
                setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &rtv, sizeof(rtv));
                char buf[4096];
                int n = (int)recv(sock, buf, sizeof(buf) - 1, 0);
                if (n > 0) {
                    buf[n] = 0;
                    bridge_log("Network test: HTTP response (%d bytes): %.300s", n, buf);
                } else {
                    bridge_log("Network test: No HTTP response (recv=%d errno=%d)", n, errno);
                }
            }
            close(sock);
        } else {
            bridge_log("Network test: socket() failed (errno=%d)", errno);
        }
    }

    /* Mark init complete — exit() calls are now allowed */
    _init_phase = 0;

    /* Auto-connect: After a delay (to let mDNS discover the server and populate
     * the UI), search for HAConnectionFormView and call connectTapped. This
     * triggers the auth/providers request and subsequent authentication flow. */
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        bridge_log("Auto-connect: Triggered after startup delay");
        Class formClass = objc_getClass("HAConnectionFormView");
        if (!formClass || !_bridge_root_window) {
            bridge_log("Auto-connect: HAConnectionFormView class=%p root_window=%p",
                       (void *)formClass, (void *)_bridge_root_window);
            return;
        }
        id formView = nil;
        NSMutableArray *stack = [NSMutableArray arrayWithObject:_bridge_root_window];
        while (stack.count > 0) {
            id view = stack.lastObject;
            [stack removeLastObject];
            if ([view isKindOfClass:formClass]) {
                formView = view;
                break;
            }
            NSArray *subviews = ((id(*)(id, SEL))objc_msgSend)(
                view, sel_registerName("subviews"));
            if (subviews) [stack addObjectsFromArray:subviews];
        }
        if (formView) {
            bridge_log("Auto-connect: Found HAConnectionFormView %p", (void *)formView);

            /* Step 1: Find discovered servers and set the URL field.
             * HAConnectionFormView has a discoveryService property with discoveredServers.
             * We need to get the first server's baseURL and set it in serverURLField. */
            @try {
                /* Get discoveryService.discoveredServers */
                id discoveryService = ((id(*)(id, SEL))objc_msgSend)(
                    formView, sel_registerName("discoveryService"));
                id servers = nil;
                if (discoveryService) {
                    servers = ((id(*)(id, SEL))objc_msgSend)(
                        discoveryService, sel_registerName("discoveredServers"));
                }
                NSUInteger count = servers ? ((NSUInteger(*)(id, SEL))objc_msgSend)(
                    servers, sel_registerName("count")) : 0;
                bridge_log("Auto-connect: discoveredServers count=%lu", (unsigned long)count);

                if (count > 0) {
                    /* Get first server's baseURL */
                    id server = ((id(*)(id, SEL, NSUInteger))objc_msgSend)(
                        servers, sel_registerName("objectAtIndex:"), (NSUInteger)0);
                    NSString *baseURL = ((id(*)(id, SEL))objc_msgSend)(
                        server, sel_registerName("baseURL"));
                    bridge_log("Auto-connect: server baseURL = %s",
                               baseURL ? [baseURL UTF8String] : "nil");

                    if (baseURL) {
                        /* Set the URL field text */
                        id urlField = ((id(*)(id, SEL))objc_msgSend)(
                            formView, sel_registerName("serverURLField"));
                        if (urlField) {
                            ((void(*)(id, SEL, id))objc_msgSend)(
                                urlField, sel_registerName("setText:"), baseURL);
                            bridge_log("Auto-connect: set serverURLField.text = %s",
                                       [baseURL UTF8String]);
                        }
                    }
                } else {
                    /* No discovered servers — use DNS map IP directly */
                    const char *dns_map = getenv("ROSETTASIM_DNS_MAP");
                    if (dns_map) {
                        /* Parse "hostname=ip" format */
                        char *eq = strchr(dns_map, '=');
                        if (eq) {
                            char ip[64];
                            strncpy(ip, eq + 1, sizeof(ip) - 1);
                            ip[sizeof(ip) - 1] = '\0';
                            NSString *url = [NSString stringWithFormat:@"http://%s:8123", ip];
                            id urlField = ((id(*)(id, SEL))objc_msgSend)(
                                formView, sel_registerName("serverURLField"));
                            if (urlField) {
                                ((void(*)(id, SEL, id))objc_msgSend)(
                                    urlField, sel_registerName("setText:"), url);
                                bridge_log("Auto-connect: set serverURLField.text = %s (from DNS_MAP)",
                                           [url UTF8String]);
                            }
                        }
                    }
                }

                /* Step 2: Simulate tapping the first discovered server row.
                 * This calls discoveredServerTapped: which sets the URL field
                 * AND probes auth providers, triggering the full connection flow. */
                SEL discTapSel = sel_registerName("discoveredServerTapped:");
                if ([(id)formView respondsToSelector:discTapSel]) {
                    /* Create a fake UIButton with tag=0 (first server) */
                    Class btnCls = objc_getClass("UIButton");
                    id fakeBtn = ((id(*)(id, SEL, long))objc_msgSend)(
                        (id)btnCls, sel_registerName("buttonWithType:"), 0);
                    ((void(*)(id, SEL, NSInteger))objc_msgSend)(
                        fakeBtn, sel_registerName("setTag:"), 0);
                    ((void(*)(id, SEL, id))objc_msgSend)(
                        formView, discTapSel, fakeBtn);
                    bridge_log("Auto-connect: discoveredServerTapped: invoked (server 0)");
                } else {
                    /* Fallback: call connectTapped directly */
                    ((void(*)(id, SEL))objc_msgSend)(formView, sel_registerName("connectTapped"));
                    bridge_log("Auto-connect: connectTapped invoked (fallback)");
                }
            } @catch (id ex) {
                bridge_log("Auto-connect: threw: %s",
                           [[ex description] UTF8String] ?: "unknown");
            }
        } else {
            bridge_log("Auto-connect: HAConnectionFormView not found in view hierarchy");
        }
    });

    /* Start the main run loop — this is what _runWithMainScene normally
     * does at the very end. CFRunLoopRun never returns. */
    bridge_log("  Starting CFRunLoop from _runWithMainScene replacement...");
    CFRunLoopRun();

    /* Only reached if CFRunLoopRun returns (app shutting down) */
    bridge_log("  CFRunLoopRun returned from _runWithMainScene replacement");
}

static void swizzle_bks_methods(void) {
    /* UIWindow makeKeyAndVisible — crashes via BKSEventFocusManager */
    Class windowClass = objc_getClass("UIWindow");
    if (windowClass) {
        SEL mkavSel = sel_registerName("makeKeyAndVisible");
        Method m = class_getInstanceMethod(windowClass, mkavSel);
        if (m) {
            _original_makeKeyAndVisible_IMP = method_getImplementation(m);
            method_setImplementation(m, (IMP)replacement_makeKeyAndVisible);
        }

        /* Swizzle UIWindow.initWithFrame: to set the pre-created remote context
         * immediately when the window is created (before any views are added). */
        SEL initFrameSel = sel_registerName("initWithFrame:");
        Method initFrameM = class_getInstanceMethod(windowClass, initFrameSel);
        if (initFrameM) {
            typedef struct { double x, y, w, h; } _CGRect;
            typedef id (*orig_initFrame_fn)(id, SEL, _CGRect);
            __block orig_initFrame_fn origInitFrame = (orig_initFrame_fn)method_getImplementation(initFrameM);
            id (^initFrameBlock)(id, _CGRect) = ^id(id _self, _CGRect frame) {
                bridge_log("  [UIWindow initWithFrame:] SWIZZLE FIRED (pre_ctx=%p)", (void *)_bridge_pre_created_context);
                id result = origInitFrame(_self, initFrameSel, frame);
                if (result && _bridge_pre_created_context) {
                    Ivar lcIvar = class_getInstanceVariable(object_getClass(result), "_layerContext");
                    if (lcIvar) {
                        id existing = *(id *)((uint8_t *)result + ivar_getOffset(lcIvar));
                        if (!existing) {
                            ((id(*)(id, SEL))objc_msgSend)(_bridge_pre_created_context, sel_registerName("retain"));
                            *(id *)((uint8_t *)result + ivar_getOffset(lcIvar)) = _bridge_pre_created_context;
                            /* Set the window's layer as context's layer */
                            id rootL = ((id(*)(id, SEL))objc_msgSend)(result, sel_registerName("layer"));
                            if (rootL && [_bridge_pre_created_context respondsToSelector:sel_registerName("setLayer:")]) {
                                ((void(*)(id, SEL, id))objc_msgSend)(
                                    _bridge_pre_created_context, sel_registerName("setLayer:"), rootL);
                            }
                            bridge_log("  [UIWindow initWithFrame:] set PRE-CREATED context on window %p", (void *)result);
                        }
                    }
                }
                return result;
            };
            IMP initFrameIMP = imp_implementationWithBlock(initFrameBlock);
            method_setImplementation(initFrameM, initFrameIMP);
            bridge_log("  Swizzled UIWindow.initWithFrame: for early context injection");
        }

    /* UIWindow.isKeyWindow — let UIKit manage natively.
         * With the real makeKeyAndVisible running, UIKit tracks key window
         * state internally. Our replacement_isKeyWindow is kept as fallback
         * but UIKit's native impl should work. */
        bridge_log("  UIWindow.isKeyWindow NOT swizzled — using UIKit native");
    }

    /* UIApplication.keyWindow — let UIKit manage natively. */
    Class appClass = objc_getClass("UIApplication");
    bridge_log("  UIApplication.keyWindow NOT swizzled — using UIKit native");

    /* UIApplication.workspaceShouldExit: — called when FBSWorkspace connection
       fails (no SpringBoard). Without this swizzle, the app calls exit().
       In RosettaSim there is no SpringBoard — this is expected, not an error. */
    if (appClass) {
        SEL wseSel = sel_registerName("workspaceShouldExit:");
        Method wseMethod = class_getInstanceMethod(appClass, wseSel);
        if (wseMethod) {
            method_setImplementation(wseMethod, (IMP)_noopMethod);
            bridge_log("  Swizzled UIApplication.workspaceShouldExit:");
        }
        SEL wse2Sel = sel_registerName("workspaceShouldExit:withTransitionContext:");
        Method wse2Method = class_getInstanceMethod(appClass, wse2Sel);
        if (wse2Method) {
            method_setImplementation(wse2Method, (IMP)_noopMethod);
            bridge_log("  Swizzled UIApplication.workspaceShouldExit:withTransitionContext:");
        }
    }

    /* UIApplication._runWithMainScene:transitionContext:completion:
       This is the method that connects to FBSWorkspace, requests scene creation
       from SpringBoard, and waits on dispatch_semaphore for the reply. Without
       SpringBoard, the semaphore never signals and UIApplicationMain hangs.

       Our replacement:
       1. Creates UIEventDispatcher (which UIKit normally creates at this point)
       2. Calls _callInitializationDelegatesForMainScene: (triggers didFinishLaunching)
       3. Starts CFRunLoopRun (the main event loop)

       This is NOT a hack — it's what UIApplicationMain would do at this point,
       minus the FBSWorkspace connection that requires SpringBoard. */
    if (appClass) {
        /* Swizzle _runWithMainScene: (called by _run) */
        SEL runSceneSel = sel_registerName("_runWithMainScene:transitionContext:completion:");
        Method runSceneMethod = class_getInstanceMethod(appClass, runSceneSel);
        if (runSceneMethod) {
            method_setImplementation(runSceneMethod, (IMP)replacement_runWithMainScene);
            bridge_log("  Swizzled UIApplication._runWithMainScene:transitionContext:completion:");
        }

        /* Also swizzle _run — this is the method called by UIApplicationMain
           that initiates the FBSWorkspace connection BEFORE calling
           _runWithMainScene:. By replacing _run, we skip the workspace
           connection entirely and jump straight to our replacement. */
        SEL runSel = sel_registerName("_run");
        Method runMethod = class_getInstanceMethod(appClass, runSel);
        if (runMethod) {
            method_setImplementation(runMethod, (IMP)replacement_runWithMainScene);
            /* Note: _run has signature void(id,SEL) but replacement_runWithMainScene
               has extra params (scene, transitionContext, completion). The extra
               params will be garbage but we don't use them when called via _run
               because _callInitializationDelegatesForMainScene: is called with
               nil scene anyway. */
            bridge_log("  Swizzled UIApplication._run");
        }
    }

    /* FBSWorkspace / FBSScene / FBSWorkspaceClient (ITEM 14).
     *
     * With proper bootstrap_fix.dylib + broker providing all services,
     * and SpringBoard registering com.apple.frontboard.workspace,
     * FBSWorkspaceClient should now connect NATURALLY to SpringBoard.
     *
     * REMOVED: FBSWorkspaceClient nil swizzle (was preventing natural lifecycle)
     * REMOVED: FBSWorkspace.init nil swizzle
     *
     * Let the natural FBSWorkspace connection flow:
     * App → FBSWorkspaceClient → SpringBoard's FBWorkspaceConnectionListener
     * → FBSScene creation → UIKit receives scene → natural display lifecycle
     */
    bridge_log("  FBSWorkspace: allowing natural connection (no swizzle)");
    {

        /* FBSSceneImpl — if it exists, no-op methods that contact SpringBoard.
           This prevents crashes during scene queries without requiring a
           full scene implementation. */
        Class fbsSceneImplClass = objc_getClass("FBSSceneImpl");
        if (fbsSceneImplClass) {
            unsigned int methodCount = 0;
            Method *methods = class_copyMethodList(fbsSceneImplClass, &methodCount);
            if (methods) {
                for (unsigned int i = 0; i < methodCount; i++) {
                    SEL sel = method_getName(methods[i]);
                    const char *name = sel_getName(sel);
                    if (strstr(name, "client") || strstr(name, "workspace") ||
                        strstr(name, "Workspace") || strstr(name, "invalidate")) {
                        method_setImplementation(methods[i], (IMP)_noopMethod);
                    }
                }
                free(methods);
            }
            bridge_log("  FBSSceneImpl: workspace/client methods → no-op");
        }
    }

    /* UIApplication.sendEvent: — with UIEventDispatcher properly initialized
       (created in replacement_runWithMainScene), UIKit's real event pipeline
       should work. Do NOT swizzle sendEvent: — let UIKit handle it natively.

       If UIKit's real _sendTouchesForEvent: crashes (gesture environment not
       fully initialized), the SIGSEGV crash guard in check_and_inject_touch()
       will catch it and fall through to direct delivery. */
    bridge_log("  sendEvent: NOT swizzled — using UIKit's real event pipeline");

    /* UITextField.becomeFirstResponder — with UIEventDispatcher and
       UIGestureEnvironment properly initialized, the real becomeFirstResponder
       should work. Do NOT swizzle — let UIKit handle it natively. */
    bridge_log("  UITextField.becomeFirstResponder NOT swizzled — using native");

    /* BKSEventFocusManager - event focus management */
    /* Keyboard infrastructure — UITextField.becomeFirstResponder triggers
       UIKeyboardImpl which creates UIInputWindowController which calls into
       backboardd via BKSTextInputSessionManager.

       Strategy: Let UIKeyboardImpl create normally but stub the BKSTextInputSession
       methods (already done via bulk swizzle below). This allows:
       - Cursor/caret display in text fields (UITextSelectionView works)
       - Text selection UI (long-press selection handles)
       - Input accessory views

       The on-screen keyboard is NOT needed — RosettaSim delivers keyboard
       input via mmap mechanism from the host app's hardware keyboard.

       We only return nil from UIInputWindowController to prevent the
       on-screen keyboard window from being created (it would overlap the
       app's UI and serve no purpose with hardware keyboard input). */
    {
        /* UIKeyboardImpl.sharedInstance → nil.
         *
         * The keyboard UI infrastructure (UIKeyboardImpl, UIInputWindowController,
         * BKSTextInputSessionManager) cannot function without backboardd — it
         * hangs on animation fences and window presentation during
         * becomeFirstResponder. Returning nil prevents the hang while still
         * allowing gesture recognizers to fire becomeFirstResponder natively.
         *
         * Text input is delivered via the mmap keyboard mechanism:
         *   Host captures keyDown → writes to shared framebuffer → bridge
         *   calls setText:/insertText: on the first responder.
         *
         * Cursor/caret display requires UIKeyboardImpl — this is a known
         * limitation. The text field accepts input but won't show a blinking
         * cursor. */
        Class kbImplClass = objc_getClass("UIKeyboardImpl");
        if (kbImplClass) {
            SEL sharedSel = sel_registerName("sharedInstance");
            Method m = class_getClassMethod(kbImplClass, sharedSel);
            if (m) {
                method_setImplementation(m, (IMP)_noopMethod);
                bridge_log("  Swizzled +[UIKeyboardImpl sharedInstance] → nil (prevents becomeFirstResponder hang)");
            }
        }

        /* UIInputWindowController: return nil to suppress on-screen keyboard.
           Hardware keyboard input via mmap is the input mechanism. */
        Class inputWCClass = objc_getClass("UIInputWindowController");
        if (inputWCClass) {
            SEL sharedSel = sel_registerName("sharedInputWindowController");
            Method m = class_getClassMethod(inputWCClass, sharedSel);
            if (m) {
                method_setImplementation(m, (IMP)_noopMethod);
                bridge_log("  Swizzled +[UIInputWindowController sharedInputWindowController] → nil (no on-screen keyboard)");
            }
        }
    }

    /* BKSEventFocusManager — local focus tracking (ITEM 12).
       Instead of bulk no-ops, provide a minimal focus manager that tracks
       which window has focus using our _bridge_key_window. Methods that
       would contact backboardd are still no-op'd, but focus queries
       return meaningful values. */
    {
        Class efmClass = objc_getClass("BKSEventFocusManager");
        if (efmClass) {
            unsigned int methodCount = 0;
            Method *methods = class_copyMethodList(efmClass, &methodCount);
            if (methods) {
                for (unsigned int i = 0; i < methodCount; i++) {
                    SEL sel = method_getName(methods[i]);
                    const char *name = sel_getName(sel);
                    /* No-op methods that contact backboardd */
                    if (strstr(name, "defer") || strstr(name, "Defer") ||
                        strstr(name, "register") || strstr(name, "fence") ||
                        strstr(name, "invalidate") || strstr(name, "client")) {
                        method_setImplementation(methods[i], (IMP)_noopMethod);
                    }
                }
                free(methods);
            }
            bridge_log("  BKSEventFocusManager: backboardd methods → no-op, focus tracked locally via _bridge_key_window");
        }
    }

    /* BKSAnimationFenceHandle — immediate signal fence (ITEM 13).
       The animation fence coordinates view controller transition animations
       between processes. Since we're single-process, the fence should signal
       immediately. All fence methods become no-ops (the fence never needs to
       wait for an inter-process commit). */
    {
        Class afhClass = objc_getClass("BKSAnimationFenceHandle");
        if (afhClass) {
            unsigned int methodCount = 0;
            Method *methods = class_copyMethodList(afhClass, &methodCount);
            if (methods) {
                for (unsigned int i = 0; i < methodCount; i++) {
                    method_setImplementation(methods[i], (IMP)_noopMethod);
                }
                free(methods);
            }
            /* Also swizzle class methods */
            unsigned int clsMethodCount = 0;
            Method *clsMethods = class_copyMethodList(object_getClass(afhClass), &clsMethodCount);
            if (clsMethods) {
                for (unsigned int i = 0; i < clsMethodCount; i++) {
                    SEL sel = method_getName(clsMethods[i]);
                    const char *name = sel_getName(sel);
                    if (strstr(name, "fence") || strstr(name, "Fence") ||
                        strstr(name, "animation") || strstr(name, "Animation")) {
                        method_setImplementation(clsMethods[i], (IMP)_noopMethod);
                    }
                }
                free(clsMethods);
            }
            bridge_log("  BKSAnimationFenceHandle: ALL methods → no-op (single-process, immediate signal)");
        }
    }

    /* BKSTextInputSessionManager — text input session management.
       No-op methods that contact backboardd for keyboard sessions. */
    {
        Class tismClass = objc_getClass("BKSTextInputSessionManager");
        if (tismClass) {
            unsigned int methodCount = 0;
            Method *methods = class_copyMethodList(tismClass, &methodCount);
            if (methods) {
                for (unsigned int i = 0; i < methodCount; i++) {
                    method_setImplementation(methods[i], (IMP)_noopMethod);
                }
                free(methods);
            }
            bridge_log("  BKSTextInputSessionManager: ALL methods → no-op");
        }
    }

    /* UIViewController.presentViewController:animated:completion:
     *
     * UIAlertController presentation requires the full UIKit windowing stack.
     * In our environment, alert windows may not render correctly. For
     * UIAlertController specifically, we auto-invoke the first action's
     * handler (auto-selecting the first option in picker dialogs). */
    {
        Class vcClass = objc_getClass("UIViewController");
        if (vcClass) {
            SEL presentSel = sel_registerName("presentViewController:animated:completion:");
            Method presentMethod = class_getInstanceMethod(vcClass, presentSel);
            if (presentMethod) {
                typedef void (*PresentIMP)(id, SEL, id, BOOL, id);
                __block PresentIMP origPresentIMP = (PresentIMP)method_getImplementation(presentMethod);

                id newBlock = ^(id self_vc, id presented, BOOL animated, id completion) {
                    Class alertClass = objc_getClass("UIAlertController");
                    if (alertClass && [presented isKindOfClass:alertClass]) {
                        bridge_log("presentViewController: UIAlertController detected — auto-selecting first action");

                        /* Get the alert's actions array */
                        NSArray *actions = ((id(*)(id, SEL))objc_msgSend)(
                            presented, sel_registerName("actions"));

                        if (actions && actions.count > 0) {
                            id firstAction = actions[0];
                            bridge_log("  Auto-selecting action: %s",
                                       ((const char *(*)(id, SEL))objc_msgSend)(
                                           ((id(*)(id, SEL))objc_msgSend)(firstAction, sel_registerName("title")),
                                           sel_registerName("UTF8String")) ?: "nil");

                            /* Extract the handler block from UIAlertAction's private ivar.
                             * The handler is stored as _handler (type @? = block). */
                            Ivar handlerIvar = class_getInstanceVariable(object_getClass(firstAction), "_handler");
                            if (handlerIvar) {
                                void (^handler)(id) = *(void (^__strong *)(id))(
                                    (uint8_t *)firstAction + ivar_getOffset(handlerIvar));
                                if (handler) {
                                    bridge_log("  Invoking action handler on main queue");
                                    dispatch_async(dispatch_get_main_queue(), ^{
                                        @try {
                                            handler(firstAction);
                                        } @catch (id ex) {
                                            bridge_log("  Action handler threw exception");
                                        }
                                    });
                                } else {
                                    bridge_log("  Action has no handler block");
                                }
                            } else {
                                bridge_log("  Could not find _handler ivar on UIAlertAction");
                            }
                        } else {
                            bridge_log("  UIAlertController has no actions");
                        }

                        /* Also call the completion block if provided */
                        if (completion) {
                            dispatch_async(dispatch_get_main_queue(), ^{
                                ((void(^)(void))completion)();
                            });
                        }
                        return;  /* Don't actually present — it would fail */
                    }

                    /* For non-UIAlertController presentations, try the original */
                    @try {
                        origPresentIMP(self_vc, presentSel, presented, animated, completion);
                    } @catch (id ex) {
                        bridge_log("presentViewController: failed for %s",
                                   class_getName(object_getClass(presented)));
                    }
                };

                method_setImplementation(presentMethod,
                    imp_implementationWithBlock(newBlock));
                bridge_log("  UIViewController.presentViewController: swizzled for UIAlertController auto-select");
            }
        }
    }

    /* Runtime binary patch for UIApplicationMain.
     *
     * The app uses a debug dylib loaded via dlopen at runtime. DYLD interposition
     * only applies to images loaded at startup — the debug dylib's GOT entries for
     * UIApplicationMain point to the real function, not our replacement.
     *
     * Fix: Write an x86_64 trampoline at UIApplicationMain's code address to
     * redirect ALL calls (including from dlopen'd images) to our replacement. */
    {
        /* dlsym returns our replacement due to DYLD interposition, so we
         * must find the ORIGINAL by walking Mach-O symbol tables directly. */
        void *orig_uiam = NULL;
        uint32_t img_count = _dyld_image_count();
        for (uint32_t i = 0; i < img_count && !orig_uiam; i++) {
            const char *img_name = _dyld_get_image_name(i);
            if (!img_name) continue;
            if (strstr(img_name, "rosettasim_bridge")) continue; /* skip our dylib */
            const struct mach_header *mh = _dyld_get_image_header(i);
            if (!mh || mh->magic != MH_MAGIC_64) continue;
            const struct mach_header_64 *mh64 = (const struct mach_header_64 *)mh;
            intptr_t slide = _dyld_get_image_vmaddr_slide(i);
            /* Walk load commands to find LC_SYMTAB and __LINKEDIT */
            const uint8_t *lc_ptr = (const uint8_t *)mh64 + sizeof(struct mach_header_64);
            const struct symtab_command *symtab_cmd = NULL;
            const struct segment_command_64 *linkedit_seg = NULL;
            for (uint32_t j = 0; j < mh64->ncmds; j++) {
                const struct load_command *lc = (const struct load_command *)lc_ptr;
                if (lc->cmd == LC_SYMTAB) symtab_cmd = (const struct symtab_command *)lc;
                else if (lc->cmd == LC_SEGMENT_64) {
                    const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
                    if (strcmp(seg->segname, SEG_LINKEDIT) == 0) linkedit_seg = seg;
                }
                lc_ptr += lc->cmdsize;
            }
            if (!symtab_cmd || !linkedit_seg) continue;
            uintptr_t lb = (uintptr_t)slide + linkedit_seg->vmaddr - linkedit_seg->fileoff;
            const struct nlist_64 *syms = (const struct nlist_64 *)(lb + symtab_cmd->symoff);
            const char *strs = (const char *)(lb + symtab_cmd->stroff);
            for (uint32_t k = 0; k < symtab_cmd->nsyms; k++) {
                if ((syms[k].n_type & N_TYPE) != N_SECT) continue;
                uint32_t sx = syms[k].n_un.n_strx;
                if (sx && strcmp(strs + sx, "_UIApplicationMain") == 0) {
                    orig_uiam = (void *)(syms[k].n_value + slide);
                    bridge_log("  Found original UIApplicationMain at %p in %s", orig_uiam, img_name);
                    break;
                }
            }
        }
        void *our_uiam = (void *)replacement_UIApplicationMain;
        if (orig_uiam && orig_uiam != our_uiam) {
            bridge_log("  Patching UIApplicationMain at %p → %p (runtime trampoline)", orig_uiam, our_uiam);
            vm_address_t page = (vm_address_t)orig_uiam & ~(vm_address_t)0xFFF;
            kern_return_t kr = vm_protect(mach_task_self(), page, 0x2000, FALSE,
                                           VM_PROT_READ | VM_PROT_WRITE | VM_PROT_EXECUTE);
            if (kr != KERN_SUCCESS) {
                kr = vm_protect(mach_task_self(), page, 0x1000, FALSE,
                                VM_PROT_READ | VM_PROT_WRITE | VM_PROT_EXECUTE);
            }
            if (kr == KERN_SUCCESS) {
                uint8_t *code = (uint8_t *)orig_uiam;
                uint64_t addr = (uint64_t)(uintptr_t)our_uiam;
                code[0]  = 0x48; code[1]  = 0xB8; /* movabs rax, imm64 */
                memcpy(&code[2], &addr, 8);
                code[10] = 0xFF; code[11] = 0xE0; /* jmp rax */
                /* Aggressive Rosetta cache flush:
                 * 1. Remove execute permission entirely (invalidates translation)
                 * 2. Re-add RX permissions (forces re-translation on next access)
                 * 3. sys_icache_invalidate as additional safety */
                vm_protect(mach_task_self(), page, 0x2000, FALSE,
                           VM_PROT_READ); /* remove X → invalidate Rosetta cache */
                vm_protect(mach_task_self(), page, 0x2000, FALSE,
                           VM_PROT_READ | VM_PROT_EXECUTE); /* re-add X */
                extern void sys_icache_invalidate(void *start, size_t len);
                sys_icache_invalidate(orig_uiam, 12);
                /* Verify the trampoline bytes are in place */
                bridge_log("  UIApplicationMain: trampoline bytes: %02x %02x %02x %02x ... %02x %02x",
                           code[0], code[1], code[2], code[3], code[10], code[11]);
                /* Verify by calling the original address directly with dummy args.
                 * This should trigger our replacement_UIApplicationMain. */
                bridge_log("  UIApplicationMain: runtime trampoline installed");
            } else {
                bridge_log("  UIApplicationMain: vm_protect failed 0x%x", kr);
            }
        } else if (orig_uiam == our_uiam) {
            bridge_log("  UIApplicationMain: DYLD interposition already active");
        } else {
            bridge_log("  UIApplicationMain: not found via dlsym");
        }
    }
}

/* Global exception handler — log with full context, re-throw unknown exceptions.
 *
 * Known-safe exceptions (UIKit initialization assertions) are caught and logged.
 * Unknown exceptions are re-thrown to prevent bugs from being silently hidden.
 *
 * Set ROSETTASIM_EXCEPTION_MODE env var to control behavior:
 *   "verbose"  — log all exceptions with call stack, re-throw unknown (default)
 *   "quiet"    — log one-line summary, catch all (for production use)
 *   "strict"   — log and re-throw ALL exceptions (for debugging)
 */
static int _rsim_exception_mode = 0; /* 0=verbose, 1=quiet, 2=strict */

/* Known-safe exception patterns — these occur during normal UIKit initialization
 * without backboardd and can be safely caught. */
static const char *_safe_exception_patterns[] = {
    "backboardd isn't running",
    "BKSDisplay",
    "Only one UIApplication",
    "Unable to find an active FBSWorkspace",
    "FBScene",
    "FBSScene",
    "UITextInteractionAssistant",
    /* NOTE: NSInternalInconsistencyException deliberately NOT included —
     * it's too broad and would swallow real application bugs like invalid
     * UITableView updates, CoreData violations, etc. */
    NULL
};

static void _rsim_exception_handler(id exception) {
    SEL reasonSel = sel_registerName("reason");
    SEL nameSel = sel_registerName("name");
    id reason = ((id(*)(id, SEL))objc_msgSend)(exception, reasonSel);
    id name = ((id(*)(id, SEL))objc_msgSend)(exception, nameSel);

    const char *reasonStr = reason ? ((const char *(*)(id, SEL))objc_msgSend)(
        reason, sel_registerName("UTF8String")) : "(null)";
    const char *nameStr = name ? ((const char *(*)(id, SEL))objc_msgSend)(
        name, sel_registerName("UTF8String")) : "(null)";

    /* Check if this is a known-safe exception */
    int is_safe = 0;
    if (reasonStr) {
        for (int i = 0; _safe_exception_patterns[i]; i++) {
            if (strstr(reasonStr, _safe_exception_patterns[i]) ||
                strstr(nameStr, _safe_exception_patterns[i])) {
                is_safe = 1;
                break;
            }
        }
    }

    if (_rsim_exception_mode == 1) {
        /* Quiet mode: one-line log, catch all */
        bridge_log("EXCEPTION [%s]: %s%s", nameStr, reasonStr,
                   is_safe ? " (known-safe)" : "");
        return;
    }

    /* Verbose/strict mode: log with call stack */
    bridge_log("EXCEPTION [%s]: %s", nameStr, reasonStr);

    /* Log call stack symbols if available */
    SEL csSel = sel_registerName("callStackSymbols");
    if (class_respondsToSelector(object_getClass(exception), csSel)) {
        @try {
            id symbols = ((id(*)(id, SEL))objc_msgSend)(exception, csSel);
            if (symbols) {
                long count = ((long(*)(id, SEL))objc_msgSend)(
                    symbols, sel_registerName("count"));
                long maxLines = (count < 10) ? count : 10;
                for (long i = 0; i < maxLines; i++) {
                    id sym = ((id(*)(id, SEL, long))objc_msgSend)(
                        symbols, sel_registerName("objectAtIndex:"), i);
                    const char *symStr = ((const char *(*)(id, SEL))objc_msgSend)(
                        sym, sel_registerName("UTF8String"));
                    bridge_log("  %s", symStr ? symStr : "?");
                }
                if (count > 10) bridge_log("  ... (%ld more frames)", count - 10);
            }
        } @catch (id e) { /* ignore stack trace failures */ }
    }

    if (_rsim_exception_mode == 2) {
        /* Strict mode: re-throw ALL exceptions */
        bridge_log("  STRICT MODE: re-throwing exception");
        @throw exception;
    }

    if (!is_safe) {
        /* Unknown exception in verbose mode — re-throw to surface real bugs */
        bridge_log("  UNKNOWN EXCEPTION — re-throwing (set ROSETTASIM_EXCEPTION_MODE=quiet to catch all)");
        @throw exception;
    }

    /* Known-safe exception — catch and continue */
    bridge_log("  (known-safe, continuing)");
}

__attribute__((constructor))
static void rosettasim_bridge_init(void) {
    bridge_log("========================================");
    bridge_log("RosettaSim Bridge loaded");
    bridge_log("PID: %d", getpid());

    /* Configure device profile from env vars (ITEM 15) */
    _configure_device_profile();
    bridge_log("Interposing %lu functions",
               sizeof(interposers) / sizeof(interposers[0]));

    /* Log the interposition targets */
    bridge_log("  BKSDisplayServicesStart      → stub (GSSetMainScreenInfo + return TRUE)");
    bridge_log("  BKSDisplayServicesServerPort  → MACH_PORT_NULL");
    bridge_log("  BKSDisplayServicesGetMainScreenInfo → %.0fx%.0f @%.0fx",
               kScreenWidth, kScreenHeight, kScreenScaleX);
    bridge_log("  BKSWatchdogGetIsAlive         → TRUE");
    bridge_log("  BKSWatchdogServerPort         → MACH_PORT_NULL");
    bridge_log("  CARenderServerGetServerPort   → broker lookup (fallback: MACH_PORT_NULL)");

    /* Fix bootstrap port (old dyld_sim doesn't set global).
     * When running under the broker, this sets bootstrap_port to the broker port,
     * enabling CARenderServer lookup via bootstrap_look_up. */
    fix_bootstrap_port();

    /* Also initialize the broker port for direct broker protocol messages.
     * This is used by bridge_broker_lookup() and replacement_bootstrap_look_up()
     * to communicate with the broker using custom msg_id 701. */
    {
        mach_port_t bp = MACH_PORT_NULL;
        kern_return_t bkr = task_get_special_port(mach_task_self(), TASK_BOOTSTRAP_PORT, &bp);
        if (bkr == KERN_SUCCESS && bp != MACH_PORT_NULL) {
            g_bridge_broker_port = bp;
            bridge_log("  broker port = 0x%x (from TASK_BOOTSTRAP_PORT)", bp);
        } else {
            bridge_log("  no broker port (standalone mode)");
        }
    }
    if (bootstrap_port != MACH_PORT_NULL) {
        bridge_log("  bootstrap_port = 0x%x (broker mode available)", bootstrap_port);
    }

    /* With bootstrap_fix.dylib active, look up CARenderServer via standard path.
     * This MUST happen early (before UIKit creates windows) so g_ca_server_port
     * is set and the Display Pipeline uses GPU mode.
     * bootstrap_look_up goes through bootstrap_fix → broker → returns real port. */
    if (g_bridge_broker_port != MACH_PORT_NULL) {
        mach_port_t ca_port = MACH_PORT_NULL;
        kern_return_t ca_kr = bootstrap_look_up(bootstrap_port,
                                                 "com.apple.CARenderServer", &ca_port);
        if (ca_kr == KERN_SUCCESS && ca_port != MACH_PORT_NULL) {
            g_ca_server_port = ca_port;
            g_ca_server_connected = 1;
            bridge_log("  CARenderServer found via bootstrap: port=0x%x", ca_port);

            /* Trigger connect_remote BEFORE UIKit creates any windows.
             * Creating a remoteContextWithOptions triggers CoreAnimation's
             * internal connect_remote() → __CASRegisterClient → sets
             * _user_client_port. After this, CARenderServerGetClientPort()
             * returns non-zero and UIKit creates IOSurface-backed backing stores
             * instead of LOCAL vm_allocate stores. */
            @try {
                Class caCtxCls = objc_getClass("CAContext");
                if (caCtxCls) {
                    NSDictionary *opts = @{
                        @"serverPort": @(ca_port),
                    };
                    bridge_log("  Creating early remote CAContext to trigger connect_remote...");
                    id earlyCtx = ((id(*)(id, SEL, id))objc_msgSend)(
                        (id)caCtxCls,
                        sel_registerName("remoteContextWithOptions:"),
                        opts);
                    if (earlyCtx) {
                        unsigned int cid = ((unsigned int(*)(id, SEL))objc_msgSend)(
                            earlyCtx, sel_registerName("contextId"));
                        bridge_log("  Early remote CAContext: id=%u (connect_remote should have fired)", cid);

                        /* Check if CARenderServerGetClientPort now returns non-zero */
                        typedef mach_port_t (*GetCPFn)(mach_port_t);
                        GetCPFn gcp = (GetCPFn)dlsym(RTLD_DEFAULT,
                                                      "CARenderServerGetClientPort");
                        if (gcp) {
                            mach_port_t cp = gcp(ca_port);
                            bridge_log("  CARenderServerGetClientPort()=%u %s", cp,
                                       cp ? "✓ IOSurface mode enabled" : "✗ still zero");
                        }
                    } else {
                        bridge_log("  Early remote CAContext: creation returned nil");
                    }
                }
            } @catch (id ex) {
                bridge_log("  remoteContextWithOptions threw: %s",
                           [[ex description] UTF8String] ?: "unknown");
            }
        } else {
            bridge_log("  CARenderServer bootstrap_look_up failed: kr=0x%x", ca_kr);
        }
    }

    /* Swizzle BackBoardServices methods that crash without backboardd */
    swizzle_bks_methods();

    /* rendersLocally override REMOVED — using REMOTE context (GPU compositing).
     * UIKit's +[UIApplication rendersLocally] returns NO by default,
     * which makes _createContextAttached: use the REMOTE context path. */

    /* Register NSURLProtocol bypass — routes HTTP requests through BSD sockets
     * instead of CFNetwork, which requires configd_sim. */
    _register_url_protocol();

    /* Set global exception handler — configurable via ROSETTASIM_EXCEPTION_MODE */
    {
        const char *mode = getenv("ROSETTASIM_EXCEPTION_MODE");
        if (mode) {
            if (strcmp(mode, "quiet") == 0) _rsim_exception_mode = 1;
            else if (strcmp(mode, "strict") == 0) _rsim_exception_mode = 2;
            bridge_log("Exception mode: %s", mode);
        }
    }
    typedef void (*ExHandler)(id);
    ExHandler (*setHandler)(ExHandler) = dlsym(RTLD_DEFAULT, "NSSetUncaughtExceptionHandler");
    if (setHandler) {
        setHandler(_rsim_exception_handler);
    }

    /* Set screen dimension globals directly in GraphicsServices.
       These are exported data symbols that UIScreen reads.
       Must be set before UIApplicationMain runs. */
    double *gsWidth = (double *)dlsym(RTLD_DEFAULT, "kGSMainScreenWidth");
    double *gsHeight = (double *)dlsym(RTLD_DEFAULT, "kGSMainScreenHeight");
    double *gsScale = (double *)dlsym(RTLD_DEFAULT, "kGSMainScreenScale");
    if (gsWidth) { *gsWidth = kScreenWidth; }
    if (gsHeight) { *gsHeight = kScreenHeight; }
    if (gsScale) { *gsScale = (double)kScreenScaleX; }
    bridge_log("Set screen globals: %.0fx%.0f @%.0fx",
               gsWidth ? *gsWidth : 0, gsHeight ? *gsHeight : 0,
               gsScale ? *gsScale : 0);

    /* Register SDK system fonts with CTFontManager so they're available
       regardless of bundle context. Without this, .app bundles fail to
       render text because CoreText looks for fontd/font cache instead of
       direct file enumeration. */
    {
        const char *root = getenv("IPHONE_SIMULATOR_ROOT");
        if (!root) root = getenv("DYLD_ROOT_PATH");
        if (root) {
            typedef bool (*CTRegFn)(const void *, uint32_t, void **);
            CTRegFn regFonts = (CTRegFn)dlsym(RTLD_DEFAULT,
                "CTFontManagerRegisterFontsForURL");
            typedef const void *(*CFURLCreateFn)(void *, const uint8_t *, long, bool);
            CFURLCreateFn createURL = (CFURLCreateFn)dlsym(RTLD_DEFAULT,
                "CFURLCreateFromFileSystemRepresentation");

            if (regFonts && createURL) {
                const char *dirs[] = {
                    "/System/Library/Fonts",
                    "/System/Library/Fonts/Core",
                    "/System/Library/Fonts/CoreUI",
                    "/System/Library/Fonts/CoreAddition",
                    NULL
                };
                int registered = 0;
                for (int d = 0; dirs[d]; d++) {
                    char path[1024];
                    snprintf(path, sizeof(path), "%s%s", root, dirs[d]);
                    const void *url = createURL(NULL, (const uint8_t *)path,
                        (long)strlen(path), true);
                    if (url) {
                        void *err = NULL;
                        if (regFonts(url, 1 /* kCTFontManagerScopeProcess */, &err)) {
                            registered++;
                        }
                        CFRelease(url);
                    }
                }
                bridge_log("Registered %d font directories for process", registered);
            }
        }
    }

    bridge_log("========================================");
}

__attribute__((destructor))
static void rosettasim_bridge_cleanup(void) {
    if (_fb_mmap && _fb_mmap != MAP_FAILED) {
        RosettaSimFramebufferHeader *hdr = (RosettaSimFramebufferHeader *)_fb_mmap;
        hdr->flags &= ~ROSETTASIM_FB_FLAG_APP_RUNNING;
        __sync_synchronize();
        munmap(_fb_mmap, _fb_size);
        _fb_mmap = NULL;
    }
    bridge_log("Bridge cleanup complete");
}
