//
//  SpliceKitPreferencesPane.m
//  Adds a "SpliceKit" tab to FCP's Preferences / Settings window.
//
//  Installation follows the same pattern as SpliceKitDebugUI:
//    1. Build the view programmatically (no NIB needed).
//    2. Mutate LKPreferences' internal arrays / dictionary directly.
//    3. Call _setupToolbar so the toolbar picks up the new tab.
//

#import "SpliceKitPreferencesPane.h"
#import "SpliceKit.h"
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

// ---------------------------------------------------------------------------
#pragma mark - Module class

// Subclass PEAppDebugPreferencesModule — same base class as FCP's Debug tab —
// so that LKPreferences' toolbarItemClicked: accepts our module without a swizzle.
// We override icon, title, and viewForPreferenceNamed: to return our own content.
@interface PEAppDebugPreferencesModule : NSObject
- (void)setPreferencesView:(NSView *)view;
- (NSView *)preferencesView;
@end

@interface SpliceKitPrefsModule : PEAppDebugPreferencesModule
@property (nonatomic, strong) NSView *spliceKitContentView;
@end

@implementation SpliceKitPrefsModule

- (NSImage *)imageForPreferenceNamed:(NSString *)name {
    (void)name;
    NSImage *img = [NSImage imageWithSystemSymbolName:@"wand.and.stars"
                                accessibilityDescription:@"SpliceKit"];
    return img ?: [NSImage imageNamed:NSImageNameAdvanced];
}

- (NSString *)titleForIdentifier:(NSString *)identifier {
    (void)identifier;
    return @"SpliceKit";
}

- (NSView *)viewForPreferenceNamed:(NSString *)name {
    (void)name;
    return self.spliceKitContentView;
}

- (BOOL)preferencesWindowShouldClose { return YES; }
- (BOOL)moduleCanBeRemoved { return NO; }

@end

// ---------------------------------------------------------------------------
#pragma mark - Controller

// Identifier tags written into NSButton/NSPopUpButton.identifier so action
// methods can dispatch without a big if-chain.
static NSString *const kIDEffectDrag       = @"effectDragAsAdjustmentClip";
static NSString *const kIDPinchZoom        = @"viewerPinchZoom";
static NSString *const kIDVideoOnlyAudio   = @"videoOnlyKeepsAudioDisabled";
static NSString *const kIDSuppressImport   = @"suppressAutoImport";
static NSString *const kIDColorizeLanes    = @"TLKColorizesLanes";
static NSString *const kIDDontCoalesceGaps = @"FFDontCoalesceGaps";
static NSString *const kIDPlayheadOverlay  = @"timelinePlayheadOverlay";
static NSString *const kIDPerfMode         = @"timelinePerformanceMode";

@interface SKPrefsController : NSObject
+ (instancetype)shared;
@end

@implementation SKPrefsController

+ (instancetype)shared {
    static SKPrefsController *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[self alloc] init]; });
    return s;
}

// Reload TLKUserDefaults so flag changes take effect immediately.
static void SKPrefs_reloadTLK(void) {
    Class cls = NSClassFromString(@"TLKUserDefaults");
    if (!cls) return;
    SEL sel = NSSelectorFromString(@"_loadUserDefaults");
    if ([cls respondsToSelector:sel]) ((void (*)(id, SEL))objc_msgSend)(cls, sel);
}

- (void)checkboxChanged:(NSButton *)sender {
    NSString *ident = sender.identifier;
    BOOL on = (sender.state == NSControlStateValueOn);

    if ([ident isEqualToString:kIDEffectDrag]) {
        SpliceKit_setEffectDragAsAdjustmentClipEnabled(on);

    } else if ([ident isEqualToString:kIDPinchZoom]) {
        SpliceKit_setViewerPinchZoomEnabled(on);

    } else if ([ident isEqualToString:kIDVideoOnlyAudio]) {
        SpliceKit_setVideoOnlyKeepsAudioDisabledEnabled(on);

    } else if ([ident isEqualToString:kIDSuppressImport]) {
        SpliceKit_setSuppressAutoImportEnabled(on);

    } else if ([ident isEqualToString:kIDColorizeLanes]) {
        [[NSUserDefaults standardUserDefaults] setBool:on forKey:kIDColorizeLanes];
        SKPrefs_reloadTLK();

    } else if ([ident isEqualToString:kIDDontCoalesceGaps]) {
        [[NSUserDefaults standardUserDefaults] setBool:on forKey:kIDDontCoalesceGaps];
        SKPrefs_reloadTLK();

    } else if ([ident isEqualToString:kIDPlayheadOverlay]) {
        SpliceKit_setTimelinePlayheadOverlayEnabled(on);

    } else if ([ident isEqualToString:kIDPerfMode]) {
        SpliceKit_setTimelinePerformanceModeEnabled(on);
    }

    SpliceKit_log(@"SpliceKit pref %@ -> %@", ident, on ? @"ON" : @"OFF");
}

- (void)conformPopupChanged:(NSPopUpButton *)popup {
    NSInteger idx = popup.indexOfSelectedItem;
    NSString *value = (idx == 1) ? @"fill" : (idx == 2) ? @"none" : @"fit";
    SpliceKit_setDefaultSpatialConformType(value);
    SpliceKit_log(@"Default spatial conform -> %@", value);
}

@end

// ---------------------------------------------------------------------------
#pragma mark - View construction helpers

static NSTextField *SKPrefs_makeHeader(NSString *text) {
    NSTextField *f = [NSTextField labelWithString:text];
    f.font = [NSFont boldSystemFontOfSize:13];
    f.textColor = [NSColor labelColor];
    f.translatesAutoresizingMaskIntoConstraints = NO;
    return f;
}

static NSTextField *SKPrefs_makeNote(NSString *text, CGFloat maxWidth) {
    NSTextField *f = [NSTextField labelWithString:text];
    f.font = [NSFont systemFontOfSize:11];
    f.textColor = [NSColor secondaryLabelColor];
    f.maximumNumberOfLines = 0;
    f.lineBreakMode = NSLineBreakByWordWrapping;
    f.preferredMaxLayoutWidth = maxWidth;
    f.translatesAutoresizingMaskIntoConstraints = NO;
    return f;
}

static NSBox *SKPrefs_makeSep(void) {
    NSBox *b = [[NSBox alloc] initWithFrame:NSMakeRect(0, 0, 400, 1)];
    b.boxType = NSBoxSeparator;
    b.translatesAutoresizingMaskIntoConstraints = NO;
    return b;
}

static NSButton *SKPrefs_makeCheckbox(NSString *ident, NSString *title, BOOL on) {
    NSButton *cb = [NSButton checkboxWithTitle:title
                                        target:[SKPrefsController shared]
                                        action:@selector(checkboxChanged:)];
    cb.identifier = ident;
    cb.state = on ? NSControlStateValueOn : NSControlStateValueOff;
    cb.translatesAutoresizingMaskIntoConstraints = NO;
    return cb;
}

// Row: label + indented checkbox
static NSStackView *SKPrefs_makeRow(NSString *ident, NSString *title,
                                    NSString *note, BOOL on, CGFloat noteWidth) {
    NSStackView *col = [NSStackView stackViewWithViews:@[]];
    col.orientation = NSUserInterfaceLayoutOrientationVertical;
    col.alignment = NSLayoutAttributeLeading;
    col.spacing = 2;
    col.translatesAutoresizingMaskIntoConstraints = NO;

    [col addArrangedSubview:SKPrefs_makeCheckbox(ident, title, on)];
    if (note.length > 0) {
        [col addArrangedSubview:SKPrefs_makeNote(note, noteWidth)];
    }
    return col;
}

// ---------------------------------------------------------------------------
#pragma mark - Build full pane view

static NSView *SKPrefs_buildView(void) {
    const CGFloat kWidth = 560.0;
    const CGFloat kNoteWidth = kWidth - 44.0;  // inset under checkbox indent

    NSView *doc = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, kWidth, 900)];
    doc.translatesAutoresizingMaskIntoConstraints = NO;

    NSStackView *root = [NSStackView stackViewWithViews:@[]];
    root.orientation = NSUserInterfaceLayoutOrientationVertical;
    root.alignment = NSLayoutAttributeLeading;
    root.spacing = 8;
    root.edgeInsets = NSEdgeInsetsMake(16, 20, 20, 20);
    root.translatesAutoresizingMaskIntoConstraints = NO;
    [doc addSubview:root];
    [NSLayoutConstraint activateConstraints:@[
        [root.topAnchor constraintEqualToAnchor:doc.topAnchor],
        [root.leadingAnchor constraintEqualToAnchor:doc.leadingAnchor],
        [root.trailingAnchor constraintEqualToAnchor:doc.trailingAnchor],
        [root.bottomAnchor constraintEqualToAnchor:doc.bottomAnchor],
    ]];

    // ── SpliceKit Options ────────────────────────────────────────────────
    [root addArrangedSubview:SKPrefs_makeHeader(@"SpliceKit Options")];

    [root addArrangedSubview:SKPrefs_makeRow(
        kIDEffectDrag,
        @"Effect Drag as Adjustment Clip",
        @"Dragging an effect onto an empty area of the timeline creates an "
         @"adjustment clip instead of applying the effect to the clip below.",
        SpliceKit_isEffectDragAsAdjustmentClipEnabled(), kNoteWidth)];

    [root addArrangedSubview:SKPrefs_makeRow(
        kIDPinchZoom,
        @"Viewer Pinch-to-Zoom",
        @"Use a trackpad pinch gesture to zoom the viewer canvas in or out.",
        SpliceKit_isViewerPinchZoomEnabled(), kNoteWidth)];

    [root addArrangedSubview:SKPrefs_makeRow(
        kIDVideoOnlyAudio,
        @"Video-Only Edit Keeps Audio Disabled",
        @"After a video-only append/insert edit, the audio role stays muted "
         @"so accidental audio bleed is prevented on subsequent exports.",
        SpliceKit_isVideoOnlyKeepsAudioDisabledEnabled(), kNoteWidth)];

    [root addArrangedSubview:SKPrefs_makeRow(
        kIDSuppressImport,
        @"Suppress Auto Import Window on Device Connect",
        @"Prevents Final Cut Pro from opening the Import window every time a "
         @"camera, memory card, or external drive is connected.",
        SpliceKit_isSuppressAutoImportEnabled(), kNoteWidth)];

    // Default Spatial Conform — popup row
    {
        NSStackView *row = [NSStackView stackViewWithViews:@[]];
        row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
        row.alignment = NSLayoutAttributeCenterY;
        row.spacing = 8;
        row.translatesAutoresizingMaskIntoConstraints = NO;

        NSTextField *lbl = [NSTextField labelWithString:@"Default New Clip Conform:"];
        lbl.translatesAutoresizingMaskIntoConstraints = NO;
        [row addArrangedSubview:lbl];

        NSPopUpButton *popup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
        [popup addItemWithTitle:@"Fit (Default)"];
        [popup addItemWithTitle:@"Fill"];
        [popup addItemWithTitle:@"None"];

        NSString *current = SpliceKit_getDefaultSpatialConformType();
        if ([current isEqualToString:@"fill"])      [popup selectItemAtIndex:1];
        else if ([current isEqualToString:@"none"]) [popup selectItemAtIndex:2];
        else                                         [popup selectItemAtIndex:0];

        popup.target = [SKPrefsController shared];
        popup.action = @selector(conformPopupChanged:);
        popup.translatesAutoresizingMaskIntoConstraints = NO;
        [row addArrangedSubview:popup];

        NSStackView *conformCol = [NSStackView stackViewWithViews:@[]];
        conformCol.orientation = NSUserInterfaceLayoutOrientationVertical;
        conformCol.alignment = NSLayoutAttributeLeading;
        conformCol.spacing = 2;
        conformCol.translatesAutoresizingMaskIntoConstraints = NO;
        [conformCol addArrangedSubview:row];
        [conformCol addArrangedSubview:SKPrefs_makeNote(
            @"Spatial conform applied to new clips dropped onto the timeline: "
             @"Fit (letterbox), Fill (crop to frame), or None (native resolution).",
            kNoteWidth)];
        [root addArrangedSubview:conformCol];
    }

    [root addArrangedSubview:SKPrefs_makeSep()];

    // ── Timeline Enhancements ────────────────────────────────────────────
    [root addArrangedSubview:SKPrefs_makeHeader(@"Timeline Enhancements")];

    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];

    [root addArrangedSubview:SKPrefs_makeRow(
        kIDColorizeLanes,
        @"Colorize Connected Clip Lanes",
        @"Tints each connected clip lane a distinct color, making it easier "
         @"to follow complex multi-lane compositions at a glance.",
        [ud boolForKey:kIDColorizeLanes], kNoteWidth)];

    [root addArrangedSubview:SKPrefs_makeRow(
        kIDDontCoalesceGaps,
        @"Prevent Gap Auto-Merge",
        @"Stops Final Cut Pro from automatically collapsing adjacent gaps into "
         @"one. Useful when gaps are intentional spacers you want to keep separate.",
        [ud boolForKey:kIDDontCoalesceGaps], kNoteWidth)];

    [root addArrangedSubview:SKPrefs_makeRow(
        kIDPlayheadOverlay,
        @"120 Hz Playhead Overlay",
        @"Renders the timeline playhead at up to 120 Hz on ProMotion displays, "
         @"decoupled from the timeline redraw cycle for smoother scrubbing.",
        SpliceKit_isTimelinePlayheadOverlayEnabled(), kNoteWidth)];

    [root addArrangedSubview:SKPrefs_makeRow(
        kIDPerfMode,
        @"Timeline Performance Mode",
        @"Bundles the 120 Hz playhead overlay, interaction-suspend (freezes "
         @"non-essential redraws during drags), and optimized reload into one toggle.",
        SpliceKit_isTimelinePerformanceModeEnabled(), kNoteWidth)];

    return doc;
}

// Wrap the doc view in a scroll view (same pattern as Debug pane).
static NSView *SKPrefs_buildScrollableView(void) {
    NSView *content = SKPrefs_buildView();

    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 600, 480)];
    scroll.hasVerticalScroller = YES;
    scroll.hasHorizontalScroller = NO;
    scroll.autohidesScrollers = YES;
    scroll.borderType = NSNoBorder;
    scroll.drawsBackground = NO;

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

static void SKPrefs_swizzleShowPanel(void);  // forward declaration

// ---------------------------------------------------------------------------
#pragma mark - Installation

static id SKPrefs_getIvar(id obj, const char *name) {
    if (!obj) return nil;
    Ivar iv = class_getInstanceVariable(object_getClass(obj), name);
    if (!iv) return nil;
    return object_getIvar(obj, iv);
}

static BOOL sSpliceKitPrefsInstalled = NO;

BOOL SpliceKit_installSpliceKitPreferencesPane(void) {
    if (sSpliceKitPrefsInstalled) return YES;

    __block BOOL success = NO;
    dispatch_block_t work = ^{
        Class prefsClass = objc_getClass("LKPreferences");
        if (!prefsClass) return;

        id shared = ((id (*)(id, SEL))objc_msgSend)((id)prefsClass,
                                                     @selector(sharedPreferences));
        if (!shared) return;

        NSMutableArray *titles  = SKPrefs_getIvar(shared, "_preferenceTitles");
        NSMutableArray *modules = SKPrefs_getIvar(shared, "_preferenceModules");
        NSMutableDictionary *master = SKPrefs_getIvar(shared, "_masterPreferenceViews");

        if (![titles isKindOfClass:[NSMutableArray class]] ||
            ![modules isKindOfClass:[NSMutableArray class]] ||
            ![master isKindOfClass:[NSMutableDictionary class]]) return;

        NSString *title = @"SpliceKit";
        if ([titles containsObject:title]) {
            sSpliceKitPrefsInstalled = YES;
            success = YES;
            return;
        }

        SpliceKitPrefsModule *module = [[SpliceKitPrefsModule alloc] init];
        NSView *view = SKPrefs_buildScrollableView();
        module.spliceKitContentView = view;
        // Also set via inherited setter for any code that calls preferencesView.
        if ([module respondsToSelector:@selector(setPreferencesView:)]) {
            [module setPreferencesView:view];
        }

        // Insert before "Debug" so SpliceKit sits between Destinations and Debug.
        NSUInteger insertAt = [titles indexOfObject:@"Debug"];
        if (insertAt == NSNotFound) insertAt = titles.count;

        [titles insertObject:title atIndex:insertAt];
        [modules insertObject:module atIndex:insertAt];
        master[title] = view;

        // Never call _setupToolbar — it wipes FCP's internal owner registry,
        // breaking native tab switching. Toolbar items are inserted directly
        // in the showPreferencesPanel swizzle below, after the window is ready.

        sSpliceKitPrefsInstalled = YES;
        success = YES;
        SpliceKit_log(@"SpliceKit preferences pane data registered");
    };

    if ([NSThread isMainThread]) work();
    else dispatch_sync(dispatch_get_main_queue(), work);

    // Swizzle showPreferencesPanel to insert toolbar items the first time the
    // window opens. At that point the NSToolbar exists and inserting an item
    // calls toolbar:itemForItemIdentifier:willBeInsertedIntoToolbar: which
    // reads from _preferenceTitles/_preferenceModules — already populated above.
    static dispatch_once_t once;
    dispatch_once(&once, ^{ SKPrefs_swizzleShowPanel(); });

    return success;
}

// ---------------------------------------------------------------------------
#pragma mark - showPreferencesPanel swizzle (toolbar item insertion)

@interface LKPreferences : NSObject
- (id)_preferencesPanel;
@end

@interface LKPreferences (SKPanelHook)
- (void)spliceKit_showPreferencesPanel;
- (void)spliceKit_selectModuleOwner:(id)sender;
@end

@implementation LKPreferences (SKPanelHook)

- (void)spliceKit_showPreferencesPanel {
    // Call original first so the window, toolbar, and native modules are ready.
    [self spliceKit_showPreferencesPanel];

    id panel = ((id (*)(id,SEL))objc_msgSend)(self, @selector(_preferencesPanel));
    NSToolbar *toolbar = [(NSWindow *)panel toolbar];
    if (!toolbar) return;

    // _selectModuleOwner: requires every tab's view to be pre-cached in
    // _masterPreferenceViews. Native tabs are not there yet after our changes;
    // populate them now while native modules are fully initialised in window context.
    NSMutableArray  *titles  = SKPrefs_getIvar(self, "_preferenceTitles");
    NSMutableArray  *modules = SKPrefs_getIvar(self, "_preferenceModules");
    NSMutableDictionary *master = SKPrefs_getIvar(self, "_masterPreferenceViews");

    if ([titles isKindOfClass:[NSArray class]] &&
        [modules isKindOfClass:[NSArray class]] &&
        [master isKindOfClass:[NSMutableDictionary class]]) {
        SEL viewSel = @selector(viewForPreferenceNamed:);
        for (NSUInteger i = 0; i < titles.count; i++) {
            NSString *t = titles[i];
            if (master[t]) continue;
            id m = modules[i];
            if ([m respondsToSelector:viewSel]) {
                NSView *v = ((id (*)(id, SEL, id))objc_msgSend)(m, viewSel, t);
                if (v) {
                    master[t] = v;
                    SpliceKit_log(@"Pre-cached view for %@: %@", t, NSStringFromClass([v class]));
                }
            }
        }
    }

    // Insert SpliceKit and Debug toolbar items if not already present.
    NSArray<NSString *> *toAdd = @[@"SpliceKit", @"Debug"];
    for (NSString *ident in toAdd) {
        BOOL found = NO;
        for (NSToolbarItem *item in toolbar.items) {
            if ([item.itemIdentifier isEqualToString:ident]) { found = YES; break; }
        }
        if (found) continue;
        NSUInteger insertIdx = toolbar.items.count;
        [toolbar insertItemWithItemIdentifier:ident atIndex:insertIdx];
        SpliceKit_log(@"Inserted %@ toolbar item at index %lu", ident, (unsigned long)insertIdx);
    }

    // Enforce a minimum window width wide enough for all toolbar items.
    // Without this, narrow panes (e.g. Editing) cause overflow arrows to appear.
    if ([panel respondsToSelector:@selector(setMinSize:)]) {
        NSSize minSize = [(NSWindow *)panel minSize];
        // ~85px per item × 7 items + padding. Measure from actual toolbar if possible.
        CGFloat needed = toolbar.items.count * 85.0 + 40.0;
        if (minSize.width < needed) {
            minSize.width = needed;
            [(NSWindow *)panel setMinSize:minSize];
        }
    }
}

// Full replacement for _selectModuleOwner: — the original has an undiagnosed
// early-return that prevents native tabs from switching. We look up the view
// from _masterPreferenceViews (pre-populated in showPreferencesPanel above)
// and set it directly on _preferenceBox, bypassing whatever gate the original uses.
- (void)spliceKit_selectModuleOwner:(id)sender {
    NSString *identifier = nil;
    if ([sender respondsToSelector:@selector(itemIdentifier)]) {
        identifier = [sender itemIdentifier];
    }
    // Real toolbar clicks arrive as NSToolbarButton (no itemIdentifier).
    // Get the selected tab from the toolbar instead.
    if (!identifier) {
        id panel = ((id (*)(id,SEL))objc_msgSend)(self, @selector(_preferencesPanel));
        if ([panel respondsToSelector:@selector(toolbar)]) {
            identifier = [[panel toolbar] selectedItemIdentifier];
        }
    }
    if (!identifier) { [self spliceKit_selectModuleOwner:sender]; return; }

    NSMutableDictionary *master  = SKPrefs_getIvar(self, "_masterPreferenceViews");
    NSView *view = master[identifier];
    if (!view) { [self spliceKit_selectModuleOwner:sender]; return; }

    id boxRaw = SKPrefs_getIvar(self, "_preferenceBox");
    if (![boxRaw isKindOfClass:[NSBox class]]) { [self spliceKit_selectModuleOwner:sender]; return; }
    NSBox *box = (NSBox *)boxRaw;

    // Find the module for this tab.
    NSArray *titles  = SKPrefs_getIvar(self, "_preferenceTitles");
    NSArray *modules = SKPrefs_getIvar(self, "_preferenceModules");
    NSUInteger idx = [titles indexOfObject:identifier];
    id module = (idx != NSNotFound && idx < modules.count) ? modules[idx] : nil;

    // Populate controls and patch targets BEFORE placing in the window.
    // initializeFromDefaults can trigger Auto Layout passes; doing this while
    // the view is detached prevents it from locking in a wrong frame size.
    if (module) {
        SEL initSel = @selector(initializeFromDefaults);
        if ([module respondsToSelector:initSel]) {
            ((void (*)(id, SEL))objc_msgSend)(module, initSel);
        }
        Class walkClass = [module class];
        while (walkClass && walkClass != [NSObject class]) {
            unsigned int ivarCount = 0;
            Ivar *ivars = class_copyIvarList(walkClass, &ivarCount);
            for (unsigned int i = 0; i < ivarCount; i++) {
                const char *enc = ivar_getTypeEncoding(ivars[i]);
                if (!enc || enc[0] != '@') continue;
                id val = object_getIvar(module, ivars[i]);
                if (!val) continue;
                if (![val isKindOfClass:[NSControl class]]) continue;
                NSControl *ctl = (NSControl *)val;
                if (ctl.target == nil && ctl.action != NULL) ctl.target = module;
            }
            if (ivars) free(ivars);
            walkClass = class_getSuperclass(walkClass);
        }
    }

    // Set _currentModule so updatePanelFrameWithOwner: knows the target size.
    if (module) {
        Ivar ivCurrent = class_getInstanceVariable(object_getClass(self), "_currentModule");
        if (ivCurrent) object_setIvar(self, ivCurrent, module);
    }

    // Resize the window to the new pane's size, then place the content view.
    SEL updateOwner = @selector(updatePanelFrameWithOwner:isChangingPanes:animated:);
    if (module && [self respondsToSelector:updateOwner]) {
        ((void (*)(id, SEL, id, BOOL, BOOL))objc_msgSend)(self, updateOwner, module, YES, NO);
    } else {
        SEL updateFrame = @selector(updatePanelFrameAnimated:);
        if ([self respondsToSelector:updateFrame]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(self, updateFrame, NO);
        }
    }

    if ([view isKindOfClass:[NSScrollView class]]) {
        view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    }
    [box setContentView:view];

    // Cache in session views.
    NSMutableDictionary *session = SKPrefs_getIvar(self, "_currentSessionPreferenceViews");
    if ([session isKindOfClass:[NSMutableDictionary class]]) session[identifier] = view;

    // Update toolbar selection (resize already done above before setContentView:).
    id panel = ((id (*)(id,SEL))objc_msgSend)(self, @selector(_preferencesPanel));
    if ([panel respondsToSelector:@selector(toolbar)]) {
        [[panel toolbar] setSelectedItemIdentifier:identifier];
    }

    SpliceKit_log(@"SKTabSwitch → %@", identifier);
}

@end

static void SKPrefs_swizzleShowPanel(void) {
    Class cls = objc_getClass("LKPreferences");
    if (!cls) return;

    void (^swizzle)(SEL, SEL, NSString *) = ^(SEL orig, SEL swiz, NSString *name) {
        Method origM = class_getInstanceMethod(cls, orig);
        Method swizM = class_getInstanceMethod(cls, swiz);
        if (origM && swizM) {
            method_exchangeImplementations(origM, swizM);
            SpliceKit_log(@"Swizzled LKPreferences.%@", name);
        }
    };

    swizzle(@selector(showPreferencesPanel),
            @selector(spliceKit_showPreferencesPanel),
            @"showPreferencesPanel");

    swizzle(@selector(_selectModuleOwner:),
            @selector(spliceKit_selectModuleOwner:),
            @"_selectModuleOwner:");
}
