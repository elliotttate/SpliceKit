#import "SpliceKitV4Core.h"
#import "SpliceKitV4OperationLedger.h"
#import "SpliceKit.h"
#import <AppKit/AppKit.h>
#import <objc/message.h>
#import <CommonCrypto/CommonDigest.h>
#include <dlfcn.h>

#ifndef SPLICEKIT_VERSION
#define SPLICEKIT_VERSION "development"
#endif

extern void SpliceKit_registerPluginMethod(NSString *, SpliceKitMethodHandler, NSDictionary *);
extern NSDictionary *SpliceKit_handleFCPXMLExport(NSDictionary *);

static SpliceKitV4OperationLedger *sLedger;
static dispatch_queue_t sWriter;
static NSMutableDictionary *sContext; // Main-thread-only, including nested RPCs.
static NSUInteger sReadDepth; // Suppress legacy modal handling inside v4 reads too.
static NSMutableDictionary *sUndoOwners; // Main-thread-only; never recovered from disk.
static NSMapTable *sUndoEpochs;
static NSString *sSessionID;
static NSTimeInterval sDeadline = 20.0;

// C logical/comparison expressions have type int. Boxing them directly emits
// JSON 0/1 instead of the booleans required by the typed session contract.
static NSNumber *SKV4Boolean(BOOL value) { return value ? @YES : @NO; }
#ifdef SPLICEKIT_V4_TESTING
static NSDictionary *(^sTestSnapshot)(void);
static NSUndoManager *(^sTestUndoManager)(void);
void SpliceKitV4SetTestHost(NSString *path, NSDictionary *(^snapshot)(void),
    NSUndoManager *(^undoManager)(void), NSTimeInterval deadline) {
    sSessionID = NSUUID.UUID.UUIDString;
    sLedger = [[SpliceKitV4OperationLedger alloc] initWithPath:path sessionID:sSessionID];
    sTestSnapshot = [snapshot copy];
    sTestUndoManager = [undoManager copy];
    sDeadline = deadline;
    sUndoOwners = [NSMutableDictionary dictionary];
}
#endif

static void SKV4Initialize(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sWriter = dispatch_queue_create("com.splicekit.v4.writer", DISPATCH_QUEUE_SERIAL);
        sUndoOwners = [NSMutableDictionary dictionary];
        sUndoEpochs = [NSMapTable weakToStrongObjectsMapTable];
    });
    @synchronized (sWriter) {
        if (!sLedger) {
            sSessionID = NSUUID.UUID.UUIDString;
            NSString *bundle = NSBundle.mainBundle.bundlePath ?: @"unknown";
            NSString *scope = [SpliceKitV4Fingerprint(@{@"bundle": bundle}) substringToIndex:16];
            NSString *base = [NSHomeDirectory() stringByAppendingPathComponent:
                @"Library/Application Support/SpliceKit/v4"];
            NSString *path = [[base stringByAppendingPathComponent:scope]
                stringByAppendingPathComponent:@"operations.jsonl"];
            sLedger = [[SpliceKitV4OperationLedger alloc] initWithPath:path sessionID:sSessionID];
        }
    }
}

BOOL SpliceKitV4IsExecuting(void) { return NSThread.isMainThread && (sContext != nil || sReadDepth > 0); }

// All selectors below are statically checked against the 12.4 (454072) binary;
// docs/v4/CORE-SELECTORS.md records class, signature and the reproduction command.
static id SKV4Object(id object, NSString *selector) {
    SEL sel = NSSelectorFromString(selector);
    if (![object respondsToSelector:sel]) return nil;
    NSMethodSignature *signature = [object methodSignatureForSelector:sel];
    if (signature.numberOfArguments != 2 || signature.methodReturnType[0] != '@') return nil;
    return ((id (*)(id, SEL))objc_msgSend)(object, sel);
}

static id SKV4Sequence(void) {
    return SKV4Object(SpliceKit_getActiveTimelineModule(), @"sequence");
}

static NSUndoManager *SKV4UndoManager(void) {
#ifdef SPLICEKIT_V4_TESTING
    if (sTestUndoManager) return sTestUndoManager();
#endif
    // Resolve from the sequence's owning document, never Browser focus or the
    // first active library. That fallback could undo another document's edit.
    id document = SKV4Object(SKV4Sequence(), @"modelDocument");
    id manager = SKV4Object(SKV4Object(document, @"undoHandler"), @"undoManager");
    return [manager isKindOfClass:NSUndoManager.class] ? manager : nil;
}
BOOL SpliceKitV4RegisterUndo(id target, void (^inverse)(id)) {
    if (!NSThread.isMainThread || !sContext || !target || !inverse) return NO;
    NSUndoManager *manager = SKV4UndoManager();
    if (!manager.isUndoRegistrationEnabled || manager.groupingLevel == 0) return NO;
    [manager registerUndoWithTarget:target handler:inverse];
    return YES;
}

static NSUInteger SKV4UndoEpoch(NSUndoManager *manager) {
    if (!manager) return 0;
    if (![sUndoEpochs objectForKey:manager]) {
        [sUndoEpochs setObject:@0 forKey:manager];
        __weak NSUndoManager *weakManager = manager;
        // No host swizzles: conservative revision invalidation on native undo
        // registrations, group closure, undo and redo (including human edits).
        for (NSString *name in @[NSUndoManagerDidCloseUndoGroupNotification,
            NSUndoManagerDidUndoChangeNotification, NSUndoManagerDidRedoChangeNotification]) {
            [NSNotificationCenter.defaultCenter addObserverForName:name object:manager queue:nil
                usingBlock:^(NSNotification *notification) {
                    NSUndoManager *owner = weakManager;
                    if (owner && NSThread.isMainThread) {
                        NSUInteger epoch = [[sUndoEpochs objectForKey:owner] unsignedIntegerValue];
                        [sUndoEpochs setObject:@(epoch + 1) forKey:owner];
                    }
                }];
        }
    }
    return [[sUndoEpochs objectForKey:manager] unsignedIntegerValue];
}

static NSDictionary *SKV4Modal(void) {
    NSWindow *modal = NSApp.modalWindow;
    if (!modal) {
        for (NSWindow *window in NSApp.windows) {
            if (window.attachedSheet) { modal = window.attachedSheet; break; }
        }
    }
    return @{@"present": SKV4Boolean(modal != nil), @"title": modal.title ?: @""};
}

static NSString *SKV4DylibHash(void) {
    static NSString *hash;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Dl_info info = {0};
        if (!dladdr((const void *)SpliceKitV4Dispatch, &info) || !info.dli_fname) return;
        NSInputStream *stream = [NSInputStream inputStreamWithFileAtPath:
            [NSString stringWithUTF8String:info.dli_fname]];
        [stream open];
        CC_SHA256_CTX context;
        CC_SHA256_Init(&context);
        uint8_t bytes[65536];
        NSInteger size;
        while ((size = [stream read:bytes maxLength:sizeof(bytes)]) > 0)
            CC_SHA256_Update(&context, bytes, (CC_LONG)size);
        [stream close];
        if (size < 0) return;
        unsigned char digest[CC_SHA256_DIGEST_LENGTH];
        CC_SHA256_Final(digest, &context);
        NSMutableString *hex = [NSMutableString string];
        for (NSUInteger i = 0; i < sizeof(digest); i++) [hex appendFormat:@"%02x", digest[i]];
        hash = hex;
    });
    return hash;
}

static NSDictionary *SKV4Snapshot(void) {
#ifdef SPLICEKIT_V4_TESTING
    if (sTestSnapshot) return sTestSnapshot();
#endif
    NSCAssert(NSThread.isMainThread, @"FCP state must be read on the main thread");
    id sequence = SKV4Sequence();
    id document = SKV4Object(sequence, @"modelDocument");
    id library = SKV4Object(document, @"library");
    if (!sequence) {
        // Status-only fallback when no sequence is open. Never used for undo.
        library = SKV4Object(NSApp.delegate, @"_targetLibrary");
        document = SKV4Object(library, @"libraryDocument");
    }
    NSUndoManager *manager = SKV4UndoManager();
    NSUInteger epoch = SKV4UndoEpoch(manager);
    id items = SKV4Object(SKV4Object(sequence, @"primaryObject"), @"containedItems");
    // This is a cheap, session-scoped concurrency token, not a semantic XML hash.
    // Unregistered raw setters are outside its coverage and outside the v4 API.
    NSDictionary *fingerprint = @{@"session_id": sSessionID,
        @"sequence": [NSString stringWithFormat:@"%p", sequence],
        @"document": [NSString stringWithFormat:@"%p", document], @"undo_epoch": @(epoch),
        @"undo_top": manager.undoActionName ?: @"",
        @"items": [items respondsToSelector:@selector(count)] ? @([items count]) : @0,
        @"sequence_name": SKV4Object(sequence, @"displayName") ?: @""};
    // UNVERIFIED: Phase-two FCP tests must prove notification coverage for
    // supported native/manual edits. This token cannot see unregistered setters.
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    NSString *build = info[@"CFBundleVersion"] ?: @"unknown";
    BOOL blockUnsupported = ![[NSProcessInfo.processInfo.environment
        objectForKey:@"SPLICEKIT_V4_BLOCK_UNSUPPORTED_BUILD"] isEqualToString:@"0"];
    NSArray *supported = @[@"454072"];
    BOOL supportedBuild = [supported containsObject:build];
    NSURL *url = SKV4Object(library, @"URL");
    return @{@"session_id": sSessionID, @"revision": sequence ? SpliceKitV4Fingerprint(fingerprint) : NSNull.null,
        @"revision_mode": @"session_undo_epoch", @"sequence_present": SKV4Boolean(sequence != nil),
        @"sequence": @{@"name": SKV4Object(sequence, @"displayName") ?: @""},
        @"library": @{@"name": SKV4Object(library, @"displayName") ?: @"",
            @"path": [url isKindOfClass:NSURL.class] ? url.path : @""},
        @"modal": SKV4Modal(), @"fcp_version": info[@"CFBundleShortVersionString"] ?: @"unknown",
        @"fcp_build": build, @"splicekit_version": @SPLICEKIT_VERSION,
        @"dylib_sha256": SKV4DylibHash() ?: NSNull.null, @"supported_builds": supported,
        @"supported_build": @(supportedBuild), @"block_unsupported_builds": @(blockUnsupported),
        @"writes_enabled": SKV4Boolean(!blockUnsupported || supportedBuild),
        @"undo": @{@"available": SKV4Boolean(manager != nil), @"can_undo": @(manager.canUndo),
            @"top_label": manager.undoActionName ?: @"", @"grouping_level": @(manager.groupingLevel)}};
}

static NSString *SKV4Revision(NSDictionary *snapshot) {
    return [snapshot[@"revision"] isKindOfClass:NSString.class] ? snapshot[@"revision"] : nil;
}

// Comparison contract: exact except security-scoped bookmark bytes.
// Preserve raw XML and every byte outside bookmark text, including IDs and dates.
// Asset source paths, durations and format IDs are also compared explicitly.
NSDictionary *SpliceKitV4XMLObservation(NSString *xml) {
    NSError *error = nil;
    NSXMLDocument *document = [[NSXMLDocument alloc] initWithXMLString:xml
        options:NSXMLNodeLoadExternalEntitiesNever error:&error];
    if (!document || error) return @{ @"error": @"Cannot parse native FCPXML observation" };
    NSArray *bookmarks = [document nodesForXPath:@"//bookmark" error:&error];
    NSRegularExpression *pattern = [NSRegularExpression regularExpressionWithPattern:
        @"(<bookmark(?:\\s[^>]*)?>)[A-Za-z0-9+/=\\s]*(</bookmark\\s*>)" options:0 error:&error];
    NSRange range = NSMakeRange(0, xml.length);
    if (error || [pattern numberOfMatchesInString:xml options:0 range:range] != bookmarks.count)
        return @{ @"error": @"Unexpected bookmark encoding; no additional normalization allowed" };
    NSString *semantic = [pattern stringByReplacingMatchesInString:xml options:0
        range:range withTemplate:@"$1$2"];
    NSMutableArray *identities = [NSMutableArray array];
    for (NSXMLElement *asset in [document nodesForXPath:@"/fcpxml/resources/asset" error:&error]) {
        NSMutableArray *sources = [NSMutableArray array];
        NSString *legacy = [asset attributeForName:@"src"].stringValue;
        if (legacy) [sources addObject:legacy];
        for (NSXMLElement *rep in [asset elementsForName:@"media-rep"])
            [sources addObject:[rep attributeForName:@"src"].stringValue ?: NSNull.null];
        [identities addObject:@{ @"id": [asset attributeForName:@"id"].stringValue ?: NSNull.null,
            @"duration": [asset attributeForName:@"duration"].stringValue ?: NSNull.null,
            @"format": [asset attributeForName:@"format"].stringValue ?: NSNull.null, @"sources": sources }];
    }
    return @{ @"state": @{ @"fcpxml": semantic, @"asset_identity": identities },
        @"raw_fcpxml": xml, @"comparison": @"exact except security-scoped bookmark bytes" };
}

// Independent native export; never substitute a cached observation.
static NSDictionary *SKV4SemanticSnapshot(void) {
    char *pattern = strdup([NSTemporaryDirectory()
        stringByAppendingPathComponent:@"splicekit-v4-snapshot.XXXXXX"].fileSystemRepresentation);
    if (!mkdtemp(pattern)) { free(pattern); return @{@"error": @"Cannot create private snapshot directory"}; }
    NSString *directory = [NSString stringWithUTF8String:pattern];
    free(pattern);
    NSString *path = [directory stringByAppendingPathComponent:@"project.fcpxml"];
    @try {
        NSDictionary *exported = SpliceKit_handleFCPXMLExport(@{@"path": path});
        if (![exported[@"status"] isEqual:@"ok"]) return @{@"error": exported[@"error"] ?: @"Native XML export failed"};
        NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
        if (!attributes || [attributes[NSFileSize] unsignedLongLongValue] > 8 * 1024 * 1024)
            return @{@"error": @"Native snapshot is missing or exceeds the 8 MiB observation limit"};
        NSString *xml = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
        if (!xml.length) return @{@"error": @"Native snapshot is empty or not UTF-8"};
        NSMutableDictionary *observation = [SpliceKitV4XMLObservation(xml) mutableCopy];
        observation[@"revision"] = SKV4Revision(SKV4Snapshot()) ?: NSNull.null;
        return observation;
    } @finally {
        [NSFileManager.defaultManager removeItemAtPath:directory error:nil];
    }
}

static NSDictionary *SKV4Normalize(NSDictionary *raw, NSString *operationID, BOOL mutation) {
    if (SpliceKitV4IsEnvelope(raw)) {
        NSMutableDictionary *result = [raw mutableCopy];
        result[@"operation_id"] = operationID;
        return result;
    }
    if (raw && (![raw isKindOfClass:NSDictionary.class] || raw[@"ok"] ||
        ![NSJSONSerialization isValidJSONObject:raw]))
        return SpliceKitV4Error(operationID, @"INVALID_RESULT_ENVELOPE",
            @"The handler returned a malformed v4 envelope or non-JSON result", mutation ? nil : @NO, nil);
    id error = raw[@"error"];
    if (!raw || (error && error != NSNull.null)) {
        NSString *message = [error isKindOfClass:NSString.class] ? error : [error description];
        return SpliceKitV4Error(operationID, @"NATIVE_ERROR", message ?: @"Handler returned no result",
            mutation ? nil : @NO, nil);
    }
    return SpliceKitV4Result(operationID, YES, mutation ? @YES : @NO, raw, nil, nil,
        @"none", @"", @[], nil);
}

static NSDictionary *SKV4RecordResult(NSDictionary *record) {
    if (record[@"result"]) return record[@"result"];
    NSMutableDictionary *pending = [SpliceKitV4Result(record[@"operation_id"], YES, nil,
        @{@"state": record[@"state"] ?: @"QUEUED"}, nil, nil, @"unknown", @"", @[], nil) mutableCopy];
    pending[@"status"] = @"pending";
    return pending;
}

static void SKV4OnMain(dispatch_block_t block) {
    // UNVERIFIED: Real FCP modal/startup loops need phase-two scheduling tests.
    CFRunLoopPerformBlock(CFRunLoopGetMain(), kCFRunLoopCommonModes, block);
    CFRunLoopWakeUp(CFRunLoopGetMain());
}

static NSDictionary *SKV4Read(NSString *method, NSDictionary *params, SpliceKitMethodHandler handler) {
    NSString *operationID = params[@"operation_id"] ?: NSUUID.UUID.UUIDString;
    __block NSDictionary *result;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    dispatch_block_t work = ^{
        sReadDepth++;
        NSDictionary *before;
        @try {
            before = SKV4Snapshot();
            // Status and session probes remain usable while a modal is open.
            if (![method isEqualToString:@"v4.session.status"] &&
                ![method isEqualToString:@"v4.operation.status"]) {
                if ([before[@"modal"][@"present"] boolValue]) {
                    result = SpliceKitV4Error(operationID, @"MODAL_PRESENT",
                        before[@"modal"][@"title"], @NO, @{@"modal": before[@"modal"]});
                }
            }
            if (!result) result = SKV4Normalize(handler(params), operationID, NO);
            NSDictionary *after = SKV4Snapshot();
            NSString *beforeRevision = SKV4Revision(before), *afterRevision = SKV4Revision(after);
            if (beforeRevision != afterRevision && ![beforeRevision isEqual:afterRevision]) {
                result = SpliceKitV4Error(operationID, @"OBSERVATION_CHANGED",
                    @"The sequence changed during observation; obtain a fresh readback", @NO,
                    @{@"observation": result[@"readback"] ?: NSNull.null});
            }
            NSMutableDictionary *stamped = [result mutableCopy];
            stamped[@"revision_before"] = beforeRevision ?: NSNull.null;
            stamped[@"revision_after"] = afterRevision ?: NSNull.null;
            result = stamped;
        } @catch (NSException *exception) {
            result = SpliceKitV4Error(operationID, @"NATIVE_EXCEPTION", exception.reason, @NO, nil);
        } @finally { sReadDepth--; dispatch_semaphore_signal(done); }
    };
    if (NSThread.isMainThread) work();
    else {
        SKV4OnMain(work);
        if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(sDeadline * NSEC_PER_SEC))))
            return SpliceKitV4Error(operationID, @"READ_TIMEOUT", @"Main-thread observation timed out", @NO, nil);
    }
    return result;
}

static NSDictionary *SKV4Preflight(NSString *operationID, NSDictionary *params,
    NSDictionary *metadata, NSDictionary *before) {
    if ([before[@"modal"][@"present"] boolValue])
        return SpliceKitV4Error(operationID, @"MODAL_PRESENT", before[@"modal"][@"title"],
            @NO, @{@"modal": before[@"modal"]});
    if (![before[@"writes_enabled"] boolValue])
        return SpliceKitV4Error(operationID, @"UNSUPPORTED_BUILD",
            @"This FCP build is not in the v4 supported-build list", @NO,
            @{@"fcp_build": before[@"fcp_build"] ?: @"unknown"});
    BOOL requiresSequence = metadata[@"v4RequiresSequence"] ? [metadata[@"v4RequiresSequence"] boolValue] : YES;
    if (requiresSequence && ![before[@"sequence_present"] boolValue])
        return SpliceKitV4Error(operationID, @"NO_ACTIVE_SEQUENCE", @"An active sequence is required", @NO, nil);
    if (params[@"expected_revision"] && ![params[@"expected_revision"] isEqual:SKV4Revision(before)])
        return SpliceKitV4Error(operationID, @"REVISION_MISMATCH", @"The active sequence revision changed", @NO, before);
    return nil;
}

static void SKV4Execute(NSString *method, NSDictionary *params,
    NSDictionary *metadata, SpliceKitMethodHandler handler, NSString *operationID) {
    @autoreleasepool {
        NSDictionary *before;
        NSMutableDictionary *result;
        NSUndoManager *manager;
        BOOL groupOpen = NO, invoked = NO;
        NSString *label = [NSString stringWithFormat:@"SpliceKit v4 %@ [%@]", method, operationID];
        NSString *undoKind = metadata[@"v4Undo"] ?: @"native_group";
        @try {
            before = SKV4Snapshot();
            NSDictionary *error = SKV4Preflight(operationID, params, metadata, before);
            if (error) { result = [error mutableCopy]; }
            else {
                if ([undoKind isEqualToString:@"native_group"]) {
                    manager = SKV4UndoManager();
                    if (!manager || !manager.isUndoRegistrationEnabled || manager.groupingLevel != 0) {
                        result = [SpliceKitV4Error(operationID, @"UNDO_UNAVAILABLE",
                            @"An idle owning native undo manager is required", @NO, nil) mutableCopy];
                    }
                }
                if (!result && [sLedger update:operationID state:@"RUNNING" result:nil
                    details:@{@"revision_before": SKV4Revision(before) ?: NSNull.null}]) {
                    sContext = [@{@"operation_id": operationID,
                        @"revision_before": SKV4Revision(before) ?: NSNull.null} mutableCopy];
                    // UNVERIFIED: FFUndoHandler transactions must be exercised
                    // live inside this outer owning NSUndoManager group.
                    if (manager) { [manager beginUndoGrouping]; groupOpen = YES; [manager setActionName:label]; }
                    invoked = YES;
                    result = [SKV4Normalize(handler(params), operationID, YES) mutableCopy];
                }
            }
        } @catch (NSException *exception) {
            result = [SpliceKitV4Error(operationID, @"NATIVE_EXCEPTION", exception.reason,
                invoked ? nil : @NO, nil) mutableCopy];
        } @finally {
            if (groupOpen) {
                @try {
                    if (manager.groupingLevel != 1) {
                        [NSException raise:@"UnbalancedUndoGroups"
                            format:@"The handler did not restore the owning group level"];
                    }
                    [manager setActionName:label]; [manager endUndoGrouping];
                }
                @catch (NSException *exception) {
                    result = [SpliceKitV4Error(operationID, @"UNDO_GROUP_FAILED", exception.reason, nil, nil) mutableCopy];
                }
            }
            sContext = nil;
        }
        // A failed RUNNING journal write must never enter the handler.
        if (!result) return;
        @try {
            NSDictionary *after = SKV4Snapshot();
            result[@"revision_before"] = SKV4Revision(before) ?: NSNull.null;
            result[@"revision_after"] = SKV4Revision(after) ?: NSNull.null;
            if (groupOpen && manager.groupingLevel == 0 && manager == SKV4UndoManager() &&
                manager.canUndo && [manager.undoActionName isEqualToString:label]) {
                result[@"undo"] = @{@"kind": @"native_group", @"label": label};
                sUndoOwners[operationID] = @{@"manager": manager, @"sequence_revision": SKV4Revision(after) ?: NSNull.null,
                    @"label": label, @"session_id": sSessionID};
            } else if (invoked && [undoKind isEqualToString:@"native_group"] &&
                ![result[@"applied"] isEqual:@NO]) {
                result[@"undo"] = @{@"kind": @"unknown", @"label": label};
                NSMutableArray *warnings = [result[@"warnings"] mutableCopy];
                [warnings addObject:@"Native undo registration was not observed; no rollback is promised."];
                result[@"warnings"] = warnings;
            } else if (![undoKind isEqualToString:@"native_group"]) {
                result[@"undo"] = @{@"kind": @"none", @"label": @""};
            }
        } @catch (NSException *exception) {
            result = [SpliceKitV4Error(operationID, @"READBACK_FAILED", exception.reason,
                invoked ? nil : @NO, nil) mutableCopy];
        }
        NSString *state = [result[@"ok"] boolValue] ? @"COMPLETED" :
            (result[@"applied"] == NSNull.null ? @"UNKNOWN" : @"FAILED");
        result[@"status"] = [state lowercaseString];
        [sLedger update:operationID state:state result:result details:nil];
    }
}

NSDictionary *SpliceKitV4Dispatch(NSString *method, NSDictionary *params,
    SpliceKitMethodHandler handler, NSDictionary *metadata) {
    SKV4Initialize();
    if (!handler) return SpliceKitV4Error(@"", @"METHOD_NOT_FOUND", method, @NO, nil);
    if (metadata[@"v4Undo"] && ![@[@"none", @"native_group"] containsObject:metadata[@"v4Undo"]])
        return SpliceKitV4Error(@"", @"INVALID_CAPABILITY", @"v4Undo must be native_group or none", @NO, nil);
    if (params[@"operation_id"] && (![params[@"operation_id"] isKindOfClass:NSString.class] ||
        ![params[@"operation_id"] length] || [params[@"operation_id"] length] > 200))
        return SpliceKitV4Error(@"", @"INVALID_ARGUMENT", @"operation_id must be a nonempty string up to 200 characters", @NO, nil);
    if (params[@"expected_revision"] && ![params[@"expected_revision"] isKindOfClass:NSString.class])
        return SpliceKitV4Error(params[@"operation_id"], @"INVALID_ARGUMENT", @"expected_revision must be a string", @NO, nil);
    if ([params[@"async"] respondsToSelector:@selector(boolValue)] && [params[@"async"] boolValue])
        return SpliceKitV4Error(params[@"operation_id"], @"INVALID_ARGUMENT", @"v4 uses pending/status, not legacy async", @NO, nil);
    NSMutableDictionary *arguments = [params mutableCopy];
    if ([method isEqualToString:@"v4.history.undo"] && !arguments[@"target_operation_id"] && arguments[@"operation_id"]) {
        arguments[@"target_operation_id"] = arguments[@"operation_id"];
        arguments[@"operation_id"] = [@"undo:" stringByAppendingString:arguments[@"operation_id"]];
    }
    NSString *operationID = arguments[@"operation_id"] ?: (NSThread.isMainThread && sContext ? sContext[@"operation_id"] : NSUUID.UUID.UUIDString);
    arguments[@"operation_id"] = operationID;
    if ([metadata[@"readOnly"] boolValue]) {
        // This RPC is ledger-only: even a blocked main thread cannot delay it.
        if ([method isEqualToString:@"v4.operation.status"])
            return SKV4Normalize(handler(arguments), operationID, NO);
        return SKV4Read(method, arguments, handler);
    }
    if (SpliceKitV4IsExecuting()) {
        if (!sContext) return SpliceKitV4Error(operationID, @"READ_ONLY_VIOLATION", @"A v4 read cannot submit a nested mutation", @NO, nil);
        if (![operationID isEqual:sContext[@"operation_id"]])
            return SpliceKitV4Error(operationID, @"NESTED_OPERATION_CONFLICT", @"Nested mutations must use the outer operation ID", @NO, nil);
        NSDictionary *before = SKV4Snapshot();
        NSMutableDictionary *check = [arguments mutableCopy];
        [check removeObjectForKey:@"expected_revision"];
        NSDictionary *error = SKV4Preflight(operationID, check, metadata, before);
        if (error) return error;
        if (arguments[@"expected_revision"] && ![arguments[@"expected_revision"] isEqual:sContext[@"revision_before"]])
            return SpliceKitV4Error(operationID, @"REVISION_MISMATCH", @"Nested revision must match the outer baseline", @NO, nil);
        return SKV4Normalize(handler(arguments), operationID, YES);
    }
    // A client must retain the ID before send and obtain a fresh concurrency
    // token. Generating an ID after an ambiguous transport failure is unsafe.
    if (!params[@"operation_id"] || ![params[@"expected_revision"] length])
        return SpliceKitV4Error(operationID, @"OPERATION_CONTRACT_REQUIRED",
            @"Mutations require operation_id and a nonempty expected_revision", @NO, nil);
    NSMutableDictionary *fingerprintParams = [arguments mutableCopy];
    [fingerprintParams removeObjectForKey:@"operation_id"];
    BOOL created = NO;
    NSString *error;
    // Admission and enqueue share a short lock so concurrent requests cannot
    // overtake a previously reserved operation before it reaches the writer.
    @synchronized (sWriter) {
        [sLedger reserve:operationID method:method fingerprint:SpliceKitV4Fingerprint(
            @{@"method": method, @"params": fingerprintParams}) created:&created error:&error];
        if (!error && created) {
            dispatch_async(sWriter, ^{
                dispatch_semaphore_t settled = dispatch_semaphore_create(0);
                SKV4OnMain(^{
                    @try { SKV4Execute(method, arguments, metadata ?: @{}, handler, operationID); }
                    @finally { dispatch_semaphore_signal(settled); }
                });
                // Client deadline never releases the writer or cancels/replays work.
                dispatch_semaphore_wait(settled, DISPATCH_TIME_FOREVER);
            });
        }
    }
    if (error) return SpliceKitV4Error(operationID, error,
        [error isEqual:@"IDEMPOTENCY_CONFLICT"] ? @"The operation ID is already bound to different arguments" : @"The operation ledger cannot admit work", @NO, nil);
    NSDictionary *record = NSThread.isMainThread ? [sLedger operation:operationID] :
        [sLedger waitFor:operationID timeout:sDeadline];
    return SKV4RecordResult(record);
}

static NSDictionary *SKV4Status(NSDictionary *params) {
    NSDictionary *record = [sLedger operation:params[@"operation_id"]];
    if (!record) return SpliceKitV4Error(params[@"operation_id"], @"OPERATION_NOT_FOUND", @"No ledger entry for this ID", @NO, nil);
    return SpliceKitV4Result(params[@"operation_id"], YES, @NO,
        @{@"state": record[@"state"], @"operation": record, @"result": SKV4RecordResult(record)},
        nil, nil, @"none", @"", @[], nil);
}

static NSDictionary *SKV4Reconcile(NSDictionary *params) {
    NSString *operationID = params[@"operation_id"];
    NSDictionary *record = [sLedger operation:operationID];
    if (!record) return SpliceKitV4Error(operationID, @"OPERATION_NOT_FOUND", @"No ledger entry for this ID", @NO, nil);
    NSDictionary *snapshot = SKV4Snapshot();
    // A generic revision cannot prove a domain-specific edit. Observation is
    // always safe; settlement requires explicit client evidence and a fresh token.
    NSString *resolution = params[@"resolution"];
    if (resolution) {
        if (![record[@"state"] isEqual:@"UNKNOWN"])
            return SpliceKitV4Error(operationID, @"OPERATION_NOT_UNKNOWN", @"Only UNKNOWN entries can be explicitly reconciled", @NO, nil);
        if (![@[@"applied", @"not_applied"] containsObject:resolution] ||
            ![params[@"evidence"] isKindOfClass:NSDictionary.class] || ![params[@"evidence"] count] ||
            ![params[@"expected_revision"] isEqual:SKV4Revision(snapshot)])
            return SpliceKitV4Error(operationID, @"RECONCILIATION_EVIDENCE_REQUIRED",
                @"Provide applied/not_applied, nonempty native evidence, and the fresh expected_revision", @NO, snapshot);
        NSDictionary *settled = SpliceKitV4Result(operationID, YES, @([resolution isEqual:@"applied"]),
            @{@"evidence": params[@"evidence"], @"current_state": snapshot},
            record[@"revision_before"] == NSNull.null ? nil : record[@"revision_before"],
            SKV4Revision(snapshot), @"unknown", @"", @[@"Explicit client attestation; domain evidence is not independently verified by the generic core."], nil);
        [sLedger update:operationID state:@"RECONCILED" result:settled details:@{@"resolution": resolution}];
        record = [sLedger operation:operationID];
    }
    return SpliceKitV4Result(operationID, YES, @NO,
        @{@"state": record[@"state"], @"operation": record, @"current_state": snapshot,
            @"reexecuted": @NO}, nil, SKV4Revision(snapshot), @"none", @"", @[], nil);
}

static NSDictionary *SKV4Undo(NSDictionary *params) {
    NSString *operationID = params[@"operation_id"];
    NSString *target = params[@"target_operation_id"];
    if (![target isKindOfClass:NSString.class] || !target.length)
        return SpliceKitV4Error(operationID, @"INVALID_ARGUMENT", @"target_operation_id is required", @NO, nil);
    NSDictionary *owner = sUndoOwners[target];
    NSDictionary *record = [sLedger operation:target];
    NSUndoManager *manager = SKV4UndoManager();
    NSDictionary *current = SKV4Snapshot();
    if (!owner || ![record[@"session_id"] isEqual:sSessionID])
        return SpliceKitV4Error(operationID, @"UNDO_NOT_OWNED", @"No native undo ownership in the current FCP session", @NO, nil);
    if (manager != owner[@"manager"] || manager.groupingLevel != 0 || !manager.canUndo ||
        ![manager.undoActionName isEqual:owner[@"label"]] ||
        ![SKV4Revision(current) isEqual:owner[@"sequence_revision"]])
        return SpliceKitV4Error(operationID, @"UNDO_NOT_TOP", @"The operation no longer owns the unchanged top native undo group", @NO, nil);
    [manager undo];
    [sUndoOwners removeObjectForKey:target];
    [sLedger update:target state:record[@"state"] result:nil
        details:@{@"undone_by_operation_id": operationID}];
    return SpliceKitV4Result(operationID, YES, @YES,
        @{@"undone_operation_id": target, @"state": SKV4Snapshot()}, nil, nil,
        @"none", @"", @[], nil);
}

void SpliceKitV4RegisterMethods(void) {
    SKV4Initialize();
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSDictionary *read = @{@"readOnly": @YES, @"v4Undo": @"none", @"v4RequiresSequence": @NO};
        SpliceKit_registerPluginMethod(@"v4.session.status", ^NSDictionary *(NSDictionary *params) {
            NSMutableDictionary *snapshot = [SKV4Snapshot() mutableCopy];
            snapshot[@"ledger"] = [sLedger summary];
            snapshot[@"build_gate_writes_enabled"] = snapshot[@"writes_enabled"];
            snapshot[@"writes_enabled"] = SKV4Boolean([snapshot[@"writes_enabled"] boolValue] &&
                [snapshot[@"ledger"][@"writable"] boolValue]);
            return snapshot;
        }, read);
        SpliceKit_registerPluginMethod(@"v4.state.revision", ^NSDictionary *(NSDictionary *params) {
            NSDictionary *snapshot = SKV4Snapshot();
            if (!SKV4Revision(snapshot)) return SpliceKitV4Error(params[@"operation_id"], @"NO_ACTIVE_SEQUENCE", @"An active sequence is required", @NO, nil);
            return snapshot;
        }, read);
        SpliceKit_registerPluginMethod(@"v4.state.snapshot", ^NSDictionary *(NSDictionary *params) {
            return SKV4SemanticSnapshot();
        }, read);
        SpliceKit_registerPluginMethod(@"v4.history.checkpoint", ^NSDictionary *(NSDictionary *params) {
            return SKV4Snapshot();
        }, read);
        SpliceKit_registerPluginMethod(@"v4.operation.status", ^NSDictionary *(NSDictionary *params) {
            return SKV4Status(params);
        }, read);
        SpliceKit_registerPluginMethod(@"v4.operation.reconcile", ^NSDictionary *(NSDictionary *params) {
            return SKV4Reconcile(params);
        }, read);
        SpliceKit_registerPluginMethod(@"v4.history.undo", ^NSDictionary *(NSDictionary *params) {
            return SKV4Undo(params);
        }, @{@"readOnly": @NO, @"v4Undo": @"none", @"v4RequiresSequence": @YES});
    });
}
