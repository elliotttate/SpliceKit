//
//  SpliceKitMixerPanel.m
//  Audio mixer panel with per-clip volume faders inside FCP
//

#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "SpliceKit.h"

// Forward declarations from SpliceKitServer.m
extern id SpliceKit_getActiveTimelineModule(void);
extern id SpliceKit_storeHandle(id obj);
extern id SpliceKit_resolveHandle(NSString *handle);
extern double SpliceKit_channelValue(id channel);
extern BOOL SpliceKit_setChannelValue(id channel, double value);

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
@property (nonatomic, assign) BOOL isDragging;
@property (nonatomic, assign) double dragStartLinear; // initial value for undo
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

// dB <-> slider position (0..100) with perceptual curve
static double dbToSliderPos(double db) {
    if (db <= -96) return 0;
    if (db >= 12) return 100;
    if (db >= 0) return 75.0 + (db / 12.0) * 25.0;
    double norm = (db + 96.0) / 96.0;
    return sqrt(norm) * 75.0;
}

static double sliderPosToDB(double pos) {
    if (pos <= 0) return -96;
    if (pos >= 100) return 12;
    if (pos >= 75) return ((pos - 75.0) / 25.0) * 12.0;
    double norm = pos / 75.0;
    return (norm * norm) * 96.0 - 96.0;
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

        // Index label at top
        _indexLabel = [self makeLabel:[NSString stringWithFormat:@"%ld", (long)idx + 1]
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
        _slider.doubleValue = dbToSliderPos(0);
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

    double db = sliderPosToDB(sender.doubleValue);
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

    if (active && !_state.isDragging) {
        _slider.doubleValue = dbToSliderPos(_state.volumeDB);
    }

    [self updateDBLabel];

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

    // Lane and name — always show
    _laneLabel.stringValue = active ? [NSString stringWithFormat:@"L%ld", (long)_state.lane] : @"";
    _nameLabel.stringValue = active ? (_state.clipName ?: @"") : @"--";
    _nameLabel.textColor = playing ? [NSColor labelColor] : [NSColor tertiaryLabelColor];

    // Slightly darker background when playing at playhead
    if (playing) {
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
    if (_state.volumeDB <= -96) {
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
@property (nonatomic, strong) NSMutableArray<SpliceKitFaderView *> *faderViews;
@property (nonatomic, strong) NSTextField *statusLabel;
@property (nonatomic, strong) NSView *statusDot;
@property (nonatomic, strong) NSTimer *pollTimer;
@property (nonatomic, assign) BOOL isPolling;
+ (instancetype)sharedPanel;
- (void)showPanel;
- (void)hidePanel;
- (BOOL)isVisible;
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

    NSRect frame = NSMakeRect(200, 200, 700, 380);
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
    self.panel.minSize = NSMakeSize(500, 320);
    self.panel.delegate = self;
    self.panel.releasedWhenClosed = NO;
    self.panel.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];

    NSView *content = self.panel.contentView;
    content.wantsLayer = YES;

    [self buildUI:content];
}

- (void)buildUI:(NSView *)content {
    // Fader container — fills the entire content area
    NSStackView *faderStack = [[NSStackView alloc] init];
    faderStack.translatesAutoresizingMaskIntoConstraints = NO;
    faderStack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    faderStack.distribution = NSStackViewDistributionFillEqually;
    faderStack.spacing = 1;
    [content addSubview:faderStack];

    // Create 10 faders
    self.faderViews = [NSMutableArray array];
    for (NSInteger i = 0; i < 10; i++) {
        SpliceKitFaderView *fv = [[SpliceKitFaderView alloc]
            initWithFrame:NSMakeRect(0, 0, 60, 300) index:i];

        __weak SpliceKitMixerPanel *weakSelf = self;
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
        [faderStack.topAnchor constraintEqualToAnchor:content.topAnchor constant:4],
        [faderStack.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:4],
        [faderStack.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-4],
        [faderStack.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-4],
    ]];
}

#pragma mark - Polling

- (void)startPolling {
    [self stopPolling];
    self.isPolling = NO; // Reset re-entrancy guard
    self.pollTimer = [NSTimer scheduledTimerWithTimeInterval:0.05
                                                     target:self
                                                   selector:@selector(pollTimerFired:)
                                                   userInfo:nil
                                                    repeats:YES];
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
    // Call the RPC handler — but it uses SpliceKit_executeOnMainThread internally,
    // and we're already on the main thread. We need to call it on a background
    // thread and dispatch results back to update the UI.
    // For safety, wrap everything in a dispatch to avoid re-entrancy crashes.
    __weak SpliceKitMixerPanel *weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
        extern NSDictionary *SpliceKit_handleMixerGetState(NSDictionary *params);
        NSDictionary *result = SpliceKit_handleMixerGetState(@{});
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf applyMixerState:result];
        });
    });
}

- (void)applyMixerState:(NSDictionary *)result {
    self.isPolling = NO; // Allow next poll

    if (result[@"error"]) {
        [self clearAllFaders];
        return;
    }

    NSArray *faderData = result[@"faders"];

    for (NSInteger i = 0; i < 10; i++) {
        SpliceKitFaderView *fv = self.faderViews[i];
        if (fv.state.isDragging) continue;

        if (i < (NSInteger)faderData.count) {
            NSDictionary *info = faderData[i];
            fv.state.isActive = YES; // All role faders are always active
            fv.state.isPlaying = [info[@"playing"] boolValue]; // Playing = clip at playhead
            fv.state.clipName = info[@"name"] ?: @"";
            fv.state.lane = [info[@"lane"] integerValue];
            fv.state.volumeDB = [info[@"volumeDB"] doubleValue];
            fv.state.volumeLinear = [info[@"volumeLinear"] doubleValue];
            fv.state.clipHandle = info[@"clipHandle"];
            fv.state.volumeChannelHandle = info[@"volumeChannelHandle"];
            fv.state.audioEffectStackHandle = info[@"audioEffectStackHandle"];
            fv.state.role = info[@"role"];
            fv.state.roleColorHex = info[@"roleColor"];
            fv.state.meterDB = [info[@"meterDB"] doubleValue];
            fv.state.meterLinear = [info[@"meterLinear"] doubleValue];
            fv.state.meterPeak = [info[@"meterPeak"] doubleValue];
        } else {
            fv.state.isActive = NO;
            fv.state.isPlaying = NO;
            fv.state.clipName = nil;
            fv.state.clipHandle = nil;
            fv.state.volumeChannelHandle = nil;
            fv.state.audioEffectStackHandle = nil;
            fv.state.role = nil;
        }
        [fv updateFromState];
    }
}

- (void)clearAllFaders {
    for (SpliceKitFaderView *fv in self.faderViews) {
        fv.state.isActive = NO;
        fv.state.clipName = nil;
        fv.state.clipHandle = nil;
        fv.state.volumeChannelHandle = nil;
        [fv updateFromState];
    }
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
            @"name": fv.state.clipName ?: @"",
            @"role": fv.state.role ?: @"",
            @"lane": @(fv.state.lane),
            @"volumeDB": @(fv.state.volumeDB),
            @"clipHandle": fv.state.clipHandle ?: @"",
            @"volHandle": fv.state.volumeChannelHandle ?: @"",
            @"sliderValue": @(fv.slider.doubleValue),
        }];
    }
    return @{
        @"panelVisible": @(self.panel.isVisible),
        @"isPolling": @(self.isPolling),
        @"timerValid": @(self.pollTimer.isValid),
        @"faders": faderStates,
    };
}

#pragma mark - Volume Control

- (void)beginVolumeChange:(NSInteger)faderIndex {
    SpliceKitFaderView *fv = self.faderViews[faderIndex];
    // Save the initial value for undo — no undo transaction opened here so that
    // postEffectsChangedNotification can propagate immediately during drag.
    NSString *handle = fv.state.volumeChannelHandle;
    if (handle) {
        id channel = SpliceKit_resolveHandle(handle);
        if (channel) {
            fv.state.dragStartLinear = SpliceKit_channelValue(channel);
        }
    }
}

- (void)setVolume:(NSInteger)faderIndex db:(double)db {
    SpliceKitFaderView *fv = self.faderViews[faderIndex];
    NSString *handle = fv.state.volumeChannelHandle;
    if (!handle) return;

    id channel = SpliceKit_resolveHandle(handle);
    if (!channel) return;

    double linear = (db <= -96.0) ? 0.0 : pow(10.0, db / 20.0);
    if (linear < 0.0) linear = 0.0;
    if (linear > 3.98) linear = 3.98;

    SpliceKit_setChannelValue(channel, linear);

    // Notify FCP that effect parameters changed so the audio engine re-reads them.
    // beginVolumeChange: sets deferUpdates:NO, so this propagates immediately
    // during drag rather than being coalesced until actionEnd:.
    NSString *esHandle = fv.state.audioEffectStackHandle;
    if (esHandle) {
        id effectStack = SpliceKit_resolveHandle(esHandle);
        if (effectStack) {
            SEL sel = NSSelectorFromString(@"postEffectsChangedNotification");
            if ([effectStack respondsToSelector:sel]) {
                ((void (*)(id, SEL))objc_msgSend)(effectStack, sel);
            }
        }
    }
}

- (void)endVolumeChange:(NSInteger)faderIndex {
    SpliceKitFaderView *fv = self.faderViews[faderIndex];
    NSString *esHandle = fv.state.audioEffectStackHandle;
    NSString *chHandle = fv.state.volumeChannelHandle;
    if (!esHandle || !chHandle) { fv.state.isDragging = NO; return; }

    id effectStack = SpliceKit_resolveHandle(esHandle);
    id channel = SpliceKit_resolveHandle(chHandle);
    if (!effectStack || !channel) { fv.state.isDragging = NO; return; }

    @try {
        // Read the final value the user dragged to
        double finalLinear = SpliceKit_channelValue(channel);

        // Restore the initial value so actionBegin: snapshots the pre-drag state
        SpliceKit_setChannelValue(channel, fv.state.dragStartLinear);

        // Open undo transaction (captures initial state)
        SEL beginSel = NSSelectorFromString(@"actionBegin:animationHint:deferUpdates:");
        if ([effectStack respondsToSelector:beginSel]) {
            ((void (*)(id, SEL, id, id, BOOL))objc_msgSend)(
                effectStack, beginSel, @"Adjust Volume", nil, YES);
        }

        // Apply the final value (undo system records the delta)
        SpliceKit_setChannelValue(channel, finalLinear);

        // Close undo transaction
        SEL endSel = NSSelectorFromString(@"actionEnd:save:error:");
        if ([effectStack respondsToSelector:endSel]) {
            ((void (*)(id, SEL, id, BOOL, id))objc_msgSend)(
                effectStack, endSel, @"Adjust Volume", YES, nil);
        }

        // Final notification to ensure audio engine has the committed value
        SEL notifySel = NSSelectorFromString(@"postEffectsChangedNotification");
        if ([effectStack respondsToSelector:notifySel]) {
            ((void (*)(id, SEL))objc_msgSend)(effectStack, notifySel);
        }
    } @catch (NSException *e) {}

    fv.state.isDragging = NO;
}

@end
