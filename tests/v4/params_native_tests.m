// Exercise production handlers against native ObjC mocks, never loading or contacting FCP.
#import <Foundation/Foundation.h>
static BOOL coreExecuting = YES;
BOOL SpliceKitV4IsExecuting(void) { return coreExecuting; }
static NSUndoManager *nativeUndo;
BOOL SpliceKitV4RegisterUndo(id target, void (^inverse)(id)) { [nativeUndo registerUndoWithTarget:target handler:inverse]; return nativeUndo != nil; }
#import <CoreMedia/CoreMedia.h>
#import "SpliceKitV4Parameters.h"

static id activeTimeline;
static NSMutableDictionary *registered;
void SpliceKit_executeOnMainThread(dispatch_block_t block) { block(); }
id SpliceKit_getActiveTimelineModule(void) { return activeTimeline; }
void SpliceKit_registerPluginMethod(NSString *name, SpliceKitMethodHandler handler, NSDictionary *meta) { registered[name] = [handler copy]; }

static NSUInteger checks;
static void Check(BOOL value, NSString *message) {
    checks++; if (!value) { fprintf(stderr,"FAIL: %s\n",message.UTF8String); exit(1); }
}
static void Record(NSDictionary *r) {
    NSData *data=[NSJSONSerialization dataWithJSONObject:r options:0 error:NULL];
    Check(data!=nil,@"JSON result serialization");
    printf("RESULT %s\n",[[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] UTF8String]);
}
static void OK(NSDictionary *r) { Check([r[@"ok"] boolValue], [r description]); Record(r); }
static void Error(NSDictionary *r, NSString *code) {
    Check(![r[@"ok"] boolValue] && [r[@"error"][@"code"] isEqual:code], [r description]); Record(r);
}
@interface MockChannel : NSObject
@property unsigned channelID;
@property(copy) NSString *name;
@property(strong) NSArray *children;
@end
@implementation MockChannel
- (void)operationBegin {}
- (void)operationEnd {}
- (instancetype)init { if ((self=[super init])) { _name=@"Localized Amount"; _children=@[]; } return self; }
@end
@interface MockKey : NSObject
@property CMTime time;
@property double value;
@property unsigned interpolation;
@end
@implementation MockKey @end
@interface MockDouble : MockChannel
@property double constant;
@property BOOL clampWrite;
@property BOOL wipeOtherKeys;
@property(strong) NSMutableArray<MockKey *> *keys;
@end
@implementation MockDouble
- (instancetype)init { if ((self=[super init])) _keys=[NSMutableArray array]; return self; }
- (BOOL)allowsKeyframes { return YES; }
- (NSUInteger)keyframeCount { return self.keys.count; }
- (double)minCurveDoubleValue { return -10; }
- (double)maxCurveDoubleValue { return 10; }
- (double)minUIDoubleValue { return 0; }
- (double)maxUIDoubleValue { return 1; }
- (double)curveDoubleValueAtTime:(CMTime)t {
    if (!CMTIME_IS_NUMERIC(t) || !self.keys.count) return self.constant;
    MockKey *previous=self.keys.firstObject;
    for (MockKey *key in self.keys) {
        if (CMTimeCompare(t,key.time)==0) return key.value;
        if (CMTimeCompare(t,key.time)<0) {
            if (key==previous || previous.interpolation==0) return previous.value;
            double fraction=CMTimeGetSeconds(CMTimeSubtract(t,previous.time))/CMTimeGetSeconds(CMTimeSubtract(key.time,previous.time));
            return previous.value+(key.value-previous.value)*fraction;
        }
        previous=key;
    }
    return previous.value;
}
- (void *)keyframeAtTime:(CMTime)t { for(MockKey *k in self.keys) if(CMTimeCompare(k.time,t)==0) return (__bridge void *)k; return NULL; }
- (BOOL)hasKeyframeAtTime:(CMTime)t { return [self keyframeAtTime:t]!=NULL; }
- (void)setCurveDoubleValue:(double)v atTime:(CMTime)t options:(unsigned)options {
    if(self.clampWrite) v=0.25;
    if (!CMTIME_IS_NUMERIC(t)) { self.constant=v; return; }
    if(self.wipeOtherKeys) [self.keys removeAllObjects];
    MockKey *key=(__bridge id)[self keyframeAtTime:t];
    if(!key) { self.constant=v; return; }
    key.value=v;
    [self.keys sortUsingComparator:^NSComparisonResult(MockKey *a,MockKey *b){return (NSComparisonResult)CMTimeCompare(a.time,b.time);}];
}
- (void)appendKeyframes:(unsigned)count times:(CMTime *)times values:(double *)values {
    for(unsigned i=0;i<count;i++) { MockKey *key=[MockKey new];key.time=times[i];key.value=values[i];key.interpolation=1;[self.keys addObject:key]; }
    [self.keys sortUsingComparator:^NSComparisonResult(MockKey *a,MockKey *b){return (NSComparisonResult)CMTimeCompare(a.time,b.time);}];
}
- (void *)firstKeyframe { return self.keys.count ? (__bridge void *)self.keys[0] : NULL; }
- (void *)nextKeyframe:(void *)p { NSUInteger i=[self.keys indexOfObjectIdenticalTo:(__bridge id)p]; return i!=NSNotFound && i+1<self.keys.count ? (__bridge void *)self.keys[i+1] : NULL; }
- (BOOL)getKeyframe:(void *)p time:(CMTime *)time { *time=((MockKey *)(__bridge id)p).time; return YES; }
- (BOOL)removeKeyframeAtTime:(CMTime)t { id key=(__bridge id)[self keyframeAtTime:t]; if(key) [self.keys removeObjectIdenticalTo:key]; return key!=nil; }
- (unsigned)segmentInterpolation:(void *)p { return ((MockKey *)(__bridge id)p).interpolation; }
- (void)setSegmentInterpolation:(void *)p interpolation:(unsigned)i { ((MockKey *)(__bridge id)p).interpolation=i; }
@end
@interface CHChannelAngle : MockDouble @end
@implementation CHChannelAngle @end
@interface MockBool : MockChannel
@property BOOL value;
@end
@implementation MockBool
- (BOOL)curveBoolValueAtTime:(CMTime)t { return self.value; }
- (void)setCurveBoolValue:(BOOL)v atTime:(CMTime)t options:(unsigned)o { self.value=v; }
- (NSUInteger)keyframeCount { return 0; }
@end
@interface MockEnum : MockChannel
@property int value;
@end
@implementation MockEnum
- (NSArray *)strings { return @[@"Localized first",@"Localized second"]; }
- (int)intValueForIndex:(int)i { return i ? 7:2; }
- (int)intValueAtTime:(CMTime)t { return self.value; }
- (void)setCurveIntValue:(int)v atTime:(CMTime)t options:(unsigned)o { self.value=v; }
- (NSUInteger)keyframeCount { return 0; }
@end
@interface MockInt : MockChannel
@property int value;
@end
@implementation MockInt
- (int)_curveIntValueAtTime:(CMTime)t { return self.value; }
- (void)_setCurveIntValue:(int)v atTime:(CMTime)t options:(unsigned)o { self.value=v; }
- (NSUInteger)keyframeCount { return 0; }
@end
@interface MockText : MockChannel
@property(copy) NSString *string;
@end
@implementation MockText @end
@interface MockColor : MockChannel
@property double r,g,b,a;
@end
@implementation MockColor
- (void)getColorAtTime:(CMTime)t curveRed:(double *)r curveGreen:(double *)g curveBlue:(double *)b curveAlpha:(double *)a { *r=self.r;*g=self.g;*b=self.b;*a=self.a; }
- (void)setColorAtTime:(CMTime)t curveRed:(double)r curveGreen:(double)g curveBlue:(double)b curveAlpha:(double)a options:(unsigned)o {self.r=r;self.g=g;self.b=b;self.a=a;}
- (NSUInteger)keyframeCount { return 0; }
@end
@interface MockRGB : MockChannel
@property double r,g,b;
@end
@implementation MockRGB
- (void)getColorAtTime:(CMTime)t curveRed:(double *)r curveGreen:(double *)g curveBlue:(double *)b { *r=self.r;*g=self.g;*b=self.b; }
- (void)setColorAtTime:(CMTime)t curveRed:(double)r curveGreen:(double)g curveBlue:(double)b options:(unsigned)o {self.r=r;self.g=g;self.b=b;}
- (NSUInteger)keyframeCount { return 0; }
@end
@interface MockPoint : MockChannel
@property double x,y;
@end
@implementation MockPoint
- (void)getDoubleValuesAtTime:(CMTime)t curveX:(double *)x curveY:(double *)y { *x=self.x;*y=self.y; }
- (void)setDoubleValuesAtTime:(CMTime)t curveX:(double)x curveY:(double)y options:(unsigned)o {self.x=x;self.y=y;}
- (NSUInteger)keyframeCount { return 0; }
@end
@interface MockPoint3D : MockChannel
@property double x,y,z;
@end
@implementation MockPoint3D
- (void)getDoubleValuesAtTime:(CMTime)t curveX:(double *)x curveY:(double *)y curveZ:(double *)z { *x=self.x;*y=self.y;*z=self.z; }
- (void)setDoubleValuesAtTime:(CMTime)t curveX:(double)x curveY:(double)y curveZ:(double)z options:(unsigned)o {self.x=x;self.y=y;self.z=z;}
- (NSUInteger)keyframeCount { return 0; }
@end
@interface MockEffect : NSObject
@property(copy) NSString *persistentID;
@property(copy) NSString *fileUUID;
@property(copy) NSString *effectID;
@property(strong) MockChannel *channelFolder;
@property BOOL enabled;
@property NSUInteger undoSnapshots;
@end
@implementation MockEffect
- (NSString *)displayName { return @"Localized Gaussian"; }
- (id)storeForUndo { self.undoSnapshots++; return self; }
@end
// Same class name as the registry the production implementation resolves.
@interface FFEffect : NSObject @end
@implementation FFEffect
+ (NSArray *)userVisibleEffectIDs { return @[(@".../Effects.localized/Blur.localized/" @"Very long Gaussian name.localized/Gaussian.moef"),@"Audio:EQ",@"Title:Basic"]; }
+ (NSString *)effectTypeForEffectID:(NSString *)eid { return [eid hasPrefix:@"Audio:"] ? @"effect.audio.effect" : [eid hasPrefix:@"Title:"] ? @"effect.video.title" : [[self userVisibleEffectIDs] containsObject:eid] ? @"effect.video.filter":nil; }
+ (NSString *)displayNameForEffectID:(NSString *)eid { return @"Localized Gaussian"; }
+ (NSString *)categoryForEffectID:(NSString *)eid { return @"Blur"; }
+ (NSURL *)fileURLFromEffectID:(NSString *)eid { return [NSURL fileURLWithPath:@"/nonexistent/mock.moef"]; }
@end
@interface MockStack : NSObject
@property(strong) NSMutableArray *effects;
@property NSUInteger began,ended;
@property BOOL failSave;
@property(copy) void (^afterClose)(void);
@end
@implementation MockStack
- (NSArray *)intrinsicEffects { return @[]; }
- (id)xform3DEffect { return self.effects.firstObject; }
- (id)audioLevelChannel { return ((MockEffect *)self.effects.firstObject).channelFolder.children.firstObject; }
- (void)actionBegin:(NSString *)label animationHint:(id)hint deferUpdates:(BOOL)defer {self.began++;}
- (BOOL)actionEnd:(NSString *)label save:(BOOL)save error:(NSError **)error {self.ended++;if(self.afterClose)self.afterClose();return !self.failSave;}
- (id)addEffectWithID:(NSString *)eid { MockEffect *e=[MockEffect new]; e.fileUUID=NSUUID.UUID.UUIDString; e.effectID=eid; e.enabled=YES; e.channelFolder=[MockChannel new]; [self.effects addObject:e]; return e; }
- (void)removeEffects:(NSArray *)effects { [self.effects removeObjectsInArray:effects]; }
- (BOOL)getSection:(NSUInteger *)section andIndexInSection:(NSUInteger *)index forEffect:(id)effect {*section=0;*index=[self.effects indexOfObjectIdenticalTo:effect];return *index!=NSNotFound;}
- (void)moveEffects:(NSArray *)effects toIndex:(NSUInteger)index inSection:(NSUInteger)section { id e=effects[0]; NSUInteger old=[self.effects indexOfObjectIdenticalTo:e]; [self.effects removeObjectIdenticalTo:e]; [self.effects insertObject:e atIndex:index-(old<index?1:0)]; }
@end
@interface MockClip : NSObject
@property(copy) NSString *persistentID;
@property(strong) MockStack *effectStack;
@property(strong) MockStack *videoEffects;
@property(strong) NSArray *containedItems;
@end
@implementation MockClip
- (CMTime)containerToLocalTime:(CMTime)t container:(id)container { return CMTimeSubtract(t,CMTimeMake(10,1)); }
- (CMTime)localToContainerTime:(CMTime)t container:(id)container { return CMTimeAdd(t,CMTimeMake(10,1)); }
@end
@interface MockSequence : NSObject
@property(strong) id primaryObject;
@end
@implementation MockSequence @end
@interface MockTimeline : NSObject
@property(strong) id sequence;
@end
@implementation MockTimeline @end

static NSMutableDictionary *Args(NSString *instance, unsigned channel, NSString *space, int64_t value, int scale) {
    NSMutableDictionary *target=[@{@"clip_id":@"clip-A"} mutableCopy];
    if(instance) target[@"effect_instance_id"]=instance;
    return [@{@"target":target,@"parameter_path":[NSString stringWithFormat:@"/effects/%@/channels/0/%u",SKV4PEscape(instance ?: @"instance-A"),channel],@"time":@{@"value":@(value),@"timescale":@(scale),@"space":space}} mutableCopy];
}
static NSMutableDictionary *Set(NSString *instance,unsigned channel,NSString *type,id value) {
    NSMutableDictionary *p=Args(instance,channel,@"clip_local",0,1); p[@"mode"]=@"constant";p[@"value"]=@{@"type":type,@"value":value};return p;
}
int main(void) { @autoreleasepool {
    nativeUndo=[NSUndoManager new];nativeUndo.groupsByEvent=NO;[nativeUndo beginUndoGrouping];
    registered=[NSMutableDictionary dictionary]; SpliceKitV4_registerParameters(); Check(registered.count==13,@"13 RPC registrations");
    coreExecuting = NO;
    Check([SpliceKitV4_handleParameter(@"set", @{})[@"error"][@"code"] isEqual:@"CORE_REQUIRED"], @"direct mutation requires core admission");
    coreExecuting = YES;
    MockDouble *number=[MockDouble new]; number.channelID=1; number.constant=0.5;
    MockBool *boolean=[MockBool new]; boolean.channelID=2;
    MockEnum *enumeration=[MockEnum new]; enumeration.channelID=3; enumeration.value=2;
    MockText *text=[MockText new]; text.channelID=4; text.string=@"Before";
    MockColor *color=[MockColor new]; color.channelID=5;
    MockRGB *rgb=[MockRGB new];rgb.channelID=10;
    MockPoint *point=[MockPoint new]; point.channelID=6;
    MockInt *integer=[MockInt new]; integer.channelID=7;
    CHChannelAngle *angle=[CHChannelAngle new];angle.channelID=8;
    MockPoint3D *point3d=[MockPoint3D new];point3d.channelID=9;
    MockChannel *folder=[MockChannel new]; folder.children=@[number,boolean,enumeration,text,color,point,integer,angle,point3d,rgb];
    MockEffect *effect=[MockEffect new];effect.fileUUID=@"instance-A";effect.effectID=[FFEffect userVisibleEffectIDs][0];effect.enabled=YES;effect.channelFolder=folder;
    MockEffect *duplicate=[MockEffect new];duplicate.fileUUID=@"instance-B";duplicate.effectID=effect.effectID;duplicate.channelFolder=[MockChannel new];duplicate.enabled=YES;
    MockStack *stack=[MockStack new]; stack.effects=[@[effect,duplicate] mutableCopy];
    MockClip *clip=[MockClip new];clip.persistentID=@"clip-A";clip.effectStack=stack;
    MockClip *root=[MockClip new]; root.persistentID=@"root";root.containedItems=@[clip];
    MockSequence *sequence=[MockSequence new];sequence.primaryObject=root;
    MockTimeline *timeline=[MockTimeline new];timeline.sequence=sequence;activeTimeline=timeline;

    clip.videoEffects=stack;clip.effectStack=nil;
    NSDictionary *collectionTree=SpliceKitV4_handleParameter(@"inspect",@{@"target":@{@"clip_id":@"clip-A"},@"time":@{@"value":@0,@"timescale":@1,@"space":@"clip_local"}});
    OK(collectionTree);Check([collectionTree[@"readback"][@"effects"] count]==2,@"collection resolves its own video stack without child fallback");
    effect.persistentID=@"instance-A";effect.fileUUID=nil;
    OK(SpliceKitV4_handleParameter(@"inspect",Args(@"instance-A",1,@"clip_local",0,1)));
    Check([SKV4PEffectIdentity(effect) isEqual:@"instance-A"],@"imported effect identity does not depend on nullable fileUUID");
    effect.persistentID=nil;effect.fileUUID=@"instance-A";
    clip.effectStack=stack;

    NSDictionary *r=SpliceKitV4_handleEffect(@"catalog",@{@"limit":@1});OK(r);
    Check([r[@"readback"][@"effects"] count]==1 && [r[@"readback"][@"total"] intValue]==3,@"stable catalog pagination");
    r=SpliceKitV4_handleEffect(@"catalog",@{@"query":@"Very long",@"type":@"filter"});OK(r);
    Check([r[@"readback"][@"effects"][0][@"effectID"] isEqual:effect.effectID],@"full catalog ID");
    Error(SpliceKitV4_handleEffect(@"catalog",@{@"limit":@0}),@"INVALID_ARGUMENT");

    NSMutableDictionary *p=Args(@"instance-A",1,@"clip_local",1001,30000);
    r=SpliceKitV4_handleParameter(@"describe",p);OK(r);
    Check([r[@"readback"][@"type"] isEqual:@"double"] && [r[@"readback"][@"writable"] boolValue],@"describe leaf is directly in readback");
    Check([r[@"readback"][@"data_range"][@"max"] intValue]==10 && [r[@"readback"][@"ui_range"][@"max"] intValue]==1,@"UI and data range separate");
    r=SpliceKitV4_handleParameter(@"inspect",p);OK(r);Check([r[@"readback"][@"components"] count]==1,@"inspect binds exact effect instance");
    p=Args(nil,1,@"clip_local",0,1);r=SpliceKitV4_handleParameter(@"inspect",p);OK(r);Check([r[@"readback"][@"bindings"][@"/intrinsic/audio/gain"] length]>0,@"intrinsic gain root");
    number.name=@"Translated label";p=Args(@"instance-A",1,@"clip_local",0,1);OK(SpliceKitV4_handleParameter(@"get",p));

    p=Set(@"instance-A",1,@"double",@2);r=SpliceKitV4_handleParameter(@"set",p);OK(r);
    Check(number.constant==2 && [r[@"readback"][@"verified"] boolValue],@"data value beyond UI range is allowed");
    p[@"value"]=@{@"type":@"double",@"value":@YES};Error(SpliceKitV4_handleParameter(@"set",p),@"TYPE_MISMATCH");
    p[@"value"]=@{@"type":@"double",@"value":@11};NSUInteger before=stack.began;Error(SpliceKitV4_handleParameter(@"set",p),@"OUT_OF_RANGE");Check(before==stack.began,@"invalid write does not begin native action");
    p=Set(@"instance-A",2,@"bool",@YES);OK(SpliceKitV4_handleParameter(@"set",p));Check(boolean.value,@"boolean setter");
    p=Set(@"instance-A",3,@"enum",@7);OK(SpliceKitV4_handleParameter(@"set",p));Check(enumeration.value==7,@"enum native remapping");
    p[@"value"]=@{@"type":@"enum",@"value":@1};Error(SpliceKitV4_handleParameter(@"set",p),@"OUT_OF_RANGE");
    p=Set(@"instance-A",4,@"string",@"After");OK(SpliceKitV4_handleParameter(@"set",p));Check([text.string isEqual:@"After"],@"text is not coerced to double");
    p[@"mode"]=@"at_time";Error(SpliceKitV4_handleParameter(@"set",p),@"UNSUPPORTED_CAPABILITY");
    p=Set(@"instance-A",5,@"color",@{@"r":@1.5,@"g":@0.2,@"b":@0.3,@"a":@1,@"space":@"native_curve"});OK(SpliceKitV4_handleParameter(@"set",p));Check(color.r==1.5,@"HDR native color is preserved");
    p=Set(@"instance-A",10,@"color",@{@"r":@1.1,@"g":@0.2,@"b":@0.3,@"a":@1,@"space":@"native_curve"});OK(SpliceKitV4_handleParameter(@"set",p));Check(rgb.r==1.1,@"native no-alpha RGB has implicit alpha one");
    p[@"value"]=@{@"type":@"color",@"value":@{@"r":@0,@"g":@0,@"b":@0,@"a":@0.8,@"space":@"native_curve"}};Error(SpliceKitV4_handleParameter(@"set",p),@"UNSUPPORTED_ALPHA");
    p=Set(@"instance-A",6,@"point2d",@{@"x":@2,@"y":@3});OK(SpliceKitV4_handleParameter(@"set",p));Check(point.y==3,@"typed point");
    p=Set(@"instance-A",7,@"int",@42);OK(SpliceKitV4_handleParameter(@"set",p));Check(integer.value==42,@"native integral setter");
    p=Set(@"instance-A",8,@"angle",@0.5);OK(SpliceKitV4_handleParameter(@"set",p));Check(angle.constant==0.5,@"native angle has distinct type without guessed degree conversion");
    p=Set(@"instance-A",9,@"point3d",@{@"x":@1,@"y":@2,@"z":@3});OK(SpliceKitV4_handleParameter(@"set",p));Check(point3d.z==3,@"native 3D vector components");

    p=Set(@"instance-A",1,@"double",@1);p[@"time"]=@{@"value":@0,@"timescale":@1,@"space":@"clip_local"};OK(SpliceKitV4_handleKeyframe(@"set",p));
    p[@"time"]=@{@"value":@1001,@"timescale":@30000,@"space":@"clip_local"};p[@"value"]=@{@"type":@"double",@"value":@3};r=SpliceKitV4_handleKeyframe(@"set",p);OK(r);
    Check(number.keys.count==2 && number.keys[1].time.value==1001 && number.keys[1].time.timescale==30000,@"rational time retained without time-zero fallback");
    r=SpliceKitV4_handleParameter(@"get",p);OK(r);Check([r[@"readback"][@"value"][@"value"] intValue]==3,@"nonzero-time read");
    p[@"mode"]=@"constant";Error(SpliceKitV4_handleParameter(@"set",p),@"ANIMATED_PARAMETER");Check(number.keys.count==2,@"constant write preserves animation");
    number.wipeOtherKeys=YES;
    r=SpliceKitV4_handleKeyframe(@"set",p);Error(r,@"READBACK_MISMATCH");Check([r[@"applied"] boolValue],@"timed write cannot silently erase adjacent keys");
    number.wipeOtherKeys=NO;
    NSMutableDictionary *restore=Set(@"instance-A",1,@"double",@1);OK(SpliceKitV4_handleKeyframe(@"set",restore));
    p[@"time"]=@{@"value":@0,@"timescale":@1,@"space":@"clip_local"};p[@"interpolation"]=@"ease_in_out";r=SpliceKitV4_handleKeyframe(@"set_interpolation",p);OK(r);Check(number.keys[0].interpolation==21,@"native S-curve mapping");
    p[@"interpolation"]=@"smooth";Error(SpliceKitV4_handleKeyframe(@"set_interpolation",p),@"UNSUPPORTED_CAPABILITY");
    p[@"time"]=@{@"value":@10,@"timescale":@1,@"space":@"timeline"};r=SpliceKitV4_handleParameter(@"get",p);OK(r);Check([r[@"readback"][@"resolved_time"][@"value"] intValue]==0,@"timeline mapping");
    r=SpliceKitV4_handleKeyframe(@"list",p);OK(r);Check([r[@"readback"][@"keyframes"][0][@"time"][@"value"] intValue]==10,@"keyframes returned in requested timeline space");
    r=SpliceKitV4_handleKeyframe(@"delete",p);OK(r);Check(number.keys.count==1,@"delete one key only");
    r=SpliceKitV4_handleKeyframe(@"delete",p);OK(r);Check(![r[@"applied"] boolValue],@"missing key delete is no-op");
    p[@"time"]=@{@"value":@1,@"timescale":@0,@"space":@"clip_local"};Error(SpliceKitV4_handleParameter(@"get",p),@"INVALID_TIME");
    p[@"time"]=@{@"value":@0.5,@"timescale":@1,@"space":@"clip_local"};Error(SpliceKitV4_handleParameter(@"get",p),@"INVALID_TIME");
    p=Args(@"instance-A",1,@"clip_local",0,1);p[@"parameter_path"]=@"/effects/instance-B/channels/0/1";Error(SpliceKitV4_handleParameter(@"get",p),@"PARAMETER_NOT_FOUND");
    p[@"target"]=@{@"clip_id":@"clip-A",@"effect_instance_id":@"stale"};Error(SpliceKitV4_handleParameter(@"get",p),@"TARGET_NOT_FOUND");
    MockClip *same=[MockClip new];same.persistentID=@"clip-A";root.containedItems=@[clip,same];Error(SpliceKitV4_handleParameter(@"get",Args(@"instance-A",1,@"clip_local",0,1)),@"AMBIGUOUS_IDENTITY");root.containedItems=@[clip];
    folder.children=@[number,number];Error(SpliceKitV4_handleParameter(@"describe",Args(@"instance-A",1,@"clip_local",0,1)),@"AMBIGUOUS_PARAMETER_PATH");folder.children=@[number];
    [number.keys removeAllObjects];number.clampWrite=YES;p=Set(@"instance-A",1,@"double",@2);r=SpliceKitV4_handleParameter(@"set",p);Error(r,@"READBACK_MISMATCH");Check([r[@"applied"] boolValue],@"readback mismatch reports applied true");number.clampWrite=NO;

    p=[@{@"target":@{@"clip_id":@"clip-A",@"effect_instance_id":@"instance-A"},@"enabled":@NO} mutableCopy];OK(SpliceKitV4_handleEffect(@"enable",p));Check(!effect.enabled && duplicate.enabled,@"bypass exact repeated effect");
    [nativeUndo endUndoGrouping];[nativeUndo undo];Check(effect.enabled,@"native operation-owned inverse restores bypass");[nativeUndo beginUndoGrouping];
    p[@"before_instance_id"]=NSNull.null;OK(SpliceKitV4_handleEffect(@"move",p));Check(stack.effects.lastObject==effect,@"move exact instance to end");
    p[@"before_instance_id"]=@"instance-B";OK(SpliceKitV4_handleEffect(@"move",p));Check(stack.effects.firstObject==effect,@"move exact instance before sibling");
    OK(SpliceKitV4_handleEffect(@"remove",p));Check(stack.effects.count==1 && stack.effects.firstObject==duplicate,@"remove preserves same-effect sibling");
    p=[@{@"target":@{@"clip_id":@"clip-A"},@"effect_id":[FFEffect userVisibleEffectIDs][0]} mutableCopy];r=SpliceKitV4_handleEffect(@"add",p);OK(r);Check(stack.effects.count==2 && [r[@"readback"][@"target"][@"effect_instance_id"] length]>0,@"add returns new native instance identity");
    p[@"effect_id"]=@"Title:Basic";Error(SpliceKitV4_handleEffect(@"add",p),@"UNSUPPORTED_CAPABILITY");
    // Readback must be checked again after native save, not only while the group is open.
    MockEffect *remaining=stack.effects[0]; remaining.channelFolder=folder;
    [number.keys removeAllObjects]; number.constant=0;
    p=Set(remaining.fileUUID,1,@"double",@2);
    stack.afterClose=^{ number.constant=0.75; };
    r=SpliceKitV4_handleParameter(@"set",p); Error(r,@"READBACK_MISMATCH");
    Check([r[@"applied"] boolValue] && [r[@"readback"][@"value"][@"value"] doubleValue]==0.75,@"post-save readback catches native normalization");
    stack.afterClose=nil;stack.failSave=YES;
    r=SpliceKitV4_handleParameter(@"set",p); Error(r,@"UNKNOWN_OUTCOME");
    Check(r[@"applied"]==NSNull.null && [r[@"undo"][@"kind"] isEqual:@"unknown"],@"failed native save preserves unknown outcome");
    stack.failSave=NO;
    Check(stack.began==stack.ended,@"native action groups balanced on all mutations");
    Check([NSJSONSerialization isValidJSONObject:r],@"common result envelope is JSON serializable");
    printf("PASS: %lu native handler checks; no FCP process or bridge used.\n",(unsigned long)checks);
} return 0; }
