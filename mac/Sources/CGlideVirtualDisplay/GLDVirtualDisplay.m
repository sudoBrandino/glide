#import "GLDVirtualDisplay.h"

#if !__has_feature(objc_arc)
#error "GLDVirtualDisplay.m must be compiled with ARC"
#endif

// Selector declarations only (protocols, not @interfaces of the real class names): nothing here
// references the private classes' symbols, so dyld never needs them. Signatures match the runtime
// metadata (type encodings) on macOS 14 through 27; see docs/VIRTUAL_DISPLAY.md.
@protocol GLDCGVirtualDisplayDescriptor <NSObject>
- (void)setName:(NSString *)name;
- (void)setVendorID:(unsigned int)v;
- (void)setProductID:(unsigned int)v;
- (void)setMaxPixelsWide:(unsigned int)v;
- (void)setMaxPixelsHigh:(unsigned int)v;
- (void)setSizeInMillimeters:(CGSize)size;
- (void)setQueue:(dispatch_queue_t)queue;
- (void)setTerminationHandler:(void (^)(id _Nullable, id _Nullable))handler;
@optional
- (void)setSerialNumber:(unsigned int)v;  // newer name
- (void)setSerialNum:(unsigned int)v;     // older name
@end

@protocol GLDCGVirtualDisplayMode <NSObject>
- (instancetype)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)refreshRate;
@end

@protocol GLDCGVirtualDisplaySettings <NSObject>
- (void)setModes:(NSArray *)modes;
- (void)setHiDPI:(unsigned int)hiDPI;
@end

@protocol GLDCGVirtualDisplay <NSObject>
- (nullable instancetype)initWithDescriptor:(id)descriptor;
- (BOOL)applySettings:(id)settings;
- (unsigned int)displayID;
@end

static NSString *const GLDErrorDomain = @"GlideVirtualDisplay";

static NSError *GLDError(NSInteger code, NSString *msg) {
    return [NSError errorWithDomain:GLDErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey : msg}];
}

static NSString *GLDCheckClass(NSString *name, NSArray<NSString *> *selectors) {
    Class cls = NSClassFromString(name);
    if (!cls) return [NSString stringWithFormat:@"%@ is not present in this macOS", name];
    for (NSString *s in selectors) {
        if (![cls instancesRespondToSelector:NSSelectorFromString(s)])
            return [NSString stringWithFormat:@"%@ does not respond to -%@", name, s];
    }
    return nil;
}

@implementation GLDVirtualDisplay {
    id<GLDCGVirtualDisplay> _display;
}

+ (NSString *)unavailableReason {
    static NSString *reason;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *r = GLDCheckClass(@"CGVirtualDisplayDescriptor", @[
            @"setName:", @"setVendorID:", @"setProductID:", @"setMaxPixelsWide:", @"setMaxPixelsHigh:",
            @"setSizeInMillimeters:", @"setQueue:", @"setTerminationHandler:"
        ]);
        if (!r) {
            Class d = NSClassFromString(@"CGVirtualDisplayDescriptor");
            if (![d instancesRespondToSelector:@selector(setSerialNumber:)] && ![d instancesRespondToSelector:@selector(setSerialNum:)])
                r = @"CGVirtualDisplayDescriptor has no serial number setter";
        }
        if (!r) r = GLDCheckClass(@"CGVirtualDisplayMode", @[ @"initWithWidth:height:refreshRate:" ]);
        if (!r) r = GLDCheckClass(@"CGVirtualDisplaySettings", @[ @"setModes:", @"setHiDPI:" ]);
        if (!r) r = GLDCheckClass(@"CGVirtualDisplay", @[ @"initWithDescriptor:", @"applySettings:", @"displayID" ]);
        reason = r;
    });
    return reason;
}

- (instancetype)initWithName:(NSString *)name
                    vendorID:(uint32_t)vendorID
                   productID:(uint32_t)productID
                serialNumber:(uint32_t)serialNumber
               maxPixelsWide:(uint32_t)maxPixelsWide
               maxPixelsHigh:(uint32_t)maxPixelsHigh
           sizeInMillimeters:(CGSize)sizeInMillimeters
                       queue:(dispatch_queue_t)queue
                 onTerminate:(void (^)(void))onTerminate
                       error:(NSError **)error {
    NSString *why = [GLDVirtualDisplay unavailableReason];
    if (why) {
        if (error) *error = GLDError(1, why);
        return nil;
    }
    if (!(self = [super init])) return nil;
    @try {
        id<GLDCGVirtualDisplayDescriptor> desc = [[NSClassFromString(@"CGVirtualDisplayDescriptor") alloc] init];
        if (!desc) {
            if (error) *error = GLDError(2, @"CGVirtualDisplayDescriptor init returned nil");
            return nil;
        }
        [desc setName:name];
        [desc setVendorID:vendorID];
        [desc setProductID:productID];
        if ([desc respondsToSelector:@selector(setSerialNumber:)]) [desc setSerialNumber:serialNumber];
        else [desc setSerialNum:serialNumber];
        [desc setMaxPixelsWide:maxPixelsWide];
        [desc setMaxPixelsHigh:maxPixelsHigh];
        [desc setSizeInMillimeters:sizeInMillimeters];
        [desc setQueue:queue];
        void (^term)(void) = [onTerminate copy];
        [desc setTerminationHandler:^(id _Nullable a, id _Nullable b) {
            (void)a; (void)b;
            if (term) term();
        }];
        _display = [[NSClassFromString(@"CGVirtualDisplay") alloc] initWithDescriptor:desc];
    } @catch (NSException *e) {
        if (error) *error = GLDError(3, [NSString stringWithFormat:@"CGVirtualDisplay threw %@: %@", e.name, e.reason]);
        _display = nil;
    }
    if (!_display) {
        if (error && !*error) *error = GLDError(4, @"WindowServer refused the virtual display (initWithDescriptor: returned nil)");
        return nil;
    }
    if (_display.displayID == 0) {
        if (error) *error = GLDError(5, @"virtual display has no display ID");
        _display = nil;
        return nil;
    }
    _maxPixelsWide = maxPixelsWide;
    _maxPixelsHigh = maxPixelsHigh;
    return self;
}

- (CGDirectDisplayID)displayID {
    return _display ? (CGDirectDisplayID)_display.displayID : 0;
}

- (BOOL)applyModeWidth:(uint32_t)width
                height:(uint32_t)height
           refreshRate:(double)refreshRate
                 hiDPI:(BOOL)hiDPI
                 error:(NSError **)error {
    if (!_display) {
        if (error) *error = GLDError(6, @"virtual display was already removed");
        return NO;
    }
    @try {
        id<GLDCGVirtualDisplayMode> mode = [[NSClassFromString(@"CGVirtualDisplayMode") alloc] initWithWidth:width height:height refreshRate:refreshRate];
        id<GLDCGVirtualDisplaySettings> settings = [[NSClassFromString(@"CGVirtualDisplaySettings") alloc] init];
        if (!mode || !settings) {
            if (error) *error = GLDError(7, @"could not build CGVirtualDisplaySettings");
            return NO;
        }
        [settings setModes:@[ mode ]];
        [settings setHiDPI:hiDPI ? 1 : 0];
        if (![_display applySettings:settings]) {
            if (error) *error = GLDError(8, [NSString stringWithFormat:@"applySettings: refused %ux%u @ %.0f Hz%@", width, height, refreshRate, hiDPI ? @" HiDPI" : @""]);
            return NO;
        }
        return YES;
    } @catch (NSException *e) {
        if (error) *error = GLDError(9, [NSString stringWithFormat:@"applySettings: threw %@: %@", e.name, e.reason]);
        return NO;
    }
}

- (void)invalidate {
    _display = nil;
}

@end
