// fb_to_png.m — Screenshot tool for legacy iOS simulators
//
// Reads framebuffer data from IOSurface (by ID) or raw file and saves as PNG.
// Used by scripts/simctl wrapper for transparent screenshot support.
//
// Usage:
//   fb_to_png <surface_id> <output.png>                           # IOSurface mode
//   fb_to_png --raw <raw_file> <width> <height> <bpr> <output.png> # raw file mode

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <IOSurface/IOSurface.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static int write_png(CGImageRef img, const char *path) {
    NSURL *url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:path]];
    CGImageDestinationRef dest = CGImageDestinationCreateWithURL(
        (__bridge CFURLRef)url, (__bridge CFStringRef)UTTypePNG.identifier, 1, NULL);
    if (!dest) { fprintf(stderr, "Can't create image destination\n"); return 1; }
    CGImageDestinationAddImage(dest, img, NULL);
    BOOL ok = CGImageDestinationFinalize(dest);
    CFRelease(dest);
    return ok ? 0 : 1;
}

int main(int argc, char *argv[]) {
    if (argc < 3) {
        fprintf(stderr, "Usage: %s <surface_id> <output.png>\n", argv[0]);
        fprintf(stderr, "   or: %s --raw <raw_file> <width> <height> <bpr> <output.png>\n", argv[0]);
        return 1;
    }
    @autoreleasepool {
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        uint32_t bitmapInfo = kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst;

        if (strcmp(argv[1], "--raw") == 0 && argc >= 7) {
            // Raw file mode
            NSData *data = [NSData dataWithContentsOfFile:[NSString stringWithUTF8String:argv[2]]];
            if (!data) { fprintf(stderr, "Can't read %s\n", argv[2]); return 1; }
            int w = atoi(argv[3]), h = atoi(argv[4]), bpr = atoi(argv[5]);
            CGContextRef ctx = CGBitmapContextCreate((void *)data.bytes, w, h, 8, bpr, cs, bitmapInfo);
            if (!ctx) { fprintf(stderr, "Can't create context\n"); return 1; }
            CGImageRef img = CGBitmapContextCreateImage(ctx);
            int ret = write_png(img, argv[6]);
            CGImageRelease(img); CGContextRelease(ctx); CGColorSpaceRelease(cs);
            if (!ret) fprintf(stderr, "Wrote %s (%dx%d)\n", argv[6], w, h);
            return ret;
        }

        // IOSurface mode
        uint32_t surfaceID = (uint32_t)atoi(argv[1]);
        IOSurfaceRef surface = IOSurfaceLookup(surfaceID);
        if (!surface) {
            fprintf(stderr, "IOSurfaceLookup(%u) failed — surface not found or not global\n", surfaceID);
            return 1;
        }

        IOSurfaceLock(surface, kIOSurfaceLockReadOnly, NULL);
        int w = (int)IOSurfaceGetWidth(surface);
        int h = (int)IOSurfaceGetHeight(surface);
        int bpr = (int)IOSurfaceGetBytesPerRow(surface);
        void *base = IOSurfaceGetBaseAddress(surface);

        CGContextRef ctx = CGBitmapContextCreate(base, w, h, 8, bpr, cs, bitmapInfo);
        CGImageRef img = CGBitmapContextCreateImage(ctx);
        IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, NULL);

        int ret = write_png(img, argv[2]);
        CGImageRelease(img); CGContextRelease(ctx);
        CGColorSpaceRelease(cs); CFRelease(surface);

        if (!ret) fprintf(stderr, "Wrote %s (%dx%d) from IOSurface %u\n", argv[2], w, h, surfaceID);
        return ret;
    }
}
