/*
 * LegacyFBDescriptor.m
 *
 * Implements the legacy framebuffer server port descriptor.
 * When the sim-side backboardd connects to our Mach service, we:
 *   1. Receive the SystemCheckin message
 *   2. Reply with display properties + mode
 *   3. Create an IOSurface for the framebuffer
 *   4. Send IOSurface port handle + swapchain info
 *   5. Handle present/cancel messages from the sim
 */

#import "LegacyFBDescriptor.h"
#import "SimFramebufferProtocol.h"
#import <mach/mach.h>
#import <IOSurface/IOSurface.h>
#import <os/log.h>

/*
 * The Mach service name the sim-side SimFramebuffer.framework connects to.
 * Confirmed from strings in the sim-side binary.
 */
static NSString *const kFramebufferServiceName = @"com.apple.CoreSimulator.SimFramebufferServer";

static os_log_t sLog;

#pragma mark - SimMachPort forward declarations

/*
 * We link against CoreSimDeviceIO.framework which provides SimMachPort.
 * Declare the methods we need.
 */
@interface SimMachPort : NSObject
+ (instancetype)port;
+ (instancetype)portWithMachPort:(mach_port_t)port options:(NSDictionary *)options error:(NSError **)error;
- (instancetype)initWithMachPort:(mach_port_t)port options:(NSDictionary *)options error:(NSError **)error;
- (mach_port_t)machPort;
@end

@interface SimDeviceIOPortDescriptor : NSObject
@end

@implementation LegacyFBDescriptor {
    mach_port_t _clientPort;    /* send right to the client's reply port */
    uint32_t    _nextDisplayID;
    uint32_t    _nextSwapchainID;
}

+ (void)initialize {
    if (self == [LegacyFBDescriptor class]) {
        sLog = os_log_create("com.rosetta.LegacyFramebuffer", "Descriptor");
    }
}

- (instancetype)initWithDevice:(id)device error:(NSError **)error {
    self = [super init];
    if (self) {
        _serviceName = kFramebufferServiceName;
        _displayWidth = 750;
        _displayHeight = 1334;
        _displayScale = 2;
        _nextDisplayID = 1;
        _nextSwapchainID = 1;
        _clientPort = MACH_PORT_NULL;

        os_log(sLog, "Initialized LegacyFBDescriptor: %{public}@ (%ux%u @%ux)",
               _serviceName, _displayWidth, _displayHeight, _displayScale);
    }
    return self;
}

- (void)dealloc {
    if (_framebufferSurface) {
        CFRelease(_framebufferSurface);
        _framebufferSurface = NULL;
    }
    if (_receiveSource) {
        dispatch_source_cancel(_receiveSource);
    }
}

#pragma mark - SimDeviceIOPortDescriptorInterface

- (NSString *)portIdentifier {
    return @"com.apple.CoreSimulator.Framebuffer.LegacyFB";
}

- (id /* SimDeviceIOPortDescriptorState */)state {
    /* Return nil; the base class handles state tracking */
    return nil;
}

- (NSDictionary *)machServicesToRegister {
    /*
     * Allocate a new Mach receive right and wrap it in a SimMachPort.
     * CoreSimulator will register this port under kFramebufferServiceName
     * in the sim's bootstrap namespace.
     */
    SimMachPort *port = [SimMachPort port];
    if (!port) {
        os_log_error(sLog, "Failed to create SimMachPort for framebuffer service");
        return nil;
    }

    _servicePort = port;

    os_log(sLog, "machServicesToRegister: %{public}@ -> port 0x%x",
           _serviceName, [port machPort]);

    return @{ _serviceName: port };
}

- (NSArray *)machServicesToUnregister {
    return @[ _serviceName ];
}

- (NSArray *)dependsOnPortIdentifiers {
    return @[];
}

- (NSDictionary *)environment {
    return nil;
}

#pragma mark - Lifecycle

- (void)deviceWillBoot:(id)device withOptions:(NSDictionary *)options error:(NSError **)error {
    os_log(sLog, "deviceWillBoot: setting up receive source");
    [self setupReceiveSource];
}

- (void)deviceDidBoot:(id)device {
    os_log(sLog, "deviceDidBoot: framebuffer server ready");
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
    _clientPort = MACH_PORT_NULL;
}

#pragma mark - Connection Handling

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

#pragma mark - Mach Message Receive

- (void)setupReceiveSource {
    if (!_servicePort) {
        os_log_error(sLog, "No service port; cannot set up receive source");
        return;
    }

    mach_port_t port = [_servicePort machPort];

    _receiveQueue = dispatch_queue_create(
        "com.rosetta.LegacyFramebuffer.receive",
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

    os_log(sLog, "Receive source active on port 0x%x", port);
}

- (void)handleReceive {
    /*
     * Receive a Mach message on our service port.
     * The message may be a simple message or a complex message with OOL ports.
     */
    union {
        SimFramebufferMessage   complex;
        SimFramebufferSimpleMessage simple;
        uint8_t                 raw[4096];
    } buffer;

    mach_msg_header_t *hdr = (mach_msg_header_t *)&buffer;
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
        os_log_error(sLog, "mach_msg receive failed: 0x%x", kr);
        return;
    }

    os_log(sLog, "Received message: id=0x%x size=%u local=0x%x remote=0x%x bits=0x%x",
           hdr->msgh_id, hdr->msgh_size,
           hdr->msgh_local_port, hdr->msgh_remote_port,
           hdr->msgh_bits);

    /*
     * Determine message type.
     * For the initial connection, the sim sends a checkin message.
     * We need to parse the SimFramebufferMessageData to find the struct_type.
     */

    /* Save the client's reply port */
    if (hdr->msgh_remote_port != MACH_PORT_NULL) {
        _clientPort = hdr->msgh_remote_port;
        os_log(sLog, "Saved client reply port: 0x%x", _clientPort);
    }

    /*
     * Try to find the SimFramebufferMessageData in the received buffer.
     * For simple messages (no OOL), it follows right after the header.
     * For complex messages, it follows after the body + descriptors.
     */
    SimFramebufferMessageData *data = NULL;
    size_t dataOffset;

    if (hdr->msgh_bits & MACH_MSGH_BITS_COMPLEX) {
        /* Complex message: skip body + port descriptors */
        mach_msg_body_t *body = (mach_msg_body_t *)(hdr + 1);
        os_log(sLog, "Complex message with %u descriptors", body->msgh_descriptor_count);
        dataOffset = sizeof(mach_msg_header_t) + sizeof(mach_msg_body_t) +
                     body->msgh_descriptor_count * sizeof(mach_msg_port_descriptor_t);
    } else {
        /* Simple message: data follows header directly */
        dataOffset = sizeof(mach_msg_header_t);
    }

    if (dataOffset + sizeof(SimFramebufferMessageData) <= hdr->msgh_size) {
        data = (SimFramebufferMessageData *)((uint8_t *)hdr + dataOffset);
    }

    if (data) {
        os_log(sLog, "Message data: magic=0x%llx struct_type=%u",
               data->magic, data->struct_type);
        [self handleMessageData:data header:hdr];
    } else {
        os_log(sLog, "Message has no recognizable SimFramebufferMessageData (size=%u, offset=%zu)",
               hdr->msgh_size, dataOffset);
        /* Still try to respond to the checkin if we got a reply port */
        if (_clientPort != MACH_PORT_NULL) {
            os_log(sLog, "Treating as initial connection, sending display properties");
            [self sendDisplayConfiguration];
        }
    }
}

- (void)handleMessageData:(SimFramebufferMessageData *)data
                   header:(mach_msg_header_t *)hdr
{
    switch (data->struct_type) {
        case kSimStructSystemCheckin:
            os_log(sLog, "SystemCheckin: version=%u identifier='%s'",
                   data->payload.checkin.version,
                   data->payload.checkin.identifier);
            [self handleCheckin:data header:hdr];
            break;

        case kSimStructSwapchainPresent:
            os_log(sLog, "SwapchainPresent: swapchain=%llu surface=%llu",
                   data->payload.swapchain_present.swapchain_id,
                   data->payload.swapchain_present.surface_id);
            [self handlePresent:data header:hdr];
            break;

        case kSimStructSwapchainCancel:
            os_log(sLog, "SwapchainCancel: display=%u swapchain=%u",
                   data->payload.swapchain_cancel.display_id,
                   data->payload.swapchain_cancel.swapchain_id);
            break;

        default:
            os_log(sLog, "Unhandled struct_type=%u", data->struct_type);
            break;
    }
}

#pragma mark - Protocol Handlers

- (void)handleCheckin:(SimFramebufferMessageData *)data
               header:(mach_msg_header_t *)hdr
{
    /*
     * Client checked in. Send back:
     *   1. CheckinReply
     *   2. DisplayProperties
     *   3. DisplayMode
     *   4. DisplaySwapchain + IOSurface handle
     */
    os_log(sLog, "Handling checkin, will send display configuration");
    [self sendDisplayConfiguration];
}

- (void)sendDisplayConfiguration {
    if (_clientPort == MACH_PORT_NULL) {
        os_log_error(sLog, "No client port, cannot send display configuration");
        return;
    }

    /*
     * Step 1: Create the IOSurface for the framebuffer
     */
    [self createFramebufferSurface];

    /*
     * Step 2: Build and send a message with display properties + swapchain + IOSurface
     *
     * The real protocol sends multiple structs in sequence within a single message.
     * For our initial implementation, we send a complex message containing:
     *   - DisplayProperties (describing the screen)
     *   - DisplayMode (current mode)
     *   - DisplaySwapchain (swapchain info)
     *   - IOSurface port as OOL descriptor
     */

    /* First: send display properties as a simple message */
    [self sendDisplayProperties];

    /* Then: send display mode */
    [self sendDisplayMode];

    /* Then: send swapchain with IOSurface */
    [self sendSwapchainWithSurface];
}

- (void)createFramebufferSurface {
    if (_framebufferSurface) {
        CFRelease(_framebufferSurface);
    }

    NSDictionary *properties = @{
        (id)kIOSurfaceWidth:            @(_displayWidth),
        (id)kIOSurfaceHeight:           @(_displayHeight),
        (id)kIOSurfaceBytesPerElement:  @(4),
        (id)kIOSurfacePixelFormat:      @('BGRA'),
        (id)kIOSurfaceBytesPerRow:      @(_displayWidth * 4),
        (id)kIOSurfaceAllocSize:        @(_displayWidth * _displayHeight * 4),
    };

    _framebufferSurface = IOSurfaceCreate((__bridge CFDictionaryRef)properties);
    if (!_framebufferSurface) {
        os_log_error(sLog, "Failed to create IOSurface %ux%u", _displayWidth, _displayHeight);
        return;
    }

    /* Fill with a visible color (dark blue) so we can verify it's working */
    IOSurfaceLock(_framebufferSurface, 0, NULL);
    uint32_t *pixels = (uint32_t *)IOSurfaceGetBaseAddress(_framebufferSurface);
    size_t totalPixels = (size_t)_displayWidth * _displayHeight;
    for (size_t i = 0; i < totalPixels; i++) {
        pixels[i] = 0xFF802020; /* BGRA: dark blue, full alpha */
    }
    IOSurfaceUnlock(_framebufferSurface, 0, NULL);

    os_log(sLog, "Created IOSurface: %ux%u, id=%u",
           _displayWidth, _displayHeight, IOSurfaceGetID(_framebufferSurface));
}

- (void)sendDisplayProperties {
    SimFramebufferSimpleMessage msg = {};
    msg.hdr.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0);
    msg.hdr.msgh_size = sizeof(msg);
    msg.hdr.msgh_remote_port = _clientPort;
    msg.hdr.msgh_local_port = MACH_PORT_NULL;
    msg.hdr.msgh_id = 0; /* TODO: determine correct msgh_id */

    msg.data.magic = SIM_MESSAGE_DATA_MAGIC;
    msg.data.struct_type = kSimStructDisplayProperties;

    SimDisplayProperties *props = &msg.data.payload.display_properties;
    strlcpy(props->name, "Default", sizeof(props->name));
    strlcpy(props->screen_type, "main", sizeof(props->screen_type));
    props->unique_id = 1;
    props->seed = 1;
    props->display_id = _nextDisplayID;
    props->pixel_size.width = _displayWidth;
    props->pixel_size.height = _displayHeight;
    props->canvas_size.width = _displayWidth;
    props->canvas_size.height = _displayHeight;
    props->power_state = 1; /* on */
    props->dot_pitch = 326; /* iPhone 6 PPI */
    props->ui_orientation = 0;
    props->screen_id = 1;

    kern_return_t kr = mach_msg(
        &msg.hdr,
        MACH_SEND_MSG,
        sizeof(msg),
        0,
        MACH_PORT_NULL,
        MACH_MSG_TIMEOUT_NONE,
        MACH_PORT_NULL);

    if (kr != KERN_SUCCESS) {
        os_log_error(sLog, "Failed to send DisplayProperties: 0x%x", kr);
    } else {
        os_log(sLog, "Sent DisplayProperties: %ux%u display_id=%u",
               _displayWidth, _displayHeight, _nextDisplayID);
    }
}

- (void)sendDisplayMode {
    SimFramebufferSimpleMessage msg = {};
    msg.hdr.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0);
    msg.hdr.msgh_size = sizeof(msg);
    msg.hdr.msgh_remote_port = _clientPort;
    msg.hdr.msgh_local_port = MACH_PORT_NULL;
    msg.hdr.msgh_id = 0;

    msg.data.magic = SIM_MESSAGE_DATA_MAGIC;
    msg.data.struct_type = kSimStructDisplayMode;

    SimDisplayMode *mode = &msg.data.payload.display_mode;
    mode->display_id = _nextDisplayID;
    mode->size.width = _displayWidth;
    mode->size.height = _displayHeight;
    mode->pixel_format = 0; /* BGRA8888 */
    mode->colorspace = 0;   /* sRGB */
    mode->hdr_mode = 0;     /* off */
    mode->refresh_rate = 60;
    mode->flags = 3;        /* native | preferred */
    mode->size_rule = 0;    /* exact */

    kern_return_t kr = mach_msg(
        &msg.hdr,
        MACH_SEND_MSG,
        sizeof(msg),
        0,
        MACH_PORT_NULL,
        MACH_MSG_TIMEOUT_NONE,
        MACH_PORT_NULL);

    if (kr != KERN_SUCCESS) {
        os_log_error(sLog, "Failed to send DisplayMode: 0x%x", kr);
    } else {
        os_log(sLog, "Sent DisplayMode: %ux%u @%uHz",
               _displayWidth, _displayHeight, mode->refresh_rate);
    }
}

- (void)sendSwapchainWithSurface {
    if (!_framebufferSurface) {
        os_log_error(sLog, "No framebuffer surface to send");
        return;
    }

    /*
     * Send a complex message with:
     *   - OOL port descriptor carrying the IOSurface mach port
     *   - SimDisplaySwapchain data
     */
    mach_port_t surfacePort = IOSurfaceCreateMachPort(_framebufferSurface);
    if (surfacePort == MACH_PORT_NULL) {
        os_log_error(sLog, "Failed to create IOSurface mach port");
        return;
    }

    struct {
        mach_msg_header_t           hdr;
        mach_msg_body_t             body;
        mach_msg_port_descriptor_t  surface_desc;
        SimFramebufferMessageData   data;
    } msg = {};

    msg.hdr.msgh_bits = MACH_MSGH_BITS_COMPLEX |
                        MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0);
    msg.hdr.msgh_size = sizeof(msg);
    msg.hdr.msgh_remote_port = _clientPort;
    msg.hdr.msgh_local_port = MACH_PORT_NULL;
    msg.hdr.msgh_id = 0;

    msg.body.msgh_descriptor_count = 1;

    msg.surface_desc.name = surfacePort;
    msg.surface_desc.disposition = MACH_MSG_TYPE_MOVE_SEND;
    msg.surface_desc.type = MACH_MSG_PORT_DESCRIPTOR;

    msg.data.magic = SIM_MESSAGE_DATA_MAGIC;
    msg.data.struct_type = kSimStructDisplaySwapchain;

    SimDisplaySwapchain *sc = &msg.data.payload.display_swapchain;
    sc->size.width = _displayWidth;
    sc->size.height = _displayHeight;
    sc->display_id = _nextDisplayID;
    sc->swapchain_id = _nextSwapchainID++;
    sc->surface_count = 1;
    sc->pixel_format = 0; /* BGRA8888 */
    sc->flags = 0;

    kern_return_t kr = mach_msg(
        &msg.hdr,
        MACH_SEND_MSG,
        sizeof(msg),
        0,
        MACH_PORT_NULL,
        MACH_MSG_TIMEOUT_NONE,
        MACH_PORT_NULL);

    if (kr != KERN_SUCCESS) {
        os_log_error(sLog, "Failed to send Swapchain+IOSurface: 0x%x", kr);
        mach_port_deallocate(mach_task_self(), surfacePort);
    } else {
        os_log(sLog, "Sent Swapchain: %ux%u swapchain_id=%u surface_port=0x%x",
               _displayWidth, _displayHeight, sc->swapchain_id, surfacePort);
    }
}

#pragma mark - Present Handling

- (void)handlePresent:(SimFramebufferMessageData *)data
               header:(mach_msg_header_t *)hdr
{
    /*
     * The sim has presented a frame to the swapchain.
     * For now, we just send the present callback to acknowledge.
     * Later, this is where we'd blit from the sim's surface to our framebuffer.
     */
    SimSwapchainPresent *present = &data->payload.swapchain_present;

    /* Send the present callback acknowledgement */
    SimFramebufferSimpleMessage reply = {};
    reply.hdr.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0);
    reply.hdr.msgh_size = sizeof(reply);
    reply.hdr.msgh_remote_port = hdr->msgh_remote_port ?: _clientPort;
    reply.hdr.msgh_local_port = MACH_PORT_NULL;
    reply.hdr.msgh_id = 0;

    reply.data.magic = SIM_MESSAGE_DATA_MAGIC;
    reply.data.struct_type = kSimStructSwapchainPresentCallback;

    SimSwapchainPresentCallback *cb = &reply.data.payload.swapchain_present_callback;
    cb->present_time = present->present_time;
    cb->completed_time = mach_absolute_time();
    cb->swapchain_id = present->swapchain_id;
    cb->status = 0; /* success */

    kern_return_t kr = mach_msg(
        &reply.hdr,
        MACH_SEND_MSG,
        sizeof(reply),
        0,
        MACH_PORT_NULL,
        MACH_MSG_TIMEOUT_NONE,
        MACH_PORT_NULL);

    if (kr != KERN_SUCCESS) {
        os_log_error(sLog, "Failed to send PresentCallback: 0x%x", kr);
    }
}

@end
