// SpliceKitBRAWToolboxCheck.h — optional Braw Toolbox ownership check.
//
// The original check validated a Mac App Store copy of LateNite Films' Braw
// Toolbox before enabling BRAW support. That requirement is currently disabled
// while SpliceKit's direct BRAW implementation is being tested.
//
// Pattern mirrors CommandPost's LateNite-app validation in MJAppDelegate.m.

#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

// Returns YES while the ownership gate is disabled.
BOOL SpliceKit_isBRAWToolboxInstalled(void);

#ifdef __cplusplus
}
#endif
