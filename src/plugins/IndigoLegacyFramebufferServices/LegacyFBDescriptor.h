/*
 * LegacyFBDescriptor.h
 *
 * Port descriptor for the legacy framebuffer service.
 * Subclasses SimDeviceIOPortDescriptor, conforms to SimDeviceIOPortDescriptorInterface.
 *
 * Registers "com.apple.CoreSimulator.SimFramebufferServer" Mach service
 * and handles connections from the sim-side SimFramebuffer client (backboardd).
 */

#import <Foundation/Foundation.h>
#import <IOSurface/IOSurface.h>

/*
 * Forward-declare CoreSimDeviceIO classes we link against.
 * These are defined in CoreSimDeviceIO.framework.
 */
@class SimMachPort;

@protocol SimDeviceIOInterface;
@protocol SimDeviceIOPortDescriptorState;

@interface LegacyFBDescriptor : NSObject

@property (nonatomic, strong) NSString *serviceName;
@property (nonatomic, strong) SimMachPort *servicePort;
@property (nonatomic, strong) dispatch_queue_t receiveQueue;
@property (nonatomic, strong) dispatch_source_t receiveSource;
@property (nonatomic, assign) IOSurfaceRef framebufferSurface;

- (instancetype)initWithDevice:(id)device error:(NSError **)error;

/* Display configuration — defaults for iPhone 6 (750x1334 @2x) */
@property (nonatomic, assign) uint32_t displayWidth;
@property (nonatomic, assign) uint32_t displayHeight;
@property (nonatomic, assign) uint32_t displayScale;

@end
