#import "SpliceKitV4Media.h"
#include <math.h>

static CMTime SKMAudioTime(id clip, NSDictionary *value) {
    CMTime time;
    SKMRequire([value isKindOfClass:[NSDictionary class]] && SKMTime(value, &time), @"INVALID_PARAMS", @"An explicit rational parameter time is required.");
    NSString *space = value[@"space"];
    SKMRequire([@[@"clip_local", @"timeline"] containsObject:space ?: @""], @"INVALID_PARAMS", @"time.space must be clip_local or timeline.");
    if ([space isEqualToString:@"timeline"]) {
        SKMRequire(SKMSignature(clip, @"containerToLocalTime:container:", @encode(CMTime), @[@(@encode(CMTime)), @"@"]),
            @"UNSUPPORTED_TIME_MAP", @"No verified timeline-to-component conversion.");
        id root = SKMObject(SKMSequence(), @"primaryObject");
        SKMRequire(root != nil, @"UNSUPPORTED_TIME_MAP", @"No active timeline root.");
        time = ((CMTime (*)(id, SEL, CMTime, id))SKM_STRET)(clip,
            NSSelectorFromString(@"containerToLocalTime:container:"), time, root);
    }
    SKMTimeJSON(time);
    return time;
}

static double SKMAudioGain(id channel, CMTime time) {
    SKMRequire(SKMSignature(channel, @"curveDoubleValueAtTime:", "d", @[@(@encode(CMTime))]),
        @"UNSUPPORTED_GAIN", @"The volume channel has no verified double read ABI.");
    double value = ((double (*)(id, SEL, CMTime))objc_msgSend)(channel,
        NSSelectorFromString(@"curveDoubleValueAtTime:"), time);
    SKMRequire(isfinite(value) && value >= 0, @"INVALID_NATIVE_GAIN", @"Native gain must be finite and nonnegative.");
    return value;
}

static NSDictionary *SKMAudioMap(id clip) {
    id map = SKMObject(clip, @"audioChannelMap");
    BOOL indexArray = [map isKindOfClass:NSArray.class];
    SKMRequire((indexArray && SKMSignature(clip, @"nativeAudioChannelCount:", "I", @[@"i"])) ||
        (SKMSignature(map, @"channelCount", "I", @[]) &&
        SKMSignature(map, @"isChannelEnabled:", "B", @[@"I"])), @"UNSUPPORTED_CHANNEL_MAP", @"No verified native channel map.");
    NSNumber *metadataCount = indexArray ? SKMObject(clip, @"metadataAudioChannelCount") : nil;
    unsigned int count = indexArray && SKMNumber(metadataCount) ? metadataCount.unsignedIntValue : indexArray ? ((unsigned int (*)(id, SEL, int))objc_msgSend)(clip,
        NSSelectorFromString(@"nativeAudioChannelCount:"), 0) :
        ((unsigned int (*)(id, SEL))objc_msgSend)(map, NSSelectorFromString(@"channelCount"));
    SKMRequire(count > 0 && count <= 256, @"UNSUPPORTED_CHANNEL_MAP", @"Native channel count is outside 1..256.");
    if (indexArray) for (id value in map)
        SKMRequire(SKMNumber(value) && [value unsignedIntValue] < count &&
            [value doubleValue] == [value unsignedIntValue], @"UNSUPPORTED_CHANNEL_MAP", @"Unexpected native source-channel index.");
    if (indexArray) {
        NSArray *ordered = [map sortedArrayUsingSelector:@selector(compare:)];
        SKMRequire([map isEqual:ordered] && [NSSet setWithArray:map].count == [map count],
            @"UNSUPPORTED_ROUTING", @"Reordered or duplicated source-channel maps are not calibrated.");
    }
    NSMutableArray *channels = [NSMutableArray array];
    for (unsigned int i = 0; i < count; i++) {
        BOOL enabled = indexArray ? [map containsObject:@(i)] :
            ((BOOL (*)(id, SEL, unsigned int))objc_msgSend)(map, NSSelectorFromString(@"isChannelEnabled:"), i);
        [channels addObject:@{@"source_channel_index": @(i), @"enabled": @(enabled)}];
    }
    return @{@"target_role_uid": SKMIdentity(clip, @"audioRoleIdentifier") ?: NSNull.null,
        @"channel_count": @(count), @"index_base": @0, @"channels": channels,
        @"routing_and_stereo_group_edits_supported": @NO};
}

static NSDictionary *SKMAudioControls(void) {
    NSMutableDictionary *controls = [@{@"threshold": @[@"double"], @"ratio": @[@"double"],
        @"attack": @[@"double"], @"release": @[@"double"], @"knee": @[@"double"],
        @"makeup_gain": @[@"double"]} mutableCopy];
    for (NSUInteger band = 1; band <= 8; band++) {
        for (NSString *field in @[@"frequency", @"gain", @"q"])
            controls[[NSString stringWithFormat:@"band.%lu.%@", (unsigned long)band, field]] = @[@"double"];
        controls[[NSString stringWithFormat:@"band.%lu.enabled", (unsigned long)band]] = @[@"bool"];
        controls[[NSString stringWithFormat:@"band.%lu.type", (unsigned long)band]] = @[@"enum"];
    }
    return controls;
}

static id SKMFindRole(NSString *uid) {
    id libraries = SKMObject((id)NSClassFromString(@"FFLibraryDocument"), @"copyActiveLibraries");
    SKMRequire([libraries isKindOfClass:[NSArray class]], @"UNSUPPORTED_ROLE", @"No active library role catalog.");
    NSMutableArray *matches = [NSMutableArray array];
    for (id library in libraries) {
        if (!SKMSignature(library, @"findRoleWithUID:", "@", @[@"@"])) continue;
        id role = ((id (*)(id, SEL, id))objc_msgSend)(library, NSSelectorFromString(@"findRoleWithUID:"), uid);
        if (role) [matches addObject:role];
    }
    SKMRequire(matches.count == 1, @"AMBIGUOUS_ROLE", @"The role UID must resolve in exactly one open library. Do not choose a role by display name.");
    return matches.firstObject;
}

void SpliceKitV4RegisterAudio(void) {
    SKMRegister(@"v4.audio.inspect", YES, ^NSDictionary *(NSDictionary *p, BOOL *attempted) {
        id clip = SKMClip(p), stack = SKMStack(clip, YES), channel = SKMObject(stack, @"audioLevelChannel");
        CMTime time = SKMAudioTime(clip, p[@"time"]);
        double linear = SKMAudioGain(channel, time);
        SKMRequire(SKMSignature(channel, @"hasKeyframeAtTime:", "B", @[@(@encode(CMTime))]) &&
            SKMSignature(channel, @"keyframeCount", "Q", @[]), @"UNSUPPORTED_GAIN", @"Native keyframe readback unavailable.");
        BOOL key = ((BOOL (*)(id, SEL, CMTime))objc_msgSend)(channel, NSSelectorFromString(@"hasKeyframeAtTime:"), time);
        NSUInteger count = ((NSUInteger (*)(id, SEL))objc_msgSend)(channel, NSSelectorFromString(@"keyframeCount"));
        id utilities = (id)NSClassFromString(@"FFAudioFadeUtilities");
        SKMRequire(SKMSignature(utilities, @"audioFadeInDurationForItem:", @encode(CMTime), @[@"@"]) &&
            SKMSignature(utilities, @"audioFadeOutDurationForItem:", @encode(CMTime), @[@"@"]),
            @"UNSUPPORTED_FADE", @"Independent audio observation requires native fade-duration getters.");
        CMTime fadeIn = ((CMTime (*)(id, SEL, id))SKM_STRET)(utilities, NSSelectorFromString(@"audioFadeInDurationForItem:"), clip);
        CMTime fadeOut = ((CMTime (*)(id, SEL, id))SKM_STRET)(utilities, NSSelectorFromString(@"audioFadeOutDurationForItem:"), clip);
        return SKMResult(p, YES, @NO, @{@"target": p[@"target"], @"time": p[@"time"],
            @"resolved_time": SKMTimeJSON(time), @"gain_linear": @(linear), @"gain_db": linear > 0 ? @(20 * log10(linear)) : NSNull.null,
            @"fade_in": SKMTimeJSON(fadeIn), @"fade_out": SKMTimeJSON(fadeOut),
            @"fade_in_seconds": @(CMTimeGetSeconds(fadeIn)), @"fade_out_seconds": @(CMTimeGetSeconds(fadeOut)),
            @"has_keyframe": @(key), @"keyframe_count": @(count), @"channel_map": SKMAudioMap(clip)}, nil, nil);
    });
    SKMRegister(@"v4.audio.set_gain", NO, ^NSDictionary *(NSDictionary *p, BOOL *attempted) {
        SKMRequire(SKMNumber(p[@"gain_db"]) && [p[@"gain_db"] doubleValue] >= -120 && [p[@"gain_db"] doubleValue] <= 36,
            @"INVALID_PARAMS", @"gain_db must be finite in the API range -120..36 dB.");
        SKMRequire([@[@"constant", @"keyframe"] containsObject:p[@"mode"] ?: @""], @"INVALID_PARAMS", @"mode must explicitly be constant or keyframe.");
        id clip = SKMClip(p), stack = SKMStack(clip, YES), channel = SKMObject(stack, @"audioLevelChannel");
        CMTime time = SKMAudioTime(clip, p[@"time"]);
        SKMRequire(SKMSignature(channel, @"keyframeCount", "Q", @[]) &&
            SKMSignature(channel, @"setCurveDoubleValue:atTime:options:", "v", @[@"d", @(@encode(CMTime)), @"I"]) &&
            SKMSignature(channel, @"hasKeyframeAtTime:", "B", @[@(@encode(CMTime))]) &&
            SKMSignature(channel, @"operationBegin", "v", @[]) && SKMSignature(channel, @"operationEnd", "v", @[]) &&
            SKMSignature(stack, @"storeForUndo", "@", @[]), @"UNSUPPORTED_GAIN", @"Missing native gain/keyframe/undo ABI.");
        BOOL keyframe = [p[@"mode"] isEqualToString:@"keyframe"];
        NSUInteger count = ((NSUInteger (*)(id, SEL))objc_msgSend)(channel, NSSelectorFromString(@"keyframeCount"));
        SKMRequire(keyframe || count == 0, @"ANIMATED_PARAMETER", @"A constant write cannot erase existing gain keyframes.");
        double before = SKMAudioGain(channel, time), linear = pow(10.0, [p[@"gain_db"] doubleValue] / 20.0);
        *attempted = YES;
        SKMEdit(stack, @"Set audio gain", ^{
            (void)SKMObject(stack, @"storeForUndo");
            ((void (*)(id, SEL))objc_msgSend)(channel, NSSelectorFromString(@"operationBegin"));
            @try {
                ((void (*)(id, SEL, double, CMTime, unsigned int))objc_msgSend)(channel,
                    NSSelectorFromString(@"setCurveDoubleValue:atTime:options:"), linear, keyframe ? time : kCMTimeIndefinite, keyframe ? 1 : 0);
            } @finally {
                ((void (*)(id, SEL))objc_msgSend)(channel, NSSelectorFromString(@"operationEnd"));
            }
        });
        double after = SKMAudioGain(channel, time);
        BOOL hasKey = ((BOOL (*)(id, SEL, CMTime))objc_msgSend)(channel, NSSelectorFromString(@"hasKeyframeAtTime:"), time);
        BOOL verified = fabs(after - linear) <= MAX(1e-9, linear * 1e-6) && (!keyframe || hasKey);
        return SKMResult(p, verified, @YES, @{@"target": p[@"target"], @"audio_identifier": @0,
            @"time": p[@"time"], @"resolved_time": SKMTimeJSON(time), @"before_linear": @(before),
            @"gain_linear": @(after), @"gain_db": after > 0 ? @(20 * log10(after)) : NSNull.null,
            @"has_keyframe": @(hasKey), @"verified": @(verified)}, verified ? nil : @"READBACK_MISMATCH",
            verified ? nil : @"Stored gain/keyframe differs from the requested value.");
    });
    SKMRegister(@"v4.audio.fade", NO, ^NSDictionary *(NSDictionary *p, BOOL *attempted) {
        SKMRequire([@[@"in", @"out"] containsObject:p[@"edge"] ?: @""], @"INVALID_PARAMS", @"edge must be in or out.");
        CMTime duration;
        SKMRequire(SKMTime(p[@"duration"], &duration) && CMTimeCompare(duration, kCMTimeZero) >= 0,
            @"INVALID_PARAMS", @"duration must be a nonnegative rational time; zero removes the fade.");
        SKMRequire(!p[@"curve"] || [p[@"curve"] isEqual:@"native_default"], @"UNSUPPORTED_FADE_CURVE", @"Native fade-type enum labels are not calibrated.");
        id clip = SKMClip(p), stack = SKMStack(clip, YES), utilities = (id)NSClassFromString(@"FFAudioFadeUtilities");
        NSString *setter = [p[@"edge"] isEqual:@"in"] ? @"setAudioFadeInWithDuration:forItem:" : @"setAudioFadeOutWithDuration:forItem:";
        NSString *getter = [p[@"edge"] isEqual:@"in"] ? @"audioFadeInDurationForItem:" : @"audioFadeOutDurationForItem:";
        SKMRequire(SKMSignature(utilities, setter, "v", @[@"f", @"@"]) &&
            SKMSignature(utilities, getter, @encode(CMTime), @[@"@"]) && SKMSignature(stack, @"storeForUndo", "@", @[]),
            @"UNSUPPORTED_FADE", @"Native fade setter/getter/undo ABI is unavailable.");
        float seconds = (float)CMTimeGetSeconds(duration);
        SKMRequire(isfinite(seconds), @"INVALID_PARAMS", @"Fade duration exceeds the native float range.");
        *attempted = YES;
        SKMEdit(stack, @"Set audio fade", ^{
            (void)SKMObject(stack, @"storeForUndo");
            ((void (*)(id, SEL, float, id))objc_msgSend)(utilities, NSSelectorFromString(setter), seconds, clip);
        });
        CMTime after = ((CMTime (*)(id, SEL, id))SKM_STRET)(utilities, NSSelectorFromString(getter), clip);
        NSDictionary *readback = @{@"target": p[@"target"], @"edge": p[@"edge"], @"duration": SKMTimeJSON(after),
            @"curve": @"native_default", @"requested_duration": p[@"duration"]};
        BOOL verified = fabs(CMTimeGetSeconds(after) - CMTimeGetSeconds(duration)) <= 1e-5;
        return SKMResult(p, verified, @YES, readback, verified ? nil : @"READBACK_MISMATCH", verified ? nil : @"Native fade duration differs from the request.");
    });
    SKMRegister(@"v4.audio.effect.add", NO, ^NSDictionary *(NSDictionary *p, BOOL *attempted) {
        NSString *effectID = p[@"effect_id"];
        id registry = (id)NSClassFromString(@"FFEffect");
        SKMRequire(SKMString(effectID) && SKMSignature(registry, @"effectTypeForEffectID:", "@", @[@"@"]), @"INVALID_PARAMS", @"A full native audio effect_id is required.");
        id type = ((id (*)(id, SEL, id))objc_msgSend)(registry, NSSelectorFromString(@"effectTypeForEffectID:"), effectID);
        SKMRequire([type isEqual:@"effect.audio.effect"], @"WRONG_EFFECT_TYPE", @"The exact effect ID is not registered as an audio effect.");
        *attempted = YES;
        return SKMCall(@"v4.effect.add", @{@"target": p[@"target"] ?: @{}, @"effect_id": effectID});
    });
    SKMRegister(@"v4.audio.effect.configure", NO, ^NSDictionary *(NSDictionary *p, BOOL *attempted) {
        // Band numbers are logical names bound to discovered native paths. They
        // never imply an AU parameter ID, Hz/Q/dB unit, or an enum ordinal.
        return SKMApplyParameterRequests(p, SKMNamedParameterRequests(p, SKMAudioControls()), attempted);
    });
    SKMRegister(@"v4.audio.apply_preset", NO, ^NSDictionary *(NSDictionary *p, BOOL *attempted) {
        SKMRequire(SKMNumber(p[@"factory_preset_id"]) && trunc([p[@"factory_preset_id"] doubleValue]) == [p[@"factory_preset_id"] doubleValue] &&
            [p[@"factory_preset_id"] longLongValue] >= INT32_MIN && [p[@"factory_preset_id"] longLongValue] <= INT32_MAX,
            @"INVALID_PARAMS", @"factory_preset_id must be a known native signed 32-bit preset ID.");
        id clip = SKMClip(p), stack = SKMStack(clip, NO), effect = SKMEffect(stack, p[@"target"]);
        SKMRequire(SKMSignature(effect, @"setFactoryPreset:", "v", @[@"i"]) &&
            SKMSignature(effect, @"presetID", "i", @[]) && SKMSignature(effect, @"storeForUndo", "@", @[]),
            @"UNSUPPORTED_PRESET", @"Only verified native AU factory presets are supported; file presets and inferred ordinal IDs are not.");
        int before = ((int (*)(id, SEL))objc_msgSend)(effect, NSSelectorFromString(@"presetID"));
        *attempted = YES;
        SKMEdit(stack, @"Apply audio factory preset", ^{
            (void)SKMObject(effect, @"storeForUndo");
            ((void (*)(id, SEL, int))objc_msgSend)(effect, NSSelectorFromString(@"setFactoryPreset:"), [p[@"factory_preset_id"] intValue]);
        });
        int after = ((int (*)(id, SEL))objc_msgSend)(effect, NSSelectorFromString(@"presetID"));
        BOOL verified = after == [p[@"factory_preset_id"] intValue];
        return SKMResult(p, verified, @YES, @{@"target": p[@"target"], @"before_preset_id": @(before), @"factory_preset_id": @(after),
            @"parameter_side_effects": @"A preset can replace the entire AU parameter state. Reinspect before further edits."},
            verified ? nil : @"READBACK_MISMATCH", verified ? nil : @"The native AU did not retain the requested factory preset.");
    });
    SKMRegister(@"v4.audio.get_channel_map", YES, ^NSDictionary *(NSDictionary *p, BOOL *attempted) {
        return SKMResult(p, YES, @NO, SKMAudioMap(SKMClip(p)), nil, nil);
    });
    SKMRegister(@"v4.audio.set_channel_map", NO, ^NSDictionary *(NSDictionary *p, BOOL *attempted) {
        id clip = SKMClip(p);
        NSDictionary *before = SKMAudioMap(clip);
        NSArray *enabled = p[@"enabled"];
        SKMRequire([enabled isKindOfClass:[NSArray class]] && enabled.count == [before[@"channel_count"] unsignedIntegerValue],
            @"INVALID_PARAMS", @"enabled must have one explicit boolean per existing source channel.");
        for (id value in enabled) SKMRequire(SKMBool(value), @"INVALID_PARAMS", @"Channel enable values must be booleans.");
        SKMRequire(!p[@"routing"] && !p[@"groups"], @"UNSUPPORTED_ROUTING", @"Routing and stereo group creation are not calibrated.");
        id map = SKMObject(clip, @"audioChannelMap");
        BOOL indexArray = [map isKindOfClass:NSArray.class];
        SKMRequire([map conformsToProtocol:@protocol(NSCopying)] &&
            (indexArray || SKMSignature(map, @"setEnabled:forChannel:", "v", @[@"B", @"I"])) &&
            SKMSignature(clip, @"setAudioChannelMap:", "v", @[@"@"]) && SKMSignature(clip, @"storeForUndo", "@", @[]),
            @"UNSUPPORTED_CHANNEL_MAP", @"Native map copy, setter or undo ABI unavailable.");
        *attempted = YES;
        SKMEdit(clip, @"Set audio channel enable map", ^{
            (void)SKMObject(clip, @"storeForUndo");
            // UNVERIFIED: Native copy depth and stereo-group preservation need
            // the live multichannel fixture. Snapshot before touching the copy.
            id copy;
            if (indexArray) {
                // FCP 12.4 returns source indices, e.g. stereo [0,1]. Keep
                // existing order; reject reordered/duplicated routing maps.
                NSMutableArray *indices = [NSMutableArray array];
                for (unsigned int i = 0; i < enabled.count; i++) if ([enabled[i] boolValue]) [indices addObject:@(i)];
                copy = indices;
            } else {
                copy = [map copy];
                SKMRequire(copy != map, @"UNSUPPORTED_CHANNEL_MAP", @"Native mutable map copy returned the original object.");
                for (unsigned int i = 0; i < enabled.count; i++) ((void (*)(id, SEL, BOOL, unsigned int))objc_msgSend)(copy,
                    NSSelectorFromString(@"setEnabled:forChannel:"), [enabled[i] boolValue], i);
            }
            ((void (*)(id, SEL, id))objc_msgSend)(clip, NSSelectorFromString(@"setAudioChannelMap:"), copy);
        });
        NSDictionary *after = SKMAudioMap(clip);
        BOOL verified = [[after[@"channels"] valueForKey:@"enabled"] isEqual:enabled];
        return SKMResult(p, verified, @YES, @{@"before": before, @"after": after}, verified ? nil : @"READBACK_MISMATCH",
            verified ? nil : @"Native channel enable map differs from the request.");
    });
    SKMRegister(@"v4.audio.set_role", NO, ^NSDictionary *(NSDictionary *p, BOOL *attempted) {
        SKMRequire(SKMString(p[@"role_uid"]), @"INVALID_PARAMS", @"Use an existing native role_uid, not a display name.");
        id clip = SKMClip(p), sequence = SKMSequence();
        NSString *before = SKMIdentity(clip, @"audioRoleIdentifier");
        SKMRequire(before != nil, @"UNSUPPORTED_ROLE", @"Clip has no identifiable current audio role.");
        id oldRole = SKMFindRole(before), role = SKMFindRole(p[@"role_uid"]);
        SKMRequire(SKMSignature(oldRole, @"roleType", "i", @[]) && SKMSignature(role, @"roleType", "i", @[]) &&
            ((int (*)(id, SEL))objc_msgSend)(oldRole, NSSelectorFromString(@"roleType")) ==
            ((int (*)(id, SEL))objc_msgSend)(role, NSSelectorFromString(@"roleType")),
            @"WRONG_ROLE_TYPE", @"The requested role must have the same native type as the clip's audio role.");
        NSString *selector = @"actionAddRole:toItems:error:";
        SKMRequire(SKMSignature(sequence, selector, "B", @[@"@", @"@", @"^@"]), @"UNSUPPORTED_ROLE", selector);
        NSError *error = nil;
        *attempted = YES;
        BOOL nativeOK = ((BOOL (*)(id, SEL, id, id, NSError **))objc_msgSend)(sequence, NSSelectorFromString(selector), role, @[clip], &error);
        NSString *after = SKMIdentity(clip, @"audioRoleIdentifier");
        BOOL verified = nativeOK && !error && [after isEqual:p[@"role_uid"]];
        return SKMResult(p, verified, @YES, @{@"target": p[@"target"], @"before_role_uid": before, @"role_uid": after ?: NSNull.null},
            verified ? nil : @"READBACK_MISMATCH", error.localizedDescription ?: (verified ? nil : @"Audio role was not retained."));
    });
    SKMRegister(@"v4.audio.ducking.plan", YES, ^NSDictionary *(NSDictionary *p, BOOL *attempted) {
        (void)SKMClip(p);
        SKMRequire([p[@"dialogue_targets"] isKindOfClass:[NSArray class]] && [p[@"dialogue_targets"] count] > 0 &&
            [p[@"dialogue_targets"] count] <= 64 && SKMNumber(p[@"duck_db"]) && [p[@"duck_db"] doubleValue] <= 0 &&
            [p[@"duck_db"] doubleValue] >= -120, @"INVALID_PARAMS", @"Provide dialogue_targets and duck_db in -120..0.");
        for (id target in p[@"dialogue_targets"]) (void)SKMClip(@{@"target": target});
        return SKMResult(p, YES, @NO, @{@"state": @"planned", @"ready": @NO, @"native_supported": NSNull.null,
            @"music_target": p[@"target"], @"dialogue_targets": p[@"dialogue_targets"], @"duck_db": p[@"duck_db"],
            @"required_inputs": @[@"revision-bound dialogue activity intervals", @"attack/release and overlap policy", @"music volume parameter and existing keyframes", @"native supportsAudioDucking(sequence) gate"],
            @"completion": @"Identify the task, prove native support or explicitly choose a keyframe fallback, preserve existing automation, read back every gain point, then listen to a native mix excerpt.",
            @"execution_supported": @NO}, nil, nil);
    });
}
