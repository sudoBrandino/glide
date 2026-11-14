// A thin, fail-safe wrapper around CoreGraphics' private CGVirtualDisplay classes
// (docs/VIRTUAL_DISPLAY.md). The private classes are looked up at runtime with
// NSClassFromString and every selector is checked before use, so the binary links no private
// symbols: if a future macOS removes or changes them, +unavailableReason says why and Glide falls
// back to the physical display instead of failing to launch.
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface GLDVirtualDisplay : NSObject

/// nil when the private API looks usable; otherwise a human-readable reason.
+ (nullable NSString *)unavailableReason;

/// Creates the display. It exists until -invalidate or until this object is deallocated (and
/// always disappears when the process exits). `onTerminate` runs on `queue` if the system ends it.
- (nullable instancetype)initWithName:(NSString *)name
                             vendorID:(uint32_t)vendorID
                            productID:(uint32_t)productID
                         serialNumber:(uint32_t)serialNumber
                        maxPixelsWide:(uint32_t)maxPixelsWide
                        maxPixelsHigh:(uint32_t)maxPixelsHigh
                    sizeInMillimeters:(CGSize)sizeInMillimeters
                                queue:(dispatch_queue_t)queue
                          onTerminate:(nullable void (^)(void))onTerminate
                                error:(NSError **)error NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// 0 after -invalidate.
@property(nonatomic, readonly) CGDirectDisplayID displayID;
@property(nonatomic, readonly) uint32_t maxPixelsWide;
@property(nonatomic, readonly) uint32_t maxPixelsHigh;

/// Replaces the display's mode list with a single mode (points when hiDPI, else pixels).
- (BOOL)applyModeWidth:(uint32_t)width
                height:(uint32_t)height
           refreshRate:(double)refreshRate
                 hiDPI:(BOOL)hiDPI
                 error:(NSError **)error NS_SWIFT_NAME(applyMode(width:height:refreshRate:hiDPI:));

/// Releases the CoreGraphics object, which removes the display (asynchronously). Idempotent.
- (void)invalidate;

@end

NS_ASSUME_NONNULL_END
