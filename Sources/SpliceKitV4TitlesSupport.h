// Shared implementation details for the v4 text and transition workstream.
#import "SpliceKit.h"
#import "SpliceKitV4Core.h"
#import <AppKit/AppKit.h>
#import <CoreMedia/CoreMedia.h>

#if defined(__x86_64__)
#define SKT_STRET objc_msgSend_stret
#else
#define SKT_STRET objc_msgSend
#endif

@interface SKTRequest : NSObject
@property NSString *operationID;
@property NSString *label;
@property id applied;
@property NSString *undoKind;
@property NSMutableArray *warnings;
@property NSDictionary *readback;
@end

NSDictionary *SKTRun(NSDictionary *params, NSString *label, BOOL mutating,
                     NSDictionary *(^body)(SKTRequest *request));
void SKTRequire(BOOL condition, NSString *code, NSString *message);
id SKTGet(id object, NSString *selector);
NSArray *SKTArray(id value);
BOOL SKTInteger(id value);
BOOL SKTNumber(id value);
CMTime SKTParseTime(id value, BOOL positive);
NSDictionary *SKTTime(CMTime time);
CMTime SKTFrame(id sequence);
void SKTCheckFrame(CMTime time, CMTime frame);
CMTimeRange SKTRange(id object, NSString *selector);
CMTimeRange SKTEffectiveRange(id sequence, id object);
id SKTSequence(void);
NSArray *SKTObjects(id sequence);
NSString *SKTID(id object);
id SKTFind(id sequence, NSString *objectID);
NSDictionary *SKTObjectReadback(id sequence, id object);
void SKTEdit(id sequence, SKTRequest *request, void (^body)(void));
id SKTTransform(id clip);
NSDictionary *SKTPosition(id clip);
void SKTSetPosition(id clip, NSDictionary *position);
void SKTValidatePosition(id value);
NSAttributedString *SKTStyledText(NSAttributedString *base, NSArray *spans);
NSDictionary *SKTTextReadback(NSAttributedString *text);
BOOL SKTStyleEqual(id actual, id expected);
void SKTRegister(NSString *method, BOOL readOnly, SpliceKitMethodHandler handler);
