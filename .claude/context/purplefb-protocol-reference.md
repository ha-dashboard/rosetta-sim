# PurpleFBServer Protocol Reference

## Source: Agent A RE (Sessions 25-27), iOS 9.3 QuartzCore

Binary: `~/Library/Developer/CoreSimulator/Profiles/Runtimes/iOS_9.3.simruntime/Contents/Resources/RuntimeRoot/System/Library/Frameworks/QuartzCore.framework/QuartzCore`

---

## Service Registration

- **Service name**: `PurpleFBServer` (or `PurpleFBTVOutServer` for external display)
- **Registration**: via `bootstrap_look_up()` from backboardd's bootstrap port
- **Env var**: `IOS_FRAMEBUFFER_PREFIX` — if set, prepends to service name (e.g. `MyPrefix_PurpleFBServer`)
- **Client**: `PurpleDisplay::open()` at QC9+0xf189e
- **Protocol**: raw Mach messages (not MIG, not XPC)

---

## Message IDs

### msg_id=4 — map_surface (Request)

**Direction**: backboardd → bridge (sent once at startup)
**Size**: 72 bytes
**Purpose**: Request shared framebuffer mapping

```c
struct PurpleFBMapSurfaceRequest {
    mach_msg_header_t  hdr;          // +0x00 (24 bytes)
    // msgh_bits: MACH_MSGH_BITS(COPY_SEND, MAKE_SEND_ONCE)
    // msgh_id: 4
    // msgh_local_port: reply port (SEND_ONCE)
    uint8_t            payload[48];  // +0x18 (mostly zeros)
};
```

### msg_id=4 — map_surface (Reply)

**Direction**: bridge → backboardd
**Size**: 0x48 bytes (72 bytes)
**Flags**: COMPLEX (contains port descriptor)

```c
struct PurpleFBMapSurfaceReply {
    mach_msg_header_t           hdr;        // +0x00 (24 bytes)
    // msgh_bits: MACH_MSGH_BITS_COMPLEX | MACH_MSGH_BITS(MOVE_SEND_ONCE, 0)
    // msgh_size: sizeof(struct) = 0x48
    // msgh_remote_port: request's reply port
    // msgh_id: 4 (same as request)

    mach_msg_body_t             body;       // +0x18
    // msgh_descriptor_count: 1

    mach_msg_port_descriptor_t  port;       // +0x1c (12 bytes)
    // name: memory_entry port (from mach_make_memory_entry_64)
    // disposition: MACH_MSG_TYPE_COPY_SEND
    // type: MACH_MSG_PORT_DESCRIPTOR

    uint32_t                    size;       // +0x28: total buffer bytes
                                            //   e.g. 4002000 = 1334 * 3000
    uint32_t                    stride;     // +0x2c: bytes per row
                                            //   e.g. 3000 = 750 * 4
    uint32_t                    pad[2];     // +0x30: padding/unknown (zero)

    uint32_t                    width;      // +0x38: PIXEL width (e.g. 750)
    uint32_t                    height;     // +0x3c: PIXEL height (e.g. 1334)
    uint32_t                    pt_width;   // +0x40: POINT width (e.g. 375 for @2x)
    uint32_t                    pt_height;  // +0x44: POINT height (e.g. 667 for @2x)
};
```

**How backboardd uses the reply** (PurpleDisplay::map_surface at QC9+0xf1a4a):

1. `vm_map(task, &addr, size, 0, VM_FLAGS_ANYWHERE, memory_entry, 0, FALSE, VM_PROT_READ|VM_PROT_WRITE, VM_PROT_READ|VM_PROT_WRITE, VM_INHERIT_NONE)` — maps shared memory
2. `MemorySurface(display, width, height, 'BGRA', addr, stride, unmap_callback, NULL)` — creates surface at pixel dimensions
3. Sets `display+0x108 = {0, 0, width, height}` — render bounds (pixel-space)
4. `Shape::new_shape({0, 0, width, height})` → `display+0x118` — clipping shape
5. `Transform::scale(width/pt_width, height/pt_height, 1.0)` → `display+0x138` — render transform
6. `Display::digital_mode_id(width, height)` or `set_dynamic_mode_size(width, height)` — display mode
7. `Display::set_size({pt_width, pt_height}, {pt_width, pt_height})` — point layout dimensions
8. `set_size` → `update_geometry()` → `update_actual_bounds()` — recalculates clip rect

**Dimension semantics**:
- `width`/`height`: Buffer pixel dimensions. MemorySurface is this size.
- `pt_width`/`pt_height`: UIKit layout dimensions in points.
- Scale factor: `width / pt_width` (e.g. 750/375 = 2.0 for @2x)
- The render transform maps point coordinates to pixel coordinates in the compositor.

### msg_id=3 — flush_shmem (Notification)

**Direction**: backboardd → bridge (sent on each rendered frame)
**Size**: 72 bytes
**Purpose**: Notify that framebuffer content has been updated

```c
struct PurpleFBFlush {
    mach_msg_header_t  hdr;          // +0x00 (24 bytes)
    // msgh_bits: 0x80001513
    //   MACH_MSGH_BITS(COPY_SEND, MAKE_SEND_ONCE)
    // msgh_id: 3
    // msgh_local_port: reply port (MUST reply!)

    uint8_t            ndr[8];       // +0x18: NDR record (zeros)

    // Dirty rect (the region that changed):
    int32_t            rect_x;       // +0x20
    int32_t            rect_y;       // +0x24
    int32_t            rect_w;       // +0x28
    int32_t            rect_h;       // +0x2c

    uint8_t            pad[16];      // +0x30: remaining (zeros)
};
```

### msg_id=3 — flush_shmem (Reply) — MANDATORY

**Direction**: bridge → backboardd
**Size**: 24 bytes (bare header)

```c
struct PurpleFBFlushReply {
    mach_msg_header_t  hdr;          // +0x00
    // msgh_bits: MACH_MSGH_BITS(MOVE_SEND_ONCE, 0)
    // msgh_size: 24
    // msgh_remote_port: flush request's reply port
    // msgh_id: any (backboardd ignores)
};
```

**CRITICAL**: `PurpleDisplay::finish_update` calls `flush_shmem` with `wait_for_reply=TRUE`. The `send_msg` function (QC9+0xf1e9e) does `mach_msg(MACH_SEND_MSG | MACH_RCV_MSG, timeout=0)` — **infinite wait**. If the bridge doesn't reply, backboardd blocks forever after the first render. The reply body content is ignored — just needs any message delivered to the reply port.

### msg_id=1011 — display state notification

**Direction**: backboardd → bridge
**Purpose**: Display state change notification
**Reply**: Not required (fire-and-forget)

---

## PurpleDisplay Struct Layout (iOS 9.3 QuartzCore)

Offset from PurpleDisplay* (total size: 0x1D0 bytes, alloc0-zeroed):

```
+0x00:  vtable*                    — CA::WindowServer::PurpleDisplay vtable
+0x08:  ... (base Display fields)
+0x34:  float    overscan_x        — overscan inset X
+0x38:  float    overscan_y        — overscan inset Y
+0x3c:  int32    size1_w           — set_size param 1 width (= pt_w)
+0x40:  int32    size1_h           — set_size param 1 height (= pt_h)
+0x44:  int32    size2_w           — set_size param 2 width (= pt_w)
+0x48:  int32    size2_h           — set_size param 2 height (= pt_h)
+0x50:  double   native_scale      — Display::set_scale() value
                                      Controls logical→actual bounds scaling
                                      If 0.0 (unset): update_geometry produces
                                      zero-size bounds → broken rendering
                                      Must be set to screen scale (1.0, 2.0, 3.0)
+0x58:  Bounds   physical_bounds   — {x, y, w, h} int32 × 4
                                      Derived from size1 in update_geometry
+0x68:  Bounds   logical_bounds    — {x, y, w, h} int32 × 4
                                      Derived from size2, scaled by native_scale
+0x78:  Bounds   mirrored_bounds   — {x, y, w, h} int32 × 4
                                      Set by set_logical_bounds()
+0x88:  Bounds   actual_bounds     — {x, y, w, h} int32 × 4
                                      THE ACTUAL CLIP RECT for rendering
                                      Set by update_actual_bounds() from
                                      logical_bounds (+0x68) or mirrored (+0x78)
+0x98:  Shape*   actual_shape      — CA::Shape from actual_bounds
                                      Used as renderer clip shape
+0xb8:  void*    sw_renderer       — CA::OGL::SWContext* (lazy-created)
+0xd8:  uint32   flags             — bit 0x1: display enabled
                                      bit 0x2: overscan enabled
+0xf0:  uint64   mode_flags        — display mode/mirroring config
+0x108: Bounds   render_bounds     — {x, y, w, h} int32 × 4
                                      Set by map_surface to {0,0,pixel_w,pixel_h}
                                      BUT: overridden by update_actual_bounds!
                                      After set_size runs, +0x88 controls clipping
+0x118: Shape*   render_shape      — Shape from render_bounds
                                      Also overridden by +0x98 after set_size
+0x124: uint32   fb_port           — PurpleFBServer Mach port
+0x128: Surface* surface           — CA::WindowServer::MemorySurface*
+0x130: bool     is_external       — true for TVOut display
+0x138: Transform render_transform — CA::Transform (64 bytes)
                                      scale(pixel_w/pt_w, pixel_h/pt_h, 1.0)
                                      Maps point-space → pixel-space
```

### Key methods and offsets

| Method | QC9 Offset | Purpose |
|--------|-----------|---------|
| PurpleDisplay::open | +0xf189e | bootstrap_look_up + constructor + map_surface |
| PurpleDisplay::map_surface | +0xf1a4a | Sends msg_id=4, creates MemorySurface, sets transform |
| PurpleDisplay::flush_shmem | +0xf20a2 | Sends msg_id=3 with dirty rect, waits for reply |
| PurpleDisplay::finish_update | +0xf2124 | Called after render, calls flush_shmem(wait=TRUE) |
| PurpleDisplay::send_msg | +0xf1e9e | Raw mach_msg send+receive with timeout |
| PurpleDisplay::new_server | +0xf1d96 | Creates CA::WindowServer::Server |
| PurpleDisplay::can_update | +0xf224c | Checks if display is ready for rendering |
| Display::set_size | +0xe1e6e | Stores two Vec2<int> at +0x3c and +0x44, calls update_geometry |
| Display::set_scale | +0xe20b8 | Stores double at +0x50, calls update_geometry |
| Display::update_geometry | +0xe1ea6 | Builds bounds from size + native_scale, calls update_actual_bounds |
| Display::update_actual_bounds | +0xe2206 | Copies logical→actual bounds, creates clip shape |
| Display::set_logical_bounds | +0xe20d0 | Sets mirrored bounds at +0x78 |
| Display::render_display | +0xe2818 | Main render entry, uses +0x88 as clip rect |
| Display::render_surface | +0xe2a06 | Renders to surface with Update |
| TimerDisplayLink::update_timer | +0x142dc0 | CFRunLoopTimer-based 60fps trigger |

---

## The Scale Problem (Session 27)

### Current state (pt_width = pixel_width, scale=1.0)
- UIKit lays out at pixel dimensions (750×1334 points for iPhone)
- Icons render at 1x density (too small on iPads)
- No wallpaper on iPads (layout at pixel dimensions is wrong)
- Rendering fills full buffer (because transform is identity)

### With pt_width = pixel_width/scale (correct @2x)
- UIKit lays out at point dimensions (375×667 for iPhone)
- BUT: native_scale at +0x50 is 0.0 (never set by anyone)
- update_geometry scales logical bounds by 0.0 → {0,0,0,0}
- Clip rect = empty → 0% buffer fill

### The fix needed (Session 28)
`BSMainScreenScale()` in backboardd returns ≤0 → fallback to scale=1.0. But this scale is stored to a global, NOT passed to `Display::set_scale()`. The path from BSMainScreenScale → set_scale goes through window server initialization, and somehow the scale doesn't reach the Display.

**Approach**: Interpose BSMainScreenScale via `insert_dylib` on backboardd binary (launchd_sim blocks DYLD_* env vars, so SIMCTL_CHILD_DYLD_INSERT doesn't work). Use a custom env var in backboardd's launchd plist for per-device scale.

**Note**: Simply patching the 1.0f fallback constant at backboardd file offset 0xbb460 to 2.0f BROKE display init entirely (zero flushes). The mismatch between BSMainScreenScale returning 0 and the fallback being 2.0 caused further issues in the init path. The interpose approach (returning a consistent 2.0 from BSMainScreenScale itself) should work because all downstream code sees a consistent scale value.

---

## MemorySurface Layout

Created by map_surface at QC9+0xf1b64:
```c
MemorySurface(display, pixel_w, pixel_h, format, vm_addr, stride, unmap_cb, ctx)
```

- Pixel format: `0x42475241` = 'BGRA' (little-endian: bytes are B, G, R, A)
- Buffer: `vm_map`'d from memory_entry port
- Stride: bytes per row (pixel_w * 4, may be padded)
- The buffer pointer ends up at SWContext+0x668 (confirmed in Session 24)

---

## Pixel Format

- **BGRA**: 4 bytes per pixel, blue-green-red-alpha order
- Alpha channel: always 255 (opaque) after clear
- Host-side conversion: `ffmpeg -f rawvideo -pix_fmt bgra -s WxH` or PIL `Image.frombytes("RGBA", (W,H), data, "raw", "BGRA")`
