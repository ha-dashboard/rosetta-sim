#!/usr/bin/env python3
"""
Read the RosettaSim shared framebuffer and save as PNG.

Usage:
    python3 tests/fb_screenshot.py [output.png]
    python3 tests/fb_screenshot.py  # defaults to /tmp/rosettasim_screenshot.png
"""
import sys
import struct
import mmap
import os

def main():
    outpath = sys.argv[1] if len(sys.argv) > 1 else "/tmp/rosettasim_screenshot.png"
    fbpath = "/tmp/rosettasim_framebuffer"

    if not os.path.exists(fbpath):
        print(f"ERROR: {fbpath} not found — is the simulator running?")
        return 1

    fd = os.open(fbpath, os.O_RDONLY)
    st = os.fstat(fd)
    mm = mmap.mmap(fd, st.st_size, access=mmap.ACCESS_READ)
    os.close(fd)

    # Read header (64 bytes)
    magic, version, width, height, stride, fmt = struct.unpack_from("<IIIIII", mm, 0)
    frame_counter = struct.unpack_from("<Q", mm, 24)[0]

    if magic != 0x4D495352:
        print(f"ERROR: Bad magic 0x{magic:08x}")
        return 1

    print(f"Framebuffer: {width}x{height}, version {version}, frame #{frame_counter}")

    # Calculate input region size for v3
    # 8 (write_index) + 16*32 (ring) + 12 (keys) + 20 (reserved) = 552
    input_size = 8 + 16 * 32 + 12 + 20
    meta_size = 64 + input_size
    pixel_offset = meta_size

    pixel_size = width * height * 4
    if st.st_size < pixel_offset + pixel_size:
        print(f"ERROR: File too small ({st.st_size} < {pixel_offset + pixel_size})")
        return 1

    # Read BGRA pixel data
    pixels = mm[pixel_offset:pixel_offset + pixel_size]
    mm.close()

    # Convert BGRA to RGBA
    import array
    rgba = bytearray(pixel_size)
    for i in range(0, pixel_size, 4):
        rgba[i]   = pixels[i+2]  # R <- B
        rgba[i+1] = pixels[i+1]  # G
        rgba[i+2] = pixels[i]    # B <- R
        rgba[i+3] = pixels[i+3]  # A

    # The framebuffer is in CG coordinates (origin bottom-left).
    # Flip vertically to get standard raster order (origin top-left).
    row_bytes = width * 4
    flipped = bytearray(pixel_size)
    for y in range(height):
        src_row = (height - 1 - y) * row_bytes
        dst_row = y * row_bytes
        flipped[dst_row:dst_row + row_bytes] = rgba[src_row:src_row + row_bytes]

    # Write PNG using zlib (no PIL dependency)
    import zlib

    def write_png(path, w, h, rgba_data):
        def chunk(ctype, data):
            c = ctype + data
            crc = struct.pack(">I", zlib.crc32(c) & 0xFFFFFFFF)
            return struct.pack(">I", len(data)) + c + crc

        # IHDR
        ihdr = struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0)  # 8-bit RGBA
        # IDAT - add filter byte (0 = None) to each row
        raw = bytearray()
        rb = w * 4
        for y in range(h):
            raw.append(0)  # filter: None
            raw.extend(rgba_data[y*rb:(y+1)*rb])
        compressed = zlib.compress(bytes(raw), 9)

        with open(path, "wb") as f:
            f.write(b"\x89PNG\r\n\x1a\n")
            f.write(chunk(b"IHDR", ihdr))
            f.write(chunk(b"IDAT", compressed))
            f.write(chunk(b"IEND", b""))

    write_png(outpath, width, height, flipped)
    fsize = os.path.getsize(outpath)
    print(f"Saved: {outpath} ({fsize} bytes)")
    return 0

if __name__ == "__main__":
    sys.exit(main())
