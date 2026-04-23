#ifndef SpliceKitImmersivePreviewPanel_h
#define SpliceKitImmersivePreviewPanel_h

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

@interface SpliceKitImmersivePreviewPanel : NSObject

+ (instancetype)sharedPanel;
- (void)showPanel;
- (void)hidePanel;
- (void)togglePanel;
- (BOOL)isVisible;

- (NSDictionary *)statusSnapshot;
- (BOOL)loadSelectedClipWithError:(NSError **)error;
- (BOOL)loadClipAtPath:(NSString *)path error:(NSError **)error;
- (void)loadClipAtPathAsync:(NSString *)path
                 completion:(void (^)(BOOL ok, NSError *error))completion;
- (void)setFrameIndexValue:(NSInteger)frameIndex;
- (void)setEyeModeIdentifier:(NSString *)identifier;
- (void)setViewModeIdentifier:(NSString *)identifier;
- (void)setViewportYaw:(double)yaw pitch:(double)pitch fov:(double)fov;
- (void)resetPerformanceCounters;
- (BOOL)requestPreviewRenderInteractive:(BOOL)interactive error:(NSError **)error;
- (BOOL)refreshPreviewWithError:(NSError **)error;
- (BOOL)sendCurrentFrameToVisionPro:(NSError **)error;

@end

#ifdef __cplusplus
extern "C" {
#endif
NSDictionary *SpliceKit_handleImmersivePreviewShow(NSDictionary *params);
NSDictionary *SpliceKit_handleImmersivePreviewHide(NSDictionary *params);
NSDictionary *SpliceKit_handleImmersivePreviewStatus(NSDictionary *params);
NSDictionary *SpliceKit_handleImmersivePreviewResolveSelectedPath(NSDictionary *params);
NSDictionary *SpliceKit_handleImmersivePreviewLoadSelected(NSDictionary *params);
NSDictionary *SpliceKit_handleImmersivePreviewLoadPath(NSDictionary *params);
NSDictionary *SpliceKit_handleImmersivePreviewSetFrame(NSDictionary *params);
NSDictionary *SpliceKit_handleImmersivePreviewSetEyeMode(NSDictionary *params);
NSDictionary *SpliceKit_handleImmersivePreviewSetViewMode(NSDictionary *params);
NSDictionary *SpliceKit_handleImmersivePreviewSetViewport(NSDictionary *params);
NSDictionary *SpliceKit_handleImmersivePreviewRefresh(NSDictionary *params);
NSDictionary *SpliceKit_handleImmersivePreviewResetPerf(NSDictionary *params);
NSDictionary *SpliceKit_handleImmersivePreviewSendCurrentFrame(NSDictionary *params);
NSString *SpliceKit_copyTimelineClipPathNearPlayhead(void);
void SpliceKit_installImmersiveViewerBridge(void);
#ifdef __cplusplus
}
#endif

#endif /* SpliceKitImmersivePreviewPanel_h */
