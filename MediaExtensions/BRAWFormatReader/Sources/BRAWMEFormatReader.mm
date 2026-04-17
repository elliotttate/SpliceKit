#import <AVFoundation/AVFoundation.h>
#import <CoreGraphics/CGAffineTransform.h>
#import <CoreMedia/CMBlockBuffer.h>
#import <CoreMedia/CMFormatDescription.h>
#import <CoreMedia/CMSampleBuffer.h>
#import <CoreMedia/CMTime.h>
#import <Foundation/Foundation.h>
#import <MediaExtension/MEError.h>
#import <MediaExtension/MEFormatReader.h>

#include "../../../Plugins/BRAW/Sources/BRAWCommon.h"

using namespace SpliceKitBRAW;

static NSError *BRAWMECreateError(MEError code, NSString *description)
{
    NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
    if (description.length) {
        userInfo[NSLocalizedDescriptionKey] = description;
    }
    return [NSError errorWithDomain:MediaExtensionErrorDomain code:code userInfo:userInfo];
}

static NSString *BRAWMESidecarFileNameForClipPath(NSString *clipPath)
{
    if (!clipPath.length) {
        return nil;
    }
    NSString *candidate = [[[clipPath stringByDeletingPathExtension] stringByAppendingPathExtension:@"sidecar"] lastPathComponent];
    return candidate.length ? candidate : nil;
}

@class BRAWMETrackReader;

@interface BRAWMESampleCursor : NSObject <MESampleCursor, NSCopying>

- (instancetype)initWithTrack:(BRAWMETrackReader *)track frameIndex:(uint64_t)frameIndex NS_DESIGNATED_INITIALIZER;

@property (nonatomic, readonly) BRAWMETrackReader *track;
@property (nonatomic, readonly) uint64_t frameIndex;

@end

@interface BRAWMETrackReader : NSObject <METrackReader>

- (instancetype)initWithPath:(NSString *)path
                   byteSource:(MEByteSource *)byteSource
                     clipInfo:(const ClipInfo &)clipInfo
            formatDescription:(CMVideoFormatDescriptionRef)formatDescription NS_DESIGNATED_INITIALIZER;

@property (nonatomic, readonly) NSString *path;
@property (nonatomic, readonly) MEByteSource *byteSource;
@property (nonatomic, readonly) ClipInfo clipInfo;
@property (nonatomic, readonly) CMVideoFormatDescriptionRef formatDescription;
@property (nonatomic, readonly) CMPersistentTrackID trackID;

@end

@interface BRAWMEFormatReader : NSObject <MEFormatReader>

- (instancetype)initWithByteSource:(MEByteSource *)byteSource error:(NSError **)error NS_DESIGNATED_INITIALIZER;

@property (nonatomic, readonly) MEByteSource *byteSource;
@property (nonatomic, readonly) NSString *path;
@property (nonatomic, readonly) ClipInfo clipInfo;
@property (nonatomic, readonly) CMVideoFormatDescriptionRef formatDescription;

@end

@interface BRAWMEFormatReaderFactory : NSObject <MEFormatReaderExtension>
@end

@implementation BRAWMEFormatReaderFactory

- (id<MEFormatReader>)formatReaderWithByteSource:(MEByteSource *)primaryByteSource
                                         options:(MEFormatReaderInstantiationOptions *)options
                                           error:(NSError *__autoreleasing  _Nullable * _Nullable)error
{
    #pragma unused(options)
    return [[BRAWMEFormatReader alloc] initWithByteSource:primaryByteSource error:error];
}

@end

@implementation BRAWMEFormatReader {
    ClipInfo _clipInfo;
    CMVideoFormatDescriptionRef _formatDescription;
    NSString *_path;
}

- (instancetype)initWithByteSource:(MEByteSource *)byteSource error:(NSError **)error
{
    self = [super init];
    if (!self) {
        return nil;
    }

    _byteSource = byteSource;
    CFStringRef standardized = CopyStandardizedPath((__bridge CFStringRef)byteSource.fileName);
    _path = standardized ? CFBridgingRelease(standardized) : [byteSource.fileName stringByStandardizingPath];
    if (!_path.length) {
        if (error) {
            *error = BRAWMECreateError(MEErrorParsingFailure, @"The BRAW byte source did not provide a usable file path.");
        }
        return nil;
    }

    std::string readError;
#if SPLICEKIT_BRAW_SDK_AVAILABLE
    if (!ReadClipInfo((__bridge CFStringRef)_path, _clipInfo, readError)) {
        if (error) {
            *error = BRAWMECreateError(MEErrorParsingFailure,
                                       [NSString stringWithFormat:@"ReadClipInfo failed for %@: %s", _path, readError.c_str()]);
        }
        return nil;
    }
#else
    if (error) {
        *error = BRAWMECreateError(MEErrorParsingFailure, @"Blackmagic RAW SDK headers are unavailable on this machine.");
    }
    return nil;
#endif

    _formatDescription = CreateVideoFormatDescription(kCFAllocatorDefault, (__bridge CFStringRef)_path, _clipInfo);
    if (!_formatDescription) {
        if (error) {
            *error = BRAWMECreateError(MEErrorParsingFailure,
                                       [NSString stringWithFormat:@"Failed to create a video format description for %@", _path]);
        }
        return nil;
    }

    Log(@"me-reader", @"prepared %@ (%ux%u %.3f fps %llu frames)",
        _path, _clipInfo.width, _clipInfo.height, _clipInfo.frameRate, _clipInfo.frameCount);
    return self;
}

- (void)dealloc
{
    if (_formatDescription) {
        CFRelease(_formatDescription);
        _formatDescription = nil;
    }
}

- (MEByteSource *)byteSource
{
    return _byteSource;
}

- (NSString *)path
{
    return _path;
}

- (ClipInfo)clipInfo
{
    return _clipInfo;
}

- (CMVideoFormatDescriptionRef)formatDescription
{
    return _formatDescription;
}

- (void)loadFileInfoWithCompletionHandler:(void (^)(MEFileInfo * _Nullable, NSError * _Nullable))completionHandler
{
    MEFileInfo *fileInfo = [[MEFileInfo alloc] init];
    fileInfo.duration = _clipInfo.duration;
    fileInfo.fragmentsStatus = MEFileInfoCouldNotContainFragments;
    if (@available(macOS 26.0, *)) {
        fileInfo.sidecarFileName = BRAWMESidecarFileNameForClipPath(_path);
    }
    completionHandler(fileInfo, nil);
}

- (void)loadMetadataWithCompletionHandler:(void (^)(NSArray<AVMetadataItem *> * _Nullable, NSError * _Nullable))completionHandler
{
    completionHandler(@[], nil);
}

- (void)loadTrackReadersWithCompletionHandler:(void (^)(NSArray<id<METrackReader>> * _Nullable, NSError * _Nullable))completionHandler
{
    BRAWMETrackReader *reader = [[BRAWMETrackReader alloc] initWithPath:_path
                                                              byteSource:_byteSource
                                                                clipInfo:_clipInfo
                                                       formatDescription:_formatDescription];
    completionHandler(reader ? @[ reader ] : @[], reader ? nil : BRAWMECreateError(MEErrorInternalFailure, @"Failed to create BRAW track reader."));
}

@end

@implementation BRAWMETrackReader {
    NSString *_path;
    MEByteSource *_byteSource;
    ClipInfo _clipInfo;
    CMVideoFormatDescriptionRef _formatDescription;
}

- (instancetype)initWithPath:(NSString *)path
                   byteSource:(MEByteSource *)byteSource
                     clipInfo:(const ClipInfo &)clipInfo
            formatDescription:(CMVideoFormatDescriptionRef)formatDescription
{
    self = [super init];
    if (!self) {
        return nil;
    }

    _path = [path copy];
    _byteSource = byteSource;
    _clipInfo = clipInfo;
    _trackID = 1;
    _formatDescription = formatDescription ? (CMVideoFormatDescriptionRef)CFRetain(formatDescription) : nil;
    return self;
}

- (void)dealloc
{
    if (_formatDescription) {
        CFRelease(_formatDescription);
        _formatDescription = nil;
    }
}

- (NSString *)path
{
    return _path;
}

- (MEByteSource *)byteSource
{
    return _byteSource;
}

- (ClipInfo)clipInfo
{
    return _clipInfo;
}

- (CMVideoFormatDescriptionRef)formatDescription
{
    return _formatDescription;
}

- (CMPersistentTrackID)trackID
{
    return _trackID;
}

- (void)loadTrackInfoWithCompletionHandler:(void (^)(METrackInfo * _Nullable, NSError * _Nullable))completionHandler
{
    if (!_formatDescription) {
        completionHandler(nil, BRAWMECreateError(MEErrorParsingFailure, @"BRAW track format description is missing."));
        return;
    }

    METrackInfo *trackInfo = [[METrackInfo alloc] initWithMediaType:kCMMediaType_Video
                                                            trackID:_trackID
                                                 formatDescriptions:@[ (__bridge id)_formatDescription ]];
    trackInfo.enabled = YES;
    trackInfo.naturalTimescale = _clipInfo.frameDuration.timescale > 0 ? _clipInfo.frameDuration.timescale : 600000;
    trackInfo.naturalSize = CGSizeMake(_clipInfo.width, _clipInfo.height);
    trackInfo.preferredTransform = CGAffineTransformIdentity;
    trackInfo.nominalFrameRate = _clipInfo.frameRate;
    trackInfo.requiresFrameReordering = NO;
    completionHandler(trackInfo, nil);
}

- (void)generateSampleCursorAtPresentationTimeStamp:(CMTime)presentationTimeStamp
                                  completionHandler:(void (^)(id<MESampleCursor> _Nullable, NSError * _Nullable))completionHandler
{
    uint64_t frameIndex = FrameIndexForTime(presentationTimeStamp, _clipInfo);
    completionHandler([[BRAWMESampleCursor alloc] initWithTrack:self frameIndex:frameIndex], nil);
}

- (void)generateSampleCursorAtFirstSampleInDecodeOrderWithCompletionHandler:(void (^)(id<MESampleCursor> _Nullable, NSError * _Nullable))completionHandler
{
    completionHandler([[BRAWMESampleCursor alloc] initWithTrack:self frameIndex:0], nil);
}

- (void)generateSampleCursorAtLastSampleInDecodeOrderWithCompletionHandler:(void (^)(id<MESampleCursor> _Nullable, NSError * _Nullable))completionHandler
{
    uint64_t lastFrame = _clipInfo.frameCount > 0 ? _clipInfo.frameCount - 1 : 0;
    completionHandler([[BRAWMESampleCursor alloc] initWithTrack:self frameIndex:lastFrame], nil);
}

- (void)loadUneditedDurationWithCompletionHandler:(void (^)(CMTime, NSError * _Nullable))completionHandler
{
    completionHandler(_clipInfo.duration, nil);
}

- (void)loadTotalSampleDataLengthWithCompletionHandler:(void (^)(int64_t, NSError * _Nullable))completionHandler
{
    completionHandler((int64_t)_clipInfo.frameCount * (int64_t)sizeof(uint32_t), nil);
}

- (void)loadEstimatedDataRateWithCompletionHandler:(void (^)(Float32, NSError * _Nullable))completionHandler
{
    Float32 bytesPerSecond = (Float32)(_clipInfo.frameRate > 0.0 ? _clipInfo.frameRate : 24.0) * sizeof(uint32_t);
    completionHandler(bytesPerSecond, nil);
}

- (void)loadMetadataWithCompletionHandler:(void (^)(NSArray<AVMetadataItem *> * _Nullable, NSError * _Nullable))completionHandler
{
    completionHandler(@[], nil);
}

@end

@implementation BRAWMESampleCursor {
    __weak BRAWMETrackReader *_track;
    uint64_t _frameIndex;
}

- (instancetype)initWithTrack:(BRAWMETrackReader *)track frameIndex:(uint64_t)frameIndex
{
    self = [super init];
    if (!self) {
        return nil;
    }
    _track = track;
    if (track.clipInfo.frameCount == 0) {
        _frameIndex = 0;
    } else {
        _frameIndex = std::min<uint64_t>(frameIndex, track.clipInfo.frameCount - 1);
    }
    return self;
}

- (id)copyWithZone:(NSZone *)zone
{
    #pragma unused(zone)
    return [[BRAWMESampleCursor alloc] initWithTrack:_track frameIndex:_frameIndex];
}

- (BRAWMETrackReader *)track
{
    return _track;
}

- (uint64_t)frameIndex
{
    return _frameIndex;
}

- (CMTime)presentationTimeStamp
{
    if (!_track) {
        return kCMTimeInvalid;
    }
    return CMTimeMultiply(_track.clipInfo.frameDuration, (int32_t)_frameIndex);
}

- (CMTime)decodeTimeStamp
{
    return self.presentationTimeStamp;
}

- (CMTime)currentSampleDuration
{
    return _track ? _track.clipInfo.frameDuration : kCMTimeInvalid;
}

- (CMFormatDescriptionRef)currentSampleFormatDescription
{
    return _track.formatDescription;
}

- (void)stepInDecodeOrderByCount:(int64_t)stepCount completionHandler:(void (^)(int64_t, NSError * _Nullable))completionHandler
{
    if (!_track || _track.clipInfo.frameCount == 0) {
        completionHandler(0, BRAWMECreateError(MEErrorNoSamples, @"The BRAW clip has no samples."));
        return;
    }
    int64_t current = (int64_t)_frameIndex;
    int64_t target = MAX((int64_t)0, MIN(current + stepCount, (int64_t)_track.clipInfo.frameCount - 1));
    _frameIndex = (uint64_t)target;
    completionHandler(target - current, nil);
}

- (void)stepInPresentationOrderByCount:(int64_t)stepCount completionHandler:(void (^)(int64_t, NSError * _Nullable))completionHandler
{
    [self stepInDecodeOrderByCount:stepCount completionHandler:completionHandler];
}

- (void)stepByDecodeTime:(CMTime)deltaDecodeTime completionHandler:(void (^)(CMTime, BOOL, NSError * _Nullable))completionHandler
{
    if (!_track || !CMTIME_IS_NUMERIC(_track.clipInfo.frameDuration)) {
        completionHandler(kCMTimeInvalid, YES, BRAWMECreateError(MEErrorNoSamples, @"The BRAW clip has no decodable samples."));
        return;
    }
    Float64 seconds = CMTimeGetSeconds(deltaDecodeTime);
    int64_t requestedSteps = (int64_t)llround(seconds * (_track.clipInfo.frameRate > 0.0 ? _track.clipInfo.frameRate : 24.0));
    int64_t current = (int64_t)_frameIndex;
    int64_t target = MAX((int64_t)0, MIN(current + requestedSteps, (int64_t)_track.clipInfo.frameCount - 1));
    _frameIndex = (uint64_t)target;
    completionHandler(self.decodeTimeStamp, target != current + requestedSteps, nil);
}

- (void)stepByPresentationTime:(CMTime)deltaPresentationTime completionHandler:(void (^)(CMTime, BOOL, NSError * _Nullable))completionHandler
{
    [self stepByDecodeTime:deltaPresentationTime completionHandler:completionHandler];
}

- (MESampleLocation *)sampleLocationReturningError:(NSError **)error
{
    if (error) {
        *error = BRAWMECreateError(MEErrorLocationNotAvailable, @"BRAW samples are synthesized by the extension and do not expose direct file locations.");
    }
    return nil;
}

- (MESampleCursorChunk *)chunkDetailsReturningError:(NSError **)error
{
    if (error) {
        *error = BRAWMECreateError(MEErrorLocationNotAvailable, @"BRAW samples are synthesized by the extension and do not expose chunk details.");
    }
    return nil;
}

- (void)loadSampleBufferContainingSamplesToEndCursor:(id<MESampleCursor>)endSampleCursor
                                   completionHandler:(void (^)(CMSampleBufferRef _Nullable, NSError * _Nullable))completionHandler
{
    if (endSampleCursor && [endSampleCursor isKindOfClass:[BRAWMESampleCursor class]]) {
        BRAWMESampleCursor *other = (BRAWMESampleCursor *)endSampleCursor;
        if (other.track != _track || other.frameIndex < _frameIndex) {
            completionHandler(nil, BRAWMECreateError(MEErrorNoSamples, @"The requested end cursor precedes the current BRAW sample cursor."));
            return;
        }
    }

    if (!_track || !_track.formatDescription) {
        completionHandler(nil, BRAWMECreateError(MEErrorParsingFailure, @"The BRAW sample cursor is missing its track format description."));
        return;
    }

    uint32_t frameIndex32 = (uint32_t)MIN<uint64_t>(_frameIndex, UINT32_MAX);
    CMBlockBufferRef blockBuffer = nil;
    OSStatus status = CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault,
                                                         NULL,
                                                         sizeof(frameIndex32),
                                                         kCFAllocatorDefault,
                                                         NULL,
                                                         0,
                                                         sizeof(frameIndex32),
                                                         0,
                                                         &blockBuffer);
    if (status != noErr || !blockBuffer) {
        completionHandler(nil, BRAWMECreateError(MEErrorInternalFailure,
                                                 [NSString stringWithFormat:@"CMBlockBufferCreateWithMemoryBlock failed %@", DescribeOSStatus(status)]));
        return;
    }

    status = CMBlockBufferReplaceDataBytes(&frameIndex32, blockBuffer, 0, sizeof(frameIndex32));
    if (status != noErr) {
        CFRelease(blockBuffer);
        completionHandler(nil, BRAWMECreateError(MEErrorInternalFailure,
                                                 [NSString stringWithFormat:@"CMBlockBufferReplaceDataBytes failed %@", DescribeOSStatus(status)]));
        return;
    }

    CMSampleTimingInfo timing = {
        .duration = _track.clipInfo.frameDuration,
        .presentationTimeStamp = self.presentationTimeStamp,
        .decodeTimeStamp = self.decodeTimeStamp,
    };
    size_t sampleSize = sizeof(frameIndex32);
    CMSampleBufferRef sampleBuffer = nil;
    status = CMSampleBufferCreateReady(kCFAllocatorDefault,
                                       blockBuffer,
                                       _track.formatDescription,
                                       1,
                                       1,
                                       &timing,
                                       1,
                                       &sampleSize,
                                       &sampleBuffer);
    CFRelease(blockBuffer);
    if (status != noErr || !sampleBuffer) {
        completionHandler(nil, BRAWMECreateError(MEErrorInternalFailure,
                                                 [NSString stringWithFormat:@"CMSampleBufferCreateReady failed %@", DescribeOSStatus(status)]));
        return;
    }

    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, YES);
    if (attachments && CFArrayGetCount(attachments) > 0) {
        CFMutableDictionaryRef attachment = (CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);
        if (attachment) {
            CFDictionarySetValue(attachment, kCMSampleAttachmentKey_NotSync, kCFBooleanFalse);
            CFDictionarySetValue(attachment, kCMSampleAttachmentKey_DoNotDisplay, kCFBooleanFalse);
        }
    }

    completionHandler(sampleBuffer, nil);
    CFRelease(sampleBuffer);
}

@end
