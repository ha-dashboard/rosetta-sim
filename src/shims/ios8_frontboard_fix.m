/*
 * ios8_frontboard_fix.m — Fix FrontBoard crash in iOS 8.2 simulator on macOS 26
 *
 * Problem: FBApplicationInfo's _cacheFolderNamesForSystemApp: doesn't nil-check
 * before [NSMutableArray addObject:], causing a crash when macOS 26's
 * CoreSimulator provides app metadata with nil values.
 *
 * Fix: Replace _cacheFolderNamesForSystemApp: with a no-op. Folder name
 * caching is cosmetic (home screen folder labels), not boot-critical.
 * Note: @try/@catch doesn't work under Rosetta 2 (ObjC exception unwinding
 * triggers SIGTRAP), so we skip the method entirely.
 *
 * Build (x86_64 — runs inside Rosetta sim):
 *   clang -arch x86_64 -dynamiclib -framework Foundation -fobjc-arc \
 *     -target x86_64-apple-ios9.0-simulator \
 *     -isysroot $(xcrun --show-sdk-path --sdk iphonesimulator) \
 *     -o ios8_frontboard_fix.dylib ios8_frontboard_fix.m
 *
 * Injection:
 *   export SIMCTL_CHILD_DYLD_INSERT_LIBRARIES=/path/to/ios8_frontboard_fix.dylib
 *   xcrun simctl boot <UDID>
 *
 *   Or via insert_dylib on SpringBoard binary directly.
 */

#import <Foundation/Foundation.h>
#import <objc/runtime.h>

__attribute__((constructor))
static void fix_frontboard(void) {
    Class cls = objc_getClass("FBApplicationInfo");
    if (!cls) {
        /* FrontBoard not loaded yet — this is normal for non-SpringBoard processes */
        return;
    }

    SEL sel = sel_registerName("_cacheFolderNamesForSystemApp:");
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;

    /* Replace with no-op — folder name caching is cosmetic, not boot-critical */
    IMP newIMP = imp_implementationWithBlock(^(id self, id app) {
        /* Do nothing — skip folder name caching entirely */
    });
    method_setImplementation(m, newIMP);
    NSLog(@"[RosettaSim] iOS 8.2 FrontBoard fix: _cacheFolderNamesForSystemApp: disabled");
}
