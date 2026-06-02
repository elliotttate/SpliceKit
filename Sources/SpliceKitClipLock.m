// SpliceKitClipLock.m
//
// Adds clip, compound-clip, and connected-clip locking to FCP.
// A locked clip cannot be moved, trimmed, deleted, cut, or have effects dropped onto it.
//
// LOCK STORAGE
//   Locked clip identifiers are stored in NSUserDefaults under "SpliceKitLockedClipIds"
//   as an NSArray<NSString *> of UUID strings.  Because each clip has a globally-unique
//   identifier in FCP's model, a single flat set covers all sequences in all libraries.
//
// SWIZZLE POINTS
//   1. TLKTimelineView.menuForEvent:
//        Right-click menu → "Lock Clip" / "Unlock Clip"
//   2. FFAnchoredTimelineModule.timelineView:shouldMoveItems:byPlacingItem:inContainer:atIndex:atTime:
//        Blocks drag-move of locked clips (returns NO → FCP refuses the move).
//   3. FFAnchoredTimelineModule._validateTrimAction:
//        Blocks trim of locked clips (returns NO → trim cursor disabled).
//   4. FFAnchoredTimelineModule.validateUserInterfaceItem:withSelectedItems:
//        Blocks delete/cut/effects-drop on locked clips by returning NO for
//        destructive action selectors when the selection contains a locked clip.
//
// KEYBOARD SHORTCUT
//   ⌥L registered as LKCommand "SKLockClip" via the same path as ReplaceAtPlayhead.
//
// RPC METHODS  (all routed through SpliceKit_registerPluginMethod)
//   clips.lock          — lock clip at playhead (or by handle)
//   clips.unlock        — unlock clip at playhead (or by handle)
//   clips.toggleLock    — toggle lock on clip at playhead
//   clips.isLocked      — return lock state of clip at playhead
//   clips.listLocked    — list all currently locked clip IDs
//   clips.unlockAll     — clear all locks

#import "SpliceKit.h"
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

// ---------------------------------------------------------------------------
// CMTime (inline, no CoreMedia link needed)
// ---------------------------------------------------------------------------

typedef struct {
    int64_t value;
    int32_t timescale;
    uint32_t flags;
    int64_t epoch;
} CL_CMTime;

// ---------------------------------------------------------------------------
// Persistence — clip metadata via mdSetLocalValue:forKey:
//
// FCP stores metadata in the library's SQLite database, so it survives
// restarts, FCP updates, and anything short of deleting the library.
// No external file or NSUserDefaults needed.
//
// Key: "SpliceKitLocked"  Value: "1" (present = locked, absent = unlocked)
//
// In-memory state:
//   sAnyLockedInTimeline — quick flag so CL_hasAnyLockedClips() is O(1).
//   Updated whenever a lock changes or a new sequence is loaded.
// ---------------------------------------------------------------------------

static NSString * const kSKLockedKey   = @"SpliceKitLocked";
static NSString * const kSKLockedValue = @"1";

static BOOL         sAnyLockedInTimeline = NO;
static NSLock      *sLockStateLock;          // guards sAnyLockedInTimeline
static NSHashTable *sSessionLockedClips;     // weak-ref in-session cache
static os_unfair_lock sSessionLock = OS_UNFAIR_LOCK_INIT; // guards sSessionLockedClips

static void CL_ensureState(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sLockStateLock      = [[NSLock alloc] init];
        sSessionLockedClips = [NSHashTable weakObjectsHashTable];
    });
}

// Thread-safe cache helpers
static BOOL CL_cacheContains(id clip) {
    os_unfair_lock_lock(&sSessionLock);
    BOOL found = [sSessionLockedClips containsObject:clip];
    os_unfair_lock_unlock(&sSessionLock);
    return found;
}
static void CL_cacheAdd(id clip) {
    os_unfair_lock_lock(&sSessionLock);
    [sSessionLockedClips addObject:clip];
    os_unfair_lock_unlock(&sSessionLock);
}
static void CL_cacheRemove(id clip) {
    os_unfair_lock_lock(&sSessionLock);
    [sSessionLockedClips removeObject:clip];
    os_unfair_lock_unlock(&sSessionLock);
}

// ---------------------------------------------------------------------------
// Two-tier lock check:
//
//   CL_isLockedClip(clip)        — CACHE ONLY.  Safe to call from any swizzle
//                                   that fires during an active FCP operation
//                                   (delete, trim, move, volume).  Never reads
//                                   the library DB — mdLocalValueForKey: crashes
//                                   when called on a clip that is mid-operation.
//
//   CL_isLockedClipDB(clip)      — CACHE + DB fallback.  Only safe to call from
//                                   idle contexts: RPC handlers, startup scans,
//                                   and _startListeningToSequence: (which fires
//                                   before any user interaction on the new seq).
// ---------------------------------------------------------------------------

static BOOL CL_isLockedClip(id clip) {
    if (!clip) return NO;
    CL_ensureState();
    // Cache-only check. No ObjC messages to clip beyond what's already safe.
    // parentItem walks are in CL_isLockedClipDB (idle contexts only).
    return CL_cacheContains(clip);
}

static BOOL CL_isLockedClipDB(id clip) {
    if (!clip) return NO;
    CL_ensureState();
    if (CL_cacheContains(clip)) return YES;
    SEL sel = NSSelectorFromString(@"mdLocalValueForKey:");
    if (![clip respondsToSelector:sel]) return NO;
    @try {
        id val = ((id (*)(id, SEL, id))objc_msgSend)(clip, sel, kSKLockedKey);
        if (val) { CL_cacheAdd(clip); return YES; }
    } @catch (...) {}
    // Walk up one level.
    SEL parentSel = NSSelectorFromString(@"parentItem");
    if (![clip respondsToSelector:parentSel]) return NO;
    id parent = nil;
    @try { parent = ((id (*)(id, SEL))objc_msgSend)(clip, parentSel); }
    @catch (...) { return NO; }
    if (!parent || parent == clip) return NO;
    if (CL_cacheContains(parent)) return YES;
    @try {
        id val = ((id (*)(id, SEL, id))objc_msgSend)(parent, sel, kSKLockedKey);
        if (val) { CL_cacheAdd(parent); return YES; }
    } @catch (...) {}
    id grandparent = nil;
    @try { grandparent = ((id (*)(id, SEL))objc_msgSend)(parent, parentSel); }
    @catch (...) { return NO; }
    if (!grandparent || grandparent == parent) return NO;
    if (CL_cacheContains(grandparent)) return YES;
    @try {
        id val = ((id (*)(id, SEL, id))objc_msgSend)(grandparent, sel, kSKLockedKey);
        if (val) { CL_cacheAdd(grandparent); return YES; }
    } @catch (...) {}
    return NO;
}

// Write lock state.
// Immediately updates sSessionLockedClips (so the lock is effective right away)
// and attempts to persist via mdSetLocalValue:forKey: + action wrappers (which
// commits to the library's SQLite for cross-restart persistence).
static void CL_setClipLocked(id clip, BOOL locked) {
    if (!clip) return;
    CL_ensureState();
    // Update in-session cache immediately.
    if (locked) CL_cacheAdd(clip);
    else        CL_cacheRemove(clip);

    // Persist to DB (best-effort — may silently fail if clip is not in an
    // active editing context, but will work via the right-click/⌥L paths
    // where the clip is always selected/active).
    SEL setSel   = NSSelectorFromString(@"mdSetLocalValue:forKey:");
    SEL beginSel = NSSelectorFromString(@"actionBeginSetMetadataValue");
    SEL endSel   = NSSelectorFromString(@"actionEndSetMetadataValueWithError:");
    if (![clip respondsToSelector:setSel]) return;
    @try {
        if ([clip respondsToSelector:beginSel])
            ((void (*)(id, SEL))objc_msgSend)(clip, beginSel);
        id value = locked ? kSKLockedValue : nil;
        ((void (*)(id, SEL, id, id))objc_msgSend)(clip, setSel, value, kSKLockedKey);
        if ([clip respondsToSelector:endSel])
            ((BOOL (*)(id, SEL, id *))objc_msgSend)(clip, endSel, NULL);
    } @catch (...) {}
}

// Clips live at sequence.primaryObject.allContainedItems — NOT sequence.allContainedItems
// (which returns nil on FFAnchoredSequence).
static NSArray *CL_getSpineItems(id seq) {
    if (!seq) return nil;
    SEL primarySel = NSSelectorFromString(@"primaryObject");
    if (![seq respondsToSelector:primarySel]) return nil;
    id primary = nil;
    @try { primary = ((id (*)(id, SEL))objc_msgSend)(seq, primarySel); } @catch (...) { return nil; }
    if (!primary) return nil;
    SEL allSel = NSSelectorFromString(@"allContainedItems");
    if (![primary respondsToSelector:allSel]) return nil;
    @try { return ((id (*)(id, SEL))objc_msgSend)(primary, allSel); } @catch (...) { return nil; }
}

// Scan the sequence owned by timelineModule and update the quick flag.
static void CL_updateAnyLockedFlag(id timelineModule) {
    SEL seqSel = NSSelectorFromString(@"sequence");
    if (!timelineModule || ![timelineModule respondsToSelector:seqSel]) return;
    id seq = ((id (*)(id, SEL))objc_msgSend)(timelineModule, seqSel);
    NSArray *items = CL_getSpineItems(seq);
    if (!items) return;
    BOOL found = NO;
    for (id item in items) { if (CL_isLockedClipDB(item)) { found = YES; break; } }
    [sLockStateLock lock];
    sAnyLockedInTimeline = found;
    [sLockStateLock unlock];
}

// ---------------------------------------------------------------------------
// Collection helpers (used by swizzles)
// ---------------------------------------------------------------------------

// Returns YES if any item in the array is locked.
static BOOL CL_arrayContainsLocked(NSArray *items) {
    for (id item in items) {
        if (CL_isLockedClip(item)) return YES;
    }
    return NO;
}

// Returns YES if any *selected* item in the given timeline module is locked.
static BOOL CL_selectionContainsLocked(id timelineModule) {
    if (!timelineModule) return NO;
    SEL sel = NSSelectorFromString(@"selectedItems");
    if (![timelineModule respondsToSelector:sel]) return NO;
    @try {
        NSArray *items = ((id (*)(id, SEL))objc_msgSend)(timelineModule, sel);
        return CL_arrayContainsLocked(items);
    } @catch (...) { return NO; }
}

// Returns the first selected clip in the active timeline module.
static id CL_clipAtPlayhead(void) {
    id tm = SpliceKit_getActiveTimelineModule();
    if (!tm) return nil;
    SEL itemsSel = NSSelectorFromString(@"selectedItems");
    if (![tm respondsToSelector:itemsSel]) return nil;
    @try {
        NSArray *items = ((id (*)(id, SEL))objc_msgSend)(tm, itemsSel);
        return items.firstObject;
    } @catch (...) { return nil; }
}

// Forward declaration needed before shouldRippleEdge swizzle.
static BOOL CL_hasAnyLockedClips(void);

// ---------------------------------------------------------------------------
// Display name prefix — shows 🔒 on locked clips in the timeline label,
// inspector, and browser.  We swizzle the getter only; the stored ivar
// (_displayName) is never touched so FCPXML export is unaffected.
// ---------------------------------------------------------------------------

static IMP sOrigDisplayName = NULL;

static NSString *CL_swizzled_displayName(id self, SEL _cmd) {
    NSString *orig = sOrigDisplayName
        ? ((NSString *(*)(id, SEL))sOrigDisplayName)(self, _cmd)
        : @"";
    // Only check the in-memory cache — never walk parentItem here.
    // displayName is called on clips mid-deletion; parentItem on a
    // partially-deallocated object causes EXC_BAD_ACCESS.
    CL_ensureState();
    if (CL_cacheContains(self))
        return [NSString stringWithFormat:@"🔒 %@", orig];
    return orig;
}

// Force-refresh specific clips in the timeline view so the 🔒 label appears
// immediately without requiring a zoom or interaction.
//
// TLKTimelineView.reloadWithItemsAdded:removed:modified: is FCP's proper
// pipeline for pushing model changes to the layer system.  Passing a clip in
// the `modified:` array causes its TLKItemLayer to call setDisplayName: again
// with the fresh value from our swizzled FFAnchoredObject.displayName getter.
static void CL_refreshClips(NSArray *clips) {
    if (!clips.count) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        id tm = SpliceKit_getActiveTimelineModule();
        if (!tm) return;
        SEL viewSel = NSSelectorFromString(@"timelineView");
        if (![tm respondsToSelector:viewSel]) return;
        id view = ((id (*)(id, SEL))objc_msgSend)(tm, viewSel);
        if (!view) return;

        // Post KVO for each clip so bindings / observers see the new displayName.
        for (id clip in clips) {
            [clip willChangeValueForKey:@"displayName"];
            [clip didChangeValueForKey:@"displayName"];
        }

        // Tell the timeline view these items were modified → triggers a layer
        // refresh cycle that re-reads displayName from the model.
        SEL reloadSel = NSSelectorFromString(@"reloadWithItemsAdded:removed:modified:");
        if ([view respondsToSelector:reloadSel]) {
            NSArray *empty = @[];
            ((void (*)(id, SEL, id, id, id))objc_msgSend)(view, reloadSel,
                                                           empty, empty, clips);
        } else {
            // Fallback: queue each clip as updated and flush.
            SEL queueSel  = NSSelectorFromString(@"queueUpdatedObjectsForReload:ofType:");
            SEL flushSel  = NSSelectorFromString(@"reloadPendingChangesWithAnimation:");
            if ([view respondsToSelector:queueSel] && [view respondsToSelector:flushSel]) {
                for (id clip in clips) {
                    ((void (*)(id, SEL, id, id))objc_msgSend)(view, queueSel, clip, nil);
                }
                ((void (*)(id, SEL, BOOL))objc_msgSend)(view, flushSel, NO);
            } else {
                [view setNeedsDisplay:YES];
            }
        }
    });
}

// ---------------------------------------------------------------------------
// Swizzle 1 — TLKTimelineView.menuForEvent:
// ---------------------------------------------------------------------------

static IMP sOrigMenuForEvent_CL = NULL;

// Set of action selector name strings that are destructive (so we know when
// to gray items out in validateUserInterfaceItem:withSelectedItems:).
static NSSet<NSString *> *CL_destructiveActionNames(void) {
    static NSSet *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [NSSet setWithArray:@[
            @"delete:",
            @"cut:",
            @"performDeleteKey:",
            @"actionDelete:",
            @"actionCut:",
            @"actionTrimStart:",
            @"actionTrimEnd:",
            @"actionTrimToPlayhead:",
            @"actionExtendEdit:",
            @"actionJoinClips:",
            @"actionNudgeLeft:",
            @"actionNudgeRight:",
            @"actionNudgeUp:",
            @"actionNudgeDown:",
            @"moveToPlayhead:",
        ]];
    });
    return s;
}

// Handler object that lives forever — target for context menu items.
@interface SKClipLockMenuHandler : NSObject
+ (instancetype)shared;
- (void)toggleLockFromMenu:(NSMenuItem *)sender;
@end

@implementation SKClipLockMenuHandler
+ (instancetype)shared {
    static SKClipLockMenuHandler *inst;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [[SKClipLockMenuHandler alloc] init]; });
    return inst;
}

- (void)toggleLockFromMenu:(NSMenuItem *)sender {
    NSArray *clips = sender.representedObject;
    if (![clips isKindOfClass:[NSArray class]] || clips.count == 0) {
        id clip = CL_clipAtPlayhead();
        clips = clip ? @[clip] : @[];
    }
    NSMutableArray *changed = [NSMutableArray array];
    for (id clip in clips) {
        BOOL wasLocked = CL_isLockedClipDB(clip);
        CL_setClipLocked(clip, !wasLocked);
        [changed addObject:clip];
        SpliceKit_log(@"[ClipLock] %@ clip", wasLocked ? @"Unlocked" : @"Locked");
    }
    id tm = SpliceKit_getActiveTimelineModule();
    if (tm) CL_updateAnyLockedFlag(tm);
    CL_refreshClips(changed);
}
@end

static NSMenu *CL_swizzled_menuForEvent(id self, SEL _cmd, NSEvent *event) {
    // Call whatever is currently installed as the "original" — this may itself
    // be another SpliceKit swizzle (e.g. StructureBlocks), so we always chain.
    NSMenu *menu = sOrigMenuForEvent_CL
        ? ((NSMenu *(*)(id, SEL, NSEvent *))sOrigMenuForEvent_CL)(self, _cmd, event)
        : nil;

    id tm = SpliceKit_getActiveTimelineModule();
    if (!tm) return menu;

    SEL itemsSel = NSSelectorFromString(@"selectedItems");
    if (![tm respondsToSelector:itemsSel]) return menu;

    NSArray *selectedItems = nil;
    @try { selectedItems = ((id (*)(id, SEL))objc_msgSend)(tm, itemsSel); }
    @catch (...) { return menu; }
    if (![selectedItems isKindOfClass:[NSArray class]] || selectedItems.count == 0) return menu;

    // Filter to lockable types: skip gaps, transitions, markers.
    NSMutableArray *lockable = [NSMutableArray array];
    for (id item in selectedItems) {
        NSString *cls = NSStringFromClass([item class]) ?: @"";
        SEL isGapSel = NSSelectorFromString(@"isGap");
        if ([item respondsToSelector:isGapSel]) {
            @try { if (((BOOL (*)(id, SEL))objc_msgSend)(item, isGapSel)) continue; }
            @catch (...) {}
        }
        if ([cls containsString:@"Transition"]) continue;
        SEL isMarkerSel = NSSelectorFromString(@"isMarker");
        if ([item respondsToSelector:isMarkerSel]) {
            @try { if (((BOOL (*)(id, SEL))objc_msgSend)(item, isMarkerSel)) continue; }
            @catch (...) {}
        }
        [lockable addObject:item];
    }
    if (lockable.count == 0) return menu;

    // Are all lockable items currently locked?
    BOOL allLocked = YES;
    for (id clip in lockable) {
        if (!CL_isLockedClipDB(clip)) { allLocked = NO; break; }
    }

    if (!menu) menu = [[NSMenu alloc] initWithTitle:@""];
    if (menu.numberOfItems > 0) [menu addItem:[NSMenuItem separatorItem]];

    // Build the icon (lock emoji rendered into a small NSImage for the menu item)
    NSString *icon   = allLocked ? @"🔓" : @"🔒";
    NSString *verb   = allLocked ? @"Unlock" : @"Lock";
    NSString *suffix = lockable.count > 1 ? @" Clips" : @" Clip";
    NSString *title  = [NSString stringWithFormat:@"%@ %@%@", icon, verb, suffix];

    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title
                                                  action:@selector(toggleLockFromMenu:)
                                           keyEquivalent:@""];
    item.target = [SKClipLockMenuHandler shared];
    item.representedObject = lockable;

    // Show lock state of each clip in a sub-note if mixed
    BOOL anyLocked = NO, anyUnlocked = NO;
    for (id clip in lockable) {
        if (CL_isLockedClipDB(clip)) anyLocked = YES;
        else anyUnlocked = YES;
    }
    if (anyLocked && anyUnlocked) {
        item.title = [NSString stringWithFormat:@"🔒 Toggle Lock (%lu clips)",
                      (unsigned long)lockable.count];
    }

    [menu addItem:item];
    return menu;
}

// ---------------------------------------------------------------------------
// Swizzle 2 — FFAnchoredTimelineModule.timelineView:shouldMoveItems:...
// ---------------------------------------------------------------------------

typedef BOOL (*ShouldMoveItemsFn)(id, SEL, id, id, id, id, unsigned long long, CL_CMTime);
static ShouldMoveItemsFn sOrigShouldMoveItems = NULL;

static BOOL CL_swizzled_shouldMoveItems(id self, SEL _cmd,
                                         id timelineView,
                                         NSArray *items,
                                         id placingItem,
                                         id container,
                                         unsigned long long atIndex,
                                         CL_CMTime atTime)
{
    if (CL_arrayContainsLocked(items)) {
        NSBeep();
        SpliceKit_log(@"[ClipLock] Move blocked — selection contains a locked clip");
        return NO;
    }
    // Also block if the placingItem itself is locked
    if (CL_isLockedClip(placingItem)) {
        NSBeep();
        SpliceKit_log(@"[ClipLock] Move blocked — placing item is locked");
        return NO;
    }
    return sOrigShouldMoveItems
        ? sOrigShouldMoveItems(self, _cmd, timelineView, items, placingItem, container, atIndex, atTime)
        : YES;
}

// ---------------------------------------------------------------------------
// Swizzle 3 — FFAnchoredTimelineModule._validateTrimAction:
//   Controls the trim cursor appearance. Belt-and-suspenders alongside shouldTrimEdge.
// ---------------------------------------------------------------------------

typedef BOOL (*ValidateTrimFn)(id, SEL, id);
static ValidateTrimFn sOrigValidateTrimAction = NULL;

static BOOL CL_swizzled_validateTrimAction(id self, SEL _cmd, id action) {
    if (CL_selectionContainsLocked(self)) return NO;
    return sOrigValidateTrimAction
        ? sOrigValidateTrimAction(self, _cmd, action)
        : NO;
}

// ---------------------------------------------------------------------------
// Swizzle 4a — FFAnchoredTimelineModule.timelineView:shouldTrimEdge:trimType:edgeType:ofItems:byTimeOffset:movementType:
//   Called for every drag-trim on one or more items. Return NO to block.
// ---------------------------------------------------------------------------

typedef struct { int64_t v; int32_t ts; uint32_t fl; int64_t ep; } CL_CMTimeOffset;
typedef BOOL (*ShouldTrimEdgeMultiFn)(id, SEL, id, id, int, int, NSArray *, CL_CMTimeOffset *, int);
static ShouldTrimEdgeMultiFn sOrigShouldTrimEdgeMulti = NULL;

static BOOL CL_swizzled_shouldTrimEdgeMulti(id self, SEL _cmd,
                                              id timelineView,
                                              id trimEdge,
                                              int trimType,
                                              int edgeType,
                                              NSArray *ofItems,
                                              CL_CMTimeOffset *byTimeOffset,
                                              int movementType)
{
    if (CL_arrayContainsLocked(ofItems)) {
        NSBeep();
        SpliceKit_log(@"[ClipLock] Trim blocked — items contain a locked clip");
        return NO;
    }
    return sOrigShouldTrimEdgeMulti
        ? sOrigShouldTrimEdgeMulti(self, _cmd, timelineView, trimEdge, trimType, edgeType, ofItems, byTimeOffset, movementType)
        : YES;
}

// ---------------------------------------------------------------------------
// Swizzle 4b — FFAnchoredTimelineModule.timelineView:shouldTrimEdge:trimType:ofItem:byTimeOffset:movementType:
//   Single-item variant.
// ---------------------------------------------------------------------------

typedef BOOL (*ShouldTrimEdgeSingleFn)(id, SEL, id, id, int, id, CL_CMTimeOffset *, int);
static ShouldTrimEdgeSingleFn sOrigShouldTrimEdgeSingle = NULL;

static BOOL CL_swizzled_shouldTrimEdgeSingle(id self, SEL _cmd,
                                               id timelineView,
                                               id trimEdge,
                                               int trimType,
                                               id ofItem,
                                               CL_CMTimeOffset *byTimeOffset,
                                               int movementType)
{
    if (CL_isLockedClip(ofItem)) {
        NSBeep();
        SpliceKit_log(@"[ClipLock] Trim blocked — item is locked");
        return NO;
    }
    return sOrigShouldTrimEdgeSingle
        ? sOrigShouldTrimEdgeSingle(self, _cmd, timelineView, trimEdge, trimType, ofItem, byTimeOffset, movementType)
        : YES;
}

// ---------------------------------------------------------------------------
// Swizzle 4c — FFAnchoredTimelineModule.timelineView:shouldRippleEdge:ofItem:
//   Blocks ripple trim on locked clips.
// ---------------------------------------------------------------------------

typedef BOOL (*ShouldRippleEdgeFn)(id, SEL, id, id, id);
static ShouldRippleEdgeFn sOrigShouldRippleEdge = NULL;

static BOOL CL_swizzled_shouldRippleEdge(id self, SEL _cmd, id timelineView, id edge, id ofItem) {
    // Block if the item itself is locked.
    if (CL_isLockedClip(ofItem)) { NSBeep(); return NO; }
    // Block if ANY locked clips exist in the timeline: ripple shifts every clip
    // to the right of the trim point, which would move locked clips downstream.
    if (CL_hasAnyLockedClips()) {
        NSBeep();
        SpliceKit_log(@"[ClipLock] Ripple trim blocked — locked clips present in timeline");
        return NO;
    }
    return sOrigShouldRippleEdge
        ? sOrigShouldRippleEdge(self, _cmd, timelineView, edge, ofItem)
        : YES;
}

// ---------------------------------------------------------------------------
// Swizzle 4c2 — FFAnchoredTimelineModule.timelineView:shouldAnchorItems:...
//
// Fired when the user drags a clip UP out of the primary storyline (turning it
// into a connected clip) or drags a connected clip to a new anchor point.
// Block if any item being anchored is locked.
// ---------------------------------------------------------------------------

typedef BOOL (*ShouldAnchorItemsFn)(id, SEL, id, NSArray *, id, id, id, CL_CMTime);
static ShouldAnchorItemsFn sOrigShouldAnchorItems = NULL;

static BOOL CL_swizzled_shouldAnchorItems(id self, SEL _cmd,
                                           id timelineView,
                                           NSArray *items,
                                           id container,
                                           id anchoringItem,
                                           id lane,
                                           CL_CMTime atTime)
{
    if (CL_arrayContainsLocked(items)) {
        NSBeep();
        SpliceKit_log(@"[ClipLock] Anchor/lift-from-spine blocked — locked clip");
        return NO;
    }
    return sOrigShouldAnchorItems
        ? sOrigShouldAnchorItems(self, _cmd, timelineView, items, container, anchoringItem, lane, atTime)
        : YES;
}

// ---------------------------------------------------------------------------
// Swizzle 4c3 — FFAnchoredTimelineModule.nudgeUp: / nudgeDown:
//
// Keyboard shortcuts ⌥↑/⌥↓ that move a clip to a different lane.
// Block on locked clips.
// ---------------------------------------------------------------------------

typedef void (*NudgeVerticalFn)(id, SEL, id);
static NudgeVerticalFn sOrigNudgeUp   = NULL;
static NudgeVerticalFn sOrigNudgeDown = NULL;

static void CL_swizzled_nudgeUp(id self, SEL _cmd, id sender) {
    if (CL_selectionContainsLocked(self)) { NSBeep(); return; }
    if (sOrigNudgeUp) sOrigNudgeUp(self, _cmd, sender);
}
static void CL_swizzled_nudgeDown(id self, SEL _cmd, id sender) {
    if (CL_selectionContainsLocked(self)) { NSBeep(); return; }
    if (sOrigNudgeDown) sOrigNudgeDown(self, _cmd, sender);
}

// ---------------------------------------------------------------------------
// Swizzles 4d-4g — Roll tool  (timelineView:shouldRollEdge:...)
//
// Roll trim moves the outgoing edge of `ofItem` and the incoming edge of
// `adjacentItem` simultaneously.  Block if EITHER clip is locked.
// There are four selector variants (with/without edgeType, with/without offset).
// ---------------------------------------------------------------------------

typedef BOOL (*ShouldRollEdgeTypeFn)(id, SEL, id, id, int, id, id);
typedef BOOL (*ShouldRollEdgeTypeOffFn)(id, SEL, id, id, int, id, id, CL_CMTimeOffset *);
typedef BOOL (*ShouldRollEdgeFn)(id, SEL, id, id, id, id);
typedef BOOL (*ShouldRollEdgeOffFn)(id, SEL, id, id, id, id, CL_CMTimeOffset *);
typedef BOOL (*ShouldRollRangeFn)(id, SEL, id, id, id, CL_CMTimeOffset *);

static ShouldRollEdgeTypeFn    sOrigShouldRollEdgeType    = NULL;
static ShouldRollEdgeTypeOffFn sOrigShouldRollEdgeTypeOff = NULL;
static ShouldRollEdgeFn        sOrigShouldRollEdge        = NULL;
static ShouldRollEdgeOffFn     sOrigShouldRollEdgeOff     = NULL;
static ShouldRollRangeFn       sOrigShouldRollRange       = NULL;

static BOOL CL_eitherLocked(id item, id adjacent) {
    return CL_isLockedClip(item) || CL_isLockedClip(adjacent);
}

static BOOL CL_swizzled_shouldRollEdgeType(id self, SEL _cmd, id view, id edge,
                                            int edgeType, id ofItem, id adjItem) {
    if (CL_eitherLocked(ofItem, adjItem)) { NSBeep(); return NO; }
    return sOrigShouldRollEdgeType
        ? sOrigShouldRollEdgeType(self, _cmd, view, edge, edgeType, ofItem, adjItem) : YES;
}

static BOOL CL_swizzled_shouldRollEdgeTypeOff(id self, SEL _cmd, id view, id edge,
                                               int edgeType, id ofItem, id adjItem,
                                               CL_CMTimeOffset *offset) {
    if (CL_eitherLocked(ofItem, adjItem)) { NSBeep(); return NO; }
    return sOrigShouldRollEdgeTypeOff
        ? sOrigShouldRollEdgeTypeOff(self, _cmd, view, edge, edgeType, ofItem, adjItem, offset) : YES;
}

static BOOL CL_swizzled_shouldRollEdge(id self, SEL _cmd, id view, id edge,
                                        id ofItem, id adjItem) {
    if (CL_eitherLocked(ofItem, adjItem)) { NSBeep(); return NO; }
    return sOrigShouldRollEdge
        ? sOrigShouldRollEdge(self, _cmd, view, edge, ofItem, adjItem) : YES;
}

static BOOL CL_swizzled_shouldRollEdgeOff(id self, SEL _cmd, id view, id edge,
                                           id ofItem, id adjItem, CL_CMTimeOffset *offset) {
    if (CL_eitherLocked(ofItem, adjItem)) { NSBeep(); return NO; }
    return sOrigShouldRollEdgeOff
        ? sOrigShouldRollEdgeOff(self, _cmd, view, edge, ofItem, adjItem, offset) : YES;
}

static BOOL CL_swizzled_shouldRollRange(id self, SEL _cmd, id view, id edge,
                                         id rangeItem, CL_CMTimeOffset *toTime) {
    if (CL_isLockedClip(rangeItem)) { NSBeep(); return NO; }
    return sOrigShouldRollRange
        ? sOrigShouldRollRange(self, _cmd, view, edge, rangeItem, toTime) : YES;
}

// ---------------------------------------------------------------------------
// Helper — are any locked clips in the current timeline?
//
// Fast path: O(1) flag set by CL_updateAnyLockedFlag() on lock/unlock and
// on sequence-load events.
//
// This is intentionally a fast O(1) flag check only. We do NOT do an inline
// scan of allContainedItems here because this function is called from inside
// active FCP operations (delete, trim, move) where reading clip metadata
// (mdLocalValueForKey:) is unsafe and can crash.
//
// sAnyLockedInTimeline is kept accurate by:
//   - CL_swizzled_startListeningToSequence: (project load)
//   - The 1s startup deferred scan in SpliceKit_installClipLock
//   - CL_updateAnyLockedFlag() after every lock/unlock operation
// ---------------------------------------------------------------------------

static BOOL CL_hasAnyLockedClips(void) {
    [sLockStateLock lock];
    BOOL any = sAnyLockedInTimeline;
    [sLockStateLock unlock];
    return any;
}

// ---------------------------------------------------------------------------
// Swizzle 4h — FFAnchoredSequence.operationTrimEdit:endEdits:edgeType:byDelta:trimCommand:...
//
// ALL trim-type operations (trim, roll, slip, slide) eventually reach one of
// these two FFAnchoredSequence methods.  `startEdits` and `endEdits` are
// NSArrays of FFAnchoredObject clips (the items whose edges are being changed).
// Block if any of them is locked.
//
// This also catches the keyboard slip/slide nudge path which bypasses the
// TLKTimelineView shouldTrimEdge: delegate chain entirely.
// ---------------------------------------------------------------------------

// CMTime struct for the byDelta parameter (24 bytes: qiIq)
typedef struct { int64_t v; int32_t ts; uint32_t fl; int64_t ep; } CL_CMTimeDelta;

// Variant 1 (without trimFlags)
typedef BOOL (*OpTrimEditFn)(id, SEL, id, id, int, CL_CMTimeDelta, int, int, id, id *);
static OpTrimEditFn sOrigOpTrimEdit = NULL;

static BOOL CL_swizzled_operationTrimEdit(id self, SEL _cmd,
                                           id startEdits, id endEdits,
                                           int edgeType,
                                           CL_CMTimeDelta byDelta,
                                           int trimCommand,
                                           int temporalResolutionMode,
                                           id animationHint,
                                           id *error)
{
    // Case A: a locked clip is directly being trimmed — always block.
    if (CL_arrayContainsLocked(startEdits) || CL_arrayContainsLocked(endEdits)) {
        NSBeep();
        SpliceKit_log(@"[ClipLock] operationTrimEdit blocked (trimCommand=%d) — locked clip in edits", trimCommand);
        return NO;
    }
    // Case B: one-sided trim (one array empty, one non-empty) = ripple trim.
    // Ripple shifts every downstream clip, which would move locked clips.
    // Roll/slip/slide are two-sided (both arrays non-empty) and don't shift positions.
    NSUInteger startCount = [startEdits count];
    NSUInteger endCount   = [endEdits   count];
    BOOL isRipple = (startCount == 0) != (endCount == 0); // XOR: exactly one side has items
    if (isRipple && CL_hasAnyLockedClips()) {
        NSBeep();
        SpliceKit_log(@"[ClipLock] operationTrimEdit blocked (ripple, trimCommand=%d) — locked clips present", trimCommand);
        return NO;
    }
    return sOrigOpTrimEdit
        ? sOrigOpTrimEdit(self, _cmd, startEdits, endEdits, edgeType, byDelta,
                          trimCommand, temporalResolutionMode, animationHint, error)
        : NO;
}

// Variant 2 (with trimFlags)
typedef BOOL (*OpTrimEditFlagsFn)(id, SEL, id, id, int, CL_CMTimeDelta, int, int, int, id, id *);
static OpTrimEditFlagsFn sOrigOpTrimEditFlags = NULL;

static BOOL CL_swizzled_operationTrimEditFlags(id self, SEL _cmd,
                                                id startEdits, id endEdits,
                                                int edgeType,
                                                CL_CMTimeDelta byDelta,
                                                int trimCommand,
                                                int trimFlags,
                                                int temporalResolutionMode,
                                                id animationHint,
                                                id *error)
{
    if (CL_arrayContainsLocked(startEdits) || CL_arrayContainsLocked(endEdits)) {
        NSBeep();
        SpliceKit_log(@"[ClipLock] operationTrimEditFlags blocked (trimCommand=%d) — locked clip in edits", trimCommand);
        return NO;
    }
    NSUInteger startCount = [startEdits count];
    NSUInteger endCount   = [endEdits   count];
    BOOL isRipple = (startCount == 0) != (endCount == 0);
    if (isRipple && CL_hasAnyLockedClips()) {
        NSBeep();
        SpliceKit_log(@"[ClipLock] operationTrimEditFlags blocked (ripple, trimCommand=%d) — locked clips present", trimCommand);
        return NO;
    }
    return sOrigOpTrimEditFlags
        ? sOrigOpTrimEditFlags(self, _cmd, startEdits, endEdits, edgeType, byDelta,
                               trimCommand, trimFlags, temporalResolutionMode, animationHint, error)
        : NO;
}

// ---------------------------------------------------------------------------
// Swizzle 4i — FFAnchoredTimelineModule.liftFromSpine:
// Lift from primary storyline detaches the clip into a connected clip.
// Block if any selected clip is locked.
// ---------------------------------------------------------------------------

typedef void (*LiftFromSpineFn)(id, SEL, id);
static LiftFromSpineFn sOrigLiftFromSpine = NULL;

static void CL_swizzled_liftFromSpine(id self, SEL _cmd, id sender) {
    if (CL_selectionContainsLocked(self)) {
        NSBeep();
        SpliceKit_log(@"[ClipLock] Lift from storyline blocked — locked clip selected");
        return;
    }
    if (sOrigLiftFromSpine) sOrigLiftFromSpine(self, _cmd, sender);
}

// ---------------------------------------------------------------------------
// Swizzles — Audio level / fade locking
//
// When a clip is locked its audio level and fade handles should be immutable.
//
// Intercept points:
//   adjustVolumeByAmount:isRelative:actionName: — core volume change, all
//     paths (keyboard ⌃+/⌃-, inspector slider, direct action) funnel here.
//   volumeUp: / volumeDown: / volumeZero: / volumeMinusInfinity: — discrete
//     menu/keyboard shortcuts.
//   fadeHandlesLayer:moveFadeAtIndex:toTime:symmetric:... — drag of audio
//     fade handles (in/out fade points on the clip waveform).
//   audioComponentSource:moveFadeAtIndex:toTime:... — programmatic fade move.
// ---------------------------------------------------------------------------

typedef void (*AdjustVolumeFn)(id, SEL, double, BOOL, id);
static AdjustVolumeFn sOrigAdjustVolumeByAmount = NULL;
static void CL_swizzled_adjustVolumeByAmount(id self, SEL _cmd, double amount,
                                              BOOL isRelative, id actionName) {
    if (CL_selectionContainsLocked(self)) { NSBeep(); return; }
    if (sOrigAdjustVolumeByAmount)
        sOrigAdjustVolumeByAmount(self, _cmd, amount, isRelative, actionName);
}

typedef void (*VolumeSenderFn)(id, SEL, id);
static VolumeSenderFn sOrigVolumeUp              = NULL;
static VolumeSenderFn sOrigVolumeDown            = NULL;
static VolumeSenderFn sOrigVolumeZero            = NULL;
static VolumeSenderFn sOrigVolumeMinusInfinity   = NULL;
static VolumeSenderFn sOrigAdjustVolumeAbsolute  = NULL;
static VolumeSenderFn sOrigAdjustVolumeRelative  = NULL;

#define MAKE_VOLUME_SWIZZLE(NAME, ORIG) \
static void CL_swizzled_##NAME(id self, SEL _cmd, id sender) { \
    if (CL_selectionContainsLocked(self)) { NSBeep(); return; } \
    if (ORIG) ORIG(self, _cmd, sender); \
}
MAKE_VOLUME_SWIZZLE(volumeUp,             sOrigVolumeUp)
MAKE_VOLUME_SWIZZLE(volumeDown,           sOrigVolumeDown)
MAKE_VOLUME_SWIZZLE(volumeZero,           sOrigVolumeZero)
MAKE_VOLUME_SWIZZLE(volumeMinusInfinity,  sOrigVolumeMinusInfinity)
MAKE_VOLUME_SWIZZLE(adjustVolumeAbsolute, sOrigAdjustVolumeAbsolute)
MAKE_VOLUME_SWIZZLE(adjustVolumeRelative, sOrigAdjustVolumeRelative)
#undef MAKE_VOLUME_SWIZZLE

// Fade handle drag — symmetric variant (most common)
typedef BOOL (*MoveFadeSymFn)(id, SEL, id, unsigned long long, CL_CMTimeOffset *, BOOL, id);
static MoveFadeSymFn sOrigMoveFadeSym = NULL;
static BOOL CL_swizzled_moveFadeSym(id self, SEL _cmd, id layer, unsigned long long idx,
                                     CL_CMTimeOffset *toTime, BOOL sym, id aligned) {
    if (CL_selectionContainsLocked(self)) { NSBeep(); return NO; }
    return sOrigMoveFadeSym
        ? sOrigMoveFadeSym(self, _cmd, layer, idx, toTime, sym, aligned) : NO;
}

// Fade handle drag — audio component source variant
typedef BOOL (*MoveFadeCompFn)(id, SEL, id, unsigned long long, CL_CMTimeOffset *, id);
static MoveFadeCompFn sOrigMoveFadeComp = NULL;
static BOOL CL_swizzled_moveFadeComp(id self, SEL _cmd, id src, unsigned long long idx,
                                      CL_CMTimeOffset *toTime, id aligned) {
    if (CL_selectionContainsLocked(self)) { NSBeep(); return NO; }
    return sOrigMoveFadeComp
        ? sOrigMoveFadeComp(self, _cmd, src, idx, toTime, aligned) : NO;
}

// ---------------------------------------------------------------------------
// Swizzle 4j — FFAnchoredTimelineModule._startListeningToSequence:
//
// Called every time a project/sequence is loaded into the timeline editor.
// We hook it to refresh the 🔒 label on any locked clips after the project
// opens — FCP's initial layout reads the ivar directly, bypassing our
// displayName getter, so the prefix doesn't appear until a reload is queued.
// ---------------------------------------------------------------------------

typedef void (*StartListeningFn)(id, SEL, id);
static StartListeningFn sOrigStartListeningToSequence = NULL;

static void CL_swizzled_startListeningToSequence(id self, SEL _cmd, id sequence) {
    if (sOrigStartListeningToSequence)
        sOrigStartListeningToSequence(self, _cmd, sequence);
    if (!sequence) return;

    // Delay slightly so the timeline view finishes its initial layout pass.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        NSArray *allItems = CL_getSpineItems(sequence);
        if (!allItems) return;

        NSMutableArray *locked = [NSMutableArray array];
        for (id item in allItems) {
            if (CL_isLockedClipDB(item)) {
                [locked addObject:item];
                // Populate the session cache so in-session checks are fast.
                CL_cacheAdd(item);
            }
        }
        // Update the quick flag.
        [sLockStateLock lock];
        sAnyLockedInTimeline = (locked.count > 0);
        [sLockStateLock unlock];

        if (locked.count) {
            SpliceKit_log(@"[ClipLock] Project loaded: refreshing 🔒 on %lu clip(s)",
                          (unsigned long)locked.count);
            CL_refreshClips(locked);
        }
    });
}

// ---------------------------------------------------------------------------
// Helper — returns YES if every item in the current selection is a gap clip.
// Used to exempt gap-only ripple deletes from the locked-clip position guard.
// ---------------------------------------------------------------------------

static BOOL CL_selectionIsOnlyGaps(id timelineModule) {
    SEL sel = NSSelectorFromString(@"selectedItems");
    if (![timelineModule respondsToSelector:sel]) return NO;
    NSArray *items = nil;
    @try { items = ((id (*)(id, SEL))objc_msgSend)(timelineModule, sel); }
    @catch (...) { return NO; }
    if (!items.count) return NO;
    SEL isGapSel = NSSelectorFromString(@"isGap");
    for (id item in items) {
        if (![item respondsToSelector:isGapSel]) return NO;
        if (!((BOOL (*)(id, SEL))objc_msgSend)(item, isGapSel)) return NO;
    }
    return YES;
}

// ---------------------------------------------------------------------------
// Swizzles — CHChannelDouble.setCurveDoubleValue:atTime:options:
//            CHChannel.setCurveValueWithDouble:atTime:options:
//
// The inspector volume slider and the clip rubber-band (in-timeline drag line)
// bypass FFAnchoredTimelineModule entirely and write directly to the clip's
// CHChannelDouble (audio level channel, a CH-framework wrapper around the
// Ozone parameter curve).  These two selectors are the actual write paths.
//
// We check the SELECTION rather than navigating the channel→clip parent chain,
// because when the user drags either control the clip is always selected.
// Swizzling on CHChannel (base class) covers both the decibel and double variants.
// ---------------------------------------------------------------------------

typedef void (*SetCurveDoubleFn)(id, SEL, double, CL_CMTime, unsigned int);
static SetCurveDoubleFn sOrigSetCurveDoubleValue    = NULL;
static SetCurveDoubleFn sOrigSetCurveValueWithDouble = NULL;

static void CL_swizzled_setCurveDoubleValue(id self, SEL _cmd, double value,
                                             CL_CMTime atTime, unsigned int options) {
    id tm = SpliceKit_getActiveTimelineModule();
    if (tm && CL_selectionContainsLocked(tm)) {
        NSBeep();
        SpliceKit_log(@"[ClipLock] CHChannelDouble write blocked — locked clip selected");
        return;
    }
    if (sOrigSetCurveDoubleValue) sOrigSetCurveDoubleValue(self, _cmd, value, atTime, options);
}

static void CL_swizzled_setCurveValueWithDouble(id self, SEL _cmd, double value,
                                                 CL_CMTime atTime, unsigned int options) {
    id tm = SpliceKit_getActiveTimelineModule();
    if (tm && CL_selectionContainsLocked(tm)) {
        NSBeep();
        return;
    }
    if (sOrigSetCurveValueWithDouble) sOrigSetCurveValueWithDouble(self, _cmd, value, atTime, options);
}

// ---------------------------------------------------------------------------
// Swizzle — FFAnchoredSequence.actionChangeAudioVolume:byAmount:overRange:isRelative:error:
//
// The sequence-level volume change used by the inspector slider and the clip
// rubber-band volume overlay (the horizontal drag line on the clip waveform).
// `items` is the NSArray of clips whose volume is being changed.
//
// CMTimeRange = two CMTime structs = 48 bytes total (non-HFA on arm64, passed on stack).
// ---------------------------------------------------------------------------

typedef struct {
    int64_t sv; int32_t sts; uint32_t sfl; int64_t sep;  // start CMTime
    int64_t dv; int32_t dts; uint32_t dfl; int64_t dep;  // duration CMTime
} CL_CMTimeRange_48;

typedef BOOL (*ActionChangeAudioVolFn)(id, SEL, id, double, CL_CMTimeRange_48, BOOL, id *);
static ActionChangeAudioVolFn sOrigActionChangeAudioVol = NULL;

static BOOL CL_swizzled_actionChangeAudioVol(id self, SEL _cmd,
                                              id items,
                                              double amount,
                                              CL_CMTimeRange_48 overRange,
                                              BOOL isRelative,
                                              id *error)
{
    // `items` is the array of clips being modified.
    if (CL_arrayContainsLocked(items)) {
        NSBeep();
        SpliceKit_log(@"[ClipLock] Volume change blocked — locked clip in items");
        return NO;
    }
    return sOrigActionChangeAudioVol
        ? sOrigActionChangeAudioVol(self, _cmd, items, amount, overRange, isRelative, error)
        : NO;
}

// ---------------------------------------------------------------------------
// Swizzles — FFAnchoredSequence.operationRemoveEdits:rootItem:preserveTime:...
//
// The actual delete path — _deleteCore: on the timeline module does NOT end
// up calling this (FCP's delete routes through the sequence directly).
//
// preserveTime=NO  → ripple delete (downstream clips shift left)
// preserveTime=YES → lift delete  (leaves a gap, positions preserved)
//
// When the selection contains a locked clip → block entirely (return NO).
// When ripple AND locked clips exist anywhere in the timeline → force
// preserveTime=YES so locked clips don't move.
// Exception: gap-only selections may still ripple freely.
//
// Two variants: with and without an explicit playhead CMTime parameter.
// ---------------------------------------------------------------------------

typedef BOOL (*OpRemoveEditsFn)(id, SEL, id, id, BOOL, BOOL, id *);
static OpRemoveEditsFn sOrigOpRemoveEdits = NULL;

static BOOL CL_swizzled_operationRemoveEdits(id self, SEL _cmd,
                                              id edits, id rootItem,
                                              BOOL preserveTime, BOOL preserveAnchors,
                                              id *error)
{
    // Case A: selected/deleted clips include a locked clip → block
    if (CL_arrayContainsLocked(edits)) {
        NSBeep();
        SpliceKit_log(@"[ClipLock] Delete blocked — edits contain a locked clip");
        return NO;
    }
    // Also check active selection for locked clips
    id tm = SpliceKit_getActiveTimelineModule();
    if (tm && CL_selectionContainsLocked(tm)) {
        NSBeep();
        SpliceKit_log(@"[ClipLock] Delete blocked — selection contains a locked clip");
        return NO;
    }
    // Case B: ripple delete + locked clips in timeline → lift instead
    if (!preserveTime && CL_hasAnyLockedClips()) {
        if (!CL_selectionIsOnlyGaps(tm)) {
            SpliceKit_log(@"[ClipLock] Ripple delete → lift delete (locked clips in timeline)");
            preserveTime = YES;
        }
    }
    return sOrigOpRemoveEdits
        ? sOrigOpRemoveEdits(self, _cmd, edits, rootItem, preserveTime, preserveAnchors, error)
        : NO;
}

// Variant with explicit playhead CMTime
// NOTE: operationRemoveEdits:...playhead:... swizzle removed.
// The playhead parameter is ^{?=qiIq} (pointer to CMTime), and swizzling this
// method during an active delete transaction crashes FCP (null ptr deref at FAR=0).
// Delete-blocking is handled at the delete: action level instead.

// Variant with range
typedef BOOL (*OpRemoveEditsRangeFn)(id, SEL, id, id, int, BOOL, BOOL, BOOL, id *);
static OpRemoveEditsRangeFn sOrigOpRemoveEditsRange = NULL;

static BOOL CL_swizzled_operationRemoveEditsRange(id self, SEL _cmd,
                                                   id ranges, id rootItem,
                                                   int editMode,
                                                   BOOL preserveTime, BOOL overwritePrep,
                                                   BOOL preservePartialAudio, id *error)
{
    id tm = SpliceKit_getActiveTimelineModule();
    if (tm && CL_selectionContainsLocked(tm)) { NSBeep(); return NO; }
    if (!preserveTime && CL_hasAnyLockedClips()) {
        if (!CL_selectionIsOnlyGaps(tm)) {
            SpliceKit_log(@"[ClipLock] Ripple delete (range) → lift delete");
            preserveTime = YES;
        }
    }
    return sOrigOpRemoveEditsRange
        ? sOrigOpRemoveEditsRange(self, _cmd, ranges, rootItem, editMode, preserveTime, overwritePrep, preservePartialAudio, error)
        : NO;
}

// ---------------------------------------------------------------------------
// Swizzles — FFAnchoredSequence.actionRemoveEdits:replaceWithGap:...
//            and actionRemoveEditsForRanges:replaceWithGap:...
//
// THIS is the method `delete:` on FFAnchoredTimelineModule actually calls.
// `_deleteCore` is never reached in practice.
//
// replaceWithGap=NO  → ripple delete (shifts downstream clips)
// replaceWithGap=YES → lift delete   (leaves a gap, positions preserved)
//
// Logic mirrors operationRemoveEdits:
//   A) edits or selection contains a locked clip → block entirely
//   B) ripple delete while any locked clip exists → force replaceWithGap=YES
// ---------------------------------------------------------------------------

typedef BOOL (*ActRemoveEditsFn)(id, SEL, id, BOOL, int, id, id *);
static ActRemoveEditsFn sOrigActRemoveEdits = NULL;

static BOOL CL_swizzled_actionRemoveEdits(id self, SEL _cmd,
                                          id edits, BOOL replaceWithGap,
                                          int removeOperation,
                                          id rootItem, id *error)
{
    if (CL_arrayContainsLocked(edits)) {
        NSBeep();
        SpliceKit_log(@"[ClipLock] actionRemoveEdits blocked — locked clip in edits");
        return NO;
    }
    id tm = SpliceKit_getActiveTimelineModule();
    if (tm && CL_selectionContainsLocked(tm)) {
        NSBeep();
        SpliceKit_log(@"[ClipLock] actionRemoveEdits blocked — selection contains a locked clip");
        return NO;
    }
    if (!replaceWithGap && CL_hasAnyLockedClips()) {
        if (tm && !CL_selectionIsOnlyGaps(tm)) {
            SpliceKit_log(@"[ClipLock] actionRemoveEdits: ripple → lift (locked clips in timeline)");
            replaceWithGap = YES;
        }
    }
    return sOrigActRemoveEdits
        ? sOrigActRemoveEdits(self, _cmd, edits, replaceWithGap, removeOperation, rootItem, error)
        : NO;
}

typedef BOOL (*ActRemoveEditsPhFn)(id, SEL, id, BOOL, int, id, CL_CMTime *, id *);
static ActRemoveEditsPhFn sOrigActRemoveEditsPh = NULL;

static BOOL CL_swizzled_actionRemoveEditsPh(id self, SEL _cmd,
                                             id edits, BOOL replaceWithGap,
                                             int removeOperation,
                                             id rootItem, CL_CMTime *playhead, id *error)
{
    if (CL_arrayContainsLocked(edits)) { NSBeep(); return NO; }
    id tm = SpliceKit_getActiveTimelineModule();
    if (tm && CL_selectionContainsLocked(tm)) { NSBeep(); return NO; }
    if (!replaceWithGap && CL_hasAnyLockedClips()) {
        if (tm && !CL_selectionIsOnlyGaps(tm)) {
            SpliceKit_log(@"[ClipLock] actionRemoveEdits+ph: ripple → lift");
            replaceWithGap = YES;
        }
    }
    return sOrigActRemoveEditsPh
        ? sOrigActRemoveEditsPh(self, _cmd, edits, replaceWithGap, removeOperation, rootItem, playhead, error)
        : NO;
}

typedef BOOL (*ActRemoveRangesFn)(id, SEL, id, BOOL, int, id, id *);
static ActRemoveRangesFn sOrigActRemoveRanges = NULL;

static BOOL CL_swizzled_actionRemoveEditsForRanges(id self, SEL _cmd,
                                                    id ranges, BOOL replaceWithGap,
                                                    int removeOperation,
                                                    id rootItem, id *error)
{
    id tm = SpliceKit_getActiveTimelineModule();
    if (tm && CL_selectionContainsLocked(tm)) {
        NSBeep();
        SpliceKit_log(@"[ClipLock] actionRemoveEditsForRanges blocked — locked clip selected");
        return NO;
    }
    if (!replaceWithGap && CL_hasAnyLockedClips()) {
        if (tm && !CL_selectionIsOnlyGaps(tm)) {
            SpliceKit_log(@"[ClipLock] actionRemoveEditsForRanges: ripple → lift");
            replaceWithGap = YES;
        }
    }
    return sOrigActRemoveRanges
        ? sOrigActRemoveRanges(self, _cmd, ranges, replaceWithGap, removeOperation, rootItem, error)
        : NO;
}

typedef BOOL (*ActRemoveRangesPhFn)(id, SEL, id, BOOL, int, id, CL_CMTime *, id *);
static ActRemoveRangesPhFn sOrigActRemoveRangesPh = NULL;

static BOOL CL_swizzled_actionRemoveEditsForRangesPh(id self, SEL _cmd,
                                                      id ranges, BOOL replaceWithGap,
                                                      int removeOperation,
                                                      id rootItem, CL_CMTime *playhead, id *error)
{
    id tm = SpliceKit_getActiveTimelineModule();
    if (tm && CL_selectionContainsLocked(tm)) { NSBeep(); return NO; }
    if (!replaceWithGap && CL_hasAnyLockedClips()) {
        if (tm && !CL_selectionIsOnlyGaps(tm)) {
            SpliceKit_log(@"[ClipLock] actionRemoveEditsForRanges+ph: ripple → lift");
            replaceWithGap = YES;
        }
    }
    return sOrigActRemoveRangesPh
        ? sOrigActRemoveRangesPh(self, _cmd, ranges, replaceWithGap, removeOperation, rootItem, playhead, error)
        : NO;
}

// ---------------------------------------------------------------------------
// Swizzle 5 — FFAnchoredTimelineModule.delete:
//
//   Intercepts the Delete key action BEFORE _deleteCore is entered.
//   This is safe: no clip objects are in an active operation state yet.
//
//   Behaviour:
//   A) Selected clips include a locked clip → block entirely (beep, return).
//   B) Ripple delete while locked clips exist → call shiftDelete: instead,
//      which replaces the selection with a gap (FCP's own gap-delete path).
//      Gap-only selections are exempted so the user can freely collapse gaps.
// ---------------------------------------------------------------------------

typedef void (*DeleteFn)(id, SEL, id);
static DeleteFn sOrigDelete = NULL;
static _Atomic(BOOL) sCLDeleteReentrancy = NO;

static void CL_swizzled_delete(id self, SEL _cmd, id sender) {
    if (sCLDeleteReentrancy) {
        if (sOrigDelete) sOrigDelete(self, _cmd, sender);
        return;
    }
    if (CL_selectionContainsLocked(self)) {
        NSBeep();
        SpliceKit_log(@"[ClipLock] Delete blocked — selection contains a locked clip");
        return;
    }
    if (CL_hasAnyLockedClips() && !CL_selectionIsOnlyGaps(self)) {
        SpliceKit_log(@"[ClipLock] Delete → shiftDelete (locked clips in timeline)");
        sCLDeleteReentrancy = YES;
        SEL shiftSel = NSSelectorFromString(@"shiftDelete:");
        if ([self respondsToSelector:shiftSel])
            ((void (*)(id, SEL, id))objc_msgSend)(self, shiftSel, sender);
        else if (sOrigDelete)
            sOrigDelete(self, _cmd, sender);
        sCLDeleteReentrancy = NO;
        return;
    }
    if (sOrigDelete) sOrigDelete(self, _cmd, sender);
}

// ---------------------------------------------------------------------------
// Swizzle 6 — FFAnchoredTimelineModule.validateUserInterfaceItem:withSelectedItems:
//   Grays out Delete / Cut menu items when locked clips are selected.
//   (Does NOT block keyboard shortcuts — _deleteCore: handles that.)
// ---------------------------------------------------------------------------

typedef BOOL (*ValidateUIFn)(id, SEL, id, NSArray *);
static ValidateUIFn sOrigValidateUI = NULL;

static BOOL CL_swizzled_validateUI(id self, SEL _cmd, id uiItem, NSArray *selectedItems) {
    BOOL orig = sOrigValidateUI
        ? sOrigValidateUI(self, _cmd, uiItem, selectedItems)
        : NO;
    if (!orig) return NO;
    if (!CL_arrayContainsLocked(selectedItems)) return orig;

    SEL action = NULL;
    @try { action = [uiItem action]; }
    @catch (...) { return orig; }
    if (!action) return orig;

    if ([CL_destructiveActionNames() containsObject:NSStringFromSelector(action)]) return NO;
    return orig;
}

// ---------------------------------------------------------------------------
// RPC methods
// ---------------------------------------------------------------------------

static id CL_clipAtPlayheadFromTM(id tm) {
    SEL sel = NSSelectorFromString(@"selectedItems");
    if (![tm respondsToSelector:sel]) return nil;
    @try {
        NSArray *items = ((id (*)(id, SEL))objc_msgSend)(tm, sel);
        return items.firstObject;
    } @catch (...) { return nil; }
}

static void CL_registerRPC(void) {
    // clips.lock
    SpliceKit_registerPluginMethod(@"clips.lock", ^NSDictionary *(NSDictionary *params) {
        __block NSString *result = nil;
        SpliceKit_executeOnMainThread(^{
            id tm = SpliceKit_getActiveTimelineModule();
            NSString *handle = params[@"handle"];
            id clip = handle ? SpliceKit_resolveHandle(handle) : CL_clipAtPlayheadFromTM(tm);
            if (!clip) { result = @"No clip found"; return; }
            CL_setClipLocked(clip, YES);
            if (tm) CL_updateAnyLockedFlag(tm);
            CL_refreshClips(@[clip]);
            result = @"Locked";
        });
        return @{@"result": result ?: @"ok"};
    }, @{@"description": @"Lock the selected clip (or clip by handle) to prevent moving or editing."});

    // clips.unlock
    SpliceKit_registerPluginMethod(@"clips.unlock", ^NSDictionary *(NSDictionary *params) {
        __block NSString *result = nil;
        SpliceKit_executeOnMainThread(^{
            id tm = SpliceKit_getActiveTimelineModule();
            NSString *handle = params[@"handle"];
            id clip = handle ? SpliceKit_resolveHandle(handle) : CL_clipAtPlayheadFromTM(tm);
            if (!clip) { result = @"No clip found"; return; }
            CL_setClipLocked(clip, NO);
            if (tm) CL_updateAnyLockedFlag(tm);
            CL_refreshClips(@[clip]);
            result = @"Unlocked";
        });
        return @{@"result": result ?: @"ok"};
    }, @{@"description": @"Unlock the selected clip (or clip by handle)."});

    // clips.toggleLock
    SpliceKit_registerPluginMethod(@"clips.toggleLock", ^NSDictionary *(NSDictionary *params) {
        __block NSDictionary *resp = nil;
        SpliceKit_executeOnMainThread(^{
            id tm = SpliceKit_getActiveTimelineModule();
            NSString *handle = params[@"handle"];
            id clip = handle ? SpliceKit_resolveHandle(handle) : CL_clipAtPlayheadFromTM(tm);
            if (!clip) { resp = @{@"error": @"No clip found"}; return; }
            BOOL nowLocked = !CL_isLockedClipDB(clip);
            CL_setClipLocked(clip, nowLocked);
            if (tm) CL_updateAnyLockedFlag(tm);
            CL_refreshClips(@[clip]);
            resp = @{@"locked": @(nowLocked)};
        });
        return resp ?: @{@"error": @"unknown error"};
    }, @{@"description": @"Toggle lock on the selected clip (or clip by handle)."});

    // clips.isLocked
    SpliceKit_registerPluginMethod(@"clips.isLocked", ^NSDictionary *(NSDictionary *params) {
        __block NSDictionary *resp = nil;
        SpliceKit_executeOnMainThread(^{
            id tm = SpliceKit_getActiveTimelineModule();
            NSString *handle = params[@"handle"];
            id clip = handle ? SpliceKit_resolveHandle(handle) : CL_clipAtPlayheadFromTM(tm);
            if (!clip) { resp = @{@"error": @"No clip found"}; return; }
            resp = @{@"locked": @(CL_isLockedClipDB(clip))};
        });
        return resp ?: @{@"error": @"unknown error"};
    }, @{@"description": @"Return whether the selected clip (or clip by handle) is locked."});

    // clips.listLocked — scans the current sequence
    SpliceKit_registerPluginMethod(@"clips.listLocked", ^NSDictionary *(NSDictionary *params) {
        __block NSDictionary *resp = nil;
        SpliceKit_executeOnMainThread(^{
            id tm = SpliceKit_getActiveTimelineModule();
            SEL seqSel = NSSelectorFromString(@"sequence");
            id seq = (tm && [tm respondsToSelector:seqSel])
                ? ((id (*)(id, SEL))objc_msgSend)(tm, seqSel) : nil;
            NSArray *items = CL_getSpineItems(seq);
            NSMutableArray *locked = [NSMutableArray array];
            for (id item in items) {
                if (CL_isLockedClipDB(item)) {
                    NSString *name = ((id (*)(id, SEL))objc_msgSend)(item, @selector(displayName));
                    [locked addObject:name ?: @"?"];
                }
            }
            resp = @{@"lockedClips": locked, @"count": @(locked.count)};
        });
        return resp ?: @{@"error": @"no timeline"};
    }, @{@"description": @"Return all locked clips in the current sequence."});

    // clips.unlockAll
    SpliceKit_registerPluginMethod(@"clips.unlockAll", ^NSDictionary *(NSDictionary *params) {
        __block NSUInteger count = 0;
        SpliceKit_executeOnMainThread(^{
            id tm = SpliceKit_getActiveTimelineModule();
            SEL seqSel = NSSelectorFromString(@"sequence");
            id seq = (tm && [tm respondsToSelector:seqSel])
                ? ((id (*)(id, SEL))objc_msgSend)(tm, seqSel) : nil;
            if (!seq) return;
            NSArray *items = CL_getSpineItems(seq);
            NSMutableArray *changed = [NSMutableArray array];
            for (id item in items) {
                if (CL_isLockedClipDB(item)) {
                    CL_setClipLocked(item, NO);
                    [changed addObject:item];
                    count++;
                }
            }
            [sLockStateLock lock]; sAnyLockedInTimeline = NO; [sLockStateLock unlock];
            if (changed.count) CL_refreshClips(changed);
        });
        SpliceKit_log(@"[ClipLock] Unlocked all — %lu clips", (unsigned long)count);
        return @{@"result": @"ok", @"unlockedCount": @(count)};
    }, @{@"description": @"Unlock all locked clips in the current sequence."});
}

// ---------------------------------------------------------------------------
// Keyboard shortcut — ⌥L  (LKCommand "SKLockClip")
// ---------------------------------------------------------------------------

static IMP sOrigLoadCommands_CL = NULL;
static IMP sOrigSetActiveCommandSet_CL = NULL;

static void CL_registerLKCommand(void) {
    Class cmdClass = objc_getClass("LKCommand");
    Class ctrlClass = objc_getClass("LKCommandsController");
    if (!cmdClass || !ctrlClass) {
        SpliceKit_log(@"[ClipLock] LKCommand/LKCommandsController not found, skipping ⌥L binding");
        return;
    }

    id ctrl = ((id (*)(Class, SEL))objc_msgSend)(ctrlClass, NSSelectorFromString(@"sharedController"));
    if (!ctrl) {
        SpliceKit_log(@"[ClipLock] LKCommandsController.sharedController nil, skipping ⌥L binding");
        return;
    }

    // Create the LKCommand: identifier "SKLockClip", action "SKToggleLockClipAction:"
    SEL initSel = NSSelectorFromString(@"initWithCommandIdentifier:action:");
    id cmd = [cmdClass alloc];
    @try {
        cmd = ((id (*)(id, SEL, NSString *, SEL))objc_msgSend)(
            cmd, initSel,
            @"SKLockClip",
            NSSelectorFromString(@"SKToggleLockClipAction:")
        );
    } @catch (NSException *e) {
        SpliceKit_log(@"[ClipLock] LKCommand init failed: %@", e);
        return;
    }
    if (!cmd) {
        SpliceKit_log(@"[ClipLock] LKCommand alloc/init returned nil");
        return;
    }

    SEL registerSel = NSSelectorFromString(@"registerCommand:");
    if ([ctrl respondsToSelector:registerSel]) {
        @try { ((void (*)(id, SEL, id))objc_msgSend)(ctrl, registerSel, cmd); }
        @catch (NSException *e) { SpliceKit_log(@"[ClipLock] registerCommand: threw %@", e); }
    }

    // Bind ⌥L
    SEL bindSel = NSSelectorFromString(@"bindCommandWithIdentifier:toKeyEquivalent:modifiers:");
    if ([ctrl respondsToSelector:bindSel]) {
        @try {
            ((void (*)(id, SEL, NSString *, NSString *, NSUInteger))objc_msgSend)(
                ctrl, bindSel,
                @"SKLockClip",
                @"l",
                NSEventModifierFlagOption
            );
            SpliceKit_log(@"[ClipLock] Bound ⌥L → SKLockClip");
        } @catch (NSException *e) {
            SpliceKit_log(@"[ClipLock] Key binding failed: %@", e);
        }
    }
}

// The LKCommand fires "SKToggleLockClipAction:" down the responder chain.
// We add it to NSApplication so it always reaches us.
static void CL_installActionHandler(void) {
    // Swizzle NSApplication to catch SKToggleLockClipAction:
    // We add the method dynamically if it doesn't exist yet.
    Class appClass = [NSApplication class];
    SEL actionSel = NSSelectorFromString(@"SKToggleLockClipAction:");

    if (![appClass instancesRespondToSelector:actionSel]) {
        IMP impl = imp_implementationWithBlock(^(id appSelf, id sender) {
            id tm = SpliceKit_getActiveTimelineModule();
            if (!tm) { NSBeep(); return; }
            SEL itemsSel = NSSelectorFromString(@"selectedItems");
            if (![tm respondsToSelector:itemsSel]) { NSBeep(); return; }
            NSArray *items = nil;
            @try { items = ((id (*)(id, SEL))objc_msgSend)(tm, itemsSel); }
            @catch (...) { NSBeep(); return; }

            NSUInteger locked = 0, unlocked = 0;
            for (id clip in items) {
                if (CL_isLockedClipDB(clip)) locked++;
                else unlocked++;
            }

            // If any are unlocked, lock all. If all are locked, unlock all.
            BOOL shouldLock = unlocked > 0;
            NSMutableArray *changed = [NSMutableArray array];
            for (id clip in items) {
                SEL isGapSel = NSSelectorFromString(@"isGap");
                if ([clip respondsToSelector:isGapSel]) {
                    @try { if (((BOOL (*)(id, SEL))objc_msgSend)(clip, isGapSel)) continue; }
                    @catch (...) {}
                }
                CL_setClipLocked(clip, shouldLock);
                [changed addObject:clip];
            }
            id lockTM = SpliceKit_getActiveTimelineModule();
            if (lockTM) CL_updateAnyLockedFlag(lockTM);
            SpliceKit_log(@"[ClipLock] ⌥L → %@ %lu clip(s)",
                          shouldLock ? @"Locked" : @"Unlocked",
                          (unsigned long)changed.count);
            CL_refreshClips(changed);
        });
        class_addMethod(appClass, actionSel, impl, "v@:@");
    }
}

// Re-register on future _loadCommands / _setActiveCommandSet: calls.
static void CL_swizzled_loadCommands(id self, SEL _cmd) {
    if (sOrigLoadCommands_CL) ((void (*)(id, SEL))sOrigLoadCommands_CL)(self, _cmd);
    CL_registerLKCommand();
}
static void CL_swizzled_setActiveCommandSet(id self, SEL _cmd, id set) {
    if (sOrigSetActiveCommandSet_CL) ((void (*)(id, SEL, id))sOrigSetActiveCommandSet_CL)(self, _cmd, set);
    CL_registerLKCommand();
}

// ---------------------------------------------------------------------------
// Public install entry point
// ---------------------------------------------------------------------------

void SpliceKit_installClipLock(void) {
    CL_ensureState();
    SpliceKit_log(@"[ClipLock] Installing (metadata-based persistence)");

    Class anchoredObj = objc_getClass("FFAnchoredObject");
    if (anchoredObj) {
        Method dn = class_getInstanceMethod(anchoredObj, @selector(displayName));
        if (dn) {
            sOrigDisplayName = method_getImplementation(dn);
            method_setImplementation(dn, (IMP)CL_swizzled_displayName);
            SpliceKit_log(@"[ClipLock] Swizzled FFAnchoredObject.displayName");
        } else {
            SpliceKit_log(@"[ClipLock] displayName not found on FFAnchoredObject");
        }
    }

    // Hoist atm/seqClass so they're available outside the diagnostic if(NO) block.
    Class atm = objc_getClass("FFAnchoredTimelineModule");
    Class seqClass = objc_getClass("FFAnchoredSequence");
    (void)seqClass; // suppress unused warning when block is disabled


    // --- Swizzle 1: TLKTimelineView.menuForEvent: ---
    Class tlkView = objc_getClass("TLKTimelineView");
    if (tlkView) {
        Method m = class_getInstanceMethod(tlkView, @selector(menuForEvent:));
        if (m) {
            sOrigMenuForEvent_CL = method_getImplementation(m);
            method_setImplementation(m, (IMP)CL_swizzled_menuForEvent);
            SpliceKit_log(@"[ClipLock] Swizzled TLKTimelineView.menuForEvent:");
        } else {
            SpliceKit_log(@"[ClipLock] menuForEvent: not found on TLKTimelineView");
        }
    } else {
        SpliceKit_log(@"[ClipLock] TLKTimelineView not found");
    }

    // --- Swizzle 2: FFAnchoredTimelineModule.timelineView:shouldMoveItems:... ---
    if (atm) {
        SEL shouldMoveSel = NSSelectorFromString(
            @"timelineView:shouldMoveItems:byPlacingItem:inContainer:atIndex:atTime:");
        Method m = class_getInstanceMethod(atm, shouldMoveSel);
        if (m) {
            sOrigShouldMoveItems = (ShouldMoveItemsFn)method_getImplementation(m);
            method_setImplementation(m, (IMP)CL_swizzled_shouldMoveItems);
            SpliceKit_log(@"[ClipLock] Swizzled shouldMoveItems:byPlacingItem:...");
        } else {
            SpliceKit_log(@"[ClipLock] shouldMoveItems not found on FFAnchoredTimelineModule");
        }

        // --- Swizzle 3: _validateTrimAction: (cursor state) ---
        SEL validateTrimSel = NSSelectorFromString(@"_validateTrimAction:");
        Method mt = class_getInstanceMethod(atm, validateTrimSel);
        if (mt) {
            sOrigValidateTrimAction = (ValidateTrimFn)method_getImplementation(mt);
            method_setImplementation(mt, (IMP)CL_swizzled_validateTrimAction);
            SpliceKit_log(@"[ClipLock] Swizzled _validateTrimAction:");
        } else {
            SpliceKit_log(@"[ClipLock] _validateTrimAction: not found");
        }

        // --- Swizzle 4a: timelineView:shouldTrimEdge:trimType:edgeType:ofItems:... (multi) ---
        SEL shouldTrimMultiSel = NSSelectorFromString(
            @"timelineView:shouldTrimEdge:trimType:edgeType:ofItems:byTimeOffset:movementType:");
        Method mm = class_getInstanceMethod(atm, shouldTrimMultiSel);
        if (mm) {
            sOrigShouldTrimEdgeMulti = (ShouldTrimEdgeMultiFn)method_getImplementation(mm);
            method_setImplementation(mm, (IMP)CL_swizzled_shouldTrimEdgeMulti);
            SpliceKit_log(@"[ClipLock] Swizzled shouldTrimEdge:...ofItems:...");
        } else {
            SpliceKit_log(@"[ClipLock] shouldTrimEdge:...ofItems:... not found");
        }

        // --- Swizzle 4b: timelineView:shouldTrimEdge:trimType:ofItem:... (single) ---
        SEL shouldTrimSingleSel = NSSelectorFromString(
            @"timelineView:shouldTrimEdge:trimType:ofItem:byTimeOffset:movementType:");
        Method ms = class_getInstanceMethod(atm, shouldTrimSingleSel);
        if (ms) {
            sOrigShouldTrimEdgeSingle = (ShouldTrimEdgeSingleFn)method_getImplementation(ms);
            method_setImplementation(ms, (IMP)CL_swizzled_shouldTrimEdgeSingle);
            SpliceKit_log(@"[ClipLock] Swizzled shouldTrimEdge:...ofItem:...");
        } else {
            SpliceKit_log(@"[ClipLock] shouldTrimEdge:...ofItem:... not found");
        }

        // --- Swizzle 4c2: timelineView:shouldAnchorItems:... (drag-up / lift-from-spine) ---
        SEL shouldAnchorSel = NSSelectorFromString(
            @"timelineView:shouldAnchorItems:inContainer:byAnchoringItem:inLane:atTime:");
        Method ma2 = class_getInstanceMethod(atm, shouldAnchorSel);
        if (ma2) {
            sOrigShouldAnchorItems = (ShouldAnchorItemsFn)method_getImplementation(ma2);
            method_setImplementation(ma2, (IMP)CL_swizzled_shouldAnchorItems);
            SpliceKit_log(@"[ClipLock] Swizzled shouldAnchorItems:...");
        } else {
            SpliceKit_log(@"[ClipLock] shouldAnchorItems:... not found");
        }

        // --- Swizzle 4c3: nudgeUp: / nudgeDown: ---
        SEL nudgeUpSel = NSSelectorFromString(@"nudgeUp:");
        Method mnu = class_getInstanceMethod(atm, nudgeUpSel);
        if (mnu) {
            sOrigNudgeUp = (NudgeVerticalFn)method_getImplementation(mnu);
            method_setImplementation(mnu, (IMP)CL_swizzled_nudgeUp);
            SpliceKit_log(@"[ClipLock] Swizzled nudgeUp:");
        }
        SEL nudgeDownSel = NSSelectorFromString(@"nudgeDown:");
        Method mnd = class_getInstanceMethod(atm, nudgeDownSel);
        if (mnd) {
            sOrigNudgeDown = (NudgeVerticalFn)method_getImplementation(mnd);
            method_setImplementation(mnd, (IMP)CL_swizzled_nudgeDown);
            SpliceKit_log(@"[ClipLock] Swizzled nudgeDown:");
        }

        struct { const char *sel; IMP imp; IMP *orig; } audioSwizzles[] = {
            { "adjustVolumeByAmount:isRelative:actionName:",
              (IMP)CL_swizzled_adjustVolumeByAmount,   (IMP *)&sOrigAdjustVolumeByAmount   },
            { "volumeUp:",
              (IMP)CL_swizzled_volumeUp,               (IMP *)&sOrigVolumeUp               },
            { "volumeDown:",
              (IMP)CL_swizzled_volumeDown,             (IMP *)&sOrigVolumeDown             },
            { "volumeZero:",
              (IMP)CL_swizzled_volumeZero,             (IMP *)&sOrigVolumeZero             },
            { "volumeMinusInfinity:",
              (IMP)CL_swizzled_volumeMinusInfinity,    (IMP *)&sOrigVolumeMinusInfinity    },
            { "fadeHandlesLayer:moveFadeAtIndex:toTime:symmetric:componentSourcesFadeAligned:",
              (IMP)CL_swizzled_moveFadeSym,            (IMP *)&sOrigMoveFadeSym            },
            { "audioComponentSource:moveFadeAtIndex:toTime:componentSourcesFadeAligned:",
              (IMP)CL_swizzled_moveFadeComp,           (IMP *)&sOrigMoveFadeComp           },
            { "adjustVolumeAbsolute:",
              (IMP)CL_swizzled_adjustVolumeAbsolute,   (IMP *)&sOrigAdjustVolumeAbsolute   },
            { "adjustVolumeRelative:",
              (IMP)CL_swizzled_adjustVolumeRelative,   (IMP *)&sOrigAdjustVolumeRelative   },
        };
        for (size_t i = 0; i < sizeof(audioSwizzles)/sizeof(audioSwizzles[0]); i++) {
            SEL s = NSSelectorFromString(@(audioSwizzles[i].sel));
            IMP orig = SpliceKit_swizzleMethod(atm, s, audioSwizzles[i].imp);
            if (orig) {
                *audioSwizzles[i].orig = orig;
                SpliceKit_log(@"[ClipLock] Swizzled %s", audioSwizzles[i].sel);
            } else {
                SpliceKit_log(@"[ClipLock] Not found: %s", audioSwizzles[i].sel);
            }
        }

        // NOTE: shouldRippleEdge:ofItem: disabled — returning NO mid-delete crashes FCP.
        // Ripple-delete blocking is handled at delete: level instead.

        // --- Swizzles 4d-4g: Roll tool ---
        struct { const char *sel; IMP imp; IMP *orig; } rollSwizzles[] = {
            { "timelineView:shouldRollEdge:edgeType:ofItem:adjacentItem:",
              (IMP)CL_swizzled_shouldRollEdgeType,    (IMP *)&sOrigShouldRollEdgeType    },
            { "timelineView:shouldRollEdge:edgeType:ofItem:adjacentItem:byTimeOffset:",
              (IMP)CL_swizzled_shouldRollEdgeTypeOff, (IMP *)&sOrigShouldRollEdgeTypeOff },
            { "timelineView:shouldRollEdge:ofItem:adjacentItem:",
              (IMP)CL_swizzled_shouldRollEdge,        (IMP *)&sOrigShouldRollEdge        },
            { "timelineView:shouldRollEdge:ofItem:adjacentItem:byTimeOffset:",
              (IMP)CL_swizzled_shouldRollEdgeOff,     (IMP *)&sOrigShouldRollEdgeOff     },
            { "timelineView:shouldRollEdge:ofRangeItem:toTime:",
              (IMP)CL_swizzled_shouldRollRange,       (IMP *)&sOrigShouldRollRange       },
        };
        for (size_t i = 0; i < sizeof(rollSwizzles)/sizeof(rollSwizzles[0]); i++) {
            SEL s = NSSelectorFromString(@(rollSwizzles[i].sel));
            Method m2 = class_getInstanceMethod(atm, s);
            if (m2) {
                *rollSwizzles[i].orig = method_getImplementation(m2);
                method_setImplementation(m2, rollSwizzles[i].imp);
                SpliceKit_log(@"[ClipLock] Swizzled %s", rollSwizzles[i].sel);
            }
        }

        // --- Swizzle 4j: _startListeningToSequence: (refresh labels on project load) ---
        SEL startListenSel = NSSelectorFromString(@"_startListeningToSequence:");
        Method msl = class_getInstanceMethod(atm, startListenSel);
        if (msl) {
            sOrigStartListeningToSequence = (StartListeningFn)method_getImplementation(msl);
            method_setImplementation(msl, (IMP)CL_swizzled_startListeningToSequence);
            SpliceKit_log(@"[ClipLock] Swizzled _startListeningToSequence:");
        } else {
            SpliceKit_log(@"[ClipLock] _startListeningToSequence: not found");
        }

        // --- Swizzle 4i: liftFromSpine: ---
        SEL liftSel = NSSelectorFromString(@"liftFromSpine:");
        Method ml2 = class_getInstanceMethod(atm, liftSel);
        if (ml2) {
            sOrigLiftFromSpine = (LiftFromSpineFn)method_getImplementation(ml2);
            method_setImplementation(ml2, (IMP)CL_swizzled_liftFromSpine);
            SpliceKit_log(@"[ClipLock] Swizzled liftFromSpine:");
        } else {
            SpliceKit_log(@"[ClipLock] liftFromSpine: not found");
        }
    }

    // --- Swizzles 4h: FFAnchoredSequence.operationTrimEdit:... (slip + slide core) ---
    if (seqClass) {
        SEL opTrimSel = NSSelectorFromString(
            @"operationTrimEdit:endEdits:edgeType:byDelta:trimCommand:temporalResolutionMode:animationHint:error:");
        Method mot = class_getInstanceMethod(seqClass, opTrimSel);
        if (mot) {
            sOrigOpTrimEdit = (OpTrimEditFn)method_getImplementation(mot);
            method_setImplementation(mot, (IMP)CL_swizzled_operationTrimEdit);
            SpliceKit_log(@"[ClipLock] Swizzled FFAnchoredSequence.operationTrimEdit:...");
        } else {
            SpliceKit_log(@"[ClipLock] operationTrimEdit:... not found on FFAnchoredSequence");
        }
        SEL opTrimFlagsSel = NSSelectorFromString(
            @"operationTrimEdit:endEdits:edgeType:byDelta:trimCommand:trimFlags:temporalResolutionMode:animationHint:error:");
        Method motf = class_getInstanceMethod(seqClass, opTrimFlagsSel);
        if (motf) {
            sOrigOpTrimEditFlags = (OpTrimEditFlagsFn)method_getImplementation(motf);
            method_setImplementation(motf, (IMP)CL_swizzled_operationTrimEditFlags);
            SpliceKit_log(@"[ClipLock] Swizzled FFAnchoredSequence.operationTrimEdit:...trimFlags:...");
        } else {
            SpliceKit_log(@"[ClipLock] operationTrimEdit:...trimFlags:... not found on FFAnchoredSequence");
        }

        // NOTE: actionChangeAudioVolume swizzle disabled pending crash investigation.

        // NOTE: operationRemoveEdits / actionRemoveEdits swizzles intentionally omitted.
        // Metadata reads inside an active FCP delete transaction crash FCP.
        // _deleteCore:replaceWithGap:removeOperation: is the safe intercept point.

        // NOTE: actionRemoveEdits:replaceWithGap:... swizzles are intentionally NOT installed.
        // Reading mdLocalValueForKey: on clip objects during an active FCP delete operation
        // crashes. _deleteCore:replaceWithGap:removeOperation: is the correct intercept point
        // — it fires before the sequence action system is entered.
    }


    if (atm) {
        SEL deleteSel = NSSelectorFromString(@"delete:");
        Method md = class_getInstanceMethod(atm, deleteSel);
        if (md) {
            sOrigDelete = (DeleteFn)method_getImplementation(md);
            method_setImplementation(md, (IMP)CL_swizzled_delete);
            SpliceKit_log(@"[ClipLock] Swizzled FFAnchoredTimelineModule.delete:");
        } else {
            SpliceKit_log(@"[ClipLock] delete: not found on FFAnchoredTimelineModule");
        }

        SEL validateUISel = NSSelectorFromString(@"validateUserInterfaceItem:withSelectedItems:");
        Method mu = class_getInstanceMethod(atm, validateUISel);
        if (mu) {
            sOrigValidateUI = (ValidateUIFn)method_getImplementation(mu);
            method_setImplementation(mu, (IMP)CL_swizzled_validateUI);
            SpliceKit_log(@"[ClipLock] Swizzled validateUserInterfaceItem:withSelectedItems:");
        } else {
            SpliceKit_log(@"[ClipLock] validateUserInterfaceItem:withSelectedItems: not found");
        }
    } else {
        SpliceKit_log(@"[ClipLock] FFAnchoredTimelineModule not found");
    }

    // --- Keyboard shortcut ⌥L ---
    CL_installActionHandler();
    CL_registerLKCommand();

    Class lkcc = objc_getClass("LKCommandsController");
    if (lkcc) {
        SEL loadSel = NSSelectorFromString(@"_loadCommands");
        Method ml = class_getInstanceMethod(lkcc, loadSel);
        if (ml) {
            sOrigLoadCommands_CL = method_getImplementation(ml);
            method_setImplementation(ml, (IMP)CL_swizzled_loadCommands);
        }
        SEL activeSel = NSSelectorFromString(@"_setActiveCommandSet:");
        Method ma = class_getInstanceMethod(lkcc, activeSel);
        if (ma) {
            sOrigSetActiveCommandSet_CL = method_getImplementation(ma);
            method_setImplementation(ma, (IMP)CL_swizzled_setActiveCommandSet);
        }
    }

    // NOTE: CHChannelDouble/CHChannel setCurveDoubleValue swizzles intentionally omitted.
    // These fire deep inside FCP's audio subsystem during clip deletion, causing crashes.

    // --- RPC methods ---
    CL_registerRPC();

    // FCP may restore the last project before _startListeningToSequence: is swizzled.
    // Run a deferred scan 1s after install to catch that case.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        id tm = SpliceKit_getActiveTimelineModule();
        if (!tm) return;
        SEL seqSel = NSSelectorFromString(@"sequence");
        if (![tm respondsToSelector:seqSel]) return;
        id seq = ((id (*)(id, SEL))objc_msgSend)(tm, seqSel);
        NSArray *allItems = CL_getSpineItems(seq);
        if (!allItems) return;
        NSMutableArray *locked = [NSMutableArray array];
        for (id item in allItems) {
            if (CL_isLockedClipDB(item)) {
                [locked addObject:item];
                CL_cacheAdd(item);
            }
        }
        [sLockStateLock lock];
        sAnyLockedInTimeline = (locked.count > 0);
        [sLockStateLock unlock];
        if (locked.count) {
            SpliceKit_log(@"[ClipLock] Startup scan: found %lu locked clip(s), refreshing labels",
                          (unsigned long)locked.count);
            CL_refreshClips(locked);
        }
    });

    SpliceKit_log(@"[ClipLock] Installed successfully");
}
