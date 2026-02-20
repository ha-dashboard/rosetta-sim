// DVT Plugin System Hook v3 - Full pipeline tracing
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
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

    // Restore removed records — but ONLY if their bundle still exists on disk.
    // Plugins moved to PlugIns.disabled/ should stay pruned so their extensions
    // never register and never trigger dlopen failures later.
    if (after < before) {
        NSMutableArray *mutableRecords = (NSMutableArray *)records;
        int restored = 0, skipped = 0;
        for (id record in backup) {
            if (![mutableRecords containsObject:record]) {
                NSString *bundlePath = nil;
                @try {
                    SEL bpSel = NSSelectorFromString(@"bundlePath");
                    if ([record respondsToSelector:bpSel]) {
                        bundlePath = [record performSelector:bpSel];
                    }
                    if (!bundlePath) {
                        SEL pathSel = NSSelectorFromString(@"path");
                        if ([record respondsToSelector:pathSel]) {
                            bundlePath = [record performSelector:pathSel];
                        }
                    }
                } @catch (NSException *e) {}

                BOOL exists = bundlePath &&
                    [[NSFileManager defaultManager] fileExistsAtPath:bundlePath];
                if (exists) {
                    [mutableRecords addObject:record];
                    restored++;
                } else {
                    skipped++;
                    if (skipped <= 10) {
                        fprintf(stderr, "[dvt]   SKIP (missing): %s\n",
                                bundlePath ? [[bundlePath lastPathComponent] UTF8String] : "?");
                    }
                }
            }
        }
        fprintf(stderr, "[dvt] _prune: restored %d, skipped %d missing → %lu total\n",
                restored, skipped, (unsigned long)[records count]);
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

// CALayer.view - removed private CoreAnimation API
// DVTKit's CALayer(DVTCALayerAdditions) category expects a -view method
// that returns the NSView backing this layer. In older CoreAnimation this was
// a private property; in modern macOS it was removed. The layer's delegate
// is the backing view when a view is layer-backed, so we return that.
static id calayer_view(id self, SEL _cmd) {
    id delegate = [(CALayer *)self delegate];
    if (delegate && [delegate isKindOfClass:[NSView class]]) {
        return delegate;
    }
    return nil;
}

// _autolayout_cellSize - removed private AppKit method on NSCell.
// IDEVariablesViewPopUpButtonCell (from DebuggerUI) calls this.
// CANNOT simply call [self cellSize] — IDEVariablesViewPopUpButtonCell overrides
// cellSize and calls _autolayout_cellSize, creating infinite recursion that
// overflows the stack and crashes Rosetta. Instead, call NSCell's cellSize
// directly via its IMP to break the cycle.
static IMP nsCell_cellSize_IMP = NULL;
static NSSize autolayout_cellSize(id self, SEL _cmd) {
    if (!nsCell_cellSize_IMP) {
        nsCell_cellSize_IMP = class_getMethodImplementation([NSCell class],
            sel_registerName("cellSize"));
    }
    // Call NSCell's cellSize directly, bypassing any subclass override
    return ((NSSize(*)(id, SEL))nsCell_cellSize_IMP)(self, sel_registerName("cellSize"));
}

static void addMissingMethods(void) {
    fprintf(stderr, "[dvt] Adding missing private method stubs...\n");

    // _addHeartBeatClientView: was removed from NSView/NSWindow in modern AppKit
    // IB tries to swizzle it and crashes when it's not found
    // IMPORTANT: Subclass-specific stubs must come BEFORE superclass stubs.
    // class_addMethod only adds if the method doesn't exist on the class OR its
    // ancestors. Once NSView gets _installHeartBeat: with v@:@, NSProgressIndicator
    // inherits it and won't get its own v@:c version. So add subclass versions first.
    struct { const char *cls; const char *sel; const char *types; } stubs[] = {
        // NSProgressIndicator MUST be before NSView — IB's _IBReplaceMethodPrimitive
        // checks type encoding via IBIsMethodSignatureCompatibleWithSignature.
        // It expects v@:c (void, self, SEL, char/BOOL) not v@:@ (object).
        {"NSProgressIndicator", "_installHeartBeat:", "v@:c"},
        {"NSProgressIndicator", "_removeHeartBeat:", "v@:c"},
        // HeartBeat methods removed from modern AppKit (NSView = base class)
        {"NSView", "_addHeartBeatClientView:", "v@:@"},
        {"NSView", "_removeHeartBeatClientView:", "v@:@"},
        {"NSView", "_installHeartBeat:", "v@:@"},
        {"NSView", "_removeHeartBeat:", "v@:@"},
        {"NSView", "_heartBeatClientViews", "@@:"},
        {"NSWindow", "_addHeartBeatClientView:", "v@:@"},
        {"NSWindow", "_removeHeartBeatClientView:", "v@:@"},
        {"NSWindow", "_installHeartBeat:", "v@:@"},
        {"NSWindow", "_removeHeartBeat:", "v@:@"},
        // Auto layout private method removed from NSView — IBCocoaTouchPlugin
        // tries to swizzle it via IBReplaceMethodPrimitive.
        // IB expects encoding v@:^c^c (void, self, SEL, char*, char*)
        {"NSView", "_whenResizingUseEngineFrame:useAutoresizingMask:", "v@:^c^c"},
        // Other common removed private methods
        {"NSApplication", "_installHeartBeat:", "v@:@"},
        {"NSApplication", "_removeHeartBeat:", "v@:@"},
        {NULL, NULL, NULL}
    };

    for (int i = 0; stubs[i].cls; i++) {
        Class cls = objc_getClass(stubs[i].cls);
        SEL sel = sel_registerName(stubs[i].sel);
        if (!cls) continue;
        // Use class_copyMethodList to check if THIS class directly implements it
        // (not inherited). This allows adding overrides on subclasses.
        BOOL hasDirectMethod = NO;
        unsigned int methodCount = 0;
        Method *methods = class_copyMethodList(cls, &methodCount);
        for (unsigned int j = 0; j < methodCount; j++) {
            if (method_getName(methods[j]) == sel) { hasDirectMethod = YES; break; }
        }
        free(methods);
        if (!hasDirectMethod) {
            class_addMethod(cls, sel, (IMP)compat_noop, stubs[i].types);
            fprintf(stderr, "[dvt]   Added stub: -[%s %s] (%s)\n",
                    stubs[i].cls, stubs[i].sel, stubs[i].types);
        }
    }

    // CALayer.view - DVTKit's CALayer(DVTCALayerAdditions) category defines a
    // -view method that internally calls a removed private CALayer API, causing
    // NSInvalidArgumentException via forwarding. We must REPLACE DVTKit's broken
    // implementation, not just add one — the category method already exists.
    Class calayerCls = objc_getClass("CALayer");
    if (calayerCls) {
        SEL viewSel = sel_registerName("view");
        Method existingMethod = class_getInstanceMethod(calayerCls, viewSel);
        if (existingMethod) {
            IMP oldImp = method_setImplementation(existingMethod, (IMP)calayer_view);
            fprintf(stderr, "[dvt]   Replaced -[CALayer view] (was %p, now delegate->NSView)\n", oldImp);
        } else {
            class_addMethod(calayerCls, viewSel, (IMP)calayer_view, "@@:");
            fprintf(stderr, "[dvt]   Added stub: -[CALayer view] (delegate->NSView)\n");
        }
    }

    // Also replace -[CALayer window] from DVTKit's category — it calls [self view]
    // then [view window], which should now work with our fixed view method, but
    // replace it too in case it also calls removed APIs directly.
    if (calayerCls) {
        SEL windowSel = sel_registerName("window");
        Method windowMethod = class_getInstanceMethod(calayerCls, windowSel);
        if (windowMethod) {
            // Check if this is DVTKit's category method (not a base CALayer method)
            // by seeing if it calls through to view. We'll replace it with a safe version.
            // DVTKit's -window calls [self view] then [[self view] window]
            // Our calayer_view is safe now, so window should chain correctly.
            // But let's log it for debugging.
            fprintf(stderr, "[dvt]   CALayer -window method exists (DVTKit category), leaving chained through -view\n");
        }
    }

    // _autolayout_cellSize — removed private AppKit method on NSCell.
    // IDEVariablesViewPopUpButtonCell (DebuggerUI) calls it for auto layout sizing.
    // We add it on NSCell so all subclasses inherit it. Forwards to cellSize.
    Class nsCellCls = objc_getClass("NSCell");
    if (nsCellCls) {
        SEL alSel = sel_registerName("_autolayout_cellSize");
        if (!class_getInstanceMethod(nsCellCls, alSel)) {
            // {CGSize=dd}16@0:8 — returns NSSize, takes self+_cmd
            class_addMethod(nsCellCls, alSel, (IMP)autolayout_cellSize, "{CGSize=dd}16@0:8");
            fprintf(stderr, "[dvt]   Added -[NSCell _autolayout_cellSize] → cellSize\n");
        }
    }
}

// Exception suppression removed — we fix the actual problems instead:
// - CALayer.view: replaced with working implementation
// - DVTExtension valueForKey:error:: wrapped in try/catch (returns nil+error)
// - _autolayout_cellSize: added missing method on NSCell
// - Plugin prune: only restores plugins whose bundles exist on disk

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

    // Add missing private method stubs
    addMissingMethods();

    // Hook IBCocoaPlugin initialization to catch exceptions
    Class ibCocoaCls = NSClassFromString(@"IBCocoaPlugin");
    if (ibCocoaCls) {
        SEL initSel = NSSelectorFromString(@"ide_initializeWithOptions:error:");
        Method m_ibinit = class_getClassMethod(ibCocoaCls, initSel);
        if (m_ibinit) {
            static IMP orig_ibinit = NULL;
            typedef BOOL(*IBInitFn)(id, SEL, unsigned long long, NSError **);
            orig_ibinit = method_getImplementation(m_ibinit);
            // Create a block-based IMP that wraps in try/catch
            IMP new_imp = imp_implementationWithBlock(^BOOL(id _self, unsigned long long opts, NSError **err) {
                @try {
                    fprintf(stderr, "[dvt] IBCocoaPlugin init (with try/catch)...\n");
                    return ((IBInitFn)orig_ibinit)(_self, initSel, opts, err);
                } @catch (NSException *e) {
                    fprintf(stderr, "[dvt] IBCocoaPlugin init EXCEPTION caught: %s\n",
                            [[e reason] UTF8String]);
                    return YES; // Pretend it succeeded
                }
            });
            method_setImplementation(m_ibinit, new_imp);
            fprintf(stderr, "[dvt] Hooked +[IBCocoaPlugin ide_initializeWithOptions:error:] (try/catch)\n");
        }
    }

    // Also wrap DVTPlugIn load: method in try/catch to catch any plugin load failures
    if (plugInCls) {
        SEL loadSel = NSSelectorFromString(@"load:");
        Method m_load = class_getInstanceMethod(plugInCls, loadSel);
        if (m_load) {
            static IMP orig_load = NULL;
            orig_load = method_getImplementation(m_load);
            typedef BOOL(*LoadFn)(id, SEL, NSError **);
            IMP new_load_imp = imp_implementationWithBlock(^BOOL(id _self, NSError **err) {
                @try {
                    return ((LoadFn)orig_load)(_self, loadSel, err);
                } @catch (NSException *e) {
                    static int loadExCount = 0;
                    loadExCount++;
                    if (loadExCount <= 5) {
                        id ident = [_self performSelector:NSSelectorFromString(@"identifier")];
                        fprintf(stderr, "[dvt] Plugin load exception for %s: %s\n",
                                ident ? [ident UTF8String] : "?",
                                [[e reason] UTF8String]);
                    }
                    return NO;
                }
            });
            method_setImplementation(m_load, new_load_imp);
            fprintf(stderr, "[dvt] Hooked -[DVTPlugIn load:] (try/catch)\n");
        }
    }

    // Hook -[DVTExtension valueForKey:error:] to catch exceptions instead of throwing.
    // On macOS 26, some extensions from disabled plugins (DebuggerUI etc.) have
    // invalid state causing NSInternalInconsistencyException. Wrapping in @try/@catch
    // lets callers handle the nil return gracefully.
    Class dvtExtCls = NSClassFromString(@"DVTExtension");
    if (dvtExtCls) {
        SEL vfkSel = NSSelectorFromString(@"valueForKey:error:");
        Method m_vfk = class_getInstanceMethod(dvtExtCls, vfkSel);
        if (m_vfk) {
            static IMP orig_vfk = NULL;
            orig_vfk = method_getImplementation(m_vfk);
            typedef id(*VFKFn)(id, SEL, NSString *, NSError **);
            IMP new_vfk = imp_implementationWithBlock(^id(id _self, NSString *key, NSError **err) {
                @try {
                    return ((VFKFn)orig_vfk)(_self, vfkSel, key, err);
                } @catch (NSException *e) {
                    static int vfkExCount = 0;
                    vfkExCount++;
                    if (vfkExCount <= 10) {
                        fprintf(stderr, "[dvt] DVTExtension valueForKey:%s exception caught: %s\n",
                                [key UTF8String], [[e reason] UTF8String]);
                    }
                    if (err) {
                        *err = [NSError errorWithDomain:@"DVTPlugInErrorDomain"
                                                   code:-1
                                               userInfo:@{NSLocalizedDescriptionKey: [e reason] ?: @"Unknown"}];
                    }
                    return nil;
                }
            });
            method_setImplementation(m_vfk, new_vfk);
            fprintf(stderr, "[dvt] Hooked -[DVTExtension valueForKey:error:] (try/catch)\n");
        }
    }

    // Hook IDEMenuBuilder to tolerate missing extensions from disabled plugins.
    // The menu definition XML references extensions from all plugins, including
    // disabled ones. IDEMenuBuilder.m:299 asserts that each extension resolves,
    // but with disabled plugins some won't. We wrap _appendItemsToMenu: so it
    // skips missing extensions instead of aborting.
    Class menuBuilderCls = NSClassFromString(@"IDEMenuBuilder");
    if (menuBuilderCls) {
        SEL appendSel = NSSelectorFromString(@"_appendItemsToMenu:forMenuDefinitionIdentifier:forViewController:fillingExtensionIdToMenuMap:");
        Method m_append = class_getClassMethod(menuBuilderCls, appendSel);
        if (m_append) {
            static IMP orig_append = NULL;
            orig_append = method_getImplementation(m_append);
            typedef void(*AppendFn)(id, SEL, id, id, id, id);
            IMP new_append = imp_implementationWithBlock(^(id _self, id menu, id menuDefId, id viewController, id extMap) {
                @try {
                    ((AppendFn)orig_append)(_self, appendSel, menu, menuDefId, viewController, extMap);
                } @catch (NSException *e) {
                    // Skip this menu definition — extension from a disabled plugin
                    static int menuSkipCount = 0;
                    menuSkipCount++;
                    if (menuSkipCount <= 5) {
                        fprintf(stderr, "[dvt] Menu: skipped missing extension for %s\n",
                                menuDefId ? [[menuDefId description] UTF8String] : "?");
                    }
                }
            });
            method_setImplementation(m_append, new_append);
            fprintf(stderr, "[dvt] Hooked +[IDEMenuBuilder _appendItemsToMenu:...] (skip missing)\n");
        }
    }

    // Hook _DVTAssertionFailureHandler to log-only for non-critical assertions.
    // Some assertions (like IDEMenuBuilder.m:299) fire because disabled plugins
    // left stale references. These are not bugs — they're expected when plugins
    // are disabled. We convert assertion failures to warnings.
    Class ideAssertCls = NSClassFromString(@"IDEAssertionHandler");
    if (ideAssertCls) {
        SEL handleSel = NSSelectorFromString(@"handleFailureInMethod:object:fileName:lineNumber:assertionSignature:messageFormat:arguments:");
        Method m_handle = class_getInstanceMethod(ideAssertCls, handleSel);
        if (m_handle) {
            static IMP orig_handleFailure = NULL;
            orig_handleFailure = method_getImplementation(m_handle);
            IMP new_handle = imp_implementationWithBlock(^(id _self, SEL method, id object,
                    const char *fileName, int lineNumber, NSString *sig,
                    NSString *format, va_list args) {
                // Log as warning instead of aborting
                static int assertCount = 0;
                assertCount++;
                if (assertCount <= 20) {
                    fprintf(stderr, "[dvt] ASSERTION→WARNING #%d: %s:%d\n",
                            assertCount, fileName ?: "?", lineNumber);
                }
                // Don't call original — it calls abort()
                // The caller will continue with whatever state it has
            });
            method_setImplementation(m_handle, new_handle);
            fprintf(stderr, "[dvt] Hooked -[IDEAssertionHandler handleFailureInMethod:] (→ warning)\n");
        }

        // Also convert uncaught exceptions to warnings
        SEL uncaughtSel = NSSelectorFromString(@"handleUncaughtException:");
        Method m_uncaught = class_getInstanceMethod(ideAssertCls, uncaughtSel);
        if (m_uncaught) {
            static IMP orig_uncaught = NULL;
            orig_uncaught = method_getImplementation(m_uncaught);
            IMP new_uncaught = imp_implementationWithBlock(^(id _self, NSException *exc) {
                static int uncaughtCount = 0;
                uncaughtCount++;
                if (uncaughtCount <= 20) {
                    fprintf(stderr, "[dvt] UNCAUGHT→WARNING #%d: %s: %s\n",
                            uncaughtCount, [[exc name] UTF8String],
                            [[exc reason] UTF8String]);
                }
                // Don't abort — the run loop will continue
            });
            method_setImplementation(m_uncaught, new_uncaught);
            fprintf(stderr, "[dvt] Hooked -[IDEAssertionHandler handleUncaughtException:] (→ warning)\n");
        }
    }

    // Hook DVTInvalidExtension — when a plugin is disabled, its extensions become
    // DVTInvalidExtension objects. Accessing any property throws via
    // _throwInvalidExtensionExceptionForProperty: → objc_exception_throw → __cxa_throw.
    // Under Rosetta 2, __cxa_throw crashes with pointer authentication failure.
    // Fix: override valueForKey: on DVTInvalidExtension to return nil instead of throwing.
    Class invalidExtCls = NSClassFromString(@"DVTInvalidExtension");
    if (invalidExtCls) {
        SEL vfkSel2 = NSSelectorFromString(@"valueForKey:");
        Method m_ivfk = class_getInstanceMethod(invalidExtCls, vfkSel2);
        if (m_ivfk) {
            static IMP orig_ivfk = NULL;
            orig_ivfk = method_getImplementation(m_ivfk);
            IMP new_ivfk = imp_implementationWithBlock(^id(id _self, NSString *key) {
                // Return safe defaults instead of throwing — callers expect non-nil
                // for certain properties and will crash inserting nil into arrays.
                static int ivfkCount = 0;
                ivfkCount++;
                if (ivfkCount <= 10) {
                    fprintf(stderr, "[dvt] DVTInvalidExtension.%s → default (plugin disabled)\n",
                            [key UTF8String]);
                }
                // Return type-appropriate defaults for known properties
                if ([key isEqualToString:@"title"] || [key isEqualToString:@"name"] ||
                    [key isEqualToString:@"localizedName"] || [key isEqualToString:@"identifier"]) {
                    return @"(disabled)";
                }
                if ([key isEqualToString:@"image"] || [key isEqualToString:@"icon"]) {
                    return [[NSImage alloc] initWithSize:NSMakeSize(16, 16)];
                }
                if ([key isEqualToString:@"toolbarOrder"] || [key isEqualToString:@"order"]) {
                    return @(999999); // Sort to end
                }
                // For unknown keys, return empty string (safer than nil for most contexts)
                return @"";
            });
            method_setImplementation(m_ivfk, new_ivfk);
            fprintf(stderr, "[dvt] Hooked -[DVTInvalidExtension valueForKey:] (→ nil)\n");
        }

        // Also hook the throw method itself in case it's called directly
        SEL throwSel = NSSelectorFromString(@"_throwInvalidExtensionExceptionForProperty:");
        Method m_throw = class_getInstanceMethod(invalidExtCls, throwSel);
        if (m_throw) {
            IMP new_throw = imp_implementationWithBlock(^(id _self, NSString *prop) {
                static int throwCount = 0;
                throwCount++;
                if (throwCount <= 5) {
                    fprintf(stderr, "[dvt] DVTInvalidExtension: prevented throw for property '%s'\n",
                            [prop UTF8String]);
                }
                // Don't throw — just return
            });
            method_setImplementation(m_throw, new_throw);
            fprintf(stderr, "[dvt] Hooked -[DVTInvalidExtension _throwInvalidExtensionExceptionForProperty:] (→ noop)\n");
        }
    }

    // Set OBJC_DEBUG_MISSING_POOLS=NO to prevent debug crashes
    setenv("OBJC_DEBUG_MISSING_POOLS", "NO", 1);

    fprintf(stderr, "[dvt] All hooks installed\n");
}
