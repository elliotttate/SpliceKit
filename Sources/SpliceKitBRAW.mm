#import "SpliceKit.h"
#import "SpliceKitBRAWExports.h"
#import "SpliceKitBRAWToolboxCheck.h"

#include <dlfcn.h>
#include <sys/clonefile.h>
#include <sys/stat.h>
#import <MediaToolbox/MTProfessionalVideoWorkflow.h>
#import <VideoToolbox/VideoToolbox.h>
#import <VideoToolbox/VTProfessionalVideoWorkflow.h>
#import <VideoToolbox/VTUtilities.h>
#import <AVFoundation/AVFoundation.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <CoreServices/CoreServices.h>
#import <Metal/Metal.h>

extern "C" void MTRegisterPluginFormatReaderBundleDirectory(CFURLRef directoryURL);
extern "C" void VTRegisterVideoDecoderBundleDirectory(CFURLRef directoryURL);

#if __has_include("/Applications/Blackmagic RAW/Blackmagic RAW SDK/Mac/Include/BlackmagicRawAPI.h")
#include <atomic>
#include <vector>
#include <string>
#include "/Applications/Blackmagic RAW/Blackmagic RAW SDK/Mac/Include/BlackmagicRawAPI.h"
#define SPLICEKIT_HAS_BRAW_SDK 1
#else
#define SPLICEKIT_HAS_BRAW_SDK 0
#endif

#ifdef __cplusplus
#define SPLICEKIT_BRAW_EXTERN_C extern "C"
#else
#define SPLICEKIT_BRAW_EXTERN_C extern
#endif

#if SPLICEKIT_HAS_BRAW_SDK

typedef IBlackmagicRawFactory *(*SpliceKitBRAWCreateFactoryFn)(void);
typedef IBlackmagicRawFactory *(*SpliceKitBRAWCreateFactoryFromPathFn)(CFStringRef loadPath);
typedef int64_t (*SpliceKitBRAWPCRegisterMediaExtensionFormatReadersFn)(void);
typedef int64_t (*SpliceKitBRAWPCRegisterFormatReadersFromAppBundleFn)(bool);
typedef int64_t (*SpliceKitBRAWPCRegisterFormatReadersFromDirectoryFn)(CFURLRef, bool);
typedef int64_t (*SpliceKitBRAWPCRegisterVideoCodecsFromAppBundleFn)(CFDictionaryRef _Nullable *);
typedef int64_t (*SpliceKitBRAWPCRegisterVideoCodecsDirectoryFn)(CFURLRef, bool, CFDictionaryRef _Nullable *);
typedef int64_t (*SpliceKitBRAWPCRegisterVideoCodecBundleInProcessFn)(CFBundleRef, CFDictionaryRef _Nullable *);
typedef int64_t (*SpliceKitBRAWPCRegisterVideoCodecsFromPlugInsDirFn)(CFURLRef, CFDictionaryRef _Nullable *);

static NSString *SpliceKitBRAWHRESULTString(HRESULT value) {
    return [NSString stringWithFormat:@"0x%08X", (unsigned int)value];
}

static NSDictionary *SpliceKitBRAWErrorResult(NSString *message) {
    return @{@"error": message ?: @"Blackmagic RAW probe failed"};
}

static NSString *SpliceKitBRAWLogFilePath(void) {
    return @"/tmp/splicekit-braw.log";
}

static void SpliceKitBRAWTrace(NSString *message) {
    if (message.length == 0) return;

    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], message];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) return;

    NSString *path = SpliceKitBRAWLogFilePath();
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
    }

    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!handle) return;

    @try {
        [handle seekToEndOfFile];
        [handle writeData:data];
    } @catch (__unused NSException *exception) {
    } @finally {
        [handle closeFile];
    }
}

static NSString *SpliceKitBRAWCopyNSString(CFStringRef value) {
    if (!value) return nil;
    return [(__bridge NSString *)value copy];
}

static NSString *SpliceKitBRAWResourceFormatName(BlackmagicRawResourceFormat format) {
    switch (format) {
        case blackmagicRawResourceFormatRGBAU8: return @"RGBAU8";
        case blackmagicRawResourceFormatBGRAU8: return @"BGRAU8";
        case blackmagicRawResourceFormatRGBU16: return @"RGBU16";
        case blackmagicRawResourceFormatRGBAU16: return @"RGBAU16";
        case blackmagicRawResourceFormatBGRAU16: return @"BGRAU16";
        case blackmagicRawResourceFormatRGBU16Planar: return @"RGBU16Planar";
        case blackmagicRawResourceFormatRGBF32: return @"RGBF32";
        case blackmagicRawResourceFormatRGBAF32: return @"RGBAF32";
        case blackmagicRawResourceFormatBGRAF32: return @"BGRAF32";
        case blackmagicRawResourceFormatRGBF32Planar: return @"RGBF32Planar";
        case blackmagicRawResourceFormatRGBF16: return @"RGBF16";
        case blackmagicRawResourceFormatRGBAF16: return @"RGBAF16";
        case blackmagicRawResourceFormatBGRAF16: return @"BGRAF16";
        case blackmagicRawResourceFormatRGBF16Planar: return @"RGBF16Planar";
        default: return [NSString stringWithFormat:@"0x%08X", format];
    }
}

static NSString *SpliceKitBRAWResourceTypeName(BlackmagicRawResourceType type) {
    switch (type) {
        case blackmagicRawResourceTypeBufferCPU: return @"BufferCPU";
        case blackmagicRawResourceTypeBufferMetal: return @"BufferMetal";
        case blackmagicRawResourceTypeBufferCUDA: return @"BufferCUDA";
        case blackmagicRawResourceTypeBufferOpenCL: return @"BufferOpenCL";
        default: return [NSString stringWithFormat:@"0x%08X", type];
    }
}

static NSString *SpliceKitBRAWVariantTypeName(BlackmagicRawVariantType type) {
    switch (type) {
        case blackmagicRawVariantTypeEmpty: return @"empty";
        case blackmagicRawVariantTypeU8: return @"u8";
        case blackmagicRawVariantTypeS16: return @"s16";
        case blackmagicRawVariantTypeU16: return @"u16";
        case blackmagicRawVariantTypeS32: return @"s32";
        case blackmagicRawVariantTypeU32: return @"u32";
        case blackmagicRawVariantTypeFloat32: return @"float32";
        case blackmagicRawVariantTypeString: return @"string";
        case blackmagicRawVariantTypeSafeArray: return @"safeArray";
        case blackmagicRawVariantTypeFloat64: return @"float64";
        default: return [NSString stringWithFormat:@"0x%08X", type];
    }
}

static NSArray *SpliceKitBRAWArrayFromContainer(id value) {
    if (!value || value == (id)kCFNull) return @[];
    if ([value isKindOfClass:[NSArray class]]) return value;

    SEL allObjectsSel = NSSelectorFromString(@"allObjects");
    if ([value respondsToSelector:allObjectsSel]) {
        id allObjects = ((id (*)(id, SEL))objc_msgSend)(value, allObjectsSel);
        if ([allObjects isKindOfClass:[NSArray class]]) return allObjects;
    }

    SEL countSel = @selector(count);
    SEL objectAtIndexSel = @selector(objectAtIndex:);
    if ([value respondsToSelector:countSel] && [value respondsToSelector:objectAtIndexSel]) {
        NSUInteger count = ((NSUInteger (*)(id, SEL))objc_msgSend)(value, countSel);
        NSMutableArray *items = [NSMutableArray arrayWithCapacity:count];
        for (NSUInteger i = 0; i < count; i++) {
            id item = ((id (*)(id, SEL, NSUInteger))objc_msgSend)(value, objectAtIndexSel, i);
            if (item) [items addObject:item];
        }
        return items;
    }

    return @[];
}

static NSURL *SpliceKitBRAWURLFromValue(id value) {
    if (!value || value == (id)kCFNull) return nil;
    if ([value isKindOfClass:[NSURL class]]) return value;
    if ([value isKindOfClass:[NSArray class]]) {
        for (id item in (NSArray *)value) {
            NSURL *url = SpliceKitBRAWURLFromValue(item);
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

static NSURL *SpliceKitBRAWMediaURLForClipObject(id clip) {
    if (!clip) return nil;

    id target = clip;
    SEL primarySel = NSSelectorFromString(@"primaryObject");
    if ([target respondsToSelector:primarySel]) {
        id primary = ((id (*)(id, SEL))objc_msgSend)(target, primarySel);
        if (primary) target = primary;
    }

    NSArray<NSString *> *keyPaths = @[
        @"originalMediaURL",
        @"media.originalMediaURL",
        @"media.fileURL",
        @"assetMediaReference.resolvedURL",
        @"media.originalMediaRep.fileURLs",
        @"media.currentRep.fileURLs",
        @"clipInPlace.asset.originalMediaURL",
    ];

    for (NSString *keyPath in keyPaths) {
        @try {
            id value = [target valueForKeyPath:keyPath];
            NSURL *url = SpliceKitBRAWURLFromValue(value);
            if (url) return url;
        } @catch (NSException *exception) {
        }
    }

    SEL containedSel = NSSelectorFromString(@"containedItems");
    if ([target respondsToSelector:containedSel]) {
        id contained = ((id (*)(id, SEL))objc_msgSend)(target, containedSel);
        for (id child in SpliceKitBRAWArrayFromContainer(contained)) {
            NSURL *url = SpliceKitBRAWMediaURLForClipObject(child);
            if (url) return url;
        }
    }

    return nil;
}

static NSString *SpliceKitBRAWNormalizeProbePath(id candidate) {
    NSURL *url = SpliceKitBRAWURLFromValue(candidate);
    if (url.isFileURL) {
        NSURL *resolvedURL = [url URLByResolvingSymlinksInPath];
        NSString *resolvedPath = resolvedURL.path.stringByStandardizingPath;
        if (resolvedPath.length > 0) return resolvedPath;
        return url.path.stringByStandardizingPath;
    }
    if ([candidate isKindOfClass:[NSString class]]) {
        NSString *path = [(NSString *)candidate stringByStandardizingPath];
        if (path.length == 0) return nil;
        NSURL *resolvedURL = [[NSURL fileURLWithPath:path] URLByResolvingSymlinksInPath];
        NSString *resolvedPath = resolvedURL.path.stringByStandardizingPath;
        return resolvedPath.length > 0 ? resolvedPath : path;
    }
    return nil;
}

static BOOL SpliceKitBRAWIsClipPath(NSString *path) {
    return [[path.pathExtension lowercaseString] isEqualToString:@"braw"];
}

static int kSpliceKitBRAWWorkQueueSpecificKey = 0;
static void SpliceKitBRAWHostInvalidateEntry(NSString *path);

static NSLock *SpliceKitBRAWRAWSettingsLock(void) {
    static NSLock *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        lock = [[NSLock alloc] init];
    });
    return lock;
}

static NSMutableDictionary<NSString *, NSDictionary *> *SpliceKitBRAWRAWSettingsMap(void) {
    static NSMutableDictionary<NSString *, NSDictionary *> *map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        map = [NSMutableDictionary dictionary];
    });
    return map;
}

SPLICEKIT_BRAW_EXTERN_C void SpliceKitBRAW_SetRAWSettingsForPath(CFStringRef pathRef, CFDictionaryRef settingsRef) {
    NSString *path = SpliceKitBRAWNormalizeProbePath((__bridge id)pathRef);
    if (!SpliceKitBRAWIsClipPath(path)) {
        return;
    }

    NSDictionary *settings = (__bridge NSDictionary *)settingsRef;
    NSDictionary *sanitized = [settings isKindOfClass:[NSDictionary class]] ? [settings copy] : nil;

    [SpliceKitBRAWRAWSettingsLock() lock];
    if (sanitized.count > 0) {
        SpliceKitBRAWRAWSettingsMap()[path] = sanitized;
    } else {
        [SpliceKitBRAWRAWSettingsMap() removeObjectForKey:path];
    }
    [SpliceKitBRAWRAWSettingsLock() unlock];

    SpliceKitBRAWTrace([NSString stringWithFormat:@"[raw-settings-cache] %@ %@",
                        sanitized.count > 0 ? @"store" : @"clear",
                        path]);

    // DELIBERATELY do NOT invalidate the cached host BRAW SDK clip entry on
    // settings changes. The decode path reads fresh settings per frame via
    // SpliceKitBRAW_CopyRAWSettingsForPath and applies them through
    // -[…ProcessingAttributes] passed to CreateJobDecodeAndProcessFrame. The
    // SDK clip handle's state doesn't depend on the settings, so tearing it
    // down forces an expensive reopen (file open + Metal pipeline rebuild)
    // for every slider tick. Was causing visibly slow updates and the
    // [host-decode] released/opened/invalidated log spam during HUD drags.
    //
    // (void)SpliceKitBRAWHostInvalidateEntry(path);  // intentionally disabled
}

SPLICEKIT_BRAW_EXTERN_C CFDictionaryRef SpliceKitBRAW_CopyRAWSettingsForPath(CFStringRef pathRef) {
    NSString *path = SpliceKitBRAWNormalizeProbePath((__bridge id)pathRef);
    if (!SpliceKitBRAWIsClipPath(path)) {
        return nullptr;
    }

    [SpliceKitBRAWRAWSettingsLock() lock];
    NSDictionary *settings = [SpliceKitBRAWRAWSettingsMap()[path] copy];
    [SpliceKitBRAWRAWSettingsLock() unlock];
    return settings ? (CFDictionaryRef)CFBridgingRetain(settings) : nullptr;
}

static NSString *const kSpliceKitBRAWUTI = @"com.blackmagic-design.braw-movie";
static NSString *const kSpliceKitBRAW2UTI = @"com.blackmagic-design.braw2-movie";
static const FourCharCode kSpliceKitBRAWCodecType = 'braw';

static NSArray<NSString *> *SpliceKitBRAWUniqueStrings(NSArray *base, NSArray<NSString *> *extras) {
    NSMutableOrderedSet<NSString *> *values = [NSMutableOrderedSet orderedSet];
    for (id item in SpliceKitBRAWArrayFromContainer(base)) {
        if ([item isKindOfClass:[NSString class]] && ((NSString *)item).length) {
            [values addObject:item];
        }
    }
    for (NSString *item in extras) {
        if (item.length) {
            [values addObject:item];
        }
    }
    return values.array ?: @[];
}

static NSString *SpliceKitBRAWMissingReasonName(NSInteger reason) {
    switch (reason) {
        case 0: return @"none";
        case 2: return @"rosetta-required";
        case 3: return @"video-decoder-disabled";
        case 4: return @"video-decoder-conflict";
        case 5: return @"format-reader-disabled";
        case 6: return @"format-reader-conflict";
        case 7: return @"format-reader-unavailable";
        case 8: return @"stale-media-reader-cache";
        default: return [NSString stringWithFormat:@"unknown-%ld", (long)reason];
    }
}

static IMP sSpliceKitBRAWOriginalProviderFigExtensionsIMP = NULL;
static IMP sSpliceKitBRAWOriginalProviderFigUTIsIMP = NULL;

static BOOL SpliceKitBRAWBoolDefault(NSString *key, BOOL fallback) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if ([defaults objectForKey:key] == nil) {
        return fallback;
    }
    return [defaults boolForKey:key];
}

static NSString *SpliceKitBRAWBundlePath(NSString *subpath) {
    NSString *pluginsPath = [[NSBundle mainBundle] builtInPlugInsPath];
    if (pluginsPath.length == 0 || subpath.length == 0) return nil;
    return [pluginsPath stringByAppendingPathComponent:subpath];
}

static NSURL *SpliceKitBRAWDirectoryURL(NSString *subpath) {
    NSString *path = SpliceKitBRAWBundlePath(subpath);
    if (path.length == 0) return nil;
    return [NSURL fileURLWithPath:path isDirectory:YES];
}

static NSString *SpliceKitBRAWResolveProCorePath(void) {
    Class proCoreClass = objc_getClass("PCFeatureFlags");
    if (proCoreClass) {
        NSBundle *bundle = [NSBundle bundleForClass:proCoreClass];
        if (bundle.executablePath.length > 0) {
            return bundle.executablePath;
        }
    }

    NSString *privateFrameworksPath = [[NSBundle mainBundle] privateFrameworksPath];
    if (privateFrameworksPath.length > 0) {
        NSString *candidate = [privateFrameworksPath stringByAppendingPathComponent:@"ProCore.framework/Versions/A/ProCore"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:candidate]) {
            return candidate;
        }
    }

    return @"/Applications/Final Cut Pro.app/Contents/Frameworks/ProCore.framework/Versions/A/ProCore";
}

static void *SpliceKitBRAWOpenProCoreHandle(NSMutableDictionary *details) {
    NSString *proCorePath = SpliceKitBRAWResolveProCorePath();
    details[@"proCorePath"] = proCorePath;
    void *handle = dlopen(proCorePath.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL | RTLD_NOLOAD);
    details[@"proCoreUsedExistingImage"] = @(handle != NULL);
    if (!handle) {
        handle = dlopen(proCorePath.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
    }
    if (!handle) {
        NSString *error = @(dlerror() ?: "dlopen failed");
        details[@"proCoreOpenError"] = error;
        SpliceKitBRAWTrace([NSString stringWithFormat:@"[register] ProCore dlopen failed %@", error]);
        return NULL;
    }
    details[@"proCoreOpened"] = @YES;
    return handle;
}

static BOOL SpliceKitBRAWLoadBundleAtPath(NSString *path, NSString *label, NSMutableDictionary *details) {
    NSString *existsKey = [NSString stringWithFormat:@"%@BundleExists", label];
    NSString *loadedKey = [NSString stringWithFormat:@"%@BundleLoaded", label];
    NSString *pathKey = [NSString stringWithFormat:@"%@BundlePath", label];
    NSString *errorKey = [NSString stringWithFormat:@"%@BundleError", label];
    NSString *identifierKey = [NSString stringWithFormat:@"%@BundleIdentifier", label];

    details[pathKey] = path ?: (id)[NSNull null];
    BOOL exists = path.length > 0 && [[NSFileManager defaultManager] fileExistsAtPath:path];
    details[existsKey] = @(exists);
    SpliceKitBRAWTrace([NSString stringWithFormat:@"[%@] load start path=%@", label, path ?: @"<nil>"]);
    if (!exists) {
        SpliceKitBRAWTrace([NSString stringWithFormat:@"[%@] load skipped missing bundle", label]);
        return NO;
    }

    NSBundle *bundle = [NSBundle bundleWithPath:path];
    if (!bundle) {
        details[loadedKey] = @NO;
        details[errorKey] = @"NSBundle bundleWithPath: returned nil";
        SpliceKitBRAWTrace([NSString stringWithFormat:@"[%@] bundleWithPath returned nil", label]);
        return NO;
    }

    if (bundle.bundleIdentifier.length > 0) {
        details[identifierKey] = bundle.bundleIdentifier;
    }

    NSError *error = nil;
    BOOL loaded = bundle.loaded || [bundle loadAndReturnError:&error];
    details[loadedKey] = @(loaded);
    if (!loaded && error) {
        details[errorKey] = error.localizedDescription ?: @"load failed";
    }
    SpliceKitBRAWTrace([NSString stringWithFormat:@"[%@] load result=%@ error=%@", label, loaded ? @"YES" : @"NO", error.localizedDescription ?: @"<none>"]);
    return loaded;
}

static void SpliceKitBRAWRegisterProfessionalWorkflowPlugins(NSMutableDictionary *details) {
    SpliceKitBRAWTrace(@"[register] professional workflow registration start");
    details[@"mediaExtensionsEnabled"] = @(((BOOL (*)(id, SEL))objc_msgSend)(
        objc_getClass("Flexo"),
        NSSelectorFromString(@"mediaExtensionsEnabled")));

    NSString *formatReaderBundlePath = SpliceKitBRAWBundlePath(@"FormatReaders/SpliceKitBRAWImport.bundle");
    NSString *videoDecoderBundlePath = SpliceKitBRAWBundlePath(@"Codecs/SpliceKitBRAWDecoder.bundle");
    NSString *formatReadersDirectory = SpliceKitBRAWBundlePath(@"FormatReaders");
    NSString *codecsDirectory = SpliceKitBRAWBundlePath(@"Codecs");
    details[@"formatReaderBundlePath"] = formatReaderBundlePath ?: (id)[NSNull null];
    details[@"videoDecoderBundlePath"] = videoDecoderBundlePath ?: (id)[NSNull null];
    details[@"formatReadersDirectoryPath"] = formatReadersDirectory ?: (id)[NSNull null];
    details[@"videoCodecsDirectoryPath"] = codecsDirectory ?: (id)[NSNull null];
    details[@"formatReaderBundleExists"] = @(formatReaderBundlePath.length > 0 && [[NSFileManager defaultManager] fileExistsAtPath:formatReaderBundlePath]);
    details[@"videoDecoderBundleExists"] = @(videoDecoderBundlePath.length > 0 && [[NSFileManager defaultManager] fileExistsAtPath:videoDecoderBundlePath]);
    details[@"formatReadersDirectoryExists"] = @(formatReadersDirectory.length > 0 && [[NSFileManager defaultManager] fileExistsAtPath:formatReadersDirectory]);
    details[@"videoCodecsDirectoryExists"] = @(codecsDirectory.length > 0 && [[NSFileManager defaultManager] fileExistsAtPath:codecsDirectory]);

    BOOL manuallyLoadedFormatReader = SpliceKitBRAWLoadBundleAtPath(formatReaderBundlePath, @"formatReader", details);
    BOOL manuallyLoadedVideoDecoder = SpliceKitBRAWLoadBundleAtPath(videoDecoderBundlePath, @"videoDecoder", details);
    details[@"manuallyLoadedFormatReaderBundle"] = @(manuallyLoadedFormatReader);
    details[@"manuallyLoadedVideoDecoderBundle"] = @(manuallyLoadedVideoDecoder);
    SpliceKitBRAWTrace([NSString stringWithFormat:@"[register] manual load reader=%@ decoder=%@",
                        manuallyLoadedFormatReader ? @"YES" : @"NO",
                        manuallyLoadedVideoDecoder ? @"YES" : @"NO"]);

    NSURL *formatReadersURL = SpliceKitBRAWDirectoryURL(@"FormatReaders");
    if (formatReadersURL) {
        SpliceKitBRAWTrace([NSString stringWithFormat:@"[register] MTRegisterPluginFormatReaderBundleDirectory begin %@", formatReadersURL.path ?: @"<nil>"]);
        MTRegisterPluginFormatReaderBundleDirectory((__bridge CFURLRef)formatReadersURL);
        details[@"registeredFormatReaderBundleDirectory"] = @YES;
        SpliceKitBRAWTrace(@"[register] MTRegisterPluginFormatReaderBundleDirectory end");
    } else {
        details[@"registeredFormatReaderBundleDirectory"] = @NO;
    }

    NSURL *codecsURL = SpliceKitBRAWDirectoryURL(@"Codecs");
    if (codecsURL) {
        SpliceKitBRAWTrace([NSString stringWithFormat:@"[register] VTRegisterVideoDecoderBundleDirectory begin %@", codecsURL.path ?: @"<nil>"]);
        VTRegisterVideoDecoderBundleDirectory((__bridge CFURLRef)codecsURL);
        details[@"registeredVideoDecoderBundleDirectory"] = @YES;
        SpliceKitBRAWTrace(@"[register] VTRegisterVideoDecoderBundleDirectory end");
    } else {
        details[@"registeredVideoDecoderBundleDirectory"] = @NO;
    }

    SpliceKitBRAWTrace(@"[register] MTRegisterProfessionalVideoWorkflowFormatReaders begin");
    MTRegisterProfessionalVideoWorkflowFormatReaders();
    details[@"registeredProfessionalFormatReaders"] = @YES;
    SpliceKitBRAWTrace(@"[register] MTRegisterProfessionalVideoWorkflowFormatReaders end");
    SpliceKitBRAWTrace(@"[register] VTRegisterProfessionalVideoWorkflowVideoDecoders begin");
    VTRegisterProfessionalVideoWorkflowVideoDecoders();
    details[@"registeredProfessionalVideoDecoders"] = @YES;
    SpliceKitBRAWTrace(@"[register] VTRegisterProfessionalVideoWorkflowVideoDecoders end");

    void *proCoreHandle = SpliceKitBRAWOpenProCoreHandle(details);
    if (!proCoreHandle) {
        return;
    }

    SpliceKitBRAWPCRegisterMediaExtensionFormatReadersFn registerMediaExtensionFormatReaders =
        (SpliceKitBRAWPCRegisterMediaExtensionFormatReadersFn)dlsym(
            proCoreHandle,
            "_Z49PCMediaPlugInsRegisterMediaExtensionFormatReadersv");
    details[@"proCoreRegisterMediaExtensionFormatReadersAvailable"] = @(registerMediaExtensionFormatReaders != NULL);
    if (registerMediaExtensionFormatReaders) {
        SpliceKitBRAWTrace(@"[register] ProCore media extension format reader registration begin");
        int64_t result = registerMediaExtensionFormatReaders();
        details[@"proCoreRegisterMediaExtensionFormatReadersResult"] = @(result);
        details[@"proCoreRegisterMediaExtensionFormatReadersCalled"] = @YES;
        SpliceKitBRAWTrace([NSString stringWithFormat:@"[register] ProCore media extension format reader registration end result=%lld", result]);
    }

    SpliceKitBRAWPCRegisterFormatReadersFromAppBundleFn registerFormatReadersFromAppBundle =
        (SpliceKitBRAWPCRegisterFormatReadersFromAppBundleFn)dlsym(
            proCoreHandle,
            "_Z48PCMediaPlugInsRegisterFormatReadersFromAppBundleb");
    details[@"proCoreRegisterFormatReadersFromAppBundleAvailable"] = @(registerFormatReadersFromAppBundle != NULL);
    if (registerFormatReadersFromAppBundle) {
        SpliceKitBRAWTrace(@"[register] ProCore format reader registration begin");
        int64_t result = registerFormatReadersFromAppBundle(true);
        details[@"proCoreRegisterFormatReadersFromAppBundleResult"] = @(result);
        details[@"proCoreRegisterFormatReadersFromAppBundleCalled"] = @YES;
        SpliceKitBRAWTrace([NSString stringWithFormat:@"[register] ProCore format reader registration end result=%lld", result]);
    }

    SpliceKitBRAWPCRegisterFormatReadersFromDirectoryFn registerFormatReadersFromDirectory =
        (SpliceKitBRAWPCRegisterFormatReadersFromDirectoryFn)dlsym(
            proCoreHandle,
            "_Z48PCMediaPlugInsRegisterFormatReadersFromDirectoryPK7__CFURLb");
    details[@"proCoreRegisterFormatReadersFromDirectoryAvailable"] = @(registerFormatReadersFromDirectory != NULL);
    if (registerFormatReadersFromDirectory && formatReadersURL) {
        SpliceKitBRAWTrace(@"[register] ProCore format reader directory registration begin");
        int64_t result = registerFormatReadersFromDirectory((__bridge CFURLRef)formatReadersURL, true);
        details[@"proCoreRegisterFormatReadersFromDirectoryResult"] = @(result);
        details[@"proCoreRegisterFormatReadersFromDirectoryCalled"] = @YES;
        SpliceKitBRAWTrace([NSString stringWithFormat:@"[register] ProCore format reader directory registration end result=%lld", result]);
    }

    SpliceKitBRAWPCRegisterVideoCodecsFromAppBundleFn registerVideoCodecsFromAppBundle =
        (SpliceKitBRAWPCRegisterVideoCodecsFromAppBundleFn)dlsym(
            proCoreHandle,
            "_Z46PCMediaPlugInsRegisterVideoCodecsFromAppBundlePP14__CFDictionary");
    details[@"proCoreRegisterVideoCodecsFromAppBundleAvailable"] = @(registerVideoCodecsFromAppBundle != NULL);
    if (registerVideoCodecsFromAppBundle) {
        CFDictionaryRef codecNames = NULL;
        SpliceKitBRAWTrace(@"[register] ProCore video codec registration begin");
        int64_t result = registerVideoCodecsFromAppBundle(&codecNames);
        details[@"proCoreRegisterVideoCodecsFromAppBundleResult"] = @(result);
        if (codecNames) {
            NSDictionary *codecMap = (__bridge NSDictionary *)codecNames;
            details[@"proCoreCodecNameMapCount"] = @([codecMap count]);
            CFRelease(codecNames);
        }
        details[@"proCoreRegisterVideoCodecsFromAppBundleCalled"] = @YES;
        SpliceKitBRAWTrace([NSString stringWithFormat:@"[register] ProCore video codec registration end result=%lld", result]);
    }

    SpliceKitBRAWPCRegisterVideoCodecsDirectoryFn registerVideoCodecsDirectory =
        (SpliceKitBRAWPCRegisterVideoCodecsDirectoryFn)dlsym(
            proCoreHandle,
            "_Z42PCMediaPlugInsRegisterVideoCodecsDirectoryPK7__CFURLbPP14__CFDictionary");
    details[@"proCoreRegisterVideoCodecsDirectoryAvailable"] = @(registerVideoCodecsDirectory != NULL);
    if (registerVideoCodecsDirectory && codecsURL) {
        CFDictionaryRef codecNames = NULL;
        SpliceKitBRAWTrace(@"[register] ProCore video codec directory registration begin");
        int64_t result = registerVideoCodecsDirectory((__bridge CFURLRef)codecsURL, true, &codecNames);
        details[@"proCoreRegisterVideoCodecsDirectoryResult"] = @(result);
        if (codecNames) {
            NSDictionary *codecMap = (__bridge NSDictionary *)codecNames;
            details[@"proCoreCodecDirectoryNameMapCount"] = @([codecMap count]);
            CFRelease(codecNames);
        }
        details[@"proCoreRegisterVideoCodecsDirectoryCalled"] = @YES;
        SpliceKitBRAWTrace([NSString stringWithFormat:@"[register] ProCore video codec directory registration end result=%lld", result]);
    }

    // This is the registration FCP itself uses for its built-in and third-party codecs
    // (including Afterburner ProRes). If the decoder is not registered through this
    // path, FFCodecAvailability's CoreMediaMovieReader_Query::decoderIsAvailable
    // check returns false, and FFSourceVideoFig reports codecMissing.
    SpliceKitBRAWPCRegisterVideoCodecBundleInProcessFn registerVideoCodecBundle =
        (SpliceKitBRAWPCRegisterVideoCodecBundleInProcessFn)dlsym(
            proCoreHandle,
            "_Z47PCMediaPlugInsRegisterVideoCodecBundleInProcessP10__CFBundlePP14__CFDictionary");
    details[@"proCoreRegisterVideoCodecBundleInProcessAvailable"] = @(registerVideoCodecBundle != NULL);
    if (registerVideoCodecBundle && videoDecoderBundlePath.length > 0) {
        NSURL *bundleURL = [NSURL fileURLWithPath:videoDecoderBundlePath isDirectory:YES];
        CFBundleRef bundle = CFBundleCreate(kCFAllocatorDefault, (CFURLRef)bundleURL);
        if (bundle) {
            CFDictionaryRef codecNames = NULL;
            SpliceKitBRAWTrace([NSString stringWithFormat:@"[register] ProCore register decoder bundle begin path=%@", videoDecoderBundlePath]);
            int64_t result = registerVideoCodecBundle(bundle, &codecNames);
            details[@"proCoreRegisterVideoCodecBundleInProcessResult"] = @(result);
            if (codecNames) {
                NSDictionary *codecMap = (__bridge NSDictionary *)codecNames;
                details[@"proCoreCodecBundleInProcessNameMapCount"] = @([codecMap count]);
                CFRelease(codecNames);
            }
            details[@"proCoreRegisterVideoCodecBundleInProcessCalled"] = @YES;
            SpliceKitBRAWTrace([NSString stringWithFormat:@"[register] ProCore register decoder bundle end result=%lld", result]);
            CFRelease(bundle);
        } else {
            details[@"proCoreRegisterVideoCodecBundleInProcessError"] = @"CFBundleCreate returned nil";
            SpliceKitBRAWTrace(@"[register] ProCore register decoder bundle CFBundleCreate failed");
        }
    }

    SpliceKitBRAWPCRegisterVideoCodecsFromPlugInsDirFn registerVideoCodecsFromPlugInsDir =
        (SpliceKitBRAWPCRegisterVideoCodecsFromPlugInsDirFn)dlsym(
            proCoreHandle,
            "_Z47PCMediaPlugInsRegisterVideoCodecsFromPlugInsDirPK7__CFURLPP14__CFDictionary");
    details[@"proCoreRegisterVideoCodecsFromPlugInsDirAvailable"] = @(registerVideoCodecsFromPlugInsDir != NULL);
    if (registerVideoCodecsFromPlugInsDir && codecsURL) {
        CFDictionaryRef codecNames = NULL;
        SpliceKitBRAWTrace(@"[register] ProCore register codecs from plugins dir begin");
        int64_t result = registerVideoCodecsFromPlugInsDir((__bridge CFURLRef)codecsURL, &codecNames);
        details[@"proCoreRegisterVideoCodecsFromPlugInsDirResult"] = @(result);
        if (codecNames) {
            NSDictionary *codecMap = (__bridge NSDictionary *)codecNames;
            details[@"proCoreCodecsFromPlugInsDirNameMapCount"] = @([codecMap count]);
            CFRelease(codecNames);
        }
        details[@"proCoreRegisterVideoCodecsFromPlugInsDirCalled"] = @YES;
        SpliceKitBRAWTrace([NSString stringWithFormat:@"[register] ProCore register codecs from plugins dir end result=%lld", result]);
    }

    dlclose(proCoreHandle);
}

static id SpliceKitBRAWProviderFigExtensions(id self, SEL _cmd) {
    id base = sSpliceKitBRAWOriginalProviderFigExtensionsIMP
        ? ((id (*)(id, SEL))sSpliceKitBRAWOriginalProviderFigExtensionsIMP)(self, _cmd)
        : nil;
    return [SpliceKitBRAWUniqueStrings(base, @[@"braw"]) copy];
}

static id SpliceKitBRAWProviderFigUTIs(id self, SEL _cmd) {
    id base = sSpliceKitBRAWOriginalProviderFigUTIsIMP
        ? ((id (*)(id, SEL))sSpliceKitBRAWOriginalProviderFigUTIsIMP)(self, _cmd)
        : nil;
    // Advertise both BRAW UTIs so the provider-level recognition matches what
    // the UTType conformance hook (at line ~633) already claims. Without braw2
    // here, clips authored on newer Blackmagic cameras can hit the provider
    // lookup as "unknown" even though downstream UTType checks accept them.
    return [SpliceKitBRAWUniqueStrings(base, @[kSpliceKitBRAWUTI, kSpliceKitBRAW2UTI]) copy];
}

static BOOL SpliceKitBRAWRegisterProviderShimPhase(NSString *phase, NSMutableDictionary *details) {
    if ([phase isEqualToString:@"noop"]) {
        details[@"phase"] = @"noop";
        return YES;
    }

    Class providerFigClass = objc_getClass("FFProviderFig");
    details[@"phase"] = phase ?: @"both";
    details[@"providerFigClass"] = providerFigClass ? NSStringFromClass(providerFigClass) : (id)[NSNull null];
    if (!providerFigClass) {
        return NO;
    }

    if ([phase isEqualToString:@"lookup"]) {
        return YES;
    }

    @try {
        Method extensionsMethod = class_getClassMethod(providerFigClass, @selector(extensions));
        Method utisMethod = class_getClassMethod(providerFigClass, @selector(utis));
        details[@"hasExtensionsMethod"] = @(extensionsMethod != NULL);
        details[@"hasUTIsMethod"] = @(utisMethod != NULL);

        if ([phase isEqualToString:@"methods"]) {
            return extensionsMethod && utisMethod;
        }

        if (!extensionsMethod || !utisMethod) {
            return NO;
        }

        BOOL shouldSwizzleExtensions = [phase isEqualToString:@"extensions"] || [phase isEqualToString:@"both"];
        BOOL shouldSwizzleUTIs = [phase isEqualToString:@"utis"] || [phase isEqualToString:@"both"];

        if (shouldSwizzleExtensions && !sSpliceKitBRAWOriginalProviderFigExtensionsIMP) {
            sSpliceKitBRAWOriginalProviderFigExtensionsIMP = method_setImplementation(
                extensionsMethod,
                (IMP)SpliceKitBRAWProviderFigExtensions);
        }
        if (shouldSwizzleUTIs && !sSpliceKitBRAWOriginalProviderFigUTIsIMP) {
            sSpliceKitBRAWOriginalProviderFigUTIsIMP = method_setImplementation(
                utisMethod,
                (IMP)SpliceKitBRAWProviderFigUTIs);
        }

        details[@"extensionsSwizzled"] = @(sSpliceKitBRAWOriginalProviderFigExtensionsIMP != NULL);
        details[@"utisSwizzled"] = @(sSpliceKitBRAWOriginalProviderFigUTIsIMP != NULL);
        return YES;
    } @catch (NSException *exception) {
        details[@"exceptionName"] = exception.name ?: @"";
        details[@"exceptionReason"] = exception.reason ?: @"";
        return NO;
    }
}

#pragma mark - UTI conformance + AVURLAsset MIME hooks

// .braw files end up with UTI com.blackmagic-design.braw-movie declared by Blackmagic
// RAW Player.app with conformsTo = public.data only. That makes AVFoundation treat
// them as non-media and never consult our MediaToolbox format reader. We lie about
// conformance and inject an MIME hint on AVURLAsset so MediaToolbox's extension-based
// matching wins.

static BOOL SpliceKitBRAWIsBRAWUTIString(NSString *identifier) {
    if (identifier.length == 0) return NO;
    return [identifier isEqualToString:@"com.blackmagic-design.braw-movie"] ||
           [identifier isEqualToString:@"com.blackmagic-design.braw2-movie"];
}

static BOOL SpliceKitBRAWShouldConformBRAWTo(NSString *targetIdentifier) {
    if (targetIdentifier.length == 0) return NO;
    // Only extend conformance to the media-related types that AVFoundation gates on.
    // We intentionally do NOT lie for arbitrary types to minimize blast radius.
    return [targetIdentifier isEqualToString:@"public.movie"] ||
           [targetIdentifier isEqualToString:@"public.audiovisual-content"] ||
           [targetIdentifier isEqualToString:@"public.video"] ||
           [targetIdentifier isEqualToString:@"public.content"];
}

static BOOL SpliceKitBRAWIsBRAWExtension(NSString *ext) {
    if (ext.length == 0) return NO;
    return [ext caseInsensitiveCompare:@"braw"] == NSOrderedSame;
}

// MARK: - fourcc shim (patch unsupported BRAW fourccs so AVFoundation exposes the video track)

// AVFoundation's MOV parser only exposes a video track if it recognizes the
// sample-description fourcc as a known video codec. braw/brxq/brst slip through;
// brvn and other newer variants get silently dropped. To work around this we
// APFS-clone the .braw file, patch just the 4-byte fourcc in the video stsd
// from the unknown code to 'brxq', and hand AVAsset the clone. Decode still
// runs against the original file via our host SDK path (the clone→original map
// ensures the VT decoder resolves to the real path).

static NSMutableDictionary<NSString *, NSString *> *SpliceKitBRAWShimCloneToOriginal() {
    static NSMutableDictionary *map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ map = [NSMutableDictionary dictionary]; });
    return map;
}

static NSString *SpliceKitBRAWShimDirectory() {
    static NSString *dir;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
        NSString *base = paths.firstObject ?: NSTemporaryDirectory();
        dir = [[base stringByAppendingPathComponent:@"SpliceKitBRAWShims"] copy];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:nil];
    });
    return dir;
}

// Read a 32-bit BE value at (buf+off) with bounds check.
static inline uint32_t SpliceKitBRAWReadU32BE(const uint8_t *buf, size_t len, size_t off) {
    if (off + 4 > len) return 0;
    return ((uint32_t)buf[off] << 24) | ((uint32_t)buf[off+1] << 16)
         | ((uint32_t)buf[off+2] << 8)  | (uint32_t)buf[off+3];
}

// Walk moov and collect offsets (within the full buffer) of every trak atom
// whose mdia/hdlr handler_type is 'meta'. Returns the list via out vec.
// Used to strip metadata tracks by rewriting them to 'skip' (AVFoundation
// ignores any atom whose fourcc it doesn't recognize).
static void SpliceKitBRAWFindMetaTrakOffsets(const uint8_t *moovBuf, size_t moovLen, std::vector<size_t> &outOffsets) {
    if (moovLen < 16) return;
    size_t p = 8;
    while (p + 8 <= moovLen) {
        uint32_t atomSize = SpliceKitBRAWReadU32BE(moovBuf, moovLen, p);
        if (atomSize < 8 || p + atomSize > moovLen) return;
        if (moovBuf[p+4] == 't' && moovBuf[p+5] == 'r' && moovBuf[p+6] == 'a' && moovBuf[p+7] == 'k') {
            size_t trakEnd = p + atomSize;
            size_t tp = p + 8;
            while (tp + 8 <= trakEnd) {
                uint32_t tsz = SpliceKitBRAWReadU32BE(moovBuf, moovLen, tp);
                if (tsz < 8 || tp + tsz > trakEnd) break;
                if (moovBuf[tp+4] == 'm' && moovBuf[tp+5] == 'd' && moovBuf[tp+6] == 'i' && moovBuf[tp+7] == 'a') {
                    size_t mp = tp + 8;
                    size_t mdiaEnd = tp + tsz;
                    while (mp + 8 <= mdiaEnd) {
                        uint32_t msz = SpliceKitBRAWReadU32BE(moovBuf, moovLen, mp);
                        if (msz < 8 || mp + msz > mdiaEnd) break;
                        if (moovBuf[mp+4] == 'h' && moovBuf[mp+5] == 'd' && moovBuf[mp+6] == 'l' && moovBuf[mp+7] == 'r') {
                            if (mp + 20 <= mdiaEnd &&
                                moovBuf[mp+16] == 'm' && moovBuf[mp+17] == 'e' &&
                                moovBuf[mp+18] == 't' && moovBuf[mp+19] == 'a') {
                                outOffsets.push_back(p); // offset of trak fourcc header
                            }
                        }
                        mp += msz;
                    }
                }
                tp += tsz;
            }
        }
        p += atomSize;
    }
}

// Walk moov payload to find the offset (within the full buffer) of the 4-byte
// fourcc field inside the FIRST video trak's stsd entry. Returns 0 on failure.
static size_t SpliceKitBRAWFindVideoFourCCOffset(const uint8_t *moovBuf, size_t moovLen, uint32_t *outFourCC) {
    // moov header: 8 bytes (size + 'moov')
    if (moovLen < 16) return 0;
    // iterate moov children
    size_t p = 8; // skip moov size+type
    while (p + 8 <= moovLen) {
        uint32_t atomSize = SpliceKitBRAWReadU32BE(moovBuf, moovLen, p);
        if (atomSize < 8 || p + atomSize > moovLen) return 0;
        if (moovBuf[p+4] == 't' && moovBuf[p+5] == 'r' && moovBuf[p+6] == 'a' && moovBuf[p+7] == 'k') {
            // Descend into trak → mdia → minf → stbl → stsd
            // First, check mdia/hdlr for handler_type == 'vide'
            size_t trakEnd = p + atomSize;
            size_t tp = p + 8;
            BOOL isVideo = NO;
            size_t stsdFourCCOffset = 0;
            while (tp + 8 <= trakEnd) {
                uint32_t tsz = SpliceKitBRAWReadU32BE(moovBuf, moovLen, tp);
                if (tsz < 8 || tp + tsz > trakEnd) break;
                if (moovBuf[tp+4] == 'm' && moovBuf[tp+5] == 'd' && moovBuf[tp+6] == 'i' && moovBuf[tp+7] == 'a') {
                    // iterate mdia children
                    size_t mp = tp + 8;
                    size_t mdiaEnd = tp + tsz;
                    while (mp + 8 <= mdiaEnd) {
                        uint32_t msz = SpliceKitBRAWReadU32BE(moovBuf, moovLen, mp);
                        if (msz < 8 || mp + msz > mdiaEnd) break;
                        if (moovBuf[mp+4] == 'h' && moovBuf[mp+5] == 'd' && moovBuf[mp+6] == 'l' && moovBuf[mp+7] == 'r') {
                            // handler_type at offset 8(hdr)+4(vflags)+4(pre_defined) = +16
                            if (mp + 20 <= mdiaEnd &&
                                moovBuf[mp+16] == 'v' && moovBuf[mp+17] == 'i' &&
                                moovBuf[mp+18] == 'd' && moovBuf[mp+19] == 'e') {
                                isVideo = YES;
                            }
                        } else if (moovBuf[mp+4] == 'm' && moovBuf[mp+5] == 'i' && moovBuf[mp+6] == 'n' && moovBuf[mp+7] == 'f') {
                            // iterate minf children to find stbl → stsd
                            size_t np = mp + 8;
                            size_t minfEnd = mp + msz;
                            while (np + 8 <= minfEnd) {
                                uint32_t nsz = SpliceKitBRAWReadU32BE(moovBuf, moovLen, np);
                                if (nsz < 8 || np + nsz > minfEnd) break;
                                if (moovBuf[np+4] == 's' && moovBuf[np+5] == 't' && moovBuf[np+6] == 'b' && moovBuf[np+7] == 'l') {
                                    // iterate stbl children for stsd
                                    size_t sp = np + 8;
                                    size_t stblEnd = np + nsz;
                                    while (sp + 8 <= stblEnd) {
                                        uint32_t ssz = SpliceKitBRAWReadU32BE(moovBuf, moovLen, sp);
                                        if (ssz < 8 || sp + ssz > stblEnd) break;
                                        if (moovBuf[sp+4] == 's' && moovBuf[sp+5] == 't' && moovBuf[sp+6] == 's' && moovBuf[sp+7] == 'd') {
                                            // stsd body: 4 version+flags, 4 entry_count, then entries.
                                            // first entry: 4 size, 4 fourcc
                                            size_t entryOff = sp + 8 + 4 + 4; // stsd_size+stsd_type + vflags + entry_count
                                            if (entryOff + 8 <= sp + ssz) {
                                                stsdFourCCOffset = entryOff + 4; // skip entry size → fourcc
                                            }
                                            break;
                                        }
                                        sp += ssz;
                                    }
                                }
                                np += nsz;
                            }
                        }
                        mp += msz;
                    }
                }
                tp += tsz;
            }
            if (isVideo && stsdFourCCOffset != 0) {
                if (outFourCC) {
                    *outFourCC = SpliceKitBRAWReadU32BE(moovBuf, moovLen, stsdFourCCOffset);
                }
                return stsdFourCCOffset;
            }
        }
        p += atomSize;
    }
    return 0;
}

// Like SpliceKitBRAWFindVideoFourCCOffset but returns offsets for EVERY video
// trak's stsd first-entry fourcc (not just the first). Used by the shim to
// patch both eye traks of a stereoscopic BRAW in one pass.
static void SpliceKitBRAWFindAllVideoFourCCOffsets(const uint8_t *moovBuf, size_t moovLen, std::vector<size_t> &outOffsets) {
    if (moovLen < 16) return;
    size_t p = 8;
    while (p + 8 <= moovLen) {
        uint32_t atomSize = SpliceKitBRAWReadU32BE(moovBuf, moovLen, p);
        if (atomSize < 8 || p + atomSize > moovLen) return;
        if (moovBuf[p+4] == 't' && moovBuf[p+5] == 'r' && moovBuf[p+6] == 'a' && moovBuf[p+7] == 'k') {
            size_t trakEnd = p + atomSize;
            size_t tp = p + 8;
            BOOL isVideo = NO;
            size_t stsdFourCCOffset = 0;
            while (tp + 8 <= trakEnd) {
                uint32_t tsz = SpliceKitBRAWReadU32BE(moovBuf, moovLen, tp);
                if (tsz < 8 || tp + tsz > trakEnd) break;
                if (moovBuf[tp+4] == 'm' && moovBuf[tp+5] == 'd' && moovBuf[tp+6] == 'i' && moovBuf[tp+7] == 'a') {
                    size_t mp = tp + 8;
                    size_t mdiaEnd = tp + tsz;
                    while (mp + 8 <= mdiaEnd) {
                        uint32_t msz = SpliceKitBRAWReadU32BE(moovBuf, moovLen, mp);
                        if (msz < 8 || mp + msz > mdiaEnd) break;
                        if (moovBuf[mp+4] == 'h' && moovBuf[mp+5] == 'd' && moovBuf[mp+6] == 'l' && moovBuf[mp+7] == 'r') {
                            if (mp + 20 <= mdiaEnd &&
                                moovBuf[mp+16] == 'v' && moovBuf[mp+17] == 'i' &&
                                moovBuf[mp+18] == 'd' && moovBuf[mp+19] == 'e') {
                                isVideo = YES;
                            }
                        } else if (moovBuf[mp+4] == 'm' && moovBuf[mp+5] == 'i' && moovBuf[mp+6] == 'n' && moovBuf[mp+7] == 'f') {
                            size_t np = mp + 8;
                            size_t minfEnd = mp + msz;
                            while (np + 8 <= minfEnd) {
                                uint32_t nsz = SpliceKitBRAWReadU32BE(moovBuf, moovLen, np);
                                if (nsz < 8 || np + nsz > minfEnd) break;
                                if (moovBuf[np+4] == 's' && moovBuf[np+5] == 't' && moovBuf[np+6] == 'b' && moovBuf[np+7] == 'l') {
                                    size_t sp = np + 8;
                                    size_t stblEnd = np + nsz;
                                    while (sp + 8 <= stblEnd) {
                                        uint32_t ssz = SpliceKitBRAWReadU32BE(moovBuf, moovLen, sp);
                                        if (ssz < 8 || sp + ssz > stblEnd) break;
                                        if (moovBuf[sp+4] == 's' && moovBuf[sp+5] == 't' && moovBuf[sp+6] == 's' && moovBuf[sp+7] == 'd') {
                                            size_t entryOff = sp + 8 + 4 + 4;
                                            if (entryOff + 8 <= sp + ssz) {
                                                stsdFourCCOffset = entryOff + 4;
                                            }
                                            break;
                                        }
                                        sp += ssz;
                                    }
                                }
                                np += nsz;
                            }
                        }
                        mp += msz;
                    }
                }
                tp += tsz;
            }
            if (isVideo && stsdFourCCOffset != 0) {
                outOffsets.push_back(stsdFourCCOffset);
            }
        }
        p += atomSize;
    }
}

// Forward decl — defined just below. The file-offset wrappers above and
// below use it before it's defined in source order.
static uint64_t SpliceKitBRAWReadMoovBuffer(NSString *path, uint8_t **outBuf, size_t *outBufLen);

// File-offset wrapper returning absolute positions of each video trak's stsd
// fourcc byte. Caller rewrites those to 'brxq' (and adjusts the surrounding
// entry). Parallels SpliceKitBRAWFindFileFourCCOffset but for all video traks.
static void SpliceKitBRAWFindAllVideoFourCCFileOffsets(NSString *path, std::vector<uint64_t> &outOffsets) {
    uint8_t *buf = nullptr;
    size_t bufLen = 0;
    uint64_t moovFileOffset = SpliceKitBRAWReadMoovBuffer(path, &buf, &bufLen);
    if (!buf) return;
    std::vector<size_t> rel;
    SpliceKitBRAWFindAllVideoFourCCOffsets(buf, bufLen, rel);
    for (size_t r : rel) outOffsets.push_back(moovFileOffset + (uint64_t)r);
    free(buf);
}

// Read the full moov buffer from the .braw file; caller frees the buffer via
// free(). On success sets *outBufLen and returns the absolute file offset of
// the moov atom. Returns 0 on failure.
static uint64_t SpliceKitBRAWReadMoovBuffer(NSString *path, uint8_t **outBuf, size_t *outBufLen) {
    if (outBuf) *outBuf = nullptr;
    if (outBufLen) *outBufLen = 0;

    FILE *f = fopen(path.UTF8String, "rb");
    if (!f) return 0;
    uint64_t offset = 0;
    uint64_t moovFileOffset = 0;
    uint64_t moovSize = 0;
    while (1) {
        uint8_t hdr[16];
        if (fread(hdr, 1, 8, f) != 8) break;
        uint64_t atomSize = ((uint64_t)hdr[0] << 24) | ((uint64_t)hdr[1] << 16) | ((uint64_t)hdr[2] << 8) | hdr[3];
        uint32_t fourcc = ((uint32_t)hdr[4] << 24) | ((uint32_t)hdr[5] << 16) | ((uint32_t)hdr[6] << 8) | hdr[7];
        size_t hdrLen = 8;
        if (atomSize == 1) {
            if (fread(hdr + 8, 1, 8, f) != 8) break;
            atomSize = ((uint64_t)hdr[8] << 56) | ((uint64_t)hdr[9] << 48) | ((uint64_t)hdr[10] << 40) | ((uint64_t)hdr[11] << 32)
                     | ((uint64_t)hdr[12] << 24) | ((uint64_t)hdr[13] << 16) | ((uint64_t)hdr[14] << 8) | hdr[15];
            hdrLen = 16;
        }
        if (atomSize < hdrLen) break;
        if (fourcc == 'moov') {
            moovFileOffset = offset;
            moovSize = atomSize;
            break;
        }
        if (fseeko(f, (off_t)(offset + atomSize), SEEK_SET) != 0) break;
        offset += atomSize;
    }
    if (moovSize == 0 || moovSize > 32 * 1024 * 1024) { fclose(f); return 0; }

    uint8_t *buf = (uint8_t *)malloc((size_t)moovSize);
    if (!buf) { fclose(f); return 0; }
    if (fseeko(f, (off_t)moovFileOffset, SEEK_SET) != 0 || fread(buf, 1, (size_t)moovSize, f) != moovSize) {
        free(buf); fclose(f); return 0;
    }
    fclose(f);

    *outBuf = buf;
    *outBufLen = (size_t)moovSize;
    return moovFileOffset;
}

// Open the .braw file, locate the moov atom, read it, find the fourcc offset.
// Returns the absolute file offset of the video fourcc on success, else 0.
// Populates outFourCC with the existing fourcc.
static uint64_t SpliceKitBRAWFindFileFourCCOffset(NSString *path, uint32_t *outFourCC) {
    if (outFourCC) *outFourCC = 0;
    uint8_t *buf = nullptr;
    size_t bufLen = 0;
    uint64_t moovFileOffset = SpliceKitBRAWReadMoovBuffer(path, &buf, &bufLen);
    if (!buf) return 0;
    size_t relOff = SpliceKitBRAWFindVideoFourCCOffset(buf, bufLen, outFourCC);
    free(buf);
    if (relOff == 0) return 0;
    return moovFileOffset + (uint64_t)relOff;
}

// Returns absolute file offsets of trak-atom FOURCC bytes for every 'meta'
// handler track in the file's moov. Caller can rewrite these to 'skip' to
// make AVFoundation ignore the track entirely.
// outOffsets is populated with offsets pointing at the 4-byte 'trak' fourcc
// field (i.e. the byte AFTER the size field).
static void SpliceKitBRAWFindMetaTrakFileOffsets(NSString *path, std::vector<uint64_t> &outOffsets) {
    uint8_t *buf = nullptr;
    size_t bufLen = 0;
    uint64_t moovFileOffset = SpliceKitBRAWReadMoovBuffer(path, &buf, &bufLen);
    if (!buf) return;
    std::vector<size_t> rel;
    SpliceKitBRAWFindMetaTrakOffsets(buf, bufLen, rel);
    for (size_t r : rel) {
        // r is offset of the atom header (size field); fourcc lives at +4
        outOffsets.push_back(moovFileOffset + (uint64_t)r + 4);
    }
    free(buf);
}

// Walk moov and collect offsets (within the full buffer) of every 'trak' atom
// whose mdia/hdlr handler_type is 'vide', SKIPPING the first one. DJI and URSA
// stereoscopic BRAW files carry two video traks (left + right eye). AVFoundation
// plus FCP then synthesize a side-by-side stereo canvas twice the per-eye width,
// but only one eye ever gets decoded through our VT path — the other half of
// the render target stays at its initialized (green) color. Stripping the extra
// video traks makes FCP treat the clip as monoscopic. Returns offsets pointing
// at the atom header (size field).
static void SpliceKitBRAWFindExtraVideoTrakOffsets(const uint8_t *moovBuf, size_t moovLen, std::vector<size_t> &outOffsets) {
    if (moovLen < 16) return;
    size_t p = 8;
    bool sawVideo = false;
    while (p + 8 <= moovLen) {
        uint32_t atomSize = SpliceKitBRAWReadU32BE(moovBuf, moovLen, p);
        if (atomSize < 8 || p + atomSize > moovLen) return;
        if (moovBuf[p+4] == 't' && moovBuf[p+5] == 'r' && moovBuf[p+6] == 'a' && moovBuf[p+7] == 'k') {
            size_t trakEnd = p + atomSize;
            size_t tp = p + 8;
            bool isVideo = false;
            while (tp + 8 <= trakEnd) {
                uint32_t tsz = SpliceKitBRAWReadU32BE(moovBuf, moovLen, tp);
                if (tsz < 8 || tp + tsz > trakEnd) break;
                if (moovBuf[tp+4] == 'm' && moovBuf[tp+5] == 'd' && moovBuf[tp+6] == 'i' && moovBuf[tp+7] == 'a') {
                    size_t mp = tp + 8;
                    size_t mdiaEnd = tp + tsz;
                    while (mp + 8 <= mdiaEnd) {
                        uint32_t msz = SpliceKitBRAWReadU32BE(moovBuf, moovLen, mp);
                        if (msz < 8 || mp + msz > mdiaEnd) break;
                        if (moovBuf[mp+4] == 'h' && moovBuf[mp+5] == 'd' && moovBuf[mp+6] == 'l' && moovBuf[mp+7] == 'r') {
                            if (mp + 20 <= mdiaEnd &&
                                moovBuf[mp+16] == 'v' && moovBuf[mp+17] == 'i' &&
                                moovBuf[mp+18] == 'd' && moovBuf[mp+19] == 'e') {
                                isVideo = true;
                            }
                        }
                        mp += msz;
                    }
                }
                tp += tsz;
            }
            if (isVideo) {
                if (sawVideo) {
                    outOffsets.push_back(p);
                } else {
                    sawVideo = true;
                }
            }
        }
        p += atomSize;
    }
}

// Walk moov and collect offsets of stereoscopic-signaling atoms that live as
// direct children of a 'trak' atom. In the file we've seen these are 'vexu'
// (Apple video-extension — the multiview/stereoscopic 3D marker) and 'hfov'
// (horizontal field-of-view metadata paired with vexu). Stripping these so
// FCP stops treating the remaining video trak as one eye of a stereo pair.
// Also strips 'tref' — track references that might dangle after extra video
// traks are skipped. Returns offsets pointing at the atom header (size field).
static void SpliceKitBRAWFindStereoAtomOffsets(const uint8_t *moovBuf, size_t moovLen, std::vector<size_t> &outOffsets) {
    if (moovLen < 16) return;
    size_t p = 8;
    while (p + 8 <= moovLen) {
        uint32_t atomSize = SpliceKitBRAWReadU32BE(moovBuf, moovLen, p);
        if (atomSize < 8 || p + atomSize > moovLen) return;
        if (moovBuf[p+4] == 't' && moovBuf[p+5] == 'r' && moovBuf[p+6] == 'a' && moovBuf[p+7] == 'k') {
            size_t trakEnd = p + atomSize;
            size_t tp = p + 8;
            while (tp + 8 <= trakEnd) {
                uint32_t tsz = SpliceKitBRAWReadU32BE(moovBuf, moovLen, tp);
                if (tsz < 8 || tp + tsz > trakEnd) break;
                const uint8_t *fcc = moovBuf + tp + 4;
                if ((fcc[0]=='v' && fcc[1]=='e' && fcc[2]=='x' && fcc[3]=='u') ||
                    (fcc[0]=='h' && fcc[1]=='f' && fcc[2]=='o' && fcc[3]=='v') ||
                    (fcc[0]=='t' && fcc[1]=='r' && fcc[2]=='e' && fcc[3]=='f')) {
                    outOffsets.push_back(tp);
                }
                tp += tsz;
            }
        }
        p += atomSize;
    }
}

// Return the absolute file offset of the first video trak's tkhd
// display_width field (Fixed16.16, followed by display_height). 0 on failure.
// Use this to keep tkhd aligned with the stsd dims we rewrite — FCP and
// AVFoundation sometimes reconcile per-clip canvas size from tkhd, so if
// stsd says 5120×2136 but tkhd still says 5120×4272 the viewer can still
// end up stretched.
static uint64_t SpliceKitBRAWFindFirstVideoTkhdDisplaySizeFileOffset(NSString *path) {
    uint8_t *buf = nullptr;
    size_t bufLen = 0;
    uint64_t moovFileOffset = SpliceKitBRAWReadMoovBuffer(path, &buf, &bufLen);
    if (!buf) return 0;
    if (bufLen < 16) { free(buf); return 0; }
    size_t p = 8;
    uint64_t out = 0;
    while (p + 8 <= bufLen) {
        uint32_t atomSize = SpliceKitBRAWReadU32BE(buf, bufLen, p);
        if (atomSize < 8 || p + atomSize > bufLen) break;
        if (buf[p+4] == 't' && buf[p+5] == 'r' && buf[p+6] == 'a' && buf[p+7] == 'k') {
            size_t trakEnd = p + atomSize;
            size_t tp = p + 8;
            size_t tkhdBodyOff = 0;
            uint32_t tkhdBodyLen = 0;
            BOOL isVideo = NO;
            while (tp + 8 <= trakEnd) {
                uint32_t tsz = SpliceKitBRAWReadU32BE(buf, bufLen, tp);
                if (tsz < 8 || tp + tsz > trakEnd) break;
                if (buf[tp+4] == 't' && buf[tp+5] == 'k' && buf[tp+6] == 'h' && buf[tp+7] == 'd') {
                    tkhdBodyOff = tp + 8;
                    tkhdBodyLen = tsz - 8;
                } else if (buf[tp+4] == 'm' && buf[tp+5] == 'd' && buf[tp+6] == 'i' && buf[tp+7] == 'a') {
                    size_t mp = tp + 8;
                    size_t mdiaEnd = tp + tsz;
                    while (mp + 8 <= mdiaEnd) {
                        uint32_t msz = SpliceKitBRAWReadU32BE(buf, bufLen, mp);
                        if (msz < 8 || mp + msz > mdiaEnd) break;
                        if (buf[mp+4] == 'h' && buf[mp+5] == 'd' && buf[mp+6] == 'l' && buf[mp+7] == 'r' &&
                            mp + 20 <= mdiaEnd &&
                            buf[mp+16] == 'v' && buf[mp+17] == 'i' &&
                            buf[mp+18] == 'd' && buf[mp+19] == 'e') {
                            isVideo = YES;
                        }
                        mp += msz;
                    }
                }
                tp += tsz;
            }
            if (isVideo && tkhdBodyOff && tkhdBodyLen >= 84) {
                uint8_t ver = buf[tkhdBodyOff];
                // v0: flags(4) ctime(4) mtime(4) track_id(4) reserved(4) dur(4)
                //     reserved(8) layer(2) altgrp(2) vol(2) reserved(2) matrix(36)
                //     -> w(4) h(4)
                // v1: flags(4) ctime(8) mtime(8) track_id(4) reserved(4) dur(8)
                //     reserved(8) layer(2) altgrp(2) vol(2) reserved(2) matrix(36)
                //     -> w(4) h(4)
                size_t off = 0;
                if (ver == 0 && tkhdBodyLen >= 84)       off = 4+4+4+4+4+4+8+2+2+2+2+36;
                else if (ver == 1 && tkhdBodyLen >= 96)  off = 4+8+8+4+4+8+8+2+2+2+2+36;
                if (off > 0 && off + 8 <= tkhdBodyLen) {
                    out = moovFileOffset + (uint64_t)(tkhdBodyOff + off);
                    break;
                }
            }
        }
        p += atomSize;
    }
    free(buf);
    return out;
}

// File-offset wrappers for the two stereo-signal rewriters, matching the
// +4 (fourcc field) convention used by SpliceKitBRAWFindMetaTrakFileOffsets.
static void SpliceKitBRAWFindExtraVideoTrakFileOffsets(NSString *path, std::vector<uint64_t> &outOffsets) {
    uint8_t *buf = nullptr;
    size_t bufLen = 0;
    uint64_t moovFileOffset = SpliceKitBRAWReadMoovBuffer(path, &buf, &bufLen);
    if (!buf) return;
    std::vector<size_t> rel;
    SpliceKitBRAWFindExtraVideoTrakOffsets(buf, bufLen, rel);
    for (size_t r : rel) {
        outOffsets.push_back(moovFileOffset + (uint64_t)r + 4);
    }
    free(buf);
}

static void SpliceKitBRAWFindStereoAtomFileOffsets(NSString *path, std::vector<uint64_t> &outOffsets) {
    uint8_t *buf = nullptr;
    size_t bufLen = 0;
    uint64_t moovFileOffset = SpliceKitBRAWReadMoovBuffer(path, &buf, &bufLen);
    if (!buf) return;
    std::vector<size_t> rel;
    SpliceKitBRAWFindStereoAtomOffsets(buf, bufLen, rel);
    for (size_t r : rel) {
        outOffsets.push_back(moovFileOffset + (uint64_t)r + 4);
    }
    free(buf);
}

// Apple GPU max texture dimension. BRAW files above this per-axis (URSA Cine
// Immersive @ 17520x8040, for example) can't be wrapped as a Metal texture
// directly — CVMetalTextureCacheCreateTextureFromImage returns
// kCVReturnPixelBufferNotMetalCompatible (-6684). To work around this we
// pick a smaller SDK resolution scale and write the downscaled dims into
// the shim's stsd so FCP allocates a Metal-compatible destination buffer.
static const uint32_t kSpliceKitBRAWMaxMetalTextureDim = 16384;

// original-path → (scale, width, height) picked at shim-creation time. The
// decoder consults this to request the same SDK scale the shim advertised,
// so source dims equal destination dims in the Metal blit.
static NSMutableDictionary<NSString *, NSArray<NSNumber *> *> *sSpliceKitBRAWDownscaleMap = nil;
static std::mutex sSpliceKitBRAWDownscaleMapMutex;

static void SpliceKitBRAWRecordPathScale(NSString *path,
                                         BlackmagicRawResolutionScale scale,
                                         uint32_t w, uint32_t h) {
    if (path.length == 0) return;
    std::lock_guard<std::mutex> lock(sSpliceKitBRAWDownscaleMapMutex);
    if (!sSpliceKitBRAWDownscaleMap) sSpliceKitBRAWDownscaleMap = [NSMutableDictionary new];
    sSpliceKitBRAWDownscaleMap[path] = @[@((int)scale), @(w), @(h)];
}

static BOOL SpliceKitBRAWLookupPathScale(NSString *path,
                                          BlackmagicRawResolutionScale *outScale,
                                          uint32_t *outW, uint32_t *outH) {
    if (path.length == 0) return NO;
    std::lock_guard<std::mutex> lock(sSpliceKitBRAWDownscaleMapMutex);
    NSArray<NSNumber *> *entry = sSpliceKitBRAWDownscaleMap[path];
    if (!entry || entry.count != 3) return NO;
    if (outScale) *outScale = (BlackmagicRawResolutionScale)entry[0].intValue;
    if (outW) *outW = entry[1].unsignedIntValue;
    if (outH) *outH = entry[2].unsignedIntValue;
    return YES;
}

// Forward decl — implementation lives after SpliceKitBRAWHostClipEntry and
// SpliceKitBRAWRunDecodeJob are defined further down. The shim path
// (SpliceKitBRAWEnsureFourCCShim, below) uses it to probe SDK dims at a
// given scale.
static BOOL SpliceKitBRAWProbeScaledDimsForPath(NSString *path,
                                                BlackmagicRawResolutionScale scale,
                                                uint32_t *outW, uint32_t *outH);

static BOOL SpliceKitBRAWIsAVFriendlyFourCC(uint32_t fourcc) {
    // Empirically: braw, brxq, brst make it through AVFoundation's track filter.
    // brvn and future variants get dropped — we rewrite those to brxq in a clone.
    return fourcc == 'braw' || fourcc == 'brxq' || fourcc == 'brst';
}

// Our shim template writes a 110-byte stsd entry (standard 86 bytes + 'bver' +
// 'ctrn' extension atoms). Blackmagic Cinema Camera 6K BRAWs (and some other
// variants) emit a 122-byte entry with an additional 'bfdn' extension atom,
// and AVFoundation silently drops their video track as a result. Anything
// beyond 110 bytes is treated as "needs shimming even though the fourcc is
// already AV-friendly".
static uint32_t SpliceKitBRAWReadStsdEntrySize(NSString *path, uint64_t fourccFileOffset) {
    if (fourccFileOffset < 4) return 0;
    FILE *f = fopen(path.UTF8String, "rb");
    if (!f) return 0;
    if (fseeko(f, (off_t)(fourccFileOffset - 4), SEEK_SET) != 0) { fclose(f); return 0; }
    uint8_t hdr[4] = {0};
    size_t n = fread(hdr, 1, 4, f);
    fclose(f);
    if (n != 4) return 0;
    return ((uint32_t)hdr[0] << 24) | ((uint32_t)hdr[1] << 16) |
           ((uint32_t)hdr[2] << 8)  | ((uint32_t)hdr[3]);
}

// Forward decl — defined later in this TU. Called from EnsureFourCCShim to
// read the SDK-true decode dims when building the shim stsd entry.
extern "C" BOOL SpliceKitBRAW_ReadClipMetadata(
    CFStringRef pathRef,
    uint32_t *outWidth,
    uint32_t *outHeight,
    float *outFrameRate,
    uint64_t *outFrameCount);

// Ensure the shim file exists for `originalPath`. Returns the shim path, or
// nil if shimming isn't needed (fourcc already friendly) or failed.
// When a shim is created, records clone→original mapping in the shim registry.
static NSString *SpliceKitBRAWEnsureFourCCShim(NSString *originalPath) {
    if (originalPath.length == 0) return nil;
    if (![[NSFileManager defaultManager] fileExistsAtPath:originalPath]) return nil;

    uint32_t fourcc = 0;
    uint64_t fourccOffset = SpliceKitBRAWFindFileFourCCOffset(originalPath, &fourcc);
    if (fourccOffset == 0 || fourcc == 0) {
        return nil; // couldn't parse — let AVAsset try the real file
    }
    BOOL friendlyFourCC = SpliceKitBRAWIsAVFriendlyFourCC(fourcc);
    uint32_t entrySize = SpliceKitBRAWReadStsdEntrySize(originalPath, fourccOffset);
    // Friendly fourcc + clean 110-byte entry = AVFoundation is happy. Anything
    // larger means Blackmagic tacked on an extension atom (e.g. 'bfdn' from
    // Cinema Camera 6K BRAWs) that AVFoundation's MOV parser rejects, so we
    // shim those too and rewrite the entry to the 110-byte template.
    if (friendlyFourCC && entrySize > 0 && entrySize <= 110) {
        return nil;
    }
    if (friendlyFourCC) {
        SpliceKitBRAWTrace([NSString stringWithFormat:@"[fourcc-shim] forcing shim for friendly fourcc 0x%08x with %u-byte stsd entry (%@)",
                            fourcc, entrySize, originalPath]);
    }

    // Cache shim by (path, fourcc). Filename is deterministic from inode+mtime
    // so stale shims don't accumulate.
    NSError *err = nil;
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:originalPath error:&err];
    if (!attrs) return nil;
    NSNumber *size = attrs[NSFileSize];
    NSDate *mtime = attrs[NSFileModificationDate];
    // Include a shim-schema version so bumping the patch logic (e.g. adding a
    // de-stereo pass) invalidates cached shims on existing installs instead
    // of silently continuing to serve pre-fix files.
    NSString *ident = [NSString stringWithFormat:@"%@-%.0f-%llu-v5",
                       [[originalPath lastPathComponent] stringByDeletingPathExtension],
                       mtime.timeIntervalSince1970, size.unsignedLongLongValue];
    NSString *shimPath = [[SpliceKitBRAWShimDirectory() stringByAppendingPathComponent:ident] stringByAppendingPathExtension:@"braw"];

    if (![[NSFileManager defaultManager] fileExistsAtPath:shimPath]) {
        // APFS clone (COW): near-zero cost on same volume; falls back to copy
        // otherwise. Use clonefile() directly so we can pass proper flags.
        int rc = clonefile(originalPath.UTF8String, shimPath.UTF8String, 0);
        if (rc != 0) {
            NSError *copyErr = nil;
            if (![[NSFileManager defaultManager] copyItemAtPath:originalPath toPath:shimPath error:&copyErr]) {
                SpliceKitBRAWTrace([NSString stringWithFormat:@"[fourcc-shim] clonefile+copy failed for %@: %@", originalPath, copyErr.localizedDescription]);
                return nil;
            }
        }
        // Patch the stsd video entry to look like brxq's: fourcc → 'brxq',
        // entry size → 110 (truncating extension atoms so AVFoundation doesn't
        // choke on bfdn/vsrc/unknown atoms), and the fixed-layout fields at
        // offsets 16..31 (version, revision, vendor, temporalQ, spatialQ) to
        // known-good values. We preserve dimensions, hres/vres, data_size,
        // frame_count, compressor_name, depth, color_table at offsets 32..85.
        // This matches Clip.braw's entry exactly for the header, diverging
        // only in media-specific fields that AVFoundation appears not to care
        // about.
        FILE *shim = fopen(shimPath.UTF8String, "r+b");
        if (!shim) {
            SpliceKitBRAWTrace([NSString stringWithFormat:@"[fourcc-shim] cannot reopen shim for patching: %@", shimPath]);
            return nil;
        }
        // Base 110-byte Clip.braw stsd entry template (fourcc='brxq',
        // known-good header + bver/ctrn extension atoms). For stereoscopic
        // BRAWs we also append a 12-byte custom 'seye' extension atom carrying
        // the eye index (0=left, 1=right), bumping the entry to 122 bytes. The
        // VT decoder / AV hook reads that atom back via
        // CMFormatDescriptionGetExtension(… SampleDescriptionExtensionAtoms …)
        // to know which eye to request from IBlackmagicRawClipImmersiveVideo.
        static const uint8_t kClipBRXQStsdEntry[110] = {
            0x00, 0x00, 0x00, 0x6e, 0x62, 0x72, 0x78, 0x71, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
            0xd9, 0x4d, 0x55, 0x22, 0x00, 0x00, 0x00, 0x18, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00,
            0x18, 0x20, 0x0d, 0x90, 0x00, 0x48, 0x00, 0x00, 0x00, 0x48, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x40, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0xff, 0xff, 0x00, 0x00, 0x00, 0x0c, 0x62, 0x76, 0x65, 0x72, 0x00, 0x00,
            0x00, 0x01, 0x00, 0x00, 0x00, 0x0c, 0x63, 0x74, 0x72, 0x6e, 0x00, 0x00, 0x00, 0x01,
        };

        // Find all video trak stsd offsets. One = monoscopic; two = stereo.
        // We only enter stereo mode for exactly two video traks (left + right);
        // other multi-trak layouts aren't supported and fall back to "patch
        // first, skip rest" as before.
        std::vector<uint64_t> videoFourCCFileOffsets;
        SpliceKitBRAWFindAllVideoFourCCFileOffsets(originalPath, videoFourCCFileOffsets);
        BOOL stereoMode = (videoFourCCFileOffsets.size() == 2);

        // Container-declared dims (fallback when SDK isn't loaded yet).
        FILE *orig = fopen(originalPath.UTF8String, "rb");
        uint8_t actualW[2] = {0}, actualH[2] = {0};
        if (orig) {
            fseeko(orig, (off_t)(fourccOffset - 4 + 32), SEEK_SET);
            fread(actualW, 1, 2, orig);
            fread(actualH, 1, 2, orig);
            fclose(orig);
        }

        // SDK-reported decode dimensions — preferred so FCP's canvas matches
        // what we actually produce (e.g. anamorphic / S16 crop modes).
        uint32_t sdkWidth = 0, sdkHeight = 0;
        float sdkFrameRate = 0.0f;
        uint64_t sdkFrameCount = 0;
        BOOL haveSDKDims = SpliceKitBRAW_ReadClipMetadata(
            (__bridge CFStringRef)originalPath,
            &sdkWidth, &sdkHeight, &sdkFrameRate, &sdkFrameCount);

        // If the clip's native dims exceed Metal's max texture size, probe
        // the SDK at Half / Quarter / Eighth scales until the output fits
        // and use those dims in the shim. The decoder consults
        // sSpliceKitBRAWDownscaleMap at runtime to request the same scale.
        BlackmagicRawResolutionScale pickedScale = blackmagicRawResolutionScaleFull;
        if (haveSDKDims && (sdkWidth > kSpliceKitBRAWMaxMetalTextureDim ||
                            sdkHeight > kSpliceKitBRAWMaxMetalTextureDim)) {
            BlackmagicRawResolutionScale try_[] = {
                blackmagicRawResolutionScaleHalf,
                blackmagicRawResolutionScaleQuarter,
                blackmagicRawResolutionScaleEighth,
            };
            for (size_t i = 0; i < sizeof(try_) / sizeof(BlackmagicRawResolutionScale); ++i) {
                uint32_t probedW = 0, probedH = 0;
                if (SpliceKitBRAWProbeScaledDimsForPath(originalPath, try_[i], &probedW, &probedH) &&
                    probedW > 0 && probedH > 0 &&
                    probedW <= kSpliceKitBRAWMaxMetalTextureDim &&
                    probedH <= kSpliceKitBRAWMaxMetalTextureDim) {
                    sdkWidth = probedW;
                    sdkHeight = probedH;
                    pickedScale = try_[i];
                    break;
                }
            }
            SpliceKitBRAWRecordPathScale(originalPath, pickedScale, sdkWidth, sdkHeight);
            SpliceKitBRAWTrace([NSString stringWithFormat:
                @"[fourcc-shim] downscaled shim dims to %ux%u (scale=%d) for %@",
                sdkWidth, sdkHeight, (int)pickedScale, originalPath]);
        } else if (haveSDKDims) {
            SpliceKitBRAWRecordPathScale(originalPath, blackmagicRawResolutionScaleFull, sdkWidth, sdkHeight);
        }

        NSUInteger hash = originalPath.hash;
        uint8_t identTag[8] = {
            (uint8_t)(hash >> 56), (uint8_t)(hash >> 48),
            (uint8_t)(hash >> 40), (uint8_t)(hash >> 32),
            (uint8_t)(hash >> 24), (uint8_t)(hash >> 16),
            (uint8_t)(hash >> 8),  (uint8_t)(hash),
        };
        uint8_t skipFCC[4] = { 's', 'k', 'i', 'p' };

        // Rewrite each video trak's stsd entry. In stereo mode we append a
        // 12-byte 'seye' atom; in mono mode we keep the 110-byte layout.
        if (videoFourCCFileOffsets.empty()) {
            // Shouldn't happen — the outer path only gets here after a video
            // fourcc was found. Fall back to single-entry patch at fourccOffset.
            videoFourCCFileOffsets.push_back(fourccOffset);
        }
        for (size_t eyeIdx = 0; eyeIdx < videoFourCCFileOffsets.size(); ++eyeIdx) {
            uint64_t thisFourccOff = videoFourCCFileOffsets[eyeIdx];
            uint64_t entryStart = thisFourccOff - 4;
            if (fseeko(shim, (off_t)entryStart, SEEK_SET) != 0 ||
                fwrite(kClipBRXQStsdEntry, 1, sizeof(kClipBRXQStsdEntry), shim) != sizeof(kClipBRXQStsdEntry)) {
                fclose(shim);
                return nil;
            }
            // In stereo mode: bump entry size 110→122 and append seye atom.
            if (stereoMode) {
                uint8_t sizeBE[4] = { 0x00, 0x00, 0x00, 0x7a }; // 122
                if (fseeko(shim, (off_t)entryStart, SEEK_SET) == 0) {
                    fwrite(sizeBE, 1, 4, shim);
                }
                uint8_t seye[12] = {
                    0x00, 0x00, 0x00, 0x0c,  // atom size = 12
                    's',  'e',  'y',  'e',   // fourcc
                    (uint8_t)eyeIdx,         // eye index (0=left, 1=right)
                    0x00, 0x00, 0x00,        // padding
                };
                if (fseeko(shim, (off_t)(entryStart + 110), SEEK_SET) == 0) {
                    fwrite(seye, 1, sizeof(seye), shim);
                }
            }
            // Dims — SDK preferred, else container fallback.
            if (haveSDKDims && sdkWidth > 0 && sdkWidth <= 0xFFFF &&
                sdkHeight > 0 && sdkHeight <= 0xFFFF) {
                uint8_t wBE[2] = { (uint8_t)(sdkWidth >> 8),  (uint8_t)(sdkWidth & 0xff) };
                uint8_t hBE[2] = { (uint8_t)(sdkHeight >> 8), (uint8_t)(sdkHeight & 0xff) };
                if (fseeko(shim, (off_t)(entryStart + 32), SEEK_SET) == 0) {
                    fwrite(wBE, 1, 2, shim);
                    fwrite(hBE, 1, 2, shim);
                }
            } else if (actualW[0] || actualW[1] || actualH[0] || actualH[1]) {
                if (fseeko(shim, (off_t)(entryStart + 32), SEEK_SET) == 0) {
                    fwrite(actualW, 1, 2, shim);
                    fwrite(actualH, 1, 2, shim);
                }
            }
            // Per-entry identity: path hash + eye index in last byte. Ensures
            // each eye's FD has distinct bytes even if AVFoundation coalesces
            // on header content only.
            if (fseeko(shim, (off_t)(entryStart + 50), SEEK_SET) == 0) {
                uint8_t perEye[8];
                memcpy(perEye, identTag, 8);
                perEye[7] = (uint8_t)eyeIdx;
                fwrite(perEye, 1, sizeof(perEye), shim);
            }
        }

        // Update tkhd display dims once (for the first video trak) when we
        // have SDK dims — anamorphic / cropped sensor modes need this or FCP
        // stretches the decoded pixels to the container's declared aspect.
        if (haveSDKDims && sdkWidth > 0 && sdkHeight > 0) {
            uint64_t tkhdOff = SpliceKitBRAWFindFirstVideoTkhdDisplaySizeFileOffset(originalPath);
            if (tkhdOff != 0) {
                uint32_t wFixed = sdkWidth  * 65536u;
                uint32_t hFixed = sdkHeight * 65536u;
                uint8_t wF[4] = {
                    (uint8_t)(wFixed >> 24), (uint8_t)(wFixed >> 16),
                    (uint8_t)(wFixed >> 8),  (uint8_t)(wFixed & 0xff),
                };
                uint8_t hF[4] = {
                    (uint8_t)(hFixed >> 24), (uint8_t)(hFixed >> 16),
                    (uint8_t)(hFixed >> 8),  (uint8_t)(hFixed & 0xff),
                };
                if (fseeko(shim, (off_t)tkhdOff, SEEK_SET) == 0) {
                    fwrite(wF, 1, 4, shim);
                    fwrite(hF, 1, 4, shim);
                }
            }
            SpliceKitBRAWTrace([NSString stringWithFormat:@"[fourcc-shim] using SDK dims %ux%u for %@",
                                sdkWidth, sdkHeight, originalPath]);
        }

        // Hide metadata (mebx) traks — rewrite their trak fourcc to 'skip'
        // so AVFoundation doesn't count them against the video-track filter.
        std::vector<uint64_t> metaOffsets;
        SpliceKitBRAWFindMetaTrakFileOffsets(originalPath, metaOffsets);
        for (uint64_t metaOff : metaOffsets) {
            if (fseeko(shim, (off_t)metaOff, SEEK_SET) != 0) continue;
            if (fwrite(skipFCC, 1, 4, shim) != 4) continue;
        }
        if (!metaOffsets.empty()) {
            SpliceKitBRAWTrace([NSString stringWithFormat:@"[fourcc-shim] stripped %lu meta trak(s) for %@",
                                (unsigned long)metaOffsets.size(), originalPath]);
        }

        // Stereo handling: in mono mode we strip extra video traks and
        // vexu/hfov/tref atoms so FCP treats the clip as single-eye. In
        // stereo mode we leave those intact — FCP uses them to expose
        // left/right eyes, and our per-eye decode path handles each.
        if (!stereoMode) {
            std::vector<uint64_t> extraVideoOffsets;
            SpliceKitBRAWFindExtraVideoTrakFileOffsets(originalPath, extraVideoOffsets);
            for (uint64_t off : extraVideoOffsets) {
                if (fseeko(shim, (off_t)off, SEEK_SET) != 0) continue;
                if (fwrite(skipFCC, 1, 4, shim) != 4) continue;
            }
            std::vector<uint64_t> stereoAtomOffsets;
            SpliceKitBRAWFindStereoAtomFileOffsets(originalPath, stereoAtomOffsets);
            for (uint64_t off : stereoAtomOffsets) {
                if (fseeko(shim, (off_t)off, SEEK_SET) != 0) continue;
                if (fwrite(skipFCC, 1, 4, shim) != 4) continue;
            }
            if (!extraVideoOffsets.empty() || !stereoAtomOffsets.empty()) {
                SpliceKitBRAWTrace([NSString stringWithFormat:@"[fourcc-shim] de-stereoed: stripped %lu extra video trak(s) + %lu stereo atom(s) for %@",
                                    (unsigned long)extraVideoOffsets.size(),
                                    (unsigned long)stereoAtomOffsets.size(),
                                    originalPath]);
            }
        } else {
            SpliceKitBRAWTrace([NSString stringWithFormat:@"[fourcc-shim] stereo mode: 2 video traks patched (seye atoms 0/1) for %@",
                                originalPath]);
        }
        fclose(shim);
        char oldFCC[5] = { (char)((fourcc>>24)&0xff), (char)((fourcc>>16)&0xff), (char)((fourcc>>8)&0xff), (char)(fourcc&0xff), 0 };
        SpliceKitBRAWTrace([NSString stringWithFormat:@"[fourcc-shim] created %@ (patched '%s'→'brxq', %s, header @%llu) for %@",
                            shimPath, oldFCC, stereoMode ? "stereo entry=122" : "entry=110", fourccOffset, originalPath]);
    }

    NSMutableDictionary *map = SpliceKitBRAWShimCloneToOriginal();
    @synchronized (map) {
        map[shimPath] = originalPath;
    }
    return shimPath;
}

// Given a (possibly shim) path, return the original BRAW path the caller cares
// about — either the path itself (if not shimmed) or the pre-shim original.
static NSString *SpliceKitBRAWResolveOriginalPath(NSString *path) {
    if (path.length == 0) return path;
    NSMutableDictionary *map = SpliceKitBRAWShimCloneToOriginal();
    NSString *original = nil;
    @synchronized (map) {
        original = map[path];
    }
    return original ?: path;
}

SPLICEKIT_BRAW_EXTERN_C NSString *SpliceKitBRAWResolveOriginalPathForPublic(NSString *path) {
    NSString *resolved = SpliceKitBRAWResolveOriginalPath(path);
    if (resolved.length == 0) return resolved;
    NSURL *url = [[NSURL fileURLWithPath:resolved] URLByResolvingSymlinksInPath];
    return (url.path.length > 0 ? url.path : resolved).stringByStandardizingPath;
}

static IMP sSpliceKitBRAWOriginalUTTypeConformsToIMP = NULL;
static IMP sSpliceKitBRAWOriginalAVURLAssetInitIMP = NULL;
static IMP sSpliceKitBRAWOriginalAVURLAssetClassMethodIMP = NULL;

static BOOL SpliceKitBRAWUTTypeConformsToOverride(id self, SEL _cmd, id target) {
    NSString *selfID = nil;
    NSString *targetID = nil;
    @try {
        if ([self respondsToSelector:@selector(identifier)]) {
            selfID = ((NSString *(*)(id, SEL))objc_msgSend)(self, @selector(identifier));
        }
        if ([target respondsToSelector:@selector(identifier)]) {
            targetID = ((NSString *(*)(id, SEL))objc_msgSend)(target, @selector(identifier));
        }
    } @catch (NSException *exception) {
        // fall through
    }

    if (SpliceKitBRAWIsBRAWUTIString(selfID) && SpliceKitBRAWShouldConformBRAWTo(targetID)) {
        return YES;
    }

    if (sSpliceKitBRAWOriginalUTTypeConformsToIMP) {
        return ((BOOL (*)(id, SEL, id))sSpliceKitBRAWOriginalUTTypeConformsToIMP)(self, _cmd, target);
    }
    return NO;
}

// Global maps: CMFormatDescription pointer (as NSValue) -> NSString path, and
// (parallel map) FD pointer -> NSNumber(eyeIndex) for stereoscopic clips
// where each eye's FD carries a different 'seye' extension atom. Populated by
// the AV hook so the decoder can recover the source path + eye when the
// format description came from AVFoundation's QT reader (which has no BrwP
// atom). Keys retain the format description so pointers stay valid until we
// unregister. Eye map is populated only when the FD actually carries a seye
// atom — absent entries are implicit "monoscopic / unknown" (-1).
static NSMutableDictionary<NSValue *, NSString *> *sSpliceKitBRAWFormatDescriptionPathMap = nil;
static NSMutableDictionary<NSValue *, NSNumber *> *sSpliceKitBRAWFormatDescriptionEyeMap = nil;
static NSLock *sSpliceKitBRAWFormatDescriptionLock = nil;

// Extract the eye index from a CMVideoFormatDescription's 'seye' extension
// atom. Returns -1 when absent (monoscopic / pre-stereo shim).
static int SpliceKitBRAWEyeIndexFromFormatDescription(CMFormatDescriptionRef fd) {
    if (!fd) return -1;
    CFDictionaryRef atoms = (CFDictionaryRef)CMFormatDescriptionGetExtension(
        fd, kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms);
    if (!atoms) return -1;
    CFDataRef seye = (CFDataRef)CFDictionaryGetValue(atoms, CFSTR("seye"));
    if (!seye || CFGetTypeID(seye) != CFDataGetTypeID()) return -1;
    if (CFDataGetLength(seye) < 1) return -1;
    const uint8_t *bytes = CFDataGetBytePtr(seye);
    return (int)bytes[0];
}

static void SpliceKitBRAWRegisterFormatDescriptionPath(CMFormatDescriptionRef fd, NSString *path) {
    if (!fd || path.length == 0) return;
    if (!sSpliceKitBRAWFormatDescriptionPathMap) {
        sSpliceKitBRAWFormatDescriptionPathMap = [NSMutableDictionary dictionary];
        sSpliceKitBRAWFormatDescriptionEyeMap = [NSMutableDictionary dictionary];
        sSpliceKitBRAWFormatDescriptionLock = [[NSLock alloc] init];
    }
    int eye = SpliceKitBRAWEyeIndexFromFormatDescription(fd);
    CFRetain(fd);  // Keep it alive while we track it
    [sSpliceKitBRAWFormatDescriptionLock lock];
    NSValue *key = [NSValue valueWithPointer:fd];
    if (!sSpliceKitBRAWFormatDescriptionPathMap[key]) {
        sSpliceKitBRAWFormatDescriptionPathMap[key] = path;
        if (eye >= 0) {
            sSpliceKitBRAWFormatDescriptionEyeMap[key] = @(eye);
        }
    } else {
        CFRelease(fd);  // Didn't insert, so balance retain
    }
    [sSpliceKitBRAWFormatDescriptionLock unlock];
    if (eye >= 0) {
        SpliceKitBRAWTrace([NSString stringWithFormat:
            @"[av-hook] registered FD %p path=%@ eye=%d", fd, path, eye]);
    }
}

SPLICEKIT_BRAW_EXTERN_C NSString *SpliceKitBRAWLookupPathForFormatDescription(CMFormatDescriptionRef fd) {
    if (!fd || !sSpliceKitBRAWFormatDescriptionPathMap) return nil;

    [sSpliceKitBRAWFormatDescriptionLock lock];
    // Exact pointer match only. CFEqual-based fallback is unsafe here: two
    // different .braw clips with identical sample descriptions (same codec,
    // dimensions, extension atoms) compare equal but map to different files,
    // so a fallback could silently bind the decoder to the wrong clip. If the
    // pointer misses, the AV hook (or future per-track registration) needs to
    // cover that path — we'd rather fail loudly than decode the wrong file.
    NSValue *pointerKey = [NSValue valueWithPointer:fd];
    NSString *result = sSpliceKitBRAWFormatDescriptionPathMap[pointerKey];
    [sSpliceKitBRAWFormatDescriptionLock unlock];

    if (!result) {
        SpliceKitBRAWTrace([NSString stringWithFormat:
            @"[av-hook] FD %p not in registry; no fallback — returning nil", fd]);
    }
    return result;
}

// Return the eye index (0=left, 1=right) for a registered stereo FD, or -1
// if the FD is monoscopic / unregistered. Used by the VT decoder to pick
// which eye to request from the BRAW SDK's immersive video interface.
SPLICEKIT_BRAW_EXTERN_C int SpliceKitBRAWLookupEyeForFormatDescription(CMFormatDescriptionRef fd) {
    if (!fd || !sSpliceKitBRAWFormatDescriptionEyeMap) return -1;
    [sSpliceKitBRAWFormatDescriptionLock lock];
    NSValue *key = [NSValue valueWithPointer:fd];
    NSNumber *eye = sSpliceKitBRAWFormatDescriptionEyeMap[key];
    [sSpliceKitBRAWFormatDescriptionLock unlock];
    return eye ? eye.intValue : -1;
}

static NSUInteger SpliceKitBRAWWalkAssetTracks(id asset, NSString *path) {
    NSUInteger registered = 0;
    @try {
        NSArray *tracks = [asset respondsToSelector:@selector(tracks)] ?
            ((NSArray *(*)(id, SEL))objc_msgSend)(asset, @selector(tracks)) : nil;
        for (id track in tracks) {
            if (![track respondsToSelector:@selector(formatDescriptions)]) continue;
            NSArray *fds = ((NSArray *(*)(id, SEL))objc_msgSend)(track, @selector(formatDescriptions));
            for (id fd in fds) {
                CMFormatDescriptionRef fdRef = (__bridge CMFormatDescriptionRef)fd;
                if (!fdRef) continue;
                if (CMFormatDescriptionGetMediaType(fdRef) == kCMMediaType_Video) {
                    FourCharCode subType = CMFormatDescriptionGetMediaSubType(fdRef);
                    if (subType == 'brxq' || subType == 'braw' || subType == 'brst' ||
                        subType == 'brvn' || subType == 'brs2' || subType == 'brxh') {
                        SpliceKitBRAWRegisterFormatDescriptionPath(fdRef, path);
                        registered++;
                    }
                }
            }
        }
    } @catch (NSException *exception) {
        // ignore
    }
    return registered;
}

static void SpliceKitBRAWRegisterAssetTracks(id asset, NSString *path) {
    if (!asset || path.length == 0) return;

    NSUInteger registered = SpliceKitBRAWWalkAssetTracks(asset, path);

    // AVFoundation can return an empty tracks array at init time when the
    // underlying container hasn't been parsed yet. Ask the asset to finish
    // loading "tracks" asynchronously and re-register once done, so late-binding
    // format descriptions end up in the path map instead of hitting the lookup
    // and returning nil.
    if (registered == 0 && [asset respondsToSelector:@selector(loadValuesAsynchronouslyForKeys:completionHandler:)]) {
        @try {
            void (^completion)(void) = ^{
                NSUInteger n = SpliceKitBRAWWalkAssetTracks(asset, path);
                if (n > 0) {
                    SpliceKitBRAWTrace([NSString stringWithFormat:
                        @"[av-hook] deferred-registered %lu track FD(s) for %@",
                        (unsigned long)n, path]);
                }
            };
            ((void (*)(id, SEL, NSArray *, id))objc_msgSend)(
                asset,
                @selector(loadValuesAsynchronouslyForKeys:completionHandler:),
                @[@"tracks"],
                completion);
        } @catch (NSException *exception) {
            // ignore
        }
    }
}

// Inject AVURLAssetOverrideMIMETypeKey=video/quicktime so AVFoundation parses
// .braw as QuickTime. This works for brxq/brst; brvn and unknown variants are
// silently dropped by AVFoundation's video track filter. Disable with
// SPLICEKIT_BRAW_MIME_OFF=1 in the environment for debugging.
static BOOL SpliceKitBRAWMIMEOverrideEnabled() {
    static BOOL value;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const char *off = getenv("SPLICEKIT_BRAW_MIME_OFF");
        value = (off && (off[0] == '1' || off[0] == 'y' || off[0] == 'Y')) ? NO : YES;
    });
    return value;
}

// Redirect to a fourcc-shim URL if the real file's stsd fourcc is one
// AVFoundation won't accept. Also returns the path we should register FDs
// against — always the original.
static NSURL *SpliceKitBRAWMaybeRewriteBRAWURL(NSURL *url, NSString **outOriginalPath) {
    *outOriginalPath = url.path;
    NSString *shim = SpliceKitBRAWEnsureFourCCShim(url.path);
    if (!shim) return url;
    NSURL *shimURL = [NSURL fileURLWithPath:shim];
    SpliceKitBRAWTrace([NSString stringWithFormat:@"[av-hook] redirecting %@ -> shim %@", url.path, shim]);
    return shimURL;
}

static id SpliceKitBRAWAVURLAssetInitOverride(id self, SEL _cmd, NSURL *url, NSDictionary *options) {
    NSDictionary *effectiveOptions = options;
    NSURL *effectiveURL = url;
    NSString *registrationPath = url.path;
    BOOL isBRAW = NO;
    @try {
        if ([url isKindOfClass:[NSURL class]] && url.isFileURL) {
            NSString *ext = url.pathExtension ?: @"";
            if (SpliceKitBRAWIsBRAWExtension(ext)) {
                isBRAW = YES;
                if (SpliceKitBRAWMIMEOverrideEnabled()) {
                    NSMutableDictionary *modified = options ? [options mutableCopy] : [NSMutableDictionary dictionary];
                    if (!modified[AVURLAssetOverrideMIMETypeKey]) {
                        modified[AVURLAssetOverrideMIMETypeKey] = @"video/quicktime";
                        SpliceKitBRAWTrace([NSString stringWithFormat:@"[av-hook] initWithURL:options: injecting MIME override for %@", url.path]);
                    }
                    effectiveOptions = modified;
                    effectiveURL = SpliceKitBRAWMaybeRewriteBRAWURL(url, &registrationPath);
                } else {
                    SpliceKitBRAWTrace([NSString stringWithFormat:@"[av-hook] initWithURL:options: saw .braw, letting AVAsset fail for %@", url.path]);
                }
            }
        }
    } @catch (NSException *exception) {
        effectiveOptions = options;
        effectiveURL = url;
    }

    id result = nil;
    if (sSpliceKitBRAWOriginalAVURLAssetInitIMP) {
        result = ((id (*)(id, SEL, NSURL *, NSDictionary *))sSpliceKitBRAWOriginalAVURLAssetInitIMP)(self, _cmd, effectiveURL, effectiveOptions);
    } else {
        result = self;
    }

    if (isBRAW && result && SpliceKitBRAWMIMEOverrideEnabled()) {
        // Register tracks against the ORIGINAL path, so the VT decoder's host
        // lookup resolves to the real file (not the fourcc-patched shim).
        SpliceKitBRAWRegisterAssetTracks(result, registrationPath);
    }
    return result;
}

static id SpliceKitBRAWAVURLAssetClassMethodOverride(id self, SEL _cmd, NSURL *url, NSDictionary *options) {
    NSDictionary *effectiveOptions = options;
    NSURL *effectiveURL = url;
    NSString *registrationPath = url.path;
    BOOL isBRAW = NO;
    @try {
        if ([url isKindOfClass:[NSURL class]] && url.isFileURL) {
            NSString *ext = url.pathExtension ?: @"";
            if (SpliceKitBRAWIsBRAWExtension(ext)) {
                isBRAW = YES;
                if (SpliceKitBRAWMIMEOverrideEnabled()) {
                    NSMutableDictionary *modified = options ? [options mutableCopy] : [NSMutableDictionary dictionary];
                    if (!modified[AVURLAssetOverrideMIMETypeKey]) {
                        modified[AVURLAssetOverrideMIMETypeKey] = @"video/quicktime";
                        SpliceKitBRAWTrace([NSString stringWithFormat:@"[av-hook] +URLAssetWithURL:options: injecting MIME override for %@", url.path]);
                    }
                    effectiveOptions = modified;
                    effectiveURL = SpliceKitBRAWMaybeRewriteBRAWURL(url, &registrationPath);
                }
            }
        }
    } @catch (NSException *exception) {
        effectiveOptions = options;
        effectiveURL = url;
    }

    id result = nil;
    if (sSpliceKitBRAWOriginalAVURLAssetClassMethodIMP) {
        result = ((id (*)(id, SEL, NSURL *, NSDictionary *))sSpliceKitBRAWOriginalAVURLAssetClassMethodIMP)(self, _cmd, effectiveURL, effectiveOptions);
    }

    if (isBRAW && result && SpliceKitBRAWMIMEOverrideEnabled()) {
        SpliceKitBRAWRegisterAssetTracks(result, registrationPath);
    }
    return result;
}

SPLICEKIT_BRAW_EXTERN_C BOOL SpliceKit_installBRAWUTITypeConformanceHook(void) {
    if (sSpliceKitBRAWOriginalUTTypeConformsToIMP) return YES;

    Class utTypeClass = objc_getClass("UTType");
    if (!utTypeClass) {
        SpliceKitBRAWTrace(@"[uti-hook] UTType class unavailable");
        return NO;
    }

    Method conformsMethod = class_getInstanceMethod(utTypeClass, @selector(conformsToType:));
    if (!conformsMethod) {
        SpliceKitBRAWTrace(@"[uti-hook] UTType conformsToType: method not found");
        return NO;
    }

    sSpliceKitBRAWOriginalUTTypeConformsToIMP = method_setImplementation(
        conformsMethod, (IMP)SpliceKitBRAWUTTypeConformsToOverride);
    SpliceKitBRAWTrace(@"[uti-hook] installed -[UTType conformsToType:] swizzle");
    return sSpliceKitBRAWOriginalUTTypeConformsToIMP != NULL;
}

SPLICEKIT_BRAW_EXTERN_C BOOL SpliceKit_installBRAWAVURLAssetMIMEHook(void) {
    Class cls = objc_getClass("AVURLAsset");
    if (!cls) {
        SpliceKitBRAWTrace(@"[av-hook] AVURLAsset class unavailable");
        return NO;
    }

    if (!sSpliceKitBRAWOriginalAVURLAssetInitIMP) {
        Method initMethod = class_getInstanceMethod(cls, @selector(initWithURL:options:));
        if (initMethod) {
            sSpliceKitBRAWOriginalAVURLAssetInitIMP = method_setImplementation(
                initMethod, (IMP)SpliceKitBRAWAVURLAssetInitOverride);
            SpliceKitBRAWTrace(@"[av-hook] installed -[AVURLAsset initWithURL:options:] swizzle");
        } else {
            SpliceKitBRAWTrace(@"[av-hook] -[AVURLAsset initWithURL:options:] not found");
        }
    }

    if (!sSpliceKitBRAWOriginalAVURLAssetClassMethodIMP) {
        Method classMethod = class_getClassMethod(cls, @selector(URLAssetWithURL:options:));
        if (classMethod) {
            sSpliceKitBRAWOriginalAVURLAssetClassMethodIMP = method_setImplementation(
                classMethod, (IMP)SpliceKitBRAWAVURLAssetClassMethodOverride);
            SpliceKitBRAWTrace(@"[av-hook] installed +[AVURLAsset URLAssetWithURL:options:] swizzle");
        } else {
            SpliceKitBRAWTrace(@"[av-hook] +[AVURLAsset URLAssetWithURL:options:] not found");
        }
    }

    return (sSpliceKitBRAWOriginalAVURLAssetInitIMP != NULL) ||
           (sSpliceKitBRAWOriginalAVURLAssetClassMethodIMP != NULL);
}

SPLICEKIT_BRAW_EXTERN_C void SpliceKit_installBRAWProviderShim(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableDictionary *details = [NSMutableDictionary dictionary];
        (void)SpliceKitBRAWRegisterProviderShimPhase(@"both", details);
    });
}

// Declared in SpliceKitBRAWDecoderInProcess.mm (same dylib — direct link).
// Registers a VT video decoder for every BRAW FourCC via VTRegisterVideoDecoder,
// so .braw decode dispatches into our process without any plugin bundle on disk.
// Idempotent (dispatch_once-guarded internally).
extern "C" BOOL SpliceKitBRAW_registerInProcessDecoder(void);

SPLICEKIT_BRAW_EXTERN_C void SpliceKit_bootstrapBRAWAtLaunchPhase(NSString *phase) {
    NSString *phaseName = [phase isKindOfClass:[NSString class]] ? phase : @"unknown";

    // Gate the entire BRAW integration on the user having a valid Mac App
    // Store copy of Braw Toolbox installed. Without it, we register nothing:
    // no in-process decoder, no VT/UTI/AV hooks, no workflow plugins.
    if (!SpliceKit_isBRAWToolboxInstalled()) {
        SpliceKitBRAWTrace([NSString stringWithFormat:@"[startup] phase=%@ skipped: Braw Toolbox not installed",
                                                      phaseName]);
        return;
    }

    // In-process decoder registration runs every time regardless of whether
    // the legacy MediaExtension bundles are present on disk. If a bundle IS
    // also present it will register its own VT decoder for the same FourCC;
    // VT dispatches to the most recent registration, and we run at dylib
    // bootstrap before the bundle directory sweep, so ours ends up ordered
    // correctly. We want the in-process path to become canonical and replace
    // the bundle path entirely over time.
    SpliceKitBRAW_registerInProcessDecoder();

    BOOL bundlesPresent =
        ([[NSFileManager defaultManager] fileExistsAtPath:SpliceKitBRAWBundlePath(@"FormatReaders/SpliceKitBRAWImport.bundle")] ||
         [[NSFileManager defaultManager] fileExistsAtPath:SpliceKitBRAWBundlePath(@"Codecs/SpliceKitBRAWDecoder.bundle")]);

    BOOL installProviderShim = SpliceKitBRAWBoolDefault(@"SpliceKitInstallBRAWProviderShimAtLaunch", bundlesPresent);
    BOOL registerWorkflowPlugins = SpliceKitBRAWBoolDefault(@"SpliceKitRegisterBRAWWorkflowPluginsAtLaunch", bundlesPresent);
    BOOL enableWillLaunch = SpliceKitBRAWBoolDefault(@"SpliceKitBootstrapBRAWAtWillLaunch", bundlesPresent);
    BOOL enableDidLaunch = SpliceKitBRAWBoolDefault(@"SpliceKitBootstrapBRAWAtDidLaunch", bundlesPresent);
    BOOL installUTIHook = SpliceKitBRAWBoolDefault(@"SpliceKitInstallBRAWUTIHookAtLaunch", bundlesPresent);
    BOOL installAVHook = SpliceKitBRAWBoolDefault(@"SpliceKitInstallBRAWAVURLAssetHookAtLaunch", bundlesPresent);

    BOOL phaseEnabled = [phaseName isEqualToString:@"will-launch"] ? enableWillLaunch : enableDidLaunch;
    SpliceKitBRAWTrace([NSString stringWithFormat:@"[startup] phase=%@ enabled=%@ bundlesPresent=%@ shim=%@ register=%@ utiHook=%@ avHook=%@",
                        phaseName,
                        phaseEnabled ? @"YES" : @"NO",
                        bundlesPresent ? @"YES" : @"NO",
                        installProviderShim ? @"YES" : @"NO",
                        registerWorkflowPlugins ? @"YES" : @"NO",
                        installUTIHook ? @"YES" : @"NO",
                        installAVHook ? @"YES" : @"NO"]);

    if (!phaseEnabled || !bundlesPresent) {
        return;
    }

    NSMutableDictionary *details = [NSMutableDictionary dictionary];
    details[@"phase"] = phaseName;

    // Install UTI / AV hooks first so they are in place before the workflow
    // plugin registration actually triggers any media-readable probe.
    if (installUTIHook) {
        BOOL utiInstalled = SpliceKit_installBRAWUTITypeConformanceHook();
        details[@"utiConformanceHookInstalled"] = @(utiInstalled);
    }

    if (installAVHook) {
        BOOL avInstalled = SpliceKit_installBRAWAVURLAssetMIMEHook();
        details[@"avURLAssetMIMEHookInstalled"] = @(avInstalled);
    }

    if (installProviderShim) {
        BOOL shimInstalled = SpliceKitBRAWRegisterProviderShimPhase(@"both", details);
        details[@"providerShimInstalled"] = @(shimInstalled);
    }

    if (registerWorkflowPlugins) {
        SpliceKitBRAWRegisterProfessionalWorkflowPlugins(details);
    }

    SpliceKitBRAWTrace([NSString stringWithFormat:@"[startup] phase=%@ diagnostics=%@",
                        phaseName,
                        details]);
}

static NSDictionary *SpliceKitBRAWProviderProbeForPath(NSString *path, BOOL includeProviderValidation) {
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    result[@"path"] = path ?: @"";

    if (!path.length) {
        result[@"error"] = @"missing path";
        return result;
    }

    Class providerClass = objc_getClass("FFProvider");
    Class providerFigClass = objc_getClass("FFProviderFig");
    if (!providerClass || !providerFigClass) {
        result[@"error"] = @"FFProvider / FFProviderFig classes are unavailable";
        return result;
    }

    NSURL *url = [NSURL fileURLWithPath:path];
    NSString *extension = url.pathExtension ?: @"";
    NSString *uti = ((id (*)(id, SEL, id))objc_msgSend)(providerClass, NSSelectorFromString(@"getUTTypeForURL:"), url);

    result[@"extension"] = extension;
    result[@"uti"] = uti ?: (id)[NSNull null];
    result[@"providerShimClass"] = NSStringFromClass(providerFigClass) ?: (id)[NSNull null];
    result[@"providerFigExtensions"] = SpliceKitBRAWArrayFromContainer(((id (*)(id, SEL))objc_msgSend)(providerFigClass, @selector(extensions))) ?: @[];
    result[@"providerFigUTIs"] = SpliceKitBRAWArrayFromContainer(((id (*)(id, SEL))objc_msgSend)(providerFigClass, @selector(utis))) ?: @[];

    if (!includeProviderValidation) {
        return result;
    }

    Class resolvedClass = ((Class (*)(id, SEL, id, id))objc_msgSend)(
        providerClass,
        NSSelectorFromString(@"providerClassForUTIType:extension:"),
        uti,
        extension);
    if (resolvedClass) {
        result[@"providerClass"] = NSStringFromClass(resolvedClass);
    } else {
        result[@"providerClass"] = [NSNull null];
    }

    BOOL pluginMissing = NO;
    int missingReason = 0;
    BOOL validSource = ((BOOL (*)(id, SEL, id, BOOL *, int *))objc_msgSend)(
        providerClass,
        NSSelectorFromString(@"providerHasValidSourceForURL:pluginMissing:missingReason:"),
        url,
        &pluginMissing,
        &missingReason);
    result[@"providerHasValidSource"] = @(validSource);
    result[@"pluginMissing"] = @(pluginMissing);
    result[@"missingReason"] = @(missingReason);
    result[@"missingReasonName"] = SpliceKitBRAWMissingReasonName(missingReason);

    if (!validSource && pluginMissing && missingReason == 8 && providerFigClass) {
        ((void (*)(id, SEL, id))objc_msgSend)(
            providerFigClass,
            NSSelectorFromString(@"invalidateMediaReaderForURL:"),
            url);
        BOOL retryPluginMissing = NO;
        int retryReason = 0;
        BOOL retryValid = ((BOOL (*)(id, SEL, id, BOOL *, int *))objc_msgSend)(
            providerClass,
            NSSelectorFromString(@"providerHasValidSourceForURL:pluginMissing:missingReason:"),
            url,
            &retryPluginMissing,
            &retryReason);
        result[@"afterInvalidate"] = @{
            @"providerHasValidSource": @(retryValid),
            @"pluginMissing": @(retryPluginMissing),
            @"missingReason": @(retryReason),
            @"missingReasonName": SpliceKitBRAWMissingReasonName(retryReason),
        };
    }

    id provider = ((id (*)(id, SEL, id))objc_msgSend)(providerClass, NSSelectorFromString(@"newProviderForURL:"), url);
    if (provider) {
        result[@"newProviderClass"] = NSStringFromClass([provider class]) ?: (id)[NSNull null];

        int providerReason = 0;
        if ([provider respondsToSelector:NSSelectorFromString(@"pluginMissing:")]) {
            BOOL providerMissing = ((BOOL (*)(id, SEL, int *))objc_msgSend)(
                provider,
                NSSelectorFromString(@"pluginMissing:"),
                &providerReason);
            result[@"providerInstancePluginMissing"] = @(providerMissing);
            result[@"providerInstanceMissingReason"] = @(providerReason);
            result[@"providerInstanceMissingReasonName"] = SpliceKitBRAWMissingReasonName(providerReason);
        }

        if ([provider respondsToSelector:NSSelectorFromString(@"copyMediaExtensionInfo")]) {
            id info = ((id (*)(id, SEL))objc_msgSend)(provider, NSSelectorFromString(@"copyMediaExtensionInfo"));
            if (info) {
                result[@"mediaExtensionInfo"] = info;
            }
        }

        id source = ((id (*)(id, SEL))objc_msgSend)(provider, NSSelectorFromString(@"newFirstVideoSource"));
        if (!source) {
            id audioSource = ((id (*)(id, SEL))objc_msgSend)(provider, NSSelectorFromString(@"firstAudioSource"));
            if (audioSource) {
                source = audioSource;
            }
        }
        if (source) {
            result[@"sourceClass"] = NSStringFromClass([source class]) ?: (id)[NSNull null];
            if ([source respondsToSelector:@selector(isValid)]) {
                BOOL sourceValid = ((BOOL (*)(id, SEL))objc_msgSend)(source, @selector(isValid));
                result[@"sourceValid"] = @(sourceValid);
            }
        }
    }

    return result;
}

static id SpliceKitBRAWVariantPreview(const Variant *value, NSUInteger maxArrayItems) {
    switch (value->vt) {
        case blackmagicRawVariantTypeS16:
            return @(value->iVal);
        case blackmagicRawVariantTypeU16:
            return @(value->uiVal);
        case blackmagicRawVariantTypeS32:
            return @(value->intVal);
        case blackmagicRawVariantTypeU32:
            return @(value->uintVal);
        case blackmagicRawVariantTypeFloat32:
            return @(value->fltVal);
        case blackmagicRawVariantTypeFloat64:
            return @(value->dblVal);
        case blackmagicRawVariantTypeString:
            return value->bstrVal ? [(__bridge NSString *)value->bstrVal copy] : (id)[NSNull null];
        case blackmagicRawVariantTypeSafeArray: {
            if (!value->parray) return @[];

            void *data = nullptr;
            if (FAILED(SafeArrayAccessData(value->parray, &data)) || !data) return @[];

            BlackmagicRawVariantType elementType = blackmagicRawVariantTypeEmpty;
            if (FAILED(SafeArrayGetVartype(value->parray, &elementType))) return @[];

            long lBound = 0;
            long uBound = -1;
            if (FAILED(SafeArrayGetLBound(value->parray, 1, &lBound)) ||
                FAILED(SafeArrayGetUBound(value->parray, 1, &uBound)) ||
                uBound < lBound) {
                return @[];
            }

            NSUInteger total = (NSUInteger)((uBound - lBound) + 1);
            NSUInteger count = MIN(total, maxArrayItems);
            NSMutableArray *preview = [NSMutableArray arrayWithCapacity:count];

            for (NSUInteger i = 0; i < count; i++) {
                switch (elementType) {
                    case blackmagicRawVariantTypeU8:
                        [preview addObject:@(((uint8_t *)data)[i])];
                        break;
                    case blackmagicRawVariantTypeS16:
                        [preview addObject:@(((int16_t *)data)[i])];
                        break;
                    case blackmagicRawVariantTypeU16:
                        [preview addObject:@(((uint16_t *)data)[i])];
                        break;
                    case blackmagicRawVariantTypeS32:
                        [preview addObject:@(((int32_t *)data)[i])];
                        break;
                    case blackmagicRawVariantTypeU32:
                        [preview addObject:@(((uint32_t *)data)[i])];
                        break;
                    case blackmagicRawVariantTypeFloat32:
                        [preview addObject:@(((float *)data)[i])];
                        break;
                    case blackmagicRawVariantTypeFloat64:
                        [preview addObject:@(((double *)data)[i])];
                        break;
                    default:
                        [preview addObject:SpliceKitBRAWVariantTypeName(elementType)];
                        break;
                }
            }

            return @{
                @"elementType": SpliceKitBRAWVariantTypeName(elementType),
                @"count": @(total),
                @"preview": preview,
            };
        }
        case blackmagicRawVariantTypeEmpty:
            return [NSNull null];
        default:
            return [NSString stringWithFormat:@"Unsupported variant type %@", SpliceKitBRAWVariantTypeName(value->vt)];
    }
}

static NSDictionary *SpliceKitBRAWMetadataEntry(CFStringRef key, const Variant *value, NSUInteger maxArrayItems) {
    NSString *keyString = key ? [(__bridge NSString *)key copy] : @"<unknown>";
    return @{
        @"key": keyString,
        @"type": SpliceKitBRAWVariantTypeName(value->vt),
        @"value": SpliceKitBRAWVariantPreview(value, maxArrayItems) ?: (id)[NSNull null],
    };
}

static NSArray<NSDictionary *> *SpliceKitBRAWMetadataSample(IBlackmagicRawMetadataIterator *iterator,
                                                            NSUInteger limit) {
    if (!iterator || limit == 0) return @[];

    NSMutableArray<NSDictionary *> *entries = [NSMutableArray array];
    for (NSUInteger index = 0; index < limit; index++) {
        CFStringRef key = nullptr;
        HRESULT keyResult = iterator->GetKey(&key);
        if (keyResult != S_OK || !key) break;

        Variant value;
        if (FAILED(VariantInit(&value))) break;

        HRESULT dataResult = iterator->GetData(&value);
        if (dataResult == S_OK) {
            [entries addObject:SpliceKitBRAWMetadataEntry(key, &value, 12)];
        }
        VariantClear(&value);

        HRESULT nextResult = iterator->Next();
        if (nextResult != S_OK) break;
    }

    return entries;
}

struct SpliceKitBRAWDecodeContext {
    HRESULT readResult = E_FAIL;
    HRESULT processResult = E_FAIL;
    bool sawRead = false;
    bool sawProcess = false;
    uint32_t width = 0;
    uint32_t height = 0;
    uint32_t resourceSizeBytes = 0;
    BlackmagicRawResourceType resourceType = blackmagicRawResourceTypeBufferCPU;
    BlackmagicRawResourceFormat resourceFormat = blackmagicRawResourceFormatRGBAU8;
    std::string error;
};

class SpliceKitBRAWDecodeCallback : public IBlackmagicRawCallback {
public:
    explicit SpliceKitBRAWDecodeCallback(SpliceKitBRAWDecodeContext *context)
    : _context(context) {}

    void ReadComplete(IBlackmagicRawJob *job, HRESULT result, IBlackmagicRawFrame *frame) override {
        _context->sawRead = true;
        _context->readResult = result;

        if (result == S_OK && frame) {
            frame->SetResolutionScale(blackmagicRawResolutionScaleHalf);
            frame->SetResourceFormat(blackmagicRawResourceFormatRGBAU8);

            IBlackmagicRawJob *decodeJob = nullptr;
            HRESULT decodeResult = frame->CreateJobDecodeAndProcessFrame(nullptr, nullptr, &decodeJob);
            if (decodeResult == S_OK && decodeJob) {
                HRESULT submitResult = decodeJob->Submit();
                if (submitResult != S_OK) {
                    _context->processResult = submitResult;
                    _context->error = "CreateJobDecodeAndProcessFrame submit failed";
                    decodeJob->Release();
                }
            } else {
                _context->processResult = decodeResult;
                _context->error = "CreateJobDecodeAndProcessFrame failed";
            }
        } else if (result != S_OK) {
            _context->error = "CreateJobReadFrame failed";
        }

        if (job) job->Release();
    }

    void DecodeComplete(IBlackmagicRawJob *, HRESULT) override {}

    void ProcessComplete(IBlackmagicRawJob *job, HRESULT result, IBlackmagicRawProcessedImage *processedImage) override {
        _context->sawProcess = true;
        _context->processResult = result;

        if (result == S_OK && processedImage) {
            processedImage->GetWidth(&_context->width);
            processedImage->GetHeight(&_context->height);
            processedImage->GetResourceType(&_context->resourceType);
            processedImage->GetResourceFormat(&_context->resourceFormat);
            processedImage->GetResourceSizeBytes(&_context->resourceSizeBytes);
        } else if (_context->error.empty()) {
            _context->error = "ProcessComplete returned failure";
        }

        if (job) job->Release();
    }

    void TrimProgress(IBlackmagicRawJob *, float) override {}
    void TrimComplete(IBlackmagicRawJob *, HRESULT) override {}
    void SidecarMetadataParseWarning(IBlackmagicRawClip *, CFStringRef, uint32_t, CFStringRef) override {}
    void SidecarMetadataParseError(IBlackmagicRawClip *, CFStringRef, uint32_t, CFStringRef) override {}
    void PreparePipelineComplete(void *, HRESULT) override {}

    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID, LPVOID *) override {
        return E_NOINTERFACE;
    }

    ULONG STDMETHODCALLTYPE AddRef(void) override { return 1; }
    ULONG STDMETHODCALLTYPE Release(void) override { return 1; }

private:
    SpliceKitBRAWDecodeContext *_context;
};

static NSArray<NSDictionary *> *SpliceKitBRAWFrameworkCandidates(void) {
    return @[
        @{
            @"binary": @"/Applications/Blackmagic RAW/Blackmagic RAW SDK/Mac/Libraries/BlackmagicRawAPI.framework/BlackmagicRawAPI",
            @"loadPath": @"/Applications/Blackmagic RAW/Blackmagic RAW SDK/Mac/Libraries",
        },
        @{
            @"binary": @"/Applications/Blackmagic RAW/Blackmagic RAW Player.app/Contents/Frameworks/BlackmagicRawAPI.framework/BlackmagicRawAPI",
            @"loadPath": @"/Applications/Blackmagic RAW/Blackmagic RAW Player.app/Contents/Frameworks",
        },
    ];
}

static IBlackmagicRawFactory *SpliceKitBRAWCreateFactory(NSString **frameworkBinaryOut,
                                                         NSString **frameworkLoadPathOut,
                                                         NSString **errorOut) {
    NSMutableArray<NSString *> *attempts = [NSMutableArray array];

    for (NSDictionary *candidate in SpliceKitBRAWFrameworkCandidates()) {
        NSString *binary = candidate[@"binary"];
        NSString *loadPath = candidate[@"loadPath"];

        if (![[NSFileManager defaultManager] fileExistsAtPath:binary]) {
            [attempts addObject:[NSString stringWithFormat:@"%@ (missing)", binary]];
            continue;
        }

        void *image = dlopen(binary.UTF8String, RTLD_NOW | RTLD_GLOBAL);
        if (!image) {
            const char *message = dlerror();
            [attempts addObject:[NSString stringWithFormat:@"%@ (dlopen failed: %s)",
                                 binary, message ?: "unknown"]];
            continue;
        }

        auto fromPath = (SpliceKitBRAWCreateFactoryFromPathFn)dlsym(image, "CreateBlackmagicRawFactoryInstanceFromPath");
        auto direct = (SpliceKitBRAWCreateFactoryFn)dlsym(image, "CreateBlackmagicRawFactoryInstance");

        IBlackmagicRawFactory *factory = nullptr;
        if (fromPath) {
            factory = fromPath((__bridge CFStringRef)loadPath);
        }
        if (!factory && direct) {
            factory = direct();
        }
        if (!factory) {
            [attempts addObject:[NSString stringWithFormat:@"%@ (factory creation returned null)", binary]];
            continue;
        }

        if (frameworkBinaryOut) *frameworkBinaryOut = binary;
        if (frameworkLoadPathOut) *frameworkLoadPathOut = loadPath;
        return factory;
    }

    if (errorOut) {
        *errorOut = attempts.count > 0
            ? [NSString stringWithFormat:@"Unable to load Blackmagic RAW SDK: %@",
               [attempts componentsJoinedByString:@"; "]]
            : @"Unable to load Blackmagic RAW SDK";
    }
    return nullptr;
}

static NSString *SpliceKitBRAWResolutionScaleName(BlackmagicRawResolutionScale scale) {
    switch (scale) {
        case blackmagicRawResolutionScaleFull: return @"full";
        case blackmagicRawResolutionScaleHalf: return @"half";
        case blackmagicRawResolutionScaleQuarter: return @"quarter";
        case blackmagicRawResolutionScaleEighth: return @"eighth";
        default: return [NSString stringWithFormat:@"0x%08X", (unsigned int)scale];
    }
}

static NSArray<NSDictionary *> *SpliceKitBRAWFallbackResolutions(uint32_t width, uint32_t height) {
    if (width == 0 || height == 0) return @[];

    const struct {
        NSString *__unsafe_unretained name;
        uint32_t divisor;
    } specs[] = {
        { @"full", 1 },
        { @"half", 2 },
        { @"quarter", 4 },
        { @"eighth", 8 },
    };

    NSMutableArray<NSDictionary *> *items = [NSMutableArray arrayWithCapacity:4];
    for (size_t i = 0; i < sizeof(specs) / sizeof(specs[0]); i++) {
        [items addObject:@{
            @"scale": specs[i].name,
            @"width": @(MAX((uint32_t)1, width / specs[i].divisor)),
            @"height": @(MAX((uint32_t)1, height / specs[i].divisor)),
        }];
    }
    return items;
}

static NSArray<NSDictionary *> *SpliceKitBRAWResolutionsForClip(IBlackmagicRawClip *clip,
                                                                uint32_t width,
                                                                uint32_t height) {
    NSMutableArray<NSDictionary *> *items = [NSMutableArray array];
    IBlackmagicRawClipResolutions *resolutions = nullptr;
    if (clip &&
        clip->QueryInterface(IID_IBlackmagicRawClipResolutions, (LPVOID *)&resolutions) == S_OK &&
        resolutions) {
        BlackmagicRawResolutionScale scales[] = {
            blackmagicRawResolutionScaleFull,
            blackmagicRawResolutionScaleHalf,
            blackmagicRawResolutionScaleQuarter,
            blackmagicRawResolutionScaleEighth,
        };
        for (BlackmagicRawResolutionScale scale : scales) {
            uint32_t scaledWidth = 0;
            uint32_t scaledHeight = 0;
            if (resolutions->GetClosestResolutionForScale(scale, &scaledWidth, &scaledHeight) == S_OK &&
                scaledWidth > 0 &&
                scaledHeight > 0) {
                [items addObject:@{
                    @"scale": SpliceKitBRAWResolutionScaleName(scale),
                    @"width": @(scaledWidth),
                    @"height": @(scaledHeight),
                }];
            }
        }

        if (items.count == 0) {
            uint32_t count = 0;
            if (resolutions->GetResolutionCount(&count) == S_OK) {
                for (uint32_t i = 0; i < MIN(count, (uint32_t)16); i++) {
                    uint32_t resolvedWidth = 0;
                    uint32_t resolvedHeight = 0;
                    uint32_t recordedWidth = 0;
                    uint32_t recordedHeight = 0;
                    if (resolutions->GetResolution(i, &resolvedWidth, &resolvedHeight) != S_OK ||
                        resolvedWidth == 0 ||
                        resolvedHeight == 0) {
                        continue;
                    }
                    NSMutableDictionary *entry = [@{
                        @"index": @(i),
                        @"width": @(resolvedWidth),
                        @"height": @(resolvedHeight),
                    } mutableCopy];
                    if (resolutions->GetRecordedResolution(i, &recordedWidth, &recordedHeight) == S_OK &&
                        recordedWidth > 0 &&
                        recordedHeight > 0) {
                        entry[@"recordedWidth"] = @(recordedWidth);
                        entry[@"recordedHeight"] = @(recordedHeight);
                    }
                    [items addObject:entry];
                }
            }
        }

        resolutions->Release();
    }

    if (items.count == 0) {
        [items addObjectsFromArray:SpliceKitBRAWFallbackResolutions(width, height)];
    }
    return items;
}

static void SpliceKitBRAWAddImmersiveInfo(IBlackmagicRawClip *clip,
                                          NSMutableDictionary *result,
                                          uint32_t width,
                                          uint32_t height,
                                          BOOL forceFallback) {
    if (!clip || !result) return;

    IBlackmagicRawClipImmersiveVideo *immersive = nullptr;
    BOOL hasImmersive = (clip->QueryInterface(IID_IBlackmagicRawClipImmersiveVideo,
                                              (LPVOID *)&immersive) == S_OK &&
                         immersive);
    if (!hasImmersive && !forceFallback) return;

    NSMutableDictionary *info = [@{
        @"available": @(hasImmersive),
        @"heroEye": @"right",
        @"heroEyeIndex": @1,
        @"resolutions": SpliceKitBRAWResolutionsForClip(clip, width, height),
    } mutableCopy];

    if (hasImmersive) {
        uint32_t distanceBetweenLenses = 0;
        int32_t comfortDisparityAdjustment = 0;
        uint32_t horizontalFieldOfView = 0;
        if (immersive->GetDistanceBetweenLenses(&distanceBetweenLenses) == S_OK) {
            info[@"distanceBetweenLenses"] = @(distanceBetweenLenses);
        }
        if (immersive->GetComfortDisparityAdjustment(&comfortDisparityAdjustment) == S_OK) {
            info[@"comfortDisparityAdjustment"] = @(comfortDisparityAdjustment);
        }
        if (immersive->GetHorizontalFieldOfView(&horizontalFieldOfView) == S_OK) {
            info[@"horizontalFieldOfView"] = @(horizontalFieldOfView);
        }

        NSMutableDictionary *attributes = [NSMutableDictionary dictionary];
        const struct {
            BlackmagicRawImmersiveAttribute attribute;
            NSString *__unsafe_unretained key;
        } attributeSpecs[] = {
            { blackmagicRawImmersiveAttributeOpticalLensProcessingDataFileUUID, @"opticalLensProcessingDataFileUUID" },
            { blackmagicRawImmersiveAttributeOpticalILPDFileName, @"opticalILPDFileName" },
            { blackmagicRawImmersiveAttributeOpticalInteraxial, @"opticalInteraxial" },
            { blackmagicRawImmersiveAttributeOpticalProjectionKind, @"opticalProjectionKind" },
            { blackmagicRawImmersiveAttributeOpticalCalibrationType, @"opticalCalibrationType" },
            { blackmagicRawImmersiveAttributeOpticalProjectionData, @"opticalProjectionData" },
        };
        for (size_t i = 0; i < sizeof(attributeSpecs) / sizeof(attributeSpecs[0]); i++) {
            Variant value;
            if (VariantInit(&value) != S_OK) continue;
            if (immersive->GetImmersiveAttribute(attributeSpecs[i].attribute, &value) == S_OK) {
                attributes[attributeSpecs[i].key] = SpliceKitBRAWVariantPreview(&value, 8) ?: (id)[NSNull null];
            }
            VariantClear(&value);
        }
        if (attributes.count > 0) info[@"attributes"] = attributes;

        immersive->Release();
    }

    result[@"immersive"] = info;
}

static void SpliceKitBRAWAppendPath(NSMutableOrderedSet<NSString *> *paths,
                                    NSMutableArray<NSDictionary *> *skipped,
                                    NSString *path,
                                    NSString *source) {
    if (path.length == 0) return;
    if (!SpliceKitBRAWIsClipPath(path)) {
        [skipped addObject:@{
            @"source": source ?: @"input",
            @"path": path,
            @"reason": @"Not a .braw clip",
        }];
        return;
    }
    [paths addObject:path];
}

static NSArray<NSString *> *SpliceKitBRAWResolveProbePaths(NSDictionary *params,
                                                           NSMutableArray<NSDictionary *> *skipped) {
    NSMutableOrderedSet<NSString *> *paths = [NSMutableOrderedSet orderedSet];

    NSString *singlePath = SpliceKitBRAWNormalizeProbePath(params[@"path"]);
    if (singlePath.length > 0) {
        SpliceKitBRAWAppendPath(paths, skipped, singlePath, @"path");
    }

    id manyPaths = params[@"paths"];
    if ([manyPaths isKindOfClass:[NSArray class]]) {
        for (id candidate in (NSArray *)manyPaths) {
            NSString *path = SpliceKitBRAWNormalizeProbePath(candidate);
            if (path.length > 0) {
                SpliceKitBRAWAppendPath(paths, skipped, path, @"paths");
            }
        }
    }

    NSString *singleHandle = [params[@"handle"] isKindOfClass:[NSString class]] ? params[@"handle"] : @"";
    if (singleHandle.length > 0) {
        id object = SpliceKit_resolveHandle(singleHandle);
        NSString *path = SpliceKitBRAWNormalizeProbePath(SpliceKitBRAWMediaURLForClipObject(object));
        if (path.length > 0) {
            SpliceKitBRAWAppendPath(paths, skipped, path, [NSString stringWithFormat:@"handle:%@", singleHandle]);
        } else {
            [skipped addObject:@{
                @"source": [NSString stringWithFormat:@"handle:%@", singleHandle],
                @"reason": @"Handle did not resolve to a clip media URL",
            }];
        }
    }

    id manyHandles = params[@"handles"];
    if ([manyHandles isKindOfClass:[NSArray class]]) {
        for (id value in (NSArray *)manyHandles) {
            if (![value isKindOfClass:[NSString class]]) continue;
            NSString *handle = (NSString *)value;
            id object = SpliceKit_resolveHandle(handle);
            NSString *path = SpliceKitBRAWNormalizeProbePath(SpliceKitBRAWMediaURLForClipObject(object));
            if (path.length > 0) {
                SpliceKitBRAWAppendPath(paths, skipped, path, [NSString stringWithFormat:@"handle:%@", handle]);
            } else {
                [skipped addObject:@{
                    @"source": [NSString stringWithFormat:@"handle:%@", handle],
                    @"reason": @"Handle did not resolve to a clip media URL",
                }];
            }
        }
    }

    BOOL shouldUseSelection = (paths.count == 0) || [params[@"selected"] boolValue];
    if (shouldUseSelection) {
        __block NSArray *selectedItems = @[];
        SpliceKit_executeOnMainThread(^{
            id timeline = SpliceKit_getActiveTimelineModule();
            if (!timeline) return;

            SEL richSel = NSSelectorFromString(@"selectedItems:includeItemBeforePlayheadIfLast:");
            if ([timeline respondsToSelector:richSel]) {
                id result = ((id (*)(id, SEL, BOOL, BOOL))objc_msgSend)(timeline, richSel, NO, NO);
                selectedItems = [SpliceKitBRAWArrayFromContainer(result) copy];
                if (selectedItems.count > 0) return;
            }

            SEL selectedSel = @selector(selectedItems);
            if ([timeline respondsToSelector:selectedSel]) {
                id result = ((id (*)(id, SEL))objc_msgSend)(timeline, selectedSel);
                selectedItems = [SpliceKitBRAWArrayFromContainer(result) copy];
            }
        });

        for (id item in selectedItems) {
            NSString *path = SpliceKitBRAWNormalizeProbePath(SpliceKitBRAWMediaURLForClipObject(item));
            if (path.length > 0) {
                SpliceKitBRAWAppendPath(paths, skipped, path, @"selected");
            } else {
                [skipped addObject:@{
                    @"source": @"selected",
                    @"reason": @"Selected item did not resolve to a clip media URL",
                }];
            }
        }
    }

    return paths.array;
}

static NSDictionary *SpliceKitBRAWProbeClip(IBlackmagicRawFactory *factory,
                                            NSString *path,
                                            NSInteger decodeFrameIndex,
                                            NSUInteger metadataLimit,
                                            BOOL includeMetadata,
                                            BOOL includeProcessing,
                                            BOOL includeAudio) {
    NSMutableDictionary *result = [@{
        @"path": path ?: @"",
    } mutableCopy];

    if (path.length == 0) {
        result[@"error"] = @"Missing clip path";
        return result;
    }

    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        result[@"error"] = @"Clip path does not exist";
        return result;
    }

    IBlackmagicRaw *codec = nullptr;
    IBlackmagicRawClip *clip = nullptr;
    IBlackmagicRawConfiguration *configuration = nullptr;

    HRESULT status = factory->CreateCodec(&codec);
    if (status != S_OK || !codec) {
        result[@"error"] = [NSString stringWithFormat:@"CreateCodec failed (%@)", SpliceKitBRAWHRESULTString(status)];
        return result;
    }

    status = codec->QueryInterface(IID_IBlackmagicRawConfiguration, (LPVOID *)&configuration);
    if (status == S_OK && configuration) {
        configuration->SetPipeline(blackmagicRawPipelineCPU, nullptr, nullptr);

        CFStringRef sdkVersionRef = nullptr;
        if (configuration->GetVersion(&sdkVersionRef) == S_OK && sdkVersionRef) {
            result[@"sdkVersion"] = SpliceKitBRAWCopyNSString(sdkVersionRef);
        }

        CFStringRef supportVersionRef = nullptr;
        if (configuration->GetCameraSupportVersion(&supportVersionRef) == S_OK && supportVersionRef) {
            result[@"cameraSupportVersion"] = SpliceKitBRAWCopyNSString(supportVersionRef);
        }

        uint32_t cpuThreads = 0;
        if (configuration->GetCPUThreads(&cpuThreads) == S_OK) {
            result[@"cpuThreads"] = @(cpuThreads);
        }
    }

    status = codec->OpenClip((__bridge CFStringRef)path, &clip);
    if (status != S_OK || !clip) {
        result[@"error"] = [NSString stringWithFormat:@"OpenClip failed (%@)", SpliceKitBRAWHRESULTString(status)];
        if (configuration) configuration->Release();
        codec->Release();
        return result;
    }

    uint32_t width = 0;
    uint32_t height = 0;
    float frameRate = 0.0f;
    uint64_t frameCount = 0;
    bool sidecarAttached = false;
    uint32_t multicardFileCount = 0;

    if (clip->GetWidth(&width) == S_OK) result[@"width"] = @(width);
    if (clip->GetHeight(&height) == S_OK) result[@"height"] = @(height);
    if (clip->GetFrameRate(&frameRate) == S_OK) result[@"frameRate"] = @(frameRate);
    if (clip->GetFrameCount(&frameCount) == S_OK) result[@"frameCount"] = @(frameCount);
    if (clip->GetSidecarFileAttached(&sidecarAttached) == S_OK) result[@"sidecarAttached"] = @(sidecarAttached);
    if (clip->GetMulticardFileCount(&multicardFileCount) == S_OK) result[@"multicardFileCount"] = @(multicardFileCount);

    SpliceKitBRAWAddImmersiveInfo(clip, result, width, height, NO);

    if (includeMetadata) {
        CFStringRef timecodeRef = nullptr;
        if (frameCount > 0 && clip->GetTimecodeForFrame(0, &timecodeRef) == S_OK && timecodeRef) {
            result[@"startTimecode"] = SpliceKitBRAWCopyNSString(timecodeRef);
        }

        CFStringRef cameraTypeRef = nullptr;
        if (clip->GetCameraType(&cameraTypeRef) == S_OK && cameraTypeRef) {
            result[@"cameraType"] = SpliceKitBRAWCopyNSString(cameraTypeRef);
        }

        IBlackmagicRawMetadataIterator *metadataIterator = nullptr;
        if (clip->GetMetadataIterator(&metadataIterator) == S_OK && metadataIterator) {
            result[@"metadataSample"] = SpliceKitBRAWMetadataSample(metadataIterator, metadataLimit);
            metadataIterator->Release();
        }
    }

    IBlackmagicRawClipProcessingAttributes *clipAttributes = nullptr;
    if (includeProcessing &&
        clip->CloneClipProcessingAttributes(&clipAttributes) == S_OK &&
        clipAttributes) {
        NSMutableDictionary *processing = [NSMutableDictionary dictionary];

        struct ClipAttributeSpec {
            BlackmagicRawClipProcessingAttribute attribute;
            NSString *key;
        };

        const ClipAttributeSpec attributeSpecs[] = {
            { blackmagicRawClipProcessingAttributeGamma, @"gamma" },
            { blackmagicRawClipProcessingAttributeGamut, @"gamut" },
            { blackmagicRawClipProcessingAttributeColorScienceGen, @"colorScienceGen" },
            { blackmagicRawClipProcessingAttributeHighlightRecovery, @"highlightRecovery" },
        };

        for (const ClipAttributeSpec &spec : attributeSpecs) {
            Variant value;
            if (VariantInit(&value) != S_OK) continue;
            if (clipAttributes->GetClipAttribute(spec.attribute, &value) == S_OK) {
                processing[spec.key] = SpliceKitBRAWVariantPreview(&value, 8) ?: (id)[NSNull null];
            }
            VariantClear(&value);
        }

        uint32_t isoValues[32] = {0};
        uint32_t isoCount = 32;
        bool isoReadOnly = false;
        if (clipAttributes->GetISOList(isoValues, &isoCount, &isoReadOnly) == S_OK && isoCount > 0) {
            NSMutableArray *isoList = [NSMutableArray arrayWithCapacity:isoCount];
            for (uint32_t i = 0; i < isoCount; i++) {
                [isoList addObject:@(isoValues[i])];
            }
            processing[@"isoList"] = isoList;
            processing[@"isoListReadOnly"] = @(isoReadOnly);
        }

        IBlackmagicRawPost3DLUT *lut = nullptr;
        if (clipAttributes->GetPost3DLUT(&lut) == S_OK && lut) {
            NSMutableDictionary *lutInfo = [NSMutableDictionary dictionary];
            CFStringRef nameRef = nullptr;
            CFStringRef titleRef = nullptr;
            uint32_t lutSize = 0;
            if (lut->GetName(&nameRef) == S_OK && nameRef) lutInfo[@"name"] = SpliceKitBRAWCopyNSString(nameRef);
            if (lut->GetTitle(&titleRef) == S_OK && titleRef) lutInfo[@"title"] = SpliceKitBRAWCopyNSString(titleRef);
            if (lut->GetSize(&lutSize) == S_OK) lutInfo[@"size"] = @(lutSize);
            if (lutInfo.count > 0) processing[@"post3DLUT"] = lutInfo;
            lut->Release();
        }

        if (processing.count > 0) result[@"processing"] = processing;
        clipAttributes->Release();
    }

    IBlackmagicRawClipAudio *audio = nullptr;
    if (includeAudio &&
        clip->QueryInterface(IID_IBlackmagicRawClipAudio, (LPVOID *)&audio) == S_OK &&
        audio) {
        NSMutableDictionary *audioInfo = [NSMutableDictionary dictionary];
        BlackmagicRawAudioFormat audioFormat = blackmagicRawAudioFormatPCMLittleEndian;
        uint32_t bitDepth = 0;
        uint32_t channelCount = 0;
        uint32_t sampleRate = 0;
        uint64_t sampleCount = 0;

        if (audio->GetAudioFormat(&audioFormat) == S_OK) {
            audioInfo[@"format"] = [NSString stringWithFormat:@"0x%08X", audioFormat];
        }
        if (audio->GetAudioBitDepth(&bitDepth) == S_OK) audioInfo[@"bitDepth"] = @(bitDepth);
        if (audio->GetAudioChannelCount(&channelCount) == S_OK) audioInfo[@"channelCount"] = @(channelCount);
        if (audio->GetAudioSampleRate(&sampleRate) == S_OK) audioInfo[@"sampleRate"] = @(sampleRate);
        if (audio->GetAudioSampleCount(&sampleCount) == S_OK) audioInfo[@"sampleCount"] = @(sampleCount);

        if (audioInfo.count > 0) result[@"audio"] = audioInfo;
        audio->Release();
    }

    if (decodeFrameIndex >= 0 && frameCount > 0) {
        NSInteger clampedIndex = MIN((NSInteger)frameCount - 1, MAX((NSInteger)0, decodeFrameIndex));
        SpliceKitBRAWDecodeContext decodeContext;
        SpliceKitBRAWDecodeCallback callback(&decodeContext);

        status = codec->SetCallback(&callback);
        if (status != S_OK) {
            result[@"decode"] = @{
                @"frameIndex": @(clampedIndex),
                @"error": [NSString stringWithFormat:@"SetCallback failed (%@)", SpliceKitBRAWHRESULTString(status)],
            };
        } else {
            IBlackmagicRawJob *readJob = nullptr;
            status = clip->CreateJobReadFrame((uint64_t)clampedIndex, &readJob);
            if (status == S_OK && readJob) {
                status = readJob->Submit();
                if (status != S_OK) {
                    readJob->Release();
                } else {
                    codec->FlushJobs();
                }
            }

            NSMutableDictionary *decode = [@{
                @"frameIndex": @(clampedIndex),
            } mutableCopy];

            if (status != S_OK) {
                decode[@"error"] = [NSString stringWithFormat:@"CreateJobReadFrame/Submit failed (%@)",
                                     SpliceKitBRAWHRESULTString(status)];
            } else {
                decode[@"readResult"] = SpliceKitBRAWHRESULTString(decodeContext.readResult);
                decode[@"processResult"] = SpliceKitBRAWHRESULTString(decodeContext.processResult);
                decode[@"sawRead"] = @(decodeContext.sawRead);
                decode[@"sawProcess"] = @(decodeContext.sawProcess);
                if (decodeContext.sawProcess && decodeContext.processResult == S_OK) {
                    decode[@"width"] = @(decodeContext.width);
                    decode[@"height"] = @(decodeContext.height);
                    decode[@"resourceFormat"] = SpliceKitBRAWResourceFormatName(decodeContext.resourceFormat);
                    decode[@"resourceType"] = SpliceKitBRAWResourceTypeName(decodeContext.resourceType);
                    decode[@"resourceSizeBytes"] = @(decodeContext.resourceSizeBytes);
                    decode[@"resolutionScale"] = @"half";
                }
                if (!decodeContext.error.empty()) {
                    decode[@"error"] = [NSString stringWithUTF8String:decodeContext.error.c_str()];
                }
            }

            result[@"decode"] = decode;
        }
    }

    clip->Release();
    if (configuration) configuration->Release();
    codec->Release();
    return result;
}

SPLICEKIT_BRAW_EXTERN_C NSDictionary *SpliceKit_handleBRAWProbe(NSDictionary *params) {
    NSUInteger metadataLimit = 16;
    if ([params[@"metadataLimit"] respondsToSelector:@selector(unsignedIntegerValue)]) {
        metadataLimit = MAX((NSUInteger)1, [params[@"metadataLimit"] unsignedIntegerValue]);
    }

    NSInteger decodeFrameIndex = -1;
    if ([params[@"decodeFrameIndex"] respondsToSelector:@selector(integerValue)]) {
        decodeFrameIndex = [params[@"decodeFrameIndex"] integerValue];
    }

    BOOL includeMetadata = [params[@"includeMetadata"] boolValue];
    BOOL includeProcessing = [params[@"includeProcessing"] boolValue];
    BOOL includeAudio = [params[@"includeAudio"] boolValue];

    NSMutableArray<NSDictionary *> *skipped = [NSMutableArray array];
    NSArray<NSString *> *paths = SpliceKitBRAWResolveProbePaths(params, skipped);
    if (paths.count == 0) {
        return SpliceKitBRAWErrorResult(@"No .braw paths were resolved. Provide `path`/`handle`, or select a .braw clip in the active timeline.");
    }

    NSString *frameworkBinary = nil;
    NSString *frameworkLoadPath = nil;
    NSString *loadError = nil;
    IBlackmagicRawFactory *factory = SpliceKitBRAWCreateFactory(&frameworkBinary, &frameworkLoadPath, &loadError);
    if (!factory) {
        return SpliceKitBRAWErrorResult(loadError);
    }

    NSMutableArray<NSDictionary *> *clips = [NSMutableArray arrayWithCapacity:paths.count];
    for (NSString *path in paths) {
        [clips addObject:SpliceKitBRAWProbeClip(factory,
                                                path,
                                                decodeFrameIndex,
                                                metadataLimit,
                                                includeMetadata,
                                                includeProcessing,
                                                includeAudio)];
    }

    factory->Release();

    return @{
        @"status": @"ok",
        @"frameworkBinary": frameworkBinary ?: @"",
        @"frameworkLoadPath": frameworkLoadPath ?: @"",
        @"paths": paths,
        @"skipped": skipped,
        @"clips": clips,
    };
}

SPLICEKIT_BRAW_EXTERN_C NSDictionary *SpliceKit_handleBRAWDescribeImmersive(NSDictionary *params) {
    NSMutableDictionary *probeParams = [params isKindOfClass:[NSDictionary class]]
        ? [params mutableCopy]
        : [NSMutableDictionary dictionary];
    probeParams[@"includeMetadata"] = @YES;
    probeParams[@"includeProcessing"] = @YES;
    probeParams[@"includeAudio"] = @NO;

    NSDictionary *probe = SpliceKit_handleBRAWProbe(probeParams);
    if (probe[@"error"]) return probe;

    NSMutableDictionary *result = [probe mutableCopy];
    NSArray *clips = [probe[@"clips"] isKindOfClass:[NSArray class]] ? probe[@"clips"] : @[];
    NSMutableArray *decoratedClips = [NSMutableArray arrayWithCapacity:clips.count];
    for (id item in clips) {
        if (![item isKindOfClass:[NSDictionary class]]) continue;
        NSMutableDictionary *clip = [(NSDictionary *)item mutableCopy];
        if (![clip[@"immersive"] isKindOfClass:[NSDictionary class]]) {
            uint32_t width = [clip[@"width"] respondsToSelector:@selector(unsignedIntValue)]
                ? [clip[@"width"] unsignedIntValue]
                : 0;
            uint32_t height = [clip[@"height"] respondsToSelector:@selector(unsignedIntValue)]
                ? [clip[@"height"] unsignedIntValue]
                : 0;
            if (width > 0 && height > 0) {
                clip[@"immersive"] = @{
                    @"available": @NO,
                    @"heroEye": @"right",
                    @"heroEyeIndex": @1,
                    @"resolutions": SpliceKitBRAWFallbackResolutions(width, height),
                    @"source": @"fallback",
                };
            }
        }
        [decoratedClips addObject:clip];
    }
    result[@"clips"] = decoratedClips;
    result[@"status"] = probe[@"status"] ?: @"ok";
    return result;
}

template <typename MotionT>
static NSDictionary *SpliceKitBRAWMotionDictionary(MotionT *motion,
                                                   uint64_t startIndex,
                                                   uint32_t requestedCount) {
    if (!motion) return @{@"available": @NO};

    float sampleRate = 0.0f;
    uint32_t totalCount = 0;
    uint32_t sampleSize = 0;
    HRESULT rateStatus = motion->GetSampleRate(&sampleRate);
    HRESULT countStatus = motion->GetSampleCount(&totalCount);
    HRESULT sizeStatus = motion->GetSampleSize(&sampleSize);
    if (rateStatus != S_OK || countStatus != S_OK || sizeStatus != S_OK || sampleSize == 0) {
        return @{
            @"available": @NO,
            @"sampleRateStatus": SpliceKitBRAWHRESULTString(rateStatus),
            @"sampleCountStatus": SpliceKitBRAWHRESULTString(countStatus),
            @"sampleSizeStatus": SpliceKitBRAWHRESULTString(sizeStatus),
        };
    }

    uint64_t remaining = startIndex < totalCount ? ((uint64_t)totalCount - startIndex) : 0;
    uint32_t readCount = (uint32_t)MIN((uint64_t)requestedCount, remaining);
    NSMutableDictionary *summary = [@{
        @"available": @YES,
        @"sampleRate": @(sampleRate),
        @"sampleCount": @(totalCount),
        @"sampleSize": @(sampleSize),
        @"startIndex": @(startIndex),
        @"requestedCount": @(requestedCount),
        @"returnedCount": @0,
        @"samples": @[],
    } mutableCopy];
    if (readCount == 0) return summary;

    std::vector<float> values((size_t)readCount * (size_t)sampleSize);
    uint32_t samplesRead = 0;
    HRESULT readStatus = motion->GetSampleRange(startIndex,
                                                readCount,
                                                values.data(),
                                                &samplesRead);
    if (readStatus != S_OK) {
        summary[@"available"] = @NO;
        summary[@"readStatus"] = SpliceKitBRAWHRESULTString(readStatus);
        return summary;
    }

    NSMutableArray *samples = [NSMutableArray arrayWithCapacity:samplesRead];
    for (uint32_t sampleIndex = 0; sampleIndex < samplesRead; sampleIndex++) {
        NSMutableArray *components = [NSMutableArray arrayWithCapacity:sampleSize];
        size_t base = (size_t)sampleIndex * (size_t)sampleSize;
        for (uint32_t component = 0; component < sampleSize; component++) {
            [components addObject:@(values[base + component])];
        }
        [samples addObject:components];
    }
    summary[@"returnedCount"] = @(samplesRead);
    summary[@"samples"] = samples;
    return summary;
}

SPLICEKIT_BRAW_EXTERN_C NSDictionary *SpliceKit_handleBRAWReadMotionSamples(NSDictionary *params) {
    uint64_t startIndex = [params[@"startIndex"] respondsToSelector:@selector(unsignedLongLongValue)]
        ? [params[@"startIndex"] unsignedLongLongValue]
        : 0;
    uint32_t requestedCount = 64;
    if ([params[@"sampleCount"] respondsToSelector:@selector(unsignedIntValue)]) {
        requestedCount = [params[@"sampleCount"] unsignedIntValue];
    } else if ([params[@"motionPreviewCount"] respondsToSelector:@selector(unsignedIntValue)]) {
        requestedCount = [params[@"motionPreviewCount"] unsignedIntValue];
    } else if ([params[@"maxSamples"] respondsToSelector:@selector(unsignedIntValue)]) {
        requestedCount = [params[@"maxSamples"] unsignedIntValue];
    }
    requestedCount = MAX((uint32_t)1, MIN(requestedCount, (uint32_t)4096));

    NSMutableArray<NSDictionary *> *skipped = [NSMutableArray array];
    NSArray<NSString *> *paths = SpliceKitBRAWResolveProbePaths(params, skipped);
    if (paths.count == 0) {
        return SpliceKitBRAWErrorResult(@"No .braw paths were resolved. Provide `path`/`handle`, or select a .braw clip in the active timeline.");
    }
    NSString *path = paths.firstObject;

    NSString *frameworkBinary = nil;
    NSString *frameworkLoadPath = nil;
    NSString *loadError = nil;
    IBlackmagicRawFactory *factory = SpliceKitBRAWCreateFactory(&frameworkBinary, &frameworkLoadPath, &loadError);
    if (!factory) {
        return SpliceKitBRAWErrorResult(loadError);
    }

    IBlackmagicRaw *codec = nullptr;
    IBlackmagicRawClip *clip = nullptr;
    HRESULT status = factory->CreateCodec(&codec);
    if (status != S_OK || !codec) {
        factory->Release();
        return SpliceKitBRAWErrorResult([NSString stringWithFormat:@"CreateCodec failed (%@)", SpliceKitBRAWHRESULTString(status)]);
    }

    status = codec->OpenClip((__bridge CFStringRef)path, &clip);
    if (status != S_OK || !clip) {
        codec->Release();
        factory->Release();
        return SpliceKitBRAWErrorResult([NSString stringWithFormat:@"OpenClip failed (%@)", SpliceKitBRAWHRESULTString(status)]);
    }

    IBlackmagicRawClipAccelerometerMotion *accelerometer = nullptr;
    IBlackmagicRawClipGyroscopeMotion *gyroscope = nullptr;
    NSDictionary *accelerometerInfo = nil;
    NSDictionary *gyroscopeInfo = nil;

    if (clip->QueryInterface(IID_IBlackmagicRawClipAccelerometerMotion, (LPVOID *)&accelerometer) == S_OK &&
        accelerometer) {
        accelerometerInfo = SpliceKitBRAWMotionDictionary(accelerometer, startIndex, requestedCount);
        accelerometer->Release();
    } else {
        accelerometerInfo = @{@"available": @NO};
    }

    if (clip->QueryInterface(IID_IBlackmagicRawClipGyroscopeMotion, (LPVOID *)&gyroscope) == S_OK &&
        gyroscope) {
        gyroscopeInfo = SpliceKitBRAWMotionDictionary(gyroscope, startIndex, requestedCount);
        gyroscope->Release();
    } else {
        gyroscopeInfo = @{@"available": @NO};
    }

    clip->Release();
    codec->Release();
    factory->Release();

    return @{
        @"status": @"ok",
        @"frameworkBinary": frameworkBinary ?: @"",
        @"frameworkLoadPath": frameworkLoadPath ?: @"",
        @"path": path ?: @"",
        @"skipped": skipped,
        @"accelerometer": accelerometerInfo ?: @{@"available": @NO},
        @"gyroscope": gyroscopeInfo ?: @{@"available": @NO},
    };
}

SPLICEKIT_BRAW_EXTERN_C NSDictionary *SpliceKit_handleBRAWAVProbe(NSDictionary *params) {
    NSString *path = params[@"path"];
    if (![path isKindOfClass:[NSString class]] || path.length == 0) {
        return SpliceKitBRAWErrorResult(@"avProbe requires `path`");
    }
    NSURL *url = [NSURL fileURLWithPath:path];
    NSDictionary *opts = @{ @"AVURLAssetOverrideMIMETypeKey": @"video/quicktime" };
    AVURLAsset *asset = [[AVURLAsset alloc] initWithURL:url options:opts];
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    result[@"path"] = path;

    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [asset loadValuesAsynchronouslyForKeys:@[@"tracks", @"duration", @"playable"] completionHandler:^{
        dispatch_semaphore_signal(sem);
    }];
    (void)dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 10LL * NSEC_PER_SEC));

    NSError *err = nil;
    AVKeyValueStatus status = [asset statusOfValueForKey:@"tracks" error:&err];
    result[@"tracksStatus"] = @((int)status);
    if (err) result[@"tracksError"] = err.localizedDescription ?: err.description;
    result[@"trackCount"] = @(asset.tracks.count);
    result[@"playable"] = @(asset.isPlayable);
    result[@"readable"] = @(asset.isReadable);

    NSMutableArray *tracks = [NSMutableArray array];
    for (AVAssetTrack *track in asset.tracks) {
        NSMutableDictionary *t = [NSMutableDictionary dictionary];
        t[@"type"] = track.mediaType ?: @"?";
        t[@"enabled"] = @(track.isEnabled);
        t[@"playable"] = @(track.isPlayable);
        t[@"decodable"] = @(track.isDecodable);
        NSMutableArray *fds = [NSMutableArray array];
        for (id fd in track.formatDescriptions) {
            CMFormatDescriptionRef f = (__bridge CMFormatDescriptionRef)fd;
            FourCharCode st = CMFormatDescriptionGetMediaSubType(f);
            char c[5] = { (char)((st>>24)&0xff), (char)((st>>16)&0xff), (char)((st>>8)&0xff), (char)(st&0xff), 0 };
            NSMutableDictionary *fdDict = [NSMutableDictionary dictionary];
            fdDict[@"fourcc"] = [NSString stringWithUTF8String:c];
            if (CMFormatDescriptionGetMediaType(f) == kCMMediaType_Video) {
                CMVideoDimensions dims = CMVideoFormatDescriptionGetDimensions(f);
                fdDict[@"width"] = @(dims.width);
                fdDict[@"height"] = @(dims.height);
                fdDict[@"hasExtensions"] = @(CMFormatDescriptionGetExtensions(f) != NULL);
            }
            [fds addObject:fdDict];
        }
        t[@"formatDescriptions"] = fds;
        [tracks addObject:t];
    }
    result[@"tracks"] = tracks;

    AVAssetTrack *videoTrack = [[asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
    if (videoTrack) {
        NSError *readerErr = nil;
        AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:asset error:&readerErr];
        if (readerErr) result[@"readerInitError"] = readerErr.localizedDescription;
        if (reader) {
            NSDictionary *outputSettings = @{ (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA) };
            AVAssetReaderTrackOutput *output = [[AVAssetReaderTrackOutput alloc] initWithTrack:videoTrack outputSettings:outputSettings];
            if ([reader canAddOutput:output]) {
                [reader addOutput:output];
                BOOL started = [reader startReading];
                result[@"readerStartReading"] = @(started);
                if (started) {
                    CMSampleBufferRef sample = [output copyNextSampleBuffer];
                    if (sample) {
                        CVImageBufferRef pb = CMSampleBufferGetImageBuffer(sample);
                        result[@"sampleValid"] = @(pb != NULL);
                        if (pb) {
                            result[@"sampleWidth"] = @(CVPixelBufferGetWidth(pb));
                            result[@"sampleHeight"] = @(CVPixelBufferGetHeight(pb));
                        }
                        CFRelease(sample);
                    } else {
                        result[@"sampleValid"] = @NO;
                        if (reader.error) result[@"readerError"] = reader.error.localizedDescription;
                        result[@"readerStatus"] = @(reader.status);
                    }
                    [reader cancelReading];
                }
            } else {
                result[@"canAddOutput"] = @NO;
            }
        }
    }
    return @{ @"status": @"ok", @"result": result };
}

SPLICEKIT_BRAW_EXTERN_C NSDictionary *SpliceKit_handleBRAWProviderProbe(NSDictionary *params) {
    SpliceKitBRAWTrace([NSString stringWithFormat:@"[providerProbe] begin params=%@", params ?: @{}]);
    NSMutableArray<NSDictionary *> *skipped = [NSMutableArray array];
    NSArray<NSString *> *paths = SpliceKitBRAWResolveProbePaths(params, skipped);
    if (paths.count == 0) {
        SpliceKitBRAWTrace(@"[providerProbe] no paths resolved");
        return SpliceKitBRAWErrorResult(@"No .braw paths were resolved. Provide `path`/`handle`, or select a .braw clip in the active timeline.");
    }

    BOOL installProviderShim = [params[@"installProviderShim"] boolValue];
    BOOL registerWorkflowPlugins = [params[@"registerWorkflowPlugins"] boolValue];
    BOOL installUTIHook = [params[@"installUTIHook"] boolValue];
    BOOL installAVHook = [params[@"installAVHook"] boolValue];
    BOOL includeProviderValidation = [params[@"includeProviderValidation"] boolValue];
    NSString *installPhase = [params[@"installPhase"] isKindOfClass:[NSString class]] ? params[@"installPhase"] : @"both";
    BOOL installOnMainThread = [params[@"installOnMainThread"] boolValue];
    __block BOOL installResult = NO;
    NSMutableDictionary *installDiagnostics = [NSMutableDictionary dictionary];

    if (installUTIHook) {
        BOOL utiInstalled = SpliceKit_installBRAWUTITypeConformanceHook();
        installDiagnostics[@"utiConformanceHookInstalled"] = @(utiInstalled);
        SpliceKitBRAWTrace([NSString stringWithFormat:@"[providerProbe] UTI hook install result=%@", utiInstalled ? @"YES" : @"NO"]);
    }
    if (installAVHook) {
        BOOL avInstalled = SpliceKit_installBRAWAVURLAssetMIMEHook();
        installDiagnostics[@"avURLAssetMIMEHookInstalled"] = @(avInstalled);
        SpliceKitBRAWTrace([NSString stringWithFormat:@"[providerProbe] AV hook install result=%@", avInstalled ? @"YES" : @"NO"]);
    }
    if (installProviderShim) {
        if (installOnMainThread) {
            SpliceKitBRAWTrace(@"[providerProbe] install provider shim on main thread begin");
            SpliceKit_executeOnMainThread(^{
                installResult = SpliceKitBRAWRegisterProviderShimPhase(installPhase, installDiagnostics);
            });
            SpliceKitBRAWTrace([NSString stringWithFormat:@"[providerProbe] install provider shim on main thread end result=%@", installResult ? @"YES" : @"NO"]);
        } else {
            SpliceKitBRAWTrace(@"[providerProbe] install provider shim begin");
            installResult = SpliceKitBRAWRegisterProviderShimPhase(installPhase, installDiagnostics);
            SpliceKitBRAWTrace([NSString stringWithFormat:@"[providerProbe] install provider shim end result=%@", installResult ? @"YES" : @"NO"]);
        }
        if (![params[@"returnStateAfterInstall"] boolValue]) {
            SpliceKitBRAWTrace(@"[providerProbe] returning after install only");
            return @{
                @"status": @"ok",
                @"paths": paths,
                @"skipped": skipped,
                @"providerShimInstalled": @(installResult),
                @"registerWorkflowPlugins": @(registerWorkflowPlugins),
                @"installPhase": installPhase,
                @"installOnMainThread": @(installOnMainThread),
                @"installDiagnostics": installDiagnostics,
                @"includeProviderValidation": @(includeProviderValidation),
            };
        }
    }

    if (registerWorkflowPlugins) {
        SpliceKitBRAWTrace(@"[providerProbe] register workflow plugins begin");
        SpliceKitBRAWRegisterProfessionalWorkflowPlugins(installDiagnostics);
        SpliceKitBRAWTrace(@"[providerProbe] register workflow plugins end");
        ((void (*)(id, SEL, id))objc_msgSend)(
            objc_getClass("FFProviderFig"),
            NSSelectorFromString(@"invalidateMediaReaderForURL:"),
            [NSURL fileURLWithPath:paths.firstObject]);
        SpliceKitBRAWTrace(@"[providerProbe] invalidated media reader cache");
    }

    SpliceKitBRAWTrace(@"[providerProbe] validating provider state");
    NSMutableDictionary *result = [[SpliceKitBRAWProviderProbeForPath(paths.firstObject, includeProviderValidation) mutableCopy] ?: [NSMutableDictionary dictionary] mutableCopy];
    result[@"status"] = result[@"error"] ? @"error" : @"ok";
    result[@"paths"] = paths;
    result[@"skipped"] = skipped;
    result[@"providerShimInstalled"] = @(installProviderShim && installResult);
    result[@"registerWorkflowPlugins"] = @(registerWorkflowPlugins);
    result[@"installUTIHook"] = @(installUTIHook);
    result[@"installAVHook"] = @(installAVHook);
    result[@"installPhase"] = installPhase;
    result[@"installOnMainThread"] = @(installOnMainThread);
    result[@"installDiagnostics"] = installDiagnostics;
    result[@"includeProviderValidation"] = @(includeProviderValidation);
    SpliceKitBRAWTrace([NSString stringWithFormat:@"[providerProbe] end status=%@", result[@"status"] ?: @"<nil>"]);
    return result;
}

#pragma mark - Host-side BRAW decode helper for VT plugin

// The VT-loaded decoder bundle cannot safely call the BRAW SDK directly —
// callbacks fire on BRAW worker threads in a context where vtable dispatch
// fails (EXC_BAD_ACCESS / PAC-style faults). The host process (this module)
// has no such problem; braw.probe decodes the same file end-to-end. So we
// expose a sync decode helper here and have the decoder bundle call it via
// dlsym(RTLD_DEFAULT, "SpliceKitBRAW_DecodeFrameBytes").
//
// Decode path:
//   1. Per-clip: configure Metal pipeline if supported (else CPU).
//   2. BRAW SDK decodes on GPU, emits a Metal BGRAU8 MTLBuffer (shared storage).
//   3. ProcessComplete encodes a GPU blit from that MTLBuffer into an
//      IOSurface-backed MTLTexture that wraps the destination CVPixelBuffer —
//      no CPU-visible copies of the ~170 MB frame.
//   4. If the caller didn't provide a CVPixelBuffer (legacy bytes API) or
//      Metal isn't available, fall back to CPU readback.

namespace {

static id<MTLDevice> SpliceKitBRAWMetalDevice() {
    static id<MTLDevice> device = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        device = MTLCreateSystemDefaultDevice();
        if (!device) {
            SpliceKitBRAWTrace(@"[metal] no default device; will fall back to CPU pipeline");
        }
    });
    return device;
}

static id<MTLCommandQueue> SpliceKitBRAWMetalCommandQueue() {
    static id<MTLCommandQueue> queue = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        id<MTLDevice> device = SpliceKitBRAWMetalDevice();
        if (device) queue = [device newCommandQueue];
    });
    return queue;
}

static CVMetalTextureCacheRef SpliceKitBRAWMetalTextureCache() {
    static CVMetalTextureCacheRef cache = nullptr;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        id<MTLDevice> device = SpliceKitBRAWMetalDevice();
        if (device) {
            CVReturn cvr = CVMetalTextureCacheCreate(
                kCFAllocatorDefault, nullptr, device, nullptr, &cache);
            if (cvr != kCVReturnSuccess) {
                SpliceKitBRAWTrace([NSString stringWithFormat:
                    @"[metal] CVMetalTextureCacheCreate failed cvr=%d", cvr]);
                cache = nullptr;
            }
        }
    });
    return cache;
}

struct SpliceKitBRAWHostDecodeContext {
    std::mutex mutex;
    std::condition_variable cv;
    bool finished { false };
    HRESULT readResult { E_FAIL };
    HRESULT processResult { E_FAIL };
    std::string error;
    std::vector<uint8_t> bytes;
    uint32_t width { 0 };
    uint32_t height { 0 };
    uint32_t resourceSizeBytes { 0 };
    BlackmagicRawResolutionScale scale { blackmagicRawResolutionScaleHalf };
    BlackmagicRawResourceFormat format { blackmagicRawResourceFormatRGBAU8 };

    // Zero-copy Metal target: if set, ProcessComplete blits the SDK's MTLBuffer
    // directly into this CVPixelBuffer's IOSurface-backed MTLTexture instead of
    // copying bytes through CPU memory.
    CVPixelBufferRef destPixelBuffer { nullptr };
    CFDictionaryRef rawSettings { nullptr };
    IBlackmagicRawClipProcessingAttributes *clipProcessingAttributes { nullptr };
};

static NSNumber *SpliceKitBRAWRAWNumberForKey(CFDictionaryRef settingsRef, NSString *key) {
    if (!settingsRef || key.length == 0) {
        return nil;
    }
    NSDictionary *settings = (__bridge NSDictionary *)settingsRef;
    id value = settings[key];
    if ([value isKindOfClass:[NSNumber class]]) {
        return value;
    }
    if ([value isKindOfClass:[NSString class]]) {
        NSString *string = [(NSString *)value stringByTrimmingCharactersInSet:
                            [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (string.length == 0) {
            return nil;
        }
        return @([string doubleValue]);
    }
    return nil;
}

static BOOL SpliceKitBRAWSetVariantFromNumber(Variant *variant, NSNumber *number) {
    if (!variant || !number) {
        return NO;
    }

    switch (variant->vt) {
        case blackmagicRawVariantTypeU8:
        case blackmagicRawVariantTypeU16:
            variant->uiVal = (uint16_t)MAX(0, number.integerValue);
            return YES;
        case blackmagicRawVariantTypeS16:
            variant->iVal = (int16_t)number.integerValue;
            return YES;
        case blackmagicRawVariantTypeS32:
            variant->intVal = (int32_t)number.intValue;
            return YES;
        case blackmagicRawVariantTypeU32:
            variant->uintVal = (uint32_t)MAX(0, number.unsignedIntValue);
            return YES;
        case blackmagicRawVariantTypeFloat32:
            variant->fltVal = number.floatValue;
            return YES;
        case blackmagicRawVariantTypeFloat64:
            variant->dblVal = number.doubleValue;
            return YES;
        default:
            return NO;
    }
}

static void SpliceKitBRAWClampVariantToRange(Variant *value,
                                             const Variant *minValue,
                                             const Variant *maxValue)
{
    if (!value || !minValue || !maxValue || value->vt != minValue->vt || value->vt != maxValue->vt) {
        return;
    }

    switch (value->vt) {
        case blackmagicRawVariantTypeU16:
            value->uiVal = (uint16_t)MIN(MAX(value->uiVal, minValue->uiVal), maxValue->uiVal);
            break;
        case blackmagicRawVariantTypeS16:
            value->iVal = (int16_t)MIN(MAX(value->iVal, minValue->iVal), maxValue->iVal);
            break;
        case blackmagicRawVariantTypeS32:
            value->intVal = MIN(MAX(value->intVal, minValue->intVal), maxValue->intVal);
            break;
        case blackmagicRawVariantTypeU32:
            value->uintVal = MIN(MAX(value->uintVal, minValue->uintVal), maxValue->uintVal);
            break;
        case blackmagicRawVariantTypeFloat32:
            value->fltVal = MIN(MAX(value->fltVal, minValue->fltVal), maxValue->fltVal);
            break;
        case blackmagicRawVariantTypeFloat64:
            value->dblVal = MIN(MAX(value->dblVal, minValue->dblVal), maxValue->dblVal);
            break;
        default:
            break;
    }
}

static BOOL SpliceKitBRAWSetISOToNearestSupportedValue(IBlackmagicRawFrameProcessingAttributes *attributes,
                                                       Variant *value,
                                                       NSNumber *number)
{
    if (!attributes || !value || !number) {
        return NO;
    }

    uint32_t count = 0;
    bool readOnly = false;
    HRESULT listHR = attributes->GetISOList(nullptr, &count, &readOnly);
    if (listHR != S_OK || readOnly || count == 0) {
        return NO;
    }

    std::vector<uint32_t> isoList(count, 0);
    if (attributes->GetISOList(isoList.data(), &count, &readOnly) != S_OK || readOnly || count == 0) {
        return NO;
    }

    uint32_t requested = (uint32_t)MAX(0.0, number.doubleValue);
    uint32_t best = isoList[0];
    uint64_t bestDelta = (best > requested) ? (uint64_t)(best - requested) : (uint64_t)(requested - best);
    for (uint32_t candidate : isoList) {
        uint64_t delta = (candidate > requested) ? (uint64_t)(candidate - requested) : (uint64_t)(requested - candidate);
        if (delta < bestDelta) {
            best = candidate;
            bestDelta = delta;
        }
    }

    switch (value->vt) {
        case blackmagicRawVariantTypeU16:
            value->uiVal = (uint16_t)MIN(best, (uint32_t)UINT16_MAX);
            return YES;
        case blackmagicRawVariantTypeU32:
            value->uintVal = best;
            return YES;
        default:
            return NO;
    }
}

static BOOL SpliceKitBRAWApplyClipSetting(IBlackmagicRawClipProcessingAttributes *attributes,
                                          BlackmagicRawClipProcessingAttribute attribute,
                                          NSNumber *number,
                                          NSString *key,
                                          NSString *path)
{
    if (!attributes || !number) {
        return NO;
    }

    Variant current = {};
    if (VariantInit(&current) != S_OK) {
        return NO;
    }
    Variant minValue = {};
    Variant maxValue = {};
    VariantInit(&minValue);
    VariantInit(&maxValue);
    bool readOnly = false;

    BOOL applied = NO;
    HRESULT getHR = attributes->GetClipAttribute(attribute, &current);
    HRESULT setHR = E_FAIL;
    HRESULT rangeHR = attributes->GetClipAttributeRange(attribute, &minValue, &maxValue, &readOnly);
    if (getHR == S_OK &&
        !readOnly &&
        SpliceKitBRAWSetVariantFromNumber(&current, number)) {
        if (rangeHR == S_OK) {
            SpliceKitBRAWClampVariantToRange(&current, &minValue, &maxValue);
        }
        setHR = attributes->SetClipAttribute(attribute, &current);
    }
    if (getHR == S_OK && setHR == S_OK) {
        applied = YES;
    }
    VariantClear(&current);
    VariantClear(&minValue);
    VariantClear(&maxValue);

    if (applied) {
        SpliceKitBRAWTrace([NSString stringWithFormat:@"[raw-settings-apply] clip %@ %@=%@",
                            path ?: @"<unknown>",
                            key,
                            number]);
    } else if (number) {
        SpliceKitBRAWTrace([NSString stringWithFormat:
                            @"[raw-settings-apply] clip-failed %@ %@=%@ getHR=%@ rangeHR=%@ readOnly=%d setHR=%@ variantType=%d",
                            path ?: @"<unknown>",
                            key,
                            number,
                            SpliceKitBRAWHRESULTString(getHR),
                            SpliceKitBRAWHRESULTString(rangeHR),
                            readOnly ? 1 : 0,
                            SpliceKitBRAWHRESULTString(setHR),
                            (int)current.vt]);
    }
    return applied;
}

static NSString *SpliceKitBRAWCopyClipStringAttribute(IBlackmagicRawClipProcessingAttributes *attributes,
                                                      BlackmagicRawClipProcessingAttribute attribute)
{
    if (!attributes) return nil;

    Variant value = {};
    if (VariantInit(&value) != S_OK) return nil;

    NSString *result = nil;
    if (attributes->GetClipAttribute(attribute, &value) == S_OK &&
        value.vt == blackmagicRawVariantTypeString &&
        value.bstrVal) {
        result = [(__bridge NSString *)value.bstrVal copy];
    }
    VariantClear(&value);
    return result;
}

static BOOL SpliceKitBRAWCopyClipUInt16Attribute(IBlackmagicRawClipProcessingAttributes *attributes,
                                                 BlackmagicRawClipProcessingAttribute attribute,
                                                 uint16_t *outValue)
{
    if (!attributes || !outValue) return NO;

    Variant value = {};
    if (VariantInit(&value) != S_OK) return NO;

    BOOL success = NO;
    if (attributes->GetClipAttribute(attribute, &value) == S_OK) {
        switch (value.vt) {
            case blackmagicRawVariantTypeU8:
            case blackmagicRawVariantTypeU16:
                *outValue = value.uiVal;
                success = YES;
                break;
            case blackmagicRawVariantTypeU32:
                *outValue = (uint16_t)MIN(value.uintVal, (uint32_t)UINT16_MAX);
                success = YES;
                break;
            default:
                break;
        }
    }

    VariantClear(&value);
    return success;
}

struct SpliceKitBRAWToneCurveDefaults {
    BOOL valid { NO };
    float contrast { 1.0f };
    float saturation { 1.0f };
    float midpoint { 0.0f };
    float highlights { 0.0f };
    float shadows { 0.0f };
    float blackLevel { 0.0f };
    float whiteLevel { 1.0f };
    uint16_t videoBlackLevel { 0 };
};

static BOOL SpliceKitBRAWSetClipStringAttribute(IBlackmagicRawClipProcessingAttributes *attributes,
                                                BlackmagicRawClipProcessingAttribute attribute,
                                                NSString *stringValue,
                                                NSString *key,
                                                NSString *path)
{
    if (!attributes || stringValue.length == 0) return NO;

    Variant value = {};
    if (VariantInit(&value) != S_OK) return NO;
    value.vt = blackmagicRawVariantTypeString;
    value.bstrVal = CFStringCreateCopy(kCFAllocatorDefault, (__bridge CFStringRef)stringValue);
    HRESULT hr = attributes->SetClipAttribute(attribute, &value);
    VariantClear(&value);

    if (hr == S_OK) {
        SpliceKitBRAWTrace([NSString stringWithFormat:@"[raw-settings-apply] clip %@ %@=%@",
                            path ?: @"<unknown>",
                            key,
                            stringValue]);
        return YES;
    }

    SpliceKitBRAWTrace([NSString stringWithFormat:@"[raw-settings-apply] clip-failed %@ %@=%@ setHR=%@",
                        path ?: @"<unknown>",
                        key,
                        stringValue,
                        SpliceKitBRAWHRESULTString(hr)]);
    return NO;
}

static BOOL SpliceKitBRAWSetClipUInt16Attribute(IBlackmagicRawClipProcessingAttributes *attributes,
                                                BlackmagicRawClipProcessingAttribute attribute,
                                                uint16_t rawValue,
                                                NSString *key,
                                                NSString *path)
{
    if (!attributes) return NO;

    Variant value = {};
    Variant minimum = {};
    Variant maximum = {};
    if (VariantInit(&value) != S_OK || VariantInit(&minimum) != S_OK || VariantInit(&maximum) != S_OK) {
        VariantClear(&value);
        VariantClear(&minimum);
        VariantClear(&maximum);
        return NO;
    }

    bool readOnly = false;
    BOOL applied = NO;
    HRESULT getHR = attributes->GetClipAttribute(attribute, &value);
    HRESULT setHR = E_FAIL;
    HRESULT rangeHR = attributes->GetClipAttributeRange(attribute, &minimum, &maximum, &readOnly);
    if (getHR == S_OK && !readOnly) {
        switch (value.vt) {
            case blackmagicRawVariantTypeU8:
            case blackmagicRawVariantTypeU16:
                value.uiVal = rawValue;
                break;
            case blackmagicRawVariantTypeU32:
                value.uintVal = rawValue;
                break;
            default:
                goto cleanup;
        }
        if (rangeHR == S_OK) {
            SpliceKitBRAWClampVariantToRange(&value, &minimum, &maximum);
        }
        setHR = attributes->SetClipAttribute(attribute, &value);
        applied = (setHR == S_OK);
    }

cleanup:
    VariantClear(&value);
    VariantClear(&minimum);
    VariantClear(&maximum);

    if (applied) {
        SpliceKitBRAWTrace([NSString stringWithFormat:@"[raw-settings-apply] clip %@ %@=%u",
                            path ?: @"<unknown>",
                            key ?: @"<unknown>",
                            (unsigned int)rawValue]);
    } else {
        SpliceKitBRAWTrace([NSString stringWithFormat:@"[raw-settings-apply] clip-failed %@ %@=%u getHR=%@ rangeHR=%@ readOnly=%d setHR=%@",
                            path ?: @"<unknown>",
                            key ?: @"<unknown>",
                            (unsigned int)rawValue,
                            SpliceKitBRAWHRESULTString(getHR),
                            SpliceKitBRAWHRESULTString(rangeHR),
                            readOnly ? 1 : 0,
                            SpliceKitBRAWHRESULTString(setHR)]);
    }
    return applied;
}

static BOOL SpliceKitBRAWToneCurveValueNeedsOverride(NSNumber *number, double neutralValue)
{
    if (!number) return NO;
    return fabs(number.doubleValue - neutralValue) > 0.001;
}

static SpliceKitBRAWToneCurveDefaults SpliceKitBRAWQueryToneCurveDefaults(IBlackmagicRaw *codec,
                                                                          IBlackmagicRawClip *clip,
                                                                          IBlackmagicRawClipProcessingAttributes *attributes,
                                                                          NSString *baseGamma,
                                                                          NSString *path)
{
    SpliceKitBRAWToneCurveDefaults defaults;
    if (!codec || !clip || !attributes || baseGamma.length == 0) {
        return defaults;
    }

    IBlackmagicRawToneCurve *toneCurve = nullptr;
    HRESULT interfaceHR = codec->QueryInterface(IID_IBlackmagicRawToneCurve, (LPVOID *)&toneCurve);
    if (interfaceHR != S_OK || !toneCurve) {
        SpliceKitBRAWTrace([NSString stringWithFormat:@"[raw-settings-apply] clip %@ tonecurve-defaults toneCurveUnavailable hr=%@",
                            path ?: @"<unknown>",
                            SpliceKitBRAWHRESULTString(interfaceHR)]);
        return defaults;
    }

    uint16_t colorScienceGen = 0;
    SpliceKitBRAWCopyClipUInt16Attribute(attributes,
                                         blackmagicRawClipProcessingAttributeColorScienceGen,
                                         &colorScienceGen);

    CFStringRef cameraTypeRef = nullptr;
    NSString *cameraType = nil;
    if (clip->GetCameraType(&cameraTypeRef) == S_OK && cameraTypeRef) {
        cameraType = [(__bridge NSString *)cameraTypeRef copy];
        CFRelease(cameraTypeRef);
    }

    HRESULT toneHR = toneCurve->GetToneCurve((__bridge CFStringRef)(cameraType ?: @""),
                                             (__bridge CFStringRef)baseGamma,
                                             colorScienceGen,
                                             &defaults.contrast,
                                             &defaults.saturation,
                                             &defaults.midpoint,
                                             &defaults.highlights,
                                             &defaults.shadows,
                                             &defaults.blackLevel,
                                             &defaults.whiteLevel,
                                             &defaults.videoBlackLevel);
    toneCurve->Release();

    if (toneHR == S_OK) {
        defaults.valid = YES;
        SpliceKitBRAWTrace([NSString stringWithFormat:
                            @"[raw-settings-apply] clip %@ tonecurve-defaults camera=%@ gamma=%@ gen=%u contrast=%g saturation=%g midpoint=%g highlights=%g shadows=%g black=%g white=%g videoBlack=%u",
                            path ?: @"<unknown>",
                            cameraType ?: @"<nil>",
                            baseGamma,
                            (unsigned int)colorScienceGen,
                            defaults.contrast,
                            defaults.saturation,
                            defaults.midpoint,
                            defaults.highlights,
                            defaults.shadows,
                            defaults.blackLevel,
                            defaults.whiteLevel,
                            (unsigned int)defaults.videoBlackLevel]);
    } else {
        SpliceKitBRAWTrace([NSString stringWithFormat:
                            @"[raw-settings-apply] clip %@ tonecurve-defaults failed camera=%@ gamma=%@ gen=%u hr=%@",
                            path ?: @"<unknown>",
                            cameraType ?: @"<nil>",
                            baseGamma,
                            (unsigned int)colorScienceGen,
                            SpliceKitBRAWHRESULTString(toneHR)]);
    }

    return defaults;
}

static void SpliceKitBRAWEnsureToneCurveModeIfNeeded(IBlackmagicRaw *codec,
                                                     IBlackmagicRawClip *clip,
                                                     IBlackmagicRawClipProcessingAttributes *attributes,
                                                     NSNumber *saturation,
                                                     NSNumber *contrast,
                                                     NSNumber *highlights,
                                                     NSNumber *shadows,
                                                     NSString *path)
{
    if (!attributes) return;

    BOOL wantsToneCurveOverride =
        SpliceKitBRAWToneCurveValueNeedsOverride(saturation, 1.0) ||
        SpliceKitBRAWToneCurveValueNeedsOverride(contrast, 1.0) ||
        SpliceKitBRAWToneCurveValueNeedsOverride(highlights, 0.0) ||
        SpliceKitBRAWToneCurveValueNeedsOverride(shadows, 0.0);
    if (!wantsToneCurveOverride) return;

    NSString *gamma = SpliceKitBRAWCopyClipStringAttribute(attributes, blackmagicRawClipProcessingAttributeGamma);
    NSString *gamut = SpliceKitBRAWCopyClipStringAttribute(attributes, blackmagicRawClipProcessingAttributeGamut);
    SpliceKitBRAWTrace([NSString stringWithFormat:@"[raw-settings-apply] clip %@ tonecurve-mode current gamma=%@ gamut=%@",
                        path ?: @"<unknown>",
                        gamma ?: @"<nil>",
                        gamut ?: @"<nil>"]);

    NSSet<NSString *> *supportedGammaNames = [NSSet setWithArray:@[
        @"Blackmagic Design Film",
        @"Blackmagic Design Extended Video",
        @"Blackmagic Design Custom",
    ]];
    BOOL gammaSupported = gamma.length > 0 && [supportedGammaNames containsObject:gamma];
    BOOL gamutSupported = [gamut isEqualToString:@"Blackmagic Design"];
    NSString *baseGamma = gammaSupported ? gamma : @"Blackmagic Design Film";

    if (!gamutSupported) {
        SpliceKitBRAWSetClipStringAttribute(attributes,
                                            blackmagicRawClipProcessingAttributeGamut,
                                            @"Blackmagic Design",
                                            @"gamut",
                                            path);
    }

    SpliceKitBRAWToneCurveDefaults defaults =
        SpliceKitBRAWQueryToneCurveDefaults(codec, clip, attributes, baseGamma, path);

    if (![gamma isEqualToString:@"Blackmagic Design Custom"]) {
        SpliceKitBRAWSetClipStringAttribute(attributes,
                                            blackmagicRawClipProcessingAttributeGamma,
                                            @"Blackmagic Design Custom",
                                            @"gamma",
                                            path);
    }

    if (defaults.valid) {
        SpliceKitBRAWApplyClipSetting(attributes,
                                      blackmagicRawClipProcessingAttributeToneCurveContrast,
                                      @(defaults.contrast),
                                      @"toneCurveDefaultContrast",
                                      path);
        SpliceKitBRAWApplyClipSetting(attributes,
                                      blackmagicRawClipProcessingAttributeToneCurveSaturation,
                                      @(defaults.saturation),
                                      @"toneCurveDefaultSaturation",
                                      path);
        SpliceKitBRAWApplyClipSetting(attributes,
                                      blackmagicRawClipProcessingAttributeToneCurveMidpoint,
                                      @(defaults.midpoint),
                                      @"toneCurveDefaultMidpoint",
                                      path);
        SpliceKitBRAWApplyClipSetting(attributes,
                                      blackmagicRawClipProcessingAttributeToneCurveHighlights,
                                      @(defaults.highlights),
                                      @"toneCurveDefaultHighlights",
                                      path);
        SpliceKitBRAWApplyClipSetting(attributes,
                                      blackmagicRawClipProcessingAttributeToneCurveShadows,
                                      @(defaults.shadows),
                                      @"toneCurveDefaultShadows",
                                      path);
        SpliceKitBRAWApplyClipSetting(attributes,
                                      blackmagicRawClipProcessingAttributeToneCurveBlackLevel,
                                      @(defaults.blackLevel),
                                      @"toneCurveDefaultBlackLevel",
                                      path);
        SpliceKitBRAWApplyClipSetting(attributes,
                                      blackmagicRawClipProcessingAttributeToneCurveWhiteLevel,
                                      @(defaults.whiteLevel),
                                      @"toneCurveDefaultWhiteLevel",
                                      path);
        SpliceKitBRAWSetClipUInt16Attribute(attributes,
                                            blackmagicRawClipProcessingAttributeToneCurveVideoBlackLevel,
                                            defaults.videoBlackLevel,
                                            @"toneCurveDefaultVideoBlackLevel",
                                            path);
    }
}

static IBlackmagicRawClipProcessingAttributes *SpliceKitBRAWCreateClipProcessingOverride(IBlackmagicRaw *codec,
                                                                                          IBlackmagicRawClip *clip,
                                                                                          CFDictionaryRef settingsRef,
                                                                                          NSString *path)
{
    if (!clip || !settingsRef) {
        return nullptr;
    }

    NSNumber *saturation        = SpliceKitBRAWRAWNumberForKey(settingsRef, @"saturation");
    NSNumber *contrast          = SpliceKitBRAWRAWNumberForKey(settingsRef, @"contrast");
    NSNumber *highlights        = SpliceKitBRAWRAWNumberForKey(settingsRef, @"highlights");
    NSNumber *shadows           = SpliceKitBRAWRAWNumberForKey(settingsRef, @"shadows");
    NSNumber *midpoint          = SpliceKitBRAWRAWNumberForKey(settingsRef, @"midpoint");
    NSNumber *blackLevel        = SpliceKitBRAWRAWNumberForKey(settingsRef, @"blackLevel");
    NSNumber *whiteLevel        = SpliceKitBRAWRAWNumberForKey(settingsRef, @"whiteLevel");
    NSNumber *videoBlackLevel   = SpliceKitBRAWRAWNumberForKey(settingsRef, @"videoBlackLevel");
    NSNumber *highlightRecovery = SpliceKitBRAWRAWNumberForKey(settingsRef, @"highlightRecovery");
    NSNumber *gamutCompression  = SpliceKitBRAWRAWNumberForKey(settingsRef, @"gamutCompression");
    NSNumber *colorScienceGen   = SpliceKitBRAWRAWNumberForKey(settingsRef, @"colorScienceGen");
    NSNumber *analogGainClip    = SpliceKitBRAWRAWNumberForKey(settingsRef, @"analogGainClip");

    NSString *gammaString = nil;
    NSString *gamutString = nil;
    NSString *post3DLUTMode = nil;
    {
        NSDictionary *dict = (__bridge NSDictionary *)settingsRef;
        id g = dict[@"gamma"];
        if ([g isKindOfClass:[NSString class]]) gammaString = (NSString *)g;
        id u = dict[@"gamut"];
        if ([u isKindOfClass:[NSString class]]) gamutString = (NSString *)u;
        id l = dict[@"post3DLUTMode"];
        if ([l isKindOfClass:[NSString class]]) post3DLUTMode = (NSString *)l;
    }

    BOOL hasNumeric =
        saturation || contrast || highlights || shadows ||
        midpoint || blackLevel || whiteLevel || videoBlackLevel ||
        highlightRecovery || gamutCompression || colorScienceGen ||
        analogGainClip;
    BOOL hasString = (gammaString.length > 0) || (gamutString.length > 0) || (post3DLUTMode.length > 0);
    if (!hasNumeric && !hasString) {
        return nullptr;
    }

    IBlackmagicRawClipProcessingAttributes *attributes = nullptr;
    if (clip->CloneClipProcessingAttributes(&attributes) != S_OK || !attributes) {
        return nullptr;
    }

    // String attributes go FIRST. Some tone-curve fields are gated by Gamma
    // mode being "Custom"; setting Gamma early lets the subsequent SetClipAttribute
    // calls land cleanly.
    BOOL touched = NO;
    if (gammaString.length > 0) {
        touched |= SpliceKitBRAWSetClipStringAttribute(attributes,
                                                       blackmagicRawClipProcessingAttributeGamma,
                                                       gammaString, @"gamma", path);
    }
    if (gamutString.length > 0) {
        touched |= SpliceKitBRAWSetClipStringAttribute(attributes,
                                                       blackmagicRawClipProcessingAttributeGamut,
                                                       gamutString, @"gamut", path);
    }
    if (post3DLUTMode.length > 0) {
        touched |= SpliceKitBRAWSetClipStringAttribute(attributes,
                                                       blackmagicRawClipProcessingAttributePost3DLUTMode,
                                                       post3DLUTMode, @"post3DLUTMode", path);
    }

    // Tone-curve overrides need Gamma=Custom; ensure that's set if any
    // tone-curve numeric attribute changed and the user didn't explicitly pick
    // a different gamma. The helper handles "Blackmagic Design Custom"
    // switching idempotently.
    SpliceKitBRAWEnsureToneCurveModeIfNeeded(codec, clip, attributes,
                                             saturation, contrast, highlights, shadows, path);

    // Tone-curve floats.
    touched |= SpliceKitBRAWApplyClipSetting(attributes,
                                             blackmagicRawClipProcessingAttributeToneCurveSaturation,
                                             saturation, @"saturation", path);
    touched |= SpliceKitBRAWApplyClipSetting(attributes,
                                             blackmagicRawClipProcessingAttributeToneCurveContrast,
                                             contrast, @"contrast", path);
    touched |= SpliceKitBRAWApplyClipSetting(attributes,
                                             blackmagicRawClipProcessingAttributeToneCurveHighlights,
                                             highlights, @"highlights", path);
    touched |= SpliceKitBRAWApplyClipSetting(attributes,
                                             blackmagicRawClipProcessingAttributeToneCurveShadows,
                                             shadows, @"shadows", path);
    touched |= SpliceKitBRAWApplyClipSetting(attributes,
                                             blackmagicRawClipProcessingAttributeToneCurveMidpoint,
                                             midpoint, @"midpoint", path);
    touched |= SpliceKitBRAWApplyClipSetting(attributes,
                                             blackmagicRawClipProcessingAttributeToneCurveBlackLevel,
                                             blackLevel, @"blackLevel", path);
    touched |= SpliceKitBRAWApplyClipSetting(attributes,
                                             blackmagicRawClipProcessingAttributeToneCurveWhiteLevel,
                                             whiteLevel, @"whiteLevel", path);
    touched |= SpliceKitBRAWApplyClipSetting(attributes,
                                             blackmagicRawClipProcessingAttributeAnalogGain,
                                             analogGainClip, @"analogGainClip", path);

    // u16 attributes — apply via the same helper; the variant clamping handles
    // the type coercion. ApplyClipSetting accepts any NSNumber and matches
    // the Variant type the SDK reports for that attribute.
    touched |= SpliceKitBRAWApplyClipSetting(attributes,
                                             blackmagicRawClipProcessingAttributeToneCurveVideoBlackLevel,
                                             videoBlackLevel, @"videoBlackLevel", path);
    touched |= SpliceKitBRAWApplyClipSetting(attributes,
                                             blackmagicRawClipProcessingAttributeHighlightRecovery,
                                             highlightRecovery, @"highlightRecovery", path);
    touched |= SpliceKitBRAWApplyClipSetting(attributes,
                                             blackmagicRawClipProcessingAttributeGamutCompressionEnable,
                                             gamutCompression, @"gamutCompression", path);
    touched |= SpliceKitBRAWApplyClipSetting(attributes,
                                             blackmagicRawClipProcessingAttributeColorScienceGen,
                                             colorScienceGen, @"colorScienceGen", path);

    if (!touched) {
        attributes->Release();
        return nullptr;
    }
    return attributes;
}

static BOOL SpliceKitBRAWApplyFrameSetting(IBlackmagicRawFrameProcessingAttributes *attributes,
                                           BlackmagicRawFrameProcessingAttribute attribute,
                                           NSNumber *number,
                                           NSString *key,
                                           NSString *path)
{
    if (!attributes || !number) {
        return NO;
    }

    Variant current = {};
    if (VariantInit(&current) != S_OK) {
        return NO;
    }
    Variant minValue = {};
    Variant maxValue = {};
    VariantInit(&minValue);
    VariantInit(&maxValue);
    bool readOnly = false;

    BOOL applied = NO;
    HRESULT getHR = attributes->GetFrameAttribute(attribute, &current);
    HRESULT setHR = E_FAIL;
    HRESULT rangeHR = attributes->GetFrameAttributeRange(attribute, &minValue, &maxValue, &readOnly);
    if (getHR == S_OK &&
        !readOnly &&
        (attribute == blackmagicRawFrameProcessingAttributeISO
            ? SpliceKitBRAWSetISOToNearestSupportedValue(attributes, &current, number)
            : SpliceKitBRAWSetVariantFromNumber(&current, number))) {
        if (attribute != blackmagicRawFrameProcessingAttributeISO && rangeHR == S_OK) {
            SpliceKitBRAWClampVariantToRange(&current, &minValue, &maxValue);
        }
        setHR = attributes->SetFrameAttribute(attribute, &current);
    }
    if (getHR == S_OK && setHR == S_OK) {
        applied = YES;
    }
    VariantClear(&current);
    VariantClear(&minValue);
    VariantClear(&maxValue);

    if (applied) {
        SpliceKitBRAWTrace([NSString stringWithFormat:@"[raw-settings-apply] frame %@ %@=%@",
                            path ?: @"<unknown>",
                            key,
                            number]);
    } else if (number) {
        SpliceKitBRAWTrace([NSString stringWithFormat:
                            @"[raw-settings-apply] frame-failed %@ %@=%@ getHR=%@ rangeHR=%@ readOnly=%d setHR=%@ variantType=%d",
                            path ?: @"<unknown>",
                            key,
                            number,
                            SpliceKitBRAWHRESULTString(getHR),
                            SpliceKitBRAWHRESULTString(rangeHR),
                            readOnly ? 1 : 0,
                            SpliceKitBRAWHRESULTString(setHR),
                            (int)current.vt]);
    }
    return applied;
}

static IBlackmagicRawFrameProcessingAttributes *SpliceKitBRAWCreateFrameProcessingOverride(IBlackmagicRawFrame *frame,
                                                                                            CFDictionaryRef settingsRef,
                                                                                            NSString *path)
{
    if (!frame || !settingsRef) {
        return nullptr;
    }

    NSNumber *iso        = SpliceKitBRAWRAWNumberForKey(settingsRef, @"iso");
    NSNumber *kelvin     = SpliceKitBRAWRAWNumberForKey(settingsRef, @"kelvin");
    NSNumber *tint       = SpliceKitBRAWRAWNumberForKey(settingsRef, @"tint");
    NSNumber *exposure   = SpliceKitBRAWRAWNumberForKey(settingsRef, @"exposure");
    NSNumber *analogGain = SpliceKitBRAWRAWNumberForKey(settingsRef, @"analogGain");
    if (!iso && !kelvin && !tint && !exposure && !analogGain) {
        return nullptr;
    }

    IBlackmagicRawFrameProcessingAttributes *attributes = nullptr;
    if (frame->CloneFrameProcessingAttributes(&attributes) != S_OK || !attributes) {
        return nullptr;
    }

    BOOL touched = NO;
    touched |= SpliceKitBRAWApplyFrameSetting(attributes,
                                              blackmagicRawFrameProcessingAttributeISO,
                                              iso, @"iso", path);
    touched |= SpliceKitBRAWApplyFrameSetting(attributes,
                                              blackmagicRawFrameProcessingAttributeWhiteBalanceKelvin,
                                              kelvin, @"kelvin", path);
    touched |= SpliceKitBRAWApplyFrameSetting(attributes,
                                              blackmagicRawFrameProcessingAttributeWhiteBalanceTint,
                                              tint, @"tint", path);
    touched |= SpliceKitBRAWApplyFrameSetting(attributes,
                                              blackmagicRawFrameProcessingAttributeExposure,
                                              exposure, @"exposure", path);
    touched |= SpliceKitBRAWApplyFrameSetting(attributes,
                                              blackmagicRawFrameProcessingAttributeAnalogGain,
                                              analogGain, @"analogGain", path);
    if (!touched) {
        attributes->Release();
        return nullptr;
    }
    return attributes;
}

class SpliceKitBRAWHostDecodeCallback : public IBlackmagicRawCallback {
public:
    void Bind(SpliceKitBRAWHostDecodeContext *ctx) {
        std::lock_guard<std::mutex> lock(_mutex);
        _context = ctx;
    }
    void Unbind() {
        std::lock_guard<std::mutex> lock(_mutex);
        _context = nullptr;
    }

    // Order matches braw.probe / the subprocess helper: vtable work on
    // frame/processedImage FIRST, then release job. Releasing the job before
    // reading the processedImage can tear it down under our feet.
    void ReadComplete(IBlackmagicRawJob *job, HRESULT result, IBlackmagicRawFrame *frame) override {
        SpliceKitBRAWHostDecodeContext *ctx = Snapshot();
        if (ctx) {
            std::lock_guard<std::mutex> lock(ctx->mutex);
            ctx->readResult = result;
        }

        if (result == S_OK && frame && ctx) {
            frame->SetResolutionScale(ctx->scale);
            frame->SetResourceFormat(ctx->format);
            IBlackmagicRawFrameProcessingAttributes *frameProcessingAttributes =
                SpliceKitBRAWCreateFrameProcessingOverride(frame, ctx->rawSettings, nil);
            IBlackmagicRawJob *decodeJob = nullptr;
            HRESULT hr = frame->CreateJobDecodeAndProcessFrame(ctx->clipProcessingAttributes,
                                                               frameProcessingAttributes,
                                                               &decodeJob);
            if (frameProcessingAttributes) {
                frameProcessingAttributes->Release();
            }
            if (hr == S_OK && decodeJob) {
                hr = decodeJob->Submit();
                if (hr != S_OK) {
                    decodeJob->Release();
                    Fail(ctx, "Decode job submit failed", hr);
                }
            } else {
                if (decodeJob) decodeJob->Release();
                Fail(ctx, "CreateJobDecodeAndProcessFrame failed", hr);
            }
        } else if (ctx && result != S_OK) {
            Fail(ctx, "ReadComplete failed", result);
        }

        if (job) job->Release();
    }

    void DecodeComplete(IBlackmagicRawJob *job, HRESULT) override {
        if (job) job->Release();
    }

    void ProcessComplete(IBlackmagicRawJob *job, HRESULT result, IBlackmagicRawProcessedImage *processedImage) override {
        SpliceKitBRAWHostDecodeContext *ctx = Snapshot();
        if (ctx) {
            uint32_t w = 0, h = 0, sz = 0;
            void *resource = nullptr;
            BlackmagicRawResourceType resourceType = blackmagicRawResourceTypeBufferCPU;
            if (result == S_OK && processedImage) {
                processedImage->GetWidth(&w);
                processedImage->GetHeight(&h);
                processedImage->GetResourceSizeBytes(&sz);
                processedImage->GetResourceType(&resourceType);
                processedImage->GetResource(&resource);
            }

            std::unique_lock<std::mutex> lock(ctx->mutex);
            ctx->processResult = result;
            ctx->width = w;
            ctx->height = h;
            ctx->resourceSizeBytes = sz;

            if (result != S_OK) {
                ctx->error = "ProcessComplete returned failure";
            } else if (!resource || sz == 0 || sz > 2u * 1024u * 1024u * 1024u || w == 0 || h == 0) {
                // Upper bound raised from 512 MB to 2 GB: URSA Cine Immersive
                // decodes to 17520x8040 BGRA8 = 563 MB per frame, which was
                // triggering a spurious "invalid resource" rejection. 2 GB
                // still catches a genuinely corrupt size report without
                // false-positing on high-res immersive formats.
                ctx->error = "ProcessComplete returned invalid resource";
            } else if (resourceType == blackmagicRawResourceTypeBufferCPU) {
                const uint8_t *bytes = static_cast<const uint8_t *>(resource);
                try {
                    ctx->bytes.assign(bytes, bytes + sz);
                } catch (...) {
                    ctx->error = "failed to copy CPU bytes";
                }
            } else if (resourceType == blackmagicRawResourceTypeBufferMetal) {
                // Drop the lock while encoding/waiting on the GPU blit — we don't
                // need ctx->mutex for any of it, and holding it would block a
                // parallel decode that's waiting on the condition variable.
                lock.unlock();

                id<MTLBuffer> srcBuffer = (__bridge id<MTLBuffer>)resource;
                std::string blitError;
                bool blitOK = false;

                if (ctx->destPixelBuffer) {
                    blitOK = EncodeMetalBlit(srcBuffer, w, h, ctx->destPixelBuffer, blitError);
                } else {
                    // Bytes API fallback — copy MTLBuffer.contents into the vector.
                    // Shared-storage MTLBuffers are CPU-visible immediately after
                    // GPU work completes; the callback fires after that.
                    const void *contents = srcBuffer ? [srcBuffer contents] : nullptr;
                    if (contents) {
                        const uint8_t *bytes = static_cast<const uint8_t *>(contents);
                        try {
                            std::lock_guard<std::mutex> l2(ctx->mutex);
                            ctx->bytes.assign(bytes, bytes + sz);
                            blitOK = true;
                        } catch (...) {
                            blitError = "failed to copy Metal buffer bytes";
                        }
                    } else {
                        blitError = "MTLBuffer contents null";
                    }
                }

                lock.lock();
                if (!blitOK) ctx->error = blitError.empty() ? "Metal blit failed" : blitError;
            } else {
                ctx->error = "ProcessComplete returned unsupported resource type";
            }
            ctx->finished = true;
            ctx->cv.notify_all();
        }

        if (job) job->Release();
    }

    static bool EncodeMetalBlit(id<MTLBuffer> srcBuffer,
                                uint32_t w, uint32_t h,
                                CVPixelBufferRef destPixelBuffer,
                                std::string &errorOut) {
        if (!srcBuffer) { errorOut = "MTLBuffer null"; return false; }
        if (!destPixelBuffer) { errorOut = "dest CVPixelBuffer null"; return false; }

        CVMetalTextureCacheRef cache = SpliceKitBRAWMetalTextureCache();
        id<MTLCommandQueue> queue = SpliceKitBRAWMetalCommandQueue();
        if (!cache || !queue) {
            errorOut = "Metal cache/queue unavailable";
            return false;
        }

        CVMetalTextureRef textureRef = nullptr;
        CVReturn cvr = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, destPixelBuffer, nullptr,
            MTLPixelFormatBGRA8Unorm, w, h, 0, &textureRef);
        if (cvr != kCVReturnSuccess || !textureRef) {
            errorOut = [NSString stringWithFormat:@"CVMetalTextureCacheCreateTextureFromImage cvr=%d", cvr].UTF8String;
            if (textureRef) CFRelease(textureRef);
            return false;
        }

        id<MTLTexture> dstTexture = CVMetalTextureGetTexture(textureRef);
        if (!dstTexture) {
            errorOut = "CVMetalTextureGetTexture returned null";
            CFRelease(textureRef);
            return false;
        }

        @autoreleasepool {
            id<MTLCommandBuffer> cmdBuffer = [queue commandBuffer];
            id<MTLBlitCommandEncoder> blit = [cmdBuffer blitCommandEncoder];
            [blit copyFromBuffer:srcBuffer
                    sourceOffset:0
               sourceBytesPerRow:(NSUInteger)w * 4
             sourceBytesPerImage:(NSUInteger)w * (NSUInteger)h * 4
                      sourceSize:MTLSizeMake(w, h, 1)
                       toTexture:dstTexture
                destinationSlice:0
                destinationLevel:0
               destinationOrigin:MTLOriginMake(0, 0, 0)];
            [blit endEncoding];
            [cmdBuffer commit];
            [cmdBuffer waitUntilCompleted];
            if (cmdBuffer.error) {
                errorOut = cmdBuffer.error.localizedDescription.UTF8String;
                CFRelease(textureRef);
                return false;
            }
        }

        CFRelease(textureRef);
        return true;
    }

    void TrimProgress(IBlackmagicRawJob *, float) override {}
    void TrimComplete(IBlackmagicRawJob *, HRESULT) override {}
    void SidecarMetadataParseWarning(IBlackmagicRawClip *, CFStringRef, uint32_t, CFStringRef) override {}
    void SidecarMetadataParseError(IBlackmagicRawClip *, CFStringRef, uint32_t, CFStringRef) override {}
    void PreparePipelineComplete(void *, HRESULT) override {}

    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID, LPVOID *) override { return E_NOINTERFACE; }
    ULONG STDMETHODCALLTYPE AddRef(void) override { return 1; }
    ULONG STDMETHODCALLTYPE Release(void) override { return 1; }

private:
    SpliceKitBRAWHostDecodeContext *Snapshot() {
        std::lock_guard<std::mutex> lock(_mutex);
        return _context;
    }
    void Fail(SpliceKitBRAWHostDecodeContext *ctx, const char *msg, HRESULT hr) {
        std::lock_guard<std::mutex> lock(ctx->mutex);
        ctx->error = msg;
        ctx->processResult = hr;
        ctx->finished = true;
        ctx->cv.notify_all();
    }

    std::mutex _mutex;
    SpliceKitBRAWHostDecodeContext *_context { nullptr };
};

struct SpliceKitBRAWHostClipEntry {
    IBlackmagicRawFactory *factory { nullptr };
    IBlackmagicRaw *codec { nullptr };
    IBlackmagicRawConfiguration *config { nullptr };
    IBlackmagicRawClip *clip { nullptr };
    IBlackmagicRawClipAudio *audioClip { nullptr };
    // Optional — populated via QueryInterface when the clip is a
    // DJI/URSA Cine stereoscopic/immersive BRAW. Lets the per-eye decode
    // path use CreateJobImmersiveReadFrame(trackLeft | trackRight, …).
    IBlackmagicRawClipImmersiveVideo *immersiveClip { nullptr };
    SpliceKitBRAWHostDecodeCallback *callback { nullptr };
    NSString *path { nil };
};

static NSLock *SpliceKitBRAWHostClipLock() {
    static NSLock *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [[NSLock alloc] init]; });
    return lock;
}

static NSMutableDictionary<NSString *, NSValue *> *SpliceKitBRAWHostClipMap() {
    static NSMutableDictionary *map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ map = [NSMutableDictionary dictionary]; });
    return map;
}

static SpliceKitBRAWHostClipEntry *SpliceKitBRAWHostAcquireEntry(NSString *path, std::string &error) {
    if (path.length == 0) {
        error = "empty path";
        return nullptr;
    }
    [SpliceKitBRAWHostClipLock() lock];
    NSValue *boxed = SpliceKitBRAWHostClipMap()[path];
    [SpliceKitBRAWHostClipLock() unlock];
    if (boxed) {
        return static_cast<SpliceKitBRAWHostClipEntry *>([boxed pointerValue]);
    }

    // Open fresh — this mirrors the probe's flow that decodes successfully.
    NSString *frameworkBinary = nil;
    NSString *frameworkLoadPath = nil;
    NSString *loadErr = nil;
    IBlackmagicRawFactory *factory = SpliceKitBRAWCreateFactory(&frameworkBinary, &frameworkLoadPath, &loadErr);
    if (!factory) {
        error = loadErr ? loadErr.UTF8String : "factory creation failed";
        return nullptr;
    }

    IBlackmagicRaw *codec = nullptr;
    HRESULT hr = factory->CreateCodec(&codec);
    if (hr != S_OK || !codec) {
        factory->Release();
        error = "CreateCodec failed";
        return nullptr;
    }

    // Prefer the Metal pipeline when available — decode happens on GPU and the
    // resulting MTLBuffer can be GPU-blitted into the destination CVPixelBuffer's
    // IOSurface without any CPU-visible copy. Fall back to CPU if Metal isn't
    // supported on the device (unlikely on modern Apple Silicon Macs).
    IBlackmagicRawConfiguration *config = nullptr;
    bool usingMetal = false;
    if (codec->QueryInterface(IID_IBlackmagicRawConfiguration, (LPVOID *)&config) == S_OK && config) {
        id<MTLDevice> device = SpliceKitBRAWMetalDevice();
        id<MTLCommandQueue> queue = SpliceKitBRAWMetalCommandQueue();
        bool metalSupported = false;
        if (device && queue) {
            config->IsPipelineSupported(blackmagicRawPipelineMetal, &metalSupported);
            if (metalSupported) {
                HRESULT hr = config->SetPipeline(blackmagicRawPipelineMetal,
                                                 (__bridge void *)device,
                                                 (__bridge void *)queue);
                if (hr == S_OK) {
                    usingMetal = true;
                    SpliceKitBRAWTrace(@"[host-decode] using Metal pipeline");
                } else {
                    SpliceKitBRAWTrace([NSString stringWithFormat:
                        @"[host-decode] Metal SetPipeline failed hr=0x%08X; falling back to CPU",
                        (uint32_t)hr]);
                }
            }
        }
        if (!usingMetal) {
            config->SetPipeline(blackmagicRawPipelineCPU, nullptr, nullptr);
            uint32_t cpuCount = (uint32_t)std::max(1, (int)[NSProcessInfo processInfo].activeProcessorCount - 1);
            config->SetCPUThreads(cpuCount);
            SpliceKitBRAWTrace([NSString stringWithFormat:@"[host-decode] using CPU pipeline (%u threads)", cpuCount]);
        }
    }

    IBlackmagicRawClip *clip = nullptr;
    hr = codec->OpenClip((__bridge CFStringRef)path, &clip);
    if (hr != S_OK || !clip) {
        if (config) config->Release();
        codec->Release();
        factory->Release();
        error = "OpenClip failed";
        return nullptr;
    }

    auto *entry = new SpliceKitBRAWHostClipEntry;
    entry->factory = factory;
    entry->codec = codec;
    entry->config = config;
    entry->clip = clip;
    entry->path = [path copy];
    // Audio is optional; query and cache the interface if present.
    IBlackmagicRawClipAudio *audioClip = nullptr;
    if (clip->QueryInterface(IID_IBlackmagicRawClipAudio, (LPVOID *)&audioClip) == S_OK && audioClip) {
        entry->audioClip = audioClip;
    }
    // Immersive/stereoscopic is also optional — exposed only for DJI/URSA Cine
    // stereo BRAWs. Presence of this interface gates our per-eye decode path.
    IBlackmagicRawClipImmersiveVideo *immersiveClip = nullptr;
    if (clip->QueryInterface(IID_IBlackmagicRawClipImmersiveVideo, (LPVOID *)&immersiveClip) == S_OK && immersiveClip) {
        entry->immersiveClip = immersiveClip;
        SpliceKitBRAWTrace([NSString stringWithFormat:@"[host-decode] immersive clip detected for %@", path]);
    }
    entry->callback = new SpliceKitBRAWHostDecodeCallback();
    codec->SetCallback(entry->callback);

    [SpliceKitBRAWHostClipLock() lock];
    // Check again in case another thread inserted one in the meantime.
    NSValue *existing = SpliceKitBRAWHostClipMap()[path];
    if (existing) {
        auto *other = static_cast<SpliceKitBRAWHostClipEntry *>([existing pointerValue]);
        // Tear down the entry we just built; use the existing one.
        if (entry->immersiveClip) entry->immersiveClip->Release();
        if (entry->audioClip) entry->audioClip->Release();
        if (entry->clip) entry->clip->Release();
        if (entry->config) entry->config->Release();
        if (entry->codec) entry->codec->Release();
        if (entry->factory) entry->factory->Release();
        entry->path = nil;
        delete entry->callback;
        delete entry;
        [SpliceKitBRAWHostClipLock() unlock];
        return other;
    }
    SpliceKitBRAWHostClipMap()[path] = [NSValue valueWithPointer:entry];
    [SpliceKitBRAWHostClipLock() unlock];

    SpliceKitBRAWTrace([NSString stringWithFormat:@"[host-decode] opened clip %@", path]);
    return entry;
}

static void SpliceKitBRAWHostReleaseEntry(NSString *path) {
    if (path.length == 0) return;
    [SpliceKitBRAWHostClipLock() lock];
    NSValue *boxed = SpliceKitBRAWHostClipMap()[path];
    [SpliceKitBRAWHostClipMap() removeObjectForKey:path];
    [SpliceKitBRAWHostClipLock() unlock];
    if (!boxed) return;
    auto *entry = static_cast<SpliceKitBRAWHostClipEntry *>([boxed pointerValue]);
    if (!entry) return;
    entry->callback->Unbind();
    if (entry->codec) entry->codec->FlushJobs();
    if (entry->immersiveClip) entry->immersiveClip->Release();
    if (entry->audioClip) entry->audioClip->Release();
    if (entry->clip) entry->clip->Release();
    if (entry->config) entry->config->Release();
    if (entry->codec) entry->codec->Release();
    if (entry->factory) entry->factory->Release();
    entry->path = nil;
    delete entry->callback;
    delete entry;
    SpliceKitBRAWTrace([NSString stringWithFormat:@"[host-decode] released clip %@", path]);
}

} // namespace

// Dedicated serial queue for all BRAW SDK calls. The SDK's worker threads
// appear to be sensitive to the thread context that issues jobs — calling
// from VT worker threads triggers PAC-style failures in VTable dispatch.
// Serializing on a single queue (our own thread) produces a stable context
// that matches the one the probe uses successfully.
static dispatch_queue_t SpliceKitBRAWWorkQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("com.splicekit.braw.work", DISPATCH_QUEUE_SERIAL);
        dispatch_queue_set_specific(queue,
                                    &kSpliceKitBRAWWorkQueueSpecificKey,
                                    &kSpliceKitBRAWWorkQueueSpecificKey,
                                    NULL);
    });
    return queue;
}

static void SpliceKitBRAWHostInvalidateEntryNow(NSString *path) {
    if (path.length == 0) return;
    [SpliceKitBRAWHostClipLock() lock];
    BOOL hasEntry = (SpliceKitBRAWHostClipMap()[path] != nil);
    [SpliceKitBRAWHostClipLock() unlock];
    if (!hasEntry) return;
    SpliceKitBRAWTrace([NSString stringWithFormat:@"[host-decode] invalidating clip %@", path]);
    SpliceKitBRAWHostReleaseEntry(path);
}

static void SpliceKitBRAWHostInvalidateEntry(NSString *path) {
    if (path.length == 0) return;

    dispatch_queue_t queue = SpliceKitBRAWWorkQueue();
    NSString *pathCopy = [path copy];
    if (dispatch_get_specific(&kSpliceKitBRAWWorkQueueSpecificKey)) {
        SpliceKitBRAWHostInvalidateEntryNow(pathCopy);
        return;
    }

    dispatch_sync(queue, ^{
        SpliceKitBRAWHostInvalidateEntryNow(pathCopy);
    });
}

static bool SpliceKitBRAWRunDecodeJob(SpliceKitBRAWHostClipEntry *entry,
                                      SpliceKitBRAWHostDecodeContext &ctx,
                                      uint32_t frameIndex,
                                      int eyeIndex /* -1 = monoscopic */) {
    ctx.clipProcessingAttributes = SpliceKitBRAWCreateClipProcessingOverride(entry->codec,
                                                                             entry->clip,
                                                                             ctx.rawSettings,
                                                                             entry->path);
    auto releaseClipProcessingOverride = [&ctx]() {
        if (ctx.clipProcessingAttributes) {
            ctx.clipProcessingAttributes->Release();
            ctx.clipProcessingAttributes = nullptr;
        }
    };
    entry->callback->Bind(&ctx);

    IBlackmagicRawJob *readJob = nullptr;
    HRESULT hr = S_OK;
    // Stereo/immersive path: use CreateJobImmersiveReadFrame with the eye
    // enum when the clip exposes IBlackmagicRawClipImmersiveVideo AND the
    // caller provided an eye index. Everything else (including monoscopic
    // clips and clips where QI failed) falls through to the plain
    // CreateJobReadFrame path.
    if (eyeIndex >= 0 && entry->immersiveClip) {
        BlackmagicRawImmersiveVideoTrack track = (eyeIndex == 0)
            ? blackmagicRawImmersiveVideoTrackLeft
            : blackmagicRawImmersiveVideoTrackRight;
        hr = entry->immersiveClip->CreateJobImmersiveReadFrame(track, (uint64_t)frameIndex, &readJob);
        if (hr != S_OK || !readJob) {
            entry->callback->Unbind();
            releaseClipProcessingOverride();
            SpliceKitBRAWTrace([NSString stringWithFormat:
                @"[host-decode] CreateJobImmersiveReadFrame failed frame=%u eye=%d hr=0x%08X",
                frameIndex, eyeIndex, (uint32_t)hr]);
            return false;
        }
    } else {
        hr = entry->clip->CreateJobReadFrame(frameIndex, &readJob);
        if (hr != S_OK || !readJob) {
            entry->callback->Unbind();
            releaseClipProcessingOverride();
            SpliceKitBRAWTrace([NSString stringWithFormat:@"[host-decode] CreateJobReadFrame failed frame=%u hr=0x%08X", frameIndex, (uint32_t)hr]);
            return false;
        }
    }
    hr = readJob->Submit();
    if (hr != S_OK) {
        readJob->Release();
        entry->callback->Unbind();
        releaseClipProcessingOverride();
        return false;
    }

    entry->codec->FlushJobs();
    {
        std::unique_lock<std::mutex> lock(ctx.mutex);
        ctx.cv.wait_for(lock, std::chrono::seconds(10), [&] { return ctx.finished; });
    }
    entry->callback->Unbind();
    releaseClipProcessingOverride();

    if (ctx.processResult != S_OK) {
        SpliceKitBRAWTrace([NSString stringWithFormat:@"[host-decode] decode failed frame=%u error=%s",
                            frameIndex, ctx.error.c_str()]);
        return false;
    }
    return true;
}

static BlackmagicRawResolutionScale SpliceKitBRAWScaleForHint(uint32_t scaleHint) {
    switch (scaleHint) {
        case 0: return blackmagicRawResolutionScaleFull;
        case 1: return blackmagicRawResolutionScaleHalf;
        case 2: return blackmagicRawResolutionScaleQuarter;
        case 3: return blackmagicRawResolutionScaleEighth;
        default: return blackmagicRawResolutionScaleHalf;
    }
}

// Probe the SDK at the given scale by decoding frame 0 once. Used by the
// shim path when a clip's native resolution exceeds Metal's 16384 texture
// cap and we need to know what a smaller scale actually produces. The probe
// bypasses the blit path (destPixelBuffer=nullptr) so it only pays for the
// CPU-bytes copy, not a Metal blit.
static BOOL SpliceKitBRAWProbeScaledDimsForPath(NSString *path,
                                                BlackmagicRawResolutionScale scale,
                                                uint32_t *outW, uint32_t *outH) {
    std::string err;
    SpliceKitBRAWHostClipEntry *entry = SpliceKitBRAWHostAcquireEntry(path, err);
    if (!entry || !entry->clip) return NO;
    SpliceKitBRAWHostDecodeContext ctx;
    ctx.scale = scale;
    ctx.format = blackmagicRawResourceFormatBGRAU8;
    ctx.destPixelBuffer = nullptr;
    if (!SpliceKitBRAWRunDecodeJob(entry, ctx, 0, -1)) return NO;
    if (ctx.width == 0 || ctx.height == 0) return NO;
    if (outW) *outW = ctx.width;
    if (outH) *outH = ctx.height;
    return YES;
}

static BOOL SpliceKitBRAWDecodeFrameBytesOnWorkQueue(
    NSString *path,
    uint32_t frameIndex,
    uint32_t scaleHint,
    int eyeIndex,
    uint32_t formatHint,
    uint32_t *outWidth,
    uint32_t *outHeight,
    uint32_t *outSizeBytes,
    void **outBytes)
{
    std::string error;
    SpliceKitBRAWHostClipEntry *entry = SpliceKitBRAWHostAcquireEntry(path, error);
    if (!entry) {
        SpliceKitBRAWTrace([NSString stringWithFormat:@"[host-decode] acquire failed for %@: %s", path, error.c_str()]);
        return NO;
    }

    SpliceKitBRAWHostDecodeContext ctx;
    ctx.scale = SpliceKitBRAWScaleForHint(scaleHint);
    ctx.format = (formatHint == 1) ? blackmagicRawResourceFormatBGRAU8
                                    : blackmagicRawResourceFormatRGBAU8;
    ctx.rawSettings = SpliceKitBRAW_CopyRAWSettingsForPath((__bridge CFStringRef)path);

    if (!SpliceKitBRAWRunDecodeJob(entry, ctx, frameIndex, eyeIndex) || ctx.bytes.empty()) {
        if (ctx.rawSettings) CFRelease(ctx.rawSettings);
        return NO;
    }

    void *buffer = malloc(ctx.bytes.size());
    if (!buffer) {
        if (ctx.rawSettings) CFRelease(ctx.rawSettings);
        return NO;
    }
    memcpy(buffer, ctx.bytes.data(), ctx.bytes.size());
    *outWidth = ctx.width;
    *outHeight = ctx.height;
    *outSizeBytes = (uint32_t)ctx.bytes.size();
    *outBytes = buffer;
    if (ctx.rawSettings) CFRelease(ctx.rawSettings);
    return YES;
}

static BOOL SpliceKitBRAWDecodeIntoPixelBufferOnWorkQueue(
    NSString *path,
    uint32_t frameIndex,
    uint32_t scaleHint,
    int eyeIndex /* -1 = monoscopic */,
    CVPixelBufferRef destPixelBuffer,
    uint32_t *outWidth,
    uint32_t *outHeight)
{
    std::string error;
    SpliceKitBRAWHostClipEntry *entry = SpliceKitBRAWHostAcquireEntry(path, error);
    if (!entry) {
        SpliceKitBRAWTrace([NSString stringWithFormat:@"[host-decode] acquire failed for %@: %s", path, error.c_str()]);
        return NO;
    }

    SpliceKitBRAWHostDecodeContext ctx;
    BlackmagicRawResolutionScale mappedScale = blackmagicRawResolutionScaleFull;
    uint32_t mappedW = 0, mappedH = 0;
    if (SpliceKitBRAWLookupPathScale(path, &mappedScale, &mappedW, &mappedH) &&
        mappedScale != blackmagicRawResolutionScaleFull) {
        // Shim picked this scale because the clip's native res exceeds
        // Metal's 16384 texture cap; honor it so source dims match the
        // destPB dims FCP allocated from the shim's stsd.
        ctx.scale = mappedScale;
    } else {
        ctx.scale = SpliceKitBRAWScaleForHint(scaleHint);
        // Fallback for the map-empty case (shim was built in a prior launch,
        // map hasn't been repopulated yet, but the shim on disk uses
        // downscaled dims): if the clip's native res exceeds Metal's cap,
        // pick a smaller scale preemptively. Costs one GetWidth/Height query.
        if (entry && entry->clip) {
            uint32_t clipW = 0, clipH = 0;
            entry->clip->GetWidth(&clipW);
            entry->clip->GetHeight(&clipH);
            if (clipW > kSpliceKitBRAWMaxMetalTextureDim ||
                clipH > kSpliceKitBRAWMaxMetalTextureDim) {
                ctx.scale = blackmagicRawResolutionScaleHalf;
            }
        }
    }
    // BGRAU8 matches kCVPixelFormatType_32BGRA on the destination so the blit
    // is a straight-line copy (no channel swap).
    ctx.format = blackmagicRawResourceFormatBGRAU8;
    ctx.destPixelBuffer = destPixelBuffer;
    ctx.rawSettings = SpliceKitBRAW_CopyRAWSettingsForPath((__bridge CFStringRef)path);

    if (!SpliceKitBRAWRunDecodeJob(entry, ctx, frameIndex, eyeIndex)) {
        if (ctx.rawSettings) CFRelease(ctx.rawSettings);
        return NO;
    }
    if (!ctx.error.empty()) {
        SpliceKitBRAWTrace([NSString stringWithFormat:@"[host-decode] blit error frame=%u: %s",
                            frameIndex, ctx.error.c_str()]);
        if (ctx.rawSettings) CFRelease(ctx.rawSettings);
        return NO;
    }
    *outWidth = ctx.width;
    *outHeight = ctx.height;
    if (ctx.rawSettings) CFRelease(ctx.rawSettings);
    return YES;
}

// Synchronous decode: open-or-reuse clip, read+decode frame, copy bytes out.
// Returns YES on success. outBytes is malloc'd; caller must free().
// All BRAW SDK work is dispatched to our serial queue so the SDK sees a
// stable thread context, avoiding VT-worker-thread PAC issues.
SPLICEKIT_BRAW_EXTERN_C BOOL SpliceKitBRAW_DecodeFrameBytes(
    CFStringRef pathRef,
    uint32_t frameIndex,
    uint32_t scaleHint,
    uint32_t formatHint,
    uint32_t *outWidth,
    uint32_t *outHeight,
    uint32_t *outSizeBytes,
    void **outBytes)
{
    if (!pathRef || !outWidth || !outHeight || !outSizeBytes || !outBytes) return NO;
    *outWidth = 0;
    *outHeight = 0;
    *outSizeBytes = 0;
    *outBytes = nullptr;

    NSString *path = (__bridge NSString *)pathRef;
    __block BOOL result = NO;
    __block uint32_t w = 0, h = 0, sz = 0;
    __block void *bytes = nullptr;
    dispatch_sync(SpliceKitBRAWWorkQueue(), ^{
        result = SpliceKitBRAWDecodeFrameBytesOnWorkQueue(path, frameIndex, scaleHint, -1, formatHint,
                                                         &w, &h, &sz, &bytes);
    });
    *outWidth = w;
    *outHeight = h;
    *outSizeBytes = sz;
    *outBytes = bytes;
    return result;
}

SPLICEKIT_BRAW_EXTERN_C BOOL SpliceKitBRAW_DecodeFrameBytesEye(
    CFStringRef pathRef,
    uint32_t frameIndex,
    uint32_t scaleHint,
    int eyeIndex,
    uint32_t formatHint,
    uint32_t *outWidth,
    uint32_t *outHeight,
    uint32_t *outSizeBytes,
    void **outBytes)
{
    if (!pathRef || !outWidth || !outHeight || !outSizeBytes || !outBytes) return NO;
    *outWidth = 0;
    *outHeight = 0;
    *outSizeBytes = 0;
    *outBytes = nullptr;

    NSString *path = (__bridge NSString *)pathRef;
    __block BOOL result = NO;
    __block uint32_t w = 0, h = 0, sz = 0;
    __block void *bytes = nullptr;
    dispatch_sync(SpliceKitBRAWWorkQueue(), ^{
        result = SpliceKitBRAWDecodeFrameBytesOnWorkQueue(path, frameIndex, scaleHint, eyeIndex, formatHint,
                                                         &w, &h, &sz, &bytes);
    });
    *outWidth = w;
    *outHeight = h;
    *outSizeBytes = sz;
    *outBytes = bytes;
    return result;
}

// Zero-copy Metal decode: BRAW SDK decodes on GPU and the resulting MTLBuffer
// is GPU-blitted directly into `destPixelBuffer`'s IOSurface-backed texture.
// No CPU-visible copies of the frame. Caller retains ownership of the pixel
// buffer; we fill it and return.
// Per-eye variant: for stereo/immersive clips the VT decoder extracts eye
// index from the incoming FD (via the 'seye' atom on our shim) and passes
// it through here so the BRAW SDK decodes the correct view. eyeIndex < 0
// means monoscopic — falls through to the legacy CreateJobReadFrame path.
SPLICEKIT_BRAW_EXTERN_C BOOL SpliceKitBRAW_DecodeFrameIntoPixelBufferEye(
    CFStringRef pathRef,
    uint32_t frameIndex,
    uint32_t scaleHint,
    int eyeIndex,
    CVPixelBufferRef destPixelBuffer,
    uint32_t *outWidth,
    uint32_t *outHeight)
{
    if (!pathRef || !destPixelBuffer || !outWidth || !outHeight) return NO;
    *outWidth = 0;
    *outHeight = 0;

    // The destination must be BGRA so the blit matches the SDK's BGRAU8 output
    // without a channel-swap shader. IOSurface-backed buffers come from VT's
    // pool which we configured for 32BGRA in StartDecoderSession.
    OSType pixelFormat = CVPixelBufferGetPixelFormatType(destPixelBuffer);
    if (pixelFormat != kCVPixelFormatType_32BGRA) {
        SpliceKitBRAWTrace([NSString stringWithFormat:
            @"[host-decode] destPixelBuffer format 0x%08x != 32BGRA", (unsigned)pixelFormat]);
        return NO;
    }

    NSString *path = (__bridge NSString *)pathRef;
    __block BOOL result = NO;
    __block uint32_t w = 0, h = 0;
    NSTimeInterval t0 = [NSDate timeIntervalSinceReferenceDate];
    dispatch_sync(SpliceKitBRAWWorkQueue(), ^{
        result = SpliceKitBRAWDecodeIntoPixelBufferOnWorkQueue(
            path, frameIndex, scaleHint, eyeIndex, destPixelBuffer, &w, &h);
    });
    NSTimeInterval elapsedMs = ([NSDate timeIntervalSinceReferenceDate] - t0) * 1000.0;

    // Only log when there's something actionable: a failure, or a genuinely
    // slow frame. The 40 ms 24fps budget is noisy because FCP's frame
    // prefetcher often queues multiple decodes — the serial BRAW work queue
    // forces later frames to wait on earlier ones, so "elapsed" reflects
    // queue wait time, not decode time. 80 ms is the threshold where actual
    // viewer stutter becomes visible.
    // Diagnostic: log EVERY decode along with the current ISO from the
    // settings cache. This lets us correlate "user moved slider" → "decoder
    // saw new ISO" → "frame emitted" in the log timeline. Toggle off later.
    {
        CFDictionaryRef settings = SpliceKitBRAW_CopyRAWSettingsForPath(pathRef);
        NSNumber *iso = nil;
        if (settings && CFGetTypeID(settings) == CFDictionaryGetTypeID()) {
            iso = ((__bridge NSDictionary *)settings)[@"iso"];
        }
        SpliceKitBRAWTrace([NSString stringWithFormat:
            @"[perf] decode frame=%u eye=%d %.1fms iso=%@ result=%@",
            frameIndex, eyeIndex, elapsedMs, iso ?: @"-", result ? @"ok" : @"fail"]);
        if (settings) CFRelease(settings);
    }
    *outWidth = w;
    *outHeight = h;
    return result;
}

// Legacy entrypoint — still used by older/in-flight VT decoder bundles.
// Forwards to the per-eye variant with eyeIndex=-1 (monoscopic).
SPLICEKIT_BRAW_EXTERN_C BOOL SpliceKitBRAW_DecodeFrameIntoPixelBuffer(
    CFStringRef pathRef,
    uint32_t frameIndex,
    uint32_t scaleHint,
    CVPixelBufferRef destPixelBuffer,
    uint32_t *outWidth,
    uint32_t *outHeight)
{
    return SpliceKitBRAW_DecodeFrameIntoPixelBufferEye(
        pathRef, frameIndex, scaleHint, -1, destPixelBuffer, outWidth, outHeight);
}

SPLICEKIT_BRAW_EXTERN_C void SpliceKitBRAW_ReleaseClip(CFStringRef pathRef) {
    if (!pathRef) return;
    // Serialize release through the same work queue that runs decode jobs so a
    // VT-thread release can't tear down the callback/clip while the work queue
    // is mid-Unbind (std::mutex::lock() in Unbind() throws system_error when
    // the mutex has been freed underneath it — that's the SIGABRT we hit
    // previously on a Metal-pipeline decode).
    NSString *path = (__bridge NSString *)pathRef;
    dispatch_sync(SpliceKitBRAWWorkQueue(), ^{
        SpliceKitBRAWHostReleaseEntry(path);
    });
}

// Query audio track metadata for a clip. Returns YES if the clip has audio and
// all fields were populated. The host's cached BRAW SDK clip is reused (the
// audio clip interface is acquired once per-entry).
SPLICEKIT_BRAW_EXTERN_C BOOL SpliceKitBRAW_GetAudioMetadata(
    CFStringRef pathRef,
    uint32_t *outSampleRate,
    uint32_t *outChannelCount,
    uint32_t *outBitDepth,
    uint64_t *outSampleCount)
{
    if (!pathRef) return NO;
    if (outSampleRate) *outSampleRate = 0;
    if (outChannelCount) *outChannelCount = 0;
    if (outBitDepth) *outBitDepth = 0;
    if (outSampleCount) *outSampleCount = 0;

    NSString *path = (__bridge NSString *)pathRef;
    __block BOOL result = NO;
    __block uint32_t sr = 0, ch = 0, bd = 0;
    __block uint64_t sc = 0;
    dispatch_sync(SpliceKitBRAWWorkQueue(), ^{
        std::string error;
        SpliceKitBRAWHostClipEntry *entry = SpliceKitBRAWHostAcquireEntry(path, error);
        if (!entry || !entry->audioClip) {
            return;
        }
        HRESULT a = entry->audioClip->GetAudioSampleRate(&sr);
        HRESULT b = entry->audioClip->GetAudioChannelCount(&ch);
        HRESULT c = entry->audioClip->GetAudioBitDepth(&bd);
        HRESULT d = entry->audioClip->GetAudioSampleCount(&sc);
        result = (a == S_OK && b == S_OK && c == S_OK && d == S_OK && sr > 0 && ch > 0 && bd > 0 && sc > 0) ? YES : NO;
    });
    if (result) {
        if (outSampleRate) *outSampleRate = sr;
        if (outChannelCount) *outChannelCount = ch;
        if (outBitDepth) *outBitDepth = bd;
        if (outSampleCount) *outSampleCount = sc;
    }
    return result;
}

// Read a range of audio samples via the host's cached BRAW SDK clip. Caller
// provides the destination buffer + capacity. Returns YES on success with the
// actual counts via out params.
SPLICEKIT_BRAW_EXTERN_C BOOL SpliceKitBRAW_ReadAudioSamples(
    CFStringRef pathRef,
    uint64_t startSample,
    uint32_t maxSampleCount,
    void *buffer,
    uint32_t bufferSizeBytes,
    uint32_t *outSamplesRead,
    uint32_t *outBytesRead)
{
    if (!pathRef || !buffer || bufferSizeBytes == 0 || maxSampleCount == 0) return NO;
    if (outSamplesRead) *outSamplesRead = 0;
    if (outBytesRead) *outBytesRead = 0;

    NSString *path = (__bridge NSString *)pathRef;
    __block BOOL result = NO;
    __block uint32_t samplesRead = 0, bytesRead = 0;
    dispatch_sync(SpliceKitBRAWWorkQueue(), ^{
        std::string error;
        SpliceKitBRAWHostClipEntry *entry = SpliceKitBRAWHostAcquireEntry(path, error);
        if (!entry || !entry->audioClip) {
            return;
        }
        HRESULT hr = entry->audioClip->GetAudioSamples((int64_t)startSample,
                                                        buffer,
                                                        bufferSizeBytes,
                                                        maxSampleCount,
                                                        &samplesRead,
                                                        &bytesRead);
        result = (hr == S_OK) ? YES : NO;
    });
    if (outSamplesRead) *outSamplesRead = samplesRead;
    if (outBytesRead) *outBytesRead = bytesRead;
    return result;
}

// Read clip metadata via the host's BRAW SDK state. Lets the decoder bundle
// avoid touching the SDK directly in its StartDecoderSession path. Runs on
// the BRAW work queue so the SDK sees a stable thread context.
SPLICEKIT_BRAW_EXTERN_C BOOL SpliceKitBRAW_ReadClipMetadata(
    CFStringRef pathRef,
    uint32_t *outWidth,
    uint32_t *outHeight,
    float *outFrameRate,
    uint64_t *outFrameCount)
{
    if (!pathRef) return NO;
    if (outWidth) *outWidth = 0;
    if (outHeight) *outHeight = 0;
    if (outFrameRate) *outFrameRate = 0.0f;
    if (outFrameCount) *outFrameCount = 0;

    NSString *path = (__bridge NSString *)pathRef;
    __block BOOL ok = NO;
    __block uint32_t w = 0, h = 0;
    __block float fps = 0.0f;
    __block uint64_t count = 0;
    dispatch_sync(SpliceKitBRAWWorkQueue(), ^{
        std::string error;
        SpliceKitBRAWHostClipEntry *entry = SpliceKitBRAWHostAcquireEntry(path, error);
        if (!entry || !entry->clip) {
            return;
        }
        entry->clip->GetWidth(&w);
        entry->clip->GetHeight(&h);
        entry->clip->GetFrameRate(&fps);
        entry->clip->GetFrameCount(&count);
        ok = (w > 0 && h > 0 && fps > 0 && count > 0);
    });
    if (outWidth) *outWidth = w;
    if (outHeight) *outHeight = h;
    if (outFrameRate) *outFrameRate = fps;
    if (outFrameCount) *outFrameCount = count;
    return ok;
}

#else

SPLICEKIT_BRAW_EXTERN_C NSDictionary *SpliceKit_handleBRAWProbe(NSDictionary *params) {
    (void)params;
    return @{
        @"error": @"Blackmagic RAW SDK headers are not available at /Applications/Blackmagic RAW/Blackmagic RAW SDK/Mac/Include/BlackmagicRawAPI.h",
    };
}

SPLICEKIT_BRAW_EXTERN_C NSDictionary *SpliceKit_handleBRAWDescribeImmersive(NSDictionary *params) {
    return SpliceKit_handleBRAWProbe(params);
}

SPLICEKIT_BRAW_EXTERN_C NSDictionary *SpliceKit_handleBRAWReadMotionSamples(NSDictionary *params) {
    return SpliceKit_handleBRAWProbe(params);
}

SPLICEKIT_BRAW_EXTERN_C NSString *SpliceKitBRAWResolveOriginalPathForPublic(NSString *path) {
    return path;
}

SPLICEKIT_BRAW_EXTERN_C void SpliceKit_installBRAWProviderShim(void) {
}

SPLICEKIT_BRAW_EXTERN_C BOOL SpliceKit_installBRAWUTITypeConformanceHook(void) {
    return NO;
}

SPLICEKIT_BRAW_EXTERN_C BOOL SpliceKit_installBRAWAVURLAssetMIMEHook(void) {
    return NO;
}

SPLICEKIT_BRAW_EXTERN_C NSDictionary *SpliceKit_handleBRAWProviderProbe(NSDictionary *params) {
    (void)params;
    return @{
        @"error": @"Blackmagic RAW SDK headers are not available at /Applications/Blackmagic RAW/Blackmagic RAW SDK/Mac/Include/BlackmagicRawAPI.h",
    };
}

SPLICEKIT_BRAW_EXTERN_C BOOL SpliceKitBRAW_DecodeFrameBytes(
    CFStringRef pathRef,
    uint32_t frameIndex,
    uint32_t scaleHint,
    uint32_t formatHint,
    uint32_t *outWidth,
    uint32_t *outHeight,
    uint32_t *outSizeBytes,
    void **outBytes)
{
    (void)pathRef; (void)frameIndex; (void)scaleHint; (void)formatHint;
    if (outWidth) *outWidth = 0;
    if (outHeight) *outHeight = 0;
    if (outSizeBytes) *outSizeBytes = 0;
    if (outBytes) *outBytes = nullptr;
    return NO;
}

SPLICEKIT_BRAW_EXTERN_C BOOL SpliceKitBRAW_DecodeFrameBytesEye(
    CFStringRef pathRef,
    uint32_t frameIndex,
    uint32_t scaleHint,
    int eyeIndex,
    uint32_t formatHint,
    uint32_t *outWidth,
    uint32_t *outHeight,
    uint32_t *outSizeBytes,
    void **outBytes)
{
    (void)pathRef; (void)frameIndex; (void)scaleHint; (void)eyeIndex; (void)formatHint;
    if (outWidth) *outWidth = 0;
    if (outHeight) *outHeight = 0;
    if (outSizeBytes) *outSizeBytes = 0;
    if (outBytes) *outBytes = nullptr;
    return NO;
}

SPLICEKIT_BRAW_EXTERN_C void SpliceKitBRAW_ReleaseClip(CFStringRef pathRef) {
    (void)pathRef;
}

SPLICEKIT_BRAW_EXTERN_C void SpliceKitBRAW_SetRAWSettingsForPath(CFStringRef pathRef, CFDictionaryRef settingsRef) {
    (void)pathRef;
    (void)settingsRef;
}

SPLICEKIT_BRAW_EXTERN_C CFDictionaryRef SpliceKitBRAW_CopyRAWSettingsForPath(CFStringRef pathRef) {
    (void)pathRef;
    return nullptr;
}

SPLICEKIT_BRAW_EXTERN_C BOOL SpliceKitBRAW_ReadClipMetadata(
    CFStringRef pathRef,
    uint32_t *outWidth,
    uint32_t *outHeight,
    float *outFrameRate,
    uint64_t *outFrameCount)
{
    (void)pathRef;
    if (outWidth) *outWidth = 0;
    if (outHeight) *outHeight = 0;
    if (outFrameRate) *outFrameRate = 0;
    if (outFrameCount) *outFrameCount = 0;
    return NO;
}

SPLICEKIT_BRAW_EXTERN_C BOOL SpliceKitBRAW_DecodeFrameIntoPixelBuffer(
    CFStringRef pathRef,
    uint32_t frameIndex,
    uint32_t scaleHint,
    CVPixelBufferRef destPixelBuffer,
    uint32_t *outWidth,
    uint32_t *outHeight)
{
    (void)pathRef; (void)frameIndex; (void)scaleHint; (void)destPixelBuffer;
    if (outWidth) *outWidth = 0;
    if (outHeight) *outHeight = 0;
    return NO;
}

SPLICEKIT_BRAW_EXTERN_C BOOL SpliceKitBRAW_DecodeFrameIntoPixelBufferEye(
    CFStringRef pathRef,
    uint32_t frameIndex,
    uint32_t scaleHint,
    int eyeIndex,
    CVPixelBufferRef destPixelBuffer,
    uint32_t *outWidth,
    uint32_t *outHeight)
{
    (void)pathRef; (void)frameIndex; (void)scaleHint; (void)eyeIndex; (void)destPixelBuffer;
    if (outWidth) *outWidth = 0;
    if (outHeight) *outHeight = 0;
    return NO;
}

SPLICEKIT_BRAW_EXTERN_C int SpliceKitBRAWLookupEyeForFormatDescription(CMFormatDescriptionRef fd) {
    (void)fd;
    return -1;
}

SPLICEKIT_BRAW_EXTERN_C BOOL SpliceKitBRAW_GetAudioMetadata(
    CFStringRef pathRef,
    uint32_t *outSampleRate,
    uint32_t *outChannelCount,
    uint32_t *outBitDepth,
    uint64_t *outSampleCount)
{
    (void)pathRef;
    if (outSampleRate) *outSampleRate = 0;
    if (outChannelCount) *outChannelCount = 0;
    if (outBitDepth) *outBitDepth = 0;
    if (outSampleCount) *outSampleCount = 0;
    return NO;
}

SPLICEKIT_BRAW_EXTERN_C BOOL SpliceKitBRAW_ReadAudioSamples(
    CFStringRef pathRef,
    uint64_t startSample,
    uint32_t maxSampleCount,
    void *buffer,
    uint32_t bufferSizeBytes,
    uint32_t *outSamplesRead,
    uint32_t *outBytesRead)
{
    (void)pathRef; (void)startSample; (void)maxSampleCount;
    (void)buffer; (void)bufferSizeBytes;
    if (outSamplesRead) *outSamplesRead = 0;
    if (outBytesRead) *outBytesRead = 0;
    return NO;
}

#endif
