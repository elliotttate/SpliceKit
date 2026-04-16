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
//  Transcription is handled directly via the Parakeet engine (no dependency
//  on the Transcript Editor panel).
//

#import "SpliceKitCaptionPanel.h"
#import "SpliceKit.h"
#import "SpliceKitTranscriptDiagnostics.h"
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
static id SpliceKitCaption_currentSequence(void);

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

static double SpliceKitCaption_CMTimeToSeconds(SpliceKitCaption_CMTime t) {
    return (t.timescale > 0) ? (double)t.value / t.timescale : 0;
}

#pragma mark - Word-Progress Template Config (SpliceKit Caption)
//
// The legacy word-progress title export emits only 3 params per title:
// Content Position, Content Opacity (fade-out), and Custom Speed
// (word-progress keyframes). All other params (Animate=Word, Speed=Custom,
// highlight colors, glow, etc.) are baked into the Motion template defaults.
//
// Content Position and Content Opacity key paths are universal (on the Widget's
// Content layer 10003). Custom Speed path depends on the template hierarchy:
//   Content (10003) → Text (10061) → behaviors (4) → SeqText (500001) → Controls (201) → CustomSpeed (209)
//
static NSString * const kWP_ContentPositionKey = @"9999/10003/1/100/101";
static NSString * const kWP_ContentOpacityKey  = @"9999/10003/1/200/202";
// Sequence Text behavior key path captured from the legacy template hierarchy.
// Content(10003) → TextGroup01-03 → Text(10061) → SeqText(3291121706)
static NSString * const kWP_CustomSpeedKey     = @"9999/10003/3336225139/3336225138/3336087544/10061/4/3291121706/201/209";
static NSString * const kSpliceKitRuntimeCaptionTemplateMatch =
    @"Bumper:Opener.localized/Basic Title.localized/Basic Title.moti";
static NSString * const kSpliceKitCaptionStorylineName = @"SpliceKit Storyline";

// The runtime/native insertion path uses FCP's built-in Basic Title template so
// connected titles render on any installation without any external template.

static NSString *SpliceKitLegacyCaptionStorylineName(void) {
    static NSString *name = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        name = [@[ @"m", @"Captions Storyline" ] componentsJoinedByString:@""];
    });
    return name;
}

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

static NSDictionary *SpliceKitCaption_transcriptWordToDictionary(SpliceKitTranscriptWord *word) {
    if (!word) return @{};
    return @{
        @"index": @(word.wordIndex),
        @"text": word.text ?: @"",
        @"startTime": @(word.startTime),
        @"duration": @(word.duration),
        @"endTime": @(word.endTime),
        @"confidence": @(word.confidence),
        @"speaker": word.speaker ?: @"Unknown",
        @"clipHandle": word.clipHandle ?: @"",
        @"clipTimelineStart": @(word.clipTimelineStart),
        @"sourceMediaOffset": @(word.sourceMediaOffset),
        @"sourceMediaTime": @(word.sourceMediaTime),
        @"sourceMediaPath": word.sourceMediaPath ?: @"",
    };
}

static SpliceKitTranscriptWord *SpliceKitCaption_transcriptWordFromDictionary(NSDictionary *dict) {
    if (![dict isKindOfClass:[NSDictionary class]]) return nil;
    SpliceKitTranscriptWord *word = [[SpliceKitTranscriptWord alloc] init];
    word.text = dict[@"text"] ?: @"";
    word.startTime = [dict[@"startTime"] doubleValue];
    word.duration = [dict[@"duration"] doubleValue];
    word.endTime = [dict[@"endTime"] doubleValue];
    if (word.endTime <= word.startTime) word.endTime = word.startTime + word.duration;
    word.confidence = [dict[@"confidence"] doubleValue];
    word.wordIndex = [dict[@"index"] unsignedIntegerValue];
    word.speaker = dict[@"speaker"] ?: @"Unknown";
    word.clipHandle = dict[@"clipHandle"];
    word.clipTimelineStart = [dict[@"clipTimelineStart"] doubleValue];
    word.sourceMediaOffset = [dict[@"sourceMediaOffset"] doubleValue];
    word.sourceMediaTime = [dict[@"sourceMediaTime"] doubleValue];
    word.sourceMediaPath = dict[@"sourceMediaPath"];
    return word;
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
@property (nonatomic, strong) NSProgressIndicator *progressBar;

// Frame rate info (detected from timeline)
@property (nonatomic) int fdNum;   // frame duration numerator
@property (nonatomic) int fdDen;   // frame duration denominator
@property (nonatomic) double frameRate;
@property (nonatomic) int videoWidth;
@property (nonatomic) int videoHeight;
@property (nonatomic) BOOL suppressPersistenceWrites;
@property (nonatomic, copy) NSString *lastRestoredSequenceKey;
@property (nonatomic, copy) NSString *lastHeadlessRestoredSequenceKey;
@property (nonatomic, copy) NSString *lastHealedSequenceKey;
@property (nonatomic, strong) id automaticRestoreObserver;
@property (nonatomic) NSUInteger automaticRestoreGeneration;
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

    if (SpliceKitCaption_usesWordHighlightRuntimeStyle(s)) {
        normalAttrs[NSKernAttributeName] = @(-1.28);
        highlightAttrs[NSKernAttributeName] = @(-1.28);
    }

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
        if (SpliceKitCaption_usesWordHighlightRuntimeStyle(s)) {
            shadow.shadowBlurRadius = 0.97;
            shadow.shadowOffset = NSMakeSize(1.42, -1.42);
        } else {
            shadow.shadowBlurRadius = s.shadowBlurRadius * 0.4;
            shadow.shadowOffset = NSMakeSize(s.shadowOffsetX * 0.4, -s.shadowOffsetY * 0.4);
        }
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

- (void)fontChanged:(id)sender { self.style.font = self.fontPopup.titleOfSelectedItem; [self updatePreview]; [self persistCaptionDraftStateForCurrentSequence]; }
- (void)fontSizeChanged:(id)sender {
    self.style.fontSize = self.fontSizeSlider.doubleValue;
    self.fontSizeField.stringValue = [NSString stringWithFormat:@"%.0f", self.style.fontSize];
    [self updatePreview];
    [self persistCaptionDraftStateForCurrentSequence];
}
- (void)colorChanged:(id)sender {
    self.style.textColor = self.textColorWell.color;
    self.style.highlightColor = self.highlightColorWell.color;
    self.style.outlineColor = self.outlineColorWell.color;
    self.style.shadowColor = self.shadowColorWell.color;
    [self updatePreview];
    [self persistCaptionDraftStateForCurrentSequence];
}
- (void)outlineWidthChanged:(id)sender { self.style.outlineWidth = self.outlineWidthSlider.doubleValue; [self updatePreview]; [self persistCaptionDraftStateForCurrentSequence]; }
- (void)shadowBlurChanged:(id)sender { self.style.shadowBlurRadius = self.shadowBlurSlider.doubleValue; [self updatePreview]; [self persistCaptionDraftStateForCurrentSequence]; }
- (void)positionChanged:(id)sender { self.style.position = (SpliceKitCaptionPosition)self.positionPopup.indexOfSelectedItem; [self persistCaptionDraftStateForCurrentSequence]; }
- (void)animationChanged:(id)sender { self.style.animation = (SpliceKitCaptionAnimation)self.animationPopup.indexOfSelectedItem; [self persistCaptionDraftStateForCurrentSequence]; }
- (void)capsToggled:(id)sender { self.style.allCaps = (self.allCapsCheckbox.state == NSControlStateValueOn); [self updatePreview]; [self persistCaptionDraftStateForCurrentSequence]; }
- (void)highlightToggled:(id)sender { self.style.wordByWordHighlight = (self.wordHighlightCheckbox.state == NSControlStateValueOn); [self updatePreview]; [self persistCaptionDraftStateForCurrentSequence]; }

- (void)groupingChanged:(id)sender {
    self.groupingMode = (SpliceKitCaptionGrouping)self.groupingPopup.indexOfSelectedItem;
    if (self.mutableWords.count > 0) [self regroupSegments];
    [self persistCaptionDraftStateForCurrentSequence];
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
    if (![NSThread isMainThread]) {
        SpliceKit_executeOnMainThread(^{
            [self showPanel];
        });
        return;
    }

    [self setupPanelIfNeeded];
    [self restorePersistedStateForCurrentSequenceIfNeeded];
    [self.panel makeKeyAndOrderFront:nil];

    // Motion title channels are not always ready at the first open tick after
    // relaunch, so repair after the panel is visible and the project is active.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (self.panel.isVisible) {
            [self repairPersistedCaptionsOnCurrentSequenceIfNeeded];
        }
    });
}

- (void)hidePanel {
    if (![NSThread isMainThread]) {
        SpliceKit_executeOnMainThread(^{
            [self hidePanel];
        });
        return;
    }

    [self.panel orderOut:nil];
}

- (BOOL)isVisible {
    return self.panel && self.panel.isVisible;
}

- (void)enableAutomaticRestore {
    if (![NSThread isMainThread]) {
        SpliceKit_executeOnMainThread(^{
            [self enableAutomaticRestore];
        });
        return;
    }

    if (!self.automaticRestoreObserver) {
        __weak typeof(self) weakSelf = self;
        self.automaticRestoreObserver =
            [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowDidBecomeMainNotification
                                                              object:nil
                                                               queue:[NSOperationQueue mainQueue]
                                                          usingBlock:^(__unused NSNotification *note) {
            if (weakSelf.panel.isVisible) {
                [weakSelf scheduleAutomaticRestoreAttemptsWithInitialDelay:0.15];
            }
        }];
    }

    if (self.panel.isVisible) {
        [self scheduleAutomaticRestoreAttemptsWithInitialDelay:0.6];
    }
}

- (void)scheduleAutomaticRestoreAttemptsWithInitialDelay:(NSTimeInterval)initialDelay {
    if (![NSThread isMainThread]) {
        SpliceKit_executeOnMainThread(^{
            [self scheduleAutomaticRestoreAttemptsWithInitialDelay:initialDelay];
        });
        return;
    }

    self.automaticRestoreGeneration += 1;
    NSUInteger generation = self.automaticRestoreGeneration;
    NSArray<NSNumber *> *offsets = @[ @0.0, @0.35, @0.9, @1.8, @3.5, @6.0, @10.0 ];
    __weak typeof(self) weakSelf = self;

    for (NSNumber *offset in offsets) {
        NSTimeInterval delay = initialDelay + offset.doubleValue;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (!weakSelf) return;
            if (weakSelf.automaticRestoreGeneration != generation) return;
            [weakSelf repairPersistedCaptionsOnCurrentSequenceIfNeeded];
        });
    }
}

- (NSDictionary *)captionDraftGroupingDictionary {
    return @{
        @"mode": @[@"words", @"sentence", @"time", @"chars", @"social"][(NSUInteger)MIN(self.groupingMode, 4)],
        @"maxWords": @(self.maxWordsPerSegment),
        @"maxChars": @(self.maxCharsPerSegment),
        @"maxSeconds": @(self.maxSecondsPerSegment),
    };
}

- (NSArray<NSDictionary *> *)runtimeEntriesForStyle:(SpliceKitCaptionStyle *)style {
    SpliceKitCaptionStyle *s = style ?: self.style;
    BOOL useWordHighlightRuntime = (s.wordByWordHighlight && s.highlightColor != nil);
    NSMutableArray<NSDictionary *> *runtimeEntries = [NSMutableArray array];

    for (NSUInteger segIndex = 0; segIndex < self.mutableSegments.count; segIndex++) {
        SpliceKitCaptionSegment *seg = self.mutableSegments[segIndex];
        NSString *segmentText = s.allCaps ? [seg.text uppercaseString] : seg.text;
        NSString *trimmed = [segmentText stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (trimmed.length == 0) continue;

        if (useWordHighlightRuntime && seg.words.count > 0) {
            NSMutableArray<NSString *> *displayWords = [NSMutableArray arrayWithCapacity:seg.words.count];
            for (SpliceKitTranscriptWord *sourceWord in seg.words) {
                NSString *wordText = sourceWord.text ?: @"";
                if (s.allCaps) wordText = [wordText uppercaseString];
                [displayWords addObject:wordText];
            }

            for (NSUInteger wordIndex = 0; wordIndex < seg.words.count; wordIndex++) {
                SpliceKitTranscriptWord *word = seg.words[wordIndex];
                double titleStart = word.startTime;
                double titleEnd = (wordIndex + 1 < seg.words.count) ? seg.words[wordIndex + 1].startTime : seg.endTime;
                double titleDuration = MAX(titleEnd - titleStart, (double)MAX(self.fdNum, 1) / MAX(self.fdDen, 1));
                [runtimeEntries addObject:@{
                    @"segmentIndex": @(segIndex),
                    @"activeWordIndex": @(wordIndex),
                    @"words": displayWords,
                    @"text": trimmed,
                    @"startTime": @(titleStart),
                    @"endTime": @(titleEnd),
                    @"duration": @(titleDuration),
                    @"mode": @"wordHighlight",
                }];
            }
        } else {
            [runtimeEntries addObject:@{
                @"segmentIndex": @(segIndex),
                @"text": trimmed,
                @"startTime": @(seg.startTime),
                @"endTime": @(seg.endTime),
                @"duration": @(MAX(seg.endTime - seg.startTime, seg.duration)),
                @"mode": @"segment",
            }];
        }
    }

    return runtimeEntries;
}

- (NSDictionary *)captionTranscriptPersistenceSection {
    NSMutableArray *wordDicts = [NSMutableArray array];
    @synchronized (self.mutableWords) {
        for (SpliceKitTranscriptWord *word in self.mutableWords) {
            [wordDicts addObject:SpliceKitCaption_transcriptWordToDictionary(word)];
        }
    }
    return @{
        @"status": @"ready",
        @"frameRate": @(self.frameRate),
        @"words": wordDicts,
    };
}

- (void)ensurePersistedStateLoaded {
    if (self.status == SpliceKitCaptionStatusTranscribing ||
        self.status == SpliceKitCaptionStatusGenerating) {
        return;
    }
    if (self.mutableWords.count > 0) return;
    [self restorePersistedStateForCurrentSequenceIfNeeded];
}

- (void)persistCaptionDraftStateForCurrentSequence {
    if (self.suppressPersistenceWrites) return;

    id sequence = SpliceKitCaption_currentSequence();
    if (!sequence) return;

    NSMutableDictionary *state = [[SpliceKit_loadSequenceState(sequence) mutableCopy] ?: [NSMutableDictionary dictionary] mutableCopy];
    NSMutableDictionary *captions = [[state[@"captions"] isKindOfClass:[NSDictionary class]]
        ? [state[@"captions"] mutableCopy]
        : [NSMutableDictionary dictionary] mutableCopy];
    captions[@"draftStyle"] = [self.style toDictionary];
    captions[@"draftGrouping"] = [self captionDraftGroupingDictionary];
    state[@"captions"] = captions;
    if (self.mutableWords.count > 0) {
        state[@"transcript"] = [self captionTranscriptPersistenceSection];
    }

    NSError *error = nil;
    if (!SpliceKit_saveSequenceState(sequence, state, &error) && error) {
        SpliceKit_log(@"[Captions] Failed to persist draft state: %@", error.localizedDescription);
    }
}

- (void)persistGeneratedCaptionStateWithRuntimeEntries:(NSArray<NSDictionary *> *)runtimeEntries
                                                 style:(SpliceKitCaptionStyle *)style {
    if (self.suppressPersistenceWrites || runtimeEntries.count == 0) return;

    id sequence = SpliceKitCaption_currentSequence();
    if (!sequence) return;

    NSMutableDictionary *state = [[SpliceKit_loadSequenceState(sequence) mutableCopy] ?: [NSMutableDictionary dictionary] mutableCopy];
    NSMutableDictionary *captions = [[state[@"captions"] isKindOfClass:[NSDictionary class]]
        ? [state[@"captions"] mutableCopy]
        : [NSMutableDictionary dictionary] mutableCopy];
    captions[@"draftStyle"] = [self.style toDictionary];
    captions[@"draftGrouping"] = [self captionDraftGroupingDictionary];
    captions[@"generatedStyle"] = [(style ?: self.style) toDictionary];
    captions[@"generatedRuntimeEntries"] = runtimeEntries;
    captions[@"generatedStorylineName"] = kSpliceKitCaptionStorylineName;
    captions[@"generatedAt"] = @([[NSDate date] timeIntervalSince1970]);
    state[@"captions"] = captions;
    if (self.mutableWords.count > 0) {
        state[@"transcript"] = [self captionTranscriptPersistenceSection];
    }

    NSError *error = nil;
    if (!SpliceKit_saveSequenceState(sequence, state, &error) && error) {
        SpliceKit_log(@"[Captions] Failed to persist generated caption state: %@", error.localizedDescription);
    }
    self.lastHeadlessRestoredSequenceKey = nil;
    self.lastHealedSequenceKey = nil;
}

- (CGFloat)yOffsetForStyle:(SpliceKitCaptionStyle *)style {
    SpliceKitCaptionStyle *resolvedStyle = style ?: self.style;
    switch (resolvedStyle.position) {
        case SpliceKitCaptionPositionBottom: return -(self.videoHeight * 0.32);
        case SpliceKitCaptionPositionCenter: return 0;
        case SpliceKitCaptionPositionTop: return (self.videoHeight * 0.32);
        case SpliceKitCaptionPositionCustom: return resolvedStyle.customYOffset;
    }
    return 0;
}

#pragma mark - Style Management

- (void)setStyle:(SpliceKitCaptionStyle *)style {
    _style = [style copy];
    if (self.panel) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self syncUIFromStyle];
        });
    }
    if (!self.suppressPersistenceWrites) {
        [self persistCaptionDraftStateForCurrentSequence];
    }
}

- (SpliceKitCaptionStyle *)currentStyle {
    return [self.style copy];
}

#pragma mark - Transcription (Built-in Parakeet)

- (void)transcribeTimeline {
    self.status = SpliceKitCaptionStatusTranscribing;
    dispatch_async(dispatch_get_main_queue(), ^{
        self.spinner.hidden = NO;
        [self.spinner startAnimation:nil];
        self.transcribeButton.enabled = NO;
        self.statusLabel.stringValue = @"Transcribing timeline...";
        if (self.progressBar) {
            self.progressBar.hidden = NO;
            self.progressBar.indeterminate = YES;
            [self.progressBar startAnimation:nil];
        }
    });

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [self performCaptionTranscription];
    });
}

- (void)transcriptionFinishedWithWords:(NSArray<SpliceKitTranscriptWord *> *)words {
    @synchronized (self.mutableWords) {
        [self.mutableWords removeAllObjects];
        [self.mutableWords addObjectsFromArray:words ?: @[]];
        // Sort by start time and assign indices
        [self.mutableWords sortUsingComparator:^NSComparisonResult(SpliceKitTranscriptWord *a, SpliceKitTranscriptWord *b) {
            if (a.startTime < b.startTime) return NSOrderedAscending;
            if (a.startTime > b.startTime) return NSOrderedDescending;
            return NSOrderedSame;
        }];
        for (NSUInteger i = 0; i < self.mutableWords.count; i++) {
            self.mutableWords[i].wordIndex = i;
        }
    }

    self.status = SpliceKitCaptionStatusReady;
    [self regroupSegments];

    dispatch_async(dispatch_get_main_queue(), ^{
        self.spinner.hidden = YES;
        [self.spinner stopAnimation:nil];
        if (self.progressBar) {
            self.progressBar.hidden = YES;
        }
        self.transcribeButton.enabled = YES;
        self.statusLabel.stringValue = [NSString stringWithFormat:@"%lu words, %lu segments",
            (unsigned long)self.mutableWords.count, (unsigned long)self.mutableSegments.count];
    });

    SpliceKit_log(@"[Captions] Transcription complete: %lu words",
                  (unsigned long)self.mutableWords.count);
}

- (void)transcriptionFailedWithError:(NSString *)error {
    self.status = SpliceKitCaptionStatusError;
    self.errorMessage = error;
    dispatch_async(dispatch_get_main_queue(), ^{
        self.spinner.hidden = YES;
        [self.spinner stopAnimation:nil];
        if (self.progressBar) {
            self.progressBar.hidden = YES;
        }
        self.transcribeButton.enabled = YES;
        self.statusLabel.stringValue = [NSString stringWithFormat:@"Error: %@", error];
    });
    SpliceKit_log(@"[Captions] Transcription error: %@", error);
}

#pragma mark - Parakeet Transcription Engine

- (NSString *)parakeetTranscriberPath {
    NSFileManager *fm = [NSFileManager defaultManager];

    // 1. Inside the FCP framework bundle (deployed by patcher)
    NSString *buildDir = [[[NSBundle mainBundle] bundlePath]
        stringByAppendingPathComponent:@"Contents/Frameworks/SpliceKit.framework/Versions/A/Resources"];
    NSString *builtPath = [buildDir stringByAppendingPathComponent:@"parakeet-transcriber"];
    if ([fm fileExistsAtPath:builtPath]) return builtPath;

    // 2. Standard tool locations
    NSString *home = NSHomeDirectory();
    NSArray *searchPaths = @[
        [home stringByAppendingPathComponent:@"Applications/SpliceKit/tools/parakeet-transcriber"],
        [home stringByAppendingPathComponent:@"Library/Application Support/SpliceKit/tools/parakeet-transcriber"],
        [home stringByAppendingPathComponent:@"Library/Caches/SpliceKit/tools/parakeet-transcriber/.build/release/parakeet-transcriber"],
    ];
    for (NSString *path in searchPaths) {
        if ([fm fileExistsAtPath:path]) return path;
    }
    return nil;
}

- (NSURL *)getMediaURLForClip:(id)clip {
    // Chain 1: clip.media.originalMediaURL
    @try {
        if ([clip respondsToSelector:NSSelectorFromString(@"media")]) {
            id media = ((id (*)(id, SEL))objc_msgSend)(clip, NSSelectorFromString(@"media"));
            if (media) {
                SEL omSel = NSSelectorFromString(@"originalMediaURL");
                if ([media respondsToSelector:omSel]) {
                    id url = ((id (*)(id, SEL))objc_msgSend)(media, omSel);
                    if (url && [url isKindOfClass:[NSURL class]]) return url;
                }
                SEL omrSel = NSSelectorFromString(@"originalMediaRep");
                if ([media respondsToSelector:omrSel]) {
                    id rep = ((id (*)(id, SEL))objc_msgSend)(media, omrSel);
                    if (rep) {
                        SEL fuSel = NSSelectorFromString(@"fileURLs");
                        if ([rep respondsToSelector:fuSel]) {
                            id urls = ((id (*)(id, SEL))objc_msgSend)(rep, fuSel);
                            if ([urls isKindOfClass:[NSArray class]] && [(NSArray *)urls count] > 0) {
                                id url = [(NSArray *)urls firstObject];
                                if ([url isKindOfClass:[NSURL class]]) return url;
                            }
                        }
                        SEL urlSel = NSSelectorFromString(@"URL");
                        if ([rep respondsToSelector:urlSel]) {
                            id url = ((id (*)(id, SEL))objc_msgSend)(rep, urlSel);
                            if ([url isKindOfClass:[NSURL class]]) return url;
                        }
                    }
                }
                SEL crSel = NSSelectorFromString(@"currentRep");
                if ([media respondsToSelector:crSel]) {
                    id rep = ((id (*)(id, SEL))objc_msgSend)(media, crSel);
                    if (rep) {
                        SEL fuSel = NSSelectorFromString(@"fileURLs");
                        if ([rep respondsToSelector:fuSel]) {
                            id urls = ((id (*)(id, SEL))objc_msgSend)(rep, fuSel);
                            if ([urls isKindOfClass:[NSArray class]] && [(NSArray *)urls count] > 0) {
                                id url = [(NSArray *)urls firstObject];
                                if ([url isKindOfClass:[NSURL class]]) return url;
                            }
                        }
                    }
                }
            }
        }
    } @catch (NSException *e) {}

    // Chain 2: clip.assetMediaReference -> resolvedURL
    @try {
        SEL amrSel = NSSelectorFromString(@"assetMediaReference");
        if ([clip respondsToSelector:amrSel]) {
            id ref = ((id (*)(id, SEL))objc_msgSend)(clip, amrSel);
            if (ref) {
                SEL ruSel = NSSelectorFromString(@"resolvedURL");
                if ([ref respondsToSelector:ruSel]) {
                    id url = ((id (*)(id, SEL))objc_msgSend)(ref, ruSel);
                    if ([url isKindOfClass:[NSURL class]]) return url;
                }
            }
        }
    } @catch (NSException *e) {}

    // Chain 3: KVC paths
    @try {
        id url = [clip valueForKeyPath:@"media.fileURL"];
        if ([url isKindOfClass:[NSURL class]]) return url;
    } @catch (NSException *e) {}
    @try {
        id url = [clip valueForKeyPath:@"clipInPlace.asset.originalMediaURL"];
        if ([url isKindOfClass:[NSURL class]]) return url;
    } @catch (NSException *e) {}

    return nil;
}

- (void)collectClipsFrom:(NSArray *)items
            primaryObject:(id)primaryObject
               atTimeline:(double *)timelinePos
                     into:(NSMutableArray *)clipInfos {
    for (id item in items) {
        NSString *className = NSStringFromClass([item class]);
        double itemTimelineStart = *timelinePos;

        double clipDuration = 0;
        if ([item respondsToSelector:@selector(duration)]) {
            SpliceKitCaption_CMTime d = ((SpliceKitCaption_CMTime (*)(id, SEL))STRET_MSG)(item, @selector(duration));
            clipDuration = SpliceKitCaption_CMTimeToSeconds(d);
        }

        BOOL isMedia = [className containsString:@"MediaComponent"];
        BOOL isCollection = [className containsString:@"Collection"] || [className containsString:@"AnchoredClip"];
        BOOL isTransition = [className containsString:@"Transition"];

        if (isMedia && clipDuration > 0) {
            [self addTimelineObject:item defaultTimeline:itemTimelineStart primaryObject:primaryObject into:clipInfos];

        } else if (isCollection && clipDuration > 0) {
            [self addTimelineObject:item defaultTimeline:itemTimelineStart primaryObject:primaryObject into:clipInfos];
        }

        for (id anchoredItem in [self anchoredItemsForTimelineItem:item]) {
            [self addTimelineObject:anchoredItem defaultTimeline:itemTimelineStart primaryObject:primaryObject into:clipInfos];
        }

        if (!isTransition) {
            *timelinePos += clipDuration;
        }
    }
}

- (NSArray *)anchoredItemsForTimelineItem:(id)item {
    SEL anchoredSel = NSSelectorFromString(@"anchoredItems");
    if (![item respondsToSelector:anchoredSel]) return @[];

    id anchoredRaw = ((id (*)(id, SEL))objc_msgSend)(item, anchoredSel);
    if ([anchoredRaw isKindOfClass:[NSArray class]]) return anchoredRaw;
    if ([anchoredRaw isKindOfClass:[NSSet class]]) return [(NSSet *)anchoredRaw allObjects];
    return @[];
}

- (BOOL)effectiveRangeForTimelineObject:(id)item
                          primaryObject:(id)primaryObject
                                  start:(double *)startOut
                               duration:(double *)durationOut {
    if (startOut) *startOut = 0;
    if (durationOut) *durationOut = 0;
    if (!item || !primaryObject) return NO;

    SEL rangeSel = NSSelectorFromString(@"effectiveRangeOfObject:");
    if (![primaryObject respondsToSelector:rangeSel]) return NO;

    @try {
        SpliceKitCaption_CMTimeRange range =
            ((SpliceKitCaption_CMTimeRange (*)(id, SEL, id))STRET_MSG)(primaryObject, rangeSel, item);
        double start = SpliceKitCaption_CMTimeToSeconds(range.start);
        double duration = SpliceKitCaption_CMTimeToSeconds(range.duration);
        if (duration <= 0) return NO;
        if (startOut) *startOut = start;
        if (durationOut) *durationOut = duration;
        return YES;
    } @catch (__unused NSException *e) {
        return NO;
    }
}

- (double)anchoredOffsetForTimelineObject:(id)item {
    SEL offsetSel = NSSelectorFromString(@"anchoredOffset");
    if (![item respondsToSelector:offsetSel]) return -1;

    @try {
        SpliceKitCaption_CMTime offset =
            ((SpliceKitCaption_CMTime (*)(id, SEL))STRET_MSG)(item, offsetSel);
        return SpliceKitCaption_CMTimeToSeconds(offset);
    } @catch (__unused NSException *e) {
        return -1;
    }
}

- (void)addTimelineObject:(id)item
          defaultTimeline:(double)defaultTimelinePos
             primaryObject:(id)primaryObject
                      into:(NSMutableArray *)clipInfos {
    if (!item) return;

    NSString *className = NSStringFromClass([item class]) ?: @"";
    BOOL isMedia = [className containsString:@"MediaComponent"];
    BOOL isCollection = [className containsString:@"Collection"] || [className containsString:@"AnchoredClip"];
    if (!isMedia && !isCollection) return;

    double clipDuration = 0;
    if ([item respondsToSelector:@selector(duration)]) {
        SpliceKitCaption_CMTime d = ((SpliceKitCaption_CMTime (*)(id, SEL))STRET_MSG)(item, @selector(duration));
        clipDuration = SpliceKitCaption_CMTimeToSeconds(d);
    }
    if (clipDuration <= 0) return;

    double timelineStart = defaultTimelinePos;
    double effectiveDuration = clipDuration;
    if (![self effectiveRangeForTimelineObject:item
                                  primaryObject:primaryObject
                                          start:&timelineStart
                                       duration:&effectiveDuration]) {
        double anchoredOffset = [self anchoredOffsetForTimelineObject:item];
        if (anchoredOffset >= 0) timelineStart = anchoredOffset;
    }

    if (isMedia) {
        [self addMediaClip:item timelineObject:item duration:effectiveDuration atTimeline:timelineStart into:clipInfos];
        return;
    }

    id innerMedia = [self findFirstMediaInContainer:item];
    if (!innerMedia) return;

    double collTrimStart = 0;
    SEL crSel = NSSelectorFromString(@"clippedRange");
    if ([item respondsToSelector:crSel]) {
        NSMethodSignature *sig = [item methodSignatureForSelector:crSel];
        if (sig && [sig methodReturnLength] == sizeof(SpliceKitCaption_CMTimeRange)) {
            SpliceKitCaption_CMTimeRange range;
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setTarget:item];
            [inv setSelector:crSel];
            [inv invoke];
            [inv getReturnValue:&range];
            collTrimStart = SpliceKitCaption_CMTimeToSeconds(range.start);
        }
    }

    [self addMediaClip:innerMedia
          timelineObject:item
               duration:effectiveDuration
              trimStart:collTrimStart
             atTimeline:timelineStart
                   into:clipInfos];
}

- (id)findFirstMediaInContainer:(id)container {
    id subItems = nil;
    if ([container respondsToSelector:@selector(containedItems)]) {
        subItems = ((id (*)(id, SEL))objc_msgSend)(container, @selector(containedItems));
    }
    if ((!subItems || ![subItems isKindOfClass:[NSArray class]] || [(NSArray *)subItems count] == 0) &&
        [container respondsToSelector:@selector(primaryObject)]) {
        id primary = ((id (*)(id, SEL))objc_msgSend)(container, @selector(primaryObject));
        if (primary && [primary respondsToSelector:@selector(containedItems)]) {
            subItems = ((id (*)(id, SEL))objc_msgSend)(primary, @selector(containedItems));
        }
    }
    if (!subItems || ![subItems isKindOfClass:[NSArray class]]) return nil;

    for (id sub in (NSArray *)subItems) {
        NSString *cls = NSStringFromClass([sub class]);
        if ([cls containsString:@"MediaComponent"]) return sub;
        if ([cls containsString:@"Collection"] || [cls containsString:@"AnchoredClip"]) {
            id found = [self findFirstMediaInContainer:sub];
            if (found) return found;
        }
    }
    return nil;
}

- (void)addMediaClip:(id)clip duration:(double)clipDuration atTimeline:(double)timelinePos into:(NSMutableArray *)clipInfos {
    [self addMediaClip:clip timelineObject:clip duration:clipDuration atTimeline:timelinePos into:clipInfos];
}

- (void)addMediaClip:(id)clip timelineObject:(id)timelineObject duration:(double)clipDuration atTimeline:(double)timelinePos into:(NSMutableArray *)clipInfos {
    double trimStart = 0;
    SEL unclippedSel = NSSelectorFromString(@"unclippedRange");
    if ([clip respondsToSelector:unclippedSel]) {
        NSMethodSignature *sig = [clip methodSignatureForSelector:unclippedSel];
        if (sig && [sig methodReturnLength] == sizeof(SpliceKitCaption_CMTimeRange)) {
            SpliceKitCaption_CMTimeRange range;
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setTarget:clip];
            [inv setSelector:unclippedSel];
            [inv invoke];
            [inv getReturnValue:&range];
            trimStart = SpliceKitCaption_CMTimeToSeconds(range.start);
        }
    }
    [self addMediaClip:clip
          timelineObject:timelineObject
               duration:clipDuration
              trimStart:trimStart
             atTimeline:timelinePos
                   into:clipInfos];
}

- (void)addMediaClip:(id)clip duration:(double)clipDuration trimStart:(double)trimStart atTimeline:(double)timelinePos into:(NSMutableArray *)clipInfos {
    [self addMediaClip:clip
          timelineObject:clip
               duration:clipDuration
              trimStart:trimStart
             atTimeline:timelinePos
                   into:clipInfos];
}

- (void)addMediaClip:(id)clip timelineObject:(id)timelineObject duration:(double)clipDuration trimStart:(double)trimStart atTimeline:(double)timelinePos into:(NSMutableArray *)clipInfos {
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    info[@"timelineStart"] = @(timelinePos);
    info[@"duration"] = @(clipDuration);
    info[@"trimStart"] = @(trimStart);
    info[@"handle"] = SpliceKit_storeHandle(clip);
    if (timelineObject) info[@"timelineObject"] = timelineObject;
    if (clip) info[@"mediaObject"] = clip;

    // Get the media's timecode origin (unclippedRange.start) for coordinate conversion.
    double mediaOrigin = 0;
    SEL ucSel = NSSelectorFromString(@"unclippedRange");
    if ([clip respondsToSelector:ucSel]) {
        NSMethodSignature *sig = [clip methodSignatureForSelector:ucSel];
        if (sig && [sig methodReturnLength] == sizeof(SpliceKitCaption_CMTimeRange)) {
            SpliceKitCaption_CMTimeRange range;
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setTarget:clip];
            [inv setSelector:ucSel];
            [inv invoke];
            [inv getReturnValue:&range];
            mediaOrigin = SpliceKitCaption_CMTimeToSeconds(range.start);
        }
    }
    info[@"mediaOrigin"] = @(mediaOrigin);

    NSURL *mediaURL = [self getMediaURLForClip:clip];
    if (mediaURL) info[@"mediaURL"] = mediaURL;
    [clipInfos addObject:info];
}

- (NSArray *)collectClipInfosForSequence:(id)sequence primaryObject:(id)primaryObject errorMessage:(NSString **)errorMessageOut {
    if (errorMessageOut) *errorMessageOut = nil;
    if (!sequence) {
        if (errorMessageOut) *errorMessageOut = @"No sequence in timeline.";
        return nil;
    }
    if (!primaryObject) {
        if (errorMessageOut) *errorMessageOut = @"No primary object in sequence.";
        return nil;
    }

    id items = nil;
    if ([primaryObject respondsToSelector:@selector(containedItems)]) {
        items = ((id (*)(id, SEL))objc_msgSend)(primaryObject, @selector(containedItems));
    }
    if (!items || ![items isKindOfClass:[NSArray class]]) {
        if (errorMessageOut) *errorMessageOut = @"No items on timeline.";
        return nil;
    }

    NSMutableArray *clipInfos = [NSMutableArray array];
    double timelinePos = 0;
    [self collectClipsFrom:(NSArray *)items primaryObject:primaryObject atTimeline:&timelinePos into:clipInfos];
    return [clipInfos copy];
}

- (void)performCaptionTranscription {
    SpliceKit_log(@"[Captions] Starting built-in Parakeet transcription");

    // Find the parakeet-transcriber binary
    NSString *binaryPath = [self parakeetTranscriberPath];
    if (!binaryPath) {
        [self transcriptionFailedWithError:@"Parakeet transcriber not found. Re-run the SpliceKit patcher or switch to Transcript Editor."];
        return;
    }
    if (![[NSFileManager defaultManager] isExecutableFileAtPath:binaryPath]) {
        [self transcriptionFailedWithError:@"Parakeet binary is not executable. Try: chmod +x ~/Applications/SpliceKit/tools/parakeet-transcriber"];
        return;
    }

    SpliceKit_log(@"[Captions] Using parakeet-transcriber at: %@", binaryPath);

    // Collect clips from the active timeline
    __block NSArray *clips = nil;

    SpliceKit_executeOnMainThread(^{
        @try {
            id timeline = SpliceKit_getActiveTimelineModule();
            if (!timeline) {
                [self transcriptionFailedWithError:@"No active timeline. Open a project first."];
                return;
            }

            // Detect frame rate
            if ([timeline respondsToSelector:@selector(sequenceFrameDuration)]) {
                SpliceKitCaption_CMTime fd = ((SpliceKitCaption_CMTime (*)(id, SEL))STRET_MSG)(
                    timeline, @selector(sequenceFrameDuration));
                if (fd.timescale > 0 && fd.value > 0) {
                    self.frameRate = (double)fd.timescale / fd.value;
                    self.fdNum = (int)fd.value;
                    self.fdDen = (int)fd.timescale;
                }
            }

            id sequence = ((id (*)(id, SEL))objc_msgSend)(timeline, @selector(sequence));
            if (!sequence) { [self transcriptionFailedWithError:@"No sequence in timeline."]; return; }

            id primaryObj = [sequence respondsToSelector:@selector(primaryObject)]
                ? ((id (*)(id, SEL))objc_msgSend)(sequence, @selector(primaryObject))
                : nil;

            NSString *collectError = nil;
            clips = [self collectClipInfosForSequence:sequence
                                         primaryObject:primaryObj
                                          errorMessage:&collectError];
            if (!clips) {
                [self transcriptionFailedWithError:collectError ?: @"No items on timeline."];
                return;
            }
        } @catch (NSException *e) {
            [self transcriptionFailedWithError:[NSString stringWithFormat:@"Error reading timeline: %@", e.reason]];
        }
    });

    if (!clips || clips.count == 0) {
        if (self.status != SpliceKitCaptionStatusError) {
            [self transcriptionFailedWithError:@"No media clips found on timeline."];
        }
        return;
    }

    SpliceKit_log(@"[Captions] Found %lu items on timeline", (unsigned long)clips.count);

    // Filter to clips with media URLs
    NSMutableArray *transcribableClips = [NSMutableArray array];
    for (NSDictionary *clipInfo in clips) {
        if (!clipInfo[@"mediaURL"]) continue;
        double dur = [clipInfo[@"duration"] doubleValue];
        if (dur < 0.5) continue;
        [transcribableClips addObject:clipInfo];
    }

    if (transcribableClips.count == 0) {
        [self transcriptionFailedWithError:@"No transcribable clips found on timeline."];
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        self.statusLabel.stringValue = [NSString stringWithFormat:@"Transcribing %lu clips with Parakeet...",
            (unsigned long)transcribableClips.count];
        if (self.progressBar) {
            self.progressBar.hidden = NO;
            self.progressBar.indeterminate = NO;
            self.progressBar.doubleValue = 0;
        }
    });

    // Build batch manifest — deduplicate source files
    NSString *manifestPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"splicekit_caption_batch.json"];
    NSMutableOrderedSet *uniqueFiles = [NSMutableOrderedSet orderedSet];
    for (NSDictionary *clipInfo in transcribableClips) {
        NSURL *mediaURL = clipInfo[@"mediaURL"];
        [uniqueFiles addObject:mediaURL.path];
    }
    NSMutableArray *manifestEntries = [NSMutableArray array];
    for (NSString *file in uniqueFiles) {
        [manifestEntries addObject:@{@"file": file}];
    }
    NSData *manifestData = [NSJSONSerialization dataWithJSONObject:manifestEntries options:0 error:nil];
    [manifestData writeToFile:manifestPath atomically:YES];

    SpliceKit_log(@"[Captions] Parakeet batch: %lu clips, %lu unique source files",
        (unsigned long)transcribableClips.count, (unsigned long)uniqueFiles.count);

    // Run parakeet-transcriber
    NSMutableArray *taskArgs = [NSMutableArray arrayWithObjects:@"--batch", manifestPath, @"--progress", @"--model", @"v3", nil];

    NSTask *task = [[NSTask alloc] init];
    task.launchPath = binaryPath;
    task.arguments = taskArgs;

    NSPipe *stdoutPipe = [NSPipe pipe];
    NSPipe *stderrPipe = [NSPipe pipe];
    task.standardOutput = stdoutPipe;
    task.standardError = stderrPipe;

    __block NSMutableData *stdoutAccum = [NSMutableData data];
    stdoutPipe.fileHandleForReading.readabilityHandler = ^(NSFileHandle *handle) {
        NSData *data = handle.availableData;
        if (data.length > 0) {
            @synchronized (stdoutAccum) {
                [stdoutAccum appendData:data];
            }
        }
    };

    // Stream stderr for progress updates
    stderrPipe.fileHandleForReading.readabilityHandler = ^(NSFileHandle *handle) {
        NSData *data = handle.availableData;
        if (data.length == 0) return;
        NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (!text) return;
        for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
            if ([line hasPrefix:@"PROGRESS:"]) {
                NSArray *parts = [line componentsSeparatedByString:@":"];
                if (parts.count >= 3) {
                    double frac = [parts[1] doubleValue];
                    NSString *msg = [[parts subarrayWithRange:NSMakeRange(2, parts.count - 2)]
                        componentsJoinedByString:@":"];
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (self.progressBar) {
                            self.progressBar.indeterminate = NO;
                            self.progressBar.doubleValue = frac;
                        }
                        self.statusLabel.stringValue = [NSString stringWithFormat:@"Parakeet: %@", msg];
                    });
                }
            }
        }
    };

    @try {
        [task launch];
        SpliceKit_log(@"[Captions] Parakeet process started (PID %d)", task.processIdentifier);
        [task waitUntilExit];
    } @catch (NSException *e) {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil;
        stderrPipe.fileHandleForReading.readabilityHandler = nil;
        [self transcriptionFailedWithError:[NSString stringWithFormat:@"Could not launch Parakeet: %@", e.reason]];
        return;
    }

    stdoutPipe.fileHandleForReading.readabilityHandler = nil;
    stderrPipe.fileHandleForReading.readabilityHandler = nil;

    NSData *remaining = [stdoutPipe.fileHandleForReading readDataToEndOfFile];
    if (remaining.length > 0) {
        @synchronized (stdoutAccum) {
            [stdoutAccum appendData:remaining];
        }
    }

    [[NSFileManager defaultManager] removeItemAtPath:manifestPath error:nil];

    if (task.terminationStatus != 0) {
        SpliceKit_log(@"[Captions] Parakeet failed (exit code %d)", task.terminationStatus);
        [self transcriptionFailedWithError:[NSString stringWithFormat:@"Parakeet transcription failed (exit code %d). Check log for details.", task.terminationStatus]];
        return;
    }

    // Parse JSON output
    NSData *jsonData;
    @synchronized (stdoutAccum) {
        jsonData = [stdoutAccum copy];
    }

    if (jsonData.length == 0) {
        [self transcriptionFailedWithError:@"Parakeet produced no output. The audio may be silent or too short."];
        return;
    }

    // CoreML's E5RT runtime can print error messages to stdout before the JSON.
    // Detect and strip any non-JSON prefix so parsing succeeds.
    NSString *rawOutput = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    if (rawOutput && [rawOutput hasPrefix:@"E5RT "]) {
        NSRange bracketRange = [rawOutput rangeOfString:@"["];
        if (bracketRange.location != NSNotFound) {
            NSString *errPrefix = [rawOutput substringToIndex:bracketRange.location];
            SpliceKit_log(@"[Captions] CoreML warning on stdout (stripped): %@", [errPrefix stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]);
            rawOutput = [rawOutput substringFromIndex:bracketRange.location];
            jsonData = [rawOutput dataUsingEncoding:NSUTF8StringEncoding];
        }
    }

    NSError *jsonError = nil;
    NSArray *batchResults = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:&jsonError];
    if (![batchResults isKindOfClass:[NSArray class]]) {
        [self transcriptionFailedWithError:@"Parakeet returned unexpected output. Check the log for details."];
        return;
    }

    // Map results back to clips
    SpliceKitTranscriptDiag_logParsedResults(batchResults);
    NSMutableDictionary *resultsByFile = [NSMutableDictionary dictionary];
    for (NSDictionary *result in batchResults) {
        NSString *file = result[@"file"];
        NSArray *words = result[@"words"];
        if (file && [words isKindOfClass:[NSArray class]]) {
            resultsByFile[file] = words;
        }
    }

    // Build words array
    NSMutableArray<SpliceKitTranscriptWord *> *allWords = [NSMutableArray array];
    for (NSDictionary *clipInfo in transcribableClips) {
        NSURL *mediaURL = clipInfo[@"mediaURL"];
        double timelineStart = [clipInfo[@"timelineStart"] doubleValue];
        double trimStart = [clipInfo[@"trimStart"] doubleValue];
        double clipDuration = [clipInfo[@"duration"] doubleValue];
        double mediaOrigin = [clipInfo[@"mediaOrigin"] doubleValue];
        NSString *clipHandle = clipInfo[@"handle"];

        NSArray *wordDicts = resultsByFile[mediaURL.path];
        if (!wordDicts) continue;

        // Convert trimStart from FCP's timecode coordinate space to file-relative
        double fileRelativeTrimStart = trimStart - mediaOrigin;

        for (NSDictionary *wd in wordDicts) {
            NSString *text = wd[@"word"];
            double startTime = [wd[@"startTime"] doubleValue];
            double endTime = [wd[@"endTime"] doubleValue];
            double confidence = [wd[@"confidence"] doubleValue];

            if (startTime >= fileRelativeTrimStart && startTime < fileRelativeTrimStart + clipDuration) {
                SpliceKitTranscriptWord *word = [[SpliceKitTranscriptWord alloc] init];
                word.text = text;
                word.startTime = timelineStart + (startTime - fileRelativeTrimStart);
                word.duration = MIN(endTime - startTime, (fileRelativeTrimStart + clipDuration) - startTime);
                word.endTime = word.startTime + word.duration;
                word.confidence = confidence;
                word.clipHandle = clipHandle;
                word.clipTimelineStart = timelineStart;
                word.sourceMediaOffset = trimStart;
                word.sourceMediaTime = startTime + mediaOrigin;
                word.sourceMediaPath = mediaURL.path;
                [allWords addObject:word];
            }
        }
    }

    SpliceKit_log(@"[Captions] Parakeet transcription complete: %lu words", (unsigned long)allWords.count);
    [self transcriptionFinishedWithWords:allWords];
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
    if (!self.suppressPersistenceWrites) {
        [self persistCaptionDraftStateForCurrentSequence];
    }
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

static NSString *SpliceKitCaption_previewText(NSString *text, NSUInteger maxLength) {
    NSString *safe = text ?: @"";
    safe = [[safe stringByReplacingOccurrencesOfString:@"\n" withString:@" "]
        stringByReplacingOccurrencesOfString:@"\r" withString:@" "];
    if (safe.length <= maxLength) return safe;
    return [[safe substringToIndex:maxLength] stringByAppendingString:@"..."];
}

static NSString *SpliceKitCaption_formatCMTime(SpliceKitCaption_CMTime time) {
    if (time.timescale <= 0) return @"invalid";
    return [NSString stringWithFormat:@"%lld/%ds (%.4fs)",
            time.value, time.timescale, SpliceKitCaption_CMTimeToSeconds(time)];
}

static NSString *SpliceKitCaption_describeObject(id obj) {
    if (!obj) return @"(nil)";
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    [parts addObject:[NSString stringWithFormat:@"%@ %p",
                      NSStringFromClass([obj class]) ?: @"(unknown)",
                      obj]];

    @try {
        SEL displayNameSel = NSSelectorFromString(@"displayName");
        if ([obj respondsToSelector:displayNameSel]) {
            id value = ((id (*)(id, SEL))objc_msgSend)(obj, displayNameSel);
            if ([value isKindOfClass:[NSString class]] && [value length] > 0) {
                [parts addObject:[NSString stringWithFormat:@"displayName=\"%@\"",
                                  SpliceKitCaption_previewText(value, 80)]];
            }
        }
    } @catch (NSException *e) {}

    @try {
        SEL nameSel = NSSelectorFromString(@"name");
        if ([obj respondsToSelector:nameSel]) {
            id value = ((id (*)(id, SEL))objc_msgSend)(obj, nameSel);
            if ([value isKindOfClass:[NSString class]] && [value length] > 0) {
                [parts addObject:[NSString stringWithFormat:@"name=\"%@\"",
                                  SpliceKitCaption_previewText(value, 80)]];
            }
        }
    } @catch (NSException *e) {}

    return [parts componentsJoinedByString:@" "];
}

static void SpliceKitCaption_writeDataDebugFile(NSData *data, NSString *path, NSString *label) {
    if (!data || !path) return;
    NSError *writeError = nil;
    BOOL ok = [data writeToFile:path options:NSDataWritingAtomic error:&writeError];
    if (ok) {
        SpliceKit_log(@"[Captions][Debug] Wrote %@ (%lu bytes) to %@",
                      label, (unsigned long)data.length, path);
    } else {
        SpliceKit_log(@"[Captions][Debug] Failed to write %@ to %@: %@",
                      label, path, writeError.localizedDescription ?: @"unknown error");
    }
}

static void SpliceKitCaption_writeJSONDebugFile(id object, NSString *path, NSString *label) {
    if (!object || !path) return;
    if (![NSJSONSerialization isValidJSONObject:object]) {
        SpliceKit_log(@"[Captions][Debug] %@ JSON object invalid for %@", label, path);
        return;
    }
    NSError *jsonError = nil;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:object
                                                       options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys
                                                         error:&jsonError];
    if (!jsonData) {
        SpliceKit_log(@"[Captions][Debug] Failed to encode %@ JSON: %@",
                      label, jsonError.localizedDescription ?: @"unknown error");
        return;
    }
    SpliceKitCaption_writeDataDebugFile(jsonData, path, label);
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

static long long SpliceKitCaption_frameCountForSeconds(double seconds, int fdNum, int fdDen, BOOL allowZero) {
    int safeFdNum = MAX(fdNum, 1);
    int safeFdDen = MAX(fdDen, 1);
    long long frames = (long long)llround(seconds * safeFdDen / safeFdNum);
    if (!allowZero && seconds > 0 && frames <= 0) frames = 1;
    if (frames < 0) frames = 0;
    return frames;
}

static SpliceKitCaption_CMTime SpliceKitCaption_makeFrameAlignedCMTime(long long frames, int fdNum, int fdDen) {
    SpliceKitCaption_CMTime time;
    time.value = frames * MAX(fdNum, 1);
    time.timescale = MAX(fdDen, 1);
    time.flags = 1;
    time.epoch = 0;
    return time;
}

static id SpliceKitCaption_newGapComponent(SpliceKitCaption_CMTime duration, SpliceKitCaption_CMTime sampleDuration) {
    Class gapClass = objc_getClass("FFAnchoredGapGeneratorComponent");
    if (!gapClass) return nil;
    SEL gapSel = NSSelectorFromString(@"newGap:ofSampleDuration:");
    if (![gapClass respondsToSelector:gapSel]) return nil;
    return ((id (*)(id, SEL, SpliceKitCaption_CMTime, SpliceKitCaption_CMTime))objc_msgSend)(
        gapClass, gapSel, duration, sampleDuration);
}

static id SpliceKitCaption_findFirstChannelNode(id root, Class targetClass, NSString *targetName) {
    if (!root || !targetClass) return nil;

    NSMutableArray *stack = [NSMutableArray arrayWithObject:root];
    SEL childSel = NSSelectorFromString(@"children");
    SEL nameSel = NSSelectorFromString(@"name");

    while (stack.count > 0) {
        id node = stack.lastObject;
        [stack removeLastObject];

        if ([node isKindOfClass:targetClass]) {
            if (!targetName) return node;
            @try {
                if ([node respondsToSelector:nameSel]) {
                    id name = ((id (*)(id, SEL))objc_msgSend)(node, nameSel);
                    if ([name isKindOfClass:[NSString class]] &&
                        [(NSString *)name isEqualToString:targetName]) {
                        return node;
                    }
                }
            } @catch (NSException *e) {}
        }

        @try {
            if ([node respondsToSelector:childSel]) {
                NSArray *children = ((id (*)(id, SEL))objc_msgSend)(node, childSel);
                if ([children isKindOfClass:[NSArray class]] && children.count > 0) {
                    [stack addObjectsFromArray:children];
                }
            }
        } @catch (NSException *e) {}
    }

    return nil;
}

static NSString *SpliceKitCaption_colorDebugString(NSColor *color) {
    if (![color isKindOfClass:[NSColor class]]) return @"(nil)";
    NSColor *rgb = [color colorUsingColorSpace:[NSColorSpace deviceRGBColorSpace]];
    if (!rgb) return color.description ?: @"(unconvertible)";
    return [NSString stringWithFormat:@"rgba(%.3f,%.3f,%.3f,%.3f)",
            rgb.redComponent, rgb.greenComponent, rgb.blueComponent, rgb.alphaComponent];
}

static NSString *SpliceKitCaption_fontDebugString(NSFont *font) {
    if (![font isKindOfClass:[NSFont class]]) return @"(nil)";
    return [NSString stringWithFormat:@"%@ %.1f",
            font.fontName ?: font.familyName ?: @"(unknown)", font.pointSize];
}

static NSUInteger SpliceKitCaption_attributedStringRunCount(NSAttributedString *attr) {
    if (![attr isKindOfClass:[NSAttributedString class]] || attr.length == 0) return 0;
    __block NSUInteger runCount = 0;
    [attr enumerateAttributesInRange:NSMakeRange(0, attr.length)
                             options:0
                          usingBlock:^(__unused NSDictionary<NSAttributedStringKey, id> *attrs,
                                       __unused NSRange range,
                                       __unused BOOL *stop) {
        runCount += 1;
    }];
    return runCount;
}

static NSString *SpliceKitCaption_attributedStringSummary(NSAttributedString *attr) {
    if (![attr isKindOfClass:[NSAttributedString class]] || attr.length == 0) return @"runs=0";

    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    __block NSUInteger runIndex = 0;
    [attr enumerateAttributesInRange:NSMakeRange(0, attr.length)
                             options:0
                          usingBlock:^(NSDictionary<NSAttributedStringKey, id> *attrs,
                                       NSRange range,
                                       BOOL *stop) {
        if (runIndex >= 6) {
            [parts addObject:@"..."];
            *stop = YES;
            return;
        }
        NSString *snippet = [[attr.string substringWithRange:range]
            stringByReplacingOccurrencesOfString:@"\n" withString:@"\\n"];
        if (snippet.length > 18) snippet = [[snippet substringToIndex:18] stringByAppendingString:@"..."];
        NSFont *font = attrs[NSFontAttributeName];
        NSColor *color = attrs[NSForegroundColorAttributeName];
        NSNumber *strokeWidth = attrs[NSStrokeWidthAttributeName];
        NSNumber *kern = attrs[NSKernAttributeName];
        [parts addObject:[NSString stringWithFormat:@"[%lu]{%@} font=%@ color=%@ stroke=%@ kern=%@ keys=%lu",
                          (unsigned long)range.location,
                          snippet ?: @"",
                          SpliceKitCaption_fontDebugString(font),
                          SpliceKitCaption_colorDebugString(color),
                          strokeWidth ?: @"(nil)",
                          kern ?: @"(nil)",
                          (unsigned long)attrs.count]];
        runIndex += 1;
    }];

    return [NSString stringWithFormat:@"runs=%lu %@",
            (unsigned long)SpliceKitCaption_attributedStringRunCount(attr),
            [parts componentsJoinedByString:@" | "]];
}

static id SpliceKitCaption_directTextChannelForEffect(id effect) {
    if (!effect) return nil;

    id textChannel = nil;
    SEL channelSel = NSSelectorFromString(@"channelForField:");
    if ([effect respondsToSelector:channelSel]) {
        @try {
            textChannel = ((id (*)(id, SEL, NSUInteger))objc_msgSend)(effect, channelSel, 0);
        } @catch (__unused NSException *e) {}
    }

    Class textClass = objc_getClass("CHChannelText");
    if (textClass && [textChannel isKindOfClass:textClass]) {
        return textChannel;
    }

    SEL folderSel = NSSelectorFromString(@"channelFolder");
    if (![effect respondsToSelector:folderSel]) return nil;
    id channelFolder = ((id (*)(id, SEL))objc_msgSend)(effect, folderSel);
    if (!channelFolder) return nil;

    textChannel = SpliceKitCaption_findFirstChannelNode(channelFolder, textClass, @"Text");
    if (!textChannel) {
        textChannel = SpliceKitCaption_findFirstChannelNode(channelFolder, textClass, nil);
    }
    return textChannel;
}

static BOOL SpliceKitCaption_usesWordHighlightRuntimeStyle(SpliceKitCaptionStyle *style) {
    return (style &&
            style.wordByWordHighlight &&
            [style.highlightColor isKindOfClass:[NSColor class]]);
}

static NSAttributedString *SpliceKitCaption_makeGeneratorAttributedString(NSString *text,
                                                                         SpliceKitCaptionStyle *style) {
    NSString *safeText = text ?: @"";
    NSColor *textColor = style.textColor ?: [NSColor whiteColor];
    NSString *fontName = style.font ?: @"Helvetica-Bold";
    CGFloat fontSize = style.fontSize > 0 ? style.fontSize : 72.0;
    NSFont *font = [NSFont fontWithName:fontName size:fontSize];
    if (!font) font = [NSFont boldSystemFontOfSize:fontSize];

    NSMutableParagraphStyle *paragraph = [[NSMutableParagraphStyle alloc] init];
    paragraph.alignment = NSTextAlignmentCenter;
    paragraph.lineBreakMode = NSLineBreakByWordWrapping;

    NSDictionary *attrs = @{
        NSFontAttributeName: font,
        NSForegroundColorAttributeName: textColor,
        NSParagraphStyleAttributeName: paragraph,
    };
    return [[NSAttributedString alloc] initWithString:safeText attributes:attrs];
}

static NSMutableDictionary<NSAttributedStringKey, id> *SpliceKitCaption_generatorTextAttributes(SpliceKitCaptionStyle *style,
                                                                                                 NSColor *fillColor) {
    NSString *fontName = style.font ?: @"Helvetica-Bold";
    CGFloat fontSize = style.fontSize > 0 ? style.fontSize : 72.0;
    NSFont *font = [NSFont fontWithName:fontName size:fontSize];
    if (!font) font = [NSFont boldSystemFontOfSize:fontSize];

    NSMutableParagraphStyle *paragraph = [[NSMutableParagraphStyle alloc] init];
    paragraph.alignment = NSTextAlignmentCenter;
    paragraph.lineBreakMode = NSLineBreakByWordWrapping;

    NSMutableDictionary<NSAttributedStringKey, id> *attrs = [@{
        NSFontAttributeName: font,
        NSForegroundColorAttributeName: fillColor ?: [NSColor whiteColor],
        NSParagraphStyleAttributeName: paragraph,
        NSLigatureAttributeName: @0,
    } mutableCopy];

    if (SpliceKitCaption_usesWordHighlightRuntimeStyle(style)) {
        // Match the older word-progress generator more closely so runtime titles
        // keep the tighter, heavier-looking tracking the user expects.
        attrs[NSKernAttributeName] = @(-3.2);
    }

    if (style.outlineColor && style.outlineWidth > 0) {
        attrs[NSStrokeColorAttributeName] = style.outlineColor;
        // Negative width renders fill + stroke, which is what the preview and FCPXML path use.
        attrs[NSStrokeWidthAttributeName] = @(-style.outlineWidth);
    }

    if (style.shadowColor && style.shadowBlurRadius > 0) {
        NSShadow *shadow = [[NSShadow alloc] init];
        shadow.shadowColor = style.shadowColor;
        if (SpliceKitCaption_usesWordHighlightRuntimeStyle(style)) {
            shadow.shadowBlurRadius = 2.43;
            shadow.shadowOffset = NSMakeSize(3.54, -3.54);
        } else {
            shadow.shadowBlurRadius = style.shadowBlurRadius;
            shadow.shadowOffset = NSMakeSize(style.shadowOffsetX, -style.shadowOffsetY);
        }
        attrs[NSShadowAttributeName] = shadow;
    }

    return attrs;
}

static NSAttributedString *SpliceKitCaption_makeHighlightedGeneratorAttributedStringFromWords(NSArray<NSString *> *displayWords,
                                                                                              NSUInteger activeWordIndex,
                                                                                              SpliceKitCaptionStyle *style) {
    if (![displayWords isKindOfClass:[NSArray class]] || displayWords.count == 0) {
        return SpliceKitCaption_makeGeneratorAttributedString(@"", style);
    }

    NSColor *baseColor = style.textColor ?: [NSColor whiteColor];
    NSColor *highlightColor = style.highlightColor ?: [NSColor yellowColor];

    NSDictionary *baseAttrs = SpliceKitCaption_generatorTextAttributes(style, baseColor);
    NSDictionary *highlightAttrs = SpliceKitCaption_generatorTextAttributes(style, highlightColor);

    NSMutableAttributedString *result = [[NSMutableAttributedString alloc] init];
    for (NSUInteger i = 0; i < displayWords.count; i++) {
        NSString *wordText = [displayWords[i] isKindOfClass:[NSString class]] ? displayWords[i] : @"";
        if (i > 0) {
            [result appendAttributedString:[[NSAttributedString alloc] initWithString:@" " attributes:baseAttrs]];
        }
        NSDictionary *attrs = (i == activeWordIndex) ? highlightAttrs : baseAttrs;
        [result appendAttributedString:[[NSAttributedString alloc] initWithString:wordText attributes:attrs]];
    }
    return result;
}

static NSAttributedString *SpliceKitCaption_makeHighlightedGeneratorAttributedString(SpliceKitCaptionSegment *seg,
                                                                                    NSUInteger activeWordIndex,
                                                                                    SpliceKitCaptionStyle *style) {
    if (!seg || seg.words.count == 0) {
        return SpliceKitCaption_makeGeneratorAttributedString(seg.text ?: @"", style);
    }
    NSMutableArray<NSString *> *displayWords = [NSMutableArray arrayWithCapacity:seg.words.count];
    for (SpliceKitTranscriptWord *word in seg.words) {
        NSString *wordText = word.text ?: @"";
        if (style.allCaps) wordText = [wordText uppercaseString];
        [displayWords addObject:wordText];
    }
    return SpliceKitCaption_makeHighlightedGeneratorAttributedStringFromWords(displayWords,
                                                                              activeWordIndex,
                                                                              style);
}

static NSAttributedString *SpliceKitCaption_effectFieldAttributedTextTemplate(id effect) {
    if (!effect) return nil;

    SEL getTextSel = NSSelectorFromString(@"textForField:");
    if (![effect respondsToSelector:getTextSel]) return nil;

    @try {
        id readBack = ((id (*)(id, SEL, NSUInteger))objc_msgSend)(effect, getTextSel, 0);
        if ([readBack isKindOfClass:[NSAttributedString class]] &&
            [(NSAttributedString *)readBack length] > 0) {
            return readBack;
        }
    } @catch (__unused NSException *e) {}

    return nil;
}

static NSAttributedString *SpliceKitCaption_channelAttributedTextTemplate(id textChannel) {
    if (!textChannel) return nil;

    SEL attrSel = NSSelectorFromString(@"attributedString");
    if ([textChannel respondsToSelector:attrSel]) {
        @try {
            id attr = ((id (*)(id, SEL))objc_msgSend)(textChannel, attrSel);
            if ([attr isKindOfClass:[NSAttributedString class]] &&
                [(NSAttributedString *)attr length] > 0) {
                return attr;
            }
        } @catch (__unused NSException *e) {}
    }

    return nil;
}

static NSAttributedString *SpliceKitCaption_mergeAttributedTextWithTemplate(NSAttributedString *desired,
                                                                            NSAttributedString *template) {
    if (![desired isKindOfClass:[NSAttributedString class]] || desired.length == 0) return desired;
    if (![template isKindOfClass:[NSAttributedString class]] || template.length == 0) return desired;

    NSDictionary<NSAttributedStringKey, id> *templateAttrs =
        [template attributesAtIndex:0 effectiveRange:NULL];
    if (templateAttrs.count == 0) return desired;

    NSMutableAttributedString *merged = [[NSMutableAttributedString alloc] initWithString:desired.string];
    [desired enumerateAttributesInRange:NSMakeRange(0, desired.length)
                                options:0
                             usingBlock:^(NSDictionary<NSAttributedStringKey, id> *attrs,
                                          NSRange range,
                                          __unused BOOL *stop) {
        NSMutableDictionary<NSAttributedStringKey, id> *runAttrs = [templateAttrs mutableCopy];
        if (attrs.count > 0) {
            [runAttrs addEntriesFromDictionary:attrs];
        }
        [merged setAttributes:runAttrs range:range];
    }];
    return merged;
}

static BOOL SpliceKitCaption_setGeneratorAttributedTextWithOptions(id generator,
                                                                   NSAttributedString *attr,
                                                                   BOOL saveDirty,
                                                                   BOOL allowChannelFallback) {
    if (!attr) return NO;
    SEL effectSel = NSSelectorFromString(@"effect");
    if (![generator respondsToSelector:effectSel]) return NO;
    id effect = ((id (*)(id, SEL))objc_msgSend)(generator, effectSel);
    if (!effect) return NO;

    SEL setTextSel = NSSelectorFromString(@"setText:forField:");
    SEL getTextSel = NSSelectorFromString(@"textForField:");
    SEL saveSel = NSSelectorFromString(@"saveDirtyTextToEffectValues");
    SEL normalizeSel = NSSelectorFromString(@"_newAttributedString:forField:");
    SEL wantsXMLSel = NSSelectorFromString(@"wantsXMLStyledText");
    SEL syncXMLSel = NSSelectorFromString(@"syncChannelStateForXMLExport");

    BOOL wantsXMLStyledText = NO;
    if ([effect respondsToSelector:wantsXMLSel]) {
        @try {
            wantsXMLStyledText = ((BOOL (*)(id, SEL))objc_msgSend)(effect, wantsXMLSel);
        } @catch (__unused NSException *e) {}
    }

    NSAttributedString *templateAttr = SpliceKitCaption_effectFieldAttributedTextTemplate(effect);
    if (templateAttr && SpliceKitCaption_attributedStringRunCount(templateAttr) > 0) {
        SpliceKit_log(@"[Captions][RuntimeTitle] Live effect template summary: %@",
                      SpliceKitCaption_attributedStringSummary(templateAttr));
    }
    NSAttributedString *mergedAttr = SpliceKitCaption_mergeAttributedTextWithTemplate(attr, templateAttr);

    if ([effect respondsToSelector:setTextSel]) {
        @try {
            NSAttributedString *attrToApply = mergedAttr ?: attr;
            NSUInteger inputRunCount = SpliceKitCaption_attributedStringRunCount(attrToApply);
            if (inputRunCount > 1) {
                SpliceKit_log(@"[Captions][RuntimeTitle] Applying attributed text summary: %@",
                              SpliceKitCaption_attributedStringSummary(attrToApply));
            }
            if ([effect respondsToSelector:normalizeSel]) {
                @try {
                    NSMutableAttributedString *mutableInput = [attrToApply mutableCopy];
                    id normalized = ((id (*)(id, SEL, id, NSUInteger))objc_msgSend)(effect, normalizeSel, mutableInput, 0);
                    if ([normalized isKindOfClass:[NSAttributedString class]] &&
                        [(NSAttributedString *)normalized length] > 0) {
                        attrToApply = normalized;
                        SpliceKit_log(@"[Captions][RuntimeTitle] _newAttributedString:forField: normalized attributed text=\"%@\"",
                                      SpliceKitCaption_previewText(attrToApply.string, 80));
                        NSUInteger normalizedRunCount = SpliceKitCaption_attributedStringRunCount(attrToApply);
                        if (normalizedRunCount > 1) {
                            SpliceKit_log(@"[Captions][RuntimeTitle] Normalized attributed text summary: %@",
                                          SpliceKitCaption_attributedStringSummary(attrToApply));
                        }
                    }
                } @catch (NSException *e) {
                    SpliceKit_log(@"[Captions][RuntimeTitle] _newAttributedString:forField: failed on %@: %@",
                                  SpliceKitCaption_describeObject(effect), e.reason);
                }
            }

            ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(effect, setTextSel, attrToApply, 0);

            NSString *readBackText = nil;
            if ([effect respondsToSelector:getTextSel]) {
                id readBack = ((id (*)(id, SEL, NSUInteger))objc_msgSend)(effect, getTextSel, 0);
                if ([readBack isKindOfClass:[NSAttributedString class]]) {
                    readBackText = [(NSAttributedString *)readBack string];
                    NSUInteger readBackRunCount = SpliceKitCaption_attributedStringRunCount(readBack);
                    if (readBackRunCount > 1) {
                        SpliceKit_log(@"[Captions][RuntimeTitle] Read-back attributed text summary: %@",
                                      SpliceKitCaption_attributedStringSummary(readBack));
                    }
                } else if ([readBack isKindOfClass:[NSString class]]) {
                    readBackText = readBack;
                } else {
                    readBackText = [readBack description];
                }
            }
            SpliceKit_log(@"[Captions][RuntimeTitle] FFMotionEffect setText:forField: text=\"%@\" readBack=\"%@\"",
                          SpliceKitCaption_previewText(attrToApply.string, 80),
                          SpliceKitCaption_previewText(readBackText, 80));

            if (wantsXMLStyledText && [effect respondsToSelector:syncXMLSel]) {
                ((void (*)(id, SEL))objc_msgSend)(effect, syncXMLSel);
                SpliceKit_log(@"[Captions][RuntimeTitle] syncChannelStateForXMLExport completed after attributed text update");
            }

            if (saveDirty && [effect respondsToSelector:saveSel]) {
                ((void (*)(id, SEL))objc_msgSend)(effect, saveSel);
                SpliceKit_log(@"[Captions][RuntimeTitle] saveDirtyTextToEffectValues completed after attributed text update");
            }
            SpliceKitCaption_notifyEffectChannelChanged(effect, nil, NO);
            SpliceKitCaption_scheduleEffectTextRefreshPulses(effect, NO);
            return YES;
        } @catch (NSException *e) {
            SpliceKit_log(@"[Captions][RuntimeTitle] setText:forField: failed on %@: %@",
                          SpliceKitCaption_describeObject(effect), e.reason);
        }
    }

    id textChannel = allowChannelFallback ? SpliceKitCaption_directTextChannelForEffect(effect) : nil;
    SEL setAttrSel = NSSelectorFromString(@"setAttributedString:");
    SEL strSel = NSSelectorFromString(@"string");
    if (textChannel && [textChannel respondsToSelector:setAttrSel]) {
        @try {
            NSAttributedString *channelTemplateAttr = SpliceKitCaption_channelAttributedTextTemplate(textChannel);
            NSAttributedString *channelAttr = SpliceKitCaption_mergeAttributedTextWithTemplate(
                mergedAttr ?: attr, channelTemplateAttr);
            NSUInteger inputRunCount = SpliceKitCaption_attributedStringRunCount(channelAttr);
            if (inputRunCount > 1) {
                SpliceKit_log(@"[Captions][RuntimeTitle] Applying CHChannelText attributed summary: %@",
                              SpliceKitCaption_attributedStringSummary(channelAttr));
            }
            ((void (*)(id, SEL, id))objc_msgSend)(textChannel, setAttrSel, channelAttr);

            id readBack = nil;
            if ([textChannel respondsToSelector:strSel]) {
                readBack = ((id (*)(id, SEL))objc_msgSend)(textChannel, strSel);
            }
            SpliceKit_log(@"[Captions][RuntimeTitle] CHChannelText %@ setAttributedString text=\"%@\" readBack=\"%@\"",
                          SpliceKitCaption_describeObject(textChannel),
                          SpliceKitCaption_previewText(channelAttr.string, 80),
                          SpliceKitCaption_previewText([readBack description], 80));

            if (wantsXMLStyledText && [effect respondsToSelector:syncXMLSel]) {
                ((void (*)(id, SEL))objc_msgSend)(effect, syncXMLSel);
                SpliceKit_log(@"[Captions][RuntimeTitle] syncChannelStateForXMLExport completed after CHChannelText update");
            }

            if (saveDirty && [effect respondsToSelector:saveSel]) {
                ((void (*)(id, SEL))objc_msgSend)(effect, saveSel);
                SpliceKit_log(@"[Captions][RuntimeTitle] saveDirtyTextToEffectValues completed after CHChannelText update");
            }
            if ([effect respondsToSelector:getTextSel]) {
                id effectReadBack = ((id (*)(id, SEL, NSUInteger))objc_msgSend)(effect, getTextSel, 0);
                if ([effectReadBack isKindOfClass:[NSAttributedString class]]) {
                    SpliceKit_log(@"[Captions][RuntimeTitle] Effect read-back after CHChannelText update: %@",
                                  SpliceKitCaption_attributedStringSummary(effectReadBack));
                } else if (effectReadBack) {
                    SpliceKit_log(@"[Captions][RuntimeTitle] Effect read-back after CHChannelText update: %@",
                                  SpliceKitCaption_previewText([effectReadBack description], 120));
                }
            }
            SpliceKitCaption_notifyEffectChannelChanged(effect, textChannel, NO);
            SpliceKitCaption_scheduleEffectTextRefreshPulses(effect, NO);
            return YES;
        } @catch (NSException *e) {
            SpliceKit_log(@"[Captions][RuntimeTitle] CHChannelText setAttributedString failed on %@: %@",
                          SpliceKitCaption_describeObject(textChannel), e.reason);
        }
    }

    return NO;
}

static BOOL SpliceKitCaption_setGeneratorAttributedText(id generator,
                                                        NSAttributedString *attr) {
    return SpliceKitCaption_setGeneratorAttributedTextWithOptions(generator, attr, YES, YES);
}

static BOOL SpliceKitCaption_setGeneratorAttributedTextForPersistedRepair(id generator,
                                                                          NSAttributedString *attr) {
    // Relaunch repair must commit the effect-level text field state or the viewer
    // can continue rendering the template placeholder even when read-back looks correct.
    // Keep the low-level channel fallback disabled here to avoid the launch crash.
    return SpliceKitCaption_setGeneratorAttributedTextWithOptions(generator, attr, YES, NO);
}

static void SpliceKitCaption_notifyEffectChannelChanged(id effect,
                                                        id channel,
                                                        BOOL rebuildAllTextFromCurrentStringState) {
    if (!effect) return;

    SEL changedSel = NSSelectorFromString(@"channelParameterChanged:");
    SEL rebuildSel = NSSelectorFromString(@"_rebuildAllTextFromCurrentStringChannelState");
    SEL channelsChangedSel = NSSelectorFromString(@"_channelsChanged");
    SEL userInfoSel = NSSelectorFromString(@"userInfo");

    @try {
        if (channel && [effect respondsToSelector:changedSel] && [channel respondsToSelector:userInfoSel]) {
            ((void (*)(id, SEL, id))objc_msgSend)(effect, changedSel, channel);
        }
    } @catch (NSException *e) {
        SpliceKit_log(@"[Captions][RuntimeTitle] channelParameterChanged failed on %@: %@",
                      SpliceKitCaption_describeObject(effect), e.reason);
    }

    @try {
        if (rebuildAllTextFromCurrentStringState && [effect respondsToSelector:rebuildSel]) {
            ((void (*)(id, SEL))objc_msgSend)(effect, rebuildSel);
        }
    } @catch (NSException *e) {
        SpliceKit_log(@"[Captions][RuntimeTitle] _rebuildAllTextFromCurrentStringChannelState failed on %@: %@",
                      SpliceKitCaption_describeObject(effect), e.reason);
    }

    @try {
        if ([effect respondsToSelector:channelsChangedSel]) {
            ((void (*)(id, SEL))objc_msgSend)(effect, channelsChangedSel);
        }
    } @catch (NSException *e) {
        SpliceKit_log(@"[Captions][RuntimeTitle] _channelsChanged failed on %@: %@",
                      SpliceKitCaption_describeObject(effect), e.reason);
    }
}

static void SpliceKitCaption_scheduleEffectTextRefreshPulses(id effect,
                                                             BOOL rebuildAllTextFromCurrentStringState) {
    if (!effect) return;
    NSArray<NSNumber *> *delays = @[ @0.2, @0.75, @1.5 ];
    for (NSNumber *delay in delays) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            SpliceKitCaption_notifyEffectChannelChanged(effect, nil, rebuildAllTextFromCurrentStringState);
        });
    }
}

static BOOL SpliceKitCaption_setGeneratorChannelText(id generator,
                                                     NSString *text,
                                                     SpliceKitCaptionStyle *style) {
    NSAttributedString *attr = SpliceKitCaption_makeGeneratorAttributedString(text, style);
    return SpliceKitCaption_setGeneratorAttributedText(generator, attr);
}

static BOOL SpliceKitCaption_setGeneratorTextFields(id generator,
                                                    NSArray<NSString *> *fields,
                                                    BOOL notifyChange) {
    SpliceKit_log(@"[Captions][RuntimeTitle] Configuring generator text fields: generator=%@ fields=%@",
                  SpliceKitCaption_describeObject(generator), fields ?: @[]);
    if (!generator) {
        SpliceKit_log(@"[Captions] runtime title text setup skipped: generator missing");
        return NO;
    }
    SEL effectSel = NSSelectorFromString(@"effect");
    if (![generator respondsToSelector:effectSel]) {
        SpliceKit_log(@"[Captions] runtime title generator has no effect selector");
        return NO;
    }
    id effect = ((id (*)(id, SEL))objc_msgSend)(generator, effectSel);
    if (!effect) {
        SpliceKit_log(@"[Captions] runtime title generator effect is nil");
        return NO;
    }
    SpliceKit_log(@"[Captions][RuntimeTitle] effect=%@", SpliceKitCaption_describeObject(effect));

    SEL countSel = NSSelectorFromString(@"textFieldCount");
    SEL setTextSel = NSSelectorFromString(@"setTextString:forField:");
    SEL getTextSel = NSSelectorFromString(@"stringForField:");
    if (![effect respondsToSelector:countSel] || ![effect respondsToSelector:setTextSel]) {
        SpliceKit_log(@"[Captions] runtime title effect text selectors missing on %@",
                      NSStringFromClass([effect class]));
        return NO;
    }

    NSUInteger fieldCount = ((NSUInteger (*)(id, SEL))objc_msgSend)(effect, countSel);
    SpliceKit_log(@"[Captions][RuntimeTitle] textFieldCount=%lu stringForField=%@ saveDirtyTextToEffectValues=%@",
                  (unsigned long)fieldCount,
                  [effect respondsToSelector:getTextSel] ? @"YES" : @"NO",
                  [effect respondsToSelector:NSSelectorFromString(@"saveDirtyTextToEffectValues")] ? @"YES" : @"NO");
    if (fieldCount == 0) {
        SpliceKit_log(@"[Captions] runtime title effect reports zero text fields during generator creation; deferring CHChannelText update until post-paste");
        return NO;
    }

    NSUInteger applied = 0;
    for (NSUInteger i = 0; i < fieldCount; i++) {
        NSString *value = (i < fields.count) ? fields[i] : @"";
        ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(effect, setTextSel, value ?: @"", i);
        if ([effect respondsToSelector:getTextSel]) {
            id readBack = ((id (*)(id, SEL, NSUInteger))objc_msgSend)(effect, getTextSel, i);
            SpliceKit_log(@"[Captions][RuntimeTitle] field[%lu] set=\"%@\" readBack=\"%@\"",
                          (unsigned long)i,
                          SpliceKitCaption_previewText(value, 80),
                          SpliceKitCaption_previewText([readBack description], 80));
        } else {
            SpliceKit_log(@"[Captions][RuntimeTitle] field[%lu] set=\"%@\"",
                          (unsigned long)i,
                          SpliceKitCaption_previewText(value, 80));
        }
        applied++;
    }

    SEL saveSel = NSSelectorFromString(@"saveDirtyTextToEffectValues");
    if ([effect respondsToSelector:saveSel]) {
        ((void (*)(id, SEL))objc_msgSend)(effect, saveSel);
        SpliceKit_log(@"[Captions][RuntimeTitle] saveDirtyTextToEffectValues completed");
    }

    if (notifyChange) {
        // Do not resolve CHChannel wrappers here. During relaunch the effect can
        // expose text fields before ProChannel has wired the OZChannel wrappers.
        SpliceKitCaption_notifyEffectChannelChanged(effect, nil, YES);
        SpliceKitCaption_scheduleEffectTextRefreshPulses(effect, YES);
    }

    return (applied > 0);
}

static id SpliceKitCaption_newRuntimeCaptionGenerator(NSString *text,
                                                      SpliceKitCaptionStyle *style,
                                                      int fdNum,
                                                      int fdDen,
                                                      long long durationFrames) {
    Class genClass = objc_getClass("FFAnchoredGeneratorComponent");
    if (!genClass) {
        SpliceKit_log(@"[Captions][RuntimeTitle] FFAnchoredGeneratorComponent class missing");
        return nil;
    }

    SEL createSel = NSSelectorFromString(@"newGeneratorForEffectIDContainingSubstring:duration:sampleDuration:");
    if (![genClass respondsToSelector:createSel]) {
        SpliceKit_log(@"[Captions][RuntimeTitle] Generator create selector missing on %@",
                      NSStringFromClass(genClass));
        return nil;
    }

    SpliceKitCaption_CMTime sampleDuration = SpliceKitCaption_makeFrameAlignedCMTime(1, fdNum, fdDen);
    SpliceKitCaption_CMTime duration = SpliceKitCaption_makeFrameAlignedCMTime(MAX(durationFrames, 1), fdNum, fdDen);
    SpliceKit_log(@"[Captions][RuntimeTitle] Requesting generator template=\"%@\" text=\"%@\" durationFrames=%lld duration=%@ sample=%@",
                  kSpliceKitRuntimeCaptionTemplateMatch,
                  SpliceKitCaption_previewText(text, 100),
                  durationFrames,
                  SpliceKitCaption_formatCMTime(duration),
                  SpliceKitCaption_formatCMTime(sampleDuration));
    id generator = nil;
    @try {
        generator = ((id (*)(id, SEL, id, SpliceKitCaption_CMTime, SpliceKitCaption_CMTime))objc_msgSend)(
            genClass, createSel, kSpliceKitRuntimeCaptionTemplateMatch, duration, sampleDuration);
    } @catch (NSException *e) {
        SpliceKit_log(@"[Captions][RuntimeTitle] Generator creation threw: %@\n%@",
                      e.reason, [[e callStackSymbols] componentsJoinedByString:@"\n"]);
        return nil;
    }
    SpliceKit_log(@"[Captions][RuntimeTitle] Generator result=%@", SpliceKitCaption_describeObject(generator));
    if (!generator) return nil;

    NSArray<NSString *> *fields = @[text ?: @""];
    BOOL shouldSkipInitialTextSetup = (style.wordByWordHighlight && style.highlightColor != nil);
    if (shouldSkipInitialTextSetup) {
        SpliceKit_log(@"[Captions][RuntimeTitle] Skipping initial plain text setup for word-highlight generator=%@",
                      SpliceKitCaption_describeObject(generator));
    } else if (!SpliceKitCaption_setGeneratorTextFields(generator, fields, YES)) {
        SpliceKit_log(@"[Captions] Continuing with runtime title generator despite text setup failure");
    }
    return generator;
}

static id SpliceKitCaption_primaryObjectForSequence(id sequence) {
    if (!sequence) return nil;
    SEL primarySel = NSSelectorFromString(@"primaryObject");
    if (![sequence respondsToSelector:primarySel]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(sequence, primarySel);
}

static NSUInteger SpliceKitCaption_removeExistingCaptionStorylines(id sequence, NSString *storylineName) {
    id primary = SpliceKitCaption_primaryObjectForSequence(sequence);
    if (!primary) return 0;

    SEL itemsSel = NSSelectorFromString(@"containedItems");
    NSArray *items = [primary respondsToSelector:itemsSel]
        ? ((id (*)(id, SEL))objc_msgSend)(primary, itemsSel)
        : nil;
    if (![items isKindOfClass:[NSArray class]] || items.count == 0) return 0;

    NSUInteger removed = 0;
    SEL anchoredSel = NSSelectorFromString(@"anchoredItems");
    SEL displayNameSel = NSSelectorFromString(@"displayName");
    SEL removeAnchoredItemsSel = NSSelectorFromString(@"removeAnchoredItemsObject:");
    SEL removeAnchoredSel = NSSelectorFromString(@"removeAnchoredObject:");

    for (id item in items) {
        if (![item respondsToSelector:anchoredSel]) continue;
        id anchoredRaw = ((id (*)(id, SEL))objc_msgSend)(item, anchoredSel);
        NSArray *anchored = nil;
        if ([anchoredRaw isKindOfClass:[NSSet class]]) {
            anchored = [(NSSet *)anchoredRaw allObjects];
        } else if ([anchoredRaw isKindOfClass:[NSArray class]]) {
            anchored = anchoredRaw;
        }
        if (anchored.count == 0) continue;

        for (id anchoredObject in anchored) {
            NSString *className = NSStringFromClass([anchoredObject class]) ?: @"";
            if (![className containsString:@"Collection"]) continue;

            NSString *displayName = nil;
            @try {
                if ([anchoredObject respondsToSelector:displayNameSel]) {
                    id name = ((id (*)(id, SEL))objc_msgSend)(anchoredObject, displayNameSel);
                    if ([name isKindOfClass:[NSString class]]) displayName = name;
                }
            } @catch (NSException *e) {}

            if (storylineName.length > 0 && ![displayName isEqualToString:storylineName]) continue;

            if ([item respondsToSelector:removeAnchoredItemsSel]) {
                ((void (*)(id, SEL, id))objc_msgSend)(item, removeAnchoredItemsSel, anchoredObject);
                removed++;
            } else if ([item respondsToSelector:removeAnchoredSel]) {
                ((void (*)(id, SEL, id))objc_msgSend)(item, removeAnchoredSel, anchoredObject);
                removed++;
            }
        }
    }

    return removed;
}

static BOOL SpliceKitCaption_isGeneratorTitleObject(id obj);

static BOOL SpliceKitCaption_storylineNameMatches(NSString *displayName) {
    if (displayName.length == 0) return NO;
    return [displayName isEqualToString:kSpliceKitCaptionStorylineName] ||
           [displayName isEqualToString:SpliceKitLegacyCaptionStorylineName()];
}

static BOOL SpliceKitCaption_effectiveRangeForObject(id primary,
                                                     id object,
                                                     double *startOut,
                                                     double *endOut) {
    if (startOut) *startOut = 0.0;
    if (endOut) *endOut = 0.0;
    if (!primary || !object) return NO;

    SEL rangeSel = NSSelectorFromString(@"effectiveRangeOfObject:");
    if (![primary respondsToSelector:rangeSel]) return NO;

    @try {
        SpliceKitCaption_CMTimeRange range =
            ((SpliceKitCaption_CMTimeRange (*)(id, SEL, id))STRET_MSG)(primary, rangeSel, object);
        if (range.start.timescale <= 0 || range.duration.timescale <= 0) return NO;
        double start = (double)range.start.value / (double)range.start.timescale;
        double duration = (double)range.duration.value / (double)range.duration.timescale;
        if (startOut) *startOut = start;
        if (endOut) *endOut = start + duration;
        return YES;
    } @catch (__unused NSException *e) {
        return NO;
    }
}

static NSArray *SpliceKitCaption_collectTitlesForPersistedStorylines(id sequence) {
    id primary = SpliceKitCaption_primaryObjectForSequence(sequence);
    if (!primary) return @[];

    SEL itemsSel = NSSelectorFromString(@"containedItems");
    NSArray *items = [primary respondsToSelector:itemsSel]
        ? ((id (*)(id, SEL))objc_msgSend)(primary, itemsSel)
        : nil;
    if (![items isKindOfClass:[NSArray class]] || items.count == 0) return @[];

    SEL anchoredSel = NSSelectorFromString(@"anchoredItems");
    SEL displayNameSel = NSSelectorFromString(@"displayName");
    SEL containedSel = NSSelectorFromString(@"containedItems");
    NSMutableSet *seenTitles = [NSMutableSet set];
    NSMutableArray *titles = [NSMutableArray array];

    for (id item in items) {
        if (![item respondsToSelector:anchoredSel]) continue;
        id anchoredRaw = ((id (*)(id, SEL))objc_msgSend)(item, anchoredSel);
        NSArray *anchored = nil;
        if ([anchoredRaw isKindOfClass:[NSSet class]]) {
            anchored = [(NSSet *)anchoredRaw allObjects];
        } else if ([anchoredRaw isKindOfClass:[NSArray class]]) {
            anchored = anchoredRaw;
        }
        if (anchored.count == 0) continue;

        for (id anchoredObject in anchored) {
            NSString *displayName = nil;
            @try {
                if ([anchoredObject respondsToSelector:displayNameSel]) {
                    id name = ((id (*)(id, SEL))objc_msgSend)(anchoredObject, displayNameSel);
                    if ([name isKindOfClass:[NSString class]]) displayName = name;
                }
            } @catch (NSException *e) {}
            if (!SpliceKitCaption_storylineNameMatches(displayName)) continue;

            if ([anchoredObject respondsToSelector:containedSel]) {
                NSArray *contained = ((id (*)(id, SEL))objc_msgSend)(anchoredObject, containedSel);
                if (![contained isKindOfClass:[NSArray class]]) continue;
                for (id sub in contained) {
                    if (SpliceKitCaption_isGeneratorTitleObject(sub) &&
                        ![seenTitles containsObject:sub]) {
                        [seenTitles addObject:sub];
                        [titles addObject:sub];
                    }
                }
            } else if (SpliceKitCaption_isGeneratorTitleObject(anchoredObject) &&
                       ![seenTitles containsObject:anchoredObject]) {
                [seenTitles addObject:anchoredObject];
                [titles addObject:anchoredObject];
            }
        }
    }

    if (titles.count > 1) {
        [titles sortUsingComparator:^NSComparisonResult(id a, id b) {
            double aStart = 0.0, aEnd = 0.0, bStart = 0.0, bEnd = 0.0;
            BOOL hasARange = SpliceKitCaption_effectiveRangeForObject(primary, a, &aStart, &aEnd);
            BOOL hasBRange = SpliceKitCaption_effectiveRangeForObject(primary, b, &bStart, &bEnd);
            if (hasARange && hasBRange) {
                if (aStart < bStart) return NSOrderedAscending;
                if (aStart > bStart) return NSOrderedDescending;
                if (aEnd < bEnd) return NSOrderedAscending;
                if (aEnd > bEnd) return NSOrderedDescending;
            } else if (hasARange) {
                return NSOrderedAscending;
            } else if (hasBRange) {
                return NSOrderedDescending;
            }
            uintptr_t aPtr = (uintptr_t)(__bridge void *)a;
            uintptr_t bPtr = (uintptr_t)(__bridge void *)b;
            if (aPtr < bPtr) return NSOrderedAscending;
            if (aPtr > bPtr) return NSOrderedDescending;
            return NSOrderedSame;
        }];
    }

    return titles;
}

static BOOL SpliceKitCaption_isGeneratorTitleObject(id obj) {
    if (!obj) return NO;
    NSString *className = NSStringFromClass([obj class]) ?: @"";
    if ([className containsString:@"Gap"]) return NO;
    if ([className containsString:@"Generator"]) return YES;
    SEL effectSel = NSSelectorFromString(@"effect");
    if ([obj respondsToSelector:effectSel]) {
        id effect = ((id (*)(id, SEL))objc_msgSend)(obj, effectSel);
        return (effect != nil);
    }
    return NO;
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

    id bestItem = nil;
    double bestStart = -DBL_MAX;

    for (id item in items) {
        double start = 0.0, end = 0.0;
        if (SpliceKitCaption_effectiveRangeForObject(primary, item, &start, &end)) {
            if (seconds >= start && seconds <= end) return item;
            if (start <= seconds && start > bestStart) {
                bestStart = start;
                bestItem = item;
            }
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

static BOOL SpliceKitCaption_applyGeneratorPositionYOffset(id titleObject, CGFloat yOffset) {
    if (!titleObject) return NO;

    @try {
        SEL effectSel = NSSelectorFromString(@"effect");
        id effect = [titleObject respondsToSelector:effectSel]
            ? ((id (*)(id, SEL))objc_msgSend)(titleObject, effectSel)
            : nil;
        id channelFolder = effect ? ((id (*)(id, SEL))objc_msgSend)(effect, NSSelectorFromString(@"channelFolder")) : nil;
        if (!channelFolder) return NO;

        Class pos3DClass = objc_getClass("CHChannelPosition3D");
        NSMutableArray *stack = [NSMutableArray arrayWithObject:channelFolder];
        while (stack.count > 0) {
            id node = stack.lastObject;
            [stack removeLastObject];
            if (pos3DClass && [node isKindOfClass:pos3DClass]) {
                NSString *name = ((id (*)(id, SEL))objc_msgSend)(node, NSSelectorFromString(@"name"));
                if ([name isEqualToString:@"Position"]) {
                    id parent = [node respondsToSelector:NSSelectorFromString(@"parent")]
                        ? ((id (*)(id, SEL))objc_msgSend)(node, NSSelectorFromString(@"parent")) : nil;
                    NSString *parentName = parent
                        ? ((id (*)(id, SEL))objc_msgSend)(parent, NSSelectorFromString(@"name")) : nil;
                    if ([parentName isEqualToString:@"Transform"]) {
                        id yChannel = SpliceKitCaption_subChannel(node, @"y");
                        return yChannel ? SpliceKitCaption_setChannelDouble(yChannel, yOffset) : NO;
                    }
                }
            }

            SEL childSel = NSSelectorFromString(@"children");
            if ([node respondsToSelector:childSel]) {
                NSArray *children = ((id (*)(id, SEL))objc_msgSend)(node, childSel);
                if ([children isKindOfClass:[NSArray class]]) {
                    [stack addObjectsFromArray:children];
                }
            }
        }
    } @catch (NSException *e) {
        SpliceKit_log(@"[Captions] Failed to restore generator position: %@", e.reason);
    }

    return NO;
}

// Legacy-style import: generate FCPXML with all captions as connected titles
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
    // Native pasteboard insertion modeled on the earlier caption workflow:
    // build a real FFAnchoredCollection storyline containing generator and gap
    // components, archive it to proFFPasteboardUTI, then pasteAnchored: it.

    SpliceKitCaptionStyle *s = self.style;
    int fdN = self.fdNum, fdD = self.fdDen;

    // Verify a timeline is open
    __block BOOL hasTimeline = NO;
    SpliceKit_executeOnMainThread(^{
        hasTimeline = (SpliceKit_getActiveTimelineModule() != nil);
    });
    if (!hasTimeline) {
        return @{@"error": @"No active timeline — open a project first"};
    }

    __block NSData *nativePasteboardData = nil;
    __block NSData *nativeArchiveData = nil;
    __block NSDictionary *outerPasteboard = nil;
    __block NSString *buildError = nil;
    __block NSString *buildStage = @"init";
    __block int titleCount = 0;
    NSString *nativePath = [NSTemporaryDirectory() stringByAppendingPathComponent:
        @"splicekit_captions_native_container.plist"];
    NSString *archivePath = [NSTemporaryDirectory() stringByAppendingPathComponent:
        @"splicekit_captions_native_container.archive"];
    NSString *xmlDebugPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
        @"splicekit_captions_native_container.xml"];
    NSString *debugPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
        @"splicekit_captions_native_debug.json"];
    NSMutableArray<NSMutableDictionary *> *segmentDebug = [NSMutableArray array];
    NSMutableArray<NSString *> *warnings = [NSMutableArray array];
    NSMutableDictionary *debugInfo = [@{
        @"mode": @"nativeStorylinePasteboard",
        @"templateMatch": kSpliceKitRuntimeCaptionTemplateMatch,
        @"timeline": @{
            @"frameDuration": [NSString stringWithFormat:@"%d/%d", fdN, fdD],
            @"frameRate": @(self.frameRate),
            @"width": @(self.videoWidth),
            @"height": @(self.videoHeight),
        },
        @"paths": @{
            @"nativePasteboardPath": nativePath,
            @"nativeArchivePath": archivePath,
            @"nativeXMLPath": xmlDebugPath,
            @"debugJSONPath": debugPath,
        },
        @"segmentCount": @(self.mutableSegments.count),
        @"segments": segmentDebug,
    } mutableCopy];
    NSArray<NSDictionary *> *runtimeEntries = [self runtimeEntriesForStyle:s];
    debugInfo[@"expectedTextCount"] = @(runtimeEntries.count);
    debugInfo[@"runtimeEntryCount"] = @(runtimeEntries.count);
    debugInfo[@"runtimeMode"] = (s.wordByWordHighlight && s.highlightColor != nil) ? @"wordHighlight" : @"segment";

    SpliceKit_log(@"[Captions][Native] Starting storyline build for %lu runtime entries from %lu grouped segments using %@",
                  (unsigned long)runtimeEntries.count,
                  (unsigned long)self.mutableSegments.count,
                  kSpliceKitRuntimeCaptionTemplateMatch);

    SpliceKit_executeOnMainThread(^{
        @try {
            buildStage = @"resolveCollectionClass";
            Class collectionClass = objc_getClass("FFAnchoredCollection");
            if (!collectionClass) {
                buildError = @"FFAnchoredCollection class not found";
                return;
            }
            SpliceKit_log(@"[Captions][Native] Using collection class %@", NSStringFromClass(collectionClass));

            buildStage = @"createStoryline";
            id storyline = ((id (*)(id, SEL, id))objc_msgSend)(
                ((id (*)(id, SEL))objc_msgSend)(collectionClass, @selector(alloc)),
                NSSelectorFromString(@"initWithDisplayName:"),
                kSpliceKitCaptionStorylineName);
            if (!storyline) {
                buildError = @"Failed to create anchored collection";
                return;
            }
            SpliceKit_log(@"[Captions][Native] Storyline created: %@", SpliceKitCaption_describeObject(storyline));

            SEL setIsSpineSel = NSSelectorFromString(@"setIsSpine:");
            if ([storyline respondsToSelector:setIsSpineSel]) {
                ((void (*)(id, SEL, BOOL))objc_msgSend)(storyline, setIsSpineSel, YES);
                SpliceKit_log(@"[Captions][Native] setIsSpine:YES");
            }
            SEL setContentCreatedSel = NSSelectorFromString(@"setContentCreated:");
            if ([storyline respondsToSelector:setContentCreatedSel]) {
                ((void (*)(id, SEL, id))objc_msgSend)(storyline, setContentCreatedSel, [NSDate date]);
                SpliceKit_log(@"[Captions][Native] setContentCreated");
            }
            SEL setAngleIDSel = NSSelectorFromString(@"setAngleID:");
            if ([storyline respondsToSelector:setAngleIDSel]) {
                ((void (*)(id, SEL, id))objc_msgSend)(storyline, setAngleIDSel, @"");
                SpliceKit_log(@"[Captions][Native] setAngleID:\"\"");
            }
            SEL setUnclippedStartSel = NSSelectorFromString(@"setUnclippedStart:");
            if ([storyline respondsToSelector:setUnclippedStartSel]) {
                SpliceKitCaption_CMTime zero = SpliceKitCaption_makeFrameAlignedCMTime(0, fdN, fdD);
                ((void (*)(id, SEL, SpliceKitCaption_CMTime))objc_msgSend)(storyline, setUnclippedStartSel, zero);
                SpliceKit_log(@"[Captions][Native] setUnclippedStart:%@", SpliceKitCaption_formatCMTime(zero));
            }

            SEL addContainedSel = NSSelectorFromString(@"addObjectToContainedItems:");
            if (![storyline respondsToSelector:addContainedSel]) {
                buildError = @"Anchored collection cannot accept contained items";
                return;
            }
            SpliceKit_log(@"[Captions][Native] Storyline responds to addObjectToContainedItems:");

            long long cursorFrames = 0;
            for (NSDictionary *entry in runtimeEntries) {
                NSUInteger segIndex = [entry[@"segmentIndex"] unsignedIntegerValue];
                SpliceKitCaptionSegment *seg = (segIndex < self.mutableSegments.count) ? self.mutableSegments[segIndex] : nil;
                NSNumber *activeWordIndex = entry[@"activeWordIndex"];
                NSString *trimmed = entry[@"text"];
                double entryStart = [entry[@"startTime"] doubleValue];
                double entryEnd = [entry[@"endTime"] doubleValue];
                double entryDuration = [entry[@"duration"] doubleValue];
                NSMutableDictionary *segInfo = [@{
                    @"segmentIndex": seg ? @(seg.segmentIndex) : @(segIndex),
                    @"startTime": @(entryStart),
                    @"endTime": @(entryEnd),
                    @"duration": @(entryDuration),
                    @"textPreview": SpliceKitCaption_previewText(trimmed, 120),
                    @"mode": entry[@"mode"] ?: @"segment",
                } mutableCopy];
                if ([activeWordIndex isKindOfClass:[NSNumber class]]) {
                    segInfo[@"activeWordIndex"] = activeWordIndex;
                }
                [segmentDebug addObject:segInfo];
                if (trimmed.length == 0) {
                    segInfo[@"status"] = @"skippedEmpty";
                    SpliceKit_log(@"[Captions][Native] Runtime entry for segment %lu skipped: empty text",
                                  (unsigned long)(seg ? seg.segmentIndex : segIndex));
                    continue;
                }

                long long startFrames = SpliceKitCaption_frameCountForSeconds(entryStart, fdN, fdD, YES);
                if (startFrames < cursorFrames) startFrames = cursorFrames;

                double rawDuration = entryDuration;
                if (rawDuration <= 0) rawDuration = (double)MAX(fdN, 1) / MAX(fdD, 1);
                long long durationFrames = SpliceKitCaption_frameCountForSeconds(rawDuration, fdN, fdD, NO);
                if (durationFrames <= 0) durationFrames = 1;
                long long gapFrames = MAX(startFrames - cursorFrames, 0);
                segInfo[@"startFrames"] = @(startFrames);
                segInfo[@"durationFrames"] = @(durationFrames);
                segInfo[@"gapFrames"] = @(gapFrames);
                segInfo[@"cursorFramesBefore"] = @(cursorFrames);
                segInfo[@"status"] = @"building";
                SpliceKit_log(@"[Captions][Native] Runtime entry segment=%lu word=%@ start=%.3f end=%.3f rawDur=%.3f startFrames=%lld gapFrames=%lld durationFrames=%lld text=\"%@\"",
                              (unsigned long)(seg ? seg.segmentIndex : segIndex),
                              [activeWordIndex isKindOfClass:[NSNumber class]] ? [activeWordIndex stringValue] : @"-",
                              entryStart, entryEnd, rawDuration,
                              startFrames, gapFrames, durationFrames,
                              SpliceKitCaption_previewText(trimmed, 100));

                if (startFrames > cursorFrames) {
                    buildStage = [NSString stringWithFormat:@"createGap(segment=%lu)", (unsigned long)(seg ? seg.segmentIndex : segIndex)];
                    id gap = SpliceKitCaption_newGapComponent(
                        SpliceKitCaption_makeFrameAlignedCMTime(startFrames - cursorFrames, fdN, fdD),
                        SpliceKitCaption_makeFrameAlignedCMTime(1, fdN, fdD));
                    if (!gap) {
                        segInfo[@"status"] = @"gapCreateFailed";
                        buildError = @"Failed to create gap component";
                        return;
                    }
                    segInfo[@"gapClass"] = NSStringFromClass([gap class]) ?: @"unknown";
                    SpliceKit_log(@"[Captions][Native] Runtime entry segment=%lu gap=%@ duration=%@",
                                  (unsigned long)(seg ? seg.segmentIndex : segIndex),
                                  SpliceKitCaption_describeObject(gap),
                                  SpliceKitCaption_formatCMTime(
                                      SpliceKitCaption_makeFrameAlignedCMTime(startFrames - cursorFrames, fdN, fdD)));
                    ((void (*)(id, SEL, id))objc_msgSend)(storyline, addContainedSel, gap);
                }

                buildStage = [NSString stringWithFormat:@"createGenerator(segment=%lu)", (unsigned long)(seg ? seg.segmentIndex : segIndex)];
                id generator = SpliceKitCaption_newRuntimeCaptionGenerator(trimmed, s, fdN, fdD, durationFrames);
                if (!generator) {
                    segInfo[@"status"] = @"generatorCreateFailed";
                    buildError = [NSString stringWithFormat:@"Failed to create runtime title generator for segment %lu",
                                  (unsigned long)(seg ? seg.segmentIndex : segIndex)];
                    return;
                }
                segInfo[@"generatorClass"] = NSStringFromClass([generator class]) ?: @"unknown";
                segInfo[@"generator"] = SpliceKitCaption_describeObject(generator);
                SpliceKit_log(@"[Captions][Native] Runtime entry segment=%lu generator=%@",
                              (unsigned long)(seg ? seg.segmentIndex : segIndex),
                              SpliceKitCaption_describeObject(generator));

                ((void (*)(id, SEL, id))objc_msgSend)(storyline, addContainedSel, generator);
                cursorFrames = startFrames + durationFrames;
                segInfo[@"cursorFramesAfter"] = @(cursorFrames);
                segInfo[@"status"] = @"added";
                titleCount++;
            }

            if (titleCount == 0) {
                buildStage = @"validateTitleCount";
                buildError = @"No non-empty caption segments to insert";
                return;
            }

            buildStage = @"archiveStoryline";
            NSDictionary *archiveRoot = @{@"objects": @[storyline]};
            NSError *archiveError = nil;
            nativeArchiveData = [NSKeyedArchiver archivedDataWithRootObject:archiveRoot
                                                      requiringSecureCoding:NO
                                                                      error:&archiveError];
            if (!nativeArchiveData) {
                buildError = archiveError.localizedDescription ?: @"Failed to archive storyline payload";
                return;
            }
            SpliceKit_log(@"[Captions][Native] Archived storyline payload (%lu bytes)",
                          (unsigned long)nativeArchiveData.length);

            buildStage = @"buildPasteboardPlist";
            outerPasteboard = @{
                @"ffpasteboardcopiedtypes": @{@"pb_anchoredObject": @{@"count": @1}},
                @"ffpasteboardobject": nativeArchiveData,
                @"kffmodelobjectIDs": @[],
            };
            NSError *plistError = nil;
            nativePasteboardData = [NSPropertyListSerialization dataWithPropertyList:outerPasteboard
                                                                              format:NSPropertyListBinaryFormat_v1_0
                                                                             options:0
                                                                               error:&plistError];
            if (!nativePasteboardData) {
                buildError = plistError.localizedDescription ?: @"Failed to serialize native pasteboard payload";
                return;
            }
            SpliceKit_log(@"[Captions][Native] Serialized pasteboard plist (%lu bytes)",
                          (unsigned long)nativePasteboardData.length);
        } @catch (NSException *e) {
            buildError = [NSString stringWithFormat:@"Native caption build failed at %@: %@",
                          buildStage, e.reason];
            SpliceKit_log(@"[Captions][Native] Exception during %@: %@\n%@",
                          buildStage, e.reason, [[e callStackSymbols] componentsJoinedByString:@"\n"]);
        }
    });

    debugInfo[@"buildStage"] = buildStage ?: @"unknown";
    debugInfo[@"titleCount"] = @(titleCount);
    if (buildError) debugInfo[@"buildError"] = buildError;
    if (warnings.count > 0) debugInfo[@"warnings"] = warnings;
    if (nativeArchiveData) debugInfo[@"nativeArchiveBytes"] = @(nativeArchiveData.length);
    if (nativePasteboardData) debugInfo[@"nativePasteboardBytes"] = @(nativePasteboardData.length);

    if (nativeArchiveData) {
        SpliceKitCaption_writeDataDebugFile(nativeArchiveData, archivePath, @"native archive");
    }
    if (outerPasteboard) {
        NSError *xmlError = nil;
        NSData *xmlData = [NSPropertyListSerialization dataWithPropertyList:outerPasteboard
                                                                     format:NSPropertyListXMLFormat_v1_0
                                                                    options:0
                                                                      error:&xmlError];
        if (xmlData) {
            SpliceKitCaption_writeDataDebugFile(xmlData, xmlDebugPath, @"native pasteboard XML");
        } else {
            NSString *warning = [NSString stringWithFormat:@"Failed to write XML debug plist: %@",
                                 xmlError.localizedDescription ?: @"unknown error"];
            [warnings addObject:warning];
            SpliceKit_log(@"[Captions][Debug] %@", warning);
        }
    }
    SpliceKitCaption_writeJSONDebugFile(debugInfo, debugPath, @"native caption debug JSON");

    if (!nativePasteboardData) {
        return @{
            @"error": buildError ?: @"Could not build native caption storyline",
            @"debugPath": debugPath,
            @"nativeArchivePath": archivePath,
            @"nativePasteboardPath": nativePath,
            @"nativeXMLPath": xmlDebugPath,
        };
    }

    SpliceKitCaption_writeDataDebugFile(nativePasteboardData, nativePath, @"native pasteboard binary plist");

    __block BOOL pasteHandled = NO;
    __block NSString *pasteTarget = nil;
    __block NSArray *pasteboardTypes = nil;
    __block NSUInteger removedExistingCaptionCollections = 0;

    SpliceKit_executeOnMainThread(^{
        id sequence = SpliceKitCaption_currentSequence();
        if (!sequence) return;
        removedExistingCaptionCollections += SpliceKitCaption_removeExistingCaptionStorylines(
            sequence, SpliceKitLegacyCaptionStorylineName());
        removedExistingCaptionCollections += SpliceKitCaption_removeExistingCaptionStorylines(
            sequence, kSpliceKitCaptionStorylineName);
        if (removedExistingCaptionCollections > 0) {
            SpliceKit_log(@"[Captions][Native] Removed %lu existing caption storyline(s) before paste",
                          (unsigned long)removedExistingCaptionCollections);
        }
    });
    debugInfo[@"removedExistingCaptionCollections"] = @(removedExistingCaptionCollections);

    // Write native pasteboard data, seek to start, then paste as a connected storyline.
    SpliceKit_executeOnMainThread(^{
        NSPasteboard *pb = [NSPasteboard generalPasteboard];
        [pb clearContents];
        [pb setData:nativePasteboardData forType:@"com.apple.flexo.proFFPasteboardUTI"];
        pasteboardTypes = pb.types ?: @[];
        id target = [[NSApplication sharedApplication]
            targetForAction:NSSelectorFromString(@"pasteAnchored:") to:nil from:nil];
        pasteTarget = SpliceKitCaption_describeObject(target);
        SpliceKit_log(@"[Captions] Wrote %lu bytes native storyline payload to pasteboard",
                      (unsigned long)nativePasteboardData.length);
        SpliceKit_log(@"[Captions][Native] pasteboard types=%@ targetForPasteAnchored=%@",
                      pasteboardTypes, pasteTarget ?: @"(nil)");

        id tm = SpliceKit_getActiveTimelineModule();
        if (tm) {
            SpliceKitCaption_CMTime zeroTime = SpliceKitCaption_makeFrameAlignedCMTime(0, fdN, fdD);
            SEL setSel = NSSelectorFromString(@"setPlayheadTime:");
            if ([tm respondsToSelector:setSel]) {
                ((void (*)(id, SEL, SpliceKitCaption_CMTime))objc_msgSend)(tm, setSel, zeroTime);
                SpliceKit_log(@"[Captions][Native] Set playhead time to %@", SpliceKitCaption_formatCMTime(zeroTime));
            }
        }
        [[NSApplication sharedApplication] sendAction:NSSelectorFromString(@"deselectAll:")
                                                   to:nil from:nil];
    });

    [NSThread sleepForTimeInterval:0.2];

    SpliceKit_executeOnMainThread(^{
        pasteHandled = [[NSApplication sharedApplication]
            sendAction:NSSelectorFromString(@"pasteAnchored:")
                    to:nil from:nil];
    });

    [NSThread sleepForTimeInterval:0.6];

    SpliceKit_log(@"[Captions] Paste as connected: %@", pasteHandled ? @"YES" : @"NO");
    if (!pasteHandled) {
        SpliceKit_log(@"[Captions][Native] pasteAnchored returned NO. Pasteboard types at paste time=%@ target=%@",
                      pasteboardTypes ?: @[], pasteTarget ?: @"(nil)");
    }

    [NSThread sleepForTimeInterval:0.3];
    __block int verifiedTitleCount = 0;
    __block int positionAppliedCount = 0;
    __block NSString *verifiedText = nil;
    __block double verifiedFontSize = 0;
    __block NSString *verifiedFontFamily = nil;
    __block NSUInteger primaryItemCount = 0;
    __block NSUInteger anchoredContainerCount = 0;
    __block NSUInteger textAppliedCount = 0;
    __block NSUInteger textSegmentCursor = 0;
    CGFloat yOffset = [self yOffsetForStyle:s];
    BOOL needsPosition = (s.position != SpliceKitCaptionPositionCenter || s.customYOffset != 0);

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
                primaryItemCount = items.count;
                SpliceKit_log(@"[Captions][Native] Post-paste primary containedItems=%lu",
                              (unsigned long)items.count);

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
                    anchoredContainerCount += anchored.count;
                    SpliceKit_log(@"[Captions][Native] Item %@ has %lu anchored items",
                                  SpliceKitCaption_describeObject(item),
                                  (unsigned long)anchored.count);

                    for (id conn in anchored) {
                        // Connected item may be a storyline (FFAnchoredCollection)
                        // containing titles, or an individual title. Collect all
                        // titles to process.
                        NSMutableArray *titlesToProcess = [NSMutableArray array];
                        SEL containedSel = NSSelectorFromString(@"containedItems");
                        if ([conn respondsToSelector:containedSel]) {
                            NSArray *contained = ((id (*)(id, SEL))objc_msgSend)(conn, containedSel);
                            if ([contained isKindOfClass:[NSArray class]]) {
                                SpliceKit_log(@"[Captions][Native] Connected container %@ contains %lu items",
                                              SpliceKitCaption_describeObject(conn),
                                              (unsigned long)contained.count);
                                for (id sub in contained) {
                                    if (SpliceKitCaption_isGeneratorTitleObject(sub)) {
                                        [titlesToProcess addObject:sub];
                                    }
                                }
                            }
                        }
                        // If no contained items (or not a collection), only process
                        // standalone generator titles. Skip unrelated anchored media.
                        if (titlesToProcess.count == 0 && SpliceKitCaption_isGeneratorTitleObject(conn)) {
                            [titlesToProcess addObject:conn];
                        }

                        for (id title in titlesToProcess) {
                            verifiedTitleCount++;
                            NSDictionary *entry = (textSegmentCursor < runtimeEntries.count)
                                ? runtimeEntries[textSegmentCursor]
                                : nil;
                            NSString *expectedText = entry[@"text"];
                            NSNumber *activeWordIndex = entry[@"activeWordIndex"];
                            NSArray *displayWords = [entry[@"words"] isKindOfClass:[NSArray class]] ? entry[@"words"] : nil;
                            textSegmentCursor++;

                            // Reload Motion template
                            @try {
                                SEL effectSel = NSSelectorFromString(@"effect");
                                if ([title respondsToSelector:effectSel]) {
                                    id eff = ((id (*)(id, SEL))objc_msgSend)(title, effectSel);
                                    SEL reloadSel = NSSelectorFromString(@"reloadMicaDocument");
                                    if (eff && [eff respondsToSelector:reloadSel]) {
                                        ((void (*)(id, SEL))objc_msgSend)(eff, reloadSel);
                                    }
                                }
                            } @catch (NSException *e) {}

                            if (expectedText.length > 0) {
                                @try {
                                    BOOL didApplyText = NO;
                                    if ([activeWordIndex isKindOfClass:[NSNumber class]] && displayWords.count > 0) {
	                                        NSAttributedString *highlighted =
	                                            SpliceKitCaption_makeHighlightedGeneratorAttributedStringFromWords(
	                                                displayWords, [activeWordIndex unsignedIntegerValue], s);
                                        didApplyText = SpliceKitCaption_setGeneratorAttributedText(title, highlighted);
                                    } else {
                                        didApplyText = SpliceKitCaption_setGeneratorChannelText(title, expectedText, s);
                                    }
                                    if (didApplyText) {
                                        textAppliedCount++;
                                    }
                                } @catch (NSException *e) {
                                    SpliceKit_log(@"[Captions][Native] Failed to apply text to %@: %@",
                                                  SpliceKitCaption_describeObject(title), e.reason);
                                }
                            }

                            // Set position via Motion template channel hierarchy
                            if (needsPosition) {
                                if (SpliceKitCaption_applyGeneratorPositionYOffset(title, yOffset)) {
                                    positionAppliedCount++;
                                }
                            }

                            // Verify first title only
                            if (verifiedText) continue;
                            @try {
                                SEL effectSel = NSSelectorFromString(@"effect");
                                id genEffect = [title respondsToSelector:effectSel]
                                    ? ((id (*)(id, SEL))objc_msgSend)(title, effectSel) : nil;
                                id cf = genEffect ? ((id (*)(id, SEL))objc_msgSend)(genEffect,
                                    NSSelectorFromString(@"channelFolder")) : nil;
                                if (!cf) continue;
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
                            } @catch (NSException *e) {}
                        }
                    }
                }
            } @catch (NSException *e) {
                SpliceKit_log(@"[Captions] Post-process exception: %@\n%@",
                              e.reason, [[e callStackSymbols] componentsJoinedByString:@"\n"]);
            }
        });
    }

    SpliceKit_log(@"[Captions] Verified: %d connected titles, text='%@', fontSize=%.1f, position=%d",
                  verifiedTitleCount, verifiedText ?: @"(none)", verifiedFontSize, positionAppliedCount);
    debugInfo[@"pasteHandled"] = @(pasteHandled);
    debugInfo[@"pasteTarget"] = pasteTarget ?: @"(nil)";
    if (pasteboardTypes) debugInfo[@"pasteboardTypes"] = pasteboardTypes;
    debugInfo[@"postPastePrimaryItemCount"] = @(primaryItemCount);
    debugInfo[@"postPasteAnchoredContainerCount"] = @(anchoredContainerCount);
    debugInfo[@"removedExistingCaptionCollections"] = @(removedExistingCaptionCollections);
    debugInfo[@"verifiedTitleCount"] = @(verifiedTitleCount);
    debugInfo[@"textAppliedCount"] = @(textAppliedCount);
    debugInfo[@"positionAppliedCount"] = @(positionAppliedCount);
    if (verifiedText) {
        debugInfo[@"verification"] = @{
            @"text": verifiedText,
            @"fontSize": @(verifiedFontSize),
            @"fontFamily": verifiedFontFamily ?: @"unknown",
        };
    }
    if (verifiedTitleCount == 0 && pasteHandled) {
        NSString *warning = @"pasteAnchored returned YES but verification found zero connected titles";
        [warnings addObject:warning];
        SpliceKit_log(@"[Captions][Native] %@", warning);
    }
    if (warnings.count > 0) debugInfo[@"warnings"] = warnings;
    SpliceKitCaption_writeJSONDebugFile(debugInfo, debugPath, @"native caption debug JSON");

    NSMutableDictionary *result = [@{
        @"status": pasteHandled ? @"ok" : @"error",
        @"insertedCount": @(titleCount),
        @"pasteHandled": @(pasteHandled),
        @"message": [NSString stringWithFormat:@"Added %d captions to timeline", titleCount],
        @"importMethod": @"nativeStorylinePasteboard",
        @"nativePasteboardPath": nativePath,
        @"nativeArchivePath": archivePath,
        @"nativeXMLPath": xmlDebugPath,
        @"debugPath": debugPath,
    } mutableCopy];

    if (!pasteHandled) {
        result[@"error"] = @"pasteAsConnected was not handled — captions may not be on timeline";
    }
    if (warnings.count > 0) {
        result[@"warnings"] = [warnings copy];
    }
    if (removedExistingCaptionCollections > 0) {
        result[@"removedExistingCaptionCollections"] = @(removedExistingCaptionCollections);
    }
    if (textAppliedCount > 0) {
        result[@"textAppliedCount"] = @(textAppliedCount);
    }
    if (needsPosition && positionAppliedCount > 0) {
        result[@"positionApplied"] = @(positionAppliedCount);
        result[@"positionY"] = @(yOffset);
    }
    if (verifiedText) {
        result[@"verification"] = @{
            @"text": verifiedText,
            @"fontSize": @(verifiedFontSize),
            @"fontFamily": verifiedFontFamily ?: @"unknown",
            @"connectedTitleCount": @(verifiedTitleCount),
        };
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
    return [self yOffsetForStyle:self.style];
}

// Content Position Y for the FCPXML <param> element (Motion template coordinate space).
// This is different from yOffsetForPosition which uses FFCutawayEffects transform space.
// The legacy template uses height * 0.7 for bottom position in this coordinate space.
- (CGFloat)contentPositionYForFCPXML {
    switch (self.style.position) {
        case SpliceKitCaptionPositionBottom: return -(self.videoHeight * 0.7);
        case SpliceKitCaptionPositionCenter: return 0;
        case SpliceKitCaptionPositionTop: return (self.videoHeight * 0.7);
        case SpliceKitCaptionPositionCustom: return self.style.customYOffset * 2.0;
    }
    return -(self.videoHeight * 0.7);
}

// Returns FCPXML <param> string for Content Position, or empty string for center.
- (NSString *)contentPositionParamXML {
    CGFloat y = [self contentPositionYForFCPXML];
    if (fabs(y) < 1.0) return @""; // center — no param needed
    return [NSString stringWithFormat:
        @"<param name=\"Content Position\" key=\"9999/10003/1/100/101\" value=\"0 %.0f\"/>\n", y];
}

- (NSString *)animationXMLForSegmentDuration:(double)segDur isFirstWord:(BOOL)isFirst isLastWord:(BOOL)isLast {
    return @"";
}

#pragma mark - Word-Progress Caption Generation

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

// Build a base64 JSON blob with per-word timing data for the legacy re-edit payload.
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
            @"WordByWord": @YES, @"TemplateName": @"Basic Title",
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
// Only emits the 3 params used by the legacy word-progress title format
// (Position, Opacity, Custom Speed).
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

    // Position Y from the legacy moti height mapping (motiHeight * posY / 100)
    CGFloat posY = -756;  // default lower-third position matching the legacy template
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

    // Hidden text (base64 JSON blob for re-editing)
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

// Generate a single segment-level title with an explicit offset in the spine.
// This avoids spacer gaps and produces the same kind of compact connected
// storyline structure that FCP serializes for dragged/pasted title storylines.
- (NSString *)segmentTitleXMLForSegment:(SpliceKitCaptionSegment *)seg
                              tsCounter:(int *)tsCounter
                                 indent:(NSString *)indent
                                   lane:(NSString *)lane {
    SpliceKitCaptionStyle *s = self.style;
    int fdN = self.fdNum, fdD = self.fdDen;
    double segDur = MAX(seg.duration, 0.1);
    NSString *text = s.allCaps ? [seg.text uppercaseString] : seg.text;
    NSString *offsetStr = SpliceKitCaption_durRational(seg.startTime, fdN, fdD);
    NSString *durStr = SpliceKitCaption_durRational(segDur, fdN, fdD);
    NSString *tsID = [NSString stringWithFormat:@"ts%d", (*tsCounter)++];
    NSString *tsDef = [self textStyleXMLWithID:tsID color:s.textColor isHighlight:NO];
    NSString *laneAttr = lane ? [NSString stringWithFormat:@" lane=\"%@\"", lane] : @"";

    NSMutableString *xml = [NSMutableString string];
    [xml appendFormat:@"%@<title ref=\"r2\"%@ offset=\"%@\" name=\"Cap%03lu\" duration=\"%@\" start=\"3600s\">\n",
        indent, laneAttr, offsetStr, (unsigned long)seg.segmentIndex + 1, durStr];
    NSString *posParam = [self contentPositionParamXML];
    if (posParam.length > 0) [xml appendFormat:@"%@    %@", indent, posParam];
    [xml appendFormat:@"%@    <text><text-style ref=\"%@\">%@</text-style></text>\n",
        indent, tsID, SpliceKitCaption_escapeXML(text)];
    [xml appendFormat:@"%@    %@\n", indent, tsDef];
    [xml appendFormat:@"%@</title>\n", indent];
    return xml;
}

// Generate per-word highlight titles for a segment using Basic Title.
// One <title> per word timing — all words visible, active word highlighted.
- (NSString *)wordHighlightTitlesForSegment:(SpliceKitCaptionSegment *)seg
                                  tsCounter:(int *)tsCounter
                                     indent:(NSString *)indent
                                       lane:(NSString *)lane {
    SpliceKitCaptionStyle *s = self.style;
    int fdN = self.fdNum, fdD = self.fdDen;
    NSArray<SpliceKitTranscriptWord *> *words = seg.words;
    if (words.count == 0) return @"";

    // Resolve font family (FCPXML needs family name, not PostScript name)
    NSString *fontName = s.font ?: @"Helvetica";
    NSFont *resolvedFont = [NSFont fontWithName:fontName size:s.fontSize];
    NSString *familyName = resolvedFont ? resolvedFont.familyName : fontName;
    if ([familyName containsString:@"-"])
        familyName = [familyName componentsSeparatedByString:@"-"].firstObject;

    // Basic Title's coordinate system renders text larger than the custom template.
    // Scale to ~2/3 for equivalent visual size at 1080p.
    CGFloat fontSize = round(s.fontSize * 0.67);

    NSColor *hilite = s.highlightColor ?: [NSColor yellowColor];
    NSString *highlightColorStr = SpliceKitCaption_colorToFCPXML(hilite);
    NSString *baseColorStr = SpliceKitCaption_colorToFCPXML(s.textColor);

    NSMutableString *xml = [NSMutableString string];
    NSString *laneAttr = lane ? [NSString stringWithFormat:@" lane=\"%@\"", lane] : @"";

    for (NSUInteger i = 0; i < words.count; i++) {
        SpliceKitTranscriptWord *word = words[i];

        // Title starts when this word starts, ends when next word starts (or segment ends)
        double titleStart = word.startTime;
        double titleEnd = (i + 1 < words.count) ? words[i + 1].startTime : seg.endTime;
        double titleDur = MAX(titleEnd - titleStart, (double)fdN / fdD); // at least 1 frame

        NSString *offsetStr = SpliceKitCaption_durRational(titleStart, fdN, fdD);
        NSString *durStr = SpliceKitCaption_durRational(titleDur, fdN, fdD);

        int tsBase = (*tsCounter);
        NSString *tsH = [NSString stringWithFormat:@"ts%d", tsBase];
        NSString *tsB = [NSString stringWithFormat:@"ts%d", tsBase + 1];
        *tsCounter = tsBase + 2;

        [xml appendFormat:@"%@<title ref=\"r2\"%@ offset=\"%@\" name=\"Cap%03lu-%lu\" "
            @"duration=\"%@\" start=\"3600s\">\n",
            indent, laneAttr, offsetStr,
            (unsigned long)seg.segmentIndex + 1, (unsigned long)i + 1, durStr];

        // Position via Motion template param — must come BEFORE <text> in FCPXML.
        // Key 9999/10003/1/100/101 = Content Position on the Widget layer.
        [xml appendFormat:@"%@    <param name=\"Position\" key=\"9999/10003/1/100/101\" value=\"0 -447\"/>\n", indent];

        // Text with per-word highlighting: only the active word gets the
        // highlight color; all other words stay at the base color.
        [xml appendFormat:@"%@    <text>\n", indent];
        for (NSUInteger j = 0; j < words.count; j++) {
            NSString *w = s.allCaps ? [words[j].text uppercaseString] : words[j].text;
            NSString *ref = (j == i) ? tsH : tsB;
            NSString *space = (j > 0) ? @" " : @"";
            [xml appendFormat:@"%@        <text-style ref=\"%@\">%@%@</text-style>\n",
                indent, ref, space, SpliceKitCaption_escapeXML(w)];
        }
        [xml appendFormat:@"%@    </text>\n", indent];

        // Drop shadow: black, 70% opacity, blur 2.43, distance 5, angle 315°
        // Shadow offset from polar: 5*cos(315°)=3.54, 5*sin(315°)=-3.54
        NSString *shadowAttrs = @" shadowColor=\"0 0 0 0.7\" shadowOffset=\"3.54 -3.54\" shadowBlurRadius=\"2.43\"";

        // Highlight text-style
        [xml appendFormat:@"%@    <text-style-def id=\"%@\">\n", indent, tsH];
        [xml appendFormat:@"%@        <text-style font=\"%@\" fontSize=\"%.0f\" "
            @"fontColor=\"%@\" alignment=\"center\"%@/>\n",
            indent, SpliceKitCaption_escapeXML(familyName), fontSize, highlightColorStr, shadowAttrs];
        [xml appendFormat:@"%@    </text-style-def>\n", indent];

        // Base text-style
        [xml appendFormat:@"%@    <text-style-def id=\"%@\">\n", indent, tsB];
        [xml appendFormat:@"%@        <text-style font=\"%@\" fontSize=\"%.0f\" "
            @"fontColor=\"%@\" alignment=\"center\"%@/>\n",
            indent, SpliceKitCaption_escapeXML(familyName), fontSize, baseColorStr, shadowAttrs];
        [xml appendFormat:@"%@    </text-style-def>\n", indent];

        [xml appendFormat:@"%@</title>\n", indent];
    }

    return xml;
}

// Generate a single title for one word position in a segment (spine-only format, no lane).
- (NSString *)wordHighlightTitleForSegment:(SpliceKitCaptionSegment *)seg
                                 wordIndex:(NSUInteger)i
                                 tsCounter:(int *)tsCounter
                                    indent:(NSString *)indent
                                  duration:(double)titleDur {
    SpliceKitCaptionStyle *s = self.style;
    int fdN = self.fdNum, fdD = self.fdDen;
    NSArray<SpliceKitTranscriptWord *> *words = seg.words;
    if (i >= words.count) return @"";

    NSString *fontName = s.font ?: @"Helvetica";
    NSFont *resolvedFont = [NSFont fontWithName:fontName size:s.fontSize];
    NSString *familyName = resolvedFont ? resolvedFont.familyName : fontName;
    if ([familyName containsString:@"-"])
        familyName = [familyName componentsSeparatedByString:@"-"].firstObject;

    CGFloat fontSize = round(s.fontSize * 0.67);
    NSColor *hilite = s.highlightColor ?: [NSColor yellowColor];
    NSString *highlightColorStr = SpliceKitCaption_colorToFCPXML(hilite);
    NSString *baseColorStr = SpliceKitCaption_colorToFCPXML(s.textColor);
    NSString *durStr = SpliceKitCaption_durRational(titleDur, fdN, fdD);
    NSString *shadowAttrs = @" shadowColor=\"0 0 0 0.7\" shadowOffset=\"3.54 -3.54\" shadowBlurRadius=\"2.43\"";

    int tsBase = (*tsCounter);
    NSString *tsH = [NSString stringWithFormat:@"ts%d", tsBase];
    NSString *tsB = [NSString stringWithFormat:@"ts%d", tsBase + 1];
    *tsCounter = tsBase + 2;

    NSMutableString *xml = [NSMutableString string];

    [xml appendFormat:@"%@<title ref=\"r2\" name=\"Cap%03lu-%lu\" duration=\"%@\" start=\"3600s\">\n",
        indent, (unsigned long)seg.segmentIndex + 1, (unsigned long)i + 1, durStr];

    // Content Position param — baked into FCPXML so every title gets it
    NSString *posParam = [self contentPositionParamXML];
    if (posParam.length > 0) [xml appendFormat:@"%@    %@", indent, posParam];
    // NOTE: Do NOT add <adjust-transform> here — it crashes FCP's FCPXML parser
    // when combined with multiple <text-style ref> elements (word-highlight mode).
    // Content Position param handles positioning for word-highlight titles.

    // Text with per-word highlighting
    [xml appendFormat:@"%@    <text>\n", indent];
    for (NSUInteger j = 0; j < words.count; j++) {
        NSString *w = s.allCaps ? [words[j].text uppercaseString] : words[j].text;
        NSString *ref = (j == i) ? tsH : tsB;
        NSString *space = (j > 0) ? @" " : @"";
        [xml appendFormat:@"%@        <text-style ref=\"%@\">%@%@</text-style>\n",
            indent, ref, space, SpliceKitCaption_escapeXML(w)];
    }
    [xml appendFormat:@"%@    </text>\n", indent];

    // Text style defs with drop shadow
    [xml appendFormat:@"%@    <text-style-def id=\"%@\">\n", indent, tsH];
    [xml appendFormat:@"%@        <text-style font=\"%@\" fontSize=\"%.0f\" "
        @"fontColor=\"%@\" alignment=\"center\"%@/>\n",
        indent, SpliceKitCaption_escapeXML(familyName), fontSize, highlightColorStr, shadowAttrs];
    [xml appendFormat:@"%@    </text-style-def>\n", indent];
    [xml appendFormat:@"%@    <text-style-def id=\"%@\">\n", indent, tsB];
    [xml appendFormat:@"%@        <text-style font=\"%@\" fontSize=\"%.0f\" "
        @"fontColor=\"%@\" alignment=\"center\"%@/>\n",
        indent, SpliceKitCaption_escapeXML(familyName), fontSize, baseColorStr, shadowAttrs];
    [xml appendFormat:@"%@    </text-style-def>\n", indent];

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
    // Use FCP's built-in Basic Title — available on all installations.
    [xml appendString:@"        <effect id=\"r2\" name=\"Basic Title\" "
        @"uid=\".../Titles.localized/Bumper:Opener.localized/Basic Title.localized/Basic Title.moti\"/>\n"];
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

// Build word-level FCPXML using the legacy word-progress approach:
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
    [xml appendString:@"        <effect id=\"r2\" name=\"Basic Title\" "
        @"uid=\".../Titles.localized/Bumper:Opener.localized/Basic Title.localized/Basic Title.moti\"/>\n"];
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
    [self ensurePersistedStateLoaded];

    SpliceKit_log(@"[Captions] generateCaptions called. Words: %lu, Segments: %lu",
                  (unsigned long)self.mutableWords.count, (unsigned long)self.mutableSegments.count);

    // Auto-transcribe if no words yet
    if (self.mutableWords.count == 0) {
        SpliceKit_log(@"[Captions] Auto-transcribing timeline...");
        if (self.panel) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.statusLabel.stringValue = @"Transcribing timeline...";
            });
        }

        // Run Parakeet transcription synchronously (we're already off main thread)
        [self performCaptionTranscription];

        // Check if transcription produced results
        if (self.status == SpliceKitCaptionStatusError) {
            return @{@"error": self.errorMessage ?: @"Transcription failed"};
        }
    }

    if (self.mutableWords.count == 0) {
        self.status = SpliceKitCaptionStatusError;
        self.errorMessage = @"No words — transcription produced no results";
        self.lastGenerateResult = @{@"status": @"error", @"error": self.errorMessage};
        return @{@"error": @"No words — transcription produced no results"};
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

    // Flat spine with absolute title offsets.
    // No gap containers, no spacer clips, no lanes — just titles directly in the spine.
    for (SpliceKitCaptionSegment *seg in self.mutableSegments) {
        [xml appendString:[self segmentTitleXMLForSegment:seg
                                                tsCounter:&tsCounter
                                                   indent:@"        "
                                                     lane:nil]];
        titleCount++;
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
    NSUInteger removedExistingCaptionCollections = directResult[@"removedExistingCaptionCollections"]
        ? [directResult[@"removedExistingCaptionCollections"] unsignedIntegerValue]
        : 0;
    BOOL generatedWordLevelTitles = (insertedCount > (NSUInteger)titleCount &&
                                     insertedCount == self.mutableWords.count &&
                                     self.mutableWords.count > self.mutableSegments.count);
    NSString *successMsg = nil;
    if (generatedWordLevelTitles) {
        successMsg = [NSString stringWithFormat:@"Added %lu word-level captions from %d grouped segments",
                      (unsigned long)insertedCount, titleCount];
    } else {
        successMsg = insertedCount == (NSUInteger)titleCount
            ? [NSString stringWithFormat:@"Added %lu captions to timeline", (unsigned long)insertedCount]
            : [NSString stringWithFormat:@"Added %lu of %d captions to timeline",
                (unsigned long)insertedCount, titleCount];
    }
    if (removedExistingCaptionCollections > 0) {
        if (generatedWordLevelTitles) {
            successMsg = [NSString stringWithFormat:
                @"Replaced previous captions and added %lu word-level captions from %d grouped segments",
                (unsigned long)insertedCount, titleCount];
        } else {
            successMsg = insertedCount == (NSUInteger)titleCount
                ? [NSString stringWithFormat:@"Replaced previous captions and added %lu captions to timeline",
                    (unsigned long)insertedCount]
                : [NSString stringWithFormat:@"Replaced previous captions and added %lu of %d captions to timeline",
                    (unsigned long)insertedCount, titleCount];
        }
    }
    NSString *statusMsg = directOK
        ? successMsg
        : [NSString stringWithFormat:@"Caption insert failed — %@",
            directResult[@"error"] ?: [NSString stringWithFormat:@"FCPXML exported to %@", xmlPath]];
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
    if (directResult[@"removedExistingCaptionCollections"]) {
        result[@"removedExistingCaptionCollections"] = directResult[@"removedExistingCaptionCollections"];
    }
    if (directResult[@"textAppliedCount"]) result[@"textAppliedCount"] = directResult[@"textAppliedCount"];
    if (directResult[@"positionApplied"]) result[@"positionApplied"] = directResult[@"positionApplied"];
    if (directResult[@"positionY"]) result[@"positionY"] = directResult[@"positionY"];
    if (directResult[@"debugPath"]) result[@"debugPath"] = directResult[@"debugPath"];
    if (!directOK && directResult[@"error"]) result[@"error"] = directResult[@"error"];
    self.lastGenerateResult = [result copy];
    if (directOK && insertedCount > 0) {
        [self persistGeneratedCaptionStateWithRuntimeEntries:[self runtimeEntriesForStyle:s] style:s];
    }
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
    [self ensurePersistedStateLoaded];

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
    [self ensurePersistedStateLoaded];

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

#pragma mark - Persistence Restore

- (void)restorePersistedStateForCurrentSequenceIfNeeded {
    if (![NSThread isMainThread]) {
        SpliceKit_executeOnMainThread(^{
            [self restorePersistedStateForCurrentSequenceIfNeeded];
        });
        return;
    }

    id sequence = SpliceKitCaption_currentSequence();
    if (!sequence) return;

    NSDictionary *state = SpliceKit_loadSequenceState(sequence);
    NSDictionary *captions = [state[@"captions"] isKindOfClass:[NSDictionary class]] ? state[@"captions"] : nil;
    NSDictionary *transcript = [state[@"transcript"] isKindOfClass:[NSDictionary class]] ? state[@"transcript"] : nil;
    NSString *sequenceKey = [state[@"sequenceIdentity"] isKindOfClass:[NSDictionary class]]
        ? state[@"sequenceIdentity"][@"cacheKey"] : nil;
    if (!captions && !transcript) return;
    if (sequenceKey.length > 0 &&
        [self.lastRestoredSequenceKey isEqualToString:sequenceKey] &&
        self.mutableWords.count > 0) {
        return;
    }

    self.suppressPersistenceWrites = YES;

    NSDictionary *draftStyle = [captions[@"draftStyle"] isKindOfClass:[NSDictionary class]] ? captions[@"draftStyle"] : nil;
    if (draftStyle) {
        _style = [SpliceKitCaptionStyle fromDictionary:draftStyle];
    }

    NSDictionary *draftGrouping = [captions[@"draftGrouping"] isKindOfClass:[NSDictionary class]] ? captions[@"draftGrouping"] : nil;
    if (draftGrouping) {
        NSString *mode = draftGrouping[@"mode"];
        if ([mode isEqualToString:@"sentence"]) self.groupingMode = SpliceKitCaptionGroupingBySentence;
        else if ([mode isEqualToString:@"time"]) self.groupingMode = SpliceKitCaptionGroupingByTime;
        else if ([mode isEqualToString:@"chars"]) self.groupingMode = SpliceKitCaptionGroupingByCharCount;
        else if ([mode isEqualToString:@"social"]) self.groupingMode = SpliceKitCaptionGroupingSocial;
        else self.groupingMode = SpliceKitCaptionGroupingByWordCount;

        if (draftGrouping[@"maxWords"]) self.maxWordsPerSegment = [draftGrouping[@"maxWords"] unsignedIntegerValue];
        if (draftGrouping[@"maxChars"]) self.maxCharsPerSegment = [draftGrouping[@"maxChars"] unsignedIntegerValue];
        if (draftGrouping[@"maxSeconds"]) self.maxSecondsPerSegment = [draftGrouping[@"maxSeconds"] doubleValue];
    }

    NSArray *wordDicts = [transcript[@"words"] isKindOfClass:[NSArray class]] ? transcript[@"words"] : nil;
    if (wordDicts.count > 0) {
        @synchronized (self.mutableWords) {
            [self.mutableWords removeAllObjects];
            for (NSDictionary *wordDict in wordDicts) {
                SpliceKitTranscriptWord *word = SpliceKitCaption_transcriptWordFromDictionary(wordDict);
                if (word) [self.mutableWords addObject:word];
            }
            [self.mutableWords sortUsingComparator:^NSComparisonResult(SpliceKitTranscriptWord *a, SpliceKitTranscriptWord *b) {
                if (a.startTime < b.startTime) return NSOrderedAscending;
                if (a.startTime > b.startTime) return NSOrderedDescending;
                return NSOrderedSame;
            }];
            for (NSUInteger i = 0; i < self.mutableWords.count; i++) {
                self.mutableWords[i].wordIndex = i;
            }
        }
        self.status = SpliceKitCaptionStatusReady;
        self.errorMessage = nil;
        if (transcript[@"frameRate"]) self.frameRate = [transcript[@"frameRate"] doubleValue];
        [self regroupSegments];
    }

    self.lastRestoredSequenceKey = sequenceKey;
    if (self.panel) {
        [self syncUIFromStyle];
        if (self.mutableWords.count > 0) {
            self.statusLabel.stringValue = [NSString stringWithFormat:@"%lu words, %lu segments (restored)",
                (unsigned long)self.mutableWords.count, (unsigned long)self.mutableSegments.count];
        }
    }

    self.suppressPersistenceWrites = NO;
}

- (void)repairPersistedCaptionsOnCurrentSequenceIfNeeded {
    if (![NSThread isMainThread]) {
        SpliceKit_executeOnMainThread(^{
            [self repairPersistedCaptionsOnCurrentSequenceIfNeeded];
        });
        return;
    }

    id sequence = SpliceKitCaption_currentSequence();
    if (!sequence) {
        SpliceKit_log(@"[Captions] Persisted caption repair skipped: no active sequence");
        return;
    }

    NSDictionary *state = SpliceKit_loadSequenceState(sequence);
    NSDictionary *captions = [state[@"captions"] isKindOfClass:[NSDictionary class]] ? state[@"captions"] : nil;
    NSArray *runtimeEntries = [captions[@"generatedRuntimeEntries"] isKindOfClass:[NSArray class]]
        ? captions[@"generatedRuntimeEntries"] : nil;
    NSDictionary *styleDict = [captions[@"generatedStyle"] isKindOfClass:[NSDictionary class]]
        ? captions[@"generatedStyle"] : nil;
    NSString *sequenceKey = [state[@"sequenceIdentity"] isKindOfClass:[NSDictionary class]]
        ? state[@"sequenceIdentity"][@"cacheKey"] : nil;
    BOOL panelVisible = (self.panel && self.panel.isVisible);
    SpliceKit_log(@"[Captions] Persisted caption repair begin: sequenceKey=%@ panelVisible=%@ runtimeEntries=%lu",
                  sequenceKey ?: @"<nil>",
                  panelVisible ? @"YES" : @"NO",
                  (unsigned long)runtimeEntries.count);
    if (!panelVisible) {
        SpliceKit_log(@"[Captions] Persisted caption repair skipped: panel not visible");
        return;
    }
    if (runtimeEntries.count == 0 || !styleDict) {
        SpliceKit_log(@"[Captions] Persisted caption repair skipped: runtime entries or style missing");
        return;
    }
    if (panelVisible) {
        if (sequenceKey.length > 0 && [self.lastHealedSequenceKey isEqualToString:sequenceKey]) {
            SpliceKit_log(@"[Captions] Persisted caption repair skipped: panel-visible restore already completed for %@", sequenceKey);
            return;
        }
    } else {
        if (sequenceKey.length > 0 && [self.lastHeadlessRestoredSequenceKey isEqualToString:sequenceKey]) {
            SpliceKit_log(@"[Captions] Persisted caption repair skipped: headless restore already completed for %@", sequenceKey);
            return;
        }
    }

    SpliceKitCaptionStyle *generatedStyle = [SpliceKitCaptionStyle fromDictionary:styleDict];
    CGFloat yOffset = [self yOffsetForStyle:generatedStyle];
    BOOL needsPosition = (generatedStyle.position != SpliceKitCaptionPositionCenter || generatedStyle.customYOffset != 0);

    __block NSUInteger textRestoredCount = 0;
    __block NSUInteger plainFallbackCount = 0;
    __block NSUInteger styledAppliedCount = 0;
    __block NSUInteger styledExpectedCount = 0;
    __block NSUInteger titleCount = 0;
    __block NSUInteger positionAppliedCount = 0;
    SpliceKit_executeOnMainThread(^{
        NSArray *titles = SpliceKitCaption_collectTitlesForPersistedStorylines(sequence);
        titleCount = titles.count;
        NSUInteger count = MIN(titles.count, runtimeEntries.count);

        for (NSUInteger i = 0; i < count; i++) {
            id title = titles[i];
            NSDictionary *entry = runtimeEntries[i];
            NSString *text = [entry[@"text"] isKindOfClass:[NSString class]] ? entry[@"text"] : @"";
            NSArray *displayWords = [entry[@"words"] isKindOfClass:[NSArray class]] ? entry[@"words"] : nil;
            NSNumber *activeWordIndex = entry[@"activeWordIndex"];
            BOOL didRestoreTextForTitle = NO;

            @try {
                BOOL isHighlightEntry = ([activeWordIndex isKindOfClass:[NSNumber class]] &&
                                         displayWords.count > 0);
                if (isHighlightEntry) {
                    styledExpectedCount++;
                    NSAttributedString *highlighted =
                        SpliceKitCaption_makeHighlightedGeneratorAttributedStringFromWords(
                            displayWords, [activeWordIndex unsignedIntegerValue], generatedStyle);
                    if (SpliceKitCaption_setGeneratorAttributedTextForPersistedRepair(title, highlighted)) {
                        styledAppliedCount++;
                        textRestoredCount++;
                        didRestoreTextForTitle = YES;
                    }
                }

                if (!didRestoreTextForTitle && text.length > 0) {
                    if (SpliceKitCaption_setGeneratorTextFields(title, @[text], NO)) {
                        textRestoredCount++;
                        plainFallbackCount++;
                        didRestoreTextForTitle = YES;
                    }
                }
            } @catch (NSException *e) {
                SpliceKit_log(@"[Captions] Failed to repair persisted title text: %@", e.reason);
            }

            if (needsPosition) {
                if (SpliceKitCaption_applyGeneratorPositionYOffset(title, yOffset)) {
                    positionAppliedCount++;
                }
            }
        }
    });

    if (textRestoredCount > 0) {
        SpliceKit_log(@"[Captions] Restored text for %lu/%lu persisted caption titles (styled=%lu/%lu plainFallback=%lu)%@",
                      (unsigned long)textRestoredCount,
                      (unsigned long)titleCount,
                      (unsigned long)styledAppliedCount,
                      (unsigned long)styledExpectedCount,
                      (unsigned long)plainFallbackCount,
                      panelVisible ? @" while panel was visible" : @" during relaunch");
    }

    NSUInteger expectedCount = MIN(titleCount, runtimeEntries.count);
    BOOL fullyRestoredText = (expectedCount > 0 &&
                              expectedCount == runtimeEntries.count &&
                              textRestoredCount == expectedCount);
    BOOL fullyRestoredStyled = (styledExpectedCount == 0 ||
                                styledAppliedCount == styledExpectedCount);
    BOOL fullyRestoredPosition = (!needsPosition ||
                                  (expectedCount > 0 && positionAppliedCount == expectedCount));

    if (!fullyRestoredText && expectedCount > 0) {
        SpliceKit_log(@"[Captions] Persisted caption restore incomplete (text=%lu expected=%lu panelVisible=%@); keeping automatic retries active",
                      (unsigned long)textRestoredCount,
                      (unsigned long)expectedCount,
                      panelVisible ? @"YES" : @"NO");
    }
    if (!fullyRestoredStyled && styledExpectedCount > 0) {
        SpliceKit_log(@"[Captions] Persisted caption styled restore incomplete (styled=%lu expected=%lu); keeping automatic retries active",
                      (unsigned long)styledAppliedCount,
                      (unsigned long)styledExpectedCount);
    }
    if (!fullyRestoredPosition && needsPosition && expectedCount > 0) {
        SpliceKit_log(@"[Captions] Persisted caption position restore incomplete (position=%lu expected=%lu panelVisible=%@); keeping automatic retries active",
                      (unsigned long)positionAppliedCount,
                      (unsigned long)expectedCount,
                      panelVisible ? @"YES" : @"NO");
    }

    if (panelVisible) {
        if (fullyRestoredText && fullyRestoredStyled && fullyRestoredPosition) {
            self.lastHealedSequenceKey = sequenceKey;
        }
    } else if (fullyRestoredText && fullyRestoredStyled && fullyRestoredPosition) {
        self.lastHeadlessRestoredSequenceKey = sequenceKey;
    }
}

#pragma mark - State

- (NSDictionary *)getState {
    [self ensurePersistedStateLoaded];

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
