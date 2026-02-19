/*
 * RosettaSim Shared Framebuffer Header
 *
 * Defines the memory layout for the shared framebuffer used to transfer
 * rendered frames from the x86_64 simulated process to the ARM64 host app.
 *
 * Both processes mmap the same file. The bridge (writer) renders frames
 * into the pixel data region and increments frame_counter. The host app
 * (reader) polls frame_counter and creates display images from the pixels.
 *
 * Memory layout:
 *   Offset 0:   Header (64 bytes)
 *   Offset 64:  Pixel data (width * height * 4 bytes, BGRA format)
 */

#ifndef ROSETTASIM_FRAMEBUFFER_H
#define ROSETTASIM_FRAMEBUFFER_H

#include <stdint.h>

#define ROSETTASIM_FB_MAGIC       0x4D495352  /* 'RSIM' little-endian */
#define ROSETTASIM_FB_VERSION     1
#define ROSETTASIM_FB_FORMAT_BGRA 0x42475241  /* 'BGRA' */
#define ROSETTASIM_FB_PATH        "/tmp/rosettasim_framebuffer"
#define ROSETTASIM_FB_HEADER_SIZE 64

/* Flags */
#define ROSETTASIM_FB_FLAG_FRAME_READY  0x01
#define ROSETTASIM_FB_FLAG_APP_RUNNING  0x02

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

/* Total mmap size: header + pixel data */
#define ROSETTASIM_FB_PIXEL_SIZE(w, h)  ((w) * (h) * 4)
#define ROSETTASIM_FB_TOTAL_SIZE(w, h)  (ROSETTASIM_FB_HEADER_SIZE + ROSETTASIM_FB_PIXEL_SIZE(w, h))

#endif /* ROSETTASIM_FRAMEBUFFER_H */
