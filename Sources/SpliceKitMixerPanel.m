//
//  SpliceKitMixerPanel.m
//  Audio mixer panel with per-clip volume faders inside FCP
//

#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <float.h>
#import <math.h>
#import "SpliceKit.h"

// Forward declarations from SpliceKitServer.m
extern id SpliceKit_getActiveTimelineModule(void);
extern id SpliceKit_getMasterAudioDest(void);
extern id SpliceKit_storeHandle(id obj);
extern id SpliceKit_resolveHandle(NSString *handle);
extern double SpliceKit_channelValue(id channel);
extern BOOL SpliceKit_setChannelValue(id channel, double value);
extern BOOL SpliceKit_mixerSetStaticChannelValue(id channel, double value);
extern BOOL SpliceKit_removeChannelKeyframes(id channel);
extern BOOL SpliceKit_mixerWriteAutomationPoint(id clip, id channel, double value);
extern NSDictionary *SpliceKit_handleEffectsListAvailable(NSDictionary *params);
extern NSDictionary *SpliceKit_handleMixerApplyBusEffect(NSDictionary *params);
extern NSDictionary *SpliceKit_handleMixerOpenBusEffect(NSDictionary *params);
extern NSDictionary *SpliceKit_handleMixerSetBusEffectEnabled(NSDictionary *params);
extern NSDictionary *SpliceKit_handleMixerRemoveBusEffect(NSDictionary *params);

// CMTime struct (matches FCP's internal layout)
typedef struct { long long value; int timescale; unsigned int flags; long long epoch; } SKMixer_CMTime;
typedef struct { SKMixer_CMTime start; SKMixer_CMTime duration; } SKMixer_CMTimeRange;

#if defined(__arm64__) || defined(__aarch64__)
  #define SK_STRET_MSG objc_msgSend
#else
  #define SK_STRET_MSG objc_msgSend_stret
#endif

#pragma mark - Meter Observer

// Stores live audio levels per role UID, updated by FCP's metering timer
// Non-static so it can be accessed from SpliceKitServer.m via extern
NSMutableDictionary *sMeterLevels = nil; // roleUID -> @(peakLinear)

static const char kMeterRoleUIDKey = 0; // associated object key
static const NSInteger kSpliceKitMixerMaxFaders = 12;
static const CGFloat kSpliceKitMixerFaderWidth = 92.0;

@interface SpliceKitMeterObserver : NSObject
@property (nonatomic, strong) NSString *roleUID;
@end

@implementation SpliceKitMeterObserver

// Called by FCP's FFContext _updateMeters: timer for each registered role.
// Signature: contextMeterUpdate:(uint)channels peakValues:(float*)peaks loudnessValues:(struct*)loudness
// We use NSMethodSignature override to ensure the runtime finds this method.
- (void)contextMeterUpdate:(NSUInteger)channels peakValues:(void *)peaks loudnessValues:(void *)loudness {
    if (!peaks) return;
    if (channels == 0) return;
    float *peakArray = (float *)peaks;
    float maxPeak = 0;
    for (NSUInteger i = 0; i < channels && i < 32; i++) {
        if (peakArray[i] > maxPeak) maxPeak = peakArray[i];
    }
    if (!sMeterLevels) sMeterLevels = [NSMutableDictionary dictionary];
    if (self.roleUID) {
        sMeterLevels[self.roleUID] = @(maxPeak);
    }
}

// Handle any unrecognized selectors gracefully to prevent crashes
- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel {
    NSMethodSignature *sig = [super methodSignatureForSelector:sel];
    if (!sig) {
        // Return a void signature for any unknown selector
        sig = [NSMethodSignature signatureWithObjCTypes:"v@:"];
    }
    return sig;
}

- (void)forwardInvocation:(NSInvocation *)invocation {
    // Log the selector FCP is trying to call
    SpliceKit_log(@"[Mixer] MeterObserver forwarded: %@", NSStringFromSelector(invocation.selector));
}

@end

#pragma mark - Fader State

@interface SpliceKitFaderState : NSObject
@property (nonatomic, assign) NSInteger index;
@property (nonatomic, strong) NSString *clipHandle;
@property (nonatomic, strong) NSString *volumeChannelHandle;
@property (nonatomic, strong) NSString *audioEffectStackHandle;
@property (nonatomic, strong) NSString *effectStackHandle; // main effectStack (for undo transactions)
@property (nonatomic, strong) NSString *busKind;
@property (nonatomic, strong) NSString *busEffectStackHandle;
@property (nonatomic, strong) NSArray<NSString *> *busEffectNames;
@property (nonatomic, strong) NSArray<NSDictionary *> *busEffects;
@property (nonatomic, assign) NSInteger busObjectCount;
@property (nonatomic, assign) NSInteger busEffectCount;
@property (nonatomic, strong) NSString *clipName;
@property (nonatomic, assign) NSInteger lane;
@property (nonatomic, assign) double volumeDB;
@property (nonatomic, assign) double volumeLinear;
@property (nonatomic, strong) NSString *role;
@property (nonatomic, strong) NSString *roleColorHex; // "#RRGGBB" from FCP
@property (nonatomic, assign) double meterDB; // real-time audio level (dB)
@property (nonatomic, assign) double meterLinear; // real-time audio level (0..1)
@property (nonatomic, assign) double meterPeak; // displayed peak ratio from FCP meters (0..1)
@property (nonatomic, assign) BOOL meterClipping; // true when the live meter hits clip/peak
@property (nonatomic, assign) CFTimeInterval clipLatchedUntil; // keep clip state visible briefly
@property (nonatomic, assign) CFTimeInterval lastMeterSampleTime;
@property (nonatomic, assign) BOOL isAutomationArmed;
@property (nonatomic, assign) BOOL isSoloed;
@property (nonatomic, assign) BOOL isSoloMuted;
@property (nonatomic, assign) BOOL isMuted;
@property (nonatomic, assign) BOOL isMuteMixed;
@property (nonatomic, assign) BOOL isActive;
@property (nonatomic, assign) BOOL isPlaying; // clip with this role is at playhead
@property (nonatomic, assign) BOOL isMaster;
@property (nonatomic, assign) BOOL isDragging;
@property (nonatomic, assign) BOOL isRecordingAutomation;
@property (nonatomic, assign) BOOL didRecordAutomationInDrag;
@property (nonatomic, assign) BOOL didPrepareAutomationInDrag;
@property (nonatomic, assign) double lastAutomationPlayheadSeconds;
@property (nonatomic, assign) double lastAutomationLinear;
@property (nonatomic, assign) double minDB;
@property (nonatomic, assign) double maxDB;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *openEffectStackHandlesByPointer;
@end

@implementation SpliceKitFaderState
@end

#pragma mark - Fader View

@class SpliceKitMouseOnlyButton;

@interface SpliceKitFaderView : NSView
@property (nonatomic, strong) SpliceKitFaderState *state;
@property (nonatomic, strong) NSSlider *slider;
@property (nonatomic, strong) NSView *displayCard;
@property (nonatomic, strong) NSTextField *dbLabel;
@property (nonatomic, strong) NSTextField *nameLabel;
@property (nonatomic, strong) NSTextField *roleLabel;
@property (nonatomic, strong) NSTextField *indexLabel;
@property (nonatomic, strong) NSImageView *iconView;
@property (nonatomic, strong) NSView *clipTagView;
@property (nonatomic, strong) NSMutableArray<NSView *> *statusBadges;
@property (nonatomic, strong) NSMutableArray<NSTextField *> *statusBadgeLabels;
@property (nonatomic, strong) SpliceKitMouseOnlyButton *muteBadgeButton;
@property (nonatomic, strong) SpliceKitMouseOnlyButton *soloBadgeButton;
@property (nonatomic, strong) SpliceKitMouseOnlyButton *armBadgeButton;
@property (nonatomic, strong) SpliceKitMouseOnlyButton *effectButton;
@property (nonatomic, strong) NSView *trackView;
@property (nonatomic, strong) NSView *fillView;
@property (nonatomic, strong) NSView *knobView;
@property (nonatomic, strong) CAGradientLayer *knobGradientLayer;
@property (nonatomic, strong) NSView *knobAccentView;
@property (nonatomic, strong) NSView *meterContainer;
@property (nonatomic, strong) NSMutableArray<NSView *> *meterSegments;
@property (nonatomic, strong) CAGradientLayer *stripGradientLayer;
@property (nonatomic, strong) CAGradientLayer *displayGradientLayer;
@property (nonatomic, copy) void (^onDragStart)(void);
@property (nonatomic, copy) void (^onDragChange)(double db);
@property (nonatomic, copy) void (^onDragEnd)(void);
@property (nonatomic, copy) void (^onToggleArm)(void);
@property (nonatomic, copy) void (^onToggleSolo)(void);
@property (nonatomic, copy) void (^onToggleMute)(void);
@property (nonatomic, copy) void (^onShowEffects)(void);
- (void)updateFromState;
@end

// dB <-> slider position (0..100) with perceptual curve.
// Clip faders reserve the top quarter for positive gain; the master spans -96..0 dB.
static double dbToSliderPos(double db, double minDB, double maxDB) {
    if (db <= minDB) return 0;
    if (db >= maxDB) return 100;

    double positiveHeadroom = fmax(0.0, maxDB);
    if (positiveHeadroom > 0.0 && db >= 0.0) {
        return 75.0 + (db / positiveHeadroom) * 25.0;
    }

    double upperBound = (positiveHeadroom > 0.0) ? 0.0 : maxDB;
    double span = upperBound - minDB;
    if (span <= 0.0) return 0.0;

    double norm = (db - minDB) / span;
    double sliderTop = (positiveHeadroom > 0.0) ? 75.0 : 100.0;
    return sqrt(fmax(0.0, norm)) * sliderTop;
}

static double sliderPosToDB(double pos, double minDB, double maxDB) {
    if (pos <= 0) return minDB;
    if (pos >= 100) return maxDB;

    double positiveHeadroom = fmax(0.0, maxDB);
    if (positiveHeadroom > 0.0 && pos >= 75.0) {
        return ((pos - 75.0) / 25.0) * positiveHeadroom;
    }

    double sliderTop = (positiveHeadroom > 0.0) ? 75.0 : 100.0;
    double upperBound = (positiveHeadroom > 0.0) ? 0.0 : maxDB;
    double span = upperBound - minDB;
    if (span <= 0.0) return minDB;

    double norm = pos / sliderTop;
    return (norm * norm) * span + minDB;
}

static NSColor *SKMixerColor(CGFloat r, CGFloat g, CGFloat b) {
    return [NSColor colorWithSRGBRed:r green:g blue:b alpha:1.0];
}

static NSColor *SKMixerColorFromHex(NSString *hex, NSColor *fallback) {
    if (![hex isKindOfClass:[NSString class]] || hex.length != 7 || ![hex hasPrefix:@"#"]) {
        return fallback;
    }

    unsigned int r = 0, g = 0, b = 0;
    if (sscanf(hex.UTF8String, "#%02x%02x%02x", &r, &g, &b) != 3) {
        return fallback;
    }

    return [NSColor colorWithSRGBRed:r / 255.0
                               green:g / 255.0
                                blue:b / 255.0
                               alpha:1.0];
}

typedef NS_ENUM(NSInteger, SKMixerRoleCategory) {
    SKMixerRoleCategoryInactive,
    SKMixerRoleCategoryMaster,
    SKMixerRoleCategoryDialogue,
    SKMixerRoleCategoryMusic,
    SKMixerRoleCategoryEffects,
    SKMixerRoleCategoryGeneric,
};

static SKMixerRoleCategory SKMixerRoleCategoryForState(SpliceKitFaderState *state) {
    if (!state.isActive) return SKMixerRoleCategoryInactive;
    if (state.isMaster) return SKMixerRoleCategoryMaster;

    NSString *lower = state.role.lowercaseString ?: @"";
    if ([lower containsString:@"dialogue"]) return SKMixerRoleCategoryDialogue;
    if ([lower containsString:@"music"]) return SKMixerRoleCategoryMusic;
    if ([lower containsString:@"effect"]) return SKMixerRoleCategoryEffects;
    return SKMixerRoleCategoryGeneric;
}

static NSColor *SKMixerAccentForState(SpliceKitFaderState *state) {
    if (state.isMaster) return SKMixerColor(0.98, 0.56, 0.26);

    SKMixerRoleCategory category = SKMixerRoleCategoryForState(state);
    NSColor *fallback = nil;
    switch (category) {
        case SKMixerRoleCategoryDialogue: fallback = SKMixerColor(0.94, 0.78, 0.38); break;
        case SKMixerRoleCategoryMusic: fallback = SKMixerColor(0.34, 0.86, 0.56); break;
        case SKMixerRoleCategoryEffects: fallback = SKMixerColor(0.77, 0.46, 0.96); break;
        case SKMixerRoleCategoryGeneric: fallback = SKMixerColor(0.42, 0.76, 0.98); break;
        default: fallback = [[NSColor whiteColor] colorWithAlphaComponent:0.30]; break;
    }
    return SKMixerColorFromHex(state.roleColorHex, fallback);
}

static NSArray<NSColor *> *SKMixerStripGradientColors(SpliceKitFaderState *state) {
    switch (SKMixerRoleCategoryForState(state)) {
        case SKMixerRoleCategoryDialogue:
            return @[
                SKMixerColor(0.34, 0.31, 0.18),
                SKMixerColor(0.22, 0.20, 0.13),
                SKMixerColor(0.14, 0.14, 0.15)
            ];
        case SKMixerRoleCategoryMusic:
            return @[
                SKMixerColor(0.10, 0.24, 0.18),
                SKMixerColor(0.11, 0.16, 0.16),
                SKMixerColor(0.12, 0.14, 0.15)
            ];
        case SKMixerRoleCategoryEffects:
            return @[
                SKMixerColor(0.23, 0.16, 0.28),
                SKMixerColor(0.16, 0.14, 0.20),
                SKMixerColor(0.12, 0.12, 0.15)
            ];
        case SKMixerRoleCategoryMaster:
            return @[
                SKMixerColor(0.33, 0.20, 0.11),
                SKMixerColor(0.22, 0.14, 0.09),
                SKMixerColor(0.14, 0.12, 0.12)
            ];
        case SKMixerRoleCategoryGeneric:
            return @[
                SKMixerColor(0.18, 0.20, 0.27),
                SKMixerColor(0.14, 0.15, 0.20),
                SKMixerColor(0.12, 0.12, 0.16)
            ];
        case SKMixerRoleCategoryInactive:
        default:
            return @[
                SKMixerColor(0.22, 0.22, 0.24),
                SKMixerColor(0.18, 0.18, 0.20),
                SKMixerColor(0.15, 0.15, 0.17)
            ];
    }
}

static NSArray<NSColor *> *SKMixerDisplayGradientColors(SpliceKitFaderState *state, NSColor *accent) {
    switch (SKMixerRoleCategoryForState(state)) {
        case SKMixerRoleCategoryDialogue:
            return @[SKMixerColor(0.35, 0.29, 0.12), SKMixerColor(0.17, 0.15, 0.10)];
        case SKMixerRoleCategoryMusic:
            return @[SKMixerColor(0.11, 0.38, 0.24), SKMixerColor(0.07, 0.18, 0.15)];
        case SKMixerRoleCategoryEffects:
            return @[SKMixerColor(0.31, 0.18, 0.39), SKMixerColor(0.16, 0.12, 0.25)];
        case SKMixerRoleCategoryMaster:
            return @[SKMixerColor(0.42, 0.24, 0.10), SKMixerColor(0.22, 0.13, 0.08)];
        case SKMixerRoleCategoryGeneric:
            return @[
                [accent colorWithAlphaComponent:0.36],
                [accent colorWithAlphaComponent:0.16]
            ];
        case SKMixerRoleCategoryInactive:
        default:
            return @[
                [[NSColor whiteColor] colorWithAlphaComponent:0.08],
                [[NSColor whiteColor] colorWithAlphaComponent:0.02]
            ];
    }
}

static NSString *SKMixerSymbolNameForState(SpliceKitFaderState *state) {
    switch (SKMixerRoleCategoryForState(state)) {
        case SKMixerRoleCategoryDialogue: return @"speaker.wave.2.fill";
        case SKMixerRoleCategoryMusic: return @"music.note";
        case SKMixerRoleCategoryEffects: return @"waveform";
        case SKMixerRoleCategoryMaster: return @"speaker.wave.3.fill";
        case SKMixerRoleCategoryGeneric: return @"slider.horizontal.3";
        case SKMixerRoleCategoryInactive:
        default: return @"slider.horizontal.3";
    }
}

static BOOL SKMixerShowsClipping(SpliceKitFaderState *state) {
    if (!state) return NO;
    return state.meterClipping || CFAbsoluteTimeGetCurrent() < state.clipLatchedUntil;
}

static double SKMixerDisplayedPeakForUpdate(double currentPeak,
                                            double livePeak,
                                            BOOL transportPlaying,
                                            CFTimeInterval deltaTime) {
    if (!isfinite(livePeak)) livePeak = 0.0;
    if (livePeak < 0.0) livePeak = 0.0;
    if (livePeak > 1.0) livePeak = 1.0;

    if (transportPlaying) {
        return livePeak;
    }

    if (!isfinite(currentPeak) || currentPeak <= 0.0) {
        return 0.0;
    }

    if (!isfinite(deltaTime) || deltaTime <= 0.0 || deltaTime > 0.25) {
        deltaTime = 0.05;
    }

    double decayedPeak = currentPeak - (1.4 * deltaTime);
    if (decayedPeak < livePeak) decayedPeak = livePeak;
    if (decayedPeak < 0.001) return 0.0;
    return decayedPeak;
}

@interface SpliceKitMouseOnlyButton : NSButton
@end

@interface SpliceKitTransparentSliderCell : NSSliderCell
@end

@implementation SpliceKitTransparentSliderCell

- (void)drawBarInside:(NSRect)aRect flipped:(BOOL)flipped {
}

- (void)drawKnob:(NSRect)knobRect {
}

@end

@interface SpliceKitInputSlider : NSSlider
@end

@implementation SpliceKitInputSlider

- (BOOL)acceptsFirstResponder {
    return NO;
}

- (BOOL)becomeFirstResponder {
    return NO;
}

- (NSRect)focusRingMaskBounds {
    return NSZeroRect;
}

- (void)drawFocusRingMask {
}

@end

@implementation SpliceKitMouseOnlyButton

- (BOOL)acceptsFirstResponder {
    return NO;
}

- (BOOL)canBecomeKeyView {
    return NO;
}

- (BOOL)performKeyEquivalent:(NSEvent *)event {
    return NO;
}

@end

@implementation SpliceKitFaderView {
    BOOL _tracking;
}

- (instancetype)initWithFrame:(NSRect)frame index:(NSInteger)idx {
    self = [super initWithFrame:frame];
    if (self) {
        self.wantsLayer = YES;
        self.layer.cornerRadius = 14.0;
        self.layer.borderWidth = 1.0;
        self.layer.masksToBounds = NO;
        if (@available(macOS 10.15, *)) {
            self.layer.cornerCurve = kCACornerCurveContinuous;
        }

        _stripGradientLayer = [CAGradientLayer layer];
        _stripGradientLayer.startPoint = CGPointMake(0.5, 1.0);
        _stripGradientLayer.endPoint = CGPointMake(0.5, 0.0);
        _stripGradientLayer.cornerRadius = 14.0;
        [self.layer insertSublayer:_stripGradientLayer atIndex:0];

        _state = [[SpliceKitFaderState alloc] init];
        _state.index = idx;
        _state.isMaster = (idx < 0);
        _state.minDB = -96.0;
        _state.maxDB = _state.isMaster ? 0.0 : 12.0;

        _displayCard = [[NSView alloc] initWithFrame:NSZeroRect];
        _displayCard.wantsLayer = YES;
        _displayCard.layer.cornerRadius = 8.0;
        _displayCard.layer.borderWidth = 1.0;
        if (@available(macOS 10.15, *)) {
            _displayCard.layer.cornerCurve = kCACornerCurveContinuous;
        }
        _displayGradientLayer = [CAGradientLayer layer];
        _displayGradientLayer.startPoint = CGPointMake(0.0, 1.0);
        _displayGradientLayer.endPoint = CGPointMake(1.0, 0.0);
        _displayGradientLayer.cornerRadius = 8.0;
        [_displayCard.layer insertSublayer:_displayGradientLayer atIndex:0];

        NSString *indexTitle = _state.isMaster ? @"M" : [NSString stringWithFormat:@"%ld", (long)idx + 1];
        _indexLabel = [self makeLabel:indexTitle size:28 bold:NO];
        _indexLabel.font = [NSFont systemFontOfSize:28 weight:NSFontWeightRegular];

        _dbLabel = [self makeLabel:@"--" size:10 bold:YES];
        _dbLabel.font = [NSFont systemFontOfSize:10 weight:NSFontWeightSemibold];

        _slider = [[SpliceKitInputSlider alloc] initWithFrame:NSZeroRect];
        _slider.vertical = YES;
        _slider.cell = [[SpliceKitTransparentSliderCell alloc] init];
        _slider.minValue = 0;
        _slider.maxValue = 100;
        _slider.doubleValue = dbToSliderPos(0, _state.minDB, _state.maxDB);
        _slider.target = self;
        _slider.action = @selector(sliderChanged:);
        _slider.continuous = YES;
        _slider.focusRingType = NSFocusRingTypeNone;

        _trackView = [[NSView alloc] initWithFrame:NSZeroRect];
        _trackView.wantsLayer = YES;
        _trackView.layer.cornerRadius = 4.0;
        _trackView.layer.backgroundColor = [SKMixerColor(0.10, 0.10, 0.12) colorWithAlphaComponent:0.75].CGColor;

        _fillView = [[NSView alloc] initWithFrame:NSZeroRect];
        _fillView.wantsLayer = YES;
        _fillView.layer.cornerRadius = 2.0;

        _knobView = [[NSView alloc] initWithFrame:NSZeroRect];
        _knobView.wantsLayer = YES;
        _knobView.layer.cornerRadius = 10.0;
        _knobView.layer.shadowOpacity = 0.45;
        _knobView.layer.shadowRadius = 8.0;
        _knobView.layer.shadowOffset = CGSizeMake(0, 6);
        _knobGradientLayer = [CAGradientLayer layer];
        _knobGradientLayer.startPoint = CGPointMake(0.5, 1.0);
        _knobGradientLayer.endPoint = CGPointMake(0.5, 0.0);
        _knobGradientLayer.cornerRadius = 10.0;
        [_knobView.layer insertSublayer:_knobGradientLayer atIndex:0];

        _knobAccentView = [[NSView alloc] initWithFrame:NSZeroRect];
        _knobAccentView.wantsLayer = YES;
        _knobAccentView.layer.cornerRadius = 2.0;
        [_knobView addSubview:_knobAccentView];

        _meterContainer = [[NSView alloc] initWithFrame:NSZeroRect];
        _meterContainer.wantsLayer = YES;
        _meterContainer.layer.cornerRadius = 8.0;
        _meterContainer.layer.backgroundColor = [[NSColor blackColor] colorWithAlphaComponent:0.32].CGColor;
        _meterContainer.layer.borderWidth = 1.0;
        _meterContainer.layer.borderColor = [[NSColor whiteColor] colorWithAlphaComponent:0.08].CGColor;

        _meterSegments = [NSMutableArray array];
        for (NSInteger i = 0; i < 34; i++) {
            NSView *segment = [[NSView alloc] initWithFrame:NSZeroRect];
            segment.wantsLayer = YES;
            segment.layer.cornerRadius = 1.0;
            [_meterContainer addSubview:segment];
            [_meterSegments addObject:segment];
        }

        _statusBadges = [NSMutableArray array];
        _statusBadgeLabels = [NSMutableArray array];
        for (NSInteger i = 0; i < 3; i++) {
            NSView *badge = [[NSView alloc] initWithFrame:NSZeroRect];
            badge.wantsLayer = YES;
            badge.layer.cornerRadius = 8.0;
            badge.layer.borderWidth = 1.0;
            if (@available(macOS 10.15, *)) {
                badge.layer.cornerCurve = kCACornerCurveContinuous;
            }

            NSTextField *label = [self makeLabel:@"" size:10 bold:YES];
            label.font = [NSFont systemFontOfSize:10 weight:NSFontWeightSemibold];
            [badge addSubview:label];
            [_statusBadges addObject:badge];
            [_statusBadgeLabels addObject:label];
            [self addSubview:badge];
        }

        _muteBadgeButton = [self makeBadgeButtonWithAction:@selector(toggleMuteBadge:)];
        _soloBadgeButton = [self makeBadgeButtonWithAction:@selector(toggleSoloBadge:)];
        _armBadgeButton = [self makeBadgeButtonWithAction:@selector(toggleArmBadge:)];
        _effectButton = [self makeBadgeButtonWithAction:@selector(showEffectsMenu:)];
        [self addSubview:_muteBadgeButton];
        [self addSubview:_soloBadgeButton];
        [self addSubview:_armBadgeButton];
        [self addSubview:_effectButton];

        _iconView = [[NSImageView alloc] initWithFrame:NSZeroRect];
        _iconView.imageScaling = NSImageScaleProportionallyUpOrDown;

        _roleLabel = [self makeLabel:@"" size:11 bold:YES];
        _roleLabel.font = [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold];
        _roleLabel.maximumNumberOfLines = 2;
        _roleLabel.cell.wraps = YES;
        _roleLabel.cell.lineBreakMode = NSLineBreakByWordWrapping;

        _clipTagView = [[NSView alloc] initWithFrame:NSZeroRect];
        _clipTagView.wantsLayer = YES;
        _clipTagView.layer.cornerRadius = 7.0;
        _clipTagView.layer.backgroundColor = [[NSColor blackColor] colorWithAlphaComponent:0.38].CGColor;

        _nameLabel = [self makeLabel:@"--" size:8.5 bold:YES];
        _nameLabel.font = [NSFont systemFontOfSize:8.5 weight:NSFontWeightMedium];
        _nameLabel.maximumNumberOfLines = 2;
        _nameLabel.cell.wraps = YES;
        _nameLabel.cell.lineBreakMode = NSLineBreakByWordWrapping;

        [_displayCard addSubview:_indexLabel];
        [_displayCard addSubview:_dbLabel];
        [_clipTagView addSubview:_nameLabel];

        // Keep the transparent slider above the decorative layers so it owns hit-testing.
        for (NSView *view in @[_displayCard, _trackView, _fillView, _meterContainer, _knobView, _iconView, _roleLabel, _clipTagView, _slider]) {
            [self addSubview:view];
        }
    }
    return self;
}

- (NSTextField *)makeLabel:(NSString *)text size:(CGFloat)size bold:(BOOL)bold {
    NSTextField *label = [NSTextField labelWithString:text];
    label.font = bold ? [NSFont boldSystemFontOfSize:size] : [NSFont systemFontOfSize:size];
    label.alignment = NSTextAlignmentCenter;
    label.textColor = [NSColor labelColor];
    return label;
}

- (SpliceKitMouseOnlyButton *)makeBadgeButtonWithAction:(SEL)action {
    SpliceKitMouseOnlyButton *button = [[SpliceKitMouseOnlyButton alloc] initWithFrame:NSZeroRect];
    button.bordered = NO;
    button.focusRingType = NSFocusRingTypeNone;
    button.keyEquivalent = @"";
    button.wantsLayer = YES;
    button.layer.cornerRadius = 8.0;
    button.layer.borderWidth = 1.0;
    button.layer.masksToBounds = YES;
    if (@available(macOS 10.15, *)) {
        button.layer.cornerCurve = kCACornerCurveContinuous;
    }
    button.target = self;
    button.action = action;
    return button;
}

- (void)toggleMuteBadge:(id)sender {
    if (self.onToggleMute) self.onToggleMute();
}

- (void)toggleSoloBadge:(id)sender {
    if (self.onToggleSolo) self.onToggleSolo();
}

- (void)toggleArmBadge:(id)sender {
    if (self.onToggleArm) self.onToggleArm();
}

- (void)showEffectsMenu:(id)sender {
    if (self.onShowEffects) self.onShowEffects();
}

- (void)layout {
    [super layout];

    self.stripGradientLayer.frame = self.bounds;

    CGFloat width = NSWidth(self.bounds);
    CGFloat height = NSHeight(self.bounds);
    CGFloat horizontalInset = 4.0;
    CGFloat displayWidth = width - horizontalInset * 2.0;
    CGFloat displayHeight = 88.0;
    CGFloat badgeWidth = 34.0;
    CGFloat badgeHeight = 28.0;
    CGFloat badgeSpacing = 8.0;
    CGFloat bottomInset = 8.0;
    CGFloat bottomSectionHeight = 96.0;

    CGFloat displayX = floor((width - displayWidth) / 2.0);
    self.displayCard.frame = NSMakeRect(displayX, height - 4.0 - displayHeight, displayWidth, displayHeight);
    self.displayGradientLayer.frame = self.displayCard.bounds;

    self.indexLabel.frame = NSMakeRect(0, 38, NSWidth(self.displayCard.bounds), 28);
    self.dbLabel.frame = NSMakeRect(0, 15, NSWidth(self.displayCard.bounds), 15);

    CGFloat badgesTotalWidth = badgeWidth * 2.0 + badgeSpacing;
    CGFloat badgeOriginX = floor(NSMinX(self.displayCard.frame) + (NSWidth(self.displayCard.frame) - badgesTotalWidth) / 2.0);
    CGFloat firstBadgeRowY = NSMinY(self.displayCard.frame) - 14.0 - badgeHeight;
    CGFloat secondBadgeRowY = firstBadgeRowY - badgeSpacing - badgeHeight;
    CGFloat thirdBadgeRowY = secondBadgeRowY - badgeSpacing - badgeHeight;
    CGFloat effectButtonY = thirdBadgeRowY - badgeSpacing - badgeHeight;
    for (NSInteger idx = 0; idx < self.statusBadges.count; idx++) {
        NSInteger row = idx / 2;
        NSInteger col = idx % 2;
        NSView *badge = self.statusBadges[idx];
        badge.frame = NSMakeRect(badgeOriginX + col * (badgeWidth + badgeSpacing),
                                 (row == 0 ? firstBadgeRowY : secondBadgeRowY),
                                 badgeWidth,
                                 badgeHeight);
        NSTextField *badgeLabel = self.statusBadgeLabels[idx];
        [badgeLabel sizeToFit];
        NSRect labelFrame = badgeLabel.frame;
        labelFrame.origin.x = floor((badgeWidth - NSWidth(labelFrame)) / 2.0);
        labelFrame.origin.y = floor((badgeHeight - NSHeight(labelFrame)) / 2.0) - 1.0;
        badgeLabel.frame = labelFrame;
    }
    self.muteBadgeButton.frame = NSMakeRect(badgeOriginX + (badgeWidth + badgeSpacing),
                                            secondBadgeRowY,
                                            badgeWidth,
                                            badgeHeight);
    self.soloBadgeButton.frame = NSMakeRect(badgeOriginX,
                                            thirdBadgeRowY,
                                            badgeWidth,
                                            badgeHeight);
    self.armBadgeButton.frame = NSMakeRect(badgeOriginX + (badgeWidth + badgeSpacing),
                                           thirdBadgeRowY,
                                           badgeWidth,
                                           badgeHeight);
    self.effectButton.frame = NSMakeRect(NSMinX(self.displayCard.frame) + 8.0,
                                         effectButtonY,
                                         NSWidth(self.displayCard.frame) - 16.0,
                                         badgeHeight);

    CGFloat bottomSectionTop = bottomInset + bottomSectionHeight;
    CGFloat faderSectionY = bottomSectionTop + 12.0;
    CGFloat faderSectionHeight = MAX(200.0, effectButtonY - 18.0 - faderSectionY);
    CGFloat controlHeight = MIN(270.0, faderSectionHeight - 12.0);
    CGFloat controlY = faderSectionY + floor((faderSectionHeight - controlHeight) / 2.0);
    CGFloat meterWidth = 22.0;
    CGFloat faderWidth = 34.0;
    CGFloat faderGap = 10.0;
    CGFloat controlTotalWidth = faderWidth + faderGap + meterWidth;
    CGFloat controlX = floor((width - controlTotalWidth) / 2.0);

    self.slider.frame = NSMakeRect(controlX, controlY, faderWidth, controlHeight);
    self.trackView.frame = NSMakeRect(controlX + floor((faderWidth - 8.0) / 2.0), controlY + 10.0, 8.0, controlHeight - 20.0);
    self.meterContainer.frame = NSMakeRect(NSMaxX(self.slider.frame) + faderGap, controlY + 5.0, meterWidth, controlHeight - 10.0);

    CGFloat sliderPos = self.slider.doubleValue;
    CGFloat knobHeight = 44.0;
    CGFloat knobWidth = 34.0;
    CGFloat usableHeight = MAX(1.0, NSHeight(self.slider.frame) - knobHeight);
    CGFloat knobY = NSMinY(self.slider.frame) + (sliderPos / 100.0) * usableHeight;
    self.knobView.frame = NSMakeRect(controlX, knobY, knobWidth, knobHeight);
    self.knobGradientLayer.frame = self.knobView.bounds;
    self.knobAccentView.frame = NSMakeRect(floor((knobWidth - 24.0) / 2.0),
                                           floor((knobHeight - 4.0) / 2.0),
                                           24.0,
                                           4.0);

    CGFloat fillHeight = MAX(18.0, NSHeight(self.trackView.frame) * (sliderPos / 100.0));
    self.fillView.frame = NSMakeRect(NSMidX(self.trackView.frame) - 2.0,
                                     NSMinY(self.trackView.frame),
                                     4.0,
                                     fillHeight);

    CGFloat segmentHeight = 5.0;
    CGFloat segmentGap = 2.0;
    CGFloat segmentInsetX = 4.0;
    CGFloat segmentInsetY = 4.0;
    for (NSInteger idx = 0; idx < self.meterSegments.count; idx++) {
        NSView *segment = self.meterSegments[idx];
        CGFloat y = segmentInsetY + idx * (segmentHeight + segmentGap);
        segment.frame = NSMakeRect(segmentInsetX,
                                   y,
                                   NSWidth(self.meterContainer.bounds) - segmentInsetX * 2.0,
                                   segmentHeight);
    }

    self.iconView.frame = NSMakeRect(floor((width - 18.0) / 2.0), bottomInset + 62.0, 18.0, 18.0);
    self.roleLabel.frame = NSMakeRect(8.0, bottomInset + 28.0, width - 16.0, 30.0);
    self.clipTagView.frame = NSMakeRect(8.0, bottomInset, width - 16.0, 24.0);
    self.nameLabel.frame = NSInsetRect(self.clipTagView.bounds, 4.0, 3.0);
}

- (void)sliderChanged:(NSSlider *)sender {
    NSEvent *event = [NSApp currentEvent];
    BOOL starting = !_tracking;
    _tracking = YES;

    double db = sliderPosToDB(sender.doubleValue, _state.minDB, _state.maxDB);
    _state.volumeDB = db;
    _state.isDragging = YES;
    [self updateDBLabel];
    [self setNeedsLayout:YES];

    if (starting && self.onDragStart) self.onDragStart();
    if (self.onDragChange) self.onDragChange(db);

    // Detect mouse-up (end of drag)
    if (event.type == NSEventTypeLeftMouseUp) {
        _tracking = NO;
        _state.isDragging = NO;
        if (self.onDragEnd) self.onDragEnd();
    }
}

- (void)updateFromState {
    BOOL active = _state.isActive;
    BOOL playing = _state.isPlaying;
    BOOL outputMuted = !_state.isMaster && (_state.isMuted || _state.isSoloMuted);
    BOOL signalEnabled = active && !outputMuted;
    _slider.enabled = active;
    NSColor *accentColor = SKMixerAccentForState(_state);
    NSColor *displayTextColor = active ? accentColor : [[NSColor whiteColor] colorWithAlphaComponent:0.24];
    NSColor *secondaryColor = active ? [accentColor colorWithAlphaComponent:0.88]
                                     : [[NSColor whiteColor] colorWithAlphaComponent:0.18];

    self.layer.borderColor = (_state.isRecordingAutomation
                              ? [[NSColor systemRedColor] colorWithAlphaComponent:0.95].CGColor
                              : [accentColor colorWithAlphaComponent:(signalEnabled ? (playing ? 0.28 : 0.14) : 0.10)].CGColor);
    self.layer.borderWidth = _state.isRecordingAutomation ? 1.2 : 1.0;
    self.stripGradientLayer.colors = ({
        NSMutableArray *colors = [NSMutableArray array];
        for (NSColor *color in SKMixerStripGradientColors(_state)) {
            [colors addObject:(__bridge id)color.CGColor];
        }
        colors;
    });

    if (active && !_state.isDragging) {
        _slider.doubleValue = dbToSliderPos(_state.volumeDB, _state.minDB, _state.maxDB);
    }

    self.displayGradientLayer.colors = ({
        NSMutableArray *colors = [NSMutableArray array];
        for (NSColor *color in SKMixerDisplayGradientColors(_state, accentColor)) {
            [colors addObject:(__bridge id)color.CGColor];
        }
        colors;
    });
    self.displayCard.layer.borderColor = [accentColor colorWithAlphaComponent:(active ? 0.32 : 0.12)].CGColor;
    self.displayCard.layer.borderWidth = 1.0;

    self.indexLabel.textColor = displayTextColor;
    self.indexLabel.stringValue = _state.isMaster ? @"M" : [NSString stringWithFormat:@"%ld", (long)_state.index + 1];
    [self updateDBLabel];

    NSString *title = nil;
    if (_state.isMaster) title = active ? @"Master" : @"Output";
    else if (active && _state.role.length > 0) title = _state.role;
    else title = @"Unused";
    _roleLabel.stringValue = title;
    _roleLabel.textColor = active ? secondaryColor : [[NSColor whiteColor] colorWithAlphaComponent:0.24];

    NSString *clipName = active ? (_state.clipName.length > 0 ? _state.clipName : (_state.isMaster ? @"Playback" : @"")) : @"";
    _nameLabel.stringValue = clipName;
    _nameLabel.textColor = [[NSColor whiteColor] colorWithAlphaComponent:0.72];
    _clipTagView.hidden = (clipName.length == 0);

    NSString *symbolName = SKMixerSymbolNameForState(_state);
    if (@available(macOS 11.0, *)) {
        _iconView.image = [NSImage imageWithSystemSymbolName:symbolName accessibilityDescription:nil];
        _iconView.contentTintColor = [accentColor colorWithAlphaComponent:(active ? 0.92 : 0.28)];
    }

    NSArray<NSString *> *badgeTitles = @[
        @"ON",
        @"LIVE",
        SKMixerShowsClipping(_state) ? @"CLIP" : @"SIG"
    ];
    NSArray<NSNumber *> *badgeActive = @[
        @(active),
        @(playing),
        @(SKMixerShowsClipping(_state) || _state.meterPeak > 0.04)
    ];
    NSArray<NSColor *> *badgeColors = @[
        accentColor,
        [NSColor systemGreenColor],
        SKMixerShowsClipping(_state) ? [NSColor systemRedColor] : [NSColor systemTealColor]
    ];

    for (NSInteger idx = 0; idx < self.statusBadges.count; idx++) {
        NSView *badge = self.statusBadges[idx];
        NSTextField *label = self.statusBadgeLabels[idx];
        BOOL badgeOn = [badgeActive[idx] boolValue];
        NSColor *badgeColor = badgeColors[idx];
        label.stringValue = badgeTitles[idx];
        label.textColor = badgeOn ? [badgeColor colorWithAlphaComponent:0.98]
                                  : [[NSColor whiteColor] colorWithAlphaComponent:(active ? 0.58 : 0.24)];
        badge.layer.backgroundColor = [[NSColor whiteColor] colorWithAlphaComponent:(badgeOn ? 0.18 : 0.10)].CGColor;
        badge.layer.borderColor = [badgeOn ? [badgeColor colorWithAlphaComponent:0.90]
                                           : [[NSColor whiteColor] colorWithAlphaComponent:0.12] CGColor];
    }

    void (^configureBadgeButton)(SpliceKitMouseOnlyButton *, NSString *, BOOL, BOOL, NSColor *) =
        ^(SpliceKitMouseOnlyButton *button, NSString *title, BOOL highlighted, BOOL enabled, NSColor *color) {
            NSDictionary *attrs = @{
                NSFontAttributeName: [NSFont systemFontOfSize:(title.length > 3 ? 8.5 : 10.0) weight:NSFontWeightSemibold],
                NSForegroundColorAttributeName: highlighted
                    ? [color colorWithAlphaComponent:0.98]
                    : [[NSColor whiteColor] colorWithAlphaComponent:(enabled ? 0.58 : 0.24)]
            };
            button.attributedTitle = [[NSAttributedString alloc] initWithString:title attributes:attrs];
            button.enabled = enabled;
            button.layer.backgroundColor = [[NSColor whiteColor] colorWithAlphaComponent:(highlighted ? 0.18 : 0.10)].CGColor;
            button.layer.borderColor = [highlighted
                ? [color colorWithAlphaComponent:0.90]
                : [[NSColor whiteColor] colorWithAlphaComponent:0.12] CGColor];
            button.alphaValue = (_state.isMaster || active) ? 1.0 : 0.72;
        };

    BOOL roleControlEnabled = !_state.isMaster && active;
    configureBadgeButton(self.muteBadgeButton,
                         _state.isMuteMixed ? @"MIX" : @"MUTE",
                         (_state.isMuted || _state.isMuteMixed),
                         roleControlEnabled,
                         [NSColor systemOrangeColor]);
    configureBadgeButton(self.soloBadgeButton,
                         @"SOLO",
                         _state.isSoloed,
                         roleControlEnabled,
                         [NSColor systemYellowColor]);
    configureBadgeButton(self.armBadgeButton,
                         _state.isMaster ? @"OUT" : @"ARM",
                         _state.isMaster ? active : (_state.isAutomationArmed || _state.isRecordingAutomation),
                         roleControlEnabled,
                         _state.isMaster ? [NSColor systemOrangeColor] : [NSColor systemRedColor]);

    BOOL hasSharedBus = ![_state.busKind isEqualToString:@"none"] && _state.busObjectCount > 0;
    NSString *effectTitle = nil;
    if (_state.busEffectCount <= 0) {
        effectTitle = @"FX";
    } else if (_state.busEffectNames.count == 1) {
        effectTitle = _state.busEffectNames.firstObject;
    } else {
        NSString *firstName = _state.busEffectNames.firstObject ?: @"FX";
        if (firstName.length > 6) firstName = [[firstName substringToIndex:6] stringByAppendingString:@"..."];
        effectTitle = [NSString stringWithFormat:@"%@ +%ld", firstName, (long)MAX(0, _state.busEffectCount - 1)];
    }
    configureBadgeButton(self.effectButton,
                         effectTitle,
                         _state.busEffectCount > 0,
                         roleControlEnabled && hasSharedBus,
                         [NSColor systemBlueColor]);
    if (hasSharedBus && _state.busEffectNames.count > 0) {
        self.effectButton.toolTip = [_state.busEffectNames componentsJoinedByString:@", "];
    } else {
        self.effectButton.toolTip = hasSharedBus
            ? @"Add an audio effect to this shared mixer bus"
            : @"This fader has no shared audio bus";
    }

    self.trackView.layer.backgroundColor = [SKMixerColor(0.10, 0.10, 0.12) colorWithAlphaComponent:(active ? 0.85 : 0.40)].CGColor;
    self.fillView.layer.backgroundColor = [accentColor colorWithAlphaComponent:(signalEnabled ? (playing ? 0.88 : 0.46) : (active ? 0.22 : 0.18))].CGColor;
    self.knobGradientLayer.colors = active
        ? @[
            (__bridge id)[NSColor colorWithSRGBRed:0.86 green:0.86 blue:0.90 alpha:1.0].CGColor,
            (__bridge id)[NSColor colorWithSRGBRed:0.72 green:0.72 blue:0.76 alpha:1.0].CGColor,
            (__bridge id)[NSColor colorWithSRGBRed:0.42 green:0.42 blue:0.46 alpha:1.0].CGColor
        ]
        : @[
            (__bridge id)[NSColor colorWithSRGBRed:0.54 green:0.54 blue:0.58 alpha:0.42].CGColor,
            (__bridge id)[NSColor colorWithSRGBRed:0.40 green:0.40 blue:0.44 alpha:0.36].CGColor,
            (__bridge id)[NSColor colorWithSRGBRed:0.25 green:0.25 blue:0.29 alpha:0.30].CGColor
        ];
    self.knobView.layer.borderWidth = 1.0;
    self.knobView.layer.borderColor = [[NSColor whiteColor] colorWithAlphaComponent:(active ? 0.4 : 0.12)].CGColor;
    self.knobAccentView.layer.backgroundColor = [accentColor colorWithAlphaComponent:(signalEnabled ? (playing ? 0.92 : 0.80) : 0.30)].CGColor;
    self.knobView.alphaValue = signalEnabled ? 1.0 : (active ? 0.68 : 0.55);

    BOOL clipped = active ? SKMixerShowsClipping(_state) : NO;
    double peak = signalEnabled ? _state.meterPeak : 0.0;
    for (NSInteger idx = 0; idx < self.meterSegments.count; idx++) {
        NSView *segment = self.meterSegments[idx];
        double threshold = (idx + 1) / 34.0;
        if (peak >= threshold) {
            if (clipped) {
                segment.layer.backgroundColor = [SKMixerColor(0.96, 0.33, 0.29) CGColor];
            } else if (threshold > 0.82) {
                segment.layer.backgroundColor = [SKMixerColor(0.96, 0.45, 0.35) CGColor];
            } else if (threshold > 0.58) {
                segment.layer.backgroundColor = [SKMixerColor(0.98, 0.83, 0.38) CGColor];
            } else {
                segment.layer.backgroundColor = [[accentColor colorWithAlphaComponent:(playing ? 0.88 : 0.42)] CGColor];
            }
        } else {
            segment.layer.backgroundColor = [[NSColor whiteColor] colorWithAlphaComponent:(active ? 0.08 : 0.04)].CGColor;
        }
    }

    if (clipped) {
        self.meterContainer.layer.borderColor = [[NSColor systemRedColor] colorWithAlphaComponent:0.92].CGColor;
        self.knobView.layer.shadowColor = [NSColor systemRedColor].CGColor;
    } else {
        self.meterContainer.layer.borderColor = [[NSColor whiteColor] colorWithAlphaComponent:0.08].CGColor;
        self.knobView.layer.shadowColor = [[NSColor blackColor] colorWithAlphaComponent:0.55].CGColor;
    }

    [self setNeedsLayout:YES];
}

- (void)updateDBLabel {
    if (!_state.isActive) {
        _dbLabel.stringValue = @"--";
        _dbLabel.textColor = [[NSColor whiteColor] colorWithAlphaComponent:0.18];
        return;
    }
    if (_state.volumeDB <= _state.minDB) {
        _dbLabel.stringValue = @"-inf dB";
    } else {
        _dbLabel.stringValue = [NSString stringWithFormat:@"%.1f dB", _state.volumeDB];
    }
    NSColor *accent = SKMixerAccentForState(_state);
    BOOL outputMuted = !_state.isMaster && (_state.isMuted || _state.isSoloMuted);
    _dbLabel.textColor = _state.isActive
        ? [accent colorWithAlphaComponent:(outputMuted ? 0.44 : 0.88)]
        : [[NSColor whiteColor] colorWithAlphaComponent:0.18];
}

@end

#pragma mark - Mixer Panel

@interface SpliceKitMixerPanel : NSObject <NSWindowDelegate>
@property (nonatomic, strong) NSPanel *panel;
@property (nonatomic, strong) SpliceKitFaderView *masterFaderView;
@property (nonatomic, strong) NSMutableArray<SpliceKitFaderView *> *faderViews;
@property (nonatomic, strong) NSTimer *pollTimer;
@property (nonatomic, assign) BOOL isPolling;
@property (nonatomic, assign) BOOL transportPlaying;
@property (nonatomic, assign) BOOL meteringLive;
@property (nonatomic, assign) double playheadSeconds;
@property (nonatomic, assign) double frameRate;
@property (nonatomic, strong) NSDictionary *lastServerDebug;
@property (nonatomic, strong) NSArray<NSDictionary *> *audioEffectCache;
+ (instancetype)sharedPanel;
- (void)showPanel;
- (void)hidePanel;
- (BOOL)isVisible;
- (void)beginMasterVolumeChange;
- (void)setMasterVolumeDB:(double)db;
- (void)endMasterVolumeChange;
- (void)toggleSoloForFaderIndex:(NSInteger)faderIndex;
- (void)toggleMuteForFaderIndex:(NSInteger)faderIndex;
- (void)showAudioEffectsForFaderIndex:(NSInteger)faderIndex;
- (NSArray<NSDictionary *> *)availableAudioEffects;
- (void)addAudioEffectItems:(NSArray<NSDictionary *> *)effects
                     toMenu:(NSMenu *)menu
                 faderIndex:(NSInteger)faderIndex
                       role:(NSString *)role;
- (void)addCurrentBusEffectItemsForFader:(SpliceKitFaderView *)target toMenu:(NSMenu *)menu;
- (void)applyAudioEffectFromMenu:(NSMenuItem *)sender;
- (void)openAudioBusEffectFromMenu:(NSMenuItem *)sender;
- (void)toggleAudioBusEffectFromMenu:(NSMenuItem *)sender;
- (void)removeAudioBusEffectFromMenu:(NSMenuItem *)sender;
@end

@implementation SpliceKitMixerPanel

+ (instancetype)sharedPanel {
    static SpliceKitMixerPanel *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [[SpliceKitMixerPanel alloc] init]; });
    return instance;
}

- (void)showPanel {
    if (![NSThread isMainThread]) {
        SpliceKit_executeOnMainThread(^{ [self showPanel]; });
        return;
    }
    [self setupPanelIfNeeded];
    [self.panel makeKeyAndOrderFront:nil];
    [self startPolling];
}

- (void)hidePanel {
    if (![NSThread isMainThread]) {
        SpliceKit_executeOnMainThread(^{ [self hidePanel]; });
        return;
    }
    [self stopPolling];
    [self.panel orderOut:nil];
}

- (BOOL)isVisible {
    return self.panel && self.panel.isVisible;
}

- (void)windowWillClose:(NSNotification *)notification {
    [self stopPolling];
}

#pragma mark - Panel Setup

- (void)setupPanelIfNeeded {
    if (self.panel) return;

    NSRect frame = NSMakeRect(160, 140, 1360, 760);
    NSUInteger styleMask = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                           NSWindowStyleMaskResizable | NSWindowStyleMaskUtilityWindow;

    self.panel = [[NSPanel alloc] initWithContentRect:frame
                                            styleMask:styleMask
                                              backing:NSBackingStoreBuffered
                                                defer:NO];
    self.panel.title = @"Audio Mixer";
    self.panel.floatingPanel = YES;
    self.panel.becomesKeyOnlyIfNeeded = YES;
    self.panel.hidesOnDeactivate = NO;
    self.panel.level = NSFloatingWindowLevel;
    self.panel.minSize = NSMakeSize(1080, 700);
    self.panel.delegate = self;
    self.panel.releasedWhenClosed = NO;
    self.panel.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    self.panel.defaultButtonCell = nil;

    NSView *content = self.panel.contentView;
    content.wantsLayer = YES;
    content.layer.backgroundColor = [SKMixerColor(0.12, 0.12, 0.15) CGColor];
    CAGradientLayer *background = [CAGradientLayer layer];
    background.frame = content.bounds;
    background.autoresizingMask = kCALayerWidthSizable | kCALayerHeightSizable;
    background.colors = @[
        (__bridge id)SKMixerColor(0.22, 0.22, 0.24).CGColor,
        (__bridge id)SKMixerColor(0.16, 0.16, 0.18).CGColor
    ];
    background.startPoint = CGPointMake(0.5, 1.0);
    background.endPoint = CGPointMake(0.5, 0.0);
    [content.layer addSublayer:background];

    [self buildUI:content];
}

- (void)buildUI:(NSView *)content {
    NSStackView *mainStack = [[NSStackView alloc] init];
    mainStack.translatesAutoresizingMaskIntoConstraints = NO;
    mainStack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    mainStack.distribution = NSStackViewDistributionFill;
    mainStack.alignment = NSLayoutAttributeTop;
    mainStack.spacing = 6;
    [content addSubview:mainStack];

    self.masterFaderView = [[SpliceKitFaderView alloc] initWithFrame:NSMakeRect(0, 0, kSpliceKitMixerFaderWidth, 640) index:-1];
    __weak SpliceKitMixerPanel *weakSelf = self;
    self.masterFaderView.onDragStart = ^{
        [weakSelf beginMasterVolumeChange];
    };
    self.masterFaderView.onDragChange = ^(double db) {
        [weakSelf setMasterVolumeDB:db];
    };
    self.masterFaderView.onDragEnd = ^{
        [weakSelf endMasterVolumeChange];
    };
    [mainStack addArrangedSubview:self.masterFaderView];
    [[self.masterFaderView.widthAnchor constraintEqualToConstant:kSpliceKitMixerFaderWidth] setActive:YES];

    NSView *separator = [[NSView alloc] initWithFrame:NSZeroRect];
    separator.translatesAutoresizingMaskIntoConstraints = NO;
    separator.wantsLayer = YES;
    separator.layer.backgroundColor = [[NSColor whiteColor] colorWithAlphaComponent:0.08].CGColor;
    [mainStack addArrangedSubview:separator];
    [[separator.widthAnchor constraintEqualToConstant:1] setActive:YES];

    NSStackView *faderStack = [[NSStackView alloc] init];
    faderStack.translatesAutoresizingMaskIntoConstraints = NO;
    faderStack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    faderStack.distribution = NSStackViewDistributionFillEqually;
    faderStack.spacing = 1;
    [mainStack addArrangedSubview:faderStack];

    // Create enough faders for stress fixtures with many independent audio roles.
    self.faderViews = [NSMutableArray array];
    for (NSInteger i = 0; i < kSpliceKitMixerMaxFaders; i++) {
        SpliceKitFaderView *fv = [[SpliceKitFaderView alloc]
            initWithFrame:NSMakeRect(0, 0, kSpliceKitMixerFaderWidth, 640) index:i];

        NSInteger idx = i;
        fv.onDragStart = ^{
            [weakSelf beginVolumeChange:idx];
        };
        fv.onDragChange = ^(double db) {
            [weakSelf setVolume:idx db:db];
        };
        fv.onDragEnd = ^{
            [weakSelf endVolumeChange:idx];
        };
        fv.onToggleArm = ^{
            [weakSelf toggleAutomationArmForFaderIndex:idx];
        };
        fv.onToggleSolo = ^{
            [weakSelf toggleSoloForFaderIndex:idx];
        };
        fv.onToggleMute = ^{
            [weakSelf toggleMuteForFaderIndex:idx];
        };
        fv.onShowEffects = ^{
            [weakSelf showAudioEffectsForFaderIndex:idx];
        };

        [faderStack addArrangedSubview:fv];
        [self.faderViews addObject:fv];
        [[fv.widthAnchor constraintEqualToConstant:kSpliceKitMixerFaderWidth] setActive:YES];
    }

    // Layout — faders fill the whole window
    [NSLayoutConstraint activateConstraints:@[
        [mainStack.topAnchor constraintEqualToAnchor:content.topAnchor constant:12],
        [mainStack.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:12],
        [mainStack.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-12],
        [mainStack.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-12],
    ]];
}

#pragma mark - Polling

- (void)startPolling {
    [self stopPolling];
    self.isPolling = NO; // Reset re-entrancy guard
    self.pollTimer = [NSTimer timerWithTimeInterval:0.05
                                             target:self
                                           selector:@selector(pollTimerFired:)
                                           userInfo:nil
                                            repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.pollTimer forMode:NSRunLoopCommonModes];
}

- (void)stopPolling {
    self.isPolling = NO;
    [self.pollTimer invalidate];
    self.pollTimer = nil;
}

- (void)pollTimerFired:(NSTimer *)timer {
    if (!self.panel || !self.panel.isVisible) return;
    if (self.isPolling) return; // Guard against re-entrant calls
    self.isPolling = YES;
    @try {
        [self updateMixerState];
    } @catch (NSException *e) {
        SpliceKit_log(@"[Mixer] Poll exception: %@ - %@", e.name, e.reason);
        [self clearAllFaders];
        self.isPolling = NO;
    }
}

- (void)updateMixerState {
    extern NSDictionary *SpliceKit_handleMixerGetState(NSDictionary *params);
    NSDictionary *result = SpliceKit_handleMixerGetState(@{});
    [self applyMixerState:result];
}

- (void)applyMixerState:(NSDictionary *)result {
    self.isPolling = NO; // Allow next poll
    CFTimeInterval now = CFAbsoluteTimeGetCurrent();

    if (result[@"error"]) {
        self.transportPlaying = NO;
        self.meteringLive = NO;
        self.lastServerDebug = @{};
        [self clearAllFaders];
        return;
    }

    self.lastServerDebug = [result[@"debug"] isKindOfClass:[NSDictionary class]] ? result[@"debug"] : @{};
    self.transportPlaying = [result[@"isPlaying"] boolValue];
    self.meteringLive = [result[@"isMeteringLive"] boolValue];
    self.playheadSeconds = [result[@"playheadSeconds"] doubleValue];
    self.frameRate = [result[@"frameRate"] doubleValue];

    NSDictionary *masterInfo = [result[@"masterFader"] isKindOfClass:[NSDictionary class]] ? result[@"masterFader"] : nil;
    NSArray *faderData = result[@"faders"];

    BOOL masterDragging = self.masterFaderView.state.isDragging;
    if (masterInfo) {
        BOOL meterFlowing = self.transportPlaying || self.meteringLive;
        CFTimeInterval deltaTime = self.masterFaderView.state.lastMeterSampleTime > 0
            ? now - self.masterFaderView.state.lastMeterSampleTime
            : 0.05;
        double livePeak = [masterInfo[@"meterPeak"] doubleValue];
        self.masterFaderView.state.isActive = YES;
        self.masterFaderView.state.isAutomationArmed = NO;
        self.masterFaderView.state.isSoloed = NO;
        self.masterFaderView.state.isSoloMuted = NO;
        self.masterFaderView.state.isMuted = NO;
        self.masterFaderView.state.isMuteMixed = NO;
        self.masterFaderView.state.isPlaying = [masterInfo[@"playing"] boolValue];
        self.masterFaderView.state.clipName = masterInfo[@"name"] ?: @"Playback";
        self.masterFaderView.state.role = masterInfo[@"role"] ?: @"Master";
        self.masterFaderView.state.meterPeak =
            SKMixerDisplayedPeakForUpdate(self.masterFaderView.state.meterPeak, livePeak, meterFlowing, deltaTime);
        self.masterFaderView.state.meterLinear = [masterInfo[@"meterLinear"] doubleValue];
        self.masterFaderView.state.meterDB = [masterInfo[@"meterDB"] doubleValue];
        self.masterFaderView.state.lastMeterSampleTime = now;
        if (!meterFlowing) {
            self.masterFaderView.state.meterClipping = NO;
            self.masterFaderView.state.clipLatchedUntil = 0;
        } else if ([masterInfo[@"meterClipping"] boolValue]) {
            self.masterFaderView.state.meterClipping = YES;
            self.masterFaderView.state.clipLatchedUntil = now + 0.8;
        } else if (now >= self.masterFaderView.state.clipLatchedUntil) {
            self.masterFaderView.state.meterClipping = NO;
        }
        self.masterFaderView.state.minDB = [masterInfo[@"minDB"] doubleValue];
        self.masterFaderView.state.maxDB = [masterInfo[@"maxDB"] doubleValue];
        if (!masterDragging) {
            self.masterFaderView.state.volumeDB = [masterInfo[@"volumeDB"] doubleValue];
            self.masterFaderView.state.volumeLinear = [masterInfo[@"volumeLinear"] doubleValue];
        }
    } else {
        self.masterFaderView.state.isActive = NO;
        self.masterFaderView.state.isAutomationArmed = NO;
        self.masterFaderView.state.isSoloed = NO;
        self.masterFaderView.state.isSoloMuted = NO;
        self.masterFaderView.state.isMuted = NO;
        self.masterFaderView.state.isMuteMixed = NO;
        self.masterFaderView.state.isPlaying = NO;
        self.masterFaderView.state.clipName = nil;
        self.masterFaderView.state.role = @"Master";
        self.masterFaderView.state.meterPeak = 0;
        self.masterFaderView.state.meterLinear = 0;
        self.masterFaderView.state.meterDB = -INFINITY;
        self.masterFaderView.state.meterClipping = NO;
        self.masterFaderView.state.clipLatchedUntil = 0;
        self.masterFaderView.state.lastMeterSampleTime = 0;
        self.masterFaderView.state.minDB = -96.0;
        self.masterFaderView.state.maxDB = 0.0;
    }
    [self.masterFaderView updateFromState];

    for (NSInteger i = 0; i < (NSInteger)self.faderViews.count; i++) {
        SpliceKitFaderView *fv = self.faderViews[i];
        BOOL dragging = fv.state.isDragging;

        if (i < (NSInteger)faderData.count) {
            NSDictionary *info = faderData[i];
            BOOL meterFlowing = self.transportPlaying || self.meteringLive;
            CFTimeInterval deltaTime = fv.state.lastMeterSampleTime > 0 ? now - fv.state.lastMeterSampleTime : 0.05;
            double livePeak = [info[@"meterPeak"] doubleValue];
            fv.state.isActive = YES; // All role faders are always active
            fv.state.isSoloed = [info[@"soloed"] boolValue];
            fv.state.isSoloMuted = [info[@"soloMuted"] boolValue];
            fv.state.isMuted = [info[@"muted"] boolValue];
            fv.state.isMuteMixed = [info[@"muteMixed"] boolValue];
            fv.state.isPlaying = [info[@"playing"] boolValue]; // Playing = clip at playhead
            fv.state.clipName = info[@"name"] ?: @"";
            fv.state.lane = [info[@"lane"] integerValue];
            fv.state.clipHandle = info[@"clipHandle"];
            fv.state.volumeChannelHandle = info[@"volumeChannelHandle"];
            fv.state.audioEffectStackHandle = info[@"audioEffectStackHandle"];
            fv.state.effectStackHandle = info[@"effectStackHandle"];
            fv.state.busKind = info[@"busKind"];
            fv.state.busEffectStackHandle = info[@"busEffectStackHandle"];
            fv.state.busObjectCount = [info[@"busObjectCount"] integerValue];
            fv.state.busEffectCount = [info[@"busEffectCount"] integerValue];
            fv.state.busEffectNames = [info[@"busEffectNames"] isKindOfClass:[NSArray class]]
                ? info[@"busEffectNames"]
                : @[];
            fv.state.busEffects = [info[@"busEffects"] isKindOfClass:[NSArray class]]
                ? info[@"busEffects"]
                : @[];
            fv.state.role = info[@"role"];
            fv.state.roleColorHex = info[@"roleColor"];
            fv.state.meterDB = [info[@"meterDB"] doubleValue];
            fv.state.meterLinear = [info[@"meterLinear"] doubleValue];
            fv.state.meterPeak = SKMixerDisplayedPeakForUpdate(fv.state.meterPeak, livePeak, meterFlowing, deltaTime);
            fv.state.lastMeterSampleTime = now;
            if (!meterFlowing) {
                fv.state.meterClipping = NO;
                fv.state.clipLatchedUntil = 0;
            } else if ([info[@"meterClipping"] boolValue]) {
                fv.state.meterClipping = YES;
                fv.state.clipLatchedUntil = now + 0.8;
            } else if (now >= fv.state.clipLatchedUntil) {
                fv.state.meterClipping = NO;
            }
            if (!dragging) {
                fv.state.volumeDB = [info[@"volumeDB"] doubleValue];
                fv.state.volumeLinear = [info[@"volumeLinear"] doubleValue];
            }
        } else {
            fv.state.isActive = NO;
            fv.state.isAutomationArmed = NO;
            fv.state.isSoloed = NO;
            fv.state.isSoloMuted = NO;
            fv.state.isMuted = NO;
            fv.state.isMuteMixed = NO;
            fv.state.isPlaying = NO;
            fv.state.isRecordingAutomation = NO;
            fv.state.clipName = nil;
            fv.state.clipHandle = nil;
            fv.state.volumeChannelHandle = nil;
            fv.state.audioEffectStackHandle = nil;
            fv.state.effectStackHandle = nil;
            fv.state.busKind = nil;
            fv.state.busEffectStackHandle = nil;
            fv.state.busEffectNames = @[];
            fv.state.busEffects = @[];
            fv.state.busObjectCount = 0;
            fv.state.busEffectCount = 0;
            fv.state.role = nil;
            fv.state.meterDB = -INFINITY;
            fv.state.meterLinear = 0;
            fv.state.meterPeak = 0;
            fv.state.meterClipping = NO;
            fv.state.clipLatchedUntil = 0;
            fv.state.lastMeterSampleTime = 0;
        }
        [fv updateFromState];
    }

    [self recordAutomationSamplesIfNeeded];
    [self updateAutomationUI];
}

- (void)clearAllFaders {
    self.masterFaderView.state.isActive = NO;
    self.masterFaderView.state.isAutomationArmed = NO;
    self.masterFaderView.state.isSoloed = NO;
    self.masterFaderView.state.isSoloMuted = NO;
    self.masterFaderView.state.isMuted = NO;
    self.masterFaderView.state.isMuteMixed = NO;
    self.masterFaderView.state.isPlaying = NO;
    self.masterFaderView.state.isDragging = NO;
    self.masterFaderView.state.clipName = nil;
    self.masterFaderView.state.role = @"Master";
    self.masterFaderView.state.meterPeak = 0;
    self.masterFaderView.state.meterLinear = 0;
    self.masterFaderView.state.meterDB = -INFINITY;
    self.masterFaderView.state.meterClipping = NO;
    self.masterFaderView.state.clipLatchedUntil = 0;
    self.masterFaderView.state.lastMeterSampleTime = 0;
    self.masterFaderView.state.minDB = -96.0;
    self.masterFaderView.state.maxDB = 0.0;
    [self.masterFaderView updateFromState];

    for (SpliceKitFaderView *fv in self.faderViews) {
        [self finishUndoTransactionsForFader:fv];
        fv.state.isActive = NO;
        fv.state.isAutomationArmed = NO;
        fv.state.isSoloed = NO;
        fv.state.isSoloMuted = NO;
        fv.state.isMuted = NO;
        fv.state.isMuteMixed = NO;
        fv.state.isPlaying = NO;
        fv.state.isRecordingAutomation = NO;
        fv.state.clipName = nil;
        fv.state.clipHandle = nil;
        fv.state.volumeChannelHandle = nil;
        fv.state.audioEffectStackHandle = nil;
        fv.state.effectStackHandle = nil;
        fv.state.busKind = nil;
        fv.state.busEffectStackHandle = nil;
        fv.state.busEffectNames = @[];
        fv.state.busEffects = @[];
        fv.state.busObjectCount = 0;
        fv.state.busEffectCount = 0;
        fv.state.meterDB = -INFINITY;
        fv.state.meterLinear = 0;
        fv.state.meterPeak = 0;
        fv.state.meterClipping = NO;
        fv.state.clipLatchedUntil = 0;
        fv.state.lastMeterSampleTime = 0;
        [fv updateFromState];
    }
    [self updateAutomationUI];
}

- (BOOL)isTransportPlayingNow {
    BOOL playing = self.transportPlaying;
    @try {
        id timeline = SpliceKit_getActiveTimelineModule();
        SEL isPlayingSel = NSSelectorFromString(@"isPlaying");
        if (timeline && [timeline respondsToSelector:isPlayingSel]) {
            playing = ((BOOL (*)(id, SEL))objc_msgSend)(timeline, isPlayingSel);
        }
    } @catch (NSException *e) {}
    self.transportPlaying = playing;
    return playing;
}

- (BOOL)anyFaderRecordingAutomation {
    for (SpliceKitFaderView *fv in self.faderViews) {
        if (fv.state.isRecordingAutomation) return YES;
    }
    return NO;
}

- (BOOL)anyFaderArmedForAutomation {
    for (SpliceKitFaderView *fv in self.faderViews) {
        if (fv.state.isAutomationArmed) return YES;
    }
    return NO;
}

- (void)updateAutomationUI {
    for (SpliceKitFaderView *fv in self.faderViews) {
        [fv updateFromState];
    }
}

- (void)toggleAutomationArmForFaderIndex:(NSInteger)faderIndex {
    if (faderIndex < 0 || faderIndex >= (NSInteger)self.faderViews.count) return;

    SpliceKitFaderView *target = self.faderViews[faderIndex];
    if (!target.state.isActive) return;

    BOOL shouldArm = !target.state.isAutomationArmed;
    for (SpliceKitFaderView *fv in self.faderViews) {
        fv.state.isAutomationArmed = NO;
        if (!fv.state.isRecordingAutomation) {
            [fv updateFromState];
        }
    }
    target.state.isAutomationArmed = shouldArm;
    [target updateFromState];
    [self updateAutomationUI];
}

- (void)toggleSoloForFaderIndex:(NSInteger)faderIndex {
    if (faderIndex < 0 || faderIndex >= (NSInteger)self.faderViews.count) return;
    SpliceKitFaderView *target = self.faderViews[faderIndex];
    if (!target.state.isActive) return;

    extern NSDictionary *SpliceKit_handleMixerSetSolo(NSDictionary *params);
    NSDictionary *result = SpliceKit_handleMixerSetSolo(@{
        @"index": @(faderIndex),
        @"mode": @"toggle"
    });
    if (result[@"error"]) {
        SpliceKit_log(@"[Mixer] Solo failed: %@", result[@"error"]);
        return;
    }
    [self updateMixerState];
}

- (void)toggleMuteForFaderIndex:(NSInteger)faderIndex {
    if (faderIndex < 0 || faderIndex >= (NSInteger)self.faderViews.count) return;
    SpliceKitFaderView *target = self.faderViews[faderIndex];
    if (!target.state.isActive) return;

    extern NSDictionary *SpliceKit_handleMixerSetMute(NSDictionary *params);
    NSDictionary *result = SpliceKit_handleMixerSetMute(@{
        @"index": @(faderIndex),
        @"mode": @"toggle"
    });
    if (result[@"error"]) {
        SpliceKit_log(@"[Mixer] Mute failed: %@", result[@"error"]);
        return;
    }
    [self updateMixerState];
}

- (NSArray<NSDictionary *> *)availableAudioEffects {
    if (self.audioEffectCache.count > 0) return self.audioEffectCache;

    NSDictionary *result = SpliceKit_handleEffectsListAvailable(@{@"type": @"audio"});
    if (result[@"error"]) {
        SpliceKit_log(@"[Mixer] Audio effect list failed: %@", result[@"error"]);
        self.audioEffectCache = @[];
        return self.audioEffectCache;
    }

    NSArray *effects = [result[@"effects"] isKindOfClass:[NSArray class]] ? result[@"effects"] : @[];
    self.audioEffectCache = effects;
    return self.audioEffectCache;
}

- (void)addAudioEffectItems:(NSArray<NSDictionary *> *)effects
                     toMenu:(NSMenu *)menu
                 faderIndex:(NSInteger)faderIndex
                       role:(NSString *)role {
    for (NSDictionary *effect in effects) {
        NSString *name = [effect[@"name"] isKindOfClass:[NSString class]] ? effect[@"name"] : @"Unknown";
        NSString *effectID = [effect[@"effectID"] isKindOfClass:[NSString class]] ? effect[@"effectID"] : @"";
        if (effectID.length == 0) continue;

        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:name
                                                      action:@selector(applyAudioEffectFromMenu:)
                                               keyEquivalent:@""];
        item.target = self;
        item.representedObject = @{
            @"index": @(faderIndex),
            @"role": role ?: @"",
            @"effectID": effectID,
            @"name": name,
        };
        [menu addItem:item];
    }
}

- (void)addCurrentBusEffectItemsForFader:(SpliceKitFaderView *)target toMenu:(NSMenu *)menu {
    if (target.state.busEffects.count == 0) return;

    NSMenuItem *heading = [[NSMenuItem alloc] initWithTitle:@"Current Effects" action:nil keyEquivalent:@""];
    heading.enabled = NO;
    [menu addItem:heading];

    for (NSDictionary *effect in target.state.busEffects) {
        NSNumber *effectIndex = [effect[@"index"] isKindOfClass:[NSNumber class]] ? effect[@"index"] : nil;
        if (!effectIndex) continue;

        NSString *name = [effect[@"name"] isKindOfClass:[NSString class]] ? effect[@"name"] : @"Effect";
        BOOL enabled = ![effect[@"enabled"] isKindOfClass:[NSNumber class]] || [effect[@"enabled"] boolValue];
        NSString *title = enabled ? name : [NSString stringWithFormat:@"%@ (off)", name];
        NSString *targetName = [effect[@"targetName"] isKindOfClass:[NSString class]] ? effect[@"targetName"] : @"";
        if (target.state.busObjectCount > 1 && targetName.length > 0) {
            title = [NSString stringWithFormat:@"%@ - %@", title, targetName];
        }

        NSMenuItem *effectItem = [[NSMenuItem alloc] initWithTitle:title action:nil keyEquivalent:@""];
        NSMenu *effectMenu = [[NSMenu alloc] initWithTitle:title];
        effectMenu.autoenablesItems = NO;
        NSMutableDictionary *payload = [@{
            @"index": @(target.state.index),
            @"role": target.state.role ?: @"",
            @"effectIndex": effectIndex,
            @"name": name,
            @"enabled": @(enabled),
        } mutableCopy];
        NSString *busEffectID = [effect[@"busEffectID"] isKindOfClass:[NSString class]] ? effect[@"busEffectID"] : @"";
        NSString *effectHandle = [effect[@"handle"] isKindOfClass:[NSString class]] ? effect[@"handle"] : @"";
        NSString *effectStackHandle = [effect[@"effectStackHandle"] isKindOfClass:[NSString class]] ? effect[@"effectStackHandle"] : @"";
        if (busEffectID.length > 0) payload[@"busEffectID"] = busEffectID;
        if (effectHandle.length > 0) payload[@"effectHandle"] = effectHandle;
        if (effectStackHandle.length > 0) payload[@"effectStackHandle"] = effectStackHandle;

        NSMenuItem *openItem = [[NSMenuItem alloc] initWithTitle:@"Open Editor"
                                                          action:@selector(openAudioBusEffectFromMenu:)
                                                   keyEquivalent:@""];
        openItem.target = self;
        openItem.representedObject = payload;
        [effectMenu addItem:openItem];

        NSMenuItem *toggleItem = [[NSMenuItem alloc] initWithTitle:(enabled ? @"Disable" : @"Enable")
                                                            action:@selector(toggleAudioBusEffectFromMenu:)
                                                     keyEquivalent:@""];
        toggleItem.target = self;
        toggleItem.representedObject = payload;
        [effectMenu addItem:toggleItem];

        [effectMenu addItem:[NSMenuItem separatorItem]];
        NSMenuItem *removeItem = [[NSMenuItem alloc] initWithTitle:@"Remove"
                                                            action:@selector(removeAudioBusEffectFromMenu:)
                                                     keyEquivalent:@""];
        removeItem.target = self;
        removeItem.representedObject = payload;
        [effectMenu addItem:removeItem];

        effectItem.submenu = effectMenu;
        [menu addItem:effectItem];
    }
    [menu addItem:[NSMenuItem separatorItem]];
}

- (void)showAudioEffectsForFaderIndex:(NSInteger)faderIndex {
    if (faderIndex < 0 || faderIndex >= (NSInteger)self.faderViews.count) return;
    SpliceKitFaderView *target = self.faderViews[faderIndex];
    if (!target.state.isActive || target.state.isMaster) return;

    NSString *role = target.state.role ?: @"";
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Audio Effects"];
    menu.autoenablesItems = NO;

    BOOL hasSharedBus = ![target.state.busKind isEqualToString:@"none"] && target.state.busObjectCount > 0;
    if (!hasSharedBus) {
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:@"No shared bus available for this fader"
                                                      action:nil
                                               keyEquivalent:@""];
        item.enabled = NO;
        [menu addItem:item];
    } else {
        [self addCurrentBusEffectItemsForFader:target toMenu:menu];

        NSArray<NSDictionary *> *effects = [self availableAudioEffects];
        if (effects.count == 0) {
            NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:@"No audio effects found"
                                                          action:nil
                                                   keyEquivalent:@""];
            item.enabled = NO;
            [menu addItem:item];
        } else {
            NSMutableDictionary<NSString *, NSMutableArray<NSDictionary *> *> *effectsByCategory = [NSMutableDictionary dictionary];
            for (NSDictionary *effect in effects) {
                NSString *category = [effect[@"category"] isKindOfClass:[NSString class]] ? effect[@"category"] : @"";
                if (category.length == 0) category = @"Audio";
                NSMutableArray *bucket = effectsByCategory[category];
                if (!bucket) {
                    bucket = [NSMutableArray array];
                    effectsByCategory[category] = bucket;
                }
                [bucket addObject:effect];
            }

            NSArray<NSString *> *categories = [[effectsByCategory allKeys] sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
            if (categories.count <= 1) {
                [self addAudioEffectItems:effects toMenu:menu faderIndex:faderIndex role:role];
            } else {
                NSMenuItem *addItem = [[NSMenuItem alloc] initWithTitle:@"Add Audio Effect" action:nil keyEquivalent:@""];
                NSMenu *addMenu = [[NSMenu alloc] initWithTitle:@"Add Audio Effect"];
                addMenu.autoenablesItems = NO;
                for (NSString *category in categories) {
                    NSArray<NSDictionary *> *categoryEffects = effectsByCategory[category];
                    NSMenuItem *categoryItem = [[NSMenuItem alloc] initWithTitle:category action:nil keyEquivalent:@""];
                    NSMenu *submenu = [[NSMenu alloc] initWithTitle:category];
                    submenu.autoenablesItems = NO;
                    [self addAudioEffectItems:categoryEffects toMenu:submenu faderIndex:faderIndex role:role];
                    categoryItem.submenu = submenu;
                    [addMenu addItem:categoryItem];
                }
                addItem.submenu = addMenu;
                [menu addItem:addItem];
            }
        }
    }

    [menu popUpMenuPositioningItem:nil
                        atLocation:NSMakePoint(0, NSHeight(target.effectButton.bounds) + 2.0)
                            inView:target.effectButton];
}

- (void)applyAudioEffectFromMenu:(NSMenuItem *)sender {
    NSDictionary *payload = [sender.representedObject isKindOfClass:[NSDictionary class]]
        ? sender.representedObject
        : nil;
    NSString *effectID = [payload[@"effectID"] isKindOfClass:[NSString class]] ? payload[@"effectID"] : @"";
    NSString *role = [payload[@"role"] isKindOfClass:[NSString class]] ? payload[@"role"] : @"";
    NSNumber *indexNumber = [payload[@"index"] isKindOfClass:[NSNumber class]] ? payload[@"index"] : nil;
    if (effectID.length == 0 || (role.length == 0 && !indexNumber)) return;

    NSMutableDictionary *params = [@{@"effectID": effectID} mutableCopy];
    if (role.length > 0) {
        params[@"role"] = role;
    } else if (indexNumber) {
        params[@"index"] = indexNumber;
    }

    NSDictionary *result = SpliceKit_handleMixerApplyBusEffect(params);
    if (result[@"error"]) {
        SpliceKit_log(@"[Mixer] Add audio bus effect failed: %@", result[@"error"]);
        NSBeep();
        return;
    }

    SpliceKit_log(@"[Mixer] Added audio bus effect %@ to %@",
                  payload[@"name"] ?: effectID,
                  role.length > 0 ? role : [NSString stringWithFormat:@"fader %@", indexNumber]);
    [self updateMixerState];
}

- (NSMutableDictionary *)busEffectParamsFromMenuPayload:(NSDictionary *)payload {
    NSString *role = [payload[@"role"] isKindOfClass:[NSString class]] ? payload[@"role"] : @"";
    NSNumber *indexNumber = [payload[@"index"] isKindOfClass:[NSNumber class]] ? payload[@"index"] : nil;
    NSNumber *effectIndex = [payload[@"effectIndex"] isKindOfClass:[NSNumber class]] ? payload[@"effectIndex"] : nil;
    NSString *busEffectID = [payload[@"busEffectID"] isKindOfClass:[NSString class]] ? payload[@"busEffectID"] : @"";
    NSString *effectHandle = [payload[@"effectHandle"] isKindOfClass:[NSString class]] ? payload[@"effectHandle"] : @"";
    NSString *effectStackHandle = [payload[@"effectStackHandle"] isKindOfClass:[NSString class]] ? payload[@"effectStackHandle"] : @"";
    if (!effectIndex && effectHandle.length == 0 && busEffectID.length == 0) return nil;
    if (effectHandle.length == 0 && busEffectID.length == 0 && role.length == 0 && !indexNumber) return nil;

    NSMutableDictionary *params = [NSMutableDictionary dictionary];
    if (effectIndex) params[@"effectIndex"] = effectIndex;
    if (busEffectID.length > 0) params[@"busEffectID"] = busEffectID;
    if (effectHandle.length > 0) params[@"effectHandle"] = effectHandle;
    if (effectStackHandle.length > 0) params[@"effectStackHandle"] = effectStackHandle;
    if (role.length > 0) {
        params[@"role"] = role;
    } else if (indexNumber) {
        params[@"index"] = indexNumber;
    }
    return params;
}

- (void)openAudioBusEffectFromMenu:(NSMenuItem *)sender {
    NSDictionary *payload = [sender.representedObject isKindOfClass:[NSDictionary class]]
        ? sender.representedObject
        : nil;
    NSMutableDictionary *params = [self busEffectParamsFromMenuPayload:payload];
    if (!params) return;

    NSDictionary *result = SpliceKit_handleMixerOpenBusEffect(params);
    if (result[@"error"]) {
        SpliceKit_log(@"[Mixer] Open audio bus effect failed: %@", result[@"error"]);
        NSBeep();
    }
}

- (void)toggleAudioBusEffectFromMenu:(NSMenuItem *)sender {
    NSDictionary *payload = [sender.representedObject isKindOfClass:[NSDictionary class]]
        ? sender.representedObject
        : nil;
    NSMutableDictionary *params = [self busEffectParamsFromMenuPayload:payload];
    if (!params) return;

    BOOL enabled = ![payload[@"enabled"] boolValue];
    params[@"enabled"] = @(enabled);
    NSDictionary *result = SpliceKit_handleMixerSetBusEffectEnabled(params);
    if (result[@"error"]) {
        SpliceKit_log(@"[Mixer] Toggle audio bus effect failed: %@", result[@"error"]);
        NSBeep();
        return;
    }
    [self updateMixerState];
}

- (void)removeAudioBusEffectFromMenu:(NSMenuItem *)sender {
    NSDictionary *payload = [sender.representedObject isKindOfClass:[NSDictionary class]]
        ? sender.representedObject
        : nil;
    NSMutableDictionary *params = [self busEffectParamsFromMenuPayload:payload];
    if (!params) return;

    NSDictionary *result = SpliceKit_handleMixerRemoveBusEffect(params);
    if (result[@"error"]) {
        SpliceKit_log(@"[Mixer] Remove audio bus effect failed: %@", result[@"error"]);
        NSBeep();
        return;
    }
    [self updateMixerState];
}

- (NSString *)currentUndoEffectStackHandleForFader:(SpliceKitFaderView *)fv {
    return fv.state.effectStackHandle ?: fv.state.audioEffectStackHandle;
}

- (void)notifyEffectsChangedForFader:(SpliceKitFaderView *)fv {
    NSString *effectStackHandle = [self currentUndoEffectStackHandleForFader:fv];
    if (!effectStackHandle) return;

    id effectStack = SpliceKit_resolveHandle(effectStackHandle);
    if (!effectStack) return;

    @try {
        SEL notifySel = NSSelectorFromString(@"postEffectsChangedNotification");
        if ([effectStack respondsToSelector:notifySel]) {
            ((void (*)(id, SEL))objc_msgSend)(effectStack, notifySel);
        }
    } @catch (NSException *e) {}
}

- (void)resetDragSessionForFader:(SpliceKitFaderView *)fv {
    fv.state.isRecordingAutomation = NO;
    fv.state.didRecordAutomationInDrag = NO;
    fv.state.didPrepareAutomationInDrag = NO;
    fv.state.lastAutomationPlayheadSeconds = -DBL_MAX;
    fv.state.lastAutomationLinear = NAN;
    if (!fv.state.openEffectStackHandlesByPointer) {
        fv.state.openEffectStackHandlesByPointer = [NSMutableDictionary dictionary];
    } else {
        [fv.state.openEffectStackHandlesByPointer removeAllObjects];
    }
}

- (void)ensureUndoTransactionForFader:(SpliceKitFaderView *)fv effectStackHandle:(NSString *)effectStackHandle {
    if (!effectStackHandle) return;

    id effectStack = SpliceKit_resolveHandle(effectStackHandle);
    if (!effectStack) return;

    if (!fv.state.openEffectStackHandlesByPointer) {
        fv.state.openEffectStackHandlesByPointer = [NSMutableDictionary dictionary];
    }

    NSString *pointerKey = [NSString stringWithFormat:@"%p", (__bridge void *)effectStack];
    if (fv.state.openEffectStackHandlesByPointer[pointerKey]) return;

    @try {
        SEL beginSel = NSSelectorFromString(@"actionBegin:animationHint:deferUpdates:");
        if ([effectStack respondsToSelector:beginSel]) {
            ((void (*)(id, SEL, id, id, BOOL))objc_msgSend)(
                effectStack, beginSel, @"Adjust Volume", nil, NO);
        }
    } @catch (NSException *e) {}

    fv.state.openEffectStackHandlesByPointer[pointerKey] = effectStackHandle;
}

- (void)finishUndoTransactionsForFader:(SpliceKitFaderView *)fv {
    NSArray<NSString *> *handles = [fv.state.openEffectStackHandlesByPointer allValues];
    for (NSString *effectStackHandle in handles) {
        id effectStack = SpliceKit_resolveHandle(effectStackHandle);
        if (!effectStack) continue;

        @try {
            SEL endSel = NSSelectorFromString(@"actionEnd:save:error:");
            if ([effectStack respondsToSelector:endSel]) {
                ((void (*)(id, SEL, id, BOOL, id))objc_msgSend)(
                    effectStack, endSel, @"Adjust Volume", YES, nil);
            }
        } @catch (NSException *e) {}
    }
    [fv.state.openEffectStackHandlesByPointer removeAllObjects];
}

- (BOOL)recordAutomationSampleForFader:(SpliceKitFaderView *)fv force:(BOOL)force {
    if (!fv.state.isAutomationArmed) return NO;
    if (!fv.state.isDragging || !self.transportPlaying || !fv.state.isPlaying) return NO;
    if (!fv.state.clipHandle || !fv.state.volumeChannelHandle) return NO;

    double linear = fv.state.volumeLinear;
    if (linear < 0.0) linear = 0.0;
    if (linear > 3.98) linear = 3.98;

    if (!force && fabs(self.playheadSeconds - fv.state.lastAutomationPlayheadSeconds) < 0.0005) {
        return NO;
    }

    id clip = SpliceKit_resolveHandle(fv.state.clipHandle);
    id channel = SpliceKit_resolveHandle(fv.state.volumeChannelHandle);
    if (!clip || !channel) return NO;

    if (!fv.state.didPrepareAutomationInDrag) {
        // Treat a fresh drag as a replacement pass for this fader's automation.
        SpliceKit_removeChannelKeyframes(channel);
        fv.state.didPrepareAutomationInDrag = YES;
    }

    BOOL ok = SpliceKit_mixerWriteAutomationPoint(clip, channel, linear);
    if (ok) {
        fv.state.isRecordingAutomation = YES;
        fv.state.didRecordAutomationInDrag = YES;
        fv.state.lastAutomationPlayheadSeconds = self.playheadSeconds;
        fv.state.lastAutomationLinear = linear;
        [fv updateFromState];
        [self updateAutomationUI];
    }
    return ok;
}

- (void)recordAutomationSamplesIfNeeded {
    for (SpliceKitFaderView *fv in self.faderViews) {
        if (!fv.state.isDragging) continue;
        if (self.transportPlaying && fv.state.isAutomationArmed) {
            [self recordAutomationSampleForFader:fv force:NO];
        } else if (fv.state.isRecordingAutomation) {
            fv.state.isRecordingAutomation = NO;
            [fv updateFromState];
        }
    }
    [self updateAutomationUI];
}

#pragma mark - Debug

- (NSDictionary *)debugState {
    NSMutableArray *faderStates = [NSMutableArray array];
    for (SpliceKitFaderView *fv in self.faderViews) {
        [faderStates addObject:@{
            @"index": @(fv.state.index),
            @"active": @(fv.state.isActive),
            @"armed": @(fv.state.isAutomationArmed),
            @"soloed": @(fv.state.isSoloed),
            @"soloMuted": @(fv.state.isSoloMuted),
            @"muted": @(fv.state.isMuted),
            @"muteMixed": @(fv.state.isMuteMixed),
            @"playing": @(fv.state.isPlaying),
            @"dragging": @(fv.state.isDragging),
            @"recordingAutomation": @(fv.state.isRecordingAutomation),
            @"name": fv.state.clipName ?: @"",
            @"role": fv.state.role ?: @"",
            @"lane": @(fv.state.lane),
            @"volumeDB": @(fv.state.volumeDB),
            @"clipHandle": fv.state.clipHandle ?: @"",
            @"volHandle": fv.state.volumeChannelHandle ?: @"",
            @"sliderValue": @(fv.slider.doubleValue),
        }];
    }
    NSDictionary *masterState = self.masterFaderView ? @{
        @"active": @(self.masterFaderView.state.isActive),
        @"playing": @(self.masterFaderView.state.isPlaying),
        @"dragging": @(self.masterFaderView.state.isDragging),
        @"name": self.masterFaderView.state.clipName ?: @"",
        @"volumeDB": @(self.masterFaderView.state.volumeDB),
        @"sliderValue": @(self.masterFaderView.slider.doubleValue),
    } : @{};
    return @{
        @"panelVisible": @(self.panel.isVisible),
        @"isPolling": @(self.isPolling),
        @"timerValid": @(self.pollTimer.isValid),
        @"panelBuildStamp": [NSString stringWithFormat:@"%s %s", __DATE__, __TIME__],
        @"transportPlaying": @(self.transportPlaying),
        @"meteringLive": @(self.meteringLive),
        @"playheadSeconds": @(self.playheadSeconds),
        @"serverDebug": self.lastServerDebug ?: @{},
        @"master": masterState,
        @"faders": faderStates,
    };
}

#pragma mark - Volume Control

- (void)beginMasterVolumeChange {
    self.masterFaderView.state.isDragging = YES;
}

- (void)setMasterVolumeDB:(double)db {
    double linear = (db <= -96.0) ? 0.0 : pow(10.0, db / 20.0);
    if (linear < 0.0) linear = 0.0;
    if (linear > 1.0) linear = 1.0;

    self.masterFaderView.state.volumeDB = db;
    self.masterFaderView.state.volumeLinear = linear;

    id audioDest = SpliceKit_getMasterAudioDest();
    if (!audioDest) return;

    SEL setVolumeSel = NSSelectorFromString(@"setOutputVolume:");
    if ([audioDest respondsToSelector:setVolumeSel]) {
        ((BOOL (*)(id, SEL, float))objc_msgSend)(audioDest, setVolumeSel, (float)linear);
    }
}

- (void)endMasterVolumeChange {
    self.masterFaderView.state.isDragging = NO;
    [self.masterFaderView updateFromState];
}

- (void)beginVolumeChange:(NSInteger)faderIndex {
    SpliceKitFaderView *fv = self.faderViews[faderIndex];
    [self resetDragSessionForFader:fv];

    if (![self isTransportPlayingNow]) {
        [self ensureUndoTransactionForFader:fv effectStackHandle:[self currentUndoEffectStackHandleForFader:fv]];
    }
    [self updateAutomationUI];
}

- (void)setVolume:(NSInteger)faderIndex db:(double)db {
    SpliceKitFaderView *fv = self.faderViews[faderIndex];
    double linear = (db <= -96.0) ? 0.0 : pow(10.0, db / 20.0);
    if (linear < 0.0) linear = 0.0;
    if (linear > 3.98) linear = 3.98;
    fv.state.volumeDB = db;
    fv.state.volumeLinear = linear;

    BOOL transportPlaying = [self isTransportPlayingNow];
    if (transportPlaying && fv.state.isAutomationArmed) {
        [self recordAutomationSampleForFader:fv force:NO];
        return;
    }

    if (fv.state.didRecordAutomationInDrag) return;

    NSString *handle = fv.state.volumeChannelHandle;
    if (!handle) return;

    id channel = SpliceKit_resolveHandle(handle);
    if (!channel) return;

    SpliceKit_removeChannelKeyframes(channel);
    SpliceKit_mixerSetStaticChannelValue(channel, linear);
    [self notifyEffectsChangedForFader:fv];
}

- (void)endVolumeChange:(NSInteger)faderIndex {
    SpliceKitFaderView *fv = self.faderViews[faderIndex];
    if ([self isTransportPlayingNow] && fv.state.isAutomationArmed) {
        [self recordAutomationSampleForFader:fv force:NO];
    }

    [self finishUndoTransactionsForFader:fv];
    fv.state.isRecordingAutomation = NO;
    fv.state.didRecordAutomationInDrag = NO;
    fv.state.didPrepareAutomationInDrag = NO;
    fv.state.lastAutomationPlayheadSeconds = -DBL_MAX;
    fv.state.lastAutomationLinear = NAN;

    fv.state.isDragging = NO;
    [fv updateFromState];
    [self updateAutomationUI];
}

@end
