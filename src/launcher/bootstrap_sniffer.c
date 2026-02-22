/*
 * bootstrap_sniffer.c
 *
 * Native arm64 macOS tool that creates a Mach bootstrap port and spawns
 * a test binary under the iOS 10.3 SDK to capture the exact MIG message
 * format used by the SDK's bootstrap_check_in / bootstrap_look_up.
 *
 * Usage: ./bootstrap_sniffer <x86_64_test_binary>
 *    or: ./bootstrap_sniffer --self-test  (spawns a minimal test)
 *
 * Compile: clang -arch arm64 -o bootstrap_sniffer bootstrap_sniffer.c
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

/* Hex dump a buffer */
static void hexdump(const char *label, const void *data, size_t len) {
    const uint8_t *p = (const uint8_t *)data;
    printf("[sniffer] %s (%zu bytes):\n", label, len);
    for (size_t i = 0; i < len; i += 16) {
        printf("  %04zx: ", i);
        for (size_t j = 0; j < 16 && i + j < len; j++) {
            printf("%02x ", p[i + j]);
        }
        /* Pad if last line is short */
        for (size_t j = len - i; j < 16; j++) {
            printf("   ");
        }
        printf(" |");
        for (size_t j = 0; j < 16 && i + j < len; j++) {
            uint8_t c = p[i + j];
            printf("%c", (c >= 32 && c < 127) ? c : '.');
        }
        printf("|\n");
    }
}

/* Decode a Mach message header */
static void decode_header(const mach_msg_header_t *hdr) {
    printf("[sniffer] === Message Header ===\n");
    printf("  msgh_bits         = 0x%08x\n", hdr->msgh_bits);
    printf("    remote type     = %d\n", MACH_MSGH_BITS_REMOTE(hdr->msgh_bits));
    printf("    local type      = %d\n", MACH_MSGH_BITS_LOCAL(hdr->msgh_bits));
    printf("    complex         = %s\n", (hdr->msgh_bits & MACH_MSGH_BITS_COMPLEX) ? "YES" : "NO");
    printf("  msgh_size         = %u (0x%x)\n", hdr->msgh_size, hdr->msgh_size);
    printf("  msgh_remote_port  = 0x%x\n", hdr->msgh_remote_port);
    printf("  msgh_local_port   = 0x%x\n", hdr->msgh_local_port);
    printf("  msgh_voucher_port = 0x%x\n", hdr->msgh_voucher_port);
    printf("  msgh_id           = %d (0x%x)\n", hdr->msgh_id, hdr->msgh_id);
}

/* Decode body after header for complex messages */
static void decode_complex_body(const uint8_t *buf, size_t total_size) {
    if (total_size < sizeof(mach_msg_header_t) + sizeof(mach_msg_body_t)) return;

    const mach_msg_body_t *body = (const mach_msg_body_t *)(buf + sizeof(mach_msg_header_t));
    printf("  msgh_descriptor_count = %u\n", body->msgh_descriptor_count);

    const uint8_t *desc_ptr = buf + sizeof(mach_msg_header_t) + sizeof(mach_msg_body_t);
    for (uint32_t i = 0; i < body->msgh_descriptor_count; i++) {
        if (desc_ptr >= buf + total_size) break;
        uint32_t type = *(uint32_t *)(desc_ptr + 8) & 0xFF; /* type field at offset 8 in descriptor */
        printf("  Descriptor %u: type=%u", i, type);
        if (type == MACH_MSG_PORT_DESCRIPTOR) {
            mach_msg_port_descriptor_t *pd = (mach_msg_port_descriptor_t *)desc_ptr;
            printf(" (PORT) name=0x%x disposition=%u\n", pd->name, pd->disposition);
            desc_ptr += sizeof(mach_msg_port_descriptor_t);
        } else if (type == MACH_MSG_OOL_DESCRIPTOR) {
            printf(" (OOL)\n");
            desc_ptr += sizeof(mach_msg_ool_descriptor_t);
        } else {
            printf(" (UNKNOWN)\n");
            desc_ptr += 12; /* guess */
        }
    }
}

/* Try to extract a service name from the message */
static void try_extract_name(const uint8_t *buf, size_t total_size) {
    /* Search for printable strings that look like service names */
    for (size_t i = sizeof(mach_msg_header_t); i < total_size - 4; i++) {
        if (buf[i] >= 'A' && buf[i] <= 'z') {
            /* Check if this looks like a service name */
            size_t slen = 0;
            while (i + slen < total_size && buf[i + slen] != 0 &&
                   (buf[i + slen] >= '.' || buf[i + slen] == '_' ||
                    (buf[i + slen] >= 'A' && buf[i + slen] <= 'z') ||
                    (buf[i + slen] >= '0' && buf[i + slen] <= '9'))) {
                slen++;
            }
            if (slen > 8 && buf[i + slen] == 0) {
                printf("[sniffer] Possible service name at offset %zu: \"%.*s\"\n",
                       i, (int)slen, buf + i);
            }
        }
    }
}

/* Send a simple error reply for any message */
static void send_generic_reply(mach_port_t reply_port, int32_t msg_id, kern_return_t retcode) {
    struct {
        mach_msg_header_t head;
        NDR_record_t ndr;
        kern_return_t ret_code;
    } reply;

    memset(&reply, 0, sizeof(reply));
    reply.head.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_MOVE_SEND_ONCE, 0);
    reply.head.msgh_size = sizeof(reply);
    reply.head.msgh_remote_port = reply_port;
    reply.head.msgh_local_port = MACH_PORT_NULL;
    reply.head.msgh_id = msg_id + 100; /* Standard MIG reply convention */
    reply.ndr = NDR_record;
    reply.ret_code = retcode;

    kern_return_t kr = mach_msg(&reply.head, MACH_SEND_MSG, sizeof(reply), 0,
                                 MACH_PORT_NULL, MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL);
    printf("[sniffer] Sent reply (retcode=%d): kr=0x%x\n", retcode, kr);
}

/* Send a port reply (for check_in: MOVE_RECEIVE, for look_up: COPY_SEND) */
static void send_port_reply(mach_port_t reply_port, int32_t msg_id,
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
    reply.head.msgh_local_port = MACH_PORT_NULL;
    reply.head.msgh_id = msg_id + 100;
    reply.body.msgh_descriptor_count = 1;
    reply.port_desc.name = port;
    reply.port_desc.disposition = disposition;
    reply.port_desc.type = MACH_MSG_PORT_DESCRIPTOR;

    kern_return_t kr = mach_msg(&reply.head, MACH_SEND_MSG, sizeof(reply), 0,
                                 MACH_PORT_NULL, MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL);
    printf("[sniffer] Sent port reply (port=0x%x, disposition=%d): kr=0x%x\n",
           port, disposition, kr);
}

int main(int argc, char *argv[]) {
    printf("[sniffer] Bootstrap MIG protocol sniffer starting\n");
    printf("[sniffer] PID: %d\n", getpid());

    /* Create bootstrap port */
    mach_port_t bp = MACH_PORT_NULL;
    kern_return_t kr = mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &bp);
    if (kr != KERN_SUCCESS) {
        fprintf(stderr, "[sniffer] Failed to allocate port: 0x%x\n", kr);
        return 1;
    }
    kr = mach_port_insert_right(mach_task_self(), bp, bp, MACH_MSG_TYPE_MAKE_SEND);
    if (kr != KERN_SUCCESS) {
        fprintf(stderr, "[sniffer] Failed to insert send right: 0x%x\n", kr);
        return 1;
    }
    printf("[sniffer] Bootstrap port: 0x%x\n", bp);

    /* Determine SDK path */
    const char *sdk = "/Applications/Xcode-8.3.3.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator10.3.sdk";

    /* Build backboardd path */
    char backboardd_path[1024];
    snprintf(backboardd_path, sizeof(backboardd_path), "%s/usr/libexec/backboardd", sdk);

    /* Verify it exists */
    if (access(backboardd_path, X_OK) != 0) {
        fprintf(stderr, "[sniffer] backboardd not found: %s\n", backboardd_path);
        return 1;
    }
    printf("[sniffer] Will spawn: %s\n", backboardd_path);

    /* Setup environment for backboardd */
    char env_root[1024], env_sim_root[1024], env_iphone_root[1024];
    snprintf(env_root, sizeof(env_root), "DYLD_ROOT_PATH=%s", sdk);
    snprintf(env_sim_root, sizeof(env_sim_root), "SIMULATOR_ROOT=%s", sdk);
    snprintf(env_iphone_root, sizeof(env_iphone_root), "IPHONE_SIMULATOR_ROOT=%s", sdk);

    char *env[] = {
        env_root,
        env_sim_root,
        env_iphone_root,
        "HOME=/tmp/rosettasim_sniffer_home",
        "CFFIXED_USER_HOME=/tmp/rosettasim_sniffer_home",
        "TMPDIR=/tmp",
        "SIMULATOR_DEVICE_NAME=iPhone 6s",
        "SIMULATOR_MODEL_IDENTIFIER=iPhone8,1",
        "SIMULATOR_RUNTIME_VERSION=10.3",
        "SIMULATOR_RUNTIME_BUILD_VERSION=14E8301",
        "SIMULATOR_MAINSCREEN_WIDTH=750",
        "SIMULATOR_MAINSCREEN_HEIGHT=1334",
        "SIMULATOR_MAINSCREEN_SCALE=2.0",
        NULL
    };

    /* Create home directory */
    mkdir("/tmp/rosettasim_sniffer_home", 0755);
    mkdir("/tmp/rosettasim_sniffer_home/Library", 0755);
    mkdir("/tmp/rosettasim_sniffer_home/Library/Preferences", 0755);
    mkdir("/tmp/rosettasim_sniffer_home/Library/Caches", 0755);
    mkdir("/tmp/rosettasim_sniffer_home/tmp", 0755);

    /* Setup spawn attributes with our bootstrap port */
    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    kr = posix_spawnattr_setspecialport_np(&attr, bp, TASK_BOOTSTRAP_PORT);
    if (kr != KERN_SUCCESS) {
        fprintf(stderr, "[sniffer] posix_spawnattr_setspecialport_np failed: 0x%x\n", kr);
        return 1;
    }
    printf("[sniffer] Bootstrap port set for child process\n");

    /* Spawn backboardd WITHOUT any shim libraries - just bare */
    char *child_argv[] = { backboardd_path, NULL };
    pid_t child_pid;
    int spawn_result = posix_spawn(&child_pid, backboardd_path, NULL, &attr, child_argv, env);
    posix_spawnattr_destroy(&attr);

    if (spawn_result != 0) {
        fprintf(stderr, "[sniffer] posix_spawn failed: %s (errno %d)\n",
                strerror(spawn_result), spawn_result);
        return 1;
    }
    printf("[sniffer] Child spawned: PID %d\n", child_pid);

    /* Receive messages and decode them */
    uint8_t buf[8192];
    mach_msg_header_t *hdr = (mach_msg_header_t *)buf;
    int msg_count = 0;
    int max_messages = 50; /* Capture first 50 messages */

    printf("\n[sniffer] ========================================\n");
    printf("[sniffer]  Listening for bootstrap messages...\n");
    printf("[sniffer] ========================================\n\n");

    while (msg_count < max_messages) {
        memset(buf, 0, sizeof(buf));

        kr = mach_msg(hdr, MACH_RCV_MSG | MACH_RCV_LARGE | MACH_RCV_TIMEOUT,
                      0, sizeof(buf), bp, 2000 /* 2s timeout */, MACH_PORT_NULL);

        if (kr == MACH_RCV_TIMED_OUT) {
            /* Check if child is still alive */
            int status;
            pid_t result = waitpid(child_pid, &status, WNOHANG);
            if (result == child_pid) {
                printf("[sniffer] Child exited with status %d\n", status);
                break;
            }
            if (msg_count == 0) {
                printf("[sniffer] No messages after 2s... (child PID %d still running)\n", child_pid);
            }
            continue;
        }

        if (kr != KERN_SUCCESS) {
            printf("[sniffer] mach_msg error: 0x%x\n", kr);
            break;
        }

        msg_count++;
        printf("\n[sniffer] ===== MESSAGE #%d =====\n", msg_count);
        decode_header(hdr);

        /* Decode complex body if present */
        if (hdr->msgh_bits & MACH_MSGH_BITS_COMPLEX) {
            decode_complex_body(buf, hdr->msgh_size);
        }

        /* Hex dump the full message */
        hexdump("Full message", buf, hdr->msgh_size);

        /* Try to extract service names */
        try_extract_name(buf, hdr->msgh_size);

        /* Respond to the message to prevent child from hanging.
         * After mach_msg receive:
         *   msgh_remote_port = reply port (SEND_ONCE right)
         *   msgh_local_port = port we received on (our bootstrap port)
         */
        if (hdr->msgh_remote_port != MACH_PORT_NULL) {
            mach_port_t reply = hdr->msgh_remote_port;

            /* For bootstrap messages, handle based on ID */
            if (hdr->msgh_id == 402) {
                /* check_in: create a real port and send MOVE_RECEIVE */
                mach_port_t svc_port;
                mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &svc_port);
                mach_port_insert_right(mach_task_self(), svc_port, svc_port, MACH_MSG_TYPE_MAKE_SEND);
                printf("[sniffer] Replying to check_in (ID 402) with port 0x%x (MOVE_RECEIVE)\n", svc_port);
                send_port_reply(reply, hdr->msgh_id, svc_port, MACH_MSG_TYPE_MOVE_RECEIVE);
            } else if (hdr->msgh_id == 404) {
                /* look_up: reply with UNKNOWN_SERVICE to let child proceed */
                /* Extract service name for logging */
                char svc_name[129] = {0};
                if (hdr->msgh_size >= 32 + 16) {
                    memcpy(svc_name, buf + 32, 128);
                    svc_name[128] = '\0';
                }
                printf("[sniffer] Replying to look_up (ID 404) for '%s' with UNKNOWN_SERVICE\n", svc_name);
                send_generic_reply(reply, hdr->msgh_id, 1102); /* BOOTSTRAP_UNKNOWN_SERVICE */
            } else if (hdr->msgh_id == 403) {
                /* register: accept and reply OK */
                printf("[sniffer] Replying to register (ID 403) with SUCCESS\n");
                send_generic_reply(reply, hdr->msgh_id, 0); /* KERN_SUCCESS */
            } else {
                printf("[sniffer] Replying with error to ID %d\n", hdr->msgh_id);
                send_generic_reply(reply, hdr->msgh_id, MIG_BAD_ID);
            }
        }

        fflush(stdout);
    }

    printf("\n[sniffer] ========================================\n");
    printf("[sniffer]  Captured %d messages\n", msg_count);
    printf("[sniffer] ========================================\n");

    /* Kill child */
    kill(child_pid, SIGKILL);
    waitpid(child_pid, NULL, 0);

    printf("[sniffer] Done.\n");
    return 0;
}
