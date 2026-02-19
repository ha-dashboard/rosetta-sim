/*
 * Phase 3: UIApplicationMain Initialization
 *
 * This test attempts to call UIApplicationMain() to initialize the
 * full UIKit stack. We expect it to crash when it tries to connect
 * to display services (backboardd/SpringBoard/SimulatorBridge).
 *
 * The goal is to determine:
 *   1. How far UIKit initialization gets before failing
 *   2. What services/connections it tries to establish
 *   3. What error we get (the specific failure tells us what to build)
 *
 * We install a signal handler and uncaught exception handler to capture
 * the failure mode cleanly.
 *
 * Compile:
 *   clang -arch x86_64 -isysroot {SDK} -mios-simulator-version-min=10.0
 *         -framework CoreFoundation -framework Foundation -framework UIKit
 *         -fobjc-arc -o phase3_test phase3_test.m
 *
 * Run:
 *   DYLD_ROOT_PATH={SDK} ./phase3_test
 */

#import <stdlib.h>
#import <string.h>
#import <unistd.h>
#import <stdio.h>
#import <stdarg.h>
#import <signal.h>
#import <dlfcn.h>
#import <execinfo.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <CoreFoundation/CoreFoundation.h>
#import <Foundation/Foundation.h>

/* ---- Raw output (avoids buffering issues) ---- */
static char _buf[8192];
void out(const char *msg) {
    write(STDOUT_FILENO, msg, strlen(msg));
}
void outf(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(_buf, sizeof(_buf), fmt, ap);
    va_end(ap);
    if (n > 0) write(STDOUT_FILENO, _buf, n);
}

/* ---- Signal handler to capture crashes ---- */
void signal_handler(int sig) {
    outf("\n!!! SIGNAL %d received", sig);
    switch (sig) {
        case SIGABRT: out(" (SIGABRT - abort)\n"); break;
        case SIGSEGV: out(" (SIGSEGV - segfault)\n"); break;
        case SIGBUS:  out(" (SIGBUS - bus error)\n"); break;
        case SIGTRAP: out(" (SIGTRAP - trap)\n"); break;
        case SIGILL:  out(" (SIGILL - illegal instruction)\n"); break;
        default: out("\n"); break;
    }

    /* Print backtrace */
    void *frames[64];
    int count = backtrace(frames, 64);
    out("\nBacktrace:\n");
    backtrace_symbols_fd(frames, count, STDOUT_FILENO);

    out("\n--- Phase 3 ended with signal ---\n");
    _exit(128 + sig);
}

/* ---- Uncaught exception handler ---- */
void uncaught_exception_handler(id exception) {
    out("\n!!! UNCAUGHT EXCEPTION !!!\n");

    /* Get exception info via ObjC runtime */
    SEL nameSel = sel_registerName("name");
    SEL reasonSel = sel_registerName("reason");
    SEL utf8Sel = sel_registerName("UTF8String");

    id name = ((id(*)(id, SEL))objc_msgSend)(exception, nameSel);
    id reason = ((id(*)(id, SEL))objc_msgSend)(exception, reasonSel);

    const char *nameStr = name ? ((const char *(*)(id, SEL))objc_msgSend)(name, utf8Sel) : "(null)";
    const char *reasonStr = reason ? ((const char *(*)(id, SEL))objc_msgSend)(reason, utf8Sel) : "(null)";

    outf("  Name:   %s\n", nameStr);
    outf("  Reason: %s\n", reasonStr);

    /* Print backtrace */
    void *frames[64];
    int count = backtrace(frames, 64);
    out("\nBacktrace:\n");
    backtrace_symbols_fd(frames, count, STDOUT_FILENO);

    out("\n--- Phase 3 ended with exception ---\n");
    _exit(1);
}

/* ---- Minimal App Delegate ---- */
@interface RosettaSimAppDelegate : NSObject
@end

@implementation RosettaSimAppDelegate

- (BOOL)application:(id)application didFinishLaunchingWithOptions:(id)options {
    out("\n*** application:didFinishLaunchingWithOptions: CALLED! ***\n");
    out("*** UIKit initialization succeeded! ***\n");

    /* If we get here, UIKit is fully initialized */
    /* Report what we have */
    Class uiScreenClass = objc_getClass("UIScreen");
    if (uiScreenClass) {
        SEL mainScreenSel = sel_registerName("mainScreen");
        id mainScreen = ((id(*)(id, SEL))objc_msgSend)((id)uiScreenClass, mainScreenSel);
        if (mainScreen) {
            out("  UIScreen.mainScreen exists\n");
        } else {
            out("  UIScreen.mainScreen is nil\n");
        }
    }

    Class uiDeviceClass = objc_getClass("UIDevice");
    if (uiDeviceClass) {
        SEL currentSel = sel_registerName("currentDevice");
        SEL modelSel = sel_registerName("model");
        SEL systemVersionSel = sel_registerName("systemVersion");
        SEL utf8Sel = sel_registerName("UTF8String");

        id device = ((id(*)(id, SEL))objc_msgSend)((id)uiDeviceClass, currentSel);
        if (device) {
            id model = ((id(*)(id, SEL))objc_msgSend)(device, modelSel);
            id version = ((id(*)(id, SEL))objc_msgSend)(device, systemVersionSel);

            const char *modelStr = model ? ((const char *(*)(id, SEL))objc_msgSend)(model, utf8Sel) : "(null)";
            const char *versionStr = version ? ((const char *(*)(id, SEL))objc_msgSend)(version, utf8Sel) : "(null)";

            outf("  UIDevice.model: %s\n", modelStr);
            outf("  UIDevice.systemVersion: %s\n", versionStr);
        }
    }

    /* Don't actually run the app - just exit successfully */
    out("\n*** Phase 3 FULLY PASSED - exiting ***\n");
    _exit(0);

    return YES;
}
@end

/* ---- Main ---- */
int main(int argc, char *argv[]) {
    out("╔══════════════════════════════════════════════════════╗\n");
    out("║  RosettaSim Phase 3: UIApplicationMain              ║\n");
    out("╚══════════════════════════════════════════════════════╝\n\n");

    const char *sdk_root = getenv("DYLD_ROOT_PATH");
    if (!sdk_root) {
        out("ERROR: DYLD_ROOT_PATH not set\n");
        return 1;
    }
    outf("SDK Root: %s\n", sdk_root);
    outf("PID: %d\n\n", getpid());

    /* Install signal handlers */
    out("Installing signal handlers...\n");
    signal(SIGABRT, signal_handler);
    signal(SIGSEGV, signal_handler);
    signal(SIGBUS,  signal_handler);
    signal(SIGTRAP, signal_handler);
    signal(SIGILL,  signal_handler);

    /* Install uncaught exception handler */
    out("Installing exception handler...\n");

    /* Use NSSetUncaughtExceptionHandler via dlsym */
    typedef void (*NSSetUncaughtExceptionHandlerFunc)(void (*)(id));
    NSSetUncaughtExceptionHandlerFunc setHandler =
        (NSSetUncaughtExceptionHandlerFunc)dlsym(RTLD_DEFAULT, "NSSetUncaughtExceptionHandler");
    if (setHandler) {
        setHandler(uncaught_exception_handler);
        out("Exception handler installed.\n");
    } else {
        out("WARNING: Could not install exception handler.\n");
    }

    /* Pre-flight checks */
    out("\n--- Pre-flight checks ---\n");

    Class uiAppClass = objc_getClass("UIApplication");
    outf("  UIApplication class: %p %s\n", (__bridge void*)uiAppClass, uiAppClass ? "✓" : "✗");

    Class delegateClass = objc_getClass("RosettaSimAppDelegate");
    outf("  RosettaSimAppDelegate class: %p %s\n", (__bridge void*)delegateClass, delegateClass ? "✓" : "✗");

    void *uiAppMainSym = dlsym(RTLD_DEFAULT, "UIApplicationMain");
    outf("  UIApplicationMain symbol: %p %s\n", uiAppMainSym, uiAppMainSym ? "✓" : "✗");

    /* Set simulator environment variables that UIKit checks */
    setenv("SIMULATOR_DEVICE_NAME", "iPhone 6s", 1);
    setenv("SIMULATOR_MODEL_IDENTIFIER", "iPhone8,1", 1);
    setenv("SIMULATOR_RUNTIME_VERSION", "10.3", 1);
    setenv("SIMULATOR_MAINSCREEN_WIDTH", "750", 1);
    setenv("SIMULATOR_MAINSCREEN_HEIGHT", "1334", 1);
    setenv("SIMULATOR_MAINSCREEN_SCALE", "2.0", 1);

    out("\nSimulator environment set:\n");
    out("  SIMULATOR_DEVICE_NAME=iPhone 6s\n");
    out("  SIMULATOR_MODEL_IDENTIFIER=iPhone8,1\n");
    out("  SIMULATOR_RUNTIME_VERSION=10.3\n");
    out("  SIMULATOR_MAINSCREEN_WIDTH=750\n");
    out("  SIMULATOR_MAINSCREEN_HEIGHT=1334\n");
    out("  SIMULATOR_MAINSCREEN_SCALE=2.0\n");

    out("\n--- Calling UIApplicationMain() ---\n");
    out("(Expecting crash when UIKit tries to connect to display services)\n\n");

    @autoreleasepool {
        /* UIApplicationMain(argc, argv, principalClassName, delegateClassName) */
        /* This is the moment of truth. */
        typedef int (*UIApplicationMainFunc)(int, char *[], id, id);
        UIApplicationMainFunc uiAppMain = (UIApplicationMainFunc)uiAppMainSym;

        NSString *delegateName = @"RosettaSimAppDelegate";
        int result = uiAppMain(argc, argv, nil, delegateName);

        outf("\nUIApplicationMain returned: %d\n", result);
        outf("(This is unexpected - UIApplicationMain normally never returns)\n");
    }

    return 0;
}
