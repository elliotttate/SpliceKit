// Exact-cut transition operations, with explicit missing-handle policy.
#import "SpliceKitV4TitlesSupport.h"
#import <limits.h>

static BOOL SKTIsTransition(id object) {
    Class cls = objc_getClass("FFAnchoredTransition");
    return cls && [object isKindOfClass:cls];
}

static NSDictionary *SKTCut(id sequence, NSDictionary *params) {
    id cut = params[@"cut"];
    SKTRequire([cut isKindOfClass:[NSDictionary class]], @"INVALID_CUT", @"cut requires left_clip_id and right_clip_id.");
    id left = SKTFind(sequence, cut[@"left_clip_id"]), right = SKTFind(sequence, cut[@"right_clip_id"]);
    NSArray *items = SKTArray(SKTGet(SKTGet(sequence, @"primaryObject"), @"containedItems"));
    NSUInteger l = [items indexOfObjectIdenticalTo:left], r = [items indexOfObjectIdenticalTo:right];
    SKTRequire(l != NSNotFound && r != NSNotFound && l < r && r - l <= 2 &&
        !SKTIsTransition(left) && !SKTIsTransition(right), @"NOT_ADJACENT",
        @"Cut targets must be neighboring primary-storyline clips (optionally separated by one transition).");
    id transition = r - l == 2 ? items[l + 1] : nil;
    SKTRequire(!transition || SKTIsTransition(transition), @"NOT_ADJACENT", @"Another clip lies between the cut targets.");
    return @{@"left": left, @"right": right, @"transition": transition ?: (id)[NSNull null]};
}

static NSDictionary *SKTTransitionReadback(id sequence, id transition, NSDictionary *params) {
    NSMutableDictionary *result = [SKTObjectReadback(sequence, transition) mutableCopy];
    result[@"effectID"] = SKTGet(SKTGet(transition, @"videoTransition"), @"effectID") ?: (id)[NSNull null];
    result[@"cut"] = params[@"cut"];
    return result;
}

static CMTime SKTMediaHandle(id clip, BOOL outgoing, id sequence) {
    Class cls = objc_getClass("FFAnchoredMediaComponent");
    if (cls && ![clip isKindOfClass:cls]) {
        // Ordinary linked AV imports wrap one video component in a collection.
        // Do not guess handles for compound/multicam or retimed collections.
        NSArray *children = SKTArray(SKTGet(clip,@"containedItems"));
        id stack = SKTGet(clip,@"videoEffects");
        SEL rate = NSSelectorFromString(@"constantRetimingRate");
        SEL segments = NSSelectorFromString(@"retimingSegmentCount");
        SKTRequire(children.count==1 && [children[0] isKindOfClass:cls] &&
            [stack respondsToSelector:rate] && [stack respondsToSelector:segments] &&
            ((double (*)(id,SEL))objc_msgSend)(stack,rate)==1 &&
            ((int (*)(id,SEL))objc_msgSend)(stack,segments)==1,
            @"HANDLES_UNKNOWN", @"Only a single unretimed AV component establishes collection handles");
        clip=children[0];
    }
    SEL retimed = NSSelectorFromString(@"isRetimed");
    SKTRequire(cls && [clip isKindOfClass:cls] && [clip respondsToSelector:retimed] &&
        !((BOOL (*)(id, SEL))objc_msgSend)(clip, retimed), @"HANDLES_UNKNOWN",
        @"Handle preflight currently supports ordinary unretimed media clips only.");
    SEL sampleSelector = NSSelectorFromString(@"sampleDuration");
    SKTRequire([clip respondsToSelector:sampleSelector], @"HANDLES_UNKNOWN", @"Source sample duration is unavailable.");
    CMTime sample = ((CMTime (*)(id, SEL))SKT_STRET)(clip, sampleSelector);
    SKTRequire(CMTIME_IS_NUMERIC(sample) && CMTimeCompare(sample, SKTFrame(sequence)) == 0,
        @"HANDLES_UNKNOWN", @"Handle preflight requires matching source and sequence frame rates.");
    CMTimeRange available = SKTRange(clip, @"mediaRange"), visible = SKTRange(clip, @"clippedRange");
    // UNVERIFIED: mediaRange versus clippedRange availability must be checked against
    // native exports; mixed source rates and retimed cases are rejected above.
    CMTime handle = outgoing ? CMTimeSubtract(CMTimeRangeGetEnd(available), CMTimeRangeGetEnd(visible)) :
        CMTimeSubtract(visible.start, available.start);
    SKTRequire(CMTIME_IS_NUMERIC(handle) && CMTimeCompare(handle, kCMTimeZero) >= 0,
        @"HANDLES_UNKNOWN", @"Native source ranges do not establish available handles.");
    return handle;
}

static NSDictionary *SKTTransitionSet(NSDictionary *params) {
    return SKTRun(params, @"Set Transition", YES, ^NSDictionary *(SKTRequest *request) {
        id sequence = SKTSequence(); NSDictionary *cut = SKTCut(sequence, params);
        NSString *policy = params[@"handle_policy"];
        SKTRequire([@[@"fail", @"shorten", @"freeze"] containsObject:policy ?: @""],
            @"INVALID_POLICY", @"handle_policy must explicitly be fail, shorten or freeze.");
        CMTime requested = SKTParseTime(params[@"duration"], YES), frame = SKTFrame(sequence);
        SKTCheckFrame(requested, frame);
        CMTime duration = requested;
        CMTime leftHandle = SKTMediaHandle(cut[@"left"], YES, sequence), rightHandle = SKTMediaHandle(cut[@"right"], NO, sequence);
        CMTime required = CMTimeMultiplyByRatio(duration, 1, 2);
        // Centered transitions require an even number of frames; no implicit rounding.
        SKTCheckFrame(required, frame);
        BOOL insufficient = CMTimeCompare(leftHandle, required) < 0 || CMTimeCompare(rightHandle, required) < 0;
        if (insufficient && [policy isEqualToString:@"fail"]) SKTRequire(NO, @"INSUFFICIENT_HANDLES", @"Not enough source media on one or both sides of the cut.");
        if (insufficient && [policy isEqualToString:@"shorten"]) {
            CMTime limit = CMTimeMinimum(leftHandle, rightHandle);
            __int128 frames = ((__int128)limit.value * frame.timescale) / ((__int128)limit.timescale * frame.value);
            SKTRequire(frames >= 1 && frames <= INT_MAX / 2, @"INSUFFICIENT_HANDLES", @"No centered transition of at least two frames fits this cut.");
            duration = CMTimeMultiply(frame, (int32_t)frames * 2);
        }
        NSString *effectID = params[@"effectID"];
        Class effectClass = objc_getClass("FFEffect"); SEL type = NSSelectorFromString(@"effectTypeForEffectID:");
        SKTRequire([effectID isKindOfClass:[NSString class]] && effectID.length && [effectClass respondsToSelector:type],
            @"INVALID_EFFECT", @"An exact installed transition effectID is required.");
        SKTRequire([((id (*)(id, SEL, id))objc_msgSend)(effectClass, type, effectID) isEqual:@"effect.video.transition"],
            @"WRONG_EFFECT_TYPE", @"The effectID is unavailable or is not a video transition.");
        SEL dictionarySelector = NSSelectorFromString(@"_transitionTypeDictionaryForTransitionID:");
        SEL add = NSSelectorFromString(@"operationAddTransitionsToObjectsOnSpineObject:spineObjectsToAddTransition:before:after:spineTransitionClipsCreated:effects:transitionDuration:transitionOverlapType:reportErrors:error:");
        SKTRequire([sequence respondsToSelector:dictionarySelector] && [sequence respondsToSelector:add],
            @"UNSUPPORTED_SELECTOR", @"Explicit-duration native transition operations are unavailable.");
        id effects = ((id (*)(id, SEL, id))objc_msgSend)(sequence, dictionarySelector, effectID);
        SKTRequire([effects isKindOfClass:[NSDictionary class]], @"TRANSITION_TYPE_UNAVAILABLE", @"FCP could not resolve the transition's native effect dictionary.");
        CMTimeRange before = SKTRange(SKTGet(sequence, @"primaryObject"), @"clippedRange");
        SKTEdit(sequence, request, ^{
            NSError *error = nil; id created = nil;
            // UNVERIFIED: the direct operation's array/output semantics require the live
            // fixture. Selector and ABI are from FCP 12.4 binary metadata. Mode 2 is the
            // existing bridge's freeze-overlap path; reportErrors:NO avoids modal fallback.
            BOOL ok = ((BOOL (*)(id, SEL, id, id, BOOL, BOOL, id *, id, CMTime, int, BOOL, NSError **))objc_msgSend)(
                sequence, add, SKTGet(sequence, @"primaryObject"), @[cut[@"right"]], YES, NO,
                &created, effects, duration, [policy isEqualToString:@"freeze"] ? 2 : 0, NO, &error);
            SKTRequire(ok, @"TRANSITION_FAILED", error.localizedDescription ?: @"Native transition operation failed; reconcile before retrying.");
        });
        NSDictionary *afterCut = SKTCut(sequence, params);
        id transition = afterCut[@"transition"];
        SKTRequire(transition != [NSNull null], @"READBACK_MISMATCH", @"No transition exists at the requested cut after the operation.");
        request.applied = @YES;
        NSMutableDictionary *result = [SKTTransitionReadback(sequence, transition, params) mutableCopy];
        request.readback = result;
        CMTimeRange after = SKTRange(SKTGet(sequence, @"primaryObject"), @"clippedRange");
        SKTRequire(CMTimeCompare(before.start, after.start) == 0 && CMTimeCompare(before.duration, after.duration) == 0,
            @"TIMELINE_DURATION_CHANGED", @"The native operation changed project timing; reconcile and use the owned undo group.");
        SKTRequire([result[@"effectID"] isEqual:effectID] && CMTimeCompare(SKTParseTime(result[@"duration"], YES), duration) == 0,
            @"READBACK_MISMATCH", @"Native transition type or duration differs from the requested result.");
        result[@"handle_policy"] = policy; result[@"requested_duration"] = SKTTime(requested);
        result[@"available_handles"] = @{@"left_out": SKTTime(leftHandle), @"right_in": SKTTime(rightHandle)};
        result[@"shortened"] = @((BOOL)(CMTimeCompare(duration, requested) < 0));
        result[@"freeze_requested"] = @((BOOL)([policy isEqualToString:@"freeze"] && insufficient));
        if ([policy isEqualToString:@"freeze"] && insufficient)
            [request.warnings addObject:@"Native freeze-overlap mode was requested; rendered edge-frame behavior requires live verification."];
        return result;
    });
}

static NSDictionary *SKTTransitionRemove(NSDictionary *params) {
    return SKTRun(params, @"Remove Transition", YES, ^NSDictionary *(SKTRequest *request) {
        id sequence = SKTSequence(); NSDictionary *cut = SKTCut(sequence, params);
        id transition = cut[@"transition"];
        if (transition == [NSNull null]) return @{@"cut": params[@"cut"], @"removed": @NO};
        NSString *transitionID = SKTID(transition);
        if (params[@"transition_id"]) SKTRequire([transitionID isEqual:params[@"transition_id"]],
            @"STALE_TRANSITION", @"The transition at this cut differs from transition_id.");
        SEL remove = NSSelectorFromString(@"operationRemoveTransitionPreservingTime:coerceEdit:toTime:");
        SKTRequire([sequence respondsToSelector:remove], @"UNSUPPORTED_SELECTOR", @"Time-preserving native transition removal is unavailable.");
        CMTime cutTime = SKTEffectiveRange(sequence, cut[@"right"]).start;
        CMTimeRange before = SKTRange(SKTGet(sequence, @"primaryObject"), @"clippedRange");
        SKTEdit(sequence, request, ^{
            // UNVERIFIED: transition object / coerceEdit / cut-time semantics need live
            // validation. The selector and BOOL/object/BOOL/CMTime ABI are statically verified.
            BOOL ok = ((BOOL (*)(id, SEL, id, BOOL, CMTime))objc_msgSend)(sequence, remove, transition, NO, cutTime);
            SKTRequire(ok, @"REMOVE_FAILED", @"Native transition removal failed; inspect the cut before retrying.");
        });
        NSDictionary *afterCut = SKTCut(sequence, params);
        request.applied = @YES;
        SKTRequire(afterCut[@"transition"] == [NSNull null], @"READBACK_MISMATCH", @"The transition is still present at the cut.");
        CMTimeRange after = SKTRange(SKTGet(sequence, @"primaryObject"), @"clippedRange");
        SKTRequire(CMTimeCompare(before.start, after.start) == 0 && CMTimeCompare(before.duration, after.duration) == 0,
            @"TIMELINE_DURATION_CHANGED", @"Native transition removal changed project timing.");
        return @{@"cut": params[@"cut"], @"removed": @YES, @"transition_id": transitionID};
    });
}

__attribute__((constructor)) static void SKTInstallTransitions(void) {
    @autoreleasepool {
        SKTRegister(@"v4.transition.set", NO, ^NSDictionary *(NSDictionary *p) { return SKTTransitionSet(p); });
        SKTRegister(@"v4.transition.remove", NO, ^NSDictionary *(NSDictionary *p) { return SKTTransitionRemove(p); });
    }
}
