//
//  SpliceKitTimecodeBarShortcuts.h
//  SpliceKit — Customizable shortcut buttons in FCP's timeline toolbar
//
//  Injects compact NSButtons into the flex gap between the timeline history
//  forward button and the snapping/skimming control cluster.  Configuration
//  is stored as JSON in ~/Library/Application Support/SpliceKit/.
//

#ifndef SpliceKitTimecodeBarShortcuts_h
#define SpliceKitTimecodeBarShortcuts_h

#import <Foundation/Foundation.h>

// Install the shortcut bar.  Called once at launch; retries until FCP's
// timeline module is ready.
void SpliceKit_installTimecodeBarShortcuts(void);

// Reload buttons from the saved config (call after prefs change).
void SpliceKit_reloadTimecodeBarShortcuts(void);

// Return the full catalogue of actions users can assign to buttons.
// Each dict: @{@"id", @"type", @"icon", @"tooltip", @"category"}
NSArray<NSDictionary *> *SpliceKit_getAvailableTimecodeBarActions(void);

// Return / replace the current ordered shortcut config.
// Each dict must have at least @"id" and @"type".
NSArray<NSDictionary *> *SpliceKit_getTimecodeBarConfig(void);
void SpliceKit_setTimecodeBarConfig(NSArray<NSDictionary *> *config);

#endif /* SpliceKitTimecodeBarShortcuts_h */
