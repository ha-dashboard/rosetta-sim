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
#import <dlfcn.h>

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

    /* Get install function */
    typedef int (*MIInstallForLS)(id path, id options, id statusCB, id progressCB);
    MIInstallForLS installFn = (MIInstallForLS)dlsym(handle, "MobileInstallationInstallForLaunchServices");
    if (!installFn) {
        log_result("[installer] ERROR: MobileInstallationInstallForLaunchServices not found");
        return;
    }

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

        NSDictionary *options = @{
            @"ApplicationType": @"User",
        };

        int result = installFn(appPath, options, nil, nil);

        if (result == 0) {
            log_result("[installer] OK: %s installed successfully", bundleID.UTF8String);
            success_count++;
        } else {
            log_result("[installer] FAIL: %s install returned %d", bundleID.UTF8String, result);
            fail_count++;
        }
    }

    log_result("[installer] Done: %d succeeded, %d failed", success_count, fail_count);

    /* Remove pending file after processing */
    [[NSFileManager defaultManager] removeItemAtPath:pendingPath error:nil];
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
}
