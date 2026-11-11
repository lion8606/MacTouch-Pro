#ifndef VirtualDisplayBridge_h
#define VirtualDisplayBridge_h

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// Creates a 2x Retina CGVirtualDisplay with the preferred logical size (looksLikeW x looksLikeH,
/// backed by 2x pixels) plus extra 16:9 / 9:16 HiDPI modes so macOS System Settings > Displays
/// shows the full Retina resolution picker.
/// Returns the retained CGVirtualDisplay instance (as id), and writes its CGDirectDisplayID to outID.
id _Nullable MTCreateHiDPIVirtualDisplay(NSString *name,
                                         unsigned int looksLikeW,
                                         unsigned int looksLikeH,
                                         unsigned int productTag,
                                         CGDirectDisplayID *outID);

NS_ASSUME_NONNULL_END

#endif
