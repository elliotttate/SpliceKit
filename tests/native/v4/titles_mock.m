// Offline contract tests. These classes emulate native boundaries, not FCP rendering.
#import "SpliceKitV4TitlesSupport.h"
static BOOL coreExecuting = YES;
BOOL SpliceKitV4IsExecuting(void) { return coreExecuting; }
static NSUndoManager *nativeUndo;
BOOL SpliceKitV4RegisterUndo(id target, void (^inverse)(id)) { [nativeUndo registerUndoWithTarget:target handler:inverse]; return nativeUndo != nil; }

static NSMutableDictionary<NSString *, SpliceKitMethodHandler> *registry;
static id activeTimeline;
static NSUInteger assertions;
static void Check(BOOL condition, NSString *message) {
    assertions++;
    if (!condition) { fprintf(stderr, "FAIL: %s\n", message.UTF8String); exit(1); }
}
void SpliceKit_registerPluginMethod(NSString *method, SpliceKitMethodHandler handler, NSDictionary *metadata) {
    if (!registry) registry = [NSMutableDictionary dictionary];
    registry[method] = [handler copy];
}
id SpliceKit_getActiveTimelineModule(void) { return activeTimeline; }
NSString *SpliceKit_storeHandle(id object) { return @"mock_runtime_handle"; }
void SpliceKit_log(NSString *format, ...) {}

@interface MockTransform : NSObject
@property double x;
@property double y;
@end
@implementation MockTransform
- (void)getPixelPositionAtTime:(CMTime)t x:(double *)x y:(double *)y z:(double *)z { *x = self.x; *y = self.y; *z = 0; }
- (void)setPixelPositionAtTime:(CMTime)t curveX:(double)x curveY:(double)y curveZ:(double)z options:(unsigned)o { self.x = x; self.y = y; }
@end

@interface FFEffect : NSObject
@property NSString *effectID;
@property NSMutableArray<NSAttributedString *> *fields;
@end
@implementation FFEffect
+ (NSString *)effectTypeForEffectID:(NSString *)eid {
    return @{@"basic-title": @"effect.video.title", @"custom-generator": @"effect.video.generator", @"dissolve": @"effect.video.transition"}[eid];
}
- (instancetype)init { if ((self = [super init])) _fields = [NSMutableArray arrayWithArray:@[
    [[NSAttributedString alloc] initWithString:@"Title"], [[NSAttributedString alloc] initWithString:@"Second field"]]]; return self; }
- (NSUInteger)textFieldCount { return self.fields.count; }
- (NSAttributedString *)textForField:(NSUInteger)index { return self.fields[index]; }
- (void)setText:(NSAttributedString *)text forField:(NSUInteger)index { self.fields[index] = [text copy]; }
@end

@interface FFRole : NSObject
@property NSString *uuid;
@property NSString *displayName;
@property NSString *languageIdentifier;
@property NSString *captionFormat;
@end
@implementation FFRole
- (BOOL)isCaption { return YES; }
@end

@interface MockClip : NSObject
@property NSString *persistentID;
@property CMTimeRange clippedRange;
@property CMTimeRange mediaRange;
@property CMTime timelineStart;
@property CMTime sampleDuration;
@property NSInteger anchoredLane;
@property FFEffect *effect;
@property MockTransform *transform;
@property NSMutableArray *anchoredItems;
@property NSSet *roles;
@property NSString *roleUID;
@end
@implementation MockClip
- (instancetype)init {
    if ((self = [super init])) {
        _persistentID = NSUUID.UUID.UUIDString; _timelineStart = kCMTimeZero;
        _sampleDuration = CMTimeMake(1,24);
        _clippedRange = CMTimeRangeMake(kCMTimeZero, CMTimeMake(120,24));
        _mediaRange = CMTimeRangeMake(kCMTimeZero, CMTimeMake(720,24));
        _anchoredItems = [NSMutableArray array]; _roles = [NSSet set];
    }
    return self;
}
- (BOOL)isRetimed { return NO; }
@end
@interface FFAnchoredMediaComponent : MockClip @end
@implementation FFAnchoredMediaComponent @end
@interface FFAnchoredGeneratorComponent : MockClip @end
@implementation FFAnchoredGeneratorComponent
- (instancetype)initWithEffectID:(NSString *)eid duration:(CMTime)d sampleDuration:(CMTime)frame {
    if ((self = [super init])) { self.effect = [FFEffect new]; self.effect.effectID = eid;
        self.clippedRange = CMTimeRangeMake(CMTimeMake(3600,1),d); } return self;
}
@end
@interface FFCaptionTextBlock : NSObject
@property NSArray<NSAttributedString *> *attributedStrings;
@end
@implementation FFCaptionTextBlock
- (NSString *)text { return [[self.attributedStrings valueForKey:@"string"] componentsJoinedByString:@"\n"]; }
@end
@interface FFAnchoredCaption : MockClip
@property NSArray<FFCaptionTextBlock *> *captionTextBlocks;
@end
@implementation FFAnchoredCaption
- (NSString *)text { return [[self.captionTextBlocks valueForKey:@"text"] componentsJoinedByString:@"\n"]; }
- (void)updateCaptionTextBlock:(FFCaptionTextBlock *)block withAttributedStrings:(NSArray *)strings { block.attributedStrings = strings; }
- (void)setRole:(FFRole *)role { self.roles = [NSSet setWithObject:role]; self.roleUID = role.uuid; }
@end
@interface FFAnchoredTransition : MockClip
@property FFEffect *videoTransition;
@end
@implementation FFAnchoredTransition @end
@interface FFCutawayEffects : NSObject @end
@implementation FFCutawayEffects
+ (id)transformEffectForObject:(MockClip *)clip { return clip.transform; }
+ (id)transformEffectForObject:(MockClip *)clip createIfAbsent:(BOOL)create {
    if (!clip.transform && create) clip.transform = [MockTransform new]; return clip.transform;
}
@end
@interface MockPrimary : MockClip
@property NSMutableArray *containedItems;
@end
@implementation MockPrimary
- (CMTimeRange)effectiveRangeOfObject:(MockClip *)clip { return CMTimeRangeMake(clip.timelineStart,clip.clippedRange.duration); }
@end
@interface MockUndo : NSObject
@property NSUInteger begins;
@property NSUInteger ends;
@property BOOL commitFails;
@end
@implementation MockUndo
- (void)undoableBegin:(NSString *)label { self.begins++; }
- (BOOL)undoableEnd:(id)info save:(BOOL)save error:(NSError **)error { self.ends++; return !self.commitFails; }
@end
@interface MockSequence : NSObject
@property MockPrimary *primaryObject;
@property MockUndo *undoHandler;
@property NSUInteger transitionCalls;
@property int overlapMode;
@property BOOL mismatchDuration;
@property BOOL wrongNativeText;
@property BOOL anchorFails;
@property NSUInteger anchorCalls;
@property double anchorDelay;
@end
@implementation MockSequence
- (CMTime)frameDuration { return CMTimeMake(1,24); }
- (BOOL)actionAnchorItem:(MockClip *)clip withAnchorInLocalTime:(CMTime)local atTime:(CMTime)time
            inContainer:(MockPrimary *)primary inContainerAnchorLane:(NSInteger)lane error:(NSError **)error {
    self.anchorCalls++;
    if (self.anchorDelay) [NSThread sleepForTimeInterval:self.anchorDelay];
    if (self.anchorFails) return NO;
    clip.timelineStart = CMTimeAdd(time,CMTimeSubtract(clip.clippedRange.start,local)); clip.anchoredLane = lane;
    if (![primary.anchoredItems containsObject:clip]) [primary.anchoredItems addObject:clip];
    return YES;
}
- (NSDictionary *)_transitionTypeDictionaryForTransitionID:(NSString *)eid { return @{@"video": eid}; }
- (BOOL)operationAddTransitionsToObjectsOnSpineObject:(MockPrimary *)primary spineObjectsToAddTransition:(NSArray *)objects
    before:(BOOL)before after:(BOOL)after spineTransitionClipsCreated:(id *)created effects:(NSDictionary *)effects
    transitionDuration:(CMTime)duration transitionOverlapType:(int)overlap reportErrors:(BOOL)report error:(NSError **)error {
    Check(before && !after && !report && objects.count == 1, @"transition uses one explicit cut without modal fallback");
    self.transitionCalls++; self.overlapMode = overlap;
    MockClip *right = objects[0]; NSUInteger index = [primary.containedItems indexOfObjectIdenticalTo:right];
    FFAnchoredTransition *transition = index && [primary.containedItems[index-1] isKindOfClass:FFAnchoredTransition.class] ? primary.containedItems[index-1] : [FFAnchoredTransition new];
    transition.clippedRange = CMTimeRangeMake(kCMTimeZero, self.mismatchDuration ? CMTimeMake(2,24) : duration);
    transition.timelineStart = CMTimeSubtract(right.timelineStart,CMTimeMultiplyByRatio(duration,1,2));
    transition.videoTransition = [FFEffect new]; transition.videoTransition.effectID = effects[@"video"];
    if (![primary.containedItems containsObject:transition]) [primary.containedItems insertObject:transition atIndex:index];
    *created = @[transition]; return YES;
}
- (BOOL)operationRemoveTransitionPreservingTime:(FFAnchoredTransition *)transition coerceEdit:(BOOL)coerce toTime:(CMTime)time {
    [self.primaryObject.containedItems removeObject:transition]; return YES;
}
@end
@interface MockTimeline : NSObject
@property MockSequence *sequence;
@end
@implementation MockTimeline @end

static NSDictionary *Call(NSString *name, NSDictionary *params) {
    Check(registry[name] != nil, [@"registered " stringByAppendingString:name]);
    NSDictionary *result = registry[name](params);
    for (NSString *key in @[@"ok",@"operation_id",@"applied",@"readback",@"revision_before",@"revision_after",@"undo",@"evidence_level",@"warnings",@"error"])
        Check(result[key] != nil, [@"envelope " stringByAppendingString:key]);
    Check([result[@"evidence_level"] isEqual:@"offline_tested"], @"never overstate evidence");
    const char *path = getenv("SKT_MOCK_RESULTS_PATH");
    if (path) {
        NSDictionary *record = @{@"method":name,@"params":params,@"result":result};
        NSData *json = [NSJSONSerialization dataWithJSONObject:record options:0 error:nil];
        Check(json != nil, @"every response is JSON serializable");
        FILE *file = fopen(path,"a"); Check(file != NULL,@"open local mock results");
        fwrite(json.bytes,1,json.length,file); fputc('\n',file); fclose(file);
    }
    return result;
}
static NSDictionary *Time(int value) { return @{@"value": @(value), @"timescale": @24}; }
static void Good(NSDictionary *result) { Check([result[@"ok"] boolValue], [result description]); }
static void Error(NSDictionary *result, NSString *code, BOOL unmodified) {
    Check(![result[@"ok"] boolValue] && [result[@"error"][@"code"] isEqual:code], [result description]);
    if (unmodified) Check([result[@"applied"] isEqual:@NO] && [result[@"undo"][@"kind"] isEqual:@"none"], @"preflight never edits");
}

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        nativeUndo=[NSUndoManager new];nativeUndo.groupsByEvent=NO;[nativeUndo beginUndoGrouping];
        Check(SKTStyleEqual(@[@1,@0.800000011920929],@[@1,@0.8]) && !SKTStyleEqual(@0.81,@0.8), @"float32 style precision is bounded");
        Check(registry.count == 11, @"all eleven RPCs register without core edits");
        MockSequence *sequence = [MockSequence new]; sequence.undoHandler = [MockUndo new];
        MockPrimary *primary = [MockPrimary new]; primary.clippedRange = CMTimeRangeMake(kCMTimeZero,CMTimeMake(240,24));
        sequence.primaryObject = primary;
        FFAnchoredMediaComponent *left = [FFAnchoredMediaComponent new], *right = [FFAnchoredMediaComponent new];
        right.timelineStart = CMTimeMake(120,24); right.clippedRange = CMTimeRangeMake(CMTimeMake(48,24),CMTimeMake(120,24));
        primary.containedItems = [NSMutableArray arrayWithArray:@[left,right]];
        MockTimeline *timeline = [MockTimeline new]; timeline.sequence = sequence; activeTimeline = timeline;
        NSDictionary *insert = @{@"effectID": @"basic-title", @"lane": @2, @"start": Time(24), @"duration": Time(48)};
        NSDictionary *result = Call(@"v4.title.insert",insert); Good(result);
        NSString *clipID = result[@"readback"][@"clip_id"];
        Check([result[@"undo"][@"kind"] isEqual:@"native_group"], @"native undo owner used");
        Check(result[@"readback"][@"object_handle"] == nil, @"no unused runtime handle is allocated");
        NSMutableDictionary *change = [@{@"clip_id": clipID,@"field_index": @1,@"text": @"Hello 👩🏽‍💻 world"} mutableCopy];
        Good(Call(@"v4.title.set_text",change));
        result = Call(@"v4.title.get",@{@"clip_id":clipID}); Good(result);
        NSArray *fields = result[@"readback"][@"fields"];
        Check([fields[0][@"text"] isEqual:@"Title"] && [fields[1][@"text"] isEqual:change[@"text"]], @"only explicit field is edited");
        NSDictionary *style = @{@"clip_id":clipID,@"field_index":@1,@"spans":@[@{@"range":@{@"start":@0,@"length":@5},
            @"style":@{@"font":@"Helvetica",@"size":@60,@"color":@[@1,@0,@0,@1],@"stroke_color":@[@0,@0,@0,@1],@"stroke_width":@(-3),
                @"shadow":@{@"color":@[@0,@0,@0,@0.5],@"blur":@4,@"x":@2,@"y":@(-2)},@"alignment":@"center"}}],@"position":@{@"x":@12,@"y":@(-30)}};
        result = Call(@"v4.title.set_style",style); Good(result);
        Check([result[@"readback"][@"position"][@"y"] doubleValue] == -30, @"position readback");
        NSArray *spans = result[@"readback"][@"fields"][1][@"spans"];
        Check(spans.count == 2 && [spans[0][@"range"][@"length"] intValue] == 5, @"full style runs read back");
        NSMutableDictionary *invalidStyle = [style mutableCopy]; invalidStyle[@"spans"] = @[@{@"range":@{@"start":@7,@"length":@1},@"style":@{@"color":@[@0,@1,@0,@1]}}];
        Error(Call(@"v4.title.set_style",invalidStyle),@"INVALID_RANGE",YES);
        invalidStyle[@"spans"] = @[@{@"range":@{@"start":@0,@"length":@5},@"style":@{@"size":@0}}];
        Error(Call(@"v4.title.set_style",invalidStyle),@"INVALID_STYLE",YES);
        invalidStyle[@"spans"] = @[@{@"range":@{@"start":@0,@"length":@5},@"style":@{@"size":@50}},@{@"range":@{@"start":@4,@"length":@1},@"style":@{@"size":@60}}];
        Error(Call(@"v4.title.set_style",invalidStyle),@"OVERLAPPING_SPANS",YES);
        change[@"field_index"] = @9; Error(Call(@"v4.title.set_text",change),@"INVALID_FIELD",YES);
        change[@"field_index"] = @1; change[@"text"] = @""; Good(Call(@"v4.title.set_text",change));
        Error(Call(@"v4.title.insert",insert),@"LANE_OCCUPIED",YES);
        NSMutableDictionary *badInsert = [insert mutableCopy]; badInsert[@"lane"]=@0;
        Error(Call(@"v4.title.insert",badInsert),@"INVALID_LANE",YES);
        badInsert[@"lane"]=@3; badInsert[@"duration"]=@{@"value":@1,@"timescale":@25};
        Error(Call(@"v4.title.insert",badInsert),@"OFF_FRAME",YES);
        badInsert[@"duration"]=Time(24); badInsert[@"effectID"]=@"custom-generator";
        Good(Call(@"v4.generator.insert",badInsert));
        Error(Call(@"v4.title.get",@{@"clip_id":@"mock_runtime_handle"}),@"CLIP_NOT_FOUND",YES);
        FFRole *en = [FFRole new]; en.uuid=@"role-en"; en.displayName=@"English"; en.languageIdentifier=@"en"; en.captionFormat=@"ITT";
        FFRole *tr = [FFRole new]; tr.uuid=@"role-tr"; tr.displayName=@"Turkish"; tr.languageIdentifier=@"tr"; tr.captionFormat=@"ITT";
        FFAnchoredCaption *caption = [FFAnchoredCaption new]; caption.anchoredLane=5; caption.clippedRange=CMTimeRangeMake(kCMTimeZero,CMTimeMake(24,24)); [caption setRole:en];
        FFCaptionTextBlock *block = [FFCaptionTextBlock new]; block.attributedStrings=@[[[NSAttributedString alloc] initWithString:@"Before"]]; caption.captionTextBlocks=@[block];
        FFAnchoredCaption *second = [FFAnchoredCaption new]; second.timelineStart=CMTimeMake(168,24); [second setRole:tr]; second.captionTextBlocks=@[block];
        [primary.anchoredItems addObjectsFromArray:@[caption,second]];
        result=Call(@"v4.caption.list",@{}); Good(result); Check([result[@"readback"][@"captions"] count]==2,@"only native captions listed");
        Check([result[@"readback"][@"available_roles"] count]==2,@"native caption roles listed");
        Good(Call(@"v4.caption.set_text",@{@"clip_id":caption.persistentID,@"block_index":@0,@"text":@"Corrected\ncaption"}));
        Check([caption.text isEqual:@"Corrected\ncaption"],@"multiline native block updated");
        Good(Call(@"v4.caption.set_timing",@{@"clip_id":caption.persistentID,@"start":Time(48),@"duration":Time(36)}));
        Check(CMTimeCompare(caption.timelineStart,CMTimeMake(48,24))==0,@"caption timeline start is not source start");
        Good(Call(@"v4.caption.set_role",@{@"clip_id":caption.persistentID,@"role_id":@"role-tr"}));
        Error(Call(@"v4.caption.set_role",@{@"clip_id":caption.persistentID,@"role_id":@"absent"}),@"ROLE_NOT_FOUND",YES);
        NSDictionary *cut = @{@"left_clip_id":left.persistentID,@"right_clip_id":right.persistentID};
        NSMutableDictionary *transition=[@{@"cut":cut,@"effectID":@"dissolve",@"duration":Time(24),@"handle_policy":@"fail"} mutableCopy];
        result=Call(@"v4.transition.set",transition); Good(result);
        NSString *transitionID=result[@"readback"][@"clip_id"];
        Good(Call(@"v4.transition.set",transition));
        Error(Call(@"v4.transition.remove",@{@"cut":cut,@"transition_id":@"stale"}),@"STALE_TRANSITION",YES);
        Good(Call(@"v4.transition.remove",@{@"cut":cut,@"transition_id":transitionID}));
        result=Call(@"v4.transition.remove",@{@"cut":cut}); Good(result); Check([result[@"applied"] isEqual:@NO],@"absent transition removal is a no-op");
        right.clippedRange=CMTimeRangeMake(CMTimeMake(4,24),CMTimeMake(120,24));
        NSUInteger prior=sequence.transitionCalls;
        Error(Call(@"v4.transition.set",transition),@"INSUFFICIENT_HANDLES",YES); Check(sequence.transitionCalls==prior,@"fail policy never invokes native mutation");
        transition[@"handle_policy"]=@"shorten"; result=Call(@"v4.transition.set",transition); Good(result);
        Check([result[@"readback"][@"shortened"] boolValue] && [result[@"readback"][@"duration"][@"value"] intValue]==8,@"shorten reports exact smaller duration");
        Good(Call(@"v4.transition.remove",@{@"cut":cut}));
        right.clippedRange=CMTimeRangeMake(kCMTimeZero,CMTimeMake(120,24));
        transition[@"handle_policy"]=@"freeze"; result=Call(@"v4.transition.set",transition); Good(result);
        Check(sequence.overlapMode==2 && [result[@"readback"][@"freeze_requested"] boolValue],@"freeze policy explicitly requests native freeze-overlap");
        Good(Call(@"v4.transition.remove",@{@"cut":cut}));
        right.clippedRange=CMTimeRangeMake(CMTimeMake(48,24),CMTimeMake(120,24)); transition[@"handle_policy"]=@"fail";
        sequence.mismatchDuration=YES; result=Call(@"v4.transition.set",transition); Error(result,@"READBACK_MISMATCH",NO);
        Check([result[@"applied"] isEqual:@YES] && [result[@"readback"] isKindOfClass:NSDictionary.class],@"readback mismatch retains observed state and applied=true");
        sequence.mismatchDuration=NO;
        right.sampleDuration=CMTimeMake(1,25);
        Error(Call(@"v4.transition.set",transition),@"HANDLES_UNKNOWN",YES);
        right.sampleDuration=CMTimeMake(1,24);
        sequence.anchorFails=YES; badInsert[@"lane"]=@8; result=Call(@"v4.generator.insert",badInsert); Error(result,@"INSERT_FAILED",NO);
        Check(result[@"applied"]==NSNull.null,@"failed native call has unknown application status"); sequence.anchorFails=NO;
        sequence.undoHandler.commitFails=YES; change[@"text"]=@"Uncommitted native text";
        result=Call(@"v4.title.set_text",change); Error(result,@"UNDO_COMMIT_FAILED",NO);
        Check(result[@"applied"]==NSNull.null,@"native commit failure never claims unmodified state");
        sequence.undoHandler.commitFails=NO;
        NSMutableDictionary *guarded=[change mutableCopy]; guarded[@"expected_revision"]=@"stale-without-core";
        coreExecuting = NO;
        Error(Call(@"v4.title.set_text",guarded),@"CORE_REQUIRED",YES);
        coreExecuting = YES;
        Check(sequence.undoHandler.begins==sequence.undoHandler.ends,@"every native undo begin is closed, including exceptions");
        NSDictionary *withID=Call(@"v4.title.get",@{@"clip_id":clipID,@"operation_id":@"test-fixed-id"});
        Check([withID[@"operation_id"] isEqual:@"test-fixed-id"],@"preserve core-assigned operation identity");
        // Only the core schedules work and owns deadlines; a direct background
        // handler invocation must reject before touching a native object.
        NSUInteger anchorsBefore = sequence.anchorCalls;
        dispatch_semaphore_t finished = dispatch_semaphore_create(0);
        __block NSDictionary *rejected = nil;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
            rejected = registry[@"v4.generator.insert"](badInsert);
            dispatch_semaphore_signal(finished);
        });
        dispatch_semaphore_wait(finished, DISPATCH_TIME_FOREVER);
        Error(rejected, @"CORE_REQUIRED", YES);
        Check(sequence.anchorCalls == anchorsBefore, @"direct background mutation is rejected");
        activeTimeline=nil; Error(Call(@"v4.caption.list",@{}),@"NO_SEQUENCE",YES);
        printf("PASS: %lu assertions across eleven native RPCs (mock, no FCP)\n",(unsigned long)assertions);
    }
    return 0;
}
