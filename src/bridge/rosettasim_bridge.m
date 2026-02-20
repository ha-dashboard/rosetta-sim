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

    /* Set up continuous frame capture before starting the run loop */
    bridge_log("  Setting up frame capture...");
    find_root_window(_bridge_delegate);
    start_frame_capture();

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

    bridge_log("Shared framebuffer: %dx%d (%zu bytes) at %s", px_w, px_h, _fb_size, path);
    return 0;
}

/* Recursively force all layers in the tree to display their content */
static void _force_display_recursive(id layer, int depth) {
    if (!layer || depth > 20) return; /* guard against infinite recursion */

    ((void(*)(id, SEL))objc_msgSend)(layer, sel_registerName("setNeedsDisplay"));
    ((void(*)(id, SEL))objc_msgSend)(layer, sel_registerName("displayIfNeeded"));

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

static void frame_capture_tick(CFRunLoopTimerRef timer, void *info) {
    if (!_bridge_root_window || !_fb_mmap) return;
    if (!_cg_CreateColorSpace || !_cg_CreateBitmap) return;

    RosettaSimFramebufferHeader *hdr = (RosettaSimFramebufferHeader *)_fb_mmap;
    void *pixels = (uint8_t *)_fb_mmap + ROSETTASIM_FB_HEADER_SIZE;

    int px_w = hdr->width;
    int px_h = hdr->height;

    /* Get root window's layer */
    id layer = ((id(*)(id, SEL))objc_msgSend)(
        _bridge_root_window, sel_registerName("layer"));
    if (!layer) return;

    /* Ensure root layer is visible (set on CALayer, not UIView, to avoid
       triggering UIKit's BKSEventFocusManager which needs backboardd) */
    ((void(*)(id, SEL, bool))objc_msgSend)(layer, sel_registerName("setHidden:"), false);

    /* Flush pending CATransaction changes (no CARenderServer to do this) */
    Class caTransaction = objc_getClass("CATransaction");
    if (caTransaction) {
        ((void(*)(id, SEL))objc_msgSend)((id)caTransaction, sel_registerName("flush"));
    }

    /* Force layout */
    ((void(*)(id, SEL))objc_msgSend)(
        _bridge_root_window, sel_registerName("setNeedsLayout"));
    ((void(*)(id, SEL))objc_msgSend)(
        _bridge_root_window, sel_registerName("layoutIfNeeded"));

    /* Recursively force entire layer tree to populate backing stores.
       Without CARenderServer, the normal display cycle never runs. */
    _force_display_recursive(layer, 0);

    /* Create bitmap context over framebuffer pixel region */
    void *cs = _cg_CreateColorSpace();
    /* kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little = 0x2002 */
    void *ctx = _cg_CreateBitmap(pixels, px_w, px_h, 8, px_w * 4, cs, 0x2002);

    if (ctx) {
        /* Flip Y and scale for Retina.
           CGBitmapContext origin is bottom-left (first pixel in memory = bottom).
           We want standard image order (first pixel = top-left) so the host
           app can display it directly without flipping.
           Transform: translate to top of pixel buffer, then scale with negative Y. */
        _cg_TranslateCTM(ctx, 0, (double)px_h);
        _cg_ScaleCTM(ctx, (double)kScreenScaleX, -(double)kScreenScaleY);

        /* Render the layer tree into the bitmap */
        ((void(*)(id, SEL, void *))objc_msgSend)(
            layer, sel_registerName("renderInContext:"), ctx);

        /* Memory barrier then update header */
        __sync_synchronize();
        hdr->frame_counter++;
        hdr->timestamp_ns = mach_absolute_time();
        hdr->flags |= ROSETTASIM_FB_FLAG_FRAME_READY;

        _cg_Release(ctx);
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

static void swizzle_bks_methods(void) {
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
