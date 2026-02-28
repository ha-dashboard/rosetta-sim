/*
 * sim_app_installer.dylib — x86_64 constructor dylib injected into SpringBoard
 *
 * Listens for darwin notifications to install apps and launch them.
 * Uses device-specific notification names: com.rosettasim.{install,launch}.<UDID>
 * Command payload is in /tmp/rosettasim_cmd_<UDID>.json (consumed immediately).
 *
 * Build: (x86_64 iOS simulator dylib)
 *   clang -arch x86_64 -dynamiclib -framework Foundation -fobjc-arc \
 *     -mios-simulator-version-min=9.0 -install_name /usr/lib/sim_app_installer.dylib \
 *     -isysroot $(xcrun --show-sdk-path --sdk iphonesimulator) \
 *     -undefined dynamic_lookup -Wl,-not_for_dyld_shared_cache \
 *     -o sim_app_installer.dylib sim_app_installer.m
 *
 * Deploy: inject into SpringBoard via insert_dylib
 */

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#include <notify.h>
#include <CoreGraphics/CoreGraphics.h>
#include "common/rosettasim_paths.h"

static const char *g_udid = NULL;
static char g_cmd_path[512];
static char g_result_path[512];
static char g_touch_path[512];
static char g_touch_log_path[512];

/* UIASyntheticEvents touch generator (resolved after UIKit init) */
static id g_uia_generator = nil;

/* ================================================================
 * Logging
 * ================================================================ */

static void log_result(const char *fmt, ...) {
    va_list ap, ap2;
    va_start(ap, fmt);
    va_copy(ap2, ap);
    fprintf(stderr, "[app_installer] ");
    vfprintf(stderr, fmt, ap2);
    fprintf(stderr, "\n");
    va_end(ap2);

    FILE *f = fopen(g_result_path, "a");
    if (f) {
        vfprintf(f, fmt, ap);
        fprintf(f, "\n");
        fclose(f);
    }
    va_end(ap);
}

/* ================================================================
 * Touch logging (file-based — NSLog doesn't appear in host syslog)
 * ================================================================ */

static void touch_log(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void touch_log(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    FILE *f = fopen(g_touch_log_path, "a");
    if (f) {
        fprintf(f, "[touch] ");
        vfprintf(f, fmt, ap);
        fprintf(f, "\n");
        fclose(f);
    }
    va_end(ap);
}

/* ================================================================
 * Touch handler (UIASyntheticEvents — runs in SpringBoard)
 * ================================================================ */

static void handle_touch(void) {
    @autoreleasepool {
        if (!g_uia_generator) return;

        NSString *touchPath = [NSString stringWithUTF8String:g_touch_path];
        NSData *data = [NSData dataWithContentsOfFile:touchPath];
        [[NSFileManager defaultManager] removeItemAtPath:touchPath error:nil];
        if (!data || data.length == 0) return;

        touch_log("Processing %lu bytes", (unsigned long)data.length);

        NSString *content = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (!content) return;

        NSArray *lines = [content componentsSeparatedByCharactersInSet:
                          [NSCharacterSet newlineCharacterSet]];

        for (NSString *line in lines) {
            NSString *trimmed = [line stringByTrimmingCharactersInSet:
                                 [NSCharacterSet whitespaceCharacterSet]];
            if (trimmed.length == 0) continue;

            NSData *lineData = [trimmed dataUsingEncoding:NSUTF8StringEncoding];
            NSDictionary *cmd = [NSJSONSerialization JSONObjectWithData:lineData
                                                                options:0 error:nil];
            if (!cmd || ![cmd isKindOfClass:[NSDictionary class]]) continue;

            NSString *action = cmd[@"action"];
            NSNumber *xNum = cmd[@"x"];
            NSNumber *yNum = cmd[@"y"];
            if (!action || !xNum || !yNum) continue;

            float x = xNum.floatValue;
            float y = yNum.floatValue;

            CGPoint pt = CGPointMake(x, y);

            if ([action isEqualToString:@"down"]) {
                touch_log("down (%.0f,%.0f)", x, y);
                ((void(*)(id, SEL, CGPoint, NSUInteger))objc_msgSend)(
                    g_uia_generator, sel_registerName("touchDown:touchCount:"), pt, 1);
                usleep(150000); /* 150ms — UIKit needs time to register tap */
            } else if ([action isEqualToString:@"move"]) {
                touch_log("move (%.0f,%.0f)", x, y);
                SEL moveSel = sel_registerName("moveToPoint:touchCount:");
                if ([g_uia_generator respondsToSelector:moveSel]) {
                    ((void(*)(id, SEL, CGPoint, NSUInteger))objc_msgSend)(
                        g_uia_generator, moveSel, pt, 1);
                }
            } else if ([action isEqualToString:@"up"]) {
                touch_log("up (%.0f,%.0f)", x, y);
                ((void(*)(id, SEL, CGPoint, NSUInteger))objc_msgSend)(
                    g_uia_generator, sel_registerName("liftUp:touchCount:"), pt, 1);
            } else if ([action isEqualToString:@"tap"]) {
                touch_log("tap (%.0f,%.0f)", x, y);
                ((void(*)(id, SEL, CGPoint, NSUInteger))objc_msgSend)(
                    g_uia_generator, sel_registerName("touchDown:touchCount:"), pt, 1);
                usleep(150000);
                ((void(*)(id, SEL, CGPoint, NSUInteger))objc_msgSend)(
                    g_uia_generator, sel_registerName("liftUp:touchCount:"), pt, 1);
            }
        }
    }
}

static int g_touch_poll_count = 0;

static void poll_touch_file(void) {
    g_touch_poll_count++;
    NSString *touchPath = [NSString stringWithUTF8String:g_touch_path];
    if (![[NSFileManager defaultManager] fileExistsAtPath:touchPath]) return;
    handle_touch();
}

/* ================================================================
 * Install handler
 * ================================================================ */

static void handle_install(void) {
    @autoreleasepool {
        NSString *cmdPath = [NSString stringWithUTF8String:g_cmd_path];
        NSData *data = [NSData dataWithContentsOfFile:cmdPath];
        if (!data) {
            log_result("No command file at %s", g_cmd_path);
            return;
        }

        NSArray *installs = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (![installs isKindOfClass:[NSArray class]]) {
            log_result("Invalid JSON in command file");
            [[NSFileManager defaultManager] removeItemAtPath:cmdPath error:nil];
            return;
        }

        /* Remove cmd file FIRST to prevent crash-loop if MobileInstallation segfaults */
        [[NSFileManager defaultManager] removeItemAtPath:cmdPath error:nil];

        /* Clear result file */
        [@"" writeToFile:[NSString stringWithUTF8String:g_result_path]
              atomically:YES encoding:NSUTF8StringEncoding error:nil];

        /* Register apps directly with LaunchServices via LSApplicationWorkspace.
         * ALL MobileInstallation APIs go through XPC to installd and WILL deadlock
         * when called from SpringBoard (installd needs the main RunLoop for XPC
         * callbacks, but we're running ON the main RunLoop).
         * registerApplicationDictionary: talks to lsd directly — no installd, no deadlock. */

        int success = 0;
        for (NSDictionary *entry in installs) {
            if (![entry isKindOfClass:[NSDictionary class]]) {
                log_result("  Skipping non-dict entry");
                continue;
            }
            NSString *path = entry[@"path"];
            NSString *bundleId = entry[@"bundle_id"];
            if (!path || ![path isKindOfClass:[NSString class]]) {
                log_result("  Skipping entry with nil/invalid path");
                continue;
            }

            BOOL isDir = NO;
            BOOL pathExists = [[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDir];
            log_result("Installing: %s (bundleId=%s) exists=%d isDir=%d",
                      [path UTF8String],
                      bundleId ? [bundleId UTF8String] : "auto",
                      pathExists, isDir);

            if (!pathExists) {
                log_result("  SKIP: path does not exist from sim perspective");
                continue;
            }

            /* Build registration dictionary from the app's Info.plist */
            NSString *infoPlistPath = [path stringByAppendingPathComponent:@"Info.plist"];
            NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:infoPlistPath];
            if (!info) {
                log_result("  SKIP: cannot read Info.plist at %s", infoPlistPath.UTF8String);
                continue;
            }

            NSMutableDictionary *regDict = [info mutableCopy];
            regDict[@"Path"] = path;
            regDict[@"ApplicationType"] = @"User";
            /* Ensure bundle ID is set */
            if (bundleId && ![bundleId isEqualToString:@"auto"]) {
                regDict[@"CFBundleIdentifier"] = bundleId;
            }

            log_result("  Registering with LSApplicationWorkspace (bundleId=%s)...",
                      [regDict[@"CFBundleIdentifier"] UTF8String]);

            Class lsClass = objc_getClass("LSApplicationWorkspace");
            if (!lsClass) {
                log_result("  FAIL: LSApplicationWorkspace class not found");
                continue;
            }
            id workspace = ((id(*)(id, SEL))objc_msgSend)((id)lsClass,
                            sel_registerName("defaultWorkspace"));
            if (!workspace) {
                log_result("  FAIL: defaultWorkspace returned nil");
                continue;
            }

            SEL regSel = sel_registerName("registerApplicationDictionary:");
            if (![workspace respondsToSelector:regSel]) {
                log_result("  FAIL: workspace does not respond to registerApplicationDictionary:");
                continue;
            }

            BOOL regResult = ((BOOL(*)(id, SEL, id))objc_msgSend)(workspace, regSel, regDict);
            log_result("  registerApplicationDictionary: result=%d", regResult);
            success++;
        }

        if (success > 0) {
            /* On iOS 10+, SpringBoard can handle the ApplicationsChanged notification
             * without crashing. On iOS 9.x, it crashes during icon layout rebuild.
             * Check runtime version and only post on 10+. */
            NSString *runtimeVer = [[NSProcessInfo processInfo].environment
                objectForKey:@"SIMULATOR_RUNTIME_VERSION"];
            BOOL isIOS10Plus = runtimeVer && ![runtimeVer hasPrefix:@"9."] &&
                               ![runtimeVer hasPrefix:@"8."] && ![runtimeVer hasPrefix:@"7."];

            if (isIOS10Plus) {
                /* Tell SpringBoard to refresh its icon model */
                notify_post("com.apple.LaunchServices.ApplicationsChanged");
                log_result("SUCCESS: Registered %d app(s) — notified SpringBoard (iOS 10+)", success);
            } else {
                /* iOS 9.x: skip notification to avoid SpringBoard crash */
                log_result("SUCCESS: Registered %d app(s) with LaunchServices (reboot to see on home screen)", success);
            }
        } else {
            log_result("FAILED: No apps registered successfully");
        }
    }
}

/* ================================================================
 * Launch handler
 * ================================================================ */

static void handle_launch(void) {
    @autoreleasepool {
        NSString *cmdPath = [NSString stringWithUTF8String:g_cmd_path];
        NSData *data = [NSData dataWithContentsOfFile:cmdPath];
        if (!data) {
            log_result("No command file at %s", g_cmd_path);
            return;
        }

        NSDictionary *cmd = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        NSString *bundleId = cmd[@"bundle_id"];
        if (!bundleId) {
            log_result("No bundle_id in command file");
            [[NSFileManager defaultManager] removeItemAtPath:cmdPath error:nil];
            return;
        }

        log_result("Launching: %s", [bundleId UTF8String]);
        BOOL launched = NO;

        /* Approach 1: LSApplicationWorkspace */
        Class lsClass = objc_getClass("LSApplicationWorkspace");
        if (lsClass && !launched) {
            id workspace = ((id(*)(id, SEL))objc_msgSend)((id)lsClass,
                            sel_registerName("defaultWorkspace"));
            if (workspace) {
                BOOL ok = ((BOOL(*)(id, SEL, id))objc_msgSend)(workspace,
                            sel_registerName("openApplicationWithBundleID:"), bundleId);
                if (ok) {
                    log_result("  LSApplicationWorkspace: SUCCESS");
                    launched = YES;
                }
            }
        }

        /* Approach 2: FBSSystemService */
        if (!launched) {
            Class fbsClass = objc_getClass("FBSSystemService");
            if (fbsClass) {
                id service = ((id(*)(id, SEL))objc_msgSend)((id)fbsClass,
                              sel_registerName("sharedService"));
                if (service) {
                    ((void(*)(id, SEL, id, id, id))objc_msgSend)(service,
                        sel_registerName("openApplication:options:withResult:"),
                        bundleId, nil, nil);
                    log_result("  FBSSystemService: called");
                    launched = YES;
                }
            }
        }

        if (!launched) {
            log_result("  WARNING: No launch method available");
        }

        [[NSFileManager defaultManager] removeItemAtPath:cmdPath error:nil];
    }
}

/* ================================================================
 * Also process legacy global pending files (backward compat)
 * ================================================================ */

static void process_legacy_pending(void) {
    @autoreleasepool {
        /* Check global pending installs file */
        NSString *globalInstall = @"/tmp/rosettasim_pending_installs.json";
        if ([[NSFileManager defaultManager] fileExistsAtPath:globalInstall]) {
            /* Copy to device-specific path and trigger install */
            NSData *data = [NSData dataWithContentsOfFile:globalInstall];
            if (data) {
                [data writeToFile:[NSString stringWithUTF8String:g_cmd_path] atomically:YES];
                [[NSFileManager defaultManager] removeItemAtPath:globalInstall error:nil];
                handle_install();
            }
        }

        /* Check global pending launch file */
        NSString *globalLaunch = @"/tmp/rosettasim_pending_launch.txt";
        if ([[NSFileManager defaultManager] fileExistsAtPath:globalLaunch]) {
            NSString *bundleId = [NSString stringWithContentsOfFile:globalLaunch
                                                           encoding:NSUTF8StringEncoding error:nil];
            if (bundleId.length > 0) {
                bundleId = [bundleId stringByTrimmingCharactersInSet:
                            [NSCharacterSet whitespaceAndNewlineCharacterSet]];
                NSDictionary *cmd = @{@"bundle_id": bundleId};
                NSData *json = [NSJSONSerialization dataWithJSONObject:cmd options:0 error:nil];
                [json writeToFile:[NSString stringWithUTF8String:g_cmd_path] atomically:YES];
                [[NSFileManager defaultManager] removeItemAtPath:globalLaunch error:nil];
                handle_launch();
            }
        }
    }
}

/* ================================================================
 * Constructor
 * ================================================================ */

/* ================================================================
 * File-polling fallback for cross-namespace IPC
 *
 * Darwin notifications don't cross the host↔sim boundary (different
 * notifyd instances). We use a 2-second polling timer on the cmd file
 * as the primary mechanism, with darwin notify as a bonus for same-
 * namespace callers.
 * ================================================================ */

static int g_poll_count = 0;

static BOOL g_boot_reregistered = NO;

static void reregister_on_boot(void) {
    if (g_boot_reregistered) return;
    g_boot_reregistered = YES;

    @autoreleasepool {
        NSString *lsMapPath = [NSHomeDirectory()
            stringByAppendingPathComponent:@ROSETTASIM_DEV_INSTALLED_APPS];
        NSDictionary *lsMap = [NSDictionary dictionaryWithContentsOfFile:lsMapPath];
        NSDictionary *userApps = lsMap[@"User"];
        if (!userApps.count) return;

        NSLog(@"[app_installer] Re-registering %lu apps on boot", (unsigned long)userApps.count);

        Class lsClass = objc_getClass("LSApplicationWorkspace");
        if (!lsClass) return;
        id workspace = ((id(*)(id, SEL))objc_msgSend)((id)lsClass,
                        sel_registerName("defaultWorkspace"));
        if (!workspace) return;
        SEL regSel = sel_registerName("registerApplicationDictionary:");

        for (NSString *bundleId in userApps) {
            NSDictionary *appInfo = userApps[bundleId];
            NSString *appPath = appInfo[@"Path"];
            if (!appPath || ![[NSFileManager defaultManager] fileExistsAtPath:appPath]) continue;
            NSString *plistPath = [appPath stringByAppendingPathComponent:@"Info.plist"];
            NSMutableDictionary *regDict = [NSMutableDictionary dictionaryWithContentsOfFile:plistPath];
            if (!regDict) continue;
            regDict[@"Path"] = appPath;
            regDict[@"ApplicationType"] = @"User";
            BOOL ok = ((BOOL(*)(id, SEL, id))objc_msgSend)(workspace, regSel, regDict);
            NSLog(@"[app_installer] Re-registered %@: %@", bundleId, ok ? @"YES" : @"NO");
        }

        NSString *runtimeVer = [[NSProcessInfo processInfo].environment
            objectForKey:@"SIMULATOR_RUNTIME_VERSION"];
        if (runtimeVer && ![runtimeVer hasPrefix:@"9."] &&
            ![runtimeVer hasPrefix:@"8."] && ![runtimeVer hasPrefix:@"7."]) {
            notify_post("com.apple.LaunchServices.ApplicationsChanged");
        }
    }
}

static void poll_cmd_file(void) {
    g_poll_count++;
    /* Re-register apps from plist on first few polls (after boot) */
    if (g_poll_count == 5) reregister_on_boot();

    NSString *cmdPath = [NSString stringWithUTF8String:g_cmd_path];
    BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:cmdPath];
    if (g_poll_count <= 5 || (exists) || (g_poll_count % 30 == 0)) {
        NSLog(@"[app_installer] Poll #%d: %s exists=%d", g_poll_count, g_cmd_path, exists);
    }
    if (!exists) return;

    NSData *data = [NSData dataWithContentsOfFile:cmdPath];
    if (!data) {
        NSLog(@"[app_installer] Poll: file exists but read returned nil (race?)");
        return;
    }

    NSLog(@"[app_installer] Poll: read %lu bytes from cmd file", (unsigned long)data.length);

    /* Peek at the content to determine action type */
    NSError *jsonErr = nil;
    id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonErr];
    if (!parsed) {
        NSLog(@"[app_installer] Poll: JSON parse failed: %@", jsonErr);
        [[NSFileManager defaultManager] removeItemAtPath:cmdPath error:nil];
        return;
    }
    if ([parsed isKindOfClass:[NSArray class]]) {
        /* Array = install command */
        handle_install();
    } else if ([parsed isKindOfClass:[NSDictionary class]]) {
        NSDictionary *cmd = (NSDictionary *)parsed;
        NSString *action = cmd[@"action"];
        if ([action isEqualToString:@"openurl"]) {
            /* openurl: extract URL and open via LSApplicationWorkspace or UIApplication */
            NSString *url = cmd[@"url"];
            if (url) {
                log_result("Opening URL: %s", url.UTF8String);
                Class lsClass = objc_getClass("LSApplicationWorkspace");
                if (lsClass) {
                    id workspace = ((id(*)(id, SEL))objc_msgSend)((id)lsClass,
                                    sel_registerName("defaultWorkspace"));
                    if (workspace) {
                        NSURL *nsurl = [NSURL URLWithString:url];
                        if (nsurl) {
                            ((BOOL(*)(id, SEL, id))objc_msgSend)(workspace,
                                sel_registerName("openURL:"), nsurl);
                            log_result("  openURL dispatched");
                        }
                    }
                }
                [[NSFileManager defaultManager] removeItemAtPath:cmdPath error:nil];
            }
        } else if (cmd[@"bundle_id"] && !action) {
            /* Dict with bundle_id but no action = launch command */
            handle_launch();
        } else {
            /* Unknown action — remove file to avoid stuck loop */
            log_result("Unknown cmd action: %s", action ? action.UTF8String : "(null)");
            [[NSFileManager defaultManager] removeItemAtPath:cmdPath error:nil];
        }
    }
}

__attribute__((constructor))
static void sim_app_installer_init(void) {
    /* Try SIMULATOR_UDID first (iOS 10+), fall back to IPHONE_SIMULATOR_DEVICE (iOS 7-9) */
    g_udid = getenv("SIMULATOR_UDID");
    if (!g_udid || !g_udid[0]) {
        g_udid = getenv("IPHONE_SIMULATOR_DEVICE");
    }
    if (!g_udid || !g_udid[0]) {
        /* Last resort: try to read from device.plist */
        NSLog(@"[app_installer] No UDID env var found (checked SIMULATOR_UDID, IPHONE_SIMULATOR_DEVICE) — disabled");
        return;
    }

    snprintf(g_cmd_path, sizeof(g_cmd_path), ROSETTASIM_HOST_CMD_FMT, g_udid);
    snprintf(g_result_path, sizeof(g_result_path), ROSETTASIM_HOST_RESULT_FMT, g_udid);

    /* Touch command file path — in sim's home/tmp */
    NSString *home = NSHomeDirectory();
    snprintf(g_touch_path, sizeof(g_touch_path), "%s/" ROSETTASIM_DEV_TOUCH_FILE, home.UTF8String);
    snprintf(g_touch_log_path, sizeof(g_touch_log_path), "%s/" ROSETTASIM_DEV_TOUCH_LOG, home.UTF8String);
    [[NSFileManager defaultManager] createDirectoryAtPath:[home stringByAppendingPathComponent:@"tmp"]
                              withIntermediateDirectories:YES attributes:nil error:nil];

    NSLog(@"[app_installer] cmd_path set to: %s", g_cmd_path);
    NSLog(@"[app_installer] result_path set to: %s", g_result_path);
    NSLog(@"[app_installer] touch_path set to: %s", g_touch_path);

    NSLog(@"[app_installer] Registering for device %s", g_udid);

    /* Register darwin notifications (works for same-namespace callers) */
    char install_name[256];
    snprintf(install_name, sizeof(install_name), "com.rosettasim.install.%s", g_udid);
    int install_token = 0;
    uint32_t install_status = notify_register_dispatch(install_name, &install_token,
        dispatch_get_main_queue(), ^(int token) { handle_install(); });

    char launch_name[256];
    snprintf(launch_name, sizeof(launch_name), "com.rosettasim.launch.%s", g_udid);
    int launch_token = 0;
    uint32_t launch_status = notify_register_dispatch(launch_name, &launch_token,
        dispatch_get_main_queue(), ^(int token) { handle_launch(); });

    NSLog(@"[app_installer] Notify registration: install=%s (status=%u token=%d), launch=%s (status=%u token=%d)",
          install_name, install_status, install_token,
          launch_name, launch_status, launch_token);

    /* Start polling as primary IPC mechanism.
     * Darwin notifications don't cross the host↔sim boundary (different notifyd).
     * Use recursive dispatch_after (safer than dispatch_source under Rosetta 2). */
    __block void (^poll_loop)(void) = ^{
        poll_cmd_file();
        if (g_poll_count <= 3)
            NSLog(@"[app_installer] Scheduling next poll in 2s (poll #%d)", g_poll_count);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                       dispatch_get_main_queue(), poll_loop);
    };
    /* Prevent block from being deallocated */
    poll_loop = [poll_loop copy];
    /* First poll fires immediately (0.1s) — SpringBoard may crash-loop on 5s cycle */
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), poll_loop);

    NSLog(@"[app_installer] Listening: %s, %s + polling every 2s", install_name, launch_name);

    /* Process legacy pending files after delay (backward compat) */
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        process_legacy_pending();
    });

    /* Touch injection via UIASyntheticEvents — init after 3s to let UIKit fully start */
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        touch_log("=== UIA touch init ===");

        void *ua = dlopen("/Developer/Library/PrivateFrameworks/UIAutomation.framework/UIAutomation", RTLD_NOW);
        touch_log("dlopen Developer UIAutomation: %p (err=%s)", ua, ua ? "none" : dlerror());
        if (!ua) {
            ua = dlopen("/System/Library/PrivateFrameworks/UIAutomation.framework/UIAutomation", RTLD_NOW);
            touch_log("dlopen System UIAutomation: %p (err=%s)", ua, ua ? "none" : dlerror());
        }

        Class synthCls = objc_getClass("UIASyntheticEvents");
        touch_log("UIASyntheticEvents class: %p", synthCls);

        if (synthCls) {
            g_uia_generator = ((id(*)(id, SEL))objc_msgSend)(
                (id)synthCls, sel_registerName("sharedEventGenerator"));
            touch_log("sharedEventGenerator: %p", g_uia_generator);

            if (g_uia_generator) {
                SEL tdSel = sel_registerName("touchDown:touchCount:");
                SEL luSel = sel_registerName("liftUp:touchCount:");
                touch_log("touchDown:touchCount: responds=%d", [g_uia_generator respondsToSelector:tdSel]);
                touch_log("liftUp:touchCount: responds=%d", [g_uia_generator respondsToSelector:luSel]);
            }
        }

        if (!g_uia_generator) {
            touch_log("Touch injection DISABLED — UIASyntheticEvents not available");
            return;
        }

        /* Start fast touch poll loop (100ms on main queue) */
        __block void (^touch_poll_loop)(void) = ^{
            poll_touch_file();
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC),
                           dispatch_get_main_queue(), touch_poll_loop);
        };
        touch_poll_loop = [touch_poll_loop copy];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), touch_poll_loop);

        touch_log("Touch poll started (100ms, UIA)");
        touch_log("touch_path: %s", g_touch_path);
    });

}
