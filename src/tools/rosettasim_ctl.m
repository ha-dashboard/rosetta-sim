/*
 * rosettasim_ctl.m — simctl replacement for legacy iOS simulator devices
 *
 * Usage:
 *   rosettasim-ctl list
 *   rosettasim-ctl boot <UDID>
 *   rosettasim-ctl shutdown <UDID|all>
 *   rosettasim-ctl install <UDID> <app-path>
 *   rosettasim-ctl screenshot <UDID> <output.png>
 *   rosettasim-ctl status <UDID>
 *
 * For legacy runtimes (iOS 7-12.x), implements operations directly.
 * For native runtimes (iOS 15+), delegates to xcrun simctl.
 *
 * Build:
 *   make ctl   (from src/)
 */

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <dlfcn.h>
#include "common/rosettasim_paths.h"
#include <spawn.h>
#include <sys/wait.h>
#include <notify.h>

/* ── Forward declarations ── */
static int run_with_timeout(NSArray<NSString *> *args, int timeout_secs);
static id get_device_set(void);
static id find_device(id deviceSet, NSString *udid);
static NSString *get_runtime_id(id device);
static long get_device_state(id device);
static BOOL is_legacy_runtime(NSString *runtimeID);

/* ── Passthrough: forward any command to real simctl ── */

static int passthrough_to_simctl(int argc, const char *argv[]) {
    NSMutableArray *args = [@[@"xcrun", @"simctl"] mutableCopy];
    for (int i = 1; i < argc; i++)
        [args addObject:[NSString stringWithUTF8String:argv[i]]];
    return run_with_timeout(args, 60);
}

/* ── Resolve "booted" to a UDID ── */

static NSString *resolve_device_arg(const char *arg) {
    if (strcmp(arg, "booted") == 0) {
        /* Find first booted device, preferring legacy */
        id deviceSet = get_device_set();
        if (!deviceSet) return nil;
        NSDictionary *devices = ((id(*)(id, SEL))objc_msgSend)(deviceSet, sel_registerName("devicesByUDID"));
        for (NSUUID *uuid in devices) {
            id dev = devices[uuid];
            if (get_device_state(dev) == 3) {
                return uuid.UUIDString;
            }
        }
        return @"booted"; /* let simctl handle it */
    }
    return [NSString stringWithUTF8String:arg];
}

/* ── Legacy runtime detection ── */

static BOOL is_legacy_runtime(NSString *runtimeID) {
    /* Legacy runtimes that need our direct handling */
    static NSSet *legacyPrefixes = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        legacyPrefixes = [NSSet setWithArray:@[
            @"com.apple.CoreSimulator.SimRuntime.iOS-7",
            @"com.apple.CoreSimulator.SimRuntime.iOS-8",
            @"com.apple.CoreSimulator.SimRuntime.iOS-9",
            @"com.apple.CoreSimulator.SimRuntime.iOS-10",
            @"com.apple.CoreSimulator.SimRuntime.iOS-11",
            @"com.apple.CoreSimulator.SimRuntime.iOS-12",
            @"com.apple.CoreSimulator.SimRuntime.iOS-13",
            @"com.apple.CoreSimulator.SimRuntime.iOS-14"
        ]];
    });
    for (NSString *prefix in legacyPrefixes) {
        if ([runtimeID hasPrefix:prefix]) return YES;
    }
    return NO;
}

/* ── Helper: run a command with timeout ── */

static int run_with_timeout(NSArray<NSString *> *args, int timeout_secs) {
    NSTask *task = [[NSTask alloc] init];
    /* Resolve timeout binary: prefer /opt/homebrew/bin/gtimeout on macOS (coreutils) */
    NSString *timeoutPath = nil;
    for (NSString *candidate in @[@"/opt/homebrew/bin/gtimeout",
                                   @"/usr/local/bin/gtimeout",
                                   @"/usr/bin/timeout",
                                   @"/opt/homebrew/bin/timeout",
                                   @"/usr/local/bin/timeout"]) {
        if ([[NSFileManager defaultManager] isExecutableFileAtPath:candidate]) {
            timeoutPath = candidate;
            break;
        }
    }
    if (!timeoutPath) {
        fprintf(stderr, "Error: neither gtimeout nor timeout found. Install coreutils: brew install coreutils\n");
        return 1;
    }
    task.executableURL = [NSURL fileURLWithPath:timeoutPath];
    NSMutableArray *fullArgs = [NSMutableArray arrayWithObject:
        [NSString stringWithFormat:@"%d", timeout_secs]];
    [fullArgs addObjectsFromArray:args];
    task.arguments = fullArgs;
    task.standardOutput = [NSFileHandle fileHandleWithStandardOutput];
    task.standardError = [NSFileHandle fileHandleWithStandardError];

    NSError *err = nil;
    [task launchAndReturnError:&err];
    if (err) {
        fprintf(stderr, "Failed to launch: %s\n", err.localizedDescription.UTF8String);
        return 1;
    }
    [task waitUntilExit];
    return task.terminationStatus;
}

/* ── Helper: run a command, capture stdout ── */

static NSString *run_capture(NSArray<NSString *> *args, int *exitCode) {
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:args[0]];
    task.arguments = [args subarrayWithRange:NSMakeRange(1, args.count - 1)];
    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = [NSPipe pipe]; /* suppress stderr */

    NSError *err = nil;
    [task launchAndReturnError:&err];
    if (err) {
        if (exitCode) *exitCode = 1;
        return nil;
    }
    NSData *data = [pipe.fileHandleForReading readDataToEndOfFile];
    [task waitUntilExit];
    if (exitCode) *exitCode = task.terminationStatus;
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

/* ── CoreSimulator access ── */

static id get_device_set(void) {
    void *handle = dlopen("/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator", RTLD_LAZY);
    if (!handle) {
        fprintf(stderr, "Failed to load CoreSimulator.framework\n");
        return nil;
    }
    Class SimServiceContext = objc_getClass("SimServiceContext");
    if (!SimServiceContext) {
        fprintf(stderr, "SimServiceContext class not found\n");
        return nil;
    }
    /* [SimServiceContext sharedServiceContextForDeveloperDir:error:] */
    NSError *err = nil;
    id ctx = ((id(*)(id, SEL, id, NSError **))objc_msgSend)(
        (id)SimServiceContext,
        sel_registerName("sharedServiceContextForDeveloperDir:error:"),
        @"/Applications/Xcode.app/Contents/Developer", &err);
    if (!ctx) {
        fprintf(stderr, "Failed to get SimServiceContext: %s\n",
                err.localizedDescription.UTF8String);
        return nil;
    }
    id deviceSet = ((id(*)(id, SEL))objc_msgSend)(ctx, sel_registerName("defaultDeviceSetWithError:"));
    return deviceSet;
}

static id find_device(id deviceSet, NSString *udid) {
    NSDictionary *devices = ((id(*)(id, SEL))objc_msgSend)(deviceSet, sel_registerName("devicesByUDID"));
    NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:udid];
    if (!uuid) return nil;
    return devices[uuid];
}

static NSString *get_runtime_id(id device) {
    id runtime = ((id(*)(id, SEL))objc_msgSend)(device, sel_registerName("runtime"));
    if (!runtime) return nil;
    return ((id(*)(id, SEL))objc_msgSend)(runtime, sel_registerName("identifier"));
}

static NSString *get_device_name(id device) {
    return ((id(*)(id, SEL))objc_msgSend)(device, sel_registerName("name"));
}

static NSString *get_device_data_path(id device) {
    id udidObj = ((id(*)(id, SEL))objc_msgSend)(device, sel_registerName("UDID"));
    NSString *udidStr = udidObj ? [udidObj UUIDString] : nil;
    if (!udidStr) return nil;
    return [NSString stringWithFormat:
        @"%@/Library/Developer/CoreSimulator/Devices/%@/data",
        NSHomeDirectory(), udidStr];
}

static long get_device_state(id device) {
    return ((long(*)(id, SEL))objc_msgSend)(device, sel_registerName("state"));
}

static NSString *state_string(long state) {
    switch (state) {
        case 0: return @"Creating";
        case 1: return @"Shutdown";
        case 2: return @"Booting";
        case 3: return @"Booted";
        case 4: return @"Shutting Down";
        default: return [NSString stringWithFormat:@"Unknown(%ld)", state];
    }
}

/* ── Command: list ── */

/* ── Command: boot ── */

static int cmd_boot(NSString *udid) {
    id deviceSet = get_device_set();
    if (!deviceSet) return 1;
    id device = find_device(deviceSet, udid);
    if (!device) {
        fprintf(stderr, "Device not found: %s\n", udid.UTF8String);
        return 1;
    }

    long state = get_device_state(device);
    if (state == 3) {
        printf("Device already booted.\n");
        return 0;
    }

    NSString *rtID = get_runtime_id(device);
    BOOL legacy = is_legacy_runtime(rtID);

    printf("Booting %s (%s)%s...\n",
           get_device_name(device).UTF8String, udid.UTF8String,
           legacy ? " [legacy]" : "");

    /* Use simctl with timeout for all devices */
    int rc = run_with_timeout(@[@"xcrun", @"simctl", @"boot", udid], legacy ? 45 : 30);
    if (rc == 124) {
        fprintf(stderr, "Boot timed out.\n");
        return 1;
    }
    if (rc != 0) {
        fprintf(stderr, "Boot failed (exit %d).\n", rc);
        return rc;
    }

    /* Verify state */
    state = get_device_state(device);
    printf("Device state: %s\n", state_string(state).UTF8String);
    return (state == 3) ? 0 : 1;
}

/* ── Command: shutdown ── */

static int cmd_shutdown(NSString *target) {
    if ([target isEqualToString:@"all"]) {
        int rc = run_with_timeout(@[@"xcrun", @"simctl", @"shutdown", @"all"], 30);
        if (rc == 124) {
            /* Timeout — kill remaining launchd_sim processes */
            fprintf(stderr, "Shutdown timed out. Killing remaining launchd_sim processes...\n");
            system("pkill -f 'launchd_sim.*CoreSimulator/Devices/'");
            sleep(2);
        }
        printf("All devices shut down.\n");
        return 0;
    }

    id deviceSet = get_device_set();
    if (!deviceSet) return 1;
    id device = find_device(deviceSet, target);
    if (!device) {
        fprintf(stderr, "Device not found: %s\n", target.UTF8String);
        return 1;
    }

    long state = get_device_state(device);
    if (state == 1) {
        printf("Device already shut down.\n");
        return 0;
    }

    NSString *rtID = get_runtime_id(device);
    BOOL legacy = is_legacy_runtime(rtID);

    printf("Shutting down %s%s...\n",
           get_device_name(device).UTF8String,
           legacy ? " [legacy]" : "");

    int rc = run_with_timeout(@[@"xcrun", @"simctl", @"shutdown", target], legacy ? 20 : 15);
    if (rc == 124 && legacy) {
        /* Fallback: find and kill launchd_sim for this device */
        fprintf(stderr, "Shutdown timed out. Killing launchd_sim...\n");
        NSString *cmd = [NSString stringWithFormat:
            @"pgrep -f 'launchd_sim.*%@' | xargs kill 2>/dev/null", target];
        system(cmd.UTF8String);
        sleep(2);
    }

    state = get_device_state(device);
    printf("Device state: %s\n", state_string(state).UTF8String);
    return 0;
}

/* ── Command: install ── */

static int cmd_install(NSString *udid, NSString *appPath) {
    id deviceSet = get_device_set();
    if (!deviceSet) return 1;
    id device = find_device(deviceSet, udid);
    if (!device) {
        fprintf(stderr, "Device not found: %s\n", udid.UTF8String);
        return 1;
    }

    long state = get_device_state(device);
    if (state != 3) {
        fprintf(stderr, "Device is not booted (state: %s)\n", state_string(state).UTF8String);
        return 1;
    }

    /* Validate app path */
    BOOL isDir = NO;
    if (![[NSFileManager defaultManager] fileExistsAtPath:appPath isDirectory:&isDir] || !isDir) {
        fprintf(stderr, "App not found or not a directory: %s\n", appPath.UTF8String);
        return 1;
    }

    /* Read bundle identifier */
    NSString *infoPlistPath = [appPath stringByAppendingPathComponent:@"Info.plist"];
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:infoPlistPath];
    NSString *bundleID = info[@"CFBundleIdentifier"];
    if (!bundleID) {
        fprintf(stderr, "Cannot read CFBundleIdentifier from %s\n", infoPlistPath.UTF8String);
        return 1;
    }

    NSString *rtID = get_runtime_id(device);
    BOOL legacy = is_legacy_runtime(rtID);

    if (!legacy) {
        /* Native device — delegate to simctl */
        printf("Installing %s on %s (native)...\n", bundleID.UTF8String,
               get_device_name(device).UTF8String);
        return run_with_timeout(@[@"xcrun", @"simctl", @"install", udid, appPath], 60);
    }

    /* Legacy device — direct file copy */
    printf("Installing %s on %s [legacy]...\n", bundleID.UTF8String,
           get_device_name(device).UTF8String);

    NSString *deviceDataPath = [NSString stringWithFormat:
        @"%@/Library/Developer/CoreSimulator/Devices/%@/data",
        NSHomeDirectory(), udid];

    /* Create container */
    NSString *containerUUID = [NSUUID UUID].UUIDString;
    NSString *containerDir = [NSString stringWithFormat:
        @"%@/Containers/Bundle/Application/%@", deviceDataPath, containerUUID];

    NSError *err = nil;
    [[NSFileManager defaultManager] createDirectoryAtPath:containerDir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:&err];
    if (err) {
        fprintf(stderr, "Failed to create container: %s\n", err.localizedDescription.UTF8String);
        return 1;
    }

    /* Copy .app into container */
    NSString *appName = [appPath lastPathComponent];
    NSString *destApp = [containerDir stringByAppendingPathComponent:appName];

    /* Remove existing if present */
    [[NSFileManager defaultManager] removeItemAtPath:destApp error:nil];

    if (![[NSFileManager defaultManager] copyItemAtPath:appPath toPath:destApp error:&err]) {
        fprintf(stderr, "Failed to copy app: %s\n", err.localizedDescription.UTF8String);
        return 1;
    }

    printf("  Copied to %s\n", containerDir.UTF8String);

    /* Create .com.apple.mobile_container_manager.metadata.plist */
    NSDictionary *metadata = @{
        @"MCMMetadataIdentifier": bundleID,
        @"MCMMetadataUUID": containerUUID,
    };
    NSString *metadataPath = [containerDir stringByAppendingPathComponent:
        @".com.apple.mobile_container_manager.metadata.plist"];
    [metadata writeToFile:metadataPath atomically:YES];

    /* Write installed apps plist for persistence across reboots.
     * registerApplicationDictionary: only updates lsd's in-memory state;
     * on fresh devices the registration is lost on reboot without this.
     * Use custom path — MobileInstallation/ is wiped by CoreSimulator on boot. */
    NSString *lsMapPath = [NSString stringWithFormat:
        @"%@/" ROSETTASIM_DEV_INSTALLED_APPS,
        deviceDataPath];
    NSString *lsMapDir = [lsMapPath stringByDeletingLastPathComponent];
    [[NSFileManager defaultManager] createDirectoryAtPath:lsMapDir
                              withIntermediateDirectories:YES attributes:nil error:nil];

    NSMutableDictionary *lsMap = [NSMutableDictionary dictionaryWithContentsOfFile:lsMapPath]
        ?: [NSMutableDictionary new];
    if (!lsMap[@"User"]) lsMap[@"User"] = [NSMutableDictionary new];
    NSMutableDictionary *userApps = [lsMap[@"User"] mutableCopy];

    userApps[bundleID] = @{
        @"CFBundleIdentifier": bundleID,
        @"Path": destApp,
        @"ApplicationType": @"User",
        @"Container": containerDir,
        @"SignerIdentity": @"Simulator",
        @"IsContainerized": @YES,
    };
    lsMap[@"User"] = userApps;
    [lsMap writeToFile:lsMapPath atomically:YES];
    printf("  Updated LaunchServicesMap for persistence.\n");

    /* For iOS 10+ (CSStore2): also symlink app into runtime's /Applications/ directory.
     * CSStore2 rebuilds the LS database from /Applications/ on every boot.
     * registerApplicationDictionary: only updates in-memory state, not the database.
     * A symlink from /Applications/<AppName>.app → container path makes CSStore2 find it. */
    NSString *runtimeRoot = nil;
    @try {
        id runtime = ((id(*)(id, SEL))objc_msgSend)(device, sel_registerName("runtime"));
        if (runtime) {
            NSURL *rootURL = ((id(*)(id, SEL))objc_msgSend)(runtime, sel_registerName("root"));
            if (rootURL) runtimeRoot = [rootURL path];
        }
    } @catch (id e) { }
    /* Fallback: construct from runtime ID (e.g., com.apple.CoreSimulator.SimRuntime.iOS-10-3) */
    if (!runtimeRoot) {
        NSString *base = [NSString stringWithFormat:@"%@/Library/Developer/CoreSimulator/Profiles/Runtimes",
                          NSHomeDirectory()];
        for (NSString *entry in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:base error:nil]) {
            if ([entry containsString:@"iOS_10"] || [entry containsString:@"iOS_9"]) {
                NSString *candidate = [NSString stringWithFormat:@"%@/%@/Contents/Resources/RuntimeRoot", base, entry];
                if ([[NSFileManager defaultManager] fileExistsAtPath:candidate]) {
                    /* Match runtime to device by checking runtime ID */
                    if ((rtID && [rtID containsString:@"10"] && [entry containsString:@"10"]) ||
                        (rtID && [rtID containsString:@"9"] && [entry containsString:@"9"])) {
                        runtimeRoot = candidate;
                        break;
                    }
                }
            }
        }
    }
    if (runtimeRoot) {
        NSString *appsDir = [runtimeRoot stringByAppendingPathComponent:@"Applications"];
        NSString *linkPath = [appsDir stringByAppendingPathComponent:appName];
        /* Remove existing app/symlink */
        [[NSFileManager defaultManager] removeItemAtPath:linkPath error:nil];
        /* Copy app directly (CSStore2 may not follow symlinks) */
        NSError *copyErr = nil;
        if ([[NSFileManager defaultManager] copyItemAtPath:destApp toPath:linkPath error:&copyErr]) {
            printf("  Copied into /Applications/ for CSStore2 persistence.\n");
        } else {
            fprintf(stderr, "  Warning: copy to /Applications/ failed: %s\n",
                    copyErr.localizedDescription.UTF8String);
        }
    }

    /* Notify sim_app_installer.dylib inside SpringBoard via darwin notification.
     * Write command file, then post device-specific notification. */
    printf("  Triggering install via sim_app_installer...\n");

    NSString *cmdPath = [NSString stringWithFormat:@ROSETTASIM_HOST_CMD_NSFMT, udid];
    NSArray *installEntry = @[@{@"path": destApp, @"bundle_id": bundleID}];
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:installEntry
                                                       options:NSJSONWritingPrettyPrinted error:nil];
    [jsonData writeToFile:cmdPath atomically:YES];

    /* Post device-specific notification */
    char notifyName[256];
    snprintf(notifyName, sizeof(notifyName), "com.rosettasim.install.%s", udid.UTF8String);
    notify_post(notifyName);

    printf("  Notification sent: %s\n", notifyName);

    /* Wait briefly for result */
    usleep(2000000); /* 2 seconds */

    NSString *resultPath = [NSString stringWithFormat:@ROSETTASIM_HOST_RESULT_NSFMT, udid];
    NSString *resultStr = [NSString stringWithContentsOfFile:resultPath
                                                   encoding:NSUTF8StringEncoding error:nil];
    if (resultStr && [resultStr containsString:@"SUCCESS"]) {
        printf("Installed %s (%s) — registered with MobileInstallation\n",
               bundleID.UTF8String, appName.UTF8String);
    } else if (resultStr) {
        printf("Install result: %s\n", resultStr.UTF8String);
    } else {
        printf("Installed %s (%s) — pending registration.\n",
               bundleID.UTF8String, appName.UTF8String);
        printf("  If sim_app_installer.dylib is not loaded, reboot the device.\n");
    }
    return 0;
}

/* ── Command: launch ── */

static int cmd_launch(NSString *udid, NSString *bundleID) {
    id deviceSet = get_device_set();
    if (!deviceSet) return 1;
    id device = find_device(deviceSet, udid);
    if (!device) {
        fprintf(stderr, "Device not found: %s\n", udid.UTF8String);
        return 1;
    }

    long state = get_device_state(device);
    if (state != 3) {
        fprintf(stderr, "Device is not booted (state: %s)\n", state_string(state).UTF8String);
        return 1;
    }

    NSString *rtID = get_runtime_id(device);
    BOOL legacy = is_legacy_runtime(rtID);

    if (!legacy) {
        /* Native — delegate to simctl */
        printf("Launching %s on %s (native)...\n", bundleID.UTF8String,
               get_device_name(device).UTF8String);
        return run_with_timeout(@[@"xcrun", @"simctl", @"launch", udid, bundleID], 30);
    }

    /* Legacy — find .app and launch via simctl spawn or open URL */
    printf("Launching %s on %s [legacy]...\n", bundleID.UTF8String,
           get_device_name(device).UTF8String);

    NSString *deviceDataPath = [NSString stringWithFormat:
        @"%@/Library/Developer/CoreSimulator/Devices/%@/data",
        NSHomeDirectory(), udid];

    /* Search for the app in Containers/Bundle/Application/ */
    NSString *containersPath = [deviceDataPath stringByAppendingPathComponent:
        @"Containers/Bundle/Application"];
    NSString *appPath = nil;
    NSFileManager *fm = [NSFileManager defaultManager];

    NSArray *containerUUIDs = [fm contentsOfDirectoryAtPath:containersPath error:nil];
    for (NSString *cuuid in containerUUIDs) {
        NSString *containerDir = [containersPath stringByAppendingPathComponent:cuuid];
        NSArray *contents = [fm contentsOfDirectoryAtPath:containerDir error:nil];
        for (NSString *item in contents) {
            if (![item hasSuffix:@".app"]) continue;
            NSString *candidate = [containerDir stringByAppendingPathComponent:item];
            NSString *infoPlist = [candidate stringByAppendingPathComponent:@"Info.plist"];
            NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:infoPlist];
            if ([info[@"CFBundleIdentifier"] isEqualToString:bundleID]) {
                appPath = candidate;
                break;
            }
        }
        if (appPath) break;
    }

    if (!appPath) {
        fprintf(stderr, "App %s not found in device containers.\n", bundleID.UTF8String);
        fprintf(stderr, "Install it first: rosettasim-ctl install %s <path.app>\n", udid.UTF8String);
        return 1;
    }

    /* Get executable name from Info.plist */
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:
        [appPath stringByAppendingPathComponent:@"Info.plist"]];
    NSString *execName = info[@"CFBundleExecutable"];
    if (!execName) {
        fprintf(stderr, "No CFBundleExecutable in app Info.plist\n");
        return 1;
    }

    (void)execName; /* app path confirmed valid */

    /* Notify sim_app_installer.dylib to launch the app via darwin notification */
    printf("  App found at: %s\n", appPath.UTF8String);

    NSString *cmdPath = [NSString stringWithFormat:
        @ROSETTASIM_HOST_CMD_NSFMT, udid];
    NSDictionary *launchCmd = @{@"bundle_id": bundleID};
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:launchCmd options:0 error:nil];
    [jsonData writeToFile:cmdPath atomically:YES];

    char notifyName[256];
    snprintf(notifyName, sizeof(notifyName), "com.rosettasim.launch.%s", udid.UTF8String);
    notify_post(notifyName);

    printf("  Launch notification sent: %s\n", notifyName);

    /* Wait briefly for result */
    usleep(2000000); /* 2 seconds */

    NSString *resultPath = [NSString stringWithFormat:@ROSETTASIM_HOST_RESULT_NSFMT, udid];
    NSString *resultStr = [NSString stringWithContentsOfFile:resultPath
                                                   encoding:NSUTF8StringEncoding error:nil];
    if (resultStr && [resultStr containsString:@"SUCCESS"]) {
        printf("Launched %s\n", bundleID.UTF8String);
    } else if (resultStr) {
        printf("Launch result: %s\n", resultStr.UTF8String);
    } else {
        printf("Launch requested for %s.\n", bundleID.UTF8String);
        printf("  If sim_app_installer.dylib is not loaded, reboot the device.\n");
    }

    return 0;
}

/* ── Command: screenshot ── */

static int cmd_screenshot(NSString *udid, NSString *outputPath) {
    id deviceSet = get_device_set();
    if (!deviceSet) return 1;
    id device = find_device(deviceSet, udid);
    if (!device) {
        fprintf(stderr, "Device not found: %s\n", udid.UTF8String);
        return 1;
    }

    NSString *rtID = get_runtime_id(device);
    BOOL legacy = is_legacy_runtime(rtID);

    if (!legacy) {
        /* Native — delegate to simctl */
        return run_with_timeout(@[@"xcrun", @"simctl", @"io", udid,
            @"screenshot", outputPath], 15);
    }

    /* Legacy — read active_devices.json for surface_id, then call fb_to_png */
    NSData *data = [NSData dataWithContentsOfFile:@"/tmp/rosettasim_active_devices.json"];
    if (!data) {
        fprintf(stderr, "Daemon not running or no active devices.\n");
        return 1;
    }

    NSArray *devices = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![devices isKindOfClass:[NSArray class]]) {
        fprintf(stderr, "Invalid active_devices.json format.\n");
        return 1;
    }

    /* Find device by UDID */
    NSDictionary *found = nil;
    for (NSDictionary *d in devices) {
        if ([d[@"udid"] isEqualToString:udid]) {
            found = d;
            break;
        }
    }

    if (!found) {
        fprintf(stderr, "Device %s not found in daemon's active device list.\n", udid.UTF8String);
        fprintf(stderr, "Is the device booted and managed by rosettasim_daemon?\n");
        return 1;
    }

    NSNumber *surfaceID = found[@"surface_id"];
    if (surfaceID && surfaceID.unsignedIntValue > 0) {
        /* IOSurface path — use fb_to_png */
        NSString *fbToPng = [[[NSProcessInfo processInfo].arguments[0]
            stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"fb_to_png"];

        /* Also try relative to our binary location */
        if (![[NSFileManager defaultManager] fileExistsAtPath:fbToPng]) {
            fbToPng = @"fb_to_png"; /* hope it's in PATH */
        }

        NSArray *args = @[fbToPng,
            [NSString stringWithFormat:@"%u", surfaceID.unsignedIntValue],
            outputPath];
        int ec = 0;
        run_capture(args, &ec);
        if (ec == 0) {
            printf("Screenshot saved to %s\n", outputPath.UTF8String);
        } else {
            fprintf(stderr, "fb_to_png failed (exit %d)\n", ec);
        }
        return ec;
    }

    /* Raw file fallback */
    NSString *fbPath = found[@"fb"];
    NSNumber *width = found[@"width"];
    NSNumber *height = found[@"height"];
    if (fbPath && width && height) {
        uint32_t bpr = width.unsignedIntValue * 4;
        NSString *fbToPng = @"fb_to_png";
        NSArray *args = @[fbToPng, @"--raw", fbPath,
            [NSString stringWithFormat:@"%u", width.unsignedIntValue],
            [NSString stringWithFormat:@"%u", height.unsignedIntValue],
            [NSString stringWithFormat:@"%u", bpr],
            outputPath];
        int ec = 0;
        run_capture(args, &ec);
        if (ec == 0) printf("Screenshot saved to %s\n", outputPath.UTF8String);
        return ec;
    }

    fprintf(stderr, "No surface_id or framebuffer path available for this device.\n");
    return 1;
}

/* ── Command: status ── */

static int cmd_status(NSString *udid) {
    id deviceSet = get_device_set();
    if (!deviceSet) return 1;
    id device = find_device(deviceSet, udid);
    if (!device) {
        fprintf(stderr, "Device not found: %s\n", udid.UTF8String);
        return 1;
    }

    NSString *name = get_device_name(device);
    NSString *rtID = get_runtime_id(device);
    long state = get_device_state(device);
    BOOL legacy = is_legacy_runtime(rtID);

    printf("Device:  %s\n", name.UTF8String);
    printf("UDID:    %s\n", udid.UTF8String);
    printf("Runtime: %s%s\n", rtID.UTF8String, legacy ? " [legacy]" : "");
    printf("State:   %s\n", state_string(state).UTF8String);

    if (state != 3) return 0;

    /* Check daemon status */
    NSData *data = [NSData dataWithContentsOfFile:@"/tmp/rosettasim_active_devices.json"];
    if (data) {
        NSArray *devices = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        for (NSDictionary *d in devices) {
            if ([d[@"udid"] isEqualToString:udid]) {
                printf("\nDaemon:\n");
                printf("  Display:    %ux%u @%.0fx\n",
                       [d[@"width"] unsignedIntValue],
                       [d[@"height"] unsignedIntValue],
                       [d[@"scale"] floatValue]);
                if (d[@"surface_id"])
                    printf("  Surface ID: %u\n", [d[@"surface_id"] unsignedIntValue]);
                if (d[@"fb"])
                    printf("  FB file:    %s\n", [d[@"fb"] UTF8String]);
                break;
            }
        }
    }

    /* Check IO ports */
    if (legacy) {
        printf("\nIO Ports:\n");
        int ec = 0;
        NSString *output = run_capture(@[@"/usr/bin/xcrun", @"simctl", @"io", udid, @"enumerate"], &ec);
        if (ec == 0 && output) {
            /* Extract port summary */
            for (NSString *line in [output componentsSeparatedByString:@"\n"]) {
                NSString *trimmed = [line stringByTrimmingCharactersInSet:
                    [NSCharacterSet whitespaceCharacterSet]];
                if ([trimmed hasPrefix:@"Class:"] ||
                    [trimmed hasPrefix:@"Port Identifier:"] ||
                    [trimmed hasPrefix:@"Power state:"] ||
                    [trimmed hasPrefix:@"Default width:"] ||
                    [trimmed hasPrefix:@"Default height:"]) {
                    printf("  %s\n", trimmed.UTF8String);
                }
            }
        }
    }

    /* Check key processes */
    printf("\nProcesses:\n");
    NSString *psCmd = [NSString stringWithFormat:
        @"ps aux | grep '%@' | grep -v grep | awk '{print $11}' | "
        @"xargs -I{} basename {} | sort -u", udid];
    int ec = 0;
    NSString *output = run_capture(@[@"/bin/sh", @"-c", psCmd], &ec);
    if (output.length > 0) {
        for (NSString *proc in [output componentsSeparatedByString:@"\n"]) {
            if (proc.length > 0) printf("  %s\n", proc.UTF8String);
        }
    }

    return 0;
}

/* ── Helper: read LastLaunchServicesMap.plist for a device ── */

static NSDictionary *read_ls_map(NSString *udid) {
    NSString *path = [NSString stringWithFormat:
        @"%@/Library/Developer/CoreSimulator/Devices/%@/data/Library/MobileInstallation/LastLaunchServicesMap.plist",
        NSHomeDirectory(), udid];
    return [NSDictionary dictionaryWithContentsOfFile:path];
}

/* ── Command: listapps ── */

static int cmd_listapps(NSString *udid) {
    id deviceSet = get_device_set();
    if (!deviceSet) return 1;
    id device = find_device(deviceSet, udid);
    if (!device) {
        fprintf(stderr, "Device not found: %s\n", udid.UTF8String);
        return 1;
    }

    NSString *rtID = get_runtime_id(device);
    BOOL legacy = is_legacy_runtime(rtID);

    if (!legacy) {
        return run_with_timeout(@[@"xcrun", @"simctl", @"listapps", udid], 15);
    }

    /* Legacy: read from LastLaunchServicesMap.plist, fall back to rosettasim plist */
    NSDictionary *lsMap = read_ls_map(udid);
    if (!lsMap) {
        /* Fallback: read rosettasim_installed_apps.plist (used on iOS 10.3 where
         * LastLaunchServicesMap doesn't persist our registrations) */
        NSString *fallbackPath = [NSString stringWithFormat:
            @"%@/Library/Developer/CoreSimulator/Devices/%@/data/" ROSETTASIM_DEV_INSTALLED_APPS,
            NSHomeDirectory(), udid];
        lsMap = [NSDictionary dictionaryWithContentsOfFile:fallbackPath];
    }
    if (!lsMap) {
        fprintf(stderr, "No LaunchServicesMap found. Device may not have booted yet.\n");
        return 1;
    }

    for (NSString *section in @[@"User", @"System", @"Internal"]) {
        NSDictionary *apps = lsMap[section];
        if (![apps isKindOfClass:[NSDictionary class]] || apps.count == 0) continue;
        printf("-- %s (%lu) --\n", section.UTF8String, (unsigned long)apps.count);
        for (NSString *bid in [apps.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
            NSDictionary *info = apps[bid];
            NSString *path = info[@"Path"] ?: @"<no path>";
            printf("  %s\n    %s\n", bid.UTF8String, path.UTF8String);
        }
    }
    return 0;
}

/* ── Command: get_app_container ── */

static int cmd_get_app_container(NSString *udid, NSString *bundleID, NSString *containerType) {
    id deviceSet = get_device_set();
    if (!deviceSet) return 1;
    id device = find_device(deviceSet, udid);
    if (!device) {
        fprintf(stderr, "Device not found: %s\n", udid.UTF8String);
        return 1;
    }

    NSString *rtID = get_runtime_id(device);
    BOOL legacy = is_legacy_runtime(rtID);

    if (!legacy) {
        NSMutableArray *args = [@[@"xcrun", @"simctl", @"get_app_container", udid, bundleID] mutableCopy];
        if (containerType) [args addObject:containerType];
        return run_with_timeout(args, 15);
    }

    /* Legacy: read from LaunchServicesMap */
    NSDictionary *lsMap = read_ls_map(udid);
    if (!lsMap) {
        fprintf(stderr, "No LaunchServicesMap found.\n");
        return 1;
    }

    /* Search all sections */
    for (NSString *section in @[@"User", @"System", @"Internal", @"CoreServices"]) {
        NSDictionary *apps = lsMap[section];
        NSDictionary *appInfo = apps[bundleID];
        if (!appInfo) continue;

        if ([containerType isEqualToString:@"data"]) {
            NSString *container = appInfo[@"Container"];
            if (container) { printf("%s\n", container.UTF8String); return 0; }
        } else {
            /* app container (default) = Path without the .app component */
            NSString *path = appInfo[@"Path"];
            if (path) {
                if ([containerType isEqualToString:@"app"] || !containerType) {
                    printf("%s\n", path.UTF8String);
                } else {
                    printf("%s\n", [path stringByDeletingLastPathComponent].UTF8String);
                }
                return 0;
            }
        }
    }

    /* Fallback: search Containers/Bundle/Application */
    NSString *containersPath = [NSString stringWithFormat:
        @"%@/Library/Developer/CoreSimulator/Devices/%@/data/Containers/Bundle/Application",
        NSHomeDirectory(), udid];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *cuuid in [fm contentsOfDirectoryAtPath:containersPath error:nil]) {
        NSString *containerDir = [containersPath stringByAppendingPathComponent:cuuid];
        for (NSString *item in [fm contentsOfDirectoryAtPath:containerDir error:nil]) {
            if (![item hasSuffix:@".app"]) continue;
            NSString *infoPlist = [[containerDir stringByAppendingPathComponent:item]
                                    stringByAppendingPathComponent:@"Info.plist"];
            NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:infoPlist];
            if ([info[@"CFBundleIdentifier"] isEqualToString:bundleID]) {
                if ([containerType isEqualToString:@"data"]) {
                    /* Look for matching data container */
                    NSString *dataPath = [NSString stringWithFormat:
                        @"%@/Library/Developer/CoreSimulator/Devices/%@/data/Containers/Data/Application",
                        NSHomeDirectory(), udid];
                    /* Can't reliably map bundle→data without the LS map; print what we have */
                    printf("%s\n", dataPath.UTF8String);
                } else {
                    printf("%s\n", [containerDir stringByAppendingPathComponent:item].UTF8String);
                }
                return 0;
            }
        }
    }

    fprintf(stderr, "App %s not found.\n", bundleID.UTF8String);
    return 1;
}

/* ── Command: uninstall ── */

static int cmd_uninstall(NSString *udid, NSString *bundleID) {
    id deviceSet = get_device_set();
    if (!deviceSet) return 1;
    id device = find_device(deviceSet, udid);
    if (!device) {
        fprintf(stderr, "Device not found: %s\n", udid.UTF8String);
        return 1;
    }

    NSString *rtID = get_runtime_id(device);
    BOOL legacy = is_legacy_runtime(rtID);

    if (!legacy) {
        return run_with_timeout(@[@"xcrun", @"simctl", @"uninstall", udid, bundleID], 30);
    }

    /* Legacy: remove app container directory */
    printf("Uninstalling %s [legacy]...\n", bundleID.UTF8String);

    NSString *containersPath = [NSString stringWithFormat:
        @"%@/Library/Developer/CoreSimulator/Devices/%@/data/Containers/Bundle/Application",
        NSHomeDirectory(), udid];
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL found = NO;

    for (NSString *cuuid in [fm contentsOfDirectoryAtPath:containersPath error:nil]) {
        NSString *containerDir = [containersPath stringByAppendingPathComponent:cuuid];
        for (NSString *item in [fm contentsOfDirectoryAtPath:containerDir error:nil]) {
            if (![item hasSuffix:@".app"]) continue;
            NSString *infoPlist = [[containerDir stringByAppendingPathComponent:item]
                                    stringByAppendingPathComponent:@"Info.plist"];
            NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:infoPlist];
            if ([info[@"CFBundleIdentifier"] isEqualToString:bundleID]) {
                NSError *err = nil;
                [fm removeItemAtPath:containerDir error:&err];
                if (err) {
                    fprintf(stderr, "Failed to remove container: %s\n", err.localizedDescription.UTF8String);
                    return 1;
                }
                printf("  Removed bundle container: %s\n", containerDir.UTF8String);
                found = YES;
                break;
            }
        }
        if (found) break;
    }

    if (!found) {
        fprintf(stderr, "App %s not found in containers.\n", bundleID.UTF8String);
        return 1;
    }

    printf("Uninstalled %s. Reboot device to update home screen.\n", bundleID.UTF8String);
    return 0;
}

/* ── Command: terminate ── */

static int cmd_terminate(NSString *udid, NSString *bundleID) {
    id deviceSet = get_device_set();
    if (!deviceSet) return 1;
    id device = find_device(deviceSet, udid);
    if (!device) {
        fprintf(stderr, "Device not found: %s\n", udid.UTF8String);
        return 1;
    }

    NSString *rtID = get_runtime_id(device);
    BOOL legacy = is_legacy_runtime(rtID);

    if (!legacy) {
        return run_with_timeout(@[@"xcrun", @"simctl", @"terminate", udid, bundleID], 15);
    }

    long state = get_device_state(device);
    if (state != 3) {
        fprintf(stderr, "Device is not booted (state: %s)\n", state_string(state).UTF8String);
        return 1;
    }

    /* Legacy: find the app's CFBundleExecutable, then pgrep inside the device's process tree */
    NSString *execName = nil;

    /* Search containers for the app's Info.plist */
    NSString *containersPath = [NSString stringWithFormat:
        @"%@/Library/Developer/CoreSimulator/Devices/%@/data/Containers/Bundle/Application",
        NSHomeDirectory(), udid];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *cuuid in [fm contentsOfDirectoryAtPath:containersPath error:nil]) {
        NSString *containerDir = [containersPath stringByAppendingPathComponent:cuuid];
        for (NSString *item in [fm contentsOfDirectoryAtPath:containerDir error:nil]) {
            if (![item hasSuffix:@".app"]) continue;
            NSString *infoPlist = [[containerDir stringByAppendingPathComponent:item]
                                    stringByAppendingPathComponent:@"Info.plist"];
            NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:infoPlist];
            if ([info[@"CFBundleIdentifier"] isEqualToString:bundleID]) {
                execName = info[@"CFBundleExecutable"];
                break;
            }
        }
        if (execName) break;
    }

    /* Also check LaunchServicesMap */
    if (!execName) {
        NSDictionary *lsMap = read_ls_map(udid);
        for (NSString *section in @[@"User", @"System", @"Internal"]) {
            NSDictionary *appInfo = lsMap[section][bundleID];
            if (appInfo[@"Path"]) {
                NSString *appInfoPlist = [appInfo[@"Path"] stringByAppendingPathComponent:@"Info.plist"];
                NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:appInfoPlist];
                execName = info[@"CFBundleExecutable"];
                if (execName) break;
            }
        }
    }

    if (!execName) {
        fprintf(stderr, "Cannot find CFBundleExecutable for %s\n", bundleID.UTF8String);
        return 1;
    }

    /* Find the launchd_sim PID for this device, then find the app process in its tree */
    NSString *pgrepCmd = [NSString stringWithFormat:
        @"pgrep -f 'launchd_sim.*%@'", udid];
    int ec = 0;
    NSString *launchdPid = run_capture(@[@"/bin/sh", @"-c", pgrepCmd], &ec);
    launchdPid = [launchdPid stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

    if (ec != 0 || launchdPid.length == 0) {
        fprintf(stderr, "Cannot find launchd_sim for device %s\n", udid.UTF8String);
        return 1;
    }

    /* Find app process: child of this launchd_sim with matching exec name */
    NSString *findCmd = [NSString stringWithFormat:
        @"ps -o pid,ppid,comm -ax | awk '$2 == %@ && $3 ~ /%@$/ {print $1}'",
        launchdPid, execName];
    NSString *appPid = run_capture(@[@"/bin/sh", @"-c", findCmd], &ec);
    appPid = [appPid stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

    if (appPid.length == 0) {
        /* Try broader match: any process with this exec name under launchd_sim's session */
        findCmd = [NSString stringWithFormat:
            @"pgrep -P %@ %@", launchdPid, execName];
        appPid = run_capture(@[@"/bin/sh", @"-c", findCmd], &ec);
        appPid = [appPid stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    }

    if (appPid.length == 0) {
        fprintf(stderr, "App %s (%s) is not running on device %s\n",
                bundleID.UTF8String, execName.UTF8String, udid.UTF8String);
        return 1;
    }

    /* Kill by exact PID */
    pid_t pid = (pid_t)appPid.intValue;
    printf("Terminating %s (pid %d)...\n", bundleID.UTF8String, pid);
    if (kill(pid, SIGTERM) != 0) {
        fprintf(stderr, "kill(%d) failed: %s\n", pid, strerror(errno));
        return 1;
    }

    /* Wait briefly, then SIGKILL if still alive */
    usleep(500000);
    if (kill(pid, 0) == 0) {
        kill(pid, SIGKILL);
    }

    printf("Terminated %s\n", bundleID.UTF8String);
    return 0;
}

/* ── Command: openurl ── */

static int cmd_openurl(NSString *udid, NSString *url) {
    id deviceSet = get_device_set();
    if (!deviceSet) return 1;
    id device = find_device(deviceSet, udid);
    if (!device) {
        fprintf(stderr, "Device not found: %s\n", udid.UTF8String);
        return 1;
    }

    NSString *rtID = get_runtime_id(device);
    BOOL legacy = is_legacy_runtime(rtID);

    if (!legacy) {
        return run_with_timeout(@[@"xcrun", @"simctl", @"openurl", udid, url], 15);
    }

    long state = get_device_state(device);
    if (state != 3) {
        fprintf(stderr, "Device is not booted (state: %s)\n", state_string(state).UTF8String);
        return 1;
    }

    /* Legacy: write openurl command file and notify sim_app_installer.dylib */
    printf("Opening URL on %s [legacy]: %s\n", get_device_name(device).UTF8String, url.UTF8String);

    NSString *cmdPath = [NSString stringWithFormat:
        @ROSETTASIM_HOST_CMD_NSFMT, udid];
    NSDictionary *cmd = @{@"action": @"openurl", @"url": url};
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:cmd options:0 error:nil];
    [jsonData writeToFile:cmdPath atomically:YES];

    /* Notify the installer dylib */
    char notifyName[256];
    snprintf(notifyName, sizeof(notifyName), "com.rosettasim.openurl.%s", udid.UTF8String);
    notify_post(notifyName);

    printf("  Notification sent: %s\n", notifyName);
    printf("  Note: openurl requires sim_app_installer.dylib with openurl handler.\n");
    printf("  If not supported yet, open Safari and navigate manually.\n");
    return 0;
}

/* ── Command: erase ── */

static int cmd_erase(NSString *udid) {
    /* erase works through CoreSimulatorService, should work for all devices */
    printf("Erasing device %s...\n", udid.UTF8String);
    return run_with_timeout(@[@"xcrun", @"simctl", @"erase", udid], 30);
}

/* ── Command: spawn ── */

static int cmd_spawn(NSString *udid, NSArray<NSString *> *spawnArgs) {
    id deviceSet = get_device_set();
    if (!deviceSet) return 1;
    id device = find_device(deviceSet, udid);
    if (!device) {
        fprintf(stderr, "Device not found: %s\n", udid.UTF8String);
        return 1;
    }

    long state = get_device_state(device);
    if (state != 3) {
        fprintf(stderr, "Device is not booted (state: %s)\n", state_string(state).UTF8String);
        return 1;
    }

    NSString *rtID = get_runtime_id(device);
    BOOL legacy = is_legacy_runtime(rtID);

    if (!legacy) {
        NSMutableArray *args = [@[@"xcrun", @"simctl", @"spawn", udid] mutableCopy];
        [args addObjectsFromArray:spawnArgs];
        return run_with_timeout(args, 30);
    }

    /* Legacy: try simctl spawn with a short timeout — it may hang due to XPC issues */
    printf("Attempting spawn on legacy device (may timeout)...\n");
    NSMutableArray *args = [@[@"xcrun", @"simctl", @"spawn", udid] mutableCopy];
    [args addObjectsFromArray:spawnArgs];
    int rc = run_with_timeout(args, 10);
    if (rc == 124) {
        fprintf(stderr, "spawn timed out. CoreSimulator cannot communicate with legacy launchd_sim.\n");
        fprintf(stderr, "Alternatives:\n");
        fprintf(stderr, "  - Use 'rosettasim-ctl launch' to launch apps by bundle ID\n");
        fprintf(stderr, "  - Inject code via sim_app_installer.dylib constructor\n");
        return 1;
    }
    return rc;
}

/* ── Command: getenv ── */

static int cmd_getenv(NSString *udid, NSString *varname) {
    id deviceSet = get_device_set();
    if (!deviceSet) return 1;
    id device = find_device(deviceSet, udid);
    if (!device) {
        fprintf(stderr, "Device not found: %s\n", udid.UTF8String);
        return 1;
    }

    NSString *rtID = get_runtime_id(device);
    BOOL legacy = is_legacy_runtime(rtID);

    if (!legacy) {
        return run_with_timeout(@[@"xcrun", @"simctl", @"getenv", udid, varname], 10);
    }

    /* Legacy: simctl getenv uses XPC to query launchd_sim, which hangs.
     * Try reading from the launchd_sim process environment directly. */
    NSString *pgrepCmd = [NSString stringWithFormat:
        @"pgrep -f 'launchd_sim.*%@'", udid];
    int ec = 0;
    NSString *pid = run_capture(@[@"/bin/sh", @"-c", pgrepCmd], &ec);
    pid = [pid stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

    if (pid.length > 0) {
        /* Read environment from ps */
        NSString *envCmd = [NSString stringWithFormat:
            @"ps -p %@ -wwE -o command= | tr ' ' '\\n' | grep '^%@='", pid, varname];
        NSString *result = run_capture(@[@"/bin/sh", @"-c", envCmd], &ec);
        result = [result stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (result.length > 0) {
            /* Extract value after = */
            NSRange eq = [result rangeOfString:@"="];
            if (eq.location != NSNotFound) {
                printf("%s\n", [result substringFromIndex:eq.location + 1].UTF8String);
                return 0;
            }
        }
    }

    fprintf(stderr, "getenv: variable '%s' not found (legacy device — limited support)\n",
            varname.UTF8String);
    return 1;
}

/* ── Command: logverbose ── */

static int cmd_logverbose(NSString *udid, NSString *enabled) {
    return run_with_timeout(@[@"xcrun", @"simctl", @"logverbose", udid, enabled], 10);
}

/* ── Command: delete (with legacy safety) ── */

static int cmd_delete(int argc, const char *argv[]) {
    if (argc < 3) {
        fprintf(stderr, "Usage: rosettasim-ctl delete <UDID|unavailable|all>\n");
        return 1;
    }

    NSString *target = [NSString stringWithUTF8String:argv[2]];

    if ([target isEqualToString:@"unavailable"]) {
        /* SAFETY: simctl considers legacy runtimes "unavailable" since they're not
         * in the current Xcode SDK. We must protect legacy devices from deletion.
         * Only delete devices whose runtimes are truly missing (not just old). */
        printf("Filtering out legacy devices from 'unavailable' deletion...\n");

        id deviceSet = get_device_set();
        if (!deviceSet) return passthrough_to_simctl(argc, argv);

        NSDictionary *devices = ((id(*)(id, SEL))objc_msgSend)(deviceSet, sel_registerName("devicesByUDID"));
        int deleted = 0;
        for (NSUUID *uuid in devices) {
            id dev = devices[uuid];
            NSString *rtID = get_runtime_id(dev);
            if (!rtID) continue;

            /* Check if runtime is "available" (has a valid runtime object with a root path) */
            id runtime = ((id(*)(id, SEL))objc_msgSend)(dev, sel_registerName("runtime"));
            BOOL available = NO;
            if (runtime) {
                NSString *rootPath = ((id(*)(id, SEL))objc_msgSend)(runtime, sel_registerName("root"));
                available = (rootPath != nil && [[NSFileManager defaultManager] fileExistsAtPath:rootPath]);
            }

            if (!available && !is_legacy_runtime(rtID)) {
                /* Truly unavailable non-legacy device — delete it */
                printf("  Deleting: %s (%s)\n", uuid.UUIDString.UTF8String,
                       get_device_name(dev).UTF8String);
                run_with_timeout(@[@"xcrun", @"simctl", @"delete", uuid.UUIDString], 15);
                deleted++;
            } else if (!available && is_legacy_runtime(rtID)) {
                printf("  Protecting legacy device: %s (%s) [%s]\n",
                       uuid.UUIDString.UTF8String, get_device_name(dev).UTF8String,
                       rtID.UTF8String);
            }
        }
        printf("Deleted %d unavailable non-legacy device(s).\n", deleted);
        return 0;
    }

    /* For explicit UDID or "all", passthrough is fine */
    return passthrough_to_simctl(argc, argv);
}

/* ── Command: appinfo ── */

static int cmd_appinfo(NSString *udid, NSString *bundleID) {
    id deviceSet = get_device_set();
    if (!deviceSet) return 1;
    id device = find_device(deviceSet, udid);
    if (!device) {
        fprintf(stderr, "Device not found: %s\n", udid.UTF8String);
        return 1;
    }

    NSString *rtID = get_runtime_id(device);
    BOOL legacy = is_legacy_runtime(rtID);

    if (!legacy) {
        /* Native: use simctl appinfo if available, else listapps + filter */
        return run_with_timeout(@[@"xcrun", @"simctl", @"appinfo", udid, bundleID], 15);
    }

    /* Legacy: read from LaunchServicesMap + app Info.plist */
    NSDictionary *lsMap = read_ls_map(udid);
    NSDictionary *appInfo = nil;
    NSString *section = nil;

    for (NSString *sec in @[@"User", @"System", @"Internal"]) {
        if (lsMap[sec][bundleID]) {
            appInfo = lsMap[sec][bundleID];
            section = sec;
            break;
        }
    }

    NSMutableDictionary *result = [NSMutableDictionary new];
    result[@"CFBundleIdentifier"] = bundleID;

    if (appInfo) {
        if (appInfo[@"Path"]) result[@"Path"] = appInfo[@"Path"];
        if (appInfo[@"Container"]) result[@"DataContainer"] = appInfo[@"Container"];
        result[@"ApplicationType"] = section;

        /* Read additional fields from the app's Info.plist */
        NSString *appPlistPath = [appInfo[@"Path"] stringByAppendingPathComponent:@"Info.plist"];
        NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:appPlistPath];
        if (info) {
            if (info[@"CFBundleDisplayName"]) result[@"CFBundleDisplayName"] = info[@"CFBundleDisplayName"];
            if (info[@"CFBundleName"]) result[@"CFBundleName"] = info[@"CFBundleName"];
            if (info[@"CFBundleExecutable"]) result[@"CFBundleExecutable"] = info[@"CFBundleExecutable"];
            if (info[@"CFBundleVersion"]) result[@"CFBundleVersion"] = info[@"CFBundleVersion"];
            if (info[@"CFBundleShortVersionString"]) result[@"CFBundleShortVersionString"] = info[@"CFBundleShortVersionString"];
            if (info[@"MinimumOSVersion"]) result[@"MinimumOSVersion"] = info[@"MinimumOSVersion"];
        }
        /* Bundle container = parent of .app */
        if (appInfo[@"Path"])
            result[@"Bundle"] = [appInfo[@"Path"] stringByDeletingLastPathComponent];
    } else {
        /* Fallback: search containers */
        NSString *containersPath = [NSString stringWithFormat:
            @"%@/Library/Developer/CoreSimulator/Devices/%@/data/Containers/Bundle/Application",
            NSHomeDirectory(), udid];
        NSFileManager *fm = [NSFileManager defaultManager];
        for (NSString *cuuid in [fm contentsOfDirectoryAtPath:containersPath error:nil]) {
            NSString *containerDir = [containersPath stringByAppendingPathComponent:cuuid];
            for (NSString *item in [fm contentsOfDirectoryAtPath:containerDir error:nil]) {
                if (![item hasSuffix:@".app"]) continue;
                NSString *appPath = [containerDir stringByAppendingPathComponent:item];
                NSString *infoPlist = [appPath stringByAppendingPathComponent:@"Info.plist"];
                NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:infoPlist];
                if ([info[@"CFBundleIdentifier"] isEqualToString:bundleID]) {
                    result[@"Path"] = appPath;
                    result[@"Bundle"] = containerDir;
                    result[@"ApplicationType"] = @"User";
                    if (info[@"CFBundleDisplayName"]) result[@"CFBundleDisplayName"] = info[@"CFBundleDisplayName"];
                    if (info[@"CFBundleExecutable"]) result[@"CFBundleExecutable"] = info[@"CFBundleExecutable"];
                    if (info[@"CFBundleVersion"]) result[@"CFBundleVersion"] = info[@"CFBundleVersion"];
                    if (info[@"CFBundleShortVersionString"]) result[@"CFBundleShortVersionString"] = info[@"CFBundleShortVersionString"];
                    goto found;
                }
            }
        }
        fprintf(stderr, "App %s not found.\n", bundleID.UTF8String);
        return 1;
    }
found:;

    /* Print as JSON */
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:result
                                                       options:NSJSONWritingPrettyPrinted error:nil];
    if (jsonData) {
        printf("%s\n", [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding].UTF8String);
    }
    return 0;
}

/* ── Command: privacy (TCC.db manipulation for legacy) ── */

static int cmd_privacy(NSString *udid, NSString *action, NSString *service, NSString *bundleID) {
    id deviceSet = get_device_set();
    if (!deviceSet) return 1;
    id device = find_device(deviceSet, udid);
    if (!device) {
        fprintf(stderr, "Device not found: %s\n", udid.UTF8String);
        return 1;
    }

    NSString *rtID = get_runtime_id(device);
    BOOL legacy = is_legacy_runtime(rtID);

    if (!legacy) {
        NSMutableArray *args = [@[@"xcrun", @"simctl", @"privacy", udid, action, service] mutableCopy];
        if (bundleID) [args addObject:bundleID];
        return run_with_timeout(args, 15);
    }

    /* Map service names to TCC service keys */
    NSDictionary *serviceMap = @{
        @"photos": @"kTCCServicePhotos",
        @"camera": @"kTCCServiceCamera",
        @"microphone": @"kTCCServiceMicrophone",
        @"contacts": @"kTCCServiceAddressBook",
        @"calendar": @"kTCCServiceCalendar",
        @"reminders": @"kTCCServiceReminders",
        @"location": @"kTCCServiceLocation",
        @"media-library": @"kTCCServiceMediaLibrary",
        @"motion": @"kTCCServiceMotion",
        @"siri": @"kTCCServiceSiri",
        @"speech-recognition": @"kTCCServiceSpeechRecognition",
        @"all": @"ALL",
    };

    NSString *tccService = serviceMap[service];
    if (!tccService) {
        fprintf(stderr, "Unknown service: %s\nKnown: photos, camera, microphone, contacts, calendar, "
                "reminders, location, media-library, motion, siri, speech-recognition, all\n",
                service.UTF8String);
        return 1;
    }

    NSString *tccPath = [NSString stringWithFormat:
        @"%@/Library/Developer/CoreSimulator/Devices/%@/data/Library/TCC/TCC.db",
        NSHomeDirectory(), udid];

    if (![[NSFileManager defaultManager] fileExistsAtPath:tccPath]) {
        /* Create TCC directory and empty DB */
        NSString *tccDir = [tccPath stringByDeletingLastPathComponent];
        [[NSFileManager defaultManager] createDirectoryAtPath:tccDir
                                  withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *createCmd = [NSString stringWithFormat:
            @"sqlite3 '%@' 'CREATE TABLE IF NOT EXISTS access ("
            "service TEXT NOT NULL, client TEXT NOT NULL, client_type INTEGER NOT NULL DEFAULT 0, "
            "allowed INTEGER NOT NULL DEFAULT 1, prompt_count INTEGER NOT NULL DEFAULT 0, "
            "PRIMARY KEY (service, client, client_type))'", tccPath];
        system(createCmd.UTF8String);
    }

    if ([action isEqualToString:@"grant"]) {
        if (!bundleID) { fprintf(stderr, "grant requires a bundle-id\n"); return 1; }
        if ([tccService isEqualToString:@"ALL"]) {
            for (NSString *svc in serviceMap.allValues) {
                if ([svc isEqualToString:@"ALL"]) continue;
                NSString *sql = [NSString stringWithFormat:
                    @"sqlite3 '%@' \"INSERT OR REPLACE INTO access (service, client, client_type, allowed, prompt_count) "
                    "VALUES ('%@', '%@', 0, 1, 0)\"", tccPath, svc, bundleID];
                system(sql.UTF8String);
            }
        } else {
            NSString *sql = [NSString stringWithFormat:
                @"sqlite3 '%@' \"INSERT OR REPLACE INTO access (service, client, client_type, allowed, prompt_count) "
                "VALUES ('%@', '%@', 0, 1, 0)\"", tccPath, tccService, bundleID];
            system(sql.UTF8String);
        }
        printf("Granted %s access to %s\n", service.UTF8String, bundleID.UTF8String);
    }
    else if ([action isEqualToString:@"revoke"]) {
        if (!bundleID) { fprintf(stderr, "revoke requires a bundle-id\n"); return 1; }
        NSString *sql = [NSString stringWithFormat:
            @"sqlite3 '%@' \"UPDATE access SET allowed=0 WHERE client='%@'%@\"",
            tccPath, bundleID,
            [tccService isEqualToString:@"ALL"] ? @"" :
            [NSString stringWithFormat:@" AND service='%@'", tccService]];
        system(sql.UTF8String);
        printf("Revoked %s access for %s\n", service.UTF8String, bundleID.UTF8String);
    }
    else if ([action isEqualToString:@"reset"]) {
        NSString *sql;
        if (bundleID) {
            sql = [NSString stringWithFormat:
                @"sqlite3 '%@' \"DELETE FROM access WHERE client='%@'%@\"",
                tccPath, bundleID,
                [tccService isEqualToString:@"ALL"] ? @"" :
                [NSString stringWithFormat:@" AND service='%@'", tccService]];
        } else {
            sql = [NSString stringWithFormat:
                @"sqlite3 '%@' \"DELETE FROM access%@\"",
                tccPath,
                [tccService isEqualToString:@"ALL"] ? @"" :
                [NSString stringWithFormat:@" WHERE service='%@'", tccService]];
        }
        system(sql.UTF8String);
        printf("Reset %s privacy settings%s\n", service.UTF8String,
               bundleID ? [NSString stringWithFormat:@" for %@", bundleID].UTF8String : "");
    }
    else {
        fprintf(stderr, "Unknown action: %s (use grant, revoke, or reset)\n", action.UTF8String);
        return 1;
    }

    return 0;
}

/* ── Command: addmedia ── */

static int cmd_addmedia(NSString *udid, NSArray<NSString *> *files) {
    id deviceSet = get_device_set();
    if (!deviceSet) return 1;
    id device = find_device(deviceSet, udid);
    if (!device) {
        fprintf(stderr, "Device not found: %s\n", udid.UTF8String);
        return 1;
    }

    NSString *rtID = get_runtime_id(device);
    BOOL legacy = is_legacy_runtime(rtID);

    if (!legacy) {
        NSMutableArray *args = [@[@"xcrun", @"simctl", @"addmedia", udid] mutableCopy];
        [args addObjectsFromArray:files];
        return run_with_timeout(args, 30);
    }

    /* Legacy: copy to DCIM directory */
    NSString *dcimPath = [NSString stringWithFormat:
        @"%@/Library/Developer/CoreSimulator/Devices/%@/data/Media/DCIM/100APPLE",
        NSHomeDirectory(), udid];
    [[NSFileManager defaultManager] createDirectoryAtPath:dcimPath
                              withIntermediateDirectories:YES attributes:nil error:nil];

    NSFileManager *fm = [NSFileManager defaultManager];
    int copied = 0;
    for (NSString *file in files) {
        if (![fm fileExistsAtPath:file]) {
            fprintf(stderr, "File not found: %s\n", file.UTF8String);
            continue;
        }
        NSString *dest = [dcimPath stringByAppendingPathComponent:[file lastPathComponent]];
        NSError *err = nil;
        [fm removeItemAtPath:dest error:nil];
        if ([fm copyItemAtPath:file toPath:dest error:&err]) {
            printf("  Copied: %s\n", [file lastPathComponent].UTF8String);
            copied++;
        } else {
            fprintf(stderr, "  Failed: %s (%s)\n", [file lastPathComponent].UTF8String,
                    err.localizedDescription.UTF8String);
        }
    }
    printf("Added %d file(s) to device media.\n", copied);
    printf("  Note: Files are in DCIM but won't appear in Photos without DB update.\n");
    return copied > 0 ? 0 : 1;
}

/* ── Command: touch (rosettasim extension) ── */

/* Send touch via file-based IPC to sim_touch_inject.dylib in backboardd.
 * Writes JSONL touch events to {deviceDataPath}/tmp/rosettasim_touch.json.
 * The dylib polls this file and dispatches IOHIDEvents directly. */

static int cmd_touch(NSString *udid, float x, float y, int duration_ms) {
    id deviceSet = get_device_set();
    if (!deviceSet) return 1;
    id device = find_device(deviceSet, udid);
    if (!device) {
        fprintf(stderr, "Device not found: %s\n", udid.UTF8String);
        return 1;
    }

    long state = get_device_state(device);
    if (state != 3) {
        fprintf(stderr, "Device is not booted (state: %s)\n", state_string(state).UTF8String);
        return 1;
    }

    /* Get device data path */
    NSString *dataPath = get_device_data_path(device);
    if (!dataPath) {
        fprintf(stderr, "Could not determine device data path\n");
        return 1;
    }

    NSString *tmpDir = [dataPath stringByAppendingPathComponent:@"tmp"];
    [[NSFileManager defaultManager] createDirectoryAtPath:tmpDir
                              withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *cmdPath = [tmpDir stringByAppendingPathComponent:@"rosettasim_touch.json"];

    printf("Touch at (%.0f, %.0f) duration=%dms on %s\n",
           x, y, duration_ms, get_device_name(device).UTF8String);

    /* Send touch down as separate file write, wait, then send touch up.
     * UIKit needs ~150ms+ between down and up to register as a tap.
     * Writing both in the same file results in only 16ms between them (too fast). */

    NSString *downJson = [NSString stringWithFormat:
        @"{\"action\":\"down\",\"x\":%.1f,\"y\":%.1f,\"finger\":0}\n", x, y];
    NSString *upJson = [NSString stringWithFormat:
        @"{\"action\":\"up\",\"x\":%.1f,\"y\":%.1f,\"finger\":0}\n", x, y];

    NSError *err = nil;

    /* Touch down */
    [downJson writeToFile:cmdPath atomically:YES encoding:NSUTF8StringEncoding error:&err];
    if (err) {
        fprintf(stderr, "Failed to write touch down: %s\n", err.localizedDescription.UTF8String);
        return 1;
    }

    /* Wait for dylib to pick up down (100ms poll) + duration for the hold */
    int hold_ms = duration_ms > 0 ? duration_ms : 150;
    usleep((100 + hold_ms) * 1000);

    /* Touch up */
    [upJson writeToFile:cmdPath atomically:YES encoding:NSUTF8StringEncoding error:&err];
    if (err) {
        fprintf(stderr, "Failed to write touch up: %s\n", err.localizedDescription.UTF8String);
        return 1;
    }

    /* Wait for dylib to pick up up event */
    usleep(200000); /* 200ms */

    printf("Touch complete.\n");
    return 0;
}

/* ── Command: sendtext (rosettasim extension) ── */

static int cmd_sendtext(NSString *udid, NSString *text) {
    id deviceSet = get_device_set();
    if (!deviceSet) return 1;
    id device = find_device(deviceSet, udid);
    if (!device) { fprintf(stderr, "Device not found: %s\n", udid.UTF8String); return 1; }
    if (get_device_state(device) != 3) { fprintf(stderr, "Device not booted\n"); return 1; }

    NSString *dataPath = get_device_data_path(device);
    if (!dataPath) { fprintf(stderr, "Could not determine device data path\n"); return 1; }

    /* Keyboard events go through backboardd (rosettasim_touch_bb.json) */
    NSString *cmdPath = [dataPath stringByAppendingPathComponent:@ROSETTASIM_DEV_TOUCH_BB_FILE];
    [[NSFileManager defaultManager] createDirectoryAtPath:[dataPath stringByAppendingPathComponent:@"tmp"]
                              withIntermediateDirectories:YES attributes:nil error:nil];

    NSString *escaped = [text stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
    escaped = [escaped stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
    NSString *json = [NSString stringWithFormat:@"{\"action\":\"text\",\"text\":\"%@\"}\n", escaped];

    NSError *err = nil;
    [json writeToFile:cmdPath atomically:YES encoding:NSUTF8StringEncoding error:&err];
    if (err) { fprintf(stderr, "Write failed: %s\n", err.localizedDescription.UTF8String); return 1; }

    printf("Sending text \"%s\" to %s\n", text.UTF8String, get_device_name(device).UTF8String);

    /* Wait for processing: ~80ms per character (30ms hold + 30ms gap + overhead) */
    usleep((unsigned)(text.length * 80000 + 200000));
    printf("Text sent.\n");
    return 0;
}

/* ── Command: keyevent (rosettasim extension) ── */

static int cmd_keyevent(NSString *udid, uint32_t page, uint32_t usage) {
    id deviceSet = get_device_set();
    if (!deviceSet) return 1;
    id device = find_device(deviceSet, udid);
    if (!device) { fprintf(stderr, "Device not found: %s\n", udid.UTF8String); return 1; }
    if (get_device_state(device) != 3) { fprintf(stderr, "Device not booted\n"); return 1; }

    NSString *dataPath = get_device_data_path(device);
    if (!dataPath) { fprintf(stderr, "Could not determine device data path\n"); return 1; }

    NSString *cmdPath = [dataPath stringByAppendingPathComponent:@ROSETTASIM_DEV_TOUCH_BB_FILE];
    [[NSFileManager defaultManager] createDirectoryAtPath:[dataPath stringByAppendingPathComponent:@"tmp"]
                              withIntermediateDirectories:YES attributes:nil error:nil];

    NSString *json = [NSString stringWithFormat:
        @"{\"action\":\"key\",\"page\":%u,\"usage\":%u}\n", page, usage];

    NSError *err = nil;
    [json writeToFile:cmdPath atomically:YES encoding:NSUTF8StringEncoding error:&err];
    if (err) { fprintf(stderr, "Write failed: %s\n", err.localizedDescription.UTF8String); return 1; }

    printf("Key event page=%u usage=%u sent to %s\n", page, usage, get_device_name(device).UTF8String);
    usleep(300000);
    return 0;
}

/* ── Command: location ── */

/* NOTE: cmd_sendtext and cmd_keyevent defined above (lines ~1635, ~1668) */

#if 0 /* duplicate definitions removed — keep originals above */
static int _removed_cmd_sendtext(NSString *udid, NSString *text) {
    id deviceSet = get_device_set();
    if (!deviceSet) return 1;
    id device = find_device(deviceSet, udid);
    if (!device) {
        fprintf(stderr, "Device not found: %s\n", udid.UTF8String);
        return 1;
    }

    long state = get_device_state(device);
    if (state != 3) {
        fprintf(stderr, "Device is not booted (state: %s)\n", state_string(state).UTF8String);
        return 1;
    }

    NSString *dataPath = get_device_data_path(device);
    if (!dataPath) {
        fprintf(stderr, "Could not determine device data path\n");
        return 1;
    }

    NSString *tmpDir = [dataPath stringByAppendingPathComponent:@"tmp"];
    [[NSFileManager defaultManager] createDirectoryAtPath:tmpDir
                              withIntermediateDirectories:YES attributes:nil error:nil];
    /* Keyboard events go through backboardd (rosettasim_touch_bb.json) */
    NSString *cmdPath = [tmpDir stringByAppendingPathComponent:@"rosettasim_touch_bb.json"];

    printf("Sending text: \"%s\" to %s\n", text.UTF8String, get_device_name(device).UTF8String);

    /* Escape the text for JSON */
    NSData *textData = [NSJSONSerialization dataWithJSONObject:@{
        @"action": @"text",
        @"text": text,
        @"x": @0,
        @"y": @0
    } options:0 error:nil];
    NSString *json = [[NSString alloc] initWithData:textData encoding:NSUTF8StringEncoding];
    NSString *jsonLine = [json stringByAppendingString:@"\n"];

    NSError *err = nil;
    [jsonLine writeToFile:cmdPath atomically:YES encoding:NSUTF8StringEncoding error:&err];
    if (err) {
        fprintf(stderr, "Failed to write command: %s\n", err.localizedDescription.UTF8String);
        return 1;
    }

    /* Wait for processing: ~60ms per character (30ms down + 30ms up) + overhead */
    int wait_ms = (int)(text.length * 80 + 500);
    usleep(wait_ms * 1000);

    printf("Text sent.\n");
    return 0;
}

/* ── Command: keyevent ── */

static int cmd_keyevent(NSString *udid, uint32_t usagePage, uint32_t usage) {
    id deviceSet = get_device_set();
    if (!deviceSet) return 1;
    id device = find_device(deviceSet, udid);
    if (!device) {
        fprintf(stderr, "Device not found: %s\n", udid.UTF8String);
        return 1;
    }

    long state = get_device_state(device);
    if (state != 3) {
        fprintf(stderr, "Device is not booted (state: %s)\n", state_string(state).UTF8String);
        return 1;
    }

    NSString *dataPath = get_device_data_path(device);
    if (!dataPath) {
        fprintf(stderr, "Could not determine device data path\n");
        return 1;
    }

    NSString *tmpDir = [dataPath stringByAppendingPathComponent:@"tmp"];
    [[NSFileManager defaultManager] createDirectoryAtPath:tmpDir
                              withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *cmdPath = [tmpDir stringByAppendingPathComponent:@"rosettasim_touch_bb.json"];

    printf("Key event: page=%u usage=%u on %s\n",
           usagePage, usage, get_device_name(device).UTF8String);

    NSString *json = [NSString stringWithFormat:
        @"{\"action\":\"key\",\"page\":%u,\"usage\":%u,\"x\":0,\"y\":0}\n",
        usagePage, usage];

    NSError *err = nil;
    [json writeToFile:cmdPath atomically:YES encoding:NSUTF8StringEncoding error:&err];
    if (err) {
        fprintf(stderr, "Failed to write command: %s\n", err.localizedDescription.UTF8String);
        return 1;
    }

    usleep(200000); /* 200ms for processing */

    printf("Key event sent.\n");
    return 0;
}
#endif /* duplicate removed */

/* ── Command: location ── */

static int cmd_location(NSString *udid, int argc, const char *argv[]) {
    id deviceSet = get_device_set();
    if (!deviceSet) return 1;
    id device = find_device(deviceSet, udid);
    if (!device) {
        fprintf(stderr, "Device not found: %s\n", udid.UTF8String);
        return 1;
    }

    NSString *rtID = get_runtime_id(device);
    if (!is_legacy_runtime(rtID)) {
        return passthrough_to_simctl(argc, argv);
    }

    if (argc < 4) {
        fprintf(stderr, "Usage: rosettasim-ctl location <UDID> set <lat>,<lon>\n");
        fprintf(stderr, "       rosettasim-ctl location <UDID> clear\n");
        return 1;
    }

    if (strcmp(argv[3], "clear") == 0) {
        NSString *cmdPath = [NSString stringWithFormat:
        @ROSETTASIM_HOST_CMD_NSFMT, udid];
        NSDictionary *cmd = @{@"action": @"location", @"clear": @YES};
        NSData *jsonData = [NSJSONSerialization dataWithJSONObject:cmd options:0 error:nil];
        [jsonData writeToFile:cmdPath atomically:YES];
        char notifyName[256];
        snprintf(notifyName, sizeof(notifyName), "com.rosettasim.location.%s", udid.UTF8String);
        notify_post(notifyName);
        printf("Location cleared on %s\n", get_device_name(device).UTF8String);
        return 0;
    }

    if (strcmp(argv[3], "set") != 0 || argc < 5) {
        fprintf(stderr, "Usage: rosettasim-ctl location <UDID> set <lat>,<lon>\n");
        fprintf(stderr, "       rosettasim-ctl location <UDID> clear\n");
        return 1;
    }

    /* Parse lat,lon */
    double lat = 0, lon = 0;
    if (sscanf(argv[4], "%lf,%lf", &lat, &lon) != 2) {
        fprintf(stderr, "Invalid coordinates: %s (expected lat,lon e.g. 51.5074,-0.1278)\n", argv[4]);
        return 1;
    }

    NSString *cmdPath = [NSString stringWithFormat:
        @ROSETTASIM_HOST_CMD_NSFMT, udid];
    NSDictionary *cmd = @{@"action": @"location", @"lat": @(lat), @"lon": @(lon)};
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:cmd options:0 error:nil];
    [jsonData writeToFile:cmdPath atomically:YES];

    char notifyName[256];
    snprintf(notifyName, sizeof(notifyName), "com.rosettasim.location.%s", udid.UTF8String);
    notify_post(notifyName);

    printf("Location set to %.6f, %.6f on %s\n", lat, lon, get_device_name(device).UTF8String);
    printf("  Note: requires sim_app_installer.dylib with location handler.\n");
    return 0;
}

/* ── Command: push ── */

static int cmd_push(NSString *udid, int argc, const char *argv[]) {
    id deviceSet = get_device_set();
    if (!deviceSet) return 1;
    id device = find_device(deviceSet, udid);
    if (!device) {
        fprintf(stderr, "Device not found: %s\n", udid.UTF8String);
        return 1;
    }

    NSString *rtID = get_runtime_id(device);
    if (!is_legacy_runtime(rtID)) {
        return passthrough_to_simctl(argc, argv);
    }

    /* Usage: push <device> <bundle-id> <json-file-or--> */
    if (argc < 5) {
        fprintf(stderr, "Usage: rosettasim-ctl push <UDID> <bundle-id> <payload.json|->\n");
        return 1;
    }

    NSString *bundleID = [NSString stringWithUTF8String:argv[3]];
    NSString *payloadArg = [NSString stringWithUTF8String:argv[4]];

    /* Read payload from file or stdin */
    NSData *payloadData = nil;
    if ([payloadArg isEqualToString:@"-"]) {
        payloadData = [[NSFileHandle fileHandleWithStandardInput] readDataToEndOfFile];
    } else {
        payloadData = [NSData dataWithContentsOfFile:payloadArg];
        if (!payloadData) {
            fprintf(stderr, "Cannot read payload file: %s\n", payloadArg.UTF8String);
            return 1;
        }
    }

    /* Validate JSON */
    NSDictionary *payload = [NSJSONSerialization JSONObjectWithData:payloadData options:0 error:nil];
    if (![payload isKindOfClass:[NSDictionary class]]) {
        fprintf(stderr, "Invalid JSON payload\n");
        return 1;
    }

    /* Write push command for sim_app_installer.dylib */
    NSString *cmdPath = [NSString stringWithFormat:
        @ROSETTASIM_HOST_CMD_NSFMT, udid];
    NSDictionary *cmd = @{
        @"action": @"push",
        @"bundle_id": bundleID,
        @"payload": payload,
    };
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:cmd options:0 error:nil];
    [jsonData writeToFile:cmdPath atomically:YES];

    char notifyName[256];
    snprintf(notifyName, sizeof(notifyName), "com.rosettasim.push.%s", udid.UTF8String);
    notify_post(notifyName);

    /* Extract alert for display */
    NSDictionary *aps = payload[@"aps"];
    NSString *alert = nil;
    if ([aps[@"alert"] isKindOfClass:[NSString class]]) alert = aps[@"alert"];
    else if ([aps[@"alert"] isKindOfClass:[NSDictionary class]]) alert = aps[@"alert"][@"body"];

    printf("Push notification sent to %s on %s\n", bundleID.UTF8String,
           get_device_name(device).UTF8String);
    if (alert) printf("  Alert: %s\n", alert.UTF8String);
    printf("  Note: requires sim_app_installer.dylib with push handler.\n");
    return 0;
}

/* ── Command: ui ── */

static int cmd_ui(NSString *udid, int argc, const char *argv[]) {
    id deviceSet = get_device_set();
    if (!deviceSet) return 1;
    id device = find_device(deviceSet, udid);
    if (!device) {
        fprintf(stderr, "Device not found: %s\n", udid.UTF8String);
        return 1;
    }

    NSString *rtID = get_runtime_id(device);
    if (!is_legacy_runtime(rtID)) {
        return passthrough_to_simctl(argc, argv);
    }

    if (argc < 5) {
        fprintf(stderr, "Usage: rosettasim-ctl ui <UDID> content_size <category>\n");
        fprintf(stderr, "       rosettasim-ctl ui <UDID> appearance <light|dark>\n");
        fprintf(stderr, "\nContent size categories: extra-small, small, medium, large (default),\n");
        fprintf(stderr, "  extra-large, extra-extra-large, extra-extra-extra-large,\n");
        fprintf(stderr, "  accessibility-medium, accessibility-large, accessibility-extra-large,\n");
        fprintf(stderr, "  accessibility-extra-extra-large, accessibility-extra-extra-extra-large\n");
        return 1;
    }

    NSString *option = [NSString stringWithUTF8String:argv[3]];
    NSString *value = [NSString stringWithUTF8String:argv[4]];

    if ([option isEqualToString:@"appearance"]) {
        fprintf(stderr, "appearance (dark mode) requires iOS 13+. Not available on legacy simulators.\n");
        return 1;
    }

    if ([option isEqualToString:@"content_size"]) {
        /* Map size name to UIContentSizeCategory key */
        NSDictionary *sizeMap = @{
            @"extra-small": @"UICTContentSizeCategoryXS",
            @"small": @"UICTContentSizeCategoryS",
            @"medium": @"UICTContentSizeCategoryM",
            @"large": @"UICTContentSizeCategoryL",
            @"extra-large": @"UICTContentSizeCategoryXL",
            @"extra-extra-large": @"UICTContentSizeCategoryXXL",
            @"extra-extra-extra-large": @"UICTContentSizeCategoryXXXL",
            @"accessibility-medium": @"UICTContentSizeCategoryAccessibilityM",
            @"accessibility-large": @"UICTContentSizeCategoryAccessibilityL",
            @"accessibility-extra-large": @"UICTContentSizeCategoryAccessibilityXL",
            @"accessibility-extra-extra-large": @"UICTContentSizeCategoryAccessibilityXXL",
            @"accessibility-extra-extra-extra-large": @"UICTContentSizeCategoryAccessibilityXXXL",
        };

        NSString *category = sizeMap[value];
        if (!category) {
            fprintf(stderr, "Unknown content size: %s\n", value.UTF8String);
            return 1;
        }

        /* Write to device's accessibility prefs plist */
        NSString *prefsPath = [NSString stringWithFormat:
            @"%@/Library/Developer/CoreSimulator/Devices/%@/data/Library/Preferences/com.apple.Accessibility.plist",
            NSHomeDirectory(), udid];

        /* Ensure directory exists */
        NSString *prefsDir = [prefsPath stringByDeletingLastPathComponent];
        [[NSFileManager defaultManager] createDirectoryAtPath:prefsDir
                                  withIntermediateDirectories:YES attributes:nil error:nil];

        /* Read existing or create new */
        NSMutableDictionary *prefs = [NSMutableDictionary dictionaryWithContentsOfFile:prefsPath] ?: [NSMutableDictionary new];
        prefs[@"PreferredContentSizeCategoryName"] = category;
        [prefs writeToFile:prefsPath atomically:YES];

        printf("Content size set to %s (%s) on %s\n",
               value.UTF8String, category.UTF8String, get_device_name(device).UTF8String);
        printf("  Reboot device for change to take effect.\n");
        return 0;
    }

    fprintf(stderr, "Unknown UI option: %s (use content_size or appearance)\n", option.UTF8String);
    return 1;
}

/* ── Command: keychain ── */

static int cmd_keychain(NSString *udid, int argc, const char *argv[]) {
    id deviceSet = get_device_set();
    if (!deviceSet) return 1;
    id device = find_device(deviceSet, udid);
    if (!device) {
        fprintf(stderr, "Device not found: %s\n", udid.UTF8String);
        return 1;
    }

    NSString *rtID = get_runtime_id(device);
    if (!is_legacy_runtime(rtID)) {
        return passthrough_to_simctl(argc, argv);
    }

    if (argc < 4) {
        fprintf(stderr, "Usage: rosettasim-ctl keychain <UDID> reset\n");
        fprintf(stderr, "       rosettasim-ctl keychain <UDID> add-root-cert <cert.pem>\n");
        fprintf(stderr, "       rosettasim-ctl keychain <UDID> add-cert <cert.pem>\n");
        return 1;
    }

    NSString *action = [NSString stringWithUTF8String:argv[3]];
    NSString *deviceDataPath = [NSString stringWithFormat:
        @"%@/Library/Developer/CoreSimulator/Devices/%@/data",
        NSHomeDirectory(), udid];

    if ([action isEqualToString:@"reset"]) {
        /* Delete keychain databases */
        NSString *keychainsDir = [deviceDataPath stringByAppendingPathComponent:@"Library/Keychains"];
        NSFileManager *fm = [NSFileManager defaultManager];
        int removed = 0;
        for (NSString *file in [fm contentsOfDirectoryAtPath:keychainsDir error:nil]) {
            if ([file hasPrefix:@"keychain-"] || [file hasPrefix:@"TrustStore"]) {
                [fm removeItemAtPath:[keychainsDir stringByAppendingPathComponent:file] error:nil];
                removed++;
            }
        }
        printf("Keychain reset: removed %d file(s) from %s\n", removed, keychainsDir.UTF8String);
        printf("  Reboot device for change to take effect.\n");
        return 0;
    }

    if ([action isEqualToString:@"add-root-cert"] || [action isEqualToString:@"add-cert"]) {
        if (argc < 5) {
            fprintf(stderr, "Usage: rosettasim-ctl keychain <UDID> %s <cert.pem|cert.der>\n",
                    action.UTF8String);
            return 1;
        }
        NSString *certPath = [NSString stringWithUTF8String:argv[4]];
        if (![[NSFileManager defaultManager] fileExistsAtPath:certPath]) {
            fprintf(stderr, "Certificate file not found: %s\n", certPath.UTF8String);
            return 1;
        }

        /* Copy cert to device's TrustStore via sqlite3 */
        NSData *certData = [NSData dataWithContentsOfFile:certPath];
        if (!certData) {
            fprintf(stderr, "Cannot read certificate file\n");
            return 1;
        }

        NSString *trustStorePath = [deviceDataPath stringByAppendingPathComponent:
            @"Library/Keychains/TrustStore.sqlite3"];
        NSString *keychainsDir = [trustStorePath stringByDeletingLastPathComponent];
        [[NSFileManager defaultManager] createDirectoryAtPath:keychainsDir
                                  withIntermediateDirectories:YES attributes:nil error:nil];

        /* Create table if needed and insert cert */
        NSString *createSql = [NSString stringWithFormat:
            @"sqlite3 '%@' 'CREATE TABLE IF NOT EXISTS tsettings ("
            "sha1 BLOB NOT NULL DEFAULT (x\\'\\'), subj BLOB NOT NULL DEFAULT (x\\'\\'), "
            "tset BLOB, data BLOB, PRIMARY KEY (sha1))'", trustStorePath];
        system(createSql.UTF8String);

        /* Write cert data to temp file for sqlite3 import */
        NSString *tmpCert = [NSString stringWithFormat:@"/tmp/rosettasim_cert_%@.der", udid];
        [certData writeToFile:tmpCert atomically:YES];

        NSString *insertSql = [NSString stringWithFormat:
            @"sqlite3 '%@' \"INSERT OR REPLACE INTO tsettings (sha1, subj, data) "
            "VALUES (x'0000000000000000000000000000000000000000', x'00', readfile('%@'))\"",
            trustStorePath, tmpCert];
        int rc = system(insertSql.UTF8String);
        [[NSFileManager defaultManager] removeItemAtPath:tmpCert error:nil];

        if (rc == 0) {
            printf("Certificate added to TrustStore on %s\n", get_device_name(device).UTF8String);
            printf("  Reboot device for change to take effect.\n");
        } else {
            fprintf(stderr, "Failed to add certificate to TrustStore\n");
            return 1;
        }
        return 0;
    }

    fprintf(stderr, "Unknown keychain action: %s\n", action.UTF8String);
    return 1;
}

/* ── Command: pbcopy ── */

static int cmd_pbcopy(NSString *udid) {
    id deviceSet = get_device_set();
    if (!deviceSet) return 1;
    id device = find_device(deviceSet, udid);
    if (!device) {
        fprintf(stderr, "Device not found: %s\n", udid.UTF8String);
        return 1;
    }

    NSString *rtID = get_runtime_id(device);
    if (!is_legacy_runtime(rtID)) {
        /* Native: passthrough stdin to simctl pbcopy */
        NSMutableArray *args = [@[@"xcrun", @"simctl", @"pbcopy", udid] mutableCopy];
        return run_with_timeout(args, 10);
    }

    /* Read stdin */
    NSData *inputData = [[NSFileHandle fileHandleWithStandardInput] readDataToEndOfFile];
    NSString *text = [[NSString alloc] initWithData:inputData encoding:NSUTF8StringEncoding];
    if (!text || text.length == 0) {
        fprintf(stderr, "No input received on stdin\n");
        return 1;
    }

    /* Write command for sim_app_installer.dylib */
    NSString *cmdPath = [NSString stringWithFormat:
        @ROSETTASIM_HOST_CMD_NSFMT, udid];
    NSDictionary *cmd = @{@"action": @"pbcopy", @"text": text};
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:cmd options:0 error:nil];
    [jsonData writeToFile:cmdPath atomically:YES];

    char notifyName[256];
    snprintf(notifyName, sizeof(notifyName), "com.rosettasim.pbcopy.%s", udid.UTF8String);
    notify_post(notifyName);

    printf("Copied %lu characters to device pasteboard\n", (unsigned long)text.length);
    printf("  Note: requires sim_app_installer.dylib with pbcopy handler.\n");
    return 0;
}

/* ── Command: pbpaste ── */

static int cmd_pbpaste(NSString *udid) {
    id deviceSet = get_device_set();
    if (!deviceSet) return 1;
    id device = find_device(deviceSet, udid);
    if (!device) {
        fprintf(stderr, "Device not found: %s\n", udid.UTF8String);
        return 1;
    }

    NSString *rtID = get_runtime_id(device);
    if (!is_legacy_runtime(rtID)) {
        return run_with_timeout(@[@"xcrun", @"simctl", @"pbpaste", udid], 10);
    }

    /* Write command for sim_app_installer.dylib */
    NSString *cmdPath = [NSString stringWithFormat:
        @ROSETTASIM_HOST_CMD_NSFMT, udid];
    NSDictionary *cmd = @{@"action": @"pbpaste"};
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:cmd options:0 error:nil];
    [jsonData writeToFile:cmdPath atomically:YES];

    char notifyName[256];
    snprintf(notifyName, sizeof(notifyName), "com.rosettasim.pbpaste.%s", udid.UTF8String);
    notify_post(notifyName);

    /* Wait for result */
    usleep(2000000);

    NSString *resultPath = [NSString stringWithFormat:@"/tmp/rosettasim_result_%@.txt", udid];
    NSString *result = [NSString stringWithContentsOfFile:resultPath
                                                encoding:NSUTF8StringEncoding error:nil];
    if (result) {
        printf("%s", result.UTF8String);
        [[NSFileManager defaultManager] removeItemAtPath:resultPath error:nil];
    } else {
        fprintf(stderr, "No pasteboard content received.\n");
        fprintf(stderr, "  Note: requires sim_app_installer.dylib with pbpaste handler.\n");
        return 1;
    }
    return 0;
}

/* ── Usage ── */

static void usage(void) {
    fprintf(stderr,
        "usage: simctl [--set <path>] [--profiles <path>] <subcommand> ...\n"
        "       simctl help [subcommand]\n"
        "Command line utility to control the Simulator\n"
        "\n"
        "For subcommands that require a <device> argument, you may specify a device UDID\n"
        "or the special \"booted\" string which will cause simctl to pick a booted device.\n"
        "If multiple devices are booted when the \"booted\" device is selected, simctl\n"
        "will choose one of them.\n"
        "\n"
        "Subcommands:\n"
        "\taddmedia            Add photos/videos to a device.\n"
        "\tappinfo             Show info about an installed app.\n"
        "\tboot                Boot a device or device pair.\n"
        "\tclone               Clone an existing device.\n"
        "\tcreate              Create a new device.\n"
        "\tdelete              Delete specified devices, unavailable devices, or all devices.\n"
        "\tdiagnose            Collect diagnostic info for the Simulator.\n"
        "\terase               Erase a device's contents and settings.\n"
        "\tget_app_container   Print the path of the installed app's container\n"
        "\tgetenv              Print an environment variable from a running device.\n"
        "\thelp                Prints the usage for a given subcommand.\n"
        "\tinstall             Install an app on a device.\n"
        "\tio                  Set up a device IO operation.\n"
        "\tkeychain            Manipulate a device's keychain.\n"
        "\tlaunch              Launch an application by identifier on a device.\n"
        "\tlist                List available devices, device types, runtimes, or device pairs.\n"
        "\tlistapps            Show the installed applications.\n"
        "\tlocation            Control a device's simulated location.\n"
        "\tlogverbose          enable or disable verbose logging for a device\n"
        "\topenurl             Open a URL in a device.\n"
        "\tpbcopy              Copy standard input onto the device pasteboard.\n"
        "\tpbpaste             Print the contents of the device pasteboard.\n"
        "\tpbsync              Sync the pasteboard content.\n"
        "\tprivacy             Grant, revoke, or reset privacy permissions.\n"
        "\tpush                Send a simulated push notification.\n"
        "\trename              Rename a device.\n"
        "\tshutdown            Shutdown a device.\n"
        "\tspawn               Spawn a process by executing a given executable on a device.\n"
        "\tstatus              Show device status (rosettasim extension).\n"
        "\tstatus_bar           Override information shown in the status bar.\n"
        "\tterminate           Terminate an application by identifier on a device.\n"
        "\ttouch               Send a touch event to a device (rosettasim extension).\n"
        "\tsendtext            Send text input to a device (rosettasim extension).\n"
        "\tkeyevent            Send a HID key event to a device (rosettasim extension).\n"
        "\tui                  Get or set UI options.\n"
        "\tuninstall           Uninstall an app from a device.\n"
        "\n"
        "rosettasim-ctl: drop-in simctl replacement with legacy device support.\n"
        "Unknown commands are forwarded to xcrun simctl.\n"
    );
}

/* ── Main ── */

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 2) {
            usage();
            return 1;
        }

        NSString *cmd = [NSString stringWithUTF8String:argv[1]];

        if ([cmd isEqualToString:@"list"]) {
            /* Pass through to simctl — it handles all list formats correctly.
             * Our legacy devices appear in simctl list since they're registered
             * with CoreSimulatorService. No override needed. */
            return passthrough_to_simctl(argc, argv);
        }
        else if ([cmd isEqualToString:@"boot"]) {
            if (argc < 3) { fprintf(stderr, "Usage: rosettasim-ctl boot <UDID>\n"); return 1; }
            return cmd_boot([NSString stringWithUTF8String:argv[2]]);
        }
        else if ([cmd isEqualToString:@"shutdown"]) {
            if (argc < 3) { fprintf(stderr, "Usage: rosettasim-ctl shutdown <UDID|all>\n"); return 1; }
            return cmd_shutdown([NSString stringWithUTF8String:argv[2]]);
        }
        else if ([cmd isEqualToString:@"install"]) {
            if (argc < 4) { fprintf(stderr, "Usage: rosettasim-ctl install <UDID> <app-path>\n"); return 1; }
            return cmd_install([NSString stringWithUTF8String:argv[2]],
                              [NSString stringWithUTF8String:argv[3]]);
        }
        else if ([cmd isEqualToString:@"launch"]) {
            if (argc < 4) { fprintf(stderr, "Usage: rosettasim-ctl launch <UDID> <bundle-id>\n"); return 1; }
            return cmd_launch([NSString stringWithUTF8String:argv[2]],
                             [NSString stringWithUTF8String:argv[3]]);
        }
        else if ([cmd isEqualToString:@"screenshot"]) {
            if (argc < 4) { fprintf(stderr, "Usage: rosettasim-ctl screenshot <UDID> <output.png>\n"); return 1; }
            return cmd_screenshot([NSString stringWithUTF8String:argv[2]],
                                 [NSString stringWithUTF8String:argv[3]]);
        }
        else if ([cmd isEqualToString:@"listapps"]) {
            if (argc < 3) { fprintf(stderr, "Usage: rosettasim-ctl listapps <UDID>\n"); return 1; }
            return cmd_listapps([NSString stringWithUTF8String:argv[2]]);
        }
        else if ([cmd isEqualToString:@"get_app_container"]) {
            if (argc < 4) { fprintf(stderr, "Usage: rosettasim-ctl get_app_container <UDID> <bundle-id> [app|data]\n"); return 1; }
            return cmd_get_app_container([NSString stringWithUTF8String:argv[2]],
                                        [NSString stringWithUTF8String:argv[3]],
                                        argc > 4 ? [NSString stringWithUTF8String:argv[4]] : nil);
        }
        else if ([cmd isEqualToString:@"uninstall"]) {
            if (argc < 4) { fprintf(stderr, "Usage: rosettasim-ctl uninstall <UDID> <bundle-id>\n"); return 1; }
            return cmd_uninstall([NSString stringWithUTF8String:argv[2]],
                                [NSString stringWithUTF8String:argv[3]]);
        }
        else if ([cmd isEqualToString:@"openurl"]) {
            if (argc < 4) { fprintf(stderr, "Usage: rosettasim-ctl openurl <UDID> <url>\n"); return 1; }
            return cmd_openurl(resolve_device_arg(argv[2]),
                              [NSString stringWithUTF8String:argv[3]]);
        }
        else if ([cmd isEqualToString:@"erase"]) {
            if (argc < 3) { fprintf(stderr, "Usage: rosettasim-ctl erase <UDID>\n"); return 1; }
            return cmd_erase([NSString stringWithUTF8String:argv[2]]);
        }
        else if ([cmd isEqualToString:@"spawn"]) {
            if (argc < 4) { fprintf(stderr, "Usage: rosettasim-ctl spawn <UDID> <binary> [args]\n"); return 1; }
            NSMutableArray *spawnArgs = [NSMutableArray new];
            for (int i = 3; i < argc; i++)
                [spawnArgs addObject:[NSString stringWithUTF8String:argv[i]]];
            return cmd_spawn(resolve_device_arg(argv[2]), spawnArgs);
        }
        else if ([cmd isEqualToString:@"create"]) {
            return passthrough_to_simctl(argc, argv);
        }
        else if ([cmd isEqualToString:@"delete"]) {
            return cmd_delete(argc, argv);
        }
        else if ([cmd isEqualToString:@"clone"]) {
            return passthrough_to_simctl(argc, argv);
        }
        else if ([cmd isEqualToString:@"rename"]) {
            return passthrough_to_simctl(argc, argv);
        }
        else if ([cmd isEqualToString:@"diagnose"]) {
            return passthrough_to_simctl(argc, argv);
        }
        else if ([cmd isEqualToString:@"appinfo"]) {
            if (argc < 4) { fprintf(stderr, "Usage: rosettasim-ctl appinfo <UDID> <bundle-id>\n"); return 1; }
            return cmd_appinfo(resolve_device_arg(argv[2]),
                              [NSString stringWithUTF8String:argv[3]]);
        }
        else if ([cmd isEqualToString:@"privacy"]) {
            if (argc < 5) { fprintf(stderr, "Usage: rosettasim-ctl privacy <UDID> <grant|revoke|reset> <service> [bundle-id]\n"); return 1; }
            return cmd_privacy(resolve_device_arg(argv[2]),
                              [NSString stringWithUTF8String:argv[3]],
                              [NSString stringWithUTF8String:argv[4]],
                              argc > 5 ? [NSString stringWithUTF8String:argv[5]] : nil);
        }
        else if ([cmd isEqualToString:@"getenv"]) {
            if (argc < 4) { fprintf(stderr, "Usage: rosettasim-ctl getenv <UDID> <variable>\n"); return 1; }
            return cmd_getenv(resolve_device_arg(argv[2]),
                             [NSString stringWithUTF8String:argv[3]]);
        }
        else if ([cmd isEqualToString:@"addmedia"]) {
            if (argc < 4) { fprintf(stderr, "Usage: rosettasim-ctl addmedia <UDID> <file> [file...]\n"); return 1; }
            NSMutableArray *files = [NSMutableArray new];
            for (int i = 3; i < argc; i++)
                [files addObject:[NSString stringWithUTF8String:argv[i]]];
            return cmd_addmedia(resolve_device_arg(argv[2]), files);
        }
        else if ([cmd isEqualToString:@"location"]) {
            if (argc < 4) { fprintf(stderr, "Usage: rosettasim-ctl location <UDID> set <lat>,<lon>\n"); return 1; }
            return cmd_location(resolve_device_arg(argv[2]), argc, argv);
        }
        else if ([cmd isEqualToString:@"push"]) {
            if (argc < 5) { fprintf(stderr, "Usage: rosettasim-ctl push <UDID> <bundle-id> <payload.json|->\n"); return 1; }
            return cmd_push(resolve_device_arg(argv[2]), argc, argv);
        }
        else if ([cmd isEqualToString:@"status_bar"]) {
            /* status_bar overrides require iOS 13+ UIStatusBar override API — genuinely unavailable */
            if (argc >= 3) {
                NSString *devUdid = resolve_device_arg(argv[2]);
                id ds = get_device_set();
                id dev = ds ? find_device(ds, devUdid) : nil;
                if (dev && is_legacy_runtime(get_runtime_id(dev))) {
                    fprintf(stderr, "status_bar overrides require iOS 13+ (UIStatusBar override API does not exist on legacy runtimes).\n");
                    return 1;
                }
            }
            return passthrough_to_simctl(argc, argv);
        }
        else if ([cmd isEqualToString:@"keychain"]) {
            if (argc < 4) { fprintf(stderr, "Usage: rosettasim-ctl keychain <UDID> <reset|add-root-cert|add-cert> [cert]\n"); return 1; }
            return cmd_keychain(resolve_device_arg(argv[2]), argc, argv);
        }
        else if ([cmd isEqualToString:@"pbcopy"]) {
            if (argc < 3) { fprintf(stderr, "Usage: echo text | rosettasim-ctl pbcopy <UDID>\n"); return 1; }
            return cmd_pbcopy(resolve_device_arg(argv[2]));
        }
        else if ([cmd isEqualToString:@"pbpaste"]) {
            if (argc < 3) { fprintf(stderr, "Usage: rosettasim-ctl pbpaste <UDID>\n"); return 1; }
            return cmd_pbpaste(resolve_device_arg(argv[2]));
        }
        else if ([cmd isEqualToString:@"pbsync"]) {
            /* pbsync syncs host↔device pasteboard — for legacy, same as pbpaste */
            if (argc < 3) return passthrough_to_simctl(argc, argv);
            NSString *devUdid = resolve_device_arg(argv[2]);
            id ds = get_device_set();
            id dev = ds ? find_device(ds, devUdid) : nil;
            if (dev && is_legacy_runtime(get_runtime_id(dev))) {
                fprintf(stderr, "pbsync: use pbcopy/pbpaste for legacy devices (no bidirectional sync).\n");
                return 1;
            }
            return passthrough_to_simctl(argc, argv);
        }
        else if ([cmd isEqualToString:@"ui"]) {
            if (argc < 5) { fprintf(stderr, "Usage: rosettasim-ctl ui <UDID> content_size <category>\n"); return 1; }
            return cmd_ui(resolve_device_arg(argv[2]), argc, argv);
        }
        else if ([cmd isEqualToString:@"touch"]) {
            if (argc < 5) { fprintf(stderr, "Usage: rosettasim-ctl touch <UDID> <x> <y> [--duration=<ms>]\n"); return 1; }
            float x = atof(argv[3]);
            float y = atof(argv[4]);
            int duration = 100; /* default tap duration */
            for (int i = 5; i < argc; i++) {
                if (strncmp(argv[i], "--duration=", 11) == 0)
                    duration = atoi(argv[i] + 11);
            }
            return cmd_touch(resolve_device_arg(argv[2]), x, y, duration);
        }
        else if ([cmd isEqualToString:@"sendtext"]) {
            if (argc < 4) { fprintf(stderr, "Usage: rosettasim-ctl sendtext <UDID> <text>\n"); return 1; }
            return cmd_sendtext(resolve_device_arg(argv[2]),
                               [NSString stringWithUTF8String:argv[3]]);
        }
        else if ([cmd isEqualToString:@"keyevent"]) {
            if (argc < 5) { fprintf(stderr, "Usage: rosettasim-ctl keyevent <UDID> <usage-page> <usage>\n"); return 1; }
            return cmd_keyevent(resolve_device_arg(argv[2]),
                               (uint32_t)atoi(argv[3]), (uint32_t)atoi(argv[4]));
        }
        else if ([cmd isEqualToString:@"logverbose"]) {
            if (argc < 4) { fprintf(stderr, "Usage: rosettasim-ctl logverbose <UDID> <on|off>\n"); return 1; }
            return cmd_logverbose([NSString stringWithUTF8String:argv[2]],
                                 [NSString stringWithUTF8String:argv[3]]);
        }
        else if ([cmd isEqualToString:@"status"]) {
            if (argc < 3) { fprintf(stderr, "Usage: rosettasim-ctl status <UDID>\n"); return 1; }
            return cmd_status([NSString stringWithUTF8String:argv[2]]);
        }
        else if ([cmd isEqualToString:@"io"]) {
            /* Handle 'io <device> screenshot' for legacy, passthrough rest */
            if (argc >= 4 && strcmp(argv[3], "screenshot") == 0) {
                NSString *udid = resolve_device_arg(argv[2]);
                id deviceSet = get_device_set();
                id device = deviceSet ? find_device(deviceSet, udid) : nil;
                if (device && is_legacy_runtime(get_runtime_id(device))) {
                    NSString *output = argc >= 5 ? [NSString stringWithUTF8String:argv[4]] : @"screenshot.png";
                    return cmd_screenshot(udid, output);
                }
            }
            return passthrough_to_simctl(argc, argv);
        }
        else if ([cmd isEqualToString:@"terminate"]) {
            if (argc < 4) { fprintf(stderr, "Usage: rosettasim-ctl terminate <UDID> <bundle-id>\n"); return 1; }
            return cmd_terminate(resolve_device_arg(argv[2]),
                                [NSString stringWithUTF8String:argv[3]]);
        }
        else if ([cmd isEqualToString:@"help"]) {
            if (argc >= 3) {
                /* Forward to simctl help for subcommand help */
                return passthrough_to_simctl(argc, argv);
            }
            usage();
            return 0;
        }
        else {
            /* Unknown command — passthrough to real simctl */
            return passthrough_to_simctl(argc, argv);
        }
    }
}
