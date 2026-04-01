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
            [ivars addObject:@{
                @"name": name ? @(name) : @"<anon>",
                @"type": type ? @(type) : @"?"
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
            if ([sequence respondsToSelector:@selector(primaryObject)]) {
                id primaryObj = ((id (*)(id, SEL))objc_msgSend)(sequence, @selector(primaryObject));
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
                    withApplicationAtURL:[NSURL fileURLWithPath:
                        @"/Applications/Final Cut Pro.app"]
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
        @"retimeHold":       @"retimeHoldFromSelection:",
        @"freezeFrame":      @"freezeFrame:",
        @"retimeBladeSpeed": @"retimeBladeSpeed:",

        // Generators
        @"addVideoGenerator": @"addVideoGenerator:",

        // Export/Share
        @"exportXML":        @"exportXML:",
        @"shareSelection":   @"shareSelection:",

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
        @"liftFromPrimaryStoryline": @"liftFromPrimaryStoryline:",
        @"overwriteToPrimaryStoryline": @"overwriteToPrimaryStoryline:",
        @"createStoryline":  @"createStoryline:",

        // Timeline view
        @"zoomToFit":        @"zoomToFit:",
        @"zoomIn":           @"zoomIn:",
        @"zoomOut":          @"zoomOut:",
        @"toggleSnapping":   @"toggleSnapping:",
        @"toggleSkimming":   @"toggleSkimming:",
        @"toggleInspector":  @"toggleInspector:",
        @"toggleTimeline":   @"toggleTimeline:",
        @"toggleTimelineIndex": @"toggleTimelineIndex:",

        // Render
        @"renderSelection":  @"renderSelection:",
        @"renderAll":        @"renderAll:",

        // Markers
        @"deleteMarkersInSelection": @"deleteMarkersInSelection:",

        // Analysis
        @"analyzeAndFix":    @"analyzeAndFix:",
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
    dispatch_async(dispatch_get_main_queue(), ^{
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
    dispatch_async(dispatch_get_main_queue(), ^{
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

            SEL addSel = @selector(addTransition:);
            if ([timelineModule respondsToSelector:addSel]) {
                ((void (*)(id, SEL, id))objc_msgSend)(timelineModule, addSel, nil);
            } else {
                // Fall back to responder chain
                [[NSApplication sharedApplication] sendAction:addSel to:nil from:nil];
            }

            // Restore the original default transition
            if (originalDefault) {
                [[NSUserDefaults standardUserDefaults] setObject:originalDefault
                                                          forKey:@"FFDefaultVideoTransition"];
            }

            // Get the display name of what we applied
            id appliedName = ((id (*)(id, SEL, id))objc_msgSend)((id)ffEffect,
                @selector(displayNameForEffectID:), resolvedID);

            result = @{
                @"status": @"ok",
                @"transition": [appliedName isKindOfClass:[NSString class]] ? appliedName : @"Unknown",
                @"effectID": resolvedID,
            };
        } @catch (NSException *e) {
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

#pragma mark - Request Dispatcher

static NSDictionary *FCPBridge_handleRequest(NSDictionary *request) {
    NSString *method = request[@"method"];
    NSDictionary *params = request[@"params"] ?: @{};

    if (!method) {
        return @{@"error": @{@"code": @(-32600), @"message": @"Invalid Request: method required"}};
    }

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
    }
    // playback.* namespace
    else if ([method isEqualToString:@"playback.action"]) {
        result = FCPBridge_handlePlayback(params);
    } else if ([method isEqualToString:@"playback.seekToTime"]) {
        result = FCPBridge_handlePlaybackSeek(params);
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
