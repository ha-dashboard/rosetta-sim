/*
 * purple_fb_bridge.m — PurpleFBServer bridge for legacy iOS simulators
 *
 * Usage: purple_fb_bridge <device-UDID>
 *   1. Shutdown sim first
 *   2. Run this tool (registers PurpleFBServer, waits)
 *   3. Boot sim: xcrun simctl boot <UDID>
 *   4. backboardd connects → gets framebuffer → display works
 */

#import <Foundation/Foundation.h>
#import <mach/mach.h>
#import <mach/vm_map.h>
#import <dispatch/dispatch.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <IOSurface/IOSurface.h>
#import <dlfcn.h>

#define PFB_PAGE_SIZE 4096

/* Dynamic dimensions — set from SimDevice.deviceType at startup */
static uint32_t g_pixel_width  = 750;
static uint32_t g_pixel_height = 1334;
static float    g_scale        = 2.0f;
static uint32_t g_bytes_per_row = 0;
static uint32_t g_surface_size  = 0;
static uint32_t g_surface_alloc = 0;

/* PurpleFB reply — 72 bytes, matches Agent A's verified offsets */
#pragma pack(4)
typedef struct {
    mach_msg_header_t          header;     /* +0x00, 24 bytes */
    mach_msg_body_t            body;       /* +0x18, 4 bytes  */
    mach_msg_port_descriptor_t port_desc;  /* +0x1c, 12 bytes — memory_entry at +0x1c */
    uint32_t                   mem_size;   /* +0x28 */
    uint32_t                   stride;     /* +0x2c */
    uint32_t                   pad1;       /* +0x30 */
    uint32_t                   pad2;       /* +0x34 */
    uint32_t                   width;      /* +0x38 */
    uint32_t                   height;     /* +0x3c */
    uint32_t                   pt_width;   /* +0x40 */
    uint32_t                   pt_height;  /* +0x44 */
} PFBReply;
#pragma pack()

extern kern_return_t mach_make_memory_entry_64(
    vm_map_t, memory_object_size_t *, memory_object_offset_t,
    vm_prot_t, mach_port_t *, mem_entry_name_port_t);

static IOSurfaceRef g_iosurface = NULL;
static mach_port_t g_mem_entry = MACH_PORT_NULL; /* for PurpleFB reply */
static void *g_surface_base = NULL;
static int g_flush_count = 0;

static void compute_dimensions(void) {
    g_bytes_per_row = g_pixel_width * 4;
    g_surface_size  = g_bytes_per_row * g_pixel_height;
    g_surface_alloc = ((g_surface_size + PFB_PAGE_SIZE - 1) / PFB_PAGE_SIZE) * PFB_PAGE_SIZE;
}

static void write_metadata(void) {
    /* Write dimensions metadata for the injection dylib and viewer */
    FILE *f = fopen("/tmp/rosettasim_dimensions.json", "w");
    if (f) {
        fprintf(f, "{\"width\":%u,\"height\":%u,\"scale\":%.1f,\"bpr\":%u}\n",
                g_pixel_width, g_pixel_height, g_scale, g_bytes_per_row);
        fclose(f);
    }
}

static void create_surface(void) {
    compute_dimensions();

    /* Create IOSurface — shared with Simulator.app display path */
    NSDictionary *props = @{
        (id)kIOSurfaceWidth:           @(g_pixel_width),
        (id)kIOSurfaceHeight:          @(g_pixel_height),
        (id)kIOSurfaceBytesPerElement: @4,
        (id)kIOSurfaceBytesPerRow:     @(g_bytes_per_row),
        (id)kIOSurfacePixelFormat:     @(0x42475241), /* 'BGRA' */
        (id)kIOSurfaceAllocSize:       @(g_surface_alloc),
    };
    g_iosurface = IOSurfaceCreate((__bridge CFDictionaryRef)props);
    if (!g_iosurface) { NSLog(@"IOSurfaceCreate failed"); return; }

    g_surface_base = IOSurfaceGetBaseAddress(g_iosurface);

    /* Fill with opaque black */
    IOSurfaceLock(g_iosurface, 0, NULL);
    uint8_t *px = (uint8_t *)g_surface_base;
    memset(px, 0, g_surface_size);
    for (uint32_t i = 0; i < g_pixel_width * g_pixel_height; i++) px[i*4+3] = 0xFF;
    IOSurfaceUnlock(g_iosurface, 0, NULL);

    /* Create memory_entry from the IOSurface's backing — for PurpleFB reply.
     * backboardd vm_maps this, NOT the IOSurface port. */
    memory_object_size_t sz = g_surface_alloc;
    kern_return_t kr = mach_make_memory_entry_64(mach_task_self(), &sz,
        (memory_object_offset_t)(uintptr_t)g_surface_base,
        VM_PROT_READ|VM_PROT_WRITE, &g_mem_entry, MACH_PORT_NULL);
    if (kr) { NSLog(@"memory_entry: %s", mach_error_string(kr)); }

    uint32_t sid = IOSurfaceGetID(g_iosurface);
    NSLog(@"IOSurface %ux%u id=%u base=%p mem_entry=0x%x",
          g_pixel_width, g_pixel_height, sid, g_surface_base, g_mem_entry);

    /* Write surface ID and dimensions metadata for injection dylib */
    FILE *idf = fopen("/tmp/rosettasim_surface_id", "w");
    if (idf) { fprintf(idf, "%u\n", sid); fclose(idf); }
    write_metadata();
}

static void handle_msg(mach_port_t port) {
    uint8_t buf[4096];
    mach_msg_header_t *msg = (mach_msg_header_t *)buf;
    kern_return_t kr = mach_msg(msg, MACH_RCV_MSG|MACH_RCV_TIMEOUT, 0, sizeof(buf), port, 0, MACH_PORT_NULL);
    if (kr) return;

    NSLog(@"msg_id=%u size=%u reply=0x%x", msg->msgh_id, msg->msgh_size, msg->msgh_remote_port);

    if (msg->msgh_id == 4 && msg->msgh_remote_port) {
        PFBReply r;
        memset(&r, 0, sizeof(r));
        r.header.msgh_bits = MACH_MSGH_BITS_COMPLEX | MACH_MSGH_BITS(MACH_MSG_TYPE_MOVE_SEND_ONCE, 0);
        r.header.msgh_size = sizeof(r);
        r.header.msgh_remote_port = msg->msgh_remote_port;
        r.header.msgh_id = msg->msgh_id + 100;
        r.body.msgh_descriptor_count = 1;
        r.port_desc.name = g_mem_entry;
        r.port_desc.disposition = MACH_MSG_TYPE_COPY_SEND;
        r.port_desc.type = MACH_MSG_PORT_DESCRIPTOR;
        r.mem_size = g_surface_alloc;
        r.stride = g_bytes_per_row;
        /* width/height = pixel dimensions of the framebuffer */
        r.width = g_pixel_width;
        r.height = g_pixel_height;
        /* pt_width/pt_height = point dimensions for layout.
         * Must be pixel_width/scale for correct UIKit layout.
         * The host CALayer's contentsScale handles Retina display. */
        r.pt_width = (uint32_t)(g_pixel_width / g_scale);
        r.pt_height = (uint32_t)(g_pixel_height / g_scale);

        kr = mach_msg(&r.header, MACH_SEND_MSG, sizeof(r), 0, MACH_PORT_NULL, MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL);
        NSLog(@">>> map_surface reply sent: kr=%d (%ux%u stride=%u)", kr, g_pixel_width, g_pixel_height, g_bytes_per_row);
    } else if (msg->msgh_id == 3) {
        g_flush_count++;
        /* Reply to flush — backboardd waits for this before next frame */
        if (msg->msgh_remote_port) {
            mach_msg_header_t reply;
            memset(&reply, 0, sizeof(reply));
            reply.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_MOVE_SEND_ONCE, 0);
            reply.msgh_size = sizeof(reply);
            reply.msgh_remote_port = msg->msgh_remote_port;
            reply.msgh_id = msg->msgh_id;
            mach_msg(&reply, MACH_SEND_MSG, sizeof(reply), 0, MACH_PORT_NULL, MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL);
        }
        /* Write raw pixels to file for viewer (every frame, atomic rename) */
        if (g_surface_base) {
            FILE *f = fopen("/tmp/sim_framebuffer.raw.tmp", "wb");
            if (f) { fwrite(g_surface_base, 1, g_surface_size, f); fclose(f);
                rename("/tmp/sim_framebuffer.raw.tmp", "/tmp/sim_framebuffer.raw"); }
        }
        /* Log pixel stats periodically */
        if (g_surface_base && (g_flush_count <= 10 || g_flush_count % 50 == 0)) {
            uint32_t *px = (uint32_t *)g_surface_base;
            int nz = 0;
            for (uint32_t i = 0; i < g_pixel_width * g_pixel_height; i++) {
                uint8_t r = (px[i] >> 16) & 0xFF;
                uint8_t g = (px[i] >> 8) & 0xFF;
                uint8_t b = px[i] & 0xFF;
                if (r || g || b) nz++;
            }
            uint32_t center = px[g_pixel_width * (g_pixel_height/2) + g_pixel_width/2];
            NSLog(@"flush #%d: %d/%d non-zero RGB, center=0x%08x, px[0]=0x%08x",
                  g_flush_count, nz, g_pixel_width * g_pixel_height, center, px[0]);
        }
        if (g_flush_count <= 5 || g_flush_count % 100 == 0)
            NSLog(@"flush #%d total", g_flush_count);
    } else if (msg->msgh_id == 1011) {
        /* Display state change — reply if reply port present */
        NSLog(@"msg_id=1011 (display state) size=%u bits=0x%x reply=0x%x",
              msg->msgh_size, msg->msgh_bits, msg->msgh_remote_port);
        if (msg->msgh_remote_port) {
            mach_msg_header_t reply;
            memset(&reply, 0, sizeof(reply));
            reply.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_MOVE_SEND_ONCE, 0);
            reply.msgh_size = sizeof(reply);
            reply.msgh_remote_port = msg->msgh_remote_port;
            reply.msgh_id = msg->msgh_id;
            mach_msg(&reply, MACH_SEND_MSG, sizeof(reply), 0, MACH_PORT_NULL, MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL);
            NSLog(@"  replied to 1011");
        }
        /* Also dump latest frame */
        if (g_surface_base) {
            FILE *f = fopen("/tmp/sim_framebuffer.raw", "wb");
            if (f) { fwrite(g_surface_base, 1, g_surface_size, f); fclose(f); }
        }
    } else {
        NSLog(@"unknown msg_id=%u size=%u reply=0x%x", msg->msgh_id, msg->msgh_size, msg->msgh_remote_port);
        /* Reply to any unknown message with reply port */
        if (msg->msgh_remote_port) {
            mach_msg_header_t reply;
            memset(&reply, 0, sizeof(reply));
            reply.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_MOVE_SEND_ONCE, 0);
            reply.msgh_size = sizeof(reply);
            reply.msgh_remote_port = msg->msgh_remote_port;
            reply.msgh_id = msg->msgh_id;
            mach_msg(&reply, MACH_SEND_MSG, sizeof(reply), 0, MACH_PORT_NULL, MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL);
        }
    }
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 2) { fprintf(stderr, "Usage: %s <UDID>\n", argv[0]); return 1; }
        NSString *udid = [NSString stringWithUTF8String:argv[1]];

        dlopen("/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator", RTLD_NOW);
        Class SimServiceContext = objc_getClass("SimServiceContext");
        NSError *err = nil;

        id ctx = ((id(*)(id,SEL,id,NSError**))objc_msgSend)(
            (id)SimServiceContext, sel_registerName("sharedServiceContextForDeveloperDir:error:"),
            @"/Applications/Xcode.app/Contents/Developer", &err);
        if (!ctx) { NSLog(@"ERROR: context: %@", err); return 1; }

        id devSet = ((id(*)(id,SEL,NSError**))objc_msgSend)(ctx, sel_registerName("defaultDeviceSetWithError:"), &err);
        NSDictionary *devs = ((id(*)(id,SEL))objc_msgSend)(devSet, sel_registerName("devicesByUDID"));
        id device = [devs objectForKey:[[NSUUID alloc] initWithUUIDString:udid]];
        if (!device) { NSLog(@"ERROR: device not found"); return 1; }
        NSLog(@"Device: %@", ((id(*)(id,SEL))objc_msgSend)(device, sel_registerName("name")));

        /* Query device dimensions from SimDeviceType */
        @try {
            id deviceType = ((id(*)(id,SEL))objc_msgSend)(device, sel_registerName("deviceType"));
            if (deviceType) {
                CGSize screenSize = ((CGSize(*)(id,SEL))objc_msgSend)(deviceType, sel_registerName("mainScreenSize"));
                float scale = ((float(*)(id,SEL))objc_msgSend)(deviceType, sel_registerName("mainScreenScale"));
                if (screenSize.width > 0 && screenSize.height > 0) {
                    g_pixel_width  = (uint32_t)screenSize.width;
                    g_pixel_height = (uint32_t)screenSize.height;
                    g_scale        = scale > 0 ? scale : 2.0f;
                    NSLog(@"Display: %ux%u @%.0fx (from SimDeviceType)",
                          g_pixel_width, g_pixel_height, g_scale);
                }
            }
        } @catch (id e) {
            NSLog(@"WARNING: Could not query device dimensions: %@. Using defaults %ux%u",
                  e, g_pixel_width, g_pixel_height);
        }

        create_surface();
        if (!g_iosurface || !g_mem_entry) { NSLog(@"ERROR: no surface/mem_entry"); return 1; }

        mach_port_t port;
        mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &port);
        mach_port_insert_right(mach_task_self(), port, port, MACH_MSG_TYPE_MAKE_SEND);

        BOOL ok = ((BOOL(*)(id,SEL,mach_port_t,id,NSError**))objc_msgSend)(
            device, sel_registerName("registerPort:service:error:"),
            port, @"PurpleFBServer", &err);
        if (!ok) { NSLog(@"ERROR: registerPort: %@", err); return 1; }
        NSLog(@"PurpleFBServer registered (port=0x%x). Boot the sim now.", port);

        dispatch_source_t src = dispatch_source_create(DISPATCH_SOURCE_TYPE_MACH_RECV, port, 0,
            dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0));
        dispatch_source_set_event_handler(src, ^{ handle_msg(port); });
        dispatch_resume(src);

        CFRunLoopRun();
    }
    return 0;
}
