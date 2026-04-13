#import "SpliceKitLiveCam.h"
#import "SpliceKit.h"
#import <AppKit/AppKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <QuartzCore/QuartzCore.h>
#import <Vision/Vision.h>
#import <objc/runtime.h>
#import <objc/message.h>

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
static NSString * const kLiveCamAdvancedVisibleKey = @"SpliceKitLiveCam.AdvancedVisible";

typedef NS_ENUM(NSInteger, SpliceKitLiveCamDestination) {
    SpliceKitLiveCamDestinationLibrary = 0,
    SpliceKitLiveCamDestinationTimeline = 1,
};

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
@"} }\n";

static NSString *SpliceKitLiveCamString(id value) {
    return [value isKindOfClass:[NSString class]] ? value : @"";
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

@interface SpliceKitLiveCamSegmentationEngine : NSObject
@property (nonatomic, assign, readonly) BOOL supported;
@property (nonatomic, copy, readonly) NSString *lastError;
- (CIImage *)maskImageForSampleBuffer:(CMSampleBufferRef)sampleBuffer;
- (void)reset;
@end

@interface SpliceKitLiveCamSegmentationEngine ()
@property (nonatomic, strong) VNSequenceRequestHandler *requestHandler;
@property (nonatomic, strong) VNGeneratePersonSegmentationRequest *request;
@property (nonatomic, assign) CVPixelBufferRef latestMaskBuffer;
@property (nonatomic, assign, readwrite) BOOL supported;
@property (nonatomic, copy, readwrite) NSString *lastError;
@property (nonatomic, assign) NSUInteger frameCounter;
@end

@implementation SpliceKitLiveCamSegmentationEngine

- (instancetype)init {
    self = [super init];
    if (!self) return nil;

    if (@available(macOS 12.0, *)) {
        _supported = YES;
        _requestHandler = [[VNSequenceRequestHandler alloc] init];
        _request = [[VNGeneratePersonSegmentationRequest alloc] init];
        _request.qualityLevel = VNGeneratePersonSegmentationRequestQualityLevelFast;
        _request.outputPixelFormat = kCVPixelFormatType_OneComponent8;
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
}

- (CIImage *)maskImageForSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    if (!self.supported || !sampleBuffer) return nil;

    self.frameCounter += 1;
    BOOL shouldAnalyze = (self.frameCounter <= 2) || (self.frameCounter % 2 == 0);
    if (shouldAnalyze) {
        NSError *error = nil;
        BOOL ok = [self.requestHandler performRequests:@[self.request]
                                       onCMSampleBuffer:sampleBuffer
                                                  error:&error];
        if (!ok || error) {
            self.lastError = error.localizedDescription ?: @"Vision could not generate a person mask.";
        } else {
            VNPixelBufferObservation *observation = (VNPixelBufferObservation *)self.request.results.firstObject;
            CVPixelBufferRef maskBuffer = observation.pixelBuffer;
            if (maskBuffer) {
                CVPixelBufferRetain(maskBuffer);
                if (self.latestMaskBuffer) {
                    CVPixelBufferRelease(self.latestMaskBuffer);
                }
                self.latestMaskBuffer = maskBuffer;
                self.lastError = @"";
            }
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
                    backgroundColor:(CIColor *)backgroundColor
                       edgeSoftness:(CGFloat)edgeSoftness
                           mirrored:(BOOL)mirrored
                          recording:(BOOL)recording
                         canvasSize:(CGSize)canvasSize;
- (CIImage *)imageFittedForCanvas:(CIImage *)image
                       canvasSize:(CGSize)canvasSize
                             fill:(BOOL)fill;
@end

@interface SpliceKitLiveCamRenderer ()
@property (nonatomic, strong) CIContext *ciContext;
@property (nonatomic, strong) id<MTLDevice> metalDevice;
@property (nonatomic, strong) id<MTLCommandQueue> commandQueue;
@property (nonatomic, assign) CGColorSpaceRef colorSpace;
@property (nonatomic, strong) NSMutableDictionary<NSString *, CIKernel *> *kernels;
@property (nonatomic, strong) NSMutableDictionary<NSString *, CIImage *> *overlayCache;
@property (nonatomic, strong) NSMutableArray<CIImage *> *trailFrames;
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
        }];
        SpliceKit_log(@"[LiveCamEffects] Metal-backed CIContext ready on %@", _metalDevice.name ?: @"<unnamed>");
    } else {
        _ciContext = [CIContext contextWithOptions:@{
            kCIContextWorkingColorSpace: (__bridge id)_colorSpace,
            kCIContextOutputColorSpace: (__bridge id)_colorSpace,
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
    CIColorKernel *kernel = (CIColorKernel *)self.kernels[name];
    if (![kernel isKindOfClass:[CIColorKernel class]]) return image;
    return [kernel applyWithExtent:image.extent arguments:arguments] ?: image;
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

- (CIImage *)renderedImageFromImage:(CIImage *)image
                             preset:(SpliceKitLiveCamPreset *)preset
                               time:(NSTimeInterval)time
                        adjustments:(SpliceKitLiveCamAdjustmentState *)adjustments
                          maskImage:(CIImage *)maskImage
                    backgroundColor:(CIColor *)backgroundColor
                       edgeSoftness:(CGFloat)edgeSoftness
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
        CIImage *mask = [self imageFittedForCanvas:maskImage
                                        canvasSize:originalExtent.size
                                              fill:YES];
        if (edgeSoftness > 0.01) {
            mask = SpliceKitLiveCamApplyFilter(mask, @"CIGaussianBlur", @{
                kCIInputRadiusKey: @(edgeSoftness * 10.0),
            });
            mask = [mask imageByCroppingToRect:originalExtent];
        }
        CIImage *background = SpliceKitLiveCamSolidColorImage(backgroundColor ?: SpliceKitLiveCamBackgroundCIColor(@"green"),
                                                              originalExtent);
        image = SpliceKitLiveCamApplyFilter(image, @"CIBlendWithMask", @{
            kCIInputBackgroundImageKey: background,
            kCIInputMaskImageKey: mask,
        });
        image = [image imageByCroppingToRect:originalExtent];
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

    return [self imageFittedForCanvas:[image imageByCroppingToRect:image.extent]
                           canvasSize:canvasSize
                                 fill:NO];
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
@property (nonatomic, strong) NSTextField *lookDescriptionLabel;
@property (nonatomic, strong) NSTextField *destinationHintLabel;
@property (nonatomic, strong) NSTextField *backgroundInfoLabel;
@property (nonatomic, strong) NSTextField *backgroundStatusLabel;
@property (nonatomic, strong) NSTextField *nameHintLabel;
@property (nonatomic, strong) NSLevelIndicator *audioMeter;
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
    _audioQueue = dispatch_queue_create("com.splicekit.livecam.audio", DISPATCH_QUEUE_SERIAL);
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

    NSTextField *titleLabel = [NSTextField labelWithString:title ?: @""];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel.font = [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold];
    titleLabel.textColor = titleColor ?: [NSColor colorWithWhite:0.88 alpha:0.92];
    titleLabel.alignment = NSTextAlignmentCenter;

    NSStackView *stack = [NSStackView stackViewWithViews:rows ?: @[]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.spacing = 5.0;
    stack.alignment = NSLayoutAttributeCenterX;
    stack.detachesHiddenViews = YES;

    [card addSubview:titleLabel];
    [card addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [titleLabel.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:8.0],
        [titleLabel.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-8.0],
        [titleLabel.topAnchor constraintEqualToAnchor:card.topAnchor constant:8.0],

        [stack.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:8.0],
        [stack.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-8.0],
        [stack.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:6.0],
        [stack.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-8.0],
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
    self.panel.minSize = NSMakeSize(760.0, 780.0);
    self.panel.maxSize = NSMakeSize(920.0, 940.0);
    self.panel.contentMinSize = NSMakeSize(760.0, 780.0);
    self.panel.contentMaxSize = NSMakeSize(920.0, 940.0);
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

    NSStackView *titleCluster = [NSStackView stackViewWithViews:@[titleIconView, titleLabel]];
    titleCluster.translatesAutoresizingMaskIntoConstraints = NO;
    titleCluster.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    titleCluster.spacing = 8.0;
    titleCluster.alignment = NSLayoutAttributeCenterY;
    titleCluster.detachesHiddenViews = YES;

    NSView *header = [[NSView alloc] initWithFrame:NSZeroRect];
    header.translatesAutoresizingMaskIntoConstraints = NO;
    [header addSubview:titleCluster];
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

    NSView *contentHost = [[NSView alloc] initWithFrame:NSZeroRect];
    contentHost.translatesAutoresizingMaskIntoConstraints = NO;

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
    self.backgroundColorPopup.target = self;
    self.backgroundColorPopup.action = @selector(configurationChanged:);

    self.backgroundEdgeSlider = [self configuredSliderWithValue:0.35 minValue:0.0 maxValue:1.0];
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

    self.audioMeter = [[NSLevelIndicator alloc] initWithFrame:NSZeroRect];
    self.audioMeter.levelIndicatorStyle = NSLevelIndicatorStyleContinuousCapacity;
    self.audioMeter.minValue = 0.0;
    self.audioMeter.maxValue = 100.0;
    self.audioMeter.warningValue = 70.0;
    self.audioMeter.criticalValue = 90.0;
    [self.audioMeter.heightAnchor constraintEqualToConstant:12.0].active = YES;

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

    NSArray<NSView *> *lookRows = @[
        [self labeledRowWithLabel:@"Category" control:self.lookCategoryPopup],
        [self labeledRowWithLabel:@"Preset" control:self.lookPresetPopup],
        [self centeredViewRow:self.lookDescriptionLabel],
        [self centeredViewRow:self.timestampOverlayCheckbox],
    ];

    self.backgroundColorRow = [self labeledRowWithLabel:@"Color" control:self.backgroundColorPopup];
    self.backgroundEdgeRow = [self sliderRowWithLabel:@"Edge Softness" slider:self.backgroundEdgeSlider];
    NSArray<NSView *> *backgroundRows = @[
        [self labeledRowWithLabel:@"Mode" control:self.backgroundModePopup],
        [self centeredViewRow:self.backgroundStatusLabel],
        [self centeredViewRow:self.openVideoEffectsButton],
        self.backgroundColorRow,
        self.backgroundEdgeRow,
    ];

    self.timelinePlacementRow = [self labeledRowWithLabel:@"Placement" control:self.timelinePlacementPopup];
    NSArray<NSView *> *destinationRows = @[
        [self labeledRowWithLabel:@"Record To" control:self.destinationControl],
        self.timelinePlacementRow,
        [self centeredViewRow:self.destinationHintLabel],
    ];

    NSView *captureRowOne = [self pairedCenteredRowsWithFirstLabel:@"Camera"
                                                      firstControl:self.cameraPopup
                                                         secondLabel:@"Microphone"
                                                       secondControl:self.microphonePopup];
    NSView *captureRowTwo = [self pairedCenteredRowsWithFirstLabel:@"Resolution"
                                                      firstControl:self.resolutionPopup
                                                         secondLabel:@"Frame Rate"
                                                       secondControl:self.frameRatePopup];
    NSView *captureRowThree = [self pairedCenteredRowsWithFirstLabel:@"Quality"
                                                        firstControl:self.qualityPopup
                                                           secondLabel:@"Input Level"
                                                         secondControl:self.audioMeter];
    NSArray<NSView *> *captureRows = @[
        captureRowOne,
        captureRowTwo,
        captureRowThree,
    ];

    NSArray<NSView *> *advancedRows = @[
        [self labeledRowWithLabel:@"Clip Name" control:self.clipNameField],
        [self labeledRowWithLabel:@"Event" control:self.eventNameField],
        self.mirrorCheckbox,
        self.muteCheckbox,
        [self sliderRowWithLabel:@"Intensity" slider:self.intensitySlider],
        [self sliderRowWithLabel:@"Exposure" slider:self.exposureSlider],
        [self sliderRowWithLabel:@"Contrast" slider:self.contrastSlider],
        [self sliderRowWithLabel:@"Saturation" slider:self.saturationSlider],
        [self sliderRowWithLabel:@"Warmth" slider:self.temperatureSlider],
        [self sliderRowWithLabel:@"Sharpness" slider:self.sharpnessSlider],
        [self sliderRowWithLabel:@"Glow" slider:self.glowSlider],
    ];

    NSStackView *advancedStack = [NSStackView stackViewWithViews:advancedRows];
    advancedStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    advancedStack.spacing = 8.0;
    advancedStack.alignment = NSLayoutAttributeLeading;
    advancedStack.detachesHiddenViews = YES;
    self.advancedContainer = advancedStack;

    self.advancedToggleButton = [NSButton buttonWithTitle:@"Show Advanced Controls"
                                                   target:self
                                                   action:@selector(toggleAdvancedControls:)];
    self.advancedToggleButton.bezelStyle = NSBezelStyleRounded;
    self.advancedToggleButton.controlSize = NSControlSizeSmall;

    NSView *lookSection = [self sectionCardWithTitle:@"Look"
                                                rows:lookRows
                                           titleColor:[NSColor colorWithSRGBRed:0.56 green:0.71 blue:1.0 alpha:1.0]];
    NSView *backgroundSection = [self sectionCardWithTitle:@"Background"
                                                       rows:backgroundRows
                                                  titleColor:[NSColor colorWithSRGBRed:0.58 green:0.85 blue:0.64 alpha:1.0]];
    NSView *destinationSection = [self sectionCardWithTitle:@"Destination"
                                                        rows:destinationRows
                                                   titleColor:[NSColor colorWithSRGBRed:1.0 green:0.72 blue:0.38 alpha:1.0]];
    NSView *captureSection = [self sectionCardWithTitle:@"Capture"
                                                   rows:captureRows
                                              titleColor:[NSColor colorWithSRGBRed:0.79 green:0.67 blue:1.0 alpha:1.0]];
    self.advancedSectionCard = [self sectionCardWithTitle:@"Advanced"
                                                     rows:@[self.advancedContainer]
                                                titleColor:[NSColor secondaryLabelColor]];
    self.advancedSectionCard.hidden = !self.advancedVisible;

    NSView *advancedToggleRow = [[NSView alloc] initWithFrame:NSZeroRect];
    advancedToggleRow.translatesAutoresizingMaskIntoConstraints = NO;
    [advancedToggleRow addSubview:self.advancedToggleButton];

    NSStackView *previewStack = [NSStackView stackViewWithViews:@[
        previewContainer,
        self.statusLabel,
        transportRow,
    ]];
    previewStack.translatesAutoresizingMaskIntoConstraints = NO;
    previewStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    previewStack.spacing = 4.0;
    previewStack.alignment = NSLayoutAttributeWidth;
    previewStack.detachesHiddenViews = YES;

    NSStackView *bottomControlRow = [NSStackView stackViewWithViews:@[lookSection, backgroundSection, destinationSection]];
    bottomControlRow.translatesAutoresizingMaskIntoConstraints = NO;
    bottomControlRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    bottomControlRow.spacing = 14.0;
    bottomControlRow.alignment = NSLayoutAttributeHeight;
    bottomControlRow.distribution = NSStackViewDistributionFillEqually;
    bottomControlRow.detachesHiddenViews = YES;

    NSView *bottomControlRowContainer = [self centeredViewRow:bottomControlRow];

    NSStackView *controlsGrid = [NSStackView stackViewWithViews:@[
        captureSection,
        bottomControlRowContainer,
    ]];
    controlsGrid.translatesAutoresizingMaskIntoConstraints = NO;
    controlsGrid.orientation = NSUserInterfaceLayoutOrientationVertical;
    controlsGrid.spacing = 10.0;
    controlsGrid.alignment = NSLayoutAttributeWidth;
    controlsGrid.distribution = NSStackViewDistributionFill;
    controlsGrid.detachesHiddenViews = YES;

    NSStackView *contentStack = [NSStackView stackViewWithViews:@[
        previewStack,
        controlsGrid,
        self.advancedSectionCard,
    ]];
    contentStack.translatesAutoresizingMaskIntoConstraints = NO;
    contentStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    contentStack.spacing = 12.0;
    contentStack.alignment = NSLayoutAttributeWidth;
    contentStack.detachesHiddenViews = YES;

    self.mainColumn = [[NSView alloc] initWithFrame:NSZeroRect];
    self.mainColumn.translatesAutoresizingMaskIntoConstraints = NO;
    [self.mainColumn addSubview:contentStack];
    [contentHost addSubview:self.mainColumn];
    [contentHost addSubview:advancedToggleRow];
    [background addSubview:header];
    [background addSubview:contentHost];

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

        [contentHost.leadingAnchor constraintEqualToAnchor:background.leadingAnchor constant:18.0],
        [contentHost.trailingAnchor constraintEqualToAnchor:background.trailingAnchor constant:-18.0],
        [contentHost.topAnchor constraintEqualToAnchor:header.bottomAnchor constant:12.0],
        [contentHost.bottomAnchor constraintEqualToAnchor:background.bottomAnchor constant:-16.0],
        [contentHost.widthAnchor constraintEqualToConstant:720.0],

        [self.mainColumn.leadingAnchor constraintEqualToAnchor:contentHost.leadingAnchor],
        [self.mainColumn.trailingAnchor constraintEqualToAnchor:contentHost.trailingAnchor],
        [self.mainColumn.topAnchor constraintEqualToAnchor:contentHost.topAnchor],
        [self.mainColumn.bottomAnchor constraintEqualToAnchor:advancedToggleRow.topAnchor constant:-12.0],
        [self.mainColumn.widthAnchor constraintEqualToConstant:720.0],

        [contentStack.leadingAnchor constraintEqualToAnchor:self.mainColumn.leadingAnchor],
        [contentStack.trailingAnchor constraintEqualToAnchor:self.mainColumn.trailingAnchor],
        [contentStack.topAnchor constraintEqualToAnchor:self.mainColumn.topAnchor],
        [contentStack.bottomAnchor constraintEqualToAnchor:self.mainColumn.bottomAnchor],

        [previewContainer.widthAnchor constraintEqualToAnchor:self.mainColumn.widthAnchor],
        [previewContainer.heightAnchor constraintEqualToAnchor:previewContainer.widthAnchor multiplier:(9.0 / 16.0)],

        [self.previewView.leadingAnchor constraintEqualToAnchor:previewContainer.leadingAnchor],
        [self.previewView.trailingAnchor constraintEqualToAnchor:previewContainer.trailingAnchor],
        [self.previewView.topAnchor constraintEqualToAnchor:previewContainer.topAnchor],
        [self.previewView.bottomAnchor constraintEqualToAnchor:previewContainer.bottomAnchor],

        [self.statusLabel.widthAnchor constraintEqualToAnchor:self.mainColumn.widthAnchor],

        [transportCluster.centerXAnchor constraintEqualToAnchor:transportRow.centerXAnchor],
        [transportCluster.topAnchor constraintEqualToAnchor:transportRow.topAnchor],
        [transportCluster.bottomAnchor constraintEqualToAnchor:transportRow.bottomAnchor],
        [transportRow.widthAnchor constraintEqualToAnchor:self.mainColumn.widthAnchor],

        [advancedToggleRow.leadingAnchor constraintEqualToAnchor:contentHost.leadingAnchor],
        [advancedToggleRow.trailingAnchor constraintEqualToAnchor:contentHost.trailingAnchor],
        [advancedToggleRow.bottomAnchor constraintEqualToAnchor:contentHost.bottomAnchor],
        [self.advancedToggleButton.trailingAnchor constraintEqualToAnchor:advancedToggleRow.trailingAnchor],
        [self.advancedToggleButton.topAnchor constraintEqualToAnchor:advancedToggleRow.topAnchor],
        [self.advancedToggleButton.bottomAnchor constraintEqualToAnchor:advancedToggleRow.bottomAnchor],

        [controlsGrid.widthAnchor constraintEqualToAnchor:self.mainColumn.widthAnchor],
        [captureSection.widthAnchor constraintEqualToAnchor:self.mainColumn.widthAnchor],
        [captureSection.heightAnchor constraintGreaterThanOrEqualToConstant:148.0],
        [lookSection.heightAnchor constraintEqualToAnchor:backgroundSection.heightAnchor],
        [backgroundSection.heightAnchor constraintEqualToAnchor:destinationSection.heightAnchor],
        [lookSection.heightAnchor constraintGreaterThanOrEqualToConstant:116.0],
        [backgroundSection.heightAnchor constraintGreaterThanOrEqualToConstant:116.0],
        [destinationSection.heightAnchor constraintGreaterThanOrEqualToConstant:116.0],
        [self.advancedSectionCard.widthAnchor constraintEqualToAnchor:self.mainColumn.widthAnchor],
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
        : 0.35;

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
    self.backgroundColorRow.hidden = !greenScreen;
    self.backgroundEdgeRow.hidden = !greenScreen;
    self.backgroundColorPopup.enabled = greenScreen;
    self.backgroundEdgeSlider.enabled = greenScreen;

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
            [self updateStatus:@"Camera permission is required for LiveCam. Enable camera access for Final Cut Pro, then reopen LiveCam."];
            [self updateSessionLabel:@"Camera permission denied"];
            [self updateControlsForState];
            return;
        }

        if (!self.microphoneAuthorized) {
            [self updateStatus:@"Microphone access is off, so LiveCam will preview video only until microphone permission is granted."];
        }

        [self reconfigurePreviewSession];
    });
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
        if ([session canSetSessionPreset:AVCaptureSessionPresetHigh]) {
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
        };
        [videoOutput setSampleBufferDelegate:self queue:self.videoQueue];
        if ([session canAddOutput:videoOutput]) {
            [session addOutput:videoOutput];
            self.videoOutput = videoOutput;
        }

        AVCaptureAudioDataOutput *audioOutput = [[AVCaptureAudioDataOutput alloc] init];
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
        self.latestPreviewImage = nil;
        [self.segmentationEngine reset];

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
        self.latestPreviewImage = nil;
        [self.segmentationEngine reset];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.audioMeter.doubleValue = 0.0;
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

- (void)backgroundModeChanged:(id)sender {
    if ([self selectedBackgroundMode] != SpliceKitLiveCamBackgroundModeGreenScreen) {
        [self.segmentationEngine reset];
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

    NSDictionary *videoSettings = @{
        AVVideoCodecKey: AVVideoCodecTypeH264,
        AVVideoWidthKey: @((NSInteger)self.recordingCanvasSize.width),
        AVVideoHeightKey: @((NSInteger)self.recordingCanvasSize.height),
        AVVideoCompressionPropertiesKey: @{
            AVVideoAverageBitRateKey: @([self selectedBitRate]),
            AVVideoMaxKeyFrameIntervalKey: @30,
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
        }
    };
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
        NSDictionary *audioSettings = @{
            AVFormatIDKey: @(kAudioFormatMPEG4AAC),
            AVNumberOfChannelsKey: @2,
            AVSampleRateKey: @48000,
            AVEncoderBitRateKey: @128000,
        };
        self.audioWriterInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio outputSettings:audioSettings];
        self.audioWriterInput.expectsMediaDataInRealTime = YES;
        if ([self.assetWriter canAddInput:self.audioWriterInput]) {
            [self.assetWriter addInput:self.audioWriterInput];
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

        SpliceKit_log(@"[LiveCamRecord] finalized output=%@ droppedVideo=%lu droppedAudio=%lu",
                      finalURL.path,
                      (unsigned long)self.droppedVideoFrames,
                      (unsigned long)self.droppedAudioFrames);

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

- (void)handleAudioMeterFromSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    CMFormatDescriptionRef format = CMSampleBufferGetFormatDescription(sampleBuffer);
    const AudioStreamBasicDescription *asbd =
        CMAudioFormatDescriptionGetStreamBasicDescription(format);
    if (!asbd) return;

    UInt32 bufferListSize = sizeof(AudioBufferList) + sizeof(AudioBuffer) * 8;
    AudioBufferList *audioBufferList = malloc(bufferListSize);
    if (!audioBufferList) return;

    CMBlockBufferRef blockBuffer = NULL;
    OSStatus status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
        sampleBuffer,
        NULL,
        audioBufferList,
        bufferListSize,
        NULL,
        NULL,
        kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
        &blockBuffer);

    if (status != noErr) {
        free(audioBufferList);
        if (blockBuffer) CFRelease(blockBuffer);
        return;
    }

    double total = 0.0;
    NSUInteger count = 0;
    for (UInt32 i = 0; i < audioBufferList->mNumberBuffers; i++) {
        AudioBuffer buffer = audioBufferList->mBuffers[i];
        if (!buffer.mData || buffer.mDataByteSize == 0) continue;

        if ((asbd->mFormatFlags & kAudioFormatFlagIsFloat) != 0) {
            const float *samples = (const float *)buffer.mData;
            NSUInteger sampleCount = buffer.mDataByteSize / sizeof(float);
            for (NSUInteger s = 0; s < sampleCount; s++) {
                total += samples[s] * samples[s];
            }
            count += sampleCount;
        } else {
            const int16_t *samples = (const int16_t *)buffer.mData;
            NSUInteger sampleCount = buffer.mDataByteSize / sizeof(int16_t);
            for (NSUInteger s = 0; s < sampleCount; s++) {
                double normalized = (double)samples[s] / 32768.0;
                total += normalized * normalized;
            }
            count += sampleCount;
        }
    }

    if (blockBuffer) CFRelease(blockBuffer);
    free(audioBufferList);

    if (count == 0) return;

    double rms = sqrt(total / (double)count);
    self.smoothedAudioLevel = (self.smoothedAudioLevel * 0.82) + (rms * 0.18);
    double meterValue = MIN(100.0, self.smoothedAudioLevel * 180.0);

    dispatch_async(dispatch_get_main_queue(), ^{
        self.audioMeter.doubleValue = meterValue;
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

    CIImage *fitted = [self.renderer imageFittedForCanvas:image
                                               canvasSize:self.recordingCanvasSize
                                                     fill:NO];
    [self.renderer.ciContext render:fitted
                    toCVPixelBuffer:pixelBuffer
                             bounds:CGRectMake(0, 0, self.recordingCanvasSize.width, self.recordingCanvasSize.height)
                         colorSpace:self.renderer.colorSpace];

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
    if (output == self.videoOutput) {
        CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
        if (!imageBuffer) return;

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
        CGFloat edgeSoftness = 0.0;

        if (backgroundMode == SpliceKitLiveCamBackgroundModeGreenScreen && self.segmentationEngine.supported) {
            maskImage = [self.segmentationEngine maskImageForSampleBuffer:sampleBuffer];
            backgroundColor = SpliceKitLiveCamBackgroundCIColor([self selectedBackgroundColorKey]);
            edgeSoftness = self.backgroundEdgeSlider.doubleValue;
        }

        CIImage *rendered = [self.renderer renderedImageFromImage:source
                                                           preset:preset
                                                             time:seconds
                                                      adjustments:adjustments
                                                         maskImage:maskImage
                                                   backgroundColor:backgroundColor
                                                      edgeSoftness:edgeSoftness
                                                         mirrored:mirrored
                                                        recording:self.recordingActive
                                                       canvasSize:source.extent.size];
        @synchronized (self) {
            self.latestPreviewImage = rendered;
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
    } else if (output == self.audioOutput) {
        [self handleAudioMeterFromSampleBuffer:sampleBuffer];
        if (self.muteCheckbox.state != NSControlStateValueOn) {
            [self appendAudioSampleBuffer:sampleBuffer];
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
