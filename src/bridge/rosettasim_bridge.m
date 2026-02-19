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
#import <pthread.h>
#import <objc/runtime.h>
#import <objc/message.h>

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

/* ================================================================
 * Simulated device configuration
 * ================================================================ */

/* iPhone 6s: 375x667 points at 2x = 750x1334 pixels */
static const double kScreenWidth  = 375.0;
static const double kScreenHeight = 667.0;
static const float  kScreenScaleX = 2.0f;
static const float  kScreenScaleY = 2.0f;

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
    bridge_log("BKSDisplayServicesStart() intercepted");
    bridge_log("  Setting screen info: %.0fx%.0f @%.0fx",
               kScreenWidth, kScreenHeight, kScreenScaleX);

    /* Set the main screen info in GraphicsServices */
    GSSetMainScreenInfo(kScreenWidth, kScreenHeight, kScreenScaleX, kScreenScaleY);

    bridge_log("  GSSetMainScreenInfo called successfully");
    bridge_log("  Returning TRUE (bypassing backboardd connection)");

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
static mach_port_t replacement_BKSDisplayServicesServerPort(void) {
    bridge_log("BKSDisplayServicesServerPort() intercepted → MACH_PORT_NULL");
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

/*
 * Replace CARenderServerGetServerPort()
 *
 * Original does bootstrap_look_up("com.apple.CARenderServer").
 * Without a render server, CoreAnimation can't do remote rendering.
 * Returning MACH_PORT_NULL may force local rendering or cause a
 * different crash - we'll find out.
 */
static mach_port_t replacement_CARenderServerGetServerPort(void) {
    bridge_log("CARenderServerGetServerPort() intercepted → MACH_PORT_NULL");
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
 * abort() guard for surviving bootstrap_register failures
 *
 * GSRegisterPurpleNamedPerPIDPort calls abort() when
 * bootstrap_register fails. We interpose abort() and use
 * setjmp/longjmp to recover.
 * ================================================================ */

extern void abort(void);

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
    _exit(134);
}

/* ================================================================
 * UIApplicationMain interposition
 *
 * We wrap UIApplicationMain with setjmp/longjmp to survive the
 * abort() inside _GSEventInitializeApp → GSRegisterPurpleNamedPerPIDPort.
 *
 * Flow:
 *   1. Set abort guard
 *   2. Call original UIApplicationMain
 *   3. Original calls _UIApplicationMainPreparations:
 *      a. BKSDisplayServicesStart → our stub (succeeds)
 *      b. BKSHIDEventRegisterEventCallbackOnRunLoop → our stub
 *      c. _GSEventInitializeApp → abort() → longjmp back to us
 *   4. After recovery, manually complete initialization
 * ================================================================ */

extern int UIApplicationMain(int argc, char *argv[], id principal, id delegate);
extern void UIApplicationInitialize(void);

/* Keep track of the args for post-recovery initialization */
static int _saved_argc;
static char **_saved_argv;
static id _saved_principal_class_name;
static id _saved_delegate_class_name;

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

    /* We caught an abort - continue initialization manually */
    _abort_guard_active = 0;
    bridge_log("  Recovered from abort #%d in UIApplicationMain", abort_result);
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
                "_UIApp", "UIApp", "__sharedApplication",
                "_sharedApplication", NULL
            };
            for (int i = 0; globals[i]; i++) {
                id *ptr = (id *)dlsym(RTLD_DEFAULT, globals[i]);
                if (ptr && *ptr) {
                    app = *ptr;
                    bridge_log("  Found via %s: %p", globals[i], (void *)app);
                    break;
                }
            }

            if (!app) {
                /* Last resort: scan ObjC runtime for UIApplication instances */
                bridge_log("  Globals not found, checking if init would work...");
                bridge_log("  NOTE: UIApplication exists (init asserts 'only one')");
                bridge_log("  Skipping UIApplication creation - proceeding without app ref");
            }
        } else {
            bridge_log("  UIApplication.sharedApplication: %p", (void *)app);
        }

        if (_saved_delegate_class_name) {
            SEL utf8Sel = sel_registerName("UTF8String");
            const char *delName = ((const char *(*)(id, SEL))objc_msgSend)(_saved_delegate_class_name, utf8Sel);
            Class delClass = objc_getClass(delName);

            if (delClass) {
                SEL allocSel = sel_registerName("alloc");
                SEL initSel = sel_registerName("init");
                SEL setDelSel = sel_registerName("setDelegate:");

                id delegate = ((id(*)(id, SEL))objc_msgSend)(
                    ((id(*)(id, SEL))objc_msgSend)((id)delClass, allocSel), initSel);

                if (delegate) {
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
                    }
                }
            }
        }
    }

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
    bridge_log("  (HID events will be injected by the bridge later)");
}

/* ================================================================
 * DYLD Interposition Table
 *
 * dyld processes this at load time and redirects calls from the
 * original functions to our replacements. This works because
 * dyld_sim honors __DATA,__interpose in injected libraries.
 * ================================================================ */

typedef struct {
    const void *replacement;
    const void *replacee;
} interpose_t;

__attribute__((used))
static const interpose_t interposers[]
__attribute__((section("__DATA,__interpose"))) = {
    { (const void *)replacement_BKSDisplayServicesStart,
      (const void *)BKSDisplayServicesStart },

    { (const void *)replacement_BKSDisplayServicesServerPort,
      (const void *)BKSDisplayServicesServerPort },

    { (const void *)replacement_BKSDisplayServicesGetMainScreenInfo,
      (const void *)BKSDisplayServicesGetMainScreenInfo },

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

    /* abort() - intercept to survive bootstrap_register failures */
    { (const void *)replacement_abort,
      (const void *)abort },
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

__attribute__((constructor))
static void rosettasim_bridge_init(void) {
    bridge_log("========================================");
    bridge_log("RosettaSim Bridge loaded (Phase 4a)");
    bridge_log("PID: %d", getpid());
    bridge_log("Interposing %lu functions",
               sizeof(interposers) / sizeof(interposers[0]));

    /* Log the interposition targets */
    bridge_log("  BKSDisplayServicesStart      → stub (GSSetMainScreenInfo + return TRUE)");
    bridge_log("  BKSDisplayServicesServerPort  → MACH_PORT_NULL");
    bridge_log("  BKSDisplayServicesGetMainScreenInfo → %.0fx%.0f @%.0fx",
               kScreenWidth, kScreenHeight, kScreenScaleX);
    bridge_log("  BKSWatchdogGetIsAlive         → TRUE");
    bridge_log("  BKSWatchdogServerPort         → MACH_PORT_NULL");
    bridge_log("  CARenderServerGetServerPort   → MACH_PORT_NULL");

    /* Fix bootstrap port (old dyld_sim doesn't set global) */
    fix_bootstrap_port();

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

    bridge_log("========================================");
}
