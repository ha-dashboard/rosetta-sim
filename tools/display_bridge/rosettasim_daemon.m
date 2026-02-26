/*
 * rosettasim_daemon.m — PurpleFBServer daemon for ALL legacy iOS simulators
 *
 * Monitors CoreSimulator device state changes. When a legacy device (iOS 9.x/10.x)
 * boots, automatically registers PurpleFBServer with the correct dimensions.
 * Handles multiple devices simultaneously.
 *
 * Usage:
 *   rosettasim_daemon              # run in foreground
 *   rosettasim_daemon --list       # list legacy devices and exit
 *
 * Handles SIGTERM/SIGINT gracefully (cleans up ports, files, IOSurfaces).
 * Logs a warning if any active device hasn't flushed in 60s.
 *
 * To run under launchd, create ~/Library/LaunchAgents/com.rosetta.daemon.plist:
 *   <plist version="1.0"><dict>
 *     <key>Label</key><string>com.rosetta.daemon</string>
 *     <key>ProgramArguments</key><array>
 *       <string>/path/to/rosettasim_daemon</string>
 *     </array>
 *     <key>RunAtLoad</key><true/>
 *     <key>KeepAlive</key><true/>
 *     <key>StandardOutPath</key><string>/tmp/rosettasim_daemon.log</string>
 *     <key>StandardErrorPath</key><string>/tmp/rosettasim_daemon.log</string>
 *   </dict></plist>
 *   Then: launchctl load ~/Library/LaunchAgents/com.rosetta.daemon.plist
 */

#import <Foundation/Foundation.h>
#import <mach/mach.h>
#import <mach/vm_map.h>
#import <dispatch/dispatch.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <IOSurface/IOSurface.h>
#import <CoreGraphics/CoreGraphics.h>
#import <dlfcn.h>

#define PFB_PAGE_SIZE 4096

extern kern_return_t mach_make_memory_entry_64(
    vm_map_t, memory_object_size_t *, memory_object_offset_t,
    vm_prot_t, mach_port_t *, mem_entry_name_port_t);

/* PurpleFB reply — 72 bytes */
#pragma pack(4)
typedef struct {
    mach_msg_header_t          header;
    mach_msg_body_t            body;
    mach_msg_port_descriptor_t port_desc;
    uint32_t                   mem_size;
    uint32_t                   stride;
    uint32_t                   pad1;
    uint32_t                   pad2;
    uint32_t                   width;
    uint32_t                   height;
    uint32_t                   pt_width;
    uint32_t                   pt_height;
} PFBReply;
#pragma pack()

/* ================================================================
 * Per-device state
 * ================================================================ */

typedef struct DeviceContext {
    char            udid[64];
    char            name[128];
    uint32_t        pixel_width;
    uint32_t        pixel_height;
    float           scale;
    uint32_t        bytes_per_row;
    uint32_t        surface_size;
    uint32_t        surface_alloc;
    IOSurfaceRef    iosurface;
    uint32_t        surface_id;
    void           *surface_base;
    mach_port_t     mem_entry;
    mach_port_t     service_port;
    dispatch_source_t recv_source;
    int             flush_count;
    int             active;
    time_t          last_flush_time;
} DeviceContext;

#define MAX_DEVICES 64
static DeviceContext g_devices[MAX_DEVICES];
static int g_device_count = 0;
static dispatch_queue_t g_msg_queue;

/* ================================================================
 * Device context management
 * ================================================================ */

static DeviceContext *find_context(const char *udid) {
    for (int i = 0; i < g_device_count; i++) {
        if (strcmp(g_devices[i].udid, udid) == 0)
            return &g_devices[i];
    }
    return NULL;
}

static DeviceContext *alloc_context(const char *udid, const char *name) {
    DeviceContext *ctx = find_context(udid);
    if (ctx) return ctx;
    if (g_device_count >= MAX_DEVICES) {
        NSLog(@"[daemon] MAX_DEVICES reached");
        return NULL;
    }
    ctx = &g_devices[g_device_count++];
    memset((void *)ctx, 0, sizeof(*ctx));
    strlcpy(ctx->udid, udid, sizeof(ctx->udid));
    strlcpy(ctx->name, name, sizeof(ctx->name));
    ctx->mem_entry = MACH_PORT_NULL;
    ctx->service_port = MACH_PORT_NULL;
    return ctx;
}

/* ================================================================
 * File I/O helpers
 * ================================================================ */

static void write_framebuffer(DeviceContext *ctx) {
    if (!ctx->surface_base) return;
    char path[256], tmp_path[256];
    snprintf(path, sizeof(path), "/tmp/rosettasim_fb_%s.raw", ctx->udid);
    snprintf(tmp_path, sizeof(tmp_path), "/tmp/rosettasim_fb_%s.raw.tmp", ctx->udid);
    FILE *f = fopen(tmp_path, "wb");
    if (f) {
        fwrite(ctx->surface_base, 1, ctx->surface_size, f);
        fclose(f);
        rename(tmp_path, path);
    }
}

static void write_device_metadata(DeviceContext *ctx) {
    char path[256];
    snprintf(path, sizeof(path), "/tmp/rosettasim_dims_%s.json", ctx->udid);
    FILE *f = fopen(path, "w");
    if (f) {
        fprintf(f, "{\"width\":%u,\"height\":%u,\"scale\":%.1f,\"bpr\":%u,\"name\":\"%s\"}\n",
                ctx->pixel_width, ctx->pixel_height, ctx->scale,
                ctx->bytes_per_row, ctx->name);
        fclose(f);
    }

    /* Also write to the shared metadata path for backward compat */
    f = fopen("/tmp/rosettasim_dimensions.json", "w");
    if (f) {
        fprintf(f, "{\"width\":%u,\"height\":%u,\"scale\":%.1f,\"bpr\":%u}\n",
                ctx->pixel_width, ctx->pixel_height, ctx->scale, ctx->bytes_per_row);
        fclose(f);
    }
}

static void write_active_devices(void) {
    FILE *f = fopen("/tmp/rosettasim_active_devices.json", "w");
    if (!f) return;
    /* Bare JSON array — injection dylib expects NSArray at top level */
    fprintf(f, "[\n");
    int first = 1;
    for (int i = 0; i < g_device_count; i++) {
        if (!g_devices[i].active) continue;
        if (!first) fprintf(f, ",\n");
        fprintf(f, "  {\"udid\":\"%s\",\"name\":\"%s\",\"width\":%u,\"height\":%u,\"scale\":%.1f,"
                "\"surface_id\":%u,"
                "\"fb\":\"/tmp/rosettasim_fb_%s.raw\","
                "\"dims\":\"/tmp/rosettasim_dims_%s.json\"}",
                g_devices[i].udid, g_devices[i].name,
                g_devices[i].pixel_width, g_devices[i].pixel_height,
                g_devices[i].scale,
                g_devices[i].surface_id,
                g_devices[i].udid, g_devices[i].udid);
        first = 0;
    }
    fprintf(f, "\n]\n");
    fclose(f);
}

static void cleanup_device_files(DeviceContext *ctx) {
    char path[256];
    snprintf(path, sizeof(path), "/tmp/rosettasim_fb_%s.raw", ctx->udid);
    unlink(path);
    snprintf(path, sizeof(path), "/tmp/rosettasim_fb_%s.raw.tmp", ctx->udid);
    unlink(path);
    snprintf(path, sizeof(path), "/tmp/rosettasim_dims_%s.json", ctx->udid);
    unlink(path);
}

/* ================================================================
 * PurpleFB message handler (per-device)
 * ================================================================ */

static void handle_one_msg(DeviceContext *ctx, mach_msg_header_t *msg);

static void handle_msg_for_device(DeviceContext *ctx) {
    /* Drain ALL pending messages — dispatch_source coalesces events */
    uint8_t buf[4096];
    mach_msg_header_t *msg = (mach_msg_header_t *)buf;
    for (;;) {
        kern_return_t kr = mach_msg(msg, MACH_RCV_MSG | MACH_RCV_TIMEOUT,
                                     0, sizeof(buf), ctx->service_port, 0, MACH_PORT_NULL);
        if (kr) break;  /* no more messages */
        handle_one_msg(ctx, msg);
    }
}

static void handle_one_msg(DeviceContext *ctx, mach_msg_header_t *msg) {

    if (msg->msgh_id == 4 && msg->msgh_remote_port) {
        /* map_surface — reply with framebuffer info */
        PFBReply r;
        memset(&r, 0, sizeof(r));
        r.header.msgh_bits = MACH_MSGH_BITS_COMPLEX |
                             MACH_MSGH_BITS(MACH_MSG_TYPE_MOVE_SEND_ONCE, 0);
        r.header.msgh_size = sizeof(r);
        r.header.msgh_remote_port = msg->msgh_remote_port;
        r.header.msgh_id = msg->msgh_id + 100;
        r.body.msgh_descriptor_count = 1;
        r.port_desc.name = ctx->mem_entry;
        r.port_desc.disposition = MACH_MSG_TYPE_COPY_SEND;
        r.port_desc.type = MACH_MSG_PORT_DESCRIPTOR;
        r.mem_size = ctx->surface_alloc;
        r.stride = ctx->bytes_per_row;
        r.width = ctx->pixel_width;
        r.height = ctx->pixel_height;
        /* pt_width = pixel_width for now (scale=1).
         * Finding 33/34: BSMainScreenScale interpose + set_scale needed for 2x.
         * Simple constant patch breaks display init. Need insert_dylib approach. */
        r.pt_width = ctx->pixel_width;
        r.pt_height = ctx->pixel_height;

        kern_return_t skr = mach_msg(&r.header, MACH_SEND_MSG, sizeof(r),
                      0, MACH_PORT_NULL, MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL);
        NSLog(@"[daemon] %s: map_surface reply kr=%d (%ux%u stride=%u)",
              ctx->name, skr, ctx->pixel_width, ctx->pixel_height, ctx->bytes_per_row);

    } else if (msg->msgh_id == 3) {
        /* flush_shmem — reply and dump pixels */
        ctx->flush_count++;
        ctx->last_flush_time = time(NULL);
        if (msg->msgh_remote_port) {
            mach_msg_header_t reply;
            memset(&reply, 0, sizeof(reply));
            reply.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_MOVE_SEND_ONCE, 0);
            reply.msgh_size = sizeof(reply);
            reply.msgh_remote_port = msg->msgh_remote_port;
            reply.msgh_id = msg->msgh_id;
            mach_msg(&reply, MACH_SEND_MSG, sizeof(reply),
                     0, MACH_PORT_NULL, MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL);
        }
        write_framebuffer(ctx);

        /* Also write to legacy shared path for backward compat */
        if (ctx->surface_base) {
            FILE *f = fopen("/tmp/sim_framebuffer.raw.tmp", "wb");
            if (f) {
                fwrite(ctx->surface_base, 1, ctx->surface_size, f);
                fclose(f);
                rename("/tmp/sim_framebuffer.raw.tmp", "/tmp/sim_framebuffer.raw");
            }
        }

        /* Periodic pixel stats: every flush <=10, every 10th <=50, every 200th after */
        if (ctx->surface_base && (ctx->flush_count <= 10 || (ctx->flush_count <= 50 && ctx->flush_count % 10 == 0) || ctx->flush_count % 200 == 0)) {
            uint32_t *px = (uint32_t *)ctx->surface_base;
            int nz = 0;
            for (uint32_t i = 0; i < ctx->pixel_width * ctx->pixel_height; i++) {
                uint8_t r = (px[i] >> 16) & 0xFF;
                uint8_t g = (px[i] >> 8) & 0xFF;
                uint8_t b = px[i] & 0xFF;
                if (r || g || b) nz++;
            }
            NSLog(@"[daemon] %s: flush #%d: %d/%d non-zero RGB (%.0f%%)",
                  ctx->name, ctx->flush_count, nz, ctx->pixel_width * ctx->pixel_height,
                  100.0 * nz / (ctx->pixel_width * ctx->pixel_height));
        } else if (ctx->flush_count % 500 == 0) {
            NSLog(@"[daemon] %s: flush #%d", ctx->name, ctx->flush_count);
        }

    } else if (msg->msgh_id == 1011) {
        /* Display state change */
        NSLog(@"[daemon] %s: msg_id=1011 (display state)", ctx->name);
        if (msg->msgh_remote_port) {
            mach_msg_header_t reply;
            memset(&reply, 0, sizeof(reply));
            reply.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_MOVE_SEND_ONCE, 0);
            reply.msgh_size = sizeof(reply);
            reply.msgh_remote_port = msg->msgh_remote_port;
            reply.msgh_id = msg->msgh_id;
            mach_msg(&reply, MACH_SEND_MSG, sizeof(reply),
                     0, MACH_PORT_NULL, MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL);
        }
    } else {
        /* Reply to any unknown message */
        if (msg->msgh_remote_port) {
            mach_msg_header_t reply;
            memset(&reply, 0, sizeof(reply));
            reply.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_MOVE_SEND_ONCE, 0);
            reply.msgh_size = sizeof(reply);
            reply.msgh_remote_port = msg->msgh_remote_port;
            reply.msgh_id = msg->msgh_id;
            mach_msg(&reply, MACH_SEND_MSG, sizeof(reply),
                     0, MACH_PORT_NULL, MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL);
        }
    }
}

/* ================================================================
 * Device activation / deactivation
 * ================================================================ */

static void activate_device(DeviceContext *ctx, id device) {
    if (ctx->active) return;
    NSLog(@"[daemon] Activating %s (%s)", ctx->name, ctx->udid);

    /* Query dimensions from SimDeviceType */
    @try {
        id deviceType = ((id(*)(id, SEL))objc_msgSend)(device, sel_registerName("deviceType"));
        if (deviceType) {
            CGSize sz = ((CGSize(*)(id, SEL))objc_msgSend)(deviceType,
                          sel_registerName("mainScreenSize"));
            float scale = ((float(*)(id, SEL))objc_msgSend)(deviceType,
                            sel_registerName("mainScreenScale"));
            if (sz.width > 0 && sz.height > 0) {
                ctx->pixel_width = (uint32_t)sz.width;
                ctx->pixel_height = (uint32_t)sz.height;
                ctx->scale = scale > 0 ? scale : 2.0f;
            }
        }
    } @catch (id e) {
        NSLog(@"[daemon] WARNING: Could not query dimensions for %s: %@", ctx->name, e);
    }

    if (ctx->pixel_width == 0) { ctx->pixel_width = 750; ctx->pixel_height = 1334; ctx->scale = 2.0f; }
    ctx->bytes_per_row = ctx->pixel_width * 4;
    ctx->surface_size = ctx->bytes_per_row * ctx->pixel_height;
    ctx->surface_alloc = ((ctx->surface_size + PFB_PAGE_SIZE - 1) / PFB_PAGE_SIZE) * PFB_PAGE_SIZE;

    NSLog(@"[daemon] %s: %ux%u @%.0fx", ctx->name, ctx->pixel_width, ctx->pixel_height, ctx->scale);

    /* Create IOSurface */
    NSDictionary *props = @{
        (id)kIOSurfaceWidth:           @(ctx->pixel_width),
        (id)kIOSurfaceHeight:          @(ctx->pixel_height),
        (id)kIOSurfaceBytesPerElement: @4,
        (id)kIOSurfaceBytesPerRow:     @(ctx->bytes_per_row),
        (id)kIOSurfacePixelFormat:     @(0x42475241),
        (id)kIOSurfaceAllocSize:       @(ctx->surface_alloc),
        (id)kIOSurfaceIsGlobal:        @YES,
    };
    ctx->iosurface = IOSurfaceCreate((__bridge CFDictionaryRef)props);
    if (!ctx->iosurface) {
        NSLog(@"[daemon] ERROR: IOSurfaceCreate failed for %s", ctx->name);
        return;
    }
    ctx->surface_base = IOSurfaceGetBaseAddress(ctx->iosurface);

    /* Fill with opaque black */
    IOSurfaceLock(ctx->iosurface, 0, NULL);
    uint8_t *px = (uint8_t *)ctx->surface_base;
    memset(px, 0, ctx->surface_size);
    for (uint32_t i = 0; i < ctx->pixel_width * ctx->pixel_height; i++) px[i * 4 + 3] = 0xFF;
    IOSurfaceUnlock(ctx->iosurface, 0, NULL);

    /* Create memory entry */
    memory_object_size_t sz = ctx->surface_alloc;
    kern_return_t kr = mach_make_memory_entry_64(mach_task_self(), &sz,
        (memory_object_offset_t)(uintptr_t)ctx->surface_base,
        VM_PROT_READ | VM_PROT_WRITE, &ctx->mem_entry, MACH_PORT_NULL);
    if (kr != KERN_SUCCESS) {
        NSLog(@"[daemon] ERROR: memory_entry failed for %s: %s", ctx->name, mach_error_string(kr));
        CFRelease(ctx->iosurface);
        ctx->iosurface = NULL;
        return;
    }

    /* Create and register Mach port */
    mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &ctx->service_port);
    mach_port_insert_right(mach_task_self(), ctx->service_port, ctx->service_port,
                           MACH_MSG_TYPE_MAKE_SEND);

    NSError *err = nil;
    BOOL ok = ((BOOL(*)(id, SEL, mach_port_t, id, NSError **))objc_msgSend)(
        device, sel_registerName("registerPort:service:error:"),
        ctx->service_port, @"PurpleFBServer", &err);
    if (!ok) {
        NSLog(@"[daemon] ERROR: registerPort failed for %s: %@", ctx->name, err);
        mach_port_deallocate(mach_task_self(), ctx->service_port);
        mach_port_deallocate(mach_task_self(), ctx->mem_entry);
        CFRelease(ctx->iosurface);
        ctx->service_port = MACH_PORT_NULL;
        ctx->mem_entry = MACH_PORT_NULL;
        ctx->iosurface = NULL;
        return;
    }

    /* Start mach_recv dispatch source */
    ctx->recv_source = dispatch_source_create(DISPATCH_SOURCE_TYPE_MACH_RECV,
                                               ctx->service_port, 0, g_msg_queue);
    DeviceContext *captured_ctx = ctx;
    dispatch_source_set_event_handler(ctx->recv_source, ^{
        handle_msg_for_device(captured_ctx);
    });
    dispatch_activate(ctx->recv_source);

    /* Write metadata */
    ctx->surface_id = IOSurfaceGetID(ctx->iosurface);
    FILE *idf = fopen("/tmp/rosettasim_surface_id", "w");
    if (idf) { fprintf(idf, "%u\n", ctx->surface_id); fclose(idf); }

    write_device_metadata(ctx);
    ctx->active = 1;
    ctx->flush_count = 0;
    write_active_devices();

    NSLog(@"[daemon] %s: PurpleFBServer registered (port=0x%x, surface=%ux%u id=%u)",
          ctx->name, ctx->service_port, ctx->pixel_width, ctx->pixel_height, ctx->surface_id);
}

static void deactivate_device(DeviceContext *ctx) {
    if (!ctx->active) return;
    NSLog(@"[daemon] Deactivating %s (%s)", ctx->name, ctx->udid);

    if (ctx->recv_source) {
        dispatch_source_cancel(ctx->recv_source);
        ctx->recv_source = nil;
    }
    if (ctx->iosurface) {
        CFRelease(ctx->iosurface);
        ctx->iosurface = NULL;
    }
    if (ctx->mem_entry != MACH_PORT_NULL) {
        mach_port_deallocate(mach_task_self(), ctx->mem_entry);
        ctx->mem_entry = MACH_PORT_NULL;
    }
    if (ctx->service_port != MACH_PORT_NULL) {
        mach_port_deallocate(mach_task_self(), ctx->service_port);
        ctx->service_port = MACH_PORT_NULL;
    }
    ctx->surface_base = NULL;
    ctx->active = 0;

    cleanup_device_files(ctx);
    write_active_devices();
}

/* ================================================================
 * Legacy runtime detection
 * ================================================================ */

static BOOL is_legacy_runtime(id device) {
    @try {
        NSString *rtId = ((id(*)(id, SEL))objc_msgSend)(device,
                           sel_registerName("runtimeIdentifier"));
        if (!rtId) return NO;
        /* iOS 12.4 has mismatched runtime ID "iOS-15-4" due to .simruntime bundle */
        if (![rtId containsString:@"iOS-9"] && ![rtId containsString:@"iOS-10"]
            && ![rtId containsString:@"iOS-15-4"]) return NO;
        /* Verify device has a valid device type profile */
        id deviceType = ((id(*)(id, SEL))objc_msgSend)(device, sel_registerName("deviceType"));
        if (!deviceType) return NO;
        return YES;
    } @catch (id e) {
        return NO;
    }
}

/* ================================================================
 * Main
 * ================================================================ */

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        BOOL listOnly = (argc > 1 && strcmp(argv[1], "--list") == 0);

        /* Load CoreSimulator */
        dlopen("/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator", RTLD_NOW);

        Class SimServiceContext = objc_getClass("SimServiceContext");
        if (!SimServiceContext) {
            NSLog(@"[daemon] ERROR: CoreSimulator not loaded");
            return 1;
        }

        NSError *err = nil;
        id ctx = ((id(*)(id, SEL, id, NSError **))objc_msgSend)(
            (id)SimServiceContext, sel_registerName("sharedServiceContextForDeveloperDir:error:"),
            @"/Applications/Xcode.app/Contents/Developer", &err);
        if (!ctx) {
            NSLog(@"[daemon] ERROR: SimServiceContext: %@", err);
            return 1;
        }

        id devSet = ((id(*)(id, SEL, NSError **))objc_msgSend)(
            ctx, sel_registerName("defaultDeviceSetWithError:"), &err);
        if (!devSet) {
            NSLog(@"[daemon] ERROR: defaultDeviceSet: %@", err);
            return 1;
        }

        NSDictionary *devsByUDID = ((id(*)(id, SEL))objc_msgSend)(
            devSet, sel_registerName("devicesByUDID"));

        /* Create message handling queue */
        g_msg_queue = dispatch_queue_create("com.rosetta.daemon.messages",
            dispatch_queue_attr_make_with_autorelease_frequency(
                DISPATCH_QUEUE_SERIAL, DISPATCH_AUTORELEASE_FREQUENCY_WORK_ITEM));

        /* Find all legacy devices */
        NSLog(@"[daemon] Scanning for legacy devices...");
        NSMutableArray *legacyDevices = [NSMutableArray array];

        for (NSUUID *udid in devsByUDID) {
            id device = devsByUDID[udid];
            if (!is_legacy_runtime(device)) continue;

            NSString *name = ((id(*)(id, SEL))objc_msgSend)(device, sel_registerName("name"));
            NSString *rtId = ((id(*)(id, SEL))objc_msgSend)(device, sel_registerName("runtimeIdentifier"));
            long state = ((long(*)(id, SEL))objc_msgSend)(device, sel_registerName("state"));

            NSLog(@"[daemon]   %@ (%@) runtime=%@ state=%ld",
                  name, [udid UUIDString], rtId, state);

            DeviceContext *dctx = alloc_context([[udid UUIDString] UTF8String],
                                                [name UTF8String]);
            if (!dctx) continue;

            [legacyDevices addObject:device];
        }

        NSLog(@"[daemon] Found %lu legacy device(s)", (unsigned long)legacyDevices.count);

        if (legacyDevices.count == 0) {
            NSLog(@"[daemon] No legacy devices found. Nothing to do.");
            return 0;
        }

        if (listOnly) return 0;

        /*
         * PRE-REGISTER PurpleFBServer for ALL shutdown legacy devices.
         *
         * This is critical: registerPort must succeed BEFORE simctl boot,
         * because backboardd calls bootstrap_look_up("PurpleFBServer") very
         * early in its startup. If we wait for the Booting notification,
         * it's already too late — launchd_sim has already spawned backboardd.
         *
         * For already-booted devices, we skip (can't register after boot).
         */
        NSLog(@"[daemon] Pre-registering PurpleFBServer for all shutdown devices...");
        for (id device in legacyDevices) {
            NSString *udidStr = [((id(*)(id, SEL))objc_msgSend)(device,
                                  sel_registerName("UDID")) UUIDString];
            DeviceContext *dctx = find_context([udidStr UTF8String]);
            if (!dctx) continue;

            long currentState = ((long(*)(id, SEL))objc_msgSend)(device, sel_registerName("state"));
            if (currentState != 1) {
                NSLog(@"[daemon] %s: state=%ld (not shutdown), skipping pre-register",
                      dctx->name, currentState);
                continue;
            }

            /* Pre-register: create surface + port + register, but don't mark active yet */
            activate_device(dctx, device);
            if (dctx->active) {
                NSLog(@"[daemon] %s: pre-registered PurpleFBServer (ready for boot)",
                      dctx->name);
            }
        }

        /* Register notification handlers for state tracking */
        for (id device in legacyDevices) {
            NSString *udidStr = [((id(*)(id, SEL))objc_msgSend)(device,
                                  sel_registerName("UDID")) UUIDString];
            DeviceContext *dctx = find_context([udidStr UTF8String]);
            if (!dctx) continue;

            __block id capturedDevice = device;
            __block DeviceContext *capturedCtx = dctx;

            ((id(*)(id, SEL, id, id))objc_msgSend)(
                device, sel_registerName("registerNotificationHandlerOnQueue:handler:"),
                dispatch_get_main_queue(),
                ^(NSDictionary *info) {
                    long newState = ((long(*)(id, SEL))objc_msgSend)(
                        capturedDevice, sel_registerName("state"));

                    /* Deduplicate: only log/act on actual state transitions */
                    static long lastState[MAX_DEVICES];
                    int idx = (int)(capturedCtx - g_devices);
                    if (idx >= 0 && idx < MAX_DEVICES && lastState[idx] == newState) return;
                    if (idx >= 0 && idx < MAX_DEVICES) lastState[idx] = newState;

                    NSLog(@"[daemon] %s: state → %ld", capturedCtx->name, newState);

                    if (newState == 1) {
                        /* Shutdown — deactivate and re-register for next boot */
                        if (capturedCtx->active) {
                            NSLog(@"[daemon] %s: SHUTDOWN — deactivating", capturedCtx->name);
                            deactivate_device(capturedCtx);
                        }
                        /* Re-register for the next boot cycle */
                        NSLog(@"[daemon] %s: re-registering for next boot", capturedCtx->name);
                        activate_device(capturedCtx, capturedDevice);
                    } else if (newState == 3 && capturedCtx->active) {
                        /* Booted — our pre-registered port is being used */
                        NSLog(@"[daemon] %s: BOOTED — bridge active", capturedCtx->name);
                        write_active_devices();
                    }
                });
        }

        NSLog(@"[daemon] Monitoring %lu legacy device(s). PurpleFBServer pre-registered.",
              (unsigned long)legacyDevices.count);

        write_active_devices();

        /* Signal handling: clean shutdown on SIGTERM/SIGINT */
        dispatch_source_t sig_term = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL,
                                                             SIGTERM, 0, dispatch_get_main_queue());
        dispatch_source_t sig_int = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL,
                                                            SIGINT, 0, dispatch_get_main_queue());
        void (^cleanup_and_exit)(void) = ^{
            NSLog(@"[daemon] Shutting down...");
            for (int i = 0; i < g_device_count; i++) {
                if (g_devices[i].active)
                    deactivate_device(&g_devices[i]);
            }
            unlink("/tmp/rosettasim_active_devices.json");
            unlink("/tmp/rosettasim_dimensions.json");
            unlink("/tmp/rosettasim_surface_id");
            unlink("/tmp/sim_framebuffer.raw");
            unlink("/tmp/sim_framebuffer.raw.tmp");
            NSLog(@"[daemon] Clean shutdown complete.");
            exit(0);
        };
        dispatch_source_set_event_handler(sig_term, cleanup_and_exit);
        dispatch_source_set_event_handler(sig_int, cleanup_and_exit);
        signal(SIGTERM, SIG_IGN); /* let dispatch handle it */
        signal(SIGINT, SIG_IGN);
        dispatch_activate(sig_term);
        dispatch_activate(sig_int);

        /* Watchdog: check for stale devices every 30s */
        dispatch_source_t watchdog = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,
                                                             0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(watchdog, dispatch_time(DISPATCH_TIME_NOW, 30*NSEC_PER_SEC),
                                  30*NSEC_PER_SEC, 5*NSEC_PER_SEC);
        dispatch_source_set_event_handler(watchdog, ^{
            time_t now = time(NULL);
            for (int i = 0; i < g_device_count; i++) {
                DeviceContext *d = &g_devices[i];
                if (!d->active) continue;
                if (d->last_flush_time > 0 && (now - d->last_flush_time) > 60) {
                    NSLog(@"[daemon] WARNING: %s has not flushed in %lds",
                          d->name, (long)(now - d->last_flush_time));
                }
            }
        });
        dispatch_activate(watchdog);

        /* Run forever */
        CFRunLoopRun();
    }
    return 0;
}
