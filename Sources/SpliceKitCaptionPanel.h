//
//  SpliceKitCaptionPanel.h
//  SpliceKit - Social media-style engaging captions for FCP.
//
//  Generates social-media-style caption titles from transcript words.
//  The primary insertion path creates title clips directly via FCP's
//  Objective-C runtime; FCPXML is still emitted for export/debug/fallback.
//

#ifndef SpliceKitCaptionPanel_h
#define SpliceKitCaptionPanel_h

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import "SpliceKitTranscriptPanel.h"

#pragma mark - Enums

typedef NS_ENUM(NSInteger, SpliceKitCaptionPosition) {
    SpliceKitCaptionPositionBottom = 0,   // Y ~-350 (lower third)
    SpliceKitCaptionPositionCenter,        // Y = 0
    SpliceKitCaptionPositionTop,           // Y ~+350
    SpliceKitCaptionPositionCustom,        // user-specified Y
};

typedef NS_ENUM(NSInteger, SpliceKitCaptionAnimation) {
    SpliceKitCaptionAnimationNone = 0,
    SpliceKitCaptionAnimationFade,        // opacity 0->1->1->0
    SpliceKitCaptionAnimationPop,         // scale 0.5->1.0 + fade
    SpliceKitCaptionAnimationSlideUp,     // Y offset + fade
    SpliceKitCaptionAnimationTypewriter,  // progressive word reveal
    SpliceKitCaptionAnimationBounce,      // scale overshoot 0.8->1.15->1.0
};

typedef NS_ENUM(NSInteger, SpliceKitCaptionStatus) {
    SpliceKitCaptionStatusIdle = 0,
    SpliceKitCaptionStatusTranscribing,
    SpliceKitCaptionStatusReady,
    SpliceKitCaptionStatusGenerating,
    SpliceKitCaptionStatusError,
};

typedef NS_ENUM(NSInteger, SpliceKitCaptionOutputMode) {
    SpliceKitCaptionOutputTitle = 0,          // Motion title clips (social media style)
    SpliceKitCaptionOutputNativeCaption,       // FFAnchoredCaption objects (native caption lane)
};

typedef NS_ENUM(NSInteger, SpliceKitCaptionGrouping) {
    SpliceKitCaptionGroupingByWordCount = 0,
    SpliceKitCaptionGroupingBySentence,
    SpliceKitCaptionGroupingByTime,
    SpliceKitCaptionGroupingByCharCount,
    SpliceKitCaptionGroupingSocial,        // 2-3 words, 0.5s silence break
};

#pragma mark - Style Model

@interface SpliceKitCaptionStyle : NSObject <NSCopying>

@property (nonatomic, copy) NSString *name;              // "Bold Pop"
@property (nonatomic, copy) NSString *presetID;          // "bold_pop"

// Typography
@property (nonatomic, copy) NSString *font;              // "Futura-Bold"
@property (nonatomic) CGFloat fontSize;                   // 60-80 typical
@property (nonatomic, copy) NSString *fontFace;           // "Bold", "Regular"

// Colors (stored as "R G B A" strings for FCPXML, NSColor for UI)
@property (nonatomic, copy) NSColor *textColor;
@property (nonatomic, copy) NSColor *highlightColor;      // active word color (nil = no highlight)

// Outline
@property (nonatomic, copy) NSColor *outlineColor;
@property (nonatomic) CGFloat outlineWidth;               // 0-5

// Shadow
@property (nonatomic, copy) NSColor *shadowColor;
@property (nonatomic) CGFloat shadowBlurRadius;           // 0-20
@property (nonatomic) CGFloat shadowOffsetX;
@property (nonatomic) CGFloat shadowOffsetY;

// Background (stroke-based pseudo-background)
@property (nonatomic, copy) NSColor *backgroundColor;     // nil = no background
@property (nonatomic) CGFloat backgroundPadding;          // stroke width for bg effect

// Position & Animation
@property (nonatomic) SpliceKitCaptionPosition position;
@property (nonatomic) CGFloat customYOffset;              // for Custom position
@property (nonatomic) SpliceKitCaptionAnimation animation;
@property (nonatomic) CGFloat animationDuration;          // seconds (0.15-0.5)

// Formatting
@property (nonatomic) BOOL allCaps;
@property (nonatomic) BOOL wordByWordHighlight;           // karaoke mode

// Serialization
- (NSDictionary *)toDictionary;
+ (instancetype)fromDictionary:(NSDictionary *)dict;

// Presets
+ (NSArray<SpliceKitCaptionStyle *> *)builtInPresets;
+ (instancetype)presetWithID:(NSString *)presetID;

@end

#pragma mark - Segment Model

@interface SpliceKitCaptionSegment : NSObject
@property (nonatomic, strong) NSArray<SpliceKitTranscriptWord *> *words;
@property (nonatomic) double startTime;          // first word startTime
@property (nonatomic) double endTime;            // last word endTime
@property (nonatomic) double duration;           // endTime - startTime
@property (nonatomic, copy) NSString *text;      // joined word text
@property (nonatomic) NSUInteger segmentIndex;
- (NSDictionary *)toDictionary;
@end

#pragma mark - Caption Panel

extern NSNotificationName const SpliceKitCaptionDidGenerateNotification;

@interface SpliceKitCaptionPanel : NSObject

+ (instancetype)sharedPanel;

// Panel visibility
- (void)showPanel;
- (void)hidePanel;
- (BOOL)isVisible;

// Transcription (delegates to SpliceKitTranscriptPanel)
- (void)transcribeTimeline;
- (void)setWordsManually:(NSArray<NSDictionary *> *)wordDicts;

// Style
- (void)setStyle:(SpliceKitCaptionStyle *)style;
- (SpliceKitCaptionStyle *)currentStyle;

// Segmentation
@property (nonatomic) SpliceKitCaptionGrouping groupingMode;
@property (nonatomic) NSUInteger maxWordsPerSegment;     // default 5
@property (nonatomic) NSUInteger maxCharsPerSegment;     // default 40
@property (nonatomic) double maxSecondsPerSegment;       // default 3.0
- (void)regroupSegments;

// Output mode
@property (nonatomic) SpliceKitCaptionOutputMode outputMode;

// Generation & Export
- (NSDictionary *)generateCaptions;
- (NSDictionary *)generateNativeCaptions:(NSString *)language format:(NSString *)format;
- (NSDictionary *)exportSRT:(NSString *)outputPath;
- (NSDictionary *)exportTXT:(NSString *)outputPath;

// FCPXML for export/debug (set by generateCaptions)
@property (nonatomic, copy) NSString *generatedFCPXML;

// State
- (NSDictionary *)getState;
- (void)restorePersistedStateForCurrentSequenceIfNeeded;
- (void)repairPersistedCaptionsOnCurrentSequenceIfNeeded;
@property (nonatomic, readonly) SpliceKitCaptionStatus status;
@property (nonatomic, readonly) NSArray<SpliceKitCaptionSegment *> *segments;
@property (nonatomic, readonly) NSArray<SpliceKitTranscriptWord *> *words;

@end

#endif /* SpliceKitCaptionPanel_h */
