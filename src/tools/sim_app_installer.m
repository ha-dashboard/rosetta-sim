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

static const char *g_udid = NULL;
static char g_cmd_path[512];
static char g_result_path[512];

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

        /* Clear result file */
        [@"" writeToFile:[NSString stringWithUTF8String:g_result_path]
              atomically:YES encoding:NSUTF8StringEncoding error:nil];

        /* Resolve MobileInstallationInstallForLaunchServices */
        typedef long (*MIInstallFn)(NSString *path, NSDictionary *opts, void *cb, NSString *caller);
        MIInstallFn miInstall = (MIInstallFn)dlsym(RTLD_DEFAULT,
            "MobileInstallationInstallForLaunchServices");
        if (!miInstall) {
            log_result("MobileInstallationInstallForLaunchServices not found");
            [[NSFileManager defaultManager] removeItemAtPath:cmdPath error:nil];
            return;
        }

        int success = 0;
        for (NSDictionary *entry in installs) {
            NSString *path = entry[@"path"];
            NSString *bundleId = entry[@"bundle_id"];
            if (!path) continue;

            log_result("Installing: %s (bundleId=%s)", [path UTF8String],
                      bundleId ? [bundleId UTF8String] : "auto");

            NSDictionary *opts = @{
                @"PackageType": @"Developer",
                @"AllowInstallLocalProvisioned": @YES,
            };

            long result = miInstall(path, opts, NULL, @"rosettasim");
            log_result("  result=%ld (%s)", result, result == 0 ? "SUCCESS" : "FAILED");
            if (result == 0) success++;
        }

        if (success > 0) {
            notify_post("com.apple.LaunchServices.ApplicationsChanged");
            notify_post("com.apple.mobile.application_installed");
            log_result("Installed %d app(s), notifications posted", success);
        }

        [[NSFileManager defaultManager] removeItemAtPath:cmdPath error:nil];
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

static void poll_cmd_file(void) {
    NSString *cmdPath = [NSString stringWithUTF8String:g_cmd_path];
    if (![[NSFileManager defaultManager] fileExistsAtPath:cmdPath]) return;

    NSData *data = [NSData dataWithContentsOfFile:cmdPath];
    if (!data) return;

    /* Peek at the content to determine action type */
    id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
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

    snprintf(g_cmd_path, sizeof(g_cmd_path), "/tmp/rosettasim_cmd_%s.json", g_udid);
    snprintf(g_result_path, sizeof(g_result_path), "/tmp/rosettasim_install_result_%s.txt", g_udid);

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
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                       dispatch_get_main_queue(), poll_loop);
    };
    /* Prevent block from being deallocated */
    poll_loop = [poll_loop copy];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), poll_loop);

    NSLog(@"[app_installer] Listening: %s, %s + polling every 2s", install_name, launch_name);

    /* Process legacy pending files after delay (backward compat) */
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        process_legacy_pending();
    });
}
