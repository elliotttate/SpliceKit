// Native media contract tests. This executable links no FCP/SpliceKit binary.
#import "SpliceKitV4Media.h"
#include <stdio.h>
#include <math.h>

static NSMutableDictionary *handlers, *metadata;
static NSMutableArray *checks, *calls;
static BOOL coreExecuting = YES, failParameterSet = NO, anonymousTimeABI = NO;
static NSUInteger parameterWrites;
BOOL SpliceKitV4IsExecuting(void) { return coreExecuting; }
void SpliceKit_log(NSString *format, ...) {}
void SpliceKit_executeOnMainThread(dispatch_block_t block) { block(); }
NSString *SpliceKit_storeHandle(id object) { return @"unused"; }
id SpliceKit_resolveHandle(NSString *handle) { return nil; }
void SpliceKit_registerPluginMethod(NSString *name, SpliceKitMethodHandler handler, NSDictionary *meta) {
    handlers[name] = [handler copy]; metadata[name] = meta;
}

static void Check(NSString *name, BOOL passed) {
    [checks addObject:@{@"name": name, @"passed": @(passed)}];
}

@interface MockOwner : NSObject
@property NSUInteger opens, closes, snapshots;
@end
@implementation MockOwner
- (void)actionBegin:(id)label animationHint:(id)hint deferUpdates:(BOOL)defer { self.opens++; }
- (BOOL)actionEnd:(id)label save:(BOOL)save error:(NSError **)error { self.closes++; return YES; }
- (id)storeForUndo { self.snapshots++; return self; }
@end

@interface MockChannel : NSObject
@property double gain;
@property BOOL clamp, throws;
@property NSUInteger opens, closes;
@property NSMutableDictionary *keys;
@end
@implementation MockChannel
- (instancetype)init { if ((self = [super init])) { _gain = 1; _keys = [NSMutableDictionary dictionary]; } return self; }
- (NSString *)key:(CMTime)t { return [NSString stringWithFormat:@"%.9f", CMTimeGetSeconds(t)]; }
- (NSUInteger)keyframeCount { return self.keys.count; }
- (BOOL)hasKeyframeAtTime:(CMTime)t { return self.keys[[self key:t]] != nil; }
- (double)curveDoubleValueAtTime:(CMTime)t { return self.keys[[self key:t]] ? [self.keys[[self key:t]] doubleValue] : self.gain; }
- (void)setCurveDoubleValue:(double)v atTime:(CMTime)t options:(unsigned int)options {
    if (self.throws) @throw [NSException exceptionWithName:@"MOCK_WRITE_FAILED" reason:@"injected failure" userInfo:nil];
    if (self.clamp) v = 0.25;
    if (CMTIME_IS_INDEFINITE(t)) self.gain = v; else self.keys[[self key:t]] = @(v);
}
- (void)operationBegin { self.opens++; }
- (void)operationEnd { self.closes++; }
@end

@interface MockMap : NSObject <NSCopying>
@property NSMutableArray *enabled;
@end
@implementation MockMap
- (instancetype)init { if ((self = [super init])) _enabled = [@[@YES, @YES] mutableCopy]; return self; }
- (id)copyWithZone:(NSZone *)zone { MockMap *m = [MockMap new]; m.enabled = self.enabled.mutableCopy; return m; }
- (unsigned int)channelCount { return (unsigned int)self.enabled.count; }
- (BOOL)isChannelEnabled:(unsigned int)i { return [self.enabled[i] boolValue]; }
- (void)setEnabled:(BOOL)v forChannel:(unsigned int)i { self.enabled[i] = @(v); }
@end

@interface MockEffect : MockOwner
@property int presetID;
@end
@implementation MockEffect
- (NSString *)fileUUID { return @"effect-1"; }
- (void)setFactoryPreset:(int)i { self.presetID = i; }
@end

@interface MockStack : MockOwner
@property MockChannel *channel;
@property NSArray *effects;
@property double rate;
@property BOOL frozen, ramp;
@end
@implementation MockStack
- (instancetype)init { if ((self = [super init])) { _channel = [MockChannel new]; _rate = 1; _effects = @[[MockEffect new]]; } return self; }
- (id)audioLevelChannel { return self.channel; }
- (double)constantRetimingRate { return self.rate; }
- (int)retimingSegmentCount { return self.frozen || self.ramp ? 3 : 1; }
- (CMTime)mediaTimeFromComponentTime:(CMTime)t {
    double source = self.frozen ? 110 : 100 + CMTimeGetSeconds(t) * self.rate;
    if (self.ramp) source += pow(CMTimeGetSeconds(t) - 10, 2) / 10;
    return CMTimeMakeWithSeconds(source, 30000);
}
@end

@interface MockClip : MockOwner
@property MockStack *stack;
@property id audioChannelMap;
@property NSString *audioRoleIdentifier;
@property CMTimeRange range;
@property CMTime fadeIn, fadeOut;
@end
@implementation MockClip
- (NSMethodSignature *)methodSignatureForSelector:(SEL)selector {
    if (anonymousTimeABI && selector == @selector(clippedRange))
        return [NSMethodSignature signatureWithObjCTypes:"{?={?=qiIq}{?=qiIq}}16@0:8"];
    return [super methodSignatureForSelector:selector];
}
- (instancetype)init {
    if ((self = [super init])) { _stack = [MockStack new]; _audioChannelMap = [MockMap new]; _audioRoleIdentifier = @"dialogue";
        _range = CMTimeRangeMake(CMTimeMake(10, 1), CMTimeMake(8, 1)); _fadeIn = kCMTimeZero; _fadeOut = kCMTimeZero; }
    return self;
}
- (NSString *)persistentID { return @"clip-1"; }
- (id)effectStack { return self.stack; }
- (unsigned int)nativeAudioChannelCount:(int)identifier { return [self.audioChannelMap isKindOfClass:NSArray.class] ? [self.audioChannelMap count] : 2; }
- (NSNumber *)metadataAudioChannelCount { return @2; }
- (id)audioEffectsForIdentifier:(unsigned long long)i { return i == 0 ? self.stack : nil; }
- (CMTimeRange)clippedRange { return self.range; }
- (CMTime)containerToLocalTime:(CMTime)t container:(id)container { return CMTimeAdd(CMTimeSubtract(t, CMTimeMake(100, 1)), self.range.start); }
- (CMTime)localToContainerTime:(CMTime)t container:(id)container { return CMTimeAdd(CMTimeSubtract(t, self.range.start), CMTimeMake(100, 1)); }
@end

@interface MockRoot : NSObject
@property NSSet *anchoredItems;
@property NSArray *containedItems;
@end
@implementation MockRoot @end

@interface MockRole : NSObject
@property int roleType;
@property NSString *uid;
@end
@implementation MockRole @end

@interface MockPresetUndo : NSObject
@property NSUInteger actionLevel;
@end
@implementation MockPresetUndo
- (BOOL)undoableEnd:(id)info save:(BOOL)save error:(NSError **)error { self.actionLevel--; return YES; }
@end
@interface MockSequence : NSObject
@property MockPresetUndo *undoHandler;
@property MockRoot *primaryObject;
@end
@implementation MockSequence
- (instancetype)init { if((self=[super init])) self.undoHandler=[MockPresetUndo new];return self; }
- (id)modelDocument { return self; }
- (BOOL)actionRetimeSetRatePreset:(NSArray *)clips rate:(double)rate ripple:(BOOL)ripple
    allowVariableSpeedRetiming:(BOOL)variable objectsAndNewRanges:(id *)ranges error:(NSError **)error {
    self.undoHandler.actionLevel++;
    MockClip *c = clips.firstObject;
    if (ripple) c.range = CMTimeRangeMake(c.range.start, CMTimeMultiplyByFloat64(c.range.duration, c.stack.rate / rate));
    c.stack.rate = rate; return YES;
}
- (BOOL)actionRetimeReverseClipPreset:(NSArray *)clips error:(NSError **)error {
    self.undoHandler.actionLevel++;
    ((MockClip *)clips.firstObject).stack.rate *= -1; return YES;
}
- (BOOL)actionRetimeHoldPreset:(NSArray *)clips holdComponentTime:(CMTime)t duration:(CMTime)d newHoldComponentTime:(CMTime *)out error:(NSError **)error {
    self.undoHandler.actionLevel++;
    ((MockClip *)clips.firstObject).stack.frozen = YES; *out = t; return YES;
}
- (BOOL)actionRetimeSpeedRampPreset:(NSArray *)clips startComponentTime:(CMTime)start endComponentTime:(CMTime)end
    toZero:(BOOL)toZero fromZero:(BOOL)fromZero error:(NSError **)error {
    self.undoHandler.actionLevel++;
    ((MockClip *)clips.firstObject).stack.ramp = YES; return YES;
}
- (BOOL)actionAddRole:(MockRole *)role toItems:(NSArray *)clips error:(NSError **)error {
    ((MockClip *)clips.firstObject).audioRoleIdentifier = role.uid; return YES;
}
@end

@interface MockTimeline : NSObject
@property MockSequence *sequence;
@end
@implementation MockTimeline @end
static MockTimeline *timeline;
id SpliceKit_getActiveTimelineModule(void) { return timeline; }

@interface FFAudioFadeUtilities : NSObject @end
@implementation FFAudioFadeUtilities
+ (void)setAudioFadeInWithDuration:(float)s forItem:(MockClip *)c { c.fadeIn = CMTimeMakeWithSeconds(s, 30000); }
+ (void)setAudioFadeOutWithDuration:(float)s forItem:(MockClip *)c { c.fadeOut = CMTimeMakeWithSeconds(s, 30000); }
+ (CMTime)audioFadeInDurationForItem:(MockClip *)c { return c.fadeIn; }
+ (CMTime)audioFadeOutDurationForItem:(MockClip *)c { return c.fadeOut; }
@end
@interface FFEffect : NSObject @end
@implementation FFEffect
+ (NSString *)effectTypeForEffectID:(NSString *)eid { return [eid isEqual:@"audio-id"] ? @"effect.audio.effect" : @"effect.video.filter"; }
@end
@interface MockLibrary : NSObject @end
@implementation MockLibrary
- (id)findRoleWithUID:(NSString *)uid {
    if (![@[@"dialogue", @"music", @"video"] containsObject:uid]) return nil;
    MockRole *role = [MockRole new]; role.uid = uid; role.roleType = [uid isEqual:@"video"] ? 2 : 1; return role;
}
@end
@interface FFLibraryDocument : NSObject @end
@implementation FFLibraryDocument
+ (NSArray *)copyActiveLibraries { return @[[MockLibrary new]]; }
@end

NSDictionary *SpliceKit_handleRequest(NSDictionary *request) {
    [calls addObject:request];
    NSString *method = request[@"method"];
    NSDictionary *p = request[@"params"], *readback;
    if ([method isEqual:@"v4.parameter.describe"]) readback = @{@"type": @"double", @"writable": @YES};
    else if ([method isEqual:@"v4.parameter.set"]) {
        parameterWrites++;
        if (failParameterSet && parameterWrites == 2) return @{@"result": SKMResult(p, NO, nil, nil, @"INJECTED", @"second parameter failed")};
        readback = @{@"target": p[@"target"], @"parameter_path": p[@"parameter_path"], @"time": p[@"time"], @"value": p[@"value"], @"verified": @YES};
    } else if ([method isEqual:@"v4.effect.add"]) readback = @{@"target": @{@"clip_id": @"clip-1", @"effect_instance_id": @"created-effect"}, @"effects": @[]};
    else if ([method isEqual:@"v4.object.inspect"]) readback = @{@"target": p[@"target"], @"components": @[], @"effects": @[]};
    else return @{@"error": @{@"code": @(-32601), @"message": @"missing dependency"}};
    return @{@"result": SKMResult(p, YES, @([method hasSuffix:@"set"] || [method hasSuffix:@"add"]), readback, nil, nil)};
}

static NSDictionary *Target(void) { return @{@"clip_id": @"clip-1"}; }
static NSDictionary *Time(long long value, int scale) { return @{@"value": @(value), @"timescale": @(scale)}; }
static NSDictionary *ParameterTime(void) { return @{@"value": @102, @"timescale": @1, @"space": @"timeline"}; }
static NSDictionary *Invoke(NSString *name, NSDictionary *p) {
    return ((SpliceKitMethodHandler)handlers[name])(p);
}
static BOOL OK(NSDictionary *r) { return [r[@"ok"] boolValue]; }
static BOOL Code(NSDictionary *r, NSString *code) { return [r[@"error"] isKindOfClass:[NSDictionary class]] && [r[@"error"][@"code"] isEqual:code]; }

int main(void) {
    @autoreleasepool {
        handlers = [NSMutableDictionary dictionary]; metadata = [NSMutableDictionary dictionary]; checks = [NSMutableArray array]; calls = [NSMutableArray array];
        MockClip *clip = [MockClip new]; MockRoot *root = [MockRoot new]; root.containedItems = @[clip];
        MockSequence *seq = [MockSequence new]; seq.primaryObject = root;
        timeline = [MockTimeline new]; timeline.sequence = seq;
        root.containedItems=@[];root.anchoredItems=[NSSet setWithObject:clip];
        Check(@"exact-identity-finds-anchored-audio", SKMClip(@{@"target":Target()})==clip);
        root.containedItems=@[clip];root.anchoredItems=nil;
        SpliceKitV4RegisterColor(); SpliceKitV4RegisterAudio(); SpliceKitV4RegisterRetime(); SpliceKitV4RegisterAnalysis();
        Check(@"all-18-RPCs-registered", handlers.count == 18);
        Check(@"analysis-cancel-has-no-project-undo", [metadata[@"v4.analysis.cancel"][@"v4Undo"] isEqual:@"none"]);
        Check(@"analysis-status-survives-no-sequence", ![metadata[@"v4.analysis.status"][@"v4RequiresSequence"] boolValue]);
        CMTime t; Check(@"rational-rejects-bool", !SKMTime(@{@"value": @YES, @"timescale": @30}, &t));
        Check(@"rational-rejects-float", !SKMTime(@{@"value": @1.1, @"timescale": @30}, &t));
        Check(@"rational-rejects-invalid-scale", !SKMTime(Time(1, 0), &t));
        Check(@"rational-preserves-2997", SKMTime(Time(1001, 30000), &t) && t.value == 1001 && t.timescale == 30000);
        NSDictionary *gain = @{@"target": Target(), @"gain_db": @(-6), @"mode": @"constant", @"time": ParameterTime()};
        coreExecuting = NO;
        Check(@"mutation-needs-core", Code(Invoke(@"v4.audio.set_gain", gain), @"CORE_REQUIRED"));
        coreExecuting = YES;
        NSDictionary *r = Invoke(@"v4.audio.set_gain", gain);
        Check(@"dB-converts-to-linear", OK(r) && fabs(clip.stack.channel.gain - pow(10, -6.0/20)) < 1e-10);
        Check(@"gain-resolves-trimmed-timeline-time", [r[@"readback"][@"resolved_time"][@"value"] longLongValue] == 12);
        Check(@"gain-transaction-balanced", clip.stack.opens == clip.stack.closes && clip.stack.snapshots > 0);
        Check(@"success-error-is-JSON-null", r[@"error"] == NSNull.null);
        NSMutableDictionary *key = gain.mutableCopy; key[@"mode"] = @"keyframe";
        r = Invoke(@"v4.audio.set_gain", key);
        Check(@"gain-writes-exact-keyframe", OK(r) && [r[@"readback"][@"has_keyframe"] boolValue]);
        Check(@"constant-does-not-erase-automation", Code(Invoke(@"v4.audio.set_gain", gain), @"ANIMATED_PARAMETER") && clip.stack.channel.keys.count == 1);
        clip.stack.channel.clamp = YES;
        r = Invoke(@"v4.audio.set_gain", key);
        Check(@"gain-readback-mismatch-is-applied-error", Code(r, @"READBACK_MISMATCH") && [r[@"applied"] boolValue]);
        clip.stack.channel.clamp = NO; clip.stack.channel.throws = YES;
        r = Invoke(@"v4.audio.set_gain", key);
        Check(@"partial-native-exception-stays-unknown", !OK(r) && r[@"applied"] == NSNull.null);
        Check(@"native-exception-closes-operations", clip.stack.opens == clip.stack.closes && clip.stack.channel.opens == clip.stack.channel.closes);
        clip.stack.channel.throws = NO;
        NSMutableDictionary *bad = gain.mutableCopy; bad[@"target"] = @{@"clip_id": @"missing"};
        Check(@"missing-clip-never-falls-back-to-selection", Code(Invoke(@"v4.audio.set_gain", bad), @"TARGET_MISMATCH"));
        root.containedItems = @[clip, [MockClip new]];
        Check(@"duplicate-native-clip-ID-is-rejected", Code(Invoke(@"v4.audio.set_gain", gain), @"TARGET_MISMATCH"));
        root.containedItems = @[clip];
        r = Invoke(@"v4.audio.fade", @{@"target": Target(), @"edge": @"in", @"duration": Time(1, 2)});
        Check(@"fade-native-float-write-rational-read", OK(r) && CMTimeCompare(clip.fadeIn, CMTimeMake(1, 2)) == 0);
        Check(@"fade-rejects-unverified-curve", Code(Invoke(@"v4.audio.fade", @{@"target": Target(), @"edge": @"in", @"duration": Time(1, 2), @"curve": @"linear"}), @"UNSUPPORTED_FADE_CURVE"));
        r = Invoke(@"v4.audio.set_channel_map", @{@"target": Target(), @"enabled": @[@YES, @NO]});
        Check(@"channel-map-copies-and-reads-back", OK(r) && [[clip.audioChannelMap enabled] isEqual:@[@YES, @NO]]);
        clip.audioChannelMap=@[@0,@1];
        r = Invoke(@"v4.audio.set_channel_map", @{@"target": Target(), @"enabled": @[@YES, @NO]});
        Check(@"native-index-array-keeps-source-channel-count", OK(r) && [clip.audioChannelMap isEqual:@[@0]] && [r[@"readback"][@"after"][@"channel_count"] intValue]==2);
        clip.audioChannelMap=@[@1,@0];
        Check(@"reordered-index-map-is-fenced", Code(Invoke(@"v4.audio.get_channel_map", @{@"target":Target()}), @"UNSUPPORTED_ROUTING"));
        clip.audioChannelMap=[MockMap new];
        Check(@"channel-map-rejects-numeric-booleans", Code(Invoke(@"v4.audio.set_channel_map", @{@"target": Target(), @"enabled": @[@1, @0]}), @"INVALID_PARAMS"));
        r = Invoke(@"v4.audio.set_role", @{@"target": Target(), @"role_uid": @"music"});
        Check(@"role-command-reads-back-exact-UID", OK(r) && [clip.audioRoleIdentifier isEqual:@"music"]);
        Check(@"audio-role-rejects-video-role", Code(Invoke(@"v4.audio.set_role", @{@"target": Target(), @"role_uid": @"video"}), @"WRONG_ROLE_TYPE"));
        r = Invoke(@"v4.audio.inspect", @{@"target": Target(), @"time": ParameterTime()});
        Check(@"independent-audio-inspector", OK(r) && [r[@"readback"][@"keyframe_count"] unsignedIntegerValue] == 1);
        NSDictionary *effectTarget = @{@"clip_id": @"clip-1", @"effect_instance_id": @"effect-1"};
        r = Invoke(@"v4.audio.apply_preset", @{@"target": effectTarget, @"factory_preset_id": @3});
        Check(@"factory-preset-exact-instance", OK(r) && ((MockEffect *)clip.stack.effects.firstObject).presetID == 3);
        Check(@"audio-effect-rejects-video-ID", Code(Invoke(@"v4.audio.effect.add", @{@"target": Target(), @"effect_id": @"video-id"}), @"WRONG_EFFECT_TYPE"));
        Check(@"audio-effect-delegates-full-ID", OK(Invoke(@"v4.audio.effect.add", @{@"target": Target(), @"effect_id": @"audio-id"})));
        NSDictionary *named = @{@"target": effectTarget, @"family": @"board", @"time": ParameterTime(),
            @"bindings": @{@"exposure.master": @"/effects/effect-1/channels/1", @"saturation.master": @"/effects/effect-1/channels/2"},
            @"adjustments": @{@"exposure.master": @{@"type": @"double", @"value": @0.1}, @"saturation.master": @{@"type": @"double", @"value": @0.9}}};
        [calls removeAllObjects]; parameterWrites = 0;
        r = Invoke(@"v4.color.apply_adjustment", named);
        Check(@"named-color-uses-shared-type-path-contract", OK(r) && parameterWrites == 2 && [calls[2][@"params"][@"value"][@"type"] isEqual:@"double"]);
        Check(@"all-named-describes-precede-writes", [calls[0][@"method"] isEqual:@"v4.parameter.describe"] && [calls[1][@"method"] isEqual:@"v4.parameter.describe"]);
        NSMutableDictionary *invalidNamed = named.mutableCopy;
        invalidNamed[@"adjustments"] = @{@"exposure.master": @{@"type": @"double", @"value": @0.1},
            @"saturation.master": @{@"type": @"double", @"value": @YES}};
        parameterWrites = 0;
        Check(@"all-named-values-validated-before-any-write", Code(Invoke(@"v4.color.apply_adjustment", invalidNamed), @"INVALID_PARAMS") && parameterWrites == 0);
        parameterWrites = 0; failParameterSet = YES;
        r = Invoke(@"v4.color.apply_adjustment", named);
        Check(@"partial-named-write-retains-readback", !OK(r) && r[@"applied"] == NSNull.null && [r[@"readback"][@"completed_parameter_readbacks"] count] == 1);
        failParameterSet = NO;
        Check(@"custom-curves-never-scalar-write", Code(Invoke(@"v4.color.apply_adjustment", @{@"target": effectTarget, @"family": @"curves"}), @"UNSUPPORTED_CUSTOM_CURVE"));
        r = Invoke(@"v4.color.inspect", @{@"target": effectTarget, @"family": @"wheels", @"time": ParameterTime()});
        Check(@"color-inspect-honest-preview-metadata", OK(r) && r[@"readback"][@"preview_color_space"] == NSNull.null);
        r = Invoke(@"v4.color.apply_adjustment", @{@"target": Target(), @"family": @"board", @"create_effect_id": @"FULL:ColorBoard"});
        Check(@"color-creation-returns-native-instance", OK(r) && [r[@"readback"][@"target"][@"effect_instance_id"] isEqual:@"created-effect"]);
        r = Invoke(@"v4.audio.effect.configure", @{@"target": effectTarget, @"time": ParameterTime(),
            @"bindings": @{@"band.1.gain": @"/effects/effect-1/channels/8"}, @"adjustments": @{@"band.1.gain": @{@"type": @"double", @"value": @(-2)}}});
        Check(@"EQ-bands-use-discovered-native-paths", OK(r));
        r = Invoke(@"v4.audio.ducking.plan", @{@"target": Target(), @"dialogue_targets": @[Target()], @"duck_db": @(-12)});
        Check(@"ducking-plan-is-not-execution", OK(r) && ![r[@"readback"][@"execution_supported"] boolValue] && ![r[@"applied"] boolValue]);
        r = Invoke(@"v4.retime.inspect", @{@"target": Target(), @"samples": @[Time(102, 1)]});
        Check(@"retime-uses-native-source-timeline-conversion", OK(r) && [r[@"readback"][@"source_timeline_map"][0][@"source_time"][@"value"] longLongValue] == 3360000);
        anonymousTimeABI = YES;
        Check(@"retime-preset-closes-native-action-scope",seq.undoHandler.actionLevel==0);
        Check(@"nested-anonymous-FCP-struct-ABI-matches", OK(Invoke(@"v4.retime.inspect", @{@"target": Target()})));
        anonymousTimeABI = NO;
        Check(@"retime-samples-outside-clip-rejected", Code(Invoke(@"v4.retime.inspect", @{@"target": Target(), @"samples": @[Time(50, 1)]}), @"OUT_OF_RANGE"));
        Check(@"retime-requires-explicit-ripple", Code(Invoke(@"v4.retime.set", @{@"target": Target(), @"mode": @"constant", @"rate": @2}), @"INVALID_PARAMS"));
        r = Invoke(@"v4.retime.set", @{@"target": Target(), @"mode": @"constant", @"rate": @2, @"ripple": @YES});
        Check(@"constant-retime-reads-rate-and-duration", OK(r) && clip.stack.rate == 2 && CMTimeCompare(clip.range.duration, CMTimeMake(4, 1)) == 0);
        r = Invoke(@"v4.retime.set", @{@"target": Target(), @"mode": @"reverse"});
        Check(@"reverse-has-native-map-readback", OK(r) && clip.stack.rate == -2);
        r = Invoke(@"v4.retime.set", @{@"target": Target(), @"mode": @"freeze", @"component_time": Time(11, 1), @"duration": Time(1, 1)});
        Check(@"freeze-passes-real-CMTime-ABI", OK(r) && clip.stack.frozen);
        clip.stack.frozen = NO;
        r = Invoke(@"v4.retime.set", @{@"target": Target(), @"mode": @"ramp", @"component_time": Time(10, 1), @"duration": Time(2, 1), @"direction": @"to_zero"});
        Check(@"ramp-passes-real-CMTime-ABI", OK(r) && clip.stack.ramp);
        Check(@"arbitrary-piecewise-does-not-pretend-support", Code(Invoke(@"v4.retime.set", @{@"target": Target(), @"mode": @"piecewise"}), @"UNSUPPORTED_RETIME_MODE"));
        for (NSString *kind in @[@"object_tracker", @"shape_mask", @"magnetic_mask", @"auto_mask", @"smart_conform", @"stabilizer"]) {
            r = Invoke(@"v4.analysis.start", @{@"target": Target(), @"kind": kind, @"component_range": @{@"start": Time(10, 1), @"duration": Time(2, 1)}});
            Check([@"analysis-blocks-unverified-" stringByAppendingString:kind], Code(r, @"UNSUPPORTED_ANALYSIS_ADAPTER") && ![r[@"readback"][@"native_started"] boolValue]);
            NSDictionary *job = @{@"job_id": r[@"readback"][@"job_id"]};
            Check([@"analysis-poll-not-ready-" stringByAppendingString:kind], ![Invoke(@"v4.analysis.status", job)[@"readback"][@"ready"] boolValue]);
            Check([@"analysis-result-not-fabricated-" stringByAppendingString:kind], Code(Invoke(@"v4.analysis.result", job), @"ANALYSIS_NOT_READY"));
            Check([@"analysis-cancel-local-only-" stringByAppendingString:kind], [Invoke(@"v4.analysis.cancel", job)[@"readback"][@"state"] isEqual:@"cancelled"]);
        }
        Check(@"analysis-unknown-ID-fails", Code(Invoke(@"v4.analysis.status", @{@"job_id": @"stale"}), @"UNKNOWN_JOB"));
        NSUInteger failed = 0; for (NSDictionary *check in checks) if (![check[@"passed"] boolValue]) failed++;
        NSData *json = [NSJSONSerialization dataWithJSONObject:@{@"checks": checks, @"passed": @(checks.count - failed), @"failed": @(failed)} options:NSJSONWritingPrettyPrinted error:nil];
        puts([[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding].UTF8String);
        return failed ? 1 : 0;
    }
}
