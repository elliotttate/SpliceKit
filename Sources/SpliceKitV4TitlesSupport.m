#import "SpliceKitV4TitlesSupport.h"
#import <math.h>
#import <limits.h>
#import <string.h>
#import "SpliceKitV4Core.h"

@implementation SKTRequest
@end

void SKTRequire(BOOL condition, NSString *code, NSString *message) {
    if (!condition) @throw [NSException exceptionWithName:@"SpliceKitV4TitlesError"
        reason:message userInfo:@{@"code": code}];
}

BOOL SKTNumber(id value) {
    return [value isKindOfClass:[NSNumber class]] &&
        CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID() && isfinite([value doubleValue]);
}

BOOL SKTInteger(id value) {
    return SKTNumber(value) && floor([value doubleValue]) == [value doubleValue] &&
        [value doubleValue] >= -9007199254740991.0 && [value doubleValue] <= 9007199254740991.0;
}

id SKTGet(id object, NSString *name) {
    SEL sel = NSSelectorFromString(name);
    if (!object || ![object respondsToSelector:sel]) return nil;
    NSMethodSignature *signature = [object methodSignatureForSelector:sel];
    SKTRequire(signature && signature.methodReturnType[0] == '@', @"ABI_MISMATCH", name);
    return ((id (*)(id, SEL))objc_msgSend)(object, sel);
}

NSArray *SKTArray(id value) {
    if ([value isKindOfClass:[NSArray class]]) return value;
    if ([value isKindOfClass:[NSSet class]]) return [value allObjects];
    return @[];
}

CMTime SKTParseTime(id value, BOOL positive) {
    SKTRequire([value isKindOfClass:[NSDictionary class]] && SKTInteger(value[@"value"]) &&
        SKTInteger(value[@"timescale"]) && [value[@"timescale"] longLongValue] > 0 &&
        [value[@"timescale"] longLongValue] <= INT_MAX &&
        (positive ? [value[@"value"] longLongValue] > 0 : [value[@"value"] longLongValue] >= 0),
        @"INVALID_TIME", @"Time must be a nonnegative rational {value, timescale}; duration must be positive.");
    return CMTimeMake([value[@"value"] longLongValue], [value[@"timescale"] intValue]);
}

NSDictionary *SKTTime(CMTime time) {
    SKTRequire(CMTIME_IS_NUMERIC(time) && time.epoch == 0, @"INVALID_NATIVE_TIME", @"Native time is unavailable or nonnumeric.");
    return @{@"value": @(time.value), @"timescale": @(time.timescale)};
}

CMTime SKTFrame(id sequence) {
    SEL sel = NSSelectorFromString(@"frameDuration");
    SKTRequire([sequence respondsToSelector:sel], @"UNSUPPORTED_SELECTOR", @"frameDuration is unavailable.");
    CMTime frame = ((CMTime (*)(id, SEL))SKT_STRET)(sequence, sel);
    SKTRequire(CMTIME_IS_NUMERIC(frame) && frame.value > 0 && frame.epoch == 0,
        @"INVALID_FRAME_DURATION", @"Sequence frame duration is invalid.");
    return frame;
}

void SKTCheckFrame(CMTime time, CMTime frame) {
    __int128 numerator = (__int128)time.value * frame.timescale;
    __int128 denominator = (__int128)time.timescale * frame.value;
    SKTRequire(denominator > 0 && numerator % denominator == 0,
        @"OFF_FRAME", @"Time must align exactly to the sequence frame grid.");
}

CMTimeRange SKTRange(id object, NSString *name) {
    SEL sel = NSSelectorFromString(name);
    SKTRequire([object respondsToSelector:sel], @"UNSUPPORTED_SELECTOR", name);
    CMTimeRange range = ((CMTimeRange (*)(id, SEL))SKT_STRET)(object, sel);
    SKTTime(range.start); SKTTime(range.duration);
    return range;
}

CMTimeRange SKTEffectiveRange(id sequence, id object) {
    id primary = SKTGet(sequence, @"primaryObject");
    SEL sel = NSSelectorFromString(@"effectiveRangeOfObject:");
    SKTRequire([primary respondsToSelector:sel], @"UNSUPPORTED_SELECTOR", @"effectiveRangeOfObject: is unavailable.");
    CMTimeRange range = ((CMTimeRange (*)(id, SEL, id))SKT_STRET)(primary, sel, object);
    SKTTime(range.start); SKTTime(range.duration);
    return range;
}

id SKTSequence(void) {
    id sequence = SKTGet(SpliceKit_getActiveTimelineModule(), @"sequence");
    SKTRequire(sequence != nil, @"NO_SEQUENCE", @"Open a project before using this method.");
    return sequence;
}

static void SKTCollect(id object, NSMutableArray *result, NSHashTable *seen, NSUInteger depth) {
    SKTRequire(depth < 128 && result.count < 100000, @"TREE_LIMIT", @"Timeline graph exceeds traversal limits.");
    if (!object || [seen containsObject:object]) return;
    [seen addObject:object]; [result addObject:object];
    for (NSString *name in @[@"containedItems", @"anchoredItems"])
        for (id child in SKTArray(SKTGet(object, name))) SKTCollect(child, result, seen, depth + 1);
}

NSArray *SKTObjects(id sequence) {
    NSMutableArray *result = [NSMutableArray array];
    SKTCollect(SKTGet(sequence, @"primaryObject"), result,
        [NSHashTable hashTableWithOptions:NSPointerFunctionsObjectPointerPersonality], 0);
    return result;
}

NSString *SKTID(id object) {
    id value = SKTGet(object, @"persistentID"); // FFAnchoredComponent, FCP 12.4 binary metadata.
    if ([value isKindOfClass:[NSUUID class]]) return [value UUIDString];
    SKTRequire([value isKindOfClass:[NSString class]] && [value length] > 0,
        @"NO_PERSISTENT_ID", @"This native object does not expose a persistent clip identity.");
    return value;
}

id SKTFind(id sequence, NSString *objectID) {
    SKTRequire([objectID isKindOfClass:[NSString class]] && objectID.length > 0,
        @"INVALID_ID", @"A persistent clip_id is required; runtime handles are not accepted.");
    id found = nil;
    for (id object in SKTObjects(sequence)) {
        if (![object respondsToSelector:NSSelectorFromString(@"persistentID")]) continue;
        if (![SKTID(object) isEqualToString:objectID]) continue;
        SKTRequire(found == nil, @"AMBIGUOUS_ID", @"More than one clip has this persistent identity.");
        found = object;
    }
    SKTRequire(found != nil, @"CLIP_NOT_FOUND", @"The clip is absent from the active sequence.");
    return found;
}

NSDictionary *SKTObjectReadback(id sequence, id object) {
    CMTimeRange effective = SKTEffectiveRange(sequence, object);
    CMTimeRange local = SKTRange(object, @"clippedRange");
    SEL lane = NSSelectorFromString(@"anchoredLane");
    return @{@"clip_id": SKTID(object), @"class": NSStringFromClass([object class]),
        @"effectID": SKTGet(SKTGet(object, @"effect"), @"effectID") ?: [NSNull null],
        @"lane": [object respondsToSelector:lane] ? @(((NSInteger (*)(id, SEL))objc_msgSend)(object, lane)) : @0,
        @"start": SKTTime(effective.start), @"duration": SKTTime(effective.duration),
        @"source_start": SKTTime(local.start)};
}

void SKTEdit(id sequence, SKTRequest *request, void (^body)(void)) {
    // Use the sequence's own undo owner, never an arbitrary active library.
    id handler = SKTGet(sequence, @"undoHandler");
    SEL begin = NSSelectorFromString(@"undoableBegin:");
    SEL end = NSSelectorFromString(@"undoableEnd:save:error:");
    SKTRequire([handler respondsToSelector:begin] && [handler respondsToSelector:end],
        @"UNDO_UNAVAILABLE", @"The sequence undo handler is unavailable; no edit was attempted.");
    ((void (*)(id, SEL, id))objc_msgSend)(handler, begin, request.label);
    request.undoKind = @"native_group";
    @try {
        request.applied = [NSNull null];
        body();
    } @finally {
        NSError *error = nil;
        BOOL saved = ((BOOL (*)(id, SEL, id, BOOL, NSError **))objc_msgSend)(handler, end, nil, YES, &error);
        if (!saved) { request.applied = [NSNull null]; }
        SKTRequire(saved, @"UNDO_COMMIT_FAILED", error.localizedDescription ?: @"Undo transaction did not commit.");
    }
}

NSDictionary *SKTRun(NSDictionary *params, NSString *label, BOOL mutating,
                     NSDictionary *(^body)(SKTRequest *)) {
    SKTRequest *request = [SKTRequest new];
    request.operationID = [params[@"operation_id"] isKindOfClass:NSString.class] ? params[@"operation_id"] : NSUUID.UUID.UUIDString;
    request.label = label; request.applied = @NO; request.undoKind = @"none";
    request.warnings = [NSMutableArray arrayWithObject:@"Live native undo, persistence and rendered output require verification."];
    NSDictionary *error = nil;
    @try {
        SKTRequire(NSThread.isMainThread && (!mutating || SpliceKitV4IsExecuting()),
            @"CORE_REQUIRED", @"Run this handler synchronously through the v4 core dispatcher.");
        request.readback = body(request);
    } @catch (NSException *exception) {
        error = @{@"code": exception.userInfo[@"code"] ?: @"NATIVE_EXCEPTION",
            @"message": exception.reason ?: @"Native operation failed.", @"retryable": @NO};
    }
    return SpliceKitV4Result(request.operationID, error == nil,
        request.applied == NSNull.null ? nil : request.applied, request.readback,
        nil, nil, request.undoKind, label, request.warnings, error);
}

id SKTTransform(id clip) {
    Class cls = objc_getClass("FFCutawayEffects");
    SEL selector = NSSelectorFromString(@"transformEffectForObject:");
    SKTRequire([cls respondsToSelector:selector], @"TRANSFORM_UNAVAILABLE", @"The clip transform API is unavailable.");
    return ((id (*)(id, SEL, id))objc_msgSend)(cls, selector, clip);
}

NSDictionary *SKTPosition(id clip) {
    id transform = SKTTransform(clip);
    if (!transform) return @{@"x": @0, @"y": @0, @"z": @0, @"unit": @"pixels"};
    SEL sel = NSSelectorFromString(@"getPixelPositionAtTime:x:y:z:");
    SKTRequire([transform respondsToSelector:sel], @"UNSUPPORTED_SELECTOR", @"Position readback is unavailable.");
    double x = 0, y = 0, z = 0;
    ((void (*)(id, SEL, CMTime, double *, double *, double *))objc_msgSend)(transform, sel,
        SKTRange(clip, @"clippedRange").start, &x, &y, &z);
    return @{@"x": @(x), @"y": @(y), @"z": @(z), @"unit": @"pixels"};
}

void SKTValidatePosition(id value) {
    SKTRequire([value isKindOfClass:[NSDictionary class]] && SKTNumber(value[@"x"]) && SKTNumber(value[@"y"]),
        @"INVALID_POSITION", @"Position requires finite pixel x and y values.");
}

void SKTSetPosition(id clip, NSDictionary *position) {
    SKTValidatePosition(position);
    double previousZ = [SKTPosition(clip)[@"z"] doubleValue];
    Class cls = objc_getClass("FFCutawayEffects");
    SEL create = NSSelectorFromString(@"transformEffectForObject:createIfAbsent:");
    SKTRequire([cls respondsToSelector:create], @"TRANSFORM_UNAVAILABLE", @"The clip transform API is unavailable.");
    id transform = ((id (*)(id, SEL, id, BOOL))objc_msgSend)(cls, create, clip, YES);
    SEL sel = NSSelectorFromString(@"setPixelPositionAtTime:curveX:curveY:curveZ:options:");
    SKTRequire([transform respondsToSelector:sel], @"UNSUPPORTED_SELECTOR", @"Position editing is unavailable.");
    SKTGet(transform, @"storeForUndo");
    ((void (*)(id, SEL, CMTime, double, double, double, unsigned))objc_msgSend)(transform, sel,
        SKTRange(clip, @"clippedRange").start, [position[@"x"] doubleValue], [position[@"y"] doubleValue], previousZ, 0);
}

void SKTRegister(NSString *method, BOOL readOnly, SpliceKitMethodHandler handler) {
    SpliceKit_registerPluginMethod(method, handler, @{@"readOnly": @(readOnly),
        @"safety": readOnly ? @"safe" : @"destructive", @"summary": method,
        @"source": @"builtin-v4-titles", @"evidence_level": @"offline_tested",
        @"v4Undo": readOnly ? @"none" : @"native_group", @"v4RequiresSequence": @YES});
}
