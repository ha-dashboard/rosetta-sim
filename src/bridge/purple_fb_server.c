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
    char buf[512];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(buf, sizeof(buf) - 1, fmt, ap);
    va_end(ap);
    if (n > 0) {
        /* Non-blocking write — drop message if pipe is full.
         * Prevents sync thread death when broker stops draining stderr. */
        static int _nb_set = 0;
        if (!_nb_set) { _nb_set = 1; fcntl(STDERR_FILENO, F_SETFL, O_NONBLOCK); }
        write(STDERR_FILENO, "[PurpleFBServer] ", 17);
        write(STDERR_FILENO, buf, n);
        write(STDERR_FILENO, "\n", 1);
    }
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
static volatile int g_gpu_inject_done = 0; /* set by GPU_INJECT after mutex reinit */
static volatile void *g_display_surface = NULL; /* Display+0x138: surface object */
static volatile void *g_display_pixel_buffer = NULL; /* surf_obj+0x08: actual pixel data */
static volatile vm_address_t g_server_surface_map = 0; /* CARenderServer's vm_map of our surface */

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
    /* Copy from Display's actual rendered surface.
     * Re-read Display+0x138 each frame (surface pointer may change).
     * The surface object has a pixel data pointer at +0x08. */
    /* Use cached pixel buffer (set once by GPU_INJECT from surf_obj+0x08).
     * This is CARenderServer's actual render target — a persistent vm_allocate'd
     * region that doesn't change between frames. */
    if (g_display_pixel_buffer != NULL) {
        memcpy(pixel_dest, (void *)g_display_pixel_buffer, PFB_SURFACE_SIZE);
    } else if (g_display_surface != NULL) {
        /* Fallback: copy surface object raw (includes 32-byte header as noise) */
        memcpy(pixel_dest, (void *)g_display_surface, PFB_SURFACE_SIZE);
    } else if (g_surface_addr != 0) {
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
         * CARenderServer has just finished rendering. Read pixel data NOW
         * from the Display's surface object while the pointer is valid. */
        if (g_shared_fb != MAP_FAILED && g_display_surface) {
            uint8_t *pixel_dest = (uint8_t *)g_shared_fb + ROSETTASIM_FB_META_SIZE;
            RosettaSimFramebufferHeader *fhdr = (RosettaSimFramebufferHeader *)g_shared_fb;
            void *surf_obj = (void *)g_display_surface;

            /* Read surface metadata */
            uint32_t s_width  = *(uint32_t *)((uint8_t *)surf_obj + 24);
            uint32_t s_height = *(uint32_t *)((uint8_t *)surf_obj + 28);
            /* Try to find stride at various offsets */
            uint32_t s_stride = *(uint32_t *)((uint8_t *)surf_obj + 32);
            static int _flush_logged = 0;
            if (!_flush_logged) {
                _flush_logged = 1;
                pfb_log("flush_shmem: surface %ux%u stride_candidate=%u",
                        s_width, s_height, s_stride);
                /* Also dump bytes 32-63 for stride detection */
                uint32_t *hdr32 = (uint32_t *)((uint8_t *)surf_obj + 32);
                pfb_log("flush_shmem: surf+32 as uint32: %u %u %u %u %u %u %u %u",
                        hdr32[0], hdr32[1], hdr32[2], hdr32[3],
                        hdr32[4], hdr32[5], hdr32[6], hdr32[7]);
            }

            /* Get pixel data pointer (at surf_obj+0x08) */
            void *pixel_buf = *(void **)((uint8_t *)surf_obj + 0x08);
            if (pixel_buf && (uint64_t)pixel_buf > 0x100000000ULL) {
                /* Determine source stride */
                int src_stride = PFB_BYTES_PER_ROW; /* 3000 default */
                if (s_stride > 0 && s_stride <= 8192 && s_stride >= PFB_BYTES_PER_ROW) {
                    src_stride = (int)s_stride;
                }

                if (src_stride == PFB_BYTES_PER_ROW) {
                    memcpy(pixel_dest, pixel_buf, PFB_SURFACE_SIZE);
                } else {
                    /* Row-by-row copy with stride conversion */
                    uint8_t *src = (uint8_t *)pixel_buf;
                    uint8_t *dst = pixel_dest;
                    for (int row = 0; row < PFB_PIXEL_HEIGHT; row++) {
                        memcpy(dst, src, PFB_BYTES_PER_ROW);
                        src += src_stride;
                        dst += PFB_BYTES_PER_ROW;
                    }
                }
                fhdr->frame_counter++;
                fhdr->flags |= ROSETTASIM_FB_FLAG_FRAME_READY;

                if (!_flush_logged) {
                    pfb_log("flush_shmem: copied from pixel_buf=%p stride=%d",
                            pixel_buf, src_stride);
                }
            } else {
                pfb_sync_to_shared();
            }
        } else {
            pfb_sync_to_shared();
        }
        pfb_log("flush_shmem: syncing to shared framebuffer");

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
        pfb_sync_to_shared();

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
        if (g_cached_display && g_gpu_inject_done) {
            /* Session 21: call PurpleServer vtable render functions directly.
             * CARenderServerRenderDisplay has port=0 in backboardd (IS the server).
             * Instead, call the C++ vtable methods on the server object. */
            static void *_server_cpp = NULL;
            static int _render_init = 0;
            if (!_render_init) {
                _render_init = 1;
                Ivar implI = class_getInstanceVariable(
                    object_getClass(g_cached_display), "_impl");
                if (implI) {
                    void *impl = *(void **)((uint8_t *)g_cached_display + ivar_getOffset(implI));
                    if (impl) _server_cpp = *(void **)((uint8_t *)impl + 0x40);
                }
                if (_server_cpp) {
                    void **vtable = *(void ***)_server_cpp;
                    pfb_log("RENDER_DIRECT: server=%p vtable=%p", _server_cpp, (void *)vtable);
                    /* Log first 10 vtable entries */
                    for (int vi = 0; vi < 10; vi++) {
                        Dl_info di;
                        if (dladdr(vtable[vi], &di) && di.dli_sname)
                            pfb_log("  svt[%d]: %p (%s)", vi, vtable[vi], di.dli_sname);
                        else
                            pfb_log("  svt[%d]: %p", vi, vtable[vi]);
                    }
                }
            }

            if (_server_cpp) {
                /* CATransaction flush + display update */
                {
                    Class catCls = (Class)objc_getClass("CATransaction");
                    if (catCls) {
                        ((void(*)(id, SEL))objc_msgSend)((id)catCls, sel_registerName("flush"));
                    }
                }
                ((void(*)(id, SEL))objc_msgSend)(g_cached_display, sel_registerName("update"));

                /* Call PurpleServer::run_loop() would block.
                 * Instead call immediate_render (vtable[5]) which does one frame.
                 * If it's a no-op in base, try render_surface (vtable[9]). */
                void **vtable = *(void ***)_server_cpp;
                typedef void (*server_fn)(void *);
                /* vtable[5] = immediate_render */
                ((server_fn)vtable[5])(_server_cpp);
            }

            if (!g_update_logged) {
                g_update_logged = 1;
                pfb_log("RENDER_DIRECT: calling vtable[5] (immediate_render) each tick");

                /* Surface stride/format diagnostic */
                if (g_display_surface) {
                    uint8_t *surf = (uint8_t *)g_display_surface;

                    /* Check for header at start of surface */
                    uint32_t *hdr32 = (uint32_t *)surf;
                    pfb_log("STRIDE_DIAG: surface=%p first 32B as uint32: %u %u %u %u %u %u %u %u",
                            surf, hdr32[0], hdr32[1], hdr32[2], hdr32[3],
                            hdr32[4], hdr32[5], hdr32[6], hdr32[7]);
                    pfb_log("STRIDE_DIAG: first 16B hex: %02x%02x%02x%02x %02x%02x%02x%02x %02x%02x%02x%02x %02x%02x%02x%02x",
                            surf[0],surf[1],surf[2],surf[3],
                            surf[4],surf[5],surf[6],surf[7],
                            surf[8],surf[9],surf[10],surf[11],
                            surf[12],surf[13],surf[14],surf[15]);

                    /* Scan for correct stride at row 710 (known content row) */
                    for (int stride = 2048; stride <= 4096; stride += 64) {
                        int off = 710 * stride;
                        if (off + 400 > 6000000) continue;
                        int nz = 0;
                        for (int x = 0; x < 100; x++) {
                            int p = off + x * 4;
                            if (surf[p] || surf[p+1] || surf[p+2]) nz++;
                        }
                        if (nz > 30)
                            pfb_log("STRIDE_DIAG: stride=%d → %d/100 non-zero at row 710", stride, nz);
                    }

                    /* Find header size: scan for first row of pixel data.
                     * Header has metadata (width=750, height=1334 at bytes 24-31).
                     * Pixel data starts at some offset. Try offsets 32, 64, 128. */
                    for (int hdr_off = 32; hdr_off <= 256; hdr_off += 32) {
                        /* At this offset, check if stride=3072 produces content */
                        int nz = 0;
                        /* Check "row 0" at hdr_off with stride 3072 */
                        for (int x = 0; x < 100; x++) {
                            int p = hdr_off + x * 4;
                            if (surf[p] || surf[p+1] || surf[p+2]) nz++;
                        }
                        /* Check "row 400" */
                        int nz400 = 0;
                        for (int x = 0; x < 100; x++) {
                            int p = hdr_off + 400 * 3072 + x * 4;
                            if (surf[p] || surf[p+1] || surf[p+2]) nz400++;
                        }
                        if (nz > 10 || nz400 > 10)
                            pfb_log("STRIDE_DIAG: hdr_off=%d stride=3072: row0_nz=%d row400_nz=%d",
                                    hdr_off, nz, nz400);
                    }

                    /* Display+0x138 is a surface object. Dump raw pointers to find
                     * the actual pixel data buffer inside. */
                    pfb_log("STRIDE_DIAG: surface object raw dump (0x100 bytes):");
                    for (int off = 0; off < 0x100; off += 32) {
                        pfb_log("  +%02x: %016llx %016llx %016llx %016llx",
                                off,
                                (unsigned long long)*(uint64_t *)(surf + off),
                                (unsigned long long)*(uint64_t *)(surf + off + 8),
                                (unsigned long long)*(uint64_t *)(surf + off + 16),
                                (unsigned long long)*(uint64_t *)(surf + off + 24));
                    }
                    /* The header at +0x08 looks like a pointer (0x7fb0XXXXXXXX).
                     * This could be the actual pixel data buffer. Check it. */
                    uint64_t pixel_ptr = *(uint64_t *)(surf + 0x08);
                    pfb_log("STRIDE_DIAG: surf+0x08 (possible pixel ptr) = 0x%llx",
                            (unsigned long long)pixel_ptr);
                    if (pixel_ptr > 0x100000000ULL && pixel_ptr < 0x800000000000ULL) {
                        uint8_t *pp = (uint8_t *)pixel_ptr;
                        /* Try strides 3000 and 3072 on this pointer */
                        for (int ts = 3000; ts <= 3072; ts += 72) {
                            int nz = 0;
                            for (int row = 0; row < 1334; row++) {
                                for (int x = 0; x < 750; x++) {
                                    int p = row * ts + x * 4;
                                    if (p + 3 < 5500000 && (pp[p] || pp[p+1] || pp[p+2]))
                                        nz++;
                                }
                            }
                            pfb_log("STRIDE_DIAG: pixel_ptr stride=%d: %d/%d non-zero",
                                    ts, nz, 750*1334);
                        }
                        /* Sample some rows */
                        for (int row = 0; row < 1334; row += 100) {
                            int nz = 0;
                            for (int x = 0; x < 750; x++) {
                                int p = row * 3000 + x * 4;
                                if (pp[p] || pp[p+1] || pp[p+2]) nz++;
                            }
                            if (nz > 0)
                                pfb_log("STRIDE_DIAG: pixel_ptr row %d: %d/750 non-zero (stride 3000)", row, nz);
                        }
                    }
                    /* Also try surf+0x10 as pixel ptr */
                    uint64_t pixel_ptr2 = *(uint64_t *)(surf + 0x10);
                    pfb_log("STRIDE_DIAG: surf+0x10 = 0x%llx", (unsigned long long)pixel_ptr2);
                }

                /* Pixel format diagnostic — sample non-zero pixels from cached buffer */
                if (g_display_pixel_buffer) {
                    uint8_t *px = (uint8_t *)g_display_pixel_buffer;
                    int logged = 0;
                    for (int i = 0; i < 750 * 1334 && logged < 10; i++) {
                        int off = i * 4;
                        if (px[off] || px[off+1] || px[off+2]) {
                            pfb_log("PIXEL_FMT: [%d] = (%u,%u,%u,%u) row=%d col=%d",
                                    i, px[off], px[off+1], px[off+2], px[off+3],
                                    i / 750, i % 750);
                            logged++;
                        }
                    }
                    if (logged == 0)
                        pfb_log("PIXEL_FMT: no non-zero RGB pixels found in buffer!");
                    /* Also count total non-zero and check alpha distribution */
                    int total_nz = 0, alpha_only = 0, has_alpha = 0;
                    for (int i = 0; i < 30000; i++) {
                        int off = i * 4;
                        int rgb = px[off] || px[off+1] || px[off+2];
                        int a = px[off+3];
                        if (rgb) total_nz++;
                        if (!rgb && a) alpha_only++;
                        if (a) has_alpha++;
                    }
                    pfb_log("PIXEL_FMT: first 30K: rgb_nz=%d alpha_only=%d has_alpha=%d",
                            total_nz, alpha_only, has_alpha);
                }

                /* OpenGL readback diagnostic — check if we can read the GPU framebuffer */
                {
                    void *gl_read = dlsym(RTLD_DEFAULT, "glReadPixels");
                    void *cgl_ctx = dlsym(RTLD_DEFAULT, "CGLGetCurrentContext");
                    pfb_log("GL_READBACK: glReadPixels=%p CGLGetCurrentContext=%p", gl_read, cgl_ctx);
                    if (cgl_ctx) {
                        typedef void *(*CGLGetCtxFn)(void);
                        void *ctx = ((CGLGetCtxFn)cgl_ctx)();
                        pfb_log("GL_READBACK: current CGL context = %p", ctx);
                    }
                    if (gl_read) {
                        /* Try reading 1 pixel to test */
                        uint8_t test_pixel[4] = {0};
                        typedef void (*glReadPixelsFn)(int, int, int, int, unsigned int, unsigned int, void *);
                        /* GL_BGRA = 0x80E1, GL_UNSIGNED_BYTE = 0x1401 */
                        ((glReadPixelsFn)gl_read)(0, 0, 1, 1, 0x80E1, 0x1401, test_pixel);
                        pfb_log("GL_READBACK: test pixel (0,0) = (%u,%u,%u,%u)",
                                test_pixel[0], test_pixel[1], test_pixel[2], test_pixel[3]);
                        /* Check GL error */
                        typedef unsigned int (*glGetErrorFn)(void);
                        glGetErrorFn getErr = (glGetErrorFn)dlsym(RTLD_DEFAULT, "glGetError");
                        if (getErr) {
                            unsigned int err = getErr();
                            pfb_log("GL_READBACK: glGetError = 0x%x (%s)",
                                    err, err == 0 ? "GL_NO_ERROR" : "ERROR");
                        }
                    }
                }
            }
            /* Periodic contextIdAtPosition check (every ~5s) */
            {
                static int _ctx_check = 0;
                if (++_ctx_check >= 300) {
                    _ctx_check = 0;
                    typedef struct { double x; double y; } CGPoint_t;
                    CGPoint_t center = { 187.5, 333.5 };
                    SEL ctxSel = sel_registerName("contextIdAtPosition:");
                    unsigned int cid = ((unsigned int(*)(id, SEL, CGPoint_t))objc_msgSend)(
                        g_cached_display, ctxSel, center);
                    pfb_log("PERIODIC_CHECK: contextIdAtPosition=%u", cid);
                }
            }
        }

        /* DISABLED: Standalone add_context blocks on context mutex and kills sync thread.
         * GPU_INJECT dispatch_after handles context binding on main thread instead. */

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
        /* If this maps our memory entry (same object port), save the address.
         * CARenderServer renders to THIS mapping, not our g_surface_addr. */
        if (kr == KERN_SUCCESS && addr && *addr != g_surface_addr &&
            object == g_memory_entry) {
            g_server_surface_map = *addr;
            pfb_log("vm_map: CAPTURED server's mapping of our surface at %p", (void *)*addr);
        }
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
     * Session 21: server+0x58 is PurpleDisplay*, NOT Shmem.
     * hit_test calls Display::transform() (vtable[14]) which returns Display+0x148.
     * Transform::get_scale() reads double at Transform+0x80.
     * If scale is 0 (uninitialized), point becomes (0,0) and bounds check may fail.
     * Also: context+0x28 mutex must be properly initialized for hit_test to iterate. */
    /* Reduced from 20s to 5s — sync thread needs g_cached_display early.
     * App contexts should be registered by 5s (RegisterClient fires at ~3s). */
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5LL * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        pfb_log("GPU_INJECT: session 21 — Display transform + mutex fix...");

        /* Get server C++ object */
        Class wsCls = (Class)objc_getClass("CAWindowServer");
        if (!wsCls) { pfb_log("GPU_INJECT: no CAWindowServer"); return; }
        id ws = ((id(*)(id, SEL))objc_msgSend)((id)wsCls, sel_registerName("server"));
        if (!ws) { pfb_log("GPU_INJECT: no server"); return; }
        id disps = ((id(*)(id, SEL))objc_msgSend)(ws, sel_registerName("displays"));
        unsigned long dcnt = disps ? ((unsigned long(*)(id, SEL))objc_msgSend)(
            disps, sel_registerName("count")) : 0;
        if (dcnt == 0) { pfb_log("GPU_INJECT: no displays"); return; }
        id disp = ((id(*)(id, SEL, unsigned long))objc_msgSend)(
            disps, sel_registerName("objectAtIndex:"), 0UL);

        void *server_cpp = NULL;
        Ivar implI = class_getInstanceVariable(object_getClass(disp), "_impl");
        if (implI) {
            void *impl = *(void **)((uint8_t *)disp + ivar_getOffset(implI));
            if (impl) server_cpp = *(void **)((uint8_t *)impl + 0x40);
        }
        if (!server_cpp) { pfb_log("GPU_INJECT: no server_cpp"); return; }

        /* Set g_cached_display for the sync thread to use */
        g_cached_display = disp;
        pfb_log("GPU_INJECT: set g_cached_display=%p", (void *)disp);

        /* Cache the Display's actual render surface (Display+0x138)
         * This is where CARenderServer writes rendered pixels. */
        {
            void *display_cpp_early = NULL;
            Ivar iI = class_getInstanceVariable(object_getClass(disp), "_impl");
            if (iI) {
                void *impl = *(void **)((uint8_t *)disp + ivar_getOffset(iI));
                if (impl) {
                    void *srv = *(void **)((uint8_t *)impl + 0x40);
                    if (srv) display_cpp_early = *(void **)((uint8_t *)srv + 0x58);
                }
            }
            if (display_cpp_early) {
                void *mapped = *(void **)((uint8_t *)display_cpp_early + 0x138);
                if (mapped) {
                    g_display_surface = mapped;
                    pfb_log("GPU_INJECT: set g_display_surface=%p (Display+0x138)", mapped);
                    /* Cache the pixel data pointer at surf_obj+0x08.
                     * This is a persistent vm_allocate'd buffer. */
                    void *pixel_buf = *(void **)((uint8_t *)mapped + 0x08);
                    if (pixel_buf && (uint64_t)pixel_buf > 0x100000000ULL) {
                        g_display_pixel_buffer = pixel_buf;
                        pfb_log("GPU_INJECT: CACHED pixel buffer=%p (surf+0x08)", pixel_buf);
                    }
                }
            }
        }

        /* ============================================================
         * Step 1: Fix Display Transform
         * server+0x58 = PurpleDisplay* (C++ object with vtable)
         * PurpleDisplay::transform() returns this+0x148 (CA::Transform)
         * CA::Transform::get_scale() reads double at +0x80
         * For hit_test: point *= scale, then bounds check
         * ============================================================ */
        void *display_cpp = *(void **)((uint8_t *)server_cpp + 0x58);
        pfb_log("GPU_INJECT: PurpleDisplay* at server+0x58 = %p", display_cpp);

        if (display_cpp) {
            /* Dump Display vtable to confirm it's a real C++ object */
            uint64_t vtable_ptr = *(uint64_t *)display_cpp;
            pfb_log("GPU_INJECT: Display vtable = 0x%llx", (unsigned long long)vtable_ptr);
            if (vtable_ptr > 0x100000 && vtable_ptr < 0x7fffffffffffULL) {
                Dl_info vinfo;
                if (dladdr((void *)vtable_ptr, &vinfo) && vinfo.dli_sname)
                    pfb_log("GPU_INJECT: Display vtable → %s", vinfo.dli_sname);
            }

            /* Transform is at Display+0x148 */
            uint8_t *transform = (uint8_t *)display_cpp + 0x148;
            /* Scale is at Transform+0x80 */
            double *scale_ptr = (double *)(transform + 0x80);
            uint8_t *flags_ptr = transform + 0x90;

            pfb_log("GPU_INJECT: Transform at %p, scale=%.4f, flags=0x%02x",
                    transform, *scale_ptr, *flags_ptr);

            /* Dump Transform raw (first 0x98 bytes) */
            pfb_log("GPU_INJECT: Transform RAW:");
            for (int off = 0; off < 0x98; off += 32) {
                pfb_log("  +%02x: %016llx %016llx %016llx %016llx",
                        off,
                        (unsigned long long)*(uint64_t *)(transform + off),
                        (unsigned long long)*(uint64_t *)(transform + off + 8),
                        (unsigned long long)*(uint64_t *)(transform + off + 16),
                        (unsigned long long)*(uint64_t *)(transform + off + 24));
            }

            /* If scale is 0 or uninitialized, write identity scale = 1.0 */
            if (*scale_ptr == 0.0 || *scale_ptr != *scale_ptr /* NaN */) {
                double identity_scale = 1.0;
                *scale_ptr = identity_scale;
                /* Clear complex-transform flag (bit 4 at +0x90) */
                *flags_ptr &= ~0x10;
                pfb_log("GPU_INJECT: WROTE scale=1.0 at Display+0x1C8, cleared flag");
            } else {
                pfb_log("GPU_INJECT: scale already set to %.4f, leaving as-is", *scale_ptr);
            }
        }

        /* ============================================================
         * Step 2: Dump context list (already populated by RegisterClient)
         * ============================================================ */
        void *list = *(void **)((uint8_t *)server_cpp + 0x68);
        uint64_t count = *(uint64_t *)((uint8_t *)server_cpp + 0x78);
        pfb_log("GPU_INJECT: context list at server+0x68=%p count=%llu", list, (unsigned long long)count);

        if (list && count > 0) {
            for (uint64_t i = 0; i < count && i < 10; i++) {
                void *entry = *(void **)((uint8_t *)list + i * 0x10);
                uint64_t meta = *(uint64_t *)((uint8_t *)list + i * 0x10 + 8);
                if (entry) {
                    uint32_t cid = *(uint32_t *)((uint8_t *)entry + 0x0C);
                    pfb_log("  list[%llu]: ctx=%p meta=0x%llx ctx_id=%u",
                            (unsigned long long)i, entry, (unsigned long long)meta, cid);
                }
            }
        }

        /* ============================================================
         * Step 3: Properly initialize context+0x28 mutexes
         * hit_test calls pthread_mutex_lock(ctx+0x28) for each context.
         * If mutex has __sig=0 (uninitialized) and is held by the
         * RegisterClient MIG handler, pthread_mutex_lock blocks forever.
         * Fix: pthread_mutex_init to reset to unlocked state.
         * ============================================================ */
        if (list && count > 0) {
            pfb_log("GPU_INJECT: initializing context mutexes...");
            for (uint64_t i = 0; i < count && i < 20; i++) {
                void *ctx_impl = *(void **)((uint8_t *)list + i * 0x10);
                if (!ctx_impl) continue;
                uint32_t cid = *(uint32_t *)((uint8_t *)ctx_impl + 0x0C);
                pthread_mutex_t *mtx = (pthread_mutex_t *)((uint8_t *)ctx_impl + 0x28);
                /* Dump current mutex state */
                uint32_t sig = *(uint32_t *)mtx;
                pfb_log("  ctx[%llu] id=%u mutex __sig=0x%x", (unsigned long long)i, cid, sig);
                /* Force reinitialize: zero the memory then init */
                memset(mtx, 0, sizeof(pthread_mutex_t));
                int rc = pthread_mutex_init(mtx, NULL);
                pfb_log("  ctx[%llu] mutex_init rc=%d, new __sig=0x%x",
                        (unsigned long long)i, rc, *(uint32_t *)mtx);
            }
        }

        /* ============================================================
         * Step 4: Also init mutexes on CAContext allContexts impls
         * (may differ from direct list entries)
         * ============================================================ */
        Class caCtxCls = (Class)objc_getClass("CAContext");
        id ctxs = ((id(*)(id, SEL))objc_msgSend)((id)caCtxCls, sel_registerName("allContexts"));
        unsigned long ctx_cnt = ctxs ? ((unsigned long(*)(id, SEL))objc_msgSend)(
            ctxs, sel_registerName("count")) : 0;
        pfb_log("GPU_INJECT: CAContext.allContexts count=%lu", ctx_cnt);

        for (unsigned long i = 0; i < ctx_cnt; i++) {
            id ctx = ((id(*)(id, SEL, unsigned long))objc_msgSend)(
                ctxs, sel_registerName("objectAtIndex:"), i);
            if (!ctx) continue;
            Ivar ci = class_getInstanceVariable(object_getClass(ctx), "_impl");
            if (!ci) continue;
            void *cimpl = *(void **)((uint8_t *)ctx + ivar_getOffset(ci));
            if (!cimpl) continue;
            unsigned int cid = ((unsigned int(*)(id, SEL))objc_msgSend)(
                ctx, sel_registerName("contextId"));

            pthread_mutex_t *mtx = (pthread_mutex_t *)((uint8_t *)cimpl + 0x28);
            uint32_t sig = *(uint32_t *)mtx;
            if (sig != 0x32AAABA7) { /* _PTHREAD_MUTEX_SIG */
                memset(mtx, 0, sizeof(pthread_mutex_t));
                pthread_mutex_init(mtx, NULL);
                pfb_log("GPU_INJECT: allCtx[%lu] id=%u impl=%p mutex reinit (was sig=0x%x)",
                        i, cid, cimpl, sig);
            } else {
                /* Mutex is properly initialized — try unlock in case it's held */
                pthread_mutex_trylock(mtx);
                pthread_mutex_unlock(mtx);
                pfb_log("GPU_INJECT: allCtx[%lu] id=%u impl=%p mutex force-unlocked",
                        i, cid, cimpl);
            }

            /* Also dump root_layer_handle area for bounds check debug */
            /* root_layer_handle is at context+some_offset, and bounds at handle+0xA0 */
        }

        /* ============================================================
         * Step 5: Check contextIdAtPosition
         * ============================================================ */
        typedef struct { double x; double y; } CGPoint_t;

        /* Try multiple positions */
        CGPoint_t positions[] = {
            { 0.0, 0.0 },       /* origin */
            { 187.5, 333.5 },   /* center of points */
            { 375.0, 667.0 },   /* bottom-right of points */
            { 1.0, 1.0 },       /* near origin */
        };

        for (int pi = 0; pi < 4; pi++) {
            unsigned int cid = ((unsigned int(*)(id, SEL, CGPoint_t))objc_msgSend)(
                disp, sel_registerName("contextIdAtPosition:"), positions[pi]);
            pfb_log("GPU_INJECT: contextIdAtPosition(%.1f, %.1f) = %u",
                    positions[pi].x, positions[pi].y, cid);
        }

        /* If still 0, try triggering a render cycle first */
        {
            /* CARenderServerRenderDisplay to trigger full render pipeline */
            void *render_fn = dlsym(RTLD_DEFAULT, "CARenderServerRenderDisplay");
            if (render_fn) {
                typedef mach_port_t (*get_port_fn)(void);
                get_port_fn gp = (get_port_fn)dlsym(RTLD_DEFAULT, "CARenderServerGetServerPort");
                mach_port_t srv_port = gp ? gp() : 0;
                id display_name = ((id(*)(id, SEL))objc_msgSend)(disp, sel_registerName("name"));
                if (srv_port && display_name) {
                    pfb_log("GPU_INJECT: triggering CARenderServerRenderDisplay...");
                    typedef int (*render_fn_t)(mach_port_t, id, id, int, int);
                    ((render_fn_t)render_fn)(srv_port, display_name, NULL, 0, 0);

                    /* Re-check after render */
                    CGPoint_t center = { 187.5, 333.5 };
                    unsigned int after = ((unsigned int(*)(id, SEL, CGPoint_t))objc_msgSend)(
                        disp, sel_registerName("contextIdAtPosition:"), center);
                    pfb_log("GPU_INJECT: AFTER RENDER contextIdAtPosition(187.5, 333.5) = %u", after);
                }
            }
        }

        /* ============================================================
         * Step 6: Diagnose bound context — check root layer
         * The bound context needs a committed layer tree for rendering.
         * ============================================================ */
        unsigned int bound_cid;
        {
            /* Find which context is bound */
            CGPoint_t center2 = { 187.5, 333.5 };
            bound_cid = ((unsigned int(*)(id, SEL, CGPoint_t))objc_msgSend)(
                disp, sel_registerName("contextIdAtPosition:"), center2);
            pfb_log("GPU_INJECT: bound context at center = %u", bound_cid);

            for (unsigned long i = 0; i < ctx_cnt; i++) {
                id ctx = ((id(*)(id, SEL, unsigned long))objc_msgSend)(
                    ctxs, sel_registerName("objectAtIndex:"), i);
                if (!ctx) continue;
                unsigned int cid = ((unsigned int(*)(id, SEL))objc_msgSend)(
                    ctx, sel_registerName("contextId"));

                /* Check layer property */
                SEL layerSel = sel_registerName("layer");
                id layer = NULL;
                if (class_respondsToSelector(object_getClass(ctx), layerSel))
                    layer = ((id(*)(id, SEL))objc_msgSend)(ctx, layerSel);
                pfb_log("GPU_INJECT: ctx[%lu] id=%u layer=%p %s",
                        i, cid, (void *)layer,
                        cid == bound_cid ? "*** BOUND ***" : "");

                if (layer) {
                    /* Check sublayers */
                    id sublayers = ((id(*)(id, SEL))objc_msgSend)(
                        layer, sel_registerName("sublayers"));
                    unsigned long slc = sublayers ? ((unsigned long(*)(id, SEL))objc_msgSend)(
                        sublayers, sel_registerName("count")) : 0;
                    pfb_log("  sublayer count=%lu", slc);
                }

                /* Check C++ impl root_layer area */
                Ivar ci = class_getInstanceVariable(object_getClass(ctx), "_impl");
                if (ci) {
                    void *cimpl = *(void **)((uint8_t *)ctx + ivar_getOffset(ci));
                    if (cimpl) {
                        /* Scan for plausible root layer pointers */
                        for (int off = 0x58; off <= 0x78; off += 8) {
                            void *ptr = *(void **)((uint8_t *)cimpl + off);
                            if (ptr && (uint64_t)ptr > 0x100000 && (uint64_t)ptr < 0x7fffffffffffULL) {
                                /* Check if it has a vtable pointing into QuartzCore */
                                uint64_t vt = *(uint64_t *)ptr;
                                Dl_info di;
                                if (vt > 0x100000 && vt < 0x7fffffffffffULL &&
                                    dladdr((void *)vt, &di) && di.dli_sname)
                                    pfb_log("  impl+0x%x → %p (vtable: %s)", off, ptr, di.dli_sname);
                            }
                        }
                    }
                }
            }
        }

        /* ============================================================
         * Step 6b: Check root_layer on BOUND list entry directly
         * allContexts may not contain the bound context — check list entries
         * ============================================================ */
        if (list && count > 0) {
            pfb_log("GPU_INJECT: checking root_layer on list entries...");
            void *known = dlsym(RTLD_DEFAULT, "CARenderServerRenderDisplay");
            ptrdiff_t slide = known ? (ptrdiff_t)known - (ptrdiff_t)0xb9899 : 0;
            /* CA::Render::Context::root_layer_handle at 0x5e14e (from nm) */
            typedef void *(*root_layer_fn)(void *);
            root_layer_fn get_root = slide ?
                (root_layer_fn)((uint8_t *)0x5e14e + slide) : NULL;

            for (uint64_t i = 0; i < count && i < 10; i++) {
                void *ctx_impl = *(void **)((uint8_t *)list + i * 0x10);
                if (!ctx_impl) continue;
                uint32_t cid = *(uint32_t *)((uint8_t *)ctx_impl + 0x0C);

                /* Lock the context mutex (we initialized it earlier) */
                pthread_mutex_t *mtx = (pthread_mutex_t *)((uint8_t *)ctx_impl + 0x28);
                int lockrc = pthread_mutex_trylock(mtx);

                void *root = NULL;
                if (get_root && lockrc == 0) {
                    root = get_root(ctx_impl);
                    pthread_mutex_unlock(mtx);
                } else if (lockrc != 0) {
                    pfb_log("  list[%llu] id=%u MUTEX LOCKED (rc=%d), skipping root_layer",
                            (unsigned long long)i, cid, lockrc);
                    continue;
                }

                pfb_log("  list[%llu] id=%u root_layer_handle=%p %s",
                        (unsigned long long)i, cid, root,
                        cid == bound_cid ? "*** BOUND ***" : "");

                if (root) {
                    /* BoundsImpl at root+0xA0 — dump it */
                    int32_t *bounds = (int32_t *)((uint8_t *)root + 0xA0);
                    pfb_log("    bounds: x=%d y=%d w=%d h=%d",
                            bounds[0], bounds[1], bounds[2], bounds[3]);
                }
            }
        }

        /* Display surface scan removed — double-dereference causes SIGBUS */

        pfb_log("GPU_INJECT: session 21 complete — enabling sync thread render");
        g_gpu_inject_done = 1;
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
