//
//  SpliceKitRuntime.m
//  ObjC runtime access utilities - class discovery, method introspection
//

#import "SpliceKit.h"
#import <dlfcn.h>
#import <mach-o/dyld.h>

#pragma mark - Safe Message Sending

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

void SpliceKit_executeOnMainThread(dispatch_block_t block) {
    if ([NSThread isMainThread]) {
        block();
    } else {
        // Use CFRunLoopPerformBlock with kCFRunLoopCommonModes so it works
        // even when FCP is running a modal event loop (sheets, dialogs).
        // dispatch_sync deadlocks in that situation because the main queue
        // isn't drained during modal sessions.
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        CFRunLoopPerformBlock(CFRunLoopGetMain(), kCFRunLoopCommonModes, ^{
            block();
            dispatch_semaphore_signal(sem);
        });
        CFRunLoopWakeUp(CFRunLoopGetMain());
        dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
    }
}

void SpliceKit_executeOnMainThreadAsync(dispatch_block_t block) {
    dispatch_async(dispatch_get_main_queue(), block);
}

#pragma mark - Class Discovery

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
                // Skip problematic classes
            }
        }
        free(classes);
    }
    [result sortUsingSelector:@selector(compare:)];
    return result;
}
