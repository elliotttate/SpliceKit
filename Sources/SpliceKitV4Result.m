#import "SpliceKitV4Result.h"

NSDictionary *SpliceKitV4Result(NSString *operationID, BOOL ok, NSNumber *applied,
    NSDictionary *readback, NSString *revisionBefore, NSString *revisionAfter,
    NSString *undoKind, NSString *undoLabel, NSArray *warnings, NSDictionary *error) {
    return @{@"ok": @(ok), @"operation_id": operationID ?: @"",
        @"applied": applied ?: NSNull.null, @"readback": readback ?: NSNull.null,
        @"revision_before": revisionBefore ?: NSNull.null,
        @"revision_after": revisionAfter ?: NSNull.null,
        @"undo": @{@"kind": undoKind ?: @"none", @"label": undoLabel ?: @""},
        @"evidence_level": @"offline_tested", @"warnings": warnings ?: @[],
        @"error": error ?: NSNull.null};
}

NSDictionary *SpliceKitV4Error(NSString *operationID, NSString *code, NSString *message,
    NSNumber *applied, NSDictionary *readback) {
    return SpliceKitV4Result(operationID, NO, applied, readback, nil, nil,
        applied == nil ? @"unknown" : @"none", @"", @[],
        @{@"code": code ?: @"NATIVE_ERROR", @"message": message ?: code ?: @"Unknown error", @"retryable": @NO});
}

static BOOL SKV4Boolean(id value) {
    return [value isKindOfClass:NSNumber.class] &&
        CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID();
}
static BOOL SKV4StringOrNull(id value) {
    return value == NSNull.null || [value isKindOfClass:NSString.class];
}

BOOL SpliceKitV4IsEnvelope(NSDictionary *value) {
    if (![value isKindOfClass:NSDictionary.class] || !SKV4Boolean(value[@"ok"]) ||
        ![value[@"operation_id"] isKindOfClass:NSString.class] ||
        !(value[@"applied"] == NSNull.null || SKV4Boolean(value[@"applied"])) ||
        !(value[@"readback"] == NSNull.null || [value[@"readback"] isKindOfClass:NSDictionary.class]) ||
        !SKV4StringOrNull(value[@"revision_before"]) || !SKV4StringOrNull(value[@"revision_after"]) ||
        ![value[@"undo"] isKindOfClass:NSDictionary.class] ||
        ![@[@"native_group", @"none", @"unknown"] containsObject:value[@"undo"][@"kind"]] ||
        ![value[@"undo"][@"label"] isKindOfClass:NSString.class] ||
        ![@[@"static", @"offline_tested", @"live_verified"] containsObject:value[@"evidence_level"]] ||
        ![value[@"warnings"] isKindOfClass:NSArray.class]) return NO;
    id error = value[@"error"];
    if (error != NSNull.null && (![error isKindOfClass:NSDictionary.class] ||
        ![error[@"code"] isKindOfClass:NSString.class] ||
        ![error[@"message"] isKindOfClass:NSString.class] || !SKV4Boolean(error[@"retryable"]))) return NO;
    return [value[@"ok"] boolValue] == (error == NSNull.null) && [NSJSONSerialization isValidJSONObject:value];
}
