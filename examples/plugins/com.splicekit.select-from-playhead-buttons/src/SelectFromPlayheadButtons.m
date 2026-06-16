//
//  SelectFromPlayheadButtons.m
//  com.splicekit.select-from-playhead-buttons
//
//  Injects two buttons into Final Cut Pro's timeline bar (the strip above the
//  timeline tracks), positioned just to the left of the scrolling-timeline /
//  snapping segment control (LKPaneCapSegmentedControl):
//
//    |◀  Select Backward — selects all primary-storyline clips whose end
//                          time is at or before the playhead position.
//    ▶|  Select Forward  — selects all primary-storyline clips whose start
//                          time is at or after the playhead position.
//
//  The buttons invoke timeline.action("selectBackward") and
//  timeline.action("selectForward"), which are built into SpliceKit core.
//
//  The timeline bar is NOT an NSToolbar — it is a plain NSView
//  (NSView 0x… inside LKContainerItemCapView) that FCP builds via
//  PETimelineToolbarBuilder. We reach it by walking up from the timeline
//  module's view and looking for LKContainerItemCapView.
//
//  The toolbar swizzle is kept so FCP can still resolve our identifiers if
//  they happen to be saved in the toolbar customisation preferences from a
//  previous install. On load we actively remove them from the main toolbar.
//
//  Build:   make -f Makefile
//  Install: make -f Makefile install
//

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import "SpliceKitPluginAPI.h"

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

static NSString * const kSFPBForwardID  = @"SpliceKitSFP_SelectForwardItemID";
static NSString * const kSFPBBackwardID = @"SpliceKitSFP_SelectBackwardItemID";

static SpliceKitPluginAPI  sSFPBAPIStorage;
static SpliceKitPluginAPI *sSFPBAPI = NULL;

// Toolbar swizzle — kept only for backward-compat resolution of saved items.
static IMP sSFPBOriginalItemForIdentifier = NULL;

// ---------------------------------------------------------------------------
// Button target
// ---------------------------------------------------------------------------
@interface SpliceKitSFP_BtnController : NSObject
+ (instancetype)shared;
- (void)selectForwardAction:(id)sender;
- (void)selectBackwardAction:(id)sender;
@end

@implementation SpliceKitSFP_BtnController

+ (instancetype)shared {
    static SpliceKitSFP_BtnController *sInstance = nil;
    static dispatch_once_t sOnce;
    dispatch_once(&sOnce, ^{ sInstance = [[self alloc] init]; });
    return sInstance;
}

// Select all primary-storyline clips whose start time >= playhead (forward)
// or whose end time <= playhead (backward). Implemented directly via the
// timeline's detailed state + setSelectedItems: rather than sendAction:,
// so it works regardless of which view is first responder.
- (void)selectForwardAction:(id)sender {
    (void)sender;
    if (!sSFPBAPI) return;
    [self _selectClips:YES];
}

- (void)selectBackwardAction:(id)sender {
    (void)sender;
    if (!sSFPBAPI) return;
    [self _selectClips:NO];
}

// Uses timeline.getDetailedState (one RPC call) to read both the playhead
// position and all clip handles. Handles are resolved to live ObjC objects
// via the plugin API, then setSelectedItems: is called directly on the
// timeline module — no sendAction:/responder-chain dependency.
- (void)_selectClips:(BOOL)forward {
    @try {
        NSDictionary *r      = sSFPBAPI->callMethod(@{@"method": @"timeline.getDetailedState"});
        NSDictionary *result = r[@"result"];
        if (!result) { sSFPBAPI->log(@"[SFPButtons] getDetailedState returned nil"); return; }

        double   playhead = [result[@"playheadTime"][@"seconds"] doubleValue];
        NSArray *items    = result[@"items"];
        if (!items.count) return;

        // Resolve clip handles to live ObjC objects and filter by playhead.
        NSMutableArray *toSelect = [NSMutableArray array];
        for (NSDictionary *item in items) {
            if ([item[@"lane"] integerValue] != 0) continue;  // primary storyline only
            double start = [item[@"startTime"][@"seconds"] doubleValue];
            double end   = [item[@"endTime"][@"seconds"]   doubleValue];
            BOOL include = forward ? (start >= playhead) : (end <= playhead);
            if (!include) continue;
            NSString *handle = item[@"handle"];
            if (!handle) continue;
            id obj = sSFPBAPI->resolveHandle(handle);
            if (obj) [toSelect addObject:obj];
        }

        // Apply selection via the timeline module directly.
        id delegate = [[NSApplication sharedApplication] delegate];
        id ec = ((id(*)(id,SEL))objc_msgSend)(delegate, NSSelectorFromString(@"activeEditorContainer"));
        id tm = ((id(*)(id,SEL))objc_msgSend)(ec, NSSelectorFromString(@"timelineModule"));
        if (!tm) return;

        SEL deselSel = NSSelectorFromString(@"deselectAll:");
        if ([tm respondsToSelector:deselSel])
            ((void(*)(id,SEL,id))objc_msgSend)(tm, deselSel, nil);

        if (toSelect.count > 0) {
            SEL setSel = NSSelectorFromString(@"setSelectedItems:");
            if ([tm respondsToSelector:setSel])
                ((void(*)(id,SEL,id))objc_msgSend)(tm, setSel, toSelect);
        }
    } @catch (NSException *e) {
        sSFPBAPI->log(@"[SFPButtons] _selectClips exception: %@", e.reason);
    }
}

@end

// ---------------------------------------------------------------------------
// Icon helper
// ---------------------------------------------------------------------------
static NSImage *SFPB_makeIcon(NSString *symbolName, NSString *description) {
    NSImage *img = [NSImage imageWithSystemSymbolName:symbolName
                             accessibilityDescription:description];
    NSImageSymbolConfiguration *cfg = [NSImageSymbolConfiguration
        configurationWithPointSize:19 weight:NSFontWeightMedium];
    return img ? [img imageWithSymbolConfiguration:cfg] : nil;
}

// ---------------------------------------------------------------------------
// Toolbar delegate swizzle (backward-compat only — resolves saved items)
// ---------------------------------------------------------------------------
static id SFPB_toolbarItemForIdentifier(id self, SEL _cmd,
                                         NSToolbar *toolbar,
                                         NSString *identifier,
                                         BOOL willInsert) {
    // Build a stub item so FCP can load it from prefs (we immediately remove it).
    NSButton * (^makeButton)(NSImage *, SEL) = ^(NSImage *icon, SEL action) {
        NSButton *btn = [[NSButton alloc] initWithFrame:NSMakeRect(0, 0, 30, 22)];
        [btn setButtonType:NSButtonTypeMomentaryPushIn];
        btn.bezelStyle    = NSBezelStyleTexturedRounded;
        btn.bordered      = YES;
        btn.image         = icon;
        btn.imagePosition = NSImageOnly;
        btn.target        = [SpliceKitSFP_BtnController shared];
        btn.action        = action;
        return btn;
    };

    if ([identifier isEqualToString:kSFPBForwardID]) {
        NSToolbarItem *item = [[NSToolbarItem alloc] initWithItemIdentifier:identifier];
        item.label   = @"Select Fwd";
        item.toolTip = @"Select all clips from the playhead to the end of the timeline";
        item.view    = makeButton(SFPB_makeIcon(@"arrow.right.square", @"Select Forward"),
                                 @selector(selectForwardAction:));
        return item;
    }
    if ([identifier isEqualToString:kSFPBBackwardID]) {
        NSToolbarItem *item = [[NSToolbarItem alloc] initWithItemIdentifier:identifier];
        item.label   = @"Select Bwd";
        item.toolTip = @"Select all clips from the beginning of the timeline to the playhead";
        item.view    = makeButton(SFPB_makeIcon(@"arrow.left.square", @"Select Backward"),
                                 @selector(selectBackwardAction:));
        return item;
    }

    return ((id (*)(id, SEL, NSToolbar *, NSString *, BOOL))sSFPBOriginalItemForIdentifier)(
        self, _cmd, toolbar, identifier, willInsert);
}

static void SFPB_installSwizzle(void) {
    if (sSFPBOriginalItemForIdentifier) return;
    @try {
        Class cls = NSClassFromString(@"PEMainWindowModule");
        if (!cls) return;
        SEL sel = @selector(toolbar:itemForItemIdentifier:willBeInsertedIntoToolbar:);
        Method m = class_getInstanceMethod(cls, sel);
        if (!m) return;
        sSFPBOriginalItemForIdentifier = method_getImplementation(m);
        class_replaceMethod(cls, sel, (IMP)SFPB_toolbarItemForIdentifier, method_getTypeEncoding(m));
    } @catch (__unused NSException *e) {
        sSFPBOriginalItemForIdentifier = NULL;
    }
}

// ---------------------------------------------------------------------------
// Remove our items from the main toolbar (cleanup from previous installs)
// ---------------------------------------------------------------------------
static void SFPB_removeFromMainToolbar(void) {
    @try {
        NSToolbar *tb = [[NSApplication sharedApplication] mainWindow].toolbar;
        if (!tb) return;
        for (NSInteger i = (NSInteger)tb.items.count - 1; i >= 0; i--) {
            NSString *ident = tb.items[(NSUInteger)i].itemIdentifier;
            if ([ident isEqualToString:kSFPBForwardID] ||
                [ident isEqualToString:kSFPBBackwardID]) {
                [tb removeItemAtIndex:(NSUInteger)i];
            }
        }
    } @catch (__unused NSException *) {}
}

// ---------------------------------------------------------------------------
// Timeline bar view discovery
//
// Walk up from FFAnchoredTimelineModule.view four levels to reach the
// LKContainerItemView (PEMainEditorContainer), then find its
// LKContainerItemCapView sibling — that cap view's first subview is the
// timeline bar NSView containing all 17 timeline-bar controls.
// ---------------------------------------------------------------------------
static NSView *SFPB_findTimelineBarView(void) {
    @try {
        id delegate = [[NSApplication sharedApplication] delegate];
        if (!delegate) return nil;

        SEL ecSel = NSSelectorFromString(@"activeEditorContainer");
        if (![delegate respondsToSelector:ecSel]) return nil;
        id editorContainer = ((id(*)(id,SEL))objc_msgSend)(delegate, ecSel);
        if (!editorContainer) return nil;

        SEL tmSel = NSSelectorFromString(@"timelineModule");
        if (![editorContainer respondsToSelector:tmSel]) return nil;
        id timelineModule = ((id(*)(id,SEL))objc_msgSend)(editorContainer, tmSel);
        if (!timelineModule) return nil;

        NSView *tlView = [timelineModule performSelector:@selector(view)];
        if (!tlView) return nil;

        // tlView → NSView(container) → PEEditorContainerSplitView →
        //   PEEditorContainerView → LKContainerItemView(PEMainEditorContainer)
        NSView *v = tlView;
        for (int i = 0; i < 4; i++) {
            v = v.superview;
            if (!v) return nil;
        }
        // v = LKContainerItemView — find LKContainerItemCapView among its subviews
        Class capClass = NSClassFromString(@"LKContainerItemCapView");
        for (NSView *sv in v.subviews) {
            if (capClass ? [sv isKindOfClass:capClass]
                         : [NSStringFromClass([sv class]) containsString:@"CapView"]) {
                return sv.subviews.firstObject; // the timeline bar NSView
            }
        }
        return nil;
    } @catch (__unused NSException *) { return nil; }
}

// ---------------------------------------------------------------------------
// Timeline bar injection
//
// Adds the two buttons as Auto-Layout subviews anchored to the left edge of
// LKPaneCapSegmentedControl (the rightmost group: beat grid, scrolling
// timeline, skimming, audio skimming, solo, snapping). FCP's frame-based
// layout auto-generates translatesAutoresizingMaskIntoConstraints constraints
// for existing views, so our explicit anchors track correctly as FCP resizes.
// ---------------------------------------------------------------------------
static void SFPB_addButtonsToTimelineBar(void) {
    @try {
        NSView *bar = SFPB_findTimelineBarView();
        if (!bar) return;

        // Idempotency: already installed if our identifier is on any subview.
        for (NSView *sv in bar.subviews) {
            if ([sv.identifier isEqualToString:kSFPBForwardID]) return;
        }

        // Find LKPaneCapSegmentedControl — the rightmost group containing
        // the scrolling timeline segment.
        Class paneCapClass = NSClassFromString(@"LKPaneCapSegmentedControl");
        NSView *segControl = nil;
        for (NSView *sv in bar.subviews) {
            if (paneCapClass && [sv isKindOfClass:paneCapClass]) {
                segControl = sv;
                break;
            }
        }
        if (!segControl) {
            if (sSFPBAPI) sSFPBAPI->log(@"[SFPButtons] LKPaneCapSegmentedControl not found in timeline bar.");
            return;
        }

        SpliceKitSFP_BtnController *ctrl = [SpliceKitSFP_BtnController shared];

        NSButton * (^makeBtn)(NSImage *, SEL, NSString *, NSString *) =
            ^(NSImage *icon, SEL action, NSString *ident, NSString *tip) {
                NSButton *btn = [[NSButton alloc] init];
                [btn setButtonType:NSButtonTypeMomentaryPushIn];
                btn.bezelStyle    = NSBezelStyleTexturedRounded;
                btn.bordered      = YES;
                btn.image         = icon;
                btn.imagePosition = NSImageOnly;
                btn.target        = ctrl;
                btn.action        = action;
                btn.identifier    = ident;
                btn.toolTip       = tip;
                btn.translatesAutoresizingMaskIntoConstraints = NO;
                return btn;
            };

        NSButton *bwdBtn = makeBtn(
            SFPB_makeIcon(@"arrow.left.square", @"Select Backward from Playhead"),
            @selector(selectBackwardAction:), kSFPBBackwardID,
            @"Select all clips from the beginning of the timeline to the playhead");
        NSButton *fwdBtn = makeBtn(
            SFPB_makeIcon(@"arrow.right.square", @"Select Forward from Playhead"),
            @selector(selectForwardAction:), kSFPBForwardID,
            @"Select all clips from the playhead to the end of the timeline");

        [bar addSubview:bwdBtn];
        [bar addSubview:fwdBtn];

        // fwdBtn: trailing edge touches segControl leading edge with a 6pt gap.
        // bwdBtn: trailing edge touches fwdBtn leading edge with a 2pt gap.
        // Both match the segControl height and are vertically centred on it.
        CGFloat w = 40.0;
        [NSLayoutConstraint activateConstraints:@[
            [fwdBtn.trailingAnchor constraintEqualToAnchor:segControl.leadingAnchor constant:-6.0],
            [fwdBtn.centerYAnchor  constraintEqualToAnchor:segControl.centerYAnchor],
            [fwdBtn.widthAnchor    constraintEqualToConstant:w],
            [fwdBtn.heightAnchor   constraintEqualToAnchor:segControl.heightAnchor],

            [bwdBtn.trailingAnchor constraintEqualToAnchor:fwdBtn.leadingAnchor constant:-2.0],
            [bwdBtn.centerYAnchor  constraintEqualToAnchor:segControl.centerYAnchor],
            [bwdBtn.widthAnchor    constraintEqualToConstant:w],
            [bwdBtn.heightAnchor   constraintEqualToAnchor:segControl.heightAnchor],
        ]];

        if (sSFPBAPI)
            sSFPBAPI->log(@"[SFPButtons] Buttons installed in timeline bar next to scrolling-timeline control.");

    } @catch (NSException *e) {
        if (sSFPBAPI)
            sSFPBAPI->log(@"[SFPButtons] Exception installing in timeline bar: %@", e.reason);
    }
}

// ---------------------------------------------------------------------------
// Polling — wait for the timeline module to be ready
// ---------------------------------------------------------------------------
static void SFPB_tryInstall(int attempt);

static void SFPB_tryInstall(int attempt) {
    if (attempt >= 40) {
        if (sSFPBAPI) sSFPBAPI->log(@"[SFPButtons] Giving up after %d attempts.", attempt);
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        NSView *bar = SFPB_findTimelineBarView();
        if (bar && bar.subviews.count > 0) {
            SFPB_removeFromMainToolbar();
            SFPB_addButtonsToTimelineBar();
        } else {
            SFPB_tryInstall(attempt + 1);
        }
    });
}

static void SFPB_startInstallation(void) {
    // Fast path: fire when a project is opened and the timeline bar becomes visible.
    [[NSNotificationCenter defaultCenter]
        addObserverForName:NSWindowDidBecomeMainNotification
        object:nil
        queue:[NSOperationQueue mainQueue]
        usingBlock:^(NSNotification * __unused note) {
            NSView *bar = SFPB_findTimelineBarView();
            if (bar && bar.subviews.count > 0) {
                SFPB_removeFromMainToolbar();
                SFPB_addButtonsToTimelineBar();
            }
        }];

    // Slow path: poll until the timeline module is loaded.
    SFPB_tryInstall(0);
}

// ---------------------------------------------------------------------------
// Plugin entry point
// ---------------------------------------------------------------------------
__attribute__((visibility("default")))
void SpliceKitPlugin_init(SpliceKitPluginAPI *api) {
    sSFPBAPIStorage = *api;
    sSFPBAPI = &sSFPBAPIStorage;

    sSFPBAPI->log(@"[SFPButtons] Loading — will inject into timeline bar.");

    api->executeOnMainThreadAsync(^{
        // Install the toolbar swizzle so FCP can resolve our identifiers if they
        // are still saved in its toolbar customisation preferences (legacy cleanup).
        SFPB_installSwizzle();
        SFPB_startInstallation();
    });

    api->log(@"[SFPButtons] Loaded.");
}
