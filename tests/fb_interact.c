/*
 * fb_interact.c — Send a sequence of touches/keys to the simulator
 *
 * Usage: ./tests/fb_interact <command> [args...]
 *   tap <x> <y>          — send BEGAN + ENDED at (x,y)
 *   type <text>          — send each character as key_char
 *   key <keycode>        — send a special key (51=backspace, 36=return, etc.)
 *   wait <ms>            — sleep for N milliseconds
 *   screenshot <path>    — take a framebuffer screenshot via python
 *
 * Compile: clang -o tests/fb_interact tests/fb_interact.c
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <mach/mach_time.h>
#include <stdint.h>

#define FB_PATH       "/tmp/rosettasim_framebuffer"
#define FB_HEADER     64
#define RING_SIZE     16
#define EVENT_SIZE    32

static void *g_mmap = NULL;
static size_t g_size = 0;

static int open_fb(void) {
    int fd = open(FB_PATH, O_RDWR);
    if (fd < 0) { fprintf(stderr, "Cannot open framebuffer\n"); return -1; }
    struct stat st; fstat(fd, &st); g_size = st.st_size;
    g_mmap = mmap(NULL, g_size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    return (g_mmap == MAP_FAILED) ? -1 : 0;
}

static void send_touch(uint32_t phase, float x, float y) {
    uint8_t *input = (uint8_t *)g_mmap + FB_HEADER;
    uint64_t *wi = (uint64_t *)input;
    uint64_t idx = *wi;
    int slot = (int)(idx % RING_SIZE);
    uint8_t *ev = input + 8 + (slot * EVENT_SIZE);
    *(uint32_t *)(ev + 0) = phase;
    *(float *)(ev + 4) = x;
    *(float *)(ev + 8) = y;
    *(uint32_t *)(ev + 12) = 0;
    *(uint64_t *)(ev + 16) = mach_absolute_time();
    __sync_synchronize();
    *wi = idx + 1;
}

static void send_tap(float x, float y) {
    send_touch(1, x, y); /* BEGAN */
    usleep(60000);
    send_touch(3, x, y); /* ENDED */
}

static void send_key(uint32_t code, uint32_t ch) {
    uint8_t *input = (uint8_t *)g_mmap + FB_HEADER;
    uint8_t *kb = input + 8 + (RING_SIZE * EVENT_SIZE);
    *(uint32_t *)(kb + 0) = code;
    *(uint32_t *)(kb + 4) = 0; /* flags */
    *(uint32_t *)(kb + 8) = ch;
    __sync_synchronize();
}

int main(int argc, char *argv[]) {
    if (argc < 2) {
        fprintf(stderr, "Usage: fb_interact <command> [args...]\n");
        return 1;
    }
    if (open_fb() < 0) return 1;

    int i = 1;
    while (i < argc) {
        if (strcmp(argv[i], "tap") == 0 && i + 2 < argc) {
            float x = atof(argv[i+1]), y = atof(argv[i+2]);
            printf("tap (%.0f, %.0f)\n", x, y);
            send_tap(x, y);
            usleep(200000);
            i += 3;
        } else if (strcmp(argv[i], "type") == 0 && i + 1 < argc) {
            const char *text = argv[i+1];
            printf("type '%s'\n", text);
            for (int j = 0; text[j]; j++) {
                send_key(0, (uint32_t)(unsigned char)text[j]);
                usleep(80000);
            }
            usleep(200000);
            i += 2;
        } else if (strcmp(argv[i], "key") == 0 && i + 1 < argc) {
            uint32_t code = atoi(argv[i+1]);
            printf("key %u\n", code);
            send_key(code, 0);
            usleep(200000);
            i += 2;
        } else if (strcmp(argv[i], "wait") == 0 && i + 1 < argc) {
            int ms = atoi(argv[i+1]);
            printf("wait %dms\n", ms);
            usleep(ms * 1000);
            i += 2;
        } else if (strcmp(argv[i], "screenshot") == 0 && i + 1 < argc) {
            printf("screenshot %s\n", argv[i+1]);
            char cmd[512];
            snprintf(cmd, sizeof(cmd), "python3 tests/fb_screenshot.py %s", argv[i+1]);
            system(cmd);
            i += 2;
        } else {
            fprintf(stderr, "Unknown command: %s\n", argv[i]);
            i++;
        }
    }

    munmap(g_mmap, g_size);
    return 0;
}
