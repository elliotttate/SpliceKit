//
//  SpliceKitUprezzer.h
//  Local editor-facing upscaling workflow for Final Cut Pro.
//

#ifndef SpliceKitUprezzer_h
#define SpliceKitUprezzer_h

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

@interface SpliceKitUprezzerPanel : NSObject

+ (instancetype)sharedPanel;

- (void)showPanel;
- (void)hidePanel;
- (void)togglePanel;
- (BOOL)isVisible;
- (void)refreshSelection;

@end

#endif /* SpliceKitUprezzer_h */
