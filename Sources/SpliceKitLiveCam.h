#ifndef SpliceKitLiveCam_h
#define SpliceKitLiveCam_h

#import <Foundation/Foundation.h>

@interface SpliceKitLiveCamPanel : NSObject

+ (instancetype)sharedPanel;
- (BOOL)isVisible;
- (void)showPanel;
- (void)hidePanel;
- (NSDictionary *)statusSnapshot;

@end

FOUNDATION_EXPORT NSString * const SpliceKitLiveCamVisibilityDidChangeNotification;

NSDictionary *SpliceKit_handleLiveCamShow(NSDictionary *params);
NSDictionary *SpliceKit_handleLiveCamHide(NSDictionary *params);
NSDictionary *SpliceKit_handleLiveCamStatus(NSDictionary *params);

#endif /* SpliceKitLiveCam_h */
