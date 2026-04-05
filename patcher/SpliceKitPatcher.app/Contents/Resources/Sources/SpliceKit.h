//
//  SpliceKit.h
//  SpliceKit - Direct in-process access to Final Cut Pro private APIs
//

#ifndef SpliceKit_h
#define SpliceKit_h

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

// Version
#define SPLICEKIT_VERSION "2.6.0"
#define SPLICEKIT_MAX_HANDLES 2000

// Socket path - resolve at runtime to handle sandbox
const char *SpliceKit_getSocketPath(void);

// Logging - writes to ~/Library/Logs/SpliceKit/splicekit.log AND NSLog
void SpliceKit_log(NSString *format, ...) NS_FORMAT_FUNCTION(1,2);

#pragma mark - Runtime Utilities

// Safe message sending wrappers
id SpliceKit_sendMsg(id target, SEL selector);
id SpliceKit_sendMsg1(id target, SEL selector, id arg1);
id SpliceKit_sendMsg2(id target, SEL selector, id arg1, id arg2);
BOOL SpliceKit_sendMsgBool(id target, SEL selector);

// Class/method discovery
NSArray *SpliceKit_classesInImage(const char *imageName);
NSDictionary *SpliceKit_methodsForClass(Class cls);
NSArray *SpliceKit_allLoadedClasses(void);

// Main thread dispatch
void SpliceKit_executeOnMainThread(dispatch_block_t block);
void SpliceKit_executeOnMainThreadAsync(dispatch_block_t block);

#pragma mark - Swizzling

IMP SpliceKit_swizzleMethod(Class cls, SEL selector, IMP newImpl);
BOOL SpliceKit_unswizzleMethod(Class cls, SEL selector);

#pragma mark - Object Handle System

NSString *SpliceKit_storeHandle(id object);
id SpliceKit_resolveHandle(NSString *handleId);
void SpliceKit_releaseHandle(NSString *handleId);
void SpliceKit_releaseAllHandles(void);
NSDictionary *SpliceKit_listHandles(void);

#pragma mark - Server

void SpliceKit_startControlServer(void);
void SpliceKit_broadcastEvent(NSDictionary *event);

#pragma mark - Transition Freeze Extend

void SpliceKit_installTransitionFreezeExtendSwizzle(void);

#pragma mark - Effect Drag as Adjustment Clip

void SpliceKit_installEffectDragAsAdjustmentClip(void);
void SpliceKit_setEffectDragAsAdjustmentClipEnabled(BOOL enabled);
BOOL SpliceKit_isEffectDragAsAdjustmentClipEnabled(void);

#pragma mark - Viewer Pinch-to-Zoom

void SpliceKit_installViewerPinchZoom(void);
void SpliceKit_removeViewerPinchZoom(void);
void SpliceKit_setViewerPinchZoomEnabled(BOOL enabled);
BOOL SpliceKit_isViewerPinchZoomEnabled(void);

#pragma mark - Effect Browser Favorites

void SpliceKit_installEffectFavoritesSwizzle(void);

#pragma mark - Video-Only Keeps Audio Disabled

void SpliceKit_installVideoOnlyKeepsAudioDisabled(void);
void SpliceKit_setVideoOnlyKeepsAudioDisabledEnabled(BOOL enabled);
BOOL SpliceKit_isVideoOnlyKeepsAudioDisabledEnabled(void);

#pragma mark - Cached Class References

extern Class SpliceKit_FFAnchoredTimelineModule;
extern Class SpliceKit_FFAnchoredSequence;
extern Class SpliceKit_FFLibrary;
extern Class SpliceKit_FFLibraryDocument;
extern Class SpliceKit_FFEditActionMgr;
extern Class SpliceKit_FFModelDocument;
extern Class SpliceKit_FFPlayer;
extern Class SpliceKit_FFActionContext;
extern Class SpliceKit_PEAppController;
extern Class SpliceKit_PEDocument;

#endif /* SpliceKit_h */
