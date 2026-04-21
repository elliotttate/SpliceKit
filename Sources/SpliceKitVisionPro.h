//
//  SpliceKitVisionPro.h
//  SpliceKit — live Vision Pro preview via Apple's private
//  ImmersiveVideoToolbox.framework (shipped with Apple Immersive Video Utility).
//
//  IVT is weak-linked from FCP's Helium. We dlopen it from AIVU at first use,
//  then drive IVTMppRemotePreviewSession through its @objc-bridged selectors.
//  No Swift at build time; all interop goes through objc_msgSend.
//

#ifndef SpliceKitVisionPro_h
#define SpliceKitVisionPro_h

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <CoreMedia/CoreMedia.h>

NS_ASSUME_NONNULL_BEGIN

// Posted on the main queue when discovery/connection/stream state changes.
// userInfo: { "isRunning": NSNumber, "isStreaming": NSNumber,
//             "availableClients": NSArray<NSString*>, "activeClients": NSArray<NSString*>,
//             "currentCameraId": NSString, "displayName": NSString,
//             "lastError": NSString? }
extern NSString * const SpliceKitVisionProStateDidChangeNotification;

@interface SpliceKitVisionPro : NSObject

+ (instancetype)shared;

// Is the IVT framework present and loadable on this machine?
@property (nonatomic, readonly) BOOL ivtAvailable;

// Resolved path to IVT (if found).
@property (nonatomic, readonly, copy, nullable) NSString *ivtPath;

// Session lifecycle
- (BOOL)startWithDisplayName:(NSString *)displayName error:(NSError **)error;
- (void)stop;
@property (nonatomic, readonly) BOOL isRunning;
@property (nonatomic, readonly) BOOL isStreaming;

// Peer queries (String display names — Bonjour-discovered and actively-connected)
- (NSArray<NSString *> *)availableClientNames;
- (NSArray<NSString *> *)activeClientNames;

// Connect / disconnect. Error out-pointer is filled on failure.
- (BOOL)addClientWithHostName:(NSString *)hostName error:(NSError **)error;
- (BOOL)addClientWithIpAddress:(NSString *)ipAddress error:(NSError **)error;
- (void)removeClientWithHostName:(NSString *)hostName;
- (void)removeClientWithIpAddress:(NSString *)ipAddress;

// IVTSession metadata context
- (BOOL)loadAimeFileURL:(NSURL *)aimeURL error:(NSError **)error;
- (BOOL)sendAimeFileURL:(NSURL *)aimeURL error:(NSError **)error;
- (BOOL)sendLoadedAimeWithError:(NSError **)error;      // pushes the currently-loaded static metadata
- (BOOL)exportAimeFileURL:(NSURL *)aimeURL error:(NSError **)error;
- (BOOL)sendMaskFileURL:(NSURL *)maskURL error:(NSError **)error;  // push camera mask to headset

// Session tuning
- (void)setMaxNumberOfClients:(NSInteger)maxClients;

- (BOOL)setCameraCalibrationUSDZForCameraId:(NSString *)cameraId fileURL:(NSURL *)fileURL error:(NSError **)error;
- (BOOL)setCameraCalibrationILPDForCameraId:(NSString *)cameraId fileURL:(NSURL *)fileURL error:(NSError **)error;
- (BOOL)setCameraCalibrationJSONForCameraId:(NSString *)cameraId json:(NSString *)json error:(NSError **)error;
- (BOOL)removeCameraWithId:(NSString *)cameraId;

// Current camera (matches one of the cameras defined in the IVTSession static metadata).
- (NSString * _Nullable)currentCameraId;
- (void)setCurrentCameraId:(NSString * _Nullable)cameraId;

// Push a stereoscopic frame (left/right eye CVPixelBuffer pair).
// colorPrimaries / transferFunction / yCbCrMatrix are indices into IVT's public enums:
//   colorPrimaries:    0=Rec709, 1=Rec2020, 2=P3D65
//   transferFunction:  0=Rec709, 1=PQ, 2=HLG, 3=sRGB
//   yCbCrMatrix:       0=Rec709, 1=Rec2020
- (BOOL)pushFrameLeft:(CVPixelBufferRef)leftEye
                right:(CVPixelBufferRef)rightEye
                  pts:(CMTime)pts
             duration:(CMTime)duration
       colorPrimaries:(NSInteger)colorPrimaries
     transferFunction:(NSInteger)transferFunction
          yCbCrMatrix:(NSInteger)yCbCrMatrix
                error:(NSError **)error;

// Snapshot of state for RPC consumers.
- (NSDictionary<NSString *, id> *)stateSnapshot;

// Poll interval for the state-watchdog timer (seconds). Default: 0.5.
@property (nonatomic) NSTimeInterval stateRefreshInterval;

@end

// RPC dispatch entrypoint for SpliceKitServer.
NSDictionary *SpliceKit_handleVisionPro(NSString *method, NSDictionary *params);

NS_ASSUME_NONNULL_END

#endif /* SpliceKitVisionPro_h */
