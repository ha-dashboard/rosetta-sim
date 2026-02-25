/*
 * purple_fb_server.c — PurpleFBServer Mach service shim for backboardd
 *
 * This library is injected into backboardd via DYLD_INSERT_LIBRARIES.
 * It provides the PurpleFBServer Mach service that QuartzCore's
 * PurpleDisplay::open() expects. Without this service, backboardd
 * crashes at BKDisplayStartWindowServer() with "No window server
 * display found".
 *
 * Protocol (reverse-engineered from QuartzCore disassembly):
 *   PurpleDisplay::open(bool isTVOut):
 *     1. bootstrap_look_up("PurpleFBServer") to find our port
 *     2. Constructs PurpleDisplay with the port
 *     3. Calls map_surface() which sends msg_id=4
 *
 *   PurpleDisplay::map_surface():
 *     Sends: 72-byte Mach msg, msgh_id=4
 *     Expects: 72-byte complex reply containing:
 *       - mach_msg_header_t (24 bytes)
 *       - mach_msg_body_t { descriptor_count = 1 } (4 bytes)
 *       - mach_msg_port_descriptor_t { memory_entry_port } (12 bytes)
 *       - uint32_t memory_size
 *       - uint32_t stride (bytes per row)
 *       - uint64_t padding/unknown
 *       - uint32_t pixel_width
 *       - uint32_t pixel_height
 *       - uint32_t point_width
 *       - uint32_t point_height
 *
 * The framebuffer memory is also shared via /tmp/rosettasim_framebuffer
 * so the host app can read pixels for display.
 *
 * Build: compiled as x86_64 against iOS 10.3 simulator SDK
 */

#include <mach/mach.h>
#include <mach/vm_map.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <dlfcn.h>
#include <dispatch/dispatch.h>
#include <objc/runtime.h>
#include <objc/message.h>

/* Forward declarations for APIs not in the iOS simulator SDK headers */
extern mach_port_t bootstrap_port;
extern kern_return_t bootstrap_look_up(mach_port_t, const char *, mach_port_t *);
extern kern_return_t bootstrap_subset(mach_port_t, mach_port_t, mach_port_t *);
extern kern_return_t bootstrap_register(mach_port_t, const char *, mach_port_t);
extern kern_return_t bootstrap_check_in(mach_port_t, const char *, mach_port_t *);
extern kern_return_t task_set_special_port(mach_port_t, int, mach_port_t);
extern mach_port_t mach_reply_port(void);
#define TASK_BOOTSTRAP_PORT 4
extern kern_return_t mach_make_memory_entry_64(
    vm_map_t target_task,
    memory_object_size_t *size,
    memory_object_offset_t offset,
    vm_prot_t permission,
    mach_port_t *object_handle,
    mem_entry_name_port_t parent_entry
);

/* Include shared framebuffer header for host app compatibility */
#include "../shared/rosettasim_framebuffer.h"

/* ================================================================
 * Configuration — matches iPhone 6s @ 2x
 * ================================================================ */

#define PFB_PIXEL_WIDTH    750
#define PFB_PIXEL_HEIGHT   1334
#define PFB_POINT_WIDTH    375
#define PFB_POINT_HEIGHT   667
#define PFB_BYTES_PER_ROW  (PFB_PIXEL_WIDTH * 4)  /* BGRA = 4 bytes/pixel */
#define PFB_SURFACE_SIZE   (PFB_BYTES_PER_ROW * PFB_PIXEL_HEIGHT)  /* 4,002,000 bytes */

/* Page-align the surface size for vm_map */
#define PFB_PAGE_SIZE      4096
#define PFB_SURFACE_PAGES  ((PFB_SURFACE_SIZE + PFB_PAGE_SIZE - 1) / PFB_PAGE_SIZE)
#define PFB_SURFACE_ALLOC  (PFB_SURFACE_PAGES * PFB_PAGE_SIZE)  /* 4,005,888 bytes */

#define PFB_SERVICE_NAME   "PurpleFBServer"
#define PFB_LOG_PREFIX     "[PurpleFBServer] "

/* ================================================================
 * PurpleFB message format (72 bytes = 0x48)
 * ================================================================ */

/* Request message (from PurpleDisplay::map_surface) */
typedef struct {
    mach_msg_header_t header;       /* 24 bytes */
    uint8_t           body[48];     /* remaining 48 bytes to reach 72 total */
} PurpleFBRequest;

/* Reply message — uses proper mach_msg_port_descriptor_t from the SDK.
 *
 * With #pragma pack(4), the port descriptor is 12 bytes:
 *   [name:4] [pad1:4] [pad2:16|disposition:8|type:8 = 4 bytes]
 *
 * Total: 24 (header) + 4 (body) + 12 (port_desc) + 32 (inline) = 72
 */
#pragma pack(4)
typedef struct {
    mach_msg_header_t          header;          /* 24 bytes, offset 0 */
    mach_msg_body_t            body;            /*  4 bytes, offset 24 */
    mach_msg_port_descriptor_t port_desc;       /* 12 bytes, offset 28 */
    /* Inline data (32 bytes): */
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

/* Verify sizes match protocol */
_Static_assert(sizeof(PurpleFBRequest) == 72, "Request must be 72 bytes");
_Static_assert(sizeof(PurpleFBReply) == 72, "Reply must be 72 bytes");

/* ================================================================
 * Globals
 * ================================================================ */

static mach_port_t      g_server_port = MACH_PORT_NULL;
static mach_port_t      g_memory_entry = MACH_PORT_NULL;
static vm_address_t     g_surface_addr = 0;
static pthread_t        g_server_thread;
static volatile int     g_running = 0;

/* Shared framebuffer for host app */
static void            *g_shared_fb = MAP_FAILED;
static int              g_shared_fd = -1;

/* Broker port for cross-process service sharing */
static mach_port_t      g_broker_port = MACH_PORT_NULL;
#define BROKER_REGISTER_PORT_ID 700

/* ================================================================
 * Forward declarations for internal functions
 * ================================================================ */

static void pfb_notify_broker(const char *name, mach_port_t port);

/* ================================================================
 * Logging
 * ================================================================ */

static void pfb_log(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    fprintf(stderr, PFB_LOG_PREFIX);
    vfprintf(stderr, fmt, ap);
    fprintf(stderr, "\n");
    va_end(ap);
}

/* ================================================================
 * Framebuffer allocation
 * ================================================================ */

static kern_return_t pfb_create_surface(void) {
    kern_return_t kr;

    /* Allocate page-aligned memory for the framebuffer */
    kr = vm_allocate(mach_task_self(), &g_surface_addr, PFB_SURFACE_ALLOC, VM_FLAGS_ANYWHERE);
    if (kr != KERN_SUCCESS) {
        pfb_log("vm_allocate failed: %s (%d)", mach_error_string(kr), kr);
        return kr;
    }

    /* Clear to black (BGRA: 0,0,0,255 for opaque black) */
    memset((void *)g_surface_addr, 0, PFB_SURFACE_ALLOC);
    /* Set alpha to 0xFF for all pixels */
    uint8_t *pixels = (uint8_t *)g_surface_addr;
    for (uint32_t i = 0; i < PFB_PIXEL_WIDTH * PFB_PIXEL_HEIGHT; i++) {
        pixels[i * 4 + 3] = 0xFF;  /* Alpha channel */
    }

    /* Create a memory entry so clients can vm_map it */
    memory_object_size_t entry_size = PFB_SURFACE_ALLOC;
    kr = mach_make_memory_entry_64(
        mach_task_self(),
        &entry_size,
        (memory_object_offset_t)g_surface_addr,
        VM_PROT_READ | VM_PROT_WRITE,
        &g_memory_entry,
        MACH_PORT_NULL
    );
    if (kr != KERN_SUCCESS) {
        pfb_log("mach_make_memory_entry_64 failed: %s (%d)", mach_error_string(kr), kr);
        vm_deallocate(mach_task_self(), g_surface_addr, PFB_SURFACE_ALLOC);
        g_surface_addr = 0;
        return kr;
    }

    pfb_log("Surface created: %ux%u pixels, %u bytes/row, %u bytes total",
            PFB_PIXEL_WIDTH, PFB_PIXEL_HEIGHT, PFB_BYTES_PER_ROW, PFB_SURFACE_ALLOC);
    pfb_log("Surface memory at %p, entry port %u", (void *)g_surface_addr, g_memory_entry);

    return KERN_SUCCESS;
}

/* ================================================================
 * Shared framebuffer for host app
 *
 * Maps the same pixel data to /tmp/rosettasim_framebuffer with the
 * RosettaSim header+input structure prepended.
 * ================================================================ */

static void pfb_setup_shared_framebuffer(void) {
    uint32_t total_size = ROSETTASIM_FB_TOTAL_SIZE(PFB_PIXEL_WIDTH, PFB_PIXEL_HEIGHT);

    /* Create/open the shared file — use GPU path to avoid conflict with bridge's
     * CPU framebuffer. The bridge reads from this file in GPU rendering mode. */
    g_shared_fd = open(ROSETTASIM_FB_GPU_PATH, O_RDWR | O_CREAT | O_TRUNC, 0666);
    if (g_shared_fd < 0) {
        pfb_log("WARNING: Cannot create %s: %s", ROSETTASIM_FB_GPU_PATH, strerror(errno));
        return;
    }

    if (ftruncate(g_shared_fd, total_size) < 0) {
        pfb_log("WARNING: ftruncate failed: %s", strerror(errno));
        close(g_shared_fd);
        g_shared_fd = -1;
        return;
    }

    g_shared_fb = mmap(NULL, total_size, PROT_READ | PROT_WRITE, MAP_SHARED, g_shared_fd, 0);
    if (g_shared_fb == MAP_FAILED) {
        pfb_log("WARNING: mmap failed: %s", strerror(errno));
        close(g_shared_fd);
        g_shared_fd = -1;
        return;
    }

    /* Initialize the header */
    RosettaSimFramebufferHeader *hdr = (RosettaSimFramebufferHeader *)g_shared_fb;
    hdr->magic = ROSETTASIM_FB_MAGIC;
    hdr->version = ROSETTASIM_FB_VERSION;
    hdr->width = PFB_PIXEL_WIDTH;
    hdr->height = PFB_PIXEL_HEIGHT;
    hdr->stride = PFB_BYTES_PER_ROW;
    hdr->format = ROSETTASIM_FB_FORMAT_BGRA;
    hdr->frame_counter = 0;
    hdr->timestamp_ns = 0;
    hdr->flags = ROSETTASIM_FB_FLAG_APP_RUNNING;
    hdr->fps_target = 60;

    pfb_log("Shared framebuffer at %s (%u bytes)", ROSETTASIM_FB_GPU_PATH, total_size);
}

/* Copy rendered pixels from backboardd's surface to the shared framebuffer.
 * Called periodically from the server thread or could be triggered on
 * flush_shmem from PurpleDisplay. For now we'll use a simple periodic copy. */
static id g_layer_host_ref = NULL; /* stored when CALayerHost is created */
static volatile int g_layer_host_created; /* defined later, declared here for pfb_sync_to_shared */
static id g_cached_display = NULL; /* set by pfb_create_layer_host, used by sync thread */

/* CoreGraphics types and functions for CALayerHost rendering */
typedef void *CGColorSpaceRef;
typedef void *CGContextRef;
extern CGColorSpaceRef CGColorSpaceCreateDeviceRGB(void);
extern void CGColorSpaceRelease(CGColorSpaceRef);
extern CGContextRef CGBitmapContextCreate(void *data, size_t width, size_t height,
    size_t bitsPerComponent, size_t bytesPerRow, CGColorSpaceRef space, uint32_t bitmapInfo);
extern void CGContextRelease(CGContextRef);
extern void CGContextTranslateCTM(CGContextRef, double, double);
extern void CGContextScaleCTM(CGContextRef, double, double);
/* kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little = 2 | (2 << 12) = 8194 */
#define PFB_BITMAP_INFO 8194

static volatile int g_layerhost_render_logged = 0;

static void pfb_sync_to_shared(void) {
    if (g_shared_fb == MAP_FAILED) return;

    uint8_t *pixel_dest = (uint8_t *)g_shared_fb + ROSETTASIM_FB_META_SIZE;
    RosettaSimFramebufferHeader *hdr = (RosettaSimFramebufferHeader *)g_shared_fb;

    /* If CALayerHost is available and has a contextId, render it into
     * the framebuffer. This captures the app's remote CA context content
     * through backboardd's CALayerHost which resolves the remote context.
     * Throttle to ~30fps (every other 60Hz tick). */
    static volatile int _render_tick = 0;
    _render_tick++;
    /* DISABLED: CALayerHost renderInContext blocks when context is REMOTE.
     * Skip in GPU mode — the sync thread only needs to copy the PurpleDisplay surface. */
    if (0 && g_layer_host_ref && g_layer_host_created && (_render_tick % 2 == 0)) {
        /* Render CALayerHost directly from the sync thread.
         * CALayer renderInContext is not officially thread-safe, but works
         * for simple layer trees. Avoid dispatch_sync to main queue
         * which deadlocks (backboardd's main queue isn't reliably serviced). */
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        if (!cs) goto fallback;

        CGContextRef ctx = CGBitmapContextCreate(
            pixel_dest, PFB_PIXEL_WIDTH, PFB_PIXEL_HEIGHT,
            8, PFB_BYTES_PER_ROW, cs, PFB_BITMAP_INFO);
        CGColorSpaceRelease(cs);
        if (!ctx) goto fallback;

        /* Scale 2x for retina (375x667 points → 750x1334 pixels).
         * Then flip Y: CG origin is bottom-left, UIKit is top-left. */
        CGContextTranslateCTM(ctx, 0, (double)PFB_PIXEL_HEIGHT);
        CGContextScaleCTM(ctx, 2.0, -2.0);

        /* Render the CALayerHost (and its hosted remote layer tree) */
        ((void(*)(id, SEL, CGContextRef))objc_msgSend)(
            g_layer_host_ref, sel_registerName("renderInContext:"), ctx);

        CGContextRelease(ctx);

        hdr->frame_counter++;
        hdr->flags |= ROSETTASIM_FB_FLAG_FRAME_READY;

        if (!g_layerhost_render_logged) {
            g_layerhost_render_logged = 1;
            pfb_log("RENDER: CALayerHost renderInContext succeeded (fc=%llu)",
                    (unsigned long long)hdr->frame_counter);
        }
        return;
    }

fallback:
    /* Fallback: copy from PurpleDisplay surface (may be empty/black) */
    if (g_surface_addr != 0) {
        memcpy(pixel_dest, (void *)g_surface_addr, PFB_SURFACE_SIZE);
    }
    hdr->frame_counter++;
    hdr->flags |= ROSETTASIM_FB_FLAG_FRAME_READY;
}

/* ================================================================
 * Message handler
 * ================================================================ */

static void pfb_handle_message(PurpleFBRequest *req) {
    mach_port_t reply_port = req->header.msgh_remote_port;

    pfb_log("Received message: id=%u, size=%u, reply_port=%u",
            req->header.msgh_id, req->header.msgh_size, reply_port);

    if (req->header.msgh_id == 4 && reply_port != MACH_PORT_NULL) {
        /* msg_id=4: map_surface request — return framebuffer info.
         *
         * Strategy: Send as a COMPLEX message with port descriptor.
         * If that fails, fall back to a simple (non-complex) reply
         * which lets PurpleDisplay exist without a surface.
         * backboardd needs at least one PurpleDisplay to pass the
         * BKDisplayStartWindowServer assertion.
         */
        PurpleFBReply reply;
        memset(&reply, 0, sizeof(reply));

        reply.header.msgh_bits = MACH_MSGH_BITS_COMPLEX |
                                 MACH_MSGH_BITS(MACH_MSG_TYPE_MOVE_SEND_ONCE, 0);
        reply.header.msgh_size = sizeof(PurpleFBReply);
        reply.header.msgh_remote_port = reply_port;
        reply.header.msgh_local_port = MACH_PORT_NULL;
        reply.header.msgh_id = 4;

        /* Body: 1 port descriptor */
        reply.body.msgh_descriptor_count = 1;

        /* Port descriptor — transfers a send right for our memory entry */
        reply.port_desc.name = g_memory_entry;
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
            MACH_PORT_NULL
        );

        if (kr != KERN_SUCCESS) {
            pfb_log("Complex reply failed: %s (%d), trying simple reply",
                    mach_error_string(kr), kr);

            /* Fall back to non-complex reply. PurpleDisplay will exist
             * but without a surface. This still lets _detectDisplays
             * find the display and avoids the assertion. */
            memset(&reply, 0, sizeof(reply));
            reply.header.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_MOVE_SEND_ONCE, 0);
            reply.header.msgh_size = sizeof(PurpleFBReply);
            reply.header.msgh_remote_port = reply_port;
            reply.header.msgh_local_port = MACH_PORT_NULL;
            reply.header.msgh_id = 4;
            /* No descriptors, no port, no surface data — just fill zeros */

            kr = mach_msg(&reply.header, MACH_SEND_MSG, sizeof(PurpleFBReply),
                         0, MACH_PORT_NULL, MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL);
            if (kr != KERN_SUCCESS) {
                pfb_log("Simple reply also failed: %s (%d)", mach_error_string(kr), kr);
            } else {
                pfb_log("Sent simple reply (no surface)");
            }
        } else {
            pfb_log("Replied with surface: %ux%u px, %ux%u pt, %u bytes, mem_entry=%u",
                    PFB_PIXEL_WIDTH, PFB_PIXEL_HEIGHT,
                    PFB_POINT_WIDTH, PFB_POINT_HEIGHT,
                    PFB_SURFACE_ALLOC, g_memory_entry);
        }
    } else if (req->header.msgh_id == 3 && reply_port != MACH_PORT_NULL) {
        /* msg_id=3: flush_shmem — framebuffer dirty region notification.
         * The body contains dirty bounds at offset 0x28 (16 bytes: x, y, w, h).
         * We sync our shared framebuffer and send a 72-byte reply. */
        pfb_log("flush_shmem: syncing to shared framebuffer");
        pfb_sync_to_shared();

        /* Send a simple 72-byte non-complex reply */
        uint8_t reply_buf[72];
        memset(reply_buf, 0, 72);
        mach_msg_header_t *hdr = (mach_msg_header_t *)reply_buf;
        hdr->msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_MOVE_SEND_ONCE, 0);
        hdr->msgh_size = 72;
        hdr->msgh_remote_port = reply_port;
        hdr->msgh_local_port = MACH_PORT_NULL;
        hdr->msgh_id = 3;

        kern_return_t kr = mach_msg(hdr, MACH_SEND_MSG, 72, 0,
                                    MACH_PORT_NULL, MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL);
        if (kr != KERN_SUCCESS) {
            pfb_log("flush reply failed: %s (%d)", mach_error_string(kr), kr);
        }
    } else {
        /* Unknown message — log it and send a proper 72-byte reply */
        pfb_log("Unhandled message id=%u, size=%u (body: %02x %02x %02x %02x)",
                req->header.msgh_id, req->header.msgh_size,
                req->body[0], req->body[1], req->body[2], req->body[3]);

        if (reply_port != MACH_PORT_NULL) {
            /* Send a 72-byte reply (matching protocol size) */
            uint8_t reply_buf[72];
            memset(reply_buf, 0, 72);
            mach_msg_header_t *hdr = (mach_msg_header_t *)reply_buf;
            hdr->msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_MOVE_SEND_ONCE, 0);
            hdr->msgh_size = 72;
            hdr->msgh_remote_port = reply_port;
            hdr->msgh_local_port = MACH_PORT_NULL;
            hdr->msgh_id = req->header.msgh_id;

            mach_msg(hdr, MACH_SEND_MSG, 72, 0,
                     MACH_PORT_NULL, MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL);
        }
    }
}

/* ================================================================
 * Server thread
 * ================================================================ */

static void *pfb_server_thread(void *arg) {
    (void)arg;

    pfb_log("Server thread started, listening on port %u", g_server_port);

    /* Receive buffer — large enough for any PurpleFB message */
    union {
        PurpleFBRequest req;
        uint8_t         raw[1024];
    } buf;

    while (g_running) {
        memset(&buf, 0, sizeof(buf));

        kern_return_t kr = mach_msg(
            &buf.req.header,
            MACH_RCV_MSG,
            0,
            sizeof(buf),
            g_server_port,
            MACH_MSG_TIMEOUT_NONE,
            MACH_PORT_NULL
        );

        if (kr != KERN_SUCCESS) {
            if (g_running) {
                pfb_log("mach_msg receive failed: %s (%d)", mach_error_string(kr), kr);
            }
            continue;
        }

        pfb_handle_message(&buf.req);

        /* Periodically sync pixels to shared framebuffer */
        pfb_sync_to_shared();
    }

    pfb_log("Server thread exiting");
    return NULL;
}

/* ================================================================
 * CALayerHost — hosts app's remote CAContext on the display
 *
 * When the app creates a remote CAContext and writes the contextId
 * to ROSETTASIM_FB_CONTEXT_PATH, we create a CALayerHost in backboardd
 * and add it to the CAWindowServer's display layer tree. This makes
 * CARenderServer composite the app's content onto the PurpleDisplay.
 * ================================================================ */

static volatile int g_layer_host_created = 0;
static volatile uint32_t g_pending_context_id = 0;

/* Called on the main thread to create CALayerHost and add to display */
static void pfb_create_layer_host(void *ctx_id_ptr) {
    uint32_t ctx_id = (uint32_t)(uintptr_t)ctx_id_ptr;
    if (ctx_id == 0 || g_layer_host_created) return;

    pfb_log("Creating CALayerHost for context ID %u", ctx_id);

    /* Get CALayerHost class */
    Class layerHostClass = (Class)objc_getClass("CALayerHost");
    if (!layerHostClass) {
        pfb_log("ERROR: CALayerHost class not found");
        return;
    }

    /* Create CALayerHost instance */
    id layerHost = ((id (*)(id, SEL))objc_msgSend)(
        (id)layerHostClass, sel_registerName("alloc"));
    layerHost = ((id (*)(id, SEL))objc_msgSend)(layerHost, sel_registerName("init"));
    if (!layerHost) {
        pfb_log("ERROR: CALayerHost alloc/init failed");
        return;
    }

    /* Set the contextId on the layer host */
    SEL setCtxIdSel = sel_registerName("setContextId:");
    if (class_respondsToSelector(layerHostClass, setCtxIdSel)) {
        ((void (*)(id, SEL, uint32_t))objc_msgSend)(layerHost, setCtxIdSel, ctx_id);
        pfb_log("CALayerHost contextId set to %u", ctx_id);
    } else {
        pfb_log("WARNING: CALayerHost does not respond to setContextId:");
        /* Try setting the ivar directly */
        Ivar ctxIvar = class_getInstanceVariable(layerHostClass, "_contextId");
        if (ctxIvar) {
            *(uint32_t *)((uint8_t *)layerHost + ivar_getOffset(ctxIvar)) = ctx_id;
            pfb_log("CALayerHost._contextId set directly via ivar");
        } else {
            pfb_log("ERROR: Cannot set contextId on CALayerHost");
            return;
        }
    }

    /* Get CAWindowServer singleton */
    Class wsClass = (Class)objc_getClass("CAWindowServer");
    if (!wsClass) {
        pfb_log("ERROR: CAWindowServer class not found");
        return;
    }

    id windowServer = ((id (*)(id, SEL))objc_msgSend)(
        (id)wsClass, sel_registerName("server"));
    if (!windowServer) {
        /* Try serverIfExists */
        windowServer = ((id (*)(id, SEL))objc_msgSend)(
            (id)wsClass, sel_registerName("serverIfExists"));
    }
    if (!windowServer) {
        pfb_log("ERROR: CAWindowServer.server returned nil");
        return;
    }
    pfb_log("CAWindowServer = %p", (void *)windowServer);

    /* Get displays from window server */
    id displays = ((id (*)(id, SEL))objc_msgSend)(
        windowServer, sel_registerName("displays"));
    if (!displays) {
        pfb_log("ERROR: CAWindowServer.displays returned nil");
        return;
    }

    unsigned long displayCount = ((unsigned long (*)(id, SEL))objc_msgSend)(
        displays, sel_registerName("count"));
    pfb_log("CAWindowServer has %lu displays", displayCount);

    if (displayCount == 0) {
        pfb_log("ERROR: No displays available in CAWindowServer");
        return;
    }

    /* Get the first display */
    id display = ((id (*)(id, SEL, unsigned long))objc_msgSend)(
        displays, sel_registerName("objectAtIndex:"), (unsigned long)0);
    pfb_log("Display[0] = %p", (void *)display);

    /* Cache for sync thread */
    g_cached_display = display;

    /* Log displayId and scan C++ impl for function pointers */
    {
        SEL didSel = sel_registerName("displayId");
        if (class_respondsToSelector(object_getClass(display), didSel)) {
            unsigned int did = ((unsigned int(*)(id, SEL))objc_msgSend)(display, didSel);
            pfb_log("Display[0] displayId = %u", did);
        }
        Class caCtxCls = (Class)objc_getClass("CAContext");
        if (caCtxCls) {
            SEL acSel = sel_registerName("allContexts");
            id ctxs = ((id(*)(id, SEL))objc_msgSend)((id)caCtxCls, acSel);
            unsigned long ctxCount = ctxs ? ((unsigned long(*)(id, SEL))objc_msgSend)(ctxs, sel_registerName("count")) : 0;
            pfb_log("CAContext.allContexts count = %lu (server-side)", ctxCount);
        }

        /* Scan Display C++ impl for function pointers (find render callback) */
        Ivar implIvar = class_getInstanceVariable(object_getClass(display), "_impl");
        if (implIvar) {
            void *displayImpl = *(void **)((uint8_t *)display + ivar_getOffset(implIvar));
            pfb_log("Display C++ impl: %p", displayImpl);
            if (displayImpl) {
                /* Scan for function pointers in the impl object */
                for (int off = 0; off < 0x200; off += 8) {
                    uint64_t val = *(uint64_t *)((uint8_t *)displayImpl + off);
                    if (val > 0x100000 && val < 0x7fffffffffffULL) {
                        Dl_info info;
                        if (dladdr((void *)val, &info) && info.dli_sname) {
                            long delta = (long)(val - (uint64_t)info.dli_saddr);
                            if (delta >= 0 && delta < 0x1000) {
                                pfb_log("  IMPL+0x%x: %p (%s+%ld)", off, (void *)val,
                                         info.dli_sname, delta);
                            }
                        }
                    }
                }
                /* Get C++ CA::Display::Server* from _impl+0x40 and dump layout */
                {
                    void *server = *(void **)((uint8_t *)displayImpl + 0x40);
                    pfb_log("PurpleServer at _impl+0x40: %p", server);
                    if (server && (uint64_t)server > 0x100000) {
                        /* Dump server object — find Render::Server, context list, etc */
                        /* Raw hex dump of PurpleServer object */
                        pfb_log("PurpleServer RAW (256 bytes):");
                        for (int off = 0; off < 256; off += 32) {
                            pfb_log("  +%02x: %016llx %016llx %016llx %016llx",
                                    off,
                                    (unsigned long long)*(uint64_t *)((uint8_t *)server + off),
                                    (unsigned long long)*(uint64_t *)((uint8_t *)server + off + 8),
                                    (unsigned long long)*(uint64_t *)((uint8_t *)server + off + 16),
                                    (unsigned long long)*(uint64_t *)((uint8_t *)server + off + 24));
                        }
                        /* Also resolve any pointers to known objects */
                        for (int off = 0; off < 0x100; off += 8) {
                            uint64_t val = *(uint64_t *)((uint8_t *)server + off);
                            if (val > 0x100000 && val < 0x7fffffffffffULL) {
                                Dl_info info;
                                /* Check if val points to something with a recognizable vtable */
                                uint64_t inner = *(uint64_t *)val;
                                if (inner > 0x100000 && inner < 0x7fffffffffffULL &&
                                    dladdr((void *)inner, &info) && info.dli_sname) {
                                    pfb_log("  +0x%02x → %s", off, info.dli_sname);
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /* Get the display's layer (the root layer of the compositing tree).
     * CAWindowServerDisplay has a 'layer' property that is the root of
     * the layer tree composited onto that display by CARenderServer. */
    SEL layerSel = sel_registerName("layer");
    id displayLayer = NULL;

    if (class_respondsToSelector(object_getClass(display), layerSel) ||
        class_getInstanceMethod(object_getClass(display), layerSel)) {
        displayLayer = ((id (*)(id, SEL))objc_msgSend)(display, layerSel);
    }

    if (!displayLayer) {
        /* Try getting layer from the display's context or other means */
        pfb_log("Display has no 'layer' — trying alternatives...");

        /* List instance methods to find layer-related methods */
        unsigned int mCount = 0;
        Method *methods = class_copyMethodList(object_getClass(display), &mCount);
        pfb_log("Display class %s has %u instance methods:",
                class_getName(object_getClass(display)), mCount);
        for (unsigned int i = 0; i < mCount && i < 30; i++) {
            pfb_log("  -%s", sel_getName(method_getName(methods[i])));
        }
        free(methods);

        /* Try rootLayer */
        SEL rootLayerSel = sel_registerName("rootLayer");
        if (class_respondsToSelector(object_getClass(display), rootLayerSel)) {
            displayLayer = ((id (*)(id, SEL))objc_msgSend)(display, rootLayerSel);
            pfb_log("Display rootLayer = %p", (void *)displayLayer);
        }
    }

    /* Try using CAWindowServer context instead of display layer */
    if (!displayLayer) {
        Class cwsClass = (Class)objc_getClass("CAWindowServer");
        if (cwsClass) {
            /* Get or create the server context */
            SEL ctxSel = sel_registerName("context");
            if (class_respondsToSelector(object_getClass((id)cwsClass), ctxSel)) {
                id serverCtx = ((id(*)(id, SEL))objc_msgSend)((id)cwsClass, ctxSel);
                if (serverCtx) {
                    pfb_log("CAWindowServer.context = %p", (void *)serverCtx);
                    /* Get the server context's layer */
                    SEL layerSel = sel_registerName("layer");
                    if (class_respondsToSelector(object_getClass(serverCtx), layerSel)) {
                        displayLayer = ((id(*)(id, SEL))objc_msgSend)(serverCtx, layerSel);
                        pfb_log("Server context layer = %p", (void *)displayLayer);
                    }
                    if (!displayLayer) {
                        /* Try setLayer on server context with our layer host */
                        SEL setLayerSel = sel_registerName("setLayer:");
                        if (class_respondsToSelector(object_getClass(serverCtx), setLayerSel)) {
                            pfb_log("Setting CALayerHost as server context layer");
                            ((void(*)(id, SEL, id))objc_msgSend)(serverCtx, setLayerSel, layerHost);
                            displayLayer = layerHost; /* mark as done */
                        }
                    }
                } else {
                    pfb_log("CAWindowServer.context returned nil");
                }
            }
        }
    }

    if (displayLayer) {
        pfb_log("Display layer = %p (class=%s)", (void *)displayLayer,
                class_getName(object_getClass(displayLayer)));
        /* Determine how CAWindowServer sized the display layer.
         *
         * In some runs, the display layer appears to use a 1x coordinate space
         * sized in *pixels* (750x1334). In others, it uses a 2x coordinate space
         * sized in *points* (375x667) with contentsScale=2.
         *
         * If we always size CALayerHost to points (375x667) but the display
         * layer is in a 1x/pixel coordinate space, the hosted app content will
         * only fill the top-left quadrant of the framebuffer.
         *
         * Heuristic: use displayLayer.contentsScale to decide whether to size
         * the host in points or pixels, and propagate the same contentsScale to
         * the CALayerHost.
         */
        double displayScale = 1.0;
        {
            SEL csSel = sel_registerName("contentsScale");
            if (class_respondsToSelector(object_getClass(displayLayer), csSel)) {
                displayScale = ((double(*)(id, SEL))objc_msgSend)(displayLayer, csSel);
            }
        }
        pfb_log("Display layer contentsScale=%.2f", displayScale);

        /* Propagate contentsScale to the CALayerHost when available */
        {
            SEL setCsSel = sel_registerName("setContentsScale:");
            if (class_respondsToSelector(object_getClass(layerHost), setCsSel)) {
                ((void(*)(id, SEL, double))objc_msgSend)(layerHost, setCsSel, displayScale);
                pfb_log("CALayerHost contentsScale set to %.2f", displayScale);
            }
        }

        double targetW = (displayScale >= 1.5) ? (double)PFB_POINT_WIDTH  : (double)PFB_PIXEL_WIDTH;
        double targetH = (displayScale >= 1.5) ? (double)PFB_POINT_HEIGHT : (double)PFB_PIXEL_HEIGHT;

        typedef struct { double x, y, w, h; } CGRect_t;
        CGRect_t frame = { 0, 0, targetW, targetH };
        pfb_log("Setting CALayerHost frame: %.0fx%.0f (%s space)",
                frame.w, frame.h, (displayScale >= 1.5) ? "points" : "pixels");

        typedef void (*SetFrameFn)(id, SEL, CGRect_t);
        ((SetFrameFn)objc_msgSend)(layerHost, sel_registerName("setFrame:"), frame);

        /* Add layer host as sublayer if not already set as the context layer */
        if (displayLayer != layerHost) {
            ((void (*)(id, SEL, id))objc_msgSend)(
                displayLayer, sel_registerName("addSublayer:"), layerHost);
            pfb_log("CALayerHost added as sublayer of display layer");
        } else {
            pfb_log("CALayerHost set as server context layer directly");
        }

        /* Retain the layer host and store globally */
        ((id (*)(id, SEL))objc_msgSend)(layerHost, sel_registerName("retain"));
        g_layer_host_ref = layerHost;

        /* Flush the transaction to commit immediately */
        Class catClass = (Class)objc_getClass("CATransaction");
        if (catClass) {
            ((void (*)(id, SEL))objc_msgSend)((id)catClass, sel_registerName("flush"));
            pfb_log("CATransaction flushed after adding CALayerHost");
        }

        g_layer_host_created = 1;
        pfb_log("CALayerHost setup COMPLETE — app content should now composite on display");

        /* Diagnostic: check what contextId the display reports at center */
        {
            typedef struct { double x; double y; } CGPoint_t;
            CGPoint_t center = { 375.0, 667.0 };
            SEL ctxAtPosSel = sel_registerName("contextIdAtPosition:");
            if (class_respondsToSelector(object_getClass(display), ctxAtPosSel)) {
                unsigned int reportedCtx = ((unsigned int(*)(id, SEL, CGPoint_t))objc_msgSend)(
                    display, ctxAtPosSel, center);
                pfb_log("DIAG: contextIdAtPosition(375,667) = %u", reportedCtx);
            } else {
                pfb_log("DIAG: display does not respond to contextIdAtPosition:");
            }
        }
    } else {
        pfb_log("ERROR: Could not find display layer to add CALayerHost to");

        /* Fallback: try adding directly to CAWindowServer's layer */
        SEL wsLayerSel = sel_registerName("layer");
        if (class_respondsToSelector(object_getClass(windowServer), wsLayerSel)) {
            id wsLayer = ((id (*)(id, SEL))objc_msgSend)(windowServer, wsLayerSel);
            if (wsLayer) {
                pfb_log("Fallback: adding CALayerHost to CAWindowServer.layer (%p)", (void *)wsLayer);
                ((void (*)(id, SEL, id))objc_msgSend)(
                    wsLayer, sel_registerName("addSublayer:"), layerHost);
                ((id (*)(id, SEL))objc_msgSend)(layerHost, sel_registerName("retain"));

                Class catClass = (Class)objc_getClass("CATransaction");
                if (catClass) {
                    ((void (*)(id, SEL))objc_msgSend)((id)catClass, sel_registerName("flush"));
                }

                g_layer_host_created = 1;
                pfb_log("CALayerHost added to CAWindowServer.layer (fallback)");
            }
        }
    }
}

/* Track the current CALayerHost contextId so we can detect changes */
static volatile uint32_t g_current_layerhost_ctx_id = 0;

/* Check for context ID file and create/update CALayerHost */
static void pfb_check_context_id(void) {
    int fd = open(ROSETTASIM_FB_CONTEXT_PATH, O_RDONLY);
    if (fd < 0) return;

    char buf[32] = {0};
    ssize_t n = read(fd, buf, sizeof(buf) - 1);
    close(fd);

    if (n <= 0) return;

    uint32_t ctx_id = (uint32_t)strtoul(buf, NULL, 10);
    if (ctx_id == 0) return;

    /* Skip if already using this contextId */
    if (ctx_id == g_current_layerhost_ctx_id) return;

    pfb_log("Found context ID %u in %s (was %u)", ctx_id, ROSETTASIM_FB_CONTEXT_PATH,
            g_current_layerhost_ctx_id);

    /* Create or update the CALayerHost */
    g_current_layerhost_ctx_id = ctx_id;
    g_layer_host_created = 0; /* allow re-creation with new ID */
    pfb_create_layer_host((void *)(uintptr_t)ctx_id);
}

/* ================================================================
 * Periodic sync thread — copies rendered pixels to shared framebuffer
 * ================================================================ */

static pthread_t g_sync_thread;

static void *pfb_sync_thread(void *arg) {
    (void)arg;
    pfb_log("Sync thread started (60 Hz)");

    static int g_update_logged = 0;

    static volatile int _sync_iter = 0;
    while (g_running) {
        _sync_iter++;
        if (_sync_iter % 60 == 0) {
            pfb_log("SYNC_ITER: %d (fc=%llu)",
                    _sync_iter,
                    g_shared_fb != MAP_FAILED ?
                    (unsigned long long)((RosettaSimFramebufferHeader *)g_shared_fb)->frame_counter : 0ULL);
        }
        /* pfb_sync_to_shared temporarily disabled for debugging */
        /* pfb_sync_to_shared(); */

        /* pfb_check_context_id DISABLED — blocks sync thread via locks */

        /* Trigger CAWindowServer display update cycle.
         * This calls attach_contexts → add_context → set_display_info,
         * binding registered contexts to the display for GPU compositing. */
        /* g_cached_display is set by pfb_create_layer_host on the main thread */
        {
            static int _disp_check = 0;
            if (++_disp_check == 300) {
                pfb_log("SYNC_THREAD: g_cached_display=%p g_layer_host_created=%d",
                        (void *)g_cached_display, g_layer_host_created);
            }
        }
        if (g_cached_display) {
            /* Server-side CATransaction flush — triggers commit processing
             * which should run the render pipeline including attach_contexts.
             * This is the server-side equivalent of a display refresh cycle. */
            {
                Class catCls = (Class)objc_getClass("CATransaction");
                if (catCls) {
                    ((void(*)(id, SEL))objc_msgSend)((id)catCls, sel_registerName("flush"));
                }
            }
            ((void(*)(id, SEL))objc_msgSend)(g_cached_display, sel_registerName("update"));

            /* Direct call to CA::WindowServer::Server::attach_contexts()
             * via ASLR slide calculation. This is the function that binds
             * registered contexts to the display (contextIdAtPosition). */
            {
                static void *g_server_cpp = NULL;
                static int _attach_init = 0;
                static void (*g_attach_fn)(void *) = NULL;
                if (!_attach_init) {
                    _attach_init = 1;
                    /* Get server C++ object */
                    Ivar implI = class_getInstanceVariable(
                        object_getClass(g_cached_display), "_impl");
                    if (implI) {
                        void *impl = *(void **)((uint8_t *)g_cached_display + ivar_getOffset(implI));
                        if (impl) g_server_cpp = *(void **)((uint8_t *)impl + 0x40);
                    }
                    /* Calculate ASLR slide from exported symbol */
                    void *known = dlsym(RTLD_DEFAULT, "CARenderServerRenderDisplay");
                    if (known) {
                        ptrdiff_t slide = (ptrdiff_t)known - (ptrdiff_t)0xb9899;
                        g_attach_fn = (void (*)(void *))((uint8_t *)0x1286de + slide);
                        pfb_log("ATTACH_CONTEXTS: server=%p slide=0x%lx fn=%p",
                                g_server_cpp, (long)slide, (void *)g_attach_fn);
                    }
                }
                if (g_server_cpp && g_attach_fn) {
                    g_attach_fn(g_server_cpp);
                }

                /* Direct add_context: get each CAContext's _impl and call add_context */
                {
                    static int _add_ctx_done = 0;
                    static int _add_ctx_tick = 0;
                    _add_ctx_tick++;
                    /* Wait ~20s (1200 ticks at 60Hz) for contexts to register, then try once */
                    if (!_add_ctx_done && _add_ctx_tick == 1200 && g_server_cpp) {
                        _add_ctx_done = 1;
                        void *known = dlsym(RTLD_DEFAULT, "CARenderServerRenderDisplay");
                        if (known) {
                            ptrdiff_t slide = (ptrdiff_t)known - (ptrdiff_t)0xb9899;
                            typedef void (*add_ctx_fn)(void *, void *);
                            add_ctx_fn add_ctx = (add_ctx_fn)((uint8_t *)0x12a006 + slide);

                            Class caCtxCls = (Class)objc_getClass("CAContext");
                            id ctxs = ((id(*)(id, SEL))objc_msgSend)(
                                (id)caCtxCls, sel_registerName("allContexts"));
                            unsigned long cnt = ctxs ? ((unsigned long(*)(id, SEL))objc_msgSend)(
                                ctxs, sel_registerName("count")) : 0;
                            pfb_log("ADD_CONTEXT: attempting for %lu contexts", cnt);

                            for (unsigned long i = 0; i < cnt; i++) {
                                id ctx = ((id(*)(id, SEL, unsigned long))objc_msgSend)(
                                    ctxs, sel_registerName("objectAtIndex:"), i);
                                if (!ctx) continue;
                                Ivar implI = class_getInstanceVariable(object_getClass(ctx), "_impl");
                                if (!implI) continue;
                                void *impl = *(void **)((uint8_t *)ctx + ivar_getOffset(implI));
                                if (!impl) continue;
                                unsigned int cid = ((unsigned int(*)(id, SEL))objc_msgSend)(
                                    ctx, sel_registerName("contextId"));
                                pfb_log("ADD_CONTEXT: ctx[%lu] id=%u impl=%p", i, cid, impl);
                                add_ctx(g_server_cpp, impl);
                                pfb_log("ADD_CONTEXT: ctx[%lu] added (no crash)", i);
                            }

                            /* Check result */
                            typedef struct { double x; double y; } CGPoint_t;
                            CGPoint_t center = { 375.0, 667.0 };
                            SEL ctxSel = sel_registerName("contextIdAtPosition:");
                            unsigned int bound = ((unsigned int(*)(id, SEL, CGPoint_t))objc_msgSend)(
                                g_cached_display, ctxSel, center);
                            pfb_log("ADD_CONTEXT: after add_context, contextIdAtPosition=%u", bound);
                        }
                    }
                }
            }

            /* Call CARenderServerRenderDisplay to trigger the full render pipeline.
             * This should invoke attach_contexts → add_context → set_display_info. */
            {
                static int _render_init = 0;
                static void *_render_fn = NULL;
                static mach_port_t _srv_port = 0;
                static id _display_name = NULL;
                if (!_render_init) {
                    _render_init = 1;
                    _render_fn = dlsym(RTLD_DEFAULT, "CARenderServerRenderDisplay");
                    typedef mach_port_t (*get_port_fn)(void);
                    get_port_fn gp = (get_port_fn)dlsym(RTLD_DEFAULT, "CARenderServerGetServerPort");
                    if (gp) _srv_port = gp();
                    _display_name = ((id(*)(id, SEL))objc_msgSend)(
                        g_cached_display, sel_registerName("name"));
                    pfb_log("RENDER_DISPLAY: fn=%p port=0x%x name=%p", _render_fn, _srv_port,
                            (void *)_display_name);
                }
                if (_render_fn && _srv_port && _display_name) {
                    typedef int (*render_fn)(mach_port_t, id, id, int, int);
                    ((render_fn)_render_fn)(_srv_port, _display_name, NULL, 0, 0);
                }
            }

            if (!g_update_logged) {
                g_update_logged = 1;
                pfb_log("DISPLAY_UPDATE: calling update + CARenderServerRenderDisplay each tick");
            }
            /* Periodic contextIdAtPosition check (every ~5s) */
            {
                static int _ctx_check = 0;
                if (++_ctx_check >= 300) {
                    _ctx_check = 0;
                    typedef struct { double x; double y; } CGPoint_t;
                    CGPoint_t center = { 375.0, 667.0 };
                    SEL ctxSel = sel_registerName("contextIdAtPosition:");
                    unsigned int cid = ((unsigned int(*)(id, SEL, CGPoint_t))objc_msgSend)(
                        g_cached_display, ctxSel, center);
                    Class caCtxCls = (Class)objc_getClass("CAContext");
                    id ctxs = ((id(*)(id, SEL))objc_msgSend)((id)caCtxCls, sel_registerName("allContexts"));
                    unsigned long cnt = ctxs ? ((unsigned long(*)(id, SEL))objc_msgSend)(ctxs, sel_registerName("count")) : 0;
                    pfb_log("PERIODIC_CHECK: contextIdAtPosition=%u allContexts=%lu", cid, cnt);
                }
            }
        }

        /* Standalone add_context attempt — runs independently of g_cached_display */
        {
            static int _add_done = 0;
            static int _add_tick = 0;
            _add_tick++;
            if (!_add_done && _add_tick == 1200) { /* ~20s at 60Hz */
                _add_done = 1;
                pfb_log("ADD_CONTEXT_STANDALONE: starting...");

                /* Get server from CAWindowServer */
                void *server_cpp = NULL;
                id disp = NULL;
                Class wsClass = (Class)objc_getClass("CAWindowServer");
                if (wsClass) {
                    id ws = ((id(*)(id, SEL))objc_msgSend)((id)wsClass, sel_registerName("server"));
                    if (!ws) ws = ((id(*)(id, SEL))objc_msgSend)((id)wsClass, sel_registerName("serverIfRunning"));
                    if (ws) {
                        id displays = ((id(*)(id, SEL))objc_msgSend)(ws, sel_registerName("displays"));
                        unsigned long cnt = displays ? ((unsigned long(*)(id, SEL))objc_msgSend)(
                            displays, sel_registerName("count")) : 0;
                        if (cnt > 0) {
                            disp = ((id(*)(id, SEL, unsigned long))objc_msgSend)(
                                displays, sel_registerName("objectAtIndex:"), 0UL);
                        }
                        pfb_log("ADD_CONTEXT_STANDALONE: ws=%p displays=%lu disp=%p", (void *)ws, cnt, (void *)disp);
                    }
                }
                if (disp) {
                    Ivar implI = class_getInstanceVariable(object_getClass(disp), "_impl");
                    if (implI) {
                        void *impl = *(void **)((uint8_t *)disp + ivar_getOffset(implI));
                        if (impl) server_cpp = *(void **)((uint8_t *)impl + 0x40);
                    }
                }
                pfb_log("ADD_CONTEXT_STANDALONE: server_cpp=%p", server_cpp);

                if (server_cpp) {
                    void *known = dlsym(RTLD_DEFAULT, "CARenderServerRenderDisplay");
                    if (known) {
                        ptrdiff_t slide = (ptrdiff_t)known - (ptrdiff_t)0xb9899;
                        typedef void (*add_ctx_fn)(void *, void *);
                        add_ctx_fn add_ctx = (add_ctx_fn)((uint8_t *)0x12a006 + slide);

                        Class caCtxCls = (Class)objc_getClass("CAContext");
                        id ctxs = ((id(*)(id, SEL))objc_msgSend)(
                            (id)caCtxCls, sel_registerName("allContexts"));
                        unsigned long cnt = ctxs ? ((unsigned long(*)(id, SEL))objc_msgSend)(
                            ctxs, sel_registerName("count")) : 0;
                        pfb_log("ADD_CONTEXT_STANDALONE: %lu contexts to add", cnt);

                        for (unsigned long i = 0; i < cnt; i++) {
                            id ctx = ((id(*)(id, SEL, unsigned long))objc_msgSend)(
                                ctxs, sel_registerName("objectAtIndex:"), i);
                            if (!ctx) continue;
                            Ivar ci = class_getInstanceVariable(object_getClass(ctx), "_impl");
                            if (!ci) continue;
                            void *cimpl = *(void **)((uint8_t *)ctx + ivar_getOffset(ci));
                            if (!cimpl) continue;
                            unsigned int cid = ((unsigned int(*)(id, SEL))objc_msgSend)(
                                ctx, sel_registerName("contextId"));
                            pfb_log("ADD_CONTEXT_STANDALONE: [%lu] id=%u impl=%p", i, cid, cimpl);
                            add_ctx(server_cpp, cimpl);
                            pfb_log("ADD_CONTEXT_STANDALONE: [%lu] done", i);
                        }

                        /* Check */
                        if (disp) {
                            typedef struct { double x; double y; } CGPoint_t;
                            CGPoint_t center = { 375.0, 667.0 };
                            unsigned int bound = ((unsigned int(*)(id, SEL, CGPoint_t))objc_msgSend)(
                                disp, sel_registerName("contextIdAtPosition:"), center);
                            pfb_log("ADD_CONTEXT_STANDALONE: contextIdAtPosition=%u", bound);
                        }
                    }
                }
            }
        }

        usleep(16667);  /* ~60 Hz */
    }

    return NULL;
}

/* ================================================================
 * GraphicsServices Purple port interpositions
 *
 * backboardd calls these during initialization to register/lookup
 * Mach ports for the Purple (HID/event) system. Without launchd,
 * the real functions fail. We provide dummy ports.
 * ================================================================ */

extern mach_port_t GSGetPurpleSystemEventPort(void);
extern mach_port_t GSGetPurpleWorkspacePort(void);
extern mach_port_t GSGetPurpleSystemAppPort(void);
extern mach_port_t GSGetPurpleApplicationPort(void);
extern mach_port_t GSRegisterPurpleNamedPort(const char *name);
extern mach_port_t GSRegisterPurpleNamedPerPIDPort(const char *name, int pid);
extern mach_port_t GSCopyPurpleNamedPort(const char *name);
extern mach_port_t GSCopyPurpleNamedPerPIDPort(const char *name, int pid);

static mach_port_t g_dummy_purple_port = MACH_PORT_NULL;

static mach_port_t pfb_get_dummy_port(void) {
    if (g_dummy_purple_port == MACH_PORT_NULL) {
        mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &g_dummy_purple_port);
        mach_port_insert_right(mach_task_self(), g_dummy_purple_port, g_dummy_purple_port,
                               MACH_MSG_TYPE_MAKE_SEND);
    }
    return g_dummy_purple_port;
}

/* Interpose GSEventInitializeWorkspaceWithQueue — called by backboardd.
 * The real function chain is:
 *   GSEventInitializeWorkspaceWithQueue → _GSEventInitializeApp
 *   → GSRegisterPurpleNamedPerPIDPort → abort (without launchd)
 * We replace this to skip the Purple port registration entirely. */
extern void GSEventInitializeWorkspaceWithQueue(void *queue);

void pfb_GSEventInitializeWorkspaceWithQueue(void *queue) {
    pfb_log("GSEventInitializeWorkspaceWithQueue(%p) → intercepted, skipping Purple registration", queue);
    /* Skip the full GS initialization to avoid Purple port registration.
     * backboardd's BKHIDSystem handles HID events independently via
     * IOHIDEventSystem, not through the GS Purple port infrastructure. */
}

/* Purple system ports — each gets its own unique port registered with broker.
 * These are singleton ports returned on repeated calls (like launchd services). */
static mach_port_t g_purple_event_port = MACH_PORT_NULL;
static mach_port_t g_purple_workspace_port = MACH_PORT_NULL;
static mach_port_t g_purple_app_port = MACH_PORT_NULL;

/* Forward declarations for service registry (defined later in the file) */
#define MAX_SERVICES 64
static struct { char name[128]; mach_port_t port; } g_services[MAX_SERVICES];
static int g_service_count;
static volatile int g_display_services_started;
static void pfb_notify_broker(const char *name, mach_port_t port);

static mach_port_t pfb_alloc_and_register(const char *name) {
    mach_port_t p = MACH_PORT_NULL;
    mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &p);
    mach_port_insert_right(mach_task_self(), p, p, MACH_MSG_TYPE_MAKE_SEND);
    if (name && p != MACH_PORT_NULL && g_service_count < MAX_SERVICES) {
        strncpy(g_services[g_service_count].name, name, 127);
        g_services[g_service_count].name[127] = 0;
        g_services[g_service_count].port = p;
        g_service_count++;
        pfb_notify_broker(name, p);
    }
    return p;
}

mach_port_t pfb_GSGetPurpleSystemEventPort(void) {
    if (g_purple_event_port == MACH_PORT_NULL) {
        g_purple_event_port = pfb_alloc_and_register("PurpleSystemEventPort");
    }
    pfb_log("GSGetPurpleSystemEventPort() → %u", g_purple_event_port);
    return g_purple_event_port;
}

mach_port_t pfb_GSGetPurpleWorkspacePort(void) {
    if (g_purple_workspace_port == MACH_PORT_NULL) {
        g_purple_workspace_port = pfb_alloc_and_register("PurpleWorkspacePort");
    }
    pfb_log("GSGetPurpleWorkspacePort() → %u", g_purple_workspace_port);
    return g_purple_workspace_port;
}

mach_port_t pfb_GSGetPurpleSystemAppPort(void) {
    if (g_purple_app_port == MACH_PORT_NULL) {
        g_purple_app_port = pfb_alloc_and_register("PurpleSystemAppPort");
    }
    pfb_log("GSGetPurpleSystemAppPort() → %u", g_purple_app_port);
    return g_purple_app_port;
}

mach_port_t pfb_GSGetPurpleApplicationPort(void) {
    pfb_log("GSGetPurpleApplicationPort() → 0");
    return MACH_PORT_NULL;
}

/* Forward declaration */
static void *pfb_display_services_thread(void *arg);

mach_port_t pfb_GSRegisterPurpleNamedPort(const char *name) {
    /* Create a unique port for each named service (not shared dummy).
     * This allows SpringBoard and other processes to look up these
     * services through the broker. */
    mach_port_t p = MACH_PORT_NULL;
    mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &p);
    mach_port_insert_right(mach_task_self(), p, p, MACH_MSG_TYPE_MAKE_SEND);
    pfb_log("GSRegisterPurpleNamedPort('%s') → %u", name ? name : "(null)", p);

    /* Register in local registry AND notify broker */
    if (name && p != MACH_PORT_NULL && g_service_count < MAX_SERVICES) {
        strncpy(g_services[g_service_count].name, name, 127);
        g_services[g_service_count].name[127] = 0;
        g_services[g_service_count].port = p;
        g_service_count++;
        pfb_notify_broker(name, p);

        /* Auto-start display services handler when registered (exactly once). */
        if (strstr(name, "display.services")) {
            if (__sync_bool_compare_and_swap(&g_display_services_started, 0, 1)) {
                pfb_log("Auto-starting display services handler on port %u", p);
                mach_port_t *ds_port = (mach_port_t *)malloc(sizeof(mach_port_t));
                *ds_port = p;
                pthread_t ds_thread;
                pthread_create(&ds_thread, NULL, pfb_display_services_thread, ds_port);
                pthread_detach(ds_thread);
            } else {
                pfb_log("Display services handler already started; skipping auto-start");
            }
        }
    }
    return p;
}

mach_port_t pfb_GSRegisterPurpleNamedPerPIDPort(const char *name, int pid) {
    /* Same as GSRegisterPurpleNamedPort but with PID suffix */
    mach_port_t p = MACH_PORT_NULL;
    mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &p);
    mach_port_insert_right(mach_task_self(), p, p, MACH_MSG_TYPE_MAKE_SEND);
    pfb_log("GSRegisterPurpleNamedPerPIDPort('%s', %d) → %u", name ? name : "(null)", pid, p);

    /* Register with broker using the service name (without PID) */
    if (name && p != MACH_PORT_NULL && g_service_count < MAX_SERVICES) {
        strncpy(g_services[g_service_count].name, name, 127);
        g_services[g_service_count].name[127] = 0;
        g_services[g_service_count].port = p;
        g_service_count++;
        pfb_notify_broker(name, p);
    }
    return p;
}

mach_port_t pfb_GSCopyPurpleNamedPort(const char *name) {
    mach_port_t p = pfb_get_dummy_port();
    pfb_log("GSCopyPurpleNamedPort('%s') → %u", name ? name : "(null)", p);
    return p;
}

mach_port_t pfb_GSCopyPurpleNamedPerPIDPort(const char *name, int pid) {
    mach_port_t p = pfb_get_dummy_port();
    pfb_log("GSCopyPurpleNamedPerPIDPort('%s', %d) → %u", name ? name : "(null)", pid, p);
    return p;
}

/* ================================================================
 * XPC interposition — BSBaseXPCServer tries to create XPC listeners
 * via xpc_connection_create_mach_service. Without launchd, this fails.
 * We provide a dummy connection that doesn't crash.
 * ================================================================ */

typedef void *xpc_connection_t;
typedef void *xpc_object_t;
typedef void (*xpc_handler_t)(xpc_object_t);

extern xpc_connection_t xpc_connection_create_mach_service(const char *name,
                                                            void *targetq,
                                                            uint64_t flags);

xpc_connection_t pfb_xpc_connection_create_mach_service(const char *name,
                                                         void *targetq,
                                                         uint64_t flags) {
    pfb_log("xpc_connection_create_mach_service('%s', flags=0x%llx)",
            name ? name : "(null)", flags);

    /* Create the real connection — it won't connect to anything useful
     * but won't immediately crash either. The error handler will fire
     * when the connection fails, but our exception suppression handles that. */
    xpc_connection_t conn = xpc_connection_create_mach_service(name, targetq, flags);
    pfb_log("  → connection %p (may fail later)", (void *)conn);
    return conn;
}

/* ================================================================
 * DYLD interposition — intercept bootstrap_look_up
 *
 * Since bootstrap_register is blocked on modern macOS, we instead
 * interpose bootstrap_look_up so that when PurpleDisplay::open()
 * looks up "PurpleFBServer", we return our own port directly.
 * ================================================================ */

static mach_port_t g_send_port = MACH_PORT_NULL;  /* Send right for clients */

/* Trace vm_map to see if PurpleDisplay::map_surface succeeds */
extern kern_return_t vm_map(vm_map_t, vm_address_t *, vm_size_t, vm_address_t,
                            int, mem_entry_name_port_t, vm_offset_t, boolean_t,
                            vm_prot_t, vm_prot_t, vm_inherit_t);

kern_return_t pfb_vm_map(vm_map_t target, vm_address_t *addr, vm_size_t size,
                         vm_address_t mask, int flags, mem_entry_name_port_t object,
                         vm_offset_t offset, boolean_t copy, vm_prot_t cur_prot,
                         vm_prot_t max_prot, vm_inherit_t inherit) {
    kern_return_t kr = vm_map(target, addr, size, mask, flags, object, offset,
                              copy, cur_prot, max_prot, inherit);
    if (object != MACH_PORT_NULL && size > 1000000) {
        pfb_log("vm_map(size=%lu, object=%u, prot=%d/%d) → %s (%d), addr=%p",
                (unsigned long)size, object, cur_prot, max_prot,
                kr == KERN_SUCCESS ? "OK" : mach_error_string(kr), kr,
                addr ? (void *)*addr : NULL);
    }
    return kr;
}

/* ================================================================
 * Suppress BKDisplayStartWindowServer assertion
 *
 * If there's no window server display, we suppress the assertion
 * and let backboardd continue. This allows us to see what else
 * fails after the display assertion.
 * ================================================================ */

/* Interpose abort() and objc_exception_throw to suppress crashes during init */
#include <execinfo.h>
extern void abort(void);
static volatile int g_suppress_exceptions = 1;  /* Suppress during init */

void pfb_abort(void) {
    pfb_log("=== abort() called! Backtrace: ===");
    void *frames[30];
    int n = backtrace(frames, 30);
    char **syms = backtrace_symbols(frames, n);
    if (syms) {
        for (int i = 0; i < n && i < 10; i++) {
            pfb_log("  %s", syms[i]);
        }
        free(syms);
    }

    if (g_suppress_exceptions) {
        pfb_log("SUPPRESSING abort() — returning (UNSAFE)");
        return;
    }

    pfb_log("=== calling real abort() ===");
    abort();
}

/* Interpose objc_exception_throw to log exceptions.
 * Use void* instead of id since ObjC headers aren't included yet. */
extern void objc_exception_throw(void *exception);

void pfb_objc_exception_throw(void *exception) {
    pfb_log("EXCEPTION thrown: object at %p", exception);
    void *frames[20];
    int n = backtrace(frames, 20);
    char **syms = backtrace_symbols(frames, n);
    if (syms) {
        for (int i = 0; i < n && i < 6; i++) {
            pfb_log("  %s", syms[i]);
        }
        free(syms);
    }

    if (g_suppress_exceptions) {
        pfb_log("SUPPRESSING exception — returning without throw");
        /* This is unsafe but lets us see how far backboardd gets.
         * Code that throws will continue executing after the raise: call,
         * which may cause further issues. */
        return;
    }

    objc_exception_throw(exception);
}

/* Better approach: interpose the assertion handler to skip the assertion */

/* Original assertion handler IMP */
static void (*orig_handleFailure)(id, SEL, id, id, long, id) = NULL;

/* Suppress ALL assertions during backboardd init */
static void pfb_handleFailureFunc(id self, SEL _cmd, id function, id file,
                                   long lineNumber, id description) {
    const char *funcName = "unknown";
    if (function) {
        funcName = ((const char *(*)(id, SEL))objc_msgSend)(function, sel_registerName("UTF8String"));
    }
    const char *descStr = "";
    if (description) {
        descStr = ((const char *(*)(id, SEL))objc_msgSend)(description, sel_registerName("UTF8String"));
    }
    pfb_log("SUPPRESSED assertion in %s at line %ld: %s", funcName, lineNumber, descStr);
    /* Don't call original — suppress ALL assertions */
}

static void pfb_handleFailureMethod(id self, SEL _cmd, SEL method, id object,
                                     id file, long lineNumber, id description) {
    const char *methodName = method ? sel_getName(method) : "unknown";
    const char *descStr = "";
    if (description) {
        descStr = ((const char *(*)(id, SEL))objc_msgSend)(description, sel_registerName("UTF8String"));
    }
    pfb_log("SUPPRESSED method assertion %s at line %ld: %s", methodName, lineNumber, descStr);
    /* Don't call original — suppress ALL assertions */
}

/* Track registered services for later lookup
 * (g_services, g_service_count, MAX_SERVICES forward-declared above
 *  near the Purple port functions) */

kern_return_t pfb_bootstrap_look_up(mach_port_t bp, const char *name, mach_port_t *sp) {
    if (name && strcmp(name, PFB_SERVICE_NAME) == 0) {
        if (g_server_port != MACH_PORT_NULL) {
            *sp = g_send_port;
            pfb_log("bootstrap_look_up('%s') → intercepted, returning port %u", name, *sp);
            return KERN_SUCCESS;
        }
    }

    /* Check our local service registry first */
    for (int i = 0; i < g_service_count; i++) {
        if (name && strcmp(name, g_services[i].name) == 0) {
            *sp = g_services[i].port;
            pfb_log("bootstrap_look_up('%s') → local registry port %u", name, *sp);
            return KERN_SUCCESS;
        }
    }

    /* Pass through to real bootstrap_look_up for all other services */
    kern_return_t kr = bootstrap_look_up(bp, name, sp);
    if (name) {
        pfb_log("bootstrap_look_up('%s') → %s (%d) port=%u",
                name, kr == KERN_SUCCESS ? "OK" : "FAILED", kr,
                (kr == KERN_SUCCESS && sp) ? *sp : 0);
    }
    return kr;
}

/* Interpose bootstrap_register to capture services backboardd tries to register */
extern kern_return_t bootstrap_register(mach_port_t, const char *, mach_port_t);

kern_return_t pfb_bootstrap_register(mach_port_t bp, const char *name, mach_port_t sp) {
    pfb_log("bootstrap_register('%s', port=%u)", name ? name : "(null)", sp);

    /* Try real registration first */
    kern_return_t kr = bootstrap_register(bp, name, sp);
    if (kr == KERN_SUCCESS) {
        pfb_log("  → registered OK via bootstrap");
        /* Notify broker of the service port */
        if (name && sp != MACH_PORT_NULL) {
            pfb_notify_broker(name, sp);
        }
        return kr;
    }

    /* If real registration fails, store in our local registry */
    if (name && g_service_count < MAX_SERVICES) {
        strncpy(g_services[g_service_count].name, name, 127);
        g_services[g_service_count].name[127] = 0;
        g_services[g_service_count].port = sp;
        g_service_count++;
        pfb_log("  → real registration failed (%d), stored in local registry", kr);

        /* Notify broker of the service port */
        if (sp != MACH_PORT_NULL) {
            pfb_notify_broker(name, sp);
        }

        return KERN_SUCCESS;  /* Pretend success */
    }

    pfb_log("  → FAILED: %s (%d)", mach_error_string(kr), kr);
    return kr;
}

/* Also interpose bootstrap_check_in */
extern kern_return_t bootstrap_check_in(mach_port_t, const char *, mach_port_t *);

kern_return_t pfb_bootstrap_check_in(mach_port_t bp, const char *name, mach_port_t *sp) {
    pfb_log("bootstrap_check_in('%s')", name ? name : "(null)");

    kern_return_t kr = bootstrap_check_in(bp, name, sp);
    if (kr == KERN_SUCCESS) {
        pfb_log("  → checked in OK, port=%u", sp ? *sp : 0);

        /* Also store in local registry for lookup */
        if (name && g_service_count < MAX_SERVICES) {
            strncpy(g_services[g_service_count].name, name, 127);
            g_services[g_service_count].name[127] = 0;
            g_services[g_service_count].port = *sp;
            g_service_count++;
        }

        /* Notify broker of the service port */
        if (name && sp && *sp != MACH_PORT_NULL) {
            pfb_notify_broker(name, *sp);
        }
    } else {
        pfb_log("  → FAILED: %s (%d), creating port for local registry", mach_error_string(kr), kr);

        /* Create a local port for the service */
        mach_port_t port;
        kern_return_t alloc_kr = mach_port_allocate(mach_task_self(),
                                                     MACH_PORT_RIGHT_RECEIVE, &port);
        if (alloc_kr == KERN_SUCCESS) {
            mach_port_insert_right(mach_task_self(), port, port, MACH_MSG_TYPE_MAKE_SEND);
            *sp = port;

            if (name && g_service_count < MAX_SERVICES) {
                strncpy(g_services[g_service_count].name, name, 127);
                g_services[g_service_count].name[127] = 0;
                g_services[g_service_count].port = port;
                g_service_count++;
            }
            pfb_log("  → created local port %u for '%s'", port, name);

            /* Notify broker of the service port */
            pfb_notify_broker(name, port);

            kr = KERN_SUCCESS;
        }
    }
    return kr;
}

/* Interposition table */
__attribute__((used, section("__DATA,__interpose")))
static struct {
    void *replacement;
    void *original;
} pfb_interpositions[] = {
    { (void *)pfb_bootstrap_look_up, (void *)bootstrap_look_up },
    { (void *)pfb_bootstrap_register, (void *)bootstrap_register },
    { (void *)pfb_bootstrap_check_in, (void *)bootstrap_check_in },
    { (void *)pfb_vm_map, (void *)vm_map },
    { (void *)pfb_abort, (void *)abort },
    { (void *)pfb_objc_exception_throw, (void *)objc_exception_throw },
    /* GraphicsServices */
    { (void *)pfb_GSEventInitializeWorkspaceWithQueue, (void *)GSEventInitializeWorkspaceWithQueue },
    { (void *)pfb_GSGetPurpleSystemEventPort, (void *)GSGetPurpleSystemEventPort },
    { (void *)pfb_GSGetPurpleWorkspacePort, (void *)GSGetPurpleWorkspacePort },
    { (void *)pfb_GSGetPurpleSystemAppPort, (void *)GSGetPurpleSystemAppPort },
    { (void *)pfb_GSGetPurpleApplicationPort, (void *)GSGetPurpleApplicationPort },
    { (void *)pfb_GSRegisterPurpleNamedPort, (void *)GSRegisterPurpleNamedPort },
    { (void *)pfb_GSRegisterPurpleNamedPerPIDPort, (void *)GSRegisterPurpleNamedPerPIDPort },
    { (void *)pfb_GSCopyPurpleNamedPort, (void *)GSCopyPurpleNamedPort },
    { (void *)pfb_GSCopyPurpleNamedPerPIDPort, (void *)GSCopyPurpleNamedPerPIDPort },
};

/* ================================================================
 * Broker notification — send service ports to broker for sharing
 * ================================================================ */

/* BROKER_REGISTER_PORT message format (msg_id 700)
 * Must match bootstrap_complex_request_t in rosettasim_broker.c */
#include <mach/ndr.h>
#pragma pack(4)
typedef struct {
    mach_msg_header_t header;        /* 24 bytes */
    mach_msg_body_t body;            /* 4 bytes — descriptor_count = 1 */
    mach_msg_port_descriptor_t port; /* 12 bytes — the service port to register */
    NDR_record_t ndr;                /* 8 bytes — required by broker */
    uint32_t name_len;               /* 4 bytes */
    char name[128];                  /* 128 bytes — service name */
} BrokerRegisterPortMsg;
#pragma pack()

static void pfb_notify_broker(const char *name, mach_port_t port) {
    if (g_broker_port == MACH_PORT_NULL || name == NULL || port == MACH_PORT_NULL) {
        return;
    }

    pfb_log("Notifying broker of service '%s' (port %u)", name, port);

    /* Construct BROKER_REGISTER_PORT request */
    BrokerRegisterPortMsg msg;
    memset(&msg, 0, sizeof(msg));

    /* Header: complex message with port descriptor */
    msg.header.msgh_bits = MACH_MSGH_BITS_COMPLEX |
                           MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, MACH_MSG_TYPE_MAKE_SEND_ONCE);
    msg.header.msgh_size = sizeof(BrokerRegisterPortMsg);
    msg.header.msgh_remote_port = g_broker_port;
    msg.header.msgh_local_port = mach_reply_port();
    msg.header.msgh_id = BROKER_REGISTER_PORT_ID;

    /* Body: 1 port descriptor */
    msg.body.msgh_descriptor_count = 1;

    /* Port descriptor */
    msg.port.name = port;
    msg.port.disposition = MACH_MSG_TYPE_COPY_SEND;
    msg.port.type = MACH_MSG_PORT_DESCRIPTOR;

    /* NDR record (must match broker's expected format) */
    msg.ndr = NDR_record;

    /* Service name */
    msg.name_len = (uint32_t)strlen(name);
    strncpy(msg.name, name, 127);
    msg.name[127] = '\0';

    /* Send request and receive reply */
    union {
        struct {
            mach_msg_header_t header;
            uint32_t body[8];  /* Space for ret_code at offset 32 */
        } reply;
        uint8_t raw[64];  /* Generous buffer for 36-byte reply */
    } reply_buf;
    memset(&reply_buf, 0, sizeof(reply_buf));

    kern_return_t kr = mach_msg(
        &msg.header,
        MACH_SEND_MSG | MACH_RCV_MSG,
        sizeof(BrokerRegisterPortMsg),
        sizeof(reply_buf),
        msg.header.msgh_local_port,
        1000,  /* 1 second timeout */
        MACH_PORT_NULL
    );

    if (kr != KERN_SUCCESS) {
        pfb_log("  → broker notification failed: %s (%d)", mach_error_string(kr), kr);
        mach_port_deallocate(mach_task_self(), msg.header.msgh_local_port);
        return;
    }

    /* Check reply ret_code at offset 32 */
    uint32_t ret_code = reply_buf.reply.body[2];  /* offset 32 = body[8] */
    if (ret_code == 0) {
        pfb_log("  → broker registered '%s' successfully", name);
    } else {
        pfb_log("  → broker returned error code %u", ret_code);
    }

    mach_port_deallocate(mach_task_self(), msg.header.msgh_local_port);
}

/* ================================================================
 * Library constructor — runs before backboardd's main()
 * ================================================================ */

static mach_port_t g_subset_port = MACH_PORT_NULL;

/* ================================================================
 * Display Services Handler Thread
 *
 * Responds to BKSDisplayServices MIG messages from the app process.
 * The app calls BKSDisplayServicesGetMainScreenInfo() which sends
 * msg_id 6001005 (0x5B916D) to get display dimensions.
 * ================================================================ */

static void *pfb_display_services_thread(void *arg) {
    mach_port_t port = *(mach_port_t *)arg;
    free(arg);

    pfb_log("[DisplayServices] Handler thread started on port %u", port);

    /* Message buffer — large enough for all display services messages */
    uint8_t buf[1024];

    while (g_running) {
        mach_msg_header_t *hdr = (mach_msg_header_t *)buf;
        memset(buf, 0, sizeof(buf));

        kern_return_t kr = mach_msg(hdr, MACH_RCV_MSG | MACH_RCV_TIMEOUT,
                                     0, sizeof(buf), port, 1000, MACH_PORT_NULL);
        if (kr == MACH_RCV_TIMED_OUT) continue;
        if (kr != KERN_SUCCESS) {
            pfb_log("[DisplayServices] mach_msg recv error: %d", kr);
            continue;
        }

        pfb_log("[DisplayServices] Received msg_id=%d size=%d reply_port=%u",
                hdr->msgh_id, hdr->msgh_size, hdr->msgh_remote_port);

        mach_port_t reply_port = hdr->msgh_remote_port;
        if (reply_port == MACH_PORT_NULL) {
            /* Check local_port for reply */
            reply_port = hdr->msgh_local_port;
        }

        if (hdr->msgh_id == 6001005) {
            /* BKSDisplayServicesGetMainScreenInfo
             * Reply format: { header, NDR, retcode, width, height, scaleX, scaleY }
             * Total 52 bytes (0x34) — confirmed from disassembly:
             *   header (24) + NDR (8) + retcode (4) + width (4) + height (4) + scaleX (4) + scaleY (4)
             * Reply ID = 0x5B91D1 (6001105 = request + 100) */
            #pragma pack(4)
            struct {
                mach_msg_header_t header;   /* 24 bytes */
                NDR_record_t ndr;           /*  8 bytes */
                int32_t retcode;            /*  4 bytes */
                uint32_t width;             /*  4 bytes — float as uint32 */
                uint32_t height;            /*  4 bytes — float as uint32 */
                uint32_t scaleX;            /*  4 bytes — float as uint32 */
                uint32_t scaleY;            /*  4 bytes — float as uint32 */
            } reply;
            #pragma pack()

            memset(&reply, 0, sizeof(reply));
            reply.header.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_MOVE_SEND_ONCE, 0);
            reply.header.msgh_size = 52; /* 0x34 — exact size from disassembly */
            reply.header.msgh_remote_port = reply_port;
            reply.header.msgh_local_port = MACH_PORT_NULL;
            reply.header.msgh_id = 6001005 + 100; /* Reply ID = request + 100 */
            reply.ndr = NDR_record;
            reply.retcode = 0; /* success */
            /* All four values are FLOATS stored as raw uint32 bits.
             * Width and height are in points. */
            float fw = (float)PFB_POINT_WIDTH;  /* 375.0 */
            float fh = (float)PFB_POINT_HEIGHT; /* 667.0 */
            float sx = 2.0f;  /* scale X */
            float sy = 2.0f;  /* scale Y */
            memcpy(&reply.width, &fw, 4);
            memcpy(&reply.height, &fh, 4);
            memcpy(&reply.scaleX, &sx, 4);
            memcpy(&reply.scaleY, &sy, 4);

            kr = mach_msg(&reply.header, MACH_SEND_MSG, reply.header.msgh_size,
                         0, MACH_PORT_NULL, 1000, MACH_PORT_NULL);
            if (kr == KERN_SUCCESS) {
                pfb_log("[DisplayServices] Replied to GetMainScreenInfo: %ux%u @2x",
                        PFB_POINT_WIDTH, PFB_POINT_HEIGHT);
            } else {
                pfb_log("[DisplayServices] Reply failed: %d", kr);
            }

        } else if (hdr->msgh_id == 6001000) {
            /* BKSDisplayServicesStart — check if display server is alive
             * Reply: { header, NDR, retcode, isAlive }
             * Reply ID = 6001100 */
            #pragma pack(4)
            struct {
                mach_msg_header_t header;
                NDR_record_t ndr;
                int32_t retcode;
                int32_t isAlive;
            } reply;
            #pragma pack()

            memset(&reply, 0, sizeof(reply));
            reply.header.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_MOVE_SEND_ONCE, 0);
            reply.header.msgh_size = sizeof(reply);
            reply.header.msgh_remote_port = reply_port;
            reply.header.msgh_local_port = MACH_PORT_NULL;
            reply.header.msgh_id = 6001100; /* Reply ID */
            reply.ndr = NDR_record;
            reply.retcode = 0;
            reply.isAlive = 1; /* TRUE */

            kr = mach_msg(&reply.header, MACH_SEND_MSG, sizeof(reply),
                         0, MACH_PORT_NULL, 1000, MACH_PORT_NULL);
            if (kr == KERN_SUCCESS) {
                pfb_log("[DisplayServices] Replied to Start: isAlive=TRUE");
            } else {
                pfb_log("[DisplayServices] Start reply failed: %d", kr);
            }

        } else {
            pfb_log("[DisplayServices] Unknown msg_id %d — sending empty reply", hdr->msgh_id);
            if (reply_port != MACH_PORT_NULL) {
                mach_msg_header_t reply;
                memset(&reply, 0, sizeof(reply));
                reply.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_MOVE_SEND_ONCE, 0);
                reply.msgh_size = sizeof(reply);
                reply.msgh_remote_port = reply_port;
                reply.msgh_id = hdr->msgh_id + 100;
                mach_msg(&reply, MACH_SEND_MSG, sizeof(reply),
                         0, MACH_PORT_NULL, 1000, MACH_PORT_NULL);
            }
        }
    }

    pfb_log("[DisplayServices] Handler thread exiting");
    return NULL;
}

__attribute__((constructor))
static void pfb_init(void) {
    pfb_log("Initializing PurpleFBServer shim");

    /* Get the broker port from TASK_BOOTSTRAP_PORT.
     * The broker spawned backboardd with this set to the broker's port. */
    kern_return_t kr = task_get_special_port(mach_task_self(), TASK_BOOTSTRAP_PORT, &g_broker_port);
    if (kr == KERN_SUCCESS && g_broker_port != MACH_PORT_NULL) {
        pfb_log("Found broker port: %u (from TASK_BOOTSTRAP_PORT)", g_broker_port);
        /* Set bootstrap_port to broker so iOS SDK bootstrap calls go to broker */
        bootstrap_port = g_broker_port;
    } else {
        pfb_log("WARNING: No broker port found: %s (%d)", mach_error_string(kr), kr);
    }

    /* Create a bootstrap subset so we can register services.
     * Without this, bootstrap_register/check_in fail with error 141
     * because macOS doesn't allow arbitrary service registration.
     * A subset creates a private namespace where we're the authority. */
    kr = bootstrap_subset(bootstrap_port, mach_task_self(), &g_subset_port);
    if (kr == KERN_SUCCESS && g_subset_port != MACH_PORT_NULL) {
        pfb_log("Created bootstrap subset: %u (replacing bootstrap_port %u)",
                g_subset_port, bootstrap_port);
        /* Replace our bootstrap port with the subset */
        task_set_special_port(mach_task_self(), TASK_BOOTSTRAP_PORT, g_subset_port);
        bootstrap_port = g_subset_port;

        /* Write the subset port to a file so app processes can join */
        FILE *f = fopen("/tmp/rosettasim_bootstrap", "w");
        if (f) {
            fprintf(f, "%u\n", g_subset_port);
            fclose(f);
            pfb_log("Bootstrap port written to /tmp/rosettasim_bootstrap");
        }
    } else {
        pfb_log("WARNING: bootstrap_subset failed: %s (%d) — services may not register",
                mach_error_string(kr), kr);
    }

    /* Create the framebuffer surface */
    kr = pfb_create_surface();
    if (kr != KERN_SUCCESS) {
        pfb_log("FATAL: Cannot create framebuffer surface");
        return;
    }

    /* Set up shared framebuffer for host app */
    pfb_setup_shared_framebuffer();

    /* Create a Mach port for our service */
    kr = mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &g_server_port);
    if (kr != KERN_SUCCESS) {
        pfb_log("FATAL: mach_port_allocate failed: %s", mach_error_string(kr));
        return;
    }

    /* Create a send right for the port (for returning to clients) */
    kr = mach_port_insert_right(mach_task_self(), g_server_port, g_server_port,
                                MACH_MSG_TYPE_MAKE_SEND);
    if (kr != KERN_SUCCESS) {
        pfb_log("FATAL: mach_port_insert_right failed: %s", mach_error_string(kr));
        return;
    }
    g_send_port = g_server_port;  /* Same port name in this task */

    pfb_log("PurpleFBServer port created: recv=%u send=%u", g_server_port, g_send_port);

    /* Register PurpleFBServer with the broker so cross-process look_ups work.
     * With bootstrap_fix.dylib active, bootstrap_look_up goes through the broker,
     * so PurpleFBServer must be registered there. */
    pfb_notify_broker("PurpleFBServer", g_send_port);

    /* Start the server thread */
    g_running = 1;

    if (pthread_create(&g_server_thread, NULL, pfb_server_thread, NULL) != 0) {
        pfb_log("FATAL: Cannot create server thread");
        g_running = 0;
        return;
    }
    pthread_detach(g_server_thread);

    /* Start the sync thread */
    if (pthread_create(&g_sync_thread, NULL, pfb_sync_thread, NULL) != 0) {
        pfb_log("WARNING: Cannot create sync thread");
    } else {
        pthread_detach(g_sync_thread);
    }

    /* Swizzle NSAssertionHandler to suppress ALL assertions during init */
    Class assertClass = (Class)objc_getClass("NSAssertionHandler");
    if (assertClass) {
        SEL sel = sel_registerName("handleFailureInFunction:file:lineNumber:description:");
        Method m = class_getInstanceMethod(assertClass, sel);
        if (m) {
            method_setImplementation(m, (IMP)pfb_handleFailureFunc);
            pfb_log("Swizzled NSAssertionHandler (function assertions)");
        }
        SEL sel2 = sel_registerName("handleFailureInMethod:object:file:lineNumber:description:");
        Method m2 = class_getInstanceMethod(assertClass, sel2);
        if (m2) {
            method_setImplementation(m2, (IMP)pfb_handleFailureMethod);
            pfb_log("Swizzled NSAssertionHandler (method assertions)");
        }
    }

    /* Swizzle CAWindowServer._detectDisplays to trace and post-fix display creation.
     * The original _detectDisplays creates PurpleDisplay but the vtable dispatch
     * for new_server() might fail to add the display. After calling the original,
     * we check if displays is empty and log the result. */
    Class wsClass = (Class)objc_getClass("CAWindowServer");
    if (wsClass) {
        SEL detectSel = sel_registerName("_detectDisplays");
        Method detectM = class_getInstanceMethod(wsClass, detectSel);
        if (detectM) {
            /* Save original implementation */
            typedef void (*DetectIMP)(id, SEL);
            __block DetectIMP origDetect = (DetectIMP)method_getImplementation(detectM);

            IMP newDetect = imp_implementationWithBlock((id)^(id self2) {
                pfb_log("_detectDisplays: calling original...");
                origDetect(self2, detectSel);

                /* Check how many displays were added */
                SEL dispSel = sel_registerName("displays");
                id displays = ((id (*)(id, SEL))objc_msgSend)(self2, dispSel);
                SEL countSel = sel_registerName("count");
                unsigned long count = ((unsigned long (*)(id, SEL))objc_msgSend)(displays, countSel);
                pfb_log("_detectDisplays: original added %lu displays", count);

                if (count == 0) {
                    pfb_log("_detectDisplays: No displays found. Will try to use server+context approach.");
                    /* Get the serverWithOptions: or server method */
                    /* For now, just log — the assertion suppression lets us continue */
                }
            });
            method_setImplementation(detectM, newDetect);
            pfb_log("Swizzled _detectDisplays for tracing");
        }
    }

    /* Swizzle BSBaseXPCServer to prevent XPC registration crashes */
    Class bsClass = (Class)objc_getClass("BSBaseXPCServer");
    if (bsClass) {
        SEL regSel = sel_registerName("registerServerSuspended");
        Method regM = class_getInstanceMethod(bsClass, regSel);
        if (regM) {
            IMP noop = imp_implementationWithBlock((id)^(id self2) {
                pfb_log("BSBaseXPCServer.registerServerSuspended → SKIPPED");
            });
            method_setImplementation(regM, noop);
            pfb_log("Swizzled BSBaseXPCServer.registerServerSuspended");
        }
        SEL regSel2 = sel_registerName("registerServer");
        Method regM2 = class_getInstanceMethod(bsClass, regSel2);
        if (regM2) {
            IMP noop2 = imp_implementationWithBlock((id)^(id self2) {
                pfb_log("BSBaseXPCServer.registerServer → SKIPPED");
            });
            method_setImplementation(regM2, noop2);
            pfb_log("Swizzled BSBaseXPCServer.registerServer");
        }
    }

    /* Proactively create and register Purple system ports with the broker.
     * SpringBoard needs these ports available BEFORE it starts:
     *   - PurpleSystemEventPort: GSEvent delivery
     *   - PurpleWorkspacePort: Workspace management
     *   - PurpleSystemAppPort: System app check-in
     *   - com.apple.backboard.system-app-server: System app management
     *   - com.apple.backboard.checkin: Initial check-in
     * These are normally created by GSEventInitializeWorkspaceWithQueue which
     * we skip. Create them now so the broker can serve them to SpringBoard. */
    {
        pfb_log("Pre-registering Purple system ports for SpringBoard...");

        /* These calls create unique ports and register with broker */
        pfb_GSGetPurpleSystemEventPort();
        pfb_GSGetPurpleWorkspacePort();
        pfb_GSGetPurpleSystemAppPort();

        /* Also pre-register the backboard services SpringBoard needs */
        pfb_GSRegisterPurpleNamedPort("com.apple.backboard.system-app-server");
        pfb_GSRegisterPurpleNamedPort("com.apple.backboard.checkin");
        pfb_GSRegisterPurpleNamedPort("com.apple.backboard.animation-fence-arbiter");
        pfb_GSRegisterPurpleNamedPort("com.apple.backboard.hid.focus");
        pfb_GSRegisterPurpleNamedPort("com.apple.backboard.TouchDeliveryPolicyServer");
        pfb_GSRegisterPurpleNamedPort("com.apple.backboard.display.services");

        pfb_log("Purple system ports registered with broker");

        /* Start display services handler thread.
         * Listens on com.apple.backboard.display.services port and responds
         * to BKSDisplayServicesGetMainScreenInfo (msg_id 0x5B916D = 6001005)
         * and BKSDisplayServicesStart (msg_id 0x5B9168 = 6001000). */
        for (int si = 0; si < g_service_count; si++) {
            if (strstr(g_services[si].name, "display.services")) {
                if (__sync_bool_compare_and_swap(&g_display_services_started, 0, 1)) {
                    pfb_log("Starting display services handler on port %u", g_services[si].port);
                    mach_port_t *ds_port = malloc(sizeof(mach_port_t));
                    *ds_port = g_services[si].port;
                    pthread_t ds_thread;
                    pthread_create(&ds_thread, NULL, pfb_display_services_thread, ds_port);
                    pthread_detach(ds_thread);
                } else {
                    pfb_log("Display services handler already started; not starting again");
                }
                break;
            }
        }
    }

    pfb_log("PurpleFBServer ready — all interpositions active");

    /* Main queue IS draining — use dispatch_after for GPU context binding.
     * add_context must run on the main thread to avoid lock contention
     * with the MIG server thread. */
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 20LL * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        pfb_log("GPU_BIND: starting on main thread...");

        /* First: try CATransaction flush on main thread — may trigger attach_contexts
         * naturally through the server's commit processing path. */
        {
            Class catCls = (Class)objc_getClass("CATransaction");
            if (catCls) {
                ((void(*)(id, SEL))objc_msgSend)((id)catCls, sel_registerName("flush"));
                pfb_log("GPU_BIND: CATransaction flush done on main thread");
            }
        }

        /* Get WindowServer and display */
        Class wsClass = (Class)objc_getClass("CAWindowServer");
        if (!wsClass) { pfb_log("GPU_BIND: no CAWindowServer"); return; }
        id ws = ((id(*)(id, SEL))objc_msgSend)((id)wsClass, sel_registerName("server"));
        if (!ws) { pfb_log("GPU_BIND: no server"); return; }
        id displays = ((id(*)(id, SEL))objc_msgSend)(ws, sel_registerName("displays"));
        unsigned long dcnt = displays ? ((unsigned long(*)(id, SEL))objc_msgSend)(
            displays, sel_registerName("count")) : 0;
        if (dcnt == 0) { pfb_log("GPU_BIND: no displays"); return; }
        id disp = ((id(*)(id, SEL, unsigned long))objc_msgSend)(
            displays, sel_registerName("objectAtIndex:"), 0UL);

        /* Get C++ server from display */
        void *server_cpp = NULL;
        Ivar implI = class_getInstanceVariable(object_getClass(disp), "_impl");
        if (implI) {
            void *impl = *(void **)((uint8_t *)disp + ivar_getOffset(implI));
            if (impl) server_cpp = *(void **)((uint8_t *)impl + 0x40);
        }
        if (!server_cpp) { pfb_log("GPU_BIND: no server_cpp"); return; }

        /* Calculate add_context address */
        void *known = dlsym(RTLD_DEFAULT, "CARenderServerRenderDisplay");
        if (!known) { pfb_log("GPU_BIND: dlsym failed"); return; }
        ptrdiff_t slide = (ptrdiff_t)known - (ptrdiff_t)0xb9899;
        typedef void (*add_ctx_fn)(void *, void *);
        add_ctx_fn add_ctx = (add_ctx_fn)((uint8_t *)0x12a006 + slide);

        /* Get all contexts */
        Class caCtxCls = (Class)objc_getClass("CAContext");
        id ctxs = ((id(*)(id, SEL))objc_msgSend)((id)caCtxCls, sel_registerName("allContexts"));
        unsigned long cnt = ctxs ? ((unsigned long(*)(id, SEL))objc_msgSend)(
            ctxs, sel_registerName("count")) : 0;
        pfb_log("GPU_BIND: %lu contexts, server=%p, add_ctx=%p", cnt, server_cpp, (void *)add_ctx);

        for (unsigned long i = 0; i < cnt; i++) {
            id ctx = ((id(*)(id, SEL, unsigned long))objc_msgSend)(
                ctxs, sel_registerName("objectAtIndex:"), i);
            if (!ctx) continue;
            Ivar ci = class_getInstanceVariable(object_getClass(ctx), "_impl");
            if (!ci) continue;
            void *cimpl = *(void **)((uint8_t *)ctx + ivar_getOffset(ci));
            if (!cimpl) continue;
            unsigned int cid = ((unsigned int(*)(id, SEL))objc_msgSend)(
                ctx, sel_registerName("contextId"));
            pfb_log("GPU_BIND: adding ctx[%lu] id=%u impl=%p", i, cid, cimpl);
            add_ctx(server_cpp, cimpl);
            pfb_log("GPU_BIND: ctx[%lu] added OK", i);
        }

        /* Check result */
        typedef struct { double x; double y; } CGPoint_t;
        CGPoint_t center = { 375.0, 667.0 };
        unsigned int bound = ((unsigned int(*)(id, SEL, CGPoint_t))objc_msgSend)(
            disp, sel_registerName("contextIdAtPosition:"), center);
        pfb_log("GPU_BIND: contextIdAtPosition=%u (after add_context)", bound);
    });
}

/* ================================================================
 * Library destructor
 * ================================================================ */

__attribute__((destructor))
static void pfb_cleanup(void) {
    g_running = 0;

    if (g_memory_entry != MACH_PORT_NULL) {
        mach_port_deallocate(mach_task_self(), g_memory_entry);
    }
    if (g_surface_addr != 0) {
        vm_deallocate(mach_task_self(), g_surface_addr, PFB_SURFACE_ALLOC);
    }
    if (g_shared_fb != MAP_FAILED) {
        uint32_t total = ROSETTASIM_FB_TOTAL_SIZE(PFB_PIXEL_WIDTH, PFB_PIXEL_HEIGHT);
        munmap(g_shared_fb, total);
    }
    if (g_shared_fd >= 0) {
        close(g_shared_fd);
        unlink(ROSETTASIM_FB_GPU_PATH);
        unlink(ROSETTASIM_FB_CONTEXT_PATH);
    }
    if (g_server_port != MACH_PORT_NULL) {
        mach_port_deallocate(mach_task_self(), g_server_port);
    }

    pfb_log("Cleaned up");
}
