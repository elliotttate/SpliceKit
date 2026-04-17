// SpliceKitBRAWSettingsHud.h — singleton floating HUD for BRAW RAW adjustments.
//
// Mirrors FFProResRAWSettingsHud's role in the ProRes RAW path: opens when the
// Inspector's "Modify BRAW…" button is clicked, shows a panel of sliders/popups
// driven by a dictionary-of-descriptors, writes changes back to FFAsset's
// rawProcessorSettings (which persists in the library) and our internal
// SpliceKitBRAWRAWSettingsMap cache (which the decoder reads per frame).

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface SpliceKitBRAWSettingsHud : NSObject

+ (instancetype)shared;

// Primary entry: sets the selected asset items and shows the panel.
// `items` is an NSArray of FFAssetRef / FFAnchoredMediaComponent objects (we
// walk them to resolve FFAsset via -asset / -media / -firstAsset).
- (void)openForItems:(nullable NSArray *)items;

- (void)closeHUD;
- (BOOL)isHUDVisible;

@end

NS_ASSUME_NONNULL_END
