// Edit existing native FFAnchoredCaption objects; never transcribe or create a temporary project.
#import "SpliceKitV4TitlesSupport.h"

static BOOL SKTIsCaption(id object) {
    Class cls = objc_getClass("FFAnchoredCaption");
    return cls && [object isKindOfClass:cls];
}

static id SKTCaption(id sequence, NSString *clipID) {
    id clip = SKTFind(sequence, clipID);
    SKTRequire(SKTIsCaption(clip), @"WRONG_CLIP_TYPE", @"clip_id must identify a native caption, not a Motion title.");
    return clip;
}

static NSArray *SKTCaptionRoles(id sequence) {
    NSMutableArray *roles = [NSMutableArray array];
    Class roleClass = objc_getClass("FFRole");
    for (id object in SKTObjects(sequence)) {
        for (id role in SKTArray(SKTGet(object, @"roles"))) {
            if (![role isKindOfClass:roleClass] || [roles containsObject:role]) continue;
            SEL caption = NSSelectorFromString(@"isCaption");
            if ([role respondsToSelector:caption] && ((BOOL (*)(id, SEL))objc_msgSend)(role, caption)) [roles addObject:role];
        }
    }
    return roles;
}

static NSDictionary *SKTRoleInfo(id role) {
    id uid = SKTGet(role, @"uuid");
    SKTRequire([uid isKindOfClass:[NSString class]] && [uid length] > 0,
        @"ROLE_ID_UNAVAILABLE", @"Caption role does not expose a string identity.");
    return @{@"role_id": uid, @"name": SKTGet(role, @"displayName") ?: @"",
        @"language": SKTGet(role, @"languageIdentifier") ?: (id)[NSNull null],
        @"format": SKTGet(role, @"captionFormat") ?: SKTGet(SKTGet(role, @"mainRole"), @"captionFormat") ?: (id)[NSNull null]};
}

static NSDictionary *SKTCaptionReadback(id sequence, id clip) {
    NSMutableDictionary *result = [SKTObjectReadback(sequence, clip) mutableCopy];
    result[@"text"] = SKTGet(clip, @"text") ?: @"";
    result[@"role_id"] = SKTGet(clip, @"roleUID") ?: (id)[NSNull null];
    NSMutableArray *blocks = [NSMutableArray array];
    NSUInteger index = 0;
    for (id block in SKTArray(SKTGet(clip, @"captionTextBlocks"))) {
        NSMutableArray *lines = [NSMutableArray array];
        for (NSAttributedString *line in SKTArray(SKTGet(block, @"attributedStrings")))
            [lines addObject:SKTTextReadback(line)];
        [blocks addObject:@{@"block_index": @(index++), @"text": SKTGet(block, @"text") ?: @"", @"lines": lines}];
    }
    result[@"blocks"] = blocks;
    return result;
}

static NSDictionary *SKTCaptionList(NSDictionary *params) {
    return SKTRun(params, @"List Native Captions", NO, ^NSDictionary *(SKTRequest *request) {
        id sequence = SKTSequence();
        NSMutableArray *captions = [NSMutableArray array], *roles = [NSMutableArray array];
        for (id object in SKTObjects(sequence)) if (SKTIsCaption(object)) [captions addObject:SKTCaptionReadback(sequence, object)];
        [captions sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            int result = CMTimeCompare(SKTParseTime(a[@"start"], NO), SKTParseTime(b[@"start"], NO));
            return result ? (NSComparisonResult)result : [a[@"clip_id"] compare:b[@"clip_id"]];
        }];
        for (id role in SKTCaptionRoles(sequence)) [roles addObject:SKTRoleInfo(role)];
        return @{@"captions": captions, @"available_roles": roles};
    });
}

static NSDictionary *SKTCaptionText(NSDictionary *params) {
    return SKTRun(params, @"Edit Native Caption Text", YES, ^NSDictionary *(SKTRequest *request) {
        id sequence = SKTSequence(), clip = SKTCaption(sequence, params[@"clip_id"]);
        NSArray *blocks = SKTArray(SKTGet(clip, @"captionTextBlocks"));
        SKTRequire(SKTInteger(params[@"block_index"]) && [params[@"block_index"] longLongValue] >= 0 &&
            [params[@"block_index"] unsignedLongLongValue] < blocks.count,
            @"INVALID_BLOCK", @"Choose a block_index returned by v4.caption.list.");
        SKTRequire([params[@"text"] isKindOfClass:[NSString class]], @"INVALID_TEXT", @"text must be a string.");
        NSUInteger index = [params[@"block_index"] unsignedIntegerValue]; id block = blocks[index];
        SEL selector = NSSelectorFromString(@"updateCaptionTextBlock:withAttributedStrings:");
        SKTRequire([clip respondsToSelector:selector], @"UNSUPPORTED_SELECTOR", @"Native caption text editing is unavailable.");
        NSArray *old = SKTArray(SKTGet(block, @"attributedStrings"));
        NSMutableArray *replacement = [NSMutableArray array];
        NSUInteger lineIndex = 0;
        for (NSString *line in [params[@"text"] componentsSeparatedByString:@"\n"]) {
            NSAttributedString *template = old.count ? old[MIN(lineIndex, old.count - 1)] : nil;
            NSDictionary *attributes = template.length ? [template attributesAtIndex:0 effectiveRange:NULL] : @{};
            [replacement addObject:[[NSAttributedString alloc] initWithString:line attributes:attributes]];
            lineIndex++;
        }
        SKTEdit(sequence, request, ^{
            ((void (*)(id, SEL, id, id))objc_msgSend)(clip, selector, block, replacement);
        });
        request.applied = @YES;
        request.readback = SKTCaptionReadback(sequence, clip);
        NSArray *actualLines = SKTArray(SKTGet(block, @"attributedStrings"));
        NSMutableArray *actual = [NSMutableArray array];
        for (NSAttributedString *line in actualLines) [actual addObject:line.string];
        SKTRequire([[actual componentsJoinedByString:@"\n"] isEqualToString:params[@"text"]],
            @"READBACK_MISMATCH", @"The native caption text differs from the replacement.");
        return SKTCaptionReadback(sequence, clip);
    });
}

static NSDictionary *SKTCaptionTiming(NSDictionary *params) {
    return SKTRun(params, @"Retime Native Caption", YES, ^NSDictionary *(SKTRequest *request) {
        id sequence = SKTSequence(), clip = SKTCaption(sequence, params[@"clip_id"]);
        CMTime start = SKTParseTime(params[@"start"], NO), duration = SKTParseTime(params[@"duration"], YES);
        SKTCheckFrame(start, SKTFrame(sequence)); SKTCheckFrame(duration, SKTFrame(sequence));
        id primary = SKTGet(sequence, @"primaryObject"); CMTimeRange primaryRange = SKTRange(primary, @"clippedRange");
        SKTRequire(CMTimeCompare(start, primaryRange.start) >= 0 && CMTimeCompare(CMTimeAdd(start, duration), CMTimeRangeGetEnd(primaryRange)) <= 0,
            @"OUTSIDE_TIMELINE", @"Caption timing must remain inside the primary storyline.");
        id roleID = SKTGet(clip, @"roleUID");
        for (id other in SKTObjects(sequence)) {
            if (other == clip || !SKTIsCaption(other) || ![SKTGet(other, @"roleUID") isEqual:roleID]) continue;
            CMTimeRange range = SKTEffectiveRange(sequence, other);
            SKTRequire(CMTimeCompare(CMTimeRangeGetEnd(range), start) <= 0 || CMTimeCompare(range.start, CMTimeAdd(start, duration)) >= 0,
                @"CAPTION_OVERLAP", @"Requested timing overlaps another caption in the same role.");
        }
        CMTimeRange local = SKTRange(clip, @"clippedRange"); local.duration = duration;
        NSInteger lane = [SKTObjectReadback(sequence, clip)[@"lane"] integerValue];
        SEL rangeSetter = NSSelectorFromString(@"setClippedRange:");
        SEL anchor = NSSelectorFromString(@"actionAnchorItem:withAnchorInLocalTime:atTime:inContainer:inContainerAnchorLane:error:");
        SKTRequire([clip respondsToSelector:rangeSetter] && [sequence respondsToSelector:anchor],
            @"UNSUPPORTED_SELECTOR", @"Caption timing selectors are unavailable.");
        SKTEdit(sequence, request, ^{
            ((void (*)(id, SEL, CMTimeRange))objc_msgSend)(clip, rangeSetter, local);
            NSError *error = nil;
            BOOL ok = ((BOOL (*)(id, SEL, id, CMTime, CMTime, id, NSInteger, NSError **))objc_msgSend)(
                sequence, anchor, clip, local.start, start, primary, lane, &error);
            SKTRequire(ok, @"TIMING_FAILED", error.localizedDescription ?: @"Native reanchor failed; inspect caption timing before retrying.");
        });
        request.applied = @YES;
        request.readback = SKTCaptionReadback(sequence, clip);
        CMTimeRange actual = SKTEffectiveRange(sequence, clip);
        SKTRequire(CMTimeCompare(actual.start, start) == 0 && CMTimeCompare(actual.duration, duration) == 0,
            @"READBACK_MISMATCH", @"Native caption timing differs from the requested interval.");
        return SKTCaptionReadback(sequence, clip);
    });
}

static NSDictionary *SKTCaptionRole(NSDictionary *params) {
    return SKTRun(params, @"Change Native Caption Role", YES, ^NSDictionary *(SKTRequest *request) {
        id sequence = SKTSequence(), clip = SKTCaption(sequence, params[@"clip_id"]);
        SKTRequire([params[@"role_id"] isKindOfClass:[NSString class]], @"INVALID_ROLE", @"Choose an existing native role_id from v4.caption.list.");
        id chosen = nil;
        for (id role in SKTCaptionRoles(sequence)) if ([SKTRoleInfo(role)[@"role_id"] isEqual:params[@"role_id"]]) chosen = role;
        SKTRequire(chosen != nil, @"ROLE_NOT_FOUND", @"Role is absent from this sequence; create/import the desired native caption role first.");
        SEL selector = NSSelectorFromString(@"setRole:");
        SKTRequire([clip respondsToSelector:selector], @"UNSUPPORTED_SELECTOR", @"Native caption role editing is unavailable.");
        SKTEdit(sequence, request, ^{ ((void (*)(id, SEL, id))objc_msgSend)(clip, selector, chosen); });
        request.applied = @YES;
        request.readback = SKTCaptionReadback(sequence, clip);
        SKTRequire([SKTGet(clip, @"roleUID") isEqual:params[@"role_id"]], @"READBACK_MISMATCH", @"Native caption role differs from the requested role.");
        NSMutableDictionary *result = [SKTCaptionReadback(sequence, clip) mutableCopy]; result[@"role"] = SKTRoleInfo(chosen);
        return result;
    });
}

__attribute__((constructor)) static void SKTInstallCaptions(void) {
    @autoreleasepool {
        SKTRegister(@"v4.caption.list", YES, ^NSDictionary *(NSDictionary *p) { return SKTCaptionList(p); });
        SKTRegister(@"v4.caption.set_text", NO, ^NSDictionary *(NSDictionary *p) { return SKTCaptionText(p); });
        SKTRegister(@"v4.caption.set_timing", NO, ^NSDictionary *(NSDictionary *p) { return SKTCaptionTiming(p); });
        SKTRegister(@"v4.caption.set_role", NO, ^NSDictionary *(NSDictionary *p) { return SKTCaptionRole(p); });
    }
}
