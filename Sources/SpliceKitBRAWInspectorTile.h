// SpliceKitBRAWInspectorTile.h — BRAW inspector tile class.
//
// Mirrors FFInspectorFileInfoProResRAWTile: a thin tile with a single
// "Modify BRAW…" button that opens the shared SpliceKitBRAWSettingsHud.
//
// Because FFInspectorBaseController (the required superclass) is a FCP-internal
// class we can't link against at compile time, we register this class at runtime
// via objc_allocateClassPair and return the resulting Class for callers (notably
// the addTilesForItems: swizzle in SpliceKitBRAWRAW.mm) to instantiate.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface SpliceKitBRAWInspectorTile : NSObject

// Registers the runtime tile class the first time it's called, caches it, and
// returns the Class. Returns nil on the ObjC platforms where FFInspectorBaseController
// isn't loaded (e.g. before FCP finishes bootstrapping its frameworks).
+ (nullable Class)registerTileClass;

// Name the runtime-built class is registered under.
+ (NSString *)runtimeClassName;

@end

NS_ASSUME_NONNULL_END
