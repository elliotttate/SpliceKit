//
//  SpliceKitVisionProPanel.h
//  SpliceKit — floating panel for connecting a Vision Pro for live preview.
//

#ifndef SpliceKitVisionProPanel_h
#define SpliceKitVisionProPanel_h

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

@interface SpliceKitVisionProPanel : NSObject
+ (instancetype)sharedPanel;
- (void)showPanel;
- (void)hidePanel;
- (void)togglePanel;
- (BOOL)isVisible;
@end

#endif /* SpliceKitVisionProPanel_h */
