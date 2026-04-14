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
extern BOOL SpliceKit_removeChannelKeyframes(id channel);
extern BOOL SpliceKit_mixerWriteAutomationPoint(id clip, id channel, double value);

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
@property (nonatomic, strong) NSString *clipName;
@property (nonatomic, assign) NSInteger lane;
@property (nonatomic, assign) double volumeDB;
@property (nonatomic, assign) double volumeLinear;
@property (nonatomic, strong) NSString *role;
@property (nonatomic, strong) NSString *roleColorHex; // "#RRGGBB" from FCP
@property (nonatomic, assign) double meterDB; // real-time audio level (dB)
@property (nonatomic, assign) double meterLinear; // real-time audio level (0..1)
@property (nonatomic, assign) double meterPeak; // visual peak ratio from FCP meters (0..1)
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

@interface SpliceKitFaderView : NSView
@property (nonatomic, strong) SpliceKitFaderState *state;
@property (nonatomic, strong) NSSlider *slider;
@property (nonatomic, strong) NSTextField *dbLabel;
@property (nonatomic, strong) NSTextField *nameLabel;
@property (nonatomic, strong) NSTextField *roleLabel;
@property (nonatomic, strong) NSTextField *laneLabel;
@property (nonatomic, strong) NSTextField *indexLabel;
@property (nonatomic, strong) NSView *meterBar;       // green level meter
@property (nonatomic, strong) NSLayoutConstraint *meterHeight; // animated height
@property (nonatomic, copy) void (^onDragStart)(void);
@property (nonatomic, copy) void (^onDragChange)(double db);
@property (nonatomic, copy) void (^onDragEnd)(void);
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

@implementation SpliceKitFaderView {
    BOOL _tracking;
}

- (instancetype)initWithFrame:(NSRect)frame index:(NSInteger)idx {
    self = [super initWithFrame:frame];
    if (self) {
        self.wantsLayer = YES;
        self.layer.cornerRadius = 4;
        self.layer.borderColor = [NSColor.separatorColor CGColor];
        self.layer.borderWidth = 0.5;

        _state = [[SpliceKitFaderState alloc] init];
        _state.index = idx;
        _state.isMaster = (idx < 0);
        _state.minDB = -96.0;
        _state.maxDB = _state.isMaster ? 0.0 : 12.0;

        // Index label at top
        NSString *indexTitle = _state.isMaster ? @"M" : [NSString stringWithFormat:@"%ld", (long)idx + 1];
        _indexLabel = [self makeLabel:indexTitle
                                 size:11 bold:YES];
        _indexLabel.textColor = [NSColor secondaryLabelColor];

        // dB readout
        _dbLabel = [self makeLabel:@"--" size:10 bold:NO];
        _dbLabel.font = [NSFont monospacedSystemFontOfSize:10 weight:NSFontWeightMedium];

        // Vertical slider
        _slider = [[NSSlider alloc] initWithFrame:NSZeroRect];
        _slider.vertical = YES;
        _slider.minValue = 0;
        _slider.maxValue = 100;
        _slider.doubleValue = dbToSliderPos(0, _state.minDB, _state.maxDB);
        _slider.target = self;
        _slider.action = @selector(sliderChanged:);
        _slider.continuous = YES;

        // Role label
        _roleLabel = [self makeLabel:@"" size:9 bold:YES];
        _roleLabel.textColor = [NSColor systemBlueColor];
        _roleLabel.cell.truncatesLastVisibleLine = YES;
        _roleLabel.cell.lineBreakMode = NSLineBreakByTruncatingTail;

        // Lane label
        _laneLabel = [self makeLabel:@"" size:8 bold:NO];
        _laneLabel.textColor = [NSColor tertiaryLabelColor];

        // Clip name
        _nameLabel = [self makeLabel:@"--" size:8 bold:NO];
        _nameLabel.maximumNumberOfLines = 2;
        _nameLabel.cell.truncatesLastVisibleLine = YES;
        _nameLabel.cell.lineBreakMode = NSLineBreakByTruncatingTail;

        // Meter bar (level indicator)
        _meterBar = [[NSView alloc] init];
        _meterBar.wantsLayer = YES;
        _meterBar.layer.backgroundColor = [[NSColor systemGreenColor] colorWithAlphaComponent:0.7].CGColor;
        _meterBar.layer.cornerRadius = 1.5;

        for (NSView *v in @[_indexLabel, _dbLabel, _slider, _meterBar, _roleLabel, _laneLabel, _nameLabel]) {
            v.translatesAutoresizingMaskIntoConstraints = NO;
            [self addSubview:v];
        }

        [NSLayoutConstraint activateConstraints:@[
            [_indexLabel.topAnchor constraintEqualToAnchor:self.topAnchor constant:4],
            [_indexLabel.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],

            [_dbLabel.topAnchor constraintEqualToAnchor:_indexLabel.bottomAnchor constant:1],
            [_dbLabel.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],

            [_slider.topAnchor constraintEqualToAnchor:_dbLabel.bottomAnchor constant:2],
            [_slider.centerXAnchor constraintEqualToAnchor:self.centerXAnchor constant:-4],
            [_slider.bottomAnchor constraintEqualToAnchor:_roleLabel.topAnchor constant:-2],
            [_slider.widthAnchor constraintEqualToConstant:22],

            // Meter bar — thin strip to the right of the slider
            [_meterBar.leadingAnchor constraintEqualToAnchor:_slider.trailingAnchor constant:4],
            [_meterBar.bottomAnchor constraintEqualToAnchor:_slider.bottomAnchor],
            [_meterBar.widthAnchor constraintEqualToConstant:5],

            [_roleLabel.bottomAnchor constraintEqualToAnchor:_laneLabel.topAnchor constant:-1],
            [_roleLabel.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
            [_roleLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.leadingAnchor constant:2],
            [_roleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.trailingAnchor constant:-2],

            [_laneLabel.bottomAnchor constraintEqualToAnchor:_nameLabel.topAnchor constant:-1],
            [_laneLabel.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],

            [_nameLabel.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-3],
            [_nameLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:2],
            [_nameLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-2],
            [_nameLabel.heightAnchor constraintLessThanOrEqualToConstant:22],
        ]];

        // Meter height constraint — starts at 0, updated dynamically
        _meterHeight = [_meterBar.heightAnchor constraintEqualToConstant:0];
        _meterHeight.active = YES;
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

- (void)sliderChanged:(NSSlider *)sender {
    NSEvent *event = [NSApp currentEvent];
    BOOL starting = !_tracking;
    _tracking = YES;

    double db = sliderPosToDB(sender.doubleValue, _state.minDB, _state.maxDB);
    _state.volumeDB = db;
    _state.isDragging = YES;
    [self updateDBLabel];

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
    _slider.enabled = active;
    self.layer.borderColor = (_state.isRecordingAutomation ? [NSColor systemRedColor].CGColor
                                                           : [NSColor.separatorColor CGColor]);
    self.layer.borderWidth = _state.isRecordingAutomation ? 1.0 : 0.5;

    if (active && !_state.isDragging) {
        _slider.doubleValue = dbToSliderPos(_state.volumeDB, _state.minDB, _state.maxDB);
    }

    [self updateDBLabel];

    if (_state.isMaster) {
        _roleLabel.stringValue = active ? @"MASTER" : @"";
        NSColor *masterColor = [NSColor systemOrangeColor];
        _roleLabel.textColor = playing ? masterColor : [masterColor colorWithAlphaComponent:0.6];
        _laneLabel.stringValue = active ? @"OUTPUT" : @"";
        _nameLabel.stringValue = active ? (_state.clipName.length > 0 ? _state.clipName : @"Playback") : @"--";
    } else {
        // Role label — always show for active faders, use FCP's actual role color
        NSString *role = active ? (_state.role ?: @"") : @"";
        _roleLabel.stringValue = role;
        NSColor *roleColor = [NSColor secondaryLabelColor];
        NSString *hex = _state.roleColorHex;
        if (hex && hex.length == 7) {
            unsigned int r = 0, g = 0, b = 0;
            sscanf([hex UTF8String], "#%02x%02x%02x", &r, &g, &b);
            roleColor = [NSColor colorWithRed:r/255.0 green:g/255.0 blue:b/255.0 alpha:1.0];
        }
        _roleLabel.textColor = playing ? roleColor : [roleColor colorWithAlphaComponent:0.5];
        _laneLabel.stringValue = active ? [NSString stringWithFormat:@"L%ld", (long)_state.lane] : @"";
        _nameLabel.stringValue = active ? (_state.clipName ?: @"") : @"--";
    }
    _nameLabel.textColor = playing ? [NSColor labelColor] : [NSColor tertiaryLabelColor];

    // Slightly darker background when playing at playhead
    if (_state.isRecordingAutomation) {
        self.layer.backgroundColor = [[NSColor systemRedColor] colorWithAlphaComponent:0.14].CGColor;
    } else if (_state.isMaster && playing) {
        self.layer.backgroundColor = [[NSColor systemOrangeColor] colorWithAlphaComponent:0.12].CGColor;
    } else if (_state.isMaster && active) {
        self.layer.backgroundColor = [[NSColor controlAccentColor] colorWithAlphaComponent:0.08].CGColor;
    } else if (playing) {
        self.layer.backgroundColor = [[NSColor controlAccentColor] colorWithAlphaComponent:0.15].CGColor;
    } else if (active) {
        self.layer.backgroundColor = [[NSColor controlBackgroundColor] colorWithAlphaComponent:0.1].CGColor;
    } else {
        self.layer.backgroundColor = [NSColor clearColor].CGColor;
    }

    // Dim the slider thumb when not playing
    _slider.alphaValue = playing ? 1.0 : (active ? 0.6 : 0.3);

    // Update meter bar — use meterPeak (0..1 visual ratio from FCP's PEMeterLayer)
    double peak = _state.meterPeak;
    if (peak > 0.001 && active) {
        CGFloat sliderHeight = _slider.frame.size.height;
        CGFloat targetHeight = sliderHeight * peak;

        // Animate meter bar height for smooth movement
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
            ctx.duration = 0.08; // Fast response like real meters
            ctx.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
            self->_meterHeight.animator.constant = targetHeight;
        }];

        // Color: green < 70%, yellow 70-90%, red > 90%
        if (peak > 0.9) {
            _meterBar.layer.backgroundColor = [[NSColor systemRedColor] colorWithAlphaComponent:0.85].CGColor;
        } else if (peak > 0.7) {
            _meterBar.layer.backgroundColor = [[NSColor systemYellowColor] colorWithAlphaComponent:0.75].CGColor;
        } else {
            _meterBar.layer.backgroundColor = [[NSColor systemGreenColor] colorWithAlphaComponent:0.75].CGColor;
        }
        _meterBar.hidden = NO;
    } else {
        // Quick decay to zero
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
            ctx.duration = 0.15;
            self->_meterHeight.animator.constant = 0;
        }];
        _meterBar.hidden = NO; // Keep visible during decay animation
    }
}

- (void)updateDBLabel {
    if (!_state.isActive) {
        _dbLabel.stringValue = @"--";
        _dbLabel.textColor = [NSColor tertiaryLabelColor];
        return;
    }
    if (_state.volumeDB <= _state.minDB) {
        _dbLabel.stringValue = @"-inf";
    } else {
        _dbLabel.stringValue = [NSString stringWithFormat:@"%.1f", _state.volumeDB];
    }
    _dbLabel.textColor = _state.isPlaying ? [NSColor labelColor] : [NSColor secondaryLabelColor];
}

@end

#pragma mark - Mixer Panel

@interface SpliceKitMixerPanel : NSObject <NSWindowDelegate>
@property (nonatomic, strong) NSPanel *panel;
@property (nonatomic, strong) SpliceKitFaderView *masterFaderView;
@property (nonatomic, strong) NSMutableArray<SpliceKitFaderView *> *faderViews;
@property (nonatomic, strong) NSTextField *statusLabel;
@property (nonatomic, strong) NSView *statusDot;
@property (nonatomic, strong) NSButton *automationButton;
@property (nonatomic, strong) NSTimer *pollTimer;
@property (nonatomic, assign) BOOL isPolling;
@property (nonatomic, assign) BOOL transportPlaying;
@property (nonatomic, assign) double playheadSeconds;
@property (nonatomic, assign) double frameRate;
@property (nonatomic, assign) BOOL automationArmed;
+ (instancetype)sharedPanel;
- (void)showPanel;
- (void)hidePanel;
- (BOOL)isVisible;
- (void)beginMasterVolumeChange;
- (void)setMasterVolumeDB:(double)db;
- (void)endMasterVolumeChange;
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

    NSRect frame = NSMakeRect(200, 200, 780, 410);
    NSUInteger styleMask = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                           NSWindowStyleMaskResizable | NSWindowStyleMaskUtilityWindow;

    self.panel = [[NSPanel alloc] initWithContentRect:frame
                                            styleMask:styleMask
                                              backing:NSBackingStoreBuffered
                                                defer:NO];
    self.panel.title = @"Audio Mixer";
    self.panel.floatingPanel = YES;
    self.panel.becomesKeyOnlyIfNeeded = NO;
    self.panel.hidesOnDeactivate = NO;
    self.panel.level = NSFloatingWindowLevel;
    self.panel.minSize = NSMakeSize(640, 350);
    self.panel.delegate = self;
    self.panel.releasedWhenClosed = NO;
    self.panel.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];

    NSView *content = self.panel.contentView;
    content.wantsLayer = YES;

    [self buildUI:content];
}

- (void)buildUI:(NSView *)content {
    self.automationArmed = NO;

    NSView *header = [[NSView alloc] init];
    header.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:header];

    NSStackView *statusRow = [[NSStackView alloc] init];
    statusRow.translatesAutoresizingMaskIntoConstraints = NO;
    statusRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    statusRow.alignment = NSLayoutAttributeCenterY;
    statusRow.distribution = NSStackViewDistributionFill;
    statusRow.spacing = 8;
    [header addSubview:statusRow];

    self.statusDot = [[NSView alloc] init];
    self.statusDot.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusDot.wantsLayer = YES;
    self.statusDot.layer.cornerRadius = 5;
    [statusRow addArrangedSubview:self.statusDot];

    self.statusLabel = [NSTextField labelWithString:@"Automation Off"];
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusLabel.font = [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold];
    self.statusLabel.textColor = [NSColor secondaryLabelColor];
    [statusRow addArrangedSubview:self.statusLabel];

    NSView *statusSpacer = [[NSView alloc] init];
    statusSpacer.translatesAutoresizingMaskIntoConstraints = NO;
    [statusSpacer setContentHuggingPriority:NSLayoutPriorityDefaultLow
                             forOrientation:NSLayoutConstraintOrientationHorizontal];
    [statusSpacer setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                          forOrientation:NSLayoutConstraintOrientationHorizontal];
    [statusRow addArrangedSubview:statusSpacer];

    self.automationButton = [NSButton buttonWithTitle:@"Arm Automation"
                                               target:self
                                               action:@selector(toggleAutomationArm:)];
    self.automationButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.automationButton.bordered = NO;
    self.automationButton.focusRingType = NSFocusRingTypeNone;
    self.automationButton.wantsLayer = YES;
    self.automationButton.layer.cornerRadius = 9.0;
    self.automationButton.layer.masksToBounds = YES;
    self.automationButton.layer.borderWidth = 1.0;
    if (@available(macOS 10.15, *)) {
        self.automationButton.layer.cornerCurve = kCACornerCurveContinuous;
    }
    [statusRow addArrangedSubview:self.automationButton];

    NSTextField *hintLabel = [NSTextField labelWithString:@"Arm, then press play and move a fader to record keyframes."];
    hintLabel.translatesAutoresizingMaskIntoConstraints = NO;
    hintLabel.font = [NSFont systemFontOfSize:10];
    hintLabel.textColor = [NSColor tertiaryLabelColor];
    [header addSubview:hintLabel];

    NSStackView *mainStack = [[NSStackView alloc] init];
    mainStack.translatesAutoresizingMaskIntoConstraints = NO;
    mainStack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    mainStack.distribution = NSStackViewDistributionFill;
    mainStack.alignment = NSLayoutAttributeTop;
    mainStack.spacing = 6;
    [content addSubview:mainStack];

    self.masterFaderView = [[SpliceKitFaderView alloc] initWithFrame:NSMakeRect(0, 0, 64, 300) index:-1];
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
    [[self.masterFaderView.widthAnchor constraintEqualToConstant:72] setActive:YES];

    NSView *separator = [[NSView alloc] initWithFrame:NSZeroRect];
    separator.translatesAutoresizingMaskIntoConstraints = NO;
    separator.wantsLayer = YES;
    separator.layer.backgroundColor = [NSColor.separatorColor CGColor];
    [mainStack addArrangedSubview:separator];
    [[separator.widthAnchor constraintEqualToConstant:1] setActive:YES];

    NSStackView *faderStack = [[NSStackView alloc] init];
    faderStack.translatesAutoresizingMaskIntoConstraints = NO;
    faderStack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    faderStack.distribution = NSStackViewDistributionFillEqually;
    faderStack.spacing = 1;
    [mainStack addArrangedSubview:faderStack];

    // Create 10 faders
    self.faderViews = [NSMutableArray array];
    for (NSInteger i = 0; i < 10; i++) {
        SpliceKitFaderView *fv = [[SpliceKitFaderView alloc]
            initWithFrame:NSMakeRect(0, 0, 60, 300) index:i];

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

        [faderStack addArrangedSubview:fv];
        [self.faderViews addObject:fv];
    }

    // Layout — faders fill the whole window
    [NSLayoutConstraint activateConstraints:@[
        [header.topAnchor constraintEqualToAnchor:content.topAnchor constant:10],
        [header.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:10],
        [header.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-10],

        [statusRow.topAnchor constraintEqualToAnchor:header.topAnchor],
        [statusRow.leadingAnchor constraintEqualToAnchor:header.leadingAnchor],
        [statusRow.trailingAnchor constraintEqualToAnchor:header.trailingAnchor],

        [self.statusDot.widthAnchor constraintEqualToConstant:10],
        [self.statusDot.heightAnchor constraintEqualToConstant:10],

        [self.automationButton.heightAnchor constraintEqualToConstant:30],
        [self.automationButton.widthAnchor constraintGreaterThanOrEqualToConstant:104],

        [hintLabel.topAnchor constraintEqualToAnchor:statusRow.bottomAnchor constant:6],
        [hintLabel.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:2],
        [hintLabel.trailingAnchor constraintLessThanOrEqualToAnchor:header.trailingAnchor],
        [hintLabel.bottomAnchor constraintEqualToAnchor:header.bottomAnchor],

        [mainStack.topAnchor constraintEqualToAnchor:header.bottomAnchor constant:8],
        [mainStack.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:4],
        [mainStack.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-4],
        [mainStack.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-4],
    ]];

    [self updateAutomationUI];
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
    }
}

- (void)updateMixerState {
    extern NSDictionary *SpliceKit_handleMixerGetState(NSDictionary *params);
    NSDictionary *result = SpliceKit_handleMixerGetState(@{});
    [self applyMixerState:result];
}

- (void)applyMixerState:(NSDictionary *)result {
    self.isPolling = NO; // Allow next poll

    if (result[@"error"]) {
        self.transportPlaying = NO;
        [self clearAllFaders];
        return;
    }

    self.transportPlaying = [result[@"isPlaying"] boolValue];
    self.playheadSeconds = [result[@"playheadSeconds"] doubleValue];
    self.frameRate = [result[@"frameRate"] doubleValue];

    NSDictionary *masterInfo = [result[@"masterFader"] isKindOfClass:[NSDictionary class]] ? result[@"masterFader"] : nil;
    NSArray *faderData = result[@"faders"];

    BOOL masterDragging = self.masterFaderView.state.isDragging;
    if (masterInfo) {
        self.masterFaderView.state.isActive = YES;
        self.masterFaderView.state.isPlaying = [masterInfo[@"playing"] boolValue];
        self.masterFaderView.state.clipName = masterInfo[@"name"] ?: @"Playback";
        self.masterFaderView.state.role = masterInfo[@"role"] ?: @"Master";
        self.masterFaderView.state.meterPeak = [masterInfo[@"meterPeak"] doubleValue];
        self.masterFaderView.state.minDB = [masterInfo[@"minDB"] doubleValue];
        self.masterFaderView.state.maxDB = [masterInfo[@"maxDB"] doubleValue];
        if (!masterDragging) {
            self.masterFaderView.state.volumeDB = [masterInfo[@"volumeDB"] doubleValue];
            self.masterFaderView.state.volumeLinear = [masterInfo[@"volumeLinear"] doubleValue];
        }
    } else {
        self.masterFaderView.state.isActive = NO;
        self.masterFaderView.state.isPlaying = NO;
        self.masterFaderView.state.clipName = nil;
        self.masterFaderView.state.role = @"Master";
        self.masterFaderView.state.meterPeak = 0;
        self.masterFaderView.state.minDB = -96.0;
        self.masterFaderView.state.maxDB = 0.0;
    }
    [self.masterFaderView updateFromState];

    for (NSInteger i = 0; i < 10; i++) {
        SpliceKitFaderView *fv = self.faderViews[i];
        BOOL dragging = fv.state.isDragging;

        if (i < (NSInteger)faderData.count) {
            NSDictionary *info = faderData[i];
            fv.state.isActive = YES; // All role faders are always active
            fv.state.isPlaying = [info[@"playing"] boolValue]; // Playing = clip at playhead
            fv.state.clipName = info[@"name"] ?: @"";
            fv.state.lane = [info[@"lane"] integerValue];
            fv.state.clipHandle = info[@"clipHandle"];
            fv.state.volumeChannelHandle = info[@"volumeChannelHandle"];
            fv.state.audioEffectStackHandle = info[@"audioEffectStackHandle"];
            fv.state.effectStackHandle = info[@"effectStackHandle"];
            fv.state.role = info[@"role"];
            fv.state.roleColorHex = info[@"roleColor"];
            fv.state.meterDB = [info[@"meterDB"] doubleValue];
            fv.state.meterLinear = [info[@"meterLinear"] doubleValue];
            fv.state.meterPeak = [info[@"meterPeak"] doubleValue];
            if (!dragging) {
                fv.state.volumeDB = [info[@"volumeDB"] doubleValue];
                fv.state.volumeLinear = [info[@"volumeLinear"] doubleValue];
            }
        } else {
            fv.state.isActive = NO;
            fv.state.isPlaying = NO;
            fv.state.clipName = nil;
            fv.state.clipHandle = nil;
            fv.state.volumeChannelHandle = nil;
            fv.state.audioEffectStackHandle = nil;
            fv.state.effectStackHandle = nil;
            fv.state.role = nil;
            fv.state.meterDB = -INFINITY;
            fv.state.meterLinear = 0;
            fv.state.meterPeak = 0;
        }
        [fv updateFromState];
    }

    [self recordAutomationSamplesIfNeeded];
    [self updateAutomationUI];
}

- (void)clearAllFaders {
    self.masterFaderView.state.isActive = NO;
    self.masterFaderView.state.isPlaying = NO;
    self.masterFaderView.state.isDragging = NO;
    self.masterFaderView.state.clipName = nil;
    self.masterFaderView.state.role = @"Master";
    self.masterFaderView.state.meterPeak = 0;
    self.masterFaderView.state.minDB = -96.0;
    self.masterFaderView.state.maxDB = 0.0;
    [self.masterFaderView updateFromState];

    for (SpliceKitFaderView *fv in self.faderViews) {
        [self finishUndoTransactionsForFader:fv];
        fv.state.isActive = NO;
        fv.state.isPlaying = NO;
        fv.state.isRecordingAutomation = NO;
        fv.state.clipName = nil;
        fv.state.clipHandle = nil;
        fv.state.volumeChannelHandle = nil;
        fv.state.audioEffectStackHandle = nil;
        fv.state.effectStackHandle = nil;
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

- (void)updateAutomationButtonWithTitle:(NSString *)title
                             textColor:(NSColor *)textColor
                        backgroundColor:(NSColor *)backgroundColor
                            borderColor:(NSColor *)borderColor {
    NSDictionary *attrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold],
        NSForegroundColorAttributeName: textColor
    };
    self.automationButton.attributedTitle =
        [[NSAttributedString alloc] initWithString:title attributes:attrs];
    self.automationButton.layer.backgroundColor = backgroundColor.CGColor;
    self.automationButton.layer.borderColor = borderColor.CGColor;
}

- (void)updateAutomationUI {
    BOOL recording = [self anyFaderRecordingAutomation];
    if (recording) {
        self.statusDot.layer.backgroundColor = [NSColor systemRedColor].CGColor;
        self.statusLabel.stringValue = @"Recording Automation";
        self.statusLabel.textColor = [NSColor systemRedColor];
    } else if (self.automationArmed) {
        self.statusDot.layer.backgroundColor = [NSColor systemOrangeColor].CGColor;
        self.statusLabel.stringValue = @"Automation Armed";
        self.statusLabel.textColor = [NSColor systemOrangeColor];
    } else {
        self.statusDot.layer.backgroundColor = [NSColor tertiaryLabelColor].CGColor;
        self.statusLabel.stringValue = @"Automation Off";
        self.statusLabel.textColor = [NSColor secondaryLabelColor];
    }

    NSString *buttonTitle = self.automationArmed ? @"Disarm" : @"Arm";
    NSColor *buttonTextColor = nil;
    NSColor *buttonBackgroundColor = nil;
    NSColor *buttonBorderColor = nil;
    if (recording) {
        buttonTextColor = [NSColor colorWithSRGBRed:1.00 green:0.86 blue:0.86 alpha:1.0];
        buttonBackgroundColor = [NSColor colorWithSRGBRed:0.36 green:0.15 blue:0.15 alpha:1.0];
        buttonBorderColor = [NSColor colorWithSRGBRed:0.77 green:0.27 blue:0.27 alpha:1.0];
    } else if (self.automationArmed) {
        buttonTextColor = [NSColor colorWithSRGBRed:1.00 green:0.89 blue:0.73 alpha:1.0];
        buttonBackgroundColor = [NSColor colorWithSRGBRed:0.34 green:0.25 blue:0.10 alpha:1.0];
        buttonBorderColor = [NSColor colorWithSRGBRed:0.90 green:0.58 blue:0.18 alpha:1.0];
    } else {
        buttonTextColor = [NSColor labelColor];
        buttonBackgroundColor = [NSColor colorWithWhite:1.0 alpha:0.08];
        buttonBorderColor = [NSColor colorWithWhite:1.0 alpha:0.12];
    }

    [self updateAutomationButtonWithTitle:buttonTitle
                                textColor:buttonTextColor
                           backgroundColor:buttonBackgroundColor
                               borderColor:buttonBorderColor];
}

- (void)toggleAutomationArm:(id)sender {
    self.automationArmed = !self.automationArmed;
    [self updateAutomationUI];
}

- (NSString *)currentUndoEffectStackHandleForFader:(SpliceKitFaderView *)fv {
    return fv.state.effectStackHandle ?: fv.state.audioEffectStackHandle;
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
        if (self.transportPlaying && self.automationArmed) {
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
        @"transportPlaying": @(self.transportPlaying),
        @"playheadSeconds": @(self.playheadSeconds),
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

    if ([self isTransportPlayingNow]) {
        if (self.automationArmed) {
            [self recordAutomationSampleForFader:fv force:NO];
        }
        return;
    }

    if (fv.state.didRecordAutomationInDrag) return;

    NSString *handle = fv.state.volumeChannelHandle;
    if (!handle) return;

    id channel = SpliceKit_resolveHandle(handle);
    if (!channel) return;

    SpliceKit_removeChannelKeyframes(channel);
    SpliceKit_setChannelValue(channel, linear);

    // Force timeline/audio engine refresh so volume takes effect during playback
    @try {
        id timeline = SpliceKit_getActiveTimelineModule();
        if (timeline) {
            id sequence = nil;
            if ([timeline respondsToSelector:@selector(sequence)])
                sequence = ((id (*)(id, SEL))objc_msgSend)(timeline, @selector(sequence));
            if (sequence) {
                SEL forceUpdateSel = NSSelectorFromString(@"forceUpdate");
                if ([sequence respondsToSelector:forceUpdateSel])
                    ((void (*)(id, SEL))objc_msgSend)(sequence, forceUpdateSel);
            }
            SEL reloadSel = NSSelectorFromString(@"reloadTimelineView:");
            if ([timeline respondsToSelector:reloadSel])
                ((void (*)(id, SEL, id))objc_msgSend)(timeline, reloadSel, nil);
        }
    } @catch (NSException *e) {}
}

- (void)endVolumeChange:(NSInteger)faderIndex {
    SpliceKitFaderView *fv = self.faderViews[faderIndex];
    if ([self isTransportPlayingNow] && self.automationArmed) {
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
