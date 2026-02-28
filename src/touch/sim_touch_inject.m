/*
 * sim_touch_inject.dylib — x86_64 constructor dylib injected into backboardd
 *
 * Dispatch priority:
 *   1. BKHIDSystemInterface.injectHIDEvent: (backboardd's internal pipeline)
 *   2. BKSHIDEventSendToFocusedProcess (fallback)
 *
 * Touch command file: {NSHomeDirectory()}/tmp/rosettasim_touch.json
 * Format: one JSON object per line (JSONL):
 *   {"action":"down","x":160,"y":284,"finger":0}
 *   {"action":"move","x":170,"y":290,"finger":0}
 *   {"action":"up","x":170,"y":290,"finger":0}
 *
 * Build:
 *   SDK=$(xcrun --show-sdk-path --sdk iphonesimulator)
 *   clang -arch x86_64 -isysroot "$SDK" -mios-simulator-version-min=9.0 \
 *       -dynamiclib -framework Foundation -framework IOKit \
 *       -install_name /usr/lib/sim_touch_inject.dylib \
 *       -Wl,-undefined,dynamic_lookup -Wl,-not_for_dyld_shared_cache \
 *       -fobjc-arc -o src/build/sim_touch_inject.dylib src/touch/sim_touch_inject.m
 */

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <dlfcn.h>
#include <mach/mach_time.h>
#include <pthread.h>

/* ================================================================
 * IOHIDEvent types
 * ================================================================ */

typedef uint32_t IOOptionBits;
typedef struct __IOHIDEvent *IOHIDEventRef;

#define kIOHIDDigitizerEventRange      (1 << 0)
#define kIOHIDDigitizerEventTouch      (1 << 1)
#define kIOHIDDigitizerEventPosition   (1 << 2)
#define kIOHIDDigitizerTransducerTypeFinger 2
#define kIOHIDEventFieldDigitizerIsDisplayIntegrated 0xb0018

typedef IOHIDEventRef (*IOHIDEventCreateDigitizerFingerEventFn)(
    CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t,
    float, float, float, float, float,
    Boolean, Boolean, IOOptionBits);
typedef IOHIDEventRef (*IOHIDEventCreateDigitizerEventFn)(
    CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t,
    uint32_t, uint32_t, float, float, float,
    float, float, float, Boolean, Boolean, IOOptionBits);
typedef void (*IOHIDEventAppendEventFn)(IOHIDEventRef, IOHIDEventRef, IOOptionBits);
typedef void (*IOHIDEventSetIntegerValueFn)(IOHIDEventRef, uint32_t, int32_t);
typedef void (*IOHIDEventSetSenderIDFn)(IOHIDEventRef, uint64_t);

typedef void (*BKSHIDEventSendToFocusedProcessFn)(IOHIDEventRef);

/* Keyboard event creation */
typedef IOHIDEventRef (*IOHIDEventCreateKeyboardEventFn)(
    CFAllocatorRef, uint64_t, uint32_t usagePage, uint32_t usage,
    Boolean down, IOOptionBits);

static IOHIDEventCreateKeyboardEventFn fnCreateKeyboardEvent = NULL;
static IOHIDEventCreateDigitizerFingerEventFn fnCreateFingerEvent = NULL;
static IOHIDEventCreateDigitizerEventFn fnCreateDigitizerEvent = NULL;
static IOHIDEventAppendEventFn fnAppendEvent = NULL;
static IOHIDEventSetIntegerValueFn fnSetIntegerValue = NULL;
static IOHIDEventSetSenderIDFn fnSetSenderID = NULL;
static BKSHIDEventSendToFocusedProcessFn fnBKSSendToFocused = NULL;
static uint64_t g_main_screen_sender_id = 0;

/* BKHIDSystemInterface (primary dispatch) */
static id g_bk_hid_system = nil;

/* SimHIDVirtualService touch service (direct dispatch) */
static id g_touch_service = nil;
static void *g_hid_service_ref = NULL; /* raw IOHIDServiceRef from hidService */

/* Direct C dispatch via IOHIDEventSystemClient */
typedef void *IOHIDEventSystemClientRef;
typedef void (*IOHIDEventSystemClientDispatchEventFn)(IOHIDEventSystemClientRef, IOHIDEventRef);
static IOHIDEventSystemClientDispatchEventFn fnClientDispatchEvent = NULL;
static IOHIDEventSystemClientRef g_event_client = NULL;

/* ================================================================
 * Logging
 * ================================================================ */

static char g_log_path[512];
static char g_cmd_path[512];

static void touch_log(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void touch_log(const char *fmt, ...) {
    va_list ap, ap2;
    va_start(ap, fmt);
    va_copy(ap2, ap);
    fprintf(stderr, "[touch_inject] ");
    vfprintf(stderr, fmt, ap2);
    fprintf(stderr, "\n");
    va_end(ap2);

    FILE *f = fopen(g_log_path, "a");
    if (f) {
        fprintf(f, "[touch_inject] ");
        vfprintf(f, fmt, ap);
        fprintf(f, "\n");
        fclose(f);
    }
    va_end(ap);
}

/* ================================================================
 * Symbol resolution
 * ================================================================ */

static BOOL resolve_symbols(void) {
    dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);

    fnCreateKeyboardEvent = (IOHIDEventCreateKeyboardEventFn)
        dlsym(RTLD_DEFAULT, "IOHIDEventCreateKeyboardEvent");
    fnCreateFingerEvent = (IOHIDEventCreateDigitizerFingerEventFn)
        dlsym(RTLD_DEFAULT, "IOHIDEventCreateDigitizerFingerEvent");
    fnCreateDigitizerEvent = (IOHIDEventCreateDigitizerEventFn)
        dlsym(RTLD_DEFAULT, "IOHIDEventCreateDigitizerEvent");
    fnAppendEvent = (IOHIDEventAppendEventFn)
        dlsym(RTLD_DEFAULT, "IOHIDEventAppendEvent");
    fnSetIntegerValue = (IOHIDEventSetIntegerValueFn)
        dlsym(RTLD_DEFAULT, "IOHIDEventSetIntegerValue");
    fnSetSenderID = (IOHIDEventSetSenderIDFn)
        dlsym(RTLD_DEFAULT, "IOHIDEventSetSenderID");
    fnBKSSendToFocused = (BKSHIDEventSendToFocusedProcessFn)
        dlsym(RTLD_DEFAULT, "BKSHIDEventSendToFocusedProcess");
    fnClientDispatchEvent = (IOHIDEventSystemClientDispatchEventFn)
        dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientDispatchEvent");
    touch_log("IOHIDEventSystemClientDispatchEvent: %p", fnClientDispatchEvent);
    /* DO NOT call IOHIDEventSystemClientCreate here — it deadlocks in backboardd.
     * g_event_client will be set later from BKHIDServiceManager's _hidEventSystem. */

    touch_log("IOHIDEvent: Finger=%p Digitizer=%p Append=%p SetInt=%p SetSenderID=%p BKS=%p",
              fnCreateFingerEvent, fnCreateDigitizerEvent,
              fnAppendEvent, fnSetIntegerValue, fnSetSenderID, fnBKSSendToFocused);

    /* Resolve IndigoHIDMainScreen from SimulatorClient.framework */
    void *scHandle = dlopen("/System/Library/PrivateFrameworks/SimulatorClient.framework/SimulatorClient", RTLD_LAZY);
    if (scHandle) {
        uint64_t *mainScreenPtr = (uint64_t *)dlsym(scHandle, "IndigoHIDMainScreen");
        if (mainScreenPtr) {
            g_main_screen_sender_id = *mainScreenPtr;
            touch_log("IndigoHIDMainScreen = 0x%llx", g_main_screen_sender_id);
        } else {
            touch_log("IndigoHIDMainScreen symbol not found, using fallback 0x200000001");
            g_main_screen_sender_id = 0x3023656E65726353ULL; /* "Screen#0" */
        }
    } else {
        touch_log("SimulatorClient.framework not loaded, using fallback sender ID 0x200000001");
        g_main_screen_sender_id = 0x3023656E65726353ULL; /* "Screen#0" */
    }

    if (!fnCreateFingerEvent) {
        touch_log("FATAL: IOHIDEventCreateDigitizerFingerEvent not found");
        return NO;
    }

    /* Resolve BKHIDSystemInterface — backboardd's internal event injection */
    Class bkCls = objc_getClass("BKHIDSystemInterface");
    if (bkCls) {
        g_bk_hid_system = ((id(*)(id, SEL))objc_msgSend)(
            (id)bkCls, sel_registerName("sharedInstance"));
        touch_log("BKHIDSystemInterface.sharedInstance = %p", (__bridge void *)g_bk_hid_system);

        if (g_bk_hid_system) {
            SEL injSel = sel_registerName("injectHIDEvent:");
            BOOL responds = [g_bk_hid_system respondsToSelector:injSel];
            touch_log("  responds to injectHIDEvent: = %d", responds);
            if (!responds) {
                /* Dump methods for debugging */
                unsigned int count = 0;
                Method *methods = class_copyMethodList([g_bk_hid_system class], &count);
                touch_log("  BKHIDSystemInterface methods (%u):", count);
                for (unsigned int i = 0; i < count; i++) {
                    const char *name = sel_getName(method_getName(methods[i]));
                    if (strcasestr(name, "hid") || strcasestr(name, "event") ||
                        strcasestr(name, "inject"))
                        touch_log("    %s", name);
                }
                free(methods);
                g_bk_hid_system = nil; /* Don't use if doesn't respond */
            }
        }
    } else {
        touch_log("BKHIDSystemInterface class not found");
        /* Dump all BK* classes for debugging */
        unsigned int classCount = 0;
        Class *allClasses = objc_copyClassList(&classCount);
        touch_log("  Searching BK* classes (%u total):", classCount);
        for (unsigned int i = 0; i < classCount; i++) {
            const char *name = class_getName(allClasses[i]);
            if (strncmp(name, "BK", 2) == 0 &&
                (strcasestr(name, "hid") || strcasestr(name, "event")))
                touch_log("    %s", name);
        }
        free(allClasses);
    }

    if (!g_bk_hid_system && !fnBKSSendToFocused) {
        touch_log("FATAL: No dispatch method available");
        return NO;
    }

    touch_log("Dispatch: primary=%s fallback=%s",
              g_bk_hid_system ? "BKHIDSystemInterface" : "none",
              fnBKSSendToFocused ? "BKSSendToFocused" : "none");

    return YES;
}

/* ================================================================
 * Event creation and dispatch
 * ================================================================ */

static void dispatch_event(IOHIDEventRef event) {
    if (!event) return;

    /* Mark as display-integrated */
    if (fnSetIntegerValue) {
        fnSetIntegerValue(event, kIOHIDEventFieldDigitizerIsDisplayIntegrated, 1);
    }

    /* Set sender ID */
    if (fnSetSenderID && g_main_screen_sender_id != 0) {
        fnSetSenderID(event, g_main_screen_sender_id);
    }

    /* Primary: BKHIDSystemInterface.injectHIDEvent:
     * Events reach BKTouchPadManager — tracing deeper to find where they stop. */
    if (g_bk_hid_system) {
        ((void(*)(id, SEL, void *))objc_msgSend)(
            g_bk_hid_system, sel_registerName("injectHIDEvent:"), (void *)event);
        return;
    }

    /* Fallback 3: BKSHIDEventSendToFocusedProcess */
    if (fnBKSSendToFocused) {
        fnBKSSendToFocused(event);
        return;
    }

    touch_log("dispatch_event: no target");
}

static void send_touch(float x, float y, BOOL isDown, BOOL isMove, uint32_t finger) {
    uint64_t ts = mach_absolute_time();

    BOOL range = isDown || isMove;
    BOOL touch = isDown || isMove;
    float pressure = (isDown || isMove) ? 1.0f : 0.0f;

    uint32_t mask = kIOHIDDigitizerEventPosition;
    if (isDown || (!isDown && !isMove))
        mask |= kIOHIDDigitizerEventRange | kIOHIDDigitizerEventTouch;

    /* Parent digitizer event — MUST be Hand (1), not Finger (2).
     * _queue_handleEvent checks IOHIDEventGetChildren — Hand is the collection type. */
#define kIOHIDDigitizerTransducerTypeHand 1
    IOHIDEventRef parent = NULL;
    if (fnCreateDigitizerEvent) {
        parent = fnCreateDigitizerEvent(
            kCFAllocatorDefault, ts,
            kIOHIDDigitizerTransducerTypeHand,
            0, 0, mask, 0,
            x, y, 0,
            pressure, 0, 0,
            range, touch, 0);
    }

    /* Child finger event */
    IOHIDEventRef child = fnCreateFingerEvent(
        kCFAllocatorDefault, ts,
        finger, finger + 2,
        mask,
        x, y, 0,
        pressure, 0,
        range, touch, 0);

    if (parent && child && fnAppendEvent) {
        fnAppendEvent(parent, child, 0);

        /* Verify children exist */
        typedef CFArrayRef (*IOHIDEventGetChildrenFn)(IOHIDEventRef);
        IOHIDEventGetChildrenFn getChildren = (IOHIDEventGetChildrenFn)
            dlsym(RTLD_DEFAULT, "IOHIDEventGetChildren");
        if (getChildren) {
            CFArrayRef kids = getChildren(parent);
            touch_log("  parent children: %ld", kids ? CFArrayGetCount(kids) : -1);
        }

        dispatch_event(parent);
        CFRelease(child);
        CFRelease(parent);
    } else if (child) {
        touch_log("  WARNING: no parent — dispatching child only");
        dispatch_event(child);
        CFRelease(child);
        if (parent) CFRelease(parent);
    } else {
        touch_log("send_touch: event creation failed");
        if (parent) CFRelease(parent);
    }
}

/* ================================================================
 * Keyboard event
 * ================================================================ */

static void send_key(uint32_t usagePage, uint32_t usage, BOOL down) {
    if (!fnCreateKeyboardEvent) {
        touch_log("send_key: IOHIDEventCreateKeyboardEvent not available");
        return;
    }
    uint64_t ts = mach_absolute_time();
    IOHIDEventRef event = fnCreateKeyboardEvent(
        kCFAllocatorDefault, ts, usagePage, usage, down, 0);
    if (!event) {
        touch_log("send_key: event creation failed");
        return;
    }
    dispatch_event(event);
    CFRelease(event);
}

/* HID usage page 7 (keyboard) key codes for ASCII characters */
static void char_to_hid(char c, uint32_t *usage, BOOL *shift) {
    *shift = NO;
    if (c >= 'a' && c <= 'z') {
        *usage = 4 + (c - 'a');
    } else if (c >= 'A' && c <= 'Z') {
        *usage = 4 + (c - 'A');
        *shift = YES;
    } else if (c >= '1' && c <= '9') {
        *usage = 30 + (c - '1');
    } else if (c == '0') {
        *usage = 39;
    } else {
        switch (c) {
            case '\n': case '\r': *usage = 40; break;
            case '\t':            *usage = 43; break;
            case ' ':             *usage = 44; break;
            case '-':             *usage = 45; break;
            case '=':             *usage = 46; break;
            case '[':             *usage = 47; break;
            case ']':             *usage = 48; break;
            case '\\':            *usage = 49; break;
            case ';':             *usage = 51; break;
            case '\'':            *usage = 52; break;
            case '`':             *usage = 53; break;
            case ',':             *usage = 54; break;
            case '.':             *usage = 55; break;
            case '/':             *usage = 56; break;
            case '!':  *usage = 30; *shift = YES; break;
            case '@':  *usage = 31; *shift = YES; break;
            case '#':  *usage = 32; *shift = YES; break;
            case '$':  *usage = 33; *shift = YES; break;
            case '%':  *usage = 34; *shift = YES; break;
            case '^':  *usage = 35; *shift = YES; break;
            case '&':  *usage = 36; *shift = YES; break;
            case '*':  *usage = 37; *shift = YES; break;
            case '(':  *usage = 38; *shift = YES; break;
            case ')':  *usage = 39; *shift = YES; break;
            case '_':  *usage = 45; *shift = YES; break;
            case '+':  *usage = 46; *shift = YES; break;
            case '{':  *usage = 47; *shift = YES; break;
            case '}':  *usage = 48; *shift = YES; break;
            case '|':  *usage = 49; *shift = YES; break;
            case ':':  *usage = 51; *shift = YES; break;
            case '"':  *usage = 52; *shift = YES; break;
            case '~':  *usage = 53; *shift = YES; break;
            case '<':  *usage = 54; *shift = YES; break;
            case '>':  *usage = 55; *shift = YES; break;
            case '?':  *usage = 56; *shift = YES; break;
            default:   *usage = 0; break;
        }
    }
}

#define kHIDUsagePage_KeyboardOrKeypad 7
#define kHIDUsage_KeyboardLeftShift 0xE1

static void send_text(const char *text) {
    if (!text) return;
    touch_log("send_text: \"%s\" (%zu chars)", text, strlen(text));
    for (size_t i = 0; text[i]; i++) {
        uint32_t usage = 0;
        BOOL shift = NO;
        char_to_hid(text[i], &usage, &shift);
        if (usage == 0) {
            touch_log("  skip unknown char: 0x%02x", (unsigned char)text[i]);
            continue;
        }
        if (shift) {
            send_key(kHIDUsagePage_KeyboardOrKeypad, kHIDUsage_KeyboardLeftShift, YES);
            usleep(10000);
        }
        send_key(kHIDUsagePage_KeyboardOrKeypad, usage, YES);
        usleep(30000);
        send_key(kHIDUsagePage_KeyboardOrKeypad, usage, NO);
        if (shift) {
            usleep(10000);
            send_key(kHIDUsagePage_KeyboardOrKeypad, kHIDUsage_KeyboardLeftShift, NO);
        }
        usleep(30000);
    }
}

/* ================================================================
 * Command file polling
 * ================================================================ */

static int g_poll_count = 0;

static void poll_touch_cmd(void) {
    g_poll_count++;

    if (g_poll_count <= 3 || (g_poll_count % 300 == 0)) {
        touch_log("Poll #%d", g_poll_count);
    }

    NSString *cmdPath = [NSString stringWithUTF8String:g_cmd_path];
    if (![[NSFileManager defaultManager] fileExistsAtPath:cmdPath]) return;

    NSData *data = [NSData dataWithContentsOfFile:cmdPath];
    [[NSFileManager defaultManager] removeItemAtPath:cmdPath error:nil];

    if (!data || data.length == 0) return;

    touch_log("Processing %lu bytes", (unsigned long)data.length);

    NSString *content = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!content) return;

    NSArray *lines = [content componentsSeparatedByCharactersInSet:
                      [NSCharacterSet newlineCharacterSet]];

    for (NSString *line in lines) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:
                             [NSCharacterSet whitespaceCharacterSet]];
        if (trimmed.length == 0) continue;

        NSData *lineData = [trimmed dataUsingEncoding:NSUTF8StringEncoding];
        NSDictionary *cmd = [NSJSONSerialization JSONObjectWithData:lineData
                                                            options:0 error:nil];
        if (!cmd || ![cmd isKindOfClass:[NSDictionary class]]) continue;

        NSString *action = cmd[@"action"];
        if (!action) continue;

        /* Keyboard actions */
        if ([action isEqualToString:@"key"]) {
            NSNumber *pageNum = cmd[@"page"];
            NSNumber *usageNum = cmd[@"usage"];
            if (!pageNum || !usageNum) continue;
            touch_log("Key: page=%u usage=%u", pageNum.unsignedIntValue, usageNum.unsignedIntValue);
            send_key(pageNum.unsignedIntValue, usageNum.unsignedIntValue, YES);
            usleep(50000);
            send_key(pageNum.unsignedIntValue, usageNum.unsignedIntValue, NO);
            continue;
        }
        if ([action isEqualToString:@"text"]) {
            NSString *text = cmd[@"text"];
            if (!text) continue;
            send_text(text.UTF8String);
            continue;
        }

        /* Touch actions — require x/y */
        NSNumber *xNum = cmd[@"x"];
        NSNumber *yNum = cmd[@"y"];
        NSNumber *fingerNum = cmd[@"finger"];
        if (!xNum || !yNum) continue;
        float x = xNum.floatValue;
        float y = yNum.floatValue;
        uint32_t finger = fingerNum ? fingerNum.unsignedIntValue : 0;

        BOOL isDown = [action isEqualToString:@"down"];
        BOOL isMove = [action isEqualToString:@"move"];
        BOOL isUp = [action isEqualToString:@"up"];
        if (!isDown && !isMove && !isUp) continue;

        touch_log("Touch: %s x=%.1f y=%.1f f=%u", action.UTF8String, x, y, finger);
        send_touch(x, y, isDown, isMove, finger);

        if (isDown) usleep(150000); /* 150ms — UIKit needs time to register tap */
    }
}

/* ================================================================
 * Poll thread
 * ================================================================ */

static void *touch_poll_thread(void *arg) {
    (void)arg;
    usleep(500000); /* 500ms initial delay */
    while (1) {
        @autoreleasepool {
            poll_touch_cmd();
        }
        usleep(100000); /* 100ms */
    }
    return NULL;
}

/* ================================================================
 * Register virtual HID services via SimHIDVirtualServiceManager
 * ================================================================ */

static void register_virtual_hid_services(void) {
    touch_log("=== Registering virtual HID services ===");

    /* Skip VSM registration on iOS 10.x — ISCVirtualServiceManager connect crashes backboardd */
    NSString *runtimeVer = [[NSProcessInfo processInfo].environment
        objectForKey:@"SIMULATOR_RUNTIME_VERSION"];
    if (runtimeVer && [runtimeVer hasPrefix:@"10."]) {
        touch_log("Skipping VSM registration on iOS 10.x (ISC incompatible)");
        return;
    }

    /* Get backboardd's IOHIDEventSystem from BKHIDServiceManager */
    Class svcMgrCls = objc_getClass("BKHIDServiceManager");
    if (!svcMgrCls) {
        touch_log("BKHIDServiceManager not found — trying BKHIDSystemInterface");
        /* On iOS 10.x, might need different approach */
        /* Dump BK* classes for debugging */
        unsigned int classCount = 0;
        Class *allClasses = objc_copyClassList(&classCount);
        for (unsigned int i = 0; i < classCount; i++) {
            const char *name = class_getName(allClasses[i]);
            if (strncmp(name, "BK", 2) == 0 &&
                (strcasestr(name, "hid") || strcasestr(name, "service")))
                touch_log("  Class: %s", name);
        }
        free(allClasses);
        return;
    }

    id svcMgr = ((id(*)(id, SEL))objc_msgSend)(
        (id)svcMgrCls, sel_registerName("sharedInstance"));
    if (!svcMgr) {
        touch_log("BKHIDServiceManager.sharedInstance = nil");
        return;
    }
    touch_log("BKHIDServiceManager: %p", (__bridge void *)svcMgr);

    /* Extract _hidEventSystem ivar (raw pointer, not ObjC object) */
    void *eventSystem = NULL;
    Ivar esIvar = class_getInstanceVariable([svcMgr class], "_hidEventSystem");
    if (esIvar) {
        ptrdiff_t offset = ivar_getOffset(esIvar);
        eventSystem = *(void **)((uint8_t *)(__bridge void *)svcMgr + offset);
        touch_log("  _hidEventSystem: %p (offset %td)", eventSystem, offset);
    }

    if (!eventSystem) {
        /* Dump all ivars for debugging */
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList([svcMgr class], &count);
        touch_log("  BKHIDServiceManager ivars (%u):", count);
        for (unsigned int i = 0; i < count; i++) {
            const char *name = ivar_getName(ivars[i]);
            ptrdiff_t off = ivar_getOffset(ivars[i]);
            touch_log("    %s (offset %td)", name, off);
            if (strcasestr(name, "eventSystem") || strcasestr(name, "hidSystem")) {
                eventSystem = *(void **)((uint8_t *)(__bridge void *)svcMgr + off);
                touch_log("    → eventSystem: %p", eventSystem);
                if (eventSystem) break;
            }
        }
        free(ivars);
    }

    if (!eventSystem) {
        touch_log("Could not get IOHIDEventSystem from BKHIDServiceManager");
        /* Last resort: IOHIDEventSystemCreate (creates a new one) */
        typedef void *(*IOHIDEventSystemCreateFn)(CFAllocatorRef);
        IOHIDEventSystemCreateFn create = (IOHIDEventSystemCreateFn)
            dlsym(RTLD_DEFAULT, "IOHIDEventSystemCreate");
        if (create) {
            eventSystem = create(kCFAllocatorDefault);
            touch_log("  IOHIDEventSystemCreate: %p", eventSystem);
        }
    }

    if (!eventSystem) {
        touch_log("FATAL: No IOHIDEventSystem available");
        return;
    }

    /* Create SimHIDVirtualServiceManager (or ISCVirtualServiceManager on iOS 10.x) */
    Class vsmCls = objc_getClass("SimHIDVirtualServiceManager");
    if (!vsmCls) {
        vsmCls = objc_getClass("ISCVirtualServiceManager");
        touch_log("Trying ISCVirtualServiceManager: %p", vsmCls);
    }
    if (!vsmCls) {
        touch_log("No VirtualServiceManager class found — searching:");
        unsigned int classCount = 0;
        Class *allClasses = objc_copyClassList(&classCount);
        for (unsigned int i = 0; i < classCount; i++) {
            const char *name = class_getName(allClasses[i]);
            if (strcasestr(name, "Virtual") && strcasestr(name, "Service"))
                touch_log("  Class: %s", name);
        }
        free(allClasses);
        return;
    }

    touch_log("VirtualServiceManager class: %p (%s)", vsmCls, class_getName(vsmCls));

    /* List methods for debugging */
    unsigned int mcount = 0;
    Method *methods = class_copyMethodList(vsmCls, &mcount);
    touch_log("  methods (%u):", mcount);
    for (unsigned int i = 0; i < mcount; i++) {
        touch_log("    %s", sel_getName(method_getName(methods[i])));
    }
    free(methods);

    id vsm = ((id(*)(id, SEL))objc_msgSend)((id)vsmCls, sel_registerName("alloc"));
    SEL initSel = sel_registerName("initWithEventSystem:");
    if (![vsm respondsToSelector:initSel]) {
        touch_log("  does not respond to initWithEventSystem: — trying init");
        /* Try plain init or other init methods */
        vsm = ((id(*)(id, SEL))objc_msgSend)(vsm, sel_registerName("init"));
    } else {
        vsm = ((id(*)(id, SEL, void *))objc_msgSend)(vsm, initSel, eventSystem);
    }
    touch_log("SimHIDVirtualServiceManager: %p", (__bridge void *)vsm);

    if (vsm) {
        CFRetain((__bridge CFTypeRef)vsm);
        touch_log("Virtual HID services registered successfully!");

        /* Get mainScreenTouchService (SimHID) or mainDisplayTouchService (ISC) */
        id touchSvc = ((id(*)(id, SEL))objc_msgSend)(
            vsm, sel_registerName("mainScreenTouchService"));
        if (!touchSvc) {
            touchSvc = ((id(*)(id, SEL))objc_msgSend)(
                vsm, sel_registerName("mainDisplayTouchService"));
            touch_log("  mainDisplayTouchService (ISC fallback): %p", (__bridge void *)touchSvc);
        } else {
            touch_log("  mainScreenTouchService: %p", (__bridge void *)touchSvc);
        }

        if (touchSvc) {
            /* Dump methods */
            unsigned int scount = 0;
            Method *smethods = class_copyMethodList([touchSvc class], &scount);
            touch_log("  %s methods (%u):", class_getName([touchSvc class]), scount);
            for (unsigned int i = 0; i < scount; i++) {
                touch_log("    %s", sel_getName(method_getName(smethods[i])));
            }
            free(smethods);

            /* Check connected status (don't call connect — may crash) */
            SEL connectedSel = sel_registerName("connected");
            if ([touchSvc respondsToSelector:connectedSel]) {
                BOOL conn = ((BOOL(*)(id, SEL))objc_msgSend)(touchSvc, connectedSel);
                touch_log("  connected: %d", conn);
            }

            /* Check hidService */
            SEL hidSvcSel = sel_registerName("hidService");
            if ([touchSvc respondsToSelector:hidSvcSel]) {
                void *hs = ((void *(*)(id, SEL))objc_msgSend)(touchSvc, hidSvcSel);
                touch_log("  hidService: %p", hs);
            }

            /* Check dispatchEvent: */
            SEL dispSel = sel_registerName("dispatchEvent:");
            touch_log("  dispatchEvent: responds=%d",
                      [touchSvc respondsToSelector:dispSel]);

            /* Store globally */
            g_touch_service = touchSvc;
            CFRetain((__bridge CFTypeRef)g_touch_service);

            /* Extract raw IOHIDServiceRef */
            SEL hidSvcSel2 = sel_registerName("hidService");
            g_hid_service_ref = ((void *(*)(id, SEL))objc_msgSend)(touchSvc, hidSvcSel2);
            touch_log("  g_hid_service_ref: %p", g_hid_service_ref);

            /* Use the IOHIDEventSystem as the event client for dispatch.
             * BKHIDServiceManager's _hidEventSystem is actually an IOHIDEventSystemRef
             * which can be cast to IOHIDEventSystemClientRef for dispatch purposes. */
            g_event_client = (IOHIDEventSystemClientRef)eventSystem;
            touch_log("  g_event_client (from eventSystem): %p", g_event_client);
        }

        /* Also check allServices */
        id allSvcs = ((id(*)(id, SEL))objc_msgSend)(vsm, sel_registerName("allServices"));
        touch_log("  allServices: %p count=%lu", (__bridge void *)allSvcs,
                  (unsigned long)(allSvcs ? [allSvcs count] : 0));
    } else {
        touch_log("SimHIDVirtualServiceManager init returned nil");
    }

    touch_log("=== Virtual HID registration complete ===");
}

/* ================================================================
 * Constructor
 * ================================================================ */

__attribute__((constructor))
static void sim_touch_inject_init(void) {
    @autoreleasepool {
        NSString *home = NSHomeDirectory();
        NSString *tmpDir = [home stringByAppendingPathComponent:@"tmp"];
        [[NSFileManager defaultManager] createDirectoryAtPath:tmpDir
                                  withIntermediateDirectories:YES attributes:nil error:nil];

        /* Use separate file path so backboardd doesn't compete with SpringBoard's
         * UIA touch handler (which polls rosettasim_touch.json). */
        snprintf(g_cmd_path, sizeof(g_cmd_path), "%s/tmp/rosettasim_touch_bb.json",
                 home.UTF8String);
        snprintf(g_log_path, sizeof(g_log_path), "%s/tmp/rosettasim_touch_inject.log",
                 home.UTF8String);

        touch_log("=== sim_touch_inject loaded pid=%d ===", getpid());
        touch_log("cmd_path: %s", g_cmd_path);

        if (!resolve_symbols()) {
            touch_log("Disabled — symbol resolution failed");
            return;
        }

        /* Register virtual HID services after backboardd's HID system is fully initialized */
        dispatch_async(dispatch_get_main_queue(), ^{
            register_virtual_hid_services();
        });

        pthread_t pollThread;
        pthread_create(&pollThread, NULL, touch_poll_thread, NULL);
        pthread_detach(pollThread);

        touch_log("Poll thread started (100ms)");
    }
}
