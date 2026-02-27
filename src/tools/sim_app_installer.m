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

__attribute__((constructor))
static void sim_app_installer_init(void) {
    g_udid = getenv("SIMULATOR_UDID");
    if (!g_udid || !g_udid[0]) {
        NSLog(@"[app_installer] SIMULATOR_UDID not set — disabled");
        return;
    }

    snprintf(g_cmd_path, sizeof(g_cmd_path), "/tmp/rosettasim_cmd_%s.json", g_udid);
    snprintf(g_result_path, sizeof(g_result_path), "/tmp/rosettasim_install_result_%s.txt", g_udid);

    NSLog(@"[app_installer] Registering for device %s", g_udid);

    /* Register for install notification */
    char install_name[256];
    snprintf(install_name, sizeof(install_name), "com.rosettasim.install.%s", g_udid);
    int install_token;
    notify_register_dispatch(install_name, &install_token, dispatch_get_main_queue(),
        ^(int token) { handle_install(); });

    /* Register for launch notification */
    char launch_name[256];
    snprintf(launch_name, sizeof(launch_name), "com.rosettasim.launch.%s", g_udid);
    int launch_token;
    notify_register_dispatch(launch_name, &launch_token, dispatch_get_main_queue(),
        ^(int token) { handle_launch(); });

    NSLog(@"[app_installer] Listening: %s, %s", install_name, launch_name);

    /* Process legacy pending files after delay (backward compat) */
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        process_legacy_pending();
    });
}
