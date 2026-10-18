#import "SpliceKitV4Media.h"

static NSDictionary *SKMColorControls(NSString *family) {
    // UNVERIFIED: These are logical binding names, not a calibrated native
    // family/channel-ID/unit table. The caller must supply discovered paths.
    NSMutableDictionary *controls = [NSMutableDictionary dictionary];
    if ([family isEqualToString:@"board"] || [family isEqualToString:@"wheels"]) {
        for (NSString *zone in @[@"master", @"shadows", @"midtones", @"highlights"]) {
            for (NSString *axis in @[@"exposure", @"saturation"])
                controls[[NSString stringWithFormat:@"%@.%@", axis, zone]] = @[@"double"];
            if ([family isEqualToString:@"board"]) {
                controls[[NSString stringWithFormat:@"color.%@.hue", zone]] = @[@"angle", @"double"];
                controls[[NSString stringWithFormat:@"color.%@.amount", zone]] = @[@"double"];
            } else controls[[NSString stringWithFormat:@"color.%@", zone]] = @[@"color"];
        }
        if ([family isEqualToString:@"wheels"]) {
            controls[@"temperature"] = @[@"double"];
            controls[@"tint"] = @[@"double"];
            controls[@"hue"] = @[@"angle", @"double"];
        }
    } else if ([family isEqualToString:@"lut"]) {
        controls[@"path"] = @[@"string"];
        controls[@"mix"] = @[@"double"];
        controls[@"input_color_space"] = @[@"enum"];
        controls[@"output_color_space"] = @[@"enum"];
    }
    // Curves and Hue/Sat expose native custom channels. An array of points is
    // not a CHChannelDouble and must never be written through the scalar API.
    return controls;
}

static void SKMColorValidateFamily(NSDictionary *params) {
    SKMRequire([@[@"board", @"wheels", @"curves", @"hue_sat", @"lut"] containsObject:params[@"family"] ?: @""],
        @"INVALID_PARAMS", @"family must be board, wheels, curves, hue_sat or lut.");
}

void SpliceKitV4RegisterColor(void) {
    SKMRegister(@"v4.color.inspect", YES, ^NSDictionary *(NSDictionary *p, BOOL *attempted) {
        SKMColorValidateFamily(p);
        NSDictionary *result = SKMCall(@"v4.object.inspect", @{@"target": p[@"target"] ?: @{}, @"time": p[@"time"] ?: @{}});
        NSMutableDictionary *readback = [result[@"readback"] mutableCopy];
        SKMRequire(readback != nil, @"DEPENDENCY_FAILED", @"Parameter inspector returned no readback.");
        readback[@"family"] = p[@"family"];
        readback[@"named_control_types"] = SKMColorControls(p[@"family"]);
        readback[@"binding_policy"] = @"Copy parameter_path from this instance's discovered tree. Bind names explicitly; no localized label or fixed channel ID is inferred. Values use native units and enum values.";
        readback[@"custom_curve_writes_supported"] = @NO;
        readback[@"preview_color_space"] = NSNull.null;
        readback[@"preview_tonemap"] = NSNull.null;
        return SKMResult(p, YES, @NO, readback, nil, nil);
    });
    SKMRegister(@"v4.color.apply_adjustment", NO, ^NSDictionary *(NSDictionary *p, BOOL *attempted) {
        SKMColorValidateFamily(p);
        if (p[@"create_effect_id"]) {
            SKMRequire(SKMString(p[@"create_effect_id"]) && !p[@"target"][@"effect_instance_id"] &&
                !p[@"adjustments"], @"INVALID_PARAMS", @"Creation requires a full catalog effect ID and a clip-only target. Inspect the new instance before binding adjustments.");
            // v4.effect.add owns exact identity, native insertion, undo and readback.
            // There is no locale-sensitive 'first Color Wheels' selection action.
            *attempted = YES;
            return SKMCall(@"v4.effect.add", @{@"target": p[@"target"] ?: @{}, @"effect_id": p[@"create_effect_id"]});
        }
        SKMRequire(![@[@"curves", @"hue_sat"] containsObject:p[@"family"]],
            @"UNSUPPORTED_CUSTOM_CURVE", @"Native control-point buffer formats are unverified. Inspect these corrections; custom curve writes are not implemented.");
        NSArray *requests = SKMNamedParameterRequests(p, SKMColorControls(p[@"family"]));
        return SKMApplyParameterRequests(p, requests, attempted);
    });
}
