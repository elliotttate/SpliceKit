#import "SpliceKitImmersivePreviewPanel.h"
#import "SpliceKitBRAWExports.h"
#import "SpliceKitVisionPro.h"
#import "SpliceKit.h"

#import <objc/message.h>
#import <objc/runtime.h>
#import <CoreGraphics/CoreGraphics.h>
#import <QuartzCore/QuartzCore.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>

#include <atomic>

#if defined(__x86_64__)
#define SKIP_STRET_MSG objc_msgSend_stret
#else
#define SKIP_STRET_MSG objc_msgSend
#endif

typedef struct { int64_t value; int32_t timescale; uint32_t flags; int64_t epoch; } SKIP_CMTime;
typedef struct { SKIP_CMTime start; SKIP_CMTime duration; } SKIP_CMTimeRange;

static inline double SKIPClamp(double value, double lower, double upper) {
    return value < lower ? lower : (value > upper ? upper : value);
}

static inline NSString *SKIPStringOrEmpty(id value) {
    return [value isKindOfClass:[NSString class]] ? value : @"";
}

static inline CFTimeInterval SKIPNow(void) {
    return CACurrentMediaTime();
}

static NSError *SKIPImmersivePreviewError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"SpliceKitImmersivePreview"
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message ?: @"Immersive preview failed"}];
}

static id SKIPActiveEditorContainerForPreview(void) {
    if (![NSThread isMainThread]) return nil;

    @try {
        id app = [NSApplication sharedApplication];
        id delegate = [app delegate];
        if (!delegate) return nil;

        SEL activeEditorContainerSel = @selector(activeEditorContainer);
        if ([delegate respondsToSelector:activeEditorContainerSel]) {
            id editorContainer = ((id (*)(id, SEL))objc_msgSend)(delegate, activeEditorContainerSel);
            if (editorContainer) return editorContainer;
        }

        SEL mainEditorContainerSel = NSSelectorFromString(@"mainEditorContainer");
        if ([delegate respondsToSelector:mainEditorContainerSel]) {
            return ((id (*)(id, SEL))objc_msgSend)(delegate, mainEditorContainerSel);
        }
    } @catch (NSException *exception) {
        SpliceKit_log(@"[ImmersivePreview] Active editor container lookup failed: %@",
                      exception.reason ?: exception.name);
    }

    return nil;
}

static id SKIPActivePlayerContainerModuleForPreview(void) {
    if (![NSThread isMainThread]) return nil;

    @try {
        id editorContainer = SKIPActiveEditorContainerForPreview();
        SEL targetModulesSel = NSSelectorFromString(@"targetModules");
        if (!editorContainer || ![editorContainer respondsToSelector:targetModulesSel]) {
            return nil;
        }

        id modules = ((id (*)(id, SEL))objc_msgSend)(editorContainer, targetModulesSel);
        if (![modules isKindOfClass:[NSArray class]]) return nil;

        for (id module in (NSArray *)modules) {
            NSString *className = NSStringFromClass([module class]);
            if ([className isEqualToString:@"PEPlayerContainerModule"]) {
                return module;
            }
            if ([module respondsToSelector:@selector(mode)] &&
                [module respondsToSelector:NSSelectorFromString(@"setMode:")] &&
                [module respondsToSelector:NSSelectorFromString(@"playerModules")]) {
                return module;
            }
        }
    } @catch (NSException *exception) {
        SpliceKit_log(@"[ImmersivePreview] Player container lookup failed: %@",
                      exception.reason ?: exception.name);
    }

    return nil;
}

static BOOL SKIPNativeFCP360ViewerIsVisible(void) {
    if (![NSThread isMainThread]) return NO;

    @try {
        id playerContainer = SKIPActivePlayerContainerModuleForPreview();
        if (!playerContainer || ![playerContainer respondsToSelector:@selector(mode)]) return NO;
        NSInteger mode = ((NSInteger (*)(id, SEL))objc_msgSend)(playerContainer, @selector(mode));
        return mode == 8;
    } @catch (__unused NSException *exception) {
        return NO;
    }
}

typedef id (*SKIPNewProjectedImageForPlayerFrameIMP)(id, SEL, id);
typedef int (*SKIPFFPlayerFrameCameraModeIMP)(id, SEL);

static SKIPNewProjectedImageForPlayerFrameIMP sSKIPOriginalNewProjectedImageForPlayerFrame = NULL;
static SKIPFFPlayerFrameCameraModeIMP sSKIPOriginalFFPlayerFrameCameraMode = NULL;
static std::atomic<bool> sSKIPNativeFCP360ProjectionPatchEnabled(false);
static std::atomic<uint64_t> sSKIPNativeFCP360ProjectionPatchCalls(0);
static std::atomic<uint64_t> sSKIPNativeFCP360CameraModeOverrides(0);
// FFSphericalMode value FCP's 360 viewer should see for BRAW immersive frames.
// 3 = FFSphericalMode_DualFisheye (Apple Immersive / URSA Immersive default).
static std::atomic<int> sSKIPNativeFCP360CameraModeOverrideValue(3);
static thread_local const void *sSKIPNativeFCP360ProjectionOverrideFrame = NULL;

static BOOL SKIPNativeFCP360ProjectionPatchIsInstalled(void) {
    return sSKIPOriginalNewProjectedImageForPlayerFrame != NULL &&
           sSKIPOriginalFFPlayerFrameCameraMode != NULL;
}

static void SKIPSetNativeFCP360ProjectionPatchEnabled(BOOL enabled) {
    sSKIPNativeFCP360ProjectionPatchEnabled.store(enabled ? true : false, std::memory_order_release);
}

static NSDictionary *SKIPNativeFCP360ProjectionPatchStats(void) {
    return @{
        @"installed": @(SKIPNativeFCP360ProjectionPatchIsInstalled()),
        @"enabled": @(sSKIPNativeFCP360ProjectionPatchEnabled.load(std::memory_order_acquire)),
        @"projectionCalls": @(sSKIPNativeFCP360ProjectionPatchCalls.load(std::memory_order_relaxed)),
        @"cameraModeOverrides": @(sSKIPNativeFCP360CameraModeOverrides.load(std::memory_order_relaxed)),
    };
}

static BOOL SKIPBoolFromSelector(id target, SEL selector, BOOL fallback) {
    if (!target || !selector || ![target respondsToSelector:selector]) return fallback;
    @try {
        return ((BOOL (*)(id, SEL))objc_msgSend)(target, selector);
    } @catch (__unused NSException *exception) {
        return fallback;
    }
}

static int SKIPIntFromSelector(id target, SEL selector, int fallback) {
    if (!target || !selector || ![target respondsToSelector:selector]) return fallback;
    @try {
        return ((int (*)(id, SEL))objc_msgSend)(target, selector);
    } @catch (__unused NSException *exception) {
        return fallback;
    }
}

static int SKIPOriginalCameraModeForPlayerFrame(id playerFrame, int fallback) {
    if (!playerFrame) return fallback;
    SKIPFFPlayerFrameCameraModeIMP original = sSKIPOriginalFFPlayerFrameCameraMode;
    if (original) {
        @try {
            return original(playerFrame, NSSelectorFromString(@"cameraMode"));
        } @catch (__unused NSException *exception) {
            return fallback;
        }
    }
    return SKIPIntFromSelector(playerFrame, NSSelectorFromString(@"cameraMode"), fallback);
}

static int SKIPPatchedFFPlayerFrameCameraMode(id self, SEL _cmd) {
    if (sSKIPNativeFCP360ProjectionPatchEnabled.load(std::memory_order_acquire) &&
        sSKIPNativeFCP360ProjectionOverrideFrame != NULL &&
        sSKIPNativeFCP360ProjectionOverrideFrame == (__bridge const void *)self) {
        sSKIPNativeFCP360CameraModeOverrides.fetch_add(1, std::memory_order_relaxed);
        return sSKIPNativeFCP360CameraModeOverrideValue.load(std::memory_order_acquire);
    }

    SKIPFFPlayerFrameCameraModeIMP original = sSKIPOriginalFFPlayerFrameCameraMode;
    return original ? original(self, _cmd) : 0;
}

static CGRect SKIPViewportBoundsForNativeFCP360VideoModule(id videoModule) {
    CGRect bounds = CGRectZero;
    if (!videoModule) return bounds;

    SEL playerViewBoundsSel = NSSelectorFromString(@"playerViewBounds");
    if ([videoModule respondsToSelector:playerViewBoundsSel]) {
        @try {
            bounds = ((CGRect (*)(id, SEL))SKIP_STRET_MSG)(videoModule, playerViewBoundsSel);
        } @catch (__unused NSException *exception) {
            bounds = CGRectZero;
        }
    }

    if (bounds.size.width <= 1.0 || bounds.size.height <= 1.0) {
        SEL sequenceBoundsSel = NSSelectorFromString(@"sequenceBounds");
        if ([videoModule respondsToSelector:sequenceBoundsSel]) {
            @try {
                bounds = ((CGRect (*)(id, SEL))SKIP_STRET_MSG)(videoModule, sequenceBoundsSel);
            } @catch (__unused NSException *exception) {
                bounds = CGRectZero;
            }
        }
    }

    if (bounds.size.width <= 1.0 || bounds.size.height <= 1.0) {
        SEL playerViewSel = NSSelectorFromString(@"playerView");
        id playerView = [videoModule respondsToSelector:playerViewSel]
            ? ((id (*)(id, SEL))objc_msgSend)(videoModule, playerViewSel)
            : nil;
        if ([playerView isKindOfClass:[NSView class]]) {
            bounds = [(NSView *)playerView bounds];
        }
    }

    if (bounds.size.width <= 1.0 || bounds.size.height <= 1.0) {
        return CGRectZero;
    }
    return CGRectMake(0.0, 0.0, bounds.size.width, bounds.size.height);
}

static id SKIPCopyProjectedImageWithViewportBounds(id videoModule, id projectedImage) {
    if (!videoModule || !projectedImage) return projectedImage;
    if (!SKIPBoolFromSelector(videoModule, NSSelectorFromString(@"is360Viewer"), NO)) {
        return projectedImage;
    }

    CGRect viewportBounds = SKIPViewportBoundsForNativeFCP360VideoModule(videoModule);
    if (viewportBounds.size.width <= 1.0 || viewportBounds.size.height <= 1.0) {
        return projectedImage;
    }

    Class matrixClass = objc_getClass("PCMatrix44Double");
    SEL makeIdentitySel = NSSelectorFromString(@"makeIdentity");
    SEL updateSel = NSSelectorFromString(@"newFFImageWithUpdatedPT:psb:field:");
    SEL fieldSel = NSSelectorFromString(@"field");
    if (!matrixClass || ![projectedImage respondsToSelector:updateSel]) {
        return projectedImage;
    }

    id matrix = [[matrixClass alloc] init];
    if ([matrix respondsToSelector:makeIdentitySel]) {
        ((void (*)(id, SEL))objc_msgSend)(matrix, makeIdentitySel);
    }

    unsigned int field = 0;
    if ([projectedImage respondsToSelector:fieldSel]) {
        @try {
            field = ((unsigned int (*)(id, SEL))objc_msgSend)(projectedImage, fieldSel);
        } @catch (__unused NSException *exception) {
            field = 0;
        }
    }

    __unsafe_unretained id adjustedImage =
        ((id (*)(id, SEL, id, CGRect, unsigned int))objc_msgSend)(projectedImage,
                                                                  updateSel,
                                                                  matrix,
                                                                  viewportBounds,
                                                                  field);
    if (!adjustedImage) return projectedImage;

    CFRelease((__bridge CFTypeRef)projectedImage);
    return adjustedImage;
}

static id SKIPPatchedNewProjectedImageForPlayerFrame(id self, SEL _cmd, id playerFrame) {
    SKIPNewProjectedImageForPlayerFrameIMP original = sSKIPOriginalNewProjectedImageForPlayerFrame;
    if (!original) return nil;

    if (!sSKIPNativeFCP360ProjectionPatchEnabled.load(std::memory_order_acquire) ||
        !playerFrame ||
        !SKIPBoolFromSelector(self, NSSelectorFromString(@"is360Viewer"), NO)) {
        return original(self, _cmd, playerFrame);
    }

    BOOL shouldOverrideCameraMode = SKIPOriginalCameraModeForPlayerFrame(playerFrame, 0) == 0;
    const void *oldOverrideFrame = sSKIPNativeFCP360ProjectionOverrideFrame;
    if (shouldOverrideCameraMode) {
        sSKIPNativeFCP360ProjectionOverrideFrame = (__bridge const void *)playerFrame;
    }
    sSKIPNativeFCP360ProjectionPatchCalls.fetch_add(1, std::memory_order_relaxed);
    @try {
        return original(self, _cmd, playerFrame);
    } @catch (NSException *exception) {
        SpliceKit_log(@"[ImmersivePreview] Native 360 projection patch failed: %@",
                      exception.reason ?: exception.name);
        @throw;
    } @finally {
        sSKIPNativeFCP360ProjectionOverrideFrame = oldOverrideFrame;
    }
}

static void SKIPInstallNativeFCP360ProjectionPatch(void) {
    if (SKIPNativeFCP360ProjectionPatchIsInstalled()) return;

    @synchronized ([NSApplication class]) {
        if (SKIPNativeFCP360ProjectionPatchIsInstalled()) return;

        Class videoModuleClass = objc_getClass("FFPlayerVideoModule");
        Class playerFrameClass = objc_getClass("FFPlayerFrame");
        SEL projectionSelector = NSSelectorFromString(@"newProjectedImageForPlayerFrame:");
        SEL cameraModeSelector = NSSelectorFromString(@"cameraMode");
        Method projectionMethod = videoModuleClass ? class_getInstanceMethod(videoModuleClass, projectionSelector) : NULL;
        Method cameraModeMethod = playerFrameClass ? class_getInstanceMethod(playerFrameClass, cameraModeSelector) : NULL;
        if (!projectionMethod || !cameraModeMethod) {
            return;
        }

        sSKIPOriginalFFPlayerFrameCameraMode =
            (SKIPFFPlayerFrameCameraModeIMP)method_setImplementation(
                cameraModeMethod,
                (IMP)SKIPPatchedFFPlayerFrameCameraMode);
        sSKIPOriginalNewProjectedImageForPlayerFrame =
            (SKIPNewProjectedImageForPlayerFrameIMP)method_setImplementation(
                projectionMethod,
                (IMP)SKIPPatchedNewProjectedImageForPlayerFrame);
    }
}

static BOOL SKIPOpenNativeFCP360Viewer(BOOL forceRebuild, NSError **error) {
    __block BOOL ok = NO;
    __block NSString *failure = nil;
    void (^openBlock)(void) = ^{
        NSApplication *app = [NSApplication sharedApplication];
        SEL show360Sel = NSSelectorFromString(@"show360:");
        SEL setModeSel = NSSelectorFromString(@"setMode:");
        id playerContainer = SKIPActivePlayerContainerModuleForPreview();
        @try {
            if (playerContainer &&
                [playerContainer respondsToSelector:@selector(mode)] &&
                [playerContainer respondsToSelector:setModeSel]) {
                NSInteger currentMode = ((NSInteger (*)(id, SEL))objc_msgSend)(playerContainer, @selector(mode));
                if (currentMode == 8 && forceRebuild) {
                    NSInteger fallbackMode = 0;
                    if ([playerContainer respondsToSelector:@selector(defaultMode)]) {
                        fallbackMode = ((NSInteger (*)(id, SEL))objc_msgSend)(playerContainer, @selector(defaultMode));
                    }
                    if (fallbackMode == 8) fallbackMode = 0;
                    ((void (*)(id, SEL, NSInteger))objc_msgSend)(playerContainer, setModeSel, fallbackMode);
                    currentMode = fallbackMode;
                }
                if (currentMode != 8) {
                    ((void (*)(id, SEL, NSInteger))objc_msgSend)(playerContainer, setModeSel, 8);
                }
                ok = YES;
                return;
            }

            id delegate = app.delegate;
            if (delegate && [delegate respondsToSelector:show360Sel]) {
                ((void (*)(id, SEL, id))objc_msgSend)(delegate, show360Sel, nil);
                ok = YES;
                return;
            }
            ok = [app sendAction:show360Sel to:nil from:nil];
            if (!ok) {
                failure = @"FCP's native 360 viewer action is not available in the current state";
            }
        } @catch (NSException *exception) {
            failure = exception.reason ?: @"FCP's native 360 viewer action threw an exception";
            ok = NO;
        }
    };

    if ([NSThread isMainThread]) {
        openBlock();
    } else {
        SpliceKit_executeOnMainThread(openBlock);
    }

    if (!ok && error) {
        *error = SKIPImmersivePreviewError(-40, failure ?: @"Unable to open FCP's native 360 viewer");
    }
    return ok;
}

static void SKIPCloseNativeFCP360Viewer(void) {
    if (![NSThread isMainThread]) {
        SpliceKit_executeOnMainThread(^{ SKIPCloseNativeFCP360Viewer(); });
        return;
    }

    @try {
        id playerContainer = SKIPActivePlayerContainerModuleForPreview();
        SEL setModeSel = NSSelectorFromString(@"setMode:");
        if (!playerContainer ||
            ![playerContainer respondsToSelector:@selector(mode)] ||
            ![playerContainer respondsToSelector:setModeSel]) {
            return;
        }

        NSInteger currentMode = ((NSInteger (*)(id, SEL))objc_msgSend)(playerContainer, @selector(mode));
        if (currentMode != 8) return;

        NSInteger fallbackMode = 0;
        if ([playerContainer respondsToSelector:@selector(defaultMode)]) {
            fallbackMode = ((NSInteger (*)(id, SEL))objc_msgSend)(playerContainer, @selector(defaultMode));
        }
        if (fallbackMode == 8) fallbackMode = 0;
        ((void (*)(id, SEL, NSInteger))objc_msgSend)(playerContainer, setModeSel, fallbackMode);
    } @catch (NSException *exception) {
        SpliceKit_log(@"[ImmersivePreview] Native 360 viewer close failed: %@",
                      exception.reason ?: exception.name);
    }
}

static inline double SKIPSecondsFromCMTime(SKIP_CMTime time) {
    return time.timescale > 0 ? ((double)time.value / (double)time.timescale) : 0.0;
}

static BOOL SKIPInvokeCMTimeNoArgs(id target, SEL selector, SKIP_CMTime *outTime) {
    if (outTime) *outTime = (SKIP_CMTime){0, 0, 0, 0};
    if (!target || !selector || ![target respondsToSelector:selector]) return NO;

    NSMethodSignature *signature = [target methodSignatureForSelector:selector];
    if (!signature || signature.methodReturnLength != sizeof(SKIP_CMTime)) return NO;

    @try {
        NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
        invocation.target = target;
        invocation.selector = selector;
        [invocation invoke];
        SKIP_CMTime value = {0, 0, 0, 0};
        [invocation getReturnValue:&value];
        if (value.timescale <= 0) return NO;
        if (outTime) *outTime = value;
        return YES;
    } @catch (__unused NSException *exception) {
        return NO;
    }
}

static BOOL SKIPInvokeCMTimeWithTimeAndObject(id target,
                                             SEL selector,
                                             SKIP_CMTime time,
                                             id object,
                                             SKIP_CMTime *outTime) {
    if (outTime) *outTime = (SKIP_CMTime){0, 0, 0, 0};
    if (!target || !selector || ![target respondsToSelector:selector]) return NO;

    NSMethodSignature *signature = [target methodSignatureForSelector:selector];
    if (!signature || signature.numberOfArguments < 4 ||
        signature.methodReturnLength != sizeof(SKIP_CMTime)) {
        return NO;
    }

    @try {
        NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
        invocation.target = target;
        invocation.selector = selector;
        [invocation setArgument:&time atIndex:2];
        id objectArg = object;
        [invocation setArgument:&objectArg atIndex:3];
        [invocation invoke];
        SKIP_CMTime value = {0, 0, 0, 0};
        [invocation getReturnValue:&value];
        if (value.timescale <= 0) return NO;
        if (outTime) *outTime = value;
        return YES;
    } @catch (__unused NSException *exception) {
        return NO;
    }
}

static BOOL SKIPInvokeCMTimeRangeWithObject(id target,
                                            SEL selector,
                                            id object,
                                            SKIP_CMTimeRange *outRange) {
    if (outRange) *outRange = (SKIP_CMTimeRange){{0, 0, 0, 0}, {0, 0, 0, 0}};
    if (!target || !selector || ![target respondsToSelector:selector]) return NO;

    NSMethodSignature *signature = [target methodSignatureForSelector:selector];
    if (!signature || signature.numberOfArguments < 3 ||
        signature.methodReturnLength != sizeof(SKIP_CMTimeRange)) {
        return NO;
    }

    @try {
        NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
        invocation.target = target;
        invocation.selector = selector;
        id objectArg = object;
        [invocation setArgument:&objectArg atIndex:2];
        [invocation invoke];
        SKIP_CMTimeRange range = {{0, 0, 0, 0}, {0, 0, 0, 0}};
        [invocation getReturnValue:&range];
        if (range.start.timescale <= 0 || range.duration.timescale <= 0) return NO;
        if (outRange) *outRange = range;
        return YES;
    } @catch (__unused NSException *exception) {
        return NO;
    }
}

static id SKIPActiveTimelineModuleForPreview(void) {
    if (![NSThread isMainThread]) return nil;

    @try {
        id app = [NSApplication sharedApplication];
        id delegate = [app delegate];
        if (!delegate) return nil;

        id editorContainer = nil;
        SEL activeEditorContainerSel = @selector(activeEditorContainer);
        if ([delegate respondsToSelector:activeEditorContainerSel]) {
            editorContainer = ((id (*)(id, SEL))objc_msgSend)(delegate, activeEditorContainerSel);
        }

        SEL mainEditorContainerSel = NSSelectorFromString(@"mainEditorContainer");
        if (!editorContainer && [delegate respondsToSelector:mainEditorContainerSel]) {
            editorContainer = ((id (*)(id, SEL))objc_msgSend)(delegate, mainEditorContainerSel);
        }

        SEL timelineModuleSel = NSSelectorFromString(@"timelineModule");
        if (editorContainer && [editorContainer respondsToSelector:timelineModuleSel]) {
            id timeline = ((id (*)(id, SEL))objc_msgSend)(editorContainer, timelineModuleSel);
            if (timeline) return timeline;
        }

        SEL activeEditorModuleSel = @selector(activeEditorModule);
        if ([delegate respondsToSelector:activeEditorModuleSel]) {
            return ((id (*)(id, SEL))objc_msgSend)(delegate, activeEditorModuleSel);
        }
    } @catch (NSException *exception) {
        SpliceKit_log(@"[ImmersivePreview] Active timeline lookup failed: %@",
                      exception.reason ?: exception.name);
    }

    return nil;
}

static BOOL SKIPExpectedDecodeDimensions(NSDictionary *clipSummary,
                                         uint32_t scaleHint,
                                         uint32_t *outWidth,
                                         uint32_t *outHeight) {
    if (outWidth) *outWidth = 0;
    if (outHeight) *outHeight = 0;

    NSArray *resolutions = [clipSummary[@"immersive"][@"resolutions"] isKindOfClass:[NSArray class]]
        ? clipSummary[@"immersive"][@"resolutions"]
        : nil;
    if (resolutions.count > 0) {
        NSUInteger index = MIN((NSUInteger)scaleHint, resolutions.count - 1);
        NSDictionary *resolution = [resolutions[index] isKindOfClass:[NSDictionary class]]
            ? resolutions[index]
            : nil;
        uint32_t width = [resolution[@"width"] respondsToSelector:@selector(unsignedIntValue)]
            ? [resolution[@"width"] unsignedIntValue]
            : 0;
        uint32_t height = [resolution[@"height"] respondsToSelector:@selector(unsignedIntValue)]
            ? [resolution[@"height"] unsignedIntValue]
            : 0;
        if (width > 0 && height > 0) {
            if (outWidth) *outWidth = width;
            if (outHeight) *outHeight = height;
            return YES;
        }
    }

    uint32_t width = [clipSummary[@"width"] respondsToSelector:@selector(unsignedIntValue)]
        ? [clipSummary[@"width"] unsignedIntValue]
        : 0;
    uint32_t height = [clipSummary[@"height"] respondsToSelector:@selector(unsignedIntValue)]
        ? [clipSummary[@"height"] unsignedIntValue]
        : 0;
    if (width == 0 || height == 0) {
        return NO;
    }

    uint32_t divisor = 1;
    if (scaleHint == 1) divisor = 2;
    else if (scaleHint == 2) divisor = 4;
    else if (scaleHint >= 3) divisor = 8;

    width = MAX(1, width / divisor);
    height = MAX(1, height / divisor);
    if (outWidth) *outWidth = width;
    if (outHeight) *outHeight = height;
    return YES;
}

static NSData *SKIPCopyPackedBGRADataFromPixelBuffer(CVPixelBufferRef pixelBuffer,
                                                     uint32_t width,
                                                     uint32_t height) {
    if (!pixelBuffer || width == 0 || height == 0) return nil;

    CVPixelBufferLockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
    void *baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer);
    size_t bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer);
    if (!baseAddress || bytesPerRow == 0) {
        CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
        return nil;
    }
    size_t requiredSourceBytes = (size_t)(height - 1) * bytesPerRow + (size_t)width * 4;
    size_t dataSize = CVPixelBufferGetDataSize(pixelBuffer);
    if (bytesPerRow < (size_t)width * 4 || (dataSize > 0 && dataSize < requiredSourceBytes)) {
        CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
        return nil;
    }

    NSMutableData *packed = [NSMutableData dataWithLength:(NSUInteger)width * (NSUInteger)height * 4];
    uint8_t *dst = (uint8_t *)packed.mutableBytes;
    const uint8_t *src = (const uint8_t *)baseAddress;
    for (uint32_t row = 0; row < height; row++) {
        memcpy(dst + ((size_t)row * width * 4),
               src + ((size_t)row * bytesPerRow),
               (size_t)width * 4);
    }

    CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
    return packed;
}

static NSData *SKIPDecodeEyeBytes(NSString *path,
                                  uint32_t frameIndex,
                                  uint32_t scaleHint,
                                  int eyeIndex,
                                  NSDictionary *clipSummary,
                                  uint32_t *outWidth,
                                  uint32_t *outHeight,
                                  NSError **error) {
    uint32_t expectedWidth = 0, expectedHeight = 0;
    if (SKIPExpectedDecodeDimensions(clipSummary, scaleHint, &expectedWidth, &expectedHeight) &&
        expectedWidth > 0 && expectedHeight > 0) {
        CVPixelBufferRef pixelBuffer = NULL;
        NSDictionary *attrs = @{
            (id)kCVPixelBufferWidthKey: @(expectedWidth),
            (id)kCVPixelBufferHeightKey: @(expectedHeight),
            (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
            (id)kCVPixelBufferMetalCompatibilityKey: @YES,
            (id)kCVPixelBufferCGImageCompatibilityKey: @YES,
            (id)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES,
            (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
        };
        CVReturn createStatus = CVPixelBufferCreate(kCFAllocatorDefault,
                                                    expectedWidth,
                                                    expectedHeight,
                                                    kCVPixelFormatType_32BGRA,
                                                    (__bridge CFDictionaryRef)attrs,
                                                    &pixelBuffer);
        if (createStatus == kCVReturnSuccess && pixelBuffer) {
            uint32_t width = 0, height = 0;
            BOOL pixelBufferOK = SpliceKitBRAW_DecodeFrameIntoPixelBufferEye((__bridge CFStringRef)path,
                                                                             frameIndex,
                                                                             scaleHint,
                                                                             eyeIndex,
                                                                             pixelBuffer,
                                                                             &width,
                                                                             &height);
            if (pixelBufferOK && width > 0 && height > 0) {
                NSData *packed = SKIPCopyPackedBGRADataFromPixelBuffer(pixelBuffer, width, height);
                CVPixelBufferRelease(pixelBuffer);
                if (packed.length > 0) {
                    if (outWidth) *outWidth = width;
                    if (outHeight) *outHeight = height;
                    return packed;
                }
            } else {
                CVPixelBufferRelease(pixelBuffer);
            }
        }
    }

    uint32_t width = 0, height = 0, sizeBytes = 0;
    void *bytes = nullptr;
    BOOL ok = SpliceKitBRAW_DecodeFrameBytesEye((__bridge CFStringRef)path,
                                                frameIndex,
                                                scaleHint,
                                                eyeIndex,
                                                1,
                                                &width,
                                                &height,
                                                &sizeBytes,
                                                &bytes);
    if (!ok || !bytes || width == 0 || height == 0 || sizeBytes == 0) {
        if (bytes) free(bytes);
        if (error) {
            *error = [NSError errorWithDomain:@"SpliceKitImmersivePreview" code:-1
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Unable to decode %@ eye for frame %u",
                                                                            eyeIndex == 0 ? @"left" : @"right",
                                                                            frameIndex]}];
        }
        return nil;
    }
    if (outWidth) *outWidth = width;
    if (outHeight) *outHeight = height;
    return [NSData dataWithBytesNoCopy:bytes length:sizeBytes freeWhenDone:YES];
}

static NSDictionary *SKIPDescribeImmersiveClipAtPath(NSString *path, NSError **error) {
    NSString *standardizedPath = path.stringByStandardizingPath ?: @"";
    if (standardizedPath.length == 0) {
        if (error) *error = SKIPImmersivePreviewError(-21, @"No immersive BRAW path was provided");
        return nil;
    }
    if (!standardizedPath.isAbsolutePath) {
        if (error) *error = SKIPImmersivePreviewError(-21, @"Immersive BRAW path must be absolute");
        return nil;
    }
    if (![[standardizedPath.pathExtension lowercaseString] isEqualToString:@"braw"]) {
        if (error) *error = SKIPImmersivePreviewError(-21, @"Immersive preview only supports .braw files");
        return nil;
    }
    BOOL isDirectory = NO;
    if (![[NSFileManager defaultManager] fileExistsAtPath:standardizedPath isDirectory:&isDirectory] || isDirectory) {
        if (error) *error = SKIPImmersivePreviewError(-21, @"Immersive BRAW file does not exist");
        return nil;
    }

    NSDictionary *description = SpliceKit_handleBRAWDescribeImmersive(@{
        @"path": standardizedPath,
        @"motionPreviewCount": @4,
    });
    NSArray *clips = [description[@"clips"] isKindOfClass:[NSArray class]] ? description[@"clips"] : nil;
    NSDictionary *clip = [clips.firstObject isKindOfClass:[NSDictionary class]] ? clips.firstObject : nil;
    NSString *clipError = [clip[@"error"] isKindOfClass:[NSString class]] ? clip[@"error"] : nil;
    if (!clip || clipError.length > 0) {
        if (error) {
            *error = SKIPImmersivePreviewError(-22,
                                               clipError.length > 0
                                                ? clipError
                                                : @"Unable to describe immersive BRAW clip");
        }
        return nil;
    }
    return clip;
}

static void SKIPSampleBGRA(const uint8_t *src,
                           size_t srcWidth,
                           size_t srcHeight,
                           double sampleX,
                           double sampleY,
                           uint8_t *dstPixel) {
    if (!src || !dstPixel || srcWidth == 0 || srcHeight == 0) return;
    if (sampleX < 0.0 || sampleY < 0.0 || sampleX > (double)(srcWidth - 1) || sampleY > (double)(srcHeight - 1)) {
        dstPixel[0] = 0;
        dstPixel[1] = 0;
        dstPixel[2] = 0;
        dstPixel[3] = 255;
        return;
    }

    size_t x0 = (size_t)floor(sampleX);
    size_t y0 = (size_t)floor(sampleY);
    size_t x1 = MIN(x0 + 1, srcWidth - 1);
    size_t y1 = MIN(y0 + 1, srcHeight - 1);
    double tx = sampleX - (double)x0;
    double ty = sampleY - (double)y0;

    const uint8_t *p00 = src + ((y0 * srcWidth + x0) * 4);
    const uint8_t *p10 = src + ((y0 * srcWidth + x1) * 4);
    const uint8_t *p01 = src + ((y1 * srcWidth + x0) * 4);
    const uint8_t *p11 = src + ((y1 * srcWidth + x1) * 4);

    for (int c = 0; c < 4; c++) {
        double top = (double)p00[c] + ((double)p10[c] - (double)p00[c]) * tx;
        double bottom = (double)p01[c] + ((double)p11[c] - (double)p01[c]) * tx;
        double value = top + (bottom - top) * ty;
        dstPixel[c] = (uint8_t)SKIPClamp(value, 0.0, 255.0);
    }
}

static NSData *SKIPRenderFisheyeMode(NSData *sourceData,
                                     size_t sourceWidth,
                                     size_t sourceHeight,
                                     size_t outputWidth,
                                     size_t outputHeight,
                                     double yawDegrees,
                                     double pitchDegrees,
                                     double fovDegrees,
                                     BOOL latLongMode) {
    if (!sourceData || sourceWidth == 0 || sourceHeight == 0 || outputWidth == 0 || outputHeight == 0) return nil;

    NSMutableData *output = [NSMutableData dataWithLength:outputWidth * outputHeight * 4];
    const uint8_t *src = (const uint8_t *)sourceData.bytes;
    uint8_t *dst = (uint8_t *)output.mutableBytes;
    double yaw = yawDegrees * M_PI / 180.0;
    double pitch = pitchDegrees * M_PI / 180.0;
    double tanHalfFov = tan((SKIPClamp(fovDegrees, 30.0, 160.0) * M_PI / 180.0) * 0.5);
    double radius = (double)MIN(sourceWidth, sourceHeight) * 0.5;
    double centerX = (double)sourceWidth * 0.5;
    double centerY = (double)sourceHeight * 0.5;

    for (size_t y = 0; y < outputHeight; y++) {
        for (size_t x = 0; x < outputWidth; x++) {
            double dirX = 0.0;
            double dirY = 0.0;
            double dirZ = 1.0;

            if (latLongMode) {
                double lon = (((double)x + 0.5) / (double)outputWidth - 0.5) * M_PI;
                double lat = (0.5 - ((double)y + 0.5) / (double)outputHeight) * M_PI;
                dirX = cos(lat) * sin(lon);
                dirY = sin(lat);
                dirZ = cos(lat) * cos(lon);
            } else {
                double ndcX = ((((double)x + 0.5) / (double)outputWidth) * 2.0 - 1.0) * tanHalfFov;
                double ndcY = (1.0 - (((double)y + 0.5) / (double)outputHeight) * 2.0) * tanHalfFov;
                double invLen = 1.0 / sqrt(ndcX * ndcX + ndcY * ndcY + 1.0);
                dirX = ndcX * invLen;
                dirY = ndcY * invLen;
                dirZ = invLen;
            }

            double rotatedX = cos(yaw) * dirX + sin(yaw) * dirZ;
            double rotatedZ = -sin(yaw) * dirX + cos(yaw) * dirZ;
            double rotatedY = cos(pitch) * dirY - sin(pitch) * rotatedZ;
            rotatedZ = sin(pitch) * dirY + cos(pitch) * rotatedZ;

            rotatedZ = SKIPClamp(rotatedZ, -1.0, 1.0);
            double theta = acos(rotatedZ);
            uint8_t *dstPixel = dst + ((y * outputWidth + x) * 4);
            if (theta > M_PI_2) {
                dstPixel[0] = 0;
                dstPixel[1] = 0;
                dstPixel[2] = 0;
                dstPixel[3] = 255;
                continue;
            }

            double phi = atan2(rotatedY, rotatedX);
            double radial = (theta / M_PI_2) * radius;
            double sampleX = centerX + cos(phi) * radial;
            double sampleY = centerY - sin(phi) * radial;
            double distance = hypot(sampleX - centerX, sampleY - centerY);
            if (distance > radius) {
                dstPixel[0] = 0;
                dstPixel[1] = 0;
                dstPixel[2] = 0;
                dstPixel[3] = 255;
                continue;
            }
            SKIPSampleBGRA(src, sourceWidth, sourceHeight, sampleX, sampleY, dstPixel);
        }
    }

    return output;
}

typedef NS_ENUM(uint32_t, SKIPImmersivePreviewEyeMode) {
    SKIPImmersivePreviewEyeModeHero = 0,
    SKIPImmersivePreviewEyeModeLeft = 1,
    SKIPImmersivePreviewEyeModeRight = 2,
    SKIPImmersivePreviewEyeModeStereo = 3,
};

typedef NS_ENUM(uint32_t, SKIPImmersivePreviewViewMode) {
    SKIPImmersivePreviewViewModeLens = 0,
    SKIPImmersivePreviewViewModeViewport = 1,
    SKIPImmersivePreviewViewModeLatLong = 2,
};

typedef struct {
    uint32_t drawableWidth;
    uint32_t drawableHeight;
    uint32_t sourceWidth;
    uint32_t sourceHeight;
    uint32_t eyeMode;
    uint32_t viewMode;
    uint32_t heroEyeIndex;
    uint32_t reserved;
    float yawRadians;
    float pitchRadians;
    float fovRadians;
    float gapFraction;
} SKIPImmersivePreviewMetalUniforms;

static NSString *sSKIPImmersivePreviewMetalPipelineError = nil;

static inline NSString *SKIPDescribeMetalError(NSError *error) {
    if (!error) return @"unknown error";
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    if (error.localizedDescription.length > 0) {
        [parts addObject:error.localizedDescription];
    }
    if (error.localizedFailureReason.length > 0) {
        [parts addObject:error.localizedFailureReason];
    }
    id compileErrors = error.userInfo[@"MTLCompileErrorKey"];
    if ([compileErrors isKindOfClass:[NSArray class]] && [compileErrors count] > 0) {
        NSMutableArray<NSString *> *descriptions = [NSMutableArray array];
        for (id entry in (NSArray *)compileErrors) {
            NSString *description = [entry description];
            if (description.length > 0) [descriptions addObject:description];
        }
        if (descriptions.count > 0) {
            [parts addObject:[NSString stringWithFormat:@"compileErrors=%@", [descriptions componentsJoinedByString:@" | "]]];
        }
    }
    if (parts.count == 0) {
        [parts addObject:error.description ?: @"unknown error"];
    }
    return [parts componentsJoinedByString:@" | "];
}

static NSString * const kSKIPImmersivePreviewMetalSource =
@"#include <metal_stdlib>\n"
@"using namespace metal;\n"
@"struct VertexOut {\n"
@"    float4 position [[position]];\n"
@"    float2 uv;\n"
@"};\n"
@"struct PreviewUniforms {\n"
@"    uint drawableWidth;\n"
@"    uint drawableHeight;\n"
@"    uint sourceWidth;\n"
@"    uint sourceHeight;\n"
@"    uint eyeMode;\n"
@"    uint viewMode;\n"
@"    uint heroEyeIndex;\n"
@"    uint reserved;\n"
@"    float yawRadians;\n"
@"    float pitchRadians;\n"
@"    float fovRadians;\n"
@"    float gapFraction;\n"
@"};\n"
@"vertex VertexOut immersivePreviewVertex(uint vid [[vertex_id]]) {\n"
@"    const float2 positions[6] = {\n"
@"        float2(-1.0, -1.0), float2(-1.0,  1.0), float2( 1.0, -1.0),\n"
@"        float2( 1.0, -1.0), float2(-1.0,  1.0), float2( 1.0,  1.0)\n"
@"    };\n"
@"    const float2 uvs[6] = {\n"
@"        float2(0.0, 1.0), float2(0.0, 0.0), float2(1.0, 1.0),\n"
@"        float2(1.0, 1.0), float2(0.0, 0.0), float2(1.0, 0.0)\n"
@"    };\n"
@"    VertexOut out;\n"
@"    out.position = float4(positions[vid], 0.0, 1.0);\n"
@"    out.uv = uvs[vid];\n"
@"    return out;\n"
@"}\n"
@"static float2 fitContentUV(float2 uv, float drawableAspect, float targetAspect, thread bool &outside) {\n"
@"    outside = false;\n"
@"    float2 local = uv;\n"
@"    if (drawableAspect > targetAspect) {\n"
@"        float contentWidth = targetAspect / drawableAspect;\n"
@"        float x0 = (1.0 - contentWidth) * 0.5;\n"
@"        float x1 = x0 + contentWidth;\n"
@"        if (uv.x < x0 || uv.x > x1) {\n"
@"            outside = true;\n"
@"            return float2(0.0);\n"
@"        }\n"
@"        local.x = (uv.x - x0) / contentWidth;\n"
@"        local.y = uv.y;\n"
@"        return local;\n"
@"    }\n"
@"    float contentHeight = drawableAspect / targetAspect;\n"
@"    float y0 = (1.0 - contentHeight) * 0.5;\n"
@"    float y1 = y0 + contentHeight;\n"
@"    if (uv.y < y0 || uv.y > y1) {\n"
@"        outside = true;\n"
@"        return float2(0.0);\n"
@"    }\n"
@"    local.x = uv.x;\n"
@"    local.y = (uv.y - y0) / contentHeight;\n"
@"    return local;\n"
@"}\n"
@"static float2 extractEyeUV(float2 uv, constant PreviewUniforms &u, thread uint &eyeIndex, thread bool &outside) {\n"
@"    eyeIndex = u.heroEyeIndex == 0 ? 0 : 1;\n"
@"    outside = false;\n"
@"    if (u.eyeMode == 1) {\n"
@"        eyeIndex = 0;\n"
@"        return uv;\n"
@"    }\n"
@"    if (u.eyeMode == 2) {\n"
@"        eyeIndex = 1;\n"
@"        return uv;\n"
@"    }\n"
@"    if (u.eyeMode != 3) {\n"
@"        return uv;\n"
@"    }\n"
@"    float gap = clamp(u.gapFraction, 0.0, 0.35);\n"
@"    float eyeWidth = (1.0 - gap) * 0.5;\n"
@"    if (uv.x < eyeWidth) {\n"
@"        eyeIndex = 0;\n"
@"        return float2(uv.x / eyeWidth, uv.y);\n"
@"    }\n"
@"    if (uv.x > eyeWidth + gap) {\n"
@"        eyeIndex = 1;\n"
@"        return float2((uv.x - eyeWidth - gap) / eyeWidth, uv.y);\n"
@"    }\n"
@"    outside = true;\n"
@"    return float2(0.0);\n"
@"}\n"
@"static float2 fisheyeSampleUV(float2 viewUV, constant PreviewUniforms &u, bool latLongMode, thread bool &valid) {\n"
@"    const float kPi = 3.14159265359;\n"
@"    const float kHalfPi = 1.57079632679;\n"
@"    valid = false;\n"
@"    float yaw = u.yawRadians;\n"
@"    float pitch = u.pitchRadians;\n"
@"    float3 dir = float3(0.0, 0.0, 1.0);\n"
@"    if (latLongMode) {\n"
@"        float lon = (viewUV.x - 0.5) * kPi;\n"
@"        float lat = (0.5 - viewUV.y) * kPi;\n"
@"        dir = float3(cos(lat) * sin(lon), sin(lat), cos(lat) * cos(lon));\n"
@"    } else {\n"
@"        const float kMinViewportFov = 0.5235987756f;\n"
@"        const float kMaxViewportFov = 2.7925268032f;\n"
@"        float tanHalfFov = tan(clamp(u.fovRadians, kMinViewportFov, kMaxViewportFov) * 0.5f);\n"
@"        float ndcX = (viewUV.x * 2.0 - 1.0) * tanHalfFov;\n"
@"        float ndcY = (1.0 - viewUV.y * 2.0) * tanHalfFov;\n"
@"        dir = normalize(float3(ndcX, ndcY, 1.0));\n"
@"    }\n"
@"    float cosYaw = cos(yaw);\n"
@"    float sinYaw = sin(yaw);\n"
@"    float rotatedX = cosYaw * dir.x + sinYaw * dir.z;\n"
@"    float rotatedZ = -sinYaw * dir.x + cosYaw * dir.z;\n"
@"    float cosPitch = cos(pitch);\n"
@"    float sinPitch = sin(pitch);\n"
@"    float rotatedY = cosPitch * dir.y - sinPitch * rotatedZ;\n"
@"    rotatedZ = sinPitch * dir.y + cosPitch * rotatedZ;\n"
@"    rotatedZ = clamp(rotatedZ, -1.0, 1.0);\n"
@"    float theta = acos(rotatedZ);\n"
@"    if (theta > kHalfPi) {\n"
@"        return float2(0.0);\n"
@"    }\n"
@"    float phi = atan2(rotatedY, rotatedX);\n"
@"    float radial = theta / kHalfPi;\n"
@"    float radiusX = min((float)u.sourceWidth, (float)u.sourceHeight) / ((float)u.sourceWidth * 2.0);\n"
@"    float radiusY = min((float)u.sourceWidth, (float)u.sourceHeight) / ((float)u.sourceHeight * 2.0);\n"
@"    float2 sampleUV = float2(0.5 + cos(phi) * radial * radiusX,\n"
@"                            0.5 - sin(phi) * radial * radiusY);\n"
@"    if (any(sampleUV < 0.0) || any(sampleUV > 1.0)) {\n"
@"        return float2(0.0);\n"
@"    }\n"
@"    valid = true;\n"
@"    return sampleUV;\n"
@"}\n"
@"fragment float4 immersivePreviewFragment(VertexOut in [[stage_in]],\n"
@"                                         constant PreviewUniforms &u [[buffer(0)]],\n"
@"                                         texture2d<float> leftTexture [[texture(0)]],\n"
@"                                         texture2d<float> rightTexture [[texture(1)]]) {\n"
@"    constexpr sampler linearSampler(coord::normalized, address::clamp_to_zero, filter::linear);\n"
@"    float drawableAspect = max(1.0f, float(u.drawableWidth)) / max(1.0f, float(u.drawableHeight));\n"
@"    float singleAspect = (u.viewMode == 2) ? 2.0f : 1.0f;\n"
@"    float targetAspect = singleAspect;\n"
@"    if (u.eyeMode == 3) {\n"
@"        targetAspect = singleAspect * 2.0f + clamp(u.gapFraction, 0.0f, 0.35f);\n"
@"    }\n"
@"    bool outside = false;\n"
@"    float2 fittedUV = fitContentUV(in.uv, drawableAspect, targetAspect, outside);\n"
@"    if (outside) {\n"
@"        return float4(0.0, 0.0, 0.0, 1.0);\n"
@"    }\n"
@"    uint eyeIndex = 0;\n"
@"    float2 eyeUV = extractEyeUV(fittedUV, u, eyeIndex, outside);\n"
@"    if (outside) {\n"
@"        return float4(0.0, 0.0, 0.0, 1.0);\n"
@"    }\n"
@"    if (u.viewMode == 0) {\n"
@"        if (eyeIndex == 0) {\n"
@"            return leftTexture.sample(linearSampler, eyeUV);\n"
@"        }\n"
@"        return rightTexture.sample(linearSampler, eyeUV);\n"
@"    }\n"
@"    bool valid = false;\n"
@"    float2 sampleUV = fisheyeSampleUV(eyeUV, u, u.viewMode == 2, valid);\n"
@"    if (!valid) {\n"
@"        return float4(0.0, 0.0, 0.0, 1.0);\n"
@"    }\n"
@"    if (eyeIndex == 0) {\n"
@"        return leftTexture.sample(linearSampler, sampleUV);\n"
@"    }\n"
@"    return rightTexture.sample(linearSampler, sampleUV);\n"
@"}\n";

static id<MTLDevice> SKIPImmersivePreviewMetalDevice(void) {
    static id<MTLDevice> device = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        device = MTLCreateSystemDefaultDevice();
        if (!device) {
            SpliceKit_log(@"[ImmersivePreview] Metal device unavailable");
        }
    });
    return device;
}

static id<MTLRenderPipelineState> SKIPImmersivePreviewPipelineState(id<MTLDevice> device) {
    static id<MTLRenderPipelineState> pipelineState = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        if (!device) return;
        sSKIPImmersivePreviewMetalPipelineError = nil;
        NSError *error = nil;
        id<MTLLibrary> library = [device newLibraryWithSource:kSKIPImmersivePreviewMetalSource
                                                      options:nil
                                                        error:&error];
        if (!library) {
            sSKIPImmersivePreviewMetalPipelineError = [NSString stringWithFormat:@"shader compilation failed: %@",
                                                      SKIPDescribeMetalError(error)];
            SpliceKit_log(@"[ImmersivePreview] Metal shader compilation failed: %@", sSKIPImmersivePreviewMetalPipelineError);
            return;
        }

        id<MTLFunction> vertexFunction = [library newFunctionWithName:@"immersivePreviewVertex"];
        id<MTLFunction> fragmentFunction = [library newFunctionWithName:@"immersivePreviewFragment"];
        if (!vertexFunction || !fragmentFunction) {
            sSKIPImmersivePreviewMetalPipelineError = [NSString stringWithFormat:@"shader functions unavailable vertex=%@ fragment=%@",
                                                      vertexFunction ? @"yes" : @"no",
                                                      fragmentFunction ? @"yes" : @"no"];
            SpliceKit_log(@"[ImmersivePreview] %@", sSKIPImmersivePreviewMetalPipelineError);
            return;
        }

        MTLRenderPipelineDescriptor *descriptor = [[MTLRenderPipelineDescriptor alloc] init];
        descriptor.vertexFunction = vertexFunction;
        descriptor.fragmentFunction = fragmentFunction;
        descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        pipelineState = [device newRenderPipelineStateWithDescriptor:descriptor error:&error];
        if (!pipelineState) {
            sSKIPImmersivePreviewMetalPipelineError = [NSString stringWithFormat:@"pipeline creation failed: %@",
                                                      SKIPDescribeMetalError(error)];
            SpliceKit_log(@"[ImmersivePreview] Metal pipeline creation failed: %@", sSKIPImmersivePreviewMetalPipelineError);
        }
    });
    return pipelineState;
}

static id<MTLSamplerState> SKIPImmersivePreviewSamplerState(id<MTLDevice> device) {
    static id<MTLSamplerState> samplerState = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        if (!device) return;
        MTLSamplerDescriptor *descriptor = [[MTLSamplerDescriptor alloc] init];
        descriptor.minFilter = MTLSamplerMinMagFilterLinear;
        descriptor.magFilter = MTLSamplerMinMagFilterLinear;
        descriptor.sAddressMode = MTLSamplerAddressModeClampToZero;
        descriptor.tAddressMode = MTLSamplerAddressModeClampToZero;
        samplerState = [device newSamplerStateWithDescriptor:descriptor];
    });
    return samplerState;
}

static NSData *SKIPCombineHorizontal(NSData *leftData,
                                     size_t leftWidth,
                                     size_t leftHeight,
                                     NSData *rightData,
                                     size_t rightWidth,
                                     size_t rightHeight,
                                     size_t gap) {
    if (!leftData || !rightData || leftHeight != rightHeight) return nil;
    size_t outWidth = leftWidth + gap + rightWidth;
    size_t outHeight = leftHeight;
    NSMutableData *combined = [NSMutableData dataWithLength:outWidth * outHeight * 4];
    uint8_t *dst = (uint8_t *)combined.mutableBytes;
    memset(dst, 0, combined.length);

    const uint8_t *left = (const uint8_t *)leftData.bytes;
    const uint8_t *right = (const uint8_t *)rightData.bytes;
    for (size_t row = 0; row < outHeight; row++) {
        memcpy(dst + ((row * outWidth) * 4),
               left + ((row * leftWidth) * 4),
               leftWidth * 4);
        memcpy(dst + ((row * outWidth + leftWidth + gap) * 4),
               right + ((row * rightWidth) * 4),
               rightWidth * 4);
    }
    return combined;
}

static NSData *SKIPCropCenteredBGRA(NSData *sourceData,
                                    size_t sourceWidth,
                                    size_t sourceHeight,
                                    size_t cropWidth,
                                    size_t cropHeight) {
    if (!sourceData || cropWidth == 0 || cropHeight == 0 ||
        cropWidth > sourceWidth || cropHeight > sourceHeight) {
        return nil;
    }

    size_t originX = (sourceWidth - cropWidth) / 2;
    size_t originY = (sourceHeight - cropHeight) / 2;
    NSMutableData *cropped = [NSMutableData dataWithLength:cropWidth * cropHeight * 4];
    const uint8_t *src = (const uint8_t *)sourceData.bytes;
    uint8_t *dst = (uint8_t *)cropped.mutableBytes;
    for (size_t row = 0; row < cropHeight; row++) {
        const uint8_t *srcRow = src + ((((row + originY) * sourceWidth) + originX) * 4);
        memcpy(dst + ((row * cropWidth) * 4), srcRow, cropWidth * 4);
    }
    return cropped;
}

static void SKIPComputePreviewOutputDimensions(NSString *viewMode,
                                               size_t decodedWidth,
                                               size_t decodedHeight,
                                               NSSize displaySize,
                                               CGFloat backingScale,
                                               BOOL interactive,
                                               size_t *outWidth,
                                               size_t *outHeight) {
    if (outWidth) *outWidth = 0;
    if (outHeight) *outHeight = 0;
    if (decodedWidth == 0 || decodedHeight == 0) return;

    BOOL needsViewport = [viewMode isEqualToString:@"viewport"];
    BOOL needsLatLong = [viewMode isEqualToString:@"latlong"];
    CGFloat safeScale = backingScale > 0.0 ? backingScale : 1.0;
    CGFloat renderScale = interactive ? 0.35 : 1.0;
    CGFloat targetWidth = displaySize.width > 0.0 ? displaySize.width * safeScale * renderScale : 0.0;
    CGFloat targetHeight = displaySize.height > 0.0 ? displaySize.height * safeScale * renderScale : 0.0;

    if (needsViewport) {
        size_t square = interactive ? 384 : 960;
        if (targetWidth > 0.0 && targetHeight > 0.0) {
            CGFloat floor = interactive ? 256.0 : 320.0;
            square = (size_t)llround(MAX(floor, MIN(targetWidth, targetHeight)));
        }
        square = MIN(square, MIN(decodedWidth, decodedHeight));
        square = MAX(interactive ? (size_t)256 : (size_t)320, square);
        if (outWidth) *outWidth = square;
        if (outHeight) *outHeight = square;
        return;
    }

    if (needsLatLong) {
        size_t width = interactive ? 512 : 960;
        if (targetWidth > 0.0 && targetHeight > 0.0) {
            CGFloat floor = interactive ? 384.0 : 480.0;
            width = (size_t)llround(MAX(floor, MIN(targetWidth, targetHeight * 2.0)));
        }
        width = MIN(width, decodedWidth);
        width = MAX(interactive ? (size_t)384 : (size_t)480, width);
        size_t height = MAX(interactive ? (size_t)192 : (size_t)240, MIN(decodedHeight, width / 2));
        if (outWidth) *outWidth = width;
        if (outHeight) *outHeight = height;
        return;
    }

    size_t square = MIN(decodedWidth, decodedHeight);
    size_t target = interactive ? 512 : square;
    if (targetWidth > 0.0 && targetHeight > 0.0) {
        CGFloat floor = interactive ? 384.0 : 480.0;
        target = (size_t)llround(MAX(floor, MIN(targetWidth, targetHeight)));
    }
    target = MIN(target, square);
    target = MAX(interactive ? (size_t)384 : (size_t)480, target);
    if (outWidth) *outWidth = target;
    if (outHeight) *outHeight = target;
}

static NSDictionary *SKIPBuildPreviewImageData(NSData *leftDecodedData,
                                               NSData *rightDecodedData,
                                               size_t decodedWidth,
                                               size_t decodedHeight,
                                               NSString *eyeMode,
                                               NSString *viewMode,
                                               NSInteger heroEyeIndex,
                                               double yawDegrees,
                                               double pitchDegrees,
                                               double fovDegrees,
                                               NSSize displaySize,
                                               CGFloat backingScale,
                                               BOOL interactive) {
    if (!leftDecodedData || !rightDecodedData || decodedWidth == 0 || decodedHeight == 0) return nil;

    NSData *primaryData = (heroEyeIndex == 0) ? leftDecodedData : rightDecodedData;
    NSData *secondaryData = (heroEyeIndex == 0) ? rightDecodedData : leftDecodedData;
    BOOL needsViewport = [viewMode isEqualToString:@"viewport"];
    BOOL needsLatLong = [viewMode isEqualToString:@"latlong"];

    size_t singleWidth = 0;
    size_t singleHeight = 0;
    SKIPComputePreviewOutputDimensions(viewMode,
                                       decodedWidth,
                                       decodedHeight,
                                       displaySize,
                                       backingScale,
                                       interactive,
                                       &singleWidth,
                                       &singleHeight);
    if (singleWidth == 0 || singleHeight == 0) return nil;

    NSData* (^renderMode)(NSData *) = ^NSData *(NSData *sourceData) {
        if (needsViewport || needsLatLong) {
            return SKIPRenderFisheyeMode(sourceData,
                                         decodedWidth,
                                         decodedHeight,
                                         singleWidth,
                                         singleHeight,
                                         yawDegrees,
                                         pitchDegrees,
                                         fovDegrees,
                                         needsLatLong);
        }
        if (decodedWidth != singleWidth || decodedHeight != singleHeight) {
            NSData *cropped = SKIPCropCenteredBGRA(sourceData,
                                                   decodedWidth,
                                                   decodedHeight,
                                                   singleWidth,
                                                   singleHeight);
            if (cropped.length > 0) return cropped;
        }
        return sourceData;
    };

    NSData *rendered = nil;
    size_t outputWidth = singleWidth;
    size_t outputHeight = singleHeight;
    if ([eyeMode isEqualToString:@"left"]) {
        rendered = renderMode(leftDecodedData);
    } else if ([eyeMode isEqualToString:@"right"]) {
        rendered = renderMode(rightDecodedData);
    } else if ([eyeMode isEqualToString:@"stereo"]) {
        NSData *leftRendered = renderMode(leftDecodedData);
        NSData *rightRendered = renderMode(rightDecodedData);
        rendered = SKIPCombineHorizontal(leftRendered,
                                         singleWidth,
                                         singleHeight,
                                         rightRendered,
                                         singleWidth,
                                         singleHeight,
                                         12);
        outputWidth = singleWidth * 2 + 12;
    } else {
        rendered = renderMode(primaryData ?: secondaryData);
    }

    if (!rendered || rendered.length == 0) return nil;
    return @{
        @"data": rendered,
        @"width": @(outputWidth),
        @"height": @(outputHeight),
    };
}

static NSImage *SKIPImageFromBGRAData(NSData *data, size_t width, size_t height) {
    if (!data || width == 0 || height == 0) return nil;
    CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)data);
    if (!provider) return nil;
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGImageRef imageRef = CGImageCreate(width,
                                        height,
                                        8,
                                        32,
                                        width * 4,
                                        colorSpace,
                                        kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst,
                                        provider,
                                        NULL,
                                        false,
                                        kCGRenderingIntentDefault);
    CGColorSpaceRelease(colorSpace);
    CGDataProviderRelease(provider);
    if (!imageRef) return nil;
    NSImage *image = [[NSImage alloc] initWithCGImage:imageRef size:NSMakeSize(width, height)];
    CGImageRelease(imageRef);
    return image;
}

static NSURL *SKIPFirstFileURLFromArray(id value) {
    if (![value isKindOfClass:[NSArray class]]) return nil;
    NSArray *items = (NSArray *)value;
    if (items.count == 0) return nil;
    id first = items.firstObject;
    return [first isKindOfClass:[NSURL class]] ? first : nil;
}

static NSURL *SKIPDirectMediaURLForClipObject(id clip) {
    if (!clip) return nil;

    id clipForMedia = clip;
    SEL primarySel = NSSelectorFromString(@"primaryObject");
    if ([clipForMedia respondsToSelector:primarySel]) {
        id primary = ((id (*)(id, SEL))objc_msgSend)(clipForMedia, primarySel);
        if (primary) clipForMedia = primary;
    }

    SEL containedSel = NSSelectorFromString(@"containedItems");
    if ([clipForMedia respondsToSelector:containedSel]) {
        id contained = ((id (*)(id, SEL))objc_msgSend)(clipForMedia, containedSel);
        if ([contained isKindOfClass:[NSArray class]]) {
            for (id child in (NSArray *)contained) {
                NSString *className = NSStringFromClass([child class]);
                if ([className containsString:@"MediaComponent"] ||
                    [className containsString:@"Asset"] ||
                    [className containsString:@"Clip"]) {
                    clipForMedia = child;
                    break;
                }
            }
        }
    }

    @try {
        SEL originalMediaURLSel = NSSelectorFromString(@"originalMediaURL");
        if ([clipForMedia respondsToSelector:originalMediaURLSel]) {
            id url = ((id (*)(id, SEL))objc_msgSend)(clipForMedia, originalMediaURLSel);
            if ([url isKindOfClass:[NSURL class]]) return url;
        }

        id media = nil;
        SEL mediaSel = NSSelectorFromString(@"media");
        if ([clipForMedia respondsToSelector:mediaSel]) {
            media = ((id (*)(id, SEL))objc_msgSend)(clipForMedia, mediaSel);
        }
        if (media) {
            if ([media respondsToSelector:originalMediaURLSel]) {
                id url = ((id (*)(id, SEL))objc_msgSend)(media, originalMediaURLSel);
                if ([url isKindOfClass:[NSURL class]]) return url;
            }

            SEL repSel = NSSelectorFromString(@"originalMediaRep");
            if ([media respondsToSelector:repSel]) {
                id rep = ((id (*)(id, SEL))objc_msgSend)(media, repSel);
                SEL fileURLsSel = NSSelectorFromString(@"fileURLs");
                if (rep && [rep respondsToSelector:fileURLsSel]) {
                    NSURL *url = SKIPFirstFileURLFromArray(((id (*)(id, SEL))objc_msgSend)(rep, fileURLsSel));
                    if (url) return url;
                }
            }

            repSel = NSSelectorFromString(@"currentRep");
            if ([media respondsToSelector:repSel]) {
                id rep = ((id (*)(id, SEL))objc_msgSend)(media, repSel);
                SEL fileURLsSel = NSSelectorFromString(@"fileURLs");
                if (rep && [rep respondsToSelector:fileURLsSel]) {
                    NSURL *url = SKIPFirstFileURLFromArray(((id (*)(id, SEL))objc_msgSend)(rep, fileURLsSel));
                    if (url) return url;
                }
            }
        }

        SEL refSel = NSSelectorFromString(@"assetMediaReference");
        if ([clipForMedia respondsToSelector:refSel]) {
            id ref = ((id (*)(id, SEL))objc_msgSend)(clipForMedia, refSel);
            SEL resolvedSel = NSSelectorFromString(@"resolvedURL");
            if (ref && [ref respondsToSelector:resolvedSel]) {
                id url = ((id (*)(id, SEL))objc_msgSend)(ref, resolvedSel);
                if ([url isKindOfClass:[NSURL class]]) return url;
            }
        }
    } @catch (__unused NSException *exception) {
    }

    return nil;
}

static BOOL SKIPItemBoundsInContext(id context, id item, double *outStart, double *outEnd) {
    if (!context || !item || !outStart || !outEnd) return NO;

    SEL startSel = @selector(timelineStartTime);
    SEL durSel = @selector(duration);
    if ([item respondsToSelector:startSel] && [item respondsToSelector:durSel]) {
        SKIP_CMTime start = {0, 0, 0, 0};
        SKIP_CMTime duration = {0, 0, 0, 0};
        SKIPInvokeCMTimeNoArgs(item, startSel, &start);
        SKIPInvokeCMTimeNoArgs(item, durSel, &duration);
        if (start.timescale > 0 && duration.timescale > 0) {
            *outStart = (double)start.value / (double)start.timescale;
            *outEnd = *outStart + ((double)duration.value / (double)duration.timescale);
            return YES;
        }
    }

    SEL rangeSel = NSSelectorFromString(@"effectiveRangeOfObject:");
    if (![context respondsToSelector:rangeSel]) return NO;

    SKIP_CMTimeRange range = {{0, 0, 0, 0}, {0, 0, 0, 0}};
    SKIPInvokeCMTimeRangeWithObject(context, rangeSel, item, &range);
    if (range.start.timescale <= 0 || range.duration.timescale <= 0) return NO;

    *outStart = (double)range.start.value / (double)range.start.timescale;
    *outEnd = *outStart + ((double)range.duration.value / (double)range.duration.timescale);
    return YES;
}

static BOOL SKIPCurrentTimelineTimeAndContext(SKIP_CMTime *outPlayhead, id *outContext, id *outSequence) {
    if (outPlayhead) *outPlayhead = (SKIP_CMTime){0, 0, 0, 0};
    if (outContext) *outContext = nil;
    if (outSequence) *outSequence = nil;

    id timeline = SKIPActiveTimelineModuleForPreview();
    if (!timeline) return NO;

    id sequence = [timeline respondsToSelector:@selector(sequence)]
        ? ((id (*)(id, SEL))objc_msgSend)(timeline, @selector(sequence))
        : nil;
    if (!sequence) return NO;

    id primaryObject = [sequence respondsToSelector:@selector(primaryObject)]
        ? ((id (*)(id, SEL))objc_msgSend)(sequence, @selector(primaryObject))
        : nil;

    SEL timeSel = NSSelectorFromString(@"currentSequenceTime");
    if (![timeline respondsToSelector:timeSel]) {
        timeSel = @selector(playheadTime);
    }
    if (![timeline respondsToSelector:timeSel]) return NO;

    SKIP_CMTime playhead = {0, 0, 0, 0};
    SKIPInvokeCMTimeNoArgs(timeline, timeSel, &playhead);
    if (playhead.timescale <= 0) return NO;

    if (outPlayhead) *outPlayhead = playhead;
    if (outContext) *outContext = primaryObject ?: sequence;
    if (outSequence) *outSequence = sequence;
    return YES;
}

static BOOL SKIPClipTrimStartSeconds(id item, double *outTrimStartSeconds) {
    if (outTrimStartSeconds) *outTrimStartSeconds = 0.0;
    if (!item) return NO;

    SEL trimmedOffsetSel = NSSelectorFromString(@"trimmedOffset");
    if ([item respondsToSelector:trimmedOffsetSel]) {
        SKIP_CMTime trimmedOffset = {0, 0, 0, 0};
        SKIPInvokeCMTimeNoArgs(item, trimmedOffsetSel, &trimmedOffset);
        if (trimmedOffset.timescale > 0) {
            if (outTrimStartSeconds) *outTrimStartSeconds = SKIPSecondsFromCMTime(trimmedOffset);
            return YES;
        }
    }

    SEL clippedRangeSel = NSSelectorFromString(@"clippedRange");
    if ([item respondsToSelector:clippedRangeSel]) {
        SKIP_CMTimeRange clippedRange = {{0, 0, 0, 0}, {0, 0, 0, 0}};
        NSMethodSignature *signature = [item methodSignatureForSelector:clippedRangeSel];
        if (signature && signature.methodReturnLength == sizeof(SKIP_CMTimeRange)) {
            @try {
                NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
                invocation.target = item;
                invocation.selector = clippedRangeSel;
                [invocation invoke];
                [invocation getReturnValue:&clippedRange];
            } @catch (__unused NSException *exception) {
            }
        }
        if (clippedRange.start.timescale > 0) {
            if (outTrimStartSeconds) *outTrimStartSeconds = SKIPSecondsFromCMTime(clippedRange.start);
            return YES;
        }
    }

    SEL trimStartSel = NSSelectorFromString(@"trimStartTime");
    if ([item respondsToSelector:trimStartSel]) {
        SKIP_CMTime trimStart = {0, 0, 0, 0};
        SKIPInvokeCMTimeNoArgs(item, trimStartSel, &trimStart);
        if (trimStart.timescale > 0) {
            if (outTrimStartSeconds) *outTrimStartSeconds = SKIPSecondsFromCMTime(trimStart);
            return YES;
        }
    }

    return NO;
}

static BOOL SKIPClipSourceSecondsAtPlayhead(id item,
                                            id context,
                                            SKIP_CMTime playhead,
                                            double maxSourceSeconds,
                                            double *outPlayheadSeconds,
                                            double *outClipStartSeconds,
                                            double *outClipEndSeconds,
                                            double *outSourceSeconds) {
    if (outPlayheadSeconds) *outPlayheadSeconds = 0.0;
    if (outClipStartSeconds) *outClipStartSeconds = 0.0;
    if (outClipEndSeconds) *outClipEndSeconds = 0.0;
    if (outSourceSeconds) *outSourceSeconds = 0.0;
    if (!item || !context || playhead.timescale <= 0) return NO;

    double clipStart = 0.0, clipEnd = 0.0;
    if (!SKIPItemBoundsInContext(context, item, &clipStart, &clipEnd)) return NO;

    double playheadSeconds = SKIPSecondsFromCMTime(playhead);
    if (playheadSeconds < clipStart - 0.001 || playheadSeconds > clipEnd + 0.001) return NO;

    double clipDurationSeconds = MAX(0.0, clipEnd - clipStart);
    double sourceDurationSeconds = maxSourceSeconds > 0.0 ? maxSourceSeconds : clipDurationSeconds;
    double localSeconds = 0.0;
    BOOL hasSaneLocalSeconds = NO;
    SEL localTimeSel = NSSelectorFromString(@"containerToLocalTime:container:");
    if ([item respondsToSelector:localTimeSel]) {
        SKIP_CMTime localTime = {0, 0, 0, 0};
        SKIPInvokeCMTimeWithTimeAndObject(item, localTimeSel, playhead, context, &localTime);
        if (localTime.timescale > 0) {
            localSeconds = SKIPSecondsFromCMTime(localTime);
            hasSaneLocalSeconds = (localSeconds >= -0.001 &&
                                   localSeconds <= (sourceDurationSeconds + 0.25));
            if (hasSaneLocalSeconds) {
                localSeconds = SKIPClamp(localSeconds, 0.0, MAX(sourceDurationSeconds, clipDurationSeconds));
            }
        }
    }

    double trimStartSeconds = 0.0;
    BOOL hasSaneTrimStart = SKIPClipTrimStartSeconds(item, &trimStartSeconds) &&
        trimStartSeconds >= -0.001 &&
        trimStartSeconds <= MAX(0.0, sourceDurationSeconds - MIN(clipDurationSeconds, sourceDurationSeconds) + 0.25);

    double sourceSeconds = MAX(0.0, playheadSeconds - clipStart);
    if (hasSaneLocalSeconds) {
        if (hasSaneTrimStart && localSeconds <= (clipDurationSeconds + 0.25)) {
            sourceSeconds = trimStartSeconds + localSeconds;
        } else {
            sourceSeconds = localSeconds;
        }
    } else if (hasSaneTrimStart) {
        sourceSeconds = trimStartSeconds + MAX(0.0, playheadSeconds - clipStart);
    }
    sourceSeconds = SKIPClamp(sourceSeconds, 0.0, MAX(sourceDurationSeconds, clipDurationSeconds));

    if (outPlayheadSeconds) *outPlayheadSeconds = playheadSeconds;
    if (outClipStartSeconds) *outClipStartSeconds = clipStart;
    if (outClipEndSeconds) *outClipEndSeconds = clipEnd;
    if (outSourceSeconds) *outSourceSeconds = sourceSeconds;
    return YES;
}

static id SKIPTimelineClipNearPlayhead(void) {
    id timeline = SKIPActiveTimelineModuleForPreview();
    if (!timeline) return nil;

    id sequence = [timeline respondsToSelector:@selector(sequence)]
        ? ((id (*)(id, SEL))objc_msgSend)(timeline, @selector(sequence))
        : nil;
    if (!sequence) return nil;

    id primaryObject = [sequence respondsToSelector:@selector(primaryObject)]
        ? ((id (*)(id, SEL))objc_msgSend)(sequence, @selector(primaryObject))
        : nil;
    id itemsSource = nil;
    if (primaryObject && [primaryObject respondsToSelector:@selector(containedItems)]) {
        itemsSource = ((id (*)(id, SEL))objc_msgSend)(primaryObject, @selector(containedItems));
    } else if ([sequence respondsToSelector:@selector(containedItems)]) {
        itemsSource = ((id (*)(id, SEL))objc_msgSend)(sequence, @selector(containedItems));
    }
    if (![itemsSource isKindOfClass:[NSArray class]] || [(NSArray *)itemsSource count] == 0) {
        return nil;
    }

    NSArray *items = (NSArray *)itemsSource;
    if (items.count == 1) return items.firstObject;

    SEL timeSel = NSSelectorFromString(@"currentSequenceTime");
    if (![timeline respondsToSelector:timeSel]) {
        timeSel = @selector(playheadTime);
    }
    if (![timeline respondsToSelector:timeSel]) return items.firstObject;

    SKIP_CMTime playhead = {0, 0, 0, 0};
    SKIPInvokeCMTimeNoArgs(timeline, timeSel, &playhead);
    if (playhead.timescale <= 0) return items.firstObject;
    double playheadSeconds = (double)playhead.value / (double)playhead.timescale;

    id context = primaryObject ?: sequence;
    for (id item in items) {
        NSString *className = NSStringFromClass([item class]);
        if ([className containsString:@"Transition"]) continue;

        double start = 0.0, end = 0.0;
        if (!SKIPItemBoundsInContext(context, item, &start, &end)) continue;
        if (playheadSeconds >= start - 0.001 && playheadSeconds <= end + 0.001) {
            return item;
        }
    }

    return items.firstObject;
}

static NSString *SKIPTimelineClipPathNearPlayheadOnMainThread(void) {
    id item = SKIPTimelineClipNearPlayhead();
    if (!item) return nil;

    NSURL *mediaURL = SKIPDirectMediaURLForClipObject(item);
    NSString *path = mediaURL.path.stringByStandardizingPath;
    return path.length > 0 ? path : nil;
}

NSString *SpliceKit_copyTimelineClipPathNearPlayhead(void) {
    __block NSString *path = nil;
    if ([NSThread isMainThread]) {
        path = SKIPTimelineClipPathNearPlayheadOnMainThread();
    } else {
        SpliceKit_executeOnMainThread(^{
            path = SKIPTimelineClipPathNearPlayheadOnMainThread();
        });
    }
    return path;
}

static NSString *SKIPResolveFirstPathFromSelection(void) {
    @try {
        NSString *timelinePath = SpliceKit_copyTimelineClipPathNearPlayhead() ?: @"";
        if (timelinePath.length == 0) return nil;

        NSString *path = SpliceKitBRAWResolveOriginalPathForPublic(timelinePath) ?: @"";
        if (path.length == 0 || ![[path.pathExtension lowercaseString] isEqualToString:@"braw"]) {
            return nil;
        }

        return [[NSURL fileURLWithPath:path] URLByResolvingSymlinksInPath].path.stringByStandardizingPath;
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static NSInteger SKIPCameraModeForVideoProps(id videoProps) {
    if (!videoProps || ![videoProps respondsToSelector:@selector(cameraMode)]) return 0;
    @try {
        return ((NSInteger (*)(id, SEL))objc_msgSend)(videoProps, @selector(cameraMode));
    } @catch (__unused NSException *exception) {
        return 0;
    }
}

static id SKIPObjectIfSupported(id target, NSString *selectorName) {
    if (!target || selectorName.length == 0) return nil;
    SEL selector = NSSelectorFromString(selectorName);
    if (![target respondsToSelector:selector]) return nil;
    @try {
        return ((id (*)(id, SEL))objc_msgSend)(target, selector);
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static NSNumber *SKIPIntegerIfSupported(id target, NSString *selectorName) {
    if (!target || selectorName.length == 0) return nil;
    SEL selector = NSSelectorFromString(selectorName);
    if (![target respondsToSelector:selector]) return nil;
    @try {
        return @(((NSInteger (*)(id, SEL))objc_msgSend)(target, selector));
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static BOOL SKIPSetIntegerIfSupported(id target, NSString *selectorName, NSInteger value) {
    if (!target || selectorName.length == 0) return NO;
    SEL selector = NSSelectorFromString(selectorName);
    if (![target respondsToSelector:selector]) return NO;
    @try {
        ((void (*)(id, SEL, NSInteger))objc_msgSend)(target, selector, value);
        return YES;
    } @catch (NSException *exception) {
        SpliceKit_log(@"[ImmersivePreview] %@ failed on %@: %@",
                      selectorName,
                      NSStringFromClass([target class]),
                      exception.reason ?: exception.name);
        return NO;
    }
}

static BOOL SKIPSetObjectIfSupported(id target, NSString *selectorName, id value) {
    if (!target || selectorName.length == 0) return NO;
    SEL selector = NSSelectorFromString(selectorName);
    if (![target respondsToSelector:selector]) return NO;
    @try {
        ((void (*)(id, SEL, id))objc_msgSend)(target, selector, value);
        return YES;
    } @catch (NSException *exception) {
        SpliceKit_log(@"[ImmersivePreview] %@ failed on %@: %@",
                      selectorName,
                      NSStringFromClass([target class]),
                      exception.reason ?: exception.name);
        return NO;
    }
}

static id SKIPIntrinsicEffectIfSupported(id effectStack, NSString *effectID, BOOL createIfAbsent) {
    if (!effectStack || effectID.length == 0) return nil;
    SEL selector = NSSelectorFromString(@"intrinsicEffectWithID:createIfAbsent:");
    if (![effectStack respondsToSelector:selector]) return nil;
    @try {
        return ((id (*)(id, SEL, id, BOOL))objc_msgSend)(effectStack, selector, effectID, createIfAbsent);
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static BOOL SKIPShowAndEnable360EffectIfSupported(id target, NSString *effectID, BOOL show, BOOL enable) {
    if (!target || effectID.length == 0) return NO;
    SEL selector = NSSelectorFromString(@"showAndEnable360Effect:show:enable:");
    if (![target respondsToSelector:selector]) return NO;
    @try {
        ((void (*)(id, SEL, id, BOOL, BOOL))objc_msgSend)(target, selector, effectID, show, enable);
        return YES;
    } @catch (NSException *exception) {
        SpliceKit_log(@"[ImmersivePreview] showAndEnable360Effect %@ failed on %@: %@",
                      effectID,
                      NSStringFromClass([target class]),
                      exception.reason ?: exception.name);
        return NO;
    }
}

static NSDictionary *SKIPNativeFCP360EffectSnapshot(id target) {
    id effectStack = SKIPObjectIfSupported(target, @"videoEffects");
    if (!effectStack) return @{};

    NSMutableDictionary *snapshot = [NSMutableDictionary dictionary];
    for (NSString *effectID in @[@"HE360Transform", @"HEOrientation", @"HEReorient", @"HES3DAdjust"]) {
        id effect = SKIPIntrinsicEffectIfSupported(effectStack, effectID, NO);
        if (!effect) {
            snapshot[effectID] = @{@"present": @NO};
            continue;
        }
        snapshot[effectID] = @{
            @"present": @YES,
            @"enabled": @(SKIPBoolFromSelector(effect, NSSelectorFromString(@"enabled"), NO)),
            @"class": NSStringFromClass([effect class]) ?: @"",
        };
    }
    return [snapshot copy];
}

static NSDictionary *SKIPForceNativeFCP360FisheyeConformEffect(id target, NSInteger sphericalMode) {
    if (!target) {
        return @{@"status": @"skipped"};
    }

    NSMutableDictionary *result = [@{
        @"status": @"ok",
        @"targetClass": NSStringFromClass([target class]) ?: @"",
        @"sphericalMode": @(sphericalMode),
    } mutableCopy];

    if (sphericalMode == 1) {
        result[@"hideHE360Transform"] = @(SKIPShowAndEnable360EffectIfSupported(target, @"HE360Transform", NO, NO));
        result[@"hideHEOrientation"] = @(SKIPShowAndEnable360EffectIfSupported(target, @"HEOrientation", NO, NO));
        result[@"hideHEReorient"] = @(SKIPShowAndEnable360EffectIfSupported(target, @"HEReorient", NO, NO));
        result[@"inputAlreadyEquirect"] = @YES;
        result[@"effects"] = SKIPNativeFCP360EffectSnapshot(target);
        return [result copy];
    }

    if (sphericalMode != 2 && sphericalMode != 3) {
        result[@"status"] = @"skipped";
        result[@"effects"] = SKIPNativeFCP360EffectSnapshot(target);
        return [result copy];
    }

    BOOL isGenerator = SKIPBoolFromSelector(target, NSSelectorFromString(@"isGenerator"), NO);
    result[@"showHE360Transform"] = @(SKIPShowAndEnable360EffectIfSupported(target, @"HE360Transform", YES, !isGenerator));
    result[@"hideHEOrientation"] = @(SKIPShowAndEnable360EffectIfSupported(target, @"HEOrientation", NO, NO));
    result[@"hideHEReorient"] = @(SKIPShowAndEnable360EffectIfSupported(target, @"HEReorient", NO, NO));

    id effectStack = SKIPObjectIfSupported(target, @"videoEffects");
    id transform = SKIPIntrinsicEffectIfSupported(effectStack, @"HE360Transform", YES);
    if (transform && [transform respondsToSelector:NSSelectorFromString(@"updateConvergenceAndInteraxial")]) {
        @try {
            ((void (*)(id, SEL))objc_msgSend)(transform, NSSelectorFromString(@"updateConvergenceAndInteraxial"));
            result[@"updatedConvergenceAndInteraxial"] = @YES;
        } @catch (NSException *exception) {
            result[@"updatedConvergenceAndInteraxial"] = @NO;
            result[@"updateError"] = exception.reason ?: exception.name ?: @"unknown error";
        }
    }

    result[@"effects"] = SKIPNativeFCP360EffectSnapshot(target);
    return [result copy];
}

static NSInteger SKIPNativeFCP360SphericalModeForImmersiveBRAW(NSDictionary *clipSummary) {
    NSDictionary *immersive = [clipSummary[@"immersive"] isKindOfClass:[NSDictionary class]]
        ? clipSummary[@"immersive"]
        : nil;
    NSDictionary *attributes = [immersive[@"attributes"] isKindOfClass:[NSDictionary class]]
        ? immersive[@"attributes"]
        : nil;
    NSString *projection = SKIPStringOrEmpty(immersive[@"opticalProjectionKind"]).lowercaseString;
    if (projection.length == 0) {
        projection = SKIPStringOrEmpty(attributes[@"opticalProjectionKind"]).lowercaseString;
    }

    // The BRAW VT decoder hands FCP per-eye fisheye pixels unchanged. Tag the
    // frame with the matching FFSphericalMode so HE360Transform unwraps it
    // natively — no host-side remap required.
    if ([projection containsString:@"dual"]) return 3;       // FFSphericalMode_DualFisheye
    if ([projection containsString:@"equirect"]) return 1;   // FFSphericalMode_Equirectangular
    if ([projection containsString:@"cube"]) return 4;       // FFSphericalMode_CubeMap
    if ([projection containsString:@"fisheye"]) return 2;    // FFSphericalMode_Fisheye
    return 3;                                                // default: URSA Immersive / AIV dual-fisheye
}

static NSInteger SKIPNativeFCP360HeroEyeForImmersiveBRAW(NSDictionary *clipSummary) {
    NSDictionary *immersive = [clipSummary[@"immersive"] isKindOfClass:[NSDictionary class]]
        ? clipSummary[@"immersive"]
        : nil;
    NSString *heroEye = SKIPStringOrEmpty(immersive[@"heroEye"]).lowercaseString;
    if ([heroEye isEqualToString:@"left"]) return 1;   // FFHeroEye_Left
    if ([heroEye isEqualToString:@"right"]) return 2;  // FFHeroEye_Right

    NSNumber *heroEyeIndex = [immersive[@"heroEyeIndex"] respondsToSelector:@selector(integerValue)]
        ? immersive[@"heroEyeIndex"]
        : nil;
    if (heroEyeIndex) return heroEyeIndex.integerValue == 0 ? 1 : 2;
    return 0; // FFHeroEye_NoPreference
}

static void SKIPForceSequenceFormatRefresh(id sequence) {
    if (!sequence) return;
    SEL forceSel = NSSelectorFromString(@"forcePlayerContextChangeForSequence");
    if ([sequence respondsToSelector:forceSel]) {
        @try {
            ((void (*)(id, SEL))objc_msgSend)(sequence, forceSel);
        } @catch (NSException *exception) {
            SpliceKit_log(@"[ImmersivePreview] forcePlayerContextChangeForSequence failed: %@",
                          exception.reason ?: exception.name);
        }
    }
}

static BOOL SKIPApplySequenceCameraProjectionMode(id sequence,
                                                  NSInteger targetCameraMode,
                                                  BOOL *outChanged,
                                                  NSError **error) {
    if (outChanged) *outChanged = NO;
    if (!sequence || ![sequence respondsToSelector:@selector(videoProps)]) {
        if (error) *error = SKIPImmersivePreviewError(-34, @"Could not find the active FCP project sequence");
        return NO;
    }

    id currentVideoProps = ((id (*)(id, SEL))objc_msgSend)(sequence, @selector(videoProps));
    NSInteger currentCameraMode = SKIPCameraModeForVideoProps(currentVideoProps);
    if (currentCameraMode == targetCameraMode) {
        return YES;
    }

    SEL copyProjectionSel = NSSelectorFromString(@"copyPropsWithCameraProjectionMode:adjustPaspForEquirect:");
    if (!currentVideoProps || ![currentVideoProps respondsToSelector:copyProjectionSel]) {
        if (error) *error = SKIPImmersivePreviewError(-36, @"FCP sequence video properties cannot be converted to a native 360 projection");
        return NO;
    }

    // adjustPaspForEquirect:YES produces a 2:1 production aperture that FCP's
    // 360 viewer needs to wrap content around a full sphere. Passing NO leaves
    // the aperture square and the viewer pans a flat panel instead of orbiting.
    CFTypeRef copiedVideoProps = ((CFTypeRef (*)(id, SEL, NSInteger, BOOL))objc_msgSend)(currentVideoProps,
                                                                                         copyProjectionSel,
                                                                                         targetCameraMode,
                                                                                         YES);
    id newVideoProps = (__bridge_transfer id)copiedVideoProps;
    if (!newVideoProps) {
        if (error) *error = SKIPImmersivePreviewError(-36, @"FCP failed to create native 360 sequence video properties");
        return NO;
    }

    @try {
        ((void (*)(id, SEL, id))objc_msgSend)(sequence, NSSelectorFromString(@"setVideoProps:"), newVideoProps);
        SKIPForceSequenceFormatRefresh(sequence);
        if (outChanged) *outChanged = YES;
        return YES;
    } @catch (NSException *exception) {
        if (error) {
            *error = SKIPImmersivePreviewError(-37,
                                               exception.reason ?: @"FCP rejected the native 360 sequence video properties");
        }
        return NO;
    }
}

static void SKIPCaptureIntegerState(NSMutableDictionary *state,
                                    id target,
                                    NSString *targetKey,
                                    NSString *valueKey,
                                    NSString *getterName) {
    if (!state || !target || targetKey.length == 0 || valueKey.length == 0) return;
    NSNumber *value = SKIPIntegerIfSupported(target, getterName);
    if (value) {
        state[targetKey] = target;
        state[valueKey] = value;
    }
}

static NSDictionary *SKIPCaptureNativeFCP360RestoreState(NSString *resolvedPath, NSError **error) {
    if (![NSThread isMainThread]) {
        __block NSDictionary *result = nil;
        __block NSError *mainError = nil;
        SpliceKit_executeOnMainThread(^{
            result = SKIPCaptureNativeFCP360RestoreState(resolvedPath, &mainError);
        });
        if (!result && error) *error = mainError;
        return result;
    }

    id timeline = SKIPActiveTimelineModuleForPreview();
    id sequence = (timeline && [timeline respondsToSelector:@selector(sequence)])
        ? ((id (*)(id, SEL))objc_msgSend)(timeline, @selector(sequence))
        : nil;
    if (!sequence || ![sequence respondsToSelector:@selector(videoProps)]) {
        if (error) *error = SKIPImmersivePreviewError(-38, @"Could not capture the active FCP project projection state");
        return nil;
    }

    NSMutableDictionary *state = [@{
        @"path": resolvedPath ?: @"",
        @"sequence": sequence,
        @"sequenceVideoProps": ((id (*)(id, SEL))objc_msgSend)(sequence, @selector(videoProps)) ?: [NSNull null],
    } mutableCopy];

    id sequenceVideoProps = state[@"sequenceVideoProps"];
    if (sequenceVideoProps && sequenceVideoProps != (id)[NSNull null]) {
        state[@"sequenceCameraMode"] = @(SKIPCameraModeForVideoProps(sequenceVideoProps));
    }

    id primaryObject = SKIPObjectIfSupported(sequence, @"primaryObject");
    if (primaryObject) {
        state[@"primaryObject"] = primaryObject;
        id primaryVideoProps = SKIPObjectIfSupported(primaryObject, @"videoProps");
        if (primaryVideoProps) state[@"primaryVideoProps"] = primaryVideoProps;
        SKIPCaptureIntegerState(state, primaryObject, @"primaryObject", @"primarySphericalProjectionMode", @"sphericalProjectionMode");
        SKIPCaptureIntegerState(state, primaryObject, @"primaryObject", @"primaryStereoscopicMode", @"stereoscopicMode");
        SKIPCaptureIntegerState(state, primaryObject, @"primaryObject", @"primaryHeroEye", @"heroEye");
    }

    id timelineItem = SKIPTimelineClipNearPlayhead();
    if (timelineItem) {
        NSURL *mediaURL = SKIPDirectMediaURLForClipObject(timelineItem);
        NSString *timelinePath = mediaURL.path.stringByStandardizingPath ?: @"";
        NSString *resolvedTimelinePath = timelinePath.length > 0
            ? (SpliceKitBRAWResolveOriginalPathForPublic(timelinePath) ?: timelinePath)
            : @"";
        resolvedTimelinePath = resolvedTimelinePath.length > 0
            ? [[NSURL fileURLWithPath:resolvedTimelinePath] URLByResolvingSymlinksInPath].path.stringByStandardizingPath
            : @"";
        if (resolvedPath.length > 0 &&
            resolvedTimelinePath.length > 0 &&
            ![resolvedTimelinePath isEqualToString:resolvedPath]) {
            if (error) *error = SKIPImmersivePreviewError(-39, @"The active timeline clip no longer matches the selected immersive BRAW file");
            return nil;
        }

        state[@"timelineItem"] = timelineItem;
        state[@"timelinePath"] = timelinePath ?: @"";
        SKIPCaptureIntegerState(state, timelineItem, @"timelineItem", @"clipSphericalProjectionMode", @"sphericalProjectionMode");
        SKIPCaptureIntegerState(state, timelineItem, @"timelineItem", @"clipStereoscopicMode", @"stereoscopicMode");
        SKIPCaptureIntegerState(state, timelineItem, @"timelineItem", @"clipHeroEye", @"heroEye");
    }

    return [state copy];
}

static NSDictionary *SKIPRestoreNativeFCP360State(NSDictionary *state, NSString *reason) {
    if (state.count == 0) return @{};
    if (![NSThread isMainThread]) {
        __block NSDictionary *result = nil;
        SpliceKit_executeOnMainThread(^{
            result = SKIPRestoreNativeFCP360State(state, reason);
        });
        return result ?: @{};
    }

    NSMutableDictionary *result = [@{
        @"status": @"ok",
        @"reason": reason ?: @"",
    } mutableCopy];

    id timelineItem = state[@"timelineItem"];
    if (timelineItem && timelineItem != (id)[NSNull null]) {
        NSNumber *spherical = state[@"clipSphericalProjectionMode"];
        NSNumber *stereo = state[@"clipStereoscopicMode"];
        NSNumber *heroEye = state[@"clipHeroEye"];
        if (spherical) SKIPSetIntegerIfSupported(timelineItem, @"setSphericalProjectionMode:", spherical.integerValue);
        if (stereo) SKIPSetIntegerIfSupported(timelineItem, @"setStereoscopicMode:", stereo.integerValue);
        if (heroEye) SKIPSetIntegerIfSupported(timelineItem, @"setHeroEye:", heroEye.integerValue);
        result[@"clipRestored"] = @YES;
    }

    id primaryObject = state[@"primaryObject"];
    if (primaryObject && primaryObject != (id)[NSNull null]) {
        NSNumber *spherical = state[@"primarySphericalProjectionMode"];
        NSNumber *stereo = state[@"primaryStereoscopicMode"];
        NSNumber *heroEye = state[@"primaryHeroEye"];
        if (spherical) SKIPSetIntegerIfSupported(primaryObject, @"setSphericalProjectionMode:", spherical.integerValue);
        if (stereo) SKIPSetIntegerIfSupported(primaryObject, @"setStereoscopicMode:", stereo.integerValue);
        if (heroEye) SKIPSetIntegerIfSupported(primaryObject, @"setHeroEye:", heroEye.integerValue);

        id primaryVideoProps = state[@"primaryVideoProps"];
        if (primaryVideoProps && primaryVideoProps != (id)[NSNull null]) {
            SKIPSetObjectIfSupported(primaryObject, @"setVideoProps:", primaryVideoProps);
        }
        result[@"primaryRestored"] = @YES;
    }

    id sequence = state[@"sequence"];
    id sequenceVideoProps = state[@"sequenceVideoProps"];
    if (sequence && sequence != (id)[NSNull null] &&
        sequenceVideoProps && sequenceVideoProps != (id)[NSNull null]) {
        if (SKIPSetObjectIfSupported(sequence, @"setVideoProps:", sequenceVideoProps)) {
            result[@"sequenceRestored"] = @YES;
            result[@"sequenceCameraMode"] = @(SKIPCameraModeForVideoProps(sequenceVideoProps));
        }
        SKIPForceSequenceFormatRefresh(sequence);
    }

    return [result copy];
}

static NSDictionary *SKIPNormalizeNativeFCP360PlayerModules(NSDictionary *clipSummary) {
    if (![NSThread isMainThread]) {
        __block NSDictionary *result = nil;
        SpliceKit_executeOnMainThread(^{
            result = SKIPNormalizeNativeFCP360PlayerModules(clipSummary);
        });
        return result ?: @{};
    }

    NSInteger width = [clipSummary[@"width"] respondsToSelector:@selector(integerValue)] ? [clipSummary[@"width"] integerValue] : 0;
    NSInteger height = [clipSummary[@"height"] respondsToSelector:@selector(integerValue)] ? [clipSummary[@"height"] integerValue] : 0;
    if (width <= 0 || height <= 0) return @{};

    id playerContainer = SKIPActivePlayerContainerModuleForPreview();
    SEL playerModulesSel = NSSelectorFromString(@"playerModules");
    if (!playerContainer || ![playerContainer respondsToSelector:playerModulesSel]) return @{};

    id playerModules = nil;
    @try {
        playerModules = ((id (*)(id, SEL))objc_msgSend)(playerContainer, playerModulesSel);
    } @catch (__unused NSException *exception) {
        return @{};
    }
    if (![playerModules isKindOfClass:[NSArray class]]) return @{};

    NSMutableArray *players = [NSMutableArray array];
    CGRect rectangularBounds = CGRectMake(0.0, 0.0, (CGFloat)width, (CGFloat)height);
    SEL videoModuleSel = NSSelectorFromString(@"videoModule");
    SEL is360ViewerSel = NSSelectorFromString(@"is360Viewer");
    SEL sequenceCameraModeSel = NSSelectorFromString(@"sequenceCameraMode");
    SEL setSequenceCameraModeSel = NSSelectorFromString(@"setSequenceCameraMode:");
    SEL setSequenceBoundsSel = NSSelectorFromString(@"setSequenceBounds:");
    SEL sequenceFormatChangedSel = NSSelectorFromString(@"_sequenceFormatChanged:");
    SEL playerViewBoundsSel = NSSelectorFromString(@"playerViewBounds");
    SEL playerViewSel = NSSelectorFromString(@"playerView");
    SEL performPlayerUpdateForOSCSel = NSSelectorFromString(@"performPlayerUpdateForOSC");

    for (id playerModule in (NSArray *)playerModules) {
        NSMutableDictionary *entry = [@{
            @"playerClass": NSStringFromClass([playerModule class]) ?: @"",
        } mutableCopy];

        @try {
            id videoModule = ([playerModule respondsToSelector:videoModuleSel])
                ? ((id (*)(id, SEL))objc_msgSend)(playerModule, videoModuleSel)
                : nil;
            if (!videoModule) {
                entry[@"status"] = @"noVideoModule";
                [players addObject:entry];
                continue;
            }

            BOOL is360Viewer = [videoModule respondsToSelector:is360ViewerSel]
                ? ((BOOL (*)(id, SEL))objc_msgSend)(videoModule, is360ViewerSel)
                : NO;
            entry[@"videoClass"] = NSStringFromClass([videoModule class]) ?: @"";
            entry[@"is360Viewer"] = @(is360Viewer);

            if ([videoModule respondsToSelector:setSequenceCameraModeSel]) {
                int cameraMode = is360Viewer ? 1 : 0;
                ((void (*)(id, SEL, int))objc_msgSend)(videoModule, setSequenceCameraModeSel, cameraMode);
                entry[@"targetCameraMode"] = @(cameraMode);
            }

            if ([videoModule respondsToSelector:setSequenceBoundsSel]) {
                CGRect targetBounds = rectangularBounds;
                if (is360Viewer) {
                    BOOL haveViewportBounds = NO;
                    if ([videoModule respondsToSelector:playerViewBoundsSel]) {
                        @try {
                            targetBounds = ((CGRect (*)(id, SEL))SKIP_STRET_MSG)(videoModule, playerViewBoundsSel);
                            haveViewportBounds = targetBounds.size.width > 1.0 && targetBounds.size.height > 1.0;
                        } @catch (__unused NSException *exception) {
                            haveViewportBounds = NO;
                        }
                    }
                    if (!haveViewportBounds) {
                        id playerView = ([videoModule respondsToSelector:playerViewSel])
                            ? ((id (*)(id, SEL))objc_msgSend)(videoModule, playerViewSel)
                            : nil;
                        if ([playerView isKindOfClass:[NSView class]]) {
                            targetBounds = [(NSView *)playerView bounds];
                            haveViewportBounds = targetBounds.size.width > 1.0 && targetBounds.size.height > 1.0;
                        }
                    }
                    if (!haveViewportBounds) {
                        targetBounds = CGRectMake(0.0, 0.0, 1920.0, 1080.0);
                    }
                }

                ((void (*)(id, SEL, CGRect))objc_msgSend)(videoModule, setSequenceBoundsSel, targetBounds);
                entry[@"targetSequenceBounds"] = @{
                    @"x": @(targetBounds.origin.x),
                    @"y": @(targetBounds.origin.y),
                    @"width": @(targetBounds.size.width),
                    @"height": @(targetBounds.size.height),
                };
            }

            if ([videoModule respondsToSelector:sequenceFormatChangedSel]) {
                ((void (*)(id, SEL, id))objc_msgSend)(videoModule, sequenceFormatChangedSel, nil);
            }
            if (is360Viewer && [videoModule respondsToSelector:performPlayerUpdateForOSCSel]) {
                ((void (*)(id, SEL))objc_msgSend)(videoModule, performPlayerUpdateForOSCSel);
            }

            if ([videoModule respondsToSelector:sequenceCameraModeSel]) {
                int finalCameraMode = ((int (*)(id, SEL))objc_msgSend)(videoModule, sequenceCameraModeSel);
                entry[@"sequenceCameraMode"] = @(finalCameraMode);
            }
            entry[@"status"] = @"ok";
        } @catch (NSException *exception) {
            entry[@"status"] = @"error";
            entry[@"error"] = exception.reason ?: exception.name ?: @"unknown error";
        }

        [players addObject:entry];
    }

    return @{
        @"status": @"ok",
        @"rectangularWidth": @(width),
        @"rectangularHeight": @(height),
        @"players": players,
    };
}

static NSDictionary *SKIPPrepareNativeFCP360ForImmersiveBRAW(NSString *resolvedPath,
                                                            NSDictionary *clipSummary,
                                                            NSError **error) {
    if (![NSThread isMainThread]) {
        __block NSDictionary *result = nil;
        __block NSError *mainError = nil;
        SpliceKit_executeOnMainThread(^{
            result = SKIPPrepareNativeFCP360ForImmersiveBRAW(resolvedPath, clipSummary, &mainError);
        });
        if (!result && error) *error = mainError;
        return result;
    }

    NSDictionary *immersive = [clipSummary[@"immersive"] isKindOfClass:[NSDictionary class]]
        ? clipSummary[@"immersive"]
        : nil;
    BOOL immersiveAvailable = [immersive[@"available"] respondsToSelector:@selector(boolValue)]
        ? [immersive[@"available"] boolValue]
        : NO;
    if (!immersiveAvailable) {
        if (error) {
            *error = SKIPImmersivePreviewError(-33,
                                               @"Selected BRAW is not immersive; leaving normal BRAW viewer settings unchanged");
        }
        return nil;
    }

    id timeline = SKIPActiveTimelineModuleForPreview();
    id sequence = (timeline && [timeline respondsToSelector:@selector(sequence)])
        ? ((id (*)(id, SEL))objc_msgSend)(timeline, @selector(sequence))
        : nil;
    if (!sequence || ![sequence respondsToSelector:@selector(videoProps)]) {
        if (error) *error = SKIPImmersivePreviewError(-34, @"Could not find the active FCP project sequence");
        return nil;
    }

    id oldVideoProps = ((id (*)(id, SEL))objc_msgSend)(sequence, @selector(videoProps));
    NSInteger oldCameraMode = SKIPCameraModeForVideoProps(oldVideoProps);
    BOOL frameProjectionPatchInstalled = SKIPNativeFCP360ProjectionPatchIsInstalled();
    BOOL sequenceChanged = NO;
    BOOL changedThisStep = NO;
    NSError *projectionError = nil;
    NSInteger clipSphericalMode = SKIPNativeFCP360SphericalModeForImmersiveBRAW(clipSummary);
    NSInteger clipHeroEyeMode = SKIPNativeFCP360HeroEyeForImmersiveBRAW(clipSummary);
    // Sequence stays in equirect (the 360 viewer's output space); HE360Transform
    // bridges the clip's real projection (e.g. DualFisheye) into equirect so the
    // 360 viewer can project it. Setting the sequence itself to DualFisheye gets
    // silently rejected by FCP and leaves the 360 pipeline with nothing to render.
    NSInteger targetCameraMode = 1;
    sSKIPNativeFCP360CameraModeOverrideValue.store(1, std::memory_order_release);

    if (!SKIPApplySequenceCameraProjectionMode(sequence, targetCameraMode, &changedThisStep, &projectionError)) {
        if (error) *error = projectionError;
        return nil;
    }
    sequenceChanged = sequenceChanged || changedThisStep;

    id primaryObject = SKIPObjectIfSupported(sequence, @"primaryObject");
    if (primaryObject) {
        SKIPSetIntegerIfSupported(primaryObject, @"setSphericalProjectionMode:", clipSphericalMode);
        SKIPSetIntegerIfSupported(primaryObject, @"setStereoscopicMode:", 0);
        SKIPSetIntegerIfSupported(primaryObject, @"setHeroEye:", clipHeroEyeMode);
    }

    NSString *timelinePath = @"";
    id timelineItem = SKIPTimelineClipNearPlayhead();
    NSDictionary *forcedConformStatus = nil;
    if (timelineItem) {
        NSURL *mediaURL = SKIPDirectMediaURLForClipObject(timelineItem);
        timelinePath = mediaURL.path.stringByStandardizingPath ?: @"";
        NSString *resolvedTimelinePath = timelinePath.length > 0
            ? (SpliceKitBRAWResolveOriginalPathForPublic(timelinePath) ?: timelinePath)
            : @"";
        resolvedTimelinePath = resolvedTimelinePath.length > 0
            ? [[NSURL fileURLWithPath:resolvedTimelinePath] URLByResolvingSymlinksInPath].path.stringByStandardizingPath
            : @"";
        if (resolvedPath.length > 0 &&
            resolvedTimelinePath.length > 0 &&
            ![resolvedTimelinePath isEqualToString:resolvedPath]) {
            if (error) *error = SKIPImmersivePreviewError(-35, @"The active timeline clip no longer matches the selected immersive BRAW file");
            return nil;
        }

        SKIPSetIntegerIfSupported(timelineItem, @"setSphericalProjectionMode:", clipSphericalMode);
        SKIPSetIntegerIfSupported(timelineItem, @"setStereoscopicMode:", 0);
        SKIPSetIntegerIfSupported(timelineItem, @"setHeroEye:", clipHeroEyeMode);
        forcedConformStatus = SKIPForceNativeFCP360FisheyeConformEffect(timelineItem, clipSphericalMode);
    }

    NSString *sequenceDescription = @"";

    projectionError = nil;
    changedThisStep = NO;
    if (!SKIPApplySequenceCameraProjectionMode(sequence, targetCameraMode, &changedThisStep, &projectionError)) {
        if (error) *error = projectionError;
        return nil;
    }
    sequenceChanged = sequenceChanged || changedThisStep;

    id finalVideoProps = ((id (*)(id, SEL))objc_msgSend)(sequence, @selector(videoProps));
    NSInteger finalCameraMode = SKIPCameraModeForVideoProps(finalVideoProps);
    SEL propDescSel = NSSelectorFromString(@"_propertyDescription");
    if ([finalVideoProps respondsToSelector:propDescSel]) {
        id desc = ((id (*)(id, SEL))objc_msgSend)(finalVideoProps, propDescSel);
        if ([desc isKindOfClass:[NSString class]]) sequenceDescription = desc;
    }

    NSMutableDictionary *status = [@{
        @"status": @"ok",
        @"path": resolvedPath ?: @"",
        @"timelinePath": timelinePath ?: @"",
        @"immersiveAvailable": @YES,
        @"oldSequenceCameraMode": @(oldCameraMode),
        @"sequenceCameraMode": @(finalCameraMode),
        @"targetCameraMode": @(targetCameraMode),
        @"sequenceChanged": @(sequenceChanged),
        @"frameProjectionPatch": @(frameProjectionPatchInstalled),
        @"targetClipSphericalProjectionMode": @(clipSphericalMode),
        @"targetClipHeroEye": @(clipHeroEyeMode),
        @"forcedFisheyeConform": forcedConformStatus ?: @{},
        @"sequenceVideoProps": sequenceDescription ?: @"",
    } mutableCopy];

    if (primaryObject) {
        NSNumber *primarySpherical = SKIPIntegerIfSupported(primaryObject, @"sphericalProjectionMode");
        NSNumber *primaryStereo = SKIPIntegerIfSupported(primaryObject, @"stereoscopicMode");
        NSNumber *primaryHero = SKIPIntegerIfSupported(primaryObject, @"heroEye");
        if (primarySpherical) status[@"primarySphericalProjectionMode"] = primarySpherical;
        if (primaryStereo) status[@"primaryStereoscopicMode"] = primaryStereo;
        if (primaryHero) status[@"primaryHeroEye"] = primaryHero;
    }

    if (timelineItem) {
        SEL sphericalSel = NSSelectorFromString(@"sphericalProjectionMode");
        if ([timelineItem respondsToSelector:sphericalSel]) {
            NSInteger spherical = ((NSInteger (*)(id, SEL))objc_msgSend)(timelineItem, sphericalSel);
            status[@"clipSphericalProjectionMode"] = @(spherical);
        }
        SEL stereoSel = NSSelectorFromString(@"stereoscopicMode");
        if ([timelineItem respondsToSelector:stereoSel]) {
            NSInteger stereo = ((NSInteger (*)(id, SEL))objc_msgSend)(timelineItem, stereoSel);
            status[@"clipStereoscopicMode"] = @(stereo);
        }
        SEL heroEyeSel = NSSelectorFromString(@"heroEye");
        if ([timelineItem respondsToSelector:heroEyeSel]) {
            NSInteger heroEye = ((NSInteger (*)(id, SEL))objc_msgSend)(timelineItem, heroEyeSel);
            status[@"clipHeroEye"] = @(heroEye);
        }
    }

    return [status copy];
}

@interface SKIPInteractiveImageView : MTKView <MTKViewDelegate>
@property (nonatomic, copy) void (^dragHandler)(NSPoint delta, BOOL ended);
@property (nonatomic, copy) void (^scrollHandler)(CGFloat deltaY);
@property (nonatomic) NSPoint lastDragPoint;
@property (nonatomic) BOOL dragging;
@property (nonatomic, strong) NSImage *image;
@property (nonatomic, readonly) BOOL rendererReady;
- (void)syncFromBackend;
- (void)clearRenderer;
- (void)waitForInFlightRendering;
- (NSDictionary *)rendererPerformanceSnapshot;
- (void)resetRendererPerformanceCounters;
@end

@interface SpliceKitImmersivePreviewPanel (ImmersiveViewerBridgePrivate)
@property (nonatomic, readonly, copy) NSString *selectedPath;
@property (nonatomic, readonly, strong) NSImage *lastRenderedImage;
@property (nonatomic, readonly, strong) NSDictionary *lastRenderedSnapshot;
- (void)setupPanelIfNeeded;
- (void)setMessage:(NSString *)message;
- (NSString *)currentEyeMode;
- (NSString *)currentViewMode;
- (NSDictionary *)metalRenderStateSnapshot;
- (NSDictionary *)performanceSnapshot;
- (void)logPerformanceIfNeeded;
- (void)previewDraggedByDelta:(NSPoint)delta ended:(BOOL)ended;
- (void)previewScrolledByDeltaY:(CGFloat)deltaY;
- (void)updateTimelineSyncTimer;
@end

static NSView *SKIPFindLargestPlayerView(void) {
    Class playerViewClass = objc_getClass("FFPlayerView");
    if (!playerViewClass) return nil;

    NSWindow *mainWindow = NSApp.mainWindow;
    if (!mainWindow) {
        for (NSWindow *window in NSApp.windows) {
            if (!window.isVisible || !window.contentView) continue;
            if (!mainWindow || (window.frame.size.width * window.frame.size.height >
                                mainWindow.frame.size.width * mainWindow.frame.size.height)) {
                mainWindow = window;
            }
        }
    }
    if (!mainWindow.contentView) return nil;

    NSView *largestPlayerView = nil;
    CGFloat largestArea = 0.0;
    NSMutableArray<NSView *> *queue = [NSMutableArray arrayWithObject:mainWindow.contentView];
    while (queue.count > 0) {
        NSView *view = queue.firstObject;
        [queue removeObjectAtIndex:0];
        if (!view) continue;
        if ([view isKindOfClass:playerViewClass]) {
            CGFloat area = view.bounds.size.width * view.bounds.size.height;
            if (area > largestArea) {
                largestArea = area;
                largestPlayerView = view;
            }
        }
        NSArray<NSView *> *subviews = view.subviews;
        if (subviews.count > 0) [queue addObjectsFromArray:subviews];
    }
    return largestPlayerView;
}

@interface SKIPImmersiveViewerOverlayHost : NSObject
@property (nonatomic, weak) NSView *attachedPlayerView;
@property (nonatomic, strong) NSView *overlayView;
@property (nonatomic, strong) NSArray<NSLayoutConstraint *> *overlayConstraints;
@property (nonatomic, strong) SKIPInteractiveImageView *previewView;
@property (nonatomic, strong) NSTextField *badgeLabel;
@property (nonatomic, strong) NSButton *closeButton;
- (BOOL)isVisible;
- (void)hide;
- (BOOL)showForCurrentSelection:(NSError **)error;
- (BOOL)showLoadedClip:(NSError **)error;
- (NSDictionary *)rendererPerformanceSnapshot;
@end

@implementation SKIPImmersiveViewerOverlayHost

+ (instancetype)sharedHost {
    static SKIPImmersiveViewerOverlayHost *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [[self alloc] init]; });
    return instance;
}

- (BOOL)isVisible {
    return self.overlayView.superview != nil;
}

- (void)hide {
    if (![NSThread isMainThread]) {
        SpliceKit_executeOnMainThread(^{ [self hide]; });
        return;
    }

    [NSLayoutConstraint deactivateConstraints:self.overlayConstraints ?: @[]];
    self.overlayConstraints = nil;
    [self.previewView waitForInFlightRendering];
    [self.previewView clearRenderer];
    [self.overlayView removeFromSuperview];
    self.attachedPlayerView = nil;
    [[SpliceKitImmersivePreviewPanel sharedPanel] updateTimelineSyncTimer];
}

- (void)closeClicked:(id)sender {
    [self hide];
}

- (void)ensureOverlayAttachedToPlayerView:(NSView *)playerView {
    if (!playerView) return;
    if (self.overlayView.superview == playerView) return;

    [NSLayoutConstraint deactivateConstraints:self.overlayConstraints ?: @[]];
    self.overlayConstraints = nil;
    [self.overlayView removeFromSuperview];
    self.attachedPlayerView = playerView;

    if (!self.overlayView) {
        NSView *overlayView = [[NSView alloc] initWithFrame:NSZeroRect];
        overlayView.translatesAutoresizingMaskIntoConstraints = NO;
        overlayView.wantsLayer = YES;
        overlayView.layer.backgroundColor = NSColor.blackColor.CGColor;
        overlayView.layer.cornerRadius = 6.0;
        overlayView.layer.masksToBounds = YES;
        self.overlayView = overlayView;

        SKIPInteractiveImageView *previewView = [[SKIPInteractiveImageView alloc] initWithFrame:NSZeroRect];
        previewView.translatesAutoresizingMaskIntoConstraints = NO;
        __weak SKIPImmersiveViewerOverlayHost *weakSelf = self;
        previewView.dragHandler = ^(NSPoint delta, BOOL ended) {
            (void)weakSelf;
            SpliceKitImmersivePreviewPanel *backend = [SpliceKitImmersivePreviewPanel sharedPanel];
            [backend previewDraggedByDelta:delta ended:ended];
        };
        previewView.scrollHandler = ^(CGFloat deltaY) {
            (void)weakSelf;
            SpliceKitImmersivePreviewPanel *backend = [SpliceKitImmersivePreviewPanel sharedPanel];
            [backend previewScrolledByDeltaY:deltaY];
        };
        previewView.toolTip = @"Drag to look around. Scroll to change field of view.";
        self.previewView = previewView;
        [overlayView addSubview:previewView];

        NSTextField *badgeLabel = [NSTextField labelWithString:@"SpliceKit Immersive Viewer"];
        badgeLabel.translatesAutoresizingMaskIntoConstraints = NO;
        badgeLabel.font = [NSFont boldSystemFontOfSize:12.0];
        badgeLabel.textColor = NSColor.whiteColor;
        badgeLabel.drawsBackground = YES;
        badgeLabel.backgroundColor = [NSColor colorWithWhite:0.0 alpha:0.55];
        badgeLabel.bordered = NO;
        badgeLabel.bezeled = NO;
        self.badgeLabel = badgeLabel;
        [overlayView addSubview:badgeLabel];

        NSButton *closeButton = [NSButton buttonWithTitle:@"Close"
                                                   target:self
                                                   action:@selector(closeClicked:)];
        closeButton.translatesAutoresizingMaskIntoConstraints = NO;
        closeButton.bezelStyle = NSBezelStyleRounded;
        self.closeButton = closeButton;
        [overlayView addSubview:closeButton];

        [NSLayoutConstraint activateConstraints:@[
            [previewView.topAnchor constraintEqualToAnchor:overlayView.topAnchor],
            [previewView.leadingAnchor constraintEqualToAnchor:overlayView.leadingAnchor],
            [previewView.trailingAnchor constraintEqualToAnchor:overlayView.trailingAnchor],
            [previewView.bottomAnchor constraintEqualToAnchor:overlayView.bottomAnchor],

            [badgeLabel.topAnchor constraintEqualToAnchor:overlayView.topAnchor constant:12.0],
            [badgeLabel.leadingAnchor constraintEqualToAnchor:overlayView.leadingAnchor constant:12.0],

            [closeButton.topAnchor constraintEqualToAnchor:overlayView.topAnchor constant:8.0],
            [closeButton.trailingAnchor constraintEqualToAnchor:overlayView.trailingAnchor constant:-8.0],
        ]];
    }

    [playerView addSubview:self.overlayView positioned:NSWindowAbove relativeTo:nil];
    self.overlayConstraints = @[
        [self.overlayView.topAnchor constraintEqualToAnchor:playerView.topAnchor],
        [self.overlayView.leadingAnchor constraintEqualToAnchor:playerView.leadingAnchor],
        [self.overlayView.trailingAnchor constraintEqualToAnchor:playerView.trailingAnchor],
        [self.overlayView.bottomAnchor constraintEqualToAnchor:playerView.bottomAnchor],
    ];
    [NSLayoutConstraint activateConstraints:self.overlayConstraints];
}

- (void)syncImageFromBackend {
    if (![NSThread isMainThread]) {
        SpliceKit_executeOnMainThread(^{ [self syncImageFromBackend]; });
        return;
    }

    SpliceKitImmersivePreviewPanel *backend = [SpliceKitImmersivePreviewPanel sharedPanel];
    if (self.previewView.rendererReady) {
        [self.previewView syncFromBackend];
    } else {
        self.previewView.image = backend.lastRenderedImage;
    }

    NSDictionary *snapshot = backend.lastRenderedSnapshot ?: [backend statusSnapshot];
    NSString *path = [snapshot[@"path"] isKindOfClass:[NSString class]] ? snapshot[@"path"] : @"";
    NSString *eyeMode = [snapshot[@"eyeMode"] isKindOfClass:[NSString class]] ? snapshot[@"eyeMode"] : @"hero";
    NSString *viewMode = [snapshot[@"viewMode"] isKindOfClass:[NSString class]] ? snapshot[@"viewMode"] : @"viewport";
    NSNumber *frameIndex = [snapshot[@"frameIndex"] respondsToSelector:@selector(integerValue)] ? snapshot[@"frameIndex"] : @0;
    self.badgeLabel.stringValue = [NSString stringWithFormat:@"SpliceKit Immersive | %@ | %@ | frame %@%@",
                                   eyeMode,
                                   viewMode,
                                   frameIndex,
                                   path.lastPathComponent.length > 0 ? [NSString stringWithFormat:@" | %@", path.lastPathComponent] : @""];
}

- (NSDictionary *)rendererPerformanceSnapshot {
    return [self.previewView rendererPerformanceSnapshot] ?: @{};
}

- (BOOL)showForCurrentSelection:(NSError **)error {
    if (![NSThread isMainThread]) {
        __block BOOL ok = NO;
        __block NSError *mainError = nil;
        SpliceKit_executeOnMainThread(^{
            ok = [self showForCurrentSelection:&mainError];
        });
        if (!ok && error) *error = mainError;
        return ok;
    }

    SpliceKitImmersivePreviewPanel *backend = [SpliceKitImmersivePreviewPanel sharedPanel];
    NSString *selectedPath = SKIPResolveFirstPathFromSelection();
    if (selectedPath.length == 0) {
        if (error) *error = SKIPImmersivePreviewError(-31, @"No immersive BRAW clip is selected near the playhead");
        return NO;
    }

    NSView *playerView = SKIPFindLargestPlayerView();
    if (!playerView) {
        if (error) *error = SKIPImmersivePreviewError(-30, @"Could not find the active FCP viewer");
        return NO;
    }

    [backend setupPanelIfNeeded];
    [self ensureOverlayAttachedToPlayerView:playerView];
    [backend updateTimelineSyncTimer];
    [backend setMessage:@"Loading immersive viewer..."];

    __weak SKIPImmersiveViewerOverlayHost *weakSelf = self;
    void (^finishShow)(BOOL, NSError *) = ^(BOOL ok, NSError *loadError) {
        SKIPImmersiveViewerOverlayHost *strongSelf = weakSelf;
        if (!strongSelf) return;

        if (!ok) {
            [backend setMessage:loadError.localizedDescription ?: @"Failed to load immersive viewer clip."];
            return;
        }
        if (![[backend currentViewMode] isEqualToString:@"viewport"]) {
            [backend setViewModeIdentifier:@"viewport"];
        }
        if ([backend currentEyeMode].length == 0) {
            [backend setEyeModeIdentifier:@"hero"];
        }

        NSError *refreshError = nil;
        BOOL refreshOK = [backend requestPreviewRenderInteractive:NO error:&refreshError];
        [backend setMessage:refreshOK ? @"" : (refreshError.localizedDescription ?: @"Unable to refresh immersive viewer.")];
        [strongSelf syncImageFromBackend];
    };

    if (![backend.selectedPath isEqualToString:selectedPath]) {
        [backend loadClipAtPathAsync:selectedPath completion:finishShow];
        return YES;
    }

    finishShow(YES, nil);
    return YES;
}

- (BOOL)showLoadedClip:(NSError **)error {
    if (![NSThread isMainThread]) {
        __block BOOL ok = NO;
        __block NSError *mainError = nil;
        SpliceKit_executeOnMainThread(^{
            ok = [self showLoadedClip:&mainError];
        });
        if (!ok && error) *error = mainError;
        return ok;
    }

    SpliceKitImmersivePreviewPanel *backend = [SpliceKitImmersivePreviewPanel sharedPanel];
    if (backend.selectedPath.length == 0) {
        if (error) *error = SKIPImmersivePreviewError(-32, @"No immersive BRAW clip is loaded");
        return NO;
    }

    NSView *playerView = SKIPFindLargestPlayerView();
    if (!playerView) {
        if (error) *error = SKIPImmersivePreviewError(-30, @"Could not find the active FCP viewer");
        return NO;
    }

    [backend setupPanelIfNeeded];
    [self ensureOverlayAttachedToPlayerView:playerView];
    [backend updateTimelineSyncTimer];
    [backend setMessage:@"Loading immersive viewer..."];

    NSError *renderError = nil;
    BOOL renderOK = [backend requestPreviewRenderInteractive:NO error:&renderError];
    if (!renderOK) {
        [backend setMessage:renderError.localizedDescription ?: @"Failed to render immersive viewer clip."];
        if (error) *error = renderError;
        return NO;
    }

    [self syncImageFromBackend];
    [backend setMessage:@"Immersive viewer ready"];
    return YES;
}

@end

@interface SKIPInteractiveImageView ()
@property (nonatomic, weak) SpliceKitImmersivePreviewPanel *backend;
@property (nonatomic, strong) id<MTLCommandQueue> renderCommandQueue;
@property (nonatomic, strong) id<MTLSamplerState> samplerState;
@property (nonatomic, strong) id<MTLRenderPipelineState> pipelineState;
@property (nonatomic, strong) id<MTLTexture> leftTexture;
@property (nonatomic, strong) id<MTLTexture> rightTexture;
@property (nonatomic, strong) id<MTLCommandBuffer> inFlightCommandBuffer;
@property (nonatomic, strong) NSData *uploadedLeftData;
@property (nonatomic, strong) NSData *uploadedRightData;
@property (nonatomic, strong) NSImageView *cpuFallbackView;
@property (nonatomic) size_t uploadedWidth;
@property (nonatomic) size_t uploadedHeight;
@property (nonatomic) SKIPImmersivePreviewMetalUniforms uniforms;
@property (nonatomic) BOOL rendererReady;
@property (nonatomic) uint64_t syncRequestCount;
@property (nonatomic) uint64_t textureUploadCount;
@property (nonatomic) NSUInteger uploadedByteCount;
@property (nonatomic) double lastTextureUploadMs;
@property (nonatomic) double totalTextureUploadMs;
@property (nonatomic) double maxTextureUploadMs;
@property (nonatomic) uint64_t drawCount;
@property (nonatomic) double lastDrawDurationMs;
@property (nonatomic) double totalDrawDurationMs;
@property (nonatomic) double maxDrawDurationMs;
@property (nonatomic) CFTimeInterval lastDrawTimestamp;
@property (nonatomic) double lastDrawIntervalMs;
@property (nonatomic) double totalDrawIntervalMs;
@property (nonatomic) double maxDrawIntervalMs;
@property (nonatomic) uint64_t drawIntervalSamples;
@property (nonatomic) double rollingDrawFPS;
@property (nonatomic) CFTimeInterval rollingWindowStart;
@property (nonatomic) uint64_t rollingWindowDrawCount;
@property (nonatomic) uint64_t pendingRenderToken;
@property (nonatomic) CFTimeInterval pendingRenderRequestedAt;
@property (nonatomic) uint64_t lastPresentedRenderToken;
@property (nonatomic) double lastRequestLatencyMs;
@property (nonatomic) double totalRequestLatencyMs;
@property (nonatomic) double maxRequestLatencyMs;
@property (nonatomic) uint64_t requestLatencySamples;
@end

@implementation SKIPInteractiveImageView

- (instancetype)initWithFrame:(NSRect)frameRect {
    id<MTLDevice> device = SKIPImmersivePreviewMetalDevice();
    self = [super initWithFrame:frameRect device:device];
    if (!self) return nil;

    self.backend = [SpliceKitImmersivePreviewPanel sharedPanel];
    self.enableSetNeedsDisplay = YES;
    self.paused = YES;
    self.framebufferOnly = NO;
    self.clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
    self.colorPixelFormat = MTLPixelFormatBGRA8Unorm;
    self.delegate = self;
    self.preferredFramesPerSecond = 60;

    if (device) {
        self.renderCommandQueue = [device newCommandQueue];
        self.pipelineState = SKIPImmersivePreviewPipelineState(device);
        self.samplerState = SKIPImmersivePreviewSamplerState(device);
        self.rendererReady = (self.renderCommandQueue != nil &&
                              self.pipelineState != nil &&
                              self.samplerState != nil);
    } else {
        self.rendererReady = NO;
    }

    NSImageView *cpuFallbackView = [[NSImageView alloc] initWithFrame:NSZeroRect];
    cpuFallbackView.translatesAutoresizingMaskIntoConstraints = NO;
    cpuFallbackView.imageScaling = NSImageScaleProportionallyUpOrDown;
    cpuFallbackView.wantsLayer = YES;
    cpuFallbackView.layer.backgroundColor = NSColor.blackColor.CGColor;
    cpuFallbackView.hidden = self.rendererReady;
    self.cpuFallbackView = cpuFallbackView;
    [self addSubview:cpuFallbackView];
    [NSLayoutConstraint activateConstraints:@[
        [cpuFallbackView.topAnchor constraintEqualToAnchor:self.topAnchor],
        [cpuFallbackView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [cpuFallbackView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [cpuFallbackView.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
    ]];

    [self resetRendererPerformanceCounters];
    return self;
}

- (BOOL)acceptsFirstResponder {
    return YES;
}

- (void)clearRenderer {
    [self waitForInFlightRendering];
    self.leftTexture = nil;
    self.rightTexture = nil;
    self.uploadedLeftData = nil;
    self.uploadedRightData = nil;
    self.cpuFallbackView.image = nil;
    self.uploadedWidth = 0;
    self.uploadedHeight = 0;
    [self setNeedsDisplay:YES];
}

- (void)waitForInFlightRendering {
    id<MTLCommandBuffer> commandBuffer = self.inFlightCommandBuffer;
    if (!commandBuffer) return;
    if (commandBuffer.status < MTLCommandBufferStatusCompleted) {
        [commandBuffer waitUntilCompleted];
    }
    self.inFlightCommandBuffer = nil;
}

- (void)resetRendererPerformanceCounters {
    self.syncRequestCount = 0;
    self.textureUploadCount = 0;
    self.uploadedByteCount = 0;
    self.lastTextureUploadMs = 0.0;
    self.totalTextureUploadMs = 0.0;
    self.maxTextureUploadMs = 0.0;
    self.drawCount = 0;
    self.lastDrawDurationMs = 0.0;
    self.totalDrawDurationMs = 0.0;
    self.maxDrawDurationMs = 0.0;
    self.lastDrawTimestamp = 0.0;
    self.lastDrawIntervalMs = 0.0;
    self.totalDrawIntervalMs = 0.0;
    self.maxDrawIntervalMs = 0.0;
    self.drawIntervalSamples = 0;
    self.rollingDrawFPS = 0.0;
    self.rollingWindowStart = 0.0;
    self.rollingWindowDrawCount = 0;
    self.pendingRenderToken = 0;
    self.pendingRenderRequestedAt = 0.0;
    self.lastPresentedRenderToken = 0;
    self.lastRequestLatencyMs = 0.0;
    self.totalRequestLatencyMs = 0.0;
    self.maxRequestLatencyMs = 0.0;
    self.requestLatencySamples = 0;
}

- (NSDictionary *)rendererPerformanceSnapshot {
    double avgDrawMs = self.drawCount > 0 ? (self.totalDrawDurationMs / (double)self.drawCount) : 0.0;
    double avgUploadMs = self.textureUploadCount > 0 ? (self.totalTextureUploadMs / (double)self.textureUploadCount) : 0.0;
    double avgDrawIntervalMs = self.drawIntervalSamples > 0 ? (self.totalDrawIntervalMs / (double)self.drawIntervalSamples) : 0.0;
    double avgLatencyMs = self.requestLatencySamples > 0 ? (self.totalRequestLatencyMs / (double)self.requestLatencySamples) : 0.0;
    CGSize drawableSize = self.drawableSize;
    return @{
        @"renderer": self.rendererReady ? @"metal" : @"cpu_fallback",
        @"rendererReady": @(self.rendererReady),
        @"deviceAvailable": @(self.device != nil),
        @"commandQueueReady": @(self.renderCommandQueue != nil),
        @"pipelineReady": @(self.pipelineState != nil),
        @"pipelineError": sSKIPImmersivePreviewMetalPipelineError ?: @"",
        @"samplerReady": @(self.samplerState != nil),
        @"layerClass": NSStringFromClass([self.layer class]) ?: @"",
        @"drawableWidth": @(drawableSize.width),
        @"drawableHeight": @(drawableSize.height),
        @"syncRequests": @(self.syncRequestCount),
        @"textureUploads": @(self.textureUploadCount),
        @"uploadedBytes": @(self.uploadedByteCount),
        @"lastTextureUploadMs": @(self.lastTextureUploadMs),
        @"avgTextureUploadMs": @(avgUploadMs),
        @"maxTextureUploadMs": @(self.maxTextureUploadMs),
        @"drawCount": @(self.drawCount),
        @"lastDrawMs": @(self.lastDrawDurationMs),
        @"avgDrawMs": @(avgDrawMs),
        @"maxDrawMs": @(self.maxDrawDurationMs),
        @"lastDrawIntervalMs": @(self.lastDrawIntervalMs),
        @"avgDrawIntervalMs": @(avgDrawIntervalMs),
        @"maxDrawIntervalMs": @(self.maxDrawIntervalMs),
        @"recentDrawFPS": @(self.rollingDrawFPS),
        @"lastRequestLatencyMs": @(self.lastRequestLatencyMs),
        @"avgRequestLatencyMs": @(avgLatencyMs),
        @"maxRequestLatencyMs": @(self.maxRequestLatencyMs),
    };
}

- (void)setImage:(NSImage *)image {
    _image = image;
    if (self.rendererReady) return;
    self.cpuFallbackView.hidden = NO;
    self.cpuFallbackView.image = image;
}

- (id<MTLTexture>)newTextureForWidth:(size_t)width height:(size_t)height {
    if (!self.device || width == 0 || height == 0) return nil;
    MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                           width:width
                                                                                          height:height
                                                                                       mipmapped:NO];
    descriptor.usage = MTLTextureUsageShaderRead;
    descriptor.storageMode = MTLStorageModeManaged;
    return [self.device newTextureWithDescriptor:descriptor];
}

- (void)uploadTextureIfNeeded:(id<MTLTexture> __strong *)texturePtr
                         data:(NSData *)data
                        width:(size_t)width
                       height:(size_t)height {
    if (!texturePtr || !data || width == 0 || height == 0) return;
    if (width > SIZE_MAX / 4 || height > SIZE_MAX / (width * 4)) {
        SpliceKit_log(@"[ImmersivePreview] Refusing texture upload with overflow dimensions %zux%zu", width, height);
        return;
    }
    NSUInteger bytesPerRow = (NSUInteger)width * 4;
    NSUInteger requiredBytes = bytesPerRow * (NSUInteger)height;
    if (data.length < requiredBytes) {
        SpliceKit_log(@"[ImmersivePreview] Refusing short texture upload %lu < %lu for %zux%zu",
                      (unsigned long)data.length,
                      (unsigned long)requiredBytes,
                      width,
                      height);
        return;
    }
    id<MTLTexture> texture = *texturePtr;
    if (!texture || texture.width != width || texture.height != height) {
        texture = [self newTextureForWidth:width height:height];
        *texturePtr = texture;
    }
    if (!texture) return;

    MTLRegion region = MTLRegionMake2D(0, 0, width, height);
    [texture replaceRegion:region mipmapLevel:0 withBytes:data.bytes bytesPerRow:bytesPerRow];
}

- (void)syncFromBackend {
    if (![NSThread isMainThread]) {
        SpliceKit_executeOnMainThread(^{ [self syncFromBackend]; });
        return;
    }
    if (!self.rendererReady || !self.backend) return;

    self.syncRequestCount += 1;
    NSDictionary *state = [self.backend metalRenderStateSnapshot];
    NSData *leftData = [state[@"leftData"] isKindOfClass:[NSData class]] ? state[@"leftData"] : nil;
    NSData *rightData = [state[@"rightData"] isKindOfClass:[NSData class]] ? state[@"rightData"] : nil;
    size_t width = [state[@"decodedWidth"] respondsToSelector:@selector(unsignedIntegerValue)] ? [state[@"decodedWidth"] unsignedIntegerValue] : 0;
    size_t height = [state[@"decodedHeight"] respondsToSelector:@selector(unsignedIntegerValue)] ? [state[@"decodedHeight"] unsignedIntegerValue] : 0;

    if (!leftData || !rightData || width == 0 || height == 0) {
        [self clearRenderer];
        return;
    }

    BOOL needsTextureUpload = (self.uploadedLeftData != leftData ||
                               self.uploadedRightData != rightData ||
                               self.uploadedWidth != width ||
                               self.uploadedHeight != height);
    if (needsTextureUpload) {
        CFTimeInterval uploadStart = SKIPNow();
        [self uploadTextureIfNeeded:&_leftTexture data:leftData width:width height:height];
        [self uploadTextureIfNeeded:&_rightTexture data:rightData width:width height:height];
        double uploadMs = (SKIPNow() - uploadStart) * 1000.0;
        self.textureUploadCount += 1;
        self.lastTextureUploadMs = uploadMs;
        self.totalTextureUploadMs += uploadMs;
        self.maxTextureUploadMs = MAX(self.maxTextureUploadMs, uploadMs);
        self.uploadedByteCount += (leftData.length + rightData.length);
        self.uploadedLeftData = leftData;
        self.uploadedRightData = rightData;
        self.uploadedWidth = width;
        self.uploadedHeight = height;
    }

    NSString *eyeModeIdentifier = [state[@"eyeMode"] isKindOfClass:[NSString class]] ? state[@"eyeMode"] : @"hero";
    NSString *viewModeIdentifier = [state[@"viewMode"] isKindOfClass:[NSString class]] ? state[@"viewMode"] : @"viewport";

    SKIPImmersivePreviewMetalUniforms uniforms = {0};
    CGSize drawableSize = self.drawableSize;
    uniforms.drawableWidth = (uint32_t)MAX(1.0, drawableSize.width);
    uniforms.drawableHeight = (uint32_t)MAX(1.0, drawableSize.height);
    uniforms.sourceWidth = (uint32_t)width;
    uniforms.sourceHeight = (uint32_t)height;
    uniforms.heroEyeIndex = [state[@"heroEyeIndex"] respondsToSelector:@selector(unsignedIntValue)] ? [state[@"heroEyeIndex"] unsignedIntValue] : 1;
    uniforms.yawRadians = ((float)[state[@"yaw"] doubleValue]) * (float)M_PI / 180.0f;
    uniforms.pitchRadians = ((float)[state[@"pitch"] doubleValue]) * (float)M_PI / 180.0f;
    uniforms.fovRadians = ((float)[state[@"fov"] doubleValue]) * (float)M_PI / 180.0f;
    uniforms.gapFraction = 0.02f;
    if ([eyeModeIdentifier isEqualToString:@"left"]) {
        uniforms.eyeMode = SKIPImmersivePreviewEyeModeLeft;
    } else if ([eyeModeIdentifier isEqualToString:@"right"]) {
        uniforms.eyeMode = SKIPImmersivePreviewEyeModeRight;
    } else if ([eyeModeIdentifier isEqualToString:@"stereo"]) {
        uniforms.eyeMode = SKIPImmersivePreviewEyeModeStereo;
    } else {
        uniforms.eyeMode = SKIPImmersivePreviewEyeModeHero;
    }
    if ([viewModeIdentifier isEqualToString:@"lens"]) {
        uniforms.viewMode = SKIPImmersivePreviewViewModeLens;
    } else if ([viewModeIdentifier isEqualToString:@"latlong"]) {
        uniforms.viewMode = SKIPImmersivePreviewViewModeLatLong;
    } else {
        uniforms.viewMode = SKIPImmersivePreviewViewModeViewport;
    }
    self.uniforms = uniforms;
    self.pendingRenderToken = [state[@"renderRequestToken"] respondsToSelector:@selector(unsignedLongLongValue)] ? [state[@"renderRequestToken"] unsignedLongLongValue] : 0;
    self.pendingRenderRequestedAt = [state[@"renderRequestedAt"] respondsToSelector:@selector(doubleValue)] ? [state[@"renderRequestedAt"] doubleValue] : 0.0;
    [self setNeedsDisplay:YES];
    [self draw];
    [self.backend logPerformanceIfNeeded];
}

- (void)mouseDown:(NSEvent *)event {
    self.dragging = YES;
    self.lastDragPoint = [self convertPoint:event.locationInWindow fromView:nil];
    [self.window makeFirstResponder:self];
}

- (void)mouseDragged:(NSEvent *)event {
    if (!self.dragging) {
        [super mouseDragged:event];
        return;
    }
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    NSPoint delta = NSMakePoint(point.x - self.lastDragPoint.x, point.y - self.lastDragPoint.y);
    self.lastDragPoint = point;
    if (self.dragHandler) self.dragHandler(delta, NO);
}

- (void)mouseUp:(NSEvent *)event {
    if (self.dragging && self.dragHandler) self.dragHandler(NSZeroPoint, YES);
    self.dragging = NO;
    [super mouseUp:event];
}

- (void)scrollWheel:(NSEvent *)event {
    if (self.scrollHandler) {
        self.scrollHandler(event.scrollingDeltaY);
        return;
    }
    [super scrollWheel:event];
}

- (void)drawInMTKView:(MTKView *)view {
    if (!self.rendererReady || !self.leftTexture || !self.rightTexture) return;
    CFTimeInterval drawStart = SKIPNow();
    id<CAMetalDrawable> drawable = view.currentDrawable;
    if (!drawable) return;

    MTLRenderPassDescriptor *passDescriptor = view.currentRenderPassDescriptor;
    if (!passDescriptor) return;

    id<MTLCommandBuffer> commandBuffer = [self.renderCommandQueue commandBuffer];
    if (!commandBuffer) return;

    id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:passDescriptor];
    if (!encoder) return;

    [encoder setRenderPipelineState:self.pipelineState];
    [encoder setFragmentBytes:&_uniforms length:sizeof(_uniforms) atIndex:0];
    [encoder setFragmentTexture:self.leftTexture atIndex:0];
    [encoder setFragmentTexture:self.rightTexture atIndex:1];
    [encoder setFragmentSamplerState:self.samplerState atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
    [encoder endEncoding];

    [commandBuffer presentDrawable:drawable];
    self.inFlightCommandBuffer = commandBuffer;
    __weak SKIPInteractiveImageView *weakSelf = self;
    [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> completedBuffer) {
        dispatch_async(dispatch_get_main_queue(), ^{
            SKIPInteractiveImageView *strongSelf = weakSelf;
            if (strongSelf.inFlightCommandBuffer == completedBuffer) {
                strongSelf.inFlightCommandBuffer = nil;
            }
        });
    }];
    [commandBuffer commit];

    CFTimeInterval drawEnd = SKIPNow();
    double drawMs = (drawEnd - drawStart) * 1000.0;
    self.drawCount += 1;
    self.lastDrawDurationMs = drawMs;
    self.totalDrawDurationMs += drawMs;
    self.maxDrawDurationMs = MAX(self.maxDrawDurationMs, drawMs);

    if (self.lastDrawTimestamp > 0.0) {
        double intervalMs = (drawStart - self.lastDrawTimestamp) * 1000.0;
        self.lastDrawIntervalMs = intervalMs;
        self.totalDrawIntervalMs += intervalMs;
        self.maxDrawIntervalMs = MAX(self.maxDrawIntervalMs, intervalMs);
        self.drawIntervalSamples += 1;
    }
    self.lastDrawTimestamp = drawStart;

    if (self.rollingWindowStart <= 0.0 || (drawStart - self.rollingWindowStart) >= 1.0) {
        double windowDuration = MAX(drawStart - self.rollingWindowStart, 0.001);
        self.rollingDrawFPS = self.rollingWindowStart > 0.0
            ? ((double)self.rollingWindowDrawCount / windowDuration)
            : 1.0;
        self.rollingWindowStart = drawStart;
        self.rollingWindowDrawCount = 1;
    } else {
        self.rollingWindowDrawCount += 1;
        self.rollingDrawFPS = (double)self.rollingWindowDrawCount / MAX(drawStart - self.rollingWindowStart, 0.001);
    }

    if (self.pendingRenderToken > 0 && self.pendingRenderToken != self.lastPresentedRenderToken) {
        self.lastPresentedRenderToken = self.pendingRenderToken;
        if (self.pendingRenderRequestedAt > 0.0) {
            double latencyMs = (drawStart - self.pendingRenderRequestedAt) * 1000.0;
            self.lastRequestLatencyMs = latencyMs;
            self.totalRequestLatencyMs += latencyMs;
            self.maxRequestLatencyMs = MAX(self.maxRequestLatencyMs, latencyMs);
            self.requestLatencySamples += 1;
        }
    }

    [self.backend logPerformanceIfNeeded];
}

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {
    [self setNeedsDisplay:YES];
}

@end

@interface SpliceKitImmersivePreviewPanel () <NSWindowDelegate, NSTextFieldDelegate>
@property (nonatomic, strong) NSPanel *panel;
@property (nonatomic, strong) SKIPInteractiveImageView *imageView;
@property (nonatomic, strong) NSTextField *pathField;
@property (nonatomic, strong) NSTextField *statusLabel;
@property (nonatomic, strong) NSTextField *infoLabel;
@property (nonatomic, strong) NSTextField *messageLabel;
@property (nonatomic, strong) NSPopUpButton *eyePopup;
@property (nonatomic, strong) NSPopUpButton *viewPopup;
@property (nonatomic, strong) NSPopUpButton *scalePopup;
@property (nonatomic, strong) NSSlider *frameSlider;
@property (nonatomic, strong) NSTextField *frameField;
@property (nonatomic, strong) NSSlider *yawSlider;
@property (nonatomic, strong) NSSlider *pitchSlider;
@property (nonatomic, strong) NSSlider *fovSlider;
@property (nonatomic, strong) NSTextField *yawValueLabel;
@property (nonatomic, strong) NSTextField *pitchValueLabel;
@property (nonatomic, strong) NSTextField *fovValueLabel;

@property (nonatomic, copy) NSString *selectedPath;
@property (nonatomic, strong) NSDictionary *clipSummary;
@property (nonatomic, strong) NSData *leftDecodedData;
@property (nonatomic, strong) NSData *rightDecodedData;
@property (nonatomic) size_t decodedWidth;
@property (nonatomic) size_t decodedHeight;
@property (nonatomic) uint32_t cachedFrameIndex;
@property (nonatomic) uint32_t cachedScaleHint;
@property (nonatomic, copy) NSString *cachedPath;
@property (nonatomic) BOOL suppressViewportRefresh;
@property (nonatomic, strong) dispatch_queue_t renderQueue;
@property (nonatomic, strong) dispatch_queue_t metadataQueue;
@property (nonatomic) uint64_t renderGeneration;
@property (nonatomic) BOOL renderWorkerRunning;
@property (nonatomic, strong) NSDictionary *pendingRenderRequest;
@property (nonatomic, strong) NSImage *lastRenderedImage;
@property (nonatomic, strong) NSDictionary *lastRenderedSnapshot;
@property (nonatomic, strong) NSTimer *timelineSyncTimer;
@property (nonatomic, strong) NSDictionary *lastTimelineSyncSnapshot;
@property (nonatomic, strong) NSDictionary *lastNativeViewerStatus;
@property (nonatomic, strong) NSDictionary *nativeViewerRestoreState;
@property (nonatomic) uint64_t previewRequestCount;
@property (nonatomic) uint64_t interactivePreviewRequestCount;
@property (nonatomic) CFTimeInterval lastPreviewRequestTimestamp;
@property (nonatomic) double lastPreviewRequestIntervalMs;
@property (nonatomic) double totalPreviewRequestIntervalMs;
@property (nonatomic) double maxPreviewRequestIntervalMs;
@property (nonatomic) uint64_t previewRequestIntervalSamples;
@property (nonatomic) double rollingRequestFPS;
@property (nonatomic) CFTimeInterval rollingRequestWindowStart;
@property (nonatomic) uint64_t rollingRequestWindowCount;
@property (nonatomic) uint64_t decodeCount;
@property (nonatomic) uint64_t decodeCacheHitCount;
@property (nonatomic) double lastDecodeMs;
@property (nonatomic) double totalDecodeMs;
@property (nonatomic) double maxDecodeMs;
@property (nonatomic) double lastLeftEyeDecodeMs;
@property (nonatomic) double lastRightEyeDecodeMs;
@property (nonatomic) double totalLeftEyeDecodeMs;
@property (nonatomic) double totalRightEyeDecodeMs;
@property (nonatomic) uint64_t cpuRenderCount;
@property (nonatomic) double lastCpuRenderMs;
@property (nonatomic) double totalCpuRenderMs;
@property (nonatomic) double maxCpuRenderMs;
@property (nonatomic) CFTimeInterval lastCpuRenderTimestamp;
@property (nonatomic) double lastCpuRenderIntervalMs;
@property (nonatomic) double totalCpuRenderIntervalMs;
@property (nonatomic) double maxCpuRenderIntervalMs;
@property (nonatomic) uint64_t cpuRenderIntervalSamples;
@property (nonatomic) double rollingCpuRenderFPS;
@property (nonatomic) CFTimeInterval rollingCpuRenderWindowStart;
@property (nonatomic) uint64_t rollingCpuRenderWindowCount;
@property (nonatomic) double lastCpuRequestLatencyMs;
@property (nonatomic) double totalCpuRequestLatencyMs;
@property (nonatomic) double maxCpuRequestLatencyMs;
@property (nonatomic) uint64_t cpuRequestLatencySamples;
@property (nonatomic) uint64_t perfRenderRequestToken;
@property (nonatomic) CFTimeInterval perfRenderRequestedAt;
@property (nonatomic) CFTimeInterval lastPerfLogTimestamp;

- (uint64_t)bumpRenderGeneration;
- (BOOL)isRenderGenerationCurrent:(uint64_t)generation;
- (uint32_t)currentFrameIndex;
- (NSString *)currentEyeMode;
- (NSString *)currentViewMode;
- (uint32_t)currentScaleHint;
- (NSInteger)currentHeroEyeIndex;
- (void)invalidateDecodeCache;
- (BOOL)applyLoadedClipSummary:(NSDictionary *)clipSummary
                       forPath:(NSString *)path
                         error:(NSError **)error;
- (BOOL)requestPreviewRenderInteractive:(BOOL)interactive error:(NSError **)error;
- (void)scheduleAsyncPreviewRenderInteractive:(BOOL)interactive;
- (void)drainScheduledPreviewRenders;
- (void)scheduleSettledFullQualityRenderFromGeneration:(uint64_t)generation;
- (void)previewDraggedByDelta:(NSPoint)delta ended:(BOOL)ended;
- (void)previewScrolledByDeltaY:(CGFloat)deltaY;
- (void)notePreviewRequestInteractive:(BOOL)interactive;
- (void)noteDecodeCacheHit;
- (void)noteDecodeDurationMs:(double)decodeMs leftEyeMs:(double)leftEyeMs rightEyeMs:(double)rightEyeMs;
- (void)noteCPURenderDurationMs:(double)renderMs requestLatencyMs:(double)requestLatencyMs;
- (NSDictionary *)timelineSyncSnapshot;
- (BOOL)syncFrameIndexToTimelinePlayheadAndReturnChange:(BOOL *)outChanged error:(NSError **)error;
- (void)timelineSyncTimerFired:(NSTimer *)timer;
- (void)refreshUIState;
@end

@implementation SpliceKitImmersivePreviewPanel

+ (instancetype)sharedPanel {
    static SpliceKitImmersivePreviewPanel *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [[self alloc] init]; });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _selectedPath = @"";
    _cachedPath = @"";
    _renderQueue = dispatch_queue_create("com.splicekit.immersivepreview.render", DISPATCH_QUEUE_SERIAL);
    _metadataQueue = dispatch_queue_create("com.splicekit.immersivepreview.metadata", DISPATCH_QUEUE_SERIAL);
    [self resetPerformanceCounters];
    return self;
}

- (void)dealloc {
    SKIPSetNativeFCP360ProjectionPatchEnabled(NO);
    [self.timelineSyncTimer invalidate];
    NSDictionary *restoreState = self.nativeViewerRestoreState;
    if (restoreState) {
        SKIPRestoreNativeFCP360State(restoreState, @"dealloc");
    }
}

- (uint64_t)bumpRenderGeneration {
    @synchronized (self) {
        self.renderGeneration += 1;
        return self.renderGeneration;
    }
}

- (BOOL)isRenderGenerationCurrent:(uint64_t)generation {
    @synchronized (self) {
        return generation == self.renderGeneration;
    }
}

- (BOOL)isVisible {
    return self.panel && self.panel.isVisible;
}

- (void)showPanel {
    if (![NSThread isMainThread]) {
        SpliceKit_executeOnMainThread(^{ [self showPanel]; });
        return;
    }
    [self setupPanelIfNeeded];
    [self refreshUIState];
    [self.panel makeKeyAndOrderFront:nil];
    [self updateTimelineSyncTimer];
}

- (void)hidePanel {
    if (![NSThread isMainThread]) {
        SpliceKit_executeOnMainThread(^{ [self hidePanel]; });
        return;
    }
    [self.timelineSyncTimer invalidate];
    self.timelineSyncTimer = nil;
    if (!self.isViewerVisible) {
        [self invalidateDecodeCache];
        [self.imageView clearRenderer];
    }
    [self.panel orderOut:nil];
    [self updateTimelineSyncTimer];
}

- (void)togglePanel {
    if (self.isVisible) [self hidePanel];
    else [self showPanel];
}

- (BOOL)showInViewerForCurrentSelection:(NSError **)error {
    if (![NSThread isMainThread]) {
        __block BOOL ok = NO;
        __block NSError *mainError = nil;
        SpliceKit_executeOnMainThread(^{
            ok = [self showInViewerForCurrentSelection:&mainError];
        });
        if (!ok && error) *error = mainError;
        return ok;
    }

    __block NSString *selectedPath = nil;
    selectedPath = SKIPResolveFirstPathFromSelection();

    NSString *resolvedPath = selectedPath.length > 0
        ? (SpliceKitBRAWResolveOriginalPathForPublic(selectedPath) ?: selectedPath)
        : @"";
    if (![[resolvedPath.pathExtension lowercaseString] isEqualToString:@"braw"]) {
        if (error) {
            *error = SKIPImmersivePreviewError(-31, @"No BRAW clip is selected near the playhead for FCP's native 360 viewer");
        }
        return NO;
    }

    NSError *describeError = nil;
    NSDictionary *clip = SKIPDescribeImmersiveClipAtPath(resolvedPath, &describeError);
    if (!clip) {
        if (error) *error = describeError ?: SKIPImmersivePreviewError(-32, @"Unable to describe the selected BRAW clip");
        return NO;
    }

    if (self.nativeViewerRestoreState) {
        SKIPSetNativeFCP360ProjectionPatchEnabled(NO);
        NSDictionary *restoreStatus = SKIPRestoreNativeFCP360State(self.nativeViewerRestoreState, @"replace");
        NSMutableDictionary *priorStatus = [self.lastNativeViewerStatus mutableCopy] ?: [NSMutableDictionary dictionary];
        priorStatus[@"restore"] = restoreStatus ?: @{};
        self.lastNativeViewerStatus = [priorStatus copy];
        self.nativeViewerRestoreState = nil;
    }

    NSError *captureError = nil;
    NSDictionary *restoreState = SKIPCaptureNativeFCP360RestoreState(resolvedPath, &captureError);
    if (!restoreState) {
        if (error) *error = captureError ?: SKIPImmersivePreviewError(-38, @"Unable to capture FCP's current viewer projection state");
        return NO;
    }

    SKIPInstallNativeFCP360ProjectionPatch();
    BOOL frameProjectionPatchInstalled = SKIPNativeFCP360ProjectionPatchIsInstalled();
    SKIPSetNativeFCP360ProjectionPatchEnabled(frameProjectionPatchInstalled);

    NSError *prepareError = nil;
    NSDictionary *nativeStatus = SKIPPrepareNativeFCP360ForImmersiveBRAW(resolvedPath, clip, &prepareError);
    if (!nativeStatus) {
        SKIPSetNativeFCP360ProjectionPatchEnabled(NO);
        SKIPRestoreNativeFCP360State(restoreState, @"prepareFailed");
        if (error) *error = prepareError ?: SKIPImmersivePreviewError(-34, @"Unable to prepare FCP's native 360 viewer for the selected BRAW clip");
        return NO;
    }

    self.selectedPath = resolvedPath;
    self.clipSummary = clip;
    self.nativeViewerRestoreState = restoreState;
    self.lastNativeViewerStatus = nativeStatus;

    BOOL opened = SKIPOpenNativeFCP360Viewer(YES, error);
    if (!opened) {
        SKIPSetNativeFCP360ProjectionPatchEnabled(NO);
        SKIPRestoreNativeFCP360State(restoreState, @"openFailed");
        self.nativeViewerRestoreState = nil;
        return NO;
    }

    NSMutableDictionary *updatedStatus = [nativeStatus mutableCopy];
    updatedStatus[@"playerOverrides"] = SKIPNormalizeNativeFCP360PlayerModules(clip);
    updatedStatus[@"restoreStateCaptured"] = @YES;
    updatedStatus[@"frameProjectionPatchActive"] = @(frameProjectionPatchInstalled);
    updatedStatus[@"visible"] = @(SKIPNativeFCP360ViewerIsVisible());
    self.lastNativeViewerStatus = [updatedStatus copy];
    return YES;
}

- (BOOL)showLoadedInViewer:(NSError **)error {
    if (error) {
        *error = SKIPImmersivePreviewError(-41, @"FCP's native 360 viewer requires a selected timeline/browser clip; loadPath is decode diagnostics only");
    }
    return NO;
}

- (void)hideInViewer {
    [[SKIPImmersiveViewerOverlayHost sharedHost] hide];
    SKIPCloseNativeFCP360Viewer();
    SKIPSetNativeFCP360ProjectionPatchEnabled(NO);
    NSDictionary *restoreState = self.nativeViewerRestoreState;
    if (restoreState) {
        NSDictionary *restoreStatus = SKIPRestoreNativeFCP360State(restoreState, @"hide");
        NSMutableDictionary *updatedStatus = [self.lastNativeViewerStatus mutableCopy] ?: [NSMutableDictionary dictionary];
        updatedStatus[@"restore"] = restoreStatus ?: @{};
        updatedStatus[@"visible"] = @(SKIPNativeFCP360ViewerIsVisible());
        self.lastNativeViewerStatus = [updatedStatus copy];
        self.nativeViewerRestoreState = nil;
    }
    if (!self.isVisible) {
        [self invalidateDecodeCache];
    }
}

- (BOOL)isViewerVisible {
    if (![NSThread isMainThread]) {
        __block BOOL visible = NO;
        SpliceKit_executeOnMainThread(^{
            visible = [self isViewerVisible];
        });
        return visible;
    }
    return [SKIPImmersiveViewerOverlayHost sharedHost].isVisible || SKIPNativeFCP360ViewerIsVisible();
}

- (void)setupPanelIfNeeded {
    if (self.panel) return;

    NSRect screenFrame = NSScreen.mainScreen.visibleFrame;
    NSRect frame = NSMakeRect(NSMidX(screenFrame) - 520.0, NSMidY(screenFrame) - 380.0, 1040.0, 760.0);
    self.panel = [[NSPanel alloc] initWithContentRect:frame
                                            styleMask:(NSWindowStyleMaskTitled |
                                                       NSWindowStyleMaskClosable |
                                                       NSWindowStyleMaskResizable |
                                                       NSWindowStyleMaskUtilityWindow)
                                              backing:NSBackingStoreBuffered
                                                defer:NO];
    self.panel.title = @"Immersive Preview";
    self.panel.floatingPanel = YES;
    self.panel.level = NSFloatingWindowLevel;
    self.panel.hidesOnDeactivate = NO;
    self.panel.releasedWhenClosed = NO;
    self.panel.minSize = NSMakeSize(900.0, 680.0);
    self.panel.delegate = self;
    self.panel.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    self.panel.collectionBehavior = NSWindowCollectionBehaviorFullScreenAuxiliary |
                                    NSWindowCollectionBehaviorCanJoinAllSpaces;

    NSView *content = self.panel.contentView;
    CGFloat p = 12.0;

    self.statusLabel = [NSTextField labelWithString:@"No immersive BRAW loaded"];
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusLabel.font = [NSFont boldSystemFontOfSize:13];
    [content addSubview:self.statusLabel];

    self.pathField = [NSTextField textFieldWithString:@""];
    self.pathField.translatesAutoresizingMaskIntoConstraints = NO;
    self.pathField.placeholderString = @"Paste a .braw path or use Load Selected";
    self.pathField.delegate = self;
    [content addSubview:self.pathField];

    NSButton *loadSelectedButton = [NSButton buttonWithTitle:@"Load Selected"
                                                      target:self
                                                      action:@selector(loadSelectedClicked:)];
    loadSelectedButton.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:loadSelectedButton];

    NSButton *loadPathButton = [NSButton buttonWithTitle:@"Load Path"
                                                  target:self
                                                  action:@selector(loadPathClicked:)];
    loadPathButton.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:loadPathButton];

    self.infoLabel = [NSTextField labelWithString:@""];
    self.infoLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.infoLabel.textColor = NSColor.secondaryLabelColor;
    [content addSubview:self.infoLabel];

    NSTextField *eyeLabel = [NSTextField labelWithString:@"Eye"];
    eyeLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:eyeLabel];

    self.eyePopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.eyePopup.translatesAutoresizingMaskIntoConstraints = NO;
    [self.eyePopup addItemWithTitle:@"Hero"];
    self.eyePopup.lastItem.representedObject = @"hero";
    [self.eyePopup addItemWithTitle:@"Left"];
    self.eyePopup.lastItem.representedObject = @"left";
    [self.eyePopup addItemWithTitle:@"Right"];
    self.eyePopup.lastItem.representedObject = @"right";
    [self.eyePopup addItemWithTitle:@"Stereo Split"];
    self.eyePopup.lastItem.representedObject = @"stereo";
    self.eyePopup.target = self;
    self.eyePopup.action = @selector(optionChanged:);
    [content addSubview:self.eyePopup];

    NSTextField *viewLabel = [NSTextField labelWithString:@"View"];
    viewLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:viewLabel];

    self.viewPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.viewPopup.translatesAutoresizingMaskIntoConstraints = NO;
    [self.viewPopup addItemWithTitle:@"Lens"];
    self.viewPopup.lastItem.representedObject = @"lens";
    [self.viewPopup addItemWithTitle:@"Viewport 180"];
    self.viewPopup.lastItem.representedObject = @"viewport";
    [self.viewPopup addItemWithTitle:@"LatLong 180"];
    self.viewPopup.lastItem.representedObject = @"latlong";
    self.viewPopup.target = self;
    self.viewPopup.action = @selector(optionChanged:);
    [content addSubview:self.viewPopup];

    NSTextField *scaleLabel = [NSTextField labelWithString:@"Decode"];
    scaleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:scaleLabel];

    self.scalePopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.scalePopup.translatesAutoresizingMaskIntoConstraints = NO;
    [self.scalePopup addItemWithTitle:@"Half"];
    self.scalePopup.lastItem.representedObject = @1;
    [self.scalePopup addItemWithTitle:@"Quarter"];
    self.scalePopup.lastItem.representedObject = @2;
    [self.scalePopup addItemWithTitle:@"Eighth"];
    self.scalePopup.lastItem.representedObject = @3;
    [self.scalePopup selectItemAtIndex:2];
    self.scalePopup.target = self;
    self.scalePopup.action = @selector(scaleChanged:);
    [content addSubview:self.scalePopup];

    NSTextField *frameLabel = [NSTextField labelWithString:@"Frame"];
    frameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:frameLabel];

    self.frameSlider = [NSSlider sliderWithValue:0 minValue:0 maxValue:0 target:self action:@selector(frameSliderChanged:)];
    self.frameSlider.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:self.frameSlider];

    self.frameField = [NSTextField textFieldWithString:@"0"];
    self.frameField.translatesAutoresizingMaskIntoConstraints = NO;
    self.frameField.target = self;
    self.frameField.action = @selector(frameFieldCommitted:);
    [content addSubview:self.frameField];

    self.imageView = [[SKIPInteractiveImageView alloc] initWithFrame:NSZeroRect];
    self.imageView.translatesAutoresizingMaskIntoConstraints = NO;
    __weak SpliceKitImmersivePreviewPanel *weakSelf = self;
    self.imageView.dragHandler = ^(NSPoint delta, BOOL ended) {
        [weakSelf previewDraggedByDelta:delta ended:ended];
    };
    self.imageView.scrollHandler = ^(CGFloat deltaY) {
        [weakSelf previewScrolledByDeltaY:deltaY];
    };
    self.imageView.toolTip = @"Drag to look around in Viewport 180. Scroll to change field of view.";
    [content addSubview:self.imageView];

    NSTextField *yawLabel = [NSTextField labelWithString:@"Yaw"];
    yawLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:yawLabel];
    self.yawSlider = [NSSlider sliderWithValue:0 minValue:-180 maxValue:180 target:self action:@selector(viewportChanged:)];
    self.yawSlider.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:self.yawSlider];
    self.yawValueLabel = [NSTextField labelWithString:@"0°"];
    self.yawValueLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:self.yawValueLabel];

    NSTextField *pitchLabel = [NSTextField labelWithString:@"Pitch"];
    pitchLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:pitchLabel];
    self.pitchSlider = [NSSlider sliderWithValue:0 minValue:-90 maxValue:90 target:self action:@selector(viewportChanged:)];
    self.pitchSlider.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:self.pitchSlider];
    self.pitchValueLabel = [NSTextField labelWithString:@"0°"];
    self.pitchValueLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:self.pitchValueLabel];

    NSTextField *fovLabel = [NSTextField labelWithString:@"FOV"];
    fovLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:fovLabel];
    self.fovSlider = [NSSlider sliderWithValue:110 minValue:60 maxValue:150 target:self action:@selector(viewportChanged:)];
    self.fovSlider.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:self.fovSlider];
    self.fovValueLabel = [NSTextField labelWithString:@"110°"];
    self.fovValueLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:self.fovValueLabel];

    NSButton *refreshButton = [NSButton buttonWithTitle:@"Refresh Preview"
                                                 target:self
                                                 action:@selector(refreshClicked:)];
    refreshButton.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:refreshButton];

    NSButton *sendButton = [NSButton buttonWithTitle:@"Send Frame to Vision Pro"
                                              target:self
                                              action:@selector(sendToVisionProClicked:)];
    sendButton.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:sendButton];

    self.messageLabel = [NSTextField labelWithString:@""];
    self.messageLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.messageLabel.textColor = NSColor.secondaryLabelColor;
    [content addSubview:self.messageLabel];

    [NSLayoutConstraint activateConstraints:@[
        [self.statusLabel.topAnchor constraintEqualToAnchor:content.topAnchor constant:p],
        [self.statusLabel.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:p],
        [self.statusLabel.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-p],

        [self.pathField.topAnchor constraintEqualToAnchor:self.statusLabel.bottomAnchor constant:8],
        [self.pathField.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:p],
        [loadSelectedButton.leadingAnchor constraintEqualToAnchor:self.pathField.trailingAnchor constant:8],
        [loadSelectedButton.centerYAnchor constraintEqualToAnchor:self.pathField.centerYAnchor],
        [loadPathButton.leadingAnchor constraintEqualToAnchor:loadSelectedButton.trailingAnchor constant:8],
        [loadPathButton.centerYAnchor constraintEqualToAnchor:self.pathField.centerYAnchor],
        [loadPathButton.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-p],
        [self.pathField.widthAnchor constraintGreaterThanOrEqualToConstant:320],

        [self.infoLabel.topAnchor constraintEqualToAnchor:self.pathField.bottomAnchor constant:8],
        [self.infoLabel.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:p],
        [self.infoLabel.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-p],

        [eyeLabel.topAnchor constraintEqualToAnchor:self.infoLabel.bottomAnchor constant:10],
        [eyeLabel.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:p],
        [self.eyePopup.centerYAnchor constraintEqualToAnchor:eyeLabel.centerYAnchor],
        [self.eyePopup.leadingAnchor constraintEqualToAnchor:eyeLabel.trailingAnchor constant:6],

        [viewLabel.centerYAnchor constraintEqualToAnchor:eyeLabel.centerYAnchor],
        [viewLabel.leadingAnchor constraintEqualToAnchor:self.eyePopup.trailingAnchor constant:18],
        [self.viewPopup.centerYAnchor constraintEqualToAnchor:viewLabel.centerYAnchor],
        [self.viewPopup.leadingAnchor constraintEqualToAnchor:viewLabel.trailingAnchor constant:6],

        [scaleLabel.centerYAnchor constraintEqualToAnchor:eyeLabel.centerYAnchor],
        [scaleLabel.leadingAnchor constraintEqualToAnchor:self.viewPopup.trailingAnchor constant:18],
        [self.scalePopup.centerYAnchor constraintEqualToAnchor:scaleLabel.centerYAnchor],
        [self.scalePopup.leadingAnchor constraintEqualToAnchor:scaleLabel.trailingAnchor constant:6],

        [frameLabel.topAnchor constraintEqualToAnchor:eyeLabel.bottomAnchor constant:10],
        [frameLabel.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:p],
        [self.frameSlider.centerYAnchor constraintEqualToAnchor:frameLabel.centerYAnchor],
        [self.frameSlider.leadingAnchor constraintEqualToAnchor:frameLabel.trailingAnchor constant:6],
        [self.frameField.centerYAnchor constraintEqualToAnchor:frameLabel.centerYAnchor],
        [self.frameField.leadingAnchor constraintEqualToAnchor:self.frameSlider.trailingAnchor constant:8],
        [self.frameField.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-p],
        [self.frameField.widthAnchor constraintEqualToConstant:90],

        [self.imageView.topAnchor constraintEqualToAnchor:self.frameSlider.bottomAnchor constant:12],
        [self.imageView.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:p],
        [self.imageView.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-p],
        [self.imageView.heightAnchor constraintEqualToConstant:470],

        [yawLabel.topAnchor constraintEqualToAnchor:self.imageView.bottomAnchor constant:12],
        [yawLabel.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:p],
        [self.yawSlider.centerYAnchor constraintEqualToAnchor:yawLabel.centerYAnchor],
        [self.yawSlider.leadingAnchor constraintEqualToAnchor:yawLabel.trailingAnchor constant:6],
        [self.yawValueLabel.centerYAnchor constraintEqualToAnchor:yawLabel.centerYAnchor],
        [self.yawValueLabel.leadingAnchor constraintEqualToAnchor:self.yawSlider.trailingAnchor constant:8],
        [self.yawValueLabel.widthAnchor constraintEqualToConstant:48],

        [pitchLabel.topAnchor constraintEqualToAnchor:yawLabel.bottomAnchor constant:8],
        [pitchLabel.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:p],
        [self.pitchSlider.centerYAnchor constraintEqualToAnchor:pitchLabel.centerYAnchor],
        [self.pitchSlider.leadingAnchor constraintEqualToAnchor:pitchLabel.trailingAnchor constant:6],
        [self.pitchValueLabel.centerYAnchor constraintEqualToAnchor:pitchLabel.centerYAnchor],
        [self.pitchValueLabel.leadingAnchor constraintEqualToAnchor:self.pitchSlider.trailingAnchor constant:8],
        [self.pitchValueLabel.widthAnchor constraintEqualToConstant:48],

        [fovLabel.topAnchor constraintEqualToAnchor:pitchLabel.bottomAnchor constant:8],
        [fovLabel.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:p],
        [self.fovSlider.centerYAnchor constraintEqualToAnchor:fovLabel.centerYAnchor],
        [self.fovSlider.leadingAnchor constraintEqualToAnchor:fovLabel.trailingAnchor constant:6],
        [self.fovValueLabel.centerYAnchor constraintEqualToAnchor:fovLabel.centerYAnchor],
        [self.fovValueLabel.leadingAnchor constraintEqualToAnchor:self.fovSlider.trailingAnchor constant:8],
        [self.fovValueLabel.widthAnchor constraintEqualToConstant:52],

        [refreshButton.centerYAnchor constraintEqualToAnchor:fovLabel.centerYAnchor],
        [refreshButton.leadingAnchor constraintEqualToAnchor:self.fovValueLabel.trailingAnchor constant:16],
        [sendButton.centerYAnchor constraintEqualToAnchor:fovLabel.centerYAnchor],
        [sendButton.leadingAnchor constraintEqualToAnchor:refreshButton.trailingAnchor constant:8],

        [self.messageLabel.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-p],
        [self.messageLabel.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:p],
        [self.messageLabel.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-p],
    ]];
}

- (void)windowWillClose:(NSNotification *)notification {
    [self hidePanel];
}

- (uint32_t)currentScaleHint {
    id value = self.scalePopup.selectedItem.representedObject;
    return [value respondsToSelector:@selector(unsignedIntValue)] ? [value unsignedIntValue] : 3;
}

- (NSString *)currentEyeMode {
    NSString *value = SKIPStringOrEmpty(self.eyePopup.selectedItem.representedObject);
    return value.length > 0 ? value : @"hero";
}

- (NSString *)currentViewMode {
    NSString *value = SKIPStringOrEmpty(self.viewPopup.selectedItem.representedObject);
    return value.length > 0 ? value : @"viewport";
}

- (NSInteger)currentHeroEyeIndex {
    NSDictionary *immersive = [self.clipSummary[@"immersive"] isKindOfClass:[NSDictionary class]] ? self.clipSummary[@"immersive"] : nil;
    NSString *heroEye = [immersive[@"heroEye"] isKindOfClass:[NSString class]] ? [immersive[@"heroEye"] lowercaseString] : @"right";
    return [heroEye isEqualToString:@"left"] ? 0 : 1;
}

- (uint32_t)currentFrameIndex {
    NSInteger value = self.frameField.integerValue;
    NSInteger maxFrame = (NSInteger)MAX(0, self.frameSlider.maxValue);
    return (uint32_t)MIN(MAX(value, 0), maxFrame);
}

- (void)invalidateDecodeCache {
    self.leftDecodedData = nil;
    self.rightDecodedData = nil;
    self.decodedWidth = 0;
    self.decodedHeight = 0;
    self.cachedFrameIndex = UINT32_MAX;
    self.cachedScaleHint = UINT32_MAX;
    self.cachedPath = @"";
    [self bumpRenderGeneration];
    @synchronized (self) {
        self.pendingRenderRequest = nil;
    }
    self.lastRenderedImage = nil;
    self.lastRenderedSnapshot = nil;
}

- (void)resetPerformanceCounters {
    self.previewRequestCount = 0;
    self.interactivePreviewRequestCount = 0;
    self.lastPreviewRequestTimestamp = 0.0;
    self.lastPreviewRequestIntervalMs = 0.0;
    self.totalPreviewRequestIntervalMs = 0.0;
    self.maxPreviewRequestIntervalMs = 0.0;
    self.previewRequestIntervalSamples = 0;
    self.rollingRequestFPS = 0.0;
    self.rollingRequestWindowStart = 0.0;
    self.rollingRequestWindowCount = 0;
    self.decodeCount = 0;
    self.decodeCacheHitCount = 0;
    self.lastDecodeMs = 0.0;
    self.totalDecodeMs = 0.0;
    self.maxDecodeMs = 0.0;
    self.lastLeftEyeDecodeMs = 0.0;
    self.lastRightEyeDecodeMs = 0.0;
    self.totalLeftEyeDecodeMs = 0.0;
    self.totalRightEyeDecodeMs = 0.0;
    self.cpuRenderCount = 0;
    self.lastCpuRenderMs = 0.0;
    self.totalCpuRenderMs = 0.0;
    self.maxCpuRenderMs = 0.0;
    self.lastCpuRenderTimestamp = 0.0;
    self.lastCpuRenderIntervalMs = 0.0;
    self.totalCpuRenderIntervalMs = 0.0;
    self.maxCpuRenderIntervalMs = 0.0;
    self.cpuRenderIntervalSamples = 0;
    self.rollingCpuRenderFPS = 0.0;
    self.rollingCpuRenderWindowStart = 0.0;
    self.rollingCpuRenderWindowCount = 0;
    self.lastCpuRequestLatencyMs = 0.0;
    self.totalCpuRequestLatencyMs = 0.0;
    self.maxCpuRequestLatencyMs = 0.0;
    self.cpuRequestLatencySamples = 0;
    self.perfRenderRequestToken = 0;
    self.perfRenderRequestedAt = 0.0;
    self.lastPerfLogTimestamp = 0.0;
    [self.imageView resetRendererPerformanceCounters];
}

- (void)notePreviewRequestInteractive:(BOOL)interactive {
    CFTimeInterval now = SKIPNow();
    self.previewRequestCount += 1;
    if (interactive) self.interactivePreviewRequestCount += 1;

    if (self.lastPreviewRequestTimestamp > 0.0) {
        double intervalMs = (now - self.lastPreviewRequestTimestamp) * 1000.0;
        self.lastPreviewRequestIntervalMs = intervalMs;
        self.totalPreviewRequestIntervalMs += intervalMs;
        self.maxPreviewRequestIntervalMs = MAX(self.maxPreviewRequestIntervalMs, intervalMs);
        self.previewRequestIntervalSamples += 1;
    }
    self.lastPreviewRequestTimestamp = now;

    if (self.rollingRequestWindowStart <= 0.0 || (now - self.rollingRequestWindowStart) >= 1.0) {
        double windowDuration = MAX(now - self.rollingRequestWindowStart, 0.001);
        self.rollingRequestFPS = self.rollingRequestWindowStart > 0.0
            ? ((double)self.rollingRequestWindowCount / windowDuration)
            : 1.0;
        self.rollingRequestWindowStart = now;
        self.rollingRequestWindowCount = 1;
    } else {
        self.rollingRequestWindowCount += 1;
        self.rollingRequestFPS = (double)self.rollingRequestWindowCount / MAX(now - self.rollingRequestWindowStart, 0.001);
    }

    self.perfRenderRequestToken += 1;
    self.perfRenderRequestedAt = now;
}

- (void)noteDecodeCacheHit {
    self.decodeCacheHitCount += 1;
}

- (void)noteDecodeDurationMs:(double)decodeMs leftEyeMs:(double)leftEyeMs rightEyeMs:(double)rightEyeMs {
    self.decodeCount += 1;
    self.lastDecodeMs = decodeMs;
    self.totalDecodeMs += decodeMs;
    self.maxDecodeMs = MAX(self.maxDecodeMs, decodeMs);
    self.lastLeftEyeDecodeMs = leftEyeMs;
    self.lastRightEyeDecodeMs = rightEyeMs;
    self.totalLeftEyeDecodeMs += leftEyeMs;
    self.totalRightEyeDecodeMs += rightEyeMs;
}

- (void)noteCPURenderDurationMs:(double)renderMs requestLatencyMs:(double)requestLatencyMs {
    CFTimeInterval now = SKIPNow();
    self.cpuRenderCount += 1;
    self.lastCpuRenderMs = renderMs;
    self.totalCpuRenderMs += renderMs;
    self.maxCpuRenderMs = MAX(self.maxCpuRenderMs, renderMs);

    if (self.lastCpuRenderTimestamp > 0.0) {
        double intervalMs = (now - self.lastCpuRenderTimestamp) * 1000.0;
        self.lastCpuRenderIntervalMs = intervalMs;
        self.totalCpuRenderIntervalMs += intervalMs;
        self.maxCpuRenderIntervalMs = MAX(self.maxCpuRenderIntervalMs, intervalMs);
        self.cpuRenderIntervalSamples += 1;
    }
    self.lastCpuRenderTimestamp = now;

    if (self.rollingCpuRenderWindowStart <= 0.0 || (now - self.rollingCpuRenderWindowStart) >= 1.0) {
        double windowDuration = MAX(now - self.rollingCpuRenderWindowStart, 0.001);
        self.rollingCpuRenderFPS = self.rollingCpuRenderWindowStart > 0.0
            ? ((double)self.rollingCpuRenderWindowCount / windowDuration)
            : 1.0;
        self.rollingCpuRenderWindowStart = now;
        self.rollingCpuRenderWindowCount = 1;
    } else {
        self.rollingCpuRenderWindowCount += 1;
        self.rollingCpuRenderFPS = (double)self.rollingCpuRenderWindowCount / MAX(now - self.rollingCpuRenderWindowStart, 0.001);
    }

    if (requestLatencyMs > 0.0) {
        self.lastCpuRequestLatencyMs = requestLatencyMs;
        self.totalCpuRequestLatencyMs += requestLatencyMs;
        self.maxCpuRequestLatencyMs = MAX(self.maxCpuRequestLatencyMs, requestLatencyMs);
        self.cpuRequestLatencySamples += 1;
    }
}

- (NSDictionary *)timelineSyncSnapshot {
    NSMutableDictionary *snapshot = [@{
        @"available": @NO,
        @"active": @NO,
        @"matchesLoadedClip": @NO,
        @"timelinePath": @"",
        @"playheadSeconds": @0.0,
        @"clipStartSeconds": @0.0,
        @"clipEndSeconds": @0.0,
        @"sourceSeconds": @0.0,
        @"frameIndex": @([self currentFrameIndex]),
    } mutableCopy];

    if (self.selectedPath.length == 0) {
        return [snapshot copy];
    }

    SKIP_CMTime playhead = {0};
    id context = nil;
    if (!SKIPCurrentTimelineTimeAndContext(&playhead, &context, NULL)) {
        return [snapshot copy];
    }

    snapshot[@"available"] = @YES;
    snapshot[@"playheadSeconds"] = @(SKIPSecondsFromCMTime(playhead));

    id item = SKIPTimelineClipNearPlayhead();
    if (!item) {
        return [snapshot copy];
    }

    NSURL *mediaURL = SKIPDirectMediaURLForClipObject(item);
    NSString *timelinePath = mediaURL.path.stringByStandardizingPath ?: @"";
    NSString *resolvedTimelinePath = timelinePath.length > 0
        ? (SpliceKitBRAWResolveOriginalPathForPublic(timelinePath) ?: timelinePath)
        : @"";
    resolvedTimelinePath = resolvedTimelinePath.length > 0
        ? [[NSURL fileURLWithPath:resolvedTimelinePath] URLByResolvingSymlinksInPath].path.stringByStandardizingPath
        : @"";
    snapshot[@"timelinePath"] = resolvedTimelinePath.length > 0 ? resolvedTimelinePath : timelinePath;

    BOOL matchesLoadedClip = (resolvedTimelinePath.length > 0 && [resolvedTimelinePath isEqualToString:self.selectedPath]);
    snapshot[@"matchesLoadedClip"] = @(matchesLoadedClip);

    double playheadSeconds = 0.0;
    double clipStartSeconds = 0.0;
    double clipEndSeconds = 0.0;
    double sourceSeconds = 0.0;
    double frameRate = [self.clipSummary[@"frameRate"] respondsToSelector:@selector(doubleValue)]
        ? [self.clipSummary[@"frameRate"] doubleValue]
        : 0.0;
    NSInteger frameCount = [self.clipSummary[@"frameCount"] respondsToSelector:@selector(integerValue)]
        ? [self.clipSummary[@"frameCount"] integerValue]
        : (NSInteger)MAX(0.0, self.frameSlider.maxValue + 1.0);
    double maxSourceSeconds = (frameRate > 0.0 && frameCount > 0)
        ? ((double)frameCount / frameRate)
        : 0.0;
    if (!SKIPClipSourceSecondsAtPlayhead(item,
                                         context,
                                         playhead,
                                         maxSourceSeconds,
                                         &playheadSeconds,
                                         &clipStartSeconds,
                                         &clipEndSeconds,
                                         &sourceSeconds)) {
        return [snapshot copy];
    }

    snapshot[@"playheadSeconds"] = @(playheadSeconds);
    snapshot[@"clipStartSeconds"] = @(clipStartSeconds);
    snapshot[@"clipEndSeconds"] = @(clipEndSeconds);
    snapshot[@"sourceSeconds"] = @(sourceSeconds);

    if (frameRate <= 0.0 || frameCount <= 0) {
        return [snapshot copy];
    }

    NSInteger frameIndex = (NSInteger)llround(MAX(0.0, sourceSeconds) * frameRate);
    frameIndex = MIN(MAX(frameIndex, 0), frameCount - 1);
    snapshot[@"frameIndex"] = @(frameIndex);
    snapshot[@"active"] = @(matchesLoadedClip);
    return [snapshot copy];
}

- (BOOL)syncFrameIndexToTimelinePlayheadAndReturnChange:(BOOL *)outChanged error:(NSError **)error {
    if (outChanged) *outChanged = NO;
    self.lastTimelineSyncSnapshot = [self timelineSyncSnapshot];

    BOOL active = [self.lastTimelineSyncSnapshot[@"active"] boolValue];
    if (!active) return NO;

    NSInteger syncedFrameIndex = [self.lastTimelineSyncSnapshot[@"frameIndex"] integerValue];
    NSInteger currentFrameIndex = [self currentFrameIndex];
    if (syncedFrameIndex == currentFrameIndex) return YES;

    [self setFrameIndexValue:syncedFrameIndex];
    if (outChanged) *outChanged = YES;
    if (error) *error = nil;
    return YES;
}

- (void)timelineSyncTimerFired:(NSTimer *)timer {
    (void)timer;
    if (self.selectedPath.length == 0) return;

    BOOL changed = NO;
    [self syncFrameIndexToTimelinePlayheadAndReturnChange:&changed error:nil];
    if (!changed) return;

    NSError *error = nil;
    BOOL ok = [self requestPreviewRenderInteractive:NO error:&error];
    [self setMessage:ok ? @"" : error.localizedDescription];
}

- (void)updateTimelineSyncTimer {
    BOOL shouldRun = self.selectedPath.length > 0 && (self.isVisible || self.isViewerVisible);
    if (shouldRun) {
        if (!self.timelineSyncTimer) {
            self.timelineSyncTimer = [NSTimer scheduledTimerWithTimeInterval:(1.0 / 15.0)
                                                                     target:self
                                                                   selector:@selector(timelineSyncTimerFired:)
                                                                   userInfo:nil
                                                                    repeats:YES];
            self.timelineSyncTimer.tolerance = 0.02;
        }
    } else if (self.timelineSyncTimer) {
        [self.timelineSyncTimer invalidate];
        self.timelineSyncTimer = nil;
    }
}

- (BOOL)loadSelectedClipWithError:(NSError **)error {
    SpliceKit_log(@"[ImmersivePreview] loadSelectedClipWithError enter");
    NSString *path = SKIPResolveFirstPathFromSelection();
    if (path.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"SpliceKitImmersivePreview" code:-20
                                     userInfo:@{NSLocalizedDescriptionKey: @"No immersive BRAW clip is currently selected"}];
        }
        return NO;
    }
    return [self loadClipAtPath:path error:error];
}

- (BOOL)loadClipAtPath:(NSString *)path error:(NSError **)error {
    NSString *standardizedPath = path.stringByStandardizingPath ?: @"";
    SpliceKit_log(@"[ImmersivePreview] loadClipAtPath path=%@", standardizedPath ?: @"");
    NSError *describeError = nil;
    NSDictionary *clip = SKIPDescribeImmersiveClipAtPath(standardizedPath, &describeError);
    if (!clip) {
        SpliceKit_log(@"[ImmersivePreview] loadClipAtPath describe failed error=%@", describeError.localizedDescription ?: @"<none>");
        if (error) *error = describeError;
        return NO;
    }

    if ([NSThread isMainThread]) {
        return [self applyLoadedClipSummary:clip forPath:standardizedPath error:error];
    }

    __block BOOL ok = NO;
    __block NSError *applyError = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{
        ok = [self applyLoadedClipSummary:clip forPath:standardizedPath error:&applyError];
    });
    if (!ok && error) *error = applyError;
    return ok;
}

- (void)loadClipAtPathAsync:(NSString *)path
                 completion:(void (^)(BOOL ok, NSError *error))completion {
    NSString *pathCopy = [path.stringByStandardizingPath copy] ?: @"";
    dispatch_queue_t queue = self.metadataQueue ?: dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
    __weak SpliceKitImmersivePreviewPanel *weakSelf = self;
    dispatch_async(queue, ^{
        @autoreleasepool {
            NSError *describeError = nil;
            NSDictionary *clip = nil;
            @try {
                clip = SKIPDescribeImmersiveClipAtPath(pathCopy, &describeError);
            } @catch (NSException *exception) {
                describeError = SKIPImmersivePreviewError(-28,
                                                          [NSString stringWithFormat:@"Immersive describe failed: %@",
                                                           exception.reason ?: exception.name]);
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                SpliceKitImmersivePreviewPanel *strongSelf = weakSelf;
                if (!strongSelf) {
                    if (completion) completion(NO, SKIPImmersivePreviewError(-26, @"Immersive preview panel was released before load completed"));
                    return;
                }
                NSError *applyError = describeError;
                BOOL ok = NO;
                if (clip) {
                    @try {
                        ok = [strongSelf applyLoadedClipSummary:clip forPath:pathCopy error:&applyError];
                    } @catch (NSException *exception) {
                        applyError = SKIPImmersivePreviewError(-27,
                                                               [NSString stringWithFormat:@"Immersive load failed: %@",
                                                                exception.reason ?: exception.name]);
                    }
                }
                if (completion) completion(ok, applyError);
            });
        }
    });
}

- (BOOL)applyLoadedClipSummary:(NSDictionary *)clipSummary
                       forPath:(NSString *)path
                         error:(NSError **)error {
    if (!clipSummary || path.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"SpliceKitImmersivePreview"
                                         code:-23
                                     userInfo:@{NSLocalizedDescriptionKey: @"Missing immersive clip summary"}];
        }
        return NO;
    }

    self.selectedPath = path ?: @"";
    self.clipSummary = clipSummary;
    self.pathField.stringValue = self.selectedPath ?: @"";
    self.frameSlider.maxValue = MAX(0, [clipSummary[@"frameCount"] doubleValue] - 1.0);
    self.frameSlider.doubleValue = 0.0;
    self.frameField.stringValue = @"0";
    self.lastTimelineSyncSnapshot = nil;
    [self syncFrameIndexToTimelinePlayheadAndReturnChange:NULL error:nil];
    [self invalidateDecodeCache];
    [self.imageView clearRenderer];
    [self resetPerformanceCounters];
    [self refreshUIState];
    [self updateTimelineSyncTimer];
    return YES;
}

- (NSDictionary *)metalRenderStateSnapshot {
    return @{
        @"path": self.selectedPath ?: @"",
        @"leftData": self.leftDecodedData ?: NSData.data,
        @"rightData": self.rightDecodedData ?: NSData.data,
        @"decodedWidth": @(self.decodedWidth),
        @"decodedHeight": @(self.decodedHeight),
        @"eyeMode": self.currentEyeMode ?: @"hero",
        @"viewMode": self.currentViewMode ?: @"viewport",
        @"heroEyeIndex": @(self.currentHeroEyeIndex),
        @"yaw": @(self.yawSlider.doubleValue),
        @"pitch": @(self.pitchSlider.doubleValue),
        @"fov": @(self.fovSlider.doubleValue),
        @"frameIndex": @([self currentFrameIndex]),
        @"renderRequestToken": @(self.perfRenderRequestToken),
        @"renderRequestedAt": @(self.perfRenderRequestedAt),
    };
}

- (BOOL)requestPreviewRenderInteractive:(BOOL)interactive error:(NSError **)error {
    [self syncFrameIndexToTimelinePlayheadAndReturnChange:NULL error:nil];
    [self notePreviewRequestInteractive:interactive];
    if (self.selectedPath.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"SpliceKitImmersivePreview" code:-22
                                     userInfo:@{NSLocalizedDescriptionKey: @"No immersive BRAW clip loaded"}];
        }
        return NO;
    }
    [self scheduleAsyncPreviewRenderInteractive:interactive];
    return YES;
}

- (void)scheduleAsyncPreviewRenderInteractive:(BOOL)interactive {
    if (self.selectedPath.length == 0) return;

    uint32_t frameIndex = self.currentFrameIndex;
    uint32_t scaleHint = self.currentScaleHint;
    BOOL hasCachedDecode = ([self.cachedPath isEqualToString:self.selectedPath] &&
                            self.cachedFrameIndex == frameIndex &&
                            self.cachedScaleHint == scaleHint &&
                            self.leftDecodedData &&
                            self.rightDecodedData &&
                            self.decodedWidth > 0 &&
                            self.decodedHeight > 0);
    if (hasCachedDecode) {
        [self noteDecodeCacheHit];
    }

    NSData *leftDecodedData = hasCachedDecode ? self.leftDecodedData : nil;
    NSData *rightDecodedData = hasCachedDecode ? self.rightDecodedData : nil;
    size_t decodedWidth = hasCachedDecode ? self.decodedWidth : 0;
    size_t decodedHeight = hasCachedDecode ? self.decodedHeight : 0;
    NSString *eyeMode = [self.currentEyeMode copy];
    NSString *viewMode = [self.currentViewMode copy];
    NSInteger heroEyeIndex = self.currentHeroEyeIndex;
    double yaw = self.yawSlider.doubleValue;
    double pitch = self.pitchSlider.doubleValue;
    double fov = self.fovSlider.doubleValue;
    CGFloat backingScale = self.panel.backingScaleFactor > 0.0 ? self.panel.backingScaleFactor : NSScreen.mainScreen.backingScaleFactor;
    NSSize displaySize = self.imageView.bounds.size;
    NSDictionary *snapshot = [self statusSnapshot];
    uint64_t generation = [self bumpRenderGeneration];
    BOOL rendererReady = self.imageView.rendererReady;
    NSDictionary *request = @{
        @"leftDecodedData": leftDecodedData ?: NSData.data,
        @"rightDecodedData": rightDecodedData ?: NSData.data,
        @"decodedWidth": @(decodedWidth),
        @"decodedHeight": @(decodedHeight),
        @"eyeMode": eyeMode ?: @"hero",
        @"viewMode": viewMode ?: @"viewport",
        @"heroEyeIndex": @(heroEyeIndex),
        @"selectedPath": self.selectedPath ?: @"",
        @"frameIndex": @(frameIndex),
        @"scaleHint": @(scaleHint),
        @"clipSummary": self.clipSummary ?: @{},
        @"yaw": @(yaw),
        @"pitch": @(pitch),
        @"fov": @(fov),
        @"displayWidth": @(displaySize.width),
        @"displayHeight": @(displaySize.height),
        @"backingScale": @(backingScale),
        @"interactive": @(interactive),
        @"generation": @(generation),
        @"rendererReady": @(rendererReady),
        @"renderRequestToken": @(self.perfRenderRequestToken),
        @"renderRequestedAt": @(self.perfRenderRequestedAt),
        @"snapshot": snapshot ?: @{},
    };

    BOOL shouldStartWorker = NO;
    @synchronized (self) {
        self.pendingRenderRequest = request;
        if (!self.renderWorkerRunning) {
            self.renderWorkerRunning = YES;
            shouldStartWorker = YES;
        }
    }

    __weak SpliceKitImmersivePreviewPanel *weakSelf = self;
    if (shouldStartWorker) {
        dispatch_async(self.renderQueue, ^{
            [weakSelf drainScheduledPreviewRenders];
        });
    }

    if (interactive) {
        [self scheduleSettledFullQualityRenderFromGeneration:generation];
    }
}

- (void)drainScheduledPreviewRenders {
    @try {
        while (YES) {
            @autoreleasepool {
                NSDictionary *request = nil;
                @synchronized (self) {
                    request = self.pendingRenderRequest;
                    self.pendingRenderRequest = nil;
                    if (!request) {
                        self.renderWorkerRunning = NO;
                        return;
                    }
                }

                uint64_t generation = [request[@"generation"] respondsToSelector:@selector(unsignedLongLongValue)] ? [request[@"generation"] unsignedLongLongValue] : 0;
                BOOL interactive = [request[@"interactive"] respondsToSelector:@selector(boolValue)] && [request[@"interactive"] boolValue];
                BOOL rendererReady = [request[@"rendererReady"] respondsToSelector:@selector(boolValue)] && [request[@"rendererReady"] boolValue];

                @synchronized (self) {
                    NSDictionary *newerRequest = self.pendingRenderRequest;
                    if (newerRequest) {
                        uint64_t newerGeneration = [newerRequest[@"generation"] respondsToSelector:@selector(unsignedLongLongValue)] ? [newerRequest[@"generation"] unsignedLongLongValue] : 0;
                        if (newerGeneration > generation) {
                            continue;
                        }
                    }
                }

                NSData *leftDecodedData = [request[@"leftDecodedData"] isKindOfClass:[NSData class]] ? request[@"leftDecodedData"] : nil;
                NSData *rightDecodedData = [request[@"rightDecodedData"] isKindOfClass:[NSData class]] ? request[@"rightDecodedData"] : nil;
            size_t decodedWidth = [request[@"decodedWidth"] respondsToSelector:@selector(unsignedIntegerValue)] ? [request[@"decodedWidth"] unsignedIntegerValue] : 0;
            size_t decodedHeight = [request[@"decodedHeight"] respondsToSelector:@selector(unsignedIntegerValue)] ? [request[@"decodedHeight"] unsignedIntegerValue] : 0;
            NSString *eyeMode = [request[@"eyeMode"] isKindOfClass:[NSString class]] ? request[@"eyeMode"] : @"hero";
            NSString *viewMode = [request[@"viewMode"] isKindOfClass:[NSString class]] ? request[@"viewMode"] : @"viewport";
            NSInteger heroEyeIndex = [request[@"heroEyeIndex"] respondsToSelector:@selector(integerValue)] ? [request[@"heroEyeIndex"] integerValue] : 0;
            NSString *selectedPath = [request[@"selectedPath"] isKindOfClass:[NSString class]] ? request[@"selectedPath"] : @"";
            uint32_t frameIndex = [request[@"frameIndex"] respondsToSelector:@selector(unsignedIntValue)] ? [request[@"frameIndex"] unsignedIntValue] : 0;
            uint32_t scaleHint = [request[@"scaleHint"] respondsToSelector:@selector(unsignedIntValue)] ? [request[@"scaleHint"] unsignedIntValue] : 0;
            NSDictionary *clipSummary = [request[@"clipSummary"] isKindOfClass:[NSDictionary class]] ? request[@"clipSummary"] : @{};
            double yaw = [request[@"yaw"] respondsToSelector:@selector(doubleValue)] ? [request[@"yaw"] doubleValue] : 0.0;
            double pitch = [request[@"pitch"] respondsToSelector:@selector(doubleValue)] ? [request[@"pitch"] doubleValue] : 0.0;
            double fov = [request[@"fov"] respondsToSelector:@selector(doubleValue)] ? [request[@"fov"] doubleValue] : 110.0;
            NSSize displaySize = NSMakeSize([request[@"displayWidth"] respondsToSelector:@selector(doubleValue)] ? [request[@"displayWidth"] doubleValue] : 0.0,
                                            [request[@"displayHeight"] respondsToSelector:@selector(doubleValue)] ? [request[@"displayHeight"] doubleValue] : 0.0);
            CGFloat backingScale = [request[@"backingScale"] respondsToSelector:@selector(doubleValue)] ? [request[@"backingScale"] doubleValue] : 1.0;
            NSDictionary *snapshot = [request[@"snapshot"] isKindOfClass:[NSDictionary class]] ? request[@"snapshot"] : @{};
            uint64_t renderRequestToken = [request[@"renderRequestToken"] respondsToSelector:@selector(unsignedLongLongValue)] ? [request[@"renderRequestToken"] unsignedLongLongValue] : 0;
            CFTimeInterval renderRequestedAt = [request[@"renderRequestedAt"] respondsToSelector:@selector(doubleValue)] ? [request[@"renderRequestedAt"] doubleValue] : 0.0;
            BOOL decodedThisPass = NO;
            double decodeMs = 0.0;
            double leftEyeMs = 0.0;
            double rightEyeMs = 0.0;

            if (!leftDecodedData || !rightDecodedData || decodedWidth == 0 || decodedHeight == 0) {
                uint32_t leftWidth = 0, leftHeight = 0;
                uint32_t rightWidth = 0, rightHeight = 0;
                NSError *decodeError = nil;
                CFTimeInterval decodeStart = SKIPNow();
                CFTimeInterval leftStart = decodeStart;
                NSData *leftData = SKIPDecodeEyeBytes(selectedPath,
                                                      frameIndex,
                                                      scaleHint,
                                                      0,
                                                      clipSummary,
                                                      &leftWidth,
                                                      &leftHeight,
                                                      &decodeError);
                leftEyeMs = (SKIPNow() - leftStart) * 1000.0;
                if (!leftData) {
                    __weak SpliceKitImmersivePreviewPanel *weakSelf = self;
                    dispatch_async(dispatch_get_main_queue(), ^{
                        SpliceKitImmersivePreviewPanel *strongSelf = weakSelf;
                        if (!strongSelf || ![strongSelf isRenderGenerationCurrent:generation]) return;
                        [strongSelf setMessage:decodeError.localizedDescription ?: @"Unable to decode immersive left eye."];
                    });
                    continue;
                }

                CFTimeInterval rightStart = SKIPNow();
                NSData *rightData = SKIPDecodeEyeBytes(selectedPath,
                                                       frameIndex,
                                                       scaleHint,
                                                       1,
                                                       clipSummary,
                                                       &rightWidth,
                                                       &rightHeight,
                                                       &decodeError);
                rightEyeMs = (SKIPNow() - rightStart) * 1000.0;
                if (!rightData) {
                    __weak SpliceKitImmersivePreviewPanel *weakSelf = self;
                    dispatch_async(dispatch_get_main_queue(), ^{
                        SpliceKitImmersivePreviewPanel *strongSelf = weakSelf;
                        if (!strongSelf || ![strongSelf isRenderGenerationCurrent:generation]) return;
                        [strongSelf setMessage:decodeError.localizedDescription ?: @"Unable to decode immersive right eye."];
                    });
                    continue;
                }

                if (leftWidth != rightWidth || leftHeight != rightHeight) {
                    __weak SpliceKitImmersivePreviewPanel *weakSelf = self;
                    dispatch_async(dispatch_get_main_queue(), ^{
                        SpliceKitImmersivePreviewPanel *strongSelf = weakSelf;
                        if (!strongSelf || ![strongSelf isRenderGenerationCurrent:generation]) return;
                        [strongSelf setMessage:@"Decoded immersive eye sizes do not match."];
                    });
                    continue;
                }

                leftDecodedData = leftData;
                rightDecodedData = rightData;
                decodedWidth = leftWidth;
                decodedHeight = leftHeight;
                decodeMs = (SKIPNow() - decodeStart) * 1000.0;
                decodedThisPass = YES;

                @synchronized (self) {
                    NSDictionary *newerRequest = self.pendingRenderRequest;
                    if (newerRequest) {
                        uint64_t newerGeneration = [newerRequest[@"generation"] respondsToSelector:@selector(unsignedLongLongValue)] ? [newerRequest[@"generation"] unsignedLongLongValue] : 0;
                        if (newerGeneration > generation) {
                            continue;
                        }
                    }
                }
            }

            if (rendererReady) {
                __weak SpliceKitImmersivePreviewPanel *weakSelf = self;
                dispatch_async(dispatch_get_main_queue(), ^{
                    SpliceKitImmersivePreviewPanel *strongSelf = weakSelf;
                    if (!strongSelf || ![strongSelf isRenderGenerationCurrent:generation]) return;
                    strongSelf.leftDecodedData = leftDecodedData;
                    strongSelf.rightDecodedData = rightDecodedData;
                    strongSelf.decodedWidth = decodedWidth;
                    strongSelf.decodedHeight = decodedHeight;
                    strongSelf.cachedPath = selectedPath ?: @"";
                    strongSelf.cachedFrameIndex = frameIndex;
                    strongSelf.cachedScaleHint = scaleHint;
                    if (decodedThisPass) {
                        [strongSelf noteDecodeDurationMs:decodeMs leftEyeMs:leftEyeMs rightEyeMs:rightEyeMs];
                    }
                    strongSelf.lastRenderedSnapshot = [strongSelf statusSnapshot];
                    [strongSelf.imageView syncFromBackend];
                    [[SKIPImmersiveViewerOverlayHost sharedHost] syncImageFromBackend];
                    [strongSelf refreshUIState];
                    [strongSelf logPerformanceIfNeeded];
                });
                continue;
            }

            CFTimeInterval renderStart = SKIPNow();
            NSDictionary *imageData = SKIPBuildPreviewImageData(leftDecodedData,
                                                                rightDecodedData,
                                                                decodedWidth,
                                                                decodedHeight,
                                                                eyeMode,
                                                                viewMode,
                                                                heroEyeIndex,
                                                                yaw,
                                                                pitch,
                                                                fov,
                                                                displaySize,
                                                                backingScale,
                                                                interactive);
            NSData *packed = [imageData[@"data"] isKindOfClass:[NSData class]] ? imageData[@"data"] : nil;
            size_t width = [imageData[@"width"] respondsToSelector:@selector(unsignedIntegerValue)] ? [imageData[@"width"] unsignedIntegerValue] : 0;
            size_t height = [imageData[@"height"] respondsToSelector:@selector(unsignedIntegerValue)] ? [imageData[@"height"] unsignedIntegerValue] : 0;
            double renderMs = (SKIPNow() - renderStart) * 1000.0;
            if (!packed || width == 0 || height == 0) {
                continue;
            }

            @synchronized (self) {
                NSDictionary *newerRequest = self.pendingRenderRequest;
                if (newerRequest) {
                    uint64_t newerGeneration = [newerRequest[@"generation"] respondsToSelector:@selector(unsignedLongLongValue)] ? [newerRequest[@"generation"] unsignedLongLongValue] : 0;
                    if (newerGeneration > generation) {
                        continue;
                    }
                }
            }

                __weak SpliceKitImmersivePreviewPanel *weakSelf = self;
                dispatch_async(dispatch_get_main_queue(), ^{
                    SpliceKitImmersivePreviewPanel *strongSelf = weakSelf;
                if (!strongSelf || ![strongSelf isRenderGenerationCurrent:generation]) return;
                NSImage *image = SKIPImageFromBGRAData(packed, width, height);
                if (!image) return;
                double requestLatencyMs = renderRequestedAt > 0.0 ? ((SKIPNow() - renderRequestedAt) * 1000.0) : 0.0;
                (void)renderRequestToken;
                strongSelf.leftDecodedData = leftDecodedData;
                strongSelf.rightDecodedData = rightDecodedData;
                strongSelf.decodedWidth = decodedWidth;
                strongSelf.decodedHeight = decodedHeight;
                strongSelf.cachedPath = selectedPath ?: @"";
                strongSelf.cachedFrameIndex = frameIndex;
                strongSelf.cachedScaleHint = scaleHint;
                if (decodedThisPass) {
                    [strongSelf noteDecodeDurationMs:decodeMs leftEyeMs:leftEyeMs rightEyeMs:rightEyeMs];
                }
                [strongSelf noteCPURenderDurationMs:renderMs requestLatencyMs:requestLatencyMs];
                strongSelf.lastRenderedImage = image;
                strongSelf.lastRenderedSnapshot = [strongSelf statusSnapshot];
                strongSelf.imageView.image = image;
                [[SKIPImmersiveViewerOverlayHost sharedHost] syncImageFromBackend];
                [strongSelf refreshUIState];
                [strongSelf logPerformanceIfNeeded];
            });
            }
        }
    } @catch (NSException *exception) {
        NSString *message = [NSString stringWithFormat:@"Immersive preview render failed: %@",
                             exception.reason ?: exception.name ?: @"unknown exception"];
        SpliceKit_log(@"[ImmersivePreview] render worker exception: %@ %@", exception.name, exception.reason);
        @synchronized (self) {
            self.renderWorkerRunning = NO;
        }
        __weak SpliceKitImmersivePreviewPanel *weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            SpliceKitImmersivePreviewPanel *strongSelf = weakSelf;
            [strongSelf setMessage:message];
        });
    }
}

- (void)scheduleSettledFullQualityRenderFromGeneration:(uint64_t)generation {
    __weak SpliceKitImmersivePreviewPanel *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        SpliceKitImmersivePreviewPanel *strongSelf = weakSelf;
        if (!strongSelf || ![strongSelf isRenderGenerationCurrent:generation]) return;
        [strongSelf scheduleAsyncPreviewRenderInteractive:NO];
    });
}

- (BOOL)refreshPreviewWithError:(NSError **)error {
    [self syncFrameIndexToTimelinePlayheadAndReturnChange:NULL error:nil];
    [self notePreviewRequestInteractive:NO];
    if (self.selectedPath.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"SpliceKitImmersivePreview" code:-22
                                     userInfo:@{NSLocalizedDescriptionKey: @"No immersive BRAW clip loaded"}];
        }
        return NO;
    }
    [self scheduleAsyncPreviewRenderInteractive:NO];
    return YES;
}

- (void)previewDraggedByDelta:(NSPoint)delta ended:(BOOL)ended {
    if (![self.currentViewMode isEqualToString:@"viewport"]) return;

    if (ended) {
        [self scheduleAsyncPreviewRenderInteractive:NO];
        return;
    }

    CGFloat width = MAX(1.0, NSWidth(self.imageView.bounds));
    CGFloat height = MAX(1.0, NSHeight(self.imageView.bounds));
    double yawScale = MAX(60.0, self.fovSlider.doubleValue);
    double pitchScale = MAX(45.0, self.fovSlider.doubleValue * 0.75);

    self.suppressViewportRefresh = YES;
    self.yawSlider.doubleValue = SKIPClamp(self.yawSlider.doubleValue - ((delta.x / width) * yawScale),
                                           self.yawSlider.minValue,
                                           self.yawSlider.maxValue);
    self.pitchSlider.doubleValue = SKIPClamp(self.pitchSlider.doubleValue + ((delta.y / height) * pitchScale),
                                             self.pitchSlider.minValue,
                                             self.pitchSlider.maxValue);
    self.suppressViewportRefresh = NO;

    [self setMessage:@""];
    [self scheduleAsyncPreviewRenderInteractive:YES];
}

- (void)previewScrolledByDeltaY:(CGFloat)deltaY {
    if (![self.currentViewMode isEqualToString:@"viewport"]) return;

    self.suppressViewportRefresh = YES;
    self.fovSlider.doubleValue = SKIPClamp(self.fovSlider.doubleValue - (deltaY * 0.2),
                                           self.fovSlider.minValue,
                                           self.fovSlider.maxValue);
    self.suppressViewportRefresh = NO;

    [self setMessage:@""];
    [self scheduleAsyncPreviewRenderInteractive:YES];
}

- (BOOL)sendCurrentFrameToVisionPro:(NSError **)error {
    if (self.selectedPath.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"SpliceKitImmersivePreview" code:-25
                                     userInfo:@{NSLocalizedDescriptionKey: @"No immersive BRAW clip loaded"}];
        }
        return NO;
    }
    return [[SpliceKitVisionPro shared] pushBRAWFrameAtPath:self.selectedPath
                                                 frameIndex:self.currentFrameIndex
                                                  scaleHint:self.currentScaleHint
                                                      error:error];
}

- (NSDictionary *)performanceSnapshot {
    NSDictionary *panelRendererPerf = [self.imageView rendererPerformanceSnapshot] ?: @{};
    SKIPImmersiveViewerOverlayHost *overlayHost = [SKIPImmersiveViewerOverlayHost sharedHost];
    NSDictionary *overlayRendererPerf = [overlayHost rendererPerformanceSnapshot] ?: @{};
    BOOL viewerVisible = overlayHost.isVisible;
    double avgCpuRenderMs = self.cpuRenderCount > 0 ? (self.totalCpuRenderMs / (double)self.cpuRenderCount) : 0.0;
    double avgCpuRenderIntervalMs = self.cpuRenderIntervalSamples > 0 ? (self.totalCpuRenderIntervalMs / (double)self.cpuRenderIntervalSamples) : 0.0;
    double avgCpuRequestLatencyMs = self.cpuRequestLatencySamples > 0 ? (self.totalCpuRequestLatencyMs / (double)self.cpuRequestLatencySamples) : 0.0;
    NSDictionary *cpuRendererPerf = @{
        @"renderer": @"cpu_fallback",
        @"renderCount": @(self.cpuRenderCount),
        @"lastRenderMs": @(self.lastCpuRenderMs),
        @"avgRenderMs": @(avgCpuRenderMs),
        @"maxRenderMs": @(self.maxCpuRenderMs),
        @"lastRenderIntervalMs": @(self.lastCpuRenderIntervalMs),
        @"avgRenderIntervalMs": @(avgCpuRenderIntervalMs),
        @"maxRenderIntervalMs": @(self.maxCpuRenderIntervalMs),
        @"recentRenderFPS": @(self.rollingCpuRenderFPS),
        @"lastRequestLatencyMs": @(self.lastCpuRequestLatencyMs),
        @"avgRequestLatencyMs": @(avgCpuRequestLatencyMs),
        @"maxRequestLatencyMs": @(self.maxCpuRequestLatencyMs),
    };
    NSDictionary *surfaceRendererPerf = viewerVisible ? overlayRendererPerf : panelRendererPerf;
    BOOL surfaceUsesMetal = [[surfaceRendererPerf[@"renderer"] lowercaseString] isEqualToString:@"metal"];
    NSDictionary *rendererPerf = surfaceUsesMetal ? surfaceRendererPerf : cpuRendererPerf;
    double avgDecodeMs = self.decodeCount > 0 ? (self.totalDecodeMs / (double)self.decodeCount) : 0.0;
    double avgLeftEyeDecodeMs = self.decodeCount > 0 ? (self.totalLeftEyeDecodeMs / (double)self.decodeCount) : 0.0;
    double avgRightEyeDecodeMs = self.decodeCount > 0 ? (self.totalRightEyeDecodeMs / (double)self.decodeCount) : 0.0;
    double avgRequestIntervalMs = self.previewRequestIntervalSamples > 0
        ? (self.totalPreviewRequestIntervalMs / (double)self.previewRequestIntervalSamples)
        : 0.0;
    double decodeRequestCount = (double)(self.decodeCount + self.decodeCacheHitCount);
    double decodeCacheHitRate = decodeRequestCount > 0.0
        ? ((double)self.decodeCacheHitCount / decodeRequestCount)
        : 0.0;

    return @{
        @"overlayVisible": @(viewerVisible),
        @"renderer": rendererPerf[@"renderer"] ?: (self.imageView.rendererReady ? @"metal" : @"cpu_fallback"),
        @"previewRequests": @(self.previewRequestCount),
        @"interactivePreviewRequests": @(self.interactivePreviewRequestCount),
        @"recentPreviewRequestFPS": @(self.rollingRequestFPS),
        @"lastPreviewRequestIntervalMs": @(self.lastPreviewRequestIntervalMs),
        @"avgPreviewRequestIntervalMs": @(avgRequestIntervalMs),
        @"maxPreviewRequestIntervalMs": @(self.maxPreviewRequestIntervalMs),
        @"decodeCount": @(self.decodeCount),
        @"decodeCacheHitCount": @(self.decodeCacheHitCount),
        @"decodeCacheHitRate": @(decodeCacheHitRate),
        @"lastDecodeMs": @(self.lastDecodeMs),
        @"avgDecodeMs": @(avgDecodeMs),
        @"maxDecodeMs": @(self.maxDecodeMs),
        @"lastLeftEyeDecodeMs": @(self.lastLeftEyeDecodeMs),
        @"lastRightEyeDecodeMs": @(self.lastRightEyeDecodeMs),
        @"avgLeftEyeDecodeMs": @(avgLeftEyeDecodeMs),
        @"avgRightEyeDecodeMs": @(avgRightEyeDecodeMs),
        @"cpuRendererPerf": cpuRendererPerf,
        @"panelRendererPerf": panelRendererPerf,
        @"overlayRendererPerf": overlayRendererPerf,
        @"rendererPerf": rendererPerf,
    };
}

- (void)logPerformanceIfNeeded {
    self.lastPerfLogTimestamp = SKIPNow();
}

- (NSDictionary *)statusSnapshot {
    BOOL nativeViewerVisible = SKIPNativeFCP360ViewerIsVisible();
    if (!nativeViewerVisible && self.nativeViewerRestoreState) {
        SKIPSetNativeFCP360ProjectionPatchEnabled(NO);
        NSDictionary *restoreStatus = SKIPRestoreNativeFCP360State(self.nativeViewerRestoreState, @"nativeViewerClosed");
        NSMutableDictionary *updatedStatus = [self.lastNativeViewerStatus mutableCopy] ?: [NSMutableDictionary dictionary];
        updatedStatus[@"restore"] = restoreStatus ?: @{};
        updatedStatus[@"visible"] = @NO;
        self.lastNativeViewerStatus = [updatedStatus copy];
        self.nativeViewerRestoreState = nil;
    }
    return @{
        @"visible": @(self.isVisible),
        @"viewerVisible": @(self.isViewerVisible),
        @"nativeViewerVisible": @(nativeViewerVisible),
        @"nativeRestoreStateActive": @(self.nativeViewerRestoreState != nil),
        @"nativeProjectionPatch": SKIPNativeFCP360ProjectionPatchStats(),
        @"path": self.selectedPath ?: @"",
        @"frameIndex": @([self currentFrameIndex]),
        @"frameCount": @((NSInteger)MAX(0, self.frameSlider.maxValue) + 1),
        @"eyeMode": self.currentEyeMode ?: @"",
        @"viewMode": self.currentViewMode ?: @"",
        @"scaleHint": @(self.currentScaleHint),
        @"yaw": @(self.yawSlider.doubleValue),
        @"pitch": @(self.pitchSlider.doubleValue),
        @"fov": @(self.fovSlider.doubleValue),
        @"decodedWidth": @(self.decodedWidth),
        @"decodedHeight": @(self.decodedHeight),
        @"clipSummary": self.clipSummary ?: @{},
        @"nativeViewer": self.lastNativeViewerStatus ?: @{},
        @"timelineSync": self.lastTimelineSyncSnapshot ?: [self timelineSyncSnapshot],
        @"perf": [self performanceSnapshot],
    };
}

- (void)setFrameIndexValue:(NSInteger)frameIndex {
    NSInteger clamped = MIN(MAX(frameIndex, 0), (NSInteger)self.frameSlider.maxValue);
    self.frameSlider.doubleValue = clamped;
    self.frameField.integerValue = clamped;
}

- (void)setEyeModeIdentifier:(NSString *)identifier {
    for (NSMenuItem *item in self.eyePopup.itemArray) {
        if ([item.representedObject isEqual:identifier]) {
            [self.eyePopup selectItem:item];
            break;
        }
    }
}

- (void)setViewModeIdentifier:(NSString *)identifier {
    for (NSMenuItem *item in self.viewPopup.itemArray) {
        if ([item.representedObject isEqual:identifier]) {
            [self.viewPopup selectItem:item];
            break;
        }
    }
}

- (void)setViewportYaw:(double)yaw pitch:(double)pitch fov:(double)fov {
    self.yawSlider.doubleValue = SKIPClamp(yaw, self.yawSlider.minValue, self.yawSlider.maxValue);
    self.pitchSlider.doubleValue = SKIPClamp(pitch, self.pitchSlider.minValue, self.pitchSlider.maxValue);
    self.fovSlider.doubleValue = SKIPClamp(fov, self.fovSlider.minValue, self.fovSlider.maxValue);
}

- (void)refreshUIState {
    NSDictionary *immersive = [self.clipSummary[@"immersive"] isKindOfClass:[NSDictionary class]] ? self.clipSummary[@"immersive"] : nil;
    NSString *projection = SKIPStringOrEmpty(immersive[@"opticalProjectionKind"]);
    NSString *cameraType = SKIPStringOrEmpty(self.clipSummary[@"cameraType"]);
    if (self.selectedPath.length > 0) {
        self.statusLabel.stringValue = [NSString stringWithFormat:@"%@  %@x%@  %@ fps",
                                        self.selectedPath.lastPathComponent,
                                        self.clipSummary[@"width"] ?: @"?",
                                        self.clipSummary[@"height"] ?: @"?",
                                        self.clipSummary[@"frameRate"] ?: @"?"];
    } else {
        self.statusLabel.stringValue = @"No immersive BRAW loaded";
    }
    self.infoLabel.stringValue = self.selectedPath.length > 0
        ? [NSString stringWithFormat:@"%@  projection=%@  hero=%@",
           cameraType.length > 0 ? cameraType : @"BRAW",
           projection.length > 0 ? projection : @"unknown",
           SKIPStringOrEmpty(immersive[@"heroEye"]).length > 0 ? immersive[@"heroEye"] : @"right"]
        : @"Load a selected immersive BRAW clip or paste a clip path.";
    self.yawValueLabel.stringValue = [NSString stringWithFormat:@"%.0f°", self.yawSlider.doubleValue];
    self.pitchValueLabel.stringValue = [NSString stringWithFormat:@"%.0f°", self.pitchSlider.doubleValue];
    self.fovValueLabel.stringValue = [NSString stringWithFormat:@"%.0f°", self.fovSlider.doubleValue];
}

- (void)setMessage:(NSString *)message {
    self.messageLabel.stringValue = message ?: @"";
}

- (void)loadSelectedClicked:(id)sender {
    NSString *path = SKIPResolveFirstPathFromSelection();
    if (path.length == 0) {
        [self setMessage:@"No immersive BRAW clip is currently selected"];
        return;
    }
    [self setMessage:@"Loading selected immersive BRAW clip..."];
    __weak SpliceKitImmersivePreviewPanel *weakSelf = self;
    [self loadClipAtPathAsync:path completion:^(BOOL ok, NSError *error) {
        SpliceKitImmersivePreviewPanel *strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf setMessage:ok ? @"Loaded selected immersive BRAW clip. Click Refresh Preview to decode a frame."
                                 : (error.localizedDescription ?: @"Failed to load immersive BRAW clip.")];
    }];
}

- (void)loadPathClicked:(id)sender {
    NSString *path = self.pathField.stringValue ?: @"";
    if (path.length == 0) {
        [self setMessage:@"Paste a .braw path first."];
        return;
    }
    [self setMessage:@"Loading immersive BRAW path..."];
    __weak SpliceKitImmersivePreviewPanel *weakSelf = self;
    [self loadClipAtPathAsync:path completion:^(BOOL ok, NSError *error) {
        SpliceKitImmersivePreviewPanel *strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf setMessage:ok ? @"Loaded immersive BRAW path. Click Refresh Preview to decode a frame."
                                 : (error.localizedDescription ?: @"Failed to load immersive BRAW path.")];
    }];
}

- (void)optionChanged:(id)sender {
    NSError *error = nil;
    BOOL ok = [self requestPreviewRenderInteractive:NO error:&error];
    [self setMessage:ok ? @"" : error.localizedDescription];
}

- (void)scaleChanged:(id)sender {
    [self invalidateDecodeCache];
    [self optionChanged:sender];
}

- (void)frameSliderChanged:(id)sender {
    self.frameField.integerValue = (NSInteger)llround(self.frameSlider.doubleValue);
    [self invalidateDecodeCache];
    [self optionChanged:sender];
}

- (void)frameFieldCommitted:(id)sender {
    [self setFrameIndexValue:self.frameField.integerValue];
    [self invalidateDecodeCache];
    [self optionChanged:sender];
}

- (void)viewportChanged:(id)sender {
    if (self.suppressViewportRefresh) return;
    NSError *error = nil;
    BOOL ok = [self requestPreviewRenderInteractive:YES error:&error];
    [self setMessage:ok ? @"" : error.localizedDescription];
}

- (void)refreshClicked:(id)sender {
    [self invalidateDecodeCache];
    NSError *error = nil;
    BOOL ok = [self refreshPreviewWithError:&error];
    [self setMessage:ok ? @"Refreshing preview..." : error.localizedDescription];
}

- (void)sendToVisionProClicked:(id)sender {
    NSError *error = nil;
    BOOL ok = [self sendCurrentFrameToVisionPro:&error];
    [self setMessage:ok ? @"Current frame pushed to Vision Pro runtime." : error.localizedDescription];
}

@end
