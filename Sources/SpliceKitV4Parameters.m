// Native parameter discovery and typed values. UI labels are metadata, never addresses.
#import "SpliceKitV4Parameters.h"
#import "SpliceKit.h"
#import "SpliceKitV4Core.h"
#import <objc/message.h>
#import <limits.h>
#import <math.h>

void SKV4PRequire(BOOL condition, NSString *code, NSString *message) {
    if (!condition) @throw [NSException exceptionWithName:code reason:message userInfo:nil];
}
BOOL SKV4PHas(id o, NSString *s) { return o && [o respondsToSelector:NSSelectorFromString(s)]; }
id SKV4PObject(id o, NSString *s) {
    if (!SKV4PHas(o, s)) return nil;
    NSMethodSignature *sig = [o methodSignatureForSelector:NSSelectorFromString(s)];
    SKV4PRequire(sig.numberOfArguments == 2 && sig.methodReturnType[0] == '@', @"UNSUPPORTED_CAPABILITY", [@"Object ABI required for " stringByAppendingString:s]);
    return ((id (*)(id, SEL))objc_msgSend)(o, NSSelectorFromString(s));
}
id SKV4PObject1(id o, NSString *s, id arg) {
    if (!SKV4PHas(o, s)) return nil;
    NSMethodSignature *sig = [o methodSignatureForSelector:NSSelectorFromString(s)];
    SKV4PRequire(sig.numberOfArguments == 3 && sig.methodReturnType[0] == '@' && [sig getArgumentTypeAtIndex:2][0] == '@', @"UNSUPPORTED_CAPABILITY", [@"Object ABI required for " stringByAppendingString:s]);
    return ((id (*)(id, SEL, id))objc_msgSend)(o, NSSelectorFromString(s), arg);
}
NSString *SKV4PIdentity(id o, NSString *s) {
    id value = SKV4PObject(o, s);
    if ([value isKindOfClass:NSString.class]) return [value length] ? value : nil;
    if ([value isKindOfClass:NSUUID.class]) return [value UUIDString];
    // Do not turn an object's description or an ephemeral address into an identity.
    return nil;
}
NSString *SKV4PEscape(NSString *s) { return [[s stringByReplacingOccurrencesOfString:@"~" withString:@"~0"] stringByReplacingOccurrencesOfString:@"/" withString:@"~1"]; }
NSString *SKV4PEffectIdentity(id effect) {
    // Imported FFMotionEffect.fileUUID is nil on FCP 12.4. persistentID is the
    // native, serialized instance identity and survives library reopen.
    return SKV4PIdentity(effect, @"persistentID") ?: SKV4PIdentity(effect, @"fileUUID");
}
NSArray *SKV4PArray(id o) {
    if ([o isKindOfClass:NSArray.class]) return o;
    if ([o isKindOfClass:NSSet.class]) return [o allObjects];
    if ([o isKindOfClass:NSOrderedSet.class]) return [o array];
    return @[];
}
BOOL SKV4PBool(id o, NSString *s) { return SKV4PHas(o, s) && ((BOOL (*)(id, SEL))objc_msgSend)(o, NSSelectorFromString(s)); }
BOOL SKV4PNumber(id n) { return [n isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)n) != CFBooleanGetTypeID() && isfinite([n doubleValue]); }
BOOL SKV4PInteger(id n) {
    return SKV4PNumber(n) && strchr("cCsSiIlLqQ", [n objCType][0]) != NULL &&
        !([n objCType][0] == 'Q' && [n unsignedLongLongValue] > LLONG_MAX);
}
CMTime SKV4PParseTime(NSDictionary *time) {
    SKV4PRequire([time isKindOfClass:NSDictionary.class], @"INVALID_TIME", @"Explicit rational time required");
    id v = time[@"value"], scale = time[@"timescale"];
    SKV4PRequire(SKV4PInteger(v) && SKV4PInteger(scale) && [scale longLongValue] > 0 && [scale longLongValue] <= INT_MAX,
                 @"INVALID_TIME", @"Time requires int64 value and positive int32 timescale");
    SKV4PRequire([@[@"clip_local", @"timeline"] containsObject:time[@"space"] ?: @""], @"INVALID_TIME", @"Explicit clip_local or timeline space required");
    return CMTimeMake([v longLongValue], [scale intValue]);
}
NSDictionary *SKV4PTimeJSON(CMTime t, NSString *space) {
    SKV4PRequire(CMTIME_IS_NUMERIC(t) && t.epoch == 0 && t.timescale > 0, @"INVALID_TIME", @"Native time is not numeric or has a nonzero epoch");
    return @{@"value":@(t.value), @"timescale":@(t.timescale), @"space":space};
}
CMTime SKV4PConvertTime(id o, NSString *s, CMTime t, id container) {
    SKV4PRequire(SKV4PHas(o, s), @"UNSUPPORTED_CAPABILITY", [@"Native time mapping unavailable: " stringByAppendingString:s]);
    NSMethodSignature *sig = [o methodSignatureForSelector:NSSelectorFromString(s)];
    NSUInteger size = 0; NSGetSizeAndAlignment([sig getArgumentTypeAtIndex:2], &size, NULL);
    SKV4PRequire(sig.methodReturnLength == sizeof(CMTime) && size == sizeof(CMTime) && sig.numberOfArguments == 4,
                 @"UNSUPPORTED_CAPABILITY", @"Native time ABI mismatch");
    // NSInvocation handles CMTime struct return on both Intel and ARM.
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    inv.target = o; inv.selector = NSSelectorFromString(s);
    [inv setArgument:&t atIndex:2]; [inv setArgument:&container atIndex:3]; [inv invoke];
    CMTime result; [inv getReturnValue:&result]; SKV4PTimeJSON(result, @"clip_local"); return result;
}
CMTime SKV4PResolveTime(SKV4PContext *c) {
    CMTime t = SKV4PParseTime(c.params[@"time"]);
    if ([c.params[@"time"][@"space"] isEqual:@"timeline"])
        t = SKV4PConvertTime(c.clip, @"containerToLocalTime:container:", t, c.sequenceRoot);
    // UNVERIFIED: Component-local -> native curve alignment on trimmed, nested and retimed effects needs the live fixture.
    return t;
}

@implementation SKV4PContext
- (void)resolveTarget {
    NSDictionary *target = self.params[@"target"];
    SKV4PRequire([target isKindOfClass:NSDictionary.class] && [target[@"clip_id"] isKindOfClass:NSString.class] && [target[@"clip_id"] length], @"INVALID_ARGUMENT", @"Native target.clip_id required");
    id timeline = SpliceKit_getActiveTimelineModule();
    id sequence = SKV4PObject(timeline, @"sequence");
    self.sequenceRoot = SKV4PObject(sequence, @"primaryObject");
    SKV4PRequire(self.sequenceRoot != nil, @"TARGET_NOT_FOUND", @"No active sequence");
    NSMutableArray *queue = [NSMutableArray arrayWithObject:self.sequenceRoot];
    NSHashTable *seen = [NSHashTable hashTableWithOptions:NSPointerFunctionsObjectPointerPersonality | NSPointerFunctionsStrongMemory];
    NSMutableArray *matches = [NSMutableArray array];
    while (queue.count) {
        SKV4PRequire(seen.count < 20000, @"INSPECTION_LIMIT", @"Sequence identity traversal exceeded its bound");
        id item = queue.lastObject; [queue removeLastObject];
        if ([seen containsObject:item]) continue; [seen addObject:item];
        if ([SKV4PIdentity(item, @"persistentID") isEqual:target[@"clip_id"]]) [matches addObject:item];
        for (NSString *selector in @[@"containedItems", @"anchoredItems"])
            [queue addObjectsFromArray:SKV4PArray(SKV4PObject(item, selector))];
    }
    SKV4PRequire(matches.count == 1, matches.count ? @"AMBIGUOUS_IDENTITY" : @"TARGET_NOT_FOUND", @"clip_id must resolve exactly once in the active sequence");
    self.clip = matches[0]; self.stack = SKV4PObject(self.clip, @"effectStack");
    // FCPXML AV clips are FFAnchoredCollection objects. Their own video stack
    // holds imported filters/intrinsics; a child component's stack is distinct.
    // FCP 12.4 runtime: FFAnchoredCollection.videoEffects -> FFEffectStack (@16@0:8).
    if (!self.stack) self.stack = SKV4PObject(self.clip, @"videoEffects");
    SKV4PRequire(self.stack != nil, @"UNSUPPORTED_CAPABILITY", @"Clip has no native effect stack");
    id instance = target[@"effect_instance_id"];
    if (instance) {
        SKV4PRequire([instance isKindOfClass:NSString.class] && [instance length], @"INVALID_ARGUMENT", @"effect_instance_id must be a native persistentID (legacy fileUUID when absent) string");
        NSArray *effects = SKV4PArray(SKV4PObject(self.stack, @"effects"));
        NSUInteger found = 0;
        for (id effect in effects) if ([SKV4PEffectIdentity(effect) isEqual:instance]) { self.effect = effect; found++; }
        SKV4PRequire(found == 1, found ? @"AMBIGUOUS_IDENTITY" : @"TARGET_NOT_FOUND", @"Effect instance does not belong uniquely to this clip");
    }
}
- (void)beginMutation {
    SKV4PRequire(SKV4PHas(self.stack, @"actionBegin:animationHint:deferUpdates:") && SKV4PHas(self.stack, @"actionEnd:save:error:"), @"UNSUPPORTED_CAPABILITY", @"Native action grouping unavailable");
    ((void (*)(id, SEL, id, id, BOOL))objc_msgSend)(self.stack, NSSelectorFromString(@"actionBegin:animationHint:deferUpdates:"), self.label, nil, YES);
    self.began = YES;
    (void)SKV4PObject(self.stack, @"storeForUndo");
}
@end

NSDictionary *SKV4PRun(NSDictionary *params, NSString *label, BOOL mutation, NSDictionary *(^body)(SKV4PContext *)) {
    SKV4PContext *c = [SKV4PContext new]; c.params = params; c.label = label;
    c.applied = @NO; c.warnings = [NSMutableArray array];
    __block NSDictionary *error = nil;
    NSString *operationID = [params isKindOfClass:NSDictionary.class] && [params[@"operation_id"] isKindOfClass:NSString.class] && [params[@"operation_id"] length] ? params[@"operation_id"] : NSUUID.UUID.UUIDString;
    SpliceKit_executeOnMainThread(^{
        @try {
            SKV4PRequire([params isKindOfClass:NSDictionary.class] && (!params[@"operation_id"] || ([params[@"operation_id"] isKindOfClass:NSString.class] && [params[@"operation_id"] length])), @"INVALID_ARGUMENT", @"params must be an object; operation_id must be a nonempty string");
            SKV4PRequire(!mutation || SpliceKitV4IsExecuting(), @"CORE_REQUIRED", @"Mutations require the v4 operation dispatcher.");
            c.readback = body(c);
        } @catch (NSException *e) {
            error = @{@"code":e.name ?: @"NATIVE_EXCEPTION", @"message":e.reason ?: @"Native exception", @"retryable":@NO};
        } @finally {
            if (c.began) {
                @try {
                    NSError *nativeError = nil;
                    BOOL saved = ((BOOL (*)(id, SEL, id, BOOL, NSError **))objc_msgSend)(c.stack, NSSelectorFromString(@"actionEnd:save:error:"), label, YES, &nativeError);
                    c.ended = saved;
                    if (!saved) c.applied = NSNull.null;
                    if (saved && c.afterCommit) c.readback = c.afterCommit(c);
                    if (!saved && !error) error = @{@"code":@"UNKNOWN_OUTCOME", @"message":nativeError.localizedDescription ?: @"Native action could not be saved", @"retryable":@NO};
                } @catch (NSException *e) {
                    if (!c.ended) c.applied = NSNull.null;
                    if (!error) error = @{@"code":c.ended ? e.name : @"UNKNOWN_OUTCOME", @"message":e.reason ?: @"Native action close failed", @"retryable":@NO};
                }
            }
            c.afterCommit = nil;
        }
    });
    [c.warnings addObject:@"Native host behavior, persistence, undo and rendered output still require live verification."];
    return SpliceKitV4Result(operationID, error == nil,
        c.applied == NSNull.null ? nil : c.applied, c.readback, nil, nil,
        c.began ? (c.ended ? @"native_group" : @"unknown") : @"none", label, c.warnings, error);
}

NSString *SKV4PType(id ch) {
    if (SKV4PHas(ch, @"strings") && SKV4PHas(ch, @"intValueAtTime:")) return @"enum";
    if (SKV4PHas(ch, @"curveBoolValueAtTime:")) return @"bool";
    if (SKV4PHas(ch, @"getColorAtTime:curveRed:curveGreen:curveBlue:curveAlpha:")) return @"color";
    if (SKV4PHas(ch, @"getColorAtTime:curveRed:curveGreen:curveBlue:")) return @"color";
    if (SKV4PHas(ch, @"getDoubleValuesAtTime:curveX:curveY:curveZ:")) return @"point3d";
    if (SKV4PHas(ch, @"getDoubleValuesAtTime:curveX:curveY:")) return @"point2d";
    if (SKV4PHas(ch, @"_curveIntValueAtTime:")) return @"int";
    if (SKV4PHas(ch, @"curveDoubleValueAtTime:"))
        return [ch isKindOfClass:NSClassFromString(@"CHChannelAngle")] ? @"angle" : @"double";
    if (SKV4PHas(ch, @"string") && SKV4PHas(ch, @"setString:")) return @"string";
    return @"container";
}
static NSString *SKV4PSetter(NSString *type) {
    return @{@"double":@"setCurveDoubleValue:atTime:options:", @"angle":@"setCurveDoubleValue:atTime:options:",
        @"int":@"_setCurveIntValue:atTime:options:", @"enum":@"setCurveIntValue:atTime:options:",
        @"bool":@"setCurveBoolValue:atTime:options:", @"color":@"setColorAtTime:curveRed:curveGreen:curveBlue:curveAlpha:options:",
        @"point2d":@"setDoubleValuesAtTime:curveX:curveY:options:", @"point3d":@"setDoubleValuesAtTime:curveX:curveY:curveZ:options:", @"string":@"setString:"}[type];
}
static NSString *SKV4PChannelSetter(id ch, NSString *type) {
    if ([type isEqual:@"color"] && !SKV4PHas(ch, @"getColorAtTime:curveRed:curveGreen:curveBlue:curveAlpha:"))
        return @"setColorAtTime:curveRed:curveGreen:curveBlue:options:";
    return SKV4PSetter(type);
}
NSDictionary *SKV4PRead(id ch, CMTime t) {
    NSString *type = SKV4PType(ch); id v = nil;
    if ([type isEqual:@"double"] || [type isEqual:@"angle"]) v = @(((double (*)(id, SEL, CMTime))objc_msgSend)(ch, NSSelectorFromString(@"curveDoubleValueAtTime:"), t));
    else if ([type isEqual:@"bool"]) v = @(((BOOL (*)(id, SEL, CMTime))objc_msgSend)(ch, NSSelectorFromString(@"curveBoolValueAtTime:"), t));
    else if ([type isEqual:@"enum"] || [type isEqual:@"int"]) v = @(((int (*)(id, SEL, CMTime))objc_msgSend)(ch, NSSelectorFromString([type isEqual:@"enum"] ? @"intValueAtTime:" : @"_curveIntValueAtTime:"), t));
    else if ([type isEqual:@"color"]) {
        double r=0,g=0,b=0,a=1;
        if (SKV4PHas(ch, @"getColorAtTime:curveRed:curveGreen:curveBlue:curveAlpha:"))
            ((void (*)(id, SEL, CMTime, double *, double *, double *, double *))objc_msgSend)(ch, NSSelectorFromString(@"getColorAtTime:curveRed:curveGreen:curveBlue:curveAlpha:"), t, &r,&g,&b,&a);
        else ((void (*)(id, SEL, CMTime, double *, double *, double *))objc_msgSend)(ch,
            NSSelectorFromString(@"getColorAtTime:curveRed:curveGreen:curveBlue:"), t, &r,&g,&b);
        SKV4PRequire(isfinite(r) && isfinite(g) && isfinite(b) && isfinite(a), @"INVALID_NATIVE_VALUE", @"Nonfinite native color");
        v = @{@"r":@(r),@"g":@(g),@"b":@(b),@"a":@(a),@"space":@"native_curve"};
    } else if ([type hasPrefix:@"point"]) {
        double x=0,y=0,z=0;
        if ([type isEqual:@"point2d"]) ((void (*)(id, SEL, CMTime, double *, double *))objc_msgSend)(ch, NSSelectorFromString(@"getDoubleValuesAtTime:curveX:curveY:"), t, &x,&y);
        else ((void (*)(id, SEL, CMTime, double *, double *, double *))objc_msgSend)(ch, NSSelectorFromString(@"getDoubleValuesAtTime:curveX:curveY:curveZ:"), t, &x,&y,&z);
        SKV4PRequire(isfinite(x) && isfinite(y) && isfinite(z), @"INVALID_NATIVE_VALUE", @"Nonfinite native point");
        v = [type isEqual:@"point2d"] ? @{@"x":@(x),@"y":@(y)} : @{@"x":@(x),@"y":@(y),@"z":@(z)};
    } else if ([type isEqual:@"string"]) v = SKV4PObject(ch, @"string");
    if ([v isKindOfClass:NSNumber.class]) SKV4PRequire(isfinite([v doubleValue]), @"INVALID_NATIVE_VALUE", @"Nonfinite native scalar");
    SKV4PRequire(v != nil, @"UNSUPPORTED_CAPABILITY", @"Channel has no supported typed reader");
    return @{@"type":type,@"value":v};
}
static NSArray *SKV4PEnumOptions(id ch) {
    NSMutableArray *out = [NSMutableArray array];
    NSArray *strings = SKV4PArray(SKV4PObject(ch, @"strings"));
    SKV4PRequire(SKV4PHas(ch, @"intValueForIndex:"), @"UNSUPPORTED_CAPABILITY", @"Enum value mapping unavailable");
    for (NSUInteger i=0;i<strings.count;i++) {
        int value = ((int (*)(id, SEL, int))objc_msgSend)(ch, NSSelectorFromString(@"intValueForIndex:"), (int)i);
        [out addObject:@{@"value":@(value),@"localized_label":[strings[i] description]}];
    }
    return out;
}
static id SKV4PLimit(id ch, NSString *s, NSString *type) {
    if (!SKV4PHas(ch,s)) return NSNull.null;
    if ([type isEqual:@"bool"]) return @(SKV4PBool(ch,s));
    if ([type isEqual:@"int"]) return @(((int (*)(id,SEL))objc_msgSend)(ch,NSSelectorFromString(s)));
    double v = ((double (*)(id,SEL))objc_msgSend)(ch,NSSelectorFromString(s));
    return isfinite(v) ? @(v) : NSNull.null;
}
static NSDictionary *SKV4PRange(id ch, NSString *type, BOOL ui) {
    NSString *suffix = [type isEqual:@"bool"] ? @"BoolValue" : [type isEqual:@"int"] ? @"IntValue" : @"DoubleValue";
    NSString *prefix = [type isEqual:@"int"] ? @"_" : @"";
    NSString *domain = ui ? @"UI" : @"Curve";
    return @{@"min":SKV4PLimit(ch,[NSString stringWithFormat:@"%@min%@%@",prefix,domain,suffix],type),
             @"max":SKV4PLimit(ch,[NSString stringWithFormat:@"%@max%@%@",prefix,domain,suffix],type)};
}
static void SKV4PValidateValue(id ch, NSDictionary *value) {
    NSString *type = SKV4PType(ch);
    SKV4PRequire([value isKindOfClass:NSDictionary.class] && [value[@"type"] isEqual:type], @"TYPE_MISMATCH", @"Value type must match discovered native channel type");
    SKV4PRequire(SKV4PChannelSetter(ch,type) && SKV4PHas(ch, SKV4PChannelSetter(ch,type)), @"UNSUPPORTED_CAPABILITY", @"Native typed setter unavailable");
    id v = value[@"value"];
    if ([type isEqual:@"double"] || [type isEqual:@"angle"]) SKV4PRequire(SKV4PNumber(v), @"TYPE_MISMATCH", @"Finite number required");
    else if ([type isEqual:@"int"] || [type isEqual:@"enum"]) {
        SKV4PRequire(SKV4PInteger(v) && [v longLongValue]>=INT_MIN && [v longLongValue]<=INT_MAX, @"TYPE_MISMATCH", @"Native int32 required");
        if ([type isEqual:@"enum"]) SKV4PRequire([[SKV4PEnumOptions(ch) valueForKey:@"value"] containsObject:v], @"OUT_OF_RANGE", @"Enum value is not a native option");
    } else if ([type isEqual:@"bool"]) SKV4PRequire([v isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)v)==CFBooleanGetTypeID(), @"TYPE_MISMATCH", @"Boolean required");
    else if ([type isEqual:@"string"]) SKV4PRequire([v isKindOfClass:NSString.class], @"TYPE_MISMATCH", @"String required");
    else {
        SKV4PRequire([v isKindOfClass:NSDictionary.class], @"TYPE_MISMATCH", @"Typed component object required");
        NSArray *keys = [type isEqual:@"color"] ? @[@"r",@"g",@"b",@"a"] : [type isEqual:@"point3d"] ? @[@"x",@"y",@"z"] : @[@"x",@"y"];
        for (NSString *key in keys) SKV4PRequire(SKV4PNumber(v[key]), @"TYPE_MISMATCH", @"Every component must be a finite number");
        if ([type isEqual:@"color"]) SKV4PRequire([v[@"space"] isEqual:@"native_curve"], @"TYPE_MISMATCH", @"Explicit native_curve color space required");
        if ([type isEqual:@"color"] && !SKV4PHas(ch,@"getColorAtTime:curveRed:curveGreen:curveBlue:curveAlpha:"))
            SKV4PRequire([v[@"a"] isEqual:@1], @"UNSUPPORTED_ALPHA", @"This native RGB control has implicit alpha 1");
    }
    if ([@[@"double",@"angle",@"int"] containsObject:type]) {
        NSDictionary *range = SKV4PRange(ch,type,NO);
        SKV4PRequire((range[@"min"]==NSNull.null || [v doubleValue]>=[range[@"min"] doubleValue]) &&
                     (range[@"max"]==NSNull.null || [v doubleValue]<=[range[@"max"] doubleValue]), @"OUT_OF_RANGE", @"Value outside native data bounds (UI bounds do not clamp data)");
    }
}
void SKV4PWrite(id ch, NSDictionary *value, CMTime t) {
    SKV4PValidateValue(ch,value);
    // options=0 updates a native value. The at-time caller explicitly inserts a
    // missing scalar key and verifies all existing keys independently.
    NSString *type = value[@"type"]; id v = value[@"value"]; SEL s = NSSelectorFromString(SKV4PChannelSetter(ch,type));
    if ([type isEqual:@"double"] || [type isEqual:@"angle"]) ((void (*)(id,SEL,double,CMTime,unsigned))objc_msgSend)(ch,s,[v doubleValue],t,0);
    else if ([type isEqual:@"int"] || [type isEqual:@"enum"]) ((void (*)(id,SEL,int,CMTime,unsigned))objc_msgSend)(ch,s,[v intValue],t,0);
    else if ([type isEqual:@"bool"]) ((void (*)(id,SEL,BOOL,CMTime,unsigned))objc_msgSend)(ch,s,[v boolValue],t,0);
    else if ([type isEqual:@"color"]) {
        if (SKV4PHas(ch,@"getColorAtTime:curveRed:curveGreen:curveBlue:curveAlpha:"))
            ((void (*)(id,SEL,CMTime,double,double,double,double,unsigned))objc_msgSend)(ch,s,t,[v[@"r"] doubleValue],[v[@"g"] doubleValue],[v[@"b"] doubleValue],[v[@"a"] doubleValue],0);
        else ((void (*)(id,SEL,CMTime,double,double,double,unsigned))objc_msgSend)(ch,s,t,[v[@"r"] doubleValue],[v[@"g"] doubleValue],[v[@"b"] doubleValue],0);
    }
    else if ([type isEqual:@"point2d"]) ((void (*)(id,SEL,CMTime,double,double,unsigned))objc_msgSend)(ch,s,t,[v[@"x"] doubleValue],[v[@"y"] doubleValue],0);
    else if ([type isEqual:@"point3d"]) ((void (*)(id,SEL,CMTime,double,double,double,unsigned))objc_msgSend)(ch,s,t,[v[@"x"] doubleValue],[v[@"y"] doubleValue],[v[@"z"] doubleValue],0);
    else if ([type isEqual:@"string"]) ((void (*)(id,SEL,id))objc_msgSend)(ch,s,v);
}
void SKV4PChannelEdit(id channel, dispatch_block_t body) {
    SKV4PRequire(SKV4PHas(channel,@"operationBegin") && SKV4PHas(channel,@"operationEnd"),
        @"UNSUPPORTED_CAPABILITY", @"Native channel edit transaction unavailable");
    ((void (*)(id,SEL))objc_msgSend)(channel,NSSelectorFromString(@"operationBegin"));
    @try { body(); }
    @finally { ((void (*)(id,SEL))objc_msgSend)(channel,NSSelectorFromString(@"operationEnd")); }
}
BOOL SKV4PValueEqual(id a, id b) {
    if ([a isKindOfClass:NSDictionary.class] && [b isKindOfClass:NSDictionary.class]) {
        if ([a count] != [b count]) return NO;
        for (id key in a) if (!SKV4PValueEqual(a[key],b[key])) return NO;
        return YES;
    }
    if (SKV4PNumber(a) && SKV4PNumber(b)) return fabs([a doubleValue]-[b doubleValue]) <= 1e-8 * MAX(1,MAX(fabs([a doubleValue]),fabs([b doubleValue])));
    return [a isEqual:b];
}

static NSDictionary *SKV4PNode(id ch, NSString *parent, NSMutableDictionary *objects, NSHashTable *ancestors, NSUInteger depth) {
    SKV4PRequire(depth < 32 && objects.count < 10000 && ![ancestors containsObject:ch], @"INSPECTION_LIMIT", @"Parameter graph is cyclic or exceeds traversal bounds");
    SKV4PRequire(SKV4PHas(ch,@"channelID"), @"UNSUPPORTED_CAPABILITY", @"Stable native channelID missing; localized names are not addresses");
    unsigned cid = ((unsigned (*)(id,SEL))objc_msgSend)(ch,NSSelectorFromString(@"channelID"));
    NSString *path = [parent stringByAppendingFormat:@"/%u",cid];
    SKV4PRequire(!objects[path], @"AMBIGUOUS_PARAMETER_PATH", @"Duplicate native channel ID in one folder");
    objects[path] = ch; [ancestors addObject:ch];
    NSString *type = SKV4PType(ch);
    BOOL scalar = ![type isEqual:@"container"];
    BOOL animatable = scalar && ![type isEqual:@"string"] && SKV4PHas(ch,@"allowsKeyframes") && SKV4PBool(ch,@"allowsKeyframes");
    NSMutableDictionary *node = [@{@"parameter_path":path, @"channel_id":@(cid), @"localized_name":SKV4PObject(ch,@"name") ?: @"",
        @"type":type, @"native_class":NSStringFromClass([ch class]), @"unit":NSNull.null,
        @"coordinate_space":scalar ? @"native_curve" : (id)NSNull.null,
        @"data_range":@{@"min":NSNull.null,@"max":NSNull.null}, @"ui_range":@{@"min":NSNull.null,@"max":NSNull.null},
        @"enum_options":[type isEqual:@"enum"] ? SKV4PEnumOptions(ch) : (id)NSNull.null,
        @"animatable":@(animatable), @"writable":@((BOOL)(scalar && SKV4PHas(ch,SKV4PChannelSetter(ch,type)))),
        @"interpolations":animatable && [@[@"double",@"angle",@"int"] containsObject:type] ? @[@"linear",@"hold",@"ease_in_out"] : @[],
        @"time_space":@"clip_local", @"slider_transformer":SKV4PObject(ch,@"sliderTransformerName") ?: NSNull.null} mutableCopy];
    if ([type isEqual:@"color"]) node[@"alpha_supported"] = @(SKV4PHas(ch,@"getColorAtTime:curveRed:curveGreen:curveBlue:curveAlpha:"));
    if ([@[@"double",@"angle",@"int",@"bool"] containsObject:type]) {
        node[@"data_range"] = SKV4PRange(ch,type,NO); node[@"ui_range"] = SKV4PRange(ch,type,YES);
    }
    NSMutableArray *children = [NSMutableArray array];
    for (id child in SKV4PArray(SKV4PObject(ch,@"children"))) [children addObject:SKV4PNode(child,path,objects,ancestors,depth+1)];
    node[@"children"] = children;
    [ancestors removeObject:ch];
    return node;
}
static NSDictionary *SKV4PTree(SKV4PContext *c, NSMutableDictionary *objects) {
    NSMutableArray *components = [NSMutableArray array];
    NSArray *effects = c.effect ? @[c.effect] : SKV4PArray(SKV4PObject(c.stack,@"effects"));
    NSMutableArray *roots = [NSMutableArray array];
    for (id effect in effects) {
        NSString *instance = SKV4PEffectIdentity(effect);
        SKV4PRequire(instance.length, @"AMBIGUOUS_IDENTITY", @"Effect has no native persistentID (legacy fileUUID when absent)");
        [roots addObject:@{@"component_path":[@"/effects/" stringByAppendingString:SKV4PEscape(instance)],@"owner":effect,@"root":SKV4PObject(effect,@"channelFolder") ?: NSNull.null}];
    }
    if (!c.effect) {
        NSDictionary *intrinsics = @{@"transform":@"xform3DEffect",@"crop":@"cropEffect",@"trim":@"trimEffect",@"distort":@"distortEffect",@"compositing":@"intrinsicCompositeEffect"};
        for (NSString *name in [intrinsics.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
            id effect = SKV4PObject(c.stack,intrinsics[name]);
            [roots addObject:@{@"component_path":[@"/intrinsic/" stringByAppendingString:name],@"owner":effect ?: NSNull.null,@"root":SKV4PObject(effect,@"channelFolder") ?: NSNull.null}];
        }
        [roots addObject:@{@"component_path":@"/intrinsic/audio",@"owner":c.stack,@"root":SKV4PObject(c.stack,@"audioLevelChannel") ?: NSNull.null}];
        [roots addObject:@{@"component_path":@"/intrinsic/native",@"owner":c.stack,@"root":SKV4PObject(c.stack,@"intrinsicChannels") ?: NSNull.null}];
    }
    NSMutableDictionary *bindings = [NSMutableDictionary dictionary];
    for (NSDictionary *root in roots) {
        NSString *prefix = root[@"component_path"]; id ch = root[@"root"];
        NSMutableDictionary *component = [@{@"component_path":prefix,@"available":@((BOOL)(ch != NSNull.null)),@"children":@[]} mutableCopy];
        if (ch != NSNull.null) {
            NSHashTable *ancestors = [NSHashTable hashTableWithOptions:NSPointerFunctionsObjectPointerPersonality | NSPointerFunctionsStrongMemory];
            component[@"children"] = @[SKV4PNode(ch,[prefix stringByAppendingString:@"/channels"],objects,ancestors,0)];
            // Stable selector aliases help intrinsic consumers bind scalar children without localized labels.
            NSDictionary *selectors = @{@"scale":@"scaleChannel3D",@"position":@"positionChannel3D",@"rotation":@"rotationChannel3D",@"anchor":@"anchorChannel3D",
                @"left":@"leftChannel",@"right":@"rightChannel",@"top":@"topChannel",@"bottom":@"bottomChannel",
                @"ken_burns.left":@"leftKBChannel",@"ken_burns.right":@"rightKBChannel",@"ken_burns.top":@"topKBChannel",@"ken_burns.bottom":@"bottomKBChannel",
                @"mode":@"cropType",@"four_corners":@"fourCornerChannel",@"opacity":@"opacityChannel",@"blend_mode":@"blendModeChannel",@"gain":@"audioLevelChannel"};
            for (NSString *name in selectors) {
                id bound = SKV4PObject(root[@"owner"],selectors[name]); if (!bound) continue;
                for (NSString *path in objects) {
                    if (![path hasPrefix:[prefix stringByAppendingString:@"/"]] || objects[path] != bound) continue;
                    bindings[[prefix stringByAppendingFormat:@"/%@",name]] = path;
                    for (NSString *axis in @[@"x",@"y",@"z"]) {
                        id axisChannel = SKV4PObject(bound,[axis stringByAppendingString:@"Channel"]);
                        for (NSString *axisPath in objects) if (axisChannel && objects[axisPath] == axisChannel && [axisPath hasPrefix:[path stringByAppendingString:@"/"]])
                            bindings[[prefix stringByAppendingFormat:@"/%@/%@",name,axis]] = axisPath;
                    }
                }
            }
        }
        [components addObject:component];
    }
    return @{@"components":components,@"bindings":bindings};
}
static NSDictionary *SKV4PFindLeaf(NSArray *nodes, NSString *path) {
    for (NSDictionary *node in nodes) {
        if ([node[@"parameter_path"] isEqual:path]) return node;
        NSDictionary *found = SKV4PFindLeaf(node[@"children"],path); if (found) return found;
    }
    return nil;
}
NSDictionary *SKV4PFindParameter(SKV4PContext *c, id *channelOut) {
    NSString *path = c.params[@"parameter_path"];
    SKV4PRequire([path isKindOfClass:NSString.class] && [path hasPrefix:@"/"], @"INVALID_ARGUMENT", @"Copy parameter_path from object.inspect");
    NSMutableDictionary *objects = [NSMutableDictionary dictionary];
    NSDictionary *tree = SKV4PTree(c,objects);
    SKV4PRequire(objects[path] != nil, @"PARAMETER_NOT_FOUND", @"Parameter path does not belong to target; re-inspect this clip or effect");
    if (channelOut) *channelOut = objects[path];
    for (NSDictionary *component in tree[@"components"]) {
        NSDictionary *leaf = SKV4PFindLeaf(component[@"children"],path); if (leaf) return leaf;
    }
    SKV4PRequire(NO,@"PARAMETER_NOT_FOUND",@"Parameter metadata missing"); return nil;
}
NSDictionary *SKV4PParameterReadback(SKV4PContext *c, id ch, CMTime t) {
    BOOL hasKey = SKV4PHas(ch,@"hasKeyframeAtTime:") && ((BOOL (*)(id,SEL,CMTime))objc_msgSend)(ch,NSSelectorFromString(@"hasKeyframeAtTime:"),t);
    return @{@"target":c.params[@"target"],@"parameter_path":c.params[@"parameter_path"],@"time":c.params[@"time"],
        @"resolved_time":SKV4PTimeJSON(t,@"clip_local"),@"channel_time":SKV4PTimeJSON(t,@"clip_local"),@"value":SKV4PRead(ch,t),@"has_keyframe":@(hasKey)};
}
NSDictionary *SpliceKitV4_handleParameter(NSString *op, NSDictionary *params) {
    BOOL write = [op isEqual:@"set"] || [op isEqual:@"keyframe_set"];
    NSString *label = [op isEqual:@"inspect"] ? @"v4.object.inspect" : [op isEqual:@"keyframe_set"] ? @"v4.keyframe.set" : [@"v4.parameter." stringByAppendingString:op];
    return SKV4PRun(params, label, write, ^NSDictionary *(SKV4PContext *c) {
        [c resolveTarget];
        if ([op isEqual:@"inspect"]) {
            CMTime t = SKV4PResolveTime(c);
            NSMutableDictionary *objects = [NSMutableDictionary dictionary];
            NSMutableDictionary *tree = [SKV4PTree(c,objects) mutableCopy];
            NSMutableDictionary *values = [NSMutableDictionary dictionary];
            for (NSString *path in objects) if (![SKV4PType(objects[path]) isEqual:@"container"]) values[path] = SKV4PRead(objects[path],t);
            tree[@"values"] = values; tree[@"target"] = params[@"target"]; tree[@"effects"] = SKV4PEffectInventory(c);
            tree[@"time"] = params[@"time"]; tree[@"resolved_time"] = SKV4PTimeJSON(t,@"clip_local");
            [c.warnings addObject:@"Absent intrinsic components are reported without creating defaults. Units/coordinate metadata not established by the host are null/native_curve."];
            return tree;
        }
        id ch = nil; NSDictionary *leaf = SKV4PFindParameter(c,&ch);
        if ([op isEqual:@"describe"]) return leaf;
        CMTime t = SKV4PResolveTime(c);
        if ([op isEqual:@"get"]) return SKV4PParameterReadback(c,ch,t);
        SKV4PRequire(write,@"INVALID_ARGUMENT",@"Unknown parameter operation");
        NSDictionary *value = params[@"value"]; SKV4PValidateValue(ch,value);
        NSString *mode = [op isEqual:@"keyframe_set"] ? @"at_time" : params[@"mode"];
        SKV4PRequire([@[@"at_time",@"constant"] containsObject:mode ?: @""],@"INVALID_ARGUMENT",@"Explicit at_time or constant intent required");
        BOOL atTime = [mode isEqual:@"at_time"];
        if (atTime) SKV4PRequire([leaf[@"animatable"] boolValue],@"UNSUPPORTED_CAPABILITY",@"Channel is not animatable; string writes require constant mode");
        else if (![leaf[@"type"] isEqual:@"string"]) {
            if (SKV4PHas(ch,@"keyframeCount")) {
                NSUInteger count = ((NSUInteger (*)(id,SEL))objc_msgSend)(ch,NSSelectorFromString(@"keyframeCount"));
                SKV4PRequire(count == 0,@"ANIMATED_PARAMETER",@"constant mode cannot erase or replace existing keyframes");
            } else for (NSArray *keys in SKV4PKeyState(c,ch).allValues)
                SKV4PRequire(keys.count == 0,@"ANIMATED_PARAMETER",@"constant mode cannot erase or replace descendant keyframes");
        }
        NSDictionary *keyState = atTime ? SKV4PKeyState(c,ch) : nil;
        if (atTime && !((BOOL (*)(id,SEL,CMTime))objc_msgSend)(ch,NSSelectorFromString(@"hasKeyframeAtTime:"),t))
            SKV4PRequire([@[@"double",@"angle"] containsObject:value[@"type"]] && SKV4PHas(ch,@"appendKeyframes:times:values:"),
                @"UNSUPPORTED_KEYFRAME_INSERT", @"No calibrated native insertion for this channel type");
        NSDictionary *before = SKV4PRead(ch,t); c.readback = SKV4PParameterReadback(c,ch,t);
        [c beginMutation]; c.applied = NSNull.null;
        SKV4PChannelEdit(ch, ^{
        SKV4PWrite(ch,value,atTime ? t : kCMTimeIndefinite); c.applied = @YES;
        // options=0 updates an unanimated native value without inserting a key.
        // FCP 12.4 CHChannelDouble: appendKeyframes:times:values: is
        // v36@0:8I16^{?=qiIq}20^d28. Append exactly one missing scalar key;
        // existing keys are subsequently compared in full, including tangents.
        if (atTime && !((BOOL (*)(id,SEL,CMTime))objc_msgSend)(ch,NSSelectorFromString(@"hasKeyframeAtTime:"),t)) {
            SKV4PRequire([@[@"double",@"angle"] containsObject:value[@"type"]] &&
                SKV4PHas(ch,@"appendKeyframes:times:values:"), @"UNSUPPORTED_KEYFRAME_INSERT", @"No calibrated native insertion for this channel type");
            CMTime keyTime=t; double scalar = [value[@"value"] doubleValue];
            ((void (*)(id,SEL,unsigned,CMTime *,double *))objc_msgSend)(ch,
                NSSelectorFromString(@"appendKeyframes:times:values:"),1,&keyTime,&scalar);
        }
        });
        NSMutableDictionary *after = [SKV4PParameterReadback(c,ch,t) mutableCopy];
        after[@"before"] = before;
        BOOL verified = SKV4PValueEqual(after[@"value"],value) && (!atTime || ([after[@"has_keyframe"] boolValue] && SKV4PPreservesOtherKeys(keyState,SKV4PKeyState(c,ch),t)));
        after[@"verified"] = @(verified); c.readback = after;
        SKV4PRequire(verified,@"READBACK_MISMATCH",@"Stored typed value or exact-time keyframe differs; inspect before retrying");
        c.afterCommit = ^NSDictionary *(SKV4PContext *context) {
            NSMutableDictionary *final = [SKV4PParameterReadback(context,ch,t) mutableCopy];
            final[@"before"] = before;
            BOOL matches = SKV4PValueEqual(final[@"value"],value) && (!atTime || ([final[@"has_keyframe"] boolValue] && SKV4PPreservesOtherKeys(keyState,SKV4PKeyState(context,ch),t)));
            final[@"verified"] = @(matches); context.readback = final;
            SKV4PRequire(matches,@"READBACK_MISMATCH",@"Native group close changed the value or exact-time keyframe");
            return final;
        };
        return after;
    });
}

void SpliceKitV4_registerParameters(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        for (NSString *op in @[@"catalog",@"add",@"remove",@"enable",@"move"]) {
            NSString *method = [@"v4.effect." stringByAppendingString:op];
            SpliceKit_registerPluginMethod(method,^NSDictionary *(NSDictionary *p){return SpliceKitV4_handleEffect(op,p);},
                @{@"description":@"Identity-bound effect catalog/lifecycle; full schema: capabilities/params.json",@"readOnly":@([op isEqual:@"catalog"]),@"params":@[],@"evidence_level":@"offline_tested"});
        }
        for (NSString *op in @[@"inspect",@"describe",@"get",@"set"]) {
            NSString *method = [op isEqual:@"inspect"] ? @"v4.object.inspect" : [@"v4.parameter." stringByAppendingString:op];
            SpliceKit_registerPluginMethod(method,^NSDictionary *(NSDictionary *p){return SpliceKitV4_handleParameter(op,p);},
                @{@"description":@"Typed native parameter tree; full schema: capabilities/params.json",@"readOnly":@((BOOL)![op isEqual:@"set"]),@"params":@[],@"evidence_level":@"offline_tested"});
        }
        for (NSString *op in @[@"list",@"set",@"delete",@"set_interpolation"])
            SpliceKit_registerPluginMethod([@"v4.keyframe." stringByAppendingString:op],^NSDictionary *(NSDictionary *p){return SpliceKitV4_handleKeyframe(op,p);},
                @{@"description":@"Exact-channel/time native keyframes; full schema: capabilities/params.json",@"readOnly":@([op isEqual:@"list"]),@"params":@[],@"evidence_level":@"offline_tested"});
    });
}
#ifndef SPLICEKIT_V4_PARAMS_TEST
__attribute__((constructor)) static void SpliceKitV4Parameters_init(void) {
    @autoreleasepool { dispatch_async(dispatch_get_main_queue(), ^{ SpliceKitV4_registerParameters(); }); }
}
#endif
