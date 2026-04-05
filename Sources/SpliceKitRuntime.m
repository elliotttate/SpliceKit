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
