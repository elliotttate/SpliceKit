//
//  SpliceKitCaptionPanel.m
//  Social media-style captions — word-by-word highlighted, animated titles
//  inserted directly into FCP's timeline via the Objective-C runtime.
//
//  FCPXML is still generated for export/debug/fallback. For each caption
//  segment we can build a <title> element with styled text, positioning,
//  and optional keyframe animations. For word-by-word highlight mode, each
//  word in a segment gets its own sequential title where that word is
//  highlighted and the rest are dimmed.
//
//  Transcription is delegated to SpliceKitTranscriptPanel's Parakeet engine.
//

#import "SpliceKitCaptionPanel.h"
#import "SpliceKit.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <float.h>
#import <QuartzCore/QuartzCore.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <dlfcn.h>

// ARM64 returns all structs via objc_msgSend; x86_64 needs _stret for structs >16 bytes.
#if defined(__x86_64__)
#define STRET_MSG objc_msgSend_stret
#else
#define STRET_MSG objc_msgSend
#endif

NSNotificationName const SpliceKitCaptionDidGenerateNotification = @"SpliceKitCaptionDidGenerate";

// Forward declare properties for panel UI
@interface SpliceKitCaptionPanel ()
@property (nonatomic, strong) NSTextField *statusLabel;
@end

extern id SpliceKit_getActiveTimelineModule(void);
extern NSDictionary *SpliceKit_handlePasteboardImportXML(NSDictionary *params);

typedef struct {
    int64_t value;
    int32_t timescale;
    uint32_t flags;
    int64_t epoch;
} SpliceKitCaption_CMTime;

typedef struct {
    SpliceKitCaption_CMTime start;
    SpliceKitCaption_CMTime duration;
} SpliceKitCaption_CMTimeRange;

#pragma mark - Word-Progress Template Config (SpliceKit Caption)
//
// mCaptions emits only 3 params per title — Content Position, Content Opacity
// (fade-out), and Custom Speed (word-progress keyframes). All other params
// (Animate=Word, Speed=Custom, highlight colors, glow, etc.) are baked into
// the Motion template as defaults.
//
// Content Position and Content Opacity key paths are universal (on the Widget's
// Content layer 10003). Custom Speed path depends on the template hierarchy:
//   Content (10003) → Text (10061) → behaviors (4) → SeqText (500001) → Controls (201) → CustomSpeed (209)
//
static NSString * const kWP_ContentPositionKey = @"9999/10003/1/100/101";
static NSString * const kWP_ContentOpacityKey  = @"9999/10003/1/200/202";
// Neon Grow TM4C key path (mCaptions template with Sequence Text behaviors)
// Content(10003) → TextGroup01-03 → Text(10061) → SeqText(3291121706)
static NSString * const kWP_CustomSpeedKey     = @"9999/10003/3336225139/3336225138/3336087544/10061/4/3291121706/201/209";

static NSString * const kWP_TemplateUID  = @"~/Titles.localized/SpliceKit/SpliceKit Caption/SpliceKit Caption.moti";
static NSString * const kWP_TemplateName = @"SpliceKit Caption";

// Content opacity fade-out: 5 frames before clip end
static const double kWP_FadeOutDuration = 5.0 / 30.0;

#pragma mark - NSColor RGBA Helpers

static NSString *SpliceKitCaption_colorToFCPXML(NSColor *color) {
    if (!color) return @"1 1 1 1";
    NSColor *rgb = [color colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
    if (!rgb) rgb = color;
    return [NSString stringWithFormat:@"%.3f %.3f %.3f %.3f",
            rgb.redComponent, rgb.greenComponent, rgb.blueComponent, rgb.alphaComponent];
}

static NSColor *SpliceKitCaption_colorFromString(NSString *str) {
    if (!str || str.length == 0) return [NSColor whiteColor];
    NSArray *parts = [str componentsSeparatedByString:@" "];
    if (parts.count < 3) return [NSColor whiteColor];
    CGFloat r = [parts[0] doubleValue];
    CGFloat g = [parts[1] doubleValue];
    CGFloat b = [parts[2] doubleValue];
    CGFloat a = parts.count >= 4 ? [parts[3] doubleValue] : 1.0;
    return [NSColor colorWithRed:r green:g blue:b alpha:a];
}

static NSString *SpliceKitCaption_escapeXML(NSString *str) {
    if (!str) return @"";
    NSMutableString *s = [str mutableCopy];
    [s replaceOccurrencesOfString:@"&" withString:@"&amp;" options:0 range:NSMakeRange(0, s.length)];
    [s replaceOccurrencesOfString:@"<" withString:@"&lt;" options:0 range:NSMakeRange(0, s.length)];
    [s replaceOccurrencesOfString:@">" withString:@"&gt;" options:0 range:NSMakeRange(0, s.length)];
    [s replaceOccurrencesOfString:@"\"" withString:@"&quot;" options:0 range:NSMakeRange(0, s.length)];
    [s replaceOccurrencesOfString:@"'" withString:@"&apos;" options:0 range:NSMakeRange(0, s.length)];
    return s;
}

#pragma mark - SpliceKitCaptionStyle

@implementation SpliceKitCaptionStyle

- (instancetype)init {
    self = [super init];
    if (self) {
        _name = @"Custom";
        _presetID = @"custom";
        _font = @"Helvetica Neue";
        _fontSize = 60;
        _fontFace = @"Bold";
        _textColor = [NSColor whiteColor];
        _highlightColor = [NSColor colorWithRed:1 green:0.85 blue:0 alpha:1];
        _outlineColor = [NSColor colorWithRed:0 green:0 blue:0 alpha:1];
        _outlineWidth = 2.0;
        _shadowColor = [NSColor colorWithRed:0 green:0 blue:0 alpha:0.8];
        _shadowBlurRadius = 4.0;
        _shadowOffsetX = 0;
        _shadowOffsetY = 0;
        _backgroundColor = nil;
        _backgroundPadding = 0;
        _position = SpliceKitCaptionPositionBottom;
        _customYOffset = 0;
        _animation = SpliceKitCaptionAnimationFade;
        _animationDuration = 0.2;
        _allCaps = YES;
        _wordByWordHighlight = YES;
    }
    return self;
}

- (id)copyWithZone:(NSZone *)zone {
    SpliceKitCaptionStyle *copy = [[SpliceKitCaptionStyle alloc] init];
    copy.name = self.name;
    copy.presetID = self.presetID;
    copy.font = self.font;
    copy.fontSize = self.fontSize;
    copy.fontFace = self.fontFace;
    copy.textColor = self.textColor;
    copy.highlightColor = self.highlightColor;
    copy.outlineColor = self.outlineColor;
    copy.outlineWidth = self.outlineWidth;
    copy.shadowColor = self.shadowColor;
    copy.shadowBlurRadius = self.shadowBlurRadius;
    copy.shadowOffsetX = self.shadowOffsetX;
    copy.shadowOffsetY = self.shadowOffsetY;
    copy.backgroundColor = self.backgroundColor;
    copy.backgroundPadding = self.backgroundPadding;
    copy.position = self.position;
    copy.customYOffset = self.customYOffset;
    copy.animation = self.animation;
    copy.animationDuration = self.animationDuration;
    copy.allCaps = self.allCaps;
    copy.wordByWordHighlight = self.wordByWordHighlight;
    return copy;
}

static NSString *SpliceKitCaption_positionName(SpliceKitCaptionPosition p) {
    switch (p) {
        case SpliceKitCaptionPositionBottom: return @"bottom";
        case SpliceKitCaptionPositionCenter: return @"center";
        case SpliceKitCaptionPositionTop: return @"top";
        case SpliceKitCaptionPositionCustom: return @"custom";
    }
    return @"bottom";
}

static SpliceKitCaptionPosition SpliceKitCaption_positionFromName(NSString *name) {
    if ([name isEqualToString:@"center"]) return SpliceKitCaptionPositionCenter;
    if ([name isEqualToString:@"top"]) return SpliceKitCaptionPositionTop;
    if ([name isEqualToString:@"custom"]) return SpliceKitCaptionPositionCustom;
    return SpliceKitCaptionPositionBottom;
}

static NSString *SpliceKitCaption_animationName(SpliceKitCaptionAnimation a) {
    switch (a) {
        case SpliceKitCaptionAnimationNone: return @"none";
        case SpliceKitCaptionAnimationFade: return @"fade";
        case SpliceKitCaptionAnimationPop: return @"pop";
        case SpliceKitCaptionAnimationSlideUp: return @"slide_up";
        case SpliceKitCaptionAnimationTypewriter: return @"typewriter";
        case SpliceKitCaptionAnimationBounce: return @"bounce";
    }
    return @"none";
}

static SpliceKitCaptionAnimation SpliceKitCaption_animationFromName(NSString *name) {
    if ([name isEqualToString:@"fade"]) return SpliceKitCaptionAnimationFade;
    if ([name isEqualToString:@"pop"]) return SpliceKitCaptionAnimationPop;
    if ([name isEqualToString:@"slide_up"]) return SpliceKitCaptionAnimationSlideUp;
    if ([name isEqualToString:@"typewriter"]) return SpliceKitCaptionAnimationTypewriter;
    if ([name isEqualToString:@"bounce"]) return SpliceKitCaptionAnimationBounce;
    return SpliceKitCaptionAnimationNone;
}

- (NSDictionary *)toDictionary {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"name"] = self.name ?: @"Custom";
    d[@"presetID"] = self.presetID ?: @"custom";
    d[@"font"] = self.font ?: @"Helvetica Neue";
    d[@"fontSize"] = @(self.fontSize);
    d[@"fontFace"] = self.fontFace ?: @"Bold";
    d[@"textColor"] = SpliceKitCaption_colorToFCPXML(self.textColor);
    d[@"highlightColor"] = self.highlightColor ? SpliceKitCaption_colorToFCPXML(self.highlightColor) : [NSNull null];
    d[@"outlineColor"] = SpliceKitCaption_colorToFCPXML(self.outlineColor);
    d[@"outlineWidth"] = @(self.outlineWidth);
    d[@"shadowColor"] = SpliceKitCaption_colorToFCPXML(self.shadowColor);
    d[@"shadowBlurRadius"] = @(self.shadowBlurRadius);
    d[@"shadowOffsetX"] = @(self.shadowOffsetX);
    d[@"shadowOffsetY"] = @(self.shadowOffsetY);
    d[@"backgroundColor"] = self.backgroundColor ? SpliceKitCaption_colorToFCPXML(self.backgroundColor) : [NSNull null];
    d[@"backgroundPadding"] = @(self.backgroundPadding);
    d[@"position"] = SpliceKitCaption_positionName(self.position);
    d[@"customYOffset"] = @(self.customYOffset);
    d[@"animation"] = SpliceKitCaption_animationName(self.animation);
    d[@"animationDuration"] = @(self.animationDuration);
    d[@"allCaps"] = @(self.allCaps);
    d[@"wordByWordHighlight"] = @(self.wordByWordHighlight);
    return d;
}

+ (instancetype)fromDictionary:(NSDictionary *)dict {
    SpliceKitCaptionStyle *s = [[SpliceKitCaptionStyle alloc] init];
    if (dict[@"name"]) s.name = dict[@"name"];
    if (dict[@"presetID"]) s.presetID = dict[@"presetID"];
    if (dict[@"font"]) s.font = dict[@"font"];
    if (dict[@"fontSize"]) s.fontSize = [dict[@"fontSize"] doubleValue];
    if (dict[@"fontFace"]) s.fontFace = dict[@"fontFace"];
    if (dict[@"textColor"]) s.textColor = SpliceKitCaption_colorFromString(dict[@"textColor"]);
    if (dict[@"highlightColor"] && dict[@"highlightColor"] != [NSNull null])
        s.highlightColor = SpliceKitCaption_colorFromString(dict[@"highlightColor"]);
    if (dict[@"outlineColor"]) s.outlineColor = SpliceKitCaption_colorFromString(dict[@"outlineColor"]);
    if (dict[@"outlineWidth"]) s.outlineWidth = [dict[@"outlineWidth"] doubleValue];
    if (dict[@"shadowColor"]) s.shadowColor = SpliceKitCaption_colorFromString(dict[@"shadowColor"]);
    if (dict[@"shadowBlurRadius"]) s.shadowBlurRadius = [dict[@"shadowBlurRadius"] doubleValue];
    if (dict[@"shadowOffsetX"]) s.shadowOffsetX = [dict[@"shadowOffsetX"] doubleValue];
    if (dict[@"shadowOffsetY"]) s.shadowOffsetY = [dict[@"shadowOffsetY"] doubleValue];
    if (dict[@"backgroundColor"] && dict[@"backgroundColor"] != [NSNull null])
        s.backgroundColor = SpliceKitCaption_colorFromString(dict[@"backgroundColor"]);
    if (dict[@"backgroundPadding"]) s.backgroundPadding = [dict[@"backgroundPadding"] doubleValue];
    if (dict[@"position"]) s.position = SpliceKitCaption_positionFromName(dict[@"position"]);
    if (dict[@"customYOffset"]) s.customYOffset = [dict[@"customYOffset"] doubleValue];
    if (dict[@"animation"]) s.animation = SpliceKitCaption_animationFromName(dict[@"animation"]);
    if (dict[@"animationDuration"]) s.animationDuration = [dict[@"animationDuration"] doubleValue];
    if (dict[@"allCaps"]) s.allCaps = [dict[@"allCaps"] boolValue];
    if (dict[@"wordByWordHighlight"]) s.wordByWordHighlight = [dict[@"wordByWordHighlight"] boolValue];
    return s;
}

+ (NSArray<SpliceKitCaptionStyle *> *)builtInPresets {
    static NSArray *presets = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableArray *list = [NSMutableArray array];

        // 1. Bold Pop — high energy YouTube/TikTok style
        {
            SpliceKitCaptionStyle *s = [[SpliceKitCaptionStyle alloc] init];
            s.presetID = @"bold_pop"; s.name = @"Bold Pop";
            s.font = @"Futura-Bold"; s.fontSize = 72; s.fontFace = @"Bold";
            s.textColor = [NSColor whiteColor];
            s.highlightColor = [NSColor colorWithRed:1 green:0.85 blue:0 alpha:1];
            s.outlineColor = [NSColor colorWithRed:0 green:0 blue:0 alpha:1]; s.outlineWidth = 3.0;
            s.shadowColor = [NSColor colorWithRed:0 green:0 blue:0 alpha:0.8]; s.shadowBlurRadius = 4;
            s.position = SpliceKitCaptionPositionBottom;
            s.animation = SpliceKitCaptionAnimationPop; s.animationDuration = 0.2;
            s.allCaps = YES; s.wordByWordHighlight = YES;
            [list addObject:s];
        }

        // 2. Neon Glow
        {
            SpliceKitCaptionStyle *s = [[SpliceKitCaptionStyle alloc] init];
            s.presetID = @"neon_glow"; s.name = @"Neon Glow";
            s.font = @"Avenir-Heavy"; s.fontSize = 68; s.fontFace = @"Heavy";
            s.textColor = [NSColor colorWithRed:0 green:1 blue:1 alpha:1];
            s.highlightColor = [NSColor colorWithRed:1 green:0 blue:1 alpha:1];
            s.outlineColor = nil; s.outlineWidth = 0;
            s.shadowColor = [NSColor colorWithRed:0 green:0.8 blue:1 alpha:0.9]; s.shadowBlurRadius = 15;
            s.position = SpliceKitCaptionPositionBottom;
            s.animation = SpliceKitCaptionAnimationFade; s.animationDuration = 0.25;
            s.allCaps = NO; s.wordByWordHighlight = YES;
            [list addObject:s];
        }

        // 3. Clean Minimal
        {
            SpliceKitCaptionStyle *s = [[SpliceKitCaptionStyle alloc] init];
            s.presetID = @"clean_minimal"; s.name = @"Clean Minimal";
            s.font = @"HelveticaNeue-Bold"; s.fontSize = 60; s.fontFace = @"Bold";
            s.textColor = [NSColor whiteColor];
            s.highlightColor = [NSColor colorWithRed:0.4 green:0.7 blue:1 alpha:1];
            s.outlineColor = nil; s.outlineWidth = 0;
            s.shadowColor = [NSColor colorWithRed:0 green:0 blue:0 alpha:0.5]; s.shadowBlurRadius = 3;
            s.position = SpliceKitCaptionPositionBottom;
            s.animation = SpliceKitCaptionAnimationFade; s.animationDuration = 0.2;
            s.allCaps = NO; s.wordByWordHighlight = YES;
            [list addObject:s];
        }

        // 4. Handwritten
        {
            SpliceKitCaptionStyle *s = [[SpliceKitCaptionStyle alloc] init];
            s.presetID = @"handwritten"; s.name = @"Handwritten";
            s.font = @"Bradley Hand"; s.fontSize = 64; s.fontFace = @"Bold";
            s.textColor = [NSColor colorWithRed:0.95 green:0.95 blue:0.9 alpha:1];
            s.highlightColor = [NSColor colorWithRed:1 green:0.6 blue:0.2 alpha:1];
            s.outlineColor = nil; s.outlineWidth = 0;
            s.shadowColor = [NSColor colorWithRed:0.3 green:0.2 blue:0.1 alpha:0.6]; s.shadowBlurRadius = 4;
            s.position = SpliceKitCaptionPositionBottom;
            s.animation = SpliceKitCaptionAnimationNone; s.animationDuration = 0;
            s.allCaps = NO; s.wordByWordHighlight = YES;
            [list addObject:s];
        }

        // 5. Gradient Fire
        {
            SpliceKitCaptionStyle *s = [[SpliceKitCaptionStyle alloc] init];
            s.presetID = @"gradient_fire"; s.name = @"Gradient Fire";
            s.font = @"HelveticaNeue-Bold"; s.fontSize = 70; s.fontFace = @"Bold";
            s.textColor = [NSColor colorWithRed:1 green:0.6 blue:0.1 alpha:1];
            s.highlightColor = [NSColor colorWithRed:1 green:0.2 blue:0.1 alpha:1];
            s.outlineColor = [NSColor colorWithRed:0 green:0 blue:0 alpha:1]; s.outlineWidth = 2;
            s.shadowColor = [NSColor colorWithRed:0.5 green:0.1 blue:0 alpha:0.8]; s.shadowBlurRadius = 6;
            s.position = SpliceKitCaptionPositionBottom;
            s.animation = SpliceKitCaptionAnimationPop; s.animationDuration = 0.2;
            s.allCaps = YES; s.wordByWordHighlight = YES;
            [list addObject:s];
        }

        // 6. Outline Bold — classic meme style
        {
            SpliceKitCaptionStyle *s = [[SpliceKitCaptionStyle alloc] init];
            s.presetID = @"outline_bold"; s.name = @"Outline Bold";
            s.font = @"Impact"; s.fontSize = 76; s.fontFace = @"Regular";
            s.textColor = [NSColor whiteColor];
            s.highlightColor = [NSColor colorWithRed:1 green:1 blue:0 alpha:1];
            s.outlineColor = [NSColor blackColor]; s.outlineWidth = 4;
            s.shadowColor = nil; s.shadowBlurRadius = 0;
            s.position = SpliceKitCaptionPositionBottom;
            s.animation = SpliceKitCaptionAnimationNone; s.animationDuration = 0;
            s.allCaps = YES; s.wordByWordHighlight = YES;
            [list addObject:s];
        }

        // 7. Shadow Deep
        {
            SpliceKitCaptionStyle *s = [[SpliceKitCaptionStyle alloc] init];
            s.presetID = @"shadow_deep"; s.name = @"Shadow Deep";
            s.font = @"Futura-Bold"; s.fontSize = 68; s.fontFace = @"Bold";
            s.textColor = [NSColor whiteColor];
            s.highlightColor = [NSColor colorWithRed:0.2 green:1 blue:0.4 alpha:1];
            s.outlineColor = nil; s.outlineWidth = 0;
            s.shadowColor = [NSColor colorWithRed:0 green:0 blue:0 alpha:1]; s.shadowBlurRadius = 8;
            s.shadowOffsetX = 4; s.shadowOffsetY = 4;
            s.position = SpliceKitCaptionPositionBottom;
            s.animation = SpliceKitCaptionAnimationFade; s.animationDuration = 0.25;
            s.allCaps = NO; s.wordByWordHighlight = YES;
            [list addObject:s];
        }

        // 8. Karaoke — gray base, white highlight
        {
            SpliceKitCaptionStyle *s = [[SpliceKitCaptionStyle alloc] init];
            s.presetID = @"karaoke"; s.name = @"Karaoke";
            s.font = @"GillSans-Bold"; s.fontSize = 66; s.fontFace = @"Bold";
            s.textColor = [NSColor colorWithRed:0.5 green:0.5 blue:0.5 alpha:1];
            s.highlightColor = [NSColor whiteColor];
            s.outlineColor = [NSColor colorWithRed:0 green:0 blue:0 alpha:1]; s.outlineWidth = 2;
            s.shadowColor = [NSColor colorWithRed:0 green:0 blue:0 alpha:0.6]; s.shadowBlurRadius = 4;
            s.position = SpliceKitCaptionPositionCenter;
            s.animation = SpliceKitCaptionAnimationNone; s.animationDuration = 0;
            s.allCaps = NO; s.wordByWordHighlight = YES;
            [list addObject:s];
        }

        // 9. Typewriter — terminal/code aesthetic
        {
            SpliceKitCaptionStyle *s = [[SpliceKitCaptionStyle alloc] init];
            s.presetID = @"typewriter"; s.name = @"Typewriter";
            s.font = @"Courier-Bold"; s.fontSize = 54; s.fontFace = @"Bold";
            s.textColor = [NSColor colorWithRed:0.2 green:1 blue:0.2 alpha:1];
            s.highlightColor = [NSColor whiteColor];
            s.outlineColor = nil; s.outlineWidth = 0;
            s.shadowColor = nil; s.shadowBlurRadius = 0;
            s.backgroundColor = [NSColor colorWithRed:0 green:0 blue:0 alpha:0.7];
            s.backgroundPadding = 6;
            s.position = SpliceKitCaptionPositionBottom;
            s.animation = SpliceKitCaptionAnimationTypewriter; s.animationDuration = 0;
            s.allCaps = NO; s.wordByWordHighlight = YES;
            [list addObject:s];
        }

        // 10. Bounce Fun
        {
            SpliceKitCaptionStyle *s = [[SpliceKitCaptionStyle alloc] init];
            s.presetID = @"bounce_fun"; s.name = @"Bounce Fun";
            s.font = @"AvenirNext-Heavy"; s.fontSize = 72; s.fontFace = @"Heavy";
            s.textColor = [NSColor whiteColor];
            s.highlightColor = [NSColor colorWithRed:1 green:0.4 blue:0.7 alpha:1];
            s.outlineColor = [NSColor colorWithRed:0 green:0 blue:0 alpha:1]; s.outlineWidth = 2;
            s.shadowColor = nil; s.shadowBlurRadius = 0;
            s.position = SpliceKitCaptionPositionBottom;
            s.animation = SpliceKitCaptionAnimationBounce; s.animationDuration = 0.3;
            s.allCaps = YES; s.wordByWordHighlight = YES;
            [list addObject:s];
        }

        // 11. Subtitle Pro — traditional, no word highlight
        {
            SpliceKitCaptionStyle *s = [[SpliceKitCaptionStyle alloc] init];
            s.presetID = @"subtitle_pro"; s.name = @"Subtitle Pro";
            s.font = @"HelveticaNeue-Medium"; s.fontSize = 48; s.fontFace = @"Medium";
            s.textColor = [NSColor whiteColor];
            s.highlightColor = nil;
            s.outlineColor = [NSColor colorWithRed:0 green:0 blue:0 alpha:1]; s.outlineWidth = 1.5;
            s.shadowColor = [NSColor colorWithRed:0 green:0 blue:0 alpha:0.6]; s.shadowBlurRadius = 2;
            s.position = SpliceKitCaptionPositionBottom;
            s.animation = SpliceKitCaptionAnimationFade; s.animationDuration = 0.15;
            s.allCaps = NO; s.wordByWordHighlight = NO;
            [list addObject:s];
        }

        // 12. Social Bold — TikTok/Reels centered
        {
            SpliceKitCaptionStyle *s = [[SpliceKitCaptionStyle alloc] init];
            s.presetID = @"social_bold"; s.name = @"Social Bold";
            s.font = @"HelveticaNeue-Bold"; s.fontSize = 80; s.fontFace = @"Bold";
            s.textColor = [NSColor whiteColor];
            s.highlightColor = [NSColor colorWithRed:1 green:0.9 blue:0 alpha:1];
            s.outlineColor = [NSColor colorWithRed:0 green:0 blue:0 alpha:1]; s.outlineWidth = 3;
            s.shadowColor = [NSColor colorWithRed:0 green:0 blue:0 alpha:0.9]; s.shadowBlurRadius = 5;
            s.position = SpliceKitCaptionPositionCenter;
            s.animation = SpliceKitCaptionAnimationPop; s.animationDuration = 0.2;
            s.allCaps = YES; s.wordByWordHighlight = YES;
            [list addObject:s];
        }

        // 13. Social Reels — optimized for 9:16 vertical short-form
        {
            SpliceKitCaptionStyle *s = [[SpliceKitCaptionStyle alloc] init];
            s.presetID = @"social_reels"; s.name = @"Social Reels";
            s.font = @"HelveticaNeue-Bold"; s.fontSize = 100; s.fontFace = @"Bold";
            s.textColor = [NSColor whiteColor];
            s.highlightColor = [NSColor colorWithRed:1 green:0.9 blue:0 alpha:1];
            s.outlineColor = [NSColor colorWithRed:0 green:0 blue:0 alpha:1]; s.outlineWidth = 4.0;
            s.shadowColor = [NSColor colorWithRed:0 green:0 blue:0 alpha:0.9]; s.shadowBlurRadius = 6;
            s.backgroundColor = [NSColor colorWithRed:0 green:0 blue:0 alpha:0.6];
            s.backgroundPadding = 8;
            s.position = SpliceKitCaptionPositionCenter;
            s.animation = SpliceKitCaptionAnimationPop; s.animationDuration = 0.15;
            s.allCaps = YES; s.wordByWordHighlight = YES;
            [list addObject:s];
        }

        presets = [list copy];
    });
    return presets;
}

+ (instancetype)presetWithID:(NSString *)presetID {
    for (SpliceKitCaptionStyle *s in [self builtInPresets]) {
        if ([s.presetID isEqualToString:presetID]) return [s copy];
    }
    return nil;
}

@end

#pragma mark - SpliceKitCaptionSegment

@implementation SpliceKitCaptionSegment

- (NSDictionary *)toDictionary {
    NSMutableArray *wordDicts = [NSMutableArray array];
    for (SpliceKitTranscriptWord *w in self.words) {
        [wordDicts addObject:@{
            @"text": w.text ?: @"",
            @"startTime": @(w.startTime),
            @"endTime": @(w.endTime),
            @"duration": @(w.duration),
        }];
    }
    return @{
        @"index": @(self.segmentIndex),
        @"text": self.text ?: @"",
        @"startTime": @(self.startTime),
        @"endTime": @(self.endTime),
        @"duration": @(self.duration),
        @"wordCount": @(self.words.count),
        @"words": wordDicts,
    };
}

@end

#pragma mark - SpliceKitCaptionPanel

@interface SpliceKitCaptionPanel () <NSWindowDelegate>
@property (nonatomic, strong) NSPanel *panel;
@property (nonatomic, strong) SpliceKitCaptionStyle *style;
@property (nonatomic, strong) NSMutableArray<SpliceKitTranscriptWord *> *mutableWords;
@property (nonatomic, strong) NSMutableArray<SpliceKitCaptionSegment *> *mutableSegments;
@property (nonatomic) SpliceKitCaptionStatus status;
@property (nonatomic, copy) NSString *errorMessage;
@property (nonatomic, strong) NSDictionary *lastGenerateResult;

// UI
@property (nonatomic, strong) NSPopUpButton *presetPopup;
@property (nonatomic, strong) NSPopUpButton *fontPopup;
@property (nonatomic, strong) NSTextField *fontSizeField;
@property (nonatomic, strong) NSSlider *fontSizeSlider;
@property (nonatomic, strong) NSColorWell *textColorWell;
@property (nonatomic, strong) NSColorWell *highlightColorWell;
@property (nonatomic, strong) NSColorWell *outlineColorWell;
@property (nonatomic, strong) NSSlider *outlineWidthSlider;
@property (nonatomic, strong) NSColorWell *shadowColorWell;
@property (nonatomic, strong) NSSlider *shadowBlurSlider;
@property (nonatomic, strong) NSPopUpButton *positionPopup;
@property (nonatomic, strong) NSPopUpButton *animationPopup;
@property (nonatomic, strong) NSButton *allCapsCheckbox;
@property (nonatomic, strong) NSButton *wordHighlightCheckbox;
@property (nonatomic, strong) NSPopUpButton *groupingPopup;
@property (nonatomic, strong) NSTextField *groupingValueField;
@property (nonatomic, strong) NSView *previewView;
@property (nonatomic, strong) NSTextField *previewLabel;
@property (nonatomic, strong) NSButton *transcribeButton;
@property (nonatomic, strong) NSButton *generateButton;
@property (nonatomic, strong) NSButton *exportSRTButton;
@property (nonatomic, strong) NSButton *exportTXTButton;
@property (nonatomic, strong) NSProgressIndicator *spinner;

// Frame rate info (detected from timeline)
@property (nonatomic) int fdNum;   // frame duration numerator
@property (nonatomic) int fdDen;   // frame duration denominator
@property (nonatomic) double frameRate;
@property (nonatomic) int videoWidth;
@property (nonatomic) int videoHeight;
@end

// Swizzle LKTileView's draggingEntered: to log what FCP receives during drags
static IMP sOrigLKTileViewDraggingEntered = NULL;
static NSDragOperation SpliceKit_swizzled_LKTileView_draggingEntered(id self, SEL _cmd, id draggingInfo) {
    // Log the dragging info
    NSPasteboard *pb = [draggingInfo draggingPasteboard];
    NSArray *types = [pb types];
    id source = [draggingInfo draggingSource];
    NSWindow *srcWin = [draggingInfo draggingDestinationWindow];
    NSDragOperation srcMask = [draggingInfo draggingSourceOperationMask];
    SpliceKit_log(@"[DragSpy] LKTileView draggingEntered:");
    SpliceKit_log(@"[DragSpy]   pasteboard types: %@", types);
    SpliceKit_log(@"[DragSpy]   source: %@ (class: %@)", source, [source class]);
    SpliceKit_log(@"[DragSpy]   destWindow: %@", srcWin);
    SpliceKit_log(@"[DragSpy]   sourceMask: %lu", (unsigned long)srcMask);
    SpliceKit_log(@"[DragSpy]   draggingLocation: %@", NSStringFromPoint([draggingInfo draggingLocation]));

    NSDragOperation result = ((NSDragOperation (*)(id, SEL, id))sOrigLKTileViewDraggingEntered)(self, _cmd, draggingInfo);
    SpliceKit_log(@"[DragSpy]   → result: %lu (0=None,1=Copy)", (unsigned long)result);
    return result;
}

static IMP sOrigTLKTimelineViewDraggingEntered = NULL;
static NSDragOperation SpliceKit_swizzled_TLKTimelineView_draggingEntered(id self, SEL _cmd, id draggingInfo) {
    NSPasteboard *pb = [draggingInfo draggingPasteboard];
    NSArray *types = [pb types];
    id source = [draggingInfo draggingSource];
    NSDragOperation srcMask = [draggingInfo draggingSourceOperationMask];
    SpliceKit_log(@"[DragSpy] TLKTimelineView draggingEntered:");
    SpliceKit_log(@"[DragSpy]   pasteboard types: %@", types);
    SpliceKit_log(@"[DragSpy]   source: %@ (class: %@)", source,
                  source ? NSStringFromClass([source class]) : @"nil");
    SpliceKit_log(@"[DragSpy]   sourceMask: %lu", (unsigned long)srcMask);

    NSDragOperation result = ((NSDragOperation (*)(id, SEL, id))sOrigTLKTimelineViewDraggingEntered)(self, _cmd, draggingInfo);
    SpliceKit_log(@"[DragSpy]   → returned: %lu (0=None,1=Copy)", (unsigned long)result);
    return result;
}

__attribute__((constructor))
static void SpliceKit_installDragSpy(void) {
    // Swizzle TLKTimelineView (the actual timeline drop target)
    Class cls = objc_getClass("TLKTimelineView");
    if (cls) {
        Method m = class_getInstanceMethod(cls, @selector(draggingEntered:));
        if (m) {
            sOrigTLKTimelineViewDraggingEntered = method_getImplementation(m);
            method_setImplementation(m, (IMP)SpliceKit_swizzled_TLKTimelineView_draggingEntered);
            SpliceKit_log(@"[DragSpy] Installed TLKTimelineView draggingEntered: swizzle");
        }
    }
    // Also swizzle LKTileView
    cls = objc_getClass("LKTileView");
    if (cls) {
        Method m = class_getInstanceMethod(cls, @selector(draggingEntered:));
        if (m) {
            sOrigLKTileViewDraggingEntered = method_getImplementation(m);
            method_setImplementation(m, (IMP)SpliceKit_swizzled_LKTileView_draggingEntered);
            SpliceKit_log(@"[DragSpy] Installed LKTileView draggingEntered: swizzle");
        }
    }
}

@implementation SpliceKitCaptionPanel

+ (instancetype)sharedPanel {
    static SpliceKitCaptionPanel *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[SpliceKitCaptionPanel alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _style = [[SpliceKitCaptionStyle builtInPresets] firstObject];
        _mutableWords = [NSMutableArray array];
        _mutableSegments = [NSMutableArray array];
        _status = SpliceKitCaptionStatusIdle;
        _groupingMode = SpliceKitCaptionGroupingByWordCount;
        _maxWordsPerSegment = 3;
        _maxCharsPerSegment = 20;
        _maxSecondsPerSegment = 3.0;
        _fdNum = 100; _fdDen = 2400; // default 24fps
        _frameRate = 24.0;
        _videoWidth = 1920; _videoHeight = 1080;
    }
    return self;
}

#pragma mark - Panel Lifecycle

- (void)setupPanelIfNeeded {
    if (self.panel) return;

    NSRect frame = NSMakeRect(100, 150, 480, 680);
    NSUInteger mask = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                      NSWindowStyleMaskResizable | NSWindowStyleMaskUtilityWindow;

    self.panel = [[NSPanel alloc] initWithContentRect:frame
                                            styleMask:mask
                                              backing:NSBackingStoreBuffered
                                                defer:NO];
    self.panel.title = @"Social Captions";
    self.panel.floatingPanel = YES;
    self.panel.becomesKeyOnlyIfNeeded = NO;
    self.panel.hidesOnDeactivate = NO;
    self.panel.level = NSFloatingWindowLevel;
    self.panel.minSize = NSMakeSize(400, 500);
    self.panel.delegate = self;
    self.panel.releasedWhenClosed = NO;
    self.panel.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];

    NSView *content = self.panel.contentView;
    content.wantsLayer = YES;

    [self buildUI:content];
}

- (void)buildUI:(NSView *)content {
    // Main stack view for vertical layout
    NSScrollView *scrollView = [[NSScrollView alloc] init];
    scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    scrollView.hasVerticalScroller = YES;
    scrollView.hasHorizontalScroller = NO;
    scrollView.borderType = NSNoBorder;
    scrollView.drawsBackground = NO;
    [content addSubview:scrollView];

    NSView *docView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 460, 900)];
    docView.translatesAutoresizingMaskIntoConstraints = NO;
    scrollView.documentView = docView;

    // Status bar at bottom (fixed, not scrollable)
    NSView *statusBar = [[NSView alloc] init];
    statusBar.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:statusBar];

    self.statusLabel = [NSTextField labelWithString:@"Ready — choose a style and transcribe"];
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusLabel.font = [NSFont systemFontOfSize:11];
    self.statusLabel.textColor = [NSColor secondaryLabelColor];
    self.statusLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [statusBar addSubview:self.statusLabel];

    self.spinner = [[NSProgressIndicator alloc] initWithFrame:NSZeroRect];
    self.spinner.style = NSProgressIndicatorStyleSpinning;
    self.spinner.translatesAutoresizingMaskIntoConstraints = NO;
    self.spinner.controlSize = NSControlSizeSmall;
    self.spinner.hidden = YES;
    [statusBar addSubview:self.spinner];

    [NSLayoutConstraint activateConstraints:@[
        [scrollView.topAnchor constraintEqualToAnchor:content.topAnchor],
        [scrollView.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [scrollView.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [scrollView.bottomAnchor constraintEqualToAnchor:statusBar.topAnchor],

        [statusBar.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [statusBar.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [statusBar.bottomAnchor constraintEqualToAnchor:content.bottomAnchor],
        [statusBar.heightAnchor constraintEqualToConstant:28],

        [self.spinner.leadingAnchor constraintEqualToAnchor:statusBar.leadingAnchor constant:8],
        [self.spinner.centerYAnchor constraintEqualToAnchor:statusBar.centerYAnchor],
        [self.statusLabel.leadingAnchor constraintEqualToAnchor:self.spinner.trailingAnchor constant:6],
        [self.statusLabel.trailingAnchor constraintEqualToAnchor:statusBar.trailingAnchor constant:-8],
        [self.statusLabel.centerYAnchor constraintEqualToAnchor:statusBar.centerYAnchor],

        [docView.leadingAnchor constraintEqualToAnchor:scrollView.contentView.leadingAnchor],
        [docView.trailingAnchor constraintEqualToAnchor:scrollView.contentView.trailingAnchor],
        [docView.topAnchor constraintEqualToAnchor:scrollView.contentView.topAnchor],
        [docView.widthAnchor constraintEqualToAnchor:scrollView.contentView.widthAnchor],
    ]];

    CGFloat pad = 14;
    CGFloat rowH = 26;
    NSView *prev = nil; // track the last added view for vertical chaining

    // === STYLE PRESET ===
    NSTextField *presetLabel = [self makeLabel:@"Style"];
    [docView addSubview:presetLabel];

    self.presetPopup = [[NSPopUpButton alloc] init];
    self.presetPopup.translatesAutoresizingMaskIntoConstraints = NO;
    self.presetPopup.controlSize = NSControlSizeRegular;
    for (SpliceKitCaptionStyle *s in [SpliceKitCaptionStyle builtInPresets]) {
        [self.presetPopup addItemWithTitle:s.name];
    }
    self.presetPopup.target = self;
    self.presetPopup.action = @selector(presetChanged:);
    [docView addSubview:self.presetPopup];

    [NSLayoutConstraint activateConstraints:@[
        [presetLabel.topAnchor constraintEqualToAnchor:docView.topAnchor constant:pad],
        [presetLabel.leadingAnchor constraintEqualToAnchor:docView.leadingAnchor constant:pad],
        [presetLabel.widthAnchor constraintEqualToConstant:80],
        [self.presetPopup.centerYAnchor constraintEqualToAnchor:presetLabel.centerYAnchor],
        [self.presetPopup.leadingAnchor constraintEqualToAnchor:presetLabel.trailingAnchor constant:4],
        [self.presetPopup.trailingAnchor constraintEqualToAnchor:docView.trailingAnchor constant:-pad],
    ]];
    prev = presetLabel;

    // === PREVIEW ===
    self.previewView = [[NSView alloc] init];
    self.previewView.translatesAutoresizingMaskIntoConstraints = NO;
    self.previewView.wantsLayer = YES;
    self.previewView.layer.backgroundColor = [[NSColor colorWithCalibratedWhite:0.1 alpha:1] CGColor];
    self.previewView.layer.cornerRadius = 8;
    [docView addSubview:self.previewView];

    self.previewLabel = [[NSTextField alloc] init];
    self.previewLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.previewLabel.editable = NO;
    self.previewLabel.selectable = NO;
    self.previewLabel.bordered = NO;
    self.previewLabel.drawsBackground = NO;
    self.previewLabel.alignment = NSTextAlignmentCenter;
    self.previewLabel.lineBreakMode = NSLineBreakByWordWrapping;
    self.previewLabel.maximumNumberOfLines = 3;
    [self.previewView addSubview:self.previewLabel];

    [NSLayoutConstraint activateConstraints:@[
        [self.previewView.topAnchor constraintEqualToAnchor:prev.bottomAnchor constant:10],
        [self.previewView.leadingAnchor constraintEqualToAnchor:docView.leadingAnchor constant:pad],
        [self.previewView.trailingAnchor constraintEqualToAnchor:docView.trailingAnchor constant:-pad],
        [self.previewView.heightAnchor constraintEqualToConstant:140],

        [self.previewLabel.leadingAnchor constraintEqualToAnchor:self.previewView.leadingAnchor constant:12],
        [self.previewLabel.trailingAnchor constraintEqualToAnchor:self.previewView.trailingAnchor constant:-12],
        [self.previewLabel.centerYAnchor constraintEqualToAnchor:self.previewView.centerYAnchor],
    ]];
    prev = self.previewView;

    // === FONT ===
    NSTextField *fontLabel = [self makeLabel:@"Font"];
    [docView addSubview:fontLabel];

    self.fontPopup = [[NSPopUpButton alloc] init];
    self.fontPopup.translatesAutoresizingMaskIntoConstraints = NO;
    self.fontPopup.controlSize = NSControlSizeSmall;
    NSArray *families = [[[NSFontManager sharedFontManager] availableFontFamilies]
                         sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    for (NSString *fam in families) { [self.fontPopup addItemWithTitle:fam]; }
    self.fontPopup.target = self; self.fontPopup.action = @selector(fontChanged:);
    [docView addSubview:self.fontPopup];

    [self layoutRow:fontLabel control:self.fontPopup in:docView below:prev pad:pad rowH:rowH];
    prev = fontLabel;

    // === FONT SIZE ===
    NSTextField *sizeLabel = [self makeLabel:@"Size"];
    [docView addSubview:sizeLabel];

    self.fontSizeSlider = [[NSSlider alloc] init];
    self.fontSizeSlider.translatesAutoresizingMaskIntoConstraints = NO;
    self.fontSizeSlider.minValue = 20; self.fontSizeSlider.maxValue = 120;
    self.fontSizeSlider.target = self; self.fontSizeSlider.action = @selector(fontSizeChanged:);
    self.fontSizeSlider.controlSize = NSControlSizeSmall;
    [docView addSubview:self.fontSizeSlider];

    self.fontSizeField = [[NSTextField alloc] init];
    self.fontSizeField.translatesAutoresizingMaskIntoConstraints = NO;
    self.fontSizeField.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular];
    self.fontSizeField.alignment = NSTextAlignmentCenter;
    self.fontSizeField.editable = NO; self.fontSizeField.bordered = YES;
    self.fontSizeField.controlSize = NSControlSizeSmall;
    [docView addSubview:self.fontSizeField];

    [NSLayoutConstraint activateConstraints:@[
        [sizeLabel.topAnchor constraintEqualToAnchor:prev.bottomAnchor constant:8],
        [sizeLabel.leadingAnchor constraintEqualToAnchor:docView.leadingAnchor constant:pad],
        [sizeLabel.widthAnchor constraintEqualToConstant:80],
        [self.fontSizeSlider.centerYAnchor constraintEqualToAnchor:sizeLabel.centerYAnchor],
        [self.fontSizeSlider.leadingAnchor constraintEqualToAnchor:sizeLabel.trailingAnchor constant:4],
        [self.fontSizeSlider.trailingAnchor constraintEqualToAnchor:self.fontSizeField.leadingAnchor constant:-6],
        [self.fontSizeField.centerYAnchor constraintEqualToAnchor:sizeLabel.centerYAnchor],
        [self.fontSizeField.trailingAnchor constraintEqualToAnchor:docView.trailingAnchor constant:-pad],
        [self.fontSizeField.widthAnchor constraintEqualToConstant:44],
    ]];
    prev = sizeLabel;

    // === COLORS (text, highlight, outline, shadow) ===
    NSTextField *colorsLabel = [self makeLabel:@"Colors"];
    [docView addSubview:colorsLabel];

    self.textColorWell = [self makeColorWell]; [docView addSubview:self.textColorWell];
    NSTextField *tcLabel = [self makeTinyLabel:@"Text"]; [docView addSubview:tcLabel];

    self.highlightColorWell = [self makeColorWell]; [docView addSubview:self.highlightColorWell];
    NSTextField *hcLabel = [self makeTinyLabel:@"Highlight"]; [docView addSubview:hcLabel];

    self.outlineColorWell = [self makeColorWell]; [docView addSubview:self.outlineColorWell];
    NSTextField *ocLabel = [self makeTinyLabel:@"Outline"]; [docView addSubview:ocLabel];

    self.shadowColorWell = [self makeColorWell]; [docView addSubview:self.shadowColorWell];
    NSTextField *scLabel = [self makeTinyLabel:@"Shadow"]; [docView addSubview:scLabel];

    self.textColorWell.target = self; self.textColorWell.action = @selector(colorChanged:);
    self.highlightColorWell.target = self; self.highlightColorWell.action = @selector(colorChanged:);
    self.outlineColorWell.target = self; self.outlineColorWell.action = @selector(colorChanged:);
    self.shadowColorWell.target = self; self.shadowColorWell.action = @selector(colorChanged:);

    [NSLayoutConstraint activateConstraints:@[
        [colorsLabel.topAnchor constraintEqualToAnchor:prev.bottomAnchor constant:10],
        [colorsLabel.leadingAnchor constraintEqualToAnchor:docView.leadingAnchor constant:pad],
        [colorsLabel.widthAnchor constraintEqualToConstant:80],

        [self.textColorWell.centerYAnchor constraintEqualToAnchor:colorsLabel.centerYAnchor],
        [self.textColorWell.leadingAnchor constraintEqualToAnchor:colorsLabel.trailingAnchor constant:4],
        [tcLabel.centerYAnchor constraintEqualToAnchor:colorsLabel.centerYAnchor],
        [tcLabel.leadingAnchor constraintEqualToAnchor:self.textColorWell.trailingAnchor constant:2],

        [self.highlightColorWell.centerYAnchor constraintEqualToAnchor:colorsLabel.centerYAnchor],
        [self.highlightColorWell.leadingAnchor constraintEqualToAnchor:tcLabel.trailingAnchor constant:8],
        [hcLabel.centerYAnchor constraintEqualToAnchor:colorsLabel.centerYAnchor],
        [hcLabel.leadingAnchor constraintEqualToAnchor:self.highlightColorWell.trailingAnchor constant:2],

        [self.outlineColorWell.centerYAnchor constraintEqualToAnchor:colorsLabel.centerYAnchor],
        [self.outlineColorWell.leadingAnchor constraintEqualToAnchor:hcLabel.trailingAnchor constant:8],
        [ocLabel.centerYAnchor constraintEqualToAnchor:colorsLabel.centerYAnchor],
        [ocLabel.leadingAnchor constraintEqualToAnchor:self.outlineColorWell.trailingAnchor constant:2],

        [self.shadowColorWell.centerYAnchor constraintEqualToAnchor:colorsLabel.centerYAnchor],
        [self.shadowColorWell.leadingAnchor constraintEqualToAnchor:ocLabel.trailingAnchor constant:8],
        [scLabel.centerYAnchor constraintEqualToAnchor:colorsLabel.centerYAnchor],
        [scLabel.leadingAnchor constraintEqualToAnchor:self.shadowColorWell.trailingAnchor constant:2],
    ]];
    prev = colorsLabel;

    // === OUTLINE WIDTH ===
    NSTextField *owLabel = [self makeLabel:@"Outline W."];
    [docView addSubview:owLabel];
    self.outlineWidthSlider = [[NSSlider alloc] init];
    self.outlineWidthSlider.translatesAutoresizingMaskIntoConstraints = NO;
    self.outlineWidthSlider.minValue = 0; self.outlineWidthSlider.maxValue = 6;
    self.outlineWidthSlider.controlSize = NSControlSizeSmall;
    self.outlineWidthSlider.target = self; self.outlineWidthSlider.action = @selector(outlineWidthChanged:);
    [docView addSubview:self.outlineWidthSlider];
    [self layoutRow:owLabel control:self.outlineWidthSlider in:docView below:prev pad:pad rowH:rowH];
    prev = owLabel;

    // === SHADOW BLUR ===
    NSTextField *sbLabel = [self makeLabel:@"Shadow Blur"];
    [docView addSubview:sbLabel];
    self.shadowBlurSlider = [[NSSlider alloc] init];
    self.shadowBlurSlider.translatesAutoresizingMaskIntoConstraints = NO;
    self.shadowBlurSlider.minValue = 0; self.shadowBlurSlider.maxValue = 20;
    self.shadowBlurSlider.controlSize = NSControlSizeSmall;
    self.shadowBlurSlider.target = self; self.shadowBlurSlider.action = @selector(shadowBlurChanged:);
    [docView addSubview:self.shadowBlurSlider];
    [self layoutRow:sbLabel control:self.shadowBlurSlider in:docView below:prev pad:pad rowH:rowH];
    prev = sbLabel;

    // === POSITION ===
    NSTextField *posLabel = [self makeLabel:@"Position"];
    [docView addSubview:posLabel];
    self.positionPopup = [[NSPopUpButton alloc] init];
    self.positionPopup.translatesAutoresizingMaskIntoConstraints = NO;
    self.positionPopup.controlSize = NSControlSizeSmall;
    [self.positionPopup addItemsWithTitles:@[@"Bottom", @"Center", @"Top"]];
    self.positionPopup.target = self; self.positionPopup.action = @selector(positionChanged:);
    [docView addSubview:self.positionPopup];
    [self layoutRow:posLabel control:self.positionPopup in:docView below:prev pad:pad rowH:rowH];
    prev = posLabel;

    // === ANIMATION ===
    NSTextField *animLabel = [self makeLabel:@"Animation"];
    [docView addSubview:animLabel];
    self.animationPopup = [[NSPopUpButton alloc] init];
    self.animationPopup.translatesAutoresizingMaskIntoConstraints = NO;
    self.animationPopup.controlSize = NSControlSizeSmall;
    [self.animationPopup addItemsWithTitles:@[@"None", @"Fade", @"Pop", @"Slide Up", @"Typewriter", @"Bounce"]];
    self.animationPopup.target = self; self.animationPopup.action = @selector(animationChanged:);
    [docView addSubview:self.animationPopup];
    [self layoutRow:animLabel control:self.animationPopup in:docView below:prev pad:pad rowH:rowH];
    prev = animLabel;

    // === CHECKBOXES ===
    self.allCapsCheckbox = [NSButton checkboxWithTitle:@"ALL CAPS" target:self action:@selector(capsToggled:)];
    self.allCapsCheckbox.translatesAutoresizingMaskIntoConstraints = NO;
    self.allCapsCheckbox.font = [NSFont systemFontOfSize:11];
    [docView addSubview:self.allCapsCheckbox];

    self.wordHighlightCheckbox = [NSButton checkboxWithTitle:@"Word-by-word highlight" target:self action:@selector(highlightToggled:)];
    self.wordHighlightCheckbox.translatesAutoresizingMaskIntoConstraints = NO;
    self.wordHighlightCheckbox.font = [NSFont systemFontOfSize:11];
    [docView addSubview:self.wordHighlightCheckbox];

    [NSLayoutConstraint activateConstraints:@[
        [self.allCapsCheckbox.topAnchor constraintEqualToAnchor:prev.bottomAnchor constant:10],
        [self.allCapsCheckbox.leadingAnchor constraintEqualToAnchor:docView.leadingAnchor constant:pad + 84],
        [self.wordHighlightCheckbox.centerYAnchor constraintEqualToAnchor:self.allCapsCheckbox.centerYAnchor],
        [self.wordHighlightCheckbox.leadingAnchor constraintEqualToAnchor:self.allCapsCheckbox.trailingAnchor constant:16],
    ]];
    prev = self.allCapsCheckbox;

    // === SEPARATOR ===
    NSBox *sep1 = [[NSBox alloc] init]; sep1.boxType = NSBoxSeparator;
    sep1.translatesAutoresizingMaskIntoConstraints = NO;
    [docView addSubview:sep1];
    [NSLayoutConstraint activateConstraints:@[
        [sep1.topAnchor constraintEqualToAnchor:prev.bottomAnchor constant:10],
        [sep1.leadingAnchor constraintEqualToAnchor:docView.leadingAnchor constant:pad],
        [sep1.trailingAnchor constraintEqualToAnchor:docView.trailingAnchor constant:-pad],
    ]];
    prev = sep1;

    // === GROUPING ===
    NSTextField *groupLabel = [self makeLabel:@"Grouping"];
    [docView addSubview:groupLabel];
    self.groupingPopup = [[NSPopUpButton alloc] init];
    self.groupingPopup.translatesAutoresizingMaskIntoConstraints = NO;
    self.groupingPopup.controlSize = NSControlSizeSmall;
    [self.groupingPopup addItemsWithTitles:@[@"By Words", @"By Sentence", @"By Time", @"By Characters"]];
    self.groupingPopup.target = self; self.groupingPopup.action = @selector(groupingChanged:);
    [docView addSubview:self.groupingPopup];

    self.groupingValueField = [[NSTextField alloc] init];
    self.groupingValueField.translatesAutoresizingMaskIntoConstraints = NO;
    self.groupingValueField.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular];
    self.groupingValueField.alignment = NSTextAlignmentCenter;
    self.groupingValueField.stringValue = @"5";
    self.groupingValueField.controlSize = NSControlSizeSmall;
    [docView addSubview:self.groupingValueField];

    NSTextField *gpSuffix = [self makeTinyLabel:@"max per group"];
    [docView addSubview:gpSuffix];

    [NSLayoutConstraint activateConstraints:@[
        [groupLabel.topAnchor constraintEqualToAnchor:prev.bottomAnchor constant:10],
        [groupLabel.leadingAnchor constraintEqualToAnchor:docView.leadingAnchor constant:pad],
        [groupLabel.widthAnchor constraintEqualToConstant:80],
        [self.groupingPopup.centerYAnchor constraintEqualToAnchor:groupLabel.centerYAnchor],
        [self.groupingPopup.leadingAnchor constraintEqualToAnchor:groupLabel.trailingAnchor constant:4],
        [self.groupingValueField.centerYAnchor constraintEqualToAnchor:groupLabel.centerYAnchor],
        [self.groupingValueField.leadingAnchor constraintEqualToAnchor:self.groupingPopup.trailingAnchor constant:6],
        [self.groupingValueField.widthAnchor constraintEqualToConstant:40],
        [gpSuffix.centerYAnchor constraintEqualToAnchor:groupLabel.centerYAnchor],
        [gpSuffix.leadingAnchor constraintEqualToAnchor:self.groupingValueField.trailingAnchor constant:4],
    ]];
    prev = groupLabel;

    // === SEPARATOR ===
    NSBox *sep2 = [[NSBox alloc] init]; sep2.boxType = NSBoxSeparator;
    sep2.translatesAutoresizingMaskIntoConstraints = NO;
    [docView addSubview:sep2];
    [NSLayoutConstraint activateConstraints:@[
        [sep2.topAnchor constraintEqualToAnchor:prev.bottomAnchor constant:10],
        [sep2.leadingAnchor constraintEqualToAnchor:docView.leadingAnchor constant:pad],
        [sep2.trailingAnchor constraintEqualToAnchor:docView.trailingAnchor constant:-pad],
    ]];
    prev = sep2;

    // === ACTION BUTTONS ===
    self.transcribeButton = [NSButton buttonWithTitle:@"Transcribe" target:self action:@selector(transcribeClicked:)];
    self.transcribeButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.transcribeButton.bezelStyle = NSBezelStyleRounded;
    [docView addSubview:self.transcribeButton];

    self.generateButton = [NSButton buttonWithTitle:@"Generate Captions" target:self action:@selector(generateClicked:)];
    self.generateButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.generateButton.bezelStyle = NSBezelStyleRounded;
    self.generateButton.keyEquivalent = @"\r";
    [docView addSubview:self.generateButton];

    [NSLayoutConstraint activateConstraints:@[
        [self.transcribeButton.topAnchor constraintEqualToAnchor:prev.bottomAnchor constant:12],
        [self.transcribeButton.leadingAnchor constraintEqualToAnchor:docView.leadingAnchor constant:pad],
        [self.generateButton.centerYAnchor constraintEqualToAnchor:self.transcribeButton.centerYAnchor],
        [self.generateButton.leadingAnchor constraintEqualToAnchor:self.transcribeButton.trailingAnchor constant:8],
    ]];

    self.exportSRTButton = [NSButton buttonWithTitle:@"SRT" target:self action:@selector(exportSRTClicked:)];
    self.exportSRTButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.exportSRTButton.bezelStyle = NSBezelStyleRounded;
    self.exportSRTButton.font = [NSFont systemFontOfSize:11];
    [docView addSubview:self.exportSRTButton];

    self.exportTXTButton = [NSButton buttonWithTitle:@"TXT" target:self action:@selector(exportTXTClicked:)];
    self.exportTXTButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.exportTXTButton.bezelStyle = NSBezelStyleRounded;
    self.exportTXTButton.font = [NSFont systemFontOfSize:11];
    [docView addSubview:self.exportTXTButton];

    [NSLayoutConstraint activateConstraints:@[
        [self.exportTXTButton.centerYAnchor constraintEqualToAnchor:self.transcribeButton.centerYAnchor],
        [self.exportTXTButton.trailingAnchor constraintEqualToAnchor:docView.trailingAnchor constant:-pad],
        [self.exportSRTButton.centerYAnchor constraintEqualToAnchor:self.transcribeButton.centerYAnchor],
        [self.exportSRTButton.trailingAnchor constraintEqualToAnchor:self.exportTXTButton.leadingAnchor constant:-4],
    ]];

    // Bottom constraint for scrollable doc view
    [self.transcribeButton.bottomAnchor constraintLessThanOrEqualToAnchor:docView.bottomAnchor constant:-pad].active = YES;

    [self syncUIFromStyle];
}

#pragma mark - UI Helpers

- (NSTextField *)makeLabel:(NSString *)text {
    NSTextField *label = [NSTextField labelWithString:text];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
    label.textColor = [NSColor secondaryLabelColor];
    return label;
}

- (NSTextField *)makeTinyLabel:(NSString *)text {
    NSTextField *label = [NSTextField labelWithString:text];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.font = [NSFont systemFontOfSize:9];
    label.textColor = [NSColor tertiaryLabelColor];
    return label;
}

- (NSColorWell *)makeColorWell {
    NSColorWell *well = [[NSColorWell alloc] initWithFrame:NSMakeRect(0, 0, 24, 24)];
    well.translatesAutoresizingMaskIntoConstraints = NO;
    well.bordered = YES;
    [NSLayoutConstraint activateConstraints:@[
        [well.widthAnchor constraintEqualToConstant:24],
        [well.heightAnchor constraintEqualToConstant:24],
    ]];
    return well;
}

- (void)layoutRow:(NSView *)label control:(NSView *)ctrl in:(NSView *)parent below:(NSView *)prev
              pad:(CGFloat)pad rowH:(CGFloat)rowH {
    [NSLayoutConstraint activateConstraints:@[
        [label.topAnchor constraintEqualToAnchor:prev.bottomAnchor constant:8],
        [label.leadingAnchor constraintEqualToAnchor:parent.leadingAnchor constant:pad],
        [label.widthAnchor constraintEqualToConstant:80],
        [ctrl.centerYAnchor constraintEqualToAnchor:label.centerYAnchor],
        [ctrl.leadingAnchor constraintEqualToAnchor:label.trailingAnchor constant:4],
        [ctrl.trailingAnchor constraintEqualToAnchor:parent.trailingAnchor constant:-pad],
    ]];
}

- (void)syncUIFromStyle {
    if (!self.panel) return;
    SpliceKitCaptionStyle *s = self.style;

    // Preset popup
    NSArray *presets = [SpliceKitCaptionStyle builtInPresets];
    NSInteger idx = -1;
    for (NSInteger i = 0; i < (NSInteger)presets.count; i++) {
        if ([((SpliceKitCaptionStyle *)presets[i]).presetID isEqualToString:s.presetID]) { idx = i; break; }
    }
    if (idx >= 0) [self.presetPopup selectItemAtIndex:idx];

    // Font
    [self.fontPopup selectItemWithTitle:s.font ?: @"Helvetica Neue"];

    // Font size
    self.fontSizeSlider.doubleValue = s.fontSize;
    self.fontSizeField.stringValue = [NSString stringWithFormat:@"%.0f", s.fontSize];

    // Colors
    self.textColorWell.color = s.textColor ?: [NSColor whiteColor];
    self.highlightColorWell.color = s.highlightColor ?: [NSColor yellowColor];
    self.outlineColorWell.color = s.outlineColor ?: [NSColor blackColor];
    self.shadowColorWell.color = s.shadowColor ?: [NSColor blackColor];

    // Sliders
    self.outlineWidthSlider.doubleValue = s.outlineWidth;
    self.shadowBlurSlider.doubleValue = s.shadowBlurRadius;

    // Popups
    [self.positionPopup selectItemAtIndex:(NSInteger)s.position];
    [self.animationPopup selectItemAtIndex:(NSInteger)s.animation];

    // Checkboxes
    self.allCapsCheckbox.state = s.allCaps ? NSControlStateValueOn : NSControlStateValueOff;
    self.wordHighlightCheckbox.state = s.wordByWordHighlight ? NSControlStateValueOn : NSControlStateValueOff;

    // Grouping
    [self.groupingPopup selectItemAtIndex:(NSInteger)self.groupingMode];
    NSUInteger val = self.maxWordsPerSegment;
    if (self.groupingMode == SpliceKitCaptionGroupingByCharCount) val = self.maxCharsPerSegment;
    self.groupingValueField.stringValue = [NSString stringWithFormat:@"%lu", (unsigned long)val];

    [self updatePreview];
}

- (void)updatePreview {
    if (!self.previewLabel) return;
    SpliceKitCaptionStyle *s = self.style;

    NSString *word1 = s.allCaps ? @"THE " : @"The ";
    NSString *word2 = s.allCaps ? @"QUICK " : @"quick ";
    NSString *word3 = s.allCaps ? @"BROWN FOX" : @"brown fox";

    CGFloat previewFontSize = MIN(s.fontSize * 0.4, 36);
    NSFont *font = [NSFont fontWithName:s.font size:previewFontSize] ?:
                   [NSFont boldSystemFontOfSize:previewFontSize];

    NSMutableDictionary *normalAttrs = [@{
        NSFontAttributeName: font,
        NSForegroundColorAttributeName: s.textColor ?: [NSColor whiteColor],
    } mutableCopy];

    NSMutableDictionary *highlightAttrs = [@{
        NSFontAttributeName: font,
        NSForegroundColorAttributeName: (s.highlightColor && s.wordByWordHighlight)
            ? s.highlightColor : (s.textColor ?: [NSColor whiteColor]),
    } mutableCopy];

    // Outline via stroke
    if (s.outlineColor && s.outlineWidth > 0) {
        normalAttrs[NSStrokeColorAttributeName] = s.outlineColor;
        normalAttrs[NSStrokeWidthAttributeName] = @(-s.outlineWidth); // negative = fill + stroke
        highlightAttrs[NSStrokeColorAttributeName] = s.outlineColor;
        highlightAttrs[NSStrokeWidthAttributeName] = @(-s.outlineWidth);
    }

    // Shadow
    if (s.shadowColor && s.shadowBlurRadius > 0) {
        NSShadow *shadow = [[NSShadow alloc] init];
        shadow.shadowColor = s.shadowColor;
        shadow.shadowBlurRadius = s.shadowBlurRadius * 0.4;
        shadow.shadowOffset = NSMakeSize(s.shadowOffsetX * 0.4, -s.shadowOffsetY * 0.4);
        normalAttrs[NSShadowAttributeName] = shadow;
        highlightAttrs[NSShadowAttributeName] = shadow;
    }

    NSMutableAttributedString *attrStr = [[NSMutableAttributedString alloc] init];
    [attrStr appendAttributedString:[[NSAttributedString alloc] initWithString:word1 attributes:normalAttrs]];
    [attrStr appendAttributedString:[[NSAttributedString alloc] initWithString:word2 attributes:highlightAttrs]];
    [attrStr appendAttributedString:[[NSAttributedString alloc] initWithString:word3 attributes:normalAttrs]];

    self.previewLabel.attributedStringValue = attrStr;
}

#pragma mark - UI Actions

- (void)presetChanged:(id)sender {
    NSArray *presets = [SpliceKitCaptionStyle builtInPresets];
    NSInteger idx = self.presetPopup.indexOfSelectedItem;
    if (idx >= 0 && idx < (NSInteger)presets.count) {
        self.style = [presets[idx] copy];
        [self syncUIFromStyle];
    }
}

- (void)fontChanged:(id)sender { self.style.font = self.fontPopup.titleOfSelectedItem; [self updatePreview]; }
- (void)fontSizeChanged:(id)sender {
    self.style.fontSize = self.fontSizeSlider.doubleValue;
    self.fontSizeField.stringValue = [NSString stringWithFormat:@"%.0f", self.style.fontSize];
    [self updatePreview];
}
- (void)colorChanged:(id)sender {
    self.style.textColor = self.textColorWell.color;
    self.style.highlightColor = self.highlightColorWell.color;
    self.style.outlineColor = self.outlineColorWell.color;
    self.style.shadowColor = self.shadowColorWell.color;
    [self updatePreview];
}
- (void)outlineWidthChanged:(id)sender { self.style.outlineWidth = self.outlineWidthSlider.doubleValue; }
- (void)shadowBlurChanged:(id)sender { self.style.shadowBlurRadius = self.shadowBlurSlider.doubleValue; }
- (void)positionChanged:(id)sender { self.style.position = (SpliceKitCaptionPosition)self.positionPopup.indexOfSelectedItem; }
- (void)animationChanged:(id)sender { self.style.animation = (SpliceKitCaptionAnimation)self.animationPopup.indexOfSelectedItem; }
- (void)capsToggled:(id)sender { self.style.allCaps = (self.allCapsCheckbox.state == NSControlStateValueOn); [self updatePreview]; }
- (void)highlightToggled:(id)sender { self.style.wordByWordHighlight = (self.wordHighlightCheckbox.state == NSControlStateValueOn); [self updatePreview]; }

- (void)groupingChanged:(id)sender {
    self.groupingMode = (SpliceKitCaptionGrouping)self.groupingPopup.indexOfSelectedItem;
    if (self.mutableWords.count > 0) [self regroupSegments];
}

- (void)transcribeClicked:(id)sender { [self transcribeTimeline]; }
- (void)generateClicked:(id)sender {
    self.generateButton.enabled = NO;
    self.statusLabel.stringValue = @"Generating captions...";
    // Must run on background thread — generateCaptions does dispatch_sync to main
    // for the import step, which would deadlock if called from main thread.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSDictionary *result = [self generateCaptions];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.generateButton.enabled = YES;
            if (result[@"error"]) {
                self.statusLabel.stringValue = [NSString stringWithFormat:@"Error: %@", result[@"error"]];
            }
        });
    });
}

- (void)exportSRTClicked:(id)sender {
    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.allowedContentTypes = @[[UTType typeWithFilenameExtension:@"srt"]];
    panel.nameFieldStringValue = @"captions.srt";
    [panel beginSheetModalForWindow:self.panel completionHandler:^(NSModalResponse result) {
        if (result == NSModalResponseOK) {
            [self exportSRT:panel.URL.path];
        }
    }];
}

- (void)exportTXTClicked:(id)sender {
    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.allowedContentTypes = @[[UTType typeWithFilenameExtension:@"txt"]];
    panel.nameFieldStringValue = @"captions.txt";
    [panel beginSheetModalForWindow:self.panel completionHandler:^(NSModalResponse result) {
        if (result == NSModalResponseOK) {
            [self exportTXT:panel.URL.path];
        }
    }];
}

- (void)windowWillClose:(NSNotification *)notification {
    // Panel closed by user — just let it hide
}

#pragma mark - Panel Visibility

- (void)showPanel {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self setupPanelIfNeeded];
        [self.panel makeKeyAndOrderFront:nil];
    });
}

- (void)hidePanel {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.panel orderOut:nil];
    });
}

- (BOOL)isVisible {
    return self.panel && self.panel.isVisible;
}

#pragma mark - Style Management

- (void)setStyle:(SpliceKitCaptionStyle *)style {
    _style = [style copy];
    if (self.panel) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self syncUIFromStyle];
        });
    }
}

- (SpliceKitCaptionStyle *)currentStyle {
    return [self.style copy];
}

#pragma mark - Transcription (Delegate to Transcript Panel)

- (void)transcribeTimeline {
    self.status = SpliceKitCaptionStatusTranscribing;
    dispatch_async(dispatch_get_main_queue(), ^{
        self.spinner.hidden = NO;
        [self.spinner startAnimation:nil];
        self.transcribeButton.enabled = NO;
        self.statusLabel.stringValue = @"Transcribing timeline...";
    });

    SpliceKitTranscriptPanel *tp = [SpliceKitTranscriptPanel sharedPanel];

    // If transcript panel already has words, reuse them
    if (tp.status == SpliceKitTranscriptStatusReady && tp.words.count > 0) {
        [self importWordsFromTranscriptPanel];
        return;
    }

    // Register for completion notification
    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(transcriptDidComplete:)
        name:@"SpliceKitTranscriptDidComplete"
        object:nil];

    // Force Parakeet for best word-level timing
    tp.engine = SpliceKitTranscriptEngineParakeet;
    [tp transcribeTimeline];
}

- (void)transcriptDidComplete:(NSNotification *)note {
    [[NSNotificationCenter defaultCenter] removeObserver:self
        name:@"SpliceKitTranscriptDidComplete" object:nil];
    [self importWordsFromTranscriptPanel];
}

- (void)importWordsFromTranscriptPanel {
    SpliceKitTranscriptPanel *tp = [SpliceKitTranscriptPanel sharedPanel];
    @synchronized (self.mutableWords) {
        [self.mutableWords removeAllObjects];
        [self.mutableWords addObjectsFromArray:tp.words ?: @[]];
    }

    self.status = SpliceKitCaptionStatusReady;
    [self regroupSegments];

    dispatch_async(dispatch_get_main_queue(), ^{
        self.spinner.hidden = YES;
        [self.spinner stopAnimation:nil];
        self.transcribeButton.enabled = YES;
        self.statusLabel.stringValue = [NSString stringWithFormat:@"%lu words, %lu segments",
            (unsigned long)self.mutableWords.count, (unsigned long)self.mutableSegments.count];
    });

    SpliceKit_log(@"[Captions] Imported %lu words from transcript panel",
                  (unsigned long)self.mutableWords.count);
}

- (void)setWordsManually:(NSArray<NSDictionary *> *)wordDicts {
    @synchronized (self.mutableWords) {
        [self.mutableWords removeAllObjects];
        for (NSUInteger i = 0; i < wordDicts.count; i++) {
            NSDictionary *d = wordDicts[i];
            SpliceKitTranscriptWord *w = [[SpliceKitTranscriptWord alloc] init];
            w.text = d[@"text"] ?: @"";
            w.startTime = [d[@"startTime"] doubleValue];
            w.duration = [d[@"duration"] doubleValue];
            w.endTime = w.startTime + w.duration;
            w.confidence = 1.0;
            w.wordIndex = i;
            [self.mutableWords addObject:w];
        }
    }
    self.status = SpliceKitCaptionStatusReady;
    [self regroupSegments];
}

#pragma mark - Word Grouping

- (void)regroupSegments {
    NSMutableArray<SpliceKitCaptionSegment *> *segments = [NSMutableArray array];
    NSArray *words = nil;
    @synchronized (self.mutableWords) {
        words = [self.mutableWords copy];
    }
    if (words.count == 0) {
        self.mutableSegments = segments;
        return;
    }

    NSMutableArray<SpliceKitTranscriptWord *> *group = [NSMutableArray array];
    NSUInteger segIdx = 0;

    for (NSUInteger i = 0; i < words.count; i++) {
        SpliceKitTranscriptWord *word = words[i];
        BOOL shouldBreak = NO;

        // Force break on silence gaps (0.5s for social, 1.0s for others)
        if (group.count > 0) {
            double gap = word.startTime - ((SpliceKitTranscriptWord *)group.lastObject).endTime;
            double silenceThreshold = (self.groupingMode == SpliceKitCaptionGroupingSocial) ? 0.5 : 1.0;
            if (gap > silenceThreshold) shouldBreak = YES;
        }

        if (!shouldBreak && group.count > 0) {
            switch (self.groupingMode) {
                case SpliceKitCaptionGroupingByWordCount:
                    shouldBreak = (group.count >= self.maxWordsPerSegment);
                    break;
                case SpliceKitCaptionGroupingBySentence: {
                    NSString *prevText = ((SpliceKitTranscriptWord *)group.lastObject).text;
                    shouldBreak = [prevText hasSuffix:@"."] || [prevText hasSuffix:@"!"] ||
                                  [prevText hasSuffix:@"?"] || [prevText hasSuffix:@";"];
                    if (!shouldBreak) shouldBreak = (group.count >= 8);
                    break;
                }
                case SpliceKitCaptionGroupingByTime: {
                    double groupStart = ((SpliceKitTranscriptWord *)group.firstObject).startTime;
                    shouldBreak = (word.endTime - groupStart) > self.maxSecondsPerSegment;
                    break;
                }
                case SpliceKitCaptionGroupingByCharCount: {
                    NSUInteger totalChars = 0;
                    for (SpliceKitTranscriptWord *w in group) totalChars += w.text.length + 1;
                    shouldBreak = (totalChars + word.text.length > self.maxCharsPerSegment);
                    break;
                }
                case SpliceKitCaptionGroupingSocial: {
                    // Optimized for social media: 2-3 words, break on short pauses & punctuation
                    NSString *prevText = ((SpliceKitTranscriptWord *)group.lastObject).text;
                    BOOL sentenceEnd = [prevText hasSuffix:@"."] || [prevText hasSuffix:@"!"]
                                    || [prevText hasSuffix:@"?"];
                    BOOL hitMax = (group.count >= 3);
                    shouldBreak = sentenceEnd || hitMax;
                    break;
                }
            }
        }

        if (shouldBreak && group.count > 0) {
            SpliceKitCaptionSegment *seg = [self segmentFromWords:group index:segIdx++];
            [segments addObject:seg];
            [group removeAllObjects];
        }
        [group addObject:word];
    }

    // Flush remaining
    if (group.count > 0) {
        [segments addObject:[self segmentFromWords:group index:segIdx]];
    }

    self.mutableSegments = segments;
    SpliceKit_log(@"[Captions] Grouped %lu words into %lu segments",
                  (unsigned long)words.count, (unsigned long)segments.count);
}

- (SpliceKitCaptionSegment *)segmentFromWords:(NSArray *)words index:(NSUInteger)idx {
    SpliceKitCaptionSegment *seg = [[SpliceKitCaptionSegment alloc] init];
    seg.words = [words copy];
    seg.startTime = ((SpliceKitTranscriptWord *)words.firstObject).startTime;
    seg.endTime = ((SpliceKitTranscriptWord *)words.lastObject).endTime;
    seg.duration = seg.endTime - seg.startTime;
    NSMutableArray *texts = [NSMutableArray array];
    for (SpliceKitTranscriptWord *w in words) { [texts addObject:w.text ?: @""]; }
    seg.text = [texts componentsJoinedByString:@" "];
    seg.segmentIndex = idx;
    return seg;
}

#pragma mark - Accessors

- (NSArray<SpliceKitCaptionSegment *> *)segments { return [self.mutableSegments copy]; }
- (NSArray<SpliceKitTranscriptWord *> *)words { return [self.mutableWords copy]; }

#pragma mark - FCPXML Generation

- (void)detectTimelineProperties {
    // Detect frame rate and resolution from the active timeline
    id timelineModule = SpliceKit_getActiveTimelineModule();
    if (!timelineModule) {
        SpliceKit_log(@"[Captions] detectTimelineProperties: no active timeline module");
        return;
    }

    SEL seqSel = NSSelectorFromString(@"sequence");
    id sequence = ((id (*)(id, SEL))objc_msgSend)(timelineModule, seqSel);
    if (!sequence) {
        SpliceKit_log(@"[Captions] detectTimelineProperties: no sequence");
        return;
    }

    // Frame duration — CMTime is a 24-byte struct (value:8 + timescale:4 + flags:4 + epoch:8)
    // ARM64: returned by value from objc_msgSend
    // x86_64: returned via pointer (objc_msgSend_stret) for structs > 16 bytes
    SEL fdSel = NSSelectorFromString(@"sequenceFrameDuration");
    if ([timelineModule respondsToSelector:fdSel]) {
        @try {
            typedef struct { int64_t value; int32_t timescale; uint32_t flags; int64_t epoch; } CMTimeStruct;
#if defined(__arm64__)
            CMTimeStruct fd = ((CMTimeStruct (*)(id, SEL))objc_msgSend)(timelineModule, fdSel);
#else
            CMTimeStruct fd;
            ((void (*)(CMTimeStruct *, id, SEL))objc_msgSend_stret)(&fd, timelineModule, fdSel);
#endif
            SpliceKit_log(@"[Captions] Frame duration: %lld/%d", fd.value, fd.timescale);
            if (fd.timescale > 0 && fd.value > 0) {
                self.fdNum = (int)fd.value;
                self.fdDen = fd.timescale;
                self.frameRate = (double)fd.timescale / fd.value;
            }
        } @catch (NSException *e) {
            SpliceKit_log(@"[Captions] Exception getting frame duration: %@", e.reason);
        }
    }

    // Resolution — NSSize is 16 bytes (2 x double), fits in registers on ARM64
    SEL resSel = NSSelectorFromString(@"renderSize");
    if ([sequence respondsToSelector:resSel]) {
        @try {
#if defined(__arm64__)
            NSSize size = ((NSSize (*)(id, SEL))objc_msgSend)(sequence, resSel);
#else
            NSSize size;
            ((void (*)(NSSize *, id, SEL))objc_msgSend_stret)(&size, sequence, resSel);
#endif
            SpliceKit_log(@"[Captions] Render size: %.0f x %.0f", size.width, size.height);
            if (size.width > 0 && size.height > 0) {
                self.videoWidth = (int)size.width;
                self.videoHeight = (int)size.height;
            }
        } @catch (NSException *e) {
            SpliceKit_log(@"[Captions] Exception getting render size: %@", e.reason);
        }
    }

    SpliceKit_log(@"[Captions] Timeline: %dx%d @ %.2f fps (fd=%d/%d)",
                  self.videoWidth, self.videoHeight, self.frameRate, self.fdNum, self.fdDen);
}

static NSString *SpliceKitCaption_durRational(double seconds, int fdNum, int fdDen) {
    if (seconds <= 0) return @"0s";
    long long frames = (long long)round(seconds * fdDen / fdNum);
    if (frames <= 0) frames = 1;
    return [NSString stringWithFormat:@"%lld/%ds", frames * fdNum, fdDen];
}

static SpliceKitCaption_CMTime SpliceKitCaption_makeCMTime(double seconds, int timescale) {
    int safeTimescale = MAX(timescale, 1);
    SpliceKitCaption_CMTime time;
    time.value = (int64_t)llround(seconds * safeTimescale);
    time.timescale = safeTimescale;
    time.flags = 1;
    time.epoch = 0;
    return time;
}

static id SpliceKitCaption_primaryObjectForSequence(id sequence) {
    if (!sequence) return nil;
    SEL primarySel = NSSelectorFromString(@"primaryObject");
    if (![sequence respondsToSelector:primarySel]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(sequence, primarySel);
}

static id SpliceKitCaption_hostItemForTime(id sequence, double seconds, int timescale) {
    id primary = SpliceKitCaption_primaryObjectForSequence(sequence);
    if (!primary) return nil;

    SpliceKitCaption_CMTime targetTime = SpliceKitCaption_makeCMTime(seconds, timescale);
    SEL containedAtTimeSel = NSSelectorFromString(@"containedItemAtTime:");
    if ([primary respondsToSelector:containedAtTimeSel]) {
        id item = ((id (*)(id, SEL, SpliceKitCaption_CMTime))objc_msgSend)(
            primary, containedAtTimeSel, targetTime);
        if (item) return item;
    }

    SEL itemsSel = NSSelectorFromString(@"containedItems");
    NSArray *items = [primary respondsToSelector:itemsSel]
        ? ((id (*)(id, SEL))objc_msgSend)(primary, itemsSel)
        : nil;
    if (![items isKindOfClass:[NSArray class]] || items.count == 0) return nil;

    SEL rangeSel = NSSelectorFromString(@"effectiveRangeOfObject:");
    id bestItem = nil;
    double bestStart = -DBL_MAX;

    for (id item in items) {
        @try {
            if (![primary respondsToSelector:rangeSel]) continue;
            SpliceKitCaption_CMTimeRange range =
                ((SpliceKitCaption_CMTimeRange (*)(id, SEL, id))STRET_MSG)(primary, rangeSel, item);
            if (range.start.timescale <= 0 || range.duration.timescale <= 0) continue;
            double start = (double)range.start.value / (double)range.start.timescale;
            double duration = (double)range.duration.value / (double)range.duration.timescale;
            double end = start + duration;
            if (seconds >= start && seconds <= end) return item;
            if (start <= seconds && start > bestStart) {
                bestStart = start;
                bestItem = item;
            }
        } @catch (NSException *e) {
        }
    }

    return bestItem ?: [items lastObject];
}

static BOOL SpliceKitCaption_setChannelDouble(id channel, double value) {
    if (!channel) return NO;
    @try {
        SpliceKitCaption_CMTime t = {0, 0, 17, 0}; // kCMTimeIndefinite
        SEL setSel = NSSelectorFromString(@"setCurveDoubleValue:atTime:options:");
        if ([channel respondsToSelector:setSel]) {
            ((void (*)(id, SEL, double, SpliceKitCaption_CMTime, unsigned int))objc_msgSend)(
                channel, setSel, value, t, 0);
            return YES;
        }
    } @catch (NSException *e) {
    }
    return NO;
}

static id SpliceKitCaption_subChannel(id parentChannel, NSString *axis) {
    if (!parentChannel) return nil;
    NSString *selectorName = [NSString stringWithFormat:@"%@Channel", axis];
    SEL selector = NSSelectorFromString(selectorName);
    if (![parentChannel respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(parentChannel, selector);
}

static BOOL SpliceKitCaption_applyTransformToTitle(id titleObject, CGFloat yOffset, CGFloat scalePercent) {
    if (!titleObject) return NO;

    @try {
        Class cutawayEffects = objc_getClass("FFCutawayEffects");
        if (!cutawayEffects) return NO;

        SEL transformSel = NSSelectorFromString(@"transformEffectForObject:createIfAbsent:");
        if (![cutawayEffects respondsToSelector:transformSel]) return NO;

        id xformEffect = ((id (*)(id, SEL, id, BOOL))objc_msgSend)(
            cutawayEffects, transformSel, titleObject, YES);
        if (!xformEffect) return NO;

        id position3D = [xformEffect respondsToSelector:NSSelectorFromString(@"positionChannel3D")]
            ? ((id (*)(id, SEL))objc_msgSend)(xformEffect, NSSelectorFromString(@"positionChannel3D"))
            : nil;
        id scale3D = [xformEffect respondsToSelector:NSSelectorFromString(@"scaleChannel3D")]
            ? ((id (*)(id, SEL))objc_msgSend)(xformEffect, NSSelectorFromString(@"scaleChannel3D"))
            : nil;

        BOOL changed = NO;
        changed |= SpliceKitCaption_setChannelDouble(SpliceKitCaption_subChannel(position3D, @"x"), 0.0);
        changed |= SpliceKitCaption_setChannelDouble(SpliceKitCaption_subChannel(position3D, @"y"), yOffset);
        changed |= SpliceKitCaption_setChannelDouble(SpliceKitCaption_subChannel(scale3D, @"x"), scalePercent);
        changed |= SpliceKitCaption_setChannelDouble(SpliceKitCaption_subChannel(scale3D, @"y"), scalePercent);
        return changed;
    } @catch (NSException *e) {
        SpliceKit_log(@"[Captions] Failed to apply title transform: %@", e.reason);
    }
    return NO;
}

// mCaptions-style import: generate FCPXML with all captions as connected titles
// inside a single gap (lane 1), import via FFXMLTranslationTask, then copy/paste
// the entire connected storyline onto the user's timeline in one shot.

static NSString *const kCaptionImportProjectPrefix = @"SpliceKit Caption Import";

// Enumerate all sequences in the active library. Must be called on main thread.
static NSArray *SpliceKitCaption_allSequences(void) {
    id activeLibs = ((id (*)(id, SEL))objc_msgSend)(
        objc_getClass("FFLibraryDocument"), NSSelectorFromString(@"copyActiveLibraries"));
    if (!activeLibs || [(NSArray *)activeLibs count] == 0) return @[];
    id library = [(NSArray *)activeLibs objectAtIndex:0];
    id seqSet = ((id (*)(id, SEL))objc_msgSend)(library,
        NSSelectorFromString(@"_deepLoadedSequences"));
    return ((id (*)(id, SEL))objc_msgSend)(seqSet, NSSelectorFromString(@"allObjects")) ?: @[];
}

static id SpliceKitCaption_findSequenceByPrefix(NSString *prefix) {
    for (id seq in SpliceKitCaption_allSequences()) {
        NSString *seqName = ((id (*)(id, SEL))objc_msgSend)(seq,
            NSSelectorFromString(@"displayName"));
        if ([seqName hasPrefix:prefix]) return seq;
    }
    return nil;
}

static id SpliceKitCaption_currentSequence(void) {
    id tm = SpliceKit_getActiveTimelineModule();
    if (!tm) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(tm, NSSelectorFromString(@"sequence"));
}

static void SpliceKitCaption_deleteSequence(id sequence) {
    if (!sequence) return;
    @try {
        SEL containerEventSel = NSSelectorFromString(@"containerEvent");
        SEL eventSel = NSSelectorFromString(@"event");
        id event = nil;
        if ([sequence respondsToSelector:containerEventSel])
            event = ((id (*)(id, SEL))objc_msgSend)(sequence, containerEventSel);
        else if ([sequence respondsToSelector:eventSel])
            event = ((id (*)(id, SEL))objc_msgSend)(sequence, eventSel);
        if (event) {
            SEL removeSel = NSSelectorFromString(@"removeObjectFromContainedItems:");
            if ([event respondsToSelector:removeSel]) {
                ((void (*)(id, SEL, id))objc_msgSend)(event, removeSel, sequence);
                return;
            }
        }
        SEL trashSel = NSSelectorFromString(@"moveToTrash:");
        if ([sequence respondsToSelector:trashSel])
            ((void (*)(id, SEL, id))objc_msgSend)(sequence, trashSel, nil);
    } @catch (NSException *e) {
        SpliceKit_log(@"[Captions] Warning: could not delete temp project: %@", e.reason);
    }
}

static BOOL SpliceKitCaption_pollMainThread(BOOL (^condition)(void), double timeoutSec, double intervalSec) {
    double elapsed = 0;
    while (elapsed < timeoutSec) {
        __block BOOL result = NO;
        SpliceKit_executeOnMainThread(^{ result = condition(); });
        if (result) return YES;
        [NSThread sleepForTimeInterval:intervalSec];
        elapsed += intervalSec;
    }
    return NO;
}

- (NSArray<NSView *> *)allSubviewsOf:(NSView *)view {
    NSMutableArray *result = [NSMutableArray array];
    for (NSView *sub in view.subviews) {
        [result addObject:sub];
        [result addObjectsFromArray:[self allSubviewsOf:sub]];
    }
    return result;
}

- (NSDictionary *)addCaptionTitlesDirectlyToTimeline {
    // Strategy: import FCPXML into a temp project, copy the connected storyline to
    // clipboard via FCP's native copy, switch back to the user's project, and
    // pasteAsConnected. This places captions directly on the user's timeline.
    //
    // NOTE (Improvement #7): The import-switch-copy-switchback pipeline is now
    // available as a shared function: SpliceKit_convertFCPXMLToNativeClipboard().
    // This method still uses its own pipeline because it needs caption-specific
    // post-processing (position offset via FFCutawayEffects transform, text/font
    // verification via CHChannelText inspection). To consolidate, this method
    // could be refactored to:
    //   1. Build FCPXML (same as now)
    //   2. Write to pasteboard via IXXMLPasteboardType
    //   3. SpliceKit_convertFCPXMLToNativeClipboard() (handles import+copy+switchback)
    //   4. pasteAnchored: (places clips)
    //   5. Post-process: apply position offset + verify text
    // This would eliminate ~100 lines of duplicate pipeline code.

    SpliceKitCaptionStyle *s = self.style;
    int fdN = self.fdNum, fdD = self.fdDen;

    // ---------------------------------------------------------------
    // Step 0: Remember the user's current sequence so we can switch back.
    // Store both the object reference AND display name since the pointer
    // may become stale after FCPXML import modifies the object graph.
    // ---------------------------------------------------------------
    __block id userSequence = nil;
    __block NSString *userSequenceName = nil;
    SpliceKit_executeOnMainThread(^{
        userSequence = SpliceKitCaption_currentSequence();
        if (userSequence) {
            userSequenceName = ((id (*)(id, SEL))objc_msgSend)(userSequence,
                NSSelectorFromString(@"displayName"));
        }
    });
    if (!userSequence) {
        return @{@"error": @"No active timeline — open a project first"};
    }
    SpliceKit_log(@"[Captions] User's project: '%@'", userSequenceName);

    double totalDuration = 0;
    for (SpliceKitCaptionSegment *seg in self.mutableSegments) {
        if (seg.endTime > totalDuration) totalDuration = seg.endTime;
    }
    totalDuration += 1.0;

    // ---------------------------------------------------------------
    // Step 1: Build mCaptions-style FCPXML — gap with connected titles in lane 1.
    // ---------------------------------------------------------------
    NSString *tempName = [NSString stringWithFormat:@"%@ %u",
        kCaptionImportProjectPrefix, (unsigned)(arc4random() % 10000)];
    NSString *totalDurStr = SpliceKitCaption_durRational(totalDuration, fdN, fdD);

    BOOL useWordProgress = s.wordByWordHighlight;

    NSMutableString *xml = [NSMutableString string];
    [xml appendString:@"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"];
    [xml appendString:@"<!DOCTYPE fcpxml>\n\n"];
    [xml appendFormat:@"<fcpxml version=\"%@\">\n", useWordProgress ? @"1.14" : @"1.11"];
    [xml appendString:@"    <resources>\n"];
    [xml appendFormat:@"        <format id=\"r1\" name=\"FFVideoFormat%dx%dp%d\" "
        @"frameDuration=\"%d/%ds\" width=\"%d\" height=\"%d\"/>\n",
        self.videoWidth, self.videoHeight, (int)round(self.frameRate),
        fdN, fdD, self.videoWidth, self.videoHeight];
    // Word-progress mode uses the Neon Grow TM4C template (has Sequence Text behaviors).
    // Standard mode uses Caption Large. ~/Titles.localized/ prefix resolves correctly.
    if (useWordProgress) {
        [xml appendFormat:@"        <effect id=\"r2\" name=\"%@\" uid=\"%@\"/>\n",
            kWP_TemplateName, kWP_TemplateUID];
    } else {
        [xml appendString:@"        <effect id=\"r2\" name=\"Caption Large\" "
            @"uid=\"~/Titles.localized/SpliceKit/Caption Large/Caption Large.moti\"/>\n"];
    }
    [xml appendString:@"    </resources>\n"];
    [xml appendString:@"    <library>\n"];
    [xml appendFormat:@"        <event name=\"SpliceKit Captions\">\n"];
    [xml appendFormat:@"            <project name=\"%@\">\n", tempName];
    [xml appendFormat:@"                <sequence format=\"r1\" duration=\"%@\" "
        @"tcStart=\"0s\" tcFormat=\"NDF\" audioLayout=\"stereo\" audioRate=\"48k\">\n", totalDurStr];
    [xml appendString:@"                    <spine>\n"];
    [xml appendFormat:@"                        <gap name=\"placeholder\" duration=\"%@\" start=\"0s\">\n",
        totalDurStr];

    int titleCount = 0;
    int tsCounter = 1;

    if (useWordProgress) {
        // mCaptions-style: one title per segment with word-progress keyframes
        for (SpliceKitCaptionSegment *seg in self.mutableSegments) {
            [xml appendString:[self wordProgressTitleXMLForSegment:seg
                                                        tsCounter:&tsCounter
                                                           indent:@"                            "
                                                             lane:@"1"]];
            titleCount++;
        }
    } else {
        // Standard: one simple title per segment
        for (SpliceKitCaptionSegment *seg in self.mutableSegments) {
            double segDur = MAX(seg.duration, 0.1);
            NSString *text = s.allCaps ? [seg.text uppercaseString] : seg.text;
            NSString *tsID = [NSString stringWithFormat:@"ts%d", tsCounter++];
            NSString *tsDef = [self textStyleXMLWithID:tsID color:s.textColor isHighlight:NO];
            NSString *offsetStr = SpliceKitCaption_durRational(seg.startTime, fdN, fdD);
            NSString *durStr = SpliceKitCaption_durRational(segDur, fdN, fdD);

            [xml appendFormat:@"                            <title ref=\"r2\" lane=\"1\" "
                @"offset=\"%@\" name=\"Cap%03lu\" duration=\"%@\" start=\"3600s\">\n",
                offsetStr, (unsigned long)seg.segmentIndex + 1, durStr];
            [xml appendFormat:@"                                <text><text-style ref=\"%@\">%@</text-style></text>\n",
                tsID, SpliceKitCaption_escapeXML(text)];
            [xml appendFormat:@"                                %@\n", tsDef];
            [xml appendString:@"                            </title>\n"];
            titleCount++;
        }
    }

    [xml appendString:@"                        </gap>\n"];
    [xml appendString:@"                    </spine>\n"];
    [xml appendString:@"                </sequence>\n"];
    [xml appendString:@"            </project>\n"];
    [xml appendString:@"        </event>\n"];
    [xml appendString:@"    </library>\n"];
    [xml appendString:@"</fcpxml>\n"];

    SpliceKit_log(@"[Captions] Built connected-storyline FCPXML: %d titles, %lu bytes",
                  titleCount, (unsigned long)xml.length);

    NSString *xmlPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"splicekit_captions.fcpxml"];
    [xml writeToFile:xmlPath atomically:YES encoding:NSUTF8StringEncoding error:nil];

    // ---------------------------------------------------------------
    // Step 2: Import via FFXMLTranslationTask — creates temp project in library.
    // ---------------------------------------------------------------
    NSDictionary *importResult = SpliceKit_handlePasteboardImportXML(@{@"xml": xml});
    if (importResult[@"error"]) {
        return @{@"error": [NSString stringWithFormat:@"Import failed: %@", importResult[@"error"]],
                 @"fcpxmlPath": xmlPath};
    }
    SpliceKit_log(@"[Captions] Import OK — waiting for temp project");

    // Wait for temp project to appear in library
    BOOL foundTemp = SpliceKitCaption_pollMainThread(^{
        return (BOOL)(SpliceKitCaption_findSequenceByPrefix(tempName) != nil);
    }, 5.0, 0.3);
    if (!foundTemp) {
        return @{@"error": @"Temp caption project not found after import",
                 @"fcpxmlPath": xmlPath};
    }

    // ---------------------------------------------------------------
    // Step 3: Load temp project → select all → copy to clipboard.
    // ---------------------------------------------------------------
    __block id tempSeq = nil;
    __block BOOL copyOK = NO;

    SpliceKit_executeOnMainThread(^{
        tempSeq = SpliceKitCaption_findSequenceByPrefix(tempName);
        if (!tempSeq) return;

        id appDelegate = [NSApp delegate];
        id editorContainer = ((id (*)(id, SEL))objc_msgSend)(appDelegate,
            NSSelectorFromString(@"activeEditorContainer"));
        if (!editorContainer) return;

        SEL loadSel = NSSelectorFromString(@"loadEditorForSequence:");
        if ([editorContainer respondsToSelector:loadSel]) {
            ((void (*)(id, SEL, id))objc_msgSend)(editorContainer, loadSel, tempSeq);
        }
    });

    // Wait for temp timeline to become active (match by exact temp name)
    BOOL tempReady = SpliceKitCaption_pollMainThread(^{
        id tm = SpliceKit_getActiveTimelineModule();
        if (!tm) return NO;
        id seq = ((id (*)(id, SEL))objc_msgSend)(tm, NSSelectorFromString(@"sequence"));
        if (!seq) return NO;
        NSString *name = ((id (*)(id, SEL))objc_msgSend)(seq, NSSelectorFromString(@"displayName"));
        return (BOOL)(name && [name isEqualToString:tempName]);
    }, 5.0, 0.3);

    if (!tempReady) {
        SpliceKit_log(@"[Captions] Warning: temp project '%@' may not be fully loaded", tempName);
    }

    // Give FCP time to finish loading the timeline UI
    [NSThread sleepForTimeInterval:0.5];

    // Select all items in temp project, then copy to clipboard
    SpliceKit_executeOnMainThread(^{
        [[NSApplication sharedApplication] sendAction:NSSelectorFromString(@"selectAll:")
                                                   to:nil from:nil];
    });
    [NSThread sleepForTimeInterval:0.1];

    SpliceKit_executeOnMainThread(^{
        [[NSApplication sharedApplication] sendAction:NSSelectorFromString(@"copy:")
                                                   to:nil from:nil];
        copyOK = YES;
    });
    [NSThread sleepForTimeInterval:0.1];

    SpliceKit_log(@"[Captions] Copied %d titles from temp project to clipboard", titleCount);

    // ---------------------------------------------------------------
    // Step 4: Switch back to user's project → seek to start → paste as connected.
    // The saved userSequence pointer should still be valid — FCPXML import
    // creates NEW sequences, it doesn't mutate existing ones. But we verify
    // by display name as a safety check.
    // ---------------------------------------------------------------
    SpliceKit_executeOnMainThread(^{
        id appDelegate = [NSApp delegate];
        id editorContainer = ((id (*)(id, SEL))objc_msgSend)(appDelegate,
            NSSelectorFromString(@"activeEditorContainer"));
        if (editorContainer) {
            SEL loadSel = NSSelectorFromString(@"loadEditorForSequence:");
            if ([editorContainer respondsToSelector:loadSel]) {
                ((void (*)(id, SEL, id))objc_msgSend)(editorContainer, loadSel, userSequence);
                SpliceKit_log(@"[Captions] loadEditorForSequence: called for '%@'", userSequenceName);
            }
        }
    });

    // Wait for user's timeline to become active — match by name since pointer
    // comparison can fail if the object graph was reorganized during import.
    BOOL userReady = SpliceKitCaption_pollMainThread(^{
        id tm = SpliceKit_getActiveTimelineModule();
        if (!tm) return NO;
        id seq = ((id (*)(id, SEL))objc_msgSend)(tm, NSSelectorFromString(@"sequence"));
        if (!seq) return NO;
        NSString *name = ((id (*)(id, SEL))objc_msgSend)(seq, NSSelectorFromString(@"displayName"));
        // Match by name AND verify it's NOT the temp project
        return (BOOL)(name && [name isEqualToString:userSequenceName]
                      && ![name hasPrefix:kCaptionImportProjectPrefix]);
    }, 5.0, 0.3);

    if (!userReady) {
        SpliceKit_log(@"[Captions] ERROR: failed to switch back to user project '%@'", userSequenceName);
        // Don't paste on wrong timeline — abort gracefully
        SpliceKit_executeOnMainThread(^{
            if (tempSeq) SpliceKitCaption_deleteSequence(tempSeq);
        });
        return @{@"error": [NSString stringWithFormat:
            @"Failed to switch back to project '%@' — captions imported but not pasted. "
            @"Use timeline_action('undo') or navigate back to your project manually.",
            userSequenceName],
                 @"insertedCount": @(0),
                 @"fcpxmlPath": xmlPath};
    }
    SpliceKit_log(@"[Captions] Switched back to user project '%@'", userSequenceName);
    [NSThread sleepForTimeInterval:0.5];

    // Seek playhead to time 0 via direct ObjC call (not responder chain which can miss).
    // Captions must paste at the start so their offsets align with the original timeline.
    SpliceKit_executeOnMainThread(^{
        id tm = SpliceKit_getActiveTimelineModule();
        if (tm) {
            SpliceKitCaption_CMTime zeroTime = {0, 600, 1, 0}; // 0s, valid
            SEL setSel = NSSelectorFromString(@"setPlayheadTime:");
            if ([tm respondsToSelector:setSel]) {
                ((void (*)(id, SEL, SpliceKitCaption_CMTime))objc_msgSend)(tm, setSel, zeroTime);
                SpliceKit_log(@"[Captions] Playhead set to 0s via setPlayheadTime:");
            } else {
                // Fallback to responder chain
                [[NSApplication sharedApplication] sendAction:NSSelectorFromString(@"goToBeginning:")
                                                           to:nil from:nil];
                SpliceKit_log(@"[Captions] Playhead set via goToBeginning: fallback");
            }
        }
    });
    [NSThread sleepForTimeInterval:0.2];

    // Deselect all first — pasteAnchored: with a selection can cause unexpected behavior
    SpliceKit_executeOnMainThread(^{
        [[NSApplication sharedApplication] sendAction:NSSelectorFromString(@"deselectAll:")
                                                   to:nil from:nil];
    });
    [NSThread sleepForTimeInterval:0.1];

    // Paste as connected — creates a connected storyline on the user's timeline
    __block BOOL pasteHandled = NO;
    SpliceKit_executeOnMainThread(^{
        pasteHandled = [[NSApplication sharedApplication]
            sendAction:NSSelectorFromString(@"pasteAnchored:")
                    to:nil from:nil];
    });
    [NSThread sleepForTimeInterval:0.3];

    SpliceKit_log(@"[Captions] Paste as connected: %@", pasteHandled ? @"handled" : @"not handled");

    // ---------------------------------------------------------------
    // Step 5: Apply position offset and self-verify text on pasted titles.
    // Position is applied via FFCutawayEffects transform (not FCPXML
    // adjust-transform which compounds with the .moti internal offset).
    // ---------------------------------------------------------------
    [NSThread sleepForTimeInterval:0.3]; // Let FCP process the paste
    __block NSString *verifiedText = nil;
    __block double verifiedFontSize = 0;
    __block NSString *verifiedFontFamily = nil;
    __block int verifiedTitleCount = 0;
    __block int positionAppliedCount = 0;
    CGFloat yOffset = [self yOffsetForPosition];
    // Word-progress mode sets position via FCPXML Content Position param.
    // Only apply the ObjC runtime transform for standard (Caption Large) mode,
    // otherwise the two position systems compound and produce insane values.
    BOOL needsPosition = !useWordProgress
        && (s.position != SpliceKitCaptionPositionCenter || s.customYOffset != 0);

    if (pasteHandled) {
        SpliceKit_executeOnMainThread(^{
            @try {
                id tm = SpliceKit_getActiveTimelineModule();
                if (!tm) return;
                id seq = ((id (*)(id, SEL))objc_msgSend)(tm, NSSelectorFromString(@"sequence"));
                if (!seq) return;
                id primary = ((id (*)(id, SEL))objc_msgSend)(seq, NSSelectorFromString(@"primaryObject"));
                if (!primary) return;
                NSArray *items = ((id (*)(id, SEL))objc_msgSend)(primary, NSSelectorFromString(@"containedItems"));
                if (![items isKindOfClass:[NSArray class]]) return;

                // Walk connected titles: apply position and verify first one
                // anchoredItems returns NSSet, not NSArray
                for (id item in items) {
                    SEL anchoredSel = NSSelectorFromString(@"anchoredItems");
                    if (![item respondsToSelector:anchoredSel]) continue;
                    id anchoredRaw = ((id (*)(id, SEL))objc_msgSend)(item, anchoredSel);
                    NSArray *anchored = nil;
                    if ([anchoredRaw isKindOfClass:[NSSet class]])
                        anchored = [(NSSet *)anchoredRaw allObjects];
                    else if ([anchoredRaw isKindOfClass:[NSArray class]])
                        anchored = anchoredRaw;
                    if (!anchored || anchored.count == 0) continue;

                    for (id conn in anchored) {
                        verifiedTitleCount++;

                        // Apply position offset to each connected title
                        if (needsPosition) {
                            if (SpliceKitCaption_applyTransformToTitle(conn, yOffset, 100.0))
                                positionAppliedCount++;
                        }

                        // Only deeply inspect first title for verification
                        if (verifiedText) continue;

                        // Motion titles store text on conn.effect.channelFolder,
                        // not on effectStack.visibleEffects (which is empty for generators).
                        id cf = nil;
                        @try {
                            SEL effectSel = NSSelectorFromString(@"effect");
                            id genEffect = [conn respondsToSelector:effectSel]
                                ? ((id (*)(id, SEL))objc_msgSend)(conn, effectSel) : nil;
                            if (genEffect) {
                                SEL cfSel = NSSelectorFromString(@"channelFolder");
                                cf = [genEffect respondsToSelector:cfSel]
                                    ? ((id (*)(id, SEL))objc_msgSend)(genEffect, cfSel) : nil;
                            }
                        } @catch (NSException *e) {}
                        if (!cf) continue;
                        {

                            // Recursively find CHChannelText
                            Class chTextClass = objc_getClass("CHChannelText");
                            NSMutableArray *stack = [NSMutableArray arrayWithObject:cf];
                            while (stack.count > 0 && !verifiedText) {
                                id node = stack.lastObject;
                                [stack removeLastObject];
                                if (chTextClass && [node isKindOfClass:chTextClass]) {
                                    SEL strSel = NSSelectorFromString(@"string");
                                    if ([node respondsToSelector:strSel]) {
                                        id str = ((id (*)(id, SEL))objc_msgSend)(node, strSel);
                                        if (str) verifiedText = [str description];
                                    }
                                    SEL asSel = NSSelectorFromString(@"attributedString");
                                    if ([node respondsToSelector:asSel]) {
                                        NSAttributedString *attrStr = ((id (*)(id, SEL))objc_msgSend)(node, asSel);
                                        if (attrStr && attrStr.length > 0) {
                                            NSDictionary *attrs = [attrStr attributesAtIndex:0 effectiveRange:NULL];
                                            NSFont *font = attrs[NSFontAttributeName];
                                            if (font) {
                                                verifiedFontSize = font.pointSize;
                                                verifiedFontFamily = font.familyName;
                                            }
                                        }
                                    }
                                }
                                SEL childSel = NSSelectorFromString(@"children");
                                if ([node respondsToSelector:childSel]) {
                                    NSArray *ch = ((id (*)(id, SEL))objc_msgSend)(node, childSel);
                                    if ([ch isKindOfClass:[NSArray class]])
                                        [stack addObjectsFromArray:ch];
                                }
                            }
                        }
                    }
                }
            } @catch (NSException *e) {
                SpliceKit_log(@"[Captions] Verification/position exception: %@", e.reason);
            }
        });
    }

    SpliceKit_log(@"[Captions] Verified: %d connected titles, first text='%@', fontSize=%.1f, font='%@', position applied=%d",
                  verifiedTitleCount, verifiedText ?: @"(none)", verifiedFontSize,
                  verifiedFontFamily ?: @"(unknown)", positionAppliedCount);

    // ---------------------------------------------------------------
    // Step 6: Clean up — delete the temp project from the library.
    // ---------------------------------------------------------------
    SpliceKit_executeOnMainThread(^{
        if (tempSeq) {
            SpliceKitCaption_deleteSequence(tempSeq);
            SpliceKit_log(@"[Captions] Deleted temp project");
        }
    });

    NSMutableDictionary *result = [@{
        @"status": @"ok",
        @"insertedCount": @(titleCount),
        @"fcpxmlPath": xmlPath,
        @"pasteHandled": @(pasteHandled),
        @"message": [NSString stringWithFormat:@"Added %d captions to timeline", titleCount],
    } mutableCopy];

    if (!pasteHandled) {
        result[@"warning"] = @"pasteAsConnected was not handled — captions may not be on timeline";
    }

    // Position results
    if (needsPosition && positionAppliedCount > 0) {
        result[@"positionApplied"] = @(positionAppliedCount);
        result[@"positionY"] = @(yOffset);
    }

    // Self-verification results
    if (verifiedText) {
        result[@"verification"] = @{
            @"text": verifiedText,
            @"fontSize": @(verifiedFontSize),
            @"fontFamily": verifiedFontFamily ?: @"unknown",
            @"connectedTitleCount": @(verifiedTitleCount),
        };
        // Flag font size mismatch
        if (verifiedFontSize > 0 && fabs(verifiedFontSize - s.fontSize) > 1.0) {
            result[@"verificationWarning"] = [NSString stringWithFormat:
                @"Font size mismatch: expected %.0f, got %.1f", s.fontSize, verifiedFontSize];
        }
    } else if (pasteHandled) {
        result[@"verificationWarning"] = @"Could not read text from pasted titles — "
            @"titles may not have loaded yet or may not have text channels";
    }

    return result;
}

- (NSString *)textStyleXMLWithID:(NSString *)tsID color:(NSColor *)color isHighlight:(BOOL)highlight {
    SpliceKitCaptionStyle *s = self.style;
    NSMutableString *xml = [NSMutableString string];
    [xml appendFormat:@"<text-style-def id=\"%@\"><text-style", tsID];

    // FCPXML requires font FAMILY names (e.g. "Futura"), not PostScript names ("Futura-Bold").
    // Using PostScript names causes FCP to fall back to Helvetica 6.0 defaults.
    // Resolve the family name from NSFont.
    NSString *fontName = s.font ?: @"Helvetica";
    NSFont *resolvedFont = [NSFont fontWithName:fontName size:s.fontSize];
    NSString *familyName = resolvedFont ? resolvedFont.familyName : fontName;
    // Strip any face suffix that might remain (e.g. "Futura-Bold" → "Futura")
    if ([familyName containsString:@"-"]) {
        familyName = [familyName componentsSeparatedByString:@"-"].firstObject;
    }

    [xml appendFormat:@" font=\"%@\"", SpliceKitCaption_escapeXML(familyName)];
    [xml appendFormat:@" fontSize=\"%.0f\"", s.fontSize];
    [xml appendFormat:@" fontColor=\"%@\"", SpliceKitCaption_colorToFCPXML(color)];
    [xml appendString:@" alignment=\"center\""];
    [xml appendString:@"/></text-style-def>"];
    return xml;
}

- (CGFloat)yOffsetForPosition {
    switch (self.style.position) {
        case SpliceKitCaptionPositionBottom: return -(self.videoHeight * 0.32);
        case SpliceKitCaptionPositionCenter: return 0;
        case SpliceKitCaptionPositionTop: return (self.videoHeight * 0.32);
        case SpliceKitCaptionPositionCustom: return self.style.customYOffset;
    }
    return -(self.videoHeight * 0.32);
}

- (NSString *)animationXMLForSegmentDuration:(double)segDur isFirstWord:(BOOL)isFirst isLastWord:(BOOL)isLast {
    return @"";
}

#pragma mark - Word-Progress Caption Generation (mCaptions-style)

// Compute Custom Speed keyframe XML for a segment's words.
// Progress = (i+1)/N, capped at 0.999. Hold keyframes during inter-word gaps.
- (NSString *)wordProgressKeyframesForSegment:(SpliceKitCaptionSegment *)seg {
    NSUInteger N = seg.words.count;
    if (N == 0) return @"";
    int fdN = self.fdNum, fdD = self.fdDen;
    NSMutableString *kf = [NSMutableString string];
    [kf appendString:@"<keyframeAnimation>\n"];

    // Initial keyframe at segment start
    [kf appendFormat:@"                                            "
        @"<keyframe time=\"%@\" value=\"0\" curve=\"linear\"/>\n",
        SpliceKitCaption_durRational(seg.startTime, fdN, fdD)];

    for (NSUInteger i = 0; i < N; i++) {
        SpliceKitTranscriptWord *w = seg.words[i];
        double progress = (i == N - 1) ? 0.999
            : MIN(floor((double)(i + 1) / (double)N * 1000.0) / 1000.0, 0.999);

        // Jump to this word's progress at word start
        [kf appendFormat:@"                                            "
            @"<keyframe time=\"%@\" value=\"%.3f\" curve=\"linear\"/>\n",
            SpliceKitCaption_durRational(w.startTime, fdN, fdD), progress];

        // Hold during silence gap before next word
        if (i < N - 1 && seg.words[i + 1].startTime - w.endTime > 0.01) {
            [kf appendFormat:@"                                            "
                @"<keyframe time=\"%@\" value=\"%.3f\" curve=\"linear\"/>\n",
                SpliceKitCaption_durRational(w.endTime, fdN, fdD), progress];
        }
    }
    [kf appendString:@"                                        </keyframeAnimation>"];
    return kf;
}

// Build base64 JSON blob with per-word timing data (mCaptions format).
- (NSString *)wordProgressBase64ForSegment:(SpliceKitCaptionSegment *)seg {
    SpliceKitCaptionStyle *s = self.style;
    NSUInteger N = seg.words.count;
    if (N == 0) return @"";
    int fdN = self.fdNum, fdD = self.fdDen;

    NSMutableArray *wordDicts = [NSMutableArray arrayWithCapacity:N];
    for (NSUInteger i = 0; i < N; i++) {
        SpliceKitTranscriptWord *w = seg.words[i];
        double pct = (i == N - 1) ? 0.999
            : MIN(floor((double)(i + 1) / (double)N * 1000.0) / 1000.0, 0.999);
        [wordDicts addObject:@{
            @"Text": w.text ?: @"",
            @"StartTime": SpliceKitCaption_durRational(w.startTime, fdN, fdD),
            @"EndTime": SpliceKitCaption_durRational(w.endTime, fdN, fdD),
            @"RawStartTime": [NSString stringWithFormat:@"%d/100s", (int)round(w.startTime * 100)],
            @"RawEndTime": [NSString stringWithFormat:@"%d/100s", (int)round(w.endTime * 100)],
            @"Percent": [NSString stringWithFormat:@"%.6f", pct],
            @"Data": @{@"DashedWord": @"0", @"LastWordInSentence": @"0"},
        }];
    }

    NSString *fontName = s.font ?: @"Helvetica";
    NSFont *f = [NSFont fontWithName:fontName size:s.fontSize];
    NSString *family = f ? f.familyName : fontName;
    if ([family containsString:@"-"]) family = [family componentsSeparatedByString:@"-"].firstObject;

    NSDictionary *blob = @{
        @"Version": @1, @"Type": @"1", @"Language": @"english",
        @"StartTime": SpliceKitCaption_durRational(seg.startTime, fdN, fdD),
        @"Words": wordDicts,
        @"Style": @{
            @"TextSize": @((int)s.fontSize), @"FontFamily": family,
            @"FontName": fontName, @"FontFace": s.fontFace ?: @"Regular",
            @"FillColor": SpliceKitCaption_colorToFCPXML(s.textColor),
            @"StrokeColor": s.outlineColor ? SpliceKitCaption_colorToFCPXML(s.outlineColor) : @"",
            @"WordByWord": @YES, @"TemplateName": kWP_TemplateName,
            @"PositionY": @(-35), @"LineCount": @1, @"TextWidth": @0.6,
            @"Uppercase": @(s.allCaps), @"Lowercase": @NO,
            @"AnimationIn": @YES, @"AnimationOut": @YES, @"HidePunctuation": @NO,
        },
        @"Id": [NSString stringWithFormat:@"%.0f.%u",
                [[NSDate date] timeIntervalSince1970] * 1000, arc4random() % 1000],
    };

    NSData *json = [NSJSONSerialization dataWithJSONObject:blob
                                                  options:NSJSONWritingSortedKeys | NSJSONWritingPrettyPrinted
                                                    error:nil];
    return json ? [json base64EncodedStringWithOptions:0] : @"";
}

// Generate one <title> XML element with word-progress params.
// Only emits the 3 params mCaptions actually sets (Position, Opacity, Custom Speed).
// All other behavior params (Animate=Word, highlight colors, etc.) are template defaults.
- (NSString *)wordProgressTitleXMLForSegment:(SpliceKitCaptionSegment *)seg
                                   tsCounter:(int *)tsCounter
                                      indent:(NSString *)indent
                                        lane:(NSString *)lane {
    SpliceKitCaptionStyle *s = self.style;
    int fdN = self.fdNum, fdD = self.fdDen;
    double segDur = MAX(seg.duration, 0.1);
    NSString *text = s.allCaps ? [seg.text uppercaseString] : seg.text;
    NSString *offsetStr = SpliceKitCaption_durRational(seg.startTime, fdN, fdD);
    NSString *durStr = SpliceKitCaption_durRational(segDur, fdN, fdD);

    // Position Y from moti height mapping (mCaptions uses motiHeight * posY / 100)
    CGFloat posY = -756;  // default lower-third position matching mCaptions
    if (self.style.position == SpliceKitCaptionPositionCenter) posY = 0;
    else if (self.style.position == SpliceKitCaptionPositionTop) posY = 756;
    else if (self.style.position == SpliceKitCaptionPositionCustom) posY = self.style.customYOffset;

    // Resolve font
    NSString *fontName = s.font ?: @"Helvetica";
    NSFont *resolvedFont = [NSFont fontWithName:fontName size:s.fontSize];
    NSString *familyName = resolvedFont ? resolvedFont.familyName : fontName;
    if ([familyName containsString:@"-"]) familyName = [familyName componentsSeparatedByString:@"-"].firstObject;
    NSString *fontFace = s.fontFace ?: @"Regular";
    NSString *fontColorStr = SpliceKitCaption_colorToFCPXML(s.textColor);

    // Highlight color for strokeColor (template uses it for the glow effect)
    NSColor *hilite = s.highlightColor ?: [NSColor yellowColor];
    NSString *hiliteStr = SpliceKitCaption_colorToFCPXML(hilite);

    // Text style IDs
    int base = (*tsCounter);
    NSString *tsVis = [NSString stringWithFormat:@"ts%d", base];
    NSString *tsPunct = [NSString stringWithFormat:@"ts%d", base + 1];
    NSString *tsHidden = [NSString stringWithFormat:@"ts%d", base + 2];
    *tsCounter = base + 3;

    // Split trailing punctuation
    NSString *mainText = text, *punctText = @"";
    if (text.length > 1) {
        unichar last = [text characterAtIndex:text.length - 1];
        if (last == '.' || last == ',' || last == '!' || last == '?' || last == ';' || last == ':') {
            mainText = [text substringToIndex:text.length - 1];
            punctText = [text substringFromIndex:text.length - 1];
        }
    }

    // Keyframes and blob
    NSString *kfXML = [self wordProgressKeyframesForSegment:seg];
    NSString *b64 = [self wordProgressBase64ForSegment:seg];

    // Fade-out times
    double fadeStart = MAX(seg.endTime - kWP_FadeOutDuration, seg.startTime);
    NSString *fadeStartStr = SpliceKitCaption_durRational(fadeStart, fdN, fdD);
    NSString *fadeEndStr = SpliceKitCaption_durRational(seg.endTime, fdN, fdD);

    NSMutableString *xml = [NSMutableString string];
    NSString *laneAttr = lane ? [NSString stringWithFormat:@" lane=\"%@\"", lane] : @"";

    // <title> — use start="3600s" (FCP standard for Motion titles)
    [xml appendFormat:@"%@<title ref=\"r2\"%@ offset=\"%@\" name=\"%@\" duration=\"%@\" start=\"3600s\">\n",
        indent, laneAttr, offsetStr, SpliceKitCaption_escapeXML(text), durStr];

    // Param 1: Content Position (in Motion template coordinate space)
    [xml appendFormat:@"%@    <param name=\"Content Position\" key=\"%@\" value=\"0 %.0f\"/>\n",
        indent, kWP_ContentPositionKey, posY];

    // Param 2: Content Opacity (fade-out at end)
    [xml appendFormat:@"%@    <param name=\"Content Opacity\" key=\"%@\">\n", indent, kWP_ContentOpacityKey];
    [xml appendFormat:@"%@        <keyframeAnimation>\n", indent];
    [xml appendFormat:@"%@            <keyframe time=\"%@\" value=\"1\" curve=\"linear\"/>\n", indent, fadeStartStr];
    [xml appendFormat:@"%@            <keyframe time=\"%@\" value=\"0\" curve=\"linear\"/>\n", indent, fadeEndStr];
    [xml appendFormat:@"%@        </keyframeAnimation>\n", indent];
    [xml appendFormat:@"%@    </param>\n", indent];

    // Param 3: Custom Speed (word-progress keyframes)
    [xml appendFormat:@"%@    <param name=\"Custom Speed\" key=\"%@\">\n", indent, kWP_CustomSpeedKey];
    [xml appendFormat:@"%@        %@\n", indent, kfXML];
    [xml appendFormat:@"%@    </param>\n", indent];

    // Visible text
    [xml appendFormat:@"%@    <text>\n", indent];
    [xml appendFormat:@"%@        <text-style ref=\"%@\">%@</text-style>\n",
        indent, tsVis, SpliceKitCaption_escapeXML(mainText)];
    if (punctText.length > 0) {
        [xml appendFormat:@"%@        <text-style ref=\"%@\">%@</text-style>\n",
            indent, tsPunct, SpliceKitCaption_escapeXML(punctText)];
    }
    [xml appendFormat:@"%@    </text>\n", indent];

    // Hidden text (base64 JSON blob — read back by mCaptions for re-editing)
    if (b64.length > 0) {
        [xml appendFormat:@"%@    <text>\n", indent];
        [xml appendFormat:@"%@        <text-style ref=\"%@\">%@</text-style>\n", indent, tsHidden, b64];
        [xml appendFormat:@"%@    </text>\n", indent];
    }

    // Text style definitions
    [xml appendFormat:@"%@    <text-style-def id=\"%@\">\n", indent, tsVis];
    [xml appendFormat:@"%@        <text-style font=\"%@\" fontSize=\"%.0f\" fontFace=\"%@\" "
        @"fontColor=\"%@\" strokeColor=\"%@\" strokeWidth=\"0\" "
        @"shadowColor=\"0 0 0 0.1947\" kerning=\"-3.2\" alignment=\"center\">\n",
        indent, SpliceKitCaption_escapeXML(familyName), s.fontSize, fontFace, fontColorStr, hiliteStr];
    [xml appendFormat:@"%@            <param name=\"MotionSimpleValues\" key=\"MotionTextStyle:SimpleValues\">\n", indent];
    [xml appendFormat:@"%@                <param name=\"motionTextTracking\" key=\"tracking\" value=\"-3.2\"/>\n", indent];
    [xml appendFormat:@"%@            </param>\n", indent];
    [xml appendFormat:@"%@        </text-style>\n", indent];
    [xml appendFormat:@"%@    </text-style-def>\n", indent];
    if (punctText.length > 0) {
        [xml appendFormat:@"%@    <text-style-def id=\"%@\">\n", indent, tsPunct];
        [xml appendFormat:@"%@        <text-style font=\"%@\" fontSize=\"%.0f\" fontFace=\"%@\" "
            @"fontColor=\"%@\" strokeColor=\"%@\" strokeWidth=\"0\" "
            @"shadowColor=\"0 0 0 0.1947\" alignment=\"center\"/>\n",
            indent, SpliceKitCaption_escapeXML(familyName), s.fontSize, fontFace, fontColorStr, hiliteStr];
        [xml appendFormat:@"%@    </text-style-def>\n", indent];
    }
    if (b64.length > 0) {
        [xml appendFormat:@"%@    <text-style-def id=\"%@\">\n", indent, tsHidden];
        [xml appendFormat:@"%@        <text-style font=\"Saira\" fontSize=\"6\" fontFace=\"Regular\" "
            @"fontColor=\"0.946308 0.946308 1 1\" alignment=\"center\"/>\n", indent];
        [xml appendFormat:@"%@    </text-style-def>\n", indent];
    }

    [xml appendFormat:@"%@</title>\n", indent];
    return xml;
}

#pragma mark - FCPXML Builder Helpers

// Build the FCPXML document skeleton (resources + opening tags).
// Returns the gap anchor's duration string for use in closing tags.
- (NSMutableString *)buildFCPXMLHeader:(NSString *)projectName
                          totalDuration:(double)totalDuration
                              titleCount:(int *)outTitleCount
                              tsCounter:(int *)outTsCounter {
    int fdN = self.fdNum, fdD = self.fdDen;
    NSString *fmtId = @"r1";
    NSString *totalDurStr = SpliceKitCaption_durRational(totalDuration, fdN, fdD);
    NSString *titleEffectId = @"r2";

    NSMutableString *xml = [NSMutableString string];
    [xml appendString:@"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"];
    [xml appendString:@"<!DOCTYPE fcpxml>\n\n"];
    [xml appendString:@"<fcpxml version=\"1.11\">\n"];
    // Drag-compatible FCPXML: <spine> at root level, no library/event/project wrapper.
    // This format is accepted by FCP's proFFPasteboardUTI drag handler and
    // anchorWithPasteboard:, inserting directly as a connected storyline.
    [xml appendString:@"    <resources>\n"];
    [xml appendFormat:@"        <format id=\"%@\" name=\"FFVideoFormat%dx%dp%d\" "
        @"frameDuration=\"%d/%ds\" width=\"%d\" height=\"%d\"/>\n",
        fmtId, self.videoWidth, self.videoHeight, (int)round(self.frameRate),
        fdN, fdD, self.videoWidth, self.videoHeight];
    // Caption Large effect — ~/Titles.localized/ prefix resolves correctly.
    // .../Titles.localized/ does NOT load the Motion template properly (text invisible).
    [xml appendFormat:@"        <effect id=\"r2\" name=\"Caption Large\" "
        @"uid=\"~/Titles.localized/SpliceKit/Caption Large/Caption Large.moti\"/>\n"];
    [xml appendString:@"    </resources>\n"];
    [xml appendString:@"    <spine>\n"];

    *outTitleCount = 0;
    *outTsCounter = 1;
    return xml;
}

- (void)appendFCPXMLFooter:(NSMutableString *)xml {
    // Close spine + fcpxml (drag format — no library/event/project wrapper)
    [xml appendString:@"    </spine>\n"];
    [xml appendString:@"</fcpxml>\n"];
}

// Build word-level FCPXML using mCaptions-style word-progress approach:
// one title per segment with Custom Speed keyframes for word-by-word animation.
// Saved to /tmp for manual import / debugging.
- (NSString *)buildWordLevelFCPXML {
    double totalDuration = 0;
    for (SpliceKitCaptionSegment *seg in self.mutableSegments) {
        if (seg.endTime > totalDuration) totalDuration = seg.endTime;
    }
    totalDuration += 1.0;

    int fdN = self.fdNum, fdD = self.fdDen;
    NSString *totalDurStr = SpliceKitCaption_durRational(totalDuration, fdN, fdD);

    NSMutableString *xml = [NSMutableString string];
    [xml appendString:@"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"];
    [xml appendString:@"<!DOCTYPE fcpxml>\n\n"];
    [xml appendString:@"<fcpxml version=\"1.14\">\n"];
    [xml appendString:@"    <resources>\n"];
    [xml appendFormat:@"        <format id=\"r1\" name=\"FFVideoFormat%dx%dp%d\" "
        @"frameDuration=\"%d/%ds\" width=\"%d\" height=\"%d\"/>\n",
        self.videoWidth, self.videoHeight, (int)round(self.frameRate),
        fdN, fdD, self.videoWidth, self.videoHeight];
    [xml appendFormat:@"        <effect id=\"r2\" name=\"%@\" uid=\"%@\"/>\n",
        kWP_TemplateName, kWP_TemplateUID];
    [xml appendString:@"    </resources>\n"];
    [xml appendString:@"    <spine>\n"];

    int tsCounter = 1, titleCount = 0;
    for (SpliceKitCaptionSegment *seg in self.mutableSegments) {
        [xml appendString:[self wordProgressTitleXMLForSegment:seg
                                                    tsCounter:&tsCounter
                                                       indent:@"        "
                                                         lane:nil]];
        titleCount++;
    }

    [xml appendString:@"    </spine>\n"];
    [xml appendString:@"</fcpxml>\n"];

    SpliceKit_log(@"[Captions] Built word-progress FCPXML: %d titles, %lu bytes",
                  titleCount, (unsigned long)xml.length);
    return xml;
}

#pragma mark - Import Pipeline (polling-based)

// Poll a condition on the main thread. Blocks the calling (background) thread.
// Returns YES if condition became true before timeout, NO on timeout.
- (NSDictionary *)generateCaptions {
    SpliceKit_log(@"[Captions] generateCaptions called. Words: %lu, Segments: %lu",
                  (unsigned long)self.mutableWords.count, (unsigned long)self.mutableSegments.count);

    if (self.mutableWords.count == 0) {
        self.status = SpliceKitCaptionStatusError;
        self.errorMessage = @"No words — transcribe the timeline first";
        self.lastGenerateResult = @{@"status": @"error", @"error": self.errorMessage};
        return @{@"error": @"No words — transcribe the timeline first"};
    }

    self.status = SpliceKitCaptionStatusGenerating;
    self.errorMessage = nil;
    self.lastGenerateResult = nil;
    if (self.panel) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.statusLabel.stringValue = @"Generating captions...";
            self.generateButton.enabled = NO;
        });
    }

    [self regroupSegments];
    if (self.mutableSegments.count == 0) {
        self.status = SpliceKitCaptionStatusError;
        self.errorMessage = @"No segments after grouping — check word timings";
        self.lastGenerateResult = @{@"status": @"error", @"error": self.errorMessage};
        return @{@"error": @"No segments after grouping — check word timings"};
    }
    [self detectTimelineProperties];

    SpliceKitCaptionStyle *s = self.style;
    int fdN = self.fdNum, fdD = self.fdDen;
    CGFloat yOffset = [self yOffsetForPosition];

    double totalDuration = 0;
    for (SpliceKitCaptionSegment *seg in self.mutableSegments) {
        if (seg.endTime > totalDuration) totalDuration = seg.endTime;
    }
    totalDuration += 1.0;

    // ---------------------------------------------------------------
    // Generate SEGMENT-LEVEL FCPXML for export/debug (one title per segment).
    // Timeline insertion uses anchorWithPasteboard, not FCPXML import.
    // ---------------------------------------------------------------
    int titleCount = 0, tsCounter = 1;
    NSMutableString *xml = [self buildFCPXMLHeader:@"SpliceKit Captions"
                                     totalDuration:totalDuration
                                        titleCount:&titleCount
                                         tsCounter:&tsCounter];

    // Flat spine with sequential titles + gap spacers.
    // This is the format mCaptions uses and that FCP's drag handler accepts.
    // No gap containers, no lanes — just titles directly in the spine.
    double currentTime = 0;

    for (SpliceKitCaptionSegment *seg in self.mutableSegments) {
        double segDur = seg.duration;
        if (segDur <= 0) segDur = 0.1;

        // Insert spacer gap before this segment if there's a time gap
        double gapBefore = seg.startTime - currentTime;
        if (gapBefore > 0.01) {
            NSString *gapDur = SpliceKitCaption_durRational(gapBefore, fdN, fdD);
            [xml appendFormat:@"        <gap name=\"S\" duration=\"%@\" start=\"0s\"/>\n", gapDur];
        }

        NSColor *segColor = (s.wordByWordHighlight && s.highlightColor) ? s.highlightColor : s.textColor;
        NSString *tsID = [NSString stringWithFormat:@"ts%d", tsCounter++];
        NSString *tsDef = [self textStyleXMLWithID:tsID color:segColor isHighlight:(s.wordByWordHighlight && s.highlightColor != nil)];
        NSString *text = s.allCaps ? [seg.text uppercaseString] : seg.text;
        NSString *durStr = SpliceKitCaption_durRational(segDur, fdN, fdD);

        [xml appendFormat:@"        <title ref=\"r2\" name=\"Cap%03lu\" duration=\"%@\" start=\"3600s\">\n",
            (unsigned long)seg.segmentIndex + 1, durStr];
        [xml appendFormat:@"            <text><text-style ref=\"%@\">%@</text-style></text>\n",
            tsID, SpliceKitCaption_escapeXML(text)];
        [xml appendFormat:@"            %@\n", tsDef];
        [xml appendFormat:@"            <adjust-transform position=\"0 %.0f\"/>\n", yOffset];
        [xml appendString:@"        </title>\n"];
        titleCount++;
        currentTime = seg.startTime + segDur;
    }

    [self appendFCPXMLFooter:xml];

    // Save segment-level FCPXML
    NSString *xmlPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"splicekit_captions.fcpxml"];
    [xml writeToFile:xmlPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    SpliceKit_log(@"[Captions] Generated segment-level FCPXML: %d titles → %@", titleCount, xmlPath);

    // Also save word-level FCPXML to disk if highlight mode is on (for future use / manual import)
    NSString *wordLevelPath = nil;
    if (s.wordByWordHighlight && s.highlightColor) {
        wordLevelPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"splicekit_captions_wordlevel.fcpxml"];
        NSString *wordXml = [self buildWordLevelFCPXML];
        if (wordXml) {
            [wordXml writeToFile:wordLevelPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
            SpliceKit_log(@"[Captions] Word-level FCPXML saved to %@", wordLevelPath);
        }
    }

    // Store segment-level FCPXML for export/debug
    self.generatedFCPXML = xml;

    NSDictionary *directResult = [self addCaptionTitlesDirectlyToTimeline];
    BOOL directOK = (directResult[@"error"] == nil);
    NSUInteger insertedCount = directResult[@"insertedCount"]
        ? [directResult[@"insertedCount"] unsignedIntegerValue]
        : 0;
    NSString *statusMsg = directOK
        ? (insertedCount == (NSUInteger)titleCount
            ? [NSString stringWithFormat:@"Added %lu captions to timeline", (unsigned long)insertedCount]
            : [NSString stringWithFormat:@"Added %lu of %d captions to timeline",
                (unsigned long)insertedCount, titleCount])
        : [NSString stringWithFormat:@"Caption insert failed — FCPXML exported to %@", xmlPath];
    self.status = directOK ? SpliceKitCaptionStatusReady : SpliceKitCaptionStatusError;
    self.errorMessage = directOK ? nil : (directResult[@"error"] ?: @"Caption insert failed");
    dispatch_async(dispatch_get_main_queue(), ^{
        [self updateUIAfterGenerate:directOK message:statusMsg];
    });

    SpliceKit_log(@"[Captions] Direct insert result: %@", directResult);

    [[NSNotificationCenter defaultCenter] postNotificationName:SpliceKitCaptionDidGenerateNotification object:self];

    NSMutableDictionary *result = [@{
        @"status": directOK ? @"ok" : @"error",
        @"titleCount": @(titleCount),
        @"segmentCount": @(self.mutableSegments.count),
        @"wordCount": @(self.mutableWords.count),
        @"fcpxmlPath": xmlPath,
        @"message": statusMsg,
        @"importMethod": directOK ? @"directRuntime" : @"fcpxmlFallback",
    } mutableCopy];
    if (wordLevelPath) result[@"wordLevelFcpxmlPath"] = wordLevelPath;
    if (directResult[@"insertedCount"]) result[@"insertedCount"] = directResult[@"insertedCount"];
    if (directResult[@"warnings"]) result[@"warnings"] = directResult[@"warnings"];
    if (directResult[@"warning"]) result[@"warning"] = directResult[@"warning"];
    if (directResult[@"verification"]) result[@"verification"] = directResult[@"verification"];
    if (directResult[@"verificationWarning"]) result[@"verificationWarning"] = directResult[@"verificationWarning"];
    if (directResult[@"pasteHandled"]) result[@"pasteHandled"] = directResult[@"pasteHandled"];
    if (directResult[@"positionApplied"]) result[@"positionApplied"] = directResult[@"positionApplied"];
    if (directResult[@"positionY"]) result[@"positionY"] = directResult[@"positionY"];
    if (!directOK && directResult[@"error"]) result[@"error"] = directResult[@"error"];
    self.lastGenerateResult = [result copy];
    return result;
}

- (void)updateUIAfterGenerate:(BOOL)success message:(NSString *)message {
    if (!self.panel) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        self.generateButton.enabled = YES;
        self.statusLabel.stringValue = message ?: @"Done";
    });
}

#pragma mark - Native Caption Generation (FFAnchoredCaption)

// Generates FCPXML with <caption> elements (FCP's native subtitle objects)
// and imports it via FFXMLTranslationTask. The importer's addCaption:toObject:
// creates FFAnchoredCaption objects, anchors them, and resolves lanes.
// This matches the path FCP uses for File > Import > Captions (SRT/ITT).

- (NSDictionary *)generateNativeCaptions:(NSString *)language format:(NSString *)format {
    SpliceKit_log(@"[NativeCaptions] generateNativeCaptions called. Words: %lu, Segments: %lu, lang=%@, fmt=%@",
                  (unsigned long)self.mutableWords.count, (unsigned long)self.mutableSegments.count,
                  language, format);

    if (self.mutableWords.count == 0) {
        return @{@"error": @"No words — transcribe the timeline first"};
    }

    [self regroupSegments];
    if (self.mutableSegments.count == 0) {
        return @{@"error": @"No segments after grouping — check word timings"};
    }
    [self detectTimelineProperties];

    NSString *lang = language ?: @"en";
    NSString *fmt = format ?: @"ITT";
    int fdN = self.fdNum, fdD = self.fdDen;

    // Build FCPXML with <caption> elements — FCP's native subtitle format.
    // The FFXMLImporter.addCaption:toObject: handler creates FFAnchoredCaption
    // objects, sets up roles, anchors to the timeline, and resolves lanes.
    // We import via FFXMLTranslationTask (same as the existing title caption path).

    double totalDuration = 0;
    for (SpliceKitCaptionSegment *seg in self.mutableSegments) {
        if (seg.endTime > totalDuration) totalDuration = seg.endTime;
    }
    totalDuration += 1.0;

    NSString *totalDurStr = SpliceKitCaption_durRational(totalDuration, fdN, fdD);
    NSString *tempName = [NSString stringWithFormat:@"%@ %u",
        kCaptionImportProjectPrefix, (unsigned)(arc4random() % 10000)];

    // Caption role string: "ITT.en" format
    NSString *captionRole = [NSString stringWithFormat:@"ITT.%@", lang];

    NSMutableString *xml = [NSMutableString string];
    [xml appendString:@"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"];
    [xml appendString:@"<!DOCTYPE fcpxml>\n\n"];
    [xml appendString:@"<fcpxml version=\"1.11\">\n"];
    [xml appendString:@"    <resources>\n"];
    [xml appendFormat:@"        <format id=\"r1\" name=\"FFVideoFormat%dx%dp%d\" "
        @"frameDuration=\"%d/%ds\" width=\"%d\" height=\"%d\"/>\n",
        self.videoWidth, self.videoHeight, (int)round(self.frameRate),
        fdN, fdD, self.videoWidth, self.videoHeight];
    [xml appendString:@"    </resources>\n"];
    [xml appendString:@"    <library>\n"];
    [xml appendFormat:@"        <event name=\"SpliceKit Captions\">\n"];
    [xml appendFormat:@"            <project name=\"%@\">\n", tempName];
    [xml appendFormat:@"                <sequence format=\"r1\" duration=\"%@\" "
        @"tcStart=\"0s\" tcFormat=\"NDF\" audioLayout=\"stereo\" audioRate=\"48k\">\n", totalDurStr];
    [xml appendString:@"                    <spine>\n"];
    [xml appendFormat:@"                        <gap name=\"placeholder\" duration=\"%@\" start=\"0s\">\n",
        totalDurStr];

    NSUInteger captionCount = 0;
    for (SpliceKitCaptionSegment *seg in self.mutableSegments) {
        NSString *text = self.style.allCaps ? [seg.text uppercaseString] : seg.text;
        if (text.length == 0) continue;

        NSString *offsetStr = SpliceKitCaption_durRational(seg.startTime, fdN, fdD);
        NSString *durStr = SpliceKitCaption_durRational(MAX(seg.duration, 0.04), fdN, fdD);

        // <caption> uses offset (position in parent), duration, and lane.
        // The role uses "ITT.lang" format. No start= needed (defaults to 0s).
        // Text is plain (no text-style ref needed for simple captions).
        [xml appendFormat:@"                            <caption lane=\"1\" offset=\"%@\" "
            @"name=\"%@\" duration=\"%@\" role=\"%@\">\n",
            offsetStr,
            SpliceKitCaption_escapeXML(text),
            durStr, captionRole];
        [xml appendFormat:@"                                <text>%@</text>\n",
            SpliceKitCaption_escapeXML(text)];
        [xml appendString:@"                            </caption>\n"];
        captionCount++;
    }

    [xml appendString:@"                        </gap>\n"];
    [xml appendString:@"                    </spine>\n"];
    [xml appendString:@"                </sequence>\n"];
    [xml appendString:@"            </project>\n"];
    [xml appendString:@"        </event>\n"];
    [xml appendString:@"    </library>\n"];
    [xml appendString:@"</fcpxml>\n"];

    SpliceKit_log(@"[NativeCaptions] Built FCPXML with %lu <caption> elements, %lu bytes",
                  (unsigned long)captionCount, (unsigned long)xml.length);

    NSString *xmlPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"splicekit_native_captions.fcpxml"];
    [xml writeToFile:xmlPath atomically:YES encoding:NSUTF8StringEncoding error:nil];

    // Import via FFXMLTranslationTask (same path as title captions)
    NSDictionary *importResult = SpliceKit_handlePasteboardImportXML(@{@"xml": xml});
    if (importResult[@"error"]) {
        return @{@"error": [NSString stringWithFormat:@"FCPXML import failed: %@", importResult[@"error"]],
                 @"fcpxmlPath": xmlPath};
    }

    SpliceKit_log(@"[NativeCaptions] Import OK — waiting for temp project");

    // Wait for temp project
    BOOL foundTemp = SpliceKitCaption_pollMainThread(^{
        return (BOOL)(SpliceKitCaption_findSequenceByPrefix(tempName) != nil);
    }, 5.0, 0.3);

    if (!foundTemp) {
        return @{@"error": @"Temp caption project not found after import",
                 @"fcpxmlPath": xmlPath,
                 @"captionCount": @(captionCount)};
    }

    // ---------------------------------------------------------------
    // Load temp project → select all → copy → switch back → paste
    // Same copy/paste approach as the title caption system.
    // ---------------------------------------------------------------
    __block id userSequence = nil;
    __block NSString *userSequenceName = nil;
    SpliceKit_executeOnMainThread(^{
        userSequence = SpliceKitCaption_currentSequence();
        if (userSequence) {
            userSequenceName = ((id (*)(id, SEL))objc_msgSend)(userSequence,
                NSSelectorFromString(@"displayName"));
        }
    });

    __block id tempSeq = nil;
    SpliceKit_executeOnMainThread(^{
        tempSeq = SpliceKitCaption_findSequenceByPrefix(tempName);
        if (!tempSeq) return;

        id appDelegate = [NSApp delegate];
        id editorContainer = ((id (*)(id, SEL))objc_msgSend)(appDelegate,
            NSSelectorFromString(@"activeEditorContainer"));
        if (!editorContainer) return;

        SEL loadSel = NSSelectorFromString(@"loadEditorForSequence:");
        if ([editorContainer respondsToSelector:loadSel]) {
            ((void (*)(id, SEL, id))objc_msgSend)(editorContainer, loadSel, tempSeq);
        }
    });

    // Wait for temp timeline to load
    BOOL tempReady = SpliceKitCaption_pollMainThread(^{
        id seq = SpliceKitCaption_currentSequence();
        if (!seq) return NO;
        NSString *name = ((id (*)(id, SEL))objc_msgSend)(seq, NSSelectorFromString(@"displayName"));
        return [name hasPrefix:tempName];
    }, 5.0, 0.3);

    if (!tempReady) {
        SpliceKitCaption_deleteSequence(tempSeq);
        return @{@"error": @"Failed to load temp caption project",
                 @"fcpxmlPath": xmlPath};
    }

    [NSThread sleepForTimeInterval:0.5];

    // Select all + copy
    SpliceKit_executeOnMainThread(^{
        [NSApp sendAction:NSSelectorFromString(@"selectAll:") to:nil from:nil];
    });
    [NSThread sleepForTimeInterval:0.3];
    SpliceKit_executeOnMainThread(^{
        [NSApp sendAction:NSSelectorFromString(@"copy:") to:nil from:nil];
    });
    [NSThread sleepForTimeInterval:0.3];

    // Switch back to user's project
    SpliceKit_executeOnMainThread(^{
        // Re-verify userSequence is still valid
        if (userSequenceName) {
            for (id seq in SpliceKitCaption_allSequences()) {
                NSString *name = ((id (*)(id, SEL))objc_msgSend)(seq,
                    NSSelectorFromString(@"displayName"));
                if ([name isEqualToString:userSequenceName]) {
                    userSequence = seq;
                    break;
                }
            }
        }

        id appDelegate = [NSApp delegate];
        id editorContainer = ((id (*)(id, SEL))objc_msgSend)(appDelegate,
            NSSelectorFromString(@"activeEditorContainer"));
        if (editorContainer && userSequence) {
            SEL loadSel = NSSelectorFromString(@"loadEditorForSequence:");
            if ([editorContainer respondsToSelector:loadSel]) {
                ((void (*)(id, SEL, id))objc_msgSend)(editorContainer, loadSel, userSequence);
            }
        }
    });

    // Wait for user's project to be active
    SpliceKitCaption_pollMainThread(^{
        id seq = SpliceKitCaption_currentSequence();
        if (!seq) return NO;
        NSString *name = ((id (*)(id, SEL))objc_msgSend)(seq, NSSelectorFromString(@"displayName"));
        return (BOOL)(userSequenceName && [name isEqualToString:userSequenceName]);
    }, 5.0, 0.3);

    [NSThread sleepForTimeInterval:0.5];

    // Paste captions onto user's timeline
    SpliceKit_executeOnMainThread(^{
        [NSApp sendAction:NSSelectorFromString(@"deselectAll:") to:nil from:nil];
    });
    [NSThread sleepForTimeInterval:0.2];
    SpliceKit_executeOnMainThread(^{
        [NSApp sendAction:NSSelectorFromString(@"paste:") to:nil from:nil];
    });
    [NSThread sleepForTimeInterval:0.5];

    // Clean up temp project
    SpliceKit_executeOnMainThread(^{
        id tempToDelete = SpliceKitCaption_findSequenceByPrefix(tempName);
        if (tempToDelete) SpliceKitCaption_deleteSequence(tempToDelete);
    });

    SpliceKit_log(@"[NativeCaptions] Done: %lu captions via FCPXML import+paste", (unsigned long)captionCount);

    return @{
        @"status": @"ok",
        @"captionCount": @(captionCount),
        @"segmentCount": @(self.mutableSegments.count),
        @"wordCount": @(self.mutableWords.count),
        @"language": lang,
        @"format": fmt,
        @"grouping": @[@"words", @"sentence", @"time", @"chars", @"social"][(NSUInteger)MIN(self.groupingMode, 4)],
        @"fcpxmlPath": xmlPath,
        @"method": @"fcpxml_import_paste",
    };
}

#pragma mark - SRT / TXT Export

- (NSDictionary *)exportSRT:(NSString *)outputPath {
    if (self.mutableSegments.count == 0) {
        return @{@"error": @"No segments to export — transcribe first"};
    }

    NSMutableString *srt = [NSMutableString string];
    NSUInteger srtIndex = 1;
    for (NSUInteger i = 0; i < self.mutableSegments.count; i++) {
        SpliceKitCaptionSegment *seg = self.mutableSegments[i];
        NSString *text = self.style.allCaps ? [seg.text uppercaseString] : seg.text;
        // Skip empty segments
        NSString *trimmed = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (trimmed.length == 0) continue;
        [srt appendFormat:@"%lu\n", (unsigned long)srtIndex++];
        [srt appendFormat:@"%@ --> %@\n", [self srtTimestamp:seg.startTime], [self srtTimestamp:seg.endTime]];
        [srt appendFormat:@"%@\n\n", trimmed];
    }

    NSError *err = nil;
    [srt writeToFile:outputPath atomically:YES encoding:NSUTF8StringEncoding error:&err];
    if (err) {
        return @{@"error": [NSString stringWithFormat:@"Write failed: %@", err.localizedDescription]};
    }

    return @{@"status": @"ok", @"path": outputPath, @"segmentCount": @(self.mutableSegments.count)};
}

- (NSDictionary *)exportTXT:(NSString *)outputPath {
    if (self.mutableSegments.count == 0) {
        return @{@"error": @"No segments to export — transcribe first"};
    }

    NSMutableString *txt = [NSMutableString string];
    for (SpliceKitCaptionSegment *seg in self.mutableSegments) {
        NSString *text = self.style.allCaps ? [seg.text uppercaseString] : seg.text;
        [txt appendFormat:@"%@\n", text];
    }

    NSError *err = nil;
    [txt writeToFile:outputPath atomically:YES encoding:NSUTF8StringEncoding error:&err];
    if (err) {
        return @{@"error": [NSString stringWithFormat:@"Write failed: %@", err.localizedDescription]};
    }

    return @{@"status": @"ok", @"path": outputPath, @"segmentCount": @(self.mutableSegments.count)};
}

- (NSString *)srtTimestamp:(double)seconds {
    int h = (int)(seconds / 3600);
    int m = (int)(fmod(seconds, 3600) / 60);
    int s = (int)fmod(seconds, 60);
    int ms = (int)((seconds - floor(seconds)) * 1000);
    return [NSString stringWithFormat:@"%02d:%02d:%02d,%03d", h, m, s, ms];
}

#pragma mark - State

- (NSDictionary *)getState {
    NSMutableDictionary *state = [NSMutableDictionary dictionary];

    switch (self.status) {
        case SpliceKitCaptionStatusIdle: state[@"status"] = @"idle"; break;
        case SpliceKitCaptionStatusTranscribing: state[@"status"] = @"transcribing"; break;
        case SpliceKitCaptionStatusReady: state[@"status"] = @"ready"; break;
        case SpliceKitCaptionStatusGenerating: state[@"status"] = @"generating"; break;
        case SpliceKitCaptionStatusError: state[@"status"] = @"error"; break;
    }

    state[@"wordCount"] = @(self.mutableWords.count);
    state[@"segmentCount"] = @(self.mutableSegments.count);
    state[@"style"] = [self.style toDictionary];

    if (self.errorMessage) state[@"error"] = self.errorMessage;
    if (self.lastGenerateResult) state[@"lastGenerateResult"] = self.lastGenerateResult;

    // Segments
    NSMutableArray *segDicts = [NSMutableArray array];
    for (SpliceKitCaptionSegment *seg in self.mutableSegments) {
        [segDicts addObject:[seg toDictionary]];
    }
    state[@"segments"] = segDicts;

    // Grouping
    state[@"grouping"] = @{
        @"mode": @[@"words", @"sentence", @"time", @"chars", @"social"][(NSUInteger)MIN(self.groupingMode, 4)],
        @"maxWords": @(self.maxWordsPerSegment),
        @"maxChars": @(self.maxCharsPerSegment),
        @"maxSeconds": @(self.maxSecondsPerSegment),
    };

    return state;
}

@end
