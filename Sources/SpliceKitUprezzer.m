//
//  SpliceKitUprezzer.m
//  Uprezzer — local clip upscaling inside Final Cut Pro.
//

#import "SpliceKitUprezzer.h"
#import "SpliceKit.h"
#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>

extern NSDictionary *SpliceKit_handleRequest(NSDictionary *request);
extern id SpliceKit_getActiveTimelineModule(void);

#if defined(__x86_64__)
#define SPLICEKIT_UPREZZER_STRET_MSG objc_msgSend_stret
#else
#define SPLICEKIT_UPREZZER_STRET_MSG objc_msgSend
#endif

typedef struct {
    int64_t value;
    int32_t timescale;
    uint32_t flags;
    int64_t epoch;
} SpliceKitUprezzerCMTime;

typedef struct {
    SpliceKitUprezzerCMTime start;
    SpliceKitUprezzerCMTime duration;
} SpliceKitUprezzerCMTimeRange;

typedef NS_ENUM(NSInteger, SpliceKitUprezzerSourceContext) {
    SpliceKitUprezzerSourceContextTimeline = 0,
    SpliceKitUprezzerSourceContextBrowser,
};

typedef NS_ENUM(NSInteger, SpliceKitUprezzerPanelState) {
    SpliceKitUprezzerPanelStateSetup = 0,
    SpliceKitUprezzerPanelStateProgress,
    SpliceKitUprezzerPanelStateCompletion,
};

static NSString * const SpliceKitUprezzerItemStateQueued = @"queued";
static NSString * const SpliceKitUprezzerItemStateSkipped = @"skipped";
static NSString * const SpliceKitUprezzerItemStateValidating = @"validating";
static NSString * const SpliceKitUprezzerItemStateProcessing = @"processing";
static NSString * const SpliceKitUprezzerItemStateImporting = @"importing";
static NSString * const SpliceKitUprezzerItemStateReplacing = @"replacing";
static NSString * const SpliceKitUprezzerItemStateCompleted = @"completed";
static NSString * const SpliceKitUprezzerItemStateFailed = @"failed";
static NSString * const SpliceKitUprezzerItemStateCancelled = @"cancelled";

static double SpliceKitUprezzerCMTimeSeconds(SpliceKitUprezzerCMTime time);
static id SpliceKitUprezzerTimelineSequence(id timeline);
static id SpliceKitUprezzerTimelinePrimaryContainer(id sequence);

@interface SpliceKitUprezzerSelectedItem : NSObject
@property (nonatomic, copy) NSString *itemID;
@property (nonatomic) SpliceKitUprezzerSourceContext sourceContext;
@property (nonatomic, copy) NSString *displayName;
@property (nonatomic, copy) NSString *eventName;
@property (nonatomic, copy) NSString *objectHandle;
@property (nonatomic, copy) NSString *objectClassName;
@property (nonatomic, copy) NSString *sourcePath;
@property (nonatomic) double duration;
@property (nonatomic) double frameRate;
@property (nonatomic) double timelineStart;
@property (nonatomic) double timelineDuration;
@property (nonatomic) NSInteger width;
@property (nonatomic) NSInteger height;
@property (nonatomic) NSInteger plannedWidth;
@property (nonatomic) NSInteger plannedHeight;
@property (nonatomic, copy) NSString *plannedOutputName;
@property (nonatomic, copy) NSString *plannedOutputPath;
@property (nonatomic, copy) NSString *status;
@property (nonatomic, copy) NSString *detail;
@property (nonatomic, copy) NSString *validationError;
@property (nonatomic) double progress;
@property (nonatomic) BOOL imported;
@property (nonatomic) BOOL replacedOnTimeline;
@property (nonatomic, copy) NSString *importedClipHandle;
@property (nonatomic, copy) NSString *importedClipName;
@end

@implementation SpliceKitUprezzerSelectedItem
@end

@class SpliceKitUprezzerProgressBarView;
@class SpliceKitUprezzerPillBadgeView;

@interface SpliceKitUprezzerItemRowView : NSView
@property (nonatomic, strong) NSTextField *nameLabel;
@property (nonatomic, strong) NSTextField *detailLabel;
@property (nonatomic, strong) SpliceKitUprezzerPillBadgeView *badgeView;
@property (nonatomic, strong) SpliceKitUprezzerProgressBarView *progressBar;
- (void)configureWithItem:(SpliceKitUprezzerSelectedItem *)item;
@end

@interface SpliceKitUprezzerProgressBarView : NSView
@property (nonatomic) double doubleValue;
@end

@interface SpliceKitUprezzerPillBadgeView : NSView
@property (nonatomic, strong) NSTextField *textLabel;
@property (nonatomic, strong) NSLayoutConstraint *minimumWidthConstraint;
- (instancetype)initWithText:(NSString *)text;
- (void)setBadgeText:(NSString *)text
           textColor:(NSColor *)textColor
           fillColor:(NSColor *)fillColor
         borderColor:(NSColor *)borderColor;
@end

@implementation SpliceKitUprezzerProgressBarView {
    CALayer *_trackLayer;
    CALayer *_fillLayer;
}

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        self.translatesAutoresizingMaskIntoConstraints = NO;
        self.wantsLayer = YES;
        self.layer.backgroundColor = NSColor.clearColor.CGColor;

        _trackLayer = [CALayer layer];
        _trackLayer.backgroundColor = [[NSColor colorWithCalibratedRed:0.20 green:0.22 blue:0.28 alpha:0.95] CGColor];
        _trackLayer.cornerRadius = 4.0;
        [self.layer addSublayer:_trackLayer];

        _fillLayer = [CALayer layer];
        _fillLayer.backgroundColor = [[NSColor colorWithCalibratedRed:0.53 green:0.44 blue:0.98 alpha:1.0] CGColor];
        _fillLayer.cornerRadius = 4.0;
        [self.layer addSublayer:_fillLayer];
    }
    return self;
}

- (void)setDoubleValue:(double)doubleValue {
    _doubleValue = MAX(0.0, MIN(1.0, doubleValue));
    [self setNeedsLayout:YES];
}

- (void)layout {
    [super layout];
    CGRect bounds = self.bounds;
    _trackLayer.frame = bounds;
    CGFloat width = bounds.size.width * self.doubleValue;
    _fillLayer.frame = CGRectMake(0.0, 0.0, width, bounds.size.height);
}

@end

@implementation SpliceKitUprezzerPillBadgeView

- (instancetype)initWithText:(NSString *)text {
    self = [super initWithFrame:NSZeroRect];
    if (self) {
        self.translatesAutoresizingMaskIntoConstraints = NO;
        self.wantsLayer = YES;
        self.layer.cornerRadius = 11.0;
        self.layer.masksToBounds = YES;
        self.layer.borderWidth = 1.0;

        _textLabel = [NSTextField labelWithString:text ?: @""];
        _textLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _textLabel.font = [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold];
        _textLabel.alignment = NSTextAlignmentCenter;
        _textLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        _textLabel.maximumNumberOfLines = 1;
        [self addSubview:_textLabel];

        _minimumWidthConstraint = [self.widthAnchor constraintGreaterThanOrEqualToConstant:72.0];
        _minimumWidthConstraint.active = YES;

        [NSLayoutConstraint activateConstraints:@[
            [self.heightAnchor constraintGreaterThanOrEqualToConstant:24.0],
            [_textLabel.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
            [_textLabel.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [_textLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.leadingAnchor constant:10.0],
            [_textLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.trailingAnchor constant:-10.0],
            [_textLabel.topAnchor constraintGreaterThanOrEqualToAnchor:self.topAnchor constant:4.0],
            [_textLabel.bottomAnchor constraintLessThanOrEqualToAnchor:self.bottomAnchor constant:-4.0],
        ]];

        [self setBadgeText:text
                 textColor:[NSColor colorWithWhite:0.94 alpha:1.0]
                 fillColor:[NSColor colorWithCalibratedWhite:0.18 alpha:0.96]
               borderColor:[NSColor colorWithCalibratedWhite:1.0 alpha:0.08]];
    }
    return self;
}

- (void)setBadgeText:(NSString *)text
           textColor:(NSColor *)textColor
           fillColor:(NSColor *)fillColor
         borderColor:(NSColor *)borderColor {
    self.textLabel.stringValue = text ?: @"";
    self.textLabel.textColor = textColor ?: [NSColor colorWithWhite:0.94 alpha:1.0];
    self.layer.backgroundColor = (fillColor ?: [NSColor colorWithCalibratedWhite:0.18 alpha:0.96]).CGColor;
    self.layer.borderColor = (borderColor ?: [NSColor colorWithCalibratedWhite:1.0 alpha:0.08]).CGColor;
}

@end

@implementation SpliceKitUprezzerItemRowView

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        self.translatesAutoresizingMaskIntoConstraints = NO;
        self.wantsLayer = YES;
        self.layer.cornerRadius = 14.0;
        self.layer.backgroundColor = [[NSColor colorWithCalibratedRed:0.13 green:0.14 blue:0.18 alpha:0.92] CGColor];
        self.layer.borderWidth = 1.0;
        self.layer.borderColor = [[NSColor colorWithCalibratedWhite:1.0 alpha:0.05] CGColor];

        _nameLabel = [NSTextField labelWithString:@""];
        _nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _nameLabel.font = [NSFont systemFontOfSize:13.5 weight:NSFontWeightSemibold];
        _nameLabel.textColor = [NSColor colorWithWhite:0.98 alpha:1.0];

        _detailLabel = [NSTextField wrappingLabelWithString:@""];
        _detailLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _detailLabel.font = [NSFont systemFontOfSize:10.5];
        _detailLabel.textColor = [NSColor colorWithWhite:0.70 alpha:1.0];
        _detailLabel.maximumNumberOfLines = 2;

        _badgeView = [[SpliceKitUprezzerPillBadgeView alloc] initWithText:@"Queued"];
        _badgeView.minimumWidthConstraint.constant = 76.0;

        _progressBar = [[SpliceKitUprezzerProgressBarView alloc] initWithFrame:NSZeroRect];
        _progressBar.doubleValue = 0.0;

        [self addSubview:_nameLabel];
        [self addSubview:_detailLabel];
        [self addSubview:_badgeView];
        [self addSubview:_progressBar];

        [NSLayoutConstraint activateConstraints:@[
            [self.heightAnchor constraintEqualToConstant:76.0],

            [_nameLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:14.0],
            [_nameLabel.topAnchor constraintEqualToAnchor:self.topAnchor constant:12.0],
            [_nameLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_badgeView.leadingAnchor constant:-8.0],

            [_badgeView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-14.0],
            [_badgeView.centerYAnchor constraintEqualToAnchor:_nameLabel.centerYAnchor],

            [_detailLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:14.0],
            [_detailLabel.topAnchor constraintEqualToAnchor:_nameLabel.bottomAnchor constant:4.0],
            [_detailLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-14.0],

            [_progressBar.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:14.0],
            [_progressBar.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-14.0],
            [_progressBar.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-12.0],
            [_progressBar.heightAnchor constraintEqualToConstant:5.0],
        ]];
    }
    return self;
}

- (void)configureWithItem:(SpliceKitUprezzerSelectedItem *)item {
    NSString *dims = (item.width > 0 && item.height > 0 && item.plannedWidth > 0 && item.plannedHeight > 0)
        ? [NSString stringWithFormat:@"%ldx%ld -> %ldx%ld",
            (long)item.width, (long)item.height, (long)item.plannedWidth, (long)item.plannedHeight]
        : @"";
    NSString *detail = item.detail ?: @"";
    if (dims.length > 0 && detail.length > 0) {
        detail = [NSString stringWithFormat:@"%@\n%@", dims, detail];
    } else if (dims.length > 0) {
        detail = dims;
    }

    self.nameLabel.stringValue = item.displayName ?: @"Untitled Clip";
    self.detailLabel.stringValue = detail;
    self.progressBar.doubleValue = MAX(0.0, MIN(1.0, item.progress));
    [self.badgeView setBadgeText:[self badgeTextForState:item.status]
                       textColor:[self badgeColorForState:item.status]
                       fillColor:[self badgeFillColorForState:item.status]
                     borderColor:[NSColor clearColor]];
}

- (NSString *)badgeTextForState:(NSString *)state {
    if ([state isEqualToString:SpliceKitUprezzerItemStateValidating]) return @"Validating";
    if ([state isEqualToString:SpliceKitUprezzerItemStateProcessing]) return @"Processing";
    if ([state isEqualToString:SpliceKitUprezzerItemStateImporting]) return @"Importing";
    if ([state isEqualToString:SpliceKitUprezzerItemStateReplacing]) return @"Replacing";
    if ([state isEqualToString:SpliceKitUprezzerItemStateCompleted]) return @"Completed";
    if ([state isEqualToString:SpliceKitUprezzerItemStateFailed]) return @"Failed";
    if ([state isEqualToString:SpliceKitUprezzerItemStateSkipped]) return @"Skipped";
    if ([state isEqualToString:SpliceKitUprezzerItemStateCancelled]) return @"Stopped";
    return @"Queued";
}

- (NSColor *)badgeColorForState:(NSString *)state {
    if ([state isEqualToString:SpliceKitUprezzerItemStateCompleted]) {
        return [NSColor colorWithCalibratedRed:0.48 green:0.86 blue:0.62 alpha:1.0];
    }
    if ([state isEqualToString:SpliceKitUprezzerItemStateFailed]) {
        return [NSColor colorWithCalibratedRed:1.0 green:0.52 blue:0.52 alpha:1.0];
    }
    if ([state isEqualToString:SpliceKitUprezzerItemStateSkipped] ||
        [state isEqualToString:SpliceKitUprezzerItemStateCancelled]) {
        return [NSColor colorWithWhite:0.72 alpha:1.0];
    }
    if ([state isEqualToString:SpliceKitUprezzerItemStateProcessing] ||
        [state isEqualToString:SpliceKitUprezzerItemStateImporting] ||
        [state isEqualToString:SpliceKitUprezzerItemStateReplacing]) {
        return [NSColor controlAccentColor];
    }
    return [NSColor colorWithWhite:0.88 alpha:1.0];
}

- (NSColor *)badgeFillColorForState:(NSString *)state {
    if ([state isEqualToString:SpliceKitUprezzerItemStateCompleted]) {
        return [NSColor colorWithCalibratedRed:0.18 green:0.30 blue:0.22 alpha:0.98];
    }
    if ([state isEqualToString:SpliceKitUprezzerItemStateFailed]) {
        return [NSColor colorWithCalibratedRed:0.31 green:0.16 blue:0.18 alpha:0.98];
    }
    if ([state isEqualToString:SpliceKitUprezzerItemStateSkipped] ||
        [state isEqualToString:SpliceKitUprezzerItemStateCancelled]) {
        return [NSColor colorWithCalibratedWhite:0.20 alpha:0.98];
    }
    if ([state isEqualToString:SpliceKitUprezzerItemStateProcessing] ||
        [state isEqualToString:SpliceKitUprezzerItemStateImporting] ||
        [state isEqualToString:SpliceKitUprezzerItemStateReplacing]) {
        return [NSColor colorWithCalibratedRed:0.23 green:0.20 blue:0.33 alpha:0.98];
    }
    return [NSColor colorWithCalibratedWhite:0.20 alpha:0.98];
}

@end

@interface SpliceKitUprezzerChoiceCardView : NSView
@property (nonatomic, strong) NSTextField *titleLabel;
@property (nonatomic, strong) NSTextField *subtitleLabel;
@property (nonatomic, strong) SpliceKitUprezzerPillBadgeView *statusBadge;
@property (nonatomic, strong) NSButton *button;
- (instancetype)initWithTitle:(NSString *)title
                     subtitle:(NSString *)subtitle
                       target:(id)target
                       action:(SEL)action;
- (void)setSelectedAppearance:(BOOL)selected emphasized:(BOOL)emphasized;
@end

@implementation SpliceKitUprezzerChoiceCardView

- (instancetype)initWithTitle:(NSString *)title
                     subtitle:(NSString *)subtitle
                       target:(id)target
                       action:(SEL)action {
    self = [super initWithFrame:NSZeroRect];
    if (self) {
        self.translatesAutoresizingMaskIntoConstraints = NO;
        self.wantsLayer = YES;
        self.layer.cornerRadius = 16.0;
        self.layer.borderWidth = 1.0;

        _titleLabel = [NSTextField labelWithString:title ?: @""];
        _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _titleLabel.font = [NSFont systemFontOfSize:12.0 weight:NSFontWeightSemibold];
        _titleLabel.textColor = [NSColor colorWithWhite:0.98 alpha:1.0];
        [self addSubview:_titleLabel];

        _subtitleLabel = [NSTextField wrappingLabelWithString:subtitle ?: @""];
        _subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _subtitleLabel.font = [NSFont systemFontOfSize:9.5];
        _subtitleLabel.textColor = [NSColor colorWithWhite:0.72 alpha:1.0];
        _subtitleLabel.maximumNumberOfLines = 1;
        _subtitleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        [self addSubview:_subtitleLabel];

        _statusBadge = [[SpliceKitUprezzerPillBadgeView alloc] initWithText:@"Import only"];
        _statusBadge.minimumWidthConstraint.constant = 78.0;
        [self addSubview:_statusBadge];

        _button = [NSButton buttonWithTitle:@"" target:target action:action];
        _button.translatesAutoresizingMaskIntoConstraints = NO;
        _button.bordered = NO;
        _button.wantsLayer = YES;
        _button.layer.backgroundColor = NSColor.clearColor.CGColor;
        [self addSubview:_button positioned:NSWindowAbove relativeTo:nil];

        [NSLayoutConstraint activateConstraints:@[
            [self.heightAnchor constraintGreaterThanOrEqualToConstant:54.0],

            [_titleLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:14.0],
            [_titleLabel.topAnchor constraintEqualToAnchor:self.topAnchor constant:10.0],
            [_titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_statusBadge.leadingAnchor constant:-12.0],

            [_statusBadge.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-14.0],
            [_statusBadge.centerYAnchor constraintEqualToAnchor:_titleLabel.centerYAnchor],

            [_subtitleLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:14.0],
            [_subtitleLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-14.0],
            [_subtitleLabel.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor constant:2.0],
            [_subtitleLabel.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-10.0],

            [_button.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [_button.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
            [_button.topAnchor constraintEqualToAnchor:self.topAnchor],
            [_button.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        ]];

        [self setSelectedAppearance:NO emphasized:NO];
    }
    return self;
}

- (void)setSelectedAppearance:(BOOL)selected emphasized:(BOOL)emphasized {
    NSColor *accent = [NSColor colorWithCalibratedRed:0.53 green:0.44 blue:0.98 alpha:1.0];
    NSColor *surface = emphasized
        ? [NSColor colorWithCalibratedRed:0.14 green:0.15 blue:0.19 alpha:0.92]
        : [NSColor colorWithCalibratedWhite:0.14 alpha:0.78];
    self.layer.backgroundColor = (selected
        ? [NSColor colorWithCalibratedRed:0.19 green:0.17 blue:0.27 alpha:0.94]
        : surface).CGColor;
    self.layer.borderColor = (selected
        ? [accent colorWithAlphaComponent:0.88].CGColor
        : [NSColor colorWithCalibratedWhite:1.0 alpha:0.06].CGColor);
    self.titleLabel.textColor = [NSColor colorWithWhite:0.98 alpha:1.0];
    self.subtitleLabel.textColor = selected
        ? [NSColor colorWithWhite:0.84 alpha:1.0]
        : [NSColor colorWithWhite:0.68 alpha:1.0];
    [self.statusBadge setBadgeText:self.statusBadge.textLabel.stringValue
                         textColor:(selected
                             ? [NSColor colorWithWhite:0.98 alpha:1.0]
                             : [NSColor colorWithWhite:0.82 alpha:1.0])
                         fillColor:(selected
                             ? [accent colorWithAlphaComponent:0.18]
                             : [NSColor colorWithCalibratedWhite:0.16 alpha:1.0])
                       borderColor:[NSColor clearColor]];
}

@end

static NSString *SpliceKitUprezzerString(id value) {
    return [value isKindOfClass:[NSString class]] ? value : @"";
}

static NSString *SpliceKitUprezzerTrimmedString(id value) {
    return [SpliceKitUprezzerString(value)
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static NSString *SpliceKitUprezzerEnsureDirectory(NSString *path) {
    if (path.length == 0) return @"";
    [[NSFileManager defaultManager] createDirectoryAtPath:path
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    return path;
}

static NSString *SpliceKitUprezzerStripANSI(NSString *input) {
    if (input.length == 0) return @"";
    static NSRegularExpression *regex = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        regex = [NSRegularExpression regularExpressionWithPattern:@"\\x1B\\[[0-9;]*[A-Za-z]"
                                                         options:0
                                                           error:nil];
    });
    NSString *clean = [regex stringByReplacingMatchesInString:input
                                                      options:0
                                                        range:NSMakeRange(0, input.length)
                                                 withTemplate:@""];
    clean = [clean stringByReplacingOccurrencesOfString:@"\r" withString:@"\n"];
    return SpliceKitUprezzerTrimmedString(clean);
}

static double SpliceKitUprezzerPercentFromLine(NSString *line) {
    if (line.length == 0) return -1.0;
    static NSRegularExpression *regex = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        regex = [NSRegularExpression regularExpressionWithPattern:@"([0-9]+(?:\\.[0-9]+)?)%"
                                                         options:0
                                                           error:nil];
    });
    NSTextCheckingResult *match = [regex firstMatchInString:line
                                                    options:0
                                                      range:NSMakeRange(0, line.length)];
    if (!match || match.numberOfRanges < 2) return -1.0;
    NSString *number = [line substringWithRange:[match rangeAtIndex:1]];
    return [number doubleValue];
}

static NSString *SpliceKitUprezzerSourceLabel(SpliceKitUprezzerSourceContext context) {
    return context == SpliceKitUprezzerSourceContextTimeline ? @"Timeline" : @"Browser";
}

static NSString *SpliceKitUprezzerSanitizeFilename(NSString *value) {
    NSString *trimmed = SpliceKitUprezzerTrimmedString(value);
    if (trimmed.length == 0) return @"Clip";
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
    return joined.length > 0 ? joined : @"Clip";
}

static NSString *SpliceKitUprezzerDisplayBaseName(NSString *value) {
    NSString *base = SpliceKitUprezzerSanitizeFilename(value);
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"\\s*\\[Uprezzer\\s+[234]x\\]$"
                                                                           options:NSRegularExpressionCaseInsensitive
                                                                             error:nil];
    return [regex stringByReplacingMatchesInString:base
                                           options:0
                                             range:NSMakeRange(0, base.length)
                                      withTemplate:@""];
}

static NSString *SpliceKitUprezzerMakeOutputFilename(NSString *baseName,
                                                     NSInteger factor,
                                                     NSString *extension,
                                                     NSSet<NSString *> *reserved) {
    NSString *cleanBase = SpliceKitUprezzerDisplayBaseName(baseName);
    NSString *suffix = [NSString stringWithFormat:@"[Uprezzer %ldx]", (long)factor];
    NSString *ext = extension.length > 0 ? extension.lowercaseString : @"mov";

    NSString *candidate = [NSString stringWithFormat:@"%@ %@.%@", cleanBase, suffix, ext];
    NSInteger serial = 2;
    while ([reserved containsObject:candidate.lowercaseString]) {
        candidate = [NSString stringWithFormat:@"%@ %@ %ld.%@", cleanBase, suffix, (long)serial, ext];
        serial++;
    }
    return candidate;
}

static NSString *SpliceKitUprezzerFXUpscalePath(void) {
    NSArray<NSString *> *paths = @[
        @"/opt/homebrew/bin/fx-upscale",
        @"/usr/local/bin/fx-upscale",
        @"/usr/bin/fx-upscale",
    ];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *path in paths) {
        if ([fm isExecutableFileAtPath:path]) return path;
    }
    return nil;
}

static NSString *SpliceKitUprezzerWorkspaceRoot(void) {
    return SpliceKitUprezzerEnsureDirectory([NSHomeDirectory()
        stringByAppendingPathComponent:@"Movies/Uprezzer/Jobs"]);
}

static NSString *SpliceKitUprezzerRunRoot(NSString *jobID) {
    return SpliceKitUprezzerEnsureDirectory([[SpliceKitUprezzerWorkspaceRoot()
        stringByAppendingPathComponent:jobID ?: @"job"] copy]);
}

static NSString *SpliceKitUprezzerLogsDirectory(NSString *jobID) {
    return SpliceKitUprezzerEnsureDirectory([[SpliceKitUprezzerRunRoot(jobID)
        stringByAppendingPathComponent:@"logs"] copy]);
}

static NSString *SpliceKitUprezzerRendersDirectory(NSString *jobID) {
    return SpliceKitUprezzerEnsureDirectory([[SpliceKitUprezzerRunRoot(jobID)
        stringByAppendingPathComponent:@"renders"] copy]);
}

static NSString *SpliceKitUprezzerReportsDirectory(NSString *jobID) {
    return SpliceKitUprezzerEnsureDirectory([[SpliceKitUprezzerRunRoot(jobID)
        stringByAppendingPathComponent:@"reports"] copy]);
}

static NSDictionary *SpliceKitUprezzerSerializeTime(SpliceKitUprezzerCMTime t) {
    if (t.timescale <= 0) return @{};
    return @{
        @"value": @(t.value),
        @"timescale": @(t.timescale),
        @"seconds": @((double)t.value / (double)t.timescale)
    };
}

static NSArray *SpliceKitUprezzerTimelineSelectedObjects(void) {
    __block NSArray *items = nil;
    SpliceKit_executeOnMainThread(^{
        id timeline = SpliceKit_getActiveTimelineModule();
        if (!timeline) return;

        SEL richSel = NSSelectorFromString(@"selectedItems:includeItemBeforePlayheadIfLast:");
        if ([timeline respondsToSelector:richSel]) {
            id selected = ((id (*)(id, SEL, BOOL, BOOL))objc_msgSend)(timeline, richSel, NO, NO);
            if ([selected isKindOfClass:[NSArray class]] && [(NSArray *)selected count] > 0) {
                items = [(NSArray *)selected copy];
                return;
            }
        }

        SEL selSel = NSSelectorFromString(@"selectedItems");
        if ([timeline respondsToSelector:selSel]) {
            id selected = ((id (*)(id, SEL))objc_msgSend)(timeline, selSel);
            if ([selected isKindOfClass:[NSArray class]] && [(NSArray *)selected count] > 0) {
                items = [(NSArray *)selected copy];
            }
        }
    });
    return items ?: @[];
}

static id SpliceKitUprezzerBrowserSelectionUnwrapObject(id object) {
    if (!object) return nil;

    id candidate = object;
    NSArray<NSString *> *selectors = @[@"object", @"representedObject", @"item", @"clip"];
    for (NSInteger attempt = 0; attempt < 3; attempt++) {
        BOOL changed = NO;
        for (NSString *selName in selectors) {
            SEL sel = NSSelectorFromString(selName);
            if (![candidate respondsToSelector:sel]) continue;
            id next = ((id (*)(id, SEL))objc_msgSend)(candidate, sel);
            if (next && next != candidate) {
                candidate = next;
                changed = YES;
                break;
            }
        }
        if (!changed) break;
    }
    return candidate;
}

static NSArray *SpliceKitUprezzerBrowserSelectedObjects(void) {
    __block NSArray *results = nil;
    SpliceKit_executeOnMainThread(^{
        NSMutableOrderedSet *unique = [NSMutableOrderedSet orderedSet];
        id app = [NSApplication sharedApplication];
        id delegate = ((id (*)(id, SEL))objc_msgSend)(app, @selector(delegate));
        if (!delegate) {
            results = @[];
            return;
        }

        NSMutableArray *modules = [NSMutableArray array];
        SEL browserSel = NSSelectorFromString(@"mediaBrowserContainerModule");
        id browser = [delegate respondsToSelector:browserSel]
            ? ((id (*)(id, SEL))objc_msgSend)(delegate, browserSel) : nil;
        if (browser) [modules addObject:browser];

        SEL filmstripSel = NSSelectorFromString(@"filmstripModule");
        id filmstrip = (browser && [browser respondsToSelector:filmstripSel])
            ? ((id (*)(id, SEL))objc_msgSend)(browser, filmstripSel) : nil;
        if (filmstrip) [modules addObject:filmstrip];

        SEL organizerSel = NSSelectorFromString(@"organizerModule");
        id organizer = [delegate respondsToSelector:organizerSel]
            ? ((id (*)(id, SEL))objc_msgSend)(delegate, organizerSel) : nil;
        if (organizer) [modules addObject:organizer];

        SEL itemsSel = NSSelectorFromString(@"itemsModule");
        id itemsModule = (organizer && [organizer respondsToSelector:itemsSel])
            ? ((id (*)(id, SEL))objc_msgSend)(organizer, itemsSel) : nil;
        if (itemsModule) [modules addObject:itemsModule];

        NSArray<NSString *> *selectionSelectors = @[
            @"selectedItems",
            @"_selectedItems",
            @"selectedMediaRanges",
            @"selectedMedia",
            @"selection",
            @"selectedObjects"
        ];

        for (id module in modules) {
            for (NSString *selName in selectionSelectors) {
                SEL sel = NSSelectorFromString(selName);
                if (![module respondsToSelector:sel]) continue;
                id selection = ((id (*)(id, SEL))objc_msgSend)(module, sel);
                if ([selection isKindOfClass:[NSSet class]]) {
                    selection = [(NSSet *)selection allObjects];
                }
                if (![selection isKindOfClass:[NSArray class]]) continue;
                for (id entry in (NSArray *)selection) {
                    id unwrapped = SpliceKitUprezzerBrowserSelectionUnwrapObject(entry);
                    if (unwrapped) {
                        [unique addObject:unwrapped];
                    }
                }
            }
        }

        results = [unique array];
    });
    return results ?: @[];
}

static NSString *SpliceKitUprezzerDisplayNameForObject(id object) {
    __block NSString *name = nil;
    if (!object) return nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            if ([object respondsToSelector:@selector(displayName)]) {
                id value = ((id (*)(id, SEL))objc_msgSend)(object, @selector(displayName));
                if ([value isKindOfClass:[NSString class]]) {
                    name = value;
                }
            }
        } @catch (__unused NSException *e) {}
    });
    return name;
}

static NSString *SpliceKitUprezzerEventNameForObject(id object) {
    __block NSString *name = nil;
    if (!object) return nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            SEL eventSel = NSSelectorFromString(@"event");
            SEL containerEventSel = NSSelectorFromString(@"containerEvent");
            id event = nil;
            if ([object respondsToSelector:eventSel]) {
                event = ((id (*)(id, SEL))objc_msgSend)(object, eventSel);
            } else if ([object respondsToSelector:containerEventSel]) {
                event = ((id (*)(id, SEL))objc_msgSend)(object, containerEventSel);
            }
            if (!event) {
                @try { event = [object valueForKey:@"event"]; } @catch (__unused NSException *e) {}
            }
            if (!event) {
                @try { event = [object valueForKey:@"containerEvent"]; } @catch (__unused NSException *e) {}
            }
            if (event && [event respondsToSelector:@selector(displayName)]) {
                id value = ((id (*)(id, SEL))objc_msgSend)(event, @selector(displayName));
                if ([value isKindOfClass:[NSString class]]) {
                    name = value;
                }
            }
        } @catch (__unused NSException *e) {}
    });
    return name;
}

static BOOL SpliceKitUprezzerTimelinePlacementForObject(id object, double *outStart, double *outDuration) {
    if (!object || !outStart || !outDuration) return NO;

    __block BOOL success = NO;
    __block double start = 0.0;
    __block double duration = 0.0;

    SpliceKit_executeOnMainThread(^{
        @try {
            if ([object respondsToSelector:@selector(timelineStartTime)] &&
                [object respondsToSelector:@selector(duration)]) {
                SpliceKitUprezzerCMTime startTime =
                    ((SpliceKitUprezzerCMTime (*)(id, SEL))SPLICEKIT_UPREZZER_STRET_MSG)(object, @selector(timelineStartTime));
                SpliceKitUprezzerCMTime durationTime =
                    ((SpliceKitUprezzerCMTime (*)(id, SEL))SPLICEKIT_UPREZZER_STRET_MSG)(object, @selector(duration));
                if (startTime.timescale > 0 && durationTime.timescale > 0) {
                    start = (double)startTime.value / (double)startTime.timescale;
                    duration = (double)durationTime.value / (double)durationTime.timescale;
                    success = YES;
                }
            }
            if (!success) {
                id timeline = SpliceKit_getActiveTimelineModule();
                id sequence = SpliceKitUprezzerTimelineSequence(timeline);
                id container = SpliceKitUprezzerTimelinePrimaryContainer(sequence);
                SEL rangeSel = NSSelectorFromString(@"effectiveRangeOfObject:");
                if (container && [container respondsToSelector:rangeSel]) {
                    SpliceKitUprezzerCMTimeRange range =
                        ((SpliceKitUprezzerCMTimeRange (*)(id, SEL, id))SPLICEKIT_UPREZZER_STRET_MSG)(container, rangeSel, object);
                    double startSeconds = SpliceKitUprezzerCMTimeSeconds(range.start);
                    double durationSeconds = SpliceKitUprezzerCMTimeSeconds(range.duration);
                    if (startSeconds >= 0.0 && durationSeconds >= 0.0) {
                        start = startSeconds;
                        duration = durationSeconds;
                        success = YES;
                    }
                }
            }
        } @catch (__unused NSException *e) {}
    });

    if (success) {
        *outStart = start;
        *outDuration = duration;
    }
    return success;
}

static NSString *SpliceKitUprezzerCurrentTimelineEventName(void) {
    __block NSString *eventName = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            id timeline = SpliceKit_getActiveTimelineModule();
            if (!timeline) return;
            SEL seqSel = NSSelectorFromString(@"sequence");
            id sequence = [timeline respondsToSelector:seqSel]
                ? ((id (*)(id, SEL))objc_msgSend)(timeline, seqSel) : nil;
            if (!sequence) return;
            eventName = SpliceKitUprezzerEventNameForObject(sequence);
        } @catch (__unused NSException *e) {}
    });
    return eventName;
}

static BOOL SpliceKitUprezzerClipRangeForClip(id clip, SpliceKitUprezzerCMTimeRange *outRange) {
    if (!clip || !outRange) return NO;

    __block BOOL success = NO;
    __block SpliceKitUprezzerCMTimeRange clipRange = {0};
    SpliceKit_executeOnMainThread(^{
        @try {
            SEL clippedRangeSel = NSSelectorFromString(@"clippedRange");
            SEL durationSel = NSSelectorFromString(@"duration");
            if ([clip respondsToSelector:clippedRangeSel]) {
                clipRange = ((SpliceKitUprezzerCMTimeRange (*)(id, SEL))SPLICEKIT_UPREZZER_STRET_MSG)(clip, clippedRangeSel);
                success = (clipRange.duration.timescale > 0);
            } else if ([clip respondsToSelector:durationSel]) {
                SpliceKitUprezzerCMTime dur =
                    ((SpliceKitUprezzerCMTime (*)(id, SEL))SPLICEKIT_UPREZZER_STRET_MSG)(clip, durationSel);
                clipRange.start = (SpliceKitUprezzerCMTime){0, dur.timescale, 1, 0};
                clipRange.duration = dur;
                success = (dur.timescale > 0);
            }
        } @catch (__unused NSException *e) {}
    });

    if (success) {
        *outRange = clipRange;
    }
    return success;
}

static NSURL *SpliceKitUprezzerMediaURLForObject(id object) {
    if (!object) return nil;

    __block NSURL *mediaURL = nil;
    SpliceKit_executeOnMainThread(^{
        @autoreleasepool {
            @try {
                NSURL* (^firstURLFromFileURLContainer)(id) = ^NSURL *(id candidate) {
                    if (!candidate) return (NSURL *)nil;

                    @try {
                        if ([candidate respondsToSelector:NSSelectorFromString(@"fileURLs")]) {
                            id urls = ((id (*)(id, SEL))objc_msgSend)(candidate, NSSelectorFromString(@"fileURLs"));
                            if ([urls isKindOfClass:[NSArray class]] && [(NSArray *)urls count] > 0) {
                                id first = [(NSArray *)urls firstObject];
                                if ([first isKindOfClass:[NSURL class]]) return (NSURL *)first;
                            }
                        }
                    } @catch (__unused NSException *e) {}

                    @try {
                        if ([candidate respondsToSelector:NSSelectorFromString(@"fileURLs:")]) {
                            id urls = ((id (*)(id, SEL, BOOL))objc_msgSend)(candidate,
                                                                             NSSelectorFromString(@"fileURLs:"),
                                                                             YES);
                            if ([urls isKindOfClass:[NSArray class]] && [(NSArray *)urls count] > 0) {
                                id first = [(NSArray *)urls firstObject];
                                if ([first isKindOfClass:[NSURL class]]) return (NSURL *)first;
                            }
                        }
                    } @catch (__unused NSException *e) {}

                    return (NSURL *)nil;
                };

                id clipForMedia = object;
                if ([clipForMedia respondsToSelector:NSSelectorFromString(@"containedItems")]) {
                    id contained = ((id (*)(id, SEL))objc_msgSend)(clipForMedia, NSSelectorFromString(@"containedItems"));
                    if ([contained isKindOfClass:[NSArray class]]) {
                        for (id item in (NSArray *)contained) {
                            NSString *className = NSStringFromClass([item class]) ?: @"";
                            if ([className containsString:@"MediaComponent"]) {
                                clipForMedia = item;
                                break;
                            }
                        }
                    }
                }
                if (!mediaURL && [clipForMedia respondsToSelector:NSSelectorFromString(@"_metadataMediaComponent")]) {
                    id metadataMedia = ((id (*)(id, SEL))objc_msgSend)(clipForMedia,
                                                                       NSSelectorFromString(@"_metadataMediaComponent"));
                    if (metadataMedia) {
                        clipForMedia = metadataMedia;
                    }
                }
                if (!mediaURL && [clipForMedia respondsToSelector:NSSelectorFromString(@"primaryObject")]) {
                    id primaryObject = ((id (*)(id, SEL))objc_msgSend)(clipForMedia, NSSelectorFromString(@"primaryObject"));
                    if (primaryObject && [primaryObject respondsToSelector:NSSelectorFromString(@"containedItems")]) {
                        id contained = ((id (*)(id, SEL))objc_msgSend)(primaryObject, NSSelectorFromString(@"containedItems"));
                        if ([contained isKindOfClass:[NSArray class]]) {
                            for (id item in (NSArray *)contained) {
                                NSString *className = NSStringFromClass([item class]) ?: @"";
                                if ([className containsString:@"MediaComponent"]) {
                                    clipForMedia = item;
                                    break;
                                }
                            }
                        }
                    }
                }

                id media = nil;
                if ([clipForMedia respondsToSelector:NSSelectorFromString(@"media")]) {
                    media = ((id (*)(id, SEL))objc_msgSend)(clipForMedia, NSSelectorFromString(@"media"));
                }

                if (media && [media respondsToSelector:NSSelectorFromString(@"originalMediaURL")]) {
                    id url = ((id (*)(id, SEL))objc_msgSend)(media, NSSelectorFromString(@"originalMediaURL"));
                    if ([url isKindOfClass:[NSURL class]]) mediaURL = url;
                }

                if (!mediaURL && media && [media respondsToSelector:NSSelectorFromString(@"originalMediaRep")]) {
                    id rep = ((id (*)(id, SEL))objc_msgSend)(media, NSSelectorFromString(@"originalMediaRep"));
                    mediaURL = firstURLFromFileURLContainer(rep);
                }

                if (!mediaURL && media && [media respondsToSelector:NSSelectorFromString(@"currentRep")]) {
                    id rep = ((id (*)(id, SEL))objc_msgSend)(media, NSSelectorFromString(@"currentRep"));
                    mediaURL = firstURLFromFileURLContainer(rep);
                }

                if (!mediaURL && [clipForMedia respondsToSelector:NSSelectorFromString(@"assetMediaReference")]) {
                    id ref = ((id (*)(id, SEL))objc_msgSend)(clipForMedia, NSSelectorFromString(@"assetMediaReference"));
                    if (ref && [ref respondsToSelector:NSSelectorFromString(@"resolvedURL")]) {
                        id url = ((id (*)(id, SEL))objc_msgSend)(ref, NSSelectorFromString(@"resolvedURL"));
                        if ([url isKindOfClass:[NSURL class]]) mediaURL = url;
                    }
                }

                if (!mediaURL) {
                    @try {
                        id url = [clipForMedia valueForKeyPath:@"media.fileURL"];
                        if ([url isKindOfClass:[NSURL class]]) mediaURL = url;
                    } @catch (__unused NSException *e) {}
                }
                if (!mediaURL) {
                    @try {
                        id url = [clipForMedia valueForKeyPath:@"clipInPlace.asset.originalMediaURL"];
                        if ([url isKindOfClass:[NSURL class]]) mediaURL = url;
                    } @catch (__unused NSException *e) {}
                }
                if (!mediaURL && [clipForMedia respondsToSelector:NSSelectorFromString(@"originalMediaURL")]) {
                    id url = ((id (*)(id, SEL))objc_msgSend)(clipForMedia, NSSelectorFromString(@"originalMediaURL"));
                    if ([url isKindOfClass:[NSURL class]]) mediaURL = url;
                }

                if (!mediaURL && [clipForMedia respondsToSelector:NSSelectorFromString(@"firstAssetIfOnlyOneVideo")]) {
                    id asset = ((id (*)(id, SEL))objc_msgSend)(clipForMedia,
                                                               NSSelectorFromString(@"firstAssetIfOnlyOneVideo"));
                    if (asset && [asset respondsToSelector:NSSelectorFromString(@"originalMediaURL")]) {
                        id url = ((id (*)(id, SEL))objc_msgSend)(asset, NSSelectorFromString(@"originalMediaURL"));
                        if ([url isKindOfClass:[NSURL class]]) mediaURL = url;
                    }
                    if (!mediaURL && asset && [asset respondsToSelector:NSSelectorFromString(@"currentRep")]) {
                        id rep = ((id (*)(id, SEL))objc_msgSend)(asset, NSSelectorFromString(@"currentRep"));
                        mediaURL = firstURLFromFileURLContainer(rep);
                    }
                    if (!mediaURL && asset) {
                        mediaURL = firstURLFromFileURLContainer(asset);
                    }
                }
            } @catch (__unused NSException *e) {}
        }
    });
    return mediaURL;
}

static NSString *SpliceKitUprezzerNormalizedPath(NSString *path) {
    return path.length > 0 ? [path stringByResolvingSymlinksInPath] : @"";
}

static double SpliceKitUprezzerCMTimeSeconds(SpliceKitUprezzerCMTime time) {
    return time.timescale > 0 ? ((double)time.value / (double)time.timescale) : -1.0;
}

static id SpliceKitUprezzerMediaRangeForClip(id clip) {
    if (!clip) return nil;
    Class rangeObjClass = objc_getClass("FigTimeRangeAndObject");
    if (!rangeObjClass) return nil;

    __block id mediaRange = nil;
    SpliceKitUprezzerCMTimeRange clipRange = {0};
    if (!SpliceKitUprezzerClipRangeForClip(clip, &clipRange)) return nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            SEL rangeAndObjSel = NSSelectorFromString(@"rangeAndObjectWithRange:andObject:");
            if ([(id)rangeObjClass respondsToSelector:rangeAndObjSel]) {
                mediaRange = ((id (*)(id, SEL, SpliceKitUprezzerCMTimeRange, id))objc_msgSend)(
                    (id)rangeObjClass, rangeAndObjSel, clipRange, clip);
            }
        } @catch (__unused NSException *e) {}
    });
    return mediaRange;
}

static id SpliceKitUprezzerTimelineSequence(id timeline) {
    if (!timeline) return nil;
    SEL seqSel = NSSelectorFromString(@"sequence");
    return [timeline respondsToSelector:seqSel]
        ? ((id (*)(id, SEL))objc_msgSend)(timeline, seqSel) : nil;
}

static id SpliceKitUprezzerTimelinePrimaryContainer(id sequence) {
    if (!sequence) return nil;
    SEL primarySel = NSSelectorFromString(@"primaryObject");
    if ([sequence respondsToSelector:primarySel]) {
        id container = ((id (*)(id, SEL))objc_msgSend)(sequence, primarySel);
        if (container) return container;
    }
    return sequence;
}

static NSArray *SpliceKitUprezzerTimelineContainedItems(id sequence, id container) {
    id items = nil;
    if (container && [container respondsToSelector:@selector(containedItems)]) {
        items = ((id (*)(id, SEL))objc_msgSend)(container, @selector(containedItems));
    } else if (sequence && [sequence respondsToSelector:@selector(containedItems)]) {
        items = ((id (*)(id, SEL))objc_msgSend)(sequence, @selector(containedItems));
    }
    if ([items isKindOfClass:[NSSet class]]) items = [(NSSet *)items allObjects];
    return [items isKindOfClass:[NSArray class]] ? items : nil;
}

static NSArray *SpliceKitUprezzerChildTimelineObjects(id object) {
    if (!object) return nil;
    NSArray<NSString *> *selectors = @[@"containedItems", @"childItems", @"items"];
    for (NSString *selectorName in selectors) {
        SEL sel = NSSelectorFromString(selectorName);
        if (![object respondsToSelector:sel]) continue;
        id children = ((id (*)(id, SEL))objc_msgSend)(object, sel);
        if ([children isKindOfClass:[NSSet class]]) children = [(NSSet *)children allObjects];
        if ([children isKindOfClass:[NSArray class]] && [(NSArray *)children count] > 0) {
            return children;
        }
    }
    return nil;
}

static void SpliceKitUprezzerAppendTimelineObjectRecursively(id object,
                                                             NSMutableArray *results,
                                                             NSHashTable *visited) {
    if (!object || !results || !visited || [visited containsObject:object]) return;
    [visited addObject:object];
    [results addObject:object];
    for (id child in SpliceKitUprezzerChildTimelineObjects(object) ?: @[]) {
        SpliceKitUprezzerAppendTimelineObjectRecursively(child, results, visited);
    }
}

static NSArray *SpliceKitUprezzerFlattenTimelineObjects(NSArray *objects) {
    if (![objects isKindOfClass:[NSArray class]] || objects.count == 0) return @[];
    NSMutableArray *results = [NSMutableArray array];
    NSHashTable *visited = [NSHashTable weakObjectsHashTable];
    for (id object in objects) {
        SpliceKitUprezzerAppendTimelineObjectRecursively(object, results, visited);
    }
    return results;
}

static BOOL SpliceKitUprezzerTimelinePlacementInContainer(id object,
                                                          id container,
                                                          double *outStart,
                                                          double *outDuration) {
    if (SpliceKitUprezzerTimelinePlacementForObject(object, outStart, outDuration)) return YES;
    if (!object || !container || !outStart || !outDuration) return NO;

    __block BOOL success = NO;
    __block double start = 0.0;
    __block double duration = 0.0;
    SpliceKit_executeOnMainThread(^{
        @try {
            SEL rangeSel = NSSelectorFromString(@"effectiveRangeOfObject:");
            if (![container respondsToSelector:rangeSel]) return;
            SpliceKitUprezzerCMTimeRange range =
                ((SpliceKitUprezzerCMTimeRange (*)(id, SEL, id))SPLICEKIT_UPREZZER_STRET_MSG)(container, rangeSel, object);
            double startSeconds = SpliceKitUprezzerCMTimeSeconds(range.start);
            double durationSeconds = SpliceKitUprezzerCMTimeSeconds(range.duration);
            if (startSeconds >= 0.0 && durationSeconds >= 0.0) {
                start = startSeconds;
                duration = durationSeconds;
                success = YES;
            }
        } @catch (__unused NSException *e) {}
    });

    if (success) {
        *outStart = start;
        *outDuration = duration;
    }
    return success;
}

static BOOL SpliceKitUprezzerTimelineSelectionContainsHandle(NSString *handle) {
    if (handle.length == 0) return NO;
    __block BOOL contains = NO;
    SpliceKit_executeOnMainThread(^{
        id target = SpliceKit_resolveHandle(handle);
        if (!target) return;
        for (id selected in SpliceKitUprezzerTimelineSelectedObjects()) {
            if (selected == target) {
                contains = YES;
                return;
            }
        }
    });
    return contains;
}

static BOOL SpliceKitUprezzerBrowserSelectionContainsClip(id clip) {
    if (!clip) return NO;
    __block BOOL contains = NO;
    SpliceKit_executeOnMainThread(^{
        for (id selected in SpliceKitUprezzerBrowserSelectedObjects()) {
            if (selected == clip) {
                contains = YES;
                return;
            }
        }
    });
    return contains;
}

static BOOL SpliceKitUprezzerWaitForSelectionCheck(BOOL (^probe)(void), NSTimeInterval timeout) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    do {
        if (probe()) return YES;
        [NSThread sleepForTimeInterval:0.05];
    } while ([deadline timeIntervalSinceNow] > 0.0);
    return NO;
}

static BOOL SpliceKitUprezzerPrepareExplicitPasteboardForClip(id clip,
                                                              NSString **outPasteboardName,
                                                              NSString **outError) {
    if (!clip) {
        if (outError) *outError = @"Imported clip is unavailable.";
        return NO;
    }

    id mediaRange = SpliceKitUprezzerMediaRangeForClip(clip);
    NSPasteboard *generalPB = [NSPasteboard generalPasteboard];
    [generalPB clearContents];

    Class ffPasteboardClass = objc_getClass("FFPasteboard");
    if (!ffPasteboardClass) {
        if (outError) *outError = @"FFPasteboard class not found.";
        return NO;
    }

    id ffPasteboard = ((id (*)(id, SEL))objc_msgSend)((id)ffPasteboardClass, @selector(alloc));
    SEL initWithNameSel = NSSelectorFromString(@"initWithName:");
    if (![ffPasteboard respondsToSelector:initWithNameSel]) {
        if (outError) *outError = @"FFPasteboard does not support initWithName:.";
        return NO;
    }

    NSString *pasteboardName = NSPasteboardNameGeneral;
    ffPasteboard = ((id (*)(id, SEL, id))objc_msgSend)(ffPasteboard, initWithNameSel, pasteboardName);
    BOOL wroteData = NO;

    SEL writeRangesSel = NSSelectorFromString(@"writeRangesOfMedia:options:");
    if (mediaRange && [ffPasteboard respondsToSelector:writeRangesSel]) {
        wroteData = ((BOOL (*)(id, SEL, id, id))objc_msgSend)(ffPasteboard, writeRangesSel, @[mediaRange], nil);
    }

    if (!wroteData) {
        SEL writeAnchoredSel = NSSelectorFromString(@"writeAnchoredObjects:options:");
        if ([ffPasteboard respondsToSelector:writeAnchoredSel]) {
            wroteData = ((BOOL (*)(id, SEL, id, id))objc_msgSend)(ffPasteboard, writeAnchoredSel, @[clip], nil);
        }
    }

    if (!wroteData) {
        if (outError) *outError = @"Could not prepare explicit clip data for replacement.";
        return NO;
    }

    if (outPasteboardName) *outPasteboardName = pasteboardName;
    return YES;
}

static NSDictionary *SpliceKitUprezzerPerformTimelineEditAction(id timeline, NSString *selectorName) {
    if (selectorName.length == 0) {
        return @{@"error": @"No edit selector provided."};
    }

    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            SEL selector = NSSelectorFromString(selectorName);
            if (timeline && [timeline respondsToSelector:selector]) {
                ((void (*)(id, SEL, id))objc_msgSend)(timeline, selector, nil);
                result = @{@"status": @"ok", @"primitive": @"timeline_direct"};
                return;
            }

            id app = ((id (*)(id, SEL))objc_msgSend)(objc_getClass("NSApplication"), @selector(sharedApplication));
            BOOL sent = ((BOOL (*)(id, SEL, SEL, id, id))objc_msgSend)(
                app, @selector(sendAction:to:from:), selector, nil, nil);
            result = sent
                ? @{@"status": @"ok", @"primitive": @"responder_chain"}
                : @{@"error": [NSString stringWithFormat:@"No responder handled %@", selectorName]};
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result ?: @{@"error": @"Media action failed."};
}

static id SpliceKitUprezzerMakeExplicitReplaceAction(NSInteger replaceType, NSString **outDescription) {
    __block id action = nil;
    __block NSString *actionDescription = nil;

    SpliceKit_executeOnMainThread(^{
        @try {
            Class actionClass = objc_getClass("FFEditAction");
            if (!actionClass) return;

            SEL replaceSel = NSSelectorFromString(@"editActionOfReplaceType:");
            if ([actionClass respondsToSelector:replaceSel]) {
                action = ((id (*)(id, SEL, int))objc_msgSend)((id)actionClass, replaceSel, (int)replaceType);
            }

            if (!action) {
                SEL kindSel = NSSelectorFromString(@"editActionOfKind:backTimed:trackType:");
                if ([actionClass respondsToSelector:kindSel]) {
                    action = ((id (*)(id, SEL, int, BOOL, id))objc_msgSend)((id)actionClass,
                                                                             kindSel,
                                                                             6,
                                                                             NO,
                                                                             @"all");
                }
            }

            if (action && [action respondsToSelector:@selector(description)]) {
                id desc = ((id (*)(id, SEL))objc_msgSend)(action, @selector(description));
                if ([desc isKindOfClass:[NSString class]]) {
                    actionDescription = desc;
                }
            }
        } @catch (NSException *e) {
            SpliceKit_log(@"[Uprezzer][Replace] Could not build explicit replace action: %@", e.reason);
        }
    });

    if (outDescription) *outDescription = actionDescription;
    return action;
}

static NSDictionary *SpliceKitUprezzerPerformExplicitReplace(id timeline,
                                                             NSString *pasteboardName,
                                                             NSInteger replaceType) {
    __block NSDictionary *result = nil;

    SpliceKit_executeOnMainThread(^{
        @try {
            if (!timeline) {
                result = @{@"error": @"No active timeline module."};
                return;
            }

            SEL performSel = NSSelectorFromString(@"performEditAction:fromPasteboardWithName:fromAnimation:");
            if (![timeline respondsToSelector:performSel]) {
                result = @{@"error": @"Timeline module does not support explicit edit actions."};
                return;
            }

            NSString *actionDescription = nil;
            id action = SpliceKitUprezzerMakeExplicitReplaceAction(replaceType, &actionDescription);
            if (!action) {
                result = @{@"error": @"Could not build the native replace action."};
                return;
            }

            NSString *resolvedPasteboardName = pasteboardName.length > 0 ? pasteboardName : NSPasteboardNameGeneral;
            ((void (*)(id, SEL, id, id, BOOL))objc_msgSend)(timeline,
                                                            performSel,
                                                            action,
                                                            resolvedPasteboardName,
                                                            NO);
            result = @{
                @"status": @"ok",
                @"primitive": @"explicit_replace_action",
                @"actionDescription": actionDescription ?: @"Replace"
            };
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });

    return result ?: @{@"error": @"Explicit replace failed."};
}

static NSString *SpliceKitUprezzerMediaIdentityForPath(NSString *path) {
    if (path.length == 0) return @"";
    NSString *filename = [[[path lastPathComponent] stringByDeletingPathExtension] lowercaseString];
    static NSRegularExpression *suffixRegex = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        suffixRegex = [NSRegularExpression regularExpressionWithPattern:@"\\s*\\(fcp\\d+\\)$"
                                                                options:NSRegularExpressionCaseInsensitive
                                                                  error:nil];
    });
    return [suffixRegex stringByReplacingMatchesInString:filename
                                                 options:0
                                                   range:NSMakeRange(0, filename.length)
                                            withTemplate:@""];
}

static BOOL SpliceKitUprezzerPathMatchesTargets(NSString *candidatePath, NSArray<NSString *> *targetPaths) {
    if (candidatePath.length == 0 || targetPaths.count == 0) return NO;
    NSString *candidateIdentity = SpliceKitUprezzerMediaIdentityForPath(candidatePath);
    NSString *candidateExtension = [[candidatePath pathExtension] lowercaseString];
    for (NSString *targetPath in targetPaths) {
        if (targetPath.length == 0) continue;
        if ([candidatePath isEqualToString:targetPath]) return YES;
        NSString *targetIdentity = SpliceKitUprezzerMediaIdentityForPath(targetPath);
        NSString *targetExtension = [[targetPath pathExtension] lowercaseString];
        if (candidateIdentity.length > 0 &&
            targetIdentity.length > 0 &&
            [candidateIdentity isEqualToString:targetIdentity] &&
            ((candidateExtension.length == 0 && targetExtension.length == 0) ||
             [candidateExtension isEqualToString:targetExtension])) {
            return YES;
        }
    }
    return NO;
}

static NSDictionary *SpliceKitUprezzerVerifyReplacementMatch(SpliceKitUprezzerSelectedItem *item,
                                                             NSString *originalPath,
                                                             NSString *outputPath,
                                                             id importedClip) {
    if (outputPath.length == 0 && !importedClip) return nil;
    NSString *normalizedOutput = SpliceKitUprezzerNormalizedPath(outputPath);
    NSString *normalizedOriginal = SpliceKitUprezzerNormalizedPath(originalPath);
    NSString *normalizedImportedClipPath = SpliceKitUprezzerNormalizedPath(SpliceKitUprezzerMediaURLForObject(importedClip).path);
    NSString *expectedImportedName = SpliceKitUprezzerTrimmedString([item.importedClipName stringByDeletingPathExtension]);
    if (expectedImportedName.length == 0) {
        expectedImportedName = SpliceKitUprezzerTrimmedString([[outputPath lastPathComponent] stringByDeletingPathExtension]);
    }
    NSMutableArray<NSString *> *targetPaths = [NSMutableArray array];
    if (normalizedOutput.length > 0) [targetPaths addObject:normalizedOutput];
    if (normalizedImportedClipPath.length > 0 &&
        ![targetPaths containsObject:normalizedImportedClipPath]) {
        [targetPaths addObject:normalizedImportedClipPath];
    }
    double expectedStart = item.timelineStart;
    double expectedDuration = item.timelineDuration;
    double timeTolerance = MAX(0.08, (1.0 / MAX(item.frameRate, 24.0)) * 2.0);

    __block NSDictionary *match = nil;
    __block BOOL originalStillPresent = NO;
    __block NSString *handleResolvedPath = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            id originalObject = SpliceKit_resolveHandle(item.objectHandle);
            if (originalObject) {
                handleResolvedPath = SpliceKitUprezzerNormalizedPath(SpliceKitUprezzerMediaURLForObject(originalObject).path);
                if (SpliceKitUprezzerPathMatchesTargets(handleResolvedPath, targetPaths)) {
                    match = @{
                        @"path": handleResolvedPath,
                        @"verifiedBy": @"original_handle"
                    };
                    return;
                }
            }

            id timeline = SpliceKit_getActiveTimelineModule();
            id sequence = SpliceKitUprezzerTimelineSequence(timeline);
            id container = SpliceKitUprezzerTimelinePrimaryContainer(sequence);
            NSArray *selectedObjects = SpliceKitUprezzerFlattenTimelineObjects(SpliceKitUprezzerTimelineSelectedObjects());
            for (id selectedObject in selectedObjects) {
                NSString *candidatePath = SpliceKitUprezzerNormalizedPath(SpliceKitUprezzerMediaURLForObject(selectedObject).path);
                NSString *candidateName = SpliceKitUprezzerTrimmedString(SpliceKitUprezzerDisplayNameForObject(selectedObject));

                double start = -1.0;
                double duration = -1.0;
                if (!SpliceKitUprezzerTimelinePlacementInContainer(selectedObject, container, &start, &duration)) {
                    continue;
                }

                BOOL pathMatch = SpliceKitUprezzerPathMatchesTargets(candidatePath, targetPaths);
                BOOL nameMatch = expectedImportedName.length > 0 &&
                    [candidateName caseInsensitiveCompare:expectedImportedName] == NSOrderedSame;
                if ((pathMatch || nameMatch) && fabs(start - expectedStart) <= timeTolerance) {
                    match = @{
                        @"path": candidatePath ?: @"",
                        @"start": @(start),
                        @"duration": @(duration),
                        @"expectedDuration": @(expectedDuration),
                        @"verifiedBy": pathMatch ? @"selected_timeline_item" : @"selected_timeline_name"
                    };
                    return;
                }
            }

            NSArray *items = SpliceKitUprezzerFlattenTimelineObjects(SpliceKitUprezzerTimelineContainedItems(sequence, container));
            for (id timelineItem in items) {
                NSString *candidatePath = SpliceKitUprezzerNormalizedPath(SpliceKitUprezzerMediaURLForObject(timelineItem).path);
                NSString *candidateName = SpliceKitUprezzerTrimmedString(SpliceKitUprezzerDisplayNameForObject(timelineItem));

                double start = -1.0;
                double duration = -1.0;
                if (!SpliceKitUprezzerTimelinePlacementInContainer(timelineItem, container, &start, &duration)) {
                    continue;
                }

                if (candidatePath.length > 0 &&
                    normalizedOriginal.length > 0 &&
                    [candidatePath isEqualToString:normalizedOriginal] &&
                    fabs(start - expectedStart) <= timeTolerance) {
                    originalStillPresent = YES;
                }

                BOOL pathMatch = SpliceKitUprezzerPathMatchesTargets(candidatePath, targetPaths);
                BOOL nameMatch = expectedImportedName.length > 0 &&
                    [candidateName caseInsensitiveCompare:expectedImportedName] == NSOrderedSame;

                if (!pathMatch && !nameMatch) continue;
                if (fabs(start - expectedStart) > timeTolerance) continue;

                match = @{
                    @"path": candidatePath ?: @"",
                    @"start": @(start),
                    @"duration": @(duration),
                    @"expectedDuration": @(expectedDuration),
                    @"verifiedBy": nameMatch && !pathMatch ? @"timeline_name_scan" : @"timeline_scan"
                };
                return;
            }
        } @catch (NSException *e) {
            SpliceKit_log(@"[Uprezzer][Replace] Verification scan failed: %@", e.reason);
        }
    });

    if (match &&
        ([match[@"verifiedBy"] isEqualToString:@"selected_timeline_item"] ||
         [match[@"verifiedBy"] isEqualToString:@"selected_timeline_name"])) {
        return match;
    }
    if (match && !originalStillPresent) return match;
    if (match && [match[@"verifiedBy"] isEqualToString:@"original_handle"]) return match;
    return nil;
}

static NSDictionary *SpliceKitUprezzerInspectMediaAtPath(NSString *path) {
    if (path.length == 0) return @{@"error": @"This item has no file-backed media source."};

    if (![[NSFileManager defaultManager] isReadableFileAtPath:path]) {
        return @{@"error": @"Source clip is offline."};
    }

    NSURL *url = [NSURL fileURLWithPath:path];
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
    NSArray<AVAssetTrack *> *videoTracks = [asset tracksWithMediaType:AVMediaTypeVideo];
    if (videoTracks.count == 0) {
        return @{@"error": @"This item is not file-backed video media."};
    }

    AVAssetTrack *videoTrack = videoTracks.firstObject;
    CGSize size = videoTrack.naturalSize;
    CGAffineTransform tx = videoTrack.preferredTransform;
    CGRect rect = CGRectApplyAffineTransform(CGRectMake(0, 0, size.width, size.height), tx);
    NSInteger width = (NSInteger)llround(fabs(rect.size.width));
    NSInteger height = (NSInteger)llround(fabs(rect.size.height));
    if (width <= 0 || height <= 0) {
        width = (NSInteger)llround(fabs(size.width));
        height = (NSInteger)llround(fabs(size.height));
    }

    double duration = CMTimeGetSeconds(asset.duration);
    double frameRate = videoTrack.nominalFrameRate > 0 ? videoTrack.nominalFrameRate : 24.0;

    return @{
        @"width": @(MAX(width, 1)),
        @"height": @(MAX(height, 1)),
        @"duration": @(isfinite(duration) ? MAX(duration, 0.0) : 0.0),
        @"frameRate": @(frameRate)
    };
}

static NSString *SpliceKitUprezzerEventNameForImportChoice(BOOL useDedicatedEvent) {
    if (useDedicatedEvent) return @"Uprezzer Outputs";
    NSString *current = SpliceKitUprezzerCurrentTimelineEventName();
    return current.length > 0 ? current : @"Uprezzer Outputs";
}

static NSString *SpliceKitUprezzerEscapeXML(NSString *input) {
    NSString *s = SpliceKitUprezzerString(input);
    s = [s stringByReplacingOccurrencesOfString:@"&" withString:@"&amp;"];
    s = [s stringByReplacingOccurrencesOfString:@"\"" withString:@"&quot;"];
    s = [s stringByReplacingOccurrencesOfString:@"<" withString:@"&lt;"];
    s = [s stringByReplacingOccurrencesOfString:@">" withString:@"&gt;"];
    s = [s stringByReplacingOccurrencesOfString:@"'" withString:@"&apos;"];
    return s;
}

static NSString *SpliceKitUprezzerCMTimeString(CMTime time, NSString *fallback) {
    if (CMTIME_IS_VALID(time) && !CMTIME_IS_INDEFINITE(time) && time.timescale > 0 && time.value >= 0) {
        return [NSString stringWithFormat:@"%lld/%ds", time.value, time.timescale];
    }
    return fallback ?: @"2400/2400s";
}

static NSDictionary *SpliceKitUprezzerInspectRenderedMedia(NSString *path) {
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:path] options:nil];
    NSArray<AVAssetTrack *> *videoTracks = [asset tracksWithMediaType:AVMediaTypeVideo];
    NSArray<AVAssetTrack *> *audioTracks = [asset tracksWithMediaType:AVMediaTypeAudio];
    if (videoTracks.count == 0) {
        return @{@"error": @"Rendered output does not contain a video track."};
    }

    AVAssetTrack *videoTrack = videoTracks.firstObject;
    CGSize size = videoTrack.naturalSize;
    CGAffineTransform tx = videoTrack.preferredTransform;
    CGRect rect = CGRectApplyAffineTransform(CGRectMake(0, 0, size.width, size.height), tx);
    NSInteger width = (NSInteger)llround(fabs(rect.size.width));
    NSInteger height = (NSInteger)llround(fabs(rect.size.height));
    if (width <= 0 || height <= 0) {
        width = (NSInteger)llround(fabs(size.width));
        height = (NSInteger)llround(fabs(size.height));
    }

    NSString *frameDuration = @"100/2400s";
    if (videoTrack.nominalFrameRate > 0) {
        int timescale = 2400;
        int value = (int)lrint((double)timescale / videoTrack.nominalFrameRate);
        if (value > 0) {
            frameDuration = [NSString stringWithFormat:@"%d/%ds", value, timescale];
        }
    }

    return @{
        @"duration": SpliceKitUprezzerCMTimeString(asset.duration, @"2400/2400s"),
        @"frameDuration": frameDuration,
        @"width": @(MAX(width, 1)),
        @"height": @(MAX(height, 1)),
        @"hasVideo": @YES,
        @"hasAudio": @(audioTracks.count > 0),
        @"audioRate": @(audioTracks.count > 0 ? 48000 : 0)
    };
}

static NSString *SpliceKitUprezzerImportXMLForOutput(NSString *clipName,
                                                     NSString *outputPath,
                                                     NSDictionary *mediaInfo,
                                                     NSString *eventName) {
    NSString *uid = [[NSUUID UUID] UUIDString];
    NSString *fmtID = [NSString stringWithFormat:@"fmt_%@", [uid substringToIndex:8]];
    NSString *assetID = [NSString stringWithFormat:@"asset_%@", [uid substringToIndex:8]];
    NSString *escapedClip = SpliceKitUprezzerEscapeXML(clipName ?: @"Upscaled Clip");
    NSString *escapedEvent = SpliceKitUprezzerEscapeXML(eventName ?: @"Uprezzer Outputs");
    NSString *mediaURL = [[[NSURL fileURLWithPath:outputPath] absoluteURL] absoluteString];
    NSString *duration = mediaInfo[@"duration"] ?: @"2400/2400s";
    NSString *frameDuration = mediaInfo[@"frameDuration"] ?: @"100/2400s";
    int width = [mediaInfo[@"width"] intValue] ?: 1920;
    int height = [mediaInfo[@"height"] intValue] ?: 1080;
    BOOL hasAudio = [mediaInfo[@"hasAudio"] boolValue];
    int audioRate = [mediaInfo[@"audioRate"] intValue] ?: 48000;

    NSMutableString *xml = [NSMutableString string];
    [xml appendString:@"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"];
    [xml appendString:@"<!DOCTYPE fcpxml>\n"];
    [xml appendString:@"<fcpxml version=\"1.14\">\n"];
    [xml appendString:@"    <resources>\n"];
    [xml appendFormat:@"        <format id=\"%@\" frameDuration=\"%@\" width=\"%d\" height=\"%d\" name=\"FFVideoFormat%dx%dp\"/>\n",
        fmtID, frameDuration, width, height, width, height];
    [xml appendFormat:@"        <asset id=\"%@\" name=\"%@\" uid=\"%@\" start=\"0s\" duration=\"%@\" hasVideo=\"1\" hasAudio=\"%@\" format=\"%@\" audioSources=\"%@\" audioChannels=\"2\" audioRate=\"%d\">\n",
        assetID, escapedClip, uid, duration, hasAudio ? @"1" : @"0", fmtID, hasAudio ? @"1" : @"0", audioRate];
    [xml appendFormat:@"            <media-rep kind=\"original-media\" src=\"%@\"/>\n", mediaURL];
    [xml appendString:@"        </asset>\n"];
    [xml appendString:@"    </resources>\n"];
    [xml appendFormat:@"    <event name=\"%@\">\n", escapedEvent];
    [xml appendFormat:@"        <asset-clip ref=\"%@\" name=\"%@\" duration=\"%@\" start=\"0s\"/>\n",
        assetID, escapedClip, duration];
    [xml appendString:@"    </event>\n"];
    [xml appendString:@"</fcpxml>\n"];
    return xml;
}

static id SpliceKitUprezzerFindClipNamedInEvent(NSString *clipName,
                                                NSString *eventName,
                                                NSString *outputPath,
                                                NSString **outMatchedBy,
                                                NSString **outResolvedPath) {
    __block id foundClip = nil;
    NSString *needle = [clipName lowercaseString];
    NSString *eventNeedle = [eventName lowercaseString];
    NSString *normalizedOutput = SpliceKitUprezzerNormalizedPath(outputPath);
    __block NSString *matchedBy = nil;
    __block NSString *resolvedPath = nil;

    SpliceKit_executeOnMainThread(^{
        @try {
            id libs = ((id (*)(id, SEL))objc_msgSend)(objc_getClass("FFLibraryDocument"), @selector(copyActiveLibraries));
            if (![libs isKindOfClass:[NSArray class]] || [(NSArray *)libs count] == 0) return;

            id library = [(NSArray *)libs firstObject];
            SEL eventsSel = NSSelectorFromString(@"events");
            id events = [library respondsToSelector:eventsSel]
                ? ((id (*)(id, SEL))objc_msgSend)(library, eventsSel) : nil;
            if (![events isKindOfClass:[NSArray class]]) return;

            for (id event in (NSArray *)events) {
                NSString *candidateEvent = SpliceKitUprezzerDisplayNameForObject(event) ?: @"";
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
                    NSString *candidateName = SpliceKitUprezzerDisplayNameForObject(clip) ?: @"";
                    NSString *candidatePath = SpliceKitUprezzerNormalizedPath(SpliceKitUprezzerMediaURLForObject(clip).path);
                    if (normalizedOutput.length > 0 &&
                        candidatePath.length > 0 &&
                        [candidatePath isEqualToString:normalizedOutput]) {
                        foundClip = clip;
                        matchedBy = @"output_path";
                        resolvedPath = candidatePath;
                        return;
                    }
                    if ([[candidateName lowercaseString] isEqualToString:needle]) {
                        foundClip = clip;
                        matchedBy = @"display_name";
                        resolvedPath = candidatePath;
                        return;
                    }
                }
            }
        } @catch (NSException *e) {
            SpliceKit_log(@"[Uprezzer] Clip lookup failed: %@", e.reason);
        }
    });
    if (outMatchedBy) *outMatchedBy = matchedBy;
    if (outResolvedPath) *outResolvedPath = resolvedPath;
    return foundClip;
}

static BOOL SpliceKitUprezzerSelectClipInBrowser(id clip) {
    __block BOOL selected = NO;
    if (!clip) return NO;

    SpliceKit_executeOnMainThread(^{
        @try {
            id app = ((id (*)(id, SEL))objc_msgSend)(objc_getClass("NSApplication"), @selector(sharedApplication));
            id delegate = ((id (*)(id, SEL))objc_msgSend)(app, @selector(delegate));
            if (!delegate) return;

            SpliceKitUprezzerCMTimeRange clipRange = {0};
            id mediaRange = SpliceKitUprezzerMediaRangeForClip(clip);
            if (!mediaRange || !SpliceKitUprezzerClipRangeForClip(clip, &clipRange)) return;

            id appController = ((id (*)(id, SEL))objc_msgSend)(
                objc_getClass("PEAppController"), NSSelectorFromString(@"appController"));
            id organizerContainer = appController &&
                [appController respondsToSelector:NSSelectorFromString(@"mediaEventOrganizerContainer")]
                    ? ((id (*)(id, SEL))objc_msgSend)(appController, NSSelectorFromString(@"mediaEventOrganizerContainer"))
                    : nil;
            id organizer = organizerContainer &&
                [organizerContainer respondsToSelector:NSSelectorFromString(@"activeOrganizerModule")]
                    ? ((id (*)(id, SEL))objc_msgSend)(organizerContainer, NSSelectorFromString(@"activeOrganizerModule"))
                    : nil;
            if (!organizer) {
                SEL orgSel = NSSelectorFromString(@"organizerModule");
                organizer = [delegate respondsToSelector:orgSel]
                    ? ((id (*)(id, SEL))objc_msgSend)(delegate, orgSel) : nil;
            }

            id mediaBrowser = nil;
            id mediaDetail = organizer &&
                [organizer respondsToSelector:NSSelectorFromString(@"mediaDetailContainerModule")]
                    ? ((id (*)(id, SEL))objc_msgSend)(organizer, NSSelectorFromString(@"mediaDetailContainerModule"))
                    : nil;
            mediaBrowser = mediaDetail &&
                [mediaDetail respondsToSelector:NSSelectorFromString(@"getActiveMediaBrowser")]
                    ? ((id (*)(id, SEL))objc_msgSend)(mediaDetail, NSSelectorFromString(@"getActiveMediaBrowser"))
                    : nil;
            if (!mediaBrowser && organizer &&
                [organizer respondsToSelector:NSSelectorFromString(@"filmstripModule")]) {
                mediaBrowser = ((id (*)(id, SEL))objc_msgSend)(organizer, NSSelectorFromString(@"filmstripModule"));
            }
            if (!mediaBrowser && organizer &&
                [organizer respondsToSelector:NSSelectorFromString(@"itemsModule")]) {
                mediaBrowser = ((id (*)(id, SEL))objc_msgSend)(organizer, NSSelectorFromString(@"itemsModule"));
            }
            if (!mediaBrowser && organizerContainer &&
                [organizerContainer respondsToSelector:NSSelectorFromString(@"getActiveMediaBrowser")]) {
                mediaBrowser = ((id (*)(id, SEL))objc_msgSend)(organizerContainer, NSSelectorFromString(@"getActiveMediaBrowser"));
            }

            if ([organizer respondsToSelector:NSSelectorFromString(@"setSidebarHidden:")]) {
                ((void (*)(id, SEL, BOOL))objc_msgSend)(organizer, NSSelectorFromString(@"setSidebarHidden:"), NO);
            }
            if ([organizer respondsToSelector:NSSelectorFromString(@"setLibrarySidebarActive:")]) {
                ((void (*)(id, SEL, BOOL))objc_msgSend)(organizer, NSSelectorFromString(@"setLibrarySidebarActive:"), YES);
            }
            if ([mediaBrowser respondsToSelector:NSSelectorFromString(@"_ensureModuleIsVisible")]) {
                ((void (*)(id, SEL))objc_msgSend)(mediaBrowser, NSSelectorFromString(@"_ensureModuleIsVisible"));
            }

            SpliceKitUprezzerCMTime zero = {0, clipRange.duration.timescale > 0 ? clipRange.duration.timescale : 6000, 1, 0};
            SEL revealSel = NSSelectorFromString(@"revealObject:andRange:atPlayhead:");
            if (organizer && [organizer respondsToSelector:revealSel]) {
                ((BOOL (*)(id, SEL, id, SpliceKitUprezzerCMTimeRange, SpliceKitUprezzerCMTime))objc_msgSend)(
                    organizer, revealSel, clip, clipRange, zero);
            }
            SEL revealRangesSel = NSSelectorFromString(@"revealMediaRanges:");
            if (organizer && [organizer respondsToSelector:revealRangesSel]) {
                ((void (*)(id, SEL, id))objc_msgSend)(organizer, revealRangesSel, @[mediaRange]);
            }

            SEL selectSel = NSSelectorFromString(@"_selectMediaRanges:");
            SEL setSelectionSel = NSSelectorFromString(@"setSelection:");
            SEL setCurrentSel = NSSelectorFromString(@"setCurrentSelection:");
            if (mediaBrowser && [mediaBrowser respondsToSelector:selectSel]) {
                ((void (*)(id, SEL, id))objc_msgSend)(mediaBrowser, selectSel, @[mediaRange]);
                selected = YES;
            } else if (mediaBrowser && [mediaBrowser respondsToSelector:setSelectionSel]) {
                ((void (*)(id, SEL, id))objc_msgSend)(mediaBrowser, setSelectionSel, @[mediaRange]);
                selected = YES;
            } else if (organizerContainer && [organizerContainer respondsToSelector:setCurrentSel]) {
                ((void (*)(id, SEL, id))objc_msgSend)(organizerContainer, setCurrentSel, @[mediaRange]);
                selected = YES;
            }
            if (selected) {
                [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.12]];
            }
        } @catch (NSException *e) {
            SpliceKit_log(@"[Uprezzer] Browser selection failed: %@", e.reason);
        }
    });
    return selected;
}

static BOOL SpliceKitUprezzerSelectTimelineItemWithHandle(NSString *handle) {
    if (handle.length == 0) return NO;
    __block BOOL success = NO;
    SpliceKit_executeOnMainThread(^{
        @try {
            id timeline = SpliceKit_getActiveTimelineModule();
            id item = SpliceKit_resolveHandle(handle);
            if (!timeline || !item) return;

            SEL setSel = NSSelectorFromString(@"setSelectedItems:");
            if (![timeline respondsToSelector:setSel]) {
                setSel = NSSelectorFromString(@"_setSelectedItems:");
            }
            if (![timeline respondsToSelector:setSel]) return;
            ((void (*)(id, SEL, id))objc_msgSend)(timeline, setSel, @[item]);
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.08]];
            success = YES;
        } @catch (NSException *e) {
            SpliceKit_log(@"[Uprezzer] Timeline selection failed: %@", e.reason);
        }
    });
    return success;
}

static NSDictionary *SpliceKitUprezzerPerformMediaEditAction(NSString *selectorName) {
    __block id timeline = nil;
    SpliceKit_executeOnMainThread(^{
        timeline = SpliceKit_getActiveTimelineModule();
    });
    return SpliceKitUprezzerPerformTimelineEditAction(timeline, selectorName);
}

static NSString *SpliceKitUprezzerReplacementError(SpliceKitUprezzerSelectedItem *item,
                                                   id importedClip,
                                                   NSString *outputPath) {
    NSString *originalPath = item.sourcePath ?: @"";
    NSString *pasteboardError = nil;
    NSString *pasteboardName = nil;

    if (!SpliceKitUprezzerPrepareExplicitPasteboardForClip(importedClip, &pasteboardName, &pasteboardError)) {
        return [NSString stringWithFormat:@"Replacement skipped. %@", pasteboardError ?: @"Could not prepare explicit clip data."];
    }

    if (!SpliceKitUprezzerSelectTimelineItemWithHandle(item.objectHandle)) {
        return @"Replacement skipped. Could not re-select the original timeline clip.";
    }
    if (!SpliceKitUprezzerWaitForSelectionCheck(^BOOL{
        return SpliceKitUprezzerTimelineSelectionContainsHandle(item.objectHandle);
    }, 0.8)) {
        return @"Replacement skipped. Final Cut did not keep the target timeline clip selected.";
    }

    SpliceKit_log(@"[Uprezzer][Replace] begin clip=%@ start=%.4f duration=%.4f pasteboard=%@",
                  item.displayName ?: @"<clip>",
                  item.timelineStart,
                  item.timelineDuration,
                  pasteboardName ?: @"");
    __block id timeline = nil;
    SpliceKit_executeOnMainThread(^{
        timeline = SpliceKit_getActiveTimelineModule();
    });

    NSDictionary *replace = SpliceKitUprezzerPerformExplicitReplace(timeline, pasteboardName, 0);
    if (replace[@"error"]) {
        SpliceKit_log(@"[Uprezzer][Replace] explicit replace failed for %@: %@",
                      item.displayName ?: @"<clip>",
                      replace[@"error"]);

        NSDictionary *fallback = SpliceKitUprezzerPerformMediaEditAction(@"replaceWithSelectedMediaWhole:");
        if (!fallback[@"error"]) {
            replace = fallback;
            SpliceKit_log(@"[Uprezzer][Replace] fallback primitive=%@",
                          fallback[@"primitive"] ?: @"selected_media_replace");
        }
    } else {
        SpliceKit_log(@"[Uprezzer][Replace] primitive=%@ action=%@",
                      replace[@"primitive"] ?: @"explicit_replace_action",
                      replace[@"actionDescription"] ?: @"Replace");
    }

    if (replace[@"error"]) {
        return [NSString stringWithFormat:@"Replacement skipped. %@", replace[@"error"]];
    }

    NSDictionary *match = nil;
    NSString *importedPath = SpliceKitUprezzerMediaURLForObject(importedClip).path ?: @"";
    SpliceKit_log(@"[Uprezzer][Replace] targetPaths output=%@ importedClip=%@",
                  outputPath ?: @"",
                  importedPath);
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5.0];
    NSInteger pollCount = 0;
    do {
        pollCount += 1;
        match = SpliceKitUprezzerVerifyReplacementMatch(item, originalPath, outputPath, importedClip);
        if (match) break;
        [NSThread sleepForTimeInterval:0.12];
    } while ([deadline timeIntervalSinceNow] > 0.0);

    if (match) {
        SpliceKit_log(@"[Uprezzer][Replace] verified clip=%@ via=%@ polls=%ld",
                      item.displayName ?: @"<clip>",
                      match[@"verifiedBy"] ?: @"unknown",
                      (long)pollCount);
        return nil;
    }

    SpliceKit_log(@"[Uprezzer][Replace] verification failed clip=%@ output=%@ polls=%ld",
                  item.displayName ?: @"<clip>",
                  outputPath ?: @"",
                  (long)pollCount);
    return @"Replacement skipped. Imported clip was added to the library, but the selected timeline clip could not be verified as replaced.";
}

static NSDictionary *SpliceKitUprezzerSelectionSnapshot(NSInteger factor) {
    NSArray *timelineSelection = SpliceKitUprezzerTimelineSelectedObjects();
    NSArray *rawSelection = timelineSelection;
    SpliceKitUprezzerSourceContext sourceContext = SpliceKitUprezzerSourceContextTimeline;
    if (rawSelection.count == 0) {
        rawSelection = SpliceKitUprezzerBrowserSelectedObjects();
        sourceContext = SpliceKitUprezzerSourceContextBrowser;
    }

    NSString *currentEvent = SpliceKitUprezzerCurrentTimelineEventName();
    NSMutableArray<SpliceKitUprezzerSelectedItem *> *items = [NSMutableArray array];
    NSMutableSet<NSString *> *reservedNames = [NSMutableSet set];
    NSInteger ordinal = 1;

    for (id object in rawSelection) {
        SpliceKitUprezzerSelectedItem *item = [[SpliceKitUprezzerSelectedItem alloc] init];
        item.itemID = [[NSUUID UUID] UUIDString];
        item.sourceContext = sourceContext;
        item.objectHandle = SpliceKit_storeHandle(object) ?: @"";
        item.objectClassName = NSStringFromClass([object class]) ?: @"";
        item.displayName = SpliceKitUprezzerDisplayNameForObject(object);
        if (item.displayName.length == 0) {
            item.displayName = [NSString stringWithFormat:@"Clip %ld", (long)ordinal];
        }
        item.eventName = SpliceKitUprezzerEventNameForObject(object) ?: currentEvent ?: @"";
        item.status = SpliceKitUprezzerItemStateQueued;
        item.detail = @"Ready for local upscale processing.";

        if (sourceContext == SpliceKitUprezzerSourceContextTimeline) {
            double start = 0.0;
            double duration = 0.0;
            if (SpliceKitUprezzerTimelinePlacementForObject(object, &start, &duration)) {
                item.timelineStart = start;
                item.timelineDuration = duration;
            }
        }

        id resolvedObject = item.objectHandle.length > 0 ? SpliceKit_resolveHandle(item.objectHandle) : object;
        NSURL *mediaURL = SpliceKitUprezzerMediaURLForObject(resolvedObject);
        if (!mediaURL || !mediaURL.isFileURL) {
            item.validationError = @"This item has no file-backed media source.";
            item.status = SpliceKitUprezzerItemStateSkipped;
            item.detail = item.validationError;
            [items addObject:item];
            ordinal++;
            continue;
        }

        item.sourcePath = mediaURL.path ?: @"";
        NSDictionary *mediaInfo = SpliceKitUprezzerInspectMediaAtPath(item.sourcePath);
        if (mediaInfo[@"error"]) {
            item.validationError = mediaInfo[@"error"];
            item.status = SpliceKitUprezzerItemStateSkipped;
            item.detail = item.validationError;
            [items addObject:item];
            ordinal++;
            continue;
        }

        item.width = [mediaInfo[@"width"] integerValue];
        item.height = [mediaInfo[@"height"] integerValue];
        item.duration = [mediaInfo[@"duration"] doubleValue];
        item.frameRate = [mediaInfo[@"frameRate"] doubleValue];
        item.plannedWidth = MAX(item.width * factor, 1);
        item.plannedHeight = MAX(item.height * factor, 1);

        NSString *plannedName = SpliceKitUprezzerMakeOutputFilename(item.displayName,
                                                                    factor,
                                                                    mediaURL.pathExtension,
                                                                    reservedNames);
        item.plannedOutputName = plannedName;
        [reservedNames addObject:plannedName.lowercaseString];
        item.detail = @"Ready";
        [items addObject:item];
        ordinal++;
    }

    return @{
        @"sourceContext": @(sourceContext),
        @"currentEvent": currentEvent ?: @"",
        @"items": items
    };
}

@interface SpliceKitUprezzerBatchRunner : NSObject
@property (nonatomic, copy) NSString *jobID;
@property (nonatomic, copy) NSString *fxPath;
@property (nonatomic, copy) NSString *destinationEventName;
@property (nonatomic) NSInteger scaleFactor;
@property (nonatomic) BOOL replaceTimeline;
@property (nonatomic) BOOL revealImported;
@property (nonatomic, copy) NSArray<SpliceKitUprezzerSelectedItem *> *items;
@property (nonatomic, strong) NSMutableArray<NSString *> *logLines;
@property (nonatomic, strong) NSTask *activeTask;
@property (nonatomic) BOOL cancelRequested;
@property (nonatomic, copy) void (^itemUpdateBlock)(SpliceKitUprezzerSelectedItem *item, NSString *state, NSString *detail, double itemProgress, double overallProgress);
@property (nonatomic, copy) void (^stageBlock)(NSString *stageText, double overallProgress);
@property (nonatomic, copy) void (^logBlock)(NSString *line);
@property (nonatomic, copy) void (^completionBlock)(NSDictionary *summary);
- (void)start;
- (void)cancel;
@end

@implementation SpliceKitUprezzerBatchRunner

- (instancetype)init {
    self = [super init];
    if (self) {
        _logLines = [NSMutableArray array];
    }
    return self;
}

- (void)cancel {
    self.cancelRequested = YES;
    @try {
        [self.activeTask terminate];
    } @catch (__unused NSException *e) {}
}

- (void)appendLog:(NSString *)line {
    NSString *clean = SpliceKitUprezzerTrimmedString(line);
    if (clean.length == 0) return;
    @synchronized (self.logLines) {
        [self.logLines addObject:clean];
    }
    if (self.logBlock) {
        self.logBlock(clean);
    }
    SpliceKit_log(@"[Uprezzer] %@", clean);
}

- (void)notifyItem:(SpliceKitUprezzerSelectedItem *)item
             state:(NSString *)state
            detail:(NSString *)detail
      itemProgress:(double)itemProgress
   overallProgress:(double)overallProgress {
    item.status = state ?: item.status;
    item.detail = detail ?: item.detail;
    item.progress = MAX(0.0, MIN(1.0, itemProgress));
    if (self.itemUpdateBlock) {
        self.itemUpdateBlock(item, item.status, item.detail, item.progress, overallProgress);
    }
}

- (void)writeReportWithSummary:(NSDictionary *)summary {
    NSString *reportsDir = SpliceKitUprezzerReportsDirectory(self.jobID);
    NSString *logsDir = SpliceKitUprezzerLogsDirectory(self.jobID);
    NSString *logPath = [logsDir stringByAppendingPathComponent:@"uprezzer.log"];
    NSString *reportPath = [reportsDir stringByAppendingPathComponent:@"report.json"];

    NSArray<NSString *> *lines = nil;
    @synchronized (self.logLines) {
        lines = [self.logLines copy];
    }
    [[lines componentsJoinedByString:@"\n"] writeToFile:logPath
                                             atomically:YES
                                               encoding:NSUTF8StringEncoding
                                                  error:nil];

    if ([NSJSONSerialization isValidJSONObject:summary]) {
        NSData *json = [NSJSONSerialization dataWithJSONObject:summary
                                                       options:NSJSONWritingPrettyPrinted
                                                         error:nil];
        [json writeToFile:reportPath atomically:YES];
    }
}

- (NSString *)stageLabelForItem:(SpliceKitUprezzerSelectedItem *)item
                          index:(NSInteger)index
                          total:(NSInteger)total {
    return [NSString stringWithFormat:@"Processing clip %ld of %ld: %@",
        (long)(index + 1), (long)total, item.displayName ?: @"Untitled Clip"];
}

- (NSDictionary *)importOutputForItem:(SpliceKitUprezzerSelectedItem *)item
                           outputPath:(NSString *)outputPath {
    NSDictionary *mediaInfo = SpliceKitUprezzerInspectRenderedMedia(outputPath);
    if (mediaInfo[@"error"]) {
        return @{@"error": mediaInfo[@"error"]};
    }

    NSString *eventName = self.destinationEventName.length > 0
        ? self.destinationEventName
        : @"Uprezzer Outputs";
    NSString *xml = SpliceKitUprezzerImportXMLForOutput(item.importedClipName ?: item.plannedOutputName,
                                                        outputPath,
                                                        mediaInfo,
                                                        eventName);
    NSDictionary *response = SpliceKit_handleRequest(@{
        @"method": @"fcpxml.import",
        @"params": @{@"xml": xml, @"internal": @YES, @"allowFileFallback": @NO}
    });
    NSDictionary *result = response[@"result"] ?: response;
    NSString *errorText = SpliceKitUprezzerString(result[@"error"]);
    if (errorText.length > 0 &&
        [errorText rangeOfString:@"file fallback is disabled" options:NSCaseInsensitiveSearch].location != NSNotFound) {
        [self appendLog:[NSString stringWithFormat:
            @"Final Cut rejected the internal import for %@. Suppressing file fallback to avoid the library chooser. Raw error: %@",
            item.displayName ?: @"Untitled Clip",
            errorText]];
        return @{@"error": @"Final Cut rejected the internal import for this clip. Uprezzer skipped the file fallback to avoid opening the library chooser."};
    }
    return result;
}

- (NSString *)replacementErrorForItem:(SpliceKitUprezzerSelectedItem *)item
                         importedClip:(id)importedClip
                           outputPath:(NSString *)outputPath {
    return SpliceKitUprezzerReplacementError(item, importedClip, outputPath);
}

- (NSDictionary *)runTaskForItem:(SpliceKitUprezzerSelectedItem *)item
                          index:(NSInteger)index
                          total:(NSInteger)total {
    NSString *rendersDir = SpliceKitUprezzerRendersDirectory(self.jobID);
    NSString *itemDir = SpliceKitUprezzerEnsureDirectory([rendersDir
        stringByAppendingPathComponent:[NSString stringWithFormat:@"item-%03ld", (long)(index + 1)]]);
    NSString *logsDir = SpliceKitUprezzerLogsDirectory(self.jobID);

    NSString *sourceExt = item.sourcePath.pathExtension.length > 0 ? item.sourcePath.pathExtension : @"mov";
    NSString *workingInputName = [NSString stringWithFormat:@"%@.%@",
        SpliceKitUprezzerDisplayBaseName(item.displayName),
        sourceExt.lowercaseString];
    NSString *workingInputPath = [itemDir stringByAppendingPathComponent:workingInputName];
    NSString *finalOutputName = item.plannedOutputName ?: workingInputName;
    NSString *finalOutputPath = [itemDir stringByAppendingPathComponent:finalOutputName];
    item.plannedOutputPath = finalOutputPath;
    item.importedClipName = [finalOutputName stringByDeletingPathExtension];

    [[NSFileManager defaultManager] removeItemAtPath:workingInputPath error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:finalOutputPath error:nil];

    NSError *copyError = nil;
    if (![[NSFileManager defaultManager] copyItemAtPath:item.sourcePath toPath:workingInputPath error:&copyError]) {
        return @{@"error": copyError.localizedDescription ?: @"Could not stage the source media for processing."};
    }

    NSInteger targetWidth = MAX(item.plannedWidth, 1);
    NSInteger targetHeight = MAX(item.plannedHeight, 1);
    NSString *codec = (targetWidth > 3840 || targetHeight > 2160) ? @"prores" : @"hevc";
    NSString *stageText = [self stageLabelForItem:item index:index total:total];

    if (self.stageBlock) {
        self.stageBlock(stageText, ((double)index / (double)MAX(total, 1)));
    }
    [self appendLog:[NSString stringWithFormat:@"%@ — %@x%@ -> %@x%@ using %@",
        item.displayName ?: @"Untitled Clip",
        @(item.width), @(item.height),
        @(targetWidth), @(targetHeight),
        codec]];

    __block NSMutableString *buffer = [NSMutableString string];
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:self.fxPath];
    task.currentDirectoryURL = [NSURL fileURLWithPath:itemDir];
    task.arguments = @[
        workingInputPath,
        @"--width", [NSString stringWithFormat:@"%ld", (long)targetWidth],
        @"--height", [NSString stringWithFormat:@"%ld", (long)targetHeight],
        @"--codec", codec
    ];

    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = pipe;
    self.activeTask = task;

    __weak typeof(self) weakSelf = self;
    __weak typeof(item) weakItem = item;
    pipe.fileHandleForReading.readabilityHandler = ^(NSFileHandle *handle) {
        NSData *data = [handle availableData];
        if (data.length == 0) return;
        NSString *chunk = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (chunk.length == 0) {
            chunk = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
        }
        if (chunk.length == 0) return;

        NSString *cleanChunk = [chunk stringByReplacingOccurrencesOfString:@"\r" withString:@"\n"];
        @synchronized (buffer) {
            [buffer appendString:cleanChunk];
            NSArray<NSString *> *segments = [buffer componentsSeparatedByString:@"\n"];
            [buffer setString:[segments.lastObject copy] ?: @""];
            for (NSUInteger i = 0; i + 1 < segments.count; i++) {
                NSString *line = SpliceKitUprezzerStripANSI(segments[i]);
                if (line.length == 0) continue;
                [weakSelf appendLog:line];

                double percent = SpliceKitUprezzerPercentFromLine(line);
                if (percent >= 0.0) {
                    double itemProgress = 0.10 + (MIN(percent, 100.0) / 100.0) * 0.70;
                    double overall = ((double)index + itemProgress) / (double)MAX(total, 1);
                    [weakSelf notifyItem:weakItem
                                   state:SpliceKitUprezzerItemStateProcessing
                                  detail:[NSString stringWithFormat:@"Upscaling locally with fx-upscale (%.0f%%)", percent]
                            itemProgress:itemProgress
                         overallProgress:overall];
                    if (weakSelf.stageBlock) {
                        weakSelf.stageBlock(stageText, overall);
                    }
                }
            }
        }
    };

    NSError *launchError = nil;
    if (![task launchAndReturnError:&launchError]) {
        pipe.fileHandleForReading.readabilityHandler = nil;
        self.activeTask = nil;
        return @{@"error": launchError.localizedDescription ?: @"Could not launch fx-upscale."};
    }

    [task waitUntilExit];
    pipe.fileHandleForReading.readabilityHandler = nil;
    NSData *remaining = [[pipe fileHandleForReading] readDataToEndOfFile];
    if (remaining.length > 0) {
        NSString *tail = [[NSString alloc] initWithData:remaining encoding:NSUTF8StringEncoding];
        if (tail.length == 0) tail = [[NSString alloc] initWithData:remaining encoding:NSISOLatin1StringEncoding];
        NSString *cleanTail = SpliceKitUprezzerStripANSI(tail);
        if (cleanTail.length > 0) {
            [self appendLog:cleanTail];
        }
    }
    self.activeTask = nil;

    if (self.cancelRequested) {
        return @{@"cancelled": @YES};
    }
    if (task.terminationStatus != 0) {
        NSString *stderrPath = [logsDir stringByAppendingPathComponent:
            [NSString stringWithFormat:@"item-%03ld.log", (long)(index + 1)]];
        NSArray<NSString *> *lines = nil;
        @synchronized (self.logLines) {
            lines = [self.logLines copy];
        }
        [[lines componentsJoinedByString:@"\n"] writeToFile:stderrPath
                                                 atomically:YES
                                                   encoding:NSUTF8StringEncoding
                                                      error:nil];
        return @{@"error": [NSString stringWithFormat:@"fx-upscale exited with status %d.", task.terminationStatus]};
    }

    NSArray<NSString *> *contents = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:itemDir error:nil] ?: @[];
    NSString *renderedPath = nil;
    NSDate *renderedDate = nil;
    for (NSString *entry in contents) {
        NSString *candidate = [itemDir stringByAppendingPathComponent:entry];
        if ([candidate isEqualToString:workingInputPath]) continue;
        if ([entry hasSuffix:@".tmp"] || [entry hasSuffix:@".part"]) continue;
        BOOL isDir = NO;
        if (![[NSFileManager defaultManager] fileExistsAtPath:candidate isDirectory:&isDir] || isDir) continue;
        NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:candidate error:nil];
        NSDate *modDate = attrs[NSFileModificationDate] ?: [NSDate distantPast];
        if (!renderedPath || [modDate compare:renderedDate] == NSOrderedDescending) {
            renderedPath = candidate;
            renderedDate = modDate;
        }
    }

    if (renderedPath.length == 0) {
        return @{@"error": @"Upscale completed, but no output file was found."};
    }

    if (![renderedPath isEqualToString:finalOutputPath]) {
        [[NSFileManager defaultManager] removeItemAtPath:finalOutputPath error:nil];
        NSError *moveError = nil;
        if (![[NSFileManager defaultManager] moveItemAtPath:renderedPath
                                                     toPath:finalOutputPath
                                                      error:&moveError]) {
            return @{@"error": moveError.localizedDescription ?: @"Could not finalize the upscaled output file."};
        }
    }

    return @{@"outputPath": finalOutputPath, @"codec": codec};
}

- (void)start {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSInteger total = self.items.count;
        NSInteger completed = 0;
        NSInteger failed = 0;
        NSInteger skipped = 0;
        NSInteger replaced = 0;
        NSInteger importedOnly = 0;
        NSInteger processed = 0;
        NSString *lastImportedHandle = nil;
        NSString *lastImportedClipName = nil;
        NSString *lastImportedOutputPath = nil;
        NSString *lastImportedEventName = nil;

        [self appendLog:[NSString stringWithFormat:@"Uprezzer run started (%ld items, %ldx)",
            (long)total, (long)self.scaleFactor]];

        for (NSInteger idx = 0; idx < total; idx++) {
            SpliceKitUprezzerSelectedItem *item = self.items[idx];
            if (self.cancelRequested) {
                item.status = SpliceKitUprezzerItemStateCancelled;
                item.detail = @"Stopped before processing.";
                continue;
            }

            double baseOverall = (double)idx / (double)MAX(total, 1);

            if (item.validationError.length > 0) {
                skipped++;
                [self notifyItem:item
                           state:SpliceKitUprezzerItemStateSkipped
                          detail:item.validationError
                    itemProgress:1.0
                 overallProgress:((double)(idx + 1) / (double)MAX(total, 1))];
                continue;
            }

            processed++;
            [self notifyItem:item
                       state:SpliceKitUprezzerItemStateValidating
                      detail:@"Inspecting media and preparing the upscale job."
                itemProgress:0.05
             overallProgress:baseOverall + (0.05 / (double)MAX(total, 1))];

            NSDictionary *runResult = [self runTaskForItem:item index:idx total:total];
            if (runResult[@"cancelled"]) {
                item.status = SpliceKitUprezzerItemStateCancelled;
                item.detail = @"Stopped during processing.";
                item.progress = 0.0;
                break;
            }
            if (runResult[@"error"]) {
                failed++;
                [self notifyItem:item
                           state:SpliceKitUprezzerItemStateFailed
                          detail:runResult[@"error"]
                    itemProgress:1.0
                 overallProgress:((double)(idx + 1) / (double)MAX(total, 1))];
                continue;
            }

            NSString *outputPath = runResult[@"outputPath"];
            item.plannedOutputPath = outputPath;
            [self notifyItem:item
                       state:SpliceKitUprezzerItemStateImporting
                      detail:@"Importing into Final Cut."
                itemProgress:0.88
             overallProgress:baseOverall + (0.88 / (double)MAX(total, 1))];

            NSDictionary *importResult = [self importOutputForItem:item outputPath:outputPath];
            if (importResult[@"error"]) {
                failed++;
                [self notifyItem:item
                           state:SpliceKitUprezzerItemStateFailed
                          detail:[NSString stringWithFormat:@"Import failed. %@", importResult[@"error"]]
                    itemProgress:1.0
                 overallProgress:((double)(idx + 1) / (double)MAX(total, 1))];
                continue;
            }

            item.imported = YES;
            BOOL usedFileImportFallback = [[SpliceKitUprezzerString(importResult[@"method"]) lowercaseString] isEqualToString:@"file"];
            if (usedFileImportFallback) {
                [self appendLog:[NSString stringWithFormat:
                    @"Internal FCPXML import rejected %@; file fallback was triggered and Uprezzer is waiting for Final Cut to finish the import.",
                    item.displayName ?: @"Untitled Clip"]];
                [self notifyItem:item
                           state:SpliceKitUprezzerItemStateImporting
                          detail:@"Final Cut is finishing the import."
                    itemProgress:0.90
                 overallProgress:baseOverall + (0.90 / (double)MAX(total, 1))];
            }
            id importedClip = nil;
            NSString *importLookupMode = nil;
            NSString *importLookupPath = nil;
            NSInteger importLookupAttempts = usedFileImportFallback ? 75 : 20;
            NSTimeInterval importLookupDelay = usedFileImportFallback ? 0.20 : 0.20;
            for (NSInteger attempt = 0; attempt < importLookupAttempts && !importedClip; attempt++) {
                importedClip = SpliceKitUprezzerFindClipNamedInEvent(item.importedClipName,
                                                                     self.destinationEventName,
                                                                     outputPath,
                                                                     &importLookupMode,
                                                                     &importLookupPath);
                if (!importedClip) [NSThread sleepForTimeInterval:importLookupDelay];
            }
            if (importedClip) {
                item.importedClipHandle = SpliceKit_storeHandle(importedClip);
                lastImportedHandle = item.importedClipHandle;
                lastImportedClipName = item.importedClipName;
                lastImportedOutputPath = outputPath;
                lastImportedEventName = self.destinationEventName;
                [self appendLog:[NSString stringWithFormat:
                    @"Imported clip resolved for %@ via %@%@",
                    item.displayName ?: @"Untitled Clip",
                    importLookupMode ?: @"unknown",
                    importLookupPath.length > 0 ? [NSString stringWithFormat:@" (%@)", importLookupPath.lastPathComponent] : @""]];
            } else {
                [self appendLog:[NSString stringWithFormat:
                    @"Imported clip could not be re-resolved for %@ in event %@",
                    item.displayName ?: @"Untitled Clip",
                    self.destinationEventName ?: @""]];
            }

            if (self.replaceTimeline && item.sourceContext == SpliceKitUprezzerSourceContextTimeline && importedClip) {
                [self notifyItem:item
                           state:SpliceKitUprezzerItemStateReplacing
                          detail:@"Replacing the selected timeline clip."
                    itemProgress:0.96
                 overallProgress:baseOverall + (0.96 / (double)MAX(total, 1))];
                NSString *replacementError = [self replacementErrorForItem:item
                                                              importedClip:importedClip
                                                                outputPath:outputPath];
                if (replacementError.length > 0) {
                    importedOnly++;
                    [self notifyItem:item
                               state:SpliceKitUprezzerItemStateCompleted
                              detail:replacementError
                        itemProgress:1.0
                     overallProgress:((double)(idx + 1) / (double)MAX(total, 1))];
                } else {
                    item.replacedOnTimeline = YES;
                    replaced++;
                    [self notifyItem:item
                               state:SpliceKitUprezzerItemStateCompleted
                              detail:@"Imported and replaced on the timeline."
                        itemProgress:1.0
                     overallProgress:((double)(idx + 1) / (double)MAX(total, 1))];
                }
            } else {
                importedOnly++;
                NSString *detail = nil;
                if (self.replaceTimeline && item.sourceContext == SpliceKitUprezzerSourceContextTimeline) {
                    detail = usedFileImportFallback
                        ? @"Import fallback was triggered in Final Cut, but the imported clip could not be re-resolved in time for timeline replacement."
                        : @"Imported successfully. Replacement was skipped.";
                } else {
                    detail = usedFileImportFallback
                        ? @"Import fallback was triggered in Final Cut, but the imported clip could not be re-resolved in time."
                        : @"Imported successfully.";
                }
                [self notifyItem:item
                           state:SpliceKitUprezzerItemStateCompleted
                          detail:detail
                    itemProgress:1.0
                 overallProgress:((double)(idx + 1) / (double)MAX(total, 1))];
            }

            completed++;
        }

        if (self.cancelRequested) {
            for (SpliceKitUprezzerSelectedItem *item in self.items) {
                if ([item.status isEqualToString:SpliceKitUprezzerItemStateQueued] ||
                    [item.status isEqualToString:SpliceKitUprezzerItemStateValidating]) {
                    item.status = SpliceKitUprezzerItemStateCancelled;
                    item.detail = @"Stopped before processing.";
                }
            }
        }

        NSMutableArray *itemReports = [NSMutableArray array];
        for (SpliceKitUprezzerSelectedItem *item in self.items) {
            [itemReports addObject:@{
                @"id": item.itemID ?: @"",
                @"name": item.displayName ?: @"",
                @"sourceContext": SpliceKitUprezzerSourceLabel(item.sourceContext),
                @"input": item.sourcePath ?: @"",
                @"output": item.plannedOutputPath ?: @"",
                @"status": item.status ?: @"",
                @"detail": item.detail ?: @"",
                @"imported": @(item.imported),
                @"replacedTimeline": @(item.replacedOnTimeline),
                @"width": @(item.width),
                @"height": @(item.height),
                @"plannedWidth": @(item.plannedWidth),
                @"plannedHeight": @(item.plannedHeight),
            }];
        }

        NSDictionary *summary = @{
            @"jobId": self.jobID ?: @"",
            @"mode": self.replaceTimeline ? @"timeline_replace" : @"import_only",
            @"scaleFactor": @(self.scaleFactor),
            @"destinationEvent": self.destinationEventName ?: @"",
            @"completed": @(completed),
            @"failed": @(failed),
            @"skipped": @(skipped),
            @"importedOnly": @(importedOnly),
            @"replacedOnTimeline": @(replaced),
            @"processed": @(processed),
            @"stopped": @(self.cancelRequested),
            @"revealImported": @(self.revealImported),
            @"lastImportedHandle": lastImportedHandle ?: @"",
            @"lastImportedClipName": lastImportedClipName ?: @"",
            @"lastImportedOutputPath": lastImportedOutputPath ?: @"",
            @"lastImportedEventName": lastImportedEventName ?: @"",
            @"items": itemReports
        };

        [self writeReportWithSummary:summary];
        if (self.completionBlock) {
            self.completionBlock(summary);
        }
    });
}

@end

@interface SpliceKitUprezzerPanel () <NSWindowDelegate>
@property (nonatomic, strong) NSPanel *panel;
@property (nonatomic) SpliceKitUprezzerPanelState panelState;

@property (nonatomic, strong) NSStackView *rootStack;
@property (nonatomic, strong) NSView *headerSurface;
@property (nonatomic, strong) NSView *headerAccentView;
@property (nonatomic, strong) NSTextField *headerTitleLabel;
@property (nonatomic, strong) NSLayoutConstraint *headerHeightConstraint;

@property (nonatomic, strong) NSView *setupView;
@property (nonatomic, strong) NSView *progressView;
@property (nonatomic, strong) NSView *completionView;

@property (nonatomic, strong) NSTextField *subtitleLabel;
@property (nonatomic, strong) SpliceKitUprezzerPillBadgeView *sourcePillView;
@property (nonatomic, strong) NSView *selectedClipRow;
@property (nonatomic, strong) NSTextField *selectedClipNameLabel;
@property (nonatomic, strong) NSStackView *setupStack;

@property (nonatomic, copy) NSArray<NSButton *> *scaleButtons;
@property (nonatomic, strong) SpliceKitUprezzerChoiceCardView *importOnlyCard;
@property (nonatomic, strong) SpliceKitUprezzerChoiceCardView *replaceTimelineCard;
@property (nonatomic, strong) NSTextField *outputHelpLabel;
@property (nonatomic, strong) NSButton *optionsToggleButton;
@property (nonatomic, strong) NSView *settingsCard;
@property (nonatomic, strong) NSPopUpButton *destinationPopup;
@property (nonatomic, strong) NSButton *revealCheckbox;
@property (nonatomic, strong) NSTextField *namingPreviewLabel;
@property (nonatomic, strong) NSTextField *dependencyLabel;
@property (nonatomic, strong) NSButton *upscaleButton;
@property (nonatomic, strong) NSButton *cancelButton;
@property (nonatomic) BOOL replaceTimelineRequested;
@property (nonatomic) BOOL optionsExpanded;

@property (nonatomic, strong) NSTextField *progressHeadlineLabel;
@property (nonatomic, strong) NSTextField *progressStatusLabel;
@property (nonatomic, strong) NSTextField *progressCurrentFileLabel;
@property (nonatomic, strong) NSTextField *progressStageLabel;
@property (nonatomic, strong) NSTextField *progressPercentLabel;
@property (nonatomic, strong) NSTextField *progressMessageLabel;
@property (nonatomic, strong) SpliceKitUprezzerProgressBarView *progressBar;
@property (nonatomic, strong) NSStackView *progressRowsStack;
@property (nonatomic, strong) NSButton *stopButton;
@property (nonatomic, strong) NSButton *detailsToggleButton;
@property (nonatomic, strong) NSScrollView *detailsScrollView;
@property (nonatomic, strong) NSTextView *detailsTextView;

@property (nonatomic, strong) NSTextField *completionIconLabel;
@property (nonatomic, strong) NSTextField *completionHeadlineLabel;
@property (nonatomic, strong) NSTextField *completionSummaryLabel;
@property (nonatomic, strong) NSButton *completionRevealButton;
@property (nonatomic, strong) NSButton *completionCloseButton;

@property (nonatomic, copy) NSArray<SpliceKitUprezzerSelectedItem *> *selectionItems;
@property (nonatomic, strong) NSMutableDictionary<NSString *, SpliceKitUprezzerItemRowView *> *rowViews;
@property (nonatomic, strong) SpliceKitUprezzerBatchRunner *runner;
@property (nonatomic, copy) NSString *fxPath;
@property (nonatomic, copy) NSString *currentEventName;
@property (nonatomic) NSInteger selectionRefreshToken;
@property (nonatomic, copy) NSString *lastImportedHandle;
@property (nonatomic, copy) NSString *lastImportedClipName;
@property (nonatomic, copy) NSString *lastImportedOutputPath;
@property (nonatomic, copy) NSString *lastImportedEventName;
@end

@implementation SpliceKitUprezzerPanel

+ (instancetype)sharedPanel {
    static SpliceKitUprezzerPanel *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[SpliceKitUprezzerPanel alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _rowViews = [NSMutableDictionary dictionary];
        _selectionItems = @[];
        [[NSNotificationCenter defaultCenter]
            addObserverForName:NSApplicationWillTerminateNotification
                        object:nil
                         queue:nil
                    usingBlock:^(__unused NSNotification *note) {
                        [self.runner cancel];
                        [self.panel orderOut:nil];
                    }];
    }
    return self;
}

- (void)setupPanelIfNeeded {
    if (self.panel) return;

    NSRect frame = NSMakeRect(160, 220, 480, 316);
    NSUInteger mask = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskUtilityWindow;
    self.panel = [[NSPanel alloc] initWithContentRect:frame
                                            styleMask:mask
                                              backing:NSBackingStoreBuffered
                                                defer:NO];
    self.panel.title = @"Uprezzer";
    self.panel.floatingPanel = YES;
    self.panel.becomesKeyOnlyIfNeeded = NO;
    self.panel.hidesOnDeactivate = NO;
    self.panel.level = NSFloatingWindowLevel;
    self.panel.minSize = NSMakeSize(440, 188);
    self.panel.releasedWhenClosed = NO;
    self.panel.delegate = self;
    self.panel.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];

    NSVisualEffectView *background = [[NSVisualEffectView alloc] initWithFrame:self.panel.contentView.bounds];
    background.translatesAutoresizingMaskIntoConstraints = NO;
    background.material = NSVisualEffectMaterialHUDWindow;
    background.state = NSVisualEffectStateActive;
    background.wantsLayer = YES;
    background.layer.backgroundColor = [[NSColor colorWithCalibratedRed:0.09 green:0.10 blue:0.13 alpha:0.98] CGColor];
    [self.panel.contentView addSubview:background];

    [NSLayoutConstraint activateConstraints:@[
        [background.leadingAnchor constraintEqualToAnchor:self.panel.contentView.leadingAnchor],
        [background.trailingAnchor constraintEqualToAnchor:self.panel.contentView.trailingAnchor],
        [background.topAnchor constraintEqualToAnchor:self.panel.contentView.topAnchor],
        [background.bottomAnchor constraintEqualToAnchor:self.panel.contentView.bottomAnchor],
    ]];

    self.rootStack = [[NSStackView alloc] init];
    self.rootStack.translatesAutoresizingMaskIntoConstraints = NO;
    self.rootStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.rootStack.alignment = NSLayoutAttributeLeading;
    self.rootStack.distribution = NSStackViewDistributionFill;
    self.rootStack.spacing = 10.0;
    [background addSubview:self.rootStack];

    [NSLayoutConstraint activateConstraints:@[
        [self.rootStack.leadingAnchor constraintEqualToAnchor:background.leadingAnchor constant:18.0],
        [self.rootStack.trailingAnchor constraintEqualToAnchor:background.trailingAnchor constant:-18.0],
        [self.rootStack.topAnchor constraintEqualToAnchor:background.topAnchor constant:14.0],
        [self.rootStack.bottomAnchor constraintEqualToAnchor:background.bottomAnchor constant:-14.0],
    ]];

    self.headerSurface = [self cardView];
    self.headerSurface.layer.cornerRadius = 15.0;
    self.headerSurface.layer.backgroundColor = [[NSColor colorWithCalibratedRed:0.12 green:0.13 blue:0.17 alpha:0.90] CGColor];
    self.headerSurface.layer.borderColor = [[NSColor colorWithCalibratedWhite:1.0 alpha:0.06] CGColor];
    self.headerSurface.layer.borderWidth = 1.0;
    [self.rootStack addArrangedSubview:self.headerSurface];
    [self.headerSurface.widthAnchor constraintEqualToAnchor:self.rootStack.widthAnchor].active = YES;
    self.headerHeightConstraint = [self.headerSurface.heightAnchor constraintEqualToConstant:80.0];
    self.headerHeightConstraint.active = YES;

    self.headerAccentView = [[NSView alloc] init];
    self.headerAccentView.translatesAutoresizingMaskIntoConstraints = NO;
    self.headerAccentView.wantsLayer = YES;
    self.headerAccentView.layer.cornerRadius = 1.0;
    self.headerAccentView.layer.backgroundColor = [[NSColor colorWithCalibratedRed:0.56 green:0.45 blue:0.98 alpha:0.90] CGColor];
    [self.headerSurface addSubview:self.headerAccentView];

    self.headerTitleLabel = [NSTextField labelWithString:@"Uprezzer"];
    self.headerTitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.headerTitleLabel.font = [NSFont systemFontOfSize:23 weight:NSFontWeightSemibold];
    self.headerTitleLabel.textColor = [NSColor colorWithWhite:0.98 alpha:1.0];
    [self.headerSurface addSubview:self.headerTitleLabel];

    self.subtitleLabel = [NSTextField wrappingLabelWithString:@"Upscale selected media from the timeline or browser."];
    self.subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.subtitleLabel.font = [NSFont systemFontOfSize:11.5 weight:NSFontWeightRegular];
    self.subtitleLabel.textColor = [NSColor colorWithWhite:0.74 alpha:1.0];
    self.subtitleLabel.maximumNumberOfLines = 1;
    [self.headerSurface addSubview:self.subtitleLabel];

    self.sourcePillView = [[SpliceKitUprezzerPillBadgeView alloc] initWithText:@"Selection"];
    self.sourcePillView.minimumWidthConstraint.constant = 78.0;
    [self.sourcePillView setBadgeText:@"Selection"
                            textColor:[NSColor colorWithWhite:0.95 alpha:1.0]
                            fillColor:[NSColor colorWithCalibratedRed:0.25 green:0.27 blue:0.34 alpha:0.88]
                          borderColor:[NSColor clearColor]];
    [self.headerSurface addSubview:self.sourcePillView];

    self.setupView = [[NSView alloc] init];
    self.setupView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.rootStack addArrangedSubview:self.setupView];
    [self.setupView.widthAnchor constraintEqualToAnchor:self.rootStack.widthAnchor].active = YES;

    self.progressView = [[NSView alloc] init];
    self.progressView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.rootStack addArrangedSubview:self.progressView];
    [self.progressView.widthAnchor constraintEqualToAnchor:self.rootStack.widthAnchor].active = YES;

    self.completionView = [[NSView alloc] init];
    self.completionView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.rootStack addArrangedSubview:self.completionView];
    [self.completionView.widthAnchor constraintEqualToAnchor:self.rootStack.widthAnchor].active = YES;

    [NSLayoutConstraint activateConstraints:@[
        [self.headerAccentView.leadingAnchor constraintEqualToAnchor:self.headerSurface.leadingAnchor constant:16.0],
        [self.headerAccentView.topAnchor constraintEqualToAnchor:self.headerSurface.topAnchor constant:10.0],
        [self.headerAccentView.widthAnchor constraintEqualToConstant:22.0],
        [self.headerAccentView.heightAnchor constraintEqualToConstant:2.0],

        [self.headerTitleLabel.leadingAnchor constraintEqualToAnchor:self.headerSurface.leadingAnchor constant:16.0],
        [self.headerTitleLabel.topAnchor constraintEqualToAnchor:self.headerAccentView.bottomAnchor constant:7.0],

        [self.sourcePillView.trailingAnchor constraintEqualToAnchor:self.headerSurface.trailingAnchor constant:-16.0],
        [self.sourcePillView.centerYAnchor constraintEqualToAnchor:self.headerTitleLabel.centerYAnchor],

        [self.subtitleLabel.leadingAnchor constraintEqualToAnchor:self.headerTitleLabel.leadingAnchor],
        [self.subtitleLabel.trailingAnchor constraintEqualToAnchor:self.headerSurface.trailingAnchor constant:-16.0],
        [self.subtitleLabel.topAnchor constraintEqualToAnchor:self.headerTitleLabel.bottomAnchor constant:3.0],
    ]];

    [self buildSetupView];
    [self buildProgressView];
    [self buildCompletionView];
    [self setPanelState:SpliceKitUprezzerPanelStateSetup];
}

- (NSTextField *)sectionTitleLabel:(NSString *)string {
    NSTextField *label = [NSTextField labelWithString:string ?: @""];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.font = [NSFont systemFontOfSize:10.5 weight:NSFontWeightSemibold];
    label.textColor = [NSColor colorWithWhite:0.86 alpha:1.0];
    return label;
}

- (NSView *)cardView {
    NSView *card = [[NSView alloc] init];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.wantsLayer = YES;
    card.layer.cornerRadius = 14.0;
    card.layer.backgroundColor = [[NSColor colorWithCalibratedRed:0.135 green:0.145 blue:0.18 alpha:0.72] CGColor];
    card.layer.borderWidth = 1.0;
    card.layer.borderColor = [[NSColor colorWithCalibratedWhite:1.0 alpha:0.05] CGColor];
    return card;
}

- (NSButton *)makeScaleButtonWithTitle:(NSString *)title factor:(NSInteger)factor {
    NSButton *button = [NSButton buttonWithTitle:title target:self action:@selector(scaleButtonPressed:)];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.tag = factor;
    button.bordered = NO;
    button.buttonType = NSButtonTypePushOnPushOff;
    button.font = [NSFont systemFontOfSize:12.5 weight:NSFontWeightSemibold];
    button.wantsLayer = YES;
    button.layer.cornerRadius = 10.0;
    return button;
}

- (void)refreshScaleButtonStyles {
    NSInteger factor = [self currentScaleFactor];
    NSColor *selectedFill = [NSColor colorWithCalibratedRed:0.52 green:0.41 blue:0.97 alpha:1.0];
    for (NSButton *button in self.scaleButtons) {
        BOOL selected = (button.tag == factor);
        button.layer.backgroundColor = selected
            ? selectedFill.CGColor
            : [NSColor colorWithCalibratedRed:0.17 green:0.18 blue:0.23 alpha:0.88].CGColor;
        button.layer.borderWidth = 1.0;
        button.layer.borderColor = (selected
            ? [selectedFill colorWithAlphaComponent:0.95].CGColor
            : [NSColor colorWithCalibratedWhite:1.0 alpha:0.06].CGColor);
        button.contentTintColor = selected
            ? [NSColor colorWithWhite:0.99 alpha:1.0]
            : [NSColor colorWithWhite:0.82 alpha:1.0];
    }
}

- (void)refreshOutputChoiceStyles {
    BOOL timelineMode = (self.selectionItems.count > 0 &&
                         self.selectionItems.firstObject.sourceContext == SpliceKitUprezzerSourceContextTimeline);
    self.importOnlyCard.hidden = NO;
    self.replaceTimelineCard.hidden = !timelineMode;

    self.importOnlyCard.titleLabel.stringValue = @"Import upscaled clip";
    self.importOnlyCard.subtitleLabel.stringValue = timelineMode
        ? @"Adds the new version to the library without changing the edit."
        : @"Adds the new version to the library.";
    self.importOnlyCard.statusBadge.textLabel.stringValue = @"Library";
    [self.importOnlyCard setSelectedAppearance:!self.replaceTimelineRequested emphasized:NO];

    self.replaceTimelineCard.titleLabel.stringValue = @"Replace selected timeline clips";
    self.replaceTimelineCard.subtitleLabel.stringValue = @"Imports the upscale and swaps the selected timeline instance.";
    self.replaceTimelineCard.statusBadge.textLabel.stringValue = @"Timeline";
    [self.replaceTimelineCard setSelectedAppearance:self.replaceTimelineRequested emphasized:YES];
}

- (void)buildSetupView {
    self.setupStack = [[NSStackView alloc] init];
    self.setupStack.translatesAutoresizingMaskIntoConstraints = NO;
    self.setupStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.setupStack.alignment = NSLayoutAttributeLeading;
    self.setupStack.distribution = NSStackViewDistributionFill;
    self.setupStack.spacing = 8.0;
    [self.setupView addSubview:self.setupStack];

    [NSLayoutConstraint activateConstraints:@[
        [self.setupStack.leadingAnchor constraintEqualToAnchor:self.setupView.leadingAnchor],
        [self.setupStack.trailingAnchor constraintEqualToAnchor:self.setupView.trailingAnchor],
        [self.setupStack.topAnchor constraintEqualToAnchor:self.setupView.topAnchor],
        [self.setupStack.bottomAnchor constraintEqualToAnchor:self.setupView.bottomAnchor],
    ]];

    self.selectedClipRow = [[NSView alloc] init];
    self.selectedClipRow.translatesAutoresizingMaskIntoConstraints = NO;
    self.selectedClipRow.wantsLayer = YES;
    self.selectedClipRow.layer.cornerRadius = 10.0;
    self.selectedClipRow.layer.backgroundColor = [[NSColor colorWithCalibratedWhite:1.0 alpha:0.03] CGColor];
    [self.setupStack addArrangedSubview:self.selectedClipRow];
    [self.selectedClipRow.widthAnchor constraintEqualToAnchor:self.setupStack.widthAnchor].active = YES;

    NSTextField *selectedPrefixLabel = [NSTextField labelWithString:@"Selected clip"];
    selectedPrefixLabel.translatesAutoresizingMaskIntoConstraints = NO;
    selectedPrefixLabel.font = [NSFont systemFontOfSize:10.0 weight:NSFontWeightMedium];
    selectedPrefixLabel.textColor = [NSColor colorWithWhite:0.66 alpha:1.0];
    [self.selectedClipRow addSubview:selectedPrefixLabel];

    self.selectedClipNameLabel = [NSTextField labelWithString:@"Inspecting current selection…"];
    self.selectedClipNameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.selectedClipNameLabel.font = [NSFont systemFontOfSize:11.5 weight:NSFontWeightRegular];
    self.selectedClipNameLabel.textColor = [NSColor colorWithWhite:0.94 alpha:1.0];
    self.selectedClipNameLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [self.selectedClipRow addSubview:self.selectedClipNameLabel];

    [NSLayoutConstraint activateConstraints:@[
        [self.selectedClipRow.heightAnchor constraintEqualToConstant:30.0],
        [selectedPrefixLabel.leadingAnchor constraintEqualToAnchor:self.selectedClipRow.leadingAnchor constant:10.0],
        [selectedPrefixLabel.centerYAnchor constraintEqualToAnchor:self.selectedClipRow.centerYAnchor],
        [self.selectedClipNameLabel.leadingAnchor constraintEqualToAnchor:selectedPrefixLabel.trailingAnchor constant:8.0],
        [self.selectedClipNameLabel.trailingAnchor constraintEqualToAnchor:self.selectedClipRow.trailingAnchor constant:-10.0],
        [self.selectedClipNameLabel.centerYAnchor constraintEqualToAnchor:self.selectedClipRow.centerYAnchor],
    ]];

    NSTextField *factorTitle = [self sectionTitleLabel:@"Upscale Factor"];
    [self.setupStack addArrangedSubview:factorTitle];
    [factorTitle.widthAnchor constraintEqualToAnchor:self.setupStack.widthAnchor].active = YES;

    NSView *factorCard = [self cardView];
    factorCard.layer.cornerRadius = 13.0;
    [self.setupStack addArrangedSubview:factorCard];
    [factorCard.widthAnchor constraintEqualToAnchor:self.setupStack.widthAnchor].active = YES;

    NSButton *button2x = [self makeScaleButtonWithTitle:@"2×" factor:2];
    NSButton *button3x = [self makeScaleButtonWithTitle:@"3×" factor:3];
    NSButton *button4x = [self makeScaleButtonWithTitle:@"4×" factor:4];
    button2x.state = NSControlStateValueOn;
    self.scaleButtons = @[button2x, button3x, button4x];

    NSStackView *factorStack = [[NSStackView alloc] init];
    factorStack.translatesAutoresizingMaskIntoConstraints = NO;
    factorStack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    factorStack.distribution = NSStackViewDistributionFillEqually;
    factorStack.spacing = 8.0;
    for (NSButton *button in self.scaleButtons) {
        [factorStack addArrangedSubview:button];
    }
    [factorCard addSubview:factorStack];

    [NSLayoutConstraint activateConstraints:@[
        [factorCard.heightAnchor constraintEqualToConstant:40.0],
        [factorStack.leadingAnchor constraintEqualToAnchor:factorCard.leadingAnchor constant:6.0],
        [factorStack.trailingAnchor constraintEqualToAnchor:factorCard.trailingAnchor constant:-6.0],
        [factorStack.topAnchor constraintEqualToAnchor:factorCard.topAnchor constant:5.0],
        [factorStack.bottomAnchor constraintEqualToAnchor:factorCard.bottomAnchor constant:-5.0],
        [button2x.heightAnchor constraintEqualToConstant:26.0],
        [button3x.heightAnchor constraintEqualToAnchor:button2x.heightAnchor],
        [button4x.heightAnchor constraintEqualToAnchor:button2x.heightAnchor],
    ]];

    NSTextField *outputTitle = [self sectionTitleLabel:@"After Processing"];
    [self.setupStack addArrangedSubview:outputTitle];
    [outputTitle.widthAnchor constraintEqualToAnchor:self.setupStack.widthAnchor].active = YES;

    NSStackView *outputStack = [[NSStackView alloc] init];
    outputStack.translatesAutoresizingMaskIntoConstraints = NO;
    outputStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    outputStack.spacing = 5.0;
    [self.setupStack addArrangedSubview:outputStack];
    [outputStack.widthAnchor constraintEqualToAnchor:self.setupStack.widthAnchor].active = YES;

    self.importOnlyCard = [[SpliceKitUprezzerChoiceCardView alloc]
        initWithTitle:@"Import upscaled clip"
              subtitle:@"Adds the new version to the library."
                target:self
                action:@selector(outputChoicePressed:)];
    self.importOnlyCard.button.tag = 0;
    [outputStack addArrangedSubview:self.importOnlyCard];
    [self.importOnlyCard.widthAnchor constraintEqualToAnchor:outputStack.widthAnchor].active = YES;

    self.replaceTimelineCard = [[SpliceKitUprezzerChoiceCardView alloc]
        initWithTitle:@"Replace selected timeline clips"
              subtitle:@"Imports the upscale and swaps the current selection."
                target:self
                action:@selector(outputChoicePressed:)];
    self.replaceTimelineCard.button.tag = 1;
    [outputStack addArrangedSubview:self.replaceTimelineCard];
    [self.replaceTimelineCard.widthAnchor constraintEqualToAnchor:outputStack.widthAnchor].active = YES;

    self.outputHelpLabel = [NSTextField wrappingLabelWithString:@"Original source files remain untouched."];
    self.outputHelpLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.outputHelpLabel.font = [NSFont systemFontOfSize:9.0];
    self.outputHelpLabel.textColor = [NSColor colorWithWhite:0.68 alpha:1.0];
    self.outputHelpLabel.maximumNumberOfLines = 1;
    [self.setupStack addArrangedSubview:self.outputHelpLabel];
    [self.outputHelpLabel.widthAnchor constraintEqualToAnchor:self.setupStack.widthAnchor].active = YES;

    self.settingsCard = [self cardView];
    [self.setupStack addArrangedSubview:self.settingsCard];
    [self.settingsCard.widthAnchor constraintEqualToAnchor:self.setupStack.widthAnchor].active = YES;

    NSTextField *destinationLabel = [NSTextField labelWithString:@"Import Settings"];
    destinationLabel.translatesAutoresizingMaskIntoConstraints = NO;
    destinationLabel.font = [NSFont systemFontOfSize:10.5 weight:NSFontWeightSemibold];
    destinationLabel.textColor = [NSColor colorWithWhite:0.90 alpha:1.0];
    [self.settingsCard addSubview:destinationLabel];

    NSTextField *eventLabel = [NSTextField labelWithString:@"Destination Event"];
    eventLabel.translatesAutoresizingMaskIntoConstraints = NO;
    eventLabel.font = [NSFont systemFontOfSize:9.5 weight:NSFontWeightMedium];
    eventLabel.textColor = [NSColor colorWithWhite:0.68 alpha:1.0];
    [self.settingsCard addSubview:eventLabel];

    self.destinationPopup = [[NSPopUpButton alloc] init];
    self.destinationPopup.translatesAutoresizingMaskIntoConstraints = NO;
    self.destinationPopup.controlSize = NSControlSizeSmall;
    [self.settingsCard addSubview:self.destinationPopup];

    NSTextField *previewLabel = [NSTextField labelWithString:@"Naming Preview"];
    previewLabel.translatesAutoresizingMaskIntoConstraints = NO;
    previewLabel.font = [NSFont systemFontOfSize:9.5 weight:NSFontWeightMedium];
    previewLabel.textColor = [NSColor colorWithWhite:0.68 alpha:1.0];
    [self.settingsCard addSubview:previewLabel];

    self.namingPreviewLabel = [NSTextField wrappingLabelWithString:@"Example Clip [Uprezzer 2x].mov"];
    self.namingPreviewLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.namingPreviewLabel.font = [NSFont systemFontOfSize:9.5];
    self.namingPreviewLabel.textColor = [NSColor colorWithWhite:0.66 alpha:1.0];
    self.namingPreviewLabel.maximumNumberOfLines = 2;
    [self.settingsCard addSubview:self.namingPreviewLabel];

    self.revealCheckbox = [NSButton checkboxWithTitle:@"Reveal imported clips when finished"
                                               target:nil
                                               action:nil];
    self.revealCheckbox.translatesAutoresizingMaskIntoConstraints = NO;
    self.revealCheckbox.font = [NSFont systemFontOfSize:10.5];
    self.revealCheckbox.state = NSControlStateValueOn;
    [self.settingsCard addSubview:self.revealCheckbox];

    [NSLayoutConstraint activateConstraints:@[
        [self.settingsCard.heightAnchor constraintGreaterThanOrEqualToConstant:94.0],
        [destinationLabel.leadingAnchor constraintEqualToAnchor:self.settingsCard.leadingAnchor constant:14.0],
        [destinationLabel.topAnchor constraintEqualToAnchor:self.settingsCard.topAnchor constant:12.0],
        [eventLabel.leadingAnchor constraintEqualToAnchor:self.settingsCard.leadingAnchor constant:14.0],
        [eventLabel.topAnchor constraintEqualToAnchor:destinationLabel.bottomAnchor constant:8.0],
        [self.destinationPopup.leadingAnchor constraintEqualToAnchor:eventLabel.leadingAnchor],
        [self.destinationPopup.topAnchor constraintEqualToAnchor:eventLabel.bottomAnchor constant:4.0],
        [self.destinationPopup.widthAnchor constraintEqualToConstant:210.0],
        [previewLabel.leadingAnchor constraintEqualToAnchor:self.settingsCard.leadingAnchor constant:14.0],
        [previewLabel.topAnchor constraintEqualToAnchor:self.destinationPopup.bottomAnchor constant:6.0],
        [self.namingPreviewLabel.leadingAnchor constraintEqualToAnchor:self.settingsCard.leadingAnchor constant:14.0],
        [self.namingPreviewLabel.trailingAnchor constraintEqualToAnchor:self.settingsCard.trailingAnchor constant:-14.0],
        [self.namingPreviewLabel.topAnchor constraintEqualToAnchor:previewLabel.bottomAnchor constant:2.0],
        [self.revealCheckbox.leadingAnchor constraintEqualToAnchor:self.settingsCard.leadingAnchor constant:14.0],
        [self.revealCheckbox.topAnchor constraintEqualToAnchor:self.namingPreviewLabel.bottomAnchor constant:6.0],
        [self.revealCheckbox.bottomAnchor constraintEqualToAnchor:self.settingsCard.bottomAnchor constant:-12.0],
    ]];

    self.dependencyLabel = [NSTextField wrappingLabelWithString:@""];
    self.dependencyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.dependencyLabel.font = [NSFont systemFontOfSize:9.5];
    self.dependencyLabel.textColor = [NSColor colorWithCalibratedRed:1.0 green:0.62 blue:0.62 alpha:1.0];
    self.dependencyLabel.maximumNumberOfLines = 2;
    [self.setupStack addArrangedSubview:self.dependencyLabel];
    [self.dependencyLabel.widthAnchor constraintEqualToAnchor:self.setupStack.widthAnchor].active = YES;

    self.optionsToggleButton = [NSButton buttonWithTitle:@"More Options"
                                                  target:self
                                                  action:@selector(toggleOptions:)];
    self.optionsToggleButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.optionsToggleButton.bordered = NO;
    self.optionsToggleButton.font = [NSFont systemFontOfSize:10.0 weight:NSFontWeightMedium];
    self.optionsToggleButton.contentTintColor = [NSColor colorWithWhite:0.82 alpha:1.0];
    self.optionsToggleButton.alignment = NSTextAlignmentLeft;
    [self.setupStack addArrangedSubview:self.optionsToggleButton];
    [self.optionsToggleButton.widthAnchor constraintEqualToAnchor:self.setupStack.widthAnchor].active = YES;

    NSView *footerRow = [[NSView alloc] init];
    footerRow.translatesAutoresizingMaskIntoConstraints = NO;
    [self.setupStack addArrangedSubview:footerRow];
    [footerRow.widthAnchor constraintEqualToAnchor:self.setupStack.widthAnchor].active = YES;

    self.cancelButton = [NSButton buttonWithTitle:@"Cancel"
                                           target:self
                                           action:@selector(cancelOrClose:)];
    self.cancelButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.cancelButton.bezelColor = [NSColor colorWithCalibratedWhite:0.28 alpha:1.0];
    [footerRow addSubview:self.cancelButton];

    self.upscaleButton = [NSButton buttonWithTitle:@"Upscale"
                                            target:self
                                            action:@selector(startUpscale:)];
    self.upscaleButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.upscaleButton.bezelStyle = NSBezelStyleRounded;
    self.upscaleButton.bezelColor = [NSColor colorWithCalibratedRed:0.50 green:0.41 blue:0.97 alpha:1.0];
    [self.upscaleButton setKeyEquivalent:@"\r"];
    [footerRow addSubview:self.upscaleButton];

    [NSLayoutConstraint activateConstraints:@[
        [footerRow.heightAnchor constraintEqualToConstant:30.0],
        [self.upscaleButton.trailingAnchor constraintEqualToAnchor:footerRow.trailingAnchor],
        [self.upscaleButton.centerYAnchor constraintEqualToAnchor:footerRow.centerYAnchor],
        [self.upscaleButton.widthAnchor constraintEqualToConstant:100.0],
        [self.cancelButton.trailingAnchor constraintEqualToAnchor:self.upscaleButton.leadingAnchor constant:-8.0],
        [self.cancelButton.centerYAnchor constraintEqualToAnchor:footerRow.centerYAnchor],
        [self.cancelButton.widthAnchor constraintEqualToConstant:88.0],
    ]];

    self.optionsExpanded = NO;
    self.settingsCard.hidden = YES;
    self.dependencyLabel.hidden = YES;
    self.replaceTimelineRequested = NO;
    [self refreshScaleButtonStyles];
    [self refreshOutputChoiceStyles];
}

- (void)buildProgressView {
    self.progressRowsStack = [[NSStackView alloc] init];
    self.progressRowsStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.progressRowsStack.spacing = 4.0;

    self.progressHeadlineLabel = [NSTextField labelWithString:@"Processing 1 of 1"];
    self.progressHeadlineLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.progressHeadlineLabel.font = [NSFont systemFontOfSize:14.5 weight:NSFontWeightSemibold];
    self.progressHeadlineLabel.textColor = [NSColor colorWithWhite:0.96 alpha:1.0];
    [self.progressView addSubview:self.progressHeadlineLabel];

    self.stopButton = [NSButton buttonWithTitle:@"Stop"
                                         target:self
                                         action:@selector(stopProcessing:)];
    self.stopButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.stopButton.bezelStyle = NSBezelStyleRounded;
    self.stopButton.bezelColor = [NSColor colorWithCalibratedRed:0.53 green:0.44 blue:0.98 alpha:1.0];
    [self.progressView addSubview:self.stopButton];

    self.progressCurrentFileLabel = [NSTextField labelWithString:@"Selected media"];
    self.progressCurrentFileLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.progressCurrentFileLabel.font = [NSFont systemFontOfSize:11 weight:NSFontWeightRegular];
    self.progressCurrentFileLabel.textColor = [NSColor colorWithWhite:0.72 alpha:1.0];
    self.progressCurrentFileLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [self.progressView addSubview:self.progressCurrentFileLabel];

    self.progressBar = [[SpliceKitUprezzerProgressBarView alloc] initWithFrame:NSZeroRect];
    self.progressBar.doubleValue = 0.0;
    [self.progressView addSubview:self.progressBar];

    self.progressStageLabel = [NSTextField labelWithString:@"Validating"];
    self.progressStageLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.progressStageLabel.font = [NSFont systemFontOfSize:11.5 weight:NSFontWeightSemibold];
    self.progressStageLabel.textColor = [NSColor colorWithWhite:0.94 alpha:1.0];
    [self.progressView addSubview:self.progressStageLabel];

    self.progressPercentLabel = [NSTextField labelWithString:@"0%"];
    self.progressPercentLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.progressPercentLabel.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    self.progressPercentLabel.textColor = [NSColor colorWithWhite:0.70 alpha:1.0];
    self.progressPercentLabel.alignment = NSTextAlignmentRight;
    [self.progressView addSubview:self.progressPercentLabel];

    self.progressMessageLabel = [NSTextField wrappingLabelWithString:@"Inspecting media and preparing the upscale job."];
    self.progressMessageLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.progressMessageLabel.font = [NSFont systemFontOfSize:10.5];
    self.progressMessageLabel.textColor = [NSColor colorWithWhite:0.72 alpha:1.0];
    self.progressMessageLabel.maximumNumberOfLines = 2;
    [self.progressView addSubview:self.progressMessageLabel];

    self.detailsToggleButton = [NSButton buttonWithTitle:@"Show Details"
                                                  target:self
                                                  action:@selector(toggleDetails:)];
    self.detailsToggleButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.detailsToggleButton.bordered = NO;
    self.detailsToggleButton.font = [NSFont systemFontOfSize:10.5 weight:NSFontWeightMedium];
    self.detailsToggleButton.contentTintColor = [NSColor colorWithWhite:0.86 alpha:1.0];
    self.detailsToggleButton.alignment = NSTextAlignmentLeft;
    [self.progressView addSubview:self.detailsToggleButton];

    self.detailsScrollView = [[NSScrollView alloc] init];
    self.detailsScrollView.translatesAutoresizingMaskIntoConstraints = NO;
    self.detailsScrollView.hasVerticalScroller = YES;
    self.detailsScrollView.drawsBackground = YES;
    self.detailsScrollView.borderType = NSNoBorder;
    self.detailsScrollView.wantsLayer = YES;
    self.detailsScrollView.layer.cornerRadius = 12.0;
    self.detailsScrollView.layer.masksToBounds = YES;
    self.detailsScrollView.backgroundColor = [NSColor colorWithCalibratedWhite:0.11 alpha:1.0];
    [self.progressView addSubview:self.detailsScrollView];

    self.detailsTextView = [[NSTextView alloc] init];
    self.detailsTextView.minSize = NSMakeSize(0.0, 0.0);
    self.detailsTextView.maxSize = NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX);
    self.detailsTextView.verticallyResizable = YES;
    self.detailsTextView.horizontallyResizable = NO;
    self.detailsTextView.editable = NO;
    self.detailsTextView.selectable = YES;
    self.detailsTextView.drawsBackground = YES;
    self.detailsTextView.backgroundColor = [NSColor colorWithCalibratedWhite:0.12 alpha:1.0];
    self.detailsTextView.textColor = [NSColor colorWithWhite:0.86 alpha:1.0];
    self.detailsTextView.font = [NSFont monospacedSystemFontOfSize:10.5 weight:NSFontWeightRegular];
    self.detailsScrollView.documentView = self.detailsTextView;
    self.detailsScrollView.hidden = YES;

    [NSLayoutConstraint activateConstraints:@[
        [self.progressHeadlineLabel.leadingAnchor constraintEqualToAnchor:self.progressView.leadingAnchor],
        [self.progressHeadlineLabel.topAnchor constraintEqualToAnchor:self.progressView.topAnchor],

        [self.stopButton.trailingAnchor constraintEqualToAnchor:self.progressView.trailingAnchor],
        [self.stopButton.centerYAnchor constraintEqualToAnchor:self.progressHeadlineLabel.centerYAnchor],

        [self.progressCurrentFileLabel.leadingAnchor constraintEqualToAnchor:self.progressView.leadingAnchor],
        [self.progressCurrentFileLabel.trailingAnchor constraintEqualToAnchor:self.stopButton.leadingAnchor constant:-12.0],
        [self.progressCurrentFileLabel.topAnchor constraintEqualToAnchor:self.progressHeadlineLabel.bottomAnchor constant:4.0],

        [self.progressBar.leadingAnchor constraintEqualToAnchor:self.progressView.leadingAnchor],
        [self.progressBar.trailingAnchor constraintEqualToAnchor:self.progressView.trailingAnchor],
        [self.progressBar.topAnchor constraintEqualToAnchor:self.progressCurrentFileLabel.bottomAnchor constant:12.0],
        [self.progressBar.heightAnchor constraintEqualToConstant:8.0],

        [self.progressStageLabel.leadingAnchor constraintEqualToAnchor:self.progressView.leadingAnchor],
        [self.progressStageLabel.topAnchor constraintEqualToAnchor:self.progressBar.bottomAnchor constant:12.0],

        [self.progressPercentLabel.trailingAnchor constraintEqualToAnchor:self.progressView.trailingAnchor],
        [self.progressPercentLabel.centerYAnchor constraintEqualToAnchor:self.progressStageLabel.centerYAnchor],

        [self.progressMessageLabel.leadingAnchor constraintEqualToAnchor:self.progressView.leadingAnchor],
        [self.progressMessageLabel.trailingAnchor constraintEqualToAnchor:self.progressView.trailingAnchor],
        [self.progressMessageLabel.topAnchor constraintEqualToAnchor:self.progressStageLabel.bottomAnchor constant:4.0],

        [self.detailsToggleButton.leadingAnchor constraintEqualToAnchor:self.progressView.leadingAnchor],
        [self.detailsToggleButton.topAnchor constraintEqualToAnchor:self.progressMessageLabel.bottomAnchor constant:10.0],

        [self.detailsScrollView.leadingAnchor constraintEqualToAnchor:self.progressView.leadingAnchor],
        [self.detailsScrollView.trailingAnchor constraintEqualToAnchor:self.progressView.trailingAnchor],
        [self.detailsScrollView.topAnchor constraintEqualToAnchor:self.detailsToggleButton.bottomAnchor constant:6.0],
        [self.detailsScrollView.heightAnchor constraintEqualToConstant:110.0],
        [self.detailsScrollView.bottomAnchor constraintEqualToAnchor:self.progressView.bottomAnchor],
    ]];
}

- (void)buildCompletionView {
    self.completionIconLabel = [NSTextField labelWithString:@"✓"];
    self.completionIconLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.completionIconLabel.font = [NSFont systemFontOfSize:34 weight:NSFontWeightSemibold];
    self.completionIconLabel.alignment = NSTextAlignmentCenter;
    [self.completionView addSubview:self.completionIconLabel];

    self.completionHeadlineLabel = [NSTextField labelWithString:@"Upscale Complete"];
    self.completionHeadlineLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.completionHeadlineLabel.font = [NSFont systemFontOfSize:22 weight:NSFontWeightSemibold];
    self.completionHeadlineLabel.textColor = [NSColor colorWithWhite:0.98 alpha:1.0];
    self.completionHeadlineLabel.alignment = NSTextAlignmentCenter;
    [self.completionView addSubview:self.completionHeadlineLabel];

    self.completionSummaryLabel = [NSTextField wrappingLabelWithString:@""];
    self.completionSummaryLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.completionSummaryLabel.font = [NSFont systemFontOfSize:11.5];
    self.completionSummaryLabel.textColor = [NSColor colorWithWhite:0.78 alpha:1.0];
    self.completionSummaryLabel.maximumNumberOfLines = 4;
    self.completionSummaryLabel.alignment = NSTextAlignmentCenter;
    [self.completionView addSubview:self.completionSummaryLabel];

    self.completionRevealButton = [NSButton buttonWithTitle:@"Reveal in Library"
                                                     target:self
                                                     action:@selector(revealImportedClip:)];
    self.completionRevealButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.completionRevealButton.bezelColor = [NSColor colorWithCalibratedWhite:0.30 alpha:1.0];
    [self.completionView addSubview:self.completionRevealButton];

    self.completionCloseButton = [NSButton buttonWithTitle:@"Close"
                                                    target:self
                                                    action:@selector(cancelOrClose:)];
    self.completionCloseButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.completionCloseButton.bezelColor = [NSColor colorWithCalibratedRed:0.50 green:0.41 blue:0.97 alpha:1.0];
    [self.completionView addSubview:self.completionCloseButton];

    [NSLayoutConstraint activateConstraints:@[
        [self.completionIconLabel.centerXAnchor constraintEqualToAnchor:self.completionView.centerXAnchor],
        [self.completionIconLabel.topAnchor constraintEqualToAnchor:self.completionView.topAnchor constant:6.0],

        [self.completionHeadlineLabel.leadingAnchor constraintEqualToAnchor:self.completionView.leadingAnchor],
        [self.completionHeadlineLabel.trailingAnchor constraintEqualToAnchor:self.completionView.trailingAnchor],
        [self.completionHeadlineLabel.topAnchor constraintEqualToAnchor:self.completionIconLabel.bottomAnchor constant:6.0],

        [self.completionSummaryLabel.leadingAnchor constraintEqualToAnchor:self.completionView.leadingAnchor],
        [self.completionSummaryLabel.trailingAnchor constraintEqualToAnchor:self.completionView.trailingAnchor],
        [self.completionSummaryLabel.topAnchor constraintEqualToAnchor:self.completionHeadlineLabel.bottomAnchor constant:8.0],

        [self.completionCloseButton.trailingAnchor constraintEqualToAnchor:self.completionView.trailingAnchor],
        [self.completionCloseButton.bottomAnchor constraintEqualToAnchor:self.completionView.bottomAnchor],
        [self.completionCloseButton.widthAnchor constraintEqualToConstant:88.0],

        [self.completionRevealButton.trailingAnchor constraintEqualToAnchor:self.completionCloseButton.leadingAnchor constant:-8.0],
        [self.completionRevealButton.bottomAnchor constraintEqualToAnchor:self.completionCloseButton.bottomAnchor],
    ]];
}

- (NSSize)preferredContentSizeForCurrentState {
    switch (self.panelState) {
        case SpliceKitUprezzerPanelStateSetup:
            return self.optionsExpanded ? NSMakeSize(560.0, 340.0) : NSMakeSize(560.0, 274.0);
        case SpliceKitUprezzerPanelStateProgress:
            return self.detailsScrollView.hidden ? NSMakeSize(560.0, 250.0) : NSMakeSize(560.0, 366.0);
        case SpliceKitUprezzerPanelStateCompletion:
            return NSMakeSize(self.completionRevealButton.hidden ? 460.0 : 520.0,
                              self.completionRevealButton.hidden ? 220.0 : 224.0);
    }
}

- (void)applyPreferredPanelSizeAnimated:(BOOL)animated {
    if (!self.panel) return;
    NSSize targetSize = [self preferredContentSizeForCurrentState];
    NSRect targetContentRect = NSMakeRect(0.0, 0.0, targetSize.width, targetSize.height);
    NSRect targetFrame = [self.panel frameRectForContentRect:targetContentRect];
    NSRect currentFrame = self.panel.frame;
    targetFrame.origin.x = currentFrame.origin.x;
    targetFrame.origin.y = NSMaxY(currentFrame) - NSHeight(targetFrame);
    [self.panel setFrame:targetFrame display:YES animate:animated];
}

- (void)setPanelState:(SpliceKitUprezzerPanelState)panelState {
    _panelState = panelState;
    BOOL showHeader = panelState != SpliceKitUprezzerPanelStateCompletion;
    self.headerSurface.hidden = !showHeader;
    if (panelState == SpliceKitUprezzerPanelStateSetup) {
        self.headerHeightConstraint.constant = 76.0;
        self.headerTitleLabel.stringValue = @"Uprezzer";
        self.headerTitleLabel.font = [NSFont systemFontOfSize:22 weight:NSFontWeightSemibold];
        self.subtitleLabel.stringValue = @"Upscale selected media from the timeline or browser.";
        self.subtitleLabel.font = [NSFont systemFontOfSize:11 weight:NSFontWeightRegular];
        self.sourcePillView.hidden = NO;
    } else if (panelState == SpliceKitUprezzerPanelStateProgress) {
        self.headerHeightConstraint.constant = 62.0;
        self.headerTitleLabel.stringValue = @"Upscaling";
        self.headerTitleLabel.font = [NSFont systemFontOfSize:20 weight:NSFontWeightSemibold];
        self.subtitleLabel.stringValue = @"Processing selected media.";
        self.subtitleLabel.font = [NSFont systemFontOfSize:10.5 weight:NSFontWeightRegular];
        self.sourcePillView.hidden = YES;
    }
    self.setupView.hidden = panelState != SpliceKitUprezzerPanelStateSetup;
    self.progressView.hidden = panelState != SpliceKitUprezzerPanelStateProgress;
    self.completionView.hidden = panelState != SpliceKitUprezzerPanelStateCompletion;
    [self applyPreferredPanelSizeAnimated:self.panel.isVisible];
}

- (void)showPanel {
    if (![NSThread isMainThread]) {
        SpliceKit_executeOnMainThread(^{
            [self showPanel];
        });
        return;
    }

    [self setupPanelIfNeeded];
    self.optionsExpanded = NO;
    self.settingsCard.hidden = YES;
    self.optionsToggleButton.title = @"More Options";
    [self.panel makeKeyAndOrderFront:nil];
    [self setPanelState:SpliceKitUprezzerPanelStateSetup];
    [self refreshSelection];
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

- (void)togglePanel {
    if (self.isVisible) {
        [self hidePanel];
    } else {
        [self showPanel];
    }
}

- (BOOL)isVisible {
    return self.panel.isVisible;
}

- (NSInteger)currentScaleFactor {
    for (NSButton *button in self.scaleButtons) {
        if (button.state == NSControlStateValueOn) {
            return MAX(button.tag, 2);
        }
    }
    return 2;
}

- (void)scaleButtonPressed:(NSButton *)sender {
    for (NSButton *button in self.scaleButtons) {
        button.state = (button == sender) ? NSControlStateValueOn : NSControlStateValueOff;
    }
    [self refreshScaleButtonStyles];
    [self scaleChanged:nil];
}

- (void)scaleChanged:(__unused id)sender {
    NSInteger factor = [self currentScaleFactor];
    for (SpliceKitUprezzerSelectedItem *item in self.selectionItems) {
        if (item.width > 0 && item.height > 0) {
            item.plannedWidth = item.width * factor;
            item.plannedHeight = item.height * factor;
        }
        if (item.plannedOutputName.length > 0) {
            NSString *ext = item.plannedOutputName.pathExtension.length > 0
                ? item.plannedOutputName.pathExtension
                : item.sourcePath.pathExtension;
            item.plannedOutputName = SpliceKitUprezzerMakeOutputFilename(item.displayName,
                                                                         factor,
                                                                         ext,
                                                                         [NSSet set]);
        }
    }
    [self refreshSetupSummaryUI];
}

- (void)outputChoicePressed:(NSButton *)sender {
    self.replaceTimelineRequested = (sender.tag == 1);
    [self refreshOutputChoiceStyles];
    [self refreshSetupSummaryUI];
}

- (void)toggleDetails:(__unused id)sender {
    BOOL show = self.detailsScrollView.hidden;
    self.detailsScrollView.hidden = !show;
    self.detailsToggleButton.title = show ? @"Hide Details" : @"Show Details";
    [self applyPreferredPanelSizeAnimated:YES];
}

- (void)toggleOptions:(__unused id)sender {
    self.optionsExpanded = !self.optionsExpanded;
    self.settingsCard.hidden = !self.optionsExpanded;
    self.optionsToggleButton.title = self.optionsExpanded ? @"Hide Options" : @"More Options";
    [self applyPreferredPanelSizeAnimated:YES];
}

- (void)cancelOrClose:(__unused id)sender {
    if (self.panelState == SpliceKitUprezzerPanelStateProgress) {
        [self stopProcessing:nil];
        return;
    }
    [self hidePanel];
}

- (void)stopProcessing:(__unused id)sender {
    [self.runner cancel];
    self.stopButton.enabled = NO;
    self.progressStageLabel.stringValue = @"Stopping after the current clip...";
    [self appendDetailLine:@"Stop requested. Uprezzer will finish the active subprocess safely."];
}

- (void)startUpscale:(__unused id)sender {
    NSArray<SpliceKitUprezzerSelectedItem *> *validItems = [self.selectionItems filteredArrayUsingPredicate:
        [NSPredicate predicateWithBlock:^BOOL(SpliceKitUprezzerSelectedItem *item, __unused NSDictionary *bindings) {
            return item.validationError.length == 0;
        }]];

    if (validItems.count == 0) {
        NSBeep();
        return;
    }
    if (self.fxPath.length == 0) {
        NSBeep();
        return;
    }

    self.lastImportedHandle = nil;
    self.lastImportedClipName = nil;
    self.lastImportedOutputPath = nil;
    self.lastImportedEventName = nil;
    self.detailsTextView.string = @"";
    self.detailsScrollView.hidden = YES;
    self.detailsToggleButton.title = @"Show Details";
    self.rowViews = [NSMutableDictionary dictionary];
    for (NSView *view in self.progressRowsStack.arrangedSubviews.copy) {
        [self.progressRowsStack removeArrangedSubview:view];
        [view removeFromSuperview];
    }

    NSInteger factor = [self currentScaleFactor];
    NSString *destinationEvent = self.destinationPopup.indexOfSelectedItem == 1
        ? @"Uprezzer Outputs"
        : SpliceKitUprezzerEventNameForImportChoice(NO);

    NSMutableArray<SpliceKitUprezzerSelectedItem *> *runItems = [NSMutableArray array];
    for (SpliceKitUprezzerSelectedItem *item in self.selectionItems) {
        SpliceKitUprezzerSelectedItem *copyItem = [[SpliceKitUprezzerSelectedItem alloc] init];
        copyItem.itemID = item.itemID;
        copyItem.sourceContext = item.sourceContext;
        copyItem.displayName = item.displayName;
        copyItem.eventName = item.eventName;
        copyItem.objectHandle = item.objectHandle;
        copyItem.objectClassName = item.objectClassName;
        copyItem.sourcePath = item.sourcePath;
        copyItem.duration = item.duration;
        copyItem.frameRate = item.frameRate;
        copyItem.timelineStart = item.timelineStart;
        copyItem.timelineDuration = item.timelineDuration;
        copyItem.width = item.width;
        copyItem.height = item.height;
        copyItem.plannedWidth = item.width * factor;
        copyItem.plannedHeight = item.height * factor;
        copyItem.validationError = item.validationError;
        copyItem.status = item.validationError.length > 0 ? SpliceKitUprezzerItemStateSkipped : SpliceKitUprezzerItemStateQueued;
        copyItem.detail = item.validationError.length > 0 ? item.validationError : @"Queued";
        NSString *extension = item.sourcePath.pathExtension.length > 0 ? item.sourcePath.pathExtension : @"mov";
        copyItem.plannedOutputName = SpliceKitUprezzerMakeOutputFilename(item.displayName, factor, extension, [NSSet set]);
        [runItems addObject:copyItem];
    }

    for (SpliceKitUprezzerSelectedItem *item in runItems) {
        SpliceKitUprezzerItemRowView *row = [[SpliceKitUprezzerItemRowView alloc] initWithFrame:NSZeroRect];
        [row configureWithItem:item];
        [self.progressRowsStack addArrangedSubview:row];
        self.rowViews[item.itemID] = row;
    }

    self.progressHeadlineLabel.stringValue = [NSString stringWithFormat:@"Processing %lu of %lu",
        (unsigned long)MIN((NSUInteger)1, runItems.count),
        (unsigned long)runItems.count];
    self.progressCurrentFileLabel.stringValue = runItems.firstObject.displayName ?: @"Selected media";
    self.progressStageLabel.stringValue = @"Validating";
    self.progressPercentLabel.stringValue = @"0%";
    self.progressMessageLabel.stringValue = @"Inspecting media and preparing the upscale job.";
    self.progressBar.doubleValue = 0.0;
    self.stopButton.enabled = YES;
    [self setPanelState:SpliceKitUprezzerPanelStateProgress];

    SpliceKitUprezzerBatchRunner *runner = [[SpliceKitUprezzerBatchRunner alloc] init];
    runner.jobID = [[NSUUID UUID] UUIDString];
    runner.fxPath = self.fxPath;
    runner.destinationEventName = destinationEvent;
    runner.scaleFactor = factor;
    runner.replaceTimeline = (runItems.firstObject.sourceContext == SpliceKitUprezzerSourceContextTimeline &&
                              self.replaceTimelineRequested);
    runner.revealImported = (self.revealCheckbox.state == NSControlStateValueOn);
    runner.items = runItems;

    __weak typeof(self) weakSelf = self;
    runner.stageBlock = ^(NSString *stageText, double overallProgress) {
        dispatch_async(dispatch_get_main_queue(), ^{
            weakSelf.progressMessageLabel.stringValue = stageText ?: @"Processing…";
            weakSelf.progressBar.doubleValue = MAX(0.0, MIN(1.0, overallProgress));
            weakSelf.progressPercentLabel.stringValue = [NSString stringWithFormat:@"%.0f%%", round(MAX(0.0, MIN(1.0, overallProgress)) * 100.0)];
        });
    };
    runner.itemUpdateBlock = ^(SpliceKitUprezzerSelectedItem *item, NSString *state, NSString *detail, __unused double itemProgress, double overallProgress) {
        dispatch_async(dispatch_get_main_queue(), ^{
            SpliceKitUprezzerItemRowView *row = weakSelf.rowViews[item.itemID];
            [row configureWithItem:item];
            weakSelf.progressBar.doubleValue = MAX(0.0, MIN(1.0, overallProgress));
            weakSelf.progressCurrentFileLabel.stringValue = item.displayName ?: @"Selected media";
            weakSelf.progressStageLabel.stringValue = row ? row.badgeView.textLabel.stringValue : (state.capitalizedString ?: @"Processing");
            weakSelf.progressMessageLabel.stringValue = detail ?: item.detail ?: @"Processing…";
            weakSelf.progressPercentLabel.stringValue = [NSString stringWithFormat:@"%.0f%%", round(MAX(0.0, MIN(1.0, overallProgress)) * 100.0)];
        });
    };
    runner.logBlock = ^(NSString *line) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf appendDetailLine:line];
        });
    };
    runner.completionBlock = ^(NSDictionary *summary) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf handleRunnerCompletion:summary];
        });
    };

    self.runner = runner;
    [runner start];
}

- (void)appendDetailLine:(NSString *)line {
    if (line.length == 0) return;
    NSString *existing = self.detailsTextView.string ?: @"";
    NSString *next = existing.length > 0 ? [existing stringByAppendingFormat:@"\n%@", line] : line;
    self.detailsTextView.string = next;
    [self.detailsTextView scrollRangeToVisible:NSMakeRange(next.length, 0)];
}

- (void)handleRunnerCompletion:(NSDictionary *)summary {
    self.stopButton.enabled = NO;
    self.lastImportedHandle = summary[@"lastImportedHandle"];
    self.lastImportedClipName = summary[@"lastImportedClipName"];
    self.lastImportedOutputPath = summary[@"lastImportedOutputPath"];
    self.lastImportedEventName = summary[@"lastImportedEventName"];

    NSInteger completed = [summary[@"completed"] integerValue];
    NSInteger failed = [summary[@"failed"] integerValue];
    NSInteger skipped = [summary[@"skipped"] integerValue];
    NSInteger replaced = [summary[@"replacedOnTimeline"] integerValue];
    NSInteger importedOnly = [summary[@"importedOnly"] integerValue];
    BOOL stopped = [summary[@"stopped"] boolValue];
    NSArray *items = [summary[@"items"] isKindOfClass:[NSArray class]] ? summary[@"items"] : @[];
    NSDictionary *firstFailure = nil;
    for (NSDictionary *item in items) {
        if ([[item[@"status"] lowercaseString] isEqualToString:@"failed"]) {
            firstFailure = item;
            break;
        }
    }

    if (stopped) {
        self.completionIconLabel.stringValue = @"!";
        self.completionIconLabel.textColor = [NSColor colorWithCalibratedRed:1.00 green:0.74 blue:0.33 alpha:1.0];
        self.completionHeadlineLabel.stringValue = @"Upscale Stopped";
    } else if (failed > 0 && completed == 0 && importedOnly == 0 && replaced == 0) {
        self.completionIconLabel.stringValue = @"!";
        self.completionIconLabel.textColor = [NSColor colorWithCalibratedRed:1.00 green:0.48 blue:0.48 alpha:1.0];
        self.completionHeadlineLabel.stringValue = @"Upscale Failed";
    } else if (failed > 0 || skipped > 0 || (importedOnly > 0 && [summary[@"mode"] isEqualToString:@"timeline_replace"])) {
        self.completionIconLabel.stringValue = @"!";
        self.completionIconLabel.textColor = [NSColor colorWithCalibratedRed:1.00 green:0.74 blue:0.33 alpha:1.0];
        self.completionHeadlineLabel.stringValue = @"Upscale Completed with Issues";
    } else {
        self.completionIconLabel.stringValue = @"✓";
        self.completionIconLabel.textColor = [NSColor colorWithCalibratedRed:0.46 green:0.90 blue:0.60 alpha:1.0];
        self.completionHeadlineLabel.stringValue = @"Upscale Complete";
    }

    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    if (stopped) {
        [lines addObject:[NSString stringWithFormat:@"Stopped after %@ clip%@.",
            summary[@"processed"], [summary[@"processed"] integerValue] == 1 ? @"" : @"s"]];
    } else if (failed > 0 && completed == 0 && importedOnly == 0 && replaced == 0) {
        NSString *detail = SpliceKitUprezzerString(firstFailure[@"detail"]);
        [lines addObject:detail.length > 0 ? detail : @"The selected clip could not be processed."];
    } else if (replaced > 0) {
        [lines addObject:[NSString stringWithFormat:@"Imported and replaced %ld timeline clip%@.",
            (long)replaced, replaced == 1 ? @"" : @"s"]];
    } else if (importedOnly > 0) {
        [lines addObject:[NSString stringWithFormat:@"Imported %ld clip%@ to the library.",
            (long)importedOnly, importedOnly == 1 ? @"" : @"s"]];
    } else {
        [lines addObject:[NSString stringWithFormat:@"%ld clip%@ processed.",
            (long)(completed + failed + skipped), (completed + failed + skipped) == 1 ? @"" : @"s"]];
    }
    if (importedOnly > 0 && [summary[@"mode"] isEqualToString:@"timeline_replace"]) {
        [lines addObject:@"Timeline replacement still needs review."];
    }
    if (failed > 0) {
        [lines addObject:[NSString stringWithFormat:@"Failed: %ld", (long)failed]];
    }
    if (skipped > 0) {
        [lines addObject:[NSString stringWithFormat:@"Skipped: %ld", (long)skipped]];
    }
    self.completionSummaryLabel.stringValue = [lines componentsJoinedByString:@"\n"];

    BOOL canReveal = (self.lastImportedHandle.length > 0 ||
                      self.lastImportedClipName.length > 0 ||
                      self.lastImportedOutputPath.length > 0);
    self.completionRevealButton.hidden = !canReveal;
    [self setPanelState:SpliceKitUprezzerPanelStateCompletion];
}

- (void)revealImportedClip:(__unused id)sender {
    id clip = nil;
    if (self.lastImportedHandle.length > 0) {
        clip = SpliceKit_resolveHandle(self.lastImportedHandle);
    }
    if (!clip && (self.lastImportedClipName.length > 0 || self.lastImportedOutputPath.length > 0)) {
        clip = SpliceKitUprezzerFindClipNamedInEvent(self.lastImportedClipName,
                                                     self.lastImportedEventName,
                                                     self.lastImportedOutputPath,
                                                     nil,
                                                     nil);
        if (clip) {
            self.lastImportedHandle = SpliceKit_storeHandle(clip) ?: self.lastImportedHandle;
        }
    }
    if (!clip) {
        SpliceKit_log(@"[Uprezzer] Reveal in Library failed: imported clip could not be resolved.");
        return;
    }
    if (!SpliceKitUprezzerSelectClipInBrowser(clip)) {
        SpliceKit_log(@"[Uprezzer] Reveal in Library failed for %@.",
                      self.lastImportedClipName ?: SpliceKitUprezzerDisplayNameForObject(clip) ?: @"<clip>");
    }
}

- (void)refreshSelection {
    self.selectionRefreshToken += 1;
    NSInteger token = self.selectionRefreshToken;
    self.selectedClipNameLabel.stringValue = @"Inspecting current selection…";
    self.upscaleButton.enabled = NO;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSInteger factor = [self currentScaleFactor];
        NSDictionary *snapshot = SpliceKitUprezzerSelectionSnapshot(factor);
        NSString *fxPath = SpliceKitUprezzerFXUpscalePath();

        dispatch_async(dispatch_get_main_queue(), ^{
            if (token != self.selectionRefreshToken) return;
            self.fxPath = fxPath;
            self.currentEventName = snapshot[@"currentEvent"];
            self.selectionItems = snapshot[@"items"] ?: @[];
            [self refreshSetupSummaryUI];
        });
    });
}

- (void)refreshSetupSummaryUI {
    SpliceKitUprezzerSourceContext sourceContext = SpliceKitUprezzerSourceContextTimeline;
    if (self.selectionItems.count > 0) {
        sourceContext = self.selectionItems.firstObject.sourceContext;
    }

    NSInteger selected = self.selectionItems.count;
    NSInteger ready = 0;
    NSInteger skipped = 0;
    NSMutableArray<NSString *> *skipReasons = [NSMutableArray array];
    for (SpliceKitUprezzerSelectedItem *item in self.selectionItems) {
        if (item.validationError.length > 0) {
            skipped++;
            if (item.validationError.length > 0 && ![skipReasons containsObject:item.validationError]) {
                [skipReasons addObject:item.validationError];
            }
        } else {
            ready++;
        }
    }

    NSInteger factor = [self currentScaleFactor];
    SpliceKitUprezzerSelectedItem *previewItem = self.selectionItems.firstObject;
    NSString *sourceLabel = selected > 0 ? SpliceKitUprezzerSourceLabel(sourceContext) : @"Selection";
    [self.sourcePillView setBadgeText:sourceLabel
                            textColor:[NSColor colorWithWhite:0.95 alpha:1.0]
                            fillColor:[NSColor colorWithCalibratedRed:0.25 green:0.27 blue:0.34 alpha:0.88]
                          borderColor:[NSColor clearColor]];
    self.selectedClipNameLabel.stringValue = previewItem.displayName.length > 0
        ? previewItem.displayName
        : @"No clip selected";

    if (previewItem) {
        NSString *ext = previewItem.sourcePath.pathExtension.length > 0 ? previewItem.sourcePath.pathExtension : @"mov";
        self.namingPreviewLabel.stringValue = SpliceKitUprezzerMakeOutputFilename(previewItem.displayName,
                                                                                   factor,
                                                                                   ext,
                                                                                   [NSSet set]);
    } else {
        self.namingPreviewLabel.stringValue = [NSString stringWithFormat:@"Example Clip [Uprezzer %ldx].mov", (long)factor];
    }

    [self.destinationPopup removeAllItems];
    NSString *currentEventLabel = self.currentEventName.length > 0
        ? [NSString stringWithFormat:@"Current Event (%@)", self.currentEventName]
        : @"Current Event";
    [self.destinationPopup addItemWithTitle:currentEventLabel];
    [self.destinationPopup addItemWithTitle:@"Uprezzer Outputs"];
    [self.destinationPopup selectItemAtIndex:self.currentEventName.length > 0 ? 0 : 1];

    BOOL timelineMode = (selected > 0 && sourceContext == SpliceKitUprezzerSourceContextTimeline);
    if (!timelineMode) {
        self.replaceTimelineRequested = NO;
    }
    [self refreshOutputChoiceStyles];

    if (timelineMode && self.replaceTimelineRequested) {
        self.outputHelpLabel.stringValue = @"Replacement happens after import verification.";
    } else if (selected == 0) {
        self.outputHelpLabel.stringValue = @"Select a clip in the timeline or browser to continue.";
    } else if (skipped > 0) {
        self.outputHelpLabel.stringValue = [NSString stringWithFormat:@"Skipped item: %@",
                                            [skipReasons componentsJoinedByString:@"; "]];
    } else if (timelineMode) {
        self.outputHelpLabel.stringValue = @"Imports the new clip without changing the current edit.";
    } else {
        self.outputHelpLabel.stringValue = @"Imports the upscale into the current library event.";
    }

    if (self.fxPath.length == 0) {
        self.dependencyLabel.stringValue = @"fx-upscale is not available on this Mac. Install it first, then reopen Uprezzer.";
        self.dependencyLabel.hidden = NO;
    } else {
        self.dependencyLabel.stringValue = @"";
        self.dependencyLabel.hidden = YES;
    }

    self.upscaleButton.enabled = (ready > 0 && self.fxPath.length > 0);
}

- (void)windowWillClose:(__unused NSNotification *)notification {
    if (self.panelState == SpliceKitUprezzerPanelStateProgress) {
        [self.runner cancel];
    }
}

@end
