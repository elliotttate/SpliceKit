// SpliceKitBRAWRAW.mm — BRAW RAW inspector integration.
//
// After the move off MediaExtensions (see /Users/briantate/.claude/plans/
// mutable-popping-charm.md), this file is *only* responsible for getting FCP's
// inspector to show a BRAW-specific "Modify BRAW…" tile for .braw clips.
//
// It does NOT try to light up FCP's generic FFVTRAWSettingsHud / VT RAW
// Processor / MediaExtension machinery. That whole shim was replaced by
// SpliceKitBRAWSettingsHud (our own native-style floating window) and
// SpliceKitBRAWInspectorTile (a runtime-built FFInspectorBaseController
// subclass that opens the HUD).
//
// Two responsibilities remain:
//
// 1. **Eligibility gates** — swizzle FFAsset / FFSourceVideoFig predicates
//    so FCP's inspector predicate ((…hasVideo) && … && supportsRAWToLogConversionUI)
//    returns YES for BRAW. Without this, the inspector predicate never reaches
//    the tile-injection branch.
//
// 2. **Tile injection** — swizzle FFInspectorFileInfoTile.addTilesForItems:references:owner:
//    to add our SpliceKitBRAWInspectorTile whenever any selected item resolves
//    to a BRAW-backed asset.
//
// 3. **Settings mirror** — swizzle FFAsset.setRawProcessorSettings: and
//    FFSourceVideoFig.setRAWAdjustmentInfo: so any write to the asset-level
//    settings dictionary also updates SpliceKit's in-process per-path cache
//    (SpliceKitBRAWRAWSettingsMap). The BRAW decoder reads that cache per
//    decode job. This keeps persistence and live render in sync regardless
//    of whether the change came from our HUD, FCP's own library mechanics,
//    or FCPXML import.

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <CoreMedia/CoreMedia.h>

#import "SpliceKitBRAWAdjustmentInfo.h"
#import "SpliceKitBRAWInspectorTile.h"

#ifdef __cplusplus
#define SPLICEKIT_BRAW_RAW_EXTERN_C extern "C"
#else
#define SPLICEKIT_BRAW_RAW_EXTERN_C extern
#endif

// SpliceKit_registerPluginMethod lives in SpliceKitServer.m (plain ObjC, C
// linkage). Since we're .mm and build with -undefined dynamic_lookup, we must
// explicitly request C linkage or the runtime loader looks for a C++-mangled
// symbol that doesn't exist and we crash on first call.
extern "C" {
typedef NSDictionary *(^SpliceKitMethodHandler)(NSDictionary *params);
void SpliceKit_registerPluginMethod(NSString *method,
                                    SpliceKitMethodHandler handler,
                                    NSDictionary *metadata);
void SpliceKitBRAW_SetRAWSettingsForPath(CFStringRef pathRef, CFDictionaryRef settingsRef);
id SpliceKit_getActiveTimelineModule(void);
}

static NSString *const kSpliceKitBRAWRAWEnabledDefault = @"SpliceKitEnableBRAWRAWControls";

#pragma mark - BRAW detection helpers

static BOOL SpliceKitBRAWRAWIsBRAWFourCC(FourCharCode c) {
    return c == 'braw' || c == 'brxq' || c == 'brst' || c == 'brvn' ||
           c == 'brs2' || c == 'brxh';
}

static void SpliceKitBRAWRAWTrace(NSString *message) {
    if (message.length == 0) return;
    NSString *path = @"/tmp/splicekit-braw.log";
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
    }
    NSString *line = [NSString stringWithFormat:@"%@ [raw-settings] %@\n", [NSDate date], message];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!handle) return;
    @try { [handle seekToEndOfFile]; [handle writeData:data]; }
    @catch (__unused NSException *e) {}
    @finally { [handle closeFile]; }
}

// Return YES if the receiver is backed by a .braw file. Works on FFAsset /
// FFSourceVideoFig / FFAnchoredMediaComponent. Prefers the codecType fourcc
// when available, falls back to URL extension because fresh FFAssets can
// have codecType == 0 before the decoder has populated it.
static BOOL SpliceKitBRAWRAWHasBRAWCodec(id obj) {
    if (!obj) return NO;
    if ([obj respondsToSelector:@selector(codecType)]) {
        FourCharCode codec = ((FourCharCode (*)(id, SEL))objc_msgSend)(obj, @selector(codecType));
        if (SpliceKitBRAWRAWIsBRAWFourCC(codec)) return YES;
    }
    if ([obj respondsToSelector:@selector(videoCodecType4CC)]) {
        FourCharCode codec = ((FourCharCode (*)(id, SEL))objc_msgSend)(obj, @selector(videoCodecType4CC));
        if (SpliceKitBRAWRAWIsBRAWFourCC(codec)) return YES;
    }
    if ([obj respondsToSelector:@selector(videoFormatName)]) {
        NSString *name = ((NSString *(*)(id, SEL))objc_msgSend)(obj, @selector(videoFormatName));
        if ([name isKindOfClass:[NSString class]] &&
            ([name rangeOfString:@"BRAW" options:NSCaseInsensitiveSearch].location != NSNotFound ||
             [name rangeOfString:@"Blackmagic" options:NSCaseInsensitiveSearch].location != NSNotFound)) {
            return YES;
        }
    }
    SEL urlSelectors[] = { @selector(originalMediaURL), @selector(fileURL), @selector(URL) };
    for (size_t i = 0; i < sizeof(urlSelectors) / sizeof(SEL); ++i) {
        if (![obj respondsToSelector:urlSelectors[i]]) continue;
        NSURL *url = ((NSURL *(*)(id, SEL))objc_msgSend)(obj, urlSelectors[i]);
        if ([url isKindOfClass:[NSURL class]] &&
            [url.pathExtension caseInsensitiveCompare:@"braw"] == NSOrderedSame) {
            return YES;
        }
    }
    return NO;
}

static NSURL *SpliceKitBRAWRAWURLFromValue(id value) {
    if (!value || value == (id)kCFNull) return nil;
    if ([value isKindOfClass:[NSURL class]]) return value;
    if ([value isKindOfClass:[NSArray class]]) {
        for (id item in (NSArray *)value) {
            NSURL *url = SpliceKitBRAWRAWURLFromValue(item);
            if (url) return url;
        }
        return nil;
    }
    if ([value isKindOfClass:[NSString class]]) {
        NSString *string = (NSString *)value;
        if ([string hasPrefix:@"file://"]) {
            NSURL *url = [NSURL URLWithString:string];
            if (url.isFileURL) return url;
        }
        if ([string hasPrefix:@"/"]) {
            return [NSURL fileURLWithPath:string];
        }
    }
    return nil;
}

static NSString *SpliceKitBRAWRAWNormalizedMediaPathFromObject(id root) {
    if (!root) return nil;
    id target = root;
    if ([target respondsToSelector:@selector(primaryObject)]) {
        id primary = ((id (*)(id, SEL))objc_msgSend)(target, @selector(primaryObject));
        if (primary) target = primary;
    }
    NSArray<NSString *> *keyPaths = @[
        @"originalMediaURL", @"fileURL", @"URL", @"persistentFileURL",
        @"media.originalMediaURL", @"media.fileURL", @"asset.originalMediaURL",
        @"originalMediaRep.fileURL", @"originalMediaRep.fileURLs",
        @"currentRep.fileURL", @"currentRep.fileURLs",
        @"media.originalMediaRep.fileURLs",
        @"assetMediaReference.resolvedURL",
        @"clipInPlace.asset.originalMediaURL",
    ];
    for (NSString *keyPath in keyPaths) {
        @try {
            id value = [target valueForKeyPath:keyPath];
            NSURL *url = SpliceKitBRAWRAWURLFromValue(value);
            if (url.isFileURL) {
                NSURL *resolved = [url URLByResolvingSymlinksInPath];
                NSString *resolvedPath = resolved.path.stringByStandardizingPath;
                return resolvedPath.length > 0 ? resolvedPath : url.path.stringByStandardizingPath;
            }
        } @catch (__unused NSException *e) {
        }
    }
    return nil;
}

static NSDictionary *SpliceKitBRAWRAWSettingsDictFromRAWAdjustmentInfo(id rawAdjustmentInfo) {
    if (!rawAdjustmentInfo || rawAdjustmentInfo == (id)kCFNull) return nil;
    SEL snapshotSel = NSSelectorFromString(@"snapshotSettings");
    if (![rawAdjustmentInfo respondsToSelector:snapshotSel]) return nil;
    id snapshot = ((id (*)(id, SEL))objc_msgSend)(rawAdjustmentInfo, snapshotSel);
    SEL settingsSel = NSSelectorFromString(@"settings");
    if (!snapshot || ![snapshot respondsToSelector:settingsSel]) return nil;
    id settings = ((id (*)(id, SEL))objc_msgSend)(snapshot, settingsSel);
    return [settings isKindOfClass:[NSDictionary class]] ? settings : nil;
}

// Determine whether any of the given inspector items resolves back to a
// BRAW-backed asset. Walks item -> asset/media/firstAsset/originalMediaRep.
static BOOL SpliceKitBRAWRAWAnyItemIsBRAW(id items) {
    if (![items respondsToSelector:@selector(count)]) return NO;
    NSUInteger n = ((NSUInteger (*)(id, SEL))objc_msgSend)(items, @selector(count));
    if (n == 0) return NO;
    for (NSUInteger i = 0; i < n; ++i) {
        id item = nil;
        if ([items respondsToSelector:@selector(objectAtIndex:)]) {
            item = ((id (*)(id, SEL, NSUInteger))objc_msgSend)(items, @selector(objectAtIndex:), i);
        }
        if (!item) continue;
        SEL probes[] = {
            @selector(asset),
            @selector(media),
            @selector(firstAsset),
            @selector(firstAssetIfOnlyOneVideo),
            @selector(originalMediaRep),
        };
        id chain[8] = { item };
        size_t chainLen = 1;
        for (size_t p = 0; p < sizeof(probes) / sizeof(SEL) && chainLen < 8; ++p) {
            id current = chain[chainLen - 1];
            if (!current || ![current respondsToSelector:probes[p]]) continue;
            id next = ((id (*)(id, SEL))objc_msgSend)(current, probes[p]);
            if (next) chain[chainLen++] = next;
        }
        for (size_t c = 0; c < chainLen; ++c) {
            if (SpliceKitBRAWRAWHasBRAWCodec(chain[c])) return YES;
        }
    }
    return NO;
}

#pragma mark - Gate overrides (FFAsset / FFSourceVideoFig)

static IMP sSpliceKitBRAWRAWOriginalAssetSupportsToLogUI = NULL;
static IMP sSpliceKitBRAWRAWOriginalAssetSupportsToLog = NULL;
static IMP sSpliceKitBRAWRAWOriginalAssetSetRawProcessorSettings = NULL;
static IMP sSpliceKitBRAWRAWOriginalAssetGetRawProcessorSettings = NULL;
static IMP sSpliceKitBRAWRAWOriginalAssetNewProvider = NULL;
static IMP sSpliceKitBRAWRAWOriginalSourceSupportsAdjustments = NULL;
static IMP sSpliceKitBRAWRAWOriginalSourceSupportsToLog = NULL;
static IMP sSpliceKitBRAWRAWOriginalSourceSetRAWAdjustmentInfo = NULL;

static BOOL SpliceKitBRAWRAWAssetSupportsToLogUIOverride(id self, SEL _cmd) {
    if (SpliceKitBRAWRAWHasBRAWCodec(self)) return YES;
    if (sSpliceKitBRAWRAWOriginalAssetSupportsToLogUI) {
        return ((BOOL (*)(id, SEL))sSpliceKitBRAWRAWOriginalAssetSupportsToLogUI)(self, _cmd);
    }
    return NO;
}

static BOOL SpliceKitBRAWRAWAssetSupportsToLogOverride(id self, SEL _cmd) {
    if (SpliceKitBRAWRAWHasBRAWCodec(self)) return YES;
    if (sSpliceKitBRAWRAWOriginalAssetSupportsToLog) {
        return ((BOOL (*)(id, SEL))sSpliceKitBRAWRAWOriginalAssetSupportsToLog)(self, _cmd);
    }
    return NO;
}

static BOOL SpliceKitBRAWRAWSourceSupportsAdjustmentsOverride(id self, SEL _cmd) {
    if (SpliceKitBRAWRAWHasBRAWCodec(self)) return YES;
    if (sSpliceKitBRAWRAWOriginalSourceSupportsAdjustments) {
        return ((BOOL (*)(id, SEL))sSpliceKitBRAWRAWOriginalSourceSupportsAdjustments)(self, _cmd);
    }
    return NO;
}

static int SpliceKitBRAWRAWSourceSupportsToLogOverride(id self, SEL _cmd) {
    if (SpliceKitBRAWRAWHasBRAWCodec(self)) return 1;
    if (sSpliceKitBRAWRAWOriginalSourceSupportsToLog) {
        return ((int (*)(id, SEL))sSpliceKitBRAWRAWOriginalSourceSupportsToLog)(self, _cmd);
    }
    return 0;
}

#pragma mark - Settings mirror overrides

static void SpliceKitBRAWRAWAssetSetRawProcessorSettingsOverride(id self, SEL _cmd, id rawProcessorSettings) {
    if (sSpliceKitBRAWRAWOriginalAssetSetRawProcessorSettings) {
        ((void (*)(id, SEL, id))sSpliceKitBRAWRAWOriginalAssetSetRawProcessorSettings)(self, _cmd, rawProcessorSettings);
    }
    NSString *path = SpliceKitBRAWRAWNormalizedMediaPathFromObject(self);
    if (path.length == 0) return;

    SpliceKitBRAWAdjustmentInfo *info =
        [SpliceKitBRAWAdjustmentInfo infoFromRawProcessorSettings:rawProcessorSettings];
    NSDictionary *settings = info.settings;
    if (settings.count > 0) {
        SpliceKitBRAW_SetRAWSettingsForPath((__bridge CFStringRef)path,
                                            (__bridge CFDictionaryRef)settings);
    } else {
        SpliceKitBRAW_SetRAWSettingsForPath((__bridge CFStringRef)path, NULL);
    }
    SpliceKitBRAWRAWTrace([NSString stringWithFormat:@"asset rawProcessorSettings path=%@ keys=%@",
                           path, settings.allKeys ?: @[]]);
}

// Mirror FFAsset.rawProcessorSettings getter into our in-memory cache.
//
// The setter swizzle above only fires for live mutations from our HUD or
// FCPXML import — but NOT during library load, where FCP deserializes the
// dict directly into the ivar without going through the setter. Without a
// cache prime on load, the decoder reads an empty cache for the first decode
// (or every decode until the user touches a slider), which means persisted
// BRAW settings appear to "not apply" until adjusted.
//
// FCP calls -rawProcessorSettings frequently during render setup
// (FFAsset._copyVideoOverridesDict, _appendCacheIdentifierAdditions:, etc.),
// so hooking the getter gives us a guaranteed pull-time prime opportunity.
// We tag each asset with an associated-object "primed" sentinel so the hot
// path is just a pointer compare — no path resolution, no settings parsing.
static const void *kSpliceKitBRAWRAWPrimedKey = &kSpliceKitBRAWRAWPrimedKey;

static id SpliceKitBRAWRAWAssetGetRawProcessorSettingsOverride(id self, SEL _cmd) {
    id result = nil;
    if (sSpliceKitBRAWRAWOriginalAssetGetRawProcessorSettings) {
        result = ((id (*)(id, SEL))sSpliceKitBRAWRAWOriginalAssetGetRawProcessorSettings)(self, _cmd);
    }
    // Hot path: assets we've already primed return immediately.
    if (objc_getAssociatedObject(self, kSpliceKitBRAWRAWPrimedKey)) {
        return result;
    }
    if (![result isKindOfClass:[NSDictionary class]] || [(NSDictionary *)result count] == 0) {
        return result;
    }
    NSString *path = SpliceKitBRAWRAWNormalizedMediaPathFromObject(self);
    if (path.length == 0) return result;

    SpliceKitBRAWAdjustmentInfo *info =
        [SpliceKitBRAWAdjustmentInfo infoFromRawProcessorSettings:result];
    NSDictionary *settings = info.settings;
    if (settings.count > 0) {
        SpliceKitBRAW_SetRAWSettingsForPath((__bridge CFStringRef)path,
                                            (__bridge CFDictionaryRef)settings);
        SpliceKitBRAWRAWTrace([NSString stringWithFormat:
            @"primed cache from asset getter path=%@ keys=%@",
            path, settings.allKeys]);
    }
    // Mark primed even when settings is empty so we don't re-parse on every
    // get — the next mutation through setRawProcessorSettings: will refresh.
    objc_setAssociatedObject(self, kSpliceKitBRAWRAWPrimedKey, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return result;
}

// Render-path cache prime — fires when FCP first asks the asset for its
// provider (which precedes any decode for the asset). The getter swizzle
// above only catches inspector / public callers; FCP's _newRAWSettingsSnapshot
// reads `self->_rawProcessorSettings` directly via the ivar, completely
// bypassing the getter — so persisted settings would never reach our cache
// until the user explicitly opened the inspector or moved a slider.
//
// By calling -rawProcessorSettings explicitly here (which goes through our
// getter swizzle), we ensure the cache is populated for any asset that's
// about to be rendered. Cheap on the hot path because the getter swizzle's
// fast-path is just an associated-object check.
static id SpliceKitBRAWRAWAssetNewProviderOverride(id self, SEL _cmd) {
    if ([self respondsToSelector:@selector(rawProcessorSettings)]) {
        (void)((id (*)(id, SEL))objc_msgSend)(self, @selector(rawProcessorSettings));
    }
    if (sSpliceKitBRAWRAWOriginalAssetNewProvider) {
        return ((id (*)(id, SEL))sSpliceKitBRAWRAWOriginalAssetNewProvider)(self, _cmd);
    }
    return nil;
}

static void SpliceKitBRAWRAWSourceSetRAWAdjustmentInfoOverride(id self, SEL _cmd, id rawAdjustmentInfo) {
    if (sSpliceKitBRAWRAWOriginalSourceSetRAWAdjustmentInfo) {
        ((void (*)(id, SEL, id))sSpliceKitBRAWRAWOriginalSourceSetRAWAdjustmentInfo)(self, _cmd, rawAdjustmentInfo);
    }
    NSString *path = SpliceKitBRAWRAWNormalizedMediaPathFromObject(self);
    if (path.length == 0) return;
    NSDictionary *settings = SpliceKitBRAWRAWSettingsDictFromRAWAdjustmentInfo(rawAdjustmentInfo);
    if (settings.count > 0) {
        SpliceKitBRAW_SetRAWSettingsForPath((__bridge CFStringRef)path,
                                            (__bridge CFDictionaryRef)settings);
        SpliceKitBRAWRAWTrace([NSString stringWithFormat:@"source rawAdjustmentInfo path=%@ keys=%@",
                               path, settings.allKeys ?: @[]]);
    }
}

#pragma mark - Tile injection

static NSMutableDictionary<NSString *, NSNumber *> *sSpliceKitBRAWRAWInitCounters = nil;
static IMP sSpliceKitBRAWRAWOriginalAddTilesForItems = NULL;
static IMP sSpliceKitBRAWRAWOriginalClipControllerAddTiles = NULL;

static void SpliceKitBRAWRAWAddTilesForItemsOverride(id self, SEL _cmd, id items, id refs, id owner) {
    NSUInteger n = 0;
    if ([items respondsToSelector:@selector(count)]) {
        n = ((NSUInteger (*)(id, SEL))objc_msgSend)(items, @selector(count));
    }

    @synchronized (sSpliceKitBRAWRAWInitCounters) {
        NSString *key = [NSString stringWithFormat:@"PARENT:%@", NSStringFromClass([self class])];
        NSInteger k = [sSpliceKitBRAWRAWInitCounters[key] integerValue];
        sSpliceKitBRAWRAWInitCounters[key] = @(k + 1);
    }
    BOOL isBRAW = SpliceKitBRAWRAWAnyItemIsBRAW(items);
    SpliceKitBRAWRAWTrace([NSString stringWithFormat:@"addTilesForItems self=%@ count=%lu isBRAW=%d",
        NSStringFromClass([self class]), (unsigned long)n, isBRAW]);

    // Call through to the original so FCP's stock tiles (file info, metadata,
    // location, etc.) continue to populate.
    if (sSpliceKitBRAWRAWOriginalAddTilesForItems) {
        ((void (*)(id, SEL, id, id, id))sSpliceKitBRAWRAWOriginalAddTilesForItems)(self, _cmd, items, refs, owner);
    }

    if (!isBRAW) return;
    if (![self respondsToSelector:@selector(_addTileOfClass:items:references:owner:)]) return;

    Class tileClass = [SpliceKitBRAWInspectorTile registerTileClass];
    if (!tileClass) {
        SpliceKitBRAWRAWTrace(@"tile class registration failed (FFInspectorBaseController missing?)");
        return;
    }
    SpliceKitBRAWRAWTrace(@"injecting SpliceKitBRAWInspectorTile");
    id newTile = ((id (*)(id, SEL, Class, id, id, id))objc_msgSend)(
        self, @selector(_addTileOfClass:items:references:owner:),
        tileClass, items, refs, owner);

    // FCP's _addTileOfClass: only calls -addTilesForItems:references:owner: on
    // FFInspectorFileInfoContainerTile subclasses; plain leaf tiles like ours
    // don't get -updateWithItems:references:owner: dispatched until the next
    // FFInspectorContainerController update cycle. Trigger it directly so the
    // tile's _items associated object is populated immediately — the HUD reads
    // _items when the "Modify BRAW…" button fires.
    if (newTile && [newTile respondsToSelector:@selector(updateWithItems:references:owner:)]) {
        ((void (*)(id, SEL, id, id, id))objc_msgSend)(
            newTile, @selector(updateWithItems:references:owner:),
            items, refs, owner);
        SpliceKitBRAWRAWTrace(@"forwarded updateWithItems: to new tile");
    }
}

static void SpliceKitBRAWRAWClipControllerAddTilesOverride(id self, SEL _cmd, id items, id refs, id owner) {
    @synchronized (sSpliceKitBRAWRAWInitCounters) {
        NSString *key = @"CLIPCTRL:_addTilesForItems";
        NSInteger k = [sSpliceKitBRAWRAWInitCounters[key] integerValue];
        sSpliceKitBRAWRAWInitCounters[key] = @(k + 1);
    }
    if (sSpliceKitBRAWRAWOriginalClipControllerAddTiles) {
        ((void (*)(id, SEL, id, id, id))sSpliceKitBRAWRAWOriginalClipControllerAddTiles)(self, _cmd, items, refs, owner);
    }
}

#pragma mark - Debug RPC helpers

static BOOL SpliceKitBRAWRAWClassMatchesFilter(NSString *cls, NSString *filter) {
    if (filter.length == 0) return YES;
    return [cls rangeOfString:filter options:NSCaseInsensitiveSearch].location != NSNotFound;
}

static void SpliceKitBRAWRAWWalkInspectorViews(NSView *view, int depth, NSString *winTag, NSMutableArray *tiles, NSString *filter) {
    if (!view) return;
    NSString *cls = NSStringFromClass([view class]);
    if (cls.length && SpliceKitBRAWRAWClassMatchesFilter(cls, filter)) {
        [tiles addObject:@{
            @"class": cls,
            @"frame": NSStringFromRect(view.frame),
            @"hidden": @(view.isHidden),
            @"alphaValue": @((double)view.alphaValue),
            @"depth": @(depth),
            @"window": winTag ?: @"<?>",
        }];
    }
    for (NSView *sub in view.subviews) {
        SpliceKitBRAWRAWWalkInspectorViews(sub, depth + 1, winTag, tiles, filter);
    }
}

static NSInteger SpliceKitBRAWRAWCountInstancesOfClass(NSView *view, Class cls) {
    if (!view) return 0;
    NSInteger count = [view isKindOfClass:cls] ? 1 : 0;
    for (NSView *sub in view.subviews) {
        count += SpliceKitBRAWRAWCountInstancesOfClass(sub, cls);
    }
    return count;
}

static NSDictionary *SpliceKitBRAWRAWHandleListTiles(NSDictionary *params) {
    NSString *filter = [params[@"filter"] isKindOfClass:[NSString class]] ? params[@"filter"] : nil;
    NSMutableArray *tiles = [NSMutableArray array];
    for (NSWindow *win in [NSApp windows]) {
        if (!win.isVisible) continue;
        NSString *tag = [NSString stringWithFormat:@"%@(%p)", NSStringFromClass([win class]), win];
        SpliceKitBRAWRAWWalkInspectorViews(win.contentView, 0, tag, tiles, filter);
    }
    return @{@"tiles": tiles, @"count": @(tiles.count), @"filter": filter ?: @""};
}

static NSDictionary *SpliceKitBRAWRAWHandleInitCounters(NSDictionary *params) {
    @synchronized (sSpliceKitBRAWRAWInitCounters) {
        return @{@"counters": sSpliceKitBRAWRAWInitCounters ?: @{}};
    }
}

static NSDictionary *SpliceKitBRAWRAWHandleHasClassInstance(NSDictionary *params) {
    id rawName = params[@"class"];
    if (![rawName isKindOfClass:[NSString class]]) {
        return @{@"error": @"missing 'class' param"};
    }
    NSString *className = (NSString *)rawName;
    Class cls = NSClassFromString(className);
    if (!cls) return @{@"class": className, @"exists": @NO, @"found": @NO};

    NSInteger total = 0;
    for (NSWindow *win in [NSApp windows]) {
        total += SpliceKitBRAWRAWCountInstancesOfClass(win.contentView, cls);
    }
    return @{
        @"class": className,
        @"exists": @YES,
        @"found": @(total > 0),
        @"viewInstances": @(total),
    };
}

#pragma mark - Hook installation

static BOOL SpliceKitBRAWRAWHookMethod(Class cls, SEL sel, IMP replacement, IMP *outOriginal, NSString *label) {
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) {
        SpliceKitBRAWRAWTrace([NSString stringWithFormat:@"%@ method not found", label]);
        return NO;
    }
    if (*outOriginal) {
        SpliceKitBRAWRAWTrace([NSString stringWithFormat:@"%@ already installed", label]);
        return YES;
    }
    *outOriginal = method_setImplementation(method, replacement);
    SpliceKitBRAWRAWTrace([NSString stringWithFormat:@"installed %@ swizzle", label]);
    return *outOriginal != NULL;
}

static void SpliceKitBRAWRAWRegisterInspectorRPCs(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sSpliceKitBRAWRAWInitCounters = [NSMutableDictionary dictionary];

        SpliceKit_registerPluginMethod(@"inspector.listTiles",
            ^NSDictionary *(NSDictionary *params) {
                return SpliceKitBRAWRAWHandleListTiles(params);
            },
            @{@"description": @"List NSView instances matching an optional name filter."});

        SpliceKit_registerPluginMethod(@"inspector.hasClassInstance",
            ^NSDictionary *(NSDictionary *params) {
                return SpliceKitBRAWRAWHandleHasClassInstance(params);
            },
            @{@"description": @"Check if a given NSView class has live instances in any visible window."});

        SpliceKit_registerPluginMethod(@"inspector.initCounters",
            ^NSDictionary *(NSDictionary *params) {
                return SpliceKitBRAWRAWHandleInitCounters(params);
            },
            @{@"description": @"Per-class init counters for inspector tiles we track."});

        BOOL (^classDefines)(Class, SEL) = ^BOOL(Class cls, SEL sel) {
            unsigned int count = 0;
            Method *methods = class_copyMethodList(cls, &count);
            BOOL found = NO;
            for (unsigned int i = 0; i < count; ++i) {
                if (method_getName(methods[i]) == sel) { found = YES; break; }
            }
            free(methods);
            return found;
        };

        Class baseTile = objc_getClass("FFInspectorFileInfoTile");
        if (baseTile && classDefines(baseTile, @selector(addTilesForItems:references:owner:)) &&
            !sSpliceKitBRAWRAWOriginalAddTilesForItems) {
            Method m = class_getInstanceMethod(baseTile, @selector(addTilesForItems:references:owner:));
            sSpliceKitBRAWRAWOriginalAddTilesForItems = method_setImplementation(m, (IMP)SpliceKitBRAWRAWAddTilesForItemsOverride);
            SpliceKitBRAWRAWTrace(@"installed FFInspectorFileInfoTile.addTilesForItems swizzle");
        }

        Class clipCtrl = objc_getClass("FFInspectorFileInfoClipController");
        if (clipCtrl && classDefines(clipCtrl, @selector(_addTilesForItems:references:owner:)) &&
            !sSpliceKitBRAWRAWOriginalClipControllerAddTiles) {
            Method m = class_getInstanceMethod(clipCtrl, @selector(_addTilesForItems:references:owner:));
            sSpliceKitBRAWRAWOriginalClipControllerAddTiles = method_setImplementation(m, (IMP)SpliceKitBRAWRAWClipControllerAddTilesOverride);
            SpliceKitBRAWRAWTrace(@"installed FFInspectorFileInfoClipController._addTilesForItems counter");
        }
    });
}

SPLICEKIT_BRAW_RAW_EXTERN_C BOOL SpliceKit_installBRAWRAWSettingsHooks(void) {
    NSNumber *override = [[NSUserDefaults standardUserDefaults] objectForKey:kSpliceKitBRAWRAWEnabledDefault];
    BOOL enabled = override ? override.boolValue : YES;
    SpliceKitBRAWRAWTrace([NSString stringWithFormat:@"install enabled=%@",
                                                     enabled ? @"YES" : @"NO"]);
    if (!enabled) return NO;

    // Pre-register our runtime tile class as soon as FCP's Flexo is loaded.
    // Registration is idempotent; later calls from addTilesForItems: just
    // return the cached class.
    [SpliceKitBRAWInspectorTile registerTileClass];

    BOOL anyInstalled = NO;

    Class asset = objc_getClass("FFAsset");
    if (asset) {
        anyInstalled |= SpliceKitBRAWRAWHookMethod(asset,
            @selector(supportsRAWToLogConversionUI),
            (IMP)SpliceKitBRAWRAWAssetSupportsToLogUIOverride,
            &sSpliceKitBRAWRAWOriginalAssetSupportsToLogUI,
            @"FFAsset.supportsRAWToLogConversionUI");
        anyInstalled |= SpliceKitBRAWRAWHookMethod(asset,
            @selector(supportsRAWToLogConversion),
            (IMP)SpliceKitBRAWRAWAssetSupportsToLogOverride,
            &sSpliceKitBRAWRAWOriginalAssetSupportsToLog,
            @"FFAsset.supportsRAWToLogConversion");
        anyInstalled |= SpliceKitBRAWRAWHookMethod(asset,
            @selector(setRawProcessorSettings:),
            (IMP)SpliceKitBRAWRAWAssetSetRawProcessorSettingsOverride,
            &sSpliceKitBRAWRAWOriginalAssetSetRawProcessorSettings,
            @"FFAsset.setRawProcessorSettings:");
        anyInstalled |= SpliceKitBRAWRAWHookMethod(asset,
            @selector(rawProcessorSettings),
            (IMP)SpliceKitBRAWRAWAssetGetRawProcessorSettingsOverride,
            &sSpliceKitBRAWRAWOriginalAssetGetRawProcessorSettings,
            @"FFAsset.rawProcessorSettings");
        anyInstalled |= SpliceKitBRAWRAWHookMethod(asset,
            @selector(newProvider),
            (IMP)SpliceKitBRAWRAWAssetNewProviderOverride,
            &sSpliceKitBRAWRAWOriginalAssetNewProvider,
            @"FFAsset.newProvider");
    } else {
        SpliceKitBRAWRAWTrace(@"FFAsset class missing");
    }

    Class svf = objc_getClass("FFSourceVideoFig");
    if (svf) {
        anyInstalled |= SpliceKitBRAWRAWHookMethod(svf,
            @selector(supportsRAWAdjustments),
            (IMP)SpliceKitBRAWRAWSourceSupportsAdjustmentsOverride,
            &sSpliceKitBRAWRAWOriginalSourceSupportsAdjustments,
            @"FFSourceVideoFig.supportsRAWAdjustments");
        anyInstalled |= SpliceKitBRAWRAWHookMethod(svf,
            @selector(supportsRAWToLogConversion),
            (IMP)SpliceKitBRAWRAWSourceSupportsToLogOverride,
            &sSpliceKitBRAWRAWOriginalSourceSupportsToLog,
            @"FFSourceVideoFig.supportsRAWToLogConversion");
        anyInstalled |= SpliceKitBRAWRAWHookMethod(svf,
            @selector(setRAWAdjustmentInfo:),
            (IMP)SpliceKitBRAWRAWSourceSetRAWAdjustmentInfoOverride,
            &sSpliceKitBRAWRAWOriginalSourceSetRAWAdjustmentInfo,
            @"FFSourceVideoFig.setRAWAdjustmentInfo:");
    } else {
        SpliceKitBRAWRAWTrace(@"FFSourceVideoFig class missing");
    }

    SpliceKitBRAWRAWRegisterInspectorRPCs();
    return anyInstalled;
}
