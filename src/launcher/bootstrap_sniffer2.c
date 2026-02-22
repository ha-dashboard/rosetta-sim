/*
 * bootstrap_sniffer2.c
 *
 * Simplified sniffer that spawns bootstrap_test_child under the iOS SDK
 * and captures + replies to all bootstrap messages. This verifies:
 * 1. posix_spawnattr_setspecialport_np works for Rosetta processes
 * 2. The exact MIG message format used by the iOS 10.3 SDK
 * 3. Correct reply formats for check_in/look_up/register
 */

#include <mach/mach.h>
#include <mach/message.h>
#include <servers/bootstrap.h>
#include <spawn.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <sys/wait.h>
#include <sys/stat.h>

static void hexdump(const void *data, size_t len) {
    const uint8_t *p = (const uint8_t *)data;
    for (size_t i = 0; i < len; i += 16) {
        printf("  %04zx: ", i);
        for (size_t j = 0; j < 16 && i + j < len; j++)
            printf("%02x ", p[i + j]);
        for (size_t j = len - i; j < 16; j++)
            printf("   ");
        printf(" |");
        for (size_t j = 0; j < 16 && i + j < len; j++) {
            uint8_t c = p[i + j];
            printf("%c", (c >= 32 && c < 127) ? c : '.');
        }
        printf("|\n");
    }
}

/* Send reply with port */
static void reply_with_port(mach_port_t reply_port, int32_t req_id,
                            mach_port_t port, mach_msg_type_name_t disposition) {
    struct {
        mach_msg_header_t head;
        mach_msg_body_t body;
        mach_msg_port_descriptor_t port_desc;
    } reply;
    memset(&reply, 0, sizeof(reply));
    reply.head.msgh_bits = MACH_MSGH_BITS_COMPLEX | MACH_MSGH_BITS(MACH_MSG_TYPE_MOVE_SEND_ONCE, 0);
    reply.head.msgh_size = sizeof(reply);
    reply.head.msgh_remote_port = reply_port;
    reply.head.msgh_id = req_id + 100;
    reply.body.msgh_descriptor_count = 1;
    reply.port_desc.name = port;
    reply.port_desc.disposition = disposition;
    reply.port_desc.type = MACH_MSG_PORT_DESCRIPTOR;

    kern_return_t kr = mach_msg(&reply.head, MACH_SEND_MSG, sizeof(reply), 0,
                                 MACH_PORT_NULL, MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL);
    printf("  -> reply with port 0x%x (disp=%d): kr=0x%x\n", port, disposition, kr);
}

/* Send error reply */
static void reply_with_error(mach_port_t reply_port, int32_t req_id, kern_return_t err) {
    struct {
        mach_msg_header_t head;
        NDR_record_t ndr;
        kern_return_t ret_code;
    } reply;
    memset(&reply, 0, sizeof(reply));
    reply.head.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_MOVE_SEND_ONCE, 0);
    reply.head.msgh_size = sizeof(reply);
    reply.head.msgh_remote_port = reply_port;
    reply.head.msgh_id = req_id + 100;
    reply.ndr = NDR_record;
    reply.ret_code = err;

    kern_return_t kr = mach_msg(&reply.head, MACH_SEND_MSG, sizeof(reply), 0,
                                 MACH_PORT_NULL, MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL);
    printf("  -> reply with error %d: kr=0x%x\n", err, kr);
}

/* Extract service name from message at offset 32 (after header + 8 bytes) */
static const char *extract_name(const uint8_t *buf, size_t size) {
    static char name[129];
    if (size >= 32 + 1) {
        memcpy(name, buf + 32, (size - 32 > 128) ? 128 : size - 32);
        name[128] = '\0';
    } else {
        name[0] = '\0';
    }
    return name;
}

int main(void) {
    printf("=== Bootstrap Protocol Sniffer v2 ===\n\n");

    /* Create bootstrap receive port */
    mach_port_t bp;
    kern_return_t kr;
    kr = mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &bp);
    kr = mach_port_insert_right(mach_task_self(), bp, bp, MACH_MSG_TYPE_MAKE_SEND);
    printf("Bootstrap port: 0x%x\n", bp);

    /* Build paths */
    const char *sdk = "/Applications/Xcode-8.3.3.app/Contents/Developer/Platforms/"
                      "iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator10.3.sdk";
    char child_path[1024];
    char cwd[512];
    getcwd(cwd, sizeof(cwd));
    snprintf(child_path, sizeof(child_path), "%s/src/launcher/bootstrap_test_child", cwd);

    printf("Child: %s\n", child_path);

    /* Environment for iOS simulator process */
    char env_root[1024];
    snprintf(env_root, sizeof(env_root), "DYLD_ROOT_PATH=%s", sdk);
    /* Build DYLD_INSERT_LIBRARIES path for bootstrap_fix.dylib */
    char env_dyld_insert[1024];
    snprintf(env_dyld_insert, sizeof(env_dyld_insert),
             "DYLD_INSERT_LIBRARIES=%s/src/launcher/bootstrap_fix.dylib", cwd);

    char *env[] = {
        env_root,
        env_dyld_insert,
        "HOME=/tmp/rosettasim_test",
        "TMPDIR=/tmp",
        NULL
    };
    mkdir("/tmp/rosettasim_test", 0755);

    /* Spawn with our bootstrap port */
    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    kr = posix_spawnattr_setspecialport_np(&attr, bp, TASK_BOOTSTRAP_PORT);
    printf("setspecialport_np: kr=0x%x\n", kr);

    char *argv[] = { child_path, NULL };
    pid_t child;
    int res = posix_spawn(&child, child_path, NULL, &attr, argv, env);
    posix_spawnattr_destroy(&attr);
    printf("posix_spawn: result=%d, child PID=%d\n\n", res, child);

    if (res != 0) {
        fprintf(stderr, "Spawn failed: %s\n", strerror(res));
        return 1;
    }

    /* Message receive loop */
    uint8_t buf[8192];
    mach_msg_header_t *hdr = (mach_msg_header_t *)buf;
    int count = 0;

    while (count < 30) {
        memset(buf, 0, sizeof(buf));
        kr = mach_msg(hdr, MACH_RCV_MSG | MACH_RCV_LARGE | MACH_RCV_TIMEOUT,
                      0, sizeof(buf), bp, 3000, MACH_PORT_NULL);

        if (kr == MACH_RCV_TIMED_OUT) {
            int status;
            if (waitpid(child, &status, WNOHANG) == child) {
                printf("\nChild exited (status %d)\n", status);
                break;
            }
            printf("... waiting (child still alive) ...\n");
            continue;
        }
        if (kr != KERN_SUCCESS) {
            printf("mach_msg error: 0x%x\n", kr);
            break;
        }

        count++;
        printf("--- Message #%d ---\n", count);
        printf("  ID=%d (0x%x) size=%u complex=%s\n",
               hdr->msgh_id, hdr->msgh_id, hdr->msgh_size,
               (hdr->msgh_bits & MACH_MSGH_BITS_COMPLEX) ? "YES" : "NO");
        printf("  remote=0x%x local=0x%x voucher=0x%x\n",
               hdr->msgh_remote_port, hdr->msgh_local_port, hdr->msgh_voucher_port);

        /* Extract name if this looks like a bootstrap message */
        const char *name = extract_name(buf, hdr->msgh_size);
        if (name[0]) printf("  name='%s'\n", name);

        hexdump(buf, hdr->msgh_size > 256 ? 256 : hdr->msgh_size);

        /* Handle the message */
        mach_port_t reply = hdr->msgh_remote_port;
        if (reply == MACH_PORT_NULL) {
            printf("  (no reply port)\n");
            continue;
        }

        switch (hdr->msgh_id) {
            case 402: { /* bootstrap_check_in */
                printf("  ACTION: check_in for '%s'\n", name);
                mach_port_t svc;
                mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &svc);
                mach_port_insert_right(mach_task_self(), svc, svc, MACH_MSG_TYPE_MAKE_SEND);
                reply_with_port(reply, 402, svc, MACH_MSG_TYPE_MOVE_RECEIVE);
                break;
            }
            case 403: { /* bootstrap_register */
                printf("  ACTION: register for '%s'\n", name);
                reply_with_error(reply, 403, 0); /* success */
                break;
            }
            case 404: { /* bootstrap_look_up */
                printf("  ACTION: look_up for '%s'\n", name);
                /* Reply UNKNOWN so child doesn't hang trying to use dummy port */
                reply_with_error(reply, 404, 1102); /* BOOTSTRAP_UNKNOWN_SERVICE */
                break;
            }
            default:
                printf("  ACTION: unknown ID %d, replying error\n", hdr->msgh_id);
                reply_with_error(reply, hdr->msgh_id, -305 /* MIG_BAD_ID */);
                break;
        }
        fflush(stdout);
    }

    printf("\n=== Captured %d messages ===\n", count);
    kill(child, SIGKILL);
    waitpid(child, NULL, 0);
    return 0;
}
