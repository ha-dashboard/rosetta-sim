/*
 * IndigoLegacyFramebufferServices.m
 *
 * CoreSimulator .simdeviceio plugin that provides PurpleFBServer
 * for legacy iOS runtimes (iOS 9.3, 10.x).
 *
 * When the sim boots, CoreSimulator loads this bundle and calls
 * simdeviceio_get_interface(). We register "PurpleFBServer" as a Mach
 * service in the sim's bootstrap namespace. backboardd's QuartzCore
 * (PurpleDisplay::open) does bootstrap_look_up("PurpleFBServer"),
 * then sends msg_id=4 (map_surface). We reply with framebuffer
 * dimensions and a memory entry port so it can vm_map the pixels.
 *
 * Protocol (from purple_fb_server.c):
 *   msg_id=4 (map_surface): 72-byte request → 72-byte complex reply
 *     with memory_entry port + dimensions
 *   msg_id=3 (flush_shmem): backboardd notifies a frame was rendered
 *
 * Links against: CoreSimDeviceIO.framework (for SimDeviceIOPortDescriptor,
 *   SimMachPort, and the SimDeviceIOBundleInterface protocol)
 */

#import <Foundation/Foundation.h>
#import <mach/mach.h>
#import <mach/vm_map.h>
#import <dispatch/dispatch.h>
#import <os/log.h>
#import <sys/mman.h>
#import <sys/stat.h>
#import <fcntl.h>

/* ================================================================
 * Forward-declare CoreSimDeviceIO classes and protocols.
 * We link against the framework but don't have headers.
 * ================================================================ */

@class SimMachPort;
@class SimDeviceIOPortDescriptor;

@protocol SimDeviceIOBundleInterface <NSObject>
- (void)bundleLoadedWithOptions:(NSDictionary *)options;
- (unsigned short)majorVersion;
- (unsigned short)minorVersion;
- (NSArray *)createDefaultPortsForDevice:(id)device error:(NSError **)error;
- (BOOL)device:(id)device didCreatePort:(id)port error:(NSError **)error;
- (void)deviceWillBoot:(id)device withOptions:(NSDictionary *)options error:(NSError **)error;
- (void)deviceDidBoot:(id)device;
- (void)deviceWillShutdown:(id)device;
- (void)deviceDidShutdown:(id)device;
- (NSArray *)dependsOnPortIdentifiers;
@end

@protocol SimDeviceIOPortDescriptorInterface <NSObject>
- (NSString *)portIdentifier;
- (id)state;
- (NSDictionary *)machServicesToRegister;
- (NSArray *)machServicesToUnregister;
- (NSArray *)dependsOnPortIdentifiers;
- (NSDictionary *)environment;
- (BOOL)connect:(id)port toDeviceIO:(id)deviceIO error:(NSError **)error;
- (BOOL)connect:(id)port toDeviceIO:(id)deviceIO options:(NSDictionary *)options error:(NSError **)error;
- (BOOL)disconnect:(id)port fromDeviceIO:(id)deviceIO error:(NSError **)error;
- (void)deviceWillBoot:(id)device withOptions:(NSDictionary *)options error:(NSError **)error;
- (void)deviceDidBoot:(id)device;
- (void)deviceWillShutdown:(id)device;
- (void)deviceDidShutdown:(id)device;
@end

/* SimMachPort — wraps mach_port_t, provided by CoreSimDeviceIO.framework */
@interface SimMachPort : NSObject
+ (instancetype)port;
+ (instancetype)portWithMachPort:(mach_port_t)port options:(NSDictionary *)options error:(NSError **)error;
- (mach_port_t)machPort;
@end

/* SimDeviceIOPortDescriptor — base class for port descriptors */
@interface SimDeviceIOPortDescriptor : NSObject
@end

/* ================================================================
 * PurpleFB protocol — message structures
 * Exactly matches purple_fb_server.c wire format.
 * ================================================================ */

#define PFB_PIXEL_WIDTH    750
#define PFB_PIXEL_HEIGHT   1334
#define PFB_POINT_WIDTH    375
#define PFB_POINT_HEIGHT   667
#define PFB_BYTES_PER_ROW  (PFB_PIXEL_WIDTH * 4)
#define PFB_SURFACE_SIZE   (PFB_BYTES_PER_ROW * PFB_PIXEL_HEIGHT)
#define PFB_PAGE_SIZE      4096
#define PFB_SURFACE_PAGES  ((PFB_SURFACE_SIZE + PFB_PAGE_SIZE - 1) / PFB_PAGE_SIZE)
#define PFB_SURFACE_ALLOC  (PFB_SURFACE_PAGES * PFB_PAGE_SIZE)

#define PFB_SERVICE_NAME   "PurpleFBServer"

/* mach_make_memory_entry_64 — not in public headers */
extern kern_return_t mach_make_memory_entry_64(
    vm_map_t target_task,
    memory_object_size_t *size,
    memory_object_offset_t offset,
    vm_prot_t permission,
    mach_port_t *object_handle,
    mem_entry_name_port_t parent_entry
);

/* Request from PurpleDisplay::map_surface (72 bytes) */
typedef struct {
    mach_msg_header_t header;       /* 24 bytes */
    uint8_t           body[48];     /* padding to 72 total */
} PurpleFBRequest;

/* Reply to map_surface (72 bytes, complex message with port descriptor) */
#pragma pack(4)
typedef struct {
    mach_msg_header_t          header;          /* 24 bytes, offset 0 */
    mach_msg_body_t            body;            /*  4 bytes, offset 24 */
    mach_msg_port_descriptor_t port_desc;       /* 12 bytes, offset 28 */
    uint32_t                   memory_size;     /*  4 bytes, offset 40 */
    uint32_t                   stride;          /*  4 bytes, offset 44 */
    uint32_t                   unknown1;        /*  4 bytes, offset 48 */
    uint32_t                   unknown2;        /*  4 bytes, offset 52 */
    uint32_t                   pixel_width;     /*  4 bytes, offset 56 */
    uint32_t                   pixel_height;    /*  4 bytes, offset 60 */
    uint32_t                   point_width;     /*  4 bytes, offset 64 */
    uint32_t                   point_height;    /*  4 bytes, offset 68 */
} PurpleFBReply;
#pragma pack()

_Static_assert(sizeof(PurpleFBRequest) == 72, "Request must be 72 bytes");
_Static_assert(sizeof(PurpleFBReply) == 72, "Reply must be 72 bytes");

static os_log_t sLog;

/* ================================================================
 * PurpleFBDescriptor — port descriptor for PurpleFBServer
 * ================================================================ */

@interface PurpleFBDescriptor : SimDeviceIOPortDescriptor <SimDeviceIOPortDescriptorInterface>

@property (nonatomic, strong) SimMachPort *servicePort;
@property (nonatomic, strong) dispatch_queue_t receiveQueue;
@property (nonatomic, strong) dispatch_source_t receiveSource;

@end

@implementation PurpleFBDescriptor {
    mach_port_t     _memoryEntry;
    vm_address_t    _surfaceAddr;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _memoryEntry = MACH_PORT_NULL;
        _surfaceAddr = 0;
        [self createSurface];
    }
    return self;
}

- (void)dealloc {
    if (_receiveSource) {
        dispatch_source_cancel(_receiveSource);
    }
    if (_surfaceAddr) {
        vm_deallocate(mach_task_self(), _surfaceAddr, PFB_SURFACE_ALLOC);
    }
    if (_memoryEntry != MACH_PORT_NULL) {
        mach_port_deallocate(mach_task_self(), _memoryEntry);
    }
}

#pragma mark - Surface allocation

- (void)createSurface {
    kern_return_t kr;

    kr = vm_allocate(mach_task_self(), &_surfaceAddr, PFB_SURFACE_ALLOC, VM_FLAGS_ANYWHERE);
    if (kr != KERN_SUCCESS) {
        os_log_error(sLog, "vm_allocate failed: %{public}s (%d)", mach_error_string(kr), kr);
        return;
    }

    /* Fill with opaque black (BGRA: 0,0,0,0xFF) */
    memset((void *)_surfaceAddr, 0, PFB_SURFACE_ALLOC);
    uint8_t *pixels = (uint8_t *)_surfaceAddr;
    for (uint32_t i = 0; i < PFB_PIXEL_WIDTH * PFB_PIXEL_HEIGHT; i++) {
        pixels[i * 4 + 3] = 0xFF;
    }

    /* Create memory entry for vm_map sharing */
    memory_object_size_t entry_size = PFB_SURFACE_ALLOC;
    kr = mach_make_memory_entry_64(
        mach_task_self(),
        &entry_size,
        (memory_object_offset_t)_surfaceAddr,
        VM_PROT_READ | VM_PROT_WRITE,
        &_memoryEntry,
        MACH_PORT_NULL
    );
    if (kr != KERN_SUCCESS) {
        os_log_error(sLog, "mach_make_memory_entry_64 failed: %{public}s (%d)",
                     mach_error_string(kr), kr);
        vm_deallocate(mach_task_self(), _surfaceAddr, PFB_SURFACE_ALLOC);
        _surfaceAddr = 0;
        return;
    }

    os_log(sLog, "Surface: %ux%u, %u bytes, mem_entry=0x%x",
           PFB_PIXEL_WIDTH, PFB_PIXEL_HEIGHT, PFB_SURFACE_ALLOC, _memoryEntry);
}

#pragma mark - SimDeviceIOPortDescriptorInterface

- (NSString *)portIdentifier {
    return @"PurpleFBServer";
}

- (id)state {
    return nil;
}

- (NSDictionary *)machServicesToRegister {
    SimMachPort *port = [SimMachPort port];
    if (!port) {
        os_log_error(sLog, "Failed to allocate SimMachPort");
        return nil;
    }
    _servicePort = port;
    os_log(sLog, "machServicesToRegister: %s -> 0x%x",
           PFB_SERVICE_NAME, [port machPort]);
    return @{ @(PFB_SERVICE_NAME): port };
}

- (NSArray *)machServicesToUnregister {
    return @[ @(PFB_SERVICE_NAME) ];
}

- (NSArray *)dependsOnPortIdentifiers {
    return @[];
}

- (NSDictionary *)environment {
    return nil;
}

- (BOOL)connect:(id)port toDeviceIO:(id)deviceIO error:(NSError **)error {
    os_log(sLog, "connect:toDeviceIO:");
    return YES;
}

- (BOOL)connect:(id)port toDeviceIO:(id)deviceIO options:(NSDictionary *)options error:(NSError **)error {
    os_log(sLog, "connect:toDeviceIO:options:");
    return YES;
}

- (BOOL)disconnect:(id)port fromDeviceIO:(id)deviceIO error:(NSError **)error {
    os_log(sLog, "disconnect:fromDeviceIO:");
    return YES;
}

#pragma mark - Lifecycle

- (void)deviceWillBoot:(id)device withOptions:(NSDictionary *)options error:(NSError **)error {
    os_log(sLog, "deviceWillBoot: setting up mach receive");
    [self setupReceiveSource];
}

- (void)deviceDidBoot:(id)device {
    os_log(sLog, "deviceDidBoot: PurpleFBServer ready");
}

- (void)deviceWillShutdown:(id)device {
    os_log(sLog, "deviceWillShutdown");
    if (_receiveSource) {
        dispatch_source_cancel(_receiveSource);
        _receiveSource = nil;
    }
}

- (void)deviceDidShutdown:(id)device {
    os_log(sLog, "deviceDidShutdown");
}

#pragma mark - Mach message handling

- (void)setupReceiveSource {
    if (!_servicePort) {
        os_log_error(sLog, "No service port");
        return;
    }

    mach_port_t port = [_servicePort machPort];

    _receiveQueue = dispatch_queue_create(
        "com.rosetta.PurpleFBServer.receive",
        dispatch_queue_attr_make_with_autorelease_frequency(
            DISPATCH_QUEUE_SERIAL, DISPATCH_AUTORELEASE_FREQUENCY_WORK_ITEM));

    _receiveSource = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_MACH_RECV, port, 0, _receiveQueue);

    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(_receiveSource, ^{
        [weakSelf handleReceive];
    });

    dispatch_source_set_cancel_handler(_receiveSource, ^{
        os_log(sLog, "Receive source cancelled");
    });

    dispatch_activate(_receiveSource);
    os_log(sLog, "Listening on port 0x%x", port);
}

- (void)handleReceive {
    /*
     * Receive a PurpleFB message. Messages are exactly 72 bytes.
     * Use a larger buffer in case of unexpected messages.
     */
    union {
        PurpleFBRequest req;
        uint8_t         raw[4096];
    } buffer;

    mach_msg_header_t *hdr = &buffer.req.header;
    mach_port_t port = [_servicePort machPort];

    kern_return_t kr = mach_msg(
        hdr,
        MACH_RCV_MSG | MACH_RCV_LARGE,
        0,
        sizeof(buffer),
        port,
        MACH_MSG_TIMEOUT_NONE,
        MACH_PORT_NULL);

    if (kr != KERN_SUCCESS) {
        os_log_error(sLog, "mach_msg recv failed: 0x%x %{public}s", kr, mach_error_string(kr));
        return;
    }

    os_log(sLog, "Received: id=%u size=%u remote=0x%x local=0x%x",
           hdr->msgh_id, hdr->msgh_size,
           hdr->msgh_remote_port, hdr->msgh_local_port);

    mach_port_t reply_port = hdr->msgh_remote_port;

    if (hdr->msgh_id == 4 && reply_port != MACH_PORT_NULL) {
        /* msg_id=4: map_surface — PurpleDisplay wants framebuffer info */
        [self handleMapSurface:reply_port];
    } else if (hdr->msgh_id == 3) {
        /* msg_id=3: flush_shmem — frame rendered notification */
        os_log(sLog, "flush_shmem received (frame rendered)");
        /* Future: copy pixels to shared memory for host display */
    } else {
        os_log(sLog, "Unknown msg_id=%u (ignoring)", hdr->msgh_id);
    }
}

- (void)handleMapSurface:(mach_port_t)replyPort {
    os_log(sLog, "map_surface request from reply_port=0x%x", replyPort);

    if (_memoryEntry == MACH_PORT_NULL) {
        os_log_error(sLog, "No memory entry — surface not allocated");
        /* Send a simple (non-complex) reply so backboardd doesn't hang */
        PurpleFBReply reply;
        memset(&reply, 0, sizeof(reply));
        reply.header.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_MOVE_SEND_ONCE, 0);
        reply.header.msgh_size = sizeof(PurpleFBReply);
        reply.header.msgh_remote_port = replyPort;
        reply.header.msgh_local_port = MACH_PORT_NULL;
        reply.header.msgh_id = 4;
        mach_msg(&reply.header, MACH_SEND_MSG, sizeof(PurpleFBReply),
                 0, MACH_PORT_NULL, MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL);
        return;
    }

    /* Build the complex reply with memory entry port + dimensions */
    PurpleFBReply reply;
    memset(&reply, 0, sizeof(reply));

    reply.header.msgh_bits = MACH_MSGH_BITS_COMPLEX |
                             MACH_MSGH_BITS(MACH_MSG_TYPE_MOVE_SEND_ONCE, 0);
    reply.header.msgh_size = sizeof(PurpleFBReply);
    reply.header.msgh_remote_port = replyPort;
    reply.header.msgh_local_port = MACH_PORT_NULL;
    reply.header.msgh_id = 4;

    reply.body.msgh_descriptor_count = 1;

    reply.port_desc.name = _memoryEntry;
    reply.port_desc.pad1 = 0;
    reply.port_desc.pad2 = 0;
    reply.port_desc.disposition = MACH_MSG_TYPE_COPY_SEND;
    reply.port_desc.type = MACH_MSG_PORT_DESCRIPTOR;

    reply.memory_size = PFB_SURFACE_ALLOC;
    reply.stride = PFB_BYTES_PER_ROW;
    reply.unknown1 = 0;
    reply.unknown2 = 0;
    reply.pixel_width = PFB_PIXEL_WIDTH;
    reply.pixel_height = PFB_PIXEL_HEIGHT;
    reply.point_width = PFB_POINT_WIDTH;
    reply.point_height = PFB_POINT_HEIGHT;

    kern_return_t kr = mach_msg(
        &reply.header,
        MACH_SEND_MSG,
        sizeof(PurpleFBReply),
        0,
        MACH_PORT_NULL,
        MACH_MSG_TIMEOUT_NONE,
        MACH_PORT_NULL);

    if (kr != KERN_SUCCESS) {
        os_log_error(sLog, "map_surface reply failed: %{public}s (%d)",
                     mach_error_string(kr), kr);
        /* Try non-complex fallback */
        memset(&reply, 0, sizeof(reply));
        reply.header.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_MOVE_SEND_ONCE, 0);
        reply.header.msgh_size = sizeof(PurpleFBReply);
        reply.header.msgh_remote_port = replyPort;
        reply.header.msgh_local_port = MACH_PORT_NULL;
        reply.header.msgh_id = 4;
        mach_msg(&reply.header, MACH_SEND_MSG, sizeof(PurpleFBReply),
                 0, MACH_PORT_NULL, MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL);
        os_log(sLog, "Sent fallback non-complex reply");
    } else {
        os_log(sLog, "Replied: %ux%u px, %ux%u pt, %u bytes, mem=0x%x",
               PFB_PIXEL_WIDTH, PFB_PIXEL_HEIGHT,
               PFB_POINT_WIDTH, PFB_POINT_HEIGHT,
               PFB_SURFACE_ALLOC, _memoryEntry);
    }
}

@end

/* ================================================================
 * LegacyFBBundleInterface — bundle-level interface
 * ================================================================ */

@interface LegacyFBBundleInterface : NSObject <SimDeviceIOBundleInterface>
@end

@implementation LegacyFBBundleInterface

- (unsigned short)majorVersion { return 1; }
- (unsigned short)minorVersion { return 0; }

- (void)bundleLoadedWithOptions:(NSDictionary *)options {
    os_log(sLog, "IndigoLegacyFramebufferServices loaded");
}

- (NSArray *)createDefaultPortsForDevice:(id)device error:(NSError **)error {
    os_log(sLog, "createDefaultPortsForDevice:");
    PurpleFBDescriptor *desc = [[PurpleFBDescriptor alloc] init];
    if (!desc) {
        if (error) {
            *error = [NSError errorWithDomain:@"com.rosetta.LegacyFramebuffer"
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey:
                                                    @"Failed to create PurpleFBDescriptor"}];
        }
        return nil;
    }
    return @[desc];
}

- (BOOL)device:(id)device didCreatePort:(id)port error:(NSError **)error {
    os_log(sLog, "device:didCreatePort:");
    return YES;
}

- (void)deviceWillBoot:(id)device withOptions:(NSDictionary *)options error:(NSError **)error {
    os_log(sLog, "deviceWillBoot");
}

- (void)deviceDidBoot:(id)device {
    os_log(sLog, "deviceDidBoot");
}

- (void)deviceWillShutdown:(id)device {
    os_log(sLog, "deviceWillShutdown");
}

- (void)deviceDidShutdown:(id)device {
    os_log(sLog, "deviceDidShutdown");
}

- (NSArray *)dependsOnPortIdentifiers {
    return @[];
}

@end

/* ================================================================
 * Plugin entry point
 * ================================================================ */

__attribute__((visibility("default")))
BOOL simdeviceio_get_interface(id *outInterface) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sLog = os_log_create("com.rosetta.LegacyFramebuffer", "Plugin");
    });

    os_log(sLog, "simdeviceio_get_interface called");

    if (!outInterface) return NO;
    *outInterface = [[LegacyFBBundleInterface alloc] init];
    return (*outInterface != nil);
}
