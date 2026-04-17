#import "SpliceKit.h"

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
    if (url.isFileURL) return url.path.stringByStandardizingPath;
    if ([candidate isKindOfClass:[NSString class]]) {
        return [(NSString *)candidate stringByStandardizingPath];
    }
    return nil;
}

static BOOL SpliceKitBRAWIsClipPath(NSString *path) {
    return [[path.pathExtension lowercaseString] isEqualToString:@"braw"];
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

static BOOL SpliceKitBRAWIsAVFriendlyFourCC(uint32_t fourcc) {
    // Empirically: braw, brxq, brst make it through AVFoundation's track filter.
    // brvn and future variants get dropped — we rewrite those to brxq in a clone.
    return fourcc == 'braw' || fourcc == 'brxq' || fourcc == 'brst';
}

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
    if (SpliceKitBRAWIsAVFriendlyFourCC(fourcc)) {
        return nil; // AVFoundation already handles this fourcc → no shim needed
    }

    // Cache shim by (path, fourcc). Filename is deterministic from inode+mtime
    // so stale shims don't accumulate.
    NSError *err = nil;
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:originalPath error:&err];
    if (!attrs) return nil;
    NSNumber *size = attrs[NSFileSize];
    NSDate *mtime = attrs[NSFileModificationDate];
    NSString *ident = [NSString stringWithFormat:@"%@-%.0f-%llu",
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
        // Overwrite the ENTIRE video stsd entry with Clip.braw's 110-byte entry
        // (fourcc='brxq', known-good header + bver/ctrn extension atoms). This
        // replaces 110 of the original 134 bytes; the remaining 24 bytes of the
        // original entry become trailing junk after the entry boundary, which
        // AVFoundation skips. We overwrite width/height with A001's real dims,
        // and we stamp 8 bytes of per-file identity into the zero-filled
        // compressor_name region so AVFoundation doesn't de-dup two different
        // BRAW files into a single shared CMFormatDescription (if every file
        // produced byte-identical stsd entries, AVFoundation would coalesce
        // them into one FD and our path registry would alias multiple clips
        // onto whichever was registered last — exactly what happened with two
        // URSA Cine brvn clips showing each other's content).
        static const uint8_t kClipBRXQStsdEntry[110] = {
            0x00, 0x00, 0x00, 0x6e, 0x62, 0x72, 0x78, 0x71, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
            0xd9, 0x4d, 0x55, 0x22, 0x00, 0x00, 0x00, 0x18, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00,
            0x18, 0x20, 0x0d, 0x90, 0x00, 0x48, 0x00, 0x00, 0x00, 0x48, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x40, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0xff, 0xff, 0x00, 0x00, 0x00, 0x0c, 0x62, 0x76, 0x65, 0x72, 0x00, 0x00,
            0x00, 0x01, 0x00, 0x00, 0x00, 0x0c, 0x63, 0x74, 0x72, 0x6e, 0x00, 0x00, 0x00, 0x01,
        };
        FILE *orig = fopen(originalPath.UTF8String, "rb");
        uint8_t actualW[2] = {0}, actualH[2] = {0};
        if (orig) {
            fseeko(orig, (off_t)(fourccOffset - 4 + 32), SEEK_SET);
            fread(actualW, 1, 2, orig);
            fread(actualH, 1, 2, orig);
            fclose(orig);
        }

        uint64_t entryStart = fourccOffset - 4;
        if (fseeko(shim, (off_t)entryStart, SEEK_SET) != 0 ||
            fwrite(kClipBRXQStsdEntry, 1, sizeof(kClipBRXQStsdEntry), shim) != sizeof(kClipBRXQStsdEntry)) {
            fclose(shim);
            return nil;
        }
        if (actualW[0] || actualW[1] || actualH[0] || actualH[1]) {
            if (fseeko(shim, (off_t)(entryStart + 32), SEEK_SET) == 0) {
                fwrite(actualW, 1, 2, shim);
                fwrite(actualH, 1, 2, shim);
            }
        }
        // Stamp a per-path 8-byte identifier into the compressor_name bytes
        // (offset 50..57 of the entry — the first 8 bytes of the 32-byte
        // Pascal-name field that's normally zero in Clip.braw's entry). Using
        // the Apple NSString hash is fine: we just need distinct-bytes-per-path
        // so AVFoundation doesn't coalesce FDs.
        NSUInteger hash = originalPath.hash;
        uint8_t identTag[8] = {
            (uint8_t)(hash >> 56), (uint8_t)(hash >> 48),
            (uint8_t)(hash >> 40), (uint8_t)(hash >> 32),
            (uint8_t)(hash >> 24), (uint8_t)(hash >> 16),
            (uint8_t)(hash >> 8),  (uint8_t)(hash),
        };
        if (fseeko(shim, (off_t)(entryStart + 50), SEEK_SET) == 0) {
            fwrite(identTag, 1, sizeof(identTag), shim);
        }

        // 4) Hide metadata (mebx) traks — rewrite their trak fourcc to 'skip'
        // so AVFoundation doesn't count them against the video-track filter.
        // AVFoundation ignores atoms it doesn't recognize at the moov-child level.
        std::vector<uint64_t> metaOffsets;
        SpliceKitBRAWFindMetaTrakFileOffsets(originalPath, metaOffsets);
        uint8_t skipFCC[4] = { 's', 'k', 'i', 'p' };
        for (uint64_t metaOff : metaOffsets) {
            if (fseeko(shim, (off_t)metaOff, SEEK_SET) != 0) continue;
            if (fwrite(skipFCC, 1, 4, shim) != 4) continue;
        }
        if (!metaOffsets.empty()) {
            SpliceKitBRAWTrace([NSString stringWithFormat:@"[fourcc-shim] stripped %lu meta trak(s) for %@",
                                (unsigned long)metaOffsets.size(), originalPath]);
        }
        fclose(shim);
        char oldFCC[5] = { (char)((fourcc>>24)&0xff), (char)((fourcc>>16)&0xff), (char)((fourcc>>8)&0xff), (char)(fourcc&0xff), 0 };
        SpliceKitBRAWTrace([NSString stringWithFormat:@"[fourcc-shim] created %@ (patched '%s'→'brxq', entry=110, header @%llu) for %@",
                            shimPath, oldFCC, fourccOffset, originalPath]);
    }

    SpliceKitBRAWShimCloneToOriginal()[shimPath] = originalPath;
    return shimPath;
}

// Given a (possibly shim) path, return the original BRAW path the caller cares
// about — either the path itself (if not shimmed) or the pre-shim original.
static NSString *SpliceKitBRAWResolveOriginalPath(NSString *path) {
    if (path.length == 0) return path;
    NSString *original = SpliceKitBRAWShimCloneToOriginal()[path];
    return original ?: path;
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

// Global map: CMFormatDescription pointer (as NSValue) -> NSString path. Populated
// by the AV hook so the decoder can recover the source path when the format
// description came from AVFoundation's QT reader (which has no BrwP atom).
// Key retains the format description so the pointer stays valid until we unregister.
static NSMutableDictionary<NSValue *, NSString *> *sSpliceKitBRAWFormatDescriptionPathMap = nil;
static NSLock *sSpliceKitBRAWFormatDescriptionLock = nil;

static void SpliceKitBRAWRegisterFormatDescriptionPath(CMFormatDescriptionRef fd, NSString *path) {
    if (!fd || path.length == 0) return;
    if (!sSpliceKitBRAWFormatDescriptionPathMap) {
        sSpliceKitBRAWFormatDescriptionPathMap = [NSMutableDictionary dictionary];
        sSpliceKitBRAWFormatDescriptionLock = [[NSLock alloc] init];
    }
    CFRetain(fd);  // Keep it alive while we track it
    [sSpliceKitBRAWFormatDescriptionLock lock];
    NSValue *key = [NSValue valueWithPointer:fd];
    if (!sSpliceKitBRAWFormatDescriptionPathMap[key]) {
        sSpliceKitBRAWFormatDescriptionPathMap[key] = path;
    } else {
        CFRelease(fd);  // Didn't insert, so balance retain
    }
    [sSpliceKitBRAWFormatDescriptionLock unlock];
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

SPLICEKIT_BRAW_EXTERN_C void SpliceKit_bootstrapBRAWAtLaunchPhase(NSString *phase) {
    NSString *phaseName = [phase isKindOfClass:[NSString class]] ? phase : @"unknown";
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
};

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
            IBlackmagicRawJob *decodeJob = nullptr;
            HRESULT hr = frame->CreateJobDecodeAndProcessFrame(nullptr, nullptr, &decodeJob);
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
            } else if (!resource || sz == 0 || sz > 512u * 1024u * 1024u || w == 0 || h == 0) {
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
    SpliceKitBRAWHostDecodeCallback *callback { nullptr };
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
    // Audio is optional; query and cache the interface if present.
    IBlackmagicRawClipAudio *audioClip = nullptr;
    if (clip->QueryInterface(IID_IBlackmagicRawClipAudio, (LPVOID *)&audioClip) == S_OK && audioClip) {
        entry->audioClip = audioClip;
    }
    entry->callback = new SpliceKitBRAWHostDecodeCallback();
    codec->SetCallback(entry->callback);

    [SpliceKitBRAWHostClipLock() lock];
    // Check again in case another thread inserted one in the meantime.
    NSValue *existing = SpliceKitBRAWHostClipMap()[path];
    if (existing) {
        auto *other = static_cast<SpliceKitBRAWHostClipEntry *>([existing pointerValue]);
        // Tear down the entry we just built; use the existing one.
        if (entry->audioClip) entry->audioClip->Release();
        if (entry->clip) entry->clip->Release();
        if (entry->config) entry->config->Release();
        if (entry->codec) entry->codec->Release();
        if (entry->factory) entry->factory->Release();
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
    if (entry->audioClip) entry->audioClip->Release();
    if (entry->clip) entry->clip->Release();
    if (entry->config) entry->config->Release();
    if (entry->codec) entry->codec->Release();
    if (entry->factory) entry->factory->Release();
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
    });
    return queue;
}

static bool SpliceKitBRAWRunDecodeJob(SpliceKitBRAWHostClipEntry *entry,
                                      SpliceKitBRAWHostDecodeContext &ctx,
                                      uint32_t frameIndex) {
    entry->callback->Bind(&ctx);

    IBlackmagicRawJob *readJob = nullptr;
    HRESULT hr = entry->clip->CreateJobReadFrame(frameIndex, &readJob);
    if (hr != S_OK || !readJob) {
        entry->callback->Unbind();
        SpliceKitBRAWTrace([NSString stringWithFormat:@"[host-decode] CreateJobReadFrame failed frame=%u hr=0x%08X", frameIndex, (uint32_t)hr]);
        return false;
    }
    hr = readJob->Submit();
    if (hr != S_OK) {
        readJob->Release();
        entry->callback->Unbind();
        return false;
    }

    entry->codec->FlushJobs();
    {
        std::unique_lock<std::mutex> lock(ctx.mutex);
        ctx.cv.wait_for(lock, std::chrono::seconds(10), [&] { return ctx.finished; });
    }
    entry->callback->Unbind();

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

static BOOL SpliceKitBRAWDecodeFrameBytesOnWorkQueue(
    NSString *path,
    uint32_t frameIndex,
    uint32_t scaleHint,
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

    if (!SpliceKitBRAWRunDecodeJob(entry, ctx, frameIndex) || ctx.bytes.empty()) {
        return NO;
    }

    void *buffer = malloc(ctx.bytes.size());
    if (!buffer) return NO;
    memcpy(buffer, ctx.bytes.data(), ctx.bytes.size());
    *outWidth = ctx.width;
    *outHeight = ctx.height;
    *outSizeBytes = (uint32_t)ctx.bytes.size();
    *outBytes = buffer;
    return YES;
}

static BOOL SpliceKitBRAWDecodeIntoPixelBufferOnWorkQueue(
    NSString *path,
    uint32_t frameIndex,
    uint32_t scaleHint,
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
    ctx.scale = SpliceKitBRAWScaleForHint(scaleHint);
    // BGRAU8 matches kCVPixelFormatType_32BGRA on the destination so the blit
    // is a straight-line copy (no channel swap).
    ctx.format = blackmagicRawResourceFormatBGRAU8;
    ctx.destPixelBuffer = destPixelBuffer;

    if (!SpliceKitBRAWRunDecodeJob(entry, ctx, frameIndex)) {
        return NO;
    }
    if (!ctx.error.empty()) {
        SpliceKitBRAWTrace([NSString stringWithFormat:@"[host-decode] blit error frame=%u: %s",
                            frameIndex, ctx.error.c_str()]);
        return NO;
    }
    *outWidth = ctx.width;
    *outHeight = ctx.height;
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
        result = SpliceKitBRAWDecodeFrameBytesOnWorkQueue(path, frameIndex, scaleHint, formatHint,
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
SPLICEKIT_BRAW_EXTERN_C BOOL SpliceKitBRAW_DecodeFrameIntoPixelBuffer(
    CFStringRef pathRef,
    uint32_t frameIndex,
    uint32_t scaleHint,
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
            path, frameIndex, scaleHint, destPixelBuffer, &w, &h);
    });
    NSTimeInterval elapsedMs = ([NSDate timeIntervalSinceReferenceDate] - t0) * 1000.0;

    // Only log when there's something actionable: a failure, or a genuinely
    // slow frame. The 40 ms 24fps budget is noisy because FCP's frame
    // prefetcher often queues multiple decodes — the serial BRAW work queue
    // forces later frames to wait on earlier ones, so "elapsed" reflects
    // queue wait time, not decode time. 80 ms is the threshold where actual
    // viewer stutter becomes visible.
    if (!result || elapsedMs > 80.0) {
        SpliceKitBRAWTrace([NSString stringWithFormat:
            @"[host-decode] into-PB frame=%u %.2fms result=%@",
            frameIndex, elapsedMs, result ? @"ok" : @"fail"]);
    }
    *outWidth = w;
    *outHeight = h;
    return result;
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

SPLICEKIT_BRAW_EXTERN_C void SpliceKitBRAW_ReleaseClip(CFStringRef pathRef) {
    (void)pathRef;
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
