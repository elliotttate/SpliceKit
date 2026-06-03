//
//  SpliceKitTimelineTabs.h
//  SpliceKit – Named project tabs for Final Cut Pro's timeline navigation
//
//  Replaces the awkward back/forward arrow tap-dance with a persistent row of
//  named tabs, one per project/sequence visited.  Click a tab to jump directly
//  to that sequence.  An × button on each tab removes it from the bar.
//

#ifndef SpliceKitTimelineTabs_h
#define SpliceKitTimelineTabs_h

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

// Install the tab bar.  Call once after FCP's main window is visible.
void SpliceKit_installTimelineTabs(void);

// Remove the tab bar.
void SpliceKit_uninstallTimelineTabs(void);

// Whether the tab bar is currently shown.
BOOL SpliceKit_isTimelineTabsInstalled(void);

#endif /* SpliceKitTimelineTabs_h */
