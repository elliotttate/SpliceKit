//
//  SpliceKitRuntime.m
//  ObjC runtime utilities — the foundation everything else is built on.
//
//  FCP doesn't have a public API, so we talk to it through raw objc_msgSend
//  calls and runtime introspection. This file provides the plumbing:
//  - Safe message sending (nil-checks before dispatch)
//  - Main thread execution (tricky because of FCP's modal dialogs)
//  - Class/method discovery for reverse-engineering FCP's internals
//

#import "SpliceKit.h"
#import <AppKit/AppKit.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>

#pragma mark - Safe Message Sending
//
// These look trivial, but they save us from scattered nil-checks everywhere.
// When you're chasing a 5-deep KVC chain through FCP's object graph,
// any link can be nil and sending a message to nil silently returns 0/nil.
// That's fine for ObjC, but we want to *know* when something's missing.
//

id SpliceKit_sendMsg(id target, SEL selector) {
    if (!target) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(target, selector);
}

id SpliceKit_sendMsg1(id target, SEL selector, id arg1) {
    if (!target) return nil;
    return ((id (*)(id, SEL, id))objc_msgSend)(target, selector, arg1);
}

id SpliceKit_sendMsg2(id target, SEL selector, id arg1, id arg2) {
    if (!target) return nil;
    return ((id (*)(id, SEL, id, id))objc_msgSend)(target, selector, arg1, arg2);
}

BOOL SpliceKit_sendMsgBool(id target, SEL selector) {
    if (!target) return NO;
    return ((BOOL (*)(id, SEL))objc_msgSend)(target, selector);
}

#pragma mark - Main Thread Dispatch
//
// Almost everything in FCP's UI layer (timeline, inspector, viewer) is main-thread-only.
// Our JSON-RPC requests arrive on background threads, so we need to hop over.
//
// The wrinkle: dispatch_sync(dispatch_get_main_queue(), ...) deadlocks when FCP
// is showing a modal dialog (sheet, save panel, etc.) because the main queue
// doesn't drain during modal run loops. CFRunLoopPerformBlock + kCFRunLoopCommonModes
// sidesteps this by scheduling directly on the run loop instead of the GCD queue.
//

// Reentrancy counter: incremented while the main thread is executing a block
// dispatched from our RPC handler via executeOnMainThread. If a breakpoint
// fires while this is > 0, pausing would deadlock (an RPC thread is blocked
// on a semaphore waiting for this block to finish). We use a counter instead
// of a flag because multiple RPC calls can nest on the main thread.
// Timer/notification callbacks fire with depth == 0, so breakpoints work on them.
static _Atomic int sMainThreadRPCDispatchDepth = 0;

BOOL SpliceKit_isMainThreadInRPCDispatch(void) {
    return [NSThread isMainThread] && sMainThreadRPCDispatchDepth > 0;
}

void SpliceKit_executeOnMainThread(dispatch_block_t block) {
    if ([NSThread isMainThread]) {
        sMainThreadRPCDispatchDepth++;
        block();
        sMainThreadRPCDispatchDepth--;
    } else {
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        CFRunLoopPerformBlock(CFRunLoopGetMain(), kCFRunLoopCommonModes, ^{
            sMainThreadRPCDispatchDepth++;
            block();
            sMainThreadRPCDispatchDepth--;
            dispatch_semaphore_signal(sem);
        });
        CFRunLoopWakeUp(CFRunLoopGetMain());

        // 20s timeout — better than a silent deadlock.
        // This can happen during startup (CompressorKit load) or heavy modal dialogs.
        long waitResult = dispatch_semaphore_wait(sem,
            dispatch_time(DISPATCH_TIME_NOW, 20LL * NSEC_PER_SEC));
        if (waitResult != 0) {
            NSLog(@"[SpliceKit] WARNING: Main thread dispatch timed out (20s). "
                  @"Main thread may be blocked by startup or modal dialog.");
        }
    }
}

void SpliceKit_executeOnMainThreadAsync(dispatch_block_t block) {
    dispatch_async(dispatch_get_main_queue(), block);
}

#pragma mark - Sequence State Persistence

static NSString *SpliceKit_persistenceString(id value) {
    if (!value) return @"";
    if ([value isKindOfClass:[NSString class]]) return value;
    return [value description] ?: @"";
}

static id SpliceKit_objectForSelector(id target, NSString *selectorName) {
    if (!target || selectorName.length == 0) return nil;
    SEL selector = NSSelectorFromString(selectorName);
    if (![target respondsToSelector:selector]) return nil;
    @try {
        return ((id (*)(id, SEL))objc_msgSend)(target, selector);
    } @catch (NSException *e) {
        SpliceKit_log(@"[State] %@ threw on %@: %@", NSStringFromClass([target class]), selectorName, e.reason);
        return nil;
    }
}

static NSString *SpliceKit_stringForSelector(id target, NSString *selectorName) {
    return SpliceKit_persistenceString(SpliceKit_objectForSelector(target, selectorName));
}

static uint64_t SpliceKit_fnv1aHash(NSString *string) {
    NSData *data = [string dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
    const uint8_t *bytes = data.bytes;
    uint64_t hash = 1469598103934665603ULL;
    for (NSUInteger i = 0; i < data.length; i++) {
        hash ^= bytes[i];
        hash *= 1099511628211ULL;
    }
    return hash;
}

static NSString *SpliceKit_sequenceStateDirectory(void) {
    NSString *base = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/SpliceKit/sequence-state"];
    NSError *error = nil;
    [[NSFileManager defaultManager] createDirectoryAtPath:base
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:&error];
    if (error) {
        SpliceKit_log(@"[State] Failed to create sequence-state directory %@: %@",
                      base, error.localizedDescription);
    }
    return base;
}

NSDictionary *SpliceKit_sequenceIdentity(id sequence) {
    if (!sequence) return nil;

    __block NSDictionary *identity = nil;
    SpliceKit_executeOnMainThread(^{
        NSString *sequenceName = SpliceKit_stringForSelector(sequence, @"displayName");
        if (sequenceName.length == 0) sequenceName = @"Untitled Sequence";

        id event = SpliceKit_objectForSelector(sequence, @"containerEvent");
        if (!event) event = SpliceKit_objectForSelector(sequence, @"event");
        NSString *eventName = SpliceKit_stringForSelector(event, @"displayName");

        id app = [NSApplication sharedApplication];
        id delegate = [app delegate];
        id library = SpliceKit_objectForSelector(delegate, @"targetLibrary");
        NSString *libraryName = SpliceKit_stringForSelector(library, @"displayName");
        NSString *mediaIdentifier = SpliceKit_stringForSelector(sequence, @"mediaIdentifier");

        NSMutableArray<NSString *> *parts = [NSMutableArray array];
        if (libraryName.length > 0) [parts addObject:[NSString stringWithFormat:@"lib=%@", libraryName]];
        if (eventName.length > 0) [parts addObject:[NSString stringWithFormat:@"event=%@", eventName]];
        [parts addObject:[NSString stringWithFormat:@"sequence=%@", sequenceName]];
        NSString *rawKey = [parts componentsJoinedByString:@"|"];
        NSString *cacheKey = [NSString stringWithFormat:@"%016llx", SpliceKit_fnv1aHash(rawKey)];

        identity = @{
            @"cacheKey": cacheKey,
            @"rawKey": rawKey,
            @"libraryName": libraryName ?: @"",
            @"eventName": eventName ?: @"",
            @"sequenceName": sequenceName ?: @"",
            @"mediaIdentifier": mediaIdentifier ?: @"",
        };
    });

    return identity;
}

static NSString *SpliceKit_sequenceStatePath(id sequence) {
    NSDictionary *identity = SpliceKit_sequenceIdentity(sequence);
    NSString *cacheKey = identity[@"cacheKey"];
    if (cacheKey.length == 0) return nil;
    return [[SpliceKit_sequenceStateDirectory() stringByAppendingPathComponent:cacheKey]
        stringByAppendingPathExtension:@"json"];
}

NSDictionary *SpliceKit_loadSequenceState(id sequence) {
    NSString *path = SpliceKit_sequenceStatePath(sequence);
    if (path.length == 0) return nil;

    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) return nil;

    NSError *error = nil;
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    if (![json isKindOfClass:[NSDictionary class]]) {
        if (error) {
            SpliceKit_log(@"[State] Failed to parse %@: %@", path, error.localizedDescription);
        }
        return nil;
    }
    return json;
}

BOOL SpliceKit_saveSequenceState(id sequence, NSDictionary *state, NSError **error) {
    NSString *path = SpliceKit_sequenceStatePath(sequence);
    NSDictionary *identity = SpliceKit_sequenceIdentity(sequence);
    if (path.length == 0 || !identity) {
        if (error) {
            *error = [NSError errorWithDomain:@"SpliceKitSequenceState"
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey: @"Could not resolve a sequence identity"}];
        }
        return NO;
    }

    NSMutableDictionary *root = [state mutableCopy] ?: [NSMutableDictionary dictionary];
    root[@"schemaVersion"] = @1;
    root[@"savedAt"] = @([[NSDate date] timeIntervalSince1970]);
    root[@"sequenceIdentity"] = identity;

    NSData *data = [NSJSONSerialization dataWithJSONObject:root
                                                   options:NSJSONWritingPrettyPrinted
                                                     error:error];
    if (!data) return NO;
    return [data writeToFile:path options:NSDataWritingAtomic error:error];
}

#pragma mark - Class Discovery
//
// These are the reverse-engineering tools. FCP has 78K+ ObjC classes across
// dozens of frameworks. We can enumerate them by Mach-O image (to see what
// came from Flexo vs ProAppSupport vs TimelineKit) or grab the full list.
//

NSArray *SpliceKit_classesInImage(const char *imageName) {
    NSMutableArray *result = [NSMutableArray array];
    unsigned int count = 0;
    const char **names = objc_copyClassNamesForImage(imageName, &count);
    if (names) {
        for (unsigned int i = 0; i < count; i++) {
            [result addObject:@(names[i])];
        }
        free(names);
    }
    return result;
}

// Returns every method on a class: selector name, type encoding, and IMP address.
// The IMP address is useful for setting breakpoints or cross-referencing with
// disassembly when you're trying to figure out what a method actually does.
NSDictionary *SpliceKit_methodsForClass(Class cls) {
    NSMutableDictionary *methods = [NSMutableDictionary dictionary];
    unsigned int count = 0;
    Method *methodList = class_copyMethodList(cls, &count);
    if (methodList) {
        for (unsigned int i = 0; i < count; i++) {
            SEL sel = method_getName(methodList[i]);
            NSString *name = NSStringFromSelector(sel);
            const char *types = method_getTypeEncoding(methodList[i]);
            methods[name] = @{
                @"selector": name,
                @"typeEncoding": types ? @(types) : @"",
                @"imp": [NSString stringWithFormat:@"0x%lx",
                         (unsigned long)method_getImplementation(methodList[i])]
            };
        }
        free(methodList);
    }
    return methods;
}

// Grab every class in the process, sorted alphabetically.
// Some classes are flaky (Swift generics, partially-loaded bundles) so we
// wrap the name lookup in a try-catch to avoid crashing on garbage metadata.
NSArray *SpliceKit_allLoadedClasses(void) {
    NSMutableArray *result = [NSMutableArray array];
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    if (classes) {
        for (unsigned int i = 0; i < count; i++) {
            @try {
                const char *name = class_getName(classes[i]);
                if (name && name[0] != '\0') {
                    NSString *nameStr = @(name);
                    if (nameStr) {
                        [result addObject:nameStr];
                    }
                }
            } @catch (NSException *e) {
                // Some classes blow up when you touch them — just skip 'em
            }
        }
        free(classes);
    }
    [result sortUsingSelector:@selector(compare:)];
    return result;
}
