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

static int cmd_list(void) {
    id deviceSet = get_device_set();
    if (!deviceSet) return 1;

    NSDictionary *devices = ((id(*)(id, SEL))objc_msgSend)(deviceSet, sel_registerName("devicesByUDID"));
    /* Group by runtime */
    NSMutableDictionary<NSString *, NSMutableArray *> *byRuntime = [NSMutableDictionary new];
    for (NSUUID *uuid in devices) {
        id dev = devices[uuid];
        NSString *rtID = get_runtime_id(dev);
        if (!rtID) rtID = @"Unknown";
        if (!byRuntime[rtID]) byRuntime[rtID] = [NSMutableArray new];
        [byRuntime[rtID] addObject:dev];
    }

    for (NSString *rtID in [[byRuntime allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
        BOOL legacy = is_legacy_runtime(rtID);
        printf("-- %s%s --\n", rtID.UTF8String, legacy ? " [legacy]" : "");
        for (id dev in byRuntime[rtID]) {
            NSString *name = get_device_name(dev);
            NSUUID *udid = ((id(*)(id, SEL))objc_msgSend)(dev, sel_registerName("UDID"));
            long state = get_device_state(dev);
            printf("    %s (%s) (%s)\n",
                   name.UTF8String, udid.UUIDString.UTF8String,
                   state_string(state).UTF8String);
        }
    }
    return 0;
}

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

    /* Trigger SpringBoard re-scan via darwin notification */
    printf("  Triggering app discovery...\n");

    /* Try notifyutil in the sim */
    int rc = run_with_timeout(@[@"xcrun", @"simctl", @"spawn", udid,
        @"/usr/bin/notifyutil", @"-p", @"com.apple.mobile.installd.app_changed"], 10);

    if (rc != 0) {
        /* Fallback: try direct notify_post from host (crosses into sim via launchd) */
        printf("  notifyutil failed (rc=%d), trying alternative...\n", rc);

        /* Try touching the install sentinel */
        NSString *sentinel = [NSString stringWithFormat:
            @"%@/Library/Caches/com.apple.mobile.installd.staging/", deviceDataPath];
        [[NSFileManager defaultManager] createDirectoryAtPath:sentinel
                                  withIntermediateDirectories:YES
                                                   attributes:nil error:nil];

        /* Also try simctl spawn with full paths */
        rc = run_with_timeout(@[@"xcrun", @"simctl", @"spawn", udid,
            @"/usr/bin/killall", @"-HUP", @"SpringBoard"], 10);
        if (rc == 0) {
            printf("  Sent HUP to SpringBoard to trigger re-scan.\n");
        } else {
            printf("  Warning: Could not trigger app discovery automatically.\n");
            printf("  The app has been copied. Reboot the device to pick it up:\n");
            printf("    rosettasim-ctl shutdown %s && rosettasim-ctl boot %s\n",
                   udid.UTF8String, udid.UTF8String);
        }
    }

    printf("Installed %s (%s)\n", bundleID.UTF8String, appName.UTF8String);
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

    NSString *execPath = [appPath stringByAppendingPathComponent:execName];

    /* Try simctl spawn with the executable path */
    printf("  Spawning %s...\n", execPath.UTF8String);
    int rc = run_with_timeout(@[@"xcrun", @"simctl", @"spawn", udid, execPath], 15);
    if (rc == 124) {
        /* simctl spawn timed out — try openurl scheme instead */
        fprintf(stderr, "  spawn timed out. Trying openurl fallback...\n");

        /* Try simctl openurl if the app has a URL scheme */
        NSArray *urlTypes = info[@"CFBundleURLTypes"];
        if ([urlTypes isKindOfClass:[NSArray class]] && urlTypes.count > 0) {
            NSDictionary *urlType = urlTypes[0];
            NSArray *schemes = urlType[@"CFBundleURLSchemes"];
            if ([schemes isKindOfClass:[NSArray class]] && schemes.count > 0) {
                NSString *scheme = schemes[0];
                NSString *url = [NSString stringWithFormat:@"%@://", scheme];
                rc = run_with_timeout(@[@"xcrun", @"simctl", @"openurl", udid, url], 10);
                if (rc == 0) {
                    printf("Launched %s via URL scheme %s://\n", bundleID.UTF8String, scheme.UTF8String);
                    return 0;
                }
            }
        }

        fprintf(stderr, "  Could not launch app automatically.\n");
        fprintf(stderr, "  The app is installed — tap its icon on the home screen.\n");
        return 1;
    }

    if (rc != 0) {
        fprintf(stderr, "Launch failed (exit %d).\n", rc);
        return rc;
    }

    printf("Launched %s\n", bundleID.UTF8String);
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

/* ── Usage ── */

static void usage(void) {
    fprintf(stderr,
        "Usage: rosettasim-ctl <command> [arguments]\n"
        "\n"
        "Commands:\n"
        "  list                          List all devices with status\n"
        "  boot <UDID>                   Boot device\n"
        "  shutdown <UDID|all>           Shutdown device(s)\n"
        "  install <UDID> <app-path>     Install .app on device\n"
        "  launch <UDID> <bundle-id>     Launch app by bundle ID\n"
        "  screenshot <UDID> <output>    Take screenshot\n"
        "  status <UDID>                 Show device status\n"
        "\n"
        "Legacy runtimes (iOS 7-14.x) are handled directly.\n"
        "Native runtimes delegate to xcrun simctl.\n"
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
            return cmd_list();
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
        else if ([cmd isEqualToString:@"status"]) {
            if (argc < 3) { fprintf(stderr, "Usage: rosettasim-ctl status <UDID>\n"); return 1; }
            return cmd_status([NSString stringWithUTF8String:argv[2]]);
        }
        else {
            fprintf(stderr, "Unknown command: %s\n", cmd.UTF8String);
            usage();
            return 1;
        }
    }
}
