#import "SpliceKitV4Media.h"
#include <math.h>

static CMTime SKMConvertTime(id object, NSString *selector, CMTime time, id container) {
    SKMRequire(SKMSignature(object, selector, @encode(CMTime), @[@(@encode(CMTime)), @"@"]),
        @"UNSUPPORTED_TIME_MAP", selector);
    return ((CMTime (*)(id, SEL, CMTime, id))SKM_STRET)(object, NSSelectorFromString(selector), time, container);
}

static NSDictionary *SKMRetimeSnapshot(id clip, id stack, NSArray *requestedSamples) {
    // UNVERIFIED: Native mapping semantics for nested trims, reverse and holds
    // still require FCPXML/native playback acceptance. ABI is statically checked.
    SKMRequire(SKMSignature(clip, @"clippedRange", @encode(CMTimeRange), @[]) &&
        SKMSignature(stack, @"mediaTimeFromComponentTime:", @encode(CMTime), @[@(@encode(CMTime))]) &&
        SKMSignature(stack, @"constantRetimingRate", "d", @[]) &&
        SKMSignature(stack, @"retimingSegmentCount", "i", @[]),
        @"UNSUPPORTED_TIME_MAP", @"The target does not expose the verified native retime readback ABI.");
    CMTimeRange range = ((CMTimeRange (*)(id, SEL))SKM_STRET)(clip, NSSelectorFromString(@"clippedRange"));
    CMTime end = CMTimeRangeGetEnd(range);
    SKMTimeJSON(range.start); SKMTimeJSON(range.duration); SKMTimeJSON(end);
    SKMRequire(CMTimeCompare(range.duration, kCMTimeZero) > 0, @"INVALID_NATIVE_RANGE", @"Clip duration must be positive.");
    id root = SKMObject(SKMSequence(), @"primaryObject");
    SKMRequire(root != nil, @"UNSUPPORTED_TIME_MAP", @"The active sequence has no timeline container.");
    CMTime timelineStart = SKMConvertTime(clip, @"localToContainerTime:container:", range.start, root);
    CMTime timelineEnd = SKMConvertTime(clip, @"localToContainerTime:container:", end, root);
    NSArray *samples = requestedSamples;
    if (!samples.count) {
        CMTime mid = CMTimeAdd(range.start, CMTimeMultiplyByRatio(range.duration, 1, 2));
        samples = @[SKMTimeJSON(timelineStart),
            SKMTimeJSON(SKMConvertTime(clip, @"localToContainerTime:container:", mid, root)),
            SKMTimeJSON(timelineEnd)];
    }
    NSMutableArray *map = [NSMutableArray array];
    for (NSDictionary *sample in samples) {
        CMTime timelineTime;
        SKMRequire(SKMTime(sample, &timelineTime), @"INVALID_PARAMS", @"samples must contain rational timeline times.");
        SKMRequire(CMTimeCompare(timelineTime, timelineStart) >= 0 && CMTimeCompare(timelineTime, timelineEnd) <= 0,
            @"OUT_OF_RANGE", @"A requested sample is outside the clip's timeline range.");
        CMTime componentTime = SKMConvertTime(clip, @"containerToLocalTime:container:", timelineTime, root);
        CMTime sourceTime = ((CMTime (*)(id, SEL, CMTime))SKM_STRET)(stack,
            NSSelectorFromString(@"mediaTimeFromComponentTime:"), componentTime);
        [map addObject:@{@"timeline_time": SKMTimeJSON(timelineTime),
            @"component_time": SKMTimeJSON(componentTime), @"source_time": SKMTimeJSON(sourceTime)}];
    }
    double rate = ((double (*)(id, SEL))objc_msgSend)(stack, NSSelectorFromString(@"constantRetimingRate"));
    int count = ((int (*)(id, SEL))objc_msgSend)(stack, NSSelectorFromString(@"retimingSegmentCount"));
    SKMRequire(isfinite(rate) && count >= 0, @"INVALID_NATIVE_MAP", @"Invalid native rate or segment count.");
    return @{@"constant_rate": @(rate), @"segment_count": @(count),
        @"component_range": @{@"start": SKMTimeJSON(range.start), @"duration": SKMTimeJSON(range.duration)},
        @"timeline_range": @{@"start": SKMTimeJSON(timelineStart), @"end": SKMTimeJSON(timelineEnd)},
        @"source_timeline_map": map, @"map_kind": @"native_samples",
        @"inverse_policy": @"A sampled relation, not a unique inverse; holds and reverse can have multiple timeline matches.",
        @"curve_exported": @NO};
}

static void SKMRetimeValidateSamples(id samples) {
    SKMRequire(!samples || ([samples isKindOfClass:[NSArray class]] && [samples count] <= 256),
        @"INVALID_PARAMS", @"samples must be an array with at most 256 rational timeline times.");
    for (id sample in samples) {
        CMTime time;
        SKMRequire(SKMTime(sample, &time), @"INVALID_PARAMS", @"Invalid sample time.");
    }
}

void SpliceKitV4RegisterRetime(void) {
    SKMRegister(@"v4.retime.inspect", YES, ^NSDictionary *(NSDictionary *p, BOOL *attempted) {
        SKMRetimeValidateSamples(p[@"samples"]);
        id clip = SKMClip(p);
        return SKMResult(p, YES, @NO, SKMRetimeSnapshot(clip, SKMStack(clip, NO), p[@"samples"]), nil, nil);
    });
    SKMRegister(@"v4.retime.set", NO, ^NSDictionary *(NSDictionary *p, BOOL *attempted) {
        NSString *mode = p[@"mode"];
        SKMRequire([@[@"constant", @"reverse", @"freeze", @"ramp"] containsObject:mode],
            @"UNSUPPORTED_RETIME_MODE", @"Supported modes are constant, reverse (one toggle), freeze and ramp (to/from zero). Arbitrary piecewise curves are not calibrated.");
        SKMRequire(!p[@"points"] && !p[@"segments"], @"UNSUPPORTED_CURVE", @"Arbitrary retime keys and falloff units are not calibrated.");
        id clip = SKMClip(p), stack = SKMStack(clip, NO), sequence = SKMSequence();
        NSDictionary *before = SKMRetimeSnapshot(clip, stack, nil);
        NSError *error = nil;
        BOOL nativeOK = NO;
        id handler = SKMObject(SKMObject(sequence,@"modelDocument"),@"undoHandler");
        SKMRequire(SKMSignature(handler,@"actionLevel", "Q", @[]) &&
            SKMSignature(handler,@"undoableEnd:save:error:", "B", @[@"@",@"B",@"^@"]),
            @"UNSUPPORTED_UNDO", @"The owning native retime action scope is unavailable");
        NSUInteger initialLevel = ((NSUInteger (*)(id,SEL))objc_msgSend)(handler,NSSelectorFromString(@"actionLevel"));
        @try {
        if ([mode isEqualToString:@"constant"]) {
            SKMRequire(SKMNumber(p[@"rate"]) && [p[@"rate"] doubleValue] > 0,
                @"INVALID_PARAMS", @"rate must be finite and positive; reverse is an explicit operation.");
            SKMRequire(SKMBool(p[@"ripple"]),
                @"INVALID_PARAMS", @"ripple must be an explicit boolean.");
            NSString *selector = @"actionRetimeSetRatePreset:rate:ripple:allowVariableSpeedRetiming:objectsAndNewRanges:error:";
            SKMRequire(SKMSignature(sequence, selector, "B", @[@"@", @"d", @"B", @"B", @"^@", @"^@"]),
                @"UNSUPPORTED_ABI", selector);
            *attempted = YES;
            nativeOK = ((BOOL (*)(id, SEL, id, double, BOOL, BOOL, id *, NSError **))objc_msgSend)(sequence,
                NSSelectorFromString(selector), @[clip], [p[@"rate"] doubleValue], [p[@"ripple"] boolValue], NO, NULL, &error);
        } else if ([mode isEqualToString:@"reverse"]) {
            NSString *selector = @"actionRetimeReverseClipPreset:error:";
            SKMRequire(SKMSignature(sequence, selector, "B", @[@"@", @"^@"]), @"UNSUPPORTED_ABI", selector);
            *attempted = YES;
            nativeOK = ((BOOL (*)(id, SEL, id, NSError **))objc_msgSend)(sequence, NSSelectorFromString(selector), @[clip], &error);
        } else {
            CMTime start, duration;
            SKMRequire(SKMTime(p[@"component_time"], &start) && SKMTime(p[@"duration"], &duration) &&
                CMTimeCompare(duration, kCMTimeZero) > 0, @"INVALID_PARAMS", @"component_time and a positive rational duration are required.");
            CMTime rangeStart, rangeDuration;
            SKMTime(before[@"component_range"][@"start"], &rangeStart);
            SKMTime(before[@"component_range"][@"duration"], &rangeDuration);
            SKMRequire(CMTimeCompare(start, rangeStart) >= 0 && CMTimeCompare(start, CMTimeAdd(rangeStart, rangeDuration)) < 0,
                @"OUT_OF_RANGE", @"component_time must be within the clip's component range.");
            if ([mode isEqualToString:@"freeze"]) {
                NSString *selector = @"actionRetimeHoldPreset:holdComponentTime:duration:newHoldComponentTime:error:";
                SKMRequire(SKMSignature(sequence, selector, "B", @[@"@", @(@encode(CMTime)), @(@encode(CMTime)), @"^{?=qiIq}", @"^@"]),
                    @"UNSUPPORTED_ABI", selector);
                CMTime newHold = kCMTimeInvalid;
                *attempted = YES;
                nativeOK = ((BOOL (*)(id, SEL, id, CMTime, CMTime, CMTime *, NSError **))objc_msgSend)(sequence,
                    NSSelectorFromString(selector), @[clip], start, duration, &newHold, &error);
            } else {
                NSString *direction = p[@"direction"];
                SKMRequire([@[@"to_zero", @"from_zero"] containsObject:direction], @"INVALID_PARAMS", @"ramp requires to_zero or from_zero direction.");
                CMTime end = CMTimeAdd(start, duration);
                SKMRequire(CMTimeCompare(end, CMTimeAdd(rangeStart, rangeDuration)) <= 0, @"OUT_OF_RANGE", @"Ramp extends beyond the clip.");
                NSString *selector = @"actionRetimeSpeedRampPreset:startComponentTime:endComponentTime:toZero:fromZero:error:";
                SKMRequire(SKMSignature(sequence, selector, "B", @[@"@", @(@encode(CMTime)), @(@encode(CMTime)), @"B", @"B", @"^@"]),
                    @"UNSUPPORTED_ABI", selector);
                *attempted = YES;
                nativeOK = ((BOOL (*)(id, SEL, id, CMTime, CMTime, BOOL, BOOL, NSError **))objc_msgSend)(sequence,
                    NSSelectorFromString(selector), @[clip], start, end, [direction isEqualToString:@"to_zero"],
                    [direction isEqualToString:@"from_zero"], &error);
            }
        }
        } @finally {
            // FCP 12.4 preset actions open one FFUndoHandler scope and expect
            // their caller to commit it. Complete only that measured scope;
            // the v4 core still owns and closes its outer NSUndoManager group.
            NSUInteger level = ((NSUInteger (*)(id,SEL))objc_msgSend)(handler,NSSelectorFromString(@"actionLevel"));
            if (level == initialLevel + 1) {
                NSError *closeError = nil;
                BOOL closed = ((BOOL (*)(id,SEL,id,BOOL,NSError **))objc_msgSend)(handler,
                    NSSelectorFromString(@"undoableEnd:save:error:"),nil,YES,&closeError);
                SKMRequire(closed && !closeError,@"NATIVE_SAVE_FAILED",closeError.localizedDescription ?: @"Native retime action could not be closed");
            }
            SKMRequire(((NSUInteger (*)(id,SEL))objc_msgSend)(handler,NSSelectorFromString(@"actionLevel"))==initialLevel,
                @"UNBALANCED_RETIME_SCOPE",@"Unexpected native retime action depth; reconcile without retry");
        }
        NSDictionary *after = SKMRetimeSnapshot(clip, stack, nil);
        SKMRequire(nativeOK && !error, @"NATIVE_RETIME_FAILED", error.localizedDescription ?: @"Native retime returned false; reconcile before retrying.");
        if ([mode isEqualToString:@"constant"]) SKMRequire(fabs([after[@"constant_rate"] doubleValue] - [p[@"rate"] doubleValue]) < 1e-8,
            @"READBACK_MISMATCH", @"The stored native rate differs from the requested rate.");
        BOOL changed = ![before isEqual:after];
        SKMRequire(changed || [mode isEqualToString:@"constant"], @"READBACK_UNCONFIRMED", @"Native samples did not establish a retime change.");
        return SKMResult(p, YES, @(changed), @{@"before": before, @"after": after, @"mode": mode}, nil, nil);
    });
}
