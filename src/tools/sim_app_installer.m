/*
 * sim_app_installer.dylib — x86_64 constructor dylib injected into SpringBoard
 *
 * On load, checks /tmp/rosettasim_pending_installs.json for apps to register.
 * Calls MobileInstallationInstallForLaunchServices() for each.
 * Writes result to /tmp/rosettasim_install_result.txt.
 *
 * Build: (x86_64 iOS simulator dylib)
 *   make app_installer
 *
 * Deploy: inject into SpringBoard via insert_dylib or DYLD_INSERT_LIBRARIES
 *   in the device's launchd_bootstrap.plist.
 *
 * Pending installs JSON format:
 *   [{"path": "/path/to/App.app", "bundle_id": "com.example.app"}]
 */

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#include <notify.h>

#define PENDING_FILE  "/tmp/rosettasim_pending_installs.json"
#define RESULT_FILE   "/tmp/rosettasim_install_result.txt"

static void log_result(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);

    /* Print to stderr */
    va_list ap2;
    va_copy(ap2, ap);
    vfprintf(stderr, fmt, ap2);
    fprintf(stderr, "\n");
    va_end(ap2);

    /* Append to result file */
    FILE *f = fopen(RESULT_FILE, "a");
    if (f) {
        vfprintf(f, fmt, ap);
        fprintf(f, "\n");
        fclose(f);
    }
    va_end(ap);
}

static void process_pending_installs(void) {
    NSString *pendingPath = @PENDING_FILE;

    /* Check if pending file exists */
    if (![[NSFileManager defaultManager] fileExistsAtPath:pendingPath]) {
        return; /* Nothing to install — silent return */
    }

    NSData *data = [NSData dataWithContentsOfFile:pendingPath];
    if (!data || data.length == 0) {
        [[NSFileManager defaultManager] removeItemAtPath:pendingPath error:nil];
        return;
    }

    NSError *jsonErr = nil;
    NSArray *pending = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonErr];
    if (![pending isKindOfClass:[NSArray class]] || pending.count == 0) {
        log_result("[installer] Invalid or empty pending installs JSON");
        [[NSFileManager defaultManager] removeItemAtPath:pendingPath error:nil];
        return;
    }

    /* Clear result file */
    [@"" writeToFile:@RESULT_FILE atomically:YES encoding:NSUTF8StringEncoding error:nil];

    log_result("[installer] Processing %lu pending install(s)...", (unsigned long)pending.count);

    /* Load MobileInstallation.framework */
    void *handle = dlopen("/System/Library/PrivateFrameworks/MobileInstallation.framework/MobileInstallation", RTLD_NOW);
    if (!handle) {
        log_result("[installer] ERROR: Failed to load MobileInstallation.framework: %s", dlerror());
        return;
    }

    /* Get install functions — try both variants.
     * Return type may be int (0=success) or id (nil=success, NSError*=failure).
     * We handle both by checking if return value looks like a pointer or zero. */
    typedef long (*MIInstallForLS)(id path, id options, id statusCB, id progressCB);
    typedef long (*MIInstallFn)(id path, id options, void *callback, void *ctx);

    MIInstallForLS installForLS = (MIInstallForLS)dlsym(handle, "MobileInstallationInstallForLaunchServices");
    MIInstallFn installBasic = (MIInstallFn)dlsym(handle, "MobileInstallationInstall");

    if (!installForLS && !installBasic) {
        log_result("[installer] ERROR: No MobileInstallation install function found");
        return;
    }

    log_result("[installer] Available APIs: ForLaunchServices=%s, Install=%s",
               installForLS ? "YES" : "NO", installBasic ? "YES" : "NO");

    int success_count = 0;
    int fail_count = 0;

    for (NSDictionary *entry in pending) {
        NSString *appPath = entry[@"path"];
        NSString *bundleID = entry[@"bundle_id"] ?: @"unknown";

        if (!appPath) {
            log_result("[installer] SKIP: entry missing 'path'");
            fail_count++;
            continue;
        }

        if (![[NSFileManager defaultManager] fileExistsAtPath:appPath]) {
            log_result("[installer] SKIP: app not found at %s", appPath.UTF8String);
            fail_count++;
            continue;
        }

        log_result("[installer] Installing %s from %s...", bundleID.UTF8String, appPath.UTF8String);

        /* Build options with extra fields for LaunchServices registration */
        NSDictionary *options = @{
            @"ApplicationType": @"User",
            @"CFBundleIdentifier": bundleID,
            @"SignerIdentity": @"-",
            @"IsAdHocSigned": @YES,
            @"SkipUninstall": @YES,
        };

        long result = -1;
        BOOL success = NO;

        /* Try MobileInstallationInstallForLaunchServices first */
        if (installForLS) {
            log_result("[installer] Trying MobileInstallationInstallForLaunchServices...");
            result = installForLS(appPath, options, nil, nil);
            log_result("[installer] ForLaunchServices returned: %ld (0x%lx)", result, result);
            /* Return 0 = success. Non-zero could be error code or pointer to error object. */
            if (result == 0) {
                success = YES;
            } else if (result > 0x10000) {
                /* Likely a pointer to NSError */
                @try {
                    id errObj = (__bridge id)(void *)result;
                    if ([errObj isKindOfClass:[NSError class]]) {
                        log_result("[installer] ForLaunchServices error: %s",
                                   ((NSError *)errObj).localizedDescription.UTF8String);
                    } else {
                        log_result("[installer] ForLaunchServices returned object: %s",
                                   [errObj description].UTF8String);
                    }
                } @catch (id e) {
                    log_result("[installer] ForLaunchServices returned non-zero: %ld", result);
                }
            }
        }

        /* If ForLaunchServices failed, try basic MobileInstallationInstall */
        if (!success && installBasic) {
            log_result("[installer] Trying MobileInstallationInstall (basic)...");
            result = installBasic(appPath, options, NULL, NULL);
            log_result("[installer] Install (basic) returned: %ld (0x%lx)", result, result);
            if (result == 0) {
                success = YES;
            } else if (result > 0x10000) {
                @try {
                    id errObj = (__bridge id)(void *)result;
                    if ([errObj isKindOfClass:[NSError class]]) {
                        log_result("[installer] Install error: %s",
                                   ((NSError *)errObj).localizedDescription.UTF8String);
                    } else {
                        log_result("[installer] Install returned object: %s",
                                   [errObj description].UTF8String);
                    }
                } @catch (id e) {
                    log_result("[installer] Install returned non-zero: %ld", result);
                }
            }
        }

        if (success) {
            log_result("[installer] OK: %s installed successfully", bundleID.UTF8String);
            success_count++;
        } else {
            log_result("[installer] FAIL: %s — all install methods failed", bundleID.UTF8String);
            fail_count++;
        }
    }

    log_result("[installer] Done: %d succeeded, %d failed", success_count, fail_count);

    /* Notify SpringBoard that apps changed so it refreshes the home screen */
    if (success_count > 0) {
        log_result("[installer] Posting LaunchServices notifications...");

        /* Post the three key notifications SpringBoard observes */
        notify_post("com.apple.LaunchServices.ApplicationsChanged");
        notify_post("com.apple.LaunchServices.applicationRegistered");

        /* Also try the MobileInstallation-specific notification */
        notify_post("com.apple.mobile.application_installed");

        log_result("[installer] Notifications posted. SpringBoard should refresh.");
    }

    /* Remove pending file after processing */
    [[NSFileManager defaultManager] removeItemAtPath:pendingPath error:nil];
}

/* ================================================================
 * Pending launch — launch an app by bundle ID from inside SpringBoard
 * ================================================================ */

#define LAUNCH_FILE "/tmp/rosettasim_pending_launch.txt"

static void process_pending_launch(void) {
    NSString *launchPath = @LAUNCH_FILE;
    NSString *bundleId = [NSString stringWithContentsOfFile:launchPath
                                                  encoding:NSUTF8StringEncoding error:nil];
    if (!bundleId || bundleId.length == 0) return;

    bundleId = [bundleId stringByTrimmingCharactersInSet:
                [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    log_result("[installer] Launching app: %s", [bundleId UTF8String]);

    BOOL launched = NO;

    /* Approach 1: LSApplicationWorkspace (works on iOS 8-13) */
    Class lsClass = objc_getClass("LSApplicationWorkspace");
    if (lsClass) {
        id workspace = ((id(*)(id, SEL))objc_msgSend)((id)lsClass,
                        sel_registerName("defaultWorkspace"));
        if (workspace) {
            BOOL ok = ((BOOL(*)(id, SEL, id))objc_msgSend)(workspace,
                        sel_registerName("openApplicationWithBundleID:"), bundleId);
            if (ok) {
                log_result("[installer] LSApplicationWorkspace.openApplicationWithBundleID: succeeded");
                launched = YES;
            }
        }
    }

    /* Approach 2: FBSSystemService (iOS 8+) */
    if (!launched) {
        Class fbsClass = objc_getClass("FBSSystemService");
        if (fbsClass) {
            id service = ((id(*)(id, SEL))objc_msgSend)((id)fbsClass,
                          sel_registerName("sharedService"));
            if (service) {
                ((void(*)(id, SEL, id, id, id))objc_msgSend)(service,
                    sel_registerName("openApplication:options:withResult:"),
                    bundleId, nil, nil);
                log_result("[installer] FBSSystemService.openApplication: called");
                launched = YES;
            }
        }
    }

    /* Approach 3: SBUserAgent (iOS 7-9) */
    if (!launched) {
        Class uaClass = objc_getClass("SBUserAgent");
        if (uaClass) {
            id agent = ((id(*)(id, SEL))objc_msgSend)((id)uaClass,
                        sel_registerName("sharedUserAgent"));
            if (agent) {
                ((void(*)(id, SEL, id, id, id))objc_msgSend)(agent,
                    sel_registerName("launchApplicationFromSource:withBundleIdentifier:url:"),
                    nil, bundleId, nil);
                log_result("[installer] SBUserAgent.launchApplication: called");
                launched = YES;
            }
        }
    }

    if (!launched) {
        log_result("[installer] WARNING: No launch method available");
    }

    /* Remove pending launch file */
    [[NSFileManager defaultManager] removeItemAtPath:launchPath error:nil];
}

__attribute__((constructor))
static void sim_app_installer_init(void) {
    /* Delay slightly to let SpringBoard finish its early init.
     * MobileInstallation needs installd to be running. */
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC),
                   dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        @autoreleasepool {
            process_pending_installs();
        }
    });

    /* Delay app launch longer — app needs to be installed first */
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        @autoreleasepool {
            process_pending_launch();
        }
    });
}
