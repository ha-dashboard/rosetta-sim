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
#include <spawn.h>
#include <sys/wait.h>

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

    /* Write pending install entry for sim_app_installer.dylib to pick up.
     * The dylib runs inside SpringBoard and calls MobileInstallationInstallForLaunchServices(). */
    printf("  Writing pending install for sim_app_installer...\n");

    NSString *pendingPath = @"/tmp/rosettasim_pending_installs.json";
    NSMutableArray *pendingArray = [NSMutableArray new];

    /* Read existing pending installs if any */
    NSData *existingData = [NSData dataWithContentsOfFile:pendingPath];
    if (existingData) {
        NSArray *existing = [NSJSONSerialization JSONObjectWithData:existingData options:0 error:nil];
        if ([existing isKindOfClass:[NSArray class]])
            [pendingArray addObjectsFromArray:existing];
    }

    /* Add new entry */
    [pendingArray addObject:@{
        @"path": destApp,
        @"bundle_id": bundleID,
    }];

    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:pendingArray
                                                       options:NSJSONWritingPrettyPrinted error:nil];
    [jsonData writeToFile:pendingPath atomically:YES];

    /* Check if sim_app_installer.dylib is deployed */
    NSString *installerDylib = [NSString stringWithFormat:
        @"%@/usr/local/lib/sim_app_installer.dylib", deviceDataPath];
    BOOL installerDeployed = [[NSFileManager defaultManager] fileExistsAtPath:installerDylib];

    printf("  Pending install written to %s\n", pendingPath.UTF8String);

    if (installerDeployed) {
        printf("  sim_app_installer.dylib is deployed. Reboot device to register:\n");
    } else {
        printf("  NOTE: sim_app_installer.dylib not deployed to this device.\n");
        printf("  Deploy it first, then reboot:\n");
        printf("    mkdir -p %s/usr/local/lib\n", deviceDataPath.UTF8String);
        printf("    cp build/sim_app_installer.dylib %s/usr/local/lib/\n", deviceDataPath.UTF8String);
    }
    printf("    rosettasim-ctl shutdown %s\n", udid.UTF8String);
    printf("    rosettasim-ctl boot %s\n", udid.UTF8String);

    printf("Installed %s (%s) — pending registration on next boot\n",
           bundleID.UTF8String, appName.UTF8String);
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

    /* Write pending launch file for sim_app_installer.dylib to pick up on boot */
    printf("  App found at: %s\n", appPath.UTF8String);
    printf("  Writing pending launch...\n");

    FILE *f = fopen("/tmp/rosettasim_pending_launch.txt", "w");
    if (f) {
        fprintf(f, "%s\n", bundleID.UTF8String);
        fclose(f);
    } else {
        fprintf(stderr, "Failed to write pending launch file.\n");
        return 1;
    }

    /* Reboot device to trigger SpringBoard → installer dylib → launch */
    printf("  Rebooting device to trigger launch...\n");
    int rc = run_with_timeout(@[@"xcrun", @"simctl", @"shutdown", udid], 15);
    if (rc == 124) {
        /* Timeout — force kill */
        NSString *killCmd = [NSString stringWithFormat:
            @"pgrep -f 'launchd_sim.*%@' | xargs kill 2>/dev/null", udid];
        system(killCmd.UTF8String);
        sleep(2);
    } else {
        sleep(3);
    }

    rc = run_with_timeout(@[@"xcrun", @"simctl", @"boot", udid], 45);
    if (rc != 0 && rc != 124) {
        fprintf(stderr, "Boot failed (exit %d). Launch may still work if daemon reboots.\n", rc);
    }

    printf("  Waiting for SpringBoard to launch app...\n");
    sleep(15);

    /* Check result */
    NSString *resultStr = [NSString stringWithContentsOfFile:@"/tmp/rosettasim_install_result.txt"
                                                   encoding:NSUTF8StringEncoding error:nil];
    if (resultStr && [resultStr containsString:bundleID]) {
        printf("Launch triggered for %s\n", bundleID.UTF8String);
    } else {
        printf("Launch requested. App should appear after SpringBoard finishes loading.\n");
        printf("If it doesn't appear, tap its icon on the home screen.\n");
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

    /* Legacy: read from LastLaunchServicesMap.plist */
    NSDictionary *lsMap = read_ls_map(udid);
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

    /* Legacy: simctl openurl hangs. Write pending action for installer dylib. */
    printf("openurl not directly supported on legacy simulators.\n");
    printf("URL: %s\n", url.UTF8String);
    printf("Use Safari on the home screen to navigate to this URL.\n");
    return 1;
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

    NSString *rtID = get_runtime_id(device);
    BOOL legacy = is_legacy_runtime(rtID);

    if (!legacy) {
        NSMutableArray *args = [@[@"xcrun", @"simctl", @"spawn", udid] mutableCopy];
        [args addObjectsFromArray:spawnArgs];
        return run_with_timeout(args, 30);
    }

    fprintf(stderr, "spawn is not supported on legacy simulators.\n");
    fprintf(stderr, "CoreSimulator cannot communicate with legacy launchd_sim.\n");
    fprintf(stderr, "Workaround: inject code via sim_app_installer.dylib constructor.\n");
    return 1;
}

/* ── Command: logverbose ── */

static int cmd_logverbose(NSString *udid, NSString *enabled) {
    return run_with_timeout(@[@"xcrun", @"simctl", @"logverbose", udid, enabled], 10);
}

/* ── Usage ── */

static void usage(void) {
    /* Match simctl's help format for drop-in compatibility */
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
        "\tboot                Boot a device or device pair.\n"
        "\tcreate              Create a new device.\n"
        "\tdelete              Delete specified devices, unavailable devices, or all devices.\n"
        "\terase               Erase a device's contents and settings.\n"
        "\tget_app_container   Print the path of the installed app's container\n"
        "\tgetenv              Print an environment variable from a running device.\n"
        "\thelp                Prints the usage for a given subcommand.\n"
        "\tinstall             Install an app on a device.\n"
        "\tio                  Set up a device IO operation.\n"
        "\tlaunch              Launch an application by identifier on a device.\n"
        "\tlist                List available devices, device types, runtimes, or device pairs.\n"
        "\tlistapps            Show the installed applications.\n"
        "\tlogverbose          enable or disable verbose logging for a device\n"
        "\topenurl             Open a URL in a device.\n"
        "\tshutdown            Shutdown a device.\n"
        "\tspawn               Spawn a process by executing a given executable on a device.\n"
        "\tstatus              Show device status (rosettasim extension).\n"
        "\tterminate           Terminate an application by identifier on a device.\n"
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
            return cmd_openurl([NSString stringWithUTF8String:argv[2]],
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
            return cmd_spawn([NSString stringWithUTF8String:argv[2]], spawnArgs);
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
            /* For legacy: kill the app process directly */
            if (argc >= 4) {
                NSString *udid = resolve_device_arg(argv[2]);
                id deviceSet = get_device_set();
                id device = deviceSet ? find_device(deviceSet, udid) : nil;
                if (device && is_legacy_runtime(get_runtime_id(device))) {
                    /* Can't terminate via simctl on legacy — just report */
                    fprintf(stderr, "terminate not supported on legacy simulators.\n");
                    return 1;
                }
            }
            return passthrough_to_simctl(argc, argv);
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
