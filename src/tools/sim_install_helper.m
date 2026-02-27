/*
 * sim_install_helper.m — x86_64 binary that runs INSIDE the iOS simulator
 *
 * Calls MobileInstallationInstallForLaunchServices() to register an app
 * with installd, making it appear on SpringBoard.
 *
 * Build: (for x86_64 iOS simulator target)
 *   make install_helper
 *
 * Deploy to device:
 *   cp build/sim_install_helper ~/Library/Developer/CoreSimulator/Devices/<UDID>/data/usr/local/bin/
 *
 * Usage (inside sim, or via daemon):
 *   sim_install_helper /path/to/App.app
 *   sim_install_helper --uninstall com.example.app
 *   sim_install_helper --list
 */

#import <Foundation/Foundation.h>
#import <dlfcn.h>

/* MobileInstallation private API */
typedef void (^MIProgressCallback)(NSDictionary *info);
typedef void (^MIStatusCallback)(NSDictionary *info, NSError *error);

static void *g_mi_handle = NULL;

static void *load_mi(void) {
    if (!g_mi_handle) {
        g_mi_handle = dlopen("/System/Library/PrivateFrameworks/MobileInstallation.framework/MobileInstallation", RTLD_NOW);
        if (!g_mi_handle) {
            fprintf(stderr, "Failed to load MobileInstallation.framework: %s\n", dlerror());
        }
    }
    return g_mi_handle;
}

static int do_install(const char *appPath) {
    void *handle = load_mi();
    if (!handle) return 1;

    /* MobileInstallationInstallForLaunchServices(NSString *path, NSDictionary *options,
     *     MIStatusCallback statusCallback, MIProgressCallback progressCallback) → int */
    typedef int (*MIInstallForLS)(id, id, id, id);
    MIInstallForLS installFn = (MIInstallForLS)dlsym(handle, "MobileInstallationInstallForLaunchServices");
    if (!installFn) {
        fprintf(stderr, "MobileInstallationInstallForLaunchServices not found\n");
        return 1;
    }

    NSString *path = [NSString stringWithUTF8String:appPath];

    /* Verify the app exists */
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        fprintf(stderr, "App not found: %s\n", appPath);
        return 1;
    }

    /* Read bundle ID for logging */
    NSString *infoPlistPath = [path stringByAppendingPathComponent:@"Info.plist"];
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:infoPlistPath];
    NSString *bundleID = info[@"CFBundleIdentifier"] ?: @"unknown";

    printf("Installing %s from %s...\n", bundleID.UTF8String, appPath);

    NSDictionary *options = @{
        @"ApplicationType": @"User",
    };

    __block BOOL gotCallback = NO;
    MIStatusCallback statusCB = ^(NSDictionary *cbInfo, NSError *error) {
        gotCallback = YES;
        if (error) {
            fprintf(stderr, "Install callback error: %s\n", error.localizedDescription.UTF8String);
        } else {
            printf("Install callback: %s\n", cbInfo.description.UTF8String);
        }
    };

    int result = installFn(path, options, statusCB, nil);
    printf("MobileInstallationInstallForLaunchServices returned: %d\n", result);

    if (result == 0) {
        printf("Successfully installed %s\n", bundleID.UTF8String);
    } else {
        fprintf(stderr, "Install failed with code %d\n", result);
    }

    return result;
}

static int do_uninstall(const char *bundleID) {
    void *handle = load_mi();
    if (!handle) return 1;

    typedef int (*MIUninstallForLS)(id, id, id, id);
    MIUninstallForLS uninstallFn = (MIUninstallForLS)dlsym(handle, "MobileInstallationUninstallForLaunchServices");
    if (!uninstallFn) {
        fprintf(stderr, "MobileInstallationUninstallForLaunchServices not found\n");
        return 1;
    }

    NSString *bid = [NSString stringWithUTF8String:bundleID];
    printf("Uninstalling %s...\n", bundleID);

    int result = uninstallFn(bid, nil, nil, nil);
    printf("Uninstall result: %d\n", result);
    return result;
}

static int do_list(void) {
    void *handle = load_mi();
    if (!handle) return 1;

    typedef id (*MICopyInstalled)(id);
    MICopyInstalled copyFn = (MICopyInstalled)dlsym(handle, "MobileInstallationCopyInstalledAppsForLaunchServices");
    if (!copyFn) {
        fprintf(stderr, "MobileInstallationCopyInstalledAppsForLaunchServices not found\n");
        return 1;
    }

    NSDictionary *apps = copyFn(nil);
    if (!apps) {
        printf("No apps returned (nil)\n");
        return 0;
    }

    printf("Installed apps (%lu):\n", (unsigned long)apps.count);
    for (NSString *bundleID in [apps.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        NSDictionary *info = apps[bundleID];
        NSString *path = info[@"Path"] ?: @"<no path>";
        NSString *type = info[@"ApplicationType"] ?: @"<unknown>";
        printf("  [%s] %s\n    %s\n", type.UTF8String, bundleID.UTF8String, path.UTF8String);
    }
    return 0;
}

static void usage(void) {
    fprintf(stderr,
        "Usage:\n"
        "  sim_install_helper /path/to/App.app     Install an app\n"
        "  sim_install_helper --uninstall <bundleID>  Uninstall an app\n"
        "  sim_install_helper --list                List installed apps\n"
    );
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 2) { usage(); return 1; }

        if (strcmp(argv[1], "--list") == 0) {
            return do_list();
        }
        if (strcmp(argv[1], "--uninstall") == 0) {
            if (argc < 3) { fprintf(stderr, "Usage: sim_install_helper --uninstall <bundleID>\n"); return 1; }
            return do_uninstall(argv[2]);
        }
        return do_install(argv[1]);
    }
}
