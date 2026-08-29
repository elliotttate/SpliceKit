#import <CoreImage/CoreImage.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <mach/mach.h>

static double ResidentMegabytes(void) {
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    kern_return_t status = task_info(mach_task_self(),
                                     TASK_VM_INFO,
                                     (task_info_t)&info,
                                     &count);
    if (status != KERN_SUCCESS) return 0.0;
    return (double)info.phys_footprint / (1024.0 * 1024.0);
}

static CIImage *FilteredMask(NSUInteger frame, CGRect extent, CIImage *previous) {
    CGFloat level = 0.25 + 0.5 * ((frame % 31) / 30.0);
    CIImage *current = [[CIImage imageWithColor:[CIColor colorWithRed:level
                                                              green:level
                                                               blue:level
                                                              alpha:1.0]]
                        imageByCroppingToRect:extent];
    current = [[current imageByApplyingFilter:@"CIMorphologyMaximum"
                           withInputParameters:@{kCIInputRadiusKey: @2.0}]
               imageByCroppingToRect:extent];

    if (previous) {
        CIFilter *blend = [CIFilter filterWithName:@"CIDissolveTransition"];
        [blend setValue:current forKey:kCIInputImageKey];
        [blend setValue:previous forKey:kCIInputTargetImageKey];
        [blend setValue:@0.45 forKey:kCIInputTimeKey];
        CIImage *blended = blend.outputImage;
        if (blended) current = [blended imageByCroppingToRect:extent];
    }

    return [[[current imageByApplyingFilter:@"CIGaussianBlur"
                         withInputParameters:@{kCIInputRadiusKey: @1.5}]
             imageByCroppingToRect:extent]
            imageByClampingToExtent];
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        const NSUInteger frameCount = 5000;
        const NSUInteger warmupFrames = 500;
        const NSUInteger sampleFrames = 500;
        const size_t width = 160;
        const size_t height = 90;
        CGRect extent = CGRectMake(0, 0, width, height);

        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        CIContext *context = device
            ? [CIContext contextWithMTLDevice:device options:@{kCIContextCacheIntermediates: @NO}]
            : [CIContext contextWithOptions:@{kCIContextCacheIntermediates: @NO}];
        if (!context) {
            fprintf(stderr, "could not create CIContext\n");
            return 2;
        }

        NSDictionary *poolAttributes = @{
            (id)kCVPixelBufferPoolMinimumBufferCountKey: @3,
        };
        NSDictionary *bufferAttributes = @{
            (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_OneComponent8),
            (id)kCVPixelBufferWidthKey: @(width),
            (id)kCVPixelBufferHeightKey: @(height),
            (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
            (id)kCVPixelBufferMetalCompatibilityKey: @YES,
        };
        CVPixelBufferPoolRef pool = NULL;
        CVReturn poolStatus = CVPixelBufferPoolCreate(kCFAllocatorDefault,
                                                       (__bridge CFDictionaryRef)poolAttributes,
                                                       (__bridge CFDictionaryRef)bufferAttributes,
                                                       &pool);
        if (poolStatus != kCVReturnSuccess || !pool) {
            fprintf(stderr, "could not create pixel buffer pool: %d\n", (int)poolStatus);
            return 3;
        }

        __strong CIImage *previous = nil;
        double warmRSS = 0.0;
        double earlySeconds = 0.0;
        double lateSeconds = 0.0;
        NSDictionary *allocationLimit = @{
            (id)kCVPixelBufferPoolAllocationThresholdKey: @8,
        };

        for (NSUInteger frame = 0; frame < frameCount; frame++) {
            @autoreleasepool {
                NSTimeInterval started = [NSDate timeIntervalSinceReferenceDate];
                CIImage *mask = FilteredMask(frame, extent, previous);

                CVPixelBufferRef buffer = NULL;
                CVReturn status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
                    kCFAllocatorDefault,
                    pool,
                    (__bridge CFDictionaryRef)allocationLimit,
                    &buffer);
                if (status != kCVReturnSuccess || !buffer) {
                    fprintf(stderr, "pool exhausted at frame %lu: %d\n",
                            (unsigned long)frame, (int)status);
                    CVPixelBufferPoolRelease(pool);
                    return 4;
                }

                [context render:mask
                 toCVPixelBuffer:buffer
                          bounds:extent
                      colorSpace:nil];
                CIImage *materialized = [CIImage imageWithCVPixelBuffer:buffer
                                                                options:@{kCIImageColorSpace: [NSNull null]}];
                CVPixelBufferRelease(buffer);
                if (!materialized) {
                    fprintf(stderr, "history materialization failed at frame %lu\n",
                            (unsigned long)frame);
                    CVPixelBufferPoolRelease(pool);
                    return 5;
                }
                previous = [materialized imageByCroppingToRect:extent];

                NSTimeInterval elapsed = [NSDate timeIntervalSinceReferenceDate] - started;
                if (frame >= warmupFrames && frame < warmupFrames + sampleFrames) {
                    earlySeconds += elapsed;
                }
                if (frame >= frameCount - sampleFrames) {
                    lateSeconds += elapsed;
                }
            }

            if (frame == warmupFrames) warmRSS = ResidentMegabytes();
        }

        double finalRSS = ResidentMegabytes();
        double rssGrowth = finalRSS - warmRSS;
        double earlyMs = earlySeconds * 1000.0 / sampleFrames;
        double lateMs = lateSeconds * 1000.0 / sampleFrames;
        double slowdown = earlyMs > 0.0 ? lateMs / earlyMs : 0.0;

        previous = nil;
        CVPixelBufferPoolFlush(pool, kCVPixelBufferPoolFlushExcessBuffers);
        CVPixelBufferPoolRelease(pool);

        printf("frames=%lu warm_rss=%.1fMB final_rss=%.1fMB growth=%.1fMB early=%.3fms late=%.3fms ratio=%.2f\n",
               (unsigned long)frameCount,
               warmRSS,
               finalRSS,
               rssGrowth,
               earlyMs,
               lateMs,
               slowdown);

        // The original implementation crashes around frame 423 and grows by
        // gigabytes. Allow generous headroom for GPU/framework caching while
        // still catching an accidentally retained frame graph or buffer pool.
        if (rssGrowth > 128.0) {
            fprintf(stderr, "resident memory grew too much: %.1fMB\n", rssGrowth);
            return 6;
        }
        if (slowdown > 2.5) {
            fprintf(stderr, "rendering slowed down over time: %.2fx\n", slowdown);
            return 7;
        }
    }
    return 0;
}
