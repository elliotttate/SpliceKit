// SpliceKitBRAWDecoderInProcess.mm — in-process VT video decoder for BRAW.
//
// Replaces the separate SpliceKitBRAWDecoder.bundle MediaExtension.
// Registered at dylib load via VTRegisterVideoDecoder so FCP's VideoToolbox
// plumbing dispatches .braw decode requests straight to us — no plugin bundle
// on disk, no MediaExtension ceremony.
//
// The actual SDK decoding runs via host-side helpers implemented in
// SpliceKitBRAW.mm (SpliceKitBRAW_DecodeFrameIntoPixelBufferEye, etc.). Those
// live in the same dylib, so calls are direct (no dlsym needed). This file
// is responsible only for:
//   • The VTVideoDecoderClass vtable (create, start session, decode, etc.)
//   • Wiring a BRAW CVPixelBuffer back to VT via VTDecoderSessionEmitDecodedFrame
//   • Resolving each decode request's frame index from the incoming sample buffer
//
// See /Users/briantate/.claude/plans/mutable-popping-charm.md for the broader
// context.

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <VideoToolbox/VideoToolbox.h>
#import <VideoToolbox/VTDecompressionProperties.h>
#import <Accelerate/Accelerate.h>

#include "../Plugins/BRAW/Sources/Private/CMBaseObjectSPI.h"
#include "../Plugins/BRAW/Sources/Private/VTVideoDecoderSPI.h"

#include <mutex>
#include <string>
#include <vector>
#include <new>

// -------- Host-side helpers defined in SpliceKitBRAW.mm ----------------------
// Same dylib → direct link, no dlsym. These match the signatures declared
// at extern "C" in SpliceKitBRAW.mm.

extern "C" {
BOOL SpliceKitBRAW_ReadClipMetadata(CFStringRef pathRef,
                                    uint32_t *width,
                                    uint32_t *height,
                                    float *frameRate,
                                    uint64_t *frameCount);
BOOL SpliceKitBRAW_DecodeFrameIntoPixelBufferEye(CFStringRef pathRef,
                                                  uint32_t frameIndex,
                                                  uint32_t scaleHint,
                                                  int eyeIndex,
                                                  CVPixelBufferRef pixelBuffer,
                                                  uint32_t *outWidth,
                                                  uint32_t *outHeight);
void SpliceKitBRAW_ReleaseClip(CFStringRef pathRef);
NSString *SpliceKitBRAWLookupPathForFormatDescription(CMFormatDescriptionRef fd);
int SpliceKitBRAWLookupEyeForFormatDescription(CMFormatDescriptionRef fd);
}

// -------- SPI shim for CFBundleRef-less in-process registration --------------

// VTRegisterVideoDecoder has been a stable private VT SPI for years; declared
// in our local VTVideoDecoderSPI.h. The header gives us the function pointer
// signature and the CMBaseObject bridging types we need.

namespace splicekit_braw_decoder {

#if defined(__x86_64__)
constexpr size_t kCMBasePadSize = 4;
#else
constexpr size_t kCMBasePadSize = 0;
#endif

struct AlignedBaseClass {
    uint8_t pad[kCMBasePadSize];
    CMBaseClass baseClass;
};

struct BRAWDecoderInstance {
    CFAllocatorRef allocator { nullptr };
    VTVideoDecoderSession session { nullptr };
    CMVideoFormatDescriptionRef formatDescription { nullptr };
    CFStringRef currentPath { nullptr };
    int eyeIndex { -1 };           // -1 = mono, 0 = left, 1 = right
    uint32_t width { 0 };
    uint32_t height { 0 };
    float frameRate { 24.0f };
    uint64_t frameCount { 0 };
    CMTime frameDuration { kCMTimeInvalid };
    CFMutableDictionaryRef supportedProperties { nullptr };
    std::mutex decodeMutex;

    explicit BRAWDecoderInstance(CFAllocatorRef inAllocator)
        : allocator((CFAllocatorRef)CFRetain(inAllocator ?: kCFAllocatorDefault))
    {
        supportedProperties = CFDictionaryCreateMutable(
            allocator, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        if (supportedProperties) {
            CFDictionaryRef placeholder = CFDictionaryCreate(
                allocator, nullptr, nullptr, 0,
                &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
            if (placeholder) {
                CFDictionaryAddValue(supportedProperties, kVTDecompressionPropertyKey_SupportedPixelFormatsOrderedByQuality, placeholder);
                CFDictionaryAddValue(supportedProperties, kVTDecompressionPropertyKey_SupportedPixelFormatsOrderedByPerformance, placeholder);
                CFDictionaryAddValue(supportedProperties, kVTDecompressionPropertyKey_PixelFormatsWithReducedResolutionSupport, placeholder);
                CFDictionaryAddValue(supportedProperties, kVTDecompressionPropertyKey_ContentHasInterframeDependencies, placeholder);
                CFDictionaryAddValue(supportedProperties, kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder, placeholder);
                CFRelease(placeholder);
            }
        }
    }

    ~BRAWDecoderInstance() {
        closeRuntime();
        if (supportedProperties) CFRelease(supportedProperties);
        if (allocator) CFRelease(allocator);
    }

    void closeRuntime() {
        if (formatDescription) { CFRelease(formatDescription); formatDescription = nullptr; }
        if (currentPath) {
            SpliceKitBRAW_ReleaseClip(currentPath);
            CFRelease(currentPath);
            currentPath = nullptr;
        }
        session = nullptr;
    }
};

template<typename T>
static T *storage(CMBaseObjectRef object) {
    return static_cast<T *>(CMBaseObjectGetDerivedStorage(object));
}

static BRAWDecoderInstance *instanceFromRef(VTVideoDecoderRef decoder) {
    return storage<BRAWDecoderInstance>(reinterpret_cast<CMBaseObjectRef>(decoder));
}

// -------- BRAW codec detection ----------------------------------------------

static BOOL isBRAWFourCC(FourCharCode c) {
    return c == 'braw' || c == 'brxq' || c == 'brst' ||
           c == 'brvn' || c == 'brs2' || c == 'brxh';
}

// Extract the clip path from a BRAW format description — either directly from
// the sample-description extension atoms (the shim writes a "BrwP" atom) or
// via SpliceKitBRAWLookupPathForFormatDescription (which checks SpliceKit's
// fd→path registry populated during AVURLAsset.initWithURL: swizzle).
static CFStringRef copyClipPathForFormatDescription(CMVideoFormatDescriptionRef fd) {
    if (!fd) return nullptr;

    // Check SampleDescriptionExtensionAtoms -> BrwP first.
    CFDictionaryRef extensions = (CFDictionaryRef)CMFormatDescriptionGetExtension(
        fd, kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms);
    if (extensions && CFGetTypeID(extensions) == CFDictionaryGetTypeID()) {
        CFDataRef data = (CFDataRef)CFDictionaryGetValue(extensions, CFSTR("BrwP"));
        if (data && CFGetTypeID(data) == CFDataGetTypeID()) {
            CFStringRef string = CFStringCreateFromExternalRepresentation(
                kCFAllocatorDefault, data, kCFStringEncodingUTF8);
            if (string) {
                @autoreleasepool {
                    NSString *standardized = [(__bridge NSString *)string stringByStandardizingPath];
                    CFRelease(string);
                    if (standardized.length) {
                        return (CFStringRef)CFBridgingRetain([standardized copy]);
                    }
                }
            }
        }
    }

    // Fall back to host-side registry (AV initWithURL: path hook).
    @autoreleasepool {
        NSString *resolved = SpliceKitBRAWLookupPathForFormatDescription(fd);
        if (resolved.length) {
            return (CFStringRef)CFBridgingRetain([resolved copy]);
        }
    }
    return nullptr;
}

// -------- Per-instance metadata population -----------------------------------

static bool populateFromFormatDescription(BRAWDecoderInstance *d,
                                          CMVideoFormatDescriptionRef fd,
                                          CFStringRef path) {
    if (!fd) return false;
    CMVideoDimensions dims = CMVideoFormatDescriptionGetDimensions(fd);
    if (dims.width <= 0 || dims.height <= 0) return false;

    d->width = (uint32_t)dims.width;
    d->height = (uint32_t)dims.height;
    d->frameRate = 24.0f;
    d->frameCount = 0;

    uint32_t sdkW = 0, sdkH = 0;
    float fps = 0.0f;
    uint64_t frames = 0;
    if (path && SpliceKitBRAW_ReadClipMetadata(path, &sdkW, &sdkH, &fps, &frames)) {
        if (sdkW > 0 && sdkH > 0) {
            d->width = sdkW;
            d->height = sdkH;
        }
        if (fps > 0.0f) d->frameRate = fps;
        if (frames > 0) d->frameCount = frames;
    }
    if (d->frameCount == 0) {
        // 10 minutes at 24fps — generous fallback, never actually hit since
        // the FCP playhead is PTS-driven.
        d->frameCount = 24ull * 60ull * 10ull;
    }
    d->frameDuration = CMTimeMakeWithSeconds(1.0 / d->frameRate, 600000);
    return true;
}

// -------- CMBaseClass callbacks ---------------------------------------------

static CFStringRef copyDecoderDebugDescription(CMBaseObjectRef) {
    return CFSTR("SpliceKit BRAW in-process decoder");
}

static OSStatus invalidateDecoder(CMBaseObjectRef object) {
    BRAWDecoderInstance *d = storage<BRAWDecoderInstance>(object);
    if (!d) return paramErr;
    d->closeRuntime();
    return noErr;
}

static void finalizeDecoder(CMBaseObjectRef object) {
    storage<BRAWDecoderInstance>(object)->~BRAWDecoderInstance();
}

static CFArrayRef copySupportedPixelFormatArray(CFAllocatorRef allocator) {
    int32_t value = kCVPixelFormatType_32BGRA;
    CFNumberRef number = CFNumberCreate(allocator ?: kCFAllocatorDefault,
                                        kCFNumberSInt32Type, &value);
    if (!number) return nullptr;
    const void *values[1] = { number };
    CFArrayRef array = CFArrayCreate(allocator ?: kCFAllocatorDefault,
                                     values, 1, &kCFTypeArrayCallBacks);
    CFRelease(number);
    return array;
}

static OSStatus decoderCopyProperty(CMBaseObjectRef object, CFStringRef key,
                                    CFAllocatorRef allocator, void *valueOut) {
    BRAWDecoderInstance *d = storage<BRAWDecoderInstance>(object);
    if (!d || !key || !valueOut) return paramErr;

    if (CFEqual(key, kVTDecompressionPropertyKey_SupportedPixelFormatsOrderedByQuality) ||
        CFEqual(key, kVTDecompressionPropertyKey_SupportedPixelFormatsOrderedByPerformance) ||
        CFEqual(key, kVTDecompressionPropertyKey_PixelFormatsWithReducedResolutionSupport)) {
        *reinterpret_cast<CFArrayRef *>(valueOut) =
            copySupportedPixelFormatArray(allocator ?: d->allocator);
        return *reinterpret_cast<CFArrayRef *>(valueOut) ? noErr : kCMBaseObjectError_ValueNotAvailable;
    }
    if (CFEqual(key, kVTDecompressionPropertyKey_ContentHasInterframeDependencies) ||
        CFEqual(key, kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder)) {
        *reinterpret_cast<CFBooleanRef *>(valueOut) = kCFBooleanFalse;
        return noErr;
    }
    return kCMBaseObjectError_ValueNotAvailable;
}

static const AlignedBaseClass kDecoderBaseClass = {
    {},
    {
        kCMBaseObject_ClassVersion_1,
        sizeof(BRAWDecoderInstance),
        nullptr,              // derivedStorageSize
        invalidateDecoder,
        finalizeDecoder,
        copyDecoderDebugDescription,
        decoderCopyProperty,
        nullptr, nullptr, nullptr,
    }
};

// -------- VT vtable callbacks ------------------------------------------------

static CFDictionaryRef createPixelBufferAttributes(CFAllocatorRef allocator,
                                                    uint32_t width, uint32_t height) {
    int32_t widthI = (int32_t)width;
    int32_t heightI = (int32_t)height;
    int32_t pixelFormat = kCVPixelFormatType_32BGRA;
    CFNumberRef widthNumber = CFNumberCreate(allocator, kCFNumberSInt32Type, &widthI);
    CFNumberRef heightNumber = CFNumberCreate(allocator, kCFNumberSInt32Type, &heightI);
    CFNumberRef pixelFormatNumber = CFNumberCreate(allocator, kCFNumberSInt32Type, &pixelFormat);
    CFMutableDictionaryRef ioSurface = CFDictionaryCreateMutable(
        allocator, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);

    const void *keys[5] = {
        kCVPixelBufferWidthKey,
        kCVPixelBufferHeightKey,
        kCVPixelBufferPixelFormatTypeKey,
        kCVPixelBufferIOSurfacePropertiesKey,
        kCVPixelBufferMetalCompatibilityKey,
    };
    const void *values[5] = {
        widthNumber, heightNumber, pixelFormatNumber, ioSurface, kCFBooleanTrue,
    };
    CFDictionaryRef attributes = CFDictionaryCreate(
        allocator, keys, values, 5,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    if (widthNumber) CFRelease(widthNumber);
    if (heightNumber) CFRelease(heightNumber);
    if (pixelFormatNumber) CFRelease(pixelFormatNumber);
    if (ioSurface) CFRelease(ioSurface);
    return attributes;
}

static CVPixelBufferRef createPixelBuffer(BRAWDecoderInstance *d) {
    CVPixelBufferPoolRef pool = d->session ? VTDecoderSessionGetPixelBufferPool(d->session) : nullptr;
    CVPixelBufferRef pb = nullptr;
    if (pool && CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pb) == noErr && pb) {
        return pb;
    }
    CFDictionaryRef attrs = createPixelBufferAttributes(d->allocator, d->width, d->height);
    CVReturn status = CVPixelBufferCreate(d->allocator, d->width, d->height,
                                          kCVPixelFormatType_32BGRA, attrs, &pb);
    if (attrs) CFRelease(attrs);
    return (status == kCVReturnSuccess) ? pb : nullptr;
}

static bool extractFrameIndex(CMSampleBufferRef sampleBuffer, uint32_t &frameIndexOut) {
    // Our format reader emits 4-byte sentinels carrying the frame index. Real
    // frame bytes from AVFoundation's QT reader are much larger.
    if (!sampleBuffer || CMSampleBufferGetNumSamples(sampleBuffer) < 1) return false;
    CMBlockBufferRef bb = CMSampleBufferGetDataBuffer(sampleBuffer);
    if (!bb) return false;
    size_t total = CMBlockBufferGetDataLength(bb);
    if (total != sizeof(uint32_t)) return false;

    CMBlockBufferRef contig = nullptr;
    if (!CMBlockBufferIsRangeContiguous(bb, 0, 0)) {
        if (CMBlockBufferCreateContiguous(kCFAllocatorDefault, bb, kCFAllocatorDefault,
                                          nullptr, 0, 0, 0, &contig) != noErr || !contig) return false;
        bb = contig;
    }
    char *data = nullptr;
    OSStatus s = CMBlockBufferGetDataPointer(bb, 0, nullptr, nullptr, &data);
    if (contig) CFRelease(contig);
    if (s != noErr || !data) return false;

    memcpy(&frameIndexOut, data, sizeof(frameIndexOut));
    return true;
}

static uint32_t frameIndexForSampleBuffer(const BRAWDecoderInstance *d,
                                           CMSampleBufferRef sampleBuffer) {
    CMSampleTimingInfo timing = {};
    if (CMSampleBufferGetSampleTimingInfo(sampleBuffer, 0, &timing) == noErr &&
        CMTIME_IS_NUMERIC(timing.presentationTimeStamp) &&
        d->frameRate > 0.0f) {
        Float64 secs = CMTimeGetSeconds(timing.presentationTimeStamp);
        if (secs <= 0.0) return 0;
        uint64_t idx = (uint64_t)floor(secs * d->frameRate + 0.0001);
        if (d->frameCount > 0 && idx >= d->frameCount) idx = d->frameCount - 1;
        return (uint32_t)idx;
    }
    return 0;
}

static OSStatus startDecoderSession(VTVideoDecoderRef decoderRef,
                                    VTVideoDecoderSession session,
                                    CMVideoFormatDescriptionRef fd) {
    BRAWDecoderInstance *d = instanceFromRef(decoderRef);
    if (!d || !session || !fd) return paramErr;

    std::lock_guard<std::mutex> lock(d->decodeMutex);
    CFStringRef path = copyClipPathForFormatDescription(fd);
    if (!path) return kVTVideoDecoderBadDataErr;

    // Refresh metadata if the format description's path changed.
    if (!d->currentPath || !CFEqual(d->currentPath, path)) {
        if (d->currentPath) { CFRelease(d->currentPath); d->currentPath = nullptr; }
        d->currentPath = (CFStringRef)CFRetain(path);
        if (!populateFromFormatDescription(d, fd, path)) {
            CFRelease(path);
            return kVTVideoDecoderBadDataErr;
        }
    }
    CFRelease(path);

    d->session = session;
    if (d->formatDescription) CFRelease(d->formatDescription);
    d->formatDescription = (CMVideoFormatDescriptionRef)CFRetain(fd);
    d->eyeIndex = SpliceKitBRAWLookupEyeForFormatDescription(fd);

    CFDictionaryRef attrs = createPixelBufferAttributes(d->allocator, d->width, d->height);
    if (attrs) {
        VTDecoderSessionSetPixelBufferAttributes(session, attrs);
        CFRelease(attrs);
    }
    return noErr;
}

static OSStatus decodeFrame(VTVideoDecoderRef decoderRef,
                            VTVideoDecoderFrame frame,
                            CMSampleBufferRef sampleBuffer,
                            VTDecodeFrameFlags,
                            VTDecodeInfoFlags *infoFlagsOut) {
    BRAWDecoderInstance *d = instanceFromRef(decoderRef);
    if (!d || !sampleBuffer) return paramErr;

    std::lock_guard<std::mutex> lock(d->decodeMutex);
    if (infoFlagsOut) *infoFlagsOut = 0;

    uint32_t frameIndex = 0;
    if (!extractFrameIndex(sampleBuffer, frameIndex)) {
        frameIndex = frameIndexForSampleBuffer(d, sampleBuffer);
    }

    if (!d->currentPath) return kVTVideoDecoderBadDataErr;

    CVPixelBufferRef pb = createPixelBuffer(d);
    if (!pb) return kVTAllocationFailedErr;

    uint32_t outW = 0, outH = 0;
    BOOL ok = SpliceKitBRAW_DecodeFrameIntoPixelBufferEye(
        d->currentPath, frameIndex, 0, d->eyeIndex, pb, &outW, &outH);
    if (!ok) {
        // Emit a black frame so the pipeline doesn't stall.
        CVPixelBufferLockBaseAddress(pb, 0);
        uint8_t *base = (uint8_t *)CVPixelBufferGetBaseAddress(pb);
        size_t bpr = CVPixelBufferGetBytesPerRow(pb);
        size_t h = CVPixelBufferGetHeight(pb);
        if (base) memset(base, 0, bpr * h);
        CVPixelBufferUnlockBaseAddress(pb, 0);
    }

    OSStatus emitStatus = VTDecoderSessionEmitDecodedFrame(d->session, frame, noErr, 0, pb);
    CFRelease(pb);
    return emitStatus;
}

static OSStatus copySupportedPropertyDictionary(VTVideoDecoderRef decoderRef,
                                                 CFDictionaryRef *out) {
    BRAWDecoderInstance *d = instanceFromRef(decoderRef);
    if (!d || !out || !d->supportedProperties) return paramErr;
    *out = CFDictionaryCreateCopy(d->allocator, d->supportedProperties);
    return *out ? noErr : kCMBaseObjectError_ValueNotAvailable;
}

static OSStatus setDecoderProperties(VTVideoDecoderRef, CFDictionaryRef) { return noErr; }

static OSStatus copySerializableProperties(VTVideoDecoderRef decoderRef,
                                            CFDictionaryRef *out) {
    if (!out) return paramErr;
    BRAWDecoderInstance *d = instanceFromRef(decoderRef);
    *out = CFDictionaryCreate(d ? d->allocator : kCFAllocatorDefault,
                              nullptr, nullptr, 0,
                              &kCFTypeDictionaryKeyCallBacks,
                              &kCFTypeDictionaryValueCallBacks);
    return *out ? noErr : kCMBaseObjectError_ValueNotAvailable;
}

static Boolean canAcceptFormatDescription(VTVideoDecoderRef decoderRef,
                                           CMVideoFormatDescriptionRef fd) {
    if (!fd) return false;
    FourCharCode sub = CMFormatDescriptionGetMediaSubType(fd);
    if (!isBRAWFourCC(sub)) return false;

    BRAWDecoderInstance *d = instanceFromRef(decoderRef);
    CFStringRef resolved = copyClipPathForFormatDescription(fd);

    if (d && d->currentPath) {
        Boolean same = resolved ? CFEqual(resolved, d->currentPath) : false;
        if (resolved) CFRelease(resolved);
        return same;
    }
    Boolean haveAPath = (resolved != nullptr);
    if (resolved) CFRelease(resolved);
    return haveAPath;
}

static OSStatus finishDelayedFrames(VTVideoDecoderRef) { return noErr; }

static const VTVideoDecoderClass kDecoderClass = {
    kVTVideoDecoder_ClassVersion_1,
    startDecoderSession,
    decodeFrame,
    copySupportedPropertyDictionary,
    setDecoderProperties,
    copySerializableProperties,
    canAcceptFormatDescription,
    finishDelayedFrames,
    nullptr, nullptr, nullptr,
};

static const VTVideoDecoderVTable kDecoderVTable = {
    { nullptr, &kDecoderBaseClass.baseClass },
    &kDecoderClass,
};

// -------- Create-instance entry point ----------------------------------------

extern "C" OSStatus SpliceKitBRAWInProcess_CreateInstance(FourCharCode /*codecType*/,
                                                           CFAllocatorRef allocator,
                                                           VTVideoDecoderRef *decoderOut) {
    if (!decoderOut) return paramErr;
    VTVideoDecoderRef decoder = nullptr;
    OSStatus status = CMDerivedObjectCreate(
        allocator ?: kCFAllocatorDefault,
        &kDecoderVTable.base,
        VTVideoDecoderGetClassID(),
        reinterpret_cast<CMBaseObjectRef *>(&decoder));
    if (status != noErr || !decoder) {
        return status ? status : kVTAllocationFailedErr;
    }
    new (storage<BRAWDecoderInstance>(reinterpret_cast<CMBaseObjectRef>(decoder)))
        BRAWDecoderInstance(allocator);
    *decoderOut = decoder;
    return noErr;
}

} // namespace splicekit_braw_decoder

// -------- Public registration entry point ------------------------------------

extern "C" BOOL SpliceKitBRAW_registerInProcessDecoder(void) {
    static dispatch_once_t once;
    static BOOL registered = NO;
    dispatch_once(&once, ^{
        // All BRAW FourCC variants we support. Each call binds one codec type
        // to our CreateInstance factory in VT's in-process decoder registry.
        FourCharCode codecs[] = { 'braw', 'brxq', 'brst', 'brvn', 'brs2', 'brxh' };
        BOOL anyOK = NO;
        for (size_t i = 0; i < sizeof(codecs) / sizeof(FourCharCode); ++i) {
            OSStatus s = VTRegisterVideoDecoder(codecs[i],
                &splicekit_braw_decoder::SpliceKitBRAWInProcess_CreateInstance);
            if (s == noErr) anyOK = YES;
            NSString *msg = [NSString stringWithFormat:@"[decoder-in-process] register %c%c%c%c status=%d",
                (char)((codecs[i] >> 24) & 0xFF),
                (char)((codecs[i] >> 16) & 0xFF),
                (char)((codecs[i] >> 8) & 0xFF),
                (char)(codecs[i] & 0xFF),
                (int)s];
            NSLog(@"%@", msg);
            // Also append to the BRAW log so we can diagnose without Console.
            FILE *f = fopen("/tmp/splicekit-braw.log", "a");
            if (f) { fprintf(f, "%s %s\n", [NSDate date].description.UTF8String, msg.UTF8String); fclose(f); }
        }
        registered = anyOK;
    });
    return registered;
}
