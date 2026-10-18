// Explicit title fields, attributed-text spans and generator insertion.
#import "SpliceKitV4TitlesSupport.h"

static void SKTRequireEffect(NSString *effectID, NSString *type) {
    Class cls = objc_getClass("FFEffect");
    SEL selector = NSSelectorFromString(@"effectTypeForEffectID:");
    SKTRequire([effectID isKindOfClass:[NSString class]] && effectID.length > 0,
        @"INVALID_EFFECT", @"An exact, untruncated effectID is required.");
    SKTRequire([cls respondsToSelector:selector], @"UNSUPPORTED_SELECTOR", @"Effect type lookup is unavailable.");
    id actual = ((id (*)(id, SEL, id))objc_msgSend)(cls, selector, effectID);
    SKTRequire([actual isEqual:type], @"WRONG_EFFECT_TYPE", @"The effectID is unavailable or belongs to a different effect type.");
}

static id SKTTitleEffect(id clip) {
    id effect = SKTGet(clip, @"effect");
    SKTRequireEffect(SKTGet(effect, @"effectID"), @"effect.video.title");
    return effect;
}

static NSUInteger SKTFieldCount(id effect) {
    SEL selector = NSSelectorFromString(@"textFieldCount");
    SKTRequire([effect respondsToSelector:selector], @"TEXT_FIELDS_UNAVAILABLE", @"This title does not expose indexed native text fields.");
    NSUInteger count = ((NSUInteger (*)(id, SEL))objc_msgSend)(effect, selector);
    SKTRequire(count <= 1024, @"TEXT_FIELDS_UNAVAILABLE", @"Native text field count exceeds limits.");
    return count;
}

static NSUInteger SKTField(id effect, NSDictionary *params) {
    SKTRequire(SKTInteger(params[@"field_index"]) && [params[@"field_index"] longLongValue] >= 0 &&
        [params[@"field_index"] unsignedLongLongValue] < SKTFieldCount(effect),
        @"INVALID_FIELD", @"Provide an explicit field_index returned by v4.title.get.");
    return [params[@"field_index"] unsignedIntegerValue];
}

static NSAttributedString *SKTFieldText(id effect, NSUInteger field) {
    SEL selector = NSSelectorFromString(@"textForField:");
    SKTRequire([effect respondsToSelector:selector], @"TEXT_UNAVAILABLE", @"Native attributed-text readback is unavailable.");
    id value = ((id (*)(id, SEL, NSUInteger))objc_msgSend)(effect, selector, field);
    SKTRequire([value isKindOfClass:[NSAttributedString class]], @"TEXT_UNAVAILABLE", @"The native text field is not ready; no channel-order fallback is used.");
    return value;
}

static void SKTWriteField(id effect, NSUInteger field, NSAttributedString *text) {
    SEL selector = NSSelectorFromString(@"setText:forField:");
    SKTRequire([effect respondsToSelector:selector], @"UNSUPPORTED_SELECTOR", @"Native attributed-text editing is unavailable.");
    SKTGet(effect, @"storeForUndo");
    ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(effect, selector, text, field);
    // Same persistence path as CaptionPanel; support depends on the concrete Motion effect.
    // UNVERIFIED: these optional selectors are present in the existing CaptionPanel path,
    // but absent from the available FCP 12.4 static metadata snapshot.
    for (NSString *name in @[@"syncChannelStateForXMLExport", @"saveDirtyTextToEffectValues", @"_channelsChanged"]) {
        SEL sel = NSSelectorFromString(name);
        if ([effect respondsToSelector:sel]) ((void (*)(id, SEL))objc_msgSend)(effect, sel);
    }
}

static NSDictionary *SKTTitleReadback(id sequence, id clip) {
    id effect = SKTTitleEffect(clip);
    NSMutableDictionary *result = [SKTObjectReadback(sequence, clip) mutableCopy];
    NSMutableArray *fields = [NSMutableArray array];
    for (NSUInteger field = 0; field < SKTFieldCount(effect); field++) {
        NSMutableDictionary *info = [SKTTextReadback(SKTFieldText(effect, field)) mutableCopy];
        info[@"field_index"] = @(field); [fields addObject:info];
    }
    result[@"fields"] = fields; result[@"position"] = SKTPosition(clip);
    return result;
}

static NSDictionary *SKTInsert(NSDictionary *params, BOOL title) {
    return SKTRun(params, title ? @"Insert Title" : @"Insert Generator", YES, ^NSDictionary *(SKTRequest *request) {
        id sequence = SKTSequence();
        CMTime start = SKTParseTime(params[@"start"], NO);
        CMTime duration = SKTParseTime(params[@"duration"], YES);
        CMTime frame = SKTFrame(sequence);
        SKTCheckFrame(start, frame); SKTCheckFrame(duration, frame);
        SKTRequire(SKTInteger(params[@"lane"]) && [params[@"lane"] longLongValue] > 0 && [params[@"lane"] longLongValue] <= 1024,
            @"INVALID_LANE", @"A connected-video lane in [1,1024] is required; lane 0 would ripple the primary storyline.");
        NSInteger lane = [params[@"lane"] integerValue];
        SKTRequireEffect(params[@"effectID"], title ? @"effect.video.title" : @"effect.video.generator");
        id primary = SKTGet(sequence, @"primaryObject");
        CMTimeRange primaryRange = SKTRange(primary, @"clippedRange");
        SKTRequire(CMTimeCompare(start, primaryRange.start) >= 0 &&
            CMTimeCompare(start, CMTimeRangeGetEnd(primaryRange)) < 0, @"NO_ANCHOR",
            @"Start must lie inside the active primary storyline.");
        for (id item in SKTObjects(sequence)) {
            SEL laneSel = NSSelectorFromString(@"anchoredLane");
            if (![item respondsToSelector:laneSel] || ((NSInteger (*)(id, SEL))objc_msgSend)(item, laneSel) != lane) continue;
            CMTimeRange range = SKTEffectiveRange(sequence, item);
            SKTRequire(CMTimeCompare(CMTimeRangeGetEnd(range), start) <= 0 ||
                CMTimeCompare(range.start, CMTimeAdd(start, duration)) >= 0,
                @"LANE_OCCUPIED", @"The requested lane and interval overlap another clip.");
        }
        Class cls = objc_getClass("FFAnchoredGeneratorComponent");
        SEL initializer = NSSelectorFromString(@"initWithEffectID:duration:sampleDuration:");
        SKTRequire([cls instancesRespondToSelector:initializer], @"UNSUPPORTED_SELECTOR", @"Generator construction is unavailable.");
        id clip = ((id (*)(id, SEL, id, CMTime, CMTime))objc_msgSend)([cls alloc], initializer,
            params[@"effectID"], duration, frame);
        SKTRequire(clip != nil, @"GENERATOR_UNAVAILABLE", @"FCP could not instantiate this template.");
        NSString *clipID = SKTID(clip); // Fail before insertion if a durable identity is unavailable.
        SEL anchor = NSSelectorFromString(@"actionAnchorItem:withAnchorInLocalTime:atTime:inContainer:inContainerAnchorLane:error:");
        SKTRequire([sequence respondsToSelector:anchor], @"UNSUPPORTED_SELECTOR", @"Native anchor action is unavailable.");
        SKTEdit(sequence, request, ^{
            NSError *error = nil;
            BOOL ok = ((BOOL (*)(id, SEL, id, CMTime, CMTime, id, NSInteger, NSError **))objc_msgSend)(
                sequence, anchor, clip, SKTRange(clip,@"clippedRange").start, start, primary, lane, &error);
            SKTRequire(ok, @"INSERT_FAILED", error.localizedDescription ?: @"Native anchor action failed; reconcile the timeline before retrying.");
        });
        id live = SKTFind(sequence, clipID);
        request.applied = @YES;
        NSDictionary *readback = title ? SKTTitleReadback(sequence, live) : SKTObjectReadback(sequence, live);
        request.readback = readback;
        SKTRequire([readback[@"lane"] integerValue] == lane &&
            CMTimeCompare(SKTParseTime(readback[@"start"], NO), start) == 0 &&
            CMTimeCompare(SKTParseTime(readback[@"duration"], YES), duration) == 0 &&
            [readback[@"effectID"] isEqual:params[@"effectID"]],
            @"READBACK_MISMATCH", @"Inserted clip does not match the requested effect, lane or timing.");
        NSMutableDictionary *result = [readback mutableCopy];
        result[@"parameter_inspection"] = @{@"method": @"v4.object.inspect", @"clip_id": clipID};
        return result;
    });
}

static NSDictionary *SKTTitleChange(NSDictionary *params, BOOL style) {
    return SKTRun(params, style ? @"Style Title" : @"Edit Title Text", YES, ^NSDictionary *(SKTRequest *request) {
        id sequence = SKTSequence(); id clip = SKTFind(sequence, params[@"clip_id"]);
        id effect = SKTTitleEffect(clip); NSUInteger field = SKTField(effect, params);
        NSAttributedString *old = [SKTFieldText(effect, field) copy];
        NSAttributedString *desired = nil;
        if (style) {
            NSArray *spans = params[@"spans"] ?: @[];
            SKTRequire([spans isKindOfClass:[NSArray class]] && ([spans count] > 0 || params[@"position"]),
                @"EMPTY_PATCH", @"Provide style spans or a clip position.");
            desired = SKTStyledText(old, spans);
        } else {
            SKTRequire([params[@"text"] isKindOfClass:[NSString class]], @"INVALID_TEXT", @"text must be a string (empty text is permitted).");
            NSDictionary *attributes = old.length ? [old attributesAtIndex:0 effectiveRange:NULL] : @{};
            desired = [[NSAttributedString alloc] initWithString:params[@"text"] attributes:attributes];
        }
        if (params[@"position"]) { SKTValidatePosition(params[@"position"]); SKTPosition(clip); }
        SKTRequire([effect respondsToSelector:NSSelectorFromString(@"setText:forField:")], @"UNSUPPORTED_SELECTOR", @"Native text setter is unavailable.");
        NSDictionary *oldPosition = params[@"position"] ? SKTPosition(clip) : nil;
        SKTEdit(sequence, request, ^{
            SKTRequire(SpliceKitV4RegisterUndo(effect, ^(id target) {
                SKTWriteField(target,field,old);
                if (oldPosition) SKTSetPosition(clip,oldPosition);
            }), @"UNDO_UNAVAILABLE", @"No current operation-owned undo group");
            SKTWriteField(effect, field, desired);
            if (params[@"position"]) SKTSetPosition(clip, params[@"position"]);
        });
        NSAttributedString *actual = SKTFieldText(effect, field);
        request.applied = @YES;
        request.readback = SKTTitleReadback(sequence, clip);
        SKTRequire([actual.string isEqualToString:desired.string], @"READBACK_MISMATCH", @"Native text differs from the requested text.");
        if (style) SKTRequire(SKTStyleEqual(SKTTextReadback(actual),SKTTextReadback(desired)),
            @"READBACK_MISMATCH", @"Native style runs differ from the requested style; inspect before retrying.");
        NSDictionary *readback = SKTTitleReadback(sequence, clip);
        if (params[@"position"]) SKTRequire(fabs([readback[@"position"][@"x"] doubleValue] - [params[@"position"][@"x"] doubleValue]) < 0.001 &&
            fabs([readback[@"position"][@"y"] doubleValue] - [params[@"position"][@"y"] doubleValue]) < 0.001,
            @"READBACK_MISMATCH", @"Native position differs from the requested pixel position.");
        return readback;
    });
}

__attribute__((constructor)) static void SKTInstallTitles(void) {
    @autoreleasepool {
        SKTRegister(@"v4.title.insert", NO, ^NSDictionary *(NSDictionary *p) { return SKTInsert(p, YES); });
        SKTRegister(@"v4.generator.insert", NO, ^NSDictionary *(NSDictionary *p) { return SKTInsert(p, NO); });
        SKTRegister(@"v4.title.get", YES, ^NSDictionary *(NSDictionary *p) {
            return SKTRun(p, @"Read Title", NO, ^NSDictionary *(SKTRequest *r) {
                id sequence = SKTSequence(); return SKTTitleReadback(sequence, SKTFind(sequence, p[@"clip_id"]));
            });
        });
        SKTRegister(@"v4.title.set_text", NO, ^NSDictionary *(NSDictionary *p) { return SKTTitleChange(p, NO); });
        SKTRegister(@"v4.title.set_style", NO, ^NSDictionary *(NSDictionary *p) { return SKTTitleChange(p, YES); });
    }
}
