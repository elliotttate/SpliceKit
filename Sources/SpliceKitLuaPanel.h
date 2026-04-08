//
//  SpliceKitLuaPanel.h
//  SpliceKit — Floating Lua REPL panel inside FCP.
//

#ifndef SpliceKitLuaPanel_h
#define SpliceKitLuaPanel_h

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

@interface SpliceKitLuaPanel : NSObject
+ (instancetype)sharedPanel;
- (void)showPanel;
- (void)hidePanel;
- (void)togglePanel;
- (BOOL)isVisible;
- (void)appendOutput:(NSString *)text color:(NSColor *)color;
@end

#endif /* SpliceKitLuaPanel_h */
