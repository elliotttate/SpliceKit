//
//  TimelineTabs.m
//  com.splicekit.timeline-tabs
//
//  Named project tabs for Final Cut Pro's timeline navigation.
//  Survives SpliceKit patcher updates — the entire feature lives here.
//
//  Creates a dedicated 28 px row between the viewer/browser section
//  (PEUpperDeckContainer) and the timeline section (PELowerDeckContainer) by
//  shrinking PELowerDeckContainer by kTabBarHeight from its top edge and
//  inserting SpliceKitTimelineTabsView as a native subview of the shared
//  LKContainerView.  No floating panel, no event monitors, no coverage of
//  any existing UI.
//
//  FCP's layout engine resets child frames on resize; we observe
//  NSViewFrameDidChangeNotification on PELowerDeckContainer and re-apply the
//  reduction immediately, keeping the dedicated row intact.
//

#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import "SpliceKitPluginAPI.h"

static SpliceKitPluginAPI  sAPIStorage;
static SpliceKitPluginAPI *sAPI = NULL;

#define SpliceKit_log(...) (sAPI ? sAPI->log(__VA_ARGS__) : (void)0)
#define SpliceKit_executeOnMainThread(block) (sAPI ? sAPI->executeOnMainThread(block) : (void)0)

// Provided by the host binary — a shared, non-migrated utility that stays in
// the core dylib. Resolved at load time via -undefined dynamic_lookup.
extern id SpliceKit_getActiveTimelineModule(void);

// ---------------------------------------------------------------------------
// Layout constants
// ---------------------------------------------------------------------------

static const CGFloat kTabBarHeight    = 28.0;
static const CGFloat kTabMinWidth     = 72.0;
static const CGFloat kTabMaxWidth     = 200.0;
static const CGFloat kTabHPad         = 10.0;
static const CGFloat kCloseButtonSize = 14.0;
static const CGFloat kTabSeparator    =  1.0;

// ---------------------------------------------------------------------------
// Colors
// ---------------------------------------------------------------------------

static NSColor *TT_colorTabActive(void)    { return [NSColor colorWithSRGBRed:0.28 green:0.28 blue:0.30 alpha:1.0]; }
static NSColor *TT_colorTabInactive(void)  { return [NSColor colorWithSRGBRed:0.18 green:0.18 blue:0.20 alpha:0.92]; }
static NSColor *TT_colorTabHover(void)     { return [NSColor colorWithSRGBRed:0.24 green:0.24 blue:0.26 alpha:1.0]; }
static NSColor *TT_colorBarBackground(void){ return [NSColor colorWithSRGBRed:0.13 green:0.13 blue:0.14 alpha:1.0]; }
static NSColor *TT_colorText(void)         { return [NSColor colorWithSRGBRed:0.93 green:0.93 blue:0.93 alpha:1.0]; }
static NSColor *TT_colorTextInactive(void) { return [NSColor colorWithSRGBRed:0.65 green:0.65 blue:0.67 alpha:1.0]; }
static NSColor *TT_colorClose(void)        { return [NSColor colorWithSRGBRed:0.60 green:0.60 blue:0.62 alpha:1.0]; }
static NSColor *TT_colorCloseHover(void)   { return [NSColor colorWithSRGBRed:0.90 green:0.90 blue:0.90 alpha:1.0]; }
static NSColor *TT_colorSeparator(void)    { return [NSColor colorWithSRGBRed:0.08 green:0.08 blue:0.09 alpha:1.0]; }

// ---------------------------------------------------------------------------
// Tab model
// ---------------------------------------------------------------------------

@interface SpliceKitTabEntry : NSObject
@property (nonatomic, copy)   NSString *displayName;
@property (nonatomic, copy)   NSString *uid;
@property (nonatomic, strong) id        sequenceObject;
@property (nonatomic, assign) uintptr_t sequenceID;
@end
@implementation SpliceKitTabEntry
@end

// ---------------------------------------------------------------------------
// ObjC helpers
// ---------------------------------------------------------------------------

static id TT_getEditorContainer(void) {
    id app = [NSApplication sharedApplication];
    id delegate = ((id (*)(id, SEL))objc_msgSend)(app, @selector(delegate));
    if (!delegate) return nil;
    SEL s = NSSelectorFromString(@"activeEditorContainer");
    if (![delegate respondsToSelector:s]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(delegate, s);
}

static id TT_currentSequence(void) {
    id tm = SpliceKit_getActiveTimelineModule();
    if (!tm) return nil;
    SEL s = NSSelectorFromString(@"sequence");
    if (![tm respondsToSelector:s]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(tm, s);
}

static NSString *TT_sequenceDisplayName(id seq) {
    if (!seq) return nil;
    SEL s = NSSelectorFromString(@"displayName");
    if (![seq respondsToSelector:s]) return @"Untitled";
    NSString *name = ((id (*)(id, SEL))objc_msgSend)(seq, s);
    return name.length ? name : @"Untitled";
}

static NSString *TT_sequenceUID(id seq) {
    if (!seq) return nil;
    for (NSString *selName in @[@"uid", @"uniqueID", @"identifier", @"persistentID"]) {
        SEL sel = NSSelectorFromString(selName);
        if ([seq respondsToSelector:sel]) {
            id val = ((id (*)(id, SEL))objc_msgSend)(seq, sel);
            if (val) return [val description];
        }
    }
    return [NSString stringWithFormat:@"hash-%@-%lx",
            TT_sequenceDisplayName(seq), (unsigned long)[seq hash]];
}

static NSURL *TT_tabsSaveURL(void) {
    NSURL *appSupport = [[[NSFileManager defaultManager]
        URLsForDirectory:NSApplicationSupportDirectory
               inDomains:NSUserDomainMask] firstObject];
    NSURL *dir = [appSupport URLByAppendingPathComponent:@"SpliceKit"];
    [[NSFileManager defaultManager] createDirectoryAtURL:dir
                             withIntermediateDirectories:YES attributes:nil error:nil];
    return [dir URLByAppendingPathComponent:@"timeline_tabs.json"];
}

// Walk all sequences in every open library, trying UID first then display name.
// UID may be hash-based and stale after restart; display name is the reliable fallback.
static id TT_findSequenceByUIDOrName(NSString *uid, NSString *name) {
    @try {
        SEL libsSel = NSSelectorFromString(@"copyActiveLibraries");
        Class libDoc = NSClassFromString(@"FFLibraryDocument");
        if (!libDoc || ![libDoc respondsToSelector:libsSel]) return nil;
        id libs = ((id (*)(id, SEL))objc_msgSend)(libDoc, libsSel);
        if (!libs) return nil;

        id nameMatch = nil; // keep first name match in case UID never hits

        for (NSInteger i = 0, n = [libs count]; i < n; i++) {
            id lib = [libs objectAtIndex:i];
            SEL deepSel = NSSelectorFromString(@"_deepLoadedSequences");
            if (![lib respondsToSelector:deepSel]) continue;
            id seqSet = ((id (*)(id, SEL))objc_msgSend)(lib, deepSel);
            if (!seqSet) continue;
            for (id seq in ((id (*)(id, SEL))objc_msgSend)(seqSet, @selector(allObjects))) {
                // Exact UID match — return immediately.
                if (uid.length && [TT_sequenceUID(seq) isEqualToString:uid]) return seq;
                // Name match — store as fallback (prefer first match).
                if (!nameMatch && name.length &&
                    [TT_sequenceDisplayName(seq) isEqualToString:name]) {
                    nameMatch = seq;
                }
            }
        }
        return nameMatch;
    } @catch (__unused NSException *e) {}
    return nil;
}

// ---------------------------------------------------------------------------
// Tab bar view
// ---------------------------------------------------------------------------

@interface SpliceKitTimelineTabsView : NSView {
    NSInteger _hoveredTabIndex;
    NSInteger _hoveredCloseIndex;
    NSInteger _dragTabIndex;
    NSInteger _dragInsertIndex;
    NSPoint   _dragStartPoint;
    CGFloat   _dragCurrentX;
    BOOL      _dragging;
    NSTrackingArea *_trackingArea;
}
@property (nonatomic, strong) NSMutableArray<SpliceKitTabEntry *> *tabs;
@property (nonatomic, assign) NSInteger activeIndex;
@property (nonatomic, copy)   void (^onTabSelected)(NSInteger);
@property (nonatomic, copy)   void (^onTabClosed)(NSInteger);
@property (nonatomic, copy)   void (^onTabReordered)(NSInteger from, NSInteger to);
+ (instancetype)shared;
- (void)reloadData;
@end

@implementation SpliceKitTimelineTabsView

+ (instancetype)shared {
    static SpliceKitTimelineTabsView *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[self alloc] initWithFrame:NSZeroRect]; });
    return s;
}

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _tabs = [NSMutableArray array];
        _activeIndex = -1;
        _hoveredTabIndex = _hoveredCloseIndex = _dragTabIndex = -1;
    }
    return self;
}

// ── Layout ──────────────────────────────────────────────────────────────────

- (CGFloat)tabWidth {
    NSInteger n = (NSInteger)_tabs.count;
    if (n == 0) return kTabMaxWidth;
    return MAX(kTabMinWidth, MIN(kTabMaxWidth, self.bounds.size.width / n));
}

- (NSRect)rectForTabAtIndex:(NSInteger)i {
    CGFloat w = [self tabWidth];
    return NSMakeRect(i * (w + kTabSeparator), 0, w, kTabBarHeight);
}

- (NSRect)closeRectForTabAtIndex:(NSInteger)i {
    NSRect t = [self rectForTabAtIndex:i];
    CGFloat m = (kTabBarHeight - kCloseButtonSize) / 2.0;
    return NSMakeRect(NSMaxX(t) - m - kCloseButtonSize, m, kCloseButtonSize, kCloseButtonSize);
}

- (NSInteger)tabIndexAtPoint:(NSPoint)pt closeHit:(BOOL *)ch {
    for (NSInteger i = 0, n = (NSInteger)_tabs.count; i < n; i++) {
        if (!NSPointInRect(pt, [self rectForTabAtIndex:i])) continue;
        if (ch) *ch = NSPointInRect(pt, [self closeRectForTabAtIndex:i]);
        return i;
    }
    if (ch) *ch = NO;
    return -1;
}

// ── Drawing ──────────────────────────────────────────────────────────────────

- (void)_drawTab:(NSInteger)i inRect:(NSRect)tabRect isActive:(BOOL)isActive isHover:(BOOL)isHover {
    NSColor *bg = isActive ? TT_colorTabActive() : isHover ? TT_colorTabHover() : TT_colorTabInactive();
    [bg setFill];
    [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(tabRect, 0, 2) xRadius:4 yRadius:4] fill];

    NSRect cr = NSMakeRect(NSMaxX(tabRect) - (kTabBarHeight - kCloseButtonSize) / 2.0 - kCloseButtonSize,
                           (kTabBarHeight - kCloseButtonSize) / 2.0, kCloseButtonSize, kCloseButtonSize);
    BOOL chov = !_dragging && (i == _hoveredCloseIndex);
    NSString *xg = @"✕";
    NSDictionary *xa = @{
        NSFontAttributeName: [NSFont systemFontOfSize:9 weight:NSFontWeightMedium],
        NSForegroundColorAttributeName: chov ? TT_colorCloseHover() : TT_colorClose(),
    };
    NSSize xs = [xg sizeWithAttributes:xa];
    [xg drawAtPoint:NSMakePoint(cr.origin.x + (cr.size.width - xs.width) / 2.0,
                                cr.origin.y + (cr.size.height - xs.height) / 2.0)
     withAttributes:xa];

    NSDictionary *ta = @{
        NSFontAttributeName: [NSFont systemFontOfSize:11.5
                                               weight:isActive ? NSFontWeightMedium : NSFontWeightRegular],
        NSForegroundColorAttributeName: isActive ? TT_colorText() : TT_colorTextInactive(),
    };
    CGFloat w = tabRect.size.width;
    NSRect tr = NSMakeRect(tabRect.origin.x + kTabHPad,
                           (kTabBarHeight - 14.0) / 2.0,
                           w - kTabHPad - (cr.size.width + 4.0) - kTabHPad, 14.0);
    NSMutableAttributedString *mas = [[[NSAttributedString alloc]
        initWithString:_tabs[i].displayName attributes:ta] mutableCopy];
    NSMutableParagraphStyle *ps = [[NSMutableParagraphStyle alloc] init];
    ps.lineBreakMode = NSLineBreakByTruncatingTail;
    [mas addAttribute:NSParagraphStyleAttributeName value:ps range:NSMakeRange(0, mas.length)];
    [mas drawInRect:tr];
}

- (void)drawRect:(NSRect)dirtyRect {
    // Full background — we own this dedicated row so we can fill it.
    [TT_colorBarBackground() setFill];
    NSRectFill(self.bounds);

    NSInteger n = (NSInteger)_tabs.count;
    if (n == 0) {
        [TT_colorSeparator() setFill];
        NSRectFill(NSMakeRect(0, 0, self.bounds.size.width, 1));
        return;
    }

    static const CGFloat kDrop = 3.0;

    if (_dragging) {
        CGFloat x = 0, w = [self tabWidth];
        NSInteger slot = 0;
        for (NSInteger i = 0; i < n; i++) {
            if (i == _dragTabIndex) continue;
            if (slot == _dragInsertIndex) {
                [[NSColor colorWithSRGBRed:0.40 green:0.55 blue:0.90 alpha:0.9] setFill];
                NSRectFill(NSMakeRect(x, 2, kDrop, kTabBarHeight - 4));
                x += kDrop + 2.0;
            }
            NSRect tr = NSMakeRect(x, 0, w, kTabBarHeight);
            if (slot > 0) { [TT_colorSeparator() setFill]; NSRectFill(NSMakeRect(x - kTabSeparator, 2, kTabSeparator, kTabBarHeight - 4)); }
            [self _drawTab:i inRect:tr isActive:(i == _activeIndex) isHover:NO];
            x += w + kTabSeparator;
            slot++;
        }
        if (slot == _dragInsertIndex) {
            [[NSColor colorWithSRGBRed:0.40 green:0.55 blue:0.90 alpha:0.9] setFill];
            NSRectFill(NSMakeRect(x, 2, kDrop, kTabBarHeight - 4));
        }
        // Ghost tab at cursor
        CGFloat w2 = [self tabWidth];
        NSRect ghost = NSMakeRect(_dragCurrentX - w2 / 2.0, 0, w2, kTabBarHeight);
        [[NSGraphicsContext currentContext] saveGraphicsState];
        CGContextSetAlpha([[NSGraphicsContext currentContext] CGContext], 0.55);
        [self _drawTab:_dragTabIndex inRect:ghost isActive:(_dragTabIndex == _activeIndex) isHover:NO];
        [[NSGraphicsContext currentContext] restoreGraphicsState];
    } else {
        for (NSInteger i = 0; i < n; i++) {
            NSRect tabRect = [self rectForTabAtIndex:i];
            if (NSMaxX(tabRect) > self.bounds.size.width) break;
            if (i > 0) { [TT_colorSeparator() setFill]; NSRectFill(NSMakeRect(tabRect.origin.x - kTabSeparator, 2, kTabSeparator, kTabBarHeight - 4)); }
            [self _drawTab:i inRect:tabRect isActive:(i == _activeIndex) isHover:(i == _hoveredTabIndex)];
        }
    }

    [TT_colorSeparator() setFill];
    NSRectFill(NSMakeRect(0, 0, self.bounds.size.width, 1));
}

// ── Insertion index for drag ─────────────────────────────────────────────────

- (NSInteger)_insertIndexForDragX:(CGFloat)cx {
    CGFloat x = 0, w = [self tabWidth];
    NSInteger slot = 0;
    for (NSInteger i = 0, n = (NSInteger)_tabs.count; i < n; i++) {
        if (i == _dragTabIndex) continue;
        if (cx < x + w / 2.0) return slot;
        x += w + kTabSeparator;
        slot++;
    }
    return slot;
}

// ── Mouse tracking ───────────────────────────────────────────────────────────

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_trackingArea) [self removeTrackingArea:_trackingArea];
    _trackingArea = [[NSTrackingArea alloc]
        initWithRect:self.bounds
             options:NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways
               owner:self userInfo:nil];
    [self addTrackingArea:_trackingArea];
}

- (void)mouseMoved:(NSEvent *)e {
    if (_dragging) return;
    NSPoint pt = [self convertPoint:e.locationInWindow fromView:nil];
    BOOL ch = NO;
    NSInteger idx = [self tabIndexAtPoint:pt closeHit:&ch];
    NSInteger pc = _hoveredCloseIndex, pt2 = _hoveredTabIndex;
    _hoveredTabIndex   = idx;
    _hoveredCloseIndex = (idx >= 0 && ch) ? idx : -1;
    if (_hoveredTabIndex != pt2 || _hoveredCloseIndex != pc) [self setNeedsDisplay:YES];
}

- (void)mouseExited:(NSEvent *)e {
    _hoveredTabIndex = _hoveredCloseIndex = -1;
    [self setNeedsDisplay:YES];
}

- (void)mouseDown:(NSEvent *)e {
    NSPoint pt = [self convertPoint:e.locationInWindow fromView:nil];
    BOOL ch = NO;
    NSInteger idx = [self tabIndexAtPoint:pt closeHit:&ch];
    if (idx < 0) return;
    if (ch) { if (_onTabClosed) _onTabClosed(idx); }
    else { _dragTabIndex = idx; _dragStartPoint = pt; _dragging = NO; }
}

- (void)mouseDragged:(NSEvent *)e {
    if (_dragTabIndex < 0) return;
    NSPoint pt = [self convertPoint:e.locationInWindow fromView:nil];
    if (!_dragging) {
        if (ABS(pt.x - _dragStartPoint.x) < 4.0 && ABS(pt.y - _dragStartPoint.y) < 4.0) return;
        _dragging = YES;
        _hoveredTabIndex = _hoveredCloseIndex = -1;
    }
    _dragCurrentX    = pt.x;
    _dragInsertIndex = [self _insertIndexForDragX:pt.x];
    [self setNeedsDisplay:YES];
}

- (void)mouseUp:(NSEvent *)e {
    NSPoint pt = [self convertPoint:e.locationInWindow fromView:nil];
    if (_dragging) {
        _dragging = NO;
        NSInteger from = _dragTabIndex, to = [self _insertIndexForDragX:_dragCurrentX];
        if (to != from && _onTabReordered) _onTabReordered(from, to);
        _dragTabIndex = -1;
        [self setNeedsDisplay:YES];
    } else if (_dragTabIndex >= 0) {
        BOOL ch = NO;
        NSInteger idx = [self tabIndexAtPoint:pt closeHit:&ch];
        if (idx >= 0 && !ch && _onTabSelected) _onTabSelected(idx);
        _dragTabIndex = -1;
    }
}

- (void)reloadData { [self setNeedsDisplay:YES]; }

@end

// ---------------------------------------------------------------------------
// Tab manager
// ---------------------------------------------------------------------------

@interface SpliceKitTimelineTabs : NSObject
@property (nonatomic, strong) NSMutableArray<SpliceKitTabEntry *> *tabs;
@property (nonatomic, assign) NSInteger activeIndex;
@property (nonatomic, strong) NSMutableArray *observerTokens;
@property (nonatomic, assign) NSInteger installRetries;
// Native layout: the views we modify to create the dedicated tab row.
@property (nonatomic, weak)   NSView   *lkContainerView;   // LKContainerView (5 levels up)
@property (nonatomic, weak)   NSView   *lowerDeckView;     // PELowerDeckContainer
@property (nonatomic, assign) BOOL      applyingLayout;    // guard against notification loops
+ (instancetype)shared;
- (void)install;
- (void)uninstall;
- (void)onSequenceChanged;
- (void)selectTabAtIndex:(NSInteger)idx;
- (void)closeTabAtIndex:(NSInteger)idx;
- (void)reorderTabFrom:(NSInteger)from to:(NSInteger)to;
@end

static SpliceKitTimelineTabs *sTabsManager = nil;

@implementation SpliceKitTimelineTabs

+ (instancetype)shared {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ sTabsManager = [[self alloc] init]; });
    return sTabsManager;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _tabs = [NSMutableArray array];
        _activeIndex = -1;
        _observerTokens = [NSMutableArray array];
    }
    return self;
}

// ── Sequence tracking ────────────────────────────────────────────────────────

- (void)onSequenceChanged {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [self _updateTabsForCurrentSequence]; });
}

- (void)_updateTabsForCurrentSequence {
    id seq = TT_currentSequence();
    if (!seq) return;
    uintptr_t seqID = (uintptr_t)(__bridge void *)seq;
    NSString *uid   = TT_sequenceUID(seq);
    NSString *name  = TT_sequenceDisplayName(seq);

    NSInteger existingIdx = -1;
    for (NSInteger i = 0; i < (NSInteger)_tabs.count; i++) {
        SpliceKitTabEntry *t = _tabs[i];
        if (t.sequenceID == seqID ||
            (uid.length  && [t.uid isEqualToString:uid]) ||
            (name.length && [t.displayName isEqualToString:name]))  // name fallback for stale UIDs
            { existingIdx = i; break; }
    }
    if (existingIdx >= 0) {
        _activeIndex = existingIdx;
        _tabs[existingIdx].displayName    = name;
        _tabs[existingIdx].uid            = uid;
        _tabs[existingIdx].sequenceObject = seq;
        _tabs[existingIdx].sequenceID     = seqID;
    } else {
        SpliceKitTabEntry *e = [SpliceKitTabEntry new];
        e.displayName = name; e.uid = uid; e.sequenceObject = seq; e.sequenceID = seqID;
        [_tabs addObject:e];
        _activeIndex = (NSInteger)_tabs.count - 1;
    }
    [self _syncView]; [self _saveTabState];
}

- (void)selectTabAtIndex:(NSInteger)idx {
    if (idx < 0 || idx >= (NSInteger)_tabs.count || idx == _activeIndex) return;
    SpliceKitTabEntry *entry = _tabs[idx];

    // Resolve the sequence object lazily from the saved UID.
    // Resolve the sequence — try UID first, then fall back to display name.
    // Hash-based UIDs (saved when no persistent ID was available) become stale
    // after restart, so the name fallback is essential.
    if (!entry.sequenceObject) {
        entry.sequenceObject = TT_findSequenceByUIDOrName(entry.uid, entry.displayName);
        if (entry.sequenceObject) {
            entry.sequenceID = (uintptr_t)(__bridge void *)entry.sequenceObject;
            // Refresh the UID now that we have a live object (may be more stable).
            entry.uid = TT_sequenceUID(entry.sequenceObject) ?: entry.uid;
        }
    }
    if (!entry.sequenceObject) {
        SpliceKit_log(@"[TimelineTabs] Cannot navigate to '%@' — not found by UID or name",
                      entry.displayName);
        return;
    }

    // Highlight the tab immediately so the user sees their click was registered.
    // FCP fires activeRootItemDidChange asynchronously; _updateTabsForCurrentSequence
    // will confirm and persist the new activeIndex once FCP finishes loading.
    _activeIndex = idx;
    [self _syncView];

    id ec = TT_getEditorContainer();
    SEL s = NSSelectorFromString(@"loadEditorForSequence:");
    if (ec && [ec respondsToSelector:s])
        ((void (*)(id,SEL,id))objc_msgSend)(ec, s, entry.sequenceObject);
}

- (void)closeTabAtIndex:(NSInteger)idx {
    if (idx < 0 || idx >= (NSInteger)_tabs.count) return;
    BOOL wasActive = (idx == _activeIndex);
    [_tabs removeObjectAtIndex:idx];
    if (_tabs.count == 0) { _activeIndex = -1; }
    else if (wasActive) { NSInteger ni = idx > 0 ? idx - 1 : 0; _activeIndex = ni; [self selectTabAtIndex:ni]; return; }
    else if (_activeIndex > idx) { _activeIndex--; }
    [self _syncView]; [self _saveTabState];
}

- (void)reorderTabFrom:(NSInteger)from to:(NSInteger)to {
    NSInteger n = (NSInteger)_tabs.count;
    if (from < 0 || from >= n || to < 0 || to > n || from == to) return;
    SpliceKitTabEntry *entry = _tabs[from];
    [_tabs removeObjectAtIndex:from];
    NSInteger insertAt = MAX(0, MIN(to, (NSInteger)_tabs.count));
    [_tabs insertObject:entry atIndex:insertAt];
    if (_activeIndex == from) _activeIndex = insertAt;
    else if (from < _activeIndex && insertAt >= _activeIndex) _activeIndex--;
    else if (from > _activeIndex && insertAt <= _activeIndex) _activeIndex++;
    [self _syncView]; [self _saveTabState];
}

- (void)_syncView {
    SpliceKitTimelineTabsView *v = [SpliceKitTimelineTabsView shared];
    v.tabs = _tabs; v.activeIndex = _activeIndex; [v reloadData];
}

// ── Persistence ──────────────────────────────────────────────────────────────

- (void)_saveTabState {
    NSMutableArray *arr = [NSMutableArray array];
    for (SpliceKitTabEntry *e in _tabs)
        [arr addObject:@{@"name": e.displayName ?: @"", @"uid": e.uid ?: @""}];
    NSDictionary *dict = @{@"tabs": arr, @"activeIndex": @(_activeIndex)};
    NSData *data = [NSJSONSerialization dataWithJSONObject:dict options:0 error:nil];
    if (data) [data writeToURL:TT_tabsSaveURL() atomically:YES];
}

- (void)_loadTabState {
    NSData *data = [NSData dataWithContentsOfURL:TT_tabsSaveURL()];
    if (!data) return;
    NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![dict isKindOfClass:[NSDictionary class]]) return;
    NSArray *arr = dict[@"tabs"];
    if (![arr isKindOfClass:[NSArray class]]) return;
    [_tabs removeAllObjects];
    for (NSDictionary *item in arr) {
        SpliceKitTabEntry *e = [SpliceKitTabEntry new];
        e.displayName = item[@"name"] ?: @"Untitled";
        e.uid         = item[@"uid"]  ?: @"";
        [_tabs addObject:e];
    }
    NSInteger si = [dict[@"activeIndex"] integerValue];
    _activeIndex = _tabs.count > 0 ? MAX(0, MIN(si, (NSInteger)_tabs.count - 1)) : -1;
    SpliceKit_log(@"[TimelineTabs] Loaded %lu tabs", (unsigned long)_tabs.count);
}

// ── Native layout: create dedicated row ──────────────────────────────────────

// Walk up from timeline module view until we find the LKContainerView that
// directly contains BOTH PELowerDeckContainer and PEUpperDeckContainer.
// From our live exploration that is 7 levels up (not 5 — there is an extra
// LKContainerView + LKContainerItemView layer around PELowerDeckContainer).
- (NSView *)_findLKContainerView {
    @try {
        id tm = SpliceKit_getActiveTimelineModule();
        if (!tm) return nil;
        NSView *v = [(id)tm performSelector:@selector(view)];
        for (int i = 0; i < 10; i++) {   // walk up to 10 levels, stop when we find both decks
            v = v.superview;
            if (!v) return nil;
            BOOL hasLower = NO, hasUpper = NO;
            for (NSView *sv in v.subviews) {
                NSString *desc = [sv description];
                if ([desc containsString:@"LowerDeck"]) hasLower = YES;
                if ([desc containsString:@"UpperDeck"]) hasUpper = YES;
            }
            if (hasLower && hasUpper) return v;
        }
    } @catch (__unused NSException *e) {}
    return nil;
}

// Apply (or re-apply) the 28px reduction to PELowerDeckContainer.
// Positions the tab view in the gap and marks the guard flag.
- (void)_applyLowerDeckReduction {
    if (_applyingLayout || !_lowerDeckView || !_lkContainerView) return;

    NSRect deckFrame = _lowerDeckView.frame;
    if (deckFrame.size.height <= kTabBarHeight) return; // deck too small

    SpliceKitTimelineTabsView *tabView = [SpliceKitTimelineTabsView shared];

    // Compute what the reduced deck frame and tab frame should be.
    // Must account for whether LKContainerView is flipped (y=0 at top, y increases
    // downward — typical for LunaKit) or non-flipped (y=0 at bottom).
    NSRect newDeckFrame = deckFrame;
    NSRect tabFrame;

    if (_lkContainerView.isFlipped) {
        // Flipped: deckFrame.origin.y is the TOP edge of the lower deck.
        // Shrink from the top → push origin.y DOWN (larger y), reduce height.
        newDeckFrame.origin.y  += kTabBarHeight;
        newDeckFrame.size.height -= kTabBarHeight;
        // Tab bar sits at the OLD top edge (the 28 px gap we opened).
        tabFrame = NSMakeRect(deckFrame.origin.x, deckFrame.origin.y,
                              deckFrame.size.width, kTabBarHeight);
    } else {
        // Non-flipped: deckFrame.origin.y is the BOTTOM edge.
        // Shrink from the top → keep origin.y, reduce height.
        newDeckFrame.size.height -= kTabBarHeight;
        // Tab bar sits at the new top edge of the lower deck.
        tabFrame = NSMakeRect(deckFrame.origin.x,
                              newDeckFrame.origin.y + newDeckFrame.size.height,
                              deckFrame.size.width, kTabBarHeight);
    }

    // Skip if already applied (avoids thrashing when the observer fires for our own setFrame:).
    if (tabView.superview == _lkContainerView &&
        ABS(_lowerDeckView.frame.size.height - newDeckFrame.size.height) < 0.5 &&
        ABS(tabView.frame.origin.y - tabFrame.origin.y) < 0.5) return;

    _applyingLayout = YES;
    _lowerDeckView.frame = newDeckFrame;
    if (tabView.superview != _lkContainerView) {
        tabView.autoresizingMask = NSViewWidthSizable;
        [_lkContainerView addSubview:tabView];
    }
    tabView.frame = tabFrame;
    _applyingLayout = NO;

    SpliceKit_log(@"[TimelineTabs] Applied reduction: deck h=%.0f tab y=%.0f (flipped=%d)",
                  newDeckFrame.size.height, tabFrame.origin.y, (int)_lkContainerView.isFlipped);
}

// ── Install ───────────────────────────────────────────────────────────────────

- (void)install {
    [self _loadTabState];
    SpliceKit_executeOnMainThread(^{ [self _installOnMainThread]; });
}

- (void)_installOnMainThread {
    NSView *lkContainer = [self _findLKContainerView];
    if (!lkContainer) {
        if (_installRetries++ < 20) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ [self _installOnMainThread]; });
        } else {
            SpliceKit_log(@"[TimelineTabs] LKContainerView not found — giving up");
        }
        return;
    }
    _installRetries = 0;

    // Find PELowerDeckContainer among LKContainerView's subviews.
    NSView *lowerDeck = nil;
    for (NSView *sv in lkContainer.subviews) {
        if ([[sv description] containsString:@"LowerDeck"]) { lowerDeck = sv; break; }
    }
    if (!lowerDeck) {
        SpliceKit_log(@"[TimelineTabs] PELowerDeckContainer not found");
        return;
    }

    _lkContainerView = lkContainer;
    _lowerDeckView   = lowerDeck;

    // Wire up the tab view callbacks.
    SpliceKitTimelineTabsView *tabView = [SpliceKitTimelineTabsView shared];
    tabView.tabs = _tabs; tabView.activeIndex = _activeIndex;
    __weak SpliceKitTimelineTabs *weakSelf = self;
    tabView.onTabSelected  = ^(NSInteger i) { [weakSelf selectTabAtIndex:i]; };
    tabView.onTabClosed    = ^(NSInteger i) { [weakSelf closeTabAtIndex:i]; };
    tabView.onTabReordered = ^(NSInteger f, NSInteger t) { [weakSelf reorderTabFrom:f to:t]; };

    // Create the dedicated row.
    [self _applyLowerDeckReduction];

    // Re-apply whenever FCP's layout engine resets the lower deck frame.
    lowerDeck.postsFrameChangedNotifications = YES;
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    id t1 = [nc addObserverForName:NSViewFrameDidChangeNotification object:lowerDeck queue:nil
                        usingBlock:^(NSNotification *n) {
        [weakSelf _applyLowerDeckReduction];
    }];
    // Also track sequence changes.
    id t2 = [nc addObserverForName:@"activeRootItemDidChange" object:nil queue:nil
                        usingBlock:^(NSNotification *n) {
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf onSequenceChanged]; });
    }];
    id t3 = [nc addObserverForName:@"PEActivePlayerModuleDidChangeNotification" object:nil queue:nil
                        usingBlock:^(NSNotification *n) {
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf onSequenceChanged]; });
    }];
    id t4 = [nc addObserverForName:@"FFTimelineIndexDidReloadArrangedItemsNotification" object:nil queue:nil
                        usingBlock:^(NSNotification *n) {
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf onSequenceChanged]; });
    }];
    [_observerTokens addObjectsFromArray:@[t1, t2, t3, t4]];

    [self _syncView];
    [self onSequenceChanged];
    SpliceKit_log(@"[TimelineTabs] Installed as native subview of LKContainerView");
}

// ── Uninstall ─────────────────────────────────────────────────────────────────

- (void)uninstall {
    SpliceKit_executeOnMainThread(^{
        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        for (id tok in _observerTokens) [nc removeObserver:tok];
        [_observerTokens removeAllObjects];

        // Restore lower deck to its natural size and remove our tab view.
        if (_lowerDeckView) {
            SpliceKitTimelineTabsView *tv = [SpliceKitTimelineTabsView shared];
            if (tv.superview == _lkContainerView) {
                // Restore the 28px we took.
                NSRect f = _lowerDeckView.frame;
                f.size.height += kTabBarHeight;
                _lowerDeckView.frame = f;
                [tv removeFromSuperview];
            }
        }
        [_tabs removeAllObjects];
        _activeIndex = -1;
        _lowerDeckView = nil;
        _lkContainerView = nil;
    });
}

@end

// ---------------------------------------------------------------------------
// Public C API
// ---------------------------------------------------------------------------

static BOOL sTabsInstalled = NO;

static void SpliceKit_installTimelineTabs(void) {
    if (sTabsInstalled) return;
    sTabsInstalled = YES;
    [[SpliceKitTimelineTabs shared] install];
}

// ---------------------------------------------------------------------------
#pragma mark - Plugin entry point
// ---------------------------------------------------------------------------

__attribute__((visibility("default")))
void SpliceKitPlugin_init(SpliceKitPluginAPI *api) {
    sAPIStorage = *api;
    sAPI = &sAPIStorage;

    sAPI->log(@"[TimelineTabs] Loading.");

    api->executeOnMainThreadAsync(^{
        SpliceKit_installTimelineTabs();
    });

    sAPI->log(@"[TimelineTabs] Loaded.");
}
