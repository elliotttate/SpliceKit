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

// Diagnostics: swizzle result tracking and server ready timing
NSDictionary *SpliceKit_getSwizzleResults(void);
void SpliceKit_markServerReady(void);

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

#pragma mark - Sequence State Persistence

// Persist and reload per-sequence JSON state under Application Support so
// transcript-derived tools can survive an FCP relaunch.
NSDictionary *SpliceKit_sequenceIdentity(id sequence);
NSDictionary *SpliceKit_loadSequenceState(id sequence);
BOOL SpliceKit_saveSequenceState(id sequence, NSDictionary *state, NSError **error);

#pragma mark - Safe Install

// Execute a feature install block with crash recovery.  If the block triggers
// SIGSEGV or SIGBUS, catches it via sigsetjmp/siglongjmp, logs the failure,
// and returns NO so startup can continue.  Returns YES on success.
// Only call from the main thread during startup.
BOOL SpliceKit_safeInstall(const char *featureName, void (^block)(void));

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

#pragma mark - Plugin Method Registry

// Plugins (Lua or native) register JSON-RPC methods here. The dispatch
// fallthrough in SpliceKit_handleRequest checks these before returning
// "method not found", so plugin methods are callable identically to built-in ones.
typedef NSDictionary *(^SpliceKitMethodHandler)(NSDictionary *params);
void SpliceKit_registerPluginMethod(NSString *method, SpliceKitMethodHandler handler, NSDictionary *metadata);
void SpliceKit_unregisterPluginMethod(NSString *method);
void SpliceKit_registerPluginManifest(NSString *pluginId, NSDictionary *manifest);

#pragma mark - Server

// Starts the TCP listener on port 9876 and the Unix domain socket.
// Called once from the app-launch notification handler.
void SpliceKit_startControlServer(void);
id SpliceKit_getActiveTimelineModule(void);

// Push a JSON-RPC notification to every connected client.
// Used for things like playhead-moved events.
void SpliceKit_broadcastEvent(NSDictionary *event);
NSDictionary *SpliceKit_handleAudioBusDiagnostics(NSString *method, NSDictionary *params);

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

// Spring-loaded blade — hold Option to temporarily switch to blade tool,
// release to revert to the previous tool. Enabled by default.
void SpliceKit_installSpringLoadedBlade(void);
void SpliceKit_uninstallSpringLoadedBlade(void);
void SpliceKit_setSpringLoadedBladeEnabled(BOOL enabled);
BOOL SpliceKit_isSpringLoadedBladeEnabled(void);

// Playback speed configuration — configurable J/L speed ladders
// L ladder: speeds for each successive L press (default: 1, 2, 4, 8, 16, 32)
// J ladder: speeds for each successive J press, stored positive, applied negative
NSArray<NSNumber *> *SpliceKit_getLLadder(void);
void SpliceKit_setLLadder(NSArray<NSNumber *> *speeds);
NSArray<NSNumber *> *SpliceKit_getJLadder(void);
void SpliceKit_setJLadder(NSArray<NSNumber *> *speeds);
void SpliceKit_setPlaybackRate(float rate);
void SpliceKit_installPlaybackSpeedSwizzle(void);

// Overrides the default Spatial Conform Type for newly added timeline clips.
// FCP normally defaults to "Fit" (letterbox/pillarbox). This lets users choose
// "Fill" (scale to fill, cropping edges) or "None" (native resolution) instead.
// Value is a string: "fit", "fill", or "none".
void SpliceKit_installDefaultSpatialConformType(void);
void SpliceKit_setDefaultSpatialConformType(NSString *value);
NSString *SpliceKit_getDefaultSpatialConformType(void);

#pragma mark - Dual Timeline

// Floating secondary timeline window support. This keeps a second
// PEEditorContainerModule alive and routes app actions to whichever timeline
// window currently has focus.
void SpliceKit_installDualTimeline(void);
void SpliceKit_installDualTimelineCrossWindowDrag(void);
BOOL SpliceKit_isDualTimelineInstalled(void);
NSString *SpliceKit_dualTimelineSecondaryIdentifier(void);
id SpliceKit_dualTimelineFocusedEditorContainer(void);
id SpliceKit_dualTimelinePrimaryEditorContainer(void);
id SpliceKit_dualTimelineSecondaryEditorContainer(BOOL createIfNeeded);
NSDictionary *SpliceKit_dualTimelineStatus(void);
NSDictionary *SpliceKit_dualTimelineOpen(NSDictionary *params);
NSDictionary *SpliceKit_dualTimelineSyncRoot(NSDictionary *params);
NSDictionary *SpliceKit_dualTimelineOpenSelectedInSecondary(NSDictionary *params);
NSDictionary *SpliceKit_dualTimelineFocus(NSDictionary *params);
NSDictionary *SpliceKit_dualTimelineClose(NSDictionary *params);
NSDictionary *SpliceKit_dualTimelineTogglePanel(NSDictionary *params);

#pragma mark - Lua Scripting

// Initialize the embedded Lua 5.4 VM and start the file watcher.
// Called once from SpliceKit_appDidLaunch().
void SpliceKitLua_initialize(void);

#pragma mark - LiveCam

NSDictionary *SpliceKit_handleLiveCamShow(NSDictionary *params);
NSDictionary *SpliceKit_handleLiveCamHide(NSDictionary *params);
NSDictionary *SpliceKit_handleLiveCamStatus(NSDictionary *params);

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

#pragma mark - Timeline Module

// Get the active FFAnchoredTimelineModule. Returns nil if no project is open.
id SpliceKit_getActiveTimelineModule(void);

#pragma mark - Sections Bar

// Custom NSView injected into FCP's timeline showing color-coded song structure.
NSDictionary *SpliceKit_handleSectionsShow(NSDictionary *params);
NSDictionary *SpliceKit_handleSectionsHide(NSDictionary *params);
NSDictionary *SpliceKit_handleSectionsAdd(NSDictionary *params);
NSDictionary *SpliceKit_handleSectionsRemove(NSDictionary *params);
NSDictionary *SpliceKit_handleSectionsSetColor(NSDictionary *params);
NSDictionary *SpliceKit_handleSectionsGet(NSDictionary *params);

#pragma mark - Structure Blocks

// Color-coded section blocks above the timeline (verse/chorus/bridge/etc.).
// Creates a connected storyline of labeled title clips from song structure data.
void SpliceKit_installStructureBlockContextMenu(void);
NSDictionary *SpliceKit_handleStructureGenerateBlocks(NSDictionary *params);
NSDictionary *SpliceKit_handleStructureGenerateCaptions(NSDictionary *params);
NSDictionary *SpliceKit_handleStructureRemove(NSDictionary *params);
NSDictionary *SpliceKit_handleStructureToggle(NSDictionary *params);

#endif /* SpliceKit_h */
