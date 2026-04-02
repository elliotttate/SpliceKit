//
//  FCPBridge.h
//  FCPBridge - Direct in-process access to Final Cut Pro private APIs
//

#ifndef FCPBridge_h
#define FCPBridge_h

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

// Version
#define FCPBRIDGE_VERSION "2.6.0"
#define FCPBRIDGE_MAX_HANDLES 2000

// Socket path - resolve at runtime to handle sandbox
const char *FCPBridge_getSocketPath(void);

// Logging - writes to ~/Library/Logs/FCPBridge/fcpbridge.log AND NSLog
void FCPBridge_log(NSString *format, ...) NS_FORMAT_FUNCTION(1,2);

#pragma mark - Runtime Utilities

// Safe message sending wrappers
id FCPBridge_sendMsg(id target, SEL selector);
id FCPBridge_sendMsg1(id target, SEL selector, id arg1);
id FCPBridge_sendMsg2(id target, SEL selector, id arg1, id arg2);
BOOL FCPBridge_sendMsgBool(id target, SEL selector);

// Class/method discovery
NSArray *FCPBridge_classesInImage(const char *imageName);
NSDictionary *FCPBridge_methodsForClass(Class cls);
NSArray *FCPBridge_allLoadedClasses(void);

// Main thread dispatch
void FCPBridge_executeOnMainThread(dispatch_block_t block);
void FCPBridge_executeOnMainThreadAsync(dispatch_block_t block);

#pragma mark - Swizzling

IMP FCPBridge_swizzleMethod(Class cls, SEL selector, IMP newImpl);
BOOL FCPBridge_unswizzleMethod(Class cls, SEL selector);

#pragma mark - Object Handle System

NSString *FCPBridge_storeHandle(id object);
id FCPBridge_resolveHandle(NSString *handleId);
void FCPBridge_releaseHandle(NSString *handleId);
void FCPBridge_releaseAllHandles(void);
NSDictionary *FCPBridge_listHandles(void);

#pragma mark - Server

void FCPBridge_startControlServer(void);
void FCPBridge_broadcastEvent(NSDictionary *event);

#pragma mark - Transition Freeze Extend

void FCPBridge_installTransitionFreezeExtendSwizzle(void);

#pragma mark - Effect Drag as Adjustment Clip

void FCPBridge_installEffectDragAsAdjustmentClip(void);

#pragma mark - Viewer Pinch-to-Zoom

void FCPBridge_installViewerPinchZoom(void);
void FCPBridge_removeViewerPinchZoom(void);
void FCPBridge_setViewerPinchZoomEnabled(BOOL enabled);
BOOL FCPBridge_isViewerPinchZoomEnabled(void);

#pragma mark - Cached Class References

extern Class FCPBridge_FFAnchoredTimelineModule;
extern Class FCPBridge_FFAnchoredSequence;
extern Class FCPBridge_FFLibrary;
extern Class FCPBridge_FFLibraryDocument;
extern Class FCPBridge_FFEditActionMgr;
extern Class FCPBridge_FFModelDocument;
extern Class FCPBridge_FFPlayer;
extern Class FCPBridge_FFActionContext;
extern Class FCPBridge_PEAppController;
extern Class FCPBridge_PEDocument;

#endif /* FCPBridge_h */
