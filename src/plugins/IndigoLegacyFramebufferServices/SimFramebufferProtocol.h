/*
 * SimFramebufferProtocol.h
 *
 * Wire-format structures for the SimFramebuffer Mach message protocol.
 * Reverse-engineered from SimFramebuffer.framework type encodings.
 *
 * The protocol uses a tagged-union message format:
 *   _SimFramebufferMessageData contains a magic, struct_type tag, and a union
 *   of all possible message payloads.
 *
 * Messages are sent over raw mach_msg with OOL port descriptors for IOSurface handles.
 */

#ifndef SIM_FRAMEBUFFER_PROTOCOL_H
#define SIM_FRAMEBUFFER_PROTOCOL_H

#include <stdint.h>
#include <mach/mach.h>

#pragma mark - Primitive Types

typedef struct _SimSize {
    uint32_t width;
    uint32_t height;
} SimSize;

typedef struct _SimPoint {
    uint32_t x;
    uint32_t y;
} SimPoint;

typedef struct _SimRect {
    SimPoint origin;
    SimSize  size;
} SimRect;

#pragma mark - Struct Type Tags
/*
 * Each message payload is identified by a string tag like "SimStructSimSystemCheckin".
 * These are the known tags (from strings in the binary):
 */
// SimStructSimSystemCheckin
// SimStructSimSystemCheckinReply
// SimStructSimDisplayProperties
// SimStructSimDisplayExtendedProperties
// SimStructSimDisplayExtendedPropertyProtocol
// SimStructSimDisplayMode
// SimStructSimDisplaySetCurrentMode
// SimStructSimDisplaySetCanvasSize
// SimStructSimDisplaySetCurrentUIOrientation
// SimStructSimDisplaySetBacklightState
// SimStructSimDisplaySetBrightnessFactor
// SimStructSimDisplaySwapchain
// SimStructSimSwapchainPresent
// SimStructSimSwapchainPresentCallback
// SimStructSimSwapchainBackgroundColor
// SimStructSimSwapchainCancel
// SimStructSimErrorReply

#pragma mark - Message Payloads

/*
 * From type encoding:
 *   {_SimSystemCheckin=II[64c]}
 */
typedef struct _SimSystemCheckin {
    uint32_t version;           // protocol version?
    uint32_t pid;               // client PID?
    char     identifier[64];    // client identifier string
} SimSystemCheckin;

/*
 * {_SimSystemCheckinReply=[16C]}
 */
typedef struct _SimSystemCheckinReply {
    unsigned char data[16];     // opaque reply (UUID? session token?)
} SimSystemCheckinReply;

/*
 * {_SimDisplayProperties=[64c][64c]QQI{_SimSize=II}{_SimSize=II}IIISS}
 */
typedef struct _SimDisplayProperties {
    char     name[64];          // display name
    char     screen_type[64];   // screen type identifier
    uint64_t unique_id;         // unique display ID
    uint64_t seed;              // change counter
    uint32_t display_id;        // numeric display ID
    SimSize  pixel_size;        // pixel dimensions
    SimSize  canvas_size;       // canvas dimensions (may differ from pixel)
    uint32_t power_state;       // on/off/standby
    uint32_t dot_pitch;         // dot pitch (physical size hint)
    uint16_t ui_orientation;    // current UI orientation (0/90/180/270)
    uint16_t screen_id;         // screen ID
} SimDisplayProperties;

/*
 * {_SimDisplayMaskPath=II[128c]}
 */
typedef struct _SimDisplayMaskPath {
    uint32_t display_id;
    uint32_t mask_type;         // or length
    char     path[128];         // path to mask PDF
} SimDisplayMaskPath;

/*
 * {_SimDisplayExtendedProperties={_SimSize=II}IIIb1b1b1b1b1b1b1b1}
 */
typedef struct _SimDisplayExtendedProperties {
    SimSize  display_size;      // logical display size
    uint32_t display_id;
    uint32_t flags1;
    uint32_t flags2;
    /* 8 single-bit bitfields packed into a byte */
    uint8_t  bitfields;         // has_mask, supports_hdr, etc.
} SimDisplayExtendedProperties;

/*
 * {_SimDisplayExtendedPropertyProtocol=II[128c]}
 */
typedef struct _SimDisplayExtendedPropertyProtocol {
    uint32_t display_id;
    uint32_t protocol_id;
    char     protocol_name[128];
} SimDisplayExtendedPropertyProtocol;

/*
 * {_SimDisplayMode=I{_SimSize=II}IIIIICCC}
 */
typedef struct _SimDisplayMode {
    uint32_t display_id;
    SimSize  size;              // mode resolution
    uint32_t pixel_format;      // SimPixelFormat (BGRA8888 = 0?)
    uint32_t colorspace;        // SimColorspace
    uint32_t hdr_mode;          // SimHDRMode
    uint32_t refresh_rate;      // Hz
    uint32_t flags;             // native, preferred, etc.
    uint8_t  size_rule;         // exact/range/any
    uint8_t  pad1;
    uint8_t  pad2;
} SimDisplayMode;

/*
 * {_SimDisplaySetCurrentMode=I{_SimDisplayMode=I{_SimSize=II}IIIIICCC}}
 */
typedef struct _SimDisplaySetCurrentMode {
    uint32_t       display_id;
    SimDisplayMode mode;
} SimDisplaySetCurrentMode;

/*
 * {_SimDisplaySetCanvasSize=I{_SimSize=II}}
 */
typedef struct _SimDisplaySetCanvasSize {
    uint32_t display_id;
    SimSize  canvas_size;
} SimDisplaySetCanvasSize;

/*
 * {_SimDisplaySetCurrentUIOrientation=II}
 */
typedef struct _SimDisplaySetCurrentUIOrientation {
    uint32_t display_id;
    uint32_t orientation;
} SimDisplaySetCurrentUIOrientation;

/*
 * {_SimDisplaySetBacklightState=Ii}
 */
typedef struct _SimDisplaySetBacklightState {
    uint32_t display_id;
    int32_t  backlight_state;
} SimDisplaySetBacklightState;

/*
 * {_SimDisplaySetBrightnessFactor=Id}
 */
typedef struct _SimDisplaySetBrightnessFactor {
    uint32_t display_id;
    double   brightness_factor;
} SimDisplaySetBrightnessFactor;

/*
 * {_SimDisplaySwapchain={_SimSize=II}IIIIII}
 */
typedef struct _SimDisplaySwapchain {
    SimSize  size;              // swapchain surface size
    uint32_t display_id;
    uint32_t swapchain_id;
    uint32_t surface_count;     // number of surfaces
    uint32_t pixel_format;
    uint32_t flags;
    uint32_t reserved;
} SimDisplaySwapchain;

/*
 * {_SimSwapchainPresent=QQQ{_SimRect=...}{_SimRect=...}IIIIII}
 */
typedef struct _SimSwapchainPresent {
    uint64_t present_time;      // nanoseconds
    uint64_t swapchain_id;
    uint64_t surface_id;        // or fence token
    SimRect  source_rect;
    SimRect  dest_rect;
    uint32_t dest_layer;
    uint32_t flags;             // SimSurfaceFlags
    uint32_t display_id;
    uint32_t pad1;
    uint32_t pad2;
    uint32_t pad3;
} SimSwapchainPresent;

/*
 * {_SimSwapchainPresentCallback=QQQI}
 */
typedef struct _SimSwapchainPresentCallback {
    uint64_t present_time;
    uint64_t completed_time;
    uint64_t swapchain_id;
    uint32_t status;
} SimSwapchainPresentCallback;

/*
 * {_SimSwapchainBackgroundColor=IIfff}
 */
typedef struct _SimSwapchainBackgroundColor {
    uint32_t display_id;
    uint32_t swapchain_id;
    float    r;
    float    g;
    float    b;
} SimSwapchainBackgroundColor;

/*
 * {_SimSwapchainCancel=II}
 */
typedef struct _SimSwapchainCancel {
    uint32_t display_id;
    uint32_t swapchain_id;
} SimSwapchainCancel;

/*
 * {_SimErrorReply=[140c]Q(?=iq)}
 */
typedef struct _SimErrorReply {
    char     error_message[140];
    uint64_t error_info;
    union {
        int32_t  error_code_i;
        int64_t  error_code_q;
    } code;
} SimErrorReply;

#pragma mark - Message Container

/*
 * Magic values (from assertion: "content->magic == SimMessageContentMagic"
 *               and "data->magic == SimMessageDataMagic")
 * Actual values unknown — need to capture from live traffic or disassemble.
 * Placeholder values; must be determined empirically.
 */
#define SIM_MESSAGE_CONTENT_MAGIC  0x53464243  /* "SFBC" placeholder */
#define SIM_MESSAGE_DATA_MAGIC     0x53464244  /* "SFBD" placeholder */

/*
 * {_SimFramebufferMessageData=QII(?=...)}
 * Q = magic (uint64_t)
 * I = struct_type tag index
 * I = reserved/size
 * Then the union of all payloads
 */
typedef struct _SimFramebufferMessageData {
    uint64_t magic;             /* SIM_MESSAGE_DATA_MAGIC */
    uint32_t struct_type;       /* index into struct type table */
    uint32_t reserved;

    union {
        SimSystemCheckin                checkin;
        SimSystemCheckinReply           checkin_reply;
        SimDisplayProperties            display_properties;
        SimDisplayMaskPath              display_mask_path;
        SimDisplayExtendedProperties    display_extended_properties;
        SimDisplayExtendedPropertyProtocol display_extended_property_protocol;
        SimDisplayMode                  display_mode;
        SimDisplaySetCurrentMode        display_set_current_mode;
        SimDisplaySetCanvasSize         display_set_canvas_size;
        SimDisplaySetCurrentUIOrientation display_set_current_ui_orientation;
        SimDisplaySetBacklightState     display_set_backlight_state;
        SimDisplaySetBrightnessFactor   display_set_brightness_factor;
        SimDisplaySwapchain             display_swapchain;
        SimSwapchainPresent             swapchain_present;
        SimSwapchainPresentCallback     swapchain_present_callback;
        SimSwapchainBackgroundColor     swapchain_background_color;
        SimSwapchainCancel              swapchain_cancel;
        SimErrorReply                   error_reply;
    } payload;
} SimFramebufferMessageData;

/*
 * {SimFramebufferMessage=Q^{_SimFramebufferMessageHeader}}
 * The outer message wraps a mach_msg with the SimFramebufferMessageData.
 */
typedef struct _SimFramebufferMessageHeader {
    mach_msg_header_t   hdr;
    /* For messages carrying IOSurface ports, OOL port descriptors follow here */
} SimFramebufferMessageHeader;

/*
 * Complete message as sent over mach_msg.
 * The message can optionally include OOL port descriptors for IOSurface handles.
 */
typedef struct SimFramebufferMessage {
    mach_msg_header_t           hdr;
    mach_msg_body_t             body;
    /* OOL port descriptors (0-2, for framebuffer + masked surfaces) */
    mach_msg_port_descriptor_t  ports[2];
    /* Inline data follows */
    SimFramebufferMessageData   data;
} SimFramebufferMessage;

/*
 * Simplified message without OOL ports (for checkin, properties, etc.)
 */
typedef struct SimFramebufferSimpleMessage {
    mach_msg_header_t           hdr;
    SimFramebufferMessageData   data;
} SimFramebufferSimpleMessage;

#pragma mark - Struct Type Enum
/*
 * Indices for struct_type field. Order inferred from union ordering in type encoding.
 * Must be verified against actual binary behavior.
 */
enum SimStructType {
    kSimStructSystemCheckin = 0,
    kSimStructSystemCheckinReply = 1,
    kSimStructDisplayProperties = 2,
    kSimStructDisplayMaskPath = 3,
    kSimStructDisplayExtendedProperties = 4,
    kSimStructDisplayExtendedPropertyProtocol = 5,
    kSimStructDisplayMode = 6,
    kSimStructDisplaySetCurrentMode = 7,
    kSimStructDisplaySetCanvasSize = 8,
    kSimStructDisplaySetCurrentUIOrientation = 9,
    kSimStructDisplaySetBacklightState = 10,
    kSimStructDisplaySetBrightnessFactor = 11,
    kSimStructDisplaySwapchain = 12,
    kSimStructSwapchainPresent = 13,
    kSimStructSwapchainPresentCallback = 14,
    kSimStructSwapchainBackgroundColor = 15,
    kSimStructSwapchainCancel = 16,
    kSimStructErrorReply = 17,
};

#endif /* SIM_FRAMEBUFFER_PROTOCOL_H */
