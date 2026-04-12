//
//  SpliceKitPlugins.m
//  SpliceKit — Plugin discovery and loading.
//
//  Scans ~/Library/Application Support/SpliceKit/plugins/ for directories
//  containing a plugin.json manifest. Supports Lua and native (dylib) plugins.
//
//  Loading order:
//  1. Discover all plugin.json manifests
//  2. Validate required fields and apiVersion
//  3. Topological sort by dependencies
//  4. For each plugin: set _PLUGIN_ID, load Lua init.lua / dlopen native dylib
//

#import "SpliceKitPlugins.h"
#import "SpliceKit.h"
#import "SpliceKitLua.h"
#import "SpliceKitPluginAPI.h"
#import <dlfcn.h>

// The universal dispatcher (defined in SpliceKitServer.m)
extern NSDictionary *SpliceKit_handleRequest(NSDictionary *request);

// Current API version. Increment when adding new fields to SpliceKitPluginAPI.
static const int kPluginAPIVersion = 1;

// Track loaded native plugin handles for unloading
static NSMutableDictionary<NSString *, NSValue *> *sNativePluginHandles = nil;

// ============================================================================
#pragma mark - Manifest Parsing
// ============================================================================

static NSDictionary *SpliceKitPlugins_readManifest(NSString *pluginDir) {
    NSString *manifestPath = [pluginDir stringByAppendingPathComponent:@"plugin.json"];
    NSData *data = [NSData dataWithContentsOfFile:manifestPath];
    if (!data) return nil;

    NSError *error = nil;
    NSDictionary *manifest = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    if (error || ![manifest isKindOfClass:[NSDictionary class]]) {
        SpliceKit_log(@"[Plugin] Failed to parse %@: %@", manifestPath,
                      error.localizedDescription ?: @"not a JSON object");
        return nil;
    }
    return manifest;
}

static BOOL SpliceKitPlugins_validateManifest(NSDictionary *manifest, NSString *pluginDir) {
    NSArray *required = @[@"id", @"name", @"version"];
    for (NSString *key in required) {
        if (![manifest[key] isKindOfClass:[NSString class]]) {
            SpliceKit_log(@"[Plugin] Missing or invalid '%@' in %@/plugin.json", key, pluginDir);
            return NO;
        }
    }

    NSNumber *apiVersion = manifest[@"apiVersion"];
    if (apiVersion && [apiVersion intValue] > kPluginAPIVersion) {
        SpliceKit_log(@"[Plugin] %@ requires apiVersion %@ (we support %d), skipping",
                      manifest[@"id"], apiVersion, kPluginAPIVersion);
        return NO;
    }

    return YES;
}

// ============================================================================
#pragma mark - Dependency Sorting
// ============================================================================

static NSArray<NSDictionary *> *SpliceKitPlugins_sortByDependencies(NSArray<NSDictionary *> *manifests) {
    // Build a lookup by plugin ID
    NSMutableDictionary<NSString *, NSDictionary *> *byId = [NSMutableDictionary dictionary];
    for (NSDictionary *m in manifests) {
        byId[m[@"id"]] = m;
    }

    NSMutableArray<NSDictionary *> *sorted = [NSMutableArray array];
    NSMutableSet<NSString *> *visited = [NSMutableSet set];
    NSMutableSet<NSString *> *visiting = [NSMutableSet set]; // cycle detection

    __block __weak BOOL (^weakVisit)(NSString *) = nil;
    BOOL (^visit)(NSString *) = nil;
    weakVisit = visit = ^BOOL(NSString *pluginId) {
        if ([visited containsObject:pluginId]) return YES;
        if ([visiting containsObject:pluginId]) {
            SpliceKit_log(@"[Plugin] Circular dependency detected involving %@", pluginId);
            return NO;
        }

        NSDictionary *m = byId[pluginId];
        if (!m) {
            SpliceKit_log(@"[Plugin] Missing dependency: %@", pluginId);
            return NO;
        }

        [visiting addObject:pluginId];

        NSArray *deps = m[@"dependencies"];
        if ([deps isKindOfClass:[NSArray class]]) {
            for (NSString *dep in deps) {
                if (![dep isKindOfClass:[NSString class]]) continue;
                BOOL (^strongVisit)(NSString *) = weakVisit;
                if (!strongVisit || !strongVisit(dep)) return NO;
            }
        }

        [visiting removeObject:pluginId];
        [visited addObject:pluginId];
        [sorted addObject:m];
        return YES;
    };

    for (NSDictionary *m in manifests) {
        if (![visited containsObject:m[@"id"]]) {
            if (!visit(m[@"id"])) {
                SpliceKit_log(@"[Plugin] Skipping %@ due to dependency issues", m[@"id"]);
            }
        }
    }

    return sorted;
}

// ============================================================================
#pragma mark - Native Plugin Loading
// ============================================================================

// Wrapper for SpliceKit_log that matches variadic C function pointer signature.
// The SpliceKitPluginAPI struct needs a function pointer, but SpliceKit_log is
// declared with NS_FORMAT_FUNCTION which is fine for direct calls but tricky
// for function pointers in a struct. We use this thin wrapper.
static void SpliceKitPlugins_logWrapper(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    SpliceKit_log(@"%@", msg);
}

static BOOL SpliceKitPlugins_loadNative(NSDictionary *manifest, NSString *pluginDir) {
    NSDictionary *entry = manifest[@"entry"];
    NSString *nativePath = entry[@"native"];
    if (!nativePath) return NO;

    NSString *fullPath = [pluginDir stringByAppendingPathComponent:nativePath];
    if (![[NSFileManager defaultManager] fileExistsAtPath:fullPath]) {
        SpliceKit_log(@"[Plugin] Native binary not found: %@", fullPath);
        return NO;
    }

    void *handle = dlopen([fullPath UTF8String], RTLD_NOW | RTLD_LOCAL);
    if (!handle) {
        const char *err = dlerror();
        SpliceKit_log(@"[Plugin] dlopen failed for %@: %s", manifest[@"id"], err ?: "unknown");
        return NO;
    }

    // Look up the init function
    SpliceKitPluginInitFunc initFunc = (SpliceKitPluginInitFunc)dlsym(handle, "SpliceKitPlugin_init");
    if (!initFunc) {
        SpliceKit_log(@"[Plugin] No SpliceKitPlugin_init symbol in %@", manifest[@"id"]);
        dlclose(handle);
        return NO;
    }

    // Build the data path
    NSString *dataPath = [pluginDir stringByAppendingPathComponent:@"data"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dataPath
                              withIntermediateDirectories:YES attributes:nil error:nil];

    // Build the API struct
    NSString *pluginId = manifest[@"id"];
    SpliceKitPluginAPI api = {
        .apiVersion = kPluginAPIVersion,
        .pluginId = [pluginId UTF8String],
        .dataPath = [dataPath UTF8String],
        .registerMethod = SpliceKit_registerPluginMethod,
        .unregisterMethod = SpliceKit_unregisterPluginMethod,
        .log = SpliceKitPlugins_logWrapper,
        .executeOnMainThread = SpliceKit_executeOnMainThread,
        .executeOnMainThreadAsync = SpliceKit_executeOnMainThreadAsync,
        .broadcastEvent = SpliceKit_broadcastEvent,
        .storeHandle = SpliceKit_storeHandle,
        .resolveHandle = SpliceKit_resolveHandle,
        .releaseHandle = SpliceKit_releaseHandle,
        .swizzleMethod = SpliceKit_swizzleMethod,
        .unswizzleMethod = SpliceKit_unswizzleMethod,
        .callMethod = SpliceKit_handleRequest,
    };

    // Call the plugin's init
    initFunc(&api);

    // Store the handle
    if (!sNativePluginHandles) sNativePluginHandles = [NSMutableDictionary dictionary];
    sNativePluginHandles[pluginId] = [NSValue valueWithPointer:handle];

    SpliceKit_log(@"[Plugin] Loaded native plugin: %@", pluginId);
    return YES;
}

// ============================================================================
#pragma mark - Lua Plugin Loading
// ============================================================================

static BOOL SpliceKitPlugins_loadLua(NSDictionary *manifest, NSString *pluginDir) {
    NSDictionary *entry = manifest[@"entry"];
    NSString *luaEntry = entry[@"lua"];
    if (!luaEntry) return NO;

    NSString *fullPath = [pluginDir stringByAppendingPathComponent:luaEntry];
    if (![[NSFileManager defaultManager] fileExistsAtPath:fullPath]) {
        SpliceKit_log(@"[Plugin] Lua entry not found: %@", fullPath);
        return NO;
    }

    NSString *pluginId = manifest[@"id"];

    // Add plugin's lib/ directory to Lua package.path
    NSString *libDir = [pluginDir stringByAppendingPathComponent:@"lib"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:libDir]) {
        NSString *addPath = [NSString stringWithFormat:
            @"package.path = package.path .. ';%@/?.lua;%@/?/init.lua'", libDir, libDir];
        SpliceKitLua_execute(addPath);
    }

    // Set _PLUGIN_ID before executing the init script
    NSString *setPluginId = [NSString stringWithFormat:@"_PLUGIN_ID = '%@'", pluginId];
    SpliceKitLua_execute(setPluginId);

    // Execute the init script
    NSDictionary *result = SpliceKitLua_executeFile(fullPath);

    // Clear _PLUGIN_ID after loading
    SpliceKitLua_execute(@"_PLUGIN_ID = nil");

    if (result[@"error"]) {
        SpliceKit_log(@"[Plugin] Error loading Lua plugin %@: %@", pluginId, result[@"error"]);
        return NO;
    }

    SpliceKit_log(@"[Plugin] Loaded Lua plugin: %@", pluginId);
    return YES;
}

// ============================================================================
#pragma mark - Public API
// ============================================================================

void SpliceKitPlugins_loadAll(void) {
    NSString *appSupport = [NSSearchPathForDirectoriesInDomains(
        NSApplicationSupportDirectory, NSUserDomainMask, YES) firstObject];
    NSString *pluginsDir = [appSupport stringByAppendingPathComponent:@"SpliceKit/plugins"];

    // Create plugins directory if it doesn't exist
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:pluginsDir withIntermediateDirectories:YES attributes:nil error:nil];

    // Discover plugins
    NSArray *contents = [fm contentsOfDirectoryAtPath:pluginsDir error:nil];
    if (!contents || contents.count == 0) {
        SpliceKit_log(@"[Plugin] No plugins found in %@", pluginsDir);
        return;
    }

    NSMutableArray<NSDictionary *> *manifests = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSString *> *pluginDirs = [NSMutableDictionary dictionary];

    for (NSString *name in contents) {
        NSString *pluginDir = [pluginsDir stringByAppendingPathComponent:name];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:pluginDir isDirectory:&isDir] || !isDir) continue;

        NSDictionary *manifest = SpliceKitPlugins_readManifest(pluginDir);
        if (!manifest) continue;

        if (!SpliceKitPlugins_validateManifest(manifest, pluginDir)) continue;

        // Check if plugin is disabled via preferences
        NSString *pluginId = manifest[@"id"];
        NSString *disabledKey = [NSString stringWithFormat:@"SpliceKitPlugin.%@.disabled", pluginId];
        if ([[NSUserDefaults standardUserDefaults] boolForKey:disabledKey]) {
            SpliceKit_log(@"[Plugin] %@ is disabled, skipping", pluginId);
            continue;
        }

        // Attach the directory path to the manifest for loading
        NSMutableDictionary *enriched = [manifest mutableCopy];
        enriched[@"_dir"] = pluginDir;
        [manifests addObject:enriched];
        pluginDirs[pluginId] = pluginDir;
    }

    if (manifests.count == 0) {
        SpliceKit_log(@"[Plugin] No valid plugins found");
        return;
    }

    SpliceKit_log(@"[Plugin] Found %lu plugin(s), sorting by dependencies...",
                  (unsigned long)manifests.count);

    // Sort by dependencies
    NSArray<NSDictionary *> *sorted = SpliceKitPlugins_sortByDependencies(manifests);

    // Load each plugin
    for (NSDictionary *manifest in sorted) {
        NSString *pluginId = manifest[@"id"];
        NSString *pluginDir = manifest[@"_dir"];

        SpliceKit_log(@"[Plugin] Loading %@ v%@ (%@)",
                      manifest[@"name"], manifest[@"version"], pluginId);

        // Create data directory
        NSString *dataDir = [pluginDir stringByAppendingPathComponent:@"data"];
        [fm createDirectoryAtPath:dataDir withIntermediateDirectories:YES attributes:nil error:nil];

        // Register the manifest for introspection
        NSMutableDictionary *cleanManifest = [manifest mutableCopy];
        [cleanManifest removeObjectForKey:@"_dir"];
        SpliceKit_registerPluginManifest(pluginId, cleanManifest);

        // Load native first (if present), then Lua
        NSDictionary *entry = manifest[@"entry"];
        BOOL loaded = NO;
        if (entry[@"native"]) {
            loaded = SpliceKitPlugins_loadNative(manifest, pluginDir);
        }
        if (entry[@"lua"]) {
            loaded = SpliceKitPlugins_loadLua(manifest, pluginDir) || loaded;
        }

        if (!loaded) {
            SpliceKit_log(@"[Plugin] %@ has no valid entry points", pluginId);
        }
    }

    SpliceKit_log(@"[Plugin] Finished loading %lu plugin(s)", (unsigned long)sorted.count);
}

NSDictionary *SpliceKitPlugins_reloadPlugin(NSString *pluginId) {
    NSString *appSupport = [NSSearchPathForDirectoriesInDomains(
        NSApplicationSupportDirectory, NSUserDomainMask, YES) firstObject];
    NSString *pluginsDir = [appSupport stringByAppendingPathComponent:@"SpliceKit/plugins"];

    // Find the plugin directory
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *contents = [fm contentsOfDirectoryAtPath:pluginsDir error:nil];
    for (NSString *name in contents) {
        NSString *pluginDir = [pluginsDir stringByAppendingPathComponent:name];
        NSDictionary *manifest = SpliceKitPlugins_readManifest(pluginDir);
        if (!manifest || ![manifest[@"id"] isEqualToString:pluginId]) continue;

        NSDictionary *entry = manifest[@"entry"];
        BOOL loaded = NO;

        if (entry[@"lua"]) {
            loaded = SpliceKitPlugins_loadLua(manifest, pluginDir);
        }

        if (loaded) {
            return @{@"status": @"ok", @"pluginId": pluginId, @"reloaded": @YES};
        } else {
            return @{@"error": [NSString stringWithFormat:@"Failed to reload %@", pluginId]};
        }
    }

    return @{@"error": [NSString stringWithFormat:@"Plugin not found: %@", pluginId]};
}
