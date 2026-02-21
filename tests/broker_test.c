/*
 * broker_test.c
 *
 * Test program to verify RosettaSim broker functionality.
 * This test runs as a separate process spawned with the broker port.
 */

#include <mach/mach.h>
#include <mach/message.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* Message IDs */
#define BOOTSTRAP_CHECK_IN      400
#define BOOTSTRAP_REGISTER      401
#define BOOTSTRAP_LOOK_UP       402
#define MIG_REPLY_OFFSET        100

#define MAX_NAME_LEN            128

/* Use system's NDR_record from mach/ndr.h */
extern NDR_record_t NDR_record;

/* Message structures */
#pragma pack(4)
typedef struct {
    mach_msg_header_t head;
    NDR_record_t ndr;
    uint32_t name_len;
    char name[MAX_NAME_LEN];
} bootstrap_simple_request_t;

typedef struct {
    mach_msg_header_t head;
    mach_msg_body_t body;
    mach_msg_port_descriptor_t port_desc;
} bootstrap_port_reply_t;

typedef struct {
    mach_msg_header_t head;
    NDR_record_t ndr;
    kern_return_t ret_code;
} bootstrap_error_reply_t;
#pragma pack()

/* Get broker port from bootstrap port */
static mach_port_t get_broker_port(void) {
    mach_port_t broker_port = MACH_PORT_NULL;
    kern_return_t kr = task_get_special_port(mach_task_self(), TASK_BOOTSTRAP_PORT, &broker_port);

    if (kr != KERN_SUCCESS) {
        printf("FAIL: task_get_special_port failed: 0x%x\n", kr);
        return MACH_PORT_NULL;
    }

    printf("INFO: got broker port: 0x%x\n", broker_port);
    return broker_port;
}

/* Test bootstrap_check_in */
static int test_check_in(mach_port_t broker_port) {
    printf("\n=== Testing bootstrap_check_in ===\n");

    const char *service_name = "com.test.service1";

    /* Build request */
    bootstrap_simple_request_t request;
    memset(&request, 0, sizeof(request));

    /* Allocate reply port */
    mach_port_t reply_port = MACH_PORT_NULL;
    kern_return_t kr = mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &reply_port);
    if (kr != KERN_SUCCESS) {
        printf("FAIL: mach_port_allocate failed: 0x%x\n", kr);
        return 1;
    }

    request.head.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, MACH_MSG_TYPE_MAKE_SEND_ONCE);
    request.head.msgh_size = sizeof(request);
    request.head.msgh_remote_port = broker_port;
    request.head.msgh_local_port = reply_port;
    request.head.msgh_id = BOOTSTRAP_CHECK_IN;

    request.ndr = NDR_record;
    request.name_len = (uint32_t)strlen(service_name);
    strncpy(request.name, service_name, MAX_NAME_LEN);

    /* Send request */
    printf("INFO: sending check_in request for %s\n", service_name);
    kr = mach_msg(&request.head, MACH_SEND_MSG, sizeof(request), 0,
                  MACH_PORT_NULL, MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL);

    if (kr != KERN_SUCCESS) {
        printf("FAIL: mach_msg send failed: 0x%x\n", kr);
        mach_port_deallocate(mach_task_self(), reply_port);
        return 1;
    }

    /* Receive reply */
    union {
        bootstrap_port_reply_t port_reply;
        bootstrap_error_reply_t error_reply;
        uint8_t buffer[256];
    } reply;
    memset(&reply, 0, sizeof(reply));

    kr = mach_msg(&reply.port_reply.head, MACH_RCV_MSG, 0, sizeof(reply),
                  reply_port, MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL);

    if (kr != KERN_SUCCESS) {
        printf("FAIL: mach_msg receive failed: 0x%x\n", kr);
        mach_port_deallocate(mach_task_self(), reply_port);
        return 1;
    }

    printf("INFO: received reply: id=%d size=%d\n",
           reply.port_reply.head.msgh_id, reply.port_reply.head.msgh_size);

    /* Check reply */
    if (reply.port_reply.head.msgh_id != BOOTSTRAP_CHECK_IN + MIG_REPLY_OFFSET) {
        printf("FAIL: unexpected reply id: %d\n", reply.port_reply.head.msgh_id);
        mach_port_deallocate(mach_task_self(), reply_port);
        return 1;
    }

    /* Check if complex (success with port) or simple (error) */
    if (reply.port_reply.head.msgh_bits & MACH_MSGH_BITS_COMPLEX) {
        printf("INFO: received port reply\n");
        mach_port_t service_port = reply.port_reply.port_desc.name;
        printf("PASS: check_in returned port: 0x%x\n", service_port);

        /* Clean up */
        mach_port_deallocate(mach_task_self(), service_port);
    } else {
        kern_return_t error = reply.error_reply.ret_code;
        printf("FAIL: check_in returned error: 0x%x\n", error);
        mach_port_deallocate(mach_task_self(), reply_port);
        return 1;
    }

    mach_port_deallocate(mach_task_self(), reply_port);
    return 0;
}

/* Test bootstrap_look_up */
static int test_look_up(mach_port_t broker_port) {
    printf("\n=== Testing bootstrap_look_up ===\n");

    const char *service_name = "com.test.service1";

    /* Build request */
    bootstrap_simple_request_t request;
    memset(&request, 0, sizeof(request));

    /* Allocate reply port */
    mach_port_t reply_port = MACH_PORT_NULL;
    kern_return_t kr = mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &reply_port);
    if (kr != KERN_SUCCESS) {
        printf("FAIL: mach_port_allocate failed: 0x%x\n", kr);
        return 1;
    }

    request.head.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, MACH_MSG_TYPE_MAKE_SEND_ONCE);
    request.head.msgh_size = sizeof(request);
    request.head.msgh_remote_port = broker_port;
    request.head.msgh_local_port = reply_port;
    request.head.msgh_id = BOOTSTRAP_LOOK_UP;

    request.ndr = NDR_record;
    request.name_len = (uint32_t)strlen(service_name);
    strncpy(request.name, service_name, MAX_NAME_LEN);

    /* Send request */
    printf("INFO: sending look_up request for %s\n", service_name);
    kr = mach_msg(&request.head, MACH_SEND_MSG, sizeof(request), 0,
                  MACH_PORT_NULL, MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL);

    if (kr != KERN_SUCCESS) {
        printf("FAIL: mach_msg send failed: 0x%x\n", kr);
        mach_port_deallocate(mach_task_self(), reply_port);
        return 1;
    }

    /* Receive reply */
    union {
        bootstrap_port_reply_t port_reply;
        bootstrap_error_reply_t error_reply;
        uint8_t buffer[256];
    } reply;
    memset(&reply, 0, sizeof(reply));

    kr = mach_msg(&reply.port_reply.head, MACH_RCV_MSG, 0, sizeof(reply),
                  reply_port, MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL);

    if (kr != KERN_SUCCESS) {
        printf("FAIL: mach_msg receive failed: 0x%x\n", kr);
        mach_port_deallocate(mach_task_self(), reply_port);
        return 1;
    }

    printf("INFO: received reply: id=%d size=%d\n",
           reply.port_reply.head.msgh_id, reply.port_reply.head.msgh_size);

    /* Check reply */
    if (reply.port_reply.head.msgh_id != BOOTSTRAP_LOOK_UP + MIG_REPLY_OFFSET) {
        printf("FAIL: unexpected reply id: %d\n", reply.port_reply.head.msgh_id);
        mach_port_deallocate(mach_task_self(), reply_port);
        return 1;
    }

    /* Check if complex (success with port) or simple (error) */
    if (reply.port_reply.head.msgh_bits & MACH_MSGH_BITS_COMPLEX) {
        printf("INFO: received port reply\n");
        mach_port_t service_port = reply.port_reply.port_desc.name;
        printf("PASS: look_up found service port: 0x%x\n", service_port);

        /* Clean up */
        mach_port_deallocate(mach_task_self(), service_port);
    } else {
        kern_return_t error = reply.error_reply.ret_code;
        printf("FAIL: look_up returned error: 0x%x\n", error);
        mach_port_deallocate(mach_task_self(), reply_port);
        return 1;
    }

    mach_port_deallocate(mach_task_self(), reply_port);
    return 0;
}

/* Test bootstrap_look_up for non-existent service */
static int test_look_up_fail(mach_port_t broker_port) {
    printf("\n=== Testing bootstrap_look_up (non-existent) ===\n");

    const char *service_name = "com.test.nonexistent";

    /* Build request */
    bootstrap_simple_request_t request;
    memset(&request, 0, sizeof(request));

    /* Allocate reply port */
    mach_port_t reply_port = MACH_PORT_NULL;
    kern_return_t kr = mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &reply_port);
    if (kr != KERN_SUCCESS) {
        printf("FAIL: mach_port_allocate failed: 0x%x\n", kr);
        return 1;
    }

    request.head.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, MACH_MSG_TYPE_MAKE_SEND_ONCE);
    request.head.msgh_size = sizeof(request);
    request.head.msgh_remote_port = broker_port;
    request.head.msgh_local_port = reply_port;
    request.head.msgh_id = BOOTSTRAP_LOOK_UP;

    request.ndr = NDR_record;
    request.name_len = (uint32_t)strlen(service_name);
    strncpy(request.name, service_name, MAX_NAME_LEN);

    /* Send request */
    printf("INFO: sending look_up request for %s\n", service_name);
    kr = mach_msg(&request.head, MACH_SEND_MSG, sizeof(request), 0,
                  MACH_PORT_NULL, MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL);

    if (kr != KERN_SUCCESS) {
        printf("FAIL: mach_msg send failed: 0x%x\n", kr);
        mach_port_deallocate(mach_task_self(), reply_port);
        return 1;
    }

    /* Receive reply */
    union {
        bootstrap_port_reply_t port_reply;
        bootstrap_error_reply_t error_reply;
        uint8_t buffer[256];
    } reply;
    memset(&reply, 0, sizeof(reply));

    kr = mach_msg(&reply.port_reply.head, MACH_RCV_MSG, 0, sizeof(reply),
                  reply_port, MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL);

    if (kr != KERN_SUCCESS) {
        printf("FAIL: mach_msg receive failed: 0x%x\n", kr);
        mach_port_deallocate(mach_task_self(), reply_port);
        return 1;
    }

    /* Check reply */
    if (reply.port_reply.head.msgh_bits & MACH_MSGH_BITS_COMPLEX) {
        printf("FAIL: look_up should have failed but returned a port\n");
        mach_port_deallocate(mach_task_self(), reply_port);
        return 1;
    } else {
        kern_return_t error = reply.error_reply.ret_code;
        printf("INFO: look_up returned error: 0x%x (expected 1102)\n", error);

        if (error == 1102) {
            printf("PASS: look_up correctly returned BOOTSTRAP_UNKNOWN_SERVICE\n");
        } else {
            printf("FAIL: unexpected error code\n");
            mach_port_deallocate(mach_task_self(), reply_port);
            return 1;
        }
    }

    mach_port_deallocate(mach_task_self(), reply_port);
    return 0;
}

int main(void) {
    printf("RosettaSim Broker Test\n");
    printf("======================\n\n");

    /* Get broker port */
    mach_port_t broker_port = get_broker_port();
    if (broker_port == MACH_PORT_NULL) {
        printf("FAIL: could not get broker port\n");
        return 1;
    }

    int failures = 0;

    /* Run tests */
    failures += test_check_in(broker_port);
    failures += test_look_up(broker_port);
    failures += test_look_up_fail(broker_port);

    /* Summary */
    printf("\n=== Test Summary ===\n");
    if (failures == 0) {
        printf("All tests PASSED\n");
        return 0;
    } else {
        printf("%d test(s) FAILED\n", failures);
        return 1;
    }
}
