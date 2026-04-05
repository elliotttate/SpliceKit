//
//  FCPBridgeServer.m
//  JSON-RPC 2.0 server over Unix domain socket
//

#import "FCPBridge.h"
#import "FCPTranscriptPanel.h"
#import "FCPCommandPalette.h"
#import <sys/socket.h>
#import <sys/un.h>
#import <sys/stat.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <fcntl.h>
#import <AppKit/AppKit.h>
#import <AVFoundation/AVFoundation.h>
#import <Accelerate/Accelerate.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach-o/getsect.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>

// Forward declaration — defined in #pragma mark - Effect Drag as Adjustment Clip
void FCPBridge_installEffectDragSwizzlesNow(void);

#define FCPBRIDGE_TCP_PORT 9876

static int sServerFd = -1;

// Forward declarations
static NSDictionary *FCPBridge_sendAppAction(NSString *selectorName);
static NSDictionary *FCPBridge_sendPlayerAction(NSString *selectorName);
static id FCPBridge_getActiveTimelineModule(void);
static id FCPBridge_getEditorContainer(void);

#pragma mark - Object Handle System

static NSMutableDictionary<NSString *, id> *sHandleMap = nil;
static uint64_t sHandleCounter = 0;

NSString *FCPBridge_storeHandle(id object) {
    if (!object) return nil;
    if (!sHandleMap) sHandleMap = [NSMutableDictionary dictionary];
    if (sHandleMap.count >= FCPBRIDGE_MAX_HANDLES) {
        FCPBridge_log(@"Handle limit reached (%d), clearing old handles", FCPBRIDGE_MAX_HANDLES);
        [sHandleMap removeAllObjects];
    }
    sHandleCounter++;
    NSString *handle = [NSString stringWithFormat:@"obj_%llu", sHandleCounter];
    sHandleMap[handle] = object;
    return handle;
}

id FCPBridge_resolveHandle(NSString *handleId) {
    if (!handleId || !sHandleMap) return nil;
    return sHandleMap[handleId];
}

void FCPBridge_releaseHandle(NSString *handleId) {
    [sHandleMap removeObjectForKey:handleId];
}

void FCPBridge_releaseAllHandles(void) {
    [sHandleMap removeAllObjects];
}

NSDictionary *FCPBridge_listHandles(void) {
    NSMutableArray *entries = [NSMutableArray array];
    for (NSString *key in sHandleMap) {
        id obj = sHandleMap[key];
        [entries addObject:@{
            @"handle": key,
            @"class": NSStringFromClass([obj class]) ?: @"<unknown>",
            @"description": [[obj description] substringToIndex:
                MIN((NSUInteger)200, [[obj description] length])]
        }];
    }
    return @{@"handles": entries, @"count": @(sHandleMap.count)};
}

#pragma mark - Type Helpers

typedef struct { int64_t value; int32_t timescale; uint32_t flags; int64_t epoch; } FCPBridge_CMTime;
typedef struct { FCPBridge_CMTime start; FCPBridge_CMTime duration; } FCPBridge_CMTimeRange;

static NSDictionary *FCPBridge_serializeCMTime(FCPBridge_CMTime t) {
    double seconds = (t.timescale > 0) ? (double)t.value / t.timescale : 0;
    return @{@"value": @(t.value), @"timescale": @(t.timescale), @"seconds": @(seconds)};
}

static id FCPBridge_serializeReturnValue(NSInvocation *invocation, BOOL returnHandle) {
    const char *retType = [[invocation methodSignature] methodReturnType];
    if (retType[0] == 'v') return @{@"result": @"void"};

    if (retType[0] == '@') {
        id __unsafe_unretained retObj = nil;
        [invocation getReturnValue:&retObj];
        if (!retObj) return @{@"result": [NSNull null]};
        if (returnHandle) {
            NSString *h = FCPBridge_storeHandle(retObj);
            return @{@"handle": h, @"class": NSStringFromClass([retObj class]),
                     @"description": [[retObj description] substringToIndex:
                         MIN((NSUInteger)500, [[retObj description] length])]};
        }
        return @{@"result": [[retObj description] substringToIndex:
                     MIN((NSUInteger)2000, [[retObj description] length])],
                 @"class": NSStringFromClass([retObj class])};
    }
    if (retType[0] == 'B' || retType[0] == 'c') {
        BOOL val; [invocation getReturnValue:&val];
        return @{@"result": @(val)};
    }
    if (retType[0] == 'q' || retType[0] == 'l') {
        long long val; [invocation getReturnValue:&val];
        return @{@"result": @(val)};
    }
    if (retType[0] == 'i') {
        int val; [invocation getReturnValue:&val];
        return @{@"result": @(val)};
    }
    if (retType[0] == 'Q' || retType[0] == 'L') {
        unsigned long long val; [invocation getReturnValue:&val];
        return @{@"result": @(val)};
    }
    if (retType[0] == 'd') {
        double val; [invocation getReturnValue:&val];
        return @{@"result": @(val)};
    }
    if (retType[0] == 'f') {
        float val; [invocation getReturnValue:&val];
        return @{@"result": @(val)};
    }
    // CMTime struct
    if (strstr(retType, "CMTime") || (retType[0] == '{' && strstr(retType, "qiIq"))) {
        FCPBridge_CMTime val;
        if ([[invocation methodSignature] methodReturnLength] == sizeof(FCPBridge_CMTime)) {
            [invocation getReturnValue:&val];
            return @{@"result": FCPBridge_serializeCMTime(val)};
        }
    }
    return @{@"result": @"<unsupported return type>", @"returnType": @(retType)};
}

#pragma mark - Client Management

static NSMutableArray *sConnectedClients = nil;
static dispatch_queue_t sClientQueue = nil;

void FCPBridge_broadcastEvent(NSDictionary *event) {
    if (!sConnectedClients || !sClientQueue) return;

    NSMutableDictionary *notification = [NSMutableDictionary dictionaryWithDictionary:@{
        @"jsonrpc": @"2.0",
        @"method": @"event",
        @"params": event
    }];

    NSData *json = [NSJSONSerialization dataWithJSONObject:notification options:0 error:nil];
    if (!json) return;

    NSMutableData *line = [json mutableCopy];
    [line appendBytes:"\n" length:1];

    dispatch_async(sClientQueue, ^{
        NSArray *clients = [sConnectedClients copy];
        for (NSNumber *fd in clients) {
            write([fd intValue], line.bytes, line.length);
        }
    });
}

#pragma mark - Request Handler

static NSDictionary *FCPBridge_handleSystemGetClasses(NSDictionary *params) {
    NSString *filter = params[@"filter"];
    NSArray *allClasses = FCPBridge_allLoadedClasses();

    if (filter && filter.length > 0) {
        NSPredicate *predicate = [NSPredicate predicateWithFormat:
                                  @"SELF CONTAINS[cd] %@", filter];
        allClasses = [allClasses filteredArrayUsingPredicate:predicate];
    }

    return @{@"classes": allClasses, @"count": @(allClasses.count)};
}

static NSDictionary *FCPBridge_handleSystemGetMethods(NSDictionary *params) {
    NSString *className = params[@"className"];
    if (!className) return @{@"error": @"className required"};

    Class cls = objc_getClass([className UTF8String]);
    if (!cls) return @{@"error": [NSString stringWithFormat:@"Class %@ not found", className]};

    BOOL includeSuper = [params[@"includeSuper"] boolValue];
    NSMutableDictionary *allMethods = [NSMutableDictionary dictionary];

    Class current = cls;
    while (current) {
        NSDictionary *methods = FCPBridge_methodsForClass(current);
        [allMethods addEntriesFromDictionary:methods];
        if (!includeSuper) break;
        current = class_getSuperclass(current);
        if (current == [NSObject class]) break;
    }

    // Also get class methods
    NSMutableDictionary *classMethods = [NSMutableDictionary dictionary];
    Class metaCls = object_getClass(cls);
    if (metaCls) {
        unsigned int count = 0;
        Method *methodList = class_copyMethodList(metaCls, &count);
        if (methodList) {
            for (unsigned int i = 0; i < count; i++) {
                SEL sel = method_getName(methodList[i]);
                NSString *name = NSStringFromSelector(sel);
                const char *types = method_getTypeEncoding(methodList[i]);
                classMethods[name] = @{
                    @"selector": name,
                    @"typeEncoding": types ? @(types) : @"",
                    @"imp": [NSString stringWithFormat:@"0x%lx",
                             (unsigned long)method_getImplementation(methodList[i])]
                };
            }
            free(methodList);
        }
    }

    return @{
        @"className": className,
        @"instanceMethods": allMethods,
        @"classMethods": classMethods,
        @"instanceMethodCount": @(allMethods.count),
        @"classMethodCount": @(classMethods.count)
    };
}

static NSDictionary *FCPBridge_handleSystemCallMethod(NSDictionary *params) {
    NSString *className = params[@"className"];
    NSString *selectorName = params[@"selector"];
    BOOL isClassMethod = [params[@"classMethod"] boolValue];

    if (!className || !selectorName)
        return @{@"error": @"className and selector required"};

    Class cls = objc_getClass([className UTF8String]);
    if (!cls) return @{@"error": [NSString stringWithFormat:@"Class %@ not found", className]};

    SEL selector = NSSelectorFromString(selectorName);

    __block NSDictionary *result = nil;

    FCPBridge_executeOnMainThread(^{
        @try {
            id target = isClassMethod ? (id)cls : nil;

            if (!isClassMethod) {
                // For instance methods, we need an instance
                // Try common singleton patterns
                if ([cls respondsToSelector:@selector(sharedInstance)]) {
                    target = [cls performSelector:@selector(sharedInstance)];
                } else if ([cls respondsToSelector:@selector(shared)]) {
                    target = [cls performSelector:@selector(shared)];
                } else if ([cls respondsToSelector:@selector(defaultManager)]) {
                    target = [cls performSelector:@selector(defaultManager)];
                } else {
                    result = @{@"error": @"Cannot get instance. Use classMethod:true or provide an instance path"};
                    return;
                }
            }

            if (!target) {
                result = @{@"error": @"Target is nil"};
                return;
            }

            if (![target respondsToSelector:selector]) {
                result = @{@"error": [NSString stringWithFormat:@"%@ does not respond to %@",
                                      className, selectorName]};
                return;
            }

            // Get method signature for return type analysis
            NSMethodSignature *sig = isClassMethod
                ? [cls methodSignatureForSelector:selector]
                : [target methodSignatureForSelector:selector];
            const char *returnType = [sig methodReturnType];

            id returnValue = nil;

            // Handle based on return type
            if (returnType[0] == 'v') {
                // void return
                ((void (*)(id, SEL))objc_msgSend)(target, selector);
                result = @{@"result": @"void"};
            } else if (returnType[0] == 'B' || returnType[0] == 'c') {
                // BOOL return
                BOOL boolResult = ((BOOL (*)(id, SEL))objc_msgSend)(target, selector);
                result = @{@"result": @(boolResult)};
            } else if (returnType[0] == '@') {
                // Object return
                returnValue = ((id (*)(id, SEL))objc_msgSend)(target, selector);
                if (returnValue) {
                    result = @{
                        @"result": [returnValue description] ?: @"<nil description>",
                        @"class": NSStringFromClass([returnValue class])
                    };
                } else {
                    result = @{@"result": [NSNull null]};
                }
            } else if (returnType[0] == 'q' || returnType[0] == 'i' || returnType[0] == 'l') {
                // Integer return
                long long intResult = ((long long (*)(id, SEL))objc_msgSend)(target, selector);
                result = @{@"result": @(intResult)};
            } else if (returnType[0] == 'd' || returnType[0] == 'f') {
                // Float/double return
                double dblResult = ((double (*)(id, SEL))objc_msgSend)(target, selector);
                result = @{@"result": @(dblResult)};
            } else {
                // Unknown type
                ((void (*)(id, SEL))objc_msgSend)(target, selector);
                result = @{@"result": @"<unknown return type>",
                           @"returnType": @(returnType)};
            }
        } @catch (NSException *exception) {
            result = @{
                @"error": [NSString stringWithFormat:@"Exception: %@ - %@",
                           exception.name, exception.reason]
            };
        }
    });

    return result;
}

static NSDictionary *FCPBridge_handleSystemVersion(NSDictionary *params) {
    NSDictionary *info = [[NSBundle mainBundle] infoDictionary];
    return @{
        @"fcpbridge_version": @FCPBRIDGE_VERSION,
        @"fcp_version": info[@"CFBundleShortVersionString"] ?: @"unknown",
        @"fcp_build": info[@"CFBundleVersion"] ?: @"unknown",
        @"pid": @(getpid()),
        @"arch": @
#if __arm64__
            "arm64"
#else
            "x86_64"
#endif
    };
}

static NSDictionary *FCPBridge_handleSystemSwizzle(NSDictionary *params) {
    // Swizzle is more complex -- for now just report capability
    return @{@"error": @"Swizzle requires compiled IMP. Use system.callMethod for direct calls."};
}

static NSDictionary *FCPBridge_handleSystemGetProperties(NSDictionary *params) {
    NSString *className = params[@"className"];
    if (!className) return @{@"error": @"className required"};

    Class cls = objc_getClass([className UTF8String]);
    if (!cls) return @{@"error": [NSString stringWithFormat:@"Class %@ not found", className]};

    NSMutableArray *properties = [NSMutableArray array];
    unsigned int count = 0;
    objc_property_t *propList = class_copyPropertyList(cls, &count);
    if (propList) {
        for (unsigned int i = 0; i < count; i++) {
            const char *name = property_getName(propList[i]);
            const char *attrs = property_getAttributes(propList[i]);
            [properties addObject:@{
                @"name": @(name),
                @"attributes": @(attrs)
            }];
        }
        free(propList);
    }

    return @{@"className": className, @"properties": properties, @"count": @(count)};
}

static NSDictionary *FCPBridge_handleSystemGetProtocols(NSDictionary *params) {
    NSString *className = params[@"className"];
    if (!className) return @{@"error": @"className required"};

    Class cls = objc_getClass([className UTF8String]);
    if (!cls) return @{@"error": [NSString stringWithFormat:@"Class %@ not found", className]};

    NSMutableArray *protocols = [NSMutableArray array];
    unsigned int count = 0;
    Protocol * __unsafe_unretained *protoList = class_copyProtocolList(cls, &count);
    if (protoList) {
        for (unsigned int i = 0; i < count; i++) {
            [protocols addObject:@(protocol_getName(protoList[i]))];
        }
        free(protoList);
    }

    return @{@"className": className, @"protocols": protocols, @"count": @(count)};
}

static NSDictionary *FCPBridge_handleSystemGetSuperchain(NSDictionary *params) {
    NSString *className = params[@"className"];
    if (!className) return @{@"error": @"className required"};

    Class cls = objc_getClass([className UTF8String]);
    if (!cls) return @{@"error": [NSString stringWithFormat:@"Class %@ not found", className]};

    NSMutableArray *chain = [NSMutableArray array];
    Class current = cls;
    while (current) {
        [chain addObject:NSStringFromClass(current)];
        current = class_getSuperclass(current);
    }

    return @{@"className": className, @"superchain": chain};
}

static NSDictionary *FCPBridge_handleSystemGetIvars(NSDictionary *params) {
    NSString *className = params[@"className"];
    if (!className) return @{@"error": @"className required"};

    Class cls = objc_getClass([className UTF8String]);
    if (!cls) return @{@"error": [NSString stringWithFormat:@"Class %@ not found", className]};

    NSMutableArray *ivars = [NSMutableArray array];
    unsigned int count = 0;
    Ivar *ivarList = class_copyIvarList(cls, &count);
    if (ivarList) {
        for (unsigned int i = 0; i < count; i++) {
            const char *name = ivar_getName(ivarList[i]);
            const char *type = ivar_getTypeEncoding(ivarList[i]);
            ptrdiff_t offset = ivar_getOffset(ivarList[i]);
            [ivars addObject:@{
                @"name": name ? @(name) : @"<anon>",
                @"type": type ? @(type) : @"?",
                @"offset": @(offset)
            }];
        }
        free(ivarList);
    }

    return @{@"className": className, @"ivars": ivars, @"count": @(count)};
}

#pragma mark - system.callMethodWithArgs

static id FCPBridge_resolveTarget(NSDictionary *params) {
    NSString *target = params[@"target"] ?: params[@"className"];
    BOOL isClassMethod = [params[@"classMethod"] boolValue];

    // Check if target is a handle
    if ([target hasPrefix:@"obj_"]) {
        return FCPBridge_resolveHandle(target);
    }

    Class cls = objc_getClass([target UTF8String]);
    if (!cls) return nil;

    if (isClassMethod) return (id)cls;

    // Try singleton patterns
    for (NSString *sel in @[@"sharedInstance", @"shared", @"defaultManager",
                            @"sharedDocumentController", @"sharedApplication"]) {
        if ([cls respondsToSelector:NSSelectorFromString(sel)]) {
            return ((id (*)(id, SEL))objc_msgSend)((id)cls, NSSelectorFromString(sel));
        }
    }
    return nil;
}

static BOOL FCPBridge_isKnownUnsafeNilErrorSelector(NSString *selectorName, NSArray *args,
                                                    NSString **reason) {
    if (![selectorName isKindOfClass:[NSString class]]) return NO;
    if (![args isKindOfClass:[NSArray class]] || args.count == 0) return NO;

    static NSSet<NSString *> *unsafeSelectors = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        unsafeSelectors = [NSSet setWithArray:@[
            @"actionTrimDuration:forEdits:isDelta:error:",
            @"operationTrimDuration:forEdits:isDelta:error:"
        ]];
    });

    if (![unsafeSelectors containsObject:selectorName]) return NO;

    NSDictionary *lastArg = [args.lastObject isKindOfClass:[NSDictionary class]] ? args.lastObject : nil;
    NSString *lastType = [lastArg[@"type"] isKindOfClass:[NSString class]] ? lastArg[@"type"] : @"nil";
    if (![lastType isEqualToString:@"nil"]) return NO;

    if (reason) {
        *reason = [NSString stringWithFormat:
                   @"Refusing %@ with nil error: pointer; this selector is known to crash Final Cut "
                   @"when the trim is constrained. Use a safe wrapper instead.",
                   selectorName];
    }
    return YES;
}

static NSDictionary *FCPBridge_handleCallMethodWithArgs(NSDictionary *params) {
    NSString *targetName = params[@"target"] ?: params[@"className"];
    NSString *selectorName = params[@"selector"];
    NSArray *args = params[@"args"] ?: @[];
    BOOL returnHandle = [params[@"returnHandle"] boolValue];

    if (!targetName || !selectorName)
        return @{@"error": @"target and selector required"};

    __block NSDictionary *result = nil;

    FCPBridge_executeOnMainThread(^{
        @try {
            id target = FCPBridge_resolveTarget(params);
            if (!target) {
                result = @{@"error": [NSString stringWithFormat:@"Cannot resolve target: %@", targetName]};
                return;
            }

            SEL selector = NSSelectorFromString(selectorName);
            NSMethodSignature *sig = [target methodSignatureForSelector:selector];
            if (!sig) {
                result = @{@"error": [NSString stringWithFormat:@"%@ does not respond to %@",
                            targetName, selectorName]};
                return;
            }

            NSUInteger expectedArgs = [sig numberOfArguments] - 2;
            if (args.count != expectedArgs) {
                result = @{@"error": [NSString stringWithFormat:
                    @"Expected %lu args for %@, got %lu",
                    (unsigned long)expectedArgs, selectorName, (unsigned long)args.count]};
                return;
            }

            NSString *unsafeReason = nil;
            if (FCPBridge_isKnownUnsafeNilErrorSelector(selectorName, args, &unsafeReason)) {
                result = @{@"error": unsafeReason ?: @"Unsafe selector invocation blocked"};
                return;
            }

            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setTarget:target];
            [inv setSelector:selector];
            [inv retainArguments];

            // Set arguments
            for (NSUInteger i = 0; i < args.count; i++) {
                NSDictionary *arg = args[i];
                NSString *type = arg[@"type"] ?: @"nil";
                NSUInteger argIdx = i + 2;
                const char *sigType = [sig getArgumentTypeAtIndex:argIdx];

                if ([type isEqualToString:@"string"]) {
                    NSString *val = [arg[@"value"] description];
                    [inv setArgument:&val atIndex:argIdx];
                } else if ([type isEqualToString:@"int"]) {
                    long long val = [arg[@"value"] longLongValue];
                    if (sigType[0] == 'i') { int v = (int)val; [inv setArgument:&v atIndex:argIdx]; }
                    else if (sigType[0] == 'q') { [inv setArgument:&val atIndex:argIdx]; }
                    else if (sigType[0] == 'Q') { unsigned long long v = (unsigned long long)val; [inv setArgument:&v atIndex:argIdx]; }
                    else { [inv setArgument:&val atIndex:argIdx]; }
                } else if ([type isEqualToString:@"double"]) {
                    double val = [arg[@"value"] doubleValue];
                    if (sigType[0] == 'f') { float v = (float)val; [inv setArgument:&v atIndex:argIdx]; }
                    else { [inv setArgument:&val atIndex:argIdx]; }
                } else if ([type isEqualToString:@"float"]) {
                    float val = [arg[@"value"] floatValue];
                    [inv setArgument:&val atIndex:argIdx];
                } else if ([type isEqualToString:@"bool"]) {
                    BOOL val = [arg[@"value"] boolValue];
                    [inv setArgument:&val atIndex:argIdx];
                } else if ([type isEqualToString:@"nil"] || [type isEqualToString:@"sender"]) {
                    id val = nil;
                    [inv setArgument:&val atIndex:argIdx];
                } else if ([type isEqualToString:@"handle"]) {
                    id val = FCPBridge_resolveHandle(arg[@"value"]);
                    if (!val) {
                        result = @{@"error": [NSString stringWithFormat:
                            @"Handle not found: %@", arg[@"value"]]};
                        return;
                    }
                    [inv setArgument:&val atIndex:argIdx];
                } else if ([type isEqualToString:@"cmtime"]) {
                    NSDictionary *tv = arg[@"value"];
                    FCPBridge_CMTime t = {
                        .value = [tv[@"value"] longLongValue],
                        .timescale = [tv[@"timescale"] intValue],
                        .flags = 1, .epoch = 0
                    };
                    [inv setArgument:&t atIndex:argIdx];
                } else if ([type isEqualToString:@"selector"]) {
                    SEL val = NSSelectorFromString(arg[@"value"]);
                    [inv setArgument:&val atIndex:argIdx];
                } else {
                    // Default: try as object (NSNull -> nil, otherwise wrap)
                    id val = nil;
                    [inv setArgument:&val atIndex:argIdx];
                }
            }

            [inv invoke];
            result = FCPBridge_serializeReturnValue(inv, returnHandle);
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@ - %@",
                        e.name, e.reason]};
        }
    });

    return result;
}

#pragma mark - Object Handlers

static NSDictionary *FCPBridge_handleObjectGet(NSDictionary *params) {
    NSString *handle = params[@"handle"];
    if (!handle) return @{@"error": @"handle required"};
    id obj = FCPBridge_resolveHandle(handle);
    if (!obj) return @{@"error": [NSString stringWithFormat:@"Handle not found: %@", handle]};
    return @{@"handle": handle, @"class": NSStringFromClass([obj class]),
             @"description": [[obj description] substringToIndex:
                 MIN((NSUInteger)500, [[obj description] length])], @"valid": @YES};
}

static NSDictionary *FCPBridge_handleObjectRelease(NSDictionary *params) {
    if ([params[@"all"] boolValue]) {
        NSUInteger count = sHandleMap.count;
        FCPBridge_releaseAllHandles();
        return @{@"released": @(count)};
    }
    NSString *handle = params[@"handle"];
    if (!handle) return @{@"error": @"handle or all:true required"};
    BOOL existed = (FCPBridge_resolveHandle(handle) != nil);
    FCPBridge_releaseHandle(handle);
    return @{@"handle": handle, @"released": @(existed)};
}

static NSDictionary *FCPBridge_handleObjectList(NSDictionary *params) {
    return FCPBridge_listHandles();
}

#pragma mark - KVC Property Access

static NSDictionary *FCPBridge_handleGetProperty(NSDictionary *params) {
    NSString *handle = params[@"handle"];
    NSString *key = params[@"key"];
    BOOL returnHandle = [params[@"returnHandle"] boolValue];
    if (!handle || !key) return @{@"error": @"handle and key required"};

    __block NSDictionary *result = nil;
    FCPBridge_executeOnMainThread(^{
        @try {
            id obj = FCPBridge_resolveHandle(handle);
            if (!obj) { result = @{@"error": @"Handle not found"}; return; }

            id value = [obj valueForKey:key];
            if (!value) {
                result = @{@"key": key, @"result": [NSNull null]};
            } else if (returnHandle) {
                NSString *h = FCPBridge_storeHandle(value);
                result = @{@"key": key, @"handle": h,
                           @"class": NSStringFromClass([value class]),
                           @"description": [[value description] substringToIndex:
                               MIN((NSUInteger)500, [[value description] length])]};
            } else {
                result = @{@"key": key, @"result": [[value description] substringToIndex:
                               MIN((NSUInteger)2000, [[value description] length])],
                           @"class": NSStringFromClass([value class])};
            }
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"KVC error: %@", e.reason]};
        }
    });
    return result;
}

static NSDictionary *FCPBridge_handleSetProperty(NSDictionary *params) {
    NSString *handle = params[@"handle"];
    NSString *key = params[@"key"];
    if (!handle || !key) return @{@"error": @"handle and key required"};

    __block NSDictionary *result = nil;
    FCPBridge_executeOnMainThread(^{
        @try {
            id obj = FCPBridge_resolveHandle(handle);
            if (!obj) { result = @{@"error": @"Handle not found"}; return; }

            NSDictionary *valSpec = params[@"value"];
            NSString *type = valSpec[@"type"] ?: @"string";
            id value = nil;
            if ([type isEqualToString:@"string"]) value = valSpec[@"value"];
            else if ([type isEqualToString:@"int"]) value = @([valSpec[@"value"] longLongValue]);
            else if ([type isEqualToString:@"double"]) value = @([valSpec[@"value"] doubleValue]);
            else if ([type isEqualToString:@"bool"]) value = @([valSpec[@"value"] boolValue]);
            else if ([type isEqualToString:@"nil"]) value = nil;

            [obj setValue:value forKey:key];
            result = @{@"key": key, @"status": @"ok",
                       @"warning": @"Direct KVC may bypass undo. Use action pattern for undoable edits."};
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"KVC error: %@", e.reason]};
        }
    });
    return result;
}

#pragma mark - timeline.getDetailedState

NSDictionary *FCPBridge_handleTimelineGetDetailedState(NSDictionary *params) {
    FCPBridge_installEffectDragSwizzlesNow();
    NSInteger limit = [params[@"limit"] integerValue] ?: 200;

    __block NSDictionary *result = nil;
    FCPBridge_executeOnMainThread(^{
        @try {
            id timeline = FCPBridge_getActiveTimelineModule();
            if (!timeline) {
                result = @{@"error": @"No active timeline module. Is a project open?"};
                return;
            }

            NSMutableDictionary *state = [NSMutableDictionary dictionary];
            id sequence = nil;

            if ([timeline respondsToSelector:@selector(sequence)]) {
                sequence = ((id (*)(id, SEL))objc_msgSend)(timeline, @selector(sequence));
            }

            if (!sequence) {
                result = @{@"error": @"No sequence in timeline. Open a project first."};
                return;
            }

            // Sequence info
            if ([sequence respondsToSelector:@selector(displayName)]) {
                id name = ((id (*)(id, SEL))objc_msgSend)(sequence, @selector(displayName));
                state[@"sequenceName"] = name ?: @"<unnamed>";
            }
            state[@"sequenceClass"] = NSStringFromClass([sequence class]);

            // Playhead
            if ([timeline respondsToSelector:@selector(playheadTime)]) {
                FCPBridge_CMTime t = ((FCPBridge_CMTime (*)(id, SEL))objc_msgSend)(timeline, @selector(playheadTime));
                state[@"playheadTime"] = FCPBridge_serializeCMTime(t);
            }

            // Sequence duration
            if ([sequence respondsToSelector:@selector(duration)]) {
                FCPBridge_CMTime d = ((FCPBridge_CMTime (*)(id, SEL))objc_msgSend)(sequence, @selector(duration));
                state[@"duration"] = FCPBridge_serializeCMTime(d);
            }

            // Selected items (get set for checking)
            NSSet *selectedSet = nil;
            SEL selItemsSel = NSSelectorFromString(@"selectedItems:includeItemBeforePlayheadIfLast:");
            if ([timeline respondsToSelector:selItemsSel]) {
                id selItems = ((id (*)(id, SEL, BOOL, BOOL))objc_msgSend)(timeline, selItemsSel, NO, NO);
                if ([selItems isKindOfClass:[NSArray class]]) {
                    selectedSet = [NSSet setWithArray:selItems];
                    state[@"selectedCount"] = @([(NSArray *)selItems count]);
                }
            }

            // Contained items - FCP uses spine model: sequence -> primaryObject (collection) -> items
            id itemsSource = nil;
            id primaryObj = nil;
            if ([sequence respondsToSelector:@selector(primaryObject)]) {
                primaryObj = ((id (*)(id, SEL))objc_msgSend)(sequence, @selector(primaryObject));
                if (primaryObj && [primaryObj respondsToSelector:@selector(containedItems)]) {
                    itemsSource = ((id (*)(id, SEL))objc_msgSend)(primaryObj, @selector(containedItems));
                }
            }
            // Fallback to sequence.containedItems
            if (!itemsSource && [sequence respondsToSelector:@selector(containedItems)]) {
                itemsSource = ((id (*)(id, SEL))objc_msgSend)(sequence, @selector(containedItems));
            }

            if (itemsSource) {
                id items = itemsSource;
                if ([items isKindOfClass:[NSArray class]]) {
                    NSArray *arr = (NSArray *)items;
                    state[@"itemCount"] = @(arr.count);
                    NSMutableArray *itemList = [NSMutableArray array];
                    NSInteger count = MIN((NSInteger)arr.count, limit);

                    // Check if container supports effectiveRangeOfObject: for absolute positions
                    SEL erSel = NSSelectorFromString(@"effectiveRangeOfObject:");
                    BOOL canGetRange = primaryObj && [primaryObj respondsToSelector:erSel];

                    for (NSInteger i = 0; i < count; i++) {
                        id item = arr[i];
                        NSMutableDictionary *info = [NSMutableDictionary dictionary];
                        info[@"index"] = @(i);
                        info[@"class"] = NSStringFromClass([item class]);

                        if ([item respondsToSelector:@selector(displayName)]) {
                            id name = ((id (*)(id, SEL))objc_msgSend)(item, @selector(displayName));
                            info[@"name"] = name ?: @"";
                        }
                        if ([item respondsToSelector:@selector(duration)]) {
                            FCPBridge_CMTime d = ((FCPBridge_CMTime (*)(id, SEL))objc_msgSend)(item, @selector(duration));
                            info[@"duration"] = FCPBridge_serializeCMTime(d);
                        }
                        if ([item respondsToSelector:@selector(anchoredLane)]) {
                            long long lane = ((long long (*)(id, SEL))objc_msgSend)(item, @selector(anchoredLane));
                            info[@"lane"] = @(lane);
                        }
                        if ([item respondsToSelector:@selector(mediaType)]) {
                            long long mt = ((long long (*)(id, SEL))objc_msgSend)(item, @selector(mediaType));
                            info[@"mediaType"] = @(mt);
                        }

                        info[@"selected"] = @(selectedSet && [selectedSet containsObject:item]);

                        // Store handle for the item
                        NSString *h = FCPBridge_storeHandle(item);
                        info[@"handle"] = h;

                        // Trimmed offset (in-point in source media)
                        SEL trimOffSel = NSSelectorFromString(@"trimmedOffset");
                        if ([item respondsToSelector:trimOffSel]) {
                            FCPBridge_CMTime t = ((FCPBridge_CMTime (*)(id, SEL))objc_msgSend)(item, trimOffSel);
                            info[@"trimmedOffset"] = FCPBridge_serializeCMTime(t);
                        }

                        // Absolute position in timeline via effectiveRangeOfObject:
                        if (canGetRange) {
                            @try {
                                FCPBridge_CMTimeRange range = ((FCPBridge_CMTimeRange (*)(id, SEL, id))objc_msgSend)(
                                    primaryObj, erSel, item);
                                info[@"startTime"] = FCPBridge_serializeCMTime(range.start);
                                // Compute end time = start + duration
                                FCPBridge_CMTime endTime = range.start;
                                if (range.duration.timescale == range.start.timescale) {
                                    endTime.value = range.start.value + range.duration.value;
                                } else if (range.duration.timescale > 0) {
                                    endTime.value = range.start.value +
                                        (range.duration.value * range.start.timescale / range.duration.timescale);
                                }
                                info[@"endTime"] = FCPBridge_serializeCMTime(endTime);
                            } @catch (NSException *e) {
                                // Silently skip if effectiveRangeOfObject: fails for this item
                            }
                        }

                        [itemList addObject:info];
                    }
                    state[@"items"] = itemList;
                }
            }

            // Frame rate from sequence
            SEL frdSel = NSSelectorFromString(@"frameDuration");
            if ([sequence respondsToSelector:frdSel]) {
                FCPBridge_CMTime fd = ((FCPBridge_CMTime (*)(id, SEL))objc_msgSend)(sequence, frdSel);
                state[@"frameDuration"] = FCPBridge_serializeCMTime(fd);
                if (fd.value > 0) {
                    state[@"frameRate"] = @((double)fd.timescale / fd.value);
                }
            }

            result = state;
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result;
}

#pragma mark - FCPXML Import

static NSDictionary *FCPBridge_handleFCPXMLImport(NSDictionary *params) {
    NSString *xml = params[@"xml"];
    if (!xml) return @{@"error": @"xml parameter required"};
    BOOL useInternal = [params[@"internal"] boolValue];

    __block NSDictionary *result = nil;
    FCPBridge_executeOnMainThread(^{
        @try {
            if (useInternal) {
                // Internal import via PEAppController.openXMLDocumentWithURL:
                NSString *tmpPath = [NSTemporaryDirectory()
                    stringByAppendingPathComponent:@"fcpbridge_import.fcpxml"];
                NSData *data = [xml dataUsingEncoding:NSUTF8StringEncoding];
                [data writeToFile:tmpPath atomically:YES];
                NSURL *tmpURL = [NSURL fileURLWithPath:tmpPath];

                id app = ((id (*)(id, SEL))objc_msgSend)(
                    objc_getClass("NSApplication"), @selector(sharedApplication));
                id delegate = ((id (*)(id, SEL))objc_msgSend)(app, @selector(delegate));

                SEL openSel = NSSelectorFromString(@"openXMLDocumentWithURL:bundleURL:display:sender:");
                if ([delegate respondsToSelector:openSel]) {
                    ((void (*)(id, SEL, id, id, BOOL, id))objc_msgSend)(
                        delegate, openSel, tmpURL, nil, YES, nil);
                    result = @{@"status": @"ok", @"method": @"internal",
                               @"message": @"FCPXML import triggered via PEAppController"};
                } else {
                    result = @{@"error": @"PEAppController does not respond to openXMLDocumentWithURL:"};
                }
            } else {
                // File-based import via NSWorkspace
                NSString *tmpPath = [NSTemporaryDirectory()
                    stringByAppendingPathComponent:@"fcpbridge_import.fcpxml"];
                NSData *data = [xml dataUsingEncoding:NSUTF8StringEncoding];
                [data writeToFile:tmpPath atomically:YES];

                NSURL *fileURL = [NSURL fileURLWithPath:tmpPath];
                NSWorkspaceOpenConfiguration *config = [NSWorkspaceOpenConfiguration configuration];
                __block BOOL opened = NO;
                dispatch_semaphore_t sem = dispatch_semaphore_create(0);
                [[NSWorkspace sharedWorkspace] openURLs:@[fileURL]
                    withApplicationAtURL:[[NSBundle mainBundle] bundleURL]
                    configuration:config
                    completionHandler:^(NSRunningApplication *app, NSError *error) {
                        opened = (error == nil);
                        dispatch_semaphore_signal(sem);
                    }];
                dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));
                result = @{@"status": opened ? @"ok" : @"failed",
                           @"method": @"file",
                           @"message": opened ? @"FCPXML import triggered" : @"Failed to open file"};
            }
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result;
}

#pragma mark - Effect Discovery

static NSDictionary *FCPBridge_handleEffectList(NSDictionary *params) {
    NSString *filter = params[@"filter"];

    __block NSDictionary *result = nil;
    FCPBridge_executeOnMainThread(^{
        @try {
            id timeline = FCPBridge_getActiveTimelineModule();
            if (!timeline) {
                result = @{@"error": @"No active timeline"};
                return;
            }

            // Get the sequence's effect registry via the sequence
            id sequence = ((id (*)(id, SEL))objc_msgSend)(timeline, @selector(sequence));
            if (!sequence) {
                result = @{@"error": @"No sequence"};
                return;
            }

            // Try to get effects from the FFEffectRegistry
            Class registryClass = objc_getClass("FFEffectRegistry");
            if (!registryClass) {
                result = @{@"error": @"FFEffectRegistry class not found"};
                return;
            }

            // Get the shared registry
            SEL regSel = NSSelectorFromString(@"registry:");
            id registry = nil;
            if ([registryClass respondsToSelector:regSel]) {
                registry = ((id (*)(id, SEL, id))objc_msgSend)((id)registryClass, regSel, nil);
            }
            if (!registry) {
                // Try alternate: sharedRegistry
                SEL sharedSel = NSSelectorFromString(@"sharedRegistry");
                if ([registryClass respondsToSelector:sharedSel]) {
                    registry = ((id (*)(id, SEL))objc_msgSend)((id)registryClass, sharedSel);
                }
            }

            if (registry) {
                NSString *h = FCPBridge_storeHandle(registry);
                result = @{@"handle": h, @"class": NSStringFromClass([registry class]),
                           @"message": @"Use get_object_property to explore the registry"};
            } else {
                result = @{@"error": @"Could not get FFEffectRegistry instance"};
            }
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result;
}

static NSDictionary *FCPBridge_handleGetClipEffects(NSDictionary *params) {
    NSString *clipHandle = params[@"handle"];

    __block NSDictionary *result = nil;
    FCPBridge_executeOnMainThread(^{
        @try {
            id clip = nil;
            if (clipHandle) {
                clip = FCPBridge_resolveHandle(clipHandle);
            }

            if (!clip) {
                // Get first selected clip
                id timeline = FCPBridge_getActiveTimelineModule();
                if (!timeline) { result = @{@"error": @"No timeline"}; return; }

                SEL selSel = NSSelectorFromString(@"selectedItems:includeItemBeforePlayheadIfLast:");
                if ([timeline respondsToSelector:selSel]) {
                    id selected = ((id (*)(id, SEL, BOOL, BOOL))objc_msgSend)(timeline, selSel, NO, NO);
                    if ([selected respondsToSelector:@selector(firstObject)]) {
                        clip = ((id (*)(id, SEL))objc_msgSend)(selected, @selector(firstObject));
                    }
                }
            }

            if (!clip) { result = @{@"error": @"No clip found (provide handle or select a clip)"}; return; }

            NSMutableDictionary *info = [NSMutableDictionary dictionary];
            info[@"clipClass"] = NSStringFromClass([clip class]);
            if ([clip respondsToSelector:@selector(displayName)]) {
                info[@"clipName"] = ((id (*)(id, SEL))objc_msgSend)(clip, @selector(displayName)) ?: @"";
            }

            // Get effect stack
            SEL esSel = @selector(effectStack);
            if ([clip respondsToSelector:esSel]) {
                id effectStack = ((id (*)(id, SEL))objc_msgSend)(clip, esSel);
                if (effectStack) {
                    NSString *esHandle = FCPBridge_storeHandle(effectStack);
                    info[@"effectStackHandle"] = esHandle;
                    info[@"effectStackClass"] = NSStringFromClass([effectStack class]);
                    info[@"effectStackDescription"] = [[effectStack description] substringToIndex:
                        MIN((NSUInteger)500, [[effectStack description] length])];
                }
            }

            // Try to get effects array
            SEL efSel = NSSelectorFromString(@"effects");
            if ([clip respondsToSelector:efSel]) {
                id effects = ((id (*)(id, SEL))objc_msgSend)(clip, efSel);
                if ([effects isKindOfClass:[NSArray class]]) {
                    NSMutableArray *efList = [NSMutableArray array];
                    for (id effect in (NSArray *)effects) {
                        NSMutableDictionary *ef = [NSMutableDictionary dictionary];
                        ef[@"class"] = NSStringFromClass([effect class]);
                        if ([effect respondsToSelector:@selector(displayName)]) {
                            ef[@"name"] = ((id (*)(id, SEL))objc_msgSend)(effect, @selector(displayName)) ?: @"";
                        }
                        if ([effect respondsToSelector:@selector(effectID)]) {
                            ef[@"effectID"] = ((id (*)(id, SEL))objc_msgSend)(effect, @selector(effectID)) ?: @"";
                        }
                        NSString *efHandle = FCPBridge_storeHandle(effect);
                        ef[@"handle"] = efHandle;
                        [efList addObject:ef];
                    }
                    info[@"effects"] = efList;
                    info[@"effectCount"] = @([(NSArray *)effects count]);
                }
            }

            result = info;
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result;
}

#pragma mark - Timeline Helpers

static id FCPBridge_getActiveTimelineModule(void) {
    // PEAppController -> activeEditorContainer -> timelineModule
    // The app delegate is the PEAppController
    id app = ((id (*)(id, SEL))objc_msgSend)(
        objc_getClass("NSApplication"), @selector(sharedApplication));
    id delegate = ((id (*)(id, SEL))objc_msgSend)(app, @selector(delegate));
    if (!delegate) return nil;

    // Try activeEditorContainer
    SEL aecSel = @selector(activeEditorContainer);
    if (![delegate respondsToSelector:aecSel]) return nil;
    id editorContainer = ((id (*)(id, SEL))objc_msgSend)(delegate, aecSel);
    if (!editorContainer) return nil;

    // Get timeline module from editor container
    SEL tmSel = NSSelectorFromString(@"timelineModule");
    if ([editorContainer respondsToSelector:tmSel]) {
        return ((id (*)(id, SEL))objc_msgSend)(editorContainer, tmSel);
    }

    // Fallback: try activeEditorModule
    SEL aemSel = @selector(activeEditorModule);
    if ([delegate respondsToSelector:aemSel]) {
        return ((id (*)(id, SEL))objc_msgSend)(delegate, aemSel);
    }

    return nil;
}

static id FCPBridge_getEditorContainer(void) {
    id app = ((id (*)(id, SEL))objc_msgSend)(
        objc_getClass("NSApplication"), @selector(sharedApplication));
    id delegate = ((id (*)(id, SEL))objc_msgSend)(app, @selector(delegate));
    if (!delegate) return nil;

    SEL aecSel = @selector(activeEditorContainer);
    if (![delegate respondsToSelector:aecSel]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(delegate, aecSel);
}

// Send an IBAction-style message (-(void)action:(id)sender) to the timeline module
static NSDictionary *FCPBridge_sendTimelineAction(NSString *selectorName) {
    __block NSDictionary *result = nil;

    FCPBridge_executeOnMainThread(^{
        @try {
            id timeline = FCPBridge_getActiveTimelineModule();
            if (!timeline) {
                result = @{@"error": @"No active timeline module. Is a project open?"};
                return;
            }

            SEL sel = NSSelectorFromString(selectorName);
            if (![timeline respondsToSelector:sel]) {
                result = @{@"error": [NSString stringWithFormat:
                    @"Timeline module does not respond to %@", selectorName]};
                return;
            }

            ((void (*)(id, SEL, id))objc_msgSend)(timeline, sel, nil);
            result = @{@"action": selectorName, @"status": @"ok"};
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });

    return result;
}

// Send an IBAction to the editor container (for playback)
static NSDictionary *FCPBridge_sendEditorAction(NSString *selectorName) {
    __block NSDictionary *result = nil;

    FCPBridge_executeOnMainThread(^{
        @try {
            id container = FCPBridge_getEditorContainer();
            if (!container) {
                result = @{@"error": @"No active editor container"};
                return;
            }

            SEL sel = NSSelectorFromString(selectorName);
            if (![container respondsToSelector:sel]) {
                result = @{@"error": [NSString stringWithFormat:
                    @"Editor container does not respond to %@", selectorName]};
                return;
            }

            ((void (*)(id, SEL, id))objc_msgSend)(container, sel, nil);
            result = @{@"action": selectorName, @"status": @"ok"};
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });

    return result;
}

#pragma mark - Timeline Command Handlers

NSDictionary *FCPBridge_handleTimelineAction(NSDictionary *params) {
    // Lazily install effect-drag swizzles on first timeline access
    FCPBridge_installEffectDragSwizzlesNow();

    NSString *action = params[@"action"];
    if (!action) return @{@"error": @"action parameter required"};

    // Map friendly names to selectors on FFAnchoredTimelineModule
    NSDictionary *actionMap = @{
        // Blade/Split
        @"blade":            @"blade:",
        @"bladeAll":         @"bladeAll:",

        // Markers
        @"addMarker":        @"addMarker:",
        @"addTodoMarker":    @"addTodoMarker:",
        @"addChapterMarker": @"addChapterMarker:",
        @"deleteMarker":     @"deleteMarker:",
        @"nextMarker":       @"nextMarker:",
        @"previousMarker":   @"previousMarker:",

        // Transitions
        @"addTransition":    @"addTransition:",

        // Navigation
        @"nextEdit":         @"nextEdit:",
        @"previousEdit":     @"previousEdit:",
        @"selectClipAtPlayhead": @"selectClipAtPlayhead:",
        @"selectToPlayhead": @"selectToPlayhead:",

        // Selection
        @"selectAll":        @"selectAll:",
        @"deselectAll":      @"deselectAll:",

        // Edit operations
        @"delete":           @"delete:",
        @"cut":              @"cut:",
        @"copy":             @"copy:",
        @"paste":            @"paste:",

        // Trim
        @"trimToPlayhead":   @"trimToPlayhead:",
        @"extendEditToPlayhead": @"actionExtendEditToPlayhead",

        // Insert
        @"insertPlaceholder": @"insertPlaceholderStoryline:",
        @"insertGap":        @"insertGapAtPlayhead:",

        // Color Correction (add to selected clips)
        @"addColorBoard":          @"addColorBoardEffect:",
        @"addColorWheels":         @"addColorWheelsEffect:",
        @"addColorCurves":         @"addColorCurvesEffect:",
        @"addColorAdjustment":     @"addColorAdjustmentEffect:",
        @"addHueSaturation":       @"addHueSaturationEffect:",
        @"addEnhanceLightAndColor":@"addEnhanceLightAndColorEffect:",

        // Volume
        @"adjustVolumeUp":         @"adjustVolumeRelative:",
        @"adjustVolumeDown":       @"adjustVolumeAbsolute:",

        // Titles
        @"addBasicTitle":          @"addBasicTitle:",
        @"addBasicLowerThird":     @"addBasicLowerThird:",

        // Retiming/Speed presets
        @"retimeNormal":     @"retimeNormal:",
        @"retimeFast2x":     @"retimeFastx2:",
        @"retimeFast4x":     @"retimeFastx4:",
        @"retimeFast8x":     @"retimeFastx8:",
        @"retimeFast20x":    @"retimeFastx20:",
        @"retimeSlow50":     @"retimeSlowHalf:",
        @"retimeSlow25":     @"retimeSlowQuarter:",
        @"retimeSlow10":     @"retimeSlowTenth:",
        @"retimeReverse":    @"retimeReverse:",
        @"retimeHold":       @"retimeHold:",
        @"freezeFrame":      @"freezeFrame:",
        @"retimeBladeSpeed": @"retimeBladeSpeed:",
        @"retimeSpeedRampToZero": @"retimeSpeedRampToZero:",
        @"retimeSpeedRampFromZero": @"retimeSpeedRampFromZero:",

        // Generators
        @"addVideoGenerator": @"addVideoGenerator:",

        // Export/Share
        @"exportXML":        @"exportXML:",
        @"shareSelection":   @"shareSelection:",

        // Range selection (in/out points)
        @"setRangeStart":    @"setRangeStart:",
        @"setRangeEnd":      @"setRangeEnd:",
        @"clearRange":       @"clearRange:",

        // Keyframes
        @"addKeyframe":      @"addKeyframe:",
        @"deleteKeyframes":  @"deleteKeyframes:",
        @"nextKeyframe":     @"nextKeyframe:",
        @"previousKeyframe": @"previousKeyframe:",

        // Solo/Disable
        @"solo":             @"soloSelectedClips:",
        @"disable":          @"disableSelectedClips:",

        // Compound clips
        @"createCompoundClip": @"createCompoundClip:",

        // Auto-reframe
        @"autoReframe":      @"autoReframe:",

        // Clip operations
        @"detachAudio":      @"detachAudio:",
        @"breakApartClipItems": @"breakApartClipItems:",
        @"removeEffects":    @"removeEffects:",
        @"liftFromPrimaryStoryline": @"liftFromSpine:",
        @"overwriteToPrimaryStoryline": @"collapseToSpine:",
        @"createStoryline":  @"createStoryline:",
        @"collapseToConnectedStoryline": @"collapseToConnectedStoryline:",

        // Timeline view
        @"zoomToFit":        @"zoomToFit:",
        @"zoomIn":           @"zoomIn:",
        @"zoomOut":          @"zoomOut:",
        @"verticalZoomToFit": @"verticalZoomToFit:",
        @"zoomToSamples":    @"zoomToSamples:",
        @"toggleSnapping":   @"toggleSnapping:",
        @"toggleSkimming":   @"toggleSkimming:",
        @"toggleClipSkimming": @"toggleItemSkimming:",
        @"toggleAudioSkimming": @"toggleAudioScrubbingDown:",
        @"toggleInspector":  @"toggleInspector:",
        @"toggleTimeline":   @"toggleTimeline:",
        @"toggleTimelineIndex": @"toggleTimelineIndex:",
        @"toggleInspectorHeight": @"toggleInspectorHeight:",
        @"showPrecisionEditor": @"showPrecisionEditor:",
        @"showAudioLanes":   @"showAudioLanes:",
        @"expandSubroles":   @"expandSubroles:",
        @"timelineHistoryBack": @"timelineHistoryBack:",
        @"timelineHistoryForward": @"timelineHistoryForward:",
        @"beatDetectionGrid": @"toggleBeatDetectionGrid:",
        @"timelineScrolling": @"toggleTimelineScrolling:",
        @"enterFullScreen":  @"toggleFullScreen:",

        // Render
        @"renderSelection":  @"renderSelection:",
        @"renderAll":        @"renderAll:",

        // Markers
        @"deleteMarkersInSelection": @"deleteMarkersInSelection:",

        // Analysis
        @"analyzeAndFix":    @"analyzeAndFix:",

        // Edit modes (insert/append/overwrite/connect)
        @"connectToPrimaryStoryline": @"anchorWithSelectedMedia:",
        @"insertEdit":       @"insertWithSelectedMedia:",
        @"appendEdit":       @"appendWithSelectedMedia:",
        @"overwriteEdit":    @"overwriteWithSelectedMedia:",

        // Paste variants
        @"pasteAsConnected": @"pasteAnchored:",
        @"pasteEffects":     @"pasteEffects:",
        @"pasteAttributes":  @"pasteAttributes:",
        @"removeAttributes": @"removeAttributes:",
        @"copyAttributes":   @"copyAttributes:",

        // Replace/delete variants
        @"replaceWithGap":   @"shiftDelete:",
        @"deleteSelection":  @"deleteSelection:",

        // Trim operations
        @"trimStart":        @"trimStart:",
        @"trimEnd":          @"trimEnd:",
        @"joinClips":        @"joinSelection:",

        // Nudge
        @"nudgeLeft":        @"nudgeLeft:",
        @"nudgeRight":       @"nudgeRight:",
        @"nudgeUp":          @"nudgeUp:",
        @"nudgeDown":        @"nudgeDown:",

        // Rating
        @"favorite":         @"favorite:",
        @"reject":           @"reject:",
        @"unrate":           @"unfavorite:",

        // Mark/Range
        @"setClipRange":     @"selectClip:",
        @"copyTimecode":     @"copyTimecode:",

        // Project operations
        @"duplicateProject": @"duplicate:",
        @"snapshotProject":  @"snapshotProject:",

        // Audio operations
        @"expandAudio":      @"splitEdit:",
        @"expandAudioComponents": @"toggleAudioComponents:",
        @"addChannelEQ":     @"addChannelEQ:",
        @"enhanceAudio":     @"enhanceAudio:",
        @"matchAudio":       @"matchAudio:",

        // Show/hide editors
        @"showVideoAnimation": @"showTimelineCurveEditor:",
        @"showAudioAnimation": @"showTimelineCurveEditor:",
        @"soloAnimation":    @"collapseTimelineCurveEditor:",
        @"showTrackingEditor": @"showTrackingEditor:",
        @"showCinematicEditor": @"showCinematicEditor:",
        @"showMagneticMaskEditor": @"showMagneticMaskEditor:",
        @"enableBeatDetection": @"enableBeatDetection:",

        // Clip operations
        @"synchronizeClips": @"mergeClips:",
        @"openClip":         @"openInTimeline:",
        @"renameClip":       @"renameClip:",
        @"addToSoloedClips": @"addToSoloedClips:",
        @"referenceNewParentClip": @"referenceNewParentClip:",

        // Color correction extras
        @"balanceColor":     @"toggleBalanceColor:",
        @"matchColor":       @"matchColor:",
        @"addMagneticMask":  @"addObjectMaskEffect:",
        @"smartConform":     @"autoReframe:",
        @"enhanceLightAndColor": @"enhanceLightAndColor:",

        // Adjustment clip
        @"addAdjustmentClip": @"connectAdjustmentClip:",

        // Voiceover
        @"recordVoiceover":  @"toggleVoiceoverRecordView:",

        // Window/workspace
        @"backgroundTasks":  @"goToBackgroundTaskList:",
        @"showDuplicateRanges": @"showDuplicateRanges:",

        // Roles
        @"editRoles":        @"editRoles:",

        // Change duration
        @"changeDuration":   @"showTimecodeEntryDuration:",

        // Keywords
        @"showKeywordEditor": @"toggleKeywordEditor:",
        @"removeAllKeywords": @"removeAllKeywords:",
        @"removeAnalysisKeywords": @"removeAnalysisKeywords:",

        // Hide clip
        @"hideClip":         @"hideClip:",

        // Audition
        @"createAudition":   @"createAudition:",
        @"finalizeAudition": @"finalizeAudition:",
        @"nextAuditionPick": @"nextAuditionPick:",
        @"previousAuditionPick": @"previousAuditionPick:",

        // Captions
        @"addCaption":       @"addCaption:",
        @"splitCaption":     @"splitCaptions:",
        @"resolveOverlaps":  @"resolveCaptionOverlaps:",

        // Multicam
        @"createMulticamClip": @"createMulticamClip:",

        // Source media
        @"revealInBrowser":  @"revealSourceInBrowser:",
        @"revealProjectInBrowser": @"revealProjectInBrowser:",
        @"revealInFinder":   @"revealInFinder:",
        @"moveToTrash":      @"moveToTrash:",

        // Library
        @"closeLibrary":     @"closeLibrary:",
        @"libraryProperties": @"showLibraryProperties:",
        @"consolidateEventMedia": @"consolidateEventMedia:",
        @"mergeEvents":      @"mergeEvents:",
        @"deleteGeneratedFiles": @"deleteGeneratedFiles:",

        // Find
        @"find":             @"performFindPanelAction:",
        @"findAndReplaceTitle": @"findAndReplaceTitleText:",

        // Project properties
        @"projectProperties": @"showProjectProperties:",

        // Edit modes - audio/video only
        @"insertEditAudio":  @"insertWithSelectedMediaAudio:",
        @"insertEditVideo":  @"insertWithSelectedMediaVideo:",
        @"appendEditAudio":  @"appendWithSelectedMediaAudio:",
        @"appendEditVideo":  @"appendWithSelectedMediaVideo:",
        @"overwriteEditAudio": @"overwriteWithSelectedMediaAudio:",
        @"overwriteEditVideo": @"overwriteWithSelectedMediaVideo:",
        @"connectEditAudio": @"anchorWithSelectedMediaAudio:",
        @"connectEditVideo": @"anchorWithSelectedMediaVideo:",
        @"connectEditBacktimed": @"anchorWithSelectedMediaBacktimed:",

        // Replace edits
        @"replaceFromStart": @"replaceWithSelectedMediaFromStart:",
        @"replaceFromEnd":   @"replaceWithSelectedMediaFromEnd:",
        @"replaceWhole":     @"replaceWithSelectedMediaWhole:",

        // Retiming extras
        @"retimeCustomSpeed": @"retimeCustomSpeed:",
        @"retimeInstantReplayHalf": @"retimeInstantReplayHalf:",
        @"retimeInstantReplayQuarter": @"retimeInstantReplayQuarter:",
        @"retimeReset":      @"retimeReset:",
        @"retimeOpticalFlow": @"retimeTurnOnOpticalFlow:",
        @"retimeFrameBlending": @"retimeTurnOnSmoothTransition:",
        @"retimeFloorFrame": @"retimeTurnOnFloorFrameSampling:",

        // AV edit mode
        @"avEditModeAudio":  @"avEditModeAudio:",
        @"avEditModeVideo":  @"avEditModeVideo:",
        @"avEditModeBoth":   @"avEditModeBoth:",

        // Keyword groups
        @"addKeywordGroup1": @"addKeywordGroup1:",
        @"addKeywordGroup2": @"addKeywordGroup2:",
        @"addKeywordGroup3": @"addKeywordGroup3:",
        @"addKeywordGroup4": @"addKeywordGroup4:",
        @"addKeywordGroup5": @"addKeywordGroup5:",
        @"addKeywordGroup6": @"addKeywordGroup6:",
        @"addKeywordGroup7": @"addKeywordGroup7:",

        // Color correction navigation
        @"nextColorEffect":  @"nextColorEffect:",
        @"previousColorEffect": @"previousColorEffect:",
        @"resetColorBoard":  @"resetPucksOnCurrentBoard:",
        @"toggleAllColorOff": @"toggleAllColorCorrectionOff:",

        // Paste attribute variants
        @"pasteAllAttributes": @"pasteAllAttributes:",

        // Audio extras
        @"alignAudioToVideo": @"alignAudioToVideo:",
        @"volumeMute":       @"volumeMinusInfinity:",
        @"addDefaultAudioEffect": @"addDefaultAudioEffect:",
        @"addDefaultVideoEffect": @"addDefaultVideoEffect:",
        @"applyAudioFades":  @"applyAudioFades:",

        // Effects toggles
        @"toggleSelectedEffectsOff": @"toggleSelectedEffectsOff:",
        @"toggleDuplicateDetection": @"toggleDupeDetection:",

        // Clip extras
        @"makeClipsUnique":  @"makeClipsUnique:",
        @"enableDisable":    @"enableOrDisableEdit:",
        @"transcodeMedia":   @"transcodeMedia:",

        // Navigation extras
        @"selectNextItem":   @"selectNextItem:",
        @"selectUpperItem":  @"selectUpperItem:",

        // View extras
        @"togglePrecisionEditor": @"togglePrecisionEditor:",
        @"goToInspector":    @"goToInspector:",
        @"goToTimeline":     @"goToTimeline:",
        @"goToViewer":       @"goToViewer:",
        @"goToColorBoard":   @"goToColorBoard:",

        // Preferences
        @"showPreferences":  @"showPreferences:",
    };

    // Undo/redo go through the document's FFUndoManager
    if ([action isEqualToString:@"undo"] || [action isEqualToString:@"redo"]) {
        __block NSDictionary *undoResult = nil;
        FCPBridge_executeOnMainThread(^{
            @try {
                id app = ((id (*)(id, SEL))objc_msgSend)(
                    objc_getClass("NSApplication"), @selector(sharedApplication));
                id delegate = ((id (*)(id, SEL))objc_msgSend)(app, @selector(delegate));
                // PEAppController -> _targetLibrary -> libraryDocument -> undoManager
                SEL libSel = NSSelectorFromString(@"_targetLibrary");
                id library = nil;
                if ([delegate respondsToSelector:libSel]) {
                    library = ((id (*)(id, SEL))objc_msgSend)(delegate, libSel);
                }
                if (!library) {
                    // Fallback: get first active library
                    id libs = ((id (*)(id, SEL))objc_msgSend)(
                        objc_getClass("FFLibraryDocument"), @selector(copyActiveLibraries));
                    if ([libs respondsToSelector:@selector(firstObject)]) {
                        library = ((id (*)(id, SEL))objc_msgSend)(libs, @selector(firstObject));
                    }
                }
                if (!library) {
                    undoResult = @{@"error": @"No library found for undo"};
                    return;
                }
                id doc = ((id (*)(id, SEL))objc_msgSend)(library, @selector(libraryDocument));
                if (!doc) {
                    undoResult = @{@"error": @"No document found for undo"};
                    return;
                }
                id um = ((id (*)(id, SEL))objc_msgSend)(doc, @selector(undoManager));
                if (!um) {
                    undoResult = @{@"error": @"No undo manager"};
                    return;
                }

                SEL undoSel = [action isEqualToString:@"undo"] ? @selector(undo) : @selector(redo);
                SEL canSel = [action isEqualToString:@"undo"] ? @selector(canUndo) : @selector(canRedo);
                SEL nameSel = [action isEqualToString:@"undo"] ? @selector(undoActionName) : @selector(redoActionName);

                BOOL can = ((BOOL (*)(id, SEL))objc_msgSend)(um, canSel);
                if (!can) {
                    undoResult = @{@"error": [NSString stringWithFormat:@"Cannot %@ - nothing to %@", action, action]};
                    return;
                }

                NSString *actionName = ((id (*)(id, SEL))objc_msgSend)(um, nameSel);
                ((void (*)(id, SEL))objc_msgSend)(um, undoSel);
                undoResult = @{@"action": action, @"status": @"ok",
                              @"actionName": actionName ?: @""};
            } @catch (NSException *e) {
                undoResult = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
            }
        });
        return undoResult;
    }

    NSString *selector = actionMap[action];
    if (!selector) {
        // Allow passing raw selector names too
        selector = action;
        if (![selector hasSuffix:@":"]) {
            selector = [selector stringByAppendingString:@":"];
        }
    }

    // First try on the timeline module directly (fastest, most specific)
    NSDictionary *result = FCPBridge_sendTimelineAction(selector);

    // If timeline module doesn't respond, fall back to responder chain
    if (result[@"error"]) {
        NSString *errMsg = result[@"error"];
        if ([errMsg containsString:@"does not respond"] || [errMsg containsString:@"No active"]) {
            return FCPBridge_sendAppAction(selector);
        }
    }

    return result;
}

// Get the FFPlayerModule from editor container
static id FCPBridge_getPlayerModule(void) {
    id container = FCPBridge_getEditorContainer();
    if (!container) return nil;

    // Try playerModule or editorModule.playerModule
    SEL pmSel = NSSelectorFromString(@"playerModule");
    if ([container respondsToSelector:pmSel]) {
        return ((id (*)(id, SEL))objc_msgSend)(container, pmSel);
    }
    // Try through editorModule
    SEL emSel = NSSelectorFromString(@"editorModule");
    if ([container respondsToSelector:emSel]) {
        id editor = ((id (*)(id, SEL))objc_msgSend)(container, emSel);
        if (editor && [editor respondsToSelector:pmSel]) {
            return ((id (*)(id, SEL))objc_msgSend)(editor, pmSel);
        }
    }
    return nil;
}

// Send action via NSApp.sendAction:to:from: (goes through responder chain)
static NSDictionary *FCPBridge_sendAppAction(NSString *selectorName) {
    __block NSDictionary *result = nil;

    FCPBridge_executeOnMainThread(^{
        @try {
            id app = ((id (*)(id, SEL))objc_msgSend)(
                objc_getClass("NSApplication"), @selector(sharedApplication));
            SEL sel = NSSelectorFromString(selectorName);
            BOOL sent = ((BOOL (*)(id, SEL, SEL, id, id))objc_msgSend)(
                app, @selector(sendAction:to:from:), sel, nil, nil);
            if (sent) {
                result = @{@"action": selectorName, @"status": @"ok"};
            } else {
                result = @{@"error": [NSString stringWithFormat:
                    @"No responder handled %@", selectorName]};
            }
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });

    return result;
}

// Send action to the player module specifically
static NSDictionary *FCPBridge_sendPlayerAction(NSString *selectorName) {
    __block NSDictionary *result = nil;

    FCPBridge_executeOnMainThread(^{
        @try {
            id player = FCPBridge_getPlayerModule();
            if (!player) {
                result = @{@"error": @"No player module found"};
                return;
            }

            SEL sel = NSSelectorFromString(selectorName);
            if (![player respondsToSelector:sel]) {
                result = @{@"error": [NSString stringWithFormat:
                    @"Player module does not respond to %@", selectorName]};
                return;
            }

            ((void (*)(id, SEL, id))objc_msgSend)(player, sel, nil);
            result = @{@"action": selectorName, @"status": @"ok"};
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });

    return result;
}

NSDictionary *FCPBridge_handlePlayback(NSDictionary *params) {
    NSString *action = params[@"action"];
    if (!action) return @{@"error": @"action parameter required"};

    // All playback actions go through the responder chain (NSApp.sendAction:to:from:)
    // This is how FCP's menu items work - they route to FFPlayerModule,
    // PEEditorContainerModule, etc. automatically.
    NSDictionary *actionMap = @{
        @"playPause":         @"playPause:",
        @"goToStart":         @"gotoStart:",
        @"goToEnd":           @"gotoEnd:",
        @"nextFrame":         @"stepForward:",
        @"prevFrame":         @"stepBackward:",
        @"nextFrame10":       @"stepForward10Frames:",
        @"prevFrame10":       @"stepBackward10Frames:",
        @"playAroundCurrent": @"playAroundCurrentFrame:",
        @"playFromStart":    @"playFromStart:",
        @"playInToOut":      @"playInToOut:",
        @"playReverse":      @"playReverse:",
        @"stopPlaying":      @"stopPlaying:",
        @"loop":             @"loop:",
        @"fastForward":      @"fastForward:",
        @"rewind":           @"rewind:",
    };

    NSString *selector = actionMap[action];
    if (!selector) {
        selector = action;
        if (![selector hasSuffix:@":"]) {
            selector = [selector stringByAppendingString:@":"];
        }
    }

    return FCPBridge_sendAppAction(selector);
}

NSDictionary *FCPBridge_handlePlaybackSeek(NSDictionary *params) {
    NSNumber *seconds = params[@"seconds"];
    if (!seconds) return @{@"error": @"seconds parameter required"};

    __block NSDictionary *result = nil;
    FCPBridge_executeOnMainThread(^{
        @try {
            id timeline = FCPBridge_getActiveTimelineModule();
            if (!timeline) {
                result = @{@"error": @"No active timeline module"};
                return;
            }

            // Get the sequence timescale for accurate time construction
            int32_t timescale = 24000; // default
            SEL seqSel = @selector(sequence);
            if ([timeline respondsToSelector:seqSel]) {
                id sequence = ((id (*)(id, SEL))objc_msgSend)(timeline, seqSel);
                if (sequence) {
                    // Try to get frameDuration to derive timescale
                    // On ARM64, objc_msgSend handles struct returns directly
                    SEL fdSel = NSSelectorFromString(@"frameDuration");
                    if ([sequence respondsToSelector:fdSel]) {
                        FCPBridge_CMTime fd = ((FCPBridge_CMTime (*)(id, SEL))objc_msgSend)(
                            sequence, fdSel);
                        if (fd.timescale > 0) timescale = fd.timescale;
                    }
                }
            }

            // Build CMTime from seconds
            double secs = [seconds doubleValue];
            FCPBridge_CMTime targetTime;
            targetTime.value = (int64_t)(secs * timescale);
            targetTime.timescale = timescale;
            targetTime.flags = 1; // kCMTimeFlags_Valid
            targetTime.epoch = 0;

            // Call setPlayheadTime: on the timeline module
            SEL setSel = @selector(setPlayheadTime:);
            if ([timeline respondsToSelector:setSel]) {
                ((void (*)(id, SEL, FCPBridge_CMTime))objc_msgSend)(
                    timeline, setSel, targetTime);
                result = @{
                    @"status": @"ok",
                    @"seconds": @(secs),
                    @"time": FCPBridge_serializeCMTime(targetTime),
                };
            } else {
                result = @{@"error": @"Timeline module does not respond to setPlayheadTime:"};
            }
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result ?: @{@"error": @"Failed to seek"};
}

NSDictionary *FCPBridge_handlePlaybackGetPosition(NSDictionary *params) {
    __block NSDictionary *result = nil;
    FCPBridge_executeOnMainThread(^{
        @try {
            id timeline = FCPBridge_getActiveTimelineModule();
            if (!timeline) { result = @{@"error": @"No active timeline module"}; return; }

            // Read playhead time
            SEL phSel = NSSelectorFromString(@"playheadTime");
            if ([timeline respondsToSelector:phSel]) {
                FCPBridge_CMTime pht = ((FCPBridge_CMTime (*)(id, SEL))objc_msgSend)(timeline, phSel);
                double seconds = (pht.timescale > 0) ? (double)pht.value / pht.timescale : 0;

                NSMutableDictionary *r = [NSMutableDictionary dictionary];
                r[@"seconds"] = @(seconds);
                r[@"time"] = FCPBridge_serializeCMTime(pht);

                // Also get sequence duration for context
                SEL seqSel = @selector(sequence);
                if ([timeline respondsToSelector:seqSel]) {
                    id sequence = ((id (*)(id, SEL))objc_msgSend)(timeline, seqSel);
                    if (sequence && [sequence respondsToSelector:@selector(duration)]) {
                        FCPBridge_CMTime dur = ((FCPBridge_CMTime (*)(id, SEL))objc_msgSend)(sequence, @selector(duration));
                        r[@"duration"] = FCPBridge_serializeCMTime(dur);
                    }
                    // Frame rate
                    SEL fdSel = NSSelectorFromString(@"frameDuration");
                    if (sequence && [sequence respondsToSelector:fdSel]) {
                        FCPBridge_CMTime fd = ((FCPBridge_CMTime (*)(id, SEL))objc_msgSend)(sequence, fdSel);
                        if (fd.timescale > 0 && fd.value > 0) {
                            r[@"frameRate"] = @((double)fd.timescale / fd.value);
                            r[@"frameDuration"] = FCPBridge_serializeCMTime(fd);
                        }
                    }
                }

                // Check if playing
                SEL playSel = NSSelectorFromString(@"isPlaying");
                if ([timeline respondsToSelector:playSel]) {
                    BOOL playing = ((BOOL (*)(id, SEL))objc_msgSend)(timeline, playSel);
                    r[@"isPlaying"] = @(playing);
                }

                result = r;
            } else {
                result = @{@"error": @"Cannot read playhead time"};
            }
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result ?: @{@"error": @"Failed to get position"};
}

#pragma mark - Range Selection & Batch Export

// Helper: build a CMTime from seconds using the sequence timescale
static FCPBridge_CMTime FCPBridge_buildCMTime(double seconds, id timeline) {
    int32_t timescale = 24000; // default
    SEL seqSel = @selector(sequence);
    if ([timeline respondsToSelector:seqSel]) {
        id sequence = ((id (*)(id, SEL))objc_msgSend)(timeline, seqSel);
        if (sequence) {
            SEL fdSel = NSSelectorFromString(@"frameDuration");
            if ([sequence respondsToSelector:fdSel]) {
                FCPBridge_CMTime fd = ((FCPBridge_CMTime (*)(id, SEL))objc_msgSend)(sequence, fdSel);
                if (fd.timescale > 0) timescale = fd.timescale;
            }
        }
    }
    FCPBridge_CMTime t;
    t.value = (int64_t)(seconds * timescale);
    t.timescale = timescale;
    t.flags = 1; // kCMTimeFlags_Valid
    t.epoch = 0;
    return t;
}

// Helper: simulate a key press in FCP (posts key down + key up events)
static void FCPBridge_simulateKeyPress(unsigned short keyCode, NSString *chars, NSEventModifierFlags mods) {
    id app = ((id (*)(id, SEL))objc_msgSend)(
        objc_getClass("NSApplication"), @selector(sharedApplication));
    id window = ((id (*)(id, SEL))objc_msgSend)(app, @selector(mainWindow));
    NSInteger winNum = window ? [(NSWindow *)window windowNumber] : 0;

    NSEvent *keyDown = [NSEvent keyEventWithType:NSEventTypeKeyDown
                                        location:NSZeroPoint
                                   modifierFlags:mods
                                       timestamp:[[NSProcessInfo processInfo] systemUptime]
                                    windowNumber:winNum
                                         context:nil
                                      characters:chars
                     charactersIgnoringModifiers:chars
                                       isARepeat:NO
                                         keyCode:keyCode];
    [app sendEvent:keyDown];

    NSEvent *keyUp = [NSEvent keyEventWithType:NSEventTypeKeyUp
                                      location:NSZeroPoint
                                 modifierFlags:mods
                                     timestamp:[[NSProcessInfo processInfo] systemUptime]
                                  windowNumber:winNum
                                       context:nil
                                    characters:chars
                   charactersIgnoringModifiers:chars
                                     isARepeat:NO
                                       keyCode:keyCode];
    [app sendEvent:keyUp];
}

// Helper: seek playhead and mark in/out using simulated key presses
static BOOL FCPBridge_seekAndMark(id timeline, FCPBridge_CMTime time, NSString *actionSelector) {
    // Seek playhead
    SEL setSel = @selector(setPlayheadTime:);
    if (![timeline respondsToSelector:setSel]) return NO;
    ((void (*)(id, SEL, FCPBridge_CMTime))objc_msgSend)(timeline, setSel, time);

    // Let FCP update playhead position
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];

    // Simulate key press: 'I' (keyCode 34) for mark in, 'O' (keyCode 31) for mark out
    if ([actionSelector isEqualToString:@"setRangeStart:"]) {
        FCPBridge_simulateKeyPress(34, @"i", 0); // 'I' key = mark in
    } else if ([actionSelector isEqualToString:@"setRangeEnd:"]) {
        FCPBridge_simulateKeyPress(31, @"o", 0); // 'O' key = mark out
    } else if ([actionSelector isEqualToString:@"clearRange:"]) {
        FCPBridge_simulateKeyPress(7, @"x", NSEventModifierFlagOption); // Option+X = clear range
    } else {
        // Fallback: try responder chain
        id app = ((id (*)(id, SEL))objc_msgSend)(
            objc_getClass("NSApplication"), @selector(sharedApplication));
        SEL actionSel = NSSelectorFromString(actionSelector);
        return ((BOOL (*)(id, SEL, SEL, id, id))objc_msgSend)(
            app, @selector(sendAction:to:from:), actionSel, nil, nil);
    }

    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    return YES;
}

static NSDictionary *FCPBridge_handleSetRange(NSDictionary *params) {
    NSNumber *startSec = params[@"startSeconds"];
    NSNumber *endSec = params[@"endSeconds"];
    if (!startSec || !endSec) {
        return @{@"error": @"startSeconds and endSeconds parameters required"};
    }

    __block NSDictionary *result = nil;
    FCPBridge_executeOnMainThread(^{
        @try {
            id timeline = FCPBridge_getActiveTimelineModule();
            if (!timeline) {
                result = @{@"error": @"No active timeline module"};
                return;
            }

            double startVal = [startSec doubleValue];
            double endVal = [endSec doubleValue];

            // Build CMTimes
            FCPBridge_CMTime startTime = FCPBridge_buildCMTime(startVal, timeline);
            FCPBridge_CMTime endTime = FCPBridge_buildCMTime(endVal, timeline);

            // Seek to start, mark in
            BOOL inOk = FCPBridge_seekAndMark(timeline, startTime, @"setRangeStart:");
            // Seek to end, mark out
            BOOL outOk = FCPBridge_seekAndMark(timeline, endTime, @"setRangeEnd:");

            result = @{
                @"status": @"ok",
                @"startSeconds": @(startVal),
                @"endSeconds": @(endVal),
                @"rangeStartSet": @(inOk),
                @"rangeEndSet": @(outOk),
            };
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result ?: @{@"error": @"Failed to set range"};
}

// Helper: collect exportable clips with their time ranges (no ARC-managed ObjC objects in the mix)
static NSArray *FCPBridge_collectExportableClips(id primaryObj, NSSet *selectedSet) {
    SEL erSel = NSSelectorFromString(@"effectiveRangeOfObject:");
    if (![primaryObj respondsToSelector:erSel]) return nil;

    NSArray *allItems = ((id (*)(id, SEL))objc_msgSend)(primaryObj, @selector(containedItems));
    if (![allItems isKindOfClass:[NSArray class]]) return nil;

    Class transitionClass = objc_getClass("FFAnchoredTransition");
    NSMutableArray *clips = [NSMutableArray array];

    for (id item in allItems) {
        if (transitionClass && [item isKindOfClass:transitionClass]) continue;
        NSString *className = NSStringFromClass([item class]);
        if ([className containsString:@"Gap"]) continue;
        if (selectedSet && ![selectedSet containsObject:item]) continue;

        @try {
            FCPBridge_CMTimeRange range = ((FCPBridge_CMTimeRange (*)(id, SEL, id))objc_msgSend)(
                primaryObj, erSel, item);
            NSString *name = @"Untitled";
            if ([item respondsToSelector:@selector(displayName)]) {
                id n = ((id (*)(id, SEL))objc_msgSend)(item, @selector(displayName));
                if (n) name = n;
            }
            FCPBridge_CMTime endTime = range.start;
            if (range.duration.timescale == range.start.timescale) {
                endTime.value = range.start.value + range.duration.value;
            } else if (range.duration.timescale > 0) {
                endTime.value = range.start.value +
                    (range.duration.value * range.start.timescale / range.duration.timescale);
            }
            [clips addObject:@{
                @"name": name,
                @"startTime": FCPBridge_serializeCMTime(range.start),
                @"endTime": FCPBridge_serializeCMTime(endTime),
                @"startCMTime": [NSValue valueWithBytes:&range.start objCType:@encode(FCPBridge_CMTime)],
                @"endCMTime": [NSValue valueWithBytes:&endTime objCType:@encode(FCPBridge_CMTime)],
            }];
        } @catch (NSException *e) { /* skip */ }
    }
    return clips;
}

// --- Batch Export: swizzle approach ---
// We swizzle FFSequenceExporter's showSharePanelWithSources:... to skip the modal dialog
// and directly queue the export. The original method creates a share panel, runs it modally,
// then queues batches. Our replacement creates the panel silently, extracts batches, and queues.

static NSURL *sBatchExportFolderURL = nil;
static NSString *sBatchExportFileName = nil;
static BOOL sBatchExportActive = NO;
static IMP sOrigShowSharePanel = NULL;
static NSInteger sBatchExportPendingCount = 0; // tracks async exports still running
static FCPBridge_CMTime sBatchExportClipStart;
static FCPBridge_CMTime sBatchExportClipEnd;

// Swizzle NSWorkspace openURL: to suppress auto-open of exported files
static IMP sOrigOpenURL = NULL;
static BOOL FCPBridge_swizzled_openURL(id self, SEL _cmd, id url) {
    if (sBatchExportPendingCount > 0 && url && [url isKindOfClass:[NSURL class]]) {
        // Suppress opening files from the batch export folder
        NSString *path = [(NSURL *)url path];
        NSString *folderPath = [sBatchExportFolderURL path];
        if (folderPath && [path hasPrefix:folderPath]) {
            FCPBridge_log(@"[BatchExport] Suppressed auto-open: %@", path);
            sBatchExportPendingCount--;
            return YES; // pretend we opened it
        }
    }
    // Call original
    return sOrigOpenURL ? ((BOOL (*)(id, SEL, id))sOrigOpenURL)(self, _cmd, url) : NO;
}

// Also suppress activateFileViewerSelectingURLs: (Reveal in Finder)
static IMP sOrigRevealURLs = NULL;
static void FCPBridge_swizzled_revealURLs(id self, SEL _cmd, id urls) {
    if (sBatchExportPendingCount > 0 && urls) {
        FCPBridge_log(@"[BatchExport] Suppressed reveal in Finder");
        return;
    }
    if (sOrigRevealURLs) ((void (*)(id, SEL, id))sOrigRevealURLs)(self, _cmd, urls);
}

// Suppress openURL:configuration:completionHandler: (modern API)
static IMP sOrigOpenURLConfig = NULL;
static void FCPBridge_swizzled_openURLConfig(id self, SEL _cmd, id url, id config, id handler) {
    if (sBatchExportPendingCount > 0 && url && [url isKindOfClass:[NSURL class]]) {
        NSString *path = [(NSURL *)url path];
        NSString *folderPath = [sBatchExportFolderURL path];
        if (folderPath && [path hasPrefix:folderPath]) {
            FCPBridge_log(@"[BatchExport] Suppressed openURL:config: %@", path);
            sBatchExportPendingCount--;
            if (handler) ((void (^)(id, id))handler)(nil, nil);
            return;
        }
    }
    if (sOrigOpenURLConfig) ((void (*)(id, SEL, id, id, id))sOrigOpenURLConfig)(self, _cmd, url, config, handler);
}

// Suppress openURLs:withApplicationAtURL:configuration:completionHandler:
static IMP sOrigOpenURLs = NULL;
static void FCPBridge_swizzled_openURLs(id self, SEL _cmd, id urls, id appURL, id config, id handler) {
    if (sBatchExportPendingCount > 0 && urls) {
        FCPBridge_log(@"[BatchExport] Suppressed openURLs: batch");
        sBatchExportPendingCount--;
        if (handler) ((void (^)(id, id))handler)(nil, nil);
        return;
    }
    if (sOrigOpenURLs) ((void (*)(id, SEL, id, id, id, id))sOrigOpenURLs)(self, _cmd, urls, appURL, config, handler);
}

// Suppress openFile: (deprecated but still used)
static IMP sOrigOpenFile = NULL;
static BOOL FCPBridge_swizzled_openFile(id self, SEL _cmd, id path) {
    if (sBatchExportPendingCount > 0 && path) {
        NSString *folderPath = [sBatchExportFolderURL path];
        if (folderPath && [(NSString *)path hasPrefix:folderPath]) {
            sBatchExportPendingCount--;
            return YES;
        }
    }
    return sOrigOpenFile ? ((BOOL (*)(id, SEL, id))sOrigOpenFile)(self, _cmd, path) : NO;
}

// Replacement for -[FFSequenceExporter showSharePanelWithSources:destination:destinationURL:parentWindow:]
// Called after shareToDestination:parentWindow: has already converted sources to CK format
static void FCPBridge_swizzled_showSharePanel(id self, SEL _cmd, id sources, id dest, id destURL, id parentWindow) {
    if (!sBatchExportActive) {
        // Not in batch mode - call original
        if (sOrigShowSharePanel) {
            ((void (*)(id, SEL, id, id, id, id))sOrigShowSharePanel)(self, _cmd, sources, dest, destURL, parentWindow);
        }
        return;
    }

    FCPBridge_log(@"[BatchExport] Swizzled showSharePanel called with %@ sources, dest=%@",
        sources ? @([(NSArray *)sources count]) : @"nil", NSStringFromClass([dest class]));

    @try {
        // Determine panel class (consumer vs pro)
        BOOL isConsumer = ((BOOL (*)(id, SEL))objc_msgSend)(
            objc_getClass("Flexo"), NSSelectorFromString(@"isConsumerUI"));

        Class panelClass = isConsumer
            ? objc_getClass("FFConsumerSharePanel")
            : objc_getClass("FFSharePanel");
        if (!panelClass) panelClass = objc_getClass("FFBaseSharePanel");

        // Modify source to set clip-specific in/out range
        id firstSource = [(NSArray *)sources firstObject];
        id sourceToUse = firstSource;

        SEL mutableCopySel = @selector(mutableCopy);
        SEL setInOutSel = NSSelectorFromString(@"setInPoint:outPoint:");
        if (firstSource && [firstSource respondsToSelector:mutableCopySel] &&
            sBatchExportClipStart.flags == 1 && sBatchExportClipEnd.flags == 1) {
            // Create a mutable copy and set the clip's range as in/out points
            sourceToUse = ((id (*)(id, SEL))objc_msgSend)(firstSource, mutableCopySel);
            if (sourceToUse && [sourceToUse respondsToSelector:setInOutSel]) {
                // Convert our CMTime to NSValue objects that the source expects
                // The source's setInPoint:outPoint: takes CMTime-wrapping objects
                // Let's try creating PCTimeObject or similar
                SEL inPtSel = NSSelectorFromString(@"inPoint");
                id origIn = [firstSource respondsToSelector:inPtSel]
                    ? ((id (*)(id, SEL))objc_msgSend)(firstSource, inPtSel) : nil;
                FCPBridge_log(@"[BatchExport] Original inPoint: %@ (class: %@)",
                    origIn, origIn ? NSStringFromClass([origIn class]) : @"nil");

                // Try creating time objects from our CMTime values
                // PCTimeObject or similar wraps CMTime
                Class timeObjClass = objc_getClass("PCTimeObject");
                if (timeObjClass) {
                    SEL initWithTimeSel = NSSelectorFromString(@"timeObjectWithCMTime:");
                    if ([(id)timeObjClass respondsToSelector:initWithTimeSel]) {
                        id startObj = ((id (*)(id, SEL, FCPBridge_CMTime))objc_msgSend)(
                            (id)timeObjClass, initWithTimeSel, sBatchExportClipStart);
                        id endObj = ((id (*)(id, SEL, FCPBridge_CMTime))objc_msgSend)(
                            (id)timeObjClass, initWithTimeSel, sBatchExportClipEnd);
                        if (startObj && endObj) {
                            ((void (*)(id, SEL, id, id))objc_msgSend)(sourceToUse, setInOutSel, startObj, endObj);
                            FCPBridge_log(@"[BatchExport] Set in/out: %@ - %@", startObj, endObj);
                        }
                    }
                }
            }
        }

        // Create the panel silently (no runModal)
        id panel = nil;
        void *rawError = NULL;

        if (isConsumer) {
            SEL createSel = NSSelectorFromString(@"sharePanelWithSource:destination:error:");
            panel = ((id (*)(id, SEL, id, id, void **))objc_msgSend)(
                (id)panelClass, createSel, sourceToUse, dest, &rawError);
        } else {
            NSArray *modSources = @[sourceToUse];
            SEL createSel = NSSelectorFromString(@"sharePanelWithSources:destination:error:");
            panel = ((id (*)(id, SEL, id, id, void **))objc_msgSend)(
                (id)panelClass, createSel, modSources, dest, &rawError);
        }

        if (!panel) {
            id panelError = rawError ? (__bridge id)rawError : nil;
            FCPBridge_log(@"[BatchExport] Panel creation failed: %@",
                panelError ? ((id (*)(id, SEL))objc_msgSend)(panelError, @selector(localizedDescription)) : @"nil");
            return;
        }

        // Set destination URL to our batch export folder
        NSURL *outputFolderURL = sBatchExportFolderURL ?: (NSURL *)destURL;
        SEL setURLSel = NSSelectorFromString(@"setDestinationURL:");
        if ([panel respondsToSelector:setURLSel]) {
            ((void (*)(id, SEL, id))objc_msgSend)(panel, setURLSel, outputFolderURL);
        }

        // Set delegate (the exporter itself, needed for queuing)
        SEL setDelegateSel = NSSelectorFromString(@"setDelegate:");
        if ([panel respondsToSelector:setDelegateSel]) {
            ((void (*)(id, SEL, id))objc_msgSend)(panel, setDelegateSel, self);
        }

        // Get batches (created during panel init)
        NSArray *batches = ((id (*)(id, SEL))objc_msgSend)(panel, NSSelectorFromString(@"batches"));
        FCPBridge_log(@"[BatchExport] Panel created %lu batches", (unsigned long)(batches ? batches.count : 0));

        if (!batches || batches.count == 0) {
            FCPBridge_log(@"[BatchExport] No batches from panel");
            return;
        }

        // Set per-clip filename on targets if provided
        if (sBatchExportFileName && sBatchExportFolderURL) {
            NSURL *fileURL = [sBatchExportFolderURL URLByAppendingPathComponent:sBatchExportFileName];
            for (id batch in batches) {
                id jobs = ((id (*)(id, SEL))objc_msgSend)(batch, NSSelectorFromString(@"jobs"));
                if (!jobs || ![jobs isKindOfClass:[NSArray class]]) continue;
                for (id job in jobs) {
                    id targets = ((id (*)(id, SEL))objc_msgSend)(job, NSSelectorFromString(@"targets"));
                    if (!targets || ![targets isKindOfClass:[NSArray class]]) continue;
                    for (id target in targets) {
                        if ([target respondsToSelector:NSSelectorFromString(@"setDestinationURL:")]) {
                            ((void (*)(id, SEL, id))objc_msgSend)(target,
                                NSSelectorFromString(@"setDestinationURL:"), fileURL);
                        }
                    }
                }
            }
        }

        // Queue the export operations directly (no dialog!)
        SEL queueSel = NSSelectorFromString(@"queueShareOperationsForBatches:addToTheater:");
        if ([self respondsToSelector:queueSel]) {
            FCPBridge_log(@"[BatchExport] Queuing batches on %@", NSStringFromClass([self class]));
            ((void (*)(id, SEL, id, BOOL))objc_msgSend)(self, queueSel, batches, NO);
            FCPBridge_log(@"[BatchExport] Queued successfully!");
        } else {
            FCPBridge_log(@"[BatchExport] Exporter doesn't respond to queueShareOperationsForBatches:");
        }
    } @catch (NSException *e) {
        FCPBridge_log(@"[BatchExport] Exception in swizzled showSharePanel: %@", e.reason);
    }
}

// Unused - kept for reference
static NSString *FCPBridge_queueClipExport(id timeline, FCPBridge_CMTime startTime, FCPBridge_CMTime endTime,
                                            NSURL *fileURL, id dest) {
    // Set range for this clip
    FCPBridge_seekAndMark(timeline, startTime, @"setRangeStart:");
    FCPBridge_seekAndMark(timeline, endTime, @"setRangeEnd:");

    // Get sources for this range via shareSelection:
    SEL selSel = NSSelectorFromString(@"shareSelection:");
    if (![timeline respondsToSelector:selSel]) return @"no shareSelection: method";

    void *rawSources = ((void * (*)(id, SEL, id))objc_msgSend)(timeline, selSel, nil);
    if (!rawSources) return @"no sources for range";

    id sources = (__bridge id)rawSources;
    FCPBridge_log(@"[BatchExport] shareSelection: returned %@ (class: %@)", sources, NSStringFromClass([sources class]));

    if (![sources isKindOfClass:[NSArray class]]) {
        return [NSString stringWithFormat:@"sources not array, got %@", NSStringFromClass([sources class])];
    }
    NSUInteger sourceCount = [(NSArray *)sources count];
    if (sourceCount == 0) return @"empty sources";
    FCPBridge_log(@"[BatchExport] Got %lu sources", (unsigned long)sourceCount);

    // Create share panel silently to build CK batch objects
    Class panelClass = objc_getClass("FFConsumerSharePanel")
        ?: objc_getClass("FFSharePanel")
        ?: objc_getClass("FFBaseSharePanel");
    if (!panelClass) return @"no share panel class";
    FCPBridge_log(@"[BatchExport] Using panel class: %@", NSStringFromClass(panelClass));

    SEL createSel = NSSelectorFromString(@"sharePanelWithSource:destination:error:");
    if (![(id)panelClass respondsToSelector:createSel]) return @"panel class has no create method";

    id firstSource = [(NSArray *)sources firstObject];
    FCPBridge_log(@"[BatchExport] First source: %@ (class: %@)", firstSource, NSStringFromClass([firstSource class]));

    __unsafe_unretained id panelError = nil;
    void *rawPanel = ((void * (*)(id, SEL, id, id, __unsafe_unretained id *))objc_msgSend)(
        (id)panelClass, createSel, firstSource, dest, &panelError);
    if (!rawPanel) {
        NSString *errStr = panelError
            ? [NSString stringWithFormat:@"panel: %@",
               ((id (*)(id, SEL))objc_msgSend)(panelError, @selector(localizedDescription))]
            : @"panel creation returned nil";
        FCPBridge_log(@"[BatchExport] %@", errStr);
        return errStr;
    }
    id panel = (__bridge id)rawPanel;
    FCPBridge_log(@"[BatchExport] Panel created: %@", NSStringFromClass([panel class]));

    // Set destination URL
    SEL setURLSel = NSSelectorFromString(@"setDestinationURL:");
    if ([panel respondsToSelector:setURLSel]) {
        ((void (*)(id, SEL, id))objc_msgSend)(panel, setURLSel, [fileURL URLByDeletingLastPathComponent]);
    }

    // Extract batches
    SEL batchesSel = NSSelectorFromString(@"batches");
    if (![panel respondsToSelector:batchesSel]) return @"panel has no batches method";
    NSArray *batches = ((id (*)(id, SEL))objc_msgSend)(panel, batchesSel);
    if (!batches || ![batches isKindOfClass:[NSArray class]]) {
        FCPBridge_log(@"[BatchExport] batches returned: %@ (class: %@)", batches, batches ? NSStringFromClass([batches class]) : @"nil");
        return @"no batches";
    }
    FCPBridge_log(@"[BatchExport] Got %lu batches", (unsigned long)batches.count);
    if (batches.count == 0) return @"zero batches";

    // Log batch structure
    for (NSUInteger bi = 0; bi < batches.count; bi++) {
        id batch = batches[bi];
        FCPBridge_log(@"[BatchExport] Batch %lu: %@ (class: %@)", (unsigned long)bi, batch, NSStringFromClass([batch class]));
        SEL jobsSel = NSSelectorFromString(@"jobs");
        if ([batch respondsToSelector:jobsSel]) {
            NSArray *jobs = ((id (*)(id, SEL))objc_msgSend)(batch, jobsSel);
            FCPBridge_log(@"[BatchExport]   Jobs: %lu", (unsigned long)(jobs ? [(NSArray *)jobs count] : 0));
            if (jobs && [jobs isKindOfClass:[NSArray class]]) {
                for (id job in jobs) {
                    SEL targetsSel = NSSelectorFromString(@"targets");
                    if ([job respondsToSelector:targetsSel]) {
                        NSArray *targets = ((id (*)(id, SEL))objc_msgSend)(job, targetsSel);
                        FCPBridge_log(@"[BatchExport]     Targets: %lu", (unsigned long)(targets ? [(NSArray *)targets count] : 0));
                        if (targets && [targets isKindOfClass:[NSArray class]]) {
                            for (id target in targets) {
                                // Set destination URL on target
                                SEL setDestSel = NSSelectorFromString(@"setDestinationURL:");
                                if ([target respondsToSelector:setDestSel]) {
                                    ((void (*)(id, SEL, id))objc_msgSend)(target, setDestSel, fileURL);
                                    FCPBridge_log(@"[BatchExport]     Set target URL: %@", fileURL);
                                }
                                // Log output URLs
                                SEL outSel = NSSelectorFromString(@"outputURLs");
                                if ([target respondsToSelector:outSel]) {
                                    id urls = ((id (*)(id, SEL))objc_msgSend)(target, outSel);
                                    FCPBridge_log(@"[BatchExport]     Output URLs: %@", urls);
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // Create exporter and queue
    Class exporterClass = objc_getClass("FFSequenceExporter");
    SEL expSel = NSSelectorFromString(@"sequenceExporterWithSelection:useTimelinePlayback:");
    if (!exporterClass || ![(id)exporterClass respondsToSelector:expSel]) return @"no exporter class";

    void *rawExporter = ((void * (*)(id, SEL, id, id))objc_msgSend)(
        (id)exporterClass, expSel, sources, nil);
    if (!rawExporter) return @"exporter creation failed";
    id exporter = (__bridge id)rawExporter;
    FCPBridge_log(@"[BatchExport] Exporter: %@", NSStringFromClass([exporter class]));

    SEL queueSel = NSSelectorFromString(@"queueShareOperationsForBatches:addToTheater:");
    if (![exporter respondsToSelector:queueSel]) return @"exporter has no queue method";

    FCPBridge_log(@"[BatchExport] Queuing %lu batches...", (unsigned long)batches.count);
    ((void (*)(id, SEL, id, BOOL))objc_msgSend)(exporter, queueSel, batches, NO);
    FCPBridge_log(@"[BatchExport] Queued successfully");
    return @"queued";
}

NSDictionary *FCPBridge_handleBatchExport(NSDictionary *params) {
    NSString *scope = params[@"scope"] ?: @"all";
    NSString *folderPath = params[@"folder"];

    __block NSDictionary *result = nil;
    FCPBridge_executeOnMainThread(^{
        @try {
            id timeline = FCPBridge_getActiveTimelineModule();
            if (!timeline) { result = @{@"error": @"No active timeline module"}; return; }

            id sequence = ((id (*)(id, SEL))objc_msgSend)(timeline, @selector(sequence));
            if (!sequence) { result = @{@"error": @"No sequence in timeline"}; return; }

            id primaryObj = [sequence respondsToSelector:@selector(primaryObject)]
                ? ((id (*)(id, SEL))objc_msgSend)(sequence, @selector(primaryObject)) : nil;
            if (!primaryObj) { result = @{@"error": @"Cannot access primary storyline"}; return; }

            // Show folder picker
            NSURL *folderURL = nil;
            if (folderPath) {
                folderURL = [NSURL fileURLWithPath:folderPath];
            } else {
                NSOpenPanel *openPanel = [NSOpenPanel openPanel];
                openPanel.canChooseFiles = NO;
                openPanel.canChooseDirectories = YES;
                openPanel.canCreateDirectories = YES;
                openPanel.prompt = @"Export Here";
                openPanel.message = @"Choose destination folder for batch export";
                NSModalResponse resp = [openPanel runModal];
                if (resp != NSModalResponseOK) { result = @{@"status": @"cancelled"}; return; }
                folderURL = openPanel.URL;
            }
            if (!folderURL) { result = @{@"error": @"No folder selected"}; return; }
            [[NSFileManager defaultManager] createDirectoryAtURL:folderURL
                                     withIntermediateDirectories:YES attributes:nil error:nil];

            // Get selected set if needed
            NSSet *selectedSet = nil;
            if ([scope isEqualToString:@"selected"]) {
                SEL selSel = NSSelectorFromString(@"selectedItems:includeItemBeforePlayheadIfLast:");
                if ([timeline respondsToSelector:selSel]) {
                    id sel = ((id (*)(id, SEL, BOOL, BOOL))objc_msgSend)(timeline, selSel, NO, NO);
                    if ([sel isKindOfClass:[NSArray class]]) selectedSet = [NSSet setWithArray:sel];
                }
                if (!selectedSet || selectedSet.count == 0) {
                    result = @{@"error": @"No clips selected"}; return;
                }
            }

            // Get default share destination
            Class destClass = objc_getClass("FFShareDestination");
            id dest = destClass ? ((id (*)(id, SEL))objc_msgSend)((id)destClass,
                NSSelectorFromString(@"defaultUserDestination")) : nil;
            if (!dest) { result = @{@"error": @"No default share destination. Configure in File > Share > Add Destination."}; return; }

            // Collect clips
            NSArray *clips = FCPBridge_collectExportableClips(primaryObj, selectedSet);
            if (!clips || clips.count == 0) { result = @{@"error": @"No exportable clips"}; return; }

            // Install swizzle on FFSequenceExporter to bypass share dialog
            Class exporterClass = objc_getClass("FFSequenceExporter");
            SEL showPanelSel = NSSelectorFromString(@"showSharePanelWithSources:destination:destinationURL:parentWindow:");
            Method origMethod = exporterClass ? class_getInstanceMethod(exporterClass, showPanelSel) : NULL;

            if (!origMethod) {
                result = @{@"error": @"Cannot find showSharePanelWithSources: method on FFSequenceExporter"};
                return;
            }

            // Save original and install swizzle
            sOrigShowSharePanel = method_getImplementation(origMethod);
            method_setImplementation(origMethod, (IMP)FCPBridge_swizzled_showSharePanel);
            sBatchExportActive = YES;
            sBatchExportFolderURL = folderURL;
            sBatchExportPendingCount = clips.count;

            // Swizzle NSWorkspace methods to suppress auto-open of exported files
            Class wsClass = [NSWorkspace class];
            Method m;
            m = class_getInstanceMethod(wsClass, @selector(openURL:));
            if (m && !sOrigOpenURL) { sOrigOpenURL = method_getImplementation(m); method_setImplementation(m, (IMP)FCPBridge_swizzled_openURL); }

            m = class_getInstanceMethod(wsClass, @selector(activateFileViewerSelectingURLs:));
            if (m && !sOrigRevealURLs) { sOrigRevealURLs = method_getImplementation(m); method_setImplementation(m, (IMP)FCPBridge_swizzled_revealURLs); }

            m = class_getInstanceMethod(wsClass, NSSelectorFromString(@"openURL:configuration:completionHandler:"));
            if (m && !sOrigOpenURLConfig) { sOrigOpenURLConfig = method_getImplementation(m); method_setImplementation(m, (IMP)FCPBridge_swizzled_openURLConfig); }

            m = class_getInstanceMethod(wsClass, NSSelectorFromString(@"openURLs:withApplicationAtURL:configuration:completionHandler:"));
            if (m && !sOrigOpenURLs) { sOrigOpenURLs = method_getImplementation(m); method_setImplementation(m, (IMP)FCPBridge_swizzled_openURLs); }

            m = class_getInstanceMethod(wsClass, @selector(openFile:));
            if (m && !sOrigOpenFile) { sOrigOpenFile = method_getImplementation(m); method_setImplementation(m, (IMP)FCPBridge_swizzled_openFile); }

            // Set destination action to "Save only" (no auto-open)
            SEL actionSel = NSSelectorFromString(@"action");
            SEL setActionSel = NSSelectorFromString(@"setAction:");
            id origAction = nil;
            if ([dest respondsToSelector:actionSel]) {
                origAction = ((id (*)(id, SEL))objc_msgSend)(dest, actionSel);
            }
            if ([dest respondsToSelector:setActionSel]) {
                ((void (*)(id, SEL, id))objc_msgSend)(dest, setActionSel, nil); // nil = save only
            }

            // Get share helper
            id shareHelper = ((id (*)(id, SEL))objc_msgSend)(timeline, NSSelectorFromString(@"shareHelper"));
            SEL shareSel = NSSelectorFromString(@"_shareToDestination:isDefault:");

            NSMutableArray *exportResults = [NSMutableArray array];
            NSInteger exported = 0;

            for (NSUInteger i = 0; i < clips.count; i++) {
                NSDictionary *clipInfo = clips[i];
                FCPBridge_CMTime startCMTime, endCMTime;
                [clipInfo[@"startCMTime"] getValue:&startCMTime];
                [clipInfo[@"endCMTime"] getValue:&endCMTime];

                NSString *clipName = clipInfo[@"name"];
                NSString *safeName = [[clipName stringByReplacingOccurrencesOfString:@"/" withString:@"-"]
                                      stringByReplacingOccurrencesOfString:@":" withString:@"-"];
                // Use clip name directly; append index only if duplicate
                NSString *baseName = safeName;
                NSString *candidate = baseName;
                NSUInteger dupIdx = 2;
                while ([[NSFileManager defaultManager] fileExistsAtPath:
                        [[folderURL URLByAppendingPathComponent:
                          [candidate stringByAppendingPathExtension:@"mov"]] path]]) {
                    candidate = [NSString stringWithFormat:@"%@ %lu", baseName, (unsigned long)dupIdx++];
                }
                sBatchExportFileName = candidate;

                NSString *status = @"unknown";
                @try {
                    // Store clip range for the swizzled showSharePanel
                    sBatchExportClipStart = startCMTime;
                    sBatchExportClipEnd = endCMTime;

                    // Set in/out range using simulated I/O key presses
                    FCPBridge_seekAndMark(timeline, startCMTime, @"setRangeStart:");
                    FCPBridge_seekAndMark(timeline, endCMTime, @"setRangeEnd:");

                    // Trigger the normal share flow - our swizzle intercepts the dialog
                    if (shareHelper && [shareHelper respondsToSelector:shareSel]) {
                        ((void (*)(id, SEL, id, BOOL))objc_msgSend)(shareHelper, shareSel, nil, YES);
                        status = @"queued";
                        exported++;
                    } else {
                        status = @"no share helper";
                    }
                } @catch (NSException *e) {
                    status = [NSString stringWithFormat:@"error: %@", e.reason];
                }

                // Let FCP process events between clips
                [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];

                [exportResults addObject:@{
                    @"name": clipName,
                    @"startTime": clipInfo[@"startTime"],
                    @"endTime": clipInfo[@"endTime"],
                    @"status": status,
                }];
            }

            // Restore showSharePanel swizzle
            if (origMethod && sOrigShowSharePanel) {
                method_setImplementation(origMethod, sOrigShowSharePanel);
            }
            sBatchExportActive = NO;
            sBatchExportFileName = nil;
            sBatchExportFolderURL = nil;
            sOrigShowSharePanel = NULL;

            // Restore original destination action
            if ([dest respondsToSelector:setActionSel] && origAction) {
                ((void (*)(id, SEL, id))objc_msgSend)(dest, setActionSel, origAction);
            }

            // Clear range
            id app = ((id (*)(id, SEL))objc_msgSend)(
                objc_getClass("NSApplication"), @selector(sharedApplication));
            ((BOOL (*)(id, SEL, SEL, id, id))objc_msgSend)(
                app, @selector(sendAction:to:from:),
                NSSelectorFromString(@"clearRange:"), nil, nil);

            result = @{
                @"status": @"ok",
                @"folder": [folderURL path] ?: @"",
                @"exported": @(exported),
                @"total": @(clips.count),
                @"clips": exportResults,
            };
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result ?: @{@"error": @"Failed to batch export"};
}

static NSDictionary *FCPBridge_handleTimelineGetState(NSDictionary *params) {
    __block NSDictionary *result = nil;

    FCPBridge_executeOnMainThread(^{
        @try {
            id timeline = FCPBridge_getActiveTimelineModule();
            if (!timeline) {
                result = @{@"error": @"No active timeline module"};
                return;
            }

            NSMutableDictionary *state = [NSMutableDictionary dictionary];

            // Get sequence
            SEL seqSel = @selector(sequence);
            if ([timeline respondsToSelector:seqSel]) {
                id sequence = ((id (*)(id, SEL))objc_msgSend)(timeline, seqSel);
                if (sequence) {
                    state[@"sequence"] = [sequence description];
                    state[@"sequenceClass"] = NSStringFromClass([sequence class]);

                    // Get contained items count
                    SEL ciSel = @selector(containedItems);
                    if ([sequence respondsToSelector:ciSel]) {
                        id items = ((id (*)(id, SEL))objc_msgSend)(sequence, ciSel);
                        if ([items respondsToSelector:@selector(count)]) {
                            state[@"itemCount"] = @([(NSArray *)items count]);
                        }
                        // Describe each item
                        if ([items respondsToSelector:@selector(objectEnumerator)]) {
                            NSMutableArray *itemDescs = [NSMutableArray array];
                            for (id item in (NSArray *)items) {
                                NSMutableDictionary *desc = [NSMutableDictionary dictionary];
                                desc[@"class"] = NSStringFromClass([item class]);
                                desc[@"description"] = [item description];

                                // Try to get name
                                if ([item respondsToSelector:@selector(name)]) {
                                    id name = ((id (*)(id, SEL))objc_msgSend)(item, @selector(name));
                                    if (name) desc[@"name"] = name;
                                }
                                // Try to get mediaType
                                if ([item respondsToSelector:@selector(mediaType)]) {
                                    long long mt = ((long long (*)(id, SEL))objc_msgSend)(item, @selector(mediaType));
                                    desc[@"mediaType"] = @(mt);
                                }

                                [itemDescs addObject:desc];
                            }
                            state[@"items"] = itemDescs;
                        }
                    }

                    // Get hasContainedItems
                    if ([sequence respondsToSelector:@selector(hasContainedItems)]) {
                        BOOL has = ((BOOL (*)(id, SEL))objc_msgSend)(sequence, @selector(hasContainedItems));
                        state[@"hasItems"] = @(has);
                    }
                } else {
                    state[@"sequence"] = [NSNull null];
                }
            }

            // Get playhead time (CMTime struct - value/timescale/flags/epoch)
            SEL ptSel = @selector(playheadTime);
            if ([timeline respondsToSelector:ptSel]) {
                // CMTime is {value:int64, timescale:int32, flags:uint32, epoch:int64}
                // Total 24 bytes. We need to use objc_msgSend_stret or check struct return
                typedef struct { int64_t value; int32_t timescale; uint32_t flags; int64_t epoch; } CMTime;
                CMTime t;
                // On arm64, small structs are returned in registers
                t = ((CMTime (*)(id, SEL))objc_msgSend)(timeline, ptSel);
                state[@"playheadTime"] = @{
                    @"value": @(t.value),
                    @"timescale": @(t.timescale),
                    @"seconds": (t.timescale > 0) ? @((double)t.value / t.timescale) : @(0)
                };
            }

            result = state;
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });

    return result;
}

#pragma mark - Transcript Handlers

static NSDictionary *FCPBridge_handleTranscriptOpen(NSDictionary *params) {
    NSString *fileURL = params[@"fileURL"];

    __block NSDictionary *result = nil;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        FCPTranscriptPanel *panel = [FCPTranscriptPanel sharedPanel];
        [panel showPanel];

        if (fileURL) {
            NSURL *url = [NSURL fileURLWithPath:fileURL];
            double timelineStart = [params[@"timelineStart"] doubleValue];
            double trimStart = [params[@"trimStart"] doubleValue];
            double trimDuration = [params[@"trimDuration"] doubleValue] ?: HUGE_VAL;
            [panel transcribeFromURL:url timelineStart:timelineStart trimStart:trimStart trimDuration:trimDuration];
        } else {
            [panel transcribeTimeline];
        }
    });

    // Return immediately - transcription is async
    return @{@"status": @"ok", @"message": @"Transcript panel opened. Transcription started. Use transcript.getState to check progress."};
}

static NSDictionary *FCPBridge_handleTranscriptClose(NSDictionary *params) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [[FCPTranscriptPanel sharedPanel] hidePanel];
    });
    return @{@"status": @"ok"};
}

static NSDictionary *FCPBridge_handleTranscriptGetState(NSDictionary *params) {
    // Don't dispatch to main thread - getState reads properties that are safe from any thread
    // Using main thread here would deadlock if transcription is in progress on main thread
    return [[FCPTranscriptPanel sharedPanel] getState] ?: @{@"status": @"idle"};
}

static NSDictionary *FCPBridge_handleTranscriptDeleteWords(NSDictionary *params) {
    NSUInteger startIndex = [params[@"startIndex"] unsignedIntegerValue];
    NSUInteger count = [params[@"count"] unsignedIntegerValue];
    if (count == 0) return @{@"error": @"count must be > 0"};

    __block NSDictionary *result = nil;
    FCPBridge_executeOnMainThread(^{
        result = [[FCPTranscriptPanel sharedPanel] deleteWordsFromIndex:startIndex count:count];
    });
    return result ?: @{@"error": @"Operation failed"};
}

static NSDictionary *FCPBridge_handleTranscriptMoveWords(NSDictionary *params) {
    NSUInteger startIndex = [params[@"startIndex"] unsignedIntegerValue];
    NSUInteger count = [params[@"count"] unsignedIntegerValue];
    NSUInteger destIndex = [params[@"destIndex"] unsignedIntegerValue];
    if (count == 0) return @{@"error": @"count must be > 0"};

    __block NSDictionary *result = nil;
    FCPBridge_executeOnMainThread(^{
        result = [[FCPTranscriptPanel sharedPanel] moveWordsFromIndex:startIndex count:count toIndex:destIndex];
    });
    return result ?: @{@"error": @"Operation failed"};
}

static NSDictionary *FCPBridge_handleTranscriptSearch(NSDictionary *params) {
    NSString *query = params[@"query"];
    if (!query || query.length == 0) return @{@"error": @"query is required"};

    return [[FCPTranscriptPanel sharedPanel] searchTranscript:query] ?: @{@"error": @"Search failed"};
}

static NSDictionary *FCPBridge_handleTranscriptDeleteSilences(NSDictionary *params) {
    double minDuration = [params[@"minDuration"] doubleValue]; // 0 = delete all

    __block NSDictionary *result = nil;
    result = [[FCPTranscriptPanel sharedPanel] deleteSilencesLongerThan:minDuration];
    return result ?: @{@"error": @"Operation failed"};
}

static NSDictionary *FCPBridge_handleTranscriptSetSilenceThreshold(NSDictionary *params) {
    double threshold = [params[@"threshold"] doubleValue];
    if (threshold <= 0) return @{@"error": @"threshold must be > 0"};

    [FCPTranscriptPanel sharedPanel].silenceThreshold = threshold;
    return @{@"status": @"ok", @"silenceThreshold": @(threshold)};
}

static NSDictionary *FCPBridge_handleTranscriptSetEngine(NSDictionary *params) {
    NSString *engineName = params[@"engine"];
    if (!engineName) return @{@"error": @"engine is required ('fcpNative' or 'appleSpeech')"};

    FCPTranscriptPanel *panel = [FCPTranscriptPanel sharedPanel];
    if ([engineName isEqualToString:@"fcpNative"]) {
        panel.engine = FCPTranscriptEngineFCPNative;
    } else if ([engineName isEqualToString:@"appleSpeech"]) {
        panel.engine = FCPTranscriptEngineAppleSpeech;
    } else {
        return @{@"error": @"Unknown engine. Use 'fcpNative' or 'appleSpeech'"};
    }
    return @{@"status": @"ok", @"engine": engineName};
}

static NSDictionary *FCPBridge_handleTranscriptSetSpeaker(NSDictionary *params) {
    NSString *speaker = params[@"speaker"];
    NSUInteger startIndex = [params[@"startIndex"] unsignedIntegerValue];
    NSUInteger count = [params[@"count"] unsignedIntegerValue];
    if (!speaker || speaker.length == 0) return @{@"error": @"speaker name is required"};
    if (count == 0) return @{@"error": @"count must be > 0"};

    [[FCPTranscriptPanel sharedPanel] setSpeaker:speaker forWordsFrom:startIndex count:count];
    return @{@"status": @"ok", @"speaker": speaker, @"startIndex": @(startIndex), @"count": @(count)};
}

#pragma mark - Scene Change Detection

NSDictionary *FCPBridge_handleDetectSceneChanges(NSDictionary *params) {
    // Get parameters
    double threshold = [params[@"threshold"] doubleValue] ?: 0.35;
    double sampleInterval = [params[@"sampleInterval"] doubleValue] ?: 0.1; // check every 0.1s
    NSString *action = params[@"action"] ?: @"detect"; // "detect", "markers", "blade"

    // Get media URL from timeline's first clip, or use provided URL
    __block NSURL *mediaURL = nil;
    NSString *urlStr = params[@"fileURL"];
    if (urlStr) {
        mediaURL = [NSURL fileURLWithPath:urlStr];
    } else {
        // Get from timeline
        FCPBridge_executeOnMainThread(^{
            @try {
                id timeline = FCPBridge_getActiveTimelineModule();
                if (!timeline) return;
                id sequence = ((id (*)(id, SEL))objc_msgSend)(timeline, @selector(sequence));
                if (!sequence) return;

                // Get primary object -> containedItems -> first clip -> media URL
                SEL poSel = NSSelectorFromString(@"primaryObject");
                if (![sequence respondsToSelector:poSel]) return;
                id primaryObj = ((id (*)(id, SEL))objc_msgSend)(sequence, poSel);
                if (!primaryObj) return;

                SEL ciSel = @selector(containedItems);
                if (![primaryObj respondsToSelector:ciSel]) return;
                id items = ((id (*)(id, SEL))objc_msgSend)(primaryObj, ciSel);
                if (!items) return;

                // Find the longest clip (skip tiny remnants)
                id bestItem = nil;
                double bestDur = 0;
                for (id item in (NSArray *)items) {
                    if ([item respondsToSelector:@selector(duration)]) {
                        FCPBridge_CMTime d = ((FCPBridge_CMTime (*)(id, SEL))objc_msgSend)(item, @selector(duration));
                        double dur = (d.timescale > 0) ? (double)d.value / d.timescale : 0;
                        if (dur > bestDur) { bestDur = dur; bestItem = item; }
                    }
                }
                if (bestItem) {
                    @try {
                        id mediaObj = bestItem;
                        if ([bestItem respondsToSelector:ciSel]) {
                            id innerItems = ((id (*)(id, SEL))objc_msgSend)(bestItem, ciSel);
                            if ([innerItems isKindOfClass:[NSArray class]] && [(NSArray *)innerItems count] > 0) {
                                mediaObj = [(NSArray *)innerItems objectAtIndex:0];
                            }
                        }
                        id media = [mediaObj valueForKey:@"media"];
                        if (media) {
                            id rep = [media valueForKey:@"originalMediaRep"];
                            if (rep) {
                                id url = [rep valueForKey:@"fileURL"];
                                if (url && [url isKindOfClass:[NSURL class]]) {
                                    mediaURL = url;
                                }
                            }
                        }
                    } @catch (NSException *e) {}
                }
            } @catch (NSException *e) {
                FCPBridge_log(@"Exception getting media URL: %@", e.reason);
            }
        });
    }

    if (!mediaURL) {
        return @{@"error": @"No media file found. Open a project with media on the timeline."};
    }

    FCPBridge_log(@"Scene detection starting on: %@ (threshold=%.2f, interval=%.2fs)",
                  mediaURL.path, threshold, sampleInterval);

    // Run scene detection synchronously on this thread (called from background)
    AVAsset *asset = [AVAsset assetWithURL:mediaURL];
    NSError *error = nil;
    AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:asset error:&error];
    if (error || !reader) {
        return @{@"error": [NSString stringWithFormat:@"Cannot read media: %@", error.localizedDescription]};
    }

    NSArray<AVAssetTrack *> *videoTracks = [asset tracksWithMediaType:AVMediaTypeVideo];
    if (videoTracks.count == 0) {
        return @{@"error": @"No video track in media file"};
    }

    AVAssetTrack *videoTrack = videoTracks[0];
    NSDictionary *outputSettings = @{
        (NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
    };
    AVAssetReaderTrackOutput *output = [AVAssetReaderTrackOutput
        assetReaderTrackOutputWithTrack:videoTrack outputSettings:outputSettings];
    output.alwaysCopiesSampleData = NO;
    [reader addOutput:output];

    if (![reader startReading]) {
        return @{@"error": [NSString stringWithFormat:@"Cannot start reading: %@", reader.error.localizedDescription]};
    }

    // Histogram comparison for scene detection
    double duration = CMTimeGetSeconds(asset.duration);
    double frameRate = videoTrack.nominalFrameRate;
    int framesPerSample = (int)(frameRate * sampleInterval);
    if (framesPerSample < 1) framesPerSample = 1;

    vImagePixelCount prevHistR[256] = {0}, prevHistG[256] = {0}, prevHistB[256] = {0};
    BOOL hasPrevHist = NO;
    NSMutableArray *sceneChanges = [NSMutableArray array];
    int frameIndex = 0;
    int sampledFrames = 0;

    while (reader.status == AVAssetReaderStatusReading) {
        @autoreleasepool {
            CMSampleBufferRef sampleBuffer = [output copyNextSampleBuffer];
            if (!sampleBuffer) break;

            frameIndex++;
            // Only analyze every Nth frame
            if (frameIndex % framesPerSample != 0) {
                CFRelease(sampleBuffer);
                continue;
            }
            sampledFrames++;

            CMTime pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
            double timeSec = CMTimeGetSeconds(pts);

            CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
            if (!imageBuffer) {
                CFRelease(sampleBuffer);
                continue;
            }

            CVPixelBufferLockBaseAddress(imageBuffer, kCVPixelBufferLock_ReadOnly);

            size_t width = CVPixelBufferGetWidth(imageBuffer);
            size_t height = CVPixelBufferGetHeight(imageBuffer);
            size_t bytesPerRow = CVPixelBufferGetBytesPerRow(imageBuffer);
            void *baseAddr = CVPixelBufferGetBaseAddress(imageBuffer);

            vImage_Buffer buf = { baseAddr, (vImagePixelCount)height, (vImagePixelCount)width, bytesPerRow };

            // Compute ARGB histogram (BGRA in memory, but histogram bins are still useful)
            vImagePixelCount *histPtrs[4];
            vImagePixelCount histA[256] = {0}, histR[256] = {0}, histG[256] = {0}, histB[256] = {0};
            histPtrs[0] = histB; // B channel (BGRA byte order)
            histPtrs[1] = histG;
            histPtrs[2] = histR;
            histPtrs[3] = histA;
            vImageHistogramCalculation_ARGB8888(&buf, histPtrs, kvImageNoFlags);

            if (hasPrevHist) {
                // Compare histograms: normalized absolute difference
                double totalPixels = (double)(width * height);
                double diffR = 0, diffG = 0, diffB = 0;
                for (int i = 0; i < 256; i++) {
                    diffR += fabs((double)histR[i] - (double)prevHistR[i]);
                    diffG += fabs((double)histG[i] - (double)prevHistG[i]);
                    diffB += fabs((double)histB[i] - (double)prevHistB[i]);
                }
                double normalizedDiff = (diffR + diffG + diffB) / (3.0 * totalPixels);

                if (normalizedDiff > threshold) {
                    [sceneChanges addObject:@{
                        @"time": @(timeSec),
                        @"score": @(normalizedDiff),
                    }];
                    FCPBridge_log(@"Scene change at %.2fs (score=%.3f)", timeSec, normalizedDiff);
                }
            }

            // Store current histogram as previous
            memcpy(prevHistR, histR, sizeof(prevHistR));
            memcpy(prevHistG, histG, sizeof(prevHistG));
            memcpy(prevHistB, histB, sizeof(prevHistB));
            hasPrevHist = YES;

            CVPixelBufferUnlockBaseAddress(imageBuffer, kCVPixelBufferLock_ReadOnly);
            CFRelease(sampleBuffer);
        }
    }

    [reader cancelReading];

    FCPBridge_log(@"Scene detection complete: %lu changes found in %.1fs (%d frames sampled)",
                  (unsigned long)sceneChanges.count, duration, sampledFrames);

    // If action is "markers" or "blade", apply them programmatically (no playhead movement)
    if (([action isEqualToString:@"markers"] || [action isEqualToString:@"blade"]) && sceneChanges.count > 0) {
        __block NSInteger applied = 0;
        FCPBridge_executeOnMainThread(^{
            @try {
                id timeline = FCPBridge_getActiveTimelineModule();
                if (!timeline) return;
                id sequence = ((id (*)(id, SEL))objc_msgSend)(timeline, @selector(sequence));
                if (!sequence) return;

                // Get frame duration for marker length
                FCPBridge_CMTime frameDur = {1, 30, 1, 0};
                SEL fdSel = NSSelectorFromString(@"frameDuration");
                if ([sequence respondsToSelector:fdSel]) {
                    frameDur = ((FCPBridge_CMTime (*)(id, SEL))objc_msgSend)(sequence, fdSel);
                }

                // Get the primary object and find the target clip (longest one)
                id primaryObj = ((id (*)(id, SEL))objc_msgSend)(sequence, NSSelectorFromString(@"primaryObject"));
                if (!primaryObj) return;
                id containedItems = ((id (*)(id, SEL))objc_msgSend)(primaryObj, @selector(containedItems));
                if (![containedItems isKindOfClass:[NSArray class]]) return;

                id targetClip = nil;
                double bestDur = 0;
                for (id item in (NSArray *)containedItems) {
                    if ([item respondsToSelector:@selector(duration)]) {
                        FCPBridge_CMTime d = ((FCPBridge_CMTime (*)(id, SEL))objc_msgSend)(item, @selector(duration));
                        double dur = (d.timescale > 0) ? (double)d.value / d.timescale : 0;
                        if (dur > bestDur) { bestDur = dur; targetClip = item; }
                    }
                }
                if (!targetClip) return;

                if ([action isEqualToString:@"markers"]) {
                    // Add markers programmatically via actionAddMarkerToAnchoredObject:isToDo:isChapter:withRange:error:
                    SEL addSel = NSSelectorFromString(@"actionAddMarkerToAnchoredObject:isToDo:isChapter:withRange:error:");
                    if (![sequence respondsToSelector:addSel]) {
                        FCPBridge_log(@"Scene detection: sequence does not respond to actionAddMarkerToAnchoredObject:");
                        return;
                    }

                    typedef BOOL (*AddMarkerFn)(id, SEL, id, BOOL, BOOL, FCPBridge_CMTimeRange, NSError **);
                    AddMarkerFn addMarker = (AddMarkerFn)objc_msgSend;

                    for (NSDictionary *sc in sceneChanges) {
                        double t = [sc[@"time"] doubleValue];
                        int32_t ts = 600;
                        FCPBridge_CMTime markerTime = {(int64_t)round(t * ts), ts, 1, 0};
                        FCPBridge_CMTimeRange range = {markerTime, frameDur};
                        NSError *err = nil;
                        BOOL ok = addMarker(sequence, addSel, targetClip, NO, NO, range, &err);
                        if (ok) applied++;
                        else FCPBridge_log(@"Scene marker failed at %.2fs: %@", t, err);
                    }
                } else {
                    // Blade: seek + blade (still needs playhead for blade action)
                    for (NSDictionary *sc in sceneChanges) {
                        double t = [sc[@"time"] doubleValue];
                        FCPBridge_handlePlaybackSeek(@{@"seconds": @(t)});
                        [NSThread sleepForTimeInterval:0.03];
                        FCPBridge_handleTimelineAction(@{@"action": @"blade"});
                        applied++;
                    }
                }
            } @catch (NSException *e) {
                FCPBridge_log(@"Scene action error: %@", e.reason);
            }
        });
        // Update count with actually applied
        if (applied > 0) {
            NSMutableDictionary *mutableResult = [NSMutableDictionary dictionaryWithDictionary:@{
                @"sceneChanges": sceneChanges,
                @"count": @(sceneChanges.count),
                @"applied": @(applied),
                @"duration": @(duration),
                @"threshold": @(threshold),
                @"action": action,
                @"mediaFile": mediaURL.lastPathComponent ?: @"",
            }];
            return mutableResult;
        }
    }

    return @{
        @"sceneChanges": sceneChanges,
        @"count": @(sceneChanges.count),
        @"duration": @(duration),
        @"threshold": @(threshold),
        @"action": action,
        @"mediaFile": mediaURL.lastPathComponent ?: @"",
    };
}

#pragma mark - Effects Browse & Apply Handlers

// Generalized handler that lists effects filtered by type(s)
NSDictionary *FCPBridge_handleEffectsListAvailable(NSDictionary *params) {
    NSString *filter = params[@"filter"];
    NSString *typeFilter = params[@"type"]; // "filter", "transition", "generator", "title", "audio", or nil for all

    // Map friendly type names to internal type strings
    NSDictionary *typeMap = @{
        @"filter":     @"effect.video.filter",
        @"transition": @"effect.video.transition",
        @"generator":  @"effect.video.generator",
        @"title":      @"effect.video.title",
        @"audio":      @"effect.audio.effect",
    };

    NSString *internalType = typeFilter ? typeMap[[typeFilter lowercaseString]] : nil;

    __block NSDictionary *result = nil;
    FCPBridge_executeOnMainThread(^{
        @try {
            Class ffEffect = objc_getClass("FFEffect");
            if (!ffEffect) { result = @{@"error": @"FFEffect class not found"}; return; }

            id allIDs = ((id (*)(id, SEL))objc_msgSend)((id)ffEffect, @selector(userVisibleEffectIDs));
            if (!allIDs) { result = @{@"error": @"No effect IDs returned"}; return; }

            SEL typeSel = @selector(effectTypeForEffectID:);
            SEL nameSel = @selector(displayNameForEffectID:);
            SEL catSel = @selector(categoryForEffectID:);

            NSMutableArray *effects = [NSMutableArray array];

            for (NSString *effectID in allIDs) {
                @autoreleasepool {
                    id type = ((id (*)(id, SEL, id))objc_msgSend)((id)ffEffect, typeSel, effectID);
                    if (![type isKindOfClass:[NSString class]]) continue;
                    NSString *typeStr = (NSString *)type;

                    // Filter by type if requested
                    if (internalType && ![typeStr isEqualToString:internalType]) continue;

                    // Skip transitions if no type filter (they have their own handler)
                    if (!typeFilter && [typeStr isEqualToString:@"effect.video.transition"]) continue;

                    id name = ((id (*)(id, SEL, id))objc_msgSend)((id)ffEffect, nameSel, effectID);
                    id category = ((id (*)(id, SEL, id))objc_msgSend)((id)ffEffect, catSel, effectID);

                    NSString *displayName = [name isKindOfClass:[NSString class]] ? (NSString *)name : @"Unknown";
                    NSString *catName = [category isKindOfClass:[NSString class]] ? (NSString *)category : @"";

                    // Derive friendly type name
                    NSString *friendlyType = @"filter";
                    if ([typeStr isEqualToString:@"effect.video.generator"]) friendlyType = @"generator";
                    else if ([typeStr isEqualToString:@"effect.video.title"]) friendlyType = @"title";
                    else if ([typeStr isEqualToString:@"effect.audio.effect"]) friendlyType = @"audio";
                    else if ([typeStr isEqualToString:@"effect.video.transition"]) friendlyType = @"transition";

                    // Apply name filter
                    if (filter.length > 0) {
                        NSString *lowerFilter = [filter lowercaseString];
                        BOOL matches = [[displayName lowercaseString] containsString:lowerFilter] ||
                                       [[catName lowercaseString] containsString:lowerFilter];
                        if (!matches) continue;
                    }

                    [effects addObject:@{
                        @"name": displayName,
                        @"effectID": effectID,
                        @"category": catName,
                        @"type": friendlyType,
                    }];
                }
            }

            [effects sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
                return [a[@"name"] compare:b[@"name"]];
            }];

            result = @{@"effects": effects, @"count": @(effects.count)};
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result ?: @{@"error": @"Failed to list effects"};
}

NSDictionary *FCPBridge_handleEffectsApply(NSDictionary *params) {
    NSString *effectID = params[@"effectID"];
    NSString *name = params[@"name"];

    if (!effectID && !name) {
        return @{@"error": @"effectID or name parameter required"};
    }

    __block NSDictionary *result = nil;
    __block NSString *resolvedID = effectID;

    FCPBridge_executeOnMainThread(^{
        @try {
            Class ffEffect = objc_getClass("FFEffect");
            if (!ffEffect) { result = @{@"error": @"FFEffect class not found"}; return; }

            // Resolve name -> effectID if needed
            if (!resolvedID && name) {
                id allIDs = ((id (*)(id, SEL))objc_msgSend)((id)ffEffect, @selector(userVisibleEffectIDs));
                SEL typeSel = @selector(effectTypeForEffectID:);
                SEL nameSel = @selector(displayNameForEffectID:);
                NSString *lowerName = [name lowercaseString];

                // Exact match first
                for (NSString *eid in allIDs) {
                    // Skip transitions — use transitions.apply for those
                    id type = ((id (*)(id, SEL, id))objc_msgSend)((id)ffEffect, typeSel, eid);
                    if ([type isKindOfClass:[NSString class]] &&
                        [(NSString *)type isEqualToString:@"effect.video.transition"]) continue;

                    id dn = ((id (*)(id, SEL, id))objc_msgSend)((id)ffEffect, nameSel, eid);
                    if ([dn isKindOfClass:[NSString class]] &&
                        [[(NSString *)dn lowercaseString] isEqualToString:lowerName]) {
                        resolvedID = eid;
                        break;
                    }
                }
                // Partial match fallback
                if (!resolvedID) {
                    for (NSString *eid in allIDs) {
                        id type = ((id (*)(id, SEL, id))objc_msgSend)((id)ffEffect, typeSel, eid);
                        if ([type isKindOfClass:[NSString class]] &&
                            [(NSString *)type isEqualToString:@"effect.video.transition"]) continue;

                        id dn = ((id (*)(id, SEL, id))objc_msgSend)((id)ffEffect, nameSel, eid);
                        if ([dn isKindOfClass:[NSString class]] &&
                            [[(NSString *)dn lowercaseString] containsString:lowerName]) {
                            resolvedID = eid;
                            break;
                        }
                    }
                }
                if (!resolvedID) {
                    result = @{@"error": [NSString stringWithFormat:@"No effect found matching '%@'", name]};
                    return;
                }
            }

            // Use FFAddEffectCommand to apply the effect to selected items
            Class cmdClass = objc_getClass("FFAddEffectCommand");
            Class selMgr = objc_getClass("PESelectionManager");
            if (!cmdClass || !selMgr) {
                result = @{@"error": @"FFAddEffectCommand or PESelectionManager not found"};
                return;
            }

            // Get effect class for selected items lookup
            id effectClass = ((id (*)(id, SEL, id))objc_msgSend)(
                (id)ffEffect, @selector(classForEffectID:), resolvedID);

            // Get selected items from the media browser container module
            // or fall back to timeline selection
            id app = [NSApplication sharedApplication];
            id delegate = ((id (*)(id, SEL))objc_msgSend)(app, @selector(delegate));

            // Try to get the browser module to find selected items
            SEL browserSel = NSSelectorFromString(@"mediaBrowserContainerModule");
            id browserModule = nil;
            if ([delegate respondsToSelector:browserSel]) {
                browserModule = ((id (*)(id, SEL))objc_msgSend)(delegate, browserSel);
            }

            // Get selected items appropriate for this effect
            NSArray *items = nil;
            if (browserModule) {
                SEL itemsSel = NSSelectorFromString(@"_newSelectedItemsForAddEffectOperationForEffectClass:");
                if ([browserModule respondsToSelector:itemsSel]) {
                    items = ((id (*)(id, SEL, id))objc_msgSend)(browserModule, itemsSel, effectClass);
                }
            }

            // If no items from browser, try getting selected clips from timeline
            if (!items || [(NSArray *)items count] == 0) {
                id timelineModule = FCPBridge_getActiveTimelineModule();
                if (timelineModule) {
                    SEL selItemsSel = NSSelectorFromString(@"selectedItems");
                    if ([timelineModule respondsToSelector:selItemsSel]) {
                        items = ((id (*)(id, SEL))objc_msgSend)(timelineModule, selItemsSel);
                    }
                }
            }

            if (!items || [(NSArray *)items count] == 0) {
                result = @{@"error": @"No clips selected. Select a clip first with timeline_action('selectClipAtPlayhead')"};
                return;
            }

            // Create and execute FFAddEffectCommand
            id cmd = ((id (*)(id, SEL))objc_msgSend)((id)cmdClass, @selector(alloc));
            SEL initSel = NSSelectorFromString(@"initWithEffectID:items:");
            cmd = ((id (*)(id, SEL, id, id))objc_msgSend)(cmd, initSel, resolvedID, items);

            // Set timeline context
            id mgr = ((id (*)(id, SEL))objc_msgSend)((id)selMgr, @selector(defaultSelectionManager));
            if (mgr) {
                id ctx = ((id (*)(id, SEL))objc_msgSend)(mgr, @selector(timelineContext));
                if (ctx) {
                    ((void (*)(id, SEL, id))objc_msgSend)(cmd, @selector(setContext:), ctx);
                }
            }

            BOOL success = ((BOOL (*)(id, SEL))objc_msgSend)(cmd, @selector(execute));

            id appliedName = ((id (*)(id, SEL, id))objc_msgSend)(
                (id)ffEffect, @selector(displayNameForEffectID:), resolvedID);

            if (success) {
                result = @{
                    @"status": @"ok",
                    @"effect": [appliedName isKindOfClass:[NSString class]] ? appliedName : @"Unknown",
                    @"effectID": resolvedID,
                };
            } else {
                result = @{@"error": [NSString stringWithFormat:@"Failed to apply effect '%@'",
                           [appliedName isKindOfClass:[NSString class]] ? appliedName : resolvedID]};
            }
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });

    return result ?: @{@"error": @"Failed to apply effect"};
}

#pragma mark - Title/Generator Insert (via Pasteboard)

NSDictionary *FCPBridge_handleTitleInsert(NSDictionary *params) {
    NSString *effectID = params[@"effectID"];
    NSString *name = params[@"name"];

    if (!effectID && !name) {
        return @{@"error": @"effectID or name parameter required"};
    }

    __block NSDictionary *result = nil;
    __block NSString *resolvedID = effectID;

    FCPBridge_executeOnMainThread(^{
        @try {
            Class ffEffect = objc_getClass("FFEffect");
            if (!ffEffect) { result = @{@"error": @"FFEffect class not found"}; return; }

            // Resolve name -> effectID if needed
            if (!resolvedID && name) {
                id allIDs = ((id (*)(id, SEL))objc_msgSend)((id)ffEffect, @selector(userVisibleEffectIDs));
                SEL nameSel = @selector(displayNameForEffectID:);
                NSString *lowerName = [name lowercaseString];
                for (NSString *eid in allIDs) {
                    id dn = ((id (*)(id, SEL, id))objc_msgSend)((id)ffEffect, nameSel, eid);
                    if ([dn isKindOfClass:[NSString class]] &&
                        [[(NSString *)dn lowercaseString] isEqualToString:lowerName]) {
                        resolvedID = eid;
                        break;
                    }
                }
                if (!resolvedID) {
                    for (NSString *eid in allIDs) {
                        id dn = ((id (*)(id, SEL, id))objc_msgSend)((id)ffEffect, nameSel, eid);
                        if ([dn isKindOfClass:[NSString class]] &&
                            [[(NSString *)dn lowercaseString] containsString:lowerName]) {
                            resolvedID = eid;
                            break;
                        }
                    }
                }
                if (!resolvedID) {
                    result = @{@"error": [NSString stringWithFormat:@"No title/generator found matching '%@'", name]};
                    return;
                }
            }

            // Use FCP's own pasteboard mechanism to insert titles/generators.
            // This is how addBasicTitle: works internally:
            // 1. Write effectID to FFPasteboard
            // 2. Call anchorWithPasteboard: on the timeline module
            Class ffPasteboard = objc_getClass("FFPasteboard");
            if (!ffPasteboard) {
                result = @{@"error": @"FFPasteboard class not found"};
                return;
            }

            // Create pasteboard and write effect ID
            id pb = ((id (*)(id, SEL))objc_msgSend)((id)ffPasteboard, @selector(alloc));
            pb = ((id (*)(id, SEL, id))objc_msgSend)(pb,
                NSSelectorFromString(@"initWithName:"),
                @"com.apple.nle.custompasteboard");

            id nsPb = ((id (*)(id, SEL))objc_msgSend)(pb, NSSelectorFromString(@"pasteboard"));
            ((void (*)(id, SEL))objc_msgSend)(nsPb, @selector(clearContents));

            NSArray *effectIDs = @[resolvedID];
            ((void (*)(id, SEL, id, id))objc_msgSend)(pb,
                NSSelectorFromString(@"writeEffectIDs:project:"),
                effectIDs, nil);

            // Get timeline module and insert via anchor
            id timelineModule = FCPBridge_getActiveTimelineModule();
            if (!timelineModule) {
                result = @{@"error": @"No active timeline module"};
                return;
            }

            // Check if a title is already selected (replace mode) or insert new (anchor mode)
            SEL anchorSel = NSSelectorFromString(@"anchorWithPasteboard:backtimed:trackType:");
            if ([timelineModule respondsToSelector:anchorSel]) {
                ((void (*)(id, SEL, id, BOOL, id))objc_msgSend)(
                    timelineModule, anchorSel,
                    @"com.apple.nle.custompasteboard", NO, @"all");
            } else {
                result = @{@"error": @"Timeline module does not support anchorWithPasteboard:"};
                return;
            }

            id appliedName = ((id (*)(id, SEL, id))objc_msgSend)(
                (id)ffEffect, @selector(displayNameForEffectID:), resolvedID);

            result = @{
                @"status": @"ok",
                @"title": [appliedName isKindOfClass:[NSString class]] ? appliedName : @"Unknown",
                @"effectID": resolvedID,
            };

        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });

    return result ?: @{@"error": @"Failed to insert title"};
}

#pragma mark - Subject Stabilization (Lock-On)

NSDictionary *FCPBridge_handleSubjectStabilize(NSDictionary *params) {
    // Stabilize the selected clip around a tracked subject.
    // The subject stays fixed on screen while the background moves.
    //
    // Flow:
    // 1. Get selected clip and its media URL
    // 2. Get playhead time as the reference frame (where subject is)
    // 3. Use Vision framework to detect and track the subject
    // 4. Compute inverse position deltas per frame
    // 5. Apply position keyframes on the clip's FFHeXFormEffect

    __block NSDictionary *result = nil;
    __block id selectedClip = nil;
    __block id timelineModule = nil;
    __block double playheadTime = 0;
    __block double clipStart = 0;
    __block double clipDuration = 0;
    __block double trimStart = 0;
    __block NSURL *mediaURL = nil;
    __block double frameRate = 24.0;
    __block id hexFormEffect = nil;

    // Step 1: Get selected clip info on main thread
    FCPBridge_executeOnMainThread(^{
        @try {
            timelineModule = FCPBridge_getActiveTimelineModule();
            if (!timelineModule) {
                result = @{@"error": @"No active timeline"};
                return;
            }

            // Get frame rate
            if ([timelineModule respondsToSelector:@selector(sequenceFrameDuration)]) {
                typedef struct { int64_t value; int32_t timescale; uint32_t flags; int64_t epoch; } CMTimeStruct;
                CMTimeStruct fd;
                NSMethodSignature *sig = [timelineModule methodSignatureForSelector:@selector(sequenceFrameDuration)];
                NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                [inv setTarget:timelineModule];
                [inv setSelector:@selector(sequenceFrameDuration)];
                [inv invoke];
                [inv getReturnValue:&fd];
                if (fd.timescale > 0 && fd.value > 0) {
                    frameRate = (double)fd.timescale / fd.value;
                }
            }

            // Get playhead time
            SEL currentTimeSel = NSSelectorFromString(@"currentSequenceTime");
            if ([timelineModule respondsToSelector:currentTimeSel]) {
                typedef struct { int64_t value; int32_t timescale; uint32_t flags; int64_t epoch; } CMTimeStruct;
                CMTimeStruct t;
                NSMethodSignature *sig = [timelineModule methodSignatureForSelector:currentTimeSel];
                NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                [inv setTarget:timelineModule];
                [inv setSelector:currentTimeSel];
                [inv invoke];
                [inv getReturnValue:&t];
                if (t.timescale > 0) playheadTime = (double)t.value / t.timescale;
            }

            // Get selected items
            SEL selSel = NSSelectorFromString(@"selectedItems");
            NSArray *items = nil;
            if ([timelineModule respondsToSelector:selSel]) {
                items = ((id (*)(id, SEL))objc_msgSend)(timelineModule, selSel);
            }
            if (!items || items.count == 0) {
                result = @{@"error": @"No clip selected. Select a clip first."};
                return;
            }
            selectedClip = items[0];

            // Get clip timeline start and duration
            if ([selectedClip respondsToSelector:@selector(timelineStartTime)]) {
                typedef struct { int64_t value; int32_t timescale; uint32_t flags; int64_t epoch; } CMTimeStruct;
                CMTimeStruct t;
                NSMethodSignature *sig = [selectedClip methodSignatureForSelector:@selector(timelineStartTime)];
                NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                [inv setTarget:selectedClip];
                [inv setSelector:@selector(timelineStartTime)];
                [inv invoke];
                [inv getReturnValue:&t];
                if (t.timescale > 0) clipStart = (double)t.value / t.timescale;
            }
            if ([selectedClip respondsToSelector:@selector(duration)]) {
                typedef struct { int64_t value; int32_t timescale; uint32_t flags; int64_t epoch; } CMTimeStruct;
                CMTimeStruct t;
                NSMethodSignature *sig = [selectedClip methodSignatureForSelector:@selector(duration)];
                NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                [inv setTarget:selectedClip];
                [inv setSelector:@selector(duration)];
                [inv invoke];
                [inv getReturnValue:&t];
                if (t.timescale > 0) clipDuration = (double)t.value / t.timescale;
            }

            // Get trim offset
            if ([selectedClip respondsToSelector:NSSelectorFromString(@"trimStartTime")]) {
                typedef struct { int64_t value; int32_t timescale; uint32_t flags; int64_t epoch; } CMTimeStruct;
                CMTimeStruct t;
                SEL tsSel = NSSelectorFromString(@"trimStartTime");
                NSMethodSignature *sig = [selectedClip methodSignatureForSelector:tsSel];
                NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                [inv setTarget:selectedClip];
                [inv setSelector:tsSel];
                [inv invoke];
                [inv getReturnValue:&t];
                if (t.timescale > 0) trimStart = (double)t.value / t.timescale;
            }

            // Get media URL — try multiple chains
            // The selected item may be a collection; dig into containedItems for the actual media component
            id clipForMedia = selectedClip;
            if ([selectedClip respondsToSelector:NSSelectorFromString(@"containedItems")]) {
                NSArray *contained = ((id (*)(id, SEL))objc_msgSend)(selectedClip, NSSelectorFromString(@"containedItems"));
                if ([contained isKindOfClass:[NSArray class]] && contained.count > 0) {
                    for (id item in contained) {
                        NSString *cn = NSStringFromClass([item class]);
                        if ([cn containsString:@"MediaComponent"]) {
                            clipForMedia = item;
                            break;
                        }
                    }
                }
            }
            // Chain 1: clip.media.originalMediaURL / originalMediaRep.fileURLs
            @try {
                id media = nil;
                if ([clipForMedia respondsToSelector:NSSelectorFromString(@"media")]) {
                    media = ((id (*)(id, SEL))objc_msgSend)(clipForMedia, NSSelectorFromString(@"media"));
                }
                if (media) {
                    SEL omSel = NSSelectorFromString(@"originalMediaURL");
                    if ([media respondsToSelector:omSel]) {
                        id url = ((id (*)(id, SEL))objc_msgSend)(media, omSel);
                        if ([url isKindOfClass:[NSURL class]]) mediaURL = url;
                    }
                    if (!mediaURL) {
                        SEL omrSel = NSSelectorFromString(@"originalMediaRep");
                        if ([media respondsToSelector:omrSel]) {
                            id rep = ((id (*)(id, SEL))objc_msgSend)(media, omrSel);
                            if (rep) {
                                SEL fuSel = NSSelectorFromString(@"fileURLs");
                                if ([rep respondsToSelector:fuSel]) {
                                    NSArray *urls = ((id (*)(id, SEL))objc_msgSend)(rep, fuSel);
                                    if ([urls isKindOfClass:[NSArray class]] && urls.count > 0) {
                                        id url = urls.firstObject;
                                        if ([url isKindOfClass:[NSURL class]]) mediaURL = url;
                                    }
                                }
                            }
                        }
                    }
                    if (!mediaURL) {
                        SEL crSel = NSSelectorFromString(@"currentRep");
                        if ([media respondsToSelector:crSel]) {
                            id rep = ((id (*)(id, SEL))objc_msgSend)(media, crSel);
                            if (rep) {
                                SEL fuSel = NSSelectorFromString(@"fileURLs");
                                if ([rep respondsToSelector:fuSel]) {
                                    NSArray *urls = ((id (*)(id, SEL))objc_msgSend)(rep, fuSel);
                                    if ([urls isKindOfClass:[NSArray class]] && urls.count > 0) {
                                        id url = urls.firstObject;
                                        if ([url isKindOfClass:[NSURL class]]) mediaURL = url;
                                    }
                                }
                            }
                        }
                    }
                }
            } @catch (NSException *e) {}
            // Chain 2: assetMediaReference.resolvedURL
            if (!mediaURL) {
                @try {
                    SEL amrSel = NSSelectorFromString(@"assetMediaReference");
                    if ([clipForMedia respondsToSelector:amrSel]) {
                        id ref = ((id (*)(id, SEL))objc_msgSend)(clipForMedia, amrSel);
                        if (ref && [ref respondsToSelector:NSSelectorFromString(@"resolvedURL")]) {
                            id url = ((id (*)(id, SEL))objc_msgSend)(ref, NSSelectorFromString(@"resolvedURL"));
                            if ([url isKindOfClass:[NSURL class]]) mediaURL = url;
                        }
                    }
                } @catch (NSException *e) {}
            }
            // Chain 3: KVC paths
            if (!mediaURL) {
                @try { id u = [clipForMedia valueForKeyPath:@"media.fileURL"]; if ([u isKindOfClass:[NSURL class]]) mediaURL = u; } @catch(NSException *e) {}
            }
            if (!mediaURL) {
                @try { id u = [clipForMedia valueForKeyPath:@"clipInPlace.asset.originalMediaURL"]; if ([u isKindOfClass:[NSURL class]]) mediaURL = u; } @catch(NSException *e) {}
            }
            FCPBridge_log(@"[Stabilize] Selected clip class: %@, mediaURL: %@",
                NSStringFromClass([selectedClip class]), mediaURL ? mediaURL.path : @"nil");

            // Get FFHeXFormEffect via FFCutawayEffects.transformEffectForObject:createIfAbsent:
            // This is FCP's own way to get/create the transform effect on any clip type.
            @try {
                Class cutawayEffects = objc_getClass("FFCutawayEffects");
                if (cutawayEffects) {
                    SEL tfSel = NSSelectorFromString(@"transformEffectForObject:createIfAbsent:");
                    hexFormEffect = ((id (*)(Class, SEL, id, BOOL))objc_msgSend)(
                        cutawayEffects, tfSel, selectedClip, YES);
                }
            } @catch (NSException *e) {}

            // Fallback: try representedToolObject.videoEffects chain directly
            if (!hexFormEffect) {
                @try {
                    id toolObj = selectedClip;
                    if ([selectedClip respondsToSelector:NSSelectorFromString(@"representedToolObject")]) {
                        toolObj = ((id (*)(id, SEL))objc_msgSend)(selectedClip, NSSelectorFromString(@"representedToolObject"));
                    }
                    if ([toolObj respondsToSelector:NSSelectorFromString(@"videoEffects")]) {
                        id vidEffects = ((id (*)(id, SEL))objc_msgSend)(toolObj, NSSelectorFromString(@"videoEffects"));
                        if (vidEffects) {
                            // Try intrinsicEffectWithID:createIfAbsent: with known transform ID
                            SEL ieSel = NSSelectorFromString(@"intrinsicEffectWithID:createIfAbsent:");
                            if ([vidEffects respondsToSelector:ieSel]) {
                                // The transform effect ID is "FFHeXFormEffect" or similar constant
                                for (NSString *eid in @[@"FFHeXFormEffect", @"transform", @"Transform"]) {
                                    hexFormEffect = ((id (*)(id, SEL, id, BOOL))objc_msgSend)(
                                        vidEffects, ieSel, eid, YES);
                                    if (hexFormEffect) break;
                                }
                            }
                            // Also try heXFormEffect accessor
                            if (!hexFormEffect && [vidEffects respondsToSelector:NSSelectorFromString(@"heXFormEffect")]) {
                                hexFormEffect = ((id (*)(id, SEL))objc_msgSend)(vidEffects, NSSelectorFromString(@"heXFormEffect"));
                            }
                        }
                    }
                } @catch (NSException *e) {}
            }
            FCPBridge_log(@"[Stabilize] heXFormEffect: %@ (class: %@)",
                hexFormEffect ? @"found" : @"nil",
                hexFormEffect ? NSStringFromClass([hexFormEffect class]) : @"n/a");

        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception getting clip info: %@", e.reason]};
        }
    });

    if (result) return result;

    if (!mediaURL) {
        return @{@"error": @"Could not find media file for selected clip"};
    }
    if (!hexFormEffect) {
        return @{@"error": [NSString stringWithFormat:
            @"Could not find transform effect on clip (class: %@, media: %@)",
            NSStringFromClass([selectedClip class]),
            mediaURL ? mediaURL.lastPathComponent : @"nil"]};
    }

    FCPBridge_log(@"[Stabilize] Clip: %@ (start:%.2f dur:%.2f trim:%.2f playhead:%.2f fps:%.1f)",
        mediaURL.lastPathComponent, clipStart, clipDuration, trimStart, playheadTime, frameRate);

    // Step 2: Use Vision framework to track subject
    // Load the video and get the reference frame
    AVAsset *asset = [AVAsset assetWithURL:mediaURL];
    if (!asset) {
        return @{@"error": @"Could not load media asset"};
    }

    // The playhead time in source media coordinates
    double sourceTime = trimStart + (playheadTime - clipStart);
    CMTime refTime = CMTimeMakeWithSeconds(sourceTime, 600);

    // Generate reference frame
    AVAssetImageGenerator *gen = [[AVAssetImageGenerator alloc] initWithAsset:asset];
    gen.appliesPreferredTrackTransform = YES;
    gen.requestedTimeToleranceBefore = kCMTimeZero;
    gen.requestedTimeToleranceAfter = kCMTimeZero;

    NSError *imgErr = nil;
    CGImageRef refImage = [gen copyCGImageAtTime:refTime actualTime:nil error:&imgErr];
    if (!refImage) {
        return @{@"error": [NSString stringWithFormat:@"Could not get reference frame: %@", imgErr.localizedDescription]};
    }

    size_t imgWidth = CGImageGetWidth(refImage);
    size_t imgHeight = CGImageGetHeight(refImage);

    // Use Vision to detect the subject at the reference frame
    // Default: track center region (40% of frame) if no specific subject
    CGRect initialBBox = CGRectMake(0.3, 0.3, 0.4, 0.4); // normalized, center region

    // Try to detect a person/face first
    Class vnDetectReq = NSClassFromString(@"VNDetectHumanRectanglesRequest");
    if (vnDetectReq) {
        id request = [[vnDetectReq alloc] init];
        Class vnHandler = NSClassFromString(@"VNImageRequestHandler");
        id handler = ((id (*)(id, SEL, CGImageRef, id))objc_msgSend)(
            [vnHandler alloc], NSSelectorFromString(@"initWithCGImage:options:"), refImage, @{});
        NSError *vnErr = nil;
        ((BOOL (*)(id, SEL, id, NSError **))objc_msgSend)(
            handler, NSSelectorFromString(@"performRequests:error:"), @[request], &vnErr);
        NSArray *results = ((id (*)(id, SEL))objc_msgSend)(request, @selector(results));
        if (results.count > 0) {
            id obs = results[0];
            CGRect bbox = ((CGRect (*)(id, SEL))objc_msgSend)(obs, NSSelectorFromString(@"boundingBox"));
            initialBBox = bbox;
            FCPBridge_log(@"[Stabilize] Detected human at (%.2f, %.2f, %.2f, %.2f)",
                bbox.origin.x, bbox.origin.y, bbox.size.width, bbox.size.height);
        }
    }

    CGImageRelease(refImage);

    // Step 3: Track the subject across all frames using VNTrackObjectRequest
    FCPBridge_log(@"[Stabilize] Tracking subject across %.1fs of video...", clipDuration);

    // Track center of initial bbox as reference point
    double refCenterX = initialBBox.origin.x + initialBBox.size.width / 2.0;
    double refCenterY = initialBBox.origin.y + initialBBox.size.height / 2.0;

    // Read frames and track
    AVAssetReader *reader = nil;
    @try {
        NSArray *videoTracks = [asset tracksWithMediaType:AVMediaTypeVideo];
        if (videoTracks.count == 0) {
            return @{@"error": @"No video track in media"};
        }
        AVAssetTrack *videoTrack = videoTracks[0];

        CMTime startCM = CMTimeMakeWithSeconds(trimStart, 600);
        CMTime durCM = CMTimeMakeWithSeconds(clipDuration, 600);
        CMTimeRange range = CMTimeRangeMake(startCM, durCM);

        reader = [AVAssetReader assetReaderWithAsset:asset error:nil];
        reader.timeRange = range;

        NSDictionary *outputSettings = @{
            (NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)
        };
        AVAssetReaderTrackOutput *output = [AVAssetReaderTrackOutput
            assetReaderTrackOutputWithTrack:videoTrack outputSettings:outputSettings];
        output.alwaysCopiesSampleData = NO;
        [reader addOutput:output];
        [reader startReading];

    } @catch (NSException *e) {
        return @{@"error": [NSString stringWithFormat:@"Failed to read video: %@", e.reason]};
    }

    // Collect position deltas per frame
    NSMutableArray *frameDeltas = [NSMutableArray array]; // [{time, dx, dy}]
    AVAssetReaderOutput *output = reader.outputs.firstObject;

    Class vnTrackReqClass = NSClassFromString(@"VNTrackObjectRequest");
    Class vnSeqHandler = NSClassFromString(@"VNSequenceRequestHandler");

    if (!vnTrackReqClass || !vnSeqHandler) {
        return @{@"error": @"Vision tracking not available"};
    }

    id observation = nil;
    // Create initial observation from bbox
    Class vnDetectedObj = NSClassFromString(@"VNDetectedObjectObservation");
    observation = ((id (*)(Class, SEL, CGRect))objc_msgSend)(
        vnDetectedObj, NSSelectorFromString(@"observationWithBoundingBox:"), initialBBox);

    id sequenceHandler = [[vnSeqHandler alloc] init];
    int frameCount = 0;
    int totalFrames = (int)(clipDuration * frameRate);

    CMSampleBufferRef sampleBuffer;
    while ((sampleBuffer = [output copyNextSampleBuffer]) != NULL) {
        @autoreleasepool {
            CMTime pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
            double frameTime = CMTimeGetSeconds(pts) - trimStart; // time within clip

            CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
            if (!pixelBuffer) {
                CFRelease(sampleBuffer);
                continue;
            }

            // Track the object in this frame
            id trackRequest = ((id (*)(id, SEL, id))objc_msgSend)(
                [vnTrackReqClass alloc],
                NSSelectorFromString(@"initWithDetectedObjectObservation:"), observation);
            ((void (*)(id, SEL, NSInteger))objc_msgSend)(
                trackRequest, NSSelectorFromString(@"setTrackingLevel:"), 1); // Fast

            NSError *trackErr = nil;
            ((BOOL (*)(id, SEL, id, id, NSError **))objc_msgSend)(
                sequenceHandler, NSSelectorFromString(@"performRequests:onCVPixelBuffer:error:"),
                @[trackRequest], (__bridge id)pixelBuffer, &trackErr);

            NSArray *trackResults = ((id (*)(id, SEL))objc_msgSend)(trackRequest, @selector(results));
            if (trackResults.count > 0) {
                observation = trackResults[0]; // Update observation for next frame
                CGRect bbox = ((CGRect (*)(id, SEL))objc_msgSend)(
                    observation, NSSelectorFromString(@"boundingBox"));
                double cx = bbox.origin.x + bbox.size.width / 2.0;
                double cy = bbox.origin.y + bbox.size.height / 2.0;

                // Delta from reference position (in normalized coordinates)
                double dx = cx - refCenterX;
                double dy = cy - refCenterY;

                [frameDeltas addObject:@{
                    @"time": @(frameTime),
                    @"dx": @(dx),    // normalized 0-1
                    @"dy": @(dy),
                }];
            }

            CFRelease(sampleBuffer);
            frameCount++;

            if (frameCount % 30 == 0) {
                FCPBridge_log(@"[Stabilize] Tracked frame %d/%d", frameCount, totalFrames);
            }
        }
    }

    [reader cancelReading];

    FCPBridge_log(@"[Stabilize] Tracked %d frames, got %lu position deltas",
        frameCount, (unsigned long)frameDeltas.count);

    if (frameDeltas.count == 0) {
        return @{@"error": @"No tracking data obtained"};
    }

    // Step 4: Apply inverse position keyframes
    __block NSUInteger keyframesSet = 0;

    // Step 4: Apply position keyframes through FCP's undo system
    FCPBridge_executeOnMainThread(^{
        @try {
            // Use FFUndoHandler for proper undo registration
            id toolObj = selectedClip;
            if ([selectedClip respondsToSelector:NSSelectorFromString(@"representedToolObject")]) {
                id rto = ((id (*)(id, SEL))objc_msgSend)(selectedClip, NSSelectorFromString(@"representedToolObject"));
                if (rto) toolObj = rto;
            }

            // Get project document and undo handler
            id projDoc = nil;
            @try {
                projDoc = ((id (*)(id, SEL))objc_msgSend)(toolObj, NSSelectorFromString(@"projectDocument"));
            } @catch(NSException *e) {}

            id undoHandler = nil;
            if (projDoc) {
                @try {
                    undoHandler = ((id (*)(id, SEL))objc_msgSend)(projDoc, NSSelectorFromString(@"undoHandler"));
                } @catch(NSException *e) {}
            }

            // Begin undoable operation
            if (undoHandler) {
                ((void (*)(id, SEL, id))objc_msgSend)(undoHandler,
                    NSSelectorFromString(@"undoableBegin:"), @"Subject Stabilize");
            }

            // Set position keyframes using direct objc_msgSend with CMTime by value
            // CMTime is a 32-byte struct — on ARM64 it's passed in registers
            typedef void (*SetPixelPosFn)(id, SEL, CMTime, double, double, double, unsigned int);
            SetPixelPosFn setPixelPos = (SetPixelPosFn)objc_msgSend;
            SEL setPosSel = NSSelectorFromString(@"setPixelPositionAtTime:curveX:curveY:curveZ:options:");

            if ([hexFormEffect respondsToSelector:setPosSel]) {
                // Smooth the tracking data: apply a simple moving average to reduce jitter
                // and clamp maximum displacement to 15% of frame dimensions
                double maxDisplaceX = imgWidth * 0.15;
                double maxDisplaceY = imgHeight * 0.15;
                int windowSize = 5; // frames for smoothing

                for (NSUInteger fi = 0; fi < frameDeltas.count; fi++) {
                    // Moving average smoothing
                    double avgDx = 0, avgDy = 0;
                    int count = 0;
                    for (int w = -(windowSize/2); w <= (windowSize/2); w++) {
                        NSInteger idx = (NSInteger)fi + w;
                        if (idx >= 0 && idx < (NSInteger)frameDeltas.count) {
                            avgDx += [frameDeltas[idx][@"dx"] doubleValue];
                            avgDy += [frameDeltas[idx][@"dy"] doubleValue];
                            count++;
                        }
                    }
                    avgDx /= count;
                    avgDy /= count;

                    double time = [frameDeltas[fi][@"time"] doubleValue];

                    // Convert to pixels (inverse to stabilize)
                    double pixelDX = -avgDx * imgWidth;
                    double pixelDY = avgDy * imgHeight; // Vision Y is flipped vs FCP

                    // Clamp to prevent extreme shifts
                    if (pixelDX > maxDisplaceX) pixelDX = maxDisplaceX;
                    if (pixelDX < -maxDisplaceX) pixelDX = -maxDisplaceX;
                    if (pixelDY > maxDisplaceY) pixelDY = maxDisplaceY;
                    if (pixelDY < -maxDisplaceY) pixelDY = -maxDisplaceY;

                    CMTime cmTime = CMTimeMakeWithSeconds(time, (int32_t)(frameRate * 100));

                    setPixelPos(hexFormEffect, setPosSel, cmTime, pixelDX, pixelDY, 0.0, 0);
                    keyframesSet++;
                }
            }

            // Scale up slightly (105%) to hide edge movement from stabilization
            SEL setScaleSel = NSSelectorFromString(@"setScaleAtTime:curveX:curveY:curveZ:options:");
            if ([hexFormEffect respondsToSelector:setScaleSel]) {
                typedef void (*SetScaleFn)(id, SEL, CMTime, double, double, double, unsigned int);
                SetScaleFn setScale = (SetScaleFn)objc_msgSend;
                CMTime t0 = CMTimeMakeWithSeconds(0, (int32_t)(frameRate * 100));
                setScale(hexFormEffect, setScaleSel, t0, 1.05, 1.05, 1.0, 0);
            }

            // Verify: read back position at first keyframe time to confirm it stuck
            SEL getPosSel = NSSelectorFromString(@"getPixelPositionAtTime:x:y:z:");
            if (frameDeltas.count > 0 && [hexFormEffect respondsToSelector:getPosSel]) {
                double t0 = [frameDeltas[frameDeltas.count / 2][@"time"] doubleValue];
                CMTime checkTime = CMTimeMakeWithSeconds(t0, (int32_t)(frameRate * 100));

                typedef void (*GetPosFn)(id, SEL, CMTime, double*, double*, double*);
                GetPosFn getPos = (GetPosFn)objc_msgSend;
                double rx = 9999, ry = 9999, rz = 9999;
                getPos(hexFormEffect, getPosSel, checkTime, &rx, &ry, &rz);
                FCPBridge_log(@"[Stabilize] Verify: position at t=%.2f is (%.1f, %.1f, %.1f)", t0, rx, ry, rz);
                // Store for response
                objc_setAssociatedObject(hexFormEffect, "verifyX", @(rx), OBJC_ASSOCIATION_RETAIN);
                objc_setAssociatedObject(hexFormEffect, "verifyY", @(ry), OBJC_ASSOCIATION_RETAIN);
            }

            // End undoable operation
            if (undoHandler) {
                ((void (*)(id, SEL, id, BOOL, id))objc_msgSend)(undoHandler,
                    NSSelectorFromString(@"undoableEnd:save:error:"), nil, YES, nil);
            }

        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception applying keyframes: %@", e.reason]};
        }
    });

    if (result) return result;

    FCPBridge_log(@"[Stabilize] Applied %lu position keyframes + 105%% scale",
        (unsigned long)keyframesSet);

    // Collect some debug info about the deltas
    double maxDx = 0, maxDy = 0;
    for (NSDictionary *d in frameDeltas) {
        double adx = fabs([d[@"dx"] doubleValue]);
        double ady = fabs([d[@"dy"] doubleValue]);
        if (adx > maxDx) maxDx = adx;
        if (ady > maxDy) maxDy = ady;
    }

    BOOL hasSetPos = [hexFormEffect respondsToSelector:NSSelectorFromString(@"setPixelPositionAtTime:curveX:curveY:curveZ:options:")];
    BOOL hasOffsetPos = [hexFormEffect respondsToSelector:NSSelectorFromString(@"offsetPixelPositionAtTime:deltaX:deltaY:deltaZ:options:")];
    BOOL hasGetPos = [hexFormEffect respondsToSelector:NSSelectorFromString(@"getPixelPositionAtTime:x:y:z:")];
    BOOL hasSetScale = [hexFormEffect respondsToSelector:NSSelectorFromString(@"setScaleAtTime:curveX:curveY:curveZ:options:")];

    return @{
        @"status": @"ok",
        @"framesTracked": @(frameCount),
        @"keyframesApplied": @(keyframesSet),
        @"clipDuration": @(clipDuration),
        @"referencePosition": @{
            @"x": @(refCenterX),
            @"y": @(refCenterY),
        },
        @"debug": @{
            @"effectClass": NSStringFromClass([hexFormEffect class]),
            @"maxDeltaX_normalized": @(maxDx),
            @"maxDeltaY_normalized": @(maxDy),
            @"maxDeltaX_pixels": @(maxDx * imgWidth),
            @"maxDeltaY_pixels": @(maxDy * imgHeight),
            @"imgSize": [NSString stringWithFormat:@"%zux%zu", imgWidth, imgHeight],
            @"hasSetPixelPosition": @(hasSetPos),
            @"hasOffsetPixelPosition": @(hasOffsetPos),
            @"hasGetPixelPosition": @(hasGetPos),
            @"hasSetScale": @(hasSetScale),
            @"verifyPosX": objc_getAssociatedObject(hexFormEffect, "verifyX") ?: @"n/a",
            @"verifyPosY": objc_getAssociatedObject(hexFormEffect, "verifyY") ?: @"n/a",
        },
    };
}

#pragma mark - Viewer Pinch-to-Zoom

// Injects magnifyWithEvent: into FFPlayerView so trackpad pinch gestures zoom the viewer.
// Gated by NSUserDefaults key "FCPBridgeViewerPinchZoom".

static NSString * const kFCPBridgeViewerPinchZoom = @"FCPBridgeViewerPinchZoom";
static BOOL sViewerPinchZoomInstalled = NO;

// The injected magnifyWithEvent: handler for FFPlayerView
static void FCPBridge_FFPlayerView_magnifyWithEvent(id self, SEL _cmd, NSEvent *event) {
    // Get playerVideoModule from the view
    SEL pvmSel = NSSelectorFromString(@"playerVideoModule");
    if (![self respondsToSelector:pvmSel]) return;
    id videoModule = ((id (*)(id, SEL))objc_msgSend)(self, pvmSel);
    if (!videoModule) return;

    // Read current zoom factor
    SEL zfSel = NSSelectorFromString(@"zoomFactor");
    if (![videoModule respondsToSelector:zfSel]) return;
    float currentZoom = ((float (*)(id, SEL))objc_msgSend)(videoModule, zfSel);

    // If zoom is 0 (Fit mode), read the reported zoom to get the actual scale
    if (currentZoom == 0.0f) {
        SEL reportedSel = NSSelectorFromString(@"reportedZoomFactor");
        if ([videoModule respondsToSelector:reportedSel]) {
            currentZoom = ((float (*)(id, SEL))objc_msgSend)(videoModule, reportedSel);
        }
        if (currentZoom == 0.0f) currentZoom = 1.0f;
    }

    // Compute new zoom: magnification is the pinch delta (-1 to +1 range per gesture)
    CGFloat magnification = event.magnification;
    float newZoom = currentZoom * (1.0f + (float)magnification);

    // Clamp to reasonable range (6.25% to 800%)
    if (newZoom < 0.0625f) newZoom = 0.0625f;
    if (newZoom > 8.0f) newZoom = 8.0f;

    // Apply
    SEL setSel = NSSelectorFromString(@"setZoomFactor:");
    if ([videoModule respondsToSelector:setSel]) {
        ((void (*)(id, SEL, float))objc_msgSend)(videoModule, setSel, newZoom);
    }
}

// Swizzled scrollWheel: — pans the viewer when zoomed in, falls through to original otherwise
static IMP sOrigScrollWheel = NULL;

static void FCPBridge_FFPlayerView_scrollWheel(id self, SEL _cmd, NSEvent *event) {
    // Get playerVideoModule
    SEL pvmSel = NSSelectorFromString(@"playerVideoModule");
    id videoModule = [self respondsToSelector:pvmSel]
        ? ((id (*)(id, SEL))objc_msgSend)(self, pvmSel) : nil;

    if (videoModule) {
        SEL zfSel = NSSelectorFromString(@"zoomFactor");
        float zoom = [videoModule respondsToSelector:zfSel]
            ? ((float (*)(id, SEL))objc_msgSend)(videoModule, zfSel) : 0.0f;

        // Only pan when actually zoomed in (zoomFactor > 0 means not in Fit mode)
        if (zoom > 0.0f) {
            SEL originSel = NSSelectorFromString(@"origin");
            SEL setOriginSel = NSSelectorFromString(@"setOrigin:");
            if ([videoModule respondsToSelector:originSel] &&
                [videoModule respondsToSelector:setOriginSel]) {

                CGPoint origin = ((CGPoint (*)(id, SEL))objc_msgSend)(videoModule, originSel);

                // scrollingDeltaX/Y give trackpad two-finger scroll deltas
                CGFloat dx = event.scrollingDeltaX;
                CGFloat dy = event.scrollingDeltaY;

                // If hasPreciseScrollingDeltas (trackpad), use directly;
                // otherwise (mouse wheel), scale up
                if (!event.hasPreciseScrollingDeltas) {
                    dx *= 10.0;
                    dy *= 10.0;
                }

                origin.x += dx;
                origin.y -= dy; // flip Y — scroll down should pan down (move origin up)

                ((void (*)(id, SEL, CGPoint))objc_msgSend)(videoModule, setOriginSel, origin);
                return; // consumed — don't pass to original
            }
        }
    }

    // Not zoomed in or couldn't get module — call original handler
    if (sOrigScrollWheel) {
        ((void (*)(id, SEL, NSEvent *))sOrigScrollWheel)(self, _cmd, event);
    }
}

static IMP sOrigMagnifyWithEvent = NULL;

void FCPBridge_installViewerPinchZoom(void) {
    if (sViewerPinchZoomInstalled) return;

    Class playerView = objc_getClass("FFPlayerView");
    if (!playerView) {
        FCPBridge_log(@"[ViewerZoom] FFPlayerView not found — skipping pinch-to-zoom install");
        return;
    }

    SEL magnifySel = @selector(magnifyWithEvent:);

    // class_addMethod only adds if the class itself doesn't directly implement it
    // (it won't be fooled by superclass methods like NSResponder's default)
    BOOL added = class_addMethod(playerView, magnifySel,
                                 (IMP)FCPBridge_FFPlayerView_magnifyWithEvent,
                                 "v@:@"); // void, self, _cmd, NSEvent*
    if (added) {
        FCPBridge_log(@"[ViewerZoom] Added magnifyWithEvent: to FFPlayerView — pinch-to-zoom enabled");
    } else {
        // FFPlayerView directly implements magnifyWithEvent: — swizzle it
        Method m = class_getInstanceMethod(playerView, magnifySel);
        if (m) {
            sOrigMagnifyWithEvent = method_setImplementation(m, (IMP)FCPBridge_FFPlayerView_magnifyWithEvent);
            FCPBridge_log(@"[ViewerZoom] Swizzled magnifyWithEvent: on FFPlayerView — pinch-to-zoom enabled");
        } else {
            FCPBridge_log(@"[ViewerZoom] Failed to install magnifyWithEvent: on FFPlayerView");
        }
    }

    // Swizzle scrollWheel: for two-finger panning when zoomed in
    SEL scrollSel = @selector(scrollWheel:);
    Method scrollMethod = class_getInstanceMethod(playerView, scrollSel);
    if (scrollMethod) {
        sOrigScrollWheel = method_setImplementation(scrollMethod, (IMP)FCPBridge_FFPlayerView_scrollWheel);
        FCPBridge_log(@"[ViewerZoom] Swizzled scrollWheel: on FFPlayerView — two-finger pan enabled");
    }

    sViewerPinchZoomInstalled = YES;
}

void FCPBridge_removeViewerPinchZoom(void) {
    if (!sViewerPinchZoomInstalled) return;

    Class playerView = objc_getClass("FFPlayerView");
    if (!playerView) return;

    // Restore magnifyWithEvent:
    SEL magnifySel = @selector(magnifyWithEvent:);
    Method m = class_getInstanceMethod(playerView, magnifySel);
    if (m) {
        if (sOrigMagnifyWithEvent) {
            method_setImplementation(m, sOrigMagnifyWithEvent);
            sOrigMagnifyWithEvent = NULL;
        } else {
            Class nsResponder = [NSResponder class];
            Method superMethod = class_getInstanceMethod(nsResponder, magnifySel);
            if (superMethod) {
                method_setImplementation(m, method_getImplementation(superMethod));
            }
        }
    }

    // Restore scrollWheel:
    if (sOrigScrollWheel) {
        SEL scrollSel = @selector(scrollWheel:);
        Method sm = class_getInstanceMethod(playerView, scrollSel);
        if (sm) {
            method_setImplementation(sm, sOrigScrollWheel);
        }
        sOrigScrollWheel = NULL;
    }

    sViewerPinchZoomInstalled = NO;
    FCPBridge_log(@"[ViewerZoom] Disabled pinch-to-zoom and pan on FFPlayerView");
}

void FCPBridge_setViewerPinchZoomEnabled(BOOL enabled) {
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:kFCPBridgeViewerPinchZoom];
    if (enabled) {
        FCPBridge_installViewerPinchZoom();
    } else {
        FCPBridge_removeViewerPinchZoom();
    }
}

BOOL FCPBridge_isViewerPinchZoomEnabled(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kFCPBridgeViewerPinchZoom];
}

#pragma mark - Viewer Zoom RPC Handlers

static NSDictionary *FCPBridge_handleViewerGetZoom(NSDictionary *params) {
    __block NSDictionary *result = nil;
    FCPBridge_executeOnMainThread(^{
        @try {
            id player = FCPBridge_getPlayerModule();
            if (!player) { result = @{@"error": @"No player module found"}; return; }

            SEL vmSel = NSSelectorFromString(@"videoModule");
            if (![player respondsToSelector:vmSel]) { result = @{@"error": @"No videoModule on player"}; return; }
            id videoModule = ((id (*)(id, SEL))objc_msgSend)(player, vmSel);
            if (!videoModule) { result = @{@"error": @"videoModule is nil"}; return; }

            SEL zfSel = NSSelectorFromString(@"zoomFactor");
            float zoom = ((float (*)(id, SEL))objc_msgSend)(videoModule, zfSel);

            float reportedZoom = zoom;
            SEL reportedSel = NSSelectorFromString(@"reportedZoomFactor");
            if ([videoModule respondsToSelector:reportedSel]) {
                reportedZoom = ((float (*)(id, SEL))objc_msgSend)(videoModule, reportedSel);
            }

            result = @{
                @"zoomFactor": @(zoom),
                @"reportedZoomFactor": @(reportedZoom),
                @"percentage": @(reportedZoom * 100.0f),
                @"isFitMode": @(zoom == 0.0f),
            };
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result;
}

static NSDictionary *FCPBridge_handleViewerSetZoom(NSDictionary *params) {
    NSNumber *zoomNum = params[@"zoom"];
    if (!zoomNum) return @{@"error": @"'zoom' parameter required (float: 0.0=fit, 1.0=100%, etc.)"};
    float zoom = [zoomNum floatValue];

    __block NSDictionary *result = nil;
    FCPBridge_executeOnMainThread(^{
        @try {
            id player = FCPBridge_getPlayerModule();
            if (!player) { result = @{@"error": @"No player module found"}; return; }

            SEL vmSel = NSSelectorFromString(@"videoModule");
            if (![player respondsToSelector:vmSel]) { result = @{@"error": @"No videoModule on player"}; return; }
            id videoModule = ((id (*)(id, SEL))objc_msgSend)(player, vmSel);
            if (!videoModule) { result = @{@"error": @"videoModule is nil"}; return; }

            SEL setSel = NSSelectorFromString(@"setZoomFactor:");
            if (![videoModule respondsToSelector:setSel]) { result = @{@"error": @"setZoomFactor: not available"}; return; }

            ((void (*)(id, SEL, float))objc_msgSend)(videoModule, setSel, zoom);

            result = @{
                @"status": @"ok",
                @"zoomFactor": @(zoom),
                @"percentage": zoom == 0.0f ? @"fit" : @(zoom * 100.0f),
            };
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result;
}

static NSDictionary *FCPBridge_handleOptionsGet(NSDictionary *params) {
    return @{
        @"effectDragAsAdjustmentClip": @(FCPBridge_isEffectDragAsAdjustmentClipEnabled()),
        @"viewerPinchZoom": @(FCPBridge_isViewerPinchZoomEnabled()),
        @"videoOnlyKeepsAudioDisabled": @(FCPBridge_isVideoOnlyKeepsAudioDisabledEnabled()),
    };
}

static NSDictionary *FCPBridge_handleOptionsSet(NSDictionary *params) {
    NSString *option = params[@"option"];
    if (!option) return @{@"error": @"'option' parameter required"};

    if ([option isEqualToString:@"viewerPinchZoom"]) {
        NSNumber *enabled = params[@"enabled"];
        if (!enabled) return @{@"error": @"'enabled' parameter required (true/false)"};
        FCPBridge_setViewerPinchZoomEnabled([enabled boolValue]);
        return @{@"status": @"ok", @"viewerPinchZoom": @(FCPBridge_isViewerPinchZoomEnabled())};
    } else if ([option isEqualToString:@"effectDragAsAdjustmentClip"]) {
        NSNumber *enabled = params[@"enabled"];
        if (!enabled) return @{@"error": @"'enabled' parameter required (true/false)"};
        FCPBridge_setEffectDragAsAdjustmentClipEnabled([enabled boolValue]);
        return @{@"status": @"ok",
                 @"effectDragAsAdjustmentClip": @(FCPBridge_isEffectDragAsAdjustmentClipEnabled())};
    } else if ([option isEqualToString:@"videoOnlyKeepsAudioDisabled"]) {
        NSNumber *enabled = params[@"enabled"];
        if (!enabled) return @{@"error": @"'enabled' parameter required (true/false)"};
        FCPBridge_setVideoOnlyKeepsAudioDisabledEnabled([enabled boolValue]);
        return @{@"status": @"ok",
                 @"videoOnlyKeepsAudioDisabled": @(FCPBridge_isVideoOnlyKeepsAudioDisabledEnabled())};
    }

    return @{@"error": [NSString stringWithFormat:@"Unknown option: %@", option]};
}

#pragma mark - Freeze Extend Transition Swizzle

// When FCP shows "not enough extra media" for a transition, this swizzle replaces
// the dialog with our own that includes a "Use Freeze Frames" button.
//
// We swizzle -[FFAnchoredSequence displayTransitionAvailableMediaAlertDialog:] directly
// rather than NSAlert's runModal, because FCP uses the deprecated NSAlert API with
// unpredictable return value mapping. By owning the dialog entirely, we control the
// output parameter (*a3): 1 = accept (create with overlap), 0 = cancel.

static IMP sOrigDefaultOverlapType = NULL;
static BOOL sForceOverlap = NO; // When YES, defaultTransitionOverlapType returns 2
static BOOL sFreezeExtendPendingAutoAccept = NO;
static BOOL sFreezeExtendDidApply = NO;
static BOOL sFreezeExtendInTransitionAlert = NO;
static BOOL sFreezeExtendUseFreezeFramesForCurrentAlert = NO;
static IMP sOrigNSAlertRunModal = NULL;
static IMP sOrigNSAppStopModalWithCode = NULL;
static IMP sOrigActionAddTransitions = NULL;
static IMP sOrigOperationAddTransitions = NULL;
static IMP sOrigOperationAddTransitionsAskedRetry = NULL;
static BOOL sFreezeExtendRepairInProgress = NO;
static id sFreezeExtendTargetRightClip = nil;
static double sFreezeExtendTargetClipStart = 0.0;
static double sFreezeExtendTargetClipEnd = 0.0;
static id sFreezeExtendActionSequence = nil;
static id sFreezeExtendActionSpineObjects = nil;
static BOOL sFreezeExtendActionBefore = NO;
static BOOL sFreezeExtendActionAfter = NO;
static id sFreezeExtendActionEffects = nil;
static id sFreezeExtendActionRootItem = nil;
static BOOL sFreezeExtendActionReportErrors = NO;
static id sFreezeExtendOperationSequence = nil;
static id sFreezeExtendOperationSpineObject = nil;
static id sFreezeExtendOperationObjects = nil;
static BOOL sFreezeExtendOperationBefore = NO;
static BOOL sFreezeExtendOperationAfter = NO;
static id sFreezeExtendOperationEffects = nil;
static CMTime sFreezeExtendOperationDuration = {0};
static id sFreezeExtendOperationSpareTransition = nil;
static int sFreezeExtendOperationReportErrors = 0;
static BOOL sFreezeExtendHasOperationReplay = NO;

// Swizzled -[FFAnchoredSequence defaultTransitionOverlapType]
// Original returns 1 (needs handles). We return 2 (overlap/use edge frames) when forced.
static int FCPBridge_swizzled_defaultTransitionOverlapType(id self, SEL _cmd) {
    if (sForceOverlap) {
        FCPBridge_log(@"[FreezeExtend] defaultTransitionOverlapType -> 2 (freeze-frame overlap)");
        return 2;
    }
    return ((int (*)(id, SEL))sOrigDefaultOverlapType)(self, _cmd);
}

static IMP sOrigDisplayTransitionAlert = NULL;

static BOOL FCPBridge_isTransitionAvailableMediaAlert(NSAlert *alert) {
    if (![alert isKindOfClass:[NSAlert class]]) return NO;
    NSString *message = [alert messageText] ?: @"";
    return [message isEqualToString:
        @"There is not enough extra media beyond clip edges to create the transition."];
}

static void FCPBridge_prepareTransitionAlertButtons(NSAlert *alert) {
    if (![alert isKindOfClass:[NSAlert class]]) return;

    NSArray<NSButton *> *buttons = [alert buttons];
    BOOL hasFreezeButton = NO;
    for (NSButton *button in buttons) {
        if ([[button title] isEqualToString:@"Use Freeze Frames"]) {
            hasFreezeButton = YES;
            break;
        }
    }
    if (hasFreezeButton) return;

    NSString *info = [alert informativeText] ?: @"";
    if (![info containsString:@"Use Freeze Frames"]) {
        NSString *extra = @"\n\n\"Use Freeze Frames\" keeps the edit in place by "
            @"letting Final Cut Pro create the transition with frozen edge frames instead.";
        [alert setInformativeText:[info stringByAppendingString:extra]];
    }

    if (buttons.count >= 2 && [[[buttons objectAtIndex:1] title] isEqualToString:@"Cancel"]) {
        [[buttons objectAtIndex:1] setTitle:@"Use Freeze Frames"];
        [alert addButtonWithTitle:@"Cancel"];
    } else {
        [alert addButtonWithTitle:@"Use Freeze Frames"];
    }
}

static BOOL FCPBridge_isFreezeFramesResponse(NSModalResponse response) {
    return response == NSAlertSecondButtonReturn || response == 0;
}

static BOOL FCPBridge_isCancelResponse(NSModalResponse response) {
    return response == NSAlertThirdButtonReturn || response == -1;
}

static BOOL FCPBridge_shouldForceFreezeOverlap(void) {
    return sForceOverlap || sFreezeExtendUseFreezeFramesForCurrentAlert;
}

static double FCPBridge_transitionFrameDurationSeconds(id timeline) {
    double seconds = 1.0 / 30.0;
    SEL seqSel = @selector(sequence);
    if ([timeline respondsToSelector:seqSel]) {
        id sequence = ((id (*)(id, SEL))objc_msgSend)(timeline, seqSel);
        SEL fdSel = NSSelectorFromString(@"frameDuration");
        if (sequence && [sequence respondsToSelector:fdSel]) {
            FCPBridge_CMTime fd = ((FCPBridge_CMTime (*)(id, SEL))objc_msgSend)(sequence, fdSel);
            if (fd.timescale > 0 && fd.value > 0) {
                seconds = (double)fd.value / (double)fd.timescale;
            }
        }
    }
    return MAX(seconds, 1.0 / 120.0);
}

static double FCPBridge_transitionCurrentTimeSeconds(id timeline) {
    SEL currentTimeSel = NSSelectorFromString(@"currentSequenceTime");
    if (![timeline respondsToSelector:currentTimeSel]) return 0.0;
    FCPBridge_CMTime t = ((FCPBridge_CMTime (*)(id, SEL))objc_msgSend)(timeline, currentTimeSel);
    if (t.timescale <= 0) return 0.0;
    return (double)t.value / (double)t.timescale;
}

static BOOL FCPBridge_transitionSeekToSeconds(id timeline, double seconds) {
    if (!timeline) return NO;

    int32_t timescale = 24000;
    SEL seqSel = @selector(sequence);
    if ([timeline respondsToSelector:seqSel]) {
        id sequence = ((id (*)(id, SEL))objc_msgSend)(timeline, seqSel);
        SEL fdSel = NSSelectorFromString(@"frameDuration");
        if (sequence && [sequence respondsToSelector:fdSel]) {
            FCPBridge_CMTime fd = ((FCPBridge_CMTime (*)(id, SEL))objc_msgSend)(sequence, fdSel);
            if (fd.timescale > 0) timescale = fd.timescale;
        }
    }

    SEL setSel = @selector(setPlayheadTime:);
    if (![timeline respondsToSelector:setSel]) return NO;

    FCPBridge_CMTime targetTime;
    targetTime.value = (int64_t)llround(seconds * (double)timescale);
    targetTime.timescale = timescale;
    targetTime.flags = 1;
    targetTime.epoch = 0;
    ((void (*)(id, SEL, FCPBridge_CMTime))objc_msgSend)(timeline, setSel, targetTime);
    return YES;
}

static BOOL FCPBridge_sendTimelineSimpleAction(id timeline, NSString *selectorName) {
    if (!timeline || selectorName.length == 0) return NO;
    SEL sel = NSSelectorFromString(selectorName);
    if (![timeline respondsToSelector:sel]) return NO;
    ((void (*)(id, SEL, id))objc_msgSend)(timeline, sel, nil);
    return YES;
}

static BOOL FCPBridge_transitionGetItemBounds(id item, double *outStart, double *outEnd) {
    if (!item || !outStart || !outEnd) return NO;

    SEL startSel = @selector(timelineStartTime);
    SEL durSel = @selector(duration);
    if (![item respondsToSelector:startSel] || ![item respondsToSelector:durSel]) return NO;

    FCPBridge_CMTime start = ((FCPBridge_CMTime (*)(id, SEL))objc_msgSend)(item, startSel);
    FCPBridge_CMTime duration = ((FCPBridge_CMTime (*)(id, SEL))objc_msgSend)(item, durSel);
    if (start.timescale <= 0 || duration.timescale <= 0) return NO;

    *outStart = (double)start.value / (double)start.timescale;
    *outEnd = *outStart + ((double)duration.value / (double)duration.timescale);
    return YES;
}

static BOOL FCPBridge_transitionGetItemBoundsInContext(id context, id item,
                                                       double *outStart, double *outEnd) {
    if (!item || !outStart || !outEnd) return NO;
    if (FCPBridge_transitionGetItemBounds(item, outStart, outEnd)) return YES;

    SEL rangeSel = NSSelectorFromString(@"effectiveRangeOfObject:");
    if (![context respondsToSelector:rangeSel]) return NO;

    FCPBridge_CMTimeRange range =
        ((FCPBridge_CMTimeRange (*)(id, SEL, id))objc_msgSend)(context, rangeSel, item);
    if (range.start.timescale <= 0 || range.duration.timescale <= 0) return NO;

    *outStart = (double)range.start.value / (double)range.start.timescale;
    *outEnd = *outStart + ((double)range.duration.value / (double)range.duration.timescale);
    return YES;
}

static NSArray *FCPBridge_transitionSelectedItems(id timeline) {
    if (!timeline) return nil;

    SEL richSel = NSSelectorFromString(@"selectedItems:includeItemBeforePlayheadIfLast:");
    if ([timeline respondsToSelector:richSel]) {
        id items = ((id (*)(id, SEL, BOOL, BOOL))objc_msgSend)(timeline, richSel, NO, YES);
        if ([items isKindOfClass:[NSArray class]] && [(NSArray *)items count] > 0) {
            return items;
        }
    }

    SEL selSel = NSSelectorFromString(@"selectedItems");
    if ([timeline respondsToSelector:selSel]) {
        id items = ((id (*)(id, SEL))objc_msgSend)(timeline, selSel);
        if ([items isKindOfClass:[NSArray class]] && [(NSArray *)items count] > 0) {
            return items;
        }
    }

    return nil;
}

static BOOL FCPBridge_transitionSelectItem(id timeline, id item) {
    if (!timeline || !item) return NO;

    SEL setSel = NSSelectorFromString(@"setSelectedItems:");
    if (![timeline respondsToSelector:setSel]) {
        setSel = NSSelectorFromString(@"_setSelectedItems:");
    }
    if (![timeline respondsToSelector:setSel]) return NO;

    ((void (*)(id, SEL, id))objc_msgSend)(timeline, setSel, @[item]);
    return YES;
}

static NSArray *FCPBridge_transitionRangeContexts(id timeline) {
    if (!timeline) return @[];

    NSMutableArray *contexts = [NSMutableArray array];

    SEL seqSel = @selector(sequence);
    id sequence = [timeline respondsToSelector:seqSel]
        ? ((id (*)(id, SEL))objc_msgSend)(timeline, seqSel)
        : nil;
    if (sequence) {
        SEL primarySel = @selector(primaryObject);
        if ([sequence respondsToSelector:primarySel]) {
            id primaryObj = ((id (*)(id, SEL))objc_msgSend)(sequence, primarySel);
            if (primaryObj) [contexts addObject:primaryObj];
        }
        [contexts addObject:sequence];
    }

    [contexts addObject:timeline];
    return contexts;
}

static BOOL FCPBridge_transitionGetSelectedClipBounds(id timeline, double *outStart, double *outEnd) {
    if (!timeline || !outStart || !outEnd) return NO;

    NSArray *items = FCPBridge_transitionSelectedItems(timeline);
    if (![items isKindOfClass:[NSArray class]] || items.count == 0) return NO;

    id selectedItem = [items objectAtIndex:0];
    if (FCPBridge_transitionGetItemBounds(selectedItem, outStart, outEnd)) return YES;

    for (id context in FCPBridge_transitionRangeContexts(timeline)) {
        if (FCPBridge_transitionGetItemBoundsInContext(context, selectedItem, outStart, outEnd)) {
            return YES;
        }
    }

    return NO;
}

static NSArray *FCPBridge_transitionContainedItemsForSequence(id sequence) {
    if (!sequence) return nil;

    id itemsSource = nil;
    if ([sequence respondsToSelector:@selector(primaryObject)]) {
        id primaryObj = ((id (*)(id, SEL))objc_msgSend)(sequence, @selector(primaryObject));
        if (primaryObj && [primaryObj respondsToSelector:@selector(containedItems)]) {
            itemsSource = ((id (*)(id, SEL))objc_msgSend)(primaryObj, @selector(containedItems));
        }
    }
    if (!itemsSource && [sequence respondsToSelector:@selector(containedItems)]) {
        itemsSource = ((id (*)(id, SEL))objc_msgSend)(sequence, @selector(containedItems));
    }

    return [itemsSource isKindOfClass:[NSArray class]] ? itemsSource : nil;
}

static NSArray *FCPBridge_transitionContainedItems(id timeline) {
    if (!timeline) return nil;

    SEL seqSel = @selector(sequence);
    id sequence = [timeline respondsToSelector:seqSel]
        ? ((id (*)(id, SEL))objc_msgSend)(timeline, seqSel)
        : nil;
    return FCPBridge_transitionContainedItemsForSequence(sequence);
}

static id FCPBridge_transitionFindRightClipInItems(NSArray *items, double timeSeconds, double frame) {
    if (![items isKindOfClass:[NSArray class]] || items.count == 0) return nil;
    Class transitionClass = objc_getClass("FFAnchoredTransition");
    id bestItem = nil;
    double bestStart = -DBL_MAX;
    for (id item in items) {
        if (transitionClass && [item isKindOfClass:transitionClass]) continue;

        NSString *className = NSStringFromClass([item class]) ?: @"";
        if ([className containsString:@"Gap"]) continue;

        double start = 0.0;
        double end = 0.0;
        if (!FCPBridge_transitionGetItemBounds(item, &start, &end)) continue;
        if (end < timeSeconds - (frame * 2.0)) continue;
        if (start > timeSeconds + (frame * 2.0)) continue;
        if (start > bestStart) {
            bestStart = start;
            bestItem = item;
        }
    }

    return bestItem;
}

static id FCPBridge_transitionFindRightClipNearTime(id timeline, double timeSeconds, double frame) {
    return FCPBridge_transitionFindRightClipInItems(
        FCPBridge_transitionContainedItems(timeline), timeSeconds, frame);
}

static id FCPBridge_transitionFindLeftClipInItems(NSArray *items, double timeSeconds, double frame) {
    if (![items isKindOfClass:[NSArray class]] || items.count == 0) return nil;
    Class transitionClass = objc_getClass("FFAnchoredTransition");
    id bestItem = nil;
    double bestEnd = -DBL_MAX;
    for (id item in items) {
        if (transitionClass && [item isKindOfClass:transitionClass]) continue;

        NSString *className = NSStringFromClass([item class]) ?: @"";
        if ([className containsString:@"Gap"]) continue;

        double start = 0.0;
        double end = 0.0;
        if (!FCPBridge_transitionGetItemBounds(item, &start, &end)) continue;
        if (start > timeSeconds + (frame * 2.0)) continue;
        if (end > timeSeconds + (frame * 2.0)) continue;
        if (end > bestEnd) {
            bestEnd = end;
            bestItem = item;
        }
    }

    return bestItem;
}

static id FCPBridge_transitionFindLeftClipNearTime(id timeline, double timeSeconds, double frame) {
    return FCPBridge_transitionFindLeftClipInItems(
        FCPBridge_transitionContainedItems(timeline), timeSeconds, frame);
}

static NSArray *FCPBridge_transitionCandidateItems(id objects) {
    if (!objects) return @[];
    if ([objects isKindOfClass:[NSArray class]]) return (NSArray *)objects;
    if ([objects respondsToSelector:@selector(allObjects)]) {
        id all = ((id (*)(id, SEL))objc_msgSend)(objects, @selector(allObjects));
        if ([all isKindOfClass:[NSArray class]]) return (NSArray *)all;
    }
    return @[objects];
}

static void FCPBridge_transitionCaptureTargetFromObjects(id objects, id context, NSString *source) {
    if (sFreezeExtendRepairInProgress) return;

    NSArray *items = FCPBridge_transitionCandidateItems(objects);
    if (items.count == 0) return;

    Class transitionClass = objc_getClass("FFAnchoredTransition");
    id bestItem = nil;
    double bestStart = -DBL_MAX;
    NSMutableArray<NSString *> *summaries = [NSMutableArray array];

    for (id item in items) {
        if (!item) continue;

        NSString *className = NSStringFromClass([item class]) ?: @"<unknown>";
        double start = 0.0;
        double end = 0.0;
        BOOL hasBounds = FCPBridge_transitionGetItemBoundsInContext(context, item, &start, &end);
        [summaries addObject:hasBounds
            ? [NSString stringWithFormat:@"%@ %.4f-%.4f", className, start, end]
            : className];

        if (transitionClass && [item isKindOfClass:transitionClass]) continue;
        if (!hasBounds) continue;
        if (start > bestStart) {
            bestStart = start;
            bestItem = item;
        }
    }

    FCPBridge_log(@"[FreezeExtend] %@ candidates: %@", source ?: @"transition",
        [summaries componentsJoinedByString:@", "]);

    if (!bestItem) return;

    double start = 0.0;
    double end = 0.0;
    if (!FCPBridge_transitionGetItemBoundsInContext(context, bestItem, &start, &end)) return;

    id timeline = FCPBridge_getActiveTimelineModule();
    double frame = timeline ? FCPBridge_transitionFrameDurationSeconds(timeline) : (1.0 / 60.0);
    NSArray *timelineItems = FCPBridge_transitionContainedItems(timeline);
    id rightNeighbor = FCPBridge_transitionFindRightClipInItems(timelineItems, end + (frame * 0.25), frame);
    if (rightNeighbor && rightNeighbor != bestItem) {
        double neighborStart = 0.0;
        double neighborEnd = 0.0;
        if (FCPBridge_transitionGetItemBounds(rightNeighbor, &neighborStart, &neighborEnd) &&
            fabs(neighborStart - end) <= (frame * 4.0)) {
            bestItem = rightNeighbor;
            start = neighborStart;
            end = neighborEnd;
        }
    }

    sFreezeExtendTargetRightClip = bestItem;
    sFreezeExtendTargetClipStart = start;
    sFreezeExtendTargetClipEnd = end;
    FCPBridge_log(@"[FreezeExtend] Captured target from %@ start=%.4f end=%.4f class=%@",
        source ?: @"transition",
        start,
        end,
        NSStringFromClass([bestItem class]) ?: @"<unknown>");
}

static NSUInteger FCPBridge_transitionCount(id timeline) {
    NSArray *items = FCPBridge_transitionContainedItems(timeline);
    if (![items isKindOfClass:[NSArray class]]) return 0;

    Class transitionClass = objc_getClass("FFAnchoredTransition");
    NSUInteger count = 0;
    for (id item in items) {
        if (transitionClass && [item isKindOfClass:transitionClass]) {
            count++;
        }
    }
    return count;
}

static BOOL FCPBridge_transitionExistsNearTime(id timeline, double timeSeconds, double tolerance) {
    NSArray *items = FCPBridge_transitionContainedItems(timeline);
    if (![items isKindOfClass:[NSArray class]] || items.count == 0) return NO;

    Class transitionClass = objc_getClass("FFAnchoredTransition");
    for (id item in items) {
        if (!(transitionClass && [item isKindOfClass:transitionClass])) continue;

        double start = 0.0;
        double end = 0.0;
        if (!FCPBridge_transitionGetItemBounds(item, &start, &end)) continue;
        if (start <= timeSeconds + tolerance && end >= timeSeconds - tolerance) {
            return YES;
        }
    }

    return NO;
}

static BOOL FCPBridge_failFreezeExtendRepair(NSString **outReason, NSString *reason);

static void FCPBridge_clearFreezeExtendTransientState(void) {
    sFreezeExtendPendingAutoAccept = NO;
    sFreezeExtendUseFreezeFramesForCurrentAlert = NO;
    sForceOverlap = NO;
}

static void FCPBridge_captureTransitionReplayRequest(id sequence, id spineObjects,
                                                     BOOL before, BOOL after, id effects,
                                                     id rootItem, BOOL reportErrors,
                                                     NSString *source) {
    if (sFreezeExtendRepairInProgress) return;
    if (!sequence || !spineObjects) return;

    sFreezeExtendActionSequence = sequence;
    sFreezeExtendActionSpineObjects = spineObjects;
    sFreezeExtendActionBefore = before;
    sFreezeExtendActionAfter = after;
    sFreezeExtendActionEffects = effects;
    sFreezeExtendActionRootItem = rootItem;
    sFreezeExtendActionReportErrors = reportErrors;

    FCPBridge_log([NSString stringWithFormat:
        @"[FreezeExtend] Captured transition request from %@ before=%@ after=%@ reportErrors=%@ effects=%@ root=%@",
        source ?: @"transition",
        before ? @"YES" : @"NO",
        after ? @"YES" : @"NO",
        reportErrors ? @"YES" : @"NO",
        NSStringFromClass([effects class]) ?: @"<nil>",
        NSStringFromClass([rootItem class]) ?: @"<nil>"]);
}

static void FCPBridge_captureOperationTransitionReplayRequest(
    id sequence, id spineObject, id spineObjectsToAddTransition, BOOL before, BOOL after,
    id effects, CMTime transitionDuration, id spareTransition, int reportErrors,
    NSString *source) {
    if (sFreezeExtendRepairInProgress) return;
    if (!sequence || !spineObjectsToAddTransition) return;

    sFreezeExtendOperationSequence = sequence;
    sFreezeExtendOperationSpineObject = spineObject;
    sFreezeExtendOperationObjects = spineObjectsToAddTransition;
    sFreezeExtendOperationBefore = before;
    sFreezeExtendOperationAfter = after;
    sFreezeExtendOperationEffects = effects;
    sFreezeExtendOperationDuration = transitionDuration;
    sFreezeExtendOperationSpareTransition = spareTransition;
    sFreezeExtendOperationReportErrors = reportErrors;
    sFreezeExtendHasOperationReplay = YES;

    double durationSeconds = 0.0;
    if (transitionDuration.timescale > 0) {
        durationSeconds = (double)transitionDuration.value / (double)transitionDuration.timescale;
    }

    FCPBridge_log([NSString stringWithFormat:
        @"[FreezeExtend] Captured operation replay from %@ before=%@ after=%@ reportErrors=%d duration=%.4f spare=%@",
        source ?: @"transition",
        before ? @"YES" : @"NO",
        after ? @"YES" : @"NO",
        reportErrors,
        durationSeconds,
        NSStringFromClass([spareTransition class]) ?: @"<nil>"]);
}

static void FCPBridge_clearCapturedTransitionRequest(void) {
    sFreezeExtendActionSequence = nil;
    sFreezeExtendActionSpineObjects = nil;
    sFreezeExtendActionEffects = nil;
    sFreezeExtendActionRootItem = nil;
    sFreezeExtendActionReportErrors = NO;
    sFreezeExtendActionBefore = NO;
    sFreezeExtendActionAfter = NO;
    sFreezeExtendOperationSequence = nil;
    sFreezeExtendOperationSpineObject = nil;
    sFreezeExtendOperationObjects = nil;
    sFreezeExtendOperationBefore = NO;
    sFreezeExtendOperationAfter = NO;
    sFreezeExtendOperationEffects = nil;
    sFreezeExtendOperationDuration = (CMTime){0};
    sFreezeExtendOperationSpareTransition = nil;
    sFreezeExtendOperationReportErrors = 0;
    sFreezeExtendHasOperationReplay = NO;
}

static id FCPBridge_transitionSequenceForTimeline(id timeline) {
    if (!timeline) return nil;
    SEL seqSel = @selector(sequence);
    return [timeline respondsToSelector:seqSel]
        ? ((id (*)(id, SEL))objc_msgSend)(timeline, seqSel)
        : nil;
}

static id FCPBridge_transitionWrapReplayItemLikePrototype(id prototype, id item) {
    if (!item) return nil;
    if (!prototype) return item;

    if ([prototype isKindOfClass:[NSArray class]]) {
        return @[item];
    }
    if ([prototype isKindOfClass:[NSSet class]]) {
        return [NSSet setWithObject:item];
    }
    if ([prototype isKindOfClass:[NSOrderedSet class]]) {
        return [NSOrderedSet orderedSetWithObject:item];
    }

    return item;
}

static id FCPBridge_transitionResolveLiveRightClipForReplay(id timeline) {
    if (!timeline) return nil;
    double frame = FCPBridge_transitionFrameDurationSeconds(timeline);
    if (!(sFreezeExtendTargetClipEnd > sFreezeExtendTargetClipStart)) return nil;
    return FCPBridge_transitionFindRightClipNearTime(timeline,
        sFreezeExtendTargetClipStart, frame);
}

static BOOL FCPBridge_replayCapturedTransitionRequest(id timeline, NSString **outReason) {
    if (!sOrigActionAddTransitions || !sFreezeExtendActionSequence || !sFreezeExtendActionSpineObjects) {
        return FCPBridge_failFreezeExtendRepair(outReason,
            @"missing captured transition request for replay");
    }

    id sequence = FCPBridge_transitionSequenceForTimeline(timeline) ?: sFreezeExtendActionSequence;
    id liveRightClip = FCPBridge_transitionResolveLiveRightClipForReplay(timeline);
    id spineObjects = liveRightClip
        ? FCPBridge_transitionWrapReplayItemLikePrototype(
            sFreezeExtendActionSpineObjects, liveRightClip)
        : sFreezeExtendActionSpineObjects;
    id rootItem = sFreezeExtendActionRootItem;
    if (liveRightClip && (!rootItem || [rootItem isKindOfClass:[liveRightClip class]])) {
        rootItem = liveRightClip;
    }

    SEL actionSel = NSSelectorFromString(
        @"actionAddTransitionsToSpineObjects:before:after:effects:transitionOverlapType:transitionsCreated:rootItem:reportErrors:error:");
    if (![sequence respondsToSelector:actionSel]) {
        return FCPBridge_failFreezeExtendRepair(outReason,
            @"captured sequence no longer responds to actionAddTransitionsToSpineObjects");
    }

    FCPBridge_log([NSString stringWithFormat:
        @"[FreezeExtend] Action replay using sequence=%@ spineObjects=%@ root=%@ liveRight=%@",
        NSStringFromClass([sequence class]) ?: @"<nil>",
        NSStringFromClass([spineObjects class]) ?: @"<nil>",
        NSStringFromClass([rootItem class]) ?: @"<nil>",
        NSStringFromClass([liveRightClip class]) ?: @"<nil>"]);

    id transitionsCreated = nil;
    __autoreleasing id error = nil;
    // The repair always targets the cut before the captured right-hand clip.
    // Do not mirror clip-level "both edges" requests here or FCP will build
    // transitions on both sides of the clip and recreate the original bug.
    BOOL ok = ((BOOL (*)(id, SEL, id, BOOL, BOOL, id, int, id *, id, BOOL, id *))
        sOrigActionAddTransitions)(sequence,
            actionSel,
            spineObjects,
            YES,
            NO,
            sFreezeExtendActionEffects,
            2,
            &transitionsCreated,
            rootItem,
            sFreezeExtendActionReportErrors,
            &error);

    if (!ok) {
        NSString *reason = nil;
        if ([error respondsToSelector:@selector(localizedDescription)]) {
            reason = [error localizedDescription];
        }
        if (!reason && error) {
            reason = [error description];
        }
        return FCPBridge_failFreezeExtendRepair(outReason,
            reason ?: @"captured transition replay returned failure");
    }

    return YES;
}

static BOOL FCPBridge_callCapturedOperationTransitionRequest(id sequence, SEL selector,
                                                             id spineObject, id objects,
                                                             id effects, CMTime duration,
                                                             id spareTransition,
                                                             int reportErrors,
                                                             int *askedRetry,
                                                             id *error) {
    id created = nil;
    return ((BOOL (*)(id, SEL, id, id, BOOL, BOOL, id *, id, CMTime, int, id, int, int *, id *))
        sOrigOperationAddTransitionsAskedRetry)(
            sequence,
            selector,
            spineObject,
            objects,
            sFreezeExtendOperationBefore,
            sFreezeExtendOperationAfter,
            &created,
            effects,
            duration,
            2,
            spareTransition,
            reportErrors,
            askedRetry,
            error);
}

static BOOL FCPBridge_replayCapturedOperationTransitionRequest(id timeline, NSString **outReason) {
    if (!sOrigOperationAddTransitionsAskedRetry || !sFreezeExtendHasOperationReplay ||
        !sFreezeExtendOperationSequence || !sFreezeExtendOperationObjects) {
        return FCPBridge_failFreezeExtendRepair(outReason,
            @"missing captured operation transition request for replay");
    }

    id sequence = FCPBridge_transitionSequenceForTimeline(timeline) ?: sFreezeExtendOperationSequence;
    id liveRightClip = FCPBridge_transitionResolveLiveRightClipForReplay(timeline);
    id spineObject = sFreezeExtendOperationSpineObject;
    if (liveRightClip && (!spineObject || [spineObject isKindOfClass:[liveRightClip class]])) {
        spineObject = liveRightClip;
    }
    id objects = liveRightClip
        ? FCPBridge_transitionWrapReplayItemLikePrototype(
            sFreezeExtendOperationObjects, liveRightClip)
        : sFreezeExtendOperationObjects;

    SEL opAddRetrySel = NSSelectorFromString(
        @"operationAddTransitionsToObjectsOnSpineObject:spineObjectsToAddTransition:before:after:spineTransitionClipsCreated:effects:transitionDuration:transitionOverlapType:spareTransition:reportErrors:askedRetry:error:");
    if (![sequence respondsToSelector:opAddRetrySel]) {
        return FCPBridge_failFreezeExtendRepair(outReason,
            @"captured sequence no longer responds to operationAddTransitions...askedRetry");
    }

    FCPBridge_log([NSString stringWithFormat:
        @"[FreezeExtend] Operation replay using sequence=%@ spineObject=%@ objects=%@ liveRight=%@ spare=%@",
        NSStringFromClass([sequence class]) ?: @"<nil>",
        NSStringFromClass([spineObject class]) ?: @"<nil>",
        NSStringFromClass([objects class]) ?: @"<nil>",
        NSStringFromClass([liveRightClip class]) ?: @"<nil>",
        NSStringFromClass([sFreezeExtendOperationSpareTransition class]) ?: @"<nil>"]);

    int askedRetry = 0;
    __autoreleasing id error = nil;
    BOOL ok = FCPBridge_callCapturedOperationTransitionRequest(
        sequence, opAddRetrySel, spineObject, objects, sFreezeExtendOperationEffects,
        sFreezeExtendOperationDuration, sFreezeExtendOperationSpareTransition,
        sFreezeExtendOperationReportErrors, &askedRetry, &error);
    if (!ok && sFreezeExtendOperationSpareTransition) {
        FCPBridge_log(@"[FreezeExtend] Operation replay failed with captured spareTransition; retrying with nil spareTransition");
        askedRetry = 0;
        error = nil;
        ok = FCPBridge_callCapturedOperationTransitionRequest(
            sequence, opAddRetrySel, spineObject, objects, sFreezeExtendOperationEffects,
            sFreezeExtendOperationDuration, nil,
            sFreezeExtendOperationReportErrors, &askedRetry, &error);
    }

    if (!ok) {
        NSString *reason = nil;
        if ([error respondsToSelector:@selector(localizedDescription)]) {
            reason = [error localizedDescription];
        }
        if (!reason && error) {
            reason = [error description];
        }
        if (!reason && askedRetry != 0) {
            reason = [NSString stringWithFormat:
                @"captured operation replay returned failure with askedRetry=%d", askedRetry];
        }
        return FCPBridge_failFreezeExtendRepair(outReason,
            reason ?: @"captured operation transition replay returned failure");
    }

    return YES;
}

static BOOL FCPBridge_waitForTransitionInsertion(id timeline, NSUInteger previousCount,
                                                 NSTimeInterval timeoutSeconds) {
    if (!timeline) return NO;

    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:MAX(timeoutSeconds, 0.0)];
    while ([deadline timeIntervalSinceNow] > 0.0) {
        if (FCPBridge_transitionCount(timeline) > previousCount) {
            return YES;
        }

        [[NSRunLoop currentRunLoop] runUntilDate:
            [NSDate dateWithTimeIntervalSinceNow:0.02]];
    }

    return FCPBridge_transitionCount(timeline) > previousCount;
}

static BOOL FCPBridge_waitForTransitionNearTime(id timeline, NSUInteger previousCount,
                                                double timeSeconds, double tolerance,
                                                NSTimeInterval timeoutSeconds) {
    if (!timeline) return NO;

    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:MAX(timeoutSeconds, 0.0)];
    while ([deadline timeIntervalSinceNow] > 0.0) {
        BOOL inserted = FCPBridge_transitionCount(timeline) > previousCount;
        BOOL placed = FCPBridge_transitionExistsNearTime(timeline, timeSeconds, tolerance);
        if (inserted && placed) return YES;

        [[NSRunLoop currentRunLoop] runUntilDate:
            [NSDate dateWithTimeIntervalSinceNow:0.02]];
    }

    return FCPBridge_transitionCount(timeline) > previousCount &&
        FCPBridge_transitionExistsNearTime(timeline, timeSeconds, tolerance);
}

static double FCPBridge_defaultTransitionDurationSeconds(id timeline) {
    double seconds = 1.0;
    SEL seqSel = @selector(sequence);
    if (![timeline respondsToSelector:seqSel]) return seconds;

    id sequence = ((id (*)(id, SEL))objc_msgSend)(timeline, seqSel);
    if (!sequence) return seconds;

    SEL durSel = NSSelectorFromString(@"defaultTransitionDurationForVideo");
    if (![sequence respondsToSelector:durSel]) return seconds;

    FCPBridge_CMTime duration = ((FCPBridge_CMTime (*)(id, SEL))objc_msgSend)(sequence, durSel);
    if (duration.timescale > 0 && duration.value > 0) {
        seconds = (double)duration.value / (double)duration.timescale;
    }
    return MAX(seconds, 0.1);
}

static BOOL FCPBridge_failFreezeExtendRepair(NSString **outReason, NSString *reason) {
    NSString *message = reason ?: @"unknown reason";
    if (outReason) *outReason = message;
    FCPBridge_log([NSString stringWithFormat:
        @"[FreezeExtend] Synthetic repair step failed: %@", message]);
    return NO;
}

static void FCPBridge_undoTimelineSteps(id timeline, NSUInteger steps) {
    for (NSUInteger idx = 0; idx < steps; idx++) {
        FCPBridge_sendTimelineSimpleAction(timeline, @"undo");
    }
}

static BOOL FCPBridge_attemptFreezeExtendRepairRightSide(NSString **outReason) {
    id timeline = FCPBridge_getActiveTimelineModule();
    if (!timeline) {
        return FCPBridge_failFreezeExtendRepair(outReason, @"no active timeline module");
    }

    double frame = FCPBridge_transitionFrameDurationSeconds(timeline);
    double targetStart = sFreezeExtendTargetClipStart;
    double targetEnd = sFreezeExtendTargetClipEnd;
    if (!(targetEnd > targetStart)) {
        return FCPBridge_failFreezeExtendRepair(outReason,
            @"missing captured target clip bounds");
    }

    double rightStart = 0.0;
    double rightEnd = 0.0;
    id rightClip = nil;
    BOOL hasTransition = NO;
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:0.8];
    while ([deadline timeIntervalSinceNow] > 0.0) {
        hasTransition = FCPBridge_transitionExistsNearTime(timeline, targetStart, frame * 4.0);
        rightClip = FCPBridge_transitionFindRightClipNearTime(timeline, targetStart, frame);
        if (rightClip && FCPBridge_transitionGetItemBounds(rightClip, &rightStart, &rightEnd)) {
            if (hasTransition) break;
        }
        [[NSRunLoop currentRunLoop] runUntilDate:
            [NSDate dateWithTimeIntervalSinceNow:0.02]];
    }

    // Compute a reduced transition duration that fits the shortest adjacent clip.
    // This mirrors the logic in FCPBridge_handleTransitionsApply but uses the
    // captured target bounds (which may have shifted after the first attempt).
    double targetDuration = targetEnd - targetStart;
    double defaultDur = FCPBridge_defaultTransitionDurationSeconds(timeline);
    id leftClipForDur = FCPBridge_transitionFindLeftClipNearTime(timeline, targetStart, frame);
    double leftDurForRepair = DBL_MAX;
    if (leftClipForDur) {
        double ls = 0, le = 0;
        if (FCPBridge_transitionGetItemBounds(leftClipForDur, &ls, &le))
            leftDurForRepair = le - ls;
    }
    double minClipDur = MIN(leftDurForRepair, targetDuration);
    double maxFeasible = MAX(2.0 * minClipDur, frame * 2.0);
    BOOL repairReducedDuration = NO;
    float repairOrigDurSetting = 0.0f;
    CMTime repairOrigOpDuration = sFreezeExtendOperationDuration;

    if (maxFeasible < defaultDur) {
        repairOrigDurSetting = [[NSUserDefaults standardUserDefaults]
            floatForKey:@"FFSequenceTransDefaultDuration"];
        [[NSUserDefaults standardUserDefaults]
            setFloat:(float)maxFeasible
            forKey:@"FFSequenceTransDefaultDuration"];
        repairReducedDuration = YES;
        // Also reduce the captured operation duration for direct replay
        if (sFreezeExtendHasOperationReplay && sFreezeExtendOperationDuration.timescale > 0) {
            double opDurSec = (double)sFreezeExtendOperationDuration.value /
                              (double)sFreezeExtendOperationDuration.timescale;
            if (maxFeasible < opDurSec) {
                sFreezeExtendOperationDuration = CMTimeMakeWithSeconds(
                    maxFeasible, sFreezeExtendOperationDuration.timescale);
            }
        }
        sForceOverlap = YES;
        FCPBridge_log([NSString stringWithFormat:
            @"[FreezeExtend] Repair: reduced duration from %.4f to %.4f "
            @"(left=%.4f target=%.4f minClip=%.4f)",
            defaultDur, maxFeasible, leftDurForRepair, targetDuration, minClipDur]);
    }

    if (!hasTransition) {
        NSUInteger transitionsBefore = FCPBridge_transitionCount(timeline);
        NSString *opReplayReason = nil;
        FCPBridge_log(@"[FreezeExtend] No transition after alert; replaying captured operation with forced overlap");
        BOOL opReplayed = FCPBridge_replayCapturedOperationTransitionRequest(timeline, &opReplayReason);
        if (opReplayed) {
            hasTransition = FCPBridge_waitForTransitionNearTime(
                timeline, transitionsBefore, targetStart, frame * 4.0, 0.8);
            if (hasTransition) {
                rightClip = FCPBridge_transitionFindRightClipNearTime(timeline, targetStart, frame);
                if (rightClip) {
                    FCPBridge_transitionGetItemBounds(rightClip, &rightStart, &rightEnd);
                }
            } else {
                FCPBridge_log(@"[FreezeExtend] Captured operation replay returned success but no transition appeared");
            }
        } else {
            FCPBridge_log([NSString stringWithFormat:
                @"[FreezeExtend] Captured operation replay failed: %@",
                opReplayReason ?: @"unknown reason"]);
        }
    }

    if (!hasTransition) {
        NSUInteger transitionsBefore = FCPBridge_transitionCount(timeline);
        NSString *replayReason = nil;
        FCPBridge_log(@"[FreezeExtend] No transition after alert; replaying captured request with forced overlap");
        BOOL replayed = FCPBridge_replayCapturedTransitionRequest(timeline, &replayReason);
        if (replayed) {
            hasTransition = FCPBridge_waitForTransitionNearTime(
                timeline, transitionsBefore, targetStart, frame * 4.0, 0.8);
            if (hasTransition) {
                rightClip = FCPBridge_transitionFindRightClipNearTime(timeline, targetStart, frame);
                if (rightClip) {
                    FCPBridge_transitionGetItemBounds(rightClip, &rightStart, &rightEnd);
                }
            } else {
                FCPBridge_log(@"[FreezeExtend] Captured replay returned success but no transition appeared");
            }
        } else {
            FCPBridge_log([NSString stringWithFormat:
                @"[FreezeExtend] Captured replay failed: %@",
                replayReason ?: @"unknown reason"]);
        }
    }

    if (!hasTransition) {
        FCPBridge_log(@"[FreezeExtend] No transition after alert; retrying addTransition once during repair");
        // `nextEdit:` advances strictly forward, so seeking to the exact cut can
        // skip past the intended edit and land on a newly created trailing split.
        double retrySeek = MAX(0.0, targetStart - (frame * 0.5));
        FCPBridge_transitionSeekToSeconds(timeline, retrySeek);
        FCPBridge_sendTimelineSimpleAction(timeline, @"nextEdit:");
        sFreezeExtendPendingAutoAccept = YES;
        SEL addSel = @selector(addTransition:);
        if ([timeline respondsToSelector:addSel]) {
            ((void (*)(id, SEL, id))objc_msgSend)(timeline, addSel, nil);
        } else {
            [[NSApplication sharedApplication] sendAction:addSel to:nil from:nil];
        }

        deadline = [NSDate dateWithTimeIntervalSinceNow:1.0];
        while ([deadline timeIntervalSinceNow] > 0.0) {
            hasTransition = FCPBridge_transitionExistsNearTime(timeline, targetStart, frame * 4.0);
            rightClip = FCPBridge_transitionFindRightClipNearTime(timeline, targetStart, frame);
            if (rightClip && FCPBridge_transitionGetItemBounds(rightClip, &rightStart, &rightEnd)) {
                if (hasTransition) break;
            }
            [[NSRunLoop currentRunLoop] runUntilDate:
                [NSDate dateWithTimeIntervalSinceNow:0.02]];
        }
        sFreezeExtendPendingAutoAccept = NO;
    }

    // All remaining return paths go through repair_cleanup to restore the
    // reduced transition duration and captured operation state.
    BOOL repairResult = NO;
    NSString *repairFailReason = nil;

    if (!hasTransition) {
        repairFailReason = @"transition did not appear after alert or repair retry";
        goto repair_cleanup;
    }
    if (!rightClip || rightEnd <= rightStart) {
        repairFailReason = @"failed to resolve right clip after transition insertion";
        goto repair_cleanup;
    }

    if (rightEnd <= targetEnd + (frame * 4.0)) {
        FCPBridge_log([NSString stringWithFormat:
            @"[FreezeExtend] Right clip already within captured bounds start=%.4f end=%.4f targetEnd=%.4f",
            rightStart, rightEnd, targetEnd]);
        repairResult = YES;
        goto repair_cleanup;
    }

    {
        id leftClip = FCPBridge_transitionFindLeftClipNearTime(timeline, targetStart, frame);
        if (!leftClip) {
            repairFailReason = @"failed to resolve left clip for corrective trim";
            goto repair_cleanup;
        }

        double leftStart = 0.0;
        double leftEnd = 0.0;
        FCPBridge_transitionGetItemBounds(leftClip, &leftStart, &leftEnd);
        FCPBridge_log([NSString stringWithFormat:
            @"[FreezeExtend] Corrective trim left=%.4f-%.4f right=%.4f-%.4f targetCut=%.4f targetEnd=%.4f",
            leftStart, leftEnd, rightStart, rightEnd, targetStart, targetEnd]);

        if (!FCPBridge_transitionSelectItem(timeline, leftClip)) {
            repairFailReason = @"failed to select left clip for corrective trim";
            goto repair_cleanup;
        }
        if (!FCPBridge_transitionSeekToSeconds(timeline, targetStart)) {
            repairFailReason = @"failed to seek to captured cut time";
            goto repair_cleanup;
        }
        if (!FCPBridge_sendTimelineSimpleAction(timeline, @"trimEnd:")) {
            repairFailReason = @"timeline missing trimEnd: for corrective trim";
            goto repair_cleanup;
        }

        id correctedRightClip = FCPBridge_transitionFindRightClipNearTime(timeline, targetStart, frame);
        double correctedRightStart = 0.0;
        double correctedRightEnd = 0.0;
        if (!correctedRightClip ||
            !FCPBridge_transitionGetItemBounds(correctedRightClip,
                &correctedRightStart, &correctedRightEnd)) {
            repairFailReason = @"failed to resolve right clip after corrective trim";
            goto repair_cleanup;
        }
        if (fabs(correctedRightEnd - targetEnd) > (frame * 4.0)) {
            repairFailReason = [NSString stringWithFormat:
                @"corrective trim left right clip end at %.4f instead of %.4f",
                correctedRightEnd, targetEnd];
            goto repair_cleanup;
        }

        FCPBridge_log([NSString stringWithFormat:
            @"[FreezeExtend] Corrective trim completed right=%.4f-%.4f",
            correctedRightStart, correctedRightEnd]);
        FCPBridge_sendTimelineSimpleAction(timeline, @"deselectAll:");
        repairResult = YES;
    }

repair_cleanup:
    // Restore reduced transition duration
    if (repairReducedDuration) {
        if (repairOrigDurSetting > 0.0f) {
            [[NSUserDefaults standardUserDefaults]
                setFloat:repairOrigDurSetting
                forKey:@"FFSequenceTransDefaultDuration"];
        } else {
            [[NSUserDefaults standardUserDefaults]
                removeObjectForKey:@"FFSequenceTransDefaultDuration"];
        }
        sFreezeExtendOperationDuration = repairOrigOpDuration;
    }

    if (!repairResult && repairFailReason) {
        return FCPBridge_failFreezeExtendRepair(outReason, repairFailReason);
    }
    return repairResult;
}

static void FCPBridge_scheduleFreezeExtendRepairAttempt(NSInteger attemptNumber) {
    double delaySeconds = 0.25 * MAX((NSInteger)1, attemptNumber);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delaySeconds * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
            NSString *reason = nil;
            BOOL ok = FCPBridge_attemptFreezeExtendRepairRightSide(&reason);
            if (ok) {
                sFreezeExtendDidApply = YES;
                FCPBridge_log([NSString stringWithFormat:
                    @"[FreezeExtend] Synthetic repair completed on attempt %ld",
                    (long)attemptNumber]);
                FCPBridge_clearCapturedTransitionRequest();
                sFreezeExtendTargetRightClip = nil;
                sFreezeExtendTargetClipStart = 0.0;
                sFreezeExtendTargetClipEnd = 0.0;
                FCPBridge_clearFreezeExtendTransientState();
                sFreezeExtendRepairInProgress = NO;
                return;
            }

            sFreezeExtendDidApply = NO;
            FCPBridge_log([NSString stringWithFormat:
                @"[FreezeExtend] Synthetic repair failed on attempt %ld: %@",
                (long)attemptNumber, reason ?: @"unknown reason"]);
            FCPBridge_clearCapturedTransitionRequest();
            sFreezeExtendTargetRightClip = nil;
            sFreezeExtendTargetClipStart = 0.0;
            sFreezeExtendTargetClipEnd = 0.0;
            FCPBridge_clearFreezeExtendTransientState();
            sFreezeExtendRepairInProgress = NO;
        });
}

static void FCPBridge_scheduleFreezeExtendRepair(void) {
    if (sFreezeExtendRepairInProgress) return;

    sFreezeExtendRepairInProgress = YES;
    sFreezeExtendDidApply = NO;
    FCPBridge_scheduleFreezeExtendRepairAttempt(1);
}

static int FCPBridge_effectiveTransitionOverlapType(int overlapType, NSString *source) {
    if (!FCPBridge_shouldForceFreezeOverlap()) {
        return overlapType;
    }

    if (overlapType != 2) {
        FCPBridge_log(@"[FreezeExtend] Forcing transitionOverlapType -> 2");
        if (source.length > 0) {
            FCPBridge_log([NSString stringWithFormat:
                @"[FreezeExtend] Source=%@ original transitionOverlapType=%d",
                source, overlapType]);
        }
    }
    return 2;
}

static NSModalResponse FCPBridge_swizzled_NSAlert_runModal(id self, SEL _cmd) {
    // Only intercept when a freeze_extend API call is in progress.
    // All other alerts (including FCP's native transition dialog) pass through
    // completely unmodified so the user sees the original FCP behavior.
    if (!sFreezeExtendPendingAutoAccept && !sFreezeExtendInTransitionAlert) {
        return ((NSModalResponse (*)(id, SEL))sOrigNSAlertRunModal)(self, _cmd);
    }

    if (sFreezeExtendPendingAutoAccept) {
        FCPBridge_log(@"[FreezeExtend] Auto-accepting NSAlert");
        sFreezeExtendUseFreezeFramesForCurrentAlert = YES;
        return 0;
    }

    return ((NSModalResponse (*)(id, SEL))sOrigNSAlertRunModal)(self, _cmd);
}

static BOOL FCPBridge_swizzled_actionAddTransitions(id self, SEL _cmd, id spineObjects,
                                                    BOOL before, BOOL after, id effects,
                                                    int transitionOverlapType,
                                                    id *transitionsCreated, id rootItem,
                                                    BOOL reportErrors, id *error) {
    FCPBridge_captureTransitionReplayRequest(self, spineObjects, before, after, effects,
        rootItem, reportErrors, @"actionAddTransitionsToSpineObjects");
    FCPBridge_transitionCaptureTargetFromObjects(spineObjects, rootItem ?: self,
        @"actionAddTransitionsToSpineObjects");
    int effectiveType = FCPBridge_effectiveTransitionOverlapType(transitionOverlapType,
        @"actionAddTransitionsToSpineObjects");
    return ((BOOL (*)(id, SEL, id, BOOL, BOOL, id, int, id *, id, BOOL, id *))
        sOrigActionAddTransitions)(self, _cmd, spineObjects, before, after, effects,
            effectiveType, transitionsCreated, rootItem, reportErrors, error);
}

static BOOL FCPBridge_swizzled_operationAddTransitions(id self, SEL _cmd, id spineObject,
                                                       id spineObjectsToAddTransition,
                                                       BOOL before, BOOL after,
                                                       id *spineTransitionClipsCreated,
                                                       id effects, CMTime transitionDuration,
                                                       int transitionOverlapType,
                                                       BOOL reportErrors, id *error) {
    FCPBridge_transitionCaptureTargetFromObjects(spineObjectsToAddTransition, spineObject ?: self,
        @"operationAddTransitionsToObjectsOnSpineObject");
    int effectiveType = FCPBridge_effectiveTransitionOverlapType(transitionOverlapType,
        @"operationAddTransitionsToObjectsOnSpineObject");
    return ((BOOL (*)(id, SEL, id, id, BOOL, BOOL, id *, id, CMTime, int, BOOL, id *))
        sOrigOperationAddTransitions)(self, _cmd, spineObject, spineObjectsToAddTransition,
            before, after, spineTransitionClipsCreated, effects, transitionDuration,
            effectiveType, reportErrors, error);
}

static BOOL FCPBridge_swizzled_operationAddTransitionsAskedRetry(
    id self, SEL _cmd, id spineObject, id spineObjectsToAddTransition, BOOL before,
    BOOL after, id *spineTransitionClipsCreated, id effects, CMTime transitionDuration,
    int transitionOverlapType, id spareTransition, int reportErrors, int *askedRetry,
    id *error) {
    FCPBridge_captureOperationTransitionReplayRequest(
        self, spineObject, spineObjectsToAddTransition, before, after, effects,
        transitionDuration, spareTransition, reportErrors,
        @"operationAddTransitionsToObjectsOnSpineObject askedRetry");
    FCPBridge_transitionCaptureTargetFromObjects(spineObjectsToAddTransition, spineObject ?: self,
        @"operationAddTransitionsToObjectsOnSpineObject askedRetry");
    int effectiveType = FCPBridge_effectiveTransitionOverlapType(transitionOverlapType,
        @"operationAddTransitionsToObjectsOnSpineObject askedRetry");
    return ((BOOL (*)(id, SEL, id, id, BOOL, BOOL, id *, id, CMTime, int, id, int, int *, id *))
        sOrigOperationAddTransitionsAskedRetry)(self, _cmd, spineObject,
            spineObjectsToAddTransition, before, after, spineTransitionClipsCreated,
            effects, transitionDuration, effectiveType, spareTransition, reportErrors,
            askedRetry, error);
}

static void FCPBridge_swizzled_NSApp_stopModalWithCode(id self, SEL _cmd, NSModalResponse code) {
    if (sFreezeExtendInTransitionAlert) {
        FCPBridge_log([NSString stringWithFormat:
            @"[FreezeExtend] stopModalWithCode raw=%ld", (long)code]);
        if (FCPBridge_isFreezeFramesResponse(code)) {
            FCPBridge_log(@"[FreezeExtend] stopModalWithCode detected 'Use Freeze Frames'");
            sForceOverlap = YES;
            sFreezeExtendUseFreezeFramesForCurrentAlert = YES;
        }
    }

    ((void (*)(id, SEL, NSModalResponse))sOrigNSAppStopModalWithCode)(self, _cmd, code);
}

// Helper: get all clip info from the timeline for debugging
static void FCPBridge_logTimelineClips(id timelineModule, NSString *label) {
    if (!timelineModule) return;
    id sequence = [timelineModule respondsToSelector:@selector(sequence)]
        ? ((id (*)(id, SEL))objc_msgSend)(timelineModule, @selector(sequence))
        : nil;
    if (!sequence) return;
    id primaryObj = [sequence respondsToSelector:@selector(primaryObject)]
        ? ((id (*)(id, SEL))objc_msgSend)(sequence, @selector(primaryObject))
        : nil;
    if (!primaryObj) return;
    NSArray *items = [primaryObj respondsToSelector:@selector(containedItems)]
        ? ((id (*)(id, SEL))objc_msgSend)(primaryObj, @selector(containedItems))
        : nil;
    if (![items isKindOfClass:[NSArray class]]) return;

    SEL erSel = NSSelectorFromString(@"effectiveRangeOfObject:");
    BOOL canGetRange = [primaryObj respondsToSelector:erSel];
    NSMutableString *desc = [NSMutableString stringWithFormat:@"[FreezeExtend] %@ (%lu items):", label, (unsigned long)items.count];

    for (id item in items) {
        NSString *cls = NSStringFromClass([item class]) ?: @"?";
        if (canGetRange) {
            @try {
                FCPBridge_CMTimeRange range =
                    ((FCPBridge_CMTimeRange (*)(id, SEL, id))objc_msgSend)(primaryObj, erSel, item);
                double s = (range.start.timescale > 0) ? (double)range.start.value / (double)range.start.timescale : 0;
                double d = (range.duration.timescale > 0) ? (double)range.duration.value / (double)range.duration.timescale : 0;
                [desc appendFormat:@" [%@ %.4f+%.4f]", cls, s, d];
            } @catch (NSException *e) {
                [desc appendFormat:@" [%@ ERR]", cls];
            }
        } else {
            [desc appendFormat:@" [%@]", cls];
        }
    }
    FCPBridge_log(@"%@", desc);
}

// Helper: apply retimeHold to a clip to create hidden media handles.
// retimeHold: (Shift+H) adds a hold segment at the playhead
// position, extending the clip's total duration. We DON'T trim back — the
// hold extension gives FCP the extra media it needs for the transition.
static BOOL FCPBridge_applyHoldFrameExtension(id timelineModule, double clipStart,
                                               double clipEnd, double frame,
                                               BOOL holdAtStart, double holdDuration) {
    if (!timelineModule) return NO;
    double clipDur = clipEnd - clipStart;
    FCPBridge_log(@"[FreezeExtend] === applyHold === clip=%.4f-%.4f holdAtStart=%@",
        clipStart, clipEnd, holdAtStart ? @"YES" : @"NO");

    id seq = [timelineModule respondsToSelector:@selector(sequence)]
        ? ((id (*)(id, SEL))objc_msgSend)(timelineModule, @selector(sequence)) : nil;
    id prim = (seq && [seq respondsToSelector:@selector(primaryObject)])
        ? ((id (*)(id, SEL))objc_msgSend)(seq, @selector(primaryObject)) : nil;
    SEL erSel = NSSelectorFromString(@"effectiveRangeOfObject:");
    id targetClip = nil;
    if (prim && [prim respondsToSelector:erSel] && [prim respondsToSelector:@selector(containedItems)]) {
        NSArray *items = ((id (*)(id, SEL))objc_msgSend)(prim, @selector(containedItems));
        Class transCls = objc_getClass("FFAnchoredTransition");
        if ([items isKindOfClass:[NSArray class]]) {
            for (id item in items) {
                if (transCls && [item isKindOfClass:transCls]) continue;
                @try {
                    FCPBridge_CMTimeRange range = ((FCPBridge_CMTimeRange (*)(id, SEL, id))objc_msgSend)(prim, erSel, item);
                    double s = (range.start.timescale > 0) ? (double)range.start.value/(double)range.start.timescale : -1;
                    if (fabs(s - clipStart) < frame * 2.0) { targetClip = item; break; }
                } @catch (NSException *ex) { continue; }
            }
        }
    }
    if (!targetClip) { FCPBridge_log(@"[FreezeExtend] applyHold: CLIP NOT FOUND"); return NO; }

    // Step 1: Apply retimeHold: to extend the clip.
    // For holdAtStart (right clip): select by seeking INTO the clip first,
    // then navigate to the edit point with nextEdit. This matches how FCP
    // handles Shift+H when the user clicks a clip then moves the playhead.
    // For !holdAtStart (left clip): seek to the last frame of the clip.
    if (holdAtStart) {
        // Select the right clip by seeking into its midpoint
        FCPBridge_transitionSeekToSeconds(timelineModule, clipStart + (clipDur * 0.5));
        FCPBridge_sendTimelineSimpleAction(timelineModule, @"selectClipAtPlayhead:");
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.15]];
        // Navigate playhead to the edit point (clip's start) via prevEdit
        FCPBridge_transitionSeekToSeconds(timelineModule, clipEnd);
        FCPBridge_sendTimelineSimpleAction(timelineModule, @"previousEdit:");
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.15]];
    } else {
        FCPBridge_transitionSeekToSeconds(timelineModule, clipEnd - frame);
        FCPBridge_transitionSelectItem(timelineModule, targetClip);
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.2]];
    }
    double actualPos = FCPBridge_transitionCurrentTimeSeconds(timelineModule);
    FCPBridge_log(@"[FreezeExtend] applyHold: playhead=%.4f holdAtStart=%@", actualPos, holdAtStart ? @"YES" : @"NO");

    SEL holdSel = NSSelectorFromString(@"retimeHold:");
    if ([timelineModule respondsToSelector:holdSel])
        ((void (*)(id, SEL, id))objc_msgSend)(timelineModule, holdSel, nil);

    BOOL holdWorked = NO;
    double newDur = 0;
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:2.0];
    while ([deadline timeIntervalSinceNow] > 0.0) {
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
        if (prim && [prim respondsToSelector:erSel]) {
            @try {
                FCPBridge_CMTimeRange curRange = ((FCPBridge_CMTimeRange (*)(id, SEL, id))objc_msgSend)(prim, erSel, targetClip);
                newDur = (curRange.duration.timescale > 0) ? (double)curRange.duration.value / (double)curRange.duration.timescale : 0;
                if (newDur > clipDur + frame) { holdWorked = YES; break; }
            } @catch (NSException *ex) {}
        }
    }
    if (!holdWorked) { FCPBridge_log(@"[FreezeExtend] applyHold: hold failed"); return NO; }
    FCPBridge_log(@"[FreezeExtend] applyHold: hold confirmed dur=%.4f (was %.4f)", newDur, clipDur);

    // Step 2: Trim back to original size.
    // For !holdAtStart (left clip): hold is at the END. Trim END back.
    // For holdAtStart (right clip): hold is at the START. The clip extends
    //   to the right. DON'T trim — the hold on the left edge is what the
    //   transition needs. We'll trim the excess after the transition.
    if (holdAtStart) {
        FCPBridge_log(@"[FreezeExtend] applyHold: skipping trim for holdAtStart (hold is on left edge)");
        FCPBridge_logTimelineClips(timelineModule, @"applyHold:done");
        FCPBridge_sendTimelineSimpleAction(timelineModule, @"deselectAll:");
        return holdWorked;
    }

    // Trim END back for left clip
    // FCP uses when manually dragging the clip edge (trimCommand=1, trimFlags=2).
    double holdAmount = newDur - clipDur;
    SEL trimSel = NSSelectorFromString(
        @"operationTrimEdit:endEdits:edgeType:byDelta:trimCommand:trimFlags:temporalResolutionMode:animationHint:error:");
    if (seq && [seq respondsToSelector:trimSel]) {
        NSMethodSignature *sig = [seq methodSignatureForSelector:trimSel];
        if (sig) {
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setTarget:seq];
            [inv setSelector:trimSel];

            // For end trim: startEdits=nil, endEdits=[clip], delta=negative
            // For start trim: startEdits=[clip], endEdits=nil, delta=positive
            id clipArray = @[targetClip];
            id nilVal = nil;
            int edgeType = 0;
            int trimCommand = 1;  // ripple
            int trimFlags = 2;
            int temporalRes = 0;
            id animHint = nil;
            void *errorPtr = NULL;

            // The hold always extends the END of the clip on the timeline.
            // Trim the END back by the hold amount (negative delta).
            FCPBridge_CMTime delta;
            delta.timescale = 60000;
            delta.flags = 1;
            delta.epoch = 0;
            delta.value = -(int64_t)llround(holdAmount * 60000.0);

            FCPBridge_log(@"[FreezeExtend] applyHold: trimming end by delta=%.4f via operationTrimEdit (with beginEditing)", -holdAmount);

            // Wrap in beginEditing/endEditing like the manual drag does
            if ([seq respondsToSelector:@selector(beginEditing)])
                ((void (*)(id, SEL))objc_msgSend)(seq, @selector(beginEditing));

            // operationTrimEdit: has 9 params (with trimFlags):
            [inv setArgument:&nilVal atIndex:2];      // startEdits = nil
            [inv setArgument:&clipArray atIndex:3];    // endEdits = [clip]
            [inv setArgument:&edgeType atIndex:4];     // edgeType = 0
            [inv setArgument:&delta atIndex:5];        // byDelta = -holdAmount
            [inv setArgument:&trimCommand atIndex:6];  // trimCommand = 1 (ripple)
            [inv setArgument:&trimFlags atIndex:7];    // trimFlags = 2
            [inv setArgument:&temporalRes atIndex:8];  // temporalResolutionMode = 0
            [inv setArgument:&animHint atIndex:9];     // animationHint = nil
            [inv setArgument:&errorPtr atIndex:10];    // error = NULL

            @try {
                [inv invoke];
                BOOL ok = NO;
                [inv getReturnValue:&ok];
                FCPBridge_log(@"[FreezeExtend] applyHold: operationTrimEdit result=%@", ok ? @"YES" : @"NO");
            } @catch (NSException *e) {
                FCPBridge_log(@"[FreezeExtend] applyHold: operationTrimEdit exception: %@", e.reason);
            }

            if ([seq respondsToSelector:@selector(endEditing)])
                ((void (*)(id, SEL))objc_msgSend)(seq, @selector(endEditing));

            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.3]];
        }
    }

    FCPBridge_logTimelineClips(timelineModule, @"applyHold:done");
    FCPBridge_sendTimelineSimpleAction(timelineModule, @"deselectAll:");
    return holdWorked;
}















// State for the async hold-frame-then-retry workflow
static double sFreezeExtendEditPointTime = 0.0;
static NSString *sFreezeExtendPendingEffectID = nil;
static BOOL sFreezeExtendAsyncPending = NO;

// Replacement for -[FFAnchoredSequence displayTransitionAvailableMediaAlertDialog:]
// Instead of showing the "not enough extra media" dialog, cancel the current
// transition attempt, schedule hold-frame extensions on the short clips, then
// retry the transition on the next run-loop iteration.
static char FCPBridge_swizzled_displayTransitionAlert(id self, SEL _cmd, char *result) {
    // Freeze-extend auto-hold is disabled pending further development.
    // Pass through to FCP's original dialog.
    if (!sFreezeExtendPendingAutoAccept) {
        return ((char (*)(id, SEL, char *))sOrigDisplayTransitionAlert)(self, _cmd, result);
    }

    FCPBridge_log(@"[FreezeExtend] Intercepted 'not enough media' dialog");

    id timeline = FCPBridge_getActiveTimelineModule();
    if (!timeline) {
        return ((char (*)(id, SEL, char *))sOrigDisplayTransitionAlert)(self, _cmd, result);
    }

    double frame = FCPBridge_transitionFrameDurationSeconds(timeline);
    double defaultDur = FCPBridge_defaultTransitionDurationSeconds(timeline);
    double halfTransition = defaultDur / 2.0;

    // Use the captured target clip start as the edit point — the playhead may
    // be elsewhere (e.g. when a transition is dragged from the browser).
    // Fall back to currentSequenceTime if no capture is available.
    double editPointTime = (sFreezeExtendTargetClipStart > 0)
        ? sFreezeExtendTargetClipStart
        : FCPBridge_transitionCurrentTimeSeconds(timeline);

    // Scan ALL clips via the sequence (self) -> primaryObject and find the
    // two clips adjacent to the edit point.
    id primaryObj = [self respondsToSelector:@selector(primaryObject)]
        ? ((id (*)(id, SEL))objc_msgSend)(self, @selector(primaryObject))
        : nil;
    NSArray *items = nil;
    if (primaryObj && [primaryObj respondsToSelector:@selector(containedItems)])
        items = ((id (*)(id, SEL))objc_msgSend)(primaryObj, @selector(containedItems));

    SEL erSel = NSSelectorFromString(@"effectiveRangeOfObject:");
    BOOL canGetRange = primaryObj && [primaryObj respondsToSelector:erSel];
    Class transCls = objc_getClass("FFAnchoredTransition");

    typedef struct { double start; double end; double dur; BOOL found; } ClipInfo;
    ClipInfo leftClip = {0, 0, 0, NO};
    ClipInfo rightClip = {0, 0, 0, NO};

    if (canGetRange && [items isKindOfClass:[NSArray class]]) {
        for (id item in items) {
            if (transCls && [item isKindOfClass:transCls]) continue;
            @try {
                FCPBridge_CMTimeRange range =
                    ((FCPBridge_CMTimeRange (*)(id, SEL, id))objc_msgSend)(
                        primaryObj, erSel, item);
                if (range.duration.timescale <= 0 || range.duration.value <= 0) continue;
                double s = (double)range.start.value / (double)range.start.timescale;
                double d = (double)range.duration.value / (double)range.duration.timescale;
                double e = s + d;
                // Left clip: ends at or near the edit point
                if (fabs(e - editPointTime) < frame * 2.0) {
                    leftClip = (ClipInfo){s, e, d, YES};
                }
                // Right clip: starts at or near the edit point
                if (fabs(s - editPointTime) < frame * 2.0) {
                    rightClip = (ClipInfo){s, e, d, YES};
                }
            } @catch (NSException *ex) { continue; }
        }
    }

    FCPBridge_log(@"[FreezeExtend] Edit point=%.4f left=%@ (%.4f-%.4f, dur=%.4f) right=%@ (%.4f-%.4f, dur=%.4f) halfTrans=%.4f",
        editPointTime,
        leftClip.found ? @"YES" : @"NO", leftClip.start, leftClip.end, leftClip.dur,
        rightClip.found ? @"YES" : @"NO", rightClip.start, rightClip.end, rightClip.dur,
        halfTransition);

    BOOL needsExtension = (rightClip.found && rightClip.dur < halfTransition) ||
                           (leftClip.found && leftClip.dur < halfTransition);

    if (!needsExtension || sFreezeExtendAsyncPending) {
        if (sFreezeExtendPendingAutoAccept) {
            // Hold frames were already applied — just auto-accept
            FCPBridge_log(@"[FreezeExtend] Auto-accepting after hold extension");
            if (result) *result = 1;
            return 1;
        }
        FCPBridge_log(@"[FreezeExtend] No clips need extension (or retry pending), showing original dialog");
        return ((char (*)(id, SEL, char *))sOrigDisplayTransitionAlert)(self, _cmd, result);
    }

    // Cancel the current transition attempt (result=0), then schedule
    // hold-frame extension + transition retry asynchronously.
    if (result) *result = 0;
    sFreezeExtendEditPointTime = editPointTime;
    sFreezeExtendAsyncPending = YES;

    // Capture clip info for the async block
    __block ClipInfo asyncLeft = leftClip;
    __block ClipInfo asyncRight = rightClip;
    __block double asyncFrame = frame;
    __block double asyncHalf = halfTransition;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        @try {
            id tl = FCPBridge_getActiveTimelineModule();
            if (!tl) {
                FCPBridge_log(@"[FreezeExtend] Async: no timeline module");
                sFreezeExtendAsyncPending = NO;
                return;
            }

            FCPBridge_log(@"[FreezeExtend] Async: starting hold extension workflow");
            FCPBridge_logTimelineClips(tl, @"Async start");

            // Undo the failed/cancelled transition attempt
            FCPBridge_log(@"[FreezeExtend] Async: undoing cancelled transition");
            FCPBridge_sendTimelineSimpleAction(tl, @"undo");
            [[NSRunLoop currentRunLoop] runUntilDate:
                [NSDate dateWithTimeIntervalSinceNow:0.3]];
            FCPBridge_logTimelineClips(tl, @"After undo");

            // Extend LEFT clip first — the right clip extension shifts timeline
            // positions, making it hard to select the left clip afterward.
            if (asyncLeft.found && asyncLeft.dur < asyncHalf) {
                FCPBridge_log(@"[FreezeExtend] Async: extending left clip (%.4f-%.4f, dur=%.4fs)",
                    asyncLeft.start, asyncLeft.end, asyncLeft.dur);
                FCPBridge_applyHoldFrameExtension(tl, asyncLeft.start, asyncLeft.end, asyncFrame, NO, asyncHalf);
                FCPBridge_logTimelineClips(tl, @"After left hold");
            }

            // Extend right clip — after left extension, the right clip's start
            // has shifted. Re-scan to find its new position.
            if (asyncRight.found && asyncRight.dur < asyncHalf) {
                // Re-scan timeline to find the right clip's new position
                double newEditPoint = sFreezeExtendEditPointTime;
                id seq = [tl respondsToSelector:@selector(sequence)]
                    ? ((id (*)(id, SEL))objc_msgSend)(tl, @selector(sequence)) : nil;
                id prim = (seq && [seq respondsToSelector:@selector(primaryObject)])
                    ? ((id (*)(id, SEL))objc_msgSend)(seq, @selector(primaryObject)) : nil;
                if (prim && [prim respondsToSelector:@selector(containedItems)]) {
                    NSArray *curItems = ((id (*)(id, SEL))objc_msgSend)(prim, @selector(containedItems));
                    SEL erS = NSSelectorFromString(@"effectiveRangeOfObject:");
                    if ([curItems isKindOfClass:[NSArray class]] && [prim respondsToSelector:erS]) {
                        // Find the second non-transition clip (the right one)
                        Class tCls = objc_getClass("FFAnchoredTransition");
                        int clipIdx = 0;
                        for (id itm in curItems) {
                            if (tCls && [itm isKindOfClass:tCls]) continue;
                            clipIdx++;
                            if (clipIdx == 2) {
                                @try {
                                    FCPBridge_CMTimeRange r =
                                        ((FCPBridge_CMTimeRange (*)(id, SEL, id))objc_msgSend)(prim, erS, itm);
                                    if (r.duration.timescale > 0) {
                                        double s = (double)r.start.value / (double)r.start.timescale;
                                        double d = (double)r.duration.value / (double)r.duration.timescale;
                                        double e = s + d;
                                        newEditPoint = s;
                                        FCPBridge_log(@"[FreezeExtend] Async: right clip now at %.4f-%.4f (dur=%.4f)", s, e, d);
                                        asyncRight = (ClipInfo){s, e, d, YES};
                                    }
                                } @catch (NSException *ex) {}
                                break;
                            }
                        }
                    }
                }
                sFreezeExtendEditPointTime = newEditPoint;
                FCPBridge_log(@"[FreezeExtend] Async: extending right clip (%.4f-%.4f, dur=%.4fs)",
                    asyncRight.start, asyncRight.end, asyncRight.dur);
                FCPBridge_applyHoldFrameExtension(tl, asyncRight.start, asyncRight.end, asyncFrame, YES, asyncHalf);
                FCPBridge_logTimelineClips(tl, @"After right hold");
            }

            // Navigate to edit point and retry the transition
            double seekTarget = MAX(0, sFreezeExtendEditPointTime - asyncFrame);
            FCPBridge_log(@"[FreezeExtend] Async: seeking to %.4f then nextEdit", seekTarget);
            FCPBridge_transitionSeekToSeconds(tl, seekTarget);
            FCPBridge_sendTimelineSimpleAction(tl, @"nextEdit:");
            [[NSRunLoop currentRunLoop] runUntilDate:
                [NSDate dateWithTimeIntervalSinceNow:0.2]];

            double retryPos = FCPBridge_transitionCurrentTimeSeconds(tl);
            FCPBridge_log(@"[FreezeExtend] Async: retrying addTransition at playhead=%.4f", retryPos);
            FCPBridge_logTimelineClips(tl, @"Before retry");

            // Temporarily reduce the default transition duration to fit within
            // the available hold handles. The holds are ~2s but we want the
            // transition to only use what's needed — sized to 2x the shorter clip
            // so the transition overlaps holds, not real content.
            double minClipDur = MIN(asyncLeft.dur, asyncRight.dur);
            double fitDuration = 2.0 * minClipDur;
            float origDurSetting = [[NSUserDefaults standardUserDefaults]
                floatForKey:@"FFSequenceTransDefaultDuration"];
            [[NSUserDefaults standardUserDefaults]
                setFloat:(float)fitDuration
                forKey:@"FFSequenceTransDefaultDuration"];
            FCPBridge_log(@"[FreezeExtend] Async: set transition duration to %.4f (2 x %.4f)", fitDuration, minClipDur);

            // Auto-accept if the dialog still appears
            sFreezeExtendPendingAutoAccept = YES;

            SEL addSel = @selector(addTransition:);
            if ([tl respondsToSelector:addSel]) {
                ((void (*)(id, SEL, id))objc_msgSend)(tl, addSel, nil);
            } else {
                [[NSApplication sharedApplication] sendAction:addSel to:nil from:nil];
            }
            sFreezeExtendPendingAutoAccept = NO;

            // Restore original transition duration
            if (origDurSetting > 0.0f) {
                [[NSUserDefaults standardUserDefaults]
                    setFloat:origDurSetting forKey:@"FFSequenceTransDefaultDuration"];
            } else {
                [[NSUserDefaults standardUserDefaults]
                    removeObjectForKey:@"FFSequenceTransDefaultDuration"];
            }

            FCPBridge_logTimelineClips(tl, @"After transition added");

            FCPBridge_sendTimelineSimpleAction(tl, @"deselectAll:");
            FCPBridge_logTimelineClips(tl, @"Final result");
        } @catch (NSException *e) {
            FCPBridge_log(@"[FreezeExtend] Async hold+retry exception: %@", e.reason);
        }
        sFreezeExtendAsyncPending = NO;
    });

    FCPBridge_log(@"[FreezeExtend] Cancelled transition, scheduled async hold+retry");
    return 1;
}

// Install the swizzles (called once at startup)
void FCPBridge_installTransitionFreezeExtendSwizzle(void) {
    Class seqClass = objc_getClass("FFAnchoredSequence");
    if (!seqClass) {
        FCPBridge_log(@"[FreezeExtend] WARNING: FFAnchoredSequence class not found");
        return;
    }

    // Swizzle defaultTransitionOverlapType to allow forcing freeze-frame overlap
    SEL overlapSel = NSSelectorFromString(@"defaultTransitionOverlapType");
    Method overlapMethod = class_getInstanceMethod(seqClass, overlapSel);
    if (overlapMethod) {
        sOrigDefaultOverlapType = method_setImplementation(overlapMethod,
            (IMP)FCPBridge_swizzled_defaultTransitionOverlapType);
        FCPBridge_log(@"[FreezeExtend] Swizzled -[FFAnchoredSequence defaultTransitionOverlapType]");
    }

    // Swizzle displayTransitionAvailableMediaAlertDialog: to add our button
    SEL alertSel = NSSelectorFromString(@"displayTransitionAvailableMediaAlertDialog:");
    Method alertMethod = class_getInstanceMethod(seqClass, alertSel);
    if (alertMethod) {
        sOrigDisplayTransitionAlert = method_setImplementation(alertMethod,
            (IMP)FCPBridge_swizzled_displayTransitionAlert);
        FCPBridge_log(@"[FreezeExtend] Swizzled -[FFAnchoredSequence displayTransitionAvailableMediaAlertDialog:]");
    }

    Method runModalMethod = class_getInstanceMethod([NSAlert class], @selector(runModal));
    if (runModalMethod) {
        sOrigNSAlertRunModal = method_setImplementation(runModalMethod,
            (IMP)FCPBridge_swizzled_NSAlert_runModal);
        FCPBridge_log(@"[FreezeExtend] Swizzled -[NSAlert runModal]");
    }

    Method stopModalMethod = class_getInstanceMethod([NSApplication class],
        @selector(stopModalWithCode:));
    if (stopModalMethod) {
        sOrigNSAppStopModalWithCode = method_setImplementation(stopModalMethod,
            (IMP)FCPBridge_swizzled_NSApp_stopModalWithCode);
        FCPBridge_log(@"[FreezeExtend] Swizzled -[NSApplication stopModalWithCode:]");
    }

    SEL actionAddSel = NSSelectorFromString(
        @"actionAddTransitionsToSpineObjects:before:after:effects:transitionOverlapType:transitionsCreated:rootItem:reportErrors:error:");
    Method actionAddMethod = class_getInstanceMethod(seqClass, actionAddSel);
    if (actionAddMethod) {
        sOrigActionAddTransitions = method_setImplementation(actionAddMethod,
            (IMP)FCPBridge_swizzled_actionAddTransitions);
        FCPBridge_log(@"[FreezeExtend] Swizzled actionAddTransitionsToSpineObjects...");
    }

    SEL opAddSel = NSSelectorFromString(
        @"operationAddTransitionsToObjectsOnSpineObject:spineObjectsToAddTransition:before:after:spineTransitionClipsCreated:effects:transitionDuration:transitionOverlapType:reportErrors:error:");
    Method opAddMethod = class_getInstanceMethod(seqClass, opAddSel);
    if (opAddMethod) {
        sOrigOperationAddTransitions = method_setImplementation(opAddMethod,
            (IMP)FCPBridge_swizzled_operationAddTransitions);
        FCPBridge_log(@"[FreezeExtend] Swizzled operationAddTransitionsToObjectsOnSpineObject...");
    }

    SEL opAddRetrySel = NSSelectorFromString(
        @"operationAddTransitionsToObjectsOnSpineObject:spineObjectsToAddTransition:before:after:spineTransitionClipsCreated:effects:transitionDuration:transitionOverlapType:spareTransition:reportErrors:askedRetry:error:");
    Method opAddRetryMethod = class_getInstanceMethod(seqClass, opAddRetrySel);
    if (opAddRetryMethod) {
        sOrigOperationAddTransitionsAskedRetry = method_setImplementation(opAddRetryMethod,
            (IMP)FCPBridge_swizzled_operationAddTransitionsAskedRetry);
        FCPBridge_log(@"[FreezeExtend] Swizzled operationAddTransitionsToObjectsOnSpineObject...askedRetry...");
    }

    // Temporarily log all trim operations to understand what FCP does when
    // the user manually drags a clip edge after applying a hold frame.
    // operationTrimEdit:endEdits:edgeType:byDelta:trimCommand:trimFlags:temporalResolutionMode:animationHint:error:
    SEL trimSel = NSSelectorFromString(
        @"operationTrimEdit:endEdits:edgeType:byDelta:trimCommand:trimFlags:temporalResolutionMode:animationHint:error:");
    Method trimMethod = class_getInstanceMethod(seqClass, trimSel);
    if (trimMethod) {
        static IMP sOrigTrimEdit = NULL;
        sOrigTrimEdit = method_getImplementation(trimMethod);
        IMP newImp = imp_implementationWithBlock(^BOOL(id self, id startEdits, id endEdits,
            int edgeType, FCPBridge_CMTime delta, int trimCommand, int trimFlags,
            int temporalResMode, id animHint, id *error) {
            double deltaSeconds = (delta.timescale > 0) ? (double)delta.value / (double)delta.timescale : 0;
            FCPBridge_log(@"[TrimLog] operationTrimEdit edgeType=%d delta=%.4fs trimCommand=%d trimFlags=%d temporalRes=%d startEdits=%@ endEdits=%@",
                edgeType, deltaSeconds, trimCommand, trimFlags, temporalResMode,
                startEdits ? [startEdits description] : @"nil",
                endEdits ? [endEdits description] : @"nil");
            return ((BOOL (*)(id, SEL, id, id, int, FCPBridge_CMTime, int, int, int, id, id *))
                sOrigTrimEdit)(self, trimSel, startEdits, endEdits, edgeType, delta,
                    trimCommand, trimFlags, temporalResMode, animHint, error);
        });
        method_setImplementation(trimMethod, newImp);
        FCPBridge_log(@"[FreezeExtend] Swizzled operationTrimEdit for logging");
    }

    // Also log setClippedRange: calls
    SEL setCRSel = NSSelectorFromString(@"setClippedRange:");
    Method setCRMethod = class_getInstanceMethod(objc_getClass("FFAnchoredObject"), setCRSel);
    if (setCRMethod) {
        static IMP sOrigSetCR = NULL;
        sOrigSetCR = method_getImplementation(setCRMethod);
        IMP newImp = imp_implementationWithBlock(^void(id self, FCPBridge_CMTimeRange range) {
            double start = (range.start.timescale > 0) ? (double)range.start.value / (double)range.start.timescale : 0;
            double dur = (range.duration.timescale > 0) ? (double)range.duration.value / (double)range.duration.timescale : 0;
            FCPBridge_log(@"[TrimLog] setClippedRange: start=%.4f dur=%.4f on %@ %p",
                start, dur, NSStringFromClass([self class]), self);
            ((void (*)(id, SEL, FCPBridge_CMTimeRange))sOrigSetCR)(self, setCRSel, range);
        });
        method_setImplementation(setCRMethod, newImp);
        FCPBridge_log(@"[FreezeExtend] Swizzled setClippedRange: for logging");
    }
}

#pragma mark - Effect Drag as Adjustment Clip

// When a video filter is dragged from the Effects Browser to empty timeline space
// (above/below clips), create an adjustment clip with that effect instead of rejecting.
// connectAdjustmentClip: gives us the right drop placement, but during a drag the
// active-browser selection is unreliable, so we capture the dragged effect ID
// ourselves and apply/rename the new clip after it is created.

static NSString * const kFCPBridgeEffectDragAsAdjustmentClip = @"FCPBridgeEffectDragAsAdjustmentClip";
static BOOL sEffectDropOnEmptySpace = NO;
static IMP sOrigValidateEffectsDrop = NULL;
static IMP sOrigTLKPerformDragOp = NULL;
static IMP sOrigKeyWindowActiveModule = NULL;
static NSString *sDraggedEffectID = nil;
static NSString *sDraggedEffectName = nil;
static NSString *sEffectDragKeyWindowSelectedEffectID = nil;
static BOOL sEffectDragInstallRetryScheduled = NO;
static NSInteger sEffectDragInstallAttempts = 0;

static void FCPBridge_scheduleEffectDragInstallRetry(void);

@interface FCPBridgeEffectDragModuleProxy : NSProxy {
    id _target;
}
+ (instancetype)proxyWithTarget:(id)target;
- (id)selectedEffectID;
@end

@implementation FCPBridgeEffectDragModuleProxy
+ (instancetype)proxyWithTarget:(id)target {
    FCPBridgeEffectDragModuleProxy *proxy = [FCPBridgeEffectDragModuleProxy alloc];
    proxy->_target = target;
    return proxy;
}

- (id)selectedEffectID {
    return sEffectDragKeyWindowSelectedEffectID;
}

- (NSMethodSignature *)methodSignatureForSelector:(SEL)selector {
    if (selector == @selector(selectedEffectID)) {
        return [NSMethodSignature signatureWithObjCTypes:"@@:"];
    }
    return _target ? [_target methodSignatureForSelector:selector]
                   : [NSObject instanceMethodSignatureForSelector:@selector(init)];
}

- (void)forwardInvocation:(NSInvocation *)invocation {
    if (_target) {
        [invocation invokeWithTarget:_target];
    }
}

- (BOOL)respondsToSelector:(SEL)aSelector {
    return aSelector == @selector(selectedEffectID) || [_target respondsToSelector:aSelector];
}

- (Class)class {
    return _target ? [_target class] : [NSObject class];
}

- (BOOL)isKindOfClass:(Class)aClass {
    return _target ? [_target isKindOfClass:aClass] : [super isKindOfClass:aClass];
}

- (NSString *)description {
    return _target ? [_target description] : @"<FCPBridgeEffectDragModuleProxy>";
}
@end

static id FCPBridge_swizzled_keyWindowActiveModule(id self, SEL _cmd) {
    id original = sOrigKeyWindowActiveModule
        ? ((id (*)(id, SEL))sOrigKeyWindowActiveModule)(self, _cmd)
        : nil;

    if (sEffectDragKeyWindowSelectedEffectID.length > 0) {
        return [FCPBridgeEffectDragModuleProxy proxyWithTarget:original];
    }

    return original;
}

static void FCPBridge_clearDraggedEffectState(void) {
    sEffectDropOnEmptySpace = NO;
    sDraggedEffectID = nil;
    sDraggedEffectName = nil;
}

BOOL FCPBridge_isEffectDragAsAdjustmentClipEnabled(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    id storedValue = [defaults objectForKey:kFCPBridgeEffectDragAsAdjustmentClip];
    if (!storedValue) {
        return YES;
    }
    return [defaults boolForKey:kFCPBridgeEffectDragAsAdjustmentClip];
}

void FCPBridge_setEffectDragAsAdjustmentClipEnabled(BOOL enabled) {
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:kFCPBridgeEffectDragAsAdjustmentClip];
    if (enabled) {
        FCPBridge_log(@"[EffectDrag] Enabled");
        FCPBridge_installEffectDragAsAdjustmentClip();
    } else {
        FCPBridge_log(@"[EffectDrag] Disabled");
        sEffectDragKeyWindowSelectedEffectID = nil;
        FCPBridge_clearDraggedEffectState();
    }
}

static Class FCPBridge_findLoadedClassNamed(const char *wantedName) {
    if (!wantedName) return Nil;

    unsigned int classCount = 0;
    Class *classes = objc_copyClassList(&classCount);
    if (!classes) return Nil;

    Class foundClass = Nil;
    for (unsigned int i = 0; i < classCount; i++) {
        const char *className = class_getName(classes[i]);
        if (className && strcmp(className, wantedName) == 0) {
            foundClass = classes[i];
            break;
        }
    }

    free(classes);
    return foundClass;
}

static NSArray *FCPBridge_effectDragSelectedItems(id timelineModule) {
    if (!timelineModule) return nil;

    SEL selSel = NSSelectorFromString(@"selectedItems:includeItemBeforePlayheadIfLast:");
    if (![timelineModule respondsToSelector:selSel]) return nil;

    id selected = ((id (*)(id, SEL, BOOL, BOOL))objc_msgSend)(timelineModule, selSel, NO, NO);
    return [selected isKindOfClass:[NSArray class]] ? [(NSArray *)selected copy] : nil;
}

static NSArray *FCPBridge_effectDragContainedItems(id timelineModule) {
    if (!timelineModule) return nil;

    SEL seqSel = NSSelectorFromString(@"sequence");
    id sequence = [timelineModule respondsToSelector:seqSel]
        ? ((id (*)(id, SEL))objc_msgSend)(timelineModule, seqSel)
        : nil;
    if (!sequence) return nil;

    id itemsSource = nil;
    if ([sequence respondsToSelector:@selector(primaryObject)]) {
        id primaryObj = ((id (*)(id, SEL))objc_msgSend)(sequence, @selector(primaryObject));
        if (primaryObj && [primaryObj respondsToSelector:@selector(containedItems)]) {
            itemsSource = ((id (*)(id, SEL))objc_msgSend)(primaryObj, @selector(containedItems));
        }
    }
    if (!itemsSource && [sequence respondsToSelector:@selector(containedItems)]) {
        itemsSource = ((id (*)(id, SEL))objc_msgSend)(sequence, @selector(containedItems));
    }

    return [itemsSource isKindOfClass:[NSArray class]] ? [(NSArray *)itemsSource copy] : nil;
}

static NSSet *FCPBridge_effectDragPointerSet(NSArray *objects) {
    NSMutableSet *result = [NSMutableSet setWithCapacity:objects.count];
    for (id object in objects) {
        if (object) {
            [result addObject:[NSValue valueWithNonretainedObject:object]];
        }
    }
    return result;
}

static BOOL FCPBridge_effectDragLooksLikeAdjustmentClip(id clip) {
    if (!clip) return NO;

    NSString *className = NSStringFromClass([clip class]) ?: @"";
    if ([className localizedCaseInsensitiveContainsString:@"adjust"]) {
        return YES;
    }

    if ([clip respondsToSelector:@selector(displayName)]) {
        id name = ((id (*)(id, SEL))objc_msgSend)(clip, @selector(displayName));
        if ([name isKindOfClass:[NSString class]] &&
            [(NSString *)name localizedCaseInsensitiveContainsString:@"adjustment"]) {
            return YES;
        }
    }

    return NO;
}

static void FCPBridge_effectDragExtractEffectInfo(
    id pasteboard, id timelineModule, NSString **outEffectID, NSString **outEffectName)
{
    NSString *effectID = nil;
    NSString *effectName = nil;

    if (pasteboard && timelineModule) {
        SEL seqSel = NSSelectorFromString(@"sequence");
        id sequence = [timelineModule respondsToSelector:seqSel]
            ? ((id (*)(id, SEL))objc_msgSend)(timelineModule, seqSel)
            : nil;
        SEL newMediaSel = NSSelectorFromString(@"newMediaWithSequence:fromURL:options:");
        if (sequence && [pasteboard respondsToSelector:newMediaSel]) {
            id items = ((id (*)(id, SEL, id, id, id))objc_msgSend)(
                pasteboard, newMediaSel, sequence, nil, nil);
            for (id item in items) {
                id object = item;
                SEL objectSel = NSSelectorFromString(@"object");
                if ([item respondsToSelector:objectSel]) {
                    id inner = ((id (*)(id, SEL))objc_msgSend)(item, objectSel);
                    if (inner) object = inner;
                }
                if ([object respondsToSelector:@selector(effectID)]) {
                    id resolvedEffectID = ((id (*)(id, SEL))objc_msgSend)(object, @selector(effectID));
                    if ([resolvedEffectID isKindOfClass:[NSString class]] &&
                        [(NSString *)resolvedEffectID length] > 0) {
                        effectID = resolvedEffectID;
                        break;
                    }
                }
            }
        }
    }

    if (effectID) {
        Class ffEffect = objc_getClass("FFEffect");
        if (ffEffect && [ffEffect respondsToSelector:@selector(displayNameForEffectID:)]) {
            id displayName = ((id (*)(id, SEL, id))objc_msgSend)(
                (id)ffEffect, @selector(displayNameForEffectID:), effectID);
            if ([displayName isKindOfClass:[NSString class]] && [(NSString *)displayName length] > 0) {
                effectName = displayName;
            }
        }
    }

    if (outEffectID) *outEffectID = effectID;
    if (outEffectName) *outEffectName = effectName;
}

static id FCPBridge_effectDragVideoEffectsTarget(id clip) {
    if (!clip) return nil;

    SEL veSel = NSSelectorFromString(@"videoEffects");
    if ([clip respondsToSelector:veSel]) {
        id videoEffects = ((id (*)(id, SEL))objc_msgSend)(clip, veSel);
        if (videoEffects) return videoEffects;
    }

    SEL toolSel = NSSelectorFromString(@"representedToolObject");
    if ([clip respondsToSelector:toolSel]) {
        id toolObj = ((id (*)(id, SEL))objc_msgSend)(clip, toolSel);
        if (toolObj && [toolObj respondsToSelector:veSel]) {
            return ((id (*)(id, SEL))objc_msgSend)(toolObj, veSel);
        }
    }

    return nil;
}

static BOOL FCPBridge_effectDragClipHasEffectID(id clip, NSString *effectID) {
    if (!clip || effectID.length == 0) return NO;

    SEL effectsSel = NSSelectorFromString(@"effects");
    if (![clip respondsToSelector:effectsSel]) return NO;

    id effects = ((id (*)(id, SEL))objc_msgSend)(clip, effectsSel);
    if (![effects isKindOfClass:[NSArray class]]) return NO;

    for (id effect in (NSArray *)effects) {
        if ([effect respondsToSelector:@selector(effectID)]) {
            id existingID = ((id (*)(id, SEL))objc_msgSend)(effect, @selector(effectID));
            if ([existingID isKindOfClass:[NSString class]] &&
                [(NSString *)existingID isEqualToString:effectID]) {
                return YES;
            }
        }
    }

    return NO;
}

static id FCPBridge_effectDragFindCreatedClip(
    id timelineModule, NSArray *itemsBefore, NSArray *selectedBefore)
{
    NSSet *selectedBeforePointers = FCPBridge_effectDragPointerSet(selectedBefore ?: @[]);
    NSArray *selectedAfter = FCPBridge_effectDragSelectedItems(timelineModule) ?: @[];

    id firstNewSelected = nil;
    for (id item in selectedAfter) {
        if (![selectedBeforePointers containsObject:[NSValue valueWithNonretainedObject:item]]) {
            if (FCPBridge_effectDragLooksLikeAdjustmentClip(item)) {
                return item;
            }
            if (!firstNewSelected) firstNewSelected = item;
        }
    }

    NSSet *beforePointers = FCPBridge_effectDragPointerSet(itemsBefore ?: @[]);
    NSArray *itemsAfter = FCPBridge_effectDragContainedItems(timelineModule) ?: @[];
    id firstNewItem = nil;
    for (id item in itemsAfter) {
        if (![beforePointers containsObject:[NSValue valueWithNonretainedObject:item]]) {
            if (FCPBridge_effectDragLooksLikeAdjustmentClip(item)) {
                return item;
            }
            if (!firstNewItem) firstNewItem = item;
        }
    }

    if (firstNewSelected) return firstNewSelected;
    if (firstNewItem) return firstNewItem;

    if ([selectedAfter respondsToSelector:@selector(firstObject)]) {
        return [selectedAfter firstObject];
    }
    return nil;
}

// Swizzled -[FFAnchoredTimelineModule _validateEffectsDrop:onItem:atIndex:]
// Original rejects drops when item is the root (empty space). We accept those
// for video filters so the user gets a green "+" cursor.
static unsigned long long FCPBridge_swizzled_validateEffectsDrop(
    id self, SEL _cmd, id pasteboard, id item, long long index)
{
    unsigned long long result = ((unsigned long long (*)(id, SEL, id, id, long long))
        sOrigValidateEffectsDrop)(self, _cmd, pasteboard, item, index);

    if (!FCPBridge_isEffectDragAsAdjustmentClipEnabled()) {
        FCPBridge_clearDraggedEffectState();
        return result;
    }

    if (result != 0) {
        // Original accepted (drop on a valid clip) — normal behavior
        FCPBridge_clearDraggedEffectState();
        return result;
    }

    // Original rejected. Check if this is a video filter over empty space.
    SEL hasTypeSel = NSSelectorFromString(@"hasEffectsWithType:");
    if (![pasteboard respondsToSelector:hasTypeSel]) {
        FCPBridge_clearDraggedEffectState();
        return 0;
    }
    BOOL hasVideoFilter = ((BOOL (*)(id, SEL, id))objc_msgSend)(
        pasteboard, hasTypeSel, @"effect.video.filter");
    if (!hasVideoFilter) {
        FCPBridge_clearDraggedEffectState();
        return 0;
    }

    // Check if item is the root item (empty timeline space)
    SEL rootSel = NSSelectorFromString(@"rootItem");
    if (![self respondsToSelector:rootSel]) {
        FCPBridge_clearDraggedEffectState();
        return 0;
    }
    id rootItem = ((id (*)(id, SEL))objc_msgSend)(self, rootSel);
    if (item != rootItem) {
        FCPBridge_clearDraggedEffectState();
        return 0;
    }

    NSString *effectID = nil;
    NSString *effectName = nil;
    FCPBridge_effectDragExtractEffectInfo(pasteboard, self, &effectID, &effectName);

    // Accept the drop — we'll create an adjustment clip in performDragOperation:
    sEffectDropOnEmptySpace = YES;
    sDraggedEffectID = [effectID copy];
    sDraggedEffectName = [effectName copy];
    FCPBridge_log(@"[EffectDrag] Accepting empty-space drop for %@ (%@) at index %lld",
                  sDraggedEffectName ?: @"<unknown effect>",
                  sDraggedEffectID ?: @"<no effect id>",
                  index);
    return 1; // NSDragOperationCopy
}

// Swizzled -[TLKTimelineView performDragOperation:]
// Intercepts the drop before FCP's normal handling. When our flag is set,
// temporarily overrides NSApp.keyWindowActiveModule.selectedEffectID so
// connectAdjustmentClip: takes FCP's normal "effect browser selection" path.
static char FCPBridge_swizzled_TLKPerformDragOp(id self, SEL _cmd, id draggingInfo) {
    if (!FCPBridge_isEffectDragAsAdjustmentClipEnabled()) {
        FCPBridge_clearDraggedEffectState();
        goto fallback;
    }

    if (sEffectDropOnEmptySpace) {
        id timelineModule = FCPBridge_getActiveTimelineModule();
        if (!timelineModule) {
            FCPBridge_clearDraggedEffectState();
            goto fallback;
        }

        NSString *effectID = [sDraggedEffectID copy];
        NSString *effectName = [sDraggedEffectName copy];
        if (effectID.length == 0) {
            id handlerPb = nil;
            @try { handlerPb = [timelineModule valueForKey:@"handlerPasteboard"]; } @catch (NSException *e) {}
            FCPBridge_effectDragExtractEffectInfo(handlerPb, timelineModule, &effectID, &effectName);
        }

        FCPBridge_log(@"[EffectDrag] Creating adjustment clip with effect: %@ (%@)",
                      effectName ?: @"<none>", effectID ?: @"<none>");

        // Step 1: Create the adjustment clip at the validated drop position.
        SEL adjSel = NSSelectorFromString(@"connectAdjustmentClip:");
        if (![timelineModule respondsToSelector:adjSel]) {
            FCPBridge_clearDraggedEffectState();
            goto fallback;
        }
        if (effectID.length > 0) {
            sEffectDragKeyWindowSelectedEffectID = [effectID copy];
        }
        ((void (*)(id, SEL, id))objc_msgSend)(timelineModule, adjSel, nil);
        sEffectDragKeyWindowSelectedEffectID = nil;

        // FCP's native path should have applied the effect and set the clip name.
        FCPBridge_clearDraggedEffectState();
        return 1; // YES — drop handled
    }

fallback:
    if (!sOrigTLKPerformDragOp) {
        return 0;
    }
    return ((char (*)(id, SEL, id))sOrigTLKPerformDragOp)(self, _cmd, draggingInfo);
}

static void FCPBridge_scheduleEffectDragInstallRetry(void) {
    if ((sOrigValidateEffectsDrop && sOrigTLKPerformDragOp) || sEffectDragInstallRetryScheduled) {
        return;
    }
    if (sEffectDragInstallAttempts >= 30) {
        if (sEffectDragInstallAttempts == 30) {
            FCPBridge_log(@"[EffectDrag] Giving up on swizzle install after %ld attempts",
                          (long)sEffectDragInstallAttempts);
            sEffectDragInstallAttempts++;
        }
        return;
    }

    sEffectDragInstallRetryScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        sEffectDragInstallRetryScheduled = NO;
        sEffectDragInstallAttempts++;
        FCPBridge_installEffectDragSwizzlesNow();
    });
}

void FCPBridge_installEffectDragSwizzlesNow(void) {
    FCPBridge_executeOnMainThread(^{
        if (sOrigValidateEffectsDrop && sOrigTLKPerformDragOp) {
            sEffectDragInstallRetryScheduled = NO;
            return;
        }

        Class tlmClass = Nil;
        Class tlkClass = Nil;

        id activeModule = FCPBridge_getActiveTimelineModule();
        if (activeModule) {
            tlmClass = [activeModule class];
            SEL tvSel = NSSelectorFromString(@"timelineView");
            if ([activeModule respondsToSelector:tvSel]) {
                id timelineView = ((id (*)(id, SEL))objc_msgSend)(activeModule, tvSel);
                if (timelineView) {
                    tlkClass = [timelineView class];
                }
            }
        }

        if (!tlmClass) tlmClass = FCPBridge_findLoadedClassNamed("FFAnchoredTimelineModule");
        if (!tlkClass) tlkClass = FCPBridge_findLoadedClassNamed("TLKTimelineView");

        if (!tlmClass || !tlkClass) {
            if (sEffectDragInstallAttempts == 0) {
                FCPBridge_log(@"[EffectDrag] Timeline classes not available yet; waiting to install swizzles");
            }
            FCPBridge_scheduleEffectDragInstallRetry();
            return;
        }

        SEL valSel = NSSelectorFromString(@"_validateEffectsDrop:onItem:atIndex:");
        Method valMethod = class_getInstanceMethod(tlmClass, valSel);
        if (!sOrigValidateEffectsDrop && valMethod) {
            sOrigValidateEffectsDrop = method_setImplementation(
                valMethod, (IMP)FCPBridge_swizzled_validateEffectsDrop);
            FCPBridge_log(@"[EffectDrag] Swizzled -[%@ _validateEffectsDrop:onItem:atIndex:]",
                          NSStringFromClass(tlmClass));
        }

        SEL perfSel = @selector(performDragOperation:);
        Method perfMethod = class_getInstanceMethod(tlkClass, perfSel);
        if (!sOrigTLKPerformDragOp && perfMethod) {
            sOrigTLKPerformDragOp = method_setImplementation(
                perfMethod, (IMP)FCPBridge_swizzled_TLKPerformDragOp);
            FCPBridge_log(@"[EffectDrag] Swizzled -[%@ performDragOperation:]",
                          NSStringFromClass(tlkClass));
        }

        Class appClass = [NSApplication class];
        SEL keyWindowActiveModuleSel = NSSelectorFromString(@"keyWindowActiveModule");
        Method keyWindowActiveModuleMethod = class_getInstanceMethod(appClass, keyWindowActiveModuleSel);
        if (!sOrigKeyWindowActiveModule && keyWindowActiveModuleMethod) {
            sOrigKeyWindowActiveModule = method_setImplementation(
                keyWindowActiveModuleMethod, (IMP)FCPBridge_swizzled_keyWindowActiveModule);
            FCPBridge_log(@"[EffectDrag] Swizzled -[NSApplication keyWindowActiveModule]");
        }

        if (!sOrigValidateEffectsDrop || !sOrigTLKPerformDragOp || !sOrigKeyWindowActiveModule) {
            FCPBridge_log(@"[EffectDrag] Waiting for swizzles: validate=%@ perform=%@ keyWindowActiveModule=%@",
                          sOrigValidateEffectsDrop ? @"ok" : @"missing",
                          sOrigTLKPerformDragOp ? @"ok" : @"missing",
                          sOrigKeyWindowActiveModule ? @"ok" : @"missing");
            FCPBridge_scheduleEffectDragInstallRetry();
            return;
        }

        sEffectDragInstallRetryScheduled = NO;
        sEffectDragInstallAttempts = 0;
    });
}

void FCPBridge_installEffectDragAsAdjustmentClip(void) {
    if (!FCPBridge_isEffectDragAsAdjustmentClipEnabled()) {
        FCPBridge_log(@"[EffectDrag] Install skipped because option is disabled");
        return;
    }
    FCPBridge_log(@"[EffectDrag] Scheduling install");
    FCPBridge_executeOnMainThreadAsync(^{
        FCPBridge_installEffectDragSwizzlesNow();
    });
}

#pragma mark - Effect Browser Favorites (context menu)

// Swizzle -[FFEffectLibraryItemView menu] to add "Add to Favorites" / "Remove from Favorites"
// This uses FCP's built-in favorites API (FFEffect favoriteEffectIDs:video:filterUnregisteredEffects:)

static IMP sOrigEffectLibraryItemViewMenu = NULL;
static BOOL sEffectFavoritesSwizzleInstalled = NO;

static id FCPBridge_swizzled_effectLibraryItemViewMenu(id self, SEL _cmd) {
    // Call original
    id menu = ((id (*)(id, SEL))sOrigEffectLibraryItemViewMenu)(self, _cmd);

    @try {
        // Get the effect item and its effectID
        id effectItem = ((id (*)(id, SEL))objc_msgSend)(self, NSSelectorFromString(@"effectItem"));
        if (!effectItem) return menu;

        id effectID = ((id (*)(id, SEL))objc_msgSend)(effectItem, NSSelectorFromString(@"effectID"));
        if (!effectID) return menu;

        // Create menu if nil (consumer UI returns nil)
        if (!menu) {
            Class menuClass = NSClassFromString(@"LKMenu") ?: [NSMenu class];
            menu = [[menuClass alloc] initWithTitle:@""];
        }

        // Determine effect type (video or audio) for the favorites API
        Class ffEffectClass = NSClassFromString(@"FFEffect");
        if (!ffEffectClass) return menu;

        SEL typeSel = @selector(effectTypeForEffectID:);
        id effectType = ((id (*)(id, SEL, id))objc_msgSend)((id)ffEffectClass, typeSel, effectID);

        BOOL isAudio = effectType && [effectType isEqualToString:@"effect.audio.effect"];
        BOOL isVideo = effectType && ([effectType isEqualToString:@"effect.video.filter"] ||
                       [effectType isEqualToString:@"effect.video.transition"] ||
                       [effectType isEqualToString:@"effect.video.title"] ||
                       [effectType isEqualToString:@"effect.video.generator"]);

        if (!isAudio && !isVideo) return menu;

        // Check if already favorited
        NSArray *favorites = ((id (*)(id, SEL, BOOL, BOOL, BOOL))objc_msgSend)(
            (id)ffEffectClass, NSSelectorFromString(@"favoriteEffectIDs:video:filterUnregisteredEffects:"),
            NO, isVideo, NO);
        BOOL isFavorite = [favorites containsObject:effectID];

        // Add separator before our items
        if ([menu numberOfItems] > 0) {
            [menu addItem:[NSMenuItem separatorItem]];
        }

        // Add the favorite/unfavorite menu item
        if (isFavorite) {
            NSString *title = isAudio ? @"Remove from Audio Favorites" : @"Remove from Favorites";
            SEL action = isAudio
                ? NSSelectorFromString(@"removeFavoriteAudioEffect:")
                : NSSelectorFromString(@"removeFavoriteVideoEffect:");
            [menu addItemWithTitle:title action:action keyEquivalent:@""];
        } else {
            NSString *title = isAudio ? @"Add to Audio Favorites" : @"Add to Favorites";
            SEL action = isAudio
                ? NSSelectorFromString(@"addFavoriteAudioEffect:")
                : NSSelectorFromString(@"addFavoriteVideoEffect:");
            [menu addItemWithTitle:title action:action keyEquivalent:@""];
        }
    } @catch (NSException *e) {
        FCPBridge_log(@"[Favorites] Exception in menu swizzle: %@", e.reason);
    }

    return menu;
}

void FCPBridge_installEffectFavoritesSwizzle(void) {
    if (sEffectFavoritesSwizzleInstalled) return;

    FCPBridge_executeOnMainThread(^{
        if (sEffectFavoritesSwizzleInstalled) return;

        // Try multiple class name variants — FCP may use different names across versions
        const char *classNames[] = {
            "FFEffectLibraryItemView",
            "Flexo.FFEffectLibraryItemView",
            "_TtC5Flexo25FFEffectLibraryItemView",
            NULL
        };

        Class cls = Nil;
        for (int i = 0; classNames[i] != NULL; i++) {
            cls = objc_getClass(classNames[i]);
            if (cls) break;
        }

        // Brute-force search through all loaded classes
        if (!cls) {
            unsigned int classCount = 0;
            Class *allClasses = objc_copyClassList(&classCount);
            if (allClasses) {
                for (unsigned int i = 0; i < classCount; i++) {
                    const char *name = class_getName(allClasses[i]);
                    if (name && strstr(name, "EffectLibraryItemView")) {
                        FCPBridge_log(@"[Favorites] Found candidate class: %s", name);
                        cls = allClasses[i];
                        break;
                    }
                }
                free(allClasses);
            }
        }

        if (!cls) {
            static int retryCount = 0;
            if (retryCount < 15) {
                retryCount++;
                if (retryCount <= 2) {
                    FCPBridge_log(@"[Favorites] EffectLibraryItemView not found, retrying... (%d)", retryCount);
                }
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                    dispatch_get_main_queue(), ^{
                        FCPBridge_installEffectFavoritesSwizzle();
                    });
            } else {
                FCPBridge_log(@"[Favorites] EffectLibraryItemView never loaded after %d attempts", retryCount);
            }
            return;
        }

        SEL menuSel = @selector(menu);
        Method menuMethod = class_getInstanceMethod(cls, menuSel);
        if (!menuMethod) {
            FCPBridge_log(@"[Favorites] -[%s menu] not found", class_getName(cls));
            return;
        }

        sOrigEffectLibraryItemViewMenu = method_setImplementation(
            menuMethod, (IMP)FCPBridge_swizzled_effectLibraryItemViewMenu);
        sEffectFavoritesSwizzleInstalled = YES;
        FCPBridge_log(@"[Favorites] Swizzled -[%s menu] for favorites context menu", class_getName(cls));

        // Swizzle add/remove favorite methods to refresh the view after changes
        NSArray *favSelNames = @[
            @"addFavoriteVideoEffect:",
            @"removeFavoriteVideoEffect:",
            @"addFavoriteAudioEffect:",
            @"removeFavoriteAudioEffect:",
        ];
        for (NSString *selName in favSelNames) {
            SEL favSel = NSSelectorFromString(selName);
            Method favMethod = class_getInstanceMethod(cls, favSel);
            if (!favMethod) continue;
            IMP origFav = method_getImplementation(favMethod);
            method_setImplementation(favMethod,
                imp_implementationWithBlock(^(id self_, id sender) {
                    // Call original
                    ((void (*)(id, SEL, id))origFav)(self_, favSel, sender);

                    // Refresh: rebuild arrangedItems from fresh favorites, then updateFilter
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
                        dispatch_get_main_queue(), ^{
                        @try {
                            // Get this effect's type
                            id effectItem = ((id (*)(id, SEL))objc_msgSend)(self_, NSSelectorFromString(@"effectItem"));
                            if (!effectItem) return;
                            id effID = ((id (*)(id, SEL))objc_msgSend)(effectItem, NSSelectorFromString(@"effectID"));
                            if (!effID) return;
                            Class ffEffect = NSClassFromString(@"FFEffect");
                            id effType = ((id (*)(id, SEL, id))objc_msgSend)((id)ffEffect, @selector(effectTypeForEffectID:), effID);

                            // Walk up to find collection view -> module
                            NSView *v = self_;
                            while (v) {
                                if ([NSStringFromClass([v class]) containsString:@"EffectLibraryCollectionView"]) {
                                    SEL tSel = NSSelectorFromString(@"targetModules");
                                    if (![v respondsToSelector:tSel]) break;
                                    for (id mod in ((id (*)(id, SEL))objc_msgSend)(v, tSel)) {
                                        if (![mod respondsToSelector:NSSelectorFromString(@"updateFilter")]) continue;

                                        // Rebuild arrangedItems with fresh favorites for this type
                                        if (effType && ffEffect) {
                                            BOOL isVideo = ![effType isEqualToString:@"effect.audio.effect"];
                                            NSArray *favIDs = ((id (*)(id, SEL, BOOL, BOOL, BOOL))objc_msgSend)(
                                                (id)ffEffect, NSSelectorFromString(@"favoriteEffectIDs:video:filterUnregisteredEffects:"),
                                                NO, isVideo, YES);
                                            Class itemClass = NSClassFromString(@"FFBKEffectLibraryItem");
                                            if (itemClass) {
                                                NSMutableArray *fresh = [NSMutableArray array];
                                                for (id fid in favIDs) {
                                                    id ft = ((id (*)(id, SEL, id))objc_msgSend)((id)ffEffect, @selector(effectTypeForEffectID:), fid);
                                                    if (!ft || ![ft isEqualToString:effType]) continue;
                                                    id item = ((id (*)(id, SEL, id))objc_msgSend)(
                                                        ((id (*)(id, SEL))objc_msgSend)((id)itemClass, @selector(alloc)),
                                                        NSSelectorFromString(@"initWithEffectID:"), fid);
                                                    if (item) [fresh addObject:item];
                                                }
                                                ((void (*)(id, SEL, id))objc_msgSend)(mod, NSSelectorFromString(@"setArrangedItems:"), fresh);
                                            }
                                        }

                                        ((void (*)(id, SEL))objc_msgSend)(mod, NSSelectorFromString(@"updateFilter"));
                                        break;
                                    }
                                    break;
                                }
                                v = [v superview];
                            }
                        } @catch (NSException *e) {
                            FCPBridge_log(@"[Favorites] Refresh exception: %@", e.reason);
                        }
                    });
                }));
        }
        FCPBridge_log(@"[Favorites] Swizzled add/remove favorite methods for auto-refresh");

        // Also swizzle masterSubitems to inject "Favorites" category in sidebar
        Class folderClass = objc_getClass("FFBKEffectLibraryFolder");
        if (!folderClass) folderClass = FCPBridge_findLoadedClassNamed("FFBKEffectLibraryFolder");
        if (folderClass) {
            // Create a runtime subclass for the Favorites folder
            Class favFolderClass = objc_allocateClassPair(folderClass, "FCPBridgeFavoritesFolder", 0);
            if (favFolderClass) {
                // Override -items to return favorited effects
                IMP itemsImp = imp_implementationWithBlock(^id(id self_) {
                    @try {
                        Class ffEffect = NSClassFromString(@"FFEffect");
                        Class itemClass = NSClassFromString(@"FFBKEffectLibraryItem");
                        if (!ffEffect || !itemClass) {
                            FCPBridge_log(@"[Favorites] items: missing classes");
                            return @[];
                        }

                        // Get effect type from this folder
                        id effType = ((id (*)(id, SEL))objc_msgSend)(self_, NSSelectorFromString(@"effectType"));
                        BOOL isVideo = !(effType && [effType isEqualToString:@"effect.audio.effect"]);

                        NSArray *favIDs = ((id (*)(id, SEL, BOOL, BOOL, BOOL))objc_msgSend)(
                            (id)ffEffect, NSSelectorFromString(@"favoriteEffectIDs:video:filterUnregisteredEffects:"),
                            NO, isVideo, YES);

                        // Filter to only favorites matching this tab's effect type
                        SEL typeSel = @selector(effectTypeForEffectID:);
                        NSMutableArray *items = [NSMutableArray array];
                        for (id effectID in favIDs) {
                            id thisType = ((id (*)(id, SEL, id))objc_msgSend)((id)ffEffect, typeSel, effectID);
                            if (!thisType || ![thisType isEqualToString:effType]) continue;

                            id item = ((id (*)(id, SEL))objc_msgSend)((id)itemClass, @selector(alloc));
                            item = ((id (*)(id, SEL, id))objc_msgSend)(item, NSSelectorFromString(@"initWithEffectID:"), effectID);
                            if (item) {
                                [items addObject:item];
                            }
                        }
                        return items;
                    } @catch (NSException *e) {
                        FCPBridge_log(@"[Favorites] Exception in favorites items: %@", e.reason);
                        return @[];
                    }
                });
                class_addMethod(favFolderClass, NSSelectorFromString(@"items"),
                    itemsImp, "@@:");

                // Override -detailSubitems to return same as items (used by syncToEffectFolder:)
                IMP detailImp = imp_implementationWithBlock(^id(id self_) {
                    return ((id (*)(id, SEL))objc_msgSend)(self_, NSSelectorFromString(@"items"));
                });
                class_addMethod(favFolderClass, NSSelectorFromString(@"detailSubitems"),
                    detailImp, "@@:");

                // Override -itemDisplayName to return "★ Favorites"
                IMP nameImp = imp_implementationWithBlock(^id(id self_) {
                    return @"\u2605 Favorites";
                });
                class_addMethod(favFolderClass, NSSelectorFromString(@"itemDisplayName"),
                    nameImp, "@@:");

                // Override -drawAsTopLevel to return NO (shows as regular sidebar row)
                IMP topLevelImp = imp_implementationWithBlock(^BOOL(id self_) {
                    return NO;
                });
                class_addMethod(favFolderClass, NSSelectorFromString(@"drawAsTopLevel"),
                    topLevelImp, "B@:");

                // Override -hasMasterSubitems to return NO
                IMP noSubImp = imp_implementationWithBlock(^BOOL(id self_) {
                    return NO;
                });
                class_addMethod(favFolderClass, NSSelectorFromString(@"hasMasterSubitems"),
                    noSubImp, "B@:");

                objc_registerClassPair(favFolderClass);
                FCPBridge_log(@"[Favorites] Created FCPBridgeFavoritesFolder runtime class");
            }

            // Swizzle masterSubitems to inject favorites folder at position 0
            SEL masterSel = NSSelectorFromString(@"masterSubitems");
            Method masterMethod = class_getInstanceMethod(folderClass, masterSel);
            if (masterMethod) {
                static IMP sOrigMasterSubitems = NULL;
                sOrigMasterSubitems = method_setImplementation(masterMethod,
                    imp_implementationWithBlock(^id(id self_) {
                        NSMutableArray *result = [((id (*)(id, SEL))sOrigMasterSubitems)(self_, masterSel) mutableCopy];

                        @try {
                            // Only inject at the top-level (not in subcategory folders)
                            id effType = ((id (*)(id, SEL))objc_msgSend)(self_, NSSelectorFromString(@"effectType"));
                            BOOL isSubAll = ((BOOL (*)(id, SEL))objc_msgSend)(self_, NSSelectorFromString(@"isSubcategoryAll"));
                            BOOL isSubNew = ((BOOL (*)(id, SEL))objc_msgSend)(self_, NSSelectorFromString(@"isSubcategoryNew"));
                            id genre = ((id (*)(id, SEL))objc_msgSend)(self_, NSSelectorFromString(@"genre"));

                            if (isSubAll || isSubNew || genre) return result;

                            // Check if there are any favorites for this specific effect type
                            Class ffEffect = NSClassFromString(@"FFEffect");
                            BOOL isVideo = !(effType && [effType isEqualToString:@"effect.audio.effect"]);
                            NSArray *favIDs = ((id (*)(id, SEL, BOOL, BOOL, BOOL))objc_msgSend)(
                                (id)ffEffect, NSSelectorFromString(@"favoriteEffectIDs:video:filterUnregisteredEffects:"),
                                NO, isVideo, YES);

                            // Filter to only favorites matching this tab's type
                            SEL typeSel = @selector(effectTypeForEffectID:);
                            NSUInteger matchCount = 0;
                            for (id fid in favIDs) {
                                id ft = ((id (*)(id, SEL, id))objc_msgSend)((id)ffEffect, typeSel, fid);
                                if (ft && [ft isEqualToString:effType]) matchCount++;
                            }

                            if (matchCount > 0) {
                                Class favClass = objc_getClass("FCPBridgeFavoritesFolder");
                                if (favClass) {
                                    id favFolder = ((id (*)(id, SEL))objc_msgSend)((id)favClass, @selector(alloc));
                                    favFolder = ((id (*)(id, SEL, id, id, BOOL, BOOL))objc_msgSend)(
                                        favFolder,
                                        NSSelectorFromString(@"initWithEffectType:genre:isSubcategoryAll:isSubcategoryNew:"),
                                        effType, nil, YES, NO);
                                    if (favFolder) {
                                        [result insertObject:favFolder atIndex:0];
                                    }
                                }
                            }
                        } @catch (NSException *e) {
                            FCPBridge_log(@"[Favorites] Exception injecting favorites folder: %@", e.reason);
                        }

                        return result;
                    }));
                FCPBridge_log(@"[Favorites] Swizzled -[FFBKEffectLibraryFolder masterSubitems] for sidebar");
            }
        }
    });
}

#pragma mark - Video-Only Keeps Audio Disabled

// When FCP's AV edit mode is "Video Only", the normal behavior strips audio entirely.
// This feature intercepts the four video-only edit methods on FFEditActionMgr and
// instead performs a normal (both A+V) edit, then disables the audio component sources
// on the newly-added clips. The result: clips land with audio present but disabled
// in the inspector, so users can re-enable it later.

static NSString * const kFCPBridgeVideoOnlyKeepsAudioDisabled = @"FCPBridgeVideoOnlyKeepsAudioDisabled";
static IMP sOrigInsertVideo = NULL;
static IMP sOrigAppendVideo = NULL;
static IMP sOrigOverwriteVideo = NULL;
static IMP sOrigAnchorVideo = NULL;
static BOOL sVideoOnlyKeepsAudioInstalled = NO;

BOOL FCPBridge_isVideoOnlyKeepsAudioDisabledEnabled(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kFCPBridgeVideoOnlyKeepsAudioDisabled];
}

void FCPBridge_setVideoOnlyKeepsAudioDisabledEnabled(BOOL enabled) {
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:kFCPBridgeVideoOnlyKeepsAudioDisabled];
    if (enabled) {
        FCPBridge_installVideoOnlyKeepsAudioDisabled();
    }
    FCPBridge_log(@"[VideoOnlyKeepsAudio] %@", enabled ? @"Enabled" : @"Disabled");
}

// Get selected items from the timeline module (snapshot for before/after comparison)
static NSArray *FCPBridge_videoOnlyGetSelectedItems(id timelineModule) {
    if (!timelineModule) return @[];
    SEL sel = NSSelectorFromString(@"selectedItems");
    if (![timelineModule respondsToSelector:sel]) return @[];
    id items = ((id (*)(id, SEL))objc_msgSend)(timelineModule, sel);
    return [items isKindOfClass:[NSArray class]] ? [items copy] : @[];
}

// Build a set of pointer values for fast identity comparison
static NSSet *FCPBridge_videoOnlyPointerSet(NSArray *items) {
    NSMutableSet *set = [NSMutableSet setWithCapacity:items.count];
    for (id item in items) {
        [set addObject:[NSValue valueWithNonretainedObject:item]];
    }
    return set;
}

// Disable audio component sources on clips that are in selectedAfter but not in selectedBefore
static void FCPBridge_videoOnlyDisableNewClipAudio(id timelineModule, NSArray *selectedBefore) {
    if (!timelineModule) return;

    NSArray *selectedAfter = FCPBridge_videoOnlyGetSelectedItems(timelineModule);
    if (!selectedAfter.count) return;

    NSSet *beforeSet = FCPBridge_videoOnlyPointerSet(selectedBefore);

    // Get the sequence for undo grouping
    id sequence = nil;
    SEL seqSel = NSSelectorFromString(@"sequence");
    if ([timelineModule respondsToSelector:seqSel]) {
        sequence = ((id (*)(id, SEL))objc_msgSend)(timelineModule, seqSel);
    }

    // Begin undoable action
    NSString *actionName = @"Disable Audio";
    if (sequence) {
        SEL beginSel = NSSelectorFromString(@"actionBegin:");
        if ([sequence respondsToSelector:beginSel]) {
            ((void (*)(id, SEL, id))objc_msgSend)(sequence, beginSel, actionName);
        }
    }

    NSInteger disabledCount = 0;
    for (id clip in selectedAfter) {
        if ([beforeSet containsObject:[NSValue valueWithNonretainedObject:clip]])
            continue; // Not a new clip

        SEL hasSel = NSSelectorFromString(@"hasAudioComponentSources");
        if (![clip respondsToSelector:hasSel]) continue;
        if (!((BOOL (*)(id, SEL))objc_msgSend)(clip, hasSel)) continue;

        // Get all audio component sources (0 = all, not just active)
        SEL acsSel = NSSelectorFromString(@"audioComponentSources:");
        if (![clip respondsToSelector:acsSel]) continue;
        id sources = ((id (*)(id, SEL, unsigned int))objc_msgSend)(clip, acsSel, (unsigned int)0);
        if (![sources isKindOfClass:[NSArray class]]) continue;

        for (id source in (NSArray *)sources) {
            SEL enabledSel = NSSelectorFromString(@"enabled");
            if (![source respondsToSelector:enabledSel]) continue;
            if (!((BOOL (*)(id, SEL))objc_msgSend)(source, enabledSel)) continue;

            SEL setEnabledSel = NSSelectorFromString(@"setEnabled:");
            if ([source respondsToSelector:setEnabledSel]) {
                ((void (*)(id, SEL, BOOL))objc_msgSend)(source, setEnabledSel, NO);
                disabledCount++;
            }
        }
    }

    // End undoable action
    if (sequence) {
        SEL endSel = NSSelectorFromString(@"actionEnd:save:error:");
        if ([sequence respondsToSelector:endSel]) {
            ((void (*)(id, SEL, id, BOOL, id))objc_msgSend)(
                sequence, endSel, actionName, YES, nil);
        }
    }

    if (disabledCount > 0) {
        FCPBridge_log(@"[VideoOnlyKeepsAudio] Disabled %ld audio component sources on new clips",
                      (long)disabledCount);
    }
}

// --- Swizzled edit methods ---
// Each intercepts the video-only variant, calls the "both" variant instead,
// then disables audio on newly-added clips.

static void FCPBridge_swizzled_insertWithSelectedMediaVideo(id self, SEL _cmd, id sender) {
    if (!FCPBridge_isVideoOnlyKeepsAudioDisabledEnabled()) {
        ((void (*)(id, SEL, id))sOrigInsertVideo)(self, _cmd, sender);
        return;
    }
    id timeline = FCPBridge_getActiveTimelineModule();
    NSArray *before = FCPBridge_videoOnlyGetSelectedItems(timeline);
    ((void (*)(id, SEL, id))objc_msgSend)(self, NSSelectorFromString(@"insertWithSelectedMedia:"), sender);
    FCPBridge_videoOnlyDisableNewClipAudio(timeline, before);
}

static void FCPBridge_swizzled_appendWithSelectedMediaVideo(id self, SEL _cmd, id sender) {
    if (!FCPBridge_isVideoOnlyKeepsAudioDisabledEnabled()) {
        ((void (*)(id, SEL, id))sOrigAppendVideo)(self, _cmd, sender);
        return;
    }
    id timeline = FCPBridge_getActiveTimelineModule();
    NSArray *before = FCPBridge_videoOnlyGetSelectedItems(timeline);
    ((void (*)(id, SEL, id))objc_msgSend)(self, NSSelectorFromString(@"appendWithSelectedMedia:"), sender);
    FCPBridge_videoOnlyDisableNewClipAudio(timeline, before);
}

static void FCPBridge_swizzled_overwriteWithSelectedMediaVideo(id self, SEL _cmd, id sender) {
    if (!FCPBridge_isVideoOnlyKeepsAudioDisabledEnabled()) {
        ((void (*)(id, SEL, id))sOrigOverwriteVideo)(self, _cmd, sender);
        return;
    }
    id timeline = FCPBridge_getActiveTimelineModule();
    NSArray *before = FCPBridge_videoOnlyGetSelectedItems(timeline);
    ((void (*)(id, SEL, id))objc_msgSend)(self, NSSelectorFromString(@"overwriteWithSelectedMedia:"), sender);
    FCPBridge_videoOnlyDisableNewClipAudio(timeline, before);
}

static void FCPBridge_swizzled_anchorWithSelectedMediaVideo(id self, SEL _cmd, id sender) {
    if (!FCPBridge_isVideoOnlyKeepsAudioDisabledEnabled()) {
        ((void (*)(id, SEL, id))sOrigAnchorVideo)(self, _cmd, sender);
        return;
    }
    id timeline = FCPBridge_getActiveTimelineModule();
    NSArray *before = FCPBridge_videoOnlyGetSelectedItems(timeline);
    ((void (*)(id, SEL, id))objc_msgSend)(self, NSSelectorFromString(@"anchorWithSelectedMedia:"), sender);
    FCPBridge_videoOnlyDisableNewClipAudio(timeline, before);
}

void FCPBridge_installVideoOnlyKeepsAudioDisabled(void) {
    if (sVideoOnlyKeepsAudioInstalled) return;
    if (!FCPBridge_isVideoOnlyKeepsAudioDisabledEnabled()) return;

    Class cls = objc_getClass("FFEditActionMgr");
    if (!cls) {
        FCPBridge_log(@"[VideoOnlyKeepsAudio] FFEditActionMgr class not found");
        return;
    }

    struct { SEL sel; IMP *origPtr; IMP newImp; } swizzles[] = {
        { NSSelectorFromString(@"insertWithSelectedMediaVideo:"),
          &sOrigInsertVideo,
          (IMP)FCPBridge_swizzled_insertWithSelectedMediaVideo },
        { NSSelectorFromString(@"appendWithSelectedMediaVideo:"),
          &sOrigAppendVideo,
          (IMP)FCPBridge_swizzled_appendWithSelectedMediaVideo },
        { NSSelectorFromString(@"overwriteWithSelectedMediaVideo:"),
          &sOrigOverwriteVideo,
          (IMP)FCPBridge_swizzled_overwriteWithSelectedMediaVideo },
        { NSSelectorFromString(@"anchorWithSelectedMediaVideo:"),
          &sOrigAnchorVideo,
          (IMP)FCPBridge_swizzled_anchorWithSelectedMediaVideo },
    };

    for (int i = 0; i < 4; i++) {
        Method m = class_getInstanceMethod(cls, swizzles[i].sel);
        if (m && !*swizzles[i].origPtr) {
            *swizzles[i].origPtr = method_setImplementation(m, swizzles[i].newImp);
            FCPBridge_log(@"[VideoOnlyKeepsAudio] Swizzled -[FFEditActionMgr %@]",
                          NSStringFromSelector(swizzles[i].sel));
        }
    }

    sVideoOnlyKeepsAudioInstalled = YES;
    FCPBridge_log(@"[VideoOnlyKeepsAudio] Swizzle installed");
}

#pragma mark - Transition Handlers

NSDictionary *FCPBridge_handleTransitionsList(NSDictionary *params) {
    NSString *filter = params[@"filter"];

    __block NSDictionary *result = nil;
    FCPBridge_executeOnMainThread(^{
        @try {
            Class ffEffect = objc_getClass("FFEffect");
            if (!ffEffect) { result = @{@"error": @"FFEffect class not found"}; return; }

            // Get all user-visible effect IDs
            id allIDs = ((id (*)(id, SEL))objc_msgSend)((id)ffEffect, @selector(userVisibleEffectIDs));
            if (!allIDs) { result = @{@"error": @"No effect IDs returned"}; return; }

            SEL typeSel = @selector(effectTypeForEffectID:);
            SEL nameSel = @selector(displayNameForEffectID:);
            SEL catSel = @selector(categoryForEffectID:);

            NSMutableArray *transitions = [NSMutableArray array];
            NSString *transitionType = @"effect.video.transition";

            for (NSString *effectID in allIDs) {
                @autoreleasepool {
                    id type = ((id (*)(id, SEL, id))objc_msgSend)((id)ffEffect, typeSel, effectID);
                    if (![type isKindOfClass:[NSString class]]) continue;
                    if (![(NSString *)type isEqualToString:transitionType]) continue;

                    id name = ((id (*)(id, SEL, id))objc_msgSend)((id)ffEffect, nameSel, effectID);
                    id category = ((id (*)(id, SEL, id))objc_msgSend)((id)ffEffect, catSel, effectID);

                    NSString *displayName = [name isKindOfClass:[NSString class]] ? (NSString *)name : @"Unknown";
                    NSString *catName = [category isKindOfClass:[NSString class]] ? (NSString *)category : @"";

                    // Apply name filter if provided
                    if (filter.length > 0) {
                        NSString *lowerFilter = [filter lowercaseString];
                        BOOL matches = [[displayName lowercaseString] containsString:lowerFilter] ||
                                       [[catName lowercaseString] containsString:lowerFilter];
                        if (!matches) continue;
                    }

                    [transitions addObject:@{
                        @"name": displayName,
                        @"effectID": effectID,
                        @"category": catName,
                    }];
                }
            }

            // Sort by name
            [transitions sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
                return [a[@"name"] compare:b[@"name"]];
            }];

            // Get the current default
            id defaultID = ((id (*)(id, SEL))objc_msgSend)((id)ffEffect,
                @selector(defaultVideoTransitionEffectID));
            NSString *defaultName = @"";
            if (defaultID) {
                id dn = ((id (*)(id, SEL, id))objc_msgSend)((id)ffEffect, nameSel, defaultID);
                if ([dn isKindOfClass:[NSString class]]) defaultName = dn;
            }

            result = @{
                @"transitions": transitions,
                @"count": @(transitions.count),
                @"defaultTransition": @{
                    @"name": defaultName,
                    @"effectID": defaultID ?: @"",
                },
            };
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result ?: @{@"error": @"Failed to list transitions"};
}

NSDictionary *FCPBridge_handleTransitionsApply(NSDictionary *params) {
    NSString *effectID = params[@"effectID"];
    NSString *name = params[@"name"];
    BOOL freezeExtend = params[@"freezeExtend"] ? [params[@"freezeExtend"] boolValue] : YES;

    if (!effectID && !name) {
        return @{@"error": @"effectID or name parameter required"};
    }

    __block NSDictionary *result = nil;
    __block NSString *resolvedID = effectID;

    FCPBridge_executeOnMainThread(^{
        @try {
            Class ffEffect = objc_getClass("FFEffect");
            if (!ffEffect) { result = @{@"error": @"FFEffect class not found"}; return; }

            // Resolve name -> effectID if needed
            if (!resolvedID && name) {
                id allIDs = ((id (*)(id, SEL))objc_msgSend)((id)ffEffect, @selector(userVisibleEffectIDs));
                SEL typeSel = @selector(effectTypeForEffectID:);
                SEL nameSel = @selector(displayNameForEffectID:);
                NSString *transitionType = @"effect.video.transition";
                NSString *lowerName = [name lowercaseString];

                // Exact match first
                for (NSString *eid in allIDs) {
                    id type = ((id (*)(id, SEL, id))objc_msgSend)((id)ffEffect, typeSel, eid);
                    if (![type isKindOfClass:[NSString class]] ||
                        ![(NSString *)type isEqualToString:transitionType]) continue;
                    id dn = ((id (*)(id, SEL, id))objc_msgSend)((id)ffEffect, nameSel, eid);
                    if ([dn isKindOfClass:[NSString class]] &&
                        [[(NSString *)dn lowercaseString] isEqualToString:lowerName]) {
                        resolvedID = eid;
                        break;
                    }
                }
                // Partial match fallback
                if (!resolvedID) {
                    for (NSString *eid in allIDs) {
                        id type = ((id (*)(id, SEL, id))objc_msgSend)((id)ffEffect, typeSel, eid);
                        if (![type isKindOfClass:[NSString class]] ||
                            ![(NSString *)type isEqualToString:transitionType]) continue;
                        id dn = ((id (*)(id, SEL, id))objc_msgSend)((id)ffEffect, nameSel, eid);
                        if ([dn isKindOfClass:[NSString class]] &&
                            [[(NSString *)dn lowercaseString] containsString:lowerName]) {
                            resolvedID = eid;
                            break;
                        }
                    }
                }
                if (!resolvedID) {
                    result = @{@"error": [NSString stringWithFormat:@"No transition found matching '%@'", name]};
                    return;
                }
            }

            // Save the current default transition
            id originalDefault = ((id (*)(id, SEL))objc_msgSend)((id)ffEffect,
                @selector(defaultVideoTransitionEffectID));

            // Set the new default via NSUserDefaults
            [[NSUserDefaults standardUserDefaults] setObject:resolvedID
                                                      forKey:@"FFDefaultVideoTransition"];

            // Call addTransition: on the timeline module
            id timelineModule = FCPBridge_getActiveTimelineModule();
            if (!timelineModule) {
                // Restore default
                if (originalDefault) {
                    [[NSUserDefaults standardUserDefaults] setObject:originalDefault
                                                              forKey:@"FFDefaultVideoTransition"];
                }
                result = @{@"error": @"No active timeline module"};
                return;
            }

            NSUInteger transitionsBefore = FCPBridge_transitionCount(timelineModule);

            // When freezeExtend is enabled, detect whether the clips at the edit
            // point are shorter than the default transition duration.  If so,
            // temporarily reduce the duration via NSUserDefaults so that FCP's
            // internal range calculations can succeed, and pre-force overlapType=2
            // so FCP uses freeze-frame paths on the very first pass (avoiding the
            // "not enough extra media" dialog entirely when possible).
            if (freezeExtend) {
                // Freeze-extend auto-hold is disabled pending further development.
                // Just set the fallback auto-accept flag for the API path.
                sFreezeExtendPendingAutoAccept = YES;
                sFreezeExtendDidApply = NO;
            }
            if (NO && freezeExtend) {
                // DISABLED: Add hold-frame media handles to short clips BEFORE adding the
                // transition. retimeHold: (Shift+H) adds a hold
                // segment to a clip's retime curve, extending its available media
                // with frozen edge frames. We then trim the clip back to its
                // original duration — the hold frames become hidden handles that
                // FCP uses for the transition overlap.
                double frame = FCPBridge_transitionFrameDurationSeconds(timelineModule);
                double defaultDur = FCPBridge_defaultTransitionDurationSeconds(timelineModule);
                double halfTransition = defaultDur / 2.0;
                double editPointTime = FCPBridge_transitionCurrentTimeSeconds(timelineModule);

                // Scan adjacent clips via sequence->primaryObject->containedItems
                id sequence = [timelineModule respondsToSelector:@selector(sequence)]
                    ? ((id (*)(id, SEL))objc_msgSend)(timelineModule, @selector(sequence))
                    : nil;
                id primaryObj = nil;
                NSArray *items = nil;
                if (sequence) {
                    primaryObj = [sequence respondsToSelector:@selector(primaryObject)]
                        ? ((id (*)(id, SEL))objc_msgSend)(sequence, @selector(primaryObject))
                        : nil;
                    if (primaryObj && [primaryObj respondsToSelector:@selector(containedItems)])
                        items = ((id (*)(id, SEL))objc_msgSend)(primaryObj, @selector(containedItems));
                }

                SEL erSel = NSSelectorFromString(@"effectiveRangeOfObject:");
                BOOL canGetRange = primaryObj && [primaryObj respondsToSelector:erSel];
                Class transCls = objc_getClass("FFAnchoredTransition");

                typedef struct { double start; double end; double dur; } ClipInfo;
                ClipInfo leftInfo = {0, 0, DBL_MAX};
                ClipInfo rightInfo = {0, 0, DBL_MAX};

                if (canGetRange && [items isKindOfClass:[NSArray class]]) {
                    for (id item in items) {
                        if (transCls && [item isKindOfClass:transCls]) continue;
                        @try {
                            FCPBridge_CMTimeRange range =
                                ((FCPBridge_CMTimeRange (*)(id, SEL, id))objc_msgSend)(
                                    primaryObj, erSel, item);
                            if (range.duration.timescale <= 0 || range.duration.value <= 0) continue;
                            double s = (double)range.start.value / (double)range.start.timescale;
                            double d = (double)range.duration.value / (double)range.duration.timescale;
                            double e = s + d;
                            if (fabs(e - editPointTime) < frame * 2.0 && d < leftInfo.dur)
                                leftInfo = (ClipInfo){s, e, d};
                            if (fabs(s - editPointTime) < frame * 2.0 && d < rightInfo.dur)
                                rightInfo = (ClipInfo){s, e, d};
                        } @catch (NSException *ex) { continue; }
                    }
                }

                SEL holdSel = NSSelectorFromString(@"retimeHold:");
                BOOL canHold = [timelineModule respondsToSelector:holdSel];
                BOOL didExtend = NO;

                // Extend clips that are shorter than the transition half-overlap
                for (int side = 0; side < 2; side++) {
                    ClipInfo info = (side == 0) ? rightInfo : leftInfo;
                    if (info.dur >= halfTransition || info.dur >= DBL_MAX) continue;
                    if (!canHold) continue;

                    // Position playhead inside the short clip
                    double seekTime = info.start + (info.dur / 2.0);
                    FCPBridge_transitionSeekToSeconds(timelineModule, seekTime);

                    // Select the clip at the playhead
                    FCPBridge_sendTimelineSimpleAction(timelineModule, @"selectClipAtPlayhead:");
                    [[NSRunLoop currentRunLoop] runUntilDate:
                        [NSDate dateWithTimeIntervalSinceNow:0.1]];

                    // Apply retimeHold — adds hold-frame segment extending the
                    // clip's available media with frozen edge frames
                    FCPBridge_log(@"[FreezeExtend] Applying retimeHold to %s clip "
                        @"(dur=%.4f < halfTransition=%.4f) at %.4fs",
                        side == 0 ? "right" : "left", info.dur, halfTransition, seekTime);
                    ((void (*)(id, SEL, id))objc_msgSend)(timelineModule, holdSel, nil);
                    [[NSRunLoop currentRunLoop] runUntilDate:
                        [NSDate dateWithTimeIntervalSinceNow:0.3]];

                    // Trim the clip back to its original end time so the hold
                    // frames become hidden media handles. Select the clip, seek
                    // to its original end, and trim.
                    FCPBridge_sendTimelineSimpleAction(timelineModule, @"selectClipAtPlayhead:");
                    FCPBridge_transitionSeekToSeconds(timelineModule, info.end);
                    FCPBridge_sendTimelineSimpleAction(timelineModule, @"trimEnd:");
                    [[NSRunLoop currentRunLoop] runUntilDate:
                        [NSDate dateWithTimeIntervalSinceNow:0.2]];

                    FCPBridge_log(@"[FreezeExtend] Hold applied and trimmed back to %.4fs", info.end);
                    didExtend = YES;
                }

                if (didExtend) {
                    // Deselect and navigate back to the edit point
                    FCPBridge_sendTimelineSimpleAction(timelineModule, @"deselectAll:");
                    FCPBridge_transitionSeekToSeconds(timelineModule, MAX(0, editPointTime - frame));
                    FCPBridge_sendTimelineSimpleAction(timelineModule, @"nextEdit:");
                    [[NSRunLoop currentRunLoop] runUntilDate:
                        [NSDate dateWithTimeIntervalSinceNow:0.2]];
                    FCPBridge_log(@"[FreezeExtend] Repositioned at edit point");
                    transitionsBefore = FCPBridge_transitionCount(timelineModule);
                }

                // Fallback auto-accept in case FCP still shows the dialog
                sFreezeExtendPendingAutoAccept = YES;
                sFreezeExtendDidApply = NO;
            }

            SEL addSel = @selector(addTransition:);
            if ([timelineModule respondsToSelector:addSel]) {
                ((void (*)(id, SEL, id))objc_msgSend)(timelineModule, addSel, nil);
            } else {
                [[NSApplication sharedApplication] sendAction:addSel to:nil from:nil];
            }

            BOOL inserted = FCPBridge_waitForTransitionInsertion(
                timelineModule, transitionsBefore, freezeExtend ? 2.0 : 0.5);
            BOOL freezeExtended = sFreezeExtendDidApply;
            sFreezeExtendDidApply = NO;
            FCPBridge_clearFreezeExtendTransientState();

            // Restore the original default transition
            if (originalDefault) {
                [[NSUserDefaults standardUserDefaults] setObject:originalDefault
                                                          forKey:@"FFDefaultVideoTransition"];
            }

            if (!inserted) {
                result = @{@"error": @"No transition was inserted at the current edit point"};
                return;
            }

            // Get the display name of what we applied
            id appliedName = ((id (*)(id, SEL, id))objc_msgSend)((id)ffEffect,
                @selector(displayNameForEffectID:), resolvedID);

            result = @{
                @"status": @"ok",
                @"transition": [appliedName isKindOfClass:[NSString class]] ? appliedName : @"Unknown",
                @"effectID": resolvedID,
                @"freezeExtended": @(freezeExtended),
            };
        } @catch (NSException *e) {
            sFreezeExtendDidApply = NO;
            FCPBridge_clearFreezeExtendTransientState();
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });

    return result ?: @{@"error": @"Failed to apply transition"};
}

#pragma mark - Command Palette Handlers

static NSDictionary *FCPBridge_handleCommandShow(NSDictionary *params) {
    FCPBridge_executeOnMainThread(^{
        [[FCPCommandPalette sharedPalette] showPalette];
    });
    return @{@"status": @"ok"};
}

static NSDictionary *FCPBridge_handleCommandHide(NSDictionary *params) {
    FCPBridge_executeOnMainThread(^{
        [[FCPCommandPalette sharedPalette] hidePalette];
    });
    return @{@"status": @"ok"};
}

static NSDictionary *FCPBridge_handleCommandSearch(NSDictionary *params) {
    NSString *query = params[@"query"] ?: @"";
    NSArray<FCPCommand *> *results = [[FCPCommandPalette sharedPalette] searchCommands:query];
    NSMutableArray *items = [NSMutableArray array];
    NSUInteger limit = [params[@"limit"] unsignedIntegerValue] ?: 20;
    for (NSUInteger i = 0; i < MIN(results.count, limit); i++) {
        FCPCommand *cmd = results[i];
        [items addObject:@{
            @"name": cmd.name ?: @"",
            @"action": cmd.action ?: @"",
            @"type": cmd.type ?: @"",
            @"category": cmd.categoryName ?: @"",
            @"detail": cmd.detail ?: @"",
            @"shortcut": cmd.shortcut ?: @"",
            @"score": @(cmd.score),
        }];
    }
    return @{@"commands": items, @"total": @(results.count)};
}

static NSDictionary *FCPBridge_handleCommandExecute(NSDictionary *params) {
    NSString *action = params[@"action"];
    NSString *type = params[@"type"] ?: @"timeline";
    if (!action) return @{@"error": @"action parameter required"};
    return [[FCPCommandPalette sharedPalette] executeCommand:action type:type];
}

static NSDictionary *FCPBridge_handleCommandAI(NSDictionary *params) {
    NSString *query = params[@"query"];
    if (!query) return @{@"error": @"query parameter required"};

    __block NSDictionary *result = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);

    [[FCPCommandPalette sharedPalette] executeNaturalLanguage:query
        completion:^(NSArray<NSDictionary *> *actions, NSString *error) {
            if (error) {
                result = @{@"error": error};
            } else {
                result = @{@"actions": actions ?: @[], @"count": @(actions.count)};
            }
            dispatch_semaphore_signal(sem);
        }];

    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC));
    return result ?: @{@"error": @"AI request timed out"};
}

#pragma mark - Browser Clip Handlers

// List clips available in the event browser
static NSDictionary *FCPBridge_handleBrowserListClips(NSDictionary *params) {
    __block NSDictionary *result = nil;

    FCPBridge_executeOnMainThread(^{
        @try {
            // Get active library -> events -> clips
            id libs = ((id (*)(id, SEL))objc_msgSend)(
                objc_getClass("FFLibraryDocument"), @selector(copyActiveLibraries));
            if (![libs isKindOfClass:[NSArray class]] || [(NSArray *)libs count] == 0) {
                result = @{@"error": @"No active library"};
                return;
            }

            id library = [(NSArray *)libs firstObject];

            // Get events from library — events are FFFolder objects
            SEL eventsSel = NSSelectorFromString(@"events");
            if (![library respondsToSelector:eventsSel]) {
                result = @{@"error": @"Library does not respond to events"};
                return;
            }
            id events = ((id (*)(id, SEL))objc_msgSend)(library, eventsSel);
            if (![events isKindOfClass:[NSArray class]] || [(NSArray *)events count] == 0) {
                result = @{@"error": @"No events in library"};
                return;
            }

            NSMutableArray *allClips = [NSMutableArray array];
            NSInteger clipIndex = 0;

            for (id event in (NSArray *)events) {
                NSString *eventName = @"";
                if ([event respondsToSelector:@selector(displayName)])
                    eventName = ((id (*)(id, SEL))objc_msgSend)(event, @selector(displayName)) ?: @"";

                // Events are FFFolder objects. Get their child items which are event clips.
                // Try multiple approaches: childItems, items, ownedClips, containedItems
                id clips = nil;
                SEL childItemsSel = NSSelectorFromString(@"childItems");
                SEL ownedClipsSel = NSSelectorFromString(@"ownedClips");
                SEL itemsSel = NSSelectorFromString(@"items");

                // Try displayOwnedClips first (browser-visible clips), then ownedClips
                SEL displayClipsSel = NSSelectorFromString(@"displayOwnedClips");
                if ([event respondsToSelector:displayClipsSel]) {
                    clips = ((id (*)(id, SEL))objc_msgSend)(event, displayClipsSel);
                } else if ([event respondsToSelector:ownedClipsSel]) {
                    clips = ((id (*)(id, SEL))objc_msgSend)(event, ownedClipsSel);
                } else if ([event respondsToSelector:childItemsSel]) {
                    clips = ((id (*)(id, SEL))objc_msgSend)(event, childItemsSel);
                } else if ([event respondsToSelector:itemsSel]) {
                    clips = ((id (*)(id, SEL))objc_msgSend)(event, itemsSel);
                }

                // Convert NSSet to NSArray if needed
                if (clips && [clips isKindOfClass:[NSSet class]]) {
                    clips = [(NSSet *)clips allObjects];
                }

                NSUInteger clipCount = [clips isKindOfClass:[NSArray class]] ? [(NSArray *)clips count] : 0;
                FCPBridge_log(@"[Browser] Event '%@' class=%@ clips=%@ count=%lu",
                    eventName, NSStringFromClass([event class]),
                    clips ? NSStringFromClass([clips class]) : @"nil",
                    (unsigned long)clipCount);

                if (![clips isKindOfClass:[NSArray class]]) continue;

                for (id clip in (NSArray *)clips) {
                    NSMutableDictionary *info = [NSMutableDictionary dictionary];
                    info[@"index"] = @(clipIndex++);
                    info[@"event"] = eventName;
                    info[@"class"] = NSStringFromClass([clip class]);

                    if ([clip respondsToSelector:@selector(displayName)]) {
                        id name = ((id (*)(id, SEL))objc_msgSend)(clip, @selector(displayName));
                        info[@"name"] = name ?: @"";
                    }
                    if ([clip respondsToSelector:@selector(duration)]) {
                        FCPBridge_CMTime d = ((FCPBridge_CMTime (*)(id, SEL))objc_msgSend)(clip, @selector(duration));
                        info[@"duration"] = FCPBridge_serializeCMTime(d);
                    }

                    NSString *handle = FCPBridge_storeHandle(clip);
                    info[@"handle"] = handle;
                    [allClips addObject:info];
                }
            }

            result = @{@"clips": allClips, @"count": @(allClips.count)};
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result ?: @{@"error": @"Failed to list browser clips"};
}

// Append a clip from the event browser to the timeline
static NSDictionary *FCPBridge_handleBrowserAppendClip(NSDictionary *params) {
    NSString *handle = params[@"handle"];
    NSNumber *indexNum = params[@"index"];
    NSString *name = params[@"name"];

    __block NSDictionary *result = nil;

    FCPBridge_executeOnMainThread(^{
        @try {
            id clip = nil;

            // Resolve clip by handle, index, or name
            if (handle) {
                clip = FCPBridge_resolveHandle(handle);
            }

            if (!clip && (indexNum || name)) {
                // Get all clips and find by index or name
                id libs = ((id (*)(id, SEL))objc_msgSend)(
                    objc_getClass("FFLibraryDocument"), @selector(copyActiveLibraries));
                if ([libs isKindOfClass:[NSArray class]] && [(NSArray *)libs count] > 0) {
                    id library = [(NSArray *)libs firstObject];
                    SEL eventsSel = NSSelectorFromString(@"events");
                    if ([library respondsToSelector:eventsSel]) {
                        id events = ((id (*)(id, SEL))objc_msgSend)(library, eventsSel);
                        NSInteger targetIdx = indexNum ? [indexNum integerValue] : -1;
                        NSString *lowerName = [name lowercaseString];
                        NSInteger currentIdx = 0;

                        for (id event in (NSArray *)events) {
                            SEL clipsSel = NSSelectorFromString(@"ownedClips");
                            if (![event respondsToSelector:clipsSel]) continue;
                            id clips = ((id (*)(id, SEL))objc_msgSend)(event, clipsSel);
                            if (![clips isKindOfClass:[NSArray class]]) continue;

                            for (id c in (NSArray *)clips) {
                                if (currentIdx == targetIdx) { clip = c; break; }
                                if (name && [c respondsToSelector:@selector(displayName)]) {
                                    NSString *dn = ((id (*)(id, SEL))objc_msgSend)(c, @selector(displayName));
                                    if (dn && [[dn lowercaseString] containsString:lowerName]) {
                                        clip = c;
                                        break;
                                    }
                                }
                                currentIdx++;
                            }
                            if (clip) break;
                        }
                    }
                }
            }

            if (!clip) {
                result = @{@"error": @"Clip not found. Provide handle, index, or name."};
                return;
            }

            // Get the organizer filmstrip module and select this clip
            id app = ((id (*)(id, SEL))objc_msgSend)(
                objc_getClass("NSApplication"), @selector(sharedApplication));
            id delegate = ((id (*)(id, SEL))objc_msgSend)(app, @selector(delegate));

            // Try to get the media browser and select the clip
            SEL browserSel = NSSelectorFromString(@"mediaBrowserContainerModule");
            id browserContainer = nil;
            if ([delegate respondsToSelector:browserSel]) {
                browserContainer = ((id (*)(id, SEL))objc_msgSend)(delegate, browserSel);
            }

            // Create a media range for the full clip and select it in the browser
            // Use FigTimeRangeAndObject to wrap the clip
            Class rangeObjClass = objc_getClass("FigTimeRangeAndObject");
            if (rangeObjClass && clip) {
                // Get the clip's clipped range
                FCPBridge_CMTimeRange clipRange = {0};
                if ([clip respondsToSelector:@selector(clippedRange)]) {
                    clipRange = ((FCPBridge_CMTimeRange (*)(id, SEL))objc_msgSend)(clip, @selector(clippedRange));
                } else if ([clip respondsToSelector:@selector(duration)]) {
                    FCPBridge_CMTime dur = ((FCPBridge_CMTime (*)(id, SEL))objc_msgSend)(clip, @selector(duration));
                    clipRange.start = (FCPBridge_CMTime){0, dur.timescale, 1, 0};
                    clipRange.duration = dur;
                }

                SEL rangeAndObjSel = NSSelectorFromString(@"rangeAndObjectWithRange:andObject:");
                if ([(id)rangeObjClass respondsToSelector:rangeAndObjSel]) {
                    id mediaRange = ((id (*)(id, SEL, FCPBridge_CMTimeRange, id))objc_msgSend)(
                        (id)rangeObjClass, rangeAndObjSel, clipRange, clip);

                    if (mediaRange) {
                        // Select the media range in the browser filmstrip
                        SEL filmstripSel = NSSelectorFromString(@"filmstripModule");
                        id filmstrip = nil;
                        if (browserContainer && [browserContainer respondsToSelector:filmstripSel]) {
                            filmstrip = ((id (*)(id, SEL))objc_msgSend)(browserContainer, filmstripSel);
                        }
                        if (!filmstrip) {
                            // Try getting through organizer
                            SEL orgSel = NSSelectorFromString(@"organizerModule");
                            id organizer = [delegate respondsToSelector:orgSel]
                                ? ((id (*)(id, SEL))objc_msgSend)(delegate, orgSel) : nil;
                            if (organizer) {
                                SEL itemsSel = NSSelectorFromString(@"itemsModule");
                                filmstrip = [organizer respondsToSelector:itemsSel]
                                    ? ((id (*)(id, SEL))objc_msgSend)(organizer, itemsSel) : nil;
                            }
                        }

                        if (filmstrip) {
                            SEL selectSel = NSSelectorFromString(@"_selectMediaRanges:");
                            if ([filmstrip respondsToSelector:selectSel]) {
                                NSArray *ranges = @[mediaRange];
                                ((void (*)(id, SEL, id))objc_msgSend)(filmstrip, selectSel, ranges);
                                [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
                            }
                        }
                    }
                }
            }

            // Now simulate pressing E (keycode 14) to append to storyline
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
            FCPBridge_simulateKeyPress(14, @"e", 0); // E key = Append to Storyline
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.3]];

            NSString *clipName = @"";
            if ([clip respondsToSelector:@selector(displayName)])
                clipName = ((id (*)(id, SEL))objc_msgSend)(clip, @selector(displayName)) ?: @"";

            result = @{@"status": @"ok", @"clip": clipName, @"action": @"appendToStoryline"};
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result ?: @{@"error": @"Failed to append clip"};
}

#pragma mark - Menu Execute Handler

static NSDictionary *FCPBridge_handleMenuExecute(NSDictionary *params) {
    NSArray *menuPath = params[@"menuPath"];
    if (!menuPath || menuPath.count < 2) {
        return @{@"error": @"menuPath array required (e.g. [\"File\", \"New\", \"Project...\"])"};
    }

    __block NSDictionary *result = nil;
    FCPBridge_executeOnMainThread(^{
        @try {
            id app = ((id (*)(id, SEL))objc_msgSend)(
                objc_getClass("NSApplication"), @selector(sharedApplication));
            NSMenu *mainMenu = ((id (*)(id, SEL))objc_msgSend)(app, @selector(mainMenu));
            if (!mainMenu) {
                result = @{@"error": @"No main menu found"};
                return;
            }

            // Navigate through the menu hierarchy
            NSMenu *currentMenu = mainMenu;
            NSMenuItem *targetItem = nil;

            for (NSUInteger i = 0; i < menuPath.count; i++) {
                NSString *title = menuPath[i];
                NSMenuItem *item = nil;

                // Search for matching menu item (case-insensitive, trimmed)
                for (NSInteger j = 0; j < [currentMenu numberOfItems]; j++) {
                    NSMenuItem *candidate = [currentMenu itemAtIndex:j];
                    NSString *candidateTitle = [candidate title];
                    // Match exact or without trailing ellipsis/dots
                    if ([candidateTitle caseInsensitiveCompare:title] == NSOrderedSame ||
                        [[candidateTitle stringByReplacingOccurrencesOfString:@"…" withString:@""]
                            caseInsensitiveCompare:
                            [title stringByReplacingOccurrencesOfString:@"..." withString:@""]] == NSOrderedSame ||
                        [[candidateTitle stringByReplacingOccurrencesOfString:@"…" withString:@""]
                            caseInsensitiveCompare:title] == NSOrderedSame) {
                        item = candidate;
                        break;
                    }
                }

                if (!item) {
                    // Build list of available items for error message
                    NSMutableArray *available = [NSMutableArray array];
                    for (NSInteger j = 0; j < [currentMenu numberOfItems]; j++) {
                        NSMenuItem *candidate = [currentMenu itemAtIndex:j];
                        if (![candidate isSeparatorItem]) {
                            [available addObject:[candidate title]];
                        }
                    }
                    result = @{@"error": [NSString stringWithFormat:@"Menu item '%@' not found. Available: %@",
                                title, [available componentsJoinedByString:@", "]]};
                    return;
                }

                if (i == menuPath.count - 1) {
                    // Last item - this is the target
                    targetItem = item;
                } else {
                    // Navigate into submenu
                    NSMenu *submenu = [item submenu];
                    if (!submenu) {
                        result = @{@"error": [NSString stringWithFormat:@"'%@' has no submenu", title]};
                        return;
                    }
                    currentMenu = submenu;
                }
            }

            if (!targetItem) {
                result = @{@"error": @"Target menu item not found"};
                return;
            }

            if (![targetItem isEnabled]) {
                result = @{@"error": [NSString stringWithFormat:@"Menu item '%@' is disabled",
                            [targetItem title]]};
                return;
            }

            // Execute the menu item's action
            SEL action = [targetItem action];
            id target = [targetItem target];
            if (action) {
                if (target) {
                    ((void (*)(id, SEL, id))objc_msgSend)(target, action, targetItem);
                } else {
                    // Send through responder chain
                    ((BOOL (*)(id, SEL, SEL, id, id))objc_msgSend)(
                        app, @selector(sendAction:to:from:), action, nil, targetItem);
                }
                result = @{@"status": @"ok", @"menuItem": [targetItem title],
                          @"action": NSStringFromSelector(action)};
            } else {
                result = @{@"error": @"Menu item has no action"};
            }
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result ?: @{@"error": @"Menu execute failed"};
}

static NSDictionary *FCPBridge_handleMenuList(NSDictionary *params) {
    NSString *menuName = params[@"menu"]; // optional: specific top-level menu
    NSNumber *depth = params[@"depth"] ?: @(2);

    __block NSDictionary *result = nil;
    FCPBridge_executeOnMainThread(^{
        @try {
            id app = ((id (*)(id, SEL))objc_msgSend)(
                objc_getClass("NSApplication"), @selector(sharedApplication));
            NSMenu *mainMenu = ((id (*)(id, SEL))objc_msgSend)(app, @selector(mainMenu));
            if (!mainMenu) {
                result = @{@"error": @"No main menu found"};
                return;
            }

            // Recursive helper to build menu tree
            __block id __weak (^weakBuildMenu)(NSMenu *, int);
            __block id (^buildMenu)(NSMenu *, int);
            weakBuildMenu = buildMenu = ^id(NSMenu *menu, int maxDepth) {
                NSMutableArray *items = [NSMutableArray array];
                for (NSInteger i = 0; i < [menu numberOfItems]; i++) {
                    NSMenuItem *item = [menu itemAtIndex:i];
                    if ([item isSeparatorItem]) continue;

                    NSMutableDictionary *entry = [NSMutableDictionary dictionary];
                    entry[@"title"] = [item title];
                    entry[@"enabled"] = @([item isEnabled]);
                    entry[@"checked"] = @([item state] == NSControlStateValueOn);

                    NSString *shortcut = [item keyEquivalent];
                    if (shortcut.length > 0) {
                        NSMutableString *combo = [NSMutableString string];
                        NSEventModifierFlags mods = [item keyEquivalentModifierMask];
                        if (mods & NSEventModifierFlagCommand) [combo appendString:@"⌘"];
                        if (mods & NSEventModifierFlagShift) [combo appendString:@"⇧"];
                        if (mods & NSEventModifierFlagOption) [combo appendString:@"⌥"];
                        if (mods & NSEventModifierFlagControl) [combo appendString:@"⌃"];
                        [combo appendString:shortcut];
                        entry[@"shortcut"] = combo;
                    }

                    if ([item hasSubmenu] && maxDepth > 0) {
                        entry[@"submenu"] = weakBuildMenu([item submenu], maxDepth - 1);
                    } else if ([item hasSubmenu]) {
                        entry[@"hasSubmenu"] = @YES;
                    }

                    [items addObject:entry];
                }
                return items;
            };

            if (menuName) {
                // Find specific top-level menu
                for (NSInteger i = 0; i < [mainMenu numberOfItems]; i++) {
                    NSMenuItem *item = [mainMenu itemAtIndex:i];
                    if ([[item title] caseInsensitiveCompare:menuName] == NSOrderedSame && [item hasSubmenu]) {
                        result = @{@"menu": menuName, @"items": buildMenu([item submenu], depth.intValue)};
                        return;
                    }
                }
                result = @{@"error": [NSString stringWithFormat:@"Menu '%@' not found", menuName]};
            } else {
                // List all top-level menus
                result = @{@"menus": buildMenu(mainMenu, depth.intValue)};
            }
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result ?: @{@"error": @"Menu list failed"};
}

#pragma mark - Effect Parameter Helpers

// Get the selected clip's effect stack, creating it if needed
static id FCPBridge_getSelectedClipEffectStack(id timeline, id *outClip) {
    if (!timeline) return nil;

    // Get selected items
    NSArray *selected = nil;
    SEL selSel = NSSelectorFromString(@"selectedItems:includeItemBeforePlayheadIfLast:");
    if ([timeline respondsToSelector:selSel]) {
        id r = ((id (*)(id, SEL, BOOL, BOOL))objc_msgSend)(timeline, selSel, NO, YES);
        if ([r isKindOfClass:[NSArray class]]) selected = (NSArray *)r;
    }
    if (!selected || selected.count == 0) return nil;

    id clip = selected[0];
    if (outClip) *outClip = clip;

    // If clip is a collection (compound/storyline), get the first media component's effectStack
    if ([clip isKindOfClass:objc_getClass("FFAnchoredCollection")]) {
        @try {
            id items = [clip valueForKey:@"containedItems"];
            if ([items isKindOfClass:[NSArray class]] && [(NSArray *)items count] > 0) {
                id firstItem = [(NSArray *)items firstObject];
                if ([firstItem respondsToSelector:@selector(effectStack)]) {
                    id es = ((id (*)(id, SEL))objc_msgSend)(firstItem, @selector(effectStack));
                    if (es) { if (outClip) *outClip = firstItem; return es; }
                }
            }
        } @catch (NSException *e) {}
    }

    // Direct effectStack access
    if ([clip respondsToSelector:@selector(effectStack)]) {
        return ((id (*)(id, SEL))objc_msgSend)(clip, @selector(effectStack));
    }
    return nil;
}

// Read a channel's value at a given time (seconds)
static NSDictionary *FCPBridge_readChannel(id channel, double timeSeconds) {
    if (!channel) return nil;
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    info[@"class"] = NSStringFromClass([channel class]);

    @try {
        // Get name
        SEL nameSel = NSSelectorFromString(@"name");
        if ([channel respondsToSelector:nameSel]) {
            id name = ((id (*)(id, SEL))objc_msgSend)(channel, nameSel);
            if (name) info[@"name"] = [name description];
        }
    } @catch (NSException *e) {}

    // Read value at time
    @try {
        SEL valSel = NSSelectorFromString(@"doubleValueAtTime:");
        if ([channel respondsToSelector:valSel]) {
            FCPBridge_CMTime t = {(int64_t)(timeSeconds * 600), 600, 1, 0};
            double val = ((double (*)(id, SEL, FCPBridge_CMTime))objc_msgSend)(channel, valSel, t);
            info[@"value"] = @(val);
        }
    } @catch (NSException *e) {}

    // Read default
    @try {
        SEL defSel = NSSelectorFromString(@"defaultCurveDoubleValue");
        if ([channel respondsToSelector:defSel]) {
            double def = ((double (*)(id, SEL))objc_msgSend)(channel, defSel);
            info[@"default"] = @(def);
        }
    } @catch (NSException *e) {}

    // Read min/max
    @try {
        SEL minSel = NSSelectorFromString(@"minCurveDoubleValue");
        SEL maxSel = NSSelectorFromString(@"maxCurveDoubleValue");
        if ([channel respondsToSelector:minSel])
            info[@"min"] = @(((double (*)(id, SEL))objc_msgSend)(channel, minSel));
        if ([channel respondsToSelector:maxSel])
            info[@"max"] = @(((double (*)(id, SEL))objc_msgSend)(channel, maxSel));
    } @catch (NSException *e) {}

    return info;
}

// Get all channels from an effect recursively
static void FCPBridge_collectChannels(id obj, NSMutableArray *channels, NSString *prefix, int depth) {
    if (!obj || depth > 8) return;

    // If this is itself a channel with a double value, add it
    if ([obj respondsToSelector:NSSelectorFromString(@"doubleValueAtTime:")]) {
        NSString *name = prefix ?: @"";
        @try {
            SEL nSel = NSSelectorFromString(@"name");
            if ([obj respondsToSelector:nSel]) {
                id n = ((id (*)(id, SEL))objc_msgSend)(obj, nSel);
                if (n) name = [n description];
            }
        } @catch (NSException *e) {}

        NSMutableDictionary *ch = [NSMutableDictionary dictionary];
        ch[@"name"] = name;
        ch[@"handle"] = FCPBridge_storeHandle(obj);

        NSDictionary *vals = FCPBridge_readChannel(obj, 0);
        if (vals[@"value"]) ch[@"value"] = vals[@"value"];
        if (vals[@"min"]) ch[@"min"] = vals[@"min"];
        if (vals[@"max"]) ch[@"max"] = vals[@"max"];
        if (vals[@"default"]) ch[@"default"] = vals[@"default"];
        [channels addObject:ch];
    }

    // Try to get sub-channels
    @try {
        SEL subSel = NSSelectorFromString(@"channels");
        if ([obj respondsToSelector:subSel]) {
            id subs = ((id (*)(id, SEL))objc_msgSend)(obj, subSel);
            if ([subs isKindOfClass:[NSArray class]]) {
                for (id sub in (NSArray *)subs) {
                    FCPBridge_collectChannels(sub, channels, nil, depth + 1);
                }
            }
        }
    } @catch (NSException *e) {}
}

#pragma mark - Inspector Handlers

// Helper: read a double from a channel at time=0 (kCMTimeIndefinite for constant)
static double FCPBridge_channelValue(id channel) {
    if (!channel) return 0;
    @try {
        // Use kCMTimeIndefinite: {0, 0, 17, 0} for constant (non-keyframed) value
        FCPBridge_CMTime t = {0, 0, 17, 0};
        SEL sel = NSSelectorFromString(@"curveDoubleValueAtTime:");
        if ([channel respondsToSelector:sel]) {
            return ((double (*)(id, SEL, FCPBridge_CMTime))objc_msgSend)(channel, sel, t);
        }
        sel = NSSelectorFromString(@"doubleValueAtTime:");
        if ([channel respondsToSelector:sel]) {
            return ((double (*)(id, SEL, FCPBridge_CMTime))objc_msgSend)(channel, sel, t);
        }
    } @catch (NSException *e) {}
    return 0;
}

// Helper: set a double on a channel
static BOOL FCPBridge_setChannelValue(id channel, double value) {
    if (!channel) return NO;
    @try {
        FCPBridge_CMTime t = {0, 0, 17, 0}; // kCMTimeIndefinite
        SEL sel = NSSelectorFromString(@"setCurveDoubleValue:atTime:options:");
        if ([channel respondsToSelector:sel]) {
            ((void (*)(id, SEL, double, FCPBridge_CMTime, unsigned int))objc_msgSend)(
                channel, sel, value, t, 0);
            return YES;
        }
    } @catch (NSException *e) {}
    return NO;
}

// Helper: get sub-channel by name (xChannel, yChannel, zChannel)
static id FCPBridge_subChannel(id parentChannel, NSString *axis) {
    if (!parentChannel) return nil;
    @try {
        NSString *selName = [NSString stringWithFormat:@"%@Channel", axis];
        SEL sel = NSSelectorFromString(selName);
        if ([parentChannel respondsToSelector:sel]) {
            return ((id (*)(id, SEL))objc_msgSend)(parentChannel, sel);
        }
    } @catch (NSException *e) {}
    return nil;
}

static NSDictionary *FCPBridge_handleInspectorGet(NSDictionary *params) {
    NSString *property = params[@"property"]; // "all", "compositing", "transform", "audio", "crop", "info", "channels"

    __block NSDictionary *result = nil;
    FCPBridge_executeOnMainThread(^{
        @try {
            id timeline = FCPBridge_getActiveTimelineModule();
            if (!timeline) { result = @{@"error": @"No active timeline module"}; return; }

            id clip = nil;
            id effectStack = FCPBridge_getSelectedClipEffectStack(timeline, &clip);
            if (!clip) { result = @{@"error": @"No clips selected"}; return; }

            NSMutableDictionary *props = [NSMutableDictionary dictionary];

            // Clip info (always included)
            NSMutableDictionary *info = [NSMutableDictionary dictionary];
            info[@"class"] = NSStringFromClass([clip class]);
            @try {
                if ([clip respondsToSelector:@selector(displayName)]) {
                    id n = ((id (*)(id, SEL))objc_msgSend)(clip, @selector(displayName));
                    if (n) info[@"name"] = [n description];
                }
            } @catch (NSException *e) {}
            info[@"hasEffectStack"] = @(effectStack != nil);
            props[@"info"] = info;

            if (!effectStack) {
                result = @{@"properties": props, @"note": @"Clip has no effect stack"};
                return;
            }

            NSString *esHandle = FCPBridge_storeHandle(effectStack);
            props[@"effectStackHandle"] = esHandle;

            // COMPOSITING (opacity, blend mode)
            if (!property || [property isEqualToString:@"all"] || [property isEqualToString:@"compositing"]) {
                NSMutableDictionary *comp = [NSMutableDictionary dictionary];
                @try {
                    SEL blendSel = NSSelectorFromString(@"intrinsicCompositeEffect");
                    id blendEffect = [effectStack respondsToSelector:blendSel]
                        ? ((id (*)(id, SEL))objc_msgSend)(effectStack, blendSel) : nil;
                    if (blendEffect) {
                        id opChan = ((id (*)(id, SEL))objc_msgSend)(blendEffect, NSSelectorFromString(@"opacityChannel"));
                        id bmChan = ((id (*)(id, SEL))objc_msgSend)(blendEffect, NSSelectorFromString(@"blendModeChannel"));
                        if (opChan) {
                            comp[@"opacity"] = @(FCPBridge_channelValue(opChan));
                            comp[@"opacityHandle"] = FCPBridge_storeHandle(opChan);
                        }
                        if (bmChan) comp[@"blendModeHandle"] = FCPBridge_storeHandle(bmChan);
                    } else {
                        comp[@"opacity"] = @(1.0); // default
                    }
                } @catch (NSException *e) { comp[@"error"] = e.reason; }
                props[@"compositing"] = comp;
            }

            // TRANSFORM (position, rotation, scale, anchor)
            if (!property || [property isEqualToString:@"all"] || [property isEqualToString:@"transform"]) {
                NSMutableDictionary *xform = [NSMutableDictionary dictionary];
                @try {
                    SEL xfSel = NSSelectorFromString(@"xform3DEffect");
                    id xfEffect = [effectStack respondsToSelector:xfSel]
                        ? ((id (*)(id, SEL))objc_msgSend)(effectStack, xfSel) : nil;
                    if (xfEffect) {
                        // Position
                        id posCh = nil;
                        @try { posCh = ((id (*)(id, SEL))objc_msgSend)(xfEffect, NSSelectorFromString(@"positionChannel3D")); } @catch(NSException *e) {}
                        if (posCh) {
                            xform[@"positionX"] = @(FCPBridge_channelValue(FCPBridge_subChannel(posCh, @"x")));
                            xform[@"positionY"] = @(FCPBridge_channelValue(FCPBridge_subChannel(posCh, @"y")));
                            xform[@"positionZ"] = @(FCPBridge_channelValue(FCPBridge_subChannel(posCh, @"z")));
                        }
                        // Scale
                        id scaCh = nil;
                        @try { scaCh = ((id (*)(id, SEL))objc_msgSend)(xfEffect, NSSelectorFromString(@"scaleChannel3D")); } @catch(NSException *e) {}
                        if (scaCh) {
                            xform[@"scaleX"] = @(FCPBridge_channelValue(FCPBridge_subChannel(scaCh, @"x")));
                            xform[@"scaleY"] = @(FCPBridge_channelValue(FCPBridge_subChannel(scaCh, @"y")));
                        }
                        // Rotation
                        id rotCh = nil;
                        @try { rotCh = ((id (*)(id, SEL))objc_msgSend)(xfEffect, NSSelectorFromString(@"rotationChannel3D")); } @catch(NSException *e) {}
                        if (rotCh) {
                            xform[@"rotation"] = @(FCPBridge_channelValue(FCPBridge_subChannel(rotCh, @"z")));
                        }
                        // Anchor
                        id ancCh = nil;
                        @try { ancCh = ((id (*)(id, SEL))objc_msgSend)(xfEffect, NSSelectorFromString(@"anchorChannel3D")); } @catch(NSException *e) {}
                        if (ancCh) {
                            xform[@"anchorX"] = @(FCPBridge_channelValue(FCPBridge_subChannel(ancCh, @"x")));
                            xform[@"anchorY"] = @(FCPBridge_channelValue(FCPBridge_subChannel(ancCh, @"y")));
                        }
                    } else {
                        xform[@"positionX"] = @(0); xform[@"positionY"] = @(0);
                        xform[@"scaleX"] = @(100); xform[@"scaleY"] = @(100);
                        xform[@"rotation"] = @(0);
                    }
                } @catch (NSException *e) { xform[@"error"] = e.reason; }
                props[@"transform"] = xform;
            }

            // AUDIO (volume)
            if (!property || [property isEqualToString:@"all"] || [property isEqualToString:@"audio"]) {
                NSMutableDictionary *audio = [NSMutableDictionary dictionary];
                @try {
                    SEL volSel = NSSelectorFromString(@"audioLevelChannel");
                    id volChan = [effectStack respondsToSelector:volSel]
                        ? ((id (*)(id, SEL))objc_msgSend)(effectStack, volSel) : nil;
                    if (volChan) {
                        audio[@"volume"] = @(FCPBridge_channelValue(volChan));
                        audio[@"volumeHandle"] = FCPBridge_storeHandle(volChan);
                    }
                } @catch (NSException *e) { audio[@"error"] = e.reason; }
                props[@"audio"] = audio;
            }

            // CROP
            if (!property || [property isEqualToString:@"all"] || [property isEqualToString:@"crop"]) {
                NSMutableDictionary *crop = [NSMutableDictionary dictionary];
                @try {
                    id cropEff = nil;
                    SEL cropSel = NSSelectorFromString(@"cropEffect");
                    if ([effectStack respondsToSelector:cropSel])
                        cropEff = ((id (*)(id, SEL))objc_msgSend)(effectStack, cropSel);
                    if (cropEff) {
                        id (^getCh)(NSString *) = ^id(NSString *name) {
                            @try {
                                SEL s = NSSelectorFromString([NSString stringWithFormat:@"%@Channel", name]);
                                if ([cropEff respondsToSelector:s])
                                    return ((id (*)(id, SEL))objc_msgSend)(cropEff, s);
                            } @catch (NSException *e) {}
                            return nil;
                        };
                        id lCh = getCh(@"left"); if (lCh) crop[@"left"] = @(FCPBridge_channelValue(lCh));
                        id rCh = getCh(@"right"); if (rCh) crop[@"right"] = @(FCPBridge_channelValue(rCh));
                        id tCh = getCh(@"top"); if (tCh) crop[@"top"] = @(FCPBridge_channelValue(tCh));
                        id bCh = getCh(@"bottom"); if (bCh) crop[@"bottom"] = @(FCPBridge_channelValue(bCh));
                    }
                } @catch (NSException *e) { crop[@"error"] = e.reason; }
                props[@"crop"] = crop;
            }

            // ALL EFFECT CHANNELS (for advanced access)
            if ([property isEqualToString:@"channels"]) {
                NSMutableArray *channels = [NSMutableArray array];
                // Get all effects and their channels
                @try {
                    SEL efSel = NSSelectorFromString(@"visibleEffects");
                    if ([effectStack respondsToSelector:efSel]) {
                        NSArray *effects = ((id (*)(id, SEL))objc_msgSend)(effectStack, efSel);
                        for (id effect in effects) {
                            FCPBridge_collectChannels(effect, channels, nil, 0);
                        }
                    }
                    // Also get intrinsic channels
                    SEL icSel = NSSelectorFromString(@"intrinsicChannels");
                    if ([effectStack respondsToSelector:icSel]) {
                        id intrinsic = ((id (*)(id, SEL))objc_msgSend)(effectStack, icSel);
                        if (intrinsic) FCPBridge_collectChannels(intrinsic, channels, @"intrinsic", 0);
                    }
                } @catch (NSException *e) {}
                props[@"channels"] = channels;
            }

            result = @{@"properties": props};
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result ?: @{@"error": @"Inspector get failed"};
}

static NSDictionary *FCPBridge_handleInspectorSet(NSDictionary *params) {
    NSString *property = params[@"property"]; // "opacity", "positionX", "positionY", "rotation", "scaleX", "scaleY", "volume", etc.
    NSNumber *value = params[@"value"];
    if (!property || !value) return @{@"error": @"property and value parameters required"};

    __block NSDictionary *result = nil;
    FCPBridge_executeOnMainThread(^{
        @try {
            id timeline = FCPBridge_getActiveTimelineModule();
            if (!timeline) { result = @{@"error": @"No active timeline module"}; return; }

            id clip = nil;
            id effectStack = FCPBridge_getSelectedClipEffectStack(timeline, &clip);
            if (!effectStack) { result = @{@"error": @"No clip selected or clip has no effect stack"}; return; }

            double val = [value doubleValue];
            BOOL success = NO;
            NSString *desc = [NSString stringWithFormat:@"Set %@", property];

            // Begin undo action
            @try {
                SEL beginSel = NSSelectorFromString(@"actionBegin:animationHint:deferUpdates:");
                if ([effectStack respondsToSelector:beginSel]) {
                    ((void (*)(id, SEL, id, id, BOOL))objc_msgSend)(
                        effectStack, beginSel, desc, nil, YES);
                }
            } @catch (NSException *e) {}

            // OPACITY
            if ([property isEqualToString:@"opacity"]) {
                @try {
                    SEL bSel = NSSelectorFromString(@"intrinsicCompositeEffectCreateIfAbsent:");
                    id blendEffect = ((id (*)(id, SEL, BOOL))objc_msgSend)(effectStack, bSel, YES);
                    id opChan = ((id (*)(id, SEL))objc_msgSend)(blendEffect, NSSelectorFromString(@"opacityChannel"));
                    success = FCPBridge_setChannelValue(opChan, val);
                } @catch (NSException *e) {}
            }
            // TRANSFORM: position, scale, rotation, anchor
            else if ([property hasPrefix:@"position"] || [property hasPrefix:@"scale"] ||
                     [property hasPrefix:@"rotation"] || [property hasPrefix:@"anchor"]) {
                @try {
                    // Get or create xform3D effect
                    id xfEffect = nil;
                    SEL xfSel = NSSelectorFromString(@"xform3DEffect");
                    if ([effectStack respondsToSelector:xfSel])
                        xfEffect = ((id (*)(id, SEL))objc_msgSend)(effectStack, xfSel);
                    // Create if absent using the known effect ID
                    if (!xfEffect) {
                        SEL addSel = NSSelectorFromString(@"addIntrinsicEffectForEffectID:");
                        if ([effectStack respondsToSelector:addSel]) {
                            xfEffect = ((id (*)(id, SEL, id))objc_msgSend)(
                                effectStack, addSel, @"HEXForm3D");
                        }
                    }
                    if (xfEffect) {
                        NSString *channelMethod = nil;
                        NSString *axis = nil;
                        if ([property isEqualToString:@"positionX"]) { channelMethod = @"positionChannel3D"; axis = @"x"; }
                        else if ([property isEqualToString:@"positionY"]) { channelMethod = @"positionChannel3D"; axis = @"y"; }
                        else if ([property isEqualToString:@"positionZ"]) { channelMethod = @"positionChannel3D"; axis = @"z"; }
                        else if ([property isEqualToString:@"scaleX"]) { channelMethod = @"scaleChannel3D"; axis = @"x"; }
                        else if ([property isEqualToString:@"scaleY"]) { channelMethod = @"scaleChannel3D"; axis = @"y"; }
                        else if ([property isEqualToString:@"rotation"]) { channelMethod = @"rotationChannel3D"; axis = @"z"; }
                        else if ([property isEqualToString:@"anchorX"]) { channelMethod = @"anchorChannel3D"; axis = @"x"; }
                        else if ([property isEqualToString:@"anchorY"]) { channelMethod = @"anchorChannel3D"; axis = @"y"; }

                        if (channelMethod && axis) {
                            id ch3d = ((id (*)(id, SEL))objc_msgSend)(xfEffect, NSSelectorFromString(channelMethod));
                            id axisCh = FCPBridge_subChannel(ch3d, axis);
                            success = FCPBridge_setChannelValue(axisCh, val);
                        }
                    }
                } @catch (NSException *e) {}
            }
            // VOLUME
            else if ([property isEqualToString:@"volume"]) {
                @try {
                    SEL volSel = NSSelectorFromString(@"audioLevelChannel");
                    id volChan = [effectStack respondsToSelector:volSel]
                        ? ((id (*)(id, SEL))objc_msgSend)(effectStack, volSel) : nil;
                    if (volChan) success = FCPBridge_setChannelValue(volChan, val);
                } @catch (NSException *e) {}
            }
            // CHANNEL BY HANDLE (generic - set any channel by its handle)
            else if ([property hasPrefix:@"handle:"]) {
                NSString *handle = [property substringFromIndex:7];
                id channel = FCPBridge_resolveHandle(handle);
                if (channel) success = FCPBridge_setChannelValue(channel, val);
                else result = @{@"error": @"Handle not found"};
            }

            // End undo action
            @try {
                SEL endSel = NSSelectorFromString(@"actionEnd:save:error:");
                if ([effectStack respondsToSelector:endSel]) {
                    ((void (*)(id, SEL, id, BOOL, id))objc_msgSend)(
                        effectStack, endSel, desc, YES, nil);
                }
            } @catch (NSException *e) {}

            if (!result) {
                result = success
                    ? @{@"status": @"ok", @"property": property, @"value": @(val)}
                    : @{@"error": [NSString stringWithFormat:@"Failed to set '%@'", property]};
            }
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result ?: @{@"error": @"Inspector set failed"};
}

#pragma mark - View/Panel Toggle Handler

static NSDictionary *FCPBridge_handleViewToggle(NSDictionary *params) {
    NSString *panel = params[@"panel"];
    if (!panel) return @{@"error": @"panel parameter required"};

    // Map panel names to selectors
    NSDictionary *panelMap = @{
        @"inspector":       @"toggleInspector:",
        @"timeline":        @"toggleTimeline:",
        @"browser":         @"toggleBrowser:",
        @"eventViewer":     @"toggleEventViewer:",
        @"effectsBrowser":  @"toggleEffectsBrowser:",
        @"transitionsBrowser": @"toggleTransitionsBrowser:",
        @"videoScopes":     @"toggleVideoScopes:",
        @"histogram":       @"toggleHistogram:",
        @"vectorscope":     @"toggleVectorscope:",
        @"waveform":        @"toggleWaveformMonitor:",
        @"audioMeter":      @"toggleAudioMeters:",
        @"keywordEditor":   @"toggleKeywordEditor:",
        @"timelineIndex":   @"toggleTimelineIndex:",
        @"precisionEditor": @"showPrecisionEditor:",
        @"retimeEditor":    @"toggleRetimeEditor:",
        @"audioCurves":     @"toggleAudioCurves:",
        @"videoAnimation":  @"showTimelineCurveEditor:",
        @"audioAnimation":  @"showTimelineCurveEditor:",
        @"multicamViewer":  @"toggleAngleViewer:",
        @"360viewer":       @"toggle360Viewer:",
        @"fullscreenViewer": @"toggleFullScreenViewer:",
        @"backgroundTasks": @"goToBackgroundTaskList:",
        @"voiceover":       @"toggleVoiceoverRecordView:",
        @"comparisonViewer": @"toggleComparisonViewer:",
    };

    NSString *selector = panelMap[panel];
    if (!selector) {
        return @{@"error": [NSString stringWithFormat:@"Unknown panel '%@'. Available: %@",
                    panel, [[panelMap allKeys] componentsJoinedByString:@", "]]};
    }

    return FCPBridge_sendAppAction(selector);
}

#pragma mark - Workspace Handler

static NSDictionary *FCPBridge_handleWorkspace(NSDictionary *params) {
    NSString *workspace = params[@"workspace"];
    if (!workspace) return @{@"error": @"workspace parameter required"};

    NSDictionary *workspaceMap = @{
        @"default":       @"Default",
        @"organize":      @"Organize",
        @"colorEffects":  @"Color & Effects",
        @"dualDisplays":  @"Dual Displays",
    };

    NSString *menuTitle = workspaceMap[workspace];
    if (!menuTitle) {
        return @{@"error": [NSString stringWithFormat:@"Unknown workspace '%@'. Available: default, organize, colorEffects, dualDisplays", workspace]};
    }

    return FCPBridge_handleMenuExecute(@{@"menuPath": @[@"Window", @"Workspaces", menuTitle]});
}

#pragma mark - Roles Handler

static NSDictionary *FCPBridge_handleRolesAssign(NSDictionary *params) {
    NSString *roleType = params[@"type"]; // "audio", "video", "caption"
    NSString *roleName = params[@"role"]; // e.g. "Dialogue", "Music", "Effects"
    if (!roleType || !roleName) {
        return @{@"error": @"type and role parameters required"};
    }

    // Build the menu path
    NSString *menuCategory;
    if ([roleType isEqualToString:@"audio"]) menuCategory = @"Assign Audio Roles";
    else if ([roleType isEqualToString:@"video"]) menuCategory = @"Assign Video Roles";
    else if ([roleType isEqualToString:@"caption"]) menuCategory = @"Assign Caption Roles";
    else return @{@"error": @"type must be 'audio', 'video', or 'caption'"};

    return FCPBridge_handleMenuExecute(@{@"menuPath": @[@"Modify", menuCategory, roleName]});
}

#pragma mark - Share/Export Handler

static NSDictionary *FCPBridge_handleShareExport(NSDictionary *params) {
    NSString *destination = params[@"destination"]; // optional: specific share destination

    if (destination) {
        // Try to use specific share destination via menu
        return FCPBridge_handleMenuExecute(@{@"menuPath": @[@"File", @"Share", destination]});
    } else {
        // Use default share
        return FCPBridge_sendAppAction(@"shareDefaultDestination:");
    }
}

#pragma mark - Library/Project Management

static NSDictionary *FCPBridge_handleProjectCreate(NSDictionary *params) {
    // Trigger new project dialog - this opens the dialog
    return FCPBridge_sendAppAction(@"newProject:");
}

static NSDictionary *FCPBridge_handleEventCreate(NSDictionary *params) {
    return FCPBridge_sendAppAction(@"newEvent:");
}

static NSDictionary *FCPBridge_handleLibraryCreate(NSDictionary *params) {
    return FCPBridge_sendAppAction(@"newLibrary:");
}

#pragma mark - Tool Selection Handler

static NSDictionary *FCPBridge_handleToolSelect(NSDictionary *params) {
    NSString *tool = params[@"tool"];
    if (!tool) return @{@"error": @"tool parameter required"};

    NSDictionary *toolMap = @{
        @"select":    @"selectToolArrow:",
        @"trim":      @"selectToolTrim:",
        @"blade":     @"selectToolBlade:",
        @"position":  @"selectToolPlacement:",
        @"hand":      @"selectToolHand:",
        @"zoom":      @"selectToolZoom:",
        @"range":     @"selectToolRangeSelection:",
    };

    NSString *selector = toolMap[tool];
    if (!selector) {
        return @{@"error": [NSString stringWithFormat:@"Unknown tool '%@'. Available: %@",
                    tool, [[toolMap allKeys] componentsJoinedByString:@", "]]};
    }

    return FCPBridge_sendAppAction(selector);
}

#pragma mark - Dialog Detection & Interaction

// Recursively collect UI elements from a view hierarchy
// Forward declarations for dialog helpers
static NSArray<NSButton *> *FCPBridge_findButtonsInView(NSView *root);

// Safe subview accessor - returns a COPY of the subviews array to avoid mutation crashes
static NSArray *FCPBridge_safeSubviews(NSView *view) {
    if (!view) return nil;
    @try {
        NSArray *subs = [view subviews];
        return subs ? [subs copy] : nil; // copy to avoid mutation during iteration
    } @catch (NSException *e) {
        return nil;
    }
}

static void FCPBridge_collectUIElements(NSView *view, NSMutableArray *buttons,
                                         NSMutableArray *textFields, NSMutableArray *labels,
                                         NSMutableArray *checkboxes, NSMutableArray *popups,
                                         int depth) {
    if (!view || depth > 15) return;

    NSArray *subviews = FCPBridge_safeSubviews(view);
    if (!subviews) return;

    for (NSView *subview in subviews) {
        if (!subview) continue;
        @try {
        if ([subview isKindOfClass:[NSButton class]]) {
            NSButton *btn = (NSButton *)subview;
            NSString *title = [btn title] ?: @"";
            NSInteger bezelStyle = [btn bezelStyle];
            BOOL isCheckbox = ([[btn className] containsString:@"Checkbox"] || [btn allowsMixedState]);
            if (isCheckbox) {
                [checkboxes addObject:@{
                    @"title": title,
                    @"checked": @([btn state] == NSControlStateValueOn),
                    @"enabled": @([btn isEnabled]),
                    @"tag": @([btn tag])
                }];
            } else if (title.length > 0) {
                [buttons addObject:@{
                    @"title": title,
                    @"enabled": @([btn isEnabled]),
                    @"tag": @([btn tag]),
                    @"keyEquivalent": [btn keyEquivalent] ?: @"",
                    @"bezelStyle": @(bezelStyle)
                }];
            }
        } else if ([subview isKindOfClass:[NSTextField class]]) {
            NSTextField *tf = (NSTextField *)subview;
            if ([tf isEditable]) {
                [textFields addObject:@{
                    @"value": [tf stringValue] ?: @"",
                    @"placeholder": [tf placeholderString] ?: @"",
                    @"editable": @YES,
                    @"tag": @([tf tag])
                }];
            } else {
                NSString *text = [tf stringValue] ?: @"";
                if (text.length > 0) {
                    [labels addObject:@{
                        @"text": text,
                        @"tag": @([tf tag])
                    }];
                }
            }
        } else if ([subview isKindOfClass:[NSPopUpButton class]]) {
            NSPopUpButton *popup = (NSPopUpButton *)subview;
            NSMutableArray *items = [NSMutableArray array];
            for (NSMenuItem *item in [popup itemArray]) {
                if (![item isSeparatorItem]) {
                    [items addObject:@{
                        @"title": [item title] ?: @"",
                        @"selected": @([popup selectedItem] == item)
                    }];
                }
            }
            [popups addObject:@{
                @"selectedTitle": [[popup titleOfSelectedItem] ?: @"" copy],
                @"items": items,
                @"tag": @([popup tag])
            }];
        } else if ([subview isKindOfClass:[NSSegmentedControl class]]) {
            NSSegmentedControl *seg = (NSSegmentedControl *)subview;
            NSMutableArray *segments = [NSMutableArray array];
            for (NSInteger i = 0; i < seg.segmentCount; i++) {
                [segments addObject:@{
                    @"label": [seg labelForSegment:i] ?: @"",
                    @"selected": @(seg.selectedSegment == i),
                    @"index": @(i)
                }];
            }
            [labels addObject:@{@"text": @"[segmented control]", @"segments": segments}];
        } else if ([subview isKindOfClass:[NSSlider class]]) {
            NSSlider *slider = (NSSlider *)subview;
            [labels addObject:@{
                @"text": @"[slider]",
                @"value": @([slider doubleValue]),
                @"min": @([slider minValue]),
                @"max": @([slider maxValue])
            }];
        }

        } @catch (NSException *e) {
            // Skip any view that throws when accessed
        }

        // Recurse into subviews
        FCPBridge_collectUIElements(subview, buttons, textFields, labels,
                                    checkboxes, popups, depth + 1);
    }
}

static NSDictionary *FCPBridge_describeWindow(NSWindow *window) {
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    info[@"title"] = [window title] ?: @"";
    info[@"class"] = NSStringFromClass([window class]);
    info[@"visible"] = @([window isVisible]);
    info[@"isSheet"] = @([window isSheet]);
    info[@"isModal"] = @(window == [NSApp modalWindow]);
    info[@"frame"] = NSStringFromRect([window frame]);

    NSMutableArray *buttons = [NSMutableArray array];
    NSMutableArray *textFields = [NSMutableArray array];
    NSMutableArray *labels = [NSMutableArray array];
    NSMutableArray *checkboxes = [NSMutableArray array];
    NSMutableArray *popups = [NSMutableArray array];

    FCPBridge_collectUIElements([window contentView], buttons, textFields,
                                labels, checkboxes, popups, 0);

    info[@"buttons"] = buttons;
    info[@"textFields"] = textFields;
    info[@"labels"] = labels;
    info[@"checkboxes"] = checkboxes;
    info[@"popups"] = popups;

    return info;
}

static NSDictionary *FCPBridge_handleDialogDetect(NSDictionary *params) {
    __block NSDictionary *result = nil;
    FCPBridge_executeOnMainThread(^{
        @try {
            id app = ((id (*)(id, SEL))objc_msgSend)(
                objc_getClass("NSApplication"), @selector(sharedApplication));

            NSMutableArray *dialogs = [NSMutableArray array];

            // Check for modal window
            NSWindow *modalWindow = [NSApp modalWindow];
            if (modalWindow) {
                NSMutableDictionary *d = [FCPBridge_describeWindow(modalWindow) mutableCopy];
                d[@"type"] = @"modal";
                [dialogs addObject:d];
            }

            // Check for sheets on all windows
            for (NSWindow *window in [NSApp windows]) {
                NSWindow *sheet = [window attachedSheet];
                if (sheet) {
                    NSMutableDictionary *d = [FCPBridge_describeWindow(sheet) mutableCopy];
                    d[@"type"] = @"sheet";
                    d[@"parentWindow"] = [window title] ?: @"";
                    [dialogs addObject:d];
                }
            }

            // Check for any visible panels (alerts, floating windows, etc.)
            for (NSWindow *window in [NSApp windows]) {
                if (![window isVisible]) continue;
                if (modalWindow && window == modalWindow) continue;

                // Check if this is a panel/alert type window
                BOOL isPanel = [window isKindOfClass:[NSPanel class]];
                BOOL isAlert = [window isKindOfClass:NSClassFromString(@"NSAlertPanel") ?: [NSNull class]];
                BOOL isSheet = [window isSheet];
                BOOL isProgressPanel = [[window className] containsString:@"Progress"];
                BOOL isSharePanel = [[window className] containsString:@"Share"];

                // Check FCP-specific dialog classes
                NSString *className = NSStringFromClass([window class]);
                BOOL isFCPDialog = [className hasPrefix:@"FF"] && (
                    [className containsString:@"Panel"] ||
                    [className containsString:@"Sheet"] ||
                    [className containsString:@"Alert"] ||
                    [className containsString:@"Dialog"] ||
                    [className containsString:@"Progress"] ||
                    [className containsString:@"Window"] // Custom windows
                );

                if (isAlert || isProgressPanel || isSharePanel || isFCPDialog) {
                    NSMutableDictionary *d = [FCPBridge_describeWindow(window) mutableCopy];
                    d[@"type"] = isAlert ? @"alert" : (isProgressPanel ? @"progress" :
                                  (isSharePanel ? @"share" : @"panel"));
                    // Avoid duplicates
                    BOOL isDupe = NO;
                    for (NSDictionary *existing in dialogs) {
                        if ([existing[@"title"] isEqualToString:d[@"title"]] &&
                            [existing[@"class"] isEqualToString:d[@"class"]]) {
                            isDupe = YES; break;
                        }
                    }
                    if (!isDupe) [dialogs addObject:d];
                }

                // Also check for NSAlert-style windows (they have specific structure)
                if (isPanel && !isSheet) {
                    NSArray *buttons = [window contentView].subviews;
                    BOOL hasAlertButton = NO;
                    for (NSView *v in buttons) {
                        if ([v isKindOfClass:[NSButton class]] &&
                            [[(NSButton *)v keyEquivalent] isEqualToString:@"\r"]) {
                            hasAlertButton = YES;
                            break;
                        }
                    }
                    if (hasAlertButton) {
                        NSMutableDictionary *d = [FCPBridge_describeWindow(window) mutableCopy];
                        d[@"type"] = @"alert";
                        BOOL isDupe = NO;
                        for (NSDictionary *existing in dialogs) {
                            if ([existing[@"title"] isEqualToString:d[@"title"]]) {
                                isDupe = YES; break;
                            }
                        }
                        if (!isDupe) [dialogs addObject:d];
                    }
                }
            }

            result = @{
                @"hasDialog": @(dialogs.count > 0),
                @"dialogCount": @(dialogs.count),
                @"dialogs": dialogs
            };
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result ?: @{@"error": @"Dialog detect failed"};
}

static NSDictionary *FCPBridge_handleDialogClick(NSDictionary *params) {
    NSString *buttonTitle = params[@"button"]; // button title to click
    NSNumber *buttonIndex = params[@"index"];   // or button index (0-based)
    if (!buttonTitle && !buttonIndex) {
        return @{@"error": @"button (title) or index parameter required"};
    }

    __block NSDictionary *result = nil;
    FCPBridge_executeOnMainThread(^{
        @try {
            // Find the dialog window (modal > sheet > panel)
            NSWindow *dialogWindow = [NSApp modalWindow];

            if (!dialogWindow) {
                // Check for sheets
                for (NSWindow *window in [NSApp windows]) {
                    NSWindow *sheet = [window attachedSheet];
                    if (sheet) { dialogWindow = sheet; break; }
                }
            }

            if (!dialogWindow) {
                // Check for visible panels
                for (NSWindow *window in [NSApp windows]) {
                    if (![window isVisible]) continue;
                    if ([window isKindOfClass:[NSPanel class]] && ![window isSheet]) {
                        NSString *className = NSStringFromClass([window class]);
                        if ([className hasPrefix:@"FF"] || [className containsString:@"Alert"]) {
                            dialogWindow = window;
                            break;
                        }
                    }
                }
            }

            if (!dialogWindow) {
                result = @{@"error": @"No dialog found to interact with"};
                return;
            }

            // Use BFS to safely find all buttons
            NSArray<NSButton *> *buttonObjects = FCPBridge_findButtonsInView([dialogWindow contentView]);

            NSButton *targetButton = nil;

            if (buttonTitle) {
                // Find button by title (case-insensitive)
                for (NSButton *btn in buttonObjects) {
                    if ([[btn title] caseInsensitiveCompare:buttonTitle] == NSOrderedSame) {
                        targetButton = btn;
                        break;
                    }
                }
                if (!targetButton) {
                    // Try partial match
                    for (NSButton *btn in buttonObjects) {
                        if ([[btn title] localizedCaseInsensitiveContainsString:buttonTitle]) {
                            targetButton = btn;
                            break;
                        }
                    }
                }
            } else if (buttonIndex) {
                NSInteger idx = [buttonIndex integerValue];
                if (idx >= 0 && idx < (NSInteger)buttonObjects.count) {
                    targetButton = buttonObjects[idx];
                }
            }

            if (!targetButton) {
                NSMutableArray *available = [NSMutableArray array];
                for (NSButton *btn in buttonObjects) {
                    [available addObject:[btn title]];
                }
                result = @{@"error": [NSString stringWithFormat:@"Button '%@' not found. Available: %@",
                            buttonTitle ?: [buttonIndex stringValue],
                            [available componentsJoinedByString:@", "]]};
                return;
            }

            if (![targetButton isEnabled]) {
                result = @{@"error": [NSString stringWithFormat:@"Button '%@' is disabled", [targetButton title]]};
                return;
            }

            // Click the button
            [targetButton performClick:nil];

            result = @{@"status": @"ok", @"clicked": [targetButton title],
                      @"dialog": [dialogWindow title] ?: @""};
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result ?: @{@"error": @"Dialog click failed"};
}

static NSDictionary *FCPBridge_handleDialogFill(NSDictionary *params) {
    NSString *value = params[@"value"];
    NSNumber *fieldIndex = params[@"index"] ?: @(0);
    if (!value) return @{@"error": @"value parameter required"};

    __block NSDictionary *result = nil;
    FCPBridge_executeOnMainThread(^{
        @try {
            // Find dialog window
            NSWindow *dialogWindow = [NSApp modalWindow];
            if (!dialogWindow) {
                for (NSWindow *window in [NSApp windows]) {
                    @try {
                        NSWindow *sheet = [window attachedSheet];
                        if (sheet) { dialogWindow = sheet; break; }
                    } @catch (NSException *e) {}
                }
            }
            if (!dialogWindow) {
                result = @{@"error": @"No dialog found"};
                return;
            }

            // Use the collectUIElements function which has full safety
            NSMutableArray *buttons = [NSMutableArray array];
            NSMutableArray *textFields = [NSMutableArray array];
            NSMutableArray *labels = [NSMutableArray array];
            NSMutableArray *checkboxes = [NSMutableArray array];
            NSMutableArray *popups = [NSMutableArray array];

            FCPBridge_collectUIElements([dialogWindow contentView], buttons, textFields,
                                        labels, checkboxes, popups, 0);

            // textFields array already contains only editable fields (from collectUIElements)
            // But we need the actual NSTextField objects, not dicts.
            // So let's find them differently - use the first responder chain.

            // Simple approach: find editable text fields using a breadth-first search
            // with maximum safety
            NSMutableArray *editableFields = [NSMutableArray array];
            NSMutableArray *queue = [NSMutableArray arrayWithObject:[dialogWindow contentView]];

            while (queue.count > 0 && editableFields.count < 20) {
                NSView *current = queue[0];
                [queue removeObjectAtIndex:0];
                if (!current) continue;

                @try {
                    if ([current isKindOfClass:[NSTextField class]]) {
                        NSTextField *tf = (NSTextField *)current;
                        // Use respondsToSelector as extra safety
                        if ([tf respondsToSelector:@selector(isEditable)] &&
                            [tf respondsToSelector:@selector(setStringValue:)]) {
                            BOOL editable = NO;
                            @try { editable = [tf isEditable]; } @catch (NSException *e) {}
                            if (editable) {
                                [editableFields addObject:tf];
                            }
                        }
                    }

                    // Add child views to queue (BFS)
                    NSArray *subs = FCPBridge_safeSubviews(current);
                    if (subs) {
                        [queue addObjectsFromArray:subs];
                    }
                } @catch (NSException *e) {
                    // Skip this view entirely
                }
            }

            NSInteger idx = [fieldIndex integerValue];
            if (idx >= 0 && idx < (NSInteger)editableFields.count) {
                NSTextField *field = editableFields[idx];
                @try {
                    [field setStringValue:value];
                    result = @{@"status": @"ok", @"field": @(idx), @"value": value};
                } @catch (NSException *e) {
                    result = @{@"error": [NSString stringWithFormat:@"Cannot set field: %@", e.reason]};
                }
            } else {
                result = @{@"error": [NSString stringWithFormat:@"Field index %ld not found (have %lu fields)",
                            (long)idx, (unsigned long)editableFields.count]};
            }
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result ?: @{@"error": @"Dialog fill failed"};
}

static NSDictionary *FCPBridge_handleDialogCheckbox(NSDictionary *params) {
    NSString *checkboxTitle = params[@"checkbox"];
    NSNumber *checked = params[@"checked"]; // YES/NO
    if (!checkboxTitle) return @{@"error": @"checkbox (title) parameter required"};

    __block NSDictionary *result = nil;
    FCPBridge_executeOnMainThread(^{
        @try {
            NSWindow *dialogWindow = [NSApp modalWindow];
            if (!dialogWindow) {
                for (NSWindow *window in [NSApp windows]) {
                    NSWindow *sheet = [window attachedSheet];
                    if (sheet) { dialogWindow = sheet; break; }
                }
            }
            if (!dialogWindow) { result = @{@"error": @"No dialog found"}; return; }

            __block NSButton *targetCB = nil;
            __block void (^findCB)(NSView *);
            __weak void (^weakCB)(NSView *);
            weakCB = findCB = ^(NSView *view) {
                if (!view) return;
                NSArray *subs = FCPBridge_safeSubviews(view);
                if (!subs) return;
                for (NSView *subview in subs) {
                    if (!subview) continue;
                    if ([subview isKindOfClass:[NSButton class]]) {
                        NSButton *btn = (NSButton *)subview;
                        if (([[btn className] containsString:@"Checkbox"] || [btn allowsMixedState]) &&
                            [[btn title] localizedCaseInsensitiveContainsString:checkboxTitle]) {
                            targetCB = btn;
                            return;
                        }
                    }
                    if (!targetCB) weakCB(subview);
                }
            };
            findCB([dialogWindow contentView]);

            if (!targetCB) {
                result = @{@"error": [NSString stringWithFormat:@"Checkbox '%@' not found", checkboxTitle]};
                return;
            }

            if (checked) {
                [targetCB setState:[checked boolValue] ? NSControlStateValueOn : NSControlStateValueOff];
            } else {
                // Toggle
                [targetCB performClick:nil];
            }
            result = @{@"status": @"ok", @"checkbox": [targetCB title],
                      @"checked": @([targetCB state] == NSControlStateValueOn)};
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result ?: @{@"error": @"Checkbox toggle failed"};
}

static NSDictionary *FCPBridge_handleDialogPopup(NSDictionary *params) {
    NSString *selection = params[@"select"]; // item title to select
    NSNumber *popupIndex = params[@"popupIndex"] ?: @(0); // which popup (if multiple)
    if (!selection) return @{@"error": @"select parameter required"};

    __block NSDictionary *result = nil;
    FCPBridge_executeOnMainThread(^{
        @try {
            NSWindow *dialogWindow = [NSApp modalWindow];
            if (!dialogWindow) {
                for (NSWindow *window in [NSApp windows]) {
                    NSWindow *sheet = [window attachedSheet];
                    if (sheet) { dialogWindow = sheet; break; }
                }
            }
            if (!dialogWindow) { result = @{@"error": @"No dialog found"}; return; }

            NSMutableArray *popups = [NSMutableArray array];
            __block void (^findPopups)(NSView *);
            __weak void (^weakPU)(NSView *);
            weakPU = findPopups = ^(NSView *view) {
                if (!view) return;
                NSArray *subs = FCPBridge_safeSubviews(view);
                if (!subs) return;
                for (NSView *subview in subs) {
                    if (!subview) continue;
                    if ([subview isKindOfClass:[NSPopUpButton class]]) {
                        [popups addObject:subview];
                    }
                    weakPU(subview);
                }
            };
            findPopups([dialogWindow contentView]);

            NSInteger idx = [popupIndex integerValue];
            if (idx >= 0 && idx < (NSInteger)popups.count) {
                NSPopUpButton *popup = popups[idx];
                [popup selectItemWithTitle:selection];
                if ([popup selectedItem]) {
                    // Trigger the action
                    if ([popup action]) {
                        ((void (*)(id, SEL, id))objc_msgSend)([popup target], [popup action], popup);
                    }
                    result = @{@"status": @"ok", @"selected": selection, @"popupIndex": @(idx)};
                } else {
                    NSMutableArray *available = [NSMutableArray array];
                    for (NSMenuItem *item in [popup itemArray]) {
                        if (![item isSeparatorItem]) [available addObject:[item title]];
                    }
                    result = @{@"error": [NSString stringWithFormat:@"Item '%@' not found. Available: %@",
                                selection, [available componentsJoinedByString:@", "]]};
                }
            } else {
                result = @{@"error": [NSString stringWithFormat:@"Popup index %ld not found (have %lu)",
                            (long)idx, (unsigned long)popups.count]};
            }
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result ?: @{@"error": @"Popup select failed"};
}

// BFS helper to find buttons safely in a view hierarchy
static NSArray<NSButton *> *FCPBridge_findButtonsInView(NSView *root) {
    NSMutableArray<NSButton *> *found = [NSMutableArray array];
    if (!root) return found;
    NSMutableArray<NSView *> *queue = [NSMutableArray arrayWithObject:root];
    while (queue.count > 0 && found.count < 50) {
        NSView *current = queue[0];
        [queue removeObjectAtIndex:0];
        if (!current) continue;
        @try {
            if ([current isKindOfClass:[NSButton class]]) {
                NSButton *btn = (NSButton *)current;
                if ([btn respondsToSelector:@selector(title)] && [btn title].length > 0) {
                    [found addObject:btn];
                }
            }
            NSArray *subs = FCPBridge_safeSubviews(current);
            if (subs) [queue addObjectsFromArray:subs];
        } @catch (NSException *e) {}
    }
    return found;
}

static NSDictionary *FCPBridge_handleDialogDismiss(NSDictionary *params) {
    NSString *action = params[@"action"] ?: @"default";

    __block NSDictionary *result = nil;
    FCPBridge_executeOnMainThread(^{
        @try {
            NSWindow *dialogWindow = [NSApp modalWindow];
            if (!dialogWindow) {
                for (NSWindow *window in [NSApp windows]) {
                    @try {
                        NSWindow *sheet = [window attachedSheet];
                        if (sheet) { dialogWindow = sheet; break; }
                    } @catch (NSException *e) {}
                }
            }
            if (!dialogWindow) {
                result = @{@"error": @"No dialog to dismiss"};
                return;
            }

            NSArray<NSButton *> *allButtons = FCPBridge_findButtonsInView([dialogWindow contentView]);

            if ([action isEqualToString:@"cancel"]) {
                NSButton *cancelBtn = nil;
                for (NSButton *btn in allButtons) {
                    @try {
                        NSString *keyEq = [btn keyEquivalent] ?: @"";
                        NSString *title = [btn title] ?: @"";
                        if ([keyEq isEqualToString:@"\033"] ||
                            [title caseInsensitiveCompare:@"Cancel"] == NSOrderedSame ||
                            [title caseInsensitiveCompare:@"Don't Save"] == NSOrderedSame) {
                            cancelBtn = btn; break;
                        }
                    } @catch (NSException *e) {}
                }
                if (cancelBtn) {
                    [cancelBtn performClick:nil];
                    result = @{@"status": @"ok", @"action": @"cancel", @"clicked": [cancelBtn title]};
                } else {
                    [dialogWindow performClose:nil];
                    result = @{@"status": @"ok", @"action": @"close"};
                }
            } else {
                NSButton *targetBtn = nil;
                for (NSButton *btn in allButtons) {
                    @try {
                        if ([[btn keyEquivalent] isEqualToString:@"\r"] && [btn isEnabled]) {
                            targetBtn = btn; break;
                        }
                    } @catch (NSException *e) {}
                }
                if (!targetBtn) {
                    for (NSButton *btn in allButtons) {
                        @try {
                            NSString *title = [btn title] ?: @"";
                            if (([title caseInsensitiveCompare:@"OK"] == NSOrderedSame ||
                                 [title caseInsensitiveCompare:@"Done"] == NSOrderedSame ||
                                 [title caseInsensitiveCompare:@"Share"] == NSOrderedSame) &&
                                [btn isEnabled]) {
                                targetBtn = btn; break;
                            }
                        } @catch (NSException *e) {}
                    }
                }
                if (targetBtn) {
                    [targetBtn performClick:nil];
                    result = @{@"status": @"ok", @"action": action, @"clicked": [targetBtn title]};
                } else {
                    result = @{@"error": @"No default/OK button found"};
                }
            }
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result ?: @{@"error": @"Dismiss failed"};
}

#pragma mark - FlexMusic & Montage Maker

// ---------- FlexMusic static state ----------
static id sFMSongLibrary = nil; // FMSongLibrary singleton

static id FCPBridge_getFlexMusicLibrary(void) {
    if (sFMSongLibrary) return sFMSongLibrary;

    Class fmLib = objc_getClass("FMSongLibrary");
    if (!fmLib) return nil;

    // alloc/init with empty options dict
    id instance = ((id (*)(id, SEL))objc_msgSend)(
        (id)fmLib, @selector(alloc));
    if (!instance) return nil;

    SEL initSel = NSSelectorFromString(@"initWithOptions:");
    if ([instance respondsToSelector:initSel]) {
        instance = ((id (*)(id, SEL, id))objc_msgSend)(instance, initSel, @{});
    } else {
        instance = ((id (*)(id, SEL))objc_msgSend)(instance, @selector(init));
    }

    sFMSongLibrary = instance;
    return sFMSongLibrary;
}

// Helper: look up an NSString* constant from FlexMusicKit by symbol name
static NSString *FCPBridge_flexMusicConstant(const char *symbolName) {
    void *ptr = dlsym(RTLD_DEFAULT, symbolName);
    if (!ptr) return nil;
    CFStringRef *cfPtr = (CFStringRef *)ptr;
    return (__bridge NSString *)(*cfPtr);
}

// Helper: build a CMTime from seconds at timescale 600
static FCPBridge_CMTime FCPBridge_cmtimeFromSeconds(double seconds) {
    FCPBridge_CMTime t;
    t.value = (int64_t)(seconds * 600.0);
    t.timescale = 600;
    t.flags = 1; // kCMTimeFlags_Valid
    t.epoch = 0;
    return t;
}

// Helper: convert CMTime to double seconds
static double FCPBridge_cmtimeToSeconds(FCPBridge_CMTime t) {
    if (t.timescale <= 0) return 0.0;
    return (double)t.value / (double)t.timescale;
}

// ---------- 1. flexmusic.listSongs ----------

static NSDictionary *FCPBridge_handleFlexMusicListSongs(NSDictionary *params) {
    NSString *filter = params[@"filter"];

    __block NSDictionary *result = nil;
    FCPBridge_executeOnMainThread(^{
        @try {
            id library = FCPBridge_getFlexMusicLibrary();
            if (!library) {
                result = @{@"error": @"FMSongLibrary not available (FlexMusicKit framework not loaded)"};
                return;
            }

            // Try multiple selectors to get songs
            id songs = nil;
            SEL songsSel = NSSelectorFromString(@"songs");
            SEL availSel = NSSelectorFromString(@"availableSongs");
            SEL allSel = NSSelectorFromString(@"allSongs");

            if ([library respondsToSelector:songsSel]) {
                songs = ((id (*)(id, SEL))objc_msgSend)(library, songsSel);
            } else if ([library respondsToSelector:availSel]) {
                songs = ((id (*)(id, SEL))objc_msgSend)(library, availSel);
            } else if ([library respondsToSelector:allSel]) {
                songs = ((id (*)(id, SEL))objc_msgSend)(library, allSel);
            }

            // If direct accessors fail, try fetch with completion (sync via semaphore)
            if (!songs) {
                SEL fetchSel = NSSelectorFromString(@"fetchSongsWithOptions:completionHandler:");
                if ([library respondsToSelector:fetchSel]) {
                    __block id fetchedSongs = nil;
                    dispatch_semaphore_t sem = dispatch_semaphore_create(0);

                    // FMFetchOptions - try empty alloc/init
                    Class fetchOptClass = objc_getClass("FMFetchOptions");
                    id fetchOpts = nil;
                    if (fetchOptClass) {
                        fetchOpts = ((id (*)(id, SEL))objc_msgSend)(
                            ((id (*)(id, SEL))objc_msgSend)((id)fetchOptClass, @selector(alloc)),
                            @selector(init));
                    }
                    if (!fetchOpts) fetchOpts = (id)@{};

                    ((void (*)(id, SEL, id, void(^)(id, id)))objc_msgSend)(
                        library, fetchSel, fetchOpts, ^(id songsResult, id error) {
                            fetchedSongs = songsResult;
                            dispatch_semaphore_signal(sem);
                        });
                    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
                    songs = fetchedSongs;
                }
            }

            // Also try FFFlexMusicLibrary from Flexo as fallback
            if (!songs) {
                Class ffFlexLib = objc_getClass("FFFlexMusicLibrary");
                if (ffFlexLib) {
                    SEL sharedSel = NSSelectorFromString(@"sharedLibrary");
                    if ([ffFlexLib respondsToSelector:sharedSel]) {
                        id ffLib = ((id (*)(id, SEL))objc_msgSend)((id)ffFlexLib, sharedSel);
                        if (ffLib) {
                            SEL fSongsSel = NSSelectorFromString(@"songs");
                            if ([ffLib respondsToSelector:fSongsSel]) {
                                songs = ((id (*)(id, SEL))objc_msgSend)(ffLib, fSongsSel);
                            }
                        }
                    }
                }
            }

            if (!songs || (![songs isKindOfClass:[NSArray class]] && ![songs isKindOfClass:[NSSet class]])) {
                result = @{@"error": @"Could not retrieve songs from FMSongLibrary",
                           @"libraryClass": NSStringFromClass([library class])};
                return;
            }

            // Normalize to array
            NSArray *songArray = [songs isKindOfClass:[NSSet class]] ? [(NSSet *)songs allObjects] : (NSArray *)songs;

            NSMutableArray *songList = [NSMutableArray array];
            for (id song in songArray) {
                @autoreleasepool {
                    NSMutableDictionary *info = [NSMutableDictionary dictionary];

                    // UID / identifier
                    SEL uidSel = NSSelectorFromString(@"songUID");
                    SEL idSel = NSSelectorFromString(@"identifier");
                    NSString *uid = nil;
                    if ([song respondsToSelector:uidSel]) {
                        uid = ((id (*)(id, SEL))objc_msgSend)(song, uidSel);
                    } else if ([song respondsToSelector:idSel]) {
                        uid = ((id (*)(id, SEL))objc_msgSend)(song, idSel);
                    }
                    if (uid) info[@"uid"] = uid;

                    // Name
                    SEL nameSel = NSSelectorFromString(@"name");
                    SEL dispSel = @selector(displayName);
                    NSString *name = nil;
                    if ([song respondsToSelector:nameSel]) {
                        name = ((id (*)(id, SEL))objc_msgSend)(song, nameSel);
                    } else if ([song respondsToSelector:dispSel]) {
                        name = ((id (*)(id, SEL))objc_msgSend)(song, dispSel);
                    }
                    if (name) info[@"name"] = name;

                    // Metadata
                    SEL metaSel = NSSelectorFromString(@"metadata");
                    if ([song respondsToSelector:metaSel]) {
                        id metadata = ((id (*)(id, SEL))objc_msgSend)(song, metaSel);
                        if (metadata) {
                            SEL artistSel = NSSelectorFromString(@"artistName");
                            if ([metadata respondsToSelector:artistSel]) {
                                id artist = ((id (*)(id, SEL))objc_msgSend)(metadata, artistSel);
                                if (artist) info[@"artist"] = artist;
                            }
                            SEL genreSel = NSSelectorFromString(@"genres");
                            if ([metadata respondsToSelector:genreSel]) {
                                id genres = ((id (*)(id, SEL))objc_msgSend)(metadata, genreSel);
                                if (genres) info[@"genres"] = genres;
                            }
                        }
                    }

                    // Duration
                    SEL durSel = NSSelectorFromString(@"naturalDuration");
                    if ([song respondsToSelector:durSel]) {
                        FCPBridge_CMTime dur = ((FCPBridge_CMTime (*)(id, SEL))objc_msgSend)(song, durSel);
                        info[@"durationSeconds"] = @(FCPBridge_cmtimeToSeconds(dur));
                    }

                    // Filter
                    if (filter.length > 0) {
                        NSString *lowerFilter = [filter lowercaseString];
                        NSString *nameStr = info[@"name"] ?: @"";
                        NSString *artistStr = info[@"artist"] ?: @"";
                        BOOL matches = [[nameStr lowercaseString] containsString:lowerFilter] ||
                                       [[artistStr lowercaseString] containsString:lowerFilter];
                        if (!matches) continue;
                    }

                    // Store handle
                    NSString *handle = FCPBridge_storeHandle(song);
                    info[@"handle"] = handle;

                    [songList addObject:info];
                }
            }

            result = @{@"songs": songList, @"count": @(songList.count)};
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result ?: @{@"error": @"Failed to list songs"};
}

// ---------- 2. flexmusic.getSong ----------

static NSDictionary *FCPBridge_handleFlexMusicGetSong(NSDictionary *params) {
    NSString *songUID = params[@"songUID"];
    NSString *handle = params[@"handle"];
    if (!songUID && !handle) return @{@"error": @"songUID or handle parameter required"};

    __block NSDictionary *result = nil;
    FCPBridge_executeOnMainThread(^{
        @try {
            id song = nil;

            // Resolve by handle first
            if (handle) {
                song = FCPBridge_resolveHandle(handle);
            }

            // Resolve by UID via library
            if (!song && songUID) {
                id library = FCPBridge_getFlexMusicLibrary();
                if (library) {
                    SEL forUIDSel = NSSelectorFromString(@"songForUID:");
                    if ([library respondsToSelector:forUIDSel]) {
                        song = ((id (*)(id, SEL, id))objc_msgSend)(library, forUIDSel, songUID);
                    }
                }
                // Try FFFlexMusicLibrary fallback
                if (!song) {
                    Class ffFlexLib = objc_getClass("FFFlexMusicLibrary");
                    if (ffFlexLib) {
                        SEL sharedSel = NSSelectorFromString(@"sharedLibrary");
                        if ([ffFlexLib respondsToSelector:sharedSel]) {
                            id ffLib = ((id (*)(id, SEL))objc_msgSend)((id)ffFlexLib, sharedSel);
                            if (ffLib) {
                                SEL fForUIDSel = NSSelectorFromString(@"songForUID:");
                                if ([ffLib respondsToSelector:fForUIDSel]) {
                                    song = ((id (*)(id, SEL, id))objc_msgSend)(ffLib, fForUIDSel, songUID);
                                }
                            }
                        }
                    }
                }
            }

            if (!song) {
                result = @{@"error": @"Song not found"};
                return;
            }

            NSMutableDictionary *info = [NSMutableDictionary dictionary];
            info[@"class"] = NSStringFromClass([song class]);

            // UID
            SEL uidSel = NSSelectorFromString(@"songUID");
            SEL idSel = NSSelectorFromString(@"identifier");
            if ([song respondsToSelector:uidSel]) {
                id uid = ((id (*)(id, SEL))objc_msgSend)(song, uidSel);
                if (uid) info[@"uid"] = uid;
            } else if ([song respondsToSelector:idSel]) {
                id uid = ((id (*)(id, SEL))objc_msgSend)(song, idSel);
                if (uid) info[@"uid"] = uid;
            }

            // Name
            SEL nameSel = NSSelectorFromString(@"name");
            if ([song respondsToSelector:nameSel]) {
                id name = ((id (*)(id, SEL))objc_msgSend)(song, nameSel);
                if (name) info[@"name"] = name;
            }

            // Metadata
            SEL metaSel = NSSelectorFromString(@"metadata");
            if ([song respondsToSelector:metaSel]) {
                id metadata = ((id (*)(id, SEL))objc_msgSend)(song, metaSel);
                if (metadata) {
                    NSMutableDictionary *meta = [NSMutableDictionary dictionary];

                    SEL artistSel = NSSelectorFromString(@"artistName");
                    if ([metadata respondsToSelector:artistSel]) {
                        id v = ((id (*)(id, SEL))objc_msgSend)(metadata, artistSel);
                        if (v) meta[@"artist"] = v;
                    }
                    SEL moodSel = NSSelectorFromString(@"mood");
                    if ([metadata respondsToSelector:moodSel]) {
                        id v = ((id (*)(id, SEL))objc_msgSend)(metadata, moodSel);
                        if (v) meta[@"mood"] = v;
                    }
                    SEL paceSel = NSSelectorFromString(@"pace");
                    if ([metadata respondsToSelector:paceSel]) {
                        id v = ((id (*)(id, SEL))objc_msgSend)(metadata, paceSel);
                        if (v) meta[@"pace"] = v;
                    }
                    SEL genreSel = NSSelectorFromString(@"genres");
                    if ([metadata respondsToSelector:genreSel]) {
                        id v = ((id (*)(id, SEL))objc_msgSend)(metadata, genreSel);
                        if (v) meta[@"genres"] = v;
                    }
                    SEL arousalSel = NSSelectorFromString(@"arousal");
                    if ([metadata respondsToSelector:arousalSel]) {
                        id v = ((id (*)(id, SEL))objc_msgSend)(metadata, arousalSel);
                        if (v) meta[@"arousal"] = v;
                    }
                    SEL valenceSel = NSSelectorFromString(@"valence");
                    if ([metadata respondsToSelector:valenceSel]) {
                        id v = ((id (*)(id, SEL))objc_msgSend)(metadata, valenceSel);
                        if (v) meta[@"valence"] = v;
                    }

                    info[@"metadata"] = meta;
                }
            }

            // Durations
            SEL natDurSel = NSSelectorFromString(@"naturalDuration");
            if ([song respondsToSelector:natDurSel]) {
                FCPBridge_CMTime dur = ((FCPBridge_CMTime (*)(id, SEL))objc_msgSend)(song, natDurSel);
                info[@"naturalDurationSeconds"] = @(FCPBridge_cmtimeToSeconds(dur));
            }
            SEL minDurSel = NSSelectorFromString(@"minimumDuration");
            if ([song respondsToSelector:minDurSel]) {
                FCPBridge_CMTime dur = ((FCPBridge_CMTime (*)(id, SEL))objc_msgSend)(song, minDurSel);
                info[@"minimumDurationSeconds"] = @(FCPBridge_cmtimeToSeconds(dur));
            }
            SEL idealSel = NSSelectorFromString(@"idealDurations");
            if ([song respondsToSelector:idealSel]) {
                id ideals = ((id (*)(id, SEL))objc_msgSend)(song, idealSel);
                if ([ideals isKindOfClass:[NSArray class]]) {
                    info[@"idealDurations"] = ideals;
                }
            }

            // Song format
            SEL fmtSel = NSSelectorFromString(@"songFormat");
            if ([song respondsToSelector:fmtSel]) {
                id fmt = ((id (*)(id, SEL))objc_msgSend)(song, fmtSel);
                if (fmt) info[@"songFormat"] = fmt;
            }

            // Store handle
            NSString *h = FCPBridge_storeHandle(song);
            info[@"handle"] = h;

            result = info;
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result ?: @{@"error": @"Failed to get song"};
}

// ---------- 3. flexmusic.getTiming ----------

static NSDictionary *FCPBridge_handleFlexMusicGetTiming(NSDictionary *params) {
    NSString *songUID = params[@"songUID"];
    NSString *handle = params[@"handle"];
    NSNumber *durationSecondsNum = params[@"durationSeconds"];
    if (!songUID && !handle) return @{@"error": @"songUID or handle parameter required"};
    if (!durationSecondsNum) return @{@"error": @"durationSeconds parameter required"};

    double durationSeconds = [durationSecondsNum doubleValue];

    __block NSDictionary *result = nil;
    FCPBridge_executeOnMainThread(^{
        @try {
            // Resolve song
            id song = nil;
            if (handle) {
                song = FCPBridge_resolveHandle(handle);
            }
            if (!song && songUID) {
                id library = FCPBridge_getFlexMusicLibrary();
                if (library) {
                    SEL forUIDSel = NSSelectorFromString(@"songForUID:");
                    if ([library respondsToSelector:forUIDSel]) {
                        song = ((id (*)(id, SEL, id))objc_msgSend)(library, forUIDSel, songUID);
                    }
                }
            }
            if (!song) {
                result = @{@"error": @"Song not found"};
                return;
            }

            FCPBridge_CMTime durTime = FCPBridge_cmtimeFromSeconds(durationSeconds);

            // Get options for duration - try FFAnchoredFlexMusicObject first
            id options = nil;
            Class ffFlexObj = objc_getClass("FFAnchoredFlexMusicObject");
            if (ffFlexObj) {
                SEL optSel = NSSelectorFromString(@"optionsForDuration:");
                if ([ffFlexObj respondsToSelector:optSel]) {
                    options = ((id (*)(id, SEL, FCPBridge_CMTime))objc_msgSend)(
                        (id)ffFlexObj, optSel, durTime);
                }
            }
            if (!options) {
                // Build options manually
                NSMutableDictionary *opts = [NSMutableDictionary dictionary];
                // Look up option constants via dlsym
                NSString *loopOpt = FCPBridge_flexMusicConstant("FMSong_Option_LoopSongForLongDurations");
                NSString *outroOpt = FCPBridge_flexMusicConstant("FMSong_Option_OutroCanBeShortened");
                if (loopOpt) opts[loopOpt] = @YES;
                if (outroOpt) opts[outroOpt] = @YES;
                options = opts;
            }

            // Get rendition
            id rendition = nil;
            SEL rendSel = NSSelectorFromString(@"renditionForDuration:withOptions:");
            if ([song respondsToSelector:rendSel]) {
                rendition = ((id (*)(id, SEL, FCPBridge_CMTime, id))objc_msgSend)(
                    song, rendSel, durTime, options);
            }
            if (!rendition) {
                // Try simpler renditionForDuration:
                SEL rendSel2 = NSSelectorFromString(@"renditionForDuration:");
                if ([song respondsToSelector:rendSel2]) {
                    rendition = ((id (*)(id, SEL, FCPBridge_CMTime))objc_msgSend)(
                        song, rendSel2, durTime);
                }
            }
            if (!rendition) {
                result = @{@"error": @"Could not get rendition for specified duration"};
                return;
            }

            NSString *rendHandle = FCPBridge_storeHandle(rendition);
            NSMutableDictionary *timing = [NSMutableDictionary dictionary];
            timing[@"renditionHandle"] = rendHandle;
            timing[@"renditionClass"] = NSStringFromClass([rendition class]);

            // Get fitted duration from rendition
            SEL rendDurSel = NSSelectorFromString(@"duration");
            if ([rendition respondsToSelector:rendDurSel]) {
                FCPBridge_CMTime rd = ((FCPBridge_CMTime (*)(id, SEL))objc_msgSend)(rendition, rendDurSel);
                timing[@"fittedDurationSeconds"] = @(FCPBridge_cmtimeToSeconds(rd));
            }

            // Extract timed metadata using identifier constants
            NSString *beatId = FCPBridge_flexMusicConstant("FMTimedMetadataIdentifierBeat");
            NSString *barId = FCPBridge_flexMusicConstant("FMTimedMetadataIdentifierBar");
            NSString *sectionId = FCPBridge_flexMusicConstant("FMTimedMetadataIdentifierSection");
            NSString *segmentId = FCPBridge_flexMusicConstant("FMTimedMetadataIdentifierSegment");
            NSString *onsetId = FCPBridge_flexMusicConstant("FMTimedMetadataIdentifierOnset");

            SEL timedMetaSel = NSSelectorFromString(@"timedMetadataItemsWithIdentifier:");
            BOOL hasTimedMeta = [rendition respondsToSelector:timedMetaSel];

            // Helper block to extract time arrays from timed metadata
            NSArray *(^extractTimes)(NSString *) = ^NSArray *(NSString *identifier) {
                if (!identifier || !hasTimedMeta) return @[];
                id items = ((id (*)(id, SEL, id))objc_msgSend)(rendition, timedMetaSel, identifier);
                if (![items isKindOfClass:[NSArray class]]) return @[];
                NSMutableArray *times = [NSMutableArray array];
                for (id item in (NSArray *)items) {
                    SEL timeSel = NSSelectorFromString(@"time");
                    if ([item respondsToSelector:timeSel]) {
                        FCPBridge_CMTime t = ((FCPBridge_CMTime (*)(id, SEL))objc_msgSend)(item, timeSel);
                        [times addObject:@(FCPBridge_cmtimeToSeconds(t))];
                    }
                }
                return times;
            };

            timing[@"beats"] = extractTimes(beatId);
            timing[@"bars"] = extractTimes(barId);
            timing[@"sections"] = extractTimes(sectionId);
            timing[@"segments"] = extractTimes(segmentId);
            timing[@"onsets"] = extractTimes(onsetId);

            // Also try FFFlexMusicTimingMetadata if direct timed metadata is empty
            if ([timing[@"beats"] count] == 0) {
                Class ffTimingClass = objc_getClass("FFFlexMusicTimingMetadata");
                if (ffTimingClass) {
                    SEL initRendSel = NSSelectorFromString(@"initWithSongRendition:clippedRange:");
                    if ([ffTimingClass instancesRespondToSelector:initRendSel]) {
                        // Full range
                        FCPBridge_CMTime start = {0, 600, 1, 0};
                        FCPBridge_CMTimeRange fullRange = {start, durTime};

                        id tmObj = ((id (*)(id, SEL))objc_msgSend)((id)ffTimingClass, @selector(alloc));
                        tmObj = ((id (*)(id, SEL, id, FCPBridge_CMTimeRange))objc_msgSend)(
                            tmObj, initRendSel, rendition, fullRange);

                        if (tmObj) {
                            SEL newMetaSel = NSSelectorFromString(@"newTimingMetadataForType:");
                            if ([tmObj respondsToSelector:newMetaSel]) {
                                // Type 1 = beats, 2 = bars, 4 = sections
                                int types[] = {1, 2, 4};
                                NSString *keys[] = {@"beats", @"bars", @"sections"};
                                for (int i = 0; i < 3; i++) {
                                    id metaItems = ((id (*)(id, SEL, int))objc_msgSend)(
                                        tmObj, newMetaSel, types[i]);
                                    if ([metaItems isKindOfClass:[NSArray class]]) {
                                        NSMutableArray *times = [NSMutableArray array];
                                        for (id item in (NSArray *)metaItems) {
                                            SEL timeSel2 = NSSelectorFromString(@"time");
                                            if ([item respondsToSelector:timeSel2]) {
                                                FCPBridge_CMTime t = ((FCPBridge_CMTime (*)(id, SEL))objc_msgSend)(item, timeSel2);
                                                [times addObject:@(FCPBridge_cmtimeToSeconds(t))];
                                            }
                                        }
                                        if (times.count > 0) timing[keys[i]] = times;
                                    }
                                }
                            }
                        }
                    }
                }
            }

            // Report available identifiers
            NSMutableArray *availableIds = [NSMutableArray array];
            if (beatId) [availableIds addObject:@"beat"];
            if (barId) [availableIds addObject:@"bar"];
            if (sectionId) [availableIds addObject:@"section"];
            if (segmentId) [availableIds addObject:@"segment"];
            if (onsetId) [availableIds addObject:@"onset"];
            timing[@"availableIdentifiers"] = availableIds;

            result = timing;
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result ?: @{@"error": @"Failed to get timing"};
}

// ---------- 4. flexmusic.renderToFile ----------

static NSDictionary *FCPBridge_handleFlexMusicRender(NSDictionary *params) {
    NSString *songUID = params[@"songUID"];
    NSString *handle = params[@"handle"];
    NSNumber *durationSecondsNum = params[@"durationSeconds"];
    NSString *outputPath = params[@"outputPath"];
    NSString *format = params[@"format"] ?: @"m4a";

    if (!songUID && !handle) return @{@"error": @"songUID or handle parameter required"};
    if (!durationSecondsNum) return @{@"error": @"durationSeconds parameter required"};

    double durationSeconds = [durationSecondsNum doubleValue];

    // Generate output path if not provided
    if (!outputPath) {
        NSString *ext = [format isEqualToString:@"wav"] ? @"wav" : @"m4a";
        outputPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"fcpbridge_flexmusic_%@.%@",
             [[NSUUID UUID] UUIDString], ext]];
    }

    __block NSDictionary *result = nil;
    FCPBridge_executeOnMainThread(^{
        @try {
            // Resolve song
            id song = nil;
            if (handle) {
                song = FCPBridge_resolveHandle(handle);
            }
            if (!song && songUID) {
                id library = FCPBridge_getFlexMusicLibrary();
                if (library) {
                    SEL forUIDSel = NSSelectorFromString(@"songForUID:");
                    if ([library respondsToSelector:forUIDSel]) {
                        song = ((id (*)(id, SEL, id))objc_msgSend)(library, forUIDSel, songUID);
                    }
                }
            }
            if (!song) {
                result = @{@"error": @"Song not found"};
                return;
            }

            FCPBridge_CMTime durTime = FCPBridge_cmtimeFromSeconds(durationSeconds);

            // Get rendition
            id rendition = nil;
            SEL rendSel = NSSelectorFromString(@"renditionForDuration:withOptions:");
            id options = nil;
            Class ffFlexObj = objc_getClass("FFAnchoredFlexMusicObject");
            if (ffFlexObj) {
                SEL optSel = NSSelectorFromString(@"optionsForDuration:");
                if ([ffFlexObj respondsToSelector:optSel]) {
                    options = ((id (*)(id, SEL, FCPBridge_CMTime))objc_msgSend)(
                        (id)ffFlexObj, optSel, durTime);
                }
            }
            if (!options) options = @{};

            if ([song respondsToSelector:rendSel]) {
                rendition = ((id (*)(id, SEL, FCPBridge_CMTime, id))objc_msgSend)(
                    song, rendSel, durTime, options);
            }
            if (!rendition) {
                SEL rendSel2 = NSSelectorFromString(@"renditionForDuration:");
                if ([song respondsToSelector:rendSel2]) {
                    rendition = ((id (*)(id, SEL, FCPBridge_CMTime))objc_msgSend)(
                        song, rendSel2, durTime);
                }
            }
            if (!rendition) {
                result = @{@"error": @"Could not get rendition for export"};
                return;
            }

            // Get AVComposition and AVAudioMix from rendition
            SEL compSel = NSSelectorFromString(@"avCompositionWithAudioMix:includeShortenedOutroFadeOut:");
            id composition = nil;
            id audioMix = nil;

            if ([rendition respondsToSelector:compSel]) {
                // audioMix is passed by reference (AVAudioMix **)
                __unsafe_unretained id mixRef = nil;
                composition = ((id (*)(id, SEL, __unsafe_unretained id *, BOOL))objc_msgSend)(
                    rendition, compSel, &mixRef, YES);
                audioMix = mixRef;
            }

            // Fallback: try avComposition directly
            if (!composition) {
                SEL simpleCompSel = NSSelectorFromString(@"avComposition");
                if ([rendition respondsToSelector:simpleCompSel]) {
                    composition = ((id (*)(id, SEL))objc_msgSend)(rendition, simpleCompSel);
                }
            }

            if (!composition) {
                result = @{@"error": @"Could not get AVComposition from rendition"};
                return;
            }

            // Remove existing file if any
            [[NSFileManager defaultManager] removeItemAtPath:outputPath error:nil];

            // Create AVAssetExportSession
            Class exportClass = objc_getClass("AVAssetExportSession");
            SEL exportInitSel = NSSelectorFromString(@"exportSessionWithAsset:presetName:");
            NSString *preset = @"AVAssetExportPresetAppleM4A";
            if ([format isEqualToString:@"wav"]) {
                preset = @"AVAssetExportPresetPassthrough";
            }

            id exportSession = ((id (*)(id, SEL, id, id))objc_msgSend)(
                (id)exportClass, exportInitSel, composition, preset);
            if (!exportSession) {
                result = @{@"error": @"Could not create AVAssetExportSession"};
                return;
            }

            // Configure export session
            NSURL *outputURL = [NSURL fileURLWithPath:outputPath];
            ((void (*)(id, SEL, id))objc_msgSend)(exportSession,
                @selector(setOutputURL:), outputURL);

            NSString *fileType = [format isEqualToString:@"wav"]
                ? @"com.microsoft.waveform-audio"
                : @"com.apple.m4a-audio";
            ((void (*)(id, SEL, id))objc_msgSend)(exportSession,
                NSSelectorFromString(@"setOutputFileType:"), fileType);

            if (audioMix) {
                ((void (*)(id, SEL, id))objc_msgSend)(exportSession,
                    NSSelectorFromString(@"setAudioMix:"), audioMix);
            }

            // Export synchronously
            dispatch_semaphore_t sem = dispatch_semaphore_create(0);
            __block BOOL exportOK = NO;
            __block NSString *exportError = nil;

            ((void (*)(id, SEL, void(^)(void)))objc_msgSend)(exportSession,
                NSSelectorFromString(@"exportAsynchronouslyWithCompletionHandler:"),
                ^{
                    NSInteger status = ((NSInteger (*)(id, SEL))objc_msgSend)(
                        exportSession, NSSelectorFromString(@"status"));
                    // AVAssetExportSessionStatusCompleted = 3
                    exportOK = (status == 3);
                    if (!exportOK) {
                        id err = ((id (*)(id, SEL))objc_msgSend)(
                            exportSession, @selector(error));
                        exportError = err ? [err description] : @"Export failed with unknown error";
                    }
                    dispatch_semaphore_signal(sem);
                });

            dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC));

            if (exportOK) {
                // Get actual file size
                NSDictionary *attrs = [[NSFileManager defaultManager]
                    attributesOfItemAtPath:outputPath error:nil];
                NSNumber *fileSize = attrs[NSFileSize] ?: @0;

                result = @{
                    @"status": @"ok",
                    @"path": outputPath,
                    @"format": format,
                    @"durationSeconds": durationSecondsNum,
                    @"fileSizeBytes": fileSize
                };
            } else {
                result = @{@"error": exportError ?: @"Export timed out"};
            }
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result ?: @{@"error": @"Failed to render song"};
}

// ---------- 5. flexmusic.addToTimeline ----------

static NSDictionary *FCPBridge_handleFlexMusicAddToTimeline(NSDictionary *params) {
    NSString *songUID = params[@"songUID"];
    NSString *handle = params[@"handle"];
    NSNumber *durationSecondsNum = params[@"durationSeconds"];
    if (!songUID && !handle) return @{@"error": @"songUID or handle parameter required"};

    __block NSDictionary *result = nil;
    FCPBridge_executeOnMainThread(^{
        @try {
            // If no explicit duration, try to get timeline duration
            double durationSeconds = durationSecondsNum ? [durationSecondsNum doubleValue] : 0;

            if (durationSeconds <= 0) {
                id timeline = FCPBridge_getActiveTimelineModule();
                if (timeline) {
                    SEL seqSel = @selector(sequence);
                    if ([timeline respondsToSelector:seqSel]) {
                        id sequence = ((id (*)(id, SEL))objc_msgSend)(timeline, seqSel);
                        if (sequence) {
                            SEL durSel = NSSelectorFromString(@"duration");
                            if ([sequence respondsToSelector:durSel]) {
                                FCPBridge_CMTime d = ((FCPBridge_CMTime (*)(id, SEL))objc_msgSend)(
                                    sequence, durSel);
                                durationSeconds = FCPBridge_cmtimeToSeconds(d);
                            }
                        }
                    }
                }
            }

            if (durationSeconds <= 0) {
                durationSeconds = 30.0; // fallback default
            }

            // Resolve song
            id song = nil;
            if (handle) {
                song = FCPBridge_resolveHandle(handle);
            }
            if (!song && songUID) {
                id library = FCPBridge_getFlexMusicLibrary();
                if (library) {
                    SEL forUIDSel = NSSelectorFromString(@"songForUID:");
                    if ([library respondsToSelector:forUIDSel]) {
                        song = ((id (*)(id, SEL, id))objc_msgSend)(library, forUIDSel, songUID);
                    }
                }
            }
            if (!song) {
                result = @{@"error": @"Song not found"};
                return;
            }

            FCPBridge_CMTime durTime = FCPBridge_cmtimeFromSeconds(durationSeconds);

            // Get song name for FCPXML
            NSString *songName = @"FlexMusic";
            SEL nameSel = NSSelectorFromString(@"name");
            if ([song respondsToSelector:nameSel]) {
                id n = ((id (*)(id, SEL))objc_msgSend)(song, nameSel);
                if (n) songName = n;
            }

            // Get rendition and export to temp file
            id rendition = nil;
            id options = @{};
            Class ffFlexObj = objc_getClass("FFAnchoredFlexMusicObject");
            if (ffFlexObj) {
                SEL optSel = NSSelectorFromString(@"optionsForDuration:");
                if ([ffFlexObj respondsToSelector:optSel]) {
                    options = ((id (*)(id, SEL, FCPBridge_CMTime))objc_msgSend)(
                        (id)ffFlexObj, optSel, durTime) ?: @{};
                }
            }
            SEL rendSel = NSSelectorFromString(@"renditionForDuration:withOptions:");
            if ([song respondsToSelector:rendSel]) {
                rendition = ((id (*)(id, SEL, FCPBridge_CMTime, id))objc_msgSend)(
                    song, rendSel, durTime, options);
            }
            if (!rendition) {
                SEL rendSel2 = NSSelectorFromString(@"renditionForDuration:");
                if ([song respondsToSelector:rendSel2]) {
                    rendition = ((id (*)(id, SEL, FCPBridge_CMTime))objc_msgSend)(
                        song, rendSel2, durTime);
                }
            }
            if (!rendition) {
                result = @{@"error": @"Could not get rendition for timeline insertion"};
                return;
            }

            // Export to temp file
            NSString *tempPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
                [NSString stringWithFormat:@"fcpbridge_flexmusic_%@.m4a",
                 [[NSUUID UUID] UUIDString]]];

            SEL compSel = NSSelectorFromString(@"avCompositionWithAudioMix:includeShortenedOutroFadeOut:");
            id composition = nil;
            id audioMix = nil;
            if ([rendition respondsToSelector:compSel]) {
                __unsafe_unretained id mixRef = nil;
                composition = ((id (*)(id, SEL, __unsafe_unretained id *, BOOL))objc_msgSend)(
                    rendition, compSel, &mixRef, YES);
                audioMix = mixRef;
            }
            if (!composition) {
                SEL simpleCompSel = NSSelectorFromString(@"avComposition");
                if ([rendition respondsToSelector:simpleCompSel]) {
                    composition = ((id (*)(id, SEL))objc_msgSend)(rendition, simpleCompSel);
                }
            }
            if (!composition) {
                result = @{@"error": @"Could not get AVComposition for export"};
                return;
            }

            [[NSFileManager defaultManager] removeItemAtPath:tempPath error:nil];

            Class exportClass = objc_getClass("AVAssetExportSession");
            SEL exportInitSel = NSSelectorFromString(@"exportSessionWithAsset:presetName:");
            id exportSession = ((id (*)(id, SEL, id, id))objc_msgSend)(
                (id)exportClass, exportInitSel, composition, @"AVAssetExportPresetAppleM4A");
            if (!exportSession) {
                result = @{@"error": @"Could not create export session"};
                return;
            }

            NSURL *outputURL = [NSURL fileURLWithPath:tempPath];
            ((void (*)(id, SEL, id))objc_msgSend)(exportSession,
                @selector(setOutputURL:), outputURL);
            ((void (*)(id, SEL, id))objc_msgSend)(exportSession,
                NSSelectorFromString(@"setOutputFileType:"), @"com.apple.m4a-audio");
            if (audioMix) {
                ((void (*)(id, SEL, id))objc_msgSend)(exportSession,
                    NSSelectorFromString(@"setAudioMix:"), audioMix);
            }

            dispatch_semaphore_t sem = dispatch_semaphore_create(0);
            __block BOOL exportOK = NO;
            ((void (*)(id, SEL, void(^)(void)))objc_msgSend)(exportSession,
                NSSelectorFromString(@"exportAsynchronouslyWithCompletionHandler:"),
                ^{
                    NSInteger status = ((NSInteger (*)(id, SEL))objc_msgSend)(
                        exportSession, NSSelectorFromString(@"status"));
                    exportOK = (status == 3);
                    dispatch_semaphore_signal(sem);
                });
            dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC));

            if (!exportOK) {
                result = @{@"error": @"Failed to render song audio for timeline import"};
                return;
            }

            // Import via FCPXML with the rendered audio file
            int durationFrames = (int)(durationSeconds * 24);
            NSString *escapedName = [[songName stringByReplacingOccurrencesOfString:@"&" withString:@"&amp;"]
                stringByReplacingOccurrencesOfString:@"\"" withString:@"&quot;"];
            escapedName = [escapedName stringByReplacingOccurrencesOfString:@"<" withString:@"&lt;"];

            NSString *xml = [NSString stringWithFormat:
                @"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
                @"<!DOCTYPE fcpxml>\n"
                @"<fcpxml version=\"1.11\">\n"
                @"  <resources>\n"
                @"    <asset id=\"flexmusic_audio\" src=\"file://%@\" hasAudio=\"1\" hasVideo=\"0\" "
                @"audioSources=\"1\" audioChannels=\"2\" audioRate=\"44100\"/>\n"
                @"  </resources>\n"
                @"  <library>\n"
                @"    <event name=\"FlexMusic Import\">\n"
                @"      <project name=\"%@ Audio\">\n"
                @"        <sequence format=\"r1\" tcStart=\"0s\" tcFormat=\"NDF\" "
                @"audioLayout=\"stereo\" audioRate=\"48k\">\n"
                @"          <spine>\n"
                @"            <asset-clip ref=\"flexmusic_audio\" name=\"%@\" "
                @"duration=\"%d/24s\" start=\"0s\"/>\n"
                @"          </spine>\n"
                @"        </sequence>\n"
                @"      </project>\n"
                @"    </event>\n"
                @"  </library>\n"
                @"</fcpxml>",
                [tempPath stringByAddingPercentEncodingWithAllowedCharacters:
                    [NSCharacterSet URLPathAllowedCharacterSet]],
                escapedName, escapedName, durationFrames];

            // Import the FCPXML
            NSString *xmlPath = [NSTemporaryDirectory()
                stringByAppendingPathComponent:@"fcpbridge_flexmusic_import.fcpxml"];
            NSData *data = [xml dataUsingEncoding:NSUTF8StringEncoding];
            [data writeToFile:xmlPath atomically:YES];
            NSURL *xmlURL = [NSURL fileURLWithPath:xmlPath];

            id app = ((id (*)(id, SEL))objc_msgSend)(
                objc_getClass("NSApplication"), @selector(sharedApplication));
            id delegate = ((id (*)(id, SEL))objc_msgSend)(app, @selector(delegate));

            SEL openSel = NSSelectorFromString(@"openXMLDocumentWithURL:bundleURL:display:sender:");
            if ([delegate respondsToSelector:openSel]) {
                ((void (*)(id, SEL, id, id, BOOL, id))objc_msgSend)(
                    delegate, openSel, xmlURL, nil, YES, nil);
                result = @{
                    @"status": @"ok",
                    @"songName": songName,
                    @"durationSeconds": @(durationSeconds),
                    @"audioFile": tempPath,
                    @"message": @"FlexMusic song added to timeline via FCPXML import"
                };
            } else {
                result = @{@"error": @"PEAppController does not respond to openXMLDocumentWithURL:"};
            }
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result ?: @{@"error": @"Failed to add song to timeline"};
}

// ---------- 6. montage.analyzeClips ----------

static NSDictionary *FCPBridge_handleMontageAnalyze(NSDictionary *params) {
    NSString *eventFilter = params[@"eventName"];

    __block NSDictionary *result = nil;
    FCPBridge_executeOnMainThread(^{
        @try {
            // Get clips from library events
            id libs = ((id (*)(id, SEL))objc_msgSend)(
                objc_getClass("FFLibraryDocument"), @selector(copyActiveLibraries));
            if (![libs isKindOfClass:[NSArray class]] || [(NSArray *)libs count] == 0) {
                result = @{@"error": @"No active library"};
                return;
            }

            id library = [(NSArray *)libs firstObject];
            SEL eventsSel = NSSelectorFromString(@"events");
            if (![library respondsToSelector:eventsSel]) {
                result = @{@"error": @"Library does not respond to events"};
                return;
            }
            id events = ((id (*)(id, SEL))objc_msgSend)(library, eventsSel);
            if (![events isKindOfClass:[NSArray class]] || [(NSArray *)events count] == 0) {
                result = @{@"error": @"No events in library"};
                return;
            }

            NSMutableArray *analyzedClips = [NSMutableArray array];
            NSInteger clipIndex = 0;

            for (id event in (NSArray *)events) {
                NSString *eventName = @"";
                if ([event respondsToSelector:@selector(displayName)])
                    eventName = ((id (*)(id, SEL))objc_msgSend)(event, @selector(displayName)) ?: @"";

                // Filter by event name if specified
                if (eventFilter.length > 0 &&
                    ![[eventName lowercaseString] containsString:[eventFilter lowercaseString]]) {
                    continue;
                }

                // Get clips from event (same logic as browser.listClips)
                id clips = nil;
                SEL displayClipsSel = NSSelectorFromString(@"displayOwnedClips");
                SEL ownedClipsSel = NSSelectorFromString(@"ownedClips");
                SEL childItemsSel = NSSelectorFromString(@"childItems");
                SEL itemsSel = NSSelectorFromString(@"items");

                if ([event respondsToSelector:displayClipsSel]) {
                    clips = ((id (*)(id, SEL))objc_msgSend)(event, displayClipsSel);
                } else if ([event respondsToSelector:ownedClipsSel]) {
                    clips = ((id (*)(id, SEL))objc_msgSend)(event, ownedClipsSel);
                } else if ([event respondsToSelector:childItemsSel]) {
                    clips = ((id (*)(id, SEL))objc_msgSend)(event, childItemsSel);
                } else if ([event respondsToSelector:itemsSel]) {
                    clips = ((id (*)(id, SEL))objc_msgSend)(event, itemsSel);
                }

                if (clips && [clips isKindOfClass:[NSSet class]]) {
                    clips = [(NSSet *)clips allObjects];
                }
                if (![clips isKindOfClass:[NSArray class]]) continue;

                for (id clip in (NSArray *)clips) {
                    @autoreleasepool {
                        NSMutableDictionary *info = [NSMutableDictionary dictionary];
                        info[@"index"] = @(clipIndex++);
                        info[@"event"] = eventName;

                        NSString *className = NSStringFromClass([clip class]);
                        info[@"class"] = className;

                        // Name
                        NSString *clipName = @"";
                        if ([clip respondsToSelector:@selector(displayName)]) {
                            clipName = ((id (*)(id, SEL))objc_msgSend)(clip, @selector(displayName)) ?: @"";
                        }
                        info[@"name"] = clipName;

                        // Duration
                        double durationSec = 0;
                        if ([clip respondsToSelector:@selector(duration)]) {
                            FCPBridge_CMTime d = ((FCPBridge_CMTime (*)(id, SEL))objc_msgSend)(
                                clip, @selector(duration));
                            durationSec = FCPBridge_cmtimeToSeconds(d);
                            info[@"duration"] = FCPBridge_serializeCMTime(d);
                            info[@"durationSeconds"] = @(durationSec);
                        }

                        // Determine media type from class name
                        NSString *mediaType = @"unknown";
                        if ([className containsString:@"Photo"] || [className containsString:@"Image"] ||
                            [className containsString:@"Still"]) {
                            mediaType = @"photo";
                        } else if ([className containsString:@"Audio"] || [className containsString:@"Sound"]) {
                            mediaType = @"audio";
                        } else if ([className containsString:@"Video"] || [className containsString:@"Media"] ||
                                   [className containsString:@"Asset"] || [className containsString:@"Clip"]) {
                            mediaType = @"video";
                        }
                        // Check for hasVideo / hasAudio properties
                        SEL hasVideoSel = NSSelectorFromString(@"hasVideo");
                        SEL hasAudioSel = NSSelectorFromString(@"hasAudio");
                        BOOL hasVideo = NO, hasAudio = NO;
                        if ([clip respondsToSelector:hasVideoSel]) {
                            hasVideo = ((BOOL (*)(id, SEL))objc_msgSend)(clip, hasVideoSel);
                        }
                        if ([clip respondsToSelector:hasAudioSel]) {
                            hasAudio = ((BOOL (*)(id, SEL))objc_msgSend)(clip, hasAudioSel);
                        }
                        if (hasVideo) mediaType = @"video";
                        else if (hasAudio && !hasVideo) mediaType = @"audio";
                        info[@"mediaType"] = mediaType;
                        info[@"hasVideo"] = @(hasVideo);
                        info[@"hasAudio"] = @(hasAudio);

                        // Score: videos > photos > audio; longer clips score higher
                        double score = 0;
                        if ([mediaType isEqualToString:@"video"]) {
                            score = 10.0 + MIN(durationSec, 30.0);
                        } else if ([mediaType isEqualToString:@"photo"]) {
                            score = 5.0;
                        } else if ([mediaType isEqualToString:@"audio"]) {
                            score = 1.0;
                        } else {
                            score = 3.0 + MIN(durationSec, 10.0);
                        }
                        // Bonus for clips with audio (likely have dialogue)
                        if (hasAudio && hasVideo) score += 2.0;
                        info[@"score"] = @(score);

                        // Check for media reference / file path
                        SEL mediaRefSel = NSSelectorFromString(@"mediaReference");
                        if ([clip respondsToSelector:mediaRefSel]) {
                            id mediaRef = ((id (*)(id, SEL))objc_msgSend)(clip, mediaRefSel);
                            if (mediaRef) {
                                SEL urlSel = NSSelectorFromString(@"url");
                                SEL pathSel = NSSelectorFromString(@"mediaPath");
                                if ([mediaRef respondsToSelector:urlSel]) {
                                    id url = ((id (*)(id, SEL))objc_msgSend)(mediaRef, urlSel);
                                    if (url) info[@"mediaURL"] = [url absoluteString] ?: @"";
                                } else if ([mediaRef respondsToSelector:pathSel]) {
                                    id path = ((id (*)(id, SEL))objc_msgSend)(mediaRef, pathSel);
                                    if (path) info[@"mediaPath"] = path;
                                }
                            }
                        }

                        // Store handle
                        NSString *h = FCPBridge_storeHandle(clip);
                        info[@"handle"] = h;

                        [analyzedClips addObject:info];
                    }
                }
            }

            // Sort by score descending
            [analyzedClips sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
                return [b[@"score"] compare:a[@"score"]];
            }];

            result = @{@"clips": analyzedClips, @"count": @(analyzedClips.count)};
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result ?: @{@"error": @"Failed to analyze clips"};
}

// ---------- 7. montage.planEdit ----------

static NSDictionary *FCPBridge_handleMontagePlan(NSDictionary *params) {
    NSArray *beats = params[@"beats"];
    NSArray *bars = params[@"bars"];
    NSArray *clips = params[@"clips"];
    NSString *style = params[@"style"] ?: @"bar";
    NSNumber *totalDurationNum = params[@"totalDuration"];

    if (!clips || ![clips isKindOfClass:[NSArray class]] || clips.count == 0) {
        return @{@"error": @"clips array parameter required (with handle, duration, score)"};
    }

    // Determine cut points based on style
    NSArray *cutPoints = nil;
    if ([style isEqualToString:@"beat"]) {
        cutPoints = beats;
    } else if ([style isEqualToString:@"section"]) {
        NSArray *sections = params[@"sections"];
        cutPoints = (sections && [sections isKindOfClass:[NSArray class]] && sections.count > 0)
            ? sections : bars;
    } else {
        cutPoints = bars;
    }

    if (!cutPoints || ![cutPoints isKindOfClass:[NSArray class]] || cutPoints.count < 2) {
        return @{@"error": @"Not enough timing data (beats/bars) to plan edit. Need at least 2 cut points."};
    }

    double totalDuration = totalDurationNum ? [totalDurationNum doubleValue] :
        [[cutPoints lastObject] doubleValue];

    // Sort cut points
    NSArray *sortedCuts = [cutPoints sortedArrayUsingSelector:@selector(compare:)];

    // Sort clips by score descending for assignment
    NSArray *sortedClips = [clips sortedArrayUsingComparator:
        ^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            return [b[@"score"] compare:a[@"score"]];
        }];

    NSMutableArray *editPlan = [NSMutableArray array];
    NSMutableSet *usedHandles = [NSMutableSet set];
    NSInteger clipPoolIndex = 0;

    for (NSUInteger i = 0; i < sortedCuts.count - 1; i++) {
        double segStart = [sortedCuts[i] doubleValue];
        double segEnd = [sortedCuts[i + 1] doubleValue];
        double segDuration = segEnd - segStart;

        if (segDuration <= 0.01) continue; // skip degenerate segments

        // Pick the highest-scoring unused clip
        NSDictionary *chosenClip = nil;
        for (NSUInteger j = 0; j < sortedClips.count; j++) {
            NSString *h = sortedClips[j][@"handle"];
            if (h && ![usedHandles containsObject:h]) {
                chosenClip = sortedClips[j];
                [usedHandles addObject:h];
                break;
            }
        }

        // If all clips used, start reusing from the top
        if (!chosenClip) {
            [usedHandles removeAllObjects];
            chosenClip = sortedClips[clipPoolIndex % sortedClips.count];
            NSString *h = chosenClip[@"handle"];
            if (h) [usedHandles addObject:h];
            clipPoolIndex++;
        }

        double clipDuration = [chosenClip[@"durationSeconds"] doubleValue];
        if (clipDuration <= 0) clipDuration = [chosenClip[@"duration"] doubleValue];

        // Calculate in/out points (center the best part)
        double inPoint = 0;
        double outPoint = segDuration;
        if (clipDuration > segDuration) {
            inPoint = (clipDuration - segDuration) / 2.0;
            outPoint = inPoint + segDuration;
        } else {
            outPoint = MIN(clipDuration, segDuration);
        }

        NSMutableDictionary *entry = [NSMutableDictionary dictionary];
        entry[@"clipHandle"] = chosenClip[@"handle"] ?: @"";
        entry[@"clipName"] = chosenClip[@"name"] ?: @"";
        entry[@"inSeconds"] = @(inPoint);
        entry[@"outSeconds"] = @(outPoint);
        entry[@"timelineStartSeconds"] = @(segStart);
        entry[@"durationSeconds"] = @(segDuration);
        entry[@"segmentIndex"] = @(i);

        [editPlan addObject:entry];
    }

    return @{
        @"editPlan": editPlan,
        @"segmentCount": @(editPlan.count),
        @"totalDurationSeconds": @(totalDuration),
        @"style": style,
        @"cutPointCount": @(sortedCuts.count)
    };
}

// ---------- 8. montage.assemble ----------

static NSDictionary *FCPBridge_handleMontageAssemble(NSDictionary *params) {
    NSArray *editPlan = params[@"editPlan"];
    NSString *projectName = params[@"projectName"] ?: @"FCPBridge Montage";
    NSString *songFile = params[@"songFile"];

    if (!editPlan || ![editPlan isKindOfClass:[NSArray class]] || editPlan.count == 0) {
        return @{@"error": @"editPlan array parameter required"};
    }

    __block NSDictionary *result = nil;
    FCPBridge_executeOnMainThread(^{
        @try {
            // Collect unique media files from clip handles
            NSMutableDictionary *mediaResources = [NSMutableDictionary dictionary];
            NSMutableArray *spineClips = [NSMutableArray array];

            int resourceIndex = 0;
            for (NSDictionary *entry in editPlan) {
                NSString *clipHandle = entry[@"clipHandle"];
                id clip = clipHandle ? FCPBridge_resolveHandle(clipHandle) : nil;

                NSString *resourceId = nil;
                NSString *mediaURL = @"";
                NSString *clipName = entry[@"clipName"] ?: @"Clip";

                if (clip) {
                    SEL mediaRefSel = NSSelectorFromString(@"mediaReference");
                    if ([clip respondsToSelector:mediaRefSel]) {
                        id mediaRef = ((id (*)(id, SEL))objc_msgSend)(clip, mediaRefSel);
                        if (mediaRef) {
                            SEL urlSel = NSSelectorFromString(@"url");
                            if ([mediaRef respondsToSelector:urlSel]) {
                                id url = ((id (*)(id, SEL))objc_msgSend)(mediaRef, urlSel);
                                if (url) mediaURL = [url absoluteString] ?: @"";
                            }
                        }
                    }
                    if (mediaURL.length == 0) {
                        SEL srcSel = NSSelectorFromString(@"sourceMediaURL");
                        if ([clip respondsToSelector:srcSel]) {
                            id url = ((id (*)(id, SEL))objc_msgSend)(clip, srcSel);
                            if (url) mediaURL = [url absoluteString] ?: @"";
                        }
                    }
                }

                // Deduplicate resources by media URL
                if (mediaURL.length > 0 && mediaResources[mediaURL]) {
                    resourceId = mediaResources[mediaURL][@"id"];
                } else {
                    resourceId = [NSString stringWithFormat:@"r%d", ++resourceIndex];
                    if (mediaURL.length > 0) {
                        mediaResources[mediaURL] = @{@"id": resourceId, @"url": mediaURL};
                    }
                }

                double inSec = [entry[@"inSeconds"] doubleValue];
                double durSec = [entry[@"durationSeconds"] doubleValue];
                double tlStart = [entry[@"timelineStartSeconds"] doubleValue];

                [spineClips addObject:@{
                    @"resourceId": resourceId ?: @"r0",
                    @"name": clipName,
                    @"inSeconds": @(inSec),
                    @"durationSeconds": @(durSec),
                    @"timelineStartSeconds": @(tlStart),
                    @"mediaURL": mediaURL
                }];
            }

            // Build FCPXML 1.11 document
            NSMutableString *xml = [NSMutableString string];
            [xml appendString:@"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"];
            [xml appendString:@"<!DOCTYPE fcpxml>\n"];
            [xml appendString:@"<fcpxml version=\"1.11\">\n"];
            [xml appendString:@"  <resources>\n"];
            [xml appendString:@"    <format id=\"r0\" frameDuration=\"1/24s\" width=\"1920\" "
                                @"height=\"1080\" name=\"FFVideoFormat1080p24\"/>\n"];

            for (NSString *urlKey in mediaResources) {
                NSDictionary *res = mediaResources[urlKey];
                [xml appendFormat:@"    <asset id=\"%@\" src=\"%@\" hasAudio=\"1\" hasVideo=\"1\"/>\n",
                    res[@"id"], res[@"url"]];
            }

            if (songFile.length > 0) {
                NSURL *songURL = [NSURL fileURLWithPath:songFile];
                [xml appendFormat:@"    <asset id=\"song_audio\" src=\"%@\" "
                    @"hasAudio=\"1\" hasVideo=\"0\" audioSources=\"1\" "
                    @"audioChannels=\"2\" audioRate=\"44100\"/>\n",
                    [songURL absoluteString]];
            }

            [xml appendString:@"  </resources>\n"];
            [xml appendString:@"  <library>\n"];
            [xml appendString:@"    <event name=\"Montage\">\n"];
            [xml appendFormat:@"      <project name=\"%@\">\n",
                [projectName stringByReplacingOccurrencesOfString:@"\"" withString:@"&quot;"]];

            // Calculate total duration
            double totalDuration = 0;
            for (NSDictionary *clip in spineClips) {
                double end = [clip[@"timelineStartSeconds"] doubleValue] +
                             [clip[@"durationSeconds"] doubleValue];
                if (end > totalDuration) totalDuration = end;
            }
            int totalFrames = (int)(totalDuration * 24);

            [xml appendFormat:@"        <sequence format=\"r0\" tcStart=\"0s\" tcFormat=\"NDF\" "
                @"audioLayout=\"stereo\" audioRate=\"48k\" duration=\"%d/24s\">\n", totalFrames];
            [xml appendString:@"          <spine>\n"];

            // Add clips to spine with gaps where needed
            double currentTime = 0;
            for (NSUInteger i = 0; i < spineClips.count; i++) {
                NSDictionary *clip = spineClips[i];
                double tlStart = [clip[@"timelineStartSeconds"] doubleValue];
                double durSec = [clip[@"durationSeconds"] doubleValue];
                double inSec = [clip[@"inSeconds"] doubleValue];

                if (tlStart > currentTime + 0.001) {
                    double gapDur = tlStart - currentTime;
                    int gapFrames = (int)(gapDur * 24);
                    if (gapFrames > 0) {
                        [xml appendFormat:@"            <gap duration=\"%d/24s\"/>\n", gapFrames];
                    }
                }

                int durFrames = (int)(durSec * 24);
                int inFrames = (int)(inSec * 24);

                NSString *name = clip[@"name"];
                NSString *escapedName = [[name stringByReplacingOccurrencesOfString:@"&" withString:@"&amp;"]
                    stringByReplacingOccurrencesOfString:@"\"" withString:@"&quot;"];
                escapedName = [escapedName stringByReplacingOccurrencesOfString:@"<" withString:@"&lt;"];

                if ([clip[@"mediaURL"] length] > 0) {
                    [xml appendFormat:@"            <asset-clip ref=\"%@\" name=\"%@\" "
                        @"duration=\"%d/24s\" start=\"%d/24s\"",
                        clip[@"resourceId"], escapedName, durFrames, inFrames];
                } else {
                    [xml appendFormat:@"            <gap name=\"%@\" duration=\"%d/24s\"",
                        escapedName, durFrames];
                }

                // Add Cross Dissolve transition between clips if not last
                if (i < spineClips.count - 1) {
                    [xml appendString:@">\n"];
                    if ([clip[@"mediaURL"] length] > 0) {
                        [xml appendString:@"            </asset-clip>\n"];
                    } else {
                        [xml appendString:@"            </gap>\n"];
                    }
                    [xml appendString:@"            <transition duration=\"12/24s\" "
                        @"name=\"Cross Dissolve\"/>\n"];
                } else {
                    [xml appendString:@"/>\n"];
                }

                currentTime = tlStart + durSec;
            }

            [xml appendString:@"          </spine>\n"];

            if (songFile.length > 0) {
                int songFrames = totalFrames;
                [xml appendFormat:@"          <asset-clip ref=\"song_audio\" name=\"Music\" "
                    @"lane=\"-1\" duration=\"%d/24s\" start=\"0s\" "
                    @"offset=\"0s\"/>\n", songFrames];
            }

            [xml appendString:@"        </sequence>\n"];
            [xml appendString:@"      </project>\n"];
            [xml appendString:@"    </event>\n"];
            [xml appendString:@"  </library>\n"];
            [xml appendString:@"</fcpxml>"];

            // Write and import FCPXML
            NSString *xmlPath = [NSTemporaryDirectory()
                stringByAppendingPathComponent:@"fcpbridge_montage.fcpxml"];
            NSData *data = [xml dataUsingEncoding:NSUTF8StringEncoding];
            [data writeToFile:xmlPath atomically:YES];
            NSURL *xmlURL = [NSURL fileURLWithPath:xmlPath];

            id app = ((id (*)(id, SEL))objc_msgSend)(
                objc_getClass("NSApplication"), @selector(sharedApplication));
            id delegate = ((id (*)(id, SEL))objc_msgSend)(app, @selector(delegate));

            SEL openSel = NSSelectorFromString(@"openXMLDocumentWithURL:bundleURL:display:sender:");
            if ([delegate respondsToSelector:openSel]) {
                ((void (*)(id, SEL, id, id, BOOL, id))objc_msgSend)(
                    delegate, openSel, xmlURL, nil, YES, nil);
                result = @{
                    @"status": @"ok",
                    @"projectName": projectName,
                    @"clipCount": @(spineClips.count),
                    @"totalDurationSeconds": @(totalDuration),
                    @"hasSongAudio": @(songFile.length > 0),
                    @"fcpxmlPath": xmlPath,
                    @"message": @"Montage assembled and imported via FCPXML"
                };
            } else {
                result = @{@"error": @"PEAppController does not respond to openXMLDocumentWithURL:"};
            }
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result ?: @{@"error": @"Failed to assemble montage"};
}

// ---------- 9. montage.auto ----------

static NSDictionary *FCPBridge_handleMontageAuto(NSDictionary *params) {
    NSString *songUID = params[@"songUID"];
    NSString *songHandle = params[@"songHandle"];
    NSString *eventName = params[@"eventName"];
    NSString *style = params[@"style"] ?: @"bar";
    NSString *projectName = params[@"projectName"] ?: @"Auto Montage";

    if (!songUID && !songHandle) return @{@"error": @"songUID or songHandle parameter required"};

    __block NSDictionary *result = nil;
    FCPBridge_executeOnMainThread(^{
        @try {
            // Step 1: Analyze clips from library
            id libs = ((id (*)(id, SEL))objc_msgSend)(
                objc_getClass("FFLibraryDocument"), @selector(copyActiveLibraries));
            if (![libs isKindOfClass:[NSArray class]] || [(NSArray *)libs count] == 0) {
                result = @{@"error": @"No active library"};
                return;
            }

            id library = [(NSArray *)libs firstObject];
            SEL eventsSel = NSSelectorFromString(@"events");
            if (![library respondsToSelector:eventsSel]) {
                result = @{@"error": @"Library does not respond to events"};
                return;
            }
            id events = ((id (*)(id, SEL))objc_msgSend)(library, eventsSel);
            if (![events isKindOfClass:[NSArray class]] || [(NSArray *)events count] == 0) {
                result = @{@"error": @"No events in library"};
                return;
            }

            NSMutableArray *analyzedClips = [NSMutableArray array];
            for (id event in (NSArray *)events) {
                NSString *evName = @"";
                if ([event respondsToSelector:@selector(displayName)])
                    evName = ((id (*)(id, SEL))objc_msgSend)(event, @selector(displayName)) ?: @"";

                if (eventName.length > 0 &&
                    ![[evName lowercaseString] containsString:[eventName lowercaseString]]) {
                    continue;
                }

                id clips = nil;
                SEL displayClipsSel = NSSelectorFromString(@"displayOwnedClips");
                SEL ownedClipsSel = NSSelectorFromString(@"ownedClips");
                if ([event respondsToSelector:displayClipsSel]) {
                    clips = ((id (*)(id, SEL))objc_msgSend)(event, displayClipsSel);
                } else if ([event respondsToSelector:ownedClipsSel]) {
                    clips = ((id (*)(id, SEL))objc_msgSend)(event, ownedClipsSel);
                }
                if (clips && [clips isKindOfClass:[NSSet class]])
                    clips = [(NSSet *)clips allObjects];
                if (![clips isKindOfClass:[NSArray class]]) continue;

                for (id clip in (NSArray *)clips) {
                    @autoreleasepool {
                        NSMutableDictionary *info = [NSMutableDictionary dictionary];

                        NSString *clipName = @"";
                        if ([clip respondsToSelector:@selector(displayName)])
                            clipName = ((id (*)(id, SEL))objc_msgSend)(clip, @selector(displayName)) ?: @"";
                        info[@"name"] = clipName;

                        double durationSec = 0;
                        if ([clip respondsToSelector:@selector(duration)]) {
                            FCPBridge_CMTime d = ((FCPBridge_CMTime (*)(id, SEL))objc_msgSend)(
                                clip, @selector(duration));
                            durationSec = FCPBridge_cmtimeToSeconds(d);
                        }
                        info[@"durationSeconds"] = @(durationSec);

                        BOOL hasVideo = NO;
                        SEL hasVideoSel = NSSelectorFromString(@"hasVideo");
                        if ([clip respondsToSelector:hasVideoSel])
                            hasVideo = ((BOOL (*)(id, SEL))objc_msgSend)(clip, hasVideoSel);

                        double score = hasVideo ? (10.0 + MIN(durationSec, 30.0)) : 3.0;
                        info[@"score"] = @(score);

                        NSString *h = FCPBridge_storeHandle(clip);
                        info[@"handle"] = h;

                        [analyzedClips addObject:info];
                    }
                }
            }

            if (analyzedClips.count == 0) {
                result = @{@"error": @"No clips found in library/event for montage"};
                return;
            }

            [analyzedClips sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
                return [b[@"score"] compare:a[@"score"]];
            }];

            // Calculate total clip duration for song fitting
            double totalClipDuration = 0;
            for (NSDictionary *c in analyzedClips) {
                totalClipDuration += [c[@"durationSeconds"] doubleValue];
            }
            double montageDuration = MIN(totalClipDuration, 120.0);
            if (montageDuration < 5.0) montageDuration = 30.0;

            // Step 2: Get timing from song
            id song = nil;
            if (songHandle) {
                song = FCPBridge_resolveHandle(songHandle);
            }
            if (!song && songUID) {
                id fmLibrary = FCPBridge_getFlexMusicLibrary();
                if (fmLibrary) {
                    SEL forUIDSel = NSSelectorFromString(@"songForUID:");
                    if ([fmLibrary respondsToSelector:forUIDSel]) {
                        song = ((id (*)(id, SEL, id))objc_msgSend)(fmLibrary, forUIDSel, songUID);
                    }
                }
            }
            if (!song) {
                result = @{@"error": @"Song not found for montage"};
                return;
            }

            FCPBridge_CMTime durTime = FCPBridge_cmtimeFromSeconds(montageDuration);

            id rendition = nil;
            id options = @{};
            Class ffFlexObj = objc_getClass("FFAnchoredFlexMusicObject");
            if (ffFlexObj) {
                SEL optSel = NSSelectorFromString(@"optionsForDuration:");
                if ([ffFlexObj respondsToSelector:optSel]) {
                    options = ((id (*)(id, SEL, FCPBridge_CMTime))objc_msgSend)(
                        (id)ffFlexObj, optSel, durTime) ?: @{};
                }
            }
            SEL rendSel = NSSelectorFromString(@"renditionForDuration:withOptions:");
            if ([song respondsToSelector:rendSel]) {
                rendition = ((id (*)(id, SEL, FCPBridge_CMTime, id))objc_msgSend)(
                    song, rendSel, durTime, options);
            }
            if (!rendition) {
                SEL rendSel2 = NSSelectorFromString(@"renditionForDuration:");
                if ([song respondsToSelector:rendSel2]) {
                    rendition = ((id (*)(id, SEL, FCPBridge_CMTime))objc_msgSend)(
                        song, rendSel2, durTime);
                }
            }
            if (!rendition) {
                result = @{@"error": @"Could not get song rendition for montage"};
                return;
            }

            // Get actual fitted duration
            double fittedDuration = montageDuration;
            SEL rendDurSel = NSSelectorFromString(@"duration");
            if ([rendition respondsToSelector:rendDurSel]) {
                FCPBridge_CMTime rd = ((FCPBridge_CMTime (*)(id, SEL))objc_msgSend)(rendition, rendDurSel);
                fittedDuration = FCPBridge_cmtimeToSeconds(rd);
                if (fittedDuration > 0) montageDuration = fittedDuration;
            }

            // Extract timing
            NSString *barId = FCPBridge_flexMusicConstant("FMTimedMetadataIdentifierBar");
            NSString *beatId = FCPBridge_flexMusicConstant("FMTimedMetadataIdentifierBeat");
            SEL timedMetaSel = NSSelectorFromString(@"timedMetadataItemsWithIdentifier:");
            BOOL hasTimedMeta = [rendition respondsToSelector:timedMetaSel];

            NSArray *(^extractTimesAuto)(NSString *) = ^NSArray *(NSString *identifier) {
                if (!identifier || !hasTimedMeta) return @[];
                id items = ((id (*)(id, SEL, id))objc_msgSend)(rendition, timedMetaSel, identifier);
                if (![items isKindOfClass:[NSArray class]]) return @[];
                NSMutableArray *times = [NSMutableArray array];
                [times addObject:@(0.0)];
                for (id item in (NSArray *)items) {
                    SEL timeSel = NSSelectorFromString(@"time");
                    if ([item respondsToSelector:timeSel]) {
                        FCPBridge_CMTime t = ((FCPBridge_CMTime (*)(id, SEL))objc_msgSend)(item, timeSel);
                        double sec = FCPBridge_cmtimeToSeconds(t);
                        if (sec > 0 && sec < montageDuration) [times addObject:@(sec)];
                    }
                }
                [times addObject:@(montageDuration)];
                return times;
            };

            NSArray *barTimes = extractTimesAuto(barId);
            NSArray *beatTimes = extractTimesAuto(beatId);
            NSArray *cutPoints = [style isEqualToString:@"beat"] ? beatTimes : barTimes;

            // If we got no timing data, create evenly spaced cuts
            if (cutPoints.count < 2) {
                NSMutableArray *evenCuts = [NSMutableArray array];
                double interval = montageDuration / MAX(analyzedClips.count, 4);
                for (double t = 0; t <= montageDuration; t += interval) {
                    [evenCuts addObject:@(t)];
                }
                if ([[evenCuts lastObject] doubleValue] < montageDuration - 0.5) {
                    [evenCuts addObject:@(montageDuration)];
                }
                cutPoints = evenCuts;
            }

            // Step 3: Plan the edit
            NSArray *sortedCuts = [cutPoints sortedArrayUsingSelector:@selector(compare:)];
            NSMutableArray *editPlan = [NSMutableArray array];
            NSMutableSet *usedHandles = [NSMutableSet set];

            NSArray *sortedClips = [analyzedClips sortedArrayUsingComparator:
                ^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
                    return [b[@"score"] compare:a[@"score"]];
                }];

            NSInteger poolIdx = 0;
            for (NSUInteger i = 0; i < sortedCuts.count - 1; i++) {
                double segStart = [sortedCuts[i] doubleValue];
                double segEnd = [sortedCuts[i + 1] doubleValue];
                double segDuration = segEnd - segStart;
                if (segDuration <= 0.01) continue;

                NSDictionary *chosenClip = nil;
                for (NSUInteger j = 0; j < sortedClips.count; j++) {
                    NSString *ch = sortedClips[j][@"handle"];
                    if (ch && ![usedHandles containsObject:ch]) {
                        chosenClip = sortedClips[j];
                        [usedHandles addObject:ch];
                        break;
                    }
                }
                if (!chosenClip) {
                    [usedHandles removeAllObjects];
                    chosenClip = sortedClips[poolIdx % sortedClips.count];
                    NSString *ch = chosenClip[@"handle"];
                    if (ch) [usedHandles addObject:ch];
                    poolIdx++;
                }

                double clipDur = [chosenClip[@"durationSeconds"] doubleValue];
                double inPt = 0;
                if (clipDur > segDuration) {
                    inPt = (clipDur - segDuration) / 2.0;
                }

                [editPlan addObject:@{
                    @"clipHandle": chosenClip[@"handle"] ?: @"",
                    @"clipName": chosenClip[@"name"] ?: @"",
                    @"inSeconds": @(inPt),
                    @"outSeconds": @(inPt + MIN(clipDur, segDuration)),
                    @"timelineStartSeconds": @(segStart),
                    @"durationSeconds": @(segDuration)
                }];
            }

            if (editPlan.count == 0) {
                result = @{@"error": @"Edit plan is empty - not enough cut points or clips"};
                return;
            }

            // Step 4: Render song to temp file
            NSString *tempSongPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
                [NSString stringWithFormat:@"fcpbridge_montage_song_%@.m4a",
                 [[NSUUID UUID] UUIDString]]];

            SEL compSel = NSSelectorFromString(@"avCompositionWithAudioMix:includeShortenedOutroFadeOut:");
            id composition = nil;
            id audioMix = nil;
            if ([rendition respondsToSelector:compSel]) {
                __unsafe_unretained id mixRef = nil;
                composition = ((id (*)(id, SEL, __unsafe_unretained id *, BOOL))objc_msgSend)(
                    rendition, compSel, &mixRef, YES);
                audioMix = mixRef;
            }
            if (!composition) {
                SEL simpleCompSel = NSSelectorFromString(@"avComposition");
                if ([rendition respondsToSelector:simpleCompSel])
                    composition = ((id (*)(id, SEL))objc_msgSend)(rendition, simpleCompSel);
            }

            BOOL songRendered = NO;
            if (composition) {
                [[NSFileManager defaultManager] removeItemAtPath:tempSongPath error:nil];
                Class exportClass = objc_getClass("AVAssetExportSession");
                SEL exportInitSel = NSSelectorFromString(@"exportSessionWithAsset:presetName:");
                id exportSession = ((id (*)(id, SEL, id, id))objc_msgSend)(
                    (id)exportClass, exportInitSel, composition, @"AVAssetExportPresetAppleM4A");
                if (exportSession) {
                    NSURL *outURL = [NSURL fileURLWithPath:tempSongPath];
                    ((void (*)(id, SEL, id))objc_msgSend)(exportSession,
                        @selector(setOutputURL:), outURL);
                    ((void (*)(id, SEL, id))objc_msgSend)(exportSession,
                        NSSelectorFromString(@"setOutputFileType:"), @"com.apple.m4a-audio");
                    if (audioMix) {
                        ((void (*)(id, SEL, id))objc_msgSend)(exportSession,
                            NSSelectorFromString(@"setAudioMix:"), audioMix);
                    }
                    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
                    __block BOOL expOK = NO;
                    ((void (*)(id, SEL, void(^)(void)))objc_msgSend)(exportSession,
                        NSSelectorFromString(@"exportAsynchronouslyWithCompletionHandler:"),
                        ^{
                            NSInteger status = ((NSInteger (*)(id, SEL))objc_msgSend)(
                                exportSession, NSSelectorFromString(@"status"));
                            expOK = (status == 3);
                            dispatch_semaphore_signal(sem);
                        });
                    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC));
                    songRendered = expOK;
                }
            }

            // Step 5: Assemble montage via FCPXML
            NSMutableDictionary *mediaResources = [NSMutableDictionary dictionary];
            NSMutableArray *spineClips = [NSMutableArray array];
            int resIdx = 0;

            for (NSDictionary *entry in editPlan) {
                NSString *clipHandle = entry[@"clipHandle"];
                id clip = clipHandle ? FCPBridge_resolveHandle(clipHandle) : nil;
                NSString *mediaURL = @"";

                if (clip) {
                    SEL mediaRefSel = NSSelectorFromString(@"mediaReference");
                    if ([clip respondsToSelector:mediaRefSel]) {
                        id mediaRef = ((id (*)(id, SEL))objc_msgSend)(clip, mediaRefSel);
                        if (mediaRef) {
                            SEL urlSel = NSSelectorFromString(@"url");
                            if ([mediaRef respondsToSelector:urlSel]) {
                                id url = ((id (*)(id, SEL))objc_msgSend)(mediaRef, urlSel);
                                if (url) mediaURL = [url absoluteString] ?: @"";
                            }
                        }
                    }
                    if (mediaURL.length == 0) {
                        SEL srcSel = NSSelectorFromString(@"sourceMediaURL");
                        if ([clip respondsToSelector:srcSel]) {
                            id url = ((id (*)(id, SEL))objc_msgSend)(clip, srcSel);
                            if (url) mediaURL = [url absoluteString] ?: @"";
                        }
                    }
                }

                NSString *resId = nil;
                if (mediaURL.length > 0 && mediaResources[mediaURL]) {
                    resId = mediaResources[mediaURL][@"id"];
                } else if (mediaURL.length > 0) {
                    resId = [NSString stringWithFormat:@"r%d", ++resIdx];
                    mediaResources[mediaURL] = @{@"id": resId, @"url": mediaURL};
                }

                [spineClips addObject:@{
                    @"resourceId": resId ?: @"r0",
                    @"name": entry[@"clipName"] ?: @"Clip",
                    @"inSeconds": entry[@"inSeconds"] ?: @0,
                    @"durationSeconds": entry[@"durationSeconds"] ?: @0,
                    @"timelineStartSeconds": entry[@"timelineStartSeconds"] ?: @0,
                    @"mediaURL": mediaURL
                }];
            }

            NSMutableString *xml = [NSMutableString string];
            [xml appendString:@"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"];
            [xml appendString:@"<!DOCTYPE fcpxml>\n"];
            [xml appendString:@"<fcpxml version=\"1.11\">\n"];
            [xml appendString:@"  <resources>\n"];
            [xml appendString:@"    <format id=\"r0\" frameDuration=\"1/24s\" width=\"1920\" "
                                @"height=\"1080\" name=\"FFVideoFormat1080p24\"/>\n"];
            for (NSString *urlKey in mediaResources) {
                NSDictionary *res = mediaResources[urlKey];
                [xml appendFormat:@"    <asset id=\"%@\" src=\"%@\" hasAudio=\"1\" hasVideo=\"1\"/>\n",
                    res[@"id"], res[@"url"]];
            }
            if (songRendered) {
                NSURL *songURL = [NSURL fileURLWithPath:tempSongPath];
                [xml appendFormat:@"    <asset id=\"song_audio\" src=\"%@\" "
                    @"hasAudio=\"1\" hasVideo=\"0\" audioSources=\"1\" "
                    @"audioChannels=\"2\" audioRate=\"44100\"/>\n", [songURL absoluteString]];
            }
            [xml appendString:@"  </resources>\n"];

            int totalFrames = (int)(montageDuration * 24);
            NSString *escapedProject = [projectName
                stringByReplacingOccurrencesOfString:@"\"" withString:@"&quot;"];

            [xml appendString:@"  <library>\n"];
            [xml appendString:@"    <event name=\"Montage\">\n"];
            [xml appendFormat:@"      <project name=\"%@\">\n", escapedProject];
            [xml appendFormat:@"        <sequence format=\"r0\" tcStart=\"0s\" tcFormat=\"NDF\" "
                @"audioLayout=\"stereo\" audioRate=\"48k\" duration=\"%d/24s\">\n", totalFrames];
            [xml appendString:@"          <spine>\n"];

            double curTime = 0;
            for (NSUInteger i = 0; i < spineClips.count; i++) {
                NSDictionary *sc = spineClips[i];
                double tlStart = [sc[@"timelineStartSeconds"] doubleValue];
                double dur = [sc[@"durationSeconds"] doubleValue];
                double inSec = [sc[@"inSeconds"] doubleValue];

                if (tlStart > curTime + 0.001) {
                    int gapFrames = (int)((tlStart - curTime) * 24);
                    if (gapFrames > 0)
                        [xml appendFormat:@"            <gap duration=\"%d/24s\"/>\n", gapFrames];
                }

                int durFrames = (int)(dur * 24);
                int inFrames = (int)(inSec * 24);
                NSString *name = sc[@"name"];
                NSString *escaped = [[name stringByReplacingOccurrencesOfString:@"&" withString:@"&amp;"]
                    stringByReplacingOccurrencesOfString:@"\"" withString:@"&quot;"];
                escaped = [escaped stringByReplacingOccurrencesOfString:@"<" withString:@"&lt;"];

                if ([sc[@"mediaURL"] length] > 0) {
                    [xml appendFormat:@"            <asset-clip ref=\"%@\" name=\"%@\" "
                        @"duration=\"%d/24s\" start=\"%d/24s\"", sc[@"resourceId"], escaped,
                        durFrames, inFrames];
                } else {
                    [xml appendFormat:@"            <gap name=\"%@\" duration=\"%d/24s\"",
                        escaped, durFrames];
                }

                if (i < spineClips.count - 1) {
                    [xml appendString:@"/>\n"];
                    [xml appendString:@"            <transition duration=\"12/24s\" "
                        @"name=\"Cross Dissolve\"/>\n"];
                } else {
                    [xml appendString:@"/>\n"];
                }
                curTime = tlStart + dur;
            }

            [xml appendString:@"          </spine>\n"];
            if (songRendered) {
                [xml appendFormat:@"          <asset-clip ref=\"song_audio\" name=\"Music\" "
                    @"lane=\"-1\" duration=\"%d/24s\" start=\"0s\" offset=\"0s\"/>\n", totalFrames];
            }
            [xml appendString:@"        </sequence>\n"];
            [xml appendString:@"      </project>\n"];
            [xml appendString:@"    </event>\n"];
            [xml appendString:@"  </library>\n"];
            [xml appendString:@"</fcpxml>"];

            NSString *xmlPath = [NSTemporaryDirectory()
                stringByAppendingPathComponent:@"fcpbridge_montage_auto.fcpxml"];
            NSData *data = [xml dataUsingEncoding:NSUTF8StringEncoding];
            [data writeToFile:xmlPath atomically:YES];
            NSURL *xmlURL = [NSURL fileURLWithPath:xmlPath];

            id app = ((id (*)(id, SEL))objc_msgSend)(
                objc_getClass("NSApplication"), @selector(sharedApplication));
            id delegate = ((id (*)(id, SEL))objc_msgSend)(app, @selector(delegate));

            SEL openSel = NSSelectorFromString(@"openXMLDocumentWithURL:bundleURL:display:sender:");
            if ([delegate respondsToSelector:openSel]) {
                ((void (*)(id, SEL, id, id, BOOL, id))objc_msgSend)(
                    delegate, openSel, xmlURL, nil, YES, nil);
                result = @{
                    @"status": @"ok",
                    @"projectName": projectName,
                    @"clipCount": @(spineClips.count),
                    @"totalDurationSeconds": @(montageDuration),
                    @"songRendered": @(songRendered),
                    @"style": style,
                    @"cutPoints": @(sortedCuts.count),
                    @"fcpxmlPath": xmlPath,
                    @"message": @"Auto montage created and imported"
                };
            } else {
                result = @{@"error": @"PEAppController does not respond to openXMLDocumentWithURL:"};
            }
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result ?: @{@"error": @"Failed to create auto montage"};
}

#pragma mark - Debug & Diagnostics

// All known TLK debug UserDefaults keys
static NSArray *FCPBridge_tlkDebugKeys(void) {
    return @[
        // Visual overlays
        @"TLKShowItemLaneIndex",
        @"TLKShowMisalignedEdges",
        @"TLKShowRenderBar",
        @"TLKShowHiddenGapItems",        // via showHiddenGapItems
        @"TLKShowHiddenItemHeaders",     // via showHiddenItemHeaders
        @"TLKShowInvalidLayoutRects",    // via showInvalidLayoutRects
        @"TLKShowContainerBounds",       // via showContainerBounds
        @"TLKShowContentLayers",         // via showContentLayers
        @"TLKShowRulerBounds",           // via showRulerBounds
        @"TLKShowUsedRegion",            // via showUsedRegion
        @"TLKShowZeroHeightSpineItems",  // via showZeroHeightSpineItems
        // Logging
        @"TLKLogVisibleLayerChanges",
        @"TLKLogParts",
        @"TLKLogReloadRequests",         // via logReloadRequests
        @"TLKLogRecyclingLayerChanges",  // via logRecyclingLayerChanges
        @"TLKLogVisibleRectChanges",     // via logVisibleRectChanges
        @"TLKLogSegmentationStatistics", // via logSegmentationStatistics
        // Performance / rendering
        @"TLKPerformanceMonitorEnabled",
        @"TLKDebugColorChangedObjects",  // via debugColorChangedObjects
        @"TLKDebugLayoutConstraints",    // via debugLayoutConstraints
        @"TLKDebugErrorsAndWarnings",    // via debugErrorsAndWarnings
        @"TLKDisableItemContents",
        @"TLKLoadDebugMicaAssets",       // via loadDebugMicaAssets
        @"TLKForceLayoutOnDrag",         // via forceLayoutOnDrag
        @"TLKOptimizedReload",
        @"TLKOptimizedZooming",
        @"TLKLegacyLayout",
        @"TLKColorizesLanes",            // via colorizesLanes
        @"TLKViewStateUsesLanePositions",
        @"TLKEnableUpdateFilmstripsForItemComponentFragments",
        @"TLKItemLayerContentsOperations",
        // Raw debug keys
        @"DebugKeyItemVideoFilmstripsDisabled",
        @"DebugKeyItemBackgroundDisabled",
        @"DebugKeyItemAudioWaveformsDisabled",
    ];
}

// All known CFPreferences debug keys (integer or bool)
static NSDictionary *FCPBridge_cfprefsDebugKeys(void) {
    return @{
        @"VideoDecoderLogLevelInNLE": @"int",
        @"FrameDropLogLevel": @"int",
        @"GPU_LOGGING": @"bool",
        @"EnableScheduledReadAudioLogging": @"bool",
        @"EnableLibraryUpdateHistoryValidation": @"bool",
        @"FFVAMLSaveTranscription": @"bool",
    };
}

// ProAppSupport log level names
static NSArray *FCPBridge_logLevelNames(void) {
    return @[@"trace", @"debug", @"info", @"warning", @"error", @"failure"];
}

// ProAppSupport log category names (matching PASLogCategory class methods)
static NSArray *FCPBridge_logCategoryNames(void) {
    return @[
        @"dev", @"player", @"sequenceEditor", @"camera", @"inspector",
        @"director", @"voiceover", @"selection", @"network", @"theme",
        @"share", @"analysisKit", @"backgroundTasks", @"angleEditor",
        @"lessons", @"onboarding", @"userNotifications", @"ui", @"all"
    ];
}

#pragma mark - Runtime Metadata Export (for IDA Pro)

// Helper: collect full metadata for a single class
// Helper: serialize a single method with dladdr info
static NSDictionary *FCPBridge_serializeMethod(Method m) {
    SEL sel = method_getName(m);
    const char *types = method_getTypeEncoding(m);
    IMP imp = method_getImplementation(m);

    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    info[@"selector"] = NSStringFromSelector(sel);
    info[@"typeEncoding"] = types ? @(types) : @"";
    info[@"imp"] = [NSString stringWithFormat:@"0x%lx", (unsigned long)imp];

    // dladdr: which image owns this IMP + nearest symbol name
    Dl_info dlinfo;
    if (dladdr((void *)imp, &dlinfo)) {
        if (dlinfo.dli_fname) info[@"image"] = [@(dlinfo.dli_fname) lastPathComponent];
        if (dlinfo.dli_sname) info[@"symbol"] = @(dlinfo.dli_sname);
        if (dlinfo.dli_saddr) info[@"symbolAddr"] = [NSString stringWithFormat:@"0x%lx",
                                                       (unsigned long)dlinfo.dli_saddr];
    }
    return info;
}

// Helper: serialize protocol method declarations
static NSDictionary *FCPBridge_serializeProtocol(Protocol *proto) {
    NSMutableDictionary *protoInfo = [NSMutableDictionary dictionary];
    protoInfo[@"name"] = @(protocol_getName(proto));

    // 4 variants: required/optional x instance/class
    NSString *keys[4] = {@"requiredInstanceMethods", @"requiredClassMethods",
                         @"optionalInstanceMethods", @"optionalClassMethods"};
    BOOL reqVals[4]  = {YES, YES, NO, NO};
    BOOL instVals[4] = {YES, NO, YES, NO};

    for (int v = 0; v < 4; v++) {
        unsigned int mCount = 0;
        struct objc_method_description *descs =
            protocol_copyMethodDescriptionList(proto, reqVals[v], instVals[v], &mCount);
        NSMutableArray *methods = [NSMutableArray arrayWithCapacity:mCount];
        if (descs) {
            for (unsigned int m = 0; m < mCount; m++) {
                [methods addObject:@{
                    @"selector": NSStringFromSelector(descs[m].name),
                    @"typeEncoding": descs[m].types ? @(descs[m].types) : @""
                }];
            }
            free(descs);
        }
        protoInfo[keys[v]] = methods;
    }

    // Protocol inheritance
    unsigned int parentCount = 0;
    Protocol * __unsafe_unretained *parents = protocol_copyProtocolList(proto, &parentCount);
    NSMutableArray *parentNames = [NSMutableArray arrayWithCapacity:parentCount];
    if (parents) {
        for (unsigned int p = 0; p < parentCount; p++) {
            [parentNames addObject:@(protocol_getName(parents[p]))];
        }
        free(parents);
    }
    protoInfo[@"inheritsFrom"] = parentNames;

    // Protocol properties
    unsigned int ppCount = 0;
    objc_property_t *ppList = protocol_copyPropertyList(proto, &ppCount);
    NSMutableArray *protoProps = [NSMutableArray arrayWithCapacity:ppCount];
    if (ppList) {
        for (unsigned int p = 0; p < ppCount; p++) {
            const char *name = property_getName(ppList[p]);
            const char *attrs = property_getAttributes(ppList[p]);
            [protoProps addObject:@{
                @"name": @(name),
                @"attributes": attrs ? @(attrs) : @""
            }];
        }
        free(ppList);
    }
    protoInfo[@"properties"] = protoProps;

    return protoInfo;
}

// Helper: parse ivar layout bitmap into array of strong/weak byte indices
static NSArray *FCPBridge_parseIvarLayout(const uint8_t *layout) {
    if (!layout) return @[];
    NSMutableArray *indices = [NSMutableArray array];
    NSUInteger byteIndex = 0;
    while (*layout != 0) {
        uint8_t skip = (*layout >> 4) & 0x0F;
        uint8_t scan = *layout & 0x0F;
        byteIndex += skip;
        for (uint8_t s = 0; s < scan; s++) {
            [indices addObject:@(byteIndex)];
            byteIndex++;
        }
        layout++;
    }
    return indices;
}

static NSDictionary *FCPBridge_classMetadata(Class cls) {
    NSString *className = NSStringFromClass(cls);

    // Instance methods with dladdr
    NSMutableArray *instanceMethods = [NSMutableArray array];
    unsigned int mCount = 0;
    Method *mList = class_copyMethodList(cls, &mCount);
    if (mList) {
        for (unsigned int i = 0; i < mCount; i++) {
            [instanceMethods addObject:FCPBridge_serializeMethod(mList[i])];
        }
        free(mList);
    }

    // Class methods with dladdr
    NSMutableArray *classMethods = [NSMutableArray array];
    Class metaCls = object_getClass(cls);
    if (metaCls) {
        unsigned int cmCount = 0;
        Method *cmList = class_copyMethodList(metaCls, &cmCount);
        if (cmList) {
            for (unsigned int i = 0; i < cmCount; i++) {
                [classMethods addObject:FCPBridge_serializeMethod(cmList[i])];
            }
            free(cmList);
        }
    }

    // Ivars with offsets
    NSMutableArray *ivars = [NSMutableArray array];
    unsigned int iCount = 0;
    Ivar *iList = class_copyIvarList(cls, &iCount);
    if (iList) {
        for (unsigned int i = 0; i < iCount; i++) {
            const char *name = ivar_getName(iList[i]);
            const char *type = ivar_getTypeEncoding(iList[i]);
            ptrdiff_t offset = ivar_getOffset(iList[i]);
            [ivars addObject:@{
                @"name": name ? @(name) : @"<anon>",
                @"type": type ? @(type) : @"?",
                @"offset": @(offset)
            }];
        }
        free(iList);
    }

    // Ivar layout bitmaps (strong/weak reference tracking)
    const uint8_t *strongLayout = class_getIvarLayout(cls);
    const uint8_t *weakLayout = class_getWeakIvarLayout(cls);
    NSArray *strongIndices = FCPBridge_parseIvarLayout(strongLayout);
    NSArray *weakIndices = FCPBridge_parseIvarLayout(weakLayout);

    // Properties with parsed attributes
    NSMutableArray *properties = [NSMutableArray array];
    unsigned int pCount = 0;
    objc_property_t *pList = class_copyPropertyList(cls, &pCount);
    if (pList) {
        for (unsigned int i = 0; i < pCount; i++) {
            const char *name = property_getName(pList[i]);
            const char *rawAttrs = property_getAttributes(pList[i]);

            NSMutableDictionary *propInfo = [NSMutableDictionary dictionary];
            propInfo[@"name"] = @(name);
            propInfo[@"rawAttributes"] = rawAttrs ? @(rawAttrs) : @"";

            // Parse structured attributes
            unsigned int attrCount = 0;
            objc_property_attribute_t *attrList = property_copyAttributeList(pList[i], &attrCount);
            if (attrList) {
                for (unsigned int a = 0; a < attrCount; a++) {
                    NSString *attrName;
                    char code = attrList[a].name[0];
                    switch (code) {
                        case 'T': attrName = @"type"; break;
                        case 'V': attrName = @"backingIvar"; break;
                        case 'S': attrName = @"setter"; break;
                        case 'G': attrName = @"getter"; break;
                        case 'R': attrName = @"readonly"; break;
                        case 'C': attrName = @"copy"; break;
                        case '&': attrName = @"strong"; break;
                        case 'N': attrName = @"nonatomic"; break;
                        case 'W': attrName = @"weak"; break;
                        case 'D': attrName = @"dynamic"; break;
                        default:  attrName = @(attrList[a].name); break;
                    }
                    propInfo[attrName] = (attrList[a].value && attrList[a].value[0])
                        ? @(attrList[a].value) : @YES;
                }
                free(attrList);
            }
            [properties addObject:propInfo];
        }
        free(pList);
    }

    // Protocols with full method declarations
    NSMutableArray *protocols = [NSMutableArray array];
    unsigned int prCount = 0;
    Protocol * __unsafe_unretained *prList = class_copyProtocolList(cls, &prCount);
    if (prList) {
        for (unsigned int i = 0; i < prCount; i++) {
            [protocols addObject:FCPBridge_serializeProtocol(prList[i])];
        }
        free(prList);
    }

    // Superchain
    NSMutableArray *superchain = [NSMutableArray array];
    Class current = class_getSuperclass(cls);
    while (current) {
        [superchain addObject:NSStringFromClass(current)];
        current = class_getSuperclass(current);
    }

    // Instance size
    size_t instanceSize = class_getInstanceSize(cls);

    return @{
        @"name": className,
        @"instanceSize": @(instanceSize),
        @"superchain": superchain,
        @"protocols": protocols,
        @"instanceMethods": instanceMethods,
        @"classMethods": classMethods,
        @"ivars": ivars,
        @"ivarLayout": @{@"strong": strongIndices, @"weak": weakIndices},
        @"properties": properties
    };
}

static NSDictionary *FCPBridge_handleDumpRuntimeMetadata(NSDictionary *params) {
    NSString *binaryFilter = params[@"binary"]; // optional: filter to one binary
    NSArray *includeFields = params[@"include"]; // optional: subset of fields
    BOOL classesOnly = [params[@"classesOnly"] boolValue]; // just class names, no details

    NSMutableArray *images = [NSMutableArray array];
    NSMutableDictionary *classesByImage = [NSMutableDictionary dictionary];

    uint32_t imageCount = _dyld_image_count();
    for (uint32_t i = 0; i < imageCount; i++) {
        const char *imageName = _dyld_get_image_name(i);
        if (!imageName) continue;

        NSString *imagePath = @(imageName);
        NSString *shortName = [imagePath lastPathComponent];

        // If binary filter specified, skip non-matching images
        if (binaryFilter && ![shortName localizedCaseInsensitiveContainsString:binaryFilter]
            && ![imagePath localizedCaseInsensitiveContainsString:binaryFilter]) {
            continue;
        }

        intptr_t slide = _dyld_get_image_vmaddr_slide(i);
        const struct mach_header *header = _dyld_get_image_header(i);
        uintptr_t baseAddr = (uintptr_t)header;

        NSDictionary *imageInfo = @{
            @"path": imagePath,
            @"name": shortName,
            @"index": @(i),
            @"baseAddress": [NSString stringWithFormat:@"0x%lx", (unsigned long)baseAddr],
            @"slide": [NSString stringWithFormat:@"0x%lx", (unsigned long)slide]
        };

        // Get classes for this image
        unsigned int classCount = 0;
        const char **classNames = objc_copyClassNamesForImage(imageName, &classCount);
        if (classCount == 0) {
            if (classNames) free(classNames);
            continue; // skip images with no ObjC classes
        }

        NSMutableArray *classData = [NSMutableArray array];
        if (classesOnly) {
            // Fast path: just class names
            for (unsigned int j = 0; j < classCount; j++) {
                [classData addObject:@(classNames[j])];
            }
        } else {
            // Full metadata for each class
            for (unsigned int j = 0; j < classCount; j++) {
                @try {
                    Class cls = objc_getClass(classNames[j]);
                    if (!cls) continue;
                    NSDictionary *meta = FCPBridge_classMetadata(cls);
                    [classData addObject:meta];
                } @catch (NSException *e) {
                    // Skip problematic classes
                    [classData addObject:@{@"name": @(classNames[j]), @"error": e.reason ?: @"unknown"}];
                }
            }
        }
        free(classNames);

        NSMutableDictionary *entry = [imageInfo mutableCopy];
        entry[@"classCount"] = @(classCount);
        [images addObject:entry];
        classesByImage[shortName] = classData;
    }

    NSUInteger totalClasses = 0;
    for (NSArray *arr in [classesByImage allValues]) {
        totalClasses += arr.count;
    }

    return @{
        @"images": images,
        @"classes": classesByImage,
        @"imageCount": @(images.count),
        @"totalClasses": @(totalClasses)
    };
}

// Lightweight: just list loaded images with addresses/slides (no class enumeration)
static NSDictionary *FCPBridge_handleListLoadedImages(NSDictionary *params) {
    NSString *filter = params[@"filter"];
    NSMutableArray *images = [NSMutableArray array];

    uint32_t imageCount = _dyld_image_count();
    for (uint32_t i = 0; i < imageCount; i++) {
        const char *imageName = _dyld_get_image_name(i);
        if (!imageName) continue;

        NSString *imagePath = @(imageName);
        NSString *shortName = [imagePath lastPathComponent];

        if (filter && ![shortName localizedCaseInsensitiveContainsString:filter]
            && ![imagePath localizedCaseInsensitiveContainsString:filter]) {
            continue;
        }

        intptr_t slide = _dyld_get_image_vmaddr_slide(i);
        const struct mach_header *header = _dyld_get_image_header(i);
        uintptr_t baseAddr = (uintptr_t)header;

        // Count classes for this image
        unsigned int classCount = 0;
        const char **classNames = objc_copyClassNamesForImage(imageName, &classCount);
        if (classNames) free(classNames);

        [images addObject:@{
            @"path": imagePath,
            @"name": shortName,
            @"index": @(i),
            @"baseAddress": [NSString stringWithFormat:@"0x%lx", (unsigned long)baseAddr],
            @"slide": [NSString stringWithFormat:@"0x%lx", (unsigned long)slide],
            @"classCount": @(classCount)
        }];
    }

    return @{@"images": images, @"count": @(images.count)};
}

#pragma mark - Mach-O Section & Symbol Table Export

// Enumerate ObjC selector references, class references, and categories for an image
static NSDictionary *FCPBridge_handleGetImageSections(NSDictionary *params) {
    NSString *binaryName = params[@"binary"];
    if (!binaryName) return @{@"error": @"binary parameter required"};

    // Find the image
    uint32_t imageCount = _dyld_image_count();
    const struct mach_header_64 *foundHeader = NULL;
    intptr_t foundSlide = 0;
    NSString *foundPath = nil;

    for (uint32_t i = 0; i < imageCount; i++) {
        const char *imageName = _dyld_get_image_name(i);
        if (!imageName) continue;
        NSString *path = @(imageName);
        NSString *shortName = [path lastPathComponent];
        if ([shortName localizedCaseInsensitiveContainsString:binaryName]
            || [path localizedCaseInsensitiveContainsString:binaryName]) {
            foundHeader = (const struct mach_header_64 *)_dyld_get_image_header(i);
            foundSlide = _dyld_get_image_vmaddr_slide(i);
            foundPath = path;
            break;
        }
    }
    if (!foundHeader) return @{@"error": [NSString stringWithFormat:@"Image not found: %@", binaryName]};

    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    result[@"binary"] = [foundPath lastPathComponent];
    result[@"path"] = foundPath;
    result[@"slide"] = [NSString stringWithFormat:@"0x%lx", (unsigned long)foundSlide];

    // __objc_selrefs: all selector references used by this image
    unsigned long selrefsSize = 0;
    SEL *selrefs = (SEL *)getsectiondata(foundHeader, "__DATA_CONST", "__objc_selrefs", &selrefsSize);
    if (!selrefs) {
        selrefs = (SEL *)getsectiondata(foundHeader, "__DATA", "__objc_selrefs", &selrefsSize);
    }
    NSMutableArray *selectorRefs = [NSMutableArray array];
    if (selrefs) {
        unsigned long selCount = selrefsSize / sizeof(SEL);
        for (unsigned long j = 0; j < selCount; j++) {
            @try {
                NSString *selName = NSStringFromSelector(selrefs[j]);
                if (selName) [selectorRefs addObject:selName];
            } @catch (NSException *e) { /* skip */ }
        }
    }
    result[@"selectorRefs"] = selectorRefs;
    result[@"selectorRefCount"] = @(selectorRefs.count);

    // __objc_classrefs: class references used by this image
    unsigned long classrefsSize = 0;
    void *classrefsRaw = (void *)getsectiondata(foundHeader, "__DATA_CONST", "__objc_classrefs", &classrefsSize);
    if (!classrefsRaw) {
        classrefsRaw = (void *)getsectiondata(foundHeader, "__DATA", "__objc_classrefs", &classrefsSize);
    }
    NSMutableArray *classRefNames = [NSMutableArray array];
    if (classrefsRaw) {
        void **classrefs = (void **)classrefsRaw;
        unsigned long crCount = classrefsSize / sizeof(void *);
        for (unsigned long j = 0; j < crCount; j++) {
            @try {
                if (classrefs[j]) {
                    const char *name = class_getName((__bridge Class)classrefs[j]);
                    if (name) [classRefNames addObject:@(name)];
                }
            } @catch (NSException *e) { /* skip */ }
        }
    }
    result[@"classRefs"] = classRefNames;
    result[@"classRefCount"] = @(classRefNames.count);

    // __objc_superrefs: superclass references
    unsigned long superrefsSize = 0;
    void *superrefsRaw = (void *)getsectiondata(foundHeader, "__DATA_CONST", "__objc_superrefs", &superrefsSize);
    if (!superrefsRaw) {
        superrefsRaw = (void *)getsectiondata(foundHeader, "__DATA", "__objc_superrefs", &superrefsSize);
    }
    NSMutableArray *superRefNames = [NSMutableArray array];
    if (superrefsRaw) {
        void **superrefs = (void **)superrefsRaw;
        unsigned long srCount = superrefsSize / sizeof(void *);
        for (unsigned long j = 0; j < srCount; j++) {
            @try {
                if (superrefs[j]) {
                    const char *name = class_getName((__bridge Class)superrefs[j]);
                    if (name) [superRefNames addObject:@(name)];
                }
            } @catch (NSException *e) { /* skip */ }
        }
    }
    result[@"superclassRefs"] = superRefNames;

    return result;
}

// Enumerate exported symbols from an image's symbol table
static NSDictionary *FCPBridge_handleGetImageSymbols(NSDictionary *params) {
    NSString *binaryName = params[@"binary"];
    if (!binaryName) return @{@"error": @"binary parameter required"};
    NSString *filter = params[@"filter"]; // optional name filter
    BOOL demangleSwift = ![params[@"demangle"] isEqual:@NO]; // default YES

    // Find the image
    uint32_t imageCount = _dyld_image_count();
    const struct mach_header_64 *foundHeader = NULL;
    intptr_t foundSlide = 0;
    NSString *foundPath = nil;

    for (uint32_t i = 0; i < imageCount; i++) {
        const char *imageName = _dyld_get_image_name(i);
        if (!imageName) continue;
        NSString *path = @(imageName);
        NSString *shortName = [path lastPathComponent];
        if ([shortName localizedCaseInsensitiveContainsString:binaryName]
            || [path localizedCaseInsensitiveContainsString:binaryName]) {
            foundHeader = (const struct mach_header_64 *)_dyld_get_image_header(i);
            foundSlide = _dyld_get_image_vmaddr_slide(i);
            foundPath = path;
            break;
        }
    }
    if (!foundHeader) return @{@"error": [NSString stringWithFormat:@"Image not found: %@", binaryName]};

    // Get swift_demangle if available
    typedef char *(*swift_demangle_func)(const char *, size_t, char *, size_t *, uint32_t);
    swift_demangle_func swift_demangle = NULL;
    if (demangleSwift) {
        swift_demangle = (swift_demangle_func)dlsym(RTLD_DEFAULT, "swift_demangle");
    }

    // Walk load commands to find LC_SYMTAB
    NSMutableArray *symbols = [NSMutableArray array];
    NSUInteger exportedCount = 0;
    NSUInteger swiftCount = 0;

    const struct load_command *cmd = (const struct load_command *)((uintptr_t)foundHeader + sizeof(struct mach_header_64));
    for (uint32_t c = 0; c < foundHeader->ncmds; c++) {
        if (cmd->cmd == LC_SYMTAB) {
            const struct symtab_command *symtab = (const struct symtab_command *)cmd;
            const struct nlist_64 *nlistArr = (const struct nlist_64 *)((uintptr_t)foundHeader + symtab->symoff);
            const char *strings = (const char *)((uintptr_t)foundHeader + symtab->stroff);

            for (uint32_t s = 0; s < symtab->nsyms; s++) {
                uint8_t ntype = nlistArr[s].n_type;
                // Only exported defined symbols
                if (!((ntype & N_EXT) && (ntype & N_TYPE) == N_SECT)) continue;

                const char *symName = strings + nlistArr[s].n_un.n_strx;
                if (!symName || !symName[0]) continue;

                // Apply name filter
                if (filter) {
                    NSString *nameStr = @(symName);
                    if (![nameStr localizedCaseInsensitiveContainsString:filter]) continue;
                }

                uint64_t addr = nlistArr[s].n_value + foundSlide;
                uint8_t sect = nlistArr[s].n_sect;

                NSMutableDictionary *symInfo = [NSMutableDictionary dictionary];
                symInfo[@"name"] = @(symName);
                symInfo[@"address"] = [NSString stringWithFormat:@"0x%llx", (unsigned long long)addr];
                symInfo[@"section"] = @(sect);

                // Swift demangling
                if (swift_demangle && (symName[0] == '$' || (symName[0] == '_' && symName[1] == '$'))) {
                    const char *toMangle = (symName[0] == '_') ? symName + 1 : symName;
                    char *demangled = swift_demangle(toMangle, 0, NULL, NULL, 0);
                    if (demangled) {
                        symInfo[@"demangled"] = @(demangled);
                        free(demangled);
                        swiftCount++;
                    }
                }

                [symbols addObject:symInfo];
                exportedCount++;
            }
            break;
        }
        cmd = (const struct load_command *)((uintptr_t)cmd + cmd->cmdsize);
    }

    return @{
        @"binary": [foundPath lastPathComponent],
        @"path": foundPath,
        @"slide": [NSString stringWithFormat:@"0x%lx", (unsigned long)foundSlide],
        @"symbols": symbols,
        @"exportedCount": @(exportedCount),
        @"swiftDemangledCount": @(swiftCount)
    };
}

// Enumerate notification name constants from exported symbols
static NSDictionary *FCPBridge_handleGetNotificationNames(NSDictionary *params) {
    NSString *binaryFilter = params[@"binary"]; // optional
    NSMutableArray *notifications = [NSMutableArray array];

    uint32_t imageCount = _dyld_image_count();
    for (uint32_t i = 0; i < imageCount; i++) {
        const char *imageName = _dyld_get_image_name(i);
        if (!imageName) continue;
        NSString *path = @(imageName);
        NSString *shortName = [path lastPathComponent];

        if (binaryFilter && ![shortName localizedCaseInsensitiveContainsString:binaryFilter]
            && ![path localizedCaseInsensitiveContainsString:binaryFilter]) {
            continue;
        }

        const struct mach_header_64 *header = (const struct mach_header_64 *)_dyld_get_image_header(i);
        intptr_t slide = _dyld_get_image_vmaddr_slide(i);

        // Walk symbol table looking for *Notification* symbols
        const struct load_command *cmd = (const struct load_command *)((uintptr_t)header + sizeof(struct mach_header_64));
        for (uint32_t c = 0; c < header->ncmds; c++) {
            if (cmd->cmd == LC_SYMTAB) {
                const struct symtab_command *symtab = (const struct symtab_command *)cmd;
                const struct nlist_64 *nlistArr = (const struct nlist_64 *)((uintptr_t)header + symtab->symoff);
                const char *strings = (const char *)((uintptr_t)header + symtab->stroff);

                for (uint32_t s = 0; s < symtab->nsyms; s++) {
                    uint8_t ntype = nlistArr[s].n_type;
                    if (!((ntype & N_EXT) && (ntype & N_TYPE) == N_SECT)) continue;

                    const char *symName = strings + nlistArr[s].n_un.n_strx;
                    if (!symName) continue;

                    // Look for Notification-related symbols
                    if (!strstr(symName, "Notification") && !strstr(symName, "notification")) continue;

                    uint64_t addr = nlistArr[s].n_value + slide;

                    // Try to resolve the string value
                    NSString *value = nil;
                    @try {
                        // Skip leading underscore for dlsym
                        const char *lookupName = (symName[0] == '_') ? symName + 1 : symName;
                        void *sym = dlsym(RTLD_DEFAULT, lookupName);
                        if (sym) {
                            id obj = *(__unsafe_unretained id *)sym;
                            if ([obj isKindOfClass:[NSString class]]) {
                                value = (NSString *)obj;
                            }
                        }
                    } @catch (NSException *e) { /* skip */ }

                    NSMutableDictionary *notif = [NSMutableDictionary dictionary];
                    notif[@"symbol"] = @(symName);
                    notif[@"address"] = [NSString stringWithFormat:@"0x%llx", (unsigned long long)addr];
                    notif[@"image"] = shortName;
                    if (value) notif[@"value"] = value;

                    [notifications addObject:notif];
                }
                break;
            }
            cmd = (const struct load_command *)((uintptr_t)cmd + cmd->cmdsize);
        }
    }

    return @{@"notifications": notifications, @"count": @(notifications.count)};
}

static NSDictionary *FCPBridge_handleDebugGetConfig(NSDictionary *params) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

    // 1) TLK debug flags
    NSMutableDictionary *tlkFlags = [NSMutableDictionary dictionary];
    for (NSString *key in FCPBridge_tlkDebugKeys()) {
        tlkFlags[key] = @([defaults boolForKey:key]);
    }

    // 2) CFPreferences debug flags
    NSMutableDictionary *cfFlags = [NSMutableDictionary dictionary];
    NSDictionary *cfKeys = FCPBridge_cfprefsDebugKeys();
    for (NSString *key in cfKeys) {
        Boolean exists = false;
        if ([cfKeys[key] isEqualToString:@"int"]) {
            CFIndex val = CFPreferencesGetAppIntegerValue(
                (__bridge CFStringRef)key, kCFPreferencesCurrentApplication, &exists);
            cfFlags[key] = exists ? @(val) : @"<not set>";
        } else {
            Boolean val = CFPreferencesGetAppBooleanValue(
                (__bridge CFStringRef)key, kCFPreferencesCurrentApplication, &exists);
            cfFlags[key] = exists ? @(val) : @"<not set>";
        }
    }

    // 3) ProAppSupport log settings (via UserDefaults keys LogLevel, LogUI, LogThread, LogCategory)
    NSMutableDictionary *logSettings = [NSMutableDictionary dictionary];
    id logLevelVal = [defaults objectForKey:@"LogLevel"];
    if (logLevelVal) {
        NSInteger level = [logLevelVal integerValue];
        NSArray *names = FCPBridge_logLevelNames();
        logSettings[@"LogLevel"] = (level >= 0 && level < (NSInteger)names.count)
            ? names[level] : [NSString stringWithFormat:@"%ld", (long)level];
    } else {
        logSettings[@"LogLevel"] = @"<not set>";
    }
    logSettings[@"LogUI"] = [defaults objectForKey:@"LogUI"] ? @([defaults boolForKey:@"LogUI"]) : @"<not set>";
    logSettings[@"LogThread"] = [defaults objectForKey:@"LogThread"] ? @([defaults boolForKey:@"LogThread"]) : @"<not set>";
    id logCatVal = [defaults objectForKey:@"LogCategory"];
    if (logCatVal) {
        logSettings[@"LogCategory"] = logCatVal;
    } else {
        logSettings[@"LogCategory"] = @"<not set>";
    }

    // 4) Additional FCP defaults
    NSMutableDictionary *fcpFlags = [NSMutableDictionary dictionary];
    NSArray *fcpKeys = @[@"FFDontCoalesceGaps", @"FFDisableSnapping", @"FFDisableSkimming"];
    for (NSString *key in fcpKeys) {
        id val = [defaults objectForKey:key];
        fcpFlags[key] = val ? @([defaults boolForKey:key]) : @"<not set>";
    }

    return @{
        @"timeline_debug": tlkFlags,
        @"cfpreferences_debug": cfFlags,
        @"proapp_log": logSettings,
        @"fcp_flags": fcpFlags,
        @"available_log_levels": FCPBridge_logLevelNames(),
        @"available_log_categories": FCPBridge_logCategoryNames(),
    };
}

static NSDictionary *FCPBridge_handleDebugSetConfig(NSDictionary *params) {
    NSString *key = params[@"key"];
    id value = params[@"value"];

    if (!key) {
        return @{@"error": @"'key' parameter required"};
    }

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

    // Check if it's a TLK key
    NSArray *tlkKeys = FCPBridge_tlkDebugKeys();
    if ([tlkKeys containsObject:key]) {
        BOOL boolVal = [value boolValue];
        [defaults setBool:boolVal forKey:key];
        [defaults synchronize];

        // Reload TLK settings live
        Class tlkClass = NSClassFromString(@"TLKUserDefaults");
        if (tlkClass && [tlkClass respondsToSelector:NSSelectorFromString(@"_loadUserDefaults")]) {
            ((void (*)(id, SEL))objc_msgSend)(tlkClass, NSSelectorFromString(@"_loadUserDefaults"));
        }

        return @{@"status": @"ok", @"key": key, @"value": @(boolVal), @"type": @"tlk_debug",
                 @"note": @"TLKUserDefaults reloaded"};
    }

    // Check if it's a CFPreferences key
    NSDictionary *cfKeys = FCPBridge_cfprefsDebugKeys();
    if (cfKeys[key]) {
        if ([cfKeys[key] isEqualToString:@"int"]) {
            CFPreferencesSetAppValue(
                (__bridge CFStringRef)key,
                (__bridge CFPropertyListRef)@([value integerValue]),
                kCFPreferencesCurrentApplication);
        } else {
            CFPreferencesSetAppValue(
                (__bridge CFStringRef)key,
                (__bridge CFPropertyListRef)@([value boolValue]),
                kCFPreferencesCurrentApplication);
        }
        CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication);
        return @{@"status": @"ok", @"key": key, @"value": value, @"type": @"cfpreferences",
                 @"note": @"CFPreferences set (may need restart for some flags)"};
    }

    // Check if it's a ProAppSupport log key
    if ([key isEqualToString:@"LogLevel"]) {
        NSArray *names = FCPBridge_logLevelNames();
        NSInteger level = -1;
        if ([value isKindOfClass:[NSString class]]) {
            level = [names indexOfObject:[value lowercaseString]];
            if (level == NSNotFound) level = -1;
        } else {
            level = [value integerValue];
        }
        if (level < 0 || level >= (NSInteger)names.count) {
            return @{@"error": [NSString stringWithFormat:@"Invalid log level. Use one of: %@",
                                [names componentsJoinedByString:@", "]]};
        }
        [defaults setInteger:level forKey:@"LogLevel"];
        [defaults synchronize];
        return @{@"status": @"ok", @"key": @"LogLevel", @"value": names[level],
                 @"rawValue": @(level), @"type": @"proapp_log"};
    }

    if ([key isEqualToString:@"LogUI"]) {
        BOOL boolVal = [value boolValue];
        [defaults setBool:boolVal forKey:@"LogUI"];
        [defaults synchronize];
        return @{@"status": @"ok", @"key": @"LogUI", @"value": @(boolVal), @"type": @"proapp_log"};
    }

    if ([key isEqualToString:@"LogThread"]) {
        BOOL boolVal = [value boolValue];
        [defaults setBool:boolVal forKey:@"LogThread"];
        [defaults synchronize];
        return @{@"status": @"ok", @"key": @"LogThread", @"value": @(boolVal), @"type": @"proapp_log"};
    }

    if ([key isEqualToString:@"LogCategory"]) {
        [defaults setObject:value forKey:@"LogCategory"];
        [defaults synchronize];
        return @{@"status": @"ok", @"key": @"LogCategory", @"value": value, @"type": @"proapp_log"};
    }

    // FCP flags
    NSArray *fcpKeys = @[@"FFDontCoalesceGaps", @"FFDisableSnapping", @"FFDisableSkimming"];
    if ([fcpKeys containsObject:key]) {
        BOOL boolVal = [value boolValue];
        [defaults setBool:boolVal forKey:key];
        [defaults synchronize];
        return @{@"status": @"ok", @"key": key, @"value": @(boolVal), @"type": @"fcp_flag"};
    }

    // Allow setting arbitrary keys as a fallback
    if ([value isKindOfClass:[NSNumber class]]) {
        [defaults setObject:value forKey:key];
    } else {
        [defaults setBool:[value boolValue] forKey:key];
    }
    [defaults synchronize];
    return @{@"status": @"ok", @"key": key, @"value": value, @"type": @"custom",
             @"note": @"Set as custom UserDefaults key"};
}

static NSDictionary *FCPBridge_handleDebugResetConfig(NSDictionary *params) {
    NSString *scope = params[@"scope"] ?: @"all";
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSMutableArray *removedKeys = [NSMutableArray array];

    if ([scope isEqualToString:@"tlk"] || [scope isEqualToString:@"all"]) {
        for (NSString *key in FCPBridge_tlkDebugKeys()) {
            [defaults removeObjectForKey:key];
            [removedKeys addObject:key];
        }
        // Reload TLK
        Class tlkClass = NSClassFromString(@"TLKUserDefaults");
        if (tlkClass && [tlkClass respondsToSelector:NSSelectorFromString(@"_loadUserDefaults")]) {
            ((void (*)(id, SEL))objc_msgSend)(tlkClass, NSSelectorFromString(@"_loadUserDefaults"));
        }
    }

    if ([scope isEqualToString:@"cfprefs"] || [scope isEqualToString:@"all"]) {
        for (NSString *key in FCPBridge_cfprefsDebugKeys()) {
            CFPreferencesSetAppValue((__bridge CFStringRef)key, NULL, kCFPreferencesCurrentApplication);
            [removedKeys addObject:key];
        }
        CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication);
    }

    if ([scope isEqualToString:@"log"] || [scope isEqualToString:@"all"]) {
        for (NSString *key in @[@"LogLevel", @"LogUI", @"LogThread", @"LogCategory"]) {
            [defaults removeObjectForKey:key];
            [removedKeys addObject:key];
        }
    }

    [defaults synchronize];
    return @{@"status": @"ok", @"scope": scope, @"removedKeys": removedKeys,
             @"count": @(removedKeys.count)};
}

// Framerate monitor state
static id sFramerateMonitor = nil;

static NSDictionary *FCPBridge_handleDebugStartFramerateMonitor(NSDictionary *params) {
    __block NSDictionary *result = nil;
    float interval = [params[@"interval"] floatValue];
    if (interval <= 0) interval = 2.0;

    dispatch_sync(dispatch_get_main_queue(), ^{
        Class hmdClass = NSClassFromString(@"HMDFramerate");
        if (!hmdClass) {
            result = @{@"error": @"HMDFramerate class not found"};
            return;
        }

        if (sFramerateMonitor) {
            // Stop existing monitor first
            if ([sFramerateMonitor respondsToSelector:NSSelectorFromString(@"stopLogging")]) {
                ((void (*)(id, SEL))objc_msgSend)(sFramerateMonitor, NSSelectorFromString(@"stopLogging"));
            }
            sFramerateMonitor = nil;
        }

        sFramerateMonitor = [[hmdClass alloc] init];
        if (!sFramerateMonitor) {
            result = @{@"error": @"Failed to create HMDFramerate instance"};
            return;
        }

        SEL startSel = NSSelectorFromString(@"startLogging:");
        if ([sFramerateMonitor respondsToSelector:startSel]) {
            ((void (*)(id, SEL, float))objc_msgSend)(sFramerateMonitor, startSel, interval);
            result = @{@"status": @"ok", @"interval": @(interval),
                       @"message": [NSString stringWithFormat:
                                    @"Framerate monitor started (%.1fs interval). Output goes to Console.app / system log.",
                                    interval]};
        } else {
            result = @{@"error": @"HMDFramerate does not respond to startLogging:"};
            sFramerateMonitor = nil;
        }
    });
    return result ?: @{@"error": @"Failed to start framerate monitor"};
}

static NSDictionary *FCPBridge_handleDebugStopFramerateMonitor(NSDictionary *params) {
    __block NSDictionary *result = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{
        if (!sFramerateMonitor) {
            result = @{@"status": @"ok", @"message": @"No framerate monitor running"};
            return;
        }
        if ([sFramerateMonitor respondsToSelector:NSSelectorFromString(@"stopLogging")]) {
            ((void (*)(id, SEL))objc_msgSend)(sFramerateMonitor, NSSelectorFromString(@"stopLogging"));
        }
        sFramerateMonitor = nil;
        result = @{@"status": @"ok", @"message": @"Framerate monitor stopped"};
    });
    return result;
}

static NSDictionary *FCPBridge_handleDebugEnablePreset(NSDictionary *params) {
    NSString *preset = params[@"preset"];
    if (!preset) {
        return @{@"error": @"'preset' parameter required",
                 @"available": @[@"timeline_visual", @"timeline_logging",
                                 @"performance", @"render_debug", @"verbose_logging", @"all_off"]};
    }

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSMutableArray *changed = [NSMutableArray array];

    void (^setKey)(NSString *, BOOL) = ^(NSString *key, BOOL val) {
        [defaults setBool:val forKey:key];
        [changed addObject:@{@"key": key, @"value": @(val)}];
    };

    if ([preset isEqualToString:@"timeline_visual"]) {
        setKey(@"TLKShowItemLaneIndex", YES);
        setKey(@"TLKShowMisalignedEdges", YES);
        setKey(@"TLKShowRenderBar", YES);
        setKey(@"TLKShowHiddenGapItems", YES);
        setKey(@"TLKShowInvalidLayoutRects", YES);
        setKey(@"TLKDebugColorChangedObjects", YES);
    } else if ([preset isEqualToString:@"timeline_logging"]) {
        setKey(@"TLKLogVisibleLayerChanges", YES);
        setKey(@"TLKLogParts", YES);
        setKey(@"TLKLogReloadRequests", YES);
        setKey(@"TLKLogRecyclingLayerChanges", YES);
        setKey(@"TLKLogVisibleRectChanges", YES);
        setKey(@"TLKLogSegmentationStatistics", YES);
    } else if ([preset isEqualToString:@"performance"]) {
        setKey(@"TLKPerformanceMonitorEnabled", YES);
        [defaults setInteger:2 forKey:@"VideoDecoderLogLevelInNLE"];
        [changed addObject:@{@"key": @"VideoDecoderLogLevelInNLE", @"value": @2}];
        [defaults setInteger:2 forKey:@"FrameDropLogLevel"];
        [changed addObject:@{@"key": @"FrameDropLogLevel", @"value": @2}];
    } else if ([preset isEqualToString:@"render_debug"]) {
        setKey(@"DebugKeyItemVideoFilmstripsDisabled", YES);
        setKey(@"DebugKeyItemBackgroundDisabled", YES);
        setKey(@"DebugKeyItemAudioWaveformsDisabled", YES);
        setKey(@"TLKDisableItemContents", YES);
        setKey(@"GPU_LOGGING", YES);
    } else if ([preset isEqualToString:@"verbose_logging"]) {
        [defaults setInteger:0 forKey:@"LogLevel"]; // trace
        [changed addObject:@{@"key": @"LogLevel", @"value": @"trace"}];
        setKey(@"LogUI", YES);
        setKey(@"LogThread", YES);
        setKey(@"EnableScheduledReadAudioLogging", YES);
    } else if ([preset isEqualToString:@"all_off"]) {
        // Turn off all TLK visual/logging flags
        for (NSString *key in FCPBridge_tlkDebugKeys()) {
            [defaults removeObjectForKey:key];
            [changed addObject:@{@"key": key, @"value": @"removed"}];
        }
        // Reset CFPreferences
        for (NSString *key in FCPBridge_cfprefsDebugKeys()) {
            CFPreferencesSetAppValue((__bridge CFStringRef)key, NULL, kCFPreferencesCurrentApplication);
            [changed addObject:@{@"key": key, @"value": @"removed"}];
        }
        CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication);
        // Reset log settings
        for (NSString *key in @[@"LogLevel", @"LogUI", @"LogThread", @"LogCategory"]) {
            [defaults removeObjectForKey:key];
            [changed addObject:@{@"key": key, @"value": @"removed"}];
        }
    } else {
        return @{@"error": [NSString stringWithFormat:@"Unknown preset: %@", preset],
                 @"available": @[@"timeline_visual", @"timeline_logging",
                                 @"performance", @"render_debug", @"verbose_logging", @"all_off"]};
    }

    [defaults synchronize];

    // Reload TLK
    Class tlkClass = NSClassFromString(@"TLKUserDefaults");
    if (tlkClass && [tlkClass respondsToSelector:NSSelectorFromString(@"_loadUserDefaults")]) {
        ((void (*)(id, SEL))objc_msgSend)(tlkClass, NSSelectorFromString(@"_loadUserDefaults"));
    }

    return @{@"status": @"ok", @"preset": preset, @"changed": changed, @"count": @(changed.count)};
}

#pragma mark - Request Dispatcher

static NSDictionary *FCPBridge_handleRequest(NSDictionary *request) {
    NSString *method = request[@"method"];
    NSDictionary *params = request[@"params"] ?: @{};

    if (!method) {
        return @{@"error": @{@"code": @(-32600), @"message": @"Invalid Request: method required"}};
    }

    // Lazily install effect-drag swizzles on first RPC call
    FCPBridge_installEffectDragSwizzlesNow();

    NSDictionary *result = nil;

    // system.* namespace
    if ([method isEqualToString:@"system.version"]) {
        result = FCPBridge_handleSystemVersion(params);
    } else if ([method isEqualToString:@"system.getClasses"]) {
        result = FCPBridge_handleSystemGetClasses(params);
    } else if ([method isEqualToString:@"system.getMethods"]) {
        result = FCPBridge_handleSystemGetMethods(params);
    } else if ([method isEqualToString:@"system.callMethod"]) {
        result = FCPBridge_handleSystemCallMethod(params);
    } else if ([method isEqualToString:@"system.swizzle"]) {
        result = FCPBridge_handleSystemSwizzle(params);
    } else if ([method isEqualToString:@"system.getProperties"]) {
        result = FCPBridge_handleSystemGetProperties(params);
    } else if ([method isEqualToString:@"system.getProtocols"]) {
        result = FCPBridge_handleSystemGetProtocols(params);
    } else if ([method isEqualToString:@"system.getSuperchain"]) {
        result = FCPBridge_handleSystemGetSuperchain(params);
    } else if ([method isEqualToString:@"system.getIvars"]) {
        result = FCPBridge_handleSystemGetIvars(params);
    } else if ([method isEqualToString:@"system.callMethodWithArgs"]) {
        result = FCPBridge_handleCallMethodWithArgs(params);
    }
    // object.* namespace
    else if ([method isEqualToString:@"object.get"]) {
        result = FCPBridge_handleObjectGet(params);
    } else if ([method isEqualToString:@"object.release"]) {
        result = FCPBridge_handleObjectRelease(params);
    } else if ([method isEqualToString:@"object.list"]) {
        result = FCPBridge_handleObjectList(params);
    } else if ([method isEqualToString:@"object.getProperty"]) {
        result = FCPBridge_handleGetProperty(params);
    } else if ([method isEqualToString:@"object.setProperty"]) {
        result = FCPBridge_handleSetProperty(params);
    }
    // timeline.* namespace
    else if ([method isEqualToString:@"timeline.action"]) {
        result = FCPBridge_handleTimelineAction(params);
    } else if ([method isEqualToString:@"timeline.getState"]) {
        result = FCPBridge_handleTimelineGetState(params);
    } else if ([method isEqualToString:@"timeline.getDetailedState"]) {
        result = FCPBridge_handleTimelineGetDetailedState(params);
    } else if ([method isEqualToString:@"timeline.setRange"]) {
        result = FCPBridge_handleSetRange(params);
    } else if ([method isEqualToString:@"timeline.batchExport"]) {
        result = FCPBridge_handleBatchExport(params);
    }
    // playback.* namespace
    else if ([method isEqualToString:@"playback.action"]) {
        result = FCPBridge_handlePlayback(params);
    } else if ([method isEqualToString:@"playback.seekToTime"]) {
        result = FCPBridge_handlePlaybackSeek(params);
    } else if ([method isEqualToString:@"playback.getPosition"]) {
        result = FCPBridge_handlePlaybackGetPosition(params);
    }
    // fcpxml.* namespace
    else if ([method isEqualToString:@"fcpxml.import"]) {
        result = FCPBridge_handleFCPXMLImport(params);
    }
    // effects.* namespace
    else if ([method isEqualToString:@"effects.list"]) {
        result = FCPBridge_handleEffectList(params);
    } else if ([method isEqualToString:@"effects.getClipEffects"]) {
        result = FCPBridge_handleGetClipEffects(params);
    }
    // transcript.* namespace
    else if ([method isEqualToString:@"transcript.open"]) {
        result = FCPBridge_handleTranscriptOpen(params);
    } else if ([method isEqualToString:@"transcript.close"]) {
        result = FCPBridge_handleTranscriptClose(params);
    } else if ([method isEqualToString:@"transcript.getState"]) {
        result = FCPBridge_handleTranscriptGetState(params);
    } else if ([method isEqualToString:@"transcript.deleteWords"]) {
        result = FCPBridge_handleTranscriptDeleteWords(params);
    } else if ([method isEqualToString:@"transcript.moveWords"]) {
        result = FCPBridge_handleTranscriptMoveWords(params);
    } else if ([method isEqualToString:@"transcript.search"]) {
        result = FCPBridge_handleTranscriptSearch(params);
    } else if ([method isEqualToString:@"transcript.deleteSilences"]) {
        result = FCPBridge_handleTranscriptDeleteSilences(params);
    } else if ([method isEqualToString:@"transcript.setSilenceThreshold"]) {
        result = FCPBridge_handleTranscriptSetSilenceThreshold(params);
    } else if ([method isEqualToString:@"transcript.setSpeaker"]) {
        result = FCPBridge_handleTranscriptSetSpeaker(params);
    } else if ([method isEqualToString:@"transcript.setEngine"]) {
        result = FCPBridge_handleTranscriptSetEngine(params);
    }
    // scene detection
    else if ([method isEqualToString:@"scene.detect"]) {
        result = FCPBridge_handleDetectSceneChanges(params);
    }
    // effects browse/apply
    else if ([method isEqualToString:@"effects.listAvailable"]) {
        result = FCPBridge_handleEffectsListAvailable(params);
    } else if ([method isEqualToString:@"effects.apply"]) {
        result = FCPBridge_handleEffectsApply(params);
    } else if ([method isEqualToString:@"titles.insert"]) {
        result = FCPBridge_handleTitleInsert(params);
    } else if ([method isEqualToString:@"stabilize.subject"]) {
        result = FCPBridge_handleSubjectStabilize(params);
    }
    // transitions.* namespace
    else if ([method isEqualToString:@"transitions.list"]) {
        result = FCPBridge_handleTransitionsList(params);
    } else if ([method isEqualToString:@"transitions.apply"]) {
        result = FCPBridge_handleTransitionsApply(params);
    }
    // command.* namespace (command palette)
    else if ([method isEqualToString:@"command.show"]) {
        result = FCPBridge_handleCommandShow(params);
    } else if ([method isEqualToString:@"command.hide"]) {
        result = FCPBridge_handleCommandHide(params);
    } else if ([method isEqualToString:@"command.search"]) {
        result = FCPBridge_handleCommandSearch(params);
    } else if ([method isEqualToString:@"command.execute"]) {
        result = FCPBridge_handleCommandExecute(params);
    } else if ([method isEqualToString:@"command.ai"]) {
        result = FCPBridge_handleCommandAI(params);
    }
    // browser.* namespace
    else if ([method isEqualToString:@"browser.listClips"]) {
        result = FCPBridge_handleBrowserListClips(params);
    } else if ([method isEqualToString:@"browser.appendClip"]) {
        result = FCPBridge_handleBrowserAppendClip(params);
    }
    // menu.* namespace
    else if ([method isEqualToString:@"menu.execute"]) {
        result = FCPBridge_handleMenuExecute(params);
    } else if ([method isEqualToString:@"menu.list"]) {
        result = FCPBridge_handleMenuList(params);
    }
    // inspector.* namespace
    else if ([method isEqualToString:@"inspector.get"]) {
        result = FCPBridge_handleInspectorGet(params);
    } else if ([method isEqualToString:@"inspector.set"]) {
        result = FCPBridge_handleInspectorSet(params);
    }
    // view.* namespace
    else if ([method isEqualToString:@"view.toggle"]) {
        result = FCPBridge_handleViewToggle(params);
    } else if ([method isEqualToString:@"view.workspace"]) {
        result = FCPBridge_handleWorkspace(params);
    }
    // roles.* namespace
    else if ([method isEqualToString:@"roles.assign"]) {
        result = FCPBridge_handleRolesAssign(params);
    }
    // share.* namespace
    else if ([method isEqualToString:@"share.export"]) {
        result = FCPBridge_handleShareExport(params);
    }
    // project.* namespace
    else if ([method isEqualToString:@"project.create"]) {
        result = FCPBridge_handleProjectCreate(params);
    } else if ([method isEqualToString:@"project.createEvent"]) {
        result = FCPBridge_handleEventCreate(params);
    } else if ([method isEqualToString:@"project.createLibrary"]) {
        result = FCPBridge_handleLibraryCreate(params);
    }
    // tool.* namespace
    else if ([method isEqualToString:@"tool.select"]) {
        result = FCPBridge_handleToolSelect(params);
    }
    // dialog.* namespace
    else if ([method isEqualToString:@"dialog.detect"]) {
        result = FCPBridge_handleDialogDetect(params);
    } else if ([method isEqualToString:@"dialog.click"]) {
        result = FCPBridge_handleDialogClick(params);
    } else if ([method isEqualToString:@"dialog.fill"]) {
        result = FCPBridge_handleDialogFill(params);
    } else if ([method isEqualToString:@"dialog.checkbox"]) {
        result = FCPBridge_handleDialogCheckbox(params);
    } else if ([method isEqualToString:@"dialog.popup"]) {
        result = FCPBridge_handleDialogPopup(params);
    } else if ([method isEqualToString:@"dialog.dismiss"]) {
        result = FCPBridge_handleDialogDismiss(params);
    }
    // viewer.* namespace
    else if ([method isEqualToString:@"viewer.getZoom"]) {
        result = FCPBridge_handleViewerGetZoom(params);
    } else if ([method isEqualToString:@"viewer.setZoom"]) {
        result = FCPBridge_handleViewerSetZoom(params);
    }
    // options.* namespace
    else if ([method isEqualToString:@"options.get"]) {
        result = FCPBridge_handleOptionsGet(params);
    } else if ([method isEqualToString:@"options.set"]) {
        result = FCPBridge_handleOptionsSet(params);
    }
    // flexmusic.* namespace
    else if ([method isEqualToString:@"flexmusic.listSongs"]) {
        result = FCPBridge_handleFlexMusicListSongs(params);
    } else if ([method isEqualToString:@"flexmusic.getSong"]) {
        result = FCPBridge_handleFlexMusicGetSong(params);
    } else if ([method isEqualToString:@"flexmusic.getTiming"]) {
        result = FCPBridge_handleFlexMusicGetTiming(params);
    } else if ([method isEqualToString:@"flexmusic.renderToFile"]) {
        result = FCPBridge_handleFlexMusicRender(params);
    } else if ([method isEqualToString:@"flexmusic.addToTimeline"]) {
        result = FCPBridge_handleFlexMusicAddToTimeline(params);
    }
    // montage.* namespace
    else if ([method isEqualToString:@"montage.analyzeClips"]) {
        result = FCPBridge_handleMontageAnalyze(params);
    } else if ([method isEqualToString:@"montage.planEdit"]) {
        result = FCPBridge_handleMontagePlan(params);
    } else if ([method isEqualToString:@"montage.assemble"]) {
        result = FCPBridge_handleMontageAssemble(params);
    } else if ([method isEqualToString:@"montage.auto"]) {
        result = FCPBridge_handleMontageAuto(params);
    }
    // debug.* namespace
    else if ([method isEqualToString:@"debug.getConfig"]) {
        result = FCPBridge_handleDebugGetConfig(params);
    } else if ([method isEqualToString:@"debug.setConfig"]) {
        result = FCPBridge_handleDebugSetConfig(params);
    } else if ([method isEqualToString:@"debug.resetConfig"]) {
        result = FCPBridge_handleDebugResetConfig(params);
    } else if ([method isEqualToString:@"debug.enablePreset"]) {
        result = FCPBridge_handleDebugEnablePreset(params);
    } else if ([method isEqualToString:@"debug.startFramerateMonitor"]) {
        result = FCPBridge_handleDebugStartFramerateMonitor(params);
    } else if ([method isEqualToString:@"debug.stopFramerateMonitor"]) {
        result = FCPBridge_handleDebugStopFramerateMonitor(params);
    } else if ([method isEqualToString:@"debug.dumpRuntimeMetadata"]) {
        result = FCPBridge_handleDumpRuntimeMetadata(params);
    } else if ([method isEqualToString:@"debug.listLoadedImages"]) {
        result = FCPBridge_handleListLoadedImages(params);
    } else if ([method isEqualToString:@"debug.getImageSections"]) {
        result = FCPBridge_handleGetImageSections(params);
    } else if ([method isEqualToString:@"debug.getImageSymbols"]) {
        result = FCPBridge_handleGetImageSymbols(params);
    } else if ([method isEqualToString:@"debug.getNotificationNames"]) {
        result = FCPBridge_handleGetNotificationNames(params);
    }
    else {
        return @{@"error": @{@"code": @(-32601), @"message":
                     [NSString stringWithFormat:@"Method not found: %@", method]}};
    }

    if (result[@"error"] && ![result[@"error"] isKindOfClass:[NSDictionary class]]) {
        return @{@"error": @{@"code": @(-32000), @"message": result[@"error"]}};
    }

    return @{@"result": result};
}

#pragma mark - Client Handler

static void FCPBridge_handleClient(int clientFd) {
    FCPBridge_log(@"Client connected (fd=%d)", clientFd);

    dispatch_async(sClientQueue, ^{
        [sConnectedClients addObject:@(clientFd)];
    });

    FILE *stream = fdopen(clientFd, "r+");
    if (!stream) {
        close(clientFd);
        return;
    }

    char buffer[65536];
    while (fgets(buffer, sizeof(buffer), stream)) {
        @autoreleasepool {
            NSData *data = [NSData dataWithBytes:buffer length:strlen(buffer)];
            NSError *jsonError = nil;
            NSDictionary *request = [NSJSONSerialization JSONObjectWithData:data
                                                                   options:0
                                                                     error:&jsonError];

            NSMutableDictionary *response = [NSMutableDictionary dictionary];
            response[@"jsonrpc"] = @"2.0";

            if (request[@"id"]) {
                response[@"id"] = request[@"id"];
            }

            if (jsonError || !request) {
                response[@"error"] = @{@"code": @(-32700),
                                       @"message": @"Parse error"};
            } else {
                @try {
                    NSDictionary *result = FCPBridge_handleRequest(request);
                    if (result[@"error"]) {
                        response[@"error"] = result[@"error"];
                    } else {
                        response[@"result"] = result[@"result"];
                    }
                } @catch (NSException *exception) {
                    FCPBridge_log(@"Exception handling request: %@ - %@",
                                  exception.name, exception.reason);
                    response[@"error"] = @{
                        @"code": @(-32000),
                        @"message": [NSString stringWithFormat:@"Internal error: %@", exception.reason]
                    };
                }
            }

            NSData *responseJson = [NSJSONSerialization dataWithJSONObject:response
                                                                  options:0
                                                                    error:nil];
            if (responseJson) {
                fwrite(responseJson.bytes, 1, responseJson.length, stream);
                fwrite("\n", 1, 1, stream);
                fflush(stream);
            }
        }
    }

    FCPBridge_log(@"Client disconnected (fd=%d)", clientFd);
    dispatch_async(sClientQueue, ^{
        [sConnectedClients removeObject:@(clientFd)];
    });
    fclose(stream);
}

#pragma mark - Server

void FCPBridge_startControlServer(void) {
    sClientQueue = dispatch_queue_create("com.fcpbridge.clients", DISPATCH_QUEUE_SERIAL);
    sConnectedClients = [NSMutableArray array];

    // Use TCP on localhost -- sandbox allows network.server entitlement
    int serverFd = socket(AF_INET, SOCK_STREAM, 0);
    if (serverFd < 0) {
        FCPBridge_log(@"ERROR: Failed to create TCP socket: %s", strerror(errno));
        return;
    }

    // Allow port reuse
    int optval = 1;
    setsockopt(serverFd, SOL_SOCKET, SO_REUSEADDR, &optval, sizeof(optval));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);  // 127.0.0.1 only
    addr.sin_port = htons(FCPBRIDGE_TCP_PORT);

    if (bind(serverFd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        FCPBridge_log(@"ERROR: Failed to bind TCP port %d: %s", FCPBRIDGE_TCP_PORT, strerror(errno));
        close(serverFd);
        return;
    }

    if (listen(serverFd, 5) < 0) {
        FCPBridge_log(@"ERROR: Failed to listen: %s", strerror(errno));
        close(serverFd);
        return;
    }

    sServerFd = serverFd;

    sServerFd = serverFd;

    FCPBridge_log(@"================================================");
    FCPBridge_log(@"Control server listening on 127.0.0.1:%d", FCPBRIDGE_TCP_PORT);
    FCPBridge_log(@"================================================");

    // Use dispatch_source for accepting connections instead of a blocking loop.
    // This lets the thread exit naturally and won't block app termination.
    dispatch_source_t acceptSource = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_READ, serverFd, 0,
        dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0));

    dispatch_source_set_event_handler(acceptSource, ^{
        int clientFd = accept(serverFd, NULL, NULL);
        if (clientFd < 0) return;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            FCPBridge_handleClient(clientFd);
        });
    });

    dispatch_source_set_cancel_handler(acceptSource, ^{
        close(serverFd);
        sServerFd = -1;
        FCPBridge_log(@"Server socket closed");
    });

    dispatch_resume(acceptSource);

    // Cancel the source on app termination
    [[NSNotificationCenter defaultCenter]
        addObserverForName:NSApplicationWillTerminateNotification
        object:nil queue:nil usingBlock:^(NSNotification *note) {
            FCPBridge_log(@"App terminating — cancelling server");
            dispatch_source_cancel(acceptSource);
        }];
}
