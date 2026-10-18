#import "SpliceKitV4OperationLedger.h"
#import "SpliceKitV4Result.h"
#import <CommonCrypto/CommonDigest.h>
#import <sys/file.h>
#import <sys/stat.h>
#import <fcntl.h>
#import <unistd.h>
#import <errno.h>

NSString *SpliceKitV4Fingerprint(NSDictionary *value) {
    if (![NSJSONSerialization isValidJSONObject:value]) return nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:value
        options:NSJSONWritingSortedKeys error:nil];
    if (!data) return nil;
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *hex = [NSMutableString string];
    for (NSUInteger i = 0; i < sizeof(digest); i++) [hex appendFormat:@"%02x", digest[i]];
    return hex;
}

BOOL SpliceKitV4OperationIsSettled(NSString *state) {
    return [@[@"COMPLETED", @"FAILED", @"UNKNOWN", @"RECONCILED"] containsObject:state];
}

@implementation SpliceKitV4OperationLedger {
    NSCondition *_condition;
    NSMutableDictionary *_records;
    NSString *_failure;
    NSUInteger _events;
    int _lockFD;
}

- (instancetype)initWithPath:(NSString *)path sessionID:(NSString *)sessionID {
    if (!(self = [super init])) return nil;
    _condition = [NSCondition new];
    _records = [NSMutableDictionary dictionary];
    _path = [path copy];
    _sessionID = [sessionID copy];
    _lockFD = -1;
    NSError *error = nil;
    NSString *directory = path.stringByDeletingLastPathComponent;
    if (![[NSFileManager defaultManager] createDirectoryAtPath:directory
        withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions: @0700} error:&error]) {
        _failure = @"LEDGER_IO_ERROR";
        return self;
    }
    _lockFD = open([[path stringByAppendingString:@".lock"] fileSystemRepresentation],
        O_CREAT | O_RDWR | O_NOFOLLOW, 0600);
    if (_lockFD < 0 || flock(_lockFD, LOCK_EX | LOCK_NB) != 0) {
        _failure = @"LEDGER_LOCKED";
        return self;
    }
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data && [[NSFileManager defaultManager] fileExistsAtPath:path]) _failure = @"LEDGER_IO_ERROR";
    if (data.length > 16 * 1024 * 1024) _failure = @"LEDGER_FULL";
    if (_failure || !data) return self;
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!text) { _failure = @"LEDGER_CORRUPT"; return self; }
    NSArray *lines = [text componentsSeparatedByString:@"\n"];
    for (NSUInteger index = 0; index < lines.count; index++) {
        NSString *line = lines[index];
        if (!line.length) continue;
        NSDictionary *record = [NSJSONSerialization JSONObjectWithData:
            [line dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
        if (![record isKindOfClass:NSDictionary.class] ||
            ![record[@"operation_id"] isKindOfClass:NSString.class] ||
            ![record[@"fingerprint"] isKindOfClass:NSString.class] ||
            ![record[@"state"] isKindOfClass:NSString.class] ||
            ![record[@"session_id"] isKindOfClass:NSString.class]) {
            // Only an incomplete tail is recoverable. Admission is fsynced before
            // native execution, so a torn reservation could not have run.
            if (index == lines.count - 1 && ![text hasSuffix:@"\n"]) break;
            _failure = @"LEDGER_CORRUPT";
            return self;
        }
        NSMutableDictionary *recovered = [record mutableCopy];
        recovered[@"recovered"] = @YES;
        if (!SpliceKitV4OperationIsSettled(record[@"state"])) {
            recovered[@"state"] = @"UNKNOWN";
            recovered[@"result"] = SpliceKitV4Error(record[@"operation_id"], @"OUTCOME_UNKNOWN",
                @"The previous FCP session ended before this operation settled. Reconcile; do not retry.", nil, nil);
        }
        _records[record[@"operation_id"]] = recovered;
    }
    // Repair any torn tail before permitting another append.
    if (![self compact]) _failure = @"LEDGER_IO_ERROR";
    return self;
}

- (void)dealloc { if (_lockFD >= 0) close(_lockFD); }

- (BOOL)compact {
    NSMutableData *data = [NSMutableData data];
    for (NSString *key in [[_records allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
        NSData *line = [NSJSONSerialization dataWithJSONObject:_records[key] options:0 error:nil];
        if (!line) return NO;
        [data appendData:line];
        [data appendBytes:"\n" length:1];
    }
    if (data.length > 8 * 1024 * 1024) return NO;
    // The private directory protects the atomic temporary file as well.
    if (![data writeToFile:_path options:NSDataWritingAtomic error:nil]) return NO;
    chmod(_path.fileSystemRepresentation, 0600);
    int fd = open(_path.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW);
    BOOL ok = fd >= 0 && fsync(fd) == 0;
    if (fd >= 0) close(fd);
    int directory = open(_path.stringByDeletingLastPathComponent.fileSystemRepresentation, O_RDONLY);
    if (directory >= 0) { if (fsync(directory) != 0) ok = NO; close(directory); }
    _events = 0;
    return ok;
}

- (BOOL)append:(NSDictionary *)record {
    if (_failure) return NO;
    NSData *json = [NSJSONSerialization dataWithJSONObject:record options:0 error:nil];
    if (!json || json.length > 1024 * 1024) { _failure = @"LEDGER_FULL"; return NO; }
    struct stat info = {0};
    BOOL atCapacity = stat(_path.fileSystemRepresentation, &info) == 0 &&
        info.st_size + json.length + 1 > 8 * 1024 * 1024;
    if ((++_events >= 128 || atCapacity) && ![self compact]) {
        _failure = @"LEDGER_FULL"; return NO;
    }
    if (stat(_path.fileSystemRepresentation, &info) == 0 &&
        info.st_size + json.length + 1 > 8 * 1024 * 1024) {
        _failure = @"LEDGER_FULL"; return NO;
    }
    NSMutableData *line = [json mutableCopy];
    [line appendBytes:"\n" length:1];
    int fd = open(_path.fileSystemRepresentation, O_CREAT | O_WRONLY | O_APPEND | O_NOFOLLOW, 0600);
    if (fd < 0) { _failure = @"LEDGER_IO_ERROR"; return NO; }
    const char *bytes = line.bytes;
    NSUInteger remaining = line.length;
    BOOL ok = YES;
    while (remaining) {
        ssize_t written = write(fd, bytes, remaining);
        if (written < 0 && errno == EINTR) continue;
        if (written <= 0) { ok = NO; break; }
        remaining -= (NSUInteger)written;
        bytes += written;
    }
    if (fsync(fd) != 0) ok = NO;
    close(fd);
    if (!ok) _failure = @"LEDGER_IO_ERROR";
    return ok;
}

- (NSDictionary *)reserve:(NSString *)operationID method:(NSString *)method
    fingerprint:(NSString *)fingerprint created:(BOOL *)created error:(NSString **)error {
    [_condition lock];
    if (created) *created = NO;
    if (error) *error = nil;
    NSDictionary *existing = _records[operationID];
    if (existing) {
        if (![existing[@"fingerprint"] isEqual:fingerprint] && error) *error = @"IDEMPOTENCY_CONFLICT";
        [_condition unlock];
        return existing;
    }
    if (_failure || _records.count >= 10000 || !fingerprint) {
        if (error) *error = _failure ?: @"LEDGER_FULL";
        [_condition unlock];
        return nil;
    }
    NSDictionary *record = @{@"operation_id": operationID, @"method": method,
        @"fingerprint": fingerprint, @"session_id": _sessionID, @"state": @"QUEUED",
        @"created_at": @([NSDate date].timeIntervalSince1970)};
    if (![self append:record]) {
        if (error) *error = _failure;
        [_condition unlock];
        return nil;
    }
    _records[operationID] = record;
    if (created) *created = YES;
    [_condition unlock];
    return record;
}

- (BOOL)update:(NSString *)operationID state:(NSString *)state result:(NSDictionary *)result
    details:(NSDictionary *)details {
    [_condition lock];
    NSMutableDictionary *record = [_records[operationID] mutableCopy];
    if (!record) { [_condition unlock]; return NO; }
    [record addEntriesFromDictionary:details ?: @{}];
    record[@"state"] = state;
    record[@"updated_at"] = @([NSDate date].timeIntervalSince1970);
    if (result) record[@"result"] = result;
    BOOL ok = [self append:record];
    if (!ok) {
        record[@"state"] = @"UNKNOWN";
        record[@"result"] = SpliceKitV4Error(operationID, @"LEDGER_IO_ERROR",
            @"The operation could not be durably settled. Reconcile; do not retry.", nil, nil);
    }
    _records[operationID] = record;
    [_condition broadcast];
    [_condition unlock];
    return ok;
}

- (NSDictionary *)operation:(NSString *)operationID {
    [_condition lock];
    NSDictionary *record = [_records[operationID] copy];
    [_condition unlock];
    return record;
}

- (NSDictionary *)waitFor:(NSString *)operationID timeout:(NSTimeInterval)timeout {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:MAX(0, timeout)];
    [_condition lock];
    while (_records[operationID] && !SpliceKitV4OperationIsSettled(_records[operationID][@"state"])) {
        if (![_condition waitUntilDate:deadline]) break;
    }
    NSDictionary *record = [_records[operationID] copy];
    [_condition unlock];
    return record;
}

- (NSDictionary *)summary {
    [_condition lock];
    NSMutableDictionary *counts = [NSMutableDictionary dictionary];
    for (NSDictionary *record in _records.allValues) {
        NSString *state = record[@"state"];
        counts[state] = @([counts[state] unsignedIntegerValue] + 1);
    }
    NSDictionary *summary = @{@"session_id": _sessionID, @"count": @(_records.count),
        @"states": counts, @"writable": @(_failure == nil), @"error": _failure ?: NSNull.null,
        @"path": _path, @"max_operations": @10000};
    [_condition unlock];
    return summary;
}
@end
