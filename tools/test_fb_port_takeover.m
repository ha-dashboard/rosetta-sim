/*
 * test_fb_port_takeover.m
 *
 * Test: Can we unregister the existing com.apple.framebuffer.server
 * port and re-register our own, so Simulator.app talks to us?
 *
 * Usage: ./test_fb_port_takeover <device-UDID>
 */

#import <Foundation/Foundation.h>
#import <mach/mach.h>
#import <dlfcn.h>

/* Forward-declare CoreSimulator classes we need */
@interface SimServiceContext : NSObject
+ (instancetype)sharedServiceContextForDeveloperDir:(NSString *)dir error:(NSError **)error;
- (id)defaultDeviceSetWithError:(NSError **)error;
@end

@interface SimDeviceSet : NSObject
- (NSDictionary *)devicesByUDID;
@end

@interface SimDevice : NSObject
- (NSString *)name;
- (NSString *)UDID;
- (BOOL)registerPort:(uint32_t)port service:(NSString *)service error:(NSError **)error;
- (BOOL)unregisterService:(NSString *)service error:(NSError **)error;
- (id)lookup:(NSString *)service error:(NSError **)error;
@end

static NSString *findDeveloperDir(void) {
    NSPipe *pipe = [NSPipe pipe];
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/xcode-select"];
    task.arguments = @[@"-p"];
    task.standardOutput = pipe;
    [task launch];
    [task waitUntilExit];
    NSData *data = [[pipe fileHandleForReading] readDataToEndOfFile];
    NSString *path = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return [path stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 2) {
            fprintf(stderr, "Usage: %s <device-UDID>\n", argv[0]);
            return 1;
        }
        NSString *udid = [NSString stringWithUTF8String:argv[1]];

        /* Load CoreSimulator */
        void *handle = dlopen("/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator", RTLD_LAZY);
        if (!handle) {
            fprintf(stderr, "Failed to load CoreSimulator: %s\n", dlerror());
            return 1;
        }

        NSString *devDir = findDeveloperDir();
        NSLog(@"Developer dir: %@", devDir);

        NSError *err = nil;
        SimServiceContext *ctx = [NSClassFromString(@"SimServiceContext")
            sharedServiceContextForDeveloperDir:devDir error:&err];
        if (!ctx) {
            NSLog(@"Failed to get service context: %@", err);
            return 1;
        }

        SimDeviceSet *deviceSet = [ctx defaultDeviceSetWithError:&err];
        if (!deviceSet) {
            NSLog(@"Failed to get device set: %@", err);
            return 1;
        }

        NSDictionary *devices = [deviceSet devicesByUDID];
        NSLog(@"Device set has %lu devices", (unsigned long)devices.count);
        /* Keys are NSUUID, not NSString */
        NSUUID *targetUUID = [[NSUUID alloc] initWithUUIDString:udid];
        SimDevice *device = [devices objectForKey:targetUUID];
        if (!device) {
            /* Fallback: iterate and compare string representations */
            for (id key in devices) {
                if ([[key description] caseInsensitiveCompare:udid] == NSOrderedSame) {
                    device = devices[key];
                    break;
                }
            }
        }
        if (!device) {
            NSLog(@"Device not found: %@", udid);
            return 1;
        }
        NSLog(@"Found device: %@ (%@)", [device name], udid);

        /* Step 1: Try to lookup the existing framebuffer.server service */
        NSLog(@"=== Step 1: Lookup existing com.apple.framebuffer.server ===");
        id existingPort = [device lookup:@"com.apple.framebuffer.server" error:&err];
        NSLog(@"lookup result: %@ err: %@", existingPort, err);
        err = nil;

        /* Step 2: Try to unregister the existing framebuffer.server */
        NSLog(@"=== Step 2: Unregister com.apple.framebuffer.server ===");
        BOOL ok = [device unregisterService:@"com.apple.framebuffer.server" error:&err];
        NSLog(@"unregister: ok=%d err=%@", ok, err);
        err = nil;

        /* Step 3: Allocate our own receive port */
        NSLog(@"=== Step 3: Create our Mach port ===");
        mach_port_t fbPort;
        kern_return_t kr = mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &fbPort);
        if (kr != KERN_SUCCESS) {
            NSLog(@"mach_port_allocate failed: 0x%x", kr);
            return 1;
        }
        kr = mach_port_insert_right(mach_task_self(), fbPort, fbPort, MACH_MSG_TYPE_MAKE_SEND);
        if (kr != KERN_SUCCESS) {
            NSLog(@"mach_port_insert_right failed: 0x%x", kr);
            return 1;
        }
        NSLog(@"Created port: 0x%x", fbPort);

        /* Step 4: Register our port as the new framebuffer.server */
        NSLog(@"=== Step 4: Register our port as com.apple.framebuffer.server ===");
        ok = [device registerPort:fbPort service:@"com.apple.framebuffer.server" error:&err];
        NSLog(@"register: ok=%d err=%@", ok, err);
        err = nil;

        /* Step 5: Also try the SimFramebufferServer name used by the plugin */
        NSLog(@"=== Step 5: Register as com.apple.CoreSimulator.SimFramebufferServer ===");
        mach_port_t fbPort2;
        mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &fbPort2);
        mach_port_insert_right(mach_task_self(), fbPort2, fbPort2, MACH_MSG_TYPE_MAKE_SEND);
        ok = [device registerPort:fbPort2 service:@"com.apple.CoreSimulator.SimFramebufferServer" error:&err];
        NSLog(@"register SimFramebufferServer: ok=%d err=%@", ok, err);
        err = nil;

        /* Step 6: Listen for messages on both ports */
        NSLog(@"=== Step 6: Listening for messages (10 seconds) ===");

        dispatch_source_t src1 = dispatch_source_create(DISPATCH_SOURCE_TYPE_MACH_RECV, fbPort, 0, dispatch_get_main_queue());
        dispatch_source_set_event_handler(src1, ^{
            uint8_t buf[4096];
            mach_msg_header_t *msg = (mach_msg_header_t *)buf;
            kern_return_t kr2 = mach_msg(msg, MACH_RCV_MSG, 0, sizeof(buf), fbPort, 0, 0);
            NSLog(@"[framebuffer.server] received: kr=0x%x id=0x%x size=%u remote=0x%x local=0x%x bits=0x%x",
                  kr2, msg->msgh_id, msg->msgh_size, msg->msgh_remote_port, msg->msgh_local_port, msg->msgh_bits);

            /* Hex dump first 64 bytes of payload */
            uint8_t *payload = (uint8_t *)(msg + 1);
            size_t payloadSize = msg->msgh_size > sizeof(mach_msg_header_t) ? msg->msgh_size - sizeof(mach_msg_header_t) : 0;
            if (payloadSize > 64) payloadSize = 64;
            NSMutableString *hex = [NSMutableString string];
            for (size_t i = 0; i < payloadSize; i++) {
                [hex appendFormat:@"%02x ", payload[i]];
                if ((i + 1) % 16 == 0) [hex appendString:@"\n  "];
            }
            NSLog(@"  payload (%zu bytes):\n  %@", payloadSize, hex);
        });
        dispatch_resume(src1);

        dispatch_source_t src2 = dispatch_source_create(DISPATCH_SOURCE_TYPE_MACH_RECV, fbPort2, 0, dispatch_get_main_queue());
        dispatch_source_set_event_handler(src2, ^{
            uint8_t buf[4096];
            mach_msg_header_t *msg = (mach_msg_header_t *)buf;
            kern_return_t kr2 = mach_msg(msg, MACH_RCV_MSG, 0, sizeof(buf), fbPort2, 0, 0);
            NSLog(@"[SimFramebufferServer] received: kr=0x%x id=0x%x size=%u remote=0x%x local=0x%x bits=0x%x",
                  kr2, msg->msgh_id, msg->msgh_size, msg->msgh_remote_port, msg->msgh_local_port, msg->msgh_bits);

            /* Hex dump first 64 bytes of payload */
            uint8_t *payload = (uint8_t *)(msg + 1);
            size_t payloadSize = msg->msgh_size > sizeof(mach_msg_header_t) ? msg->msgh_size - sizeof(mach_msg_header_t) : 0;
            if (payloadSize > 64) payloadSize = 64;
            NSMutableString *hex = [NSMutableString string];
            for (size_t i = 0; i < payloadSize; i++) {
                [hex appendFormat:@"%02x ", payload[i]];
                if ((i + 1) % 16 == 0) [hex appendString:@"\n  "];
            }
            NSLog(@"  payload (%zu bytes):\n  %@", payloadSize, hex);
        });
        dispatch_resume(src2);

        /* Run for 10 seconds then exit */
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            NSLog(@"=== Timeout. Cleaning up. ===");

            /* Unregister our services */
            NSError *cleanupErr = nil;
            [device unregisterService:@"com.apple.framebuffer.server" error:&cleanupErr];
            [device unregisterService:@"com.apple.CoreSimulator.SimFramebufferServer" error:&cleanupErr];

            exit(0);
        });

        dispatch_main();
    }
    return 0;
}
