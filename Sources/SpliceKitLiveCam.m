#import "SpliceKitLiveCam.h"
#import "SpliceKit.h"
#import <AppKit/AppKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <QuartzCore/QuartzCore.h>
#import <Vision/Vision.h>
#import <VideoToolbox/VideoToolbox.h>
#import <CoreVideo/CoreVideo.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <mach/mach.h>
#import <mach/mach_time.h>

extern NSDictionary *SpliceKit_handleRequest(NSDictionary *request);

#if defined(__x86_64__)
#define SPLICEKIT_LIVECAM_STRET_MSG objc_msgSend_stret
#else
#define SPLICEKIT_LIVECAM_STRET_MSG objc_msgSend
#endif

NSString * const SpliceKitLiveCamVisibilityDidChangeNotification =
    @"SpliceKitLiveCamVisibilityDidChangeNotification";

static NSString * const kLiveCamVideoDeviceKey = @"SpliceKitLiveCam.VideoDevice";
static NSString * const kLiveCamAudioDeviceKey = @"SpliceKitLiveCam.AudioDevice";
static NSString * const kLiveCamNoMicrophoneIdentifier = @"__splicekit_livecam_no_microphone__";
static NSString * const kLiveCamResolutionKey = @"SpliceKitLiveCam.Resolution";
static NSString * const kLiveCamFrameRateKey = @"SpliceKitLiveCam.FrameRate";
static NSString * const kLiveCamQualityKey = @"SpliceKitLiveCam.Quality";
static NSString * const kLiveCamPresetKey = @"SpliceKitLiveCam.Preset";
static NSString * const kLiveCamMirrorKey = @"SpliceKitLiveCam.Mirror";
static NSString * const kLiveCamMuteKey = @"SpliceKitLiveCam.Mute";
static NSString * const kLiveCamDestinationKey = @"SpliceKitLiveCam.Destination";
static NSString * const kLiveCamPlacementKey = @"SpliceKitLiveCam.Placement";
static NSString * const kLiveCamClipNameKey = @"SpliceKitLiveCam.ClipName";
static NSString * const kLiveCamEventNameKey = @"SpliceKitLiveCam.EventName";
static NSString * const kLiveCamIntensityKey = @"SpliceKitLiveCam.Intensity";
static NSString * const kLiveCamExposureKey = @"SpliceKitLiveCam.Exposure";
static NSString * const kLiveCamContrastKey = @"SpliceKitLiveCam.Contrast";
static NSString * const kLiveCamSaturationKey = @"SpliceKitLiveCam.Saturation";
static NSString * const kLiveCamTemperatureKey = @"SpliceKitLiveCam.Temperature";
static NSString * const kLiveCamSharpnessKey = @"SpliceKitLiveCam.Sharpness";
static NSString * const kLiveCamGlowKey = @"SpliceKitLiveCam.Glow";
static NSString * const kLiveCamTimestampOverlayKey = @"SpliceKitLiveCam.TimestampOverlay";
static NSString * const kLiveCamBackgroundModeKey = @"SpliceKitLiveCam.BackgroundMode";
static NSString * const kLiveCamBackgroundColorKey = @"SpliceKitLiveCam.BackgroundColor";
static NSString * const kLiveCamBackgroundEdgeSoftnessKey = @"SpliceKitLiveCam.BackgroundEdgeSoftness";
static NSString * const kLiveCamBackgroundRefinementKey = @"SpliceKitLiveCam.BackgroundRefinement";
static NSString * const kLiveCamBackgroundChokeKey = @"SpliceKitLiveCam.BackgroundChoke";
static NSString * const kLiveCamBackgroundSpillKey = @"SpliceKitLiveCam.BackgroundSpill";
static NSString * const kLiveCamBackgroundWrapKey = @"SpliceKitLiveCam.BackgroundWrap";
static NSString * const kLiveCamBackgroundQualityKey = @"SpliceKitLiveCam.BackgroundQuality";
static NSString * const kLiveCamAdvancedVisibleKey = @"SpliceKitLiveCam.AdvancedVisible";

typedef NS_ENUM(NSInteger, SpliceKitLiveCamDestination) {
    SpliceKitLiveCamDestinationLibrary = 0,
    SpliceKitLiveCamDestinationTimeline = 1,
};

// Flipped NSView used as the documentView for the Advanced controls scroll
// view so the clip view shows the top of the stack first (NSStackView is
// unflipped by default, which makes NSScrollView's initial bounds origin
// sit at the bottom-left of the content).
@interface SpliceKitLiveCamFlippedView : NSView
@end
@implementation SpliceKitLiveCamFlippedView
- (BOOL)isFlipped { return YES; }
@end

// Compact broadcast-style input meter for the LiveCam audio card. The old
// NSLevelIndicator was only 12 points tall and mapped linear RMS to an
// arbitrary 0-100 range, so it was easy to miss and gave no useful headroom
// information. This view uses the standard dBFS scale, keeps a short peak hold,
// and makes clipping visible without taking over the compact four-card layout.
@interface SpliceKitLiveCamAudioMeterView : NSView
@property (nonatomic, assign) double rmsDB;
@property (nonatomic, assign) double peakDB;
@property (nonatomic, assign) double heldPeakDB;
@property (nonatomic, assign) NSTimeInterval peakHoldUntil;
@property (nonatomic, assign) NSTimeInterval clipHoldUntil;
- (void)updateWithRMSDB:(double)rmsDB peakDB:(double)peakDB;
- (void)reset;
@end

@implementation SpliceKitLiveCamAudioMeterView

static double SpliceKitLiveCamMeterClampedDB(double value) {
    if (!isfinite(value)) return -60.0;
    return MIN(0.0, MAX(-60.0, value));
}

static CGFloat SpliceKitLiveCamMeterPosition(double value) {
    return (CGFloat)((SpliceKitLiveCamMeterClampedDB(value) + 60.0) / 60.0);
}

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (!self) return nil;
    _rmsDB = -60.0;
    _peakDB = -60.0;
    _heldPeakDB = -60.0;
    self.toolTip = @"Live microphone level in dBFS. Keep peaks out of the red to avoid clipping.";
    [self setAccessibilityElement:YES];
    [self setAccessibilityRole:NSAccessibilityLevelIndicatorRole];
    [self setAccessibilityLabel:@"Audio monitor"];
    return self;
}

- (NSSize)intrinsicContentSize {
    return NSMakeSize(168.0, 46.0);
}

- (void)updateWithRMSDB:(double)rmsDB peakDB:(double)peakDB {
    self.rmsDB = SpliceKitLiveCamMeterClampedDB(rmsDB);
    self.peakDB = SpliceKitLiveCamMeterClampedDB(peakDB);

    NSTimeInterval now = CACurrentMediaTime();
    if (self.peakDB >= self.heldPeakDB) {
        self.heldPeakDB = self.peakDB;
        self.peakHoldUntil = now + 0.8;
    } else if (now > self.peakHoldUntil) {
        self.heldPeakDB = MAX(self.peakDB, self.heldPeakDB - 2.0);
    }
    if (self.peakDB >= -0.5) {
        self.clipHoldUntil = now + 1.5;
    }

    NSString *accessibilityValue = self.peakDB <= -59.5
        ? @"No signal"
        : [NSString stringWithFormat:@"Peak %.0f decibels full scale", self.peakDB];
    [self setAccessibilityValue:accessibilityValue];
    [self setNeedsDisplay:YES];
}

- (void)reset {
    self.rmsDB = -60.0;
    self.peakDB = -60.0;
    self.heldPeakDB = -60.0;
    self.peakHoldUntil = 0.0;
    self.clipHoldUntil = 0.0;
    [self setAccessibilityValue:@"No signal"];
    [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];

    NSRect bounds = self.bounds;
    NSRect track = NSMakeRect(1.0, 14.0, MAX(1.0, NSWidth(bounds) - 2.0), 10.0);
    NSBezierPath *trackPath = [NSBezierPath bezierPathWithRoundedRect:track
                                                             xRadius:3.0
                                                             yRadius:3.0];
    [[NSColor colorWithWhite:0.04 alpha:0.88] setFill];
    [trackPath fill];

    NSArray<NSColor *> *zoneColors = @[
        [NSColor colorWithRed:0.20 green:0.82 blue:0.42 alpha:1.0],
        [NSColor colorWithRed:0.96 green:0.73 blue:0.18 alpha:1.0],
        [NSColor colorWithRed:0.96 green:0.25 blue:0.23 alpha:1.0],
    ];
    const double zoneStarts[] = { -60.0, -12.0, -3.0 };
    const double zoneEnds[] = { -12.0, -3.0, 0.0 };

    [NSGraphicsContext saveGraphicsState];
    [trackPath addClip];
    for (NSUInteger i = 0; i < 3; i++) {
        CGFloat startX = NSMinX(track) + NSWidth(track) * SpliceKitLiveCamMeterPosition(zoneStarts[i]);
        CGFloat endX = NSMinX(track) + NSWidth(track) * SpliceKitLiveCamMeterPosition(zoneEnds[i]);
        [[zoneColors[i] colorWithAlphaComponent:0.18] setFill];
        NSRectFill(NSMakeRect(startX, NSMinY(track), MAX(0.0, endX - startX), NSHeight(track)));
    }

    CGFloat activeWidth = NSWidth(track) * SpliceKitLiveCamMeterPosition(self.rmsDB);
    [[NSBezierPath bezierPathWithRect:NSMakeRect(NSMinX(track),
                                                 NSMinY(track),
                                                 activeWidth,
                                                 NSHeight(track))] addClip];
    for (NSUInteger i = 0; i < 3; i++) {
        CGFloat startX = NSMinX(track) + NSWidth(track) * SpliceKitLiveCamMeterPosition(zoneStarts[i]);
        CGFloat endX = NSMinX(track) + NSWidth(track) * SpliceKitLiveCamMeterPosition(zoneEnds[i]);
        [zoneColors[i] setFill];
        NSRectFill(NSMakeRect(startX, NSMinY(track), MAX(0.0, endX - startX), NSHeight(track)));
    }
    [NSGraphicsContext restoreGraphicsState];

    if (self.heldPeakDB > -59.5) {
        CGFloat peakX = NSMinX(track) + NSWidth(track) * SpliceKitLiveCamMeterPosition(self.heldPeakDB);
        NSBezierPath *peakLine = [NSBezierPath bezierPath];
        [peakLine moveToPoint:NSMakePoint(peakX, NSMinY(track) + 1.0)];
        [peakLine lineToPoint:NSMakePoint(peakX, NSMaxY(track) - 1.0)];
        peakLine.lineWidth = 1.5;
        [[NSColor colorWithWhite:1.0 alpha:0.95] setStroke];
        [peakLine stroke];
    }

    NSDictionary *headerAttributes = @{
        NSFontAttributeName: [NSFont systemFontOfSize:9.0 weight:NSFontWeightSemibold],
        NSForegroundColorAttributeName: [NSColor secondaryLabelColor],
        NSKernAttributeName: @(0.8),
    };
    [@"MONITOR" drawAtPoint:NSMakePoint(1.0, 30.0) withAttributes:headerAttributes];

    BOOL clipping = CACurrentMediaTime() < self.clipHoldUntil;
    NSString *readout = clipping
        ? @"CLIP"
        : (self.peakDB <= -59.5
            ? @"−∞ dBFS"
            : [NSString stringWithFormat:@"%.0f dBFS", self.peakDB]);
    NSDictionary *readoutAttributes = @{
        NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:9.0 weight:NSFontWeightSemibold],
        NSForegroundColorAttributeName: clipping ? [NSColor systemRedColor] : [NSColor secondaryLabelColor],
    };
    NSSize readoutSize = [readout sizeWithAttributes:readoutAttributes];
    [readout drawAtPoint:NSMakePoint(MAX(1.0, NSMaxX(bounds) - readoutSize.width - 1.0), 30.0)
          withAttributes:readoutAttributes];

    NSDictionary *tickAttributes = @{
        NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:7.5 weight:NSFontWeightRegular],
        NSForegroundColorAttributeName: [NSColor tertiaryLabelColor],
    };
    NSArray<NSNumber *> *ticks = @[@(-48), @(-24), @(-12), @(-6), @(0)];
    for (NSNumber *tick in ticks) {
        NSString *label = tick.stringValue;
        NSSize labelSize = [label sizeWithAttributes:tickAttributes];
        CGFloat centerX = NSMinX(track) + NSWidth(track) * SpliceKitLiveCamMeterPosition(tick.doubleValue);
        CGFloat labelX = MIN(NSMaxX(bounds) - labelSize.width,
                             MAX(NSMinX(bounds), centerX - labelSize.width * 0.5));
        [label drawAtPoint:NSMakePoint(labelX, 1.0) withAttributes:tickAttributes];
    }
}

@end

typedef NS_ENUM(NSInteger, SpliceKitLiveCamTimelinePlacement) {
    SpliceKitLiveCamTimelinePlacementAppend = 0,
    SpliceKitLiveCamTimelinePlacementInsertAtPlayhead = 1,
    SpliceKitLiveCamTimelinePlacementConnectedAbove = 2,
};

typedef NS_ENUM(NSInteger, SpliceKitLiveCamBackgroundMode) {
    SpliceKitLiveCamBackgroundModeNone = 0,
    SpliceKitLiveCamBackgroundModeSystemBlur = 1,
    SpliceKitLiveCamBackgroundModeGreenScreen = 2,
};

@interface SpliceKitLiveCamPreset : NSObject
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *category;
@property (nonatomic, copy) NSString *summary;
@property (nonatomic, assign) BOOL premium;
+ (instancetype)presetWithIdentifier:(NSString *)identifier
                                name:(NSString *)name
                            category:(NSString *)category
                             summary:(NSString *)summary
                             premium:(BOOL)premium;
@end

@implementation SpliceKitLiveCamPreset

+ (instancetype)presetWithIdentifier:(NSString *)identifier
                                name:(NSString *)name
                            category:(NSString *)category
                             summary:(NSString *)summary
                             premium:(BOOL)premium {
    SpliceKitLiveCamPreset *preset = [[self alloc] init];
    preset.identifier = identifier ?: @"clean";
    preset.name = name ?: @"Clean";
    preset.category = category ?: @"Clean";
    preset.summary = summary ?: @"";
    preset.premium = premium;
    return preset;
}

@end

@interface SpliceKitLiveCamAdjustmentState : NSObject <NSCopying>
@property (nonatomic, assign) CGFloat intensity;
@property (nonatomic, assign) CGFloat exposure;
@property (nonatomic, assign) CGFloat contrast;
@property (nonatomic, assign) CGFloat saturation;
@property (nonatomic, assign) CGFloat temperature;
@property (nonatomic, assign) CGFloat sharpness;
@property (nonatomic, assign) CGFloat glow;
@end

@implementation SpliceKitLiveCamAdjustmentState

- (id)copyWithZone:(NSZone *)zone {
    SpliceKitLiveCamAdjustmentState *copy = [[[self class] allocWithZone:zone] init];
    copy.intensity = self.intensity;
    copy.exposure = self.exposure;
    copy.contrast = self.contrast;
    copy.saturation = self.saturation;
    copy.temperature = self.temperature;
    copy.sharpness = self.sharpness;
    copy.glow = self.glow;
    return copy;
}

@end

static NSString * const kSpliceKitLiveCamMetalSource =
@"#include <CoreImage/CoreImage.h>\n"
@"using namespace metal;\n"
@"extern \"C\" { namespace coreimage {\n"
@"[[ stitchable ]] float2 vhsWarp(coreimage::destination dest, float time, float amount) {\n"
@"    float2 c = dest.coord();\n"
@"    float wobble = sin(c.y * 0.028 + time * 6.0) * amount * 18.0;\n"
@"    float jitter = sin(c.y * 0.19 + time * 31.0) * amount * 3.5;\n"
@"    return float2(c.x + wobble + jitter, c.y);\n"
@"}\n"
@"[[ stitchable ]] float2 liquidWarp(coreimage::destination dest, float time, float amount) {\n"
@"    float2 c = dest.coord();\n"
@"    float x = sin(c.y * 0.032 + time * 1.8) * amount * 28.0;\n"
@"    float y = cos(c.x * 0.024 + time * 1.3) * amount * 20.0;\n"
@"    return float2(c.x + x, c.y + y);\n"
@"}\n"
@"[[ stitchable ]] half4 rgbSplit(coreimage::sampler_h image, float dx, float dy) {\n"
@"    float2 c = image.coord();\n"
@"    half4 base = image.sample(c);\n"
@"    half4 red = image.sample(c + float2(dx, dy));\n"
@"    half4 blue = image.sample(c - float2(dx, dy));\n"
@"    return half4(red.r, base.g, blue.b, base.a);\n"
@"}\n"
@"[[ stitchable ]] half4 glitch(coreimage::sampler_h image, float time, float amount) {\n"
@"    float2 c = image.coord();\n"
@"    float band = floor(c.y / 18.0);\n"
@"    float shift = sin(band * 12.7 + time * 24.0) * amount * 36.0;\n"
@"    half4 color = image.sample(c + float2(shift, 0.0));\n"
@"    float swap = fract(band * 0.071 + time * 0.9);\n"
@"    if (swap > 0.84) {\n"
@"        color.rgb = color.bgr;\n"
@"    }\n"
@"    return color;\n"
@"}\n"
@"[[ stitchable ]] half4 thermal(coreimage::sampler_h image) {\n"
@"    float2 c = image.coord();\n"
@"    half4 color = image.sample(c);\n"
@"    half luma = dot(color.rgb, half3(0.299h, 0.587h, 0.114h));\n"
@"    half3 cold = half3(0.04h, 0.10h, 0.50h);\n"
@"    half3 mid = half3(1.0h, 0.48h, 0.02h);\n"
@"    half3 hot = half3(1.0h, 0.96h, 0.62h);\n"
@"    half3 palette = mix(cold, mid, smoothstep(0.12h, 0.58h, luma));\n"
@"    palette = mix(palette, hot, smoothstep(0.56h, 1.0h, luma));\n"
@"    return half4(palette, color.a);\n"
@"}\n"
@"[[ stitchable ]] half4 scanline(coreimage::sampler_h image, float strength, float time) {\n"
@"    float2 c = image.coord();\n"
@"    half4 color = image.sample(c);\n"
@"    float line = 0.62 + 0.38 * sin(c.y * 3.14159 + time * 3.0);\n"
@"    float flicker = 0.96 + 0.04 * sin(time * 21.0);\n"
@"    color.rgb *= half3(mix(1.0, line * flicker, strength));\n"
@"    return color;\n"
@"}\n"
@"[[ stitchable ]] float2 bulgeWarp(coreimage::destination dest, float amount, float width, float height) {\n"
@"    float2 c = dest.coord();\n"
@"    float2 center = float2(width * 0.5, height * 0.5);\n"
@"    float2 delta = c - center;\n"
@"    float radius = length(delta) / max(width, height);\n"
@"    float pull = 1.0 - amount * smoothstep(0.0, 0.8, radius);\n"
@"    return center + delta * pull;\n"
@"}\n"
@"// Joint bilateral mask refinement: re-weights mask samples by RGB similarity to the\n"
@"// guide pixel so the alpha boundary snaps to color edges in the source image.\n"
@"[[ stitchable ]] half4 maskRefine(coreimage::sampler_h mask, coreimage::sampler_h guide, float radius, float colorSigma) {\n"
@"    float2 mc = mask.coord();\n"
@"    float2 gc = guide.coord();\n"
@"    half3 centerRGB = guide.sample(gc).rgb;\n"
@"    half centerA = mask.sample(mc).r;\n"
@"    float invSigma = 1.0 / max(colorSigma * colorSigma, 1e-4);\n"
@"    float wSum = 0.0;\n"
@"    float aSum = 0.0;\n"
@"    for (int dy = -1; dy <= 1; dy++) {\n"
@"        for (int dx = -1; dx <= 1; dx++) {\n"
@"            float2 off = float2(float(dx), float(dy)) * radius;\n"
@"            half3 sRGB = guide.sample(gc + off).rgb;\n"
@"            half sA = mask.sample(mc + off).r;\n"
@"            half3 d = sRGB - centerRGB;\n"
@"            float colorD = float(dot(d, d));\n"
@"            float spatialD = float(dx * dx + dy * dy) * 0.18;\n"
@"            float w = exp(-(colorD * invSigma) - spatialD);\n"
@"            wSum += w;\n"
@"            aSum += w * float(sA);\n"
@"        }\n"
@"    }\n"
@"    half refined = (wSum > 1e-6) ? half(aSum / wSum) : centerA;\n"
@"    return half4(refined, refined, refined, 1.0h);\n"
@"}\n"
@"// Signed morphological op: positive = erode (shrink mask, kills halo);\n"
@"// negative = dilate (grow mask). Output is mixed with original by amount magnitude.\n"
@"[[ stitchable ]] half4 maskChoke(coreimage::sampler_h mask, float amount) {\n"
@"    float2 c = mask.coord();\n"
@"    float radius = abs(amount) * 6.0;\n"
@"    half center = mask.sample(c).r;\n"
@"    half acc = center;\n"
@"    for (int i = 0; i < 8; i++) {\n"
@"        float a = float(i) * 0.7853981633974483;\n"
@"        float2 o = float2(cos(a), sin(a)) * radius;\n"
@"        half s = mask.sample(c + o).r;\n"
@"        acc = (amount >= 0.0) ? min(acc, s) : max(acc, s);\n"
@"    }\n"
@"    return half4(acc, acc, acc, 1.0h);\n"
@"}\n"
@"// Spill suppression: at partial-alpha edge pixels, desaturate toward luma. Removes\n"
@"// color cast (e.g. green/blue room light bleeding into hair) so the comp reads clean.\n"
@"[[ stitchable ]] half4 spillSuppress(coreimage::sampler_h image, coreimage::sampler_h mask, float amount) {\n"
@"    half4 c = image.sample(image.coord());\n"
@"    half a = mask.sample(mask.coord()).r;\n"
@"    half edgeWeight = clamp(4.0h * a * (1.0h - a), 0.0h, 1.0h);\n"
@"    half luma = dot(c.rgb, half3(0.2126h, 0.7152h, 0.0722h));\n"
@"    half3 desat = mix(c.rgb, half3(luma), half(amount) * edgeWeight);\n"
@"    return half4(desat, c.a);\n"
@"}\n"
@"// Light wrap: bleed background color into the subject edge so the composite picks\n"
@"// up ambient color from the new background. Sells the cut on solid-color keys.\n"
@"[[ stitchable ]] half4 lightWrap(coreimage::sampler_h image, coreimage::sampler_h mask, coreimage::sampler_h background, float amount) {\n"
@"    half4 c = image.sample(image.coord());\n"
@"    half4 b = background.sample(background.coord());\n"
@"    half a = mask.sample(mask.coord()).r;\n"
@"    half wrapBand = smoothstep(0.55h, 0.95h, a) * (1.0h - smoothstep(0.95h, 1.0h, a));\n"
@"    half3 wrapped = c.rgb + b.rgb * wrapBand * half(amount);\n"
@"    return half4(min(wrapped, half3(1.0h)), c.a);\n"
@"}\n"
@"// Temporal EMA: blend previous and current mask. Kills per-frame Vision flicker.\n"
@"[[ stitchable ]] half4 maskTemporalBlend(coreimage::sampler_h current, coreimage::sampler_h previous, float factor) {\n"
@"    half a = mix(current.sample(current.coord()).r, previous.sample(previous.coord()).r, half(factor));\n"
@"    return half4(a, a, a, 1.0h);\n"
@"}\n"
@"} }\n";

static NSString *SpliceKitLiveCamString(id value) {
    return [value isKindOfClass:[NSString class]] ? value : @"";
}

// Resident memory footprint of the current process in MB. Used by perf logging
// to surface mask-chain accumulation (which isn't heap-allocated itself but
// keeps CIContext intermediates + Metal textures resident).
static double SpliceKitLiveCamResidentMB(void) {
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    kern_return_t kr = task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count);
    if (kr != KERN_SUCCESS) return -1.0;
    return (double)info.phys_footprint / (1024.0 * 1024.0);
}

static NSString *SpliceKitLiveCamTrimmedString(id value) {
    return [SpliceKitLiveCamString(value)
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static NSString *SpliceKitLiveCamSanitizeFilename(NSString *input) {
    NSString *trimmed = SpliceKitLiveCamTrimmedString(input);
    if (trimmed.length == 0) return @"LiveCam";

    NSCharacterSet *bad = [NSCharacterSet characterSetWithCharactersInString:@"/:\\?%*|\"<>"];
    NSArray<NSString *> *parts = [trimmed componentsSeparatedByCharactersInSet:bad];
    NSString *joined = [[parts componentsJoinedByString:@"-"]
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

    while ([joined containsString:@"  "]) {
        joined = [joined stringByReplacingOccurrencesOfString:@"  " withString:@" "];
    }
    while ([joined containsString:@"--"]) {
        joined = [joined stringByReplacingOccurrencesOfString:@"--" withString:@"-"];
    }

    return joined.length > 0 ? joined : @"LiveCam";
}

static NSString *SpliceKitLiveCamEscapeXML(NSString *input) {
    NSString *text = SpliceKitLiveCamString(input);
    text = [text stringByReplacingOccurrencesOfString:@"&" withString:@"&amp;"];
    text = [text stringByReplacingOccurrencesOfString:@"\"" withString:@"&quot;"];
    text = [text stringByReplacingOccurrencesOfString:@"<" withString:@"&lt;"];
    text = [text stringByReplacingOccurrencesOfString:@">" withString:@"&gt;"];
    text = [text stringByReplacingOccurrencesOfString:@"'" withString:@"&apos;"];
    return text;
}

static BOOL SpliceKitLiveCamPresetSupportsTimestampOverlay(NSString *identifier) {
    return [identifier isEqualToString:@"securityCam"] ||
           [identifier isEqualToString:@"oldCamcorder"] ||
           [identifier isEqualToString:@"badVideoCall"];
}

static BOOL SpliceKitLiveCamTimestampOverlayEnabled(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    id stored = [defaults objectForKey:kLiveCamTimestampOverlayKey];
    if (!stored) return YES;
    return [defaults boolForKey:kLiveCamTimestampOverlayKey];
}

static NSString *SpliceKitLiveCamEnsureDirectory(NSString *path) {
    if (path.length == 0) return @"";
    [[NSFileManager defaultManager] createDirectoryAtPath:path
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    return path;
}

static NSString *SpliceKitLiveCamOutputDirectory(void) {
    return SpliceKitLiveCamEnsureDirectory([NSHomeDirectory()
        stringByAppendingPathComponent:@"Movies/SpliceKit/LiveCam"]);
}

static NSString *SpliceKitLiveCamTemporaryDirectory(void) {
    return SpliceKitLiveCamEnsureDirectory([NSHomeDirectory()
        stringByAppendingPathComponent:@"Library/Application Support/SpliceKit/LiveCam/Temp"]);
}

static NSString *SpliceKitLiveCamTimestampForFilename(NSDate *date) {
    static NSDateFormatter *formatter = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [[NSDateFormatter alloc] init];
        formatter.dateFormat = @"yyyyMMdd_HHmmss";
    });
    return [formatter stringFromDate:date ?: [NSDate date]] ?: @"00000000_000000";
}

static NSString *SpliceKitLiveCamUniquePath(NSString *directory,
                                            NSString *baseName,
                                            NSString *extension) {
    NSString *safeBase = SpliceKitLiveCamSanitizeFilename(baseName);
    NSString *safeExt = extension.length > 0 ? extension : @"mov";
    NSString *candidate = [directory stringByAppendingPathComponent:
        [NSString stringWithFormat:@"%@.%@", safeBase, safeExt]];
    NSInteger suffix = 1;
    while ([[NSFileManager defaultManager] fileExistsAtPath:candidate]) {
        candidate = [directory stringByAppendingPathComponent:
            [NSString stringWithFormat:@"%@-%ld.%@", safeBase, (long)suffix, safeExt]];
        suffix++;
    }
    return candidate;
}

static CGSize SpliceKitLiveCamResolutionForKey(NSString *key) {
    NSString *resolution = key.length > 0 ? key : @"1280x720";
    NSArray<NSString *> *parts = [resolution componentsSeparatedByString:@"x"];
    if (parts.count == 2) {
        CGFloat width = (CGFloat)[parts[0] integerValue];
        CGFloat height = (CGFloat)[parts[1] integerValue];
        if (width > 0 && height > 0) {
            return CGSizeMake(width, height);
        }
    }
    return CGSizeMake(1280, 720);
}

static NSString *SpliceKitLiveCamResolutionKeyForDimensions(CGFloat width, CGFloat height) {
    if (width <= 0.0 || height <= 0.0) return @"";
    return [NSString stringWithFormat:@"%ldx%ld", (long)lrint(width), (long)lrint(height)];
}

static NSString *SpliceKitLiveCamResolutionTitleForKey(NSString *key) {
    CGSize size = SpliceKitLiveCamResolutionForKey(key);
    if (fabs(size.width - 3840.0) < 1.0 && fabs(size.height - 2160.0) < 1.0) {
        return @"3840x2160 (4K)";
    }
    if (fabs(size.width - 2560.0) < 1.0 && fabs(size.height - 1440.0) < 1.0) {
        return @"2560x1440 (1440p)";
    }
    if (fabs(size.width - 1920.0) < 1.0 && fabs(size.height - 1080.0) < 1.0) {
        return @"1920x1080 (1080p)";
    }
    if (fabs(size.width - 1280.0) < 1.0 && fabs(size.height - 720.0) < 1.0) {
        return @"1280x720 (720p)";
    }
    return [NSString stringWithFormat:@"%ldx%ld", (long)lrint(size.width), (long)lrint(size.height)];
}

static AVCaptureSessionPreset SpliceKitLiveCamSessionPresetForResolution(CGSize size) {
    if (fabs(size.width - 3840.0) < 1.0 && fabs(size.height - 2160.0) < 1.0) {
        return AVCaptureSessionPreset3840x2160;
    }
    if (fabs(size.width - 1920.0) < 1.0 && fabs(size.height - 1080.0) < 1.0) {
        return AVCaptureSessionPreset1920x1080;
    }
    if (fabs(size.width - 1280.0) < 1.0 && fabs(size.height - 720.0) < 1.0) {
        return AVCaptureSessionPreset1280x720;
    }
    return AVCaptureSessionPresetHigh;
}

static NSString *SpliceKitLiveCamFrameDurationString(double fps) {
    if (fps <= 0.0) return @"100/2400s";
    int timescale = 2400;
    int value = MAX(1, (int)lrint((double)timescale / fps));
    return [NSString stringWithFormat:@"%d/%ds", value, timescale];
}

static NSString *SpliceKitLiveCamCurrentTimelineEventName(void) {
    __block NSString *eventName = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            id timeline = SpliceKit_getActiveTimelineModule();
            if (!timeline) return;

            SEL seqSel = NSSelectorFromString(@"sequence");
            id sequence = [timeline respondsToSelector:seqSel]
                ? ((id (*)(id, SEL))objc_msgSend)(timeline, seqSel)
                : nil;
            if (!sequence) return;

            SEL eventSel = NSSelectorFromString(@"event");
            SEL containerEventSel = NSSelectorFromString(@"containerEvent");
            id event = nil;
            if ([sequence respondsToSelector:eventSel]) {
                event = ((id (*)(id, SEL))objc_msgSend)(sequence, eventSel);
            } else if ([sequence respondsToSelector:containerEventSel]) {
                event = ((id (*)(id, SEL))objc_msgSend)(sequence, containerEventSel);
            }
            if (!event) {
                @try { event = [sequence valueForKey:@"event"]; } @catch (__unused NSException *e) {}
            }
            if (!event) {
                @try { event = [sequence valueForKey:@"containerEvent"]; } @catch (__unused NSException *e) {}
            }
            if (event && [event respondsToSelector:@selector(displayName)]) {
                eventName = ((id (*)(id, SEL))objc_msgSend)(event, @selector(displayName));
            }
        } @catch (NSException *e) {
            SpliceKit_log(@"[LiveCamImport] Failed to resolve current event: %@", e.reason);
        }
    });
    return eventName;
}

static NSDictionary *SpliceKitLiveCamCurrentTimelineIdentity(void) {
    __block NSDictionary *identity = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            id timeline = SpliceKit_getActiveTimelineModule();
            if (!timeline) return;
            id sequence = [timeline respondsToSelector:@selector(sequence)]
                ? ((id (*)(id, SEL))objc_msgSend)(timeline, @selector(sequence))
                : nil;
            if (sequence) {
                identity = SpliceKit_sequenceIdentity(sequence);
            }
        } @catch (NSException *e) {
            SpliceKit_log(@"[LiveCamTimeline] Failed to resolve timeline identity: %@", e.reason);
        }
    });
    return identity;
}

static BOOL SpliceKitLiveCamHasActiveTimeline(void) {
    __block BOOL hasTimeline = NO;
    SpliceKit_executeOnMainThread(^{
        @try {
            hasTimeline = (SpliceKit_getActiveTimelineModule() != nil);
        } @catch (__unused NSException *e) {
            hasTimeline = NO;
        }
    });
    return hasTimeline;
}

static BOOL SpliceKitLiveCamTimelineIdentityMatches(NSDictionary *expected,
                                                    NSDictionary *current) {
    if (!expected || !current) return NO;
    NSString *expectedKey = SpliceKitLiveCamString(expected[@"cacheKey"]);
    NSString *currentKey = SpliceKitLiveCamString(current[@"cacheKey"]);
    if (expectedKey.length > 0 && currentKey.length > 0) {
        return [expectedKey isEqualToString:currentKey];
    }
    return [[expected description] isEqualToString:[current description]];
}

static NSDictionary *SpliceKitLiveCamInspectMediaAtURL(NSURL *url) {
    if (!url.isFileURL) return @{@"error": @"LiveCam media URL must be a file URL."};
    if (![[NSFileManager defaultManager] fileExistsAtPath:url.path]) {
        return @{@"error": @"LiveCam recording file does not exist on disk."};
    }

    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
    NSArray<AVAssetTrack *> *videoTracks = [asset tracksWithMediaType:AVMediaTypeVideo];
    NSArray<AVAssetTrack *> *audioTracks = [asset tracksWithMediaType:AVMediaTypeAudio];
    CMTime duration = asset.duration;
    if (!CMTIME_IS_VALID(duration) || CMTIME_IS_INDEFINITE(duration) ||
        duration.timescale <= 0 || duration.value <= 0) {
        return @{@"error": @"LiveCam recording has no readable duration."};
    }

    AVAssetTrack *videoTrack = videoTracks.firstObject;
    AVAssetTrack *audioTrack = audioTracks.firstObject;

    int width = 1280;
    int height = 720;
    NSString *frameDuration = @"100/2400s";
    if (videoTrack) {
        CGSize size = CGSizeApplyAffineTransform(videoTrack.naturalSize, videoTrack.preferredTransform);
        width = MAX(1, (int)fabs(size.width));
        height = MAX(1, (int)fabs(size.height));
        if (videoTrack.nominalFrameRate > 0.0f) {
            frameDuration = SpliceKitLiveCamFrameDurationString(videoTrack.nominalFrameRate);
        } else if (CMTIME_IS_VALID(videoTrack.minFrameDuration) &&
                   videoTrack.minFrameDuration.value > 0 &&
                   videoTrack.minFrameDuration.timescale > 0) {
            frameDuration = [NSString stringWithFormat:@"%lld/%ds",
                             videoTrack.minFrameDuration.value,
                             videoTrack.minFrameDuration.timescale];
        }
    }

    return @{
        @"duration": [NSString stringWithFormat:@"%lld/%ds", duration.value, duration.timescale],
        @"width": @(width),
        @"height": @(height),
        @"frameDuration": frameDuration,
        @"hasVideo": @(videoTrack != nil),
        @"hasAudio": @(audioTrack != nil),
        @"audioRate": @(audioTrack ? (int)round(audioTrack.naturalTimeScale > 0 ? audioTrack.naturalTimeScale : 48000) : 0),
    };
}

static NSString *SpliceKitLiveCamImportXML(NSURL *fileURL,
                                           NSString *clipName,
                                           NSString *eventName,
                                           NSDictionary *mediaInfo) {
    NSString *uid = [[NSUUID UUID] UUIDString];
    NSString *fmtID = [NSString stringWithFormat:@"fmt_%@", [uid substringToIndex:8]];
    NSString *assetID = [NSString stringWithFormat:@"asset_%@", [uid substringToIndex:8]];
    NSString *escapedClip = SpliceKitLiveCamEscapeXML(clipName ?: @"LiveCam");
    NSString *escapedEvent = SpliceKitLiveCamEscapeXML(eventName ?: @"LiveCam");
    NSString *duration = SpliceKitLiveCamString(mediaInfo[@"duration"]);
    NSString *frameDuration = SpliceKitLiveCamString(mediaInfo[@"frameDuration"]);
    int width = [mediaInfo[@"width"] intValue] ?: 1280;
    int height = [mediaInfo[@"height"] intValue] ?: 720;
    BOOL hasVideo = [mediaInfo[@"hasVideo"] boolValue];
    BOOL hasAudio = [mediaInfo[@"hasAudio"] boolValue];
    int audioRate = [mediaInfo[@"audioRate"] intValue] ?: 48000;

    NSMutableString *xml = [NSMutableString string];
    [xml appendString:@"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"];
    [xml appendString:@"<!DOCTYPE fcpxml>\n"];
    [xml appendString:@"<fcpxml version=\"1.14\">\n"];
    [xml appendString:@"    <resources>\n"];
    [xml appendFormat:@"        <format id=\"%@\" frameDuration=\"%@\" width=\"%d\" height=\"%d\" name=\"FFVideoFormat%dx%dp\"/>\n",
        fmtID, frameDuration.length > 0 ? frameDuration : @"100/2400s", width, height, width, height];
    [xml appendFormat:@"        <asset id=\"%@\" name=\"%@\" uid=\"%@\" start=\"0s\" duration=\"%@\" hasVideo=\"%@\" hasAudio=\"%@\" format=\"%@\" audioSources=\"%@\" audioChannels=\"2\" audioRate=\"%d\">\n",
        assetID,
        escapedClip,
        uid,
        duration.length > 0 ? duration : @"2400/2400s",
        hasVideo ? @"1" : @"0",
        hasAudio ? @"1" : @"0",
        fmtID,
        hasAudio ? @"1" : @"0",
        audioRate];
    [xml appendFormat:@"            <media-rep kind=\"original-media\" src=\"%@\"/>\n",
        fileURL.absoluteURL.absoluteString ?: @""];
    [xml appendString:@"        </asset>\n"];
    [xml appendString:@"    </resources>\n"];
    [xml appendFormat:@"    <event name=\"%@\">\n", escapedEvent];
    [xml appendFormat:@"        <asset-clip ref=\"%@\" name=\"%@\" duration=\"%@\" start=\"0s\"/>\n",
        assetID, escapedClip, duration.length > 0 ? duration : @"2400/2400s"];
    [xml appendString:@"    </event>\n"];
    [xml appendString:@"</fcpxml>\n"];
    return xml;
}

static id SpliceKitLiveCamFindClipNamed(NSString *clipName, NSString *eventName) {
    __block id foundClip = nil;
    NSString *needle = [[SpliceKitLiveCamTrimmedString(clipName) lowercaseString] copy];
    NSString *eventNeedle = [[SpliceKitLiveCamTrimmedString(eventName) lowercaseString] copy];

    if (needle.length == 0) return nil;

    SpliceKit_executeOnMainThread(^{
        @try {
            id libs = ((id (*)(id, SEL))objc_msgSend)(
                objc_getClass("FFLibraryDocument"), @selector(copyActiveLibraries));
            if (![libs isKindOfClass:[NSArray class]] || [(NSArray *)libs count] == 0) return;

            id library = [(NSArray *)libs firstObject];
            SEL eventsSel = NSSelectorFromString(@"events");
            id events = [library respondsToSelector:eventsSel]
                ? ((id (*)(id, SEL))objc_msgSend)(library, eventsSel)
                : nil;
            if (![events isKindOfClass:[NSArray class]]) return;

            for (id event in (NSArray *)events) {
                NSString *candidateEvent = @"";
                if ([event respondsToSelector:@selector(displayName)]) {
                    candidateEvent = ((id (*)(id, SEL))objc_msgSend)(event, @selector(displayName)) ?: @"";
                }
                if (eventNeedle.length > 0 &&
                    ![[candidateEvent lowercaseString] containsString:eventNeedle]) {
                    continue;
                }

                id clips = nil;
                SEL displayClipsSel = NSSelectorFromString(@"displayOwnedClips");
                SEL ownedClipsSel = NSSelectorFromString(@"ownedClips");
                SEL childItemsSel = NSSelectorFromString(@"childItems");
                if ([event respondsToSelector:displayClipsSel]) {
                    clips = ((id (*)(id, SEL))objc_msgSend)(event, displayClipsSel);
                } else if ([event respondsToSelector:ownedClipsSel]) {
                    clips = ((id (*)(id, SEL))objc_msgSend)(event, ownedClipsSel);
                } else if ([event respondsToSelector:childItemsSel]) {
                    clips = ((id (*)(id, SEL))objc_msgSend)(event, childItemsSel);
                }
                if ([clips isKindOfClass:[NSSet class]]) clips = [(NSSet *)clips allObjects];
                if (![clips isKindOfClass:[NSArray class]]) continue;

                for (id clip in [(NSArray *)clips reverseObjectEnumerator]) {
                    if (![clip respondsToSelector:@selector(displayName)]) continue;
                    NSString *candidateName = ((id (*)(id, SEL))objc_msgSend)(clip, @selector(displayName)) ?: @"";
                    if ([[candidateName lowercaseString] isEqualToString:needle]) {
                        foundClip = clip;
                        return;
                    }
                }
            }
        } @catch (NSException *e) {
            SpliceKit_log(@"[LiveCamImport] Clip lookup failed: %@", e.reason);
        }
    });
    return foundClip;
}

static BOOL SpliceKitLiveCamSelectClipInBrowser(id clip) {
    __block BOOL selected = NO;
    if (!clip) return NO;

    SpliceKit_executeOnMainThread(^{
        @try {
            id app = ((id (*)(id, SEL))objc_msgSend)(
                objc_getClass("NSApplication"), @selector(sharedApplication));
            id delegate = ((id (*)(id, SEL))objc_msgSend)(app, @selector(delegate));
            if (!delegate) return;

            id browserContainer = nil;
            SEL browserSel = NSSelectorFromString(@"mediaBrowserContainerModule");
            if ([delegate respondsToSelector:browserSel]) {
                browserContainer = ((id (*)(id, SEL))objc_msgSend)(delegate, browserSel);
            }

            Class rangeObjClass = objc_getClass("FigTimeRangeAndObject");
            if (!rangeObjClass) return;

            CMTimeRange clipRange = kCMTimeRangeZero;
            SEL clippedRangeSel = NSSelectorFromString(@"clippedRange");
            SEL durationSel = NSSelectorFromString(@"duration");
            if ([clip respondsToSelector:clippedRangeSel]) {
                clipRange = ((CMTimeRange (*)(id, SEL))SPLICEKIT_LIVECAM_STRET_MSG)(clip, clippedRangeSel);
            } else if ([clip respondsToSelector:durationSel]) {
                CMTime duration = ((CMTime (*)(id, SEL))SPLICEKIT_LIVECAM_STRET_MSG)(clip, durationSel);
                clipRange = CMTimeRangeMake(kCMTimeZero, duration);
            }

            SEL rangeAndObjSel = NSSelectorFromString(@"rangeAndObjectWithRange:andObject:");
            if (![(id)rangeObjClass respondsToSelector:rangeAndObjSel]) return;
            id mediaRange = ((id (*)(id, SEL, CMTimeRange, id))objc_msgSend)(
                (id)rangeObjClass, rangeAndObjSel, clipRange, clip);
            if (!mediaRange) return;

            id filmstrip = nil;
            SEL filmstripSel = NSSelectorFromString(@"filmstripModule");
            if (browserContainer && [browserContainer respondsToSelector:filmstripSel]) {
                filmstrip = ((id (*)(id, SEL))objc_msgSend)(browserContainer, filmstripSel);
            }

            SEL setSelectionSel = NSSelectorFromString(@"setSelection:");
            if (filmstrip && [filmstrip respondsToSelector:setSelectionSel]) {
                ((void (*)(id, SEL, id))objc_msgSend)(filmstrip, setSelectionSel, @[mediaRange]);
                selected = YES;
            }

            SEL setCurrentSel = NSSelectorFromString(@"setCurrentSelection:");
            if (!selected && browserContainer && [browserContainer respondsToSelector:setCurrentSel]) {
                ((void (*)(id, SEL, id))objc_msgSend)(browserContainer, setCurrentSel, @[mediaRange]);
                selected = YES;
            }
        } @catch (NSException *e) {
            SpliceKit_log(@"[LiveCamImport] Failed to select browser clip: %@", e.reason);
        }
    });
    return selected;
}

static CIImage *SpliceKitLiveCamApplyFilter(CIImage *image,
                                            NSString *filterName,
                                            NSDictionary<NSString *, id> *parameters) {
    CIFilter *filter = [CIFilter filterWithName:filterName];
    if (!filter) return image;
    [filter setDefaults];
    if (image) {
        [filter setValue:image forKey:kCIInputImageKey];
    }
    [parameters enumerateKeysAndObjectsUsingBlock:^(NSString *key, id value, BOOL *stop) {
        if (value) [filter setValue:value forKey:key];
    }];
    CIImage *result = filter.outputImage;
    return result ?: image;
}

static CIImage *SpliceKitLiveCamSolidColorImage(CIColor *color, CGRect rect) {
    return [[[CIImage imageWithColor:color ?: [CIColor colorWithRed:0 green:0 blue:0 alpha:1]]
        imageByCroppingToRect:rect] imageByCroppingToRect:rect];
}

static CIColor *SpliceKitLiveCamBackgroundCIColor(NSString *key) {
    NSString *backgroundKey = key.length > 0 ? key : @"green";
    if ([backgroundKey isEqualToString:@"blue"]) {
        return [CIColor colorWithRed:0.04 green:0.22 blue:0.82 alpha:1.0];
    }
    return [CIColor colorWithRed:0.03 green:0.78 blue:0.20 alpha:1.0];
}

typedef NS_ENUM(NSInteger, SpliceKitLiveCamSegmentationQuality) {
    SpliceKitLiveCamSegmentationQualityFast = 0,
    SpliceKitLiveCamSegmentationQualityBalanced = 1,
    SpliceKitLiveCamSegmentationQualityAccurate = 2,
};

@interface SpliceKitLiveCamSegmentationEngine : NSObject
@property (nonatomic, assign, readonly) BOOL supported;
@property (nonatomic, assign, readonly) BOOL usingSubjectLift;
@property (nonatomic, copy, readonly) NSString *lastError;
@property (nonatomic, assign, readonly) NSUInteger maskGeneration;
@property (nonatomic, assign) SpliceKitLiveCamSegmentationQuality quality;
- (CIImage *)maskImageForSampleBuffer:(CMSampleBufferRef)sampleBuffer;
- (void)reset;
@end

@interface SpliceKitLiveCamSegmentationEngine ()
@property (nonatomic, strong) VNSequenceRequestHandler *requestHandler;
@property (nonatomic, strong) VNRequest *primaryRequest;
@property (nonatomic, strong) VNGeneratePersonSegmentationRequest *fallbackRequest;
@property (nonatomic, assign) CVPixelBufferRef latestMaskBuffer;
@property (nonatomic, assign, readwrite) BOOL supported;
@property (nonatomic, assign, readwrite) BOOL usingSubjectLift;
@property (nonatomic, copy, readwrite) NSString *lastError;
@property (nonatomic, assign) NSUInteger frameCounter;
@property (nonatomic, assign, readwrite) NSUInteger maskGeneration;
@end

@implementation SpliceKitLiveCamSegmentationEngine

- (instancetype)init {
    self = [super init];
    if (!self) return nil;

    _quality = SpliceKitLiveCamSegmentationQualityBalanced;
    _requestHandler = [[VNSequenceRequestHandler alloc] init];

    // Subject Lift gives a much tighter, edge-aware matte than person segmentation
    // and works on objects, not just people — prefer it whenever the OS supports it.
    if (@available(macOS 14.0, *)) {
        _primaryRequest = [[VNGenerateForegroundInstanceMaskRequest alloc] init];
        _supported = YES;
        _usingSubjectLift = YES;
    } else if (@available(macOS 12.0, *)) {
        _fallbackRequest = [[VNGeneratePersonSegmentationRequest alloc] init];
        _fallbackRequest.qualityLevel = VNGeneratePersonSegmentationRequestQualityLevelAccurate;
        _fallbackRequest.outputPixelFormat = kCVPixelFormatType_OneComponent8;
        _primaryRequest = _fallbackRequest;
        _supported = YES;
        _usingSubjectLift = NO;
    } else {
        _supported = NO;
        _lastError = @"Green Screen requires macOS 12 or newer.";
    }

    return self;
}

- (void)dealloc {
    if (_latestMaskBuffer) {
        CVPixelBufferRelease(_latestMaskBuffer);
        _latestMaskBuffer = nil;
    }
}

- (void)reset {
    self.frameCounter = 0;
    self.lastError = @"";
    if (self.latestMaskBuffer) {
        CVPixelBufferRelease(self.latestMaskBuffer);
        self.latestMaskBuffer = nil;
    }
    self.maskGeneration = 0;
}

- (void)setQuality:(SpliceKitLiveCamSegmentationQuality)quality {
    if (_quality == quality) return;
    _quality = quality;
    if (self.fallbackRequest) {
        switch (quality) {
            case SpliceKitLiveCamSegmentationQualityFast:
                self.fallbackRequest.qualityLevel = VNGeneratePersonSegmentationRequestQualityLevelFast;
                break;
            case SpliceKitLiveCamSegmentationQualityBalanced:
                self.fallbackRequest.qualityLevel = VNGeneratePersonSegmentationRequestQualityLevelBalanced;
                break;
            case SpliceKitLiveCamSegmentationQualityAccurate:
                self.fallbackRequest.qualityLevel = VNGeneratePersonSegmentationRequestQualityLevelAccurate;
                break;
        }
    }
}

// Quality presets pick the inference downsample factor. Vision dominates frame cost,
// so running on a smaller image and upscaling the mask is the dominant perf lever.
- (CGFloat)inferenceDownsampleFactor {
    switch (self.quality) {
        case SpliceKitLiveCamSegmentationQualityFast:     return 0.40;
        case SpliceKitLiveCamSegmentationQualityBalanced: return 0.60;
        case SpliceKitLiveCamSegmentationQualityAccurate: return 1.0;
    }
    return 0.6;
}

// Match inference cadence to the requested quality tier. The compositor still
// runs at camera frame rate and reuses the last materialized matte between
// Vision updates, so Fast saves substantial neural-engine/GPU work without
// making preview or recording cadence uneven.
- (NSUInteger)inferenceFrameInterval {
    switch (self.quality) {
        case SpliceKitLiveCamSegmentationQualityFast:     return 3;
        case SpliceKitLiveCamSegmentationQualityBalanced: return 2;
        case SpliceKitLiveCamSegmentationQualityAccurate: return 1;
    }
    return 2;
}

- (CIImage *)maskImageForSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    if (!self.supported || !sampleBuffer || !self.primaryRequest) return nil;

    self.frameCounter += 1;
    NSUInteger inferenceInterval = [self inferenceFrameInterval];
    BOOL shouldAnalyze = (self.frameCounter <= 2) || (self.frameCounter % inferenceInterval == 0);
    if (shouldAnalyze) {
        CVPixelBufferRef maskBuffer = [self runInferenceForSampleBuffer:sampleBuffer];
        if (maskBuffer) {
            if (self.latestMaskBuffer) {
                CVPixelBufferRelease(self.latestMaskBuffer);
            }
            self.latestMaskBuffer = maskBuffer; // ownership transferred from runInference
            self.maskGeneration += 1;
            self.lastError = @"";
        }
    }

    if (!self.latestMaskBuffer) return nil;

    CIImage *mask = [CIImage imageWithCVPixelBuffer:self.latestMaskBuffer];
    if (!mask) return nil;
    CGRect extent = CGRectMake(0,
                               0,
                               CVPixelBufferGetWidth(self.latestMaskBuffer),
                               CVPixelBufferGetHeight(self.latestMaskBuffer));
    return [mask imageByCroppingToRect:extent];
}

// Returns a retained CVPixelBufferRef the caller owns, or NULL on failure.
- (CVPixelBufferRef)runInferenceForSampleBuffer:(CMSampleBufferRef)sampleBuffer CF_RETURNS_RETAINED {
    CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!imageBuffer) return NULL;

    if (self.usingSubjectLift) {
        if (@available(macOS 14.0, *)) {
            return [self runSubjectLiftForImageBuffer:imageBuffer
                                       presentationTime:CMSampleBufferGetPresentationTimeStamp(sampleBuffer)];
        }
    }

    NSError *error = nil;
    BOOL ok = [self.requestHandler performRequests:@[self.primaryRequest]
                                  onCMSampleBuffer:sampleBuffer
                                             error:&error];
    if (!ok || error) {
        self.lastError = error.localizedDescription ?: @"Vision could not generate a person mask.";
        return NULL;
    }
    VNPixelBufferObservation *observation = (VNPixelBufferObservation *)self.primaryRequest.results.firstObject;
    CVPixelBufferRef result = observation.pixelBuffer;
    if (result) CVPixelBufferRetain(result);
    return result;
}

- (CVPixelBufferRef)runSubjectLiftForImageBuffer:(CVImageBufferRef)imageBuffer
                                presentationTime:(CMTime)pts CF_RETURNS_RETAINED API_AVAILABLE(macos(14.0)) {
    if (!imageBuffer) return NULL;

    // Run inference on a downsampled CIImage to cut Vision cost. The returned
    // CGImage is then upscaled by the renderer's joint-bilateral kernel using
    // the full-res guide image, so the mask edge stays sharp at output res.
    CIImage *full = [CIImage imageWithCVPixelBuffer:imageBuffer];
    if (!full) return NULL;
    CGFloat factor = [self inferenceDownsampleFactor];
    CIImage *scaled = full;
    if (factor < 0.999) {
        scaled = [full imageByApplyingFilter:@"CILanczosScaleTransform"
                         withInputParameters:@{kCIInputScaleKey: @(factor),
                                                kCIInputAspectRatioKey: @1.0}];
    }

    NSDictionary *handlerOptions = @{};
    VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCIImage:scaled
                                                                            options:handlerOptions];
    NSError *error = nil;
    VNGenerateForegroundInstanceMaskRequest *request = (VNGenerateForegroundInstanceMaskRequest *)self.primaryRequest;
    if (![handler performRequests:@[request] error:&error]) {
        self.lastError = error.localizedDescription ?: @"Subject Lift could not generate a mask.";
        return NULL;
    }

    VNInstanceMaskObservation *observation = (VNInstanceMaskObservation *)request.results.firstObject;
    if (!observation) {
        // No subject in frame — return a zero mask at the full source size so the
        // composite cleanly shows the background instead of falling back to the previous frame.
        return [self emptyMaskMatchingImageBuffer:imageBuffer];
    }

    NSError *maskError = nil;
    CVPixelBufferRef maskBuffer = [observation generateScaledMaskForImageForInstances:observation.allInstances
                                                                     fromRequestHandler:handler
                                                                                  error:&maskError];
    if (!maskBuffer || maskError) {
        self.lastError = maskError.localizedDescription ?: @"Subject Lift mask generation failed.";
        return NULL;
    }
    // generateScaledMaskForImageForInstances: returns a retained buffer.
    return maskBuffer;
}

- (CVPixelBufferRef)emptyMaskMatchingImageBuffer:(CVImageBufferRef)imageBuffer CF_RETURNS_RETAINED {
    size_t w = CVPixelBufferGetWidth(imageBuffer);
    size_t h = CVPixelBufferGetHeight(imageBuffer);
    CVPixelBufferRef out = NULL;
    NSDictionary *attrs = @{(id)kCVPixelBufferIOSurfacePropertiesKey: @{}};
    CVReturn rc = CVPixelBufferCreate(kCFAllocatorDefault, w, h,
                                      kCVPixelFormatType_OneComponent8,
                                      (__bridge CFDictionaryRef)attrs, &out);
    if (rc != kCVReturnSuccess || !out) return NULL;
    CVPixelBufferLockBaseAddress(out, 0);
    void *base = CVPixelBufferGetBaseAddress(out);
    size_t bytesPerRow = CVPixelBufferGetBytesPerRow(out);
    memset(base, 0, bytesPerRow * h);
    CVPixelBufferUnlockBaseAddress(out, 0);
    return out;
}

@end

@interface SpliceKitLiveCamMaskParams : NSObject
@property (nonatomic, assign) CGFloat edgeSoftness;  // 0..1, gaussian feather radius scale
@property (nonatomic, assign) CGFloat refinement;    // 0..1, joint-bilateral edge refinement
@property (nonatomic, assign) CGFloat choke;         // -1..1, negative dilates / positive erodes
@property (nonatomic, assign) CGFloat spill;         // 0..1, edge desaturation strength
@property (nonatomic, assign) CGFloat wrap;          // 0..1, background light bleed into edge
@property (nonatomic, assign) CGFloat temporalSmoothing; // 0..1, EMA factor against previous mask
@property (nonatomic, assign) BOOL transparentBackground; // when YES, output premultiplied alpha
@property (nonatomic, assign) NSUInteger sourceGeneration;
@end

@implementation SpliceKitLiveCamMaskParams
@end

@interface SpliceKitLiveCamRenderer : NSObject
@property (nonatomic, strong, readonly) CIContext *ciContext;
@property (nonatomic, strong, readonly) id<MTLCommandQueue> commandQueue;
@property (nonatomic, assign, readonly) CGColorSpaceRef colorSpace;
- (CIImage *)renderedImageFromImage:(CIImage *)image
                             preset:(SpliceKitLiveCamPreset *)preset
                               time:(NSTimeInterval)time
                        adjustments:(SpliceKitLiveCamAdjustmentState *)adjustments
                          maskImage:(CIImage *)maskImage
                         maskParams:(SpliceKitLiveCamMaskParams *)maskParams
                    backgroundColor:(CIColor *)backgroundColor
                           mirrored:(BOOL)mirrored
                          recording:(BOOL)recording
                         canvasSize:(CGSize)canvasSize;
- (CIImage *)imageFittedForCanvas:(CIImage *)image
                       canvasSize:(CGSize)canvasSize
                             fill:(BOOL)fill;
- (CIImage *)imageFittedForCanvas:(CIImage *)image
                       canvasSize:(CGSize)canvasSize
                             fill:(BOOL)fill
                    preserveAlpha:(BOOL)preserveAlpha;
- (CIImage *)imageByCompositingOverPreviewCheckerboard:(CIImage *)alphaImage;
- (void)resetMaskHistory;
@property (nonatomic, strong, readonly) CIImage *previousMaskForBlend;
@end

@interface SpliceKitLiveCamRenderer ()
@property (nonatomic, strong) CIContext *ciContext;
@property (nonatomic, strong) id<MTLDevice> metalDevice;
@property (nonatomic, strong) id<MTLCommandQueue> commandQueue;
@property (nonatomic, assign) CGColorSpaceRef colorSpace;
@property (nonatomic, strong) NSMutableDictionary<NSString *, CIKernel *> *kernels;
@property (nonatomic, strong) NSMutableDictionary<NSString *, CIImage *> *overlayCache;
@property (nonatomic, strong) NSMutableArray<CIImage *> *trailFrames;
@property (nonatomic, strong) CIImage *previousMaskForBlend;
@property (nonatomic, assign) CVPixelBufferPoolRef maskHistoryPool;
@property (nonatomic, assign) size_t maskHistoryWidth;
@property (nonatomic, assign) size_t maskHistoryHeight;
@property (nonatomic, assign) NSUInteger maskHistoryFrames;
@property (nonatomic, assign) NSUInteger previousMaskSourceGeneration;
@property (nonatomic, assign) CGFloat previousMaskEdgeSoftness;
@property (nonatomic, assign) CGFloat previousMaskRefinement;
@property (nonatomic, assign) CGFloat previousMaskChoke;
@property (nonatomic, assign) CGFloat previousMaskTemporalSmoothing;
@property (nonatomic, assign) BOOL previousMaskConfigurationValid;
@end

@implementation SpliceKitLiveCamRenderer

- (instancetype)init {
    self = [super init];
    if (!self) return nil;

    _colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    _metalDevice = MTLCreateSystemDefaultDevice();
    if (_metalDevice) {
        _commandQueue = [_metalDevice newCommandQueue];
    }
    if (_commandQueue) {
        _ciContext = [CIContext contextWithMTLCommandQueue:_commandQueue options:@{
            kCIContextWorkingColorSpace: (__bridge id)_colorSpace,
            kCIContextOutputColorSpace: (__bridge id)_colorSpace,
            // Every camera frame has different inputs. Retaining Core Image's
            // transient intermediates only grows memory and cannot produce a
            // useful cache hit for this streaming workload.
            kCIContextCacheIntermediates: @NO,
        }];
        SpliceKit_log(@"[LiveCamEffects] Metal-backed CIContext ready on %@", _metalDevice.name ?: @"<unnamed>");
    } else {
        _ciContext = [CIContext contextWithOptions:@{
            kCIContextWorkingColorSpace: (__bridge id)_colorSpace,
            kCIContextOutputColorSpace: (__bridge id)_colorSpace,
            kCIContextCacheIntermediates: @NO,
        }];
        SpliceKit_log(@"[LiveCamEffects] Falling back to CPU/GL Core Image context");
    }

    _kernels = [NSMutableDictionary dictionary];
    _overlayCache = [NSMutableDictionary dictionary];
    _trailFrames = [NSMutableArray array];
    [self compileMetalKernelsIfPossible];
    return self;
}

- (void)dealloc {
    if (_maskHistoryPool) {
        CVPixelBufferPoolRelease(_maskHistoryPool);
        _maskHistoryPool = NULL;
    }
    if (_colorSpace) {
        CGColorSpaceRelease(_colorSpace);
        _colorSpace = nil;
    }
}

- (void)compileMetalKernelsIfPossible {
    if (@available(macOS 12.0, *)) {
        NSError *error = nil;
        NSArray<CIKernel *> *kernels = [CIKernel kernelsWithMetalString:kSpliceKitLiveCamMetalSource error:&error];
        if (kernels.count == 0 || error) {
            SpliceKit_log(@"[LiveCamEffects] Metal kernels unavailable: %@", error.localizedDescription ?: @"unknown error");
            return;
        }
        for (CIKernel *kernel in kernels) {
            if (kernel.name.length > 0) {
                self.kernels[kernel.name] = kernel;
            }
        }
        SpliceKit_log(@"[LiveCamEffects] Loaded Metal kernels: %@", [self.kernels.allKeys componentsJoinedByString:@", "]);
    }
}

- (CIImage *)applyWarpKernelNamed:(NSString *)name
                          toImage:(CIImage *)image
                        arguments:(NSArray<id> *)arguments {
    CIWarpKernel *kernel = (CIWarpKernel *)self.kernels[name];
    if (![kernel isKindOfClass:[CIWarpKernel class]]) return image;

    CGRect extent = image.extent;
    return [kernel applyWithExtent:extent
                       roiCallback:^CGRect(int index, CGRect destRect) {
                           return CGRectInset(destRect, -80.0, -80.0);
                       }
                        inputImage:image
                         arguments:arguments] ?: image;
}

- (CIImage *)applyColorKernelNamed:(NSString *)name
                           toImage:(CIImage *)image
                         arguments:(NSArray<id> *)arguments {
    // Despite the "Color" name, the method also handles general CIKernels so
    // stitchable Metal shaders that sample neighbor pixels (rgbSplit, glitch,
    // scanline, maskRefine, maskChoke) are not silently skipped.
    CIKernel *kernel = self.kernels[name];
    if (!kernel) return image;
    CIImage *result = nil;
    if ([kernel isKindOfClass:[CIColorKernel class]]) {
        result = [(CIColorKernel *)kernel applyWithExtent:image.extent arguments:arguments];
    } else {
        result = [kernel applyWithExtent:image.extent
                             roiCallback:^CGRect(int index, CGRect destRect) {
                                 return CGRectInset(destRect, -12.0, -12.0);
                             }
                               arguments:arguments];
    }
    return result ?: image;
}

- (CIImage *)noiseImageForExtent:(CGRect)extent alpha:(CGFloat)alpha monochrome:(BOOL)monochrome {
    CIImage *noise = [CIFilter filterWithName:@"CIRandomGenerator"].outputImage;
    if (!noise) return nil;
    noise = [noise imageByCroppingToRect:extent];
    if (monochrome) {
        noise = SpliceKitLiveCamApplyFilter(noise, @"CIColorControls", @{
            kCIInputSaturationKey: @0.0,
            kCIInputContrastKey: @1.35,
        });
    }
    noise = SpliceKitLiveCamApplyFilter(noise, @"CIColorMatrix", @{
        @"inputRVector": [CIVector vectorWithX:1 Y:0 Z:0 W:0],
        @"inputGVector": [CIVector vectorWithX:0 Y:1 Z:0 W:0],
        @"inputBVector": [CIVector vectorWithX:0 Y:0 Z:1 W:0],
        @"inputAVector": [CIVector vectorWithX:0 Y:0 Z:0 W:alpha],
    });
    return noise;
}

- (CIImage *)overlayImageForKey:(NSString *)cacheKey
                           size:(CGSize)size
                      drawBlock:(void (^)(void))drawBlock {
    if (cacheKey.length == 0 || size.width <= 0 || size.height <= 0) return nil;
    CIImage *cached = self.overlayCache[cacheKey];
    if (cached) return cached;

    NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize(size.width, size.height)];
    [image lockFocus];
    [[NSColor clearColor] setFill];
    NSRectFill(NSMakeRect(0, 0, size.width, size.height));
    if (drawBlock) drawBlock();
    [image unlockFocus];

    CGImageRef cgImage = [image CGImageForProposedRect:NULL context:nil hints:nil];
    if (!cgImage) return nil;

    CIImage *ciImage = [[CIImage alloc] initWithCGImage:cgImage];
    if (ciImage) {
        self.overlayCache[cacheKey] = ciImage;
    }
    return ciImage;
}

- (CIImage *)timestampOverlayForExtent:(CGRect)extent
                             timestamp:(NSString *)timestamp
                                  tint:(NSColor *)tint
                                prefix:(NSString *)prefix {
    NSString *text = prefix.length > 0
        ? [NSString stringWithFormat:@"%@ %@", prefix, timestamp ?: @""]
        : (timestamp ?: @"");
    NSString *cacheKey = [NSString stringWithFormat:@"stamp|%@|%.0fx%.0f|%@",
                          text,
                          extent.size.width,
                          extent.size.height,
                          tint.description ?: @""];
    CIImage *overlay = [self overlayImageForKey:cacheKey size:extent.size drawBlock:^{
        NSDictionary *attrs = @{
            NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:14 weight:NSFontWeightSemibold],
            NSForegroundColorAttributeName: tint ?: [NSColor colorWithWhite:1 alpha:0.95],
            NSStrokeColorAttributeName: [NSColor colorWithWhite:0 alpha:0.4],
            NSStrokeWidthAttributeName: @-1.5,
        };
        [text drawAtPoint:NSMakePoint(18, 18) withAttributes:attrs];
    }];
    if (!overlay) return nil;
    return [overlay imageByCroppingToRect:extent];
}

- (CIImage *)recordingOverlayForExtent:(CGRect)extent timestamp:(NSString *)timestamp {
    NSString *cacheKey = [NSString stringWithFormat:@"rec|%@|%.0fx%.0f",
                          timestamp ?: @"", extent.size.width, extent.size.height];
    CIImage *overlay = [self overlayImageForKey:cacheKey size:extent.size drawBlock:^{
        NSColor *red = [NSColor colorWithRed:0.98 green:0.21 blue:0.23 alpha:0.95];
        [red setFill];
        NSBezierPath *dot = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(18, extent.size.height - 30, 12, 12)];
        [dot fill];

        NSDictionary *recAttrs = @{
            NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightBold],
            NSForegroundColorAttributeName: red,
        };
        [@"REC" drawAtPoint:NSMakePoint(36, extent.size.height - 33) withAttributes:recAttrs];

        if (timestamp.length > 0) {
            NSDictionary *timeAttrs = @{
                NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightMedium],
                NSForegroundColorAttributeName: [NSColor colorWithWhite:1 alpha:0.92],
                NSStrokeColorAttributeName: [NSColor colorWithWhite:0 alpha:0.35],
                NSStrokeWidthAttributeName: @-1.2,
            };
            [timestamp drawAtPoint:NSMakePoint(extent.size.width - 140, extent.size.height - 33)
                     withAttributes:timeAttrs];
        }
    }];
    if (!overlay) return nil;
    return [overlay imageByCroppingToRect:extent];
}

- (CIImage *)imageFittedForCanvas:(CIImage *)image
                       canvasSize:(CGSize)canvasSize
                             fill:(BOOL)fill {
    return [self imageFittedForCanvas:image canvasSize:canvasSize fill:fill preserveAlpha:NO];
}

- (CIImage *)imageFittedForCanvas:(CIImage *)image
                       canvasSize:(CGSize)canvasSize
                             fill:(BOOL)fill
                    preserveAlpha:(BOOL)preserveAlpha {
    if (!image || canvasSize.width <= 0 || canvasSize.height <= 0) return image;
    CGRect extent = image.extent;
    if (extent.size.width <= 0 || extent.size.height <= 0) return image;

    CGFloat scaleX = canvasSize.width / extent.size.width;
    CGFloat scaleY = canvasSize.height / extent.size.height;
    CGFloat scale = fill ? MAX(scaleX, scaleY) : MIN(scaleX, scaleY);
    if (!isfinite(scale) || scale <= 0.0) scale = 1.0;

    CIImage *scaled = [image imageByApplyingTransform:CGAffineTransformMakeScale(scale, scale)];
    CGRect scaledExtent = scaled.extent;
    CGFloat tx = (canvasSize.width - scaledExtent.size.width) * 0.5 - scaledExtent.origin.x;
    CGFloat ty = (canvasSize.height - scaledExtent.size.height) * 0.5 - scaledExtent.origin.y;
    scaled = [scaled imageByApplyingTransform:CGAffineTransformMakeTranslation(tx, ty)];

    CGRect canvasRect = CGRectMake(0, 0, canvasSize.width, canvasSize.height);
    if (preserveAlpha) {
        return [scaled imageByCroppingToRect:canvasRect];
    }
    CIImage *background = SpliceKitLiveCamSolidColorImage([CIColor colorWithRed:0 green:0 blue:0 alpha:1], canvasRect);
    return [[scaled imageByCompositingOverImage:background] imageByCroppingToRect:canvasRect];
}

- (CIImage *)composeSplitImage:(CIImage *)image mirrored:(BOOL)mirrored {
    CGRect extent = image.extent;
    CGFloat halfWidth = CGRectGetWidth(extent) * 0.5;
    CGRect leftRect = CGRectMake(CGRectGetMinX(extent), CGRectGetMinY(extent), halfWidth, CGRectGetHeight(extent));
    CIImage *left = [image imageByCroppingToRect:leftRect];
    CGAffineTransform transform = CGAffineTransformMake(-1, 0, 0, 1, CGRectGetWidth(extent), 0);
    CIImage *mirroredHalf = [left imageByApplyingTransform:transform];
    CIImage *background = SpliceKitLiveCamSolidColorImage([CIColor colorWithRed:0 green:0 blue:0 alpha:1], extent);
    background = [mirroredHalf imageByCompositingOverImage:background];
    background = [left imageByCompositingOverImage:background];
    return mirrored ? background : [background imageByCroppingToRect:extent];
}

- (CIImage *)composeSlitScanForImage:(CIImage *)image {
    CGRect extent = image.extent;
    if (CGRectIsEmpty(extent)) return image;

    [self.trailFrames insertObject:image atIndex:0];
    while (self.trailFrames.count > 10) {
        [self.trailFrames removeLastObject];
    }
    if (self.trailFrames.count < 2) return image;

    NSInteger slices = MIN((NSInteger)self.trailFrames.count, 8);
    CGFloat sliceWidth = CGRectGetWidth(extent) / (CGFloat)slices;
    CIImage *background = SpliceKitLiveCamSolidColorImage([CIColor colorWithRed:0 green:0 blue:0 alpha:1], extent);

    for (NSInteger idx = 0; idx < slices; idx++) {
        CIImage *frame = self.trailFrames[MIN(idx, (NSInteger)self.trailFrames.count - 1)];
        CGRect sliceRect = CGRectMake(CGRectGetMinX(extent) + sliceWidth * idx,
                                      CGRectGetMinY(extent),
                                      idx == slices - 1 ? CGRectGetWidth(extent) - sliceWidth * idx : sliceWidth,
                                      CGRectGetHeight(extent));
        CIImage *slice = [[frame imageByCroppingToRect:sliceRect] imageByCroppingToRect:sliceRect];
        background = [slice imageByCompositingOverImage:background];
    }
    return background;
}

- (void)resetMaskHistory {
    if (self.maskHistoryFrames > 0) {
        SpliceKit_log(@"[LiveCamPerf] resetMaskHistory: released materialized history after %lu masks",
                      (unsigned long)self.maskHistoryFrames);
    }
    self.previousMaskForBlend = nil;
    self.previousMaskSourceGeneration = 0;
    self.previousMaskConfigurationValid = NO;
    self.maskHistoryFrames = 0;
    if (self.maskHistoryPool) {
        CVPixelBufferPoolFlush(self.maskHistoryPool, kCVPixelBufferPoolFlushExcessBuffers);
    }
}

// CIImage is a lazy recipe, not a pixel snapshot. Keeping a filtered CIImage as
// feedback for the next frame creates mask[n] -> mask[n-1] -> ... forever. Core
// Image recursively walks that graph during recording and eventually exhausts
// the 544 KB capture-queue stack. Materialize each completed mask into a bounded
// pool-backed pixel buffer so feedback always has constant graph depth.
- (CIImage *)materializedMaskForHistory:(CIImage *)mask extent:(CGRect)extent {
    if (!mask || CGRectIsEmpty(extent) || !self.ciContext) return nil;

    size_t width = (size_t)MAX(1.0, ceil(CGRectGetWidth(extent)));
    size_t height = (size_t)MAX(1.0, ceil(CGRectGetHeight(extent)));
    if (!self.maskHistoryPool || self.maskHistoryWidth != width || self.maskHistoryHeight != height) {
        if (self.maskHistoryPool) {
            CVPixelBufferPoolRelease(self.maskHistoryPool);
            self.maskHistoryPool = NULL;
        }

        NSDictionary *poolAttributes = @{
            (id)kCVPixelBufferPoolMinimumBufferCountKey: @3,
        };
        NSDictionary *bufferAttributes = @{
            (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_OneComponent8),
            (id)kCVPixelBufferWidthKey: @(width),
            (id)kCVPixelBufferHeightKey: @(height),
            (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
            (id)kCVPixelBufferMetalCompatibilityKey: @YES,
        };
        CVReturn poolStatus = CVPixelBufferPoolCreate(kCFAllocatorDefault,
                                                       (__bridge CFDictionaryRef)poolAttributes,
                                                       (__bridge CFDictionaryRef)bufferAttributes,
                                                       &_maskHistoryPool);
        if (poolStatus != kCVReturnSuccess || !self.maskHistoryPool) {
            SpliceKit_log(@"[LiveCamPerf] mask history pool creation failed (%d) for %zux%zu",
                          (int)poolStatus, width, height);
            self.maskHistoryWidth = 0;
            self.maskHistoryHeight = 0;
            return nil;
        }
        self.maskHistoryWidth = width;
        self.maskHistoryHeight = height;
        SpliceKit_log(@"[LiveCamPerf] materialized mask history ready at %zux%zu", width, height);
    }

    CVPixelBufferRef historyBuffer = NULL;
    NSDictionary *allocationLimit = @{
        (id)kCVPixelBufferPoolAllocationThresholdKey: @8,
    };
    CVReturn bufferStatus = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
        kCFAllocatorDefault,
        self.maskHistoryPool,
        (__bridge CFDictionaryRef)allocationLimit,
        &historyBuffer);
    if (bufferStatus != kCVReturnSuccess || !historyBuffer) {
        SpliceKit_log(@"[LiveCamPerf] mask history buffer unavailable (%d); using current-frame mask without feedback",
                      (int)bufferStatus);
        return nil;
    }

    CGRect targetExtent = CGRectMake(0, 0, width, height);
    CIImage *normalized = mask;
    if (fabs(CGRectGetMinX(extent)) > 0.001 || fabs(CGRectGetMinY(extent)) > 0.001) {
        normalized = [mask imageByApplyingTransform:CGAffineTransformMakeTranslation(-CGRectGetMinX(extent),
                                                                                     -CGRectGetMinY(extent))];
    }
    normalized = [normalized imageByCroppingToRect:targetExtent];
    [self.ciContext render:normalized
           toCVPixelBuffer:historyBuffer
                    bounds:targetExtent
                colorSpace:nil];

    CIImage *materialized = [CIImage imageWithCVPixelBuffer:historyBuffer
                                                   options:@{ kCIImageColorSpace: [NSNull null] }];
    CVPixelBufferRelease(historyBuffer);
    if (!materialized) return nil;

    materialized = [materialized imageByCroppingToRect:targetExtent];
    if (fabs(CGRectGetMinX(extent)) > 0.001 || fabs(CGRectGetMinY(extent)) > 0.001) {
        materialized = [materialized imageByApplyingTransform:CGAffineTransformMakeTranslation(CGRectGetMinX(extent),
                                                                                                CGRectGetMinY(extent))];
    }
    return [materialized imageByCroppingToRect:extent];
}

// Checkerboard composited under transparent preview only — never written to disk.
// The recording path receives the original alpha-bearing image untouched.
- (CIImage *)previewCheckerboardForExtent:(CGRect)extent {
    CIFilter *checker = [CIFilter filterWithName:@"CICheckerboardGenerator"];
    [checker setValue:[CIVector vectorWithX:0 Y:0] forKey:kCIInputCenterKey];
    [checker setValue:[CIColor colorWithRed:0.18 green:0.18 blue:0.20 alpha:1.0] forKey:@"inputColor0"];
    [checker setValue:[CIColor colorWithRed:0.10 green:0.10 blue:0.12 alpha:1.0] forKey:@"inputColor1"];
    [checker setValue:@(MAX(8.0, MIN(extent.size.width, extent.size.height) / 36.0)) forKey:kCIInputWidthKey];
    [checker setValue:@(0.0) forKey:@"inputSharpness"];
    CIImage *board = checker.outputImage;
    if (!board) return nil;
    return [board imageByCroppingToRect:extent];
}

- (CIImage *)imageByCompositingOverPreviewCheckerboard:(CIImage *)alphaImage {
    if (!alphaImage) return nil;
    CGRect extent = alphaImage.extent;
    CIImage *board = [self previewCheckerboardForExtent:extent];
    if (!board) return alphaImage;
    return [[alphaImage imageByCompositingOverImage:board] imageByCroppingToRect:extent];
}

- (CIImage *)applyColorKernelNamed:(NSString *)name
                          toExtent:(CGRect)extent
                         arguments:(NSArray<id> *)arguments {
    CIKernel *kernel = self.kernels[name];
    if (!kernel) return nil;
    if ([kernel isKindOfClass:[CIColorKernel class]]) {
        return [(CIColorKernel *)kernel applyWithExtent:extent arguments:arguments];
    }
    return [kernel applyWithExtent:extent
                       roiCallback:^CGRect(int index, CGRect destRect) {
                           return CGRectInset(destRect, -16.0, -16.0);
                       }
                         arguments:arguments];
}

- (CIImage *)refinedMaskFor:(CIImage *)rawMask
                      guide:(CIImage *)guideImage
                 background:(CIImage *)backgroundImage
                     params:(SpliceKitLiveCamMaskParams *)params
                     extent:(CGRect)extent {
    BOOL sameSource = self.previousMaskForBlend &&
        self.previousMaskConfigurationValid &&
        params.sourceGeneration == self.previousMaskSourceGeneration &&
        fabs(params.edgeSoftness - self.previousMaskEdgeSoftness) < 0.0001 &&
        fabs(params.refinement - self.previousMaskRefinement) < 0.0001 &&
        fabs(params.choke - self.previousMaskChoke) < 0.0001 &&
        fabs(params.temporalSmoothing - self.previousMaskTemporalSmoothing) < 0.0001 &&
        self.maskHistoryWidth == (size_t)MAX(1.0, ceil(CGRectGetWidth(extent))) &&
        self.maskHistoryHeight == (size_t)MAX(1.0, ceil(CGRectGetHeight(extent)));
    if (sameSource) {
        // Vision intentionally updates every other capture frame. Reuse the
        // already-materialized matte on the intervening frame instead of
        // repeating morphology, blur, temporal blend, and a GPU render.
        return self.previousMaskForBlend;
    }

    CIImage *mask = [self imageFittedForCanvas:rawMask canvasSize:extent.size fill:YES];
    mask = [mask imageByCroppingToRect:extent];

    // Signed morphology on the mask: positive dilates (grows the cutout so more
    // of the subject is kept), negative erodes (shrinks it so edge halo goes
    // away). Matches FCP's own Background Remover "Contour" parameter semantics
    // and uses Apple's Metal-backed CIMorphology filters.
    if (fabs(params.refinement) > 0.02) {
        CGFloat radius = fabs(params.refinement) * 8.0;
        NSString *filterName = (params.refinement > 0) ? @"CIMorphologyMaximum" : @"CIMorphologyMinimum";
        CIImage *shaped = SpliceKitLiveCamApplyFilter(mask, filterName, @{
            kCIInputRadiusKey: @(radius),
        });
        if (shaped) mask = [shaped imageByCroppingToRect:extent];
    }

    // Choke before feathering so the gaussian softens the *new* boundary.
    if (fabs(params.choke) > 0.01) {
        CIImage *choked = [self applyColorKernelNamed:@"maskChoke"
                                             toExtent:extent
                                            arguments:@[mask, @(params.choke)]];
        if (choked) mask = [choked imageByCroppingToRect:extent];
    }

    // Temporal EMA against the previously composited mask. Killer for live video.
    if (params.temporalSmoothing > 0.01 && self.previousMaskForBlend) {
        CIImage *prev = [self imageFittedForCanvas:self.previousMaskForBlend
                                        canvasSize:extent.size
                                              fill:YES];
        prev = [prev imageByCroppingToRect:extent];
        CIImage *blended = [self applyColorKernelNamed:@"maskTemporalBlend"
                                              toExtent:extent
                                             arguments:@[mask, prev, @(params.temporalSmoothing)]];
        if (blended) mask = [blended imageByCroppingToRect:extent];
    }

    if (params.edgeSoftness > 0.01) {
        mask = SpliceKitLiveCamApplyFilter(mask, @"CIGaussianBlur", @{
            kCIInputRadiusKey: @(params.edgeSoftness * 6.0),
        });
        mask = [mask imageByCroppingToRect:extent];
    }

    CIImage *materialized = [self materializedMaskForHistory:mask extent:extent];
    if (materialized) {
        self.previousMaskForBlend = materialized;
        self.previousMaskSourceGeneration = params.sourceGeneration;
        self.previousMaskEdgeSoftness = params.edgeSoftness;
        self.previousMaskRefinement = params.refinement;
        self.previousMaskChoke = params.choke;
        self.previousMaskTemporalSmoothing = params.temporalSmoothing;
        self.previousMaskConfigurationValid = YES;
        self.maskHistoryFrames += 1;
        return materialized;
    }

    // Allocation/render failure must degrade to a single-frame mask. Never
    // retain the lazy result, or the recursive graph and crash return.
    self.previousMaskForBlend = nil;
    self.previousMaskConfigurationValid = NO;
    return mask;
}

- (CIImage *)renderedImageFromImage:(CIImage *)image
                             preset:(SpliceKitLiveCamPreset *)preset
                               time:(NSTimeInterval)time
                        adjustments:(SpliceKitLiveCamAdjustmentState *)adjustments
                          maskImage:(CIImage *)maskImage
                         maskParams:(SpliceKitLiveCamMaskParams *)maskParams
                    backgroundColor:(CIColor *)backgroundColor
                           mirrored:(BOOL)mirrored
                          recording:(BOOL)recording
                         canvasSize:(CGSize)canvasSize {
    if (!image) return nil;
    CGRect originalExtent = image.extent;
    NSString *identifier = preset.identifier ?: @"clean";
    CGFloat intensity = MAX(0.0, adjustments.intensity);

    if (mirrored) {
        CGFloat tx = CGRectGetMinX(originalExtent) + CGRectGetMaxX(originalExtent);
        CGAffineTransform mirrorTransform = CGAffineTransformMake(-1, 0, 0, 1, tx, 0);
        image = [[image imageByApplyingTransform:mirrorTransform] imageByCroppingToRect:originalExtent];
    }

    if (maskImage) {
        BOOL transparent = maskParams.transparentBackground;
        CIImage *background = SpliceKitLiveCamSolidColorImage(transparent
                                                              ? [CIColor colorWithRed:0 green:0 blue:0 alpha:0]
                                                              : (backgroundColor ?: SpliceKitLiveCamBackgroundCIColor(@"green")),
                                                              originalExtent);
        CIImage *mask = [self refinedMaskFor:maskImage
                                       guide:image
                                  background:background
                                      params:maskParams
                                      extent:originalExtent];

        if (maskParams.spill > 0.01) {
            CIImage *suppressed = [self applyColorKernelNamed:@"spillSuppress"
                                                     toExtent:originalExtent
                                                    arguments:@[image, mask, @(maskParams.spill)]];
            if (suppressed) image = [suppressed imageByCroppingToRect:originalExtent];
        }

        // Light wrap only makes sense when compositing onto a real background;
        // it would just dim the alpha edge in transparent mode.
        if (!transparent && maskParams.wrap > 0.01) {
            CIImage *wrapped = [self applyColorKernelNamed:@"lightWrap"
                                                  toExtent:originalExtent
                                                 arguments:@[image, mask, background, @(maskParams.wrap)]];
            if (wrapped) image = [wrapped imageByCroppingToRect:originalExtent];
        }

        image = SpliceKitLiveCamApplyFilter(image, @"CIBlendWithMask", @{
            kCIInputBackgroundImageKey: background,
            kCIInputMaskImageKey: mask,
        });
        image = [image imageByCroppingToRect:originalExtent];
    } else {
        // No mask this frame — drop history so the next composite starts clean.
        [self resetMaskHistory];
    }

    if (fabs(adjustments.exposure) > 0.001) {
        image = SpliceKitLiveCamApplyFilter(image, @"CIExposureAdjust", @{
            kCIInputEVKey: @(adjustments.exposure * 1.6),
        });
    }
    image = SpliceKitLiveCamApplyFilter(image, @"CIColorControls", @{
        kCIInputContrastKey: @(MAX(0.2, adjustments.contrast)),
        kCIInputSaturationKey: @(MAX(0.0, adjustments.saturation)),
    });
    if (fabs(adjustments.temperature) > 0.01) {
        CIVector *neutral = [CIVector vectorWithX:6500 Y:0];
        CIVector *target = [CIVector vectorWithX:(6500.0 + adjustments.temperature * 2400.0) Y:0];
        image = SpliceKitLiveCamApplyFilter(image, @"CITemperatureAndTint", @{
            @"inputNeutral": neutral,
            @"inputTargetNeutral": target,
        });
    }
    if (adjustments.sharpness > 0.01) {
        image = SpliceKitLiveCamApplyFilter(image, @"CISharpenLuminance", @{
            kCIInputSharpnessKey: @(adjustments.sharpness * 1.8),
        });
    }
    if (adjustments.glow > 0.01) {
        image = SpliceKitLiveCamApplyFilter(image, @"CIBloom", @{
            kCIInputRadiusKey: @(6.0 + adjustments.glow * 12.0),
            kCIInputIntensityKey: @(0.15 + adjustments.glow * 0.55),
        });
    }

    if ([identifier isEqualToString:@"vhs"]) {
        image = SpliceKitLiveCamApplyFilter(image, @"CIGaussianBlur", @{ kCIInputRadiusKey: @(0.8 + intensity * 1.3) });
        image = [self applyWarpKernelNamed:@"vhsWarp" toImage:image arguments:@[@(time), @(0.18 + intensity * 0.28)]];
        image = [self applyColorKernelNamed:@"rgbSplit" toImage:image arguments:@[image, @(0.7 + intensity * 2.2), @(0.15)]];
        CIImage *noise = [self noiseImageForExtent:image.extent alpha:(0.05 + intensity * 0.08) monochrome:NO];
        if (noise) image = [noise imageByCompositingOverImage:image];
        image = [self applyColorKernelNamed:@"scanline" toImage:image arguments:@[image, @(0.22 + intensity * 0.25), @(time)]];
        image = SpliceKitLiveCamApplyFilter(image, @"CIColorControls", @{
            kCIInputContrastKey: @(0.92),
            kCIInputSaturationKey: @(0.82),
        });
    } else if ([identifier isEqualToString:@"webcamFry"]) {
        image = SpliceKitLiveCamApplyFilter(image, @"CISharpenLuminance", @{ kCIInputSharpnessKey: @(1.2 + intensity * 1.6) });
        image = SpliceKitLiveCamApplyFilter(image, @"CIColorControls", @{
            kCIInputContrastKey: @(1.28 + intensity * 0.55),
            kCIInputSaturationKey: @(1.05 + intensity * 0.35),
        });
        image = SpliceKitLiveCamApplyFilter(image, @"CIHighlightShadowAdjust", @{
            @"inputHighlightAmount": @(0.0),
            @"inputShadowAmount": @(0.35),
        });
        image = SpliceKitLiveCamApplyFilter(image, @"CIColorPosterize", @{ @"inputLevels": @(18.0 - intensity * 7.0) });
    } else if ([identifier isEqualToString:@"crt"]) {
        image = [self applyWarpKernelNamed:@"bulgeWarp" toImage:image arguments:@[@(0.14 + intensity * 0.16), @(CGRectGetWidth(image.extent)), @(CGRectGetHeight(image.extent))]];
        image = [self applyColorKernelNamed:@"scanline" toImage:image arguments:@[image, @(0.42 + intensity * 0.3), @(time)]];
        image = [self applyColorKernelNamed:@"rgbSplit" toImage:image arguments:@[image, @(0.8 + intensity * 1.8), @(0.2)]];
        image = SpliceKitLiveCamApplyFilter(image, @"CIBloom", @{
            kCIInputRadiusKey: @(8.0),
            kCIInputIntensityKey: @(0.18 + intensity * 0.28),
        });
        image = SpliceKitLiveCamApplyFilter(image, @"CIVignette", @{
            kCIInputIntensityKey: @(0.52),
            kCIInputRadiusKey: @(1.45),
        });
    } else if ([identifier isEqualToString:@"securityCam"]) {
        image = SpliceKitLiveCamApplyFilter(image, @"CIPhotoEffectMono", @{});
        image = SpliceKitLiveCamApplyFilter(image, @"CIFalseColor", @{
            @"inputColor0": [CIColor colorWithRed:0.05 green:0.11 blue:0.05 alpha:1],
            @"inputColor1": [CIColor colorWithRed:0.52 green:1.00 blue:0.62 alpha:1],
        });
        image = SpliceKitLiveCamApplyFilter(image, @"CIColorControls", @{
            kCIInputContrastKey: @(1.35),
            kCIInputSaturationKey: @(0.6),
        });
        CIImage *noise = [self noiseImageForExtent:image.extent alpha:(0.08 + intensity * 0.08) monochrome:YES];
        if (noise) image = [noise imageByCompositingOverImage:image];
    } else if ([identifier isEqualToString:@"thermalFalseColor"]) {
        image = SpliceKitLiveCamApplyFilter(image, @"CIColorControls", @{
            kCIInputSaturationKey: @0.0,
            kCIInputContrastKey: @(1.25),
        });
        image = [self applyColorKernelNamed:@"thermal" toImage:image arguments:@[image]];
        image = SpliceKitLiveCamApplyFilter(image, @"CISharpenLuminance", @{ kCIInputSharpnessKey: @(0.7) });
    } else if ([identifier isEqualToString:@"comicPoster"]) {
        image = SpliceKitLiveCamApplyFilter(image, @"CIComicEffect", @{});
        image = SpliceKitLiveCamApplyFilter(image, @"CIColorPosterize", @{ @"inputLevels": @(6.0 + intensity * 3.0) });
    } else if ([identifier isEqualToString:@"dreamGlow"]) {
        image = SpliceKitLiveCamApplyFilter(image, @"CIBloom", @{
            kCIInputRadiusKey: @(15.0 + intensity * 12.0),
            kCIInputIntensityKey: @(0.4 + intensity * 0.5),
        });
        image = SpliceKitLiveCamApplyFilter(image, @"CIColorControls", @{
            kCIInputContrastKey: @(0.86),
            kCIInputSaturationKey: @(0.92),
        });
        image = SpliceKitLiveCamApplyFilter(image, @"CITemperatureAndTint", @{
            @"inputNeutral": [CIVector vectorWithX:6500 Y:0],
            @"inputTargetNeutral": [CIVector vectorWithX:7800 Y:0],
        });
    } else if ([identifier isEqualToString:@"mirrorSplit"]) {
        image = [self composeSplitImage:image mirrored:mirrored];
    } else if ([identifier isEqualToString:@"kaleidoscope"]) {
        image = SpliceKitLiveCamApplyFilter(image, @"CIKaleidoscope", @{
            kCIInputCenterKey: [CIVector vectorWithX:CGRectGetMidX(image.extent) Y:CGRectGetMidY(image.extent)],
            @"inputCount": @(6.0 + round(intensity * 2.0)),
            kCIInputAngleKey: @(time * 0.18),
        });
    } else if ([identifier isEqualToString:@"rgbSplit"]) {
        image = [self applyColorKernelNamed:@"rgbSplit" toImage:image arguments:@[image, @(1.0 + intensity * 5.0), @(0.3 + intensity * 1.4)]];
    } else if ([identifier isEqualToString:@"glitchJitter"]) {
        image = [self applyColorKernelNamed:@"glitch" toImage:image arguments:@[image, @(time), @(0.28 + intensity * 0.45)]];
        image = [self applyColorKernelNamed:@"rgbSplit" toImage:image arguments:@[image, @(0.6 + intensity * 2.5), @(0.0)]];
    } else if ([identifier isEqualToString:@"oldCamcorder"]) {
        image = SpliceKitLiveCamApplyFilter(image, @"CIColorControls", @{
            kCIInputContrastKey: @(1.02),
            kCIInputSaturationKey: @(0.82),
        });
        image = SpliceKitLiveCamApplyFilter(image, @"CITemperatureAndTint", @{
            @"inputNeutral": [CIVector vectorWithX:6500 Y:0],
            @"inputTargetNeutral": [CIVector vectorWithX:5200 Y:0],
        });
        image = [self applyWarpKernelNamed:@"vhsWarp" toImage:image arguments:@[@(time), @(0.08 + intensity * 0.12)]];
        image = [self applyColorKernelNamed:@"scanline" toImage:image arguments:@[image, @(0.12), @(time)]];
    } else if ([identifier isEqualToString:@"badVideoCall"]) {
        image = SpliceKitLiveCamApplyFilter(image, @"CIPixellate", @{ kCIInputScaleKey: @(5.0 + intensity * 10.0) });
        image = SpliceKitLiveCamApplyFilter(image, @"CIColorControls", @{
            kCIInputContrastKey: @(1.2 + intensity * 0.25),
            kCIInputSaturationKey: @(0.74),
        });
        image = [self applyColorKernelNamed:@"glitch" toImage:image arguments:@[image, @(time), @(0.16 + intensity * 0.25)]];
    } else if ([identifier isEqualToString:@"liquidWarp"]) {
        image = [self applyWarpKernelNamed:@"liquidWarp" toImage:image arguments:@[@(time), @(0.12 + intensity * 0.4)]];
    } else if ([identifier isEqualToString:@"slitScanTrail"]) {
        image = [self composeSlitScanForImage:image];
    } else if ([identifier isEqualToString:@"fisheyeBulge"]) {
        image = [self applyWarpKernelNamed:@"bulgeWarp" toImage:image arguments:@[@(0.2 + intensity * 0.24), @(CGRectGetWidth(image.extent)), @(CGRectGetHeight(image.extent))]];
        image = SpliceKitLiveCamApplyFilter(image, @"CIVignette", @{
            kCIInputIntensityKey: @(0.24),
            kCIInputRadiusKey: @(1.6),
        });
    } else if ([identifier isEqualToString:@"neonStream"]) {
        CIImage *edges = SpliceKitLiveCamApplyFilter(image, @"CIEdges", @{ kCIInputIntensityKey: @(8.0 + intensity * 6.0) });
        edges = SpliceKitLiveCamApplyFilter(edges, @"CIColorInvert", @{});
        edges = SpliceKitLiveCamApplyFilter(edges, @"CIColorControls", @{
            kCIInputSaturationKey: @(1.8),
            kCIInputContrastKey: @(1.25),
        });
        image = [edges imageByCompositingOverImage:image];
        image = SpliceKitLiveCamApplyFilter(image, @"CIBloom", @{
            kCIInputRadiusKey: @(10.0),
            kCIInputIntensityKey: @(0.22 + intensity * 0.25),
        });
    } else if ([identifier isEqualToString:@"faceCamPunch"]) {
        CGRect extent = image.extent;
        CGFloat scale = 1.07 + intensity * 0.13;
        CIImage *scaled = [image imageByApplyingTransform:CGAffineTransformMakeScale(scale, scale)];
        CGRect scaledExtent = scaled.extent;
        CGFloat tx = CGRectGetMidX(extent) - CGRectGetMidX(scaledExtent);
        CGFloat ty = CGRectGetMidY(extent) - CGRectGetMidY(scaledExtent);
        image = [[scaled imageByApplyingTransform:CGAffineTransformMakeTranslation(tx, ty)] imageByCroppingToRect:extent];
        image = SpliceKitLiveCamApplyFilter(image, @"CIVignette", @{
            kCIInputIntensityKey: @(0.22 + intensity * 0.18),
            kCIInputRadiusKey: @(1.2),
        });
    }

    NSString *timestamp = nil;
    if (SpliceKitLiveCamTimestampOverlayEnabled() &&
        SpliceKitLiveCamPresetSupportsTimestampOverlay(identifier)) {
        timestamp = [NSDateFormatter localizedStringFromDate:[NSDate date]
                                                   dateStyle:NSDateFormatterShortStyle
                                                   timeStyle:NSDateFormatterMediumStyle];
        NSColor *tint = [identifier isEqualToString:@"securityCam"]
            ? [NSColor colorWithRed:0.80 green:1.00 blue:0.84 alpha:0.95]
            : [NSColor colorWithRed:1.00 green:0.93 blue:0.82 alpha:0.95];
        NSString *prefix = [identifier isEqualToString:@"badVideoCall"] ? @"NET UNSTABLE" : @"";
        CIImage *overlay = [self timestampOverlayForExtent:image.extent timestamp:timestamp tint:tint prefix:prefix];
        if (overlay) image = [overlay imageByCompositingOverImage:image];
    }

    if (recording) {
        NSString *clock = [NSDateFormatter localizedStringFromDate:[NSDate date]
                                                         dateStyle:NSDateFormatterNoStyle
                                                         timeStyle:NSDateFormatterMediumStyle];
        CIImage *recOverlay = [self recordingOverlayForExtent:image.extent timestamp:clock];
        if (recOverlay) image = [recOverlay imageByCompositingOverImage:image];
    }

    // Keep alpha intact for transparent-background mode. The preview path adds
    // its checkerboard later, and the recording path needs the untouched alpha
    // frame for ProRes 4444 output.
    BOOL preserveOutputAlpha = (maskParams != nil && maskParams.transparentBackground);
    return [self imageFittedForCanvas:[image imageByCroppingToRect:image.extent]
                           canvasSize:canvasSize
                                 fill:NO
                        preserveAlpha:preserveOutputAlpha];
}

@end

@interface SpliceKitLiveCamPanel () <AVCaptureVideoDataOutputSampleBufferDelegate,
                                     AVCaptureAudioDataOutputSampleBufferDelegate,
                                     MTKViewDelegate,
                                     NSWindowDelegate,
                                     NSTextFieldDelegate>
@property (nonatomic, strong) NSPanel *panel;
@property (nonatomic, strong) MTKView *previewView;
@property (nonatomic, strong) NSTextField *statusLabel;
@property (nonatomic, strong) NSTextField *presetLabel;
@property (nonatomic, strong) NSTextField *elapsedLabel;
@property (nonatomic, strong) NSTextField *sessionLabel;
@property (nonatomic, strong) NSButton *permissionButton;
@property (nonatomic, strong) NSTextField *lookDescriptionLabel;
@property (nonatomic, strong) NSTextField *destinationHintLabel;
@property (nonatomic, strong) NSTextField *backgroundInfoLabel;
@property (nonatomic, strong) NSTextField *backgroundStatusLabel;
@property (nonatomic, strong) NSTextField *nameHintLabel;
@property (nonatomic, strong) SpliceKitLiveCamAudioMeterView *audioMeter;
@property (nonatomic, strong) NSPopUpButton *lookCategoryPopup;
@property (nonatomic, strong) NSPopUpButton *lookPresetPopup;
@property (nonatomic, strong) NSPopUpButton *backgroundModePopup;
@property (nonatomic, strong) NSPopUpButton *backgroundColorPopup;
@property (nonatomic, strong) NSPopUpButton *cameraPopup;
@property (nonatomic, strong) NSPopUpButton *microphonePopup;
@property (nonatomic, strong) NSPopUpButton *resolutionPopup;
@property (nonatomic, strong) NSPopUpButton *frameRatePopup;
@property (nonatomic, strong) NSPopUpButton *qualityPopup;
@property (nonatomic, strong) NSPopUpButton *timelinePlacementPopup;
@property (nonatomic, strong) NSSegmentedControl *destinationControl;
@property (nonatomic, strong) NSTextField *clipNameField;
@property (nonatomic, strong) NSTextField *eventNameField;
@property (nonatomic, strong) NSSlider *backgroundEdgeSlider;
@property (nonatomic, strong) NSSlider *backgroundRefinementSlider;
@property (nonatomic, strong) NSSlider *backgroundChokeSlider;
@property (nonatomic, strong) NSSlider *backgroundSpillSlider;
@property (nonatomic, strong) NSSlider *backgroundWrapSlider;
@property (nonatomic, strong) NSPopUpButton *backgroundQualityPopup;
@property (nonatomic, strong) NSSlider *intensitySlider;
@property (nonatomic, strong) NSSlider *exposureSlider;
@property (nonatomic, strong) NSSlider *contrastSlider;
@property (nonatomic, strong) NSSlider *saturationSlider;
@property (nonatomic, strong) NSSlider *temperatureSlider;
@property (nonatomic, strong) NSSlider *sharpnessSlider;
@property (nonatomic, strong) NSSlider *glowSlider;
@property (nonatomic, strong) NSButton *mirrorCheckbox;
@property (nonatomic, strong) NSButton *muteCheckbox;
@property (nonatomic, strong) NSButton *timestampOverlayCheckbox;
@property (nonatomic, strong) NSButton *openVideoEffectsButton;
@property (nonatomic, strong) NSButton *advancedToggleButton;
@property (nonatomic, strong) NSButton *recordButton;
@property (nonatomic, strong) NSButton *stopButton;
@property (nonatomic, strong) NSView *advancedContainer;
@property (nonatomic, strong) NSView *advancedSectionCard;
@property (nonatomic, strong) NSView *advancedKeyingGroup;
@property (nonatomic, strong) NSView *mainColumn;
@property (nonatomic, strong) NSView *timelinePlacementRow;
@property (nonatomic, strong) NSView *backgroundColorRow;
@property (nonatomic, strong) NSView *backgroundEdgeRow;
@property (nonatomic, strong) NSArray<AVCaptureDevice *> *videoDevices;
@property (nonatomic, strong) NSArray<AVCaptureDevice *> *audioDevices;
@property (nonatomic, strong) NSArray<SpliceKitLiveCamPreset *> *presets;
@property (nonatomic, strong) NSArray<NSString *> *presetCategories;
@property (nonatomic, strong) SpliceKitLiveCamRenderer *renderer;
@property (nonatomic, strong) SpliceKitLiveCamSegmentationEngine *segmentationEngine;
@property (nonatomic, strong) SpliceKitLiveCamAdjustmentState *adjustments;
@property (nonatomic, strong) dispatch_queue_t sessionQueue;
@property (nonatomic, strong) dispatch_queue_t videoQueue;
@property (nonatomic, strong) dispatch_queue_t audioQueue;
@property (nonatomic, strong) AVCaptureSession *session;
@property (nonatomic, strong) AVCaptureDeviceInput *videoInput;
@property (nonatomic, strong) AVCaptureDeviceInput *audioInput;
@property (nonatomic, strong) AVCaptureVideoDataOutput *videoOutput;
@property (nonatomic, strong) AVCaptureAudioDataOutput *audioOutput;
@property (nonatomic, strong) CIImage *latestPreviewImage;
@property (nonatomic, assign) BOOL previewDrawPending;
@property (nonatomic, assign) BOOL cameraAuthorized;
@property (nonatomic, assign) BOOL microphoneAuthorized;
@property (nonatomic, assign) BOOL recordingActive;
@property (nonatomic, assign) BOOL finalizingRecording;
@property (nonatomic, assign) BOOL writerDidStart;
@property (nonatomic, assign) CMTime writerStartTime;
@property (nonatomic, strong) AVAssetWriter *assetWriter;
@property (nonatomic, strong) AVAssetWriterInput *videoWriterInput;
@property (nonatomic, strong) AVAssetWriterInput *audioWriterInput;
@property (nonatomic, strong) AVAssetWriterInputPixelBufferAdaptor *pixelBufferAdaptor;
@property (nonatomic, assign) CGSize recordingCanvasSize;
@property (nonatomic, assign) BOOL recordingIsTransparent;
@property (nonatomic, strong) NSURL *temporaryRecordingURL;
@property (nonatomic, strong) NSURL *finalRecordingURL;
@property (nonatomic, strong) NSDictionary *recordingSequenceIdentity;
@property (nonatomic, assign) SpliceKitLiveCamDestination recordingDestination;
@property (nonatomic, assign) SpliceKitLiveCamTimelinePlacement recordingPlacement;
@property (nonatomic, copy) NSString *recordingClipName;
@property (nonatomic, copy) NSString *recordingEventName;
@property (nonatomic, strong) NSTimer *elapsedTimer;
@property (nonatomic, strong) NSDate *recordingStartDate;
@property (nonatomic, assign) NSUInteger droppedVideoFrames;
@property (nonatomic, assign) NSUInteger droppedAudioFrames;
@property (atomic, assign) NSUInteger sourceAudioDiscontinuities;
@property (atomic, assign) NSUInteger sourceAudioGapFrames;
@property (atomic, assign) double capturedAudioSampleRate;
@property (atomic, assign) NSUInteger capturedAudioChannels;
@property (nonatomic, assign) CMTime expectedNextAudioPTS;
@property (nonatomic, assign) BOOL audioFormatLogged;
@property (nonatomic, assign) NSTimeInterval lastAudioMeterDispatchTime;
@property (atomic, assign) NSUInteger audioMeterBuffersReceived;
@property (atomic, assign) NSUInteger audioMeterDecodedSamples;
@property (atomic, assign) OSStatus audioMeterLastError;
@property (nonatomic, assign) NSUInteger perfFrameCount;
@property (nonatomic, assign) double perfFrameMsSum;
@property (nonatomic, assign) double perfFrameMsMax;
@property (nonatomic, assign) NSTimeInterval perfLastLogTime;
@property (nonatomic, assign) double smoothedAudioLevel;
@property (nonatomic, assign) BOOL systemBlurSupported;
@property (nonatomic, assign) BOOL systemBlurActive;
@property (nonatomic, assign) BOOL centerStageSupported;
@property (nonatomic, assign) BOOL centerStageActive;
@property (nonatomic, assign) BOOL studioLightActive;
@property (nonatomic, assign) BOOL advancedVisible;
@property (nonatomic, copy) NSArray<NSString *> *availableResolutionKeys;
@property (nonatomic, copy) NSDictionary<NSString *, NSArray<NSNumber *> *> *availableFrameRatesByResolution;
@end

@implementation SpliceKitLiveCamPanel

+ (instancetype)sharedPanel {
    static SpliceKitLiveCamPanel *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[self alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;

    _renderer = [[SpliceKitLiveCamRenderer alloc] init];
    _segmentationEngine = [[SpliceKitLiveCamSegmentationEngine alloc] init];
    _adjustments = [[SpliceKitLiveCamAdjustmentState alloc] init];
    _sessionQueue = dispatch_queue_create("com.splicekit.livecam.session", DISPATCH_QUEUE_SERIAL);
    _videoQueue = dispatch_queue_create("com.splicekit.livecam.video", DISPATCH_QUEUE_SERIAL);
    // USB audio callbacks have hard real-time-ish deadlines. Keep them ahead of
    // the much heavier Core Image / 4K encode work so memory pressure or a busy
    // video frame cannot starve the microphone callback and turn an otherwise
    // valid Shure buffer into an audible discontinuity.
    dispatch_queue_attr_t audioQueueAttributes =
        dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,
                                                 QOS_CLASS_USER_INTERACTIVE,
                                                 0);
    _audioQueue = dispatch_queue_create("com.splicekit.livecam.audio", audioQueueAttributes);
    _expectedNextAudioPTS = kCMTimeInvalid;
    _presets = @[
        [SpliceKitLiveCamPreset presetWithIdentifier:@"clean" name:@"Clean" category:@"Clean" summary:@"Natural camera image with no stylized treatment." premium:NO],
        [SpliceKitLiveCamPreset presetWithIdentifier:@"faceCamPunch" name:@"Face-Cam Punch" category:@"Clean" summary:@"Tightens the framing for quick commentary pickups." premium:NO],
        [SpliceKitLiveCamPreset presetWithIdentifier:@"vhs" name:@"VHS" category:@"Retro" summary:@"Soft tape blur, color drift, and low-fi scanlines." premium:YES],
        [SpliceKitLiveCamPreset presetWithIdentifier:@"crt" name:@"CRT" category:@"Retro" summary:@"Curved glass, scanlines, bloom, and phosphor contrast." premium:YES],
        [SpliceKitLiveCamPreset presetWithIdentifier:@"oldCamcorder" name:@"Old Camcorder" category:@"Retro" summary:@"Timestamped tape-era color and handheld camcorder texture." premium:YES],
        [SpliceKitLiveCamPreset presetWithIdentifier:@"securityCam" name:@"Security Cam" category:@"Retro" summary:@"Green monochrome surveillance look with timestamp overlay." premium:YES],
        [SpliceKitLiveCamPreset presetWithIdentifier:@"webcamFry" name:@"Webcam Fry" category:@"Glitch" summary:@"Harsh sharpening, ugly compression, and clipped digital contrast." premium:YES],
        [SpliceKitLiveCamPreset presetWithIdentifier:@"rgbSplit" name:@"RGB Split" category:@"Glitch" summary:@"Chromatic channel drift for streamer-style aberration." premium:YES],
        [SpliceKitLiveCamPreset presetWithIdentifier:@"glitchJitter" name:@"Glitch Jitter" category:@"Glitch" summary:@"Unstable signal jitter with blocky horizontal disruption." premium:YES],
        [SpliceKitLiveCamPreset presetWithIdentifier:@"badVideoCall" name:@"Bad Video Call" category:@"Glitch" summary:@"Blocky low-bitrate video-call ugliness with digital instability." premium:YES],
        [SpliceKitLiveCamPreset presetWithIdentifier:@"thermalFalseColor" name:@"Thermal False Color" category:@"Stylized" summary:@"Maps luminance into a bold hot-cold thermal palette." premium:YES],
        [SpliceKitLiveCamPreset presetWithIdentifier:@"comicPoster" name:@"Comic / Poster" category:@"Stylized" summary:@"Bold contour edges and reduced posterized color." premium:NO],
        [SpliceKitLiveCamPreset presetWithIdentifier:@"dreamGlow" name:@"Dream Glow" category:@"Stylized" summary:@"Bloom-heavy soft halation with a tinted haze." premium:NO],
        [SpliceKitLiveCamPreset presetWithIdentifier:@"neonStream" name:@"Neon Stream" category:@"Stylized" summary:@"Punchy saturation, edge glow, and high-energy chroma." premium:YES],
        [SpliceKitLiveCamPreset presetWithIdentifier:@"liquidWarp" name:@"Liquid Warp" category:@"Distortion" summary:@"Organic moving distortion that bends the live frame." premium:YES],
        [SpliceKitLiveCamPreset presetWithIdentifier:@"slitScanTrail" name:@"Slit-Scan Trail" category:@"Distortion" summary:@"Temporal smearing for motion-trail time distortion." premium:YES],
        [SpliceKitLiveCamPreset presetWithIdentifier:@"fisheyeBulge" name:@"Fisheye / Bulge" category:@"Distortion" summary:@"Comedic bulge-lens warp with rounded vignette." premium:YES],
        [SpliceKitLiveCamPreset presetWithIdentifier:@"mirrorSplit" name:@"Mirror Split" category:@"Distortion" summary:@"Mirrors and duplicates the frame for performance-style symmetry." premium:NO],
        [SpliceKitLiveCamPreset presetWithIdentifier:@"kaleidoscope" name:@"Kaleidoscope" category:@"Distortion" summary:@"Rotational symmetry that turns motion into geometric pattern." premium:NO],
    ];
    _presetCategories = @[@"Clean", @"Retro", @"Glitch", @"Stylized", @"Distortion"];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(deviceAvailabilityChanged:)
                                                 name:AVCaptureDeviceWasConnectedNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(deviceAvailabilityChanged:)
                                                 name:AVCaptureDeviceWasDisconnectedNotification
                                               object:nil];

    [self loadDefaults];
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (BOOL)isVisible {
    return self.panel && self.panel.isVisible;
}

- (NSDictionary *)statusSnapshot {
    NSString *presetName = @"Clean";
    for (SpliceKitLiveCamPreset *preset in self.presets) {
        if ([preset.identifier isEqualToString:[self selectedPresetIdentifier]]) {
            presetName = preset.name;
            break;
        }
    }
    return @{
        @"visible": @(self.isVisible),
        @"recording": @(self.recordingActive),
        @"finalizing": @(self.finalizingRecording),
        @"panelFrame": self.panel ? NSStringFromRect(self.panel.frame) : @"",
        @"contentSize": self.panel ? NSStringFromSize(self.panel.contentView.bounds.size) : @"",
        @"layoutBackgroundSize": self.panel ? NSStringFromSize(self.panel.contentView.subviews.firstObject.bounds.size) : @"",
        @"layoutContentHostSize": self.mainColumn ? NSStringFromSize(self.mainColumn.superview.bounds.size) : @"",
        @"layoutMainColumnSize": self.mainColumn ? NSStringFromSize(self.mainColumn.bounds.size) : @"",
        @"preset": presetName,
        @"lookCategory": [self selectedPreset].category ?: @"",
        @"destination": @([self selectedDestination]),
        @"timelinePlacement": @([self selectedTimelinePlacement]),
        @"clipName": self.clipNameField.stringValue ?: @"",
        @"eventName": self.eventNameField.stringValue ?: @"",
        @"camera": self.cameraPopup.selectedItem.title ?: @"",
        @"microphone": self.microphonePopup.selectedItem.title ?: @"",
        @"resolution": self.resolutionPopup.selectedItem.title ?: @"",
        @"frameRate": self.frameRatePopup.selectedItem.title ?: @"",
        @"quality": self.qualityPopup.selectedItem.title ?: @"",
        @"backgroundMode": @([self selectedBackgroundMode]),
        @"backgroundModeName": [self selectedBackgroundModeName] ?: @"None",
        @"timestampOverlay": @(SpliceKitLiveCamPresetSupportsTimestampOverlay([self selectedPresetIdentifier]) &&
                              [self selectedTimestampOverlayEnabled]),
        @"systemBlurSupported": @(self.systemBlurSupported),
        @"systemBlurActive": @(self.systemBlurActive),
        @"centerStageActive": @(self.centerStageActive),
        @"outputPath": self.finalRecordingURL.path ?: @"",
        @"droppedVideoFrames": @(self.droppedVideoFrames),
        @"droppedAudioFrames": @(self.droppedAudioFrames),
        @"sourceAudioDiscontinuities": @(self.sourceAudioDiscontinuities),
        @"sourceAudioGapFrames": @(self.sourceAudioGapFrames),
        @"audioSampleRate": @(self.capturedAudioSampleRate),
        @"audioChannels": @(self.capturedAudioChannels),
        @"audioLevelDB": @(self.audioMeter.rmsDB),
        @"audioPeakDB": @(self.audioMeter.peakDB),
        @"audioMeterBuffersReceived": @(self.audioMeterBuffersReceived),
        @"audioMeterDecodedSamples": @(self.audioMeterDecodedSamples),
        @"audioMeterLastError": @(self.audioMeterLastError),
    };
}

- (void)loadDefaults {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    self.adjustments.intensity = [defaults objectForKey:kLiveCamIntensityKey] ? [defaults doubleForKey:kLiveCamIntensityKey] : 0.8;
    self.adjustments.exposure = [defaults objectForKey:kLiveCamExposureKey] ? [defaults doubleForKey:kLiveCamExposureKey] : 0.0;
    self.adjustments.contrast = [defaults objectForKey:kLiveCamContrastKey] ? [defaults doubleForKey:kLiveCamContrastKey] : 1.0;
    self.adjustments.saturation = [defaults objectForKey:kLiveCamSaturationKey] ? [defaults doubleForKey:kLiveCamSaturationKey] : 1.0;
    self.adjustments.temperature = [defaults objectForKey:kLiveCamTemperatureKey] ? [defaults doubleForKey:kLiveCamTemperatureKey] : 0.0;
    self.adjustments.sharpness = [defaults objectForKey:kLiveCamSharpnessKey] ? [defaults doubleForKey:kLiveCamSharpnessKey] : 0.0;
    self.adjustments.glow = [defaults objectForKey:kLiveCamGlowKey] ? [defaults doubleForKey:kLiveCamGlowKey] : 0.0;
    self.advancedVisible = [defaults boolForKey:kLiveCamAdvancedVisibleKey];
}

- (NSString *)selectedPresetIdentifier {
    NSString *preset = [[NSUserDefaults standardUserDefaults] stringForKey:kLiveCamPresetKey];
    return preset.length > 0 ? preset : @"clean";
}

- (void)storeSelectedPresetIdentifier:(NSString *)identifier {
    NSString *resolved = identifier.length > 0 ? identifier : @"clean";
    [[NSUserDefaults standardUserDefaults] setObject:resolved forKey:kLiveCamPresetKey];
}

- (SpliceKitLiveCamPreset *)selectedPreset {
    NSString *identifier = [self selectedPresetIdentifier];
    for (SpliceKitLiveCamPreset *preset in self.presets) {
        if ([preset.identifier isEqualToString:identifier]) return preset;
    }
    return self.presets.firstObject;
}

- (BOOL)selectedTimestampOverlayEnabled {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    id stored = [defaults objectForKey:kLiveCamTimestampOverlayKey];
    if (!stored) return YES;
    return [defaults boolForKey:kLiveCamTimestampOverlayKey];
}

- (BOOL)currentTimestampOverlayEnabled {
    if (self.timestampOverlayCheckbox) {
        return self.timestampOverlayCheckbox.state == NSControlStateValueOn;
    }
    return [self selectedTimestampOverlayEnabled];
}

- (SpliceKitLiveCamDestination)selectedDestination {
    return self.destinationControl.selectedSegment == 1
        ? SpliceKitLiveCamDestinationTimeline
        : SpliceKitLiveCamDestinationLibrary;
}

- (SpliceKitLiveCamTimelinePlacement)selectedTimelinePlacement {
    switch (self.timelinePlacementPopup.indexOfSelectedItem) {
        case 1: return SpliceKitLiveCamTimelinePlacementInsertAtPlayhead;
        case 2: return SpliceKitLiveCamTimelinePlacementConnectedAbove;
        default: return SpliceKitLiveCamTimelinePlacementAppend;
    }
}

- (SpliceKitLiveCamBackgroundMode)selectedBackgroundMode {
    switch (self.backgroundModePopup.indexOfSelectedItem) {
        case 1: return SpliceKitLiveCamBackgroundModeSystemBlur;
        case 2: return SpliceKitLiveCamBackgroundModeGreenScreen;
        default: return SpliceKitLiveCamBackgroundModeNone;
    }
}

- (NSString *)selectedBackgroundModeName {
    switch ([self selectedBackgroundMode]) {
        case SpliceKitLiveCamBackgroundModeSystemBlur: return @"Blur";
        case SpliceKitLiveCamBackgroundModeGreenScreen: return @"Green Screen";
        default: return @"None";
    }
}

- (void)persistDefaults {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if (self.cameraPopup.selectedItem.representedObject) {
        [defaults setObject:self.cameraPopup.selectedItem.representedObject forKey:kLiveCamVideoDeviceKey];
    }
    if (self.microphonePopup.selectedItem.representedObject) {
        [defaults setObject:self.microphonePopup.selectedItem.representedObject forKey:kLiveCamAudioDeviceKey];
    }
    [defaults setObject:self.resolutionPopup.selectedItem.representedObject ?: @"1280x720" forKey:kLiveCamResolutionKey];
    [defaults setObject:self.frameRatePopup.selectedItem.representedObject ?: @30 forKey:kLiveCamFrameRateKey];
    [defaults setObject:self.qualityPopup.selectedItem.representedObject ?: @"balanced" forKey:kLiveCamQualityKey];
    [defaults setObject:[self selectedPresetIdentifier] forKey:kLiveCamPresetKey];
    [defaults setInteger:self.backgroundModePopup.indexOfSelectedItem forKey:kLiveCamBackgroundModeKey];
    [defaults setObject:self.backgroundColorPopup.selectedItem.representedObject ?: @"green" forKey:kLiveCamBackgroundColorKey];
    [defaults setDouble:self.backgroundEdgeSlider.doubleValue forKey:kLiveCamBackgroundEdgeSoftnessKey];
    [defaults setDouble:self.backgroundRefinementSlider.doubleValue forKey:kLiveCamBackgroundRefinementKey];
    [defaults setDouble:self.backgroundChokeSlider.doubleValue forKey:kLiveCamBackgroundChokeKey];
    [defaults setDouble:self.backgroundSpillSlider.doubleValue forKey:kLiveCamBackgroundSpillKey];
    [defaults setDouble:self.backgroundWrapSlider.doubleValue forKey:kLiveCamBackgroundWrapKey];
    [defaults setObject:self.backgroundQualityPopup.selectedItem.representedObject ?: @"balanced" forKey:kLiveCamBackgroundQualityKey];
    [defaults setBool:(self.mirrorCheckbox.state == NSControlStateValueOn) forKey:kLiveCamMirrorKey];
    [defaults setBool:(self.muteCheckbox.state == NSControlStateValueOn) forKey:kLiveCamMuteKey];
    [defaults setInteger:self.destinationControl.selectedSegment forKey:kLiveCamDestinationKey];
    [defaults setInteger:self.timelinePlacementPopup.indexOfSelectedItem forKey:kLiveCamPlacementKey];
    [defaults setObject:self.eventNameField.stringValue ?: @"" forKey:kLiveCamEventNameKey];
    [defaults setBool:self.advancedVisible forKey:kLiveCamAdvancedVisibleKey];
    [defaults setDouble:self.intensitySlider.doubleValue forKey:kLiveCamIntensityKey];
    [defaults setDouble:self.exposureSlider.doubleValue forKey:kLiveCamExposureKey];
    [defaults setDouble:self.contrastSlider.doubleValue forKey:kLiveCamContrastKey];
    [defaults setDouble:self.saturationSlider.doubleValue forKey:kLiveCamSaturationKey];
    [defaults setDouble:self.temperatureSlider.doubleValue forKey:kLiveCamTemperatureKey];
    [defaults setDouble:self.sharpnessSlider.doubleValue forKey:kLiveCamSharpnessKey];
    [defaults setDouble:self.glowSlider.doubleValue forKey:kLiveCamGlowKey];
    [defaults setBool:[self currentTimestampOverlayEnabled] forKey:kLiveCamTimestampOverlayKey];
}

- (NSTextField *)sectionTitleWithText:(NSString *)text {
    NSTextField *label = [NSTextField labelWithString:text ?: @""];
    label.font = [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold];
    label.textColor = [NSColor secondaryLabelColor];
    return label;
}

- (NSView *)labeledRowWithLabel:(NSString *)label control:(NSView *)control {
    NSTextField *title = [NSTextField labelWithString:label ?: @""];
    title.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    title.textColor = [NSColor colorWithWhite:0.88 alpha:0.95];
    title.alignment = NSTextAlignmentCenter;
    title.translatesAutoresizingMaskIntoConstraints = NO;

    control.translatesAutoresizingMaskIntoConstraints = NO;

    NSStackView *row = [NSStackView stackViewWithViews:@[title, control]];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    row.orientation = NSUserInterfaceLayoutOrientationVertical;
    row.spacing = 4.0;
    row.alignment = NSLayoutAttributeCenterX;
    row.distribution = NSStackViewDistributionGravityAreas;
    row.detachesHiddenViews = YES;
    return row;
}

- (NSView *)sliderRowWithLabel:(NSString *)label slider:(NSSlider *)slider {
    slider.translatesAutoresizingMaskIntoConstraints = NO;
    [slider.heightAnchor constraintEqualToConstant:20.0].active = YES;
    return [self labeledRowWithLabel:label control:slider];
}

- (NSView *)centeredViewRow:(NSView *)view {
    NSView *row = [[NSView alloc] initWithFrame:NSZeroRect];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    view.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:view];
    [NSLayoutConstraint activateConstraints:@[
        [view.centerXAnchor constraintEqualToAnchor:row.centerXAnchor],
        [view.topAnchor constraintEqualToAnchor:row.topAnchor],
        [view.bottomAnchor constraintEqualToAnchor:row.bottomAnchor],
        [view.leadingAnchor constraintGreaterThanOrEqualToAnchor:row.leadingAnchor],
        [view.trailingAnchor constraintLessThanOrEqualToAnchor:row.trailingAnchor],
    ]];
    return row;
}

- (NSView *)pairedCenteredRowsWithFirstLabel:(NSString *)firstLabel
                                     firstControl:(NSView *)firstControl
                                        secondLabel:(NSString *)secondLabel
                                      secondControl:(NSView *)secondControl {
    NSView *firstRow = [self labeledRowWithLabel:firstLabel control:firstControl];
    NSView *secondRow = [self labeledRowWithLabel:secondLabel control:secondControl];
    NSStackView *row = [NSStackView stackViewWithViews:@[firstRow, secondRow]];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    row.spacing = 12.0;
    row.distribution = NSStackViewDistributionFillEqually;
    row.alignment = NSLayoutAttributeCenterY;
    row.detachesHiddenViews = YES;
    return row;
}

- (NSSlider *)configuredSliderWithValue:(double)value
                               minValue:(double)minValue
                               maxValue:(double)maxValue {
    NSSlider *slider = [[NSSlider alloc] initWithFrame:NSZeroRect];
    slider.minValue = minValue;
    slider.maxValue = maxValue;
    slider.doubleValue = value;
    slider.target = self;
    slider.action = @selector(adjustmentSliderChanged:);
    return slider;
}

- (NSView *)sectionCardWithTitle:(NSString *)title
                            rows:(NSArray<NSView *> *)rows
                       titleColor:(NSColor *)titleColor {
    NSView *card = [[NSView alloc] initWithFrame:NSZeroRect];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.wantsLayer = YES;
    card.layer.cornerRadius = 10.0;
    card.layer.borderWidth = 1.0;
    card.layer.borderColor = [[NSColor colorWithWhite:1.0 alpha:0.08] CGColor];
    card.layer.backgroundColor = [[NSColor colorWithCalibratedWhite:0.15 alpha:0.97] CGColor];

    // Uppercase small-caps title, kerned, muted color. Matches the FCP
    // Inspector / modern Apple pro-app style and drops the colored tints
    // the old design used for each section.
    NSTextField *titleLabel = [NSTextField labelWithString:@""];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel.alignment = NSTextAlignmentCenter;
    NSString *upper = [(title ?: @"") uppercaseString];
    NSMutableParagraphStyle *paragraph = [[NSMutableParagraphStyle alloc] init];
    paragraph.alignment = NSTextAlignmentCenter;
    NSMutableAttributedString *attr = [[NSMutableAttributedString alloc] initWithString:upper];
    [attr addAttributes:@{
        NSFontAttributeName: [NSFont systemFontOfSize:10 weight:NSFontWeightSemibold],
        NSForegroundColorAttributeName: [NSColor secondaryLabelColor],
        NSKernAttributeName: @(1.2),
        NSParagraphStyleAttributeName: paragraph,
    } range:NSMakeRange(0, attr.length)];
    titleLabel.attributedStringValue = attr;
    (void)titleColor; // intentionally ignored — consistent uppercase label color

    NSStackView *stack = [NSStackView stackViewWithViews:rows ?: @[]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.spacing = 5.0;
    stack.alignment = NSLayoutAttributeCenterX;
    stack.detachesHiddenViews = YES;

    [card addSubview:titleLabel];
    [card addSubview:stack];

    // Stack's bottom uses `lessThanOrEqual` so when the card is forced to a
    // height larger than its natural content (e.g. the parent NSStackView
    // equalizes all 4 cards to the tallest one), the inner content stays
    // packed at the top and the extra space sits at the bottom of the card.
    // Without this, NSStackView's default gravity distribution spreads the
    // rows apart to fill the card, which is what made Camera sit at the
    // top and Resolution/Frame Rate/Quality drift to the bottom.
    [NSLayoutConstraint activateConstraints:@[
        [titleLabel.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:8.0],
        [titleLabel.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-8.0],
        [titleLabel.topAnchor constraintEqualToAnchor:card.topAnchor constant:8.0],

        [stack.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:8.0],
        [stack.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-8.0],
        [stack.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:8.0],
        [stack.bottomAnchor constraintLessThanOrEqualToAnchor:card.bottomAnchor constant:-8.0],
    ]];

    return card;
}

- (NSTextField *)wrappingInfoLabelWithText:(NSString *)text {
    NSTextField *label = [NSTextField wrappingLabelWithString:text ?: @""];
    label.font = [NSFont systemFontOfSize:12];
    label.textColor = [NSColor colorWithWhite:0.77 alpha:0.95];
    label.maximumNumberOfLines = 3;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    return label;
}

- (void)setupPanelIfNeeded {
    if (self.panel) return;

    NSRect screenFrame = [[NSScreen mainScreen] visibleFrame];
    NSRect frame = NSMakeRect(NSMidX(screenFrame) - 390.0,
                              NSMidY(screenFrame) - 410.0,
                              780.0,
                              820.0);
    self.panel = [[NSPanel alloc] initWithContentRect:frame
                                            styleMask:(NSWindowStyleMaskTitled |
                                                       NSWindowStyleMaskClosable |
                                                       NSWindowStyleMaskUtilityWindow)
                                              backing:NSBackingStoreBuffered
                                                defer:NO];
    self.panel.title = @"LiveCam";
    self.panel.floatingPanel = YES;
    self.panel.level = NSFloatingWindowLevel;
    self.panel.hidesOnDeactivate = NO;
    self.panel.releasedWhenClosed = NO;
    self.panel.minSize = NSMakeSize(760.0, 560.0);
    self.panel.contentMinSize = NSMakeSize(760.0, 560.0);
    // Cap the max height at what fits on this display rather than a fixed
    // 940pt — on a MacBook's visible area the old cap would run the panel
    // off-screen the moment Advanced Controls were opened.
    CGFloat maxPanelHeight = MAX(640.0, screenFrame.size.height - 40.0);
    self.panel.maxSize = NSMakeSize(920.0, maxPanelHeight);
    self.panel.contentMaxSize = NSMakeSize(920.0, maxPanelHeight);
    self.panel.styleMask |= NSWindowStyleMaskResizable;
    self.panel.collectionBehavior = NSWindowCollectionBehaviorFullScreenAuxiliary |
                                    NSWindowCollectionBehaviorCanJoinAllSpaces;
    self.panel.delegate = self;

    NSView *background = [[NSView alloc] initWithFrame:self.panel.contentView.bounds];
    background.translatesAutoresizingMaskIntoConstraints = NO;
    background.wantsLayer = YES;
    background.layer.backgroundColor = [[NSColor colorWithCalibratedWhite:0.11 alpha:0.985] CGColor];
    [self.panel.contentView addSubview:background];

    NSImageView *titleIconView = [[NSImageView alloc] initWithFrame:NSZeroRect];
    titleIconView.translatesAutoresizingMaskIntoConstraints = NO;
    titleIconView.imageScaling = NSImageScaleProportionallyDown;
    titleIconView.image = [NSImage imageWithSystemSymbolName:@"camera.fill"
                                    accessibilityDescription:@"LiveCam"];
    if (titleIconView.image) {
        titleIconView.contentTintColor = [NSColor colorWithWhite:0.92 alpha:0.96];
    }

    NSTextField *titleLabel = [NSTextField labelWithString:@"LiveCam"];
    titleLabel.font = [NSFont systemFontOfSize:24 weight:NSFontWeightBold];
    titleLabel.textColor = [NSColor labelColor];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;

    self.presetLabel = [NSTextField labelWithString:@""];
    self.presetLabel.hidden = YES;

    self.sessionLabel = [NSTextField labelWithString:@"Ready"];
    self.sessionLabel.font = [NSFont systemFontOfSize:10.5 weight:NSFontWeightMedium];
    self.sessionLabel.textColor = [NSColor colorWithWhite:0.84 alpha:0.88];
    self.sessionLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.sessionLabel.alignment = NSTextAlignmentRight;
    self.sessionLabel.maximumNumberOfLines = 1;

    self.permissionButton = [NSButton buttonWithTitle:@"Allow Camera…"
                                               target:self
                                               action:@selector(permissionButtonClicked:)];
    self.permissionButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.permissionButton.bezelStyle = NSBezelStyleRounded;
    self.permissionButton.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    self.permissionButton.hidden = YES;

    NSStackView *titleCluster = [NSStackView stackViewWithViews:@[titleIconView, titleLabel]];
    titleCluster.translatesAutoresizingMaskIntoConstraints = NO;
    titleCluster.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    titleCluster.spacing = 8.0;
    titleCluster.alignment = NSLayoutAttributeCenterY;
    titleCluster.detachesHiddenViews = YES;

    NSView *header = [[NSView alloc] initWithFrame:NSZeroRect];
    header.translatesAutoresizingMaskIntoConstraints = NO;
    [header addSubview:titleCluster];
    [header addSubview:self.permissionButton];
    [header addSubview:self.sessionLabel];

    NSView *previewContainer = [[NSView alloc] initWithFrame:NSZeroRect];
    previewContainer.translatesAutoresizingMaskIntoConstraints = NO;
    previewContainer.wantsLayer = YES;
    previewContainer.layer.backgroundColor = [[NSColor blackColor] CGColor];
    previewContainer.layer.cornerRadius = 16.0;
    previewContainer.layer.borderWidth = 1.0;
    previewContainer.layer.borderColor = [[NSColor colorWithWhite:1.0 alpha:0.08] CGColor];
    previewContainer.layer.masksToBounds = YES;

    self.previewView = [[MTKView alloc] initWithFrame:NSZeroRect device:self.renderer.metalDevice];
    self.previewView.translatesAutoresizingMaskIntoConstraints = NO;
    self.previewView.enableSetNeedsDisplay = YES;
    self.previewView.paused = YES;
    self.previewView.delegate = self;
    self.previewView.clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
    self.previewView.framebufferOnly = NO;
    self.previewView.colorPixelFormat = MTLPixelFormatBGRA8Unorm;
    [previewContainer addSubview:self.previewView];

    self.statusLabel = [self wrappingInfoLabelWithText:@"Preview will start after camera permission is granted."];
    self.statusLabel.font = [NSFont systemFontOfSize:12];
    self.statusLabel.textColor = [NSColor colorWithWhite:0.76 alpha:0.96];
    self.statusLabel.maximumNumberOfLines = 1;
    self.statusLabel.alignment = NSTextAlignmentCenter;

    // contentHost was the old wrapper view; the scroll view now owns layout.
    // Declaration kept out of the tree below.

    self.lookCategoryPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.lookCategoryPopup.target = self;
    self.lookCategoryPopup.action = @selector(lookCategoryChanged:);

    self.lookPresetPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.lookPresetPopup.target = self;
    self.lookPresetPopup.action = @selector(lookPresetChanged:);

    self.lookDescriptionLabel = [self wrappingInfoLabelWithText:@"Natural camera image with no stylized treatment."];
    self.lookDescriptionLabel.textColor = [NSColor secondaryLabelColor];
    self.lookDescriptionLabel.alignment = NSTextAlignmentCenter;

    self.timestampOverlayCheckbox = [NSButton checkboxWithTitle:@"Date/Time Stamp"
                                                           target:self
                                                           action:@selector(timestampOverlayChanged:)];
    self.timestampOverlayCheckbox.controlSize = NSControlSizeSmall;

    self.backgroundModePopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [self.backgroundModePopup addItemWithTitle:@"None"];
    self.backgroundModePopup.lastItem.representedObject = @"none";
    [self.backgroundModePopup addItemWithTitle:@"Blur"];
    self.backgroundModePopup.lastItem.representedObject = @"blur";
    [self.backgroundModePopup addItemWithTitle:@"Green Screen"];
    self.backgroundModePopup.lastItem.representedObject = @"greenScreen";
    self.backgroundModePopup.target = self;
    self.backgroundModePopup.action = @selector(backgroundModeChanged:);

    self.backgroundColorPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [self.backgroundColorPopup addItemWithTitle:@"Green"];
    self.backgroundColorPopup.lastItem.representedObject = @"green";
    [self.backgroundColorPopup addItemWithTitle:@"Blue"];
    self.backgroundColorPopup.lastItem.representedObject = @"blue";
    [self.backgroundColorPopup addItemWithTitle:@"Transparent"];
    self.backgroundColorPopup.lastItem.representedObject = @"transparent";
    self.backgroundColorPopup.target = self;
    self.backgroundColorPopup.action = @selector(configurationChanged:);

    self.backgroundEdgeSlider = [self configuredSliderWithValue:0.25 minValue:0.0 maxValue:1.0];
    // Defaults are tuned to clean up the typical Vision overcut without manual tweaking.
    self.backgroundRefinementSlider = [self configuredSliderWithValue:0.0 minValue:-1.0 maxValue:1.0];
    self.backgroundChokeSlider = [self configuredSliderWithValue:0.20 minValue:-1.0 maxValue:1.0];
    self.backgroundSpillSlider = [self configuredSliderWithValue:0.55 minValue:0.0 maxValue:1.0];
    self.backgroundWrapSlider = [self configuredSliderWithValue:0.0 minValue:0.0 maxValue:1.0];

    self.backgroundQualityPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [self.backgroundQualityPopup addItemWithTitle:@"Fast"];
    self.backgroundQualityPopup.lastItem.representedObject = @"fast";
    [self.backgroundQualityPopup addItemWithTitle:@"Balanced"];
    self.backgroundQualityPopup.lastItem.representedObject = @"balanced";
    [self.backgroundQualityPopup addItemWithTitle:@"Accurate"];
    self.backgroundQualityPopup.lastItem.representedObject = @"accurate";
    self.backgroundQualityPopup.target = self;
    self.backgroundQualityPopup.action = @selector(backgroundQualityChanged:);
    self.backgroundInfoLabel = [self wrappingInfoLabelWithText:@"Choose a background treatment for the live camera feed."];
    self.backgroundStatusLabel = [self wrappingInfoLabelWithText:@""];
    self.backgroundStatusLabel.textColor = [NSColor tertiaryLabelColor];
    self.backgroundStatusLabel.maximumNumberOfLines = 2;
    self.backgroundStatusLabel.alignment = NSTextAlignmentCenter;
    self.openVideoEffectsButton = [NSButton buttonWithTitle:@"Open Video Effects"
                                                     target:self
                                                     action:@selector(openVideoEffects:)];
    self.openVideoEffectsButton.bezelStyle = NSBezelStyleRounded;
    self.openVideoEffectsButton.toolTip = @"Opens the macOS Video Effects menu for Portrait blur, Center Stage, and Studio Light.";

    self.cameraPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.cameraPopup.target = self;
    self.cameraPopup.action = @selector(deviceSelectionChanged:);

    self.microphonePopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.microphonePopup.target = self;
    self.microphonePopup.action = @selector(deviceSelectionChanged:);

    self.resolutionPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [self.resolutionPopup addItemWithTitle:@"1280x720"];
    self.resolutionPopup.lastItem.representedObject = @"1280x720";
    [self.resolutionPopup addItemWithTitle:@"1920x1080"];
    self.resolutionPopup.lastItem.representedObject = @"1920x1080";
    [self.resolutionPopup addItemWithTitle:@"640x480"];
    self.resolutionPopup.lastItem.representedObject = @"640x480";
    self.resolutionPopup.target = self;
    self.resolutionPopup.action = @selector(configurationChanged:);

    self.frameRatePopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    for (NSNumber *fps in @[@24, @30, @60]) {
        [self.frameRatePopup addItemWithTitle:[NSString stringWithFormat:@"%@ fps", fps]];
        self.frameRatePopup.lastItem.representedObject = fps;
    }
    self.frameRatePopup.target = self;
    self.frameRatePopup.action = @selector(configurationChanged:);

    self.qualityPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [self.qualityPopup addItemWithTitle:@"Fast H.264"];
    self.qualityPopup.lastItem.representedObject = @"fast";
    [self.qualityPopup addItemWithTitle:@"Balanced H.264"];
    self.qualityPopup.lastItem.representedObject = @"balanced";
    [self.qualityPopup addItemWithTitle:@"High H.264"];
    self.qualityPopup.lastItem.representedObject = @"high";
    self.qualityPopup.target = self;
    self.qualityPopup.action = @selector(configurationChanged:);

    self.mirrorCheckbox = [NSButton checkboxWithTitle:@"Mirror preview"
                                               target:self
                                               action:@selector(configurationChanged:)];
    self.muteCheckbox = [NSButton checkboxWithTitle:@"Mute audio"
                                             target:self
                                             action:@selector(configurationChanged:)];

    self.audioMeter = [[SpliceKitLiveCamAudioMeterView alloc] initWithFrame:NSZeroRect];
    [self.audioMeter.heightAnchor constraintEqualToConstant:46.0].active = YES;

    self.destinationControl = [[NSSegmentedControl alloc] initWithFrame:NSZeroRect];
    self.destinationControl.segmentCount = 2;
    [self.destinationControl setLabel:@"Library" forSegment:0];
    [self.destinationControl setLabel:@"Timeline" forSegment:1];
    self.destinationControl.trackingMode = NSSegmentSwitchTrackingSelectOne;
    self.destinationControl.target = self;
    self.destinationControl.action = @selector(destinationChanged:);
    self.destinationControl.selectedSegment = 0;

    self.timelinePlacementPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [self.timelinePlacementPopup addItemWithTitle:@"Append"];
    [self.timelinePlacementPopup addItemWithTitle:@"At Playhead"];
    [self.timelinePlacementPopup addItemWithTitle:@"Connected Above"];
    self.timelinePlacementPopup.target = self;
    self.timelinePlacementPopup.action = @selector(configurationChanged:);
    self.destinationHintLabel = [self wrappingInfoLabelWithText:@"Fallback: Library if placement fails."];
    self.destinationHintLabel.textColor = [NSColor tertiaryLabelColor];
    self.destinationHintLabel.alignment = NSTextAlignmentCenter;

    self.clipNameField = [[NSTextField alloc] initWithFrame:NSZeroRect];
    self.clipNameField.placeholderString = @"Optional clip name";
    self.clipNameField.delegate = self;

    self.eventNameField = [[NSTextField alloc] initWithFrame:NSZeroRect];
    self.eventNameField.placeholderString = @"Current Event";
    self.eventNameField.delegate = self;
    self.nameHintLabel = [self wrappingInfoLabelWithText:@"Auto name: LiveCam_YYYYMMDD_HHMMSS"];
    self.nameHintLabel.textColor = [NSColor tertiaryLabelColor];

    self.intensitySlider = [self configuredSliderWithValue:self.adjustments.intensity minValue:0.0 maxValue:1.5];
    self.exposureSlider = [self configuredSliderWithValue:self.adjustments.exposure minValue:-1.0 maxValue:1.0];
    self.contrastSlider = [self configuredSliderWithValue:self.adjustments.contrast minValue:0.5 maxValue:1.8];
    self.saturationSlider = [self configuredSliderWithValue:self.adjustments.saturation minValue:0.0 maxValue:2.0];
    self.temperatureSlider = [self configuredSliderWithValue:self.adjustments.temperature minValue:-1.0 maxValue:1.0];
    self.sharpnessSlider = [self configuredSliderWithValue:self.adjustments.sharpness minValue:0.0 maxValue:1.5];
    self.glowSlider = [self configuredSliderWithValue:self.adjustments.glow minValue:0.0 maxValue:1.5];

    self.recordButton = [NSButton buttonWithTitle:@"Record"
                                           target:self
                                           action:@selector(recordClicked:)];
    self.recordButton.bezelStyle = NSBezelStyleRounded;
    self.recordButton.bezelColor = [NSColor systemRedColor];
    self.recordButton.contentTintColor = [NSColor whiteColor];
    self.recordButton.font = [NSFont systemFontOfSize:13 weight:NSFontWeightBold];

    self.stopButton = [NSButton buttonWithTitle:@"Stop"
                                         target:self
                                         action:@selector(stopClicked:)];
    self.stopButton.bezelStyle = NSBezelStyleRounded;
    self.stopButton.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
    self.stopButton.enabled = NO;

    self.elapsedLabel = [NSTextField labelWithString:@"00:00:00"];
    self.elapsedLabel.font = [NSFont monospacedDigitSystemFontOfSize:16 weight:NSFontWeightSemibold];
    self.elapsedLabel.textColor = [NSColor labelColor];

    NSStackView *recordButtons = [NSStackView stackViewWithViews:@[self.recordButton, self.stopButton]];
    recordButtons.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    recordButtons.spacing = 10.0;
    recordButtons.alignment = NSLayoutAttributeCenterY;

    NSStackView *transportCluster = [NSStackView stackViewWithViews:@[
        self.elapsedLabel,
        recordButtons,
    ]];
    transportCluster.translatesAutoresizingMaskIntoConstraints = NO;
    transportCluster.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    transportCluster.alignment = NSLayoutAttributeCenterY;
    transportCluster.spacing = 14.0;
    transportCluster.detachesHiddenViews = YES;

    NSView *transportRow = [[NSView alloc] initWithFrame:NSZeroRect];
    transportRow.translatesAutoresizingMaskIntoConstraints = NO;
    [transportRow addSubview:transportCluster];

    // Four-card layout matching the reference design:
    //   Video | Audio | Look | Extras
    // Each card sizes to its own content height (no more equal-height
    // constraint), so sparse cards don't inherit the Extras card's green-
    // screen slider stack.

    NSArray<NSView *> *videoRows = @[
        [self labeledRowWithLabel:@"Camera" control:self.cameraPopup],
        [self labeledRowWithLabel:@"Resolution" control:self.resolutionPopup],
        [self labeledRowWithLabel:@"Frame Rate" control:self.frameRatePopup],
        [self labeledRowWithLabel:@"Quality" control:self.qualityPopup],
    ];

    NSArray<NSView *> *audioRows = @[
        [self labeledRowWithLabel:@"Microphone" control:self.microphonePopup],
        [self centeredViewRow:self.audioMeter],
    ];

    NSArray<NSView *> *lookRows = @[
        [self labeledRowWithLabel:@"Category" control:self.lookCategoryPopup],
        [self labeledRowWithLabel:@"Preset" control:self.lookPresetPopup],
        [self centeredViewRow:self.lookDescriptionLabel],
        [self centeredViewRow:self.timestampOverlayCheckbox],
    ];

    // Green-screen-specific keying rows. These used to live inside the Extras
    // card, but that made Extras balloon to ~15 rows in green-screen mode
    // while Video/Audio/Look had 2–4 rows each, breaking the 4-card row's
    // uniform-grid look. Now they live at the bottom of the Advanced section
    // and their visibility is toggled by refreshBackgroundUI.
    self.backgroundColorRow = [self labeledRowWithLabel:@"Color" control:self.backgroundColorPopup];
    self.backgroundEdgeRow = [self sliderRowWithLabel:@"Edge Softness" slider:self.backgroundEdgeSlider];
    NSView *backgroundRefinementRow = [self sliderRowWithLabel:@"Refinement" slider:self.backgroundRefinementSlider];
    NSView *backgroundChokeRow = [self sliderRowWithLabel:@"Choke" slider:self.backgroundChokeSlider];
    NSView *backgroundSpillRow = [self sliderRowWithLabel:@"Spill" slider:self.backgroundSpillSlider];
    NSView *backgroundWrapRow = [self sliderRowWithLabel:@"Light Wrap" slider:self.backgroundWrapSlider];
    NSView *backgroundQualityRow = [self labeledRowWithLabel:@"Quality" control:self.backgroundQualityPopup];

    self.timelinePlacementRow = [self labeledRowWithLabel:@"Placement" control:self.timelinePlacementPopup];

    // Thin divider separating Background-group controls from Destination-
    // group controls inside the Extras card.
    NSBox *extrasDivider = [[NSBox alloc] initWithFrame:NSZeroRect];
    extrasDivider.boxType = NSBoxCustom;
    extrasDivider.borderWidth = 0;
    extrasDivider.fillColor = [NSColor colorWithCalibratedWhite:1.0 alpha:0.08];
    extrasDivider.translatesAutoresizingMaskIntoConstraints = NO;
    [extrasDivider.heightAnchor constraintEqualToConstant:1.0].active = YES;

    NSArray<NSView *> *extrasRows = @[
        [self labeledRowWithLabel:@"Background" control:self.backgroundModePopup],
        [self centeredViewRow:self.backgroundStatusLabel],
        [self centeredViewRow:self.openVideoEffectsButton],
        extrasDivider,
        [self labeledRowWithLabel:@"Record To" control:self.destinationControl],
        self.timelinePlacementRow,
        [self centeredViewRow:self.destinationHintLabel],
    ];

    // --- Advanced section: sub-sections with uniform-width horizontal grids
    //
    // Instead of one tall vertical stack, Advanced is broken into logical
    // sub-sections (Metadata, Options, Image Adjustments, Keying), and the
    // sliders inside each sub-section are laid out in a 3-column horizontal
    // row where every column gets the same width via distribution=FillEqually.
    // That gives every slider the same on-screen width regardless of which
    // row it lives in.

    NSView *(^blankCell)(void) = ^NSView * {
        NSView *v = [[NSView alloc] initWithFrame:NSZeroRect];
        v.translatesAutoresizingMaskIntoConstraints = NO;
        return v;
    };

    NSStackView *(^rowOf)(NSArray<NSView *> *) = ^NSStackView *(NSArray<NSView *> *views) {
        NSStackView *row = [NSStackView stackViewWithViews:views];
        row.translatesAutoresizingMaskIntoConstraints = NO;
        row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
        row.alignment = NSLayoutAttributeTop;
        row.spacing = 14.0;
        row.distribution = NSStackViewDistributionFillEqually;
        row.detachesHiddenViews = YES;
        return row;
    };

    NSTextField *(^subsectionHeader)(NSString *) = ^NSTextField *(NSString *text) {
        NSTextField *label = [NSTextField labelWithString:@""];
        label.translatesAutoresizingMaskIntoConstraints = NO;
        NSString *upper = [(text ?: @"") uppercaseString];
        NSMutableAttributedString *attr = [[NSMutableAttributedString alloc] initWithString:upper];
        [attr addAttributes:@{
            NSFontAttributeName: [NSFont systemFontOfSize:10 weight:NSFontWeightSemibold],
            NSForegroundColorAttributeName: [NSColor secondaryLabelColor],
            NSKernAttributeName: @(1.2),
        } range:NSMakeRange(0, attr.length)];
        label.attributedStringValue = attr;
        return label;
    };

    // Metadata: Clip Name | Event
    NSStackView *metadataRow = rowOf(@[
        [self labeledRowWithLabel:@"Clip Name" control:self.clipNameField],
        [self labeledRowWithLabel:@"Event" control:self.eventNameField],
    ]);

    // Options: Mirror preview | Mute audio
    NSStackView *optionsRow = rowOf(@[self.mirrorCheckbox, self.muteCheckbox]);

    // Image Adjustments — 3 columns × 3 rows (7 sliders + 2 blank cells).
    NSStackView *adjustRow1 = rowOf(@[
        [self sliderRowWithLabel:@"Intensity" slider:self.intensitySlider],
        [self sliderRowWithLabel:@"Exposure" slider:self.exposureSlider],
        [self sliderRowWithLabel:@"Contrast" slider:self.contrastSlider],
    ]);
    NSStackView *adjustRow2 = rowOf(@[
        [self sliderRowWithLabel:@"Saturation" slider:self.saturationSlider],
        [self sliderRowWithLabel:@"Warmth" slider:self.temperatureSlider],
        [self sliderRowWithLabel:@"Sharpness" slider:self.sharpnessSlider],
    ]);
    NSStackView *adjustRow3 = rowOf(@[
        [self sliderRowWithLabel:@"Glow" slider:self.glowSlider],
        blankCell(),
        blankCell(),
    ]);

    // Green Screen Keying sub-section. Whole group toggled by refreshBackgroundUI
    // via the enclosing NSStackView's hidden state.
    NSStackView *keyingRow1 = rowOf(@[
        self.backgroundColorRow,
        backgroundQualityRow,
        blankCell(),
    ]);
    NSStackView *keyingRow2 = rowOf(@[
        self.backgroundEdgeRow,
        backgroundRefinementRow,
        backgroundChokeRow,
    ]);
    NSStackView *keyingRow3 = rowOf(@[
        backgroundSpillRow,
        backgroundWrapRow,
        blankCell(),
    ]);

    NSStackView *keyingGroup = [NSStackView stackViewWithViews:@[
        subsectionHeader(@"Green Screen Keying"),
        keyingRow1, keyingRow2, keyingRow3,
    ]];
    keyingGroup.translatesAutoresizingMaskIntoConstraints = NO;
    keyingGroup.orientation = NSUserInterfaceLayoutOrientationVertical;
    keyingGroup.alignment = NSLayoutAttributeLeading;
    keyingGroup.spacing = 8.0;
    keyingGroup.detachesHiddenViews = YES;
    self.advancedKeyingGroup = keyingGroup;

    NSStackView *advancedLeftColumn = [NSStackView stackViewWithViews:@[
        subsectionHeader(@"Clip"),
        metadataRow,
        optionsRow,
        subsectionHeader(@"Image Adjustments"),
        adjustRow1,
        adjustRow2,
        adjustRow3,
    ]];
    advancedLeftColumn.translatesAutoresizingMaskIntoConstraints = NO;
    advancedLeftColumn.orientation = NSUserInterfaceLayoutOrientationVertical;
    advancedLeftColumn.spacing = 8.0;
    advancedLeftColumn.alignment = NSLayoutAttributeLeading;
    advancedLeftColumn.detachesHiddenViews = YES;

    NSStackView *advancedColumns = [NSStackView stackViewWithViews:@[
        advancedLeftColumn,
        keyingGroup,
    ]];
    advancedColumns.translatesAutoresizingMaskIntoConstraints = NO;
    advancedColumns.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    advancedColumns.spacing = 20.0;
    advancedColumns.alignment = NSLayoutAttributeTop;
    advancedColumns.distribution = NSStackViewDistributionFillEqually;
    advancedColumns.detachesHiddenViews = YES;
    self.advancedContainer = advancedColumns;

    self.advancedToggleButton = [NSButton buttonWithTitle:@"Show Advanced Controls"
                                                   target:self
                                                   action:@selector(toggleAdvancedControls:)];
    self.advancedToggleButton.bezelStyle = NSBezelStyleRounded;
    self.advancedToggleButton.controlSize = NSControlSizeSmall;

    NSView *videoSection = [self sectionCardWithTitle:@"Video"
                                                 rows:videoRows
                                           titleColor:nil];
    NSView *audioSection = [self sectionCardWithTitle:@"Audio"
                                                 rows:audioRows
                                           titleColor:nil];
    NSView *lookSection = [self sectionCardWithTitle:@"Look"
                                                rows:lookRows
                                          titleColor:nil];
    NSView *extrasSection = [self sectionCardWithTitle:@"Extras"
                                                  rows:extrasRows
                                            titleColor:nil];
    self.advancedSectionCard = [self sectionCardWithTitle:@"Advanced"
                                                     rows:@[self.advancedContainer]
                                                titleColor:[NSColor secondaryLabelColor]];
    self.advancedSectionCard.hidden = !self.advancedVisible;
    [self.advancedContainer.widthAnchor constraintEqualToAnchor:self.advancedSectionCard.widthAnchor constant:-32.0].active = YES;

    NSView *advancedToggleRow = [[NSView alloc] initWithFrame:NSZeroRect];
    advancedToggleRow.translatesAutoresizingMaskIntoConstraints = NO;
    [advancedToggleRow addSubview:self.advancedToggleButton];

    // Drop the "Previewing with…" status line out of the layout — it reads
    // as noise. Keep the label alive (other code paths call updateStatus:
    // on it) but hide it and leave it out of the view hierarchy.
    self.statusLabel.hidden = YES;

    NSStackView *previewStack = [NSStackView stackViewWithViews:@[
        previewContainer,
        transportRow,
    ]];
    previewStack.translatesAutoresizingMaskIntoConstraints = NO;
    previewStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    previewStack.spacing = 10.0;
    previewStack.alignment = NSLayoutAttributeWidth;
    previewStack.detachesHiddenViews = YES;

    // Four settings cards in a single row, all equal width and equal height
    // (matching the tallest card). Inner content is packed at the top of
    // each card so shorter cards show a clean empty space at the bottom,
    // like the reference mock. This is what gives the grid its cohesive
    // "Apple pro-app" look.
    NSStackView *controlsGrid = [NSStackView stackViewWithViews:@[
        videoSection, audioSection, lookSection, extrasSection,
    ]];
    controlsGrid.translatesAutoresizingMaskIntoConstraints = NO;
    controlsGrid.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    controlsGrid.spacing = 12.0;
    controlsGrid.alignment = NSLayoutAttributeHeight;
    controlsGrid.distribution = NSStackViewDistributionFillEqually;
    controlsGrid.detachesHiddenViews = YES;

    // The whole content below the header lives inside an NSScrollView so
    // the preview + settings + Advanced controls scroll together when they
    // don't fit on-screen. User can open Advanced and just keep scrolling.
    NSStackView *contentStack = [NSStackView stackViewWithViews:@[
        previewStack,
        controlsGrid,
        self.advancedSectionCard,
        advancedToggleRow,
    ]];
    contentStack.translatesAutoresizingMaskIntoConstraints = NO;
    contentStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    contentStack.spacing = 12.0;
    contentStack.alignment = NSLayoutAttributeWidth;
    contentStack.detachesHiddenViews = YES;
    contentStack.edgeInsets = NSEdgeInsetsMake(0, 18, 16, 18);

    // Flipped wrapper so scrolling starts from the top of the content.
    SpliceKitLiveCamFlippedView *scrollDocView = [[SpliceKitLiveCamFlippedView alloc] initWithFrame:NSZeroRect];
    scrollDocView.translatesAutoresizingMaskIntoConstraints = NO;
    [scrollDocView addSubview:contentStack];

    NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    scrollView.hasVerticalScroller = YES;
    scrollView.autohidesScrollers = YES;
    scrollView.drawsBackground = NO;
    scrollView.borderType = NSNoBorder;
    scrollView.documentView = scrollDocView;

    // Legacy ivar — some debug paths and refreshAdvancedUI still reference
    // it; point it at the doc view so the pointer stays valid.
    self.mainColumn = scrollDocView;

    [background addSubview:header];
    [background addSubview:scrollView];

    [NSLayoutConstraint activateConstraints:@[
        [background.leadingAnchor constraintEqualToAnchor:self.panel.contentView.leadingAnchor],
        [background.trailingAnchor constraintEqualToAnchor:self.panel.contentView.trailingAnchor],
        [background.topAnchor constraintEqualToAnchor:self.panel.contentView.topAnchor],
        [background.bottomAnchor constraintEqualToAnchor:self.panel.contentView.bottomAnchor],

        [header.leadingAnchor constraintEqualToAnchor:background.leadingAnchor constant:18.0],
        [header.trailingAnchor constraintEqualToAnchor:background.trailingAnchor constant:-18.0],
        [header.topAnchor constraintEqualToAnchor:background.topAnchor constant:16.0],
        [header.heightAnchor constraintEqualToConstant:48.0],

        [titleCluster.leadingAnchor constraintEqualToAnchor:header.leadingAnchor],
        [titleCluster.topAnchor constraintEqualToAnchor:header.topAnchor],
        [titleIconView.widthAnchor constraintEqualToConstant:16.0],
        [titleIconView.heightAnchor constraintEqualToConstant:16.0],
        [self.sessionLabel.trailingAnchor constraintEqualToAnchor:header.trailingAnchor],
        [self.sessionLabel.centerYAnchor constraintEqualToAnchor:titleCluster.centerYAnchor],
        [self.sessionLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:titleCluster.trailingAnchor constant:24.0],

        [self.permissionButton.centerYAnchor constraintEqualToAnchor:self.sessionLabel.centerYAnchor],
        [self.permissionButton.trailingAnchor constraintEqualToAnchor:self.sessionLabel.leadingAnchor constant:-8.0],
        [self.permissionButton.leadingAnchor constraintGreaterThanOrEqualToAnchor:titleCluster.trailingAnchor constant:16.0],

        // Scroll view fills the rest of the panel.
        [scrollView.leadingAnchor constraintEqualToAnchor:background.leadingAnchor],
        [scrollView.trailingAnchor constraintEqualToAnchor:background.trailingAnchor],
        [scrollView.topAnchor constraintEqualToAnchor:header.bottomAnchor constant:6.0],
        [scrollView.bottomAnchor constraintEqualToAnchor:background.bottomAnchor],

        // Document view matches the scroll view width so content never
        // scrolls horizontally — only vertically as needed.
        [scrollDocView.leadingAnchor constraintEqualToAnchor:scrollView.contentView.leadingAnchor],
        [scrollDocView.trailingAnchor constraintEqualToAnchor:scrollView.contentView.trailingAnchor],
        [scrollDocView.topAnchor constraintEqualToAnchor:scrollView.contentView.topAnchor],
        [scrollDocView.widthAnchor constraintEqualToAnchor:scrollView.contentView.widthAnchor],

        [contentStack.leadingAnchor constraintEqualToAnchor:scrollDocView.leadingAnchor],
        [contentStack.trailingAnchor constraintEqualToAnchor:scrollDocView.trailingAnchor],
        [contentStack.topAnchor constraintEqualToAnchor:scrollDocView.topAnchor],
        [contentStack.bottomAnchor constraintEqualToAnchor:scrollDocView.bottomAnchor],

        [previewContainer.heightAnchor constraintEqualToAnchor:previewContainer.widthAnchor multiplier:(9.0 / 16.0)],

        [self.previewView.leadingAnchor constraintEqualToAnchor:previewContainer.leadingAnchor],
        [self.previewView.trailingAnchor constraintEqualToAnchor:previewContainer.trailingAnchor],
        [self.previewView.topAnchor constraintEqualToAnchor:previewContainer.topAnchor],
        [self.previewView.bottomAnchor constraintEqualToAnchor:previewContainer.bottomAnchor],

        [transportCluster.centerXAnchor constraintEqualToAnchor:transportRow.centerXAnchor],
        [transportCluster.topAnchor constraintEqualToAnchor:transportRow.topAnchor],
        [transportCluster.bottomAnchor constraintEqualToAnchor:transportRow.bottomAnchor],

        [self.advancedToggleButton.trailingAnchor constraintEqualToAnchor:advancedToggleRow.trailingAnchor],
        [self.advancedToggleButton.topAnchor constraintEqualToAnchor:advancedToggleRow.topAnchor],
        [self.advancedToggleButton.bottomAnchor constraintEqualToAnchor:advancedToggleRow.bottomAnchor],

        // Preview, status line, and transport row each fill the content
        // width — without these they'd hug their intrinsic sizes and
        // collapse into a small cluster at the top-left of the scroll view.
        [previewContainer.widthAnchor constraintEqualToAnchor:self.mainColumn.widthAnchor constant:-36.0],
        [transportRow.widthAnchor constraintEqualToAnchor:self.mainColumn.widthAnchor constant:-36.0],

        // Four-card row and the Advanced section also fill the content width.
        [controlsGrid.widthAnchor constraintEqualToAnchor:self.mainColumn.widthAnchor constant:-36.0],
        [self.advancedSectionCard.widthAnchor constraintEqualToAnchor:self.mainColumn.widthAnchor constant:-36.0],

        // Each of the four settings cards has a small minimum so they
        // don't squash into unreadable slivers on narrow panels.
        [videoSection.widthAnchor constraintGreaterThanOrEqualToConstant:150.0],
        [audioSection.widthAnchor constraintGreaterThanOrEqualToConstant:150.0],
        [lookSection.widthAnchor constraintGreaterThanOrEqualToConstant:150.0],
        [extrasSection.widthAnchor constraintGreaterThanOrEqualToConstant:150.0],
    ]];

    [self buildPresetButtons];
    [self restoreSavedControlSelections];
    [self refreshDestinationUI];
    [self refreshBackgroundUI];
    [self refreshAdvancedUI];
    [self refreshNameHint];
    [self updateControlsForState];
}

- (void)buildPresetButtons {
    NSString *selectedCategory = self.lookCategoryPopup.selectedItem.representedObject ?: self.lookCategoryPopup.titleOfSelectedItem;
    if (selectedCategory.length == 0) {
        selectedCategory = [self selectedPreset].category ?: self.presetCategories.firstObject;
    }

    [self.lookCategoryPopup removeAllItems];
    for (NSString *category in self.presetCategories) {
        [self.lookCategoryPopup addItemWithTitle:category];
        self.lookCategoryPopup.lastItem.representedObject = category;
    }
    NSInteger categoryIndex = [self.lookCategoryPopup indexOfItemWithRepresentedObject:selectedCategory];
    [self.lookCategoryPopup selectItemAtIndex:(categoryIndex >= 0 ? categoryIndex : 0)];

    [self.lookPresetPopup removeAllItems];
    for (SpliceKitLiveCamPreset *preset in [self presetsForSelectedCategory]) {
        [self.lookPresetPopup addItemWithTitle:preset.name];
        self.lookPresetPopup.lastItem.representedObject = preset.identifier;
    }
    [self refreshPresetButtons];
}

- (void)restoreSavedControlSelections {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

    NSString *savedResolution = [defaults stringForKey:kLiveCamResolutionKey] ?: @"1280x720";
    NSInteger resolutionIndex = [self.resolutionPopup indexOfItemWithRepresentedObject:savedResolution];
    [self.resolutionPopup selectItemAtIndex:(resolutionIndex >= 0 ? resolutionIndex : 0)];

    NSNumber *savedFPS = @([defaults integerForKey:kLiveCamFrameRateKey] ?: 30);
    NSInteger fpsIndex = [self.frameRatePopup indexOfItemWithRepresentedObject:savedFPS];
    [self.frameRatePopup selectItemAtIndex:(fpsIndex >= 0 ? fpsIndex : 1)];

    NSString *savedQuality = [defaults stringForKey:kLiveCamQualityKey] ?: @"balanced";
    NSInteger qualityIndex = [self.qualityPopup indexOfItemWithRepresentedObject:savedQuality];
    [self.qualityPopup selectItemAtIndex:(qualityIndex >= 0 ? qualityIndex : 1)];

    NSInteger savedDestination = [defaults integerForKey:kLiveCamDestinationKey];
    self.destinationControl.selectedSegment = (savedDestination == 1) ? 1 : 0;

    NSInteger savedPlacement = [defaults integerForKey:kLiveCamPlacementKey];
    if (savedPlacement < 0 || savedPlacement > 2) savedPlacement = 0;
    [self.timelinePlacementPopup selectItemAtIndex:savedPlacement];

    NSInteger savedBackgroundMode = [defaults integerForKey:kLiveCamBackgroundModeKey];
    if (savedBackgroundMode < 0 || savedBackgroundMode > 2) savedBackgroundMode = 0;
    [self.backgroundModePopup selectItemAtIndex:savedBackgroundMode];

    NSString *savedBackgroundColor = [defaults stringForKey:kLiveCamBackgroundColorKey] ?: @"green";
    NSInteger backgroundColorIndex = [self.backgroundColorPopup indexOfItemWithRepresentedObject:savedBackgroundColor];
    [self.backgroundColorPopup selectItemAtIndex:(backgroundColorIndex >= 0 ? backgroundColorIndex : 0)];
    self.backgroundEdgeSlider.doubleValue = [defaults objectForKey:kLiveCamBackgroundEdgeSoftnessKey]
        ? [defaults doubleForKey:kLiveCamBackgroundEdgeSoftnessKey]
        : 0.25;
    self.backgroundRefinementSlider.doubleValue = [defaults objectForKey:kLiveCamBackgroundRefinementKey]
        ? [defaults doubleForKey:kLiveCamBackgroundRefinementKey]
        : 0.55;
    self.backgroundChokeSlider.doubleValue = [defaults objectForKey:kLiveCamBackgroundChokeKey]
        ? [defaults doubleForKey:kLiveCamBackgroundChokeKey]
        : 0.20;
    self.backgroundSpillSlider.doubleValue = [defaults objectForKey:kLiveCamBackgroundSpillKey]
        ? [defaults doubleForKey:kLiveCamBackgroundSpillKey]
        : 0.55;
    self.backgroundWrapSlider.doubleValue = [defaults objectForKey:kLiveCamBackgroundWrapKey]
        ? [defaults doubleForKey:kLiveCamBackgroundWrapKey]
        : 0.0;
    NSString *savedBgQuality = [defaults stringForKey:kLiveCamBackgroundQualityKey] ?: @"balanced";
    NSInteger qIdx = [self.backgroundQualityPopup indexOfItemWithRepresentedObject:savedBgQuality];
    [self.backgroundQualityPopup selectItemAtIndex:(qIdx >= 0 ? qIdx : 1)];
    SpliceKitLiveCamSegmentationQuality q = SpliceKitLiveCamSegmentationQualityBalanced;
    if ([savedBgQuality isEqualToString:@"fast"]) q = SpliceKitLiveCamSegmentationQualityFast;
    else if ([savedBgQuality isEqualToString:@"accurate"]) q = SpliceKitLiveCamSegmentationQualityAccurate;
    self.segmentationEngine.quality = q;

    self.mirrorCheckbox.state = [defaults objectForKey:kLiveCamMirrorKey]
        ? ([defaults boolForKey:kLiveCamMirrorKey] ? NSControlStateValueOn : NSControlStateValueOff)
        : NSControlStateValueOn;
    self.muteCheckbox.state = [defaults boolForKey:kLiveCamMuteKey]
        ? NSControlStateValueOn : NSControlStateValueOff;
    self.timestampOverlayCheckbox.state = [defaults objectForKey:kLiveCamTimestampOverlayKey]
        ? ([defaults boolForKey:kLiveCamTimestampOverlayKey] ? NSControlStateValueOn : NSControlStateValueOff)
        : NSControlStateValueOn;

    self.clipNameField.stringValue = @"";
    self.eventNameField.stringValue = [defaults stringForKey:kLiveCamEventNameKey] ?: @"";

    self.intensitySlider.doubleValue = self.adjustments.intensity;
    self.exposureSlider.doubleValue = self.adjustments.exposure;
    self.contrastSlider.doubleValue = self.adjustments.contrast;
    self.saturationSlider.doubleValue = self.adjustments.saturation;
    self.temperatureSlider.doubleValue = self.adjustments.temperature;
    self.sharpnessSlider.doubleValue = self.adjustments.sharpness;
    self.glowSlider.doubleValue = self.adjustments.glow;
    if ([self.clipNameField.stringValue hasPrefix:@"CrashRecovery"]) {
        self.clipNameField.stringValue = @"";
    }
    [self buildPresetButtons];
}

- (void)refreshPresetButtons {
    NSString *selectedIdentifier = [self selectedPresetIdentifier];
    NSArray<SpliceKitLiveCamPreset *> *visiblePresets = [self presetsForSelectedCategory];
    NSInteger presetIndex = NSNotFound;
    for (NSUInteger idx = 0; idx < visiblePresets.count; idx++) {
        if ([visiblePresets[idx].identifier isEqualToString:selectedIdentifier]) {
            presetIndex = (NSInteger)idx;
            break;
        }
    }
    if (presetIndex == NSNotFound) {
        SpliceKitLiveCamPreset *selectedPreset = [self selectedPreset];
        NSInteger categoryIndex = [self.lookCategoryPopup indexOfItemWithRepresentedObject:selectedPreset.category];
        if (categoryIndex >= 0) {
            [self.lookCategoryPopup selectItemAtIndex:categoryIndex];
            visiblePresets = [self presetsForSelectedCategory];
        }
        [self.lookPresetPopup removeAllItems];
        for (SpliceKitLiveCamPreset *preset in visiblePresets) {
            [self.lookPresetPopup addItemWithTitle:preset.name];
            self.lookPresetPopup.lastItem.representedObject = preset.identifier;
        }
        for (NSUInteger idx = 0; idx < visiblePresets.count; idx++) {
            if ([visiblePresets[idx].identifier isEqualToString:selectedIdentifier]) {
                presetIndex = (NSInteger)idx;
                break;
            }
        }
    }
    [self.lookPresetPopup selectItemAtIndex:(presetIndex != NSNotFound ? presetIndex : 0)];

    SpliceKitLiveCamPreset *selectedPreset = [self selectedPreset];
    self.presetLabel.stringValue = selectedPreset.name ?: @"Clean";
    self.lookDescriptionLabel.stringValue = selectedPreset.summary.length > 0
        ? selectedPreset.summary
        : @"";
    BOOL timestampSupported = SpliceKitLiveCamPresetSupportsTimestampOverlay(selectedIdentifier);
    self.timestampOverlayCheckbox.hidden = !timestampSupported;
    self.timestampOverlayCheckbox.enabled = timestampSupported;
    self.timestampOverlayCheckbox.state = [self selectedTimestampOverlayEnabled]
        ? NSControlStateValueOn
        : NSControlStateValueOff;
}

- (void)refreshDestinationUI {
    BOOL timeline = (self.destinationControl.selectedSegment == 1);
    self.timelinePlacementRow.hidden = !timeline;
    self.destinationHintLabel.hidden = !timeline;
    self.destinationHintLabel.stringValue = timeline
        ? @"Fallback: Library if placement fails."
        : @"";
}

- (NSArray<SpliceKitLiveCamPreset *> *)presetsForSelectedCategory {
    NSString *category = self.lookCategoryPopup.selectedItem.representedObject ?: self.lookCategoryPopup.titleOfSelectedItem;
    if (category.length == 0) return self.presets;
    NSMutableArray<SpliceKitLiveCamPreset *> *matches = [NSMutableArray array];
    for (SpliceKitLiveCamPreset *preset in self.presets) {
        if ([preset.category isEqualToString:category]) {
            [matches addObject:preset];
        }
    }
    return matches.count > 0 ? matches : self.presets;
}

- (NSString *)selectedBackgroundColorKey {
    NSString *key = SpliceKitLiveCamString(self.backgroundColorPopup.selectedItem.representedObject);
    return key.length > 0 ? key : @"green";
}

- (void)refreshBackgroundEffectState {
    AVCaptureDevice *device = [self selectedVideoDevice];
    self.systemBlurSupported = NO;
    self.systemBlurActive = NO;
    self.centerStageSupported = NO;
    self.centerStageActive = NO;
    self.studioLightActive = NO;

    if (!device) return;

    if (@available(macOS 12.0, *)) {
        AVCaptureDeviceFormat *format = device.activeFormat;
        if ([format respondsToSelector:@selector(isPortraitEffectSupported)]) {
            self.systemBlurSupported = format.isPortraitEffectSupported;
        }
        self.systemBlurActive = device.isPortraitEffectActive;
    }
    if (@available(macOS 12.3, *)) {
        AVCaptureDeviceFormat *format = device.activeFormat;
        if ([format respondsToSelector:@selector(isCenterStageSupported)]) {
            self.centerStageSupported = format.isCenterStageSupported;
        }
        self.centerStageActive = device.isCenterStageActive;
    }
    if (@available(macOS 13.0, *)) {
        self.studioLightActive = device.isStudioLightActive;
    }
}

- (void)refreshBackgroundUI {
    if (!self.backgroundModePopup) return;

    [self refreshBackgroundEffectState];

    SpliceKitLiveCamBackgroundMode mode = [self selectedBackgroundMode];
    BOOL blurAvailable = self.systemBlurSupported || self.systemBlurActive;
    BOOL greenScreenAvailable = self.segmentationEngine.supported;
    [[self.backgroundModePopup itemAtIndex:1] setEnabled:blurAvailable];
    [[self.backgroundModePopup itemAtIndex:2] setEnabled:greenScreenAvailable];

    if (mode == SpliceKitLiveCamBackgroundModeSystemBlur && !blurAvailable) {
        [self.backgroundModePopup selectItemAtIndex:0];
        mode = SpliceKitLiveCamBackgroundModeNone;
    } else if (mode == SpliceKitLiveCamBackgroundModeGreenScreen && !greenScreenAvailable) {
        [self.backgroundModePopup selectItemAtIndex:0];
        mode = SpliceKitLiveCamBackgroundModeNone;
    }

    BOOL blur = (mode == SpliceKitLiveCamBackgroundModeSystemBlur);
    BOOL greenScreen = (mode == SpliceKitLiveCamBackgroundModeGreenScreen);
    BOOL showVideoEffectsButton = blur || (greenScreen && (self.systemBlurActive || self.centerStageActive || self.studioLightActive));

    self.backgroundStatusLabel.hidden = (mode == SpliceKitLiveCamBackgroundModeNone);
    self.openVideoEffectsButton.hidden = !showVideoEffectsButton;
    self.openVideoEffectsButton.enabled = blurAvailable;
    // Toggle the whole Keying sub-section inside Advanced — it lives as
    // its own NSStackView group now, so one hidden toggle collapses all
    // 7 rows rather than leaving the "empty" keying container visible.
    self.advancedKeyingGroup.hidden = !greenScreen;
    self.backgroundColorRow.hidden = !greenScreen;
    self.backgroundEdgeRow.hidden = !greenScreen;
    self.backgroundColorPopup.enabled = greenScreen;
    self.backgroundEdgeSlider.enabled = greenScreen;
    self.backgroundRefinementSlider.enabled = greenScreen;
    self.backgroundChokeSlider.enabled = greenScreen;
    self.backgroundSpillSlider.enabled = greenScreen;
    // Light wrap is a no-op in transparent mode (no background color to bleed).
    BOOL transparentKey = [[self selectedBackgroundColorKey] isEqualToString:@"transparent"];
    self.backgroundWrapSlider.enabled = greenScreen && !transparentKey;
    self.backgroundQualityPopup.enabled = greenScreen;

    if (blur) {
        self.backgroundStatusLabel.stringValue = self.systemBlurSupported
            ? @"System Portrait Effect available."
            : @"Background blur unavailable on this camera.";
    } else if (greenScreen) {
        if (self.segmentationEngine.supported) {
            NSString *colorName = [[self selectedBackgroundColorKey] isEqualToString:@"blue"] ? @"blue" : @"green";
            self.backgroundStatusLabel.stringValue = [NSString stringWithFormat:@"LiveCam subject isolation. %@ field.", colorName];
        } else {
            self.backgroundStatusLabel.stringValue = self.segmentationEngine.lastError.length > 0
                ? self.segmentationEngine.lastError
                : @"Green Screen is unavailable on this system.";
        }
    } else {
        self.backgroundStatusLabel.stringValue = @"";
    }
}

- (void)refreshAdvancedUI {
    self.advancedContainer.hidden = !self.advancedVisible;
    self.advancedSectionCard.hidden = !self.advancedVisible;
    [self.advancedToggleButton setTitle:(self.advancedVisible ? @"Hide Advanced Controls" : @"Show Advanced Controls")];
}

- (void)refreshNameHint {
    NSString *baseName = SpliceKitLiveCamTrimmedString(self.clipNameField.stringValue);
    if ([baseName hasPrefix:@"CrashRecovery"]) {
        baseName = @"";
    }
    NSString *previewBase = baseName.length > 0 ? SpliceKitLiveCamSanitizeFilename(baseName) : @"LiveCam";
    self.nameHintLabel.stringValue = [NSString stringWithFormat:@"Auto name: %@_%@", previewBase, @"YYYYMMDD_HHMMSS"];
}

- (void)postVisibilityChange {
    [[NSNotificationCenter defaultCenter] postNotificationName:SpliceKitLiveCamVisibilityDidChangeNotification
                                                        object:self
                                                      userInfo:@{@"visible": @(self.isVisible)}];
}

- (void)showPanel {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self showPanel]; });
        return;
    }

    [self setupPanelIfNeeded];
    self.advancedVisible = NO;
    [self refreshAdvancedUI];
    [self refreshNameHint];
    NSRect desiredFrame = [self preferredLiveCamFrame];
    [self.panel setFrame:desiredFrame display:NO];
    [self.panel makeKeyAndOrderFront:nil];
    [self postVisibilityChange];
    [self reloadDevices];
    [self refreshBackgroundUI];
    [self requestPermissionsAndStartPreviewIfPossible];
}

- (NSRect)preferredLiveCamFrame {
    NSRect screenFrame = [[NSScreen mainScreen] visibleFrame];
    return NSMakeRect(NSMidX(screenFrame) - 390.0,
                      NSMidY(screenFrame) - 410.0,
                      780.0,
                      820.0);
}

- (void)hidePanel {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self hidePanel]; });
        return;
    }
    [self.panel orderOut:nil];
    [self postVisibilityChange];
    [self stopPreviewSession];
}

- (void)updateStatus:(NSString *)status {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.statusLabel.stringValue = status ?: @"";
    });
}

- (void)updateSessionLabel:(NSString *)text {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.sessionLabel.stringValue = text ?: @"";
    });
}

- (void)updateControlsForState {
    BOOL locked = self.recordingActive || self.finalizingRecording;
    self.lookCategoryPopup.enabled = !locked;
    self.lookPresetPopup.enabled = !locked;
    self.backgroundModePopup.enabled = !locked;
    self.backgroundColorPopup.enabled = !locked && self.backgroundColorRow.hidden == NO;
    self.backgroundEdgeSlider.enabled = !locked && self.backgroundEdgeRow.hidden == NO;
    BOOL bgEnabled = !locked && self.backgroundEdgeRow.hidden == NO;
    self.backgroundRefinementSlider.enabled = bgEnabled;
    self.backgroundChokeSlider.enabled = bgEnabled;
    self.backgroundSpillSlider.enabled = bgEnabled;
    self.backgroundWrapSlider.enabled = bgEnabled;
    self.backgroundQualityPopup.enabled = bgEnabled;
    self.openVideoEffectsButton.enabled = !locked && !self.openVideoEffectsButton.isHidden;
    self.advancedToggleButton.enabled = !locked;
    self.cameraPopup.enabled = !locked;
    self.microphonePopup.enabled = !locked;
    self.resolutionPopup.enabled = !locked;
    self.frameRatePopup.enabled = !locked;
    self.qualityPopup.enabled = !locked;
    self.timelinePlacementPopup.enabled = !locked;
    self.destinationControl.enabled = !locked;
    self.clipNameField.enabled = !locked;
    self.eventNameField.enabled = !locked;
    self.mirrorCheckbox.enabled = !locked;
    self.muteCheckbox.enabled = !locked;
    self.timestampOverlayCheckbox.enabled = !locked && !self.timestampOverlayCheckbox.hidden;
    self.intensitySlider.enabled = !locked;
    self.exposureSlider.enabled = !locked;
    self.contrastSlider.enabled = !locked;
    self.saturationSlider.enabled = !locked;
    self.temperatureSlider.enabled = !locked;
    self.sharpnessSlider.enabled = !locked;
    self.glowSlider.enabled = !locked;
    self.recordButton.enabled = !locked && self.cameraAuthorized && self.session.isRunning;
    self.stopButton.enabled = self.recordingActive || self.finalizingRecording;
}

- (void)reloadDevices {
    NSString *currentResolution = SpliceKitLiveCamString(self.resolutionPopup.selectedItem.representedObject);
    NSNumber *currentFPS = self.frameRatePopup.selectedItem.representedObject;

    AVCaptureDeviceDiscoverySession *videoSession =
        [AVCaptureDeviceDiscoverySession discoverySessionWithDeviceTypes:@[
            AVCaptureDeviceTypeBuiltInWideAngleCamera,
            AVCaptureDeviceTypeExternal,
        ]
                                                               mediaType:AVMediaTypeVideo
                                                                position:AVCaptureDevicePositionUnspecified];
    AVCaptureDeviceDiscoverySession *audioSession =
        [AVCaptureDeviceDiscoverySession discoverySessionWithDeviceTypes:@[
            AVCaptureDeviceTypeMicrophone,
            AVCaptureDeviceTypeExternal,
        ]
                                                               mediaType:AVMediaTypeAudio
                                                                position:AVCaptureDevicePositionUnspecified];
    self.videoDevices = videoSession.devices ?: @[];
    self.audioDevices = audioSession.devices ?: @[];

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *savedVideo = [defaults stringForKey:kLiveCamVideoDeviceKey];
    id savedAudioObject = [defaults objectForKey:kLiveCamAudioDeviceKey];
    NSString *savedAudio = [savedAudioObject isKindOfClass:[NSString class]] ? (NSString *)savedAudioObject : nil;
    NSString *defaultAudioID = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeAudio].uniqueID ?: @"";

    [self.cameraPopup removeAllItems];
    NSInteger preferredVideoIndex = -1;
    for (AVCaptureDevice *device in self.videoDevices) {
        [self.cameraPopup addItemWithTitle:device.localizedName ?: @"Camera"];
        self.cameraPopup.lastItem.representedObject = device.uniqueID ?: @"";
        if (savedVideo.length > 0 && [device.uniqueID isEqualToString:savedVideo]) {
            preferredVideoIndex = self.cameraPopup.numberOfItems - 1;
        }
    }
    if (self.cameraPopup.numberOfItems > 0) {
        [self.cameraPopup selectItemAtIndex:(preferredVideoIndex >= 0 ? preferredVideoIndex : 0)];
    }

    [self.microphonePopup removeAllItems];
    NSInteger preferredAudioIndex = -1;
    NSInteger noMicIndex = -1;
    for (AVCaptureDevice *device in self.audioDevices) {
        [self.microphonePopup addItemWithTitle:device.localizedName ?: @"Microphone"];
        self.microphonePopup.lastItem.representedObject = device.uniqueID ?: @"";
        if ([savedAudio isEqualToString:kLiveCamNoMicrophoneIdentifier]) {
            continue;
        }
        if (savedAudio.length > 0 && [device.uniqueID isEqualToString:savedAudio]) {
            preferredAudioIndex = self.microphonePopup.numberOfItems - 1;
        } else if (preferredAudioIndex < 0 && defaultAudioID.length > 0 &&
                   [device.uniqueID isEqualToString:defaultAudioID]) {
            preferredAudioIndex = self.microphonePopup.numberOfItems - 1;
        }
    }
    [self.microphonePopup addItemWithTitle:@"No Microphone"];
    self.microphonePopup.lastItem.representedObject = kLiveCamNoMicrophoneIdentifier;
    noMicIndex = self.microphonePopup.numberOfItems - 1;

    if ([savedAudio isEqualToString:kLiveCamNoMicrophoneIdentifier]) {
        preferredAudioIndex = noMicIndex;
    } else if (preferredAudioIndex < 0) {
        preferredAudioIndex = (self.audioDevices.count > 0) ? 0 : noMicIndex;
    }
    [self.microphonePopup selectItemAtIndex:preferredAudioIndex];

    [self refreshResolutionOptionsPreservingSelection:currentResolution frameRate:currentFPS];
    [self persistDefaults];
}

- (void)deviceAvailabilityChanged:(NSNotification *)note {
    SpliceKit_log(@"[LiveCamCapture] Device availability changed: %@", note.name);
    dispatch_async(dispatch_get_main_queue(), ^{
        [self reloadDevices];
        if (self.isVisible && !self.finalizingRecording) {
            [self reconfigurePreviewSession];
        }
    });
}

- (void)requestPermissionsAndStartPreviewIfPossible {
    AVAuthorizationStatus videoStatus = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
    AVAuthorizationStatus audioStatus = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio];

    dispatch_group_t group = dispatch_group_create();
    __block BOOL videoGranted = (videoStatus == AVAuthorizationStatusAuthorized);
    __block BOOL audioGranted = (audioStatus == AVAuthorizationStatusAuthorized);

    if (videoStatus == AVAuthorizationStatusNotDetermined) {
        dispatch_group_enter(group);
        [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL granted) {
            videoGranted = granted;
            dispatch_group_leave(group);
        }];
    }
    if (audioStatus == AVAuthorizationStatusNotDetermined) {
        dispatch_group_enter(group);
        [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL granted) {
            audioGranted = granted;
            dispatch_group_leave(group);
        }];
    }

    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        self.cameraAuthorized = videoGranted || videoStatus == AVAuthorizationStatusAuthorized;
        self.microphoneAuthorized = audioGranted || audioStatus == AVAuthorizationStatusAuthorized;
        if (!self.cameraAuthorized) {
            AVAuthorizationStatus currentVideoStatus = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
            BOOL needsSystemSettings = (currentVideoStatus == AVAuthorizationStatusDenied ||
                                         currentVideoStatus == AVAuthorizationStatusRestricted);
            self.permissionButton.title = needsSystemSettings ? @"Open System Settings…" : @"Allow Camera…";
            self.permissionButton.hidden = NO;
            NSString *detail = needsSystemSettings
                ? @"Camera permission is off. Click Open System Settings… to turn on camera access for Final Cut Pro."
                : @"Camera permission is required for LiveCam. Click Allow Camera… to grant access.";
            [self updateStatus:detail];
            [self updateSessionLabel:@"Camera permission denied"];
            [self updateControlsForState];
            return;
        }
        self.permissionButton.hidden = YES;

        if (!self.microphoneAuthorized) {
            [self updateStatus:@"Microphone access is off, so LiveCam will preview video only until microphone permission is granted."];
        }

        [self reconfigurePreviewSession];
    });
}

- (void)permissionButtonClicked:(id)sender {
    AVAuthorizationStatus videoStatus = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
    if (videoStatus == AVAuthorizationStatusNotDetermined) {
        [self requestPermissionsAndStartPreviewIfPossible];
        return;
    }
    NSURL *url = [NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_Camera"];
    [[NSWorkspace sharedWorkspace] openURL:url];
}

- (AVCaptureDevice *)selectedVideoDevice {
    NSString *identifier = SpliceKitLiveCamString(self.cameraPopup.selectedItem.representedObject);
    for (AVCaptureDevice *device in self.videoDevices) {
        if ([device.uniqueID isEqualToString:identifier]) return device;
    }
    return self.videoDevices.firstObject;
}

- (AVCaptureDevice *)selectedAudioDevice {
    NSString *identifier = SpliceKitLiveCamString(self.microphonePopup.selectedItem.representedObject);
    if (identifier.length == 0 || [identifier isEqualToString:kLiveCamNoMicrophoneIdentifier]) return nil;
    for (AVCaptureDevice *device in self.audioDevices) {
        if ([device.uniqueID isEqualToString:identifier]) return device;
    }
    return nil;
}

- (NSArray<NSNumber *> *)frameRatesForFormat:(AVCaptureDeviceFormat *)format {
    NSMutableOrderedSet<NSNumber *> *rates = [NSMutableOrderedSet orderedSet];
    NSArray<NSNumber *> *preferredRates = @[@24, @25, @30, @50, @60];

    for (AVFrameRateRange *range in format.videoSupportedFrameRateRanges) {
        double minRate = range.minFrameRate;
        double maxRate = range.maxFrameRate;

        for (NSNumber *candidate in preferredRates) {
            double fps = candidate.doubleValue;
            if (fps + 0.001 >= minRate && fps - 0.001 <= maxRate) {
                [rates addObject:@((NSInteger)lrint(fps))];
            }
        }

        NSInteger roundedMax = (NSInteger)lrint(maxRate);
        if (roundedMax > 0 && roundedMax <= 120 &&
            roundedMax + 0.001 >= minRate && roundedMax - 0.001 <= maxRate) {
            [rates addObject:@(roundedMax)];
        }
    }

    NSArray<NSNumber *> *sorted = [[rates array] sortedArrayUsingComparator:^NSComparisonResult(NSNumber *lhs, NSNumber *rhs) {
        return [lhs compare:rhs];
    }];
    return sorted.count > 0 ? sorted : @[@30];
}

- (void)refreshFrameRateOptionsPreservingSelection:(NSNumber *)preferredFPS {
    NSString *selectedResolutionKey = SpliceKitLiveCamString(self.resolutionPopup.selectedItem.representedObject);
    NSArray<NSNumber *> *availableRates = self.availableFrameRatesByResolution[selectedResolutionKey];
    if (availableRates.count == 0) {
        availableRates = @[@24, @30, @60];
    }

    NSNumber *fallbackPreferredFPS = preferredFPS ?: self.frameRatePopup.selectedItem.representedObject;
    [self.frameRatePopup removeAllItems];
    for (NSNumber *fps in availableRates) {
        [self.frameRatePopup addItemWithTitle:[NSString stringWithFormat:@"%@ fps", fps]];
        self.frameRatePopup.lastItem.representedObject = fps;
    }

    NSInteger preferredIndex = [self.frameRatePopup indexOfItemWithRepresentedObject:fallbackPreferredFPS];
    if (preferredIndex < 0) {
        preferredIndex = [self.frameRatePopup indexOfItemWithRepresentedObject:@30];
    }
    [self.frameRatePopup selectItemAtIndex:(preferredIndex >= 0 ? preferredIndex : 0)];
}

- (void)refreshResolutionOptionsPreservingSelection:(NSString *)preferredResolution
                                          frameRate:(NSNumber *)preferredFPS {
    AVCaptureDevice *device = [self selectedVideoDevice];
    NSMutableDictionary<NSString *, NSMutableOrderedSet<NSNumber *> *> *mutableRates = [NSMutableDictionary dictionary];

    for (AVCaptureDeviceFormat *format in device.formats) {
        CMVideoDimensions dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription);
        if (dimensions.width <= 0 || dimensions.height <= 0) continue;

        NSString *resolutionKey = SpliceKitLiveCamResolutionKeyForDimensions(dimensions.width, dimensions.height);
        if (resolutionKey.length == 0) continue;

        NSMutableOrderedSet<NSNumber *> *bucket = mutableRates[resolutionKey];
        if (!bucket) {
            bucket = [NSMutableOrderedSet orderedSet];
            mutableRates[resolutionKey] = bucket;
        }
        for (NSNumber *fps in [self frameRatesForFormat:format]) {
            [bucket addObject:fps];
        }
    }

    if (mutableRates.count == 0) {
        mutableRates[@"1280x720"] = [NSMutableOrderedSet orderedSetWithArray:@[@24, @30, @60]];
    }

    NSArray<NSString *> *sortedResolutionKeys = [[mutableRates allKeys] sortedArrayUsingComparator:^NSComparisonResult(NSString *lhs, NSString *rhs) {
        CGSize lhsSize = SpliceKitLiveCamResolutionForKey(lhs);
        CGSize rhsSize = SpliceKitLiveCamResolutionForKey(rhs);
        double lhsArea = lhsSize.width * lhsSize.height;
        double rhsArea = rhsSize.width * rhsSize.height;
        if (lhsArea > rhsArea) return NSOrderedAscending;
        if (lhsArea < rhsArea) return NSOrderedDescending;
        if (lhsSize.width > rhsSize.width) return NSOrderedAscending;
        if (lhsSize.width < rhsSize.width) return NSOrderedDescending;
        return [lhs compare:rhs];
    }];

    NSMutableDictionary<NSString *, NSArray<NSNumber *> *> *finalRates = [NSMutableDictionary dictionary];
    for (NSString *resolutionKey in sortedResolutionKeys) {
        NSArray<NSNumber *> *sortedRates = [[mutableRates[resolutionKey] array] sortedArrayUsingComparator:^NSComparisonResult(NSNumber *lhs, NSNumber *rhs) {
            return [lhs compare:rhs];
        }];
        finalRates[resolutionKey] = sortedRates.count > 0 ? sortedRates : @[@30];
    }

    self.availableResolutionKeys = sortedResolutionKeys;
    self.availableFrameRatesByResolution = finalRates;

    NSString *resolvedPreference = preferredResolution.length > 0 ? preferredResolution : [[NSUserDefaults standardUserDefaults] stringForKey:kLiveCamResolutionKey];
    [self.resolutionPopup removeAllItems];
    for (NSString *resolutionKey in self.availableResolutionKeys) {
        [self.resolutionPopup addItemWithTitle:SpliceKitLiveCamResolutionTitleForKey(resolutionKey)];
        self.resolutionPopup.lastItem.representedObject = resolutionKey;
    }

    NSInteger preferredIndex = [self.resolutionPopup indexOfItemWithRepresentedObject:resolvedPreference];
    if (preferredIndex < 0) {
        preferredIndex = [self.resolutionPopup indexOfItemWithRepresentedObject:@"1920x1080"];
    }
    if (preferredIndex < 0) {
        preferredIndex = [self.resolutionPopup indexOfItemWithRepresentedObject:@"1280x720"];
    }
    [self.resolutionPopup selectItemAtIndex:(preferredIndex >= 0 ? preferredIndex : 0)];
    [self refreshFrameRateOptionsPreservingSelection:preferredFPS];
}

- (void)configureVideoDevice:(AVCaptureDevice *)device
                  resolution:(CGSize)resolution
                   frameRate:(double)fps {
    if (!device) return;

    NSError *error = nil;
    if (![device lockForConfiguration:&error]) {
        SpliceKit_log(@"[LiveCamCapture] Could not lock %@ for configuration: %@",
                      device.localizedName, error.localizedDescription);
        return;
    }

    AVCaptureDeviceFormat *bestFormat = nil;
    double bestScore = DBL_MAX;

    for (AVCaptureDeviceFormat *format in device.formats) {
        CMFormatDescriptionRef description = format.formatDescription;
        CMVideoDimensions dimensions = CMVideoFormatDescriptionGetDimensions(description);

        BOOL fpsSupported = (fps <= 0.0);
        for (AVFrameRateRange *range in format.videoSupportedFrameRateRanges) {
            if (fps <= 0.0 || (range.minFrameRate <= fps && range.maxFrameRate >= fps)) {
                fpsSupported = YES;
                break;
            }
        }
        if (!fpsSupported) continue;

        double widthDelta = fabs((double)dimensions.width - resolution.width);
        double heightDelta = fabs((double)dimensions.height - resolution.height);
        double score = widthDelta + heightDelta;
        if (score < bestScore) {
            bestScore = score;
            bestFormat = format;
        }
    }

    if (bestFormat) {
        device.activeFormat = bestFormat;
        if (fps > 0.0) {
            CMTime frameDuration = CMTimeMake(1000, (int32_t)lrint(fps * 1000.0));
            device.activeVideoMinFrameDuration = frameDuration;
            device.activeVideoMaxFrameDuration = frameDuration;
        }
        CMVideoDimensions dimensions = CMVideoFormatDescriptionGetDimensions(bestFormat.formatDescription);
        SpliceKit_log(@"[LiveCamCapture] %@ active format %dx%d @ %.0f fps",
                      device.localizedName ?: @"Camera",
                      dimensions.width,
                      dimensions.height,
                      fps);
    } else {
        SpliceKit_log(@"[LiveCamCapture] No exact format match for %@ %.0fx%.0f @ %.0f fps",
                      device.localizedName ?: @"Camera",
                      resolution.width,
                      resolution.height,
                      fps);
    }

    [device unlockForConfiguration];
}

- (void)reconfigurePreviewSession {
    if (!self.cameraAuthorized) return;

    AVCaptureDevice *videoDevice = [self selectedVideoDevice];
    AVCaptureDevice *audioDevice = self.microphoneAuthorized ? [self selectedAudioDevice] : nil;
    CGSize targetResolution = SpliceKitLiveCamResolutionForKey(SpliceKitLiveCamString(self.resolutionPopup.selectedItem.representedObject));
    double frameRate = [self.frameRatePopup.selectedItem.representedObject doubleValue] ?: 30.0;

    [self updateSessionLabel:@"Configuring capture…"];
    [self updateStatus:@"Opening camera preview…"];

    dispatch_async(self.sessionQueue, ^{
        if (self.session.isRunning) {
            [self.session stopRunning];
        }

        AVCaptureSession *session = [[AVCaptureSession alloc] init];
        // Use an exact macOS capture preset where one exists. The old generic
        // "High" preset made a selected 720p preview arrive as 1920x1080 and
        // forced 2.25x as many pixels through every effect.
        AVCaptureSessionPreset requestedPreset =
            SpliceKitLiveCamSessionPresetForResolution(targetResolution);
        if ([session canSetSessionPreset:requestedPreset]) {
            session.sessionPreset = requestedPreset;
        } else if ([session canSetSessionPreset:AVCaptureSessionPresetHigh]) {
            session.sessionPreset = AVCaptureSessionPresetHigh;
        }

        NSError *inputError = nil;
        AVCaptureDeviceInput *videoInput = videoDevice
            ? [AVCaptureDeviceInput deviceInputWithDevice:videoDevice error:&inputError]
            : nil;
        if (videoInput && [session canAddInput:videoInput]) {
            [session addInput:videoInput];
            self.videoInput = videoInput;
        }

        if (videoDevice) {
            [self configureVideoDevice:videoDevice resolution:targetResolution frameRate:frameRate];
        }

        AVCaptureDeviceInput *audioInput = nil;
        if (audioDevice) {
            NSError *audioError = nil;
            audioInput = [AVCaptureDeviceInput deviceInputWithDevice:audioDevice error:&audioError];
            if (audioInput && [session canAddInput:audioInput]) {
                [session addInput:audioInput];
                self.audioInput = audioInput;
            } else if (audioError) {
                SpliceKit_log(@"[LiveCamCapture] Audio input error: %@", audioError.localizedDescription);
            }
        } else {
            self.audioInput = nil;
        }

        AVCaptureVideoDataOutput *videoOutput = [[AVCaptureVideoDataOutput alloc] init];
        videoOutput.alwaysDiscardsLateVideoFrames = YES;
        videoOutput.videoSettings = @{
            (NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
            (NSString *)kCVPixelBufferWidthKey: @((NSInteger)lrint(targetResolution.width)),
            (NSString *)kCVPixelBufferHeightKey: @((NSInteger)lrint(targetResolution.height)),
        };
        [videoOutput setSampleBufferDelegate:self queue:self.videoQueue];
        if ([session canAddOutput:videoOutput]) {
            [session addOutput:videoOutput];
            self.videoOutput = videoOutput;
        }

        AVCaptureAudioDataOutput *audioOutput = [[AVCaptureAudioDataOutput alloc] init];
        // Preserve the hardware's native rate and channel layout. In
        // particular, the MVX2U is a 48 kHz mono source; forcing a stereo
        // capture format here adds an unnecessary real-time conversion before
        // the writer has even seen the source format.
        audioOutput.audioSettings = nil;
        [audioOutput setSampleBufferDelegate:self queue:self.audioQueue];
        if (audioDevice && [session canAddOutput:audioOutput]) {
            [session addOutput:audioOutput];
            self.audioOutput = audioOutput;
        } else {
            self.audioOutput = nil;
        }

        AVCaptureConnection *videoConnection = [videoOutput connectionWithMediaType:AVMediaTypeVideo];
        if (videoConnection.isVideoMirroringSupported) {
            videoConnection.automaticallyAdjustsVideoMirroring = NO;
            videoConnection.videoMirrored = NO;
        }

        self.session = session;
        dispatch_sync(self.videoQueue, ^{
            self.latestPreviewImage = nil;
            [self.segmentationEngine reset];
            [self.renderer resetMaskHistory];
        });

        if (self.isVisible) {
            [session startRunning];
        }

        NSString *cameraName = videoDevice.localizedName ?: @"No Camera";
        NSString *micName = audioDevice.localizedName ?: @"No Microphone";
        NSString *statusCopy = audioDevice
            ? @"What you see is what gets recorded."
            : @"Video only. No microphone selected.";
        NSString *compactCameraName = [cameraName stringByReplacingOccurrencesOfString:@" Camera" withString:@""];
        NSString *compactResolution = SpliceKitLiveCamString(self.resolutionPopup.selectedItem.representedObject);
        dispatch_async(dispatch_get_main_queue(), ^{
            [self refreshBackgroundUI];
            [self updateSessionLabel:[NSString stringWithFormat:@"%@ • %@ • %@ • %@",
                                      compactCameraName.length > 0 ? compactCameraName : cameraName,
                                      micName,
                                      compactResolution.length > 0 ? compactResolution : (self.resolutionPopup.titleOfSelectedItem ?: @""),
                                      self.frameRatePopup.titleOfSelectedItem ?: @""]];
            [self updateStatus:statusCopy];
            [self updateControlsForState];
            [self persistDefaults];
        });
    });
}

- (void)stopPreviewSession {
    dispatch_async(self.sessionQueue, ^{
        if (self.session.isRunning) {
            [self.session stopRunning];
        }
        dispatch_sync(self.videoQueue, ^{
            self.latestPreviewImage = nil;
            [self.segmentationEngine reset];
            [self.renderer resetMaskHistory];
        });
        dispatch_async(dispatch_get_main_queue(), ^{
            self.smoothedAudioLevel = 0.0;
            [self.audioMeter reset];
        });
    });
}

- (void)deviceSelectionChanged:(id)sender {
    if (sender == self.cameraPopup) {
        [self refreshResolutionOptionsPreservingSelection:nil frameRate:nil];
    }
    [self persistDefaults];
    [self refreshBackgroundUI];
    if (self.isVisible && !self.recordingActive && !self.finalizingRecording) {
        [self reconfigurePreviewSession];
    }
}

- (void)configurationChanged:(id)sender {
    if (sender == self.resolutionPopup) {
        [self refreshFrameRateOptionsPreservingSelection:nil];
    }
    [self refreshDestinationUI];
    [self refreshPresetButtons];
    [self refreshBackgroundUI];
    [self refreshNameHint];
    [self persistDefaults];
    if (sender == self.resolutionPopup || sender == self.frameRatePopup) {
        if (self.isVisible && !self.recordingActive && !self.finalizingRecording) {
            [self reconfigurePreviewSession];
        }
    }
}

- (void)adjustmentSliderChanged:(id)sender {
    self.adjustments.intensity = self.intensitySlider.doubleValue;
    self.adjustments.exposure = self.exposureSlider.doubleValue;
    self.adjustments.contrast = self.contrastSlider.doubleValue;
    self.adjustments.saturation = self.saturationSlider.doubleValue;
    self.adjustments.temperature = self.temperatureSlider.doubleValue;
    self.adjustments.sharpness = self.sharpnessSlider.doubleValue;
    self.adjustments.glow = self.glowSlider.doubleValue;
    [self persistDefaults];
}

- (void)destinationChanged:(id)sender {
    [self refreshDestinationUI];
    [self persistDefaults];
}

- (void)lookCategoryChanged:(id)sender {
    NSString *category = self.lookCategoryPopup.selectedItem.representedObject ?: self.lookCategoryPopup.titleOfSelectedItem;
    SpliceKitLiveCamPreset *currentPreset = [self selectedPreset];
    NSArray<SpliceKitLiveCamPreset *> *visiblePresets = [self presetsForSelectedCategory];
    NSString *identifier = ([currentPreset.category isEqualToString:category] && currentPreset.identifier.length > 0)
        ? currentPreset.identifier
        : visiblePresets.firstObject.identifier;
    [self storeSelectedPresetIdentifier:identifier];
    [self buildPresetButtons];
    [self refreshPresetButtons];
    [self updateStatus:[NSString stringWithFormat:@"Previewing %@.", [self selectedPreset].name ?: @"Clean"]];
    [self persistDefaults];
}

- (void)lookPresetChanged:(id)sender {
    NSString *identifier = SpliceKitLiveCamString(self.lookPresetPopup.selectedItem.representedObject);
    [self storeSelectedPresetIdentifier:identifier];
    [self refreshPresetButtons];
    [self updateStatus:[NSString stringWithFormat:@"Previewing %@.", [self selectedPreset].name ?: @"Clean"]];
    [self persistDefaults];
}

- (void)backgroundQualityChanged:(id)sender {
    NSString *key = SpliceKitLiveCamString(self.backgroundQualityPopup.selectedItem.representedObject);
    SpliceKitLiveCamSegmentationQuality q = SpliceKitLiveCamSegmentationQualityBalanced;
    if ([key isEqualToString:@"fast"]) q = SpliceKitLiveCamSegmentationQualityFast;
    else if ([key isEqualToString:@"accurate"]) q = SpliceKitLiveCamSegmentationQualityAccurate;
    self.segmentationEngine.quality = q;
    [self.segmentationEngine reset];
    [self.renderer resetMaskHistory];
    [self persistDefaults];
}

- (void)backgroundModeChanged:(id)sender {
    if ([self selectedBackgroundMode] != SpliceKitLiveCamBackgroundModeGreenScreen) {
        [self.segmentationEngine reset];
        [self.renderer resetMaskHistory];
    }
    [self refreshBackgroundUI];

    switch ([self selectedBackgroundMode]) {
        case SpliceKitLiveCamBackgroundModeSystemBlur:
            [self updateStatus:@"Blur is controlled by macOS Video Effects. Open Video Effects to turn Portrait blur on or off."];
            break;
        case SpliceKitLiveCamBackgroundModeGreenScreen:
            [self updateStatus:@"Previewing with LiveCam Green Screen. Best results come from clear separation and stable lighting."];
            break;
        default:
            [self updateStatus:@"Previewing the natural camera feed. System Video Effects still pass through when enabled."];
            break;
    }

    [self persistDefaults];
}

- (void)openVideoEffects:(id)sender {
    if (!@available(macOS 12.0, *)) {
        [self updateStatus:@"System Video Effects are not available on this macOS version."];
        return;
    }

    [AVCaptureDevice showSystemUserInterface:AVCaptureSystemUserInterfaceVideoEffects];
    [self updateStatus:@"Open Video Effects to manage Portrait blur, Center Stage, and Studio Light for the current camera."];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self refreshBackgroundUI];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self refreshBackgroundUI];
    });
}

- (void)timestampOverlayChanged:(id)sender {
    [self persistDefaults];
}

- (void)toggleAdvancedControls:(id)sender {
    self.advancedVisible = !self.advancedVisible;
    [self refreshAdvancedUI];
    [self persistDefaults];
}

- (void)presetClicked:(NSButton *)sender {
    NSInteger index = sender.tag;
    if (index < 0 || index >= (NSInteger)self.presets.count) return;
    SpliceKitLiveCamPreset *preset = self.presets[(NSUInteger)index];
    [self storeSelectedPresetIdentifier:preset.identifier];
    [self refreshPresetButtons];
    [self persistDefaults];
}

- (void)controlTextDidChange:(NSNotification *)obj {
    [self refreshNameHint];
    [self persistDefaults];
}

- (NSString *)recordingBaseName {
    NSString *baseName = SpliceKitLiveCamTrimmedString(self.clipNameField.stringValue);
    if (baseName.length == 0) baseName = @"LiveCam";
    NSString *timestamp = SpliceKitLiveCamTimestampForFilename([NSDate date]);
    return [NSString stringWithFormat:@"%@_%@", SpliceKitLiveCamSanitizeFilename(baseName), timestamp];
}

- (double)selectedBitRate {
    NSString *quality = SpliceKitLiveCamString(self.qualityPopup.selectedItem.representedObject);
    if ([quality isEqualToString:@"fast"]) return 6.0 * 1000.0 * 1000.0;
    if ([quality isEqualToString:@"high"]) return 20.0 * 1000.0 * 1000.0;
    return 12.0 * 1000.0 * 1000.0;
}

- (NSDictionary<NSString *, id> *)audioWriterSettingsForCurrentSession {
    // Apple's recommendation is derived from the configured capture session,
    // so it retains a mono USB microphone as mono and uses its actual sample
    // rate. The previous fixed 48 kHz/stereo dictionary made AVAssetWriter
    // perform an undocumented real-time mono-to-stereo conversion for the
    // Shure MVX2U, which is both unnecessary and vulnerable to crackle when
    // the 4K video path is under pressure.
    NSDictionary<NSString *, id> *recommended =
        [self.audioOutput recommendedAudioSettingsForAssetWriterWithOutputFileType:AVFileTypeQuickTimeMovie];
    NSNumber *recommendedRate = recommended[AVSampleRateKey];
    NSNumber *recommendedChannels = recommended[AVNumberOfChannelsKey];
    if (recommended.count > 0 && recommendedRate.doubleValue > 0.0 &&
        recommendedChannels.unsignedIntegerValue > 0) {
        return recommended;
    }

    // The recommendation should be available once the session is running, but
    // retain a format-aware fallback for devices/drivers that do not provide
    // one. Read the active audio ASBD instead of assuming every microphone is
    // stereo.
    double sampleRate = 48000.0;
    NSUInteger channelCount = 1;
    AVCaptureDevice *audioDevice = self.audioInput.device;
    CMFormatDescriptionRef formatDescription = audioDevice.activeFormat.formatDescription;
    if (formatDescription &&
        CMFormatDescriptionGetMediaType(formatDescription) == kCMMediaType_Audio) {
        const AudioStreamBasicDescription *asbd =
            CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription);
        if (asbd) {
            if (asbd->mSampleRate > 0.0) sampleRate = asbd->mSampleRate;
            if (asbd->mChannelsPerFrame > 0) {
                channelCount = MIN((NSUInteger)2, (NSUInteger)asbd->mChannelsPerFrame);
            }
        }
    }

    return @{
        AVFormatIDKey: @(kAudioFormatMPEG4AAC),
        AVNumberOfChannelsKey: @(channelCount),
        AVSampleRateKey: @(sampleRate),
        AVEncoderBitRateKey: @(channelCount == 1 ? 96000 : 160000),
        AVEncoderAudioQualityKey: @(AVAudioQualityHigh),
    };
}

- (void)resetAudioDiagnosticsForRecording {
    dispatch_sync(self.audioQueue, ^{
        self.expectedNextAudioPTS = kCMTimeInvalid;
        self.sourceAudioDiscontinuities = 0;
        self.sourceAudioGapFrames = 0;
    });
}

- (void)prepareWriterForCurrentSettings {
    NSString *baseName = [self recordingBaseName];
    NSString *tempPath = SpliceKitLiveCamUniquePath(SpliceKitLiveCamTemporaryDirectory(), [baseName stringByAppendingString:@".partial"], @"mov");
    NSString *finalPath = SpliceKitLiveCamUniquePath(SpliceKitLiveCamOutputDirectory(), baseName, @"mov");

    [[NSFileManager defaultManager] removeItemAtPath:tempPath error:nil];

    self.temporaryRecordingURL = [NSURL fileURLWithPath:tempPath];
    self.finalRecordingURL = [NSURL fileURLWithPath:finalPath];
    self.recordingCanvasSize = SpliceKitLiveCamResolutionForKey(SpliceKitLiveCamString(self.resolutionPopup.selectedItem.representedObject));

    NSError *writerError = nil;
    self.assetWriter = [AVAssetWriter assetWriterWithURL:self.temporaryRecordingURL
                                                fileType:AVFileTypeQuickTimeMovie
                                                   error:&writerError];
    if (!self.assetWriter || writerError) {
        SpliceKit_log(@"[LiveCamRecord] Writer creation failed: %@", writerError.localizedDescription);
        self.assetWriter = nil;
        return;
    }

    // ProRes 4444 is the only QuickTime codec FCP imports with alpha out of the box,
    // so transparent recordings have to switch off H.264 — bit rate / profile keys
    // are H.264-only and would be rejected by the ProRes encoder.
    BOOL transparentRecording = [self selectedBackgroundMode] == SpliceKitLiveCamBackgroundModeGreenScreen
        && [[self selectedBackgroundColorKey] isEqualToString:@"transparent"];
    self.recordingIsTransparent = transparentRecording;
    NSDictionary *videoSettings;
    if (transparentRecording) {
        // Without kVTCompressionPropertyKey_AlphaChannelMode the ProRes encoder
        // reserves the alpha plane in the file (yuva444p12le) but writes 1.0 into
        // every pixel, ignoring the source buffer's A channel.
        videoSettings = @{
            AVVideoCodecKey: AVVideoCodecTypeAppleProRes4444,
            AVVideoWidthKey: @((NSInteger)self.recordingCanvasSize.width),
            AVVideoHeightKey: @((NSInteger)self.recordingCanvasSize.height),
            AVVideoCompressionPropertiesKey: @{
                (id)kVTCompressionPropertyKey_AlphaChannelMode: (id)kVTAlphaChannelMode_PremultipliedAlpha,
            },
        };
    } else {
        videoSettings = @{
            AVVideoCodecKey: AVVideoCodecTypeH264,
            AVVideoWidthKey: @((NSInteger)self.recordingCanvasSize.width),
            AVVideoHeightKey: @((NSInteger)self.recordingCanvasSize.height),
            AVVideoCompressionPropertiesKey: @{
                AVVideoAverageBitRateKey: @([self selectedBitRate]),
                AVVideoMaxKeyFrameIntervalKey: @30,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            }
        };
    }
    self.videoWriterInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:videoSettings];
    self.videoWriterInput.expectsMediaDataInRealTime = YES;
    self.videoWriterInput.transform = CGAffineTransformIdentity;

    NSDictionary *pixelBufferAttributes = @{
        (NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (NSString *)kCVPixelBufferWidthKey: @((NSInteger)self.recordingCanvasSize.width),
        (NSString *)kCVPixelBufferHeightKey: @((NSInteger)self.recordingCanvasSize.height),
        (NSString *)kCVPixelBufferMetalCompatibilityKey: @YES,
    };
    self.pixelBufferAdaptor = [AVAssetWriterInputPixelBufferAdaptor
        assetWriterInputPixelBufferAdaptorWithAssetWriterInput:self.videoWriterInput
                                   sourcePixelBufferAttributes:pixelBufferAttributes];

    if ([self.assetWriter canAddInput:self.videoWriterInput]) {
        [self.assetWriter addInput:self.videoWriterInput];
    }

    if (self.microphoneAuthorized &&
        self.muteCheckbox.state != NSControlStateValueOn &&
        self.audioInput != nil) {
        NSDictionary<NSString *, id> *audioSettings = [self audioWriterSettingsForCurrentSession];
        self.audioWriterInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio outputSettings:audioSettings];
        self.audioWriterInput.expectsMediaDataInRealTime = YES;
        if ([self.assetWriter canAddInput:self.audioWriterInput]) {
            [self.assetWriter addInput:self.audioWriterInput];
            SpliceKit_log(@"[LiveCamAudio] writer format rate=%.0fHz channels=%lu codec=%@ bitrate=%@",
                          [audioSettings[AVSampleRateKey] doubleValue],
                          (unsigned long)[audioSettings[AVNumberOfChannelsKey] unsignedIntegerValue],
                          audioSettings[AVFormatIDKey] ?: @"",
                          audioSettings[AVEncoderBitRateKey] ?: @"");
        } else {
            self.audioWriterInput = nil;
        }
    } else {
        self.audioWriterInput = nil;
    }

    self.writerStartTime = kCMTimeInvalid;
    self.writerDidStart = NO;
    self.droppedVideoFrames = 0;
    self.droppedAudioFrames = 0;
    [self resetAudioDiagnosticsForRecording];

    SpliceKit_log(@"[LiveCamRecord] Writer prepared path=%@ final=%@ quality=%@ canvas=%.0fx%.0f",
                  self.temporaryRecordingURL.path,
                  self.finalRecordingURL.path,
                  self.qualityPopup.titleOfSelectedItem ?: @"",
                  self.recordingCanvasSize.width,
                  self.recordingCanvasSize.height);
}

- (void)startElapsedTimer {
    [self.elapsedTimer invalidate];
    self.elapsedTimer = [NSTimer scheduledTimerWithTimeInterval:0.25
                                                         target:self
                                                       selector:@selector(updateElapsedTime)
                                                       userInfo:nil
                                                        repeats:YES];
}

- (void)updateElapsedTime {
    if (!self.recordingStartDate) {
        self.elapsedLabel.stringValue = @"00:00:00";
        return;
    }
    NSInteger total = (NSInteger)round([[NSDate date] timeIntervalSinceDate:self.recordingStartDate]);
    NSInteger hours = total / 3600;
    NSInteger minutes = (total / 60) % 60;
    NSInteger seconds = total % 60;
    self.elapsedLabel.stringValue = [NSString stringWithFormat:@"%02ld:%02ld:%02ld",
                                     (long)hours, (long)minutes, (long)seconds];
}

- (void)recordClicked:(id)sender {
    if (self.recordingActive || self.finalizingRecording) return;
    if (!self.cameraAuthorized) {
        [self updateStatus:@"LiveCam needs camera permission before it can record."];
        return;
    }
    if (!self.session || !self.session.isRunning) {
        [self updateStatus:@"The camera session is not running yet. Wait for preview, then record."];
        return;
    }

    self.recordingDestination = [self selectedDestination];
    self.recordingPlacement = [self selectedTimelinePlacement];
    self.recordingSequenceIdentity = nil;
    self.recordingEventName = SpliceKitLiveCamTrimmedString(self.eventNameField.stringValue);
    self.recordingClipName = [self recordingBaseName];

    if (self.recordingDestination == SpliceKitLiveCamDestinationTimeline) {
        NSDictionary *identity = SpliceKitLiveCamCurrentTimelineIdentity();
        if (identity.count == 0) {
            SpliceKit_log(@"[LiveCamTimeline] No active timeline at record start; LiveCam will fall back to Library.");
            self.recordingDestination = SpliceKitLiveCamDestinationLibrary;
        } else {
            self.recordingSequenceIdentity = identity;
        }
    }

    [self prepareWriterForCurrentSettings];
    if (!self.assetWriter) {
        [self updateStatus:@"LiveCam could not create a writer for this recording."];
        return;
    }

    self.recordingActive = YES;
    self.finalizingRecording = NO;
    self.recordingStartDate = [NSDate date];
    [self startElapsedTimer];
    [self updateElapsedTime];
    [self updateStatus:[NSString stringWithFormat:@"Recording %@. Stop to finalize, import, and %@.",
                        self.recordingClipName,
                        self.recordingDestination == SpliceKitLiveCamDestinationTimeline ? @"place it on the timeline" : @"import it into the Library"]];
    [self updateSessionLabel:[NSString stringWithFormat:@"REC • %@ • %@",
                              self.resolutionPopup.titleOfSelectedItem ?: @"",
                              self.frameRatePopup.titleOfSelectedItem ?: @""]];
    [self updateControlsForState];

    SpliceKit_log(@"[LiveCamRecord] start clip=%@ camera=%@ mic=%@ preset=%@ destination=%@ placement=%ld",
                  self.recordingClipName,
                  self.cameraPopup.selectedItem.title ?: @"",
                  self.microphonePopup.selectedItem.title ?: @"",
                  [self selectedPreset].name ?: @"Clean",
                  self.recordingDestination == SpliceKitLiveCamDestinationTimeline ? @"timeline" : @"library",
                  (long)self.recordingPlacement);
}

- (void)finishWriterAndIngest {
    if (!self.assetWriter) {
        self.finalizingRecording = NO;
        [self updateControlsForState];
        return;
    }

    AVAssetWriter *writer = self.assetWriter;
    AVAssetWriterInput *videoInput = self.videoWriterInput;
    AVAssetWriterInput *audioInput = self.audioWriterInput;
    NSURL *tempURL = self.temporaryRecordingURL;
    NSURL *finalURL = self.finalRecordingURL;

    self.assetWriter = nil;
    self.videoWriterInput = nil;
    self.audioWriterInput = nil;
    self.pixelBufferAdaptor = nil;

    if (!self.writerDidStart) {
        [writer cancelWriting];
        [[NSFileManager defaultManager] removeItemAtURL:tempURL error:nil];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.finalizingRecording = NO;
            self.elapsedLabel.stringValue = @"00:00:00";
            [self updateStatus:@"LiveCam stopped before any frames were written, so nothing was imported."];
            [self updateControlsForState];
        });
        return;
    }

    [videoInput markAsFinished];
    [audioInput markAsFinished];

    [writer finishWritingWithCompletionHandler:^{
        if (writer.status != AVAssetWriterStatusCompleted) {
            SpliceKit_log(@"[LiveCamRecord] finishWriting failed: %@", writer.error.localizedDescription);
            [[NSFileManager defaultManager] removeItemAtURL:tempURL error:nil];
            dispatch_async(dispatch_get_main_queue(), ^{
                self.finalizingRecording = NO;
                self.elapsedLabel.stringValue = @"00:00:00";
                [self updateStatus:[NSString stringWithFormat:@"Finalizing failed: %@",
                                    writer.error.localizedDescription ?: @"Unknown error"]];
                [self updateControlsForState];
            });
            return;
        }

        [[NSFileManager defaultManager] removeItemAtURL:finalURL error:nil];
        NSError *moveError = nil;
        if (![[NSFileManager defaultManager] moveItemAtURL:tempURL toURL:finalURL error:&moveError]) {
            SpliceKit_log(@"[LiveCamRecord] Failed to move final clip: %@", moveError.localizedDescription);
            dispatch_async(dispatch_get_main_queue(), ^{
                self.finalizingRecording = NO;
                [self updateStatus:[NSString stringWithFormat:@"Finalized, but could not move the clip: %@",
                                    moveError.localizedDescription ?: @"Unknown error"]];
                [self updateControlsForState];
            });
            return;
        }

        SpliceKit_log(@"[LiveCamRecord] finalized output=%@ droppedVideo=%lu droppedAudio=%lu sourceAudioDiscontinuities=%lu sourceAudioGapFrames=%lu audio=%.0fHz/%luch",
                      finalURL.path,
                      (unsigned long)self.droppedVideoFrames,
                      (unsigned long)self.droppedAudioFrames,
                      (unsigned long)self.sourceAudioDiscontinuities,
                      (unsigned long)self.sourceAudioGapFrames,
                      self.capturedAudioSampleRate,
                      (unsigned long)self.capturedAudioChannels);

        dispatch_async(dispatch_get_main_queue(), ^{
            [self updateStatus:@"Finalizing complete. Importing into Final Cut Pro…"];
            [self updateSessionLabel:@"Importing…"];
        });

        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSDictionary *result = [self ingestFinalizedRecordingAtURL:finalURL];
            dispatch_async(dispatch_get_main_queue(), ^{
                self.finalizingRecording = NO;
                self.elapsedLabel.stringValue = @"00:00:00";
                [self updateStatus:SpliceKitLiveCamString(result[@"message"]).length > 0
                    ? result[@"message"]
                    : @"LiveCam finished."];
                NSString *readyCamera = [self.cameraPopup.titleOfSelectedItem ?: @"" stringByReplacingOccurrencesOfString:@" Camera" withString:@""];
                [self updateSessionLabel:[NSString stringWithFormat:@"Ready • %@ • %@",
                                          readyCamera.length > 0 ? readyCamera : (self.cameraPopup.titleOfSelectedItem ?: @""),
                                          self.microphonePopup.titleOfSelectedItem ?: @"No Microphone"]];
                [self updateControlsForState];
            });
        });
    }];
}

- (void)stopClicked:(id)sender {
    if (!self.recordingActive && !self.finalizingRecording) return;
    self.recordingActive = NO;
    self.finalizingRecording = YES;
    [self.elapsedTimer invalidate];
    self.elapsedTimer = nil;
    [self updateStatus:@"Stopping capture and finalizing the LiveCam clip…"];
    [self updateControlsForState];
    [self finishWriterAndIngest];
}

- (NSDictionary *)verifyConnectedPlacementForClipName:(NSString *)clipName {
    for (NSInteger lane = 1; lane <= 4; lane++) {
        NSDictionary *response = SpliceKit_handleRequest(@{
            @"method": @"timeline.selectClipInLane",
            @"params": @{@"lane": @(lane)}
        });
        NSDictionary *result = response[@"result"] ?: response;
        if (result[@"error"]) continue;
        NSString *actual = SpliceKitLiveCamString(result[@"clip"]);
        if (actual.length > 0 &&
            ([[actual lowercaseString] isEqualToString:[clipName lowercaseString]] ||
             [[actual lowercaseString] containsString:[clipName lowercaseString]])) {
            return @{
                @"verified": @YES,
                @"lane": @(lane),
                @"clip": actual,
            };
        }
    }
    return @{@"verified": @NO,
             @"error": @"Connected placement could not be verified at the playhead."};
}

- (NSDictionary *)ingestFinalizedRecordingAtURL:(NSURL *)url {
    NSDictionary *mediaInfo = SpliceKitLiveCamInspectMediaAtURL(url);
    if (mediaInfo[@"error"]) {
        return @{@"message": [NSString stringWithFormat:@"LiveCam saved the file, but inspection failed: %@",
                              mediaInfo[@"error"]]};
    }

    NSString *eventName = self.recordingEventName.length > 0
        ? self.recordingEventName
        : SpliceKitLiveCamCurrentTimelineEventName();
    if (eventName.length == 0) eventName = @"LiveCam";

    NSString *xml = SpliceKitLiveCamImportXML(url, self.recordingClipName, eventName, mediaInfo);
    SpliceKit_log(@"[LiveCamImport] importing clip=%@ event=%@ path=%@",
                  self.recordingClipName, eventName, url.path);
    NSDictionary *importResponse = SpliceKit_handleRequest(@{
        @"method": @"fcpxml.import",
        @"params": @{@"xml": xml, @"internal": @YES}
    });
    NSDictionary *importResult = importResponse[@"result"] ?: importResponse;
    if (importResult[@"error"]) {
        return @{@"message": [NSString stringWithFormat:@"LiveCam saved the clip to %@, but Final Cut import failed: %@",
                              url.path,
                              importResult[@"error"]]};
    }

    id clip = nil;
    for (NSInteger attempt = 0; attempt < 15 && !clip; attempt++) {
        clip = SpliceKitLiveCamFindClipNamed(self.recordingClipName, eventName);
        if (!clip) [NSThread sleepForTimeInterval:0.2];
    }

    if (!clip) {
        return @{@"message": [NSString stringWithFormat:@"LiveCam imported the file into %@, but could not re-find the browser clip for reveal or timeline placement.",
                              eventName]};
    }

    NSString *handle = SpliceKit_storeHandle(clip);
    if (handle.length == 0) {
        return @{@"message": [NSString stringWithFormat:@"LiveCam imported %@ into %@, but could not prepare the clip for placement.",
                              self.recordingClipName,
                              eventName]};
    }

    SpliceKitLiveCamSelectClipInBrowser(clip);

    if (self.recordingDestination == SpliceKitLiveCamDestinationLibrary) {
        return @{@"message": [NSString stringWithFormat:@"LiveCam saved %@ and imported it into the %@ event.",
                              self.recordingClipName,
                              eventName]};
    }

    NSDictionary *currentIdentity = SpliceKitLiveCamCurrentTimelineIdentity();
    if (!SpliceKitLiveCamHasActiveTimeline() ||
        !SpliceKitLiveCamTimelineIdentityMatches(self.recordingSequenceIdentity, currentIdentity)) {
        SpliceKit_log(@"[LiveCamTimeline] Timeline changed during recording. expected=%@ current=%@",
                      self.recordingSequenceIdentity, currentIdentity);
        return @{@"message": [NSString stringWithFormat:@"LiveCam imported %@ into %@, but the active timeline changed during recording so it stayed in the Library instead.",
                              self.recordingClipName,
                              eventName]};
    }

    if (self.recordingPlacement == SpliceKitLiveCamTimelinePlacementConnectedAbove) {
        NSDictionary *placementResponse = SpliceKit_handleRequest(@{
            @"method": @"browser.connectClip",
            @"params": @{@"handle": handle}
        });
        NSDictionary *placementResult = placementResponse[@"result"] ?: placementResponse;
        if (placementResult[@"error"]) {
            SpliceKit_log(@"[LiveCamTimeline] explicit connect failed: %@", placementResult[@"error"]);
            return @{@"message": [NSString stringWithFormat:@"LiveCam imported %@ into %@, but connected timeline insertion failed: %@",
                                  self.recordingClipName,
                                  eventName,
                                  placementResult[@"error"]]};
        }

        NSDictionary *verify = [self verifyConnectedPlacementForClipName:self.recordingClipName];
        if ([verify[@"verified"] boolValue]) {
            NSInteger lane = [verify[@"lane"] integerValue];
            SpliceKit_log(@"[LiveCamVerify] connected placement verified clip=%@ lane=%ld",
                          self.recordingClipName,
                          (long)lane);
            return @{@"message": [NSString stringWithFormat:@"LiveCam imported %@ into %@ and connected it above the storyline at the playhead (lane %ld).",
                                  self.recordingClipName,
                                  eventName,
                                  (long)lane]};
        }

        SpliceKit_log(@"[LiveCamVerify] connect placement unverified: %@", verify[@"error"]);
        return @{@"message": [NSString stringWithFormat:@"LiveCam imported %@ into %@, but connected placement could not be verified so the clip was left in the Library.",
                              self.recordingClipName,
                              eventName]};
    }

    NSString *method = self.recordingPlacement == SpliceKitLiveCamTimelinePlacementInsertAtPlayhead
        ? @"browser.insertClip"
        : @"browser.appendClip";
    NSDictionary *placementResponse = SpliceKit_handleRequest(@{
        @"method": method,
        @"params": @{@"handle": handle}
    });
    NSDictionary *placementResult = placementResponse[@"result"] ?: placementResponse;
    if (placementResult[@"error"]) {
        SpliceKit_log(@"[LiveCamTimeline] placement failed method=%@ error=%@", method, placementResult[@"error"]);
        return @{@"message": [NSString stringWithFormat:@"LiveCam imported %@ into %@, but %@ failed so the clip stayed in the Library.",
                              self.recordingClipName,
                              eventName,
                              self.recordingPlacement == SpliceKitLiveCamTimelinePlacementInsertAtPlayhead ? @"playhead insertion" : @"append placement"]};
    }

    SpliceKit_log(@"[LiveCamTimeline] placement verified=%@ debug=%@",
                  placementResult[@"placementVerified"],
                  placementResult[@"placementDebug"]);

    NSString *placementText = self.recordingPlacement == SpliceKitLiveCamTimelinePlacementInsertAtPlayhead
        ? @"inserted it at the playhead"
        : @"appended it to the end of the active timeline";
    return @{@"message": [NSString stringWithFormat:@"LiveCam imported %@ into %@ and %@.",
                          self.recordingClipName,
                          eventName,
                          placementText]};
}

- (void)trackAudioFormatAndContinuityFromSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    CMFormatDescriptionRef format = CMSampleBufferGetFormatDescription(sampleBuffer);
    const AudioStreamBasicDescription *asbd =
        CMAudioFormatDescriptionGetStreamBasicDescription(format);
    if (!asbd) return;

    double sampleRate = asbd->mSampleRate;
    NSUInteger channels = asbd->mChannelsPerFrame;
    BOOL formatChanged = !self.audioFormatLogged ||
        fabs(self.capturedAudioSampleRate - sampleRate) > 0.5 ||
        self.capturedAudioChannels != channels;
    self.capturedAudioSampleRate = sampleRate;
    self.capturedAudioChannels = channels;
    if (formatChanged) {
        self.audioFormatLogged = YES;
        SpliceKit_log(@"[LiveCamAudio] source format rate=%.0fHz channels=%lu format=0x%08x flags=0x%08x bits=%u bytesPerFrame=%u",
                      sampleRate,
                      (unsigned long)channels,
                      (unsigned int)asbd->mFormatID,
                      (unsigned int)asbd->mFormatFlags,
                      (unsigned int)asbd->mBitsPerChannel,
                      (unsigned int)asbd->mBytesPerFrame);
    }

    CMTime pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
    CMItemCount sampleCount = CMSampleBufferGetNumSamples(sampleBuffer);
    if (!CMTIME_IS_VALID(pts) || sampleRate <= 0.0 || sampleCount <= 0) {
        self.expectedNextAudioPTS = kCMTimeInvalid;
        return;
    }

    if (self.recordingActive && CMTIME_IS_VALID(self.expectedNextAudioPTS)) {
        double gapSeconds = CMTimeGetSeconds(CMTimeSubtract(pts, self.expectedNextAudioPTS));
        // Host-time conversion can introduce sub-millisecond rounding. A gap
        // beyond 2 ms is large enough to be audible and indicates a capture
        // discontinuity, even when AVAssetWriter itself reports zero drops.
        if (isfinite(gapSeconds) && fabs(gapSeconds) > 0.002) {
            self.sourceAudioDiscontinuities += 1;
            self.sourceAudioGapFrames += (NSUInteger)llround(fabs(gapSeconds) * sampleRate);
            NSUInteger eventCount = self.sourceAudioDiscontinuities;
            if (eventCount <= 8 || eventCount % 25 == 0) {
                SpliceKit_log(@"[LiveCamAudio] source discontinuity #%lu gap=%+.3fms near %.3fs",
                              (unsigned long)eventCount,
                              gapSeconds * 1000.0,
                              CMTimeGetSeconds(pts));
            }
        }
    }

    CMTime bufferDuration = CMTimeMakeWithSeconds((double)sampleCount / sampleRate, 1000000000);
    self.expectedNextAudioPTS = CMTimeAdd(pts, bufferDuration);
}

- (void)handleAudioMeterFromSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    self.audioMeterBuffersReceived += 1;

    // Metering is intentionally capped at 20 Hz. Do this before inspecting or
    // copying the PCM payload so the audio callback stays lightweight even for
    // high-rate/multichannel devices.
    NSTimeInterval now = CACurrentMediaTime();
    if (now - self.lastAudioMeterDispatchTime < 0.05) return;
    self.lastAudioMeterDispatchTime = now;

    CMFormatDescriptionRef format = CMSampleBufferGetFormatDescription(sampleBuffer);
    const AudioStreamBasicDescription *asbd =
        CMAudioFormatDescriptionGetStreamBasicDescription(format);
    if (!asbd) return;

    // Ask Core Media for the exact AudioBufferList size first. AVCapture can
    // return more buffers than the old fixed stack-sized estimate (especially
    // for non-interleaved and aggregate devices), in which case the previous
    // code returned kCMSampleBufferError_ArrayTooSmall and silently left the
    // UI frozen. The first call is a size query and does not copy audio.
    size_t bufferListSize = 0;
    OSStatus status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
        sampleBuffer,
        &bufferListSize,
        NULL,
        0,
        NULL,
        NULL,
        0,
        NULL);
    if (status != noErr || bufferListSize < sizeof(AudioBufferList)) {
        self.audioMeterLastError = status != noErr ? status : kCMSampleBufferError_ArrayTooSmall;
        return;
    }

    AudioBufferList *audioBufferList = calloc(1, bufferListSize);
    if (!audioBufferList) return;

    CMBlockBufferRef blockBuffer = NULL;
    status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
        sampleBuffer,
        NULL,
        audioBufferList,
        bufferListSize,
        NULL,
        NULL,
        kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
        &blockBuffer);

    if (status != noErr) {
        self.audioMeterLastError = status;
        free(audioBufferList);
        if (blockBuffer) CFRelease(blockBuffer);
        return;
    }

    double total = 0.0;
    double peak = 0.0;
    NSUInteger count = 0;
    for (UInt32 i = 0; i < audioBufferList->mNumberBuffers; i++) {
        AudioBuffer buffer = audioBufferList->mBuffers[i];
        if (!buffer.mData || buffer.mDataByteSize == 0) continue;

        BOOL isFloat = (asbd->mFormatFlags & kAudioFormatFlagIsFloat) != 0;
        BOOL isSignedInteger = (asbd->mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0;
        if (isFloat && asbd->mBitsPerChannel == 32) {
            const float *samples = (const float *)buffer.mData;
            NSUInteger sampleCount = buffer.mDataByteSize / sizeof(float);
            for (NSUInteger s = 0; s < sampleCount; s++) {
                double value = samples[s];
                total += value * value;
                peak = MAX(peak, fabs(value));
            }
            count += sampleCount;
        } else if (isFloat && asbd->mBitsPerChannel == 64) {
            const double *samples = (const double *)buffer.mData;
            NSUInteger sampleCount = buffer.mDataByteSize / sizeof(double);
            for (NSUInteger s = 0; s < sampleCount; s++) {
                double value = samples[s];
                total += value * value;
                peak = MAX(peak, fabs(value));
            }
            count += sampleCount;
        } else if (isSignedInteger && asbd->mBitsPerChannel == 16) {
            const int16_t *samples = (const int16_t *)buffer.mData;
            NSUInteger sampleCount = buffer.mDataByteSize / sizeof(int16_t);
            for (NSUInteger s = 0; s < sampleCount; s++) {
                double normalized = (double)samples[s] / 32768.0;
                total += normalized * normalized;
                peak = MAX(peak, fabs(normalized));
            }
            count += sampleCount;
        } else if (isSignedInteger && asbd->mBitsPerChannel == 24) {
            BOOL nonInterleaved =
                (asbd->mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
            BOOL bigEndian =
                (asbd->mFormatFlags & kAudioFormatFlagIsBigEndian) != 0;
            BOOL alignedHigh =
                (asbd->mFormatFlags & kAudioFormatFlagIsAlignedHigh) != 0;
            UInt32 bytesPerSample = nonInterleaved
                ? asbd->mBytesPerFrame
                : (asbd->mChannelsPerFrame > 0
                    ? asbd->mBytesPerFrame / asbd->mChannelsPerFrame
                    : 0);

            if (bytesPerSample == 4) {
                const int32_t *samples = (const int32_t *)buffer.mData;
                NSUInteger sampleCount = buffer.mDataByteSize / sizeof(int32_t);
                for (NSUInteger s = 0; s < sampleCount; s++) {
                    int32_t value = samples[s];
                    if (bigEndian) value = (int32_t)CFSwapInt32BigToHost((uint32_t)value);
                    if (!alignedHigh) value = (int32_t)((uint32_t)value << 8);
                    double normalized = (double)value / 2147483648.0;
                    total += normalized * normalized;
                    peak = MAX(peak, fabs(normalized));
                }
                count += sampleCount;
            } else if (bytesPerSample == 3) {
                const uint8_t *bytes = (const uint8_t *)buffer.mData;
                NSUInteger sampleCount = buffer.mDataByteSize / 3;
                for (NSUInteger s = 0; s < sampleCount; s++) {
                    const uint8_t *sample = bytes + s * 3;
                    int32_t value = bigEndian
                        ? ((int32_t)sample[0] << 16) | ((int32_t)sample[1] << 8) | sample[2]
                        : ((int32_t)sample[2] << 16) | ((int32_t)sample[1] << 8) | sample[0];
                    if (value & 0x00800000) value |= (int32_t)0xff000000;
                    double normalized = (double)value / 8388608.0;
                    total += normalized * normalized;
                    peak = MAX(peak, fabs(normalized));
                }
                count += sampleCount;
            }
        } else if (isSignedInteger && asbd->mBitsPerChannel == 32) {
            const int32_t *samples = (const int32_t *)buffer.mData;
            NSUInteger sampleCount = buffer.mDataByteSize / sizeof(int32_t);
            for (NSUInteger s = 0; s < sampleCount; s++) {
                double normalized = (double)samples[s] / 2147483648.0;
                total += normalized * normalized;
                peak = MAX(peak, fabs(normalized));
            }
            count += sampleCount;
        }
    }

    if (blockBuffer) CFRelease(blockBuffer);
    free(audioBufferList);

    self.audioMeterDecodedSamples = count;
    if (count == 0) {
        self.audioMeterLastError = kCMSampleBufferError_InvalidMediaFormat;
        return;
    }
    self.audioMeterLastError = noErr;

    double rms = sqrt(total / (double)count);
    self.smoothedAudioLevel = (self.smoothedAudioLevel * 0.82) + (rms * 0.18);
    double rmsDB = self.smoothedAudioLevel > 0.000001
        ? 20.0 * log10(self.smoothedAudioLevel)
        : -60.0;
    double peakDB = peak > 0.000001 ? 20.0 * log10(peak) : -60.0;

    dispatch_async(dispatch_get_main_queue(), ^{
        [self.audioMeter updateWithRMSDB:rmsDB peakDB:peakDB];
    });
}

- (void)appendVideoFrame:(CIImage *)image atTime:(CMTime)presentationTime {
    if (!self.recordingActive || !self.assetWriter || !self.videoWriterInput || !self.pixelBufferAdaptor) return;
    if (!self.writerDidStart) {
        if (![self.assetWriter startWriting]) {
            SpliceKit_log(@"[LiveCamRecord] startWriting failed: %@", self.assetWriter.error.localizedDescription);
            self.droppedVideoFrames++;
            return;
        }
        [self.assetWriter startSessionAtSourceTime:presentationTime];
        self.writerDidStart = YES;
        self.writerStartTime = presentationTime;
        SpliceKit_log(@"[LiveCamRecord] session started at %.3fs", CMTimeGetSeconds(presentationTime));
    }

    if (!self.videoWriterInput.readyForMoreMediaData) {
        self.droppedVideoFrames++;
        return;
    }

    CVPixelBufferRef pixelBuffer = NULL;
    CVReturn createStatus = CVPixelBufferPoolCreatePixelBuffer(NULL,
                                                               self.pixelBufferAdaptor.pixelBufferPool,
                                                               &pixelBuffer);
    if (createStatus != kCVReturnSuccess || !pixelBuffer) {
        self.droppedVideoFrames++;
        return;
    }

    BOOL transparent = self.recordingIsTransparent;
    CIImage *fitted = [self.renderer imageFittedForCanvas:image
                                               canvasSize:self.recordingCanvasSize
                                                     fill:NO
                                            preserveAlpha:transparent];
    if (transparent) {
        // -[CIContext render:toCVPixelBuffer:bounds:colorSpace:] treats the destination
        // as opaque per Apple's docs and overwrites alpha to 1.0. CIRenderDestination
        // with alphaMode = Premultiplied is the only path that preserves source alpha.
        CIRenderDestination *dest = [[CIRenderDestination alloc] initWithPixelBuffer:pixelBuffer];
        dest.alphaMode = CIRenderDestinationAlphaPremultiplied;
        if (self.renderer.colorSpace) {
            dest.colorSpace = self.renderer.colorSpace;
        }
        NSError *renderErr = nil;
        CIRenderTask *task = [self.renderer.ciContext startTaskToRender:fitted
                                                          toDestination:dest
                                                                  error:&renderErr];
        if (task) {
            [task waitUntilCompletedAndReturnError:&renderErr];
        }
        if (renderErr) {
            SpliceKit_log(@"[LiveCamRecord] alpha render failed: %@", renderErr.localizedDescription);
        }
    } else {
        [self.renderer.ciContext render:fitted
                        toCVPixelBuffer:pixelBuffer
                                 bounds:CGRectMake(0, 0, self.recordingCanvasSize.width, self.recordingCanvasSize.height)
                             colorSpace:self.renderer.colorSpace];
    }

    if (![self.pixelBufferAdaptor appendPixelBuffer:pixelBuffer withPresentationTime:presentationTime]) {
        self.droppedVideoFrames++;
    }
    CVPixelBufferRelease(pixelBuffer);
}

- (void)appendAudioSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    if (!self.recordingActive || !self.audioWriterInput || !self.writerDidStart) return;
    CMTime pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
    if (CMTIME_IS_VALID(self.writerStartTime) && CMTIME_COMPARE_INLINE(pts, <, self.writerStartTime)) {
        return;
    }
    if (!self.audioWriterInput.readyForMoreMediaData) {
        self.droppedAudioFrames++;
        return;
    }
    if (![self.audioWriterInput appendSampleBuffer:sampleBuffer]) {
        self.droppedAudioFrames++;
    }
}

- (void)captureOutput:(AVCaptureOutput *)output
didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection {
    @autoreleasepool {
    if (output == self.videoOutput) {
        CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
        if (!imageBuffer) return;

        uint64_t frameStartTicks = mach_absolute_time();

        CIImage *source = [CIImage imageWithCVPixelBuffer:imageBuffer];
        if (!source) return;

        CMTime pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
        NSTimeInterval seconds = CMTimeGetSeconds(pts);
        SpliceKitLiveCamAdjustmentState *adjustments = [self.adjustments copy];
        SpliceKitLiveCamPreset *preset = [self selectedPreset];
        SpliceKitLiveCamBackgroundMode backgroundMode = [self selectedBackgroundMode];
        BOOL mirrored = (self.mirrorCheckbox.state == NSControlStateValueOn);
        CIImage *maskImage = nil;
        CIColor *backgroundColor = nil;
        SpliceKitLiveCamMaskParams *maskParams = nil;

        BOOL transparentBg = NO;
        if (backgroundMode == SpliceKitLiveCamBackgroundModeGreenScreen && self.segmentationEngine.supported) {
            maskImage = [self.segmentationEngine maskImageForSampleBuffer:sampleBuffer];
            NSString *colorKey = [self selectedBackgroundColorKey];
            transparentBg = [colorKey isEqualToString:@"transparent"];
            backgroundColor = transparentBg ? nil : SpliceKitLiveCamBackgroundCIColor(colorKey);
            maskParams = [[SpliceKitLiveCamMaskParams alloc] init];
            maskParams.edgeSoftness = self.backgroundEdgeSlider.doubleValue;
            maskParams.refinement = self.backgroundRefinementSlider.doubleValue;
            maskParams.choke = self.backgroundChokeSlider.doubleValue;
            maskParams.spill = self.backgroundSpillSlider.doubleValue;
            maskParams.wrap = self.backgroundWrapSlider.doubleValue;
            maskParams.temporalSmoothing = 0.45;
            maskParams.transparentBackground = transparentBg;
            maskParams.sourceGeneration = self.segmentationEngine.maskGeneration;
        }

        CIImage *rendered = [self.renderer renderedImageFromImage:source
                                                           preset:preset
                                                             time:seconds
                                                      adjustments:adjustments
                                                         maskImage:maskImage
                                                       maskParams:maskParams
                                                   backgroundColor:backgroundColor
                                                         mirrored:mirrored
                                                        recording:self.recordingActive
                                                       canvasSize:source.extent.size];
        // Preview composites alpha over a checkerboard so the user can see the cut.
        // The recording path keeps the untouched alpha-bearing frame.
        CIImage *previewImage = transparentBg
            ? [self.renderer imageByCompositingOverPreviewCheckerboard:rendered]
            : rendered;
        @synchronized (self) {
            self.latestPreviewImage = previewImage;
        }
        if (!self.previewDrawPending) {
            self.previewDrawPending = YES;
            dispatch_async(dispatch_get_main_queue(), ^{
                self.previewDrawPending = NO;
                [self.previewView draw];
            });
        }

        if (self.recordingActive) {
            [self appendVideoFrame:rendered atTime:pts];
        }

        // Perf instrumentation: accumulate per-frame render time and log a
        // summary every ~2 seconds with the number of masks materialized into
        // bounded history buffers and process RSS. CIImage.description is not
        // a reliable graph-depth metric on current Core Image releases.
        static mach_timebase_info_data_t timebase = {0, 0};
        if (timebase.denom == 0) mach_timebase_info(&timebase);
        double frameMs = ((mach_absolute_time() - frameStartTicks) * timebase.numer / (double)timebase.denom) / 1.0e6;
        self.perfFrameCount += 1;
        self.perfFrameMsSum += frameMs;
        if (frameMs > self.perfFrameMsMax) self.perfFrameMsMax = frameMs;
        NSTimeInterval now = CACurrentMediaTime();
        if (self.perfLastLogTime == 0) self.perfLastLogTime = now;
        if (now - self.perfLastLogTime >= 2.0 && self.perfFrameCount > 0) {
            double avgMs = self.perfFrameMsSum / self.perfFrameCount;
            double rssMB = SpliceKitLiveCamResidentMB();
            SpliceKit_log(@"[LiveCamPerf] frames=%lu avg=%.1fms max=%.1fms materializedMasks=%lu rss=%.1fMB input=%.0fx%.0f bg=%ld refinement=%.2f choke=%.2f edge=%.2f spill=%.2f wrap=%.2f",
                          (unsigned long)self.perfFrameCount,
                          avgMs,
                          self.perfFrameMsMax,
                          (unsigned long)self.renderer.maskHistoryFrames,
                          rssMB,
                          CGRectGetWidth(source.extent),
                          CGRectGetHeight(source.extent),
                          (long)backgroundMode,
                          self.backgroundRefinementSlider.doubleValue,
                          self.backgroundChokeSlider.doubleValue,
                          self.backgroundEdgeSlider.doubleValue,
                          self.backgroundSpillSlider.doubleValue,
                          self.backgroundWrapSlider.doubleValue);
            self.perfFrameCount = 0;
            self.perfFrameMsSum = 0;
            self.perfFrameMsMax = 0;
            self.perfLastLogTime = now;
        }
    } else if (output == self.audioOutput) {
        [self trackAudioFormatAndContinuityFromSampleBuffer:sampleBuffer];
        [self handleAudioMeterFromSampleBuffer:sampleBuffer];
        if (self.muteCheckbox.state != NSControlStateValueOn) {
            [self appendAudioSampleBuffer:sampleBuffer];
        }
    }
    }
}

- (void)drawInMTKView:(MTKView *)view {
    if (!view.currentDrawable) return;

    CIImage *image = nil;
    @synchronized (self) {
        image = self.latestPreviewImage;
    }
    if (!image) return;

    CGSize drawableSize = view.drawableSize;
    if (drawableSize.width <= 0 || drawableSize.height <= 0) return;

    CIImage *fitted = [self.renderer imageFittedForCanvas:image
                                               canvasSize:drawableSize
                                                     fill:NO];

    id<MTLCommandBuffer> commandBuffer = [self.renderer.commandQueue commandBuffer];
    if (!commandBuffer) return;

    [self.renderer.ciContext render:fitted
                       toMTLTexture:view.currentDrawable.texture
                      commandBuffer:commandBuffer
                             bounds:CGRectMake(0, 0, drawableSize.width, drawableSize.height)
                         colorSpace:self.renderer.colorSpace];
    [commandBuffer presentDrawable:view.currentDrawable];
    [commandBuffer commit];
}

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {
}

- (void)windowWillClose:(NSNotification *)notification {
    if (self.recordingActive) {
        [self stopClicked:nil];
    } else {
        [self hidePanel];
    }
}

@end

NSDictionary *SpliceKit_handleLiveCamShow(NSDictionary *params) {
    __block NSDictionary *status = nil;
    SpliceKit_executeOnMainThread(^{
        [[SpliceKitLiveCamPanel sharedPanel] showPanel];
        status = [[SpliceKitLiveCamPanel sharedPanel] statusSnapshot];
    });
    return status ?: @{@"status": @"ok"};
}

NSDictionary *SpliceKit_handleLiveCamHide(NSDictionary *params) {
    __block NSDictionary *status = nil;
    SpliceKit_executeOnMainThread(^{
        [[SpliceKitLiveCamPanel sharedPanel] hidePanel];
        status = [[SpliceKitLiveCamPanel sharedPanel] statusSnapshot];
    });
    return status ?: @{@"status": @"ok"};
}

NSDictionary *SpliceKit_handleLiveCamStatus(NSDictionary *params) {
    __block NSDictionary *status = nil;
    SpliceKit_executeOnMainThread(^{
        status = [[SpliceKitLiveCamPanel sharedPanel] statusSnapshot];
    });
    return status ?: @{@"visible": @NO, @"recording": @NO};
}
