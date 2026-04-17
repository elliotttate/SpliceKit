// SpliceKitBRAWSettingsHud.mm — BRAW RAW adjustment HUD.
//
// Design: a single singleton NSPanel built entirely in code (no nib). An
// NSGridView lays out [label | control | value-readout | spacer] rows, one
// per BRAW adjustment parameter. Control descriptors are a static array;
// adding a new parameter is one dictionary entry. Changes are commited to
// FFAsset.rawProcessorSettings immediately; undo is wrapped via FFEditActionMgr
// beginActionWithLabel: / endAction so each slider drag shows up as a single
// "Modify BRAW Settings" undo step.

#import "SpliceKitBRAWSettingsHud.h"
#import "SpliceKitBRAWAdjustmentInfo.h"

#import <objc/message.h>
#import <objc/runtime.h>
#import <CoreMedia/CoreMedia.h>

// Host-side BRAW entry points (defined in SpliceKitBRAW.mm). Declared here so
// we don't need a header change in SpliceKit.h.
extern "C" {
void SpliceKitBRAW_SetRAWSettingsForPath(CFStringRef pathRef, CFDictionaryRef settingsRef);
CFDictionaryRef SpliceKitBRAW_CopyRAWSettingsForPath(CFStringRef pathRef);
id SpliceKit_getActiveTimelineModule(void);
}

#pragma mark - Descriptors

// Control kinds supported in the HUD grid.
typedef NS_ENUM(NSInteger, SpliceKitBRAWControlKind) {
    SpliceKitBRAWControlKindSlider,        // NSSlider, float/int
    SpliceKitBRAWControlKindPopupNumeric,  // NSPopUpButton, NSNumber values
    SpliceKitBRAWControlKindPopupString,   // NSPopUpButton, NSString values
    SpliceKitBRAWControlKindCheckbox,      // NSButton, BOOL backing
    SpliceKitBRAWControlKindSection,       // section header, no control
};

@interface SpliceKitBRAWControlDescriptor : NSObject
@property (nonatomic, copy)   NSString *key;             // BRAW settings key
@property (nonatomic, copy)   NSString *label;
@property (nonatomic, assign) SpliceKitBRAWControlKind kind;
@property (nonatomic, assign) double minValue;
@property (nonatomic, assign) double maxValue;
@property (nonatomic, assign) double defaultValue;       // numeric default
@property (nonatomic, copy, nullable) NSString *defaultString;
@property (nonatomic, copy, nullable) NSArray<NSNumber *> *popupValues;
@property (nonatomic, copy, nullable) NSArray<NSString *> *popupStrings;
@property (nonatomic, copy, nullable) NSString *format;  // printf-style readout
@end

@implementation SpliceKitBRAWControlDescriptor
@end

static NSArray<SpliceKitBRAWControlDescriptor *> *SpliceKitBRAWBuildDescriptors(void) {
    static NSArray<SpliceKitBRAWControlDescriptor *> *descriptors;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableArray *array = [NSMutableArray array];

        SpliceKitBRAWControlDescriptor *(^addSection)(NSString *) = ^(NSString *label) {
            SpliceKitBRAWControlDescriptor *d = [SpliceKitBRAWControlDescriptor new];
            d.kind = SpliceKitBRAWControlKindSection;
            d.label = label;
            [array addObject:d];
            return d;
        };

        SpliceKitBRAWControlDescriptor *(^addSlider)(NSString *, NSString *, double, double, double, NSString *) =
            ^(NSString *key, NSString *label, double minV, double maxV, double def, NSString *fmt) {
            SpliceKitBRAWControlDescriptor *d = [SpliceKitBRAWControlDescriptor new];
            d.key = key; d.label = label; d.kind = SpliceKitBRAWControlKindSlider;
            d.minValue = minV; d.maxValue = maxV; d.defaultValue = def;
            d.format = fmt;
            [array addObject:d];
            return d;
        };

        SpliceKitBRAWControlDescriptor *(^addPopupNumeric)(NSString *, NSString *, NSArray<NSNumber *> *, double) =
            ^(NSString *key, NSString *label, NSArray<NSNumber *> *values, double def) {
            SpliceKitBRAWControlDescriptor *d = [SpliceKitBRAWControlDescriptor new];
            d.key = key; d.label = label; d.kind = SpliceKitBRAWControlKindPopupNumeric;
            d.popupValues = values; d.defaultValue = def;
            [array addObject:d];
            return d;
        };

        SpliceKitBRAWControlDescriptor *(^addPopupString)(NSString *, NSString *, NSArray<NSString *> *, NSString *) =
            ^(NSString *key, NSString *label, NSArray<NSString *> *values, NSString *def) {
            SpliceKitBRAWControlDescriptor *d = [SpliceKitBRAWControlDescriptor new];
            d.key = key; d.label = label; d.kind = SpliceKitBRAWControlKindPopupString;
            d.popupStrings = values; d.defaultString = def;
            [array addObject:d];
            return d;
        };

        SpliceKitBRAWControlDescriptor *(^addCheckbox)(NSString *, NSString *, BOOL) =
            ^(NSString *key, NSString *label, BOOL def) {
            SpliceKitBRAWControlDescriptor *d = [SpliceKitBRAWControlDescriptor new];
            d.key = key; d.label = label; d.kind = SpliceKitBRAWControlKindCheckbox;
            d.defaultValue = def ? 1.0 : 0.0;
            [array addObject:d];
            return d;
        };

        // ─────────── Color Science ───────────
        addSection(@"Color Science");
        // Gamma options the BRAW SDK accepts (Generation 5 default for new
        // cameras; older clips may originate as Gen 4). Picking "…Custom"
        // unlocks the per-channel tone-curve sliders below.
        addPopupString(SpliceKitBRAWKeyGamma, @"Gamma",
            @[@"Blackmagic Design Film",
              @"Blackmagic Design Extended Video",
              @"Blackmagic Design Video",
              @"Blackmagic Design Custom"],
            @"Blackmagic Design Film");
        addPopupString(SpliceKitBRAWKeyGamut, @"Gamut",
            @[@"Blackmagic Design",
              @"Rec.709",
              @"Rec.2020"],
            @"Blackmagic Design");
        // Color Science Gen — most clips lock this to whatever the camera shot,
        // but exposing it lets users force-upgrade older clips to Gen 5 math.
        addPopupNumeric(SpliceKitBRAWKeyColorScienceGen, @"Color Science Gen",
            @[@1, @4, @5], 5);
        addCheckbox(SpliceKitBRAWKeyGamutCompression, @"Gamut Compression", NO);

        // ─────────── Frame ───────────
        addSection(@"Frame");
        addPopupNumeric(SpliceKitBRAWKeyISO, @"ISO",
            @[@100, @200, @400, @800, @1600, @3200, @6400, @12800], 800);
        addSlider(SpliceKitBRAWKeyKelvin,     @"Color Temperature", 2500, 10000, 5600, @"%.0f K");
        addSlider(SpliceKitBRAWKeyTint,       @"Tint",              -50,  50,    0,    @"%.0f");
        addSlider(SpliceKitBRAWKeyExposure,   @"Exposure",          -5.0, 5.0,   0.0,  @"%.2f stops");
        addSlider(SpliceKitBRAWKeyAnalogGain, @"Analog Gain",       -5.0, 5.0,   0.0,  @"%.2f");

        // ─────────── Tone Curve ───────────
        addSection(@"Tone Curve");
        addSlider(SpliceKitBRAWKeySaturation,      @"Saturation",        0.0,  2.0,   1.0,  @"%.2f");
        addSlider(SpliceKitBRAWKeyContrast,        @"Contrast",          0.0,  2.0,   1.0,  @"%.2f");
        addSlider(SpliceKitBRAWKeyMidpoint,        @"Midpoint",          0.0,  1.0,   0.38, @"%.2f");
        addSlider(SpliceKitBRAWKeyHighlights,      @"Highlights",       -1.0,  1.0,   0.0,  @"%.2f");
        addSlider(SpliceKitBRAWKeyShadows,         @"Shadows",          -1.0,  1.0,   0.0,  @"%.2f");
        addSlider(SpliceKitBRAWKeyBlackLevel,      @"Black Level",       0.0,  1.0,   0.0,  @"%.2f");
        addSlider(SpliceKitBRAWKeyWhiteLevel,      @"White Level",       0.0,  1.0,   1.0,  @"%.2f");
        addCheckbox(SpliceKitBRAWKeyVideoBlackLevel, @"Video Black Level", NO);

        // ─────────── Color Adjustments ───────────
        addSection(@"Color Adjustments");
        addCheckbox(SpliceKitBRAWKeyHighlightRecovery, @"Highlight Recovery", NO);
        addSlider(SpliceKitBRAWKeyAnalogGainClip,      @"Clip Gain",         -5.0, 5.0, 0.0, @"%.2f");

        // ─────────── Post 3D LUT ───────────
        addSection(@"Post 3D LUT");
        addPopupString(SpliceKitBRAWKeyPost3DLUTMode, @"3D LUT Mode",
            @[@"None",
              @"Embedded",
              @"Sidecar"],
            @"None");

        descriptors = [array copy];
    });
    return descriptors;
}

#pragma mark - Path / asset helpers

static NSURL *SpliceKitBRAWHudURLFromValue(id value) {
    if (!value || value == (id)kCFNull) return nil;
    if ([value isKindOfClass:[NSURL class]]) return value;
    if ([value isKindOfClass:[NSArray class]]) {
        for (id item in (NSArray *)value) {
            NSURL *url = SpliceKitBRAWHudURLFromValue(item);
            if (url) return url;
        }
        return nil;
    }
    if ([value isKindOfClass:[NSString class]]) {
        NSString *string = (NSString *)value;
        if ([string hasPrefix:@"file://"]) {
            NSURL *url = [NSURL URLWithString:string];
            if (url.isFileURL) return url;
        }
        if ([string hasPrefix:@"/"]) {
            return [NSURL fileURLWithPath:string];
        }
    }
    return nil;
}

static NSString *SpliceKitBRAWHudNormalizedPath(id root) {
    if (!root) return nil;
    id target = root;
    if ([target respondsToSelector:@selector(primaryObject)]) {
        id primary = ((id (*)(id, SEL))objc_msgSend)(target, @selector(primaryObject));
        if (primary) target = primary;
    }
    NSArray<NSString *> *keyPaths = @[
        @"originalMediaURL", @"fileURL", @"URL", @"persistentFileURL",
        @"media.originalMediaURL", @"asset.originalMediaURL",
        @"originalMediaRep.fileURL", @"originalMediaRep.fileURLs",
        @"currentRep.fileURL", @"currentRep.fileURLs",
        @"clipInPlace.asset.originalMediaURL",
    ];
    for (NSString *keyPath in keyPaths) {
        @try {
            id value = [target valueForKeyPath:keyPath];
            NSURL *url = SpliceKitBRAWHudURLFromValue(value);
            if (url.isFileURL) {
                NSURL *resolved = [url URLByResolvingSymlinksInPath];
                NSString *resolvedPath = resolved.path.stringByStandardizingPath;
                return resolvedPath.length > 0 ? resolvedPath : url.path.stringByStandardizingPath;
            }
        } @catch (__unused NSException *e) {
        }
    }
    return nil;
}

// Walk an item (FFAssetRef / FFAnchoredMediaComponent / FFAsset / …) to the
// concrete FFAsset that holds rawProcessorSettings.
static id SpliceKitBRAWHudResolveAsset(id root) {
    if (!root) return nil;
    Class assetClass = objc_getClass("FFAsset");
    if (assetClass && [root isKindOfClass:assetClass]) return root;

    SEL probes[] = { @selector(asset), @selector(media), @selector(firstAsset),
                     @selector(firstAssetIfOnlyOneVideo), @selector(originalMediaRep) };
    id chain[8] = { root };
    NSUInteger chainLen = 1;
    for (size_t p = 0; p < sizeof(probes) / sizeof(SEL) && chainLen < 8; ++p) {
        id current = chain[chainLen - 1];
        if (!current || ![current respondsToSelector:probes[p]]) continue;
        id next = ((id (*)(id, SEL))objc_msgSend)(current, probes[p]);
        if (!next) continue;
        chain[chainLen++] = next;
        if (assetClass && [next isKindOfClass:assetClass]) return next;
    }
    return nil;
}

static id SpliceKitBRAWHudCurrentSequence(void) {
    id module = SpliceKit_getActiveTimelineModule();
    if (!module) return nil;
    SEL sel = NSSelectorFromString(@"sequence");
    if (![module respondsToSelector:sel]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(module, sel);
}

static void SpliceKitBRAWHudForceRefresh(id asset) {
    if (!asset) return;
    // Defer ALL invalidation calls. -[FFAsset invalidate] takes the
    // FFSharedLock write lock by way of -[FFAnchoredSequence _actionBeginEditing].
    // If we're called inline from a slider action that's already inside an
    // active edit-action context (FCP's own NSControl gesture handler holds
    // a sequence write lock while dispatching the action), invalidate will
    // try to begin a NESTED edit action, fail to re-acquire the same lock,
    // and deadlock waiting on a pthread condvar. We saw this in the
    // 2026-04-17 15:53 crash report (faulting thread 0, _writeLock at +368).
    //
    // dispatch_async(main) lets the current action context unwind first;
    // when our refresh fires the next runloop tick, the lock is free and
    // invalidate cleanly begins its own action.
    // Use ONLY the light-touch -invalidateSourceRange: refresh. The heavier
    // -[FFAsset invalidate] and -[FFAnchoredSequence forcePlayerContextChangeForSequence]
    // cascaded into FFSourceVideoEffect._invalidateCachedMD5: which then
    // crashed on FFSynchronizable::Lock() against a nil object — see crash
    // 2026-04-17 16:44:35 (EXC_BAD_ACCESS at 0x70 from
    // SpliceKitBRAWHudForceRefresh deferred block).
    //
    // FCP's own -[FFAsset setRawProcessorSettings:] (which we call right
    // before this) already invalidates internal state enough to trigger a
    // re-decode on the next frame request. invalidateSourceRange: is the
    // belt-and-suspenders nudge — safe and sufficient.
    id retainedAsset = asset;
    dispatch_async(dispatch_get_main_queue(), ^{
        SEL invalidateRange = NSSelectorFromString(@"invalidateSourceRange:");
        if ([retainedAsset respondsToSelector:invalidateRange]) {
            CMTimeRange fullRange = CMTimeRangeMake(kCMTimeZero, kCMTimePositiveInfinity);
            ((void (*)(id, SEL, CMTimeRange))objc_msgSend)(retainedAsset, invalidateRange, fullRange);
        }
    });
}

#pragma mark - Undo helper

// We deliberately do NOT wrap settings commits in FFEditActionMgr begin/end
// scopes. Two reasons:
//   1. Slider events from NSControl are already dispatched inside FCP's own
//      action context (NSGestureRecognizer holds a sequence write lock while
//      sending). Nesting a begin/end inside that context caused
//      -[FFAsset invalidate] to deadlock on FFSharedLock — see crash report
//      2026-04-17 15:53 at /Users/briantate/Library/Logs/DiagnosticReports.
//   2. -[FFAsset setRawProcessorSettings:] already triggers FCP's internal
//      undo coordination via the per-asset KVO + invalidation path. We don't
//      need to redundantly wrap it.
//
// If we ever need explicit "Modify BRAW Settings" undo grouping, it should be
// done via FFAsset's own undoRegisterRedoWithTarget pattern, not by opening
// a top-level edit action that conflicts with the in-flight gesture.
static inline void SpliceKitBRAWHudRunInUndoAction(NSString *label, void (^block)(void)) {
    (void)label;
    block();
}

#pragma mark - HUD implementation

@interface SpliceKitBRAWSettingsHud () <NSWindowDelegate>
@property (nonatomic, strong) NSPanel *panel;
@property (nonatomic, strong) NSGridView *grid;
@property (nonatomic, strong) NSTextField *itemLabel;
@property (nonatomic, strong) NSTextField *subtitleLabel;
@property (nonatomic, strong) NSBox *formBox;
@property (nonatomic, copy, nullable) NSArray *items;
@property (nonatomic, strong, nullable) id currentAsset;
@property (nonatomic, copy, nullable) NSString *currentPath;
@property (nonatomic, strong) SpliceKitBRAWAdjustmentInfo *adjustmentInfo;
@property (nonatomic, strong) NSMutableDictionary<NSString *, id> *controlByKey;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSTextField *> *readoutByKey;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSButton *> *revertButtonByKey;
@property (nonatomic, assign) BOOL suppressActions;
@end

@implementation SpliceKitBRAWSettingsHud

+ (instancetype)shared {
    static SpliceKitBRAWSettingsHud *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [[self alloc] init]; });
    return instance;
}

- (instancetype)init {
    if ((self = [super init])) {
        _controlByKey = [NSMutableDictionary dictionary];
        _readoutByKey = [NSMutableDictionary dictionary];
        _revertButtonByKey = [NSMutableDictionary dictionary];
        _adjustmentInfo = [SpliceKitBRAWAdjustmentInfo infoWithSettings:nil];
    }
    return self;
}

- (BOOL)isHUDVisible {
    return _panel.isVisible;
}

- (void)openForItems:(NSArray *)items {
    self.items = items;
    [self resolveAssetFromItems];
    [self reloadAdjustmentInfoFromAsset];
    [self ensurePanel];
    [self rebuildControls];
    [self refreshControlValues];
    [_panel makeKeyAndOrderFront:nil];
}

- (void)closeHUD {
    [_panel orderOut:nil];
}

- (void)resolveAssetFromItems {
    self.currentAsset = nil;
    self.currentPath = nil;
    for (id item in _items) {
        id asset = SpliceKitBRAWHudResolveAsset(item);
        if (!asset) continue;
        NSString *path = SpliceKitBRAWHudNormalizedPath(asset);
        if (path.length == 0) path = SpliceKitBRAWHudNormalizedPath(item);
        if (path.length > 0) {
            self.currentAsset = asset;
            self.currentPath = path;
            return;
        }
    }
}

- (void)reloadAdjustmentInfoFromAsset {
    NSDictionary *top = nil;
    if ([_currentAsset respondsToSelector:@selector(rawProcessorSettings)]) {
        id raw = ((id (*)(id, SEL))objc_msgSend)(_currentAsset, @selector(rawProcessorSettings));
        if ([raw isKindOfClass:[NSDictionary class]]) top = raw;
    }
    self.adjustmentInfo = [SpliceKitBRAWAdjustmentInfo infoFromRawProcessorSettings:top];
}

#pragma mark Panel construction

- (void)ensurePanel {
    if (_panel) return;

    // Match the ProRes RAW Settings panel: titled utility window (NOT HUD),
    // centered title bar with close button on the left, clip name + subtitle
    // centered below, then an inset rounded NSBox containing the controls.
    NSRect frame = NSMakeRect(0, 0, 540, 760);
    NSPanel *panel = [[NSPanel alloc] initWithContentRect:frame
                                                styleMask:(NSWindowStyleMaskTitled |
                                                           NSWindowStyleMaskClosable |
                                                           NSWindowStyleMaskUtilityWindow)
                                                  backing:NSBackingStoreBuffered
                                                    defer:YES];
    panel.title = @"BRAW Settings";
    panel.floatingPanel = YES;
    panel.becomesKeyOnlyIfNeeded = YES;
    panel.hidesOnDeactivate = NO;
    panel.delegate = self;
    self.panel = panel;

    NSView *content = [[NSView alloc] initWithFrame:frame];
    content.wantsLayer = YES;
    panel.contentView = content;

    // Centered clip name (large, primary).
    NSTextField *itemLabel = [NSTextField labelWithString:@"No BRAW clip selected"];
    itemLabel.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
    itemLabel.textColor = [NSColor labelColor];
    itemLabel.alignment = NSTextAlignmentCenter;
    itemLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    itemLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:itemLabel];
    self.itemLabel = itemLabel;

    // Subtitle: matches "Modifications will affect all clips that reference this media."
    NSTextField *subtitle = [NSTextField labelWithString:
        @"Modifications will affect all clips that reference this media."];
    subtitle.font = [NSFont systemFontOfSize:11];
    subtitle.textColor = [NSColor secondaryLabelColor];
    subtitle.alignment = NSTextAlignmentCenter;
    subtitle.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:subtitle];
    self.subtitleLabel = subtitle;

    // Inset rounded form panel (the dark grouped container).
    NSBox *formBox = [[NSBox alloc] initWithFrame:NSZeroRect];
    formBox.boxType = NSBoxCustom;
    formBox.borderType = NSLineBorder;
    formBox.borderColor = [NSColor separatorColor];
    formBox.borderWidth = 0.5;
    formBox.cornerRadius = 6.0;
    formBox.fillColor = [NSColor.controlBackgroundColor colorWithAlphaComponent:0.5];
    formBox.titlePosition = NSNoTitle;
    formBox.contentViewMargins = NSMakeSize(0, 0);
    formBox.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:formBox];
    self.formBox = formBox;

    // Grid lives inside the form box.
    NSGridView *grid = [[NSGridView alloc] initWithFrame:NSZeroRect];
    grid.translatesAutoresizingMaskIntoConstraints = NO;
    grid.rowAlignment = NSGridRowAlignmentFirstBaseline;
    grid.columnSpacing = 10.0;
    grid.rowSpacing = 7.0;
    [formBox.contentView addSubview:grid];
    self.grid = grid;

    [NSLayoutConstraint activateConstraints:@[
        [itemLabel.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:20],
        [itemLabel.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-20],
        [itemLabel.topAnchor constraintEqualToAnchor:content.topAnchor constant:14],

        [subtitle.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:20],
        [subtitle.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-20],
        [subtitle.topAnchor constraintEqualToAnchor:itemLabel.bottomAnchor constant:6],

        [formBox.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:14],
        [formBox.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-14],
        [formBox.topAnchor constraintEqualToAnchor:subtitle.bottomAnchor constant:14],
        [formBox.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-14],

        [grid.topAnchor constraintEqualToAnchor:formBox.contentView.topAnchor constant:14],
        [grid.leadingAnchor constraintEqualToAnchor:formBox.contentView.leadingAnchor constant:14],
        [grid.trailingAnchor constraintEqualToAnchor:formBox.contentView.trailingAnchor constant:14],
        [grid.bottomAnchor constraintLessThanOrEqualToAnchor:formBox.contentView.bottomAnchor constant:-14],
    ]];
}

- (void)rebuildControls {
    // ORDER MATTERS — remove the grid's rows FIRST, sweep stray subviews
    // SECOND. See crash 2026-04-17 16:20 — removeRowAtIndex: asserts if the
    // tracked views aren't in the grid's subviews list anymore. The
    // follow-up subview sweep is still required because removeRowAtIndex:
    // only detaches the row from the layout (causes the stacked-sliders
    // bug otherwise).
    while (_grid.numberOfRows > 0) {
        [_grid removeRowAtIndex:0];
    }
    for (NSView *sub in [_grid.subviews copy]) {
        [sub removeFromSuperview];
    }
    [_controlByKey removeAllObjects];
    [_readoutByKey removeAllObjects];
    [_revertButtonByKey removeAllObjects];

    self.itemLabel.stringValue = _currentPath.length > 0
        ? _currentPath.lastPathComponent
        : @"No BRAW clip selected";

    NSArray<SpliceKitBRAWControlDescriptor *> *descriptors = SpliceKitBRAWBuildDescriptors();
    for (SpliceKitBRAWControlDescriptor *d in descriptors) {
        // Section headers — small spacer rows with optional bold label.
        if (d.kind == SpliceKitBRAWControlKindSection) {
            NSTextField *spacer = [NSTextField labelWithString:@""];
            spacer.translatesAutoresizingMaskIntoConstraints = NO;
            [spacer.heightAnchor constraintEqualToConstant:4].active = YES;
            [_grid addRowWithViews:@[ spacer, [[NSView alloc] init], [[NSView alloc] init], [[NSView alloc] init] ]];
            continue;
        }

        // Right-aligned label with trailing colon — matches Inspector style.
        NSString *labelText = [NSString stringWithFormat:@"%@:", d.label];
        NSTextField *label = [NSTextField labelWithString:labelText];
        label.font = [NSFont systemFontOfSize:12];
        label.textColor = [NSColor labelColor];
        label.alignment = NSTextAlignmentRight;

        NSView *control = [self newControlForDescriptor:d];
        NSTextField *readout = [NSTextField labelWithString:@""];
        readout.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular];
        readout.textColor = [NSColor secondaryLabelColor];
        readout.alignment = NSTextAlignmentRight;

        // SF Symbol revert button — matches the curved-arrow icon ProRes RAW
        // shows at the right edge of every row.
        //
        // Critical: bordered=NO + buttonType=MomentaryChange + NO bezelStyle.
        // Setting bezelStyle (especially Inline) gives the button an accent-
        // tinted pill bezel instead of a flat icon — that was the source of
        // the purple double-chevron look in the 2026-04-17 16:37 screenshot.
        NSButton *revert = [[NSButton alloc] initWithFrame:NSZeroRect];
        revert.image = [self revertSymbolImage];
        revert.imagePosition = NSImageOnly;
        revert.bordered = NO;
        [revert setButtonType:NSButtonTypeMomentaryChange];
        revert.target = self;
        revert.action = @selector(revertFieldPressed:);
        revert.identifier = d.key;
        revert.toolTip = @"Reset to default";
        revert.contentTintColor = [NSColor tertiaryLabelColor];
        revert.translatesAutoresizingMaskIntoConstraints = NO;
        // 36×24 frame — the curve overshoot on the SF Symbol's right side
        // needs ~4-6pt of extra horizontal padding beyond the nominal glyph
        // box, otherwise it clips against the form-box border (screenshots
        // 2026-04-17 16:39 + 16:42 both showed the right tail clipped at
        // smaller widths).
        [revert.widthAnchor constraintEqualToConstant:36].active = YES;
        [revert.heightAnchor constraintEqualToConstant:24].active = YES;

        [_grid addRowWithViews:@[ label, control, readout, revert ]];
        if (d.key.length > 0) {
            _controlByKey[d.key] = control;
            _readoutByKey[d.key] = readout;
            _revertButtonByKey[d.key] = revert;
        }
    }
    // Column widths — matches ProRes RAW Settings: wide-enough labels,
    // generous slider column, monospaced readout, fixed icon button.
    [_grid columnAtIndex:0].width = 160.0;
    [_grid columnAtIndex:1].width = 220.0;
    [_grid columnAtIndex:2].width = 60.0;
    [_grid columnAtIndex:3].width = 44.0;
}

- (NSImage *)revertSymbolImage {
    if (@available(macOS 11.0, *)) {
        NSImage *img = [NSImage imageWithSystemSymbolName:@"arrow.uturn.backward"
                                accessibilityDescription:@"Reset"];
        if (img) {
            // 13pt regular medium-scale matches the visible size of ProRes
            // RAW's revert glyph. Smaller scales clip the curved tail in
            // a 22-pt frame; medium uses the full glyph extent.
            NSImageSymbolConfiguration *cfg =
                [NSImageSymbolConfiguration configurationWithPointSize:13
                                                                weight:NSFontWeightRegular
                                                                 scale:NSImageSymbolScaleMedium];
            img = [img imageWithSymbolConfiguration:cfg] ?: img;
            // -setTemplate: instead of `.template` because the latter collides
            // with the C++ `template` keyword in this .mm file.
            [img setTemplate:YES];
            return img;
        }
    }
    // Fallback for pre-Big Sur (unreachable in our deployment but kept for
    // completeness): an unstyled label-as-image. Not pretty.
    return [NSImage imageNamed:NSImageNameRefreshTemplate];
}

- (NSView *)newControlForDescriptor:(SpliceKitBRAWControlDescriptor *)d {
    switch (d.kind) {
        case SpliceKitBRAWControlKindSlider: {
            NSSlider *slider = [NSSlider sliderWithValue:d.defaultValue
                                               minValue:d.minValue
                                               maxValue:d.maxValue
                                                 target:self
                                                 action:@selector(sliderChanged:)];
            slider.continuous = YES;
            slider.identifier = d.key;
            // Tick marks below the bar match ProRes RAW Settings exactly.
            slider.numberOfTickMarks = 5;
            slider.tickMarkPosition = NSTickMarkPositionBelow;
            slider.allowsTickMarkValuesOnly = NO;
            [slider setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                             forOrientation:NSLayoutConstraintOrientationHorizontal];
            return slider;
        }
        case SpliceKitBRAWControlKindPopupNumeric: {
            NSPopUpButton *popup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
            popup.target = self;
            popup.action = @selector(popupChanged:);
            popup.identifier = d.key;
            for (NSNumber *value in d.popupValues) {
                NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:value.stringValue
                                                              action:nil
                                                       keyEquivalent:@""];
                item.representedObject = value;
                [popup.menu addItem:item];
            }
            return popup;
        }
        case SpliceKitBRAWControlKindPopupString: {
            NSPopUpButton *popup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
            popup.target = self;
            popup.action = @selector(popupChanged:);
            popup.identifier = d.key;
            for (NSString *value in d.popupStrings) {
                // Keep the pull-down title compact — strip the "Blackmagic Design"
                // prefix the SDK uses for its built-in gamma/gamut names.
                NSString *displayTitle = value;
                if ([value hasPrefix:@"Blackmagic Design "]) {
                    displayTitle = [value substringFromIndex:[@"Blackmagic Design " length]];
                    if (displayTitle.length == 0) displayTitle = @"Default";
                }
                NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:displayTitle
                                                              action:nil
                                                       keyEquivalent:@""];
                item.representedObject = value;
                [popup.menu addItem:item];
            }
            return popup;
        }
        case SpliceKitBRAWControlKindCheckbox: {
            NSButton *checkbox = [NSButton checkboxWithTitle:@""
                                                      target:self
                                                      action:@selector(checkboxChanged:)];
            checkbox.identifier = d.key;
            return checkbox;
        }
        case SpliceKitBRAWControlKindSection:
            return [[NSView alloc] init];
    }
    return [[NSView alloc] init];
}

#pragma mark Value <-> control sync

- (double)effectiveNumericValueForDescriptor:(SpliceKitBRAWControlDescriptor *)d {
    NSNumber *stored = [_adjustmentInfo valueForBRAWKey:d.key];
    if (stored) return stored.doubleValue;
    if ([d.key isEqualToString:SpliceKitBRAWKeyISO]    && _adjustmentInfo.asShotISO    > 0) return _adjustmentInfo.asShotISO;
    if ([d.key isEqualToString:SpliceKitBRAWKeyKelvin] && _adjustmentInfo.asShotKelvin > 0) return _adjustmentInfo.asShotKelvin;
    if ([d.key isEqualToString:SpliceKitBRAWKeyTint])                                     return _adjustmentInfo.asShotTint;
    return d.defaultValue;
}

- (NSString *)effectiveStringValueForDescriptor:(SpliceKitBRAWControlDescriptor *)d {
    id stored = _adjustmentInfo.settings[d.key];
    if ([stored isKindOfClass:[NSString class]]) return (NSString *)stored;
    return d.defaultString ?: @"";
}

- (void)refreshControlValues {
    self.suppressActions = YES;
    NSArray<SpliceKitBRAWControlDescriptor *> *descriptors = SpliceKitBRAWBuildDescriptors();
    for (SpliceKitBRAWControlDescriptor *d in descriptors) {
        if (d.kind == SpliceKitBRAWControlKindSection) continue;
        id control = _controlByKey[d.key];
        NSTextField *readout = _readoutByKey[d.key];

        if (d.kind == SpliceKitBRAWControlKindPopupString) {
            NSString *value = [self effectiveStringValueForDescriptor:d];
            NSPopUpButton *popup = (NSPopUpButton *)control;
            NSInteger pickIndex = 0;
            for (NSInteger i = 0; i < popup.numberOfItems; ++i) {
                if ([(NSString *)[popup itemAtIndex:i].representedObject isEqualToString:value]) {
                    pickIndex = i;
                    break;
                }
            }
            [popup selectItemAtIndex:pickIndex];
            readout.stringValue = @"";
            continue;
        }

        double value = [self effectiveNumericValueForDescriptor:d];
        if ([control isKindOfClass:[NSSlider class]]) {
            NSSlider *slider = (NSSlider *)control;
            slider.doubleValue = value;
        } else if ([control isKindOfClass:[NSPopUpButton class]]) {
            NSPopUpButton *popup = (NSPopUpButton *)control;
            NSInteger bestIndex = 0;
            double bestDelta = INFINITY;
            for (NSInteger i = 0; i < popup.numberOfItems; ++i) {
                NSNumber *v = (NSNumber *)[popup itemAtIndex:i].representedObject;
                double delta = fabs(v.doubleValue - value);
                if (delta < bestDelta) { bestDelta = delta; bestIndex = i; }
            }
            [popup selectItemAtIndex:bestIndex];
        } else if ([control isKindOfClass:[NSButton class]]) {
            ((NSButton *)control).state = value != 0 ? NSControlStateValueOn : NSControlStateValueOff;
        }
        readout.stringValue = [self formattedValue:value descriptor:d];
    }
    self.suppressActions = NO;
}

- (NSString *)formattedValue:(double)value descriptor:(SpliceKitBRAWControlDescriptor *)d {
    if (d.format.length == 0) return [NSString stringWithFormat:@"%.2f", value];
    return [NSString stringWithFormat:d.format, value];
}

#pragma mark Actions

- (void)sliderChanged:(NSSlider *)sender {
    if (_suppressActions) return;
    NSString *key = sender.identifier;
    if (key.length == 0) return;
    [self commitValue:@(sender.doubleValue) forKey:key];
}

- (void)popupChanged:(NSPopUpButton *)sender {
    if (_suppressActions) return;
    NSString *key = sender.identifier;
    if (key.length == 0) return;
    id value = sender.selectedItem.representedObject;
    if ([value isKindOfClass:[NSNumber class]] || [value isKindOfClass:[NSString class]]) {
        [self commitValue:value forKey:key];
    }
}

- (void)checkboxChanged:(NSButton *)sender {
    if (_suppressActions) return;
    NSString *key = sender.identifier;
    if (key.length == 0) return;
    [self commitValue:@(sender.state == NSControlStateValueOn) forKey:key];
}

// Per-row revert button — clears the override for that key, reverting to
// the BRAW SDK default (or the as-shot value when applicable).
- (void)revertFieldPressed:(NSButton *)sender {
    NSString *key = sender.identifier;
    if (key.length == 0) return;
    self.adjustmentInfo = [self.adjustmentInfo infoBySetting:key value:nil];
    [self writeSettingsToAssetAndCache];
    [self refreshControlValues];
}

- (void)resetAllPressed:(id)sender {
    SpliceKitBRAWHudRunInUndoAction(@"Reset BRAW Settings", ^{
        self.adjustmentInfo = [SpliceKitBRAWAdjustmentInfo infoWithSettings:nil];
        [self writeSettingsToAssetAndCache];
    });
    [self refreshControlValues];
}

- (void)closePressed:(id)sender {
    [self closeHUD];
}

- (void)commitValue:(id)value forKey:(NSString *)key {
    NSTimeInterval t0 = [NSDate timeIntervalSinceReferenceDate];

    SpliceKitBRAWControlDescriptor *descriptor = nil;
    for (SpliceKitBRAWControlDescriptor *d in SpliceKitBRAWBuildDescriptors()) {
        if ([d.key isEqualToString:key]) { descriptor = d; break; }
    }

    SpliceKitBRAWHudRunInUndoAction(@"Modify BRAW Settings", ^{
        self.adjustmentInfo = [self.adjustmentInfo infoBySetting:key value:value];
        [self writeSettingsToAssetAndCache];
    });

    NSTimeInterval t1 = [NSDate timeIntervalSinceReferenceDate];
    FILE *f = fopen("/tmp/splicekit-braw.log", "a");
    if (f) {
        fprintf(f, "%s [perf] commitValue %s=%s sliderChanged→cacheWritten=%.1fms\n",
            [NSDate date].description.UTF8String,
            key.UTF8String,
            [value description].UTF8String,
            (t1 - t0) * 1000);
        fclose(f);
    }

    // Live readout update without rebuilding the whole grid. String popups
    // don't show a numeric readout — leave the readout empty.
    NSTextField *readout = _readoutByKey[key];
    if (descriptor && [value isKindOfClass:[NSNumber class]]) {
        readout.stringValue = [self formattedValue:[(NSNumber *)value doubleValue] descriptor:descriptor];
    } else {
        readout.stringValue = @"";
    }
}

- (void)writeSettingsToAssetAndCache {
    // PART 1 — live cache write (every tick)
    //
    // The host-side BRAW decoder reads SpliceKitBRAWRAWSettingsMap per decode
    // job. Writing here is cheap, NSLock-protected, and never races with FCP's
    // own state. The viewer reflects the change on the next decoded frame.
    if (_currentPath.length > 0) {
        NSDictionary *settings = _adjustmentInfo.settings;
        if (settings.count > 0) {
            SpliceKitBRAW_SetRAWSettingsForPath((__bridge CFStringRef)_currentPath,
                                                (__bridge CFDictionaryRef)settings);
        } else {
            SpliceKitBRAW_SetRAWSettingsForPath((__bridge CFStringRef)_currentPath, NULL);
        }
    }

    // PART 2 — coalesced asset persistence (~150ms after last edit)
    //
    // Writing FFAsset.rawProcessorSettings on every slider tick caused a
    // crash (BG thumbnail thread reading FFAsset._copyVideoOverridesDict
    // raced our dict swap; objc_retain'd a freed value — see crash 2026-04-17
    // 15:31 + 15:58 at /Users/briantate/Library/Logs/DiagnosticReports/).
    // The race is a pre-existing FCP issue but we trigger it by mutating at
    // every continuous-slider tick. The OLD VT-RAW path didn't hit it because
    // FCP itself drove the writes inside its own action context.
    //
    // Fix: coalesce. Bump a generation counter, schedule a delayed dispatch;
    // when it fires, only run if generation hasn't moved. Slider drags cancel
    // pending writes and only the final value gets persisted.
    [self schedulePersistAssetWrite];
}

// Generation counter to coalesce asset writes during slider drags. Each
// schedulePersistAssetWrite bumps this; the deferred block only runs if
// no newer write came in. 350ms delay is long enough that the slider's
// continuous events all settle on the same generation, but short enough
// that the user perceives "instant" persistence after they release the
// mouse.
- (void)schedulePersistAssetWrite {
    static NSUInteger sGeneration = 0;
    NSUInteger myGen = ++sGeneration;
    __weak SpliceKitBRAWSettingsHud *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (myGen != sGeneration) return; // newer write coalesced this one
        [weakSelf persistAssetSettingsNow];
    });
}

- (void)persistAssetSettingsNow {
    if (!_currentAsset || ![_currentAsset respondsToSelector:@selector(setRawProcessorSettings:)]) return;
    NSTimeInterval t0 = [NSDate timeIntervalSinceReferenceDate];
    id base = nil;
    if ([_currentAsset respondsToSelector:@selector(rawProcessorSettings)]) {
        base = ((id (*)(id, SEL))objc_msgSend)(_currentAsset, @selector(rawProcessorSettings));
    }
    NSDictionary *baseDict = [base isKindOfClass:[NSDictionary class]] ? base : nil;
    NSDictionary *merged = [_adjustmentInfo mergedIntoRawProcessorSettings:baseDict];
    ((void (*)(id, SEL, id))objc_msgSend)(_currentAsset,
                                          @selector(setRawProcessorSettings:),
                                          merged);
    NSTimeInterval t1 = [NSDate timeIntervalSinceReferenceDate];
    SpliceKitBRAWHudForceRefresh(_currentAsset);
    NSTimeInterval t2 = [NSDate timeIntervalSinceReferenceDate];
    FILE *f = fopen("/tmp/splicekit-braw.log", "a");
    if (f) {
        fprintf(f, "%s [perf] persistAsset setRPS=%.1fms forceRefresh-dispatch=%.1fms\n",
            [NSDate date].description.UTF8String,
            (t1 - t0) * 1000, (t2 - t1) * 1000);
        fclose(f);
    }
}

#pragma mark NSWindowDelegate

- (void)windowWillClose:(NSNotification *)notification {
    // Nothing special — the singleton keeps its state for next open.
}

@end
