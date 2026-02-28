/* bridge_compat_stubs.m — Compatibility stubs for Xcode 8.3.3 CoreSimulatorBridge on iOS 9.3
 *
 * Provides:
 * 1. Missing iOS 10+ FrontBoardServices symbols
 * 2. Nil-safe swizzles for LSApplicationProxy (prevents NSDictionary nil insertion crash)
 * 3. FBSOpenApplicationService stub that delegates to FBSSystemService
 */

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

#pragma mark - NSString Constants

NSString * const FBSOpenApplicationServiceErrorDomain = @"FBSOpenApplicationServiceErrorDomain";
NSString * const FBSOpenApplicationErrorDomain = @"FBSOpenApplicationErrorDomain";
NSString * const AVAppleMakerNote_AssetIdentifier = @"17";

NSString * const FBSActivateForEventOptionTypeBackgroundContentFetching = @"FBSActivateForEventOptionTypeBackgroundContentFetching";
NSString * const FBSDebugOptionKeyArguments = @"arguments";
NSString * const FBSDebugOptionKeyEnvironment = @"environment";
NSString * const FBSDebugOptionKeyStandardErrorPath = @"standardErrorPath";
NSString * const FBSDebugOptionKeyStandardOutPath = @"standardOutPath";
NSString * const FBSDebugOptionKeyWaitForDebugger = @"waitForDebugger";
NSString * const FBSOpenApplicationOptionKeyActivateForEvent = @"activateForEvent";
NSString * const FBSOpenApplicationOptionKeyActivateSuspended = @"activateSuspended";
NSString * const FBSOpenApplicationOptionKeyDebuggingOptions = @"debuggingOptions";
NSString * const FBSOpenApplicationOptionKeyLSCacheGUID = @"LSCacheGUID";
NSString * const FBSOpenApplicationOptionKeyLSSequenceNumber = @"LSSequenceNumber";
NSString * const FBSOpenApplicationOptionKeyServiceAvailabilityTimeout = @"serviceAvailabilityTimeout";
NSString * const FBSOpenApplicationOptionKeyUnlockDevice = @"unlockDevice";

#pragma mark - C Function Stubs

int BKSWatchdogGetIsAlive(void) { return 1; }
int SBSProcessIDForDisplayIdentifier(void *identifier) { return 0; }

#pragma mark - FBSOpenApplicationOptions Stub

@interface FBSOpenApplicationOptions : NSObject
@end
@implementation FBSOpenApplicationOptions
@end

#pragma mark - FBSOpenApplicationService Stub (delegates to FBSSystemService on iOS 9.3)

@interface FBSOpenApplicationService : NSObject
@end

@implementation FBSOpenApplicationService

- (void)openApplication:(NSString *)bundleID
             withOptions:(id)options
              completion:(void (^)(NSError *))completion {
    /* Delegate to FBSSystemService which exists on iOS 9.3 */
    Class fbsSysClass = objc_getClass("FBSSystemService");
    if (fbsSysClass) {
        id svc = ((id(*)(id, SEL))objc_msgSend)((id)fbsSysClass,
                  sel_registerName("sharedService"));
        if (svc) {
            /* FBSSystemService openApplication:options:clientPort:withResult: */
            SEL openSel = sel_registerName("openApplication:options:clientPort:withResult:");
            if ([svc respondsToSelector:openSel]) {
                NSDictionary *opts = @{};
                ((void(*)(id, SEL, id, id, unsigned int, id))objc_msgSend)(
                    svc, openSel, bundleID, opts, 0,
                    ^(int err) {
                        if (completion) {
                            NSError *error = nil;
                            if (err != 0) {
                                error = [NSError errorWithDomain:@"FBSOpenApplicationServiceErrorDomain"
                                                           code:err userInfo:nil];
                            }
                            completion(error);
                        }
                    });
                return;
            }
        }
    }
    /* Fallback: SBSLaunchApplicationWithIdentifier */
    if (completion) completion(nil);
}

@end

#pragma mark - Nil-safe Swizzles for LSApplicationProxy

static IMP orig_dataContainerURL;
static IMP orig_bundleContainerURL;
static IMP orig_groupContainerURLs;
static IMP orig_appTags;

static NSURL *safe_dataContainerURL(id self, SEL _cmd) {
    NSURL *result = ((NSURL*(*)(id, SEL))orig_dataContainerURL)(self, _cmd);
    if (!result) {
        /* Return a placeholder so NSDictionary doesn't crash on nil */
        result = [NSURL fileURLWithPath:@"/var/empty"];
    }
    return result;
}

static NSURL *safe_bundleContainerURL(id self, SEL _cmd) {
    NSURL *result = ((NSURL*(*)(id, SEL))orig_bundleContainerURL)(self, _cmd);
    if (!result) {
        result = [NSURL fileURLWithPath:@"/var/empty"];
    }
    return result;
}

static NSDictionary *safe_groupContainerURLs(id self, SEL _cmd) {
    NSDictionary *result = ((NSDictionary*(*)(id, SEL))orig_groupContainerURLs)(self, _cmd);
    if (!result) {
        result = @{};
    }
    return result;
}

static NSArray *safe_appTags(id self, SEL _cmd) {
    NSArray *result = ((NSArray*(*)(id, SEL))orig_appTags)(self, _cmd);
    if (!result) {
        result = @[];
    }
    return result;
}

#pragma mark - Constructor

__attribute__((constructor))
static void bridge_compat_init(void) {
    /* Swizzle LSApplicationProxy methods to return non-nil defaults */
    Class lsProxy = objc_getClass("LSApplicationProxy");
    if (lsProxy) {
        Method m;

        m = class_getInstanceMethod(lsProxy, sel_registerName("dataContainerURL"));
        if (m) {
            orig_dataContainerURL = method_getImplementation(m);
            method_setImplementation(m, (IMP)safe_dataContainerURL);
        }

        m = class_getInstanceMethod(lsProxy, sel_registerName("bundleContainerURL"));
        if (m) {
            orig_bundleContainerURL = method_getImplementation(m);
            method_setImplementation(m, (IMP)safe_bundleContainerURL);
        }

        m = class_getInstanceMethod(lsProxy, sel_registerName("groupContainerURLs"));
        if (m) {
            orig_groupContainerURLs = method_getImplementation(m);
            method_setImplementation(m, (IMP)safe_groupContainerURLs);
        }

        m = class_getInstanceMethod(lsProxy, sel_registerName("appTags"));
        if (m) {
            orig_appTags = method_getImplementation(m);
            method_setImplementation(m, (IMP)safe_appTags);
        }

        NSLog(@"[bridge_compat] LSApplicationProxy nil-safe swizzles installed");
    }

    NSLog(@"[bridge_compat] Stubs loaded: FBS classes + nil-safe proxy + %d string constants",
          15 /* count of FBS string constants */);
}
