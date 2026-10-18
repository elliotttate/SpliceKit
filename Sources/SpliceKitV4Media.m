#import "SpliceKitV4Media.h"
#import "SpliceKitV4Core.h"
#import <AppKit/AppKit.h>
#include <math.h>

extern NSDictionary *SpliceKit_handleRequest(NSDictionary *request);

BOOL SKMString(id value) {
    return [value isKindOfClass:[NSString class]] && [value length] > 0;
}

BOOL SKMNumber(id value) {
    return [value isKindOfClass:[NSNumber class]] &&
        CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID() &&
        isfinite([value doubleValue]);
}

BOOL SKMBool(id value) {
    return value && [value isKindOfClass:[NSNumber class]] &&
        CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID();
}

void SKMRequire(BOOL condition, NSString *code, NSString *message) {
    if (!condition) @throw [NSException exceptionWithName:code reason:message userInfo:nil];
}

// Rational component-local times only. Never silently round seconds into frames.
BOOL SKMTime(id value, CMTime *time) {
    if (![value isKindOfClass:[NSDictionary class]] || !SKMNumber(value[@"value"]) ||
        !SKMNumber(value[@"timescale"])) return NO;
    double n = [value[@"value"] doubleValue], d = [value[@"timescale"] doubleValue];
    if (trunc(n) != n || trunc(d) != d || fabs(n) > 9007199254740991.0 ||
        d < 1 || d > INT32_MAX) return NO;
    *time = CMTimeMake([value[@"value"] longLongValue], [value[@"timescale"] intValue]);
    return YES;
}

NSDictionary *SKMTimeJSON(CMTime time) {
    SKMRequire(CMTIME_IS_NUMERIC(time) && time.epoch == 0, @"INVALID_NATIVE_TIME",
               @"FCP returned an invalid, indefinite, or nonzero-epoch time.");
    return @{@"value": @(time.value), @"timescale": @(time.timescale)};
}

static const char *SKMSkipQualifier(const char *type) {
    while (*type && strchr("rnNoORV", *type)) type++;
    return type;
}

static NSString *SKMCanonicalType(const char *type) {
    NSMutableString *result = [NSMutableString string];
    for (const char *p = SKMSkipQualifier(type); *p; p++) {
        if (*p == '{' || *p == '(') {
            [result appendFormat:@"%c", *p];
            // Strip aggregate tags at every nesting level. A native anonymous
            // CMTimeRange contains two anonymous CMTimes, not just one tag.
            while (p[1] && p[1] != '=' && p[1] != '}' && p[1] != ')') p++;
        } else if (*p == '"') {
            while (p[1] && p[1] != '"') p++;
            if (p[1]) p++;
        } else [result appendFormat:@"%c", *p];
    }
    return result;
}

static BOOL SKMTypeMatches(const char *actual, const char *expected) {
    return [SKMCanonicalType(actual) isEqualToString:SKMCanonicalType(expected)];
}

BOOL SKMSignature(id receiver, NSString *selector, const char *result, NSArray<NSString *> *args) {
    SEL sel = NSSelectorFromString(selector);
    if (!receiver || ![receiver respondsToSelector:sel]) return NO;
    NSMethodSignature *signature = [receiver methodSignatureForSelector:sel];
    if (!signature || signature.numberOfArguments != args.count + 2 ||
        !SKMTypeMatches(signature.methodReturnType, result)) return NO;
    for (NSUInteger i = 0; i < args.count; i++) {
        if (!SKMTypeMatches([signature getArgumentTypeAtIndex:i + 2], args[i].UTF8String)) return NO;
    }
    return YES;
}

id SKMObject(id receiver, NSString *selector) {
    if (!SKMSignature(receiver, selector, "@", @[])) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(receiver, NSSelectorFromString(selector));
}

id SKMSequence(void) {
    id sequence = SKMObject(SpliceKit_getActiveTimelineModule(), @"sequence");
    SKMRequire(sequence != nil, @"NO_SEQUENCE", @"Open an isolated test sequence first.");
    return sequence;
}

NSString *SKMIdentity(id receiver, NSString *selector) {
    id identity = SKMObject(receiver, selector);
    if ([identity isKindOfClass:[NSUUID class]]) return [identity UUIDString];
    return SKMString(identity) ? identity : nil;
}

static void SKMFindClips(id root, NSString *target, NSMutableArray *matches, NSHashTable *seen, NSUInteger depth, NSUInteger *budget) {
    if (!root || [seen containsObject:root]) return;
    SKMRequire(depth <= 64 && *budget > 0, @"DISCOVERY_LIMIT", @"The sequence exceeds the bounded media discovery budget.");
    (*budget)--;
    [seen addObject:root];
    if ([SKMIdentity(root, @"persistentID") isEqualToString:target]) [matches addObject:root];
    // Linked audio and connected clips live in anchoredItems (an NSSet in FCP
    // 12.4), not only containedItems. Resolve the exact persistentID in both.
    for (NSString *selector in @[@"containedItems", @"anchoredItems"]) {
        id items = SKMObject(root, selector);
        if ([items isKindOfClass:[NSSet class]]) items = [items allObjects];
        if (![items isKindOfClass:[NSArray class]]) continue;
        for (id child in items) SKMFindClips(child, target, matches, seen, depth + 1, budget);
    }
}

id SKMClip(NSDictionary *params) {
    NSDictionary *target = params[@"target"];
    SKMRequire([target isKindOfClass:[NSDictionary class]] && SKMString(target[@"clip_id"]),
        @"INVALID_PARAMS", @"target.clip_id must be a native persistentID; selection and handles are never a fallback.");
    id sequence = SKMSequence(), root = SKMObject(sequence, @"primaryObject") ?: sequence;
    NSUInteger budget = 20000;
    NSMutableArray *matches = [NSMutableArray array];
    SKMFindClips(root, target[@"clip_id"], matches,
        [NSHashTable hashTableWithOptions:NSPointerFunctionsObjectPointerPersonality], 0, &budget);
    SKMRequire(matches.count == 1, @"TARGET_MISMATCH", @"The native clip identity is missing or ambiguous in the active sequence.");
    id clip = matches.firstObject;
    SKMRequire(clip != root && clip != sequence, @"TARGET_MISMATCH", @"Target a clip rather than the sequence root.");
    return clip;
}

id SKMEffect(id stack, NSDictionary *target) {
    SKMRequire(SKMString(target[@"effect_instance_id"]), @"INVALID_PARAMS", @"An exact native effect_instance_id is required.");
    id effects = SKMObject(stack, @"effects");
    SKMRequire([effects isKindOfClass:[NSArray class]], @"UNSUPPORTED_TARGET", @"No native effect inventory.");
    NSMutableArray *matches = [NSMutableArray array];
    for (id effect in effects) if ([(SKMIdentity(effect, @"persistentID") ?: SKMIdentity(effect, @"fileUUID")) isEqualToString:target[@"effect_instance_id"]]) [matches addObject:effect];
    SKMRequire(matches.count == 1, @"TARGET_MISMATCH", @"Effect instance is missing or ambiguous in the exact clip stack.");
    return matches.firstObject;
}

id SKMStack(id clip, BOOL audio) {
    id stack = nil;
    // UNVERIFIED: Audio identifier 0 must be checked against the audible AV
    // component on trimmed/multichannel fixtures. Never fall back to video.
    if (audio && SKMSignature(clip, @"audioEffectsForIdentifier:", "@", @[@"Q"])) {
        stack = ((id (*)(id, SEL, unsigned long long))objc_msgSend)(clip,
            NSSelectorFromString(@"audioEffectsForIdentifier:"), 0ULL);
    }
    if (!audio) stack = SKMObject(clip, @"effectStack");
    if (!audio && !stack) stack = SKMObject(clip, @"videoEffects");
    SKMRequire(stack != nil, @"UNSUPPORTED_TARGET", audio ?
        @"The exact clip has no audio stack for identifier 0; component fallback is disabled." : @"The clip has no video effect stack.");
    return stack;
}

void SKMEdit(id owner, NSString *label, dispatch_block_t mutation) {
    SKMRequire(SKMSignature(owner, @"actionBegin:animationHint:deferUpdates:", "v", @[@"@", @"@", @"B"]) &&
        SKMSignature(owner, @"actionEnd:save:error:", "B", @[@"@", @"B", @"^@"]),
        @"UNSUPPORTED_UNDO", @"The native object does not provide the verified editing transaction ABI.");
    ((void (*)(id, SEL, id, id, BOOL))objc_msgSend)(owner,
        NSSelectorFromString(@"actionBegin:animationHint:deferUpdates:"), label, nil, YES);
    @try {
        mutation();
    } @finally {
        NSError *error = nil;
        BOOL saved = ((BOOL (*)(id, SEL, id, BOOL, NSError **))objc_msgSend)(owner,
            NSSelectorFromString(@"actionEnd:save:error:"), label, YES, &error);
        SKMRequire(saved && !error, @"NATIVE_SAVE_FAILED", error.localizedDescription ?: @"Native actionEnd failed; reconcile before retrying.");
    }
}

NSDictionary *SKMResult(NSDictionary *params, BOOL ok, NSNumber *applied,
                        NSDictionary *readback, NSString *code, NSString *message) {
    return SpliceKitV4Result(params[@"operation_id"] ?: NSUUID.UUID.UUIDString,
        ok, applied, readback, nil, nil, @"none", @"", @[],
        code ? @{@"code": code, @"message": message ?: code, @"retryable": @NO} : nil);
}

NSDictionary *SKMCall(NSString *method, NSDictionary *params) {
    NSDictionary *response = SpliceKit_handleRequest(@{@"method": method, @"params": params});
    SKMRequire([response[@"result"] isKindOfClass:[NSDictionary class]], @"DEPENDENCY_UNAVAILABLE",
        [NSString stringWithFormat:@"%@ failed: %@", method, response[@"error"] ?: @"invalid response"]);
    NSDictionary *result = response[@"result"];
    SKMRequire([result[@"ok"] boolValue] && (result[@"error"] == NSNull.null || !result[@"error"]),
        @"DEPENDENCY_FAILED", [NSString stringWithFormat:@"%@ failed: %@", method, result[@"error"] ?: @"invalid envelope"]);
    return result;
}

NSArray *SKMNamedParameterRequests(NSDictionary *params, NSDictionary *allowed) {
    NSDictionary *target = params[@"target"], *bindings = params[@"bindings"], *adjustments = params[@"adjustments"];
    SKMRequire([target isKindOfClass:[NSDictionary class]] && SKMString(target[@"effect_instance_id"]) &&
        [bindings isKindOfClass:[NSDictionary class]] && [adjustments isKindOfClass:[NSDictionary class]] &&
        adjustments.count > 0 && adjustments.count <= 64, @"INVALID_PARAMS",
        @"Provide an exact effect target, discovered parameter-path bindings, and 1..64 named typed adjustments.");
    CMTime time;
    SKMRequire(SKMTime(params[@"time"], &time) &&
        [@[@"clip_local", @"timeline"] containsObject:params[@"time"][@"space"] ?: @""],
        @"INVALID_PARAMS", @"An explicit rational v4.parameter time and space are required.");
    SKMRequire(!params[@"mode"] || [@[@"at_time", @"constant"] containsObject:params[@"mode"]],
        @"INVALID_PARAMS", @"mode must be at_time or constant.");
    NSMutableArray *requests = [NSMutableArray array];
    NSMutableSet *paths = [NSMutableSet set];
    for (NSString *name in [adjustments.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        SKMRequire(SKMString(name) && allowed[name], @"UNSUPPORTED_NAMED_PARAMETER", @"This named control is not implemented; custom curve buffers and inferred enum ordinals are unsupported.");
        NSDictionary *typed = adjustments[name];
        NSString *path = bindings[name];
        SKMRequire(SKMString(path) && [typed isKindOfClass:[NSDictionary class]] &&
            [allowed[name] containsObject:typed[@"type"] ?: @""], @"INVALID_PARAMS", @"Named control has no discovered binding or the wrong value type.");
        SKMRequire(![paths containsObject:path], @"DUPLICATE_PARAMETER", @"Two names may not address the same parameter in one operation.");
        [paths addObject:path];
        NSDictionary *address = @{@"target": target, @"parameter_path": path, @"time": params[@"time"]};
        NSDictionary *metadata = SKMCall(@"v4.parameter.describe", address)[@"readback"];
        SKMRequire([metadata isKindOfClass:[NSDictionary class]] && [metadata[@"writable"] boolValue] &&
            [metadata[@"type"] isEqualToString:typed[@"type"]], @"PARAMETER_TYPE_MISMATCH",
            @"The discovered native parameter is not writable with the requested type.");
        NSString *type = typed[@"type"];
        id value = typed[@"value"];
        if ([@[@"double", @"angle", @"int", @"enum"] containsObject:type]) {
            SKMRequire(SKMNumber(value), @"INVALID_PARAMS", @"Numeric parameter values must be finite numbers, not booleans.");
            if ([@[@"int", @"enum"] containsObject:type]) SKMRequire(trunc([value doubleValue]) == [value doubleValue] &&
                [value doubleValue] >= INT32_MIN && [value doubleValue] <= INT32_MAX,
                @"INVALID_PARAMS", @"Native integer parameter values must be signed 32-bit integers.");
            if ([type isEqual:@"enum"]) SKMRequire([metadata[@"enum_options"] isKindOfClass:[NSArray class]] &&
                [[metadata[@"enum_options"] valueForKey:@"value"] containsObject:value],
                @"OUT_OF_RANGE", @"Enum values must come from the native discovered option table.");
            NSDictionary *range = metadata[@"data_range"];
            SKMRequire(![range isKindOfClass:[NSDictionary class]] ||
                ((!SKMNumber(range[@"min"]) || [value doubleValue] >= [range[@"min"] doubleValue]) &&
                 (!SKMNumber(range[@"max"]) || [value doubleValue] <= [range[@"max"] doubleValue])),
                @"OUT_OF_RANGE", @"Value is outside the discovered native data range.");
        } else if ([type isEqual:@"bool"]) SKMRequire(SKMBool(value), @"INVALID_PARAMS", @"Boolean parameter values must be actual booleans.");
        else if ([type isEqual:@"string"]) SKMRequire([value isKindOfClass:[NSString class]] && [params[@"mode"] isEqual:@"constant"],
            @"INVALID_PARAMS", @"String parameters require a string value and constant mode.");
        else if ([type isEqual:@"color"]) {
            SKMRequire([value isKindOfClass:[NSDictionary class]] && [value[@"space"] isEqual:@"native_curve"],
                @"INVALID_PARAMS", @"Colors must declare native_curve space.");
            for (NSString *field in @[@"r", @"g", @"b", @"a"]) SKMRequire(SKMNumber(value[field]), @"INVALID_PARAMS", @"Color components must be finite numbers.");
        }
        if ([params[@"mode"] isEqual:@"constant"] && [metadata[@"animatable"] boolValue]) {
            NSDictionary *keys = SKMCall(@"v4.keyframe.list", address)[@"readback"];
            SKMRequire([keys[@"keyframes"] isKindOfClass:[NSArray class]] && [keys[@"keyframes"] count] == 0,
                @"ANIMATED_PARAMETER", @"A constant named adjustment cannot erase existing animation.");
        }
        NSMutableDictionary *request = [address mutableCopy];
        request[@"value"] = typed;
        request[@"mode"] = params[@"mode"] ?: @"at_time";
        [requests addObject:request];
    }
    return requests;
}

NSDictionary *SKMApplyParameterRequests(NSDictionary *params, NSArray *requests, BOOL *attempted) {
    NSMutableArray *readbacks = [NSMutableArray array];
    BOOL changed = NO;
    @try {
        for (NSDictionary *request in requests) {
            *attempted = YES;
            NSDictionary *result = SKMCall(@"v4.parameter.set", request);
            [readbacks addObject:result[@"readback"] ?: NSNull.null];
            changed |= [result[@"applied"] isKindOfClass:[NSNumber class]] && [result[@"applied"] boolValue];
        }
        return SKMResult(params, YES, @(changed), @{@"target": params[@"target"], @"parameters": readbacks}, nil, nil);
    } @catch (NSException *exception) {
        return SKMResult(params, NO, *attempted ? nil : @NO,
            @{@"target": params[@"target"], @"completed_parameter_readbacks": readbacks}, exception.name, exception.reason);
    }
}

void SKMRegister(NSString *name, BOOL readOnly, SKV4MediaHandler handler) {
    SpliceKit_registerPluginMethod(name, ^NSDictionary *(NSDictionary *params) {
        __block NSDictionary *result = nil;
        __block BOOL attempted = NO;
        // The integrated core owns serialization, revisions, idempotency and undo.
        if (!readOnly && !SpliceKitV4IsExecuting()) return SKMResult(params, NO, @NO, nil,
            @"CORE_REQUIRED", @"Media mutations must run through the v4 operation core.");
        SpliceKit_executeOnMainThread(^{
            @try { result = handler(params, &attempted); }
            @catch (NSException *exception) {
                result = SKMResult(params, NO, attempted ? nil : @NO, nil,
                    exception.name, exception.reason);
            }
        });
        return result ?: SKMResult(params, NO, attempted ? nil : @NO, nil,
            @"NATIVE_ERROR", @"No native result; reconcile before retrying.");
    }, @{@"description": name, @"readOnly": @(readOnly),
         @"v4Undo": (readOnly || [name hasPrefix:@"v4.analysis."]) ? @"none" : @"native_group",
         @"v4RequiresSequence": @(![name hasPrefix:@"v4.analysis."] || [name hasSuffix:@".start"])});
}

@interface SpliceKitV4MediaBootstrap : NSObject @end
@implementation SpliceKitV4MediaBootstrap
+ (void)load {
    // Registry functions are available at load time; defer Foundation work until
    // the application's main run loop. This does not launch or alter FCP itself.
    dispatch_async(dispatch_get_main_queue(), ^{
        SpliceKitV4RegisterColor();
        SpliceKitV4RegisterAudio();
        SpliceKitV4RegisterRetime();
        SpliceKitV4RegisterAnalysis();
    });
}
@end
