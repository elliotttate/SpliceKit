#include <AudioToolbox/AudioToolbox.h>
#include <CoreFoundation/CoreFoundation.h>
#include <math.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <limits.h>

#ifndef SKBP_PLUGIN_NAME
#define SKBP_PLUGIN_NAME "SpliceKit Audio Bus Probe"
#endif

#ifndef SKBP_METRICS_BASENAME
#define SKBP_METRICS_BASENAME "splicekit-audio-bus-probe"
#endif

#ifndef SKBP_AU_SUBTYPE
#define SKBP_AU_SUBTYPE 'SkBP'
#endif

#ifndef SKBP_AU_MANUFACTURER
#define SKBP_AU_MANUFACTURER 'SpKt'
#endif

#define SKBP_PARAM_COUNT 10
#define SKBP_MAX_PROPERTY_LISTENERS 16
#define SKBP_MAX_SCRATCH_BUFFERS 16
#define SKBP_RECEIVE_WINDOW_NS 1000000000ULL
#define SKBP_AUDIO_THRESHOLD 0.00001

enum {
    kSKBPParamReceivingAudio = 0,
    kSKBPParamInputPeak = 1,
    kSKBPParamInputRMS = 2,
    kSKBPParamAverageRenderMs = 3,
    kSKBPParamMaxRenderMs = 4,
    kSKBPParamCPULoad = 5,
    kSKBPParamLastRenderAgeMs = 6,
    kSKBPParamRenderCount = 7,
    kSKBPParamLastFrames = 8,
    kSKBPParamResetStats = 9,
};

typedef struct {
    AudioUnitPropertyID propertyID;
    AudioUnitPropertyListenerProc proc;
    void *userData;
} SKBPPropertyListener;

typedef struct {
    AudioComponentInstance componentInstance;
    AURenderCallbackStruct inputCallback;
    bool hasInputCallback;
    AudioUnitConnection connection;
    bool hasConnection;
    AudioStreamBasicDescription inputFormat;
    AudioStreamBasicDescription outputFormat;
    UInt32 maxFramesPerSlice;
    UInt32 renderQuality;
    bool bypass;
    void *scratchBuffers[SKBP_MAX_SCRATCH_BUFFERS];
    UInt32 scratchBufferSizes[SKBP_MAX_SCRATCH_BUFFERS];
    SKBPPropertyListener propertyListeners[SKBP_MAX_PROPERTY_LISTENERS];
    UInt32 propertyListenerCount;
    atomic_bool stopWriter;
    bool writerStarted;
    pthread_t writerThread;

    atomic_uint_fast64_t renderCount;
    atomic_uint_fast64_t nonSilentRenderCount;
    atomic_uint_fast64_t silentRenderCount;
    atomic_uint_fast64_t totalFrames;
    atomic_uint_fast64_t maxFrames;
    atomic_uint_fast64_t lastFrames;
    atomic_uint_fast64_t totalRenderNanos;
    atomic_uint_fast64_t lastRenderNanos;
    atomic_uint_fast64_t maxRenderNanos;
    atomic_uint_fast64_t lastRenderAtNanos;
    atomic_uint_fast32_t lastChannels;
    atomic_int lastError;
    _Atomic double lastPeak;
    _Atomic double lastRMS;
    _Atomic double sampleRate;

    char metricsPath[PATH_MAX];
    char latestPath[PATH_MAX];
} SKBPState;

typedef struct {
    AudioComponentPlugInInterface interface;
    SKBPState state;
} SKBPPlugin;

static AudioComponentMethod SKBPLookup(SInt16 selector);
static OSStatus SKBPRemovePropertyListenerWithUserData(void *self, AudioUnitPropertyID prop,
                                                       AudioUnitPropertyListenerProc proc,
                                                       void *userData);

static SKBPState *SKBPStateFromSelf(void *self)
{
    return self ? &((SKBPPlugin *)self)->state : NULL;
}

static uint64_t SKBPNowNanos(void)
{
    return clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
}

static void SKBPDefaultFormat(AudioStreamBasicDescription *format)
{
    memset(format, 0, sizeof(*format));
    format->mSampleRate = 48000.0;
    format->mFormatID = kAudioFormatLinearPCM;
    format->mFormatFlags = kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved;
    format->mBytesPerPacket = sizeof(float);
    format->mFramesPerPacket = 1;
    format->mBytesPerFrame = sizeof(float);
    format->mChannelsPerFrame = 2;
    format->mBitsPerChannel = 32;
}

static bool SKBPFormatIsUsable(const AudioStreamBasicDescription *format)
{
    return format &&
           format->mSampleRate > 0.0 &&
           format->mFormatID == kAudioFormatLinearPCM &&
           format->mChannelsPerFrame > 0 &&
           format->mFramesPerPacket > 0 &&
           format->mBytesPerFrame > 0 &&
           format->mBytesPerPacket > 0 &&
           format->mBitsPerChannel > 0;
}

static bool SKBPIsGlobalScope(AudioUnitScope scope)
{
    return scope == kAudioUnitScope_Global;
}

static bool SKBPIsInputOrOutputScope(AudioUnitScope scope)
{
    return scope == kAudioUnitScope_Input || scope == kAudioUnitScope_Output;
}

static bool SKBPPropertyScopeIsValid(AudioUnitPropertyID prop, AudioUnitScope scope)
{
    switch (prop) {
        case kAudioUnitProperty_MakeConnection:
        case kAudioUnitProperty_SetRenderCallback:
            return scope == kAudioUnitScope_Input;
        case kAudioUnitProperty_SampleRate:
        case kAudioUnitProperty_StreamFormat:
        case kAudioUnitProperty_ElementCount:
            return SKBPIsInputOrOutputScope(scope);
        case kAudioUnitProperty_ClassInfo:
        case kAudioUnitProperty_ParameterList:
        case kAudioUnitProperty_ParameterInfo:
        case kAudioUnitProperty_FastDispatch:
        case kAudioUnitProperty_CPULoad:
        case kAudioUnitProperty_Latency:
        case kAudioUnitProperty_SupportedNumChannels:
        case kAudioUnitProperty_MaximumFramesPerSlice:
        case kAudioUnitProperty_TailTime:
        case kAudioUnitProperty_BypassEffect:
        case kAudioUnitProperty_LastRenderError:
        case kAudioUnitProperty_RenderQuality:
        case kAudioUnitProperty_PresentPreset:
            return SKBPIsGlobalScope(scope);
        default:
            return false;
    }
}

static void SKBPPutUInt32(CFMutableDictionaryRef dictionary, CFStringRef key, UInt32 value)
{
    CFNumberRef number = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &value);
    if (number) {
        CFDictionarySetValue(dictionary, key, number);
        CFRelease(number);
    }
}

static void SKBPNotifyPropertyChanged(SKBPState *state, AudioUnitPropertyID propertyID,
                                      AudioUnitScope scope, AudioUnitElement element)
{
    for (UInt32 index = 0; index < state->propertyListenerCount; index++) {
        SKBPPropertyListener listener = state->propertyListeners[index];
        if (listener.proc && listener.propertyID == propertyID) {
            listener.proc(listener.userData,
                          (AudioUnit)state->componentInstance,
                          propertyID,
                          scope,
                          element);
        }
    }
}

static void SKBPResetStats(SKBPState *state)
{
    atomic_store(&state->renderCount, 0);
    atomic_store(&state->nonSilentRenderCount, 0);
    atomic_store(&state->silentRenderCount, 0);
    atomic_store(&state->totalFrames, 0);
    atomic_store(&state->maxFrames, 0);
    atomic_store(&state->lastFrames, 0);
    atomic_store(&state->totalRenderNanos, 0);
    atomic_store(&state->lastRenderNanos, 0);
    atomic_store(&state->maxRenderNanos, 0);
    atomic_store(&state->lastRenderAtNanos, 0);
    atomic_store(&state->lastChannels, 0);
    atomic_store(&state->lastError, noErr);
    atomic_store(&state->lastPeak, 0.0);
    atomic_store(&state->lastRMS, 0.0);
}

static double SKBPParameterValue(SKBPState *state, AudioUnitParameterID inID)
{
    uint64_t now = SKBPNowNanos();
    uint64_t count = atomic_load(&state->renderCount);
    uint64_t totalRender = atomic_load(&state->totalRenderNanos);
    uint64_t maxRender = atomic_load(&state->maxRenderNanos);
    uint64_t lastAt = atomic_load(&state->lastRenderAtNanos);
    uint64_t lastFrames = atomic_load(&state->lastFrames);
    double peak = atomic_load(&state->lastPeak);
    double sampleRate = atomic_load(&state->sampleRate);

    switch (inID) {
        case kSKBPParamReceivingAudio:
            return (lastAt != 0 && now - lastAt <= SKBP_RECEIVE_WINDOW_NS && peak > SKBP_AUDIO_THRESHOLD) ? 1.0 : 0.0;
        case kSKBPParamInputPeak:
            return peak;
        case kSKBPParamInputRMS:
            return atomic_load(&state->lastRMS);
        case kSKBPParamAverageRenderMs:
            return count == 0 ? 0.0 : ((double)totalRender / (double)count) / 1000000.0;
        case kSKBPParamMaxRenderMs:
            return (double)maxRender / 1000000.0;
        case kSKBPParamCPULoad: {
            double avgSeconds = count == 0 ? 0.0 : ((double)totalRender / (double)count) / 1000000000.0;
            double bufferSeconds = sampleRate > 0.0 && lastFrames > 0 ? (double)lastFrames / sampleRate : 0.0;
            return bufferSeconds > 0.0 ? fmin(avgSeconds / bufferSeconds, 1.0) : 0.0;
        }
        case kSKBPParamLastRenderAgeMs:
            return lastAt == 0 ? -1.0 : (double)(now - lastAt) / 1000000.0;
        case kSKBPParamRenderCount:
            return (double)count;
        case kSKBPParamLastFrames:
            return (double)lastFrames;
        case kSKBPParamResetStats:
            return 0.0;
        default:
            return 0.0;
    }
}

static void SKBPUpdateMax(atomic_uint_fast64_t *slot, uint64_t value)
{
    uint64_t current = atomic_load(slot);
    while (value > current && !atomic_compare_exchange_weak(slot, &current, value)) {
    }
}

static void SKBPZeroAudio(AudioBufferList *ioData)
{
    if (!ioData) {
        return;
    }
    for (UInt32 index = 0; index < ioData->mNumberBuffers; index++) {
        AudioBuffer *buffer = &ioData->mBuffers[index];
        if (buffer->mData && buffer->mDataByteSize > 0) {
            memset(buffer->mData, 0, buffer->mDataByteSize);
        }
    }
}

static OSStatus SKBPEnsureWritableBuffers(SKBPState *state, AudioBufferList *ioData, UInt32 inNumberFrames)
{
    if (!ioData) {
        return noErr;
    }
    if (ioData->mNumberBuffers > SKBP_MAX_SCRATCH_BUFFERS) {
        return kAudioUnitErr_TooManyFramesToProcess;
    }

    bool nonInterleaved = (state->outputFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
    UInt32 bytesPerFrame = state->outputFormat.mBytesPerFrame > 0 ? state->outputFormat.mBytesPerFrame : sizeof(float);
    UInt32 defaultChannels = nonInterleaved ? 1 : state->outputFormat.mChannelsPerFrame;
    if (defaultChannels == 0) {
        defaultChannels = 1;
    }

    for (UInt32 index = 0; index < ioData->mNumberBuffers; index++) {
        AudioBuffer *buffer = &ioData->mBuffers[index];
        UInt32 channels = buffer->mNumberChannels > 0 ? buffer->mNumberChannels : defaultChannels;
        UInt32 requiredBytes = buffer->mDataByteSize;
        if (requiredBytes == 0) {
            requiredBytes = inNumberFrames * bytesPerFrame * channels;
            buffer->mDataByteSize = requiredBytes;
        }
        if (buffer->mNumberChannels == 0) {
            buffer->mNumberChannels = channels;
        }
        if (!buffer->mData && requiredBytes > 0) {
            if (state->scratchBufferSizes[index] < requiredBytes) {
                void *newBuffer = realloc(state->scratchBuffers[index], requiredBytes);
                if (!newBuffer) {
                    return kAudioUnitErr_FailedInitialization;
                }
                state->scratchBuffers[index] = newBuffer;
                state->scratchBufferSizes[index] = requiredBytes;
            }
            buffer->mData = state->scratchBuffers[index];
        }
    }
    return noErr;
}

static bool SKBPHasNonzeroBytes(const void *data, UInt32 byteCount)
{
    const uint8_t *bytes = (const uint8_t *)data;
    for (UInt32 index = 0; index < byteCount; index++) {
        if (bytes[index] != 0) {
            return true;
        }
    }
    return false;
}

static void SKBPAnalyzeAudio(SKBPState *state, AudioBufferList *ioData, UInt32 inNumberFrames)
{
    double peak = 0.0;
    double squareSum = 0.0;
    uint64_t sampleCount = 0;
    UInt32 channelCount = 0;
    bool unknownNonzero = false;
    AudioStreamBasicDescription format = state->outputFormat;
    UInt32 bytesPerSample = format.mBitsPerChannel > 0 ? format.mBitsPerChannel / 8 : sizeof(float);
    bool isLinearPCM = format.mFormatID == kAudioFormatLinearPCM || format.mFormatID == 0;
    bool isFloat = (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0;
    bool isSignedInteger = (format.mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0;

    if (!ioData) {
        atomic_store(&state->lastPeak, 0.0);
        atomic_store(&state->lastRMS, 0.0);
        return;
    }

    for (UInt32 bufferIndex = 0; bufferIndex < ioData->mNumberBuffers; bufferIndex++) {
        AudioBuffer *buffer = &ioData->mBuffers[bufferIndex];
        if (!buffer->mData || buffer->mDataByteSize == 0) {
            continue;
        }

        UInt32 bufferChannels = buffer->mNumberChannels;
        if (bufferChannels == 0) {
            bufferChannels = format.mChannelsPerFrame > 0 ? format.mChannelsPerFrame : 1;
        }
        channelCount += bufferChannels;

        if (!isLinearPCM || bytesPerSample == 0) {
            unknownNonzero = unknownNonzero || SKBPHasNonzeroBytes(buffer->mData, buffer->mDataByteSize);
            continue;
        }

        uint64_t availableSamples = buffer->mDataByteSize / bytesPerSample;
        uint64_t expectedSamples = (uint64_t)inNumberFrames * (uint64_t)bufferChannels;
        uint64_t samples = expectedSamples > 0 && expectedSamples < availableSamples ? expectedSamples : availableSamples;

        if (isFloat && bytesPerSample == sizeof(float)) {
            const float *values = (const float *)buffer->mData;
            for (uint64_t index = 0; index < samples; index++) {
                double value = fabs((double)values[index]);
                peak = fmax(peak, value);
                squareSum += value * value;
            }
            sampleCount += samples;
        } else if (isFloat && bytesPerSample == sizeof(double)) {
            const double *values = (const double *)buffer->mData;
            for (uint64_t index = 0; index < samples; index++) {
                double value = fabs(values[index]);
                peak = fmax(peak, value);
                squareSum += value * value;
            }
            sampleCount += samples;
        } else if (isSignedInteger && bytesPerSample == sizeof(int16_t)) {
            const int16_t *values = (const int16_t *)buffer->mData;
            for (uint64_t index = 0; index < samples; index++) {
                double value = fabs((double)values[index] / 32768.0);
                peak = fmax(peak, value);
                squareSum += value * value;
            }
            sampleCount += samples;
        } else if (isSignedInteger && bytesPerSample == sizeof(int32_t)) {
            const int32_t *values = (const int32_t *)buffer->mData;
            for (uint64_t index = 0; index < samples; index++) {
                double value = fabs((double)values[index] / 2147483648.0);
                peak = fmax(peak, value);
                squareSum += value * value;
            }
            sampleCount += samples;
        } else {
            unknownNonzero = unknownNonzero || SKBPHasNonzeroBytes(buffer->mData, buffer->mDataByteSize);
        }
    }

    if (sampleCount == 0 && unknownNonzero) {
        peak = 1.0;
        squareSum = 1.0;
        sampleCount = 1;
    }

    double rms = sampleCount == 0 ? 0.0 : sqrt(squareSum / (double)sampleCount);
    atomic_store(&state->lastPeak, peak);
    atomic_store(&state->lastRMS, rms);
    atomic_store(&state->lastChannels, channelCount);
    if (peak > SKBP_AUDIO_THRESHOLD || rms > SKBP_AUDIO_THRESHOLD) {
        atomic_fetch_add(&state->nonSilentRenderCount, 1);
    } else {
        atomic_fetch_add(&state->silentRenderCount, 1);
    }
}

static void SKBPRecordRender(SKBPState *state, UInt32 inNumberFrames, uint64_t renderNanos)
{
    atomic_fetch_add(&state->renderCount, 1);
    atomic_fetch_add(&state->totalFrames, inNumberFrames);
    atomic_fetch_add(&state->totalRenderNanos, renderNanos);
    atomic_store(&state->lastFrames, inNumberFrames);
    atomic_store(&state->lastRenderNanos, renderNanos);
    atomic_store(&state->lastRenderAtNanos, SKBPNowNanos());
    SKBPUpdateMax(&state->maxFrames, inNumberFrames);
    SKBPUpdateMax(&state->maxRenderNanos, renderNanos);
}

static void SKBPWriteStatusPayload(SKBPState *state, FILE *file)
{
    uint64_t now = SKBPNowNanos();
    uint64_t count = atomic_load(&state->renderCount);
    uint64_t nonSilent = atomic_load(&state->nonSilentRenderCount);
    uint64_t silent = atomic_load(&state->silentRenderCount);
    uint64_t lastAt = atomic_load(&state->lastRenderAtNanos);
    double receive = SKBPParameterValue(state, kSKBPParamReceivingAudio);
    double avgMs = SKBPParameterValue(state, kSKBPParamAverageRenderMs);
    double cpuLoad = SKBPParameterValue(state, kSKBPParamCPULoad);
    double ageMs = lastAt == 0 ? -1.0 : (double)(now - lastAt) / 1000000.0;

    fprintf(file,
            "{\n"
            "  \"plugin\": \"%s\",\n"
            "  \"pid\": %d,\n"
            "  \"instance\": \"%p\",\n"
            "  \"receivingAudio\": %s,\n"
            "  \"renderCount\": %llu,\n"
            "  \"nonSilentRenderCount\": %llu,\n"
            "  \"silentRenderCount\": %llu,\n"
            "  \"lastRenderAgeMs\": %.3f,\n"
            "  \"lastFrames\": %llu,\n"
            "  \"maxFrames\": %llu,\n"
            "  \"channels\": %u,\n"
            "  \"sampleRate\": %.1f,\n"
            "  \"peak\": %.8f,\n"
            "  \"rms\": %.8f,\n"
            "  \"avgRenderMs\": %.6f,\n"
            "  \"lastRenderMs\": %.6f,\n"
            "  \"maxRenderMs\": %.6f,\n"
            "  \"cpuLoad\": %.8f,\n"
            "  \"lastError\": %d,\n"
            "  \"metricsPath\": \"%s\"\n"
            "}\n",
            SKBP_PLUGIN_NAME,
            getpid(),
            (void *)state,
            receive > 0.5 ? "true" : "false",
            (unsigned long long)count,
            (unsigned long long)nonSilent,
            (unsigned long long)silent,
            ageMs,
            (unsigned long long)atomic_load(&state->lastFrames),
            (unsigned long long)atomic_load(&state->maxFrames),
            (unsigned int)atomic_load(&state->lastChannels),
            atomic_load(&state->sampleRate),
            atomic_load(&state->lastPeak),
            atomic_load(&state->lastRMS),
            avgMs,
            (double)atomic_load(&state->lastRenderNanos) / 1000000.0,
            (double)atomic_load(&state->maxRenderNanos) / 1000000.0,
            cpuLoad,
            atomic_load(&state->lastError),
            state->metricsPath);
}

static void SKBPWriteStatus(SKBPState *state)
{
    char tempPath[PATH_MAX];
    snprintf(tempPath, sizeof(tempPath), "%s.tmp", state->metricsPath);

    FILE *file = fopen(tempPath, "w");
    if (!file) {
        return;
    }
    SKBPWriteStatusPayload(state, file);
    fclose(file);

    rename(tempPath, state->metricsPath);

    char latestTempPath[PATH_MAX];
    snprintf(latestTempPath, sizeof(latestTempPath), "%s.tmp", state->latestPath);
    FILE *latest = fopen(latestTempPath, "w");
    if (latest) {
        SKBPWriteStatusPayload(state, latest);
        fclose(latest);
        rename(latestTempPath, state->latestPath);
    }
    unlink(tempPath);
    unlink(latestTempPath);
}

static void *SKBPWriterMain(void *context)
{
    SKBPState *state = (SKBPState *)context;
    while (!atomic_load(&state->stopWriter)) {
        SKBPWriteStatus(state);
        usleep(250000);
    }
    SKBPWriteStatus(state);
    return NULL;
}

static OSStatus SKBPOpen(void *self, AudioComponentInstance mInstance)
{
    SKBPState *state = SKBPStateFromSelf(self);
    if (!state) {
        return kAudioUnitErr_Uninitialized;
    }
    memset(state, 0, sizeof(*state));

    state->componentInstance = mInstance;
    state->maxFramesPerSlice = 4096;
    state->renderQuality = kRenderQuality_Max;
    SKBPDefaultFormat(&state->inputFormat);
    SKBPDefaultFormat(&state->outputFormat);
    atomic_init(&state->sampleRate, state->outputFormat.mSampleRate);
    atomic_init(&state->stopWriter, false);
    snprintf(state->metricsPath, sizeof(state->metricsPath),
             "/tmp/%s-%d-%p.json", SKBP_METRICS_BASENAME, getpid(), (void *)state);
    snprintf(state->latestPath, sizeof(state->latestPath), "/tmp/%s-latest.json", SKBP_METRICS_BASENAME);
    SKBPResetStats(state);

    if (pthread_create(&state->writerThread, NULL, SKBPWriterMain, state) == 0) {
        state->writerStarted = true;
    }
    return noErr;
}

static OSStatus SKBPClose(void *self)
{
    SKBPState *state = SKBPStateFromSelf(self);
    if (!state) {
        return noErr;
    }
    atomic_store(&state->stopWriter, true);
    if (state->writerStarted) {
        pthread_join(state->writerThread, NULL);
        state->writerStarted = false;
    }
    SKBPWriteStatus(state);
    for (UInt32 index = 0; index < SKBP_MAX_SCRATCH_BUFFERS; index++) {
        free(state->scratchBuffers[index]);
        state->scratchBuffers[index] = NULL;
        state->scratchBufferSizes[index] = 0;
    }
    return noErr;
}

static OSStatus SKBPInitialize(void *self)
{
    SKBPState *state = SKBPStateFromSelf(self);
    if (!state) {
        return kAudioUnitErr_Uninitialized;
    }
    if (!SKBPFormatIsUsable(&state->inputFormat) ||
        !SKBPFormatIsUsable(&state->outputFormat) ||
        state->inputFormat.mChannelsPerFrame != state->outputFormat.mChannelsPerFrame ||
        (state->inputFormat.mChannelsPerFrame != 1 && state->inputFormat.mChannelsPerFrame != 2) ||
        (state->outputFormat.mChannelsPerFrame != 1 && state->outputFormat.mChannelsPerFrame != 2) ||
        state->inputFormat.mSampleRate != state->outputFormat.mSampleRate) {
        atomic_store(&state->lastError, kAudioUnitErr_FormatNotSupported);
        return kAudioUnitErr_FormatNotSupported;
    }
    atomic_store(&state->lastError, noErr);
    return noErr;
}

static OSStatus SKBPUninitialize(void *self)
{
    (void)self;
    return noErr;
}

static UInt32 SKBPPropertySize(AudioUnitPropertyID prop)
{
    switch (prop) {
        case kAudioUnitProperty_ClassInfo:
            return sizeof(CFPropertyListRef);
        case kAudioUnitProperty_MakeConnection:
            return sizeof(AudioUnitConnection);
        case kAudioUnitProperty_SampleRate:
            return sizeof(Float64);
        case kAudioUnitProperty_ParameterList:
            return sizeof(AudioUnitParameterID) * SKBP_PARAM_COUNT;
        case kAudioUnitProperty_ParameterInfo:
            return sizeof(AudioUnitParameterInfo);
        case kAudioUnitProperty_FastDispatch:
            return sizeof(void *);
        case kAudioUnitProperty_PresentPreset:
            return sizeof(AUPreset);
        case kAudioUnitProperty_CPULoad:
        case kAudioUnitProperty_Latency:
        case kAudioUnitProperty_TailTime:
            return sizeof(Float64);
        case kAudioUnitProperty_StreamFormat:
            return sizeof(AudioStreamBasicDescription);
        case kAudioUnitProperty_ElementCount:
        case kAudioUnitProperty_MaximumFramesPerSlice:
        case kAudioUnitProperty_RenderQuality:
        case kAudioUnitProperty_BypassEffect:
        case kAudioUnitProperty_LastRenderError:
            return sizeof(UInt32);
        case kAudioUnitProperty_SupportedNumChannels:
            return sizeof(AUChannelInfo) * 2;
        case kAudioUnitProperty_SetRenderCallback:
            return sizeof(AURenderCallbackStruct);
        default:
            return 0;
    }
}

static bool SKBPPropertyWritable(AudioUnitPropertyID prop)
{
    switch (prop) {
        case kAudioUnitProperty_MakeConnection:
        case kAudioUnitProperty_SampleRate:
        case kAudioUnitProperty_StreamFormat:
        case kAudioUnitProperty_MaximumFramesPerSlice:
        case kAudioUnitProperty_RenderQuality:
        case kAudioUnitProperty_BypassEffect:
        case kAudioUnitProperty_SetRenderCallback:
        case kAudioUnitProperty_PresentPreset:
            return true;
        default:
            return false;
    }
}

static OSStatus SKBPGetPropertyInfo(void *self, AudioUnitPropertyID prop, AudioUnitScope scope,
                                    AudioUnitElement elem, UInt32 *outDataSize, Boolean *outWritable)
{
    (void)self;
    (void)elem;
    if (!SKBPPropertyScopeIsValid(prop, scope)) {
        return kAudioUnitErr_InvalidProperty;
    }
    UInt32 size = SKBPPropertySize(prop);
    if (size == 0) {
        return kAudioUnitErr_InvalidProperty;
    }
    if (outDataSize) {
        *outDataSize = size;
    }
    if (outWritable) {
        *outWritable = SKBPPropertyWritable(prop);
    }
    return noErr;
}

static void SKBPSetParameterName(AudioUnitParameterInfo *info, const char *name, CFStringRef cfName)
{
    memset(info->name, 0, sizeof(info->name));
    strlcpy(info->name, name, sizeof(info->name));
    info->cfNameString = cfName;
    info->flags |= kAudioUnitParameterFlag_HasCFNameString;
}

static OSStatus SKBPFillParameterInfo(AudioUnitParameterID parameterID, AudioUnitParameterInfo *info)
{
    memset(info, 0, sizeof(*info));
    info->flags = kAudioUnitParameterFlag_IsReadable | kAudioUnitParameterFlag_MeterReadOnly |
                  kAudioUnitParameterFlag_IsHighResolution;
    info->minValue = 0.0f;
    info->defaultValue = 0.0f;
    info->maxValue = 1.0f;
    info->unit = kAudioUnitParameterUnit_Generic;

    switch (parameterID) {
        case kSKBPParamReceivingAudio:
            SKBPSetParameterName(info, "Receiving Audio", CFSTR("Receiving Audio"));
            info->unit = kAudioUnitParameterUnit_Boolean;
            break;
        case kSKBPParamInputPeak:
            SKBPSetParameterName(info, "Input Peak", CFSTR("Input Peak"));
            info->unit = kAudioUnitParameterUnit_LinearGain;
            break;
        case kSKBPParamInputRMS:
            SKBPSetParameterName(info, "Input RMS", CFSTR("Input RMS"));
            info->unit = kAudioUnitParameterUnit_LinearGain;
            break;
        case kSKBPParamAverageRenderMs:
            SKBPSetParameterName(info, "Avg Render ms", CFSTR("Avg Render ms"));
            info->unit = kAudioUnitParameterUnit_Milliseconds;
            info->maxValue = 100.0f;
            break;
        case kSKBPParamMaxRenderMs:
            SKBPSetParameterName(info, "Max Render ms", CFSTR("Max Render ms"));
            info->unit = kAudioUnitParameterUnit_Milliseconds;
            info->maxValue = 100.0f;
            break;
        case kSKBPParamCPULoad:
            SKBPSetParameterName(info, "CPU Load", CFSTR("CPU Load"));
            info->unit = kAudioUnitParameterUnit_Percent;
            break;
        case kSKBPParamLastRenderAgeMs:
            SKBPSetParameterName(info, "Last Render Age ms", CFSTR("Last Render Age ms"));
            info->unit = kAudioUnitParameterUnit_Milliseconds;
            info->minValue = -1.0f;
            info->maxValue = 10000.0f;
            break;
        case kSKBPParamRenderCount:
            SKBPSetParameterName(info, "Render Count", CFSTR("Render Count"));
            info->maxValue = 1000000000.0f;
            break;
        case kSKBPParamLastFrames:
            SKBPSetParameterName(info, "Last Frames", CFSTR("Last Frames"));
            info->unit = kAudioUnitParameterUnit_SampleFrames;
            info->maxValue = 65536.0f;
            break;
        case kSKBPParamResetStats:
            SKBPSetParameterName(info, "Reset Stats", CFSTR("Reset Stats"));
            info->unit = kAudioUnitParameterUnit_Boolean;
            info->flags = kAudioUnitParameterFlag_IsReadable | kAudioUnitParameterFlag_IsWritable |
                          kAudioUnitParameterFlag_HasCFNameString;
            break;
        default:
            return kAudioUnitErr_InvalidParameter;
    }
    return noErr;
}

static OSStatus SKBPGetProperty(void *self, AudioUnitPropertyID inID, AudioUnitScope inScope,
                                AudioUnitElement inElement, void *outData, UInt32 *ioDataSize)
{
    SKBPState *state = SKBPStateFromSelf(self);
    if (!state || !outData || !ioDataSize) {
        return kAudioUnitErr_InvalidPropertyValue;
    }
    if (!SKBPPropertyScopeIsValid(inID, inScope)) {
        return kAudioUnitErr_InvalidProperty;
    }

    UInt32 expectedSize = SKBPPropertySize(inID);
    if (expectedSize == 0 || *ioDataSize < expectedSize) {
        return kAudioUnitErr_InvalidProperty;
    }

    switch (inID) {
        case kAudioUnitProperty_ClassInfo: {
            CFMutableDictionaryRef info = CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
                                                                    &kCFTypeDictionaryKeyCallBacks,
                                                                    &kCFTypeDictionaryValueCallBacks);
            if (info) {
                SKBPPutUInt32(info, CFSTR(kAUPresetVersionKey), 1);
                SKBPPutUInt32(info, CFSTR(kAUPresetTypeKey), kAudioUnitType_Effect);
                SKBPPutUInt32(info, CFSTR(kAUPresetSubtypeKey), SKBP_AU_SUBTYPE);
                SKBPPutUInt32(info, CFSTR(kAUPresetManufacturerKey), SKBP_AU_MANUFACTURER);
                SKBPPutUInt32(info, CFSTR(kAUPresetNumberKey), 0);
                CFStringRef pluginName = CFStringCreateWithCString(NULL, SKBP_PLUGIN_NAME, kCFStringEncodingUTF8);
                if (pluginName) {
                    CFDictionarySetValue(info, CFSTR(kAUPresetNameKey), pluginName);
                    CFRelease(pluginName);
                }
                CFDictionarySetValue(info, CFSTR(kAUPresetDataKey), CFSTR("audio-bus-diagnostics"));
            }
            *(CFPropertyListRef *)outData = info;
            *ioDataSize = sizeof(CFPropertyListRef);
            return noErr;
        }
        case kAudioUnitProperty_SampleRate: {
            *(Float64 *)outData = atomic_load(&state->sampleRate);
            *ioDataSize = sizeof(Float64);
            return noErr;
        }
        case kAudioUnitProperty_ParameterList: {
            AudioUnitParameterID *ids = (AudioUnitParameterID *)outData;
            for (AudioUnitParameterID id = 0; id < SKBP_PARAM_COUNT; id++) {
                ids[id] = id;
            }
            *ioDataSize = sizeof(AudioUnitParameterID) * SKBP_PARAM_COUNT;
            return noErr;
        }
        case kAudioUnitProperty_ParameterInfo:
            *ioDataSize = sizeof(AudioUnitParameterInfo);
            return SKBPFillParameterInfo(inElement, (AudioUnitParameterInfo *)outData);
        case kAudioUnitProperty_FastDispatch:
            *(void **)outData = (void *)SKBPLookup((SInt16)inElement);
            *ioDataSize = sizeof(void *);
            return noErr;
        case kAudioUnitProperty_CPULoad: {
            *(Float64 *)outData = SKBPParameterValue(state, kSKBPParamCPULoad);
            *ioDataSize = sizeof(Float64);
            return noErr;
        }
        case kAudioUnitProperty_StreamFormat:
            *(AudioStreamBasicDescription *)outData =
                inScope == kAudioUnitScope_Input ? state->inputFormat : state->outputFormat;
            *ioDataSize = sizeof(AudioStreamBasicDescription);
            return noErr;
        case kAudioUnitProperty_ElementCount:
            *(UInt32 *)outData = 1;
            *ioDataSize = sizeof(UInt32);
            return noErr;
        case kAudioUnitProperty_Latency:
        case kAudioUnitProperty_TailTime:
            *(Float64 *)outData = 0.0;
            *ioDataSize = sizeof(Float64);
            return noErr;
        case kAudioUnitProperty_SupportedNumChannels: {
            AUChannelInfo *channels = (AUChannelInfo *)outData;
            channels[0] = (AUChannelInfo){1, 1};
            channels[1] = (AUChannelInfo){2, 2};
            *ioDataSize = sizeof(AUChannelInfo) * 2;
            return noErr;
        }
        case kAudioUnitProperty_MaximumFramesPerSlice:
            *(UInt32 *)outData = state->maxFramesPerSlice;
            *ioDataSize = sizeof(UInt32);
            return noErr;
        case kAudioUnitProperty_RenderQuality:
            *(UInt32 *)outData = state->renderQuality;
            *ioDataSize = sizeof(UInt32);
            return noErr;
        case kAudioUnitProperty_BypassEffect:
            *(UInt32 *)outData = state->bypass ? 1 : 0;
            *ioDataSize = sizeof(UInt32);
            return noErr;
        case kAudioUnitProperty_LastRenderError:
            *(UInt32 *)outData = (UInt32)atomic_load(&state->lastError);
            *ioDataSize = sizeof(UInt32);
            return noErr;
        case kAudioUnitProperty_PresentPreset: {
            AUPreset *preset = (AUPreset *)outData;
            preset->presetNumber = 0;
            preset->presetName = CFRetain(CFSTR("Default"));
            *ioDataSize = sizeof(AUPreset);
            return noErr;
        }
        default:
            return kAudioUnitErr_InvalidProperty;
    }
}

static OSStatus SKBPSetProperty(void *self, AudioUnitPropertyID inID, AudioUnitScope inScope,
                                AudioUnitElement inElement, const void *inData, UInt32 inDataSize)
{
    SKBPState *state = SKBPStateFromSelf(self);
    if (!state || !inData) {
        return kAudioUnitErr_InvalidPropertyValue;
    }
    if (!SKBPPropertyScopeIsValid(inID, inScope)) {
        return kAudioUnitErr_InvalidProperty;
    }

    switch (inID) {
        case kAudioUnitProperty_MakeConnection:
            if (inDataSize < sizeof(AudioUnitConnection)) {
                return kAudioUnitErr_InvalidPropertyValue;
            }
            state->connection = *(const AudioUnitConnection *)inData;
            state->hasConnection = state->connection.sourceAudioUnit != NULL;
            return noErr;
        case kAudioUnitProperty_SampleRate:
            if (inDataSize < sizeof(Float64) || *(const Float64 *)inData <= 0.0) {
                return kAudioUnitErr_InvalidPropertyValue;
            }
            state->inputFormat.mSampleRate = *(const Float64 *)inData;
            state->outputFormat.mSampleRate = *(const Float64 *)inData;
            atomic_store(&state->sampleRate, *(const Float64 *)inData);
            return noErr;
        case kAudioUnitProperty_StreamFormat:
            if (inDataSize < sizeof(AudioStreamBasicDescription)) {
                return kAudioUnitErr_InvalidPropertyValue;
            }
            if (!SKBPFormatIsUsable((const AudioStreamBasicDescription *)inData)) {
                return kAudioUnitErr_FormatNotSupported;
            }
            UInt32 newChannels = ((const AudioStreamBasicDescription *)inData)->mChannelsPerFrame;
            if (newChannels != 1 && newChannels != 2) {
                return kAudioUnitErr_FormatNotSupported;
            }
            if (inScope == kAudioUnitScope_Input) {
                state->inputFormat = *(const AudioStreamBasicDescription *)inData;
            } else if (inScope == kAudioUnitScope_Output) {
                state->outputFormat = *(const AudioStreamBasicDescription *)inData;
                if (state->outputFormat.mSampleRate > 0.0) {
                    atomic_store(&state->sampleRate, state->outputFormat.mSampleRate);
                }
            } else {
                state->inputFormat = *(const AudioStreamBasicDescription *)inData;
                state->outputFormat = *(const AudioStreamBasicDescription *)inData;
                if (state->outputFormat.mSampleRate > 0.0) {
                    atomic_store(&state->sampleRate, state->outputFormat.mSampleRate);
                }
            }
            return noErr;
        case kAudioUnitProperty_MaximumFramesPerSlice:
            if (inDataSize < sizeof(UInt32)) {
                return kAudioUnitErr_InvalidPropertyValue;
            }
            state->maxFramesPerSlice = *(const UInt32 *)inData;
            SKBPNotifyPropertyChanged(state, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0);
            return noErr;
        case kAudioUnitProperty_RenderQuality:
            if (inDataSize < sizeof(UInt32)) {
                return kAudioUnitErr_InvalidPropertyValue;
            }
            state->renderQuality = *(const UInt32 *)inData;
            return noErr;
        case kAudioUnitProperty_BypassEffect:
            if (inDataSize < sizeof(UInt32)) {
                return kAudioUnitErr_InvalidPropertyValue;
            }
            state->bypass = (*(const UInt32 *)inData) != 0;
            return noErr;
        case kAudioUnitProperty_SetRenderCallback:
            if (inElement != 0 || inDataSize < sizeof(AURenderCallbackStruct)) {
                return kAudioUnitErr_InvalidPropertyValue;
            }
            state->inputCallback = *(const AURenderCallbackStruct *)inData;
            state->hasInputCallback = state->inputCallback.inputProc != NULL;
            return noErr;
        case kAudioUnitProperty_PresentPreset:
            if (inDataSize < sizeof(AUPreset)) {
                return kAudioUnitErr_InvalidPropertyValue;
            }
            return noErr;
        default:
            return kAudioUnitErr_InvalidProperty;
    }
}

static OSStatus SKBPGetParameter(void *self, AudioUnitParameterID inID, AudioUnitScope inScope,
                                 AudioUnitElement inElement, AudioUnitParameterValue *outValue)
{
    (void)inScope;
    (void)inElement;
    SKBPState *state = SKBPStateFromSelf(self);
    if (!state || !outValue || inID >= SKBP_PARAM_COUNT) {
        return kAudioUnitErr_InvalidParameter;
    }
    *outValue = (AudioUnitParameterValue)SKBPParameterValue(state, inID);
    return noErr;
}

static OSStatus SKBPSetParameter(void *self, AudioUnitParameterID inID, AudioUnitScope inScope,
                                 AudioUnitElement inElement, AudioUnitParameterValue inValue,
                                 UInt32 inBufferOffsetInFrames)
{
    (void)inScope;
    (void)inElement;
    (void)inBufferOffsetInFrames;
    SKBPState *state = SKBPStateFromSelf(self);
    if (!state || inID >= SKBP_PARAM_COUNT) {
        return kAudioUnitErr_InvalidParameter;
    }
    if (inID == kSKBPParamResetStats && inValue > 0.5f) {
        SKBPResetStats(state);
        return noErr;
    }
    return inID == kSKBPParamResetStats ? noErr : kAudioUnitErr_InvalidParameter;
}

static OSStatus SKBPAddPropertyListener(void *self, AudioUnitPropertyID prop,
                                        AudioUnitPropertyListenerProc proc, void *userData)
{
    SKBPState *state = SKBPStateFromSelf(self);
    if (!state || !proc) {
        return kAudioUnitErr_InvalidPropertyValue;
    }
    if (state->propertyListenerCount >= SKBP_MAX_PROPERTY_LISTENERS) {
        return kAudioUnitErr_InvalidPropertyValue;
    }
    state->propertyListeners[state->propertyListenerCount++] = (SKBPPropertyListener){
        .propertyID = prop,
        .proc = proc,
        .userData = userData,
    };
    return noErr;
}

static OSStatus SKBPRemovePropertyListener(void *self, AudioUnitPropertyID prop,
                                           AudioUnitPropertyListenerProc proc)
{
    return SKBPRemovePropertyListenerWithUserData(self, prop, proc, NULL);
}

static OSStatus SKBPRemovePropertyListenerWithUserData(void *self, AudioUnitPropertyID prop,
                                                       AudioUnitPropertyListenerProc proc,
                                                       void *userData)
{
    SKBPState *state = SKBPStateFromSelf(self);
    if (!state) {
        return noErr;
    }
    for (UInt32 index = 0; index < state->propertyListenerCount; index++) {
        SKBPPropertyListener listener = state->propertyListeners[index];
        bool userDataMatches = userData == NULL || listener.userData == userData;
        if (listener.propertyID == prop && listener.proc == proc && userDataMatches) {
            for (UInt32 move = index + 1; move < state->propertyListenerCount; move++) {
                state->propertyListeners[move - 1] = state->propertyListeners[move];
            }
            state->propertyListenerCount--;
            break;
        }
    }
    return noErr;
}

static OSStatus SKBPReset(void *self, AudioUnitScope inScope, AudioUnitElement inElement)
{
    (void)inScope;
    (void)inElement;
    SKBPState *state = SKBPStateFromSelf(self);
    if (state) {
        SKBPResetStats(state);
    }
    return noErr;
}

static OSStatus SKBPAddRenderNotify(void *self, AURenderCallback proc, void *userData)
{
    (void)self;
    (void)proc;
    (void)userData;
    return noErr;
}

static OSStatus SKBPRemoveRenderNotify(void *self, AURenderCallback proc, void *userData)
{
    (void)self;
    (void)proc;
    (void)userData;
    return noErr;
}

static OSStatus SKBPRender(void *self, AudioUnitRenderActionFlags *ioActionFlags,
                           const AudioTimeStamp *inTimeStamp, UInt32 inOutputBusNumber,
                           UInt32 inNumberFrames, AudioBufferList *ioData)
{
    SKBPState *state = SKBPStateFromSelf(self);
    if (!state) {
        return kAudioUnitErr_Uninitialized;
    }

    uint64_t start = SKBPNowNanos();
    OSStatus status = noErr;

    if (state->hasInputCallback) {
        status = SKBPEnsureWritableBuffers(state, ioData, inNumberFrames);
        if (status != noErr) {
            atomic_store(&state->lastError, status);
            SKBPRecordRender(state, inNumberFrames, SKBPNowNanos() - start);
            return status;
        }
        status = state->inputCallback.inputProc(state->inputCallback.inputProcRefCon,
                                                ioActionFlags,
                                                inTimeStamp,
                                                0,
                                                inNumberFrames,
                                                ioData);
    } else if (state->hasConnection) {
        status = SKBPEnsureWritableBuffers(state, ioData, inNumberFrames);
        if (status != noErr) {
            atomic_store(&state->lastError, status);
            SKBPRecordRender(state, inNumberFrames, SKBPNowNanos() - start);
            return status;
        }
        status = AudioUnitRender(state->connection.sourceAudioUnit,
                                 ioActionFlags,
                                 inTimeStamp,
                                 state->connection.sourceOutputNumber,
                                 inNumberFrames,
                                 ioData);
    }

    if (status != noErr) {
        atomic_store(&state->lastError, status);
        SKBPRecordRender(state, inNumberFrames, SKBPNowNanos() - start);
        return status;
    }

    SKBPAnalyzeAudio(state, ioData, inNumberFrames);
    SKBPRecordRender(state, inNumberFrames, SKBPNowNanos() - start);
    atomic_store(&state->lastError, noErr);
    (void)inOutputBusNumber;
    return noErr;
}

static OSStatus SKBPProcess(void *self, AudioUnitRenderActionFlags *ioActionFlags,
                            const AudioTimeStamp *inTimeStamp, UInt32 inNumberFrames,
                            AudioBufferList *ioData)
{
    (void)ioActionFlags;
    (void)inTimeStamp;
    SKBPState *state = SKBPStateFromSelf(self);
    if (!state) {
        return kAudioUnitErr_Uninitialized;
    }
    uint64_t start = SKBPNowNanos();
    SKBPAnalyzeAudio(state, ioData, inNumberFrames);
    SKBPRecordRender(state, inNumberFrames, SKBPNowNanos() - start);
    atomic_store(&state->lastError, noErr);
    return noErr;
}

static void SKBPCopyAudioBufferList(AudioBufferList *output, const AudioBufferList *input)
{
    if (!output) {
        return;
    }
    if (!input) {
        SKBPZeroAudio(output);
        return;
    }
    UInt32 count = output->mNumberBuffers < input->mNumberBuffers ? output->mNumberBuffers : input->mNumberBuffers;
    for (UInt32 index = 0; index < count; index++) {
        AudioBuffer *outBuffer = &output->mBuffers[index];
        const AudioBuffer *inBuffer = &input->mBuffers[index];
        UInt32 bytesToCopy = outBuffer->mDataByteSize < inBuffer->mDataByteSize ?
                             outBuffer->mDataByteSize : inBuffer->mDataByteSize;
        if (outBuffer->mData && inBuffer->mData && bytesToCopy > 0) {
            memcpy(outBuffer->mData, inBuffer->mData, bytesToCopy);
            if (outBuffer->mDataByteSize > bytesToCopy) {
                memset((uint8_t *)outBuffer->mData + bytesToCopy, 0, outBuffer->mDataByteSize - bytesToCopy);
            }
        }
    }
    for (UInt32 index = count; index < output->mNumberBuffers; index++) {
        AudioBuffer *outBuffer = &output->mBuffers[index];
        if (outBuffer->mData && outBuffer->mDataByteSize > 0) {
            memset(outBuffer->mData, 0, outBuffer->mDataByteSize);
        }
    }
}

static OSStatus SKBPProcessMultiple(void *self, AudioUnitRenderActionFlags *ioActionFlags,
                                    const AudioTimeStamp *inTimeStamp, UInt32 inNumberFrames,
                                    UInt32 inNumberInputBufferLists,
                                    const AudioBufferList *const *inInputBufferLists,
                                    UInt32 inNumberOutputBufferLists,
                                    AudioBufferList *const *ioOutputBufferLists)
{
    (void)ioActionFlags;
    (void)inTimeStamp;
    SKBPState *state = SKBPStateFromSelf(self);
    if (!state) {
        return kAudioUnitErr_Uninitialized;
    }

    uint64_t start = SKBPNowNanos();
    const AudioBufferList *input = inNumberInputBufferLists > 0 ? inInputBufferLists[0] : NULL;
    AudioBufferList *firstOutput = NULL;
    for (UInt32 index = 0; index < inNumberOutputBufferLists; index++) {
        AudioBufferList *output = ioOutputBufferLists[index];
        if (!firstOutput) {
            firstOutput = output;
        }
        SKBPCopyAudioBufferList(output, input);
    }
    SKBPAnalyzeAudio(state, firstOutput, inNumberFrames);
    SKBPRecordRender(state, inNumberFrames, SKBPNowNanos() - start);
    atomic_store(&state->lastError, noErr);
    return noErr;
}

static AudioComponentMethod SKBPLookup(SInt16 selector)
{
    switch (selector) {
        case kAudioUnitInitializeSelect:
            return (AudioComponentMethod)SKBPInitialize;
        case kAudioUnitUninitializeSelect:
            return (AudioComponentMethod)SKBPUninitialize;
        case kAudioUnitGetPropertyInfoSelect:
            return (AudioComponentMethod)SKBPGetPropertyInfo;
        case kAudioUnitGetPropertySelect:
            return (AudioComponentMethod)SKBPGetProperty;
        case kAudioUnitSetPropertySelect:
            return (AudioComponentMethod)SKBPSetProperty;
        case kAudioUnitAddPropertyListenerSelect:
            return (AudioComponentMethod)SKBPAddPropertyListener;
        case kAudioUnitRemovePropertyListenerSelect:
            return (AudioComponentMethod)SKBPRemovePropertyListener;
        case kAudioUnitRemovePropertyListenerWithUserDataSelect:
            return (AudioComponentMethod)SKBPRemovePropertyListenerWithUserData;
        case kAudioUnitAddRenderNotifySelect:
            return (AudioComponentMethod)SKBPAddRenderNotify;
        case kAudioUnitRemoveRenderNotifySelect:
            return (AudioComponentMethod)SKBPRemoveRenderNotify;
        case kAudioUnitGetParameterSelect:
            return (AudioComponentMethod)SKBPGetParameter;
        case kAudioUnitSetParameterSelect:
            return (AudioComponentMethod)SKBPSetParameter;
        case kAudioUnitRenderSelect:
            return (AudioComponentMethod)SKBPRender;
        case kAudioUnitResetSelect:
            return (AudioComponentMethod)SKBPReset;
        case kAudioUnitProcessSelect:
            return (AudioComponentMethod)SKBPProcess;
        case kAudioUnitProcessMultipleSelect:
            return (AudioComponentMethod)SKBPProcessMultiple;
        default:
            return NULL;
    }
}

__attribute__((visibility("default")))
AudioComponentPlugInInterface *SpliceKitAudioBusProbeFactory(const AudioComponentDescription *inDesc)
{
    (void)inDesc;
    SKBPPlugin *plugin = (SKBPPlugin *)calloc(1, sizeof(SKBPPlugin));
    if (!plugin) {
        return NULL;
    }
    plugin->interface.Open = SKBPOpen;
    plugin->interface.Close = SKBPClose;
    plugin->interface.Lookup = SKBPLookup;
    plugin->interface.reserved = NULL;
    return &plugin->interface;
}
