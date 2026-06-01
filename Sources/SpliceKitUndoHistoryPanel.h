//
//  SpliceKitUndoHistoryPanel.h
//  SpliceKit – Floating Undo History palette for Final Cut Pro
//
//  Intercepts NSUndoManager group-close notifications to build a persistent
//  ordered list of every action pushed onto the undo stack, including those
//  registered before the panel was first opened. Redo entries (actions that
//  were done then undone) are shown greyed-out below the current state.
//

#ifndef SpliceKitUndoHistoryPanel_h
#define SpliceKitUndoHistoryPanel_h

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

// ---------------------------------------------------------------------------
// Data model
// ---------------------------------------------------------------------------

@interface SpliceKitUndoEntry : NSObject
@property (nonatomic, copy) NSString *actionName;
@property (nonatomic, strong) NSDate  *timestamp;
@property (nonatomic)        NSInteger index;    // position in the history array
@end

// ---------------------------------------------------------------------------
// Panel
// ---------------------------------------------------------------------------

@interface SpliceKitUndoHistoryPanel : NSObject

+ (instancetype)sharedPanel;

// Called once from SpliceKit.m after the app finishes launching.
// Installs NSNotificationCenter observers on all NSUndoManagers in the process.
+ (void)installHooks;

// Panel visibility
- (void)showPanel;
- (void)hidePanel;
- (BOOL)isVisible;

// RPC surface ---------------------------------------------------------------

// Returns the full history as an array of entry dictionaries plus the cursor.
//   {
//     "entries": [{ "index": 0, "name": "Blade", "timestamp": "HH:MM:SS" }, ...],
//     "cursor":  2,   // index of current state (-1 = pristine/nothing done)
//     "canUndo": true,
//     "canRedo": false
//   }
- (NSDictionary *)getHistory;

// Jump to a specific history index by performing undo or redo as needed.
// Pass -1 to jump all the way back to the pristine (fully-undone) state.
- (NSDictionary *)jumpToIndex:(NSInteger)targetIndex;

// Clear the local history buffer (does NOT touch FCP's undo stack).
- (void)clearHistory;

@end

#endif /* SpliceKitUndoHistoryPanel_h */
