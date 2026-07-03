//
//  SKPluginShared.h
//  com.splicekit.preferences-pane
//
//  Shared plugin-API storage used by both PreferencesPane.m and DebugUI.m,
//  which are compiled into the same plugin.dylib.
//

#ifndef SKPluginShared_h
#define SKPluginShared_h

#import "SpliceKitPluginAPI.h"

extern SpliceKitPluginAPI *sAPI;

#define SpliceKit_log(...) (sAPI ? sAPI->log(__VA_ARGS__) : (void)0)

#endif /* SKPluginShared_h */
