//
//  SpliceKitTimelineInteractionSuspend.m
//  Suspend expensive timeline updates during active interaction (pinch, scroll,
//  marquee, drag) and run a single coalesced catch-up at the end.
//
//  How we found the hot spots
//  --------------------------
//  Live-decompiling TimelineKit on a long project shows two things fire on every
//  visible-rect change and every zoom step:
//
//    -[TLKTimelineView _updateItemLayersInVisibleRect:]
//      → walks ALL timelineItems (not visible), then each fragment, then
//        checks shouldSuspendLayerUpdateForItemComponent: on every one.
//
//    -[TLKLayerManager updateFilmstripsForItemComponentFragments:]
//      → for each fragment, reads visibleRect, computes intersection with the
//        fragment's layer frame, updates contents. Gated by
//        TLKEnableUpdateFilmstripsForItemComponentFragments.
//
//  And filmstrip cells fail equivalence on every zoom step because
//  -[FFFilmstripCell isEquivalentToFilmstripCell:] compares timeRange AND
//  frame.size AND audioHeight — each of which changes when the
//  TLKThumbnailTimeModel moves to a new zoom step. So the decoded bitmap may
//  still be in FFThumbnailImageRequestMD5Cache but the *cell* is rebuilt.
//
//  Suspend strategy
//  ----------------
//  1. Observe TLKEventHandlerDidStartTrackingNotification /
//     TLKEventHandlerDidStopTrackingNotification. These fire for every handler
//     that goes through TLKEventDispatcher.startTracking / stopTracking —
//     covers marquee, scroll-bar drag, item drag, trim, etc.
//  2. Swizzle -[TLKTimelineHandler magnifyWithEvent:]. Pinch-to-zoom does NOT
//     post the tracking notifications — the handler runs its own
//     nextEventMatchingMask: loop inline. So we wrap the call.
//  3. Both paths go through the same begin/end functions with refcounting so
//     nested/overlapping interactions save+restore once.
//
//  While suspended:
//    -[TLKTimelineView setDisableFilmstripLayerUpdates:YES]   (bit 6 of _tlkViewFlags)
//    -[TLKTimelineView setSuspendLayerUpdatesForAnchoredClips:YES]
//                                                               (sets LM flag bit 0)
//    -[TLKTimelineView setMinThumbnailCount:0]                (density floor)
//
//  On end:
//    Restore the three flags to their pre-suspend values.
//    Post one coalesced -[TLKTimelineView _reloadVisibleLayers] on the next
//    run-loop turn so a rapid pinch → tiny pause → pinch doesn't do two
//    full catch-ups.
//
//  Hidden TLK flags
//  ----------------
//  +[TLKUserDefaults optimizedReload] reads bit 8 of __userDefaultFlags_0.
//  `_loadUserDefaults` doesn't populate that bit from an NSUserDefaults key —
//  so to flip it we set `TLKOptimizedReload=YES` in NSUserDefaults AND then
//  reach into the static flag byte at runtime. Because `_loadUserDefaults`
//  is an @synthesize-style function that only populates certain bits, we
//  have to both (a) set the default (in case Apple later wires it up) and
//  (b) swizzle the getter to return our value. Option (a) alone doesn't
//  work right now — so we go with (b).
//

#import "SpliceKit.h"
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>

// ---- Defaults keys ----

static NSString * const kDefTimelineInteractionSuspend = @"SpliceKitTimelineInteractionSuspend";
static NSString * const kDefTLKOptimizedReload        = @"SpliceKitTLKOptimizedReload";

// ---- Install state ----

static BOOL sInteractionSuspendInstalled = NO;

// Swizzled selectors
static IMP sOrigMagnifyWithEvent = NULL;
static IMP sOrigOptimizedReload  = NULL;

// Tokens returned by +addObserverForName:object:queue:usingBlock: — we need
// to hold them so -removeObserver: can tear them down on disable. Without
// this, re-enable stacks duplicate observers and disable doesn't actually
// silence the begin/end-suspend calls.
static id sStartTrackingObserver = nil;
static id sStopTrackingObserver  = nil;

// Per-view suspend state. Wrapped in an ObjC box so ARC + associated-object
// cleanup frees the backing struct when the timeline view is deallocated —
// previously a raw calloc buffer was stashed as an NSValue pointer, which
// leaked on window/project churn.
@interface SpliceKitSuspendStateBox : NSObject {
@public
    BOOL filmstripWasDisabled;
    BOOL anchoredWasSuspended;
    double minThumbnailCountPrev;
    BOOL capturedFilmstrip;
    BOOL capturedAnchored;
    BOOL capturedMinThumbnailCount;
    int refcount;
}
@end
@implementation SpliceKitSuspendStateBox
@end

static void * const kSuspendStateKey = (void *)&kSuspendStateKey;
static NSHashTable *sSuspendedTimelineViews = nil; // weak objects

static NSHashTable *IS_suspendedViews(void) {
    if (!sSuspendedTimelineViews) {
        sSuspendedTimelineViews = [NSHashTable weakObjectsHashTable];
    }
    return sSuspendedTimelineViews;
}

static SpliceKitSuspendStateBox *IS_getOrCreateState(id timelineView) {
    SpliceKitSuspendStateBox *st = objc_getAssociatedObject(timelineView, kSuspendStateKey);
    if (st) return st;
    st = [[SpliceKitSuspendStateBox alloc] init];
    objc_setAssociatedObject(timelineView, kSuspendStateKey, st,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return st;
}

static SpliceKitSuspendStateBox *IS_getState(id timelineView) {
    return objc_getAssociatedObject(timelineView, kSuspendStateKey);
}

// ---- Begin / end suspension ----

static void IS_beginSuspend(id timelineView) {
    if (!timelineView) return;
    // Belt-and-braces gate: if the feature was turned off between the
    // observer registration and delivery, don't touch the timeline view.
    if (!sInteractionSuspendInstalled) return;
    SpliceKitSuspendStateBox *st = IS_getOrCreateState(timelineView);
    st->refcount++;
    if (st->refcount > 1) return; // already suspended
    st->capturedFilmstrip = NO;
    st->capturedAnchored = NO;
    st->capturedMinThumbnailCount = NO;
    [IS_suspendedViews() addObject:timelineView];

    @try {
        // Save current state
        SEL filmstripGet = @selector(disableFilmstripLayerUpdates);
        SEL anchoredGet  = @selector(suspendLayerUpdatesForAnchoredClips);
        SEL minThumbGet  = @selector(minThumbnailCount);
        id layerManager = nil;
        SEL layerManagerSel = @selector(layerManager);
        if ([timelineView respondsToSelector:layerManagerSel]) {
            layerManager = ((id (*)(id, SEL))objc_msgSend)(timelineView, layerManagerSel);
        }
        if ([timelineView respondsToSelector:filmstripGet]) {
            st->filmstripWasDisabled = ((BOOL (*)(id, SEL))objc_msgSend)(timelineView, filmstripGet);
            st->capturedFilmstrip = YES;
        }
        // FCP 12.3 exposes the getter on TLKLayerManager while retaining the
        // setter on TLKTimelineView. Older builds exposed both on the view.
        id anchoredOwner = [timelineView respondsToSelector:anchoredGet]
            ? timelineView : ([layerManager respondsToSelector:anchoredGet] ? layerManager : nil);
        if (anchoredOwner) {
            st->anchoredWasSuspended = ((BOOL (*)(id, SEL))objc_msgSend)(anchoredOwner, anchoredGet);
            st->capturedAnchored = YES;
        }
        if ([timelineView respondsToSelector:minThumbGet]) {
            // Normal objc_msgSend for double-returning methods on arm64/x86_64.
            // objc_msgSend_fpret is x86-long-double-only and not usable in fat builds.
            st->minThumbnailCountPrev = ((double (*)(id, SEL))objc_msgSend)(timelineView, minThumbGet);
            st->capturedMinThumbnailCount = YES;
        }

        // Apply suspend
        SEL filmstripSet = @selector(setDisableFilmstripLayerUpdates:);
        SEL anchoredSet  = @selector(setSuspendLayerUpdatesForAnchoredClips:);
        SEL minThumbSet  = @selector(setMinThumbnailCount:);
        if (st->capturedFilmstrip && [timelineView respondsToSelector:filmstripSet]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(timelineView, filmstripSet, YES);
        }
        if (st->capturedAnchored && [timelineView respondsToSelector:anchoredSet]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(timelineView, anchoredSet, YES);
        } else if (st->capturedAnchored && [layerManager respondsToSelector:anchoredSet]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(layerManager, anchoredSet, YES);
        }
        if (st->capturedMinThumbnailCount && [timelineView respondsToSelector:minThumbSet]) {
            ((void (*)(id, SEL, double))objc_msgSend)(timelineView, minThumbSet, 0.0);
        }
    } @catch (NSException *e) {
        SpliceKit_log(@"[TLInteractionSuspend] beginSuspend exception: %@", e.reason ?: e.description);
    }
}

static void IS_endSuspend(id timelineView) {
    if (!timelineView) return;
    // End still runs even when disabled — there may be an in-flight pair
    // from a begin that happened while enabled. Skip only if refcount is
    // zero (no outstanding begin).
    SpliceKitSuspendStateBox *st = IS_getState(timelineView);
    if (!st || st->refcount <= 0) return;
    st->refcount--;
    if (st->refcount > 0) return; // still inside a nested interaction

    @try {
        SEL filmstripSet = @selector(setDisableFilmstripLayerUpdates:);
        SEL anchoredSet  = @selector(setSuspendLayerUpdatesForAnchoredClips:);
        SEL minThumbSet  = @selector(setMinThumbnailCount:);
        id layerManager = nil;
        SEL layerManagerSel = @selector(layerManager);
        if ([timelineView respondsToSelector:layerManagerSel]) {
            layerManager = ((id (*)(id, SEL))objc_msgSend)(timelineView, layerManagerSel);
        }
        if (st->capturedFilmstrip && [timelineView respondsToSelector:filmstripSet]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(timelineView, filmstripSet,
                                                    st->filmstripWasDisabled);
        }
        if (st->capturedAnchored && [timelineView respondsToSelector:anchoredSet]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(timelineView, anchoredSet,
                                                    st->anchoredWasSuspended);
        } else if (st->capturedAnchored && [layerManager respondsToSelector:anchoredSet]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(layerManager, anchoredSet,
                                                    st->anchoredWasSuspended);
        }
        if (st->capturedMinThumbnailCount && [timelineView respondsToSelector:minThumbSet]) {
            ((void (*)(id, SEL, double))objc_msgSend)(timelineView, minThumbSet,
                                                     st->minThumbnailCountPrev);
        }
    } @catch (NSException *e) {
        SpliceKit_log(@"[TLInteractionSuspend] endSuspend exception: %@", e.reason ?: e.description);
    }

    [IS_suspendedViews() removeObject:timelineView];

    // Coalesced catch-up. Use performSelector so multiple end-calls within
    // the same run-loop turn collapse to one invocation.
    SEL reloadSel = @selector(_reloadVisibleLayers);
    if ([timelineView respondsToSelector:reloadSel]) {
        [NSObject cancelPreviousPerformRequestsWithTarget:timelineView
                                                 selector:reloadSel
                                                   object:nil];
        [timelineView performSelector:reloadSel
                           withObject:nil
                           afterDelay:0.0
                              inModes:@[NSRunLoopCommonModes]];
    }
}

// ---- Swizzled magnifyWithEvent: ----
//
// We wrap the entire TLKTimelineHandler.magnifyWithEvent: call because it
// contains an internal nextEventMatchingMask: loop that doesn't return until
// the gesture ends. Suspend before, restore after.

static void SpliceKit_swizzled_magnifyWithEvent(id self_, SEL _cmd, id event) {
    id timelineView = nil;
    @try {
        if ([self_ respondsToSelector:@selector(timelineView)]) {
            timelineView = ((id (*)(id, SEL))objc_msgSend)(self_, @selector(timelineView));
        }
    } @catch (...) { timelineView = nil; }

    if (timelineView) IS_beginSuspend(timelineView);
    @try {
        ((void (*)(id, SEL, id))sOrigMagnifyWithEvent)(self_, _cmd, event);
    } @finally {
        if (timelineView) IS_endSuspend(timelineView);
    }
}

// ---- Notification observers ----

static NSMutableSet *sObservedHandlerClassNames(void) {
    static NSMutableSet *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [NSMutableSet setWithArray:@[
            @"TLKZoomHandler",              // option+drag marquee zoom
            @"TLKScrollHandler",            // scroll-bar drag
            @"TLKMarqueeHandler",           // range selection drag
            // Drag-item / trim handlers intentionally omitted — user wants
            // live feedback during those operations.
        ]];
    });
    return s;
}

static id IS_extractTimelineView(id handler) {
    id view = nil;
    @try {
        if ([handler respondsToSelector:@selector(timelineView)]) {
            view = ((id (*)(id, SEL))objc_msgSend)(handler, @selector(timelineView));
        } else if ([handler respondsToSelector:@selector(view)]) {
            view = ((id (*)(id, SEL))objc_msgSend)(handler, @selector(view));
        }
    } @catch (...) { view = nil; }
    return view;
}

static void IS_installNotificationObservers(void) {
    // Idempotent: if already installed, do nothing. Re-enable must not
    // stack duplicate observer pairs.
    if (sStartTrackingObserver || sStopTrackingObserver) return;

    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];

    sStartTrackingObserver =
    [nc addObserverForName:@"TLKEventHandlerDidStartTrackingNotification"
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
        id handler = note.object;
        if (!handler) return;
        NSString *cn = NSStringFromClass([handler class]);
        if (![sObservedHandlerClassNames() containsObject:cn]) return;
        id view = IS_extractTimelineView(handler);
        if (view) IS_beginSuspend(view);
    }];

    sStopTrackingObserver =
    [nc addObserverForName:@"TLKEventHandlerDidStopTrackingNotification"
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
        id handler = note.object;
        if (!handler) return;
        NSString *cn = NSStringFromClass([handler class]);
        if (![sObservedHandlerClassNames() containsObject:cn]) return;
        id view = IS_extractTimelineView(handler);
        if (view) IS_endSuspend(view);
    }];
}

static void IS_removeNotificationObservers(void) {
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    if (sStartTrackingObserver) {
        [nc removeObserver:sStartTrackingObserver];
        sStartTrackingObserver = nil;
    }
    if (sStopTrackingObserver) {
        [nc removeObserver:sStopTrackingObserver];
        sStopTrackingObserver = nil;
    }
}

// ---- TLKOptimizedReload flag ----
//
// +[TLKUserDefaults optimizedReload] reads bit 8 of a static __userDefaultFlags_0
// word. `_loadUserDefaults` doesn't populate that bit from any NSUserDefaults
// key, so setting the default alone is ineffective. Swizzle the getter
// instead so our user-controlled value is actually read by callers.

static BOOL sForceTLKOptimizedReloadOn = NO;

static char SpliceKit_swizzled_optimizedReload(Class self_, SEL _cmd) {
    if (sForceTLKOptimizedReloadOn) return 1;
    if (sOrigOptimizedReload) return ((char (*)(Class, SEL))sOrigOptimizedReload)(self_, _cmd);
    return 0;
}

void SpliceKit_setTLKOptimizedReloadEnabled(BOOL enabled) {
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:kDefTLKOptimizedReload];
    sForceTLKOptimizedReloadOn = enabled;
    // Also set Apple's own default key in case some code path reads it directly.
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:@"TLKOptimizedReload"];

    // Install swizzle on first *enable*. We intentionally don't use dispatch_once
    // here — the old code did, and if the first call was a disable it swallowed
    // the token forever and later enables couldn't install the swizzle. Now
    // we install on demand, and leave it installed across toggles (the
    // sForceTLKOptimizedReloadOn flag alone gates the effective value).
    if (enabled && sOrigOptimizedReload == NULL) {
        Class cls = objc_getClass("TLKUserDefaults");
        if (!cls) return;
        SEL sel = @selector(optimizedReload);
        Method m = class_getClassMethod(cls, sel);
        if (!m) return;
        sOrigOptimizedReload = method_setImplementation(m, (IMP)SpliceKit_swizzled_optimizedReload);
        SpliceKit_log(@"[TLInteractionSuspend] Swizzled +[TLKUserDefaults optimizedReload]");
    }
}

BOOL SpliceKit_isTLKOptimizedReloadEnabled(void) {
    NSNumber *n = [[NSUserDefaults standardUserDefaults] objectForKey:kDefTLKOptimizedReload];
    return n ? [n boolValue] : NO;
}

// ---- Install / remove ----

void SpliceKit_installTimelineInteractionSuspend(void) {
    if (sInteractionSuspendInstalled) return;

    Class handlerCls = objc_getClass("TLKTimelineHandler");
    if (!handlerCls) {
        SpliceKit_log(@"[TLInteractionSuspend] TLKTimelineHandler not found — skip");
        return;
    }

    // 1. Swizzle pinch-zoom entry point. Only install if not already swapped.
    if (sOrigMagnifyWithEvent == NULL) {
        SEL magnifySel = @selector(magnifyWithEvent:);
        Method m = class_getInstanceMethod(handlerCls, magnifySel);
        if (m) {
            sOrigMagnifyWithEvent = method_setImplementation(m, (IMP)SpliceKit_swizzled_magnifyWithEvent);
            SpliceKit_log(@"[TLInteractionSuspend] Swizzled -[TLKTimelineHandler magnifyWithEvent:]");
        } else {
            SpliceKit_log(@"[TLInteractionSuspend] magnifyWithEvent: not found on TLKTimelineHandler");
        }
    }

    // 2. Tracking notification observers. Idempotent — no stacking.
    IS_installNotificationObservers();

    // 3. Restore TLKOptimizedReload if previously enabled.
    if (SpliceKit_isTLKOptimizedReloadEnabled()) {
        SpliceKit_setTLKOptimizedReloadEnabled(YES);
    }

    sInteractionSuspendInstalled = YES;
    SpliceKit_log(@"[TLInteractionSuspend] Installed");
}

void SpliceKit_removeTimelineInteractionSuspend(void) {
    if (!sInteractionSuspendInstalled) return;

    Class handlerCls = objc_getClass("TLKTimelineHandler");
    if (handlerCls && sOrigMagnifyWithEvent) {
        Method m = class_getInstanceMethod(handlerCls, @selector(magnifyWithEvent:));
        if (m) method_setImplementation(m, sOrigMagnifyWithEvent);
        sOrigMagnifyWithEvent = NULL;
    }

    // Lower the begin gate first, then tear down tracking observers so no new
    // suspension can start while we restore in-flight views.
    sInteractionSuspendInstalled = NO;

    // Tear down the tracking observers so scroll/marquee interactions stop
    // calling begin/end-suspend. The inner gate in IS_beginSuspend is a
    // belt-and-braces backstop; removing the observers is the real fix.
    IS_removeNotificationObservers();

    // Disabling in the middle of a gesture used to strand these private flags
    // in their suspended state because the matching stop notification was no
    // longer observed. Force every live view back to its captured values.
    for (id timelineView in IS_suspendedViews().allObjects) {
        SpliceKitSuspendStateBox *st = IS_getState(timelineView);
        if (!st || st->refcount <= 0) continue;
        st->refcount = 1;
        IS_endSuspend(timelineView);
    }
    [IS_suspendedViews() removeAllObjects];

    SpliceKit_log(@"[TLInteractionSuspend] Removed");
}

void SpliceKit_setTimelineInteractionSuspendEnabled(BOOL enabled) {
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:kDefTimelineInteractionSuspend];
    if (enabled) {
        SpliceKit_installTimelineInteractionSuspend();
    } else {
        SpliceKit_removeTimelineInteractionSuspend();
    }
}

BOOL SpliceKit_isTimelineInteractionSuspendEnabled(void) {
    NSNumber *n = [[NSUserDefaults standardUserDefaults]
                   objectForKey:kDefTimelineInteractionSuspend];
    // Default: OFF. The master "Performance Mode" toggle flips this on.
    return n ? [n boolValue] : NO;
}
