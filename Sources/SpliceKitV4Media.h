// Shared media helpers. No private FCP declaration is linked into this module.
#pragma once
#import "SpliceKit.h"
#import <CoreMedia/CoreMedia.h>
#import <objc/message.h>

typedef NSDictionary *(^SKV4MediaHandler)(NSDictionary *params, BOOL *attempted);

NSDictionary *SKMResult(NSDictionary *params, BOOL ok, NSNumber *applied,
                        NSDictionary *readback, NSString *code, NSString *message);
void SKMRegister(NSString *name, BOOL readOnly, SKV4MediaHandler handler);
void SKMRequire(BOOL condition, NSString *code, NSString *message);
BOOL SKMString(id value);
BOOL SKMNumber(id value);
BOOL SKMBool(id value);
BOOL SKMTime(id value, CMTime *time);
NSDictionary *SKMTimeJSON(CMTime time);
BOOL SKMSignature(id receiver, NSString *selector, const char *result, NSArray<NSString *> *args);
id SKMObject(id receiver, NSString *selector);
NSString *SKMIdentity(id receiver, NSString *selector);
id SKMClip(NSDictionary *params);
id SKMEffect(id stack, NSDictionary *target);
id SKMSequence(void);
id SKMStack(id clip, BOOL audio);
void SKMEdit(id owner, NSString *label, dispatch_block_t mutation);
NSDictionary *SKMCall(NSString *method, NSDictionary *params);
NSArray *SKMNamedParameterRequests(NSDictionary *params, NSDictionary *allowed);
NSDictionary *SKMApplyParameterRequests(NSDictionary *params, NSArray *requests, BOOL *attempted);
void SpliceKitV4RegisterColor(void);
void SpliceKitV4RegisterAudio(void);
void SpliceKitV4RegisterRetime(void);
void SpliceKitV4RegisterAnalysis(void);

#if defined(__x86_64__)
#define SKM_STRET objc_msgSend_stret
#else
#define SKM_STRET objc_msgSend
#endif
