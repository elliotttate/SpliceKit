//
//  TimecodeBarShortcuts.m
//  com.splicekit.timecode-bar-shortcuts
//
//  Customizable shortcut buttons in FCP's timeline toolbar.
//  Survives SpliceKit patcher updates — the entire feature lives here.
//
//  Injects compact NSButtons into the flex gap between the timeline history
//  forward button and the snapping/skimming control cluster.  Configuration
//  is stored as JSON in ~/Library/Application Support/SpliceKit/.
//
//  View hierarchy path to the injection point:
//    NSApp.mainWindow → contentView → LKContainerView → PEMainContainerModule →
//    LKContainerView → PELowerDeckContainer → LKContainerView →
//    PEMainEditorContainer (LKContainerItemView) → LKContainerItemCapView →
//    NSView  ← the 30px toolbar bar with 20 subviews
//
//  Injection target: the Auto Layout flex gap between the history-forward
//  PEEditorMenuDelayButton and the LKPaneCapSegmentedControl (which holds the
//  snapping / skimming / solo / scrolling toggles).  The existing constraint is
//  ">=5" (compressible spacing); we replace it with:
//    histFwd.trailing -(>=6)- [SpliceKitShortcutsBar] -(>=6)- snappingCtrl.leading
//  so the bar compresses naturally if the window is narrow.
//
//  The "SpliceKit" Settings tab (com.splicekit.preferences-pane plugin) writes
//  the same JSON config file directly (native plugins are dlopen(RTLD_LOCAL),
//  so its own copy of the catalogue/config functions is self-contained rather
//  than calling into this plugin) and then calls the "timecodeBarShortcuts.reload"
//  RPC method registered below so button changes take effect immediately.
//

#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import "SpliceKitPluginAPI.h"

static SpliceKitPluginAPI  sAPIStorage;
static SpliceKitPluginAPI *sAPI = NULL;

#define SpliceKit_log(...) (sAPI ? sAPI->log(__VA_ARGS__) : (void)0)
#define SpliceKit_executeOnMainThread(block) (sAPI ? sAPI->executeOnMainThread(block) : (void)0)

// Provided by the host binary — shared, non-migrated utilities that stay in
// the core dylib. Resolved at load time via -undefined dynamic_lookup.
extern id SpliceKit_getActiveTimelineModule(void);
extern NSDictionary *SpliceKit_handleTimelineAction(NSDictionary *params);

// ──────────────────────────────────────────────────────────────────────────────
#pragma mark - Layout constants
// ──────────────────────────────────────────────────────────────────────────────

static const CGFloat kSCBButtonSize  = 20.0;   // width = height of each button
static const CGFloat kSCBButtonGap   =  3.0;   // spacing between buttons
static const CGFloat kSCBGroupPad    =  6.0;   // outer padding from neighbours

// ──────────────────────────────────────────────────────────────────────────────
#pragma mark - Config persistence
// ──────────────────────────────────────────────────────────────────────────────

static NSURL *SCB_configURL(void) {
    NSURL *appSupport = [[[NSFileManager defaultManager]
        URLsForDirectory:NSApplicationSupportDirectory
               inDomains:NSUserDomainMask] firstObject];
    NSURL *dir = [appSupport URLByAppendingPathComponent:@"SpliceKit"];
    [[NSFileManager defaultManager] createDirectoryAtURL:dir
                             withIntermediateDirectories:YES attributes:nil error:nil];
    return [dir URLByAppendingPathComponent:@"timecode_bar_shortcuts.json"];
}

static NSArray<NSDictionary *> *SCB_loadConfig(void) {
    NSData *data = [NSData dataWithContentsOfURL:SCB_configURL()];
    if (!data) return @[];
    NSArray *arr = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [arr isKindOfClass:[NSArray class]] ? arr : @[];
}

static void SCB_saveConfig(NSArray<NSDictionary *> *config) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:config
                                                   options:NSJSONWritingPrettyPrinted
                                                     error:nil];
    if (data) [data writeToURL:SCB_configURL() atomically:YES];
}

// ──────────────────────────────────────────────────────────────────────────────
#pragma mark - Available actions catalogue
// ──────────────────────────────────────────────────────────────────────────────

NSArray<NSDictionary *> *SpliceKit_getAvailableTimecodeBarActions(void) {
    static NSArray *sActions = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sActions = @[
            // ── Edit ─────────────────────────────────────────────────────────
            @{@"id":@"blade",              @"type":@"timeline", @"category":@"Edit",       @"icon":@"scissors",                           @"tooltip":@"Blade — B"},
            @{@"id":@"bladeAll",           @"type":@"timeline", @"category":@"Edit",       @"icon":@"scissors.circle.fill",               @"tooltip":@"Blade All — Shift-B"},
            @{@"id":@"undo",               @"type":@"timeline", @"category":@"Edit",       @"icon":@"arrow.uturn.backward",               @"tooltip":@"Undo — ⌘Z"},
            @{@"id":@"redo",               @"type":@"timeline", @"category":@"Edit",       @"icon":@"arrow.uturn.forward",                @"tooltip":@"Redo — ⇧⌘Z"},
            @{@"id":@"selectAll",          @"type":@"timeline", @"category":@"Edit",       @"icon":@"checkmark.rectangle.fill",           @"tooltip":@"Select All — ⌘A"},
            @{@"id":@"delete",             @"type":@"timeline", @"category":@"Edit",       @"icon":@"trash",                              @"tooltip":@"Delete"},
            @{@"id":@"cut",                @"type":@"timeline", @"category":@"Edit",       @"icon":@"scissors.badge.ellipsis",            @"tooltip":@"Cut — ⌘X"},
            @{@"id":@"copy",               @"type":@"timeline", @"category":@"Edit",       @"icon":@"doc.on.doc",                         @"tooltip":@"Copy — ⌘C"},
            @{@"id":@"paste",              @"type":@"timeline", @"category":@"Edit",       @"icon":@"doc.on.clipboard",                   @"tooltip":@"Paste — ⌘V"},
            @{@"id":@"joinClips",          @"type":@"timeline", @"category":@"Edit",       @"icon":@"link",                               @"tooltip":@"Join Clips"},
            // ── Markers ──────────────────────────────────────────────────────
            @{@"id":@"addMarker",          @"type":@"timeline", @"category":@"Markers",    @"icon":@"bookmark.fill",                      @"tooltip":@"Add Marker — M"},
            @{@"id":@"addChapterMarker",   @"type":@"timeline", @"category":@"Markers",    @"icon":@"star.fill",                          @"tooltip":@"Add Chapter Marker"},
            @{@"id":@"addTodoMarker",      @"type":@"timeline", @"category":@"Markers",    @"icon":@"checkmark.seal.fill",                @"tooltip":@"Add To-Do Marker"},
            @{@"id":@"deleteMarker",       @"type":@"timeline", @"category":@"Markers",    @"icon":@"bookmark.slash.fill",                @"tooltip":@"Delete Marker"},
            @{@"id":@"nextMarker",         @"type":@"timeline", @"category":@"Markers",    @"icon":@"chevron.right",                      @"tooltip":@"Next Marker"},
            @{@"id":@"previousMarker",     @"type":@"timeline", @"category":@"Markers",    @"icon":@"chevron.left",                       @"tooltip":@"Previous Marker"},
            // ── Navigation ───────────────────────────────────────────────────
            @{@"id":@"goToStart",          @"type":@"playback", @"category":@"Navigation", @"icon":@"backward.end.fill",                  @"tooltip":@"Go to Start — Home"},
            @{@"id":@"goToEnd",            @"type":@"playback", @"category":@"Navigation", @"icon":@"forward.end.fill",                   @"tooltip":@"Go to End — End"},
            @{@"id":@"nextEdit",           @"type":@"timeline", @"category":@"Navigation", @"icon":@"forward.frame.fill",                 @"tooltip":@"Next Edit — ;"},
            @{@"id":@"previousEdit",       @"type":@"timeline", @"category":@"Navigation", @"icon":@"backward.frame.fill",                @"tooltip":@"Previous Edit — :"},
            @{@"id":@"selectClipAtPlayhead",@"type":@"timeline",@"category":@"Navigation", @"icon":@"cursorarrow.click",                  @"tooltip":@"Select Clip at Playhead — X"},
            // ── Color ────────────────────────────────────────────────────────
            @{@"id":@"addColorBoard",      @"type":@"timeline", @"category":@"Color",      @"icon":@"paintpalette",                       @"tooltip":@"Add Color Board"},
            @{@"id":@"addColorWheels",     @"type":@"timeline", @"category":@"Color",      @"icon":@"circle.hexagongrid",                 @"tooltip":@"Add Color Wheels"},
            @{@"id":@"addColorCurves",     @"type":@"timeline", @"category":@"Color",      @"icon":@"chart.line.uptrend.xyaxis",          @"tooltip":@"Add Color Curves"},
            @{@"id":@"balanceColor",       @"type":@"timeline", @"category":@"Color",      @"icon":@"wand.and.stars",                     @"tooltip":@"Balance Color — ⌥⌘B"},
            @{@"id":@"matchColor",         @"type":@"timeline", @"category":@"Color",      @"icon":@"eyedropper.halffull",                @"tooltip":@"Match Color"},
            @{@"id":@"addColorAdjustment", @"type":@"timeline", @"category":@"Color",      @"icon":@"slider.horizontal.3",               @"tooltip":@"Add Color Adjustment"},
            // ── Rating ───────────────────────────────────────────────────────
            @{@"id":@"favorite",           @"type":@"timeline", @"category":@"Rating",     @"icon":@"hand.thumbsup.fill",                 @"tooltip":@"Favorite — F"},
            @{@"id":@"reject",             @"type":@"timeline", @"category":@"Rating",     @"icon":@"hand.thumbsdown.fill",               @"tooltip":@"Reject — Delete"},
            @{@"id":@"unrate",             @"type":@"timeline", @"category":@"Rating",     @"icon":@"minus.circle",                       @"tooltip":@"Unrate — U"},
            // ── Speed ────────────────────────────────────────────────────────
            @{@"id":@"retimeSlow50",       @"type":@"timeline", @"category":@"Speed",      @"icon":@"tortoise.fill",                      @"tooltip":@"50% Slow Motion"},
            @{@"id":@"retimeFast2x",       @"type":@"timeline", @"category":@"Speed",      @"icon":@"hare.fill",                          @"tooltip":@"2× Fast Motion"},
            @{@"id":@"retimeNormal",       @"type":@"timeline", @"category":@"Speed",      @"icon":@"speedometer",                        @"tooltip":@"Normal Speed — ⌥⌘R"},
            @{@"id":@"retimeReverse",      @"type":@"timeline", @"category":@"Speed",      @"icon":@"arrow.counterclockwise",             @"tooltip":@"Reverse"},
            @{@"id":@"freezeFrame",        @"type":@"timeline", @"category":@"Speed",      @"icon":@"pause.circle.fill",                  @"tooltip":@"Freeze Frame — F"},
            // ── Trim ─────────────────────────────────────────────────────────
            @{@"id":@"trimToPlayhead",     @"type":@"timeline", @"category":@"Trim",       @"icon":@"crop",                               @"tooltip":@"Trim to Playhead"},
            @{@"id":@"extendEditToPlayhead",@"type":@"timeline",@"category":@"Trim",       @"icon":@"arrow.left.and.right.circle",        @"tooltip":@"Extend Edit to Playhead — ⇧X"},
            @{@"id":@"nudgeLeft",          @"type":@"timeline", @"category":@"Trim",       @"icon":@"arrow.left",                         @"tooltip":@"Nudge Left — ,"},
            @{@"id":@"nudgeRight",         @"type":@"timeline", @"category":@"Trim",       @"icon":@"arrow.right",                        @"tooltip":@"Nudge Right — ."},
            // ── View ─────────────────────────────────────────────────────────
            @{@"id":@"zoomToFit",          @"type":@"timeline", @"category":@"View",       @"icon":@"arrow.up.left.and.arrow.down.right", @"tooltip":@"Zoom to Fit — ⇧Z"},
            @{@"id":@"zoomIn",             @"type":@"timeline", @"category":@"View",       @"icon":@"plus.magnifyingglass",               @"tooltip":@"Zoom In — ⌘="},
            @{@"id":@"zoomOut",            @"type":@"timeline", @"category":@"View",       @"icon":@"minus.magnifyingglass",              @"tooltip":@"Zoom Out — ⌘-"},
            @{@"id":@"toggleInspector",    @"type":@"timeline", @"category":@"View",       @"icon":@"sidebar.right",                      @"tooltip":@"Toggle Inspector — ⌘4"},
            @{@"id":@"toggleSnapping",     @"type":@"timeline", @"category":@"View",       @"icon":@"magnet",                             @"tooltip":@"Toggle Snapping — N"},
            @{@"id":@"toggleSkimming",     @"type":@"timeline", @"category":@"View",       @"icon":@"eye",                                @"tooltip":@"Toggle Skimming — S"},
        ];
    });
    return sActions;
}

static NSDictionary *SCB_actionForID(NSString *actionID) {
    for (NSDictionary *a in SpliceKit_getAvailableTimecodeBarActions())
        if ([a[@"id"] isEqualToString:actionID]) return a;
    return nil;
}

// ──────────────────────────────────────────────────────────────────────────────
#pragma mark - Action dispatch
// ──────────────────────────────────────────────────────────────────────────────

static void SCB_fireAction(NSString *actionID, NSString *type) {
    if (!actionID) return;
    if ([type isEqualToString:@"playback"]) {
        static NSDictionary *map = nil;
        if (!map) map = @{
            @"goToStart":   @"goToStart:",
            @"goToEnd":     @"goToEnd:",
            @"playPause":   @"playPause:",
            @"nextFrame":   @"nextFrame:",
            @"prevFrame":   @"previousFrame:",
        };
        NSString *sel = map[actionID];
        if (sel) [[NSApplication sharedApplication] sendAction:NSSelectorFromString(sel) to:nil from:nil];
    } else {
        // timeline action — goes through the existing well-tested dispatcher
        SpliceKit_handleTimelineAction(@{@"action": actionID});
    }
}

// ──────────────────────────────────────────────────────────────────────────────
#pragma mark - Shortcut bar view
// ──────────────────────────────────────────────────────────────────────────────

@interface SpliceKitShortcutsBar : NSView
- (void)reloadFromConfig:(NSArray<NSDictionary *> *)config;
@end

@implementation SpliceKitShortcutsBar

- (instancetype)init {
    self = [super initWithFrame:NSZeroRect];
    self.translatesAutoresizingMaskIntoConstraints = NO;
    self.clipsToBounds = YES;
    return self;
}

- (void)reloadFromConfig:(NSArray<NSDictionary *> *)config {
    // Remove existing buttons
    for (NSView *sv in self.subviews.copy) [sv removeFromSuperview];
    if (!config.count) return;

    NSButton *prev = nil;
    for (NSDictionary *item in config) {
        NSString *actionID = item[@"id"];
        if (!actionID) continue;
        // Fill in icon/tooltip from catalogue if the config entry doesn't have them
        NSDictionary *meta = SCB_actionForID(actionID);
        NSString *type    = item[@"type"]    ?: meta[@"type"]    ?: @"timeline";
        NSString *icon    = item[@"icon"]    ?: meta[@"icon"]    ?: @"questionmark.circle";
        NSString *tooltip = item[@"tooltip"] ?: meta[@"tooltip"] ?: actionID;

        NSButton *btn = [NSButton buttonWithTitle:@"" target:self action:@selector(_buttonClicked:)];
        btn.identifier = [NSString stringWithFormat:@"%@|%@", actionID, type];
        btn.toolTip   = tooltip;
        btn.bezelStyle = NSBezelStyleInline;
        btn.bordered  = NO;
        btn.translatesAutoresizingMaskIntoConstraints = NO;

        // Build a symbol image at a size that matches FCP's own inline icons (~12pt)
        NSImage *img = [NSImage imageWithSystemSymbolName:icon accessibilityDescription:tooltip];
        if (img) {
            NSImageSymbolConfiguration *cfg = [NSImageSymbolConfiguration
                configurationWithPointSize:11.5
                                    weight:NSFontWeightRegular
                                     scale:NSImageSymbolScaleSmall];
            btn.image = [img imageWithSymbolConfiguration:cfg];
            btn.imageScaling = NSImageScaleProportionallyUpOrDown;
        }

        [self addSubview:btn];
        [NSLayoutConstraint activateConstraints:@[
            [btn.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [btn.widthAnchor   constraintEqualToConstant:kSCBButtonSize],
            [btn.heightAnchor  constraintEqualToConstant:kSCBButtonSize],
        ]];
        if (!prev) {
            [btn.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:kSCBGroupPad].active = YES;
        } else {
            [btn.leadingAnchor constraintEqualToAnchor:prev.trailingAnchor constant:kSCBButtonGap].active = YES;
        }
        prev = btn;
    }
    if (prev) {
        [prev.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-kSCBGroupPad].active = YES;
    }
}

- (void)_buttonClicked:(NSButton *)sender {
    NSString *raw = sender.identifier;
    NSArray *parts = [raw componentsSeparatedByString:@"|"];
    if (parts.count == 2) SCB_fireAction(parts[0], parts[1]);
}

@end

// ──────────────────────────────────────────────────────────────────────────────
#pragma mark - View hierarchy navigation
// ──────────────────────────────────────────────────────────────────────────────

// Returns the NSView that directly parents the toolbar's 20 subviews, or nil.
// Walks up from the active timeline module's view until it finds the
// LKContainerItemView labelled "PEMainEditorContainer", then returns the
// first NSView subview of its LKContainerItemCapView child.
static NSView *SCB_findToolbarView(void) {
    @try {
        id tm = SpliceKit_getActiveTimelineModule();
        if (!tm) return nil;

        NSView *v = nil;
        SEL viewSel = @selector(view);
        if ([tm respondsToSelector:viewSel])
            v = ((NSView *(*)(id, SEL))objc_msgSend)(tm, viewSel);
        if (!v) return nil;

        for (int depth = 0; depth < 16; depth++) {
            v = v.superview;
            if (!v) return nil;
            if ([[v description] containsString:@"PEMainEditorContainer"]) {
                // v is the LKContainerItemView — find its LKContainerItemCapView
                for (NSView *sv in v.subviews) {
                    if ([NSStringFromClass([sv class]) isEqualToString:@"LKContainerItemCapView"]) {
                        return sv.subviews.firstObject;
                    }
                }
                return nil;
            }
        }
    } @catch (__unused NSException *e) {}
    return nil;
}

// ──────────────────────────────────────────────────────────────────────────────
#pragma mark - Constraint surgery
// ──────────────────────────────────────────────────────────────────────────────

// Walk "X.trailing == Y.leading - C" chains leftward from snappingCtrl to find
// the leftmost view already pinned in the flex gap (e.g. transition audition
// buttons, any other SpliceKit toolbar buttons).  Returns snappingCtrl itself
// if nothing is pinned to its left.
static NSView *SCB_findRightAnchor(NSView *toolbar, NSView *snappingCtrl) {
    // Build a map: rightView → leftView for == trailing/leading pairs.
    NSMutableDictionary *pred = [NSMutableDictionary dictionary];
    for (NSLayoutConstraint *c in toolbar.constraints) {
        if (c.relation != NSLayoutRelationEqual)                    continue;
        if (c.firstAttribute  != NSLayoutAttributeTrailing)         continue;
        if (c.secondAttribute != NSLayoutAttributeLeading)          continue;
        id first = c.firstItem, second = c.secondItem;
        if (!first || !second) continue;
        // Accept any first-class view pinned to the snapping ctrl or another NSButton.
        NSString *secondCls = NSStringFromClass([second class]);
        if (!([secondCls isEqualToString:@"LKPaneCapSegmentedControl"] ||
              [secondCls isEqualToString:@"NSButton"])) continue;
        pred[[NSValue valueWithNonretainedObject:second]] = first;
    }
    // Walk left until no more predecessor.
    id current = snappingCtrl;
    for (int i = 0; i < 16; i++) {
        NSView *p = pred[[NSValue valueWithNonretainedObject:current]];
        if (!p) break;
        current = p;
    }
    return current;   // leftmost button, or snappingCtrl if chain was empty
}

// Finds H:[PEEditorMenuDelayButton]-(>=5)-[LKPaneCapSegmentedControl].
// The first item is the history-forward button; the second is snapping/skimming.
static BOOL SCB_findFlexConstraint(NSView *toolbar,
                                    NSView  * __strong *histFwdOut,
                                    NSView  * __strong *snappingOut,
                                    NSLayoutConstraint * __strong *cOut) {
    for (NSLayoutConstraint *c in toolbar.constraints) {
        id first = c.firstItem, second = c.secondItem;
        if (!first || !second) continue;
        if (c.relation != NSLayoutRelationGreaterThanOrEqual) continue;

        // Auto Layout normalizes H:[A]-(>=N)-[B] so that firstItem = B (leading-anchored)
        // and secondItem = A (trailing reference). Accept both orderings to be safe.
        NSString *firstName  = NSStringFromClass([first  class]);
        NSString *secondName = NSStringFromClass([second class]);

        NSView *histFwd = nil, *snapping = nil;
        if ([firstName  isEqualToString:@"LKPaneCapSegmentedControl"] &&
            [secondName isEqualToString:@"PEEditorMenuDelayButton"]) {
            // Normal (leading-normalized) storage: first=snapping, second=histFwd
            snapping = first;
            histFwd  = second;
        } else if ([firstName  isEqualToString:@"PEEditorMenuDelayButton"] &&
                   [secondName isEqualToString:@"LKPaneCapSegmentedControl"]) {
            // Reverse storage (unlikely but guard against it)
            histFwd  = first;
            snapping = second;
        } else {
            continue;
        }

        if (histFwdOut)  *histFwdOut  = histFwd;
        if (snappingOut) *snappingOut = snapping;
        if (cOut)        *cOut        = c;
        return YES;
    }
    return NO;
}

// ──────────────────────────────────────────────────────────────────────────────
#pragma mark - Manager
// ──────────────────────────────────────────────────────────────────────────────

@interface SpliceKitTimecodeBarShortcutsManager : NSObject
// Strong refs to the two anchor views keep them alive across reloads so we
// never need to re-search for the flex constraint.
@property (nonatomic, strong) SpliceKitShortcutsBar *shortcutsBar;
@property (nonatomic, strong) NSLayoutConstraint    *origFlexConstraint;
@property (nonatomic, strong) NSArray               *injectedConstraints;
@property (nonatomic, strong) NSView                *histFwdBtn;    // PEEditorMenuDelayButton
@property (nonatomic, strong) NSView                *snappingCtrl;  // LKPaneCapSegmentedControl
@property (nonatomic, assign) NSInteger              installRetries;
+ (instancetype)shared;
- (void)install;
- (NSString *)reload; // "ok" (installed/reloaded synchronously) or "pending" (still retrying — see log)
@end

@implementation SpliceKitTimecodeBarShortcutsManager

+ (instancetype)shared {
    static SpliceKitTimecodeBarShortcutsManager *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[self alloc] init]; });
    return s;
}

- (instancetype)init {
    self = [super init];
    _shortcutsBar = [[SpliceKitShortcutsBar alloc] init];
    return self;
}

// ── Install ──────────────────────────────────────────────────────────────────

- (void)install {
    SpliceKit_executeOnMainThread(^{ [self _installOnMainThread]; });
}

// Returns YES if the bar is installed (or already was) by the time this call
// returns; NO if a retry was scheduled (or retries were exhausted) and the
// caller should not treat this as a confirmed success.
- (BOOL)_installOnMainThread {
    // If the bar is already in a toolbar, nothing to do.
    if (_shortcutsBar.superview) return YES;

    NSView *toolbar = SCB_findToolbarView();
    if (!toolbar) {
        if (_installRetries++ < 20) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ [self _installOnMainThread]; });
        } else {
            SpliceKit_log(@"[TimecodeBarShortcuts] Toolbar not found after 20 retries — giving up");
        }
        return NO;
    }
    _installRetries = 0;

    NSView *histFwdBtn = nil, *snappingCtrl = nil;
    NSLayoutConstraint *flexC = nil;
    if (!SCB_findFlexConstraint(toolbar, &histFwdBtn, &snappingCtrl, &flexC)) {
        // Constraint not ready yet — retry (FCP may still be laying out on first launch).
        if (_installRetries++ < 20) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ [self _installOnMainThread]; });
        } else {
            SpliceKit_log(@"[TimecodeBarShortcuts] Flex constraint not found after 20 retries — giving up");
        }
        return NO;
    }

    // Keep strong refs to the anchors so reload never needs to search again.
    _histFwdBtn   = histFwdBtn;
    _snappingCtrl = snappingCtrl;

    // Build buttons from saved config and add bar.
    NSArray *config = SCB_loadConfig();
    [_shortcutsBar reloadFromConfig:config];
    [toolbar addSubview:_shortcutsBar];

    // Replace the original flex gap with two gaps flanking our bar.
    // For the right-side anchor use the leftmost view already pinned in the gap
    // (e.g. transition-audition buttons) so we don't overlap them.
    NSView *rightAnchor = SCB_findRightAnchor(toolbar, snappingCtrl);

    _origFlexConstraint = flexC;
    flexC.active = NO;

    NSLayoutConstraint *c1 = [NSLayoutConstraint
        constraintWithItem:_shortcutsBar
                 attribute:NSLayoutAttributeLeading
                 relatedBy:NSLayoutRelationGreaterThanOrEqual
                    toItem:histFwdBtn
                 attribute:NSLayoutAttributeTrailing
                multiplier:1.0 constant:kSCBGroupPad];
    c1.priority = NSLayoutPriorityDefaultHigh;

    NSLayoutConstraint *c2 = [NSLayoutConstraint
        constraintWithItem:rightAnchor
                 attribute:NSLayoutAttributeLeading
                 relatedBy:NSLayoutRelationGreaterThanOrEqual
                    toItem:_shortcutsBar
                 attribute:NSLayoutAttributeTrailing
                multiplier:1.0 constant:kSCBGroupPad];
    c2.priority = NSLayoutPriorityDefaultHigh;

    NSLayoutConstraint *c3 = [_shortcutsBar.centerYAnchor
        constraintEqualToAnchor:toolbar.centerYAnchor];
    NSLayoutConstraint *c4 = [_shortcutsBar.heightAnchor
        constraintEqualToConstant:kSCBButtonSize + 2.0];

    [NSLayoutConstraint activateConstraints:@[c1, c2, c3, c4]];
    _injectedConstraints = @[c1, c2, c3, c4];

    SpliceKit_log(@"[TimecodeBarShortcuts] Installed — %lu shortcuts", (unsigned long)config.count);
    return YES;
}

// ── Reload ───────────────────────────────────────────────────────────────────

// Returns "ok" once the bar reflects the current config, or "pending" if
// install is still retrying in the background (check the log for the
// eventual "giving up" message if it never resolves).
- (NSString *)reload {
    __block NSString *status = @"pending";
    SpliceKit_executeOnMainThread(^{
        if (_shortcutsBar.superview) {
            // Fast path: bar is already placed — just swap the buttons in place.
            NSArray *config = SCB_loadConfig();
            [_shortcutsBar reloadFromConfig:config];
            [_shortcutsBar.superview layoutSubtreeIfNeeded];
            SpliceKit_log(@"[TimecodeBarShortcuts] Reloaded — %lu shortcuts", (unsigned long)config.count);
            status = @"ok";
        } else {
            // Bar not installed yet (or was removed by FCP) — full install.
            _installRetries = 0;
            status = [self _installOnMainThread] ? @"ok" : @"pending";
        }
    });
    return status;
}

@end

// ──────────────────────────────────────────────────────────────────────────────
#pragma mark - Public C API
// ──────────────────────────────────────────────────────────────────────────────

static void SpliceKit_installTimecodeBarShortcuts(void) {
    [[SpliceKitTimecodeBarShortcutsManager shared] install];
}

static NSString *SpliceKit_reloadTimecodeBarShortcuts(void) {
    return [[SpliceKitTimecodeBarShortcutsManager shared] reload];
}

// ──────────────────────────────────────────────────────────────────────────────
#pragma mark - Plugin entry point
// ──────────────────────────────────────────────────────────────────────────────

__attribute__((visibility("default")))
void SpliceKitPlugin_init(SpliceKitPluginAPI *api) {
    sAPIStorage = *api;
    sAPI = &sAPIStorage;

    sAPI->log(@"[TimecodeBarShortcuts] Loading.");

    // Lets other plugins (e.g. com.splicekit.preferences-pane, which writes the
    // same JSON config file directly since native plugins can't call each
    // other's C functions across dlopen(RTLD_LOCAL) boundaries) trigger a live
    // reload after the user toggles a checkbox, without needing a restart.
    api->registerMethod(@"timecodeBarShortcuts.reload",
        ^NSDictionary *(NSDictionary *params) {
            (void)params;
            NSString *status = SpliceKit_reloadTimecodeBarShortcuts();
            return @{@"status": status};
        },
        @{@"description": @"Reload the timeline toolbar's shortcut buttons from the saved config.",
          @"readOnly": @NO});

    // Single source of truth for the action catalogue — other plugins (e.g.
    // com.splicekit.preferences-pane) fetch it through this RPC method rather
    // than keeping their own copy, so the two plugins can't drift apart.
    api->registerMethod(@"timecodeBarShortcuts.getCatalogue",
        ^NSDictionary *(NSDictionary *params) {
            (void)params;
            return @{@"actions": SpliceKit_getAvailableTimecodeBarActions()};
        },
        @{@"description": @"Return the canonical list of actions available for timeline toolbar shortcuts.",
          @"readOnly": @YES});

    api->executeOnMainThreadAsync(^{
        SpliceKit_installTimecodeBarShortcuts();
    });

    sAPI->log(@"[TimecodeBarShortcuts] Loaded.");
}
