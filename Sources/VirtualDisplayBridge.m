#import "VirtualDisplayBridge.h"

@interface CGVirtualDisplaySettings : NSObject
@property (retain, nonatomic) NSArray *modes;
@property (nonatomic) unsigned int hiDPI;
@end

@interface CGVirtualDisplayDescriptor : NSObject
@property (retain, nonatomic) dispatch_queue_t queue;
@property (retain, nonatomic) NSString *name;
@property (nonatomic) CGSize sizeInMillimeters;
@property (nonatomic) unsigned int maxPixelsWide;
@property (nonatomic) unsigned int maxPixelsHigh;
@property (nonatomic) CGPoint redPrimary;
@property (nonatomic) CGPoint greenPrimary;
@property (nonatomic) CGPoint bluePrimary;
@property (nonatomic) CGPoint whitePoint;
@property (copy, nonatomic) void (^terminationHandler)(id, id);
@property (nonatomic) unsigned int serialNum;
@property (nonatomic) unsigned int productID;
@property (nonatomic) unsigned int vendorID;
@end

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(unsigned int)width
                       height:(unsigned int)height
                  refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplay : NSObject
@property (readonly, nonatomic) unsigned int displayID;
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@end

id _Nullable MTCreateHiDPIVirtualDisplay(NSString *name,
                                         unsigned int looksLikeW,
                                         unsigned int looksLikeH,
                                         unsigned int productTag,
                                         CGDirectDisplayID *outID) {
    Class descCls = NSClassFromString(@"CGVirtualDisplayDescriptor");
    Class vdCls   = NSClassFromString(@"CGVirtualDisplay");
    Class setCls  = NSClassFromString(@"CGVirtualDisplaySettings");
    Class modeCls = NSClassFromString(@"CGVirtualDisplayMode");
    if (!descCls || !vdCls || !setCls || !modeCls) return nil;

    BOOL portrait = looksLikeH > looksLikeW;
    unsigned int prefW = looksLikeW * 2, prefH = looksLikeH * 2;
    CGVirtualDisplayDescriptor *desc = [[descCls alloc] init];
    desc.name = name;
    desc.queue = dispatch_get_main_queue();
    desc.sizeInMillimeters = portrait ? CGSizeMake(336.0, 597.0) : CGSizeMake(597.0, 336.0);
    desc.maxPixelsWide = portrait ? 2880 : 5120;
    desc.maxPixelsHigh = portrait ? 5120 : 2880;
    desc.redPrimary   = CGPointMake(0.680, 0.320);
    desc.greenPrimary = CGPointMake(0.265, 0.690);
    desc.bluePrimary  = CGPointMake(0.150, 0.060);
    desc.whitePoint   = CGPointMake(0.3127, 0.3290);
    desc.vendorID  = 0xB33F;
    desc.productID = 0x7200 + (productTag & 0x0FFF);
    desc.serialNum = 1;

    CGVirtualDisplay *vd = [[vdCls alloc] initWithDescriptor:desc];
    if (!vd) return nil;

    CGVirtualDisplaySettings *settings = [[setCls alloc] init];
    settings.hiDPI = 1;

    // Register BOTH 2x framebuffer modes AND their 1x logical counterparts so macOS WindowServer
    // synthesizes every preset as a native Usable-For-Desktop-GUI Retina HiDPI mode, enabling live
    // zero-flicker resolution switching via both MacTouch AND macOS System Settings > Displays.
    NSMutableArray *modes = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    void (^addMode)(unsigned int, unsigned int) = ^(unsigned int w, unsigned int h) {
        NSString *key = [NSString stringWithFormat:@"%ux%u", w, h];
        if (![seen containsObject:key]) {
            [seen addObject:key];
            [modes addObject:[[modeCls alloc] initWithWidth:w height:h refreshRate:60.0]];
        }
    };

    addMode(prefW, prefH);
    addMode(looksLikeW, looksLikeH);

    if (portrait) {
        unsigned int pairs[][2] = {
            {2880, 5120}, {1440, 2560},
            {2304, 4096}, {1152, 2048},
            {2160, 3840}, {1080, 1920},
            {1800, 3200}, {900, 1600},
            {1620, 2880}, {810, 1440},
            {1440, 2560}, {720, 1280}
        };
        for (size_t i = 0; i < sizeof(pairs) / sizeof(pairs[0]); i++) {
            addMode(pairs[i][0], pairs[i][1]);
        }
    } else {
        unsigned int pairs[][2] = {
            {5120, 2880}, {2560, 1440},
            {4608, 2592}, {2304, 1296},
            {4096, 2304}, {2048, 1152},
            {3840, 2160}, {1920, 1080},
            {3360, 1890}, {1680, 945},
            {3200, 1800}, {1600, 900},
            {2880, 1620}, {1440, 810},
            {2560, 1440}, {1280, 720}
        };
        for (size_t i = 0; i < sizeof(pairs) / sizeof(pairs[0]); i++) {
            addMode(pairs[i][0], pairs[i][1]);
        }
    }
    settings.modes = modes;
    if (![vd applySettings:settings]) return nil;
    if (outID) *outID = vd.displayID;
    return vd;
}
