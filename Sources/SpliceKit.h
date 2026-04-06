//
//  SpliceKit.h
//  SpliceKit - Direct in-process access to Final Cut Pro's private ObjC APIs.
//
//  This dylib gets injected into FCP's process space before main() runs.
//  Once loaded, it spins up a JSON-RPC server so external tools (MCP, scripts,
//  whatever) can call into FCP's internals without AppleScript or accessibility hacks.
//

#ifndef SpliceKit_h
#define SpliceKit_h

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

#define SPLICEKIT_VERSION "2.6.0"

// We keep strong refs to ObjC objects the caller might need later.
// Cap it so a forgetful client can't balloon our memory.
#define SPLICEKIT_MAX_HANDLES 2000

// The socket lives in /tmp when possible, but FCP's sandbox can block that.
// This resolves the right path at runtime and caches it.
const char *SpliceKit_getSocketPath(void);

// Dual-output logger: NSLog for Console.app + append to ~/Library/Logs/SpliceKit/splicekit.log.
// The log file is handy for post-mortem debugging when Console isn't open.
void SpliceKit_log(NSString *format, ...) NS_FORMAT_FUNCTION(1,2);

#pragma mark - Runtime Utilities

// Thin wrappers around objc_msgSend that nil-check the target first.
// Saves a crash when chasing a long KVC chain and something in the middle is nil.
id SpliceKit_sendMsg(id target, SEL selector);
id SpliceKit_sendMsg1(id target, SEL selector, id arg1);
id SpliceKit_sendMsg2(id target, SEL selector, id arg1, id arg2);
BOOL SpliceKit_sendMsgBool(id target, SEL selector);

// Enumerate classes loaded from a specific Mach-O image, or grab everything in the process.
// Useful for reverse-engineering which frameworks FCP pulls in.
NSArray *SpliceKit_classesInImage(const char *imageName);
NSDictionary *SpliceKit_methodsForClass(Class cls);
NSArray *SpliceKit_allLoadedClasses(void);

// Run a block on the main thread and wait for it to finish.
// Uses CFRunLoopPerformBlock so it works even during modal dialogs
// (dispatch_sync deadlocks in that situation because the main queue stalls).
void SpliceKit_executeOnMainThread(dispatch_block_t block);
void SpliceKit_executeOnMainThreadAsync(dispatch_block_t block);
BOOL SpliceKit_isMainThreadInRPCDispatch(void);

#pragma mark - Swizzling

// Swap a method implementation and stash the original so we can put it back later.
// Returns the original IMP, or NULL if the method wasn't found.
IMP SpliceKit_swizzleMethod(Class cls, SEL selector, IMP newImpl);
BOOL SpliceKit_unswizzleMethod(Class cls, SEL selector);

#pragma mark - Object Handle System

// The handle system lets JSON-RPC clients hold references to live ObjC objects
// across multiple calls. Each object gets a string ID like "obj_42" that the
// client can pass back in subsequent requests. Without this, every call would
// need to re-traverse the object graph from scratch.
NSString *SpliceKit_storeHandle(id object);
id SpliceKit_resolveHandle(NSString *handleId);
void SpliceKit_releaseHandle(NSString *handleId);
void SpliceKit_releaseAllHandles(void);
NSDictionary *SpliceKit_listHandles(void);

#pragma mark - Server

// Starts the TCP listener on port 9876 and the Unix domain socket.
// Called once from the app-launch notification handler.
void SpliceKit_startControlServer(void);

// Push a JSON-RPC notification to every connected client.
// Used for things like playhead-moved events.
void SpliceKit_broadcastEvent(NSDictionary *event);

#pragma mark - Feature Swizzles
//
// These are optional behaviors we inject into FCP by patching specific methods.
// Each one fixes a pain point or adds a capability that FCP doesn't have natively.
//

// When FCP says "not enough extra media for this transition", we add a third
// button: "Use Freeze Frames". It extends clip edges with hold frames so the
// transition can overlap without shortening the project.
void SpliceKit_installTransitionFreezeExtendSwizzle(void);

// Lets you drag an effect onto empty timeline space to auto-create an adjustment
// clip with that effect applied. Normally FCP just ignores the drop.
void SpliceKit_installEffectDragAsAdjustmentClip(void);
void SpliceKit_setEffectDragAsAdjustmentClipEnabled(BOOL enabled);
BOOL SpliceKit_isEffectDragAsAdjustmentClipEnabled(void);

// Trackpad pinch-to-zoom on the viewer. FCP only supports zoom via menu/keyboard.
void SpliceKit_installViewerPinchZoom(void);
void SpliceKit_removeViewerPinchZoom(void);
void SpliceKit_setViewerPinchZoomEnabled(BOOL enabled);
BOOL SpliceKit_isViewerPinchZoomEnabled(void);

// Adds a right-click "Favorite" option in the effect browser.
void SpliceKit_installEffectFavoritesSwizzle(void);

// Swizzles pasteAnchored: and paste: to handle FCPXML on the pasteboard.
// When FCPXML is detected, imports it into a temp project, converts to native
// clipboard format, and then lets the original paste proceed. Includes caching,
// screen freeze to hide the project switch, and playhead restoration.
void SpliceKit_installFCPXMLPasteSwizzle(void);

// Shared FCPXML-to-native conversion function. Checks if the pasteboard has
// FCPXML, converts it to native proFFPasteboardUTI format (using cache if
// available), and returns YES if native data is now on the pasteboard.
// Can be called directly by the caption system instead of duplicating the pipeline.
// Must be called on the main thread.
BOOL SpliceKit_convertFCPXMLToNativeClipboard(void);

// When you switch to video-only edit mode, FCP re-enables audio every time
// you switch back. This keeps audio disabled so it stays how you left it.
void SpliceKit_installVideoOnlyKeepsAudioDisabled(void);
void SpliceKit_setVideoOnlyKeepsAudioDisabledEnabled(BOOL enabled);
BOOL SpliceKit_isVideoOnlyKeepsAudioDisabledEnabled(void);

// Stops FCP from auto-opening the Import Media window every time a card, camera,
// or iOS device mounts. The observers stay wired up, but the handler methods
// bail out early when this is enabled.
void SpliceKit_installSuppressAutoImport(void);
void SpliceKit_setSuppressAutoImportEnabled(BOOL enabled);
BOOL SpliceKit_isSuppressAutoImportEnabled(void);

// Playback speed configuration — configurable J/L speed ladders
// L ladder: speeds for each successive L press (default: 1, 2, 4, 8, 16, 32)
// J ladder: speeds for each successive J press, stored positive, applied negative
NSArray<NSNumber *> *SpliceKit_getLLadder(void);
void SpliceKit_setLLadder(NSArray<NSNumber *> *speeds);
NSArray<NSNumber *> *SpliceKit_getJLadder(void);
void SpliceKit_setJLadder(NSArray<NSNumber *> *speeds);
void SpliceKit_setPlaybackRate(float rate);
void SpliceKit_installPlaybackSpeedSwizzle(void);

#pragma mark - Cached Class References
//
// We look these up once at launch instead of calling objc_getClass() on every
// request. FCP has 78K+ classes so the lookup isn't free. These are the ones
// we actually need for the core editing/playback/library operations.
//

extern Class SpliceKit_FFAnchoredTimelineModule;  // the big one — 1400+ methods for timeline editing
extern Class SpliceKit_FFAnchoredSequence;         // timeline data model (spine, items, duration)
extern Class SpliceKit_FFLibrary;
extern Class SpliceKit_FFLibraryDocument;
extern Class SpliceKit_FFEditActionMgr;
extern Class SpliceKit_FFModelDocument;
extern Class SpliceKit_FFPlayer;
extern Class SpliceKit_FFActionContext;
extern Class SpliceKit_PEAppController;            // app delegate — entry point for most things
extern Class SpliceKit_PEDocument;

#endif /* SpliceKit_h */
