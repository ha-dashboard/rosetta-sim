/*
 * LegacyFBBundleInterface.h
 *
 * Bundle-level interface for the IndigoLegacyFramebufferServices plugin.
 * Conforms to SimDeviceIOBundleInterface protocol.
 */

#import <Foundation/Foundation.h>

@protocol SimDeviceIOBundleInterface;
@protocol SimDeviceIOInterface;
@protocol SimDeviceIOPortInterface;
@protocol SimDeviceIOPortDescriptorInterface;

@interface LegacyFBBundleInterface : NSObject <SimDeviceIOBundleInterface>

@property (nonatomic, readonly) unsigned short majorVersion;
@property (nonatomic, readonly) unsigned short minorVersion;

@end
