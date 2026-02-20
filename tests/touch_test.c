/*
 * touch_test.c — Automated touch delivery test harness
 *
 * Sends synthetic touch events via the shared mmap framebuffer and
 * verifies delivery by checking the bridge's stderr log output.
 *
 * Usage:
 *   1. Launch simulator: bash scripts/run_sim.sh <app> 2>/tmp/rosettasim_bridge.log &
 *   2. Wait ~3s for framebuffer creation
 *   3. Run: ./tests/touch_test
 *
 * Compile (native macOS):
 *   clang -o tests/touch_test tests/touch_test.c -framework CoreFoundation
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

/* Must match rosettasim_framebuffer.h v3 */
#define FB_PATH       "/tmp/rosettasim_framebuffer"
#define FB_HEADER     64
#define RING_SIZE     16
#define EVENT_SIZE    32  /* sizeof(RosettaSimTouchEvent) */

/* Touch phases */
#define TOUCH_BEGAN   1
#define TOUCH_MOVED   2
#define TOUCH_ENDED   3

/* Input region layout (after header at offset 64):
 *   offset 0:  touch_write_index (uint64_t)
 *   offset 8:  touch_ring[16] (16 * 32 bytes)
 *   offset 520: key_code, key_flags, key_char
 */

static void *g_mmap = NULL;
static size_t g_size = 0;

static int open_framebuffer(void) {
    int fd = open(FB_PATH, O_RDWR);
    if (fd < 0) {
        fprintf(stderr, "ERROR: Cannot open %s — is the simulator running?\n", FB_PATH);
        return -1;
    }
    struct stat st;
    fstat(fd, &st);
    g_size = st.st_size;
    g_mmap = mmap(NULL, g_size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    if (g_mmap == MAP_FAILED) {
        fprintf(stderr, "ERROR: mmap failed\n");
        return -1;
    }
    /* Verify magic */
    uint32_t magic = *(uint32_t *)g_mmap;
    if (magic != 0x4D495352) {
        fprintf(stderr, "ERROR: Bad magic 0x%08x (expected RSIM)\n", magic);
        return -1;
    }
    printf("Framebuffer opened: %zu bytes, version %u\n",
           g_size, ((uint32_t *)g_mmap)[1]);
    return 0;
}

static void send_touch(uint32_t phase, float x, float y) {
    uint8_t *input = (uint8_t *)g_mmap + FB_HEADER;

    /* Read current write index */
    uint64_t *write_idx_ptr = (uint64_t *)input;
    uint64_t idx = *write_idx_ptr;
    int slot = (int)(idx % RING_SIZE);

    /* Write event to ring slot */
    uint8_t *ev = input + 8 + (slot * EVENT_SIZE);
    *(uint32_t *)(ev + 0) = phase;        /* touch_phase */
    *(float *)(ev + 4) = x;               /* touch_x */
    *(float *)(ev + 8) = y;               /* touch_y */
    *(uint32_t *)(ev + 12) = 0;           /* touch_id */
    *(uint64_t *)(ev + 16) = mach_absolute_time(); /* timestamp */

    __sync_synchronize();
    *write_idx_ptr = idx + 1;

    const char *pname = phase == TOUCH_BEGAN ? "BEGAN" :
                        phase == TOUCH_ENDED ? "ENDED" :
                        phase == TOUCH_MOVED ? "MOVED" : "?";
    printf("  Sent %s at (%.0f, %.0f) [slot %d, idx %llu]\n", pname, x, y, slot, idx + 1);
}

static void send_tap(float x, float y) {
    send_touch(TOUCH_BEGAN, x, y);
    usleep(50000); /* 50ms between began and ended — realistic tap timing */
    send_touch(TOUCH_ENDED, x, y);
}

static void send_key(uint32_t keyCode, uint32_t flags, uint32_t ch) {
    uint8_t *input = (uint8_t *)g_mmap + FB_HEADER;
    /* Key fields at offset 520 (8 + 16*32) */
    uint8_t *keyBase = input + 8 + (RING_SIZE * EVENT_SIZE);
    *(uint32_t *)(keyBase + 0) = keyCode;
    *(uint32_t *)(keyBase + 4) = flags;
    *(uint32_t *)(keyBase + 8) = ch;
    __sync_synchronize();
    printf("  Sent key code=%u char='%c'\n", keyCode, ch >= 32 ? (char)ch : '?');
}

/* Check bridge log for expected strings */
static int check_log(const char *pattern) {
    char cmd[512];
    snprintf(cmd, sizeof(cmd), "grep -c '%s' /tmp/rosettasim_bridge.log 2>/dev/null", pattern);
    FILE *f = popen(cmd, "r");
    if (!f) return 0;
    int count = 0;
    fscanf(f, "%d", &count);
    pclose(f);
    return count;
}

/* Count occurrences of a pattern in the log since a given line */
static int check_log_since(const char *pattern, int since_line) {
    char cmd[512];
    snprintf(cmd, sizeof(cmd),
             "tail -n +%d /tmp/rosettasim_bridge.log | grep -c '%s' 2>/dev/null",
             since_line, pattern);
    FILE *f = popen(cmd, "r");
    if (!f) return 0;
    int count = 0;
    fscanf(f, "%d", &count);
    pclose(f);
    return count;
}

static int get_log_lines(void) {
    FILE *f = popen("wc -l < /tmp/rosettasim_bridge.log 2>/dev/null", "r");
    if (!f) return 0;
    int count = 0;
    fscanf(f, "%d", &count);
    pclose(f);
    return count;
}

/* ================================================================ */

int main(int argc, char *argv[]) {
    printf("=== RosettaSim Touch Test Harness ===\n\n");

    if (open_framebuffer() < 0) return 1;

    /* Wait a moment for the bridge to be ready */
    usleep(500000);

    /*
     * Known coordinates from the view hierarchy dump:
     *   UITextField (URL field):       ~x=150, y=360
     *   UIButton (server):             ~x=130, y=270
     *   UISegmentedControl:            ~x=100, y=414
     *   UIButton (Connect):            ~x=150, y=490-ish
     *   UISwitch:                      near bottom
     *
     * These are approximate — the hit test should find them.
     */

    int passed = 0, failed = 0, total = 0;

    /* --- Test 1: Tap UITextField --- */
    {
        total++;
        printf("\nTest 1: Tap UITextField at (150, 360)\n");
        int before = get_log_lines();
        send_tap(150.0f, 360.0f);
        usleep(200000); /* Wait for bridge to process */
        int began = check_log_since("Touch BEGAN.*UITextField", before);
        int ended = check_log_since("Touch ENDED.*UITextField", before);
        int fr_set = check_log_since("Set first responder", before);
        printf("  Results: BEGAN→UITextField=%d, ENDED→UITextField=%d, firstResponder=%d\n",
               began, ended, fr_set);
        if (began > 0 && ended > 0) {
            printf("  ✓ PASS: UITextField received touch\n");
            if (fr_set > 0) printf("  ✓ PASS: First responder set\n");
            else { printf("  ✗ FAIL: First responder NOT set\n"); failed++; }
            passed++;
        } else {
            printf("  ✗ FAIL: UITextField did not receive touch\n");
            failed++;
        }
    }

    /* --- Test 2: Type into UITextField --- */
    {
        total++;
        printf("\nTest 2: Type 'hello' into focused UITextField\n");
        int before = get_log_lines();
        const char *text = "hello";
        for (int i = 0; text[i]; i++) {
            /* key_code doesn't matter for regular chars — key_char drives insertText */
            send_key(0, 0, (uint32_t)text[i]);
            usleep(100000);
        }
        usleep(200000);
        int delivered = check_log_since("Delivered insertText", before);
        printf("  Results: insertText deliveries=%d (expected 5)\n", delivered);
        if (delivered >= 5) {
            printf("  ✓ PASS: All characters delivered\n");
            passed++;
        } else {
            printf("  ✗ FAIL: Only %d/5 characters delivered\n", delivered);
            failed++;
        }
    }

    /* --- Test 3: Tap UIButton (discovered server) --- */
    {
        total++;
        printf("\nTest 3: Tap UIButton at (130, 270)\n");
        int before = get_log_lines();
        send_tap(130.0f, 270.0f);
        usleep(200000);
        int began = check_log_since("Touch BEGAN.*UIButton", before);
        int tracking = check_log_since("beginTracking\\|endTracking\\|sendActions\\|setHighlighted", before);
        printf("  Results: BEGAN→UIButton=%d, tracking/actions=%d\n", began, tracking);
        if (began > 0) {
            printf("  ✓ PASS: UIButton received touch\n");
            if (tracking > 0) printf("  ✓ PASS: UIButton tracking fired\n");
            else printf("  ✗ FAIL: UIButton tracking did NOT fire\n");
            passed++;
        } else {
            /* Might hit a different view — check what was hit */
            printf("  ? Checking actual hit target...\n");
            int any_began = check_log_since("Touch BEGAN", before);
            if (any_began > 0) {
                char cmd[256];
                snprintf(cmd, sizeof(cmd),
                         "tail -n +%d /tmp/rosettasim_bridge.log | grep 'Touch BEGAN' | head -1",
                         before);
                FILE *f = popen(cmd, "r");
                char buf[256] = {0};
                if (f) { fgets(buf, sizeof(buf), f); pclose(f); }
                printf("  Hit: %s", buf);
            }
            printf("  ✗ FAIL: UIButton not hit\n");
            failed++;
        }
    }

    /* --- Test 4: Tap UISegmentedControl --- */
    {
        total++;
        printf("\nTest 4: Tap UISegmentedControl at (250, 414)\n");
        int before = get_log_lines();
        send_tap(250.0f, 414.0f);
        usleep(200000);
        int began = check_log_since("Touch BEGAN.*UISegment", before);
        int changed = check_log_since("selectedIndex\\|ValueChanged", before);
        printf("  Results: BEGAN→UISegmented=%d, valueChanged=%d\n", began, changed);
        if (began > 0) {
            printf("  ✓ PASS: UISegmentedControl received touch\n");
            passed++;
        } else {
            printf("  ✗ FAIL: UISegmentedControl not hit\n");
            failed++;
        }
    }

    /* --- Test 5: Tap in lower screen area (Connect button region) --- */
    {
        total++;
        printf("\nTest 5: Tap Connect button area at (187, 490)\n");
        int before = get_log_lines();
        send_tap(187.0f, 490.0f);
        usleep(200000);
        int began = check_log_since("Touch BEGAN", before);
        char cmd[256];
        snprintf(cmd, sizeof(cmd),
                 "tail -n +%d /tmp/rosettasim_bridge.log | grep 'Touch BEGAN' | head -1",
                 before);
        FILE *f = popen(cmd, "r");
        char buf[256] = {0};
        if (f) { fgets(buf, sizeof(buf), f); pclose(f); }
        printf("  Hit: %s", buf[0] ? buf : "(nothing)\n");
        if (began > 0) {
            printf("  ✓ Event delivered (check target above)\n");
            passed++;
        } else {
            printf("  ✗ FAIL: No touch event received\n");
            failed++;
        }
    }

    /* --- Test 6: Verify no orphan drops --- */
    {
        total++;
        printf("\nTest 6: Check for orphan drops\n");
        int orphans = check_log("Dropping orphan");
        printf("  Orphan drops: %d\n", orphans);
        if (orphans == 0) {
            printf("  ✓ PASS: No orphan drops\n");
            passed++;
        } else {
            printf("  ✗ FAIL: %d orphan drops\n", orphans);
            failed++;
        }
    }

    /* --- Summary --- */
    printf("\n=== Results: %d/%d passed, %d failed ===\n", passed, total, failed);

    munmap(g_mmap, g_size);
    return failed > 0 ? 1 : 0;
}
