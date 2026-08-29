//
//  SpliceKitTimelinePlayheadOverlay.m
//  Display-refresh-rate animation for FCP's native timeline playhead.
//
//  Problem
//  -------
//  FCP's playhead updates are driven by FFContext.time changes
//  (timeRateChangedForContext:), not by CVDisplayLink. On a 24p or 30p
//  project the playhead steps at the source frame rate regardless of the
//  display's refresh rate. On a 120Hz ProMotion panel that reads as stutter.
//
//  Approach
//  --------
//  Don't force TimelineKit to redraw at 120Hz — filmstrips and waveforms
//  re-layout on every step, which is expensive. Instead, move FCP's existing
//  TLKPlayheadMarker layer at display refresh rate by extrapolating forward
//  from the last observed (time, wallClock, rate) triple. Reusing the native
//  layer preserves FCP's exact artwork, focus, snapped, and accessibility
//  states; there is no second, differently-colored playhead to maintain.
//
//  Extrapolation
//    t_now = t_last + (CACurrentMediaTime() - wallClock_last) * rate
//    x_now = [timelineView locationRangeForTime: t_now].location
//
//  Observation
//    Swizzle -[TLKTimelineView _setPlayheadTime_NoKVO:animate:] to capture
//    every real playhead update. Read rate from the FFContext via
//    [timelineModule context].rate.
//
//  On pause, the marker is snapped to FCP's authoritative playhead time and
//  normal TimelineKit positioning resumes.
//

#import "SpliceKit.h"
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreMedia/CoreMedia.h>
#import <objc/runtime.h>
#import <objc/message.h>

// objc_msgSend_stret is x86-only. On arm64, struct returns use plain msgSend.
#if defined(__x86_64__)
#define PO_STRET objc_msgSend_stret
#else
#define PO_STRET objc_msgSend
#endif

// Opaque CMTime mirror — matches sizeof(CMTime) = 24 with 8-byte alignment.
typedef struct __attribute__((aligned(8))) {
    int64_t value;
    int32_t timescale;
    uint32_t flags;
    int64_t epoch;
} PO_CMTime;

// TLKTimelineView.locationRangeForTime: returns _TLKRange { double location; double length; }
typedef struct {
    double location;
    double length;
} PO_TLKRange;

static NSString * const kDefTimelinePlayheadOverlay = @"SpliceKitTimelinePlayheadOverlay";

static BOOL        sOverlayInstalled = NO;
static BOOL        sIsPlaying = NO;
static __weak NSView *sTimelineViewWeak = nil;     // last known FFProTimelineView / TLKTimelineView
static __weak NSView *sPlaybackTimelineViewWeak = nil;
static __weak CALayer *sNativePlayheadLayerWeak = nil;
static __weak id sPlaybackSourceWeak = nil;
static CADisplayLink *sDisplayLink = nil;
static __weak NSWindow *sDisplayLinkWindowWeak = nil;
static NSInteger sTrackingDepth = 0;

// When we pause Apple's TLKScrollingTimeline during playback to stop its
// 30Hz step-based auto-scroll from fighting our 120Hz smooth scroll, we
// need to remember which scrollingTimeline we paused and its prior state
// so we can restore on playback end.
static __weak id sPausedScrollingTimelineWeak = nil;
static BOOL      sScrollingTimelineWasPaused = NO;
// Keep Apple's normal scrolling alive until our first valid display-link
// frame is ready. Pausing it in the begin-playback notification can expose a
// short frozen beat if FCP's main thread is busy before the first callback.
static BOOL      sPendingCenteredScrollTakeover = NO;

// Last observed playhead state from the swizzle.
// Guarded by sObservedLock.
static PO_CMTime  sObservedTime = {0};
static CFTimeInterval sObservedWall = 0;
static double     sObservedRate = 0.0;
static os_unfair_lock sObservedLock = OS_UNFAIR_LOCK_INIT;
static CFTimeInterval sDisplayLinkResumeWall = 0.0;
static BOOL sAwaitingFirstDisplayLinkTick = NO;

// The exact TLKTimelineView that received the most recent
// _setPlayheadTime_NoKVO:animate: swizzled call. Preferred over window-walking
// in the display-link tick because it's the object actually receiving
// playhead updates — no risk of ending up on a wrong timeline view when the
// dual-timeline panel is open. Set under sObservedLock.
static __weak NSView *sSwizzleCapturedViewWeak = nil;

static IMP sOrigSetPlayheadTimeNoKVO = NULL;
static BOOL PO_prepareDisplayLink(NSView *timelineView);

// ---- Helpers ----

static NSView *PO_findFFProTimelineView(NSView *root, NSInteger depth) {
    if (!root || depth > 20) return nil;
    if ([NSStringFromClass([root class]) isEqualToString:@"FFProTimelineView"]) return root;
    for (NSView *sub in root.subviews) {
        NSView *hit = PO_findFFProTimelineView(sub, depth + 1);
        if (hit) return hit;
    }
    return nil;
}

static NSView *PO_currentTimelineView(void) {
    // Prefer the view captured in the swizzle — it's the one actually
    // receiving playhead updates right now, even across dual-timeline /
    // focus changes.
    NSView *fromSwizzle = sSwizzleCapturedViewWeak;
    if (fromSwizzle && fromSwizzle.window) {
        sTimelineViewWeak = fromSwizzle;
        return fromSwizzle;
    }
    NSView *existing = sTimelineViewWeak;
    if (existing && existing.window) return existing;
    for (NSWindow *w in [NSApp windows]) {
        NSString *cn = NSStringFromClass([w class]);
        if (![cn containsString:@"PEWindow"]) continue;
        NSView *hit = PO_findFFProTimelineView(w.contentView, 0);
        if (hit) {
            sTimelineViewWeak = hit;
            return hit;
        }
    }
    return nil;
}

// Try a few ivar names Apple has used for the playhead layer on TLKTimelineView.
static CALayer *PO_findRealPlayheadLayer(NSView *timelineView) {
    if (!timelineView) return nil;
    NSArray *keys = @[@"playheadMarker", @"_playheadMarker", @"playhead",
                      @"_playhead", @"playheadLayer", @"_playheadLayer"];
    for (NSString *key in keys) {
        @try {
            id v = [timelineView valueForKey:key];
            if ([v isKindOfClass:[CALayer class]]) {
                return v;
            }
        } @catch (NSException *e) {
            // valueForKey: is strict — swallow and continue
        }
    }
    return nil;
}

// Query the active FFContext's current rate. During playback this is typically
// 1.0 (or the L/J speed); while paused it's 0.0.
static double PO_currentRate(void) {
    id tm = SpliceKit_getActiveTimelineModule();
    if (!tm) return 0.0;
    SEL ctxSel = NSSelectorFromString(@"context");
    if (![tm respondsToSelector:ctxSel]) return 0.0;
    id ctx = ((id (*)(id, SEL))objc_msgSend)(tm, ctxSel);
    if (!ctx) return 0.0;
    SEL rateSel = NSSelectorFromString(@"rate");
    if (![ctx respondsToSelector:rateSel]) return 0.0;
    return ((double (*)(id, SEL))objc_msgSend)(ctx, rateSel);
}

// Convert an extrapolated CMTime to an x coordinate in the timeline view's
// own coordinate space, via -[TLKTimelineView locationRangeForTime:].
static BOOL PO_xForTime(NSView *timelineView, PO_CMTime t, double *outX) {
    if (!timelineView || !outX) return NO;
    SEL sel = @selector(locationRangeForTime:);
    if (![timelineView respondsToSelector:sel]) return NO;
    PO_TLKRange range = {0};
    @try {
        range = ((PO_TLKRange (*)(id, SEL, PO_CMTime))PO_STRET)(timelineView, sel, t);
    } @catch (NSException *e) {
        return NO;
    }
    *outX = range.location;
    return YES;
}

static void PO_seedObservationFromView(NSView *view) {
    if (!view) return;
    SEL phSel = @selector(playheadTime);
    if (![view respondsToSelector:phSel]) return;
    @try {
        PO_CMTime t = ((PO_CMTime (*)(id, SEL))PO_STRET)(view, phSel);
        if (t.timescale <= 0) return;
        os_unfair_lock_lock(&sObservedLock);
        sObservedTime = t;
        sObservedWall = CACurrentMediaTime();
        sObservedRate = PO_currentRate();
        os_unfair_lock_unlock(&sObservedLock);
    } @catch (...) {}
}

// ---- Swizzled -[TLKTimelineView _setPlayheadTime_NoKVO:animate:] ----

static void SpliceKit_swizzled_setPlayheadTimeNoKVO(id self_, SEL _cmd,
                                                     PO_CMTime time, BOOL animate) {
    // Call original FIRST so the real UI updates as normal. Then capture.
    ((void (*)(id, SEL, PO_CMTime, BOOL))sOrigSetPlayheadTimeNoKVO)(self_, _cmd, time, animate);

    // While a playback session is active, ignore updates belonging to a
    // different timeline/player. Global PEPlayer notifications can cover the
    // browser and a secondary timeline too; allowing either to replace our
    // captured view made the playhead jump between windows.
    NSView *playbackView = sPlaybackTimelineViewWeak;
    if (sIsPlaying && playbackView && self_ != playbackView) return;

    double rate = PO_currentRate();
    CFTimeInterval now = CACurrentMediaTime();

    os_unfair_lock_lock(&sObservedLock);
    sObservedTime = time;
    sObservedWall = now;
    sObservedRate = rate;
    // Capture the actual TLKTimelineView receiving the update — the tick
    // should prefer this over window-walking so dual-timeline / focus
    // changes don't land us on a stale view.
    if ([self_ isKindOfClass:[NSView class]]) {
        sSwizzleCapturedViewWeak = (NSView *)self_;
    }
    os_unfair_lock_unlock(&sObservedLock);

    // appDidLaunch can run before FCP restores the last project. A paused
    // playhead update is the earliest reliable signal that the timeline view
    // and its window are ready, so prepare the reusable display link then.
    if (sOverlayInstalled && !sIsPlaying && !sDisplayLink &&
        [self_ isKindOfClass:[NSView class]]) {
        __weak NSView *weakView = (NSView *)self_;
        dispatch_async(dispatch_get_main_queue(), ^{
            NSView *view = weakView;
            if (sOverlayInstalled && !sIsPlaying && !sDisplayLink && view.window) {
                PO_prepareDisplayLink(view);
            }
        });
    }
}

// ---- Native marker positioning ----

static void PO_setNativePlayheadX(CALayer *marker, double x) {
    if (!marker || !isfinite(x)) return;
    CGPoint p = marker.position;
    if (fabs(p.x - x) < 0.01) return;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    marker.position = CGPointMake((CGFloat)x, p.y);
    [CATransaction commit];
}

static void PO_restoreAppleScroller(void) {
    sPendingCenteredScrollTakeover = NO;
    id paused = sPausedScrollingTimelineWeak;
    if (paused) {
        @try {
            SEL pausedSet = NSSelectorFromString(@"setPaused:");
            if ([paused respondsToSelector:pausedSet]) {
                ((void (*)(id, SEL, BOOL))objc_msgSend)(paused, pausedSet,
                                                        sScrollingTimelineWasPaused);
            }
        } @catch (...) {}
    }
    sPausedScrollingTimelineWeak = nil;
    sScrollingTimelineWasPaused = NO;
}

static void PO_activateCenteredScrollTakeover(NSView *view) {
    if (!sPendingCenteredScrollTakeover || !view || sTrackingDepth != 0) return;
    // Consume the pending handoff before calling private code so an exception
    // cannot make every subsequent display tick retry it.
    sPendingCenteredScrollTakeover = NO;
    @try {
        SEL stSel = NSSelectorFromString(@"scrollingTimeline");
        id scrollingTimeline = [view respondsToSelector:stSel]
            ? ((id (*)(id, SEL))objc_msgSend)(view, stSel) : nil;
        if (!scrollingTimeline) return;

        SEL pausedGet = NSSelectorFromString(@"paused");
        SEL pausedSet = NSSelectorFromString(@"setPaused:");
        if ([scrollingTimeline respondsToSelector:pausedGet]) {
            sScrollingTimelineWasPaused =
                ((BOOL (*)(id, SEL))objc_msgSend)(scrollingTimeline, pausedGet);
        }
        if ([scrollingTimeline respondsToSelector:pausedSet]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(scrollingTimeline, pausedSet, YES);
            sPausedScrollingTimelineWeak = scrollingTimeline;
            SpliceKit_log(@"[PlayheadOverlay] First smooth frame ready; paused "
                          @"TLKScrollingTimeline (centered-playback mode)");
        }
    } @catch (...) {}
}

static void PO_snapNativePlayheadToModel(void) {
    NSView *view = sPlaybackTimelineViewWeak;
    CALayer *marker = sNativePlayheadLayerWeak;
    if (!view || !marker) return;
    SEL phSel = @selector(playheadTime);
    if (![view respondsToSelector:phSel]) return;
    @try {
        PO_CMTime t = ((PO_CMTime (*)(id, SEL))PO_STRET)(view, phSel);
        double x = 0.0;
        if (t.timescale > 0 && PO_xForTime(view, t, &x)) {
            PO_setNativePlayheadX(marker, x);
        }
    } @catch (...) {}
}

// ---- Display link tick ----

@interface SpliceKitPlayheadOverlayTarget : NSObject
@end

// Reads the user's "Continuous Scrolling" preference — the toggle that
// controls whether the timeline scrolls to keep the playhead centered
// during playback, or whether the playhead slides off to the right.
//
// This lives on TLKTimelineView as -scrollDuringPlayback (backed by the
// FFScrollDuringPlaybackKey NSUserDefaults key, wired from
// -[FFAnchoredTimelineModule updateTimelineScrollDuringPlaybackToMatchUserDefaults]).
//
// IMPORTANT: we deliberately do NOT use `keepsPlayheadCenteredDuringPlayback`
// here. That one looks like the right property by name, but it's a computed
// value driven by playback rate — it's NO at normal rate=1.0 and only
// flips YES during fast-forward / rewind. Using it as a gate made Smooth
// Scroll silently skip the 120Hz centered path for every normal playback.
static BOOL PO_scrollDuringPlayback(id timelineView) {
    if (!timelineView) return NO;
    @try {
        SEL sel = NSSelectorFromString(@"scrollDuringPlayback");
        if (![timelineView respondsToSelector:sel]) return NO;
        return ((BOOL (*)(id, SEL))objc_msgSend)(timelineView, sel);
    } @catch (...) {}
    return NO;
}

@implementation SpliceKitPlayheadOverlayTarget
- (void)tick:(CADisplayLink *)link {
    NSView *view = sPlaybackTimelineViewWeak;
    CALayer *marker = sNativePlayheadLayerWeak;
    if (!view || !view.window || !marker || !marker.superlayer) {
        // Timeline teardown or a project/window switch: fail back to Apple's
        // normal scroller immediately instead of calling into a stale view.
        PO_restoreAppleScroller();
        sDisplayLink.paused = YES;
        return;
    }

    os_unfair_lock_lock(&sObservedLock);
    PO_CMTime base = sObservedTime;
    CFTimeInterval baseWall = sObservedWall;
    double rate = sObservedRate;
    os_unfair_lock_unlock(&sObservedLock);

    // If nothing has been observed yet, we have no reference — skip this tick.
    if (base.timescale <= 0 || baseWall <= 0.0) return;

    // Skip when paused: tick only needs to extrapolate during active playback,
    // and if we've gone idle the cached view may be mid-teardown. APPLE-MACOS-P
    // shows EXC_BAD_ACCESS deep inside locationRangeForTime: when this fires
    // against a view whose internals were freed.
    if (rate == 0.0) return;

    // Stale observation: if we haven't seen a setPlayheadTime in a while, the
    // cached view may have been replaced (sequence change, dual-timeline
    // toggle). Bail out and wait for a fresh observation rather than calling
    // into a possibly-dead view.
    CFTimeInterval elapsed = CACurrentMediaTime() - baseWall;
    if (elapsed > 1.0) {
        PO_restoreAppleScroller();
        sDisplayLink.paused = YES;
        return;
    }

    // Extrapolate forward: t_now = base + (now - baseWall) * rate
    double extraSecs = elapsed * rate;
    PO_CMTime extrapolated = base;
    int64_t addValue = (int64_t)llround(extraSecs * (double)base.timescale);
    extrapolated.value += addValue;

    double x = 0.0;
    if (!PO_xForTime(view, extrapolated, &x) || !isfinite(x)) {
        // If the private mapping API becomes temporarily unavailable, native
        // playhead updates still work. Restore Apple's scrolling so failure of
        // the enhancement cannot freeze continuous scrolling.
        PO_restoreAppleScroller();
        sDisplayLink.paused = YES;
        return;
    }

    // Make the handoff only after a callback has a non-zero playback rate and
    // a valid timeline coordinate. Until this exact point Apple's native
    // scroller remains authoritative, so a delayed first callback cannot
    // present as a frozen playhead/timeline hitch.
    if (sAwaitingFirstDisplayLinkTick) {
        sAwaitingFirstDisplayLinkTick = NO;
        static NSUInteger sLoggedStartDelays = 0;
        if (sLoggedStartDelays < 12 && sDisplayLinkResumeWall > 0.0) {
            double delayMs = (CACurrentMediaTime() - sDisplayLinkResumeWall) * 1000.0;
            SpliceKit_log(@"[PlayheadOverlay] First active display tick %.1f ms after resume", delayMs);
            sLoggedStartDelays++;
        }
    }
    PO_activateCenteredScrollTakeover(view);

    // ── Smooth centered-scroll path ──────────────────────────────────────
    // During Perf Mode playback (when the safety gate accepted), Apple's
    // TLKScrollingTimeline is paused and our tick is authoritative. Drive
    // the scroll directly on the clip view — that's what Apple's own
    // scrollPoint: ultimately does, minus any guards in
    // -[TLKTimelineView scrollTimelineToPoint:] that can short-circuit
    // when the tlkViewFlags re-entrancy bit happens to be set.
    BOOL drivingScroll = (sPausedScrollingTimelineWeak != nil && sTrackingDepth == 0);
    NSRect vrect = NSZeroRect;
    if (drivingScroll) {
        @try {
            vrect = [view visibleRect];
        } @catch (...) {}
    }

    if (drivingScroll && vrect.size.width > 0.0) {
        CGFloat halfWidth = vrect.size.width * 0.5;
        CGFloat targetOriginX = x - halfWidth;

        // Clamp to content bounds so we never ask for a negative or
        // beyond-end origin (scrollPoint quietly does this too, but doing
        // it up front also gives us an accurate comparison to decide
        // whether we need to scroll at all).
        CGFloat contentWidth = view.bounds.size.width;
        CGFloat maxOriginX = MAX(0.0, contentWidth - vrect.size.width);
        if (targetOriginX < 0.0) targetOriginX = 0.0;
        if (targetOriginX > maxOriginX) targetOriginX = maxOriginX;

        if (fabs(vrect.origin.x - targetOriginX) > 0.25) {
            NSView *docSuper = view.superview;
            NSClipView *clipView = [docSuper isKindOfClass:[NSClipView class]]
                ? (NSClipView *)docSuper : nil;
            NSPoint newOrigin = NSMakePoint(targetOriginX, vrect.origin.y);

            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            if (clipView) {
                // Low-level path: move the clip view's bounds origin and
                // reflect to the scroll view. Bypasses Apple's
                // scrollTimelineToPoint: reentrancy guard.
                [clipView setBoundsOrigin:newOrigin];
                [clipView.enclosingScrollView reflectScrolledClipView:clipView];
                // Update vrect so the center-pin math below uses the new origin.
                vrect.origin.x = targetOriginX;
            } else {
                // Fallback: standard scrollPoint on the timeline view.
                [view scrollPoint:newOrigin];
                vrect.origin.x = targetOriginX;
            }
            [CATransaction commit];

            // Diagnostic: log the first few ticks so we can verify the
            // scroll is actually moving. Throttle so we don't flood the log.
            static int sLogged = 0;
            if (sLogged < 5) {
                SpliceKit_log(@"[PlayheadOverlay] tick x=%.1f vrect.origin.x=%.1f → %.1f "
                              @"clipView=%@ contentW=%.0f viewportW=%.0f",
                              x, vrect.origin.x, targetOriginX,
                              clipView ? @"yes" : @"no",
                              contentWidth, vrect.size.width);
                sLogged++;
            }
        }

        // The marker stays in content coordinates. When scrolling succeeds,
        // x naturally appears at screen center; near the content boundaries it
        // remains at the truthful, unclamped playhead location.
    }

    PO_setNativePlayheadX(marker, x);
}
@end

static SpliceKitPlayheadOverlayTarget *sDisplayLinkTarget = nil;

static void PO_disposeDisplayLink(void) {
    [sDisplayLink invalidate];
    sDisplayLink = nil;
    sDisplayLinkWindowWeak = nil;
}

static BOOL PO_prepareDisplayLink(NSView *timelineView) {
    NSWindow *window = timelineView.window;
    if (sDisplayLink && (!sDisplayLinkWindowWeak || sDisplayLinkWindowWeak == window)) {
        return YES;
    }
    if (sDisplayLink) PO_disposeDisplayLink();
    if (!sDisplayLinkTarget) sDisplayLinkTarget = [[SpliceKitPlayheadOverlayTarget alloc] init];

    CADisplayLink *link = nil;
    if ([window respondsToSelector:@selector(displayLinkWithTarget:selector:)]) {
        link = [window displayLinkWithTarget:sDisplayLinkTarget
                                    selector:@selector(tick:)];
    }
    if (!link) {
        link = [NSScreen.mainScreen displayLinkWithTarget:sDisplayLinkTarget
                                                 selector:@selector(tick:)];
    }
    if (!link) return NO;
    // Creating and registering a window display link can take several frames.
    // Keep one prepared across playback sessions and only toggle its paused
    // state so hitting Play has no recurring setup cost.
    link.paused = YES;
    [link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    sDisplayLink = link;
    sDisplayLinkWindowWeak = window;
    SpliceKit_log(@"[PlayheadOverlay] Prepared reusable display link");
    return YES;
}

static BOOL PO_startDisplayLink(NSView *timelineView) {
    if (!PO_prepareDisplayLink(timelineView)) return NO;
    sDisplayLinkResumeWall = CACurrentMediaTime();
    sAwaitingFirstDisplayLinkTick = YES;
    sDisplayLink.paused = NO;
    return YES;
}

static void PO_pauseDisplayLink(void) {
    sDisplayLink.paused = YES;
    sAwaitingFirstDisplayLinkTick = NO;
}

static void PO_prepareDisplayLinkWhenTimelineReady(NSUInteger attemptsRemaining) {
    if (!sOverlayInstalled || sDisplayLink || attemptsRemaining == 0) return;
    NSView *view = PO_currentTimelineView();
    if (view && PO_prepareDisplayLink(view)) return;

    // FCP restores the active project several seconds after SpliceKit's launch
    // callback. Retry quietly while idle so even the first press of Play gets
    // the already-registered display link instead of paying its setup cost.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        PO_prepareDisplayLinkWhenTimelineReady(attemptsRemaining - 1);
    });
}

// ---- Play/pause transitions ----

static void PO_onPlaybackBegan(id source) {
    CFTimeInterval beginEntryWall = CACurrentMediaTime();
    if (sIsPlaying) {
        // Duplicate begin notifications are common for the same player. Do
        // not overwrite cleanup state or pause another scrolling timeline.
        return;
    }
    sIsPlaying = YES;
    sPlaybackSourceWeak = source;
    NSView *view = PO_currentTimelineView();
    if (!view) {
        sIsPlaying = NO;
        sPlaybackSourceWeak = nil;
        return;
    }
    CALayer *marker = PO_findRealPlayheadLayer(view);
    if (!marker) {
        SpliceKit_log(@"[PlayheadOverlay] Native TLKPlayheadMarker not found — leaving FCP unchanged");
        sIsPlaying = NO;
        sPlaybackSourceWeak = nil;
        return;
    }
    sPlaybackTimelineViewWeak = view;
    sNativePlayheadLayerWeak = marker;
    sTrackingDepth = 0;

    static NSUInteger sBeginDiagnostics = 0;
    if (sBeginDiagnostics < 12) {
        @try {
            PO_CMTime diagnosticTime = ((PO_CMTime (*)(id, SEL))PO_STRET)(view, @selector(playheadTime));
            double timeX = NAN;
            PO_xForTime(view, diagnosticTime, &timeX);
            CGPoint modelPosition = marker.position;
            CALayer *presentedLayer = (CALayer *)marker.presentationLayer;
            CGPoint presentedPosition = presentedLayer ? presentedLayer.position : modelPosition;
            SpliceKit_log(@"[PlayheadOverlay] Begin handoff modelX=%.2f presentedX=%.2f "
                          @"timeX=%.2f work=%.2fms",
                          modelPosition.x, presentedPosition.x, timeX,
                          (CACurrentMediaTime() - beginEntryWall) * 1000.0);
            sBeginDiagnostics++;
        } @catch (...) {}
    }

    // Always re-seed observation on playback begin so extrapolation starts
    // from the current-known state, not stale data from a previous session.
    SEL phSel = @selector(playheadTime);
    PO_seedObservationFromView(view);

    // Respect the user's "Continuous Scrolling" preference (the
    // FFScrollDuringPlaybackKey NSUserDefaults toggle). If it's OFF, we
    // should only move the native marker smoothly and let FCP's native
    // edge-tracking handle the scroll (playhead slides right, timeline
    // stays put until the playhead hits the side threshold). If it's ON,
    // we take over the scroll so centering happens smoothly at display
    // refresh instead of FCP's 30Hz step-based centering.
    BOOL userWantsCentered = PO_scrollDuringPlayback(view);

    // Do not touch Apple's scrolling machinery unless the display link that
    // replaces it is actually running. The native marker remains visible in
    // every failure path.
    if (!PO_startDisplayLink(view)) {
        SpliceKit_log(@"[PlayheadOverlay] Could not create display link — leaving FCP unchanged");
        sPlaybackTimelineViewWeak = nil;
        sNativePlayheadLayerWeak = nil;
        sPlaybackSourceWeak = nil;
        sIsPlaying = NO;
        return;
    }

    // Safety gate: only pause Apple's scroll machinery if we can actually
    // drive our own replacement. If locationRangeForTime: or the clip-view
    // lookup fails, leave Apple's scroller running and only animate the
    // native marker — still a visual win, no functional regression.
    BOOL canDriveScroll = NO;
    if (userWantsCentered && [view respondsToSelector:phSel]) {
        PO_CMTime probeTime = ((PO_CMTime (*)(id, SEL))PO_STRET)(view, phSel);
        double probeX = 0.0;
        BOOL gotX = (probeTime.timescale > 0) && PO_xForTime(view, probeTime, &probeX);
        BOOL gotClip = [view.superview isKindOfClass:[NSClipView class]];
        canDriveScroll = gotX && gotClip && isfinite(probeX);
        if (!canDriveScroll) {
            SpliceKit_log(@"[PlayheadOverlay] Safety gate: not pausing Apple scroller "
                          @"(gotX=%d gotClip=%d) — native-marker-only mode",
                          (int)gotX, (int)gotClip);
        }
    }

    // Hand off Apple's auto-scroll *only* when the user has centered-during-
    // playback on AND our safety probe succeeded. The actual pause is deferred
    // to our first valid display-link frame so there is never an uncovered gap
    // at playback start. TLKScrollingTimeline otherwise runs step-based
    // `scrollPlayheadTowardMiddle` on every playhead-time update (30Hz on a 30p
    // project); on a ProMotion display that reads as the timeline hopping
    // sideways a few times per second.
    // When centered is OFF, we want Apple's edge-threshold scroll left
    // intact — the user explicitly chose "playhead slides off to the right
    // until it reaches the edge," and animating the native marker already
    // gives them a smooth playhead.
    sPausedScrollingTimelineWeak = nil;
    sScrollingTimelineWasPaused = NO;
    sPendingCenteredScrollTakeover = userWantsCentered && canDriveScroll;

    // FCP can deliver its begin-playback notification just before FFContext's
    // rate flips from 0 to the requested speed. Refresh once after notification
    // delivery completes so the first display-link callback does not wait for
    // the next project-frame playhead update (up to 42 ms on a 24p timeline).
    __weak NSView *weakView = view;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSView *sessionView = weakView;
        if (!sOverlayInstalled || !sIsPlaying ||
            !sessionView || sPlaybackTimelineViewWeak != sessionView) return;
        PO_seedObservationFromView(sessionView);
    });

}

static void PO_endPlaybackSession(void) {
    sIsPlaying = NO;
    PO_pauseDisplayLink();
    PO_snapNativePlayheadToModel();
    PO_restoreAppleScroller();
    sPlaybackTimelineViewWeak = nil;
    sNativePlayheadLayerWeak = nil;
    sPlaybackSourceWeak = nil;
    sTrackingDepth = 0;
}

static void PO_onPlaybackEnded(id source) {
    if (!sIsPlaying) return;
    id activeSource = sPlaybackSourceWeak;
    if (activeSource && source && activeSource != source) {
        // Ignore a browser/secondary-player end notification while the
        // timeline player that started this session is still active.
        return;
    }
    PO_endPlaybackSession();
}

// ---- Install / remove ----

static BOOL sObserversRegistered = NO;

static void PO_registerObservers(void) {
    if (sObserversRegistered) return;
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];

    [nc addObserverForName:@"PEPlayerDidBeginPlaybackNotification"
                    object:nil queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
        if (sOverlayInstalled) PO_onPlaybackBegan(note.object);
    }];
    [nc addObserverForName:@"PEPlayerDidEndPlaybackNotification"
                    object:nil queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
        if (sOverlayInstalled) PO_onPlaybackEnded(note.object);
    }];

    // Suspend our centered-scroll takeover while the user is actively
    // dragging, trimming, zooming, or scrolling this timeline. The native
    // marker continues to animate, but Smooth Scroll no longer fights direct
    // manipulation on NSRunLoopCommonModes.
    [nc addObserverForName:@"TLKEventHandlerDidStartTrackingNotification"
                    object:nil queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
        if (!sOverlayInstalled || !sIsPlaying) return;
        id handler = note.object;
        id handlerView = nil;
        @try {
            SEL timelineViewSel = @selector(timelineView);
            SEL viewSel = @selector(view);
            if ([handler respondsToSelector:timelineViewSel])
                handlerView = ((id (*)(id, SEL))objc_msgSend)(handler, timelineViewSel);
            else if ([handler respondsToSelector:viewSel])
                handlerView = ((id (*)(id, SEL))objc_msgSend)(handler, viewSel);
        } @catch (...) {}
        if (handlerView == sPlaybackTimelineViewWeak) sTrackingDepth++;
    }];
    [nc addObserverForName:@"TLKEventHandlerDidStopTrackingNotification"
                    object:nil queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
        if (!sOverlayInstalled || !sIsPlaying) return;
        id handler = note.object;
        id handlerView = nil;
        @try {
            SEL timelineViewSel = @selector(timelineView);
            SEL viewSel = @selector(view);
            if ([handler respondsToSelector:timelineViewSel])
                handlerView = ((id (*)(id, SEL))objc_msgSend)(handler, timelineViewSel);
            else if ([handler respondsToSelector:viewSel])
                handlerView = ((id (*)(id, SEL))objc_msgSend)(handler, viewSel);
        } @catch (...) {}
        if (handlerView == sPlaybackTimelineViewWeak && sTrackingDepth > 0) sTrackingDepth--;
    }];
    sObserversRegistered = YES;
}

void SpliceKit_installTimelinePlayheadOverlay(void) {
    if (sOverlayInstalled) return;

    Class tlvCls = objc_getClass("TLKTimelineView");
    if (!tlvCls) {
        SpliceKit_log(@"[PlayheadOverlay] TLKTimelineView not found — skip");
        return;
    }

    SEL sel = @selector(_setPlayheadTime_NoKVO:animate:);
    Method m = class_getInstanceMethod(tlvCls, sel);
    if (!m) {
        SpliceKit_log(@"[PlayheadOverlay] _setPlayheadTime_NoKVO:animate: not found — overlay will not track playback");
        return;
    }
    sOrigSetPlayheadTimeNoKVO = method_setImplementation(
        m, (IMP)SpliceKit_swizzled_setPlayheadTimeNoKVO);
    SpliceKit_log(@"[PlayheadOverlay] Swizzled -[TLKTimelineView _setPlayheadTime_NoKVO:animate:]");

    PO_registerObservers();
    sOverlayInstalled = YES;
    SpliceKit_log(@"[PlayheadOverlay] Installed");

    // Pay the one-time display-link creation cost while FCP is idle whenever
    // a timeline is already available. If a project opens later, first play
    // prepares it and all subsequent starts still reuse it.
    dispatch_async(dispatch_get_main_queue(), ^{
        PO_prepareDisplayLinkWhenTimelineReady(40); // up to 10 seconds
    });
}

void SpliceKit_removeTimelinePlayheadOverlay(void) {
    if (!sOverlayInstalled) return;
    // This must happen before the observer gate is lowered. In particular,
    // restore a TLKScrollingTimeline paused by us if the user disables Smooth
    // Scroll in the middle of playback.
    PO_endPlaybackSession();
    PO_disposeDisplayLink();

    Class tlvCls = objc_getClass("TLKTimelineView");
    if (tlvCls && sOrigSetPlayheadTimeNoKVO) {
        Method m = class_getInstanceMethod(tlvCls, @selector(_setPlayheadTime_NoKVO:animate:));
        if (m) method_setImplementation(m, sOrigSetPlayheadTimeNoKVO);
        sOrigSetPlayheadTimeNoKVO = NULL;
    }

    sOverlayInstalled = NO;
    SpliceKit_log(@"[PlayheadOverlay] Removed");
}

void SpliceKit_setTimelinePlayheadOverlayEnabled(BOOL enabled) {
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:kDefTimelinePlayheadOverlay];
    if (enabled) {
        SpliceKit_installTimelinePlayheadOverlay();
    } else {
        SpliceKit_removeTimelinePlayheadOverlay();
    }
}

BOOL SpliceKit_isTimelinePlayheadOverlayEnabled(void) {
    NSNumber *n = [[NSUserDefaults standardUserDefaults]
                   objectForKey:kDefTimelinePlayheadOverlay];
    return n ? [n boolValue] : NO;
}
