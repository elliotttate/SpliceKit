// SpliceKitBRAWAdjustmentInfo.h — per-clip BRAW RAW adjustment model.
//
// Mirrors the shape of FFProResRAWConversionAdjustmentInfo so FCP's XML/library
// serialization round-trips cleanly. Stored inside FFAsset.rawProcessorSettings
// under the "com.splicekit.braw.rawprocessor" key (same key the VT-shim path
// wrote under previously, so existing libraries with BRAW settings keep working).
//
// The BRAW SDK host bridge in SpliceKitBRAW.mm reads settings via
// SpliceKitBRAW_CopyRAWSettingsForPath(path) and applies them per decode job.
// This class is a typed façade over the untyped dictionary the cache stores.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Canonical settings-dict keys. Match the keys SpliceKitBRAW.mm already
// expects when iterating rawSettings dictionaries.
//
// FRAME attributes (per-frame, animatable):
extern NSString *const SpliceKitBRAWKeyISO;              // u32
extern NSString *const SpliceKitBRAWKeyKelvin;           // u32 (2500..10000)
extern NSString *const SpliceKitBRAWKeyTint;             // s16 (-50..50)
extern NSString *const SpliceKitBRAWKeyExposure;         // float (-5.0..+5.0 stops)
extern NSString *const SpliceKitBRAWKeyAnalogGain;       // float
//
// CLIP attributes (per-clip, tone curve — gated on Gamma=Custom):
extern NSString *const SpliceKitBRAWKeySaturation;       // float 0..2
extern NSString *const SpliceKitBRAWKeyContrast;         // float 0..2
extern NSString *const SpliceKitBRAWKeyHighlights;       // float -1..1
extern NSString *const SpliceKitBRAWKeyShadows;          // float -1..1
extern NSString *const SpliceKitBRAWKeyMidpoint;         // float 0..1
extern NSString *const SpliceKitBRAWKeyBlackLevel;       // float 0..1
extern NSString *const SpliceKitBRAWKeyWhiteLevel;       // float 0..1
extern NSString *const SpliceKitBRAWKeyVideoBlackLevel;  // u16 (0/1)
extern NSString *const SpliceKitBRAWKeyHighlightRecovery;// u16 (0/1)
extern NSString *const SpliceKitBRAWKeyGamutCompression; // u16 (0/1)
extern NSString *const SpliceKitBRAWKeyColorScienceGen;  // u16 (1/4/5)
extern NSString *const SpliceKitBRAWKeyAnalogGainClip;   // float (clip-static)
//
// CLIP attributes (string popups):
extern NSString *const SpliceKitBRAWKeyGamma;            // NSString
extern NSString *const SpliceKitBRAWKeyGamut;            // NSString
extern NSString *const SpliceKitBRAWKeyPost3DLUTMode;    // NSString

// Outer-wrapper key. FFAsset.rawProcessorSettings is a dict keyed by extension
// identifier; our settings live under this key inside that top-level dict.
extern NSString *const SpliceKitBRAWExtensionIdentifier; // "com.splicekit.braw.rawprocessor"

@interface SpliceKitBRAWAdjustmentInfo : NSObject <NSCopying>

// Raw backing dict. Never nil. Contains only the keys above.
@property (nonatomic, readonly, copy) NSDictionary<NSString *, id> *settings;

// As-shot camera metadata (readonly, from BRAW SDK clip attributes). Not
// persisted — this is queried at HUD-open time for display only.
@property (nonatomic, assign) uint32_t asShotISO;
@property (nonatomic, assign) uint32_t asShotKelvin;
@property (nonatomic, assign) int32_t  asShotTint;

+ (instancetype)infoWithSettings:(nullable NSDictionary<NSString *, id> *)settings;

// Create from a top-level FFAsset.rawProcessorSettings dict (unwraps the outer
// SpliceKitBRAWExtensionIdentifier key). Returns a fresh instance with empty
// settings if the key is missing.
+ (instancetype)infoFromRawProcessorSettings:(nullable NSDictionary *)topLevel;

// Mutating accessors — return copies since the instance is immutable. The
// value type can be NSNumber (for numeric attributes) or NSString (for the
// string-typed gamma/gamut/lut popups). Pass nil to clear a key.
- (instancetype)infoBySetting:(NSString *)key value:(nullable id)value;
- (instancetype)infoBySettings:(NSDictionary<NSString *, id> *)overrides;

// Wrap current settings into the top-level FFAsset.rawProcessorSettings shape.
// If `baseTopLevel` is non-nil, merges into it (preserving other extensions'
// keys). Returns nil when settings is empty AND baseTopLevel has nothing else
// under our key — that signal tells the caller to clear instead of set.
- (nullable NSDictionary *)mergedIntoRawProcessorSettings:(nullable NSDictionary *)baseTopLevel;

// Convenience typed accessors.
- (nullable NSNumber *)valueForBRAWKey:(NSString *)key;
- (double)doubleValueForKey:(NSString *)key defaultValue:(double)defaultValue;

@end

NS_ASSUME_NONNULL_END
