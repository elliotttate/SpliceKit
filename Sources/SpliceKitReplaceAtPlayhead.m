// SpliceKitReplaceAtPlayhead.m
//
// Restores the "Replace at Playhead" edit mode that Apple removed from FCP 12.2's UI.
// The underlying ObjC methods still exist — Apple only removed all UI entry points.
//
// This module re-wires it in two places:
//
//   1. The drag-drop menu shown when hovering a clip over the timeline.
//      In FCP 12.2 the Replace overlay is a plain NSMenu (LKMenu) stored as
//      FFAnchoredTimelineModule.dropMenu — not OZDropMenuWindow.
//      Swizzles FFAnchoredTimelineModule.init and _startListeningToSequence: to
//      append "Replace at Playhead" (→ actionDropMenuReplaceAtPlayhead:) after
//      "Replace from End". actionDropMenuReplaceAtPlayhead: is also swizzled to
//      fix its broken duration handling: the original performs a full replace
//      (changes target duration), so we trim the result back to the original
//      target duration after the replace.
//
//   2. FCP's Command Editor (View > Commands > Customize).
//      Registers the LKCommand and binds Option+Shift+R directly at install time
//      (LKCommandsController._loadCommands has already fired by the time our
//      swizzle is installed, so we can't rely on the swizzle for initial setup).
//      _loadCommands and _setActiveCommandSet: swizzles re-apply on future reloads
//      and command-set switches.

#import "SpliceKit.h"
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>

// CMTime struct (matches CoreMedia layout without linking the framework).
typedef struct { int64_t value; int32_t timescale; uint32_t flags; int64_t epoch; } SK_CMTime;
#define SK_kCMTimeInvalid ((SK_CMTime){0, 0, 0, 0})
static inline int  SK_CMTimeIsValid(SK_CMTime t)          { return t.timescale != 0; }
static inline int  SK_CMTimeCompare(SK_CMTime a, SK_CMTime b) {
    if (a.timescale == 0 || b.timescale == 0) return 0;
    // Convert to common timescale via cross-multiply to avoid overflow on typical values.
    __int128 av = (__int128)a.value * b.timescale;
    __int128 bv = (__int128)b.value * a.timescale;
    return (av > bv) - (av < bv);
}
static inline SK_CMTime SK_CMTimeSubtract(SK_CMTime a, SK_CMTime b) {
    if (a.timescale == b.timescale)
        return (SK_CMTime){a.value - b.value, a.timescale, a.flags, 0};
    // Normalize b to a's timescale to avoid int32 overflow when timescales differ
    // (e.g. 48000 × 90000 = 4.3B > INT32_MAX). Rounding error < 1/a.timescale seconds.
    int64_t b_in_a = ((int64_t)b.value * a.timescale + b.timescale / 2) / b.timescale;
    return (SK_CMTime){a.value - b_in_a, a.timescale, a.flags, 0};
}
static inline SK_CMTime SK_CMTimeAdd(SK_CMTime a, SK_CMTime b) {
    if (a.timescale == b.timescale)
        return (SK_CMTime){a.value + b.value, a.timescale, a.flags, 0};
    int64_t b_in_a = ((int64_t)b.value * a.timescale + b.timescale / 2) / b.timescale;
    return (SK_CMTime){a.value + b_in_a, a.timescale, a.flags, 0};
}
static inline SK_CMTime SK_CMTimeNegate(SK_CMTime t) { t.value = -t.value; return t; }
static inline double   SK_CMTimeGetSeconds(SK_CMTime t) {
    return t.timescale ? (double)t.value / t.timescale : 0.0;
}

// ---------------------------------------------------------------------------
// 1. Drag-drop menu injection
// ---------------------------------------------------------------------------
// FFAnchoredTimelineModule keeps a pre-built LKMenu in its `dropMenu` ivar.
// It's populated during -init and reused for every drag. We inject our item
// once per instance.
//
// actionDropMenuReplaceAtPlayhead: exists but is broken in FCP 12.2: it does a
// full replace that changes the target clip's duration to the full source length
// (same as plain "Replace"), instead of trimming the source to fit the target.
// We swizzle it to:
//   1. Run the original (which correctly uses the browser skimmer as source in-point)
//   2. Trim the replacement clip's end back to the original target's duration

// CMTimeRange: two consecutive CMTime values.
typedef struct { SK_CMTime start; SK_CMTime duration; } SK_CMTimeRange;

static SK_CMTime SpliceKit_readCMTime(id obj, SEL sel) {
    SK_CMTime t = SK_kCMTimeInvalid;
    NSMethodSignature *sig = [obj methodSignatureForSelector:sel];
    if (!sig) return t;
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    inv.target = obj; inv.selector = sel;
    [inv invoke];
    [inv getReturnValue:&t];
    return t;
}

static SK_CMTimeRange SpliceKit_readCMTimeRange(id obj, SEL sel) {
    SK_CMTimeRange r = { SK_kCMTimeInvalid, SK_kCMTimeInvalid };
    NSMethodSignature *sig = [obj methodSignatureForSelector:sel];
    if (!sig) return r;
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    inv.target = obj; inv.selector = sel;
    [inv invoke];
    [inv getReturnValue:&r];
    return r;
}

static void (*sOrigActionDropMenuReplaceAtPlayhead)(id, SEL, id);

// Target clip geometry captured in replaceWithPasteboard: (module level, has _deferredDropTargetItem)
// and consumed in operationReplaceItem:withItems: (sequence level).
// Both methods execute on the main thread, back-to-back in the same call stack.
static SK_CMTime sTargetClipStart = {0, 0, 0, 0};
static SK_CMTime sTargetClipDur   = {0, 0, 0, 0};

// Keyboard path geometry, set in SpliceKit_replaceWithSelectedMediaAtPlayhead BEFORE
// performEditAction: fires, consumed in SpliceKit_seqOperationReplaceItem.
// sKBReplaceInFlight gates the keyboard handling path to avoid interfering with other
// replace operations.
static SK_CMTime sKBTargetClipStart  = {0, 0, 0, 0};
static SK_CMTime sKBTargetClipDur    = {0, 0, 0, 0};
static SK_CMTime sKBDesiredSrcIn     = {0, 0, 0, 0};  // pre-computed srcIn (SPH=0 for keyboard path)
static SK_CMTime sKBOrgDesiredStart  = {0, 0, 0, 0};  // organizer-cumulative start = orgClipStart + desiredSrcIn
static BOOL      sKBReplaceInFlight  = NO;

// Swizzle on replaceWithPasteboard:replaceActionType: (FFAnchoredTimelineModule).
// Fires just before the drag-drop replace is executed. Captures target clip geometry
// (start position and duration) by walking containedItems and matching _deferredDropTargetItem
// by pointer identity.  Results are consumed in SpliceKit_seqOperationReplaceItem.
static void (*sOrigReplaceWithPasteboard)(id, SEL, id, int);

static void SpliceKit_replaceWithPasteboard(id self, SEL _cmd, id pasteboard, int actionType) {
    if (actionType == 1) {
        Ivar tgtIvar = class_getInstanceVariable(object_getClass(self), "_deferredDropTargetItem");
        id tgt = tgtIvar ? object_getIvar(self, tgtIvar) : nil;
        SEL durSel            = NSSelectorFromString(@"duration");
        SEL sequenceSel       = NSSelectorFromString(@"sequence");
        SEL primaryObjSel     = NSSelectorFromString(@"primaryObject");
        SEL containedItemsSel = NSSelectorFromString(@"containedItems");

        sTargetClipDur = (tgt && [tgt respondsToSelector:durSel])
            ? SpliceKit_readCMTime(tgt, durSel) : SK_kCMTimeInvalid;

        // Compute the target clip's absolute timeline start by walking the primary storyline
        // and matching by pointer identity. FFAnchoredCollection clips always return 0 from
        // timeOffset; position is cumulative sum of preceding durations.
        sTargetClipStart = SK_kCMTimeInvalid;
        if (tgt) {
            id sequence = [self respondsToSelector:sequenceSel]
                ? ((id (*)(id, SEL))objc_msgSend)(self, sequenceSel) : nil;
            id primary = (sequence && [sequence respondsToSelector:primaryObjSel])
                ? ((id (*)(id, SEL))objc_msgSend)(sequence, primaryObjSel) : nil;
            if (primary && [primary respondsToSelector:containedItemsSel]) {
                NSArray *clips = ((NSArray *(*)(id, SEL))objc_msgSend)(primary, containedItemsSel);
                SK_CMTime cursor = {0, 90000, 1, 0};
                for (id item in clips) {
                    if (item == tgt) { sTargetClipStart = cursor; break; }
                    SK_CMTime d = SpliceKit_readCMTime(item, durSel);
                    if (SK_CMTimeIsValid(d)) cursor = SK_CMTimeAdd(cursor, d);
                }
            }
        }
        SpliceKit_log(@"[ReplaceAtPlayhead] replaceWithPasteboard type=1: T1=%.3fs(v=%d) dur=%.3fs(v=%d)",
                      SK_CMTimeGetSeconds(sTargetClipStart), SK_CMTimeIsValid(sTargetClipStart),
                      SK_CMTimeGetSeconds(sTargetClipDur),   SK_CMTimeIsValid(sTargetClipDur));
    }
    sOrigReplaceWithPasteboard(self, _cmd, pasteboard, actionType);
}

// ---------------------------------------------------------------------------
// Swizzle on FFAnchoredSequence.operationReplaceItem:withItems:...
// Intercepts the structural replace to apply the correct source in-point
// immediately inside the operation context (the only safe place for all clip types).
// On arm64, CMTime (24 bytes > 16) is passed as a pointer-to-copy by the ABI.
// ---------------------------------------------------------------------------

// The function pointer type must match the actual arm64 calling convention:
// large structs (>16 bytes) are passed by hidden pointer, but since clang
// lowers CMTime the same way in both the IMP and in our wrapper, it just works.
typedef BOOL (*OrigSeqReplaceItemFn)(id, SEL, id, id, int, id *, SK_CMTime, SK_CMTime, BOOL);
static OrigSeqReplaceItemFn sOrigSeqOperationReplaceItem;

static BOOL SpliceKit_seqOperationReplaceItem(id self, SEL _cmd,
                                               id replaceItem,
                                               id withItems,
                                               int actionType,
                                               id *editsAdded,
                                               SK_CMTime playheadTime,
                                               SK_CMTime sourcePlayheadTime,
                                               BOOL autoCancelOnFail) {
    SK_CMTime targetStart       = SK_kCMTimeInvalid;
    SK_CMTime targetDur         = SK_kCMTimeInvalid;
    SK_CMTime effectivePH       = playheadTime;
    SK_CMTime effectiveSPH      = sourcePlayheadTime;
    SK_CMTime kbDesiredSrcIn    = SK_kCMTimeInvalid;
    SK_CMTime kbOrgDesiredStart = SK_kCMTimeInvalid;
    BOOL      isKBPath          = NO;

    if (actionType == 1 && sKBReplaceInFlight) {
        // Keyboard path: type=1 with our pre-armed geometry.
        isKBPath            = YES;
        targetStart         = sKBTargetClipStart;
        targetDur           = sKBTargetClipDur;
        kbDesiredSrcIn      = sKBDesiredSrcIn;
        kbOrgDesiredStart   = sKBOrgDesiredStart;
        sKBReplaceInFlight  = NO;
        sKBTargetClipStart  = SK_kCMTimeInvalid;
        sKBTargetClipDur    = SK_kCMTimeInvalid;
        sKBDesiredSrcIn     = SK_kCMTimeInvalid;
        sKBOrgDesiredStart  = SK_kCMTimeInvalid;
        SpliceKit_log(@"[ReplaceAtPlayhead] seqOpReplace KB: PH=%.3fs SPH=%.3fs "
                      "T1=%.3fs dur=%.3fs srcIn=%.3fs",
                      SK_CMTimeGetSeconds(playheadTime), SK_CMTimeGetSeconds(sourcePlayheadTime),
                      SK_CMTimeGetSeconds(targetStart),  SK_CMTimeGetSeconds(targetDur),
                      SK_CMTimeGetSeconds(kbDesiredSrcIn));
    } else if (actionType == 1 && !sKBReplaceInFlight) {
        // Drag-drop path: geometry from replaceWithPasteboard: swizzle.
        targetStart = sTargetClipStart;
        targetDur   = sTargetClipDur;
        sTargetClipStart = SK_kCMTimeInvalid;
        sTargetClipDur   = SK_kCMTimeInvalid;
    } else if (sKBReplaceInFlight) {
        // KB path fired with unexpected actionType — FCP changed its internal routing.
        sKBReplaceInFlight  = NO;
        sKBTargetClipStart  = SK_kCMTimeInvalid;
        sKBTargetClipDur    = SK_kCMTimeInvalid;
        sKBDesiredSrcIn     = SK_kCMTimeInvalid;
        sKBOrgDesiredStart  = SK_kCMTimeInvalid;
        SpliceKit_log(@"[ReplaceAtPlayhead] seqOpReplace KB unexpected actionType=%d — passthrough",
                      actionType);
        return sOrigSeqOperationReplaceItem(self, _cmd, replaceItem, withItems, actionType,
                                            editsAdded, playheadTime, sourcePlayheadTime,
                                            autoCancelOnFail);
    } else {
        return sOrigSeqOperationReplaceItem(self, _cmd, replaceItem, withItems, actionType,
                                            editsAdded, playheadTime, sourcePlayheadTime,
                                            autoCancelOnFail);
    }

    // ── KB pre-correction: substitute withItems with a correctly-ranged FigTimeRangeAndObject ──
    // withItems[0] is a FigTimeRangeAndObject from selectedRangesOfMedia. Its
    // clippedRange = {orgCursor, 0} because the user has a cursor (no range selected).
    // FCP uses clippedRange.start directly as the source in-point (SPH=0 → no phOffset
    // adjustment) and clippedRange.duration to size the placed clip → 1-frame stub.
    //
    // Fix: create a new FigTimeRangeAndObject{start=kbDesiredSrcIn, dur=targetDur}
    // keeping the same .object (the media source). FCP then places the clip at exactly
    // the right source in-point with the correct duration, without any post-correction.
    id substitutedWithItems = withItems;
    // Use organizer-cumulative coords for clippedRange.start:
    //   FCP interprets clippedRange.start as organizer position (not raw source coords).
    //   kbOrgDesiredStart = orgClipStart + desiredSrcIn  →  raw srcIn = desiredSrcIn ✓
    //   Passing raw kbDesiredSrcIn caused: range-outside-organizer rejection (large orgClipStart)
    //   or wrong raw placement (small orgClipStart).
    if (isKBPath && SK_CMTimeIsValid(kbOrgDesiredStart) && SK_CMTimeIsValid(targetDur)) {
        Class figClass = NSClassFromString(@"FigTimeRangeAndObject");
        SEL factorySel = NSSelectorFromString(@"rangeAndObjectWithRange:andObject:");
        id firstItem = [withItems isKindOfClass:[NSArray class]]
            ? [(NSArray *)withItems firstObject] : withItems;
        SEL objSel0 = NSSelectorFromString(@"object");
        id origObj = (firstItem && [firstItem respondsToSelector:objSel0])
            ? ((id (*)(id, SEL))objc_msgSend)(firstItem, objSel0) : nil;
        if (figClass && origObj) {
            SK_CMTimeRange newRange = { kbOrgDesiredStart, targetDur };
            id newItem = ((id (*)(Class, SEL, SK_CMTimeRange, id))objc_msgSend)(
                figClass, factorySel, newRange, origObj);
            if (newItem) {
                substitutedWithItems = @[newItem];
                SpliceKit_log(@"[ReplaceAtPlayhead] KB withItems substituted: "
                              "orgStart=%.3fs rawSrcIn=%.3fs dur=%.3fs",
                              SK_CMTimeGetSeconds(kbOrgDesiredStart),
                              SK_CMTimeGetSeconds(kbDesiredSrcIn),
                              SK_CMTimeGetSeconds(targetDur));
            } else {
                SpliceKit_log(@"[ReplaceAtPlayhead] KB FigTimeRangeAndObject factory returned nil");
            }
        } else {
            SpliceKit_log(@"[ReplaceAtPlayhead] KB withItems substitution failed: "
                          "figClass=%@ origObj=%@",
                          NSStringFromClass(figClass), origObj);
        }
    }

    id __autoreleasing localEdits = nil;
    id __autoreleasing *editsPtr = editsAdded ? (id __autoreleasing *)editsAdded : &localEdits;
    BOOL result = sOrigSeqOperationReplaceItem(self, _cmd, replaceItem, substitutedWithItems,
                                               actionType, (id *)editsPtr, playheadTime,
                                               sourcePlayheadTime, autoCancelOnFail);
    if (!result) return result;

    // ── KB path: FigTimeRangeAndObject substitution already placed at kbDesiredSrcIn ──
    // We pre-set withItems[0].clippedRange = {kbDesiredSrcIn, targetDur} above.
    // FCP places within sub-frame rounding (~0.02s) — no secondary setTimeRangeInAsset:
    // needed. The secondary call previously caused FCP's post-op validation to crash.
    if (isKBPath) {
        SpliceKit_log(@"[ReplaceAtPlayhead] KB placed (no correction): srcIn≈%.3fs dur≈%.3fs",
                      SK_CMTimeGetSeconds(kbDesiredSrcIn), SK_CMTimeGetSeconds(targetDur));
        return result;
    }

    // ── Drag-drop path: post-correction (srcIn via setTimeRangeInAsset:) ─────
    id added = editsPtr ? *editsPtr : nil;
    id wrapper = [added isKindOfClass:[NSArray class]] ? [(NSArray *)added firstObject] : added;
    if (!wrapper) {
        SpliceKit_log(@"[ReplaceAtPlayhead] editsAdded empty — alignment not applied");
        return result;
    }
    SEL objSel = NSSelectorFromString(@"object");
    id newClip = [wrapper respondsToSelector:objSel]
        ? ((id (*)(id, SEL))objc_msgSend)(wrapper, objSel)
        : wrapper;

    SpliceKit_log(@"[ReplaceAtPlayhead] type=%d T1=%.3fs(v=%d) PH=%.3fs(v=%d) SPH=%.3fs dur=%.3fs(v=%d)",
                  actionType,
                  SK_CMTimeGetSeconds(targetStart),  SK_CMTimeIsValid(targetStart),
                  SK_CMTimeGetSeconds(effectivePH),  SK_CMTimeIsValid(effectivePH),
                  SK_CMTimeGetSeconds(effectiveSPH),
                  SK_CMTimeGetSeconds(targetDur),    SK_CMTimeIsValid(targetDur));

    if (!SK_CMTimeIsValid(effectivePH) || !SK_CMTimeIsValid(targetStart) || !SK_CMTimeIsValid(targetDur)) {
        SpliceKit_log(@"[ReplaceAtPlayhead] geometry incomplete — skip trim");
        return result;
    }

    // Drag-drop: srcIn = effectiveSPH − (playheadTime − targetStart)
    // effectiveSPH = browser skimmer position (source-media coords for drag-drop type=1)
    SK_CMTime phOffset = SK_CMTimeSubtract(effectivePH, targetStart);
    SK_CMTime srcIn    = SK_CMTimeSubtract(effectiveSPH, phOffset);
    if (SK_CMTimeCompare(srcIn, (SK_CMTime){0, srcIn.timescale, 1, 0}) < 0)
        srcIn = (SK_CMTime){0, srcIn.timescale, 1, 0};

    SEL startSel2 = NSSelectorFromString(@"start");
    SK_CMTime placedOrgClipStart = [newClip respondsToSelector:startSel2]
        ? SpliceKit_readCMTime(newClip, startSel2) : SK_kCMTimeInvalid;
    SK_CMTime correctedStart = (SK_CMTimeIsValid(placedOrgClipStart) &&
                                SK_CMTimeGetSeconds(placedOrgClipStart) > 1.0)
        ? SK_CMTimeAdd(placedOrgClipStart, srcIn)
        : srcIn;

    SEL crSel = NSSelectorFromString(@"clippedRange");
    SK_CMTimeRange crBefore = { SK_kCMTimeInvalid, SK_kCMTimeInvalid };
    if ([newClip respondsToSelector:crSel])
        crBefore = SpliceKit_readCMTimeRange(newClip, crSel);
    SpliceKit_log(@"[ReplaceAtPlayhead] pre-correct: clippedRange={%.3fs,%.3fs} "
                  "placedOrgClipStart=%.3fs wantSrcIn=%.3fs correctedStart=%.3fs",
                  SK_CMTimeGetSeconds(crBefore.start), SK_CMTimeGetSeconds(crBefore.duration),
                  SK_CMTimeGetSeconds(placedOrgClipStart),
                  SK_CMTimeGetSeconds(srcIn), SK_CMTimeGetSeconds(correctedStart));

    SEL setRangeSel = NSSelectorFromString(@"setTimeRangeInAsset:");
    if (![newClip respondsToSelector:setRangeSel]) {
        SpliceKit_log(@"[ReplaceAtPlayhead] setTimeRangeInAsset: not found on %@",
                      NSStringFromClass(object_getClass(newClip)));
        return result;
    }

    SK_CMTimeRange newRange = { correctedStart, targetDur };
    NSMethodSignature *ms = [newClip methodSignatureForSelector:setRangeSel];
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:ms];
    inv.target   = newClip;
    inv.selector = setRangeSel;
    [inv setArgument:&newRange atIndex:2];
    [inv invoke];

    SK_CMTimeRange crAfter = { SK_kCMTimeInvalid, SK_kCMTimeInvalid };
    if ([newClip respondsToSelector:crSel])
        crAfter = SpliceKit_readCMTimeRange(newClip, crSel);
    SK_CMTime durAfter = SpliceKit_readCMTime(newClip, NSSelectorFromString(@"duration"));
    SpliceKit_log(@"[ReplaceAtPlayhead] post-correct: clippedRange={%.3fs,%.3fs} timelineDur=%.3fs "
                  "effectiveSrcIn=%.3fs",
                  SK_CMTimeGetSeconds(crAfter.start), SK_CMTimeGetSeconds(crAfter.duration),
                  SK_CMTimeGetSeconds(durAfter),
                  SK_CMTimeGetSeconds(SK_CMTimeSubtract(crAfter.start, placedOrgClipStart)));
    return result;
}

static void SpliceKit_actionDropMenuReplaceAtPlayhead(id self, SEL _cmd, id sender) {
    sOrigActionDropMenuReplaceAtPlayhead(self, _cmd, sender);
}

static void SpliceKit_injectReplaceAtPlayheadMenuItem(id module) {
    Ivar ivar = class_getInstanceVariable(object_getClass(module), "dropMenu");
    if (!ivar) return;
    id menu = object_getIvar(module, ivar);
    if (!menu) return;

    SEL rapSel    = NSSelectorFromString(@"actionDropMenuReplaceAtPlayhead:");
    SEL fromEndSel = NSSelectorFromString(@"actionDropMenuReplaceFromEnd:");

    // Guard: don't inject twice (check by title).
    if ([(NSMenu *)menu indexOfItemWithTitle:@"Replace at Playhead"] != -1) return;

    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:@"Replace at Playhead"
                                                  action:rapSel
                                           keyEquivalent:@""];
    NSInteger idx = [(NSMenu *)menu indexOfItemWithTarget:nil andAction:fromEndSel];
    if (idx == -1) idx = 2;
    [(NSMenu *)menu insertItem:item atIndex:idx + 1];

    SpliceKit_log(@"[ReplaceAtPlayhead] Injected 'Replace at Playhead' into dropMenu at index %ld",
                  (long)(idx + 1));
}

static id (*sOrigFFAtmInit)(id, SEL);

static id SpliceKit_FFAtmInit(id self, SEL _cmd) {
    id result = sOrigFFAtmInit(self, _cmd);
    if (result) SpliceKit_injectReplaceAtPlayheadMenuItem(result);
    return result;
}

// _startListeningToSequence: fires when a project is loaded into the timeline.
// Use it as the reliable post-init injection point for the already-live instance.
// (init swizzle handles future instances; this handles the startup case where
// the module was created before our init swizzle was installed.)
static void (*sOrigStartListeningToSequence)(id, SEL, id);

static void SpliceKit_startListeningToSequence(id self, SEL _cmd, id sequence) {
    sOrigStartListeningToSequence(self, _cmd, sequence);
    SpliceKit_injectReplaceAtPlayheadMenuItem(self);
}

// ---------------------------------------------------------------------------
// 2. Command Editor registration
// ---------------------------------------------------------------------------

static id sReplaceAtPlayheadCmd = nil;

// Creates the LKCommand, registers it with the controller, and binds the
// Option+Shift+R shortcut to the given command set. Safe to call multiple
// times — skips command creation after the first call.
static void SpliceKit_applyReplaceAtPlayheadCommand(id controller, id commandSet) {
    if (!sReplaceAtPlayheadCmd) {
        Class cmdClass = objc_getClass("LKCommand");
        if (!cmdClass) return;

        SEL initSel = NSSelectorFromString(@"initWithCommandIdentifier:action:");
        if (![cmdClass instancesRespondToSelector:initSel]) return;

        id cmd = ((id (*)(id, SEL, NSString *, SEL))objc_msgSend)(
            [cmdClass alloc], initSel,
            @"ReplaceWithSelectedMediaAtPlayhead",
            NSSelectorFromString(@"replaceWithSelectedMediaAtPlayhead:"));
        if (!cmd) return;

        SEL registerSel = NSSelectorFromString(@"registerCommand:");
        if ([controller respondsToSelector:registerSel])
            ((void (*)(id, SEL, id))objc_msgSend)(controller, registerSel, cmd);

        // Add to the same "Editing" group as Replace From Start / From End / Whole Clip
        // so the command appears in the Command Editor under the right category.
        SEL addToGroupSel = NSSelectorFromString(@"addCommandWithIdentifier:toGroupWithIdentifier:");
        if ([controller respondsToSelector:addToGroupSel])
            ((void (*)(id, SEL, NSString *, NSString *))objc_msgSend)(
                controller, addToGroupSel,
                @"ReplaceWithSelectedMediaAtPlayhead",
                @"Editing");

        sReplaceAtPlayheadCmd = cmd;
        SpliceKit_log(@"[ReplaceAtPlayhead] Registered LKCommand ReplaceWithSelectedMediaAtPlayhead");
    }

    if (!commandSet) return;

    // Option (NSAlternateKeyMask = 1<<19) | Shift (NSShiftKeyMask = 1<<17) = 0xA0000 = 655360
    SEL addSel = NSSelectorFromString(@"_addCommand:withCharacter:modifierMask:");
    if ([commandSet respondsToSelector:addSel]) {
        ((void (*)(id, SEL, id, unichar, NSUInteger))objc_msgSend)(
            commandSet, addSel,
            sReplaceAtPlayheadCmd,
            (unichar)'r',
            (NSUInteger)655360);
    }
}

// Forward declarations for the retain-attributes command (defined below).
static id sReplaceRetainingAttrCmd;
static void SpliceKit_applyReplaceRetainingAttributesCommand(id controller);

// Re-register on future _loadCommands calls (e.g. Command Editor reloads).
static void (*sOrigLoadCommands)(id, SEL);

static void SpliceKit_loadCommands(id self, SEL _cmd) {
    sOrigLoadCommands(self, _cmd);
    SEL activeSetSel = NSSelectorFromString(@"_activeCommandSet");
    id commandSet = ((id (*)(id, SEL))objc_msgSend)(self, activeSetSel);
    // Reset so both commands re-register after the reload.
    sReplaceAtPlayheadCmd = nil;
    SpliceKit_applyReplaceAtPlayheadCommand(self, commandSet);
    sReplaceRetainingAttrCmd = nil;
    SpliceKit_applyReplaceRetainingAttributesCommand(self);
}

// Re-bind the shortcut whenever a new command set becomes active.
static void (*sOrigSetActiveCommandSet)(id, SEL, id);

static void SpliceKit_setActiveCommandSet(id self, SEL _cmd, id commandSet) {
    sOrigSetActiveCommandSet(self, _cmd, commandSet);
    if (commandSet)
        SpliceKit_applyReplaceAtPlayheadCommand(self, commandSet);
}

// ---------------------------------------------------------------------------
// 2b. Replace and Retain Attributes command (⌥⇧⌘R)
// ---------------------------------------------------------------------------
// Replaces the timeline clip at the playhead with the browser selection while
// preserving all effects, color corrections, transforms, and audio attributes
// of the original clip.
//
// Strategy:
//   1. Select clip at playhead → copyAttributes: (writes to FCP effects clipboard)
//   2. replaceWithSelectedMediaAtPlayhead: (uses a private named pasteboard — no conflict)
//   3. selectClipAtPlayhead: → pasteEffects: (restores all attributes, no dialog)

static void SpliceKit_applyReplaceRetainingAttributesCommand(id controller) {
    if (sReplaceRetainingAttrCmd) return;

    Class cmdClass = objc_getClass("LKCommand");
    if (!cmdClass) return;
    SEL initSel = NSSelectorFromString(@"initWithCommandIdentifier:action:");
    if (![cmdClass instancesRespondToSelector:initSel]) return;

    id cmd = ((id (*)(id, SEL, NSString *, SEL))objc_msgSend)(
        [cmdClass alloc], initSel,
        @"SKReplaceRetainingAttributes",
        NSSelectorFromString(@"SKReplaceRetainingAttributesAction:"));
    if (!cmd) return;

    SEL registerSel = NSSelectorFromString(@"registerCommand:");
    if ([controller respondsToSelector:registerSel])
        ((void (*)(id, SEL, id))objc_msgSend)(controller, registerSel, cmd);

    SEL addToGroupSel = NSSelectorFromString(@"addCommandWithIdentifier:toGroupWithIdentifier:");
    if ([controller respondsToSelector:addToGroupSel])
        ((void (*)(id, SEL, NSString *, NSString *))objc_msgSend)(
            controller, addToGroupSel,
            @"SKReplaceRetainingAttributes", @"Editing");

    // Bind ⌥⇧⌘R
    SEL bindSel = NSSelectorFromString(@"bindCommandWithIdentifier:toKeyEquivalent:modifiers:");
    if ([controller respondsToSelector:bindSel]) {
        @try {
            ((void (*)(id, SEL, NSString *, NSString *, NSUInteger))objc_msgSend)(
                controller, bindSel,
                @"SKReplaceRetainingAttributes",
                @"r",
                NSEventModifierFlagOption | NSEventModifierFlagShift | NSEventModifierFlagCommand);
            SpliceKit_log(@"[ReplaceAtPlayhead] Bound ⌥⇧⌘R → SKReplaceRetainingAttributes");
        } @catch (NSException *e) {
            SpliceKit_log(@"[ReplaceAtPlayhead] ⌥⇧⌘R binding failed: %@", e);
        }
    }

    sReplaceRetainingAttrCmd = cmd;
    SpliceKit_log(@"[ReplaceAtPlayhead] Registered SKReplaceRetainingAttributes (⌥⇧⌘R)");
}

// Adds SKReplaceRetainingAttributesAction: to NSApplication so the LKCommand
// reaches our handler regardless of which view is first responder.
static void SpliceKit_installRetainAttributesActionHandler(void) {
    Class appClass = [NSApplication class];
    SEL actionSel = NSSelectorFromString(@"SKReplaceRetainingAttributesAction:");
    if ([appClass instancesRespondToSelector:actionSel]) return;

    IMP impl = imp_implementationWithBlock(^(id __unused appSelf, id sender) {
        id app = [NSApplication sharedApplication];

        // Get the timeline module directly — the user's focus is on the browser
        // (they just selected a clip there), so sendAction:to:nil would route copy:
        // and pasteEffects: to the browser instead of the timeline.
        id tm = SpliceKit_getActiveTimelineModule();
        if (!tm) {
            SpliceKit_log(@"[ReplaceAtPlayhead] RetainAttrs: no timeline module");
            return;
        }

        // Step 1: Select the timeline clip at the playhead, then copy it directly
        // to the timeline module. copy: populates FCP's clip clipboard which
        // pasteEffects: reads from.
        SEL selectSel = NSSelectorFromString(@"selectClipAtPlayhead:");
        if ([tm respondsToSelector:selectSel])
            ((void(*)(id,SEL,id))objc_msgSend)(tm, selectSel, nil);

        if ([tm respondsToSelector:@selector(copy:)]) {
            ((void(*)(id,SEL,id))objc_msgSend)(tm, @selector(copy:), nil);
            SpliceKit_log(@"[ReplaceAtPlayhead] RetainAttrs: copied timeline clip");
        } else {
            SpliceKit_log(@"[ReplaceAtPlayhead] RetainAttrs: timeline module has no copy: — aborting");
            return;
        }

        // Step 2: Replace clip with browser selection at playhead.
        // Routes to our SpliceKit_replaceWithSelectedMediaAtPlayhead swizzle,
        // which writes to a private named pasteboard, leaving copy:'s data intact.
        [app sendAction:NSSelectorFromString(@"replaceWithSelectedMediaAtPlayhead:") to:nil from:nil];

        // Step 3: Select the new clip and paste all effects (no dialog).
        // Deferred one runloop cycle so the timeline model fully settles after replace.
        dispatch_async(dispatch_get_main_queue(), ^{
            id tm2 = SpliceKit_getActiveTimelineModule();
            if (!tm2) return;
            SEL selSel = NSSelectorFromString(@"selectClipAtPlayhead:");
            if ([tm2 respondsToSelector:selSel])
                ((void(*)(id,SEL,id))objc_msgSend)(tm2, selSel, nil);
            // "Paste Effects" (Edit > Paste Effects, ⌘⌥V) fires pasteAllAttributes:,
            // not pasteEffects: — confirmed via dry_run on the menu item.
            SEL pasteSel = NSSelectorFromString(@"pasteAllAttributes:");
            if ([tm2 respondsToSelector:pasteSel]) {
                ((void(*)(id,SEL,id))objc_msgSend)(tm2, pasteSel, nil);
                SpliceKit_log(@"[ReplaceAtPlayhead] Replace and Retain Attributes complete");
            } else {
                [app sendAction:pasteSel to:nil from:nil];
                SpliceKit_log(@"[ReplaceAtPlayhead] RetainAttrs: pasteAllAttributes: via sendAction (fallback)");
            }
        });
    });
    class_addMethod(appClass, actionSel, impl, "v@:@");
    SpliceKit_log(@"[ReplaceAtPlayhead] Installed SKReplaceRetainingAttributesAction: on NSApplication");
}

// ---------------------------------------------------------------------------
// 3. Keyboard shortcut path: FFEditActionMgr.replaceWithSelectedMediaAtPlayhead:
// ---------------------------------------------------------------------------
// ⌥⇧R → LKCommand "ReplaceWithSelectedMediaAtPlayhead" → responder chain →
// FFEditActionMgr.replaceWithSelectedMediaAtPlayhead: → our swizzle.
//
// FCP 12.2 broke the original (effectively deletes the clip). Fix strategy:
//
//   1. Read browserTime (source-media offset) and orgClipStart from selection:
//        activeEditSourceForToolBar → FFOrganizerFilmstripModule
//        selectedRangesOfMedia[0].start         = orgCursor (organizer-cumulative)
//        selectedRangesOfMedia[0]._object.start  = orgClipStart (organizer-cumulative)
//        browserTime = orgCursor − orgClipStart  = source-media offset  ✓
//
//   2. Serialize browser selection to named pasteboard via
//      PEAppController.writeDataForEditAction:toPasteboardWithName: with
//      replaceType=2 ("Replace From Start") FFEditAction.
//
//   3. Walk containedItems to find the target clip's timeline start and duration.
//
//   4. Select the clip at the playhead.
//
//   5. Call performEditAction:fromPasteboardWithName:fromAnimation: with the
//      Replace From Start action.  FCP replaces the clip.
//      After this, FCP has called setClippedRange:{orgCursor, targetDur} on the
//      new clip (organizer coords: srcIn = orgCursor − orgClipStart = browserTime).
//
//   6. Find the new clip at targetStart. Apply alignment by calling setClippedRange:
//      DIRECTLY with organizer coords:
//        orgDesiredStart = orgClipStart + desiredSrcIn
//                        = orgClipStart + (browserTime − (PH − targetStart))
//        setClippedRange:{orgDesiredStart, targetDur}
//        → srcIn = orgDesiredStart − orgClipStart = desiredSrcIn  ✓
//
// WHY setClippedRange and not setTimeRangeInAsset:
//   Replace-From-Start clips retain their browser orgClipStart (e.g. 40401.127s).
//   setTimeRangeInAsset: calls setClippedRange: with raw source-media coords
//   (e.g. start=51.67), but setClippedRange: interprets start in organizer
//   coords → srcIn = 51.67 − 40401.127 = −40349s → negative → clip deleted.
//   Drag-drop (Replace at Playhead) clips have orgClipStart=0, so
//   setTimeRangeInAsset: works there. For this keyboard path we must pass
//   organizer coords: orgClipStart + desiredSrcIn.

static void (*sOrigReplaceWithSelectedMediaAtPlayhead)(id, SEL, id);

static void SpliceKit_replaceWithSelectedMediaAtPlayhead(id self, SEL _cmd, id sender) {
    id delegate = [[NSApplication sharedApplication] delegate];

    // ── Step 1: Capture browser state ────────────────────────────────────────
    // filmstrip and clipObj are hoisted so we can seek them in step 3.
    SK_CMTime browserTime   = SK_kCMTimeInvalid;
    SK_CMTime orgClipStart  = SK_kCMTimeInvalid;
    SK_CMTime orgCursor     = SK_kCMTimeInvalid;   // updated after seek; used for guard check
    SK_CMTime sourceClipDur = SK_kCMTimeInvalid;
    id filmstrip = nil;
    id clipObj   = nil;
    {
        SEL editSrcSel       = NSSelectorFromString(@"activeEditSourceForToolBar");
        SEL rangesSel        = NSSelectorFromString(@"selectedRangesOfMedia");
        SEL startSel         = NSSelectorFromString(@"start");
        SEL curSeqTimeSel    = NSSelectorFromString(@"currentSequenceTime");
        filmstrip = [delegate respondsToSelector:editSrcSel]
            ? ((id (*)(id, SEL))objc_msgSend)(delegate, editSrcSel) : nil;
        NSArray *ranges = (filmstrip && [filmstrip respondsToSelector:rangesSel])
            ? ((NSArray *(*)(id, SEL))objc_msgSend)(filmstrip, rangesSel) : nil;
        id rangeObj = ranges.count > 0 ? ranges.firstObject : nil;
        // currentSequenceTime = organizer-cumulative skimmer/cursor position (NOT clip start).
        // rangeObj.start is the clip's start in organizer coords (= orgClipStart), not the cursor.
        if (filmstrip && [filmstrip respondsToSelector:curSeqTimeSel])
            orgCursor = SpliceKit_readCMTime(filmstrip, curSeqTimeSel);
        if (rangeObj) {
            Ivar objIvar = class_getInstanceVariable(object_getClass(rangeObj), "_object");
            clipObj = objIvar ? object_getIvar(rangeObj, objIvar) : nil;
            orgClipStart = (clipObj && [clipObj respondsToSelector:startSel])
                ? SpliceKit_readCMTime(clipObj, startSel) : SK_kCMTimeInvalid;
            // clippedRange = {orgClipStart, sourceClipDur} in organizer-cumulative coords.
            SEL crSel = NSSelectorFromString(@"clippedRange");
            if (clipObj && [clipObj respondsToSelector:crSel]) {
                SK_CMTimeRange cr = SpliceKit_readCMTimeRange(clipObj, crSel);
                sourceClipDur = cr.duration;
            }
            if (SK_CMTimeIsValid(orgCursor) && SK_CMTimeIsValid(orgClipStart))
                browserTime = SK_CMTimeSubtract(orgCursor, orgClipStart);
            else
                browserTime = orgCursor;
            SpliceKit_log(@"[ReplaceAtPlayhead-KB] browserTime=%.3fs orgClipStart=%.3fs(v=%d) "
                          "sourceClipDur=%.3fs(v=%d)",
                          SK_CMTimeGetSeconds(browserTime),
                          SK_CMTimeGetSeconds(orgClipStart), SK_CMTimeIsValid(orgClipStart),
                          SK_CMTimeGetSeconds(sourceClipDur), SK_CMTimeIsValid(sourceClipDur));
        }
    }
    if (!SK_CMTimeIsValid(browserTime)) {
        SpliceKit_log(@"[ReplaceAtPlayhead-KB] no browser selection — fallback");
        sOrigReplaceWithSelectedMediaAtPlayhead(self, _cmd, sender);
        return;
    }

    // ── Step 2: Gather target clip geometry ──────────────────────────────────
    // Done BEFORE writing to the pasteboard so we can compute desiredSrcIn first.
    id module = ((id (*)(id, SEL))objc_msgSend)(delegate, NSSelectorFromString(@"timelineModule"));
    if (!module) {
        SpliceKit_log(@"[ReplaceAtPlayhead-KB] no timelineModule — fallback");
        sOrigReplaceWithSelectedMediaAtPlayhead(self, _cmd, sender);
        return;
    }
    SK_CMTime ph   = SpliceKit_readCMTime(module, NSSelectorFromString(@"playheadTime"));
    id sequence    = ((id (*)(id, SEL))objc_msgSend)(module, NSSelectorFromString(@"sequence"));
    id primary     = sequence
        ? ((id (*)(id, SEL))objc_msgSend)(sequence, NSSelectorFromString(@"primaryObject")) : nil;
    SEL containedSel = NSSelectorFromString(@"containedItems");
    SEL durSel       = NSSelectorFromString(@"duration");

    SK_CMTime targetStart = SK_kCMTimeInvalid;
    SK_CMTime targetDur   = SK_kCMTimeInvalid;
    id originalClip = nil;   // pointer to clip at playhead BEFORE replace (for guard)
    if (SK_CMTimeIsValid(ph) && primary && [primary respondsToSelector:containedSel]) {
        NSArray *clips = ((NSArray *(*)(id, SEL))objc_msgSend)(primary, containedSel);
        SK_CMTime cursor = {0, 90000, 1, 0};
        for (id item in clips) {
            SK_CMTime d = SpliceKit_readCMTime(item, durSel);
            if (!SK_CMTimeIsValid(d)) continue;
            SK_CMTime end = SK_CMTimeAdd(cursor, d);
            if (SK_CMTimeCompare(cursor, ph) <= 0 && SK_CMTimeCompare(ph, end) < 0) {
                targetStart = cursor; targetDur = d; originalClip = item; break;
            }
            cursor = end;
        }
    }

    SpliceKit_log(@"[ReplaceAtPlayhead-KB] PH=%.3fs BT=%.3fs T1=%.3fs dur=%.3fs",
                  SK_CMTimeGetSeconds(ph), SK_CMTimeGetSeconds(browserTime),
                  SK_CMTimeGetSeconds(targetStart), SK_CMTimeGetSeconds(targetDur));

    // ── Step 3: Compute desiredSrcIn ─────────────────────────────────────────
    // "Replace at Playhead": the browser cursor frame appears AT the timeline
    // playhead position. srcIn = browserTime − (PH − T1), so that at position
    // PH the source shows frame browserTime (= what was under the browser cursor).
    SK_CMTime desiredSrcIn   = browserTime;    // fallback: keep original cursor
    SK_CMTime orgDesiredStart = orgCursor;     // fallback: keep original cursor
    if (SK_CMTimeIsValid(ph) && SK_CMTimeIsValid(targetStart) &&
        SK_CMTimeIsValid(targetDur) && SK_CMTimeIsValid(orgClipStart)) {
        SK_CMTime phOffset = SK_CMTimeSubtract(ph, targetStart);
        SK_CMTime raw = SK_CMTimeSubtract(browserTime, phOffset);
        if (SK_CMTimeCompare(raw, (SK_CMTime){0, raw.timescale, 1, 0}) < 0)
            raw = (SK_CMTime){0, raw.timescale, 1, 0};
        desiredSrcIn   = raw;
        orgDesiredStart = SK_CMTimeAdd(orgClipStart, desiredSrcIn);

        // Pre-flight: abort if there's not enough source media.
        // desiredSrcIn is the actual source in-point we'll apply; if desiredSrcIn + targetDur
        // exceeds the source clip's total duration, the replace would produce a black or
        // truncated clip.  Abort here so the original clip stays intact.
        if (SK_CMTimeIsValid(sourceClipDur)) {
            SK_CMTime needed = SK_CMTimeAdd(desiredSrcIn, targetDur);
            if (SK_CMTimeCompare(needed, sourceClipDur) > 0) {
                SpliceKit_log(@"[ReplaceAtPlayhead-KB] not enough source media: "
                              "desiredSrcIn=%.3fs + dur=%.3fs = %.3fs > sourceClipDur=%.3fs — aborted",
                              SK_CMTimeGetSeconds(desiredSrcIn),
                              SK_CMTimeGetSeconds(targetDur),
                              SK_CMTimeGetSeconds(needed),
                              SK_CMTimeGetSeconds(sourceClipDur));
                return;
            }
        }
    }

    // ── Step 4: Serialize browser selection to named pasteboard ──────────────
    // Use Replace at Playhead (type=1) — NOT Replace From Start (type=2).
    // Type=2 places a 0-duration stub that FCP extends AFTER operationReplaceItem: returns,
    // conflicting with our in-operation srcIn correction.  Type=1 places the clip with
    // targetDur from the start, so our setTimeRangeInAsset: only adjusts srcIn.
    Class eaClass = objc_getClass("FFEditAction");
    id fromStartAction = ((id (*)(id, SEL, int))objc_msgSend)(
        eaClass, NSSelectorFromString(@"editActionOfReplaceType:"), 1);
    SEL canSel = NSSelectorFromString(@"canSourceDataForEditAction:");
    if (!((BOOL (*)(id, SEL, id))objc_msgSend)(delegate, canSel, fromStartAction)) {
        SpliceKit_log(@"[ReplaceAtPlayhead-KB] canSourceData=NO — fallback");
        sOrigReplaceWithSelectedMediaAtPlayhead(self, _cmd, sender);
        return;
    }
    NSString *pbName = @"com.apple.splicekit.replaceAtPlayhead";
    SEL writeSel = NSSelectorFromString(@"writeDataForEditAction:toPasteboardWithName:");
    if (!((BOOL (*)(id, SEL, id, id))objc_msgSend)(delegate, writeSel, fromStartAction, pbName)) {
        SpliceKit_log(@"[ReplaceAtPlayhead-KB] writeDataForEditAction failed — fallback");
        sOrigReplaceWithSelectedMediaAtPlayhead(self, _cmd, sender);
        return;
    }

    // ── Step 5: Arm keyboard-path statics for operationReplaceItem: swizzle ─────
    // Set geometry statics and raise sKBReplaceInFlight BEFORE performEditAction: fires.
    // If the operation routes through operationReplaceItem:withItems:, the swizzle
    // picks up these values and calls setTimeRangeInAsset: from inside the operation
    // (the only safe place for orgClipStart≈0 clips — calling it from outside moves the clip).
    // After performEditAction: returns, if sKBReplaceInFlight was cleared, the swizzle
    // handled it and we skip the post-correction block below.
    if (SK_CMTimeIsValid(targetStart) && SK_CMTimeIsValid(targetDur)) {
        sKBTargetClipStart  = targetStart;
        sKBTargetClipDur    = targetDur;
        sKBDesiredSrcIn     = desiredSrcIn;
        sKBOrgDesiredStart  = orgDesiredStart;
        sKBReplaceInFlight  = YES;
    }

    // ── Step 5.5: Arm _deferredDropTargetItem so FCP places with targetDur ──────
    // FCP reads _deferredDropTargetItem.duration to determine the replacement clip's
    // duration in replaceWithPasteboard:replaceActionType:.  For keyboard path,
    // _deferredDropTargetItem is nil — FCP falls back to the pasteboard clip's extent
    // which is 0 (cursor, no range selection) → places a 1-frame stub.
    // Temporarily set _deferredDropTargetItem = originalClip so FCP uses targetDur.
    Ivar deferredIvar = class_getInstanceVariable(object_getClass(module), "_deferredDropTargetItem");
    id prevDeferred = nil;
    if (deferredIvar && originalClip) {
        prevDeferred = object_getIvar(module, deferredIvar);
        object_setIvar(module, deferredIvar, originalClip);
        SpliceKit_log(@"[ReplaceAtPlayhead-KB] armed _deferredDropTargetItem dur=%.3fs",
                      SK_CMTimeGetSeconds(targetDur));
    }

    // ── Step 6: Select the clip at the playhead ───────────────────────────────
    SEL selectSel = NSSelectorFromString(@"selectClipAtPlayhead:");
    if ([module respondsToSelector:selectSel])
        ((void (*)(id, SEL, id))objc_msgSend)(module, selectSel, nil);

    // ── Step 7: Replace at Playhead via named pasteboard ─────────────────────
    SEL performSel = NSSelectorFromString(@"performEditAction:fromPasteboardWithName:fromAnimation:");
    ((void (*)(id, SEL, id, id, BOOL))objc_msgSend)(
        module, performSel, fromStartAction, pbName, NO);

    // Restore _deferredDropTargetItem to avoid affecting subsequent operations.
    if (deferredIvar) {
        object_setIvar(module, deferredIvar, prevDeferred);
    }

    // ── Step 8: Verify in-operation correction persisted ─────────────────────
    // After performEditAction: fully returns, check the clip at targetStart to confirm
    // that FCP's own post-processing didn't overwrite/discard our correction.
    if (!sKBReplaceInFlight) {
        // operationReplaceItem: fired — walk containedItems to see what FCP committed.
        id verifyClip = nil;
        if (primary && [primary respondsToSelector:containedSel]) {
            NSArray *clips = ((NSArray *(*)(id, SEL))objc_msgSend)(primary, containedSel);
            SK_CMTime cursor = {0, 90000, 1, 0};
            for (id item in clips) {
                if (SK_CMTimeCompare(cursor, targetStart) == 0) { verifyClip = item; break; }
                SK_CMTime d = SpliceKit_readCMTime(item, durSel);
                if (SK_CMTimeIsValid(d)) cursor = SK_CMTimeAdd(cursor, d);
            }
        }
        SEL crSel2 = NSSelectorFromString(@"clippedRange");
        if (verifyClip) {
            SK_CMTimeRange cr = SpliceKit_readCMTimeRange(verifyClip, crSel2);
            SK_CMTime tDur = SpliceKit_readCMTime(verifyClip, durSel);
            SpliceKit_log(@"[ReplaceAtPlayhead-KB] post-perform: "
                          "clippedRange={%.3fs,%.3fs} timelineDur=%.3fs class=%@ ptr=%p",
                          SK_CMTimeGetSeconds(cr.start), SK_CMTimeGetSeconds(cr.duration),
                          SK_CMTimeGetSeconds(tDur),
                          NSStringFromClass(object_getClass(verifyClip)),
                          (__bridge void *)verifyClip);
        } else {
            SpliceKit_log(@"[ReplaceAtPlayhead-KB] post-perform: clip at T1=%.3fs GONE from timeline",
                          SK_CMTimeGetSeconds(targetStart));
        }
        return;
    }
    // operationReplaceItem: did NOT fire.
    sKBReplaceInFlight = NO;
    SpliceKit_log(@"[ReplaceAtPlayhead-KB] operationReplaceItem: did not fire — using post-correction");

    // ── Step 9: Post-correction (fallback) ────────────────────────────────────
    if (!SK_CMTimeIsValid(ph) || !SK_CMTimeIsValid(targetStart) ||
        !SK_CMTimeIsValid(targetDur) || !SK_CMTimeIsValid(orgClipStart)) {
        SpliceKit_log(@"[ReplaceAtPlayhead-KB] geometry incomplete — skip correction");
        return;
    }

    id newClip = nil;
    if (primary && [primary respondsToSelector:containedSel]) {
        NSArray *clips = ((NSArray *(*)(id, SEL))objc_msgSend)(primary, containedSel);
        SK_CMTime cursor = {0, 90000, 1, 0};
        for (id item in clips) {
            if (SK_CMTimeCompare(cursor, targetStart) == 0) { newClip = item; break; }
            SK_CMTime d = SpliceKit_readCMTime(item, durSel);
            if (SK_CMTimeIsValid(d)) cursor = SK_CMTimeAdd(cursor, d);
        }
    }
    // ── Guard: verify Replace From Start actually fired ──────────────────────────
    // Use ObjC pointer identity: compare the clip at targetStart after the replace
    // with originalClip captured before.
    //   newClip == originalClip → replace didn't fire (FCP aborted, e.g. not enough media)
    //   newClip == nil          → slot is empty (severe failure) → auto-undo
    //   newClip != originalClip → replace fired → proceed with correction
    if (!newClip || newClip == originalClip) {
        if (!newClip) {
            SpliceKit_log(@"[ReplaceAtPlayhead-KB] clip at targetStart gone after replace — auto-undo");
            SEL undoSel = NSSelectorFromString(@"actionUndo:");
            if ([module respondsToSelector:undoSel])
                ((void (*)(id, SEL, id))objc_msgSend)(module, undoSel, nil);
            else
                SpliceKit_log(@"[ReplaceAtPlayhead-KB] actionUndo: not found — clip lost");
        } else {
            SpliceKit_log(@"[ReplaceAtPlayhead-KB] replace didn't fire (same clip pointer) — original intact");
        }
        return;
    }

    // Apply alignment: set the desired source in-point on the placed clip.
    // IMPORTANT: we preserve the placed clip's ACTUAL duration (from clippedRange)
    // to avoid inadvertently trimming/extending the clip and causing a timeline ripple.
    //
    // Two paths depending on orgClipStart:
    //   orgClipStart≈0  → use setTimeRangeInAsset:{desiredSrcIn, placedDur}
    //                      (raw source coords; same as drag-drop path)
    //                      setClippedRange: with small start values physically MOVES
    //                      the clip's timeline position for these clips.
    //   orgClipStart large → use setClippedRange:{orgClipStart+desiredSrcIn, placedDur}
    //                         (organizer-cumulative coords)
    //                         setTimeRangeInAsset: would compute negative srcIn here.

    // Read the placed clip's actual clippedRange duration before touching it.
    SK_CMTime placedDur = targetDur;   // fallback
    {
        SEL crReadSel = NSSelectorFromString(@"clippedRange");
        if ([newClip respondsToSelector:crReadSel]) {
            SK_CMTimeRange cr = SpliceKit_readCMTimeRange(newClip, crReadSel);
            if (SK_CMTimeIsValid(cr.duration))
                placedDur = cr.duration;
        }
    }

    if (SK_CMTimeGetSeconds(orgClipStart) < 1.0) {
        // orgClipStart≈0: setTimeRangeInAsset: with raw source coords (same as drag-drop path).
        SEL setTRSel = NSSelectorFromString(@"setTimeRangeInAsset:");
        if (![newClip respondsToSelector:setTRSel]) {
            SpliceKit_log(@"[ReplaceAtPlayhead-KB] %@ has no setTimeRangeInAsset: — skip",
                          NSStringFromClass(object_getClass(newClip)));
            return;
        }
        SK_CMTimeRange srcRange = { desiredSrcIn, placedDur };
        NSMethodSignature *ms = [newClip methodSignatureForSelector:setTRSel];
        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:ms];
        inv.target = newClip; inv.selector = setTRSel;
        [inv setArgument:&srcRange atIndex:2];
        [inv invoke];
    } else {
        // large orgClipStart: setClippedRange: with organizer-cumulative coords.
        SEL setCRSel = NSSelectorFromString(@"setClippedRange:");
        if (![newClip respondsToSelector:setCRSel]) {
            SpliceKit_log(@"[ReplaceAtPlayhead-KB] %@ has no setClippedRange: — skip",
                          NSStringFromClass(object_getClass(newClip)));
            return;
        }
        SK_CMTimeRange clippedRange = { orgDesiredStart, placedDur };
        NSMethodSignature *ms = [newClip methodSignatureForSelector:setCRSel];
        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:ms];
        inv.target = newClip; inv.selector = setCRSel;
        [inv setArgument:&clippedRange atIndex:2];
        [inv invoke];
    }

    SpliceKit_log(@"[ReplaceAtPlayhead-KB] done (post-correction/%@) — "
                  "BT=%.3fs desiredSrcIn=%.3fs orgClipStart=%.3fs",
                  SK_CMTimeGetSeconds(orgClipStart) < 1.0 ? @"setTR" : @"setCR",
                  SK_CMTimeGetSeconds(browserTime),
                  SK_CMTimeGetSeconds(desiredSrcIn),
                  SK_CMTimeGetSeconds(orgClipStart));
}

// ---------------------------------------------------------------------------
// Install
// ---------------------------------------------------------------------------

void SpliceKit_installReplaceAtPlayhead(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // --- Drag-drop menu injection ---
        // Swizzle FFAnchoredTimelineModule.init so every new instance gets the item.
        Class atmClass = objc_getClass("FFAnchoredTimelineModule");
        if (atmClass) {
            SEL rapSel = NSSelectorFromString(@"actionDropMenuReplaceAtPlayhead:");
            sOrigActionDropMenuReplaceAtPlayhead =
                (void (*)(id, SEL, id))SpliceKit_swizzleMethod(atmClass, rapSel,
                    (IMP)SpliceKit_actionDropMenuReplaceAtPlayhead);
            SpliceKit_log(sOrigActionDropMenuReplaceAtPlayhead
                ? @"[ReplaceAtPlayhead] Swizzled actionDropMenuReplaceAtPlayhead: (playhead alignment)"
                : @"[ReplaceAtPlayhead] actionDropMenuReplaceAtPlayhead: swizzle failed");

            sOrigFFAtmInit = (id (*)(id, SEL))SpliceKit_swizzleMethod(atmClass,
                @selector(init), (IMP)SpliceKit_FFAtmInit);
            SpliceKit_log(sOrigFFAtmInit
                ? @"[ReplaceAtPlayhead] Swizzled FFAnchoredTimelineModule.init"
                : @"[ReplaceAtPlayhead] FFAnchoredTimelineModule.init swizzle failed");

            // _startListeningToSequence: fires each time a project is loaded into the
            // timeline — the reliable post-startup hook for injecting into the live instance.
            SEL listenSel = NSSelectorFromString(@"_startListeningToSequence:");
            sOrigStartListeningToSequence =
                (void (*)(id, SEL, id))SpliceKit_swizzleMethod(atmClass, listenSel,
                    (IMP)SpliceKit_startListeningToSequence);
            SpliceKit_log(sOrigStartListeningToSequence
                ? @"[ReplaceAtPlayhead] Swizzled FFAnchoredTimelineModule._startListeningToSequence:"
                : @"[ReplaceAtPlayhead] _startListeningToSequence: swizzle failed");

            // replaceWithPasteboard:replaceActionType: fires during drag-drop just before
            // the structural replace.  Captures target clip geometry (start + dur) from
            // _deferredDropTargetItem for use in operationReplaceItem:withItems:.
            SEL replacePBSel = NSSelectorFromString(@"replaceWithPasteboard:replaceActionType:");
            sOrigReplaceWithPasteboard =
                (void (*)(id, SEL, id, int))SpliceKit_swizzleMethod(
                    atmClass, replacePBSel, (IMP)SpliceKit_replaceWithPasteboard);
            SpliceKit_log(sOrigReplaceWithPasteboard
                ? @"[ReplaceAtPlayhead] Swizzled replaceWithPasteboard:replaceActionType:"
                : @"[ReplaceAtPlayhead] replaceWithPasteboard: swizzle failed");
        } else {
            SpliceKit_log(@"[ReplaceAtPlayhead] FFAnchoredTimelineModule not found");
        }

        // Intercept FFAnchoredSequence.operationReplaceItem:withItems: to apply the correct
        // source in-point from inside the operation context (safe for all clip types).
        Class seqClass = objc_getClass("FFAnchoredSequence");
        if (seqClass) {
            SEL seqReplaceSel = NSSelectorFromString(
                @"operationReplaceItem:withItems:replaceActionType:editsAdded:playheadTime:sourcePlayheadTime:autoCancelOnFail:");
            sOrigSeqOperationReplaceItem = (OrigSeqReplaceItemFn)SpliceKit_swizzleMethod(
                seqClass, seqReplaceSel, (IMP)SpliceKit_seqOperationReplaceItem);
            SpliceKit_log(sOrigSeqOperationReplaceItem
                ? @"[ReplaceAtPlayhead] Swizzled FFAnchoredSequence.operationReplaceItem:withItems:"
                : @"[ReplaceAtPlayhead] FFAnchoredSequence.operationReplaceItem: swizzle failed");
        }

        // --- Keyboard shortcut path: FFEditActionMgr ---
        Class editActionMgrClass = objc_getClass("FFEditActionMgr");
        if (editActionMgrClass) {
            SEL kbSel = NSSelectorFromString(@"replaceWithSelectedMediaAtPlayhead:");
            sOrigReplaceWithSelectedMediaAtPlayhead =
                (void (*)(id, SEL, id))SpliceKit_swizzleMethod(editActionMgrClass, kbSel,
                    (IMP)SpliceKit_replaceWithSelectedMediaAtPlayhead);
            SpliceKit_log(sOrigReplaceWithSelectedMediaAtPlayhead
                ? @"[ReplaceAtPlayhead] Swizzled FFEditActionMgr.replaceWithSelectedMediaAtPlayhead:"
                : @"[ReplaceAtPlayhead] FFEditActionMgr.replaceWithSelectedMediaAtPlayhead: swizzle failed");
        } else {
            SpliceKit_log(@"[ReplaceAtPlayhead] FFEditActionMgr not found");
        }

        // --- Command Editor ---
        Class lkcc = objc_getClass("LKCommandsController");
        if (lkcc) {
            SEL loadSel = NSSelectorFromString(@"_loadCommands");
            sOrigLoadCommands = (void (*)(id, SEL))SpliceKit_swizzleMethod(lkcc, loadSel,
                (IMP)SpliceKit_loadCommands);
            SpliceKit_log(sOrigLoadCommands
                ? @"[ReplaceAtPlayhead] Swizzled LKCommandsController._loadCommands"
                : @"[ReplaceAtPlayhead] _loadCommands swizzle failed");

            SEL activeSel = NSSelectorFromString(@"_setActiveCommandSet:");
            sOrigSetActiveCommandSet = (void (*)(id, SEL, id))SpliceKit_swizzleMethod(lkcc, activeSel,
                (IMP)SpliceKit_setActiveCommandSet);
            SpliceKit_log(sOrigSetActiveCommandSet
                ? @"[ReplaceAtPlayhead] Swizzled LKCommandsController._setActiveCommandSet:"
                : @"[ReplaceAtPlayhead] _setActiveCommandSet: swizzle failed");

            // _loadCommands already fired at startup — register directly now.
            SEL sharedSel = NSSelectorFromString(@"sharedController");
            if ([lkcc respondsToSelector:sharedSel]) {
                id controller = ((id (*)(id, SEL))objc_msgSend)((id)lkcc, sharedSel);
                if (controller) {
                    SEL activeSetSel = NSSelectorFromString(@"_activeCommandSet");
                    id commandSet = ((id (*)(id, SEL))objc_msgSend)(controller, activeSetSel);
                    SpliceKit_applyReplaceAtPlayheadCommand(controller, commandSet);
                    SpliceKit_applyReplaceRetainingAttributesCommand(controller);
                }
            }
        }

        // Install the action handler for SKReplaceRetainingAttributesAction: on NSApplication.
        SpliceKit_installRetainAttributesActionHandler();
    });
}
