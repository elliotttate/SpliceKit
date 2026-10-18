// Native attributed-text style patches and complete run readback.
#import "SpliceKitV4TitlesSupport.h"

static NSColor *SKTColor(id value) {
    SKTRequire([value isKindOfClass:[NSArray class]] && [value count] == 4,
        @"INVALID_STYLE", @"Colors require four sRGB components [r,g,b,a].");
    for (id component in value) SKTRequire(SKTNumber(component) && [component doubleValue] >= 0 &&
        [component doubleValue] <= 1, @"INVALID_STYLE", @"Color components must be in [0,1].");
    return [NSColor colorWithSRGBRed:[value[0] doubleValue] green:[value[1] doubleValue]
        blue:[value[2] doubleValue] alpha:[value[3] doubleValue]];
}

static NSArray *SKTColorJSON(NSColor *color) {
    NSColor *rgb = [color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    return rgb ? @[@(rgb.redComponent), @(rgb.greenComponent), @(rgb.blueComponent), @(rgb.alphaComponent)] : nil;
}

static void SKTPatch(NSMutableAttributedString *text, NSRange range, NSDictionary *style) {
    SKTRequire([style isKindOfClass:[NSDictionary class]] && style.count > 0,
        @"INVALID_STYLE", @"Each span needs a nonempty style patch.");
    NSSet *keys = [NSSet setWithArray:@[@"font", @"size", @"color", @"stroke_color", @"stroke_width", @"shadow", @"alignment"]];
    for (NSString *key in style) SKTRequire([keys containsObject:key], @"INVALID_STYLE", [@"Unknown style attribute: " stringByAppendingString:key]);
    // Apply per existing run to preserve fonts and paragraph properties outside this patch.
    NSAttributedString *snapshot = [text copy];
    [snapshot enumerateAttributesInRange:range options:0 usingBlock:^(NSDictionary *old, NSRange run, BOOL *stop) {
        NSMutableDictionary *attributes = [old mutableCopy];
        if (style[@"font"] || style[@"size"]) {
            NSFont *previous = old[NSFontAttributeName];
            id name = style[@"font"] ?: previous.fontName ?: @"Helvetica";
            id size = style[@"size"] ?: @(previous ? previous.pointSize : 48);
            SKTRequire([name isKindOfClass:[NSString class]] && [name length] > 0 && SKTNumber(size) &&
                [size doubleValue] > 0 && [size doubleValue] <= 4096, @"INVALID_STYLE", @"Invalid font name or point size.");
            NSFont *font = [NSFont fontWithName:name size:[size doubleValue]];
            SKTRequire(font != nil, @"FONT_NOT_FOUND", @"The requested font is not installed; no fallback was applied.");
            attributes[NSFontAttributeName] = font;
        }
        if (style[@"color"]) attributes[NSForegroundColorAttributeName] = SKTColor(style[@"color"]);
        if (style[@"stroke_color"]) attributes[NSStrokeColorAttributeName] = SKTColor(style[@"stroke_color"]);
        if (style[@"stroke_width"]) {
            SKTRequire(SKTNumber(style[@"stroke_width"]), @"INVALID_STYLE", @"Stroke width must be finite (negative means fill plus stroke).");
            attributes[NSStrokeWidthAttributeName] = style[@"stroke_width"];
        }
        if (style[@"alignment"]) {
            NSArray *alignments = @[@"left", @"right", @"center", @"justified", @"natural"];
            NSUInteger alignment = [alignments indexOfObject:style[@"alignment"]];
            SKTRequire(alignment != NSNotFound, @"INVALID_STYLE", @"Unknown paragraph alignment.");
            NSMutableParagraphStyle *paragraph = [old[NSParagraphStyleAttributeName] mutableCopy] ?: [NSMutableParagraphStyle new];
            paragraph.alignment = (NSTextAlignment)alignment;
            attributes[NSParagraphStyleAttributeName] = paragraph;
        }
        if (style[@"shadow"]) {
            id value = style[@"shadow"];
            if (value == [NSNull null]) [attributes removeObjectForKey:NSShadowAttributeName];
            else {
                SKTRequire([value isKindOfClass:[NSDictionary class]] && SKTNumber(value[@"blur"]) &&
                    [value[@"blur"] doubleValue] >= 0 && SKTNumber(value[@"x"]) && SKTNumber(value[@"y"]),
                    @"INVALID_STYLE", @"Shadow requires color, nonnegative blur, x and y.");
                NSShadow *shadow = [NSShadow new]; shadow.shadowColor = SKTColor(value[@"color"]);
                shadow.shadowBlurRadius = [value[@"blur"] doubleValue];
                shadow.shadowOffset = NSMakeSize([value[@"x"] doubleValue], [value[@"y"] doubleValue]);
                attributes[NSShadowAttributeName] = shadow;
            }
        }
        [text setAttributes:attributes range:run];
    }];
}

NSAttributedString *SKTStyledText(NSAttributedString *base, NSArray *spans) {
    SKTRequire([spans isKindOfClass:[NSArray class]], @"INVALID_STYLE", @"spans must be an array.");
    NSMutableAttributedString *result = [base mutableCopy];
    NSMutableIndexSet *covered = [NSMutableIndexSet indexSet];
    for (id span in spans) {
        SKTRequire([span isKindOfClass:[NSDictionary class]] && [span[@"range"] isKindOfClass:[NSDictionary class]],
            @"INVALID_RANGE", @"Each span requires a UTF-16 range {start,length}.");
        id range = span[@"range"];
        SKTRequire(SKTInteger(range[@"start"]) && SKTInteger(range[@"length"]) && [range[@"start"] longLongValue] >= 0 &&
            [range[@"length"] longLongValue] > 0 && [range[@"start"] unsignedLongLongValue] <= result.length &&
            [range[@"length"] unsignedLongLongValue] <= result.length - [range[@"start"] unsignedLongLongValue],
            @"INVALID_RANGE", @"Span is outside the UTF-16 text bounds.");
        NSRange r = NSMakeRange([range[@"start"] unsignedIntegerValue], [range[@"length"] unsignedIntegerValue]);
        SKTRequire(NSEqualRanges(r, [result.string rangeOfComposedCharacterSequencesForRange:r]),
            @"INVALID_RANGE", @"A span cannot split a composed character or surrogate pair.");
        SKTRequire(![covered intersectsIndexesInRange:r], @"OVERLAPPING_SPANS", @"Style patches must have disjoint ranges.");
        [covered addIndexesInRange:r];
        SKTPatch(result, r, span[@"style"]);
    }
    return result;
}

NSDictionary *SKTTextReadback(NSAttributedString *text) {
    SKTRequire([text isKindOfClass:[NSAttributedString class]], @"TEXT_UNAVAILABLE", @"Native attributed text is unavailable.");
    NSMutableArray *spans = [NSMutableArray array];
    [text enumerateAttributesInRange:NSMakeRange(0, text.length) options:0 usingBlock:^(NSDictionary *attrs, NSRange range, BOOL *stop) {
        NSMutableDictionary *style = [NSMutableDictionary dictionary];
        NSFont *font = attrs[NSFontAttributeName];
        if (font) { style[@"font"] = font.fontName; style[@"size"] = @(font.pointSize); }
        if (attrs[NSForegroundColorAttributeName]) style[@"color"] = SKTColorJSON(attrs[NSForegroundColorAttributeName]);
        if (attrs[NSStrokeColorAttributeName]) style[@"stroke_color"] = SKTColorJSON(attrs[NSStrokeColorAttributeName]);
        if (attrs[NSStrokeWidthAttributeName]) style[@"stroke_width"] = attrs[NSStrokeWidthAttributeName];
        NSParagraphStyle *paragraph = attrs[NSParagraphStyleAttributeName];
        if (paragraph) {
            NSArray *alignments = @[@"left", @"right", @"center", @"justified", @"natural"];
            if (paragraph.alignment >= 0 && paragraph.alignment < (NSInteger)alignments.count)
                style[@"alignment"] = alignments[paragraph.alignment];
        }
        NSShadow *shadow = attrs[NSShadowAttributeName];
        if (shadow) style[@"shadow"] = @{@"color": SKTColorJSON(shadow.shadowColor) ?: @[@0,@0,@0,@0],
            @"blur": @(shadow.shadowBlurRadius), @"x": @(shadow.shadowOffset.width), @"y": @(shadow.shadowOffset.height)};
        [spans addObject:@{@"range": @{@"start": @(range.location), @"length": @(range.length)}, @"style": style}];
    }];
    return @{@"text": text.string, @"spans": spans, @"range_unit": @"utf16"};
}

// Native Motion colors round through float32; this tolerance applies only to
// requested style values, never to baseline/restore XML comparison.
BOOL SKTStyleEqual(id actual, id expected) {
    if ([actual isKindOfClass:NSDictionary.class] && [expected isKindOfClass:NSDictionary.class]) {
        if ([actual count] != [expected count]) return NO;
        for (id key in expected) if (!SKTStyleEqual(actual[key],expected[key])) return NO;
        return YES;
    }
    if ([actual isKindOfClass:NSArray.class] && [expected isKindOfClass:NSArray.class]) {
        if ([actual count] != [expected count]) return NO;
        for (NSUInteger i=0;i<[actual count];i++) if (!SKTStyleEqual(actual[i],expected[i])) return NO;
        return YES;
    }
    if (SKTNumber(actual) && SKTNumber(expected))
        return fabs([actual doubleValue]-[expected doubleValue]) <= 1e-6 * MAX(1,fabs([expected doubleValue]));
    return [actual isEqual:expected];
}
