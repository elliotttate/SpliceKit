// SpliceKitBRAWAdjustmentInfo.mm — typed model over the BRAW settings dictionary.

#import "SpliceKitBRAWAdjustmentInfo.h"

NSString *const SpliceKitBRAWKeyISO              = @"iso";
NSString *const SpliceKitBRAWKeyKelvin           = @"kelvin";
NSString *const SpliceKitBRAWKeyTint             = @"tint";
NSString *const SpliceKitBRAWKeyExposure         = @"exposure";
NSString *const SpliceKitBRAWKeyAnalogGain       = @"analogGain";
NSString *const SpliceKitBRAWKeySaturation       = @"saturation";
NSString *const SpliceKitBRAWKeyContrast         = @"contrast";
NSString *const SpliceKitBRAWKeyHighlights       = @"highlights";
NSString *const SpliceKitBRAWKeyShadows          = @"shadows";
NSString *const SpliceKitBRAWKeyMidpoint         = @"midpoint";
NSString *const SpliceKitBRAWKeyBlackLevel       = @"blackLevel";
NSString *const SpliceKitBRAWKeyWhiteLevel       = @"whiteLevel";
NSString *const SpliceKitBRAWKeyVideoBlackLevel  = @"videoBlackLevel";
NSString *const SpliceKitBRAWKeyHighlightRecovery= @"highlightRecovery";
NSString *const SpliceKitBRAWKeyGamutCompression = @"gamutCompression";
NSString *const SpliceKitBRAWKeyColorScienceGen  = @"colorScienceGen";
NSString *const SpliceKitBRAWKeyAnalogGainClip   = @"analogGainClip";
NSString *const SpliceKitBRAWKeyGamma            = @"gamma";
NSString *const SpliceKitBRAWKeyGamut            = @"gamut";
NSString *const SpliceKitBRAWKeyPost3DLUTMode    = @"post3DLUTMode";

NSString *const SpliceKitBRAWExtensionIdentifier = @"com.splicekit.braw.rawprocessor";

static NSString *const kSpliceKitBRAWSettingsVersionKey = @"settingsVersion";
static NSString *const kSpliceKitBRAWSettingsBagKey     = @"settings";

static NSSet<NSString *> *SpliceKitBRAWNumericKeys(void) {
    static NSSet<NSString *> *keys;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        keys = [NSSet setWithObjects:
                SpliceKitBRAWKeyISO, SpliceKitBRAWKeyKelvin, SpliceKitBRAWKeyTint,
                SpliceKitBRAWKeyExposure, SpliceKitBRAWKeyAnalogGain,
                SpliceKitBRAWKeySaturation, SpliceKitBRAWKeyContrast,
                SpliceKitBRAWKeyHighlights, SpliceKitBRAWKeyShadows,
                SpliceKitBRAWKeyMidpoint, SpliceKitBRAWKeyBlackLevel,
                SpliceKitBRAWKeyWhiteLevel, SpliceKitBRAWKeyVideoBlackLevel,
                SpliceKitBRAWKeyHighlightRecovery, SpliceKitBRAWKeyGamutCompression,
                SpliceKitBRAWKeyColorScienceGen, SpliceKitBRAWKeyAnalogGainClip,
                nil];
    });
    return keys;
}

static NSSet<NSString *> *SpliceKitBRAWStringKeys(void) {
    static NSSet<NSString *> *keys;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        keys = [NSSet setWithObjects:
                SpliceKitBRAWKeyGamma, SpliceKitBRAWKeyGamut,
                SpliceKitBRAWKeyPost3DLUTMode, nil];
    });
    return keys;
}

static NSDictionary<NSString *, id> *SpliceKitBRAWFilterSettings(NSDictionary *input) {
    if (![input isKindOfClass:[NSDictionary class]] || input.count == 0) {
        return @{};
    }
    NSMutableDictionary<NSString *, id> *out = [NSMutableDictionary dictionary];
    for (NSString *key in SpliceKitBRAWNumericKeys()) {
        id value = input[key];
        if ([value isKindOfClass:[NSNumber class]]) out[key] = value;
    }
    for (NSString *key in SpliceKitBRAWStringKeys()) {
        id value = input[key];
        if ([value isKindOfClass:[NSString class]] && [(NSString *)value length] > 0) {
            out[key] = value;
        }
    }
    return out.count > 0 ? [out copy] : @{};
}

@implementation SpliceKitBRAWAdjustmentInfo

+ (instancetype)infoWithSettings:(NSDictionary<NSString *, id> *)settings {
    return [[self alloc] initWithSettings:settings];
}

+ (instancetype)infoFromRawProcessorSettings:(NSDictionary *)topLevel {
    if (![topLevel isKindOfClass:[NSDictionary class]]) {
        return [[self alloc] initWithSettings:nil];
    }
    id entry = topLevel[SpliceKitBRAWExtensionIdentifier];
    if (![entry isKindOfClass:[NSDictionary class]]) {
        return [[self alloc] initWithSettings:nil];
    }
    id bag = ((NSDictionary *)entry)[kSpliceKitBRAWSettingsBagKey];
    return [[self alloc] initWithSettings:([bag isKindOfClass:[NSDictionary class]] ? bag : nil)];
}

- (instancetype)initWithSettings:(NSDictionary<NSString *, id> *)settings {
    if ((self = [super init])) {
        _settings = SpliceKitBRAWFilterSettings(settings);
    }
    return self;
}

- (id)copyWithZone:(NSZone *)zone {
    SpliceKitBRAWAdjustmentInfo *copy = [[[self class] alloc] initWithSettings:_settings];
    copy.asShotISO    = _asShotISO;
    copy.asShotKelvin = _asShotKelvin;
    copy.asShotTint   = _asShotTint;
    return copy;
}

- (instancetype)infoBySetting:(NSString *)key value:(id)value {
    if (key.length == 0) return self;
    NSMutableDictionary *merged = [_settings mutableCopy];
    if ([value isKindOfClass:[NSNumber class]]) {
        merged[key] = value;
    } else if ([value isKindOfClass:[NSString class]] && [(NSString *)value length] > 0) {
        merged[key] = value;
    } else {
        [merged removeObjectForKey:key];
    }
    return [[SpliceKitBRAWAdjustmentInfo alloc] initWithSettings:merged];
}

- (instancetype)infoBySettings:(NSDictionary<NSString *, id> *)overrides {
    if (overrides.count == 0) return self;
    NSMutableDictionary *merged = [_settings mutableCopy];
    for (NSString *key in overrides) {
        id value = overrides[key];
        if ([value isKindOfClass:[NSNumber class]]) {
            merged[key] = value;
        } else {
            [merged removeObjectForKey:key];
        }
    }
    return [[SpliceKitBRAWAdjustmentInfo alloc] initWithSettings:merged];
}

- (NSDictionary *)mergedIntoRawProcessorSettings:(NSDictionary *)baseTopLevel {
    NSMutableDictionary *top = [NSMutableDictionary dictionary];
    if ([baseTopLevel isKindOfClass:[NSDictionary class]]) {
        [top addEntriesFromDictionary:baseTopLevel];
    }

    if (_settings.count == 0) {
        [top removeObjectForKey:SpliceKitBRAWExtensionIdentifier];
        return top.count > 0 ? [top copy] : nil;
    }

    NSMutableDictionary *entry = [NSMutableDictionary dictionary];
    id existing = top[SpliceKitBRAWExtensionIdentifier];
    if ([existing isKindOfClass:[NSDictionary class]]) {
        [entry addEntriesFromDictionary:existing];
    }
    entry[kSpliceKitBRAWSettingsBagKey] = [_settings copy];
    if (!entry[kSpliceKitBRAWSettingsVersionKey]) {
        entry[kSpliceKitBRAWSettingsVersionKey] = @1;
    }
    top[SpliceKitBRAWExtensionIdentifier] = [entry copy];
    return [top copy];
}

- (NSNumber *)valueForBRAWKey:(NSString *)key {
    if (key.length == 0) return nil;
    id value = _settings[key];
    return [value isKindOfClass:[NSNumber class]] ? value : nil;
}

- (double)doubleValueForKey:(NSString *)key defaultValue:(double)defaultValue {
    NSNumber *value = [self valueForBRAWKey:key];
    return value ? value.doubleValue : defaultValue;
}

@end
