// Runs the actual Foundation ledger and native scheduler against an in-process
// fake host. No NSApplication, FCP, sockets, private classes or injected dylib.
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <stdatomic.h>
#import "SpliceKitV4Core.h"
#import "SpliceKitV4OperationLedger.h"

extern void SpliceKitV4SetTestHost(NSString *, NSDictionary *(^)(void), NSUndoManager *(^)(void), NSTimeInterval);
static NSMutableDictionary *handlers, *metadata;
static int checks;
static NSString *(^currentRevision)(void);
static NSMutableDictionary *requestRevisions;
#define CHECK(condition, label) do { if (!(condition)) { fprintf(stderr, "FAIL: %s\n", label); exit(1); } checks++; } while (0)

id SpliceKit_getActiveTimelineModule(void) { abort(); } // Test probe must always override this.
void SpliceKit_registerPluginMethod(NSString *name, SpliceKitMethodHandler block, NSDictionary *meta) {
    if (!handlers) { handlers = [NSMutableDictionary dictionary]; metadata = [NSMutableDictionary dictionary]; }
    handlers[name] = [block copy]; metadata[name] = meta;
}
NSDictionary *SpliceKit_handleFCPXMLExport(NSDictionary *params) {
    [@"<fcpxml><project name=\"fixture\"/></fcpxml>" writeToFile:params[@"path"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    return @{@"status": @"ok", @"path": params[@"path"]};
}
static NSDictionary *RPC(NSString *method, NSDictionary *params) {
    // Fixtures retain the original revision alongside each operation ID, just
    // as a client must do before sending. Nested calls inherit the outer fence.
    if (![metadata[method][@"readOnly"] boolValue] && !SpliceKitV4IsExecuting() && params[@"operation_id"]) {
        NSMutableDictionary *arguments = [params mutableCopy];
        @synchronized(requestRevisions) {
            NSString *key = [method stringByAppendingString:params[@"operation_id"]];
            if (!requestRevisions[key]) requestRevisions[key] = params[@"expected_revision"] ?: currentRevision();
            if (!arguments[@"expected_revision"]) arguments[@"expected_revision"] = requestRevisions[key];
        }
        params = arguments;
    }
    return SpliceKitV4Dispatch(method, params, handlers[method], metadata[method]);
}
static NSDictionary *Worker(NSDictionary *(^block)(void)) {
    __block NSDictionary *result;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        result = block(); dispatch_semaphore_signal(done);
    });
    while (dispatch_semaphore_wait(done, DISPATCH_TIME_NOW))
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.005, true);
    return result;
}
static void PumpUntil(BOOL (^done)(void)) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:2];
    while (!done() && deadline.timeIntervalSinceNow > 0)
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.005, true);
    CHECK(done(), "queued work settled");
}
static NSString *Error(NSDictionary *value) {
    return [value[@"error"] isKindOfClass:NSDictionary.class] ? value[@"error"][@"code"] : nil;
}

@interface Counter : NSObject
@property NSInteger value;
@end
@implementation Counter
@end

static void LedgerTests(NSString *root) {
    NSString *path = [root stringByAppendingPathComponent:@"ledger/events.jsonl"];
    @autoreleasepool {
        SpliceKitV4OperationLedger *ledger = [[SpliceKitV4OperationLedger alloc] initWithPath:path sessionID:@"first"];
        BOOL created = NO; NSString *error = nil;
        [ledger reserve:@"once" method:@"edit" fingerprint:@"hash" created:&created error:&error];
        CHECK(created && !error, "durable reservation");
        [ledger update:@"once" state:@"RUNNING" result:nil details:nil];
        [ledger reserve:@"once" method:@"edit" fingerprint:@"hash" created:&created error:&error];
        CHECK(!created && !error, "duplicate does not admit another job");
        [ledger reserve:@"once" method:@"edit" fingerprint:@"different" created:&created error:&error];
        CHECK([error isEqual:@"IDEMPOTENCY_CONFLICT"], "ID is bound to arguments");
        SpliceKitV4OperationLedger *locked = [[SpliceKitV4OperationLedger alloc] initWithPath:path sessionID:@"other-process"];
        CHECK(![locked.summary[@"writable"] boolValue], "exclusive file ownership");
        NSDictionary *pending = [ledger waitFor:@"once" timeout:0.002];
        CHECK([pending[@"state"] isEqual:@"RUNNING"], "deadline does not cancel operation");
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
            [ledger update:@"once" state:@"COMPLETED" result:SpliceKitV4Result(@"once", YES, @YES,
                @{@"value": @1}, nil, nil, @"none", @"", @[], nil) details:nil];
        });
        CHECK([[ledger waitFor:@"once" timeout:1][@"state"] isEqual:@"COMPLETED"], "late settlement wakes status waiter");
        error = nil;
        [ledger reserve:@"lost" method:@"edit" fingerprint:@"lost" created:&created error:&error];
        [ledger update:@"lost" state:@"RUNNING" result:nil details:nil];
        for (int i = 0; i < 140; i++)
            CHECK([ledger update:@"once" state:@"COMPLETED" result:nil details:nil], "journal compaction");
        // The autorelease scope releases both the ledger and the lock owner.
    }
    @autoreleasepool {
        SpliceKitV4OperationLedger *restored = [[SpliceKitV4OperationLedger alloc] initWithPath:path sessionID:@"second"];
        CHECK([[restored operation:@"lost"][@"state"] isEqual:@"UNKNOWN"], "restart recovers unfinished work as UNKNOWN");
        CHECK([[restored operation:@"once"][@"state"] isEqual:@"COMPLETED"], "completed historical result survives restart");
        BOOL created = YES; NSString *error = nil;
        [restored reserve:@"lost" method:@"edit" fingerprint:@"lost" created:&created error:&error];
        CHECK(!created && !error, "recovered UNKNOWN never re-executes");
    }
    NSString *corruptPath = [root stringByAppendingPathComponent:@"corrupt/events.jsonl"];
    [NSFileManager.defaultManager createDirectoryAtPath:corruptPath.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    [@"invalid\n" writeToFile:corruptPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    SpliceKitV4OperationLedger *corrupt = [[SpliceKitV4OperationLedger alloc] initWithPath:corruptPath sessionID:@"test"];
    CHECK(![corrupt.summary[@"writable"] boolValue], "corruption closes writes");
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        CHECK(argc == 2, "temporary directory argument");
        NSString *root = @(argv[1]);
        LedgerTests(root);
        Counter *counter = [Counter new];
        NSUndoManager *undo = [NSUndoManager new]; undo.groupsByEvent = NO;
        __block BOOL modal = NO, supported = YES;
        NSDictionary *(^snapshot)(void) = ^{
            return @{@"revision": [NSString stringWithFormat:@"r%ld-%@", (long)counter.value, undo.undoActionName],
                @"sequence_present": @YES, @"writes_enabled": @(supported), @"fcp_build": @"fake-build",
                @"modal": @{@"present": @(modal), @"title": modal ? @"Fixture sheet" : @""},
                @"undo": @{@"top_label": undo.undoActionName}};
        };
        requestRevisions = [NSMutableDictionary dictionary];
        currentRevision = ^{ return snapshot()[@"revision"]; };
        SpliceKitV4SetTestHost([root stringByAppendingPathComponent:@"host/events.jsonl"], snapshot, ^{ return undo; }, 0.03);
        SpliceKitV4RegisterMethods();
        CHECK(!SpliceKitV4RegisterUndo(counter, ^(id target) {}), "explicit inverse cannot register outside a writer operation");
        NSDictionary *session = RPC(@"v4.session.status", @{});
        CHECK(CFGetTypeID((__bridge CFTypeRef)session[@"readback"][@"writes_enabled"]) == CFBooleanGetTypeID(),
            "session write permission serializes as a JSON boolean, not integer one");
        SpliceKit_registerPluginMethod(@"v4.test.edit", ^NSDictionary *(NSDictionary *params) {
            CHECK(NSThread.isMainThread, "mutation executes on main thread");
            NSInteger previous = counter.value;
            CHECK(SpliceKitV4RegisterUndo(counter, ^(id target) { ((Counter *)target).value = previous; }), "explicit inverse belongs to the current writer group");
            counter.value++;
            return @{@"value": @(counter.value), @"forwarded_id": params[@"operation_id"]};
        }, @{@"readOnly": @NO});
        SpliceKit_registerPluginMethod(@"v4.test.read", ^NSDictionary *(NSDictionary *params) {
            CHECK(SpliceKitV4IsExecuting(), "read scope suppresses nested legacy modal handling");
            return @{@"value": @(counter.value)};
        }, @{@"readOnly": @YES});
        CHECK([Error(SpliceKitV4Dispatch(@"v4.test.edit", @{}, handlers[@"v4.test.edit"], metadata[@"v4.test.edit"])) isEqual:@"OPERATION_CONTRACT_REQUIRED"], "mutation requires caller-owned ID and revision");
        CHECK([Error(SpliceKitV4Dispatch(@"v4.test.edit", @{@"operation_id": @"no-fence"}, handlers[@"v4.test.edit"], metadata[@"v4.test.edit"])) isEqual:@"OPERATION_CONTRACT_REQUIRED"], "mutation rejects a missing fence");
        extern NSDictionary *SpliceKitV4XMLObservation(NSString *xml);
        NSString *sourceXML = @"<fcpxml><resources><asset id=\"r2\" duration=\"3s\" format=\"r1\"><media-rep src=\"file:///a.mov\"><bookmark>YWJj</bookmark></media-rep></asset></resources></fcpxml>";
        NSDictionary *observation = SpliceKitV4XMLObservation(sourceXML);
        NSDictionary *changedBookmark = SpliceKitV4XMLObservation([sourceXML stringByReplacingOccurrencesOfString:@"YWJj" withString:@"ZGVm"]);
        CHECK([observation[@"state"] isEqual:changedBookmark[@"state"]], "security-scoped bookmark payload alone is excluded");
        CHECK([observation[@"raw_fcpxml"] isEqual:sourceXML], "raw XML remains byte exact");
        for (NSString *field in @[@"file:///a.mov", @"3s", @"r1"])
            CHECK(![observation[@"state"] isEqual:SpliceKitV4XMLObservation([sourceXML stringByReplacingOccurrencesOfString:field withString:@"changed"])[@"state"]], "asset source/duration/format differences remain observable");
        CHECK(SpliceKitV4XMLObservation([sourceXML stringByReplacingOccurrencesOfString:@"YWJj" withString:@"opaque!"])[@"error"] != nil, "unexpected bookmark encoding fails closed");
        NSDictionary *xmlSnapshot = RPC(@"v4.state.snapshot", @{});
        CHECK([xmlSnapshot[@"readback"][@"state"][@"fcpxml"] containsString:@"<fcpxml>"], "independent native export snapshot retains complete XML");
        NSDictionary *first = Worker(^{ return RPC(@"v4.test.edit", @{@"operation_id": @"edit-1", @"expected_revision": snapshot()[@"revision"]}); });
        CHECK([first[@"ok"] boolValue] && counter.value == 1, "native operation completes");
        CHECK([first[@"undo"][@"kind"] isEqual:@"native_group"], "one named native group");
        CHECK([first[@"readback"][@"forwarded_id"] isEqual:@"edit-1"], "ID reaches handler");
        NSDictionary *same = RPC(@"v4.test.edit", @{@"operation_id": @"edit-1", @"expected_revision": first[@"revision_before"]});
        CHECK([same isEqual:first] && counter.value == 1, "cached result is returned verbatim");
        NSDictionary *readback = Worker(^{ return RPC(@"v4.test.read", @{}); });
        CHECK([readback[@"revision_after"] isEqual:first[@"revision_after"]], "independent read revision equals mutation revision");
        CHECK([readback[@"revision_before"] isEqual:readback[@"revision_after"]], "stable observation is stamped on both sides");
        CHECK([Error(RPC(@"v4.test.edit", @{@"operation_id": @"edit-1", @"other": @1})) isEqual:@"IDEMPOTENCY_CONFLICT"], "different request cannot reuse ID");
        NSDictionary *stale = Worker(^{ return RPC(@"v4.test.edit", @{@"operation_id": @"stale", @"expected_revision": @"wrong"}); });
        CHECK([Error(stale) isEqual:@"REVISION_MISMATCH"] && counter.value == 1, "revision mismatch never invokes handler");
        CHECK([stale[@"applied"] isEqual:@NO], "rejected request explicitly not applied");
        NSDictionary *undone = Worker(^{ return RPC(@"v4.history.undo", @{@"operation_id": @"edit-1"}); });
        CHECK([undone[@"ok"] boolValue] && counter.value == 0, "owned top group is undone");
        CHECK([RPC(@"v4.history.undo", @{@"operation_id": @"edit-1"}) isEqual:undone], "undo is itself idempotent");
        Worker(^{ return RPC(@"v4.test.edit", @{@"operation_id": @"edit-2"}); });
        [undo beginUndoGrouping]; [undo registerUndoWithTarget:counter handler:^(Counter *c) { c.value = 0; }];
        [undo setActionName:@"Human edit"]; [undo endUndoGrouping];
        NSDictionary *wrongTop = Worker(^{ return RPC(@"v4.history.undo", @{@"operation_id": @"undo-2", @"target_operation_id": @"edit-2"}); });
        CHECK([Error(wrongTop) isEqual:@"UNDO_NOT_TOP"] && [undo.undoActionName isEqual:@"Human edit"], "human undo group is protected");
        modal = YES;
        CHECK([Error(Worker(^{ return RPC(@"v4.test.edit", @{@"operation_id": @"modal-edit"}); })) isEqual:@"MODAL_PRESENT"], "modal blocks writes too");
        NSDictionary *blocked = Worker(^{ return RPC(@"v4.test.read", @{}); });
        CHECK([Error(blocked) isEqual:@"MODAL_PRESENT"], "read fails explicitly under modal");
        CHECK([blocked[@"readback"][@"modal"][@"title"] isEqual:@"Fixture sheet"] && modal, "modal is reported and left open");
        CHECK([Worker(^{ return RPC(@"v4.session.status", @{}); })[@"readback"][@"modal"][@"present"] boolValue], "session probe available under modal");
        modal = NO; supported = NO;
        CHECK([Error(Worker(^{ return RPC(@"v4.test.edit", @{@"operation_id": @"build"}); })) isEqual:@"UNSUPPORTED_BUILD"], "unsupported host build closes writes");
        supported = YES;
        NSInteger beforeConcurrent = counter.value;
        dispatch_group_t concurrent = dispatch_group_create();
        for (int i = 0; i < 8; i++) dispatch_group_async(concurrent, dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
            RPC(@"v4.test.edit", @{@"operation_id": @"concurrent"});
        });
        while (dispatch_group_wait(concurrent, DISPATCH_TIME_NOW))
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.005, true);
        CHECK(counter.value == beforeConcurrent + 1, "eight simultaneous duplicates apply exactly once");
        SpliceKit_registerPluginMethod(@"v4.test.drift", ^NSDictionary *(NSDictionary *params) {
            // Simulate an external/native edit arriving during an observation.
            counter.value++;
            return @{@"sample": @1};
        }, @{@"readOnly": @YES});
        NSDictionary *drift = Worker(^{ return RPC(@"v4.test.drift", @{}); });
        CHECK([Error(drift) isEqual:@"OBSERVATION_CHANGED"], "observation drift is not accepted");
        CHECK(![drift[@"revision_before"] isEqual:drift[@"revision_after"]], "drift includes both revision tokens");
        SpliceKit_registerPluginMethod(@"v4.test.malformed", ^NSDictionary *(NSDictionary *params) {
            return @{@"ok": @YES};
        }, @{@"readOnly": @YES});
        CHECK([Error(Worker(^{ return RPC(@"v4.test.malformed", @{}); })) isEqual:@"INVALID_RESULT_ENVELOPE"], "malformed domain envelope fails explicitly");
        SpliceKit_registerPluginMethod(@"v4.test.readViolation", ^NSDictionary *(NSDictionary *params) {
            return RPC(@"v4.test.edit", @{});
        }, @{@"readOnly": @YES});
        CHECK([Error(Worker(^{ return RPC(@"v4.test.readViolation", @{}); })) isEqual:@"READ_ONLY_VIOLATION"], "read handler cannot nest a mutation");
        SpliceKit_registerPluginMethod(@"v4.test.responsive", ^NSDictionary *(NSDictionary *params) {
            dispatch_semaphore_t statusDone = dispatch_semaphore_create(0);
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                NSDictionary *status = RPC(@"v4.operation.status", @{@"operation_id": @"responsive"});
                if ([status[@"readback"][@"state"] isEqual:@"RUNNING"]) dispatch_semaphore_signal(statusDone);
            });
            BOOL immediate = dispatch_semaphore_wait(statusDone, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0;
            return @{@"status_did_not_wait_for_main": @(immediate)};
        }, @{@"readOnly": @NO, @"v4Undo": @"none"});
        NSDictionary *responsive = Worker(^{ return RPC(@"v4.test.responsive", @{@"operation_id": @"responsive"}); });
        CHECK([responsive[@"readback"][@"status_did_not_wait_for_main"] boolValue], "status responds while writer is executing on main");
        SpliceKit_registerPluginMethod(@"v4.test.slow", ^NSDictionary *(NSDictionary *params) {
            [NSThread sleepForTimeInterval:0.09];
            return @{@"done": @YES};
        }, @{@"readOnly": @NO, @"v4Undo": @"none"});
        NSDictionary *pending = Worker(^{ return RPC(@"v4.test.slow", @{@"operation_id": @"slow"}); });
        CHECK([pending[@"status"] isEqual:@"pending"] && pending[@"applied"] == NSNull.null, "deadline returns pending with unknown application");
        PumpUntil(^BOOL { return [RPC(@"v4.operation.status", @{@"operation_id": @"slow"})[@"readback"][@"state"] isEqual:@"COMPLETED"]; });
        CHECK([RPC(@"v4.operation.status", @{@"operation_id": @"slow"})[@"readback"][@"result"][@"ok"] boolValue], "timeout then status observes final result");
        // Main-thread callers must not block the run loop waiting on themselves.
        NSDictionary *queued = RPC(@"v4.test.edit", @{@"operation_id": @"queued"});
        CHECK([queued[@"status"] isEqual:@"pending"], "main-thread mutation admission is nonblocking");
        NSDictionary *observed = RPC(@"v4.operation.status", @{@"operation_id": @"queued"});
        CHECK([observed[@"readback"][@"state"] isEqual:@"QUEUED"], "status bypasses a queued writer");
        CHECK([RPC(@"v4.test.read", @{})[@"readback"][@"value"] integerValue] == counter.value, "direct main-thread read does not wait behind queued work");
        CHECK([Worker(^{ return RPC(@"v4.test.read", @{}); })[@"ok"] boolValue], "ordinary reads bypass writer admission");
        PumpUntil(^BOOL { return [RPC(@"v4.operation.status", @{@"operation_id": @"queued"})[@"readback"][@"state"] isEqual:@"COMPLETED"]; });
        SpliceKit_registerPluginMethod(@"v4.test.nested", ^NSDictionary *(NSDictionary *params) {
            return RPC(@"v4.test.edit", @{});
        }, @{@"readOnly": @NO});
        NSDictionary *nested = Worker(^{ return RPC(@"v4.test.nested", @{@"operation_id": @"nested"}); });
        CHECK([nested[@"operation_id"] isEqual:@"nested"] && [nested[@"ok"] boolValue], "nested RPC inherits operation ID");
        CHECK([nested[@"undo"][@"kind"] isEqual:@"native_group"], "nested mutation shares outer undo group");
        SpliceKit_registerPluginMethod(@"v4.test.conflict", ^NSDictionary *(NSDictionary *params) {
            return RPC(@"v4.test.edit", @{@"operation_id": @"different-child"});
        }, @{@"readOnly": @NO});
        CHECK([Error(Worker(^{ return RPC(@"v4.test.conflict", @{@"operation_id": @"parent"}); })) isEqual:@"NESTED_OPERATION_CONFLICT"], "nested mutation cannot acquire an independent ID");
        SpliceKit_registerPluginMethod(@"v4.test.throw", ^NSDictionary *(NSDictionary *params) {
            [NSException raise:@"Fixture" format:@"partial execution"];
            return @{};
        }, @{@"readOnly": @NO, @"v4Undo": @"none"});
        NSDictionary *unknown = Worker(^{ return RPC(@"v4.test.throw", @{@"operation_id": @"unknown"}); });
        CHECK([unknown[@"status"] isEqual:@"unknown"] && unknown[@"applied"] == NSNull.null, "native exception is ambiguous");
        CHECK([RPC(@"v4.test.throw", @{@"operation_id": @"unknown"}) isEqual:unknown], "UNKNOWN cannot be retried with same ID");
        NSDictionary *reconcile = Worker(^{ return RPC(@"v4.operation.reconcile", @{@"operation_id": @"unknown"}); });
        CHECK([reconcile[@"readback"][@"state"] isEqual:@"UNKNOWN"] && [reconcile[@"readback"][@"reexecuted"] isEqual:@NO], "generic observation never guesses an outcome");
        NSDictionary *settled = Worker(^{ return RPC(@"v4.operation.reconcile", @{@"operation_id": @"unknown", @"resolution": @"not_applied",
            @"expected_revision": snapshot()[@"revision"], @"evidence": @{@"native_value": @(counter.value)}}); });
        CHECK([settled[@"readback"][@"state"] isEqual:@"RECONCILED"], "explicit evidence can settle UNKNOWN without native replay");
        NSData *json = [NSJSONSerialization dataWithJSONObject:first options:0 error:nil];
        CHECK(json != nil && first[@"error"] == NSNull.null, "native envelope keeps explicit null error");
        NSArray *samples = @[session, first, same, readback, stale, undone, wrongTop, blocked, drift, pending, nested, unknown, reconcile, settled];
        CHECK([[NSJSONSerialization dataWithJSONObject:samples options:0 error:nil]
            writeToFile:[root stringByAppendingPathComponent:@"envelopes.json"] atomically:YES], "native envelope fixtures exported");
        printf("%d native offline checks passed\n", checks);
        return 0;
    }
}
