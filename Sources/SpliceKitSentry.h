//
//  SpliceKitSentry.h
//  Shared Sentry hooks for the injected runtime.
//

#ifndef SpliceKitSentry_h
#define SpliceKitSentry_h

#import <Foundation/Foundation.h>

BOOL SpliceKit_sentryRuntimeEnabled(void);
void SpliceKit_sentryStartRuntime(void);
void SpliceKit_sentrySetLaunchPhase(NSString *phase);
void SpliceKit_sentrySetLastRPCMethod(NSString *method);
void SpliceKit_sentryAddBreadcrumb(NSString *category, NSString *message, NSDictionary *data);
void SpliceKit_sentryCaptureMessage(NSString *message, NSString *context, NSDictionary *data);
void SpliceKit_sentryCaptureException(NSException *exception, NSString *context, NSDictionary *data);
void SpliceKit_sentryCaptureNSError(NSError *error, NSString *context, NSDictionary *data);

#endif /* SpliceKitSentry_h */
