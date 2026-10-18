// Keyframe pointers are used only within one main-thread call; never exported as handles.
#import "SpliceKitV4Parameters.h"
#import <objc/message.h>

static void *SKV4PKeyAt(id ch, CMTime t) {
    SKV4PRequire(SKV4PHas(ch,@"keyframeAtTime:"),@"UNSUPPORTED_CAPABILITY",@"Native keyframe lookup unavailable");
    return ((void *(*)(id,SEL,CMTime))objc_msgSend)(ch,NSSelectorFromString(@"keyframeAtTime:"),t);
}
NSArray *SKV4PListKeys(SKV4PContext *c, id ch) {
    for (NSString *s in @[@"firstKeyframe",@"nextKeyframe:",@"getKeyframe:time:"])
        SKV4PRequire(SKV4PHas(ch,s),@"UNSUPPORTED_CAPABILITY",@"Native keyframe iteration unavailable; use scalar child channels for compound curves");
    NSMutableArray *keys = [NSMutableArray array]; NSMutableSet *seen = [NSMutableSet set];
    void *key = ((void *(*)(id,SEL))objc_msgSend)(ch,NSSelectorFromString(@"firstKeyframe"));
    while (key) {
        SKV4PRequire(keys.count<10000 && ![seen containsObject:[NSValue valueWithPointer:key]],@"INSPECTION_LIMIT",@"Native keyframe traversal exceeded its bound or repeated a pointer");
        [seen addObject:[NSValue valueWithPointer:key]];
        CMTime local;
        BOOL got = ((BOOL (*)(id,SEL,void *,CMTime *))objc_msgSend)(ch,NSSelectorFromString(@"getKeyframe:time:"),key,&local);
        SKV4PRequire(got,@"INVALID_NATIVE_VALUE",@"Native keyframe time unavailable"); SKV4PTimeJSON(local,@"clip_local");
        CMTime requested = [c.params[@"time"][@"space"] isEqual:@"timeline"] ? SKV4PConvertTime(c.clip,@"localToContainerTime:container:",local,c.sequenceRoot) : local;
        id interpolation = SKV4PHas(ch,@"segmentInterpolation:") ? @(((unsigned (*)(id,SEL,void *))objc_msgSend)(ch,NSSelectorFromString(@"segmentInterpolation:"),key)) : (id)NSNull.null;
        [keys addObject:@{@"time":SKV4PTimeJSON(requested,c.params[@"time"][@"space"]),@"resolved_time":SKV4PTimeJSON(local,@"clip_local"),@"value":SKV4PRead(ch,local),@"native_interpolation":interpolation}];
        key = ((void *(*)(id,SEL,void *))objc_msgSend)(ch,NSSelectorFromString(@"nextKeyframe:"),key);
    }
    return keys;
}
// Compound values use their native scalar descendants for curve preservation checks.
static void SKV4PCollectKeyState(SKV4PContext *c, id ch, NSString *path, NSMutableDictionary *state, NSUInteger depth) {
    SKV4PRequire(depth<32 && state.count<10000,@"INSPECTION_LIMIT",@"Compound keyframe state exceeded traversal bounds");
    if (SKV4PHas(ch,@"firstKeyframe") && SKV4PHas(ch,@"nextKeyframe:") && SKV4PHas(ch,@"getKeyframe:time:")) {
        state[path] = SKV4PListKeys(c,ch); return;
    }
    NSArray *children = SKV4PArray(SKV4PObject(ch,@"children"));
    SKV4PRequire(children.count>0,@"UNSUPPORTED_CAPABILITY",@"Cannot prove preservation of this native curve; edit discovered scalar children");
    for (id child in children) {
        SKV4PRequire(SKV4PHas(child,@"channelID"),@"UNSUPPORTED_CAPABILITY",@"Curve descendant has no stable native identity");
        unsigned cid = ((unsigned (*)(id,SEL))objc_msgSend)(child,NSSelectorFromString(@"channelID"));
        SKV4PCollectKeyState(c,child,[path stringByAppendingFormat:@"/%u",cid],state,depth+1);
    }
}
NSDictionary *SKV4PKeyState(SKV4PContext *c, id ch) {
    NSMutableDictionary *state = [NSMutableDictionary dictionary];
    SKV4PCollectKeyState(c,ch,@"",state,0); return state;
}
BOOL SKV4PPreservesOtherKeys(NSDictionary *before, NSDictionary *after, CMTime edited) {
    if (![before.allKeys isEqualToArray:after.allKeys] && ![[NSSet setWithArray:before.allKeys] isEqual:[NSSet setWithArray:after.allKeys]]) return NO;
    for (NSString *path in before) {
        NSMutableArray *old = [NSMutableArray array], *now = [NSMutableArray array];
        for (NSDictionary *row in before[path]) if (CMTimeCompare(SKV4PParseTime(row[@"resolved_time"]),edited)!=0) [old addObject:row];
        for (NSDictionary *row in after[path]) if (CMTimeCompare(SKV4PParseTime(row[@"resolved_time"]),edited)!=0) [now addObject:row];
        if (![old isEqual:now]) return NO;
    }
    return YES;
}
NSDictionary *SpliceKitV4_handleKeyframe(NSString *op, NSDictionary *params) {
    if ([op isEqual:@"set"]) return SpliceKitV4_handleParameter(@"keyframe_set",params);
    return SKV4PRun(params,[@"v4.keyframe." stringByAppendingString:op],![op isEqual:@"list"],^NSDictionary *(SKV4PContext *c){
        [c resolveTarget]; id ch = nil; NSDictionary *leaf = SKV4PFindParameter(c,&ch);
        CMTime t = SKV4PResolveTime(c);
        SKV4PRequire([leaf[@"animatable"] boolValue],@"UNSUPPORTED_CAPABILITY",@"Channel does not expose native keyframes");
        if ([op isEqual:@"list"]) return @{@"target":params[@"target"],@"parameter_path":params[@"parameter_path"],@"time":params[@"time"],@"keyframes":SKV4PListKeys(c,ch)};
        void *key = SKV4PKeyAt(ch,t);
        if ([op isEqual:@"delete"]) {
            if (!key) return @{@"target":params[@"target"],@"parameter_path":params[@"parameter_path"],@"time":params[@"time"],@"deleted":@NO,@"keyframes":SKV4PListKeys(c,ch)};
            SKV4PRequire(SKV4PHas(ch,@"removeKeyframeAtTime:"),@"UNSUPPORTED_CAPABILITY",@"Native exact-time delete unavailable");
            NSArray *before = SKV4PListKeys(c,ch); c.readback = @{@"keyframes":before};
            [c beginMutation]; c.applied = NSNull.null;
            __block BOOL removed; SKV4PChannelEdit(ch, ^{ removed = ((BOOL (*)(id,SEL,CMTime))objc_msgSend)(ch,NSSelectorFromString(@"removeKeyframeAtTime:"),t); }); c.applied = @YES;
            NSArray *after = SKV4PListKeys(c,ch);
            c.readback = @{@"target":params[@"target"],@"parameter_path":params[@"parameter_path"],@"time":params[@"time"],@"deleted":@(removed),@"keyframes":after};
            SKV4PRequire(removed && !SKV4PKeyAt(ch,t) && after.count+1==before.count && SKV4PPreservesOtherKeys(@{@"":before},@{@"":after},t),@"READBACK_MISMATCH",@"Exact keyframe deletion could not be confirmed");
        } else if ([op isEqual:@"set_interpolation"]) {
            // Verified from ProChannel arm64 getInterpolator jump table + strategy constructors.
            // 0 = OZConstantInterpolator, 1 = OZLinearInterpolator, 21 = OZSCurveInterpolator.
            // S-curve is an ease-in/out segment, not an alias for FCP's spatial Smooth tangents.
            NSDictionary *modes = @{@"hold":@0,@"linear":@1,@"ease_in_out":@21};
            NSNumber *mode = [params[@"interpolation"] isKindOfClass:NSString.class] ? modes[params[@"interpolation"]] : nil;
            SKV4PRequire(mode && [leaf[@"interpolations"] containsObject:params[@"interpolation"]],@"UNSUPPORTED_CAPABILITY",@"Only scalar linear, hold and engine S-curve ease_in_out are currently verified; spatial smooth is unavailable");
            SKV4PRequire(key && SKV4PHas(ch,@"setSegmentInterpolation:interpolation:") && SKV4PHas(ch,@"segmentInterpolation:"),@"KEYFRAME_NOT_FOUND",@"Existing scalar keyframe and native segment interpolation required");
            // Capture precondition and all keys before the first native mutation.
            NSArray *before = SKV4PListKeys(c,ch); c.readback = @{@"keyframes":before};
            [c beginMutation]; c.applied = NSNull.null;
            SKV4PChannelEdit(ch, ^{ ((void (*)(id,SEL,void *,unsigned))objc_msgSend)(ch,NSSelectorFromString(@"setSegmentInterpolation:interpolation:"),key,mode.unsignedIntValue); }); c.applied = @YES;
            key = SKV4PKeyAt(ch,t);
            SKV4PRequire(key != NULL,@"READBACK_MISMATCH",@"Keyframe disappeared during interpolation write");
            unsigned actual = ((unsigned (*)(id,SEL,void *))objc_msgSend)(ch,NSSelectorFromString(@"segmentInterpolation:"),key);
            c.readback = @{@"target":params[@"target"],@"parameter_path":params[@"parameter_path"],@"time":params[@"time"],@"native_interpolation":@(actual),@"keyframes":SKV4PListKeys(c,ch)};
            SKV4PRequire(actual==mode.unsignedIntValue,@"READBACK_MISMATCH",@"Native interpolation differs from requested mode");
        } else SKV4PRequire(NO,@"INVALID_ARGUMENT",@"Unknown keyframe operation");
        NSDictionary *expectedReadback = c.readback;
        c.afterCommit = ^NSDictionary *(SKV4PContext *context) {
            NSArray *keys = SKV4PListKeys(context,ch);
            NSMutableDictionary *final = [expectedReadback mutableCopy]; final[@"keyframes"] = keys;
            context.readback = final;
            SKV4PRequire([keys isEqual:expectedReadback[@"keyframes"]],@"READBACK_MISMATCH",@"Native group close changed keyframe state");
            return final;
        };
        return c.readback;
    });
}
