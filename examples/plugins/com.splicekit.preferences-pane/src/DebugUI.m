//
//  DebugUI.m
//  com.splicekit.preferences-pane
//
//  Rebuilds FCP's hidden Debug preferences pane programmatically.
//  Survives SpliceKit patcher updates — the entire feature lives here.
//
//  The Debug preferences module (PEAppDebugPreferencesModule) is still compiled
//  into FCP, but Apple strips PEAppDebugPreferencesModule.nib from the bundle
//  during release builds. At runtime LKPreferences calls addPreferenceNamed:owner:
//  which tries to load the NIB via preferencesNibName and silently drops the
//  module when it fails.
//
//  We work around the silent filter by:
//    1. Building the view in code (no NIB needed).
//    2. Calling setPreferencesView: on the module so it owns our view.
//    3. Mutating LKPreferences' internal arrays/dictionary directly to add the
//       Debug pane to _preferenceTitles, _preferenceModules, and
//       _masterPreferenceViews.
//
//  (The Debug top-level menu bar reconstruction that used to live alongside
//  this — SpliceKit_installDebugMenuBar — is intentionally not ported here:
//  it was already disabled at every launch in the core dylib and unused.)
//

#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import "SKPluginShared.h"

// Minimal forward declaration — the real SpliceKitLogPanel class lives in the
// core dylib. Only the two methods used below need to be declared for the
// compiler; resolution happens at load time via -undefined dynamic_lookup.
@interface SpliceKitLogPanel : NSObject
+ (instancetype)sharedPanel;
- (void)showPanel;
- (void)hidePanel;
@end

#pragma mark - Shared Helpers

// Some NSUserDefaults keys we need to read from the same helper set that
// SpliceKitServer already curates. Duplicating a tiny subset here keeps this
// file standalone rather than pulling in the server's header surface.
static NSArray<NSString *> *SKDebug_tlkVisualFlags(void) {
    return @[
        @"TLKShowItemLaneIndex",
        @"TLKShowMisalignedEdges",
        @"TLKShowRenderBar",
        @"TLKShowHiddenGapItems",
        @"TLKShowHiddenItemHeaders",
        @"TLKShowInvalidLayoutRects",
        @"TLKShowContainerBounds",
        @"TLKShowContentLayers",
        @"TLKShowRulerBounds",
        @"TLKShowUsedRegion",
        @"TLKShowZeroHeightSpineItems",
        @"TLKDebugColorChangedObjects",
    ];
}

static NSArray<NSString *> *SKDebug_tlkLoggingFlags(void) {
    return @[
        @"TLKLogVisibleLayerChanges",
        @"TLKLogParts",
        @"TLKLogReloadRequests",
        @"TLKLogRecyclingLayerChanges",
        @"TLKLogVisibleRectChanges",
        @"TLKLogSegmentationStatistics",
    ];
}

static NSArray<NSString *> *SKDebug_renderFlags(void) {
    return @[
        @"TLKPerformanceMonitorEnabled",
        @"TLKDisableItemContents",
        @"DebugKeyItemVideoFilmstripsDisabled",
        @"DebugKeyItemBackgroundDisabled",
        @"DebugKeyItemAudioWaveformsDisabled",
        @"GPU_LOGGING",
    ];
}

static NSArray<NSString *> *SKDebug_fcpBehaviorFlags(void) {
    // FFDontCoalesceGaps lives in the SpliceKit preferences pane — omit here.
    return @[
        @"FFDisableSnapping",
        @"FFDisableSkimming",
    ];
}

static NSArray<NSString *> *SKDebug_logLevelNames(void) {
    return @[@"trace", @"debug", @"info", @"warning", @"error", @"failure"];
}

static NSString *SKDebug_humanizeKey(NSString *key) {
    // TLKShowHiddenGapItems -> "Show Hidden Gap Items"
    if ([key hasPrefix:@"TLK"]) key = [key substringFromIndex:3];
    if ([key hasPrefix:@"DebugKey"]) key = [key substringFromIndex:8];
    if ([key hasPrefix:@"FF"]) key = [key substringFromIndex:2];
    NSMutableString *out = [NSMutableString string];
    for (NSUInteger i = 0; i < key.length; i++) {
        unichar c = [key characterAtIndex:i];
        if (i > 0 && c >= 'A' && c <= 'Z') {
            unichar prev = [key characterAtIndex:i - 1];
            if (prev >= 'a' && prev <= 'z') [out appendString:@" "];
        }
        [out appendFormat:@"%C", c];
    }
    return out;
}

// Sender-agnostic key lookup. NSView subclasses (NSButton, NSPopUpButton) use
// `identifier`; NSMenuItem uses `representedObject`. This returns whichever
// is set so action methods can be shared between views and menu items.
static NSString *SKDebug_senderKey(id sender) {
    if ([sender isKindOfClass:[NSMenuItem class]]) {
        id obj = [(NSMenuItem *)sender representedObject];
        if ([obj isKindOfClass:[NSString class]]) return obj;
    }
    if ([sender isKindOfClass:[NSView class]]) {
        return [(NSView *)sender identifier];
    }
    return nil;
}

// After we change flags, reload FCP's TLK cache so they take effect live.
static void SKDebug_reloadTLKIfPossible(void) {
    Class tlkClass = NSClassFromString(@"TLKUserDefaults");
    if (tlkClass) {
        SEL sel = NSSelectorFromString(@"_loadUserDefaults");
        if ([tlkClass respondsToSelector:sel]) {
            ((void (*)(id, SEL))objc_msgSend)(tlkClass, sel);
        }
    }
}

static NSInteger SKDebug_currentLogLevelIndex(void) {
    id raw = [[NSUserDefaults standardUserDefaults] objectForKey:@"LogLevel"];
    if (!raw) return 2;  // FCP defaults to "info" when unset.
    NSInteger level = [raw integerValue];
    if (level < 0 || level >= (NSInteger)SKDebug_logLevelNames().count) return 2;
    return level;
}

static id SKDebug_vamlDebugMenu(void) {
    Class vamlClass = objc_getClass("FFVAMLDebugMenu");
    if (!vamlClass || ![vamlClass respondsToSelector:@selector(instance)]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(vamlClass, @selector(instance));
}

static NSInteger SKDebug_vamlMenuItemState(NSString *getterName, NSString *defaultsKey) {
    id vaml = SKDebug_vamlDebugMenu();
    SEL getter = NSSelectorFromString(getterName);
    if (vaml && [vaml respondsToSelector:getter]) {
        id item = ((id (*)(id, SEL))objc_msgSend)(vaml, getter);
        if ([item respondsToSelector:@selector(state)]) {
            return ((NSInteger (*)(id, SEL))objc_msgSend)(item, @selector(state));
        }
    }

    if (defaultsKey.length > 0) {
        return [[NSUserDefaults standardUserDefaults] boolForKey:defaultsKey]
            ? NSControlStateValueOn : NSControlStateValueOff;
    }
    return NSControlStateValueOff;
}

#pragma mark - Controller (owns targets for all actions)

@interface SpliceKitDebugController : NSObject <NSMenuDelegate>
+ (instancetype)shared;
@property (nonatomic, weak) NSMenuItem *debugMenuItem;  // the top-level bar item
@property (nonatomic, strong) id debugPrefsModule;      // PEAppDebugPreferencesModule instance
@property (nonatomic, strong) NSView *debugPrefsView;   // our programmatic view
@end

@implementation SpliceKitDebugController

+ (instancetype)shared {
    static SpliceKitDebugController *instance = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [[self alloc] init]; });
    return instance;
}

#pragma mark Checkbox actions

- (void)toggleBoolDefault:(id)sender {
    if (![sender isKindOfClass:[NSButton class]] && ![sender isKindOfClass:[NSMenuItem class]]) return;
    NSString *key = SKDebug_senderKey(sender);
    if (key.length == 0) return;

    BOOL current = [[NSUserDefaults standardUserDefaults] boolForKey:key];
    BOOL newValue = !current;
    [[NSUserDefaults standardUserDefaults] setBool:newValue forKey:key];
    [[NSUserDefaults standardUserDefaults] synchronize];

    if ([sender isKindOfClass:[NSButton class]]) {
        [(NSButton *)sender setState:newValue ? NSControlStateValueOn : NSControlStateValueOff];
    } else {
        [(NSMenuItem *)sender setState:newValue ? NSControlStateValueOn : NSControlStateValueOff];
    }

    if ([key isEqualToString:@"LogUI"]) {
        if (newValue) [[SpliceKitLogPanel sharedPanel] showPanel];
        else [[SpliceKitLogPanel sharedPanel] hidePanel];
    }

    SKDebug_reloadTLKIfPossible();
    SpliceKit_log(@"Debug flag %@ -> %@", key, newValue ? @"YES" : @"NO");
}

- (void)setLogLevel:(id)sender {
    NSInteger level = -1;
    if ([sender isKindOfClass:[NSPopUpButton class]]) {
        level = [(NSPopUpButton *)sender indexOfSelectedItem];
    } else if ([sender isKindOfClass:[NSMenuItem class]]) {
        level = [(NSMenuItem *)sender tag];
    }
    if (level < 0 || level >= (NSInteger)SKDebug_logLevelNames().count) return;
    [[NSUserDefaults standardUserDefaults] setInteger:level forKey:@"LogLevel"];
    [[NSUserDefaults standardUserDefaults] synchronize];

    if ([sender isKindOfClass:[NSMenuItem class]]) {
        NSMenu *menu = [(NSMenuItem *)sender menu];
        for (NSMenuItem *item in menu.itemArray) {
            item.state = (item.tag == level) ? NSControlStateValueOn : NSControlStateValueOff;
        }
    }

    SpliceKit_log(@"ProAppSupport LogLevel -> %@", SKDebug_logLevelNames()[level]);
}

- (void)setIntDefault:(id)sender {
    // Used by CFPreferences integer popups (VideoDecoderLogLevelInNLE, FrameDropLogLevel).
    // The view's identifier stores the CFPreferences key; the popup's selected
    // index is the integer value (since items are titled 0..5).
    if (![sender isKindOfClass:[NSPopUpButton class]]) return;
    NSPopUpButton *popup = sender;
    NSString *key = SKDebug_senderKey(popup);
    if (key.length == 0) return;
    NSInteger value = popup.indexOfSelectedItem;
    CFPreferencesSetAppValue((__bridge CFStringRef)key,
                             (__bridge CFPropertyListRef)@(value),
                             kCFPreferencesCurrentApplication);
    CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication);
    SpliceKit_log(@"CFPreferences %@ -> %ld", key, (long)value);
}

#pragma mark Preset actions

- (void)applyPreset:(id)sender {
    NSString *preset = SKDebug_senderKey(sender);
    if (preset.length == 0) return;

    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    void (^set)(NSString *, BOOL) = ^(NSString *key, BOOL val) {
        [d setBool:val forKey:key];
    };

    if ([preset isEqualToString:@"timeline_visual"]) {
        set(@"TLKShowItemLaneIndex", YES);
        set(@"TLKShowMisalignedEdges", YES);
        set(@"TLKShowRenderBar", YES);
        set(@"TLKShowHiddenGapItems", YES);
        set(@"TLKShowInvalidLayoutRects", YES);
        set(@"TLKDebugColorChangedObjects", YES);
    } else if ([preset isEqualToString:@"timeline_logging"]) {
        for (NSString *k in SKDebug_tlkLoggingFlags()) set(k, YES);
    } else if ([preset isEqualToString:@"performance"]) {
        set(@"TLKPerformanceMonitorEnabled", YES);
        CFPreferencesSetAppValue(CFSTR("VideoDecoderLogLevelInNLE"),
                                 (__bridge CFPropertyListRef)@(2),
                                 kCFPreferencesCurrentApplication);
        CFPreferencesSetAppValue(CFSTR("FrameDropLogLevel"),
                                 (__bridge CFPropertyListRef)@(2),
                                 kCFPreferencesCurrentApplication);
        CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication);
    } else if ([preset isEqualToString:@"render_debug"]) {
        set(@"DebugKeyItemVideoFilmstripsDisabled", YES);
        set(@"DebugKeyItemBackgroundDisabled", YES);
        set(@"DebugKeyItemAudioWaveformsDisabled", YES);
        set(@"TLKDisableItemContents", YES);
        set(@"GPU_LOGGING", YES);
    } else if ([preset isEqualToString:@"verbose_logging"]) {
        [d setInteger:0 forKey:@"LogLevel"];
        set(@"LogUI", YES);
        set(@"LogThread", YES);
        set(@"EnableScheduledReadAudioLogging", YES);
    } else if ([preset isEqualToString:@"all_off"]) {
        for (NSString *k in SKDebug_tlkVisualFlags()) [d removeObjectForKey:k];
        for (NSString *k in SKDebug_tlkLoggingFlags()) [d removeObjectForKey:k];
        for (NSString *k in SKDebug_renderFlags()) [d removeObjectForKey:k];
        for (NSString *k in SKDebug_fcpBehaviorFlags()) [d removeObjectForKey:k];
        [d removeObjectForKey:@"LogLevel"];
        [d removeObjectForKey:@"LogUI"];
        [d removeObjectForKey:@"LogThread"];
        [d removeObjectForKey:@"LogCategory"];
        [d removeObjectForKey:@"EnableScheduledReadAudioLogging"];
        // Clear CFPreferences keys set by the performance preset and popup UI
        CFPreferencesSetAppValue(CFSTR("VideoDecoderLogLevelInNLE"), NULL,
                                 kCFPreferencesCurrentApplication);
        CFPreferencesSetAppValue(CFSTR("FrameDropLogLevel"), NULL,
                                 kCFPreferencesCurrentApplication);
        CFPreferencesSetAppValue(CFSTR("GPU_LOGGING"), NULL,
                                 kCFPreferencesCurrentApplication);
        CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication);
    }

    [d synchronize];
    SKDebug_reloadTLKIfPossible();
    SpliceKit_log(@"Applied debug preset: %@", preset);
}

#pragma mark FCP-native debug actions

- (void)toggleCGContextDraw:(id)sender {
    // FCP ships this selector as an empty stub in release builds, so keep
    // the behavior explicit instead of surfacing a dead-looking action.
    (void)sender;
    SpliceKit_log(@"PEAppController.toggleDebugCGContextDraw: is a no-op in this FCP build");
}

- (void)toggleSaveSearchResults:(id)sender {
    Class vamlClass = objc_getClass("FFVAMLDebugMenu");
    if (!vamlClass) return;
    id vaml = ((id (*)(id, SEL))objc_msgSend)(vamlClass, @selector(instance));
    SEL sel = NSSelectorFromString(@"toggleSaveSearchResults");
    if ([vaml respondsToSelector:sel]) {
        ((void (*)(id, SEL))objc_msgSend)(vaml, sel);
        if ([sender isKindOfClass:[NSMenuItem class]]) {
            [(NSMenuItem *)sender setState:SKDebug_vamlMenuItemState(@"saveSearchMenuItem", nil)];
        }
    }
}

- (void)toggleSaveTranscription:(id)sender {
    Class vamlClass = objc_getClass("FFVAMLDebugMenu");
    if (!vamlClass) return;
    id vaml = ((id (*)(id, SEL))objc_msgSend)(vamlClass, @selector(instance));
    SEL sel = NSSelectorFromString(@"toggleSaveTranscription");
    if ([vaml respondsToSelector:sel]) {
        ((void (*)(id, SEL))objc_msgSend)(vaml, sel);
        if ([sender isKindOfClass:[NSMenuItem class]]) {
            [(NSMenuItem *)sender setState:SKDebug_vamlMenuItemState(@"saveTranscriptionMenuItem",
                                                                    @"FFVAMLSaveTranscription")];
        }
    }
}

static const char kFramerateMonitorKey = '\0';

#pragma mark Framerate monitor

- (void)startFramerateMonitor:(id)sender {
    Class hmd = NSClassFromString(@"HMDFramerate");
    if (!hmd) {
        SpliceKit_log(@"HMDFramerate class not found");
        return;
    }
    id monitor = [[hmd alloc] init];
    SEL startSel = NSSelectorFromString(@"startLogging:");
    if ([monitor respondsToSelector:startSel]) {
        ((void (*)(id, SEL, float))objc_msgSend)(monitor, startSel, 2.0f);
        // Retain the monitor in an associated object so it's not deallocated.
        objc_setAssociatedObject(self, &kFramerateMonitorKey, monitor,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        SpliceKit_log(@"HMD framerate monitor started (2.0s interval). ProCore only logs while HMD rendering is active.");
    }
}

- (void)stopFramerateMonitor:(id)sender {
    id monitor = objc_getAssociatedObject(self, &kFramerateMonitorKey);
    if (!monitor) return;
    SEL stopSel = NSSelectorFromString(@"stopLogging");
    if ([monitor respondsToSelector:stopSel]) {
        ((void (*)(id, SEL))objc_msgSend)(monitor, stopSel);
    }
    objc_setAssociatedObject(self, &kFramerateMonitorKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    SpliceKit_log(@"Framerate monitor stopped");
}

#pragma mark User defaults reset (from the module's own clearUserDefaults:)

- (void)clearAllDebugFlags:(id)sender {
    // Uses the module's own clearUserDefaults: if we have a handle to it;
    // otherwise falls through to our own per-key clear.
    id module = self.debugPrefsModule;
    SEL sel = NSSelectorFromString(@"clearUserDefaults:");
    if (module && [module respondsToSelector:sel]) {
        ((void (*)(id, SEL, id))objc_msgSend)(module, sel, sender);
        return;
    }
    // Direct clear fallback — mirrors the all_off preset logic exactly.
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    for (NSString *k in SKDebug_tlkVisualFlags()) [d removeObjectForKey:k];
    for (NSString *k in SKDebug_tlkLoggingFlags()) [d removeObjectForKey:k];
    for (NSString *k in SKDebug_renderFlags()) [d removeObjectForKey:k];
    for (NSString *k in SKDebug_fcpBehaviorFlags()) [d removeObjectForKey:k];
    [d removeObjectForKey:@"LogLevel"];
    [d removeObjectForKey:@"LogUI"];
    [d removeObjectForKey:@"LogThread"];
    [d removeObjectForKey:@"LogCategory"];
    [d removeObjectForKey:@"EnableScheduledReadAudioLogging"];
    [d synchronize];
    // Clear CFPreferences keys
    CFPreferencesSetAppValue(CFSTR("VideoDecoderLogLevelInNLE"), NULL,
                             kCFPreferencesCurrentApplication);
    CFPreferencesSetAppValue(CFSTR("FrameDropLogLevel"), NULL,
                             kCFPreferencesCurrentApplication);
    CFPreferencesSetAppValue(CFSTR("GPU_LOGGING"), NULL,
                             kCFPreferencesCurrentApplication);
    CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication);
    SKDebug_reloadTLKIfPossible();
}

#pragma mark NSMenuDelegate — sync checkbox state with NSUserDefaults

- (void)menuNeedsUpdate:(NSMenu *)menu {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSInteger currentLogLevel = SKDebug_currentLogLevelIndex();
    for (NSMenuItem *item in menu.itemArray) {
        NSString *key = [item representedObject];
        if ([key isKindOfClass:[NSString class]] && [key length] > 0 && item.action == @selector(toggleBoolDefault:)) {
            BOOL on = [d boolForKey:key];
            item.state = on ? NSControlStateValueOn : NSControlStateValueOff;
        } else if (item.action == @selector(setLogLevel:)) {
            item.state = (item.tag == currentLogLevel) ? NSControlStateValueOn : NSControlStateValueOff;
        } else if (item.action == @selector(toggleSaveSearchResults:)) {
            item.state = SKDebug_vamlMenuItemState(@"saveSearchMenuItem", nil);
        } else if (item.action == @selector(toggleSaveTranscription:)) {
            item.state = SKDebug_vamlMenuItemState(@"saveTranscriptionMenuItem",
                                                   @"FFVAMLSaveTranscription");
        }
    }
}

@end

#pragma mark - Programmatic View Construction

// Builds a labeled checkbox row bound to a BOOL NSUserDefaults key.
static NSButton *SKDebug_makeCheckbox(NSString *key, NSString *title) {
    NSButton *cb = [NSButton checkboxWithTitle:title
                                        target:[SpliceKitDebugController shared]
                                        action:@selector(toggleBoolDefault:)];
    cb.identifier = key;  // toggleBoolDefault: reads this via SKDebug_senderKey
    cb.state = [[NSUserDefaults standardUserDefaults] boolForKey:key]
               ? NSControlStateValueOn : NSControlStateValueOff;
    cb.translatesAutoresizingMaskIntoConstraints = NO;
    return cb;
}

static NSTextField *SKDebug_makeSectionLabel(NSString *text) {
    NSTextField *label = [NSTextField labelWithString:text];
    label.font = [NSFont boldSystemFontOfSize:13];
    label.textColor = [NSColor labelColor];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    return label;
}

static NSTextField *SKDebug_makeNoteLabel(NSString *text) {
    NSTextField *label = [NSTextField labelWithString:text];
    label.font = [NSFont systemFontOfSize:11];
    label.textColor = [NSColor secondaryLabelColor];
    label.maximumNumberOfLines = 0;
    label.lineBreakMode = NSLineBreakByWordWrapping;
    label.preferredMaxLayoutWidth = 520.0;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    return label;
}

static NSBox *SKDebug_makeSeparator(void) {
    NSBox *box = [[NSBox alloc] initWithFrame:NSMakeRect(0, 0, 400, 1)];
    box.boxType = NSBoxSeparator;
    box.translatesAutoresizingMaskIntoConstraints = NO;
    return box;
}

// descriptions: key → human-readable explanation (may be nil for a given key).
static NSStackView *SKDebug_makeCheckboxGroup(NSArray<NSString *> *keys,
                                              NSDictionary<NSString *, NSString *> *descriptions) {
    NSStackView *stack = [NSStackView stackViewWithViews:@[]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 6;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    for (NSString *key in keys) {
        NSString *desc = descriptions[key];
        if (desc.length > 0) {
            NSStackView *row = [NSStackView stackViewWithViews:@[]];
            row.orientation = NSUserInterfaceLayoutOrientationVertical;
            row.alignment = NSLayoutAttributeLeading;
            row.spacing = 2;
            row.translatesAutoresizingMaskIntoConstraints = NO;
            [row addArrangedSubview:SKDebug_makeCheckbox(key, SKDebug_humanizeKey(key))];
            [row addArrangedSubview:SKDebug_makeNoteLabel(desc)];
            [stack addArrangedSubview:row];
        } else {
            [stack addArrangedSubview:SKDebug_makeCheckbox(key, SKDebug_humanizeKey(key))];
        }
    }
    return stack;
}

static NSButton *SKDebug_makePresetButton(NSString *title, NSString *preset) {
    NSButton *btn = [NSButton buttonWithTitle:title
                                       target:[SpliceKitDebugController shared]
                                       action:@selector(applyPreset:)];
    btn.identifier = preset;  // applyPreset: reads this via SKDebug_senderKey
    btn.bezelStyle = NSBezelStyleRounded;
    btn.translatesAutoresizingMaskIntoConstraints = NO;
    return btn;
}

// Build the entire Debug preferences content view. Returned view has a fixed
// intrinsic size so LKPreferences can size its window around it.
static NSView *SKDebug_buildDebugPrefsView(void) {
    const CGFloat kWidth = 560.0;

    // The root doc view for a scroll view — it grows vertically as we add sections.
    NSView *doc = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, kWidth, 1200)];
    doc.translatesAutoresizingMaskIntoConstraints = NO;

    NSStackView *root = [NSStackView stackViewWithViews:@[]];
    root.orientation = NSUserInterfaceLayoutOrientationVertical;
    root.alignment = NSLayoutAttributeLeading;
    root.spacing = 10;
    root.edgeInsets = NSEdgeInsetsMake(16, 20, 16, 20);
    root.translatesAutoresizingMaskIntoConstraints = NO;
    [doc addSubview:root];
    [NSLayoutConstraint activateConstraints:@[
        [root.topAnchor constraintEqualToAnchor:doc.topAnchor],
        [root.leadingAnchor constraintEqualToAnchor:doc.leadingAnchor],
        [root.trailingAnchor constraintEqualToAnchor:doc.trailingAnchor],
        [root.bottomAnchor constraintEqualToAnchor:doc.bottomAnchor],
    ]];

    // Header
    NSTextField *header = [NSTextField labelWithString:
        @"Debug — Reconstructed by SpliceKit. Flags mirror Final Cut Pro's "
        @"internal developer defaults (TLKUserDefaults, CFPreferences, "
        @"ProAppSupport log)."];
    header.font = [NSFont systemFontOfSize:11];
    header.textColor = [NSColor secondaryLabelColor];
    header.maximumNumberOfLines = 0;
    header.preferredMaxLayoutWidth = kWidth - 40;
    header.translatesAutoresizingMaskIntoConstraints = NO;
    [root addArrangedSubview:header];
    [root addArrangedSubview:SKDebug_makeSeparator()];

    // --- Timeline Visual Overlays ---
    [root addArrangedSubview:SKDebug_makeSectionLabel(@"Timeline Visual Overlays")];
    [root addArrangedSubview:SKDebug_makeCheckboxGroup(SKDebug_tlkVisualFlags(), @{
        @"TLKShowItemLaneIndex":      @"Shows the lane number on each timeline item — useful for understanding connected clip stacking order.",
        @"TLKShowMisalignedEdges":    @"Highlights item edges that are not pixel-aligned, which can cause sub-pixel rendering artefacts.",
        @"TLKShowRenderBar":          @"Shows the render status colour bar overlaid on the timeline ruler.",
        @"TLKShowHiddenGapItems":     @"Reveals gap items that FCP normally hides from view, exposing the true timeline data model.",
        @"TLKShowHiddenItemHeaders":  @"Reveals item header elements (role labels, etc.) that FCP hides in compact layouts.",
        @"TLKShowInvalidLayoutRects": @"Highlights rectangles where layout constraints could not be satisfied.",
        @"TLKShowContainerBounds":    @"Draws the bounding box of each timeline container (primary storyline, connected story lines).",
        @"TLKShowContentLayers":      @"Draws the boundary of each content layer within an item (video, audio, overlay).",
        @"TLKShowRulerBounds":        @"Shows the ruler overlay bounding box.",
        @"TLKShowUsedRegion":         @"Highlights the portion of each container that is actually occupied by items.",
        @"TLKShowZeroHeightSpineItems": @"Reveals spine items with zero height — normally invisible but present in the data model.",
        @"TLKDebugColorChangedObjects": @"Tints objects that changed during the last layout pass, making update propagation visible.",
    })];
    [root addArrangedSubview:SKDebug_makeSeparator()];

    // --- Timeline Logging ---
    [root addArrangedSubview:SKDebug_makeSectionLabel(@"Timeline Logging")];
    [root addArrangedSubview:SKDebug_makeCheckboxGroup(SKDebug_tlkLoggingFlags(), @{
        @"TLKLogVisibleLayerChanges":    @"Logs when visible layers are added, removed, or reordered (high volume during scrubbing).",
        @"TLKLogParts":                  @"Logs timeline part lifecycle events: load, layout, unload, recycle.",
        @"TLKLogReloadRequests":         @"Logs every request to reload or refresh timeline content.",
        @"TLKLogRecyclingLayerChanges":  @"Logs when layers are recycled between items to reduce allocation overhead.",
        @"TLKLogVisibleRectChanges":     @"Logs changes to the visible rectangle as the user scrolls or zooms.",
        @"TLKLogSegmentationStatistics": @"Logs statistics about how the timeline is segmented for rendering.",
    })];
    [root addArrangedSubview:SKDebug_makeSeparator()];

    // --- Performance & Rendering ---
    [root addArrangedSubview:SKDebug_makeSectionLabel(@"Performance & Rendering")];
    [root addArrangedSubview:SKDebug_makeCheckboxGroup(SKDebug_renderFlags(), @{
        @"TLKPerformanceMonitorEnabled":         @"Enables TLK's built-in overlay showing layout and render timings per frame.",
        @"TLKDisableItemContents":               @"Disables all item content rendering (video frames, waveforms, thumbnails). Useful for isolating UI performance from media decode.",
        @"DebugKeyItemVideoFilmstripsDisabled":  @"Disables video filmstrip thumbnail generation only, leaving waveforms and backgrounds intact.",
        @"DebugKeyItemBackgroundDisabled":       @"Disables the coloured background bar behind each clip.",
        @"DebugKeyItemAudioWaveformsDisabled":   @"Disables audio waveform drawing — can speed up rendering on large timelines.",
        @"GPU_LOGGING":                          @"Enables verbose GPU and FxPlug shader pipeline logging in the system log.",
    })];
    [root addArrangedSubview:SKDebug_makeSeparator()];

    // --- FCP Behavior Overrides ---
    [root addArrangedSubview:SKDebug_makeSectionLabel(@"FCP Behavior Overrides")];
    [root addArrangedSubview:SKDebug_makeCheckboxGroup(SKDebug_fcpBehaviorFlags(), @{
        @"FFDisableSnapping":  @"Disables magnetic snapping when moving or trimming clips. Useful when testing free-form positioning.",
        @"FFDisableSkimming":  @"Disables clip skimming when the pointer hovers over clips in the browser or timeline.",
    })];
    [root addArrangedSubview:SKDebug_makeSeparator()];

    // --- ProAppSupport Log ---
    [root addArrangedSubview:SKDebug_makeSectionLabel(@"ProAppSupport Log")];
    {
        NSStackView *row = [NSStackView stackViewWithViews:@[]];
        row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
        row.alignment = NSLayoutAttributeCenterY;
        row.spacing = 8;
        row.translatesAutoresizingMaskIntoConstraints = NO;

        NSTextField *logLevelLabel = [NSTextField labelWithString:@"Log Level:"];
        [row addArrangedSubview:logLevelLabel];

        NSPopUpButton *levelPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
        for (NSString *name in SKDebug_logLevelNames()) {
            [levelPopup addItemWithTitle:[name capitalizedString]];
        }
        NSInteger currentLevel = [[NSUserDefaults standardUserDefaults] integerForKey:@"LogLevel"];
        if (currentLevel < 0 || currentLevel >= (NSInteger)SKDebug_logLevelNames().count) currentLevel = 2;
        [levelPopup selectItemAtIndex:currentLevel];
        levelPopup.target = [SpliceKitDebugController shared];
        levelPopup.action = @selector(setLogLevel:);
        [row addArrangedSubview:levelPopup];
        NSTextField *logLevelNote = SKDebug_makeNoteLabel(
            @"Minimum severity for ProAppSupport-emitted log entries. "
            @"Trace is most verbose; Failure is errors only.");
        logLevelNote.preferredMaxLayoutWidth = 200;
        [row addArrangedSubview:logLevelNote];
        [row addArrangedSubview:SKDebug_makeCheckbox(@"LogUI", @"Show In-App Log Panel")];
        [row addArrangedSubview:SKDebug_makeCheckbox(@"LogThread", @"Include Thread Info")];
        [root addArrangedSubview:row];
        [root addArrangedSubview:SKDebug_makeNoteLabel(
            @"SpliceKit hosts this panel inside FCP. It combines "
             @"~/Library/Logs/SpliceKit/splicekit.log, live Final Cut Pro unified logs, "
             @"and interaction tracing for menus, windows, popovers, and actions. "
             @"Use the panel toggles to choose sources and dial unified-log noise from "
             @"Important to Verbose. `LogThread` adds the current thread label to emitted "
             @"SpliceKit lines.")];
    }

    // --- CFPreferences integer popups ---
    {
        NSStackView *row = [NSStackView stackViewWithViews:@[]];
        row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
        row.alignment = NSLayoutAttributeCenterY;
        row.spacing = 8;

        NSTextField *label1 = [NSTextField labelWithString:@"Video Decoder Log:"];
        [row addArrangedSubview:label1];
        NSPopUpButton *p1 = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
        for (int i = 0; i <= 5; i++) [p1 addItemWithTitle:[@(i) stringValue]];
        {
            CFPropertyListRef raw = CFPreferencesCopyAppValue(CFSTR("VideoDecoderLogLevelInNLE"),
                                                              kCFPreferencesCurrentApplication);
            NSInteger idx = raw ? [(__bridge_transfer NSNumber *)raw integerValue] : 0;
            if (idx < 0 || idx > 5) idx = 0;
            [p1 selectItemAtIndex:idx];
        }
        p1.identifier = @"VideoDecoderLogLevelInNLE";
        p1.target = [SpliceKitDebugController shared];
        p1.action = @selector(setIntDefault:);
        [row addArrangedSubview:p1];

        NSTextField *label2 = [NSTextField labelWithString:@"Frame Drop Log:"];
        [row addArrangedSubview:label2];
        NSPopUpButton *p2 = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
        for (int i = 0; i <= 5; i++) [p2 addItemWithTitle:[@(i) stringValue]];
        {
            CFPropertyListRef raw = CFPreferencesCopyAppValue(CFSTR("FrameDropLogLevel"),
                                                              kCFPreferencesCurrentApplication);
            NSInteger idx = raw ? [(__bridge_transfer NSNumber *)raw integerValue] : 0;
            if (idx < 0 || idx > 5) idx = 0;
            [p2 selectItemAtIndex:idx];
        }
        p2.identifier = @"FrameDropLogLevel";
        p2.target = [SpliceKitDebugController shared];
        p2.action = @selector(setIntDefault:);
        [row addArrangedSubview:p2];

        [root addArrangedSubview:row];
        [root addArrangedSubview:SKDebug_makeNoteLabel(
            @"Video Decoder Log: verbosity of the NLE video decode pipeline (0 = off, higher = more detail). "
            @"Frame Drop Log: verbosity of dropped-frame reporting (0 = off). "
            @"Both write to the system unified log — view with Console.app or `log stream --process \"Final Cut Pro\"`.")];
    }
    [root addArrangedSubview:SKDebug_makeSeparator()];

    // --- Presets (row of buttons) ---
    [root addArrangedSubview:SKDebug_makeSectionLabel(@"Presets")];
    [root addArrangedSubview:SKDebug_makeNoteLabel(
        @"One-click combinations of the flags above. \"All Off\" removes every debug key "
        @"from NSUserDefaults and CFPreferences, restoring FCP's default behaviour.")];
    {
        NSStackView *row1 = [NSStackView stackViewWithViews:@[
            SKDebug_makePresetButton(@"Timeline Visual", @"timeline_visual"),
            SKDebug_makePresetButton(@"Timeline Logging", @"timeline_logging"),
            SKDebug_makePresetButton(@"Performance", @"performance"),
        ]];
        row1.orientation = NSUserInterfaceLayoutOrientationHorizontal;
        row1.spacing = 8;
        [root addArrangedSubview:row1];

        NSStackView *row2 = [NSStackView stackViewWithViews:@[
            SKDebug_makePresetButton(@"Render Debug", @"render_debug"),
            SKDebug_makePresetButton(@"Verbose Logging", @"verbose_logging"),
            SKDebug_makePresetButton(@"All Off", @"all_off"),
        ]];
        row2.orientation = NSUserInterfaceLayoutOrientationHorizontal;
        row2.spacing = 8;
        [root addArrangedSubview:row2];
    }
    [root addArrangedSubview:SKDebug_makeSeparator()];

    // --- Actions ---
    [root addArrangedSubview:SKDebug_makeSectionLabel(@"Actions")];
    [root addArrangedSubview:SKDebug_makeNoteLabel(
        @"HMD Framerate Monitor uses FCP's built-in HMDFramerate (ProCore) to log overall fps, "
        @"average getFrame() time in ms, and min/max frame times every 2 seconds. "
        @"Output appears in the system unified log — monitor with Console.app. "
        @"\"Clear User Defaults\" removes all debug flags set on this tab.")];
    {
        NSStackView *row = [NSStackView stackViewWithViews:@[]];
        row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
        row.spacing = 8;

        NSButton *fpsStart = [NSButton buttonWithTitle:@"Start HMD Framerate Monitor"
                                                target:[SpliceKitDebugController shared]
                                                action:@selector(startFramerateMonitor:)];
        [row addArrangedSubview:fpsStart];

        NSButton *fpsStop = [NSButton buttonWithTitle:@"Stop HMD Framerate Monitor"
                                               target:[SpliceKitDebugController shared]
                                               action:@selector(stopFramerateMonitor:)];
        [row addArrangedSubview:fpsStop];

        NSButton *clearBtn = [NSButton buttonWithTitle:@"Clear User Defaults…"
                                                target:[SpliceKitDebugController shared]
                                                action:@selector(clearAllDebugFlags:)];
        [row addArrangedSubview:clearBtn];

        [root addArrangedSubview:row];
    }

    return doc;
}

// Wrap the programmatic doc view in a scroll view so the panel stays usable
// even if the content grows taller than the screen.
static NSView *SKDebug_buildScrollableDebugView(void) {
    NSView *content = SKDebug_buildDebugPrefsView();

    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 600, 520)];
    scroll.hasVerticalScroller = YES;
    scroll.hasHorizontalScroller = NO;
    scroll.autohidesScrollers = YES;
    scroll.borderType = NSNoBorder;
    scroll.drawsBackground = NO;

    // The scroll view's documentView is what it scrolls inside its bounds.
    // content's intrinsicContentSize comes from the stack view's constraints,
    // so we let Auto Layout drive its height.
    content.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.documentView = content;

    [NSLayoutConstraint activateConstraints:@[
        [content.topAnchor constraintEqualToAnchor:scroll.contentView.topAnchor],
        [content.leadingAnchor constraintEqualToAnchor:scroll.contentView.leadingAnchor],
        [content.trailingAnchor constraintEqualToAnchor:scroll.contentView.trailingAnchor],
        [content.widthAnchor constraintEqualToAnchor:scroll.contentView.widthAnchor],
    ]];

    return scroll;
}

#pragma mark - Preferences Panel Installation

// Reads an ivar by name using runtime APIs instead of KVC, since LKPreferences'
// ivars are underscored and KVC-illegal.
static id SKDebug_getIvar(id obj, const char *name) {
    if (!obj) return nil;
    Ivar iv = class_getInstanceVariable(object_getClass(obj), name);
    if (!iv) return nil;
    return object_getIvar(obj, iv);
}

static BOOL sDebugPrefsInstalled = NO;

BOOL SpliceKit_installDebugSettingsPanel(void) {
    if (sDebugPrefsInstalled) return YES;

    __block BOOL success = NO;

    dispatch_block_t work = ^{
        Class moduleClass = objc_getClass("PEAppDebugPreferencesModule");
        if (!moduleClass) {
            SpliceKit_log(@"PEAppDebugPreferencesModule class not found — cannot install Debug panel");
            return;
        }

        Class prefsClass = objc_getClass("LKPreferences");
        if (!prefsClass) {
            SpliceKit_log(@"LKPreferences class not found");
            return;
        }

        id shared = ((id (*)(id, SEL))objc_msgSend)((id)prefsClass, @selector(sharedPreferences));
        if (!shared) {
            SpliceKit_log(@"LKPreferences sharedPreferences returned nil");
            return;
        }

        // Instantiate the module
        id module = ((id (*)(id, SEL))objc_msgSend)((id)moduleClass, @selector(alloc));
        module = ((id (*)(id, SEL))objc_msgSend)(module, @selector(init));
        if (!module) {
            SpliceKit_log(@"Failed to init PEAppDebugPreferencesModule");
            return;
        }
        [SpliceKitDebugController shared].debugPrefsModule = module;

        // Build our programmatic view
        NSView *view = SKDebug_buildScrollableDebugView();
        [SpliceKitDebugController shared].debugPrefsView = view;

        // Hand the view to the module (so it behaves like a normal NIB-owned module)
        SEL setViewSel = @selector(setPreferencesView:);
        if ([module respondsToSelector:setViewSel]) {
            ((void (*)(id, SEL, id))objc_msgSend)(module, setViewSel, view);
        }

        // Direct mutation of LKPreferences state — bypasses the silent NIB filter.
        NSMutableArray *titles  = SKDebug_getIvar(shared, "_preferenceTitles");
        NSMutableArray *modules = SKDebug_getIvar(shared, "_preferenceModules");
        NSMutableDictionary *master = SKDebug_getIvar(shared, "_masterPreferenceViews");

        if (![titles isKindOfClass:[NSMutableArray class]] ||
            ![modules isKindOfClass:[NSMutableArray class]] ||
            ![master isKindOfClass:[NSMutableDictionary class]]) {
            SpliceKit_log(@"LKPreferences ivars have unexpected types — aborting install");
            return;
        }

        NSString *title = @"Debug";

        if ([titles containsObject:title]) {
            SpliceKit_log(@"Debug pane already registered");
            sDebugPrefsInstalled = YES;
            success = YES;
            return;
        }

        [titles addObject:title];
        [modules addObject:module];
        master[title] = view;

        // Do NOT call _setupToolbar here — it wipes FCP's owner registry and
        // breaks native tab switching. Toolbar items are inserted directly
        // when showPreferencesPanel is called (see PreferencesPane.m).

        sDebugPrefsInstalled = YES;
        success = YES;
        SpliceKit_log(@"Debug preferences pane installed");
    };

    if ([NSThread isMainThread]) {
        work();
    } else {
        dispatch_sync(dispatch_get_main_queue(), work);
    }

    return success;
}

BOOL SpliceKit_uninstallDebugSettingsPanel(void) {
    if (!sDebugPrefsInstalled) return YES;

    __block BOOL success = NO;
    dispatch_block_t work = ^{
        Class prefsClass = objc_getClass("LKPreferences");
        if (!prefsClass) return;
        id shared = ((id (*)(id, SEL))objc_msgSend)((id)prefsClass, @selector(sharedPreferences));
        if (!shared) return;

        NSMutableArray *titles  = SKDebug_getIvar(shared, "_preferenceTitles");
        NSMutableArray *modules = SKDebug_getIvar(shared, "_preferenceModules");
        NSMutableDictionary *master = SKDebug_getIvar(shared, "_masterPreferenceViews");

        NSUInteger idx = [titles indexOfObject:@"Debug"];
        if (idx != NSNotFound) {
            [titles removeObjectAtIndex:idx];
            if (idx < modules.count) [modules removeObjectAtIndex:idx];
            [master removeObjectForKey:@"Debug"];
        }

        SEL setupToolbar = NSSelectorFromString(@"_setupToolbar");
        if ([shared respondsToSelector:setupToolbar]) {
            ((void (*)(id, SEL))objc_msgSend)(shared, setupToolbar);
        }

        [SpliceKitDebugController shared].debugPrefsModule = nil;
        [SpliceKitDebugController shared].debugPrefsView = nil;
        sDebugPrefsInstalled = NO;
        success = YES;
    };

    if ([NSThread isMainThread]) work(); else dispatch_sync(dispatch_get_main_queue(), work);
    return success;
}

BOOL SpliceKit_isDebugSettingsPanelInstalled(void) {
    return sDebugPrefsInstalled;
}
