/*
 * rosettasim_hid_manager.m — Custom HID System Manager for RosettaSim
 *
 * Loaded by SimulatorClient.framework via the SIMULATOR_HID_SYSTEM_MANAGER
 * environment variable. Provides a class conforming to the
 * SimulatorClientHIDSystemManager protocol so that
 * IndigoHIDSystemSpawnLoopback() succeeds.
 *
 * What SimulatorClient does:
 *   1. Reads SIMULATOR_HID_SYSTEM_MANAGER env var
 *   2. [NSBundle bundleWithPath:] → loads this bundle
 *   3. Gets principalClass → RosettaSimHIDManager
 *   4. Checks conformsToProtocol: SimulatorClientHIDSystemManager
 *   5. [[principalClass alloc] initUsingHIDService:hidEventSystem error:&error]
 *   6. Stores result in static hidSystemManager
 *   7. Returns YES if non-nil
 *
 * What SimulatorHIDFallbackSystem (Apple's built-in) does in init:
 *   - Creates ISCVirtualServiceManager with event system
 *   - bootstrap_look_up("IndigoHIDRegistrationPort")
 *   - Creates IOHIDEventSystemClient
 *   - Sets up dispatch_source for HID event mach port
 *   - Creates virtual IOHIDServices for touch, buttons, keyboard
 *
 * Our simpler approach:
 *   - Skip IndigoHIDRegistrationPort (we don't have it)
 *   - Create virtual IOHIDServices for touch and keyboard if possible
 *   - Return CADisplay objects from [CADisplay displays] for the displays method
 *   - Main goal: get IndigoHIDSystemSpawnLoopback to return YES
 *
 * Build: compiled as x86_64 .bundle against iOS 10.3 simulator SDK
 */

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <mach/mach.h>
#include <dlfcn.h>

/* IOKit/IOHIDEvent private API declarations */
typedef void *IOHIDEventSystemRef;
typedef void *IOHIDEventSystemClientRef;
typedef void *IOHIDServiceRef;
typedef void *IOHIDEventRef;

/* Function pointer types for dynamically-resolved IOKit HID APIs.
 * These are private symbols in IOKit.framework — we resolve them
 * at runtime via dlsym() to avoid crashes if they're not available. */
typedef IOHIDServiceRef (*IOHIDServiceCreateVirtualFunc)(
    CFAllocatorRef allocator,
    CFDictionaryRef properties
);
typedef void (*IOHIDEventSystemAddServiceFunc)(
    IOHIDEventSystemRef system,
    IOHIDServiceRef service
);

static IOHIDServiceCreateVirtualFunc fn_IOHIDServiceCreateVirtual = NULL;
static IOHIDEventSystemAddServiceFunc fn_IOHIDEventSystemAddService = NULL;

/* Bootstrap API — forward declared since <servers/bootstrap.h> is not
 * available in the iOS simulator SDK. Matches purple_fb_server.c. */
extern mach_port_t bootstrap_port;
extern kern_return_t bootstrap_look_up(mach_port_t bp, const char *name, mach_port_t *sp);

/* mach_msg_send may not be declared in the SDK headers either */
extern kern_return_t mach_msg_send(mach_msg_header_t *msg);

/* ================================================================
 * Protocol declaration
 * ================================================================ */

@protocol SimulatorClientHIDSystemManager <NSObject>
- (instancetype)initUsingHIDService:(void *)hidEventSystem error:(NSError **)error;
- (NSArray *)displays;
- (BOOL)hasTouchScreen;
- (BOOL)hasTouchScreenLofi;
- (BOOL)hasWheel;
- (NSString *)name;
- (NSString *)uniqueId;
@optional
- (id)interfaceCapabilities;
@end

/* ================================================================
 * RosettaSimHIDManager — principal class
 * ================================================================ */

@interface RosettaSimHIDManager : NSObject <SimulatorClientHIDSystemManager>
@property (nonatomic, assign) IOHIDEventSystemRef hidEventSystem;
@property (nonatomic, assign) IOHIDServiceRef touchService;
@property (nonatomic, assign) IOHIDServiceRef keyboardService;
@end

@implementation RosettaSimHIDManager

#pragma mark - Logging

static void hid_log(NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    NSLog(@"[RosettaSimHID] %@", msg);
    [msg release];
}

#pragma mark - SimulatorClientHIDSystemManager Protocol

- (instancetype)initUsingHIDService:(void *)hidEventSystem error:(NSError **)error {
    self = [super init];
    if (!self) return nil;

    _hidEventSystem = hidEventSystem;
    hid_log(@"initUsingHIDService: hidEventSystem=%p", hidEventSystem);

    /* Step 1: Create virtual IOHIDServices for touch and keyboard.
     *
     * SimulatorHIDFallback creates 3 services:
     *   - com.apple.SimulatorClient.MainDisplayButtonsService
     *   - com.apple.SimulatorClient.MainDisplayTouchService
     *   - com.apple.SimulatorClient.ExternalKeyboardService
     *
     * These use _IOHIDServiceCreateVirtual with HID usage page/usage
     * properties, then _IOHIDEventSystemAddService to register them.
     */
    /* Virtual HID service creation is deferred for now.
     *
     * _IOHIDServiceCreateVirtual has a complex 5-parameter signature:
     *   _IOHIDServiceCreateVirtual(allocator, identifier, callbackStruct, properties, context)
     * where callbackStruct is a struct of function pointers (open, close,
     * copyProperty, setProperty, setEventCallback, scheduleWithDispatchQueue,
     * unscheduleFromDispatchQueue, copyEvent). Getting this wrong crashes.
     *
     * The primary goal is getting IndigoHIDSystemSpawnLoopback to return YES,
     * which just needs a non-nil return from initUsingHIDService:. Virtual
     * HID services can be added once the display pipeline works. */
    hid_log(@"Virtual HID service creation deferred (complex API)");

    /* Step 2: Try IndigoHIDRegistrationPort lookup.
     *
     * The real SimulatorHIDFallback does bootstrap_look_up("IndigoHIDRegistrationPort")
     * and sends a registration message. Without launchd this will fail,
     * which is OK — our purple_fb_server shim handles this path. */
    mach_port_t regPort = MACH_PORT_NULL;
    kern_return_t kr = bootstrap_look_up(bootstrap_port, "IndigoHIDRegistrationPort", &regPort);
    if (kr == KERN_SUCCESS && regPort != MACH_PORT_NULL) {
        hid_log(@"Found IndigoHIDRegistrationPort: %u", regPort);
        [self registerWithIndigoPort:regPort];
    } else {
        hid_log(@"IndigoHIDRegistrationPort not found (kr=%d) — this is expected without launchd", kr);
    }

    hid_log(@"Initialization complete");
    return self;
}

- (NSArray *)displays {
    /* SimulatorHIDFallbackSystem does NOT implement its own displays method
     * in the binary. The protocol requires it, but the actual display objects
     * come from CAWindowServer via PurpleDisplay::open() which our
     * purple_fb_server.c already handles.
     *
     * Return [CADisplay displays] which is what the SimulatorHIDFallback's
     * internal code iterates through. If CADisplay isn't available yet,
     * return an empty array. */
    Class caDisplayClass = NSClassFromString(@"CADisplay");
    if (caDisplayClass) {
        SEL displaysSel = NSSelectorFromString(@"displays");
        if ([caDisplayClass respondsToSelector:displaysSel]) {
            NSArray *result = ((NSArray *(*)(id, SEL))objc_msgSend)((id)caDisplayClass, displaysSel);
            hid_log(@"displays: returning %lu CADisplay objects", (unsigned long)[result count]);
            return result;
        }
    }

    hid_log(@"displays: CADisplay not available, returning empty array");
    return @[];
}

- (BOOL)hasTouchScreen {
    return YES;
}

- (BOOL)hasTouchScreenLofi {
    return NO;
}

- (BOOL)hasWheel {
    return NO;
}

- (NSString *)name {
    return @"RosettaSimHIDManager";
}

- (NSString *)uniqueId {
    return @"rosettasim-hid-001";
}

- (id)interfaceCapabilities {
    return nil;
}

#pragma mark - Virtual HID Services

- (void)createVirtualServices {
    /* Create virtual touch service.
     *
     * HID Usage Pages (from IOHIDUsageTables.h):
     *   kHIDPage_Digitizer = 0x0D
     *   kHIDUsage_Dig_TouchScreen = 0x04
     *
     * SimulatorHIDFallback uses these properties:
     *   DeviceUsagePage, DeviceUsage, DeviceUsagePairs, PrimaryUsagePage,
     *   PrimaryUsage, Authenticated
     */
    NSDictionary *touchProps = @{
        @"PrimaryUsagePage": @(0x0D),   /* Digitizer */
        @"PrimaryUsage": @(0x04),       /* Touch Screen */
        @"DeviceUsagePage": @(0x0D),
        @"DeviceUsage": @(0x04),
        @"DeviceUsagePairs": @[@{@"DeviceUsagePage": @(0x0D), @"DeviceUsage": @(0x04)}],
        @"Authenticated": @YES
    };

    hid_log(@"Creating touch service with props: %@", touchProps);
    IOHIDServiceRef touchSvc = fn_IOHIDServiceCreateVirtual(
        kCFAllocatorDefault,
        (CFDictionaryRef)touchProps
    );

    if (touchSvc) {
        _touchService = touchSvc;
        hid_log(@"Touch service created: %p, adding to event system...", touchSvc);
        fn_IOHIDEventSystemAddService(_hidEventSystem, touchSvc);
        hid_log(@"Created and registered virtual touch service: %p", touchSvc);
    } else {
        hid_log(@"WARNING: Failed to create virtual touch service");
    }

    /* Create virtual keyboard service.
     *
     * HID Usage Pages:
     *   kHIDPage_GenericDesktop = 0x01
     *   kHIDUsage_GD_Keyboard = 0x06
     */
    NSDictionary *kbProps = @{
        @"PrimaryUsagePage": @(0x01),   /* Generic Desktop */
        @"PrimaryUsage": @(0x06),       /* Keyboard */
        @"DeviceUsagePage": @(0x01),
        @"DeviceUsage": @(0x06),
        @"DeviceUsagePairs": @[@{@"DeviceUsagePage": @(0x01), @"DeviceUsage": @(0x06)}],
        @"Authenticated": @YES
    };

    hid_log(@"Creating keyboard service...");
    IOHIDServiceRef kbSvc = fn_IOHIDServiceCreateVirtual(
        kCFAllocatorDefault,
        (CFDictionaryRef)kbProps
    );

    if (kbSvc) {
        _keyboardService = kbSvc;
        fn_IOHIDEventSystemAddService(_hidEventSystem, kbSvc);
        hid_log(@"Created and registered virtual keyboard service: %p", kbSvc);
    } else {
        hid_log(@"WARNING: Failed to create virtual keyboard service");
    }

    /* Create virtual buttons service (Home, Lock, Volume).
     *
     * HID Usage Pages:
     *   kHIDPage_Consumer = 0x0C
     *   kHIDUsage_Csmr_ConsumerControl = 0x01
     */
    NSDictionary *btnProps = @{
        @"PrimaryUsagePage": @(0x0C),   /* Consumer */
        @"PrimaryUsage": @(0x01),       /* Consumer Control */
        @"DeviceUsagePage": @(0x0C),
        @"DeviceUsage": @(0x01),
        @"DeviceUsagePairs": @[@{@"DeviceUsagePage": @(0x0C), @"DeviceUsage": @(0x01)}],
        @"Authenticated": @YES
    };

    hid_log(@"Creating buttons service...");
    IOHIDServiceRef btnSvc = fn_IOHIDServiceCreateVirtual(
        kCFAllocatorDefault,
        (CFDictionaryRef)btnProps
    );

    if (btnSvc) {
        fn_IOHIDEventSystemAddService(_hidEventSystem, btnSvc);
        hid_log(@"Created and registered virtual buttons service: %p", btnSvc);
    } else {
        hid_log(@"WARNING: Failed to create virtual buttons service");
    }
}

#pragma mark - IndigoHIDRegistrationPort

- (void)registerWithIndigoPort:(mach_port_t)regPort {
    /* The real SimulatorHIDFallback sends a registration message to
     * IndigoHIDRegistrationPort. The message format (from disassembly):
     *   header.msgh_bits = 0x1800001413 (complex, send+send_once)
     *   header.msgh_remote_port = regPort
     *   header.msgh_local_port = allocated receive port
     *   Sends a port descriptor (the receive port)
     *
     * The reply gives back a mach port that becomes the
     * dispatch_source for HID events.
     *
     * For now, just allocate a port and send the registration. */
    mach_port_t recvPort = MACH_PORT_NULL;
    kern_return_t kr = mach_port_allocate(mach_task_self(),
                                           MACH_PORT_RIGHT_RECEIVE,
                                           &recvPort);
    if (kr != KERN_SUCCESS) {
        hid_log(@"Failed to allocate receive port for registration: %d", kr);
        return;
    }

    /* Build registration message matching the format at offset 0x5417-0x543c
     * in the SimulatorHIDFallback disassembly:
     *   0x1800001413 = MACH_MSGH_BITS_COMPLEX | MACH_MSGH_BITS(
     *                    MACH_MSG_TYPE_COPY_SEND, MACH_MSG_TYPE_MAKE_SEND_ONCE) */
    struct {
        mach_msg_header_t header;
        mach_msg_body_t body;
        mach_msg_port_descriptor_t port_desc;
    } msg;
    memset(&msg, 0, sizeof(msg));

    msg.header.msgh_bits = MACH_MSGH_BITS_COMPLEX |
                           MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, MACH_MSG_TYPE_MAKE_SEND_ONCE);
    msg.header.msgh_size = sizeof(msg);
    msg.header.msgh_remote_port = regPort;
    msg.header.msgh_local_port = recvPort;

    msg.body.msgh_descriptor_count = 1;

    msg.port_desc.name = recvPort;
    msg.port_desc.disposition = MACH_MSG_TYPE_MAKE_SEND;
    msg.port_desc.type = MACH_MSG_PORT_DESCRIPTOR;

    kr = mach_msg_send(&msg.header);
    if (kr == KERN_SUCCESS) {
        hid_log(@"Sent registration to IndigoHIDRegistrationPort (recvPort=%u)", recvPort);
    } else {
        hid_log(@"Registration message failed: %d", kr);
        mach_port_mod_refs(mach_task_self(), recvPort, MACH_PORT_RIGHT_RECEIVE, -1);
    }

    /* Deallocate the regPort send right we looked up */
    mach_port_deallocate(mach_task_self(), regPort);
}

- (void)dealloc {
    hid_log(@"deallocating");
    /* IOHIDService cleanup would go here if needed.
     * The services are owned by the event system after AddService. */
    [super dealloc];
}

@end
