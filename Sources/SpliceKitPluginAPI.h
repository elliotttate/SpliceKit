//
//  SpliceKitPluginAPI.h
//  SpliceKit — Public API for native plugin authors.
//
//  Native plugins export a single entry point:
//    void SpliceKitPlugin_init(SpliceKitPluginAPI *api);
//
//  The API struct provides versioned access to SpliceKit's core functions.
//  This avoids symbol conflicts between plugins and provides a stable interface
//  even if SpliceKit's internal symbols change.
//

#ifndef SpliceKitPluginAPI_h
#define SpliceKitPluginAPI_h

#import <Foundation/Foundation.h>
#import <objc/runtime.h>

// Handler block type — same type used internally by SpliceKit.
// Receives JSON-RPC params, returns a result dictionary.
typedef NSDictionary *(^SpliceKitMethodHandler)(NSDictionary *params);

typedef struct {
    // API version (currently 1). Check this before using any fields.
    int apiVersion;

    // Plugin identity (set by the loader before calling init)
    const char *pluginId;    // e.g. "com.example.my-plugin"
    const char *dataPath;    // writable data directory for this plugin

    // --- Method Registration ---
    // Register a JSON-RPC method. The method name will be prefixed with the plugin ID.
    // metadata: optional dict with "description", "params", "readOnly" keys.
    void (*registerMethod)(NSString *method, SpliceKitMethodHandler handler, NSDictionary *metadata);
    void (*unregisterMethod)(NSString *method);

    // --- Logging ---
    void (*log)(NSString *format, ...) NS_FORMAT_FUNCTION(1,2);

    // --- Thread Management ---
    void (*executeOnMainThread)(dispatch_block_t block);
    void (*executeOnMainThreadAsync)(dispatch_block_t block);

    // --- Event Broadcasting ---
    // Push a JSON-RPC notification to all connected clients (MCP, TCP).
    void (*broadcastEvent)(NSDictionary *event);

    // --- Object Handle System ---
    // Keep ObjC objects alive across multiple RPC calls.
    NSString *(*storeHandle)(id object);
    id (*resolveHandle)(NSString *handleId);
    void (*releaseHandle)(NSString *handleId);

    // --- Swizzling ---
    // Swap a method implementation. Returns the original IMP.
    IMP (*swizzleMethod)(Class cls, SEL selector, IMP newImpl);
    BOOL (*unswizzleMethod)(Class cls, SEL selector);

    // --- RPC Passthrough ---
    // Call any built-in SpliceKit JSON-RPC method.
    // request must contain "method" and optionally "params".
    NSDictionary *(*callMethod)(NSDictionary *request);
} SpliceKitPluginAPI;

// Native plugin entry point. Called once when the plugin is loaded.
// The api struct is valid for the lifetime of FCP's process.
typedef void (*SpliceKitPluginInitFunc)(SpliceKitPluginAPI *api);

#endif /* SpliceKitPluginAPI_h */
