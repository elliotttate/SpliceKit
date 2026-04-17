#include "BRAWCommon.h"

#include <AudioToolbox/AudioToolbox.h>
#include <CoreMedia/CMFormatDescription.h>
#include <VideoToolbox/VTDecompressionProperties.h>
#include <dlfcn.h>

namespace SpliceKitBRAW {

namespace {

#if SPLICEKIT_BRAW_SDK_AVAILABLE
typedef IBlackmagicRawFactory *(*CreateFactoryFn)(void);
typedef IBlackmagicRawFactory *(*CreateFactoryFromPathFn)(CFStringRef);
#endif

CFStringRef CopyAtomDataAsPath(CFDataRef data)
{
    if (!data) {
        return nullptr;
    }
    CFStringRef string = CFStringCreateFromExternalRepresentation(kCFAllocatorDefault, data, kCFStringEncodingUTF8);
    if (!string) {
        return nullptr;
    }
    NSString *standardized = [(__bridge NSString *)string stringByStandardizingPath];
    CFRelease(string);
    if (!standardized.length) {
        return nullptr;
    }
    return (CFStringRef)CFRetain((__bridge CFTypeRef)standardized);
}

} // namespace

void Log(NSString *component, NSString *format, ...)
{
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    if (!component.length) {
        component = @"common";
    }

    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", component, message ?: @""];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    FILE *file = fopen("/tmp/splicekit-braw.log", "a");
    if (file) {
        fwrite(data.bytes, 1, data.length, file);
        fclose(file);
    }
}

NSString *DescribeOSStatus(OSStatus status)
{
    return [NSString stringWithFormat:@"0x%08X", (unsigned int)status];
}

NSString *DescribeHRESULT(HRESULT status)
{
    return [NSString stringWithFormat:@"0x%08X", (unsigned int)status];
}

NSString *CopyNSString(CFStringRef value)
{
    if (!value) {
        return nil;
    }
    return [(__bridge NSString *)value copy];
}

CFStringRef CopyStandardizedPath(CFStringRef rawPath)
{
    if (!rawPath) {
        return nullptr;
    }
    NSString *standardized = [(__bridge NSString *)rawPath stringByStandardizingPath];
    if (!standardized.length) {
        return nullptr;
    }
    return (CFStringRef)CFRetain((__bridge CFTypeRef)standardized);
}

CFStringRef CopyStandardizedPathFromByteSource(MTPluginByteSourceRef byteSource)
{
    if (!byteSource) {
        return nullptr;
    }
    CFStringRef raw = MTPluginByteSourceCopyFileName(byteSource);
    if (!raw) {
        return nullptr;
    }
    CFStringRef standardized = CopyStandardizedPath(raw);
    CFRelease(raw);
    return standardized;
}

CFStringRef CopyPathFromFormatDescription(CMFormatDescriptionRef formatDescription)
{
    if (!formatDescription) {
        return nullptr;
    }
    CFDictionaryRef extensions = (CFDictionaryRef)CMFormatDescriptionGetExtension(
        formatDescription,
        kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms);
    if (!extensions || CFGetTypeID(extensions) != CFDictionaryGetTypeID()) {
        return nullptr;
    }
    CFDataRef data = (CFDataRef)CFDictionaryGetValue(extensions, CFSTR("BrwP"));
    if (!data || CFGetTypeID(data) != CFDataGetTypeID()) {
        return nullptr;
    }
    return CopyAtomDataAsPath(data);
}

CFDictionaryRef CreatePathAtomDictionary(CFAllocatorRef allocator, CFStringRef filePath)
{
    if (!filePath) {
        return nullptr;
    }
    CFDataRef pathData = CFStringCreateExternalRepresentation(
        allocator ?: kCFAllocatorDefault,
        filePath,
        kCFStringEncodingUTF8,
        ' ');
    if (!pathData) {
        return nullptr;
    }
    const void *keys[] = { CFSTR("BrwP") };
    const void *values[] = { pathData };
    CFDictionaryRef dictionary = CFDictionaryCreate(
        allocator ?: kCFAllocatorDefault,
        keys,
        values,
        1,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks);
    CFRelease(pathData);
    return dictionary;
}

CMVideoFormatDescriptionRef CreateVideoFormatDescription(CFAllocatorRef allocator, CFStringRef filePath, const ClipInfo &info)
{
    CFDictionaryRef atoms = CreatePathAtomDictionary(allocator, filePath);
    if (!atoms) {
        return nullptr;
    }

    CFMutableDictionaryRef extensions = CFDictionaryCreateMutable(
        allocator ?: kCFAllocatorDefault,
        0,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks);
    if (!extensions) {
        CFRelease(atoms);
        return nullptr;
    }

    CFDictionarySetValue(extensions, kCMFormatDescriptionExtension_FormatName, CFSTR("Blackmagic RAW"));
    CFDictionarySetValue(extensions, kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms, atoms);
    CFRelease(atoms);

    CMVideoFormatDescriptionRef formatDescription = nullptr;
    OSStatus status = CMVideoFormatDescriptionCreate(
        allocator ?: kCFAllocatorDefault,
        kCodecType,
        (int32_t)info.width,
        (int32_t)info.height,
        extensions,
        &formatDescription);
    CFRelease(extensions);
    if (status != noErr) {
        Log(@"common", @"CMVideoFormatDescriptionCreate failed %@", DescribeOSStatus(status));
        return nullptr;
    }
    return formatDescription;
}

CMAudioFormatDescriptionRef CreateAudioFormatDescription(CFAllocatorRef allocator, const AudioClipInfo &audio)
{
    if (!audio.present || audio.sampleRate == 0 || audio.channelCount == 0 || audio.bitDepth == 0) {
        return nullptr;
    }
    AudioStreamBasicDescription asbd = {};
    asbd.mSampleRate = (Float64)audio.sampleRate;
    asbd.mFormatID = kAudioFormatLinearPCM;
    // BRAW SDK returns signed integer PCM interleaved packed.
    asbd.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
    asbd.mFramesPerPacket = 1;
    asbd.mChannelsPerFrame = audio.channelCount;
    asbd.mBitsPerChannel = audio.bitDepth;
    asbd.mBytesPerFrame = (audio.bitDepth / 8) * audio.channelCount;
    asbd.mBytesPerPacket = asbd.mBytesPerFrame;

    CMAudioFormatDescriptionRef formatDescription = nullptr;
    OSStatus status = CMAudioFormatDescriptionCreate(
        allocator ?: kCFAllocatorDefault,
        &asbd,
        0, nullptr,
        0, nullptr,
        nullptr,
        &formatDescription);
    if (status != noErr) {
        Log(@"common", @"CMAudioFormatDescriptionCreate failed %@", DescribeOSStatus(status));
        return nullptr;
    }
    return formatDescription;
}

CMTime FrameDurationForRate(double frameRate)
{
    if (!(frameRate > 0.0)) {
        frameRate = 24.0;
    }
    return CMTimeMakeWithSeconds(1.0 / frameRate, 600000);
}

uint64_t FrameIndexForTime(CMTime time, const ClipInfo &info)
{
    if (info.frameCount == 0) {
        return 0;
    }
    if (!CMTIME_IS_NUMERIC(time) || CMTIME_COMPARE_INLINE(time, <=, kCMTimeZero)) {
        return 0;
    }
    Float64 seconds = CMTimeGetSeconds(time);
    if (!(seconds > 0.0)) {
        return 0;
    }
    uint64_t index = (uint64_t)floor(seconds * info.frameRate + 0.0001);
    if (index >= info.frameCount) {
        index = info.frameCount - 1;
    }
    return index;
}

#if SPLICEKIT_BRAW_SDK_AVAILABLE
IBlackmagicRawFactory *CreateFactory(std::string &error)
{
    NSArray<NSDictionary *> *candidates = @[
        @{
            @"binary": @"/Applications/Blackmagic RAW/Blackmagic RAW SDK/Mac/Libraries/BlackmagicRawAPI.framework/BlackmagicRawAPI",
            @"loadPath": @"/Applications/Blackmagic RAW/Blackmagic RAW SDK/Mac/Libraries",
        },
        @{
            @"binary": @"/Applications/Blackmagic RAW/Blackmagic RAW Player.app/Contents/Frameworks/BlackmagicRawAPI.framework/BlackmagicRawAPI",
            @"loadPath": @"/Applications/Blackmagic RAW/Blackmagic RAW Player.app/Contents/Frameworks",
        },
    ];

    NSMutableArray<NSString *> *attempts = [NSMutableArray array];
    for (NSDictionary *candidate in candidates) {
        NSString *binary = candidate[@"binary"];
        NSString *loadPath = candidate[@"loadPath"];
        if (![[NSFileManager defaultManager] fileExistsAtPath:binary]) {
            [attempts addObject:[NSString stringWithFormat:@"%@ missing", binary]];
            continue;
        }

        void *image = dlopen(binary.UTF8String, RTLD_NOW | RTLD_GLOBAL);
        if (!image) {
            [attempts addObject:[NSString stringWithFormat:@"%@ dlopen failed: %s", binary, dlerror() ?: "unknown"]];
            continue;
        }

        auto createFromPath = (CreateFactoryFromPathFn)dlsym(image, "CreateBlackmagicRawFactoryInstanceFromPath");
        auto createDirect = (CreateFactoryFn)dlsym(image, "CreateBlackmagicRawFactoryInstance");
        IBlackmagicRawFactory *factory = nullptr;
        if (createFromPath) {
            factory = createFromPath((__bridge CFStringRef)loadPath);
        }
        if (!factory && createDirect) {
            factory = createDirect();
        }
        if (factory) {
            return factory;
        }

        [attempts addObject:[NSString stringWithFormat:@"%@ factory creation failed", binary]];
    }

    error = attempts.count ? [[attempts componentsJoinedByString:@"; "] UTF8String] : "BRAW SDK not found";
    return nullptr;
}

bool ReadClipInfo(CFStringRef path, ClipInfo &info, std::string &error)
{
    info = ClipInfo {};
    if (!path) {
        error = "missing clip path";
        return false;
    }

    IBlackmagicRawFactory *factory = CreateFactory(error);
    if (!factory) {
        return false;
    }

    IBlackmagicRaw *codec = nullptr;
    IBlackmagicRawConfiguration *configuration = nullptr;
    IBlackmagicRawClip *clip = nullptr;

    HRESULT status = factory->CreateCodec(&codec);
    if (status != S_OK || !codec) {
        error = [[DescribeHRESULT(status) stringByAppendingString:@" CreateCodec failed"] UTF8String];
        factory->Release();
        return false;
    }

    if (codec->QueryInterface(IID_IBlackmagicRawConfiguration, (LPVOID *)&configuration) == S_OK && configuration) {
        configuration->SetPipeline(blackmagicRawPipelineCPU, nullptr, nullptr);
    }

    status = codec->OpenClip(path, &clip);
    if (status != S_OK || !clip) {
        error = [[DescribeHRESULT(status) stringByAppendingString:@" OpenClip failed"] UTF8String];
        if (configuration) {
            configuration->Release();
        }
        codec->Release();
        factory->Release();
        return false;
    }

    clip->GetWidth(&info.width);
    clip->GetHeight(&info.height);
    clip->GetFrameRate(&info.frameRate);
    clip->GetFrameCount(&info.frameCount);
    info.frameDuration = FrameDurationForRate(info.frameRate);
    info.duration = CMTimeMultiplyByFloat64(info.frameDuration, (Float64)info.frameCount);

    // Audio (optional)
    IBlackmagicRawClipAudio *audioClip = nullptr;
    if (clip->QueryInterface(IID_IBlackmagicRawClipAudio, (LPVOID *)&audioClip) == S_OK && audioClip) {
        uint32_t sampleRate = 0, channels = 0, bitDepth = 0;
        uint64_t sampleCount = 0;
        HRESULT srStatus = audioClip->GetAudioSampleRate(&sampleRate);
        HRESULT chStatus = audioClip->GetAudioChannelCount(&channels);
        HRESULT bdStatus = audioClip->GetAudioBitDepth(&bitDepth);
        HRESULT scStatus = audioClip->GetAudioSampleCount(&sampleCount);
        if (srStatus == S_OK && chStatus == S_OK && bdStatus == S_OK && scStatus == S_OK
            && sampleRate > 0 && channels > 0 && bitDepth > 0 && sampleCount > 0) {
            info.audio.sampleRate = sampleRate;
            info.audio.channelCount = channels;
            info.audio.bitDepth = bitDepth;
            info.audio.sampleCount = sampleCount;
            info.audio.present = true;
        }
        audioClip->Release();
    }

    clip->Release();
    if (configuration) {
        configuration->Release();
    }
    codec->Release();
    factory->Release();

    if (!info.width || !info.height || !info.frameCount) {
        error = "clip metadata is incomplete";
        return false;
    }
    return true;
}

#endif

} // namespace SpliceKitBRAW
