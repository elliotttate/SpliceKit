#import "SpliceKitImmersivePreviewPanel.h"
#import "SpliceKitBRAWExports.h"
#import "SpliceKitVisionPro.h"
#import "SpliceKit.h"

static NSDictionary *SKIPError(NSString *message) {
    return @{@"error": message ?: @"unknown error"};
}

NSDictionary *SpliceKit_handleImmersivePreviewShow(NSDictionary *params) {
    (void)params;
    __block NSDictionary *status = nil;
    SpliceKit_executeOnMainThread(^{
        [[SpliceKitImmersivePreviewPanel sharedPanel] showPanel];
        status = [[SpliceKitImmersivePreviewPanel sharedPanel] statusSnapshot];
    });
    return status ?: @{@"visible": @NO};
}

NSDictionary *SpliceKit_handleImmersivePreviewHide(NSDictionary *params) {
    (void)params;
    __block NSDictionary *status = nil;
    SpliceKit_executeOnMainThread(^{
        [[SpliceKitImmersivePreviewPanel sharedPanel] hidePanel];
        status = [[SpliceKitImmersivePreviewPanel sharedPanel] statusSnapshot];
    });
    return status ?: @{@"visible": @NO};
}

NSDictionary *SpliceKit_handleImmersivePreviewStatus(NSDictionary *params) {
    (void)params;
    __block NSDictionary *status = nil;
    SpliceKit_executeOnMainThread(^{
        status = [[SpliceKitImmersivePreviewPanel sharedPanel] statusSnapshot];
    });
    return status ?: @{@"visible": @NO};
}

NSDictionary *SpliceKit_handleImmersivePreviewResolveSelectedPath(NSDictionary *params) {
    (void)params;
    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        NSString *timelinePath = SpliceKit_copyTimelineClipPathNearPlayhead() ?: @"";
        NSString *resolvedPath = timelinePath.length > 0
            ? (SpliceKitBRAWResolveOriginalPathForPublic(timelinePath) ?: @"")
            : @"";
        result = @{
            @"timelinePath": timelinePath,
            @"resolvedPath": resolvedPath,
            @"isBRAW": @([[resolvedPath.pathExtension lowercaseString] isEqualToString:@"braw"]),
        };
    });
    return result ?: SKIPError(@"resolveSelectedPath failed");
}

NSDictionary *SpliceKit_handleImmersivePreviewLoadSelected(NSDictionary *params) {
    (void)params;
    __block NSString *path = nil;
    SpliceKit_executeOnMainThread(^{
        path = SpliceKit_copyTimelineClipPathNearPlayhead() ?: @"";
        if (path.length > 0) {
            path = SpliceKitBRAWResolveOriginalPathForPublic(path) ?: @"";
        }
    });
    if (![path isKindOfClass:[NSString class]] || path.length == 0 ||
        ![[path.pathExtension lowercaseString] isEqualToString:@"braw"]) {
        return SKIPError(@"No immersive BRAW clip is currently selected");
    }

    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block NSDictionary *status = nil;
    [[SpliceKitImmersivePreviewPanel sharedPanel] loadClipAtPathAsync:path completion:^(BOOL ok, NSError *error) {
        status = ok
            ? [[SpliceKitImmersivePreviewPanel sharedPanel] statusSnapshot]
            : SKIPError(error.localizedDescription ?: @"loadSelected failed");
        dispatch_semaphore_signal(sem);
    }];
    long waitResult = dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 30LL * NSEC_PER_SEC));
    if (waitResult != 0) {
        return SKIPError(@"loadSelected timed out");
    }
    return status ?: SKIPError(@"loadSelected failed");
}

NSDictionary *SpliceKit_handleImmersivePreviewLoadPath(NSDictionary *params) {
    NSString *path = [params[@"path"] isKindOfClass:[NSString class]] ? params[@"path"] : @"";
    if (path.length == 0) {
        return SKIPError(@"immersivePreview.loadPath requires {path}");
    }

    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block NSDictionary *status = nil;
    [[SpliceKitImmersivePreviewPanel sharedPanel] loadClipAtPathAsync:path completion:^(BOOL ok, NSError *error) {
        status = ok
            ? [[SpliceKitImmersivePreviewPanel sharedPanel] statusSnapshot]
            : SKIPError(error.localizedDescription ?: @"loadPath failed");
        dispatch_semaphore_signal(sem);
    }];
    long waitResult = dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 30LL * NSEC_PER_SEC));
    if (waitResult != 0) {
        return SKIPError(@"loadPath timed out");
    }
    return status ?: SKIPError(@"loadPath failed");
}

NSDictionary *SpliceKit_handleImmersivePreviewSetFrame(NSDictionary *params) {
    __block NSDictionary *status = nil;
    SpliceKit_executeOnMainThread(^{
        NSNumber *frame = params[@"frameIndex"];
        if (![frame isKindOfClass:[NSNumber class]]) {
            status = SKIPError(@"immersivePreview.setFrame requires {frameIndex}");
            return;
        }
        SpliceKitImmersivePreviewPanel *panel = [SpliceKitImmersivePreviewPanel sharedPanel];
        [panel setFrameIndexValue:frame.integerValue];
        NSError *error = nil;
        BOOL ok = [panel requestPreviewRenderInteractive:NO error:&error];
        status = ok ? panel.statusSnapshot : SKIPError(error.localizedDescription ?: @"setFrame failed");
    });
    return status ?: SKIPError(@"setFrame failed");
}

NSDictionary *SpliceKit_handleImmersivePreviewSetEyeMode(NSDictionary *params) {
    __block NSDictionary *status = nil;
    SpliceKit_executeOnMainThread(^{
        NSString *mode = [params[@"eyeMode"] isKindOfClass:[NSString class]] ? params[@"eyeMode"] : @"";
        if (mode.length == 0) {
            status = SKIPError(@"immersivePreview.setEyeMode requires {eyeMode}");
            return;
        }
        SpliceKitImmersivePreviewPanel *panel = [SpliceKitImmersivePreviewPanel sharedPanel];
        [panel setEyeModeIdentifier:mode];
        NSError *error = nil;
        BOOL ok = [panel requestPreviewRenderInteractive:NO error:&error];
        status = ok ? panel.statusSnapshot : SKIPError(error.localizedDescription ?: @"setEyeMode failed");
    });
    return status ?: SKIPError(@"setEyeMode failed");
}

NSDictionary *SpliceKit_handleImmersivePreviewSetViewMode(NSDictionary *params) {
    __block NSDictionary *status = nil;
    SpliceKit_executeOnMainThread(^{
        NSString *mode = [params[@"viewMode"] isKindOfClass:[NSString class]] ? params[@"viewMode"] : @"";
        if (mode.length == 0) {
            status = SKIPError(@"immersivePreview.setViewMode requires {viewMode}");
            return;
        }
        SpliceKitImmersivePreviewPanel *panel = [SpliceKitImmersivePreviewPanel sharedPanel];
        [panel setViewModeIdentifier:mode];
        NSError *error = nil;
        BOOL ok = [panel requestPreviewRenderInteractive:NO error:&error];
        status = ok ? panel.statusSnapshot : SKIPError(error.localizedDescription ?: @"setViewMode failed");
    });
    return status ?: SKIPError(@"setViewMode failed");
}

NSDictionary *SpliceKit_handleImmersivePreviewSetViewport(NSDictionary *params) {
    __block NSDictionary *status = nil;
    SpliceKit_executeOnMainThread(^{
        SpliceKitImmersivePreviewPanel *panel = [SpliceKitImmersivePreviewPanel sharedPanel];
        NSDictionary *snapshot = [panel statusSnapshot];
        id yawValue = params[@"yaw"];
        id pitchValue = params[@"pitch"];
        id fovValue = params[@"fov"];
        double yaw = [yawValue respondsToSelector:@selector(doubleValue)] ? [yawValue doubleValue]
            : [snapshot[@"yaw"] respondsToSelector:@selector(doubleValue)] ? [snapshot[@"yaw"] doubleValue]
            : 0.0;
        double pitch = [pitchValue respondsToSelector:@selector(doubleValue)] ? [pitchValue doubleValue]
            : [snapshot[@"pitch"] respondsToSelector:@selector(doubleValue)] ? [snapshot[@"pitch"] doubleValue]
            : 0.0;
        double fov = [fovValue respondsToSelector:@selector(doubleValue)] ? [fovValue doubleValue]
            : [snapshot[@"fov"] respondsToSelector:@selector(doubleValue)] ? [snapshot[@"fov"] doubleValue]
            : 110.0;
        [panel setViewportYaw:yaw pitch:pitch fov:fov];
        NSError *error = nil;
        BOOL ok = [panel requestPreviewRenderInteractive:YES error:&error];
        status = ok ? panel.statusSnapshot : SKIPError(error.localizedDescription ?: @"setViewport failed");
    });
    return status ?: SKIPError(@"setViewport failed");
}

NSDictionary *SpliceKit_handleImmersivePreviewRefresh(NSDictionary *params) {
    (void)params;
    __block NSDictionary *status = nil;
    SpliceKit_executeOnMainThread(^{
        NSError *error = nil;
        BOOL ok = [[SpliceKitImmersivePreviewPanel sharedPanel] refreshPreviewWithError:&error];
        status = ok
            ? [[SpliceKitImmersivePreviewPanel sharedPanel] statusSnapshot]
            : SKIPError(error.localizedDescription ?: @"refresh failed");
    });
    return status ?: SKIPError(@"refresh failed");
}

NSDictionary *SpliceKit_handleImmersivePreviewResetPerf(NSDictionary *params) {
    (void)params;
    __block NSDictionary *status = nil;
    SpliceKit_executeOnMainThread(^{
        SpliceKitImmersivePreviewPanel *panel = [SpliceKitImmersivePreviewPanel sharedPanel];
        [panel resetPerformanceCounters];
        status = [panel statusSnapshot];
    });
    return status ?: SKIPError(@"resetPerf failed");
}

NSDictionary *SpliceKit_handleImmersivePreviewSendCurrentFrame(NSDictionary *params) {
    (void)params;
    __block NSDictionary *status = nil;
    SpliceKit_executeOnMainThread(^{
        NSError *error = nil;
        BOOL ok = [[SpliceKitImmersivePreviewPanel sharedPanel] sendCurrentFrameToVisionPro:&error];
        if (!ok) {
            status = SKIPError(error.localizedDescription ?: @"sendCurrentFrame failed");
            return;
        }
        NSMutableDictionary *snapshot = [[[SpliceKitImmersivePreviewPanel sharedPanel] statusSnapshot] mutableCopy];
        snapshot[@"visionPro"] = [[SpliceKitVisionPro shared] stateSnapshot];
        status = [snapshot copy];
    });
    return status ?: SKIPError(@"sendCurrentFrame failed");
}
