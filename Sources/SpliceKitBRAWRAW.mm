// SpliceKitBRAWRAW.mm — Light up FCP's RAW-related inspector controls for BRAW.
//
// FCP exposes two RAW-related surfaces in the Info inspector that never
// appeared for .braw clips out of the box:
//   1. A "RAW to Log Conversion" dropdown that lets users pick an output log
//      curve (gated by -[FFAsset supportsRAWToLogConversionUI]).
//   2. A "Modify RAW..." button tile that opens FFVTRAWSettingsHud (gated by
//      FFMediaExtensionManager's decoder+RAW classification and a
//      MediaExtension-based RAW processor being installed).
//
// (1) works end-to-end with the current swizzles — verified with the decompiled
// Flexo predicate `((isCollection || isComponent) && hasVideo) && ... &&
// supportsRAWToLogConversionUI = YES` and a live inspector screenshot of the
// Rec. 709 → Log dropdown now rendering for .braw files.
//
// (2) now uses a hybrid path. The native FFVTRAWSettingsHud /
// FFVTRAWSettingsController / FFVTRAWProcessorSession stack is backed by a
// real VT RAW Processor MediaExtension, while actual BRAW frame decode still
// runs in-process through SpliceKitBRAWDecoder.bundle. This file keeps those
// halves synchronized by mirroring live VT session writes back into
// FFAsset.setRawProcessorSettings: and invalidating the asset so the host-side
// BRAW decoder sees the change on the next frame.
//
// This file also registers debug RPCs (`inspector.listTiles`,
// `inspector.hasClassInstance`, `inspector.initCounters`) used to verify tile
// state programmatically instead of by screenshot.

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <CoreMedia/CoreMedia.h>
#import <dlfcn.h>
#include <stdint.h>

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
static const FourCharCode kSpliceKitBRAWRAWCodecType = 'braw';
static NSString *const kSpliceKitBRAWRAWCurrentAddNativeRAWKey = @"SpliceKitBRAWRAWCurrentAddNativeRAW";
static NSString *const kSpliceKitBRAWRAWExtensionIdentifier = @"com.splicekit.braw.rawprocessor";
static NSString *const kSpliceKitBRAWRAWSessionWritebackGuardKey = @"SpliceKitBRAWRAWSessionWriteback";
static void *kSpliceKitBRAWRAWSessionPathKey = &kSpliceKitBRAWRAWSessionPathKey;
static void *kSpliceKitBRAWRAWSessionAssetKey = &kSpliceKitBRAWRAWSessionAssetKey;

// All BRAW variant fourccs observed in the wild. URSA Cine uses 'brxq' /
// 'brst', Vari-angle uses 'brvn', and 'brs2' / 'brxh' have been seen on
// newer firmware. We treat any of these as BRAW for the purposes of the RAW
// controls gating.
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

static NSString *SpliceKitBRAWRAWFourCCString(FourCharCode code) {
    char bytes[5] = {
        (char)((code >> 24) & 0xFF),
        (char)((code >> 16) & 0xFF),
        (char)((code >> 8) & 0xFF),
        (char)(code & 0xFF),
        0
    };
    return [NSString stringWithUTF8String:bytes] ?: [NSString stringWithFormat:@"0x%08x", code];
}

// Return YES if the receiver's codecType is 'braw'. Works for any object
// responding to -codecType (FFSourceVideoFig) or -videoCodecType4CC (FFAsset).
// Also checks videoFormatName as a fallback because some FFAsset instances
// hold only the container-level codec and expose the actual track codec name.
// YES if the receiver (FFAsset, FFSourceVideoFig, or similar) is backed by a
// .braw file. Prefers the `'braw'` fourcc from a -codecType / -videoCodecType4CC
// accessor when available; falls back to the asset's media URL extension
// because fresh FFAssets sometimes have codecType == 0 before the decoder
// session has populated it. Also checks -videoFormatName as a belt-and-suspenders
// text match for "BRAW" / "Blackmagic".
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
        @"originalMediaURL",
        @"fileURL",
        @"URL",
        @"persistentFileURL",
        @"media.originalMediaURL",
        @"media.fileURL",
        @"asset.originalMediaURL",
        @"originalMediaRep.fileURL",
        @"originalMediaRep.fileURLs",
        @"currentRep.fileURL",
        @"currentRep.fileURLs",
        @"media.originalMediaRep.fileURLs",
        @"assetMediaReference.resolvedURL",
        @"clipInPlace.asset.originalMediaURL",
    ];

    for (NSString *keyPath in keyPaths) {
        @try {
            id value = [target valueForKeyPath:keyPath];
            NSURL *url = SpliceKitBRAWRAWURLFromValue(value);
            if (url.isFileURL) {
                NSURL *resolvedURL = [url URLByResolvingSymlinksInPath];
                NSString *resolvedPath = resolvedURL.path.stringByStandardizingPath;
                return resolvedPath.length > 0 ? resolvedPath : url.path.stringByStandardizingPath;
            }
        } @catch (__unused NSException *e) {
        }
    }
    return nil;
}

static NSDictionary *SpliceKitBRAWRAWSettingsDictionaryFromRAWAdjustmentInfo(id rawAdjustmentInfo) {
    if (!rawAdjustmentInfo || rawAdjustmentInfo == (id)kCFNull) {
        return nil;
    }
    if (![rawAdjustmentInfo respondsToSelector:NSSelectorFromString(@"snapshotSettings")]) {
        return nil;
    }
    id snapshot = ((id (*)(id, SEL))objc_msgSend)(rawAdjustmentInfo, NSSelectorFromString(@"snapshotSettings"));
    if (!snapshot || ![snapshot respondsToSelector:NSSelectorFromString(@"settings")]) {
        return nil;
    }
    id settings = ((id (*)(id, SEL))objc_msgSend)(snapshot, NSSelectorFromString(@"settings"));
    return [settings isKindOfClass:[NSDictionary class]] ? settings : nil;
}

static NSDictionary *SpliceKitBRAWRAWSettingsDictionaryFromPersistedSettings(id rawProcessorSettings) {
    if (![rawProcessorSettings isKindOfClass:[NSDictionary class]]) {
        return nil;
    }
    id extensionSettings = ((NSDictionary *)rawProcessorSettings)[kSpliceKitBRAWRAWExtensionIdentifier];
    if (![extensionSettings isKindOfClass:[NSDictionary class]]) {
        return nil;
    }
    id settings = ((NSDictionary *)extensionSettings)[@"settings"];
    return [settings isKindOfClass:[NSDictionary class]] ? settings : nil;
}

static NSDictionary *SpliceKitBRAWRAWSettingsDictionaryFromVTRAWSettings(id vtSettings) {
    if (![vtSettings isKindOfClass:[NSArray class]]) {
        return nil;
    }
    NSMutableDictionary *settings = [NSMutableDictionary dictionary];
    for (id item in (NSArray *)vtSettings) {
        if (![item isKindOfClass:[NSDictionary class]]) continue;
        id key = ((NSDictionary *)item)[@"Key"];
        id value = ((NSDictionary *)item)[@"CurrentValue"];
        if (![key isKindOfClass:[NSString class]] || !value || value == (id)kCFNull) continue;
        settings[key] = value;
    }
    return settings.count > 0 ? settings : nil;
}

static NSDictionary *SpliceKitBRAWRAWMergedRawProcessorSettings(id asset, NSDictionary *settings) {
    if (settings.count == 0) return nil;

    NSMutableDictionary *top = [NSMutableDictionary dictionary];
    id currentTop = nil;
    if ([asset respondsToSelector:@selector(rawProcessorSettings)]) {
        currentTop = ((id (*)(id, SEL))objc_msgSend)(asset, @selector(rawProcessorSettings));
    }
    if ([currentTop isKindOfClass:[NSDictionary class]]) {
        [top addEntriesFromDictionary:(NSDictionary *)currentTop];
    }

    NSMutableDictionary *entry = [NSMutableDictionary dictionary];
    id currentEntry = [currentTop isKindOfClass:[NSDictionary class]]
        ? ((NSDictionary *)currentTop)[kSpliceKitBRAWRAWExtensionIdentifier]
        : nil;
    if ([currentEntry isKindOfClass:[NSDictionary class]]) {
        [entry addEntriesFromDictionary:(NSDictionary *)currentEntry];
    }
    entry[@"settings"] = settings;
    if (!entry[@"settingsVersion"]) {
        entry[@"settingsVersion"] = @1;
    }
    top[kSpliceKitBRAWRAWExtensionIdentifier] = entry;
    return top;
}

static void SpliceKitBRAWRAWAssociateSessionWithPathAndAsset(id controller, id asset, id source) {
    if (!controller) return;

    id session = nil;
    @try {
        session = [controller valueForKey:@"_processingSession"];
    } @catch (__unused NSException *e) {
        session = nil;
    }
    if (!session) return;

    NSString *path = SpliceKitBRAWRAWNormalizedMediaPathFromObject(asset);
    if (path.length == 0) {
        path = SpliceKitBRAWRAWNormalizedMediaPathFromObject(source);
    }
    if (path.length == 0) return;

    objc_setAssociatedObject(session, kSpliceKitBRAWRAWSessionPathKey, path, OBJC_ASSOCIATION_COPY_NONATOMIC);
    if (asset) {
        objc_setAssociatedObject(session, kSpliceKitBRAWRAWSessionAssetKey, asset, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    SpliceKitBRAWRAWTrace([NSString stringWithFormat:@"associated session %@ with %@", session, path]);
}

// The RAW inspector tile's visibility predicate (from Flexo strings) is:
//   ((isCollection || isComponent) && hasVideo) && !isPSD && !isPSDLayer &&
//   !isReferenceClip && !isStill && supportsRAWToLogConversionUI == YES
// So the real gate for "is this clip eligible for the RAW processor tile?"
// is -[FFAsset supportsRAWToLogConversionUI]. supportsRAWAdjustments is a
// separate property read from FFSourceVideoFig for inside-the-HUD flow.
// We hook all three to cover every path that might query BRAW's RAW state.

static IMP sSpliceKitBRAWRAWOriginalAssetSupportsToLogUI = NULL;
static IMP sSpliceKitBRAWRAWOriginalAssetSupportsToLog = NULL;
static IMP sSpliceKitBRAWRAWOriginalAssetSetRawProcessorSettings = NULL;
static IMP sSpliceKitBRAWRAWOriginalSourceSupportsAdjustments = NULL;
static IMP sSpliceKitBRAWRAWOriginalSourceSupportsToLog = NULL;
static IMP sSpliceKitBRAWRAWOriginalSourceCodecIsRawExt = NULL;
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

static void SpliceKitBRAWRAWAssetSetRawProcessorSettingsOverride(id self, SEL _cmd, id rawProcessorSettings) {
    if (sSpliceKitBRAWRAWOriginalAssetSetRawProcessorSettings) {
        ((void (*)(id, SEL, id))sSpliceKitBRAWRAWOriginalAssetSetRawProcessorSettings)(self, _cmd, rawProcessorSettings);
    }

    NSString *path = SpliceKitBRAWRAWNormalizedMediaPathFromObject(self);
    NSDictionary *settings = SpliceKitBRAWRAWSettingsDictionaryFromPersistedSettings(rawProcessorSettings);
    if (path.length > 0) {
        SpliceKitBRAW_SetRAWSettingsForPath((__bridge CFStringRef)path,
                                            settings ? (__bridge CFDictionaryRef)settings : NULL);
        SpliceKitBRAWRAWTrace([NSString stringWithFormat:@"asset rawProcessorSettings path=%@ keys=%@",
                               path,
                               settings.allKeys ?: @[]]);
    } else if (settings.count > 0) {
        SpliceKitBRAWRAWTrace([NSString stringWithFormat:@"asset rawProcessorSettings missing path for %@", self]);
    }
}

static void SpliceKitBRAWRAWSourceSetRAWAdjustmentInfoOverride(id self, SEL _cmd, id rawAdjustmentInfo) {
    if (sSpliceKitBRAWRAWOriginalSourceSetRAWAdjustmentInfo) {
        ((void (*)(id, SEL, id))sSpliceKitBRAWRAWOriginalSourceSetRAWAdjustmentInfo)(self, _cmd, rawAdjustmentInfo);
    }

    NSString *path = SpliceKitBRAWRAWNormalizedMediaPathFromObject(self);
    NSDictionary *settings = SpliceKitBRAWRAWSettingsDictionaryFromRAWAdjustmentInfo(rawAdjustmentInfo);
    if (path.length > 0) {
        SpliceKitBRAW_SetRAWSettingsForPath((__bridge CFStringRef)path,
                                            settings ? (__bridge CFDictionaryRef)settings : NULL);
        SpliceKitBRAWRAWTrace([NSString stringWithFormat:@"source rawAdjustmentInfo path=%@ keys=%@",
                               path,
                               settings.allKeys ?: @[]]);
    } else if (settings.count > 0) {
        SpliceKitBRAWRAWTrace([NSString stringWithFormat:@"source rawAdjustmentInfo missing path for %@", self]);
    }
}

static BOOL SpliceKitBRAWRAWHasRegisteredRAWProcessorForFormat(CMFormatDescriptionRef fmt) {
    if (!fmt) return NO;
    FourCharCode codec = CMFormatDescriptionGetMediaSubType(fmt);
    if (!SpliceKitBRAWRAWIsBRAWFourCC(codec)) return NO;

    static NSMutableDictionary<NSNumber *, NSNumber *> *cache = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [NSMutableDictionary new];
    });

    NSNumber *codecKey = @(codec);
    @synchronized (cache) {
        NSNumber *cached = cache[codecKey];
        if (cached) return cached.boolValue;
    }

    typedef OSStatus (*VTCopyRAWProcessorExtensionPropertiesFn)(CMFormatDescriptionRef, CFDictionaryRef *);
    VTCopyRAWProcessorExtensionPropertiesFn copyProps =
        (VTCopyRAWProcessorExtensionPropertiesFn)dlsym(RTLD_DEFAULT, "VTCopyRAWProcessorExtensionProperties");
    if (!copyProps) {
        SpliceKitBRAWRAWTrace(@"VTCopyRAWProcessorExtensionProperties symbol missing");
        @synchronized (cache) {
            cache[codecKey] = @NO;
        }
        return NO;
    }

    CFDictionaryRef props = NULL;
    OSStatus status = copyProps(fmt, &props);
    BOOL ok = (status == noErr && props && CFDictionaryGetCount(props) > 0);
    NSString *codecString = SpliceKitBRAWRAWFourCCString(codec);
    NSString *summary = [NSString stringWithFormat:
        @"raw processor availability codec=%@ status=%d props=%@",
        codecString, (int)status, ok ? @"yes" : @"no"];
    SpliceKitBRAWRAWTrace(summary);
    if (props) CFRelease(props);

    @synchronized (cache) {
        cache[codecKey] = @(ok);
    }
    return ok;
}

static BOOL SpliceKitBRAWRAWSourceCodecIsRawExtOverride(id self, SEL _cmd) {
    if (SpliceKitBRAWRAWHasBRAWCodec(self) &&
        [self respondsToSelector:@selector(videoFormatDescription)]) {
        CMFormatDescriptionRef fmt =
            ((CMFormatDescriptionRef (*)(id, SEL))objc_msgSend)(self, @selector(videoFormatDescription));
        if (SpliceKitBRAWRAWHasRegisteredRAWProcessorForFormat(fmt)) {
            return YES;
        }
    }
    if (sSpliceKitBRAWRAWOriginalSourceCodecIsRawExt) {
        return ((BOOL (*)(id, SEL))sSpliceKitBRAWRAWOriginalSourceCodecIsRawExt)(self, _cmd);
    }
    return NO;
}

// Recursive view walker that fills `tiles` with any view whose class name
// looks like an inspector tile. Kept as a C-callable helper so the block-based
// handler stays small and doesn't re-create closures on every call.
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
    BOOL hiddenOnly = [params[@"includeHidden"] boolValue];
    (void)hiddenOnly;
    NSMutableArray *tiles = [NSMutableArray array];
    for (NSWindow *win in [NSApp windows]) {
        if (!win.isVisible) continue;
        NSString *tag = [NSString stringWithFormat:@"%@(%p)", NSStringFromClass([win class]), win];
        SpliceKitBRAWRAWWalkInspectorViews(win.contentView, 0, tag, tiles, filter);
    }
    return @{@"tiles": tiles, @"count": @(tiles.count), @"filter": filter ?: @""};
}

// Counters bumped from a class-specific swizzle on a method the tile class
// actually defines, so we can tell if the tile ever got its
// updateWithItems:references:owner: called. Never swizzle -init on a class
// that doesn't override it — that replaces NSObject's init globally.
static NSMutableDictionary<NSString *, NSNumber *> *sSpliceKitBRAWRAWInitCounters = nil;
static IMP sSpliceKitBRAWRAWOriginalRAWTileUpdate = NULL;
static IMP sSpliceKitBRAWRAWOriginalAddTileOfClass = NULL;
static IMP sSpliceKitBRAWRAWOriginalAddTilesForItems = NULL;
static IMP sSpliceKitBRAWRAWOriginalClipControllerAddTiles = NULL;

// ---- Synthetic VT RAW processor session for BRAW clips ----
//
// FFVTRAWSettingsController requires a FFVTRAWProcessorSession whose
// hasValidSession==YES and whose copyVTRAWSettingsFromSession returns an
// array of VT-shaped setting dicts. Without a MediaExtension-based RAW
// processor registered, VTRAWProcessingSessionCreate fails and the controller
static IMP sSpliceKitBRAWRAWOriginalControllerInit = NULL;
static IMP sSpliceKitBRAWRAWOriginalSetProcessingParam = NULL;
static void SpliceKitBRAWRAWPostAssetChangeNotification(id asset, NSInteger changeType);
static void SpliceKitBRAWRAWInvalidateAssetSourceRange(id asset);
static void SpliceKitBRAWRAWForceActiveSequenceContextRefresh(void);

static BOOL SpliceKitBRAWRAWSetProcessingParamOverride(id self, SEL _cmd, id value, id key) {
    if (sSpliceKitBRAWRAWOriginalSetProcessingParam) {
        BOOL ok = ((BOOL (*)(id, SEL, id, id))sSpliceKitBRAWRAWOriginalSetProcessingParam)(self, _cmd, value, key);
        if (!ok) return NO;

        NSMutableDictionary *threadDictionary = [NSThread currentThread].threadDictionary;
        if ([threadDictionary[kSpliceKitBRAWRAWSessionWritebackGuardKey] boolValue]) {
            return YES;
        }

        NSString *path = objc_getAssociatedObject(self, kSpliceKitBRAWRAWSessionPathKey);
        if (path.length == 0) return YES;

        NSDictionary *settings = nil;
        if ([self respondsToSelector:@selector(copyVTRAWSettingsFromSession)]) {
            id vtSettings = ((id (*)(id, SEL))objc_msgSend)(self, @selector(copyVTRAWSettingsFromSession));
            settings = SpliceKitBRAWRAWSettingsDictionaryFromVTRAWSettings(vtSettings);
        }
        if (settings.count == 0) return YES;

        SpliceKitBRAW_SetRAWSettingsForPath((__bridge CFStringRef)path,
                                            (__bridge CFDictionaryRef)settings);

        id asset = objc_getAssociatedObject(self, kSpliceKitBRAWRAWSessionAssetKey);
        if (asset && [asset respondsToSelector:@selector(setRawProcessorSettings:)]) {
            NSDictionary *mergedSettings = SpliceKitBRAWRAWMergedRawProcessorSettings(asset, settings);
            if (mergedSettings.count > 0) {
                threadDictionary[kSpliceKitBRAWRAWSessionWritebackGuardKey] = @YES;
                @try {
                    ((void (*)(id, SEL, id))objc_msgSend)(asset, @selector(setRawProcessorSettings:), mergedSettings);
                    // Match the private generic VT RAW flow as closely as
                    // possible: set rawProcessorSettings, then invalidate the
                    // asset's RAW provider state so the viewer/browser pulls a
                    // fresh frame immediately.
                    if ([asset respondsToSelector:@selector(invalidateRAWSettings)]) {
                        ((void (*)(id, SEL))objc_msgSend)(asset, @selector(invalidateRAWSettings));
                    } else {
                        SpliceKitBRAWRAWPostAssetChangeNotification(asset, 2);
                        SpliceKitBRAWRAWInvalidateAssetSourceRange(asset);
                        if ([asset respondsToSelector:@selector(invalidate)]) {
                            ((void (*)(id, SEL))objc_msgSend)(asset, @selector(invalidate));
                        }
                    }
                    SpliceKitBRAWRAWForceActiveSequenceContextRefresh();
                } @catch (__unused NSException *e) {
                } @finally {
                    [threadDictionary removeObjectForKey:kSpliceKitBRAWRAWSessionWritebackGuardKey];
                }
            }
        }

        SpliceKitBRAWRAWTrace([NSString stringWithFormat:@"session writeback path=%@ %@=%@",
                               path, key ?: @"<nil>", value ?: @"<nil>"]);
        return YES;
    }
    return NO;
}

static CFStringRef SpliceKitBRAWRAWVTKey(const char *symbolName) {
    void *ptr = dlsym(RTLD_DEFAULT, symbolName);
    if (!ptr) return NULL;
    return *(CFStringRef *)ptr;
}

static NSString *SpliceKitBRAWRAWVTKeyStr(const char *symbolName) {
    CFStringRef cf = SpliceKitBRAWRAWVTKey(symbolName);
    return cf ? (__bridge NSString *)cf : nil;
}

static NSString *SpliceKitBRAWRAWGlobalString(const char *symbolName) {
    CFStringRef cf = SpliceKitBRAWRAWVTKey(symbolName);
    return cf ? (__bridge NSString *)cf : nil;
}

static void SpliceKitBRAWRAWPostAssetChangeNotification(id asset, NSInteger changeType) {
    if (!asset) return;

    Class notificationCenterClass = objc_getClass("FFNotificationCenter");
    if (!notificationCenterClass) return;

    NSString *name = SpliceKitBRAWRAWGlobalString("FFAssetChangeNotification");
    NSString *typeKey = SpliceKitBRAWRAWGlobalString("FFAssetChangeNotificationTypeKey");
    if (name.length == 0 || typeKey.length == 0) return;

    SEL postSel = @selector(postNotificationName:object:userInfo:);
    if (![notificationCenterClass respondsToSelector:postSel]) return;

    NSDictionary *userInfo = @{ typeKey: @(changeType) };
    ((void (*)(id, SEL, id, id, id))objc_msgSend)(notificationCenterClass,
                                                   postSel,
                                                   name,
                                                   asset,
                                                   userInfo);
}

static void SpliceKitBRAWRAWInvalidateAssetSourceRange(id asset) {
    SEL invalidateSel = NSSelectorFromString(@"invalidateSourceRange:");
    if (!asset || ![asset respondsToSelector:invalidateSel]) return;

    CMTimeRange fullRange = CMTimeRangeMake(kCMTimeZero, kCMTimePositiveInfinity);
    ((void (*)(id, SEL, CMTimeRange))objc_msgSend)(asset, invalidateSel, fullRange);
}

static id SpliceKitBRAWRAWCurrentSequence(void) {
    id timelineModule = SpliceKit_getActiveTimelineModule();
    if (!timelineModule) return nil;

    SEL sequenceSel = NSSelectorFromString(@"sequence");
    if (![timelineModule respondsToSelector:sequenceSel]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(timelineModule, sequenceSel);
}

static void SpliceKitBRAWRAWForceActiveSequenceContextRefresh(void) {
    id sequence = SpliceKitBRAWRAWCurrentSequence();
    SEL forceSel = NSSelectorFromString(@"forcePlayerContextChangeForSequence");
    if (!sequence || ![sequence respondsToSelector:forceSel]) return;
    ((void (*)(id, SEL))objc_msgSend)(sequence, forceSel);
}

static id SpliceKitBRAWRAWControllerInitOverride(id self, SEL _cmd, id source, id settings, id asset) {
    if (!sSpliceKitBRAWRAWOriginalControllerInit) {
        return nil;
    }
    id controller = ((id (*)(id, SEL, id, id, id))sSpliceKitBRAWRAWOriginalControllerInit)(self, _cmd, source, settings, asset);
    if (!controller) return nil;
    if (SpliceKitBRAWRAWHasBRAWCodec(asset) || SpliceKitBRAWRAWHasBRAWCodec(source)) {
        SpliceKitBRAWRAWAssociateSessionWithPathAndAsset(controller, asset, source);
    }
    return controller;
}

static void SpliceKitBRAWRAWClipControllerAddTilesOverride(id self, SEL _cmd, id items, id refs, id owner) {
    NSUInteger n = 0;
    NSString *firstCls = @"<nil>";
    if ([items respondsToSelector:@selector(count)]) {
        n = ((NSUInteger (*)(id, SEL))objc_msgSend)(items, @selector(count));
    }
    if (n > 0 && [items respondsToSelector:@selector(firstObject)]) {
        id first = ((id (*)(id, SEL))objc_msgSend)(items, @selector(firstObject));
        if (first) firstCls = NSStringFromClass([first class]);
    }
    @synchronized (sSpliceKitBRAWRAWInitCounters) {
        NSString *key = @"CLIPCTRL:_addTilesForItems";
        NSInteger k = [sSpliceKitBRAWRAWInitCounters[key] integerValue];
        sSpliceKitBRAWRAWInitCounters[key] = @(k + 1);
    }
    SpliceKitBRAWRAWTrace([NSString stringWithFormat:@"CLIPCTRL addTiles self=%@ items.count=%lu firstClass=%@",
        NSStringFromClass([self class]), (unsigned long)n, firstCls]);
    if (sSpliceKitBRAWRAWOriginalClipControllerAddTiles) {
        ((void (*)(id, SEL, id, id, id))sSpliceKitBRAWRAWOriginalClipControllerAddTiles)(self, _cmd, items, refs, owner);
    }
}

// Determine whether any of the given inspector items resolves back to a
// BRAW-backed asset. Works across FFAssetRef, FFAnchoredMediaComponent, and
// anything else in the item chain — we probe via -asset, -media, -firstAsset,
// -firstAssetIfOnlyOneVideo, and -originalMediaRep and accept a hit on any
// path that reaches an object recognized by SpliceKitBRAWRAWHasBRAWCodec.
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
    SpliceKitBRAWRAWTrace([NSString stringWithFormat:@"PARENT addTilesForItems self=%@ count=%lu isBRAW=%d",
        NSStringFromClass([self class]), (unsigned long)n, isBRAW]);

    NSMutableDictionary *td = [NSThread currentThread].threadDictionary;
    [td removeObjectForKey:kSpliceKitBRAWRAWCurrentAddNativeRAWKey];

    if (sSpliceKitBRAWRAWOriginalAddTilesForItems) {
        ((void (*)(id, SEL, id, id, id))sSpliceKitBRAWRAWOriginalAddTilesForItems)(self, _cmd, items, refs, owner);
    }

    // Post-process: for BRAW-backed selections, FCP's stock addTilesForItems
    // skips FFInspectorFileInfoRAWProcessorTile when items are timeline clips
    // (FFAnchoredMediaComponent) that don't pass the -isAssetRef check. If
    // the native path already added the tile (e.g. browser-selected AssetRef),
    // don't add a second one.
    BOOL nativeAddedRAW = [td[kSpliceKitBRAWRAWCurrentAddNativeRAWKey] boolValue];
    [td removeObjectForKey:kSpliceKitBRAWRAWCurrentAddNativeRAWKey];
    if (isBRAW && !nativeAddedRAW && [self respondsToSelector:@selector(_addTileOfClass:items:references:owner:)]) {
        Class rawTile = objc_getClass("FFInspectorFileInfoRAWProcessorTile");
        if (rawTile) {
            SpliceKitBRAWRAWTrace(@"forcing FFInspectorFileInfoRAWProcessorTile for BRAW items (native didn't add it)");
            ((id (*)(id, SEL, Class, id, id, id))objc_msgSend)(
                self, @selector(_addTileOfClass:items:references:owner:),
                rawTile, items, refs, owner);
        }
    }
}

// Thread-local flag set when native addTilesForItems already added the RAW
// processor tile during the current call. Used by our force-add wrapper to
// avoid adding a duplicate tile on top of FCP's own.
static id SpliceKitBRAWRAWAddTileOfClassOverride(id self, SEL _cmd, Class tileClass, id items, id refs, id owner) {
    @synchronized (sSpliceKitBRAWRAWInitCounters) {
        NSString *key = [NSString stringWithFormat:@"ADD:%@", NSStringFromClass(tileClass) ?: @"?"];
        NSInteger n = [sSpliceKitBRAWRAWInitCounters[key] integerValue];
        sSpliceKitBRAWRAWInitCounters[key] = @(n + 1);
    }
    SpliceKitBRAWRAWTrace([NSString stringWithFormat:@"ADD tile class=%@", NSStringFromClass(tileClass)]);
    if (tileClass == objc_getClass("FFInspectorFileInfoRAWProcessorTile")) {
        [[NSThread currentThread].threadDictionary setObject:@YES forKey:kSpliceKitBRAWRAWCurrentAddNativeRAWKey];
    }
    if (sSpliceKitBRAWRAWOriginalAddTileOfClass) {
        return ((id (*)(id, SEL, Class, id, id, id))sSpliceKitBRAWRAWOriginalAddTileOfClass)(self, _cmd, tileClass, items, refs, owner);
    }
    return nil;
}

static void SpliceKitBRAWRAWRAWTileUpdateOverride(id self, SEL _cmd, id items, id refs, id owner) {
    @synchronized (sSpliceKitBRAWRAWInitCounters) {
        NSString *key = NSStringFromClass([self class]) ?: @"?";
        NSInteger n = [sSpliceKitBRAWRAWInitCounters[key] integerValue];
        sSpliceKitBRAWRAWInitCounters[key] = @(n + 1);
    }
    SpliceKitBRAWRAWTrace([NSString stringWithFormat:@"TILE UPDATE: %@ items=%@",
        NSStringFromClass([self class]), items]);
    if (sSpliceKitBRAWRAWOriginalRAWTileUpdate) {
        ((void (*)(id, SEL, id, id, id))sSpliceKitBRAWRAWOriginalRAWTileUpdate)(self, _cmd, items, refs, owner);
    }
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

static void SpliceKitBRAWRAWRegisterInspectorRPCs(void) {
    SpliceKitBRAWRAWTrace(@"RPC registration: starting");
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

        // Helper to check whether a class itself (not a superclass) defines a
        // given instance method. Critical — swizzling an inherited method hits
        // the superclass (we lost an hour to -init on NSObject).
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

        Class tileClass = objc_getClass("FFInspectorFileInfoRAWProcessorTile");
        if (tileClass && classDefines(tileClass, @selector(updateWithItems:references:owner:)) &&
            !sSpliceKitBRAWRAWOriginalRAWTileUpdate) {
            Method m = class_getInstanceMethod(tileClass, @selector(updateWithItems:references:owner:));
            sSpliceKitBRAWRAWOriginalRAWTileUpdate = method_setImplementation(m, (IMP)SpliceKitBRAWRAWRAWTileUpdateOverride);
            SpliceKitBRAWRAWTrace(@"installed FFInspectorFileInfoRAWProcessorTile.updateWithItems counter");
        }

        Class baseTile = objc_getClass("FFInspectorFileInfoTile");
        if (baseTile && classDefines(baseTile, @selector(_addTileOfClass:items:references:owner:)) &&
            !sSpliceKitBRAWRAWOriginalAddTileOfClass) {
            Method m = class_getInstanceMethod(baseTile, @selector(_addTileOfClass:items:references:owner:));
            sSpliceKitBRAWRAWOriginalAddTileOfClass = method_setImplementation(m, (IMP)SpliceKitBRAWRAWAddTileOfClassOverride);
            SpliceKitBRAWRAWTrace(@"installed FFInspectorFileInfoTile._addTileOfClass counter");
        }

        if (baseTile && classDefines(baseTile, @selector(addTilesForItems:references:owner:)) &&
            !sSpliceKitBRAWRAWOriginalAddTilesForItems) {
            Method m = class_getInstanceMethod(baseTile, @selector(addTilesForItems:references:owner:));
            sSpliceKitBRAWRAWOriginalAddTilesForItems = method_setImplementation(m, (IMP)SpliceKitBRAWRAWAddTilesForItemsOverride);
            SpliceKitBRAWRAWTrace(@"installed FFInspectorFileInfoTile.addTilesForItems counter");
        }

        Class clipCtrl = objc_getClass("FFInspectorFileInfoClipController");
        if (clipCtrl && classDefines(clipCtrl, @selector(_addTilesForItems:references:owner:)) &&
            !sSpliceKitBRAWRAWOriginalClipControllerAddTiles) {
            Method m = class_getInstanceMethod(clipCtrl, @selector(_addTilesForItems:references:owner:));
            sSpliceKitBRAWRAWOriginalClipControllerAddTiles = method_setImplementation(m, (IMP)SpliceKitBRAWRAWClipControllerAddTilesOverride);
            SpliceKitBRAWRAWTrace(@"installed FFInspectorFileInfoClipController._addTilesForItems counter");
        }

    });
    SpliceKitBRAWRAWTrace(@"RPC registration: done");
}

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

// ---- Hooks that drive whether the Modify-RAW button tile is added to the
// inspector. Decompiling Flexo's -[FFInspectorFileInfoTile
// addTilesForItems:references:owner:] shows the tile is only instantiated when
// FCP finds at least one selected asset whose codec is reported as BOTH
// "using a MediaExtension decoder" AND "is a RAW decoder", by way of
// FFMediaExtensionManager. BRAW isn't registered as a MediaExtension on disk,
// so we intercept the manager's accessors and force YES for fourcc 'braw'.
// The mediaRep's videoCodec4CC also has to return 'braw' — we fall back to
// filename-extension sniffing when the stored fourcc is still zero.

static IMP sSpliceKitBRAWRAWOriginalIsDecoderME = NULL;
static IMP sSpliceKitBRAWRAWOriginalIsDecoderRAW = NULL;
static IMP sSpliceKitBRAWRAWOriginalMediaRepCodec = NULL;

static BOOL SpliceKitBRAWRAWIsDecoderMEOverride(id self, SEL _cmd, unsigned int codec) {
    BOOL match = SpliceKitBRAWRAWIsBRAWFourCC(codec);
    BOOL orig = NO;
    if (sSpliceKitBRAWRAWOriginalIsDecoderME) {
        orig = ((BOOL (*)(id, SEL, unsigned int))sSpliceKitBRAWRAWOriginalIsDecoderME)(self, _cmd, codec);
    }
    static NSMutableSet *seen = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ seen = [NSMutableSet new]; });
    NSString *k = [NSString stringWithFormat:@"ME:%u", codec];
    if (seen.count < 16 && ![seen containsObject:k]) {
        [seen addObject:k];
        SpliceKitBRAWRAWTrace([NSString stringWithFormat:@"isDecoderME(%u)=%d orig=%d match=%d",
            codec, match || orig, orig, match]);
    }
    return match ? YES : orig;
}

static BOOL SpliceKitBRAWRAWIsDecoderRAWOverride(id self, SEL _cmd, unsigned int codec) {
    BOOL match = SpliceKitBRAWRAWIsBRAWFourCC(codec);
    BOOL orig = NO;
    if (sSpliceKitBRAWRAWOriginalIsDecoderRAW) {
        orig = ((BOOL (*)(id, SEL, unsigned int))sSpliceKitBRAWRAWOriginalIsDecoderRAW)(self, _cmd, codec);
    }
    static NSMutableSet *seen = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ seen = [NSMutableSet new]; });
    NSString *k = [NSString stringWithFormat:@"RAW:%u", codec];
    if (seen.count < 16 && ![seen containsObject:k]) {
        [seen addObject:k];
        SpliceKitBRAWRAWTrace([NSString stringWithFormat:@"isDecoderRAW(%u)=%d orig=%d match=%d",
            codec, match || orig, orig, match]);
    }
    return match ? YES : orig;
}

static unsigned int SpliceKitBRAWRAWMediaRepCodecOverride(id self, SEL _cmd) {
    unsigned int orig = 0;
    if (sSpliceKitBRAWRAWOriginalMediaRepCodec) {
        orig = ((unsigned int (*)(id, SEL))sSpliceKitBRAWRAWOriginalMediaRepCodec)(self, _cmd);
    }
    unsigned int result = orig;
    NSString *foundExt = nil;
    if (orig == 0) {
        SEL urlSelectors[] = { @selector(fileURL), @selector(URL), @selector(persistentFileURL) };
        for (size_t i = 0; i < sizeof(urlSelectors) / sizeof(SEL); ++i) {
            if (![self respondsToSelector:urlSelectors[i]]) continue;
            NSURL *url = ((NSURL *(*)(id, SEL))objc_msgSend)(self, urlSelectors[i]);
            if ([url isKindOfClass:[NSURL class]]) {
                foundExt = url.pathExtension;
                if ([foundExt caseInsensitiveCompare:@"braw"] == NSOrderedSame) {
                    result = (unsigned int)kSpliceKitBRAWRAWCodecType;
                    break;
                }
            }
        }
    }
    // Log first few calls so we can confirm the override fires and what the
    // input URL / existing codec were.
    static NSMutableSet *seen = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ seen = [NSMutableSet new]; });
    NSString *key = [NSString stringWithFormat:@"%@:%u:%u:%@",
        NSStringFromClass([self class]), orig, result, foundExt ?: @"-"];
    if (seen.count < 16 && ![seen containsObject:key]) {
        [seen addObject:key];
        SpliceKitBRAWRAWTrace([NSString stringWithFormat:@"mediaRep.videoCodec4CC class=%@ orig=%u result=%u urlExt=%@",
            NSStringFromClass([self class]), orig, result, foundExt ?: @"<nil>"]);
    }
    return result;
}

SPLICEKIT_BRAW_RAW_EXTERN_C BOOL SpliceKit_installBRAWRAWSettingsHooks(void) {
    NSNumber *override = [[NSUserDefaults standardUserDefaults] objectForKey:kSpliceKitBRAWRAWEnabledDefault];
    BOOL enabled = override ? override.boolValue : YES;
    SpliceKitBRAWRAWTrace([NSString stringWithFormat:@"install enabled=%@ (default key %@ override=%@)",
                                                     enabled ? @"YES" : @"NO",
                                                     kSpliceKitBRAWRAWEnabledDefault,
                                                     override ?: @"<none>"]);
    if (!enabled) return NO;

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
            @selector(codecIsRawExtension),
            (IMP)SpliceKitBRAWRAWSourceCodecIsRawExtOverride,
            &sSpliceKitBRAWRAWOriginalSourceCodecIsRawExt,
            @"FFSourceVideoFig.codecIsRawExtension");
        anyInstalled |= SpliceKitBRAWRAWHookMethod(svf,
            @selector(setRAWAdjustmentInfo:),
            (IMP)SpliceKitBRAWRAWSourceSetRAWAdjustmentInfoOverride,
            &sSpliceKitBRAWRAWOriginalSourceSetRAWAdjustmentInfo,
            @"FFSourceVideoFig.setRAWAdjustmentInfo:");
    } else {
        SpliceKitBRAWRAWTrace(@"FFSourceVideoFig class missing");
    }

    Class vtCtrl = objc_getClass("FFVTRAWSettingsController");
    if (vtCtrl) {
        anyInstalled |= SpliceKitBRAWRAWHookMethod(vtCtrl,
            @selector(initWithSource:settings:asset:),
            (IMP)SpliceKitBRAWRAWControllerInitOverride,
            &sSpliceKitBRAWRAWOriginalControllerInit,
            @"FFVTRAWSettingsController.initWithSource:settings:asset:");
    } else {
        SpliceKitBRAWRAWTrace(@"FFVTRAWSettingsController class missing");
    }

    Class vtSession = objc_getClass("FFVTRAWProcessorSession");
    if (vtSession) {
        anyInstalled |= SpliceKitBRAWRAWHookMethod(vtSession,
            @selector(setProcessingParameter:forKey:),
            (IMP)SpliceKitBRAWRAWSetProcessingParamOverride,
            &sSpliceKitBRAWRAWOriginalSetProcessingParam,
            @"FFVTRAWProcessorSession.setProcessingParameter:forKey:");
    } else {
        SpliceKitBRAWRAWTrace(@"FFVTRAWProcessorSession class missing");
    }

    Class mem = objc_getClass("FFMediaExtensionManager");
    if (mem) {
        anyInstalled |= SpliceKitBRAWRAWHookMethod(mem,
            @selector(isDecoderUsingMediaExtension:),
            (IMP)SpliceKitBRAWRAWIsDecoderMEOverride,
            &sSpliceKitBRAWRAWOriginalIsDecoderME,
            @"FFMediaExtensionManager.isDecoderUsingMediaExtension:");
        anyInstalled |= SpliceKitBRAWRAWHookMethod(mem,
            @selector(isDecoderRAW:),
            (IMP)SpliceKitBRAWRAWIsDecoderRAWOverride,
            &sSpliceKitBRAWRAWOriginalIsDecoderRAW,
            @"FFMediaExtensionManager.isDecoderRAW:");
    } else {
        SpliceKitBRAWRAWTrace(@"FFMediaExtensionManager class missing");
    }

    Class mediaRep = objc_getClass("FFMediaRep");
    if (mediaRep) {
        anyInstalled |= SpliceKitBRAWRAWHookMethod(mediaRep,
            @selector(videoCodec4CC),
            (IMP)SpliceKitBRAWRAWMediaRepCodecOverride,
            &sSpliceKitBRAWRAWOriginalMediaRepCodec,
            @"FFMediaRep.videoCodec4CC");
    } else {
        SpliceKitBRAWRAWTrace(@"FFMediaRep class missing");
    }

    SpliceKitBRAWRAWRegisterInspectorRPCs();
    return anyInstalled;
}
