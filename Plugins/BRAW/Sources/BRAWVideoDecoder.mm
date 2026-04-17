#include "BRAWCommon.h"

#include <Accelerate/Accelerate.h>
#include <CoreMedia/CMSampleBuffer.h>
#include <CoreVideo/CVPixelBuffer.h>
#include <VideoToolbox/VTDecompressionProperties.h>
#include "Private/VTVideoDecoderSPI.h"

#include <condition_variable>
#include <dlfcn.h>
#include <mutex>
#include <pthread.h>
#include <unistd.h>
#include <vector>

using namespace SpliceKitBRAW;

namespace {

__attribute__((constructor))
static void BRAWVideoDecoderBundleDidLoad()
{
    Log(@"decoder", @"bundle loaded pid=%d", getpid());
}

// Forward declaration so CloseRuntime() below can call it — the full definition
// sits next to the other host-dlsym resolvers further down.
typedef void (*SKBRAWHostReleaseFn)(CFStringRef);
static SKBRAWHostReleaseFn ResolveHostReleaseFn();

#if defined(__x86_64__)
constexpr size_t kCMBasePadSize = 4;
#else
constexpr size_t kCMBasePadSize = 0;
#endif

struct AlignedBaseClass {
    uint8_t pad[kCMBasePadSize];
    CMBaseClass baseClass;
};

template<typename T>
class ComPtr {
public:
    ComPtr() = default;
    ~ComPtr() { reset(); }

    T *get() const { return m_ptr; }
    T **out()
    {
        reset();
        return &m_ptr;
    }
    T *operator->() const { return m_ptr; }
    explicit operator bool() const { return m_ptr != nullptr; }

    void reset(T *value = nullptr)
    {
        if (m_ptr) {
            m_ptr->Release();
        }
        m_ptr = value;
    }

private:
    T *m_ptr { nullptr };
};

struct DecodeContext {
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
};

class DecoderCallback final : public IBlackmagicRawCallback {
public:
    void Begin(DecodeContext *context)
    {
        std::lock_guard<std::mutex> lock(m_contextMutex);
        m_context = context;
    }

    void End()
    {
        std::lock_guard<std::mutex> lock(m_contextMutex);
        m_context = nullptr;
    }

    void ReadComplete(IBlackmagicRawJob *job, HRESULT result, IBlackmagicRawFrame *frame) override
    {
        Log(@"decoder", @"ReadComplete enter result=0x%08X job=%p frame=%p",
            (uint32_t)result, job, frame);
        DecodeContext *context = SnapshotContext();
        if (job) {
            job->Release();
        }
        if (!context) {
            Log(@"decoder", @"ReadComplete no live context");
            return;
        }

        {
            std::lock_guard<std::mutex> lock(context->mutex);
            context->readResult = result;
        }

        if (result != S_OK || !frame) {
            Fail(context, "ReadComplete failed", result);
            return;
        }

        // Match the probe's known-good settings. Full-resolution BGRAU8 at 6144x3456
        // may be triggering SDK pipeline issues on worker threads; half-res RGBAU8
        // is what braw.probe uses successfully from the host side.
        frame->SetResolutionScale(blackmagicRawResolutionScaleHalf);
        frame->SetResourceFormat(blackmagicRawResourceFormatRGBAU8);

        IBlackmagicRawJob *decodeJob = nullptr;
        HRESULT decodeStatus = frame->CreateJobDecodeAndProcessFrame(nullptr, nullptr, &decodeJob);
        Log(@"decoder", @"CreateJobDecodeAndProcessFrame=0x%08X decodeJob=%p",
            (uint32_t)decodeStatus, decodeJob);
        if (decodeStatus != S_OK || !decodeJob) {
            if (decodeJob) {
                decodeJob->Release();
            }
            Fail(context, "CreateJobDecodeAndProcessFrame failed", decodeStatus);
            return;
        }

        decodeStatus = decodeJob->Submit();
        Log(@"decoder", @"decodeJob Submit=0x%08X", (uint32_t)decodeStatus);
        decodeJob->Release();
        if (decodeStatus != S_OK) {
            Fail(context, "Decode job submit failed", decodeStatus);
        }
    }

    void DecodeComplete(IBlackmagicRawJob *job, HRESULT) override
    {
        if (job) {
            job->Release();
        }
    }

    // Mirror the simpler, proven probe pattern. The decoder callback is always
    // called from a BRAW worker thread; keep the body tight and do nothing that
    // depends on decoder-level state other than the DecodeContext pointer.
    void ProcessComplete(IBlackmagicRawJob *job, HRESULT result, IBlackmagicRawProcessedImage *processedImage) override
    {
        DecodeContext *context = SnapshotContext();

        if (result == S_OK && processedImage && context) {
            uint32_t width = 0, height = 0, sizeBytes = 0;
            void *resource = nullptr;
            processedImage->GetWidth(&width);
            processedImage->GetHeight(&height);
            processedImage->GetResourceSizeBytes(&sizeBytes);
            processedImage->GetResource(&resource);

            std::lock_guard<std::mutex> lock(context->mutex);
            context->processResult = result;
            context->width = width;
            context->height = height;
            context->resourceSizeBytes = sizeBytes;
            if (resource && sizeBytes > 0 && sizeBytes <= 512u * 1024u * 1024u) {
                const uint8_t *bytes = static_cast<const uint8_t *>(resource);
                try {
                    context->bytes.assign(bytes, bytes + sizeBytes);
                } catch (...) {
                    context->error = "failed to copy processed image bytes";
                }
            } else {
                context->error = "processed image returned invalid resource";
            }
            context->finished = true;
            context->cv.notify_all();
        } else if (context) {
            std::lock_guard<std::mutex> lock(context->mutex);
            context->processResult = result;
            context->error = "ProcessComplete failed";
            context->finished = true;
            context->cv.notify_all();
        }

        if (job) {
            job->Release();
        }
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
    DecodeContext *SnapshotContext()
    {
        std::lock_guard<std::mutex> lock(m_contextMutex);
        return m_context;
    }

    void Fail(DecodeContext *context, const char *message, HRESULT status)
    {
        std::lock_guard<std::mutex> lock(context->mutex);
        context->error = [[NSString stringWithFormat:@"%s %@", message, DescribeHRESULT(status)] UTF8String];
        context->finished = true;
        context->cv.notify_all();
    }

    std::mutex m_contextMutex;
    DecodeContext *m_context { nullptr };
};

struct BRAWVideoDecoder {
    CFAllocatorRef allocator { nullptr };
    VTVideoDecoderSession session { nullptr };
    CMVideoFormatDescriptionRef formatDescription { nullptr };
    CFStringRef currentPath { nullptr };
    ClipInfo info {};
    ComPtr<IBlackmagicRawFactory> factory;
    ComPtr<IBlackmagicRaw> codec;
    ComPtr<IBlackmagicRawConfiguration> configuration;
    ComPtr<IBlackmagicRawClip> clip;
    DecoderCallback callback;
    CFMutableDictionaryRef supportedProperties { nullptr };
    std::mutex decodeMutex;

    explicit BRAWVideoDecoder(CFAllocatorRef inAllocator)
        : allocator((CFAllocatorRef)CFRetain(inAllocator ?: kCFAllocatorDefault))
    {
        supportedProperties = CFDictionaryCreateMutable(
            allocator,
            0,
            &kCFTypeDictionaryKeyCallBacks,
            &kCFTypeDictionaryValueCallBacks);
        if (supportedProperties) {
            CFDictionaryRef placeholder = CFDictionaryCreate(
                allocator,
                nullptr,
                nullptr,
                0,
                &kCFTypeDictionaryKeyCallBacks,
                &kCFTypeDictionaryValueCallBacks);
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

    ~BRAWVideoDecoder()
    {
        CloseRuntime();
        if (supportedProperties) {
            CFRelease(supportedProperties);
        }
        if (allocator) {
            CFRelease(allocator);
        }
    }

    void CloseRuntime()
    {
        callback.End();
        clip.reset();
        configuration.reset();
        codec.reset();
        factory.reset();
        if (formatDescription) {
            CFRelease(formatDescription);
            formatDescription = nullptr;
        }
        if (currentPath) {
            // Drop the host-side cached BRAW clip entry so the SDK state doesn't
            // accumulate across decoder teardowns. Host keeps a fresh entry when
            // a subsequent decode asks for the same path.
            if (SKBRAWHostReleaseFn release = ResolveHostReleaseFn()) {
                release(currentPath);
            }
            CFRelease(currentPath);
            currentPath = nullptr;
        }
        session = nullptr;
        info = ClipInfo {};
    }
};

template<typename T>
static T *Storage(CMBaseObjectRef object)
{
    return static_cast<T *>(CMBaseObjectGetDerivedStorage(object));
}

static BRAWVideoDecoder *DecoderFromRef(VTVideoDecoderRef decoder)
{
    return Storage<BRAWVideoDecoder>(reinterpret_cast<CMBaseObjectRef>(decoder));
}

static CFArrayRef CopySupportedPixelFormatArray(CFAllocatorRef allocator)
{
    int32_t value = kCVPixelFormatType_32BGRA;
    CFNumberRef number = CFNumberCreate(allocator ?: kCFAllocatorDefault, kCFNumberSInt32Type, &value);
    if (!number) {
        return nullptr;
    }
    const void *values[1] = { number };
    CFArrayRef array = CFArrayCreate(allocator ?: kCFAllocatorDefault, values, 1, &kCFTypeArrayCallBacks);
    CFRelease(number);
    return array;
}

static CFStringRef CopyDecoderDebugDescription(CMBaseObjectRef)
{
    return CFSTR("SpliceKit BRAW decoder");
}

static OSStatus InvalidateDecoder(CMBaseObjectRef object)
{
    BRAWVideoDecoder *decoder = Storage<BRAWVideoDecoder>(object);
    if (!decoder) {
        return paramErr;
    }
    decoder->CloseRuntime();
    return noErr;
}

static void FinalizeDecoder(CMBaseObjectRef object)
{
    Storage<BRAWVideoDecoder>(object)->~BRAWVideoDecoder();
}

static OSStatus DecoderCopyProperty(CMBaseObjectRef object, CFStringRef key, CFAllocatorRef allocator, void *valueOut)
{
    BRAWVideoDecoder *decoder = Storage<BRAWVideoDecoder>(object);
    if (!decoder || !key || !valueOut) {
        return paramErr;
    }

    if (CFEqual(key, kVTDecompressionPropertyKey_SupportedPixelFormatsOrderedByQuality) ||
        CFEqual(key, kVTDecompressionPropertyKey_SupportedPixelFormatsOrderedByPerformance) ||
        CFEqual(key, kVTDecompressionPropertyKey_PixelFormatsWithReducedResolutionSupport)) {
        *reinterpret_cast<CFArrayRef *>(valueOut) = CopySupportedPixelFormatArray(allocator ?: decoder->allocator);
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
        sizeof(BRAWVideoDecoder),
        nullptr,
        InvalidateDecoder,
        FinalizeDecoder,
        CopyDecoderDebugDescription,
        DecoderCopyProperty,
        nullptr,
        nullptr,
        nullptr,
    }
};

static OSStatus StartDecoderSession(VTVideoDecoderRef decoderRef, VTVideoDecoderSession session, CMVideoFormatDescriptionRef formatDescription);
static OSStatus DecodeFrame(VTVideoDecoderRef decoderRef, VTVideoDecoderFrame frame, CMSampleBufferRef sampleBuffer, VTDecodeFrameFlags, VTDecodeInfoFlags *infoFlagsOut);
static OSStatus CopySupportedPropertyDictionary(VTVideoDecoderRef decoderRef, CFDictionaryRef *dictionaryOut);
static OSStatus SetDecoderProperties(VTVideoDecoderRef, CFDictionaryRef);
static OSStatus CopySerializableProperties(VTVideoDecoderRef, CFDictionaryRef *dictionaryOut);
static Boolean CanAcceptFormatDescription(VTVideoDecoderRef decoderRef, CMVideoFormatDescriptionRef formatDescription);
static OSStatus FinishDelayedFrames(VTVideoDecoderRef);

static const VTVideoDecoderClass kDecoderClass = {
    kVTVideoDecoder_ClassVersion_1,
    StartDecoderSession,
    DecodeFrame,
    CopySupportedPropertyDictionary,
    SetDecoderProperties,
    CopySerializableProperties,
    CanAcceptFormatDescription,
    FinishDelayedFrames,
    nullptr,
    nullptr,
    nullptr,
};

static const VTVideoDecoderVTable kDecoderVTable = {
    { nullptr, &kDecoderBaseClass.baseClass },
    &kDecoderClass,
};

typedef BOOL (*SKBRAWHostMetaFn)(CFStringRef, uint32_t *, uint32_t *, float *, uint64_t *);

static SKBRAWHostMetaFn ResolveHostMetaFunction()
{
    static SKBRAWHostMetaFn fn = (SKBRAWHostMetaFn)-1;
    if (fn == (SKBRAWHostMetaFn)-1) {
        fn = (SKBRAWHostMetaFn)dlsym(RTLD_DEFAULT, "SpliceKitBRAW_ReadClipMetadata");
    }
    return fn;
}

static bool PopulateInfoFromFormatDescription(BRAWVideoDecoder *decoder, CMVideoFormatDescriptionRef fd, CFStringRef path)
{
    if (!fd) return false;
    CMVideoDimensions dims = CMVideoFormatDescriptionGetDimensions(fd);
    if (dims.width <= 0 || dims.height <= 0) return false;

    // The format description's dimensions are encoded-frame dims, often padded
    // up to the container's macroblock alignment (e.g. 6176x3472 for a true
    // 6144x3456 clip). Prefer the BRAW SDK's actual clip dimensions so the pool
    // buffer matches exactly what the decode job emits — otherwise we blit a
    // smaller image into a larger buffer and the uncovered strip keeps whatever
    // stale pixels the pool cycled in.
    uint32_t fdW = (uint32_t)dims.width;
    uint32_t fdH = (uint32_t)dims.height;
    decoder->info.width = fdW;
    decoder->info.height = fdH;

    float fps = 24.0f;
    uint64_t count = 0;
    SKBRAWHostMetaFn hostMeta = ResolveHostMetaFunction();
    if (hostMeta && path) {
        uint32_t sdkW = 0, sdkH = 0;
        if (hostMeta(path, &sdkW, &sdkH, &fps, &count)) {
            if (sdkW > 0 && sdkH > 0) {
                decoder->info.width = sdkW;
                decoder->info.height = sdkH;
                Log(@"decoder", @"using SDK dims %ux%u (fd was %ux%u)",
                    sdkW, sdkH, fdW, fdH);
            }
        }
    }
    if (fps <= 0.0f) fps = 24.0f;
    if (count == 0) {
        // Last-ditch fallback: assume the clip is 10 minutes at 24fps. The
        // actual PTS-driven frame index will never exceed this in practice.
        count = 24u * 60u * 10u;
    }
    decoder->info.frameRate = fps;
    decoder->info.frameCount = count;
    decoder->info.frameDuration = FrameDurationForRate(fps);
    decoder->info.duration = CMTimeMultiplyByFloat64(decoder->info.frameDuration, (Float64)count);
    return true;
}

static bool ConfigureDecoderRuntime(BRAWVideoDecoder *decoder, CFStringRef filePath, CMVideoFormatDescriptionRef fdHint)
{
    if (!decoder || !filePath) {
        return false;
    }

    if (decoder->currentPath && CFEqual(decoder->currentPath, filePath) &&
        decoder->info.width && decoder->info.height) {
        return true;
    }

    decoder->CloseRuntime();

    // Metadata comes from the format description FCP handed us plus host-side
    // BRAW SDK state (for framerate/frameCount). We deliberately do not open
    // the BRAW clip in-bundle: BRAW SDK callbacks fire on its own worker
    // threads, and when the decoder bundle is loaded inside a live VT decoder
    // session those callbacks faulted (PAC / EXC_BAD_ACCESS). All actual
    // decode work runs through the host helper on its serial queue.
    if (!fdHint || !PopulateInfoFromFormatDescription(decoder, fdHint, filePath)) {
        Log(@"decoder", @"failed to populate metadata for %@", CopyNSString(filePath));
        return false;
    }

    decoder->currentPath = (CFStringRef)CFRetain(filePath);
    Log(@"decoder", @"metadata: %ux%u @ %.3f fps, %llu frames",
        decoder->info.width, decoder->info.height,
        (double)decoder->info.frameRate, decoder->info.frameCount);
    return true;
}

static CFDictionaryRef CreatePixelBufferAttributes(CFAllocatorRef allocator, const ClipInfo &info)
{
    int32_t width = (int32_t)info.width;
    int32_t height = (int32_t)info.height;
    int32_t pixelFormat = kCVPixelFormatType_32BGRA;
    CFNumberRef widthNumber = CFNumberCreate(allocator, kCFNumberSInt32Type, &width);
    CFNumberRef heightNumber = CFNumberCreate(allocator, kCFNumberSInt32Type, &height);
    CFNumberRef pixelFormatNumber = CFNumberCreate(allocator, kCFNumberSInt32Type, &pixelFormat);
    CFMutableDictionaryRef ioSurface = CFDictionaryCreateMutable(
        allocator,
        0,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks);
    // Metal compatibility is required so the host-side zero-copy path can wrap
    // this pixel buffer's IOSurface as an MTLTexture (via CVMetalTextureCache)
    // and GPU-blit decoded pixels into it.
    const void *keys[5] = {
        kCVPixelBufferWidthKey,
        kCVPixelBufferHeightKey,
        kCVPixelBufferPixelFormatTypeKey,
        kCVPixelBufferIOSurfacePropertiesKey,
        kCVPixelBufferMetalCompatibilityKey,
    };
    const void *values[5] = {
        widthNumber,
        heightNumber,
        pixelFormatNumber,
        ioSurface,
        kCFBooleanTrue,
    };
    CFDictionaryRef attributes = CFDictionaryCreate(
        allocator,
        keys,
        values,
        5,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks);
    if (widthNumber) CFRelease(widthNumber);
    if (heightNumber) CFRelease(heightNumber);
    if (pixelFormatNumber) CFRelease(pixelFormatNumber);
    if (ioSurface) CFRelease(ioSurface);
    return attributes;
}

static bool ExtractFrameIndex(CMSampleBufferRef sampleBuffer, uint32_t &frameIndexOut)
{
    if (!sampleBuffer || CMSampleBufferGetNumSamples(sampleBuffer) < 1) {
        return false;
    }

    CMBlockBufferRef dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer);
    if (!dataBuffer) {
        return false;
    }

    // Our format reader produces 4-byte synthetic sample buffers that carry the
    // frame index. Real BRAW frame bytes coming from AVFoundation's QT reader are
    // much larger, so the size check disambiguates the two routing paths.
    size_t totalSize = CMBlockBufferGetDataLength(dataBuffer);
    if (totalSize != sizeof(uint32_t)) {
        return false;
    }

    CMBlockBufferRef contiguous = nullptr;
    if (!CMBlockBufferIsRangeContiguous(dataBuffer, 0, 0)) {
        if (CMBlockBufferCreateContiguous(kCFAllocatorDefault, dataBuffer, kCFAllocatorDefault, nullptr, 0, 0, 0, &contiguous) != noErr || !contiguous) {
            return false;
        }
        dataBuffer = contiguous;
    }

    char *data = nullptr;
    OSStatus status = CMBlockBufferGetDataPointer(dataBuffer, 0, nullptr, nullptr, &data);
    if (contiguous) {
        CFRelease(contiguous);
    }
    if (status != noErr || !data) {
        return false;
    }

    memcpy(&frameIndexOut, data, sizeof(frameIndexOut));
    return true;
}

static CVPixelBufferRef CreatePixelBuffer(BRAWVideoDecoder *decoder)
{
    CVPixelBufferPoolRef pool = decoder->session ? VTDecoderSessionGetPixelBufferPool(decoder->session) : nullptr;
    CVPixelBufferRef pixelBuffer = nullptr;
    if (pool && CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer) == noErr && pixelBuffer) {
        return pixelBuffer;
    }

    CFDictionaryRef attributes = CreatePixelBufferAttributes(decoder->allocator, decoder->info);
    CVReturn status = CVPixelBufferCreate(
        decoder->allocator,
        decoder->info.width,
        decoder->info.height,
        kCVPixelFormatType_32BGRA,
        attributes,
        &pixelBuffer);
    if (attributes) {
        CFRelease(attributes);
    }
    if (status != kCVReturnSuccess) {
        return nullptr;
    }
    return pixelBuffer;
}

// The decoder bundle is built with -fvisibility=hidden and links cleanly, so it
// can't directly reference host-side SpliceKit symbols. When loaded inside an
// FCP process that has SpliceKit injected, dlsym(RTLD_DEFAULT, ...) locates
// the host-side lookup helper. When loaded in a different host, this resolves
// to NULL and we fall back to the format description's embedded BrwP atom.
typedef NSString *(*SpliceKitBRAWLookupFn)(CMFormatDescriptionRef);

static SpliceKitBRAWLookupFn ResolveHostLookupFunction()
{
    static SpliceKitBRAWLookupFn fn = (SpliceKitBRAWLookupFn)-1;
    if (fn == (SpliceKitBRAWLookupFn)-1) {
        fn = (SpliceKitBRAWLookupFn)dlsym(RTLD_DEFAULT, "SpliceKitBRAWLookupPathForFormatDescription");
        Log(@"decoder", @"host lookup fn %@", fn ? @"available" : @"unavailable");
    }
    return fn;
}

static CFStringRef ResolveClipPathForFormatDescription(CMFormatDescriptionRef formatDescription)
{
    CFStringRef path = CopyPathFromFormatDescription(formatDescription);
    if (path) {
        return path;
    }
    SpliceKitBRAWLookupFn hostLookup = ResolveHostLookupFunction();
    if (hostLookup) {
        @autoreleasepool {
            NSString *resolved = hostLookup(formatDescription);
            if (resolved.length) {
                return (CFStringRef)CFBridgingRetain([resolved copy]);
            }
        }
    }
    return nullptr;
}

static OSStatus StartDecoderSession(VTVideoDecoderRef decoderRef, VTVideoDecoderSession session, CMVideoFormatDescriptionRef formatDescription)
{
    BRAWVideoDecoder *decoder = DecoderFromRef(decoderRef);
    if (!decoder || !session || !formatDescription) {
        return paramErr;
    }

    std::lock_guard<std::mutex> lock(decoder->decodeMutex);
    CFStringRef path = ResolveClipPathForFormatDescription(formatDescription);
    if (!path) {
        Log(@"decoder", @"no path for format description (no BrwP atom and no host-side registration)");
        return kVTVideoDecoderBadDataErr;
    }

    bool ready = ConfigureDecoderRuntime(decoder, path, formatDescription);
    CFRelease(path);
    if (!ready) {
        return kVTVideoDecoderBadDataErr;
    }

    decoder->session = session;
    if (decoder->formatDescription) {
        CFRelease(decoder->formatDescription);
    }
    decoder->formatDescription = (CMVideoFormatDescriptionRef)CFRetain(formatDescription);

    CFDictionaryRef pixelBufferAttributes = CreatePixelBufferAttributes(decoder->allocator, decoder->info);
    if (pixelBufferAttributes) {
        VTDecoderSessionSetPixelBufferAttributes(session, pixelBufferAttributes);
        CFRelease(pixelBufferAttributes);
    }

    Log(@"decoder", @"session ready for %@ (%ux%u %.3f fps)",
        CopyNSString(decoder->currentPath), decoder->info.width, decoder->info.height, decoder->info.frameRate);
    return noErr;
}

static uint32_t FrameIndexForSampleBuffer(const BRAWVideoDecoder *decoder, CMSampleBufferRef sampleBuffer)
{
    // Preferred: presentation time stamp → frame index using the clip's frame rate.
    CMSampleTimingInfo timing = {};
    if (CMSampleBufferGetSampleTimingInfo(sampleBuffer, 0, &timing) == noErr &&
        CMTIME_IS_NUMERIC(timing.presentationTimeStamp)) {
        uint64_t idx = FrameIndexForTime(timing.presentationTimeStamp, decoder->info);
        return (uint32_t)idx;
    }
    return 0;
}

static bool SKBRAWEnvFlag(const char *name, BOOL defaultValue)
{
    const char *env = getenv(name);
    if (!env) return defaultValue;
    return (env[0] == '1' || env[0] == 'Y' || env[0] == 'y');
}

// Real host-delegated decode is now the default. Set SPLICEKIT_BRAW_STUB_DECODE=1
// to fall back to gray placeholder frames (useful for isolating BRAW SDK
// issues from the format reader / session plumbing).
static bool SKBRAWStubDecodeEnabled()
{
    static BOOL value;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        value = SKBRAWEnvFlag("SPLICEKIT_BRAW_STUB_DECODE", NO);
        if (!value) {
            value = [[NSUserDefaults standardUserDefaults] boolForKey:@"SpliceKitBRAWStubDecode"];
        }
    });
    return value;
}

// Host decode is on by default. Set SPLICEKIT_BRAW_HOST_DECODE=0 to disable
// (then the stub fallback emits gray frames).
static bool SKBRAWHostDecodeOptedIn()
{
    static BOOL value;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        value = SKBRAWEnvFlag("SPLICEKIT_BRAW_HOST_DECODE", YES);
    });
    return value;
}

static void FillBytesSolid(CVPixelBufferRef pixelBuffer)
{
    if (!pixelBuffer) return;
    CVPixelBufferLockBaseAddress(pixelBuffer, 0);
    uint8_t *base = static_cast<uint8_t *>(CVPixelBufferGetBaseAddress(pixelBuffer));
    size_t bpr = CVPixelBufferGetBytesPerRow(pixelBuffer);
    size_t h = CVPixelBufferGetHeight(pixelBuffer);
    if (base) {
        // kCVPixelFormatType_32BGRA. Fill with opaque mid-gray so a stubbed
        // frame is visibly distinct from a real decode.
        for (size_t row = 0; row < h; row++) {
            uint32_t *px = reinterpret_cast<uint32_t *>(base + row * bpr);
            size_t w = bpr / 4;
            for (size_t i = 0; i < w; i++) {
                px[i] = 0xFF808080;
            }
        }
    }
    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
}

// Host-side decode helpers, resolved via dlsym. The pixel-buffer variant is
// the preferred zero-copy path: the host runs the BRAW Metal pipeline and
// GPU-blits the result straight into our IOSurface-backed pool buffer. The
// bytes variant is the legacy fallback when Metal isn't available on the
// device or the host build doesn't export the new symbol.
typedef BOOL (*SKBRAWHostDecodeFn)(CFStringRef, uint32_t, uint32_t, uint32_t,
                                    uint32_t *, uint32_t *, uint32_t *, void **);
typedef BOOL (*SKBRAWHostDecodeIntoPBFn)(CFStringRef, uint32_t, uint32_t,
                                          CVPixelBufferRef, uint32_t *, uint32_t *);

static SKBRAWHostDecodeFn ResolveHostDecodeFn()
{
    static SKBRAWHostDecodeFn fn = (SKBRAWHostDecodeFn)-1;
    if (fn == (SKBRAWHostDecodeFn)-1) {
        fn = (SKBRAWHostDecodeFn)dlsym(RTLD_DEFAULT, "SpliceKitBRAW_DecodeFrameBytes");
        Log(@"decoder", @"host decode fn %@", fn ? @"available" : @"unavailable");
    }
    return fn;
}

static SKBRAWHostDecodeIntoPBFn ResolveHostDecodeIntoPBFn()
{
    static SKBRAWHostDecodeIntoPBFn fn = (SKBRAWHostDecodeIntoPBFn)-1;
    if (fn == (SKBRAWHostDecodeIntoPBFn)-1) {
        fn = (SKBRAWHostDecodeIntoPBFn)dlsym(RTLD_DEFAULT, "SpliceKitBRAW_DecodeFrameIntoPixelBuffer");
        Log(@"decoder", @"host decode-into-PB fn %@", fn ? @"available" : @"unavailable");
    }
    return fn;
}

static SKBRAWHostReleaseFn ResolveHostReleaseFn()
{
    static SKBRAWHostReleaseFn fn = (SKBRAWHostReleaseFn)-1;
    if (fn == (SKBRAWHostReleaseFn)-1) {
        fn = (SKBRAWHostReleaseFn)dlsym(RTLD_DEFAULT, "SpliceKitBRAW_ReleaseClip");
    }
    return fn;
}

static void BlitBGRA_FromBGRA(uint8_t *dst, size_t dstBytesPerRow,
                               const uint8_t *src, size_t srcBytesPerRow,
                               size_t height)
{
    size_t copyBytes = std::min(dstBytesPerRow, srcBytesPerRow);
    for (size_t row = 0; row < height; row++) {
        memcpy(dst + row * dstBytesPerRow, src + row * srcBytesPerRow, copyBytes);
    }
}

static OSStatus EmitDecodedFrame_FromHostBytes(BRAWVideoDecoder *decoder,
                                                VTVideoDecoderFrame frame,
                                                uint32_t width,
                                                uint32_t height,
                                                uint32_t sizeBytes,
                                                const uint8_t *bytes)
{
    if (!bytes || width == 0 || height == 0 || sizeBytes == 0) {
        return kVTVideoDecoderBadDataErr;
    }

    CVPixelBufferRef pixelBuffer = CreatePixelBuffer(decoder);
    if (!pixelBuffer) {
        Log(@"decoder", @"failed to get pixel buffer");
        return kVTAllocationFailedErr;
    }

    size_t pbW = CVPixelBufferGetWidth(pixelBuffer);
    size_t pbH = CVPixelBufferGetHeight(pixelBuffer);
    size_t pbBpr = CVPixelBufferGetBytesPerRow(pixelBuffer);
    size_t expectedSrcBpr = (size_t)width * 4;
    size_t srcBpr = height > 0 ? (sizeBytes / height) : expectedSrcBpr;

    static bool loggedOnce = false;
    if (!loggedOnce) {
        Log(@"decoder", @"pool buffer %zux%zu bpr=%zu, src %ux%u bpr=%zu (expected %zu)",
            pbW, pbH, pbBpr, width, height, srcBpr, expectedSrcBpr);
        loggedOnce = true;
    }

    // Sanity: the SDK promised RGBAU8 at w*h*4 bytes. Anything else means the
    // pipeline returned a non-CPU resource, or the format was downgraded without
    // our knowledge. Bailing out prevents writing nonsense into the IOSurface.
    if (srcBpr != expectedSrcBpr) {
        Log(@"decoder", @"srcBpr %zu != expected %zu; bailing", srcBpr, expectedSrcBpr);
        CFRelease(pixelBuffer);
        return kVTVideoDecoderBadDataErr;
    }

    CVPixelBufferLockBaseAddress(pixelBuffer, 0);
    uint8_t *dst = static_cast<uint8_t *>(CVPixelBufferGetBaseAddress(pixelBuffer));

    size_t copyW = std::min<size_t>(width, pbW);
    size_t copyH = std::min<size_t>(height, pbH);

    // If the pool buffer is larger than the decoded frame (padded format
    // description), clear the whole surface first so the leftover strip on the
    // right/bottom doesn't show stale pixels from a previously recycled buffer.
    if (pbW > copyW || pbH > copyH) {
        memset(dst, 0, pbBpr * pbH);
    }

    // Host returns RGBAU8; pool buffer is 32BGRA. SIMD channel swap via vImage.
    vImage_Buffer srcBuf = { (void *)bytes, (vImagePixelCount)copyH, (vImagePixelCount)copyW, srcBpr };
    vImage_Buffer dstBuf = { dst, (vImagePixelCount)copyH, (vImagePixelCount)copyW, pbBpr };
    const uint8_t channelMap[4] = { 2, 1, 0, 3 };  // RGBA → BGRA
    vImage_Error err = vImagePermuteChannels_ARGB8888(&srcBuf, &dstBuf, channelMap, kvImageDoNotTile);
    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);

    if (err != kvImageNoError) {
        Log(@"decoder", @"vImagePermuteChannels failed %ld", (long)err);
        CFRelease(pixelBuffer);
        return kVTVideoDecoderBadDataErr;
    }

    OSStatus status = VTDecoderSessionEmitDecodedFrame(decoder->session, frame, noErr, 0, pixelBuffer);
    CFRelease(pixelBuffer);
    return status;
}

static OSStatus DecodeFrame(VTVideoDecoderRef decoderRef, VTVideoDecoderFrame frame, CMSampleBufferRef sampleBuffer, VTDecodeFrameFlags, VTDecodeInfoFlags *infoFlagsOut)
{
    BRAWVideoDecoder *decoder = DecoderFromRef(decoderRef);
    if (!decoder || !sampleBuffer) {
        return paramErr;
    }

    std::lock_guard<std::mutex> lock(decoder->decodeMutex);

    uint32_t frameIndex = 0;
    if (!ExtractFrameIndex(sampleBuffer, frameIndex)) {
        frameIndex = FrameIndexForSampleBuffer(decoder, sampleBuffer);
    }

    if (infoFlagsOut) *infoFlagsOut = 0;

    // Stub path: safest default. Emits gray frames without touching BRAW SDK,
    // keeps FCP stable.
    if (SKBRAWStubDecodeEnabled()) {
        CVPixelBufferRef pb = CreatePixelBuffer(decoder);
        if (!pb) return kVTAllocationFailedErr;
        FillBytesSolid(pb);
        OSStatus s = VTDecoderSessionEmitDecodedFrame(decoder->session, frame, noErr, 0, pb);
        CFRelease(pb);
        return s;
    }

    if (SKBRAWHostDecodeOptedIn() && decoder->currentPath) {
        // Preferred path: zero-copy Metal. The host runs BRAW's Metal pipeline,
        // blits the result straight into this CVPixelBuffer's IOSurface via a
        // GPU blit command, and returns once the command buffer has completed.
        // No CPU memcpy of the ~170 MB frame, no vImage channel swap.
        if (SKBRAWHostDecodeIntoPBFn hostDecodePB = ResolveHostDecodeIntoPBFn()) {
            CVPixelBufferRef pb = CreatePixelBuffer(decoder);
            if (pb) {
                uint32_t w = 0, h = 0;
                BOOL ok = hostDecodePB(decoder->currentPath, frameIndex, 0, pb, &w, &h);
                if (ok) {
                    OSStatus s = VTDecoderSessionEmitDecodedFrame(decoder->session, frame, noErr, 0, pb);
                    CFRelease(pb);
                    return s;
                }
                CFRelease(pb);
                Log(@"decoder", @"host decode-into-PB failed frame=%u; falling back to bytes path", frameIndex);
            }
        }

        // Fallback: CPU-bytes path. Slower but still correct.
        if (SKBRAWHostDecodeFn hostDecode = ResolveHostDecodeFn()) {
            uint32_t w = 0, h = 0, sz = 0;
            void *hostBytes = nullptr;
            // scale=0 (full), format=0 (RGBAU8).
            BOOL ok = hostDecode(decoder->currentPath, frameIndex, 0, 0, &w, &h, &sz, &hostBytes);
            if (ok && hostBytes && sz > 0) {
                OSStatus status = EmitDecodedFrame_FromHostBytes(decoder, frame, w, h, sz, (const uint8_t *)hostBytes);
                free(hostBytes);
                return status;
            }
            if (hostBytes) free(hostBytes);
            Log(@"decoder", @"host decode-bytes failed frame=%u", frameIndex);
        }
    }

    // Nothing handled the frame — emit gray as a last-resort so the session
    // doesn't starve the pipeline.
    CVPixelBufferRef pb = CreatePixelBuffer(decoder);
    if (!pb) return kVTAllocationFailedErr;
    FillBytesSolid(pb);
    OSStatus s = VTDecoderSessionEmitDecodedFrame(decoder->session, frame, noErr, 0, pb);
    CFRelease(pb);
    return s;
}

static OSStatus CopySupportedPropertyDictionary(VTVideoDecoderRef decoderRef, CFDictionaryRef *dictionaryOut)
{
    BRAWVideoDecoder *decoder = DecoderFromRef(decoderRef);
    if (!decoder || !dictionaryOut || !decoder->supportedProperties) {
        return paramErr;
    }
    *dictionaryOut = CFDictionaryCreateCopy(decoder->allocator, decoder->supportedProperties);
    return *dictionaryOut ? noErr : kCMBaseObjectError_ValueNotAvailable;
}

static OSStatus SetDecoderProperties(VTVideoDecoderRef, CFDictionaryRef)
{
    return noErr;
}

static OSStatus CopySerializableProperties(VTVideoDecoderRef decoderRef, CFDictionaryRef *dictionaryOut)
{
    if (!dictionaryOut) {
        return paramErr;
    }
    BRAWVideoDecoder *decoder = DecoderFromRef(decoderRef);
    *dictionaryOut = CFDictionaryCreate(
        decoder ? decoder->allocator : kCFAllocatorDefault,
        nullptr,
        nullptr,
        0,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks);
    return *dictionaryOut ? noErr : kCMBaseObjectError_ValueNotAvailable;
}

static Boolean CanAcceptFormatDescription(VTVideoDecoderRef decoderRef, CMVideoFormatDescriptionRef formatDescription)
{
    if (!formatDescription) {
        return false;
    }
    FourCharCode subType = CMFormatDescriptionGetMediaSubType(formatDescription);
    if (subType != kCodecType && subType != 'brxq' && subType != 'brst' &&
        subType != 'brvn' && subType != 'brs2' && subType != 'brxh') {
        return false;
    }

    BRAWVideoDecoder *decoder = DecoderFromRef(decoderRef);

    CMVideoDimensions dims = CMVideoFormatDescriptionGetDimensions(formatDescription);
    char fcc[5] = { (char)((subType >> 24) & 0xff), (char)((subType >> 16) & 0xff),
                    (char)((subType >> 8) & 0xff), (char)(subType & 0xff), 0 };

    // If VideoToolbox is probing whether it can keep using this decoder across
    // a session boundary, we MUST verify that the new format description still
    // points at the same .braw clip we previously bound to. Otherwise VT will
    // reuse the session and decode the wrong file.
    //
    // When the decoder has no bound clip yet, accept if we can resolve any path
    // (either from a BrwP atom or the host's path registry). If resolution
    // fails entirely, reject so VT knows to surface the error rather than
    // fall back on stale decoder state.
    CFStringRef resolved = ResolveClipPathForFormatDescription(formatDescription);

    if (decoder && decoder->currentPath) {
        Boolean sameClip = resolved ? CFEqual(resolved, decoder->currentPath) : false;
        Log(@"decoder", @"canAccept fcc=%s fd=%p dims=%dx%d resolved=%@ currentPath=%@ -> %s",
            fcc, formatDescription, dims.width, dims.height,
            resolved ? CopyNSString(resolved) : @"<nil>",
            CopyNSString(decoder->currentPath),
            sameClip ? "accept" : "reject");
        if (resolved) CFRelease(resolved);
        return sameClip;
    }

    Boolean haveAPath = resolved != nullptr;
    Log(@"decoder", @"canAccept fcc=%s fd=%p dims=%dx%d resolved=%@ (fresh decoder) -> %s",
        fcc, formatDescription, dims.width, dims.height,
        resolved ? CopyNSString(resolved) : @"<nil>",
        haveAPath ? "accept" : "reject");
    if (resolved) CFRelease(resolved);
    return haveAPath;
}

static OSStatus FinishDelayedFrames(VTVideoDecoderRef)
{
    return noErr;
}

} // namespace

extern "C" __attribute__((visibility("default")))
OSStatus BRAWVideoDecoder_CreateInstance(FourCharCode, CFAllocatorRef allocator, VTVideoDecoderRef *decoderOut)
{
    if (!decoderOut) {
        return paramErr;
    }

    Log(@"decoder", @"factory createInstance");

    VTVideoDecoderRef decoder = nullptr;
    OSStatus status = CMDerivedObjectCreate(
        allocator ?: kCFAllocatorDefault,
        &kDecoderVTable.base,
        VTVideoDecoderGetClassID(),
        reinterpret_cast<CMBaseObjectRef *>(&decoder));
    if (status != noErr || !decoder) {
        return status ? status : kVTAllocationFailedErr;
    }

    new (Storage<BRAWVideoDecoder>(reinterpret_cast<CMBaseObjectRef>(decoder))) BRAWVideoDecoder(allocator);
    *decoderOut = decoder;
    return noErr;
}
