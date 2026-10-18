// Typed, identity-bound parameters. Private selectors are listed in docs/v4/params-selectors.tsv.
#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import "SpliceKitPluginAPI.h"

@interface SKV4PContext : NSObject
@property(nonatomic, strong) NSDictionary *params;
@property(nonatomic, strong) id clip;
@property(nonatomic, strong) id stack;
@property(nonatomic, strong) id sequenceRoot;
@property(nonatomic, strong) id effect;
@property(nonatomic, strong) id applied;
@property(nonatomic, strong) NSDictionary *readback;
@property(nonatomic, strong) NSMutableArray *warnings;
@property(nonatomic, copy) NSString *label;
@property(nonatomic, copy) NSDictionary *(^afterCommit)(SKV4PContext *context);
@property(nonatomic) BOOL began;
@property(nonatomic) BOOL ended;
- (void)resolveTarget;
- (void)beginMutation;
@end

void SKV4PRequire(BOOL condition, NSString *code, NSString *message);
BOOL SKV4PHas(id object, NSString *selector);
id SKV4PObject(id object, NSString *selector);
id SKV4PObject1(id object, NSString *selector, id argument);
NSString *SKV4PIdentity(id object, NSString *selector);
NSString *SKV4PEffectIdentity(id effect);
NSString *SKV4PEscape(NSString *text);
NSArray *SKV4PArray(id object);
BOOL SKV4PBool(id object, NSString *selector);
BOOL SKV4PInteger(id value);
BOOL SKV4PNumber(id value);
CMTime SKV4PParseTime(NSDictionary *time);
NSDictionary *SKV4PTimeJSON(CMTime time, NSString *space);
CMTime SKV4PConvertTime(id object, NSString *selector, CMTime time, id container);
CMTime SKV4PResolveTime(SKV4PContext *context);
NSArray *SKV4PEffectInventory(SKV4PContext *context);
NSString *SKV4PType(id channel);
NSDictionary *SKV4PRead(id channel, CMTime time);
void SKV4PWrite(id channel, NSDictionary *value, CMTime time);
void SKV4PChannelEdit(id channel, dispatch_block_t body);
BOOL SKV4PValueEqual(id before, id after);
NSDictionary *SKV4PFindParameter(SKV4PContext *context, id *channelOut);
NSDictionary *SKV4PParameterReadback(SKV4PContext *context, id channel, CMTime time);
NSDictionary *SKV4PRun(NSDictionary *params, NSString *label, BOOL mutation,
                     NSDictionary *(^body)(SKV4PContext *context));
NSDictionary *SpliceKitV4_handleEffect(NSString *operation, NSDictionary *params);
NSDictionary *SpliceKitV4_handleParameter(NSString *operation, NSDictionary *params);
NSArray *SKV4PListKeys(SKV4PContext *context, id channel);
NSDictionary *SKV4PKeyState(SKV4PContext *context, id channel);
BOOL SKV4PPreservesOtherKeys(NSDictionary *before, NSDictionary *after, CMTime editedTime);
NSDictionary *SpliceKitV4_handleKeyframe(NSString *operation, NSDictionary *params);
void SpliceKitV4_registerParameters(void);
