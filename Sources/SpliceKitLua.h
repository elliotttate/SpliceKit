//
//  SpliceKitLua.h
//  SpliceKit — Embedded Lua 5.4 scripting engine for FCP automation.
//
//  Provides a persistent Lua VM with an `sk` bridge module that calls
//  directly into SpliceKit's existing handlers (no TCP round-trip).
//  Supports live coding via file watching and an in-app REPL panel.
//

#ifndef SpliceKitLua_h
#define SpliceKitLua_h

#import <Foundation/Foundation.h>

// Initialize the Lua 5.4 VM and register the sk bridge module.
// Called once from SpliceKit_appDidLaunch(). Safe to call multiple times (no-op).
void SpliceKitLua_initialize(void);

// Destroy and recreate the VM. All Lua state (variables, modules) is lost.
void SpliceKitLua_reset(void);

// Execute a Lua code string. Returns dict with:
//   "output"  — captured print() output (may be empty)
//   "result"  — string representation of last expression value (may be nil)
//   "error"   — error message if execution failed (absent on success)
NSDictionary *SpliceKitLua_execute(NSString *code);

// Execute a Lua file. Same return format as SpliceKitLua_execute.
// Path can be absolute or relative to ~/Library/Application Support/SpliceKit/lua/.
NSDictionary *SpliceKitLua_executeFile(NSString *path);

// Whether the VM has been initialized.
BOOL SpliceKitLua_isInitialized(void);

// Get VM state info: memory usage, global variables, watch paths.
NSDictionary *SpliceKitLua_getState(void);

// Manage file watching. action: "add", "remove", "list".
NSDictionary *SpliceKitLua_watchAction(NSString *action, NSString *path);

#pragma mark - JSON-RPC Handlers (called from SpliceKitServer.m)

NSDictionary *SpliceKit_handleLuaExecute(NSDictionary *params);
NSDictionary *SpliceKit_handleLuaExecuteFile(NSDictionary *params);
NSDictionary *SpliceKit_handleLuaReset(NSDictionary *params);
NSDictionary *SpliceKit_handleLuaGetState(NSDictionary *params);
NSDictionary *SpliceKit_handleLuaWatch(NSDictionary *params);

#endif /* SpliceKitLua_h */
