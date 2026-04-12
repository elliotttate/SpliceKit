//
//  SpliceKitLua.m
//  SpliceKit — Embedded Lua 5.4 scripting engine.
//
//  Provides a persistent Lua VM inside FCP's process with an `sk` bridge module
//  that calls SpliceKit handlers directly. Supports live coding via FSEvents file
//  watching and an in-app REPL panel.
//

#import "SpliceKitLua.h"
#import "SpliceKit.h"
#import <AppKit/AppKit.h>
#import <CoreServices/CoreServices.h>

#include "lua.h"
#include "lualib.h"
#include "lauxlib.h"

// ============================================================================
#pragma mark - Extern Declarations (handlers in SpliceKitServer.m)
// ============================================================================

// Non-static handlers we call directly for hot-path operations
extern NSDictionary *SpliceKit_handleTimelineAction(NSDictionary *params);
extern NSDictionary *SpliceKit_handlePlayback(NSDictionary *params);
extern NSDictionary *SpliceKit_handlePlaybackSeek(NSDictionary *params);
extern NSDictionary *SpliceKit_handlePlaybackGetPosition(NSDictionary *params);
extern NSDictionary *SpliceKit_handleTimelineGetDetailedState(NSDictionary *params);
extern NSDictionary *SpliceKit_handleDirectTimelineAction(NSDictionary *params);

// The universal dispatcher — routes any method to its handler
extern NSDictionary *SpliceKit_handleRequest(NSDictionary *request);

// ============================================================================
#pragma mark - Globals
// ============================================================================

static lua_State *sLuaState = NULL;
static dispatch_queue_t sLuaQueue = NULL;
static BOOL sLuaInitialized = NO;

// Print capture buffer (set during execution, read after)
static NSMutableString *sPrintBuffer = nil;

// File watcher
static FSEventStreamRef sEventStream = NULL;
static NSMutableSet<NSString *> *sWatchedPaths = nil;
static NSMutableDictionary<NSString *, NSTimer *> *sDebounceTimers = nil;

// Safety: execution timeout
static NSDate *sExecutionStartTime = nil;
static const NSTimeInterval kExecutionTimeout = 30.0;

// Safety: memory limit (256 MB)
static size_t sLuaMemoryUsed = 0;
static const size_t kLuaMemoryLimit = 256 * 1024 * 1024;

// Scripts base directory
static NSString *sScriptsDir = nil;

// ============================================================================
#pragma mark - Forward Declarations
// ============================================================================

static void SpliceKitLua_registerSkModule(lua_State *L);
static void SpliceKitLua_startFileWatcher(void);
static void SpliceKitLua_stopFileWatcher(void);
static void SpliceKitLua_sandboxStdlibs(lua_State *L);
static void SpliceKitLua_installTimeoutHook(lua_State *L);
static NSNumber *SpliceKitLua_elapsedMilliseconds(NSDate *startTime);

// ============================================================================
#pragma mark - Custom Allocator (Memory Limit)
// ============================================================================

static void *SpliceKitLua_alloc(void *ud, void *ptr, size_t osize, size_t nsize) {
    (void)ud;
    if (nsize == 0) {
        sLuaMemoryUsed -= osize;
        free(ptr);
        return NULL;
    }
    if (sLuaMemoryUsed - osize + nsize > kLuaMemoryLimit) {
        return NULL;  // Lua treats NULL return as out-of-memory error
    }
    sLuaMemoryUsed = sLuaMemoryUsed - osize + nsize;
    return realloc(ptr, nsize);
}

// ============================================================================
#pragma mark - Timeout Hook
// ============================================================================

static void SpliceKitLua_timeoutHook(lua_State *L, lua_Debug *ar) {
    (void)ar;
    if (sExecutionStartTime &&
        [[NSDate date] timeIntervalSinceDate:sExecutionStartTime] > kExecutionTimeout) {
        luaL_error(L, "execution timed out (%.0f second limit)", kExecutionTimeout);
    }
}

static void SpliceKitLua_installTimeoutHook(lua_State *L) {
    // Fire every 100K instructions
    lua_sethook(L, SpliceKitLua_timeoutHook, LUA_MASKCOUNT, 100000);
}

static NSNumber *SpliceKitLua_elapsedMilliseconds(NSDate *startTime) {
    if (!startTime) return @0;
    NSTimeInterval elapsed = [[NSDate date] timeIntervalSinceDate:startTime] * 1000.0;
    if (elapsed < 0) elapsed = 0;
    return @((NSUInteger)elapsed);
}

// ============================================================================
#pragma mark - Print Capture
// ============================================================================

static int sk_print(lua_State *L) {
    int n = lua_gettop(L);
    for (int i = 1; i <= n; i++) {
        if (i > 1) [sPrintBuffer appendString:@"\t"];
        const char *s = luaL_tolstring(L, i, NULL);
        if (s) [sPrintBuffer appendFormat:@"%s", s];
        lua_pop(L, 1);  // pop the string from luaL_tolstring
    }
    [sPrintBuffer appendString:@"\n"];
    return 0;
}

// ============================================================================
#pragma mark - Type Conversions: ObjC → Lua
// ============================================================================

static void SpliceKitLua_pushValue(lua_State *L, id value);

static void SpliceKitLua_pushNSDictionary(lua_State *L, NSDictionary *dict) {
    if (!dict) { lua_pushnil(L); return; }
    lua_createtable(L, 0, (int)dict.count);
    [dict enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
        const char *keyStr = [[key description] UTF8String];
        if (keyStr) {
            lua_pushstring(L, keyStr);
            SpliceKitLua_pushValue(L, obj);
            lua_settable(L, -3);
        }
    }];
}

static void SpliceKitLua_pushNSArray(lua_State *L, NSArray *array) {
    if (!array) { lua_pushnil(L); return; }
    lua_createtable(L, (int)array.count, 0);
    for (NSUInteger i = 0; i < array.count; i++) {
        SpliceKitLua_pushValue(L, array[i]);
        lua_rawseti(L, -2, (lua_Integer)(i + 1));
    }
}

static void SpliceKitLua_pushValue(lua_State *L, id value) {
    if (!value || [value isKindOfClass:[NSNull class]]) {
        lua_pushnil(L);
    } else if ([value isKindOfClass:[NSString class]]) {
        lua_pushstring(L, [value UTF8String]);
    } else if ([value isKindOfClass:[NSNumber class]]) {
        NSNumber *num = value;
        // Check if it's a boolean
        if (strcmp([num objCType], @encode(BOOL)) == 0 ||
            strcmp([num objCType], @encode(char)) == 0) {
            lua_pushboolean(L, [num boolValue]);
        } else if (strcmp([num objCType], @encode(double)) == 0 ||
                   strcmp([num objCType], @encode(float)) == 0) {
            lua_pushnumber(L, [num doubleValue]);
        } else {
            lua_pushinteger(L, [num longLongValue]);
        }
    } else if ([value isKindOfClass:[NSDictionary class]]) {
        SpliceKitLua_pushNSDictionary(L, value);
    } else if ([value isKindOfClass:[NSArray class]]) {
        SpliceKitLua_pushNSArray(L, value);
    } else {
        lua_pushstring(L, [[value description] UTF8String]);
    }
}

// ============================================================================
#pragma mark - Type Conversions: Lua → ObjC
// ============================================================================

static id SpliceKitLua_toObjC(lua_State *L, int idx);

static NSDictionary *SpliceKitLua_toNSDictionary(lua_State *L, int idx) {
    if (!lua_istable(L, idx)) return nil;
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    idx = lua_absindex(L, idx);
    lua_pushnil(L);
    while (lua_next(L, idx)) {
        id key = SpliceKitLua_toObjC(L, -2);
        id val = SpliceKitLua_toObjC(L, -1);
        if (key && val) dict[[key description]] = val;
        lua_pop(L, 1);  // pop value, keep key for next iteration
    }
    return dict;
}

static NSArray *SpliceKitLua_toNSArray(lua_State *L, int idx) {
    if (!lua_istable(L, idx)) return nil;
    NSMutableArray *array = [NSMutableArray array];
    idx = lua_absindex(L, idx);
    lua_Integer len = luaL_len(L, idx);
    for (lua_Integer i = 1; i <= len; i++) {
        lua_rawgeti(L, idx, i);
        id val = SpliceKitLua_toObjC(L, -1);
        [array addObject:val ?: [NSNull null]];
        lua_pop(L, 1);
    }
    return array;
}

// Determine if a Lua table is a sequence (array) or a map (dict)
static BOOL SpliceKitLua_isSequence(lua_State *L, int idx) {
    idx = lua_absindex(L, idx);
    lua_Integer len = luaL_len(L, idx);
    if (len == 0) {
        // Empty table — check if there are any keys at all
        lua_pushnil(L);
        if (lua_next(L, idx)) {
            lua_pop(L, 2);
            return NO;  // has non-integer keys → dict
        }
        return YES;  // truly empty → array
    }
    return YES;  // has sequence part → treat as array
}

static id SpliceKitLua_toObjC(lua_State *L, int idx) {
    switch (lua_type(L, idx)) {
        case LUA_TNIL:
            return [NSNull null];
        case LUA_TBOOLEAN:
            return @(lua_toboolean(L, idx));
        case LUA_TNUMBER:
            if (lua_isinteger(L, idx))
                return @(lua_tointeger(L, idx));
            return @(lua_tonumber(L, idx));
        case LUA_TSTRING:
            return @(lua_tostring(L, idx));
        case LUA_TTABLE:
            if (SpliceKitLua_isSequence(L, idx))
                return SpliceKitLua_toNSArray(L, idx);
            return SpliceKitLua_toNSDictionary(L, idx);
        default:
            return [NSString stringWithFormat:@"<%s>", luaL_typename(L, idx)];
    }
}

// ============================================================================
#pragma mark - Helper: Call Handler on Main Thread
// ============================================================================

// Call a SpliceKit handler on the main thread and return its result.
// The Lua queue is a background queue, so this always crosses threads.
static NSDictionary *SpliceKitLua_callHandler(NSDictionary *(^handler)(void)) {
    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        result = handler();
    });
    return result;
}

// ============================================================================
#pragma mark - sk Module: Bridge Functions
// ============================================================================

// --- Timeline Actions ---

// Generic timeline action: sk.timeline(action) or individual wrappers
static int sk_timeline_action(lua_State *L) {
    const char *action = luaL_checkstring(L, 1);
    NSDictionary *params = @{@"action": @(action)};
    NSDictionary *result = SpliceKitLua_callHandler(^{
        return SpliceKit_handleTimelineAction(params);
    });
    SpliceKitLua_pushValue(L, result);
    return 1;
}

// --- Playback Actions ---

static int sk_playback_action(lua_State *L) {
    const char *action = luaL_checkstring(L, 1);
    NSDictionary *params = @{@"action": @(action)};
    NSDictionary *result = SpliceKitLua_callHandler(^{
        return SpliceKit_handlePlayback(params);
    });
    SpliceKitLua_pushValue(L, result);
    return 1;
}

// --- Convenience Wrappers ---

static int sk_blade(lua_State *L) {
    (void)L;
    NSDictionary *result = SpliceKitLua_callHandler(^{
        return SpliceKit_handleTimelineAction(@{@"action": @"blade"});
    });
    SpliceKitLua_pushValue(L, result);
    return 1;
}

static int sk_undo(lua_State *L) {
    NSDictionary *result = SpliceKitLua_callHandler(^{
        return SpliceKit_handleTimelineAction(@{@"action": @"undo"});
    });
    SpliceKitLua_pushValue(L, result);
    return 1;
}

static int sk_redo(lua_State *L) {
    NSDictionary *result = SpliceKitLua_callHandler(^{
        return SpliceKit_handleTimelineAction(@{@"action": @"redo"});
    });
    SpliceKitLua_pushValue(L, result);
    return 1;
}

static int sk_play(lua_State *L) {
    NSDictionary *result = SpliceKitLua_callHandler(^{
        return SpliceKit_handlePlayback(@{@"action": @"playPause"});
    });
    SpliceKitLua_pushValue(L, result);
    return 1;
}

static int sk_go_to_start(lua_State *L) {
    NSDictionary *result = SpliceKitLua_callHandler(^{
        return SpliceKit_handlePlayback(@{@"action": @"goToStart"});
    });
    SpliceKitLua_pushValue(L, result);
    return 1;
}

static int sk_go_to_end(lua_State *L) {
    NSDictionary *result = SpliceKitLua_callHandler(^{
        return SpliceKit_handlePlayback(@{@"action": @"goToEnd"});
    });
    SpliceKitLua_pushValue(L, result);
    return 1;
}

static int sk_next_frame(lua_State *L) {
    int count = (int)luaL_optinteger(L, 1, 1);
    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        for (int i = 0; i < count; i++) {
            result = SpliceKit_handlePlayback(@{@"action": @"nextFrame"});
        }
    });
    SpliceKitLua_pushValue(L, result);
    return 1;
}

static int sk_prev_frame(lua_State *L) {
    int count = (int)luaL_optinteger(L, 1, 1);
    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        for (int i = 0; i < count; i++) {
            result = SpliceKit_handlePlayback(@{@"action": @"prevFrame"});
        }
    });
    SpliceKitLua_pushValue(L, result);
    return 1;
}

static int sk_seek(lua_State *L) {
    NSMutableDictionary *params = [NSMutableDictionary dictionary];
    if (lua_isnumber(L, 1)) {
        params[@"seconds"] = @(lua_tonumber(L, 1));
    } else {
        params[@"timecode"] = @(luaL_checkstring(L, 1));
    }
    NSDictionary *result = SpliceKitLua_callHandler(^{
        return SpliceKit_handlePlaybackSeek(params);
    });
    SpliceKitLua_pushValue(L, result);
    return 1;
}

static int sk_select_clip(lua_State *L) {
    NSDictionary *result = SpliceKitLua_callHandler(^{
        return SpliceKit_handleTimelineAction(@{@"action": @"selectClipAtPlayhead"});
    });
    SpliceKitLua_pushValue(L, result);
    return 1;
}

static int sk_add_marker(lua_State *L) {
    NSDictionary *result = SpliceKitLua_callHandler(^{
        return SpliceKit_handleTimelineAction(@{@"action": @"addMarker"});
    });
    SpliceKitLua_pushValue(L, result);
    return 1;
}

static int sk_color_board(lua_State *L) {
    NSDictionary *result = SpliceKitLua_callHandler(^{
        return SpliceKit_handleTimelineAction(@{@"action": @"addColorBoard"});
    });
    SpliceKitLua_pushValue(L, result);
    return 1;
}

// --- State Queries ---

static int sk_clips(lua_State *L) {
    // Return the detailed state with full item list — this is what scripts need
    // to iterate over clips, get durations, positions, etc.
    NSDictionary *result = SpliceKitLua_callHandler(^{
        return SpliceKit_handleTimelineGetDetailedState(@{});
    });
    SpliceKitLua_pushValue(L, result);
    return 1;
}

static int sk_position(lua_State *L) {
    NSDictionary *result = SpliceKitLua_callHandler(^{
        return SpliceKit_handlePlaybackGetPosition(@{});
    });
    SpliceKitLua_pushValue(L, result);
    return 1;
}

static int sk_selected(lua_State *L) {
    NSDictionary *request = @{
        @"method": @"selection.getSelectedClips",
        @"params": @{}
    };
    NSDictionary *result = SpliceKitLua_callHandler(^{
        return SpliceKit_handleRequest(request);
    });
    id inner = result[@"result"];
    SpliceKitLua_pushValue(L, inner ?: result);
    return 1;
}

// --- URL Import ---

static int sk_import_url(lua_State *L) {
    const char *url = luaL_checkstring(L, 1);
    NSMutableDictionary *params = [NSMutableDictionary dictionaryWithObject:@(url) forKey:@"url"];
    if (lua_istable(L, 2)) {
        NSDictionary *options = SpliceKitLua_toNSDictionary(L, 2);
        if (options) [params addEntriesFromDictionary:options];
    }
    NSDictionary *response = SpliceKit_handleRequest(@{
        @"method": @"urlImport.import",
        @"params": params
    });
    id result = response[@"result"];
    SpliceKitLua_pushValue(L, result ?: response);
    return 1;
}

static int sk_import_url_start(lua_State *L) {
    const char *url = luaL_checkstring(L, 1);
    NSMutableDictionary *params = [NSMutableDictionary dictionaryWithObject:@(url) forKey:@"url"];
    if (lua_istable(L, 2)) {
        NSDictionary *options = SpliceKitLua_toNSDictionary(L, 2);
        if (options) [params addEntriesFromDictionary:options];
    }
    NSDictionary *response = SpliceKit_handleRequest(@{
        @"method": @"urlImport.start",
        @"params": params
    });
    id result = response[@"result"];
    SpliceKitLua_pushValue(L, result ?: response);
    return 1;
}

static int sk_import_url_status(lua_State *L) {
    const char *jobID = luaL_checkstring(L, 1);
    NSDictionary *response = SpliceKit_handleRequest(@{
        @"method": @"urlImport.status",
        @"params": @{@"job_id": @(jobID)}
    });
    id result = response[@"result"];
    SpliceKitLua_pushValue(L, result ?: response);
    return 1;
}

static int sk_import_url_cancel(lua_State *L) {
    const char *jobID = luaL_checkstring(L, 1);
    NSDictionary *response = SpliceKit_handleRequest(@{
        @"method": @"urlImport.cancel",
        @"params": @{@"job_id": @(jobID)}
    });
    id result = response[@"result"];
    SpliceKitLua_pushValue(L, result ?: response);
    return 1;
}

// --- Generic RPC Passthrough ---

// sk.rpc("method.name", {param = value}) → calls any RPC method
static int sk_rpc(lua_State *L) {
    const char *method = luaL_checkstring(L, 1);
    NSDictionary *params = @{};
    if (lua_istable(L, 2)) {
        params = SpliceKitLua_toNSDictionary(L, 2) ?: @{};
    }
    NSDictionary *request = @{
        @"method": @(method),
        @"params": params
    };
    // Call handleRequest directly on the Lua queue — NOT on the main thread.
    // Each RPC handler internally dispatches to main thread when needed.
    // Forcing everything through the main thread here caused soft deadlocks:
    // polling loops (e.g. transcript.getState) would starve the main thread
    // runloop, preventing async operations (transcription) from progressing.
    NSDictionary *response = SpliceKit_handleRequest(request);
    id result = response[@"result"];
    SpliceKitLua_pushValue(L, result ?: response);
    return 1;
}

// --- ObjC Bridge ---

// sk.eval("NSApp.delegate._targetLibrary.displayName")
static int sk_eval(lua_State *L) {
    const char *expr = luaL_checkstring(L, 1);
    NSDictionary *request = @{
        @"method": @"debug.eval",
        @"params": @{@"expression": @(expr)}
    };
    NSDictionary *response = SpliceKitLua_callHandler(^{
        return SpliceKit_handleRequest(request);
    });
    id result = response[@"result"];
    SpliceKitLua_pushValue(L, result ?: response);
    return 1;
}

// sk.call("FFLibraryDocument", "copyActiveLibraries")
// sk.call(handle, "methodName:", {args})
static int sk_call(lua_State *L) {
    const char *target = luaL_checkstring(L, 1);
    const char *selector = luaL_optstring(L, 2, NULL);

    NSMutableDictionary *params = [NSMutableDictionary dictionary];

    // Determine if target is a handle or a class name
    if (strncmp(target, "obj_", 4) == 0) {
        params[@"target"] = @(target);
    } else {
        params[@"className"] = @(target);
    }

    if (selector) {
        params[@"selector"] = @(selector);
    }

    // Args table (optional 3rd argument)
    if (lua_istable(L, 3)) {
        NSArray *args = SpliceKitLua_toNSArray(L, 3);
        if (args) params[@"args"] = args;
    }

    // Always return a handle for objects
    params[@"returnHandle"] = @YES;

    NSDictionary *request = @{
        @"method": @"system.callMethodWithArgs",
        @"params": params
    };
    NSDictionary *response = SpliceKitLua_callHandler(^{
        return SpliceKit_handleRequest(request);
    });
    id result = response[@"result"];
    SpliceKitLua_pushValue(L, result ?: response);
    return 1;
}

// sk.release(handle) — release an object handle
static int sk_release(lua_State *L) {
    const char *handle = luaL_checkstring(L, 1);
    NSDictionary *request = @{
        @"method": @"object.release",
        @"params": @{@"handle": @(handle)}
    };
    NSDictionary *response = SpliceKitLua_callHandler(^{
        return SpliceKit_handleRequest(request);
    });
    SpliceKitLua_pushValue(L, response[@"result"]);
    return 1;
}

// sk.release_all() — release all handles
static int sk_release_all(lua_State *L) {
    NSDictionary *request = @{
        @"method": @"object.releaseAll",
        @"params": @{}
    };
    NSDictionary *response = SpliceKitLua_callHandler(^{
        return SpliceKit_handleRequest(request);
    });
    SpliceKitLua_pushValue(L, response[@"result"]);
    return 1;
}

// --- Logging ---

static int sk_log(lua_State *L) {
    const char *msg = luaL_checkstring(L, 1);
    SpliceKit_log(@"[Lua] %s", msg);
    return 0;
}

// --- Sleep ---

static int sk_sleep(lua_State *L) {
    double seconds = luaL_checknumber(L, 1);
    if (seconds > 0 && seconds < 60) {
        usleep((useconds_t)(seconds * 1000000));
    }
    return 0;
}

// ============================================================================
#pragma mark - sk Module: UI Functions (alert, toast, prompt)
// ============================================================================

// sk.alert(title, message)
// Shows a floating message panel with an OK button. Non-blocking — returns
// immediately. The panel stays visible until the user clicks OK.
// This avoids all modal/semaphore/threading issues by never blocking.
static int sk_alert(lua_State *L) {
    const char *title = luaL_checkstring(L, 1);
    const char *message = luaL_optstring(L, 2, "");

    NSString *nsTitle = @(title);
    NSString *nsMessage = @(message);

    SpliceKit_executeOnMainThreadAsync(^{
        NSFont *msgFont = [NSFont systemFontOfSize:13];
        CGFloat panelWidth = 440.0;
        CGFloat textWidth = panelWidth - 48.0;
        NSRect textBounds = [nsMessage boundingRectWithSize:NSMakeSize(textWidth, 600)
                                                    options:NSStringDrawingUsesLineFragmentOrigin
                                                 attributes:@{NSFontAttributeName: msgFont}
                                                    context:nil];
        CGFloat textHeight = fmax(ceil(textBounds.size.height), 20);
        if (textHeight > 400) textHeight = 400;
        CGFloat panelHeight = 24 + textHeight + 16 + 36 + 20;

        NSRect screenFrame = [[NSScreen mainScreen] visibleFrame];
        NSRect frame = NSMakeRect(
            NSMidX(screenFrame) - panelWidth / 2,
            NSMidY(screenFrame) - panelHeight / 2 + 100,
            panelWidth, panelHeight);

        NSPanel *panel = [[NSPanel alloc]
            initWithContentRect:frame
                      styleMask:(NSWindowStyleMaskTitled |
                                 NSWindowStyleMaskClosable |
                                 NSWindowStyleMaskUtilityWindow)
                        backing:NSBackingStoreBuffered
                          defer:NO];
        panel.title = nsTitle;
        panel.floatingPanel = YES;
        panel.becomesKeyOnlyIfNeeded = NO;
        panel.hidesOnDeactivate = NO;
        panel.level = NSFloatingWindowLevel;
        panel.releasedWhenClosed = NO;
        panel.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];

        NSView *content = panel.contentView;

        // Message label
        NSTextField *label = [NSTextField wrappingLabelWithString:nsMessage];
        label.translatesAutoresizingMaskIntoConstraints = NO;
        label.font = msgFont;
        label.textColor = [NSColor labelColor];
        label.selectable = YES;
        [content addSubview:label];

        // OK button — closes the panel when clicked
        NSButton *btn = [NSButton buttonWithTitle:@"OK" target:panel action:@selector(close)];
        btn.translatesAutoresizingMaskIntoConstraints = NO;
        btn.bezelStyle = NSBezelStyleRounded;
        btn.keyEquivalent = @"\r";
        [content addSubview:btn];

        [NSLayoutConstraint activateConstraints:@[
            [label.topAnchor constraintEqualToAnchor:content.topAnchor constant:20],
            [label.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:24],
            [label.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-24],

            [btn.topAnchor constraintEqualToAnchor:label.bottomAnchor constant:16],
            [btn.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-20],
            [btn.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-16],
            [btn.widthAnchor constraintGreaterThanOrEqualToConstant:80],
        ]];

        [panel makeKeyAndOrderFront:nil];
    });

    return 0;
}

// sk.toast(message, [duration])
// Shows a brief floating HUD notification that auto-dismisses.
// Does not block script execution.
static int sk_toast(lua_State *L) {
    const char *message = luaL_checkstring(L, 1);
    double duration = luaL_optnumber(L, 2, 3.0);
    if (duration < 0.5) duration = 0.5;
    if (duration > 30.0) duration = 30.0;

    NSString *nsMessage = @(message);
    NSTimeInterval nsDuration = duration;

    SpliceKit_executeOnMainThreadAsync(^{
        // Create a borderless floating window with rounded corners
        CGFloat width = 500.0;
        CGFloat padding = 24.0;

        // Measure text height
        NSFont *font = nil;
        if (@available(macOS 15.0, *)) {
            font = [NSFont monospacedSystemFontOfSize:13 weight:NSFontWeightMedium];
        } else {
            font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
        }
        NSDictionary *attrs = @{NSFontAttributeName: font};
        NSRect textBounds = [nsMessage boundingRectWithSize:NSMakeSize(width - padding * 2, 800)
                                                    options:NSStringDrawingUsesLineFragmentOrigin
                                                 attributes:attrs
                                                    context:nil];
        CGFloat textHeight = ceil(textBounds.size.height);
        CGFloat height = textHeight + padding * 2;
        if (height < 50) height = 50;
        if (height > 600) height = 600;

        NSRect screenFrame = [[NSScreen mainScreen] visibleFrame];
        CGFloat x = NSMidX(screenFrame) - width / 2.0;
        CGFloat y = NSMaxY(screenFrame) - height - 60.0;
        NSRect frame = NSMakeRect(x, y, width, height);

        NSPanel *panel = [[NSPanel alloc]
            initWithContentRect:frame
                      styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                        backing:NSBackingStoreBuffered
                          defer:NO];
        panel.backgroundColor = [NSColor clearColor];
        panel.opaque = NO;
        panel.hasShadow = YES;
        panel.level = NSStatusWindowLevel;
        panel.hidesOnDeactivate = NO;
        panel.releasedWhenClosed = NO;
        panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                                    NSWindowCollectionBehaviorStationary;

        // Vibrancy background
        NSVisualEffectView *bg = [[NSVisualEffectView alloc] initWithFrame:
            NSMakeRect(0, 0, width, height)];
        bg.material = NSVisualEffectMaterialHUDWindow;
        bg.state = NSVisualEffectStateActive;
        bg.blendingMode = NSVisualEffectBlendingModeBehindWindow;
        bg.wantsLayer = YES;
        bg.layer.cornerRadius = 12.0;
        bg.layer.masksToBounds = YES;
        [panel.contentView addSubview:bg];

        // Text label
        NSTextField *label = [NSTextField wrappingLabelWithString:nsMessage];
        label.font = font;
        label.textColor = [NSColor whiteColor];
        label.alignment = NSTextAlignmentCenter;
        label.frame = NSMakeRect(padding, padding, width - padding * 2, textHeight);
        [bg addSubview:label];

        [panel orderFrontRegardless];
        panel.alphaValue = 0.0;

        // Fade in
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
            ctx.duration = 0.25;
            panel.animator.alphaValue = 1.0;
        }];

        // Auto-dismiss after duration
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
            (int64_t)(nsDuration * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
                ctx.duration = 0.4;
                panel.animator.alphaValue = 0.0;
            } completionHandler:^{
                [panel orderOut:nil];
            }];
        });
    });

    return 0;
}

// sk.prompt(title, message, [default_value])
// Shows a floating panel with text input. Non-blocking — opens the panel and
// returns immediately. The user's input is logged when they click OK.
// For scripts that need the value, use sk.rpc("dialog.fill") patterns instead.
static int sk_prompt(lua_State *L) {
    const char *title = luaL_checkstring(L, 1);
    const char *message = luaL_optstring(L, 2, "");
    const char *defaultVal = luaL_optstring(L, 3, "");

    NSString *nsTitle = @(title);
    NSString *nsMessage = @(message);
    NSString *nsDefault = @(defaultVal);

    SpliceKit_executeOnMainThreadAsync(^{
        CGFloat panelWidth = 440.0;
        CGFloat panelHeight = 160.0;

        NSRect screenFrame = [[NSScreen mainScreen] visibleFrame];
        NSRect frame = NSMakeRect(
            NSMidX(screenFrame) - panelWidth / 2,
            NSMidY(screenFrame) - panelHeight / 2 + 100,
            panelWidth, panelHeight);

        NSPanel *panel = [[NSPanel alloc]
            initWithContentRect:frame
                      styleMask:(NSWindowStyleMaskTitled |
                                 NSWindowStyleMaskClosable |
                                 NSWindowStyleMaskUtilityWindow)
                        backing:NSBackingStoreBuffered
                          defer:NO];
        panel.title = nsTitle;
        panel.floatingPanel = YES;
        panel.becomesKeyOnlyIfNeeded = NO;
        panel.hidesOnDeactivate = NO;
        panel.level = NSFloatingWindowLevel;
        panel.releasedWhenClosed = NO;
        panel.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];

        NSView *content = panel.contentView;

        NSTextField *label = [NSTextField wrappingLabelWithString:nsMessage];
        label.translatesAutoresizingMaskIntoConstraints = NO;
        label.font = [NSFont systemFontOfSize:13];
        label.textColor = [NSColor labelColor];
        [content addSubview:label];

        NSTextField *input = [[NSTextField alloc] initWithFrame:NSZeroRect];
        input.translatesAutoresizingMaskIntoConstraints = NO;
        input.stringValue = nsDefault;
        input.font = [NSFont systemFontOfSize:13];
        input.bezeled = YES;
        input.bezelStyle = NSTextFieldRoundedBezel;
        [content addSubview:input];

        // OK button — logs value and closes
        NSButton *okBtn = [NSButton buttonWithTitle:@"OK" target:panel action:@selector(close)];
        okBtn.translatesAutoresizingMaskIntoConstraints = NO;
        okBtn.bezelStyle = NSBezelStyleRounded;
        okBtn.keyEquivalent = @"\r";
        [content addSubview:okBtn];

        // Cancel button — just closes
        NSButton *cancelBtn = [NSButton buttonWithTitle:@"Cancel" target:panel action:@selector(close)];
        cancelBtn.translatesAutoresizingMaskIntoConstraints = NO;
        cancelBtn.bezelStyle = NSBezelStyleRounded;
        cancelBtn.keyEquivalent = @"\033";
        [content addSubview:cancelBtn];

        [NSLayoutConstraint activateConstraints:@[
            [label.topAnchor constraintEqualToAnchor:content.topAnchor constant:16],
            [label.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:24],
            [label.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-24],

            [input.topAnchor constraintEqualToAnchor:label.bottomAnchor constant:10],
            [input.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:24],
            [input.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-24],
            [input.heightAnchor constraintEqualToConstant:24],

            [okBtn.topAnchor constraintEqualToAnchor:input.bottomAnchor constant:14],
            [okBtn.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-20],
            [okBtn.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-14],
            [okBtn.widthAnchor constraintGreaterThanOrEqualToConstant:80],

            [cancelBtn.trailingAnchor constraintEqualToAnchor:okBtn.leadingAnchor constant:-8],
            [cancelBtn.centerYAnchor constraintEqualToAnchor:okBtn.centerYAnchor],
            [cancelBtn.widthAnchor constraintGreaterThanOrEqualToConstant:80],
        ]];

        [panel makeKeyAndOrderFront:nil];
        [panel makeFirstResponder:input];
    });

    return 0;
}

// ============================================================================
#pragma mark - sk Module: __index Metamethod (snake_case → camelCase Fallback)
// ============================================================================

// Maps snake_case names to camelCase timeline/playback action names
static NSDictionary *sSnakeToCamelMap = nil;

static void SpliceKitLua_buildSnakeMap(void) {
    if (sSnakeToCamelMap) return;
    sSnakeToCamelMap = @{
        // Timeline actions
        @"blade_all": @"bladeAll",
        @"add_marker": @"addMarker",
        @"add_todo_marker": @"addTodoMarker",
        @"add_chapter_marker": @"addChapterMarker",
        @"delete_marker": @"deleteMarker",
        @"next_marker": @"nextMarker",
        @"previous_marker": @"previousMarker",
        @"add_transition": @"addTransition",
        @"next_edit": @"nextEdit",
        @"previous_edit": @"previousEdit",
        @"select_clip": @"selectClipAtPlayhead",
        @"select_clip_at_playhead": @"selectClipAtPlayhead",
        @"select_to_playhead": @"selectToPlayhead",
        @"select_all": @"selectAll",
        @"deselect_all": @"deselectAll",
        @"delete_selection": @"delete",
        @"paste_as_connected": @"pasteAsConnected",
        @"replace_with_gap": @"replaceWithGap",
        @"copy_timecode": @"copyTimecode",
        @"insert_gap": @"insertGap",
        @"insert_placeholder": @"insertPlaceholder",
        @"trim_to_playhead": @"trimToPlayhead",
        @"extend_edit": @"extendEditToPlayhead",
        @"join_clips": @"joinClips",
        @"nudge_left": @"nudgeLeft",
        @"nudge_right": @"nudgeRight",
        @"nudge_up": @"nudgeUp",
        @"nudge_down": @"nudgeDown",
        @"add_color_board": @"addColorBoard",
        @"add_color_wheels": @"addColorWheels",
        @"add_color_curves": @"addColorCurves",
        @"color_board": @"addColorBoard",
        @"color_wheels": @"addColorWheels",
        @"color_curves": @"addColorCurves",
        @"balance_color": @"balanceColor",
        @"match_color": @"matchColor",
        @"add_basic_title": @"addBasicTitle",
        @"add_basic_lower_third": @"addBasicLowerThird",
        @"freeze_frame": @"freezeFrame",
        @"retime_normal": @"retimeNormal",
        @"retime_slow_50": @"retimeSlow50",
        @"retime_slow_25": @"retimeSlow25",
        @"retime_fast_2x": @"retimeFast2x",
        @"retime_fast_4x": @"retimeFast4x",
        @"retime_reverse": @"retimeReverse",
        @"detach_audio": @"detachAudio",
        @"expand_audio": @"expandAudio",
        @"create_compound_clip": @"createCompoundClip",
        @"create_storyline": @"createStoryline",
        @"create_audition": @"createAudition",
        @"add_keyframe": @"addKeyframe",
        @"set_range_start": @"setRangeStart",
        @"set_range_end": @"setRangeEnd",
        @"clear_range": @"clearRange",
        @"zoom_to_fit": @"zoomToFit",
        @"zoom_in": @"zoomIn",
        @"zoom_out": @"zoomOut",
        @"toggle_snapping": @"toggleSnapping",
        @"duplicate_project": @"duplicateProject",
        @"export_xml": @"exportXML",
        @"find": @"find",
        @"render_all": @"renderAll",
        @"render_selection": @"renderSelection",

        // Playback actions
        @"go_to_start": @"goToStart",
        @"go_to_end": @"goToEnd",
        @"next_frame": @"nextFrame",
        @"prev_frame": @"prevFrame",
        @"play_pause": @"playPause",
        @"play_around": @"playAroundCurrent",
    };
}

// Timeline actions that we recognize (for __index fallback)
static NSSet *sTimelineActions = nil;
static NSSet *sPlaybackActions = nil;

static void SpliceKitLua_buildActionSets(void) {
    if (sTimelineActions) return;
    sTimelineActions = [NSSet setWithArray:@[
        @"blade", @"bladeAll",
        @"addMarker", @"addTodoMarker", @"addChapterMarker", @"deleteMarker",
        @"nextMarker", @"previousMarker", @"deleteMarkersInSelection",
        @"addTransition",
        @"nextEdit", @"previousEdit", @"selectClipAtPlayhead", @"selectToPlayhead",
        @"selectAll", @"deselectAll",
        @"delete", @"cut", @"copy", @"paste", @"undo", @"redo",
        @"pasteAsConnected", @"replaceWithGap", @"copyTimecode",
        @"connectToPrimaryStoryline", @"insertEdit", @"appendEdit", @"overwriteEdit",
        @"pasteEffects", @"pasteAttributes", @"removeAttributes", @"copyAttributes", @"removeEffects",
        @"insertGap", @"insertPlaceholder", @"addAdjustmentClip",
        @"trimToPlayhead", @"extendEditToPlayhead", @"trimStart", @"trimEnd",
        @"joinClips", @"nudgeLeft", @"nudgeRight", @"nudgeUp", @"nudgeDown",
        @"addColorBoard", @"addColorWheels", @"addColorCurves", @"addColorAdjustment",
        @"addHueSaturation", @"addEnhanceLightAndColor", @"balanceColor", @"matchColor",
        @"addMagneticMask", @"smartConform",
        @"adjustVolumeUp", @"adjustVolumeDown",
        @"expandAudio", @"expandAudioComponents", @"addChannelEQ", @"enhanceAudio",
        @"matchAudio", @"detachAudio",
        @"addBasicTitle", @"addBasicLowerThird",
        @"retimeNormal", @"retimeFast2x", @"retimeFast4x", @"retimeFast8x", @"retimeFast20x",
        @"retimeSlow50", @"retimeSlow25", @"retimeSlow10",
        @"retimeReverse", @"retimeHold", @"freezeFrame",
        @"retimeBladeSpeed", @"retimeSpeedRampToZero", @"retimeSpeedRampFromZero",
        @"addKeyframe", @"deleteKeyframes", @"nextKeyframe", @"previousKeyframe",
        @"favorite", @"reject", @"unrate",
        @"setRangeStart", @"setRangeEnd", @"clearRange", @"setClipRange",
        @"solo", @"disable", @"createCompoundClip", @"autoReframe",
        @"breakApartClipItems", @"synchronizeClips", @"openClip", @"renameClip",
        @"changeDuration",
        @"createStoryline", @"liftFromPrimaryStoryline", @"overwriteToPrimaryStoryline",
        @"collapseToConnectedStoryline",
        @"createAudition", @"finalizeAudition", @"nextAuditionPick", @"previousAuditionPick",
        @"addCaption", @"splitCaption", @"resolveOverlaps",
        @"createMulticamClip",
        @"zoomToFit", @"zoomIn", @"zoomOut", @"verticalZoomToFit",
        @"toggleSnapping", @"toggleSkimming",
        @"toggleInspector", @"toggleTimeline", @"toggleTimelineIndex",
        @"duplicateProject", @"snapshotProject", @"projectProperties",
        @"closeLibrary", @"renderSelection", @"renderAll",
        @"exportXML", @"shareSelection",
        @"find", @"findAndReplaceTitle",
        @"revealInBrowser", @"revealInFinder",
    ]];

    sPlaybackActions = [NSSet setWithArray:@[
        @"playPause", @"goToStart", @"goToEnd",
        @"nextFrame", @"prevFrame", @"nextFrame10", @"prevFrame10",
        @"playAroundCurrent",
    ]];
}

// C function closures for __index (ObjC blocks can't be used as lua_CFunction)
static int sk_dynamic_timeline_action(lua_State *L) {
    const char *action = lua_tostring(L, lua_upvalueindex(1));
    NSDictionary *params = @{@"action": @(action)};
    NSDictionary *result = SpliceKitLua_callHandler(^{
        return SpliceKit_handleTimelineAction(params);
    });
    SpliceKitLua_pushValue(L, result);
    return 1;
}

static int sk_dynamic_playback_action(lua_State *L) {
    const char *action = lua_tostring(L, lua_upvalueindex(1));
    NSDictionary *params = @{@"action": @(action)};
    NSDictionary *result = SpliceKitLua_callHandler(^{
        return SpliceKit_handlePlayback(params);
    });
    SpliceKitLua_pushValue(L, result);
    return 1;
}

// __index metamethod: when sk.something is accessed and it's not in the table,
// check if it maps to a timeline or playback action, and return a closure.
static int sk_index(lua_State *L) {
    const char *key = luaL_checkstring(L, 2);
    NSString *name = @(key);

    SpliceKitLua_buildSnakeMap();
    SpliceKitLua_buildActionSets();

    // Check snake_case map first
    NSString *mapped = sSnakeToCamelMap[name];
    NSString *actionName = mapped ?: name;

    if ([sTimelineActions containsObject:actionName]) {
        lua_pushstring(L, [actionName UTF8String]);
        lua_pushcclosure(L, sk_dynamic_timeline_action, 1);
        return 1;
    }

    if ([sPlaybackActions containsObject:actionName]) {
        lua_pushstring(L, [actionName UTF8String]);
        lua_pushcclosure(L, sk_dynamic_playback_action, 1);
        return 1;
    }

    lua_pushnil(L);
    return 1;
}

// ============================================================================
#pragma mark - Plugin Registration from Lua
// ============================================================================

// Track Lua function refs for registered plugin methods so we can clean up
static NSMutableDictionary<NSString *, NSNumber *> *sLuaPluginRefs = nil;

// sk.register("methodName", handler_function, optional_metadata_table)
// Registers a JSON-RPC method backed by a Lua function.
// If _PLUGIN_ID is set, the method is namespaced as "pluginId.methodName".
static int sk_register_method(lua_State *L) {
    const char *name = luaL_checkstring(L, 1);
    luaL_checktype(L, 2, LUA_TFUNCTION);

    // Read optional metadata table (arg 3)
    NSDictionary *metadata = nil;
    if (lua_istable(L, 3)) {
        metadata = SpliceKitLua_toNSDictionary(L, 3);
    }

    // Determine fully-qualified method name using _PLUGIN_ID if set
    lua_getglobal(L, "_PLUGIN_ID");
    NSString *pluginId = nil;
    if (lua_isstring(L, -1)) {
        pluginId = @(lua_tostring(L, -1));
    }
    lua_pop(L, 1);

    NSString *fullMethod;
    if (pluginId && pluginId.length > 0) {
        fullMethod = [NSString stringWithFormat:@"%@.%s", pluginId, name];
    } else {
        fullMethod = @(name);
    }

    // Store the Lua function as a registry reference
    lua_pushvalue(L, 2);
    int funcRef = luaL_ref(L, LUA_REGISTRYINDEX);

    // Track the ref for cleanup
    if (!sLuaPluginRefs) sLuaPluginRefs = [NSMutableDictionary dictionary];
    // If re-registering, release old ref
    NSNumber *oldRef = sLuaPluginRefs[fullMethod];
    if (oldRef) {
        luaL_unref(L, LUA_REGISTRYINDEX, [oldRef intValue]);
    }
    sLuaPluginRefs[fullMethod] = @(funcRef);

    // Capture what we need for the handler block
    NSString *capturedMethod = [fullMethod copy];
    int capturedRef = funcRef;

    // Create a handler block that marshals NSDictionary → Lua table → NSDictionary
    SpliceKitMethodHandler handler = ^NSDictionary *(NSDictionary *params) {
        __block NSDictionary *result = nil;
        dispatch_sync(sLuaQueue, ^{
            lua_State *Ls = sLuaState;
            if (!Ls) {
                result = @{@"error": @"Lua VM not initialized"};
                return;
            }

            // Push the stored function
            lua_rawgeti(Ls, LUA_REGISTRYINDEX, capturedRef);
            if (!lua_isfunction(Ls, -1)) {
                lua_pop(Ls, 1);
                result = @{@"error": [NSString stringWithFormat:
                    @"Plugin method '%@' handler is no longer valid", capturedMethod]};
                return;
            }

            // Push params as Lua table
            SpliceKitLua_pushValue(Ls, params ?: @{});

            // Install timeout hook
            sExecutionStartTime = [NSDate date];
            lua_sethook(Ls, SpliceKitLua_timeoutHook,
                        LUA_MASKCOUNT, 100000);

            // Call the function
            int status = lua_pcall(Ls, 1, 1, 0);

            // Clear timeout hook
            lua_sethook(Ls, NULL, 0, 0);
            sExecutionStartTime = nil;

            if (status != LUA_OK) {
                const char *err = lua_tostring(Ls, -1);
                result = @{@"error": @(err ?: "unknown Lua error")};
                lua_pop(Ls, 1);
                return;
            }

            // Convert return value to NSDictionary
            if (lua_istable(Ls, -1)) {
                result = SpliceKitLua_toNSDictionary(Ls, -1) ?: @{};
            } else if (lua_isstring(Ls, -1)) {
                result = @{@"result": @(lua_tostring(Ls, -1))};
            } else if (lua_isnumber(Ls, -1)) {
                result = @{@"result": @(lua_tonumber(Ls, -1))};
            } else if (lua_isboolean(Ls, -1)) {
                result = @{@"result": @(lua_toboolean(Ls, -1))};
            } else if (lua_isnil(Ls, -1)) {
                result = @{@"status": @"ok"};
            } else {
                result = @{@"status": @"ok"};
            }
            lua_pop(Ls, 1);
        });
        return result;
    };

    // Enrich metadata with plugin info
    NSMutableDictionary *enrichedMeta = [NSMutableDictionary dictionary];
    if (metadata) [enrichedMeta addEntriesFromDictionary:metadata];
    if (pluginId) enrichedMeta[@"pluginId"] = pluginId;
    enrichedMeta[@"shortName"] = @(name);

    SpliceKit_registerPluginMethod(fullMethod, handler, enrichedMeta);

    lua_pushboolean(L, 1);
    return 1;
}

// sk.unregister("methodName")
// Removes a previously registered plugin method.
static int sk_unregister_method(lua_State *L) {
    const char *name = luaL_checkstring(L, 1);

    // Determine fully-qualified name
    lua_getglobal(L, "_PLUGIN_ID");
    NSString *pluginId = nil;
    if (lua_isstring(L, -1)) {
        pluginId = @(lua_tostring(L, -1));
    }
    lua_pop(L, 1);

    NSString *fullMethod;
    if (pluginId && pluginId.length > 0) {
        fullMethod = [NSString stringWithFormat:@"%@.%s", pluginId, name];
    } else {
        fullMethod = @(name);
    }

    // Release Lua function ref
    NSNumber *ref = sLuaPluginRefs[fullMethod];
    if (ref) {
        luaL_unref(L, LUA_REGISTRYINDEX, [ref intValue]);
        [sLuaPluginRefs removeObjectForKey:fullMethod];
    }

    SpliceKit_unregisterPluginMethod(fullMethod);

    lua_pushboolean(L, 1);
    return 1;
}

// sk.plugin_data_path() — returns writable data directory for the current plugin
static int sk_plugin_data_path(lua_State *L) {
    lua_getglobal(L, "_PLUGIN_ID");
    NSString *pluginId = nil;
    if (lua_isstring(L, -1)) {
        pluginId = @(lua_tostring(L, -1));
    }
    lua_pop(L, 1);

    if (!pluginId || pluginId.length == 0) {
        // Fallback to generic plugin data directory
        NSString *appSupport = [NSSearchPathForDirectoriesInDomains(
            NSApplicationSupportDirectory, NSUserDomainMask, YES) firstObject];
        NSString *dataPath = [appSupport stringByAppendingPathComponent:@"SpliceKit/plugins/_default/data"];
        [[NSFileManager defaultManager] createDirectoryAtPath:dataPath
                                  withIntermediateDirectories:YES attributes:nil error:nil];
        lua_pushstring(L, [dataPath UTF8String]);
        return 1;
    }

    NSString *appSupport = [NSSearchPathForDirectoriesInDomains(
        NSApplicationSupportDirectory, NSUserDomainMask, YES) firstObject];
    NSString *dataPath = [appSupport stringByAppendingPathComponent:
        [NSString stringWithFormat:@"SpliceKit/plugins/%@/data", pluginId]];
    [[NSFileManager defaultManager] createDirectoryAtPath:dataPath
                              withIntermediateDirectories:YES attributes:nil error:nil];
    lua_pushstring(L, [dataPath UTF8String]);
    return 1;
}

// sk.get_config("key") — read a plugin-scoped NSUserDefaults value
static int sk_get_config(lua_State *L) {
    const char *key = luaL_checkstring(L, 1);

    lua_getglobal(L, "_PLUGIN_ID");
    NSString *pluginId = nil;
    if (lua_isstring(L, -1)) {
        pluginId = @(lua_tostring(L, -1));
    }
    lua_pop(L, 1);

    NSString *fullKey;
    if (pluginId && pluginId.length > 0) {
        fullKey = [NSString stringWithFormat:@"SpliceKitPlugin.%@.%s", pluginId, key];
    } else {
        fullKey = [NSString stringWithFormat:@"SpliceKitPlugin.%s", key];
    }

    id value = [[NSUserDefaults standardUserDefaults] objectForKey:fullKey];
    if (value) {
        SpliceKitLua_pushValue(L, value);
    } else {
        lua_pushnil(L);
    }
    return 1;
}

// sk.set_config("key", value) — write a plugin-scoped NSUserDefaults value
static int sk_set_config(lua_State *L) {
    const char *key = luaL_checkstring(L, 1);

    lua_getglobal(L, "_PLUGIN_ID");
    NSString *pluginId = nil;
    if (lua_isstring(L, -1)) {
        pluginId = @(lua_tostring(L, -1));
    }
    lua_pop(L, 1);

    NSString *fullKey;
    if (pluginId && pluginId.length > 0) {
        fullKey = [NSString stringWithFormat:@"SpliceKitPlugin.%@.%s", pluginId, key];
    } else {
        fullKey = [NSString stringWithFormat:@"SpliceKitPlugin.%s", key];
    }

    if (lua_isnil(L, 2)) {
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:fullKey];
    } else {
        id value = SpliceKitLua_toObjC(L, 2);
        if (value && ![value isKindOfClass:[NSNull class]]) {
            [[NSUserDefaults standardUserDefaults] setObject:value forKey:fullKey];
        } else {
            [[NSUserDefaults standardUserDefaults] removeObjectForKey:fullKey];
        }
    }

    lua_pushboolean(L, 1);
    return 1;
}

// ============================================================================
#pragma mark - sk Module Registration
// ============================================================================

static const luaL_Reg sk_functions[] = {
    // Explicit convenience functions
    {"blade",           sk_blade},
    {"undo",            sk_undo},
    {"redo",            sk_redo},
    {"play",            sk_play},
    {"go_to_start",     sk_go_to_start},
    {"go_to_end",       sk_go_to_end},
    {"next_frame",      sk_next_frame},
    {"prev_frame",      sk_prev_frame},
    {"seek",            sk_seek},
    {"select_clip",     sk_select_clip},
    {"add_marker",      sk_add_marker},
    {"color_board",     sk_color_board},

    // State queries
    {"clips",           sk_clips},
    {"position",        sk_position},
    {"selected",        sk_selected},
    {"import_url",      sk_import_url},
    {"import_url_start", sk_import_url_start},
    {"import_url_status", sk_import_url_status},
    {"import_url_cancel", sk_import_url_cancel},

    // Generic access
    {"timeline",        sk_timeline_action},
    {"playback",        sk_playback_action},
    {"rpc",             sk_rpc},

    // ObjC bridge
    {"eval",            sk_eval},
    {"call",            sk_call},
    {"release",         sk_release},
    {"release_all",     sk_release_all},

    // Utility
    {"log",             sk_log},
    {"sleep",           sk_sleep},
    {"wait",            sk_sleep},  // alias

    // UI
    {"alert",           sk_alert},
    {"toast",           sk_toast},
    {"prompt",          sk_prompt},

    // Plugin registration
    {"register",        sk_register_method},
    {"unregister",      sk_unregister_method},
    {"plugin_data_path", sk_plugin_data_path},
    {"get_config",      sk_get_config},
    {"set_config",      sk_set_config},

    {NULL, NULL}
};

static void SpliceKitLua_registerSkModule(lua_State *L) {
    luaL_newlib(L, sk_functions);

    // Set up __index metamethod for snake_case → camelCase fallback
    lua_createtable(L, 0, 1);
    lua_pushcfunction(L, sk_index);
    lua_setfield(L, -2, "__index");
    lua_setmetatable(L, -2);

    lua_setglobal(L, "sk");
}

// ============================================================================
#pragma mark - Sandbox Standard Libraries
// ============================================================================

static int sk_blocked(lua_State *L) {
    return luaL_error(L, "this function is disabled in SpliceKit for safety");
}

static void SpliceKitLua_sandboxStdlibs(lua_State *L) {
    // Block os.exit, os.execute
    lua_getglobal(L, "os");
    if (lua_istable(L, -1)) {
        lua_pushcfunction(L, sk_blocked);
        lua_setfield(L, -2, "exit");
        lua_pushcfunction(L, sk_blocked);
        lua_setfield(L, -2, "execute");
    }
    lua_pop(L, 1);

    // Block io.popen
    lua_getglobal(L, "io");
    if (lua_istable(L, -1)) {
        lua_pushcfunction(L, sk_blocked);
        lua_setfield(L, -2, "popen");
    }
    lua_pop(L, 1);

    // Remove debug.debug (interactive debugger)
    lua_getglobal(L, "debug");
    if (lua_istable(L, -1)) {
        lua_pushnil(L);
        lua_setfield(L, -2, "debug");
    }
    lua_pop(L, 1);
}

// ============================================================================
#pragma mark - VM Lifecycle
// ============================================================================

static void SpliceKitLua_createVM(void) {
    sLuaMemoryUsed = 0;
    sLuaState = lua_newstate(SpliceKitLua_alloc, NULL);
    if (!sLuaState) {
        SpliceKit_log(@"[Lua] Failed to create Lua state");
        return;
    }

    luaL_openlibs(sLuaState);
    SpliceKitLua_sandboxStdlibs(sLuaState);
    SpliceKitLua_registerSkModule(sLuaState);
    SpliceKitLua_installTimeoutHook(sLuaState);

    // Override print
    lua_pushcfunction(sLuaState, sk_print);
    lua_setglobal(sLuaState, "print");

    // Set package.path to include the lib/ directory
    if (sScriptsDir) {
        NSString *libDir = [sScriptsDir stringByAppendingPathComponent:@"lib"];
        NSString *pathAdd = [NSString stringWithFormat:@";%@/?.lua;%@/?/init.lua", libDir, libDir];
        lua_getglobal(sLuaState, "package");
        lua_getfield(sLuaState, -1, "path");
        const char *currentPath = lua_tostring(sLuaState, -1);
        NSString *newPath = [NSString stringWithFormat:@"%s%@", currentPath ?: "", pathAdd];
        lua_pop(sLuaState, 1);
        lua_pushstring(sLuaState, [newPath UTF8String]);
        lua_setfield(sLuaState, -2, "path");
        lua_pop(sLuaState, 1);
    }

    SpliceKit_log(@"[Lua] VM initialized (Lua %s, memory limit %zu MB)",
                  LUA_VERSION_NUM > 500 ? LUA_RELEASE : "5.4", kLuaMemoryLimit / (1024*1024));
}

void SpliceKitLua_initialize(void) {
    if (sLuaInitialized) return;
    sLuaInitialized = YES;

    sLuaQueue = dispatch_queue_create("com.splicekit.lua", DISPATCH_QUEUE_SERIAL);
    sWatchedPaths = [NSMutableSet set];
    sDebounceTimers = [NSMutableDictionary dictionary];

    // Set up scripts directory
    NSString *appSupport = [NSSearchPathForDirectoriesInDomains(
        NSApplicationSupportDirectory, NSUserDomainMask, YES) firstObject];
    sScriptsDir = [appSupport stringByAppendingPathComponent:@"SpliceKit/lua"];

    // Create directory structure
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *sub in @[@"", @"auto", @"lib", @"examples"]) {
        NSString *dir = [sScriptsDir stringByAppendingPathComponent:sub];
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    }

    dispatch_sync(sLuaQueue, ^{
        SpliceKitLua_createVM();
    });

    // Start watching the scripts directory
    SpliceKitLua_startFileWatcher();

    // Execute any scripts in auto/ on launch.
    // Use a global queue — SpliceKitLua_executeFile does its own dispatch_sync
    // to sLuaQueue, and Lua code may call back to main thread.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *autoDir = [sScriptsDir stringByAppendingPathComponent:@"auto"];
        NSArray *files = [fm contentsOfDirectoryAtPath:autoDir error:nil];
        for (NSString *file in files) {
            if ([file.pathExtension isEqualToString:@"lua"]) {
                NSString *path = [autoDir stringByAppendingPathComponent:file];
                SpliceKit_log(@"[Lua] Auto-executing: %@", file);
                NSDictionary *result = SpliceKitLua_executeFile(path);
                if (result[@"error"]) {
                    SpliceKit_log(@"[Lua] Error in %@: %@", file, result[@"error"]);
                }
            }
        }
    });
}

void SpliceKitLua_reset(void) {
    dispatch_sync(sLuaQueue, ^{
        if (sLuaState) {
            lua_close(sLuaState);
            sLuaState = NULL;
        }
        SpliceKitLua_createVM();
    });
    SpliceKit_log(@"[Lua] VM reset");
}

BOOL SpliceKitLua_isInitialized(void) {
    return sLuaInitialized && sLuaState != NULL;
}

// ============================================================================
#pragma mark - Execute
// ============================================================================

NSDictionary *SpliceKitLua_execute(NSString *code) {
    if (!sLuaState) return @{@"ok": @NO, @"error": @"Lua VM not initialized"};

    __block NSDictionary *result = nil;
    dispatch_sync(sLuaQueue, ^{
        sPrintBuffer = [NSMutableString string];
        NSDate *startTime = [NSDate date];
        sExecutionStartTime = startTime;

        lua_State *L = sLuaState;

        // Expression eval trick: try "return <code>" first
        NSString *exprCode = [NSString stringWithFormat:@"return %@", code];
        int loadStatus = luaL_loadstring(L, [exprCode UTF8String]);
        if (loadStatus != LUA_OK) {
            lua_pop(L, 1);  // pop error from failed attempt
            loadStatus = luaL_loadstring(L, [code UTF8String]);
        }

        if (loadStatus != LUA_OK) {
            const char *err = lua_tostring(L, -1);
            result = @{
                @"ok": @NO,
                @"error": @(err ?: "compilation error"),
                @"output": [sPrintBuffer copy],
                @"durationMs": SpliceKitLua_elapsedMilliseconds(startTime)
            };
            lua_pop(L, 1);
        } else {
            int callStatus = lua_pcall(L, 0, LUA_MULTRET, 0);
            if (callStatus != LUA_OK) {
                const char *err = lua_tostring(L, -1);
                result = @{
                    @"ok": @NO,
                    @"error": @(err ?: "runtime error"),
                    @"output": [sPrintBuffer copy],
                    @"durationMs": SpliceKitLua_elapsedMilliseconds(startTime)
                };
                lua_pop(L, 1);
            } else {
                // Collect return values
                int nresults = lua_gettop(L);
                NSString *resultStr = nil;
                if (nresults > 0) {
                    NSMutableArray *values = [NSMutableArray array];
                    for (int i = 1; i <= nresults; i++) {
                        const char *s = luaL_tolstring(L, i, NULL);
                        if (s) [values addObject:@(s)];
                        lua_pop(L, 1);  // pop tolstring result
                    }
                    resultStr = [values componentsJoinedByString:@"\t"];
                    lua_pop(L, nresults);  // pop all return values
                }

                NSMutableDictionary *d = [NSMutableDictionary dictionary];
                d[@"ok"] = @YES;
                d[@"output"] = [sPrintBuffer copy];
                d[@"durationMs"] = SpliceKitLua_elapsedMilliseconds(startTime);
                if (resultStr.length > 0) d[@"result"] = resultStr;
                result = d;
            }
        }

        sExecutionStartTime = nil;
        sPrintBuffer = nil;
    });

    return result;
}

NSDictionary *SpliceKitLua_executeFile(NSString *path) {
    if (!sLuaState) return @{@"ok": @NO, @"error": @"Lua VM not initialized"};

    // Resolve relative paths
    if (![path hasPrefix:@"/"]) {
        path = [sScriptsDir stringByAppendingPathComponent:path];
    }

    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        return @{
            @"ok": @NO,
            @"error": [NSString stringWithFormat:@"file not found: %@", path]
        };
    }

    __block NSDictionary *result = nil;
    dispatch_sync(sLuaQueue, ^{
        sPrintBuffer = [NSMutableString string];
        NSDate *startTime = [NSDate date];
        sExecutionStartTime = startTime;

        lua_State *L = sLuaState;
        int loadStatus = luaL_loadfile(L, [path UTF8String]);

        if (loadStatus != LUA_OK) {
            const char *err = lua_tostring(L, -1);
            result = @{
                @"ok": @NO,
                @"error": @(err ?: "file load error"),
                @"output": [sPrintBuffer copy],
                @"durationMs": SpliceKitLua_elapsedMilliseconds(startTime)
            };
            lua_pop(L, 1);
        } else {
            int callStatus = lua_pcall(L, 0, LUA_MULTRET, 0);
            if (callStatus != LUA_OK) {
                const char *err = lua_tostring(L, -1);
                result = @{
                    @"ok": @NO,
                    @"error": @(err ?: "runtime error"),
                    @"output": [sPrintBuffer copy],
                    @"durationMs": SpliceKitLua_elapsedMilliseconds(startTime)
                };
                lua_pop(L, 1);
            } else {
                int nresults = lua_gettop(L);
                NSString *resultStr = nil;
                if (nresults > 0) {
                    NSMutableArray *values = [NSMutableArray array];
                    for (int i = 1; i <= nresults; i++) {
                        const char *s = luaL_tolstring(L, i, NULL);
                        if (s) [values addObject:@(s)];
                        lua_pop(L, 1);
                    }
                    resultStr = [values componentsJoinedByString:@"\t"];
                    lua_pop(L, nresults);
                }

                NSMutableDictionary *d = [NSMutableDictionary dictionary];
                d[@"ok"] = @YES;
                d[@"output"] = [sPrintBuffer copy];
                d[@"durationMs"] = SpliceKitLua_elapsedMilliseconds(startTime);
                if (resultStr.length > 0) d[@"result"] = resultStr;
                result = d;
            }
        }

        sExecutionStartTime = nil;
        sPrintBuffer = nil;
    });

    return result;
}

// ============================================================================
#pragma mark - Get State
// ============================================================================

NSDictionary *SpliceKitLua_getState(void) {
    if (!sLuaState) return @{@"error": @"Lua VM not initialized"};

    __block NSDictionary *result = nil;
    dispatch_sync(sLuaQueue, ^{
        lua_State *L = sLuaState;

        // Memory usage
        int memKB = lua_gc(L, LUA_GCCOUNT, 0);

        // Enumerate globals
        NSMutableArray *globals = [NSMutableArray array];
        lua_pushglobaltable(L);
        lua_pushnil(L);
        while (lua_next(L, -2)) {
            const char *key = lua_tostring(L, -2);
            if (key) {
                // Skip standard library names
                NSString *name = @(key);
                static NSSet *stdlibs = nil;
                if (!stdlibs) stdlibs = [NSSet setWithArray:@[
                    @"_G", @"_VERSION", @"assert", @"collectgarbage", @"coroutine",
                    @"debug", @"dofile", @"error", @"getmetatable", @"io", @"ipairs",
                    @"load", @"loadfile", @"math", @"next", @"os", @"package", @"pairs",
                    @"pcall", @"print", @"rawequal", @"rawget", @"rawlen", @"rawset",
                    @"require", @"select", @"setmetatable", @"sk", @"string", @"table",
                    @"tonumber", @"tostring", @"type", @"utf8", @"warn", @"xpcall",
                ]];
                if (![stdlibs containsObject:name]) {
                    NSString *typeName = @(luaL_typename(L, -1));
                    [globals addObject:@{@"name": name, @"type": typeName}];
                }
            }
            lua_pop(L, 1);
        }
        lua_pop(L, 1);  // pop global table

        result = @{
            @"memory_kb": @(memKB),
            @"memory_limit_mb": @(kLuaMemoryLimit / (1024 * 1024)),
            @"globals": globals,
            @"watched_paths": [sWatchedPaths allObjects] ?: @[],
            @"scripts_dir": sScriptsDir ?: @"",
        };
    });

    return result;
}

// ============================================================================
#pragma mark - File Watcher
// ============================================================================

static void SpliceKitLua_fsEventCallback(
    ConstFSEventStreamRef streamRef,
    void *info,
    size_t numEvents,
    void *eventPaths,
    const FSEventStreamEventFlags eventFlags[],
    const FSEventStreamEventId eventIds[])
{
    (void)streamRef; (void)info; (void)eventFlags; (void)eventIds;
    CFArrayRef paths = (CFArrayRef)eventPaths;

    for (size_t i = 0; i < numEvents; i++) {
        NSString *path = (__bridge NSString *)CFArrayGetValueAtIndex(paths, i);
        if (![path.pathExtension isEqualToString:@"lua"]) continue;

        // Only auto-execute files in auto/ directories
        BOOL isAuto = NO;
        for (NSString *watchPath in sWatchedPaths) {
            NSString *autoDir = [watchPath stringByAppendingPathComponent:@"auto"];
            if ([path hasPrefix:autoDir]) {
                isAuto = YES;
                break;
            }
        }
        if (!isAuto) continue;

        // Debounce: coalesce rapid events for the same file
        dispatch_async(dispatch_get_main_queue(), ^{
            NSTimer *existing = sDebounceTimers[path];
            [existing invalidate];
            sDebounceTimers[path] = [NSTimer scheduledTimerWithTimeInterval:0.1
                repeats:NO block:^(NSTimer *timer) {
                    (void)timer;
                    [sDebounceTimers removeObjectForKey:path];
                    SpliceKit_log(@"[Lua] File changed, executing: %@", [path lastPathComponent]);
                    // Dispatch to a global queue, NOT sLuaQueue.
                    // SpliceKitLua_executeFile does its own dispatch_sync to sLuaQueue,
                    // and from there Lua code may call SpliceKit_executeOnMainThread.
                    // Main thread must be free to service those calls.
                    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                        NSDictionary *result = SpliceKitLua_executeFile(path);
                        if (result[@"error"]) {
                            SpliceKit_log(@"[Lua] Error in %@: %@",
                                          [path lastPathComponent], result[@"error"]);
                        } else if ([result[@"output"] length] > 0) {
                            SpliceKit_log(@"[Lua] %@: %@",
                                          [path lastPathComponent], result[@"output"]);
                        }
                        // Broadcast to connected MCP clients
                        SpliceKit_broadcastEvent(@{
                            @"type": @"lua.fileExecuted",
                            @"file": [path lastPathComponent],
                            @"result": result ?: @{}
                        });
                    });
                }];
        });
    }
}

static void SpliceKitLua_startFileWatcher(void) {
    [sWatchedPaths addObject:sScriptsDir];

    CFArrayRef pathsToWatch = (__bridge CFArrayRef)@[sScriptsDir];
    FSEventStreamContext ctx = {0, NULL, NULL, NULL, NULL};

    sEventStream = FSEventStreamCreate(
        kCFAllocatorDefault,
        &SpliceKitLua_fsEventCallback,
        &ctx,
        pathsToWatch,
        kFSEventStreamEventIdSinceNow,
        0.2,  // latency in seconds
        kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
    );

    if (sEventStream) {
        FSEventStreamSetDispatchQueue(sEventStream, dispatch_get_main_queue());
        FSEventStreamStart(sEventStream);
        SpliceKit_log(@"[Lua] File watcher started on %@", sScriptsDir);
    }
}

static void SpliceKitLua_stopFileWatcher(void) {
    if (sEventStream) {
        FSEventStreamStop(sEventStream);
        FSEventStreamInvalidate(sEventStream);
        FSEventStreamRelease(sEventStream);
        sEventStream = NULL;
    }
}

NSDictionary *SpliceKitLua_watchAction(NSString *action, NSString *path) {
    if ([action isEqualToString:@"add"] && path.length > 0) {
        // Expand tilde
        path = [path stringByExpandingTildeInPath];
        BOOL isDir = NO;
        if (![[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDir] || !isDir) {
            return @{@"error": [NSString stringWithFormat:@"directory not found: %@", path]};
        }
        [sWatchedPaths addObject:path];
        // Restart watcher with new paths
        SpliceKitLua_stopFileWatcher();
        SpliceKitLua_startFileWatcher();
        return @{@"status": @"added", @"watched_paths": [sWatchedPaths allObjects]};
    } else if ([action isEqualToString:@"remove"] && path.length > 0) {
        path = [path stringByExpandingTildeInPath];
        [sWatchedPaths removeObject:path];
        SpliceKitLua_stopFileWatcher();
        if (sWatchedPaths.count > 0) SpliceKitLua_startFileWatcher();
        return @{@"status": @"removed", @"watched_paths": [sWatchedPaths allObjects]};
    } else if ([action isEqualToString:@"list"]) {
        return @{@"watched_paths": [sWatchedPaths allObjects]};
    }
    return @{@"error": @"invalid action (use: add, remove, list)"};
}

// ============================================================================
#pragma mark - JSON-RPC Handlers
// ============================================================================

NSDictionary *SpliceKit_handleLuaExecute(NSDictionary *params) {
    NSString *code = params[@"code"];
    if (!code) return @{@"error": @"missing 'code' parameter"};
    return SpliceKitLua_execute(code);
}

NSDictionary *SpliceKit_handleLuaExecuteFile(NSDictionary *params) {
    NSString *path = params[@"path"];
    if (!path) return @{@"error": @"missing 'path' parameter"};
    return SpliceKitLua_executeFile(path);
}

NSDictionary *SpliceKit_handleLuaReset(NSDictionary *params) {
    (void)params;
    SpliceKitLua_reset();
    return @{@"status": @"ok"};
}

NSDictionary *SpliceKit_handleLuaGetState(NSDictionary *params) {
    (void)params;
    return SpliceKitLua_getState();
}

NSDictionary *SpliceKit_handleLuaWatch(NSDictionary *params) {
    NSString *action = params[@"action"] ?: @"list";
    NSString *path = params[@"path"] ?: @"";
    return SpliceKitLua_watchAction(action, path);
}
