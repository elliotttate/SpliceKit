//
//  SpliceKitVisionPro.m
//  SpliceKit — live Vision Pro preview via ImmersiveVideoToolbox.framework.
//
//  Overview
//  --------
//  IVT ships as a binary-only, Swift-native framework inside Apple Immersive
//  Video Utility. Its core session types (IVTSession, IVTMppRemotePreviewSession,
//  VideoFrame) extend NSObject and expose @objc-bridged selectors for every
//  method we need. We dlopen IVT from AIVU's embedded framework path, look up
//  the Swift classes with `_TtC21ImmersiveVideoToolbox<ClassName>` mangling,
//  and drive them through objc_msgSend — no Swift compiler involved.
//
//  Discovery is Bonjour (`_ivtpreviewclient._tcp`); frames are stereoscopic
//  CVPixelBuffer pairs wrapped as VideoFrame and pushed into the session. A
//  low-cost NSTimer polls `availableClientNames` / `activeClientNames` /
//  `isStreaming` and broadcasts a change notification so the UI and MCP layer
//  can stay in sync without wiring up Combine observers through the bridge.
//

#import "SpliceKitVisionPro.h"
#import "SpliceKit.h"
#import <dlfcn.h>
#import <objc/runtime.h>
#import <objc/message.h>

NSString * const SpliceKitVisionProStateDidChangeNotification =
    @"SpliceKitVisionProStateDidChangeNotification";

#pragma mark - Swift class mangling

// Swift class names when accessed from the ObjC runtime follow `_TtC<N><ModuleName><M><ClassName>`
// where N = length of module name, M = length of class name.
// Module "ImmersiveVideoToolbox" has length 21.
static NSString *const kClsSession             = @"_TtC21ImmersiveVideoToolbox26IVTMppRemotePreviewSession";
static NSString *const kClsIVTSession          = @"_TtC21ImmersiveVideoToolbox10IVTSession";
static NSString *const kClsVideoFrame          = @"_TtC21ImmersiveVideoToolbox10VideoFrame";

#pragma mark - objc_msgSend helpers (typed)

// ARC / init-via-cast-pointer note:
//   We intentionally do NOT mark these typedefs with ns_returns_retained. Swift's
//   @objc init returns the same `self` it received from `alloc` (ObjC convention).
//   With ns_returns_retained, ARC skips its assignment-retain and then its
//   assignment-release fires on the SAME pointer the caller now owns, freeing
//   the just-initialized object before we stash it anywhere. The unannotated
//   version does an extra retain/release pair during the assignment — harmless,
//   balances at scope exit, and leaves a valid +1 owned by the caller.
typedef id      (*MsgSend_id_id)(id, SEL, id);
typedef id      (*MsgSend_init_id_long)(id, SEL, id, NSInteger);
typedef id      (*MsgSend_id_id_idp)(id, SEL, id, id *);
typedef void    (*MsgSend_void)(id, SEL);
typedef void    (*MsgSend_void_id)(id, SEL, id);
typedef id      (*MsgSend_id_void)(id, SEL);
typedef id      (*MsgSend_init_buf_buf)(id, SEL, CVPixelBufferRef, CVPixelBufferRef);
typedef void    (*MsgSend_push_frame)(id, SEL, id, CMTime, CMTime);
typedef void    (*MsgSend_void_long)(id, SEL, NSInteger);
typedef char    (*MsgSend_bool_id_idp)(id, SEL, id, id *);
typedef BOOL    (*MsgSend_BOOL_void)(id, SEL);

// Default number of clients the Mpp session will accept. The Swift init uses
// this as an upper bound — 0 silently rejects every headset that tries to
// connect. 4 is generous for a directing-room workflow without being wasteful.
static const NSInteger kSKVPDefaultMaxClients = 4;

#pragma mark - SpliceKitVisionPro

@interface SpliceKitVisionPro () {
    void *_ivtHandle;
    Class _sessionClass;
    Class _ivtSessionClass;
    Class _videoFrameClass;
}
// Use atomic properties for session/ivtSession so a read from the poll timer
// can't tear with a nil-out from another queue. Even with atomic, we still
// load into a local strong ref at the top of pollTick so the session can't be
// released mid-tick while we're calling methods on it.
@property (atomic, strong, nullable) id session;            // IVTMppRemotePreviewSession
@property (atomic, strong, nullable) id ivtSession;         // IVTSession
@property (nonatomic, copy, nullable) NSString *displayName;
@property (nonatomic, strong, nullable) dispatch_source_t pollSource;
@property (nonatomic) BOOL lastIsStreaming;
@property (nonatomic, strong) NSArray<NSString *> *lastAvailable;
@property (nonatomic, strong) NSArray<NSString *> *lastActive;
@property (nonatomic, copy, nullable) NSString *lastErrorMessage;
@property (nonatomic, copy, nullable) NSString *resolvedIvtPath;
@property (nonatomic, strong) dispatch_queue_t pollQueue;
@end

@implementation SpliceKitVisionPro

+ (instancetype)shared {
    static SpliceKitVisionPro *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [[self alloc] init]; });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _stateRefreshInterval = 0.5;
    _lastAvailable = @[];
    _lastActive = @[];
    _pollQueue = dispatch_queue_create("com.splicekit.visionpro.poll", DISPATCH_QUEUE_SERIAL);
    return self;
}

- (NSString * _Nullable)ivtPath {
    return self.resolvedIvtPath;
}

#pragma mark - dlopen

// Candidate locations, in priority order. We prefer AIVU's bundle because
// that's the only officially-supported path today. Users can symlink IVT
// elsewhere if they want to skip AIVU.
static NSArray<NSString *> *IVTCandidatePaths(void) {
    return @[
        @"/Applications/Apple Immersive Video Utility.app/Contents/Frameworks/ImmersiveVideoToolbox.framework/Versions/A/ImmersiveVideoToolbox",
        @"/Applications/Apple Immersive Video Utility.app/Contents/Frameworks/ImmersiveVideoToolbox.framework/ImmersiveVideoToolbox",
        @"/Library/Frameworks/ImmersiveVideoToolbox.framework/Versions/A/ImmersiveVideoToolbox",
        [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Frameworks/ImmersiveVideoToolbox.framework/Versions/A/ImmersiveVideoToolbox"],
    ];
}

- (BOOL)loadIVTIfNeededWithError:(NSError **)error {
    if (_ivtHandle && _sessionClass && _ivtSessionClass && _videoFrameClass) return YES;

    NSString *resolved = nil;
    for (NSString *candidate in IVTCandidatePaths()) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:candidate]) {
            resolved = candidate;
            break;
        }
    }
    if (!resolved) {
        if (error) {
            *error = [NSError errorWithDomain:@"SpliceKitVisionPro" code:-1
                                     userInfo:@{NSLocalizedDescriptionKey: @"ImmersiveVideoToolbox.framework not found. Install Apple Immersive Video Utility from the Mac App Store."}];
        }
        return NO;
    }

    // RTLD_NOLOAD first — if FCP itself already pulled it in (Helium weak-links it),
    // reuse the existing image. Otherwise load fresh.
    void *h = dlopen(resolved.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL | RTLD_NOLOAD);
    if (!h) h = dlopen(resolved.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL);
    if (!h) {
        NSString *err = @(dlerror() ?: "dlopen failed");
        if (error) {
            *error = [NSError errorWithDomain:@"SpliceKitVisionPro" code:-2
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"dlopen %@: %@", resolved, err]}];
        }
        return NO;
    }

    _ivtHandle = h;
    _resolvedIvtPath = [resolved copy];

    _sessionClass    = NSClassFromString(kClsSession);
    _ivtSessionClass = NSClassFromString(kClsIVTSession);
    _videoFrameClass = NSClassFromString(kClsVideoFrame);

    if (!_sessionClass || !_ivtSessionClass || !_videoFrameClass) {
        if (error) {
            *error = [NSError errorWithDomain:@"SpliceKitVisionPro" code:-3
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"IVT loaded but class lookup failed (session=%p ivt=%p frame=%p)",
                                                                             (void *)_sessionClass, (void *)_ivtSessionClass, (void *)_videoFrameClass]}];
        }
        return NO;
    }
    return YES;
}

- (BOOL)ivtAvailable {
    for (NSString *candidate in IVTCandidatePaths()) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:candidate]) return YES;
    }
    return NO;
}

#pragma mark - Lifecycle

- (BOOL)startWithDisplayName:(NSString *)displayName error:(NSError **)error {
    if (self.session) return YES;
    if (![self loadIVTIfNeededWithError:error]) return NO;

    NSString *name = displayName.length > 0 ? displayName : @"SpliceKit";
    SEL initSel = @selector(initWithDisplayName:maxNumberOfClients:);

    // Must use a single variable for alloc + init: ARC sees the reassignment
    // and balances retains. Two separate strong locals (alloced/session) would
    // each claim +1 on the same object, double-releasing at scope exit.
    id session = [_sessionClass alloc];
    if (!session) {
        if (error) *error = [NSError errorWithDomain:@"SpliceKitVisionPro" code:-4
                                            userInfo:@{NSLocalizedDescriptionKey: @"Failed to alloc IVTMppRemotePreviewSession"}];
        return NO;
    }
    session = ((MsgSend_init_id_long)objc_msgSend)(session, initSel, name, kSKVPDefaultMaxClients);
    if (!session) {
        self.lastErrorMessage = @"IVTMppRemotePreviewSession init returned nil";
        if (error) *error = [NSError errorWithDomain:@"SpliceKitVisionPro" code:-5
                                            userInfo:@{NSLocalizedDescriptionKey: self.lastErrorMessage}];
        return NO;
    }

    // Build a fresh IVTSession so we have a place to pin static metadata + cameras.
    id ivt = [[_ivtSessionClass alloc] init];
    if (!ivt) {
        if (error) *error = [NSError errorWithDomain:@"SpliceKitVisionPro" code:-6
                                            userInfo:@{NSLocalizedDescriptionKey: @"IVTSession init returned nil"}];
        return NO;
    }
    ((MsgSend_void_id)objc_msgSend)(session, @selector(setIvtSession:), ivt);

    // Kick off Bonjour discovery.
    ((MsgSend_void)objc_msgSend)(session, @selector(start));

    self.session = session;
    self.ivtSession = ivt;
    self.displayName = name;
    self.lastErrorMessage = nil;

    [self startPollTimer];
    [self broadcastStateChange];
    return YES;
}

- (void)stop {
    // Take a local strong ref so the session object can't go away mid-stop.
    id session = self.session;
    [self cancelPollSource];
    if (session) {
        ((MsgSend_void)objc_msgSend)(session, @selector(stop));
    }
    self.session = nil;
    self.ivtSession = nil;
    self.lastActive = @[];
    self.lastAvailable = @[];
    self.lastIsStreaming = NO;
    [self broadcastStateChange];
}

- (void)cancelPollSource {
    if (self.pollSource) {
        dispatch_source_cancel(self.pollSource);
        self.pollSource = nil;
    }
}

- (BOOL)isRunning { return self.session != nil; }
- (BOOL)isStreaming { return self.lastIsStreaming; }

#pragma mark - Client queries

- (NSArray<NSString *> *)fetchNamesWithSelector:(SEL)sel {
    id session = self.session;  // hoist, see pollTick for rationale
    if (!session) return @[];
    id result = ((MsgSend_id_void)objc_msgSend)(session, sel);
    if ([result isKindOfClass:[NSArray class]]) return result;
    return @[];
}

- (NSArray<NSString *> *)availableClientNames {
    return [self fetchNamesWithSelector:@selector(availableClientNames)];
}

- (NSArray<NSString *> *)activeClientNames {
    return [self fetchNamesWithSelector:@selector(activeClientNames)];
}

#pragma mark - Connect / Disconnect

- (BOOL)addClientWithHostName:(NSString *)hostName error:(NSError **)error {
    id session = self.session;
    if (!session) { [self fillStartError:error]; return NO; }
    id nsError = nil;
    BOOL ok = ((MsgSend_bool_id_idp)objc_msgSend)(session,
                                                  @selector(addClientWithDestinationHostName:error:),
                                                  hostName, &nsError) != 0;
    if (!ok) {
        NSString *msg = [nsError isKindOfClass:[NSError class]] ? [(NSError *)nsError localizedDescription]
                                                                : [NSString stringWithFormat:@"addClient(host=%@) failed", hostName];
        self.lastErrorMessage = msg;
        if (error) {
            *error = [nsError isKindOfClass:[NSError class]] ? (NSError *)nsError
                  : [NSError errorWithDomain:@"SpliceKitVisionPro" code:-10
                                    userInfo:@{NSLocalizedDescriptionKey: msg}];
        }
    }
    return ok;
}

- (BOOL)addClientWithIpAddress:(NSString *)ipAddress error:(NSError **)error {
    // IVT only exposes `addClientWithDestinationHostName:error:` to ObjC;
    // it accepts dotted-quad IPs just fine since NWEndpoint resolves either form.
    return [self addClientWithHostName:ipAddress error:error];
}

- (void)removeClientWithHostName:(NSString *)hostName {
    id session = self.session;
    if (!session) return;
    ((MsgSend_void_id)objc_msgSend)(session, @selector(removeClientWithDestinationHostName:), hostName);
}

- (void)removeClientWithIpAddress:(NSString *)ipAddress {
    id session = self.session;
    if (!session) return;
    ((MsgSend_void_id)objc_msgSend)(session, @selector(removeClientWithDestinationIpAddress:), ipAddress);
}

#pragma mark - AIME / metadata

- (BOOL)loadAimeFileURL:(NSURL *)aimeURL error:(NSError **)error {
    id ivt = self.ivtSession;
    if (!ivt) { [self fillStartError:error]; return NO; }
    id nsError = nil;
    BOOL ok = ((MsgSend_bool_id_idp)objc_msgSend)(ivt,
                                                  @selector(loadStaticMetadataWithAimeUrl:error:),
                                                  aimeURL, &nsError) != 0;
    if (!ok) {
        self.lastErrorMessage = [nsError isKindOfClass:[NSError class]]
            ? [(NSError *)nsError localizedDescription]
            : @"loadAime failed";
        if (error) *error = nsError;
    }
    return ok;
}

- (BOOL)exportAimeFileURL:(NSURL *)aimeURL error:(NSError **)error {
    id ivt = self.ivtSession;
    if (!ivt) { [self fillStartError:error]; return NO; }
    id nsError = nil;
    BOOL ok = ((MsgSend_bool_id_idp)objc_msgSend)(ivt,
                                                  @selector(exportStaticMetadataWithAimeUrl:error:),
                                                  aimeURL, &nsError) != 0;
    if (!ok && error) *error = nsError;
    return ok;
}

- (BOOL)sendAimeFileURL:(NSURL *)aimeURL error:(NSError **)error {
    id session = self.session;
    if (!session) { [self fillStartError:error]; return NO; }
    ((MsgSend_void_id)objc_msgSend)(session, @selector(sendAimeWithUrl:), aimeURL);
    return YES;
}

- (BOOL)sendMaskFileURL:(NSURL *)maskURL error:(NSError **)error {
    id session = self.session;
    if (!session) { [self fillStartError:error]; return NO; }
    ((MsgSend_void_id)objc_msgSend)(session, @selector(sendMaskWithUrl:), maskURL);
    return YES;
}

- (void)setMaxNumberOfClients:(NSInteger)maxClients {
    id session = self.session;
    if (!session) return;
    ((MsgSend_void_long)objc_msgSend)(session, @selector(setMaxNumberOfClients:), maxClients);
}

- (BOOL)sendLoadedAimeWithError:(NSError **)error {
    if (!self.session || !self.ivtSession) { [self fillStartError:error]; return NO; }
    // The Swift API accepts a staticMetadata object via sendAime(staticMetadata:).
    // The @objc bridge only exposes sendAimeWithUrl:, so round-trip through the
    // session's exported aime in a temp file.
    NSString *temp = [NSTemporaryDirectory() stringByAppendingPathComponent:
                      [NSString stringWithFormat:@"splicekit-vp-%u.aime", arc4random_uniform(UINT32_MAX)]];
    NSURL *tmpURL = [NSURL fileURLWithPath:temp];
    NSError *exportError = nil;
    if (![self exportAimeFileURL:tmpURL error:&exportError]) {
        if (error) *error = exportError;
        return NO;
    }
    BOOL sent = [self sendAimeFileURL:tmpURL error:error];
    [[NSFileManager defaultManager] removeItemAtURL:tmpURL error:NULL];
    return sent;
}

- (BOOL)setCameraCalibrationUSDZForCameraId:(NSString *)cameraId fileURL:(NSURL *)fileURL error:(NSError **)error {
    id ivt = self.ivtSession;
    if (!ivt) { [self fillStartError:error]; return NO; }
    id nsError = nil;
    typedef char (*Fn)(id, SEL, id, id, id *);
    BOOL ok = ((Fn)objc_msgSend)(ivt,
                                 @selector(setCameraCalibrationWithCameraId:usdzFile:error:),
                                 cameraId, fileURL, &nsError) != 0;
    if (!ok && error) *error = nsError;
    return ok;
}

- (BOOL)setCameraCalibrationILPDForCameraId:(NSString *)cameraId fileURL:(NSURL *)fileURL error:(NSError **)error {
    id ivt = self.ivtSession;
    if (!ivt) { [self fillStartError:error]; return NO; }
    id nsError = nil;
    typedef char (*Fn)(id, SEL, id, id, id *);
    BOOL ok = ((Fn)objc_msgSend)(ivt,
                                 @selector(setCameraCalibrationWithCameraId:ilpdUrl:error:),
                                 cameraId, fileURL, &nsError) != 0;
    if (!ok && error) *error = nsError;
    return ok;
}

- (BOOL)setCameraCalibrationJSONForCameraId:(NSString *)cameraId json:(NSString *)json error:(NSError **)error {
    id ivt = self.ivtSession;
    if (!ivt) { [self fillStartError:error]; return NO; }
    id nsError = nil;
    typedef char (*Fn)(id, SEL, id, id, id *);
    BOOL ok = ((Fn)objc_msgSend)(ivt,
                                 @selector(setCameraCalibrationWithCameraId:descriptionJson:error:),
                                 cameraId, json, &nsError) != 0;
    if (!ok && error) *error = nsError;
    return ok;
}

- (BOOL)removeCameraWithId:(NSString *)cameraId {
    id ivt = self.ivtSession;
    if (!ivt) return NO;
    ((MsgSend_void_id)objc_msgSend)(ivt, @selector(removeCameraWithCameraId:), cameraId);
    return YES;
}

- (NSString * _Nullable)currentCameraId {
    id session = self.session;
    if (!session) return nil;
    id result = ((MsgSend_id_void)objc_msgSend)(session, @selector(currentCameraId));
    return [result isKindOfClass:[NSString class]] ? result : nil;
}

- (void)setCurrentCameraId:(NSString * _Nullable)cameraId {
    id session = self.session;
    if (!session) return;
    ((MsgSend_void_id)objc_msgSend)(session, @selector(setCurrentCameraId:), cameraId ?: @"");
}

#pragma mark - Frame push

- (BOOL)pushFrameLeft:(CVPixelBufferRef)leftEye
                right:(CVPixelBufferRef)rightEye
                  pts:(CMTime)pts
             duration:(CMTime)duration
       colorPrimaries:(NSInteger)colorPrimaries
     transferFunction:(NSInteger)transferFunction
          yCbCrMatrix:(NSInteger)yCbCrMatrix
                error:(NSError **)error {
    id session = self.session;
    if (!session) { [self fillStartError:error]; return NO; }
    if (!leftEye || !rightEye) {
        if (error) *error = [NSError errorWithDomain:@"SpliceKitVisionPro" code:-20
                                            userInfo:@{NSLocalizedDescriptionKey: @"pushFrame requires non-null left+right pixel buffers"}];
        return NO;
    }

    // Single variable for alloc + init, see startWithDisplayName for the rationale.
    id frame = [_videoFrameClass alloc];
    frame = ((MsgSend_init_buf_buf)objc_msgSend)(frame, @selector(initWithLeftEye:rightEye:), leftEye, rightEye);
    if (!frame) {
        if (error) *error = [NSError errorWithDomain:@"SpliceKitVisionPro" code:-21
                                            userInfo:@{NSLocalizedDescriptionKey: @"VideoFrame init returned nil"}];
        return NO;
    }
    ((MsgSend_void_long)objc_msgSend)(frame, @selector(setColorPrimaries:), colorPrimaries);
    ((MsgSend_void_long)objc_msgSend)(frame, @selector(setTransferFunction:), transferFunction);
    ((MsgSend_void_long)objc_msgSend)(frame, @selector(setYCbCrMatrixOption:), yCbCrMatrix);

    ((MsgSend_push_frame)objc_msgSend)(session, @selector(pushWithVideoFrame:pts:duration:), frame, pts, duration);
    return YES;
}

#pragma mark - State polling + snapshots

- (void)setStateRefreshInterval:(NSTimeInterval)interval {
    _stateRefreshInterval = MAX(0.1, interval);
    if (self.pollSource) [self startPollTimer];  // restart with new interval
}

- (void)startPollTimer {
    // Use a GCD dispatch source instead of NSTimer so we're thread-agnostic
    // and cancellation is race-safe. The poll queue is a serial GCD queue
    // dedicated to this instance — cancellation is synchronous with respect
    // to the queue, so pollTick can't straddle a stop().
    [self cancelPollSource];
    dispatch_source_t src = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.pollQueue);
    uint64_t intervalNsec = (uint64_t)(self.stateRefreshInterval * NSEC_PER_SEC);
    dispatch_source_set_timer(src,
                              dispatch_time(DISPATCH_TIME_NOW, intervalNsec),
                              intervalNsec,
                              intervalNsec / 4);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(src, ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        [strongSelf pollTick];
    });
    self.pollSource = src;
    dispatch_resume(src);
}

- (void)pollTick {
    // Hoist the session ivar into a single strong local so it can't be torn
    // down by another queue mid-tick. This is the fix for a UAF we saw:
    // repeated `self.session` reads during the tick could race with `stop`
    // and end up calling objc_msgSend on a freed object.
    id session = self.session;
    if (!session) return;

    BOOL streaming = ((MsgSend_BOOL_void)objc_msgSend)(session, @selector(isStreaming));
    NSArray *avail = ((MsgSend_id_void)objc_msgSend)(session, @selector(availableClientNames));
    NSArray *active = ((MsgSend_id_void)objc_msgSend)(session, @selector(activeClientNames));
    if (![avail isKindOfClass:[NSArray class]]) avail = @[];
    if (![active isKindOfClass:[NSArray class]]) active = @[];

    BOOL changed = NO;
    if (streaming != self.lastIsStreaming) { self.lastIsStreaming = streaming; changed = YES; }
    if (![self.lastAvailable isEqualToArray:avail]) { self.lastAvailable = avail; changed = YES; }
    if (![self.lastActive isEqualToArray:active])   { self.lastActive = active; changed = YES; }
    if (changed) [self broadcastStateChange];
}

- (void)broadcastStateChange {
    NSDictionary *info = [self stateSnapshot];
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter]
            postNotificationName:SpliceKitVisionProStateDidChangeNotification
                          object:self
                        userInfo:info];
    });
}

- (NSDictionary<NSString *, id> *)stateSnapshot {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"ivtAvailable"] = @(self.ivtAvailable);
    d[@"ivtPath"] = self.resolvedIvtPath ?: [NSNull null];
    d[@"isRunning"] = @(self.isRunning);
    d[@"isStreaming"] = @(self.lastIsStreaming);
    d[@"displayName"] = self.displayName ?: @"";
    d[@"availableClients"] = self.lastAvailable ?: @[];
    d[@"activeClients"] = self.lastActive ?: @[];
    d[@"currentCameraId"] = self.currentCameraId ?: @"";
    if (self.lastErrorMessage) d[@"lastError"] = self.lastErrorMessage;
    return d;
}

- (void)fillStartError:(NSError **)error {
    if (error) {
        *error = [NSError errorWithDomain:@"SpliceKitVisionPro" code:-100
                                 userInfo:@{NSLocalizedDescriptionKey: @"Vision Pro session not started. Call start first."}];
    }
}

@end

#pragma mark - RPC dispatch

static NSDictionary *vpErrorDict(NSError *err, NSString *fallback) {
    return @{ @"error": err.localizedDescription ?: fallback ?: @"unknown error" };
}

NSDictionary *SpliceKit_handleVisionPro(NSString *method, NSDictionary *params) {
    SpliceKitVisionPro *vp = [SpliceKitVisionPro shared];

    if ([method isEqualToString:@"visionpro.status"]) {
        return [vp stateSnapshot];
    }
    if ([method isEqualToString:@"visionpro.start"]) {
        NSString *name = params[@"displayName"];
        NSError *err = nil;
        BOOL ok = [vp startWithDisplayName:name error:&err];
        if (!ok) return vpErrorDict(err, @"start failed");
        return [vp stateSnapshot];
    }
    if ([method isEqualToString:@"visionpro.stop"]) {
        [vp stop];
        return [vp stateSnapshot];
    }
    if ([method isEqualToString:@"visionpro.listClients"]) {
        return @{
            @"available": [vp availableClientNames],
            @"active":    [vp activeClientNames],
        };
    }
    if ([method isEqualToString:@"visionpro.addClient"]) {
        NSString *host = params[@"host"];
        NSString *ip = params[@"ip"];
        NSError *err = nil;
        BOOL ok = NO;
        if (ip.length) ok = [vp addClientWithIpAddress:ip error:&err];
        else if (host.length) ok = [vp addClientWithHostName:host error:&err];
        else return @{ @"error": @"visionpro.addClient requires {host} or {ip}" };
        if (!ok) return vpErrorDict(err, @"addClient failed");
        return [vp stateSnapshot];
    }
    if ([method isEqualToString:@"visionpro.removeClient"]) {
        NSString *host = params[@"host"];
        NSString *ip = params[@"ip"];
        if (ip.length) [vp removeClientWithIpAddress:ip];
        else if (host.length) [vp removeClientWithHostName:host];
        else return @{ @"error": @"visionpro.removeClient requires {host} or {ip}" };
        return [vp stateSnapshot];
    }
    if ([method isEqualToString:@"visionpro.loadAime"]) {
        NSString *path = params[@"path"];
        if (!path.length) return @{ @"error": @"visionpro.loadAime requires {path}" };
        NSError *err = nil;
        BOOL ok = [vp loadAimeFileURL:[NSURL fileURLWithPath:path] error:&err];
        if (!ok) return vpErrorDict(err, @"loadAime failed");
        return [vp stateSnapshot];
    }
    if ([method isEqualToString:@"visionpro.sendAime"]) {
        NSString *path = params[@"path"];
        NSError *err = nil;
        BOOL ok;
        if (path.length) ok = [vp sendAimeFileURL:[NSURL fileURLWithPath:path] error:&err];
        else             ok = [vp sendLoadedAimeWithError:&err];
        if (!ok) return vpErrorDict(err, @"sendAime failed");
        return [vp stateSnapshot];
    }
    if ([method isEqualToString:@"visionpro.exportAime"]) {
        NSString *path = params[@"path"];
        if (!path.length) return @{ @"error": @"visionpro.exportAime requires {path}" };
        NSError *err = nil;
        BOOL ok = [vp exportAimeFileURL:[NSURL fileURLWithPath:path] error:&err];
        if (!ok) return vpErrorDict(err, @"exportAime failed");
        return @{ @"path": path };
    }
    if ([method isEqualToString:@"visionpro.setCurrentCamera"]) {
        NSString *cameraId = params[@"cameraId"];
        [vp setCurrentCameraId:cameraId];
        return [vp stateSnapshot];
    }
    if ([method isEqualToString:@"visionpro.setCameraCalibration"]) {
        NSString *cameraId = params[@"cameraId"];
        NSString *usdz = params[@"usdzPath"];
        NSString *ilpd = params[@"ilpdPath"];
        NSString *json = params[@"json"];
        if (!cameraId.length) return @{ @"error": @"visionpro.setCameraCalibration requires {cameraId}" };
        NSError *err = nil;
        BOOL ok = NO;
        if (usdz.length) ok = [vp setCameraCalibrationUSDZForCameraId:cameraId fileURL:[NSURL fileURLWithPath:usdz] error:&err];
        else if (ilpd.length) ok = [vp setCameraCalibrationILPDForCameraId:cameraId fileURL:[NSURL fileURLWithPath:ilpd] error:&err];
        else if (json.length) ok = [vp setCameraCalibrationJSONForCameraId:cameraId json:json error:&err];
        else return @{ @"error": @"provide one of {usdzPath, ilpdPath, json}" };
        if (!ok) return vpErrorDict(err, @"setCameraCalibration failed");
        return [vp stateSnapshot];
    }
    if ([method isEqualToString:@"visionpro.removeCamera"]) {
        NSString *cameraId = params[@"cameraId"];
        if (!cameraId.length) return @{ @"error": @"visionpro.removeCamera requires {cameraId}" };
        [vp removeCameraWithId:cameraId];
        return [vp stateSnapshot];
    }
    if ([method isEqualToString:@"visionpro.sendMask"]) {
        NSString *path = params[@"path"];
        if (!path.length) return @{ @"error": @"visionpro.sendMask requires {path}" };
        NSError *err = nil;
        BOOL ok = [vp sendMaskFileURL:[NSURL fileURLWithPath:path] error:&err];
        if (!ok) return vpErrorDict(err, @"sendMask failed");
        return [vp stateSnapshot];
    }
    if ([method isEqualToString:@"visionpro.setMaxClients"]) {
        NSNumber *n = params[@"max"];
        if (![n isKindOfClass:[NSNumber class]]) return @{ @"error": @"visionpro.setMaxClients requires {max: int}" };
        [vp setMaxNumberOfClients:n.integerValue];
        return [vp stateSnapshot];
    }
    return @{ @"error": [NSString stringWithFormat:@"unknown visionpro method: %@", method] };
}
