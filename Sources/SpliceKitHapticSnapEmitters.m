//
//  SpliceKitHapticSnapEmitters.m
//  Adds tactile feedback for FCP timeline snap events that don't natively
//  fire a haptic.
//
//  What FCP already haptics
//  ------------------------
//    • Viewer-canvas snap (FFSnapGridOSC)
//    • Title-into-timeline drop snap (FFAnchoredTimelineModule _acceptDrop:)
//    • Trim/roll edge limit (TLKDragEdgesHandler)
//    • Force Touch FF/RW pressure step (FFTransportLongPressButton)
//
//  What FCP does NOT haptic — covered by this file
//  -----------------------------------------------
//    • Clip-body snap on the spine (drag a clip onto another clip's edge)
//    • Connected-clip snap to playhead, markers, edits
//    • Playhead snap to clip edges, markers, range edges
//    • Skim-playhead snap to the same set of targets
//
//  All of these route through one delegate callback:
//      -[FFAnchoredTimelineModule
//          snappingCalc:didSnapClips:atTime:withAligment:guideTypes:]
//  and one teardown:
//      -[FFAnchoredTimelineModule _removeSnappingGuides]
//
//  Debouncing — the harder part
//  ----------------------------
//  `-[FFAnchoredTimelineModule timelineView:willSetPlayheadTime:snap:]` runs
//  on every playhead-position update during scrubbing/dragging, and inside
//  it the sequence is literally:
//      _removeSnappingGuides      // tear down stale guides
//      snapPlayheadTime:…         // recompute → snappingCalc fires again
//  So the snap state visibly flips off→on dozens of times per second during
//  a sustained snap. Naive off→on debouncing fires a haptic on every tick.
//
//  We solve this with a delayed teardown. `_removeSnappingGuides` schedules
//  a "really release the snap" task ~80ms in the future; any `snappingCalc:`
//  that arrives before the deadline bumps a generation counter that the
//  pending task checks before applying — i.e. the new snap call cancels the
//  pending release. Only a teardown followed by genuine silence (no further
//  snap call within the window) ever flips state back to off.
//
//  End result: one haptic per snap engagement, no matter how chatty the
//  per-tick recompute, with the snap re-arming as soon as the user actually
//  drags out of the snap zone.

#import "SpliceKit.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <CoreMedia/CoreMedia.h>

static IMP sOrigSnappingCalc = NULL;
static IMP sOrigRemoveSnappingGuides = NULL;
static BOOL sSnapEmittersInstalled = NO;

// Per-FFAnchoredTimelineModule snap engagement state. Each entry tracks
//   snapped — current snap state ("am I currently engaged?")
//   gen     — bumped by every snappingCalc/_removeSnappingGuides call;
//             scheduled release tasks check the gen they were posted with
//             against the live one to decide whether to apply.
// Weak keys so timeline modules that close take their entries with them.
@interface SKSnapState : NSObject
@property (atomic) BOOL snapped;
@property (atomic) int64_t generation;
@end
@implementation SKSnapState
@end

static NSMapTable<id, SKSnapState *> *sStateByModule = nil;
static dispatch_queue_t sSnapStateQueue = NULL;

// How long after a teardown to wait before flipping to "really unsnapped".
// Must be longer than the inter-tick gap during sustained snap (~16ms at
// 60Hz) but short enough that re-engaging after a real drag-out feels like
// a fresh tap. 80ms is empirically a sweet spot.
static const NSTimeInterval kSKReleaseDelay = 0.080;

static SKSnapState *SK_snap_stateFor(id module) {
    SKSnapState *state = [sStateByModule objectForKey:module];
    if (!state) {
        state = [SKSnapState new];
        [sStateByModule setObject:state forKey:module];
    }
    return state;
}

// Called from the snappingCalc: hook. Returns YES if this snap call is the
// off→on transition (haptic should fire). Bumps the generation counter so
// any pending release task scheduled by an earlier `_removeSnappingGuides`
// becomes a no-op.
static BOOL SK_snap_recordSnapAndCheckTransition(id module) {
    if (!sStateByModule || !sSnapStateQueue) return YES;
    __block BOOL transitioned = NO;
    dispatch_sync(sSnapStateQueue, ^{
        SKSnapState *state = SK_snap_stateFor(module);
        state.generation++;
        if (!state.snapped) {
            state.snapped = YES;
            transitioned = YES;
        }
    });
    return transitioned;
}

// Called from the _removeSnappingGuides hook. Schedules a delayed flip to
// "unsnapped"; any snappingCalc: that lands in the meantime cancels it via
// the generation bump.
static void SK_snap_scheduleRelease(id module) {
    if (!sStateByModule || !sSnapStateQueue) return;
    __block int64_t scheduledGen = 0;
    __block SKSnapState *state = nil;
    dispatch_sync(sSnapStateQueue, ^{
        state = SK_snap_stateFor(module);
        state.generation++;
        scheduledGen = state.generation;
    });
    // Hold a strong ref to the state object across the delay so it stays
    // alive even if the module gets associated-object-cleaned in between.
    SKSnapState *strongState = state;
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kSKReleaseDelay * NSEC_PER_SEC)),
        sSnapStateQueue,
        ^{
            if (strongState.generation == scheduledGen) {
                strongState.snapped = NO;
            }
        });
}

// Determine whether a snap landed on the live or skim playhead so we can
// label "playhead snap" distinctly from "clip-edge snap". Mirrors the same
// CMTimeCompare branches the original snappingCalc: uses internally.
static BOOL SK_snap_isToPlayhead(id module, CMTime snapTime) {
    id timelineView = ((id (*)(id, SEL))objc_msgSend)(module, @selector(timelineView));
    if (!timelineView) return NO;

    // Cast objc_msgSend to a function pointer with the correct return type.
    // The compiler picks the right ABI for arm64 (x8 sret register) and
    // x86_64 (stret call) automatically, while objc_msgSend_stret is
    // unavailable on arm64.
    CMTime playheadTime = ((CMTime (*)(id, SEL))objc_msgSend)(
        timelineView, @selector(playheadTime));
    if (CMTimeCompare(snapTime, playheadTime) == 0) return YES;

    CMTime skimTime = ((CMTime (*)(id, SEL))objc_msgSend)(
        timelineView, @selector(skimmingPlayheadTime));
    return CMTimeCompare(snapTime, skimTime) == 0;
}

// Replacement IMP: signature must match the original exactly. The CMTime
// arrives by value, which on ARM64 is passed in registers — declaring it as
// a plain CMTime parameter handles the calling convention correctly.
static void SK_swz_snappingCalc(id self, SEL _cmd,
                                 id snappingCalc, id snappedClips,
                                 CMTime time, char alignment,
                                 id guideTypes) {
    // Emit a single haptic on the off→on transition. The recordSnap helper
    // also bumps the per-module generation counter, which cancels any
    // pending delayed-release task scheduled by a recent
    // `_removeSnappingGuides` call (FCP runs that teardown immediately
    // before re-snapping on every mouse-moved tick).
    if (SK_snap_recordSnapAndCheckTransition(self)) {
        BOOL toPlayhead = SK_snap_isToPlayhead(self, time);
        SpliceKit_emitHaptic(toPlayhead ? @"playhead_snap" : @"clip_snap");
    }

    if (sOrigSnappingCalc) {
        ((void (*)(id, SEL, id, id, CMTime, char, id))sOrigSnappingCalc)(
            self, _cmd, snappingCalc, snappedClips, time, alignment, guideTypes);
    }
}

static void SK_swz_removeSnappingGuides(id self, SEL _cmd) {
    // Don't flip state here directly — FCP calls this on every mouse-moved
    // tick during sustained snap, immediately followed by snappingCalc.
    // Schedule the flip ~80ms out; subsequent snappingCalc: arrivals will
    // bump the generation counter and the pending flip will become a no-op.
    SK_snap_scheduleRelease(self);
    if (sOrigRemoveSnappingGuides) {
        ((void (*)(id, SEL))sOrigRemoveSnappingGuides)(self, _cmd);
    }
}

void SpliceKit_installHapticSnapEmitters(void) {
    if (sSnapEmittersInstalled) return;

    Class moduleCls = objc_getClass("FFAnchoredTimelineModule");
    if (!moduleCls) {
        SpliceKit_log(@"[HapticSnap] FFAnchoredTimelineModule missing; bailing");
        return;
    }

    // Apple's selector spelling is "withAligment" (typo preserved from the
    // shipping binary). sel_registerName matches verbatim.
    SEL snapCalcSel = sel_registerName("snappingCalc:didSnapClips:atTime:withAligment:guideTypes:");
    SEL removeSel = sel_registerName("_removeSnappingGuides");

    if (![moduleCls instancesRespondToSelector:snapCalcSel]) {
        SpliceKit_log(@"[HapticSnap] -[FFAnchoredTimelineModule snappingCalc:…] missing; bailing");
        return;
    }
    if (![moduleCls instancesRespondToSelector:removeSel]) {
        SpliceKit_log(@"[HapticSnap] -[FFAnchoredTimelineModule _removeSnappingGuides] missing; "
                      @"snap state will not reset between drags — falling through to emit-on-change-only");
    }

    sSnapStateQueue = dispatch_queue_create("com.splicekit.haptic.snap.state", DISPATCH_QUEUE_SERIAL);
    sStateByModule = [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsWeakMemory
                                           valueOptions:NSPointerFunctionsStrongMemory];

    sOrigSnappingCalc = SpliceKit_swizzleMethod(moduleCls, snapCalcSel, (IMP)SK_swz_snappingCalc);
    if (!sOrigSnappingCalc) {
        SpliceKit_log(@"[HapticSnap] swizzle of snappingCalc:… failed; no snap haptics");
        return;
    }

    if ([moduleCls instancesRespondToSelector:removeSel]) {
        sOrigRemoveSnappingGuides = SpliceKit_swizzleMethod(
            moduleCls, removeSel, (IMP)SK_swz_removeSnappingGuides);
    }

    sSnapEmittersInstalled = YES;
    SpliceKit_log(@"[HapticSnap] installed: snappingCalc:%s _removeSnappingGuides:%s — "
                  @"emits 'clip_snap' / 'playhead_snap' on each new snap target",
                  sOrigSnappingCalc ? "✓" : "✗",
                  sOrigRemoveSnappingGuides ? "✓" : "✗");
}
