/*
 * RosettaSim Shared Framebuffer + Input Header
 *
 * Defines the memory layout for bidirectional IPC between the x86_64
 * simulated process and the ARM64 host app.
 *
 * Bridge (writer):  renders frames into pixel data, increments frame_counter
 * Host (writer):    writes touch events into the input region
 * Both poll their respective counters for changes.
 *
 * Memory layout:
 *   Offset 0:      Header (64 bytes) — frame metadata
 *   Offset 64:     Input region — touch event ring buffer + keyboard
 *   Offset 1088:   Pixel data (width * height * 4 bytes, BGRA format)
 *
 * VERSION 3: Touch events use a ring buffer (16 slots) to prevent
 * event loss when the host sends events faster than the bridge polls.
 * The host writes to events[write_index % RING_SIZE] and increments
 * write_index. The bridge reads all events between its read_index and
 * the current write_index.
 */

#ifndef ROSETTASIM_FRAMEBUFFER_H
#define ROSETTASIM_FRAMEBUFFER_H

#include <stdint.h>

#define ROSETTASIM_FB_MAGIC       0x4D495352  /* 'RSIM' little-endian */
#define ROSETTASIM_FB_VERSION     3
#define ROSETTASIM_FB_FORMAT_BGRA 0x42475241  /* 'BGRA' */
#define ROSETTASIM_FB_PATH          "/tmp/rosettasim_framebuffer"
#define ROSETTASIM_FB_GPU_PATH      "/tmp/rosettasim_framebuffer_gpu"
#define ROSETTASIM_FB_CONTEXT_PATH  "/tmp/rosettasim_context_id"
#define ROSETTASIM_FB_HEADER_SIZE   64

/* Flags */
#define ROSETTASIM_FB_FLAG_FRAME_READY  0x01
#define ROSETTASIM_FB_FLAG_APP_RUNNING  0x02
#define ROSETTASIM_FB_FLAG_RENDERING    0x04  /* Bridge is writing pixels — host should skip read */

/* Touch phase (matches UITouchPhase) */
#define ROSETTASIM_TOUCH_NONE      0
#define ROSETTASIM_TOUCH_BEGAN     1
#define ROSETTASIM_TOUCH_MOVED     2
#define ROSETTASIM_TOUCH_ENDED     3
#define ROSETTASIM_TOUCH_CANCELLED 4

typedef struct __attribute__((packed)) {
    uint32_t magic;           /* Must be ROSETTASIM_FB_MAGIC */
    uint32_t version;         /* Must be ROSETTASIM_FB_VERSION */
    uint32_t width;           /* Pixel width (e.g. 750) */
    uint32_t height;          /* Pixel height (e.g. 1334) */
    uint32_t stride;          /* Bytes per row (width * 4) */
    uint32_t format;          /* ROSETTASIM_FB_FORMAT_BGRA */
    uint64_t frame_counter;   /* Incremented each rendered frame */
    uint64_t timestamp_ns;    /* mach_absolute_time() of last render */
    uint32_t flags;           /* ROSETTASIM_FB_FLAG_* */
    uint32_t fps_target;      /* Target FPS (e.g. 30) */
    uint32_t _reserved[4];    /* Pad header to 64 bytes */
} RosettaSimFramebufferHeader;

/* Single touch event entry in the ring buffer */
typedef struct __attribute__((packed)) {
    uint32_t touch_phase;     /* ROSETTASIM_TOUCH_* */
    float    touch_x;         /* X coordinate in points (0..375) */
    float    touch_y;         /* Y coordinate in points (0..667) */
    uint32_t touch_id;        /* Finger ID for multi-touch (0 = primary) */
    uint64_t touch_timestamp; /* mach_absolute_time() of the touch */
    uint32_t _pad[2];         /* Pad to 32 bytes */
} RosettaSimTouchEvent;

/* Touch event ring buffer — prevents event loss when host sends faster
 * than bridge polls. Host writes to events[write_index % RING_SIZE],
 * then increments write_index. Bridge reads all events between its
 * read_index and write_index. */
#define ROSETTASIM_TOUCH_RING_SIZE 16

/* Input region — host writes, bridge reads.
 * Contains the touch ring buffer + keyboard event fields. */
typedef struct __attribute__((packed)) {
    /* Touch ring buffer */
    uint64_t touch_write_index;   /* Incremented by host after writing each event */
    RosettaSimTouchEvent touch_ring[ROSETTASIM_TOUCH_RING_SIZE]; /* 16 * 32 = 512 bytes */

    /* Keyboard events (single-buffered — keys are slow enough) */
    uint32_t key_code;        /* Key code (0 = none) */
    uint32_t key_flags;       /* Modifier flags */
    uint32_t key_char;        /* UTF-8 character (first byte, 0 = none) */
    uint32_t _reserved[5];    /* Pad to 1024 bytes total for input region */
} RosettaSimInputRegion;

#define ROSETTASIM_FB_INPUT_SIZE  sizeof(RosettaSimInputRegion)
#define ROSETTASIM_FB_META_SIZE   (ROSETTASIM_FB_HEADER_SIZE + ROSETTASIM_FB_INPUT_SIZE)

/* Total mmap size: header + input + pixel data */
#define ROSETTASIM_FB_PIXEL_SIZE(w, h)  ((w) * (h) * 4)
#define ROSETTASIM_FB_TOTAL_SIZE(w, h)  (ROSETTASIM_FB_META_SIZE + ROSETTASIM_FB_PIXEL_SIZE(w, h))

#endif /* ROSETTASIM_FRAMEBUFFER_H */
