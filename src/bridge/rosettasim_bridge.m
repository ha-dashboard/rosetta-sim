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
#import <signal.h>
#import <pthread.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <sys/mman.h>
#import <sys/stat.h>
#import <fcntl.h>
#import <mach/mach_time.h>
#import <CoreFoundation/CoreFoundation.h>

#include "../shared/rosettasim_framebuffer.h"

/* Forward declarations for frame capture system */
static id _bridge_delegate = nil;
static void find_root_window(id delegate);
static void start_frame_capture(void);
static void _mark_display_dirty(void);

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
    _exit(134);
}

/*
 * Replace exit() - catch workspace server disconnect exit during init.
 * The FBSWorkspace connection failure calls exit() on an XPC callback thread.
 * During startup (_init_phase = 1), we block ALL exits. After the app enters
 * the run loop, we allow exits normally.
 */
static volatile int _init_phase = 1;  /* 1 = during startup, 0 = app running */

static void replacement_exit(int status) {
    if (_init_phase) {
        bridge_log("exit(%d) BLOCKED during init phase (workspace disconnect expected)", status);
        /* The workspace server disconnect calls exit() on an XPC callback thread.
         * Returning from exit() is UB and causes SIGSEGV. Instead, terminate
         * only THIS thread (the XPC callback thread) using pthread_exit().
         * The main thread continues UIApplicationMain initialization. */
        if (!pthread_main_np()) {
            bridge_log("  Terminating XPC callback thread via pthread_exit");
            pthread_exit(NULL);
            /* not reached */
        }
        /* If we're on the main thread, use longjmp if guard is active */
        if (_abort_guard_active) {
            bridge_log("  exit() on main thread inside guard → longjmp recovery");
            longjmp(_abort_recovery, 200 + status);
            /* not reached */
        }
        /* Last resort: block this thread forever (prevent process exit) */
        bridge_log("  exit() on main thread outside guard → blocking thread");
        while (1) { sleep(86400); }
    }
    bridge_log("exit(%d) called in running phase → terminating", status);
    _exit(status);
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

                    /* Call didFinishLaunchingWithOptions: */
                    SEL didFinishSel = sel_registerName("application:didFinishLaunchingWithOptions:");
                    Class appObjClass = object_getClass(app);
                    if (class_respondsToSelector(appObjClass, didFinishSel)) {
                        bridge_log("  Calling %s application:didFinishLaunchingWithOptions:", delName);
                        ((void(*)(id, SEL, id, id))objc_msgSend)(app, didFinishSel, app, nil);
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
    bridge_log("  (HID events will be injected by the bridge later)");
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
static id _bridge_root_window = nil;

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

    int fd = open(path, O_RDWR | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) {
        bridge_log("ERROR: Could not create framebuffer file: %s", path);
        return -1;
    }

    if (ftruncate(fd, _fb_size) < 0) {
        bridge_log("ERROR: Could not size framebuffer to %zu bytes", _fb_size);
        close(fd);
        return -1;
    }

    _fb_mmap = mmap(NULL, _fb_size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);

    if (_fb_mmap == MAP_FAILED) {
        bridge_log("ERROR: mmap failed for framebuffer");
        _fb_mmap = NULL;
        return -1;
    }

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

    bridge_log("Shared framebuffer: %dx%d (%zu bytes) at %s", px_w, px_h, _fb_size, path);
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

        /* 4. Private UIKit backing views — only if they actually override drawing.
         * The old catch-all `className[0] == '_'` created false positives on
         * container views (_UIBarBackground, _UILayoutGuide) that use only
         * backgroundColor. Forcing display on them creates empty opaque backing
         * stores that cover the backgroundColor. */
        if (!hasCustomDrawing) {
            const char *className = class_getName(cls);
            if (className && className[0] == '_') {
                /* Verify the private class actually overrides drawRect: */
                if (drawRectIMP != baseDrawRectIMP) hasCustomDrawing = 1;
            }
        }

        if (hasCustomDrawing) {
            /* Only call setNeedsDisplay if the layer has no content yet.
             * Calling setNeedsDisplay on a layer with valid content destroys
             * the existing backing store, causing a flash until displayIfNeeded
             * repopulates it. */
            id contents = ((id(*)(id, SEL))objc_msgSend)(layer, sel_registerName("contents"));
            if (!contents) {
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

static void _sendEvent_crash_handler(int sig) {
    if (_sendEvent_guard_active) {
        _sendEvent_guard_active = 0;
        siglongjmp(_sendEvent_recovery, sig);
        /* not reached */
    }
    /* Not our crash — invoke previous handler */
    struct sigaction *prev = (sig == SIGSEGV) ? &_prev_sigsegv_action : &_prev_sigbus_action;
    if (prev->sa_flags & SA_SIGINFO) {
        /* Can't call sa_sigaction without siginfo_t, just re-raise */
        signal(sig, SIG_DFL);
        raise(sig);
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

/* Recursive hit testing — walks the view hierarchy to find the deepest
 * view containing the point, respecting userInteractionEnabled and hidden. */
static id _hitTestView(id view, _RSBridgeCGPoint windowPt) {
    if (!view) return nil;

    SEL convertSel = sel_registerName("convertPoint:fromView:");
    SEL pointInsideSel = sel_registerName("pointInside:withEvent:");
    typedef _RSBridgeCGPoint (*convertPt_fn)(id, SEL, _RSBridgeCGPoint, id);
    typedef bool (*pointInside_fn)(id, SEL, _RSBridgeCGPoint, id);

    /* Convert to view-local coords */
    _RSBridgeCGPoint localPt = ((convertPt_fn)objc_msgSend)(
        view, convertSel, windowPt, nil); /* nil = window coords */

    /* Check containment */
    bool inside = ((pointInside_fn)objc_msgSend)(view, pointInsideSel, localPt, nil);
    if (!inside) return nil;

    /* Check userInteractionEnabled */
    bool enabled = ((bool(*)(id, SEL))objc_msgSend)(
        view, sel_registerName("isUserInteractionEnabled"));
    if (!enabled) return nil;

    /* Check hidden */
    bool hidden = ((bool(*)(id, SEL))objc_msgSend)(
        view, sel_registerName("isHidden"));
    if (hidden) return nil;

    /* Walk subviews back-to-front (topmost first) */
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

static void check_and_inject_touch(void) {
    if (!_fb_mmap || !_bridge_root_window) return;

    /* Read input region */
    RosettaSimInputRegion *inp = (RosettaSimInputRegion *)((uint8_t *)_fb_mmap + ROSETTASIM_FB_HEADER_SIZE);

    /* Check if there's a new touch event */
    static uint64_t last_touch_counter = 0;
    uint64_t current_counter = inp->touch_counter;

    if (current_counter == last_touch_counter) {
        return; /* No new touch */
    }
    last_touch_counter = current_counter;

    /* Memory barrier: ensure we see the fields written before the counter (Fix #6) */
    __sync_synchronize();

    uint32_t phase = inp->touch_phase;
    if (phase == ROSETTASIM_TOUCH_NONE) return;

    /* Get touch coordinates (in points) */
    double tx = (double)inp->touch_x;
    double ty = (double)inp->touch_y;

    bridge_log("Touch event #%llu: phase=%u x=%.1f y=%.1f",
               current_counter, phase, tx, ty);

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

    if (app && touchClass) {
        /* Create UITouch on BEGAN only (Fix #3: drop orphan MOVED/ENDED) */
        if (phase == ROSETTASIM_TOUCH_BEGAN) {
            /* Release previous touch if any */
            if (_bridge_current_touch) {
                ((void(*)(id, SEL))objc_msgSend)(_bridge_current_touch, sel_registerName("release"));
                _bridge_current_touch = nil;
            }
            /* Keep _bridge_current_event for reuse — _clearTouches resets it (Fix #5) */

            /* Allocate UITouch */
            _bridge_current_touch = ((id(*)(id, SEL))objc_msgSend)(
                ((id(*)(id, SEL))objc_msgSend)((id)touchClass, sel_registerName("alloc")),
                sel_registerName("init"));
            if (_bridge_current_touch) {
                ((id(*)(id, SEL))objc_msgSend)(_bridge_current_touch, sel_registerName("retain"));
            }
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

            /* ---- Proper UITouchesEvent delivery ----
             *
             * [UIApplication _touchesEvent] returns nil because _eventDispatcher
             * was never initialized (our longjmp recovery skips that code path).
             * Instead, create our own UITouchesEvent using _init (which calls
             * _UITouchesEventCommonInit to create all internal dictionaries),
             * then populate with _addTouch:forDelayedDelivery: and sendEvent:.
             *
             * Wrapped in SIGSEGV/SIGBUS guard for safety under Rosetta 2.
             */
            SEL clearTouchesSel = sel_registerName("_clearTouches");
            SEL addTouchSel = sel_registerName("_addTouch:forDelayedDelivery:");
            SEL sendEventSel = sel_registerName("sendEvent:");

            /* Create or reuse our bridge-owned UITouchesEvent */
            if (!_bridge_current_event) {
                Class touchesEventClass = objc_getClass("UITouchesEvent");
                if (touchesEventClass) {
                    SEL initSel = sel_registerName("_init");
                    if (class_respondsToSelector(touchesEventClass, initSel) ||
                        class_getInstanceMethod(touchesEventClass, initSel)) {
                        @try {
                            _bridge_current_event = ((id(*)(id, SEL))objc_msgSend)(
                                ((id(*)(id, SEL))objc_msgSend)((id)touchesEventClass,
                                    sel_registerName("alloc")),
                                initSel);
                            if (_bridge_current_event) {
                                ((id(*)(id, SEL))objc_msgSend)(_bridge_current_event,
                                    sel_registerName("retain"));
                                bridge_log("  Created bridge-owned UITouchesEvent: %p",
                                           (void *)_bridge_current_event);
                            }
                        } @catch (id e) {
                            bridge_log("  UITouchesEvent _init threw exception");
                            _bridge_current_event = nil;
                        }
                    }
                }
            }

            id touchesEvent = _bridge_current_event;

            if (touchesEvent) {
                /* Clear previous touch data (empties dicts, does NOT nil them) */
                @try {
                    ((void(*)(id, SEL))objc_msgSend)(touchesEvent, clearTouchesSel);
                } @catch (id e) { /* ignore */ }

                /* Populate internal dictionaries via direct ivar manipulation.
                 *
                 * We can't use _addTouch:forDelayedDelivery: because it calls
                 * _addGestureRecognizersForView:toTouch: which crashes when
                 * UIScrollView's gesture recognizers check internal state that
                 * doesn't exist without backboardd.
                 *
                 * Manual approach: get ivar offsets for _touches, _keyedTouches,
                 * _keyedTouchesByWindow and populate them directly. The dictionary
                 * keys are raw pointers (NULL key callbacks). */
                Class teClass = object_getClass(touchesEvent);
                Ivar touchesIvar = class_getInstanceVariable(teClass, "_touches");
                Ivar keyedIvar = class_getInstanceVariable(teClass, "_keyedTouches");
                Ivar byWindowIvar = class_getInstanceVariable(teClass, "_keyedTouchesByWindow");

                if (touchesIvar && keyedIvar && byWindowIvar) {
                    ptrdiff_t touchesOff = ivar_getOffset(touchesIvar);
                    ptrdiff_t keyedOff = ivar_getOffset(keyedIvar);
                    ptrdiff_t byWindowOff = ivar_getOffset(byWindowIvar);

                    /* _touches is an NSMutableSet */
                    id touchesSet = *(id *)((uint8_t *)touchesEvent + touchesOff);
                    /* _keyedTouches and _keyedTouchesByWindow are CFMutableDictionaryRef */
                    CFMutableDictionaryRef keyedDict = *(CFMutableDictionaryRef *)((uint8_t *)touchesEvent + keyedOff);
                    CFMutableDictionaryRef byWindowDict = *(CFMutableDictionaryRef *)((uint8_t *)touchesEvent + byWindowOff);

                    if (touchesSet && keyedDict && byWindowDict) {
                        /* Add touch to _touches */
                        ((void(*)(id, SEL, id))objc_msgSend)(touchesSet,
                            sel_registerName("addObject:"), _bridge_current_touch);

                        /* Add to _keyedTouches[view] */
                        if (targetView) {
                            const void *viewKey = (__bridge const void *)targetView;
                            id viewSet = (id)CFDictionaryGetValue(keyedDict, viewKey);
                            if (!viewSet) {
                                viewSet = ((id(*)(id, SEL))objc_msgSend)(
                                    (id)objc_getClass("NSMutableSet"), sel_registerName("set"));
                                CFDictionarySetValue(keyedDict, viewKey, (__bridge const void *)viewSet);
                            }
                            ((void(*)(id, SEL, id))objc_msgSend)(viewSet,
                                sel_registerName("addObject:"), _bridge_current_touch);
                        }

                        /* Add to _keyedTouchesByWindow[window] — THIS IS THE CRITICAL ONE */
                        if (_bridge_root_window) {
                            const void *winKey = (__bridge const void *)_bridge_root_window;
                            id winSet = (id)CFDictionaryGetValue(byWindowDict, winKey);
                            if (!winSet) {
                                winSet = ((id(*)(id, SEL))objc_msgSend)(
                                    (id)objc_getClass("NSMutableSet"), sel_registerName("set"));
                                CFDictionarySetValue(byWindowDict, winKey, (__bridge const void *)winSet);
                            }
                            ((void(*)(id, SEL, id))objc_msgSend)(winSet,
                                sel_registerName("addObject:"), _bridge_current_touch);
                        }

                        bridge_log("  Populated UITouchesEvent dicts via ivar manipulation");
                    } else {
                        bridge_log("  UITouchesEvent internal sets/dicts are nil");
                        touchesEvent = nil;
                    }
                } else {
                    bridge_log("  Could not find UITouchesEvent ivars");
                    touchesEvent = nil;
                }
            }

            if (touchesEvent) {
                /* Store reference to singleton (NOT retained — it's app-owned) */
                _bridge_current_event = touchesEvent;

                /* Install SIGSEGV/SIGBUS handlers if not yet done */
                if (!_sendEvent_handlers_installed) {
                    struct sigaction sa;
                    memset(&sa, 0, sizeof(sa));
                    sa.sa_handler = _sendEvent_crash_handler;
                    sigemptyset(&sa.sa_mask);
                    sa.sa_flags = 0; /* No SA_RESTART — we want siglongjmp */
                    sigaction(SIGSEGV, &sa, &_prev_sigsegv_action);
                    sigaction(SIGBUS, &sa, &_prev_sigbus_action);
                    _sendEvent_handlers_installed = 1;
                }

                /* Try sendEvent: with crash guard */
                _sendEvent_guard_active = 1;
                int crash_sig = sigsetjmp(_sendEvent_recovery, 1);
                if (crash_sig == 0) {
                    /* Normal path — deliver the event */
                    bridge_log("  Delivering via [UIApplication sendEvent:] with UITouchesEvent");
                    ((void(*)(id, SEL, id))objc_msgSend)(app, sendEventSel, touchesEvent);
                    _sendEvent_guard_active = 0;
                    sendEvent_succeeded = 1;
                    bridge_log("  sendEvent: delivery succeeded");
                    /* Fall through to direct delivery for UIControl tracking.
                     * Our sendEvent: replacement delivers touchesBegan:/touchesEnded:
                     * to views, but UIControl needs explicit beginTracking/endTracking/
                     * sendActionsForControlEvents to fire target-action handlers.
                     * The direct delivery code below handles this. */
                } else {
                    /* Crashed in sendEvent: — recovered via siglongjmp */
                    bridge_log("  sendEvent: CRASHED (signal %d) — falling through to direct delivery",
                               crash_sig);
                    _sendEvent_guard_active = 0;
                    /* Fall through to direct_delivery below */
                }
            } else {
                bridge_log("  UITouchesEvent singleton unavailable — using direct delivery");
            }
        }
    }

/* direct_delivery: */
    /* ---- Approach 2: Direct touch + UIControl tracking (fallback) ---- */
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

    if (controlTarget && _bridge_current_touch) {
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
            /* UITextField: becomeFirstResponder is now swizzled to avoid the
               UITextInteractionAssistant gesture recognizer crash. Call it
               to enter editing mode and fire delegate callbacks. */
            if (phase == ROSETTASIM_TOUCH_BEGAN) {
                @try {
                    ((bool(*)(id, SEL))objc_msgSend)(controlTarget,
                        sel_registerName("becomeFirstResponder"));
                    bridge_log("  UITextField becomeFirstResponder (swizzled)");
                } @catch (id e) {
                    bridge_log("  UITextField becomeFirstResponder failed");
                }
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

                    /* Estimate segment width (control frame is tricky to get via stret) */
                    /* Use a simple heuristic: divide 375 points by segment count
                     * and use the X position to determine which segment */
                    long newSeg = currentSel;
                    if (numSegs > 0) {
                        /* Get segment widths from subview positions */
                        double segWidth = 335.0 / numSegs; /* approximate control width */
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

static uint32_t _last_key_code = 0;

static void check_and_inject_keyboard(void) {
    if (!_fb_mmap || !_bridge_root_window) return;

    RosettaSimInputRegion *inp = (RosettaSimInputRegion *)((uint8_t *)_fb_mmap + ROSETTASIM_FB_HEADER_SIZE);

    uint32_t key_code = inp->key_code;
    if (key_code == 0) return; /* No pending key event */

    uint32_t key_flags = inp->key_flags;
    uint32_t key_char = inp->key_char;

    /* Clear key_code immediately to acknowledge processing */
    inp->key_code = 0;
    inp->key_flags = 0;
    inp->key_char = 0;
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
        /* Backspace / Delete */
        SEL deleteBackSel = sel_registerName("deleteBackward");
        if (class_respondsToSelector(object_getClass(firstResponder), deleteBackSel)) {
            @try {
                ((void(*)(id, SEL))objc_msgSend)(firstResponder, deleteBackSel);
                bridge_log("  Delivered deleteBackward");
            } @catch (id e) {
                bridge_log("  deleteBackward failed");
            }
        } else if (hasInsertText) {
            /* Some text inputs don't have deleteBackward — try deleteBackward: */
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
            /* For UITextField, Return typically ends editing.
             * Check if it's a UITextField and resign first responder. */
            if (uiTextFieldClass) {
                Class c = object_getClass(firstResponder);
                int isTF = 0;
                while (c) {
                    if (c == uiTextFieldClass) { isTF = 1; break; }
                    c = class_getSuperclass(c);
                }
                if (isTF) {
                    @try {
                        ((bool(*)(id, SEL))objc_msgSend)(firstResponder,
                            sel_registerName("resignFirstResponder"));
                        bridge_log("  UITextField resignFirstResponder (Return)");
                    } @catch (id e) { /* ignore */ }
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

    /* Regular character input */
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

        @try {
            id charStr = ((id(*)(id, SEL, const char *))objc_msgSend)(
                (id)objc_getClass("NSString"),
                sel_registerName("stringWithUTF8String:"), utf8);
            if (charStr) {
                ((void(*)(id, SEL, id))objc_msgSend)(firstResponder, insertTextSel, charStr);
                bridge_log("  Delivered insertText: '%s'", utf8);
            }
        } @catch (id e) {
            bridge_log("  insertText failed for char 0x%x", key_char);
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

/* Called after a touch event mutates the UI — schedule a few force-display frames */
static void _mark_display_dirty(void) {
    if (_force_display_countdown < 5) _force_display_countdown = 5;
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

    /* Check for and inject touch events from host */
    check_and_inject_touch();

    /* Check for and inject keyboard events from host */
    check_and_inject_keyboard();

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
     * and animations), but skip the expensive _force_display_recursive walk. */
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
        /* Scale for Retina. CG origin is bottom-left; the host app handles
           the vertical flip when displaying. Do NOT flip here — negative Y
           scale mirrors text glyphs rendered by CoreText. */
        _cg_ScaleCTM(ctx, (double)kScreenScaleX, (double)kScreenScaleY);

        /* Render the layer tree into the local buffer */
        ((void(*)(id, SEL, void *))objc_msgSend)(
            layer, sel_registerName("renderInContext:"), ctx);

        _cg_Release(ctx);

        /* Copy completed frame to shared framebuffer in one shot */
        memcpy(pixels, _render_buffer, pixel_size);
        __sync_synchronize();
        hdr->frame_counter++;
        hdr->timestamp_ns = mach_absolute_time();
        hdr->flags |= ROSETTASIM_FB_FLAG_FRAME_READY;
    }
    _cg_ReleaseCS(cs);
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

    /* Create a repeating timer on the current run loop at ~30fps */
    double interval = 1.0 / 30.0;
    CFRunLoopTimerRef timer = CFRunLoopTimerCreate(
        NULL,                             /* allocator */
        CFAbsoluteTimeGetCurrent() + 0.1, /* first fire (100ms delay) */
        interval,                         /* repeat interval */
        0, 0,                             /* flags, order */
        frame_capture_tick,               /* callback */
        NULL);                            /* context */

    CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, kCFRunLoopCommonModes);
    bridge_log("Frame capture started (%.0f FPS target)", 1.0 / interval);
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

    /* bootstrap_register2 - make Purple port registration succeed */
    { (const void *)replacement_bootstrap_register2,
      (const void *)bootstrap_register2 },

    /* abort() - intercept to survive bootstrap_register failures */
    { (const void *)replacement_abort,
      (const void *)abort },

    /* exit() - intercept workspace server disconnect exit during init */
    { (const void *)replacement_exit,
      (const void *)exit },
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

/* ================================================================
 * UIApplication._sendTouchesForEvent: replacement
 *
 * The original crashes in gesture recognizer processing because
 * UIGestureEnvironment and _gestureRecognizersByWindow are never
 * initialized (UIEventDispatcher was skipped during longjmp recovery).
 *
 * This replacement bypasses gesture recognizer processing entirely
 * and delivers touches directly to views via their touchesBegan:/
 * touchesMoved:/touchesEnded:/touchesCancelled: methods. UIControl
 * subclasses handle tracking internally via their overrides.
 * ================================================================ */

static void replacement_sendTouchesForEvent(id self, SEL _cmd, id event) {
    if (!event) return;

    /* Check if this is a UITouchesEvent by looking for _touches ivar.
     * If not, it's a different event type (motion, remote, etc.) — skip it.
     * This method may be installed as either _sendTouchesForEvent: (receives
     * only touch events) or sendEvent: (receives all events). */
    Class teClass = object_getClass(event);
    Ivar touchesIvar = class_getInstanceVariable(teClass, "_touches");
    if (!touchesIvar) {
        /* Not a touches event — nothing to do */
        return;
    }

    ptrdiff_t touchesOff = ivar_getOffset(touchesIvar);
    id touchesSet = *(id *)((uint8_t *)event + touchesOff);
    if (!touchesSet) return;

    id allTouches = ((id(*)(id, SEL))objc_msgSend)(
        touchesSet, sel_registerName("allObjects"));
    long count = ((long(*)(id, SEL))objc_msgSend)(
        allTouches, sel_registerName("count"));

    for (long i = 0; i < count; i++) {
        id touch = ((id(*)(id, SEL, long))objc_msgSend)(
            allTouches, sel_registerName("objectAtIndex:"), i);

        long phase = ((long(*)(id, SEL))objc_msgSend)(
            touch, sel_registerName("phase"));
        id view = ((id(*)(id, SEL))objc_msgSend)(
            touch, sel_registerName("view"));
        if (!view) continue;

        /* Select touch method based on UITouchPhase:
         *   0 = UITouchPhaseBegan
         *   1 = UITouchPhaseMoved
         *   2 = UITouchPhaseStationary (skip)
         *   3 = UITouchPhaseEnded
         *   4 = UITouchPhaseCancelled */
        SEL touchSel = nil;
        switch (phase) {
            case 0: touchSel = sel_registerName("touchesBegan:withEvent:"); break;
            case 1: touchSel = sel_registerName("touchesMoved:withEvent:"); break;
            case 3: touchSel = sel_registerName("touchesEnded:withEvent:"); break;
            case 4: touchSel = sel_registerName("touchesCancelled:withEvent:"); break;
            default: continue;
        }

        id touchSet = ((id(*)(id, SEL, id))objc_msgSend)(
            (id)objc_getClass("NSSet"),
            sel_registerName("setWithObject:"), touch);

        @try {
            ((void(*)(id, SEL, id, id))objc_msgSend)(
                view, touchSel, touchSet, event);
        } @catch (id e) {
            bridge_log("  _sendTouchesForEvent: delivery to %s threw exception",
                       class_getName(object_getClass(view)));
        }
    }
}

/* ================================================================
 * UITextField.becomeFirstResponder replacement
 *
 * The original crashes because UITextInteractionAssistant tries to
 * set gesture recognizers, which requires UIGestureEnvironment
 * (not initialized without backboardd).
 *
 * This replacement sets the editing state directly, fires delegate
 * callbacks, and posts notifications — enabling the app's text field
 * handlers to run. Keyboard input is delivered via the mmap mechanism.
 * ================================================================ */

static bool replacement_UITextFieldBecomeFirstResponder(id self, SEL _cmd) {
    bridge_log("  [UITextField becomeFirstResponder] intercepted: %p", (void *)self);

    /* Check delegate's textFieldShouldBeginEditing: */
    SEL delegateSel = sel_registerName("delegate");
    id delegate = nil;
    if (class_respondsToSelector(object_getClass(self), delegateSel)) {
        delegate = ((id(*)(id, SEL))objc_msgSend)(self, delegateSel);
    }
    if (delegate) {
        SEL shouldBeginSel = sel_registerName("textFieldShouldBeginEditing:");
        if (class_respondsToSelector(object_getClass(delegate), shouldBeginSel)) {
            @try {
                bool should = ((bool(*)(id, SEL, id))objc_msgSend)(
                    delegate, shouldBeginSel, self);
                if (!should) {
                    bridge_log("  textFieldShouldBeginEditing: returned NO");
                    return false;
                }
            } @catch (id e) { /* proceed */ }
        }
    }

    /* Set _editing ivar to YES */
    Class tfClass = objc_getClass("UITextField");
    if (tfClass) {
        Ivar editingIvar = class_getInstanceVariable(tfClass, "_traits");
        /* _editing may be a bitfield inside _traits, or a standalone ivar.
         * Try the standalone first. */
        Ivar directEditIvar = class_getInstanceVariable(tfClass, "_editing");
        if (directEditIvar) {
            bool *ptr = (bool *)((uint8_t *)self + ivar_getOffset(directEditIvar));
            *ptr = true;
        }
    }

    /* Register as first responder.
     * The keyboard injection code finds the first responder via multiple paths:
     *   1. [UIApplication _firstResponder]
     *   2. [keyWindow firstResponder]
     * We need to make sure at least one of these returns our text field.
     * Try multiple approaches to maximize compatibility. */
    {
        /* Store a reference the keyboard code can find */
        /* Approach 1: Set on UIWindow via _setFirstResponder: (private) */
        if (_bridge_root_window) {
            SEL setFRSel = sel_registerName("_setFirstResponder:");
            if (class_respondsToSelector(object_getClass(_bridge_root_window), setFRSel)) {
                @try {
                    ((void(*)(id, SEL, id))objc_msgSend)(
                        _bridge_root_window, setFRSel, self);
                    bridge_log("  Set first responder via window._setFirstResponder:");
                } @catch (id e) { /* ignore */ }
            }
        }

        /* Approach 2: Call UIResponder's base becomeFirstResponder (which does NOT
         * touch gesture recognizers — that's UITextField's override that crashes).
         * UIResponder.becomeFirstResponder calls [UIApplication _setFirstResponder:]. */
        Class uiResponderClass = objc_getClass("UIResponder");
        if (uiResponderClass) {
            SEL bfrSel = sel_registerName("becomeFirstResponder");
            /* Get UIResponder's implementation (not UITextField's swizzled one) */
            Method responderMethod = class_getInstanceMethod(uiResponderClass, bfrSel);
            if (responderMethod) {
                IMP responderBFR = method_getImplementation(responderMethod);
                if (responderBFR) {
                    @try {
                        ((bool(*)(id, SEL))responderBFR)(self, bfrSel);
                        bridge_log("  Called UIResponder.becomeFirstResponder (base)");
                    } @catch (id e) {
                        bridge_log("  UIResponder.becomeFirstResponder threw exception");
                    }
                }
            }
        }
    }

    /* Fire textFieldDidBeginEditing: delegate callback */
    if (delegate) {
        SEL didBeginSel = sel_registerName("textFieldDidBeginEditing:");
        if (class_respondsToSelector(object_getClass(delegate), didBeginSel)) {
            @try {
                ((void(*)(id, SEL, id))objc_msgSend)(delegate, didBeginSel, self);
                bridge_log("  Called textFieldDidBeginEditing:");
            } @catch (id e) {
                bridge_log("  textFieldDidBeginEditing: threw exception");
            }
        }
    }

    /* Post UITextFieldTextDidBeginEditingNotification */
    Class nsCenterClass = objc_getClass("NSNotificationCenter");
    id center = nsCenterClass ? ((id(*)(id, SEL))objc_msgSend)(
        (id)nsCenterClass, sel_registerName("defaultCenter")) : nil;
    if (center) {
        id notifName = ((id(*)(id, SEL, const char *))objc_msgSend)(
            (id)objc_getClass("NSString"),
            sel_registerName("stringWithUTF8String:"),
            "UITextFieldTextDidBeginEditingNotification");
        ((void(*)(id, SEL, id, id, id))objc_msgSend)(
            center, sel_registerName("postNotificationName:object:userInfo:"),
            notifName, self, nil);
        bridge_log("  Posted UITextFieldTextDidBeginEditingNotification");
    }

    return true;
}

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

/* Replacement for -[UIWindow makeKeyAndVisible].
   The original triggers BKSEventFocusManager which crashes without backboardd.
   We perform the essential parts: show the window, load the rootViewController's
   view into the window, and trigger layout — skipping event registration. */
static void replacement_makeKeyAndVisible(id self, SEL _cmd) {
    bridge_log("  [UIWindow makeKeyAndVisible] intercepted");

    /* 1. Set layer visible */
    id layer = ((id(*)(id, SEL))objc_msgSend)(self, sel_registerName("layer"));
    if (layer) {
        ((void(*)(id, SEL, bool))objc_msgSend)(layer, sel_registerName("setHidden:"), false);
    }

    /* 2. Load rootViewController's view into the window if not already there.
       Normally makeKeyAndVisible triggers _installRootViewControllerIntoWindow:
       which does this, but that path crashes via BKSEventFocusManager. */
    SEL rvcSel = sel_registerName("rootViewController");
    if (class_respondsToSelector(object_getClass(self), rvcSel)) {
        id rootVC = ((id(*)(id, SEL))objc_msgSend)(self, rvcSel);
        if (rootVC) {
            id rootView = ((id(*)(id, SEL))objc_msgSend)(rootVC, sel_registerName("view"));
            if (rootView) {
                /* Check if rootView is already in the window */
                id superview = ((id(*)(id, SEL))objc_msgSend)(rootView, sel_registerName("superview"));
                if (!superview || superview != self) {
                    /* Set frame to window's screen size (avoid CGRect struct return
                       which crashes under Rosetta 2 — 32 bytes requires stret). */
                    _RSBridgeCGRect windowFrame = {0, 0, kScreenWidth, kScreenHeight};
                    typedef void (*setFrameFn)(id, SEL, _RSBridgeCGRect);
                    ((setFrameFn)objc_msgSend)(rootView, sel_registerName("setFrame:"), windowFrame);

                    /* Add to window */
                    ((void(*)(id, SEL, id))objc_msgSend)(self, sel_registerName("addSubview:"), rootView);
                    bridge_log("  Added rootViewController.view (%s) to window",
                               class_getName(object_getClass(rootView)));
                }

                /* Notify view controller of appearance lifecycle.
                   Both viewWillAppear: and viewDidAppear: are needed:
                   - viewWillAppear: triggers UIAppearance proxy application
                   - viewDidAppear: triggers post-layout theme code in many apps */
                @try {
                    ((void(*)(id, SEL, bool))objc_msgSend)(rootVC,
                        sel_registerName("viewWillAppear:"), false);
                } @catch (id e) { /* ignore */ }
                @try {
                    ((void(*)(id, SEL, bool))objc_msgSend)(rootVC,
                        sel_registerName("viewDidAppear:"), false);
                } @catch (id e) { /* ignore */ }
            }
        }
    }

    /* 3. Register this as the bridge key window.
       The key window swizzles (isKeyWindow on UIWindow, keyWindow on UIApplication)
       are installed in swizzle_bks_methods(). They use _bridge_root_window to
       determine which window is "key". Just ensure that's set here. */
    _bridge_root_window = self;
    ((id(*)(id, SEL))objc_msgSend)(self, sel_registerName("retain"));
    bridge_log("  Set _bridge_root_window = %p (isKeyWindow will return YES)", (void *)self);

    /* 4. Set window level to UIWindowLevelNormal (0) to ensure proper ordering */
    @try {
        ((void(*)(id, SEL, double))objc_msgSend)(self,
            sel_registerName("setWindowLevel:"), 0.0);
    } @catch (id e) { /* ignore */ }

    /* 5. Force layout */
    ((void(*)(id, SEL))objc_msgSend)(self, sel_registerName("setNeedsLayout"));
    ((void(*)(id, SEL))objc_msgSend)(self, sel_registerName("layoutIfNeeded"));

    bridge_log("  makeKeyAndVisible complete — window visible with rootVC view");
}

/* Replacement for -[UIWindow isKeyWindow].
   Returns YES for _bridge_root_window, NO for all others. */
static bool replacement_isKeyWindow(id self, SEL _cmd) {
    return (self == _bridge_root_window);
}

/* Replacement for -[UIApplication keyWindow].
   Returns _bridge_root_window directly. */
static id replacement_keyWindow(id self, SEL _cmd) {
    return _bridge_root_window;
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

    /* Call _callInitializationDelegatesForMainScene:transitionContext:
     * This is the UIKit method that:
     *   - Loads the main storyboard/nib
     *   - Creates the delegate
     *   - Calls application:didFinishLaunchingWithOptions:
     *   - Calls makeKeyAndVisible (via storyboard loading)
     *   - Posts UIApplicationDidFinishLaunchingNotification
     *   - Calls applicationDidBecomeActive:
     */
    SEL callInitSel = sel_registerName("_callInitializationDelegatesForMainScene:transitionContext:");
    if (class_respondsToSelector(object_getClass(self), callInitSel)) {
        bridge_log("  Calling _callInitializationDelegatesForMainScene:");
        @try {
            ((void(*)(id, SEL, id, id))objc_msgSend)(
                self, callInitSel, scene, transitionContext);
            bridge_log("  _callInitializationDelegatesForMainScene: completed");
        } @catch (id e) {
            SEL reasonSel = sel_registerName("reason");
            id reason = ((id(*)(id, SEL))objc_msgSend)(e, reasonSel);
            const char *str = reason ? ((const char *(*)(id, SEL))objc_msgSend)(
                reason, sel_registerName("UTF8String")) : "(unknown)";
            bridge_log("  _callInitializationDelegatesForMainScene threw: %s", str);
        }
    } else {
        bridge_log("  _callInitializationDelegatesForMainScene: not found — calling completion block");
        /* Fallback: call the completion block directly */
        if (completionBlock) {
            @try {
                typedef void (^VoidBlock)(void);
                ((VoidBlock)completionBlock)();
                bridge_log("  Completion block executed");
            } @catch (id e) {
                bridge_log("  Completion block threw exception");
            }
        }
    }

    /* Set up frame capture (rendering pipeline) */
    bridge_log("  Setting up frame capture from _runWithMainScene...");
    find_root_window(_bridge_delegate);
    start_frame_capture();

    /* Mark init complete — exit() calls are now allowed */
    _init_phase = 0;

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
            method_setImplementation(m, (IMP)replacement_makeKeyAndVisible);
        }

        /* UIWindow.isKeyWindow — return YES for our bridge root window */
        SEL ikwSel = sel_registerName("isKeyWindow");
        Method ikwMethod = class_getInstanceMethod(windowClass, ikwSel);
        if (ikwMethod) {
            method_setImplementation(ikwMethod, (IMP)replacement_isKeyWindow);
            bridge_log("  Swizzled UIWindow.isKeyWindow");
        }
    }

    /* UIApplication.keyWindow — return _bridge_root_window directly */
    Class appClass = objc_getClass("UIApplication");
    if (appClass) {
        SEL kwSel = sel_registerName("keyWindow");
        Method kwMethod = class_getInstanceMethod(appClass, kwSel);
        if (kwMethod) {
            method_setImplementation(kwMethod, (IMP)replacement_keyWindow);
            bridge_log("  Swizzled UIApplication.keyWindow");
        }
    }

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

    /* Prevent FBSWorkspace XPC connection from being initiated.
       FBSWorkspaceClient connects to SpringBoard via XPC. When the connection
       fails (no SpringBoard), it calls exit(0) on the XPC callback thread.
       By preventing the connection, we avoid both the exit and the blocking
       semaphore wait in scene creation.

       Swizzle FBSWorkspaceClient init methods to return nil. */
    {
        Class fbsWsClientClass = objc_getClass("FBSWorkspaceClient");
        if (fbsWsClientClass) {
            const char *initSelNames[] = {
                "initWithServiceName:endpoint:",
                "initWithDelegate:",
                NULL
            };
            for (int s = 0; initSelNames[s]; s++) {
                SEL sel = sel_registerName(initSelNames[s]);
                Method m = class_getInstanceMethod(fbsWsClientClass, sel);
                if (m) {
                    method_setImplementation(m, (IMP)_noopMethod);
                    bridge_log("  Swizzled FBSWorkspaceClient.%s → nil", initSelNames[s]);
                }
            }
        }

        Class fbsWsClass = objc_getClass("FBSWorkspace");
        if (fbsWsClass) {
            SEL initSel = sel_registerName("init");
            Method m = class_getInstanceMethod(fbsWsClass, initSel);
            if (m) {
                method_setImplementation(m, (IMP)_noopMethod);
                bridge_log("  Swizzled FBSWorkspace.init → nil");
            }
        }
    }

    /* UIApplication.sendEvent: — the original calls _sendTouchesForEvent:
       which crashes in gesture recognizer processing because UIGestureEnvironment
       is not initialized. Replace with a version that handles UITouchesEvent
       directly and passes other event types through. */
    if (appClass) {
        /* Try _sendTouchesForEvent: first (internal method) */
        SEL stfeSel = sel_registerName("_sendTouchesForEvent:");
        Method m = class_getInstanceMethod(appClass, stfeSel);
        if (m) {
            method_setImplementation(m, (IMP)replacement_sendTouchesForEvent);
            bridge_log("  Swizzled UIApplication._sendTouchesForEvent:");
        } else {
            /* _sendTouchesForEvent: not found — swizzle sendEvent: directly.
               Store original IMP to call for non-touch events. */
            SEL sendEventSel = sel_registerName("sendEvent:");
            Method sem = class_getInstanceMethod(appClass, sendEventSel);
            if (sem) {
                /* We can't easily chain to original for non-touch events without
                   storing the original IMP. Instead, just replace with our version
                   that handles UITouchesEvent and no-ops other event types. */
                method_setImplementation(sem, (IMP)replacement_sendTouchesForEvent);
                bridge_log("  Swizzled UIApplication.sendEvent: (fallback)");
            }
        }
    }

    /* UITextField.becomeFirstResponder — crashes in UITextInteractionAssistant
       gesture recognizer setup */
    Class textFieldClass = objc_getClass("UITextField");
    if (textFieldClass) {
        SEL bfrSel = sel_registerName("becomeFirstResponder");
        Method m = class_getInstanceMethod(textFieldClass, bfrSel);
        if (m) {
            method_setImplementation(m, (IMP)replacement_UITextFieldBecomeFirstResponder);
            bridge_log("  Swizzled UITextField.becomeFirstResponder");
        }
    }

    /* BKSEventFocusManager - event focus management */
    const char *classesToSwizzle[] = {
        "BKSEventFocusManager",
        "BKSAnimationFenceHandle",
        NULL
    };

    for (int c = 0; classesToSwizzle[c]; c++) {
        Class cls = objc_getClass(classesToSwizzle[c]);
        if (!cls) continue;

        unsigned int methodCount = 0;
        Method *methods = class_copyMethodList(cls, &methodCount);
        if (!methods) continue;

        for (unsigned int i = 0; i < methodCount; i++) {
            /* Replace all methods that might call into backboardd */
            SEL sel = method_getName(methods[i]);
            const char *name = sel_getName(sel);
            /* Only swizzle methods that look like they'd contact backboardd */
            if (strstr(name, "defer") || strstr(name, "Defer") ||
                strstr(name, "register") || strstr(name, "fence") ||
                strstr(name, "invalidate") || strstr(name, "client")) {
                method_setImplementation(methods[i], (IMP)_noopMethod);
            }
        }
        free(methods);
        bridge_log("  Swizzled %s backboardd-calling methods", classesToSwizzle[c]);
    }
}

/* Global exception handler — log and survive non-critical assertions */
static void _rsim_exception_handler(id exception) {
    SEL reasonSel = sel_registerName("reason");
    id reason = ((id(*)(id, SEL))objc_msgSend)(exception, reasonSel);
    if (reason) {
        const char *str = ((const char *(*)(id, SEL))objc_msgSend)(
            reason, sel_registerName("UTF8String"));
        bridge_log("CAUGHT EXCEPTION: %s", str ? str : "(null)");
    }
    /* Don't re-throw — allow the process to continue */
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

    /* Swizzle BackBoardServices methods that crash without backboardd */
    swizzle_bks_methods();

    /* Set global exception handler for non-critical assertion failures */
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
