#ifndef SpliceKitBRAWExports_h
#define SpliceKitBRAWExports_h

#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <CoreVideo/CoreVideo.h>

#ifdef __cplusplus
extern "C" {
#endif

NSDictionary *SpliceKit_handleBRAWProbe(NSDictionary *params);
NSDictionary *SpliceKit_handleBRAWDescribeImmersive(NSDictionary *params);
NSDictionary *SpliceKit_handleBRAWReadMotionSamples(NSDictionary *params);
NSString *SpliceKitBRAWResolveOriginalPathForPublic(NSString *path);

BOOL SpliceKitBRAW_DecodeFrameBytesEye(CFStringRef pathRef,
                                       uint32_t frameIndex,
                                       uint32_t scaleHint,
                                       int eyeIndex,
                                       uint32_t formatHint,
                                       uint32_t *outWidth,
                                       uint32_t *outHeight,
                                       uint32_t *outSizeBytes,
                                       void **outBytes);

BOOL SpliceKitBRAW_DecodeFrameIntoPixelBufferEye(CFStringRef pathRef,
                                                 uint32_t frameIndex,
                                                 uint32_t scaleHint,
                                                 int eyeIndex,
                                                 CVPixelBufferRef destPixelBuffer,
                                                 uint32_t *outWidth,
                                                 uint32_t *outHeight);

BOOL SpliceKitBRAW_GetScaledDimensions(CFStringRef pathRef,
                                        uint32_t scaleHint,
                                        uint32_t *outWidth,
                                        uint32_t *outHeight);

BOOL SpliceKitBRAW_ReadClipMetadata(CFStringRef pathRef,
                                    uint32_t *outWidth,
                                    uint32_t *outHeight,
                                    float *outFrameRate,
                                    uint64_t *outFrameCount);

#ifdef __cplusplus
}
#endif

#endif /* SpliceKitBRAWExports_h */
