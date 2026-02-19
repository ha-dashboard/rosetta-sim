// DVT Plugin System Hook v3 - Full pipeline tracing
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <stdio.h>

static void dumpExtensionPoints(void);

static IMP orig_checkPresence = NULL;
static IMP orig_validatePlatform = NULL;
static IMP orig_extendedPlatformInfo = NULL;
static IMP orig_applyActivation = NULL;
static IMP orig_scanRecords = NULL;
static IMP orig_createFromScan = NULL;
static IMP orig_createFromCache = NULL;
static IMP orig_prune = NULL;
static IMP orig_cacheCovers = NULL;
static IMP orig_register = NULL;
static IMP orig_useCache = NULL;

static BOOL hooked_checkPresence(id self, SEL _cmd, id req, NSError **err) {
    fprintf(stderr, "[dvt] _checkPresence: %lu plugins\n", (unsigned long)[req count]);
    BOOL result = ((BOOL(*)(id, SEL, id, NSError **))orig_checkPresence)(self, _cmd, req, err);
    if (!result) {
        fprintf(stderr, "[dvt] OVERRIDE _checkPresence -> YES\n");
        if (err) *err = nil;
        return YES;
    }
    return result;
}

static void hooked_applyActivation(id self, SEL _cmd, id records) {
    fprintf(stderr, "[dvt] _applyActivation: BYPASSED (keeping all %lu records)\n",
            (unsigned long)[records count]);
    // Don't call original - it filters out platform support plugins
    // that require "build-system" capability (chicken-and-egg problem)
}

// Hook: defaultSearchPaths
static IMP orig_defaultSearchPaths = NULL;
static id hooked_defaultSearchPaths(id self, SEL _cmd) {
    id result = ((id(*)(id, SEL))orig_defaultSearchPaths)(self, _cmd);
    fprintf(stderr, "[dvt] defaultSearchPaths: %lu paths\n", (unsigned long)[result count]);
    for (NSString *p in result) {
        fprintf(stderr, "[dvt]   path: %s\n", [p UTF8String]);
    }
    return result;
}

// Hook: _scanForPlugInsInDirectories:skippingDuplicatesOfPlugIns:
static IMP orig_scanDirs = NULL;
static id hooked_scanDirs(id self, SEL _cmd, id dirs, id skipDups) {
    fprintf(stderr, "[dvt] _scanForPlugInsInDirs: %lu dirs\n", (unsigned long)[dirs count]);
    for (NSString *d in dirs) {
        fprintf(stderr, "[dvt]   dir: %s\n", [d UTF8String]);
    }
    id result = ((id(*)(id, SEL, id, id))orig_scanDirs)(self, _cmd, dirs, skipDups);
    fprintf(stderr, "[dvt] _scanForPlugInsInDirs: found %lu records\n", (unsigned long)[result count]);
    return result;
}

// Helper: get cached bundle info dictionary for a scan record
static NSDictionary *getBundleInfo(id record) {
    SEL bpSel = NSSelectorFromString(@"bundlePath");
    NSString *bp = [record respondsToSelector:bpSel] ? [record performSelector:bpSel] : nil;
    if (!bp) {
        SEL pathSel = NSSelectorFromString(@"path");
        bp = [record respondsToSelector:pathSel] ? [record performSelector:pathSel] : nil;
    }
    if (bp) {
        NSBundle *bundle = [NSBundle bundleWithPath:bp];
        if (bundle) return [bundle infoDictionary];
    }
    return nil;
}

static void setIvarIfNil(id obj, const char *ivarName, id value) {
    Ivar ivar = class_getInstanceVariable([obj class], ivarName);
    if (ivar && !object_getIvar(obj, ivar) && value) {
        object_setIvar(obj, ivar, value);
    }
}

// Hook: -[DVTPlugInScanRecord identifier]
static IMP orig_scanRecordIdentifier = NULL;
static id hooked_scanRecordIdentifier(id self, SEL _cmd) {
    id result = ((id(*)(id, SEL))orig_scanRecordIdentifier)(self, _cmd);
    if (!result) {
        NSDictionary *info = getBundleInfo(self);
        result = [info objectForKey:@"CFBundleIdentifier"];
        if (result) setIvarIfNil(self, "_identifier", result);
    }
    return result;
}

// Hook: -[DVTPlugInScanRecord plugInCompatibilityUUIDs]
static IMP orig_scanRecordUUIDs = NULL;
static id hooked_scanRecordUUIDs(id self, SEL _cmd) {
    id result = ((id(*)(id, SEL))orig_scanRecordUUIDs)(self, _cmd);
    if (!result || [result count] == 0) {
        NSDictionary *info = getBundleInfo(self);
        result = [info objectForKey:@"DVTPlugInCompatibilityUUIDs"];
        if (result) setIvarIfNil(self, "_plugInCompatibilityUUIDs", result);
    }
    return result;
}

// Hook: -[DVTPlugInScanRecord isApplePlugIn]
static IMP orig_scanRecordIsApple = NULL;
static BOOL hooked_scanRecordIsApple(id self, SEL _cmd) {
    // All Xcode 8.3.3 plugins are Apple plugins
    return YES;
}

// Hook: -[DVTPlugInScanRecord marketingVersion]
static IMP orig_scanRecordVersion = NULL;
static id hooked_scanRecordVersion(id self, SEL _cmd) {
    id result = ((id(*)(id, SEL))orig_scanRecordVersion)(self, _cmd);
    if (!result) {
        NSDictionary *info = getBundleInfo(self);
        result = [info objectForKey:@"CFBundleShortVersionString"];
        if (result) setIvarIfNil(self, "_marketingVersion", result);
    }
    return result;
}

// Hook: -[DVTPlugInScanRecord plugInPlist] - force lazy loading of xcplugindata
static IMP orig_scanRecordPlugInPlist = NULL;
static int plugInPlistCallCount = 0;
static int plugInPlistLoadedCount = 0;
static id hooked_scanRecordPlugInPlist(id self, SEL _cmd) {
    plugInPlistCallCount++;
    id result = ((id(*)(id, SEL))orig_scanRecordPlugInPlist)(self, _cmd);
    // Log plugin records specifically
    @try {
        NSString *recPath = [self performSelector:NSSelectorFromString(@"path")];
        if ([recPath hasSuffix:@".ideplugin"] || [recPath hasSuffix:@".dvtplugin"]) {
            static int plc = 0;
            if (plc < 3) {
                plc++;
                NSString *nm = [recPath lastPathComponent];
                fprintf(stderr, "[dvt] PLUGIN plist: %s -> %s (keys=%lu)\n",
                        [nm UTF8String],
                        result ? [NSStringFromClass([result class]) UTF8String] : "nil",
                        (result && [result respondsToSelector:@selector(count)])
                            ? (unsigned long)[(NSDictionary*)result count] : 0UL);
                if (result && [result isKindOfClass:[NSDictionary class]]) {
                    id pluginDict = [(NSDictionary*)result objectForKey:@"plug-in"];
                    fprintf(stderr, "[dvt]   plug-in key: %s\n",
                            pluginDict ? "present" : "MISSING");
                }
            }
        }
    } @catch(NSException *e) {}
    if (!result) {
        // Check if bundle exists
        SEL bundleSel = NSSelectorFromString(@"bundle");
        SEL bpSel = NSSelectorFromString(@"bundlePath");
        id bundle = [self respondsToSelector:bundleSel] ? [self performSelector:bundleSel] : nil;
        NSString *bp = [self respondsToSelector:bpSel] ? [self performSelector:bpSel] : nil;

        if (plugInPlistCallCount <= 3) {
            fprintf(stderr, "[dvt] plugInPlist: bundle=%s bundlePath=%s\n",
                    bundle ? "yes" : "nil",
                    bp ? [[bp lastPathComponent] UTF8String] : "nil");
        }

        // Try _instantiateBundleIfNecessary first
        SEL instantiateSel = NSSelectorFromString(@"_instantiateBundleIfNecessary");
        if (!bundle && [self respondsToSelector:instantiateSel]) {
            [self performSelector:instantiateSel];
            bundle = [self performSelector:bundleSel];
            if (plugInPlistCallCount <= 3) {
                fprintf(stderr, "[dvt] plugInPlist: after instantiate, bundle=%s\n",
                        bundle ? "yes" : "nil");
            }
        }

        SEL loadSel = NSSelectorFromString(@"loadPlugInPlist:");
        if ([self respondsToSelector:loadSel]) {
            NSError *err = nil;
            BOOL ok = ((BOOL(*)(id, SEL, NSError **))objc_msgSend)(self, loadSel, &err);
            result = ((id(*)(id, SEL))orig_scanRecordPlugInPlist)(self, _cmd);
            if (result) plugInPlistLoadedCount++;
            if (plugInPlistCallCount <= 3) {
                fprintf(stderr, "[dvt] plugInPlist: loadPlugInPlist=%s result=%s err=%s\n",
                        ok ? "YES" : "NO",
                        result ? "yes" : "nil",
                        err ? [[err localizedDescription] UTF8String] : "nil");
            }
        }
    }
    if (plugInPlistCallCount == 200 || plugInPlistCallCount == 500) {
        fprintf(stderr, "[dvt] plugInPlist: %d calls, %d loaded so far\n",
                plugInPlistCallCount, plugInPlistLoadedCount);
    }
    return result;
}

// Hook: -[DVTPlugInScanRecord bundleRawInfoPlist] - force lazy loading
static IMP orig_scanRecordRawPlist = NULL;
static id hooked_scanRecordRawPlist(id self, SEL _cmd) {
    id result = ((id(*)(id, SEL))orig_scanRecordRawPlist)(self, _cmd);
    if (!result) {
        SEL loadSel = NSSelectorFromString(@"_loadBundleRawInfoPlist:");
        if ([self respondsToSelector:loadSel]) {
            NSError *err = nil;
            ((BOOL(*)(id, SEL, NSError **))objc_msgSend)(self, loadSel, &err);
            result = ((id(*)(id, SEL))orig_scanRecordRawPlist)(self, _cmd);
        }
    }
    return result;
}

static id hooked_scanRecords(id self, SEL _cmd, BOOL isInitial, id *linkedFw) {
    id result = ((id(*)(id, SEL, BOOL, id *))orig_scanRecords)(self, _cmd, isInitial, linkedFw);
    fprintf(stderr, "[dvt] _scanRecords: %lu results, %lu linked fw\n",
            (unsigned long)[result count],
            (linkedFw && *linkedFw) ? (unsigned long)[*linkedFw count] : 0UL);
    return result;
}

static void hooked_createFromScan(id self, SEL _cmd, id records) {
    fprintf(stderr, "[dvt] _createFromScan: %lu records\n", (unsigned long)[records count]);
    ((void(*)(id, SEL, id))orig_createFromScan)(self, _cmd, records);
    fprintf(stderr, "[dvt] _createFromScan: done (plugInPlist: %d calls, %d loaded)\n",
            plugInPlistCallCount, plugInPlistLoadedCount);

    // Check plugInsByIdentifier on the manager
    @try {
        SEL piSel = NSSelectorFromString(@"_plugInsByIdentifier");
        if ([self respondsToSelector:piSel]) {
            NSDictionary *pbi = [self performSelector:piSel];
            fprintf(stderr, "[dvt] _plugInsByIdentifier: %lu plugins\n", (unsigned long)[pbi count]);
            int shown = 0;
            for (NSString *key in pbi) {
                if (shown < 5) {
                    fprintf(stderr, "[dvt]   %s\n", [key UTF8String]);
                    shown++;
                }
            }
        }
    } @catch(NSException *e) {
        fprintf(stderr, "[dvt] _plugInsByIdentifier: exception\n");
    }

    dumpExtensionPoints();
}

static void hooked_createFromCache(id self, SEL _cmd) {
    fprintf(stderr, "[dvt] _createFromCache\n");
    ((void(*)(id, SEL))orig_createFromCache)(self, _cmd);
    fprintf(stderr, "[dvt] _createFromCache: done\n");
}

// Hook: -[DVTPlugIn isLoadable]
static IMP orig_isLoadable = NULL;
static BOOL hooked_isLoadable(id self, SEL _cmd) {
    return YES; // Force all plugins to be loadable
}

static void hooked_prune(id self, SEL _cmd, id records, id fwPaths) {
    unsigned long before = [records count];
    fprintf(stderr, "[dvt] _prune: %lu records IN\n", before);

    // Classify records into framework and plugin types
    int fwCount = 0, pluginCount = 0, hasIdCount = 0, nullIdCount = 0;
    int pluginsDumped = 0;
    for (id record in records) {
        @try {
            SEL pathSel = NSSelectorFromString(@"path");
            SEL idSel = NSSelectorFromString(@"identifier");
            NSString *path = [record performSelector:pathSel];
            NSString *ident = [record performSelector:idSel];
            BOOL isPlugin = [path hasSuffix:@".ideplugin"] || [path hasSuffix:@".dvtplugin"];
            BOOL isFw = [path hasSuffix:@".framework"];

            if (isPlugin) pluginCount++;
            if (isFw) fwCount++;
            if (ident) hasIdCount++; else nullIdCount++;

            // Dump plugin record details
            if (isPlugin && pluginsDumped < 3) {
                SEL uuidSel = NSSelectorFromString(@"plugInCompatibilityUUIDs");
                SEL minSel = NSSelectorFromString(@"minimumRequiredSystemVersion");
                SEL maxSel = NSSelectorFromString(@"maximumAllowedSystemVersion");
                id uuids = [record performSelector:uuidSel];
                NSString *minV = [record performSelector:minSel];
                NSString *maxV = [record performSelector:maxSel];
                fprintf(stderr, "[dvt]   PLUGIN: %s\n", [[path lastPathComponent] UTF8String]);
                fprintf(stderr, "[dvt]     id=%s uuids=%lu min=%s max=%s\n",
                        ident ? [ident UTF8String] : "NIL",
                        uuids ? (unsigned long)[uuids count] : 0UL,
                        minV ? [minV UTF8String] : "nil",
                        maxV ? [maxV UTF8String] : "nil");
                pluginsDumped++;
            }
        } @catch (NSException *e) {}
    }
    fprintf(stderr, "[dvt]   %d plugins, %d frameworks | %d with id, %d null id\n",
            pluginCount, fwCount, hasIdCount, nullIdCount);

    // Strategy: let the prune run its full logic (which may set up extension points
    // as a side effect), then RESTORE all removed records afterward.
    NSArray *backup = [records copy];
    fprintf(stderr, "[dvt] _prune: calling original (backed up %lu records)\n", before);

    ((void(*)(id, SEL, id, id))orig_prune)(self, _cmd, records, fwPaths);

    unsigned long after = [records count];
    fprintf(stderr, "[dvt] _prune: original removed %lu records\n", before - after);

    // Restore removed records
    if (after < before) {
        NSMutableArray *mutableRecords = (NSMutableArray *)records;
        for (id record in backup) {
            if (![mutableRecords containsObject:record]) {
                [mutableRecords addObject:record];
            }
        }
        fprintf(stderr, "[dvt] _prune: RESTORED to %lu records\n", (unsigned long)[records count]);
    }

    // Dump extension points to see if prune registered any
    dumpExtensionPoints();
}

static BOOL hooked_cacheCovers(id self, SEL _cmd, id records) {
    BOOL result = ((BOOL(*)(id, SEL, id))orig_cacheCovers)(self, _cmd, records);
    fprintf(stderr, "[dvt] _cacheCovers: %d\n", result);
    return result;
}

static void hooked_register(id self, SEL _cmd, id records) {
    fprintf(stderr, "[dvt] _register: %lu records\n", (unsigned long)[records count]);
    ((void(*)(id, SEL, id))orig_register)(self, _cmd, records);
}

static BOOL hooked_useCache(id self, SEL _cmd) {
    BOOL result = ((BOOL(*)(id, SEL))orig_useCache)(self, _cmd);
    fprintf(stderr, "[dvt] useCache: %d\n", result);
    return result;
}

// Hook: -[DVTPlugInManager extensionPointWithIdentifier:]
static IMP orig_epLookup = NULL;
static int epLookupMissCount = 0;
static id hooked_epLookup(id self, SEL _cmd, id identifier) {
    id result = ((id(*)(id, SEL, id))orig_epLookup)(self, _cmd, identifier);
    if (!result && epLookupMissCount < 20) {
        fprintf(stderr, "[dvt] extensionPoint:%s -> NIL\n", [identifier UTF8String]);
        epLookupMissCount++;
    }
    return result;
}

static void dumpExtensionPoints(void) {
    fprintf(stderr, "[dvt] === DUMP STATE ===\n");
    @try {
        Class mgrCls = NSClassFromString(@"DVTPlugInManager");
        id mgr = [mgrCls performSelector:NSSelectorFromString(@"defaultPlugInManager")];

        // Access ivars directly
        Ivar piIvar = class_getInstanceVariable(mgrCls, "_plugInsByIdentifier");
        Ivar epIvar = class_getInstanceVariable(mgrCls, "_extensionPointsByIdentifier");
        Ivar exIvar = class_getInstanceVariable(mgrCls, "_extensionsByIdentifier");

        id pbi = piIvar ? object_getIvar(mgr, piIvar) : nil;
        id epi = epIvar ? object_getIvar(mgr, epIvar) : nil;
        id exi = exIvar ? object_getIvar(mgr, exIvar) : nil;

        fprintf(stderr, "[dvt] _plugInsByIdentifier: %lu\n",
                pbi ? (unsigned long)[pbi count] : 0UL);
        fprintf(stderr, "[dvt] _extensionPointsByIdentifier: %lu\n",
                epi ? (unsigned long)[epi count] : 0UL);
        fprintf(stderr, "[dvt] _extensionsByIdentifier: %lu\n",
                exi ? (unsigned long)[exi count] : 0UL);

        // Show first few plugin IDs
        if (pbi && [pbi count] > 0) {
            int shown = 0;
            for (NSString *key in pbi) {
                if (shown++ < 3) fprintf(stderr, "[dvt]   plugin: %s\n", [key UTF8String]);
            }
        }
        if (epi && [epi count] > 0) {
            int shown = 0;
            for (NSString *key in epi) {
                // Show platform-related EPs and first few others
                if ([key containsString:@"Platform"] || [key containsString:@"Extended"] ||
                    [key containsString:@"Device"] || shown < 3) {
                    fprintf(stderr, "[dvt]   EP: %s\n", [key UTF8String]);
                }
                shown++;
            }
            // Specifically check for the one we need
            BOOL hasEPI = [epi objectForKey:@"Xcode.DVTFoundation.ExtendedPlatformInfo"] != nil;
            fprintf(stderr, "[dvt]   HAS Xcode.DVTFoundation.ExtendedPlatformInfo: %s\n",
                    hasEPI ? "YES" : "NO");
        }
    } @catch (NSException *e) {
        fprintf(stderr, "[dvt] dump exception: %s\n", [[e reason] UTF8String]);
    }
}

// Hook: +[DVTPlatform validatePlatformDataReturningError:]
// This is the class method that triggers the "Required content for platform X is missing" dialog
static BOOL hooked_validatePlatform(id self, SEL _cmd, NSError **err) {
    fprintf(stderr, "[dvt] +[DVTPlatform validatePlatformDataReturningError:] -> BYPASSED (returning YES)\n");
    // Skip validation entirely - the platforms are intact, it's the extension point
    // registration that's broken
    return YES;
}

// Instead of hooking the assertion handler (complex va_list ABI issues),
// add the missing private methods that IB/DVT try to swizzle.
// This prevents the assertion from firing in the first place.

static void compat_noop(id self, SEL _cmd, ...) {
    // No-op stub for removed private methods
}

static void addMissingMethods(void) {
    fprintf(stderr, "[dvt] Adding missing private method stubs...\n");

    // _addHeartBeatClientView: was removed from NSView/NSWindow in modern AppKit
    // IB tries to swizzle it and crashes when it's not found
    struct { const char *cls; const char *sel; const char *types; } stubs[] = {
        {"NSView", "_addHeartBeatClientView:", "v@:@"},
        {"NSView", "_removeHeartBeatClientView:", "v@:@"},
        {"NSWindow", "_addHeartBeatClientView:", "v@:@"},
        {"NSWindow", "_removeHeartBeatClientView:", "v@:@"},
        {NULL, NULL, NULL}
    };

    for (int i = 0; stubs[i].cls; i++) {
        Class cls = objc_getClass(stubs[i].cls);
        SEL sel = sel_registerName(stubs[i].sel);
        if (cls && !class_getInstanceMethod(cls, sel)) {
            class_addMethod(cls, sel, (IMP)compat_noop, stubs[i].types);
            fprintf(stderr, "[dvt]   Added stub: -[%s %s]\n", stubs[i].cls, stubs[i].sel);
        }
    }
}

// Also install a global uncaught exception handler that logs instead of crashing
static void uncaughtExceptionHandler(NSException *exception) {
    static int exCount = 0;
    exCount++;
    if (exCount <= 10) {
        fprintf(stderr, "[dvt] UNCAUGHT EXCEPTION #%d: %s: %s\n",
                exCount,
                [[exception name] UTF8String],
                [[exception reason] UTF8String]);
    }
    // Don't abort - just continue (this only works if the exception is caught
    // somewhere up the call stack)
}

// Hook: +[DVTExtendedPlatformInfo extendedPlatformInfoForPlatformIdentifier:error:]
// The extension points are registered AFTER the first call to this method.
// We force the scan to complete before querying.
static id hooked_extendedPlatformInfo(id self, SEL _cmd, id platformId, NSError **err) {
    // First, try the normal lookup
    id result = ((id(*)(id, SEL, id, NSError **))orig_extendedPlatformInfo)(self, _cmd, platformId, err);
    if (!result) {
        fprintf(stderr, "[dvt] ExtendedPlatformInfo nil for %s - clearing error\n",
                [platformId UTF8String]);
        if (err && *err) *err = nil;
    }
    return result;
}

#define HOOK(cls, selStr, origVar, hookFn) do { \
    Method m = class_getInstanceMethod(cls, NSSelectorFromString(selStr)); \
    if (m) { origVar = method_getImplementation(m); method_setImplementation(m, (IMP)hookFn); \
        fprintf(stderr, "[dvt] Hooked %s\n", [selStr UTF8String]); \
    } else { fprintf(stderr, "[dvt] MISS: %s\n", [selStr UTF8String]); } \
} while(0)

__attribute__((constructor))
static void dvt_plugin_hook_init(void) {
    fprintf(stderr, "[dvt] Installing hooks v3\n");
    Class cls = NSClassFromString(@"DVTPlugInManager");
    if (!cls) { fprintf(stderr, "[dvt] DVTPlugInManager not found!\n"); return; }

    HOOK(cls, @"_checkPresenceOfRequiredPlugIns:error:", orig_checkPresence, hooked_checkPresence);
    HOOK(cls, @"_applyActivationRulesToScanRecords:", orig_applyActivation, hooked_applyActivation);
    HOOK(cls, @"_plugInScanRecordsForInitialScan:linkedFrameworksScanRecords:", orig_scanRecords, hooked_scanRecords);
    HOOK(cls, @"defaultSearchPaths", orig_defaultSearchPaths, hooked_defaultSearchPaths);
    HOOK(cls, @"_scanForPlugInsInDirectories:skippingDuplicatesOfPlugIns:", orig_scanDirs, hooked_scanDirs);
    HOOK(cls, @"_createPlugInObjectsFromScanRecords:", orig_createFromScan, hooked_createFromScan);
    HOOK(cls, @"_createPlugInObjectsFromCache", orig_createFromCache, hooked_createFromCache);
    HOOK(cls, @"_pruneUnusablePlugInsAndScanRecords:linkedFrameworkPaths:", orig_prune, hooked_prune);

    // Hook DVTPlugInScanRecord.identifier to force lazy Info.plist loading
    Class scanRecordCls = NSClassFromString(@"DVTPlugInScanRecord");
    if (scanRecordCls) {
        Method m_id = class_getInstanceMethod(scanRecordCls, NSSelectorFromString(@"identifier"));
        if (m_id) {
            orig_scanRecordIdentifier = method_getImplementation(m_id);
            method_setImplementation(m_id, (IMP)hooked_scanRecordIdentifier);
            fprintf(stderr, "[dvt] Hooked -[DVTPlugInScanRecord identifier] (lazy plist load)\n");
        }
    }

    // Hook plugInPlist and bundleRawInfoPlist for lazy loading
    {
        Method m;
        m = class_getInstanceMethod(scanRecordCls, NSSelectorFromString(@"plugInPlist"));
        if (m) { orig_scanRecordPlugInPlist = method_getImplementation(m);
                  method_setImplementation(m, (IMP)hooked_scanRecordPlugInPlist);
                  fprintf(stderr, "[dvt] Hooked plugInPlist\n"); }
        m = class_getInstanceMethod(scanRecordCls, NSSelectorFromString(@"bundleRawInfoPlist"));
        if (m) { orig_scanRecordRawPlist = method_getImplementation(m);
                  method_setImplementation(m, (IMP)hooked_scanRecordRawPlist);
                  fprintf(stderr, "[dvt] Hooked bundleRawInfoPlist\n"); }
    }

    // Hook additional scan record property getters
    {
        Method m;
        m = class_getInstanceMethod(scanRecordCls, NSSelectorFromString(@"plugInCompatibilityUUIDs"));
        if (m) { orig_scanRecordUUIDs = method_getImplementation(m);
                  method_setImplementation(m, (IMP)hooked_scanRecordUUIDs);
                  fprintf(stderr, "[dvt] Hooked plugInCompatibilityUUIDs\n"); }
        m = class_getInstanceMethod(scanRecordCls, NSSelectorFromString(@"isApplePlugIn"));
        if (m) { orig_scanRecordIsApple = method_getImplementation(m);
                  method_setImplementation(m, (IMP)hooked_scanRecordIsApple);
                  fprintf(stderr, "[dvt] Hooked isApplePlugIn\n"); }
        m = class_getInstanceMethod(scanRecordCls, NSSelectorFromString(@"marketingVersion"));
        if (m) { orig_scanRecordVersion = method_getImplementation(m);
                  method_setImplementation(m, (IMP)hooked_scanRecordVersion);
                  fprintf(stderr, "[dvt] Hooked marketingVersion\n"); }
    }

    // Hook DVTPlugIn.isLoadable to force all plugins as loadable
    Class plugInCls = NSClassFromString(@"DVTPlugIn");
    if (plugInCls) {
        Method m_loadable = class_getInstanceMethod(plugInCls, NSSelectorFromString(@"isLoadable"));
        if (m_loadable) {
            orig_isLoadable = method_getImplementation(m_loadable);
            method_setImplementation(m_loadable, (IMP)hooked_isLoadable);
            fprintf(stderr, "[dvt] Hooked -[DVTPlugIn isLoadable] -> YES\n");
        }
    }
    HOOK(cls, @"_cacheCoversPlugInsWithScanRecords:", orig_cacheCovers, hooked_cacheCovers);
    HOOK(cls, @"_registerPlugInsFromScanRecords:", orig_register, hooked_register);
    HOOK(cls, @"usePlugInCache", orig_useCache, hooked_useCache);

    // Hook extension point lookup to trace what's missing
    Method m_ep_lookup = class_getInstanceMethod(cls,
        NSSelectorFromString(@"extensionPointWithIdentifier:"));
    if (m_ep_lookup) {
        orig_epLookup = method_getImplementation(m_ep_lookup);
        method_setImplementation(m_ep_lookup, (IMP)hooked_epLookup);
        fprintf(stderr, "[dvt] Hooked extensionPointWithIdentifier:\n");
    }

    // Hook DVTPlatform class methods for platform validation bypass
    Class platformCls = NSClassFromString(@"DVTPlatform");
    if (platformCls) {
        // validatePlatformDataReturningError: is a CLASS method
        Method m_validate = class_getClassMethod(platformCls,
            NSSelectorFromString(@"validatePlatformDataReturningError:"));
        if (m_validate) {
            orig_validatePlatform = method_getImplementation(m_validate);
            method_setImplementation(m_validate, (IMP)hooked_validatePlatform);
            fprintf(stderr, "[dvt] Hooked +[DVTPlatform validatePlatformDataReturningError:]\n");
        } else {
            fprintf(stderr, "[dvt] MISS: +[DVTPlatform validatePlatformDataReturningError:]\n");
        }
    } else {
        fprintf(stderr, "[dvt] DVTPlatform class not found\n");
    }

    // Hook DVTExtendedPlatformInfo class method
    Class epCls = NSClassFromString(@"DVTExtendedPlatformInfo");
    if (epCls) {
        Method m_ep = class_getClassMethod(epCls,
            NSSelectorFromString(@"extendedPlatformInfoForPlatformIdentifier:error:"));
        if (m_ep) {
            orig_extendedPlatformInfo = method_getImplementation(m_ep);
            method_setImplementation(m_ep, (IMP)hooked_extendedPlatformInfo);
            fprintf(stderr, "[dvt] Hooked +[DVTExtendedPlatformInfo extendedPlatformInfoForPlatformIdentifier:error:]\n");
        } else {
            fprintf(stderr, "[dvt] MISS: +[DVTExtendedPlatformInfo ...]\n");
        }
    } else {
        fprintf(stderr, "[dvt] DVTExtendedPlatformInfo class not found\n");
    }

    // Add missing private method stubs to prevent assertion failures
    addMissingMethods();

    // Install global uncaught exception handler
    NSSetUncaughtExceptionHandler(uncaughtExceptionHandler);

    fprintf(stderr, "[dvt] All hooks installed\n");
}
